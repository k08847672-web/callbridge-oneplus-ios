import Foundation
import Network
import CryptoKit

enum BridgeStage: String {
    case connecting = "正在连接"
    case authenticating = "正在认证"
    case idle = "已连接，等待新来电"
    case ringing = "一加正在响铃"
    case active = "通话音频桥接中"
    case recovering = "连接中断，正在恢复本次通话（最多 30 秒）"
    case ending = "正在同步挂断本次通话"
}

struct NetworkStatistics {
    var receivedFrames: UInt64 = 0
    var sentFrames: UInt64 = 0
    var droppedUplink: UInt64 = 0
    var receiveLevel: Double = 0
    var sendLevel: Double = 0
}

struct NetworkPathDiagnostics {
    let status: String
    let unsatisfiedReason: String?
    let interfaces: [String]
}

enum BridgeClientEvent {
    case callID(UUID)
    case callerIdentity(CallIdentityUpdate)
    case stage(BridgeStage)
    case statistics(NetworkStatistics)
    case diagnostic(String, String?, Int?)
    case networkPath(NetworkPathDiagnostics)
    case stopped(BridgeProtocolError?)
}

/// All protocol and socket state belongs to this serial queue. No PCM or key is persisted.
final class BridgeClient {
    private var allowsLoopbackFixture = false
#if DEBUG
    /// Synthetic local integration only. The ordinary app never enables this seam.
    init(localFixture: Bool = false) { allowsLoopbackFixture = localFixture }
#endif
    var onEvent: ((UUID, BridgeClientEvent) -> Void)?
    var onDownlink: ((UUID, Data) -> Void)?
    private let queue = DispatchQueue(label: "com.doitio.callbridge.network", qos: .userInitiated)
    private var connection: NWConnection?
    private var sessionID: UUID?
    private var timer: DispatchSourceTimer?
    private var key = Data()
    private var endpoint = ""
    private var port: UInt16 = 0
    private var sessionToken = Data()
    private var requestedJoinID: UUID?
    private var announcedCallID: UUID?
    private var parser = BridgeFrameParser()
    private var stage: BridgeStage = .connecting
    private var didReceiveChallenge = false
    private var didReceiveInitialState = false
    private var didReceiveSession = false
    private var hasActiveCall = false
    private var hangupRequested = false
    private var hangupQueued = false
    private var recoveryDeadline: TimeInterval?
    private var retryAt: TimeInterval?
    private var requiresSimulation = false
    private var didReceiveSimulationMarker = false
    private var answerRequested = false
    private var sendSequence: UInt64 = 0
    private var controls: [BridgeFrame] = []
    private var audio: [(frame: BridgeFrame, time: TimeInterval)] = []
    private var sending = false
    private var lastFrameTime: TimeInterval = 0
    private var authenticationDeadline: TimeInterval?
    private var sessionDeadline: TimeInterval?
    private var lastHeartbeat: TimeInterval = 0
    private var lastStatistics: TimeInterval = 0
    private var statistics = NetworkStatistics()

    func connect(id: UUID, endpoint: String, port: UInt16, key: Data, simulation: Bool = false, callID: UUID? = nil) {
        queue.async {
            self.close(reason: nil)
            guard key.count == 32,
                  ((self.allowsLoopbackFixture && endpoint == "127.0.0.1")
                    || (try? PJZCallProtocol.validateEndpoint(endpoint, port: port)) != nil),
                  NWEndpoint.Port(rawValue: port) != nil else {
                self.onEvent?(id, .stopped(.invalidEndpoint))
                return
            }
            self.sessionID = id
            self.key = key
            self.endpoint = endpoint
            self.port = port
            self.requiresSimulation = simulation
            self.requestedJoinID = callID
            self.announcedCallID = nil
            self.didReceiveSimulationMarker = false
            self.answerRequested = false
            self.hasActiveCall = false
            self.hangupRequested = false
            self.statistics = NetworkStatistics()
            self.lastFrameTime = ProcessInfo.processInfo.systemUptime
            self.lastHeartbeat = self.lastFrameTime
            self.lastStatistics = self.lastFrameTime
            self.sessionDeadline = simulation ? self.lastFrameTime + 180 : nil
            let tick = DispatchSource.makeTimerSource(queue: self.queue)
            tick.schedule(deadline: .now() + 1, repeating: 1)
            tick.setEventHandler { [weak self] in self?.tick() }
            self.timer = tick
            tick.resume()
            self.startTransport()
        }
    }

