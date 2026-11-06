# Fish Pocket 引擎（实验用）

来源：https://github.com/imsai-sh/fish-pocket （MIT，Copyright (c) 2026 imsai-sh）

这里只借用它的 **本机引擎层**：
- `boot.mjs` / `main.mjs`：启动 DSH 引擎、解析端口与 token
- `runtime/`：JS 版 child_process、shell、worker 等替身
  （iOS 不许 fork/exec，所以命令都在同一进程里模拟）
- `fetch-nodejs-mobile.sh`：下载 Node 24 的 iOS xcframework（NodeMobile），
  来自 https://github.com/digidem/nodejs-mobile

用途：让 DSH Go 的 iOS 版**可选地**在手机上跑引擎（默认不开，选了「本机」才启动）。
MIT 允许这样用；本目录保留原许可与声明。
