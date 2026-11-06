# 生成并导入设备配对

两台手机需要可互访的 Tailscale 网络。先准备自己的 provider HTTPS 根地址；Node provider 的配置见 [provider 说明](PROVIDER.md)。

## 生成私有配置

在 Mac 上的仓库根目录编译生成器，再为本次生成创建一个仓库外的空私有目录：

```sh
umask 077
CALLBRIDGE_TOOLS_DIR="$(mktemp -d /tmp/callbridge-tools.XXXXXX)"
xcrun swiftc ios/CallBridge/CallBridge/FrameProtocol.swift \
  scripts/diagnostics/PrepareCallBridgePairing.swift \
  -o "$CALLBRIDGE_TOOLS_DIR/prepare"
CALLBRIDGE_PAIRING_DIR="$(mktemp -d /tmp/callbridge-pairing.XXXXXX)"
"$CALLBRIDGE_TOOLS_DIR/prepare" "<ONEPLUS_TAILNET_IPV4>" \
  "$CALLBRIDGE_PAIRING_DIR" \
  --provider-url "https://provider-host.example-tailnet.ts.net"
```

把 `<ONEPLUS_TAILNET_IPV4>` 替换为自己一加的实际 Tailnet IPv4，并替换示例 HTTPS 地址。生成器只接受有效的 Tailnet IPv4，输出目录必须是绝对路径且原先为空。它生成随机直连密钥、独立 provider token 和配对 UUID，不打印这些秘密。

| 私有产物 | 用途 |
| --- | --- |
| `android.properties` | Android 桥的绑定地址、直连密钥和 provider 配置 |
| `CallBridgePairing.plist` | iPhone 配对导入文件 |
| `provider-pair.json` | provider 配置 `pairs` 数组的一项，只含 `pairing_id` 与 token 摘要 |

文件使用 0600 权限。把 `provider-pair.json` 中的一项放入自己的私有 provider JSON 配置的 `pairs` 数组；两端配置已包含同一个 provider 原 token，不能再另配不同 token。

`--provider-url` 可省略，用于原前台直连调试；锁屏新来电需要它。显式合成模拟可加 `--simulation`，此时 Android 配置为 `allowAnswer=false`，不会控制真实电话。

## iPhone / TestFlight

将 `CallBridgePairing.plist` 通过自己的私有传输方式送到 iPhone 的“文件”。打开 App 的“设备配对”→“导入设备配对文件”，在系统文件选择器中选中它；该入口在 Release/TestFlight 也可使用，文件没有导入期限。

App 验证后将配对写入 Keychain。生成器不再输出 `expiresAt`；新 App 也会忽略旧文件中的该字段，即使日期已过，也可直接导入原文件，无需重新生成或更换两端/provider 的配对。App 可能申请尚未授予的麦克风权限；持久配对和正常通话没有总时长上限。

目前已安装的 TestFlight 1.0 (1) 仍包含旧导入期限判断，必须先更新到包含本次修复的新构建；修改服务器或重新传输同一文件不会改变旧 App 的校验。下一构建的具体步骤见 [朋友 Codex 说明](FRIEND_APNS_CODEX.md)。

## Android 与 provider

将 `android.properties` 送到自己的 Android shell 可读私有路径并保留 0600 权限。在具备 [Android 运行前提](ANDROID_PREREQUISITES.md) 的设备上，显式启动桥进程；同一配对可继续等待下一通，每通生成新的 session。

provider 按匹配的 `pairing_id` 和摘要鉴权。iOS 导入的字段为 `providerURL` / `providerToken`，Android properties 字段为 `providerUrl` / `providerToken`。iOS 通过 HTTPS 注册当前 VoIP push token，Android 发布新来电与结束事件。

这些私有配置不属于源码、测试样本或发布包，不应提交到 Git 或随公开仓库分发。真实 APNs、锁屏界面与真人双向通话仍按 [验证范围](VERIFICATION.md) 单独验收。