    func disconnect() { queue.async { self.close(reason: nil) } }

    func hangUp(id: UUID) {
        queue.async {
            guard self.sessionID == id, !self.hangupRequested else { return }
            guard !self.requiresSimulation, self.hasActiveCall, self.sessionToken.count == 32 else {
                self.close(reason: nil)
                return
            }
            self.hangupRequested = true
            self.audio.removeAll(keepingCapacity: false)
            self.stage = .ending
            self.emit(.stage(.ending))
            if self.didReceiveInitialState, self.connection != nil {
                self.sendHangup()
            }
            // During recovery, AUTH and RESUME remain queued. HANGUP is sent immediately
            // after this same session is accepted, without restarting audio or ANSWER.
        }
    }

    private func startTransport() {
        guard sessionID != nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        parser = BridgeFrameParser()
        didReceiveChallenge = false
        didReceiveInitialState = false
        didReceiveSession = false
        hangupQueued = false
        sendSequence = 0
        retryAt = nil
        stage = hangupRequested ? .ending : recoveryDeadline == nil ? .connecting : .recovering
        emit(.stage(stage))
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        let socket = NWConnection(host: NWEndpoint.Host(endpoint), port: nwPort, using: parameters)
        connection = socket
        socket.stateUpdateHandler = { [weak self, weak socket] state in
            guard let self, let socket, self.connection === socket else { return }
            self.reportNetworkPath(socket.currentPath)
            switch state {
            case .ready:
                if self.recoveryDeadline == nil {
                    self.stage = .authenticating
                    self.emit(.stage(.authenticating))
                }
                self.authenticationDeadline = self.requiresSimulation ? ProcessInfo.processInfo.systemUptime + 5 : nil
                self.receive(socket)
            case .failed(let error):
                self.reportNetworkFailure(error, event: "network_failed")
                self.transportInterrupted()
            case .cancelled:
                self.reportNetworkFailure(nil, event: "network_cancelled")
                self.transportInterrupted()
            case .waiting(let error):
                self.reportNetworkFailure(error, event: "network_waiting")
                if self.hasActiveCall { self.transportInterrupted() }
            default: break
            }
        }
        socket.pathUpdateHandler = { [weak self, weak socket] path in
            guard let self, let socket, self.connection === socket else { return }
            self.reportNetworkPath(path)
            if path.status == .unsatisfied, self.hasActiveCall { self.transportInterrupted() }
        }
        socket.start(queue: queue)
    }

