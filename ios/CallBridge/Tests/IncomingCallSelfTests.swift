import Foundation

/// Synthetic inputs and fake side effects exercise the production coordinator. No APNs,
/// CallKit service, device, network, microphone or real Keychain entry is accessed.
@main
struct IncomingCallSelfTests {
    @MainActor
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) throws {
            checks += 1
            if !value { throw Failure.failed(name) }
        }
        let pairingID = UUID(uuidString: "00000000-0000-4000-8000-000000000010")!
        let callID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let other = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let key = String(repeating: "5a", count: 32)
        let pairing = StoredPairing(pairingID: pairingID, endpoint: "100.64.0.1", port: 47631,
                                    keyHex: key, providerURL: URL(string: "https://example.invalid")!, providerToken: key)
        let invitation = CallInvitation(pairingID: pairingID, callID: callID)
        let payload: [AnyHashable: Any] = ["aps": [:], "pairing_id": pairingID.uuidString.lowercased(),
            "call_id": callID.uuidString.lowercased(), "revision": 1, "state": "ringing"]
        try check(try CallInvitation(payload: payload) == invitation, "wire payload")
        for (field, value) in [("revision", 2 as Any), ("state", "ended" as Any), ("call_id", "wrong" as Any)] {
            var bad = payload; bad[field] = value
            try check((try? CallInvitation(payload: bad)) == nil, "reject invalid invitation")
        }
        let encoded = PJZCallProtocol.callIDPayload(callID)
        let decoded = try PJZCallProtocol.decodeCallID(encoded)
        try check(encoded.count == 36 && decoded == callID, "UUID ASCII contract")
        try PJZCallProtocol.validateServerFrame(BridgeFrame(type: PJZCallProtocol.join, payload: encoded))
        try check((try? PJZCallProtocol.decodeCallID(Data("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA".utf8))) == nil,
                  "canonical lowercase only")
        try check(try JSONDecoder().decode(StoredPairing.self, from: JSONEncoder().encode(pairing)) == pairing,
                  "persistent record round trip, no use expiry")

        let importValues: [String: Any] = ["pairing_id": pairingID.uuidString.lowercased(),
            "endpoint": pairing.endpoint, "port": Int(pairing.port), "pairingKey": key,
            "providerURL": pairing.providerURL.absoluteString, "providerToken": key, "simulation": false]
        func importPairing(_ values: [String: Any]) throws -> StoredPairing {
            try StoredPairing.importFile(PropertyListSerialization.data(fromPropertyList: values,
                                                                        format: .binary, options: 0))
        }
        try check(try importPairing(importValues) == pairing, "import without expiry")
        for expiry in [Date(timeIntervalSince1970: 0), Date.distantFuture] {
            var legacy = importValues; legacy["expiresAt"] = expiry
            try check(try importPairing(legacy) == pairing, "ignore legacy import expiry")
        }
        for field in ["pairingKey", "providerToken"] {
            var bad = importValues; bad[field] = "not-a-key"
            try check((try? importPairing(bad)) == nil, "reject malformed import key")
        }
        for field in ["providerURL", "providerToken"] {
            var incomplete = importValues; incomplete.removeValue(forKey: field)
            try check((try? importPairing(incomplete)) == nil, "reject incomplete provider")
        }
        var badProvider = importValues; badProvider["providerURL"] = "https://example.invalid/?token=example"
        try check((try? importPairing(badProvider)) == nil, "preserve provider URL validation")

        var time = Date(timeIntervalSince1970: 100)
        var scheduled: [() -> Void] = []
        var events: [String] = []
        var report: ((Bool) -> Void)?
        let coordinator = IncomingCallCoordinator(loadPairing: { id in
            guard id == pairingID else { throw IncomingCallError.missingPairing }; return pairing
        }, reportIncoming: { _, completion in events.append("report"); report = completion },
           join: { _, _ in events.append("join") }, end: { _ in events.append("end") },
           now: { time }, schedule: { _, work in scheduled.append(work) })
        coordinator.receive(invitation) { events.append("push_complete") }
        try check(events == ["report"], "report before any transport")
        var answers: [Bool] = []
        coordinator.requestAnswer(callID: callID, deadline: time.addingTimeInterval(10)) { answers.append($0) }
        try check(answers.isEmpty, "early answer waits for authenticated JOIN")
        report?(true)
        try check(events == ["report", "push_complete", "join"], "PushKit completion does not wait for network")
        coordinator.didJoin(callID: other)
        try check(answers.isEmpty, "other call cannot fulfill answer")
        coordinator.didJoin(callID: callID)
        try check(answers == [true], "same call releases early answer")
        coordinator.receive(invitation) { events.append("duplicate_complete") }
        coordinator.didJoin(callID: callID)
        try check(events.filter { $0 == "join" }.count == 1 && answers == [true], "duplicate delivery is idempotent")
        coordinator.requestAnswer(callID: callID, deadline: time.addingTimeInterval(10)) { answers.append($0) }
        try check(answers == [true, false], "second answer cannot be accepted")
        coordinator.finish(callID: other)
        try check(coordinator.current == invitation, "other end cannot terminate current call")
        coordinator.finish(callID: callID)
        try check(coordinator.current == nil && events.last == "end", "remote/user end clears call")
        coordinator.receive(invitation) { events.append("stale_complete") }
        report?(true)
        try check(events.filter { $0 == "join" }.count == 1 && coordinator.current == nil, "ended call never rejoins")

        let next = CallInvitation(pairingID: pairingID, callID: other)
        coordinator.receive(next) {}
        report?(true)
        var cancelled: [Bool] = []
        coordinator.requestAnswer(callID: other, deadline: time.addingTimeInterval(10)) { cancelled.append($0) }
        coordinator.finish(callID: other)
        coordinator.didJoin(callID: other)
        try check(cancelled == [false], "cancel during JOIN blocks late answer")

        let timedID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        coordinator.receive(CallInvitation(pairingID: pairingID, callID: timedID)) {}
        report?(true)
        var timed: [Bool] = []
        coordinator.requestAnswer(callID: timedID, deadline: time.addingTimeInterval(5)) { timed.append($0) }
        time = time.addingTimeInterval(5)
        scheduled.forEach { $0() }
        coordinator.didJoin(callID: timedID)
        try check(timed == [false] && coordinator.current == nil, "system deadline, virtual clock, no sleep")

        let missing = CallInvitation(pairingID: other, callID: UUID())
        let joinsBefore = events.filter { $0 == "join" }.count
        coordinator.receive(missing) {}
        report?(true)
        try check(coordinator.current == nil && events.filter { $0 == "join" }.count == joinsBefore,
                  "missing or inaccessible pairing still completes report without device control")
        print("INCOMING_CALL_LOCAL passed=\(checks) synthetic=true apns_delivery_verified=false locked_wakeup_verified=false")
    }
    enum Failure: Error { case failed(String) }
}
