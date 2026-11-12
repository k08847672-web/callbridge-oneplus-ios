# 朋友签名与 TestFlight

朋友从公开仓库下载源码，在自己的 Mac 和 Apple Developer 团队下构建、签名和上传。使用者可以通过 TestFlight 安装；不需要向仓库作者提供 Apple 密码、验证码或私钥。

## 1. 配置团队和 App ID

1. 在 Xcode 打开 `ios/CallBridge/CallBridge.xcodeproj`，选择 `CallBridge` target。
2. 在 Signing & Capabilities 选择朋友的付费 Apple Developer 团队，启用 Automatically manage signing。
3. 将 Bundle Identifier 改为该团队拥有的唯一 App ID。工程公开副本不包含开发者 Team ID。
4. 为该 App ID 启用 Push Notifications，确认 target 使用 `CallBridge.entitlements`，并保留音频/VoIP 后台模式。
5. 在 App Store Connect 用相同 Bundle ID 创建 App 记录，按团队角色分配上传和测试权限。

本轮为已有 App 增加验证码收件箱，沿用现有 `com.sunbelife.callbridge` App 记录和已配置团队，不新建 App ID、不更换钥匙串归属、不新增会员。公开工程继续保留示例 Bundle ID 和空 Team；实际签名值只在签名方本机覆盖。现有 1.0 (3) 的通话、配对和音频功能必须保留，不加入 iPhone 主动外呼。

普通 Personal Team 本机签名不能替代锁屏 VoIP 推送及 TestFlight 分发所需的团队能力。Apple 团队资格、能力配置和签名成功也不能代替真实 APNs 与锁屏通话验收。

## 2. 配置 APNs provider

朋友在 Apple Developer 后台创建适用的 APNs token signing key，记录对应 Key ID、Team ID 和 App ID。`.p8` 私钥只放在 provider 主机的私有文件中，限制文件访问权限，不加入 iOS 资源、Git 或聊天。

provider 的 VoIP topic 应为 App 的 Bundle ID 加 `.voip`。TestFlight/正式分发使用 production APNs；开发签名构建使用与其 entitlement 一致的环境。不同环境的 push token 不能混用。按照 [provider 说明](PROVIDER.md) 填写私有配置并启动。

验证码提醒使用**普通 APNs alert**，topic 是 App 的 Bundle ID（不加 `.voip`），使用 AppDelegate 注册得到的普通 push token，与 PushKit token 分开保存。复用已有 APNs key、会员和 provider 配对认证，无需 Bark；现有 key 若已覆盖该 App 的普通 Push Notifications，不创建新 key。不得通过 PushKit 发送短信提醒。固定通知只显示“收到验证码短信 / 打开应用查看”，payload 仅含 `kind=verification_sms`、`pairing_id` 和 `message_id` 路由信息，不含发件人、验证码或短信正文。

iPhone 自动向现有 provider 的 `/v1/sms/register` 注册普通 token，并通过 `/v1/sms/sync` 补拉完整记录，全部为 Bearer 认证的 POST JSON。Mini 的对应接口由本轮服务端发布提供；签名方无需重做配对、修改 Mini 或启用手动通话桥连接。App 启动、回到前台、点击通知和下拉收件箱均会补拉，拒绝通知权限仍可打开 App 获取短信。记录与每个配对的同步游标原子保存到 App 的 Application Support，并使用 iOS 首次解锁后文件保护；清除系统通知不删除本地记录，无自动过期或数量淘汰。短信和验证码不写诊断日志。

将客户端可访问、具有有效 TLS 证书的 provider HTTPS 根地址与独立认证 token 按应用配置入口导入 iPhone 和 Android。Node HTTP 后端可使用已有反代或 Tailscale Serve 提供 HTTPS，具体见 provider 说明。该 token 与两机直连的配对密钥用途不同；模板不携带真实值。

## 3. Archive 与上传

1. 选择 Release 配置和通用 iOS 设备目标，确认 Bundle ID、Team、版本号及 build number 正确。本轮验证码收件箱源码为 **1.0 (4)**，上一版为 1.0 (3)。上传前核对 App Store Connect，若 build 4 已占用，递增为未使用的更高 build number，保留既有团队、实际 Bundle ID、Push Notifications 和音频/VoIP 后台能力。
2. 使用 Product → Archive；在 Organizer 中 Validate App，再选择 Distribute App → App Store Connect 上传。
3. 在 App Store Connect 等待构建处理完成，按实际情况回答加密/出口合规问题。
4. 加入内部测试者，或创建外部测试组并提交 Apple 要求的 Beta App Review，再向获准测试者开放。
5. 使用者通过自己的 Apple Account 接受 TestFlight 邀请，安装该构建。

