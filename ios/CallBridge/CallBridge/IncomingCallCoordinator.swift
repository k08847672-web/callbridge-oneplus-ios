import Foundation

struct CallInvitation: Equatable {
    let pairingID: UUID
    let callID: UUID
    let caller: CallerIdentity

    init(payload: [AnyHashable: Any]) throws {
        guard let pairing = payload["pairing_id"] as? String,
              let call = payload["call_id"] as? String,
              let pairingID = Self.canonicalUUID(pairing), let callID = Self.canonicalUUID(call),
              (payload["revision"] as? NSNumber)?.intValue == 1,
              payload["state"] as? String == "ringing" else { throw IncomingCallError.invalidInvitation }
        self.pairingID = pairingID
        self.callID = callID
        caller = CallerIdentity(fields: payload)
    }

    init(pairingID: UUID, callID: UUID, caller: CallerIdentity = CallerIdentity()) {
        self.pairingID = pairingID; self.callID = callID; self.caller = caller
    }

    func isSameCall(as other: CallInvitation) -> Bool {
        pairingID == other.pairingID && callID == other.callID
    }

    static func canonicalUUID(_ value: String) -> UUID? {
        guard value.utf8.count == 36, let id = UUID(uuidString: value),
              id.uuidString.lowercased() == value else { return nil }
        return id
    }
}

enum IncomingCallError: Error { case invalidInvitation, missingPairing }

/// The real PushKit callback and synthetic tests use this same coordinator. No socket,
/// CallKit, audio engine, wall-clock wait, or provider account is needed by its tests.
@MainActor
final class IncomingCallCoordinator {
    var loadPairing: (UUID) throws -> StoredPairing
    var reportIncoming: (UUID, CallerIdentity, @escaping (Bool) -> Void) -> Void
    var updateCaller: (UUID, CallerIdentity) -> Void
    var join: (CallInvitation, StoredPairing) -> Void
    var end: (UUID) -> Void
    var now: () -> Date
    var schedule: (Date, @escaping () -> Void) -> Void
    private(set) var current: CallInvitation?
    private var joined = false
    private var lastEnded: UUID?
    private var answer: ((Bool) -> Void)?
    private var answerDeadline: Date?
    private var answerAccepted = false

    init(loadPairing: @escaping (UUID) throws -> StoredPairing,
         reportIncoming: @escaping (UUID, CallerIdentity, @escaping (Bool) -> Void) -> Void,
         updateCaller: @escaping (UUID, CallerIdentity) -> Void = { _, _ in },
         join: @escaping (CallInvitation, StoredPairing) -> Void,
         end: @escaping (UUID) -> Void,
         now: @escaping () -> Date = Date.init,
         schedule: @escaping (Date, @escaping () -> Void) -> Void = { date, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + max(0, date.timeIntervalSinceNow), execute: work)
         }) {
        self.loadPairing = loadPairing; self.reportIncoming = reportIncoming
        self.updateCaller = updateCaller
        self.join = join; self.end = end; self.now = now; self.schedule = schedule
    }

    func receive(_ invitation: CallInvitation, completion: @escaping () -> Void) {
        // Reuse the UUID already reported for this call. A duplicate never starts a new
        // transport, answer action or audio engine.
        if let current, current.isSameCall(as: invitation) {
            if current.caller != invitation.caller {
                self.current = invitation
                updateCaller(invitation.callID, invitation.caller)
            }
            completion()
            return
        }
        guard current == nil else { completion(); return }
        let pairing = try? loadPairing(invitation.pairingID)
        current = invitation
        joined = false
        answerAccepted = false
        reportIncoming(invitation.callID, invitation.caller) { [weak self] success in
            completion() // PushKit completion follows the report attempt, never JOIN/network.
            guard let self, let current = self.current, current.isSameCall(as: invitation) else { return }
            guard success, let pairing, self.lastEnded != invitation.callID else {
                self.finish(callID: invitation.callID)
                return
            }
            self.join(current, pairing)
        }
    }

    func didJoin(callID: UUID) {
        guard current?.callID == callID else { return }
        joined = true
        finishAnswerIfReady()
    }

    func requestAnswer(callID: UUID, deadline: Date, completion: @escaping (Bool) -> Void) {
        guard current?.callID == callID, answer == nil, !answerAccepted, deadline > now() else { completion(false); return }
        answer = completion
        answerDeadline = deadline
        schedule(deadline) { [weak self] in self?.checkDeadline(callID: callID) }
        finishAnswerIfReady()
    }

    func checkDeadline(callID: UUID) {
        guard current?.callID == callID, let deadline = answerDeadline, now() >= deadline else { return }
        finish(callID: callID)
    }

    func finish(callID: UUID, reportEnd: Bool = true) {
        guard current?.callID == callID else { return }
        current = nil
        lastEnded = callID
        joined = false
        answerAccepted = false
        let pending = answer
        answer = nil; answerDeadline = nil
        pending?(false)
        if reportEnd { end(callID) }
    }

    private func finishAnswerIfReady() {
        guard joined, let pending = answer, let deadline = answerDeadline else { return }
        guard deadline > now() else { if let id = current?.callID { finish(callID: id) }; return }
        answer = nil; answerDeadline = nil
        answerAccepted = true
        pending(true)
    }
}
