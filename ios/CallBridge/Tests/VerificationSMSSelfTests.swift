import Foundation

@main
struct VerificationSMSSelfTests {
    private static let pairingID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private static let otherPairing = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--reopen" {
            let store = VerificationSMSStore(fileURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            try store.load()
            try check(store.afterSeq(for: pairingID) == 3 && store.messages.count == 3, "reopened cursor/list")
            try check(store.messages.map(\.seq) == [2, 3, 1], "received time ordering")
            try check(store.messages[1].code == nil, "unknown code stays nil")
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("inbox.json")
        let store = VerificationSMSStore(fileURL: file)
        try store.load()
        let first = page([message(seq: 1, time: 1000), message(seq: 2, time: 3000)], cursor: 2, more: true)
        try store.apply(first, pairingID: pairingID)
        try store.apply(first, pairingID: pairingID)
        try check(store.messages.count == 2 && store.afterSeq(for: pairingID) == 2, "replay deduplication")
        try store.apply(page([message(seq: 3, time: 2000, code: nil)], cursor: 3), pairingID: pairingID)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--reopen", file.path]
        try child.run(); child.waitUntilExit()
        try check(child.terminationStatus == 0, "independent process reload")
        try mustThrow("wrong pairing") { try store.apply(page([message(seq: 4, time: 4000, pairing: otherPairing)], cursor: 4), pairingID: pairingID) }
        try mustThrow("cursor skipping records") { try store.apply(page([message(seq: 4, time: 4000)], cursor: 5), pairingID: pairingID) }
        try mustThrow("empty continuation") { try store.apply(page([], cursor: 3, more: true), pairingID: pairingID) }
        try mustThrow("invalid replay sequence") {
            let invalid = VerificationSMS(pairingID: pairingID, messageID: String(repeating: "d", count: 64),
                seq: .min, receivedAtMS: 0, sender: "合成发件人", body: "合成正文", code: nil)
            try store.apply(page([invalid], cursor: 3), pairingID: pairingID)
        }
        try mustThrow("duplicate ID changed") {
            let duplicate = VerificationSMS(pairingID: pairingID, messageID: String(repeating: "1", count: 64),
                seq: 4, receivedAtMS: 4000, sender: "合成发件人", body: "合成正文", code: "001234")
            try store.apply(page([duplicate], cursor: 4), pairingID: pairingID)
        }
        try check(store.afterSeq(for: pairingID) == 3 && store.messages.count == 3, "rejection preserves cursor/list")
        try store.apply(page([message(seq: 1, time: 5000, pairing: otherPairing)], cursor: 1), pairingID: otherPairing)
        try check(store.afterSeq(for: pairingID) == 3 && store.afterSeq(for: otherPairing) == 1 && store.messages.count == 4,
                  "pairing cursors independent and history retained")
        try atomicFailure(directory: directory)
        try automaticCopy(directory: directory)
        try await schema()
        print("VERIFICATION_SMS passed=true process_reopen=true receive_time_sort=true dedup=true atomic_cursor=true pagination=true schema=true private_push_routing=true auto_copy_route=true active_gate=true history_isolated=true stale_completion_rejected=true synthetic=true")
    }

