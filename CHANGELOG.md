# 更新日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的结构，
版本号三处一致：`cjpm.toml` / `cj-tauri.toml` / 本文件最新条目（见 `AGENTS.md` §6）。

---

## [0.13.0] - 2026-10-30

**主题**：P4 收官 —— T4-7 Agent 兜底闭环（错误指纹库 + 结构化补丁建议 + 六道闸校验器），
`t2h:diagnose` 命令上线。**P4 全部任务（T4-1～T4-9）完成**。

### Added

- **`src/port/diagnose.cj`（新）**——T4-7a/b：
  - **错误指纹库 15 条**（FP-001~015，与 `skills/t2h-ohos-port/references/pitfalls.md` 同源）：
    编译链接期 7 条（napi 缺依赖 / -lgcc_eh / 链接器未配置 / patch 绕过 / wry·tao 未一并 patch /
    版本解析失败 / custom-protocol 白屏）+ 运行部署期 8 条（app_data_dir panic / SIGABRT /
    9568322 签名 / 9568269 安装路径 / 10106102 锁屏 / rawfile 死资源）
  - **patchKind 两档**：`rule`（现有规则可修 → 建议重跑 t2h:port，幂等只补缺口）/
    `guide`（需人工或 AI）；**命中时不调用模型**——更快、更准、可审计（技术思路 §5.5 的差异化点）
  - `diagnoseLog`：日志逐行字面量匹配，同指纹去重取首行证据（带日志行号）
  - `patchProposalsFromDiagnosis`：rule 档按 ruleId 映射目标文件（按文件去重）
- **`src/port/gates.cj`（新）**——T4-7c 六道闸（可纯函数化的四道 + 命令层两道）：
  1. 文件白名单（白名单前缀 + 绝对禁碰 .git/target/node_modules/dist/Cargo.lock）
  2. 单点原则（一次一文件）
  3. 结构约束（删除 >80 行 ≈ 整体重写，拒；空补丁拒）
  4. 轮次与经济性（>8 轮拒、同指纹失败 ≥2 转 guide——`FailLedger` 跨轮计数）
  （编译闸/回归闸需 cargo 子进程，P5 落地后接入）
- **`t2h:diagnose` 命令**（三处联动）：输入 `log` 全文或 `logPath` 文件路径 →
  命中指纹（现象→根因→修法）+ 补丁提案过闸结果 + `suggestRerunPort`；
  **未命中如实返回空**（长尾才走 LLM 对话通道）。④ 屏新增"诊断"入口
  （日志路径 → 渲染"[FP-xxx] 根因 → 修法（重跑预览改造即可修 / 需人工）"）
- **8 例新单测**（总 82）：指纹库形态、rule 档命中与证据行号、同指纹去重、
  无命中返回空、补丁提案文件映射与去重、六道闸（白名单/单点/结构/轮次/经济性/正常放行）、
  FailLedger 分指纹计数

### Changed

- **AGENTS.md §8 上游回馈纪律 + fork 先行策略**：cj-tauri/cjh 能力不满足 → 提 issue（有修法提 PR）；
  **tauri/openharmony-ability 能力不满足时不等上游**——在 yangyongzhen fork 下建
  `fix/<工程>-<问题>` 分支先解决，patch rev 钉住继续移植，后续整理 PR 贡献上游
  （实证：cc-switch 官方 feat/open-harmony、habit-tree 的 ability feat/0.3.0 patch）
- **§8 新增鸿蒙侧工具与技能生态表**：deveco-cli（`devecocli build/run`，P5 部署链实际使用）、
  harmonyos-agent-skills（官方鸿蒙 skills 集合，skill 沉淀的参照形态与回馈对象）；
  gitcode 反爬时按 atomgit 同路径域名访问

### 验证证据

| 断言项 | 值 |
|---|---|
| 指纹库 | 15 条（rule 7 + guide 8），marker 全部为报错原文稳定子串 |
| 诊断匹配 | FP-001/002 主路径命中 + 证据带日志行号；同指纹去重；无命中返回空 |
| 六道闸 | 白名单外/禁碰文件/多文件/大段删除/空补丁/超轮次/超失败全部拦截；干净补丁放行 |
| 门禁 | 四道闸全绿，**82 例单测** |

**P4 出口判据达成情况（如实标注）**：判据 2（人工介入 ≤5 有记录）、4（幂等可回滚）已达成并有
单测与实测证据；判据 1（`cargo check --target ohos` 0 error）、3（规则命中率 ≥60%）**需 P5
交叉编译流水线**才能取证——指纹库与六道闸就是为那一刻准备的（编译闸/回归闸届时接入）。

---

## [0.12.0] - 2026-10-30

**主题**：P4 第三刀 —— setup 接线机械化（R2-PORT-010）+ 对话框资源生成（R2-PORT-014）
+ 人工决策记录可审计（`t2h:decisions`，T4-8 收口）。

### Added

- **`src/port/resolve.cj`（新）**：
  - **R2-PORT-010**（auto）：`.setup(|app| {` 块内接线 `install_panic_hook(app)` 与
    沙箱目录调用（4 行，形态照 habit-tree 迁移后 lib.rs）；幂等——二次 apply 文本不变；
    已接线/无 setup 块分别走跳过与 guide（不猜）
  - **R2-PORT-014**（auto）：生成 `lingqu-dialog.js` + `lingqu-dialog.css`——应用内
    Promise 化 `confirmDialog`/`promptDialog` 模块（单层 `.dialog`、z-index 80、
    颜色跟随页面 CSS 变量）；**confirm/prompt 调用点替换仍归 012 guide**（改控制流，
    机械替换会改坏代码——边界不移）
