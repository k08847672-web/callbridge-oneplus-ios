import Foundation

struct VerificationSMSKey: Hashable, Codable, Sendable {
    let pairingID: UUID
    let messageID: String
}

struct VerificationSMS: Codable, Equatable, Identifiable, Sendable {
    let pairingID: UUID
    let messageID: String
    let seq: Int64
    let receivedAtMS: Int64
    let sender: String
    let body: String
    let code: String?

    var id: VerificationSMSKey { VerificationSMSKey(pairingID: pairingID, messageID: messageID) }
    var receivedAt: Date { Date(timeIntervalSince1970: Double(receivedAtMS) / 1000) }

    enum CodingKeys: String, CodingKey {
        case pairingID = "pairing_id", messageID = "message_id", seq
        case receivedAtMS = "received_at_ms", sender, body, code
    }

    func validated() throws -> Self {
        guard Self.validMessageID(messageID), seq > 0, receivedAtMS >= 0,
              code.map({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) ?? true else {
            throw VerificationSMSError.invalidResponse
        }
        return self
    }

    static func validMessageID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct VerificationSMSPage: Decodable, Sendable {
    let messages: [VerificationSMS]
    let nextAfterSeq: Int64
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case messages, nextAfterSeq = "next_after_seq", hasMore = "has_more"
    }

    func validated(pairingID: UUID, afterSeq: Int64) throws -> Self {
        var previous = afterSeq
        for message in messages {
            _ = try message.validated()
            guard message.pairingID == pairingID, message.seq > previous else {
                throw VerificationSMSError.invalidResponse
            }
            previous = message.seq
        }
        // Never advance beyond the records actually delivered to this device.
        guard nextAfterSeq == previous, !hasMore || nextAfterSeq > afterSeq else {
            throw VerificationSMSError.invalidResponse
        }
        return self
    }
}

/// APNs carries routing identifiers only. SMS data always comes from authenticated sync.
struct VerificationSMSNotification: Sendable {
    let key: VerificationSMSKey

    init?(payload: [AnyHashable: Any]) {
        guard payload["kind"] as? String == "verification_sms",
              let text = payload["pairing_id"] as? String,
              let pairingID = UUID(uuidString: text), text == pairingID.uuidString.lowercased(),
              let messageID = payload["message_id"] as? String,
              VerificationSMS.validMessageID(messageID) else { return nil }
        key = VerificationSMSKey(pairingID: pairingID, messageID: messageID)
    }
}

enum VerificationSMSError: Error {
    case invalidResponse, notLoaded, requestFailed
}

/// Messages and per-pairing cursor are one atomic, protected file, independent of notifications.
final class VerificationSMSStore {
    private struct Snapshot: Codable {
        var messages: [VerificationSMS] = []
        var cursors: [String: Int64] = [:]
    }

    private let fileURL: URL
    private var snapshot: Snapshot?
    var isLoaded: Bool { snapshot != nil }
    var messages: [VerificationSMS] {
        (snapshot?.messages ?? []).sorted {
            if $0.receivedAtMS != $1.receivedAtMS { return $0.receivedAtMS > $1.receivedAtMS }
            if $0.seq != $1.seq { return $0.seq > $1.seq }
            return $0.messageID < $1.messageID
        }
    }

    init(fileURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VerificationSMS", isDirectory: true).appendingPathComponent("inbox.json")) {
        self.fileURL = fileURL
    }

