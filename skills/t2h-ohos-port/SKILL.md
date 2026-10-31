---
name: t2h-ohos-port
description: Tauri 应用移植到鸿蒙 PC（HarmonyOS / OpenHarmony）的完整方法论与规则库。当需要把 Tauri（Rust + 系统 WebView）应用迁移/移植/适配到鸿蒙 PC 或真机，遇到 cargo patch、OHOS 交叉编译、ArkWeb 兼容、hdc 部署等问题时使用。来自 habit-tree / cc-switch / m3u8dl 等真实移植实战（真机验证过）。
---

# Tauri → 鸿蒙 PC 移植方法（t2h）

> 语料来源：habit-tree（Windows → nova14 真机，69 文件 / +2383−228，已上架验证）、
> cc-switch-harmonyos、m3u8dl-tauri 三个端到端样本 + lingqu 工具的规则库（R2-PORT-*）。
> 每条结论都标了实测出处；文章只作线索，**本地实测为准**。

## 核心认知（先建立这三个模型，后面全是细节）

1. **前端资源编译进 `.so`**：tauri-codegen 的 `EmbeddedAssets` 对所有 target 生效，
   `frontendDist` 资源嵌进 `lib*.so`，运行时从 .so 读。`rawfile/` 是**死资源**。
   → 改前端 / 改版本号 / 改 tauri.conf.json，都必须**重编 .so**；只同步 rawfile、只重打 HAP 无效。
2. **桌面与 OHOS 的差异集中在五处**：Cargo.toml（fork+钉版+cdylib）、工具链（gnullvm+NDK clang）、
   tauri.conf.json（withGlobalTauri+assetProtocol）、前端三坑（localStorage/confirm·prompt/type=color）、
   平台代码（无 HOME → 沙箱路径、panic 落盘）。除前端三坑外全部可机械化（lingqu 已规则化为 12 条）。
3. **人工介入点要显式记录**：confirm/prompt 对话框替换、type=color 色板化这类"要写 UI 语义"的改动
   不该机械替换——列位置给方案留人工（lingqu 的 guide 档），这是验收"单应用人工介入 ≤5 处"的口径。

## 移植流程（顺序勿乱，每步的"为什么"在 references/ 里）

1. **改 Cargo.toml**（最绕，规则见 [cargo-patches.md](references/cargo-patches.md)）
   fork patch（tauri 全家桶+wry+tao+openharmony-ability，git rev 固定）→ 精确版本钉 →
   `crate-type` 加 `cdylib` → features 加 `custom-protocol`/`protocol-asset` →
   `[target.'cfg(target_env = "ohos")'.dependencies]` 加 napi 桥
2. **固定工具链**（见 [toolchain.md](references/toolchain.md)）
   `rust-toolchain.toml`（Windows 必须 gnullvm）+ `.cargo/config.toml`（NDK clang 直作链接器 + sysroot）
3. **tauri.conf.json 与能力文件**：`app.withGlobalTauri: true`（ArkWeb 需要 `window.__TAURI__` 全局桥）+
   `security.assetProtocol.enable: true`（`protocol-asset` 的 allowlist 前提）；
   `capabilities/default.json` 主窗口 `core:default`
4. **前端适配**（见 [arkweb-shims.md](references/arkweb-shims.md)）
   localStorage polyfill（必须在业务 script 之前）→ confirm/prompt 应用内对话框 → type=color 色板化
5. **平台代码注入**：`resolve_app_data_dir()`（OHOS 沙箱 `/data/storage/el2/base/files`，桌面走 Tauri）+
   `install_panic_hook()`（panic 落盘 `panic.log`——hilog 不捕获 Rust stderr，不落盘拿不到崩溃证据）；
   在 `.setup()` 里接线调用
6. **交叉编译 .so**：`cargo build --release --target aarch64-unknown-linux-ohos`；
   Windows 上 HAP 装配失败是**预期行为**（DevEco 壳由 tauri CLI 生成一半，手工装配见 pitfalls）