- **`t2h:decisions` 命令**（三处联动）：`action=record`（同 rule 覆盖最新决策，防重复条目）
  / `action=list`；落 `.lingqu/port/<工程>/decisions.json`（`lingqu/decisions/v1`）。
  A3 口径：guide 采纳 = 一次人工介入；忽略也要留痕
- **④ 屏 guide 项待确认卡**：guide 行标"待你确认"，行内采纳/忽略按钮；
  已决策显示"人工·已采纳/已忽略"；顶部计数变为"已决策 n，待决策 m"；
  `ui_report` 新增 `portDecided` 字段（服务端白名单同批放行）
- **5 例新单测**（总 74）：接线插入位置与幂等、无 setup 块 guide、对话框资源形态、
  不存在目录 outcome

### 验证证据（habit-tree 迁移前文件实测，Xvfb + `ui_report`）

| 断言项 | 值 |
|---|---|
| portRules / portApplied | **14 / 11**（auto 10 + guide 1） |
| guide 1 条 | 本机未设 `NATIVE_OHOS_SDK` → R2-PORT-008 如实降级（同 0.11.0 行为） |
| portDecided | 0（决策记录链路已通，端到端点选待实机） |
| errorCount | 0 |
| 门禁 | 四道闸全绿，**74 例单测** |

**未做（如实标注）**：决策记录的端到端点选（Xvfb 下无指针交互，命令层逻辑已编译验证）；
confirm/prompt 调用点替换仍 guide（设计边界）；`cargo check --target ohos` 需 P5。

---

## [0.11.0] - 2026-10-30

**主题**：P4 第二刀 —— 工具链落盘（T4-3）+ 平台 cfg 分支注入（T4-4）+ ArkWeb 兼容层（T4-5）
+ 三档动作与人工介入计数（T4-8），`t2h:port` 从"Cargo.toml 改造"扩展为完整规则面。

### Added

- **`src/port/toolchain.cj`（新）**——T4-3 工具链落盘：
  - R2-PORT-007 `rust-toolchain.toml`：Windows 走 `gnullvm`（llvm-mingw 缺 `-lgcc_eh` 的实测结论）、
    Linux 走默认 GNU；targets 统一加 `aarch64-unknown-linux-ohos`
  - R2-PORT-008 `.cargo/config.toml`：NDK clang 直作链接器（自带 clang 包装是 Unix shell 脚本）
    + sysroot rustflags + cc 环境变量；SDK 路径从 `NATIVE_OHOS_SDK` 读取，
    **未设时如实降级为 guide 提示，不写坏文件**
- **`src/port/shim.cj`（新）**——T4-4 / T4-5：
  - R2-PORT-009 `lib.rs` 注入 `resolve_app_data_dir()`（OHOS 沙箱 `/data/storage/el2/base/files`）
    + `install_panic_hook()`（panic 落盘 `panic.log`——鸿蒙 hilog 不捕获 Rust stderr）
  - R2-PORT-011 `index.html` 注入 localStorage 内存 polyfill（ArkWeb 自定义 scheme 下
    `window.localStorage` 为 null；桌面原生可用时不生效，业务零改动）
  - R2-PORT-012 / 013（**guide 档**）：探测裸 `confirm(`/`prompt(` 调用点与
    `<input type="color">`——只给位置与处置方案（Promise 化对话框 / 应用内色板），
    **不机械替换**（会改坏代码）；计数进人工介入（验收 A3 可审计）
- **T4-8 分档计数**：`RuleOutcome` 增加 `tier`（auto/guide），`PortResult.countersJson()`
  输出 auto/guide 两计数；④ 屏显示"人工介入 n/5"；`ui_report` 新增 `portAuto/portGuide`
- **t2h:port apply 扩展**：逐文件备份到 `.lingqu/port/<工程>/`（Cargo.toml / rust-toolchain /
  cargo config / lib.rs / index.html），备份不覆盖（首次为准）
- **8 例新单测**（总 64）：两套工具链模板、SDK 路径替换、注入块形态、分档计数、
  guide 探测（正向 fixture + 迁移后样本应为 false）

### 验证证据（habit-tree 迁移前文件实测，Xvfb + `ui_report`）

| 断言项 | 值 |
|---|---|
| portRules / portApplied | 12 / 9（auto 8 + guide 1） |
| guide 1 条 | 本机未设 `NATIVE_OHOS_SDK` → R2-PORT-008 如实降级提示（不编造链接器路径） |
| errorCount | 0 |
| 门禁 | 四道闸全绿，**64 例单测** |

**未做（如实标注）**：注入函数的 setup 接线（`install_panic_hook(app)` 调用点）涉及语义，留 guide；
confirm/prompt 的应用内对话框实现属 P4 第三刀（跟 T4-8 审批卡一起）；
`cargo check --target ohos` 出口判据需 P5 交叉编译环境。

---

## [0.10.0] - 2026-10-30

**主题**：P4 第一刀 —— 规则引擎 + Cargo.toml 文本变换（路线图 T4-1 / T4-2 / T4-6），
`t2h:port` / `t2h:revert` 命令上线，④ 改造执行屏接真数据。

### Added

