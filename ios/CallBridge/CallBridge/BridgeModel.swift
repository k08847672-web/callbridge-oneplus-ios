import SwiftUI
import AVFoundation
import UIKit

@MainActor
final class BridgeModel: ObservableObject {
    @Published var endpoint = ""
    @Published var port = "47631"
    @Published var temporaryKey = ""
    @Published var speakerphone = false
    @Published private(set) var status = "未连接"
    @Published private(set) var stage: BridgeStage?
    @Published private(set) var connected = false
    @Published private(set) var requestingPermission = false
    @Published private(set) var answerRequested = false
    @Published private(set) var audioRunning = false
    @Published private(set) var networkStatistics = NetworkStatistics()
    @Published private(set) var audioStatistics = AudioStatistics()
    @Published private(set) var simulatedTest = false
    @Published private(set) var networkSimulation = false
    private let client = BridgeClient()
    private let audio = CallAudio()
    private let systemCall = SystemCallController()
    private let pairingStore = PairingStore()
    private let push = VoIPPushController()
    private var pushToken: Data?
    private var remoteCallID: UUID?
    private var connectionPairingID: UUID?
    private var joiningIncoming = false
    private var callerIdentity = CallIdentityState()
    private lazy var incoming = IncomingCallCoordinator(loadPairing: { [weak self] id in
        guard let pairing = try self?.pairingStore.load(), pairing.pairingID == id else {
            throw IncomingCallError.missingPairing
        }
        return pairing
    }, reportIncoming: { [weak self] id, caller, completion in
        self?.prepareIncomingReport(id: id, caller: caller, completion: completion)
    }, updateCaller: { [weak self] id, caller in
        self?.updateCaller(id: id, caller: caller, direct: false)
    }, join: { [weak self] invitation, pairing in
        self?.joinIncoming(invitation, pairing: pairing)
    }, end: { [weak self] id in
        guard let self, self.systemCallID == id else { return }
        self.disconnect(message: "本次来电已结束或无法连接，未接听其他电话。")
    })
    private var systemCallID: UUID?
    private var systemAudioActive = false
    private var requestedMicrophoneMuted = false
    private var sessionID: UUID?
    private var foreground = true
    private var lastDiagnosticTime: TimeInterval = 0
    private var audioStarting = false
    private var endingCall = false
    private var hangupBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var diagnosticErrorEvent: String?
    private var diagnosticErrorDomain: String?
    private var diagnosticErrorCode: Int?
    private var diagnosticNetworkPath: NetworkPathDiagnostics?
#if DEBUG
    private let selfTestRequested = ProcessInfo.processInfo.arguments.contains("--audio-self-test")
    private var localFixtureBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var scheduledLocalCall: DispatchWorkItem?
    private let acousticSelfTestRequested = ProcessInfo.processInfo.arguments.contains("--audio-acoustic-self-test")
    private var acousticProbe = LocalAcousticProbe()
    private var selfTestWasStarted = false
    private var selfTestID: UUID?
    private var selfTestTimer: Timer?
    private var selfTestDeadline: TimeInterval = 0
    private var selfTestNonzeroFrames: UInt64 = 0
    private var callKitSelfTestActive = false
    private var selfTestDuration: TimeInterval = 10
    private let networkTestRequested = ProcessInfo.processInfo.arguments.contains("--network-self-test")
    private var simulationPairing = false
    private var networkTestWasStarted = false
    private var networkTestActive = false
    private var networkTestAnswerCount = 0
    private var networkTestActiveTime: TimeInterval = 0
    private let expectsTestDisconnect = ProcessInfo.processInfo.arguments.contains("--expect-network-disconnect")
#endif

