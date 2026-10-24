# CallBridge 协议

音频和通话控制通过已认证的两机 Tailscale TCP 连接传输。provider 只负责推送注册与来电事件；语音不经过 provider。

## 直连帧：PJZ-CALL/1

帧头为 8 字节：`type:u8`、`reserved:u8=0`、`length:u16BE`、`sequence:u32BE`。每方向序号从 0 递增，载荷上限 1024 字节。PCM 为 16 kHz、单声道、PCM16LE，每帧 320 样本 / 640 字节。

服务端先发 32 字节 challenge。客户端以随机 256-bit 配对密钥计算 `HMAC-SHA256(key, UTF8("PJZ-CALL/1") || challenge)` 并返回。新连接都必须重新完成认证；运行时会话 token 不能替代配对认证。

| Type | 名称 | 方向 / 载荷 |
| --- | --- | --- |
| `0x01` | CHALLENGE | Android → iPhone，32 字节 |
| `0x02` | AUTH | iPhone → Android，32 字节 HMAC |
| `0x10` | DOWNLINK | Android → iPhone，640 字节 PCM |
| `0x11` | UPLINK | iPhone → Android，640 字节 PCM |
| `0x20` | STATE | Android → iPhone，`0=idle`、`1=ringing`、`2=active` |
| `0x21` | SESSION | Android → iPhone，32 字节，仅存内存的会话 token |
| `0x30` | ANSWER | iPhone → Android，单字节 `1` |
| `0x31` | RESUME | iPhone → Android，原 32 字节 SESSION token |
| `0x32` | HANGUP | iPhone → Android，原 32 字节 SESSION token |
| `0x33` | JOIN | 双向，36 字节小写 UUID ASCII `call_id` |
| `0x40` | HEARTBEAT | 双向，空载荷 |
| `0x50` | SIMULATION | 显式 Debug 合成服务器标记 |

`JOIN(call_id)` 用于 PushKit 唤醒后加入当前响铃来电。它与已经接听的通话恢复 `RESUME(session_token)` 不同；UUID 不授予认证权限。只有完成配对认证且来电 ID 匹配，客户端才可以关联该响铃会话。

已接听通话连续 4 秒没有有效对端帧时进入恢复；恢复截止为最后有效帧后 30 秒。新连接重新认证并提交原 SESSION token，不重新拨号、不重复 ANSWER，重试不延长期限。HANGUP 只控制 helper 持有且由桥接接听的原 Call。客户端以服务端 `STATE=idle` 确认结束。

健康等待和健康通话没有总时长上限。一次性配对导入文件的 600 秒有效期只限制导入文件，不是协议运行时限。

## provider HTTP API

以下请求使用独立的 `Authorization: Bearer <provider_token>`。它不使用直连配对密钥。

注册 iPhone 的 VoIP push token：

```http
POST /v1/register
Content-Type: application/json
Authorization: Bearer <provider_token>
```

```json
{
  "pairing_id": "<pairing identifier>",
  "push_token": "<VoIP push token>",
  "environment": "production"
}
```

`environment` 严格为 `sandbox` 或 `production`，必须与 iOS 构建的推送环境匹配。

Android 发布来电状态：

```http
POST /v1/calls
Content-Type: application/json
Authorization: Bearer <provider_token>
```

```json
{
  "pairing_id": "<same pairing identifier>",
  "call_id": "<lowercase UUID>",
  "revision": 1,
  "state": "ringing"
}
```

`state` 为 `ringing` 或 `ended`。事件按 `call_id` 和递增 `revision` 去重，已结束状态不能被迟到的响铃事件覆盖。只有新的有效响铃产生一次 VoIP push，payload 精确为：

```json
{
  "aps": {},
  "pairing_id": "00000000-0000-4000-8000-000000000001",
  "call_id": "00000000-0000-4000-8000-000000000002",
  "revision": 1,
  "state": "ringing"
}
```

示例 UUID 为合成值。通知不携带电话号码、联系人、音频或直连密钥，也没有应用层来电寿命字段。APNs expiration 只在传输 header 中设置。

具体配置、APNs 环境取值与本地 mock 命令见 [provider 说明](PROVIDER.md)。