- **`src/port/port.cj`（新，`lingqu.port` 包）**：
  - 规则模型（T4-1）：每条规则 = id + 适用条件 + 变换 + `RuleOutcome`
    （applied / note / before / after——evidence 载体，UI 与报告直接展示）
  - 六条 Cargo.toml 规则（T4-2），**逐条对应 habit-tree `main→ohos` 分支的真实 diff**：
    R2-PORT-001 `[lib]` crate-type 补 cdylib（`["rlib"]` → `["staticlib", "cdylib", "rlib"]`）、
    002 tauri 钉 `=2.11.5` + features 合并 custom-protocol/protocol-asset（已有 features 原样保留）、
    003 tauri-build 钉 `=2.6.3`、004 wry 钉 `=0.56.0` + `default-features=false`（仅当存在 tauri 依赖）、
    005 追加 OHOS target 段（napi-ohos / openharmony-ability 桥）、006 追加 `[patch.crates-io]`
    与 ability patch 段（git URL + rev 固定）
  - 幂等与回滚（T4-6）：追加块带 `# === lingqu: <rule-id> ===` 标记；原地改写看目标状态判定
    （钉没钉/有没有该段）；`isIdempotent` 可断言"再跑一遍 applied=0"；
    **apply 前自动备份原文件到 `.lingqu/port/<工程>-Cargo.toml.bak`，`t2h:revert` 一键写回**
  - dry-run 落预览 `.lingqu/port/<工程>-Cargo.toml.preview`——UI diff 预览与实测对照的载体
- **命令 `t2h:port` / `t2h:revert`**（三处联动齐全）；④ 改造执行屏新增规则改造卡
  （预览/应用/回滚三按钮 + 逐条 outcome 表 + `portApplied/portRules/portError` 自检字段，
  服务端白名单同批补放行）
- **7 例新单测**（总 63）：六条全应用 / 变换内容逐项断言 / 幂等二次跑 /
  已迁移工程逐字节不变 / 非 Tauri 工程跳过钉版 / 行级工具边界

### Fixed

- `spliceLines` 死循环：`count=0` 且 `i==at` 时 `i += 0` 后 `continue`，无限插入直到
  OutOfMemoryError（单测二进制直跑抓到的栈）。修法：`inserted` 标志位
- 行模型纪律：规则内禁止往单个行元素塞 `\n`——ruleTauriPin 曾把注释与代码并进一个元素，
  导致后续规则按行扫 `tauri` 时命中的是注释行、误判成非 Tauri 工程。抽 `spliceLines` 统一处理

### 验证证据（habit-tree 迁移前 Cargo.toml 实测，Xvfb + `ui_report`）

| 断言项 | 值 |
|---|---|
| portApplied | **6 / 6**（六条规则在未迁移文件上全部应用） |
| **规则产物 vs 真实迁移 diff** | **功能性代码行全部一致**（crate-type / 钉版 / features / OHOS target 段 / 两段 patch 的 rev 与 URL 逐字符吻合）；差异仅：注释措辞、人工按需加的 `image-png` feature、上游版本号演进——**规则覆盖了该工程 Cargo.toml 迁移的全部机械改动** |
| 幂等 | `idempotent=true`（二次跑 applied=0，文本逐字节不变） |
| 门禁 | 四道闸全绿，**63 例单测** |

**未做（如实标注）**：T4-3（工具链落盘）/ T4-4（cfg 分支注入）/ T4-5（ArkWeb 兼容层）/
T4-8（三档审批与人工计数）留给 P4 第二刀；T4-7（Agent 兜底）按砍单顺序最后；
`cargo check --target aarch64-unknown-linux-ohos` 出口判据需 P5 交叉编译环境。

---

## [0.9.0] - 2026-10-30

**主题**：P3 `t2h:deps` —— Cargo 依赖树 OHOS 兼容性矩阵 + 替代建议库（路线图 T3-1～T3-5），
③ 依赖扫描屏接真数据，依赖维评分上线。

### Added

- **`src/deps/deps.cj`（新，`lingqu.deps` 包）**：
  - `parseCargoLock`：解析 `Cargo.lock`（v3/v4）整树，按 `[[package]]` 块取 name/version；
    `[metadata]` 段不收；残缺块（缺 version）也收。**不跑 cargo 子进程**——单测只测纯函数（D-009）
  - `parsePatchedCrates`：提取 `Cargo.toml` 的 `[patch.*]` 段覆盖的 crate 名
    （`[patch.crates-io]` 与 `[patch."https://…"]` 都算），用于判断 fork 替换是否已落档
  - `applyRule` 规则表（**每条都有实测出处，不凭空编**）：tauri 全家桶 / wry / tao /
    openharmony-ability → 需 patch（alternative 给 git rev 与版本钉法）；
    `openssl-sys` / `native-tls` / `rfd` → 不可用 + 替代方案（rustls / 应用内降级）；
    `reqwest` / `dirs` / `napi-ohos` → 有条件可用（evidence 写清条件）；
    **已在 `[patch.*]` 里的 crate 优先判「已处置」（R2-DEPS-100）**——这是迁移前后的关键区别；
    表外的 crate 默认"可用"，evidence 标明"待真机验证"，**不冒充已验证**（避免误报，P3 出口判据 1）
  - `depsScanJson`：总入口，产出 `lingqu/deps/v1`；读盘失败走 `outError`（D-013 不静默）
  - `depsScoreOf`：依赖维评分（不可用 −15 / 需 patch −5，与 runtime/api 维同口径），floor 0
- **命令 `t2h:deps` + 三处联动**：`src/main.cj` 注册、capabilities 放行、UI 调用；
  结果落 `.lingqu/deps/<工程名>.json`
- **③ 依赖扫描屏接真数据**：工程路径输入 + 扫描按钮 + 全量/需 patch/不可用筛选页签 +
  状态 pill / 规则 / 依据 / 替代建议四列表格；`ui_report` 新增
  `depsTotal / depsPatch / depsUnavailable / depsRows / depsOut / depsError` 六个可断言字段
  （**后端 `UiReportCommand` 是显式字段白名单，前端新字段必须同批在服务端补放行**——本轮踩到）
- **② 画像的依赖维评分条点亮**：`t2h:deps` 出分后 ② 屏 deps 维从"—"变为真分数
  （build/dist 仍属 P5，如实保持 -1）