7. **装配 HAP + 签名**（见 [signing.md](references/signing.md)）：`.so` 复制到 `gen/ohos/entry/libs/arm64-v8a/` →
   `ohpm install --all` → `hvigor assembleHap`。**真机直装必须用绑定本机 UDID 的 debug profile**
   （release profile 直装报 9568322）；**多数情况下不需要登录华为账号**——`~/.ohos/config` 里
   当年自动签名的材料若还在、且 `device-ids` 含本机 UDID，把 `signingConfigs` 抄回
   `build-profile.json5` 即可，hvigor 自己会解密口令
8. **部署与验证**：hdc 目录坑（cd 到 HAP 目录再 file send）→ `bm install -p` → 手动解锁 →
   按 [pitfalls.md](references/pitfalls.md) 的验证清单核对（AssetKey 指纹 / rawfile 检测 / 版本号反推）

## 验证纪律（移植完 ≠ 装上了，装上了 ≠ 是新版）

- `.so` 内嵌最新前端：grep 二进制里的 **AssetKey**（vite 产物文件名明文，如 `ui-<hash>.js`）
- HAP 内无 rawfile：解包 zip 检查
- 版本号反推：真机设置页 vX.Y.Z 来自 .so 内嵌 dist——**看到旧版本号 = .so 没重编**（同一坑的另一种表现）
- ArkWeb 控制台 / panic.log / hilog 三路证据都要留

## 工具：`lingqu-cli`（能真跑，不只是给建议）

灵渠迁移台的命令行入口，和界面按钮**同一份实现**（`lingqu-cli <命令> --键 值`）。
在工程目录里直接跑，结果既打印 JSON、也落工程自己的 `.lingqu/`：

```bash
lingqu-cli scan   --path .                   # 扫描画像 → .lingqu/scan/<工程>.json
lingqu-cli deps   --path .                   # 依赖矩阵 → .lingqu/deps/<工程>.json
lingqu-cli port   --path .                   # 规则改造（预览；apply 才落盘且可 revert）
lingqu-cli build  --path .                   # 交叉编译；--verifyOnly 只比前端指纹
lingqu-cli hap    --path .                   # 装配 HAP
lingqu-cli sign   --path .                   # 签名体检（--apply 写回 signingConfigs）
lingqu-cli deploy --path .                   # 真机装启 + hilog
lingqu-cli verify --path .                   # 采证 + 功能清单 + 可用率
lingqu-cli report --path .                   # 三段式迁移报告
lingqu-cli resume --path .                   # 8 步断点板（下一步是哪步）
lingqu-cli batch  --samples "a|b|c"          # 多工程矩阵
```

规则：**先 `resume` 看停在哪步，再跑那一步**；判断"能不能用"只认 `verify` 的落档，
不要拿 `build` 通过就宣称可用。真机装不上先 `sign` 体检再看 `deploy` 的 hilog。

## references（按需读，不要全读）

| 文件 | 什么时候读 |
|---|---|
| [cargo-patches.md](references/cargo-patches.md) | 动 Cargo.toml 之前；为什么用 [patch] 不用 path 依赖、为什么必须钉精确版本 |
| [toolchain.md](references/toolchain.md) | 配交叉编译链接器之前；gnullvm 与 NDK clang 的两平台差异 |
| [arkweb-shims.md](references/arkweb-shims.md) | 前端适配三坑；polyfill 完整代码与"为什么必须 remove() 而不能 display:none" |
| [signing.md](references/signing.md) | **真机装不上（9568322）时第一个读**：三条签名路径对比、复用本机自动签名材料的 6 步配方、失败码表、什么时候才真需要账号 |
| [pitfalls.md](references/pitfalls.md) | 部署/真机阶段按报错原文索引；hdc 目录坑、锁屏、验证清单 |