    init() {
#if DEBUG
        if (selfTestRequested || networkTestRequested),
           ProcessInfo.processInfo.arguments.contains("--audio-self-test-speaker") {
            speakerphone = true
        }
#endif
        systemCall.onDiagnostic = { [weak self] event, domain, code in
            self?.recordDiagnostic(event, domain: domain, code: code)
        }
        let audioBridge = audio
        client.onEvent = { [weak self] id, event in
            // Preserve the serial protocol order (JOIN identity before ringing) when
            // crossing to the UI actor, including frames received in one TCP read.
            DispatchQueue.main.async { self?.handle(id: id, event: event) }
        }
        client.onDownlink = { id, pcm in
            // The client only dispatches downlink after an authenticated active state.
            audioBridge.enqueueDownlink(id: id, pcm: pcm)
        }
        systemCall.onAnswer = { [weak self] id, deadline, completion in
            guard let self else { completion(false); return }
            if self.incoming.current?.callID == id {
                self.incoming.requestAnswer(callID: id, deadline: deadline) { [weak self] ready in
                    completion(ready && (self?.prepareSystemAnswer(id: id) ?? false))
                }
            } else { completion(self.prepareSystemAnswer(id: id)) }
        }
        systemCall.onAudioActivated = { [weak self] id in
            guard let self, let bridgeID = self.sessionID, self.systemCallID == id, self.answerRequested, !self.endingCall,
                  !self.systemAudioActive else { return }
            self.systemAudioActive = true
            self.diagnostic("callkit_audio_activated")
#if DEBUG
            if self.callKitSelfTestActive, self.simulatedTest, self.selfTestID == id {
                self.endLocalFixtureBackgroundTask()
                self.startLocalTestPlayback(id: id)
                return
            }
#endif
            self.startAudio(id: bridgeID)
        }
        systemCall.onEnded = { [weak self] id, explicitEndAction in
            guard let self, self.systemCallID == id else { return }
            if explicitEndAction { self.endCall() }
            else if !self.endingCall { self.disconnect(message: "系统通话异常结束，桥接已停止。") }
        }
        systemCall.onMuted = { [weak self] id, muted in
            guard let self, self.systemCallID == id else { return }
            self.requestedMicrophoneMuted = muted
            self.audio.setMicrophoneMuted(muted)
            self.diagnostic("callkit_microphone_muted=\(muted)")
        }
    }

    func startPushRegistration() {
        push.onIncoming = { [weak self] payload, completion in
            guard let self else { completion(); return }
            self.receiveIncomingPayload(payload, completion: completion)
        }
        push.onToken = { [weak self] token in self?.pushToken = token; self?.registerPushToken() }
        push.start()
    }

    /// Shared entry for PushKit and explicitly injected synthetic test events.
    func receiveIncomingPayload(_ payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        guard let invitation = try? CallInvitation(payload: payload) else {
            // Even an unusable VoIP delivery is reported promptly, then ended. No network
            // authentication or device control is attempted for a malformed invitation.
            let id = UUID()
            systemCall.reportIncoming(id: id, simulated: false) { [weak self] success in
                if success { self?.systemCall.end(id: id, failed: true) }
                completion()
            }
            return
        }
        incoming.receive(invitation, completion: completion)
    }

    private func prepareIncomingReport(id: UUID, caller: CallerIdentity, completion: @escaping (Bool) -> Void) {
        if systemCallID == id { updateCaller(id: id, caller: caller, direct: false); completion(true); return }
        guard systemCallID == nil, !connected || stage == .idle else { completion(false); return }
        if !connected {
            sessionID = id
            connected = true
            answerRequested = false
            audioRunning = false
            audioStarting = false
            endingCall = false
            stage = .connecting
        }
        remoteCallID = id
        systemCallID = id
        joiningIncoming = true
        status = "收到来电，正在连接本次原通话。"
        updateCaller(id: id, caller: caller, direct: false)
        systemCall.reportIncoming(id: id, simulated: false, caller: callerIdentity.caller, completion: completion)
    }

    private func updateCaller(id: UUID, caller: CallerIdentity, direct: Bool) {
        guard systemCallID == nil || systemCallID == id else { return }
        callerIdentity.update(callID: id, caller: caller, direct: direct)
        systemCall.updateCaller(id: id, caller: callerIdentity.caller)
    }

    private func joinIncoming(_ invitation: CallInvitation, pairing: StoredPairing) {
        guard systemCallID == invitation.callID else { return }
        if connectionPairingID == pairing.pairingID, stage == .ringing, remoteCallID == invitation.callID {
            joiningIncoming = false
            incoming.didJoin(callID: invitation.callID)
            return
        }
        if connectionPairingID == pairing.pairingID, stage == .idle {
            return // The authenticated foreground connection will announce JOIN + ringing.
        }
        let id = invitation.callID
        sessionID = id
        connectionPairingID = pairing.pairingID
        stage = .connecting
        client.connect(id: id, endpoint: pairing.endpoint, port: pairing.port,
                       key: (try? PJZCallProtocol.decodeKey(pairing.keyHex)) ?? Data(), callID: id)
    }