    private func transportInterrupted(silentSince: TimeInterval? = nil) {
        guard !requiresSimulation, hasActiveCall, sessionToken.count == 32, key.count == 32 else {
            close(reason: .connectionFailed)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if recoveryDeadline == nil {
            // A silent TCP black hole is already interrupted at its last valid frame.
            // Retries never extend this first recovery window.
            recoveryDeadline = (silentSince ?? now) + 30
            emit(.diagnostic("recovery_started", nil, nil))
        }
        closeTransport()
        stage = hangupRequested ? .ending : .recovering
        emit(.stage(stage))
        retryAt = now + 1
    }

    private func sendHangup() {
        guard !hangupQueued, didReceiveInitialState, sessionToken.count == 32 else { return }
        hangupQueued = true
        controls.removeAll(keepingCapacity: false)
        enqueueControl(BridgeFrame(type: PJZCallProtocol.hangup, payload: sessionToken))
    }

    func requestAnswer(id: UUID) {
        queue.async {
            guard self.sessionID == id, self.stage == .ringing, !self.answerRequested else { return }
            self.answerRequested = true
            self.enqueueControl(BridgeFrame(type: PJZCallProtocol.answer, payload: Data([1])))
        }
    }

    func sendMicrophone(id: UUID, pcm: Data) {
        queue.async {
            guard self.sessionID == id, self.stage == .active, !self.hangupRequested,
                  pcm.count == PJZCallProtocol.pcmBytes else { return }
            if self.audio.count == 10 {
                self.audio.removeFirst()
                self.statistics.droppedUplink += 1
            }
            self.audio.append((BridgeFrame(type: PJZCallProtocol.uplink, payload: pcm),
                               ProcessInfo.processInfo.systemUptime))
            self.pumpSend()
        }
    }

    private func receive(_ socket: NWConnection) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak socket] data, _, complete, error in
            guard let self, let socket, self.connection === socket else { return }
            do {
                if let data, !data.isEmpty {
                    let frames = try self.parser.append(data)
                    for frame in frames {
                        try PJZCallProtocol.validateServerFrame(frame)
                        self.lastFrameTime = ProcessInfo.processInfo.systemUptime
                        try self.handle(frame)
                        if self.connection !== socket { return }
                    }
                }
                guard error == nil, !complete else {
                    self.reportNetworkFailure(error, event: error == nil ? "network_eof" : "network_receive_failed")
                    self.transportInterrupted()
                    return
                }
                self.receive(socket)
            } catch {
                self.close(reason: (error as? BridgeProtocolError) ?? .invalidMessage)
            }
        }
    }

    private func handle(_ frame: BridgeFrame) throws {
        if !didReceiveChallenge {
            guard frame.type == PJZCallProtocol.challenge,
                  stage == .authenticating || recoveryDeadline != nil else {
                throw BridgeProtocolError.invalidMessage
            }
            didReceiveChallenge = true
            var message = PJZCallProtocol.name
            message.append(frame.payload)
            if !requiresSimulation { message.append(PJZCallProtocol.callerIdentityCapability) }
            var tag = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
            if !requiresSimulation { tag.append(PJZCallProtocol.callerIdentityCapability) }
            if requiresSimulation {
                key.resetBytes(in: 0..<key.count)
                key.removeAll(keepingCapacity: false)
            }
            enqueueControl(BridgeFrame(type: PJZCallProtocol.authentication, payload: tag))
            if recoveryDeadline != nil {
                enqueueControl(BridgeFrame(type: PJZCallProtocol.resume, payload: sessionToken))
            } else if let id = requestedJoinID {
                enqueueControl(BridgeFrame(type: PJZCallProtocol.join, payload: PJZCallProtocol.callIDPayload(id)))
            }
            return
        }
        guard frame.type != PJZCallProtocol.challenge else { throw BridgeProtocolError.invalidMessage }
        if frame.type == PJZCallProtocol.callerIdentity {
            let update = try CallIdentityUpdate(payload: frame.payload)
            guard !requiresSimulation, announcedCallID == update.callID || requestedJoinID == update.callID else {
                throw BridgeProtocolError.invalidState
            }
            emit(.callerIdentity(update))
            return
        }
        if frame.type == PJZCallProtocol.join {
            guard !requiresSimulation, recoveryDeadline == nil else { throw BridgeProtocolError.invalidState }
            let id = try PJZCallProtocol.decodeCallID(frame.payload)
            if let expected = requestedJoinID, expected != id { throw BridgeProtocolError.invalidState }
            if let existing = announcedCallID, existing != id { throw BridgeProtocolError.invalidState }
            if announcedCallID == nil { announcedCallID = id; emit(.callID(id)) }
            return
        }
        if requestedJoinID != nil, announcedCallID == requestedJoinID, !didReceiveSession,
           frame.type == PJZCallProtocol.state, frame.payload.first == 0 {
            close(reason: nil) // JOIN matched no currently ringing original call; never ANSWER.
            return
        }
        if requiresSimulation && !didReceiveSimulationMarker {
            guard frame.type == PJZCallProtocol.simulation,
                  frame.payload == PJZCallProtocol.simulationLabel else { throw BridgeProtocolError.invalidState }
            didReceiveSimulationMarker = true
            return
        }
        if !requiresSimulation && !didReceiveSession {
            guard frame.type == PJZCallProtocol.session else { throw BridgeProtocolError.invalidState }
            if requestedJoinID != nil, recoveryDeadline == nil, announcedCallID != requestedJoinID {
                throw BridgeProtocolError.invalidState
            }
            if sessionToken.isEmpty { sessionToken = frame.payload }
            else if sessionToken != frame.payload { throw BridgeProtocolError.invalidState }
            didReceiveSession = true
            return
        }
        if !didReceiveInitialState {
            let resuming = recoveryDeadline != nil
            if resuming, hangupRequested, frame.type == PJZCallProtocol.state, frame.payload.first == 0 {
                close(reason: nil) // Same authenticated SESSION already confirms this call ended.
                return
            }
            let joining = !resuming && requestedJoinID != nil
            guard frame.type == PJZCallProtocol.state, frame.payload.first == (resuming ? 2 : joining ? 1 : 0) else {
                throw BridgeProtocolError.invalidState
            }
            didReceiveInitialState = true
            authenticationDeadline = nil
            if requiresSimulation { sessionDeadline = ProcessInfo.processInfo.systemUptime + 180 }
            if hangupRequested { sendHangup(); return }
            recoveryDeadline = nil
            if resuming { emit(.diagnostic("recovery_succeeded", nil, nil)) }
            stage = resuming ? .active : joining ? .ringing : .idle
            emit(.stage(stage))
            return
        }
        if hangupRequested {
            if frame.type == PJZCallProtocol.state, frame.payload.first == 0 { close(reason: nil) }
            return
        }
        switch frame.type {
        case PJZCallProtocol.state:
            switch frame.payload.first {
            case 0:
                if stage == .ringing || stage == .active {
                    close(reason: nil) // The call ended; never carry this connection into another call.
                } else if stage != .idle { throw BridgeProtocolError.invalidState }
            case 1:
                guard stage == .idle || stage == .ringing else { throw BridgeProtocolError.invalidState }
                if requiresSimulation, stage == .idle {
                    sessionDeadline = ProcessInfo.processInfo.systemUptime + 180
                }
                stage = .ringing
                emit(.stage(.ringing))
            case 2:
                guard stage == .ringing || stage == .active else { throw BridgeProtocolError.invalidState }
                if stage != .active {
                    hasActiveCall = true
                    stage = .active
                    if requiresSimulation { sessionDeadline = ProcessInfo.processInfo.systemUptime + 180 }
                    emit(.stage(.active))
                }
            default: throw BridgeProtocolError.invalidState
            }
        case PJZCallProtocol.downlink:
            guard stage == .active, let id = sessionID else { throw BridgeProtocolError.invalidState }
            statistics.receivedFrames += 1
            statistics.receiveLevel = PJZCallProtocol.pcmLevel(frame.payload)
            onDownlink?(id, frame.payload)
        case PJZCallProtocol.heartbeat: break // Heartbeats are not echoed.
        default: throw BridgeProtocolError.invalidMessage
        }
    }

    private func enqueueControl(_ frame: BridgeFrame) {
        if frame.type == PJZCallProtocol.heartbeat,
           controls.contains(where: { $0.type == PJZCallProtocol.heartbeat }) { return }
        guard controls.count < 8 else { close(reason: .connectionFailed); return }
        controls.append(frame)
        pumpSend()
    }

    private func pumpSend() {
        guard !sending, let socket = connection else { return }
        let now = ProcessInfo.processInfo.systemUptime
        while let first = audio.first, now - first.time > 0.2 {
            audio.removeFirst()
            statistics.droppedUplink += 1
        }
        let frame: BridgeFrame
        if !controls.isEmpty { frame = controls.removeFirst() }
        else if !audio.isEmpty { frame = audio.removeFirst().frame }
        else { return }
        guard sendSequence <= UInt64(UInt32.max),
              let encoded = try? PJZCallProtocol.encode(frame, sequence: UInt32(sendSequence)) else {
            close(reason: .invalidSequence)
            return
        }
        sendSequence += 1
        sending = true
        socket.send(content: encoded, completion: .contentProcessed { [weak self, weak socket] error in
            guard let self, let socket, self.connection === socket else { return }
            self.sending = false
            guard error == nil else {
                self.reportNetworkFailure(error, event: "network_send_failed")
                self.transportInterrupted()
                return
            }
            if frame.type == PJZCallProtocol.uplink {
                self.statistics.sentFrames += 1
                self.statistics.sendLevel = PJZCallProtocol.pcmLevel(frame.payload)
            }
            if frame.type == PJZCallProtocol.hangup {
                self.emit(.diagnostic("hangup_sent", nil, nil))
                // TCP enqueue completion is not acknowledgement of the remote hangup.
                // Keep the token until STATE idle confirms it or recovery expires.
            }
            self.pumpSend()
        })
    }

    private func tick() {
        guard sessionID != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let deadline = recoveryDeadline, now >= deadline {
            close(reason: .recoveryTimeout)
        } else if let retry = retryAt, now >= retry, connection == nil {
            emit(.diagnostic("recovery_attempt", nil, nil))
            startTransport()
        } else if let deadline = authenticationDeadline, now > deadline {
            close(reason: .authenticationTimeout)
        } else if let deadline = sessionDeadline, now > deadline {
            close(reason: .sessionTimeout)
        } else if requiresSimulation && now - lastFrameTime > 10 {
            close(reason: .receiveTimeout)
        } else if !requiresSimulation, hasActiveCall, recoveryDeadline == nil,
                  now - lastFrameTime >= 4 {
            emit(.diagnostic("network_silent", nil, nil))
            transportInterrupted(silentSince: lastFrameTime)
        } else {
            if didReceiveInitialState, !hangupRequested, recoveryDeadline == nil, now - lastHeartbeat >= 2 {
                lastHeartbeat = now
                enqueueControl(BridgeFrame(type: PJZCallProtocol.heartbeat, payload: Data()))
            }
            if now - lastStatistics >= 1 {
                lastStatistics = now
                emit(.statistics(statistics))
            }
        }
    }

    private func reportNetworkFailure(_ error: Error?, event: String) {
        let value = error.map { $0 as NSError }
        emit(.diagnostic(event, value?.domain, value?.code))
    }

    private func reportNetworkPath(_ path: NWPath?) {
        guard let path else {
            emit(.networkPath(NetworkPathDiagnostics(status: "unavailable", unsatisfiedReason: nil, interfaces: [])))
            return
        }
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requiresConnection"
        @unknown default: status = "unknown"
        }
        var reason: String?
        if path.status == .unsatisfied {
            switch path.unsatisfiedReason {
            case .notAvailable: reason = "notAvailable"
            case .cellularDenied: reason = "cellularDenied"
            case .wifiDenied: reason = "wifiDenied"
            case .localNetworkDenied: reason = "localNetworkDenied"
            case .vpnInactive: reason = "vpnInactive"
            @unknown default: reason = "unknown"
            }
        }
        let types: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wiredEthernet"),
            (.loopback, "loopback"), (.other, "other")
        ]
        let interfaces = types.compactMap { path.usesInterfaceType($0.0) ? $0.1 : nil }
        emit(.networkPath(NetworkPathDiagnostics(status: status, unsatisfiedReason: reason, interfaces: interfaces)))
    }

    private func emit(_ event: BridgeClientEvent) {
        if let id = sessionID { onEvent?(id, event) }
    }

    private func close(reason: BridgeProtocolError?) {
        let id = sessionID
        sessionID = nil
        timer?.cancel()
        timer = nil
        closeTransport()
        key.resetBytes(in: 0..<key.count)
        key.removeAll(keepingCapacity: false)
        sessionToken.resetBytes(in: 0..<sessionToken.count)
        sessionToken.removeAll(keepingCapacity: false)
        requestedJoinID = nil
        announcedCallID = nil
        endpoint = ""
        port = 0
        hasActiveCall = false
        hangupRequested = false
        recoveryDeadline = nil
        retryAt = nil
        authenticationDeadline = nil
        sessionDeadline = nil
        if let id {
            onEvent?(id, .statistics(statistics))
            onEvent?(id, .stopped(reason))
        }
    }

    private func closeTransport() {
        connection?.stateUpdateHandler = nil
        connection?.pathUpdateHandler = nil
        connection?.cancel()
        connection = nil
        parser = BridgeFrameParser()
        audio.removeAll(keepingCapacity: false)
        controls.removeAll(keepingCapacity: false)
        sending = false
        didReceiveInitialState = false
        authenticationDeadline = nil
    }
}
