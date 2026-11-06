import Foundation
import Security
import CryptoKit

// Explicit empty private directory only. Never prints or puts secrets in argv or clipboard.
@main
enum PrepareCallBridgePairing {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2 else { throw NSError(domain: "Pairing", code: 1) }
        let endpoint = try PJZCallProtocol.validateEndpoint(arguments[0], port: 47631)
        var simulation = false
        var providerURL: String?
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--simulation": simulation = true; index += 1
            case "--provider-url":
                guard index + 1 < arguments.count, providerURL == nil,
                      let url = URL(string: arguments[index + 1]),
                      ["http", "https"].contains(url.scheme), url.host != nil,
                      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                    throw NSError(domain: "Pairing", code: 5)
                }
                providerURL = arguments[index + 1]; index += 2
            default: throw NSError(domain: "Pairing", code: 1)
            }
        }
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard arguments[1].hasPrefix("/"), attributes[.type] as? FileAttributeType == .typeDirectory,
              try manager.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw NSError(domain: "Pairing", code: 2)
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        func randomHex() throws -> String {
            var random = [UInt8](repeating: 0, count: 32)
            guard random.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else {
                throw NSError(domain: "Pairing", code: 3)
            }
            defer { _ = random.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
            return random.map { String(format: "%02x", $0) }.joined()
        }
        let key = try randomHex(), providerToken = try randomHex()
        let pairingID = UUID().uuidString.lowercased()
        var android = "bindAddress=\(endpoint)\nport=47631\npairingKey=\(key)\nallowAnswer=\(!simulation)\npairingId=\(pairingID)\n"
        var iphone: [String: Any] = [
            "pairing_id": pairingID, "endpoint": endpoint, "port": 47631, "pairingKey": key,
            "simulation": simulation
        ]
        var files: [(String, Data)] = []
        if let providerURL {
            android += "providerUrl=\(providerURL)\nproviderToken=\(providerToken)\n"
            iphone["providerURL"] = providerURL; iphone["providerToken"] = providerToken
            let digest = SHA256.hash(data: Data(providerToken.utf8)).map { String(format: "%02x", $0) }.joined()
            files.append(("provider-pair.json", try JSONSerialization.data(withJSONObject: [
                "pairing_id": pairingID, "provider_token_hash": digest
            ], options: [.prettyPrinted, .sortedKeys])))
        }
        files.append(("android.properties", Data(android.utf8)))
        files.append(("CallBridgePairing.plist", try PropertyListSerialization.data(fromPropertyList: iphone, format: .binary, options: 0)))
        for (name, payload) in files {
            guard manager.createFile(atPath: directory.appendingPathComponent(name).path, contents: payload,
                                     attributes: [.posixPermissions: 0o600]) else { throw NSError(domain: "Pairing", code: 4) }
        }
        print("Private pairing files generated; pairing import and saved pairing have no automatic expiry")
    }
}
