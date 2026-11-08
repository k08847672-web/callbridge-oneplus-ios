import Foundation
import Network
import CryptoKit

/// Real BridgeClient and authenticated loopback frames; no phone, APNs, CallKit or audio.
@main
struct CallerIdentityClientSelfTests {
    static func main() throws {
        for mode in ["join", "foreground", "wrong_call"] { try run(mode) }
        print("CALLER_IDENTITY_CLIENT passed=true authenticated_capability=true same_call_updates=true other_call_rejected=true synthetic=true")
    }

    private static func run(_ mode: String) throws {
        let fixture = try Fixture(mode: mode)
        defer { fixture.close() }
        let client = BridgeClient(localFixture: true)
        defer { client.disconnect() }
        let transport = UUID()
        let done = DispatchSemaphore(value: 0)
        var events: [String] = []
        var updates: [CallIdentityUpdate] = []
        var error: BridgeProtocolError?
        client.onEvent = { id, event in
            guard id == transport else { return }
            switch event {
            case .callID: events.append("call_id")
            case .callerIdentity(let update): updates.append(update); events.append("identity")
            case .stage(.idle): events.append("idle")
            case .stage(.ringing): events.append("ringing")
            case .stopped(let reason): error = reason; events.append("stopped"); done.signal()
            default: break
            }
        }
        client.connect(id: transport, endpoint: "127.0.0.1", port: fixture.port,
                       key: Fixture.key, callID: mode == "foreground" ? nil : Fixture.callID)
        guard done.wait(timeout: .now() + 10) == .success else { throw Failure.failed("timeout") }
        guard fixture.authenticated else { throw Failure.failed("capability HMAC") }
        if mode == "wrong_call" {
            guard case .invalidState? = error, updates.isEmpty else { throw Failure.failed("other call identity") }
        } else {
            let expected = (mode == "foreground" ? ["idle"] : [])
                + ["call_id", "identity", "ringing", "identity", "stopped"]
            guard error == nil, events == expected, updates.count == 2,
                  updates.allSatisfy({ $0.callID == Fixture.callID }),
                  updates[0].caller.displayName == "+12025550100",
                  updates[1].caller.displayName == "合成联系人" else { throw Failure.failed("identity order") }
        }
    }

    private final class Fixture {
        static let key = Data(repeating: 0x5a, count: 32)
        static let challenge = Data(repeating: 0x6b, count: 32)
        static let callID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let listener: NWListener
        let queue = DispatchQueue(label: "callbridge.caller.fixture")
        var socket: NWConnection?
        var parser = BridgeFrameParser()
        var sequence: UInt32 = 0
        var authenticated = false
        let mode: String
        var port: UInt16 { listener.port!.rawValue }

        init(mode: String) throws {
            self.mode = mode
            listener = try NWListener(using: .tcp, on: .any)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                switch state { case .ready, .failed: ready.signal(); default: break }
            }
            listener.newConnectionHandler = { [weak self] socket in
                guard let self else { socket.cancel(); return }
                self.socket = socket
                socket.stateUpdateHandler = { [weak self] state in
                    guard let self, case .ready = state else { return }
                    self.send([BridgeFrame(type: PJZCallProtocol.challenge, payload: Self.challenge)])
                    self.receive(socket)
                }
                socket.start(queue: self.queue)
            }
            listener.start(queue: queue)
            guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else { throw Failure.failed("listen") }
        }

        func close() { socket?.cancel(); listener.cancel() }

        func send(_ frames: [BridgeFrame]) {
            do {
                var data = Data()
                for frame in frames { data.append(try PJZCallProtocol.encode(frame, sequence: sequence)); sequence += 1 }
                socket?.send(content: data, completion: .contentProcessed { _ in })
            } catch { socket?.cancel() }
        }

        func receive(_ socket: NWConnection) {
            socket.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
                guard let self else { return }
                do {
                    if let data {
                        for frame in try self.parser.append(data) {
                            if !self.authenticated {
                                let message = PJZCallProtocol.name + Self.challenge + Data([1])
                                let tag = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Self.key))) + Data([1])
                                guard frame.type == PJZCallProtocol.authentication, frame.payload == tag else { throw Failure.failed("AUTH33") }
                                self.authenticated = true
                                if self.mode == "foreground" { try self.invite() }
                            } else if frame.type == PJZCallProtocol.join {
                                guard frame.payload == PJZCallProtocol.callIDPayload(Self.callID) else { throw Failure.failed("JOIN") }
                                try self.invite()
                            }
                        }
                    }
                    if !complete && error == nil { self.receive(socket) }
                } catch { socket.cancel() }
            }
        }

        func invite() throws {
            let id = mode == "wrong_call" ? UUID(uuidString: "00000000-0000-4000-8000-000000000002")! : Self.callID
            func identity(name: String?) throws -> BridgeFrame {
                var value = ["call_id": id.uuidString.lowercased(), "caller_number": "+12025550100"]
                value["caller_name"] = name
                return BridgeFrame(type: PJZCallProtocol.callerIdentity, payload: try JSONSerialization.data(withJSONObject: value))
            }
            let join = BridgeFrame(type: PJZCallProtocol.join, payload: PJZCallProtocol.callIDPayload(Self.callID))
            let session = BridgeFrame(type: PJZCallProtocol.session, payload: Data(repeating: 0x7c, count: 32))
            var frames = mode == "foreground"
                ? [session, BridgeFrame(type: PJZCallProtocol.state, payload: Data([0])), join] : [join, session]
            frames += [try identity(name: nil), BridgeFrame(type: PJZCallProtocol.state, payload: Data([1])),
                       try identity(name: "合成联系人"), BridgeFrame(type: PJZCallProtocol.state, payload: Data([0]))]
            send(frames)
        }
    }
    private enum Failure: Error { case failed(String) }
}