TestFlight 构建通常有效 90 天；后续需要上传新的 build。朋友在自己的环境管理证书、profiles 和上传权限。将个人签名设置保留在本机，公开提交不要带入 Team ID、私人邮箱、证书或 provisioning profile。

本轮签名交接复用该 App 已有团队、Bundle ID 和签名材料；公开工程的空 Team / 示例 Bundle ID 由签名方在本机覆盖。保留已安装 App 的配对和已有 APNs key。可先在仓库根目录执行新增核心的合成自测，再用已有签名环境 Archive：

```sh
bash scripts/test-callbridge-sms-ios.sh

xcodebuild -project ios/CallBridge/CallBridge.xcodeproj \
  -scheme CallBridge -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath /path/to/private-callbridge-release/CallBridge.xcarchive \
  DEVELOPMENT_TEAM='<existing team ID>' \
  PRODUCT_BUNDLE_IDENTIFIER='<existing actual Bundle ID>' \
  MARKETING_VERSION=1.0 CURRENT_PROJECT_VERSION=4 \
  CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates archive

xcodebuild -exportArchive \
  -archivePath /path/to/private-callbridge-release/CallBridge.xcarchive \
  -exportOptionsPlist /path/to/private-callbridge-release/ExportOptions.plist \
  -exportPath /path/to/private-callbridge-release/export \
  -allowProvisioningUpdates
```

`ExportOptions.plist` 使用签名方私有现有配置，`method=app-store-connect`、`destination=upload`，团队与上述 Archive 相同；通过已登录的 Xcode 账号完成上传。占用 build 4 时同步替换命令中的 build number。Archive 后检查已签名 App 的 `aps-environment=production`、Info.plist 的 `CallBridgePushEnvironment=production`、Bundle ID、版本/build 和原有 audio/voip 后台能力。完成后交回实际版本/build、Bundle ID、上传及 TestFlight 可用状态，不回传证书、私钥、账号或配置内容。

2026-11-12 本地已通过 Xcode 27.2 / iPhoneOS 27.2 的无签名 Release 真目标构建。默认 `xcode-select` 指向 Command Line Tools，必要时仅在命令前设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`；不用修改系统开发目录。CoreSimulator 版本不匹配会打印警告，未阻塞 `generic/platform=iOS`。此结果不代表签名、上传或真机推送验收。

## 4. 实机验收

确认两机 Tailnet 连通、provider 可达和 iOS 推送注册完成后，再检查：

- 新验证码短信到达时，锁屏提醒只有泛化标题和正文，没有号码、验证码或短信预览；点击通知进入同一条短信详情。
- 收件箱按短信收到时间倒序；识别到唯一验证码时可复制，未能确定唯一验证码时仅展示正文，不猜码。
- 清除通知、关闭并重开 App、重启 iPhone 后，已经同步的短信记录仍保留；离线时也可查看已保存记录。
- 暂时断网或关闭通知权限后再打开 App，自动补拉此前未收到提醒的记录，不要求点击“连接”。恢复通知后普通 APNs 与来电 PushKit 各用各自 token。
- 用原有配对完成一次真实来电与双向语音，确认新增收件箱未影响下列通话行为；不要以合成测试代替真人听音。

- iPhone 已锁屏时，新 SIM 来电能否经真实 APNs 唤醒并显示系统接听界面；有姓名时显示姓名，无姓名时显示允许公开的号码。
- 通话结束后，系统“电话”的 Recents 是否出现同一通话的姓名/号码。
- 接听后，双方是否确实听见彼此的语音；两台手机应分开以排除串音。
- 锁屏续行、短时断网恢复、用户挂断和恢复超时能否正确结束同一原 Call。
- 结束后麦克风、音频、连接和系统通话界面能否释放。

本地 mock、Simulator 构建和非零音频帧只证明相应的技术步骤，不证明上述实机行为已通过。

Apple 参考：

- <https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit>
- <https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns>
- <https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/>
