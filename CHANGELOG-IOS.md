# 本 fork 的改动（相对 yss20025/dsh-go-ios-ipa）

基线：`1afc868`（上游 fork 的 tip）。下面每一条都能用提交号在 `git log` 里查到，
并且都经过真机或 CI 编译验证（注明是哪一种）。

## 新增

### 1. 后台保活：切出去不再掉线（`6f86aa1`，真机验证）

上游 `Info.plist` 没有 `UIBackgroundModes`，全工程也没有 `beginBackgroundTask`
或 PushKit。iOS 在用户切到别的 App 后几秒就挂起进程，宿主连接随之断开，任何提醒
都发不出来——只能等用户回到 App、重连、把会话重拉一遍。

- `app/ios/Runner/DshPlugin.swift`：新增 `BackgroundKeepAlive`，用
  `AVAudioSession(.playback, .mixWithOthers)` 循环播放**内存里生成**的 1 秒静音
  WAV（不占包体，也不抢别的 App 的声音输出）；新增 `dsh/notify` 的 `keepAlive` 方法。
- `app/ios/Runner/Info.plist`：`UIBackgroundModes = [audio]`。
- `app/lib/notify/notify_channel.dart`：`setBackgroundKeepAlive(bool)`，仅 iOS 生效。
- `app/lib/ui/notify/chat_alert_host.dart`：离开前台时打开，回到前台立刻关闭；
  只在「通知开关开着 **且** 有主机连接」时才开，空闲不烧电。
- `app/ios/Runner/VoiceChannel.swift`：语音识别要占用音频会话，开始听写时
  `suspend()`、结束或被打断时 `resume()`，两边不抢。

代价：离屏期间约 3–5%/小时耗电；`audio` 后台模式在 App Store 审核会被质询，自签不受影响。

### 2. 点宠物显示 WorkBuddy 余额 / 积分（`71d83e6`、`4b1b04c`，CI 编译通过）

读面板的只读接口，不改面板、不加依赖。

- `app/lib/state/credits_state.dart`：`GET {base}/api/accounts/credits-snapshot`，
  `Authorization: Bearer wbt_…`，按 `known` 求和，30 秒缓存；地址与令牌存本机
  SharedPreferences，不进日志。
- `app/lib/ui/pets/pet_credits_sheet.dart`：合计 + 每账号一行 + 登记时间 + 刷新。
- `app/lib/ui/pets/credits_settings_section.dart`：宠物设置里的新分组
  （开关 / 面板地址 / 只读令牌 / 预览）。
- `app/lib/ui/pets/pet_stage.dart`：配置好之后，轻点宠物的同一拍弹出积分卡。
- `app/lib/l10n/parts/credits_{zh,en}.arb`：文案按仓库规矩做成 part，
  直接改合并后的 `app_zh.arb` 会被 `tool/l10n_merge.py` 冲掉。
- `app/ios/Runner/Info.plist`：ATS 例外 `117.72.34.46`，允许用明文 HTTP 打自建面板。

### 3. 灵动岛 / 实时活动（`LIVE` 提交，CI 编译验证）

`dsh/notify` 的 `live` 与 `liveStatus` 在 iOS 上原本是空实现。现在接到 ActivityKit：

- 新 target **`DshLiveActivity`**（Widget Extension，iOS 16.1+）：
  锁屏卡片 + 灵动岛 compact / expanded / minimal 三态。
- `app/ios/LiveActivity/DshActivityAttributes.swift`：`ContentState` 与
  Dart 的 `LiveActivity.toMap` 字段一一对应（`kind` / `title` / `text` / `chip` /
  `publicText` / `mood` / `sinceMs` / `sessionId`），Dart 无改动。
- `app/ios/Runner/LiveActivityBridge.swift`：`request / update / end`，
  只保留一个活动（换会话时收掉旧的），`staleDate` 30 分钟。
- `app/ios/Runner/Info.plist`：`NSSupportsLiveActivities = true`。
- 工程用 Ruby `xcodeproj` 生成：依赖关系、嵌入 `PlugIns/`、
  `APPLICATION_EXTENSION_API_ONLY = YES`、bundle id `…dshgo.LiveActivity`。

状态映射沿用 Dart 侧：`running` 计时、`waiting` 黄色待确认、`done` 绿色完成、
`failed` 红色出错。点岛走 `dshgo://open/chat`。

限制：**本地更新**（靠已做的后台保活）。App 被划掉后岛会消失；远程推送要 APNs。

### 4. Codemagic 构建（`65ce48c`）

`codemagic.yaml`：`mac_mini_m2` + Flutter 3.47.7，`l10n_merge --no-gen` →
`pub get` → `gen-l10n` → `flutter build ios --release --no-codesign` → 打 Payload。
编译全在云端，本机只推代码；免费档并发 1，通常比 GitHub 免费 macOS runner 快。

## 修改

### 4. 侧边栏页脚不再一直显示「正在连接」（`41deb30`，CI 编译通过）

`hostLinkProvider` 是 `autoDispose` 的，抽屉/设置页各自 watch 一次就会新建连线对象；
新对象从第一步「连接服务器」起步，而旧对象交出去的 client 一直在跑。于是连接是好的，
状态文字却停在起跑线。`app/lib/ui/remote/host_status.dart`：只要该主机有一条活着的
连接，就直接显示**已连接**。

### 5. 表格/代码块横向滑动不再被抽屉抢走（`41deb30`）

抽屉的拖动识别器 8px 就表态，比 `Scrollable` 的 hit slop 早，横滑一下表格就变成拉抽屉。
`app/lib/ui/shell/drawer_drag.dart` 新增 `edgeZone`：只在**左侧 32px 内**起手才拉开抽屉，
抽屉已开时不受限（左右都能推）。`home_shell.dart` 传入 `kDrawerEdgeZone = 32`。

### 6. GitHub Actions 队列（`89cded0`）

`concurrency.cancel-in-progress` 从 `true` 改为 `false`：两次 dispatch 连着来的时候，
后到的会把排队的那个顶掉，表现为「15 分钟后失败、没有 runner、没有日志」。
另外 `tooling/ios/build.sh`（`fa213ce`）失败时打印原始输出的最后 80 行——
Flutter 会把 Dart 编译错误笼统报成「requires a selected Development Team」，害人查错方向。

## 仍然没有的（与上游一致，未动）

- **APNs**：App 被杀掉后仍然收不到提醒，那需要付费开发者账号的 `.p8`。
- **灵动岛 / 实时活动**：`DshPlugin.swift` 的 `liveStatus` 仍硬编码 `supported: false`，
  ActivityKit 与 Widget Extension 都还没做。
- 本机引擎、手机操控、`dsh/performance`、`dsh/launcher_icon`、`dsh/diagnostics`、
  `dsh/usage`、`dsh/dynamic_color`、`dsh/native-files`、`dsh/native-media` 等通道：
  和上游一样按「这个平台没有」处理。

## 验证方式

| 项 | 怎么验 |
|---|---|
| 后台通知 | 切到别的 App 停留 3 分钟，让主机动一次；应弹系统横幅，锁屏同样 |
| 积分 | 宠物设置里填地址与只读令牌，轻点宠物；合计应等于面板 `known_count` 个账号之和 |
| 页脚 | 连上主机后拉开侧边栏，底部应写「已连接」 |
| 抽屉 | 在表格上横滑，表格自己滚；从屏幕最左 32px 内右拉，抽屉才出来 |
