# 交给朋友 Codex：核对 TestFlight 与 APNs 资源

请先核对已经完成的工作，再补缺项。本 App 已通过 TestFlight 安装，但目前不确定朋友的 Apple 团队是否已经准备 APNs 资源；不要因此重复创建 key 或重新发版。

朋友负责核对签名产物、Apple 资源和私密交付；本次 provider 部署在使用者的 Mini，由使用者一侧负责。朋友无需部署服务器、配置 Mini、操作 Android、拨号或发送测试推送。服务器实现已经在 `callbridge_push/server.mjs`，无需另写服务。

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

Apple 私钥只能下载一次。后台存在 key 而 Download 按钮已不可用，不表示可以重新下载；先查持有人的私有备份或已授权的既有 provider。找不到时说明“已有 key，但私有文件未找到”；不得假装已取得，也不得擅自撤销旧 key、轮换或清空其他 App 正在使用的资源。

## 4. 只有实际缺项才补齐

在持有人授权覆盖的范围内，按查明的缺项操作：

- **构建和 App ID 已满足要求，且已有适用 key 与 `.p8`**：直接复用并交付，无需改 App、重新 Archive 或上传 TestFlight。
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
- [PushKit 接入](https://developer.apple.com/documentation/pushkit/supporting-pushkit-notifications-in-your-app)
