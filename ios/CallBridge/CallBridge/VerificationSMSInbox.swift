import SwiftUI
import UIKit
import UserNotifications

enum VerificationSMSDestination: Hashable {
    case inbox
    case message(VerificationSMSKey)
}

@MainActor
final class VerificationSMSInboxModel: ObservableObject {
    @Published private(set) var messages: [VerificationSMS] = []
    @Published private(set) var syncing = false
    @Published private(set) var status: String?
    @Published var path: [VerificationSMSDestination] = []
    private let store = VerificationSMSStore()
    private let pairingStore = PairingStore()
    private let client = VerificationSMSClient(session: URLSession(configuration: .ephemeral))
    private var pushToken: Data?
    private var refreshAgain = false
    private var syncTask: Task<Void, Never>?

    func start(_ application: UIApplication) {
        loadLocal()
        // APNs registration and sync work independently of notification permission.
        application.registerForRemoteNotifications()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refresh()
    }

    func didRegister(token: Data) { pushToken = token; refresh() }

    func refresh() {
        guard syncTask == nil else { refreshAgain = true; return }
        syncTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.refreshAgain = false
                await self.synchronize()
            } while self.refreshAgain
            self.syncTask = nil
        }
    }

    func refreshAndWait() async {
        refresh()
        await syncTask?.value
    }

    func receive(_ notification: VerificationSMSNotification, open: Bool) {
        guard let pairing = try? pairingStore.load(), pairing.pairingID == notification.key.pairingID else { return }
        loadLocal()
        if open { path = [.inbox, .message(notification.key)] }
        refresh()
    }

    func accepts(_ notification: VerificationSMSNotification) -> Bool {
        (try? pairingStore.load())?.pairingID == notification.key.pairingID
    }

    func message(for key: VerificationSMSKey) -> VerificationSMS? { messages.first { $0.id == key } }

    private func loadLocal() {
        guard !store.isLoaded else { return }
        do { try store.load(); messages = store.messages }
        catch { status = "暂时无法读取已保存的短信，请解锁后重试。" }
    }

    private func synchronize() async {
        loadLocal()
        guard store.isLoaded else { return }
        syncing = true
        defer { syncing = false }
        do {
            guard let pairing = try pairingStore.load() else {
                status = "导入设备配对后即可接收验证码短信。"
                return
            }
            status = nil
            if let pushToken {
                let environment = Bundle.main.object(forInfoDictionaryKey: "CallBridgePushEnvironment") as? String ?? "production"
                // A notification registration failure must not block opening and syncing the inbox.
                do { try await client.register(pairing: pairing, pushToken: pushToken, environment: environment) }
                catch { status = "暂时无法接收新短信提醒，仍可打开收件箱刷新。" }
            }
            var hasMore: Bool
            repeat {
                let page = try await client.sync(pairing: pairing, afterSeq: store.afterSeq(for: pairing.pairingID))
                try store.apply(page, pairingID: pairing.pairingID)
                messages = store.messages
                hasMore = page.hasMore
                // Importing another pairing does not erase records or apply its cursor to this one.
                if (try pairingStore.load())?.pairingID != pairing.pairingID { return }
            } while hasMore
        } catch {
            status = "暂时无法更新短信，已保存的记录仍可查看。请稍后下拉刷新。"
        }
    }
}

struct VerificationSMSInboxView: View {
    @ObservedObject var model: VerificationSMSInboxModel

    var body: some View {
        List {
            if let status = model.status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            if model.messages.isEmpty {
                Text(model.syncing ? "正在获取验证码短信…" : "还没有验证码短信")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.messages) { message in
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink(value: VerificationSMSDestination.message(message.id)) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(message.sender).font(.headline)
                                Spacer()
                                Text(message.receivedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(message.body).lineLimit(2).font(.subheadline)
                        }
                    }
                    if let code = message.code { VerificationSMSCopyButton(code: code) }
                }
                .padding(.vertical, 4)
                .privacySensitive()
            }
        }
        .navigationTitle("验证码收件箱")
        .refreshable { await model.refreshAndWait() }
        .task { model.refresh() }
        .toolbar { if model.syncing { ProgressView() } }
    }
}

struct VerificationSMSDetailView: View {
    @ObservedObject var model: VerificationSMSInboxModel
    let key: VerificationSMSKey

    var body: some View {
        Form {
            if let message = model.message(for: key) {
                Section {
                    LabeledContent("发件人", value: message.sender)
                    LabeledContent("收到时间") {
                        Text(message.receivedAt, format: .dateTime.year().month().day().hour().minute().second())
                    }
                }
                Section("短信内容") { Text(message.body).textSelection(.enabled) }
                Section("验证码") {
                    if let code = message.code {
                        Text(code).font(.title2.monospacedDigit()).textSelection(.enabled)
                        VerificationSMSCopyButton(code: code)
                    } else {
                        Text("未能确定唯一验证码，请查看短信内容。")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(model.syncing ? "正在获取这条短信…" : "暂时无法获取这条短信，请稍后重试。")
                Button("重新获取") { model.refresh() }.disabled(model.syncing)
            }
        }
        .privacySensitive()
        .navigationTitle("验证码短信")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct VerificationSMSCopyButton: View {
    let code: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "已复制" : "复制验证码", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = code
            copied = true
        }
        .buttonStyle(.borderless)
    }
}
