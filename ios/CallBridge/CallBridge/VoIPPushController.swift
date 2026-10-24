import Foundation
import PushKit

@MainActor
final class VoIPPushController: NSObject, @preconcurrency PKPushRegistryDelegate {
    var onIncoming: (([AnyHashable: Any], @escaping () -> Void) -> Void)?
    var onToken: ((Data?) -> Void)?
    private var registry: PKPushRegistry?

    func start() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        onToken?(pushCredentials.token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        if type == .voIP { onToken?(nil) }
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP, let onIncoming else { completion(); return }
        onIncoming(payload.dictionaryPayload, completion)
    }
}
