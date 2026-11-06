# 验证范围

本仓库区分源码/协议检查、构建、本地模拟与真实设备验收。

## 2026-11-06 配对导入无期限修复

`IncomingCallSelfTests.swift` 使用生产 `StoredPairing.importFile` 与合成 plist，28 个断言通过：不带 `expiresAt`、旧日期及遥远未来日期均可导入；错误桥接密钥/provider token、不完整 provider 与原有非法 URL 仍被拒绝。其余既有来电协调断言继续通过；不访问真实 Keychain、网络或手机。

生成器使用现有 macOS SDK 编译成功，执行 `callbridge_local.py` 中已有的配对生成检查通过：不输出 `expiresAt`、两端配对 ID/密钥一致、provider token 独立且摘要匹配、私有文件权限保持 0600。只执行该配对检查，没有重跑 Android、音频或完整本地套件。`BridgeModel.swift` 与模拟客户端的 Swift 语法解析、`git diff --check` 通过。

本机通过直接调用现有 Xcode 工具链的 `swiftc`、指定现有 macOS SDK 与 `arm64-apple-macosx14.0` target 完成这些检查；未运行 Xcode first-launch、签名、安装、Archive 或 TestFlight 上传。当前 TestFlight 1.0 (1) 仍需由签名方更新，手机上的真实导入与推送注册尚待新构建验证。

## 2026-10-24 集中验证

| 检查 | 结果与证据范围 |
| --- | --- |
| provider 自测 | 8 项通过；覆盖 HTTP API、鉴权、持久化与去重、JWT 签名/缓存、真实 HTTP/2 sender 向本机假 APNs peer 发送请求 |
| iOS 纯协调器 | 20 个断言通过；使用 fake CallKit，检查先报告、早接听与状态关联 |
| 实际 JOIN 客户端 | 4 种本机 TCP 模式通过；使用真实 BridgeClient 与 Java Admission |
| 新链路贯通模拟 | Android PushEvents → Node mock 同 API → payload → 同一 iOS coordinator/fake CallKit → 真实 BridgeClient/Java Admission JOIN → 单次 ANSWER → 双向合成 PCM → HANGUP/idle → provider ended 通过 |
| 已有恢复与精确 Call 控制 | Java active/recovery/claim、helper、Swift active recovery 回归通过 |
| Android 构建 | 独立 JAR 和已对齐 unsigned helper APK 构建通过 |
| 独立仓库固定入口 | `bash scripts/test-callbridge-local.sh --check` 退出 0；实际 Java 全源 javac、Incoming/Join/PushJoin/PreparePairing 四个 Swift 可执行入口编译成功，Node server 语法检查通过，无父项目源码依赖 |
| iOS 业务源码 | 排除 Assets 的 arm64 unsigned 编译/链接通过 |
| 图标资源 | actool 只读内容解析通过；完整 Assets.car/资源打包未验证 |

本地入口为 `scripts/test-callbridge-local.sh`，使用合成数据与本地 mock。provider 可单独运行 `node --test callbridge_push/tests/*.test.mjs`。这些检查未使用真实 APNs 凭据、真实来电或手机操作。

独立导出目录的固定入口检查为 `bash scripts/test-callbridge-local.sh --check`，本轮已退出 0；该模式检查独立源码/编译入口，不重复全部 suite。Node 模块的实际 HTTP/API 运行由同源码的 8 项 provider 自测覆盖，不能把 `--check` 的 Node 语法检查写成另一轮服务运行验证。

完整 iOS App 资源构建、签名、Archive 和 TestFlight 上传本轮尚未验证。本机构建环境缺少对应 iOS Simulator runtime；业务源码 unsigned 链接成功不等于完整 App 构建成功。使用者需要在具备完整 Xcode 平台组件的环境中完成自己的签名和打包。

真实 APNs 投递、iPhone 已锁屏的新来电唤醒、Android 真实蜂窝音频路由、双向真人听感、锁屏续行和断网恢复，需要具备有效签名及相应权限的真实设备验证。它们不能从本地通过结果推断。
