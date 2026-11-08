# 交给朋友 Codex：修复 production APNs TopicDisallowed

2026-11-08 本轮真机验收通过：真实 SIM 呼入时，iPhone 锁屏出现系统来电界面并成功接听；使用者确认双方声音正常，在 iPhone 挂断后一加也同步结束。Mini 已记录 1 次真实来电（排除之前的合成 `ended`），最终为 `ended / revision=2`，本次 APNs 返回 HTTP 200。先前合成记录不计入真实验收。

Android 原生产监听因 `helper_connect_unavailable` 退出，真实来电未走到 provider。原 AF_UNIX 路径已在实体机 shell 连接时复现 `EACCES`，但具体拒绝原因及对应的 SELinux 规则尚未证实；`Context.bindService` 探针则返回 `not_registered_caller`。现已完成 `getContentProviderExternal → Binder` 的生产迁移：helper 0.4 以同签名覆盖安装，生产 JAR 短哈希为 `29b531f2fa10`；已核对实体进程、`CLASSPATH` 使用新 JAR，以及 47631 端口监听。新日志出现 `helper_ready`（`installed=true`、`default_dialer_changed=false`）和 `listening`；部署后实体机 shell 的 Provider → Binder `PING` 再次返回 `version=1`、`state=0`。所需 AppOp 核验为 `allow`，默认拨号器保持不变。本轮真实通话结束后，一加同一生产进程保持监听，供下一次来电使用。**真实意外断线后的自动恢复未在本轮测试**；实现及本地回归结果不代替该项真人验证。

iPhone 界面的“未连接”描述前台桥接连接状态，与 PushKit 启动及 token 注册独立；注册成功也不会更新这句文案。后台来电由 PushKit / CallKit 触发后再连接原通话；本次 Android 修复不要求 iPhone 重新配对或手点“连接”来保持待机，也不能只凭这句文案判断后台推送是否就绪。

2026-11-07 已完成的历史验证：朋友已在现有 Production / Topic Specific key 的范围中补入本 App。使用同一 provider 配置、同一 key、同一真实 production token 一次重测，**2026-11-07 12:43:50.308 UTC 返回 HTTP 200 / `AppleAccepted=true`**，原 `TopicDisallowed` 阻断已解除。随后使用同配对的合成来电 peer 完成真实 production APNs HTTP 200、配对 AUTH / JOIN，并直接观察到物理 iPhone 锁屏上的“一加来电 · 通话桥”和“滑动来接听”系统 CallKit 界面；**真实生产推送与物理 iPhone 锁屏 CallKit 的模拟验收已通过**。这次合成测试不触碰真实 Telecom 或蜂窝音频；真实蜂窝来电 → helper 这一跳、真人双向音频、真实挂断和断线恢复本轮尚未验证，不能写为全功能通过。无需用户再更新 App、导入配对或朋友再修改 key；第 3、4 节原流程保留作实际缺项排查参考。

历史证据：2026-11-07 已确认 TestFlight 1.0 (2)、配对导入成功及 Mini 的 1 条 production PushKit token 注册；当日 10:17:47 UTC 使用真实注册请求 production APNs 曾返回 **HTTP 400 / `TopicDisallowed`**。后续补充上述现有 key 的关联范围并取得真实 HTTP 200，无需使用者再次真人拨号来定位该授权问题。若将来实际缺项确需更换 key，`.p8` 仍仅经既有私密文件通道交付，绝不进入聊天或 Git。

Apple 对 `TopicDisallowed` 的定义是“不允许向该 topic 推送”。此前使用无效 token 得到的 `BadDeviceToken` 不能证明实际 VoIP topic 已获授权；私钥能签 JWT、provider 健康、token 注册成功，也不能替代真实 APNs 接受结果。仅凭原错误不能认定必须新建 key 或重发 App；本次已通过补充现有 key 范围后的真实 HTTP 200 验证 Apple 接受。

