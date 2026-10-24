import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
private enum BridgeRuntime {
    static let model = BridgeModel()
}

@MainActor
final class BridgeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BridgeRuntime.model.startPushRegistration()
        return true
    }
}

@main
struct CallBridgeApp: App {
    @UIApplicationDelegateAdaptor(BridgeAppDelegate.self) private var appDelegate
    @StateObject private var model = BridgeRuntime.model
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            BridgeView(model: model)
                .onAppear { model.setScenePhase(scenePhase) }
                .onChange(of: scenePhase) { _, phase in model.setScenePhase(phase) }
        }
    }
}

private struct BridgeView: View {
    @ObservedObject var model: BridgeModel
    @State private var importingPairing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("通话桥实验") {
                    if model.simulatedTest {
                        Text("本次是本机模拟自检：不拨号、不接听真实电话，麦克风数据不发送到网络。")
                            .font(.headline)
                    }
                    if model.networkSimulation {
                        Text("两机模拟自检：一加发送合成短音，iPhone 麦克风临时传给一加模拟服务计数，不保存；不拨号、不接听真实电话。")
                            .font(.headline)
                    }
                    Text("导入配对并完成推送配置后，可由系统推送通知新来电。接听后由系统管理通话音频。正常通话不限时，已接通通话意外断网后最多恢复 30 秒。")
                        .font(.footnote)
                    Text("主动挂断会同步结束 iPhone 与一加的本次电话；恢复超时也会结束本次电话。暂不支持远程拨号。")
                        .font(.footnote)
                }
                Section("设备配对") {
                    Button("导入设备配对文件") { importingPairing = true }
                        .disabled(model.connected)
                    Text("配对保存到此设备钥匙串，供系统来电唤醒后使用。下方仍可手动进行一次前台连接。")
                        .font(.footnote)
                }
                Section("一次前台连接") {
                    TextField("一加 Tailscale IPv4：100.64–127.x.x", text: $model.endpoint)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $model.port).keyboardType(.numberPad)
                    SecureField("64 位十六进制临时密钥", text: $model.temporaryKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                    Button("连接") { model.connect() }
                        .disabled(model.connected || model.requestingPermission)
                }
                .disabled(model.connected)
                Section("音频输出") {
                    Toggle("使用扬声器", isOn: $model.speakerphone)
                    Text("接听前选择输出方式；关闭时使用听筒或已连接的耳机。")
                        .font(.footnote)
#if DEBUG
                    Button("播放测试音（10 秒，不拨号）") { model.playAudioSelfTest() }
                        .disabled(model.connected || model.requestingPermission)
                    Button("系统接听测试（20 秒，不拨号）") { model.playSystemCallSelfTest() }
                        .disabled(model.connected || model.requestingPermission)
                    Button("锁屏来电测试（10 秒后，不拨号）") { model.scheduleLockedSystemCallSelfTest() }
                        .disabled(model.connected || model.requestingPermission)
#endif
                }
                .disabled(model.audioRunning || model.answerRequested || model.simulatedTest || model.networkSimulation)
                Section("状态") {
                    Text(model.status)
                    Button(model.answerRequested ? "正在准备或接听本次来电" : "接听本次来电") { model.answer() }
                        .disabled(model.stage != .ringing || model.answerRequested)
                    Button("挂断并停止桥接", role: .destructive) { model.endCall() }
                        .disabled(!model.connected || model.stage == .ending)
                }
                Section("非敏感诊断") {
                    LabeledContent("音频", value: model.audioRunning ? "运行中" : "未启动")
                    LabeledContent("下行帧", value: "\(model.networkStatistics.receivedFrames)")
                    LabeledContent("上行帧", value: "\(model.networkStatistics.sentFrames)")
                    LabeledContent("下行电平 RMS", value: String(format: "%.3f", model.networkStatistics.receiveLevel))
                    LabeledContent("上行电平 RMS", value: String(format: "%.3f", model.networkStatistics.sendLevel))
                    LabeledContent("上行积压丢帧", value: "\(model.networkStatistics.droppedUplink)")
                    LabeledContent("采集积压丢帧", value: "\(model.audioStatistics.droppedCapture)")
                    LabeledContent("播放积压丢帧", value: "\(model.audioStatistics.droppedPlayback)")
                    LabeledContent("麦克风采集缓冲", value: "\(model.audioStatistics.capturedBuffers)")
                    LabeledContent("实际播放完成缓冲", value: "\(model.audioStatistics.playedBuffers)")
                    LabeledContent("硬件采样率", value: String(format: "%.0f Hz", model.audioStatistics.hardwareSampleRate))
                    Text("只显示计数与电平，不保存音频、电话号码或密钥。")
                        .font(.footnote)
                }
            }
            .navigationTitle("一加通话桥 · 实验")
            .fileImporter(isPresented: $importingPairing, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result { model.importPairing(from: url) }
            }
        }
    }
}
