import Foundation

/// One mock-provider payload crosses the production invitation/coordinator/client chain.
/// CallKit reporting and audio readiness are fake; the authenticated TCP peer is Java's
/// production JOIN admission fixture. No APNs, microphone, phone or real Keychain entry.
@main
struct PushJoinSelfTests {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              let port = UInt16(CommandLine.arguments[1]), port != 0 else { throw Failure.arguments }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        guard bytes.count <= 4096,
              let payload = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw Failure.arguments
        }
        let invitation = try CallInvitation(payload: payload)
        guard invitation.callID == UUID(uuidString: "00000000-0000-4000-8000-000000000001") else {
            throw Failure.arguments
        }
        let transportID = UUID()
        let syntheticKey = String(repeating: "5a", count: 32)
        let pairing = StoredPairing(pairingID: invitation.pairingID, endpoint: "100.64.0.1", port: port,
                                    keyHex: syntheticKey, providerURL: URL(string: "https://example.invalid")!,
                                    providerToken: String(repeating: "7c", count: 32))
        let client = BridgeClient(localFixture: true)
        var coordinator: IncomingCallCoordinator!
        var finished: CheckedContinuation<Void, Error>?
        var events: [String] = []
        var reported: [UUID] = []
        var announced: UUID?
        var answerResults: [Bool] = []
        var earlyWaited = false
        var downlink = 0
        var cleanEnd = false
        var unexpectedID = false
        coordinator = IncomingCallCoordinator(loadPairing: { id in
            guard id == pairing.pairingID else { throw IncomingCallError.missingPairing }
            return pairing
        }, reportIncoming: { id, _, completion in
            reported.append(id)
            events.append("report")
            coordinator.requestAnswer(callID: id, deadline: Date().addingTimeInterval(10)) { ready in
                answerResults.append(ready)
                events.append("answer_ready")
                if ready {
                    // Fake CallKit fulfillment and successful audio preparation. The real
                    // client remains responsible for its own one-ANSWER guard.
                    client.requestAnswer(id: transportID)
                    client.requestAnswer(id: transportID)
                }
            }
            earlyWaited = answerResults.isEmpty
            completion(true)
        }, join: { received, saved in
            events.append("join")
            client.connect(id: transportID, endpoint: "127.0.0.1", port: saved.port,
                           key: (try? PJZCallProtocol.decodeKey(saved.keyHex)) ?? Data(), callID: received.callID)
        }, end: { _ in events.append("coordinator_end") })
        client.onDownlink = { id, _ in
            DispatchQueue.main.async {
                if id != transportID { unexpectedID = true }
                downlink += 1
                if downlink == 1 {
                    events.append("downlink")
                    client.sendMicrophone(id: transportID, pcm: Data(count: PJZCallProtocol.pcmBytes))
                    client.hangUp(id: transportID)
                }
            }
        }
        client.onEvent = { id, event in
            DispatchQueue.main.async {
                if id != transportID { unexpectedID = true }
                switch event {
                case .callID(let value): announced = value; events.append("call_id")
                case .stage(.ringing):
                    events.append("ringing")
                    if announced == invitation.callID { coordinator.didJoin(callID: invitation.callID) }
                case .stage(.active): events.append("active")
                case .stage(.ending): events.append("ending")
                case .stopped(let reason):
                    cleanEnd = reason == nil
                    events.append("stopped")
                    coordinator.finish(callID: invitation.callID, reportEnd: false)
                    let pending = finished
                    finished = nil
                    pending?.resume()
                default: break
                }
            }
        }
        let timeout = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            let pending = finished
            finished = nil
            client.disconnect()
            pending?.resume(throwing: Failure.timeout)
        }
        defer { timeout.cancel(); client.disconnect() }
        try await withCheckedThrowingContinuation { pending in
            finished = pending
            coordinator.receive(invitation) { events.append("push_complete") }
        }
        let expected = ["report", "push_complete", "join", "call_id", "ringing", "answer_ready",
                        "active", "downlink", "ending", "stopped"]
        let passed = events == expected && reported == [invitation.callID] && announced == invitation.callID
            && earlyWaited && answerResults == [true] && downlink > 0 && cleanEnd && !unexpectedID
        print("PUSH_JOIN_LOCAL passed=\(passed) fake_callkit_reports=\(reported.count) early_answer_waited=\(earlyWaited) down_frames=\(downlink) synthetic=true apns_delivery_verified=false locked_wakeup_verified=false")
        guard passed else { throw Failure.failed }
    }

    enum Failure: Error { case arguments, timeout, failed }
}
