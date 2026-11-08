import AVFoundation
import CallKit

/// One authenticated call at a time. The system owns audio activation after explicit answer.
@MainActor
final class SystemCallController: NSObject, @preconcurrency CXProviderDelegate {
    var onDiagnostic: ((String, String?, Int?) -> Void)?
    var onAnswer: ((UUID, Date, @escaping (Bool) -> Void) -> Void)?
    var onAudioActivated: ((UUID) -> Void)?
    var onEnded: ((UUID, Bool) -> Void)?
    var onMuted: ((UUID, Bool) -> Void)?
    private let provider: CXProvider
    private let controller = CXCallController()
    private var callID: UUID?
    private var answered = false
    private var answerTransactionPending = false
    private var pendingAnswer: CXAnswerCallAction?

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic, .phoneNumber]
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    func reportIncoming(id: UUID, simulated: Bool, caller: CallerIdentity = CallerIdentity(),
                        completion: @escaping (Bool) -> Void) {
        if callID == id { updateCaller(id: id, caller: caller); completion(true); return }
        guard callID == nil else { completion(false); return }
        callID = id
        answered = false
        answerTransactionPending = false
        let update = callerUpdate(simulated: simulated, caller: caller)
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            Task { @MainActor in
                guard let self, self.callID == id else { completion(false); return }
                if let error {
                    let value = error as NSError
                    self.onDiagnostic?("callkit_report_incoming_failed", value.domain, value.code)
                    self.callID = nil
                }
                completion(error == nil)
            }
        }
    }

    func updateCaller(id: UUID, caller: CallerIdentity) {
        guard callID == id else { return }
        provider.reportCall(with: id, updated: callerUpdate(simulated: false, caller: caller))
    }

    private func callerUpdate(simulated: Bool, caller: CallerIdentity) -> CXCallUpdate {
        let update = CXCallUpdate()
        if simulated {
            update.remoteHandle = CXHandle(type: .generic, value: "合成音测试")
            update.localizedCallerName = "合成音测试 · 不拨号"
        } else {
            update.remoteHandle = caller.number.map { CXHandle(type: .phoneNumber, value: $0) }
                ?? CXHandle(type: .generic, value: caller.displayName)
            update.localizedCallerName = caller.displayName
        }
        return update
    }

    func requestAnswer(id: UUID) {
        guard callID == id, !answered, !answerTransactionPending else { return }
        answerTransactionPending = true
        controller.request(CXTransaction(action: CXAnswerCallAction(call: id))) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, self.callID == id else { return }
                self.answerTransactionPending = false
                let value = error! as NSError
                self.onDiagnostic?("callkit_answer_transaction_failed", value.domain, value.code)
                self.notifyEnded(id: id, reason: "answer_transaction_failed")
            }
        }
    }

    func end(id: UUID, failed: Bool = false) {
        guard callID == id else { return }
        failPendingAnswer()
        callID = nil
        answered = false
        answerTransactionPending = false
        provider.reportCall(with: id, endedAt: Date(), reason: failed ? .failed : .remoteEnded)
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard callID == action.callUUID, !answered, pendingAnswer == nil, let onAnswer else {
            action.fail()
            return
        }
        pendingAnswer = action
        onAnswer(action.callUUID, action.timeoutDate) { [weak self, weak action] ready in
            guard let self, let action, self.pendingAnswer === action else { return }
            self.pendingAnswer = nil
            self.answerTransactionPending = false
            guard ready, self.callID == action.callUUID, Date() < action.timeoutDate else {
                action.fail()
                self.notifyEnded(id: action.callUUID, reason: "answer_not_ready")
                return
            }
            self.answered = true
            // Only the authenticated same call may fulfill an early answer. didActivate
            // then starts audio; Android ANSWER still waits for actual microphone readiness.
            action.fulfill()
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        guard answered, let id = callID else { return }
        onAudioActivated?(id)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        guard answered, let id = callID else { return }
        notifyEnded(id: id, reason: "audio_deactivated")
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard callID == action.callUUID else { action.fail(); return }
        failPendingAnswer()
        callID = nil
        answered = false
        answerTransactionPending = false
        action.fulfill()
        // Every valid End action is honored. Only an already bridged active session
        // authorizes the model to end its original OnePlus call as well.
        notifyEnded(id: action.callUUID, reason: "system_end_action", explicitEndAction: true)
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard callID == action.callUUID, answered else { action.fail(); return }
        onMuted?(action.callUUID, action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        guard let id = callID else { return }
        failPendingAnswer()
        notifyEnded(id: id, reason: "action_timed_out")
    }

    func providerDidReset(_ provider: CXProvider) {
        let id = callID
        failPendingAnswer()
        callID = nil
        answered = false
        answerTransactionPending = false
        if let id { notifyEnded(id: id, reason: "provider_reset") }
    }
    private func notifyEnded(id: UUID, reason: String, explicitEndAction: Bool = false) {
        onDiagnostic?(reason, nil, nil)
#if DEBUG
        // Fixed lifecycle labels only, never a handle, caller number or audio content.
        print("PJZ_CALL_SYSTEM uptime=\(ProcessInfo.processInfo.systemUptime) reason=\(reason)")
        fflush(stdout)
#endif
        onEnded?(id, explicitEndAction)
    }

    private func failPendingAnswer() {
        let action = pendingAnswer
        pendingAnswer = nil
        action?.fail()
    }
}
