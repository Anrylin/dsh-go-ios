# DSH Go for iOS

DeepSeek Harness 的 **iOS 客户端**：Flutter 写界面、Swift 写原生通道，只连远程主机（iOS 上跑不了 Linux 环境），编译在云端 macOS 上完成，产物是**未签名 IPA**，用你自己的 Apple ID 侧载。

这是 [`ccch1mneyyy/dsh-Go`](https://github.com/ccch1mneyyy/dsh-Go) 的 iOS 分支（`feat/ios-foundation`）的衍生版本，经由 [`yss20025/dsh-go-ios-ipa`](https://github.com/yss20025/dsh-go-ios-ipa)。改动逐条写在 [CHANGELOG-IOS.md](CHANGELOG-IOS.md)。

## 下载

**https://github.com/Anrylin/dsh-go-ios/releases/latest**

包里是未签名的 `.ipa`，装法见下。

## 相对上游加了什么

| 功能 | 说明 |
|---|---|
| **后台保活** | 切到别的 App、锁屏后不再掉线，提醒能到。用静音音频会话把进程留住，约 3–5%/小时耗电；语音听写时自动让出音频会话 |
| **点宠物看积分** | 轻点宠物弹出余额卡：合计 + 每个账号一行。在「设置 › 宠物 › 余额 / 积分」里填面板地址与**只读**令牌，数据走 `/api/accounts/credits-snapshot` |
| **云端构建** | `codemagic.yaml`（Mac mini M2）与 GitHub Actions 两套，本机只推代码 |

## 相对上游改了什么

| 问题 | 现在 |
|---|---|
| 侧边栏页脚一直显示「正在连接」 | 有活连接就显示**已连接**（连线对象是 autoDispose 的，重建后会停在第一步） |
| 表格/代码块横向滑动被抽屉抢走 | 抽屉只在**左侧 32px** 内起手；抽屉开着时左右都归它 |
| 滑动中点点「回到底部」没反应 | 跳转前先结束当前滚动活动，惯性期间点击也立即生效 |
| 只能回到底部 | 新增**上一条提问**按钮，跳到视口上方最近的一条自己的消息 |
| 积分刷新慢/点了没反应 | 复用 HTTP 连接、失败重试一次、刷新中禁用按钮并显示耗时，失败保留上次数字 |
| GitHub 排队被并发规则顶掉 | `cancel-in-progress: false`；失败时打印原始构建日志尾部 |

## 还没有

- **APNs**：App 被划掉后收不到推送（需要付费开发者账号的 `.p8`）
- **灵动岛 / 实时活动**：`liveStatus` 仍是 `supported: false`，ActivityKit 未接
- 本机引擎、手机操控、`dsh/performance`、`dsh/launcher_icon`、`dsh/diagnostics`、`dsh/usage`、`dsh/native-files`、`dsh/native-media` 等通道与上游一致，按「这个平台没有」处理

## 装到手机

1. 电脑装 [Sideloadly](https://sideloadly.io/)（Windows 需 iTunes 或 Apple Devices 驱动）
2. iPhone 插线、解锁、信任这台电脑
3. IPA 拖进 Sideloadly，填你的 Apple ID，Start
4. 手机 **设置 › 通用 › VPN与设备管理** 信任证书
5. 首次打开：允许**通知**与**本地网络**权限

免费 Apple ID 签名 **7 天有效**，到期重签；最多 3 台设备。

## 自己编

**Codemagic**：仓库里有 `codemagic.yaml`，Add application 后直接跑 `ios-unsigned` 工作流。

**GitHub Actions**：`.github/workflows/build-ipa.yml`，Actions → Build unsigned IPA → Run workflow。

两者都是 `flutter build ios --release --no-codesign`，产物同一份。

**本地**（需要 macOS + Xcode 26）：

```sh
cd app
flutter pub get
flutter gen-l10n
flutter build ios --release --no-codesign
```

## 许可

AGPL-3.0，见 [LICENSE](LICENSE)。上游作者与协议声明保留在 [README.upstream.md](README.upstream.md)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

本项目与 DeepSeek 无隶属关系；模型请求由你自己配置的提供方处理。