- **9 例新单测**（总 50）：lock 解析（主路径/空文件/残缺块）、patch 提取（含子表头排除）、
  规则表逐档断言、已 patch 优先、评分（主路径/扣到底不出负数）、错误路径（无 Cargo.lock → outError）、
  真实样本回归（cc-switch-ohos，无样本时跳过不造假）、`quotedValue` 边界

### Fixed

- `ui_report` 服务端字段白名单漏新字段：前端加了 `deps*` 指标但落盘日志里始终不出现
  （回投被服务端丢弃）。处置：`UiReportCommand` 同批补放行，探针可断言

### 验证证据（cc-switch-ohos 真实样本，`.lingqu/ui-report.log`）

| 断言项 | 值 |
|---|---|
| depsTotal / depsRows | **625**（与 Cargo.lock 包数一致——出口判据 3） |
| depsPatch | 0（该工程 `[patch.*]` 已落，tauri/wry 全部命中"已处置"R2-DEPS-100） |
| depsUnavailable | 1（`rfd` 0.16.0 → R2-DEPS-011 + 替代建议） |
| depsOut | `.lingqu/deps/cc-switch-ohos.json`（真实落档） |
| 依赖维评分 | 85 |
| errorCount | 0 |
| 门禁 | 四道闸全绿，**50 例单测** |

**未做（如实标注）**：规则库只覆盖已实测的 10+ 个 crate（tauri 系 / wry / tao / napi-ohos /
openssl 系 / rfd / dirs / reqwest），其余 615 个 crate 走默认直编——**不可用清单与真实交叉编译
失败点的 ≥80% 吻合度验证（出口判据 1）需 P5 交叉编译流水线到位后做**；`cargo metadata` 子进程
版采集层未做（当前用 Cargo.lock 静态解析，够用且可单测）。

---

## [0.8.0] - 2026-10-30

**主题**：P2 收尾 —— **C2 发现置信度**落地（人工基线双向 diff），并据此补齐 4 条扫描规则。

### Added

- **`src/scanner/baseline.cj`（新）**：`lingqu/baseline/v1` 解析 + 双向 diff + `lingqu/confidence/v1` 输出
  - 漏识别（基线有、扫描无）扣 **C2 = (基线项 − 漏)/基线项**；误识别（扫描有、基线无）只计数；
    结论分歧（两边都有但结论不同）只计数、用于盯判定表质量
  - **没有基线时 C2 = -1**（页面显示"未对照"），绝不顺口算成 100
  - 解析容错：语法错 / 顶层非对象 / 缺 items / 单项缺 kind 或 name 都只跳过，不让扫描失败
- **命令 `t2h:scan` 接入基线**：按工程名自动找 `samples/baselines/<工程>.json`（参数 `baseline` 可覆盖），
  返回值新增 `baseline` / `baselineError` / `confidence`
- **② 迁移画像新增「C2 发现置信度 · 人工基线对照」卡片**：基线项 / 命中 / 漏识别 / 误识别 +
  基线来源 + 漏识别与误识别明细；C1/C2/C3 三个指标并列显示（防止只看 C1）
- **`samples/`**：`baselines/habit-tree.json`（人工基线 24 项，注明来源与口径）、
  `evidence/habit-tree-scan-before-c2.json`（补规则前的扫描快照，第一轮 C2 的底稿）、`README.md`（口径 + 加样本步骤）
- **8 例新单测**（总 41）：基线解析（正常/坏 JSON/顶层非对象/缺字段）、全命中、数漏识别、数误识别、
  无基线不算 100、结论分歧、名字首尾空白容错

### Fixed（C2 第一轮 diff 直接扫出来的 4 个漏识别，全部补规则而不是改基线）

| 漏识别 | 处置 |
|---|---|
| `canvas.toDataURL`（celebrate.ts 导出 PNG，2 处） | 新增前端标记 + 规则 `R5-010`：长 base64 跨桥风险 → `toBlob` + 原生保存 |
| `FileReader`（ui.ts 导入处理） | 新增前端标记 + 规则：本身可用、配合 `<input type=file>` 才受限（判 `不适用`） |
| `window.open`（ui.ts 外链回退） | 新增前端标记 + 规则：主路径已走 `open_url` 命令，判 `不适用` |
| `getVersion`（前端 `@tauri-apps/api/app`） | **新增一类解析 `parseFrontendTauriApis`**：前端侧 Tauri API 能力并进平台 API 维，规则 `R3-010`（OHOS 走 bundleManager）；同时补上 window/path/fs/dialog/webview 五个模块的判定 |

### Changed

- 版本 0.7.0 → 0.8.0，`cj-tauri sync` 重派生骨架
- `docs/P2-scan-口径草案.md` 新增 §三之二「A4 人工基线口径」：基线的**边界**（库依赖归 P3、死代码也要收）
  与「先人工列基线再补规则」的自证流程

### 验证范围

| 断言项（habit-tree 实测） | 第一轮（0.7.0，未补规则） | 本轮（0.8.0） |
|---|---|---|
| R（识别项） | 20 | **24** |
| C1 结论覆盖率 | 100% | 100% |
| **C2 发现置信度** | **83.3%**（漏 4 项） | **100%**（漏 0 / 误 0 / 分歧 0） |
| 五类分布 | cmd12 / ev0 / plg0 / fe4 / api4 | cmd12 / ev0 / plg0 / **fe7** / **api5** |
| C3 人工占比 | 5.0% | 4.2%（1/24） |

- ✅ 四道闸全绿；**41 例单测**；`ui_report` 断言 `scanC2=100, scanMissed=0, scanExtra=0, scanVerdictDiff=0,
  scanBaseline=samples/baselines/habit-tree.json`，逐页签 `scanRows` 12/0/0/7/5，`errorCount=0`