    func importPairing(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try savePersistentPairing(StoredPairing.importFile(Data(contentsOf: url)))
            status = "配对已保存到本机钥匙串；推送注册后可等待后台来电。"
            registerPushToken()
            if AVAudioSession.sharedInstance().recordPermission == .undetermined {
                requestMicrophonePermission(savedPairing: true)
            } else if AVAudioSession.sharedInstance().recordPermission == .denied {
                status = "配对已保存；" + BridgeProtocolError.microphoneDenied.localizedDescription
            }
        } catch { status = "配对文件无效或钥匙串不可用。" }
    }

    private func savePersistentPairing(_ pairing: StoredPairing) throws {
        try pairingStore.save(pairing)
        endpoint = pairing.endpoint; port = String(pairing.port); temporaryKey = pairing.keyHex
    }

    private func registerPushToken() {
        guard let token = pushToken, let pairing = try? pairingStore.load() else { return }
        let environment = Bundle.main.object(forInfoDictionaryKey: "CallBridgePushEnvironment") as? String ?? "production"
        guard ["sandbox", "production"].contains(environment) else { return }
        var request = URLRequest(url: pairing.providerURL.appendingPathComponent("v1").appendingPathComponent("register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + pairing.providerToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "pairing_id": pairing.pairingID.uuidString.lowercased(),
            "push_token": token.map { String(format: "%02x", $0) }.joined(), "environment": environment])
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let success = error == nil && (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
            Task { @MainActor in self?.diagnostic(success ? "push_registration_succeeded" : "push_registration_failed") }
        }.resume()
    }

    private func requestMicrophonePermission(savedPairing: Bool) {
        requestingPermission = true
        status = savedPairing ? "配对已保存，请允许通话使用麦克风。" : "首次测试先允许麦克风；授权后请再次点击连接。"
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.requestingPermission = false
                self.diagnostic("microphone_permission_granted=\(granted)")
                guard !self.connected else { return }
                self.status = granted
                    ? (savedPairing ? "配对已保存到本机钥匙串；推送注册后可等待后台来电。" : "麦克风已允许，请点击连接。")
                    : BridgeProtocolError.microphoneDenied.localizedDescription
            }
        }
    }

    func connect() {
        diagnosticErrorEvent = nil
        diagnosticErrorDomain = nil
        diagnosticErrorCode = nil
        diagnosticNetworkPath = nil
        diagnostic("connect_clicked foreground=\(foreground) connected=\(connected) permission_pending=\(requestingPermission) pairing_present=\(!temporaryKey.isEmpty) speakerphone=\(speakerphone)")
        guard foreground, !connected, !requestingPermission, !simulatedTest else { return }
        do {
            // The permission alert itself makes the scene inactive. Do not hold a socket or audio
            // during this first prompt, and do not silently reconnect when the prompt disappears.
            switch AVAudioSession.sharedInstance().recordPermission {
            case .undetermined:
                requestMicrophonePermission(savedPairing: false)
                return
            case .denied: throw BridgeProtocolError.microphoneDenied
            case .granted: break
            @unknown default: throw BridgeProtocolError.microphoneDenied
            }
            guard let numericPort = UInt16(port) else { throw BridgeProtocolError.invalidEndpoint }
            let target = try PJZCallProtocol.validateEndpoint(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), port: numericPort)
            let key = try PJZCallProtocol.decodeKey(temporaryKey)
            if let pairing = try? pairingStore.load(), pairing.endpoint == target,
               pairing.port == numericPort, pairing.keyHex == temporaryKey {
                connectionPairingID = pairing.pairingID
            } else { connectionPairingID = nil }
#if DEBUG
            // An automatic diagnostic must never connect/answer with a real-call pairing.
            guard !networkTestRequested || simulationPairing else { throw BridgeProtocolError.invalidState }
            networkTestActive = networkTestRequested
            networkSimulation = networkTestActive
#endif
            let id = UUID()
            sessionID = id
            connected = true
            answerRequested = false
            audioRunning = false
            audioStarting = false
            endingCall = false
            networkStatistics = NetworkStatistics()
            audioStatistics = AudioStatistics()
            stage = .connecting
            status = BridgeStage.connecting.rawValue
            var simulation = false
#if DEBUG
            simulation = networkTestActive
#endif
            client.connect(id: id, endpoint: target, port: numericPort, key: key, simulation: simulation)
        } catch {
            diagnostic("connect_rejected reason=\(String(describing: (error as? BridgeProtocolError) ?? .connectionFailed))")
            status = (error as? BridgeProtocolError)?.localizedDescription ?? BridgeProtocolError.connectionFailed.localizedDescription
        }
    }

    func answer() {
        guard foreground, !simulatedTest, stage == .ringing, !answerRequested, let id = systemCallID else { return }
        diagnostic("answer_clicked speakerphone=\(speakerphone)")
        systemCall.requestAnswer(id: id)
    }

    private var mayContinueAnsweredCall: Bool {
        sessionID != nil && systemCallID != nil && answerRequested
    }

    private func prepareSystemAnswer(id: UUID) -> Bool {
        guard sessionID != nil, systemCallID == id, stage == .ringing, !answerRequested else { return false }
        do { try CallAudio.prepareSession() }
        catch {
            let value = error as NSError
            recordDiagnostic("audio_prepare_failed", domain: value.domain, code: value.code)
            disconnect(message: BridgeProtocolError.audioUnavailable.localizedDescription)
            return false
        }
        answerRequested = true
        diagnostic("callkit_answer_accepted android_answer_sent=false")
#if DEBUG
        if networkTestActive { networkTestAnswerCount += 1 }
#endif
        status = "正在准备 iPhone 音频，就绪后接听本次来电。"
        // Real answering advances only from CallKit activation or an actual end/error event.
        if simulatedTest || networkSimulation {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.sessionID == id, !self.systemAudioActive else { return }
                self.disconnect(message: "系统未激活通话音频，桥接已停止；一加尚未接听。")
            }
        }
        return true
    }

    private func reportSystemIncomingCall(id: UUID) {
        guard systemCallID == nil else { return }
        systemCallID = id
        let caller = callerIdentity.callID == id ? callerIdentity.caller : CallerIdentity()
        systemCall.reportIncoming(id: id, simulated: simulatedTest || networkSimulation, caller: caller) { [weak self] succeeded in
            guard let self, self.systemCallID == id else { return }
            self.diagnostic("callkit_incoming_reported success=\(succeeded)")
            guard succeeded else {
                self.disconnect(message: "系统来电界面未能显示，桥接已停止；一加尚未接听。")
                return
            }
#if DEBUG
            if self.networkTestActive || self.callKitSelfTestActive && self.selfTestRequested {
                self.diagnostic("callkit_simulated_answer real_call_control=false")
                self.systemCall.requestAnswer(id: id)
            }
#endif
        }
    }

    func endCall() {
        guard connected, !endingCall else { return }
        guard stage == .active || stage == .recovering else {
            disconnect(message: "桥接已停止。")
            return
        }
        guard let id = sessionID, !simulatedTest, !networkSimulation else {
            disconnect(message: "模拟测试或等待连接已停止。")
            return
        }
        endingCall = true
        // Finishing an already requested hangup is bounded existing-call work. This does
        // not register or wake the app for any future incoming call.
        hangupBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Complete call hangup") { [weak self] in
            MainActor.assumeIsolated { self?.endHangupBackgroundTask() }
        }
        stage = .ending
        status = BridgeStage.ending.rawValue
        audioRunning = false
        audioStarting = false
        audio.stop()
        let endedCallID = systemCallID
        systemCallID = nil
        systemAudioActive = false
        if let endedCallID { incoming.finish(callID: endedCallID, reportEnd: false) }
        if let endedCallID { systemCall.end(id: endedCallID) }
        client.hangUp(id: id)
        diagnostic("explicit_hangup_requested")
    }

    func disconnect(message: String = "桥接已停止。") {
        endHangupBackgroundTask()
#if DEBUG
        selfTestTimer?.invalidate()
        selfTestTimer = nil
        selfTestID = nil
        scheduledLocalCall?.cancel()
        scheduledLocalCall = nil
        endLocalFixtureBackgroundTask()
        callKitSelfTestActive = false
        if !selfTestRequested { simulatedTest = false }
#endif
        let endedCallID = systemCallID
        systemCallID = nil
        systemAudioActive = false
        requestedMicrophoneMuted = false
        sessionID = nil
        connected = false
        stage = nil
        audioRunning = false
        audioStarting = false
        endingCall = false
        answerRequested = false
        joiningIncoming = false
        remoteCallID = nil
        callerIdentity = CallIdentityState()
        connectionPairingID = nil
        if let endedCallID { incoming.finish(callID: endedCallID, reportEnd: false) }
        status = message
        audio.stop()
        client.disconnect()
        if let endedCallID { systemCall.end(id: endedCallID) }
        diagnostic("stopped message=\(message)")
    }

    private func endHangupBackgroundTask() {
        guard hangupBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(hangupBackgroundTask)
        hangupBackgroundTask = .invalid
    }

    func setScenePhase(_ phase: ScenePhase) {
        // Passive metadata distinguishes a temporary inactive scene from backgrounding.
        // Do not enable proximity monitoring. Only a reported/answered CallKit call can
        // survive the system call overlay or continue its active audio while locked.
        let app = UIApplication.shared
        let device = UIDevice.current
        diagnostic("scene_phase=\(phase) application_state=\(app.applicationState.rawValue) "
                   + "protected_data_available=\(app.isProtectedDataAvailable) "
                   + "proximity_monitoring=\(device.isProximityMonitoringEnabled) proximity_near=\(device.proximityState)")
        setForeground(phase == .active, systemOverlay: phase == .inactive && systemCallID != nil)
    }

    private func setForeground(_ active: Bool, systemOverlay: Bool) {
        foreground = active
        // Only this foreground laboratory page stays awake; never change the system timeout.
        // An explicitly answered CallKit call owns its audio in the background.
        UIApplication.shared.isIdleTimerDisabled = active
        diagnostic("foreground=\(active) idle_timer_disabled=\(UIApplication.shared.isIdleTimerDisabled)")
#if DEBUG
        if active, selfTestRequested, !selfTestWasStarted {
            selfTestWasStarted = true
            runAudioSelfTest()
            return
        }
#endif
        if active, !connected, !requestingPermission, temporaryKey.isEmpty {
            loadOneTimePairing()
        }
        if active { registerPushToken() }
#if DEBUG
        if active, networkTestRequested, simulationPairing, !networkTestWasStarted {
            networkTestWasStarted = true
            diagnostic("network_test_start calls_placed=false simulation_pairing=true")
            connect()
        }
#endif
        if !active {
#if DEBUG
            if localFixtureBackgroundTask != .invalid, simulatedTest {
                diagnostic("locked_local_fixture continues=true production_wakeup_verified=false")
                return // Only this bounded, local-only fixture can ring while already locked.
            }
#endif
            if endingCall || mayContinueAnsweredCall || systemOverlay || joiningIncoming || systemCallID != nil {
                diagnostic("callkit_scene_continues answered=\(answerRequested) audio_active=\(systemAudioActive)")
                return
            }
            // Keep an unused pairing only in memory until authentication succeeds.
            // Backgrounding still closes any waiting connection or audio.
            if connected { disconnect(message: "App 已离开前台，桥接已停止；请主动重新连接。") }
            else { audio.stop(); client.disconnect() }
        }
    }

    private func handle(id: UUID, event: BridgeClientEvent) {
        guard id == sessionID else { return }
        switch event {
        case .callID(let callID):
            guard systemCallID == nil || systemCallID == callID else { disconnect(); return }
            remoteCallID = callID
        case .callerIdentity(let update):
            guard remoteCallID == update.callID || systemCallID == update.callID else { disconnect(); return }
            updateCaller(id: update.callID, caller: update.caller, direct: true)
        case .diagnostic(let event, let domain, let code):
            recordDiagnostic(event, domain: domain, code: code)
        case .networkPath(let path):
            diagnosticNetworkPath = path
            diagnostic("network_path")
        case .stage(let state):
            // An already queued stage callback must not restart audio after user hangup.
            if endingCall, state != .ending { return }
            let recovered = stage == .recovering && state == .active
            stage = state
            if state == .idle { temporaryKey = "" }
            if state != .ringing || !answerRequested { status = state.rawValue }
            diagnostic("stage=\(state.rawValue)")
            if state == .active {
                guard answerRequested, systemAudioActive, foreground || mayContinueAnsweredCall else { disconnect(); return }
#if DEBUG
                networkTestActiveTime = ProcessInfo.processInfo.systemUptime
#endif
                startAudio(id: id)
                if recovered { status = "连接已恢复，继续本次通话。" }
            }
            if state == .ringing {
                let callID = remoteCallID ?? id
                reportSystemIncomingCall(id: callID)
                joiningIncoming = false
                incoming.didJoin(callID: callID)
            }
        case .statistics(let statistics):
            networkStatistics = statistics
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastDiagnosticTime >= 5 {
                lastDiagnosticTime = now
                diagnostic("down_frames=\(statistics.receivedFrames) up_frames=\(statistics.sentFrames) "
                           + "down_rms=\(statistics.receiveLevel) up_rms=\(statistics.sendLevel) "
                           + "up_dropped=\(statistics.droppedUplink) audio_running=\(audioRunning)")
            }
        case .stopped(let reason):
            diagnostic("connection_ended error=\(String(describing: reason))")
#if DEBUG
            if networkTestActive {
                let renderDelay = audioStatistics.firstNonzeroRenderTime - networkTestActiveTime
                let earlyAudio = audioStatistics.firstNonzeroRenderTime > 0 && renderDelay >= 0 && renderDelay < 0.5
                var endMatches = reason == nil
                if expectsTestDisconnect { if case .connectionFailed? = reason { endMatches = true } else { endMatches = false } }
                let passed = endMatches && audioRunning && networkTestAnswerCount == 1
                    && networkStatistics.receivedFrames >= (expectsTestDisconnect ? 150 : 400)
                    && networkStatistics.sentFrames >= (expectsTestDisconnect ? 100 : 300)
                    && Double(audioStatistics.nonzeroRenderedSamples) >= audioStatistics.hardwareSampleRate * (expectsTestDisconnect ? 0.15 : 3) && earlyAudio
                diagnostic("network_test_result passed=\(passed) answer_count=\(networkTestAnswerCount) "
                    + "down_frames=\(networkStatistics.receivedFrames) up_frames=\(networkStatistics.sentFrames) "
                    + "rendered_buffers=\(audioStatistics.renderedBuffers) rendered_nonzero=\(audioStatistics.nonzeroRenderedBuffers) "
                    + "early_audio_present=\(earlyAudio) first_render_delay=\(renderDelay) rendered_nonzero_samples=\(audioStatistics.nonzeroRenderedSamples) "
                    + "capture_drops=\(audioStatistics.droppedCapture) playback_drops=\(audioStatistics.droppedPlayback) "
                    + "expected_disconnect=\(expectsTestDisconnect) "
                    + "calls_placed=false hearing_verified=false pcm_saved=false")
                networkTestActive = false
            }
#endif
            let endedMessage = endingCall ? "本次通话已挂断。" : "本次连接已结束；请主动重新连接。"
            disconnect(message: reason?.localizedDescription ?? endedMessage)
        }
    }

    private func startAudio(id: UUID) {
        guard !endingCall, !audioRunning, !audioStarting else { return }
        audioStarting = true
        let bridgeClient = client
        let simulated = simulatedTest
        audio.start(id: id, speakerphone: speakerphone, systemManagedSession: systemAudioActive,
                    initiallyMuted: requestedMicrophoneMuted, finiteTest: simulated || networkSimulation, microphone: { id, pcm in
            if simulated {
#if DEBUG
                Task { @MainActor [weak self] in
                    guard let self, self.selfTestID == id else { return }
                    self.networkStatistics.sentFrames += 1
                    self.networkStatistics.sendLevel = PJZCallProtocol.pcmLevel(pcm)
                    if self.networkStatistics.sendLevel > 0 { self.selfTestNonzeroFrames += 1 }
                    if self.acousticSelfTestRequested { self.acousticProbe.add(pcm) }
                }
#endif
                return // Local self-test microphone never enters a socket.
            }
            bridgeClient.sendMicrophone(id: id, pcm: pcm)
        }, statistics: { [weak self] id, statistics in
            Task { @MainActor in
                guard let self, self.sessionID == id, !self.endingCall else { return }
                self.audioStatistics = statistics
            }
        }, failure: { [weak self] id, reason in
            Task { @MainActor in
                guard let self, self.sessionID == id, !self.endingCall else { return }
                self.diagnostic("audio_failed reason=\(reason)")
#if DEBUG
                if self.simulatedTest { self.finishAudioSelfTest(error: reason); return }
#endif
                self.disconnect(message: BridgeProtocolError.audioUnavailable.localizedDescription)
            }
        }, completion: { [weak self] id, succeeded in
            Task { @MainActor in
                guard let self, self.sessionID == id, !self.endingCall,
                      self.foreground || self.mayContinueAnsweredCall,
                      self.stage == .active || self.stage == .recovering && self.answerRequested
                        || self.stage == .ringing && self.answerRequested else { return }
                self.audioStarting = false
                if succeeded {
                    self.diagnostic("audio_started hardware_rate=\(self.audioStatistics.hardwareSampleRate)")
                    self.audioRunning = true
                    if self.stage == .recovering {
                        self.status = BridgeStage.recovering.rawValue
                        return
                    }
                    if self.stage == .ringing, self.answerRequested {
                        self.diagnostic("audio_ready_before_answer microphone_network_blocked_until_active=true")
                        self.client.requestAnswer(id: id)
                        self.status = "iPhone 音频已就绪，已请求接听，等待一加路由确认。"
                        return
                    }
                    self.status = self.simulatedTest ? "本机模拟音频自检中：无需拨电话。"
                        : self.networkSimulation ? "两机合成音频模拟中：无需拨电话。"
                        : "音频已启动：请分别确认两端能否听见真人讲话。"
                } else {
                    self.disconnect(message: BridgeProtocolError.audioUnavailable.localizedDescription)
                }
            }
        })
    }

