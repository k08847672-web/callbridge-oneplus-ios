import Foundation

/// Mac CLI: exercise the same client against Android's explicit synthetic-only server.
/// Private pairing file only; no real microphone, Telecom, PCM persistence or keys in argv.
@main
struct NetworkSimulationSelfTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 || (CommandLine.arguments.count == 3 &&
            ["--production-rejection", "--expect-disconnect"].contains(CommandLine.arguments[2])) else { throw Failure.invalidPairing }
        let rejectSimulation = CommandLine.arguments.last == "--production-rejection"
        let expectDisconnect = CommandLine.arguments.last == "--expect-disconnect"
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw Failure.invalidPairing }
        let bytes = try Data(contentsOf: url)
        guard bytes.count < 4096,
              let values = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              values["simulation"] as? Bool == true,
              let endpoint = values["endpoint"] as? String,
              let port = values["port"] as? Int, let numericPort = UInt16(exactly: port),
              let keyText = values["pairingKey"] as? String,
              let expiry = values["expiresAt"] as? Date, expiry > Date() else { throw Failure.invalidPairing }
        let client = BridgeClient()
        let id = UUID()
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var answers = 0
        var nonzero = 0
        var statistics = NetworkStatistics()
        var stoppedCleanly = false
        var expectedError = false
        var timer: DispatchSourceTimer?
        let silence = Data(count: PJZCallProtocol.pcmBytes)
        client.onDownlink = { _, pcm in
            lock.lock()
            if PJZCallProtocol.pcmLevel(pcm) > 0 { nonzero += 1 }
            lock.unlock()
        }
        client.onEvent = { _, event in
            switch event {
            case .stage(.ringing):
                answers += 1
                client.requestAnswer(id: id)
            case .stage(.active):
                let tick = DispatchSource.makeTimerSource(queue: .global())
                tick.schedule(deadline: .now(), repeating: .milliseconds(20))
                tick.setEventHandler { client.sendMicrophone(id: id, pcm: silence) }
                timer = tick
                tick.resume()
            case .statistics(let value): statistics = value
            case .stopped(let reason):
                timer?.cancel()
                stoppedCleanly = reason == nil
                if rejectSimulation { if case .invalidState? = reason { expectedError = true } }
                if expectDisconnect { if case .connectionFailed? = reason { expectedError = true } }
                done.signal()
            default: break
            }
        }
        client.connect(id: id, endpoint: endpoint, port: numericPort,
                       key: try PJZCallProtocol.decodeKey(keyText), simulation: !rejectSimulation)
        guard done.wait(timeout: .now() + 20) == .success else {
            client.disconnect()
            throw Failure.timeout
        }
        lock.lock(); let audible = nonzero; lock.unlock()
        let passed = rejectSimulation
            ? expectedError && answers == 0 && statistics.receivedFrames == 0 && statistics.sentFrames == 0
            : (expectDisconnect ? expectedError : stoppedCleanly) && answers == 1
                && statistics.receivedFrames == (expectDisconnect ? 150 : 500)
                && statistics.sentFrames >= (expectDisconnect ? 140 : 450) && audible == (expectDisconnect ? 15 : 190)
        print("PJZ_NETWORK_CLIENT passed=\(passed) answers=\(answers) down_frames=\(statistics.receivedFrames) up_frames=\(statistics.sentFrames) nonzero_down_frames=\(audible) clean_end=\(stoppedCleanly) expected_disconnect=\(expectDisconnect) production_rejection=\(rejectSimulation) real_microphone=false calls_placed=false")
        guard passed else { throw Failure.failed }
    }
    enum Failure: Error { case invalidPairing, timeout, failed }
}