- ⚠️ **只做了 1 个样本的基线**（habit-tree）。cc-switch（R=317）尚无基线 → 它的 C2 如实显示"未对照"；
  5 样本基线矩阵排在 P7。build/deps/dist 三维仍为 `-1`（待 P3/P5）

---

## [0.7.0] - 2026-10-30

**主题**：②「迁移画像」界面接真数据（`t2h:scan` 驱动），并把参考资源写进开发契约。

### Added

- **② 迁移画像改成数据驱动**：`assets/ui/index.html` 的整屏由 `lingqu/scan/v1` 渲染——
  评分环（`--v` = 后端总分）、五维条（未扫描维如实显示 `—`，不编造 100）、
  R/D/H/U 与 C1/C3、五类清单表（处置 pill / 规则 / 出现点 / 依据）、阻塞项列表
  （未知 = hard 红条、人工 = soft 黄条）；页签切换即换数据源
- **扫描入口**：右上角工程路径输入 + 「扫描」按钮（`t2h:scan`），失败原因直接显示在提示行
- **自检扩展**：`ui_report` 新增 `scanKind / scanRows / scanBlockers / scanOutError / scanKindRows`；
  `LINGQU_SCAN_PATH` 探针扫完会**把五类页签逐个切一遍并逐次回投**
- **`AGENTS.md` §8 参考资源**：**CangjieSkills 地址**
  （https://atomgit.com/Cangjie-SIG/CangjieSkills ）+ 本机克隆路径 + `search_docs.py` 用法，
  以及 cj-tauri / cjh 本地仓位置——写仓颉卡住时的第一查阅点，防止后续会话遗忘
- **`projectNameOf` / `sanitizeFileName`**（`lingqu.scanner`，公开纯函数，各带测试）

### Fixed

- **`.lingqu/scan/<工程>.json` 从来没写成功过（0.6.0 就在丢证据）**：
  工程名只按 `/` 取末段，Windows 路径 `E:\test\rust\habit-tree` 整条被当名字 →
  落档路径非法 → `FSException: The input path 'parent' … does not exist`；
  而 `eprintln` 在 GUI 里被框架日志接管（AGENTS §4 第 14 条），**失败是静默的**。
  处置：路径末段 `(`/` 与 `\` 取最后出现者）+ 非法字符转 `_` + **写档失败原因进返回值 `outError`
  并由页面显示**——同类静默失败以后看得见
- **`docs/仓颉资源地址.md` 编码**：原文件是 GBK 粘贴稿（`read` 报 "invalid UTF-8 text"）→
  显式按 936 解码转 UTF-8，并重排成五节表格

### Changed

- 版本号 0.6.0 → 0.7.0（`cjpm.toml` / `cj-tauri.toml` / 本文件三处一致），`cj-tauri sync` 重派生骨架

### 验证范围

| 断言项（habit-tree 实测） | 值 |
|---|---|
| R / D / H / U | 20 / 20 / 1 / 0 |
| C1 / total | 100% / 68（partial） |
| `scanOut` | `.lingqu/scan/habit-tree.json`，8606 B（**本轮才真的写出来**） |
| `scanKindRows` | `commands:12,events:0,plugins:0,frontend:4,platform:4` |
| 逐页签 `scanRows` | 12 / 0 / 0 / 4 / 4 |
| JS 错误数 | 0 |

- ✅ 四道闸全绿；**33 例单测**（新增 2 例：路径末段 + 文件名净化）
- ⚠️ **未做**：C2 发现置信度（需人工基线双向 diff）；鸿蒙端 HAP 未开始；
  五维里 build/deps/dist 仍为 `-1`（待 P3/P5）

---

## [0.6.0] - 2026-10-30

**主题**：P2 `t2h:scan` 扫描器（五类清单 + 覆盖率 + 评分），口径按 `docs/P2-scan-口径草案.md` 落地。

### Added

- **`src/scanner/scan.cj`（新增包 `lingqu.scanner`）**
  - 工程识别：`Cargo.toml`（crate / tauri 版本）、`tauri.conf.json`（bundleId / frontendDist）
  - **五类清单**：命令（`#[tauri::command]` 函数 + `generate_handler!` 注册核对）、事件（emit/listen）、
    插件（Cargo + package.json 两侧合并）、**前端浏览器能力**（按能力计项，不按文件）、平台 API 符号
  - 处置四值域 + `未知` 禁用值；**同一符号/能力跨文件合并**，sites 只记账
  - 度量：`R/D/H/U`、`C1`（结论覆盖率）、`C3`（人工占比）、`C2`（留空并标注需人工基线）
  - 评分：runtime / api 两维实算；build / deps / dist 标 `-1`（未扫描）且 `partial=true`，
    **不编造 100 分**；总分是加权平均（`Σ维分×权重 / Σ权重`）
  - 输出 `lingqu/scan/v1` JSON，落 `.lingqu/scan/<工程>.json`
- **命令 `t2h:scan {path}`** + capabilities 声明 + `.gitignore` 覆盖 `.lingqu/`
- **扫描探针**：环境变量 `LINGQU_SCAN_PATH` → 页面启动即跑一次扫描，指标回投 `t2h:ui_report`
  （`scanR/D/H/U/C1/total/out/error`），**无视觉也能验扫描器**
- **16+2 例单测**（`src/tests/scanner_test.cj`）：命令/事件/插件/前端/平台解析、判定表、
  C1/C3 计算、禁用值拉低覆盖、评分不重复乘 100、命令一律 `不适用`

### Fixed（都是实测扫出来的）

