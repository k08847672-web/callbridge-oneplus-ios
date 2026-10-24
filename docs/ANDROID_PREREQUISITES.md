# Android 运行前提

本桥是面向已有授权环境的实验代码，不是安装一个普通 Android APK 即可完成的通话转接方案。先在本机编译和运行合成测试，再判断自己的设备是否具备以下系统能力。

## shell 通话桥

`TelephonyNetworkBridge` 由显式启动的 `app_process` 运行，UID 为 Android shell（2000）。它沿用设备既有的特权音频路径，不以普通 App 的麦克风权限代替蜂窝通话音频能力。

运行前检查严格要求 shell 已具备：

- `RECORD_AUDIO`
- `CAPTURE_AUDIO_OUTPUT`
- `CALL_AUDIO_INTERCEPTION`
- `MODIFY_AUDIO_ROUTING`
- `MODIFY_PHONE_STATE`
- `READ_PHONE_STATE`
- `INTERNET`

设备还必须支持 `Telecom.isRinging`、16 kHz PCM 的 `VOICE_DOWNLINK`、双向 `TYPE_TELEPHONY` 路由以及 native `incall_music` 输出 flag。这些能力依赖系统实现与既有授权，不能从 Android 版本或编译成功推断。

此前环境的 Root 只用于获得所需既有特权；桥进程本身仍以 shell UID 运行。本仓库不提供解锁、刷机、Root 或自动提权步骤，也不新增开机启动或 Root daemon。

## helper

`com.doitio.callbridgehelper` 需要安装，并已允许 `MANAGE_ONGOING_CALLS` 对应 app-op。其 InCallService 由系统 `BIND_INCALL_SERVICE` 权限保护；本地 socket 仅接受 shell UID。helper 持有并控制本次由桥接接听的原 Call，默认拨号器不变。

公开 helper 构建默认生成已对齐的未签名 APK，不读取个人 keystore。安装使用自己的本地签名材料；显式设置 `CALLBRIDGE_KEYSTORE`、`CALLBRIDGE_KEY_ALIAS`、`CALLBRIDGE_KS_PASSWORD`、`CALLBRIDGE_KEY_PASSWORD` 后，构建脚本通过环境变量给签名工具提供密码。不同签名不能直接覆盖已有相同 package 的安装；在现有设备上更换签名或卸载前，应先判断其数据和授权影响。

## 显式运行

在满足前提的 Android shell 中，入口形式为：

```sh
CLASSPATH=/explicit/path/bridge.jar app_process /system/bin \
  com.doitio.diagnostics.TelephonyNetworkBridge /explicit/path/private600.properties
```

JAR 和配置路径应替换为自己设备上的明确路径。配置文件由 shell 可读并使用 0600 权限，包含本次设备的绑定地址、配对密钥及可选 provider 配置；不要把真实配置提交到 Git 或放入命令参数。

一次通话正常结束后，进程继续等待下一通；持久配对可以复用，每通生成新的 session。进程需要由使用者明确配置并启动，本仓库不自动部署或安装后台服务。

iPhone 签名或 TestFlight 安装完成后，还要配置并启动 Android 桥、helper 及所选 provider。真实 Telecom 绑定、蜂窝双向音频、锁屏新来电、断线恢复与挂断均需在自己的设备上验收；本地 fixture 或 APK 构建不证明这些条件已满足。
