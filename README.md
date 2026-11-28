<div align="center">

# 灵渠 · Lingqu

**Tauri 应用 → 鸿蒙 PC 的开箱即用一站式 AI 迁移台**

**开箱即用**——内置 AI 引擎随包分发（SHA256 校验、自动拉起），装上就能用，不用先配一套 agent 运行时；
**全程可视化**——8 屏工作台把每一步的落档、证据与卡点摊在界面上，不必去翻文件猜它走到哪了。

把「照几千字踩坑笔记手工移植一个 Tauri 应用」变成**一条命令 + 一份带证据的迁移报告**；
而且**踩过的坑会自己长成下一轮的规则、指纹与技能**。

[![Release](https://img.shields.io/badge/release-v0.39.130-00868B)](./CHANGELOG.md)
[![Tests](https://img.shields.io/badge/tests-649%20passed-2ea44f)](./scripts/test.sh)
[![Gates](https://img.shields.io/badge/gates-6%2F6%20green-2ea44f)](#-测试与质量)
[![Language](https://img.shields.io/badge/language-Cangjie%20%2F%20Rust%20%2F%20ArkTS-00868B)](https://cangjie-lang.cn)
[![Platform](https://img.shields.io/badge/platform-Windows%20→%20HarmonyOS%20PC-lightgrey)](#-平台与验证范围)
[![License](https://img.shields.io/badge/license-MIT-2ea44f)](./LICENSE)
[![Live Demo](https://img.shields.io/badge/live%20demo-%E5%9C%A8%E7%BA%BF%E9%A2%84%E8%A7%88-6c8cff)](https://yangyongzhen.github.io/lingqu/)

[**🖥 在线预览界面（GitHub Pages）**](https://yangyongzhen.github.io/lingqu/) · [30 秒了解](#-30-秒了解) · [为什么是它](#-为什么是它) · [AI 自动进化飞轮](#-ai-自动进化飞轮本项目的特色) · [截图](#-截图) · [能做什么](#-能力矩阵) · [快速开始](#-快速开始) · [测试与质量](#-测试与质量) · [架构](#-架构) · [命令表](#-命令表) · [文档](#-文档地图) · [路线](#-路线与质量目标) · [**📖 项目介绍**](docs/灵渠%28lingqu%29项目介绍.md)

> 💡 **上面的网页仅为界面演示，不是本项目的形态**：灵渠是**桌面应用**（仓颉 + cj-tauri 外壳）——
> **内嵌智能体、开箱即用**，交付物为**单个可执行文件**（AI 引擎随包，**双击即可运行**，无需安装任何依赖），
> 唯一需要配置的只有**模型 API Key**。

</div>

> **English TL;DR** — Lingqu is a desktop workbench (Cangjie + `cj-tauri` shell, built-in
> [`cjh`](https://atomgit.com/qq8864/cjh) coding-agent engine) that migrates real Tauri apps to
> **HarmonyOS PC**: scan → dependency matrix → rule-based code rewrite → cross-compile → HAP assembly →
> automatic signing (AGC) → `hdc` deploy → on-device verification → risk-graded report.
> **The agent is the worker, the tools are its hands, humans only step in when it asks** (ADR D-015).
> Its distinguishing feature is a **self-evolution flywheel**: the agent writes its own lessons to
> `<project>/.lingqu/notes/`, unknown errors accumulate as normalized signatures in
> `.lingqu/diagnose/misses.jsonl`, and only after human review do they become fingerprints / rules / skills
> that the next run consumes. 649 unit tests, six local gates, MIT.

---

## 📋 项目考核信息

| 项 | 内容 |
|---|---|
| **交付时间** | **2027-02-13** |
| **当前进度** | **85%** |
| **技术基础** | 本项目**站在两个已开源项目之上**，不复刻基础件、聚焦迁移工具链本身：外壳/UI 框架 [**cj-tauri**](https://atomgit.com/qq8864/cj-tauri)（仓颉 + 系统 WebView 的跨端应用框架）与内置 AI 引擎 [**cjh**](https://atomgit.com/qq8864/cjh)（仓颉 Coding Agent Harness，进程外 REST+WS）——两者同为本人开源（MIT），已分别在桌面与鸿蒙真机验证 |
| **最后更新** | 2026-11-24 |

**进度描述**：**0.39.137–0.39.138（最新两轮）**：真机 **Picker 端到端打通**——点「SQLite → 文件路径 → 浏览」真的弹出系统 `DocumentViewPicker`，选完文件回填**沙箱副本**路径（此前卡在 `plugin:dialog|open not allowed by ACL`；根因归到「ACL 在编译期烘进二进制、改完 `capabilities/*.json` 必须强制重跑 build script」这一族，判据已入 `AGENTS.md` §4-209）。0.39.136–0.39.137：dbx 第一次真正**在真机上跑通并看到界面**（期间修掉四连坑：`dirs::data_dir()` 数据目录 EPERM、重复 `main` webview、黑屏的 `defaultPage`×窗口 label 组合、以及 `hdc install -r` 不重启导致"重装了还是旧代码"），`events` 项由真机实测转正（`:memory:` 连接触发 `dbx-connection-liveness`，绿点由事件渲染）⇒ dbx 移植验收 **83%**、报告 **8 步 8/8**；新增**「导出移植成果」**——把迁移后的整个工程冻结到 `%USERPROFILE%\lingqu-migrated\<工程>-<日期>`（附 `MIGRATION.md` 与 `migration-manifest.json`，验收通过自动导一次），解决"成果散落在各样本目录、找不到也不好提交"。项目的外壳框架（cj-tauri）与 AI 引擎（cjh）均为**已开源的成熟底座**（见上），本项目在其上做的是**迁移工具链层**：工程解析（五类清单 + 迁移画像）、Cargo 依赖树 OHOS 兼容性扫描与替代建议、17 条规则改造（幂等可回滚）、交叉编译流水线、HAP 装配、AGC 自动签名、hdc 部署、验证报告与风险分级、断点续迁的 **8 步流水线全部落地**，并经鸿蒙 PC 真机验证；已驱动 AI 引擎完成 **7 个真实 Tauri 应用**的迁移（清单与开源地址见下节），其中 **5 个已各跑出 8 步 8/8**（cc-switch 走手工桥接路线，单独列）；第 **7 个（EcoPaste）**（本轮已整条打通：8 步 8/8、移植验收 85%）此前因模型账号 402 改用**确定性流水线**推进，已到"真机上真的跑起来"。**0.39.116–0.39.123 这八轮的增量**：① 指纹库装上与规则同款的判据（条数 / 编号连续 / 文档双向对齐，漂了就红）；② **crates.io 国内镜像做成默认值**——`R2-PORT-008` 生成的配置自带 rsproxy 稀疏索引，修掉"卡在 Downloading crates 十几分钟"；③ R-2 规则库压力测试**首次真跑**（3 个未归纳样本，盲预测 vs 真实编译，抓到 1 个真 FN 并回填 `R2-DEPS-013`，分母只有 1 所以如实记「未达标」）；④ R-1 飞轮闭环**首次取证**（结论是否定的：`notes` / `diagnose` / `pr` 三个目录全空 ⇒ 机制在位但 agent 不会自己用，下一步改任务书纪律而不是加命令）；⑤ **EcoPaste 在鸿蒙 PC 上第一次真正跑起来**（此前只有"装机 + 启动成功"的假绿），期间修掉 5 处桌面专属 builder 方法、2 个启动期致命坑（`tauri-plugin-log` 的 `LogDir` EPERM、路径 API 返回不可写路径），4 条通用经验已沉淀进 `skills/t2h-ohos-port`。**0.39.131–0.39.134 这四轮的增量**：① **随包 cjh 换血到 1.6.18**（官方发布产物，Windows 侧五件套 SHA256 逐条核对、`/api/health` 实测 1.6.18、单实例 524 ms 拉起），顺带修掉「设备换无线调试后 `probe`/`verify` 拿落档里的旧 USB 序列号跑不动」；② **平台 API 判据沿 helper 追两层**（EcoPaste 的 `app_data_dir → bootstrap_dir` 不再被冤枉成空壳），`tauri_plugin_opener` 接 **ArkTS Want 桥**（`ohos_bridge.rs` + 4 处调用点鸿蒙分支 + `EntryAbility.ets` 分发器，`cargo --target …ohos` 与 hvigor 两道都过）；③ **`events` 判据从"写死 unknown"改成实测通道**（真机切开关取证），并修掉「AI 路径不回投设备口径」导致的"跑完 8 步全绿却说未连接真机"；④ **剪贴板实测定性为平台限制**（`clipboard-rs` 无 ohos 实现；改走桥后 `getChangeCount()` 会涨但 `getDataSync()` 返回 `records=0`；而声明 `READ_PASTEBOARD` 设备直接拒装 `9568289`）⇒ 剪贴板历史这类自动采集在三方应用里做不了，登记 limit；⑤ **移植报告不再"假绿"**——平台能力**实测结论压过静态推断**（`probe.json` 的 `platform:<符号>`）、失败项**原因进报告**、扫描层 `R3-015` 直接给"不可用 + 需授权"的结论；⑥ **R-1 飞轮首次取证**：agent 在真实迁移里**自己写了两条经验**（`notes` 有内容、`trace` 可见 `notes --action append`），监管提醒随之自动消失；`misses.jsonl` 记账机制也已验通（自主发 PR 仍缺 token 未验）。**0.39.100–0.39.105 把「可用率」的口径定死**：分母只认**移植验收项**（ADR **D-020**），原应用自己的业务功能单列冒烟、不判失败——note-gen-2 按此重算为 **83%**（移植项 7：通 5 / 未过 1 / 未测 1），其余样本仍待按同口径重跑复核。剩余 **15%** 为三项验收收尾 + 本轮遗留（任务清单见 [`docs/需求追踪.md`](docs/需求追踪.md) §五）：① **AI 进化飞轮的无人干预闭环实证**——首次取证已证明"机制在位、agent 不会自己用"，下一步是任务书硬纪律与监管提示；② **规则库多样本压力测试**——有效分母仍只有 1，需先过工具链/环境关再复跑冲 Recall ≥80%；③ **鸿蒙原生能力位矩阵补全**——EcoPaste 只验到 onboarding 首页，业务功能未逐项实测，文件选择框一类原生能力仍待逐项真机验证；④ **本轮明确未收口的两件**：`verify` 的 UTF-8 崩溃未根除、真机截图用的是临时复用的签名材料（正式包名需 `sign --login` 自签后重跑）。

---

## 🎯 30 秒了解

| | |
|---|---|
| **是什么** | 一个**桌面工作台**（仓颉外壳 + 8 屏导航 + 右栏 AI 面板），把「把一个真实 Tauri 应用迁到鸿蒙 PC」做成**看得见、可断点、有证据**的流水线 |
| **谁在做迁移** | **内置的 AI agent `cjh`**（进程外 `127.0.0.1:8765`，REST + WS）。我们不替它决定每一步怎么做，只给它**器官**（`t2h:*` 命令、`lingqu-cli`、落档、技能、轮次预算）和**刹车**（预算 / 停滞 / 一键停止） |
| **凭什么叫完成** | **落档说了算**：`.lingqu/<步骤>/<工程>.json` 里的判定字段通过才算通过；退出码 0 不算、AI 说"好了"也不算 |
| **为什么是仓颉** | 外壳（`cj-tauri`）、迁移引擎、AI 引擎（`cjh`）同栈；一个业务包 `src/` 编出桌面与鸿蒙两端产物，没有 Node/Python 运行时依赖 |
| **特色** | **AI 自动进化飞轮**：经验与未命中错误由 agent 自己落盘，攒够次数后由人裁决进指纹 / 规则 / 技能库，下一轮自动吃上（见 [专章](#-ai-自动进化飞轮本项目的特色)，设计细节见 [`docs/AI自进化飞轮.md`](docs/AI自进化飞轮.md)） |
| **特色** | **HAP 包自签名机制（纯仓颉实现，全程摆脱 DevEco Studio）**：本地签名链（纯仓颉 AES-128-GCM 解密口令 + 调用 hap-sign-tool）与 AGC 云生成双路线，`sign --auto` 一条命令 → `signed=true` + 真机装机启动——**迁移的最后一公里不依赖任何重型 IDE，一键到真机跑起来** |
| **现状** | **v0.39.157**：45 个 `t2h:*` 命令 · 24 条 CLI 子命令 · 681 例单测 · 17 条改造规则 · 22 条错误指纹 · 8 步流水线六道门禁全绿；0.39.157 一件（**`autoport --run` 设备离线时不再白烧一轮**）——起跑前过离线闸门（纯函数 `autoPortOfflineGuardOf`）：设备不在线默认拒绝并说清怎么连，真机项因此不会被 `verify` 重新记成 `unknown`（juCang 83%→50% 那次的教训）；确实要离线跑就加 `--allow-offline`；0.39.156 两件（**真机「白屏一闪就退」定位到根因，并把规则补上**）——① 根因是 `app_data_dir()` 的**第二处裸调用**：`R2-PORT-009` 只注入 `resolve_app_data_dir` helper、不改写已有调用，而鸿蒙上裸 `app.data_dir()` **不报错却返回不可写路径** ⇒ 开 SQLite 失败 ⇒ setup 返回 Err ⇒ 进程 abort（`exit with signal:6`），hilog 一行线索都不留；现在规则在"helper 已存在但仍有裸调用"时也落改写（跳过 helper 自身函数体、幂等）；② `R2-PORT-010` 接线顺序改成**先建目录再装 panic hook**（反过来时崩溃那一刻 hook 连日志都写不进去）；真机 A/B：只加窗口 label 仍 abort，改这两处后 `OnPageEnd 200` + 主/render 进程存活；0.39.155 一件（**无界面轮终于有"眼睛"**）——`autoport --run` 真起一轮并把观测落 `.lingqu/agent/cli-run.json`（state/elapsed/tools/lastTool/rounds/verdict）与 `cli-run.log`（cjh 的 stderr 进度原文）；`autoport --status` **只读**回看（绝不重跑），超预算+2 分钟还没终态就说「看起来已中断」（一直显示"跑着"就是 §4-136 那种第三态缺失）；纯函数 `cjhProgressOf` / `cliRunVerdictOf` + 两个单测；顺带修掉**CLI 数值/布尔参数"传了等于没传"**（`--minutes 6` 落成 40、`--max 3` 落成 8）：`argvToJson` 把值存成 `JsonString`，而 `argInt`/`argBool` 只认 `JsInt`/`JsBool` ⇒ 静默回落默认值；新增 `intArgOfText`/`boolArgOfText` 让两种形态都认；0.39.154 两件（**设备离线不许把"没跑"写成"没过"**）——① `deploy` 在"没有可用设备"时照样写落档，把上次真机装启成功的记录盖成 `deviceCount=0/install.ok=false`；现在直接返回 `ok=false` + `recordKept=true` + 下一步提示，**不改写**落档；② `verify` 读那份被盖的档，把 `launch` 判成 **fail（「没装上」）**，实测把 juCang 的 83% 压成 50%；现在 `ChecklistInput.deviceOffline` 由活的 hdc 判定，离线时 `launch` 落 `unknown`（不是失败），并按纯函数 `verdictUnderDeviceOfflineOf` 与上次落档合并：**上次 pass 沿用**（真机证据不丢）、本次 fail 降 unknown（没设备判不了"装不上"），只动 `launch/frontend/events` 三个真机依赖项；0.39.153 一件（**`lingqu-cli autoport` 把"跑一轮迁移"从界面里解耦**）——新增无界面入口：准备现场（装技能 + 写工程 `AGENTS.md` 并把 cjh 工作区切过去）→ 用**同一个** `buildAutoPortDirective` 生成任务书并落盘，回包给出 `directiveChars`/`lessonsDigestItems`/`device`/`promptAscii`/`kickoff`/`runHint`；无界面轮的提示词**强制纯 ASCII**（cjh 把 prompt 当 argv，Windows 上非 ASCII 直接崩，AGENTS §4-119），中文全留在任务书里；界面「一键跑」仍拒（它会起一整轮 agent 并改工程）；0.39.152 一件（**门禁 ③ 的"必红"归因被实测推翻**）——同机同 PATH 下框架 CLI `--version` **30/30 成功**、`sync` **3/3 成功**、`./scripts/test.sh -s` 的 `[0/5] sync` 与 `[3/5] check` 都 PASS ⇒ 它是**偶发**（安全软件拦进程创建那一族），不是"Git Bash 起不来"；`scripts/test.sh` 新增 `run_capture_retry`，只对 `126/127`（根本没起来）重试 3 次并在 PASS 行标注"第 N 次才起来"，命令真跑起来但自己失败仍判红；0.39.151 两件（**真实跑一轮 autoport 抓到两处判据缺陷**）——① 任务书教 agent「每撞一次坑先落经验」那条命令**少写了 `--action append`**，且 `--body-file` 不被识别、`--rule` 压根没实现，于是它落进只读分支、回 `ok:true` 而 `count:0`（**什么都没写却报成功**），`archive --to user` 也因为缺「入库」行永远归档不出东西 ⇒ 用户级经验本永远空；现在 `--body-file` 作别名、`--rule` 写成条目里的「入库：」行、缺 `--action` 却带写入参数时**明确 `ok:false`**；② `hdc list targets -v` 里 **`Offline` 的目标被当成「真机在线」**（真凶是 state 取成了行尾的 `hdc`）⇒ 任务书写「真机在线 ⇒ deploy/verify/probe 都要跑」，现在 `HdcDevice.usable()` 把 `Offline`/`Unauthorized`/`Unknown` 判为不可用，`onlineHdcTargetsOf` 统一供合并/选设备/迁移起始判据使用；另修摘要截断处无标记（`clippedUtf8Of` 截了加「…」）；0.39.150 一件（**已入库经验随任务书下发**）——`~/.lingqu/flywheel/lessons.md` 攒下的经验过去只服务本工程（下个工程从零再撞一遍），现在 `t2h:autoport_start` 每轮把它压成摘要（每条一行「**标题**：修法（入库：FP-021）」，**限 8 条 / 1800 字节**、按完整字符截断以免切坏中文）拼进任务书的「## 已入库经验（跨工程，先看这里）」，没有经验时整节不出现；通道比过技能（≤1.6.18 技能区有上限、超出静默丢弃、按需读）与用户级指纹（只收唯一报错串）都盖不住「形态选择」类经验 ⇒ 只有任务书每轮必读；另加 `lingqu-cli notes --action digest` 回显"任务书会带的那份摘要"，`t2h:autoport_start` 回投 `lessonsDigestItems`/`lessonsDigestChars`/`lessonsSource`；0.39.149 一件（**真机明明连着却被判「没有设备」**）——`liveHdcTargetsText` 原来只跑 `hdc list targets -v`，而它在无线调试下**偶发只列 COM1/COM2 串口噪声**（同一时刻 `hdc list targets` 有 `192.168.3.13:46163`）⇒ 任务书写「真机不在线」⇒ agent 去启模拟器；改为纯函数 `mergeHdcTargetsTextOf`（`-v` 有设备就用 `-v`，否则回落纯列表）+ `LINGQU_DEVICE=<ip:port>` 探测前自动 `hdc tconn`，任务书补**设备优先级：真机 > 模拟器兜底**（用模拟器须标明「非真机」、真机项仍记未测）与「聊天窗口里的地址不会自己生效」；0.39.148 一件（**探针取目标工程改成「等 env 就绪」**）——`LINGQU_UI_PROBE=autoport` 固定 2.6 s 取 `__scanPath`，env 慢就退回「上次工程」（实测把 23,776 字符任务书发给了 dbx 而不是 juCang）；现在等 `__envLoaded` 再定目标，并留 `__probeTargetSrc` 当判据；0.39.147 一件（**随包 cjh 升到 v1.6.24**）——Windows exe 与官方附件逐字节一致（digest `c5372e72…`）、Linux 包内 `cjh-linux-x64` `bbec6eb5…`，`cd vendor/cjh && sha256sum -c SHA256SUMS` 六项全 OK、`--version` = `cjh v1.6.24`、`--mock` 全链 `FINAL-DONE`；**随行 DLL 沿用 1.6.23 那份**（判据：导入表里**没有** runtime/boundscheck、把这四个 DLL 挪走 `--version` 照跑，真正按名字 `LoadLibrary` 的只有 openssl 两件且 1.6.18 起逐字节未变）；上游 1.6.24 的三件正好对着 D-015——**写域封堵**（`task` scope 不再被 bash/MCP/插件绕过、子代理失败不再冒充成功）、**只读工具回合内缓存 + DAG 写域按 glob 判重叠**（省轮次）、**`usage.model_ms`/`tool_ms` 可观测**（判预算花在哪）；0.39.146 两件（**随包 cjh 升到 v1.6.23** + **note-gen 移植版入仓**）——包哈希与官方 `SHA256SUMS-v1.6.23.txt` 对过（win `0a083426…`、linux `1bf6a2d2…`），六个文件的清单与 `src/cjh_host.cj` 常量同步改（`libcangjie-runtime.dll` 也跟着换了），`cd vendor/cjh && sha256sum -c SHA256SUMS` 全 OK；**cjh issue #16 实测已修**——`--web` 模式现在注入 `AGENTS.md`（探针 marker 命中 YES），技能改成**渐进披露**（prompt 只有索引，正文按需 `skill_load`），`/api/skills` 增 `injected`/`reason`、新增热加载 `POST /api/skills/reload` ⇒ 上一轮那条「技能区 6,000 字节上限」**只适用 ≤1.6.18**；同轮把 note-gen 的鸿蒙移植版收进仓 [**qq8864/note-gen-ohos**](https://atomgit.com/qq8864/note-gen-ohos)（8 步 8/8、移植验收 83%、signed HAP 34.8 MB、真机截图在 `ohos/screenshots/`、`.lingqu/` 落档随仓）；0.39.145 一件（**技能改「索引 + 按需读」，并实测出 6,000 字节技能区上限**）——`skills/t2h-ohos-port/SKILL.md` **14,096 → 5,503 字节**（安装件 13,738 → 5,995），细节下沉到 **10 份** `references/`（共 93,643 B，**不进提示词**，按需读）：新增 `device-probe.md`（真机功能自测闭环六步与判定口径）与 `cli-and-selfcheck.md`（`lingqu-cli` 全量命令、中文走文件、`devecocli` 自装与边界）；`description` 改成触发式写法（把"移植到鸿蒙 / 适配 HarmonyOS / 打 HAP / 装真机 / 9568322"写进去）；**实测发现** cjh 的技能区上限约 **6,000 字节**：超出即截断、**排在后面的技能整份丢失**，而 `GET /api/skills` 仍对每份回 `enabled: true`（已回投 cjh issue #16；纪律入 `AGENTS.md` §4-214——短判据进 `SKILL.md`、长细节进 `references/`，否则等于把别人的技能挤掉）；0.39.144 两件（**reference 陈旧有了判据 + 技能指针改可达**）——`references` 是逐份另拷的，而旧判据只比 `SKILL.md` 正文哈希 ⇒ 正文没变时它们会静默陈旧（实测：安装件停在 11-21，`native-ui-bridge.md` 9,576 B vs 仓里 15,818 B、`startup-and-first-screen.md` 整份缺失，而 `t2h:skill status` 一直报 `installed`）；现在逐份比 SHA256，正文一致但任一份缺失/不同即 `outdated` 并点名到文件（重装前 `refDriftCount=4` → 重装后 `installed / 0`，`sha256sum` 独立核对 8 份全 OK）；同时任务书那句「先读技能」原来是**相对路径死链**（agent 的 cwd 是目标工程，实测那目录在样本工作区不存在），改由 `skillRefPointerFor(...)` 生成绝对指向；**上游**：cjh `--web` 模式按源码未把技能正文与 `AGENTS.md` 注进提示词、也没有热加载 ⇒ 已提 cjh issue **#16**，本项目的"新经验"通道因此定在任务书（每轮重下发）+ `.lingqu/notes` 落档；0.39.143 一件（**任务书补「同名 IPC shim」与「ACL 编译期烘死」**）——「原生 UI 能力」同小节加第 6/7 条：前端调的是 `@tauri-apps/plugin-<x>` 而鸿蒙把该插件排除时，必须补**同名插件 shim**（插件名/命令名 + `build.rs` 的 `InlinedPlugin` + capabilities 三处联动，`R2-PORT-017` 会点名）；被 `not allowed by ACL` 拒时别只改 JSON——ACL 是**编译期**烘进二进制的，先核实际窗口 label，再 `touch src-tauri/build.rs` 强制重跑 build script，必要时用 `debug-assertions` 拿三维明细（条款数仍 21，只改文案）；0.39.142 一件（**导出改分块拷贝**）——`copyTreeInto` 从「整文件读进内存」换成 1 MB 缓冲的分块读写（`File(src, OpenMode.Read)` + `File.create(dst)`），46 MB 的 jar 不再是坎；末块边界收成纯函数 `exportWriteLenOf` + 单测；探针兜底上限可配（`LINGQU_EXPORT_PROBE_MS`）并实测到超时分支；**实跑读数**：`exportOk=true / 8683 文件 / 257,526,499 字节`（此前每次卡在 913），15 秒上限那条给出「导出超过 15 秒仍未结束」；0.39.141 一件（**任务书补「平台 API 降级落地」**）——`directiveClauses` 20 → **21**：先把"空壳"定义写死（`Ok(None)`/`Some(None)`/`return None`/`todo!()`/返桌面路径都算没落地），再给 dbx 实测那 10 类的**逐条落法**（沙箱根 `files`、`temp_dir`→`files/tmp`、`Command` 能不用就不用、`opener` 走 Want 桥且沙箱目录三方打不开→登记 limit、`clipboard` 自动采集登记 limit），最后给复验判据（改完必须 `verify` 复跑到 `platform-api` 的 `verdict` 变 `pass`/`limit`；`probe.json` 的 `platform:<符号>` 压过静态推断；不许删条目——那会改分母，D-020）；`docs/任务书规范.md` §3 同步；**这条按 D-015 只补说明书、不代写样本代码**；0.39.140 一件（**导出改后台任务**）——`t2h:export` 只起后台线程立刻返回，新增只读命令 `t2h:export_status`（`running/done/exportFiles/exportBytes/current/idleSecs/verdict/exportErr`，绝不重跑导出），拷前拷后各回投一次进度，停滞判据是纯函数 `exportStallVerdictOf`（60 秒无新文件 ⇒ `stalled`）；复验：界面不再无限转圈，而是**点名到文件**的失败（`当前停在 agents/drivers/transwarp/libs/inceptor-sdk-transwarp-6.1.0-SNAPSHOT.jar`，913 个 / 19,873,115 字节）⇒ 根因收窄到「应用进程里整文件读进内存」这条路（同工程 CLI 拷同一文件无事）；**未修**：改分块流式拷贝后才可能拿到 `exportOk=true`（`AGENTS.md` §4-211）；0.39.139 一件（**⑦ 屏导出装上探针**）——`LINGQU_UI_PROBE=export` 进 ⑦ 屏点按钮、轮询结果（上限 5 分钟）并回投 `export-final`/`export-timeout`，`ui_report` 增 `exportOk/exportTries/exportFiles/exportBytes/exportDir/exportErr`（前后端两处一起加）；**探针第一轮就抓到真缺陷**：经 IPC 的导出卡在 **913 个文件 / 21 MB** 不再前进、promise 永不 settle（目标换到 E: 盘一样卡；同工程 CLI 却成功 8683 文件 / 257 MB）⇒ 待改成后台线程 + 进度回投（`AGENTS.md` §4-211）；0.39.138 一件（**真机 Picker 打通**，只改文档）——dbx 整份重编（45m48s、`libdbx_lib.so` 97,314,840 B）→ signed HAP 99,631,380 B → 无线真机部署 → `aa force-stop`+`aa start`（pid 56227 → 57095）→ 点「浏览」弹出系统 `DocumentViewPicker`（版面 bundle 变 `com.huawei.hmos.filemanager`）→「已选 (1/1)」→「打开」→ 应用「文件路径」回填 `/data/storage/el2/base/haps/entry/files/imported/<文件名>`；**归因未坐实**（按 tauri 源码 `platforms: ["openHarmony"]` 本该生效，更可能是编译期 ACL 没刷新），已入 `AGENTS.md` §4-209；0.39.137 一件（**导出移植成果**）——`lingqu-cli export` / `t2h:export` / ⑦ 报告屏按钮三条入口把迁移后的整个工程复制到 `%USERPROFILE%\lingqu-migrated\<工程>-<日期>-<序号>`（`LINGQU_MIGRATED_DIR` 可覆盖），排除 `node_modules/target/dist/oh_modules/.git/.lingqu`、`gen/ohos/entry/libs|build`、`.so|.hap|.dll|.exe` 等产物，附 `MIGRATION.md`（怎么 build/hap/sign/deploy/verify）与 `migration-manifest.json`，落 `.lingqu/export/<工程>.json`；**验收通过（无 fail）时自动导一次**；dbx 冒烟实测 8683 个文件 / 257 MB / 跳过 32 条 / `verifyRate=83`；0.39.136 三件（**dbx 首次推到真机**）——**前端指纹闸两处假红修掉**（`.so` 里的前端键是合并字符串池、相邻两条常常没有 NUL：粘连会造出假 `stale`、键后粘着别处正文会造成假 `missing`；改按 `assets/` 切段 + 段内取最长扩展名截断 ⇒ `matched=599 / stale=0 / missing=0`）；**`crate::dialog` 的 ArkTS Picker 半边补齐**（`DocumentViewPicker` 异步 ⇒ 形态 B：ArkTS 先回 `{pending}`、选完写一次性文件、Rust 100 ms 轮询；选文件回**沙箱副本**路径、目录非 2in1 如实 `ok:false`）；**「自动签成功却判没过」修掉**（`sign --auto` 落档没有 `check` 段，新增 `signStepOkOf` 认三种出口）⇒ dbx **8 步 8/8**、移植验收 **80%**；**真机「起来即崩」已定性**（`panic=abort` + panic hook 从未安装导致零线索；补早期 hook 后一次取到真因 `Failed to prepare app data dir: PermissionDenied`——`dirs::data_dir()` 在鸿蒙是桌面口径路径、`create_dir_all` EPERM），**已修复并复验**（进程 + `:render` 进程存活、`#FOREGROUND`、截图为 DBX 真实「新建连接」界面）；并逐轮修掉随之暴露的**黑屏**（`defaultPage` × 窗口 label 是一对相互牵制的开关：`defaultPage:false` ⇒ `SetUIContent timeout` 停在启动占位；label 用默认 `main` ⇒ 与 ability 默认页撞车 `a webview with label 'main' already exists`；最终取 `defaultPage:true` + label `dbx-main`）；0.39.135 两件（**dbx 攻坚：交叉编译打通**）——**GTK 链真凶是 `tao` 不是 wry**（`glib-sys ← atk ← gtk ← tao ← tauri-runtime-wry(fork)`，且 `[patch]` 写在 workspace 成员会被 cargo 完全忽略，必须挪到根 + `tauri×7`/`wry`/`tao` 三样一并 patch）；桌面专属依赖逐个摘出鸿蒙（**openssl→rustls、secret-service、rfd→系统 Picker 抽象层、tray/menu、updater、window-state、deep-link**）⇒ `libdbx_lib.so` **97 MB** 产出、`t2h:build` 修复两处假红（加 `--lib` 只编 cdylib；**尊重工程 `build.target-dir`**，`.so` 定位与产物闸同口径）；0.39.134 三件（**移植报告不再"假绿"**）——平台能力的**实测结论压过静态推断**（`probe.json` 的 `platform:<符号>`，剪贴板桥"写了代码"不再自动算通过）、**失败项原因进报告**（正文直接写「实测原因：…clipboard-rs…」）、扫描层 `R3-015` 文案同步成最终结论（**不可用 + 需 `READ_PASTEBOARD` + `9568289`**）⇒ **EcoPaste 可用率 100% → 85%（6/7）**，如实暴露"剪贴板历史在鸿蒙三方应用做不了"；0.39.133 四件——`events` 判据从"写死 unknown"改成**实测通道**（真机切开关取证）、AI 路径补**设备口径**（不再出现"跑完 8 步全绿却说未连接真机"）、**路径类 API 进扫描分母**（`app_log_dir`/`app_local_data_dir` 等）+ `cfg!` 宏形态入判据、真机证伪「沙箱目录能被文件管理器打开」（三条路：被 WPS 接走 / 仍给 WPS / 弹"暂无可用打开方式"）⇒ 改为如实提示路径并登记 limit；0.39.132 两件——**平台 API 判据沿 helper 追两层**（EcoPaste 的 `app_data_dir → bootstrap_dir` 间接落地不再被冤枉成空壳：platform-api 从「5 处 / 2 处空壳」变 limit，移植验收 **66% → 80%**）与 **`tauri_plugin_opener` 接 ArkTS Want 桥**（`ohos_bridge.rs` + 4 处调用点鸿蒙分支 + `EntryAbility.ets` 分发器，`cargo --target …ohos` 与 hvigor 两道都过）；0.39.131 两件——**随包 cjh 1.6.18**（官方发布产物换血，Windows 侧五件套 SHA256 逐条核对、`--version` 与 `/api/health` 实测 `1.6.18`、引擎单实例 524 ms 拉起）与**真机设备键修复**（设备换无线调试后 `probe`/`verify` 拿落档里的 USB 序列号跑不动，现以在线目标为准；修后 `probe` 实测 7 pass / 0 fail / 1 unknown、采证截图真实落盘）；0.39.130 三件——**随包 cjh 1.6.13**（MCP Streamable HTTP 传输，本仓 PR #13 已合入上游）并**接入华为开发者知识库**（agent 会话内实调 `searchDocuments`/`getDocumentsById` 检索鸿蒙官方文档闭环）、任务书新增「**插件不满足：三层适配优先于降级**」与「**鸿蒙知识库优先于记忆**」两条纪律（外部反馈采纳）、技能补 `plugin-adaptation.md` 配方清单（实测 4/推断 6/limit 4）；0.39.129 在 Linux 侧补三件——`app_data_dir` 判据**沿 helper 追一层**（0.39.128 唯一没修的判据缺陷，EcoPaste 假 fail 的另一半）、`R2-DEPS-015` 回填 CMake 系 C 依赖（`aws-lc-sys`）、R-1 监管态提醒（连撞 ≥2 步而 notes 空时界面说出来）——并适配框架 2.4.0 的 `readBytes` 接口；0.39.120 **R-1 零干预轮首次实跑取证：三个验证点全部未达成**（EcoPaste 26 轮后因模型账号 402 余额不足终止，八步停 3/8；`notes`/`diagnose`/`pr` 三个目录全空 ⇒ 机制在位但 agent 不会自己用），如实记档不修口径；0.39.119 把「国内直连 crates.io 卡死」沉淀成**默认镜像**（`R2-PORT-008` 生成的配置带 rsproxy）+ 指纹 `FP-024`；0.39.118 把 PR 提交凭据改成**多源探测**（`LINGQU_GITCODE_TOKEN` / `GITCODE_TOKEN` / `ATOMGIT_TOKEN` / `GH_TOKEN` 任一），探测不到时**不再静默退化**、当场给出三条可操作的开启路径（含"不授权也能自己提"）；0.39.117 **首次真跑 R-2 规则库压力测试**（3 个未归纳样本：盲跑 `deps` 出预测 → 真实交叉编译对照）：抓到 1 个真 FN（`libdbus-sys`，已回填新规则 `R2-DEPS-013` 并补 FP-016 归因），另 2 个样本卡在环境关（样本自带的过期 SDK 路径、C 依赖缺 target CC）⇒ **crate 级分母只有 1，Recall 0/1，如实记为未达标**；0.39.116 给指纹库装上与规则同款的判据——保留空位（`FP-008/009`）下的编号连续、marker 不撞车、`rule` 档必须指向已登记的 `R2-PORT-*`、四份现状文档的条数与编号**双向**对齐（文档引用不存在的编号也红），`docs/需求追踪.md` 里陈旧的两处指纹条数因此被当场纠正；0.39.115 把「17 条改造规则到底是哪 17 条」收成**单点清单**（`src/port/rules.cj`）并用读真实源码/文档的单测钉住——条数或编号一旦漂就红；**已按 A4 新口径（只数移植项）重跑**：habit-tree **100%**（5 项：通 4 / 免判 1）· m3u8dl-tauri **100%**（5 项：通 4 / 免判 1）· rust-music-3 **80%**（历史落档 6 项：通 4 / 未过 1 / 未测 1；样本源码已不在本机）· note-gen-2 **83%**；三个样本那 1 条失败同源——命中的平台 API 在 `#[cfg(target_env="ohos")]` 分支里是 `Ok(None)` 空壳，属**待落地的降级项**。0.39.106 修掉一处让样本"分数虚高"的假绿：扫描器只认 `src-tauri/`，扁平布局工程（rust-music-3）五类清单恒为 0 ⇒ 分母缩成 3 项、可用率算成 100%；0.39.90 补了「后端已停止响应」的自检与提示；0.39.91 修掉三处**工具自身**的假红/假绿：指纹闸只认 `assets/` 布局、`ohpm.bat` 在 Windows 上不能直启、轮次预算只改内存不落文件；0.39.92 打通整条真机链路（`sign --auto` → signed HAP → 装机启动 → verify 100%），并补上「命令做成了却不落档」这处假失败；0.39.94 新增 `probe`——agent 自己在真机上**点一下再判定**功能可用性（`dumpLayout → 按文本取 bounds 中心 → uiInput click → 再 dump 比对 → 截图 → 写 probe.json`），技能与任务书同步教会它；0.39.95 修掉环境体检的两处**假缺失**——`hdc` 走了已过期的 `DEVECO_SDK_HOME`、`llvm-mingw` 只认一条写死路径，现在按「真的能跑到」判；0.39.96–0.39.98 让 agent 干完的活**上得了屏**：①②⑤⑥⑦ 五屏进屏按落档回读（纯读盘、不重跑），监管态补第三态「**已交接**」；0.39.100 修掉「`.so` 就在盘上却报没产出」的产物闸假红（现在期望产物名优先，note-gen-2 的 ⑤ 构建第一次整条通过）；0.39.104–0.39.105 修 ⑥ 验证屏的分类与折叠：`smoke` 项不再混进移植主行（主行 9 → 7），摘要与 note 同源统计 |平台能力的**实测结论压过静态推断**（`probe.json` 的 `platform:<符号>`，剪贴板桥"写了代码"不再自动算通过）、**失败项原因进报告**（正文直接写「实测原因：…clipboard-rs…」）、扫描层 `R3-015` 文案同步成最终结论（**不可用 + 需 `READ_PASTEBOARD` + `9568289`**）⇒ **EcoPaste 可用率 100% → 85%（6/7）**，如实暴露"剪贴板历史在鸿蒙三方应用做不了"；0.39.133 四件——`events` 判据从"写死 unknown"改成**实测通道**（真机切开关取证）、AI 路径补**设备口径**（不再出现"跑完 8 步全绿却说未连接真机"）、**路径类 API 进扫描分母**（`app_log_dir`/`app_local_data_dir` 等）+ `cfg!` 宏形态入判据、真机证伪「沙箱目录能被文件管理器打开」（三条路：被 WPS 接走 / 仍给 WPS / 弹"暂无可用打开方式"）⇒ 改为如实提示路径并登记 limit；0.39.132 两件——**平台 API 判据沿 helper 追两层**（EcoPaste 的 `app_data_dir → bootstrap_dir` 间接落地不再被冤枉成空壳：platform-api 从「5 处 / 2 处空壳」变 limit，移植验收 **66% → 80%**）与 **`tauri_plugin_opener` 接 ArkTS Want 桥**（`ohos_bridge.rs` + 4 处调用点鸿蒙分支 + `EntryAbility.ets` 分发器，`cargo --target …ohos` 与 hvigor 两道都过）；0.39.131 两件——**随包 cjh 1.6.18**（官方发布产物换血，Windows 侧五件套 SHA256 逐条核对、`--version` 与 `/api/health` 实测 `1.6.18`、引擎单实例 524 ms 拉起）与**真机设备键修复**（设备换无线调试后 `probe`/`verify` 拿落档里的 USB 序列号跑不动，现以在线目标为准；修后 `probe` 实测 7 pass / 0 fail / 1 unknown、采证截图真实落盘）；0.39.130 三件——**随包 cjh 1.6.13**（MCP Streamable HTTP 传输，本仓 PR #13 已合入上游）并**接入华为开发者知识库**（agent 会话内实调 `searchDocuments`/`getDocumentsById` 检索鸿蒙官方文档闭环）、任务书新增「**插件不满足：三层适配优先于降级**」与「**鸿蒙知识库优先于记忆**」两条纪律（外部反馈采纳）、技能补 `plugin-adaptation.md` 配方清单（实测 4/推断 6/limit 4）；0.39.129 在 Linux 侧补三件——`app_data_dir` 判据**沿 helper 追一层**（0.39.128 唯一没修的判据缺陷，EcoPaste 假 fail 的另一半）、`R2-DEPS-015` 回填 CMake 系 C 依赖（`aws-lc-sys`）、R-1 监管态提醒（连撞 ≥2 步而 notes 空时界面说出来）——并适配框架 2.4.0 的 `readBytes` 接口；0.39.120 **R-1 零干预轮首次实跑取证：三个验证点全部未达成**（EcoPaste 26 轮后因模型账号 402 余额不足终止，八步停 3/8；`notes`/`diagnose`/`pr` 三个目录全空 ⇒ 机制在位但 agent 不会自己用），如实记档不修口径；0.39.119 把「国内直连 crates.io 卡死」沉淀成**默认镜像**（`R2-PORT-008` 生成的配置带 rsproxy）+ 指纹 `FP-024`；0.39.118 把 PR 提交凭据改成**多源探测**（`LINGQU_GITCODE_TOKEN` / `GITCODE_TOKEN` / `ATOMGIT_TOKEN` / `GH_TOKEN` 任一），探测不到时**不再静默退化**、当场给出三条可操作的开启路径（含"不授权也能自己提"）；0.39.117 **首次真跑 R-2 规则库压力测试**（3 个未归纳样本：盲跑 `deps` 出预测 → 真实交叉编译对照）：抓到 1 个真 FN（`libdbus-sys`，已回填新规则 `R2-DEPS-013` 并补 FP-016 归因），另 2 个样本卡在环境关（样本自带的过期 SDK 路径、C 依赖缺 target CC）⇒ **crate 级分母只有 1，Recall 0/1，如实记为未达标**；0.39.116 给指纹库装上与规则同款的判据——保留空位（`FP-008/009`）下的编号连续、marker 不撞车、`rule` 档必须指向已登记的 `R2-PORT-*`、四份现状文档的条数与编号**双向**对齐（文档引用不存在的编号也红），`docs/需求追踪.md` 里陈旧的两处指纹条数因此被当场纠正；0.39.115 把「17 条改造规则到底是哪 17 条」收成**单点清单**（`src/port/rules.cj`）并用读真实源码/文档的单测钉住——条数或编号一旦漂就红；**已按 A4 新口径（只数移植项）重跑**：habit-tree **100%**（5 项：通 4 / 免判 1）· m3u8dl-tauri **100%**（5 项：通 4 / 免判 1）· rust-music-3 **80%**（历史落档 6 项：通 4 / 未过 1 / 未测 1；样本源码已不在本机）· note-gen-2 **83%**；三个样本那 1 条失败同源——命中的平台 API 在 `#[cfg(target_env="ohos")]` 分支里是 `Ok(None)` 空壳，属**待落地的降级项**。0.39.106 修掉一处让样本"分数虚高"的假绿：扫描器只认 `src-tauri/`，扁平布局工程（rust-music-3）五类清单恒为 0 ⇒ 分母缩成 3 项、可用率算成 100%；0.39.90 补了「后端已停止响应」的自检与提示；0.39.91 修掉三处**工具自身**的假红/假绿：指纹闸只认 `assets/` 布局、`ohpm.bat` 在 Windows 上不能直启、轮次预算只改内存不落文件；0.39.92 打通整条真机链路（`sign --auto` → signed HAP → 装机启动 → verify 100%），并补上「命令做成了却不落档」这处假失败；0.39.94 新增 `probe`——agent 自己在真机上**点一下再判定**功能可用性（`dumpLayout → 按文本取 bounds 中心 → uiInput click → 再 dump 比对 → 截图 → 写 probe.json`），技能与任务书同步教会它；0.39.95 修掉环境体检的两处**假缺失**——`hdc` 走了已过期的 `DEVECO_SDK_HOME`、`llvm-mingw` 只认一条写死路径，现在按「真的能跑到」判；0.39.96–0.39.98 让 agent 干完的活**上得了屏**：①②⑤⑥⑦ 五屏进屏按落档回读（纯读盘、不重跑），监管态补第三态「**已交接**」；0.39.100 修掉「`.so` 就在盘上却报没产出」的产物闸假红（现在期望产物名优先，note-gen-2 的 ⑤ 构建第一次整条通过）；0.39.104–0.39.105 修 ⑥ 验证屏的分类与折叠：`smoke` 项不再混进移植主行（主行 9 → 7），摘要与 note 同源统计 |0.39.90 补了「后端已停止响应」的自检与提示；0.39.91 修掉三处**工具自身**的假红/假绿：指纹闸只认 `assets/` 布局、`ohpm.bat` 在 Windows 上不能直启、轮次预算只改内存不落文件；0.39.92 打通整条真机链路（`sign --auto` → signed HAP → 装机启动 → verify 100%），并补上「命令做成了却不落档」这处假失败；0.39.94 新增 `probe`——agent 自己在真机上**点一下再判定**功能可用性（`dumpLayout → 按文本取 bounds 中心 → uiInput click → 再 dump 比对 → 截图 → 写 probe.json`），技能与任务书同步教会它；0.39.95 修掉环境体检的两处**假缺失**——`hdc` 走了已过期的 `DEVECO_SDK_HOME`、`llvm-mingw` 只认一条写死路径，现在按「真的能跑到」判（复用 `hdcPathOr()`、按 PATH + 版本化目录找 clang），每项标出**影响哪一步**，不适用当前宿主机的项不再展示；0.39.96–0.39.97 让 agent 干完的活**上得了屏**：① 迁移画像 / ② 依赖扫描 / ⑤ 构建 / ⑥ 验证四屏进屏按落档回读（纯读盘、不重跑），监管态补第三态「**已交接**」——agent 自己收尾时不再显示成「进行中」；0.39.98 给 ⑦ 迁移报告屏补上同一条回读通道（`t2h:report {action:"load"}`），`ui_report` 可用 `reportLoaded/reportSource` 断言「屏上的数字来自落档」；**0.39.100** 修掉一处让整步功亏一篑的**假红**：`.so` 明明就在盘上（33 MB、刚编出来的），产物闸却报「没产出 `libtauri_app_lib.so`」——cargo 的 artifact 列表里 deps 的 hash 中间产物排在前面，旧实现取「第一个 `.so`」拼出了不存在的路径；现在**期望产物名优先**（`lib<name>.so` 即 HAP 真正加载的那个），note-gen-2 的 ⑤ 构建**第一次整条通过**（`assetDiff.matched=12`，此前一个前端键都没比上） |

---

## 💡 为什么是它

把灵渠和「拿一堆散装脚本/技能包 + 让 AI 现场发挥」的路线放在一起比，差异不在单个功能，而在**形态**：

| | 传统「技能包 / 散装 CLI」路线 | **灵渠** |
|---|---|---|
| **感知全景** | 雁过不留痕：技能是静态文档，agent 撞了什么坑、走到哪一步、哪步卡住——散落在会话与日志里，**没有一处能看到移植的全貌** | **8 步流水线全程落档**（`.lingqu/<步骤>/<工程>.json`）：迁移画像（五类清单 + 评分 + C1/C2/C3）、依赖矩阵、改造 diff、构建闸门、真机证据——**每一步都看得见、可断点、可回滚** |
| **生命周期** | 一次会话 = 一次搬运：会话关了，上下文就没了；换个应用、隔两周再回来，从零开始 | **断点续迁 + 任务状态机**：工程停在哪一步、哪些过了哪些没过，落档说了算；随时接着跑 |
| **迁移质量** | 「跑完了」≈「能用了」：退出码 0 就算成功，白屏、旧 .so、假安装都发现不了 | **落档说了算 + 六项门禁 + 真机证据链**：判定字段写进 JSON 才算通过；真机截图 / hilog / dumpLayout 四段判据，报告里「100%」和「尚未验证」不会打架。遇到鸿蒙侧没有的插件 API，任务书写死**三层适配优先于降级**（wry/tao fork 差异层 → 平台条件编译 → API 映射到 ArkWeb/系统能力）——降级是最后手段且必须登记，静默砍功能算移植失败 |
| **知识底座** | agent 靠模型记忆答鸿蒙 API 语义：训练数据旧了就猜错，猜错就白烧一轮交叉编译 | **内置华为开发者知识库**（cjh 1.6.13 起支持 MCP Streamable HTTP 传输，**随包现为 v1.6.24**；`searchDocuments`/`getDocumentsById`）：任务书写死"何时该查、结论带出处"——agent 先检索鸿蒙官方 RAG 再动手，答 API 语义注明来源文档 |
| **经验沉淀** | 技能包靠人写人维护：写完就旧，AI 撞到新坑也无法自行记账；**雁过不留痕** | **AI 自动进化飞轮**：agent 自己写经验（四段式）、机器攒未命中证据、人只做裁决——指纹 / 规则 / 技能**从真实迁移里长出来**，下一个应用自动吃上 |
| **上手成本** | 用户自己装环境、找技能、配 prompt、拼 CLI：工具越好用，前置功课越多 | **开箱即一台完整工作台**：内置 AI 引擎（cjh 随包分发、SHA256 校验、自动拉起），43 个 `t2h:*` 命令 + 22 条 CLI 子命令开箱即用；一条 `migrate` 从源码到真机 |
| **谁来干活** | 人写 prompt 驱动 AI，AI 每一步都要人盯着 | **agent 是执行者，工具是它的手**（ADR D-015）：任务书交出去，AI 自己跑流水线；停滞/超预算才叫人，人工介入逐次记录（验收 A3 ≤5 处的口径） |

一句话：**技能包给 AI 一本攻略书，灵渠给 AI 一条带闸门的流水线和一个会自己写攻略的大脑。**

攻略书会过时，流水线不会——每迁一个应用，流水线上的证据都沉淀进飞轮，这正是
[AI 自动进化飞轮](#-ai-自动进化飞轮本项目的特色)那章所描述的机制。

**追问：为什么不做成命令行或纯 skills 形式？**（命令面我们其实保留了——`lingqu-cli` 20 条
子命令就是给 AI 用的；这里回答的是"给人的形态"为什么是桌面可执行工具）

- **纯 skills 通用但雁过不留痕**：技能是静态文档，迁移走到哪一步、哪步卡住、撞了什么坑，
  全部散在会话与日志里——**感知不到移植的全貌与生命周期**；而且用户要自己挑 agent、装
  环境、找技能、配集成，**碎片化**程度高，知识技能的沉淀复用也基本靠人维护；
- **纯 CLI 对人不够友好**：证据要自己翻 `.lingqu/` 下的落档文件，流水线全景、断点状态、
  风险分级没有一眼可见的地方；
- **桌面可执行工具把这层全包了**：**使用简单、功能全面**——8 屏导航感知全景与生命周期、
  **内置智能体（cjh），开箱配置好密钥即可用**（SHA256 校验 + 自动拉起，无需装运行时）、
  落档即证据、六项门禁、断点续迁、**数据飞轮进化机制内建**；CLI 面仍在（给 AI 与自动化），
  但人面对的是工作台，不是一堆命令。

顺带说明：**skills 本项目也有**——[`skills/t2h-ohos-port/`](skills/t2h-ohos-port/SKILL.md)
（SKILL.md + 5 篇 references）就是给 agent 的移植技能，飞轮回流通道会把它装进 agent 的
技能库；只是 skills 之上还有**可视化工作台、迁移画像、依赖扫描矩阵、六项门禁与数据飞轮**
这些 skills 本身做不到的层——**工具是"skills + 工程 + 可视化 + 飞轮"的整体**，缺哪层
"雁过留痕"都不成立。

---

## 🧩 已验证的迁移样本（上游开源地址）

灵渠不拿玩具工程充数——下面这些都是**真实开源 Tauri 应用**，已经迁到鸿蒙 PC 上装得上、起得来、界面出得来，
每一条都挂可复查的证据（`.lingqu/<步骤>/<工程>.json` 落档 + 真机截图 + 迁移报告）。

| 样本（上游开源地址） | 是什么 | 鸿蒙侧成果 / 迁移方式 | 验证到哪一步 |
|---|---|---|---|
| **[cc-switch](https://github.com/farion1231/cc-switch)** | Claude Code / Codex / Gemini CLI 的 All-in-One 配置管理器（Tauri v2 + React），社区热门项目 | 移植版开源：[**qq8864/cc-switch-harmonyos**](https://atomgit.com/qq8864/cc-switch-harmonyos)——Rust 交叉编译出 `libcc_switch_lib.so`，napi-ohos 桥接 + ArkWeb 渲染原版 React 前端，**前端零框架改动** | 真机装机 + 启动 + 界面可用（HAP）；走的是**手工桥接路线**，未跑 8 步流水线，故无 `verify` 落档（不计入 A4） |
| **[note-gen](https://github.com/codexu/note-gen)** | AI 笔记 / 写作工具（Tauri v2 + Next.js），GitHub 热门项目 | 移植版开源：[**qq8864/note-gen-ohos**](https://atomgit.com/qq8864/note-gen-ohos)（含真机截图 `ohos/screenshots/` 与 `.lingqu/` 落档）；灵渠 8 步流水线全流程驱动 | **8 步 8/8**；移植验收 **83%**（移植项 7：通 5 / 未过 1 / 未测 1）；原应用业务功能 180 条单列冒烟不计入；人工介入 0 处 |
| **[habit-tree](https://atomgit.com/qq8864/habit-tree)** | 习惯养成打卡（Tauri 2 + redb 本地库） | 移植版开源：[**qq8864/habit-tree**](https://atomgit.com/qq8864/habit-tree)（仓内 `shots/` 有真机截图） | 8 步 **8/8**；按 A4 新口径（只数移植项）**100%**——移植 5 项：通 4 / 免判 1（4 处平台 API 已全部落地，`open_url` 走 NAPI 桥投 Want）/ 未测 0；真机截图 + hilog 证据齐全；0 处人工介入 |
| **[m3u8dl-tauri](https://atomgit.com/qq8864/m3u8dl-tauri)** | m3u8 视频下载器（Tauri 2 + 子进程编排） | 源码镜像：[**qq8864/m3u8dl-tauri**](https://atomgit.com/qq8864/m3u8dl-tauri)；移植版（含 `.lingqu/` 落档）：[**qq8864/m3u8dl-tauri-ohos**](https://atomgit.com/qq8864/m3u8dl-tauri-ohos) | 8 步 **8/8**、真实 HAP 装机启动；按 A4 新口径 **100%**——移植 5 项：通 4 / 免判 1（「选择文件 / 保存目录」已接 NAPI 桥 + ArkTS `DocumentViewPicker`，桌面侧仍 `rfd::FileDialog`；`temp_dir` 已改为沙箱 `files/tmp`；真机选目录/选文件待下次设备在线复验）；此前「核心功能 40%」含原应用业务功能，不再作为 A4 依据 |
| **[rust-music](https://atomgit.com/qq8864/rust-music)** | 音乐播放器（Rust + Tauri 2，对齐 cj-tauri `examples/music`） | 源码镜像：[**qq8864/rust-music**](https://atomgit.com/qq8864/rust-music) | 8 步 **8/8**、真机起得来；按 A4 新口径 **80%**——移植 6 项：通 4 / 未过 1（2 处平台 API 无落地降级）/ 未测 1（events 未逐条触发）。0.39.106 修掉扫描器「只认 `src-tauri/`」导致该扁平布局工程清单恒为 0、分母缩成 3 项虚高成 100% 的假绿 |
| **[juCang / 聚藏](https://atomgit.com/qq8864/juCang)** | 收藏聚合阅读器（Tauri 2 + React 19，本地优先） | 源码镜像：[**qq8864/juCang**](https://atomgit.com/qq8864/juCang) | 装配链打通（HAP 34 MB 出包、真机启动）；旧口径 **85%**，`events` 项待真机实测 |
| **[EcoPaste](https://github.com/EcoPasteHub/EcoPaste)** | 跨平台剪贴板管理工具（Tauri 2 + Vue，7.6k★） | 移植版开源：[**qq8864/ecopaste-ohos**](https://atomgit.com/qq8864/ecopaste-ohos)（含真机截图与 `.lingqu/` 落档）；**`sign --auto` 正式自签**（`auto_debug_…`，profile 含本机 UDID）→ `libeco_paste_lib.so` 交叉编译 → HAP 装配 → 真机装机启动 | **8 步 8/8**、真机进程常驻 + 前台是本应用、onboarding 6/6 → 主界面正常渲染；移植验收 **85%**（移植项 7：通 6 / 未过 1）——那 1 项是 `platform-api`：**剪贴板在鸿蒙三方应用不可用**（`getDataSync()` 返回 `records=0`，声明 `READ_PASTEBOARD` 则设备拒装 `9568289`），属平台限制、报告如实计为未通过；业务功能（剪贴板历史）不在移植分母，风险段单独写明 |

> **口径说明**：通过率只数**移植验收项**（装得上 / 起得来 / 渲染得出 / 前端资源进包 / IPC 与事件通道 / 平台能力有落地等价物）；
> 原应用自己的业务功能只作冒烟记录、**不判失败**——理由见 [`docs/设计决策记录.md`](docs/设计决策记录.md) ADR **D-020**，
> 逐项状态见 [`docs/需求追踪.md`](docs/需求追踪.md)。

### 🏷 移植版仓库（工程源码 + 真机截图 + `.lingqu/` 落档）

迁移成功的工程都不止留在本机工作区——**单独建了仓**，仓里 README 写明工程路径、改动清单、
构建/签名/部署步骤与验收读数，`docs/ohos/` 有真机截图，**`.lingqu/` 迁移落档也随仓提交**
（各步判定 JSON + 取证截图），拿到仓就能对着落档复核"哪一步验到哪"。

| 样本 | 移植版仓库 | 验收读数 | 仓内真机截图 |
|---|---|---|---|
| **DBX** | [**qq8864/dbx-ohos**](https://atomgit.com/qq8864/dbx-ohos) | 移植验收 **83%** · signed HAP **99.6 MB** · 8 步 **8/8** | 新建连接 / 插件中心 / 系统文件选择（Picker 端到端回填沙箱路径） |
| **EcoPaste** | [**qq8864/ecopaste-ohos**](https://atomgit.com/qq8864/ecopaste-ohos) | 移植验收 **85%**（`platform-api` 登记 platform limit）· signed HAP **21.7 MB** | onboarding 首页 / 「Open」走 Want 打开系统浏览器 |
| **N_m3u8DL-Tauri** | [**qq8864/m3u8dl-tauri-ohos**](https://atomgit.com/qq8864/m3u8dl-tauri-ohos) | HAP **8,664,788 B**、`errorCount=0`；**未签名 ⇒ 真机未取证**（如实标注） | 待补（仓内 README 已写明缺什么、怎么复现） |
| **habit-tree** | [**qq8864/habit-tree**](https://atomgit.com/qq8864/habit-tree) | 移植验收 **100%**（移植 5 项：通 4 / 免判 1）· 8 步 **8/8** · 人工介入 **0** 处 | `shots/`：详情 / 网格 / 首页（鼓）三张 + 庆祝动画两段截图；**`.lingqu/` 落档当时未纳入本仓**（要复核请在本机跑一遍 `lingqu-cli verify`） |
| **note-gen** | [**qq8864/note-gen-ohos**](https://atomgit.com/qq8864/note-gen-ohos) | 移植验收 **83%**（移植项 7：通 5 / 未过 1 / 未测 1）· signed HAP **34.8 MB** · 8 步 **8/8** | `ohos/screenshots/`：首页 / 新建笔记 / 新建画布（真机探针取证，含 `dumpLayout` 前后对比）· `.lingqu/` 落档随仓提交 |
| **墨记 MarkNote** | [**qq8864/mark_note**](https://atomgit.com/qq8864/mark_note) | R-2 压测样本：`deps` 497 条（判 13 不可用 / 9 需 patch） | — |
| **cc-switch** | [**qq8864/cc-switch-harmonyos**](https://atomgit.com/qq8864/cc-switch-harmonyos) | 手工桥接路线（未跑 8 步，不计入 A4） | 真机装机 + 界面可用 |

> 口径：**仓里写什么就是验到什么**——没截到图就不写"已适配"（m3u8dl 那条即如此）；
> 各仓 README 顶部都标了「本项目由[灵渠迁移台](https://atomgit.com/qq8864/lingqu)移植」并给回链。

### 📋 样本台账（测过的都记在这，含只做静态评测与排队待测的）

上表是**已上真机验证**的 7 个；这张是**全部测过的样本**（含只做了静态评测、正在压测的）与**排队待测**。
「测到哪一步」一律按落档（`.lingqu/<步骤>/<工程>.json`）如实标注——**静态评测 ≠ 迁得动**，别把两列看串。

| 样本 | 上游开源地址 | 测到哪一步 | 备注 |
|---|---|---|---|
| cc-switch | [farion1231/cc-switch](https://github.com/farion1231/cc-switch) | 真机装机 + 启动 + 界面可用（HAP） | 走手工桥接路线，未跑 8 步流水线 |
| note-gen | [codexu/note-gen](https://github.com/codexu/note-gen)（移植版：[note-gen-ohos](https://atomgit.com/qq8864/note-gen-ohos)） | 8 步 **8/8**；移植验收 **83%** | 业务功能 180 条单列冒烟；人工介入 0 处 |
| habit-tree | [qq8864/habit-tree](https://atomgit.com/qq8864/habit-tree) | 8 步 **8/8**；移植验收 **100%** | 0 处人工介入 |
| m3u8dl-tauri | [qq8864/m3u8dl-tauri](https://atomgit.com/qq8864/m3u8dl-tauri)（移植版：[m3u8dl-tauri-ohos](https://atomgit.com/qq8864/m3u8dl-tauri-ohos)） | 8 步 **8/8**；移植验收 **100%** | 原生选择框已接 ArkTS `DocumentViewPicker` |
| rust-music | [qq8864/rust-music](https://atomgit.com/qq8864/rust-music) | 8 步 **8/8**；移植验收 **80%** | 扁平布局；`rust-music-3` 源码已不在本机，80% 取历史落档 |
| juCang / 聚藏 | [qq8864/juCang](https://atomgit.com/qq8864/juCang) | HAP 出包 + 真机启动；旧口径 85% | `events` 项待真机实测 |
| atomMqtt | [qq8864/atomMqtt](https://gitcode.com/qq8864/atomMqtt) | 仅签名体检落档 | 扁平布局；未进 8 步流水线 |
| atomgitcli | [nutpi/atomgitcli](https://atomgit.com/nutpi/atomgitcli) | 仅签名体检落档 | **非 Tauri 工程**（Rust CLI），作为工具链体检对象纳入 |
| mark_note | [qq8864/mark_note](https://atomgit.com/qq8864/mark_note) | **R-2 压测已出结果**：`deps` 497 条（判 13 不可用 / 9 需 patch）；`build` exit 101——唯一 crate 级失败点 `libdbus-sys`（矩阵原判"可用"⇒ **FN**，已回填 `R2-DEPS-013`） | 墨记 MarkNote（Tauri v2 + Rust `satteri` + React 19）；`src-tauri` 布局 |
| tauri-mqtt-client-ohos | [OpenHarmonyPCDeveloper/ohos_mqtt_client_tauri](https://atomgit.com/OpenHarmonyPCDeveloper/ohos_mqtt_client_tauri) | **R-2 压测已出结果**：`deps` 555 条（判 10 不可用 / 7 需 patch）；补齐 target CC 与修掉过期 SDK 路径后 **`build` `exit=0 / errors=0` 真的编过**（"不可用"预测一条都没被触发，待查是过度预测还是被 cfg 排除） | 网络长连接 + fork 依赖形态 |
| EcoPaste | [EcoPasteHub/EcoPaste](https://github.com/EcoPasteHub/EcoPaste)（移植版：[ecopaste-ohos](https://atomgit.com/qq8864/ecopaste-ohos)） | **真机跑通（正式自签版）**：`sign --auto` 出含本机 UDID 的 profile（包名 `com.ayangweb.eco_paste`）→ `hap` `signed=true` → `install`/`start` 成功 → **onboarding 从 1/6 走到 6/6、主界面列表渲染出空态**；`verify` 出 stats（移植项 7、covered 6） | 跨平台剪贴板管理工具（Rust + Tauri，7.6k★）；移植中修掉 5 处桌面专属 builder 方法 + 2 个启动期致命坑（`tauri-plugin-log` 的 `LogDir` EPERM、路径 API 返回不可写路径） |
| dbx | [t8y2/dbx](https://github.com/t8y2/dbx)（移植版：[dbx-ohos](https://atomgit.com/qq8864/dbx-ohos)） | ✅ **真机跑通、界面可见**：交叉编译 `exit=0`（`libdbx_lib.so` 97 MB）· signed HAP 99,584,663 B · `deploy` 装+启成功 · **进程 + `:render` 进程存活、`#FOREGROUND`、截图为 DBX 真实「新建连接」界面**（getVer 两轮修复：数据目录 EPERM、重复 `main` webview、黑屏的 `defaultPage`×label 组合）· 移植验收 **83%**（5/6 有结论；`events` 用 `:memory:` 连接触发存活事件实测转正；`platform-api` 仍有 10 处未落地降级）· 报告 **8 步 8/8** | 轻量跨平台数据库客户端（Rust + Tauri + Vue，100+ 数据库，30.9k★；27 crate workspace） |
| HuLa | [HuLaSpark/HuLa](https://github.com/HuLaSpark/HuLa) | ⬜ **排队待测** | 跨平台即时通讯桌面应用（Rust + Vue3 + Tauri，7.8k★；多窗口 / 托盘 / 全局快捷键 / 音视频，原生能力位最全的一个） |

> 台账口径：**只登记真的跑过命令的样本**，跑失败也照写（环境拦、工具链缺、样本自身坏都算结果）。
> 新样本进队时先补 `scan` + `deps`（纯静态、可复跑），再决定是否进 8 步流水线。

**真机实拍 —— EcoPaste 首次在鸿蒙 PC 上真正跑起来**（进程常驻 + ArkWeb 渲染，onboarding 首页 1/6）：

![EcoPaste 在鸿蒙 PC 上运行](docs/imgs/ecopaste-ohos-running.jpg)

> 这张图是"起来即退"修掉之后取的：此前 `install bundle successfully` + `ability started` 都成功、
> 但进程 10ms 就退、界面停在桌面（判据见 `AGENTS.md` §4-175）。**装机成功 ≠ 跑起来了。**

---

## 🚀 AI 自动进化飞轮（本项目的特色）

迁移工具的通病是**每次迁移都从零开始**：这次的报错、这次的绕法，写在会话里、日志里、人的脑子里，
下一个应用再来一遍。灵渠把它做成一个**闭环**：干活的 agent 自己写经验，机器攒证据，人只做裁决。

![AI 自动进化飞轮](docs/imgs/flywheel.png)

**每一次迁移的经验都自动沉淀**——不用人催、不用人记：agent 在迁移途中把学到的写进
`<工程>/.lingqu/notes/<工程>.md`，未命中的报错自动进台账，攒够次数进入候选池。下图是实拍：
rust-music 迁移中，右侧 AI 助手面板正在落笔经验（`hashline_edit` 写 `notes/rust-music.md`），
中栏是同轮迁移八步全绿的现场：

![飞轮实拍：迁移经验自动沉淀](docs/imgs/flywheel_shortcut.png)

**关键设计（为什么不是"让 AI 自己改技能库"）**

| 决策 | 理由 |
|---|---|
| 认知层**不许全自动写** | 指纹与规则会**直接指挥 agent 改用户工程**（动 `Cargo.toml` / `lib.rs` / `hvigorfile.ts`）——人复核一条规则 5 分钟，一条错规则毁掉一个样本的可信度 |
| **不热替换**本地 `skills/` | 技能正文进 **system prompt**，热替换 = prompt 漂移：行为变了却没人知道为什么 |
| 只记**验证过**的事 | 四段里的「修法」必须是实际生效的那个；空标题直接拒绝写盘 |
| 次数 = 可信度代理 | 1 次可能是命令写错，≥2/≥3 次基本就是系统的脾性 |
| 内容走**文件**不走参数 | 仓颉程序在 Windows 上接不了非 ASCII 的 `argv`（`AGENTS.md` §4-119）→ `--body <json>` |

**它是否真在转，看这四个数**：`notes` 条数（↑ 说明 agent 在记）· 同签名未命中次数（补完指纹后应停止增长）·
指纹/规则条数（缓慢 ↑，只收通用的）· 人工介入 A3 与可用率 A4。

> **不登录、不想贡献，飞轮照样转**：经验/台账/候选池全部落在本机 `.lingqu/` 下，裁决入库的
> 默认去处是**用户级认知层** `~/.lingqu/flywheel/`（指纹/规则/技能，离线可用，`t2h:skill`
> 装回 agent）；向公共技能仓提 PR 是**可选的分享**，不是沉淀的前提（演进路线见
> [`docs/AI自进化飞轮.md`](docs/AI自进化飞轮.md) §8 阶段 4）。

> 完整技术文档（五层结构、七个环节的接口与判据、数据结构、度量、纪律与反例、已知边界、演进路线）：
> **[`docs/AI自进化飞轮.md`](docs/AI自进化飞轮.md)**；
> 入库标准与格式（三条件 + 三追问、四段 → `pitfalls.md` 三段 的映射与示例、反例、PR 清单）：
> **[`docs/经验入库规则.md`](docs/经验入库规则.md)**

---

## 📸 截图

> **🖥 想先点一下看看？** [**在线预览界面（GitHub Pages）**](https://yangyongzhen.github.io/lingqu/) ——
> 8 屏工作台的**可交互静态页**（`docs/ui-mockup.html` 原样发布，单文件、零外部依赖，手机也能看）。
> ⚠️ 那一页是**版面与交互示意**（示例数据），不是某次真实运行的结果；
> 真实数字看下面的真机截图与 `docs/进度记录.md` 里的落档读数。
> 💡 **网页 ≠ 本项目的形态**：灵渠是**桌面应用**（cj-tauri 仓颉外壳）——**内嵌智能体、开箱即用**：
> 交付物是**单个可执行文件**（AI 引擎随包、双击可运行，无需安装依赖），唯一要配的是**模型 API Key**；
> 网页只是把界面做成了静态演示页。
> 维护：改完 `docs/ui-mockup.html` 后跑 `./scripts/publish-demo.sh` 重新发布

**① 工作台（真实窗口，1280×840）** — 左栏 8 屏导航与六项徽标、中栏当前步骤、右栏 AI 面板；
顶栏是当前工程，AI 引擎状态在页脚（`WS 已连接 / 引擎 running`）。

![工作台](docs/imgs/workbench.png)

**⑦ 迁移报告屏（真实落档生成）** — 结论一行（8 步 8/8、可用率 85%、人工介入 1 处）、**风险分级**（高 0 / 中 3 / 低 3，共 6 条）、
三段式正文（做了什么 / 没做什么 / 需要你做什么）与「迁移矩阵」。

![迁移报告](docs/imgs/report.png)

**真机侧（鸿蒙 PC，HAD-W32 / HarmonyOS 7.0.0.111 / API 26）** — Rust+ArkWeb 混合应用在真机上的运行画面：

![鸿蒙真机上的 Rust+ArkWeb 应用](docs/imgs/ohos-music-screenshot.jpg)

### 八屏全流程（真实窗口 · 1936×1048 · 逐屏 `PrintWindow` 抓取）

`LINGQU_UI_PROBE=shots` 让页面自己按左栏顺序走一遍 8 屏，抓图侧监听 `activeScreen` 变化、逐屏抓真实窗口；
**每个数字都由 `.lingqu/` 落档回投**（断点板、扫描、构建、验证、报告读数一致），不是示例值。

| ① 一键迁移 | ② 项目 / 环境 |
|---|---|
| ![一键迁移](docs/imgs/ui-01-migrate.png)<br>cjh 是执行者：这里给的是任务书与九步进度断言 | ![项目与环境](docs/imgs/ui-02-env.png)<br>体检 8 项全就绪、最近项目带落档评分、工具箱路径逐个可查 |
| **③ 迁移画像** | **④ 依赖扫描** |
| ![迁移画像](docs/imgs/ui-03-profile.png)<br>可迁移度 95（runtime.api）、识别项 R=13、清单按迁移单元计 | ![依赖扫描](docs/imgs/ui-04-deps.png)<br>540 个包、需 patch 0、不可用 11 |
| **⑤ 规则改造** | **⑥ 构建打包** |
| ![规则改造](docs/imgs/ui-05-port.png)<br>确定性改造 0 处，每处都给依据与回滚单元 | ![构建打包](docs/imgs/ui-06-build.png)<br>交叉编译 / HAP 装配 / 签名三条闸，3/3 |
| **⑦ 真机验证** | **⑧ 迁移报告** |
| ![真机验证](docs/imgs/ui-07-verify.png)<br>可用率 100%（通过 3/3，平台限制与未验证各占位） | ![迁移报告](docs/imgs/ui-08-report.png)<br>8 步 8/8、人工介入 0 处、风险分级 5 条 |

> 截图口径：前两张是**真实应用窗口**（`CopyFromScreen` 抓取本应用窗口区域，非示意图）；
> 报告屏那一张是用 `LINGQU_UI_PROBE=risk` 触发一次真实的 `t2h:report` 后截的（报告内容 100% 来自落档）。
> 第三张是迁移样本 [`rust-music`](https://atomgit.com/qq8864/rust-music)（Rust + Tauri 2）
> **真实移植成功后在鸿蒙 PC 真机上的运行画面**。
> **界面里没有示意数据**——所有数字都绑定真实落档（§4-94/§4-95）。

---

## 📋 能力矩阵

| 能力 | 状态 | 证据 |
|---|---|---|
| **8 步迁移流水线**：扫描 → 依赖矩阵 → 规则改造 → 交叉编译 → HAP 装配 → 签名 → 真机部署 → 真机验证（+ 报告 / 断点续迁 / 批量矩阵） | ✅ 全部落地 | `t2h:scan/deps/port/build/hap/sign/deploy/verify/report/resume/batch` |
| **规则改造**（确定性，幂等可回滚） | ✅ 17 条规则 | `R2-PORT-001…017`（含 0.39.53 的 015：自动注掉 hvigorfile 的 tauri 钩子，修 `00308018`；0.39.99 的 016：`reqwest` 关 `default-tls` 改 rustls，修 `Could not find directory of OpenSSL`；0.39.114 的 017：桥两侧检测——Rust `call_arkts("x")` 与 ArkTS `case "x"` **只报不写**，命名要判断，不替人改） |
| **错误指纹库**（命中不调模型） | ✅ 22 条 | `FP-001…FP-024`（**008/009 是空位，从未存在**，不补编以保留编号可追溯性），`t2h:diagnose` 命中即给修法 |
| **HAP 装配 + 闸门** | ✅ 真机 15 MB 级产物 | 点名校验 `lib<module>.so`、前端指纹闸（`.so` 内嵌 AssetKey ↔ `dist/`） |
| **HAP 包自签名（路线 A：AGC 云生成 + 本地签名链）** | ✅ 真机打通，**全程摆脱 DevEco Studio** | **纯仓颉 AES-128-GCM 解密签名口令 + hap-sign-tool 本地签名链**（`compiler/sign_*.cj`），`sign --auto` 一条命令 → `signed=true` + `install bundle successfully`——签名两态自动判定（debug/release）+ 上架前强提醒 |
| **真机部署与验证** | ✅ 3 个样本 | `hdc install` / `aa start` / `hilog` / `uitest dumpLayout` 四段判据；A4 新口径可用率（只数移植项）habit-tree **100%** · m3u8dl **100%** · rust-music-3 **80%**（note-gen-2 83%；juCang 85% 旧口径待重算） |
| **AI 一体化**：一键迁移（后台 8 步）+ **把任务书交给 cjh 让它自己干** | ✅ 实机跑过 | `t2h:migrate` / `t2h:autoport_*`；juCang 一轮 AI 自动迁移 8/8 |
| **报告**：三段式 + 风险分级 + 自动出报告 | ✅ | `t2h:report`；AI 路径跑完自动出报告（0.39.54） |
| **AI 自动进化飞轮**：经验落盘 + 未命中台账 + **候选池（suggest/archive）** → 认知层 | ✅ 实现（agent 侧实跑观察中） | `t2h:notes` / `t2h:diagnose` + `notes_test` 24 例；阶段 1 已端到端实测（候选门槛三层生效、入库后出池）；**未验**：agent 在真实迁移途中是否照做 |
| 5 样本矩阵 | 🔶 3/5 已验证 | `t2h:batch`；cc-switch / tauri-mqtt / atomMqtt 待推到验证 |

---

## ⚡ 快速开始

**前置**：仓颉 SDK 1.0.5（`cjpm` / `cjc`）、[cj-tauri 框架仓](https://atomgit.com/qq8864/cj-tauri)
（含 `native/libcjtbridge.dll` 与 `native/webview2/WebView2Loader.dll`）、stdx。
详细环境变量表见 [`docs/开发环境.md`](docs/开发环境.md)。

```bash
git clone https://atomgit.com/qq8864/lingqu.git && cd lingqu

./scripts/setup.sh              # 环境体检（只校验，不改任何文件）
./scripts/test.sh -s            # 六项门禁（首次会派生 targets/ 骨架）
./scripts/run-dev.sh -b         # 编译 + 起窗口（AI 引擎自动拉起；需要模型 Key）
```

Windows 用 `scripts\test.bat -s` / `scripts\run-dev.bat`（参数相同）。
**脚本一律 bash 为准，`.bat` 只做「找 bash 再委托」**——一份实现、两个平台（ADR D-012）。

给 AI 引擎配模型（也可以在工作台「设置」里点，写的是 cjh 自己的配置）：

```bash
export DEEPSEEK_API_KEY=sk-xxx      # 或 OPENAI_API_KEY / DASHSCOPE_API_KEY / CJH_API_KEY
```

### 迁一个应用（最小路径）

```bash
lingqu-cli scan   --path <工程>            # 五类清单 + 评分 + 覆盖率（C1/C2/C3）
lingqu-cli deps   --path <工程>            # Cargo 依赖 → OHOS 兼容矩阵 + 替代建议
lingqu-cli port   --path <工程>            # 17 条规则改造（幂等 / 可回滚 / 决策可审计）
lingqu-cli build  --path <工程>            # 交叉编译 + .so 前端指纹闸
lingqu-cli hap    --path <工程>            # HAP 装配（点名校验 lib<module>.so）
lingqu-cli sign   --auto --path <工程>     # AGC 自动签名（唯一人工介入：浏览器授权一次）
lingqu-cli deploy --path <工程> --start    # hdc 装机 + 拉起 + hilog
lingqu-cli verify --path <工程>            # 功能清单 → 可用率
lingqu-cli report --path <工程>            # 三段式报告 + 风险分级

# 或者：一条命令跑完 8 步（卡住时留给 AI 接着干）
lingqu-cli migrate --path <工程> --wait
```

**落档说了算**：`.lingqu/<步骤>/<工程>.json` 写着通过才算通过。
GUI 里对应的入口是「🤖 开始 AI 自动迁移」（`t2h:autoport_start`：准备现场 → 交任务书 → 盯落档 → 停滞/预算时叫人）。

### 打包分发

```bash
bash packaging/pack-win-single-full.sh   # 真·单文件：产物只有一个 main.exe（cjh 与 WebView2Loader 变 PE 资源，运行期释放）
bash packaging/package-win.sh            # 常规目录包（DLL 按导入闭包自动收，漏一个就启动即退 0xC0000135）
```

---

## 🧪 测试与质量

**一句话**：`./scripts/test.sh` 是**唯一交付凭证**——六项全绿才算能交付，而且每一项都要求"看得到明细"。

```
[0] cj-tauri sync         清单 → 派生 targets/（改了 cj-tauri.toml 才需要 -s）
[1] 业务包 cjpm build      零警告（unused / deprecated 一律清零，禁止"先交付后清理"）
[2] 业务包 cjpm test       470 例 / 50 个 *_test.cj，FAILED=0 且 ERROR=0
[3] cj-tauri check        清单校验 + 骨架漂移 + 能力三方比对（声明 × 插件自述 × 实际装配）
[3b] 页面脚本语法          抽出 index.html 的 <script> 块逐个 node --check
[4] targets/desktop build  骨架侧也要编得过且零警告
[5] cli build             AI 用的命令行入口也要编得过且零警告
```

| 质量手段 | 具体做法 | 真实产出 |
|---|---|---|
| **测试只测纯函数** | 进程 / 网络 / WebView2 / 真机部署**不在单测里造假绿**，这类以实机为准 | 499 例覆盖扫描器、依赖解析、规则改造、HAP 闸、签名判定、风险分级、扫描口径、真机探针… |
| **bug 先红后绿** | 修 bug 必须先写复现用例（红）再修（绿） | 本轮 0.39.55 的 3 个真 bug 就是单测当场抓出来的（见下） |
| **零警告是硬判据** | 门禁统计 `warning:` 行数并**打印明细**（只报条数等于没检查） | 0.39.0 曾因"删调用方留下 unused"栽过，之后写进规矩 |
| **界面可自动断言** | `t2h:ui_report` 回投版面指标（grid 列宽 / 当前屏 / JS 错误数 / 面板状态 / 200+ 字段）落 `.lingqu/ui-report.{json,log}` | 没有视觉也能证明版面对；本轮两个截图也是这么验的（像素体检：239/300 种颜色，非空白） |
| **落档即证据** | 每步判定写 `<工程>/.lingqu/<步骤>/<工程>.json`，失败要把闸门第一条 `failures` 贴出来 | 报告、风险分级、断点板、矩阵全部只读落档，不猜 |
| **真机口径不靠退出码** | `hdc` 失败也返回 0 → 只按输出文本判（`install bundle successfully` / `start ability successfully`）；界面是否真画出来用 `uitest dumpLayout` 断言 | 白屏、锁屏、异签名装机这些历史坑都是这么定位的 |
| **踩坑清单** | `AGENTS.md` §4 **119 条**，每条写"现象 → 根因 → 正确做法"，并要求同批进文档 | 本轮新增 §4-116~119（逐字节 UTF-8 / 美化 JSON / 全角空格 / 非 ASCII argv） |

**单测当场抓出的真 bug（0.39.55，都能过编译、跑起来必错）**

| # | 现象 | 根因 |
|---|---|---|
| 1 | 中文标题一进"经验合并"就崩 | 逐字节 `String.fromUtf8([b])`——单个字节不是合法 UTF-8（§4-116，与 §4-113 同族） |
| 2 | 经验里的 `工程` 字段变成 `juCang　时间：…` | 多字段行没在全角空格 `　` 处截断（§4-118） |
| 3 | 未命中台账的累计次数**永远是 1** | `JsonObject.toJsonString()` 是**美化输出**（一条记录 4 行、冒号带空格）→「一条一行 + 按行计数」不成立（§4-117） |

**为什么没有云端 CI**：编译链依赖仓颉 SDK 1.0.5 + stdx + cj-tauri 框架 + DevEco/OHOS NDK（真机步骤还要设备），
公开 CI runner 装不全这些；所以门禁**内置在仓里**（`scripts/test.sh`，跨平台 bash + `.bat` 委托），
本地一条命令复现，任何人 clone 下来跑同一份逻辑。真机步骤以落档与证据图为准，并在
[`docs/进度记录.md`](docs/进度记录.md) 写清「验证到什么程度」。

---

## 🏗 架构

**三层技术栈，一份业务代码两端产物**

| 层 | 用什么 | 说明 |
|---|---|---|
| 外壳 / UI | **cj-tauri**（仓颉 + 系统 WebView） | 窗口、IPC、资产、能力清单、打包；桌面 = WebView2，鸿蒙 = ArkWeb |
| AI 引擎 | **cjh**（仓颉 Coding Agent Harness，进程外 web 模式） | 规划 / 诊断 / 改码，走 `127.0.0.1:8765` 的 REST + WS |
| 迁移引擎 | **仓颉** + 外部工具编排 | 扫描 / 规则改造 / 交叉编译（cargo）/ HAP（hvigor）/ 部署（hdc）/ 证据采集 |

```
lingqu/
├── cj-tauri.toml            # 应用清单——单一真相（id / 窗口 / 资产 / 能力目录）；sync 派生 targets/
├── cjpm.toml                # 业务包（static 库；骨架以 path 依赖引用）
├── src/                     # 业务代码（仓颉）
│   ├── main.cj              # build(): AppSpec —— 命令注册 / 生命周期接线（43 条 t2h:*）
│   ├── notes.cj             # ★ 本地经验（AI 飞轮的经验层）
│   ├── diagnose_miss.cj     # ★ 未命中指纹台账（AI 飞轮的证据层）
│   ├── autoport.cj          # 把任务书交给 cjh；agent 轨迹观测 / 停滞判定 / 轮次预算
│   ├── migrate.cj / resume.cj / batch*.cj      # 一键迁移 / 断点续迁 / 5 样本矩阵
│   ├── port/                # 规则库（R2-PORT-*）+ 错误指纹 + 回滚表
│   ├── compiler/            # 交叉编译 / HAP / 部署 / 签名（含纯仓颉 AES-128-GCM）
│   ├── report/ report_feed.cj                  # 三段式报告 + 风险分级
│   ├── skill_install.cj     # 把技能装进 cjh（飞轮回流通道）
│   └── tests/               # 45 个 *_test.cj（396 例，纯函数口径）
├── cli/                     # lingqu-cli：给 AI agent 用的命令行入口（22 条子命令，--json 输出）
├── assets/ui/index.html     # 工作台前端（原生 HTML/CSS/JS，8 屏 + 右栏 AI 面板，无构建步骤）
├── assets/capabilities/     # 能力白名单（命令 / 事件 / 权限集）
├── skills/t2h-ohos-port/    # 给 cjh 的移植技能（SKILL.md + 5 篇 references）
├── vendor/cjh/              # 内置 AI 引擎产物（cjh.exe + 3 DLL + SHA256SUMS）
├── scripts/                 # setup / test / run-dev（bash 为准，.bat 只委托）
├── packaging/               # 便携包与「真·单文件」打包
├── samples/                 # 样本工程与真机证据图
├── docs/                    # 方案、路线图、进度、复盘、ADR、交接、飞轮技术文档
└── targets/                 # sync 派生（.gitignore 忽略；勿手改，check 会判漂移）
    ├── desktop/             #   桌面可执行（launcher 只调 lingqu.build()）
    └── ohos/                #   鸿蒙 HAP 工程（DevEco + build-hap.sh）
```

**与 cjh 的关系：它是执行者，工具是它的手**（[`AGENTS.md`](AGENTS.md) §0.1 / ADR **D-015**）。
cjh 以 web 模式被驱动：`cjh web --port 8765 --bind 127.0.0.1`，对外 REST + WS。
就绪判据只有一条（`GET /api/health` 200）；**复用优先**（8765 上已有 cjh 就不抢不杀）；
**只绑回环**；随包产物 **4 个文件逐个 SHA256** 校验不过绝不解包、不执行。

**FAQ：为什么不集成 Claude Code / OpenCode 这类通用 agent，而非要 cjh？**

先拆层：**模型层本来就是开放的**——cjh 是 harness 不是模型，设置页可选 openai 兼容 /
anthropic 接入协议，DeepSeek / OpenAI / Gemini / 通义 等 LLM 随便接。被选定的只是
**harness 层**（驱动模型干活的引擎），换通用 agent CLI 会撞上四堵墙：

1. **鸿蒙 PC 可运行性（决定性）**：通用 agent CLI 依赖 Node/Python 运行时，而鸿蒙 PC 上
   跑不了这些运行时——**能跑在鸿蒙 PC 的仓颉 agent 引擎，cjh 是唯一路线**；且 cjh 的
   Windows / Linux / 鸿蒙三端形态统一，迁移工具本身也要"被迁移"时同样适用；
2. **小巧可内嵌 + 协议干净（项目思路成立的前提）**：通用 agent **动辄数百 MB**（自带运行时与依赖树），既不方便内嵌进桌面产物，接入协议也各不相同、未必方便集成；cjh **单文件 ~18MB**、以标准 REST + WS 对外（就绪判据一条 `GET /api/health`），与外壳同为仓颉、整个桌面产物是**一个 main.exe**（cjh 成 PE 资源运行期释放）——**正因为有它这样小巧且易集成的引擎，「桌面工作台内置完整 agent」这个项目思路才成立**；换通用 agent 会把"10MB 级轻量"打回 Electron 时代；
3. **编排件是共同设计的**：任务书（autoport）、失败现场自动拼提问、agent 轨迹观测 /
   停滞判定 / 轮次预算、审批卡、技能回流（`t2h:skill` → system prompt）、经验四段式落档
   （`t2h:notes`）——这些与 lingqu 的落档/证据体系咬合，换 harness 全部重做；
4. **安全与可控**：进程外只绑 127.0.0.1（不少 harness 默认 `0.0.0.0` 且无鉴权）、
   SHA256 验不过不解包不执行、token 只走环境变量绝不落盘；且 cjh 是 MIT 自有仓——
   缺口走 issue/PR/fork 分支先行的回馈闭环已实测跑通（`docs/上游回馈-cjh.md`）。

**加一条命令要三处联动**（漏一处就是运行期报错，`cj-tauri check` 会拦）：
`src/main.cj` 注册 → `assets/capabilities/default.json` 放行 → `assets/ui/index.html` 调用。

---

## 🧰 命令表

**`t2h:*` 命令（37 条，UI 与 CLI 共用同一套实现）**

| 组 | 命令 |
|---|---|
| 环境 / 工程 | `env` · `git_clone` · `quit` · `ui_report` |
| 分析 | `scan` · `deps` |
| 改造 | `port` · `revert` · `decisions` · `diagnose` |
| 构建与装配 | `build` · `hap` · `sign` · `deploy` · `verify` |
| 交付物 | `resume` · `report` · `batch` |
| AI | `skill` · `agent_context` · `cli_run` · `ai_brief` · `ai_decide` · `migrate` · `migrate_status` · `migrate_cancel` · `autoport_start` · `autoport_status` · `autoport_stop` · `agent_trace` |
| 引擎托管 | `cjh_status` · `cjh_deploy` · `cjh_start` · `cjh_models` · `cjh_settings` · `cjh_settings_save` |
| 经验（飞轮） | **`notes`**（`list` / `append` / `export` / **`suggest`** / **`archive`**） |

**`lingqu-cli` 子命令（20 条）**：`migrate` `scan` `deps` `port` `revert` `decisions` `diagnose` `build` `hap`
`sign` `deploy` `verify` `report` `batch` `resume` `env` `skill` `agent_context` `git_clone` **`notes`**
（`--json` 输出；GUI 专属的 `quit` / `cjh_*` 不开放给 agent）

```bash
lingqu-cli notes --action append --path . --body .lingqu/note-in.json   # 经验：内容走文件（§4-119）
lingqu-cli notes --action list --path .                                  # 看这个工程攒了几条
lingqu-cli notes --action export --path .                                # 整份 markdown
```

---

## 🖥 平台与验证范围

| 项 | 状态 |
|---|---|
| **开发机（本仓实测）** | Windows 11 + 仓颉 SDK 1.0.5 + DevEco SDK + WebView2；桌面产物与 CLI 双绿 |
| **鸿蒙 PC 真机** | HAD-W32 / HarmonyOS 7.0.0.111 / API 26：装机、启动、ArkWeb 渲染、可用率清单均已实测（3 个样本） |
| **Linux** | 脚本与门禁按跨平台写（bash 为准）；**本轮未在 Linux 上实跑**——如实标注，不写"已支持" |
| **鸿蒙端外壳** | `targets/ohos` 可派生并可打包（`build-hap.sh`）；灵渠自身作为鸿蒙应用的完整链路**未验证** |

---

## 📚 文档地图

| 文档 | 什么时候读 |
|---|---|
| [`docs/灵渠(lingqu)项目介绍.md`](docs/灵渠%28lingqu%29项目介绍.md) | **想完整了解项目定位、行业痛点与六大核心能力时**：面向读者的一篇深度介绍（背景 → 对比表 → 能力拆解 → 交付价值） |
| [`docs/迁移指南.md`](docs/迁移指南.md) | **要迁一个真实 Tauri 应用时**：8 步流程每步信什么、高频坑速查、卡住的三级递进、样本实证 |
| [`docs/P3-出口判据1-验证方案.md`](docs/P3-出口判据1-验证方案.md) | **P5 交叉编译跑通后**：依赖矩阵预测力的对照口径（Recall ≥80%）、执行八步与对照表模板 |
| [`docs/P5-流水线Linux执行方案.md`](docs/P5-流水线Linux执行方案.md) | **在 Linux 上补环境跑流水线时**：本机现状探测、环境就绪清单（每项带验证命令）、9 步首跑序列与判据、风险预案 |
| [`docs/AI自进化飞轮.md`](docs/AI自进化飞轮.md) | **要动"经验 / 指纹 / 技能怎么长出来"这条链路时**（五层结构、候选门槛、人工闸门、演进路线） |
| [`docs/任务书规范.md`](docs/任务书规范.md) | **改 `src/autoport.cj` 的任务书时**（18 个必备小节与触发条件、缺了会怎样、能力该写进哪一层、怎么验收"给全了"） |
| [`docs/经验入库规则.md`](docs/经验入库规则.md) | **改 `pitfalls.md` / 指纹库 / 规则库之前**（三条件 + 三追问、四段→三段映射与示例、反例、PR 清单） |
| [`AGENTS.md`](AGENTS.md) | **改代码前必读**：门禁、架构契约、编码规范、**§4 踩坑清单（编号已到 166，含少量重号）** |
| [`CHANGELOG.md`](CHANGELOG.md) | 每个版本做了什么（现象 → 根因 → 处置，含实测证据） |
| [`docs/进度记录.md`](docs/进度记录.md) | 每轮做了什么、验证到什么程度、下一步 |
| [`docs/会话交接.md`](docs/会话交接.md) | 换会话 / 换机器怎么接（30 分钟上手） |
| [`docs/需求追踪.md`](docs/需求追踪.md) | 质量目标 → 功能 → 界面 → 证据 的追踪矩阵 |
| [`docs/实施路线图.md`](docs/实施路线图.md) | P0–P8 阶段任务与出口判据 |
| [`docs/设计决策记录.md`](docs/设计决策记录.md) | ADR：D-001~D-018（含 D-015 方向、D-017/018 签名边界） |
| [`docs/自动签名实战复盘.md`](docs/自动签名实战复盘.md) | 自动签名的六个坑 + 协议细节 + 可照抄手册 |
| [`docs/开发环境.md`](docs/开发环境.md) | 环境变量表、构建命令、按报错原文索引的排查表 |
| [`docs/集成cjh.md`](docs/集成cjh.md) · [`docs/上游回馈-cjh.md`](docs/上游回馈-cjh.md) | cjh 集成协议；发现的上游缺口与建议 |
| [`skills/t2h-ohos-port/`](skills/t2h-ohos-port/SKILL.md) | 给 agent 的移植技能（含 `references/signing.md` 签名配方、`pitfalls.md` 踩坑指纹） |
| [`docs/ui-mockup.html`](docs/ui-mockup.html) | 界面效果图（浏览器直接打开；显式标注"示意"） |

---

## 🗺 路线与质量目标

```
P0–P6 ✅  外壳 / 对话通道 / 扫描 / 依赖 / 改造 / 构建·HAP·签名·部署 / 验证·报告
P7   🔶  6 样本：4 个已跑 8 步 8/8（cc-switch 走手工桥接路线）；按 A4 新口径移植项通过率 habit-tree 100% / m3u8dl 100% / rust-music-3 80% / note-gen-2 83%，juCang 85% 为旧口径待重算
         待办：其余 2 个推到底 + 基线/消融实验
P8   ✅  迁移指南（docs/迁移指南.md）+ 开源门面（README / LICENSE / 贡献 / 安全）
        飞轮阶段 2/3（半自动 PR → CI 评审合并）进行中
```

**质量目标（逐条证据见 [`docs/需求追踪.md`](docs/需求追踪.md)）**

| 编号 | 目标 | 现状 |
|---|---|---|
| A1 | 5 个真实开源 Tauri 应用迁移验证 | `进行中 3/5` |
| A2 | 迁移分析覆盖率 100% | `已实现已验证`（habit-tree：C1 100%、C2 100%，漏 0/误 0） |
| A3 | 单应用平均人工介入 ≤ 5 处 | `进行中`（本次三样本：m3u8dl-tauri 1 处；habit-tree 与 rust-music-3 各 0 处） |
| A4 | 鸿蒙电脑核心功能可用率 ≥ 80% | `已实现已验证`（A4 新口径，只数移植验收项：habit-tree **100%** · m3u8dl **100%** · rust-music-3 **80%** · note-gen-2 **83%** · **EcoPaste 83%**（移植项 7 / covered 6 / 通 5，1 fail + 1 unknown 待定性），五项均达线；juCang 85% 旧口径待重算） |
| A5 | 开源 + 迁移指南 | `已实现`（仓库开源 MIT；[`docs/迁移指南.md`](docs/迁移指南.md)） |

---

## 🤝 参与贡献

欢迎 issue 与 PR，但请先读 [`CONTRIBUTING.md`](CONTRIBUTING.md)：**任何代码改动都要过六项门禁**，
bug 修复要"先写复现用例再修"，行为变更要给可观测证据，文档同批更新。
安全相关问题（密钥、证书口令、Token）请不要开公开 issue，见 [`SECURITY.md`](SECURITY.md)。

## 📄 许可

[MIT](./LICENSE) © 2026 yangyongzhen。上游依赖：[cj-tauri](https://atomgit.com/qq8864/cj-tauri)、
[cjh](https://atomgit.com/qq8864/cjh)（同为 MIT），仓颉语言与 stdx 见[官网](https://cangjie-lang.cn)。