- **总分算成 2500**：`weighted × 100 / 0.45` 把 100 乘了两遍 → 改为加权平均（回归测试锁住）
- **跨文件同名项没合并**：`app_data_dir`、`localStorage` 在多个文件各生成一项 → 编排层按名字合并
  （habit-tree 的 `localStorage` 从 5 项合成 1 项、17 个 sites）
- **扣分过重**：改造按 −10 算导致 habit-tree runtime/api 双双见底 25 分（与"该应用已迁移成功"矛盾）
  → 改造 −5 / 降级 −15，总分回到 68
- **事件与插件过度归因为"人工"**：cc-switch 上 22 个事件名 + 7 个插件全判人工，H=30 直接违反 A3（≤5）
  → 事件桥三端闭环判 `不适用`；插件判定表补齐（updater/deep-link/window-state/process/opener/
    global-shortcut/log/os 等）→ 两个样本 H 都降到 **1**

### 验证范围

| 样本 | R | C1 | H | C3 | total | 五类分布 |
|---|---|---|---|---|---|---|
| habit-tree | 20 | 100% | 1 | 5.0% | 68（partial） | cmd12 / ev0 / plg0 / fe4 / api4 |
| cc-switch | 317 | 100% | 1 | 0.3% | 65（partial） | cmd275 / ev22 / plg10 / fe4 / api6 |

- ✅ 四道闸全绿；**31 例单测**；能力三方比对通过
- ✅ 两个真实样本上 R/D/U 一致、无重复符号、sites 计数正确
- ⚠️ **未做**：C2 发现置信度（需人工基线双向 diff）、UI ② 迁移画像接真数据（仍是示意）、
  events/plugins 在 habit-tree 上为 0（该应用确实没用 `tauri-plugin-*` 与 `emit/listen`，非漏扫）

---

## [0.5.0] - 2026-10-30

**主题**：P1 对话通道接通（WS 流式 + 工具卡 + 审批卡）。

### Added

- **装配 `WsPlugin`**：capabilities 声明 `ws:connect/send/close`、事件 `ws:frame/ws:state`、
  `permissions: ["ws:default"]`、`scopes.ws: ["127.0.0.1","localhost"]`
- **页面 WS 通道**（对齐 cj-tauri `examples/cjnote` 的跑通实现）：
  - 引擎就绪自动连 `ws://127.0.0.1:<port>/ws`；`ws:state` 是唯一连接判据；断线退避重连（上限 12 次）
  - 帧分发：`delta`（增量累积 + 90ms 节流重绘）/ `tool_start` / `tool_result`（认 `is_error`）/
    `done`（认 `finish_reason`）/ `ack` / `cancelled` / `approval_request` / `error` / `history_messages` / `raw`
  - 帧解包**先认 `p.type`**（delta 帧自带 `text`，先按包装体 parse 会把帧吞掉——cjnote 踩过）
  - 会话续接：从帧里接住 `session_id`，重连后自动 `resume_session`，不另起会话
- **工具调用卡**：工具名 + 参数 + 结果回填（失败标红）；结果超 2000 字符截断显示
- **审批卡**：工具名 / 命中规则 / 参数（JSON）/ 倒计时（与 `expires_in_ms` 同步）/ 批准·拒绝；
  超时或断连就地标「按拒绝收场」；回执走 `approval_response{request_id, approved}`
- **错误可执行化**：按 `error.code`（`model_unavailable` / `provider_error` / `no_api_key` 等）给下一步提示
- **会话控制**：面板头「＋ 新建会话」「■ 中断」
- **自检扩展**：`ui_report` 增 `wsState / frames / toolCards / approvals / lastFrameType / replyPreview`；
  `LINGQU_UI_PROBE=1` 跑常规序列（含真实发问），`LINGQU_UI_PROBE=approval` 触发审批并**自动点拒绝**验证回执链路

### 验证范围

- ✅ **通道连通**：`ws=connected`，一问一答 `frames=2`（`delta`+`done`），`replyPreview="收到"`
- ✅ **审批闭环**：临时把 cjh 置严格模式（`capability.approval=["*:*"]`）→ `approvals=1`（卡片出现）
  → 自检自动点「拒绝」→ 回合继续到 `done`（`frames=268`）。**验证后已恢复原配置**
- ✅ 四道闸全绿；能力三方比对通过（ws 命令与事件均声明齐）
- ⚠️ 未验证：多轮长对话的滚动/性能、`tasks` 帧的面板（尚未接）、鸿蒙端 WS（cjh 在鸿蒙无 ws 能力位）

### 已知限制（诚实标注）

- cjh **默认是宽松模式**（无 `capability` 段 = 所有工具放行），所以审批卡只有在 cjh 侧开启
  `capability.enabled=true` + `approval` 命中时才会出现。工具不替用户改 cjh 的安全策略，
  只在卡片出现时正确渲染与回执。验证配方见 `docs/实施路线图.md` P1。

---

## [0.4.0] - 2026-10-30

**主题**：跨平台工程化（Windows + Linux 同源）+ 界面可自动验证。

### Added

- **门禁改 bash 为准（跨平台一份实现）**：`scripts/test.sh`（Linux / macOS / Windows-Git-Bash 通用）
  + `scripts/test.bat`（Windows 只做"找 bash 再委托"，纯 ASCII）。与 cj-tauri / cjh 两个上游仓同口径。
  支持 `-q`（快速回路）/ `-s`（先 sync）/ `-c`（清增量缓存）
- **`scripts/run-dev.sh` + `run-dev.bat`**：跨平台启动（PATH/动态库/工作目录一次配好；引擎由应用自己托管）
- **`scripts/setup.sh`**：换机器时把 `cjpm.toml` 里写死的本机绝对路径（框架 path + 两处 `-L<native>`）
  一键改成本机值，不必重跑 `cj-tauri create`（那会覆盖业务代码）
