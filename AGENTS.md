# Orbira Browser — agent notes

## 引擎二进制与资源必须同源（血泪教训）

`overlay/chromium-ui/engine/libs/arm64-v8a/*.so` 和
`overlay/chromium-ui/engine/src/main/resources/rawfile/chromium/*`
**都不在 git 里**（本地构件），且必须来自**同一个上游版本**：

- `.so` 与 rawfile 不匹配（如 155 资源 + 157 内核）→ 冷启动 1 秒内 SIGTRAP cppcrash
- v8_context_snapshot.bin / icudtl.dat / *.pak 全部版本锁定
- 正确来源：上游 release（如 v1.2.1）的 unsigned HAP，解包提取整套
  - `libs/arm64-v8a/libweb_engine.so libnweb_render.so libohos_video_overlay.so liblumie_adblock.so` → `engine/libs/arm64-v8a/`
  - `libs/arm64-v8a/libadblock.so` → `entry/libs/arm64-v8a/`
  - `resources/rawfile/chromium/**` → `engine/src/main/resources/rawfile/chromium/`（注意 unzip glob 要单独解 `locales/*`）

## 构建/安装

- 构建：`cd overlay/chromium-ui && E:/HarmonyOS/command-line-tools/bin/hvigorw.bat assembleHap --no-daemon -p buildMode=debug`
- 产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`（未签名，hdc 直装会报 9568320 no signature）
- 用户在 DevEco 里签名后安装
- 验证包内内核版本：`unzip -l xx.hap | grep libweb_engine` 对比字节数

## 设备

- 远程 hdc：`hdc tconn 192.168.0.143:36203`（掉线就重连）；USB 序列 88V0226804001040
- MSYS 路径转换坑：hdc shell 的 unix 路径前加 `MSYS_NO_PATHCONV=1`
- faultlog（/data/log/faultlog）无权限读；崩溃靠 hilog 里 DfxSignalHandler/Chromium 行重建
- signal 5 = SIGTRAP = Chromium CHECK 失败

## 上游

- `ShixmSimon/orbira-browser`，只读。157 线 = `hmos-157-adapter` 分支（squash 历史，与 155 无共同祖先，移植只能文件级）
- 引擎编译在上游 self-hosted runner（`/root/chromium-15x/src` 持久树），fork/本地都无法构建
- 本地改动要生效到 native 层 → PR 给上游让其 CI 出 `.so`
