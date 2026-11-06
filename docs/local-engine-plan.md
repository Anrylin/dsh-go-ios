# 本机引擎（实验分支 `local-engine`）

目标：App 里带一套 Node 运行时，**默认不启动**；首次引导或主机切换里选「本机」时才拉起。

## 为什么不是"把 Linux 搬进来"

iOS 不允许 fork/exec、不允许跑下载来的可执行文件，所以：
- 不能跑 Ubuntu / proot（Android 版走的是这条）
- 只能把 **Node 24 编成 iOS 库**（nodejs-mobile / NodeMobile.xcframework）
- 子进程、shell 用 JS 替身（`third_party/fish-pocket-engine/runtime/`）
- git 走静态链接的 libgit2（后面再接）

## 契约（Dart 侧已就位，见 app/lib/runtime/runtime_bridge.dart）

通道 `dsh/runtime`：`install` / `start` / `stop` / `status` / `reset`，事件 `logs` / `progress` / `notice`。
iOS 只要实现 **start / stop / status / logs** 四条，「本机」选项就能活过来，
`localConnectionProvider` 会自动连上去。

## 步骤

1. `fetch-nodejs-mobile.sh` 拉 NodeMobile.xcframework（Node 24.20.0，带 sha256）——需 macOS/CI
2. 链进 Runner（Embed & Sign）
3. `app/ios/Runner/LocalEngine.swift`：
   - `start`：沙箱里起 node（`engine/boot.mjs`），HOME/cwd 指到 `Application Support/dsh-home`
   - 从 stdout 解析 `dsh web: http://127.0.0.1:PORT/?token=…`
   - `status` / `stop` / `logs`
4. Dart 侧不改
5. 引导里把 iOS 的「本机」从灰改成可选，点了才 start

## 风险

- 体积 +100–150 MB
- 没有真 Linux：fork 类命令靠 JS 模拟，重活会失败
- 无 JIT，比服务器慢数倍
- 路径：Fish Pocket 用 `DshRoot` 改写 dyld 的 libSystem 绑定做"假根"，第一版先不做，跑不通再引入
- 与灵动岛无关；扩展签名问题不受影响

## 现状

- [x] 引擎源码 + 抓取脚本入库
- [ ] CI 里跑 fetch + 链 framework
- [ ] LocalEngine.swift 的 start/stop/status
- [ ] 引导放开「本机」