    func load() throws {
        let loaded: Snapshot
        do { loaded = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { loaded = Snapshot() }
        var keys = Set<VerificationSMSKey>()
        for message in loaded.messages {
            _ = try message.validated()
            guard keys.insert(message.id).inserted,
                  message.seq <= (loaded.cursors[message.pairingID.uuidString.lowercased()] ?? 0) else {
                throw VerificationSMSError.invalidResponse
            }
        }
        guard loaded.cursors.values.allSatisfy({ $0 >= 0 }) else { throw VerificationSMSError.invalidResponse }
        snapshot = loaded
    }

    func afterSeq(for pairingID: UUID) -> Int64 { snapshot?.cursors[pairingID.uuidString.lowercased()] ?? 0 }

    func apply(_ page: VerificationSMSPage, pairingID: UUID) throws {
        guard var next = snapshot else { throw VerificationSMSError.notLoaded }
        let cursor = afterSeq(for: pairingID)
        if page.nextAfterSeq <= cursor, let first = page.messages.first {
            guard first.seq > 0 else { throw VerificationSMSError.invalidResponse }
            _ = try page.validated(pairingID: pairingID, afterSeq: first.seq - 1)
            let existing = Dictionary(uniqueKeysWithValues: next.messages.map { ($0.id, $0) })
            guard page.messages.allSatisfy({ existing[$0.id] == $0 }) else {
                throw VerificationSMSError.invalidResponse
            }
            return // An already committed page can be retried without duplication or regression.
        }
        _ = try page.validated(pairingID: pairingID, afterSeq: cursor)
        var byID = Dictionary(uniqueKeysWithValues: next.messages.map { ($0.id, $0) })
        for message in page.messages {
            if let existing = byID[message.id] {
                guard existing == message else { throw VerificationSMSError.invalidResponse }
            } else { byID[message.id] = message; next.messages.append(message) }
        }
        next.cursors[pairingID.uuidString.lowercased()] = page.nextAfterSeq
        let bytes = try JSONEncoder().encode(next)
        let directory = fileURL.deletingLastPathComponent()
#if os(iOS)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try bytes.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
#else
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: fileURL, options: .atomic)
#endif
        // No in-memory cursor or list changes unless the entire page was saved.
        snapshot = next
    }
}

/// Only notification intents can copy. Historical sync merely makes persisted records available.
/// Owned by the inbox's main actor; no asynchronous operation retains an older copy request.
struct VerificationSMSAutoCopy {
    private var active = false
    private var restored = false
    private var automaticSequences: [UUID: Int64] = [:]
    private var deliveries = Set<VerificationSMSKey>()
    private var openedNotification: VerificationSMSKey?

    mutating func restoreBaseline(from store: VerificationSMSStore) {
        guard !restored, store.isLoaded else { return }
        for message in store.messages {
            automaticSequences[message.pairingID] = max(automaticSequences[message.pairingID] ?? 0, message.seq)
        }
        restored = true
    }

    mutating func setActive(_ value: Bool) { active = value }

    mutating func receive(_ key: VerificationSMSKey, opened: Bool) {
        if opened {
            // A user's selection supersedes pending automatic requests, including older network work.
            deliveries.removeAll()
            openedNotification = key
        } else {
            deliveries.insert(key)
        }
    }

    mutating func takeCopy(from store: VerificationSMSStore, pairingID: UUID) -> VerificationSMS? {
        guard active, restored, store.isLoaded else { return nil }
        deliveries = Set(deliveries.filter { $0.pairingID == pairingID })
        if let key = openedNotification {
            guard key.pairingID == pairingID else { openedNotification = nil; return nil }
            guard let message = store.messages.first(where: { $0.id == key }) else { return nil }
            openedNotification = nil
            automaticSequences[pairingID] = max(automaticSequences[pairingID] ?? 0, message.seq)
            return message.code == nil ? nil : message
        }
        let available = store.messages.filter { deliveries.contains($0.id) }
        guard let newest = available.max(by: { $0.seq < $1.seq }) else { return nil }
        for message in available { deliveries.remove(message.id) }
        guard newest.seq > (automaticSequences[pairingID] ?? 0) else { return nil }
        // Even a newer ambiguous SMS must not cause an older pending code to be copied later.
        automaticSequences[pairingID] = newest.seq
        return newest.code == nil ? nil : newest
    }

    mutating func copiedManually(_ message: VerificationSMS) {
        deliveries.removeAll()
        openedNotification = nil
        automaticSequences[message.pairingID] = max(automaticSequences[message.pairingID] ?? 0, message.seq)
    }
}

struct VerificationSMSClient {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func register(pairing: StoredPairing, pushToken: Data, environment: String) async throws {
        guard ["sandbox", "production"].contains(environment), !pushToken.isEmpty else {
            throw VerificationSMSError.invalidResponse
        }
        let request = try request(pairing: pairing, action: "register", values: [
            "push_token": pushToken.map { String(format: "%02x", $0) }.joined(), "environment": environment])
        struct Registration: Decodable { let accepted: Bool }
        let result = try JSONDecoder().decode(Registration.self, from: await send(request))
        guard result.accepted else { throw VerificationSMSError.requestFailed }
    }

    func sync(pairing: StoredPairing, afterSeq: Int64) async throws -> VerificationSMSPage {
        let request = try request(pairing: pairing, action: "sync", values: ["after_seq": afterSeq])
        return try JSONDecoder().decode(VerificationSMSPage.self, from: await send(request))
            .validated(pairingID: pairing.pairingID, afterSeq: afterSeq)
    }

    private func request(pairing: StoredPairing, action: String, values: [String: Any]) throws -> URLRequest {
        var values = values
        values["pairing_id"] = pairing.pairingID.uuidString.lowercased()
        let url = pairing.providerURL.appendingPathComponent("v1").appendingPathComponent("sms").appendingPathComponent(action)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + pairing.providerToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: values)
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw VerificationSMSError.requestFailed
        }
        return bytes
    }
}