    private static func atomicFailure(directory: URL) throws {
        let blocked = directory.appendingPathComponent("blocked")
        let store = VerificationSMSStore(fileURL: blocked.appendingPathComponent("inbox.json"))
        try store.load()
        var autoCopy = VerificationSMSAutoCopy()
        autoCopy.restoreBaseline(from: store)
        autoCopy.setActive(true)
        autoCopy.receive(message(seq: 1, time: 1000).id, opened: false)
        try Data().write(to: blocked)
        try mustThrow("disk write failure") { try store.apply(page([message(seq: 1, time: 1000)], cursor: 1), pairingID: pairingID) }
        try check(store.afterSeq(for: pairingID) == 0 && store.messages.isEmpty, "failed save does not advance")
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == nil, "failed save cannot copy")
        try FileManager.default.removeItem(at: blocked)
        try store.apply(page([message(seq: 1, time: 1000)], cursor: 1), pairingID: pairingID)
        let restarted = VerificationSMSStore(fileURL: blocked.appendingPathComponent("inbox.json"))
        try restarted.load()
        try check(restarted.afterSeq(for: pairingID) == 1 && restarted.messages.count == 1, "retry committed")
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID)?.seq == 1, "copy only after committed retry")
    }

    private static func automaticCopy(directory: URL) throws {
        let store = VerificationSMSStore(fileURL: directory.appendingPathComponent("auto-copy.json"))
        try store.load()
        let history = message(seq: 1, time: 1000, code: "001111")
        try store.apply(page([history], cursor: 1), pairingID: pairingID)
        var autoCopy = VerificationSMSAutoCopy()
        autoCopy.restoreBaseline(from: store)
        autoCopy.setActive(true)
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == nil, "startup history never copies")
        let fresh = message(seq: 2, time: 2000, code: "002222")
        autoCopy.receive(fresh.id, opened: false)
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == nil, "route waits for exact persisted record")
        autoCopy.setActive(false)
        try store.apply(page([fresh], cursor: 2), pairingID: pairingID)
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == nil, "inactive or locked cannot copy")
        autoCopy.setActive(true)
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == fresh, "active copies notification target")
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == nil, "one write per automatic intent")
        autoCopy.receive(fresh.id, opened: false)
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == nil, "duplicate delivery cannot overwrite clipboard")

        let syncedHistory = message(seq: 3, time: 3000, code: "003333")
        try store.apply(page([syncedHistory], cursor: 3), pairingID: pairingID)
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == nil, "pull or history pagination does not copy")
        autoCopy.receive(history.id, opened: true)
        autoCopy.setActive(false)
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == nil, "notification tap waits for active")
        autoCopy.setActive(true)
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == history, "explicit old notification can copy old code")

        let older = message(seq: 4, time: 4000, code: "004444")
        let newer = message(seq: 5, time: 5000, code: "005555")
        autoCopy.receive(newer.id, opened: false)
        autoCopy.receive(older.id, opened: false)
        try store.apply(page([older, newer], cursor: 5), pairingID: pairingID)
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == newer, "concurrent routes choose greatest sequence")
        autoCopy.receive(older.id, opened: false)
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == nil, "late older completion cannot replace newer code")

        let ambiguous = message(seq: 6, time: 6000, code: nil)
        autoCopy.receive(ambiguous.id, opened: false)
        autoCopy.receive(older.id, opened: false)
        try store.apply(page([ambiguous], cursor: 6), pairingID: pairingID)
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == nil, "ambiguous new SMS never guesses or falls back")
        autoCopy.receive(ambiguous.id, opened: true)
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == nil, "ambiguous tapped SMS keeps manual body behavior")

        let awaiting = message(seq: 7, time: 7000, code: "007777")
        autoCopy.receive(awaiting.id, opened: false)
        autoCopy.receive(history.id, opened: true)
        try store.apply(page([awaiting], cursor: 7), pairingID: pairingID)
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == history, "user selection supersedes an older automatic request")
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == nil, "superseded network work cannot copy later")

        let afterManual = message(seq: 8, time: 8000, code: "008888")
        autoCopy.receive(afterManual.id, opened: false)
        autoCopy.copiedManually(syncedHistory)
        try store.apply(page([afterManual], cursor: 8), pairingID: pairingID)
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == nil, "manual copy supersedes pending requests")
        autoCopy.receive(history.id, opened: true)
        try check(autoCopy.takeCopy(from: store, pairingID: otherPairing) == nil, "pairing switch cannot copy previous pairing")
        try check(autoCopy.takeCopy(from: store, pairingID: pairingID) == nil, "discarded pairing intent does not resume")

        let reopened = VerificationSMSStore(fileURL: directory.appendingPathComponent("auto-copy.json"))
        try reopened.load()
        var relaunched = VerificationSMSAutoCopy()
        relaunched.restoreBaseline(from: reopened)
        relaunched.setActive(true)
        relaunched.receive(afterManual.id, opened: false)
        try check(relaunched.takeCopy(from: reopened, pairingID: pairingID) == nil, "relaunch baseline prevents historical repeat")
        relaunched.receive(history.id, opened: true)
        try check(relaunched.takeCopy(from: reopened, pairingID: pairingID) == history, "explicit target survives local store reopen")
    }

    private static func schema() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SMSFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = VerificationSMSClient(session: session)
        let pairing = StoredPairing(pairingID: pairingID, endpoint: "100.64.0.1", port: 47631,
            keyHex: String(repeating: "a", count: 64), providerURL: URL(string: "https://synthetic.invalid")!,
            providerToken: String(repeating: "b", count: 64))
        var requests = 0
        SMSFixtureProtocol.handler = { request in
            requests += 1
            try check(request.httpMethod == "POST", "POST")
            try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + pairing.providerToken, "existing bearer")
            let object = try JSONSerialization.jsonObject(with: requestBytes(request)) as! [String: Any]
            try check(object["pairing_id"] as? String == pairingID.uuidString.lowercased(), "JSON pairing ID")
            if request.url!.path == "/v1/sms/register" {
                try check(Set(object.keys) == ["pairing_id", "push_token", "environment"], "registration schema")
                try check(object["push_token"] as? String == "01020a" && object["environment"] as? String == "production", "ordinary token")
                return (200, Data("{\"accepted\":true}".utf8))
            }
            try check(request.url!.path == "/v1/sms/sync" && Set(object.keys) == ["pairing_id", "after_seq"], "sync schema")
            let after = object["after_seq"] as! Int64
            let messages = after == 0 ? [message(seq: 1, time: 1000)] : [message(seq: 2, time: 2000, code: nil)]
            let encodedMessages = try JSONSerialization.jsonObject(with: JSONEncoder().encode(messages))
            let payload: [String: Any] = ["messages": encodedMessages, "next_after_seq": after + 1, "has_more": after == 0]
            return (200, try JSONSerialization.data(withJSONObject: payload))
        }
        try await client.register(pairing: pairing, pushToken: Data([1, 2, 10]), environment: "production")
        var cursor: Int64 = 0
        var more: Bool
        repeat {
            let response = try await client.sync(pairing: pairing, afterSeq: cursor)
            cursor = response.nextAfterSeq; more = response.hasMore
        } while more
        try check(cursor == 2 && requests == 3, "multiple sync pages")
        SMSFixtureProtocol.handler = { _ in (403, Data("{}".utf8)) }
        do { _ = try await client.sync(pairing: pairing, afterSeq: cursor); throw Failure.failed("HTTP status accepted") }
        catch is Failure { throw Failure.failed("HTTP status accepted") }
        catch {}
        let messageID = String(repeating: "c", count: 64)
        let payload: [String: Any] = ["kind": "verification_sms", "pairing_id": pairingID.uuidString.lowercased(),
            "message_id": messageID, "aps": ["alert": ["title": "收到验证码短信", "body": "打开应用查看"]]]
        try check(VerificationSMSNotification(payload: payload)?.key.messageID == messageID, "generic notification route")
        var invalid = payload
        invalid["message_id"] = "untrusted"
        try check(VerificationSMSNotification(payload: invalid) == nil, "bad route rejected")
        let noCode = try JSONDecoder().decode(VerificationSMS.self, from: JSONEncoder().encode(message(seq: 1, time: 1000, code: nil)))
        try check(noCode.code == nil, "no client-side code guessing")
        try mustThrow("nondigit code") { _ = try message(seq: 1, time: 1000, code: "one-two").validated() }
    }

    private static func message(seq: Int64, time: Int64, code: String? = "001234", pairing: UUID = pairingID) -> VerificationSMS {
        VerificationSMS(pairingID: pairing, messageID: String(repeating: String(seq), count: 64),
            seq: seq, receivedAtMS: time, sender: "合成发件人", body: "合成验证码短信正文", code: code)
    }
    private static func requestBytes(_ request: URLRequest) throws -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { throw Failure.failed("missing JSON body") }
        stream.open()
        defer { stream.close() }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw Failure.failed("JSON body stream") }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        return bytes
    }
    private static func page(_ messages: [VerificationSMS], cursor: Int64, more: Bool = false) -> VerificationSMSPage {
        VerificationSMSPage(messages: messages, nextAfterSeq: cursor, hasMore: more)
    }
    private static func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
        if !value() { throw Failure.failed(name) }
    }
    private static func mustThrow(_ name: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw Failure.failed(name)
    }
    private enum Failure: Error { case failed(String) }
}

private final class SMSFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, bytes) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