#if DEBUG
    func playAudioSelfTest() {
        guard foreground, !connected, !requestingPermission else { return }
        runAudioSelfTest()
    }

    func playSystemCallSelfTest() {
        guard foreground, !connected, !requestingPermission else { return }
        runAudioSelfTest(useCallKit: true)
    }

    func scheduleLockedSystemCallSelfTest() {
        guard foreground, !connected, !requestingPermission,
              AVAudioSession.sharedInstance().recordPermission == .granted else { return }
        // A finite UIKit grace period for one user-armed local fixture. No socket, silent
        // playback, recurring timer or production background incoming-call permission.
        localFixtureBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Local synthetic call") { [weak self] in
            // UIKit invokes expiration synchronously on the main thread. End its task
            // before returning, rather than scheduling cleanup after suspension.
            MainActor.assumeIsolated {
                self?.disconnect(message: "本机锁屏测试准备时间已结束；未拨打电话。")
            }
        }
        guard localFixtureBackgroundTask != .invalid else {
            status = "系统未提供本机测试准备时间；未拨打电话。"
            return
        }
        simulatedTest = true
        connected = true
        status = "10 秒后显示合成来电，请现在锁屏；不拨号、不联网。"
        diagnostic("locked_local_fixture_armed delay_seconds=10 production_wakeup_verified=false")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.localFixtureBackgroundTask != .invalid, self.simulatedTest else { return }
            self.scheduledLocalCall = nil
            self.runAudioSelfTest(useCallKit: true, allowBackgroundFixture: true)
        }
        scheduledLocalCall = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func endLocalFixtureBackgroundTask() {
        guard localFixtureBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(localFixtureBackgroundTask)
        localFixtureBackgroundTask = .invalid
    }

    // Explicit development-only entry point requested by the user. No Telecom, network,
    // pairing key, audio file or phone-number access; runs the actual iPhone audio pipeline.
    private func runAudioSelfTest(useCallKit: Bool = false, allowBackgroundFixture: Bool = false) {
        guard foreground || allowBackgroundFixture && localFixtureBackgroundTask != .invalid,
              AVAudioSession.sharedInstance().recordPermission == .granted else {
            status = "本机自检需要前台及已授予的麦克风权限；未拨打电话。"
            diagnostic("self_test_rejected microphone_or_foreground")
            return
        }
        simulatedTest = true
        callKitSelfTestActive = useCallKit || ProcessInfo.processInfo.arguments.contains("--callkit-self-test")
        selfTestDuration = callKitSelfTestActive ? 20 : 10
        let id = UUID()
        selfTestID = id
        sessionID = id
        connected = true
        stage = .ringing
        status = "模拟来电自检：不拨号、不接听真实电话。"
        networkStatistics = NetworkStatistics()
        audioStatistics = AudioStatistics()
        selfTestNonzeroFrames = 0
        acousticProbe = LocalAcousticProbe()
        diagnostic("self_test_ringing calls_placed=false network_used=false")
        if callKitSelfTestActive {
            reportSystemIncomingCall(id: id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, self.selfTestID == id, !self.answerRequested else { return }
                self.finishAudioSelfTest(error: "local_answer_timeout")
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.selfTestID == id, self.foreground else { return }
            self.startLocalTestPlayback(id: id)
        }
    }

    private func startLocalTestPlayback(id: UUID) {
        guard selfTestID == id else { return }
        // Eight complete cycles per 20 ms packet, avoiding discontinuities at packet edges.
        func tone(frequency: Double) -> Data {
            var data = Data(capacity: PJZCallProtocol.pcmBytes)
            for index in 0..<PJZCallProtocol.frameSamples {
                let sample = Int16((sin(2 * Double.pi * frequency * Double(index) / 16000) * 2000).rounded())
                let bits = UInt16(bitPattern: sample)
                data.append(UInt8(bits & 0xff)); data.append(UInt8(bits >> 8))
            }
            return data
        }
        let syntheticPacket = tone(frequency: 400)
        let secondPacket = tone(frequency: 700)
        stage = .active
        status = "本机音频自检中：仅播放合成短音，麦克风不发送到网络。"
        diagnostic("self_test_answered calls_answered=false")
        selfTestDeadline = ProcessInfo.processInfo.systemUptime + selfTestDuration
        startAudio(id: id)
        selfTestTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.selfTestID == id else { return }
                if ProcessInfo.processInfo.systemUptime >= self.selfTestDeadline {
                    self.finishAudioSelfTest()
                    return
                }
                let remaining = self.selfTestDeadline - ProcessInfo.processInfo.systemUptime
                let audible = Int((self.selfTestDuration - remaining) * 2) % 2 == 0
                let secondTone = self.acousticSelfTestRequested && Int((self.selfTestDuration - remaining) * 2) % 4 == 2
                self.audio.enqueueDownlink(id: id, pcm: audible ? (secondTone ? secondPacket : syntheticPacket) : Data(count: PJZCallProtocol.pcmBytes))
                self.networkStatistics.receivedFrames += 1
            }
        }
    }

    private func finishAudioSelfTest(error: String? = nil) {
        guard selfTestID != nil else { return }
        let passed = error == nil && audioRunning && networkStatistics.sentFrames >= 100
            && audioStatistics.playedBuffers >= 100
        if acousticSelfTestRequested {
            diagnostic("local_acoustic_result tone_detected=\(acousticProbe.detected) tone_400_frames=\(acousticProbe.firstFrames) tone_700_frames=\(acousticProbe.secondFrames) "
                       + "tone_400_max_rms=\(acousticProbe.firstLevel) tone_700_max_rms=\(acousticProbe.secondLevel) network_used=false pcm_saved=false hearing_verified=false")
        }
        diagnostic("self_test_result passed=\(passed) reason=\(error ?? "completed") "
                   + "microphone_frames=\(networkStatistics.sentFrames) microphone_nonzero=\(selfTestNonzeroFrames) "
                   + "played_buffers=\(audioStatistics.playedBuffers) calls_placed=false network_used=false hearing_verified=false pcm_saved=false")
        disconnect(message: passed ? "本机音频数据检查完成；听筒是否出声仍需确认。"
                   : "本机模拟音频自检未通过，诊断已记录；未拨打电话。")
        if !selfTestRequested { simulatedTest = false }
    }
