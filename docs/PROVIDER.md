# APNs provider 配置与本地 mock

`callbridge_push/server.mjs` 同时提供真实 APNs 和本地 mock 模式。真实模式使用 Node.js 内置 HTTP/2 与 crypto 生成 APNs token 并发送 VoIP push，无第三方 npm 运行时依赖。需要 Node.js 20+。

provider 主机和监听地址可以自行选择。iPhone 与 Android 必须能访问客户端配置的 HTTPS 入口；真实模式还需要主机可以访问 Apple APNs。语音和通话控制仍经两机间的 Tailscale 直连，不经过 provider。本仓库不自动部署服务、开放端口或创建 Apple 凭据。

## 配置文件

将 `callbridge_push/config.example.json` 复制到仓库外的私有目录，按自己的环境填写。私有配置和运行状态文件都不加入 Git。

| 字段 | 含义 |
| --- | --- |
| `listen` / `port` | provider 本机监听地址和端口 |
| `mode` | `mock` 或 `apns` |
| `state_file` | 私有注册/状态持久化文件路径，服务保存时使用 0600 权限 |
| `pairs` | 允许注册与发布事件的配对项 |
| `pairs[].pairing_id` | iPhone 和 Android 配置使用的同一个配对标识 |
| `pairs[].provider_token_hash` | 独立 provider Bearer token 的 SHA-256 十六进制摘要 |
| `apns.team_id` | 签名团队的 Apple Team ID |
| `apns.key_id` | APNs token signing key 的 Key ID |
| `apns.topic` | iOS App Bundle ID 加 `.voip` |
| `apns.private_key_path` | provider 主机上私有 `.p8` 文件的路径 |

使用 [配对生成器](PAIRING.md) 一次生成两端配置和 `provider-pair.json`。把该 JSON 对象作为自己私有 provider 配置 `pairs` 数组的一项：它包含对应的 `pairing_id` 与 SHA-256 摘要，两端私有文件已经带入同一原 token。不要另生成不匹配的 token，也不要把原 token 放进启动参数、公开示例、日志或 shell 历史。

iOS 配对导入字段为 `pairing_id`、`providerURL`、`providerToken`；Android properties 对应字段为 `pairingId`、`providerUrl`、`providerToken`。provider token 与音频直连的 `pairingKey` 分开。

## iOS 可用的 HTTPS 入口

Node 服务本身监听 HTTP。真实 iOS 注册使用 URLSession，受系统 ATS 与 TLS 证书验证约束；任意 Tailnet IP 的明文 HTTP 不是可依赖的 App 注册入口。

将 Node 配置为监听 `127.0.0.1:47632`，再把自己已有的有效证书 HTTPS 反向代理指向该回环地址。也可在所选 provider 主机使用已有 Tailscale 的 Serve 功能提供 Tailnet HTTPS：

```sh
tailscale serve status
tailscale serve --bg http://127.0.0.1:47632
```

执行前检查该主机现有 Serve 配置，按自己的服务安排接入。Tailscale 的 DNS/HTTPS 配置和访问权限需可用；以 Serve 输出的实际 HTTPS URL 为准。例如客户端填写 `https://provider-host.example-tailnet.ts.net`，不附加 `/v1/register` 或 `/v1/calls`，两端在此根地址下调用对应 API。

这只是自行部署时的可选接入方式，仓库准备和本地测试不会运行上述配置命令。iOS App 不设置全局 ATS 明文放行；本地 mock 的回环 HTTP 测试不能证明真实 App 的 HTTPS 注册已通过。

## 本地 mock

在私有配置中选择 `mode: "mock"`，监听本机回环地址，使用私有临时 state 文件。mock 走相同 HTTP API，用于检查注册、认证、响铃/结束事件与去重；不连接真实 APNs，不唤醒 iPhone。

```sh
node callbridge_push/server.mjs --config /path/to/private-callbridge/mock.json
```

provider 单独测试：

```sh
node --test callbridge_push/tests/*.test.mjs
```

集中本地验证使用仓库根目录的 `scripts/test-callbridge-local.sh`。以实际脚本结果为准，不把 mock 成功写成真实 APNs 投递成功。

## 真实 APNs

在私有配置中选择 `mode: "apns"`，填入朋友团队的 Team ID、Key ID、正确 VoIP topic 与 `.p8` 私钥路径。Node 可保持回环监听，通过上面的 HTTPS 入口供两台手机访问；服务器区域不限。

```sh
node callbridge_push/server.mjs --config /path/to/private-callbridge/production.json
```

客户端向 `/v1/register` 注册 `push_token` 和 `environment`。环境只接受 `sandbox` 或 `production`：开发签名使用匹配的 sandbox token；TestFlight 使用 production token。配置改变或重新安装后，使用客户端当前注册的 token。

Android 通过 `/v1/calls` 发布 `ringing` / `ended`。provider 使用独立 Bearer token 认证，按 `call_id` 与 `revision` 去重；只有有效的新响铃发送一次 VoIP push。payload 为 `{aps:{},pairing_id,call_id,revision,state:"ringing"}`，不包含电话号码、联系人、音频或直连配对密钥，也不设置应用层来电寿命。

provider 在发送前持久化这次尝试，避免重复事件或进程重启导致重复推送。发送失败返回 `502 push_attempt_failed`；结果不确定的同一次推送不会自动重发。`ended` 只保存结束状态，不发送新的 VoIP push，迟到响铃不会覆盖已结束的同一个 Call。

真实 APNs 接受请求只证明 provider 的发送步骤。iPhone 收到推送、CallKit 报告来电、JOIN 匹配、用户接听、两向声音以及挂断都需要单独观察。签名与 TestFlight 步骤见 [朋友签名](FRIEND_SIGNING_TESTFLIGHT.md)。
