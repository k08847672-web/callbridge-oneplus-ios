import Foundation

/// Actual BridgeClient against the Java production admission/JOIN code on loopback.
/// The fixture has a fixed synthetic key and PCM; no device, CallKit or microphone.
@main
struct JoinClientSelfTests {
    static func main() throws {
        guard CommandLine.arguments.count == 3,
              let port = UInt16(CommandLine.arguments[1]), port != 0,
              ["ringing", "ended", "mismatch", "foreground"].contains(CommandLine.arguments[2]) else {
            throw Failure.arguments
        }
        let mode = CommandLine.arguments[2]
        let expectsCall = mode == "ringing" || mode == "foreground"
        let callID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let transportID = UUID()
        let client = BridgeClient(localFixture: true)
        let done = DispatchSemaphore(value: 0)
        var events: [String] = []
        var announced: [UUID] = []
        var ringing = 0
        var active = 0
        var downlink = 0
        var unexpectedID = false
        var cleanEnd = false
        var requestedHangup = false
        client.onDownlink = { id, _ in
            if id != transportID { unexpectedID = true }
            downlink += 1
            if !requestedHangup {
                requestedHangup = true
                client.sendMicrophone(id: transportID, pcm: Data(count: PJZCallProtocol.pcmBytes))
                client.hangUp(id: transportID)
            }
        }
        client.onEvent = { id, event in
            if id != transportID { unexpectedID = true }
            switch event {
            case .callID(let value):
                announced.append(value)
                events.append("call_id")
            case .stage(.idle): events.append("idle")
            case .stage(.ringing):
                ringing += 1
                events.append("ringing")
                // Exercise the production idempotency guard, not a test-side counter.
                client.requestAnswer(id: transportID)
                client.requestAnswer(id: transportID)
            case .stage(.active):
                active += 1
                events.append("active")
            case .stage(.ending): events.append("ending")
            case .stopped(let reason):
                cleanEnd = reason == nil
                events.append("stopped")
                done.signal()
            default: break
            }
        }
        client.connect(id: transportID, endpoint: "127.0.0.1", port: port,
                       key: Data(repeating: 0x5a, count: 32),
                       callID: mode == "foreground" ? nil : callID)
        guard done.wait(timeout: .now() + 15) == .success else {
            client.disconnect()
            throw Failure.timeout
        }
        let flow: [String]
        if expectsCall {
            flow = (mode == "foreground" ? ["idle"] : [])
                + ["call_id", "ringing", "active", "ending", "stopped"]
        } else { flow = ["call_id", "stopped"] }
        let passed = cleanEnd && !unexpectedID && announced == [callID] && events == flow
            && (expectsCall ? ringing == 1 && active == 1 && downlink > 0 && requestedHangup
                : ringing == 0 && active == 0 && downlink == 0 && !requestedHangup)
        print("JOIN_CLIENT_LOCAL mode=\(mode) passed=\(passed) ringing=\(ringing) active=\(active) down_frames=\(downlink) clean_end=\(cleanEnd) synthetic=true device_verified=false apns_delivery_verified=false")
        guard passed else { throw Failure.failed }
    }

    enum Failure: Error { case arguments, timeout, failed }
}
