# DSH Go for iOS —— 自建 IPA 说明

这是 [ccch1mneyyy/dsh-Go](https://github.com/ccch1mneyyy/dsh-Go) 的 `feat/ios-foundation`
分支（AGPL-3.0）加上一条 GitHub Actions 流水线，用来在**没有任何 Mac**的情况下产出一个
unsigned `.ipa`。签名和安装在你自己的手机上完成。

上游作者把这个分支标为「代码只经过 CI 编译，还没有在设备上跑过」。本仓库没有改变这个
事实，只是补上了打包和分发。

## 产物

| 文件 | 大小 | 说明 |
| --- | --- | --- |
| `dsh-go-ios-unsigned.ipa` | ~27.5 MB | Flutter 客户端，**只连远程主机**，无本机引擎 |

结构核对（已在本地产物上验证）：

```
Payload/Runner.app/                      280 个文件
  Runner                                 arm64, 2.65 MB
  Info.plist                             CFBundleIdentifier = io.github.ccch1mneyyy.dshgo
                                         MinimumOSVersion   = 15.0
                                         CFBundleVersion    = 1.0.9 (1)
  Frameworks/App.framework/App           31.91 MB  Flutter AOT
  Frameworks/Flutter.framework           8.98 MB
  Frameworks/WebRTC.framework            11.77 MB
  Frameworks/objective_c.framework
  PlugIns/ShareExtension.appex           arm64, 0.22 MB
```

`Runner.app` 本身**没有** `_CodeSignature`，这是正确的未签名状态。Flutter 预编译的三个
framework 自带签名，重签时会被工具覆盖。

Entitlements 只有一个 App Group（`group.io.github.ccch1mneyyy.dshgo`），**没有
HealthKit、没有 private-cloud-compute**。这一点很关键：用免费 Apple ID 签名时不会
因为受限能力被拒。

## 装到手机

免费 Apple ID 的签名 7 天有效，付费开发者账号 1 年。三条路，选一条：

**Sideloadly（Windows / macOS，最省事）**

1. 装 iTunes 经典版（不是 Microsoft Store 版），拿到 Apple Mobile Device 驱动。
2. 打开 Sideloadly，iPhone 用数据线连电脑并点「信任」。
3. 把 `dsh-go-ios-unsigned.ipa` 拖进去，填 Apple ID，点 Start。
4. 手机上：设置 → 通用 → VPN 与设备管理 → 信任你的开发者证书。
5. 设置 → 隐私与安全性 → 开发者模式 → 打开并重启。

**SideStore / AltStore（手机上自签，7 天自动续签）**

需要先在手机上装 SideStore，然后导入这个 ipa。好处是到期会自动刷新，不用每周插线。

**TrollStore（免签名，iOS ≤ 17.0 且已装 TrollStore）**

直接把 ipa 拖进 TrollStore 安装，永久有效，不需要证书。

覆盖安装时**沿用同一个 Bundle ID 和同一个签名账号**，否则会变成两个 App 或装不上。
卸载会清空对话和设置。

## 连服务端

iOS 版**没有本机引擎**（`dsh/runtime` 没有原生实现），所以必须有一台跑着 DSH 的机器。
你自己有云服务器和公网家宽，两种都行。

服务端（Linux / macOS，Node 22+）：

```bash
npm i -g @deepseek-ai/dsh
dsh web --host 0.0.0.0 --port 3080
```

`--host 0.0.0.0` 是为了让手机能连；只给本机用就保持默认的 `127.0.0.1`。
公网暴露时前面挂一层 TLS 反代（Caddy 一行 `reverse_proxy 127.0.0.1:3080` 就够），
别把明文 3080 直接开到公网上。

客户端里加主机：

1. 打开 App → 「连接电脑或服务器」。
2. 填地址 `http://<你的域名或内网 IP>:3080`，以及 `dsh web` 启动时打印的 token。
3. 首次连接会弹「信任这台主机？」，核对指纹后点信任。

局域网直连时 iOS 会问一次「本地网络」权限，必须允许。

## 能用什么、不能用什么

上游 `app/ios/README.md` 列了完整清单，这里只挑影响使用的：

**能用**：聊天与流式回复、切换模型、图片附件、语音输入（系统听写）、会话管理、
网页模式、分享卡与对话回放链接、`.dshgo` 导入、文件预览与保存、桌面快捷操作、
主题与语言。

**不能用**：

- **本机引擎**。手机上没有 Ubuntu/Node/proot，DSH 必须跑在别的机器上。
  想在手机上本机跑，用 [DSHIOS](https://github.com/everettjf/dsh-ios)（iSH-ARM64 模拟器，
  150 MB，慢，且需要 HealthKit entitlement）。
- **手机操控**。iOS 沙箱没有等价于 Android 无障碍服务的东西，第三方 App 无法读屏或
  点击别的 App。要自动化 iPhone 只能从外部用 XCUITest / WebDriverAgent，见下文。
- **离开应用后的通知**。需要 APNs，没做。锁屏和后台的「等你确认」提醒收不到，
  回到应用才看得到。
- **换图标、诊断、用量统计、动态取色**：`dsh/launcher_icon`、`dsh/diagnostics`、
  `dsh/usage`、`dsh/dynamic_color` 这些通道在 iOS 上按「不支持」处理。
- 插件里有原生文件和媒体能力的部分（`dsh/native-files`、`dsh/native-media`）也没接。

## 自己重新构建

推送到 `main` 就会跑 [`.github/workflows/build-ipa.yml`](.github/workflows/build-ipa.yml)：
`macos-26` runner、Xcode 26.6、Flutter 3.47.7（带 SHA256 校验）、Swift Package Manager，
`flutter build ios --release --no-codesign`，然后打成 `Payload/Runner.app` 的 zip 并发布
release。全程不需要任何 secret。

也可以手动触发：Actions → Build unsigned IPA → Run workflow。

公开仓库的 macOS runner 不消耗私有仓库的免费额度，所以这个仓库是 public 的。

### 踩过的两个坑

- **CRLF**。在 Windows 上 checkout 会把 `tooling/ios/build.sh` 变成 DOS 换行，
  bash 报 `syntax error: unexpected end of file`。`.gitattributes` 强制 `eol=lf` 解决。
- **`APPLICATION_EXTENSION_API_ONLY`**。`project.pbxproj` 里 ShareExtension 的三个
  build configuration 原本写的是 `NO`，Xcode 26 直接拒绝：

  > Application extensions and any libraries they link to must be built with the
  > `APPLICATION_EXTENSION_API_ONLY` build setting set to YES.

  改成 `YES` 后既编译通过，又能正常打包成 appex。

## 从电脑控制 iPhone

iOS 没有 Android 那样的设备内自动化。唯一官方能力是 XCUITest，落地形态是
WebDriverAgent（WDA）——一个用 XCTest 写的 HTTP server，装在手机上，接受点击、
输入、截图、取无障碍树的指令。

Windows 上不用 Mac 也能跑，靠 [go-ios](https://github.com/danielpaulus/go-ios)：

```powershell
# 管理员 PowerShell
npm install -g go-ios
# iOS 17+ 的隧道要 wintun
Invoke-WebRequest https://www.wintun.net/builds/wintun-0.14.1.zip -OutFile $env:TEMP\wintun.zip
Expand-Archive $env:TEMP\wintun.zip -DestinationPath $env:TEMP\wintun -Force
Copy-Item "$env:TEMP\wintun\wintun\bin\amd64\wintun.dll" C:\Windows\System32\ -Force

ios list                 # 确认设备、已信任本机、开发者模式已开
ios image auto           # 挂载 developer disk image
ios tunnel start         # 常驻，别关
ios ui download wda --output C:\wda
ios ui install wda --path C:\wda\WebDriverAgent.ipa --p12file <你的>.p12 --profile <你的>.mobileprovision
ios ui run wda --host-port 8100   # 常驻

# 真正操作屏幕
ios ui tap --x=200 --y=640 --driver=wda
ios ui type --text="hello" --driver=wda
ios ui swipe --from-x=200 --from-y=700 --to-x=200 --to-y=300 --driver=wda
ios ui screenshot --output shot.png --driver=wda
ios ui source --output ui.json --driver=wda
```

注意几点：WDA 自己也要签名，免费账号同样 7 天一轮；iOS 17+ 的隧道必须管理员权限；
微软商店版 iTunes 不带 Apple Mobile Device 驱动，装经典版；`--driver=wda` 不能省，
不带会打到 DeviceKit 的 12004 端口。

要现成的 agent 封装，用 [appium-mcp](https://github.com/appium/appium-mcp)（MCP →
Appium → WDA）或 [android-agent](https://github.com/ghost-in-the-droid/android-agent)
（62 个 MCP 工具，Android 走 ADB、iPhone 走 WDA）。

## 许可与署名

上游 `ccch1mneyyy/dsh-Go` 以 AGPL-3.0 发布，`sdk/` 和 `examples/` 为 MIT。
DSH Go 的名称、标识、Deepy 和鲸娘形象不在开源授权范围内，见上游 `ASSETS.md`。
本仓库只是为了让这个分支能编出 ipa，不含任何品牌素材的再授权。
