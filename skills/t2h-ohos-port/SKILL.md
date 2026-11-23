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
   按 [pitfalls.md](references/pitfalls.md) 的验证清单核对（AssetKey 指纹 / rawfile 检测 / 版本号反推）；
   **界面这一关单独判**：`ps` 看进程还在、`aa dump` 看 `#FOREGROUND`、**截图**看有没有内容
   （非空版面树不算、"应用图标+转圈"不算）——细则见
   [startup-and-first-screen.md](references/startup-and-first-screen.md)

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
lingqu-cli probe  --path . --auto --max 8    # 自动验证：自己枚举版面里能点的文本逐个点
lingqu-cli probe  --path . --feature <名> --click-file <按钮文本文件>   # 真机点一下再判定
```

规则：**先 `resume` 看停在哪步，再跑那一步**；判断"能不能用"只认 `verify` 的落档，
不要拿 `build` 通过就宣称可用。真机装不上先 `sign` 体检再看 `deploy` 的 hilog。

## 真机功能自测（点了有没有反应，让证据说话）

> 「进程在跑 / 日志正常 / 截图看着像」都不算功能可用。要判定某个功能，必须在真机上
> **点它一下，再对比点了之后发生了什么**——这一步是 agent 自己能做、也应当自己做的实验。

闭环六步（`lingqu-cli probe` 已把它做成一条命令）：

1. `dumpLayout` 存 before
2. 按**文本**找节点，取 `attributes.bounds` 的 `"[x1,y1][x2,y2]"` 中心——
   **别按截图估坐标**：设备 1840×2800，截图是缩放过的，估出来的点必偏
3. `uiInput click <x> <y>`
4. 再 dump 一次 after，比对文本集合：**冒出新的文本 = 有反应；一字不差 = 没反应**
5. 截图归档（给人看，也是第二路证据）
6. 结论写进 `.lingqu/verify/<工程>.probe.json`，`verify` 会**优先**采用它

```bash
lingqu-cli probe --path . --feature pick_m3u8_file --click-file ./pick.txt
lingqu-cli probe --path . --feature start_download --click-file ./start.txt --expect-log-file ./expect.txt
```

判定口径：点后版面**多出新文本**（且不含"无法/失败/错误"）→ `pass`；版面**没变** → `fail`；
日志命中 `--expect-log` 同样算 `pass` 的一种。落档里有 `verdict / note / evidence`，`note` 要写清
"多出了哪条文本"或"节点数 35→35"，别只写"失败"。

**中文一律写进 UTF-8 文件再传**（`--click-file` / `--expect-log-file`）：仓颉在 Windows 上
接不到非 ASCII 的 argv，`--click 选择文件` 会直接崩（AGENTS §4-119）。同理给 agent 传的任何中文内容都走文件。

探针**不计人工介入**（A3）——这是 agent 自己做的实验。判不准就如实记「未测」，别凑结论：
需要前置现场的（例：取消下载要先有"下载进行中"）、需要滚动或跨窗口才看得见的节点。

## 工具自检与自装（devecocli）

`devecocli`（`@deveco/deveco-cli`）是华为的 HarmonyOS 开发工具集 CLI，能查平台文档、拉官方 skills、
读设备日志。**先探再用，别一上来 `npm i -g` 覆盖用户环境**：

```bash
"$APPDATA/npm/devecocli.cmd" --version    # 绝对路径探（它不在 cjh 继承来的 PATH 上）
command -v devecocli                      # 有就直接用
```

探不到才装：`npm i -g @deveco/deveco-cli`（装完仍是上面那个绝对路径）。实测 1.0.0 有的子命令：

| 子命令 | 用途 |
|---|---|
| `device` / `emulator` | 列设备、起模拟器 |
| `log --bundle-name <包名> --keyword <词> --tail 200` | 拉 hilog——**崩溃/白屏先看它** |
| `docs search <词>` / `docs read` / `docs catalog` | 查本地平台文档 |
| `skills list` / `skills find` / `skills add --skill <hmos-*> --path ~/.cjh/skills` | 拉官方 skills（61 个 `hmos-*`） |
| `init --path ~/.cjh/skills --agent` | 把 skills 装成 agent 可用的形态 |
| `create` / `build` / `run` / `serve` / `update` | 建/编/跑工程 |

**它没有 `sign`**：签名走 `lingqu-cli sign --login` + `sign --auto`，别指望它。两条边界：
`skills list` 是**线上拉取**（断网就空）；`docs` 依赖本地 `docs.zip`，缺了先 `update`。
它也没有"点了有没有反应"的判定能力——那件事用 `lingqu-cli probe`。

## 让灵渠的界面能执行你的建议（回复格式约定）

灵渠会**解析你的回复**渲染成可点卡片，所以这两条格式要照写：

1. **建议命令**一行一条，写成 `lingqu-cli <命令> --path <工程目录>`。只读命令
   （scan / deps / sign / verify / report / batch / resume / env / diagnose）在用户开了
   「自动跑只读命令」时会自动执行；会改工程或动真机的（`port --apply` / `revert` / `hap` /
   `deploy`）也渲染成按钮，但必须人点。
2. **要人定的取舍**写成围栏块（语言标记 `lingqu-decision`），块里一行 JSON：

   ```lingqu-decision
   {"rule":"reqwest 改用 rustls 后端","decision":"accepted","why":"ohos 没有 openssl"}
   ```

   `decision` 取 `accepted`（建议采纳）或 `ignored`（建议忽略）。界面会渲染成确认卡，
   **人点一下才落进 `.lingqu/port/<工程>/decisions.json`**——你只提案，决定权在人。
   同一 rule 重复提案按最后一次算。

## 失败现场怎么来（别自己猜）

某一步没过时，灵渠会**自动**把「落档正文 + 日志尾 40 行 + 该步判据」发给你（`t2h:ai_brief`）。
收到这种【灵渠 · 自动诊断】开头的消息时：先给一句话根因（引用具体某行），再给可执行动作，
判不准就写"需要哪份证据"——**不要编造修复步骤**，也不要复述现场。

## references（按需读，不要全读）

| 文件 | 什么时候读 |
|---|---|
| [cargo-patches.md](references/cargo-patches.md) | 动 Cargo.toml 之前；为什么用 [patch] 不用 path 依赖、为什么必须钉精确版本；**`reqwest` 忘了关默认特性 → 拉 openssl-sys** 的样子与自查命令（症状串 `Could not find directory of OpenSSL installation`） |
| [toolchain.md](references/toolchain.md) | 配交叉编译链接器之前；gnullvm 与 NDK clang 的两平台差异 |
| [arkweb-shims.md](references/arkweb-shims.md) | 前端适配三坑；polyfill 完整代码与"为什么必须 remove() 而不能 display:none" |
| [signing.md](references/signing.md) | **真机装不上（9568322）时第一个读**：三条签名路径对比、复用本机自动签名材料的 6 步配方、失败码表、什么时候才真需要账号 |
| [pitfalls.md](references/pitfalls.md) | 部署/真机阶段按报错原文索引；hdc 目录坑、锁屏、验证清单；**构建期 `pkg-config … cross-compilation` 的两种归因（glib-sys vs openssl-sys）见第 13 条**；**「起来即退」（装机/启动都"成功"但进程秒退、hilog 无输出）见第 17 条**——先装不依赖 `App` 的早期 panic hook 再谈排查；**`no method named center/decorations…` 见第 18 条**（方法被 `cfg(desktop)` 门控，按 impl 块边界判断）；**签名优先自签名、`11014003 Init keystore failed` 见第 19 条**；**插件与 fork 版 tauri 版本漂移（`no field appimage`）见第 20 条**；**「装上了、启动了，但秒退/全黑/白底转圈」见第 21 条**（启动四连坑总表） |
| [startup-and-first-screen.md](references/startup-and-first-screen.md) | **真机"起来了但界面不对"第一个读**：取证通道（`hdc file recv -b` 才读得到沙箱）→ 早期 panic hook（唯一能拿到 SIGABRT 真因的手段）→ 数据目录 EPERM（跑在构造 `Builder` 之前，`app.path()` 修不到）→ 重复 `main` webview（窗口 label 默认就是 `main`）→ `defaultPage` × label 四种组合的真机读数与判据（`SetUIContent timeout`、非空版面树 ≠ 有内容） |
| [native-ui-bridge.md](references/native-ui-bridge.md) | **某命令在鸿蒙侧是空壳**（`rfd::FileDialog` / `explorer` / 分享 / 相册 → `None`、`Err("当前平台不支持")`）时读：`__ohos_dispatch` 桥骨架、主线程 env 铁律、三种返回值形态、**picker 的 uri 授权不覆盖裸路径**、验证三步（桌面 + 交叉 + `hap` 验 ArkTS） |
| [plugin-adaptation.md](references/plugin-adaptation.md) | **遇到鸿蒙侧没有对应物的插件/平台 API 时第一个读**：判定顺序（先查 fork 源码 cfg 门控，别把"方法不存在"当"平台没有"）→ 三层适配（wry/tao 差异层 fork 先行 → 平台条件编译补丁 → API 映射到 ArkWeb/系统能力）→ 降级是最后手段且必须登记 limit（静默砍功能算移植失败） |
