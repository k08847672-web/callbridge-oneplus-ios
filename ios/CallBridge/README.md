# CallBridge iOS

使用 Xcode 打开本目录的 `CallBridge.xcodeproj`，选择共享 `CallBridge` scheme。公开工程的 Team 为空、Bundle ID 为 `com.example.callbridge` 示例；签名前选择自己的团队并改为自己的唯一 Bundle ID。

- [仓库说明与构建](../../README.md)
- [朋友签名与 TestFlight](../../docs/FRIEND_SIGNING_TESTFLIGHT.md)
- [生成并导入设备配对](../../docs/PAIRING.md)
- [真实 APNs provider 与本地 mock](../../docs/PROVIDER.md)
- [协议](../../docs/PROTOCOL.md)
- [已验证与未验证范围](../../docs/VERIFICATION.md)

Release/TestFlight 可通过“设备配对”→“导入设备配对文件”使用系统文件选择器导入私有配置；有效配对保存在本机 Keychain。导入无期限，旧文件中的 `expiresAt` 字段也会被忽略。不要将真实配置、账户、Team ID、证书或私钥加入公开提交。
