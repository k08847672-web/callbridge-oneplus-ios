import Foundation
import CryptoKit

/// Standalone pure-protocol regression. Synthetic bytes only; no device/network/audio access.
@main
struct ProtocolSelfTests {
    static func main() throws {
        var assertions = 0
        func check(_ value: Bool, _ label: String) throws {
            assertions += 1
            if !value { throw TestFailure(label: label) }
        }
        func rejects(_ label: String, _ body: () throws -> Void) throws {
            var didThrow = false
            do { try body() } catch { didThrow = true }
            try check(didThrow, label)
        }
        let challenge = BridgeFrame(type: PJZCallProtocol.challenge, payload: Data(repeating: 0x5a, count: 32))
        let first = try PJZCallProtocol.encode(challenge, sequence: 0)
        let second = try PJZCallProtocol.encode(BridgeFrame(type: PJZCallProtocol.state, payload: Data([0])), sequence: 1)
        try check(Array(first.prefix(8)) == [1, 0, 0, 32, 0, 0, 0, 0], "big-endian header")
        var fragmented = BridgeFrameParser()
        var frames: [BridgeFrame] = []
        let stream = first + second
        for byte in stream { frames.append(contentsOf: try fragmented.append(Data([byte]))) }
        try check(frames.count == 2 && frames[0].payload == challenge.payload && frames[1].payload == Data([0]), "fragmented stream")
        var coalesced = BridgeFrameParser()
        try check(try coalesced.append(stream).count == 2, "coalesced stream")
        try rejects("reserved byte") {
            var invalid = first; invalid[1] = 1
            var parser = BridgeFrameParser(); _ = try parser.append(invalid)
        }
        try rejects("oversize header") {
            var parser = BridgeFrameParser(); _ = try parser.append(Data([1, 0, 4, 1, 0, 0, 0, 0]))
        }
        try rejects("out-of-order sequence") {
            var parser = BridgeFrameParser(); _ = try parser.append(second)
        }
        try rejects("replayed sequence") {
            var parser = BridgeFrameParser(); _ = try parser.append(first + first)
        }
        try rejects("receive bound") {
            var parser = BridgeFrameParser(); _ = try parser.append(Data(repeating: 0, count: 4097))
        }
        try rejects("direction pin") {
            try PJZCallProtocol.validateServerFrame(BridgeFrame(type: PJZCallProtocol.uplink, payload: Data(repeating: 0, count: 640)))
        }
        try rejects("PCM length") {
            try PJZCallProtocol.validateServerFrame(BridgeFrame(type: PJZCallProtocol.downlink, payload: Data(repeating: 0, count: 639)))
        }
        try PJZCallProtocol.validateServerFrame(BridgeFrame(type: PJZCallProtocol.simulation, payload: PJZCallProtocol.simulationLabel))
        try rejects("simulation marker length") {
            try PJZCallProtocol.validateServerFrame(BridgeFrame(type: PJZCallProtocol.simulation, payload: Data([1])))
        }
        let callID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let identity = try JSONSerialization.data(withJSONObject: ["call_id": callID.uuidString.lowercased(),
            "caller_name": "合成联系人", "caller_number": "+12025550100"])
        try PJZCallProtocol.validateServerFrame(BridgeFrame(type: PJZCallProtocol.callerIdentity, payload: identity))
        let decodedIdentity = try CallIdentityUpdate(payload: identity)
        try check(PJZCallProtocol.callerIdentity == 0x22 && decodedIdentity.callID == callID
                  && decodedIdentity.caller.name == "合成联系人", "identity frame contract")
        try rejects("identity cannot omit call ID") { _ = try CallIdentityUpdate(payload: Data("{}".utf8)) }
        try rejects("identity retains 1024 byte limit") { _ = try CallIdentityUpdate(payload: Data(repeating: 0, count: 1025)) }
        try check(try PJZCallProtocol.validateEndpoint("100.64.0.1", port: 47631) == "100.64.0.1", "lower Tailscale boundary")
        try check(try PJZCallProtocol.validateEndpoint("100.127.255.254", port: 1) == "100.127.255.254", "upper Tailscale boundary")
        for rejected in ["100.63.255.255", "100.128.0.1", "192.168.1.1", "example.com", "0100.64.0.1", "100.64.0.256", "100.64.0"] {
            try rejects("endpoint rejection") { _ = try PJZCallProtocol.validateEndpoint(rejected, port: 47631) }
        }
        try rejects("zero port") { _ = try PJZCallProtocol.validateEndpoint("100.64.0.1", port: 0) }
        let syntheticKey = try PJZCallProtocol.decodeKey(String(repeating: "ab", count: 32))
        try check(syntheticKey.count == 32 && syntheticKey.allSatisfy({ $0 == 0xab }), "hex decoding")
        try rejects("short key") { _ = try PJZCallProtocol.decodeKey("00") }
        try rejects("nonhex key") { _ = try PJZCallProtocol.decodeKey(String(repeating: "xy", count: 32)) }
        // RFC 4231 test case 1 checks CryptoKit HMAC-SHA256 without using a real pairing key.
        let tag = HMAC<SHA256>.authenticationCode(for: Data("Hi There".utf8), using: SymmetricKey(data: Data(repeating: 0x0b, count: 20)))
        try check(tag.map { String(format: "%02x", $0) }.joined() == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", "HMAC vector")
        let pairingFixture = Data((0..<32).map(UInt8.init))
        let challengeFixture = Data((32..<64).map(UInt8.init))
        let pairingTag = HMAC<SHA256>.authenticationCode(for: PJZCallProtocol.name + challengeFixture,
                                                        using: SymmetricKey(data: pairingFixture))
        try check(pairingTag.map { String(format: "%02x", $0) }.joined()
                  == "4d5e886a5c05ab83e912801e2c699d055caa6947e419a007cbebe00f66f1847e", "PJZ label cross-language fixture")
        let capabilityMessage = PJZCallProtocol.name + challengeFixture + Data([PJZCallProtocol.callerIdentityCapability])
        let capabilityTag = Data(HMAC<SHA256>.authenticationCode(for: capabilityMessage, using: SymmetricKey(data: pairingFixture)))
        try check(capabilityTag != Data(pairingTag) && capabilityTag.count == 32 && PJZCallProtocol.callerIdentityCapability == 1,
                  "caller capability is authenticated and legacy authentication is unchanged")
        try check(PJZCallProtocol.pcmLevel(Data(repeating: 0, count: 640)) == 0, "silence level")
        var negativeFullScale = Data()
        for _ in 0..<320 { negativeFullScale.append(contentsOf: [0, 128]) }
        try check(PJZCallProtocol.pcmLevel(negativeFullScale) == 1, "PCM16LE signed level")
        print("PJZ-CALL/1 pure protocol: \(assertions) assertions passed (synthetic data only)")
    }
}

private struct TestFailure: Error { let label: String }
