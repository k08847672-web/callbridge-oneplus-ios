import Foundation
import Security

struct StoredPairing: Codable, Equatable {
    let pairingID: UUID
    let endpoint: String
    let port: UInt16
    let keyHex: String
    let providerURL: URL
    let providerToken: String

    func validated() throws -> StoredPairing {
        _ = try PJZCallProtocol.validateEndpoint(endpoint, port: port)
        _ = try PJZCallProtocol.decodeKey(keyHex)
        _ = try PJZCallProtocol.decodeKey(providerToken)
        guard ["https", "http"].contains(providerURL.scheme?.lowercased() ?? ""),
              providerURL.host != nil, providerURL.user == nil, providerURL.password == nil,
              providerURL.query == nil, providerURL.fragment == nil else { throw IncomingCallError.missingPairing }
        return self
    }
}

/// One device pairing, kept locally after first unlock. The import file's ten-minute
/// delivery window is not a lifetime for the saved pairing or for a normal phone call.
final class PairingStore {
    private let service = (Bundle.main.bundleIdentifier ?? "CallBridge") + ".pairing"
    private let account = "paired-device"

    func load() throws -> StoredPairing? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw StoreError.keychain(status) }
        return try JSONDecoder().decode(StoredPairing.self, from: data).validated()
    }

    func save(_ pairing: StoredPairing) throws {
        let data = try JSONEncoder().encode(pairing.validated())
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = identity
            attributes.forEach { query[$0.key] = $0.value }
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    enum StoreError: Error { case keychain(OSStatus) }
}
