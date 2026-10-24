import Foundation

enum BridgeProtocolError: Error, LocalizedError {
    case invalidEndpoint, invalidKey, invalidHeader, invalidLength, invalidSequence
    case invalidMessage, invalidState, authenticationTimeout, receiveTimeout, sessionTimeout
    case connectionFailed, recoveryTimeout, microphoneDenied, audioUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "只允许 Tailscale 100.64.0.0/10 IPv4 和有效端口。"
        case .invalidKey: return "临时配对密钥必须为 64 个十六进制字符。"
        case .invalidHeader: return "协议帧头无效，桥接已停止。"
        case .invalidLength: return "协议载荷长度无效，桥接已停止。"
        case .invalidSequence: return "协议序号异常，桥接已停止。"
        case .invalidMessage: return "收到非预期协议消息，桥接已停止。"
        case .invalidState: return "电话状态不符合本次实验流程，桥接已停止。"
        case .authenticationTimeout: return "认证超时，桥接已停止。"
        case .receiveTimeout: return "超过 10 秒未收到完整帧，桥接已停止。"
        case .sessionTimeout: return "达到本次 180 秒实验限时，桥接已停止。"
        case .connectionFailed: return "网络连接结束或不可用，桥接已停止。"
        case .recoveryTimeout: return "30 秒内未恢复连接，本次通话已结束。"
        case .microphoneDenied: return "请在 iPhone 设置中允许此 App 使用麦克风。"
        case .audioUnavailable: return "音频初始化、转换或路由发生异常，桥接已停止。"
        }
    }
}

struct BridgeFrame {
    let type: UInt8
    let payload: Data
}

enum PJZCallProtocol {
    static let name = Data("PJZ-CALL/1".utf8)
    static let challenge: UInt8 = 0x01
    static let authentication: UInt8 = 0x02
    static let downlink: UInt8 = 0x10
    static let uplink: UInt8 = 0x11
    static let state: UInt8 = 0x20
    static let session: UInt8 = 0x21
    static let answer: UInt8 = 0x30
    static let resume: UInt8 = 0x31
    static let hangup: UInt8 = 0x32
    static let join: UInt8 = 0x33
    static let heartbeat: UInt8 = 0x40
    // Debug network simulation must authenticate AND identify itself before any auto-answer.
    static let simulation: UInt8 = 0x50
    static let simulationLabel = Data("PJZ-SIMULATION/1".utf8)
    static let frameSamples = 320
    static let pcmBytes = 640
    static let maxPayload = 1024

    static func callIDPayload(_ id: UUID) -> Data { Data(id.uuidString.lowercased().utf8) }

    static func decodeCallID(_ data: Data) throws -> UUID {
        guard data.count == 36, let text = String(data: data, encoding: .ascii),
              let id = UUID(uuidString: text), id.uuidString.lowercased() == text else {
            throw BridgeProtocolError.invalidMessage
        }
        return id
    }

    static func validateEndpoint(_ text: String, port: UInt16) throws -> String {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard port != 0, parts.count == 4 else { throw BridgeProtocolError.invalidEndpoint }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(part), (0...255).contains(value), String(value) == part else {
                throw BridgeProtocolError.invalidEndpoint
            }
            octets.append(value)
        }
        guard octets[0] == 100, (64...127).contains(octets[1]) else {
            throw BridgeProtocolError.invalidEndpoint
        }
        return octets.map(String.init).joined(separator: ".")
    }

    static func decodeKey(_ text: String) throws -> Data {
        let bytes = Array(text.utf8)
        guard bytes.count == 64 else { throw BridgeProtocolError.invalidKey }
        func nibble(_ value: UInt8) -> UInt8? {
            switch value {
            case 48...57: return value - 48
            case 65...70: return value - 55
            case 97...102: return value - 87
            default: return nil
            }
        }
        var decoded = Data(capacity: 32)
        for index in stride(from: 0, to: 64, by: 2) {
            guard let upper = nibble(bytes[index]), let lower = nibble(bytes[index + 1]) else {
                throw BridgeProtocolError.invalidKey
            }
            decoded.append(upper << 4 | lower)
        }
        return decoded
    }

    static func validateServerFrame(_ frame: BridgeFrame) throws {
        let required: Int
        switch frame.type {
        case challenge, session: required = 32
        case downlink: required = pcmBytes
        case state: required = 1
        case join: required = 36
        case heartbeat: required = 0
        case simulation: required = simulationLabel.count
        default: throw BridgeProtocolError.invalidMessage
        }
        guard frame.payload.count == required else { throw BridgeProtocolError.invalidLength }
        if frame.type == join { _ = try decodeCallID(frame.payload) }
    }

    static func encode(_ frame: BridgeFrame, sequence: UInt32) throws -> Data {
        guard frame.payload.count <= maxPayload else { throw BridgeProtocolError.invalidLength }
        let length = UInt16(frame.payload.count)
        var result = Data([
            frame.type, 0, UInt8(length >> 8), UInt8(length & 0xff),
            UInt8(sequence >> 24), UInt8((sequence >> 16) & 0xff),
            UInt8((sequence >> 8) & 0xff), UInt8(sequence & 0xff)
        ])
        result.append(frame.payload)
        return result
    }

    static func pcmLevel(_ data: Data) -> Double {
        guard data.count == pcmBytes else { return 0 }
        let bytes = [UInt8](data)
        var sum = 0.0
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let value = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
            let normalized = Double(value) / 32768.0
            sum += normalized * normalized
        }
        return sqrt(sum / Double(frameSamples))
    }
}

/// A receive call is bounded to 4096 bytes; partial-frame storage is independently bounded.
struct BridgeFrameParser {
    private var bytes: [UInt8] = []
    private var expectedSequence: UInt64 = 0

    mutating func append(_ data: Data) throws -> [BridgeFrame] {
        guard data.count <= 4096, bytes.count + data.count <= 8192 else {
            throw BridgeProtocolError.invalidLength
        }
        bytes.append(contentsOf: data)
        var frames: [BridgeFrame] = []
        var offset = 0
        while bytes.count - offset >= 8 {
            guard bytes[offset + 1] == 0 else { throw BridgeProtocolError.invalidHeader }
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length <= PJZCallProtocol.maxPayload else { throw BridgeProtocolError.invalidLength }
            let sequence = UInt32(bytes[offset + 4]) << 24 | UInt32(bytes[offset + 5]) << 16
                | UInt32(bytes[offset + 6]) << 8 | UInt32(bytes[offset + 7])
            guard expectedSequence <= UInt64(UInt32.max), UInt64(sequence) == expectedSequence else {
                throw BridgeProtocolError.invalidSequence
            }
            guard bytes.count - offset >= 8 + length else { break }
            frames.append(BridgeFrame(type: bytes[offset], payload: Data(bytes[(offset + 8)..<(offset + 8 + length)])))
            expectedSequence += 1
            offset += 8 + length
        }
        if offset != 0 { bytes.removeFirst(offset) }
        return frames
    }
}