- **Linux 版内置引擎**：`vendor/cjh/linux-x64/cjh`（单文件、静态链接，无随行 DLL），
  并在 `cjhVendorVerified` 的 Linux 分支里加了 SHA256 校验
- **`.gitattributes`**：`.sh` 强制 LF 且保留可执行位、`.bat` 用 CRLF、二进制不动——
  否则 Linux 上会撞 `/usr/bin/env: 'bash\r': No such file or directory`
- **界面自检闭环 `t2h:ui_report`**：页面把版面指标（视口、grid 列宽、当前屏、屏数、id 数、
  设置面板状态、模型条数、JS 错误数）回投后端，后端落 `.lingqu/ui-report.json` 与 `ui-report.log`；
  置 `LINGQU_UI_PROBE=1` 时页面自己跑一遍「开设置 → 折叠 → 展开」序列。
  **没有视觉能力也能验证版面**（本项目首次做到）
- **快捷键 `Ctrl+,`** 打开模型与服务商设置

### Fixed

- **`t2h:cjh_models` / `cjh_settings` / `cjh_settings_save` 未注册**：`CjhCommands` 的 `match`
  里写了分支，但没给这三个命令名逐条 `app.register` → 页面拿到 `command not registered`。
  由界面自检抓出（`cj-tauri check` 只校验"已注册 ⊆ 已声明"，不查"已声明 ⊆ 已注册"）
- **门禁把失败原因藏了**：失败时只 `grep FAILED|ERROR|error:`，而真实原因（崩溃 / 链接错）里没有这些词。
  改为失败即打印日志尾部
- `run-dev.sh` 与 `test.sh` 在 Windows 上会因环境里的 `CANGJIE_HOME=D:\...` 形式路径导致
  所有命令 `exit 127`：统一加 `to_posix`（`cygpath -u` 或手写转换）

### Changed

- **弃用 `.ps1` 脚本**（`test.ps1` / `run-dev.ps1` / `tools/vendor-cjh.ps1`）：
  PowerShell 5.1 的坑太多（无 BOM 按 GBK 解码、`2>&1` 把 stderr 变成 ErrorRecord 后
  在 EAP=Stop 下炸、`Set-Content` 给 `.cj`/`.toml` 加 BOM），且 Windows 专用不利跨平台。
  替代为 `scripts/*.sh` + `*.bat` + `tools/vendor-cjh.sh`
- `tools/vendor-cjh.sh` 支持 `--platform win-x64|linux-x64`，一次重算两平台的 `SHA256SUMS`

### 验证范围

- ✅ `scripts/test.sh` 与 `scripts/test.bat` 均实测执行通过（三连全量 + 干净构建）
- ✅ 窗口实机截图（1280×840，标题 `灵渠迁移台 · Lingqu`）、WebView2 起 6 个渲染进程
- ✅ 界面自检序列实测：`240px 652px 372px` → 开设置 `models=2` → 折叠 `240px 1024px` → 展开复原，`jsErrors=0`
- ✅ cjh 由应用从 `vendor/` 自动拉起，`/api/health` → `{"status":"ok","version":"1.6.1"}`
- ⚠️ Linux 侧脚本**未在 Linux 上执行过**（按约定留给后续接续时验证）
- ⚠️ 纯视觉层面（配色、字距、留白）未做人工目检

---

## [0.3.0] - 2026-10-29

**主题**：UI 门面重做（对齐效果图）+ 模型配置。

### Added

- **七屏全部按效果图填实**：评分环与五维条、覆盖率分子分母、五类清单页签、阻塞项（严重度色标）、
  Cargo 依赖矩阵、改造步骤时间线、实时日志（着色）、构建五阶段、产物卡（含 `.so` 的 AssetKey 指纹）、
  功能清单打勾表 + 证据缩略图、报告三段式与风险分级
- **AI 助手可折叠**：面板头 `»`、顶栏「AI 助手」、快捷键 `Ctrl+B` 三条入口；折叠后中栏占满，
  右侧留一条竖向悬浮唤出条
- **模型与服务商配置视图**（参考 cjnote `examples/cjnote`）：引擎状态与端点、模型列表（点选即切）、
  Base URL / API Key（**永不回填**）/ 模型名 / 温度 / 单轮最大 tokens / 最大工具轮数，
  「保存并生效」直接推给运行中的 cjh（外部实例也生效，不必重启）
- **后端命令**：`t2h:cjh_models`（GET `/api/models`）、`t2h:cjh_settings`（GET `/api/settings`）、
  `t2h:cjh_settings_save`（POST `/api/settings`，**只提交用户真填了的字段**）
- 深/浅色主题切换（同一套令牌，与 cj-tauri 生态一致）
- 引擎未就绪时，对话区给**可操作**的提示卡（「立刻拉起」/「校验并重试」），而不是干巴巴的"未连接"

### Changed

- **去掉「指定路径启动」入口**——引擎是内置随包的，启动即自动托管；`t2h:cjh_start` 保留为后端兜底
- 引擎三态同时显示在顶栏、左栏底部、输入框上方，任何一屏都看得见
- REST 调用放后端而不是页面直接 fetch：避免 WebView 自定义 scheme 的跨源问题，
  也不用把 `127.0.0.1` 写进 `scopes.http` 给页面开一条出网白名单
- 前端**不持久化任何状态到 localStorage**——ArkWeb 自定义 scheme 下它不可用，
  这正是本工具要写进规则库（R5-001）的坑，自己不能踩

### 验证范围（诚实标注）

- ✅ `scripts/test.ps1` 四道闸全绿；后端零警告；13 例单测通过；HTML 结构平衡（7 屏 / 302 div / 43 button）
- ✅ 前后端命令面三方一致（`cj-tauri check` 比对通过）
- ⚠️ 界面渲染、折叠、模型读取/保存的实际交互仍需人工目视验证（受限宿主里窗口起不来）

