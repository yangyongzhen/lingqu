# 更新日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的结构，
版本号三处一致：`cjpm.toml` / `cj-tauri.toml` / 本文件最新条目（见 `AGENTS.md` §6）。

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
