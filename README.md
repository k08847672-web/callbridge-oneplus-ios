# CallBridge: OnePlus → iPhone

把一加上的 SIM 来电接入 iPhone 的原生 CallKit 接听界面，并在接听后通过两机之间的 Tailscale 连接传输双向语音。独立 Android Java 桥与最小 InCallService helper 控制本次来电；iOS 使用 SwiftUI、Network、AVAudioEngine、CallKit 和 PushKit。

锁屏新来电使用可自行配置的 APNs VoIP provider 唤醒 iPhone。provider 只处理推送注册与最小来电事件，语音仍在两机间直传。已经接听的通话断线时恢复同一会话，最多 30 秒，不重新拨号或再次接听。

这是面向 OnePlus 13 / Android 16 环境开发的实验实现。Android 端沿用已授权的 shell 音频路径与窄权限 helper，需要系统已具备相应的通话音频和 Telecom 能力；普通安装一个 APK 不能获得完整功能。其他设备的支持情况需要实机验证，具体前提见 [Android 运行前提](docs/ANDROID_PREREQUISITES.md)。构建、协议测试或本地 APNs mock 不能证明真实锁屏唤醒与双向通话已经通过；实际验证结果见 [验证说明](docs/VERIFICATION.md)。

## 朋友只打包 iOS / TestFlight

1. clone 本仓库，用 Xcode 打开 `ios/CallBridge/CallBridge.xcodeproj`，选择 `CallBridge` scheme。
2. 选择朋友自己的付费 Apple Developer Team，把示例 `com.example.callbridge` 改为其团队的唯一 Bundle ID。
3. 启用对应 App ID 的 Push Notifications，使用 Release / production 推送环境。
4. Archive，在 Organizer 验证并上传 App Store Connect，再开放 TestFlight 测试。

仅完成 iOS 签名和上传需要 Mac、Xcode 与朋友的 Apple 团队，不需要先安装 Android 构建工具。细节见 [签名与分发](docs/FRIEND_SIGNING_TESTFLIGHT.md)。实际使用转接时，再按下面的独立说明准备 Android、provider 和配对。

已经通过 TestFlight 安装后，可将 [朋友 Codex 的 APNs 核对与交付说明](docs/FRIEND_APNS_CODEX.md) 交给签名方：先核对当前构建及已有 Apple 资源，只补实际缺项；本次 provider 由使用者一侧部署在 Mini，朋友无需部署服务器。

## 目录与环境

| 路径 | 内容 |
| --- | --- |
| `ios/CallBridge/` | iOS 17+ 客户端、Xcode 工程和纯逻辑测试 |
| `android/callbridgehelper/` | 精确持有本次桥接 Call 的 InCallService helper |
| `scripts/diagnostics/TelephonyNetworkBridge.java` | Android shell Java 通话桥 |
| `scripts/diagnostics/PrepareCallBridgePairing.swift` | 在私有临时目录生成配对配置 |
| `callbridge_push/` | 使用 Node.js 内置 HTTP/2、crypto 的真实 APNs provider 与本地 mock |
| `scripts/test-callbridge-local.sh` | 集中执行本地模拟与相关构建的入口 |

iOS 构建需要 macOS、Xcode 和匹配目标设备系统的 SDK。Android 构建需要 JDK 17 与 Android SDK 36 / Build Tools 36.0.0；通过 `JAVA_HOME` 和 `ANDROID_SDK_ROOT` 选择本机安装。provider 使用 Node.js，无第三方 npm 运行时依赖。

## 本地验证与构建

在仓库根目录运行：

```sh
scripts/test-callbridge-local.sh
```

具体选项与验证结果以 [验证说明](docs/VERIFICATION.md) 和脚本帮助为准。此入口用于本地源码、协议、状态和 mock 检查；真实手机安装、蜂窝通话和 APNs 唤醒另行验收。

仅编译 Android 桥或 helper：

```sh
export JAVA_HOME="/path/to/jdk-17/Contents/Home"
export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
scripts/build-call-bridge-lab.sh
scripts/build-callbridge-helper.sh
```

构建目录和产物由脚本输出。helper 默认生成已对齐的未签名 APK；显式设置 `CALLBRIDGE_KEYSTORE`、`CALLBRIDGE_KEY_ALIAS`、`CALLBRIDGE_KS_PASSWORD`、`CALLBRIDGE_KEY_PASSWORD` 才会用本机材料签名，密码通过环境传给签名工具。不要把 keystore 或密码提交到仓库。

用 Xcode 打开 `ios/CallBridge/CallBridge.xcodeproj`，选择 `CallBridge` scheme。无签名编译可使用：

```sh
xcodebuild -project ios/CallBridge/CallBridge.xcodeproj \
  -scheme CallBridge -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/callbridge-ios-build CODE_SIGNING_ALLOWED=NO build
```

朋友签名与 TestFlight 的完整步骤见 [签名与分发](docs/FRIEND_SIGNING_TESTFLIGHT.md)。

## 配对与运行

两台手机加入可互相访问的 Tailscale 网络。Android 桥绑定显式指定的 Tailnet IPv4，默认音频端口为 47631。配对密钥在本地生成，通过私有文件或客户端输入提供，不随源码分发。生成与两端配置步骤见 [配对配置](docs/PAIRING.md)。

iOS 将有效配对保存到本机 Keychain，使 PushKit 唤醒后可以连接原 Android 桥。一次性导入文件的 600 秒有效期用于限制文件导入，不是通话或后台运行时限。

锁屏新来电还需要你自己的 Apple Developer 团队、启用 Push Notifications 的 App ID、正确签名的 iOS App，以及可访问 APNs 的 provider。iOS 注册使用有有效证书的 HTTPS 入口；Node HTTP 后端可通过现有反代或 Tailscale Serve 接入。主机和监听地址由配置决定；不限定服务器区域。配置与本地 mock 见 [provider 说明](docs/PROVIDER.md)，消息格式见 [协议](docs/PROTOCOL.md)。

本仓库只包含源码、模板和合成测试。Apple 账号、APNs 私钥、证书、provisioning profile、provider token、配对密钥和真实 push token 应保存在各自运行环境中。

## 许可

[MIT](LICENSE)。Apple、Android 和其他平台 SDK 由其各自条款管理；本仓库不附带这些 SDK、签名凭据或设备材料。
