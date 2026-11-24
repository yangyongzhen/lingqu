---
name: t2h-ohos-port
description: 把 Tauri（Rust + 系统 WebView）应用移植/适配到鸿蒙 PC 或真机时使用：cargo patch、OHOS 交叉编译、ArkWeb 兼容、HAP 装配与签名、hdc 部署、真机白屏/秒退、原生 UI 桥接。撞到 9568322 / arkts-no-untyped-obj-literals / SetUIContent timeout 也加载。纯仓颉原生鸿蒙开发不要用。
---

# Tauri → 鸿蒙 PC 移植（t2h）

> **索引**：只放"不做就必错"的动作，细节在 `references/`（不进提示词，按需读）。
> 语料来自 habit-tree / cc-switch / m3u8dl / EcoPaste / dbx / note-gen-2 实测，**本地实测为准**。

## 核心认知

1. **前端编进 `.so`**：`rawfile/` 是死资源 ⇒ 改前端 / 版本号 / `tauri.conf.json` 都必须**重编 .so**（只重打 HAP = 真机还是旧界面）。
2. **差异五处**：Cargo.toml（fork+钉版+`cdylib`）、工具链（gnullvm/NDK clang）、`tauri.conf.json`（`withGlobalTauri`+`assetProtocol`）、
   前端三坑、平台代码（沙箱路径 + panic 落盘）。除 UI 语义外都可机械化。
3. **要写 UI 语义的改动别机械替换**（confirm/prompt、type=color）：列位置给方案，留人判断（人工介入 ≤5 处）。

## 流程（顺序勿乱）

1. **Cargo.toml**：fork patch（tauri 全家桶+wry+tao+openharmony-ability，rev 钉死）→ 钉精确版本 → `cdylib` → `custom-protocol`/`protocol-asset` → ohos 分支 napi 桥。**`[patch]` 必须在 workspace 根**。
2. **工具链**：`rust-toolchain.toml`（Windows 必须 gnullvm）+ `.cargo/config.toml`（NDK clang + sysroot）。
3. **配置**：`withGlobalTauri: true` + `security.assetProtocol.enable: true`；`capabilities/` 主窗 `core:default`。
4. **前端**：localStorage polyfill（**在业务 script 之前**）→ confirm/prompt 对话框 → type=color 色板。
5. **平台代码**：`resolve_app_data_dir()`（OHOS 定死 `/data/storage/el2/base/files`）+ `install_panic_hook()`。
6. **交叉编译**：`cargo build --release --target aarch64-unknown-linux-ohos --lib`（**要 `--lib`**）。
7. **装配+签名**：`.so` → `gen/ohos/entry/libs/arm64-v8a/` → `ohpm install` → `hvigor assembleHap`；真机直装**必须**含本机 UDID 的 debug profile（release 报 9568322）。
8. **部署验证**：hdc 目录坑 → `bm install` → 解锁 → 清单核对；界面单独判（进程 + `#FOREGROUND` + **截图有内容**）。

## 验证纪律

- `.so` 里有没有新前端：grep 二进制 **AssetKey**（如 `ui-<hash>.js`）；HAP 里不该有 rawfile
- 真机设置页旧版本号 = `.so` 没重编
- 证据三路：ArkWeb 控制台 / `panic.log` / hilog；**别把 `eprintln` 当证据**（鸿蒙不进 hilog）
- `hdc install -r` **不杀进程**、`aa start` 只拉到前台 ⇒ 必须 `aa force-stop` 再起
- **判定只认落档**：`build` 通过 ≠ 能用，退出码 0 ≠ 通过

## 工具（`lingqu-cli`，与界面同一实现）

```bash
lingqu-cli resume --path .   # 先跑这个：8 步断点板
lingqu-cli port   --path . --apply   # 规则改造（可 revert）
lingqu-cli build  --path .   # 交叉编译（--verifyOnly 只比指纹）
lingqu-cli hap    --path .   # 装配 HAP（含签名闸）
lingqu-cli sign   --path .   # 体检；--login / --auto 自动签名
lingqu-cli deploy --path .   # 真机装启 + hilog
lingqu-cli verify --path .   # 采证 + 可用率（判"能不能用"只认它）
lingqu-cli probe  --path . --auto --max 8   # 真机点一下再判定
```

其余子命令见 [cli-and-selfcheck.md](references/cli-and-selfcheck.md)。**中文写进 UTF-8 文件再传**（`--click-file` / `--body`）。

## 真机自测 / 回复格式 / 失败现场

- **功能能不能用**：真机**点一下再对比点击前后版面**，坐标取 `dumpLayout` 的 `bounds`（别按截图估）；冒出新实质文本 → `pass`，一字不差 → `unknown`（**不许判 fail**）。见 [device-probe.md](references/device-probe.md)。
- **回复格式**：建议命令一行一条 `lingqu-cli <命令> --path <工程>`；要人定取舍写成 `lingqu-decision` 围栏块（一行 JSON，你只提案）。
- **失败现场**：灵渠会**自动**发「落档 + 日志尾 40 行 + 判据」（`t2h:ai_brief`）；回一句话根因（**引用具体某行**）+ 可执行动作，判不准就说要哪份证据。

## references（按需读，别全读）

| 文件 | 什么时候读 |
|---|---|
| [cargo-patches.md](references/cargo-patches.md) | 动 Cargo.toml：`[patch]` 写根、钉版本、`reqwest` 拉 `openssl-sys` |
| [toolchain.md](references/toolchain.md) | 配链接器：gnullvm vs NDK clang |
| [arkweb-shims.md](references/arkweb-shims.md) | 前端三坑：polyfill、必须 `remove()` |
| [signing.md](references/signing.md) | **装不上 9568322 先读**：三条路径、码表 |
| [pitfalls.md](references/pitfalls.md) | 按报错原文索引 |
| [startup-and-first-screen.md](references/startup-and-first-screen.md) | **界面不对先读**：取证、早期 hook、EPERM、`defaultPage`×label |
| [native-ui-bridge.md](references/native-ui-bridge.md) | **命令是空壳**：桥骨架、主线程铁律、uri≠路径 |
| [plugin-adaptation.md](references/plugin-adaptation.md) | 插件无对应物：cfg 门控 → 三层适配 → limit |
| [device-probe.md](references/device-probe.md) | 真机证明功能可用：闭环六步 |
| [cli-and-selfcheck.md](references/cli-and-selfcheck.md) | 全量命令 / 查文档 / 拉 skills |
