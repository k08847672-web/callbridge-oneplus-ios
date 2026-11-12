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

此前环境的 Root 只用于获得所需既有特权；桥进程本身仍以 shell UID 运行。本仓库不提供解锁、刷机、Root 或自动提权步骤。已有 Magisk 的 PJZ110 可使用下方独立开机启动模板；桥不会以 Root 身份运行。

## helper

`com.doitio.callbridgehelper` 需要安装，并已允许 `MANAGE_ONGOING_CALLS` 对应 app-op。其 InCallService 由系统 `BIND_INCALL_SERVICE` 权限保护；控制入口通过 `getContentProviderExternal → Binder` 连接，Provider 受 `DUMP` 保护，Provider 和每次 Binder transaction 都核验实际 shell UID 2000。shell 使用系统已有的 `DUMP` / `ACCESS_CONTENT_PROVIDERS_EXTERNALLY` 授权。helper 持有并控制本次由桥接接听的原 Call，默认拨号器不变。

helper 新增 `READ_CONTACTS` 用于本机匹配联系人姓名；未授权或未匹配时，仍可使用 Telecom 允许显示的网络姓名或号码，不阻塞通话。姓名和号码只对应本次原 Call；系统隐藏或限制显示的身份不向 iPhone 发布。

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

## Magisk 开机启动

`scripts/device/callbridge-autostart.sh` 是模板。先核验现有生产进程实际使用的 JAR、配置路径和哈希，以及本机 Magisk `su` 支持 `-d -g 2000 -G 3003 -Z u:r:shell:s0 2000 -c`。只把路径传给本地 renderer，不将实际设备配对、地址或私有配置写入源码：

```sh
python3 scripts/device/render-callbridge-autostart.py \
  --jar-path /explicit/device/path/bridge.jar \
  --config-path /explicit/device/path/private600.properties \
  --su-path /explicit/device/path/su \
  --log-path /explicit/device/path/bridge.log \
  --output /absolute/private/callbridge-autostart.sh
```

renderer 不读取配对文件、不访问手机，输出权限为 `0700`。核验设备、产物哈希和现有运行身份后，只将渲染结果安装为设备端 `/data/adb/service.d/callbridge-autostart.sh`，owner `0:0`、mode `0755`；保留原 JAR、配置及其权限，不改其他开机项。安装前后都核对只有同一份生产桥；可手动调用这个已安装的 hook 验证它不会重复启动。

hook 等待 `sys.boot_completed=1` 和原配置的 `bindAddress` 在本机接口上 UP，不主动启动、重配或重连 Tailscale。Magisk 只负责进入原 shell UID/GID 2000、SELinux shell 域并丢弃 capabilities，附加组仅恢复原 ADB shell 已有的 `inet`（3003），用于访问 Android DNS 代理；不复制其他附加组。执行桥前再次核验 UID/GID、3003 组、shell 域及 CapEff 为零。未继承 `SYSTEMSERVERCLASSPATH` 时，只从 Android 生成的 classpath 文件提取该变量。`--log-path` 指向原生产进程使用的日志；只有降到 shell 身份并通过身份核验后，才在执行桥时将 stdout/stderr 追加该文件，Root 不打开生产日志。配置不会作为 shell 代码执行，也不输出密钥、号码或音频。

原子锁位于 `/dev/.callbridge-autostart.lock`，重启自然清除；精确 argv 与 CLASSPATH 检查保留已运行的生产桥。桥退出后不自动重拉，不改变正常通话时长、配对期限、helper 权限或原有接听行为。回滚只移除这个新增 hook：尚在等待启动条件的脚本随即退出，已运行的生产桥保持原样，下一次重启不再自动启动。

定向本地检查为 `python3 scripts/diagnostics/tests/callbridge_autostart_test.py`，使用桩系统命令，不访问设备。安装后需正常重启一次，核验无需手动启动即可恢复同一 JAR 的单一生产监听、UID/GID 2000、shell 域和 CapEff 为零；这只验收开机启动，不代替真实通话验收。