朋友负责核对签名产物、Apple 资源和私密交付；本次 provider 部署在使用者的 Mini，由使用者一侧负责。朋友无需部署服务器、配置 Mini、操作 Android、拨号或发送测试推送。服务器实现已经在 `callbridge_push/server.mjs`，无需另写服务。

## 0. 已完成的配对导入更新；旧构建才需执行

本轮已确认的 1.0 (2) 无需重复执行本节。仅当实际安装的仍是保留导入期限的旧构建时，按以下步骤更新；APNs 服务端 key 授权问题本身不构成重发 iOS App 的依据。

1. 取得 [本公开仓库](https://github.com/k08847672-web/callbridge-oneplus-ios) 中包含本节的最新修复，记录实际使用的 commit；保留朋友本机已有的签名团队和实际 Bundle ID。
2. 确认 `PairingStore.swift` 的 `StoredPairing.importFile` 不读取/校验 `expiresAt`，`BridgeModel.swift` 正式导入与 Debug 导入也不再比较日期。旧文件即使日期已过，以及不带该字段的新文件，都应可直接导入；原有密钥、endpoint 和 provider 完整性校验保留。
3. 工程 `Info.plist` 默认版本为 1.0、build 2。先在 App Store Connect 核对该版本已使用的 build；若 2 已占用，改为未使用的更高数字，不能再次上传 build 1。
4. 按 [签名与 TestFlight](FRIEND_SIGNING_TESTFLIGHT.md) 使用 Release / 通用 iOS 设备执行 Archive、Validate、上传并开放测试。核对分发的 `aps-environment` 和 `CallBridgePushEnvironment` 均为 `production`，保留已有正确的 PushKit/CallKit 接线。
5. 告知使用者实际 commit、版本/build 与 TestFlight 可安装状态。使用者安装该新构建后，可直接导入手机已收到的原配对文件；无需因旧 `expiresAt` 重新生成配对或更改 Android/provider 配置。

只有更新 iPhone App 才会移除已安装构建的旧校验。刷新 plist、修改服务器或取得 APNs 私钥都不会改变 TestFlight 1.0 (1) 中的导入判断。本次本地配对回归不代替签名、Archive、TestFlight 上传或手机导入验证；不要据源码已修复报告旧构建已修复。

## 1. 执行范围与已有授权

这份文档是操作说明，不授予 Apple 账号、Mini 或其他设备的访问权限。只在账号持有人的直接指令和既有授权范围内执行。先做只读核对；缺失资源、修改 capability 或必要的重新签名/上传，只有持有人已有授权覆盖时才继续，未覆盖时说明具体缺项和影响后由持有人决定。

使用 Apple 官方 [Developer Account](https://developer.apple.com/account/) 和 [App Store Connect](https://appstoreconnect.apple.com/) 入口。登录、密码、OTP 和验证码由持有人在正常认证入口完成，不要求写入聊天、脚本、命令参数或日志。不撤销旧 key、不更改其他 App、不更换团队/Bundle ID、不购买服务或产生费用；这些不在本说明范围内。

## 2. 定位已经安装的 TestFlight 构建

1. 在 App Store Connect 的本 App → TestFlight 中，记录使用者已安装构建的版本号和 build number。若当前账号看不到安装信息，只记录能确认的构建，不猜测。
2. 在朋友本机、既有构建记录或 CI 产物中，定位该构建对应的 `.xcarchive`、上传时导出的 `.ipa` 或已签名 `.app`，并核对源码 commit。不要用刚 clone 的仓库 HEAD 冒充已上传构建的 commit；无法追溯时标为未确认。
3. `.xcarchive` 的 App 通常在 `Products/Applications/<APP_NAME>.app`；已有导出 `.ipa` 可在本机私有临时目录解包，读取 `Payload/<APP_NAME>.app`。以对应上传构建的 Distribution 签名产物为优先依据，避免误用旧 Debug App。

同一手机可能同时装有不同 Bundle ID 的同名 App；即使显示名和版本/build 相同，也须按实际 Bundle ID 对应分发产物，不能据此认定操作的是新 TestFlight 包。

若当前 iPhone 安装产物无法直接导出，改用朋友一侧对应版本/build 的现成分发产物；找不到时标为未确认，并说明需要哪份对应产物，不用源码或“TestFlight 已安装”推断签名字段。

对已经定位的 `.app`，以下命令只输出必要的非秘密元信息，不打印完整 profile、签名或 entitlement：

```sh
CALLBRIDGE_SIGNED_APP="/absolute/path/to/the/matching/CallBridge.app"
python3 - "$CALLBRIDGE_SIGNED_APP" <<'PY'
from pathlib import Path
import json, plistlib, subprocess, sys

app = Path(sys.argv[1])
with (app / "Info.plist").open("rb") as source:
    info = plistlib.load(source)
result = subprocess.run(
    ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)],
    capture_output=True,
)
try:
    entitlements = plistlib.loads(result.stdout) if result.returncode == 0 else {}
except (ValueError, plistlib.InvalidFileException):
    entitlements = {}
fields = {
    "bundle_id": info.get("CFBundleIdentifier"),
    "version": info.get("CFBundleShortVersionString"),
    "build": info.get("CFBundleVersion"),
    "team_id": entitlements.get("com.apple.developer.team-identifier"),
    "aps_environment": entitlements.get("aps-environment"),
    "client_push_environment": info.get("CallBridgePushEnvironment"),
    "background_modes": info.get("UIBackgroundModes"),
}
print(json.dumps(fields, ensure_ascii=False, indent=2))
PY
```

核对实际 Bundle ID、Team ID、版本/build 与本次 App Store Connect 记录一致；TestFlight 分发签名的 `aps-environment` 应为 `production`，本项目的 `CallBridgePushEnvironment` 也应为 `production`，后台模式保留 `audio`、`voip`。

Archive 中的原始 App 可能尚未经过 Distribution 导出时的重新签名。若只找到原始 archive，不能仅因其中 entitlement 是 `development` 就认定已上传的 TestFlight 构建错误并要求重发；继续核对该 archive 对应的分发导出产物/上传记录，无法确认的字段如实标注。

核对与该构建对应的源码和 target Sources：

- `VoIPPushController.swift` 使用 `PKPushRegistry`，注册 `.voIP` 并处理 token 和来电回调。
- `BridgeModel.swift` 启动该注册，将来电交给 `IncomingCallCoordinator`，并向 provider 注册当前 token。
- `SystemCallController.swift` 使用 CallKit 报告系统来电；协调器/客户端含 `JOIN(call_id)` 路径。
- 上述源码确实属于打包 target；只看到仓库中有同名文件不证明已经编入当前 TestFlight 构建。

仅凭签名成功、`audio/voip` 后台声明或新 clone 的源码，不能认定当前构建已含 PushKit。源码/构建来源证据不足时记录缺口，不以发测试推送来替代本次核对。

## 3. 先核对 App ID 和已有 APNs key

在对应团队的 Certificates, Identifiers & Profiles 中：

1. **Identifiers → 实际 Bundle ID**：查看该 App ID 的 Push Notifications 是否已启用。先记录现状，已经启用就保留。不要另建 App ID，也不要把示例 `com.example.callbridge` 当成朋友实际 App ID。
2. **Keys**：先查看已有 key 的服务、Key ID、环境和范围。选择已启用 Apple Push Notification service、适用于本团队/本 App 且覆盖 production VoIP 推送的 token signing key；不要拿 App Store Connect API key、Sign in with Apple key 或普通 APNs TLS 证书替代 `.p8` token signing key。
3. 核对范围：新 key 可为环境限定的 Team Scoped 或 Topic Specific；已有兼容两种环境的旧 key 仍可能可用，无需仅为改成新形式而替换。Topic Specific key 要核对范围覆盖本 App 所需的 VoIP topic，不能只凭同一 Team 判为适用。目标 topic 是 `<ACTUAL_BUNDLE_ID>.voip`，目标环境是 production。以当前 Apple 后台及官方说明为准；无法确认适用性时如实报告。
4. 核对所选 key 对应的私有 `.p8` 是否已经在持有人批准查看的备份目录或既有 provider 中保存。只确认匹配的 Key ID、文件存在及访问权限，不输出私钥内容、不扫描无关目录或主机。

### 本次 `TopicDisallowed` 的具体核对顺序

1. 从使用者一侧取得 `<TEAM_ID>`、`<KEY_ID>`、`<ACTUAL_BUNDLE_ID>` 和 `<ACTUAL_BUNDLE_ID>.voip` 的非秘密元信息。在该团队的 **Keys → 对应 Key ID** 查看 Apple Push Notification service 是否启用，并记录当前环境、Team Scoped / Topic Specific 类型及关联范围；`.p8` 文件本身不包含这些后台授权元数据。
2. 目标环境是 production。Team Scoped key 应属于同一团队并覆盖 production；兼容 production 的既有旧 key 也可复用。Topic Specific key 要按后台实际关联的 App/topic 范围核对本 App 及其 VoIP 推送适用性，不能只看到同一 Team 或裸 Bundle ID 就报告已验证。保留 `apns-push-type: voip` 与 `apns-topic: <ACTUAL_BUNDLE_ID>.voip`；不要通过改成普通通知 topic 绕过错误，也不另建带 `.voip` 后缀的 App ID。
3. 在 **Identifiers → `<ACTUAL_BUNDLE_ID>`** 核对同一团队的 Push Notifications capability；与第 2 节的实际分发产物 Bundle ID、团队和 production entitlement 对齐。只报告已看到的字段；仓库默认的示例 Bundle ID、Release 配置和已上传构建不能互相替代。
4. 若已证实只是现有 key 未启用 APNs 服务，按持有人已有授权在 **Key → Edit → Services** 补对应服务；若是范围不适用，先找同团队已覆盖 production VoIP 的现成 key 及其私有文件。是否可直接调整当前 key 的具体范围，以 Apple 后台实际可用操作为准；只有没有可复用资源时才提出必要的新 key，不撤销旧 key。若只有服务端 key/范围改变，通常无需重发 App；只有实际分发 entitlement 或 App ID capability 缺失涉及 profile 时，才处理本 App 所需产物。
5. 把上述非秘密核对结果交回使用者一侧，必要时修正 Mini 对应配置，再执行一次不拨真实号码的 production APNs 检查。HTTP 200 才表明 Apple 接受；还需单独观察 iPhone PushKit / CallKit。该检查不是蜂窝双向音频验收，也不要求朋友部署 provider、操作 Android 或发送推送。

Apple 私钥只能下载一次。后台存在 key 而 Download 按钮已不可用，不表示可以重新下载；先查持有人的私有备份或已授权的既有 provider。找不到时说明“已有 key，但私有文件未找到”；不得假装已取得，也不得擅自撤销旧 key、轮换或清空其他 App 正在使用的资源。

## 4. 只有实际缺项才补齐

在持有人授权覆盖的范围内，按查明的缺项操作：

- **构建和 App ID 已满足要求，且已有适用 key 与 `.p8`**：直接复用这些资源；已安装包含配对修复的 1.0 (2) 时不重复上传，也无需为此重新创建 APNs key。
- **缺少适用 key，或现有 key 的私有文件确实无法找回**：由具备所需角色且已获持有人授权的人，在官方 Keys 入口创建启用 APNs 的适用 key，选择覆盖本 App production VoIP 的环境/范围并妥善下载 `.p8`。不以撤销旧 key 为前置步骤；若配额/角色等阻止创建，记录具体阻塞并交持有人处理，不自动变更其他资源。
- **App ID 确实未启用 Push Notifications**：只为此 App 补 capability。Apple 提示相关 provisioning profiles 需重新生成时，更新本 App 使用的 profile，不波及其他 App。随后核对现有分发产物是否满足实际 entitlement 要求。
- **当前 TestFlight 构建实际缺少 production entitlement、正确环境配置或 PushKit 接线**：只补这些已确认缺项，保持原团队和 Bundle ID，按现有签名/上传流程完成必要的新 build，并告知使用者替换为对应 TestFlight 构建。若只是新增/复用服务端 APNs key，通常不需要重新打包 App。

不要因本次准备而重跑全部本地模拟、部署另一套 provider、修改音频/通话时限或新增客户端功能。不能完成某一缺项时，先交付已确认的非秘密结果，明确尚缺什么。

## 5. 交给使用者一侧的内容

普通文字只交以下非秘密元信息；实际值通过双方既有私下沟通交付，不提交公开仓库：

```text
实际 Bundle ID: <ACTUAL_BUNDLE_ID>
Apple Team ID: <TEAM_ID>
APNs Key ID: <KEY_ID>
VoIP topic: <ACTUAL_BUNDLE_ID>.voip
APNs key 环境与范围: <production或兼容production的既有key；实际scope>
本次 TopicDisallowed 核对: <APNs服务、环境、关联范围、App ID capability及各自证据>
TestFlight 版本 / build: <VERSION> / <BUILD_NUMBER>
对应源码 commit: <COMMIT或未确认>
App ID Push Notifications: <已确认启用或缺项>
分发 aps-environment: <production或未确认；注明产物来源>
CallBridgePushEnvironment: <production或未确认>
PushKit/CallKit/JOIN 编入构建: <证据或未确认>
是否改动/重发: <未改动，或本App的必要改动与新build>
p8 私密交付状态: <已有适用文件待交付/已私密交付/未找到>
剩余缺项: <无或具体缺项>
```

`.p8` 通过持有人认可的私密文件通道单独交付给使用者一侧；不把内容贴入聊天、日志、工单、Git、iOS 资源或公开链接。文件可命名为 `AuthKey_<KEY_ID>.p8`，私有目录仅允许所需账号访问，文件权限为 `0600`。不要把私钥本身或 token 放到 shell 命令参数中。

报告也不附 `embedded.mobileprovision` 全文、注册 push token、provider token 或配对密钥，只保留上面选择的字段和核对结果。

Mini 上的最终仓库外私有目录和传输目的地由使用者一侧确认；`/absolute/private-callbridge/AuthKey_<KEY_ID>.p8` 只是路径模板，不是已部署位置或给朋友的 Mini 访问授权。未确定私密通道时先完成元信息交付，私钥留在持有人控制的私有位置，待通道确定后交付。

使用者一侧负责：Mini 上的 `mode: "apns"` 配置、私钥落盘和 HTTPS 入口；生成匹配的 provider/Android/iPhone 配对；启动服务并确认 TestFlight 的 production token 注册；之后安排真实锁屏新来电与双向通话验收。朋友完成资源准备，不等于真实 APNs 或锁屏验收已通过。

相关项目说明：[provider 配置](PROVIDER.md)、[配对](PAIRING.md)、[签名/TestFlight](FRIEND_SIGNING_TESTFLIGHT.md)、[验证范围](VERIFICATION.md)。

## Apple 官方依据

- [创建私钥及 APNs 环境/范围](https://developer.apple.com/help/account/keys/create-a-private-key/)
- [key 只可下载一次及撤销影响](https://developer.apple.com/help/account/keys/revoke-edit-and-download-keys/)
- [启用 App capability 与 profile 影响](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/)
- [APNs token 认证及 key 范围](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
- [APNs 请求、VoIP push type 与 topic](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
- [APNs HTTP 状态与 TopicDisallowed 等 reason](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns)
- [PushKit 接入](https://developer.apple.com/documentation/pushkit/supporting-pushkit-notifications-in-your-app)