---

## [0.2.0] - 2026-10-29

**主题**：AI 引擎托管完整化 + 工程规范落地。

### Added

- **`src/cjh_host.cj`**：完整移植 cj-tauri `examples/ai-chat` 的 cjh 托管实现
  - 健康检查 `GET /api/health`（`stdx.net.http`），替代原先的裸 TCP 探测
  - 三态状态机 `running` / `ready` / `missing`，纯读可轮询
  - `launchHidden` 静默拉起 + 100ms × 10s 就绪等待（`Ready` / `Died` / `Timeout`）
  - 复用优先：8765 上已有实例不抢不杀；只有 `gCjhOwned` 的才在退出时收尾
  - 拉起前先收掉自己上一只，避免旧进程占端口导致新实例绑定失败
  - 二进制三级来源：`LINGQU_CJH` → 已部署目录 → 仓内 vendor（4 文件逐个 SHA256）
  - vendor 不可用时按 `LINGQU_CJH_BUNDLE` 的 zip 用系统 bsdtar（绝对路径）解包后拉起
- **三条运维命令**：`t2h:cjh_status` / `t2h:cjh_start` / `t2h:cjh_deploy`；`t2h:quit`（先收引擎再退窗口）
- **生命周期收尾**：守护线程 `waitForExit()` 后收 cjh（新形态 `AppSpec` 无 onExit 钩子），
  收尾跑 5 轮覆盖「用户秒关窗口 + 后台拉起在途」的抢跑
- **单元测试** `src/tests/core_test.cj`：13 例，覆盖 `joinPath` / `firstExisting` / `parsePortEnv` /
  `putEndpoints` / `cjhVendorVerified` 的主路径与边界
- **交付门禁** `scripts/test.ps1`：业务包构建（零警告）+ 单测 + `cj-tauri check` 三方比对 + 骨架构建
- **工程规范文档**：`AGENTS.md`、本 `CHANGELOG.md`、`docs/需求追踪.md`、`docs/进度记录.md`、
  `docs/会话交接.md`、`docs/设计决策记录.md`

### Changed

- 日志落盘：`setLogToDefaultFile("lingqu")` → `%LOCALAPPDATA%\cj-tauri\logs\lingqu.log`
- 启动时在**后台线程**自动 ensure 引擎，不再挡住窗口出现
- 工作台 UI：cjh 从"alive 布尔"改为三态展示；新增「一键部署并启动引擎」「用指定路径启动」「退出」入口
- `cjpm.toml` 补 `[target.x86_64-w64-mingw32]` / `[target.x86_64-unknown-linux-gnu]` 的
  `link-option`（`-lcjtbridge`）——`cjpm test` 的测试可执行文件走业务包自己的链接行

### Fixed

- 加 `LogPlugin` 却没在能力清单声明 `log:path` / `log:write`，被 `cj-tauri check` 三方比对拦下
- `vendor/cjh/win-x64/*.dll` 被模板 `.gitignore` 的 `*.dll` 规则忽略（克隆后 HTTPS 全灭的隐患）

### 验证范围（诚实标注）

- ✅ 编译零警告；`cj-tauri check` 通过；13 例单测全绿；门禁四道闸全绿
- ✅ 退出收尾线程实测触发（日志 `窗口已全部退出，开始收尾`）
- ✅ 仓内 vendor 实测可用：`/api/health` → `{"status":"ok","version":"1.6.1","web_port":8765}`
- ⚠️ 窗口渲染在受限宿主（容器/沙箱）里不可验证：Chromium 起不了子进程 → `0x8000ffff`；
  需在普通桌面会话运行（开发机已验证窗口标题 `灵渠迁移台 · Lingqu`）
- ⚠️ 鸿蒙端 HAP 尚未构建验证

---

## [0.1.1] - 2026-10-28

### Added

- `vendor/cjh/win-x64/`：内置 cjh 产物（`cjh.exe` + 3 个运行时 DLL）+ `SHA256SUMS`
- `tools/vendor-cjh.ps1`：重新灌入 cjh 产物并重算校验
- `scripts/run-dev.ps1`：一条命令配齐运行前提（四段 PATH / 工作目录 / cjh 指向），支持 `-Sync` / `-Build` / `-Cjh`
- `docs/开发环境.md`：环境变量表 + 踩坑索引（按报错原文）

### Fixed

- **`.ps1` 存为 UTF-8 BOM**：Windows PowerShell 5.1 读无 BOM 的脚本按 GBK 解码，
  中文注释会把字符串引号撑坏，报「数组索引表达式丢失或无效 / 字符串缺少终止符」
- `.gitignore` 放行 `vendor/cjh/win-x64/*.dll`（运行时依赖，不是构建产物）
- cjh 版本号纠正：实测 `/api/health` 回报 **1.6.1**（原按 cj-tauri 仓里的 1.5.3 写成）

---

## [0.1.0] - 2026-10-28

### Added

- cj-tauri 2.0 工程骨架：业务包（static）+ `targets/desktop` + `targets/ohos`，`cj-tauri check` 通过
- 七步流程导航（项目 / 画像 / 依赖 / 改造 / 构建 / 验证 / 报告），中栏 + 右栏 Agent Dock
- **环境体检** `t2h:env`：Rust / llvm-mingw / OHOS NDK / DevEco / hvigor / ohpm / hdc / cjh 八项
- cjh 探测与拉起（当时的精简版：TCP 探测 + `launchHidden`）
- 方案文档沉淀：`docs/需求.md`、`docs/产品方案.md`、`docs/技术思路.md`、`docs/ui-mockup.html`