#endif

    // Development delivery only: the trusted Mac copies a pairing file into this
    // App's private container. Consume/delete it on foreground entry; never log its values.
    private func loadOneTimePairing() {
#if DEBUG
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = directory.appendingPathComponent("CallBridgePairing.plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 4096,
                  let values = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                  let host = values["endpoint"] as? String,
                  let number = values["port"] as? Int, let numericPort = UInt16(exactly: number),
                  let key = values["pairingKey"] as? String else { return }
            endpoint = try PJZCallProtocol.validateEndpoint(host, port: numericPort)
            _ = try PJZCallProtocol.decodeKey(key)
            port = String(numericPort)
            temporaryKey = key
            if values["pairing_id"] != nil, values["simulation"] as? Bool != true {
                try savePersistentPairing(StoredPairing.importFile(bytes))
                registerPushToken()
            }
            simulationPairing = values["simulation"] as? Bool ?? false
            status = "本次临时配对已准备，请点击连接。"
            diagnostic("one_time_pairing_loaded")
        } catch { diagnostic("one_time_pairing_rejected") }
#endif
    }

    private func recordDiagnostic(_ event: String, domain: String?, code: Int?) {
        // Public error metadata only: no userInfo, descriptions, addresses or pairing material.
        // Keep the last concrete domain/code when a following lifecycle event has no error.
        if domain != nil || diagnosticErrorEvent == nil {
            diagnosticErrorEvent = event
            diagnosticErrorDomain = domain
            diagnosticErrorCode = code
        }
        diagnostic(event)
    }

    private func diagnostic(_ metadata: String) {
#if DEBUG
        print("PJZ_CALL_BRIDGE uptime=\(ProcessInfo.processInfo.systemUptime) \(metadata)")
        fflush(stdout)
        var values: [String: Any] = [
            "hasKey": !temporaryKey.isEmpty, "connected": connected, "foreground": foreground,
            "event": String(metadata.split(separator: " ").first ?? "unknown"),
            "stage": stage?.rawValue ?? "stopped", "updatedAt": Date().timeIntervalSince1970
        ]
        if let event = diagnosticErrorEvent { values["errorEvent"] = event }
        if let domain = diagnosticErrorDomain { values["errorDomain"] = domain }
        if let code = diagnosticErrorCode { values["errorCode"] = code }
        if let path = diagnosticNetworkPath {
            values["pathStatus"] = path.status
            values["pathInterfaces"] = path.interfaces
            if let reason = path.unsatisfiedReason { values["pathUnsatisfiedReason"] = reason }
        }
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let state = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) {
            try? state.write(to: directory.appendingPathComponent("CallBridgePairingState.plist"), options: .atomic)
        }
