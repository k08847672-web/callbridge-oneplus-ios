# 朋友签名与 TestFlight

朋友从公开仓库下载源码，在自己的 Mac 和 Apple Developer 团队下构建、签名和上传。使用者可以通过 TestFlight 安装；不需要向仓库作者提供 Apple 密码、验证码或私钥。

## 1. 配置团队和 App ID

1. 在 Xcode 打开 `ios/CallBridge/CallBridge.xcodeproj`，选择 `CallBridge` target。
2. 在 Signing & Capabilities 选择朋友的付费 Apple Developer 团队，启用 Automatically manage signing。
3. 将 Bundle Identifier 改为该团队拥有的唯一 App ID。工程公开副本不包含开发者 Team ID。
4. 为该 App ID 启用 Push Notifications，确认 target 使用 `CallBridge.entitlements`，并保留音频/VoIP 后台模式。
5. 在 App Store Connect 用相同 Bundle ID 创建 App 记录，按团队角色分配上传和测试权限。

普通 Personal Team 本机签名不能替代锁屏 VoIP 推送及 TestFlight 分发所需的团队能力。Apple 团队资格、能力配置和签名成功也不能代替真实 APNs 与锁屏通话验收。

## 2. 配置 APNs provider

朋友在 Apple Developer 后台创建适用的 APNs token signing key，记录对应 Key ID、Team ID 和 App ID。`.p8` 私钥只放在 provider 主机的私有文件中，限制文件访问权限，不加入 iOS 资源、Git 或聊天。

provider 的 VoIP topic 应为 App 的 Bundle ID 加 `.voip`。TestFlight/正式分发使用 production APNs；开发签名构建使用与其 entitlement 一致的环境。不同环境的 push token 不能混用。按照 [provider 说明](PROVIDER.md) 填写私有配置并启动。

将客户端可访问、具有有效 TLS 证书的 provider HTTPS 根地址与独立认证 token 按应用配置入口导入 iPhone 和 Android。Node HTTP 后端可使用已有反代或 Tailscale Serve 提供 HTTPS，具体见 provider 说明。该 token 与两机直连的配对密钥用途不同；模板不携带真实值。

## 3. Archive 与上传

1. 选择 Release 配置和通用 iOS 设备目标，确认 Bundle ID、Team、版本号及 build number 正确。
2. 使用 Product → Archive；在 Organizer 中 Validate App，再选择 Distribute App → App Store Connect 上传。
3. 在 App Store Connect 等待构建处理完成，按实际情况回答加密/出口合规问题。
4. 加入内部测试者，或创建外部测试组并提交 Apple 要求的 Beta App Review，再向获准测试者开放。
5. 使用者通过自己的 Apple Account 接受 TestFlight 邀请，安装该构建。

TestFlight 构建通常有效 90 天；后续需要上传新的 build。朋友在自己的环境管理证书、profiles 和上传权限。将个人签名设置保留在本机，公开提交不要带入 Team ID、私人邮箱、证书或 provisioning profile。

## 4. 实机验收

确认两机 Tailnet 连通、provider 可达和 iOS 推送注册完成后，再检查：

- iPhone 已锁屏时，新 SIM 来电能否经真实 APNs 唤醒并显示系统接听界面。
- 接听后，双方是否确实听见彼此的语音；两台手机应分开以排除串音。
- 锁屏续行、短时断网恢复、用户挂断和恢复超时能否正确结束同一原 Call。
- 结束后麦克风、音频、连接和系统通话界面能否释放。

本地 mock、Simulator 构建和非零音频帧只证明相应的技术步骤，不证明上述实机行为已通过。

Apple 参考：

- <https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit>
- <https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns>
- <https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/>