#endif
    }
}

#if DEBUG
// Reduces local microphone PCM immediately to two synthetic-frequency counts. A negative
// result is inconclusive for a directional receiver; it is never a human hearing verdict.
private struct LocalAcousticProbe {
    private(set) var firstFrames = 0
    private(set) var secondFrames = 0
    private(set) var firstLevel = 0.0
    private(set) var secondLevel = 0.0
    var detected: Bool { firstFrames >= 15 && secondFrames >= 15 }

    mutating func add(_ pcm: Data) {
        guard pcm.count == PJZCallProtocol.pcmBytes else { return }
        let firstCoefficient = 2 * cos(2 * Double.pi * 400 / 16000)
        let secondCoefficient = 2 * cos(2 * Double.pi * 700 / 16000)
        var first1 = 0.0, first2 = 0.0, second1 = 0.0, second2 = 0.0, power = 0.0
        pcm.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for index in 0..<PJZCallProtocol.frameSamples {
                let value = Double(Int16(bitPattern: UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8)) / 32768
                power += value * value
                let nextFirst = value + firstCoefficient * first1 - first2
                first2 = first1; first1 = nextFirst
                let nextSecond = value + secondCoefficient * second1 - second2
                second2 = second1; second1 = nextSecond
            }
        }
        let level = sqrt(power / Double(PJZCallProtocol.frameSamples))
        guard level > 0.00015 else { return }
        let firstPower = first1 * first1 + first2 * first2 - firstCoefficient * first1 * first2
        let secondPower = second1 * second1 + second2 * second2 - secondCoefficient * second1 * second2
        let denominator = Double(PJZCallProtocol.frameSamples) * power
        if 2 * firstPower / denominator > 0.45 { firstFrames += 1; firstLevel = max(firstLevel, level) }
        if 2 * secondPower / denominator > 0.45 { secondFrames += 1; secondLevel = max(secondLevel, level) }
    }
}
#endif
