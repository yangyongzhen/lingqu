# 更新日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的结构，
版本号三处一致：`cjpm.toml` / `cj-tauri.toml` / 本文件最新条目（见 `AGENTS.md` §6）。

---

## [0.39.118] - 2026-11-19

**提交凭据不再只认一个环境变量**。起因是用户点破：`LINGQU_GITCODE_TOKEN` 没设就把"能不能发 PR"
判死，「否则单靠个人意愿，未必现实」——这等于把飞轮闭合的那一步交给运气（R-1 的 1.3 因此一直没证据）。

### Changed

- **`SUBMIT_TOKEN_ENVS` + `resolveSubmitAuth()`（`src/pr_prepare.cj`）**：`LINGQU_GITCODE_TOKEN` /
  `GITCODE_TOKEN` / `ATOMGIT_TOKEN` / `GH_TOKEN` 四个同义变量**按顺序**探测，命中即用；
  `t2h:pr_prepare` 回投 `tokenSource` / `tokenAvailable`——**只报来源，绝不回投 token 值**。
- **探测不到时不再静默退化**：`note` 与新增字段 `howToEnable` 当场给出三条可操作的开启路径
  （① 导出个人访问令牌 ② 本机登录 atomgit CLI 由它代管 ③ **不授权也行**——`pr-body.md` 已生成，
  自己提同样有效）。依据 §4-129：要人做一件事，就得把能动手的东西摆到面前。
- `pr_prepare_test` 补用例：变量名清单不止一条、提示里三种路径都在、结果对象带 `howToEnable`。

### 诚实的边界

- 探测源仍只有 **环境变量 + atomgit CLI 代管**两类，**没有**做 AtomGit 浏览器 OAuth；
  `t2h:sign_login` 那套回环登录只覆盖 AGC。
- 界面目前只是把 `howToEnable` 当文本显示，**尚未做成可点按钮**（下一步；
  真正的"主动发起 PR"按钮要接提交命令，属独立一轮）。
- R-1 的 1.3 仍无证据：本轮改的是"凭据好不好拿"，不是"已经提过一次 PR"。

---

## [0.39.117] - 2026-11-19

**R-2 首次真跑：判据终于执行了，但分母只有 1——如实记成"未达标"，并把抓到的 FN 回填。**
`docs/需求追踪.md` §五 的原话是"不可用清单与真实编译失败吻合 ≥80% **一次都没执行过**"。
本轮挑三个**未被规则库归纳过**的样本（`cc-switch-harmonyos` / `mark_note` /
`tauri-mqtt-client-ohos`，均 0 个 `lingqu:` 标记 = 未迁移原始状态），先盲跑 `deps` 落预测，
再跑真实交叉编译对照。

### Added

- **`R2-DEPS-013` 系统总线（D-Bus）类不可用规则**（`src/deps/deps.cj` 的 `isDesktopSysBusCrate`）：
  `libdbus-sys` / `dbus` / `secret-service`。**替代建议与 GTK 族分开写**——GTK 那族重跑 `port`
  就能根除（wry/tao patch 后根本不进依赖树），dbus 系即便 tauri 全 patch 也还在树里，
  必须换 zbus 或降级/桥接系统能力。`deps_test` 补 3 条断言（含"不许抄 wry/tao 建议"的反向断言）。
- **README「样本台账」**：把**测过的 10 个样本**（含只做静态评测/压测中的）与**排队待测**的
  `EcoPaste` / `dbx` / `HuLa` 列成一张表，每行写"测到哪一步"并注明证据落档位置。

### Changed

- **FP-016 归因补 dbus 一支**：`pkg-config has not been configured to support cross-compilation`
  这条 marker 现在会先看紧随其后的 crate 名——`glib-sys/gtk` 系 → 重跑 port；
  `libdbus-sys/dbus` → 换实现或降级；`openssl-sys` → 见 FP-021。

### R-2 首次执行结果（如实，不修口径）

| 样本 | 预测（条数） | 真实失败点 | 归类 |
|---|---|---|---|
| cc-switch-harmonyos | 724：713 可用 / 11 不可用 | `aws-lc-sys`：`ToolNotFound … sdk/**HarmonyOS-NEXT-DB6**/…clang.exe` | 环境（样本 `.cargo/config.toml` 指向过期 SDK） |
| mark_note | 497：477 可用 / 11 不可用 / 9 需 patch | `libdbus-sys`：pkg-config 交叉编译未配置 | **crate 级 → FN** |
| tauri-mqtt-client-ohos | 555：538 可用 / 10 不可用 / 7 需 patch | `ring`：宿主 `cc` 找不到 OHOS sysroot 的 `assert.h` | 工具链（缺 target CC） |

- **Recall = TP/(TP+FN) = 0/1 = 0%**（分母 N=1，**不具统计意义**）；`Precision = 0/0`——
  21 条"判不可用"**一条都没被触发**（cargo 在第一个错误处就停，GTK 链没轮到编译），
  既不记 TP 也不记 FP，如实标「未触发」。
- **未达标原因**：3 个样本里 2 个卡在**环境关**，fail-fast 让预测无法被触发 ⇒ 有效分母只剩 1。

### 诚实的边界

- 两处环境级缺陷**只记录、未修**（`AGENTS.md` §4-171 / §4-172）：样本自带 `.cargo/config.toml`
  的过期 SDK 路径会盖掉工具推导值；未迁移工程的 C 依赖缺 target CC 时直接死在 `cc`。
- 协议 §2.3 的"解掉第一个失败再复跑"迭代（≤3 轮）**本轮未做**——这是把分母做大的关键。
- **R-1 只做了准备**：随包 cjh 1.6.12 已拉起（`/api/health` 200），零干预轮的实施路径确认是
  应用 IPC（`t2h:autoport_start` → 页面经 WS 下发任务书），**未开跑**；且 1.3「自主提交 PR」
  因 `LINGQU_GITCODE_TOKEN` 未设置而**无法取证**。

---

## [0.39.116] - 2026-11-19

**给「21 条指纹」装上与规则同款的判据**。0.39.115 收口规则条数时留了一句"指纹侧同款可以照抄"：
`fingerprintLibrary()` 有 `size`，但「README 说 21 条」**没有任何断言**，文档里也真留着陈旧说法
（`docs/需求追踪.md` 两处仍是「15 条指纹」）。本轮不新增清单——库本身就是单点，再抄一份只会
多一个漂移源——只补三类判据：编号连续性、库 ↔ 文档双向、库 ↔ 规则可达性。

### Added

- **指纹清单判据（`src/port/diagnose.cj`）**：`fingerprintIds / fingerprintCount /
  fingerprintRangeTextOf`（范围串 `FP-001…FP-023` **由库首尾算出**，不与条数脱钩 §4-63）+ 四件能红的判据：
  - `fingerprintNumberingTextOf`：编号须恰好是 `FP-001..FP-023` **跳过保留空位**
    （`FP-008/009` 从未存在、不补编）的那一组，无重复 / 缺号 / 越界；
  - `fingerprintMarkerDupesOf`：marker 撞车（忽略大小写）——撞了则后一条永远命不中；
  - `fingerprintRuleLinkGapsOf`：`patchKind=rule` 必须指向**已登记**的 `R2-PORT-*`，
    档位只允许 `rule` / `guide`（否则 agent 拿到的是一条死路）；
  - `fingerprintDocIdGapsOf / fingerprintCountClaimsOf / fingerprintCountClaimGapsOf`：
    文档 → 库的**双向**差集——文档引用不存在的编号、文档写着旧条数，都要红。
- **`t2h:diagnose` 回投 `fingerprintCount / fingerprintRange / fingerprintIds`**——清单有了运行期读者。
- **`src/tests/fingerprint_manifest_test.cj`（12 条）**：读**真实库与真实文档**，含
  「保留空位不许有内容」、「具体指纹必须排在泛串之前（`FP-021` < `FP-016`、`FP-022` < `FP-005`）」、
  四份现状文档（README / 飞轮 / 迁移指南 / 需求追踪）的条数与编号对齐、技能 references 引用的编号都存在。

### Changed

- `docs/需求追踪.md` 两处陈旧条数（C3 行、G16 行）→ 21 条 `FP-001…FP-023`。
- 单测 605 → **617**；版本三处 0.39.115 → **0.39.116**。

### 诚实的边界

- 判据只保证「有几条、编号怎么排、几处说法对不对得上」，**不保证指纹接得住真实日志**
  ——那要看 5 个样本的实跑命中率（`docs/需求追踪.md` §五 R-2）。
- 连续性判据**只看集合、不看数组顺序**：库的顺序是**匹配顺序**（`FP-022` 刻意夹在 `FP-004` 与
  `FP-005` 之间），把顺序塞进连续性会把这个设计判成漂移——第一版正是这么红的（见 AGENTS §4-169）。
- 历史记录类文档（`docs/进度记录.md`、`docs/会话交接.md` 的历史段、`docs/实施路线图.md`）里的条数
  是**写作当时的事实**，刻意不纳入断言集合——判据不许自造历史假红（§4-160）。

---

## [0.39.115] - 2026-11-11

**把「17 条改造规则」收成一个单点，并给条数装上能红的判据**。起因是上一轮核准文档计数：
17 条规则的编号只以 `RuleOutcome("R2-PORT-0xx")` 字面量散在 6 个文件里，
**没有任何地方能回答"一共几条"**——于是 README 写 16 条、`docs/AI自进化飞轮.md` 写 16 条、
`docs/需求追踪.md` 写 15 条，三种说法同时存在（§4-166 同族：同一份知识写两处、只靠"记得同步"必然漂）。

### Added

- **`src/port/rules.cj`：改造规则的唯一清单**。`portRules()`（17 条：编号 + 一句话标题 + 是否只报不写），
  配套纯函数 `portRuleIds / portRuleCount / portRuleRangeTextOf / portRuleKnownOf / portRuleTitleOf /
  portDetectOnlyRuleIdsOf`；三件判据工具 `ruleIdFromConstructLine`（认字面量与 `HVIGOR_HOOK_RULE_ID`
  两种真实形态，认不出的写法**返回空串让调用方判红**，不许有默认真值）、`ruleDriftTextOf`
  （清单 ↔ 源码构造点**双向**差集）、`ruleNumberingTextOf`（连号无重复）。范围串
  `R2-PORT-001…017` **由清单首尾算出**，不会与条数脱钩（§4-63）。
- **`t2h:diagnose` 回投 `ruleCount / ruleRange / ruleIds`**——清单有了运行期读者，
  agent 也能直接看到"工具里到底有哪些规则"。
- **`src/tests/port_rules_test.cj`（7 条）**：编号连号无重复 · 两种构造形态解析（含裸前缀
  `R2-PORT-*` 不许切片）· 源码构造点 ↔ 清单双向对齐（漏登记、漏实现、改成动态编号都红）·
  `diagnose.cj` 点名的规则必须存在 · README 与飞轮的编号范围/条数一致（并查旧条数残留）。

### Changed

- 文档计数以代码为唯一真相：README / `docs/AI自进化飞轮.md` / `docs/迁移指南.md` /
  `docs/P5-流水线Linux执行方案.md` / `docs/需求追踪.md` 统一为 **17 条规则 `R2-PORT-001…017`**、
  **21 条指纹 `FP-001…FP-023`**（008/009 是 0.13.0 起的空位，不补编）。

### 诚实的边界

- 清单只保证「有几条、编号连续、四处编号对得上」，**不保证规则行为对**——那要靠 5 个样本的真机迁移验收。
- 规则 tier 是**运行期按现场降档**的（008 半配好、016 多行数组都降 guide），所以清单只登记
  "是否只报不写"这条静态事实、不登记档位——否则又是一份会漂的副本。

### 验证

- `cjpm test`：**605 例**（598 → 605，本轮 +7），`FAILED=0 / ERROR=0`。
- 门禁六道全绿：`build-biz / test / check / js-syntax / build-app / build-cli`。
- **判据能红（做过反向验证）**：把清单里第 13 条临时改成 `R2-PORT-018`，
  `unittest_bin/lingqu.tests.exe --filter='*PortRuleNumbering*'` 立刻红在
  「编号不连续：第 13 条应为 R2-PORT-013，实际 R2-PORT-018」；改回后绿。
- **运行期读者实跑**：`LINGQU_DIAGNOSE_LOG=... lingqu-cli diagnose`
  回投 `ruleCount=17 / ruleRange="R2-PORT-001…017"`，`ruleIds` 17 条齐。清单不再是"只有单测知道"。

## [0.39.114] - 2026-11-11

**把「落档说了算」的几个窟窿补上，并让桥不再"只写半边"**。本轮的判据统一：不是"代码写了"，
而是"落档里能查到、换一个工程还能查得到"。

### Added

- `t2h:port` 规则 **R2-PORT-017**：**桥的双侧检测**。Rust 侧发了哪些桥命令
  （`call_arkts("x")` 与 `"cmd": "x"` 两种形态都认），与 ArkTS 分发器（`case "x"` /
  `parsed.cmd === 'x'`）逐条比对，缺哪个就**点名**。背景：`cargo build`（含
  `--target aarch64-unknown-linux-ohos`）**不编译 ArkTS**，只有 hvigor 会审 ⇒ "Rust 全绿、
  ArkTS 少个分支"能一路绿灯到真机才发现点了没反应（§4-162）。**只报不写**——补 ArkTS 分支
  要上下文，替 agent 写等于抢它的活（D-015）。
- `lingqu-cli pr`：`t2h:pr_prepare` 原先只有 IPC 入口，agent 在 bash 里跑不到。工具是它的手，
  CLI 必须同款可达。
- `sign --check-material`：证书与 `.p12` 的配套性**前置体检**（纯函数 + 落档
  `<工程>.material.json`），用来提前抓住 `11111002 Certificates error` 那一族
  ——云端证书不是本地这把钥匙签的，重下多少次都没用，只能换密钥对。
- `notes archive --to repo` 当场产出 `lessons-suggestion.md`（带
  `<!-- lingqu:repo-lessons:begin/end -->` 标记的可合并块），并回投
  `repoPrReady` / `repoPrPath`。

### Changed

- `t2h:pr_prepare` 把 repo 归档落下的经验块**幂等并入** `pr-body.md`，回投 `lessonsMerged`；
  候选池已被归档清空时，正文以经验块为主体出草稿。
- ③port 屏与 ⑤构建屏签名卡补 `action:"load"` **纯读盘回读**（与 ①②⑤⑥⑦ 同款口径）：
  agent 自己跑出来的落档，界面必须看得到（§4-135）。
- **对外定位语改为「开箱即用一站式 AI 迁移台」**：`README.md` 首屏、`AGENTS.md` §0、
  `docs/会话交接.md`、`docs/产品方案.md` 四处同步，并在 README 首屏补两句支撑
  （开箱即用＝内置引擎随包分发 + 自动拉起；可视化＝8 屏摊开落档/证据/卡点），
  不写撑不住的宣称。顺带把 README 两处过期徽标改回现值（`v0.39.114` / `598` 例单测）。

### Fixed

- **归档到 repo 的经验「两边都不认」**：`--to repo` 只回一句「经验留在候选草稿里，等你提 PR」，
  而 `pr_prepare` 只认**未入库**候选 ⇒ 刚归档的那批谁也读不到，人按提示去提 PR 会发现草稿里没有它。
  现在归档当场产块、pr_prepare 并进正文，人只做"复核 + 提交"。
- **归档集合取错**：`--to repo` 一度按"候选"取，应取**本轮归档掉的已入库经验**
  （已沉淀的才提上游仓）。
- `upsertLessonsSectionOf` 用 `doc[(size-1)..size]` 判末字符 —— 那是**取最后一个字节**，
  中文正文必抛 `IllegalArgumentException: Invalid utf8 byte sequence`（§4-116 同族）；
  替换路径还多留一个换行 ⇒ 重跑不幂等。两处一起修，单测钉住。
- `pr_prepare` 在「没有候选」时**提前返回**，而 `--to repo` 归档恰恰清空候选池 ⇒
  经验块永远并不进正文（实测 `repoPrReady=true` 但 `pr-body.md` 不存在）。早退条件改成
  「既无候选又无经验块」。

### 验证

- `cjpm test`：`TOTAL=598 / FAILED=0 / ERROR=0`（本轮 +15：桥双侧判据 9、repo↔pr 接头 5、
  源码判据 1）。
- 真实工程实跑：habit-tree 上 `t2h:port` 的 `R2-PORT-017` 回
  `applied=false / note="桥两侧都在（3 个 cmd）"`；临时样本走
  `notes append → archive --to repo → pr` 全链路：`repoPrReady=true` →
  `lessonsMerged=true`、`pr-body.md` 里 2 个标记 + 「## 经验沉淀」标题。
- 未验证：鸿蒙真机侧仍未复跑（设备锁屏）；Linux 侧本轮改动未跑。

---



**飞轮阶段 4「用户级认知层」落地**：不登录任何平台、不给源仓提 PR，也能把"这次学到的坑"
变成下一次迁移就吃上的认知——**贡献公共仓是"分享"，本地飞轮必须是"自用"**（两条轨道分开）。

### 现象

经验裁决入库后只有三条去处：本工程 `notes`、`pitfalls.md`、指纹/规则库——**后两条都在 lingqu 源仓里**。
用户没登录 atomgit、或不想给别人的仓提 PR，"这条经验值得入库"就到此为止：下个工程从零再撞一遍。
这不是"少个功能"，而是把**积累**这件本该默认发生的事，做成了需要先有账号的选择题。

### 根因

认知层只有一个装载点（编译进代码的 `fingerprintLibrary()` + 仓里的 `skills/`），而写入通道只有
"改 lingqu 源码"。**装载点与写入通道都绑死在"公共仓"上** ⇒ 没有公共贡献能力的人，飞轮在他机器上不转。

### Added

- **用户级认知层 `~/.lingqu/flywheel/`**（`LINGQU_FLYWHEEL_DIR` 可覆盖，探针/多用户靠它）——新增 `src/flywheel.cj`：
  - `fingerprints.json`：用户级错误指纹。`t2h:notes --action fp-add --body <json 文件>` 写
    （支持 单对象 / 数组 / `{"fingerprints":[…]}`；缺 `id` 自动编号 `FP-U001` 起，**缺 `marker` 直接报错**
    ——没有触发串的指纹永远不会命中，写进去只是让"我有 12 条指纹"看起来很美）；
    `--action fp-list` 列出合并库，每条带 `source: builtin|user`。
  - `lessons.md`：用户级经验本。`t2h:notes --action archive --to user`（默认）并入，
    同 `lessonKeyOf` 去重、**不累加次数**——归档是幂等动作，要是重跑一次就 +1，
    用户看到的"出现 N 次"只是他手勤（假数据比没有更坏，§4-94 同族）。
  - `rules.json` / `skills/`：留位与说明；技能回流仍走 `t2h:skill` → `~/.cjh/skills/`（机制不变，零新增）。
- `t2h:notes --action archive --to user|repo`：`repo` 只把经验留在候选草稿里等你提 PR（**不写用户级**）；
  `--to` 认不出时 `ok=false` 并说明，**不许默默当成 `user`**（用户会以为进了 PR 队列，其实只在本机）。
- `t2h:diagnose` / `t2h:migrate` 回投 `userFingerprints` / `librarySize` / `userFingerprintsDir`。

### Changed

- `readTextOrEmpty`（`src/agent_context.cj`）改用 `lenientUtf8`：用户级落档是**人手工编辑**的，
  以前只要一个非法字节 `String.fromUtf8` 就抛，整份文件读成空串 = 静默丢全部内容（§4-113 / §4-116 同族）。
- 合并口径收在 `lingqu.port`（`mergeFingerprintLibraries` / `fingerprintLibraryWithUser` / `nextUserIdOf`）：
  **用户级排前 + 同 id 用用户版本**——本表顺序即匹配顺序，刚学到的坑通常比内置泛串更具体（§4-150）。

### 诚实边界（写清，别让它看起来更强）

- 用户级层**不装可执行规则**：`R2-PORT-*` 是确定性的**文本变换函数**（`src/port/port.cj`），
  一份 JSON 没法安全地执行它 ⇒ 想加规则仍得改仓（`--to repo` 出草稿）。把安全边界让给"便利"才是真的坑。
- 用户级入库**照旧要过人工闸门**；"永远不做"清单（全自动写认知层 / 自动合并 / 自动覆盖 `skills/`）一条没松。

### 验证（全程离线：不登录、不联网）

手工走了一遍完整链路（`LINGQU_FLYWHEEL_DIR=E:/tmp/lingqu-fw-probe`，`cli/target/release/bin/main.exe`）：

```
$ lingqu-cli notes --action fp-add --body E:/tmp/fp-body.json --path E:/tmp/lingqu-proj
[lingqu][notes] fp-add: ok:E:/tmp/lingqu-fw-probe\fingerprints.json（新增 1 / 覆盖 0 / 共 1 条）
$ lingqu-cli notes --action fp-list --path E:/tmp/lingqu-proj
[lingqu][notes] fp-list: 合并库 22 条（用户级 1 条）@ E:/tmp/lingqu-fw-probe
$ lingqu-cli diagnose --path E:/tmp/lingqu-proj --log "boom LINGQU-PROBE-MARKER happened"
  → hits[0].fingerprint = { id: FP-U001, marker: LINGQU-PROBE-MARKER, patchKind: guide }   ← 用户级指纹命中
$ lingqu-cli notes --action archive --to user --path E:/tmp/lingqu-proj
  → archivedNotes: 1 / to: user / userNote: ok:…\lessons.md（用户级经验 1 条，本次新增 1）
$ cat E:/tmp/lingqu-fw-probe/lessons.md      ← 四段完整落进用户级经验本，带"重跑不虚增"说明头
```

单测：`src/tests/flywheel_test.cj` 19 条（目录解析两种分隔符 / home 为空不回落 CWD / 用户库 JSON 容错 /
`patchKind` 缺省按 guide / 合并优先级与去重 / upsert 幂等 / body 自动编号 / 经验本去重不虚增）。
`TOTAL=564，FAILED=0，ERROR=0`；五道闸全绿。

**未验证**：Linux 侧（本机只有 Windows）；`~/.lingqu/flywheel/` 与 `t2h:pr_prepare` 的联动仍靠人手工
（`--to repo` 只出草稿，不会自动塞进 PR 产物）。

---

## [0.39.112] - 2026-11-10

### 现象

0.39.111 收尾时记下的两个诚实缺口之一：「**任务书层只有代码 + AGENTS 零散说明，没有独立规范**」。
它不是形式问题，现场已经在漏：0.39.83 签名那步没给 `sign --login` / `sign --auto`（agent 自己开浏览器
登录 AGC，拿不到本机回调的 `tempToken`，白花一次人工介入）；0.39.99 TLS 栈那条技能里明明写着
`reqwest` 要关默认特性，agent 照样踩 `openssl-sys`。据此逐行核对 `buildAutoPortDirective`，
又抓出第三处：`## 原生 UI 能力` 是**无条件**渲染的，正文却裸拼 `inp.cliPath` —— 定位不到 CLI 时
产出 `` ` hap --path .` ``（程序名丢了），agent 照着跑必然 `command not found`。

### 根因

任务书是 cjh **唯一每轮必读**的入口，但它的小节全是手写字符串拼接：删一节、改一句文案、
把一个条件分支写成无条件，**编译期一句警告都没有**，症状要等下一轮真机迁移才暴露（agent 撞墙、白烧轮次）。
更根本的是：「哪些小节是必备的、各自在什么条件下出现、缺了会怎样」从来没写下来过 ——
所以既没法评审，也没法断言，只能靠人记得。

### 处置

1. **把必备清单做成纯函数**（`src/autoport.cj`）：`DirectiveClause{section, when, why}` +
   `directiveClauses()`（**18 条**，每条 `why` 写明"缺了会怎样"）+ 五个触发条件常量
   （`always` / `cli` / `device` / `state` / `half`）+ `directiveSectionsOf(whens)`（这一份变体该有哪些）+
   `directiveConditionalSectionsOf(whens)`（只看条件性小节，供"不该在"的断言）+
   `directiveGapsOf(body, wants)`（缺哪些；**空 body 判全缺**，不许把"读不到"当"都齐了"）。
2. **独立规范文档** `docs/任务书规范.md`（214 行）：为什么单独立（三次事故）、形态（落文件 + <300 字 kickoff，
   0.37.2 的 4433 字单帧被静默丢弃）、§3 必备小节表（与代码同一份）、§3.1 触发条件、§3.2 四种变体、
   §4 全自动 vs 半自动、§5 三层分工（任务书 / 技能 / 规则指纹，§4-150）、§6 六条纪律红线、
   §7 新增能力三落点 + 反例清单、§8 验收（含"只保证小节在，**不保证 agent 照做**"的诚实边界）、§9 变更流程。
3. **同源单测** `src/tests/directive_spec_test.cj`（7 条）：清单格式（18 条、`why` 非空、条件合法、无重名）/
   全流程变体缺口为空 / 无副作用变体只掉条件节且**命令不许丢程序名** / 有 CLI 时必须用真路径 /
   半自动带范围节且含 `--login` / 截断正文逐条点名 / **读真实 `docs/任务书规范.md` 断言每个小节都列到了**
   （文档读不到直接红）。
4. **修真 bug**（判据第一轮抓出来的）：`## 原生 UI 能力` 与真机冒烟那条命令裸拼 `inp.cliPath` ⇒
   改成 `cliRef` 兜底（有路径用路径，没有退化成命令名，与「工具箱」同口径），并如实把该节触发条件标为 `always`。

### 证据

- 单测：`TOTAL=545` / `FAILED=0` / `ERROR=0`（基线 538，+7）
- 五道闸 `[1/5]`~`[5/5]` 全绿：`cjpm build` 0 warning、`cjpm test`、`cj-tauri check`、
  页面脚本语法、`targets/desktop` 0 warning、`cli/` 0 warning
- **先红后绿实跑**：`testDirectiveWithoutSideConditionsDropsOnlyThoseSections` 本轮红过两次 ——
  第一次暴露 `## 原生 UI 能力` 的条件标注与生成物不一致 + 命令丢程序名（**被测代码错**）；
  第二次是我自己把「该变体全部小节」当成「条件性小节」去断"不在"（**测试自己错**，已改成
  `directiveConditionalSectionsOf`，并在代码注释里写明这种情形不许去改被测代码迎合测试）

### 变更

- 新增 `docs/任务书规范.md`、`src/tests/directive_spec_test.cj`
- `src/autoport.cj`：必备清单 + 缺口判定 + `cliRef` 兜底
- 互引：`AGENTS.md`（顶部文档清单 + §5 第 8 条）、`docs/AI自进化飞轮.md` §①、`docs/经验入库规则.md` 头部、
  `README.md` 文档索引（顺带修掉一处字面 `\n` 与过时的「踩坑清单 119 条」）

## [0.39.111] - 2026-11-10

### 现象

上一轮（0.39.110）收尾时记了三个诚实缺口，第一条是
「**指纹表 ↔ `pitfalls.md` 同源只靠纪律、没有自动校验**」。
拿现场核对，它**已经在漂移**：`FP-020` 的正文写着 hvigor 报 `00308018`，
而 `skills/t2h-ohos-port/references/` 六个 `.md` 里 `00308018` **一处都没有**；
任务书正文点名 `9568320`，技能文档同样查不到。也就是说：agent 撞上这个码，
指纹库给得出归因，但**去技能里翻不到处置**（§4-130 的同款处境：能力在、说明书没给）。

### 根因

指纹库（`src/port/diagnose.cj` 的 `fingerprintLibrary()`）与技能 references
是**两处手写维护的同一份知识**，只靠顶部一句注释「改动两边同步」约束。
纪律在没有判据时必然失效——尤其"补指纹"和"补技能"常常不是同一个人、同一轮做的事。

### 处置

1. **把同源做成判据**（`src/port/diagnose.cj`，四个纯函数）：
   - `isUniqueErrorCodeOf()`——唯一错误码的口径（全 ASCII 数字、≥7 位），
     与 §4-164「只收能被报错原文唯一认出的串」同一条线；
   - `uniqueErrorCodesOf()`——从任意文本里抽这些码（保序去重，按字节扫，中文不误判）；
   - `codesMissingInDocsOf()` / `fingerprintDocGapsOf()`——"这些码在文档里查不到"的缺口清单。
2. **单测钉住两边**（`src/tests/fingerprint_sync_test.cj`，7 条）：
   口径/抽取/去重/边界（码紧贴中文、超长码）/
   合成指纹报缺口（并指名是哪条 FP）/
   **读真实 `references/*.md` 断言缺口为空**（文档读不到时直接红，不静默通过）。
3. **按缺口补文档**（`references/signing.md`）：新增 `00308018`（hvigor `Unknown Error`，
   真 trace 是 `dev-eco-studio-script` 钩子 panic，处置=注掉钩子并重跑 `port --apply`）
   与 `9568320`（`no signature file`，压根没签上，别去查设备）。

### 证据

- `cjpm build` 零警告；`cjpm test` → `TOTAL: 538 / PASSED: 538 / FAILED: 0 / ERROR: 0`
  （0.39.110 基线 531，本轮 +7）。
- 该断言**可复现地会红**：把 `signing.md` 里的 `00308018` 删掉，
  `testRealReferencesCoverEveryFingerprintCode` 立刻报「缺口为空」失败并列出缺的码——
  它不是"跑一遍总是绿"的摆设。
- 同批同步：`docs/AI自进化飞轮.md`（认知层资产表按真实规模更新 + 补"同源靠单测"一节）、
  `docs/进度记录.md`。

---

## [0.39.110] - 2026-11-10

### 现象

重签之后装机仍被拒：`deploy` 回 `9568322 signature verification failed due to not trusted app source`。
可每一份落档都说"好"——`sign` 落档 `ok=true`、`mode.canInstallDevice=true`、设备 UDID 就在 profile 的
`bundle-info.device-ids` 里、HAP `signed=true` 8.3 MB、`libm3u8dl_tauri_lib.so` 已装配。
连"设备上装着同包名的旧签名版本"这条也排掉了（`bm uninstall` 之后再装，照样 `9568322`）。

### 根因

**签 HAP 用的证书，和 profile 里绑的证书不是同一张**——两层，第二层会在第一层修好后暴露：

1. `sign --auto` 第 ⑤ 步复用云端同名证书（`auto_debug_40574614.cer`）时，判据是
   `if (freshCert || !exists(cerPath))`——**只要本地 `.cer` 还在就不重下**。
   实测本地那份是 11-01 的旧证书（serial `63E51AD2…`），而这轮 profile 里绑的是云端 11-09 那张
   （serial `63E51D71…`，有效期 2026-11-09→2027-11-09、`type=debug`、device-ids 含本机 UDID）。
   hvigor 用旧证书签 → 设备按 profile 里的证书验 → 不信。
2. 让工具重下 `.cer` 后，一致性回来了，但 hvigor 报
   `11111002 Certificates error`：**云端那张证书不是本地 `.p12` 这把钥匙签出来的**
   （换证书时换了密钥对）。这一段只能 `--newKeys` 重生成材料，重下 `.cer` 多少次都没用。

教训：证书以**云端为准**，本地 `.cer` 只是一份缓存；而"证书对了"不等于"钥匙配对了"。

### 处置

- `sign --auto` 在 ⑥（profile 落盘）之后加**证书-配置一致性自检**：从 p7b 里取出
  `bundle-info.development-certificate`，与本地 `.cer`（一条链，顺序是 根→中间→开发者）比对；
  不一致就按 `certObjectId` 重下（旧文件改名 `*.lingqu-stale-<ms>` 留底）并复核，
  重下仍不一致则直接给出「`.p12` 与证书不是一把钥匙 → `sign --auto --newKeys`」并中止，
  不再一路"成功"到真机才炸。
- 新增三个纯函数（各带单测）：`pemCertBlocksOf`（抽证书块并规范化空白）、
  `profileDevCertPemOf`（从 profile JSON 取开发证书正文）、`cerHasCertOf`（链里有没有这张）。
- `hapSignHint` 认 `11111002` / `00303242`：写明这是"材料文件齐全但钥匙不配"，
  处置是 `--newKeys`，**别去重下 .cer、别改包名**。
- 指纹库新增 **FP-023**（marker 用唯一的错误码 `11111002`，不拿 `Certificates error` 这类泛串）。
- 任务书里 `9568322` 由"两种成因"改为"三种"（新增第 ③ 种），并明说
  **「设备上装着同包名的另一套签名」报的是 `9568332`**，两者别混。
- `references/signing.md` / `references/pitfalls.md` 同源更新（与指纹表一起改，不许只改一边）。

### 验证

- 真机 `5VFUN26310G06052`：`bm uninstall` → `sign --auto --newKeys`（新证书
  id=2080774188410377024、新 profile、写回 `signingConfigs`）→ `hap`（`signed=true`）→
  `deploy --start`：**`installed=true / started=true / ok=true`**。
- 装机后 `probe --auto --max 8`：「选择文件」**pass**——点后版面多出「最近 / 正在加载… / 已选 (0/1)」，
  即 ArkWeb 侧真的弹出了 `DocumentViewPicker`（0.39.108 的 native UI 桥在真机成立）；
  `浏览 / 文档 / 搜索文件 / 自由手写` pass；3 条 `unknown`（可能是没点中，按 §4-157 不据此判不可用）。
- 五道闸全绿，单测 `TOTAL=531 / FAILED=0 / ERROR=0`。

---

## [0.39.109] - 2026-11-10

### 现象

真机复验 m3u8dl-tauri 的 picker 时，`deploy` 回投 `installed=true / started=true`，
可同一份输出里 `installDetail` 明写着：

```
error: failed to install bundle. code:9568423 error: device is unauthorized,
make sure the UDID of your device is configured in the signing profile.
```

结果是**设备上跑的还是旧版本**（`aa start` 起来的是上一轮装的），而工具"以为"刚装好。
若此时接着跑 `probe`，测的是**没有 picker 桥的旧 build**，落档却会记在当前这轮名下——
又是一种"长得跟通过一模一样"的假绿。

### 根因

`parseInstallResult` 的兜底判据是 `exitCode == 0 && code == 0`，而 `code` 来自
`hdcFailCodeOf()`——它**只认 5 个硬编码失败码**（9568322 / 9568269 / 10106102 / 9568332 / 9568289），
别的码一律回 **0**。于是任何**没登记过**的失败码都会让"失败"变"成功"（§4-40 早就写明
"hdc 失败时退出码仍是 0，只能按输出文本判"，但兜底那一半把文本判据丢了）。
`9568423` 恰好是没登记的那一类：设备 UDID 不在 profile 的 `device-ids` 里。

### 处置

- `genericFailCodeOf(text)`：按 `code:<数字>` 取**任意**失败码（只认 ≥5 位，避开 `code: 0`
  这类正常字段），未知码也**算失败**；
- `hdcErrorTextSeen(text)`：与失败码互补——没码但出现 `error:` / `failed to install` /
  `failed to start` 也算失败；
- `parseInstallResult` / `parseStartResult` 的 `ok` 改为
  `exitCode == 0 && code == 0 && !hdcErrorTextSeen(text)`；
- `hdcFailHintOf` 补 `9568423` 的处置：**这台设备的 UDID 不在 profile 里** ⇒ `sign --auto`
  重签（要浏览器登录一次 AGC），别去改编译参数（§4-77：能秒级说清的别让 agent 白等）；
- 单测：`testParseInstallUnknownCodeIsFailure`（真机原样输出 → `ok=false / failCode=9568423`）、
  `testGenericFailCodeOf`、`testHdcErrorTextSeen`。

### 证据

修后同一条失败输出被判 `installed=false / failCode=9568423`，`started=false`——
不再"装失败了却继续启动旧版本"。

### 未验证

- **m3u8dl-tauri 的 picker 真机实测仍未完成**：当前在线设备（真 UDID `667BA4F7…`）
  **不在**签名 profile 的 `device-ids`（那是另两台 `FD0D92…` / `B8861D…`）里 ⇒ 本轮 HAP 装不上。
  要补这一步需要一次 AGC 浏览器登录重签（计入 A3 人工介入）。设备上现有的是**旧 build**，
  所以本轮**没有**对新 picker 做任何真机判定，也没往 `verify` 落档写"未测"以外的结论。

---


**主题**：**把「原生 UI 能力缺口」这一个反复出现的坑，从"每换一个工程重踩一遍"变成"有桥、有手册、有指纹、有判据"**。
m3u8dl-tauri 的选择框接上 NAPI 桥 + ArkTS `DocumentViewPicker`（A4 **80% → 100%**），
并把这轮经验按「规则 / 指纹 / 技能 / 任务书 / 飞轮」五层落进仓——单点修复不复利就是白修。

### 现象

m3u8dl-tauri 的 `pick_folder` / `pick_m3u8ld_file` 在鸿蒙侧是空壳：桌面走 `rfd::FileDialog`，
鸿蒙分支直接 `None`。`verify` 判 `platform-api` fail ⇒ 可用率卡在 **80%**、且这一项**永远留在 A4 分母里**。
同理 habit-tree 的 `open_url`（上一版已修）——**同一个族**的缺口在两个样本上各撞一次，说明这是结构性问题，不是个别工程没写好。

### 根因

ArkWeb 里**没有原生对话框**，这类能力只能由 ArkTS 拉起系统 UI、Rust 通过 NAPI 桥请它动手。
但仓里此前只有"零星做过一次"（habit-tree `open_url` 的单向 fire-and-forget），
既没有可复用的桥骨架，也没有写清：

1. **线程模型**：Tauri 命令在 IPC 线程跑，`get_main_thread_env()` 是 thread_local、只有主线程有值
   ⇒ 直接调必定拿不到 env（必须 `run_on_main_thread` 投递）；
2. **uri ≠ 路径**：Picker 返回 `file://docs/…` 的 **uri**，系统授权**只在 uri 通道生效、不覆盖 `std::fs` 裸路径读写**
   ⇒ 拿路径去写分片，会在下载到一半才 EACCES；
3. **返回值怎么回去**：单选/选目录需要真返回，fire-and-forget 拿不到用户结果；
4. **`.ets` 谁编译**：`cargo build` 与交叉编译**都不检查 `.ets`**，只有 hvigor 查
   ⇒ 前两步全绿、真机上点了不弹框的假绿。

### 处置

**① 落地修复（m3u8dl-tauri）**

- 新建 `src-tauri/src/ohos_bridge.rs`：`call_arkts(msg)` 取主线程 `Env` → `globalThis.__ohos_dispatch`；
  `dispatch_on_main(app, msg)` 先 `run_on_main_thread` 再调（线程铁律）。
- 返回值走**沙箱落档 + 轮询**：Rust 下发一次性结果文件路径；ArkTS 选完先写 `.tmp` 再 `renameSync`
  （rename 保证 Rust 永不见半截 JSON），Rust 以 100 ms 轮询读取。
- `commands.rs` 的 `pick_folder` / `pick_m3u8ld_file`：鸿蒙走桥，桌面保留 `rfd::FileDialog`（cfg 隔离）。
- `EntryAbility.ets` 21 行 → **159 行**：`(globalThis as ESObject).__ohos_dispatch` + `DocumentViewPicker`
  两种命令（`pick_folder` 用 `DocumentSelectMode.FOLDER`，`pick_m3u8ld_file` 用 `fileSuffixFilters`）；
  选文件 `copyFileSync` 进沙箱再回传路径；选目录交给 Rust 侧探可写。
- 首次交叉编译报 `unresolved import openharmony_ability`：本工程对该 crate 只有 `[patch]` 段、
  **没有直接依赖**（`[patch]` 只改来源，不把 crate 加进依赖图）⇒ 改走 `tauri::ohos::openharmony_ability`
  转出，不动 `Cargo.toml` / `Cargo.lock`。
- 证据：桌面 `cargo build` exit=0；`cargo build --target aarch64-unknown-linux-ohos --release` **exit=0**；
  `hap` 装配 `built=true / errors=0 / gates=true / 8,324,836 B signed`（ArkTS 过 hvigor）；
  `verify` 重跑 ⇒ m3u8dl-tauri **100%**（`total 5 / pass 4 / fail 0 / limit 1`）。

**② 经验沉淀（这轮的重点）**

- **技能层**：新增 `skills/t2h-ohos-port/references/native-ui-bridge.md`——桥骨架、线程铁律、
  三种返回值形态对照（fire-and-forget / 沙箱落档 / 反向 napi，后者标注"真机未验证"）、
  picker 的 uri 授权语义、验证三步、纪律与反例；`SKILL.md` 索引表加行。
- **指纹层**：`FP-022`（marker `openharmony_ability`）——归因「只有 `[patch]` 没有直接依赖」，
  处置「走 tauri 转出」；**排在通用 `unresolved import`（FP-005）之前**，否则被泛指纹先吃掉。
  `references/pitfalls.md` 同源补第 14/15 条（"点了不弹框"与"下载到一半 EACCES"两种表现同一族）。
- **任务书层**：`buildAutoPortDirective` 新增「原生 UI 能力」节——写死三条铁律 + 验证三步 +
  「**别自己开浏览器、别猜路径**」。这条是 §4-130 的正面处置：能力已有、说明书没给 = agent 只能瞎摸。
- **判据层**：明确"落地要双侧"——Rust 分支调了桥 **且** `EntryAbility.ets` 的 `__ohos_dispatch` 里有同名
  `cmd` 分支；只满足前者的真机表现是「点了没反应」，而现有 `commandImplLanded` 会判通过（写进
  reference §6 作为自检清单，判据本体留待下一轮与 `R2-PORT-017` 一起做）。

### 未验证

- **真机未复跑**：本轮没有设备在线，m3u8dl-tauri picker 的**真机选目录/选文件**未实测，
  100% 来自静态判据 + 桌面/交叉编译 + HAP 装配结果；以 `.lingqu/verify/<工程>.probe.json` 为准。
- 形态 C（反向 napi 回调）未在真机验证，reference 里已标注，不当成可选默认。

---


**主题**：平台 API 判据从"按 IPC 命令猜"改成"**按命中行所属函数看落地**"——三个样本里 10 处所谓"空壳"缩到 **3 处真缺口**，其中 **2 处已经落地实现**（habit-tree `open_url` 走 NAPI 桥、m3u8dl-tauri 临时目录走沙箱）；顺带修 ⑦ 报告屏认不出 `portRun` 的老账。

### 现象

三样本按 A4 新口径重跑，`platform-api` 一律判 fail，note 都是同一句
「N 处没有落地的降级方案」，于是可用率卡在 **80%**。逐处核对发现这 10 处"空壳"其实分三类问题：

1. **误报**：`dirs::data_dir` / `app_data_dir` 出现在**文档注释**里、`std::env::temp_dir` 出现在 `#[test]` 里；
2. **命名撞车**：`app_data_dir(` 这个标记把工程自己写的包装函数 `resolve_app_data_dir(` 也命中了（habit-tree 5 处"命中"里 3 处是这种）；
3. **判据认不出真实形态**：真正的落地写法是**一个函数、体内按 cfg 分块**（`resolve_app_data_dir` / `open_url` 都是），而判据只认"整个函数被 `#[cfg(target_env = "ohos")]` 包裹"。

剩下的 3 处是真缺口：habit-tree 的 `open_url`（鸿蒙上会走到 `xdg-open` 分支然后 spawn 失败，点"开源地址"没反应）、m3u8dl-tauri 的 `std::env::temp_dir`（鸿蒙没有可写 `/tmp`，concat 列表写不进去）、同一个工程的 `rfd::FileDialog`（选择框空壳返回 `None`）。

### 根因

判据把「**有没有命令命中它**」当成了「**该怎么判**」：
无命令命中 → 直接落"无法判定 → 没落地"；有命令命中 → 只看命令函数有没有整函数 cfg 分支。
两条路都没问「命中行**所在的那个函数**在鸿蒙上有没有实现」，于是封装得好好的代码被判成缺口。
另外,"标记是否是独立标识符"这件事没人管，子串匹配天然会咬到 `resolve_app_data_dir(`。

### 处置

- 扫描器加**词边界**：`markerPresentIn(line, marker)` 要求标记前一个字符不是标识符字符
  （`[A-Za-z0-9_]`），`app.path().app_data_dir()` 命中、`resolve_app_data_dir(` 不再命中。
  平台标记与前端标记统一走这一条（`parsePlatformApis` / `parseFrontendTauriApis`）。
- 判据补两种形态：`judgePlatformSite(src, lineNo)` 按**命中行所属函数**判，
  `commandImplLanded(src, fnName)` 同时认「整函数 cfg」与「体内 cfg 分块」
  （命令侧与无命令侧共用同一个结论，避免两条路各判一套）。
- 前端（`.ts/.js`）另立判据 `judgeFrontendSite`：没有 `#[cfg]` 可判，落地形态是
  **try/catch 兜底**（`getVersion` 失败回落 `APP_VERSION_FALLBACK` 就是范例）。
- **真缺口就真动手**：habit-tree `open_url` 加鸿蒙分支 → 经 NAPI 桥投 `viewData` Want
  （`EntryAbility.openExternalUrl`，系统默认浏览器接收，不需额外权限）；
  m3u8dl-tauri 新增 `temp_dir()`（桌面走系统 temp、OHOS 走 setup 登记的沙箱 `files/tmp`），
  `merge.rs` 两处调用点改用它。两个工程分别 `cargo build --target aarch64-unknown-linux-ohos
  --release` **exit=0**（鸿蒙分支在桌面编译里不参与，必须交叉编译才算验过）。
- 顺手修 m3u8dl-tauri 桌面分支缺 `tauri::Manager` 导入（`app.path()` 编不过，与本次判据无关的老账）。
- ⑦ 报告/断点板的 `port` 步认 `portRun` 块：以前只报「人工决策 N 条」，
  **看不出改造到底应用了没有**；现在报「改造已应用 N 个文件（自动规则 X 条、待拍板 Y 条）／人工决策 Z 条」，
  旧落档没有该块时如实说明而不是装作没发生。

### 证据

- 单测 521 → **524**（`testMarkerPresentInUsesWordBoundary`、`testJudgeFrontendSiteFallback`、
  `testCommandImplLandedAcceptsInBodyCfg`）。
- habit-tree 平台命中点：`app_data_dir` 从 5 处降到 2 处（其余是包装函数名/注释），
  `dirs::data_dir` 误报消失；`std::process::Command` 落地后仍是**同一条 API**，但判据终于看对了函数。
- 未验证：m3u8dl-tauri 的 `rfd::FileDialog`（选择框）还需接 ArkTS `DocumentViewPicker`，
  本轮**未做**——它仍留在分母里判 fail（口径见 ADR D-020，不粉饰）。

---

**主题**：扫描器认**扁平布局**——rust-music-3 实测「只认 `src-tauri/`」让五类清单恒为 0、A4 分母缩水成 3 项、可用率虚高为 100%；顺带按 A4 新口径（ADR **D-020**：只数移植验收项）重跑三个样本，README 进度 65% → **70%** 并新增「已验证的迁移样本」开源地址小节。

### 现象

按新口径重跑 rust-music-3 时，`lingqu-cli scan --path …` 只回一句
「未找到 src-tauri/Cargo.toml —— 不是 Tauri v2 工程？」，scan 落档里
`commands / events / frontend / platform` **全为 0** ⇒ verify 的清单只剩
`launch / build / hap` 三项，`transplantTotal=3`、通过率 3/3 = **100%**——
一个既没扫过功能清单、也没验过事件通路的样本，反而拿到了比扫全了的样本更高的分。

该工程是**扁平布局**：`Cargo.toml` / `tauri.conf.json` / `src/` 都在工程根，
没有 `src-tauri/` 这一层。

### 根因

扫描器把工程布局**写死**成 `src-tauri/`（§4-129 那族坑的第五处漏网）：
`scanProject` 只读 `${root}/src-tauri/Cargo.toml` 与 `${root}/src-tauri/tauri.conf.json`、
源码只收 `src-tauri/src`，读不到就直接 `return`「不是 Tauri 工程」。
而"布局"是**多处共用的判据**（Cargo.toml 位置、tauri.conf.json 位置、`src/` 位置、
落档里的站点标签），每处各写一份，迟早漂移——这次漂到"扫描器不认识真实工程"。

### 处置

- 新增纯函数 **`srcTauriDirOf(hasNested, hasFlat): Option<String>`**：
  传统布局 → `Some("src-tauri")`；扁平布局 → `Some("")`；两者都没有 → `None`
  （调用方报「不是 Tauri 工程」，**绝不默认成某一种布局**）。`scanProject` 的
  Cargo.toml / tauri.conf.json / Rust 源码根 / 插件站点标签**全部由它派生**，
  布局判据从此只有一个构造点。
- 「文件在、但读不出来」与「压根没有」**分开报**：前者不再被一句
  「不是 Tauri 工程」掩盖（§4-75 同族：读档口径与"没跑过"是两件事）。
- 单测 `testSrcTauriDirOf`：传统 / 扁平 / 两者都有（以传统为准）/ 都没有 ⇒
  `cjpm test` **TOTAL 514 → 515**。

### 证据（A4 新口径重跑，2026-11-10）

| 样本 | 移植项 | 通 | 未过 | 未测 | 可用率 |
|---|---|---|---|---|---|
| habit-tree | 5 | 4 | 1（5 处平台 API 无落地降级） | 0 | **80%** |
| m3u8dl-tauri | 5 | 4 | 1（4 处平台 API 无落地降级） | 0 | **80%** |
| rust-music-3 | 6 | 4 | 1（2 处平台 API 无落地降级） | 1（events 未逐条触发） | **80%**（4/5 有结论） |

- 修前 rust-music-3 的分母是 **3**（100%），修后是 **6**（80%）——
  同一份工程，改的只是"我们认不认这种布局"。
- 三个样本那 1 条失败**同源**：命中的平台 API（`app_data_dir` / `dirs::data_dir` /
  `rfd::FileDialog` / `std::process::Command` …）在 `#[cfg(target_env = "ohos")]`
  分支里是 `Ok(None)` 空壳，等于**没有落地的等价实现**，对应功能在真机上点不动。
  按 D-020 它们必须留在分母里并判 fail，不许再登记成"平台限制"剔出去。
- 真机本轮不在线（`hdc list targets` → `[Empty]`），`launch` 项沿用既有证据截图
  仍判 pass；**未做**新的真机交互实测，`probe` 结论不更新。

### 文档

- `README.md`：进度 65% → **70%**；进度描述改为按 D-020 口径叙述；新增
  「🧩 已验证的迁移样本（上游开源地址）」小节，cc-switch 与 note-gen 靠前展示。
- `docs/进度记录.md` / `docs/需求追踪.md`：同步本轮结果与未完成项。

---

## [0.39.105] - 2026-11-09

**主题**：⑥ 验证屏把**真机冒烟项**从移植主行挪回折叠节，并给折叠探针补上「展开必须为 1」的断言——一条是口径漏网，一条是假绿。

### 现象

按实测流程重跑一轮迁移（8 步 8/8、移植验收 83%）后起 `LINGQU_UI_PROBE=verifysections`，读数出现两处自相矛盾：

- `verifyMainRows=9`，而落档里移植验收项只有 **7** 条；
- 折叠摘要写「实测 **0** 条」，同一屏的 `verNote` 却写「冒烟 **2** 条」。

### 根因

1. **分流只认 `business`**（`renderVerify` 里 `category === 'business' ? 折叠 : 主行`）——真机冒烟项 `category='smoke'`（`feat:probe:*`，`verify.cj` 明写"单列、不计入通过率"）顺着 `else` 掉进主行，于是 7 条移植项变 9 条，冒烟被当成移植验收项展示。
2. **摘要只统计 `bizItems` 里的 `business`**，而实测的 2 条是 `smoke`、已被算进主行 ⇒ 摘要永远「实测 0 条」，与 `verNote`（用后端 `businessTested=2`）打架（§4-139 同族：同一屏两处对同一件事说法不同）。
3. **探针假绿**：序列注释写着「再展开 details → `verifyBizOpen` 必须变 1（证明真能展开）」，但 6800ms 那步**只 `reportUi` 不断言** ⇒ 展开失效时探针照样 `verifyProbe=1`（§4-136 假绿：长得跟通过一模一样）。

### 处置

- `business` 与 `smoke` 一并归折叠节，**主行恒等于移植验收项**；
- 摘要拆开数：`业务功能 N 条 + 真机冒烟 M 条 …（冒烟实测 X 条：通 Y / 未过 Z）`，与 `verNote` 同源；
- 探针展开后复查 `details.open === true`，失败记 `open-not-applied` / `no-biz-section`；收回阶段 `d == null` 不再回落成"收回成功"，改判 `restore-failed`（同属假绿）。

### 证据（探针 `LINGQU_UI_PROBE=verifysections`）

| 阶段 | `verifyBizOpen` | `verifyMainRows` | `verifyBizRows` | `verifyListH` |
|---|---|---|---|---|
| enter | 0 | **7** | **182** | 367 |
| default | 0 | 7 | 182 | 367 |
| opened | **1** | 7 | 182 | **8482** |
| restored | **0** | 7 | 182 | 367 |

`verifyProbe=1`、`verifyProbeFail=''`；`verifyBizText` =「业务功能 180 条 + 真机冒烟 2 条 —— 属原应用职责，不计入移植通过率（冒烟实测 2 条：通 2 / 未过 0）」，与 `verNote` 的「冒烟 2 条」一致。

---

## [0.39.104] - 2026-11-09

**主题**：⑥ 验证屏的**分节折叠**第一次被自动断言住——顺带揪出两个「界面没接住后端」的真缺陷。

### 现象

用户要求「起一轮探针看下 ⑥ 验证屏的分节折叠读数」。探针能跑，但**没有任何字段能证明折叠生效**：
`verifyRows` 数的是 `#verList .evi`，把 `<details>` 折叠体内的行也一起数了，折叠与不折叠读数一模一样。

### 根因

三条一起看：

1. **读数缺位**：折叠节（`<details>` + `<summary>`）没有任何回投字段 ⇒「180 条业务功能有没有被折起来」「默认是不是收起」「摘要把职责说清没有」全靠肉眼。
2. **字段漏取（真 bug）**：`renderVerify` 重建 `VERIFY` 对象时没取 `businessTotal` / `businessTested`，而 `verNote` 的 biz 分支读的正是 `VERIFY.businessTotal` ⇒ 恒 `undefined > 0` = false ⇒
   「业务功能 180 条属原应用职责，不计入」这句**永远不会出现**。后端 `main.cj` 一直在回投这两个键，回读白名单里也有 ⇒ 不是后端没给，是界面没接。
3. **回读顶掉口径文案（真 bug）**：`fillStepFromRecord('verify','enter')` 成功时无条件把 `verNote` 改写成「已按落档回读：路径」，把 `renderVerify` 刚算好的「移植验收通过率 X%（分母 N 项有结论…）」整段盖掉 ⇒
   用户进 ⑥ 屏读到的第一句是文件路径，不是通过率口径（§4-135 同族：回读通道把渲染结果顶掉）。

### 处置

- `renderVerify` 补齐 `businessTotal / businessTested / transplantTotal / transplantNotVerified` 四个字段；
- `fillStepFromRecord` 成功分支对 `verify` 步**只追加后缀**「（按落档回读，未重新验证）」，不许顶掉口径文案；
- `t2h:ui_report` 新增 `verifySections / verifyMainRows / verifyBizRows / verifyBizOpen / verifyBizText /
  verifyNoteText / verifyListH / verifyBusinessTotal / verifyTransplantTotal / verifyProbe / verifyProbeFail`
  （`index.html` 的 `reportUi` 与 `main.cj` 的白名单**两处一起加**，§4-60）；
- 新增自检序列 `LINGQU_UI_PROBE=verifysections`：进 ⑥ 屏 → 判默认态 → 展开 → 收回并复查。
  前提不成立（当前工程没有 verify 落档）时如实报 `no-record`，不许假绿（§4-136）。

### 证据（note-gen-2 真机，2026-11-09 23:00）

| 读数 | 值 |
|---|---|
| `verifySections` | **2**（移植项一节 + 业务功能折叠节） |
| `verifyMainRows` | **7** |
| `verifyBizRows` | **180** |
| `verifyBizOpen` | **0**（默认收起）→ **1**（展开）→ **0**（收回） |
| `verifyBizText` | 「业务功能 180 条 —— 属原应用职责，不计入移植通过率（实测 0 条：通 0 / 未过 0）」 |
| `verifyBusinessTotal` | **180**（修复前恒 `undefined`） |
| `verifyNoteText` | 「移植验收通过率 0%（分母 2 项有结论：0 通过 / 2 未过），另有 5 项未测；业务功能 180 条属原应用职责，不计入（冒烟 0 条）　（按落档回读，未重新验证）」 |
| `verifyProbe / verifyProbeFail` | **1 / 空** |

修复前同一探针报 `note-no-scope`（`verNote` 里只剩「已按落档回读：路径」），修后通过——判据确实抓到了缺陷，不是摆设。

### 说明

这轮 `verifyRate = 0%` **不是**移植质量问题：`note-gen-2/.lingqu` 在 22:44 被整体归档到 `_archive-*`，
`scan/build/hap/deploy` 落档同时被挪走 ⇒ 分母只剩 2 项有结论。重跑 `lingqu-cli scan` + `lingqu-cli verify` 后
清单恢复 187 项（180 业务 + 7 移植），折叠节才重新出现。

---

## [0.39.103] - 2026-11-09

**主题**：A4 的**分母只认移植验收项**——原应用的业务功能降为冒烟记录，不再算移植的账。

### 现象

note-gen-2 真机跑出「核心功能可用率 **4/16 = 25%**」，可用率长期压在 0~25%。
逐条核对分母：清单 192 项里 **180 项是 note-gen-2 自己的 IPC 命令**
（`ai_json_request` / `start_download` / `pick_folder`…）。用户当场点破：
「每个软件都这么验要验到什么时候？没配网、没配参数，有些功能必然过不了——移植不是给作者测业务功能」。

### 根因

把「原应用的职责」当成了「移植该证明的事」，两个后果同时成立：

- 分母没有上界（每个应用上百条命令），"≥80%" 变成永远悬着的数；
- 缺网 / 缺密钥 / 没登录时这些功能本来就跑不起来，失败与移植质量无关，却被算成移植不达标。

### 处置

- **分类**：`CheckItem` 新增 `category`（`transplant` / `business` / `smoke`）。移植项 = 装得上、
  起得来、渲染得出、前端资源进包、IPC 与事件通道、平台能力有落地等价物；业务功能只统计条数。
- **统计**：`VerifyStats` 新增 `transplantTotal` / `transplantNotVerified` / `businessTotal` /
  `businessTested` / `businessPass` / `probeFeatures`；**分母与通过率只算 transplant**；
  全局 `total/pass/fail/unknown` 也只覆盖移植项（否则一条冒烟失败会让界面报「失败 2 项」）。
- **不双重计账**：平台 API 空壳的账记在移植项 `platform-api` 上；业务功能没人实测就只记 `unknown`，
  不再因静态推断判 `fail`（早先写法让业务清单一片红，看着像"原应用全崩"）。
- **落档**：`CheckItem.toJson()` 补 `kind` / `category`——少了它，回读时只能靠 id 前缀猜分类。
- **文案统一**：报告头 / 矩阵 / 界面 ⑥ 屏 / agent 任务书一律改「移植验收通过率」，
  业务功能单列并注明不参与验收；任务书里"把功能清单逐条点完"改成"点按属可选冒烟"。
- **界面**：⑥ 屏清单按口径分节，业务功能默认折叠成一行摘要（180 条铺开会把移植项埋掉）。

### 证据

- note-gen-2 真机（`5VFUN26310G06052`）重算：`total=7 / pass=5 / fail=1 / unknown=1`，
  `covered=6`、`ratePercent=83`、`scope=transplant`；`businessTotal=180`、`businessTested=5`、`businessPass=4`。
  同一份落档里业务侧 **0 条 fail**（改前 11 条）。
- 单测 514 通过 / FAILED 0 / ERROR 0；五道闸（build-biz / test / check / js-syntax / build-app / build-cli）全绿。
- 口径决策见 `docs/设计决策记录.md` **D-020**；踩坑见 `AGENTS.md` §4-158。

---

## [0.39.102] - 2026-11-09

**主题**：自动探针**别在错的地方点**——候选按当前版面重新枚举，前台不是应用就一条都不点。

现象（本轮实跑，note-gen-2 真机 `5VFUN26310G06052`）：0.39.101 加的 `probe --auto --max 8`
第一次真机跑完只拿到 **1 条 pass**，另外 7 条全是「点前版面树里找不到「X」」。
`--max 4` 那一轮更糟：4 条全判 **fail**，而版面上根本是锁屏的日期文本（`11月9日`、`星期一`、`十月初一`）。

根因（两层，第二层是"谎报"级别的）：

1. **候选清单只枚举一次**：`runProbeAuto` 从首份版面 dump 里挑 `max` 条文本后就照着点，
   而点一次现场就变一层（点「文本」弹出记录框 ⇒ 其余「插图/链接/文件/待办」全不在这一屏了）。
   注释里写着「每条都单独 dump 一次点前版面」，实现却只 dump 不比候选——7/8 白花。
2. **没有任何"这是不是我们的应用"的判据**：设备锁屏时版面上是桌面（`com.ohos.sceneboard`）的
   日期文本，自动枚举照样点、照样落档，于是 4 条"点日期没反应"被记成功能 **fail**——
   **拿桌面冒充功能**，还会顺着 `verify_feed` 变成 `probe:11月9日` 这类假功能项，把 A4 分母也带脏。

处置：

- `firstUntriedOf(cands, tried)` + 循环重枚举：**每轮按当前版面重新挑候选**，`tried` 账去重，
  点完再 dump 下一次。落档新增 `tried` 计数。
- `foregroundBundleOf(layoutJson)`：从 `uitest dumpLayout` 原文取**第一个非空** `bundleName`
  （根节点那几个是空串，不跳过就永远取到空）。
- `foregroundGateOf(foreground, expect)` 三档纯函数：期望包名已知 → 对不上就拦；
  未知 → 只拦 `com.ohos.*` 系统界面；版面里没包名 → 不拦。
- `probeExpectBundleOf(projName, projPath)`：先读 deploy 落档，再回退 `AppScope/app.json5`
  （含扁平布局的 `gen/ohos/`、`src-tauri/gen/ohos/`）。闸不过就 `ok=false` + 说清原因，**一条都不落档**。
- 单测新增 6 条（重枚举 2 + 前台闸 2 + 实质文本 2），`cjpm test` **512 / 512**。

跑到应用真正在前台之后，又暴露**两处判据缺陷**（都是"凭噪声下结论"）：

3. **纯数字/标点被当成"版面变化"⇒ 假 pass**：点「保存到」冒出「09、:、48」（时钟）、点「添加」冒出
   「, ? !」（编辑器标点）都判了 **pass**。加 `hasWordContent()`（含 ASCII 字母或非 ASCII 字节才算有内容），
   `newTextsOf` 跳过无实质内容的文本。
4. **"点了没反应"被判 fail ⇒ 假失败**：工具分不清"没点中"（ArkWeb 文本节点 bounds 未必准）与
   "功能真无响应"，判 fail 会让可用率凭观测缺陷**下降**（与假 pass 对称的谎报）⇒ 改成 `unknown`，
   note 明写「可能是没点中，不据此判不可用」。候选清单也接 `hasWordContent`——
   实测混进过 `09, :, 52` 这种时钟拼串，纯符号连起来的东西不是按钮。

证据（真机实测，note-gen-2 / `5VFUN26310G06052`）：

| 轮次 | 候选 | 结论 |
|---|---|---|
| 修复前 | 8 | 1 pass + 7「找不到节点」；`--max 4` 那轮 4 条全 fail（点的是锁屏日期） |
| 只修重枚举 + 前台闸 | 7 | pass 由噪声撑起（`保存到` 因时钟、`添加` 因标点），其余 fail |
| 三处判据都修完 | 7 | **「文本」/「新建标签」pass**（点后真多出「添加、取消」），其余 6 条如实 unknown |

闸的实测证据（设备在桌面时）：`{"ok":false,"foreground":"com.ohos.sceneboard","expectBundle":"com.codexu.NoteGen"}`，
落档条目数**未增加**。清掉上一轮写坏的 12 条假/废条目后重跑，
`total=192 / covered=16 / featurePass=4 / probeFeatures=5 / ratePercent=25`，
`scopeNote`=「分母 = 核心功能清单（185 条：扫描命令 180 条 + 真机实测 5 条），通过 4 / 有结论 16；另有 169 项未测」
（分子分母**同源**）。报告侧 `verifyRate=25`、结论「8 步完成 8/8（100%），核心功能可用率 25%（4/16 项有结论，另 169 项未测）」。
门禁五道闸全绿（`TOTAL=512 / FAILED=0 / ERROR=0`，六项 PASS）。

## [0.39.101] - 2026-11-09

**主题**：验证这件事**不该等人**——`probe` 能自动枚举点击，实测结论也不再被统计丢掉。

现象（用户实测，桌面 UI 重跑一键迁移后）：界面进度 **100%**，报告却写
「核心功能可用率 0%（5/3 项有结论，另 169 项未测）」。一查 `.lingqu/verify/note-gen-2.probe.json`：
真机探针确实自动跑了 3 项（`new_note` pass / `new_canvas` pass / `global_search` unknown），
**一条人工都没要**，但这些结论在清单里一条都没出现。

根因（两个洞，各自都能让"自动验证"失效）：

1. **接口要求"每条都由人/你先知道按钮叫什么"**：`probe` 只收 `--feature <命令名> --click-file <按钮文本>`，
   于是 agent 探了 3 项就没词了 —— 剩下 169 项永远停在"未测"，覆盖推不动；
2. **对不上号就被静默丢弃**：`verify_feed.cj` 只把实测结论挂到**同名 IPC 命令**上，
   而界面语义名（`new_note`）与清单里的命令名（`ai_json_request`）天然对不上 ⇒ 两条真机 `pass`
   在落档里躺着，分母里没有它们（与 §4-135 / §4-140「干活的一方写了、显示的一方没读」同族）。

处置（三处，缺一条闭环都推不动）：

- **Added `lingqu-cli probe --auto [--max N]`**：不用谁知道按钮叫什么，自己去 `uitest dumpLayout`
  的版面树里枚举能点的文本，逐个点、逐个比对、逐条落档。判据收成纯函数：
  `nonButtonText`（时钟「12:34」/日期/纯数字不是按钮——现场实测过点完只有时钟 35→34 在变）、
  `riskyClickText`（删除/卸载/清空/登录… 默认跳过：自动点按跑在**真实用户的工程**上）、
  `clickableTextsOf`（先收 `clickable=true`，再收"不可点但文本短"的——ArkWeb 里整片按钮没有该标记）。
  **每条都重新 dump 一次点前版面**（点完现场就变了，复用同一份 before 会把后面几条全判 fail）。
- **Fixed 实测结论不再被丢弃**：`collectChecklistInput` 记下被命令清单吸收的实测名，
  余下的以 `FeatureInput("probe:<名>")` 进清单，条目 note 明写「真机实测」，
  `VerifyStats.probeFeatures` 单列条数，`scopeNote` 改成「扫描命令 N 条 + 真机实测 M 条」。
- **Changed 任务书**：新增「自动验证闭环」段——先 `probe --auto`，再对 `verdict=unknown` 的项点名探，
  **目标是「每一项都有结论」**，探不到要写清缺什么现场，别探 2~3 项就收工。

验证：`cjpm build` 零警告；`cjpm test` **TOTAL 505 / PASSED 505 / FAILED 0 / ERROR 0**
（新增 `src/tests/probe_auto_test.cj` 5 条：时钟与纯数字、危险词、长度阈值、
可点优先与去重、`--max` 边界）。
**未验证**：`probe --auto` 尚未在真机上实跑一轮（下一轮迁移才会用上），
真机侧效果以 `.lingqu/verify/<工程>.probe.json` 的条目数 + 报告 `probeFeatures` 为准。

---

## [0.39.100] - 2026-11-09

**主题**：`.so` **就在盘上**，闸却报"没产出"——"第一个 `.so`"不是"应用自己的 `.so`"。

现象（note-gen-2 实测，2026-11-09 20:27 那一轮）：`t2h:build` 报

```
gates.passed = false
failures = ["鸿蒙产物闸：编译成功但没产出 libtauri_app_lib.so——没有 .so 就装不进 HAP"]
```

而同一时刻 `src-tauri/target/aarch64-unknown-linux-ohos/release/libtauri_app_lib.so`
是 **33,012,312 B、刚编出来的**（mtime 就是这一轮），`artifacts` 里也明明白白列着
`libtauri_app_lib.so`。更隐蔽的一半：`assetDiff` 的 `matched/staleInSo/missingInSo`
**三组全是空数组**——前端指纹闸压根没跑，却看着像"没问题"。

根因：cargo `--message-format=json` 报的 artifact **顺序不保证应用自己的排在前面**，
现场是

```
["libpdf_inspector-dfd192e6df9e9eb4.so", "libtauri_app_lib.a", "libtauri_app_lib.so"]
```

第一项是 **deps 里的 hash 中间产物**。旧 `findSoArtifactOf` 取"第一个 `.so`"，
拼成 `release/libpdf_inspector-dfd192e6df9e9eb4.so`——它其实在 `release/deps/` 下，
`exists()` 为假 ⇒ 返回空串 ⇒ 产物闸假红 + 指纹闸被跳过。**"没找到 .so"与".so 就在盘上"同时成立**，
最坏的后果是 agent 顺着假红去怀疑 cdylib 声明/编译参数，白烧轮次。

### Fixed

- `findSoArtifactOf` 改为**期望名优先**：先按 `expectedLibNameOf` 算出的 `lib<name>.so`
  （HAP 真正加载的那个）找，再逐个试 `release/` 与 `deps/`；`expectedSo` 的算点
  **提到找 `.so` 之前**（闸的输入算得比闸晚，是漏判的常见来源）。
- cargo 一条 artifact 都没报（增量编译全 Fresh）时按磁盘兜底——**"这条命令没输出"不等于"没有产物"**；
  编译失败时闸仍先短路，不会把"没编出来"变成通过。
- 新增纯函数 `soCandidateRelsOf`（`src/port/gates.cj`）：候选顺序可单测，
  与 `expectedLibNameOf` / `hasCdylibCrateType` 同处一族。

### Added

- 任务书再补一条**顺序**：「脚手架就位后必须重跑 `port --path . --apply`」（`src/autoport.cj`）。起因是
  note-gen-2 的 `gen/ohos` 是 2026-11-09 才 `cargo tauri ohos init --ci` 生成的，而上一轮 `port --apply`
  跑在**脚手架还不存在**的时候 ⇒ R2-PORT-015 无文件可改 ⇒ 新生成的 `entry/hvigorfile.ts` 带着
  tauri Rust 钩子进 hvigor ⇒ `00308018 Unknown Error`（钩子要读 dev server 的 addr 文件，非 dev 必 panic）。
  判据写死：看 `afterRun(buildRustCode)` 那行**还在不在**、同目录有没有 `.bak` 与 `lingqu: R2-PORT-015` 标记
  ——**「规则存在」不等于「已经注过」**。
- 单测 `testSoCandidateRelsPutsExpectedArtifactFirst`（`src/tests/ohos_artifact_test.cj`），
  用例直接照抄 note-gen-2 现场这三项 artifact 的顺序——先红后绿的复现样本。
- 任务书补「**装配 HAP 前：鸿蒙脚手架必须先生成**」（`src/autoport.cj`）：判据只有一处
  （`<工程>/src-tauri/gen/ohos/build-profile.json5`）、生成命令 `cargo tauri ohos init --ci`、
  以及「别删整个 `gen/ohos` 再 init」（签名材料与 `bundleName` 都挂在 `build-profile.json5` 上）；
  「纪律」里那条「如实报告缺脚手架」也补上了具体命令。技能 `references/toolchain.md` 同步同一段
  ——**同一份知识不许只写在一条分支里**（§4-130 判据②）。起因是 0.39.99 整改时发现：工具在 `hap`
  会如实说「先用 `cargo tauri ohos init --ci` 生成」，而任务书从头到尾**一次都没提 init**，
  agent 到这一步只能撞墙（2026-11-07 还为找 `gen/ohos` 全盘扫描挂死 565s）。

### 验证

- 修后重跑 `t2h:build --path note-gen-2`：`exitCode=0`、`gates.passed=true`、`soPath` 有值、
  `assetDiff.matched=12`（12 个前端键真的比上了，此前一个都没比）、`staleInSo=0`、`missingInSo=0`。
  **⑤ 构建这一步在 note-gen-2 上第一次整条通过**（含前端指纹闸）。
- 生成脚手架（`cargo tauri ohos init --ci`）→ **重跑 `port --apply`** → `t2h:hap`：
  `built=true`、`errorCount=0`、**HAP 34,457,633 B**、`entries` 里 `libentry.so` 与
  `libtauri_app_lib.so` 齐、`gates.passed=true`。**⑥ 装配第一次通过**（此前从 0.39.99 起一直没跑到）。
  产物是 `entry-default-unsigned.hap`——签名是下一步。
- **签名 → 部署 → 验证 → 报告 同一晚跑通（人只登录 AGC 一次）**：`sign --login` → `ok=true`；
  首次 `sign --auto` 死在「复用现有 p12 但工程里没有可沿用的口令密文」（§4-85），核实该材料无工程引用
  且 `--newKeys` 是改名不删后，`sign --auto --newKeys` 成功（新证书 + 含 UDID 的 profile +
  `signingConfigs` 写回，原文件备份 `.lingqu-autosign.bak`）；`hap` 出签名产物
  **34,792,315 B / `signed=true`**；`deploy` 真机（`5VFUN26310G06052`）`installed=true / started=true /
  hilogHealthy=true`；`verify` → **`ratePercent=0`**（`featurePass=0 / covered=11`，另 169 项未测，
  12 项 fail 里 11 项是 `app_data_dir` 降级方案没落地——真问题，不是口径错）；
  `report` → 「8 步完成 7/8（87%），可用率 0%，3 处人工介入」。
  **缺的那一步是 `port`，而它其实跑过了**：证据在 `.lingqu/port/note-gen-2/decisions.json` 的
  `portRun`（`apply=true, applied=2`），报告的八步观测没认这份落档（§4-58 第三次漏网，属观测缺口）。
- 五道闸全绿：`cjpm test` **TOTAL=500 / FAILED=0 / ERROR=0**（0.39.99 的 499 + 本次 1 条）。

---

## [0.39.99] - 2026-11-08

**主题**：`reqwest` 忘了关默认特性 → 拉 openssl-sys，这条**由工具自己修**，不再指望 agent 记得住。

现象（note-gen-2 实测）：`src-tauri/Cargo.toml:76` 明明写了
`features = ["json","multipart","stream","rustls-tls","socks"]`，交叉编译到 OHOS 还是死在

```
error: failed to run custom build command for `openssl-sys v0.9.109`
Could not find directory of OpenSSL installation …
pkg-config has not been configured to support cross-compilation.
```

根因：`rustls-tls` 只是"多加一个后端"，`default-tls`（→ native-tls → openssl-sys）仍在**默认集合**里。

**关键的一条判断**：这份知识**技能里早就写着**（`references/cargo-patches.md` 的依赖兼容性表，
`reqwest` 那行就写着"`default-features=false`，禁 default，会拉进 openssl-sys"），
agent 照样踩——因为日志症状串（OpenSSL / pkg-config）与"reqwest 默认特性"之间**没有字面联系**，
而任务书「交叉编译的硬前置」那节又会把它引向"配 CC / pkg-config"。**写在技能里 ≠ agent 会读到、
更 ≠ 它能把日志串对到那一条**。所以这轮把它做成四层，核心是确定性规则。

### Added

- **规则 `R2-PORT-016`**（`src/port/port.cj`）：`reqwest` 缺 `default-features = false` 时自动加，
  并把与其无关、但属于默认集合的**纯 Rust** 项补回来——`charset` / `http2`（0.12 起还有
  `system-proxy`）。**只关默认特性会顺手砍掉这几个特性 = 静默改行为**，所以补回来是规则的一半。
  边界照旧"不猜"：已关+带 rustls-tls → 幂等跳过；显式要 `native-tls`/`default-tls`/
  `default-features = true` → guide；features 多行数组 → guide（机械合并会留下续行，把
  Cargo.toml 改坏，同 R2-PORT-002 的教训）；版本 < 0.11 或取不到 version（git/path 依赖）→ guide；
  `reqwest` 只在 `[target.*]`/dev 段出现 → guide。原行的其它键与**行尾注释**都保留。
- **指纹 `FP-021`**（`src/port/diagnose.cj`）：marker `Could not find directory of OpenSSL installation`，
  归因「reqwest 没关默认特性」，修法指向 R2-PORT-016 + 自查命令。**刻意排在 FP-016 之前**：
  现场这两串日志同时出现（openssl-sys 的 build script 也打 `pkg-config …` 那句），
  而 FP-016 归因给 glib-sys/GTK——顺序错了 agent 就走偏。FP-016 的 rootCause/fix 同步补了分流。
- **任务书「TLS 栈」小节**（`src/autoport.cj`）：症状串、根因、`port --apply` 即为修法、
  自查命令 `cargo tree --target aarch64-unknown-linux-ohos -i openssl-sys`，
  以及**明令禁止**的三条死路（装 OpenSSL / `PKG_CONFIG_ALLOW_CROSS` / `OPENSSL_DIR` 指宿主）。
- `src/tests/port_tls_test.cj`（13 条）：规则主路径 / 幂等 / 多行数组 guide / 显式 native-tls guide /
  老版本 guide / 简写形态 / 无 reqwest 不塞 / 行尾注释保留 / 按版本补默认项 / 版本与注释解析 /
  **FP-021 命中且排在 FP-016 之前** / 任务书含 TLS 栈。

### Changed

- 技能沉淀（这条要落在**人与 agent 都读得到**的地方，不止代码）：
  `skills/t2h-ohos-port/references/cargo-patches.md` 表行补症状串 + 新增「`reqwest` 忘了关默认特性
  长什么样」整节（含 ✗/✓ 对照、默认集合、别走的路）；`references/pitfalls.md` 新增第 13 条
  「`pkg-config … cross-compilation` 有两种归因：glib-sys vs openssl-sys」；`SKILL.md` 的
  references 索引点出这两处，让 agent 按需读时能直接翻到。

### Verified

- 门禁六项全绿：build 0 warning / test **499 PASSED、FAILED=0、ERROR=0**（原 486，+13）/
  `cj-tauri check` / 页面脚本语法 / `targets/desktop` build 0 warning / `cli` build 0 warning。
- 规则未在**真实 note-gen-2 工程**上跑过 apply（那要用户工程在场）：本轮验证到的是
  「同样的 Cargo.toml 行 → 产出 `default-features = false` + 完整 features 且幂等」，
  端到端（改完 `cargo tree -i openssl-sys` 为空）**未验证**，按 §1 第 4 条如实标注。

---

## [0.39.98] - 2026-11-08


**主题**：⑦ 迁移报告屏按落档回读——agent 跑过 `lingqu-cli report`，屏上不许再显示「从没生成过」。
0.39.87 给 ⑤ 构建 / ⑥ 验证两屏补了 `action:"load"`，**⑦ 屏漏在外面**：note-gen-2 的
`.lingqu/report/note-gen-2.json`（19:26，结论「8 步完成 3/8（37%）」）明明躺在盘上，
`ui_report` 却报 `reportOk=false / reportRate=-1`，因为 `REPORT` 只有人点「生成迁移报告」才被填。

### Added

- **`t2h:report {action:"load"}`**（`src/main.cj`）：只读回投 `.lingqu/report/<工程>.json`，
  **不重新生成、不写任何文件**——重出一遍会写三份文件，屏幕上的数字就成了"重算的那份"。
- **纯函数 `reportRecordOf(res, root, projPath, projName)`**：按盘上 `lingqu/report/v1` 的 schema 抄字段
  （`sections[{key,title,lines}]` / `artifacts` / `risk{…}` / `stats{…}` / `files{md,html}`），
  并把嵌套 `risk` 展成界面读的扁平 `riskLevel/riskLabel/riskSummary/riskHigh/riskItems`；
  三份产物路径按**工程路径**重定位（落档里记的是相对 CWD 的 `.lingqu\report/x.md`，§4-75 同族）。
- `ui_report` 新增 `reportLoaded` / `reportSource`（两处一起加，§4-60）：断言 `reportLoaded=1 ∧ reportOk=1`
  即证明屏上数字来自落档，而不是"从没生成过"。
- 单测 `src/tests/report_load_test.cj`：主路径（三段计数/统计透传/风险别名/产物重定位）+
  三个边界（空落档不崩、只有一段时后两段计 0、`verifyRate=-1` 仍是"尚未验证"不许变 0）。

### Changed

- 进 ⑦ 屏的顺序改为**先回读、再判重出**：回读秒级且只读盘，屏幕立刻与盘上一致；
  0.39.85 的「这一代过期就自动重出」保持原样，排在回读之后（它要写盘、会改数字）。
- 报告屏文案标出来源：时间行「（按落档回读，没重出）」、导出区「上一次导出（按落档回读）：」，
  别把"读盘"说成"刚生成"（§4-94 同族：界面不许对自己编数字来源）。

### 验证范围

- 六项门禁全绿（build 0 warning / test TOTAL=486 FAILED=0 ERROR=0 / check `com.lingqu.migrator@0.39.98` /
  js-syntax / build-app 0 warning / build-cli 0 warning）。
- **界面已取证**（`LINGQU_UI_PROBE=shots` 两轮遍历 8 屏，工程恢复为 note-gen-2，`.lingqu/ui-report.json`）：
  第一轮进 ⑦ 屏按 0.39.85 自动重出 1 次（`reportSource=generated`，`reportAutoCount=1`）；
  第二轮进 ⑦ 屏同一代不再重出、走回读 ⇒ **`reportLoaded=true` / `reportSource=record`**，
  且 `reportRate=-1` 与落档 `stats.verifyRate=-1`（尚未验证）一致 —— 正是原来
  `reportOk=false / reportRate=-1` 那处假象的反面。`reportGeneratedAt=2026-11-08T20:39:09`。

---

## [0.39.97] - 2026-11-08

**主题**：监管态不许再"装还在干活"——补上第三态「**已交接**」。0.39.87 端到端实测：agent 自己
`turn_done`（rounds=33 / tools=32）收了工，界面却仍写「进行中：正在处理「交叉编译」」，
`stalled=false / finished=false`，用户盯着屏幕以为它在跑。它不是绕圈（根本没动），也不是完工（活没干完）。

### Added

- **第三态判定 `handoffDue(turnEnded, allConcluded, busy)`**（`src/autoport.cj`，纯函数）：
  三条同时成立才算——轨迹最后一条是 `turn_done`（这一轮真收了）、8 步还有没结论的（活没干完）、
  没有工具在跑（不是"正在干活"）。任何一条不成立都不许报（宁可晚报，不可谎报）。
- **`agentTraceTurnEnded(projectPath)` + `traceLastKindOfText(text)`**（`src/agent_trace.cj`）：
  与 `agentTraceBusy` 成一对——一个说"正在跑工具"，一个说"这一轮已收"。判据只认落档/轨迹，
  不依赖页面记忆（刷新、换屏都不该改变"谁在干活"这个事实）。
- **`autoportHandoffVerdict` / `handoffEscalation`**：说清「谁停了 / 几步有结论 / 卡在哪一步 / 下一步怎么做」。
- `t2h:autoport_status` 新增 `handoff` / `turnEnded` 两个字段，`verdict` / `escalation` 随交接态改写。
- `ui_report` 新增 `aiPortHandoff` / `aiPortTurnEnded`（两处一起加，§4-60），界面据此可断言。

### Changed

- 界面把「已交接」并入"要人接手"口径：`AIP.stalled = stalled || handoff`；
  轮询新增交接分支，note 里**贴出最后一条工具报错首行**（没报错就明说"那是模型侧判断"）。
- 开跑/点「继续」时清掉上一轮的 `handoff / turnEnded / stalled`，不让旧结论顶着新回合。

### Tests

- 新增 `src/tests/autoport_handoff_test.cj`：`handoffDue` 主路径 + 三个反向（已完工 / 在干活 / 回合未完）、
  交接结论与升级文案的措辞、`traceLastKindOfText` 的三个边界（尾部空行 / 最后是 tool / 空文本）。
  `cjpm test` TOTAL **475 → 482**。

### 验证范围

- ①②（业务包 build 零警告 / test 482 全绿）已过。
- ④ 桌面产物闸**未跑**：本轮手里有正在跑的实测窗口，跑 ④ 会为释放产物结束 `main.exe`（§4-72）。
  关窗后必须补跑 `./scripts/test.sh` 全量。
- 真实「已交接」现场未再复现（本轮迁移停在 ④ 交叉编译，agent 收尾时本轮监管态已停），
  断言口径：`ui_report.aiPortHandoff=1` 且 `aiPortVerdict` 含「已交接」。

---

## [0.39.96] - 2026-11-08

**主题**：AI 干完的活，屏上要看得见——⑤ 构建 / ⑥ 验证补上「按落档回读」通道；顶栏胶囊不再把已扫描的工程说成
「未扫描」；⑥ 屏「通过 x/y」分子分母同源；README 补 8 屏真实窗口截图。

### Added

- `t2h:build` / `t2h:verify` 增加 `action:"load"`：**纯读盘回投、绝不重跑**（重跑得到的是"这一刻的数"，
  与落档对不上），界面进 ⑤/⑥ 屏与 AI 跑完该步时自动回填——0.39.87 只补了 scan/deps 两条通道。
- `t2h:ui_report` 增 `verifyCovered / verifyNotVerified / verifyScope`：⑥ 屏统计口径可被自动断言。
- `LINGQU_UI_PROBE=shots`：页面自跑左栏 8 屏，抓图侧按 `activeScreen` 变化逐屏 `PrintWindow` 抓真实窗口。

### Fixed

- ⑥ 屏写成「通过 7/3」：分子取功能口径 `featurePass`、分母取了全局 `pass`，两套口径混用。改成与
  `src/report_feed.cj` 同源配对（分子 `featurePass`、分母 `covered`）。
- 顶栏胶囊把「已扫描 R=13 项」说成「未扫描」：只有点进 ① 屏才回读扫描落档。现在切/恢复工程后主动回读，
  回读成功即重绘胶囊，胶囊与左栏徽标说的是同一份落档（§4-94/§4-95 同族）。
- 左栏徽标判据改成「报告在 **且** 至少跑过一步」，不再把"没跑过"渲染成"已完成"。

### 验证

- `scripts/test.sh` 五道闸全绿：业务包 build 零警告、`cjpm test` 475 项 0 FAILED、`cj-tauri check` 三方比对通过、
  `targets/desktop` 与 `cli/` 均零警告。
- 8 屏截图逐张核对：胶囊「已扫描 R=13 项」、⑤ 构建「已完成 3/3」、⑥ 验证「通过 3/3」、⑧ 报告「8 步 8/8 · 100%」。

---

## [0.39.95] - 2026-11-08

**主题**：工具链体检别再报假缺失——`hdc` 与 `llvm-mingw` 判到「真的能跑到」，而不是「某个写死的目录里有没有文件」；
每项标出**影响哪一步**，不适用当前宿主机的项整项不出现。

**现象**（用户实测）：「这些是不是准确？llvm-mingw 跟移植不相关吧，不相干的不需要展示」——
设置页环境体检把 `hdc 设备桥` 与 `llvm-mingw（Windows 链接前提）` 双双标成「缺失」，
可本机两者都装着：`hdc.exe` 在 `D:\oh\DevEcoStudio\sdk\default\openharmony\toolchains\`，
`x86_64-w64-mingw32-clang.exe` 在 `C:\tool\llvm-mingw-20260324-ucrt-x86_64\bin\`（且只在 PATH 上）。

**根因**

- `hdc` 项自己用**裸 `DEVECO_SDK_HOME`** 拼了一份候选路径，而本机该变量仍指着已删除的旧 DevEco
  （`D:\Program Files\Huawei\DevEco Studio\sdk`）⇒ 拼出来的路径必然不存在（§4-38 同族）。
  仓里本来就有验过存在性的 `hdcPathOr()`（env → `DEVECO_HOME` 下的 SDK → 常见安装路径），体检却没用它。
- `llvm-mingw` 只认一条写死路径 `C:\tool\llvm-mingw\bin\…`，而发行包目录名**带版本号**，
  且真实可用性取决于 **PATH 能不能按名字找到它**（cargo 就是按名字找链接器的）。

**处置**

- `t2h:env`：`hdc` 改走 `hdcPathOr()`；`DevEco` 改走已验证的 `devecoHomeOr()`；
  `OHOS NDK` 改为「环境变量 + `DEVECO_HOME` 那套 SDK」两路候选并按 **clang 文件**判定存在。
  路径类环境变量一律**验存在才采用**（§4-38）。
- `llvm-mingw` 判定换成 `llvmMingwClangCandidates()`：PATH 各段（含 `<dir>` 与 `<dir>\bin` 两种放法）
  → `%SystemDrive%\tool` / `%ProgramFiles%` / `%ProgramFiles(x86)%` 下的**版本化目录** → 老的不带版本号目录兜底。
  该项**只在 Windows 宿主出现**：别的平台上不存在这个前提，拿它报缺失就是拿不相干的项污染结论。
- 体检项新增 `scope`（影响哪一步：交叉编译 / HAP 装配 / 真机部署 / AI 面板 / 仅 Windows 主机构建），
  界面标签后以小字显示，缺了也知道该不该管；`ui_report` 增 `envTotal/envOk/envMiss/envMissIds/envScopes`
  （白名单**两处一起加**，§4-60），体检结论从此可被断言。
- 纯函数 `pathDirsOf` / `llvmMingwRootsOf` / `isLlvmMingwDirName` 新增，`addCheckScoped` 公开以便钉住「就绪/缺失」口径。

**验证**

- `cjpm build` 零警告；`cjpm test` **470 例（460 + 新增 10）**全过，`FAILED: 0 / ERROR: 0`。
- 本机实测：`DEVECO_HOME=D:\oh\DevEcoStudio`（存在）→ `hdcPathOr()` 命中 `hdc.exe`；
  `command -v x86_64-w64-mingw32-clang` 命中 `C:\tool\llvm-mingw-20260324-ucrt-x86_64\bin`。
- **未在运行期复看面板**：当时应用窗口（旧构建）还开着，按用户要求不动它；
  面板结论待下次重启后由 `ui_report.envMissIds` 确认（应不含 `hdc` / `llvm-mingw`）。

---

## [0.39.94] - 2026-11-08

**主题**：给 agent 一条**能自己判定"这个功能能不能用"**的手——`lingqu-cli probe`，外加技能与任务书把这门手艺教给它。

**现象**（用户追问）：「AI 现在能自己跑应用测试吗?」查下来三条缺口：`verify` 只**采证**（读落档、数崩溃、
存截图），点不点得动它一概不知道；技能里没有真机功能自测的闭环；任务书也只教了 `verify`。结果是
0.39.93 那两个空壳命令（`pick_m3u8_file` / `pick_folder`）只能靠**人**手动点才发现点不动。

**处置**

- 新增 `src/probe.cj`（310 行）：一条命令做完六步——`dumpLayout` 存 before → 按**文本**找节点、
  取 `attributes.bounds` `"[x1,y1][x2,y2]"` 的**中心**（不按截图估坐标：设备 1840×2800，截图是缩放过的）→
  `uiInput click` → 再 dump 比对文本集合 → 截图归档 → 写 `<工程>/.lingqu/verify/<工程>.probe.json`。
- 判定口径：点后版面**冒出新文本**（不含"无法/失败/错误"）→ `pass`；版面**一字不差** → `fail`；
  日志命中 `--expect-log` 也算 `pass`。`note` 必须写清"多出了哪条文本"或"节点数 35→35"。
- **通用，不针对任何样本**：工程、功能名、按钮文本、期望日志全是入参，落档路径由 `--path` 推出；
  代码里没有一处写死样本名。
- **中文一律走文件**（`--click-file` / `--expect-log-file`）：仓颉在 Windows 上接不到非 ASCII 的 argv
  （`Invalid unicode scalar value`，§4-119），而界面按钮文本几乎必然是中文——`--click 选择文件` 会直接崩。
- `lingqu-cli` 子命令 20 → **21**；`verify` 日志行的分子分母改回同源（原先把全局 `pass` 配功能 `covered`，
  会打出 `pass=6/5`）。
- 技能 `t2h-ohos-port` 补两节：**「真机功能自测」**（六步闭环 + 判定口径 + 哪些情形该如实记未测）、
  **「工具自检与自装（devecocli）」**（绝对路径先探、缺才装；`log/skills/docs/init` 怎么用；**它没有 `sign`**）。
- 任务书 `buildAutoPortDirective` 工具箱补 `probe`，真机段改成「功能是**点**出来的，不是看出来的」，
  并要求先分清「壳没接（OHOS 分支空实现）」还是「真崩了」，别反复试点。

**验证**（2026-11-08，真机 `5VFUN26310G06052`）

- 业务包 `cjpm build` 0 warning；`cjpm test` **460/460 全绿**（原 449 + `probe_test.cj` 11 例）。
- 真机跑通两条：
  - `pick_m3u8_file` 点「选择文件」@ (1622,396) → 版面 35→35 无新增 → **fail**（与人工取证一致）；
  - `start_download` 点「▶ 开始下载」@ (290,2146) → 版面多出「16:24:40 请先输入 m3u8 地址或选择本地文件」→ **pass**。
- 落档回读：`lingqu-cli verify` 输出 `feature=2/5 scope=features rate=40%`，与 `.lingqu/verify/m3u8dl-tauri.probe.json` 一字不差。
- 未验证：技能两节的 devecocli 安装流程（本机已有 1.0.0，未走"缺了才装"路径）；
  `cancel_download` / `get_task` 仍缺前置现场未测；六道门禁未整跑（窗口正开着，第 ④ 闸会 `taskkill` 它，§4-72）。

---

## [0.39.93] - 2026-11-08

**主题**：**「可用率 0%」那句话是假的——分子分母不同源**；顺带开一条真机实测落档通道。

**现象**（用户当场质问）：「这次的可用率 0%？不对吧，除了文件选不了、浏览不弹框，其他核心功能不可能 0%」。
落档 `stats` 为 `pass=4 / fail=4 / unknown=4 / covered=3 / ratePercent=0`，而报告结论句写着
「核心功能可用率 0%（**4/3 项有结论**，另 4 项未测）」——分子（4）比分母（3）还大。

**根因两条**

1. `report.cj` 的结论句分子取 `facts.verifyPass`（全局 4，含 launch/build/hap/frontend 装配项），
   分母取 `facts.verifyCovered`（只数功能项，3）→ 两个集合相除，必然出现"分子大于分母"。
2. 功能项结论只有 `human.json` 一条通道，我们自己在真机上点按取到的证据**无处可落** ⇒ 未测项永远是
   `unknown`，不会因为实测过而变成结论。

**处置**

- `VerifyStats` 新增 `featurePass`（功能通过数，与全局 `pass` 分开），随落档输出。
- 报告结论句：`features` 口径用 `featurePass` 当分子，`gates-only` 口径仍用 `pass`（分子分母同源）。
- 新增真机实测通道 `<工程>/.lingqu/verify/<工程>.probe.json`：
  `{"features": {"start_download": {"verdict":"pass","note":"…","evidence":".lingqu/shots/x.layout.json"}}}`。
  判定顺序改为 **真机实测 > 人工实测 > 静态推断 > 未测**；探针**不计入 A3 人工介入**（人没被打扰），
  但它的证据强度高于静态推断——点了有没有响应是事实，代码看起来像空壳只是推断。
- 新增 4 例单测：探针压过静态 fail、探针证据落进条目、stats 单列 featurePass、结论句分子同源。

**验证**（2026-11-08）

- 业务包 `cjpm build` 0 warning；`cjpm test` **449/449 全绿**（原 445 + 新增 4）。
- 真机 `5VFUN26310G06052` 实测 m3u8dl-tauri 后重跑 `lingqu-cli verify` + `report`，结论句为：
  「8 步完成 8/8（100%），核心功能可用率 **40%（2/5 项有结论，另 2 项未测）**，0 处人工介入」。
- 实测证据：`start_download` 点「开始下载」日志回「15:35:24 请先输入 m3u8 地址或选择本地文件」→ pass；
  `detect_ffmpeg` 界面显示「未找到（将回退为二进制合并）」→ pass；`pick_m3u8_file` / `pick_folder` 点按后
  版面树节点数不变、无任何弹出 → fail；`cancel_download` / `get_task` 点按无输出 → 仍记未测（不猜）。
- 未验证：其余样本未重跑；界面 ⑥ 屏未重渲（重跑走 CLI，窗口未介入）。

---

## [0.39.92] - 2026-11-08

**主题**：**签名这一关过去了，真机链路第一次整条跑通**；顺带修掉"做成了却不留痕"。
重建后按文档正路走一遍：`sign --auto` 一条命令拿到新密钥、新证书、含本机 UDID 的 profile 并写回
`signingConfigs`；HAP 一次出 **signed 8,791,204 B**；真机上 `installed/started/hilogHealthy` 全真；
`verify` 三项核心功能 **3/3（100%）**。而现场同时暴露一个口径问题：签名明明成功，
`.lingqu/sign/` 里却还是四小时前的旧档，报告因此写「8 步完成 7/8」、`nextStep` 仍指 `sign`。

### Fixed
- **`t2h:sign --auto` 成功后不落档**（`src/main.cj`）：`--auto` 分支从入口到 `return res4` 没有一处写
  `.lingqu/sign/<工程>.json`，只有"体检"路径会写 ⇒ 界面、断点板、报告读到的都是旧档，
  "签名跑过了"这件事在证据里不存在。现在成功/失败都落 `lingqu/sign/v1`：
  `mode{mode,modeLabel,canInstallDevice}` + `by=auto` + `autoSign` 明细，失败另带 `error` 与 `nextStep`
  指引（先 `sign --login` 再 `sign --auto`，材料口令解不开加 `--newKeys`）。
- 证据：落档 15:03 刷新（`mode=debug` / `canInstall=true`），报告 `stepPercent` **87 → 100**、
  `nextStep` 消失；业务包 `cjpm build` 零警告。

### Added
- 真机链路首次全绿实测记录（rust-music-3 / 5VFUN26310G06052）：
  `sign --auto` → HAP `signed=true` → `deploy.installed/started=true` → `verify` 3/3 = 100%。

### 复测（15:12–15:16，补丁进产物后由用户自己再跑一次）
- 重建产物 **15:07:26**（晚于 `src/main.cj` 的 15:03:42）后重跑，不再靠人工 `sign --path` 体检补档：
  `build 15:13:11` → `hap 15:13:27`（signed 8,791,204 B）→ `sign 15:14:20`（`mode=debug` /
  `canInstallDevice=true`）→ `deploy 15:14:28` → `verify 15:15:11`（3/3 = 100%）→
  `report 15:16:34`，结论 **「8 步完成 8/8（100%），核心功能可用率 100%，0 处人工介入」**，
  `nextStep` 不再出现；`tasks.json` 八步全 `done`。
- 同一天另两个样本按同一口径跑通：**habit-tree**（10:21，0 处人工介入）、
  **m3u8dl-tauri**（11:29，1 处人工介入）。即 **3 个真实 Tauri 应用 8 步 8/8 + 可用率 100%**
  （juCang 仍为旧口径 85%，待重算），README 进度随之 **60% → 65%**。
- **六道门禁整跑全绿**（`./scripts/test.sh`，exit 0）：`build-biz / test / check / js-syntax /
  build-app / build-cli` 全部 PASS，三条构建闸均 **0 warning**，`cjpm test` TOTAL=445 / FAILED=0 / ERROR=0；
  第 ④ 闸按 §4-92 只结束本仓自己那只 `main.exe`，cjh 引擎未受影响。
- 单测 **445 例全绿**（`PASSED 445 / FAILED 0 / ERROR 0`）；顺带修掉一例**停在旧口径的断言**：
  `testPreflightBlocksOnBundleMismatch` 仍在要求签名提示含「DevEco」，与"签名不走 DevEco"的定案冲突
  → 改为断 `sign --auto` / `sign --login`，并**反向断言**文案里不许出现 DevEco（§4-147 同族）。
- 遗留（本轮未改，已记进 `docs/进度记录.md`）：`sign` 落档被"体检"路径**整份覆写**，
  `--auto` 写的 `by=auto` 标记会丢 ⇒ 看不出来源；方向是体检路径只补 `check` 段、不整份重写。

## [0.39.91] - 2026-11-08

**主题**：**"工具自己坏了"和"工程没迁好"必须分清。** 接手一轮真机迁移（rust-music-3）跑完复盘，
发现三次构建全红**不是工程的问题**：指纹闸只认 vite 的 `assets/` 布局，而该工程是
`frontendDist: "ui"` + 单个 `index.html`；装配 HAP 前要的 `ohpm install` 在 Windows 上
直启 `.bat` 必然失败；轮次预算被抬到 120 只改了引擎内存、`~/.cjh/settings.json` 里还是 40，
下回合又在 41 轮被截断。三处都修在**我们自己的判据**上，SDK 文件一个没动。

### Fixed

- **前端指纹闸假红（`src/compiler/fingerprint.cj` + `src/main.cj`）**：整整**三层**都错，一层修好还是红，
  必须一起修。① `frontendDist` 是 **tauri v2 的 `build.frontendDist`**（嵌在 `build` 段里），
  旧代码按**顶层键**取 ⇒ 永远空串；② `tauri.conf.json` 在**扁平布局**下位于工程根，旧代码只看
  `src-tauri/` ⇒ 连配置文件都找不到；③ 就算读到了 dist，两处取键也只认 `assets/` 前缀（vite 布局），
  而该工程是 `frontendDist: "ui"` + 单个 `index.html` ⇒ 抽出 0 键。三层叠加的结果是闸报
  「`.so` 里没有内嵌前端资源」，而 `.so` 里明明白白嵌着 `index.html` / `/index.html`（各 5 处）。
  处置：新增 `jsonStringPathOf`（点路径取值，`build.frontendDist` 与顶层两种都认）、
  `resolveDistDirOf` 改 public 且两处 conf 位置都找、新增 `assetLayoutOf` / `distEntryKeysOf` /
  `compareEntryKeys` / `binaryContainsKey`——先定布局，`assets/` 有产物走老三方比对，
  只有入口文件就走**存在性**比对（`.so` 里没有可枚举的键表，凭空扫"像路径的串"只会把
  `module.json` 之类当成资源，那是另一种假红）。
  **真实工程验证**：`rust-music-3` 上跑 `build --verifyOnly` → `passed: true`、`distDir` 解析到
  `…/ui`、`failures: []`（修前：`distDir` 落到空的 `dist/`、闸报无内嵌前端资源）。
  同一份证据在**真实的 AI 一键迁移**里也拿到了：14:46:35 的 `build` 落档 `gates.passed=true`、
  `failures=[]`——修前这一步是红的。
- **登录入口递不出去（`assets/ui/index.html`）**：用户实测问「为啥没有自动弹出来网页让登录 AGC」。
  现场：agent 直接跑 `sign --auto`，报 `拉团队列表失败（token 可能已失效，重跑 sign --login）`，
  随后 `deploy` 也失败 —— 而"回合结束自动起登录"的判据**只看最后一条工具报错**，
  被 deploy 的失败盖掉了 ⇒ 登录入口一次都没递到人手上。处置：`CJ.needLoginSeen` **整回合留痕**
  （任何一条工具失败命中 `loginHintOf` 就记住），回合结束据此起登录并在签名屏给**可点**按钮；
  `loginHintOf` 同时认中文「登录」与英文 `login` / `token 可能已失效` / `拉团队列表失败`。
- **签名指引改成实际可用的路（`src/compiler/sign.cj` + `src/main.cj`，9 处）**：原文案多处写
  「在 DevEco 里点一次自动签名」——那是**多一道人工**的旧路，与我们已支持的
  `lingqu-cli sign --login`（网页登录一次）+ `sign --auto` 冲突，agent 照着读就只能停在等人。
  统一改成后者（§4-130 同族：能力在手、说明书指错路）。
- **`t2h:hap` 直启 `ohpm.bat` 必失败（`src/compiler/hap.cj` + `src/main.cj`）**：Windows 的
  CreateProcess **起不来 `.bat`**，实测 `Created process failed, errMessage: "The system cannot
  find the file specified."`（文件明明在）。后果是 hap 连红四轮、agent 只能自己手工
  `ohpm install` 再重跑，白烧轮次。新增纯函数 `ohpmLauncherOf(...)` + `hostIsWindows()`：
  Windows 有 node 与 `pm-cli.js` 就走 node（与 hvigor 同款、不经 shell），POSIX 仍走 `.bat`，
  都没有就如实报"缺 ohpm"，**不静默跳过**。实机验证 `node pm-cli.js --version` → `6.1.2.285`。
- **轮次预算"抬过却回落"（`src/cjh_settings.cj`）**：`already` 判据只看 live 内存值，
  于是"上次 POST 改过内存"被当成"已经落好"，文件不写 ⇒ 引擎重启回落 40（`cjh.log` 里
  `41 rounds` 实测 15 次）。新增纯函数 `iterBudgetSatisfiedOf(live, file, target)`：
  **两处都达标才算满足**；live 达标时也照样把文件抬上去，配置文件没落成就在返回值里
  明写「重启会回落」，不许报 `already`。

### Tests

- 新增 5 例：`testAssetLayoutOfFlatDist` / `testDistEntryKeysOfFlatDist` /
  `testCompareEntryKeysPresence` / `testOhpmLauncherOf` / `testIterBudgetSatisfiedOf`。
  `cjpm test` **443 例全绿**（原 438 + 5），`cjpm build` 零警告。

---

## [0.39.90] - 2026-11-08

**主题**：**"点了没反应"要先分清「按钮坏了」还是「对面已经没人了」。** 用户实测原话：
「当前界面点选择，不会弹出来文件选择框了吗？」——查下来按钮、权限（`dialog:default`）、
插件（`DialogPlugin()`）全都没问题，**同一版程序 5 分钟前还成功弹过 5 次目录框**
（`dialog: kind=6 … ok=1`）。真正的事发现场是：那个窗口已经**退出到一半**。

### 现场证据（都是实取的，不是推断）

| 时刻 | 事实 |
|---|---|
| 12:14:53 | `[cj-bridge] destroy: host thread still running, handle kept`——事件循环结束、宿主开始销毁 |
| 之后 | 窗口**仍可见**（`hwnd=854120`，最大化），进程**仍在** |
| 之后 | 页面发 `js -> native` **467 条**，原生回投 `ExecuteScript` **0 条** |

即：C 桥的消息通道还在（听得见），回投要走的 `ExecuteScript` 随事件循环一起没了（说不出）。
所有 invoke 的 Promise 永不 settle ⇒ 不弹框、不报错、连 `prompt` 兜底和 `.catch` 都走不到。
**这是"静默失败"里最难查的一种：界面看着完好无损。**

### Added

- **后端心跳与失联横幅**（`assets/ui/index.html`）：每 5 秒 `system:ping`，连续 **3 次**无回包
  （≈15s）判失联，顶栏亮红条：「后端已停止响应，连续 N 次心跳没有回包…请关闭后重新启动灵渠」。
  单次没回包**不算**（长回合时 IPC 会短暂排不上，与 §4-103 同口径）。判失联那一刻立刻
  `reportUi('backend-lost')` 落一份证据——此后 IPC 全哑，再等就没有第二次上报机会。
- **判据纯函数化 + 自检**：`backendVerdictOf(miss, ageMs)`；`LINGQU_UI_PROBE=backendlost`
  单独验判据与横幅（0/1/2 次不许判失联、3 次必须判、恢复后横幅要收回）。
- **`ui_report` 新增 8 个字段**（两处一起加，§4-60）：`backendLost / backendMiss /
  backendOkBeats / backendAgeSec / backendWhy / backendNote / backendProbe / backendProbeFail`。

### Changed

- 版本号三处升 `0.39.90`。

### Fixed

- 用户所见的「点『选择…』不弹框」：重开应用后目录框正常（`dialog: kind=6` → `ok=0` 取消、
  `pickerUsed=1`）——即**不是按钮的问题**，是僵尸窗口。应用侧现在会自己说清这种情况。

### 回馈上游

- `atomgit.com/qq8864/cj-tauri` **issue #8**：`cj_plat_fini` 因宿主线程仍在跑而早退后，
  窗口既不 `DestroyWindow` 也不回收句柄，且 `dispose()` 返回 `Unit` 不给调用方任何
  "没做成"的信号 ⇒ 留下看得见的空窗口、进程不退出。建议早退也收窗口 / `destroy` 回状态 /
  给宿主线程一个上界。

### 已知未验

- 失联判定**没有在真僵尸窗口上端到端验过**（造假僵尸要杀掉事件循环，探针里不做）：
  实测到的是「心跳正常时 `backendAgeSec` 是个位数、`backendProbe=1`」。真断线那一刻的
  表现留待下次实际撞上时对账。
- 三个样本的可用率仍是**旧口径**数字（见 0.39.89），本轮未重跑。

---

## [0.39.89] - 2026-11-08

**主题**：**可用率 100% 是假的**——拿"装配跑通了"当"核心功能可用"。用户实测
（`C:\Users\yang\Desktop\test\m3u8dl-tauri`）落档写着 `ratePercent=100 / total 6 / unknown 0 / limit 1`，
而真机上**选择文件、保存目录两个按钮点了没反应**。查下来两件事：

1. **分母口径错了**：分母是 `清单项 − 平台限制`，而 8 条清单里**没有一条**是"某个核心功能真的能用"——
   launch/build/hap 是**装配**跑通，`platform-api` 因为登记了 `rfd::FileDialog` 反被**剔出分母**
   （§4-63 的反向坑加重版：越不可用越不影响分数）。
2. **"降级方案落没落地"没人判**：`rfd::FileDialog` 在 `commands.rs` 里的鸿蒙分支是
   `#[cfg(all(target_os = "linux", target_env = "ohos"))] pub async fn pick_folder() -> ... { None }`
   —— 等于没实现，前端 `if (p) {...}` 拿到 `None` 就静默什么都不做。这**不算**平台限制，算不可用。

### Changed
- **A4 可用率口径换成分核心功能清单**（`src/verify/verify.cj`）：
  - 分母 = **有结论的项**（`stats.covered` = pass + fail），未测单列 `stats.notVerified`，
    另加 `stats.scope`（`features` = 按核心功能清单算 / `gates-only` = 没扫过时退回装配口径）。
  - 每条 IPC 命令（scan 的 `items.commands[]`）生成一条功能清单项；判据三档：
    人测过 → 以人为准（`pass`/`fail`）；命中平台 API 且鸿蒙分支是空壳 → `fail` 并点名；
    其余无证据 → `unknown`（**未测就是未测**，不许算通过）。
  - `platform-api` 项：只有**降级方案真的落地**（命中它的命令在鸿蒙侧都有实现）才记 `limit`，
    否则 `fail` 并列出未落地的那几处。
  - 聚合的 `ipc` 项不再用「应用起来了」判 `pass`（旧版据此判通过，正是 100% 的来源）。

### Added
- `src/verify/verify.cj`：源码级判据纯函数 `fnImplsOf` / `ohosImplStubOnly` / `firstApiHitIn` /
  `bodyRangeOf` / `unwrapToValue`——认 `#[cfg(...)]` 分支归属（`not(...)` 里的 `ohos` 不算鸿蒙分支）、
  认 `None` / `return None` / `Ok(None)` / `todo!()` 这几种"写了等于没写"。
- `src/verify_feed.cj`：`scanSurfaceOf()` 把 **scan 落档 + 工程源码 + 人工实测结论** 汇成清单输入；
  人工结论读 `<工程>/.lingqu/verify/<工程>.human.json`（`{ "pick_folder": "fail" }`），**人测永远优先**。
- `t2h:verify` 回投新增 `covered` / `notVerified` / `scope`；报告与矩阵、⑥ 屏、`ui_report`
  （`verifyCovered/verifyNotVerified/verifyScope`，两处一起加，§4-60）全部同步。

### Verified（2026-11-08，本机实跑）
- 单测：`cjpm test` **TOTAL 438 / PASSED 438 / FAILED 0 / ERROR 0**；`cjpm build` **零警告**。
- 口径用例覆盖：`Ok(None)` 包装也算空壳、`#[cfg(not(...))]` 不被误判成鸿蒙分支、
  `pick_folder` 不误命中 `pick_folder_extra`、鸿蒙侧写了真实现就要判"落地"。
- 未验证：**③④⑤ 闸（`cj-tauri check` / 骨架侧 build / cli build）本轮没跑**——用户在真机测试期间，
  第 ④ 闸会 `taskkill` 本仓 `main.exe`（§4-72）；且 `cj-tauri.toml` 改了版本号，需先 `sync desktop`
  + `sync ohos`。新口径在**真机**上的取值也还没复核（`src/verify/verify.cj` 本体与取数层只有单测证据）。

---

## [0.39.88] - 2026-11-08

**主题**：**同一块屏幕上，提示语和左栏互相打脸**。用户实测：「换了工程（m3u8dl-tauri）：这里还没跑过」
——可左侧六个徽标全写着「已完成」。查下来**左栏是对的**（它读 `.lingqu/<步骤>/<工程>.json`，那个工程
确实有 scan/deps/port/build/hap/sign/report 落档、只是没有 deploy/verify，所以 `verify=未开始`），
**错的是那句提示**：换工程时**无条件**写「这里还没跑过」，根本没看新工程有没有旧档。

### Fixed
- 换工程提示改为按**落档实况**三档生成（读的是**同一次** `t2h:resume` 结果，与左栏徽标同一份数据）：
  - `has-record`：`这个工程有旧落档（N 步做过：…）。可以直接接着用；要全部重来就点「↻ 从头重跑」把旧档归档。`
  - `empty`：`这里还没跑过。填好路径点「🤖 开始 AI 自动迁移」。`
  - `unknown`：`读不到这个工程的旧落档，没法判断这里跑过没有（原因）——左栏徽标此刻也可能不准。`
  - 上一次迁移还在跑时（`wasActive`）保持原提示不动：「上一个工程那次**没有被停止**」。
- `ui_report` 新增 `switchNoteKind` / `switchNoteSteps` / `switchNoteOk` / `switchNoteFail`
  （前端 `reportUi` 与后端白名单**两处一起加**，§4-60）。

### Added
- 自检 `LINGQU_UI_PROBE=switchnote`：切到有全套落档的 `habit-tree` 必须说「有旧落档」、切到没有任何
  `<工程>.json` 落档的 lingqu 工程根必须说「这里还没跑过」、最后切回真实工程复核（收尾不留假路径，§4-137）。

### Verified（2026-11-08，本机实跑）
- 红（修前）：`switchNoteOk=0`，
  `switchNoteFail=① 有落档的工程没说"有旧落档"（换了工程（habit-tree）：这里还没跑过。…） | ③ 切回真实工程后提示仍不对（…）`
  （② 通过——"没落档"那档原文案本来就是对的）。
- 绿（修后）：`switchNoteOk=1` / `switchNoteKind=has-record` / `switchNoteSteps=7`，与左栏
  `profile/deps/port/build/report=已完成 + verify=未开始` 逐项吻合。
- `./scripts/test.sh` 六道闸全绿（`cjpm test` TOTAL=432 / FAILED=0 / ERROR=0）。
- 未验证：`unknown` 那档（读不到断点板）没有可造的样本，只有代码路径；未在鸿蒙真机上复核文案。

---

## [0.39.87] - 2026-11-07

**主题**：**"AI 说跑完了，屏上还是空的"**。用户实测原话：「执行 AI 自动迁移后会自动执行左侧的
迁移画像和依赖扫描等操作，但各个项里面的内容没有更新，看到的可迁移度等仍是空的」。
根因：① 迁移画像 / ② 依赖扫描两屏**只认人点按钮**（`btnScan` / `btnDeps`）才渲染；AI 通过
`lingqu-cli scan|deps` 把落档写得整整齐齐，界面却没人去读。于是"AI 说扫描已完成"与"可迁移度空白"
同时成立——最容易被当成"AI 根本没干活"的那种分裂。

### Added
- `t2h:scan` / `t2h:deps` 新增 `action: "load"`：**纯读盘回投落档，不重跑扫描**
  （`scanRecordResponse` / `depsRecordResponse`）。为什么不直接重跑：重跑得到的是"现在这一刻的数"，
  用户拿它去对 `.lingqu/scan/<工程>.json` 就会对不上——本项目最怕的正是这类"屏幕与落档不同代"
  （§0.1「落档说了算」）。落档不存在时 `ok=false` + `loaded=false` + 说明原因，**绝不把"没跑过"
  渲染成"扫描失败"**（§4-63 同族）。
- 进 ① / ② 屏自动按落档回填（`fillStepFromRecord`）。
- AI 迁移轮询里检测「某步刚有结论」（`MigrateRow.ran` 由假变真）→ 立刻回读该屏
  （`syncStepsFromRows`）；换工程时 `STEP_SEEN` / `STEP_FILL` 一并清空，避免旧记忆挡住新工程。
- `ui_report` 新增 `scanScore` / `depsRows` / `stepFillN` / `stepFillLast` / `stepFillErr`
  （前端 + `UiReportCommand` 白名单两处一起加，§4-60）。断言口径：`stepFillN>0 ∧ scanRows>0`。

### Known gaps
- **构建 / HAP / 装配 / 部署 / 验证** 五屏尚未提供同类 `action:"load"`：它们的落档形态各自不同，
  且"回读"必须避免触发重编/重装。本轮只覆盖用户报障点名的 ① 迁移画像与 ② 依赖扫描。
- 回读行为**未实机目测**：本轮验证到"编译通过 + 六道闸全绿 + 页面脚本语法通过"。

---


**主题**：**"换了个工程，上一轮的运行态还挂在那儿"**。用户实测原话：「在上次完成移植的基础上
重新选了个新项目，但 AI 自动迁移还是上次执行完的状态，不能点」。
两条根因叠在一起：① `#btnAiPort` **只在启动失败 / invoke 异常**两个分支恢复可用，一旦 AI 接手就
再没有任何一处把它置回 `false` —— 整个进程生命周期内它都是死的；② `setCurrentProject()` 只换
路径回显 + 顶栏胶囊 + 左栏徽标，**运行态一个字没清**：进度条、时间轴、结果卡、AI 过程消息，
以及 ⑤⑥⑦ 三屏的数据面板全都还挂着上一个工程的数字。

口径：这些面板是「**这一轮、在这个工程上**观测到的结果」，换了工程就等于「这里还没跑过」——
宁可不显示，也不许把上个工程的数字摆在新工程名下（与 §4-94「不许拿示意值冒充数据」同族）。

### Fixed
- **换工程即清运行态**（`resetProjectRunState`，经 `window.__onProjectSwitch` 桥由外层
  `setCurrentProject` 调用，§4-107）：停掉迁移/AI 两条轮询 → `AIP`/`MIG` 归零 → 进度条、时间轴、
  结果卡、AI 过程消息回到"没跑过" → `#btnAiPort`/`#btnMigrateStart`/`#btnAiPortReset` 恢复可点、
  `#btnMigrateStop` 只在监管态真在跑时留着 → `BUILD`/`HAP`/`SIGN`/`DEPLOY`/`VERIFY`/`REPORT`
  清成空对象并由快照还原 ⑤⑥⑦ 面板占位 → 左栏徽标按新工程重读落档。
- **判据用 `normPathKey`**：`E:\x` 与 `E:/x` 是同一个工程，直接 `===` 会把"重复设为同一工程"也当成
  切换、把面板白白清掉（§4-95 同族）。
- **逐步覆盖态（✎ 单独指定别的工程）一并清掉**：它跟着旧工程名走会指向错误目录。
- **监管态还活着时不许悄悄当它没发生过**：切换时若 `AIP.active` 为真，面板照样按新工程重置，
  但提示里明写「上一个工程那次迁移**没有被停止**」，「停止」保持可点。
- **不再"停了/跑完了就再也起不来"**：`renderAiPort` 在 `finished===true || active===false` 时恢复
  按钮；点「停止」时也恢复——这是"换工程"之外的同一条问题的另一半。

### Added
- `ui_report` 新增 `projSwitches` / `projResets` / `projResetActive` / `aiPortBtn` / `uiErrors`
  （前端 `reportUi` 与 `UiReportCommand` 白名单**两处一起加**，§4-60）。
  断言口径：`projSwitches>0 ∧ projResets==projSwitches ∧ aiPortBtn=1`。
- 自检 `LINGQU_UI_PROBE=projswitch`：伪造"上一轮跑完的现场"（按钮禁用 + 面板有值 + 监管态 finished）
  → 换工程 → 断言按钮恢复、`AIP` 归零、`hapBuilt`/`migratePct`/`verRate` 回到占位、「停止」置灰、
  提示含「换了工程」；再伪造 `AIP.active=true` → 换工程 → 断言「停止」**不**置灰、提示含
  「没有被停止」。结论回投 `projSwitchOk` / `projSwitchNote`。

### Known gaps
- `LINGQU_UI_PROBE=projswitch` 已写、**未在实机跑过**；本轮只验证到"页面脚本语法通过 + 门禁全绿"。

---


**主题**：**"报告写着 66%，落档写着 100%"**。用户看着 ⑦ 迁移报告问「核心功能可用率
（A4 ≥80%）怎么还是 66%」。核账：`.lingqu/verify/rust-music-2.json` 与
`.lingqu/report/rust-music-2.json` **都是 21:19 生成、都是 100%**（3/3 通过）。
真值没错，错的是**界面那一代快照**——⑦ 屏的报告只在「点生成迁移报告」或「AI 迁移收尾」时
渲染一次，⑥ 屏把验证从 66%（18:19，`launch` 判 fail）重跑到 100% 之后，没人叫它重出。
可观测证据就在 `.lingqu/ui-report.json` 里自相矛盾：`verifyRate: 100` 与 `reportRate: 66` 并排。

### Changed
- 进 ⑦ 屏先校正报告新鲜度（`autoReportOnEnter`）：key 收「工程路径 + ⑥ 屏当前可用率」，
  没出过 / 又验证过一次 / 换了工程 → **自动按落档重出**（纯读盘、秒级），反复切屏不重复写盘。
  ⑥ 屏 `t2h:verify` 成功后把报告标脏（`REPORT_AUTO.key=''`），下次进屏即重出。
- 面板头像：`rpTime` 除了「生成于 …」再显示「进屏自动重出 N 次」；报告与落档不同代时
  `rpNote` 直接说清「这份报告是旧快照：它按 66% 算的，而 ⑥ 屏最新落档是 100%」。

### Added
- `ui_report` 新增 `reportStale` / `reportGeneratedAt` / `reportAutoCount`（前端 `reportUi` 与
  `UiReportCommand` 白名单**两处一起加**，§4-60）——"报告与落档同代"从此可断言。
- 自检 `LINGQU_UI_PROBE=reportstale`：进屏自动重出 → `reportAutoCount ≥ 1`、`reportGeneratedAt`
  非空、`reportStale=false`；再把「⑥ 屏可用率」临时改成落档不可能给的值 7 → `reportStale` 必须
  变 `true`；还原后回到 `false`（测判定逻辑，不往落档里塞假数）。

### Verified（补充，2026-11-08）

把上面写着"未验证"的那部分跑掉了：**代码未变**，只起窗口跑探针取数
（明细见 `docs/进度记录.md`「0.39.87-补充验证」）。

- ①② 屏按落档回填：`LINGQU_UI_SCREEN=profile` → `stepFillN=1` / `scanScore=77`
  （与落档 `score.total=77` **逐字一致**）/ `scanRows=7`；`=deps` → `depsRows=523`
  （落档 `items` 523 条）。判据 `stepFillN>0 ∧ scanScore>=0` 达成。
- `LINGQU_UI_PROBE=projswitch` → `projSwitchOk=1` / `projResets=4` / `aiPortBtn=1`、无失败项。
- `LINGQU_UI_PROBE=reportstale` → 三段 `false → true → false` 全对；
  **前提是样本必须带可用率落档**，否则该探针假绿（§4-136）。
- `LINGQU_UI_PROBE=store` → 写 `localStorage` 抛 `SecurityError`（源为 `about://`），
  与 §4-107 记录一致：本应用"记住偏好"只能走落档通道。
- 仍未验：③–⑦ 屏的 `action:"load"`（构建/HAP/装配/部署/验证/报告），以及 AI 轮询里
  `MigrateRow.ran` 假→真跳变触发的回读（要真 agent 跑一轮，分钟级）。

---

## [0.39.84] - 2026-11-07

**主题**：**"修好了，应用却还在跑旧引擎"**。用户追问「修复的 cjh 替换 vendor 下的没」——
一核对：`vendor/cjh/win-x64/cjh.exe` 仍是上游 1.6.12 官方版（SHA256 `2cb384f0…`），
超时杀树那笔（PR #12 / 分支 `fix/bash-timeout-kill-process-group` @ `9a4f6d5`）只活在本机
cjh 仓的构建产物里。也就是说 **应用一直在跑没有修复的引擎**：`find / -maxdepth …` 这类命令
超时后仍挂在孤儿管道上，界面停在「执行中」不动。

### Changed
- `vendor/cjh/win-x64/cjh.exe` 换成 `9a4f6d5` 的本地构建（13,769,216 B，SHA256 `7dda9caf…`）；
  4 个随行 DLL 不动（与 1.6.5 逐字节相同）。
- `src/cjh_host.cj` 的 `CJH_VENDOR_FILES` 常量与 `vendor/cjh/SHA256SUMS` **同步新值**——
  两处必须一起改，否则 `cjhVendorVerified` 判不过、引擎直接不启用（§2.3「验不过绝不执行」）。

### Fixed
- `t2h:cjh_status` 的 `binPath` **谎报**（换引擎时顺手抓到的）：安装目录里留着**内容不符的旧副本**
  （`cjhBinPathResolve` 会跳过它、绝不执行）时，旧实现按"哪条路径可读"回投，界面报出的是那个
  **没在跑**的旧副本。现在优先回投**本应用实际拉起的**那个二进制（新增 `gCjhBinUsed`，配合
  `gCjhOwned`），复用的是别人的实例时不采信它。实测现场：界面说
  `AppData\Local\lingqu\cjh\cjh.exe`（11-02 旧货 `07f5427a…`），进程实际是
  `vendor\cjh\win-x64\cjh.exe`（`7dda9caf…`）。新增单测 `testKnownBinPathPrefersLaunchedBin`。

### 证据
- 修复特征串：新二进制含 `sessionPgFile`(2 处) 与 `/tmp/cjh-sess-`(1 处)，官方版两者皆 **0**。
- `./vendor/cjh/win-x64/cjh.exe --version` → `cjh v1.6.12`：**版本号没变，光看版本区分不出来**。
- 逐文件 SHA256 与 `SHA256SUMS` 五项全 OK（`cjh.exe` = `7dda9caf…`）。

### 构建口径（下次换二进制别再撞）
- cjh 的 `cjpm.toml` 只声明了 Linux 的 `[target.x86_64-unknown-linux-gnu.bin-dependencies]`；
  `scripts/winbuild.sh` 追加的键是 `x86_64-pc-windows-gnu`，而 cjpm 报「该 target 等价于本地
  target `x86_64-w64-mingw32`」走原生编译 ⇒ 追加段不被采信，报一串
  `imports package 'stdx.encoding.json' … not added as a dependency`。
  要**根包 + `libs/*` 五个子包**都补 `[target.x86_64-w64-mingw32.bin-dependencies]`，
  且 toml 里的路径必须写 **Windows 形式**（`D:/…`）——cjpm 是原生程序，不认 MSYS 的 `/d/…`。
- 本机 `x86_64-w64-mingw32-strip` 是调 `llvm-strip` 的壳而 llvm-strip 缺失 ⇒ 改用
  `objcopy.exe --strip-all` 裁剪（38,822,400 → 13,769,216 B）。

### 未验证
- 超时杀树的**实际效果**本轮未复验（行为验证在 cjh 仓侧；本仓只保证「发出去的是含修复的二进制」）。
- Linux 侧 `vendor/cjh/linux-x64/cjh` 未动，仍是官方版 ⇒ 两平台随包引擎**进一步分叉**（如实记）。

---

## [0.39.83] - 2026-11-07

**主题**：**"工具明明有能力，任务书没写"**。用户实测后一句点破：cjh 拿到任务书却不知道
该走登录/签名这条路，最后**自己拉了个外部浏览器**让用户登录 AGC 网页——可那条路拿不到
本机回调的 `tempToken`、也不会把设备注册进 profile，签名照样过不了，纯白花一次人工介入。

查证结果：`lingqu-cli sign --login` 与 `sign --auto` **本来就存在**（`src/cli.cj` 的帮助里
写得很清楚，`--auto` 一条命令跑完 设备→证书→profile→写回），但 `buildAutoPortDirective`
的工具箱只写了 `sign --path .`，半自动「只做签名」那一步更是只有一句"体检 + 写回"。
**能力在手、说明书没给** = agent 只能瞎摸。

### Fixed

- **任务书补「签名与登录」整节**（`buildAutoPortDirective`）：顺序写死
  `sign --path .`（体检）→ `sign --login`（人授权一次）→ `sign --auto --path .`（注册设备/证书/profile/写回）
  → 重跑 `hap`；并写明「有 signed.hap ≠ 能装」，判据是 `mode` / 材料 / profile 里的 `device-ids`。
- **明确禁止 agent 自己开浏览器登录**：`start` / `rundll32` / `open` 一律不许，理由写清
  （拿不到本机回调 `tempToken`、不注册设备，白花一次人工介入）；要人登录时必须用
  `lingqu-decision` 块一次说清 **为什么必须登录 / 点哪里 / 本机 UDID 是多少**。
- **报错对照表进任务书**：`9568320`（没签上）/ `9568322`（**release profile 不含 device-ids 属正常**，
  或 debug 材料缺本机 UDID）/ `00303074`（包名与 profile 不一致）/ `00303242`·`GCM tag mismatch`
  （`.p12` 口令解不开 → `--newKeys`）/ `9568332`（同包名装过另一套签名 → 先 `bm uninstall`）。
- **纪律那条改口径**：原文「release 态装不上（9568322）是正常的，别去修」会把「缺本机 UDID」
  一起当成正常放过；现在两种成因分开写，并在同处指向新的对照表节。
- **半自动 `scope=sign` 同步补齐**：同一份签名知识不许只在全流程分支里（否则"只点签名这一步"
  反而比全自动知道得更少）。

### Added

- 单测 `testDirectiveTellsAgentHowToSignAndLogin` / `testSignScopeDirectiveAlsoCarriesLoginPath`：
  钉住两条入口带绝对路径出现、顺序小节存在、禁止自己开浏览器、四种报错号、以及「不许伪造签名 /
  不许改 `bundleName` 蹭别人 profile」的底线（**TOTAL 429 → 431**）。

### Verify

- ① 业务包 `cjpm build` **零警告**；③ `cj-tauri check` 通过（`com.lingqu.migrator@0.39.83`）。
- ② `cjpm test` **TOTAL 431 / PASSED 431 / FAILED 0 / ERROR 0**（+2 例）。
  注：测试构建另报 **4 条** `possibly confusing line terminator`，出自**既有测试文件**
  （`src/tests/cli_test.cj:113`、`src/tests/build_test.cj:138`，字符串里带 `\n- ` 触发），
  与本轮改动无关，写在文本里以免被当成"零警告"假象。
- ⑤ `cli/` 的 `cjpm build`：**零警告 / exit 0**（不经门禁脚本、直接构建，避开 `kill_own_main_exe`
  对正在实测界面的结束动作）。首次构建曾报 **9 条**同类警告——全部是本轮新写的任务书文本
  把 `+` 写在行首所致（§4 老坑），已改成运算符收在行尾。
- ④ `targets/desktop` 构建**未跑**：产物 `main.exe` 正被用户实测占用，构建会撞
  `Permission denied`（§4-6），门禁脚本还会主动结束它。留到实测结束后补。

---



**主题**：**"做一半停"和"没人告诉你该点哪里"**。用户实测整应用迁移跑到 **回合 62/40** 就停住，
界面只写"回合结束"；同一次还问了"没有提示让我访问网页登录呀"。查下来三件事各自独立：

1. **62/40 是假象**：预算抬升函数返回的是 `file:…（需重启 cjh 生效）`——值写进了
   `~/.cjh/settings.json`，但**正在跑回合的引擎内存里还是默认 40**，于是"抬到 120"等于没做。
2. **引擎被重复拉起**：`/api/health` 在引擎忙时超时 → 被判成"引擎没了" → 又拉起一只；
   Windows 允许重复绑定同一端口，第二只静默"就绪"，现场留下 **3 只 `cjh.exe` 同占 8765**，
   WS 还挂在上一轮的孤儿上。这解释了"过了会儿又自己连上了"（引擎全程没退出）。
3. **登录入口不存在**：登录被塞在一条阻塞命令里（最长 5 分钟），页面拿不到"正在等你登录"、
   也拿不到那条 URL，人只能从 cjh 的聊天文字里猜该点哪里。

### Added

- **轮次预算开跑前自愈**（`iterBudgetStateOf` / `enforceIterBudgetBeforeRun`）：把
  `live:` / `already:` / `restart-ok:` 判为**真生效**，`file:` 一律等于没生效；需要重启才生效的，
  在**开跑前**重启自己拉起的引擎（~0.5s），而不是等跑到中途被 40 轮截断。非本应用拉起的引擎
  按 D-003 不抢不杀，只回投"需人工重启"。
- **预算用完自动续跑**（页面 `AUTO_CONTINUE_MAX = 3`）：回合因预算结束时，若迁移监管态仍在跑
  且未判停滞，自动接着干并上屏说明次数；到上限就明确交回人判断（不无限烧轮次）。
- **`t2h:sign_login` / `t2h:sign_login_status`**：后台登录（命令立刻返回，不占 IPC），
  登录页 URL 通过状态回投；签名屏把链接给成**可点按钮**。
- **`t2h:open_url`**：界面里的链接统一走系统浏览器（`rundll32` / `xdg-open` 按 argv 传参），
  不依赖 WebView 的 `target=_blank`（那种"点了没反应"比没有链接更糟）。
- `ui_report` 新增 `autoContinue` / `signLoginState` / `signLoginUrl`（白名单同步，
  见 §4-60：两处不一起加等于字段不存在）。

### Changed

- **拉起前判据从 Bool 改成三态**（`spawnDecisionOf` → `Spawn` / `Reuse` / `Occupied`）：
  「端口空着」与「有人听但不响应」不再都算"没有引擎"。`Occupied` 时**绝不拉起第二只**，
  只有用户显式点「重启引擎」且引擎是本应用拉起的，才真重启。
- `ensureCjhWeb` / `cjhDeployAndStart` 整段加互斥锁 `gCjhSpawnLock`：探活→判断→拉起是
  读-判断-写，两路同时进来必然各拉一只（实测日志里两条一模一样的"就绪"）。
- `cjh_status` 不再把"有监听但读不到"谎报成 `ready`：如实回 `running + portBusy + 原因`，
  设置页显示「端口有监听但不响应，按在忙处理」。
- 探死要把原因写进 `.lingqu/cjh-start.log`（`gLastHealthErr`），别再靠进程表倒推。

### Fixed

- 回合结束时若最后一条工具报错里出现"登录"，**主动起登录并提示入口**（不再只把输出摆着）。

### Known limitations

- **六闸全绿**：`build-biz / test / check / js-syntax / build-app / build-cli` 六项 PASS，
  `TOTAL=429 / FAILED=0 / ERROR=0`，三处 `warning: 0`。第 ④ 闸补跑时按 §4-92 只结束了
  本仓的 `main.exe`，引擎（`cjh.exe`）未被误杀。
- 登录成功后的 profile/UDID 注册仍依赖华为账号的一次真实登录，未在自动化里伪造。
- 自动续跑 / 登录卡片 / `t2h:open_url` 目前只有编译与语法闸的保证，**还没有 UI 探针证据**；
  `ui_report` 已加 `autoContinue / signLoginState / signLoginUrl` 三项白名单字段，
  但要页面跑起来才有值（接手第一件事：起应用看这三项）。



**主题**：**"跑成功了"和"东西真出来了"是两回事**。rust-music-2 交叉编译 `exitCode=0 / errorCount=0`
被报成通过，可产出的是一份 11 MB 的 **exe**——工程只有 bin target，没有 `cdylib`，HAP 里要的
`lib<name>.so` 压根没生成。同一轮把回滚链路的三个静默失效一起修了：二次 apply 覆盖原始备份、
备份目录相对/绝对不一致（CWD 不是工程目录就永远"没有备份"）、回滚表写死 `src-tauri/`（扁平工程
一个文件都对不上）。三处都是"工具说没备份/没改动，其实是我们读错了地方"。

### Added

- **鸿蒙产物闸**（`checkOhosArtifactGate`）：编译成功但**没有预期的 `lib<name>.so`** 时判失败，
  并按「有没有 `cdylib` 声明」给出不同提示——没有声明就是移植没做完，不是编译参数问题。
  期望产物名由 `expectedLibNameOf`（认 `[lib] name` → 包名 → 工程名）解析，
  `hasCdylibCrateType` 判声明（注释里的 `cdylib` 不算数）。build 结果新增 `expectedSo` 字段。
- **`t2h:port` 落 `decisions.json`**（`decisionsJsonWithPortRun`）：以前只有"记过一条人工决策"
  才会生成它，"这个工程跑过 port 没有"在断点板与 agent 上下文里无从判断（§4-58 的窟窿）。
  现在每次跑完都写 `portRun` 块（apply/applied/auto/human/at/outcomes），`items` 原样保留。
- `portRunAtOf`：从 decisions.json 读"跑过的时刻"（没跑过 → -1）。

### Changed

- **`backupDirOf` 换成两侧共用的绝对路径**（`portBackupDirOf(projectDir, safeName)`）：
  apply 写 `<工程>/.lingqu/port/<工程>`，revert 也要读同一处——以前 revert 用 CWD 相对路径，
  只要 CWD 不是该工程目录，回滚就永远报"没有备份"（§4-33 同族）。
- **回滚表改用布局标记**（`REL_SRC` / `REL_PROJECT` + `resolveRevertTarget`）：不再写死
  `src-tauri/`。传统工程解析到 `<工程>/src-tauri/...`，扁平工程（`src-tauri` 就是工程根）
  解析到 `<工程>/...`；解析不出的（工程里没有 Cargo.toml）返回空串 → 计入 `skipped`，不猜路径。
  单 bin 工程的 `lib.rs` 兜底也从写死 `src-tauri/src/main.rs` 改成按布局取 `src/main.rs`。

### Fixed

- **build 假绿**：单 bin 工程交叉编译成功即报通过，实际没有 `.so`，装不进 HAP。
- **二次 `--apply` 覆盖原始备份**：备份写盘改为"已存在就不写"（与 `backupFile` 同一语义），
  否则备份里存的是迁移态，revert 只会"回滚"成迁移态——回滚能力静默失效。
- **回滚永远 miss**：备份目录相对/绝对不一致（见 Changed）。
- **扁平工程回滚一个文件都对不上**：回滚表硬编码 `src-tauri/`（见 Changed）。

### Verified

- 单测 **427 例全过**（新增 `src/tests/ohos_artifact_test.cj` 4 例 + 回滚/落档 3 例）。
- 实路复验（样本副本 `.lingqu/tmp-verify/rm2`，扁平布局）：
  `port --apply` → 备份 + `decisions.json`（`portRun.applied=2`）落地；**二次 apply 后两份备份
  sha256 不变**；`revert` → `restored=2 removed=2 skipped=[]`，`src/lib.rs` 与备份 sha256 一致，
  `backup` 字段是绝对路径。
- 未验：`config.toml` / `index.html` / `hvigorfile.ts` 三类回滚（样本里没有这几条规则的落盘），
  以及 Linux/macOS 侧同族路径行为。

---

## [0.39.80] - 2026-11-07

**主题**：**agent 卡死一半是我们自己的监管失灵**。rust-music-2 回归时引擎把工具调用挂住 565s+，
灵渠这边既没报停滞、也没给建议——因为「正在跑工具」的豁免**没有时间上限**，
一个挂死的工具可以把停滞判定永久按住。同一轮把上游 cjh 的根因也修了（超时收尾只杀得掉
启动器，孤儿握着管道让 `p.wait` 永挂），并把「禁全盘搜索」写进任务书纪律。

### Added

- `AUTOPORT_BUSY_MAX_SECS = 300` + 纯函数 `busyStillExempt(busySecs, limitSecs)`：
  「正在跑工具」的豁免有上限，超限即恢复停滞判定；`AutoPortState.noteBusy/clearBusy`
  记工具年龄，`t2h:autoport_status` 回投 `busySecs` 作证据（`src/autoport.cj`、`src/main.cj`）。
- 任务书纪律新增「**禁止全盘搜索**」：命令只在本工程目录内；脚手架只有 `<工程>/gen/ohos`
  与 `<工程>/src-tauri/gen/ohos` 两处，都没有就如实报告缺脚手架；预估 >2 分钟的命令先说明理由。

### Fixed

- **监管屏对挂死工具永久沉默**（2026-11-07 实测）：`agentTraceBusy()` 没有时间上限，
  工具一挂死 `busy` 永远为真 ⇒ `clearHistory()` 一路清空 ⇒ 界面只剩「执行中 565s」，
  既不报停滞也不给建议，用户只能自己去任务管理器发现一个 605s CPU 的 `find.exe`。
- 任务书此前没禁止全盘搜索，agent 为找 `gen/ohos` 跑 `find / -maxdepth 6 …`，
  正是把工具调用挂死的直接触发点。

### Changed

- 上游 cjh 同步修复（已提 MR #12）：`killSession()` 改为**按进程组**收尾——
  会话启动让 bash 把 `$$` 写进 `/tmp/cjh-sess-<启动器pid>.pid`，超时时
  `kill -9 -$(cat …)` 连子命令一起收，`taskkill /T` 退为兜底。
  实测 `find / … | head -10` + `timeout 5`：**6.08 s 返回**（旧实现 644s+ 不返回），无残留 `find.exe`。

### Verified

- 业务包 `cjpm build` **零警告**；`cjpm test` **TOTAL: 418 / FAILED: 0 / ERROR: 0**
  （新增 `testBusyExemptHasUpperBound`、`testNoteBusyMeasuresSecondsSinceToolStart`、
  `testDirectiveForbidsFullDiskSearch`）。
- cjh 侧：`build warning: 0`、新增 Windows 用例两条 PASSED、`find.exe` 无残留。
- 未验证：`busySecs` 在真实挂死场景下的端到端读数（需再复现一次 5 分钟以上的工具挂死）。

---

**主题**：**拿 rust-music-2（扁平布局的真实 Tauri 工程）跑一遍全流程，前 4 步连撞三处真 bug** ——
每一处都**不是**工程的问题，是工具把 Windows 路径 / 目录层级 / OHOS crate 的环境要求想当然了。
三处修完，`build` 从「连 manifest 都读不进去」走到 **`ok=true / exitCode=0 / errorCount=0`**。

### Fixed

- **R2-PORT-008 把 Windows 路径原样拼进 TOML 双引号串 → 生成的 `.cargo/config.toml` 是非法 TOML**：
  - **现象**：`t2h:build` 报 `failed to parse manifest at Cargo.toml` +
    `could not parse TOML configuration in …\.cargo\config.toml`、
    `missing escaped value, expected 'b', 'e', 'f', 'n', 'r', '\\', '"', 'x', 'u', 'U'`，`exit=101`；
  - **根因**：`NATIVE_OHOS_SDK` 是 Windows 形态（`D:\oh\…\native`）时，模板直接
    `linker = "${sdk}/llvm/bin/clang"` ⇒ `\o` 不是 TOML 合法转义。**凡是带反斜杠的 NDK 路径必死**；
  - **处置**：新增纯函数 `tomlSafePath()`（`\`→`/`，cargo 在 Windows 同样认正斜杠），
    `cargoConfigToml` / `cargoEnvOnlyToml` 都过它；单测断言"生成内容里一个反斜杠都不剩"。
- **`frontend` 目录按经典布局写死 `srcTauriDir/..`，扁平工程会跑出工程外**：
  - **现象**：`R2-PORT-014` 报「已存在——跳过」（本工程 `ui/` 里根本没有对话框模块），
    `R2-PORT-012` 的 before 证据里出现 `juCang/lingqu-dialog.js:4` —— **上一个样本的文件**；
  - **根因**：扁平布局（`Cargo.toml` 就在工程根）时 `srcTauriDir/..` = **工程父目录**
    `C:\Users\yang\lingqu-workspaces\`，那里躺着 juCang 遗留的 `lingqu-dialog.js`；
  - **处置**：新增纯函数 `frontendDirOf(projPath, srcTauriDir, frontendDist)` —— 只有
    扁平布局改口径（优先 `tauri.conf.json` 的 `frontendDist`，本例 `ui`），经典布局原样返回，
    不动已验证过的样本；**拒绝**绝对/`..` 越界的 frontendDist；
  - **连带**：`t2h:revert` 删这两个资源的路径必须与写入侧同源（改为同一函数 + 兼容历史
    `<工程>/` 残留位置），否则回滚永远删不到（§4-33 同族）。
- **`ohos-arkui-sys` 等 OHOS crate 的 build.rs `expect` `OHOS_NDK_HOME` → build 当场 panic**：
  - **现象**：`thread 'main' panicked: OHOS_NDK_HOME not set`，`exit=101`；
  - **根因**：生成的 `[env]` 段只补了 `CC_/AR_/CFLAGS_`（cc-rs 口径），没有 OHOS 自己的约定变量；
  - **处置**：`[env]` 段补 `OHOS_NDK_HOME`（cargo 的 `[env]` 对 build script 生效 ⇒ 工程自足）；
    `t2h:build` 执行前再兜一层（`NATIVE_OHOS_SDK` 存在且没设就注入），并把兜底值回投
    `result.ndkHome` 当证据 —— 救"已迁移但没重跑 port"的老工程。

### Changed

- `t2h:build` 的返回值新增 `ndkHome`（**两处一起加**：命令层 `o.put` + 落档），空串 = 环境里本来就有。

### Known（本轮实测暴露、尚未处置）

- **`build` 绿了但没有 `.so`**：rust-music-2 只有 `src/main.rs`（bin target），编出来是
  11 MB 可执行文件 `rust-music`，而 OHOS 需要 `lib<模块>.so`（cdylib）。`build` 判据只看
  `exitCode==0`，**不校验产物形态** —— 属"绿了也装不上"的假绿，已记入待办。
- **`t2h:hap` 前置于本机不可满足**：工程无 `gen/ohos` 脚手架，工具提示
  `先用 cargo tauri ohos init --ci 生成`，而本机**没装 tauri-cli**；且无 `com.example.rustmusic`
  的签名材料、真机 `hdc list targets -v` 仍 **Unauthorized** ⇒ hap/deploy/verify 三步本轮未能验证。

---

## [0.39.78] - 2026-11-07

**主题**：**内置 cjh「起得慢」不是引擎慢** —— 实测引擎自身 fork→`/api/health`=200 只要 **85 ms**，
而应用从启动到引擎可用是 **15.5 秒**，慢的全在**拉起之前**的白等上；修完 **613 ms**。

### Fixed

- **拉起前的探活改用纯 TCP「有没有人在听」（`cjhPortListening`）**：
  - **现象**（用户反馈"内置的 cjh 引擎起的这么慢"）：主进程启动 → 引擎进程诞生相隔 15 秒，
    而引擎自己被拉起后瞬间就绪；
  - **根因**：仓颉的 `ClientBuilder` **没有 connectTimeout**（上游 cj-tauri `plugin_http.cj`、
    cjh `web_fetch.cj` 两处注释都记了这坑），目标不可达时卡在 TCP connect —— 端口空着时
    **一次** `/api/health` 就要 **2007 ms**（`.lingqu/cjh-start.log` 实测）；原来拉起前先
    `cjhHealthyWithRetry(port, 6)`，2s + 5×(2s+0.7s) ≈ 15 秒，全花在"确认端口上没人"上；
  - **处置**：先 `TcpSocket("127.0.0.1", port).connect(timeout: 250ms)` 探端口（一个字节都不发，
    不打扰正在跑长回合的引擎）——没人在听就立刻拉起；有人在听才走 `/api/health` 的宽容重试
    （否则会拉起绑不上端口的僵尸，§4-103 那类"连接反复横跳"）；
- **`ensureCjhWeb` / `cjhDeployAndStart` 共用 `cjhCheckBeforeSpawn`**：两处原先各写一份重试次数
  （6 / 4），口径容易走岔；现在只有一处判定。

### Added

- **启动计时证据落档 `.lingqu/cjh-start.log`**（`traceStartup`）：仓颉 `eprintln` **不进应用日志**
  （§4-14），上一版想靠日志看"拉起前花了多久"根本看不到。现在慢的阶段会自己写一行
  `<时刻> <标签> <耗时>ms`，正常启动不刷盘。

### Changed

- 版本号三处一致 0.39.78

### 验证

- **实测（本机 win-x64，2026-11-07）**：同一台机器、同一份产物结构，改前 **15518 ms** / **15528 ms**，
  改后 **613 ms**；落档 `2026-11-07T12:22:08 端口 8765 空着（无监听）→ 直接拉起 0ms`，
  随后 `GET /api/health` → `{"status":"ok","version":"1.6.12"}`；
- 隔离计时：vendor cjh 直接跑 `web --port 8772`，fork→健康检查 200 = **85 ms**（证明慢不在引擎）；
- 单测 `TOTAL: 414 / FAILED: 0 / ERROR: 0`（`installBinUsable` 1 条为新；TCP 探测属 I/O，按 §1-5 不进单测，
  以实机计时为准）。

---

## [0.39.77] - 2026-11-07

**主题**：**「文件在」不等于「内容对」** —— 随包引擎升到 cjh 1.6.12 后，应用却一直在跑
`%LOCALAPPDATA%\lingqu\cjh` 里 11-02 留下的 **1.6.5**；界面完全看不出来（`/api/health` 照样 200）。

### Fixed

- **`src/cjh_host.cj` 的 `cjhBinPath()` 第 ② 档（部署过的安装目录）补 SHA256 校验**：
  - **现象**：本轮启动实测 `/api/health` 回 `{"status":"ok","version":"1.6.5"}`，
    而 `vendor/cjh/win-x64/cjh.exe` 已是 1.6.12（0.39.75 升级，SHA256 常量也换了）；
  - **根因**：第 ② 档只判 `fileReadable(install)` 就 `return`，抢在第 ③ 档（vendor，**校验通过才用**）
    前面命中旧副本 —— 升级后的 1.6.12 永远轮不到执行；
  - **处置**：新增纯函数 `installBinUsable(readable, verified)`（两件都满足才算可用），
    第 ② 档改用它；副本内容不符时**不执行**，并打一行「部署目录副本与随包清单不符，跳过 …（多半是
    升级前的旧引擎残留）」——排查时能看见"为什么不执行"，而不是只剩「引擎缺失」；
- **`cjhDeployAndStart()` 的 ② 档同口径**：副本不符时不再"读得到就拉起"，改为
  **有安装包就 `bsdtar -xf` 重解一次当刷新**（解完再核一次，解包成功 ≠ 内容对），
  没有任何可解来源时如实拒绝：「不执行未校验的二进制」。

### Changed

- `cjhBinPath()` 的文档补齐四档优先级与各自的可信度（① `LINGQU_CJH` 显式指定不校验；②③④ 都要校验）
- 版本号三处一致 0.39.77

### 验证

- **单测**：新增 `testInstallBinUsable`（主路径 / 文件在但内容不符 / 校验过但文件不在 / 两者都不成立）；
  `cjpm test` → `TOTAL: 414, PASSED: 414, FAILED: 0, ERROR: 0`（原 413 + 1）；
- **实机**：重编 `targets/desktop` 后重启应用 —— `Get-Process` 显示引擎路径为
  `E:\test\rust\test1\lingqu\vendor\cjh\win-x64\cjh.exe`，
  `GET /api/health` → `{"status":"ok","version":"1.6.12","web_port":8765}`。

---

## [0.39.76] - 2026-11-07

**主题**：**「已存在就不再拷」把旧 DLL 钉死在产物目录** —— 框架升级后门禁 `cj-tauri check`
退出码 `0xC0000139`（STATUS_ENTRYPOINT_NOT_FOUND）；顺带补验 win-x64 随包引擎。

### Fixed

- **`scripts/collect-runtime-dlls.sh`**：依赖闭包由「缺则拷」（`[ -f "$BIN_DIR/$dep" ] && continue`）
  改为「缺则拷、**内容不同则刷新**」（新增 `same_file()`，有 `sha256sum` 用它、没有退 `cmp`）；
  OpenSSL 两件（`libcrypto-3-x64.dll` / `libssl-3-x64.dll`）同样的跳过逻辑一并改成刷新；
  汇总行增「刷新 N 个」。起因见下：
  - **现象**：`./scripts/test.sh` 的 ③ 闸报
    `[cj-tauri] 三方比对：无头导出退出异常（code=3221225785）`，
    手跑 `targets/desktop/target/release/bin/main.exe` 同样起不来；
  - **根因**：`targets/desktop/target/release/bin/` 里的 `libcjtbridge.dll` 还是 2026-11-02 那份
    （732,160 B），而框架 `native/libcjtbridge.dll` 在 cj-tauri 2.1.2（2026-11-05）已换成 742,912 B；
    Windows 加载顺序里 **exe 同目录优先于 PATH**，于是 `main.exe`（11-07 重新链接）用旧桥 DLL，
    导入符号对不上 → `0xC0000139`。收集脚本按「已存在就跳过」的逻辑，永远不会把旧拷贝换掉；
  - **处置**：脚本改成按内容比对刷新；本次现场用 `--clean` 重收一遍（新拷 46 个），`check` 立刻通过

### Changed

- `scripts/run-dev.sh` 的提示语由「幂等，只补缺的」改为「幂等：缺则拷、内容不同则刷新」
- 版本号三处一致 0.39.76

### 验证

- **回归**：把产物里的 `libcjtbridge.dll` 故意换成 `libssl-3-x64.dll` 的内容 →
  脚本报「刷新 1 个」，哈希回到与框架 `native/libcjtbridge.dll` 一致（`d4f3dc43…`）；
- `cj-tauri check` → `[cj-tauri] check 通过：com.lingqu.migrator@0.39.76`；
- **win-x64 随包引擎补验**（0.39.75 遗留的未验证项）：5 个文件 SHA256 与 `CJH_VENDOR_FILES`
  逐条一致；`cjh.exe --version` → `cjh v1.6.12`；`web --port 8772 --bind 127.0.0.1` +
  `GET /api/health` → 200 `{"status":"ok","version":"1.6.12"}`（验完收进程，未动 8765）；
- 六项门禁见 `docs/进度记录.md`。

---

## [0.39.75] - 2026-11-07

**主题**：**随包引擎升级 cjh 1.6.5 → 1.6.12**（vendor 两平台 + SHA256 校验链 + 灌包脚本）。

### Changed

- **`vendor/cjh/linux-x64/cjh`** 替换为 cjh v1.6.12 官方产物
  （`cjh` 仓 `dist/cjh-v1.6.12-linux-x64.tar.gz`，18,485,672 bytes，
  SHA256 `028992be…2dfbf`）；`--version` → `cjh v1.6.12`
- **`vendor/cjh/win-x64/`** 五件套同步 `dist/cjh-v1.6.12-windows-x64-selfcontained.zip`：
  `cjh.exe` 13,754,880 bytes（SHA256 `2cb384f0…23cb7`）；**4 个随行 DLL 与 1.6.5 逐字节相同**
  （`libboundscheck` / `libcangjie-runtime` / `libssl-3-x64` / `libcrypto-3-x64` 未变，故只有 exe 需要换）
- **`src/cjh_host.cj`**：`CJH_VENDOR_FILES` 的 `cjh.exe` 常量与 `CJH_LINUX_SHA` 同步到 1.6.12；
  校验注释按实际形态写成「5 个文件」
- **`tools/vendor-cjh.sh`** 修两处陈旧处：① Windows 清单补 `libboundscheck.dll`（1.6.5 起是五件套，
  脚本仍按四件套检查，会灌出缺文件的自校验不过目录）；② `--source` 支持直接喂 cjh 官方归档
  （`.zip` / `.tar.gz`）并自动把归档里的 `cjh-windows-x64.exe` / `cjh-linux-x64` 改名成
  `cjh.exe` / `cjh`——此前必须先手工解包改名
- 文档同步：`vendor/cjh/README.md`（版本表 v1.6.1 → v1.6.12、文件表补第 4 个 DLL 与大小、
  升级命令改成喂官方归档）、`packaging/README-run.md`（引擎 1.6.12、校验文件数五个）
- 版本号三处一致 0.39.75

### 验证

- 常量与盘上二进制逐条比对：`win-x64/cjh.exe` 与 `linux-x64/cjh` 的 SHA256 与源码常量**逐字相同**
  （DLL 未变，四条常量照旧成立）
- **实跑**：`vendor/cjh/linux-x64/cjh --version` → `cjh v1.6.12`；
  `cjh web --port 8771 --bind 127.0.0.1` → `GET /api/health` 200，
  `{"status":"ok","version":"1.6.12","web_port":8771}`
- 六项门禁见本轮 `docs/进度记录.md`；**win-x64 仍是「换好了未在 Windows 实机跑过」**
  （本机只有 Linux，实机验证待 Windows 会话补，`cjh.exe --version` 属纯 exe 执行，风险低但未取证）

---

## [0.39.74] - 2026-11-05

**主题**：「用户级认知层」方案落档（飞轮 §8 阶段 4）——不登录、不贡献，飞轮照样转。

### Changed

- **`docs/AI自进化飞轮.md` §8 新增「阶段 4：用户级认知层」方案**（方案已定，待实现）：
  - **问题**（2026-11-03 用户提出）：指纹/规则编译在代码里、skills 在仓里——没登录 atomgit
    或不想提 PR 的用户，经验只对当前工程有效，出不了"跨工程自动吃上"的全局认知；
  - **方案**：裁决入库三轨——① 本工程 notes（已有）② **用户级认知层
    `~/.lingqu/flywheel/`**（fingerprints.json / rules.json / skills，离线零登录，内置库 +
    用户库合并、id 冲突用户级优先）③ 公共仓 PR（可选分享，degraded/canSubmit 双轨已就绪）；
  - **实现落点**：4.1 加载合并（`fingerprintLibrary()` + 规则加载，纯函数可单测）、
    4.2 `archive` 加目标参数（`--to user` 默认 / `--to repo`）、4.3 回流复用 `t2h:skill`
    （零新增）、4.4 团队共享 = 整目录拷贝/私有仓同步（无代码）；
  - 与"永远不做"清单互补不冲突：用户级入库同样要过人工闸门；及格判据 = 全程离线完成
    "迁移 → 撞坑 → 经验 → 裁决入库 → 下个工程命中用户级指纹"整链
- **需求追踪 C7 行登记阶段 4 方案**；**README 飞轮章补一句**：不登录不贡献飞轮照样转
  （默认去处 = 用户级认知层，PR 是可选分享）
- 版本号三处一致 0.39.74

### 验证

六项门禁全绿（纯文档改动）。

---

## [0.39.73] - 2026-11-04

**主题**：README 突出「HAP 包自签名机制」特色——纯仓颉实现、全程摆脱 DevEco Studio，一键迁移到真机运行。

### Changed

- **「30 秒了解」表新增特色行**：HAP 包自签名机制（纯仓颉实现，全程摆脱 DevEco Studio）——
  本地签名链（纯仓颉 AES-128-GCM 解密口令 + 调用 hap-sign-tool）与 AGC 云生成双路线，
  `sign --auto` 一条命令 → `signed=true` + 真机装机启动；**迁移的最后一公里不依赖任何重型 IDE**
- **能力矩阵行强化**：「自动签名（路线 A：AGC 云生成）」→「**HAP 包自签名（AGC 云生成 +
  本地签名链）**」，补实现落点 `compiler/sign_*.cj` 与签名两态自动判定（debug/release）+
  上架前强提醒
- 版本号三处一致 0.39.73

### 验证

六项门禁全绿（纯文档改动）。

---

## [0.39.72] - 2026-11-03

**主题**：README「为什么是它」章补 FAQ——「为什么不做成命令行或纯 skills 形式？」。

### Changed

- **「为什么是它」章末尾新增追问段**，回答口径（命令面其实保留了——`lingqu-cli` 20 条子命令
  给 AI 用；这里回答"给人的形态"为什么是桌面可执行工具）：
  - **纯 skills 通用但雁过不留痕**：静态文档感知不到移植全貌与生命周期；用户要自己挑
    agent、装环境、找技能、配集成，碎片化高；知识沉淀复用靠人维护
  - **纯 CLI 对人不够友好**：证据要自己翻 `.lingqu/` 落档，全景/断点/风险分级没有一眼可见的地方
  - **桌面可执行工具全包了**：使用简单、功能全面、**内置智能体（cjh）开箱配置好密钥即可用**
    （SHA256 + 自动拉起，无需装运行时）、落档即证据、断点续迁、**数据飞轮进化机制内建**；
    CLI 面仍在（给 AI 与自动化），人面对的是工作台不是一堆命令
  - **顺带说明：skills 本项目也有**（`skills/t2h-ohos-port/`，飞轮回流通道会装进 agent 技能库）——
    skills 之上还有**可视化工作台、迁移画像、依赖扫描矩阵、六项门禁与数据飞轮**这些 skills
    做不到的层，工具是"skills + 工程 + 可视化 + 飞轮"的整体
- 版本号三处一致 0.39.72

### 验证

六项门禁全绿（纯文档改动）。

---

## [0.39.71] - 2026-11-03

**主题**：README 架构章新增 FAQ——「为什么不集成 Claude Code / OpenCode 这类通用 agent，而非要 cjh？」。

### Changed

- **README「与 cjh 的关系」段后新增 FAQ**，回答口径先拆层再论据：
  **模型层本来就是开放的**（cjh 是 harness 不是模型，设置页可选 openai 兼容 / anthropic
  接入协议，DeepSeek / OpenAI / Gemini / 通义随便接）——被选定的只是 **harness 层**，
  换通用 agent CLI 撞四堵墙：
  1. **鸿蒙 PC 可运行性（决定性）**：通用 agent CLI 依赖 Node/Python 运行时，鸿蒙 PC 跑不了——能跑在鸿蒙 PC 的仓颉 agent 引擎 cjh 是唯一路线；
  2. **小巧可内嵌 + 协议干净（项目思路成立的前提）**：通用 agent 动辄数百 MB（自带运行时）、接入协议各不相同；cjh 单文件 ~18MB、标准 REST+WS（就绪判据一条），与外壳同栈、桌面产物一个 main.exe——「桌面工作台内置完整 agent」的思路因此成立；
  3. **编排件共同设计**：任务书 / 失败现场拼提问 / 轨迹观测 / 停滞判定 / 轮次预算 / 审批卡 / 技能回流 / 经验四段式落档，与落档证据体系咬合，换 harness 全部重做；
  4. **安全与可控**：只绑 127.0.0.1（不少 harness 默认 0.0.0.0 无鉴权）、SHA256 不过不解包不执行、token 只走环境变量；MIT 自有仓，issue/PR/fork 分支回馈闭环已实测（`docs/上游回馈-cjh.md`）
- 版本号三处一致 0.39.71

### 验证

六项门禁全绿（纯文档改动）。

---

## [0.39.70] - 2026-11-03

**主题**：README 考核信息补「技术基础」——点明项目站在 cj-tauri / cjh 两个已开源项目之上（进度合理性的来源）。

### Changed

- **README 考核信息小节加「技术基础」行**：外壳/UI 框架 [cj-tauri](https://atomgit.com/qq8864/cj-tauri)
  与 AI 引擎 [cjh](https://atomgit.com/qq8864/cjh)（均本人开源、MIT、已真机验证）——
  **不复刻基础件、聚焦迁移工具链本身**；
- **进度描述补基座说明**：外壳与引擎为已开源成熟底座，本项目在其上做迁移工具链层
  （8 步流水线 + 鸿蒙真机验证 + 4 个应用迁移），避免"进度快 → 项目简单"的误读；
- 版本号三处一致 0.39.70

### 验证

六项门禁全绿（纯文档改动）。

---

## [0.39.69] - 2026-11-03

**主题**：README 新增「📋 项目考核信息」——交付时间 2027-02-13 / 当前进度 60% / 进度描述（60 分口径）。

### Changed

- **README 顶部插入考核信息小节**（英文 TL;DR 之后、30 秒了解之前）：交付时间 **2027-02-13**、
  当前进度 **60%**、最后更新 2026-11-03；进度描述按 60 分口径如实撰写——
  核心工具链（8 步流水线 + 内置 AI 引擎）已开发完成并经鸿蒙 PC 真机验证、4 个真实应用完成迁移
  （3 个已出可用率报告 100%/100%/85%，rust-music 移植成功取证中）；
  剩余 40% = 三项验收收尾（飞轮无人干预闭环实证 / 规则库多样本压力测试 / 鸿蒙原生能力位矩阵），
  任务清单指向 `docs/需求追踪.md` §五
- 版本号三处一致 0.39.69

### 验证

六项门禁全绿（纯文档改动）。

---

## [0.39.68] - 2026-11-03

**主题**：**需求追踪落「验收风险清单」（60 分口径）**——把完成度评估的三条差距转化为可执行的验证任务。

### Changed

- **`docs/需求追踪.md` 新增 §五「验收风险清单」（60 分口径，2026-11-03 用户评估）**，原维护规则顺延为 §六。三项验证任务（**不是新功能开发**——是把已有机制放到真实压力下取证）：
  - **R-1 飞轮闭环实证**（对应 A1/A3 附加口径，证据为零）：零人工干预跑一轮迁移，验 agent 自写经验 / 未命中自动攒签名 / **自主真发 PR**（canSubmit 路径从未真发）；升档条件 = 下一样本轮次与介入数可观测下降
  - **R-2 规则库压力测试**（对应 C2/C3 出口判据，样本量 3）：每新样本盲跑预测→真实编译对照，按 P3 判据 1 方案记 Recall/Precision，FN/FP 逐条回填；及格线 = ≥3 新样本对照数据 + Recall ≥80% + FN/FP 全部入库
  - **R-3 鸿蒙原生能力位矩阵**（**对应 A4 口径修正，最大缺口**）：verify 清单从"工程自报 6 项窄清单"扩成系统能力位全量矩阵（文件选择框当前不可用、通知/剪贴板/凭据存储/媒体/权限弹窗流…），逐项真机实测；及格线 = 矩阵落库 + 已验样本按新口径重出数字
  - 执行顺序：R-3 与 R-1 同一个样本轮同时取证（rust-music 零干预轮）→ R-2 随样本持续积累
- **A4 行补口径标注**：100% 可用率统计的是工程自报窄清单，"能运行"≠"能用"，重算口径指向 §五 R-3
- 版本号三处一致 0.39.68

### 验证

六项门禁全绿（纯文档改动）。

---

## [0.39.67] - 2026-11-03

**主题**：README「AI 自动进化飞轮」框图化（drawio 源文件 + SVG + PNG）+ 案例素材批量扩容。

### Changed

- **README 飞轮章框图**：ASCII 流程示意替换为正式框图（`docs/imgs/flywheel.png`，1600×1094）；
  源文件同批入库：`docs/imgs/flywheel-arch.drawio`（drawio 原生，可编辑）+ `flywheel.svg`（矢量源）。
  框图覆盖 ①迁移现场 → ②事实层/③经验层/④证据层 → ⑤候选池（**人工闸门**单列）→ archive →
  ⑥认知层 → ⑦回流 → 回到①的完整闭环，语义配色（青=现场/橙=存储/红=人工闸门/绿=回流）
- **`docs/案例素材.md` 批量扩容**（§1.3 迁移目标队列 +5、§二 +1、§4.2 +1，全部 2026-11-03 本机验证）：
  - **NextChat**（曾用名 ChatGPT-Next-Web，88k+ star，MIT）：多模型 AI 聊天助手，桌面端 Tauri ~5MB——LLM 流式对话/SSE + `tauri fetch` Rust 侧转发、30+ Provider 抽象（⚠️ 现仓名已改 `ChatGPTNextWeb/NextChat`）
  - **EcoPaste**（6.9k star，Apache-2.0）：剪贴板历史管理，Tauri v2 + React + SQLite/sqlx——全局快捷键/多类型剪贴板/OCR/托盘；v1→v2 升级 PR（#634，+9044−4782）可作大版本升级 diff 语料
  - **QuantumTV**（MIT）：本地优先影视聚合播放器（Tauri 2 + Next.js + Axum + SQLite + HLS.js）——在线播放半个媒体域、内嵌 API server
  - **Pake**：网页转桌面应用——**最简 Tauri 工程**，验证流水线下限与 P3 判据 1"零失败样本"
  - **CapCut 平替类剪辑**：Clypra / WolfCut（Tauri v2 + FFmpeg）——工程复杂度天花板，FFmpeg 原生依赖是 P3 依赖矩阵高危域（用户所指具体项目待从官方文档定位）
  - **Peekoo AI**（feed-mob/peekoo-ai，MIT）：桌面智能宠物（AI 对话 + 任务管理 + 番茄钟）——多 crate 分层架构、OS keychain 存密钥（凭据管理新考点）
  - **§二**：Tauri 官方主仓（tauri-apps/tauri，112k+ star）：15 个核心 crate、tao/WRY——规则库 patch 对象（R2-PORT-002/006）的源码口径
  - **§4.2**：awesome-tauri（官方生态清单）——迁移目标队列后续扩容入口

### 验证

六项门禁全绿（纯文档 + 图片资源改动）；版本 0.39.67 三处一致（sync 重派生消漂移）。

---

## [0.39.66] - 2026-11-03

**主题**：README 真机截图更换（锁屏画面 → 可用画面）+ 迁移目标队列登记（rust-music 对照对）。

### Changed

- **README 真机图**：原 0.17.0 真机首验留证图（锁屏画面）→
  `docs/imgs/ohos-music-screenshot.jpg`（cj-tauri `examples/ohos/ohos-music` 在鸿蒙 PC
  HAD-W32 真机的运行画面，3120×2080）；图注如实写明来源与用途——
  **下一个迁移样本 [`rust-music`](https://atomgit.com/qq8864/rust-music)（Rust + Tauri 2
  的同口径对照实现）的移植目标形态**；
- **`docs/案例素材.md` 新增 §1.3「迁移目标队列」**：rust-music（源工程）↔ ohos-music
  （移植目标形态）登记——「源 ↔ 目标」同口径双实现，**扫描器/规则库可做"预测 vs 答案"
  的精确对照**（C2 第二个基线 + P3 出口判据 1 的天然样本）；媒体/音频域考点清单
  （播放器/媒体会话/后台任务/音频焦点——m3u8dl 只覆盖下载子进程那一半）与使用顺序建议。

### 验证

六项门禁全绿（纯文档 + 图片资源改动）。

---

## [0.39.65] - 2026-11-02

**主题**：**「浏览器能打开 8765、应用却说未连接」——真凶是 OpenSSL 裸名加载失败（`RAND_bytes`）**
（用户实测：*网页测试 127.0.0.1:8765 是通的，为何软件启动后还提示未连接* / *这块处理还没有 cjnote 稳*）。

### Fixed

- **WS 握手失败的真因**：仓颉运行时的 TLS 加载器**按裸名**找 `libcrypto-3-x64.dll` / `libssl-3-x64.dll`，
  而 SDK 与 stdx **都不带**这两个 DLL —— 开发机上恰好命中 PATH 里别人带的那份，于是"本机全通、换个启动方式就挂"。
  症状极具误导性：`http://127.0.0.1:8765` 与 `/api/health` 全正常（cjh 自己带着这两个 DLL），
  **只有 ws 握手失败**（RFC6455 升级要算 `Sec-WebSocket-Key` 的随机 nonce，明文 `ws://` 也逃不掉）。
  处置照框架 `cj-tauri/src/embedded_assets.cj`：进程启动早期用 `preloadEmbeddedLibrary()` 按**绝对路径**
  预加载一次（`preloadOpensslLibs()`，候选目录 = 单文件释放的安装目录 → 仓内 `vendor/cjh/win-x64`），
  之后同类裸名加载命中已加载模块 —— 不必改 PATH，也不必把 DLL 摆到 exe 旁边（单文件承诺不破）。
  同时 `scripts/collect-runtime-dlls.sh` 也把这两件收进产物目录（双保险）。
- **连接失败不再"静默失败"**：`wsConnect()` 以前只等 `ws:state` 事件置 `CJ.up`，而**invoke 成功不等于事件会到**；
  事件没来时 `CJ.connecting` 永远为 true ⇒ 之后每次状态轮询都被挡回去 ⇒ **永久"未连接"且再也不重试**，
  界面上一个字的原因都没有。现在照 cjnote 的语义改：**`invoke('ws:connect')` resolve 就当连上**，
  事件只用来发现掉线；失败把插件原话存进 `CJ.wsErr`（`ws: url must start with ws://` / `host is outside
  the authorized scope` / `connect failed: …` 这类能定位的话），页脚悬停可见，并回投
  `ui_report.wsErr / wsConnectTries / wsConnectMs`。

### Changed

- 页内自检（`LINGQU_UI_PROBE=1`）不再"固定 2 秒就发提问"：cjh 冷启动 + 首次健康检查实测要 10~20 秒，
  固定 2 秒发等于在没连上时发，探针永远拿不到 `frames`——**把真问题掩盖成假失败**。
  改成等 `CJ.up` 真连上再发（最多 40 秒），连不上则回投 `probe-ws-fail`。

### 验证到什么程度

- `cjpm build` 0 warning；`cjpm test` **413 / FAILED 0**；`scripts/test.sh` 六项全绿；版本三处一致 0.39.65；
- **裸 PATH 启动（模拟双击）实测**：`wsState=connected`、`frames=2`、`replyPreview="收到"`
  （设置页「测试连通」那条链同理）、`wsConnectTries=1`、`wsErr` 为空、`errorCount=0`。
  同一台机器上把 `libcrypto-3-x64.dll` 拿掉时能稳定复现
  `ws: connect failed: Can not load openssl library or function RAND_bytes.`

### 未验证（如实）

- 只在本机（Git Bash 带着 OpenSSL 在 PATH 里）与"裸 PATH"两种环境验过；**没有在干净的新机器上验**；
- 单文件包里的 OpenSSL 走的是"随包释放到 `%LOCALAPPDATA%\lingqu\cjh` + 预加载"，与目录版同一套代码，
  但**单文件包本身没有再跑一遍 WS 端到端**（只验过它的窗口/引擎/报告）。

---

## [0.39.64] - 2026-11-02

**主题**：**「从头重跑」+ 两处"看着像 bug 的观测口径"** + **打包链修到能出新版单文件 exe**
（用户实测：*点 AI 一键迁移怎么直接完成了？那我没办法重新跑一遍吗* / *报告已生成但左栏还是未开始* /
*为啥启动时总报少 libstdx.dll* / *单个可执行文件的*）。

### Added

- **`t2h:reset_records` + ① 屏「↻ 从头重跑」**（命令数 38 → 39）：把该工程的迁移落档
  （8 步目录 + report + `tasks.json`）**搬进 `<工程>/.lingqu/_archive-<时间戳>/`**，让观测从零开始，
  搬完立刻起 AI 迁移。为什么需要它：判定只认落档（`observeTaskStep` 每次按盘上 `.lingqu/` 重新观测），
  跑过一轮的工程 8 步落档都在 ⇒ 再点「AI 一键迁移」agent 一看 `resume` 就"没活可干"，
  界面表现就是"点一下直接完成"——不是它偷懒，是真没有可干的活。
  纪律：**只搬灵渠自己的落档**（`notes`/`diagnose`/`evidence`/源码一律不碰）、**搬走不删**（档案可回退）、
  判据是"源不在且目标在"而不是"rename 没抛异常"。纯函数 `resetTargetsOf` / `archiveDirNameOf` + 5 例单测。
  ⚠ 写这一版时又撞上 `StringBuilder.append(Byte)` 按十进制打印的老坑（`-` 变成 "45"）——
  单测用**整串精确值**断言当场抓出（弱判据"不含 `:`"照样过，§4-62 同族）。
- **`scripts/collect-runtime-dlls.sh`**：按导入闭包把运行时 DLL 收进
  `targets/desktop/target/release/bin/`（Windows 的 DLL 搜索顺序里 exe 目录排第一），
  并把它接进 `scripts/run-dev.sh`。起因：`main.exe` 导入 `libstdx.*.dll` / `libcangjie-runtime.dll` /
  `libcjtbridge.dll`，它们只在 SDK/框架目录里 ⇒ **双击 exe 必报"缺少 libstdx.dll"并启动即退（0xC0000135）**，
  只有走 `run-dev.bat`（配好 PATH）才起得来。收起后双击也能跑，且带闭包自检（漏一个就失败）。

### Fixed

- **左栏「报告」徽标永远「未开始」**：`RAIL_STEPS.report = ['report']`，而断点板只有 8 步
  （scan…verify）**没有 report 这一步** ⇒ `rows['report']` 恒 undefined。现在 `t2h:resume` 直接回投
  `reportOut` / `reportExists`（路径由 `reportOutPathOf` 统一构造，与 `t2h:report` 的落点同一口径），
  前端据此合成一行观测。
- **单文件打包链三处真问题**（用户要求"单个可执行文件的"，照 `cj-tauri/scripts/` 的做法修）：
  ① `packaging/pack-assets.txt` 漏了 `libboundscheck.dll`（0.39.61 引擎升 1.6.5 时新增）——
  释放出来却过不了 `cjhVendorVerified` 的五项 SHA256，运行期表现为"AI 引擎缺失"（§4-55）；
  ② 两个打包脚本都**写死只生成 `PACKED_UI_B64`/`PACKED_CAPS_B64`**，而 0.39.x 给技能正文加了
  `PACKED_SKILL_B64` ⇒ 单文件构建直接编不过；现在改成**按 `src/packed_assets.cj` 的存根声明逐行生成**
  （存根声明了本脚本不认识的资源就报错退出），与框架 `scripts/pack-win-single.sh` 同款；
  ③ **补 strip**（61.5 MB → 34.6 MB）：优先 `strip`，失败回退 SDK 自带 `llvm-objcopy --strip-all`
  ——llvm-mingw 的 `strip.exe` 是包装器、真身 `llvm-strip` 可能缺失，直接 `2>/dev/null` 会把真实报错吞掉。

### 验证到什么程度

- `cjpm build` 0 warning；`cjpm test` **413 / FAILED 0 / ERROR 0**；`scripts/test.sh` **六项全绿**；
- **单文件包实跑**（`dist/lingqu-0.39.63-win-x64-full/main.exe`，**只有 main.exe + README**）：
  在**别的目录 + 只剩系统 PATH**（模拟双击）启动 → 窗口起来、内嵌引擎释放 5 件
  （`cjh.exe` + 4 个 DLL）、`/api/health` **200 / version 1.6.5**、页面自写 `ui-report`（`errorCount=0`）；
  导入表只剩系统 DLL（无 `libcgtbridge`/`libstdx.*`/`WebView2Loader`），有 `.rsrc` 资源节；
- **从头重跑探针**（`LINGQU_UI_PROBE=reset`，只验归档不真发任务书）：`resetOk=true`、搬走 11 项、
  档案目录 `_archive-2026-11-02-...`、`notes/` 仍在原位。

### 未验证（如实）

- 「从头重跑」**没有在真机上把一轮完整迁移跑完并归档再重跑一遍**（只验了归档与起点）；
- 单文件包的**鸿蒙端**从未打过（只做 Windows x64）；
- 静态单文件 **34.6 MB** 里约 18 MB 是 base64 内嵌资源（页面 711 KB + 技能 10 KB + 引擎 ~21 MB 作为 PE 资源），
  再用 `-Woff`/去符号挤空间没做；`llvm-strip` 缺真身这条是**本机事实**，换机器请重看 `[strip]` 那行输出。

---

## [0.39.63] - 2026-11-02

**主题**：**聊完一句「hello」不许再弹"迁移还没完成"的红卡**（用户实测，发 hello 后的截图原话：
*「为什么停：模型自己结束了这一轮（它认为无法再推进）。迁移还没完成…」*）。

### Fixed

- `noteTurnEnded()` 的判据只看了 `AIP.finished`：普通问答时 `finished=false`、`active=false`，
  于是"还没迁完"这个结论被无条件套到**每一次**回合收尾上 ⇒ 正常聊完一句话，屏幕上多出一张红卡。
  现在改成：**只有 AI 自动迁移监管态在跑（`AIP.active === true`）时**才谈"迁移还没完成"；
  普通问答里有真原因（轮次预算 / 长度上限 / 回合异常）才解释一句，且**一个字都不提迁移**；
  正常 `stop` 收尾什么都不多说。
- `newAssistantTurn()` 现在清空 `window.__turnEnd`（上一回合的 reason 会串到下一轮，§4-105 同族：
  一次性快照不许当"现在"用）；顺带清 `CJ.lastToolErrName`。
- 错误卡加上稳定类名 `.errmsg`（`addError`），`ui_report` 新增 **`errorCards`**（聊天区红卡计数）
  ——"屏幕上多了个红块"这类问题要能数字断言，不能靠人眼。

### Added

- 页内自检 **`LINGQU_UI_PROBE=turnend`**：同一条 `done` 帧喂两次——① `AIP.active=false`（普通问答，
  必须 `errorCards=0`、`turnEndReason=""`）；② `AIP.active=true`（迁移监管态，必须 `errorCards=1`
  且 `turnEndReason` 非空）。实机实测：`turnend-plain → errorCards=0 / turnEndReason=""`、
  `turnend-migration → errorCards=1 / turnEndReason="模型自己结束了这一轮（它认为无法再推进）"`。

---

## [0.39.62] - 2026-11-02

**主题**：**模型设置页按 cjnote 收敛**——删掉"模型清单"这套校验、补上「测试连通」与**接入协议**选择，
顺带修掉 ⚙ 按钮那个静默抛错的作用域缺陷（用户实测反馈）。

### Added

- **接入协议选择**（`openai` 兼容 / `anthropic`）：设置页 `<select id="setProto">`，
  写进 `~/.cjh/settings.json` 的 `provider_protocol`。
  为什么不能走 REST：cjh 的 `applySettingsUpdate` 白名单里**没有** provider_protocol
  （只认 baseUrl/model/apiKey/温度/tokens/轮次），协议是"启动时读一次配置文件"的字段 ⇒ 与轮次预算同款做法：
  **定点文本修补 + 先备份**（`<settings>.bak.protocol`），不重排 JSON；写完如实回投
  `protocolChanged=true` 与「需重启 cjh 生效」。纯函数 `normalizeProtocol` / `providerProtocolOf` /
  `setProviderProtocol` + 动作层 `ensureCjhProviderProtocol`，5 例新单测（含转义、camel/snake 两种键、
  不认识的值不动、无 `{` 不动）。
- **`t2h:cjh_restart`**（命令数 37 → 38）：只重启**本应用拉起的**引擎（D-003 不抢不杀），
  外部实例回 `external=true` 并如实拒绝；等旧实例真退出（最多 5s）再拉新的，避免端口占用导致
  "重启后引擎缺失"。设置页「重启引擎」现在**真重启**（旧实现只调 `deploy`，见到活实例就复用 ⇒ 等于没点）。
- **设置页「测试连通」按钮**（做法照 `cj-tauri/examples/cjnote`）：用**表单里这组值**（Base URL / 模型名 /
  API Key）真发一条最小对话（`连通测试：请只回复一个词 ok`），改配置一字不动、不落会话。
  原理是 cjh `chat` 帧自带**单次模型覆盖**（`src/web/protocol.cj` 的 `ChatRequest`：
  `model` / `baseUrl`(`base_url`) / `apiKey`(`api_key`)，优先级 帧字段 > 会话级 `switch_model` > 当前配置，
  明确「本次 run 局部生效、不落盘不粘连」）；探针帧在 `onFrame` 里被拦截，不进聊天面板、不接会话 id、
  不触发 `finishTurn`。四种收尾文案分得很清：**连通 / 通了但没吐字（多半模型名不对）/ 超时 / 报错**。
- `ui_report` 新增 `settingsProbe` / `settingsProbeMs` / `settingsProbeNote` / `settingsProbeFrames` /
  `settingsProto` / `settingsProtoSaved` / `settingsOpenBridge` 七项（`main.cj` 白名单同批放行）。
- 页内自检 `LINGQU_UI_PROBE=probe`：自动打开设置页 → 点「测试连通」→ 回投结果，
  让"按钮真的干了事"可被自动断言（不需要人眼）。

### Changed

- **设置页形态收敛到 cjnote 那种**：`节点状态 → 服务商（地址 / Key / 模型名 / 接入协议）→ 生成参数
  → 保存并生效 · 测试连通 · 重启引擎`。**整块「候选模型」清单删掉**（含 `loadModels` 与 `.modelitem` 样式）：
  cjh 的 `/api/models` 只是把 `settings.json` 里手写的 `models` 数组原样返回
  （`handleListModels` 不查服务商真实目录），拿它当校验等于用一份手写列表去否定用户输入。
- **删掉「配置里的模型 X 不在下面的列表里」这条告警**（用户判定：*模型名填啥就是啥，不应该显示是不是在什么清单里*）。
  模型名以「模型名」输入框 / `settings.json.model` 为准；这组值通不通由「测试连通」回答。
- 「本会话已切到 X / 配置里写的仍是 Y」这条保留：那是**会话级覆盖 ≠ 配置**的真实差异，不是清单校验。

### Fixed

- **点右栏 ⚙「模型与服务商设置」抛 `ReferenceError: loadSettings is not defined`**（`about:blank:2557`）：
  那段 handler 在**外层作用域**，而 `loadSettings` / `loadModels` 定义在内层
  `withBridge(function(tauri){…})` 里 —— 设置页能打开但字段永远不填充，界面上就是"点了没反应"
  （与 AGENTS §4-107 左栏徽标同族）。处置：内层注册 `window.__aiSettingsOpen`，外层只切版面 + 走桥。

---

## [0.39.61] - 2026-11-02

**主题**：**win-x64 随包引擎同步 cjh 1.6.5**（selfcontained 五件套整套替换，0.39.60 的未验项之一清账）。

### Changed

- **vendor/cjh/win-x64** 整套替换为 cjh v1.6.5 selfcontained 产物（`dist/cjh-v1.6.5-windows-x64-selfcontained.zip`）：
  - `cjh.exe` 换新（SHA256 `07f5427a…012b`）；
  - **`libboundscheck.dll` 新增随行件**（SHA256 `07b33dd3…6c78`，1.6.5 起自带）；
  - `libcangjie-runtime.dll` / `libcrypto-3-x64.dll` / `libssl-3-x64.dll` **哈希与旧版完全一致**（运行时 DLL 未变）——组合风险极低：同一发版产物内的组合，且三个 DLL 与上一版逐字节相同；
- **校验链两处同步**：`vendor/cjh/SHA256SUMS`（cjh.exe 行更新 + libboundscheck.dll 新增行，6 条全量）；
  `src/cjh_host.cj` 的 `CJH_VENDOR_FILES` **4 项 → 5 项**（新增 libboundscheck.dll 条目）；
- 版本号三处一致 0.39.61。

### 验证

```
sha256sum -c vendor/cjh/SHA256SUMS → 六文件全量 OK（exit=0，含 linux-x64 与 win-x64）
cjpm build               → 0 warning
scripts/test.sh          → 六项全绿（build-biz / test 403 / check / js-syntax / build-app / build-cli）
```

### 未验证（如实标注）

- **Windows 实机运行未验**（本机 Linux 无法运行 exe）——但组合完整性有双重保障：
  ① 五件套来自同一发版 zip；② 三个运行时 DLL 与已验证的旧版逐字节相同，唯一新二进制
  是 exe 本身与新随行 libboundscheck.dll。待 Windows 侧启动一次 cjh（`cjh --version`
  → `cjh v1.6.5`）即可清账；
- 校验链的 Windows 分支（`CJH_VENDOR_FILES` 五项比对）在 Linux 构建不编译（`@When` 门禁），
  其正确性以 SHA256SUMS 全量比对为准——常量与 SUMS 同源，人工已核。

---

## [0.39.60] - 2026-11-02

**主题**：**随包引擎升级 cjh 1.5.3 → 1.6.5**（vendor/cjh/linux-x64 替换 + SHA256 校验链同步）。

### Changed

- **vendor/cjh/linux-x64/cjh** 替换为 cjh v1.6.5 官方产物（来自 cjh 仓发版提交 `7966f44` 的
  `dist/cjh-linux-x64`，18,120,496 bytes）；实测 `--version` 回 `cjh v1.6.5`
- **校验链两处同步**（SHA256 不过就拒绝执行，漏一处 = 启动即拒）：
  ① `vendor/cjh/SHA256SUMS` 的 `linux-x64/cjh` 行 → `2821d90f…7ab31`；
  ② `src/cjh_host.cj` 的 `CJH_LINUX_SHA` 常量同步更新
- 版本号三处一致 0.39.60

### 验证

```
cjh --version            → cjh v1.6.5
cjh web --bind 127.0.0.1 → GET /api/health 200，version="1.6.5"
cjpm build               → 0 warning
scripts/test.sh          → 六项全绿（build-biz / test 403 / check / js-syntax / build-app / build-cli）
```

### 未验证（如实标注）

- **win-x64 未同步**：cjh 1.6.5 发版只含 exe（无随行 DLL 更新），Windows 侧替换后无法在本机
  验证运行（dll/exe 组合完整性测不了）——待 Windows 侧验证后单独更新，SHA256SUMS 的
  win-x64 三 DLL 行保持 1.5.3 期哈希不变；
- 新引擎与既有 WS 协议/审批流/`t2h:*` 的**实机对话回归**未跑（本机 Linux 起工作台即可做，
  属 Linux GUI 收尾项）。

---

## [0.39.59] - 2026-11-02

**主题**：**飞轮阶段 3 护栏**——`t2h:pr_prepare` 加上防失控的三道栏杆（单轮上限 / 同类去重 / 启动刷新语义）。至此飞轮 §8 的阶段 1–3 全部落地（自动提交真发 PR 仍除外，见未验证）。

### Added

- **单轮候选上限**（`MAX_CANDIDATES_PER_PR = 5`）：一次 PR 改太多条，评审就变成"信任 AI"而不是"逐条复核"——超出截断进 note（**其余留在候选池**，下轮再提，不丢弃）；
- **同类去重**：`lessonKeyOf`（title+cause）相同只算一条（loader 已去重，编排层防御一次）；
- **启动刷新语义写进 PR 正文末尾**：合并后**下次启动**才刷新本地技能（不热替换——prompt 漂移会让行为变了却没人知道为什么，§5-2 原决策）。
- **2 例新单测**（总 **405 例**）：去重 + 上限截断（8 条种子 → 去重 7 → 截断 5，note 说明）+ 正文只含 5 条 + 启动刷新说明在末尾。
- **`docs/P3-出口判据1-验证方案.md`**（同轮补）：P3 出口判据 1（依赖矩阵与真实交叉编译失败吻合 ≥80%）的
  **可执行验证方案**——失败点三分类（crate 级/工程配置/环境工具链，前两类进口径）、
  混淆矩阵与公式（Recall ≥80% 主判据 + Precision 辅助 + 零失败样本不进分母）、
  4 样本名单与预期、执行八步、对照表模板、五条风险预案。P5 跑通后照做，不再讨论"怎么算"。
- **`docs/P5-流水线Linux执行方案.md`**（同轮补）：P5 代码已落地（Windows 3 样本真机验证），
  这份是 **Linux 环境就绪 + 首跑执行清单**——本机现状探测（rust 1.96 + ohos 三 target ✅ /
  node v22 ✅ / OHOS SDK **断链** ❌ / java·hdc·hvigor ❌）、按序补装清单（每项带验证命令）、
  9 步首跑序列与**字段级判据**（含补上出口判据 ② 缺的"版本号一致"断言）、
  首跑后两份对照（本方案 + P3 判据 1 **共用同一次首跑日志**）、六条 Linux 特有风险预案
  （含"compiler 的 Windows 布局假设若成真——是真 bug 修 compiler 补单测"）。

### 验证

```
cjpm build      → 0 warning
cjpm test       → TOTAL=405, FAILED=0, ERROR=0（+2 例）
scripts/test.sh → 六项全绿
```

### 未验证（如实标注）

- 飞轮 §8 的"全自动提交"（token 在手时真发 PR）**未实现**——提交动作永远在人手里；
  gitcode PR API 接入待调研（不猜 API）；CI 侧：本仓无云端 CI（编译链私有），"CI 绿才合并"
  由人工跑 `scripts/test.sh` 替代，评审流程不变。

---

## [0.39.58] - 2026-11-02

**主题**：**P8 迁移指南 + 飞轮阶段 2（半自动 PR）**——面向用户的指南落地，经验入库从"机器提议"推进到"人只点提交"。

### Added

- **`docs/迁移指南.md`**（P8，验收 A5 的"迁移指南"件）：面向想把 Tauri 应用迁到鸿蒙 PC 的使用者——
  迁移画像读什么（C1/C2/阻塞项、依赖矩阵分档不是判决）、8 步流水线**每步信什么 + 最容易踩的坑**、
  规则/AI 双路径与 diagnose 三级递进（指纹 → AI 长尾 → fork 先行）、高频坑速查表、
  迁完之后的报告/断点/飞轮回填、样本实证表（3/5 可复现口径）。素材与 `skills/t2h-ohos-port` 同源，一次蒸馏两份产出
- **README 同步**：文档地图加迁移指南入口；路线 P8 ✅；验收 A5 `已实现`
- **飞轮阶段 2：`t2h:pr_prepare`**（`src/pr_prepare.cj` + `PrPrepareCommand`，三处联动）：
  - 产物落 `<工程>/.lingqu/pr/<工程>/`：`pr-body.md`（PR 正文，证据链六要素：标题/现象/根因/
    复现含样本与次数/修法 + **提交前三问**）、`pitfalls-suggestion.md`（四段→三段的建议追加段，
    **不碰 skills/ 本体**——合并是人/CI 的事）、`branch.txt`（`flywheel/<工程>-notes-<条数>`，
    git ref 安全集字节级清洗，全非法兜底 proj）
  - **token 纪律**：只认环境变量 `LINGQU_GITCODE_TOKEN`（有则 `canSubmit=true`），
    无则退化本地产物（`degraded=true`，人复核后自行提交）；**绝不读取/写回 settings.json**
  - 没有满足门槛的候选 → 不产文件、note 明说（不假装准备好）
- **7 例新单测**（总 403）：分支名清洗（中文按字节换 `-`、全非法兜底 proj）、
  PR 正文证据链六要素与提交前三问、空候选明说、pitfalls 建议段三段形态、
  编排真实落盘（tmp 种子两条候选 → 三份产物 + degraded）、token 在但无候选的组合

### 验证

```
cjpm build      → 0 warning
cjpm test       → TOTAL=403, FAILED=0, ERROR=0（+7 例）
scripts/test.sh → 六项全绿（build-biz / test / check / js-syntax / build-app / build-cli）
```

### 未验证（如实标注）

- `canSubmit=true` 路径**没有真发 PR**（token 只探测不使用，提交动作永远在人手里——阶段 3 再谈自动化）；
- 403 例里 `pr_prepare` 的编排用例依赖 `/tmp` 可写（不可写时自动跳过，不造假绿）。

---

## [0.39.57] - 2026-11-02

**主题**：Linux 侧回归与文档收口——`bareLqRel` 跨平台分隔符修复 + README「为什么是它」。

### Fixed

- **`bareLqRel` 反斜杠前缀剥离绑死平台分隔符（Linux 上必挂）**：
  `testBareLqRelStripsLingquPrefix` 在 Linux FAILED——`bareLqRel(".lingqu\\scan\\habit-tree.json")`
  原样返回，未剥 `.lingqu\` 前缀。根因：反斜杠分支用 `cjhPathSep()` 构造前缀，而该函数
  `@When` 平台分支在 Linux 返回 `/`——Windows 反斜杠路径（报告收数可能收到归档里的 Win 路径）
  在 Linux 上两个分支都匹配不上。处置：`.lingqu\\` 分支无条件判断（不依赖平台），与 §4-26
  同纪律（剥前缀/取末段，**两种分隔符都认**）。验证：Linux 上四道闸全绿，396 例 FAILED=0。

### Added

- **README「为什么是它」**：与传统「技能包 / 散装 CLI」路线的六维形态对比（感知全景 /
  生命周期 / 迁移质量 / 经验沉淀 / 上手成本 / 谁来干活），凸显项目价值——
  一句话定位：**技能包给 AI 一本攻略书，灵渠给 AI 一条带闸门的流水线和一个会自己写攻略的大脑**。

### 证据

```
cjpm build      → 0 warning
cjpm test       → TOTAL=396, FAILED=0, ERROR=0（含此前在 Linux 挂掉的该用例）
scripts/test.sh → 六项全绿（build-biz / test / check / js-syntax / build-app / build-cli）
环境            → Linux x86_64 首跑（cjc 1.2.0 / cj-tauri @ 7dfea72 / CLI 重编）
```

### 备注

- cj-tauri CLI `sync` 不展开 `cjpm.toml` 依赖路径的 `${CJ_TAURI_ROOT}` 占位符（cjpm 能展开）
  已提上游 issue：`cj-tauri#7`；本机以 `sync --framework "$CJ_TAURI_ROOT"` 绕过。

---

## [0.39.56] - 2026-11-02

**主题**：**飞轮阶段 1——把"候选池"做成可操作的东西**（不联网、不碰用户工程）。

### 背景

0.39.55 让 agent 把经验落盘了，但"哪些值得进技能库/指纹库"还得人翻文件。阶段 1 把这件事变成
**机器提议、人裁决**：按可判定的门槛筛候选、给每条配一段 PR 正文草稿、入库后一键移出候选池。

### 处置

| 面 | 内容 |
|---|---|
| `t2h:notes --action suggest` | 筛候选（**次数 ≥2 + 四段齐全 + 未入库**，`candidateLessons`）→ 写 `<工程>/.lingqu/notes/<工程>-candidates.md`（`--out` 可指定位置）+ **逐条 PR 正文草稿**（`renderPrDraft`：现象/根因/复现/修法 + 次数/工程 + 建议落点 + **提交前确认三问** + 三段式填空模板）。未命中台账里**同签名 ≥3 次**的也一并列出（`missSignatureList` + `missCountOf`）。回包给 `candidateCount / missCandidateCount / lessonTotal / missLedgerLines / candidates / missCandidates / out` |
| `t2h:notes --action archive` | ① 把打了 `- 入库：<引用>` 的经验挪到 `<工程>-archived.md`（**先写归档件、成功后才重写主文件**；并入已有归档件时走 `mergeLessons` 去重）；② 台账到 `MISS_ROLL_MIN_LINES=200` 行就整体挪到 `diagnose/misses.<时间戳>.jsonl`——**先写归档件再重置台账**，不丢证据。回包给 `archivedNotes / keptNotes / archivePath / notesNote / missLedgerLines / missArchivePath / missNote` |
| 落档格式扩展 | `LessonNote` 增 `archivedRef`（渲染为 `- 入库：…`，只在该字段非空时出现；解析宽容，老文件没有这行照样读） |
| 新文档 | **`docs/经验入库规则.md`**：三条件 + 人的三追问、四个去处与选型判据、**四段 → `pitfalls.md` 三段**的映射表与完整示例（用真实那条 `hvigor 00308018`）、入库后回写标记与归档流程、命令速查与回包字段、七条反例、PR 前复核清单 |

### 单测（9 例，`src/tests/notes_test.cj`）

- 门槛：`isLessonComplete` / `isLessonArchived` / `candidateLessons`（次数不够、四段不齐、已入库三种都筛掉）；
- 拆分与渲染：`splitArchivedLessons`、`renderPrDraft`（含"提交前确认三问"）、`renderCandidatesMd`（**没有候选要明说"没有"**，不造空表）；
- 动作层：`archiveLessons` 搬走已入库的、主文件保留待裁决的、**第二次跑什么都不做**（不写空文件冒充"归档过了"）；
- 台账：`missLedgerLineCount` / `missSignatureList`（紧凑行**和**美化多行都要认）/ `shouldRollMisses` / `missArchiveFileName`（时间戳里的 `:` 换掉）/ `rollMissesLedger`（没台账、未到阈值、到阈值三种路径 + 归档件内容完整）。

### 单测当场抓到的 bug

`missSignatureList` 原先按 `"sig":` 切片，遇到**美化输出**（`"sig": "x"`，冒号后带空格）会漏 →
`missSignatureList(pretty).size` 断言 0≠1 报出来。改成"找 `"sig"` 键 → 跳过空白与冒号 → 读 JSON 字符串字面量"
（`sigFieldOf` + `jsonStringAt`，能跳过 `\"`/`\\` 转义），紧凑与美化两种形态都认。

### 证据

```
cjpm build      → 0 warning
cjpm test       → TOTAL=396, FAILED=0, ERROR=0（+9 例）
scripts/test.sh → 六项全绿（build-biz / test / check / js-syntax / build-app / build-cli）
真 CLI          → suggest 产出 candidates.md（含 PR 草稿）；archive 把已入库条目挪走、主文件保留其余
```

### 未验证

- `suggest`/`archive` 目前只有**单测 + 本机 CLI 跑通**，**还没有真实样本攒够 2 次经验**（阶段 1 的判据要等下一轮实跑）；
- `--out` 写仓外路径时不做沙箱校验（工具本就允许写用户目录）；
- 阶段 2（`t2h:pr_prepare` 草稿 PR）与阶段 3（CI + 评审后合并）未开始——见 `docs/AI自进化飞轮.md` §8。

---

## [0.39.55] - 2026-11-02

**主题**：**踩坑经验自己长出来**——事实层早就是全自动的，认知层却一直靠人（每轮手写指纹 / 技能 / §4）。

### 现象（用户提问查出来的）

> 移植中的踩坑经验和技能会自动沉淀下来吗？

诚实回答是「一半」：

| 层 | 现状 |
|---|---|
| **事实层** | **全自动**：每步落档 `.lingqu/<步骤>/<工程>.json`、agent 轨迹 `.lingqu/agent/trace.jsonl`、迁移报告三件套 |
| **认知层** | **靠人**：新坑 → 新指纹（FP-0xx）/ 技能条目（`skills/t2h-ohos-port`）/ AGENTS §4，全是每轮手写 |

而 agent 的汇报留在会话里，**会话一压缩细节就淡了**（本轮实测出现过"21/24/30 条早期消息 → 摘要"）。
于是下一个样本撞上同一个坑，还是从零查起——这与「数据从真实的来」是一体两面：真实的东西没落盘，就等于没有。

### 处置（三件，一批）

| 面 | 内容 |
|---|---|
| 落盘口子 | 新 `src/notes.cj` + 命令 **`t2h:notes`**（`action=list/append/export`）：写 `<工程>/.lingqu/notes/<工程>.md`，固定四段（现象 / 根因 / 复现 / 修法）+ 次数 / 工程 / 时间。**幂等**：同标题（归一化后）只累加次数、不重复堆；`lingqu-cli notes --path . --action export` 出全量 markdown |
| 让 agent 自己记 | `src/autoport.cj` 任务书新增**强制一节**「把踩到的坑记下来」：踩到新坑就先把内容写成 JSON 文件，再 `lingqu-cli notes --action append --path <工程绝对路径> --body <json文件>`。路径**绝对**（§4-70：agent 的 bash cwd 是目标工程）。**为什么必须走文件**见下面的"硬限制" |
| 不认识就攒证据 | `t2h:diagnose` 未命中指纹时，把日志归一签名（`missSignatureOf`：数字折叠成 `#`、空白压一格、ASCII 小写、截断 120）追加到 `<工程>/.lingqu/diagnose/misses.jsonl`，同签名累计次数并给 `missCandidateHint`（1 次先攒着 / 2 次可考虑 / ≥3 次**建议补指纹**）。回投 `missSignature / missCount / missHint / missLedger` |
| 报告看得见 | `MigrationFacts.lessonCount/lessonsLine`：「做了什么」多一行「本地经验 N 条（标题…）」，「需要你做什么」多一行复核提示；产物清单列出 `.lingqu/notes/<工程>.md` |

**纪律**：`notes` 只记 agent **跑过看过**的东西，不写猜测；台账只攒**证据**——指纹库会指导 agent 怎么改用户代码，
所以进库仍要人确认（**不自动写**）。

### 单测当场抓出的三个真 bug（都能过编译、跑起来必错）

1. `lessonKeyOf` 逐字节 `String.fromUtf8([b])` → **中文标题必抛** `IllegalArgumentException: Invalid utf8 byte sequence`
   （单个字节不是合法 UTF-8，与 §4-113 同族）。改成攒 `ArrayList<Byte>` 后整体解一次。
2. `fieldAfterSpace` 取 `工程：` 的值时没在全角空格 `　` 处截断 → `project` 变成 `juCang　时间：2026-11-02 …`。
3. `JsonObject.toJsonString()` 是**美化输出**（一条记录摊成 4 行、冒号后带空格）⇒ 台账"一条一行 + 按行计数"的前提不成立，
   累计次数**永远返回 1**。改成手拼紧凑 JSONL，并让 `missCountOf` 两种形态都认。

### 端到端实测又撞出一个**硬限制**：Windows 上仓颉程序接不了非 ASCII 的 argv

拿真 CLI 跑 `notes --action append --title "中文标题探针"` 时**必崩**：

```
IllegalArgumentException: Invalid unicode scalar value.      ← PowerShell 传参
IllegalArgumentException: Invalid utf8 byte sequence.        ← Git-Bash 传参
```

- **不是我们代码的问题**：连 `main.exe --help 中文` 都崩，异常在 `main(args: Array<String>)` 之前就抛，
  cmd / PowerShell / Git-Bash 三种调用方一样，`chcp 65001` 也没用 ⇒ 是**运行时解 argv 的口径**问题（§4-119）。
- **影响面**：凡是"中文内容当参数"的用法全废——经验正文、中文工程路径、中文标题都过不去。
  agent 的 bash 同样受影响（它传的也是非 ASCII 字节）。
- **处置**：`notes` 增 **`--body <json 文件>`**（`parseLessonBody` 纯函数解析，宽容：坏 JSON/缺字段不抛）；
  agent 先把内容写成 UTF-8 JSON 文件（bash 写盘没问题），再让命令读文件。任务书与文档已改。
- **实测证据**（`cli/target/release/bin/main.exe notes --path .lingqu/notes-probe --action append --body note-in.json`）：

```
{"ok": true, "result": "added:hvigor 00308018 不是签名问题", "bodyUsed": true, "count": 1}
落档 .lingqu/notes/notes-probe.md：
  ### hvigor 00308018 不是签名问题
  - 现象：t2h:hap 报 00308018，日志里是 cargo tauri panic
  - 根因：hvigorfile 的 tauri 钩子在非 dev 场景必然失败
  - 修法：R2-PORT-015 注掉 .afterRun(buildRustCode)
```

> 中文内容**没有坏**（用 UTF-8 读回逐字正确）；PowerShell 里 `Get-Content` 看到的乱码是**读侧按 GBK 解码的显示假象**。

### 证据

```
cjpm build      → 0 warning
cjpm test       → TOTAL=387, FAILED=0, ERROR=0（新增 15 例：src/tests/notes_test.cj）
scripts/test.sh → 六项全绿：build-biz / test / check / js-syntax / build-app / build-cli
命令数 37（register 37 × capabilities 37，`cj-tauri check` 三方比对通过）
真 CLI 实测     → notes --body 中文四段 → 落档逐字正确（above）
```

### 文档

- 新增 **`docs/AI自进化飞轮.md`**：把这条"agent 自己记经验 → 攒未命中证据 → 机器提议 / 人裁决 → 固化成指纹·规则·技能 → 下一轮自动吃上"的闭环写成技术文档
  （五层结构、七个环节的接口与判据、数据结构、度量指标、纪律与反例、已知边界、可复核验证清单、阶段 1–3 演进路线）。
  在 `docs/会话交接.md` 的文档地图里加了入口。
- **README 重写**（开源门面）：徽章行 + 目录导航 + 30 秒了解 + **「AI 自动进化飞轮」专章**（回路图 + 五条设计理由 + 四个观察指标）+
  **三张真实截图**（`docs/imgs/workbench.png`、`docs/imgs/report.png` 为真实应用窗口截图，第三张为真机证据图）+
  能力矩阵 + 快速开始 + **「测试与质量」专章**（六项门禁逐项、七种质量手段、本轮三个真 bug、为什么没有云端 CI）+
  架构与目录树 + 命令表（37 条 `t2h:*` / 20 条 CLI）+ **平台与验证范围（含 Linux 未实跑）** + 文档地图 + 路线与质量目标表。
  **README 面向开源读者**：不写课题名称、课题性质与交付期这类项目外部信息（按用户要求删除）；
  原"验收标准（课题原文）"改写为「质量目标」，证据仍指向 `docs/需求追踪.md`。
- 开源规范补齐：**`LICENSE`（MIT）**、**`CONTRIBUTING.md`**（开发流程、改动规矩、常见扩展点、提交信息格式、PR 清单）、
  **`SECURITY.md`**（敏感数据边界表、已有安全设计、已知边界）、
  **`.github/`**（Issue 模板：bug / feature；PR 模板，证据与文档勾选项内建）。
- 截图口径：工作台与报告屏为 `CopyFromScreen` 抓取真实窗口（1280×840，像素体检 239 / 300 种颜色，非空白）；
  报告内容 100% 来自落档，触发方式是 `LINGQU_UI_PROBE=risk` 走真实的 `t2h:report`。

### 未验证

- **agent 真的会在迁移途中调 `notes append` 吗**？任务书里是硬指令，但"指令写了"≠"它照做"——要等下一轮真实自动迁移跑到
  踩坑处，看 `.lingqu/notes/<工程>.md` 有没有长出来。本轮只验了命令本身（单测 + 真 CLI 落档往返）。
- 非 ASCII argv 的限制只在本机（Windows 10/11 + 仓颉 1.0.5）实测过；**Linux 侧未验**（那边 argv 是字节流，大概率没这问题）。
- `--body` 的 JSON 只认 `title/symptom/cause/repro/fix` 五个键，其它键忽略；标题为空会拒绝写盘。
- `misses.jsonl` 目前只有单测造的数据，**还没有真实样本**（`t2h:diagnose` 真跑未命中才会写）。
- 本地经验**不会自动进 `skills/`**：这是有意的（prompt 漂移代价太大），整理进技能库仍要人 / PR 评审。

---

## [0.39.54] - 2026-11-02

**主题**：**AI 自动迁移跑完自动出报告**——确定性流程早就会，AI 这条路漏了。

### 现象（用户提问查出来的）

> 当前跑完真机验证就结束了？那个迁移报告有没有生成？

- 8 步流水线的最后一步就是 **verify**（`src/task.cj` 的 `TASK_STEPS` 到 `verify` 为止），**报告不在 8 步里**；
- `t2h:migrate`（▶ 确定性流程）收尾**无条件**调 `t2h:report`（`main.cj:4435`，0.36.0 定的规矩）；
- **`t2h:autoport_*`（🤖 开始 AI 自动迁移）没有任何出报告调用** ⇒ 纯 AI 跑完会出现
  「8 步全绿、`finished=true`，但 `.lingqu/report/` 是空的」，A1 要的"每应用一份报告"全靠人记得点 ⑦ 屏。
  juCang 那轮就是我自己手动补了一次 `report`——正好被用户问出来。

### 处置

| 面 | 内容 |
|---|---|
| 触发 | 页面在 `renderAiPort(st)` 里判 `st.finished === true && !AIP.autoReported` → 调一次 `autoReportAfterAi(path)`（幂等；新一轮开始时 `startAiPortScope` 把 `AIP.autoReported` 与 `window.__autoReport` 重置） |
| 做什么 | `invoke('t2h:report', {path})` → 成功则把 ① 屏「AI 过程消息」补一行「已自动生成迁移报告：<md>　结论：…　风险：…」，并把 ⑦ 屏顺手渲染成这次结果（不强制切屏）；失败只留一行原因，不打断任何东西 |
| 断言 | `ui_report` 增 `autoReportDone / autoReportPath / autoReportRisk / autoReportErr` |
| 探针 | `LINGQU_UI_PROBE=autoreport`：喂一个"已跑完（finished=true）"的状态夹具，断言页面**自己**去出报告 |

### 证据（清空报告目录后跑探针）

```
删除 …\juCang\.lingqu\report\*  → 启动 LINGQU_UI_PROBE=autoreport
tag=auto-report-ok  autoReportDone=True  risk=中  err=
  path=C:\Users\yang\lingqu-workspaces\juCang\.lingqu\report/juCang.md
报告目录重新出现：juCang.md 4280 B / juCang.html 6190 B / juCang.json 6131 B（21:57:16）
errorCount=0
```

### 未验证

- 真实整轮 AI 迁移（21:45 那轮）跑完时**还没有这段代码**，所以"真实回合结束时自动触发"没在本轮亲眼见到——
  探针证明的是同一段逻辑（同一入口 `renderAiPort`、同一判定 `finished`）。
- 若报告生成失败（比如工程路径已删），界面只有一行错误，不会重试——按"手刹在人这边"的惯例没做自动重试。
## [0.39.53] - 2026-11-02

**主题**：把上一轮查出的两个"卡点"真解决——**HAP 装配过的**（新规则 R2-PORT-015）＋ **AI 回合的轮次预算抬上去**。

### 背景（0.39.51 查出的两条）

- juCang 的 `gen/ohos/entry/hvigorfile.ts` 带着 tauri 钩子，运行时 `cargo tauri ohos dev-eco-studio-script`
  要读 dev server 的 addr 文件 → tauri-cli panic → hvigor `00308018` → HAP 装不出来 → 迁移停在那儿；
- cjh `max_iterations: 40`，整应用迁移 41 轮就被截断，agent 没回合收尾。

### 处置

| 面 | 内容 |
|---|---|
| **新规则 R2-PORT-015**（`src/port/hvigor.cj`，auto 档） | 命中 `dev-eco-studio-script` 的 hvigorfile → **只注掉 `.afterRun(buildRustCode)` 那一行**（加 `lingqu: R2-PORT-015` 标记 + 4 行原因注释），文件其余结构一字不动；幂等；没有该脚本的工程**不判命中**（不乱改别人的钩子）；备份 `hvigorfile.ts.bak` 并接入 `revertPairs()`（5 → 6 条） |
| **轮次预算**（`src/cjh_settings.cj`） | `ensureCjhIterationBudget`：`t2h:autoport_start` 开跑前把 `max_iterations` 抬到 **120**（`AUTOPORT_MIN_ITERATIONS`）；**只抬不降**；先走 live（`POST /api/settings`，引擎在跑也立刻生效），live 不通才落 `settings.json`（`settings.json.bak.autoport` 备份 + 文本定点修补，不重排 JSON）并注明"需重启 cjh"；结果回投 `t2h:autoport_start` 的 `iterationBudget` |

### 证据（都是真跑）

```
1) R2-PORT-015：lingqu-cli port --path …\juCang --apply
   rules=15；R2-PORT-015 applied=True tier=auto
   hvigorfile.ts:  L25 `// lingqu: R2-PORT-015 注掉 tauri 的 Rust 构建钩子：它跑`
                   L29 `// node.getTaskByName('default@ConfigureCmake')!.afterRun(buildRustCode);`
   备份落地：.lingqu/port/juCang/ 下新增 hvigorfile.ts.bak

2) 修后重跑装配：lingqu-cli hap --path …\juCang
   修前：ok=false  built=false  hapBytes=0        firstError=00308018
   修后：ok=true   built=true   hapBytes=15338218  （15.3 MB HAP 真的出来了）
   仍 signed=false —— 签名材料还没配（下一步，见下）

3) 轮次预算 live 生效：POST /api/settings {"maxIterations":120} → {"ok":true}
   GET /api/settings → "maxIterations": 120（无需重启引擎）
```

- 单测 **372 例全 PASS**：新增 `hvigor_rule_test`（4 例：只注一行 / 幂等 / 不乱改别人的钩子 / 回滚表覆盖）
  与 `cjh_settings_test`（3 例：读取 / 只抬不降 / 缺键插入 / camel 写法）。
- 顺手把 `port_revert_test` 的 `revertPairs` 断言从 5 改成 6——那条用例存在的意义就是拦住"改了文件没进回滚表"。

### 踩到的一个坑（已进 AGENTS §4-115）

**同一个设置有两种拼写**：`~/.cjh/settings.json` 里是 `max_iterations`（snake），
而 `GET /api/settings` 返回的是 `maxIterations`（camel）。只认一种的话，live 路径会误判"读不到"，
白白回落到"改文件 + 需重启"。现在 `maxIterKeyOf()` 两种都认，单测钉住。

### 未验证 / 下一步

- **juCang 的签名没做**（`signed=false`）：`com.dicing.jucang` 这个包名本机没有材料，
  要跑 `lingqu-cli sign --auto --path …\juCang`（AGC 云签发，**需要浏览器授权一次**，计入 A3 人工介入）。
  签完才能 `deploy` → `verify`。
- `autoport_start` 的预算是"设好了"，但**没真跑一轮 120 轮的迁移**验证它不再被截断**。
- 规则只注掉 `.afterRun(` 那一行；若某个工程的钩子写法不同（没有 `.afterRun(`），规则会如实报"没找到，不动"。
## [0.39.52] - 2026-11-02

**主题**：把「迁移过程日志」换成**「AI 过程消息」**——用户要看的是 AI 说了什么。

### 现象（用户实测）

> 进度下面的迁移过程日志，看着没有什么用，不行还去掉吧，我以为能显示 ai 的响应信息呢，
> 如果可以的话可以显示 AI 回复的信息

### 判断

0.39.50 那块记的是「每步开始 / 通过 / 未过 / 跳过」——而**上方进度条已经把 8 步状态全列了**，
重复信息，看着确实没用；用户真正缺的是"AI 正在干什么、它说了什么"。

### 处置

| 面 | 改成 |
|---|---|
| ④ 屏（① 屏一键迁移）那块卡 | 标题「AI 过程消息」，只放两样：① **AI 真正的流式叙述**（`delta` 增量合并成段，120ms 合批重绘，Markdown 渲染）；② **工具失败摘要**（成功的不放——右栏有工具卡与 bash 原文）；回合结束补一行「回合结束：<原因>」；新一轮自动清空 |
| 喂数来源 | `onFrame` 的 `delta`（仅当 AI 自动迁移/确定性流程在跑时）＋ `fillToolResult(isError)` ＋ `turn_done`；**与右栏同一条流**，不新增轮询、不重复解析 |
| 删掉的 | 0.39.50 的 `noteMigrateProgress`（步骤状态时间线）与它的 `MIG_LOG` 状态——与进度条重复 |
| 断言 | `ui_report.migLogLines/migLogLast` → **`migAiLines/migAiLast`**；探针 `LINGQU_UI_PROBE=miglog` 改为喂三帧 delta + 一条工具失败 |

### 顺带：把「页面静默失效」变成门禁能抓的错

改 `index.html` 时用行范围替换，**多留了一个 `}`** → 页面整块 JS 不执行：窗口照起、界面全空、
连 `ui-report.log` 都不生成（又是一个"点了没反应"）。`cjpm build` 与 `cj-tauri check` **都看不见**这种错。
现在门禁新增 **`[3b/5] 页面脚本语法`**：用 `node --check` 抽取 `index.html` 里的 `<script>` 块逐个检查
（没有 node 就跳过并说明，不阻塞其它闸）；判据进 `RESULTS`（`js-syntax:PASS/FAIL`）。

### 证据

```
LINGQU_UI_PROBE=miglog（夹具：两帧 delta + 一条工具失败）
  migAiLines = 2
  migAiLast  = err 工具 bash 失败：exit code: 1 执行 t2h:hap 失败：IllegalArgumentException: Invalid utf8 byte sequence
  errorCount = 0
五道闸全绿：build-biz:PASS test:PASS check:PASS js-syntax:PASS build-app:PASS build-cli:PASS
```

### 未验证

- **真实迁移回合下的观感没跑**（夹具只验证了"能显示、按段落合并、失败会单独一行"）；
  AI 叙述很长时在 260px 高的卡片里的阅读体验要你实际跑一次才知道。
- 确定性流程（`t2h:migrate`，不经过 AI）时这块保持空态，只有工具失败行——这是设计，不是缺数据。
## [0.39.51] - 2026-11-02

**主题**：一次失败的迁移被查清——三个原因，修掉两个半，并把"为什么停"从此说清楚。

### 现象（用户实测）

> 回合结束 · 轮次 41 · 工具 54 · 157.5s，移植中途失败了，ai 也不反馈个信息提示吗？就这么停在这了，
> 检查下日志分析下原因吧

### 排查（只看证据：`.lingqu/agent/trace.jsonl` 253 行 + 落档 + cjh 设置）

1. **agent 最后做了什么**（trace 末段）：装 ohpm 依赖时 `cmd //c ohpm.bat` 撞上
   `BATCH RECURSION exceeds STACK limits`，它自己改用 `node pm-cli.js install --all` 成功 →
   然后跑 `lingqu-cli hap --path .` → **`exit=1`：执行 t2h:hap 失败：IllegalArgumentException: Invalid utf8 byte sequence** →
   紧接着 `turn_done {"rounds":41,"tools":54,"duration_ms":157463}`。
2. **为什么"回合结束"**：`~/.cjh/settings.json` 的 `max_iterations: 40` ⇒ 41 轮正好撞上限，回合被截断。
3. **落档现状**（`juCang/.lingqu/tasks.json`）：scan / deps / port / build **done**，
   **hap failed**（`HAP 0 字节 / arm64 条目 0`），sign / deploy / verify **pending**。

### 根因三条

| # | 根因 | 归属 |
|---|---|---|
| A | `stripAnsi` 里 `out += String.fromUtf8([bytes[i]])` —— **逐字节转 UTF-8 是炸弹**：中文/GBK 的一个字节本身不是合法 UTF-8，hvigor/ohpm/cmd 的输出里两样都有 ⇒ `t2h:hap` 秒抛异常、落档写成「HAP 0 字节」（§4-41/§4-62 同族） | **我们的 bug** |
| B | 轮次预算用完（cjh `max_iterations: 40`），而界面 `turn_done` 只写一句"回合结束"，**不解释为什么停、也不贴最后一条工具报错** | 我们的界面 |
| C | 修掉 A 之后暴露的真因：hvigor 报 `00308018`，真 trace 是 `cargo tauri ohos dev-eco-studio-script` → `failed to read missing addr file %TEMP%\com.dicing.jucang-server-addr` → **tauri-cli 自己 panic**（那条钩子只对 `tauri ohos dev` 有效） | 样本工程 + 缺规则 |

### 处置

- **`lenientUtf8`（`compiler/hap.cj`）**：逐字节宽容解码，非法字节换 `?`、**永不抛**；`stripAnsi` 改成
  攒 `ArrayList<Byte>` 再整体解；`main.cj` / `sign_tool.cj` / `sign_login.cj` 里 **22 处**命令行输出解码统一走它
  （hvigor / ohpm / cmd 的输出会带 GBK）。
- **界面说清"为什么停"**：`turn_done` 时判定原因（轮次预算用完 / 上下文长度上限 / 回合异常 / 模型自己结束），
  并**贴出最后一条工具报错**（`CJ.lastToolErr`，新回合开始时清零；`CJ.maxIterations` 取自设置）：
  `为什么停：轮次预算用完（41/40，cjh 的 max_iterations）……最后一条工具报错（bash）：执行 t2h:hap 失败：…`
  `ui_report` 增 `turnEndReason / lastToolErr / lastToolErrName`。
- **新指纹 FP-020 + `hapSignHint`**：`00308018` / `dev-eco-studio-script` / `server-addr` 三种痕迹都翻成
  「现象 → 根因 → 修法」，agent 不必再反复试签名、重装依赖（省轮次，D-015）。

### 证据

```
修前（trace 20:42:57）：lingqu-cli hap --path …\juCang
  → exit=1 执行 t2h:hap 失败：IllegalArgumentException: Invalid utf8 byte sequence
修后（同一命令、同一工程）：
  → 能跑完 hvigor，报真实错误 00308018；.lingqu/hap/juCang.log 里的 trace 是
    `cargo tauri ohos dev-eco-studio-script` + `failed to read missing addr file …-server-addr`
  → HAP 闸失败行现在带人话：「hvigor 的 tauri 钩子失败（00308018）……让 hvigorfile 不跑这个钩子」
单测：lenientUtf8 三例（ASCII/中文/GBK/截断/破坏序列）+ stripAnsi 保中文 + FP-020 命中；
      cjpm test TOTAL=364 FAILED=0，五道闸全绿。
```

### 未验证 / 下一步

- **没端到端跑通 juCang 的 HAP 装配**：真因 C 需要「让 `gen/ohos/entry/hvigorfile.ts` 不再跑那个钩子」。
  这该是**迁移规则**（`t2h:port` 加一条 R2-PORT-015，带备份可回滚），本轮只做了"报清楚"，没做"自动修"。
- cjh 的 `max_iterations` 是否该为 autoport 调大，未实测；本轮只做到"解释 + 让你点继续"。
## [0.39.50] - 2026-11-02

**主题**：一键迁移屏加「迁移过程日志」——过程不再只能去右栏看 bash。

### 现象（用户实测）

> 能否在一键迁移那个页面的进度下面区域，展示下日志窗口啊？当前仅能在右侧的窗口里看到 bash，
> 其他的都看不到过程了

### 现状与根因

① 屏当时只有三样东西：进度条、每步的 `待跑 / 进行中 / 通过 / 未过 / 跳过`、结果卡。
**过程**（某步什么时候开始、落档摘要是什么、为什么跳过、引擎此刻在做什么）在页面上没有出口，
只能从右栏 AI 的工具调用里"旁证"——而 AI 只是其中一条路径：**确定性流程连 AI 都不经过**，于是完全看不见。

### 处置

- ① 屏进度卡**下面**新增「迁移过程日志」卡（`#migrateLog`，260px 可滚，空态写"还没有开始"）。
- 数据源是**同一份轮询状态**：`t2h:migrate_status` 与 `t2h:autoport_status` 都经 `renderMigrate`，
  这里把它翻译成时间线：
  `开始一键迁移：<工程>（设备文案）` → `▷ 开始「<步>」（第 i/8 步）` → `✔ 通过 / ✘ 未过 / ↷ 跳过「<步>」：<落档摘要>`
  （带该步 `at` 时间）→ 引擎当前动作 `message`（值变了才记）→ `结束：<verdict>　报告：<路径>`。
- **幂等**：每步按判定签名（`ran|ok|skipped`）去重，同一状态不重复刷；**新一轮开始时清空**
  （日志只属于本次运行，不跨轮混看）；上限 300 行，自动滚到底。
- 可断言：`ui_report` 增 `migLogLines` / `migLogLast`；探针 `LINGQU_UI_PROBE=miglog`（固定夹具喂三轮状态）。

### 证据

```
LINGQU_UI_PROBE=miglog（夹具，不跑真迁移、不改工程）
  migLogLines = 11
  migLogLast  = ok 结束：迁移完成：8 步 8/8，可用率 100%
  errorCount  = 0
```

- 五道闸全绿：`cjpm build` 0 warning ／ `cjpm test`（TOTAL=360，FAILED=0）／ `cj-tauri check` ／
  `targets/desktop` 0 warning ／ `cli` 0 warning。

### 未验证

- **没在本轮真跑一次一键迁移**（分钟级且会改样本工程）：日志行是按同一份状态形状渲染的，
  但"真实 8 步跑完的日志观感"要你点一次才算验过。
- AI 自动迁移（`autoport_status`）只共享 `rows` / `verdict`，没有 `message` / `current` 字段，
  所以 `▷ 开始某步` 与"引擎当前动作"这两类行只有确定性流程会出现；AI 路径看到的是
  `✔/✘/↷` 的步骤变化与结束句。要把这两类也补齐，得给 `autoport_status` 加字段（下一轮可做）。

## [0.39.49] - 2026-11-02

**主题**：把界面上剩下的假数据**全清掉**，一个不留；并加一道"假数据回归闸"。

### 现象（用户实测，先是一处，后来是全仓排查）

> 实时日志占位示意 · P5 接真数据　占位示意，这个是假的展示？没有数据吗还是没有做啊？
>
> 排查下还有哪些假数据，都得处理掉啊，数据从真实的来。

### 排查结果：一共 7 处，分布 3 个屏 + 1 个面板

| # | 位置 | 假的是什么 |
|---|---|---|
| 1 | ④ 屏「实时日志」 | **写死 14 行示例**（`15:42:01 [R1-002] 生成 rust-toolchain.toml…`）+ 徽标「占位示意 · P5 接真数据」（P5 早就做完了，这句也过期） |
| 2 | ⑤ 屏「流水线」 | 5 格写死 `3m12s / 匹配 ✔ / 1m05s / debug`（编造的耗时） |
| 3 | ⑤ 屏「产物 · .so」 | 写死 `libgrove_lib.so 4.71 MB` |
| 4 | ⑤ 屏「产物 · HAP」 | 写死 `12.4 MB · v1.2.0` |
| 5 | ⑤ 屏「真机」 | 写死 `2in1 · HarmonyOS 5.0.0(12) / hdc 已连接` |
| 6 | ⑤ 屏「构建输出」 | 写死 7 行示例编译日志 |
| 7 | ① 屏「最近项目」 | **写死 5 行工程表**（`habit-tree 86 / cc-switch 72 / …`），旁边注着「示意数据。扫描器接入后就是真实数据」——扫描器早就在用了，这句注释本身就是谎 |
| 8 | 右栏 AI 面板 | 写死**三段示例对话**（一句「先看一眼环境体检的结果」+ 一张假工具卡「8 项体检 → 就绪 7 / 缺失 1 ✘ llvm-mingw…」），看着跟真会话一模一样 |

2–6 与 7、8 都**没有任何标注**，长得跟真数据一样（AGENTS §4-94 那一课，`mockLeft` 这条断言从 0.39.49 起守着）。

### 处置

| 面 | 改成 |
|---|---|
| ④ 屏「实时日志」→ **「执行日志」** | 只记真发生过的事（命令 / 结果 / 关键数字 / 指纹命中 / 产物路径）；环形缓冲 200 行 +「清空」；没跑过就明说「还没有执行任何步骤」。④ 屏改造按**逐条规则**记（id / 已改·需人工·跳过） |
| ⑤ 屏「流水线」 | 5 格真实状态（交叉编译 / 前端指纹 / HAP 装配 / 签名 / 安装），从本次运行结果推；没跑过就是「—」，**不编时长** |
| ⑤ 屏产物三卡 | `.so` 真实路径 + exit/err/warn + 指纹一致数；HAP 真实路径 + 大小 + 是否签名 + rawfile 数；真机真实 serial + 安装/启动结果 + 签名态 |
| ⑤ 屏「构建输出」 | 本次真实 stderr 尾部（≤24 行）；没跑过就明说「还没跑交叉编译」 |
| ① 屏「最近项目」 | 改成**按落档发现**：复用 `t2h:batch` 的发现结果（`sampleSource=workspace/remembered/…`），只有真有 `.lingqu` 的工程才出现；一行都没有时写「还没有迁移过的工程」——**空着比编五行假数据诚实** |
| 右栏 AI 面板 | 三段假对话 → 一张「对话还没开始」的空状态说明卡（有真消息/真历史就撤掉，`renderHistory` 空历史时再放回） |
| 重复刷日志 | 切屏会把 `renderPort` 重绘一遍 → 之前会把 30 条规则重复写进日志。`LOG_ONCE`：只有命令跑完那一次才记 |
| **假数据回归闸** | `ui_report` 增 `fakeLeft`：把「绝不可能出现在真实界面里」的示例串（`libgrove` / `ui-9f3a` / `ColorPicker.vue` / `com.grove.habittrees` / `tauri/examples` / `3m12s` / `1m05s` / `2in1 · HarmonyOS` / `就绪 7 / 缺失 1`）扫整页文本，**必须 0**；另有 `mockLeft`（还剩几块「占位示意」块，必须 0）、`projRows`/`projListSrc`（最近项目是真发现出来的） |

### 证据

```
冷启动（LINGQU_SCAN_PATH=…\juCang，清空 ui-report.log）
mockLeft=0   fakeLeft=0      ← 页面上既没有「占位示意」块，也没有任何示例串
projRows=1   projListSrc=workspace   ← 最近项目按落档发现（发现 1 个真有 .lingqu 的工程）
execLogLines=1   errorCount=0
```

- 五道闸全绿：`cjpm build` 0 warning ／ `cjpm test`（**TOTAL=360，FAILED=0**）／ `cj-tauri check`
  （`sync desktop` + `sync ohos` 后）／ `targets/desktop` 0 warning ／ `cli` 0 warning。

### 未验证

- ⑤ 屏「真数据」本轮只在 **idle 分支**验过（没跑分钟级 `cargo build`）；跑一次真实编译后
  阶段条应从 `idle` 转 `ok`，属正常路径但没在本轮重跑取证。
- ① 屏「最近项目」只验了 `workspace` 来源（发现 1 个工程）；`remembered` / `explicit` 两条来源
  没在同一轮里逐个复跑。
- 执行日志只存内存（关窗即清），没有落盘——要不要落 `.lingqu/ui-log.txt` 另议。

## [0.39.48] - 2026-11-02

**主题**：点「克隆」什么都不发生——真因是**顶层作用域调内层函数**（AGENTS §4-107 同一课），
外加「把 Git 地址填进工程路径」这件事界面上零指引。

### 现象（用户实测两条）

> 我测了下点克隆，输入项目地址：https://gitcode.com/qq8864/juCang，没有反应，也不知道发生了什么，
> clone 的项目在哪里，有没有成功。然后我点迁移画像，提示扫描失败：路径不存在：https://gitcode.com/qq8864/juCang

### 根因（先取证，不猜）

1. **后端本来就是好的**：`lingqu-cli git_clone --url https://gitcode.com/qq8864/juCang`
   → `ok=true`、落到 `C:\Users\yang\lingqu-workspaces\juCang`、`hint=像一个 Tauri 工程（有 src-tauri/）`。
2. 现场 `ui-report` 两条硬证据：`currentProject=https://gitcode.com/qq8864/juCang`（**地址被当成了工程**）、
   **`uiErr=3`**（界面有三个异常）。
3. 先给 `ui_report` 补 `uiErrText`（以前只报条数 = 知道出事但不知道什么事），重跑一次就抓到原文：
   ```
   Uncaught ReferenceError: reportUi is not defined @about:blank:7577
   ```
   —— 克隆按钮处理器里 `reportUi('clone-start')` 抛异常，**它后面那行 `invoke('t2h:git_clone')` 从未执行**。
   所以"没有反应"是字面意义的：`invoke` 根本没被调用，git 一次都没跑。
4. 作用域实况：`reportUi`(L6212) / `invoke`(L2588) 缩进 2（内层作用域），而 `setCurrentProject` /
   `cloneNote` / `openClonePanel` / `initProjectBar` 全在顶层 —— 外层引用内层符号，异常只落
   `window.onerror`，调用方与 promise 都看不见（§4-107 已经踩过一次，这次是第二个受害者）。

### 处置

| 面 | 改了什么 |
|---|---|
| 作用域（真因） | 内层把能力挂出去：`window.__reportUi` / `window.__invoke`；顶层加**同名薄包装**转交（内层未就绪时 `reportUi` 静默跳过、`invoke` 返回 rejected promise，不崩）。克隆那组处理器一行没改就复活了 |
| 地址 ≠ 路径 | 新增纯函数 `looksLikeGitUrl`（后端 `src/git_clone.cj` + 前端同口径）：前端 `setCurrentProject` 见到地址**不设工程**，直接打开克隆面板、填好地址、明说「这是 Git 地址，先克隆」；`rememberProject` 也不再记地址（否则下次启动又把地址当工程带回来） |
| 命令文案 | `projectPathRejectReason`（scan / port / deps 共用，把三处重复判断收成一处）：地址 → 「这是 Git 地址，不是本地工程目录…先点「克隆…」」；真不存在才说「路径不存在」 |
| 克隆要看得见 | 每秒刷一次「正在克隆… Ns（depth、目标目录）」（git 的输出要等结束才回，没心跳就像卡死）；成功后一句话说清**克隆到哪 / 像不像 Tauri 工程 / 下一步点哪**；**回车 = 开始克隆** |
| 可观测性 | `ui_report` 增 `uiErrText`（异常原文，最多 3 条）、`cloneNote`、`cloneBusy`、`cloneTarget`、`gitUrlGuard`、`projRestoreSkipped` |
| 带回来先判存在 | `shouldRestoreLastProject(last, existsOnDisk)`（纯函数，带单测）：上次工程已被删/移走时**不带回来**（0.39.44 文档里如实记过这个缺口；这次实测撞上——上次指向 `juCang-2`，目录已删，顶层仍显示它，点 ② 只会得到「路径不存在」）。存在性由后端 `exists()` 判（页面没有 FS 能力） |
| 探针 | 新增 `LINGQU_UI_PROBE=clone`：先把地址填进工程路径（应被拦）→ 再走真实克隆 → 逐步回投；`LINGQU_CLONE_URL` / `LINGQU_CLONE_DIR` 可指定，默认克隆到仓内 `.lingqu/clone-probe`（**探针不往用户工作区堆副本**） |

### 证据

```
LINGQU_UI_PROBE=clone（LINGQU_CLONE_URL=https://gitcode.com/qq8864/juCang）
  clone-panel        proj=（空）        open=True  guard=1
  project-url-guard  proj=（空）        note=这是 Git 地址，不是本地工程目录——点「开始克隆」（或按回车）…
  clone-start        busy=True          note=正在克隆… 0s（depth=1）
  clone-running      busy=True          note=正在克隆… 1s（depth=1，克隆到 工作区根；网络慢时可能要几十秒）
  clone-ok           busy=False         target=C:\Users\yang\lingqu-workspaces\juCang
                     note=已克隆到 …（像一个 Tauri 工程（有 src-tauri/））——已设为当前工程，现在可以去 ② 迁移画像点「重新扫描」
  全程 errorCount=0；修前同一序列是 uiErr=3 + `ReferenceError: reportUi is not defined`
```

- 纯函数单测：`looksLikeGitUrl`（https/http/ssh/git/file/scp 六种形态 + 本地路径与 `C:\` 反例）、
  `projectPathRejectReason`（空 / 地址 / 不存在 / 存在四档）、`shouldRestoreLastProject`（存在/不存在/空三档）。
- **五道闸全绿**：`cjpm build` 0 warning ／ `cjpm test`（**TOTAL=360，FAILED=0，ERROR=0**）／
  `cj-tauri check`（版本号变动后按 §4-11 跑了 `sync desktop` + `sync ohos`）／
  `targets/desktop cjpm build` 0 warning ／ `cli cjpm build` 0 warning。

- 「上次工程已被删」这条也做了端到端取证（把 `juCang-2` 删掉后重启）：

  ```
  projRestored=backend-missing
  projRestoreSkipped=C:\Users\yang\lingqu-workspaces\juCang-2   ← 不再带回来
  currentProject=C:\Users\yang\lingqu-workspaces\juCang
  scanErr=（空） scanR=31 scanC1=100 scanTotal=82 errorCount=0
  ```

### 未验证

- 鸿蒙 ArkWeb 侧未跑同一序列；克隆依赖本机 `git`（`LINGQU_GIT` 或 PATH），
  **代理 / 网络受限环境未实测**（本次走的是公网直连，gitcode 有一次 redirect 警告）。
- 顶栏「打开工程」用的 `pickDirectory` 本来就只依赖 `window.__CJ_TAURI__`（不碰内层符号），未受影响，但也没重测。

## [0.39.47] - 2026-11-02

**主题**：迁移报告补上**风险分级**——需求原文硬要求的一项此前整块缺失；顺带把「5 样本矩阵」改名归位。

### 现象（用户对照原型图发现）

> 对了下原型图，发现迁移报告里，漏了风险等级这一项，补上吧。这很重要，可以让用户知道当前虽然移植成功了，
> 但还有哪些可能的潜在问题。

### 根因

`docs/需求.md` 原文写的是"输出结构化迁移报告，**支持风险分级**与断点续迁"，`docs/需求追踪.md` 的 C5
也把"风险分级"列进去了，但代码里只有三段式（做了什么 / 没做什么 / 需要你做什么）——
**`grep 风险 src/` 里没有任何实现**。三段式回答不了用户最关心的那句："既然成功了，还剩哪些坑？"

### 处置

| 面 | 改了什么 |
|---|---|
| 纯函数层（新） | `src/report/report.cj`：`RiskItem`（项/级别/影响面/处置）、`ReportRisk`（明细 + 各级计数 + `overallLevel()`）、`riskLevelLabel`、`riskSummaryLine`、`assessRisks(facts)` |
| 判定口径 | 只用落档事实推级别：编译/装配/部署判定、清单三类（失败/未验证/平台限制）、签名两态、前端指纹、人工介入、依赖不可用、没跑的步骤；**没有落档的步骤只写"无法评估"，不当成"没问题"** |
| 收数 | `src/report_feed.cj`：新增 build / hap / deploy / deps 四份落档的判定字段（`*Ran` 标记"跑过没有"，与"跑过没过"分开） |
| 命令 | `t2h:report` 回投 `riskLevel / riskLabel / riskSummary / riskHigh / riskMid / riskLow / riskItems[]`；JSON 落档 `lingqu/report/v1` 增 `risk` 段（**新增字段**，不改 schema 名） |
| 导出 | Markdown 与 HTML 都在**结论之后、三段之前**插入风险表（总体一句 + 四列表格 + 口径说明）；HTML 用 `lv-high/mid/low` 胶囊染色 |
| 界面 | ⑦ 屏新增「风险分级」卡片（总体胶囊 + 四列表格），排在**三段式下面**；`ui_report` 增 `reportRisk / reportRiskLabel / reportRiskRows / reportRiskHi / reportRiskSum`（白名单两处一起加，§4-60） |
| 探针 | 新增 `LINGQU_UI_PROBE=risk`：切 ⑦ → 真出一次报告 → 回投上面五个字段 |
| 矩阵归位 | 用户指出"5 样本是验收要求，不是界面要求"：卡片从「5 样本迁移矩阵（T7-3）」**改名为「迁移矩阵」**，挪到**风险分级下面**；`t2h:batch` 与落档格式不变 |

### 证据

- **五道闸全绿**：`cjpm build`（0 warning）／`cjpm test`（**TOTAL=357，FAILED=0，ERROR=0**，新增 9 例）／
  `cj-tauri check`（先按 §4-11 显式跑了 `sync desktop` + `sync ohos` 消掉骨架漂移）／
  `targets/desktop cjpm build`（0 warning）／`cli cjpm build`（0 warning）。
- **CLI 实跑**（`lingqu-cli report --path E:\test\rust\habit-tree`，真机验证过、可用率 100% 的样本）：

  ```
  riskLevel   = mid        riskLabel = 中
  riskSummary = 总体：中（高 0 / 中 2 / 低 1，共 3 条）
  conclusion  = habit-tree：8 步完成 8/8（100%），核心功能可用率 100%，0 处人工介入
    [中] 1 项功能受平台限制（平台相关 API（5 处）按平台限制登记）
    [中] 签名是 debug 态            → 「不能上架」（AGC 不接受 debug 证书）
    [低] 10 个 crate 在 OHOS 不可用（共 453 个依赖）
  ```

  这就是本轮要的效果：**移植成功（100%）≠ 没有风险**——报告现在会把"还剩哪些坑"摊开，
  而且每条都能追到一份落档（sign / verify / deps）。
- **三份导出都带表**：`.lingqu/report/habit-tree.md`（`## 风险分级` + 四列 Markdown 表）、
  `.html`（`<h2>风险分级</h2>` + `lv-mid / lv-low` 胶囊）、`.json` 的 `risk` 段
  （`level=mid label=中 high=0 mid=2 low=1 items=3`）。
- **界面探针**（`LINGQU_UI_PROBE=risk`，`LINGQU_REPORT_PATH=E:\test\rust\habit-tree`）：
  `reportRisk=mid／reportRiskLabel=中／reportRiskRows=3／reportRiskHi=0／
  reportOrder=risk<matrix／reportMatrixTitle=迁移矩阵／errorCount=0`——最后两条正是"矩阵在风险等级下面"
  与"标题就叫迁移矩阵"的自动化断言（否则下次谁挪上去、改回旧名，没人发现）。

### 未验证

- 鸿蒙 ArkWeb 侧未跑同一序列（同以往各轮的边界）；真机 `ui_report` 只在 WebView2 侧采到。
- release 签名态下风险表是否如预期只剩"平台限制/依赖"两类项，本机没有 release 材料，未实测。

### 同批：文档口径对齐（无代码变更）

- **进度口径对齐到 0.39.46**（`docs/进度记录.md` / `docs/需求追踪.md` / `docs/实施路线图.md`）：
  - `进度记录.md` 的「一、现在到哪了」原停在 **0.29.0 / 183 例单测 / 四道闸 / 24 个命令**，与现状差约 10 个版本；
    现改为 0.39.46 / **348 例单测（42 个 `*_test.cj`）** / **五道闸** / **36 个 `t2h:*`**，并把 P4–P8 状态、
    A1 战果（2/5 样本真机可用率 100%）与当前瓶颈写进表和正文。
  - `需求追踪.md`：A1 `未开始` → `进行中（2/5）`；M4 / M5 / M6 / M7 分别补齐为
    「已实现已验证（release 态未验）/ 已实现已验证 / 进行中 / 进行中」；G8 单测数 114 → **348**；
    C1 的 `R=20（fe4/api4）`更正为 `R=24（fe7/api5）`（`ui_report.scanKindRows` 实测）；
    M3 的「出口判据 1 待 P5」更正为已由 0.14.0 取证，**只剩「规则命中率 ≥60%」没有统计口径**。
  - `实施路线图.md`：抬头「当前进度（0.21.0）」→ **0.39.46**；总览表 P5/P6/P7/P8 状态与
    T5-4/T5-6/T5-7 落地情况补齐；P5/P6/P7 三节各加「取证情况」；末节从「P5 的具体起手」
    换成「P7 收尾与 P8 起手」；横切事项的门禁由四道闸改为五道闸。
  - `会话交接.md`：按 `需求追踪.md` §五第 3 条（验收项变化须同步交接文档）加了「增量（0.39.12→0.39.46）」块，
    并把「未完成」与「下一步（P5）」两节的过期抬头标明为历史记录（AGC 自动签名已结清原「下一步 1」）。

## [0.39.46] - 2026-11-02

**主题**：AI 设置页的模型一项显示不对——**模型的显示名从来没渲染过**，「当前」也跟着含混。

### 现象（用户）

> 在 AI 助手的设置页面，发现读回来的信息展示不正确……展示的模型和模型名是错误的，当前

### 根因（先对账，再改）

先用新加的 `ui_report.settingsDump` 把「界面上到底显示了什么」原样回投，与 cjh 真值逐项对账：

| 项 | cjh `/api/settings` / `settings.json` | 面板显示 |
|---|---|---|
| baseUrl | `https://api.deepseek.com` | 一致 |
| model | `gpt-4o-mini` | 一致 |
| temperature / maxTokens / maxIterations | 0.7 / 16384 / 40 | 一致 |
| apiKey | `sk-3****8ae4`（cjh 掩码） | 一致 |
| 模型列表 | `[{id:"gpt-4o-mini", name:"GPT-4o mini"}, {id:"deepseek-chat", name:"DeepSeek V3"}]` | **只有 id，`name` 根本没渲染**，且「当前」胶囊在 DOM 里紧跟 id（`gpt-4o-mini当前`） |

两处缺陷：① `loadModels()` 只输出 `m.id`，`.modelitem .nm` 的样式写了却从没用过——**模型名从来没显示**；
② 「当前」取的是 `/api/models.current`，而真正决定行为的是 `settings.model`（两者不同时界面会撒谎）。

### 处置

- **列表项改成 `name` 主标签 + `id` 副标签**（对齐 cjh 自带 UI 的 `m.name || m.id`），「当前」胶囊独立成块不再粘在 id 上；
- **「当前」以配置为准**：`settings.model` 优先、`/api/models.current` 兜底；两者不一致、或配置里的模型不在列表里，
  都在列表上方亮一条 `warnbox` 说清，不静默；
- **区分「配置」与「本会话」**：会话级 `switch_model` 的 `ack` 回执带 `model`，现在记进 `CJ.sessionModel`，
  本会话切过就单独标「本会话」并提示"会话级覆盖、不改配置"；
- **「保存并生效」真的生效到本会话**：写完配置后，若本会话模型与配置不同且通道在线，补发一条
  `switch_model`（cjh 的优先级是「帧字段 > 会话级覆盖 > 配置」，只写配置对正在跑的回合不起作用）；
- 温度 `0` 不再显示成空（0 是合法值：贪心采样）；
- 新增 `ui_report.settingsDump`（字段值 + 模型列表的 id/name/是否当前 + 是否有提示行），
  白名单两处一起加（§4-60）。

### 证据

```
settingsDump = {
  "base":"https://api.deepseek.com","model":"gpt-4o-mini","temp":"0.7",
  "maxTok":"16384","maxIter":"40","state":"已连接",
  "endpoint":"http://127.0.0.1:8765 ws://127.0.0.1:8765/ws",
  "models":[{"id":"gpt-4o-mini","name":"GPT-4o mini","cur":true},
            {"id":"deepseek-chat","name":"DeepSeek V3","cur":false}],
  "curMarked":"gpt-4o-mini","sessionModel":"","warn":false
}
```
`LINGQU_UI_PROBE=1`（打开设置并读 /api/models）→ `errorCount=0`；`cjpm test` TOTAL=348 FAILED:0。

### 未验证

- 「本会话」徽标与 `switch_model` 补发只在通道在线时走通逻辑，**没有进行真实的模型切换实测**
  （会消耗用户的 API 额度并改变其运行中的模型）；鸿蒙 ArkWeb 侧未跑同一序列。

## [0.39.45] - 2026-11-02

**主题**：查清「页脚已连接、设置页却说引擎缺失」——不是引擎没了，是**状态渲染被一个 null 打断了**。

### 现象（0.39.44 交付时顺手观察到）

页脚「已连接 http://127.0.0.1:8765」、WS `ESTABLISHED`、外部 `curl /api/health` 200 且 20 次探活 0 失败，
而 `ui_report` 里 `cjhState=missing` 且 `cjhBin` 为空。

### 排查（先加证据，再下结论）

1. 先给状态回包加诊断串 `diag`（端口 / 最近一次探活失败原因 / 多久没成功 / `LINGQU_CJH` 是否可读 /
   查过的 vendor 目录 / 是否本应用托管），回投 `ui_report.cjhDiag`。**第一次跑就露了馅**：
   ```
   cjhState = unknown
   cjhDiag  = status_ipc_fail: Cannot read properties of null (reading 'style')
   ```
2. 真根因：`renderStatus()` 末尾写 `$('aiHint').style.display`，而**历史回放**里
   `chatBox().innerHTML = ''` 把常驻的 `#aiHint` 节点一起冲掉了。于是状态渲染每 5 秒抛一次
   `TypeError`，被 `loadStatus().catch` 吞成 `renderStatus({state:'missing'})`——
   界面从此**停止更新状态**，永远停在上一次渲染的结果，且报告里写着"缺失"。

### 处置

- **清屏保住常驻节点**：`renderHistory()` 先摘下 `#aiHint`，清完再塞回去。
- **渲染不再依赖别人保住 DOM**：新增 `ensureAiHint()`，节点缺了就重建。
- **IPC/渲染失败不再冒充"引擎缺失"**：新增 `unknown` 状态，文案「引擎状态未知（状态查询未返回）」，
  `title` 摊开真实原因；`unknown` 与 `missing` 一样，绝不盖过"通道还连着"这条更硬的证据。
- 新回投 `ui_report`：`cjhDiag`、`cjhPollFail`、`cjhPollLast`、`aiHintOk`（白名单两处一起加）。

### 证据

- 探针 `LINGQU_UI_PROBE=history`（喂一帧 `history_messages` 触发清屏）：
  修前 `cjhState=missing` + `status_ipc_fail: …null…style…`；
  修后 `history-restored` / `history-after-status` 两行都是 `aiHintOk=1`、`cjhState=running`、`cjhPollFail=0`。
- 正常冷启动连续采样 4 次（约 30 秒）：`cjh=running`、`cjhPollFail=0`、`aiHintOk=1`、`wsState=connected`，
  诊断串：`port=8765 lastErr= lastOkAgoMs=4976 envCjh=…\cjh\main.exe readable=true install=… vendor=vendor\cjh\win-x64 owned=false`。
- `cjpm test` TOTAL=348 FAILED:0；五道闸全绿。

### 未验证

- 只在本机（WebView2 / Windows）验证；鸿蒙 ArkWeb 侧未跑同一序列。

## [0.39.44] - 2026-11-02

**主题**：启动就带回上次的工程，左栏徽标立刻刷出来——不用每次开窗重新选一遍。

### 现象/反馈（用户）

> 加一条「启动时自动带回上次工程、并立刻刷徽标」

### 根因（两层）

1. **表层**：`initProjectBar` 只读 `localStorage['lingqu.proj']` 这一条键，键一空窗口就是
   「⚠ 未选工程」、左栏六项全「未开始」（`railFail=no-path`），每次开窗都得重新选一遍。
2. **真根因（本轮的意外发现）**：**本应用的页面里 localStorage 根本不能用**——
   探针 `LINGQU_UI_PROBE=store` 实测 `storeProbe = before||SecurityError|about://`：
   页面 origin 是 `about://`（不透明源），`localStorage.setItem` 直接抛 `SecurityError`。
   也就是说"记住工程 / 记住聊天窗宽度 / 记住偏好开关"这些**从来没生效过**，只是被
   `try{}catch{}` 吞掉了（AGENTS §4-111）。所以"记住上次工程"只能换一条通道。

### 处置

- **改走落档通道**（`localStorage` 那条留着做兜底，实机上恒为空）：
  后端新增纯函数 `lastProjectOf(jsonText)` + `lastProjectFromReport()`，读上一次
  `t2h:ui_report` 落的 `.lingqu/ui-report.json`（里面本来就有 `currentProject`），
  由 `t2h:env` 的 `lastProject` 回投给页面；页面在 `loadEnv` 里发现自己没工程时
  `setCurrentProject(lastProject)`，并立刻刷左栏徽标。
- 前端保留纯函数 `pickRestoreProject(saved, recent)`：`saved` → `recent[0]` → 空
  （第三档**不造默认值**，AGENTS §4-94）；输入容错 `undefined` / `null` / 非数组 / 全空白。
- 回投 `ui_report`：`projRestored`（`saved` / `recent` / `backend` / `none`）、
  `projRestorePath`、`restoreFail`、`storeProbe`；白名单同步加在 `src/main.cj`（§4-60）。
- 新增两个探针：`LINGQU_UI_PROBE=restore`（表驱动断言纯函数 6 种输入 + 种一次工程供下次启动验真）、
  `LINGQU_UI_PROBE=store`（写 localStorage → 刷新 → 读回，用 `stage|val|err|origin` 判定能否持久化）。
- 新增单测 `src/tests/ui_state_test.cj`（5 例）：正常路径 / 反斜杠路径 / 缺键 / 类型不符 /
  空文本与坏 JSON 不抛异常。

### 证据

- `LINGQU_UI_PROBE=store` → `storeProbe = before||SecurityError|about://`
  （**localStorage 被拒**，这也解释了为什么之前"记住"的功能全都不灵）。
- `LINGQU_UI_PROBE=restore` → `restoreFail = ''`（6 种输入全对）。
- 真实冷启动（同一 WebView2 配置目录，重启两次）：
  `projRestored=backend`、`projRestorePath=C:/Users/yang/Desktop/test/m3u8dl-tauri`、
  `currentProject=` 同上、`railBadges=profile=已完成 … build=已完成 3/3 verify=已完成 2/2`、
  `railFail=''`、`errorCount=0`、`wsState=connected`。
- `cjpm test` TOTAL=348 FAILED:0。

### 未验证 / 已知边界

- 「上次的工程已被删除/移走」没有存在性校验（界面没有廉价的存在性探针）；
  这种情形顶栏仍显示那个路径、徽标回落「未开始」，不会假装有数据。
- 落档在 `.lingqu/ui-report.json`，所以"记住"的范围跟着**工作目录**走：换了 CWD 启动
  （不同启动方式）就带不回来——与 ui-report 本身的落点一致，不算新问题。
- **聊天窗宽度（`lingqu.aiw`）与偏好开关仍在用 localStorage，因此重启后不记忆**（同一个根因）。
  这条没在本轮改：它们要么也走后端落档，要么等 cj-tauri 暴露"可持久化的偏好"能力。


## [0.39.43] - 2026-11-02

**主题**：左栏徽标的口径从「通过」改成「已完成」——它表示"这一步检查跑过没有"，不是"合不合格"。

### 现象/反馈（用户）

> 「左侧的迁移画像，依赖扫描，改造执行等的状态显示『通过』？是不不太合适？叫做完成是不是更合适些？
>   因为它好像不涉及是否是通过还是未通过，只代表了是否进行过检查吧」

### 处置

- `railBadgeOf()`（纯函数）文案改为：`未开始` / **`已完成`**（多步时 `已完成 k/m`）/
  `部分完成 k/m` / **`有失败 k/m`**。
- **失败仍然看得见**：落档里 `ok=false` 的步骤聚合出「有失败 N/M」（红色），
  但用词改成"有失败"而不是直接判"未通过"——徽标只说做过没有，具体判定看 `title`：
  `签名体检：已完成（判定失败）（拿不到设备 UDID…）`。
- 左栏项的 `.done` 勾只认「已完成」（`有失败 / 部分完成 / 未开始` 都不打勾）。
- 探针 `LINGQU_UI_PROBE=rail` 的断言同步改成：必须出现「已完成」、**不许再出现"通过"**、不许出现「待接入」。

### 一个真实例子（顺带说清"记录会过期"）

改完探针第一次跑出来是 `build=有失败 1/3` —— 不是 bug：`sign`（签名体检）的记录停在 14:42，
那会儿设备没连，判了"拿不到设备 UDID"（failed）；后来 15:50 的部署/验证是通的。
设备现在连着，重跑一次签名体检后变成 `build=已完成 3/3`。

### 证据（`LINGQU_UI_PROBE=rail`）

```
railBadges = profile=已完成 deps=已完成 port=已完成 build=已完成 3/3 verify=已完成 2/2 report=未开始
railFail   = （空）
```

### 未说明白的部分（如实标注）

- `report`（⑦迁移报告）仍在生成后才点亮，重启后回到「未开始」。
- 各步的**判定文字**（`.lingqu/<步骤>/*.json` 里的 note）没改，仍写"通过/失败"——那是判定本身的词，
  与左栏"做过没有"是两个层次。

## [0.39.42] - 2026-11-02

**主题**：状态轮询为什么偶发超时——查清了：`/api/health` 本身不慢，是**我们自己每次探活都新建 TCP 再拆掉**；顺手把「通道连着却报引擎缺失」也堵住。

### 现象（用户实测 + 追问）

> 启动起来报「AI 引擎缺失」，网页都能打开 `http://127.0.0.1:8765/`，说明 cjh 服务是在的。
> 状态轮询为啥会偶尔超时？

### 实测结论（先量再说）

| 场景 | 结果 |
|---|---|
| 空载串行 40 次 `/api/health` | min 9.8ms / avg 21ms / max 384ms（首次冷启动），**超过 1s 的 0 次** |
| 16 路并发 `/api/health`（node 单进程，排除进程启动开销） | p50 8ms、p90 9ms、max 106ms，失败 0 |
| 8 路并发压 `/api/sessions`（读全部会话）时穿插探活 | health max **15ms**，失败 0 |
| 30 次「新建连接→取完就关」（旧写法，`Connection: close`） | 8765 上留下 **30 个 TIME_WAIT** |
| 30 次 keep-alive 单连接 | **新增 0 个** |

⇒ `/api/health` 与引擎的 HTTP 层都不慢。**慢的是我们的探活写法**：
`cjhHealthy()` 每次都 `ClientBuilder().build()` → 请求 → `client.close()`，即**每 2 秒新建一条 TCP 再拆掉**；
而 cjh 侧对断开连接**不回收**（常驻 `CLOSE_WAIT`，`docs/上游回馈-cjh.md` 第 11 条）——
长会话里引擎 socket 表只涨不落，偶发一次建连/accept 慢过 3s，就判成"引擎不在"，
配合"发现路径也没找到二进制"（未设 `LINGQU_CJH` 时）直接落到 `missing` ⇒ 界面写「AI 引擎缺失」。

### 处置

- `src/cjh_host.cj`：探活改成**整条会话复用一条 keep-alive 客户端**（`gHealthClient`），
  出错才 `dropHealthClient()` 重建；churn 从「1 次/2 秒」降到「1 次/会话」。
- **判死要有证据**：`cjhStatusJson` 先单次探活 → 失败重试 3 次 → 仍失败但 **20 秒内成功过**
  就报 `running + unstable`（附 `note`），只有"最近没成功过且二进制也找不到"才报 `missing`。
- 界面兜底：**本侧 WS 还连着就绝不宣称引擎缺失**（`renderStatus` 用 `CJ.up` 修正状态），
  文案改成「引擎 已连接（健康检查变慢）」。
- 新增单测 `testCjhHealthyRecentlyWindow`（宽容窗口语义）。

### 证据

- 修后实测：重启应用轮询 50 秒（约 25 次探活）→ `TIME_WAIT=0`、`ESTABLISHED=3`、
  `cjhState=running`、`wsState=connected`（旧写法同条件下 30 次探活留 30 个 TIME_WAIT）。
- `cjpm test` TOTAL=343、FAILED:0；五道闸全绿。

### 未验证

- 没有在一次**真实 agent 长回合**里复测超时率（会占用用户的会话）；上面的结论是
  "探活写法与连接 churn" 这个可测部分。引擎侧 socket 不回收仍是上游问题（第 11 条），
  修好后对端不会再攒 `CLOSE_WAIT`。

## [0.39.41] - 2026-11-02

**主题**：① 活干完了不再喊「AI 连续 20 次轮询落档没有变化」；② 左栏步骤徽标不再是写死的「待接入」。

### 现象（用户实测，两条）

> 「最后还又显示这个 AI 连续 20 次轮询落档没有变化，建议点「停止」后让它总结，或直接接管。
>   这都成功了呀，为何还有这个显示呢」
>
> 「左侧的迁移画像、依赖扫描和改造执行等，无论是否执行过，都显示待接入，这有问题吧？」

### 根因一：停滞判定只看"有没有变化"，没看"该不该再变"

`t2h:autoport_status` 每次把 8 步落档压成一行签名（含 agent 轨迹行数、WS 帧数）丢进窗口，
窗口内 20 次全相同就判停滞。**活干完之后落档本来就不会再变**——于是迁移全绿、报告都生成了，
界面还在喊"绕圈、建议点停止"。0.39.34 只补了"还在干活"这一半（活动量/帧数），
把"已经干完"这一半漏了。

### 根因二：徽标是写死的示意文案

左栏那排 `<span class="badge">待接入</span>` 是 HTML 里的死字，`setCurrentProject()`
只更新输入框与胶囊，从没碰过它——落档里明明写着跑过没跑过（AGENTS §4-94 那一族）。

### 处置

- 新增纯函数 `autoportConcludedCount` / `autoportAllConcluded`：**通过 或 明确跳过**都算"有结论"；
  8 步全部有结论 ⇒ **不判停滞**（并清掉已攒的快照），`escalationLineFor(..., finished=true)` 返回空串。
- `autoport_status` 增报 `finished` / `concludedCount`；界面在 finished 时显示
  「全部步骤都已有结论（8/8，含明确跳过的）——活已经干完，落档不再变化属正常」，不再喊绕圈。
- 左栏徽标改由落档驱动：HTML 里换成空 `<span class="badge" data-badge="…">`，
  `renderRailBadges()` 按 `railBadgeOf()`（纯函数）聚合——一项可能由多步拼成
  （⑤构建打包 = build+hap+sign、⑥真机验证 = deploy+verify），文案 `未开始 / 通过 k/m / 失败 k/m / 部分 k/m`，
  整组通过时该左栏项还打 `.done` 勾；`title` 里列每一步的结论。
  ⑦迁移报告不在 8 步流水线里，只在**真的生成了报告**时点亮（`已生成 / 失败`）。
- 数据源用**已有的** `t2h:resume`（`action=status`，返回 `steps[]` 的 done/failed/skipped/pending），
  不新造命令；`ui_report` 增 `railBadges` / `railFail`。

### 证据（`LINGQU_UI_PROBE=rail` 实跑，工程 m3u8dl-tauri）

```
railBadges = profile=通过 deps=通过 port=通过 build=通过 3/3 verify=通过 2/2 report=未开始
railFail   = （空）
rows=8  ticks=4  uiErr=（空）
```

### 踩坑（已记 AGENTS §4-107）

左栏这段代码在**外层作用域**，而 `invoke` / `CJ` / `projectPathValue` 都在内层 IIFE 里——
直接引用会抛 `ReferenceError: xxx is not defined`，**只落到 `window.onerror`，调用方完全看不到**
（本次为此白查三轮：徽标一直是空的、却没有任何报错）。处置：外层只"读 DOM + 画"，
取数据走内层注册的 `window.__railBridge`；并用 `railsFail` 把这类被吞掉的错误回投出来。

### 未验证

- ⑦报告徽标只在本次会话点过「生成报告」后点亮；重启后仍显示「未开始」（没做"读盘判断报告是否存在"）。
- 停滞判定的"完工"只看 8 步是否有结论，不看 agent 回合是否真的结束（回合还在跑但落档已全绿时不会叫人，
  这是有意的：叫人按停止的代价比多等一会儿大）。

## [0.39.40] - 2026-11-02

**主题**：① 界面不再把「开始时的设备快照」当成"现在"，② 黑窗一闪一闪的根因（GUI 进程没有控制台）修掉。

### 现象（用户实测）

> 回合结束 · 轮次 28 · 工具 30 · 207.6s，进度 100%　未连接真机，我看都在真机上运行起来了，
> 还提示这个？且为啥 dos 的黑窗口现在还一闪一闪的弹出又消失啊？

### 根因一：设备状态是"一次性快照"，却被当成"现在"

- `migrateHasDevice()` 只在 `t2h:migrate` **开始那一刻**查一次（`hdc list targets -v`），
  存进 `MigrateState.hasDevice`，之后**永不再查**。
- 界面那行 `100%　未连接真机` 直接读这个快照 ⇒ 开始时没插设备、中途插上并在真机上跑通了，
  它还是写「未连接真机」。而落档里证据齐全：`.lingqu/deploy/m3u8dl-tauri.json` 写着
  `deviceCount: 1`、`serial: 3QC0124B20000048`、install/start 均 ok；
  `.lingqu/verify/*.json` 是 `ratePercent: 100`。现场 `hdc list targets -v` 也确有
  `3QC0124B20000048  USB  Connected`。

### 处置一

- `t2h:migrate_status` 增报**两条口径**：`hasDevice`（本次起始时的检测，决定要不要跳过
  deploy/verify）+ `deviceInRecord` / `deviceSerial`（读 `.lingqu/deploy/<工程>.json` 核实到的真机，
  新增纯函数 `deployDeviceOf`）。
- 界面 `deviceText()`：有起始检测 → `真机已连接`；没有但落档有记录 → `真机已连接（部署记录 3QC…）`；
  两者都没有才 `未连接真机（无部署记录）`；`title` 里写明两条口径的来源与"跳过"的原因。

### 根因二：GUI 进程没有控制台 ⇒ 每个子进程都新配一个控制台窗口

本应用是 `--subsystem=windows`：进程**没有 console**。于是
`std.process.executeWithOutput(...)`（hdc / cargo / node+hvigor / git / java / curl）每调一次，
Windows 就给子进程**新配一个控制台窗口**——用户看到的就是一个个黑窗一闪。cjh 走
`launchHidden`（DETACHED_PROCESS）也没有 console，它再拉 bash / find / lingqu-cli 时又各自新配一个。

### 处置二

- 新增 `src/win_console.cj`：`ensureHiddenConsole()` = `AllocConsole()` + `ShowWindow(SW_HIDE)`，
  让本进程持有一个**看不见的**控制台，子进程直接继承它，不再各自弹窗（单点修法，
  不去改几十处 spawn 调用点）。命令行走 `lingqu-cli` 时已有控制台，则**不动**（别去隐藏用户的窗口）。
- cjh 拉起方式：**有隐藏控制台时走 `std.process.launch`（继承）**，否则回落 `launchHidden`——
  继承后 cjh 的 bash / find / lingqu-cli 也继承这个看不见的 console。新增 `CjhHandle`
  把两种句柄（`BackgroundProcess` / `SubProcess`）收在一层，就绪等待与退出收尾不必分叉。
- `ui_report` 新增 `consoleHidden`（后端回投）、`deviceInRecord`、`migratePctText`、`deviceFail`。

### 证据

- `consoleHidden=true`；启动全套环境体检（会 spawn 多个 CLI）之后，`conhost` 进程**只多 1 个**
  （应用自己那个隐藏控制台），以前是"每个子进程一个"。
- 强制走「自己拉起」这条路（`LINGQU_CJH_PORT=8766`，不复用用户那只 8765）：
  cjh 以「继承隐藏控制台」方式拉起，`http://127.0.0.1:8766/api/health` = **200**，
  且 `conhost` 没有再多——证明继承生效、cjh 不再顶出黑窗。测试实例已清理，
  用户在用的 8765 引擎（pid 14668）全程未被碰，`/api/health` 仍 200。
- `LINGQU_UI_PROBE=device`：三种组合文案断言全过（`deviceFail=[]`）——
  `hasDevice=true`→「真机已连接」；`record-only`→「真机已连接（部署记录 3QC…）」；都无→「未连接真机（无部署记录）」。

### 未验证

- 「看不到黑窗」无法用程序断言，只能按机制证明：本进程 `consoleHidden=true` + 子进程继承
  （`conhost` 增量 = 1 而非 N）。**真实观感请以你这边的肉眼为准。**
- 鸿蒙（ArkWeb / 无 Win32）不涉及本项；`ensureHiddenConsole()` 在非 Windows 上是返回 false 的空实现。

## [0.39.39] - 2026-11-02

**主题**：聊天窗宽度**可拖动**（左右拖条 + 双击复位 + 记住宽度），参考本仓上游示例 cjnote。

### 需求

> 让聊天窗口可拖动调整宽度，这个调整宽度功能，在 cjnote 这个项目里是已实现的，可作为参考。

参考实现：`cj-tauri/examples/cjnote` 的 `#ai-resizer` + `--ai-w` 方案
（`ui/index.html:127-132`、`2003-2064`）。三条经验直接照搬：

1. **宽度写进 CSS 变量 `--ai-w`**，不直接改元素 `style` —— 折叠态/媒体查询才好配合；
2. **夹取要跟窗口走**：`min(上限, 窗口宽 − 左栏 − 拖条 − 内容区保底)`，
   否则窄窗口"拖到最大"会把中间内容挤成 0，那不是用户想要的最宽；
3. **`resize` 后按新空间重夹一次**，但**折叠态必须跳过**（`display:none` 量出来是 0，
   会把用户存的宽度冲成下限 —— cjnote 踩过，这里同样规避）。

### 处置（本仓）

- 版面 `.body` 从三列 `240px 1fr 372px` 改成四列
  `240px 1fr 6px var(--ai-w, 372px)`，中间的 6px 拖条 = `#aiResizer`
  （`cursor:col-resize`，hover/拖动时高亮成一根 3px 竖线）。
- 拖条在**右栏左缘**：往左拖变宽（增量取负），夹取 `260 ~ min(960, 窗口可用)`；
  **双击复位** 372px；拖动结束写 `localStorage['lingqu.aiw']`，启动时读回。
  与 cjnote 的差异：偏好存 `localStorage`（本仓没有 `store:set` 插件，
  不为一次界面偏好去加命令三处联动）。
- `body.ai-hidden` 时拖条与面板一起隐藏（`#aiResizer{display:none}`）。
- `ui_report` 新增 `aiW`（生效宽度）/ `aiResizerOk`（拖条真的可拖）/ `aiDrags`（拖过几次），
  白名单两处同时加；原有的 `aiDockW` 继续当"真的变宽了"的判据。
- 新增探针 `LINGQU_UI_PROBE=resize`：派发真实的 `mousedown/mousemove/mouseup`（走人手同一条代码路径）。

### 证据（`LINGQU_UI_PROBE=resize` 实跑）

| tag | aiDockW | aiW | resizerOk | drags | gridColumns |
|---|---|---|---|---|---|
| `resize-baseline` | 372 | 372 | true | 0 | `240px 646px 6px 372px` |
| `resize-dragged`（左拖 160） | **532** | 532 | true | 1 | `240px 486px 6px 532px` |
| `resize-clamped`（右拖 4000） | **260** | 260 | true | 2 | `240px 758px 6px 260px` |
| `resize-reset`（双击） | **372** | 372 | true | 2 | `240px 646px 6px 372px` |

即：能变宽、到下限会停住（不越界）、双击回默认；同时 `1fr` 的内容列跟着缩放，版面没有破。

### 未验证

- 只在 1264×801 视口上验过；更窄窗口（<900px）下 260px 下限 + 内容区 320px 保底
  是否会挤到横向滚动，没有实测。
- 鸿蒙（ArkWeb）侧未验证：`getComputedStyle(cursor)`、`MouseEvent` 派发在 ArkWeb 上的行为
  与 WebView2 可能不同，真机需复跑 `LINGQU_UI_PROBE=resize`。

## [0.39.38] - 2026-11-02

**主题**：「WS 已连接 ↔ 未连接」不再反复横跳 —— 一次状态误判不足以掐掉连接，且断开原因留痕。

### 现象（用户实测）

> 聊天窗口最下方又出现 `WS 已连接 · 帧 26 · s1793516546.122.109`，然后显示已断开，
> 然后又 `WS 已连接 · 帧 27 ·`（会话号没了）——这是为啥？连接存在 bug 吗？

### 根因（两处，都在我们这边）

1. **状态轮询的一次误判会掐掉连接**：`renderStatus` 里只要 `t2h:cjh_status` 回
   `state != running` 就立刻 `wsClose()`。而引擎忙于 SSE 流时 `/api/health` 会超过
   3s 超时 → 判成 `missing` → 关连接 → 800ms 后又连上 ⇒ 界面抽风。
   **证据**：0.39.37 的探针日志里同一个窗口出现过 `cjhState:"running"` → `"missing"`
   → `"running"`，而 `wsState` 一直是 `connected`、工具帧正常在收。
2. **会话号消失**是另一条链路：`reasoning_content` 自愈（0.39.36）会 `CJ.session=''`
   → 页脚只剩 `帧 N`，看着像"会话丢了"。

### 处置

- 新增纯函数 `wsKeepDecision(running, streak, busy)`：`keep` / `grace` / `close`。
  判据：**判掉 1 次只是疑似**（grace，不动连接）、连续 2 次**且不在干活**才 close；
  有工具在跑或有回合气泡时一律不断（跑命令时误杀代价最大）。
- 页脚把状态说清：`连接中…（第 N 次）` / `未连接 · 准备第 N 次重连` /
  自愈后 `WS 已连接 · 帧 N · 新会话（旧会话 s… 已弃用）`。
- 新增 WS 状态流水 `noteWsEvent()`（最近 8 条：`conn(#N)`、`closed(帧N)`、`close(status-miss2)`），
  回投 `ui_report.wsEventText` —— 下次问"为什么断了"直接看这条，不用猜。
- `ui_report` 新增 `statusFlapsSeen / statusFlaps / sessionRetired / flapCases / flapFail /
  wsEventText`（白名单两处同时加）。
- `LINGQU_UI_PROBE=flap`：对 `wsKeepDecision` 做表驱动断言（4 条，`flapFail` 为空才算过）。
- 上游：`docs/上游回馈-cjh.md` 第 11 条（断开的 WS 套接字留 `CLOSE_WAIT` 不回收，实测 15 个）。

### 证据（`LINGQU_UI_PROBE=flap` 实跑）

```
flap-cases | ws=connected | flapCases=4 | flapFail=[] | wsEvents=[conn(#0)]
```

四条判据全过、全程 `connected`、没有一次误断。

### 说明

- 当时现场还查到：**Chrome 里开着 cjh 自带网页 UI**（pid 21640 持有 4 条到 8765 的
  ESTABLISHED），引擎日志里每 5 秒一条 `Agent.interrupt` 就是那个页面的断开/重连触发的
  （cjh 的 disconnect 策略会取消在跑的回合）。**那不是灵渠的窗口**，用不着就关掉那个标签。
- 断线期间点了「停止」或在跑工具时，现在**不会**再因为状态误判把连接掐掉。

## [0.39.37] - 2026-11-02

**主题**：工具调用不再刷屏 —— 卡片**默认折叠**，标题行只留「工具 · 耗时 · exit · 行数」，点开看全文。

### 现象（用户实测）

> 聊天窗口里显示 `bash / 完成 / exit code: 0 / stdout: … {"id":"cjh","label":"AI 引擎 cjh（内置）","ok":true …}`，
> 一大堆这些信息是什么呀？看着刷屏不好看，且也不是什么关键信息。

### 根因

`fillToolResult` 把工具输出**整块铺在聊天区**（最多 2000 字），`addToolCard` 还把参数 JSON 全量放在卡面上。
agent 一个回合调十几次工具时，这些**中间产物**就把"模型说了什么"冲得看不见了。

### 处置

- `assets/ui/index.html`：
  - 工具卡片改为**默认折叠**（`.tool .tb{display:none}`，`.tool.open .tb{display:block}`），
    标题行 = 状态点 + 工具名 + **摘要** + 状态 + 折叠箭头；点标题行展开/收起。
  - 摘要由纯函数 `toolSummary()` 从输出里取关键信息：`exit code: 0` / `exit=0` / `[exit 1]` 的退出码、
    行数、字数；执行中则显示 `briefArgs()` 给的一行命令简介（`cat /tmp/env.json`，>46 字截断）。
  - **失败的调用自动展开**（错误必须第一眼看见），成功的一律折叠；`title` 里带首个非空行预览。
  - 展开区上限从 2000 字提到 8000 字（折叠后不再占版面，全文可以留得更全），超出标注"共 N 字，已截断"。
  - 断线重连的 `history_messages` 回放（`renderHistory`）同样改成折叠卡片，不再把 19 条工具输出铺一行行。
- `t2h:ui_report` 新增 `toolCardsOpen`（当前展开几张）/ `toolResultChars`（这轮工具输出总字数），
  白名单两处（`index.html` 的 `reportUi` + `src/main.cj` 的 `o.put`）同时加，见 AGENTS §4-60。
- `LINGQU_UI_PROBE=toolrun` 扩了三条断言：成功长输出 → `toolCardsOpen=0`；失败 → `=1`（自动展开）；
  再点击标题行 → `=0`（交互可用）。

### 证据（`LINGQU_UI_PROBE=toolrun` 实跑）

| tag | toolCards | toolCardsOpen | toolResultChars | 判据 |
|---|---|---|---|---|
| `tool-run-busy` | 1 | 0 | 0 | 心跳仍在（`aiToolRunning=1 / elapsed=4 / ⏳ bash · 3s`） |
| `tool-collapsed` | 2 | **0** | **1162** | 1162 字的输出，展开卡 0 张 |
| `tool-error-open` | 3 | **1** | 1185 | 失败卡片自动展开，仅 1 张 |
| `tool-click-toggle` | 3 | **0** | 1185 | 点标题行后收起 |

### 说明

- **信息没删，只是默认不占版面**：全文仍在 DOM 里的展开区，随时点开、可复制。
- 使用者真正要读的是模型的结论（assistant 气泡），工具输出只是可查的细节。

## [0.39.36] - 2026-11-02

**主题**：接续旧会话被 DeepSeek 思考模式拒（400 `reasoning_content`）→ 我们**自动开新会话**，不再把人卡死。

### 现象（用户实测）

```
❌ 服务商返回错误：服务商拒绝了本次请求（HTTP 400: The `reasoning_content` in the thinking mode
   must be passed back to the API.）
```

### 根因（cjh 侧两处口径缺失）

1. `ChatMessage` 只有 `role / content / toolCalls`，**没有 reasoning 字段**；入历史时不带
   `reasoning_content`；
2. `~/.cjh/sessions/*.json` 的落盘也只存 role/content/name/tool_call_id，**reasoning 没落库**。
   ⇒ 只要**接续旧会话**（`resume_session` 或进程重启后恢复历史），回传的历史就缺该字段，
   DeepSeek 思考模式直接 400；**全新会话不受影响**。

### 处置（本仓）

- `assets/ui/index.html`：识别到 `error` 帧里含 `reasoning_content` → **自动 `new_session`** 并提示
  「上一轮历史缺 reasoning_content，已自动开新会话；界面上的历史仍保留。根治要 cjh 把 reasoning
  一起落库并回传」。计数上限 **3 次**（`CJ.reasoningHeals`）：够覆盖「断线重连恢复的旧会话」这种
  一次性场景，又不至于在某条永远失败的路径上每轮换一个会话白烧轮次。
- 上游：`docs/上游回馈-cjh.md` 新增第 10 条（`ChatMessage` 加 reasoning / `SessionStore` 落盘 /
  `history_messages` 带上 / `features.reasoning_passthrough` 四条改法）。

### 说明

- 这条错误文案 `服务商返回错误：` 出自 **cjh 自带的网页 UI**（`static_assets.cj:1116`），
  不是灵渠窗口的文案 —— 若在浏览器里开着 `127.0.0.1:8765`，看到的报错是那一页给的。
- 灵渠窗口遇到同一 400 时，现在会自动换成新会话（历史仍显示在界面上），可以继续用。

## [0.39.35] - 2026-11-02

**主题**：查清 `ws_read_failed · Invalid utf8 byte sequence` —— **大帧被 WS 分片、cjh 不拼续帧**。

### 现象（用户实测）

> 读取 WebSocket 帧失败（多半是单帧超过实现上限）：IllegalArgumentException: Invalid utf8 byte sequence.
> code=ws_read_failed

### 排查（两步就定位了）

1. **对照实验（node 直连 cjh `/ws`）**：1KB / 4KB / 8KB / 12KB / 32KB / 100KB 的**单帧**中文全部被正常接收，
   只有 300KB 收到显式的 `frame_too_large`（符合 cjh 256KB 上限）。
   ⇒ **不是 cjh 的读侧上限**，而是"我们发出去的那帧本身不完整"。
2. **分档探针（本仓 `LINGQU_UI_PROBE=wssend`）**：一次运行内按 4KB / 16KB / 40KB / **81KB** 各发一条中文，
   结果 `wsErrCodes=ws_read_failed:1` —— **只有最大那档失败**。

### 根因

- 客户端 `w.write(TextWebFrame, text.toArray())`（cj-tauri `plugin_ws.cj:241`），
  stdx 的 WebSocket 在大负载时**自行分片**（后续帧是 `ContinuationWebFrame`）；
- cjh 的 `ws_handler.cj` 只处理 `TextWebFrame`，**续帧落到 `case _ => ()` 被丢弃**；
- cjh 拿到截断的 payload → `String.fromUtf8` 在建中间被切开的多字节字符上抛
  `Invalid utf8 byte sequence` → 回 `ws_read_failed`，这一轮就这么断了。

### 处置（本仓能做的）

- `wsSend` 加**出站帧体检 + 60KB 守卫**：
  - 出站前洗掉孤立代理项（`lone surrogate` 会编码成非法 UTF-8）；
  - `chat` 正文超过 60KB → 截断并明确提示（`ui_report.wsTruncated` 计数），**不让整条消息变成 cjh 读不了的帧**；
  - 回投 `wsSendCount / wsLastSendBytes / wsLastSendType / wsErrCodes / wsLastErrCode / wsTruncated`。
- 新增探针 `LINGQU_UI_PROBE=wssend`（分档发大帧，直接把 cjh 的错误码抓回来）。
- 上游：`docs/上游回馈-cjh.md` 新增第 9 条，给出「cjh 拼续帧」的具体改法（二十来行）与更优替代
  （任务书落文件、只发路径）。

### 实测

| 探针发送 | 结果 |
|---|---|
| 4KB / 16KB / 40KB 中文 | 无错误帧 |
| **81KB 中文** | cjh 回 `ws_read_failed`（`ui_report.wsErrCodes=ws_read_failed:1`） |
| node 直连单帧 100KB | 正常；300KB → `frame_too_large` |

**未做（如实标注）**：根治要 cjh 侧拼续帧（上游）；本仓只做了止血（60KB 守卫）+ 可定位（错误码回投）。

## [0.39.34] - 2026-11-02

**主题**：修「**回合结束了却说 AI 在绕圈**」的假停滞 —— 活动量不能只看落档和轨迹，还要看**页面收到的帧**。

### 现象（用户实测）

> 「右侧聊天窗口已经显示回合结束了，但是还能看到 dos 窗口在闪，且主页面上显示
> AI 连续 20 次轮询落档没有变化，建议点「停止」后让它总结，或直接接管。」

### 现场（本机实测）

1. **落档与轨迹都在动，也没用**：真实工程是 `C:\Users\yang\Desktop\test\m3u8dl-tauri`，
   `.lingqu/agent/trace.jsonl` 有 **299 行**、最后一条正是 `turn_done`（
   `{"rounds":41,"tools":40,"duration_ms":136060}`），和界面上的「轮次 41 · 工具 40 · 136.1s」对得上。
   也就是说 AI 一直在干活，**没有绕圈**。
2. **假停滞的机制**：`isStalled` 的快照 = 落档状态 + 轨迹行数。而 agent 有大量
   "只思考 / 只流式回话、一连 30~60 秒不调工具"的时段 —— 这段时间落档不动、轨迹也不动，
   但**页面一直在收 `delta` 帧**。20 次轮询（3s × 20 = 60s）后判「在绕圈」，纯属误判。
3. **顺带挖出一个潜伏 bug**：`AgentTraceCommand.handle()` 里**误粘了 `SignCommand` 的
   `--login`（AGC 登录）分支** —— 谁能想到"记一条轨迹"会去起回调服务登录华为账号？只要机器上
   导出过 `LINGQU_SIGN_LOGIN=1`，页面每记一条轨迹就会跑一次登录。已删除。

### 处置

- **后端**（`src/main.cj`）：
  - `t2h:autoport_status` 接受 `activity`（页面帧数）并并入快照签名
    （`sig = autoportSnapshotWith(rows, traceLines) + "|a=${activity}"`）；
  - 删掉 `AgentTraceCommand` 里误粘的 AGC 登录分支，恢复"只追加一行"的单一职责。
- **前端**（`assets/ui/index.html`）：`pollAiPort` 把 `CJ.frames`（收到的 WS 帧总数，含 delta）作为
  `activity` 一起传给后端 —— **有帧 = 有活动**，页面在动就不该报"绕圈"。

### 未做 / 说明

- DOS 窗口闪烁仍是 cjh 的 bash 会话（`docs/上游回馈-cjh.md` 第 8 条），本仓消不掉；
  实测 13:21:13 回合结束后 **30 秒采样内没有新增 `bash`/`conhost`** —— 回合内 40 次工具调用
  才会密集闪，结束后是那几秒的残留观感。
- 这次是**假停滞**，所以"点停止"并不是正确动作：正确识别之后，界面不会再在 AI 流式回话时劝人停。

## [0.39.33] - 2026-11-02

**主题**：查清「**连接已断开——回复可能不完整**」为什么会偶发，并让**断线可恢复**（不再只剩半截回复）。

### 现象（用户连续两轮实测）

> 「连接已断开——回复可能不完整），为啥总是偶发会出现这个？」

### 证据（`~/.cjh/logs/cjh.log`）

```
[12:57:22] 客户端断开，本轮继续执行（web.keep_running_on_disconnect=true）
[12:57:23] WebChannel 发送失败，连接判定为断开，后续帧跳过
           （ws sent=494 failed=1 dead=true err=SocketException: Failed to write data
            10054: An existing connection was forcibly closed by the remote host.）
[13:00:40] Agent.run 正常结束: 41 rounds, 45 tools, 628753ms
```

（11:52 那一次同款，错误码是 **10053** An established connection was aborted by the software in your host machine.）

**结论：不是"网络玄学"，也不是 cjh 崩了。** WebSocket 是**客户端这一侧**关掉的
（10053 = 本机软件中止、10054 = 对端强制关闭，两次都对得上"应用被重启/关闭"）；
cjh 按 `keep_running_on_disconnect=true` **继续把回合跑完了**（3 分钟后 41 轮 / 45 个工具正常结束），
但那根连接已判定 dead、后续帧全部跳过 → 界面只剩半截回复 + 一句"可能不完整"。

### 三类真实触发（都不是随机）

1. **应用被重启/关闭**：开发期我反复重启验证，以及早期门禁的 `taskkill /F /IM main.exe`（§4-92）——
   用户侧的会话被打断，这是"偶发"的最大来源；
2. **健康检查误判**（真 bug）：`cjhHealthy` 的 `readTimeout` 原来是 **1s**，引擎在跑长回合时
   `/api/health` 排队就超过 1s → 被判成"引擎不在" → `ensureCjhWeb()` **又拉起一只引擎**。
   实测证据：13:09:24 应用（pid 15248）在 8765 已被 14668 占着的情况下又 spawn 了 pid 24536，
   那只注定绑不上端口，成为僵尸；
3. **恢复时只插一句话**（UX 缺陷）：重连后 cjh 会推 `history_messages`，我们原来只显示
   「已恢复历史会话（N 条）」，**不渲染内容** —— 断线期间 agent 的产出在界面上等于丢了。

### 处置

- 后端（`src/cjh_host.cj`）：
  - `cjhHealthy` 读超时 1s → **3s**（判活要宽容，判死要有证据）；
  - 新增 `cjhHealthyWithRetry(port, tries)`（700ms × N 次）；`ensureCjhWeb()` 重试 6 次、
    `cjhDeployAndStart()` 重试 4 次，全都不通才认定"没有引擎"→ **不再在引擎忙时 spawn 僵尸**。
- 前端（`assets/ui/index.html`）：
  - 新增 `renderHistory()`：收到 `history_messages` 就**按历史重建对话**
    （user → 我的气泡；assistant → Markdown；tool → 一行工具结果），末尾标注
    「↻ 已按会话历史重建对话（N 条）——断线期间的产出也在这里」；
  - 断开措辞改成「**连接断开 · 正在自动重连，重连后按会话历史补回这段**」（不再是终点式的"可能不完整"）；
  - `ui_report` 新增 `historyIn` / `historyShown`；新增探针 `LINGQU_UI_PROBE=history`。

### 实测（`LINGQU_UI_PROBE=history`，喂一帧真实形状的 `history_messages`）

`ui_report` 的 `history-restored` 一行：
`historyIn=3`、`historyShown=3`、`lastFrameType=history_messages`、`errorCount=0` —— 界面真的把三重建出来了。

### 未做（如实标注）

- cjh **断线期间的事件（tool_start/tool_result）没有落库**，重连只能靠会话消息重建，
  中间的工具过程看不到；要补得在 cjh 侧把帧写进 session（属上游改动）。
- 本次两次断线都有明确的客户端侧证据（10053/10054）；**WebView2 自身无故断 WS 没有证据支持**，
  所以没有为此加"心跳 ping"之类的补丁。

## [0.39.32] - 2026-11-02

**主题**：长命令期间聊天区**不再看着像卡死** —— 工具执行挂秒表；同时把「DOS 窗口一闪」查清并记进上游回馈。

### 现象（用户实测）

> 「右侧 AI 聊天窗口信息不更新了，但屏幕上仍不时看到 dos 窗口一闪而过，像是还在执行，这种现象正常吗？」

### 根因（两件事，都不算 bug，但**界面没交代**）

1. **聊天区不动**：cjh 的回合是 `tool_start → 工具跑完 → tool_result`，工具执行期间**不发 delta**
   （ANTHROPIC/OpenAI 那一族 agent 的常规做法）。我们只在 `tool_start` 插了一张写着「执行中…」的工具卡，
   没有秒表，也没有全局指示 —— 长命令（构建/测试/hvigor 几分钟）时确实像死机。
2. **DOS 窗口一闪**：cjh 的持久 bash 会话用标准库 `launch` 起 shell，**不带 `CREATE_NO_WINDOW`**。
   本应用是 GUI 子系统、cjh 又是我们用 `launchHidden` 拉起的（没有控制台），于是 Windows 给每个
   bash 子进程**新分配**控制台 → 每次命令都闪一下 `conhost` 窗口。现场链路实测：
   `main.exe(cjh) → bash → bash → bash + conhost.exe`。

### 处置（我们这侧能做的部分）

- **工具执行秒表**：收到 `tool_start` 就开始计时，工具卡状态每秒刷新成 `执行中… 12s`，
  顶栏 AI 区同时显示 `⏳ bash · 12s`（悬停说明"工具跑完前不会有正文增量，不是卡死"）；
  `tool_result` / `done` / `error` / 中断 一律收表（`finishTurn` 兜底，避免秒表挂死）。
- `ui_report` 新增 `aiToolRunning` / `aiToolName` / `aiToolElapsed` / `aiBusyText`（§4-60 两处一起加）。
- 新增探针模式 **`LINGQU_UI_PROBE=toolrun`**：模拟一次 `tool_start` → 4 秒后回投 → 喂 `tool_result`
  → 再回投。**不用真跑长命令**就能断言心跳。
- **上游回馈**：`docs/上游回馈-cjh.md` 新增第 8 条「Windows 上每条 bash 命令都闪一个控制台窗口」，
  含现场链路、根因（`bash_session.cj:158` 的 `launch` 无 `CREATE_NO_WINDOW`）、复现步骤与三条建议
  （首选 cjutil 加 `launchHidden`；并说明 `CREATE_NEW_CONSOLE + SW_HIDE` 不管用）。

### 实测（`LINGQU_UI_PROBE=toolrun`）

| 回投时刻 | `aiToolRunning` | `aiToolName` | `aiToolElapsed` | `toolCards` | `errorCount` |
|---|---|---|---|---|---|
| `tool-run-busy`（tool_start 后 4s） | **1** | `bash` | **4s** | 1 | 0 |
| `tool-run-idle`（tool_result 后） | **0** | （空） | 0 | 1 | 0 |

**未做（如实标注）**：控制台窗口无法在本仓消除 —— 需要 cjh 侧 `CreateProcessW + CREATE_NO_WINDOW`
（FFI，属 cjh 仓的改动，要跑它自己的门禁）。已记为上游 issue，不做"假装治好"。

## [0.39.31] - 2026-11-02

**主题**：迁完之后「**用 DevEco Studio 打开哪个目录**」界面上直接给出来。

### 现象（用户提问）

> 「我要打开移植成功后的 DevEco Studio 的工程，它在哪呢？」

答案是 `<Tauri 工程>/src-tauri/gen/ohos`，但**界面上一个字都没提** —— 后端 `t2h:hap` 早就回投了
`ohosDir`，前端从来没显示（用户只能去翻文档或猜路径约定）。

### 处置

- ⑤ 构建打包 屏的 HAP 卡片下新增一行：
  **「鸿蒙工程（DevEco Studio →「打开」选这个目录）：<ohosDir> [复制路径]」**，
  数据来自 `t2h:hap` 的 `ohosDir` 回投（不是前端拼的）—— hvigor 真跑过才显示。
- `ui_report` 新增 `hapOhosDir`（§4-60 两处一起加）。
- 新增探针模式 **`LINGQU_UI_PROBE=ohos`**：切到 ⑤ 屏 → 真跑一次 `t2h:hap` → 回投 `hapOhosDir`。

### 实测（`LINGQU_UI_PROBE=ohos`，m3u8dl-tauri 真跑装配）

`ui_report` 的 `hap-done` 一行：
`hapBuilt=true / hapSigned=true / hapBytes=8257155 / hapRawfile=0 / hapArm64=true /
hapGate=pass / hapOhosDir=E:/test/rust/m3u8dl-tauri/src-tauri/gen/ohos / errorCount=0`。

## [0.39.30] - 2026-11-02

**主题**：0.39.29 上线后自己复查发现的两个"成绩冒名"问题 —— 都在同一栏（5 样本矩阵）上。

### ① 样本路径不存在时，会拿本仓同名工程的旧档顶替

`readSampleLq` 走的是 `resolveLqPath`（工程优先 → CWD 兜底）。当一个样本路径**根本不存在**
（工程改名/删掉/路径敲错）时，兜底会命中本仓 `.lingqu/<步骤>/<同名工程>.json`，
于是这一行显示的是**别人的成绩**。处置：工程目录不存在 → 直接返回"没有落档"（显示「未跑」）；
目录存在但还没 `.lingqu` 时仍允许兜底（兼容 0.38.0 之前的旧落档）。

实测（`lingqu-cli batch --samples 'E:\test\rust\does-not-exist-proj'`）：

| 样本 | 评分 | 编译 | 可用率 | 判定 |
|---|---|---|---|---|
| does-not-exist-proj | 未跑 | 未跑 | 未跑 | 未验证 |

修复前这一行会读到本仓的旧档，显示成"有成绩"。

### ② 界面「生成矩阵」默认不带样本，得先配环境变量

0.39.29 只在后端按 `LINGQU_SAMPLES_ROOT` / `LINGQU_WORKSPACES` 发现样本，界面点按钮时
什么都没带 → 用户不配环境变量就还是"没数据"。处置：界面在样本框留空时，**自动用
「当前工程 + 最近用过的工程」**（`localStorage` 里本来就记着）拼给后端；后端仍保留
四级来源（`explicit` / `workspace` / `remembered` / `cwd-lingqu`）。

顺带把来源标签改口：后端只知道"你给了 samples"，界面按实际情况标注
**「当前工程 + 最近用过的工程」**，不再一律说成"手填的样本"。

### 实测（`LINGQU_UI_PROBE=batch`，探针先设当前工程再进 ⑦）

`ui_report` 的 `batch-auto` 一行：`batchSamples=1 / batchPassed=1 / batchVerified=1 /
batchAvgRate=100 / batchSource=explicit / errorCount=0`，
`batchSumText` 结尾为 **「样本来源：当前工程 + 最近用过的工程」**。

## [0.39.29] - 2026-11-02

**主题**：把「**移植成功的项目**」真正摆到界面上 —— 而且摆的是**真数据**（原来那一栏读的是本仓的旧档）。

### 现象（用户提问）

> 「移植成功的项目在哪可以体现啊？界面上我没有看到有对应的地方」

查下来是三件事叠在一起：
1. 唯一能体现"多个工程迁移成果"的地方是 **⑦ 迁移报告 最下方的「5 样本迁移矩阵」**，藏得深、默认空、还要先点「生成矩阵」；
2. 即使点了，**数字也是错的**：矩阵读落档走的是相对当前工作目录的 `.lingqu/...`，
   读的是**本仓**的旧档，不是各样本工程自己的 `<工程>/.lingqu` —— 实测 m3u8dl-tauri 明明
   跑到可用率 100%，矩阵里写着「未跑 / 25%」；
3. 自动发现样本时只发现**工程名**、不带路径，天然无法定位到样本自己的落档。

### 处置

- **读档口径**（`src/batch_feed.cj`）：7 处 `readJsonOrNone(".lingqu/<步骤>/<工程>.json")`
  全部改成 `readSampleLq(projPath, sampleLqRel(步骤, 工程名))` → 走 `resolveLqPath`
  （先按工程解析、找不到再落回相对路径，老行为不丢）。这是 §4-75 那族的**第三处漏网**。
- **样本发现**（`src/batch_feed.cj` 新增 `splitRootList` / `sampleRootsOf` /
  `discoverSampleProjects` / `saveBatchSamplePaths` / `loadBatchSamplePaths`）：
  按 `LINGQU_SAMPLES_ROOT` → `LINGQU_WORKSPACES` → `~/lingqu-workspaces`（并集）逐根扫一层子目录，
  **挑出带 `.lingqu` 的工程目录**并带路径返回；显式填过的样本路径记进
  `.lingqu/batch/samples.txt`，下次不用重填。`t2h:batch` 回投 `sampleSource`
  （`explicit` / `workspace` / `remembered` / `cwd-lingqu`），**数据从哪来能查**。
- **界面**：进 ⑦ 迁移报告 **自动生成一次矩阵**（纯读盘、秒级），摘要行改成先给一句
  「**已迁移成功 N / M 个**（判定=达标，单样本可用率 ≥80%）」，再给 A4/A1 判定与**样本来源**；
  每行 `title` 挂出该行的工程路径 —— 「这行数字是从哪个目录读的」必须能查。

### 自动断言（§4-60 两处一起加）

`ui_report` 新增 `batchPassed` / `batchSource` / `batchSumText`；新增探针模式
**`LINGQU_UI_PROBE=batch`**：切到 ⑦ → 等自动矩阵生成 → 回投上面几个字段。

### 实测

**命令行**（`lingqu-cli batch`，`LINGQU_SAMPLES_ROOT=E:\test\rust` 自动发现）：

| 样本 | 可用率 | 8 步 | 判定 |
|---|---|---|---|
| habit-tree | 100%（5/5） | 8/8 | **达标** |
| m3u8dl-tauri | 100%（5/5） | 8/8 | **达标** |
| cc-switch-harmonyos | 未跑 | 2/8 | 未验证 |
| atomMqtt / tauri-mqtt-client-ohos | 未跑 | 0/8 | 未验证 |

修复前同一命令输出的是「m3u8dl-tauri 未跑 / 25%」——因为它读的是本仓的旧档。

**界面探针**（`LINGQU_UI_PROBE=batch`，`ui_report` 的 `batch-auto` 一行）：
`batchSamples=5`、`batchPassed=2`、`batchAvgRate=100`、`batchA4=true`、`batchA1=false`、
`batchSource=workspace`、`errorCount=0`，`batchSumText` 以「已迁移成功 2 / 5 个」开头。

### 测试

`src/tests/batch_sample_test.cj` 新增 3 例（`sampleLqRel` 7 个步骤路径 + 不带 `.lingqu/` 前缀、
`splitRootList` 四种分隔符/去空白/去重、`sampleRootsOf` 顺序与去重）。单测 338 → **341**。

## [0.39.28] - 2026-11-02

**主题**：顶栏「当前项目」胶囊**不再撒谎** —— 它原来是 HTML 里写死的一段示意文案。

### 现象（用户实测）

> 「我已经选择了其他项目，但 UI 上为何还显示 当前项目 habit-tree · v1.2.0 · 原生 TS + Rust？」

### 根因

`.tb-proj` 这段三个字段（`habit-tree` / `v1.2.0` / `原生 TS + Rust`）**全是写死的字符串**，
`setCurrentProject()` 只更新顶部输入框与左栏 8 个回显框，从来没碰过它 —— 换哪个工程它都不变。
而且它写的是"看起来像数据"的样子，用户没理由怀疑它是示意稿。

### 处置

- HTML：`<div class="tb-proj">` 拆成 `#tbProj` / `#tbProjName` / `#tbProjMeta` 三段，初始值「（未选）· 未选工程」。
- 新增 `renderTopProj()`（配 `basenameOf()` / `normPathKey()`）：**只显示真的知道的两样东西** ——
  - 工程名 = 当前工程路径末段；
  - 扫描状态 = `已扫描 R=N 项` / `未扫描` / `扫描失败`，`title` 里给完整路径。
  版本号、技术栈这类要读工程元数据的字段**没有真实来源就不写**（AGENTS §1-4：未验证不得冒充已验证），
  而不是继续沿用一段没人维护的假数据。
- 调用点：`setCurrentProject()`（换工程即刷新）、扫描成功/失败后、页面初始化。
- 路径比较统一走 `normPathKey()`（`\`↔`/`、去尾分隔符、Windows 盘符小写）：
  后端回投的是 `E:\test\rust\m3u8dl-tauri`，输入框/记住的是 `E:/test/rust/m3u8dl-tauri`，
  直接 `===` 会把同一工程判成两个，导致**扫完之后胶囊还说「未扫描（旁边的数字属于上一个工程）」**。

### 自动断言（§4-60 两处一起加）

`ui_report` 新增 4 个字段：`tbProjName` / `tbProjMeta` / `tbProjScanned` / `tbProjStale`。
`LINGQU_UI_PROBE=layout` 由 3 步扩到 4 步，第 ④ 步专门用**反斜杠写法**的 `__scan` 验证路径归一化。

### 实测（`LINGQU_UI_PROBE=layout`，窗口 1264×801）

| 探针状态 | 当前工程 | `tbProjName` | `tbProjScanned` / `Stale` | `tbProjMeta` |
|---|---|---|---|---|
| `layout-no-project` | （空） | （未选） | 0 / 0 | 未选工程 |
| `layout-with-override` | `E:/test/rust/m3u8dl-tauri` | `m3u8dl-tauri` | 0 / 0 | 未扫描 |
| `layout-normal` | `E:/test/rust/m3u8dl-tauri` | `m3u8dl-tauri` | 0 / 0 | 未扫描 |
| `layout-scan-same-project` | 同上 | `m3u8dl-tauri` | **1 / 0** | **已扫描 R=13 项** |

**换工程胶囊跟着换**（第 1→2 行）、**同一工程写法不同也认得出**（第 4 行）。

### 坑

AGENTS §4-94（写死的示意数据留在真实界面里 = 谎报）、§4-95（路径字符串比较必须先归一化）。

## [0.39.27] - 2026-11-02

**主题**：**门禁不再误杀 cjh 引擎**，且「立即拉起」拉的是**当前该用的那个** cjh —— 两处都是"器官被自己掰断"的错误。

### 现象（用户实测）

> 「连接已断开——回复可能不完整」弹出了「立即拉起」界面，点了之后聊天窗口又没任何反应。

即：一边开着应用一边跑门禁，回来聊天面板就断了；点「立即拉起」也无法恢复。

### 根因（两条，缺一不可）

1. **门禁第 ④/⑤ 闸按进程名一刀切**：`scripts/test.sh` 为了释放 `targets/desktop` 的产物执行
   `taskkill /F /IM main.exe` —— 而 **cjh 引擎的可执行文件也叫 `main.exe`**，于是把 `127.0.0.1:8765`
   上的引擎一起杀了。这与 §2.3「复用优先、不抢不杀」的托管语义直接冲突：本来是"别人的进程不碰"，
   我们自己的门禁反倒把用户正在用的引擎打断。
2. **`t2h:cjh_deploy`（界面「立即拉起」）忽略 `LINGQU_CJH`**：它直接拉起 vendored / 部署目录里的
   `cjh.exe` 旧副本（本机是 v1.6.1），而正主是 `LINGQU_CJH` 指向的开发构建（v1.6.3）。
   端口被旧副本占住后，页面连上去行为不对 —— 「拉起来了」但「页面没反应」。

### 处置

- `scripts/test.sh` 新增 `kill_own_main_exe()`：用 PowerShell 取 `Process.Path`，
  **只结束路径落在本仓根（`ROOT_WIN`）之下的** `main.exe`（即 `targets/desktop` 与 `cli/` 的产物）。
  cjh / cj-tauri 的 `main.exe` 一律不碰；一并去掉两处 `taskkill //F //IM main.exe`。
  （`to_posix_rev_win()` 把 `/e/x` 还原成 `E:\x` 供 Windows 侧比较用。）
- `src/cjh_host.cj` 的 `cjhDeployAndStart()` 增加步骤 ⓪：`LINGQU_CJH` 已设且可读 → 直接用它拉起，
  与 `cjhBinPath()` 保持**同一优先级顺序**；都没有才走 vendor / 部署副本的老路径。

### 证据（本机实测，2026-11-02）

**① 端到端：引擎在跑的时候跑完整五道闸**

| 时刻 | `Get-Process main` | `/api/health` |
|---|---|---|
| 跑门禁前 | 16548（`E:\test\harmonyos\test\cjh\target\release\bin\main.exe`） | 200 `{"status":"ok","version":"1.6.3"}` |
| 门禁第 ④/⑤ 闸打印「上一版 main.exe 仍在运行，先结束**本仓的**那些」两遍后 | 仍是 16548（**一条 `[kill]` 都没有**） | 200，仍 v1.6.3 |

`门禁全绿：build-biz:PASS test:PASS check:PASS build-app:PASS build-cli:PASS`（`EXITCODE=0`，338 例单测）。

**② 隔离性：只杀本仓的那份**

| 时刻 | `Get-Process main` | 结果 |
|---|---|---|
| 执行前 | 6804（`targets\desktop\...\main.exe`）、6628（引擎） | — |
| `kill_own_main_exe` 后 | 只剩 6628（引擎） | 产物的占用被释放、引擎照活 |

**③ 中间踩到的坑（已修，值得记住）**：第一版把 `ROOT_WIN` 的赋值写在 `to_posix_rev_win()` 定义**之前**，
调用报 `command not found` → `ROOT_WIN` 空串 → `Path.StartsWith('')` 恒真 →
**日志里出现 `[kill] 6628 ...\cjh\...\main.exe`，引擎照样被杀**。现在赋值挪到函数之后，
并给过滤依据加了空值守卫（空就拒绝结束任何进程）。

### 坑

AGENTS §4-92（门禁 `taskkill /IM main.exe` 会杀掉 cjh 引擎 + 「立即拉起」忽略 `LINGQU_CJH`）、
§4-93（bash 不预解析函数 → 路径变量空串 → 过滤条件退化成"全部匹配"）。

## [0.39.26] - 2026-11-02

**主题**：顶栏在**非最大化窗口**下不再折行/溢出，且**最大化后底部能拉伸对齐**——两个都是布局口径的
硬错误，不是审美问题。

### 现象（用户两轮反馈）

1. 窗口没最大化时，顶部那行字"折叠"了；尤其红字 `未选工程：所有步骤都跑不了` 折成好几行、
   溢出压到标题上。
2. 修完上一条后，**最大化窗口时底部空出一大截**，内容不拉伸到底。

### 根因（两条都不是 CSS 写丑了，是布局基线错了）

1. **红字自己换行**：`#projNote` 没有任何 nowrap/省略约束，而顶栏是固定 48px 的一行 —— 文案一长就折，
   折出来的第二行直接溢出到标题区。1170px 级窗口下 `有 N 个步骤用了别的工程：迁移画像、依赖树…`
   这种句子必然折行。
2. **`.app` 用 grid 固定三行**（`48px auto 1fr`），而第二行的克隆面板默认 `display:none`：
   **`display:none` 的子元素不再是 grid item**，于是 `.body` 落进第 2 行（`auto`），
   第 3 行的 `1fr` 空着没人占 —— 小窗口时 `auto` 恰好等于内容高度所以"看着没事"，
   最大化时才暴露出底部那一大截空白。
3. 顺带发现：`#projPath` 上带着**行内 `style="min-width:260px"`**，行内样式压过样式表，
   我加的 `@media(max-width:1300px){min-width:80px}` 形同虚设 → 1264 宽时工程条仍被撑爆。

### 处置

- 顶栏整条 `flex-wrap:nowrap; overflow:hidden`，`#projBar` 与 `#projPath` 都可收缩（`min-width:0`，
  输入框宽度策略**只写在样式表里**，删掉行内 style）。
- 提示文案改**短句上屏 + 全文进 `title`**：`⚠ 未选工程`、`⚠ N 步用了别的工程`（悬停看详情），
  并给 `#projNote` 加 `white-space:nowrap; text-overflow:ellipsis`（真挤才截）。
- 窄窗按优先级让位：`<1560px` 撤"当前项目"胶囊 → `<1360px` 撤 logo 副标题 → `<1300px` 三个按钮收成
  图标（📁 / ⤓ / ▾，文字进 title）+ 输入框最小宽 80 → `<1120px` 撤"当前工程"标签。
- **`.app` 改成纵向 flex**（`.titlebar`、`#clonePanel` 都是 `flex:0 0 auto`，`.body{flex:1 1 auto;min-height:0}`）：
  隐藏项自然不占位，不再依赖"隐藏后还剩几行"。

### 自动断言（两处一起加，§4-60）

`ui_report` 新增 6 个字段：`topbarH` / `titlebarOverflow` / `projNoteLines` / `projNoteClipped` /
`projNoteText` / `projBarClipped` / `layoutGapBottom` / `bodyH` / `appH`。
判据：`titlebarOverflow=false`、`projNoteLines=1`、`projBarClipped=false`、`layoutGapBottom≈0`。
新增探针模式 **`LINGQU_UI_PROBE=layout`**：把三种状态（未选工程 / 某步覆盖 / 正常）各上报一次。

### 实测（`LINGQU_UI_PROBE=layout`，两份窗口尺寸都跑过）

| 窗口 | 状态 | gapBottom | noteLines | overflow | barClipped |
|---|---|---|---|---|---|
| 1264×801（默认） | 未选工程 | 0 | 1 | false | false |
| 1264×801 | 1 步覆盖 | 0 | 1 | false | false |
| 1264×801 | 正常 | 0 | 0 | false | false |
| 1884×1061（模拟最大化） | 同上三种 | 0 | 1 / 1 / 0 | false | false |

大窗那轮是把 `cj-tauri.toml` 临时改成 1900×1100 跑的，**跑完已恢复 1280×840 并重新 sync**。

### 坑

AGENTS §4-90（grid 固定行 + 隐藏子元素 → 剩余行错位）、§4-91（行内 style 压过媒体查询）。

## [0.39.25] - 2026-11-02

**主题**：选工程从"手敲路径一条路"变成**三条路并存**（手敲 / 原生目录框 / 从 Git 克隆），
并把左栏各屏那 8 个回显框做成**一眼看出不是输入框**的样子。

### 起因（用户反馈）

> 「当前工程旁边有个输入框，左侧迁移画像/依赖扫描/改造执行/真机验证/迁移报告等界面，还都留着输入框。
> 这些 UI 交互细节让人迷惑。另外，工程路径可否弹出文件选择框来选？或者支持给个网络链接自动 clone？」

### 做了什么

1. **保留手敲**（老习惯不断）：顶部输入框照旧可以粘贴绝对路径。
2. **「选择…」改成原生目录框**：装配框架 `DialogPlugin()`，走 `dialog:pickFolder`
   （框架自带、返回选中目录绝对路径）。**没装配该插件时自动回退到 `prompt`**——
   功能不会因为漏挂插件而消失，`ui_report.pickerUsed/pickerFallback` 能分辨走的哪条。
3. **新增「克隆…」**：从 Git 地址拉下来并自动设为当前工程。
   - 新命令 `t2h:git_clone { url, dir?, depth? }`（`src/git_clone.cj`）；
   - 默认克隆到**工作区根** `LINGQU_WORKSPACES` 或 `~/lingqu-workspaces`，浅克隆 `depth=1`（填 0 = 完整历史）；
   - 三条硬规则：① 参数走 **argv 不经 shell**（URL 里 `&`/`%` 交给 shell 必被吃掉，见 §4-80）；
     ② URL 先过白名单（https/http/ssh/git/file/git@host:path），**拒绝 `-` 开头**
     （`--upload-pack=…` 这类参数注入）；③ 同名目录**不覆盖**，自动换 `-2`/`-3`；
   - 克隆完给一句"像不像 Tauri 工程"的判断（有 `src-tauri/` / 只有 `package.json` / 都没有），
     只提示不拦截（monorepo 也能继续）。
4. **8 个回显框视觉改造**：加 `echo` 样式（透明底、无边框、灰字），只有被 `✎` 显式覆盖时
   才恢复成输入框外观并可编辑。**值仍存在 input 上**，所以各屏既有的 `$('xxx').value`
   读法一行都没改——这是有意的：改 DOM 结构会牵动十几处取值逻辑，风险远大于收益。
5. `ui_report` 新增 8 个字段（两处一起加，见 §4-60）：`echoInputsTotal / echoInputsEditable /
   echoInputsEchoStyled / pickerUsed / pickerFallback / pickerLastPath / clonePanelOpen /
   cloneUrlFilled`。**`echoInputsEditable` 必须为 0**——界面上不许再"到处都要填路径"。

### 顺带撞到的门禁口径问题

挂 `DialogPlugin()` 后 `cj-tauri check` 报
`已注册命令 dialog:message 未在 capabilities 声明`：插件一次性注册 open/save/pickFolder/message
四条，而命名权限集 `dialog:files` 只覆盖前三条 → 门禁按"已注册 ⊆ 已声明"判红。
现在用 `dialog:default`（四条全覆盖）。**这是框架侧可改进点**：门禁应先展开 permissions 再比对，
否则"用最小权限集"反而过不了门禁。

### 门禁与测试

- 五道闸全绿；单测 **338 例**（+6：URL 白名单、仓库目录名抽取、冲突命名、Tauri 特征提示、
  工作区根兜底、坏地址在起进程前就被拒）。
- 改动后端 + 前端，`targets/` 已重新 sync；版本三处对齐 **0.39.25**。

## [0.39.24] - 2026-11-02

**主题**：m3u8dl-tauri 最后两格补齐（**可用率 80% → 100%**），并修掉「报告结论自己打自己」的读档缺陷。

### 实测证据（同一条链，HarmonyOS PC `3QC0124B20000048`）

| 环节 | 清理前 | 清理后 |
|---|---|---|
| `hap` 闸 | `gates=false`（rawfile 6 条死资源） | **`gates=true`、`rawfileCount=0`、`signed=true`**，包体 8,273,766 → **8,257,155** B |
| `deploy --start` | installed/started 均 true | 仍 `ok=true`，hilog 40 行无崩溃 |
| 界面 | ArkWeb 已渲染 | `uitest dumpLayout` 仍命中本应用窗口 + `Web`/`rootWebArea` + 真实文案（**证明清死资源没影响渲染**） |
| `verify` | pass 4 / fail 1 → 80% | **pass 5 / fail 0 / limit 1 / unknown 0 → 100%** |
| `report` | 结论「可用率 尚未验证」 | **「8 步完成 8/8（100%），核心功能可用率 100%，0 处人工介入」** |

### 做了什么

- **清掉 m3u8dl 的 6 个死 rawfile 条目**（`app.js` / `index.html` / `style.css` 及 hvigor 记录里的镜像条目）：
  前端已在 `.so` 里（`/assets/index.html`、`/assets/app.js`、`/assets/style.css` 在 `.so` 内可见），
  源码（`*.ets`/`*.ts`/`*.json5`）**没有任何 rawfile 引用**——先落这三条证据再动手。
  清理前把 3 个文件**按 SHA256 校验着备份**到 `<工程>/.lingqu/evidence/rawfile-bak-<时间戳>/`。

### Fixed（报告读档，属 §4-75 同族但漏在 `report_feed`）

1. **`collectReportFacts` 全程用相对 CWD 的 `.lingqu/...` 读落档** → 从仓目录跑
   `report --path <别的工程>` 时读到本仓旧档（或读不到）→ 结论写「核心功能可用率 尚未验证」，
   而**同一份报告正文的任务板摘要写着 100%**——一份文档里两个数。
   现在：读按 `resolveLqPath(projPath, …)` 解析，附录仍显示工程内相对路径。
2. **`.lingqu` 前缀被喂给 `resolveLqPath` 会拼出 `.lingqu/.lingqu/...`**（它内部自己补一层），
   `exists()` 永远 false → 所有产物附录消失、可用率读不到。新增纯函数
   `bareLqRel`（剥前缀，两种分隔符都认，且不误伤 `.lingqu-extra/`）+ 单测钉住。
3. 顺带修一处**签名结论过期**：报告里的「签名体检没过」来自自动签名之前的旧落档；
   重跑 `sign --path` 后为 `ok=true / mode=debug / candidateBundleMatch=true`，
   报告因此只剩一条**真实**的提醒（debug 态不能上架）。

### 说明

- 单测 **332 例**（+1：`testBareLqRelStripsLingquPrefix`，含"不能把 100% 说成未验证"的结论口径）。
- 5 道门禁全绿。
- **遗留（口径缺口，非缺陷）**：报告的「0 处人工介入」只数 `port` 决策采纳；
  本轮 AGC 那次**浏览器授权点击**没被计进 A3，属口径未覆盖，已记录在 `docs/进度记录.md`。

## [0.39.23] - 2026-11-02

**主题**：把「跑过但没过」从「没跑过」里分出来——`verify` 之前会把**装配跑过、闸没过**说成
「没跑过装配」，既不诚实，也把一条**可修的失败**藏成了"待办"。

### 实测证据（同一条链跑到底，HarmonyOS PC `3QC0124B20000048`）

| 环节 | 结果 |
|---|---|
| `sign --auto --newKeys` | `ok=true` |
| `hap` | `built=true signed=true hapBytes=8,273,766` |
| `deploy --start` | `installed=true started=true ok=true`，hilog 40 行无崩溃 |
| 前台确认 | `aa dump -a`：`state #FOREGROUND`、Mission #149；`uitest dumpLayout` 里有本应用窗口（focused）与 **ArkWeb 的 `Web`/`rootWebArea` 节点**，且 dump 出真实界面文本（"m3u8dl 多线程下载器 · Rust + Tauri 2 复刻"、"下载配置"、"线程数"、"限速(KB/s)"…） |
| 截图 | `E:\test\rust\m3u8dl-tauri\.lingqu\evidence\m3u8dl-autosign.jpeg`（3120×2080，用户已人眼确认界面正常） |
| `verify` | `pass=4 fail=1 limit=1 unknown=0` → **可用率 80%**；唯一失败是 `hap` 闸（rawfile 死资源） |

### Fixed

- **"跑了没过" ≠ "没跑过"**（AGENTS §4-63 的口径被自己违反了）：`build`/`hap` 两条清单项原来只有
  一个 `xxxOk` 布尔，失败一律写成「没跑过…」。新增 `hasBuild` / `hasHap` 位 +
  `hapBuilt` / `hapSigned` / `hapFirstFailure`：
  - 落档不存在 → `unknown`「没跑过装配」；
  - 跑过但 hvigor 没成功 → `fail`「装配跑过但 hvigor 没成功」；
  - 跑过、包也出来了、是**闸**没过 → `fail`，并把闸门**第一条失败**贴进 note；
  - 跑过且过 → `pass`，证据里列出 `built=true` / `signed=true`。
  交叉编译那条同样处理（`exitCode != 0` 不再显示成"没跑过交叉编译"）。
- 新增纯函数 `firstArrayItemOf`（取闸门 `failures[0]`），单测 +1 例
  （`testRanButFailedIsNotReportedAsNeverRan`，覆盖 hap/build 各自的 跑过未过 / 没跑过 四种分支），
  合计 **331 例**。

### 说明（未验证 / 遗留）

- 剩下的 `fail` 是 **m3u8dl 工程自己的 `rawfile/` 有 6 个死资源**（前端已在 `.so` 里），
  与本轮签名无关；清掉后 `hap` 项即可转 pass（可用率 → 100%）。
- 复盘文档 `docs/自动签名实战复盘.md` 的「当前状态」表已按实测更新（启动/界面从"未验证"改为已验证，
  并补上 `uitest dumpLayout` 这条**可机器断言**的界面证据口径）。
- `README.md` 从 v0.1 骨架叙述整篇重写到当前状态（0.39.23 / 五道闸 / 331 例 / 35 条 `t2h:*` /
  真机实证 / 自动签名一节 / 22 个文档链接逐个核过存在性）。

## [0.39.22] - 2026-11-02

**主题**：**路线 A（AGC 云生成自动签名）真机打通**——`m3u8dl-tauri` 从"没有签名"走到
`signed=true`、**装机成功**（`install bundle successfully`），全程零手工点 DevEco。

### 实测证据（本机，HarmonyOS PC `3QC0124B20000048`）

| 环节 | 结果 |
|---|---|
| `sign --auto --newKeys` | `ok=true`：团队 40574614 → 设备已注册 → 生成密钥对/CSR → 建证书 → debug profile → 写回 |
| `hap` | `built=true signed=true hapBytes=8,273,766 errorCount=0` |
| `deploy` | `installed=true installDetail="install bundle successfully"` |
| `deploy --start` | 装上了但**设备锁屏**拒绝自动拉起（10106102，非签名问题） |

### Fixed（一条链上逐个撞出来的六个坑）

1. **证书"名字对得上"≠"能用"**：AGC 里 `auto_debug_40574614.cer` 名字对、`expireTime` 早已过去
   （`status=2`），拿它申请 profile 被回 `The certList is invalid.`。新增 `AgcCert.expireMs/status/usable()`
   与 `findUsableCert`——按**有效期**挑，不按名字挑。
2. **证书数量上限**：`cert/add` 回 `205389872 certificate number exceeds limit.`（本账号上限 4 张，
   **过期的照样占位**）。新增 `agcCertDelete` + `staleCertsOf`（只删"过期 **且** 名字是
   `auto_debug_*`/`auto_release_*`"的，不碰用户手工建的证书）。
   端点参数位置是实测出来的：删除是 **DELETE + 请求体** `{"certIds":[...]}`（放 query 一律被回
   `Body parameter is required.`），且请求体要带 Content-Length。
3. **同名证书绑的是旧公钥**：换了新密钥对后复用云端同名证书 → profile 里的证书与 `.p12` 对不上。
   现在 `--newKeys` 会先删同名旧证书再新建，并**强制重下**本地 `.cer`（本地那份是旧证书）。
4. **写回被自己的保护挡住**：工程里已有 `signingConfigs` 时旧实现一律拒绝，
   于是整条链死在第 ⑦ 步。新增 `replaceOwnSigningConfigs`（**同一套材料才就地更新**，
   换材料仍拒绝）+ 抽出共用的 `locateSigningArray`（按深度配对，跳过 json5 字符串）。
5. **`.p12` 的口令没人知道**：材料来自别处 / `material/` 重建过时，旧密文解不开
   （`GCM tag mismatch`）→ hvigor 报 `00303242 Signature material verification failed, as:
   Unsupported state or unable to authenticate data`。新增 `--newKeys`（旧材料**改名留底**后重生成），
   自己掌口令 → 自己加密 → hvigor 解得开。
   `DEVECO_SDK_HOME` 没设时按 `DEVECO_HOME/sdk` 推导出 `hap-sign-tool.jar` 位置。
6. **`9568332 install sign info inconsistent`**：同包名已装过另一套签名的版本（重签后必然撞上）。
   `deploy` 现在自动 `bm uninstall` 后重试一次并记进证据；`10106102`（锁屏）的结论文案也改对了
   （原来一律怪"ability 名写错"）。

### Added

- `sign --auto --newKeys`（`LINGQU_SIGN_NEWKEYS=1`）：丢弃并重生成材料。
- `t2h:sign --tool-check`（0.39.20 起）：自检 java / `hap-sign-tool.jar` / hdc，并真生成一对密钥验通路。
- 单测 +5 例（`usable()` 与过期挑选手法、`staleCertsOf` 只挑自己的、`replaceOwnSigningConfigs`
  就地更新/拒绝换材料/空数组分流），合计 **330 例**。

### 说明（未验证 / 遗留）

- **应用启动与界面未验证**：设备锁屏（开发者模式禁止自动解锁），`aa start` 报 10106102。
  装机已成功，启动与 `verify` 需解锁后重跑。
- `hap` 闸仍报 `rawfile/` 有 6 个死资源（前端已编进 `.so`）——与本轮签名无关，属 m3u8dl 工程的清资源待办。
- **复盘文档**：`docs/自动签名实战复盘.md`（全链路、六个坎的现象→根因→处置、可复跑手册、
  协议细节表、复用清单、边界）；`skills/t2h-ohos-port/references/signing.md` 同步更正
  "口令密文只能搬"的旧结论并补上路径 C 的用法。

## [0.39.21] - 2026-11-02

**主题**：AGC 云侧四处"字段名/编码"错误——它们让设备与证书这两步**看着成功其实没用**。

### Fixed

- **设备列表解析**：AGC 真正用的字段是 `list`（`devicesInfo`/`devices`/`deviceList`/`deviceInfos`
  全不存在）→ "设备已注册"永远判成没注册，随后 `device/add` 报 `205389858 UDID is repeat`。
- `205389858`（UDID 重复）**按已注册处理**：语义上就是"已经好了"，不该当失败。
- **profile 的 `deviceList` 要云端设备 id**：传 UDID（64 位）被拒
  （`deviceList[0].<list element>: size must be between 0 and 32`）。
- **证书下载 403**：AGC 给的是 SigV4 签名链，通用 HTTP 客户端会重新编码 query 使签名失效；
  改为**原样用系统 curl**取字节，再校验 sha256 落盘。

## [0.39.20] - 2026-11-02

**主题**：`sign --tool-check` —— 先把"别人的安装目录里那三样东西"体检清楚。

### Added

- `t2h:sign --tool-check`（`LINGQU_SIGN_TOOLCHECK=1`）：逐项报告 java / `hap-sign-tool.jar` / hdc
  是否存在、在哪、版本，并**真生成一对密钥再删**（证明它不只是"文件在"）。

## [0.39.19] - 2026-11-02

**主题**：把「回调判定」抽成纯函数并**放宽到只认 quit**——连续三次登录失败都出在"一次异常回调
弄死整次会话"，以及"_回调页被用户手动打开_"。

### Fixed（三个实测出来的坑）

1. **缺 `tempToken`/`siteId` 的回调会终止会话**：浏览器/华为页面的预检跳转就是这种形态——
   实测进程当场退出、端口不再监听，用户再登录必然失败。现在**只有显式 `quit` 才终止**。
2. **`code` 不一致硬拒绝**：华为回调里自带它自己的 `code`，与我们的防伪 code 天然不同 →
   正常登录被我们判成 `Bad code`。现在 `code` **只核对不拒绝**（安全边界改为：
   只绑 `127.0.0.1` + 一次性服务 + Host 白名单 + tempToken 仍要过华为校验）。
3. **`/callback` 被用户手动打开**（连续两次）：回调页现在**直接给出可点的登录页链接**，
   并写清"这是内部地址，别手动开"。

### Added

- `judgeCallback(code, tempToken, siteId, quit, expectCode)` **纯函数**（+`CallbackVerdict`）：
  三条规则一处实现，handler 只执行动作；4 例单测覆盖（正常 / code 不一致仍放行 /
  缺参数与非大陆站点只忽略 / 只有 quit 终止），合计 **325 例**。
- 回调证据落文件：`~/.lingqu/agc/login-callback.log`（记 code 长度、siteId、code 是否匹配——
  **不记 tempToken 明文**），下次出问题不用再靠猜。

### 说明（仍未验证）

真实授权仍未完成（本轮结束时重新起了一次登录并给出链接）。因此 AGC 侧（团队/设备/证书/profile）
与 `m3u8dl-tauri` 的 `signed=true` 都还没发生。
## [0.39.18] - 2026-11-02

**主题**：自动签名的**编排层**落地——登录之后的一整条链现在是一条命令。
（真实授权仍未完成，所以 `signed=true` 还没拿到；代码已就位，token 一到即可连跑。）

### Added

- `src/compiler/sign_apply.cj`：
  - `autoSign(inp, token)`：① 令牌 → ② 团队 → ③ 设备（已注册跳过 / 否则注册）→
    ④ 材料命名 + 本地没有 p12 就 `hap-sign-tool` 生成密钥与 CSR → ⑤ 证书（按 `auto_debug_<teamId>.cer`
    精确复用，没有就用 CSR 新建并下载 .cer）→ ⑥ 按**新包名**申请 debug profile（带 deviceList）→
    下载 `.p7b` → ⑦ 用 `material/` 加密口令 → `applySigningConfig` 写回（先 `.bak`）
  - `AutoSignOutcome`：**逐步日志**（一行一步）+ 各文件路径 + `passwordLen`（只回长度，绝不回口令）
  - 复用旧 p12 时沿用工程里现有的口令密文；没有现成密文就要求删掉 p12 重新生成（不猜口令）
  - 每一步失败都带"是哪一步"，不出"跑完了但不知道哪步没做"的结果
- `t2h:sign --auto --path <工程>`（或 `LINGQU_SIGN_AUTO=1`）：组装 `bundleName`（AppScope）、
  UDID / deviceType（hdc）、令牌（`~/.lingqu/agc`），跑完整编排并按 JSON 回投。
- 2 例新单测（无令牌必须**秒级**报"先去登录"且一步不走；`AutoSignOutcome` 落档结构里不得出现口令），
  合计 **321 例**。

### 说明（仍未验证）

真实账号授权尚未完成（等一次浏览器点击）。因此 `autoSign` 的网络部分（团队/设备/证书/profile）
在本机**还没有真跑过**；`m3u8dl-tauri` 的 `signed=true` 尚未发生。
已就位并可复跑的离线证据仍是 0.39.16 的那条：**hvigor 能解开我们造的 AesGcmKit 口令密文**。
## [0.39.17] - 2026-11-02

**主题**：修掉「登录链接被 shell 拆开」这个真 bug——它就是用户"网页登录失败"的直接原因。

### 现象与根因

用户点登录链接后网页侧失败。查日志发现浏览器**只拿到了截断的地址**：

    openUrlInBrowser → `cmd /c start "" <url>`
    'appid' is not recognized as an internal or external command,
    'code' is not recognized as an internal or external command,

登录 URL 是 `…/apply?port=21570&appid=1009&code=<32位hex>`——`cmd` 把 **`&` 当命令分隔符**，
于是 `start` 只打开 `…?port=21570`，后面几段被当作命令执行。用户看到的是一个残缺链接的失败页。

### Fixed

- `openUrlInBrowser` 在 Windows 上改用 **`rundll32 url.dll,FileProtocolHandler <url>`**：
  不经过 cmd 的命令解析，URL 原样交给系统；其它平台仍用 `xdg-open` / `open`（按 argv 收参，无此问题）。
- 新增断言把这件事钉住（`testLoginUrlCarriesAmpersands`）：登录 URL 必须同时含
  `?port=<n>&`、`&appid=1009&`、`&code=<hex>` 三段——将来谁改拼装逻辑，少一段就红。

### 说明（仍未验证）

真实账号授权仍未完成（本轮结束时重新起了一次登录，链接已给用户）。
`m3u8dl-tauri` 的 `signed=true` 尚未发生。
## [0.39.16] - 2026-11-02

**主题**：**证明我们的 AesGcmKit 口令密文 hvigor 真能解开**——这是"全新生成签名材料"路上最后一个
未知数。附 `hap-sign-tool` 的定位与调用（生成密钥对与 CSR）。

### 决定性实验（本机实测，可复跑）

    # ① 用我们自己的实现重加密 habit-tree 现有口令密文（新 IV，同一口令）
    lingqu-cli sign --reencrypt --buildProfile E:\test\rust\habit-tree\src-tauri\gen\ohos\build-profile.json5
      → ok=true  storePwdLen=10  keyPwdLen=10  newStorePasswordPrefix=0000001af150…
      原密文前缀 0000001ABCEAD81D… → 新密文前缀 0000001af15004076fb1…（确实变了）

    # ② 让 hvigor 去解「我们造的密文」
    lingqu-cli hap --path E:\test\rust\habit-tree
      → hvigor Finished :entry:default@SignHap… after 2s 578ms
      → hvigor BUILD SUCCESSFUL in 14s 175ms
      → built=true signed=true hapBytes=7,249,832 gates.ok=true
    # 实验后 habit-tree 的 build-profile.json5 已还原（.bak 删除）

结论：**命令里那串口令密文可以完全由我们自己生成**，hvigor/DevEco 解得开——不必再"抄别人的密文"。

### Added

- `src/compiler/sign_tool.cj`（`hap-sign-tool.jar` 的定位与调用）：
  - `javaCandidates`（`JAVA_HOME` → DevEco JBR → PATH）/ `hapSignToolCandidates`（SDK 三档布局 +
    数字版本目录降序）/ `firstExisting`
  - `randomPasswordAlnum`（8 随机字节 → base64url → 去 `-_=`，纯字母数字、7~10 位，与 flutter 同规则）
  - `keypairArgs` / `csrArgs`（**`generate-keypair` 没有 `-outFile`，`generate-csr` 才有**）
  - `maskSecrets`：日志里把 `-keystorePwd` / `-keyPwd` 后面的值替换成 `******`
  - `genKeypair` / `genCsr` / `runSignTool`（失败带 exit 码与日志尾部）
- `t2h:sign --reencrypt`（或 `LINGQU_SIGN_REENCRYPT=1`）：读 `material/` → 解出原口令 → 用新 IV
  重新加密 → 写回（先留 `.bak`）；只回**口令长度**与前缀，绝不回明文。

### 说明（仍未验证）

真实账号授权未完成（等一次浏览器点击）。因此"用 AGC 侧给新包名签发的 profile + 我们自己生成的
密钥/口令"这一整条，还差最后一段；`m3u8dl-tauri` 的 `signed=true` 尚未发生。
## [0.39.15] - 2026-11-02

**主题**：AGC 云侧动作（设备 / 证书 / profile / 安全下载）落地——登录之后的整条链已经写完，
只等一次真实授权即可连跑。

### Added

- `src/compiler/sign_cloud.cj`
  - **纯函数**（全部单测）：`parseDeviceList` / `deviceRegistered`（UDID 大小写不敏感）/
    `parseCertList` / `findCertByName`（命名是确定性的，所以"要不要新建"= 一次名字精确匹配）/
    `deviceTypeOf`（`liteWearable` 必须先于 `wearable` 判，否则子串会吃掉前者）/
    `buildDeviceAddBody` / `buildCertAddBody` / `buildProvisionBody`（`deviceList` 只在 debug 带、
    空 ACL 不带该键）/ `parseProvisionAdd` / **`isSafeDownloadUrl`**（SSRF 护栏）/
    `upperAscii` `lowerAscii` `digitsOnlyValue`
  - **动作层**：`agcDeviceList`（分页 start=1 起、每页 100）/ `agcEnsureDevice`（已注册就跳过，
    名字重复自动换 nonce 重试一次）/ `agcCertList` / `agcCertAdd` /
    `agcDownloadObject`（`objects/url/reapply` 换临时链 → **先校验 sha256 再落盘**）/
    `agcProvisionDebug`（申请 → 下载 `.p7b` → **下载完立即删云端 profile**，与 flutter 一致）
- 8 例新单测（`src/tests/sign_cloud_test.cj`），合计 **318 例**。

### Fixed（单测当场抓到的两个真缺陷）

1. **SSRF 护栏漏判 IPv6 字面量**：按第一个 `:` 切 host 时，`https://[::1]/a` 会被切成 `[`，
   于是"本机回环"没被拦住。改成：带方括号的 IPv6 整段取到 `]`；其余含 `:` 的 host 一律拒（不猜）。
2. **一次错 code 的回调会废掉整次登录**（`sign_login.cj`）：Host 不合规 / code 不匹配以前都会
   `done.store(true)` 终止会话——实测代价是：上一轮贴给用户的登录链接在会话重启后 code 变了，
   用户仍点旧链接 → 整次登录被判失败。现在这两种情况**只回 400 并继续等**（只有 `quit` 才终止）。

### 说明（仍未验证）

真实账号授权**还没完成**：本轮结束时重新起了一次登录（新的 code），等人点击。
因此 jwtToken 校验之后的团队/设备/证书/profile 申请、以及 m3u8dl-tauri 的 `signed=true` 尚未发生。
另：`hap-sign-tool` 的 keypair/CSR 生成（全新材料的路径）也还没接。
## [0.39.14] - 2026-11-02

**主题**：路线 A 的**登录环节**落地——OAuth loopback（本机回调 + 防伪 code + Host 白名单）→
tempToken→JWT → JWT 校验 → 令牌加密落盘 → 团队列表。第一次需要人在浏览器里点一次授权。

### 自测证据（本机实测，无需账号即可验证链路）

    # 起服务后 /callback 的三条路径
    错误 code（伪造回调）  → 400 "Bad code"（客户端报「回调 code 与本机生成的不一致」，并终止）
    未知路径 /nope          → 404
    正确 code（假 tempToken）→ 302 跳 loginSuccess；随后客户端去打
                              https://cn.devecostudio.huawei.com/authrouter/auth/api/temptoken/check
                              返回 200 但响应不是 JWT → 我们按"不是 JWT"如实拦住：
                              「换 JWT 失败：HTTP 200，响应不是 JWT」
    端口获取：`port(0)` 由系统分配，必须 `afterBind` + SyncCounter 等绑定完成再读，
              一开始就读会拿到 0（实测踩到，已按此改）

### Added

- `src/compiler/sign_login.cj`：
  - `agcLogin(timeoutSec, openBrowser)`：阻塞式登录（起服务 → 打印/打开登录页 → 等回调 → 换 JWT →
    校验 → 拉团队），返回 `AgcLoginOutcome`（含 `port` 与逐步 error，排障一眼看出卡在哪）
  - `LoginCallbackHandler`：只认 `/callback`；Host 白名单 `127.0.0.1:<port>` / `localhost:<port>`；
    `code` 必须与本机一致；`siteId != "1"` 拒绝（只支持大陆站点）；`quit` 走失败页
  - `randomHex32` / `loginPageHtml` / `openUrlInBrowser`（Windows `cmd /c start`）
  - 令牌加密落盘：`~/.lingqu/agc/{keys/kek.bin, token.enc}`，AES-128-GCM（复用 0.39.13 的实现），
    信封 `{version, algorithm, iv, ciphertext, tag}` 全 hex；`loadAgcToken` 解不开就返回 None（要求重登）
  - `agcTeamList`：默认取第一个团队（与 flutter 的 `teams.first.id` 一致）
- `t2h:sign` 新增 `--login`（或 `LINGQU_SIGN_LOGIN=1`）：只做登录并落盘令牌，不走体检；
  探针 `LINGQU_SIGN_LOGIN_CODE`（自测时固定 32 位 code）、`--noBrowser`、`--timeout`。
- CLI 增加 `lingqu-cli sign --login` 的用法说明与调用路径。
- 4 例新单测（code 形态与随机性、成功/失败页文案、用户摘要不含 token），合计 **311 例**。

### 说明（仍未验证）

真实账号的登录**尚未完成**（本轮起好了服务并给出登录链接，等人授权）。
因此 jwtToken 校验、团队/设备/证书/profile 申请、以及 m3u8dl-tauri 的 `signed=true` 都还没发生。
## [0.39.13] - 2026-11-02

**主题**：把「口令密文」这一环打通——**纯仓颉 AES-128-GCM + hvigor AesGcmKit 兼容**。
这是路线 A 里最容易"静默失败"的一步：算错一位，hvigor 只会说"签名失败"，不会说 GCM 错了。

### 决定性验证（本机实测，两边独立实现互证）

    # 用本机现成的 ~/.ohos/config/material 解 habit-tree 已有口令密文
    仓颉实现（src/compiler/aes_gcm_kit.cj）：loadWorkKey + decryptPasswordHex → 通过（GCM 认证过了）
    Node 实现（DevEco 自带 node，走 OpenSSL）独立复算：
      workKey     = b730dc2388f8e70c645ac48fea7f22e4
      storePassword → "LtjnTDt7h8"（10 位字母数字，与 flutter 随机口令形态一致）
      keyPassword   → "LtjnTDt7h8"
    → 两边逐字节一致 ⇒ 我们**能自己生产 hvigor 解得开的口令密文**，不必再"抄别人的密文"

### Added

- `src/compiler/aes_gcm.cj`：**纯仓颉 AES-128-GCM**（296 行）。
  为什么自己写：仓颉 std / stdx 1.0.5.1 **没有 AES**——`stdx.crypto.crypto` 只给 `SM4`，
  标准库 `std.crypto.cipher` 只有 `BlockCipher` 接口；且本机实测 **SM4-GCM 直接抛**
  `CryptoException: Encrypt failed due to create tag error`（CBC/ECB/CTR 才可用）。
  实现用 NIST SP 800-38D 的 TC1/TC2/TC4 向量核对（期望值又用本机 Node/OpenSSL 独立复算），
  另测非 96bit nonce、多块、tag 篡改拒绝、换 key 拒绝。
- `src/compiler/aes_gcm_kit.cj`：AesGcmKit 兼容层
  - `hmacSha256` / `pbkdf2HmacSha256`（stdx 没有 PBKDF2，自写；4 组公开向量核对）
  - `lossyUtf8Bytes`：非法 UTF-8 序列 → U+FFFD（Node `toString('utf8')` 同语义；
    不做这一步 rootKey 必然不对）
  - `loadWorkKey(materialDir)`：读 `material/{ac,ce,fd/0..2}`（每目录恰好 1 个文件）→
    `PBKDF2(10000,16)` → AES-GCM 解出 workKey；错误逐条带原因
  - `encryptPasswordHex` / `decryptPasswordHex`：载荷 `[len(4BE)|IV(12)|ct|tag(16)]` → hex
  - `randomBytes`（`SecureRandom`：**注意 `nextBytes(buf)` 是填缓冲区，不是给长度返回数组**）
- 8 例新单测（AES 4 + kit 4），合计 **310 例**。

### 说明（仍未验证）

路线 A 的**联网部分**（OAuth 登录、团队/设备、证书、profile）仍未写；本轮只把"材料生产"里
最危险的密码学环节做穿。`m3u8dl-tauri` 的 `signed=true` 尚未发生。
## [0.39.12] - 2026-11-02

**主题**：自动签名「路线 A」（AGC 云生成）开工，第一批落地的是**纯函数地层**：
材料命名规则、口令密文的载荷布局、hex 编解码。都可在本机自证，不联网、不碰云端资产。

### 本轮确证的三个事实

1. **材料命名规则与本机磁盘逐字一致**（这是"复用 DevEco 已有材料"的地基）：
   `~/.ohos/config/{safeProduct}_{工程目录名}_{base64url(sha256(前向斜杠工程路径)) 去 padding}=.{p12|csr|cer|p7b}`
   - 实测：`sha256("E:/test/rust/habit-tree/src-tauri/gen/ohos")` → `m7Gxh5QRtg0h6LnDjtArCp3iYObE9iWm8BEssdAfmHM`，
     与磁盘上的 `default_ohos_m7Gxh5QR….p7b` 完全一致；换成反斜杠路径算出 `EuNnZ1gj…`（反例）→ 印证"hash 必须用前向斜杠"。
   - 文件名里 hash 与后缀之间那个 **`=` 是字面分隔符**，不是 base64 填充。
2. **AesGcmKit 载荷布局已钉住**：`[len(4B 大端)=|ct|+16 | IV(12) | ct | tag(16)]` → 小写 hex；
   `material/{ac,ce,fd/0..2}` 各恰好 1 个文件；固定分量 `31 f3 09 73 d6 af 5b b8 d3 be b1 58 65 83 c0 77`；
   `rootKey = PBKDF2-HMAC-SHA256(utf8(有损解码(XOR(fd0,fd1,fd2,固定分量))), salt, 10000, 16)`。
3. **仓颉侧缺 AES-GCM 原语**（重要，影响方案）：
   - `stdx.crypto.crypto` 只暴露 `OperationMode` / `PaddingMode` / `SecureRandom` / **SM4**（`GCM` 只是 SM4 的模式之一）；
   - 标准库 `std.crypto.cipher` 只有 `BlockCipher` **接口**（`encrypt`/`decrypt`），没有 AES 实现；
   - `stdx.crypto.digest` 的 `HMAC` 可用（`HMAC(key) { => SHA256() }` 编译通过），故 PBKDF2 可自写；
   - `stdx.net.http` 有 `ServerBuilder` / `HttpServer` / `TcpServer` → OAuth loopback 回调服务可行。
   → 两条可选路：**(a)** 自实现 AES-128 + GCM（约 300 行，可用 .NET `AesGcm` 生成权威测试向量对拍）；
   **(b)** 复用本机已有一套 p12/cer（连口令密文一起搬），只向 AGC 申请**新包名的 profile** —— 这样完全不碰 AES，更快通到 `signed=true`。

### Added

- `src/compiler/sign.cj`「材料生产」一节（纯函数，全部单测覆盖）：
  - `b64UrlNoPad()`（自带 base64url 编码；仓库原本只有解码）
  - `forwardSlashPath()` / `projectPathHash()` / `sanitizeSignName()` /
    `signingFileBaseName()` / `signingMaterialFileName()`
  - `toHexLower()` / `fromHexLower()` / `packGcmPayload()` / `unpackGcmPayload()`
  - 常量：`AES_GCM_IV_LEN` / `AES_GCM_TAG_LEN` / `AES_GCM_KEY_LEN` / `PBKDF2_ITERATIONS` / `SIGN_NAME_MAX_LEN`
- 6 例新单测（命名 hash 与磁盘一致 / 反斜杠反例 / 文件名那个 `=` / sanitize 边界 / hex 往返 / 载荷布局与异常长度），
  合计 **296 例**。
- 文件头注释同步纠正：口令不再只能"从别处搬"，`material/` 本机就有（见路线 A）。


### 追加（同一轮）：AGC 协议层与 HTTP 客户端骨架

- 新增 `src/compiler/sign_agc.cj`（路线 A 的协议层）：
  - **纯函数**：`oauthLoginUrl` / `tempTokenCheckUrl` / `jwtCheckUrl` / `agcUrl` / `loginRedirectUrl` /
    `isChinaSite` / `isJwtShaped` / `parseQueryParams` / `urlEncode` / `urlDecode` /
    `certNameFor`（`auto_debug_<teamId>.cer`）/ `provisionNameOf`（`sha256("p_b_b")[0:16]`）/
    `agcSucceeded`（判 `ret.code==0`）/ `agcErrorCode` / `agcErrorMsg`（`msg` 两种形态都认）
  - **动作层**：`agcHttp(method, url, headers, body, timeout)`、`ohosConfigDir` / `agcStateDir` / `agcTempDir`
- 6 例新单测（`src/tests/sign_agc_test.cj`），合计 **302 例**。`provisionNameOf` 的期望值来自
  **独立的 SHA256 计算**（PowerShell），不靠自证。

**从实测里学到的三条硬约束**（已写进代码注释，避免下次再踩）：

1. **HTTPS 必须显式 `tlsConfig(TlsClientConfig())`**，否则 `HttpException: TLS must be configured…`；
2. **必须 `.noProxy()`**——客户端默认读系统 `http_proxy/https_proxy`，否则连本机回环都可能被送去代理；
3. 响应体是 `InputStream`，用 `StringReader(resp.body).readToEnd()` 取字符串并 `close()`；且
   **lambda 不能捕获 `var` 局部变量**（loopback 回调要把结果带回主线程，得用类实例字段）。
### 说明（未验证的部分）

路线 A 的**联网部分**（OAuth 登录、团队、设备注册、证书、profile 申请与下载）本轮**一行未写**，
因此"自动签名打通 m3u8dl-tauri"尚未发生；本轮只有离线地层与事实核对。
`docs/鸿蒙自动签名机制.md` 已有的端点/流程与本轮实现一致，无需改口径。
## [0.39.11] - 2026-11-01

**主题**：把「签名不对」从**分钟级的白等**变成**秒级的说清**，并修掉一个让落档整块消失的建目录缺陷。
背景是上一轮把根因钉在「profile 按包名签发」之后，剩下的成本问题：`t2h:hap` 仍要先跑 `hvigor assembleHap`，
而包名不匹配这件事在跑之前就能判。

### 实测证据（Windows x64 · 鸿蒙 PC 在线）

    # ① 预检拦下（把 m3u8dl-tauri 的 signingConfigs 指向本机现存但**别的包名**的材料）
    lingqu-cli hap --path E:\test\rust\m3u8dl-tauri
      elapsed = 1s（此前要跑完 hvigor：约 3 分钟才拿到同一条 00303074）
      signPreflightBlock  = true
      signPreflightReason = 工程包名 `com.atomgit.m3u8dl_tauri` 与已配签名材料的包名
                            `com.yang.testcj` 不一致（hvigor 必然报 00303074，一个产物都不会有）…
      gates.failures      = 「HAP 闸（签名预检，已拦下）：…」       ← 落档 .lingqu/hap/<工程>.json
      （实验后已把样本 build-profile.json5 还原，storeFile 仍指向原路径）

    # ② 正常路径不受影响（habit-tree 包名匹配）
    lingqu-cli hap --path E:\test\rust\habit-tree
      signPreflightBlock=false · built=true · signed=true · gates.ok=true

### Fixed

- **落档整块丢失（5 个样本里 3 个中招）**：`ensureDirOf` 逐段 `Directory.create(Path(part))` 在
  「工程的 `.lingqu` 还不存在」时抛 `Failed to create directory …\.lingqu\sign, parent …\.lingqu does not exist`，
  于是 `t2h:sign` 的 `.lingqu/sign/<工程>.json` 一个都写不出来（cc-switch-harmonyos / atomMqtt /
  tauri-mqtt-client-ohos 实测）。改为优先 `Directory.create(Path(dir), recursive: true)`（与
  `saveTaskBoard` 同一种写法），失败再退回逐段创建——修后三份落档分别 4445 / 3736 / 4197 字节。
  这是 D-013「静默失败零容忍」的又一次落实：**证据写不出来必须能被发现**。
- **"读不到包名"被写成"包名不一致"**：`judgeSignForWriteback` 在工程 `AppScope/app.json5` 读不到
  `bundleName` 时，原先照样拼出"工程包名 （…读不到…） 与候选材料包名不一致"——读着像真结论，
  其实是没有事实支撑。现在只提示"无法判断候选材料是否匹配"，不动原判定的下一步。

### Added

- `src/compiler/sign.cj`：`SignPreflight` + `judgeSignPreflight()`（纯函数）。三条规则**只在必然失败时拦**：
  没配 signingConfigs 不拦（能产 unsigned HAP）· 材料文件缺失只提示（unsigned 仍可能产出，
  提示 00303107）· 包名不一致**拦**（必然 00303074，产物为零）· 读不到工程包名不拦（交回 hvigor）。
- `src/main.cj`：`t2h:hap` 在跑 hvigor 之前做预检，结论进 `phaseLog`、落档 `signPreflight{}` 与
  HAP 闸 failures；返回值加 `signPreflightBlock / signPreflightReason / projectBundle / profileBundle`。
  `profileBundleOf(p7bPath)` 读 profile 的 `bundle-name`（与 `profileTypeOf` / `profileAllows` 同族）。
- 4 例新单测（`judgeSignPreflight` 四态），总 **290 例**。

### 5 样本签名就绪度（同一台机器 · 已连设备，`t2h:sign` 实跑）

| 样本 | 工程 bundleName | 本机候选材料包名 | 可签吗 |
|---|---|---|---|
| habit-tree | `com.jiujiang.habit_tree` | 同（`m7Gx…`） | ✅ `ok=true`，已装机 |
| m3u8dl-tauri | `com.atomgit.m3u8dl_tauri` | `com.yang.testcj` | ❌ 需 DevEco 对本工程自动签名 |
| cc-switch-harmonyos | `com.ccswitch.desktop` | `com.yang.testcj` | ❌ 同上 |
| tauri-mqtt-client-ohos | `com.atomgit.mqtt_client_ohos` | `com.yang.testcj` | ❌ 同上 |
| atomMqtt | （无 `gen/ohos/AppScope`） | `com.yang.testcj` | ❌ 先补鸿蒙脚手架 |

**口径**：这四条"❌"不是工具缺陷，是**每个新包名都需要一次 DevEco 登录自动签名**（ADR D-017，
计入 A3 人工介入）。本轮还确认了没有可脚本化的替代入口：`devecocli`（1.0.0）只有 `build/run/device`，
`DevEcoStudio6.1` 的配置目录里没有任何登录态文件，`hap-sign-tool.jar` 只能签、不能签发 profile。

## [0.39.10] - 2026-11-01

**主题**：**habit-tree 首次拿到真机的完整链路与 100% 可用率**，同时修掉让可用率"假低分"的两个
取数缺陷。签名这条也终于在**包名匹配**的样本上跑通（`signed=true` → 装 → 启）。

### 真机实跑证据（Windows x64 · 鸿蒙 PC `3QC0124B20000048` · habit-tree @ `ohos` 分支）

    lingqu-cli sign   --path E:\test\rust\habit-tree
      ok=true  udid=B8861DAE…6385  hasConfig=true filesExist=true allowsDevice=true profileType=debug
      projectBundle=com.jiujiang.habit_tree  candidateBundle=com.jiujiang.habit_tree  candidateBundleMatch=true
    lingqu-cli hap    --path E:\test\rust\habit-tree
      built=true  signed=true  hapBytes=7,249,833  gates.passed=true  errorCount=0
      hvigor：BUILD SUCCESSFUL（SignHap UP-TO-DATE）
    lingqu-cli deploy --path E:\test\rust\habit-tree
      installed=true（install bundle successfully） started=true（ability started）
      hilogHealthy=true（40 行，无崩溃）  serial=3QC0124B20000048
    lingqu-cli verify --path E:\test\rust\habit-tree
      清单 6 项：通过 5 / 平台限制 1 / 未验证 0
      → **核心功能可用率 100%**（分母剔除平台限制），截图 .lingqu/evidence/habit-tree-verify.jpeg

### Fixed

- **verify 取数读到别处/过期的旧档（假低分主因）**：`collectVerifyInput` / `deploySerialOf` /
  `deployBundleOf` / `collectEvidence` 用的是**相对 CWD** 的 `.lingqu/...`（0.38.0 之前的落档位置）。
  实测后果：`t2h:deploy` 刚报 `start.ok=true`，紧接着 `t2h:verify` 却按应用目录里 0.39.7 份旧档
  （`start.ok=false`，锁屏那轮）判定"装上了但没起来"。现在读侧一律 `resolveLqPath(projPath, …)`
  （工程优先、CWD 兜底），截图证据也落到**工程**的 `.lingqu/evidence/`。
- **`assetDiff` 三个字段是数组，被当整数取**（AGENTS §4-57 的老坑复发）：`matched / staleInSo /
  missingInSo` 用 `intFieldOf` 永远得 0 → "前端指纹一致"被误判成"不一致（会白屏）"，
  连带可用率掉一格。改为 `arraySizeFieldOf`，并把解析收成纯函数 `buildAssetFlagsOf` /
  `deployFlagsOf`（`src/verify_feed.cj`），单测钉住字段形态。

### Added

- `src/verify_feed.cj`：`buildAssetFlagsOf(root)` / `deployFlagsOf(root)` 纯函数（两条判定单点定义）。
- `src/tests/verify_test.cj`：`testBuildAssetFlagsTreatsAssetDiffAsArrays`（数组形态 / stale / missing /
  编译失败四态）与 `testDeployFlagsReadInstallAndStartSeparately`（装≠起）。

### 说明（签名这条的口径，别读错）

`t2h:sign` 的包名门槛（0.39.9）在 habit-tree 上按预期放行：材料 bundle-name 与工程 bundleName 一致
→ `candidateBundleMatch=true` → `signed=true`。**m3u8dl-tauri 仍是不可签**（本机没有
`com.atomgit.m3u8dl_tauri` 的 profile），需 DevEco 登录自动签名一次——那是外部人工步骤，
工具已给出可执行说明（见 ADR D-017），不是本仓能脚本化的（`devecocli` 只有 build/run，
`~/.ohos/config` 里没有登录态）。

## [0.39.9] - 2026-11-01

**主题**：**签名链路的真根因是「包名」，不是「材料路径」**。0.39.7 把 `hap/sign` 的 `ok=false`
记成「`signingConfigs` 指向不存在的材料，改指向现存那套即可」——**这个改法照着做仍然装不上**。
本轮把它钉死：`profile` 是**按包名签发**的，hvigor 在 `default@SignHap` 会校验它。

### 决定性证据（Windows x64，m3u8dl-tauri，bundleName=`com.atomgit.m3u8dl_tauri`）

把工程 `signingConfigs` 改成指向本机**现存且文件齐全、含本机 UDID** 的那套材料（`default_ohos-probe…`，
口令密文一并从用同一套材料的工程搬过来），`hvigor assembleHap` 仍然失败，而且错误变了：

    > hvigor ERROR: Failed :entry:default@SignHap...
    > hvigor ERROR: 00303074 Configuration Error
    Error Message: The bundleName in app.json5/hvigorfile.ts does not match the bundleName
    in the generated SigningConfigs. At file: …\src-tauri\gen\ohos\build-profile.json5

本机 4 套 profile 的包名是 `com.yang.testcj` / `com.jiujiang.habit_tree` / `com.yang.ohosnes.fceux`，
**没有** `com.atomgit.m3u8dl_tauri`。结论：这道门不是路径问题，是**包名门槛**；
"机器上有含本机 UDID 的材料"≠"能写回"。（实验后已把工程文件按原样还原，SHA256 校验一致。）

### 实跑证据（`lingqu-cli sign --path E:\test\rust\m3u8dl-tauri`）

    reason   : …有文件不存在…；工程包名 `com.atomgit.m3u8dl_tauri` 与候选材料包名不一致
    nextStep : 工程包名 `com.atomgit.m3u8dl_tauri` 没有对应的签名材料（profile 按包名签发）。
               本机现有材料的包名：com.yang.testcj(27台/含本机)、com.jiujiang.habit_tree(26台/含本机)…
               hvigor 写回/抄用别的包名的材料会报 00303074（bundleName 与 SigningConfigs 不一致）。
               在 DevEco 里对**本工程**点一次「Automatically generate signature」（需登录）…
    candidateBundleMatch : false
    apply（LINGQU_SIGN_APPLY=1）: applied=false，applyError="拒绝写回：本机候选材料的包名是 com.yang.testcj…"
    且工程 build-profile.json5 的 SHA256 前后一致（**拒绝而不是写坏**）

### Added

- `src/compiler/sign.cj`：`bundleMatches()` / `profileBundleCensus()` / `judgeSignForWriteback()`
  —— 把"包名门槛"做成独立判定（`SignCheck.bundleMatch`），不再塞进 `filesExist` 之类的开关里。
  没有候选材料时**不叠**这句（设备离线就是"拿不到 UDID"，别把人带偏）。
- `src/port/gates.cj`：`hapSignHint(logText)` —— HAP 闸直接给出签名根因
  （`00303074` 包名不一致 / `00303107` 材料文件不存在），不用再自己去 `.lingqu/hap/<工程>.log` 里扒。
- 指纹库 **FP-018**（00303074）/ **FP-019**（00303107），走 guide 档（涉及 DevEco 登录，不自动改）。
- 探针 `LINGQU_SIGN_UDID`：设备离线/无设备机器上复跑签名体检（日志里标注"探针覆盖，非 hdc 实测"）。
- `ui_report` 新增 `signBundleMatch` / `signCandidateBundles`（前端 `reportUi` 与后端白名单两处同批加，
  见 AGENTS §4-60）；⑤ 屏候选行改成「N 份（可用：有 / 无——包名不符）」，hover 给出两边包名。

### Fixed

- **误导性建议**：候选材料包名与工程不一致时，以前会说"抄回来即可"——照着做 hvigor 必然 00303074。
  现在结论明确不可用，并把"缺哪个包名 / 本机有哪些包名 / 该点哪里"一次说清。
- **apply 不再写坏工程**：包名不匹配时拒绝写回（以前会写进一份注定失败的 signingConfigs，
  比"没配"更难排查——人会以为是口令/路径问题）。
- HAP 装配失败时闸门只报「assembleHap 没成功」→ 现在带签名根因那一行。

### 测试

`cjpm test` **284 例**（+9）：`bundleMatches` 边界（空/空白/大小写）· `profileBundleCensus`
（解析失败不列 / UDID 未知不写"不含本机"）· **复现用例** `testWritebackRefusesOtherBundle`（先红后绿）·
无候选时不误报 · 包名匹配时保留原建议 · `hapSignHint` 两条 + 不瞎猜 · 指纹 FP-018/FP-019 命中。

## [0.39.8] - 2026-11-01

**主题**：**断点板跟着工程走**。`tasks.json` 原先写在灵渠应用目录、跨工程共用，
于是打开 B 工程时顶部还显示 A 工程的进度——和「8 个路径框各填一遍」是同一个毛病：
**同一件事实存了两份权威**。现在板子落在 `<工程>/.lingqu/tasks.json`，工程自包含。

### 实跑证据（Windows x64，`lingqu-cli resume --path <工程>`，五道闸全绿 / 275 例）

    habit-tree   → "out": "E:\\test\\rust\\habit-tree\\.lingqu\\tasks.json"     done=7/8 next=deploy
    m3u8dl-tauri → "out": "E:\\test\\rust\\m3u8dl-tauri\\.lingqu\\tasks.json"   done=4/8 next=hap
    habit-tree 板子 SHA256 在跑 m3u8dl-tauri 前后**不变**（两工程互不覆盖）

### Changed

- `src/task_feed.cj`：`taskBoardPath()` → **`taskBoardPathFor(projectPath)`**（单点定义，内部走
  `lqPathOf`）+ `legacyTaskBoardPath()` 保留旧应用级位置；`saveTaskBoard(board, projectPath)`
  改工程级写盘，目录改为 **`recursive: true`** 创建（换成工程级路径后不建目录会直接写失败）。
- **读侧双查**（迁移期不丢证据）：读板一律 `resolveLqPath(projPath, "tasks.json")` —— 工程优先、
  CWD 兜底，旧板子照旧读得到（AGENTS §4-33 的纪律：产出方与消费方同批改）。
- 消费方同批切换：`ResumeCommand`（读板 + `out` 回投 + 写回落 `path`，没给就沿用板子里记的工程）、
  `ReportCommand`（读板取工程名）、`report_feed.cj` 的证据清单（记实际用的那个路径）。
- 文案三处对齐事实：`agent_context.cj` 的注入说明（原写"在灵渠应用目录、跨工程共用"）、
  界面「刷新断点」的 tooltip、`agent_ctx_path_test.cj` 的断言。

### Added

- `src/tests/task_board_path_test.cj`（4 例）：板子跟工程走 / 无工程回落旧位置 /
  双读工程优先 / 双读回落不抛。**断言不断死分隔符**（`cjhPathSep()` 在 Windows 上是 `\`），
  且明确允许「工程与 CWD 都没有板子 → 回落旧板子」这条合法路径（测试 CWD 是仓库根，
  本来就躺着一块应用级旧板子，这个分支没法稳定构造成"两处都没有"）。
- ADR **D-016**：断点板跟工程走（写入位置 = 工程，读侧双查兜底，迁移完成后可删兜底）。

## [0.39.7] - 2026-11-01

**主题**：把"假停滞"彻底修掉（0.39.6 只修了一半），并拿到第一次**完整链路**实跑证据：
`build` 落档从 `exitCode=101` 变成 **0**，hap/sign 也真的被跑到。

### 实跑证据（Windows x64，`LINGQU_UI_PROBE=ai-full`，m3u8dl-tauri，cjh 分支构建 + `CJH_BASH_TIMEOUT=600`）

    wsFrameTypes：delta:86  done:1  tool_start:40  tool_result:40   ← 40/40 完全配对，无丢帧
    aiPortPolls=151  aiPortStalled=false  abortSource=""  wsReconnects=0  errorCount=0
    trace.jsonl：67 KB；trace 里 `| tail` 0 次、`> /tmp/` 5 次（长命令都改成重定向了）
    落档：scan ✓ / deps ✓ / port ✓ / **build exitCode=0** / hap（hvigor BUILD FAILED，但已产出 7.9 MB HAP）/ sign（debug，材料探测不到）

- **build exitCode=0 的原因**：agent 读了任务书新加「交叉编译的硬前置」+ R2-PORT-008 的 guide 片段，
  自己给 `src-tauri/.cargo/config.toml` 补了 `[env] CC_aarch64_unknown_linux_ohos`（trace 里有那条 edit），
  `ring` / `ohos-arkui-sys` 的 C 依赖这才找到 NDK clang。
- **这轮把应用中途打断的是我自己的门禁**：`scripts/test.bat` 第 ④ 闸检测到旧 `main.exe` 在跑，
  结束进程以释放产物（日志原文：`[!] 上一版 main.exe 仍在运行，先结束它以释放产物`），
  所以 deploy/verify 没跑到。**教训进 §4：实机探针与门禁不要同时跑。**

### Fixed

- **假停滞（第二轮）**：0.39.6 只把"轨迹行数"编进签名，但**单个长工具调用期间轨迹也不动**
  （tool / tool_done 各一条）——实跑到 poll≈106 又报了「AI 好像在绕圈」。现在：
  ① 新增 `agentTraceBusy(path)`（最后一条轨迹是 `tool` 且没有 `tool_done` = 正在干活），
  正在跑工具时**不判停滞**并清空已攒的窗口（`AutoPortState.clearHistory()`，polls 计数保留）；
  ② `AUTOPORT_STALL_POLLS` 6 → **20**（轮询 900ms，6 次 ≈5.4 秒，比一次 LLM 思考还短，必然误报）。

### Changed

- 用例改成常量驱动：`testStatePushSigKeepsWindow` 原先硬编码"推 12 条、留 6 条"，
  阈值一改就假红——现在按 `AUTOPORT_STALL_POLLS + 5` 推、按常量断言。

### 追加（同一轮补做）：`autoport_start` 自动打开「断连不打断」

上一条把责任推给了"用户手工配 settings.json"——这不对，**配置不该由人记**。现在
`t2h:autoport_start` 在准备现场时自动调用 `ensureCjhKeepRunning(userHomeDir())`：

- 新增 `src/cjh_settings.cj`：`ensureKeepRunningOnDisconnect(json)` 对 settings JSON 做
  **定点修补**（不整体重排、不动用户注释与字段顺序），幂等；没有 `web` 段时原样返回、不乱写。
- 结果回投 `keepRunningOnDisconnect` 字段（`already` / `written` / `no-settings` / `no-home` /
  `error:…`），排障时一眼看出到底改没改。
- 测试 `src/tests/cjh_settings_test.cj`：注入 / 幂等 / false→true / 无 web 段不动 / 空输入 /
  home 缺失不抛。`cjpm test` 267 例全 PASS。

**诊断（hap/sign 的 `ok=false`，同一个根因）**：hap 不是装配失败 —— 落档里
`hapBytes=8151230`、`hasArm64So=true`、两个 so 都在（`libentry.so` + `libm3u8dl_tauri_lib.so`）；
失败在 `default@SignHap`：

    hvigor ERROR 00303107 Configuration Error
    Invalid storeFile value. Make sure it is not null or empty.
    The file must be included in 'C:\Users\yang\.ohos\config\default_ohos_cqJPvSnvtx…'

工程 `build-profile.json5` 的 `signingConfigs` 指向 `default_ohos_cqJPvSnvtx…{cer,p7b,p12}`，
而 `~/.ohos/config` 里现存的材料是另外几套（`sign` 落档 `candidateCount=4`，探测到
`default_ohos-probe_…p7b` / `default_ohos_m7Gxh5…p7b` 等）——**写回时选中的那套文件不存在**。
所以 hap 与 sign 是同一件事：签名材料选错/未写回，跟装配、跟 agent 都无关。下一步按
`skills/t2h-ohos-port/references/signing.md` 的配方，改成"只挑现存且在 `~/.ohos/config` 内、
profile 含本机 UDID（`B8861DAE…`）的那套"再写回，并重跑 `t2h:hap` 验证。
### 追加：这一轮把「整轮被打断」的**真凶**找到了（cjh 侧已修）

复跑时观察到 `Agent.interrupt` 出现但 `abortSource=""`（两处 UI abort 入口都没被点），
顺着 `~/.cjh/logs/cjh.log` 定位到 cjh 的**断连处理本身**就打断回合：

    [23:54:12] Agent.interrupt 已请求：interruptFlag=true + abort() 已调用
    [23:56:21] WebChannel 发送失败，连接判定为断开，后续帧跳过（上一轮的 WsSendGuard 生效）
    [23:56:21] Agent.run 被用户中断（24 轮后）

调用点是 `gateway/channel.cj` 的 `interruptSession()`（WS 断连时调用）。对交互式合理，
对**无人值守的长任务**是灾难：WebView 只重连一次（`wsReconnects=1`），
40 次工具调用、交叉编译已经跑到 `exitCode=0` 的整轮迁移当场作废。

cjh 已加 `web.keep_running_on_disconnect`（默认 false 保持老行为；开着则断开后本轮跑完、
结果落会话、重连靠 `history_messages` 补看）。**本机 `~/.cjh/settings.json` 已置 true 用于验证**
（备份在 `%TEMP%\cjh_settings_backup.json`）。灵渠侧下一步要做的：`t2h:autoport_start` 时
把这条设置自动写进去，别让用户手改。

### 验证：开关打开后重跑，回合**扛住了 13 次断连**

    [00:08:53] 客户端断开，本轮继续执行（web.keep_running_on_disconnect=true）   ← cjh 新逻辑
    [00:11:01] build 落档 exitCode=0
    [00:13:03] Agent.run 正常结束: 41 rounds, 49 tools, 328028ms               ← 跑完并收尾

    ui_report：wsReconnects=13  aiPortStalled=false  abortSource=""  toolCards=33
    落档：scan ✓ / deps ✓ / build **ok=true exitCode=0** / hap 落档 ok=false / sign 落档 ok=false

对比上一轮（不加开关、只加写容错）：同样是重连，那次 `Agent.run 被用户中断（24 轮后）` 直接作废；
这次 49 次工具调用跑完整轮、`build` 拿到 `exitCode=0`，hap 与 sign 也真的被执行到
（各自 `ok=false`，原因待查：hap 是 `hvigor BUILD FAILED`、sign 是 debug 态且探测不到签名材料）。



  阈值一改就假红——现在按 `AUTOPORT_STALL_POLLS + 5` 推、按常量断言。

---

## [0.39.6] - 2026-11-01

**主题**：端到端实跑暴露的两个"能打死整轮"的问题各修一处——停滞判定并入 agent 活动、
abort 留痕；交叉编译的 C 依赖环境不再"半配好就当已配好"。

### 实跑证据（Windows x64，`LINGQU_UI_PROBE=ai-full`，m3u8dl-tauri，cjh 分支构建 + `CJH_BASH_TIMEOUT=600`）

    ui_report：wsState=connected  wsSendFail=0  cjhBin=<分支产物>  toolCards=24  agentTraceLines=48
    wsFrameTypes：delta:91  tool_start:24  tool_result:23  history_messages:1
    落档：scan 5.8 KB / deps 175 KB / port（5 条规则 applied）/ build（6.3 KB + 298 KB jsonl + 4.7 KB log）

- **好的一面（上一轮 cjh 修复生效）**：agent 的长命令变成
  `"…main.exe" build --path . > /tmp/build.log 2>&1; echo "EXIT:$?"; tail -40 /tmp/build.log`
  —— **不再 `| tail`**；24 次工具调用无一次卡满超时；事后会话 shell 空闲、无残留子进程。
- **坏的一面（本轮修）**：① 页面重连两次后 cjh 往旧 WS 写帧抛 10053，**整轮 run 当场结束**，
  那条 build 的 `tool_result` 永久丢失（cjh 侧已修，MR !11 `840dc85`）；
  ② 分钟级交叉编译期间落档当然不动，连续 6 次轮询被判「AI 好像在绕圈」——假停滞。
  该轮 `Agent.interrupt` 有记录但**没有** `autoport-stop` 标签，说明按的是对话面板那个 abort；
  现在两处 abort 都会标来源。

### Added

- `t2h:ui_report` 新增 `abortSource` / `abortAt`：停止按钮 → `stop-button`、对话面板「中止」→ `chat-abort`，
  不再出现"cjh 收到 interrupt 却查不到谁按的"。
- `autoportSnapshotWith(rows, traceLines)`：停滞签名并入 agent 活动量
  （`<工程>/.lingqu/agent/trace.jsonl` 行数）；`autoportSnapshot` 保留，等价于 `traceLines=-1`。
- `cargoEnvOnlyToml(sdkNative)`：只补 `[env]` 段的片段，用于工程已有 `.cargo/config.toml`
  但缺 C 依赖环境的场景（不覆盖既有 linker 配置）。

### Changed

- 任务书新增「交叉编译的硬前置」：`.cargo/config.toml` 的 `[target…]` **和** `[env]` 两段都要在；
  缺 `[env]` 的症状是 `cc-rs: … "cc" … --target=aarch64-unknown-linux-ohos`（`ring` 的 curve25519.c
  实测失败，build 落档 `exitCode=101`）；看到这条错先查 `[env]`，别改 Rust 源码；
  回滚改造别只回滚 `Cargo.toml`。

### Fixed

- **R2-PORT-008 幂等判据误判"已配好"**：原判据只看文件里有没有 `aarch64-unknown-linux-ohos`。
  m3u8dl-tauri 的 `.cargo/config.toml` 有 target 段却**没有 `[env]`**，于是被判"跳过"，
  而 `ring` 这类含 C 代码的依赖只能退回宿主 `cc` → 交叉编译必然失败。现在要求
  target 段 + `CC_aarch64_unknown_linux_ohos` 都在才算跳过；半配好降成 **guide**
  （`applied=false` / `needsHuman=true` / `after` 给出应追加的片段），既不动用户文件也不假装完成。
- 版本三处对齐：`cjpm.toml` / `cj-tauri.toml` 0.39.3 → **0.39.6**（此前已落后代码两个小版本）。

---

## [0.39.5] - 2026-11-01

### Fixed

- 页面断线**重连不设次数上限**（backoff 封顶 5s）：换引擎实例 / 引擎重启后，页面不再永久停在
  「连接已断开——回复可能不完整」。
- `t2h:ui_report` 新增 `wsReconnects`，用来断言"页面真的在重连"。

---

## [0.39.4] - 2026-11-01

**主题**：cjh 第 4 个 PR（bash `timeout` 参数）合入后复跑全自动 —— **AI 第一次把没迁过的样本编译到 exit=0**。

### 实跑证据（Windows x64，`LINGQU_UI_PROBE=ai-full`，m3u8dl-tauri，`CJH_BASH_TIMEOUT=600`）

    ui_report：toolCards=49  frames=110  errorCount=0  agentTraceLines=98
    trace.jsonl：bash 77 次，**命令超时 0 次**，exit code: 0 共 37 条
    build 落档：project=m3u8dl-tauri  target=aarch64-unknown-linux-ohos
                exitCode=0  errorCount=0  ← 交叉编译成功（0.39.2 时是 exitCode=101）
                gates.passed=false，唯一失败项：前端指纹闸「.so 里没有内嵌前端资源（frontendDist 配了吗）」
    行为：它自己写了 src-tauri/src/lib.rs（write_file，2242 字符），随后在跑命令继续处理

对照：0.39.2 同一路径 25 次 bash 全失败、build exit=101；现在 77 次调用零超时、**编译通过**。

### 仍未完成（下一步）

- 前端指纹闸还没修好（frontendDist 未配），所以没走到 hap/sign/deploy；
- 实测最后一条 trace 是 in-flight 的 `python - <<EOF`（heredoc），4 分钟无结果 —— 疑点：
  这条命令依赖 PATH 里的 python，且 heredoc 在持久 bash 会话里可能吞掉后续输入。
  排查方向：① 机器上 python 是否存在；② 是否需要提示 agent「heredoc 少用，改写脚本文件再执行」。
## [0.39.3] - 2026-11-01

**主题**：修 `--path .` 让落档名变成 `.`（0.39.2 实测暴露，`..json` 那种）。

### 现象与根因

agent 按我们的任务书在**工程根**用 `--path .` 跑 `lingqu-cli build`，落档写成
`..json / ..jsonl / ..log`。根因：`projectNameOf(".")` 把 `"."` 原样当名字，
`sanitizeFileName` 再清成空串。而「在工程根用 `--path .`」正是我们自己教它的写法。

### 处置

- `src/scanner/scan.cj` 新增**纯函数** `projectNameOfPath(path, cwd)`（cwd 注入，可单测）：
  `"."` → cwd 末段；`".."` → cwd 父目录末段；`"./x"` → `x`；绝对路径照旧取末段；
  末尾分隔符归一（顺带修了旧契约"末尾带分隔符返回空串"——现在返回名字）
- `projectNameOf` 改为先按 cwd 解析、拿不到 cwd 才退回旧逻辑（不崩）
- 单测 `src/tests/project_name_test.cj`（3 例）：`.`/`./`/空串/反斜杠 cwd/`..`/相对子路径/绝对路径，
  外加一条"退化输入不许返回 `.` 或空串"的兜底断言（252 例全绿）

### 证据

```
在工程根： lingqu-cli build --path . --verifyOnly
  outJson = .lingqu\build\m3u8dl-tauri.json        ← 正确名字（修前是 ..json）
  .lingqu/build/ 下：m3u8dl-tauri.{json,jsonl,log}
```
## [0.39.2] - 2026-11-01

**主题**：**第一次让 AI 全自动迁一个从没迁过的样本**（`m3u8dl-tauri`，此前只有 scan/deps）。跑通 4 步，卡在两个新缺陷上（都已定位）。

### 实跑证据（Windows x64，`LINGQU_UI_PROBE=ai-full`，scope=all，合入后构建的 cjh）

    ui_report：toolCards=32  frames=78  errorCount=0  agentTraceLines=64
    trace.jsonl：bash 59 次，命令执行异常 = 0，exit code: 0 共 26 条
    工程落档（**从零生成**）：m3u8dl-tauri/.lingqu/{scan,deps,port,build}
    build 落档：target=aarch64-unknown-linux-ohos  exitCode=101  errorCount=1  ← 真编译错，等 AI 修

顺序与行为：scan → deps → port --apply（有备份目录）→ build；中间自己 `cat` 了 build 日志
（trace 里有真实 cargo 输出 `Compiling cfg-if v1.0.4 …`），最后调用 `lingqu-cli build --path .` 重跑。

### 暴露的两个新缺陷（下一轮第一件事）

1. **`--path .` 让落档名变成 `.`** → 文件写成 `..json / ..jsonl / ..log`
   根因：`projectNameOf(".")` 原样返回 `"."`，`sanitizeFileName(".")` 清成空串；而我们的
   AGENTS.md/任务书**正是教 agent 用 `--path .`**（agent cwd = 工程根）。
   修法：命令入口统一把相对路径解析成绝对（`absProjectPath`），或 `projectNameOf` 对 `.`/`..`/空串
   回退到 cwd 末段名。
2. **长命令会卡住回合**：cargo 交叉编译是分钟级，而 cjh 的 bash 工具单条命令有超时；实测最后一帧
   停在"已发起 build、结果没回"，`aiPortPolls=127` 但落档不再变化。
   修法（cjh 侧建议）：bash 工具加"后台执行 + 轮询"，或暴露 `timeout` 参数让 agent 自己传。
## [0.39.1] - 2026-11-01

**主题**：**AI 真的能动手了** —— cjh 的三个 PR 合入后，实机验证 agent 从"能看不能跑"变成"能看能跑"。

### 证据（Windows x64，`LINGQU_UI_PROBE=ai-port`，habit-tree，用**合入后重新构建**的 cjh）

```
① 合并后的二进制接口自述（不是单测，是 GET /api/capabilities）：
   shell = {"path":"D:\\Program Files\\Git\\bin\\bash.exe","mode":"bash","source":"GIT_BASH"}
   ws    = {"max_frame_bytes":262144}
   → Git 装在 D 盘也能找到；WS 帧上限也公告出来了

② 端到端（半自动档 ④「🤖 交给 AI 改造」）：
   ui_report：toolCards=19  frames=45  errorCount=0  agentTraceLines=38
   trace.jsonl：bash 调用 33 次，**真正的 ProcessException 失败 = 0**，`exit code: 0` 共 14 条
   逐条节选（trace 原文）：
     exit code: 0  stdout: Counter({'可用': 443, '不可用': 10})        ← 读 deps 落档
     exit code: 0  stdout: "id": "R2-PORT-011", "applied": false ...   ← 读 port 落档
     exit code: 0  stdout: .lingqu/port/habit-tree/Cargo.toml.bak === git status === M src-tauri/gen/ohos…
     exit code: 0  stdout: .lingqu/port: total 4 …
   → 它在真跑 `port --apply`、看备份、看 git status
```

对照 0.39.0：25 次 bash **全部** ProcessException；本轮 33 次**零**失败。

### 本轮暴露的下一处（诚实记录）

- **停滞判定会误报**：`aiPortVerdict` 报"AI 好像在绕圈（落档连续没变化）"，实际它一直在干活（33 次 bash）——
  因为判定**只看落档**；habit-tree 已迁移完、`port --apply` 不产生改动 → 落档自然不动。
  修法：把 `agentTraceLines`（工具活动）纳入停滞判据，**落档不动且没有工具活动**才算卡住。

## [0.39.0] - 2026-11-01

**主题**：agent 行为轨迹落成工程证据（`<工程>/.lingqu/agent/trace.jsonl`）。

cjh 的 web 会话只在销毁时落盘，跑完的回合在 `~/.cjh/sessions/` 里仍只有 system 消息（实测 158 B），
"AI 改了什么、跑了哪些命令"因此没有留痕。现在由**我们**记：`src/agent_trace.cj`（纯函数 + 4 例单测）
+ 命令 `t2h:agent_trace` + 页面 `onFrame` 挂钩（tool_start / tool_result / done），
`ui_report` 新增 `agentTraceLines`。分工依据见 ADR D-015（我们是记录员）。

## [0.38.1] - 2026-11-01

**主题**：**落档跟着工程走 —— 全部写入者迁完**（12 个产出者里 11 个在工程内，2 个按设计留在应用目录）。

### Changed（写侧全量迁移，每个命令一次 `cjpm test`）

| 命令 | 落档新位置 | 备注 |
|---|---|---|
| `t2h:scan`（0.38.0） | `<工程>/.lingqu/scan/<工程>.json` | — |
| `t2h:deps` | `<工程>/.lingqu/deps/<工程>.json` | — |
| `t2h:build` | `<工程>/.lingqu/build/<工程>.{json,jsonl,log}` | 读侧（回归闸基线 `lastBuildErrorCountOf`）改走 `resolveLqPath` |
| `t2h:hap` | `<工程>/.lingqu/hap/<工程>.{json,log}` | — |
| `t2h:sign` | `<工程>/.lingqu/sign/<工程>.{json,log}` + `signingConfigs` 备份 | 读侧 `signModeOf(proj, path)` 也跟着带工程路径 |
| `t2h:verify` | `<工程>/.lingqu/verify/<工程>.{json,md,html,evidence.log}` | — |
| `t2h:deploy` | `<工程>/.lingqu/deploy/<工程>.{json,log}` | — |
| `t2h:report` | `<工程>/.lingqu/report/<工程>.{md,html,json}` | — |
| `t2h:migrate`（结果卡） | `<工程>/.lingqu/migrate/<工程>.md` | — |
| `t2h:port`（备份/预览/决策） | `<工程>/.lingqu/port/<工程>/…` | `ensurePortDirs()` 改成 `ensurePortDirs(dir)`：不再硬编码 `.lingqu/port` |
| `t2h:resume`（`tasks.json`） | **仍在应用目录** | 断点板是"跨工程的工具状态"，不属于单个工程（待讨论，见下） |
| `t2h:batch`（矩阵） / `ui_report` | **仍在应用目录（有意）** | 矩阵是多样本的工具体产物；`ui-report` 是界面自检证据，与被迁移工程无关。两处代码里已加注释，避免后人"顺手改掉" |

### 未做（诚实标注）

- `t2h:resume` 的 `.lingqu/tasks.json` 仍写在应用目录：它是**跨工程**的断点状态（一个板记 8 步 + 会话 id）。
  要不要按工程拆成 `<工程>/.lingqu/tasks.json`，需要先定"用户在界面切换工程时断点板怎么表现"，
  这是产品决定，不在这轮硬改。
- AGENTS.md 文案（"落在本工程的 `.lingqu/` 下"）**现在才变成真的**，但还没写准确路径 → 下一步。
- `resolveLqPath` 的 CWD 兜底仍保留（旧落档还能读）；全部验证完再删。

## [0.38.0] - 2026-11-01

**主题**：**落档跟着工程走（第 1~2 步：底座 + 第一个命令）** —— 让 agent 与界面看**同一份**落档。

### 为什么

0.37.2 实测暴露：界面/命令跑出的落档在**灵渠应用目录**（`<lingqu>/.lingqu/`），而 agent（cjh）
的 cwd 是**目标工程**（`<project>/`）→ 它看不见落档；我们注入的 AGENTS.md 却写"落在本工程的
`.lingqu/` 下"——**与事实不符**（agent 原话：'`.lingqu/` 里只有任务书本身，没有任何落档 JSON'）。
这是"AI 能自己判断下一步"的前提，必须修。

### Added

- `src/workdir.cj`（纯函数 + 4 条单测，243 例）：
  - `lqDirOf(工程路径)` → `<工程>/.lingqu`（空路径退回 `.lingqu`，末尾分隔符归一，不会拼出 `x//.lingqu`）
  - `lqPathOf(工程路径, rel)` → `<工程>/.lingqu/<rel>`
  - **`resolveLqPath(工程路径, rel)` → 工程优先、CWD 兜底**（迁移期新旧落档都能读到，不丢证据）
  - `lqIsProjectScoped(path, 工程路径)` —— 报告里标注口径用
- `taskArtifactRelPath(projName, stepId)`：落档的**相对路径**单点定义（`taskArtifactPath` 改为
  调它 + `.lingqu/` 前缀，保持旧行为），产出方与消费方从此共用一份（AGENTS §4-33）
- `observeTaskStepAt(projName, stepId, 工程路径)`：读侧双查；旧签名 `observeTaskStep` 保留并委托
- 单测故意**不依赖分隔符**（Windows `\` / Linux `/` 都过）：钉的是"拼对了、优先级对了"

### Changed（迁移进度：12 个产出者里已完成 1 个）

| 步骤 | 命令 | 状态 |
|---|---|---|
| **1** | **底座 `workdir.cj` + 单测** | ✅ 完成 |
| **2** | **`t2h:scan`（写侧改工程内）** | ✅ 完成，实测 `out = E:\test\rust\habit-tree\.lingqu\scan\habit-tree.json` |
| 2 | `t2h:deps` / `port` / `build` / `hap` / `sign` / `deploy` / `verify` / `report` / `batch` / `resume(tasks.json)` / `migrate(结果卡)` | ⏳ 待迁（每个命令一次门禁） |
| 3 | 读侧（`collectTaskBoard`、`migrate` / `autoport_status` / `stepBriefOf` 已切 `observeTaskStepAt`） | ✅ 主链路已切 |
| 4 | AGENTS.md 文案去掉"本工程"、写准确路径 | ⏳ 待做（**现在这句还是错的**） |
| 5 | `resolveLqPath` 的 CWD 兜底删除 | ⏳ 待全部迁完后 |

### 证据

```
门禁：五道闸全绿 build-biz:PASS test:PASS(TOTAL=243) check:PASS build-app:PASS build-cli:PASS
lingqu-cli scan --path E:\test\rust\habit-tree
  → out = E:\test\rust\habit-tree\.lingqu\scan\habit-tree.json（文件存在）
```

## [0.37.3] - 2026-11-01

**主题**：把 0.37.2 那个坑**从上游堵掉**——cjh 的 WS 读侧不再静默丢弃超限帧。

### cjh 侧（两个独立 PR 分支，均已推）

| 分支 | 内容 | 验证 |
|---|---|---|
| `fix/declarative-tool-shell` | `registry.cj` 的 `/bin/bash` → `ShellProvider`（Windows 声明式技能工具可用） | build 0 warning / 540 例全绿 |
| `feat/ws-frame-limit` | 新增 `WS_MAX_INBOUND_BYTES`（256 KiB）：超限帧回 `{"type":"error","code":"frame_too_large","retryable":false}` 并 continue（不杀连接）；读异常同样先回 `ws_read_failed`；`/api/capabilities` 的 `features.ws.max_frame_bytes` 公告上限 | 同上 |

提 PR：
- https://gitcode.com/qq8864/cjh/merge_requests/new?source_branch=fix/declarative-tool-shell
- https://gitcode.com/qq8864/cjh/merge_requests/new?source_branch=feat/ws-frame-limit

### 说明

- 灵渠侧 0.37.2 的「任务书落文件 + 短 kickoff」**不依赖**这两个 PR（已自证可用：
  `tool_start:40 / tool_result:40 / done:1`）；PR 的价值是**让下一个调用方不用再踩**——
  失败会得到明确 error，而不是"没有回帧"。
- 「落档跟着工程走」（`<工程>/.lingqu/...`）本轮**未做**：它要改所有命令的落档前缀，
  属于跨 10+ 文件的迁移，必须配"读两处（工程优先、CWD 兜底）+ 逐命令切换"的迁移策略与单测，
  不适合在上下文将尽时动。设计已写进 `docs/进度记录.md` 的下一步。

## [0.37.2] - 2026-11-01

**主题**：**AI 终于真的开工了** —— 定位并修掉「任务书发过去 cjh 不干活」，第一次拿到
agent 自主跑完一个回合的实据（**40 次工具调用、886 帧、done 收尾**）。

### 二分定位（一次探针定死）

| 变量 | 实验 | 结果 |
|---|---|---|
| 通道不通？ | 同会话发 9 字短句 | ❌ 排除：`frames=5, delta:2, done:2, replyPreview=收到` |
| 发送失败？ | `wsSendFail` | ❌ 排除：`0` |
| 多余 `new_session`？ | 已去掉再跑 | ❌ 排除：现象不变 |
| **workspace 切换后状态坏了？** | **切完工作区只发短句**（新探针 `LINGQU_UI_PROBE=ai-short`） | ❌ 排除：短句照样正常 |
| **消息太长？** | 同上：4448 字长文 vs 9 字短句 | ✅ **就是这个**：短句有回、长文静默 |

### Fixed

- **任务书改为「落文件 + 短 kickoff」**：写进**目标工程**的 `.lingqu/autoport-directive.md`，
  只发一条 <400 字的开工信（`buildAutoPortKickoff`，纯函数 + 1 条"必须短"的单测），
  让 agent 用自己的 `read` 工具去读。对任何单帧长度上限免疫，也更符合 agent 的工作习惯
- 写盘失败时如实退回"整段发送"并在返回值里带 `directiveError`（不静默）

### 证据（Windows x64，`LINGQU_UI_PROBE=ai`，habit-tree）

```
wsFrameTypes = "history_messages:1, delta:804, tool_start:40, tool_result:40, done:1"
frames = 886    toolCards = 40    errorCount = 0
任务书落盘：E:\test\rust\habit-tree\.lingqu\autoport-directive.md（4448 B）
AI 的自述（实时回复节选）："任务书已读完。按指示先跑 resume 看落档。
  .lingqu/ 里只有任务书本身，没有任何落档 JSON。我先核实落档是否存放在别处。"
门禁：五道闸全绿（TOTAL=239）
```

### 新发现（下一步第一件事）

**落档位置跟 agent 的 cwd 对不上**：界面/命令跑出来的落档在**灵渠应用的工作目录**
（`E:\test\rust\test1\lingqu\.lingqu\`），而 agent 的工作目录是**目标工程**
（`E:\test\rust\habit-tree\`）。`t2h:agent_context` 写进工程的 AGENTS.md 说"落在本工程的
`.lingqu/` 下"——**与事实不符**，agent 因此先花了几轮去核实。

两种修法，倾向第一种：

1. **落档跟着工程走**（正解）：所有命令的落档路径改为 `<工程>/.lingqu/...`，工程自包含，
   换机器/换会话都能自证；代价是每个命令的落档前缀要统一改（`lingquWorkDir(projectPath)`）。
2. 只改文案：告诉 agent"落档在灵渠应用目录"，但这样 agent 与界面就永远各看一套落档。

## [0.37.1] - 2026-11-01

**主题**：**两种自动化档次 + 把 WS 排障的证据补齐**。

用户澄清了产品形态，这一轮据此对齐：

| 档位 | 入口 | 谁干活 | 收尾 |
|---|---|---|---|
| **半自动** | 左栏各屏（②画像 / ③依赖 / ④改造 / ⑤构建 …） | 人点一步，**AI 干那一步**（改代码、跑验证） | 做完**停下**，下一步由人点 |
| **全自动** | 「⚡ AI 自动迁移」（默认屏 / 顶栏） | cjh 一路干到 verify | 卡住/超预算才叫人 |

两档共用**同一套引擎**（`t2h:autoport_start { scope }`），只有任务书的"范围与收尾条件"不同。

### Added

- `scope` 参数（`all` = 全自动；`port`/`deps`/`build`/`hap`/`sign`/`deploy`/`verify` = 半自动）：
  `autoPortScopeTitle` / `isFullScope` / `autoPortScopeGoal`（纯函数 + 5 条单测）。
  半自动任务书会写明「只做「规则改造」这一步」+ 该步收尾条件 + **做完就停，不要顺手把后面几步也做了**
- ④ 改造执行屏新增 **`🤖 交给 AI 改造`** 按钮（与「预览改造 / 应用（落盘）」并排，互不冲突：
  规则引擎是不花模型钱的快通道，也是 agent 的手）
- `ui_report` 新增排障字段：`wsSendFail` / `wsLastSendErr` / `wsFrameTypes`（帧类型计数）
  —— 以前发送失败是静默的，分不清"没发出去"和"cjh 没回"

### Changed

- 撤回 0.37.0 的"补 `POST /api/chat`"计划：**用户指出 WS 已经能直接发消息**，产品是桌面 GUI、
  页面永远在场，REST 对话入口不是需求。那是在给一个 WS bug 打补丁（详见 docs/上游回馈-cjh.md 排障进度）

### 证据（Windows x64，2026-11-01）

```
门禁：五道闸全绿 build-biz:PASS test:PASS(TOTAL=238) check:PASS build-app:PASS build-cli:PASS
WS 排障（LINGQU_UI_PROBE=ai，habit-tree）：
  wsSendFail=0  wsFrameTypes="history_messages:1"  frames=1  toolCards=0
  → 任务书**发送成功**，cjh 只回一帧 history_messages 就静默；会话文件 158 B（只有 system 消息）
  同会话里探针短消息正常：frames=3 / lastFrameType=done / replyPreview=收到
  ⇒ 排除"通道不通"与"发送失败"；剩下两个变量：消息长度（4448 字）与 workspace 切换后的会话状态
```

## [0.37.0] - 2026-11-01

**主题**：**方向纠偏 —— AI 是执行者，不是"失败后给建议的顾问"**。

0.36.0 的「一键迁移」其实是**确定性流水线**：我们按固定顺序跑 8 个命令，失败就把现场问一次 AI，
AI 只出建议、命令还得人点。用户当场指出这做反了：**这个项目内置了 cjh 这个 agent，
移植的活本来就该它干**。0.37.0 把它摆正：

| | 0.36.0（做反了） | 0.37.0（摆正） |
|---|---|---|
| 谁在干 | 我们跑命令，AI 只在失败后被问一次 | **cjh 自己读落档 → 改代码 → 重跑**，我们准备现场 |
| 人的位置 | 每一步都要人点按钮 | 只在 AI 主动要求时才介入（介入次数 = 验收指标 A3） |
| 落档的角色 | 我们的输出 | **AI 的输入 + 我们的唯一判据** |
| 确定性流程 | 主路径 | 降级为「▶ 确定性流程」按钮 = 无 AI 兜底，也是 agent 的工具 |

### Added

- **`t2h:autoport_start` / `_status` / `_stop`（三处联动齐全）**：
  - `start`：准备现场（把 `t2h-ohos-port` 技能装进 `~/.cjh/skills`、往目标工程写 AGENTS.md 受管区块、
    把 cjh 工作区切到该工程、**算出 `lingqu-cli` 的绝对路径**）+ 生成任务书 → 返回 `{directive, cliPath, prep}`
  - `status`：纯读落档（`observeTaskStep` × 8）→ 进度/结论/**停滞判定**（连续 6 次快照一样 → 提示绕圈）
  - `stop`：收监管状态（页面同时发 WS `abort` 真打断模型回合）
- **任务书 `buildAutoPortDirective`（纯函数 + 单测）**：明确"你是执行者不是顾问"、可复制的工具命令行、
  "判断只认落档"、工作循环（同错最多 2 种修法）、纪律（平台限制不算失败 / 未验证不算通过）、
  预算（轮次 + 分钟）、收尾三段式、要人拍板的用 `lingqu-decision` 块
- **界面改成 AI 优先**：屏名「AI 自动迁移」，主按钮 `🤖 开始 AI 自动迁移`，其次是「▶ 确定性流程」（原一键迁移）
  与「继续」（AI 回合停了但没迁完时让它接着干）；时间轴读的是**落档**，不是我们自己的执行进度
- `ui_report` 新增 `aiPortActive/aiPortPolls/aiPortStalled/aiPortVerdict/aiPortDirective/aiPortCli`
- `docs/上游回馈-cjh.md`：5 条可直接提 issue 的 cjh 能力缺口（见下）

### Fixed

- **任务书里的工具路径是相对路径**（首次实跑暴露）：`cli\target\release\bin\main.exe` 在 agent 的
  bash 里（cwd = 目标工程）根本不存在 → 现在 `resolveCliExe()` 一定返回**绝对路径**
- 任务书发送顺序：`autoport_start` 会切 cjh 的 workspace（重置其持久 bash 会话），
  **必须先 `new_session` 再发任务书**，否则消息进了旧会话

### 未打通 / 未验证（如实记录，下一步第一件事）

- ⛔ **任务书没能送进 cjh 的对话回合**：三次实跑都是 `frames=1（history_messages）`、`toolCards=0`，
  cjh 新会话文件里只有一条 system 消息（158 B）——`new_session` 到达了、`chat` 帧没被处理。
  落档因此没变化（`aiPortPolls=17`、`aiPortStalled=true`），**AI 一次工具都没调起来**。
  根因未定位到行；已按用户授权把「cjh 没有 REST 对话入口（只有 `/ws`）」记成上游缺口 #2
- ⛔ 因此本轮**没有任何"AI 自主完成迁移"的实跑证据**。已通的只有：现场准备（技能 8639 B 已装、
  工程 AGENTS.md 已写、工作区已切）、任务书生成（4433 字）、绝对路径、停滞判定、时间轴读落档

## [0.36.0] - 2026-11-01

**主题**：**从"AI 副驾"到"AI 干活"** —— ① 一键迁移（一个按钮跑完 8 步）、
② 失败自动问 AI（现场由落档拼成提问正文）、③ 只读命令自动执行、④ 决策块回写 decisions.json。
本轮先回答了一个尖锐的问题：「当前这些工具、命令或技能，有主动调用 agent 吗？」答案是**没有**——
cjh 只被用于生命周期与配置，迁移八步一次模型都不问，AI 只是"人叫才动"的聊天窗。0.36.0 开始接闭环。

### Added

- **一键迁移 `t2h:migrate` / `t2h:migrate_status` / `t2h:migrate_cancel`（三处联动齐全）**

  | 环节 | 做法 |
  |---|---|
  | 跑在哪 | `t2h:migrate` 只起**后台线程**并立即返回（一次迁移以分钟计，堵住 IPC 就连进度都读不到）；页面 900ms 轮询 `t2h:migrate_status` |
  | 判定 | 每步跑完都 `observeTaskStep` **读盘上的落档**，不信命令返回值的乐观字段（存在 ≠ 成功，§4-63） |
  | 步骤 | scan → deps → port(apply) → build → hap → sign(体检→必要时写回) → deploy → verify → 出报告 |
  | 跳过 | 没插设备 / 签名是 release 态 → deploy+verify **跳过并写明原因**，不算失败 |
  | 失败 | 就地停下，用 `migrateAskPrompt`（复用 G1/G2 模板）拼好提问正文交给 AI |
  | 结果 | 结果卡 Markdown + `.lingqu/migrate/<工程>.md` + 三段式报告 `.lingqu/report/<工程>.{md,html}` |

- **新屏「⚡ 一键迁移」**（左栏第一项、默认屏）+ 顶栏按钮：路径框、`自动应用代码改造`（留 `.bak` 可回滚）、
  进度条、8 步时间轴（待跑/进行中/通过/未过/跳过 五态）、结果卡（`renderMd` 渲染，含报告路径）
- **`lingqu-cli migrate --path <工程>`**：命令行一条命令跑完整条链（内部强制 `--wait`，
  跑到出结果才返回，直接打印结果 JSON/Markdown）——这是 agent 能真正"干完所有的活"的入口
- **`t2h:ai_brief`（G1+G2）**：`{path, step}` → 把该步的**落档正文（截断 3000 字）+ 日志尾 40 行 +
  该步判据**拼成提问正文。判定权在后端（`observeTaskStep`），**没跑过（落档不存在）不算失败**、
  不打扰模型；`force` 仅供界面探针
- **`t2h:ai_decide`（G4）**：从 AI 回复里抽 `lingqu-decision` 围栏块 → 确认卡（采纳/忽略）→
  人点一下才落 `.lingqu/port/<工程>/decisions.json`，`source=ai` 标出"AI 提案、人确认"
- 前端两个开关（localStorage 记住）：`失败自动问 AI`（默认开）、`自动跑只读命令`（默认关）
- `cliAutoRunAllowed`（纯函数 + 单测）：自动执行的**更严一层**白名单
  （`scan/deps/sign/verify/report/batch/resume/env/diagnose`），`build/hap/port/revert/deploy/migrate` 一律不自动跑
- `t2h:cli_run` 新增 `preflight`（只回答能不能跑、不执行）与 `auto`（是否在自动白名单）
- 纯函数层：`src/agent_prompt.cj`（`tailLinesOf` / `clipCharsOf`（按字符切，不切坏汉字）/
  `stepAskCaveat` 八步判据 / `buildAutoAskPrompt` / `parseDecisionBlocks`）、
  `src/migrate.cj`（步骤编排、`MigrateState` 深拷贝快照、`migrateVerdict` 四态、
  `migrateResultMarkdown`、`migrateAskPrompt`）
- `ui_report` 新增：`autoDiag*/autoRun*/decide*/migrate*` 共 15 个字段（页面 + 后端白名单两处一起加）
- 技能与工程上下文同步写进两个新约定（建议命令一行一条、`lingqu-decision` 决策块格式），
  否则模型不会产出界面能解析的东西

### Fixed

- **写错返回值语法时编译器指错位置**：`func f(...) -> T` 少写冒号会把错误报到**下一个**函数声明
  （`body of function 'X' is missing` / `found '->'`），照报错位置改永远改不对（§4-67）
- **`t2h:port` 的 `apply` 在新工程上必失败**（0.11.0 起潜伏）：`ensurePortDirs()` 只建到
  `.lingqu/port`，逐文件备份目录 `.lingqu/port/<工程>/` 要等 `t2h:decisions` 记过决策才碰巧存在 →
  第一次「应用改造」抛 `The input path 'parent' … does not exist`、`ok=false`。现在 apply 前自建
- 一键迁移结果卡写不进去：把**文件**路径传给了 `ensureDirOf`（它按目录逐段建）→ 先建 `.lingqu/migrate`
- 「规则改造」在已迁移工程上显示**未跑**：port 的落档是可选的（没东西可改就不写 decisions.json /
  不留 .bak）。改为"命令 ok 且落档不存在 → 通过（幂等）"
- deploy 摘要把最有用的那句丢了：只写"启 失败"，看不出为什么。抽纯函数 `deployNoteOf`
  在失败时带上 `start.detail` 的处置提示（真机实测：设备锁屏 `10106102`），且不叠 `｜｜`

### 证据（本机 Windows x64，2026-11-01）

```
门禁：五道闸全绿 build-biz:PASS test:PASS(TOTAL=226) check:PASS build-app:PASS build-cli:PASS

① 一键迁移真机实跑（`lingqu-cli migrate --path E:\test\rust\habit-tree --wait`，约 60 秒）：
   扫描分析｜通过｜单元 R=24 / D=24 / U=0 / 评分 63 / 阻塞 1 项
   依赖评估｜通过｜依赖 453 包 / 需 patch 0 / 不可用 10
   规则改造｜通过｜已应用改造（有备份，未记人工决策）
   交叉编译｜通过｜exit=0 / 错误 0 / 前端指纹 一致 0、过期 0、缺 0
   HAP 装配｜通过｜HAP 7249833 字节 / arm64 库条目 3 个 / rawfile 0 个死资源
   签名体检｜通过｜签名态 debug（开发直装）｜profile 绑定了本机 UDID，可直装
   真机部署｜未过｜装 成功 / 启 失败｜处置：设备在锁屏，拒绝自动解锁 → 解锁后重试（FP-014）
   → percent=87，结论「停在真机部署」；报告 .lingqu/report/habit-tree.{md,html}；
     结果卡 .lingqu/migrate/habit-tree.md；askPrompt 已拼好（含落档 + 日志尾 40 行 + 判据）

② 新屏无 JS 错误（`LINGQU_UI_PROBE=1` 实机）：
   ui_report：screens=8 activeScreen=migrate migrateRows=8 autoDiag=true autoRun=false
              gridColumns=240px 652px 372px wsState=connected frames=3 mdOk=true errorCount=0
   同一次运行的断点板：resumeDone=7 resumeFailed=1 resumePercent=87 resumeNext=deploy
   —— 与一键迁移的 percent=87 /「停在真机部署」逐字一致（两条链路读同一份落档）
```

## [0.35.0] - 2026-11-01

**主题**：**AI 接入第 4 步 —— 一键执行 + 结果回填**：AI 回复里出现的 `lingqu-cli …` 建议
直接变成可点按钮；点一下真跑，结果卡回填对话，还能一键「让 AI 分析结果」。**闭环成立**。

### Added

- **命令 `t2h:cli_run`**（三处联动齐全）：`{cmd, flags}` → 组装 argv → 复用 `dispatchCli`
  （与 CLI/界面**同一份实现**）→ 回 `{ok, allowed, reason, exitCode, result}`
- **安全边界 `cliRunAllowed`（纯函数 + 单测）**——误点一个按钮不该能把工程改坏：

  | 放开（只读/幂等可回滚） | 拒绝（并告诉人该去哪个界面点） |
  |---|---|
  | `scan` `deps` `resume` `report` `verify` `env` `diagnose` `batch` `build` | `deploy`（动真机）→ ⑥ 屏「安装并启动」 |
  | `sign`（体检）| `sign --apply`（改用户工程）→ ⑤ 屏「写回签名配置」 |
  | `skill` / `agent_context`（status/install，幂等且可移除） | `port`（改源码）→ ④ 屏；`revert` → ④ 屏；`hap`（耗时+产物）→ ⑤ 屏；`decisions` → ④ 屏 |

- 前端：`cliSuggestParseInPage` 从回复里抽建议（列表符号/行内码/去重）→ 挂一排「▶ 命令」按钮
  → 点击后结果卡（退出码 + 摘要 + JSON 预览 + **「让 AI 分析结果」**按钮，点它才发消息，
  不悄悄多花一次模型调用）
- `ui_report` 新增 `cliSuggest/cliSuggestRows/cliLastCmd/cliLastExit/cliLastOk/cliRan/cliBlocked/cliResultCards`
- 探针 `LINGQU_UI_PROBE=cli`（点一次允许的命令）与 `cli-block`（点一条会被拦下的命令）

### 证据（本机 Windows x64，2026-11-01）

```
① 允许路径 LINGQU_UI_PROBE=cli（确定性注入一条 `lingqu-cli resume --path …` 建议再点它）：
   ui_report：cliSuggest=1 cliSuggestRows=1 cliLastCmd=resume cliLastExit=0 cliLastOk=true
              cliRan=1 cliBlocked=0 cliResultCards=1 errorCount=0
② 拦截路径 LINGQU_UI_PROBE=cli-block（注入 `lingqu-cli deploy --path …` 再点）：
   ui_report：cliLastCmd=deploy cliLastExit=-2 cliLastOk=false cliBlocked=1 cliResultCards=1 errorCount=0
   → 界面显示「⚠ 这条命令要在界面里点：真机部署会安装并启动应用，请在 ⑥ 屏点「安装并启动」」
门禁：五道闸全绿（build 0 warning / TOTAL=201 / check / 骨架 build / cli build）
```

### 未做（如实）

- 「让 AI 分析结果」是**手动点**（避免每条建议都自动多一轮模型调用）；自动回填留作可选项
- 建议解析只认 `lingqu-cli <cmd>` 开头（不猜 `t2h:` 或自然语言里的命令名）
- ④ 之后 AI 接入四步全部就绪；P7 的 5 样本推进仍未做

---

## [0.34.0] - 2026-11-01

**主题**：**AI 接入第 3 步 —— `t2h:*` CLI 化**：新增 `lingqu-cli` 可执行文件，让 **agent 的 bash
能把工具真跑起来**（此前只有应用内 IPC 入口，AI 只能"讲"不能"做"）。

### Added

- **`cli/` 目标**（独立可执行 `lingqu-cli`，产物 `cli/target/release/bin/main.exe`，分发时改名即可）：
  `scan / deps / port / revert / decisions / diagnose / build / hap / sign / deploy / verify /
  report / batch / resume / skill / agent_context / env`
- `src/cli.cj`（业务包内，可单测）：
  - `argvToJson` / `argvToJsonWithValues`：`--k v` 与 `--k=v` 两种形态都认；布尔开关（`verifyOnly`
    等）不带值算 true；**纯命令（不带开关）也会占位**——否则会报"不认识的命令："
  - `cliCommandSupported` / `cliHasCommand` / `cliUsage`：白名单 + 用法（GUI 专属 `quit`/`cjh_*` 不开放）
  - `dispatchCli`：**零重构复用** `CommandHandler`——`XxxCommand().handle(name, args, IpcContext("cli", IpcHub()))`，
    所以 CLI 与界面按钮是**同一份实现**，不会出现"CLI 能跑、界面报错"
- 门禁从 **4 道 → 5 道**：新增 ⑤ `cli cjpm build`（零警告）
- `cli/README.md`（命令表 / 退出码 / 运行环境 / 已知限制）
- 技能正文与 `AGENTS.md` 受管区块都改成**能真跑的命令**（`lingqu-cli scan --path .` 等），
  并写明"先 `resume` 看停在哪步，再跑那一步"

### 证据（本机 Windows x64，2026-11-01）

```
门禁：build-biz:PASS test:PASS(TOTAL=198) check:PASS build-app:PASS build-cli:PASS
--list：列出 17 个命令（用法 + 退出码说明）
resume --path E:\test\rust\habit-tree → exit=0，JSON 4498 B
   {"ok":true,"project":"habit-tree","next":"port",
    "hint":"下一步是「规则改造」——从这一步接着做（前 6 步已有落档证据）"}
scan --path E:\test\rust\habit-tree（在空目录里跑）→ exit=0
   {"ok":true,"out":".lingqu/scan/habit-tree.json","R":24,"C1":100,…}
   → 落档真的写在**当前目录**：.lingqu/scan/habit-tree.json 10113 B
坏命令 nosuchcmd → exit=1，stderr 给出"不认识的命令：nosuchcmd"
```

> 关键点：`scan` 是在一个**空目录**里跑的，落档落在那个目录的 `.lingqu/` ——
> 这正是 agent 需要的行为（它在用户工程目录里跑，产物就该进用户工程）。

### 未做（如实）

- `lingqu-cli.exe` 的名字要打包/分发时改（cjpm 产物固定叫 `main.exe`）；尚未加进 `packaging/`
- cjh 技能 frontmatter 的 `tools:`（声明式工具）**硬编码 `/bin/bash -c`**，Windows 上用不了
  （上游 `registry.cj` 实现），所以本项目让 agent 用它的 bash 工具（Windows 上自动选 Git Bash）调 CLI；
  这条已记进 `cli/README.md` 与进度记录，作为上游回馈项
- ④（AI 建议命令的一键执行 + 结果回填）未开工

---

## [0.33.0] - 2026-11-01

**主题**：**AI 接入第 2 步 —— 工程上下文**：让 agent 的 bash/文件工具真正落到用户的工程上，
并把「工具链 + 落档位置 + 口径」写进工程的 `AGENTS.md`（cjh 会自动注入 system prompt）。

### Added

- **命令 `t2h:agent_context`**（三处联动齐全）：`status` / `install` / `remove`
  - `install`：往目标工程写 `AGENTS.md` **受管区块** + `POST /api/workspaces/switch`
    把 cjh 的 workspace 切到该工程（cjh 会 chdir **并重置持久 bash 会话**）
  - `remove`：只删灵渠那块，用户原有内容保留；文件因此变空时直接删文件
- `src/agent_context.cj`：
  - 纯函数：`agentContextPathOf` / `agentContextBody`（落档清单 + 工具清单 + 五条口径）/
    `hasAgentBlock` / `injectAgentBlock`（**幂等**）/ `removeAgentBlock`（**可撤销**）
  - IO：`cjhSwitchWorkspace`（POST 切工作区）/ `cjhCurrentWorkspace`（GET 回读）
- ① 屏「工程上下文（AGENTS.md）」卡：受管区块状态 / cjh 工作区 / 「查状态」「装上下文」「移除区块」
- `ui_report` 新增 `agentHasBlock/agentPath/agentSwitched/agentWorkspace/agentError`；
  探针 `LINGQU_AGENT=install|status|remove` + `LINGQU_AGENT_PATH`

### 为什么这样做（用户拍板）

| 方案 | 取舍 |
|---|---|
| 只写 AGENTS.md 不切 workspace | ❌ 只做一半：agent 的 bash 还在灵渠目录，知识再全也落不到工程上 |
| 只切 workspace 不写内容 | ❌ agent 不知道有哪些工具、落档在哪、口径是什么 |
| **切 workspace + 受管区块 AGENTS.md** | ✅ 本轮采纳：cjh 原生机制（AGENTS.md 自动注入 + workspace chdir） |
| 改 cjh 全局 `systemPrompt` | ⏸ 仅作兜底：全局单值、切换工程要重写、别的客户端用不到 |

### 证据（本机 Windows x64，2026-11-01，临时工程 `.lingqu/tmp-agent/demo-app`）

```
造一个"用户已有自己的 AGENTS.md"的工程（4 行用户内容）：
LINGQU_AGENT=install LINGQU_AGENT_PATH=<tmp> →
  ui_report：agentHasBlock=true agentSwitched=true
             agentWorkspace=E:\...\.lingqu\tmp-agent\demo-app agentError="" errorCount=0
  AGENTS.md：用户原有 4 行**原样保留**，其后追加
             <!-- lingqu:begin … --> 区块 + 落档表 + 工具清单 + 五条口径 <!-- lingqu:end -->
LINGQU_AGENT=remove →
  ui_report：agentHasBlock=false errorCount=0
  AGENTS.md 回到用户原来那 4 行（灵渠区块整段消失）
```

> `agentSwitched=true` 来自 cjh 的 `POST /api/workspaces/switch` 回执；`agentWorkspace` 是紧接着
> `GET /api/workspaces` 回读的最近工作区——**不是"我们以为切了"**。

### 未做（如实）

- 装完上下文后 **cjh 的 system prompt 不会自动刷新**（它在会话开始时装配）——界面提示"新建一次会话"；
  真正自动刷新需要 cjh 侧支持，属上游改造
- 没做"按工程自动切 workspace"（目前要用户点一下）；③ 的工具 CLI 化之后再串成一条链
- ③（`t2h:*` CLI 化）与 ④（一键执行闭环）未开工

---

## [0.32.0] - 2026-11-01

**主题**：**AI 接入第 1 步 —— 把 `t2h-ohos-port` 技能真正装进 cjh**。
在此之前 `skills/t2h-ohos-port/` 只是躺在仓库里，cjh 从未见过它：AI 助手对鸿蒙移植的坑、
签名配方、工具链差异一无所知（只能靠模型自己的通用知识）。

### Added

- **命令 `t2h:skill`**（三处联动齐全，五个动作里本轮做两个）：
  - `status`：安装状态（missing / installed / outdated，按**内容 SHA256**判，不看时间戳）
    + `enabled_skills` 白名单语义 + references 份数 + **问 cjh `GET /api/skills` 是否真的加载了**
  - `install`：把 SKILL.md 写到 `~/.cjh/skills/t2h-ohos-port.md`，references 拷到
    `~/.cjh/skills/.t2h-ohos-port/references/`；覆盖前留 `.bak`；幂等
- `src/skill_install.cj`（`lingqu` 包）：
  - 纯函数：`cjhSkillsDirOf/skillTargetPathOf/skillRefDirOf`（路径约定）、
    `rewriteSkillLinks`（把 `references/x.md` 改成**绝对路径**——agent 的 cwd 是用户工程，
    相对路径必然读不到）、`skillStateOf`（三态）、`skillEnableNoteOf`（白名单语义，
    **空=全部启用，不要乱加白名单**——加了会把别的技能关掉）、`skillSourceCandidates`（向上找仓库）
  - 有 IO：`skillSourceDir`（`LINGQU_SKILL_SRC` → `LINGQU_HOME/skills` → cwd 上溯 6 层）、
    `skillFinalBodyOf`（**安装与期望哈希共用同一条生成路径**）、`installSkill`、`cjhSkillNames`
- ① 屏「AI 迁移技能」卡：安装状态 / cjh 已加载 / references 份数 / 来源 + 「查状态」「安装技能」
- `ui_report` 新增 `skillState/skillPath/skillRefs/skillCjhSeen/skillCjhCount/skillSource/skillNote`；
  探针 `LINGQU_SKILL=install|status`
- `src/packed_assets.cj` 增 `PACKED_SKILL_B64` 存根（单文件产物里没有 `skills/` 目录时用内嵌正文）

### 口径

| 判据 | 怎么判 | 为什么 |
|---|---|---|
| 装了没 | 目标文件存在 + **内容哈希**比对来源 | 时间戳会被 checkout/复制骗过 |
| 生效没 | **问 cjh `/api/skills` 里有没有它** | 装到磁盘 ≠ cjh 加载了（frontmatter 坏了/白名单关了都不可见） |
| 白名单 | 空 = 全部启用；非空才提示"要不要加进去" | 乱加一项会把 cjh 自带的仓颉知识技能一起关掉 |

### 证据（本机 Windows x64，2026-11-01）

```
装前：~/.cjh/skills 不存在
LINGQU_SKILL=install →
  ~/.cjh/skills/t2h-ohos-port.md                       5829 B
  ~/.cjh/skills/.t2h-ohos-port/references/{arkweb-shims,cargo-patches,pitfalls,signing,toolchain}.md
                                                      4668 / 5184 / 5467 / 9652 / 3267 B
  ui_report：skillState=installed skillRefs=5 skillSource=repo
             skillCjhSeen=true skillCjhCount=1 errorCount=0
技能里的相对链接已改写为绝对路径：
  [signing.md](C:\Users\yang\.cjh\skills\.t2h-ohos-port\references/signing.md)
```

> `skillCjhSeen=true` 是本轮最关键的证据：cjh 自己的 `/api/skills` 列出了这个技能，
> 说明它**已经进入 system prompt 的注入范围**，不是"文件在那儿"而已。

### 未做（如实）

- 单文件产物里目前只能装**内嵌正文**（`PACKED_SKILL_B64` 存根还没被打包脚本填充，下一轮补）；
  references 要 `LINGQU_SKILL_SRC` 指到仓库才拷得到
- 「一键移除/卸载技能」没做；白名单写入（`POST /api/settings`）没做——当前机器 `enabled_skills`
  为空（= 全部启用），不需要写配置，需要时再补
- ① 之后的 ②③④ 见 `docs/进度记录.md` 的 AI 接入计划

---

## [0.31.0] - 2026-11-01

**主题**：**代码块语法高亮 + AI 回复平铺展开**。0.30.0 把 Markdown 渲染补上了；
这一轮补齐两块：① 代码块从"等宽纯文本"升级为 hljs 高亮；② 用户裁定"回复正文铺满整栏"，
assistant 消息去掉头像栏与气泡框，正文从聊天区左边缘起排。

### Added

- **highlight.js v11.9.0 整份内联**（BSD-3-Clause，取自 `cj-tauri/examples/ai-chat` 的
  `ui/vendor/highlight.min.js`）：页面要被打进单文件 exe（`pack-win-single` 只内联
  `ui/index.html`），外部 `<script src>` 在单文件产物里会 404，所以必须内联。
  更新方式写在插入处的注释里（拿 ai-chat 那份整段替换）
- 代码块高亮：带语言标注按语言、否则 `highlightAuto`；**库缺失/未知语言/词法异常一律退化为
  `escHtml`**——高亮失败不能把整条回复弄挂
- 配色不引 vendor 主题：关键字紫 / 字符串橙 / 数字·内建青 / 函数名蓝 / 注释灰（`.hljs-*` 类名由库生成）
- 页内自检从 12 条 → **16 条**（新增 `hl-keyword` / `hl-string` / `hl-comment` / `hl-unknown-lang`）
- `ui_report` 新增 `mdHljs`（版面里被切成词法 span 的数量）与右栏版面量尺：
  `aiDockW / aiBubbleW / aiBubbleGap / aiInnerLeft / aiFlatLeft / aiAvatars / aiAvatarsShown / aiLastHtml`

### Changed（版面：平铺展开，用户裁定 A）

- `.msg:not(.me)`：头像栏隐藏、气泡框（背景/边框/内边距/圆角）全部去掉，正文贴聊天区左边缘；
  **用户自己发的消息仍保留气泡**（"我说的话"要和"AI 说的话"一眼区分）
- Markdown 表格 `width:100%`：能放下时撑满整栏，放不下时外层 `.tbl` 横向滚动

### 证据（本机 Windows x64，`LINGQU_UI_PROBE=md`，cjh 真实回复）

```
渲染：mdOk=true mdFail=""（16 条自检全过，含 4 条高亮）
      mdBlocks=4（h2 + ol + table + pre）  mdCodeCopy=1（复制按钮）  mdHljs=6（代码块里 6 段词法）
版面：aiDockW=372 aiBubbleW=299→333（多给内容 34px） aiBubbleGap=24
      aiFlatLeft=14（= 聊天区 padding，回复贴左边缘；改前是 14+25+9=48）
      aiAvatarsShown=0（头像栏已隐藏，DOM 里仍有 5 个节点但宽度为 0）
      errorCount=0 tag=probe-done
```

### 未做（如实）

- 用户自己的消息不渲染 Markdown（保持纯文本，避免"我打的星号被吃掉"）
- 高亮只影响代码块；行内 `code` 按统一配色，不做语言识别
- 内联 hljs 让 `ui/index.html` 从 ~187 KB 涨到 ~310 KB（单文件 exe 里可忽略；dev 加载同样走同一份）

---

## [0.30.0] - 2026-11-01

**主题**：**AI 回复的 Markdown 渲染**——气泡一直是 `textContent = acc` 塞纯文本，
模型输出的标题/列表/表格/代码块全被压平（表格变成一串带竖线的句子），"看起来不像个界面"。
本轮对齐 `cj-tauri/examples/ai-chat` 的 `renderMd`，把渲染补上。

### Added

- **`renderMd(src)`**（`assets/ui/index.html`，移植自 ai-chat 并减少差异）：
  - 块级：代码围栏（带语言标注）、`#`~`######` 标题、`---` 分隔线、`>` 引用、无序/有序列表、
    **表格**（外层 `.tbl` 横向可滚）、段落
  - 行内：行内码、粗体、斜体、删除线、链接（**只放行 http/https**，其余只留文字）
  - 顺序固定：**先摘代码块 → 再整体转义 → 只认受控标记**（模型输出是外部内容，
    先转义 `<` `>` `&` `"`，之后加的都是我们自己生成的标签）
- 代码块**复制按钮**（`MD_CODES` 里存原文，复制源码而不是高亮后的 HTML），事件委托绑在聊天容器上
- Markdown 排版 CSS（标题/列表/表格/代码块/引用/分隔线/链接 + 流式光标 `.md-cur`）
- 流式与收尾都走 renderMd：`flushStream` 追加光标块，`finishTurn` 出完整版
- **页内自检 + 版面证据**：`mdSelfCheck()` 12 条断言（转义/粗体/行内码/代码块/标题/列表/有序表/
  表格/引用/链接白名单/非字符串容错），结果回投 `ui_report` 的 `mdOk/mdFail`；
  另加 `mdBlocks`（版面里真正渲染出的块级元素数）与 `mdCodeCopy`（复制按钮数）
- 探针 `LINGQU_UI_PROBE=md`：让模型用 markdown 回「标题 + 有序列表 + 表格 + 代码块」，
  这样版面证据不依赖人肉看截图

### 与 ai-chat 的差异（有意为之）

ai-chat 的 vendor 里内联了 highlight.js（122 KB）做语法高亮；本项目页面要编进单文件 exe，
本轮**只做 Markdown**（代码块保留等宽 + 复制按钮），语法高亮留作可选后续——
要加的话是"内联成熟库"，不是自己写 tokenizer（ai-chat 的注释里也是这个结论）。

### 证据（本机 Windows x64，2026-11-01）

```
LINGQU_UI_PROBE=md（cjh 真实回复，原文含 ## 标题 / 有序列表 / 表格 / ```bash 代码块）
ui_report：mdOk=true  mdFail=""（12 条页内自检全过）
           mdBlocks=4（h2 + ol + table + pre 各一，确实渲染成了元素而不是文本）
           mdCodeCopy=1（代码块复制按钮已渲染）
           frames=68 lastFrameType=done errorCount=0 tag=probe-done
```

> 对照：渲染前同一条回复在气泡里是 `## 构建步骤 1. … | 命令 | 作用 | …` 一整坨纯文本。

### 未做（如实）

- 语法高亮（highlight.js）未引入：见上面的取舍；要加就是内联 vendor（约 122 KB）
- 用户自己发的消息仍是纯文本转义（不回渲染 markdown）——避免"我打的星号被吃掉"
- 渲染只在 `assets/ui/index.html` 侧，未做单测：纯字符串函数靠页内自检 + `ui_report` 断言
  （渲染不在仓颉侧的纯函数层，无法进 `cjpm test`）

---

## [0.29.0] - 2026-11-01

**主题**：**P7 开工 —— T7-3 5 样本迁移矩阵**：把每个样本自己的落档并排成一张表
（评分 / 依赖 / 编译 / 装配 / 签名态 / 部署 / 可用率 / 8 步 / 人工介入 / 判定），
A1/A3/A4 三个验收指标在矩阵层有了直接读数。

### Added

- **命令 `t2h:batch`**（三处联动齐全）：`samples`（`路径1|路径2`，也认逗号）缺省时按
  `.lingqu` 下出现过的工程名收集 → 落 `.lingqu/batch/matrix.{md,html,json}`（`lingqu/batch/v1`）
- `src/batch/batch.cj`（纯函数层，`lingqu.batch`）：
  - `batchVerdict`（达标 ≥80 / 未达标 / **未验证**）、`batchCompletion`、
    `summarize`（样本数 / 已验证数 / 平均可用率 / 平均评分 / A3 人工介入 / A1·A4 判定）
  - `batchRowCells` + `batchHeaders`（12 列，表头与单元格共用一份口径）、
    `renderMatrixMarkdown` / `renderMatrixHtml`、`summaryLine`
- `src/batch_feed.cj`：逐样本读自己的落档汇总成一行（**只读盘**，不影响任何样本）
- ⑦ 屏新增「5 样本迁移矩阵」卡：样本路径输入 + 生成按钮 + 12 列横向滚动表 + 汇总与 A1/A4 判定
- `ui_report` 新增 `batchOk/batchSamples/batchVerified/batchAvgRate/batchAvgScore/batchHuman/`
  `batchA4/batchA1/batchHtml/batchRows/batchA4Rows`；探针 `LINGQU_BATCH_SAMPLES`
- `docs/5样本矩阵-实测.md`：把本机实测矩阵原样留档

### 口径（矩阵说错话比没有矩阵更糟）

| 情形 | 矩阵里怎么写 | 为什么 |
|---|---|---|
| 没有落档 | 该列写「未跑」，**不参与任何平均** | 未验证 ≠ 0 分（把没跑算成 0 会让平均凭空变低），也 ≠ 通过 |
| 跑了但没过 | 「未过」 | 与「未跑」必须分开——否则人分不清"还没做"和"做了不行" |
| 0 个已验证样本 | 平均可用率 `-1`（界面显示 `—`）、A4 判未达标 | "没验"不能算"通过" |

### 证据（本机 Windows x64，2026-11-01，5 个真实样本）

```
LINGQU_BATCH_SAMPLES=E:\test\rust\habit-tree|E:\test\rust\cc-switch-harmonyos|
                    E:\test\rust\m3u8dl-tauri|E:\test\rust\atomMqtt|E:\test\rust\tauri-mqtt-client-ohos
汇总：样本 5 个（已验证 1 个）｜平均评分 66｜平均可用率 60%｜人工介入 0 处（均 0.0 处/应用）

| 样本 | 评分 | 单元/未知 | 依赖 | 编译 | 装配 | 签名态 | 部署 | 可用率 | 8步 | 人工 | 判定 |
| habit-tree | 63 | 24 / 未知 0 | 430 包 / 不可用 10 | 未过 | 通过 | debug | 成功 | 60%（3/5） | 6/8（75%） | 0 | 未达标 |
| cc-switch-harmonyos | 58 | 320 / 未知 0 | 724 包 / 不可用 11 | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 2/8（25%） | 0 | 未验证 |
| m3u8dl-tauri | 77 | 11 / 未知 0 | 602 包 / 不可用 11 | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 2/8（25%） | 0 | 未验证 |
| atomMqtt | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 0/8（0%） | 0 | 未验证 |
| tauri-mqtt-client-ohos | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 0/8（0%） | 0 | 未验证 |

ui_report：batchOk=true batchSamples=5 batchVerified=1 batchAvgRate=60 batchAvgScore=66
           batchHuman=0 batchA4=false batchA1=false batchRows=5 errorCount=0
```

### 未做（如实）

- **A1 未达成（1/5 验证）**：cc-switch-harmonyos 与 m3u8dl-tauri 只跑了扫描 + 依赖，
  编译/装配/签名/部署/验证都没跑；atomMqtt 与 tauri-mqtt-client-ohos 一行落档都没有。
  下一轮按样本逐个推（每个样本的构建链以分钟计）
- 矩阵暂无"耗时"列（落档不记每步耗时，需改各命令 schema）；T7-4 基线实验与 T7-5 消融未开工

---

## [0.28.0] - 2026-11-01

**主题**：**T5-4 签名两态（debug / release）+ 上架前强提醒**——P5 的最后一块。
工具现在会明确告诉你"当前是哪一态、另一态怎么切"，而不是只在装机失败时给一句 9568322。

### Added

- `src/compiler/sign.cj` 新增两态纯函数层：
  - `judgeSignMode(hasConfig, profileType)` → `debug` / `release` / `unknown`；
    **判不出来就说 unknown，绝不猜 debug**（猜错会让人以为能装机）
  - `assessSignMode(...)` → `SignModeState`：当前态 + 能否直装 + 是否上架齐备 +
    **强提醒** + 双向下一步 + 切态步骤 + 本机 release profile 份数
  - `signModeReminder(mode)`：debug 态写明「只能装已注册设备，**不能上架**」；
    release 态写明「可以上架；真机直装被 9568322 拒是正常的」
  - `signReleaseSteps()` / `signDebugSteps()`：两个方向的可照做步骤清单
- `t2h:sign` 回投并落档 `mode` 段（`mode / modeLabel / canInstallDevice / releaseReady /
  reminder / installNextStep / releaseNextStep / releaseProfileCount / switchSteps`），
  日志增 `[mode]` 行
- ⑤ 屏签名卡：签名态 / 可直装 / 上架齐备三个指标 + 按态染色的提醒栏 + 切态步骤清单
- `ui_report` 新增 `signMode/signModeLabel/signReleaseReady/signReminder/signReleaseProfiles/signSwitchRows`
- 报告（`t2h:report`）：debug 态时「没做什么」写「签名是 debug 态：可直装真机，但**不能上架**」，
  「需要你做什么」原文引用强提醒 + 上架下一步
- 断点板（`t2h:resume`）：**release 态不再被算成"签名体检失败"**——它装不上真机是设计使然

### Changed

- 版本 0.27.0 → **0.28.0**；单测 **171 → 177**（`src/tests/sign_mode_test.cj` 5 例 +
  报告带签名的 1 例）

### 证据（本机 Windows x64 + 真机 HAD-W32 在线的 UDID 读取，2026-11-01，habit-tree）

```
LINGQU_SIGN_PATH=E:\test\rust\habit-tree
.lingqu/sign/habit-tree.json 的 mode 段：
  mode=debug  modeLabel="debug（开发直装）"  canInstallDevice=true  releaseReady=false
  releaseProfileCount=0
  reminder="⚠ 当前是 debug 签名：profile 绑定了本机 UDID，只能装到已注册设备，**不能上架**
            （AGC 不接受 debug 证书）。上架前必须切回 release profile 并重新签名。"
  releaseNextStep="上架前：本机还没有 release profile（~/.ohos/config 里 0 份），
                   先去 AGC 生成 release 证书与 profile，再按下面步骤切"
  switchSteps=5 条（生成 release 证书/profile → 放材料 → 改 build-profile.json5 →
                    重跑装配 HAP → 上传前再体检确认 mode=release）
ui_report：signMode=debug signModeLabel=debug（开发直装） signReleaseReady=false
           signReleaseProfiles=0 signSwitchRows=5 errorCount=0
报告（.lingqu/report/habit-tree.md）：
  没做什么：签名是 debug 态：可直装真机，但**不能上架**（AGC 不接受 debug 证书）
  需要你做什么：⚠ 当前是 debug 签名…（强提醒原文）+ 上架前：本机还没有 release profile…
           （reportDid=8 reportUndone=7 reportNeed=6，errorCount=0）
```

> 真机侧事实：`hdc shell bm get --udid` 读到本机 UDID、profile 含它 → debug 态判定可直装；
> `~/.ohos/config` 里 **0 份 release profile**，所以"切回 release"不是拨开关，要先做材料——
> 提醒里如实写了这一点（不做 release 签名的前提是**没有**华为 release 证书，本机确实没有）。

### 未做（如实）

- **release 态的实机判定未验证**：本机没有 release 材料，无法造出 release profile 来跑一遍
  `mode=release` 的真机路径（判定逻辑有单测覆盖 `assessSignMode(release)`，属"纯函数已验、
  真机未验"）。拿到 release 证书后需补一次真机实测
- 未做"一键切换 signingConfig"（要改工程文件且依赖 release 材料存在，风险高；本轮只给步骤与提醒）
- 上架除签名外还有隐私政策/图标/兼容 SDK 版本等非签名项，不在 T5-4 范围

---

## [0.27.0] - 2026-11-01

**主题**：**P6 收口 —— `t2h:report` 上线 + ⑦ 迁移报告屏接真数据**：三段式报告完全从落档推导，
MD / HTML / JSON 一键导出；⑦ 屏原来的假数据（"38 分钟 / 3 处人工介入 / 87% 可用率"）全部换成真实读数。

### Added

- **命令 `t2h:report`**（三处联动齐全）：读 `.lingqu` 下的落档 → 生成三段式报告
  → `.lingqu/report/<工程>.{md,html,json}`（`lingqu/report/v1`）。
  纯读盘：**不采证、不跑子进程、不改工程**，可以反复出。
- `src/report/report.cj`（纯函数层，`lingqu.report`）：
  - `buildReport`：8 步状态 + 可用率清单 + 决策 → 三段（做了什么 / 没做什么 / 需要你做什么）；
    没跑的写「还没跑」、没过的写「没过」、跳过的写「按人工判断跳过」——**三种状态不混**；
  - `stepActionHint`：每步对应界面上一个按钮（报告里的"需要你做什么"因此可执行、不是空话）；
  - `renderReportMarkdown` / `renderReportHtml`（自包含单文件）/ `escapeHtmlText`
    （按字节替换 5 个危险 ASCII，**中文原样保留**）；
  - `countHumanDecisions`（A3 口径：`accepted` 才算一次介入，`ignored` 只留痕）
- `src/report_feed.cj`：把落档汇总成 `MigrationFacts`（8 步走 `t2h:resume` 的同一套观测、
  清单三类判定分列、证据文件计数、附录只列**真实存在**的落档）
- **⑦ 屏接真数据**：四个指标（工程 / 8 步进度 / 人工介入 A3 / 可用率 A4）+ 三段卡片 +
  「生成迁移报告」「导出 Markdown / JSON / HTML」+ 证据索引（附录逐条列出落档路径）
- `ui_report` 新增 `reportOk/reportDid/reportUndone/reportNeed/reportRate/reportHuman/`
  `reportHtml/reportMd/reportConclusion/reportRows`；探针 `LINGQU_REPORT_PATH`

### Changed

- 版本 0.26.0 → **0.27.0**；单测 **165 → 171**（`src/tests/report_test.cj`，6 例）

### 口径（与 verify / task 一致，别改薄）

| 类别 | 报告里的位置 | 为什么 |
|---|---|---|
| 平台限制 | 没做什么（标注「不算失败」） | 鸿蒙没有托盘是能力位 0，不是工具失败；混进失败会让人误判 |
| 未验证 | 没做什么 + 需要你做什么（补验证） | 没证据就不算通过（A4 的分母口径） |
| 失败 | 没做什么 + 需要你做什么（重跑） | 失败要能一眼看到闸的第一条原因 |
| 人工跳过 | 没做什么（标注「按人工判断跳过」） | 跳过是人的结论，但它不是通过 |

### 证据（本机 Windows x64，2026-11-01，habit-tree）

```
启动参数：LINGQU_REPORT_PATH=E:\test\rust\habit-tree  LINGQU_UI_SCREEN=report  LINGQU_UI_PROBE=1
产物：.lingqu/report/habit-tree.md (2804 B) / .html (3796 B) / .json (3912 B)
结论：habit-tree：8 步完成 5/8（62%），核心功能可用率 60%，0 处人工介入
做了什么（7 条）：扫描 R=24… / 依赖 430 包… / HAP 7249837 字节… / 部署装启成功 hilog 40 行 /
                验证可用率 60% / 采集到 2 份真机证据 / 功能清单通过 3/5 项
没做什么（7 条）：「规则改造」还没跑 /「交叉编译」没过：…闸未过：.so 内嵌的 1 个前端产物在 dist/
                里已不存在 /「签名体检」还没跑 / 平台限制（不算失败）1 项 / 未验证 2 项 / 无人工决策记录
需要你做什么（5 条）：三条步骤动作（各对应界面按钮）+ 两条补验证
ui_report：reportOk=true reportDid=7 reportUndone=7 reportNeed=5 reportRate=60 reportHuman=0
           reportRows=19 errorCount=0 activeScreen=report
```

### 未做（如实）

- 报告里没有"总耗时"这一项——落档目前不记每步耗时（要改各命令的落档 schema，单独一轮做）；
  ⑦ 屏因此也去掉了原来的"38 分钟"假数字，而不是编一个
- 报告未做「打开文件」按钮（跨平台 opener 涉及启动外部进程，本轮不动）；路径已给全，可自行打开
- T5-4 release 签名两态、P7 5 样本矩阵仍未开工

---

## [0.26.0] - 2026-11-01

**主题**：**T6-5 断点续迁**——8 步迁移链的进度变成盘上可查的证据（`.lingqu/tasks.json`），
关掉应用、隔天回来能接着做；④ 屏的占位步骤条换成真数据。

### Added

- **命令 `t2h:resume`**（三处联动齐全）：
  - `status`（默认）：读 `.lingqu/{scan,deps,port,build,hap,sign,deploy,verify}/<工程>.json`
    → 归约成 8 步状态 → 落 `.lingqu/tasks.json`（`lingqu/tasks/v1`）
  - `mark`：人工覆盖一步（agent 应用补丁后记 `done`；判定做不了记 `skipped`，断点会越过它）
  - `redo`：从某步重来（该步及之后回 `pending`，落档不动）
  - `reset`：整块回 `pending`（**不删落档**，证据不该被断点操作毁掉）
  - `session`：记 cjh 会话 id → 重开应用后页面据此 `resume_session`，**agent 会话一起续**
- `src/task.cj`（纯函数层）：`TASK_STEPS` 步骤表、`normalizeTaskStatus`、
  `reconcileStepStatus`、`firstUnfinished`、`taskProgress`、`resumeHint`、
  `markTaskStep` / `redoFromStep`、`parseTaskBoard`（容错）/ `TaskBoard.toJson`
- `src/task_feed.cj`（观测层）：`observeTaskStep` 读各步落档 → `exists / ok / 一句话摘要`，
  `collectTaskBoard` / `saveTaskBoard`（写前留 `.bak`）
- ④ 屏「断点续迁 · 8 步状态机」卡（**替换原占位步骤条**）：完成/失败/跳过/进度/下一步五个指标、
  逐步行（勾选 / 步骤名 + 落档证据 / 判定 + 「从这步重来」）、「刷新断点」按钮
- `ui_report` 新增 `resumeOk/resumeNext/resumeDone/resumeFailed/resumeSkipped/resumeTotal/`
  `resumePercent/resumeHint/resumeSession` + 版面指标 `resumeRows/resumeRowH`；
  探针 `LINGQU_RESUME_PATH`

### Changed

- 版本 0.25.0 → **0.26.0**；单测 **156 → 165**（`src/tests/task_test.cj`，9 例）

### 口径（与 `t2h:verify` 一致，别改薄）

| 情形 | 判定 | 为什么 |
|---|---|---|
| 落档不存在 | `pending`（没跑过） | "上次好像跑过"不可信，盘上没有就是没跑 |
| 落档存在但判定没过 | `failed` | **存在 ≠ 成功**（0.24.0 的 verify 也是这条口径） |
| 人工 `skipped` | 保留，断点越过它 | 跳过是人的结论，但它不是"通过"，进度里单列 |

### 证据（本机 Windows x64，2026-11-01，habit-tree）

```
启动参数：LINGQU_RESUME_PATH=E:\test\rust\habit-tree  LINGQU_UI_SCREEN=port  LINGQU_UI_PROBE=1
.lingqu/tasks.json（lingqu/tasks/v1）：
  project=habit-tree  next=port  done=5  failed=1  skipped=0  total=8  percent=62
  hint="下一步是「规则改造」——从这一步接着做（前 5 步已有落档证据）"
  sessionId=s1793421167.504.1（页面在帧里收到会话 id 后由 t2h:resume action=session 落盘）
  scan    done    单元 R=24 / D=24 / U=0 / 评分 63 / 阻塞 1 项
  deps    done    依赖 430 包 / 需 patch 9 / 不可用 10
  port    pending .lingqu/port/habit-tree/decisions.json（没有落档 → 没跑过，不猜）
  build   failed  exit=0 / 错误 0 / 前端指纹 一致 2、过期 1、缺 0｜闸未过：.so 内嵌的
                  1 个前端产物在 dist/ 里已不存在——改了前端没重编 .so
  hap     done    HAP 7249837 字节 / arm64 库条目 3 个 / rawfile 0 个死资源
  sign    pending 该工程没有签名落档（只有 lingqu-apply-demo 那份）
  deploy  done    装 成功 / 启 成功 / hilog 40 行（健康）
  verify  done    可用率 60%（通过 3/6，平台限制 1）
ui_report（④ 屏断点板）：resumeOk=true resumeNext=port resumeDone=5 resumeFailed=1
  resumeTotal=8 resumePercent=62 resumeRows=8 resumeRowH=37 resumeSession=s1793421167.504.1
  errorCount=0 tag=probe-done
  → 8 行**单行**渲染（37px/行，与 verify 清单同一套排版纪律），会话 id 与 tasks.json 一致
```

> 注意 `build=failed` 是**真实状态**：`exit=0` 且错误 0，但前端指纹闸没过（`.so` 里还留着
> `index-BbUz51cz.css`，dist 已经换成新的）——这正是 0.20.0 白屏问题的指纹形态。
> 断点因此停在更前面的 `port`（改造还没跑），而不是自欺地报"编译通过"。

### 未做（如实）

- `t2h:report` 命令面（报告文件 0.24.0 已由 `t2h:verify` 产出 `.lingqu/verify/<工程>.{md,html}`，
  缺的是"单独出报告"的命令与 ⑦ 屏导出按钮）；T5-4 release 签名两态；P7 5 样本矩阵
- `redo` 之后立刻 `status` 会用落档把状态刷回真实情况（落档还是上一轮的，摘要里写了"待重跑"）——
  设计如此，但需要在文档里说清，避免被误读成"重来没生效"

---

## [0.25.0] - 2026-11-01

**主题**：**真·单文件包**——整份应用只剩一个 `main.exe`（无 DLL、无 `assets/`、无 `vendor/`），
cjh 引擎与 WebView2Loader 变成 PE 资源随二进制走，运行期释放再用。

### Added

- **`packaging/pack-win-single-full.sh`**：把四件事一次做完（机制照抄框架
  `cj-tauri/scripts/pack-win-single.sh`，不自创）：
  ① 仓颉 std/stdx 静态链接（`--static --static-std` + stdx 的 static 树）；
  ② C 桥编成静态归档 `libcjtbridge.a`（`-DCJ_EMBED_WEBVIEW2_LOADER -DCJ_PACK_ASSETS_EMBEDDED`）；
  ③ `windres` 把随包资源打成 `pack_assets.o`（RT_RCDATA，**必须作为链接输入**直接给 ld.lld，
     塞进 `.a` 不会被取用）；
  ④ 页面与能力清单 base64 进二进制（复用 `pack-win-single.sh` 的 `packed_assets.cj` 做法）
- `packaging/pack-assets.txt`（随包清单：`cjh.exe` + 3 个运行时 DLL）、`packaging/README-full.md`
- `src/cjh_host.cj`：`extractEmbeddedCjh()`（释放到 `%LOCALAPPDATA%\lingqu\cjh`）、
  `shouldUseExtracted()`（**释放数 > 0 且 SHA256 校验通过**才用，纯函数 + 单测）、
  `installBinPath()`；`cjhBinPath()` 增加「内嵌释放」兜底分支
- `cjhStatusJson()` 在 `running` 分支回投 `binPath`：引擎已在跑时也能看出用的是哪一份二进制
  （纯函数 `knownBinPath` + 单测）——单文件产物里这直接区分「内嵌释放的那份」与「用户自己起的」

### Changed

- 版本 0.24.0 → **0.25.0**；单测 **154 → 156**（`testShouldUseExtracted` + `testKnownBinPath`）

### Fixed

- **静态链接 C 桥报 `undefined symbol: IID_IFileOpenDialog / IID_IUnknown / IID_IDropTarget`**：
  mingw 下 COM 的 IID 守卫符号在 `libuuid.a` 里，桥的文件对话框与拖放实现引用了它们。
  链接行补齐 `-lole32 -loleaut32 -luuid -lcomdlg32 -lgdi32 -loleacc -lshlwapi -lshcore`
  （与框架 `native/build_win.bat` 对齐），链接通过

### 证据（本机 Windows x64，2026-11-01，0.25.0 产物）

```
[1/6] 随包资源 4 个；WebView2Loader 162392 字节
[4/6] cjpm build success（静态全量重编，0 warning）
[5/6] 导入表：CRYPT32 KERNEL32 SHCORE SHELL32 USER32 WS2_32 comdlg32 dbghelp msvcrt ole32
      （**没有** libcjtbridge.dll / WebView2Loader.dll / libcangjie-runtime.dll / libboundscheck.dll）
      PE 资源节 .rsrc：有
[6/6] 产物：dist/lingqu-0.25.0-win-x64-full/main.exe（58,998,784 字节）+ README.md —— 目录里只有这两个文件
```

隔离验证（拷到 `C:\lingqu-full-test`，目录里**只有 main.exe**，`%LOCALAPPDATA%\lingqu` 先删空）：

```
启动后 %LOCALAPPDATA%\lingqu\cjh\ 出现 4 个文件：
  cjh.exe 13446144 / libcangjie-runtime.dll 1206272 / libcrypto-3-x64.dll 6614528 / libssl-3-x64.dll 1241600
SHA256 与 CJH_VENDOR_FILES 常量逐字一致（3dc9db6f… / 03f4d59a… / a997e132… / bbaf8a8c…）
8765 监听者路径 = C:\Users\<u>\AppData\Local\lingqu\cjh\cjh.exe ← 跑的是**释放出来的**那份
ui_report：screens=7 idCount=156 wsState=connected errorCount=0 tag=probe-done
           cjhState=running、cjhBin=C:\Users\<u>\AppData\Local\lingqu\cjh\cjh.exe（本版新增回投）
关窗 → main 与 cjh 同时退出，8765 释放（ownership 语义未被单文件化改薄）
```

### 未做（如实）

- 单文件包**只在 Windows x64 验证**；Linux/鸿蒙侧的静态桥仍是上游 TODO
- `dist/` 产物不入库（gitignore）；复现请跑 `packaging/pack-win-single-full.sh`
  （需要 `CANGJIE_STDX_ROOT` 的 static 树、`WEBVIEW2_SDK_ROOT`、llvm-mingw、`CJ_TAURI_ROOT`）
- 未做代码签名：单文件 exe 首次运行仍可能被 SmartScreen 拦（与 0.24.0 相同）

---

## [0.24.0] - 2026-10-31

**主题**：**P6 第二刀 —— `t2h:verify` 上线**：采证据 → 出清单 → 算可用率 → 导出三段式报告，
⑥ 屏「功能清单 / 可用率」接真数据（不再是占位示意）。

### Added

- **命令 `t2h:verify`**（三处联动齐全）：
  - 读落档：`.lingqu/scan`（清单规模：命令/事件/插件/前端/平台 API 条数 + 阻塞项）、
    `.lingqu/build`（退出码 + 前端指纹比对）、`.lingqu/hap`（装配闸）、`.lingqu/deploy`（装 / 启 / 日志）
  - 采真机证据：`snapshot_display` + `file recv` 落 `.lingqu/evidence/`（**以文件真的落盘为准**，
    不看 hdc 退出码）；`ls /data/log/faultlog/faultlogger/` 数崩溃记录
  - 落档 `.lingqu/verify/<工程>.{json,md,html}`（+ `.evidence.log` 记录采证过程）
- **⑥ 屏接真数据**：四张统计卡改为可用率 / 通过 / 平台限制（剔除分母）/ 未验证·失败；
  功能清单逐条渲染（判定 pill + 勾选 + 标题，证据与说明进 tooltip）；「采集证据并算可用率」按钮
- `ui_report` 新增 `verifyOk/verifyRate/verifyPass/verifyTotal/verifyLimit/verifyUnknown/verifyShots/verifyMd`
  **以及版面指标 `verifyRows/verifyOverflow/verifyRowH`**（没有视觉也能断言"没竖排、没溢出"）
- `LINGQU_VERIFY_PATH` 探针；`src/verify_feed.cj`（落档解析 + 采证）；2 例新单测（总 **154**）

### Fixed（真机实测暴露的两个）

- **`faultlog` 读不到被当成「崩溃」**：`ls` 返回 `Permission denied` 时，旧逻辑"非空行就算一条"
  把无权限误判成崩溃 → 启动项假失败（可用率 40% → 修后 60%）。现在只认像崩溃记录的行
  （`.log` / `crash` / `fault` 开头），读不到时在报告里写明"无证据"，不再编造。
  纯函数 `countCrashRecords` / `faultlogUnreadable` + 单测
- **清单行被长文本挤成竖排**：证据文本原先塞进 `.chips`（`flex:0 0 auto`），把整行压变形。
  改成单行三列（勾选 / 标题可截断 / 判定），证据与说明进 tooltip——
  版面指标实测：`verifyRowH` **134px → 45px**、`verifyOverflow` 0、`errorCount` 0

### 证据（本机 + 真机，2026-10-31）

```
t2h:verify（LINGQU_VERIFY_PATH=E:\test\rust\habit-tree，设备 3QC0124B20000048）
落档：.lingqu/verify/habit-tree.{json,md,html} + .evidence.log
stats：rate=60% pass=3/5 limit=1 unknown=2 fail=0
  清单：[pass] 应用启动无 panic，首屏渲染
        [unknown] 交叉编译通过，前端指纹一致（本轮没跑 t2h:build，如实记未验证）
        [pass] HAP 装配通过（应用 .so 已进包、无死资源）
        [pass] IPC 命令通道可用（共 7 条命令）
        [unknown] 前端资源打进 .so 并正确加载（9 个源文件）
        [limit] 平台相关 API（4 处）按平台限制登记
截图：.lingqu/evidence/habit-tree-verify.jpeg（3120×2080，173 KB）
ui_report：verifyRate=60 verifyPass=3 verifyLimit=1 verifyUnknown=2 verifyShots=1
           verifyRows=6 verifyOverflow=0 verifyRowH=45 errorCount=0
```

### 未做（如实）

T6-5 断点续迁（`.lingqu/tasks.json` + `t2h:resume`）未开工；⑦ 屏报告导出按钮仍是占位
（报告文件已生成，路径在 ⑥ 屏"证据与报告"卡里，可直接打开看）；两份 unknown 需要跑一次
「交叉编译（OHOS）」才能补齐。

---

## [0.23.0] - 2026-10-31

**主题**：**P6 第一刀 —— 验证与报告的纯函数层**（T6-1 清单推导 / T6-3 可用率 / T6-4 报告渲染）。

### Added

- **`src/verify/verify.cj`**（`lingqu.verify`）：三条口径先钉死，再谈数字
  - `buildChecklist(ChecklistInput)` —— 功能清单**推导**而非手写：命令 / 事件 / 插件 / 前端 / 平台 API
    的条数决定出哪些条目（换样本自动跟着变），部署与日志决定判定
  - `computeStats(items)` —— 可用率 = 通过 ÷ (总数 − **平台限制**)，分母为 0 按 0 处理
  - `renderMarkdown` / `renderHtml` —— 三段式报告（做了什么 / 没做什么 / 需要你做什么），
    逐项挂证据；HTML 侧对正文做转义（报告要给外人看，`<script>` 不能当标签）
  - `verdictLabel` / `CheckItem.toJson` / `VerifyStats.toJson`
- **7 例新单测**（总 **153**），钉的是口径不是文案：
  平台限制不计入分母、**未采集 ≠ 通过**（`unknown` 计入分母）、分母为 0 不除零、
  清单随扫描伸缩（没扫过就只剩 launch/build/hap 三条）、报告三段齐全、HTML 转义

### 未做（本刀的边界，下一步接着做）

- `t2h:verify` **命令**还没接线（要跑 hdc 采截图 / hilog / faultlog，并读 scan·build·hap·deploy 的落档）；
- ⑥ 屏「功能清单 / 可用率」还是占位示意；⑦ 报告的导出按钮也还没接；
- T6-5 断点续迁（`.lingqu/tasks.json` + `t2h:resume`）未开工。

---

## [0.22.0] - 2026-10-31

**主题**：**单文件包** —— 页面与能力清单**编进 exe**，包里不再有 `assets/` 目录
（照 `cj-tauri/examples/ai-chat` 的成熟机制，不自己发明）。

### Added

- `src/packed_assets.cj`（空存根）：`PACKED_UI_B64` / `PACKED_CAPS_B64` 两个常量，
  仓库里恒为空串；`packaging/pack-win-single.sh` 在构建期把它们覆盖成真实 base64。
- `src/packed_resources.cj`：
  - `decodeBase64` / `splitBytesBy`（与 ai-chat 同款实现，只服务这条链路）
  - **`LingquAssetResolver`**：内嵌优先、缺则读盘。装配期由 `wire()` 换掉骨架默认的
    `DirectoryAssetResolver`（`app.assets(...)` 是 setter，wire 又在 `loadCapabilities` 之后跑，
    所以不需要改任何派生文件）
  - `embeddedCapabilityJsons()`：单文件产物没有 `assets/capabilities` 目录，
    能力清单在 `wire()` 里用 `addCapabilityJson` 补挂（否则所有命令都会 `command not allowed`）
- `packaging/pack-win-single.sh`：生成 base64 → 静态构建 → 打包（`--no-assets`）→ 改名成
  `lingqu-<ver>-win-x64-single`；`trap EXIT` **无条件还原**存根，仓里永远只有空串
- `packaging/README-single.md`：单文件版的使用说明与"还差什么"
- 4 例新单测（总 **146**）：base64 往返（含中文多字节、换行、非法字符）、按字节切分、
  "空存根时能力清单为 0"、resolver 的读盘回退分支

### Changed

- `package-win.sh` 增加 `--no-assets`（单文件模式不拷 `assets/`、换用 `README-single.md`）；
  `build-static-win.sh` 把额外参数透传给打包脚本

### 验证（干净 PATH，从别的工作目录启动）

```
包内顶层：main.exe + 5 个 DLL + vendor/cjh + scripts + README.md + run.bat
          assets/ 不存在（页面在 exe 里）
启动：run.bat，WorkingDirectory 故意设成 C:\Windows\Temp
结果：ui_report screens=7 / idCount=146 / activeScreen=env / errorCount=0（自检跑到 probe-frames）
      cjhState=running、wsState=connected；cjh 进程路径 = 包内 vendor/cjh/win-x64/cjh.exe
```

### 未做（如实）

**还不是"一个文件"**：`vendor/cjh`（13.4 MB 的外部引擎）与 5 个 DLL 仍在旁边。
要彻底单文件，需要 ① 把 cjh 作为 PE 资源编进 exe、运行期用框架的 `extractEmbeddedAssets`
释放到 `%LOCALAPPDATA%\lingqu\runtime`；② C 桥编成静态归档（`libcjtbridge.a`），
否则 `libcjtbridge.dll` 省不掉；③ 仓颉运行时目前没有静态版，`libcangjie-runtime.dll` 也得留。
这三条都已写进 `packaging/pack-win-single.sh` 末尾的 TODO。

---

## [0.21.2] - 2026-10-31

**主题**：**修便携包「没找到可用的 cjh」** —— `cjh.exe` 本来就在包里（13.4 MB、SHA256 对得上），
缺的是**发现路径**：`cjhVendorDir()` 用的是相对当前工作目录的 `vendor/cjh/<平台>`。

### Fixed

- **引擎目录解析不再依赖 CWD**。按序解析：`LINGQU_CJH`（显式指定二进制）→ 应用数据目录的部署副本 →
  `LINGQU_HOME/vendor` → `LINGQU_CJH_HOME/vendor` → **从 CWD 逐级上溯 6 层** → 最后退回相对路径
  （开发期在仓根跑的口径不变，旧行为不被破坏）
- **`run.bat` 两处修正**：写 `LINGQU_HOME`（包根）供应用使用；`cd /d` 到包根（`assets/` 是相对读的）。
  并删掉「剥末尾反斜杠」那一行——cmd 对引号紧邻反斜杠的写法会误解码，把整段脚本拆坏
  （真实报错：`'tory' is not recognized as an internal or external command`）
- **引擎发现结果可复核**：`ui_report` 新增 `cjhState / cjhBin / cjhVendorDir / cjhHome`。
  之前只有界面文案，而**仓颉的 `eprintln` 不会进 `%LOCALAPPDATA%\cj-tauri\logs\lingqu.log`**
  （只有 C 桥日志进得去，AGENTS §4-14），所以"找到没找到、用的哪一份"必须落文件
- 2 例新单测（总 **142**）：vendor 候选顺序（LINGQU_HOME → 自定义 → 相对）、CWD 逐级上溯与尾分隔符容错

### 验证（干净 PATH + 故意从别的工作目录启动）

```
包内引擎：…\dist\lingqu-0.21.2-win-x64-static\vendor\cjh\win-x64\cjh.exe（13.4 MB）
启动：cmd /c run.bat，工作目录故意设成 C:\Windows\Temp，PATH 只留 System32
结果：跑起来的 cjh 进程实测路径 = 包内那一份；8765 处于监听
      ui_report：cjhState=running、wsState=connected、errorCount=0
```

### 上游 TODO（AGENTS §8 回馈项）

框架若暴露 `cj_bridge_exe_dir`（C 桥里已经在用 `GetModuleFileNameW`），应用就能直接按 **exe 目录**
定位 `vendor/`，彻底摆脱 CWD 与启动器变量。更彻底的做法参考 `cj-tauri/examples/ai-chat` 的**单文件打包**：
页面与能力清单 base64 编进二进制、cjh 作 PE 资源随行，运行期由 `extractEmbeddedAssets`
释放到 `%LOCALAPPDATA%\<应用名>\runtime`——那样连 `assets/` 与 `vendor/` 两个目录都不需要，
本仓下一步照此收掉即可。

---

## [0.21.1] - 2026-10-31

**主题**：**静态链接的 Windows 便携包** —— 随包 DLL 从 **98 个降到 5 个**（zip 24.7 MB → 13.9 MB）。

### Added

- **`packaging/build-static-win.sh`**：一条命令产出静态版（`main.exe` 11.7 MB，仓颉 std + stdx 全进 exe）。
  做对三件事才链得出来（都实测过，缺一个就失败）：
  1. `compile-option = "--static-std"`（`--static-libs` 已 deprecated，别用）
  2. `CANGJIE_STDX` 指向 **static 树** `<stdx>\windows_x86_64_cjnative\static\stdx`，否则 stdx 仍按 `.dll` 链
  3. mingw 链接行补 `-lcrypt32 -lbcrypt -lws2_32 -liphlpapi -luserenv -lpsapi`——
     静态版 stdx 的 x509 用到 `CertCloseStore`，缺 `-lcrypt32` 直接 `undefined symbol`
- **`packaging/package-win.sh` 重写**：不再"整目录拷 DLL"，改为**按导入闭包自动收**
  （BFS 遍历 `main.exe` 与已收 DLL 的导入表，从 `CANGJIE_HOME`/`CANGJIE_STDX`/框架 `native` 里解析；
  收完再跑一次闭包自检，缺任何 `lib*`/`stdx*` 就失败退出）。动态版 98 个、静态版 5 个，同一份脚本
- 新增 `--static` 模式与 `-static` 后缀包名（`lingqu-<ver>-win-x64-static.zip`）

### 注意（老实话）

- **只有两个 DLL 无论如何也省不掉**：`libcangjie-runtime.dll`（仓颉运行时没有静态版）、
  `libcjtbridge.dll`（cj-tauri 的 C 桥只发了 `.dll.a` 导入库）。再加按名加载的 `WebView2Loader.dll`
  与 cj-tauri 存储用的 `sqlite3.dll`，合计 5 个。
- `targets/desktop/cjpm.toml` 是 `cj-tauri sync` **派生**的（手改会被 `check` 判漂移），
  所以静态构建走的是"**临时改 → 构建 → `trap EXIT` 无条件还原**"。上游若能给
  `cj-tauri.toml` 加 `[build] compile_option/link_option` 透传，这个临时手法就能删掉
  （已记进 `packaging/build-static-win.sh` 的 TODO，按 AGENTS §8 属回馈项）。

### 验证

```
[ok] 版本 0.21.1（static）｜main.exe 12 MB｜DLL 5 个｜整包约 39 MB
zip = 13.9 MB；根目录：main.exe 11.7 + cangjie-runtime 1.2 + sqlite3 3.4 + cjtbridge 0.7
                   + libboundscheck + WebView2Loader
干净 PATH + zip 解压到临时目录 + run.bat → 窗口"灵渠迁移台 · Lingqu"
ui_report：screens=7 idCount=146 activeScreen=env errorCount=0（自检跑到 probe-frames）
```

---

## [0.21.0] - 2026-10-31

**主题**：**`t2h:deploy` 命令化 + ⑥ 真机验证屏接真数据** —— P5 的最后一块拼图。
0.17.0 手工跑通的 `hdc install -r` → `aa start` → 抓 hilog，现在是一条命令，并且**三段分开报**
（装得上 ≠ 界面出来，这是 0.20.0 白屏的教训）。

### Added

- **命令 `t2h:deploy`**（三处联动齐全）：
  - `hdc list targets -v` → `parseHdcTargets`（挡 `COM1 UART Ready` 串口噪声）→ 选设备
    （`serial` 参数 / `LINGQU_DEPLOY_SERIAL` / 第一台 USB；显式 serial 也会在列表里核对）
  - `hdc -t <serial> install -r <hap>` → `parseInstallResult`（**按文本判**，hdc 失败退出码仍是 0）
  - `hdc -t <serial> shell aa start -a <ability> -b <bundle>` → `parseStartResult`
    （ability 默认 `EntryAbility`，bundle 读 `AppScope/app.json5`）
  - `hilog -x` 抓尾部 → `hilogLooksHealthy` 判 panic / SIGABRT / JS error
  - 落档 `.lingqu/deploy/<工程>.json`（`lingqu/deploy/v1`）+ `.log`（三段 hdc 原文 + hilog 尾部）
- **判定层 `judgeDeploy`**（纯函数）：按「设备 → 安装 → 启动 → 日志」**顺序短路**，只报最靠前那段失败——
  装不上给失败码处置（9568322 → 签名），**装上了但启动失败明确写"不是签名问题"**（多半是 ability/bundle 名不对），
  启动了但日志有崩溃则指向 `faultlog`
- **2 例新单测**（总 **140**）：happy path + 四个有序失败分支
- **⑥ 屏接真数据**：路径输入 +「安装并启动」/「仅安装」按钮 + 部署卡（设备 / 安装 / 启动 / hilog / HAP 五项）
  + 原因与下一步；占位的"功能清单"卡明确标了 `占位示意`（不冒充真数据）
- `ui_report` 新增 `deployOk/deploySerial/deployDeviceCount/deployInstalled/deployStarted/deployHilogOk/deployError`
- `LINGQU_DEPLOY_PATH` 探针（置了就启动时跑一次部署体检）

### Added（打包）

- **`packaging/package-win.sh`**：产出 `dist/lingqu-<版本>-win-x64/`（可直接双击 `run.bat`）+ 同名 `.zip`
  （24.7 MB）。清单里显式列出"运行期真的需要的文件"，并带 **依赖闭包自检**：
  把 `main.exe` 与所有随包 DLL 的导入表走一遍，缺失任何 `lib*`/`stdx*` 依赖就直接失败退出——
  这类漏文件的症状是"开发机上好好的、拷给别人启动即退 0xC0000135"，在别人机器上几乎无法自查
- **踩到并修掉的两个打包缺口**（自检就是为了不再犯）：
  `libwinpthread-1.dll`（`libstdx.net.tlsFFI.dll` 显式依赖，缺了启动即退）；
  `vendor/cjh/SHA256SUMS`（少了它引擎自校验不过、压根不会被拉起）
- `packaging/README-run.md`（随包交付的使用说明）、`run.bat`（把本目录加进 PATH 再启动）、
  `.gitignore` 增 `dist/`

### 证据（真机 HAD-W32 / HarmonyOS 7.0.0.111 / API 26，2026-10-31）

```
[devices] 3QC0124B20000048 USB Connected localhost hdc   （COM1/COM2 UART 噪声已滤掉）
[install] serial=3QC0124B20000048 ok=true code=0   msg:install bundle successfully.
[start]   ok=true   start ability successfully.
[hilog]   healthy=true lines=40
verdict:  安装 + 启动成功，hilog 无崩溃痕迹（设备 3QC0124B20000048）
ui_report（activeScreen=verify）：deployOk=true deploySerial=3QC0124B20000048 deployDeviceCount=1
          deployInstalled=true deployStarted=true deployHilogOk=true
```

**便携包实测（2026-10-31）**：把 zip 解压到干净目录、把 PATH 剥到只剩 `System32`，
双击 `run.bat` → 窗口标题 `灵渠迁移台 · Lingqu`、`ui_report` 回投 `screens=7 idCount=146
activeScreen=env errorCount=0`（自检序列跑到 `probe-frames`）；包内 `cjh.exe --version` → `cjh v1.6.1`。

**未做（如实）**：⑥ 屏的「功能清单 / 可用率」仍是占位示意——那要等 P6 的 `t2h:verify`（从画像生成清单 +
逐项挂证据）；T5-4 release 签名两态仍未开工。

---

## [0.20.0] - 2026-10-31

**主题**：**修真机白屏的两个真缺陷**（T5-3/T5-5 的漏检）—— 用户报"habit-tree 在真机上跑起来但看不到界面"，
查下去发现是**装配链漏了两步**，而且 0.17.0 的"真机验证成功"结论**过宽**（装了、启动了，但界面是白的）。

### Fixed

- **`t2h:hap` 不把应用自己的 `.so` 打进 HAP**（白屏根因①）。HAP 里只有 DevEco 模板自带的
  `libentry.so`（6 KB 的 `add` 示例桩）与 `libc++_shared.so`，`libgrove_lib.so`（5.7 MB）**从未进入产物**。
  样本仓把这步写成手工 `cp target/aarch64-unknown-linux-ohos/release/libgrove_lib.so
  gen/ohos/entry/libs/arm64-v8a/`，而 `entry/hvigorfile.ts` 里的 cargo 钩子早被移除（Windows 拉不起），
  所以链路上没人做这件事 → `EntryAbility.moduleName="grove_lib"` 的 `import("libgrove_lib.so")` 失败 →
  ArkTS 页面空 Column → **白屏**。
  现在 `t2h:hap` 装配前自动：读 `EntryAbility.ets` 的 `moduleName` → 定位
  `<src-tauri>/target/aarch64-unknown-linux-ohos/release/lib<name>.so` → 拷进 `entry/libs/arm64-v8a/`
  （产物缺失时直接报"先跑交叉编译"），并在返回值/落档里带 `expectedSo` / `soCopied` / `soSource`
- **HAP 闸放过了"没有应用 .so"的包**（白屏根因②的漏检面）。旧闸只判"有没有 `libs/arm64-v8a/*.so`"，
  被模板的 `libentry.so` 骗过。`checkHapGate` 增加 `expectedSoName` + `hasExpectedSo`：
  **必须存在 `lib<moduleName>.so`**，否则失败并指向"先交叉编译"
- **`.so` 里嵌的是旧前端**：修完白屏①后仍然白屏，因为 `libgrove_lib.so` 的时间戳（22:24）
  早于 `dist/`（22:52）——`.so` 里嵌着旧的 `index-BbUz51cz.css / index-CNGJtM_T.js`，
  而 `dist/` 是 `index-CBRNBEtE.css / index-Cn-J9RFq.js`。重编 `.so`（增量 33 s）后界面出来。
  **这正是 T5-2 前端指纹闸存在的理由**（`t2h:build` 的 verify 模式会报 stale），本轮把它跑在了真机链路上

### Added

- `src/compiler/hap.cj`：`entryModuleNameOf`（从 `EntryAbility.ets` 取 `moduleName`）、
  `expectedSoNameOf`（→ `lib<name>.so`，容错 `lib`/`.so` 写法）、`hapHasSo`（在 HAP 条目里按末段比名，忽略大小写）
- **4 例新单测**（总 **138**）：闸门新参数、`moduleName` 抽取（单/双引号、无则返回空）、
  `.so` 名字推导、"只有模板 stub 必须失败"的白屏复现用例

### 证据（真机 HAD-W32 / HarmonyOS 7.0.0.111 / API 26，2026-10-31）

| 步骤 | 结果 |
|---|---|
| 修前 HAP 条目 | `libs/arm64-v8a/{libc++_shared.so, libentry.so}`（1.47 MB）——**没有 libgrove_lib.so** |
| 修前 hilog | ArkTS 起窗口后再无 NAPI/webview 日志；截图中央区 **97.8% 纯白、仅 70 色** |
| 拷 `.so` + 重装 | HAP 7.25 MB，条目含 `libs/arm64-v8a/libgrove_lib.so`；hilog 出现 `cef` / `chromium` / `gpu` 进程与 `[WebNavigation]` |
| 页面加载 | `LoadUrlWithHeaders url:tauri://loc…` → `OnPageEnd httpStatusCode:200` → `DOMContentLoaded` → `PageLoadFinished` |
| 仍白屏 | 截图 350 KB、中央区 97.8% 纯白 → 定位到 `.so` 嵌旧前端（见上） |
| 重编 `.so` 后 | 截图 173 KB、中央区 **574 色**、主色 `12,15,24`（36.6%）；ArkWeb `gpu`+2×`render` 子进程在跑，无 faultlog |

**人眼确认（2026-10-31，用户）**：修完后界面正常显示 —— 白屏问题闭环。
我这边抓屏仍与"仅桌面"截图逐点相同（11310 采样差 1）、窗口管理器里 `habit_tree0` 的 bounds 为
`[515,281]-[2605,1675]`，但 `uitest dumpLayout` 的前台是 `com.ohos.sceneboard`——
**说明"截屏 + 窗口树"不能替代人眼**（抓屏可能拍到桌面）。0.17.0 的"真机首验通过"结论按此收窄：
**链路（装/启/签名）当时成立，界面呈现不成立；0.20.0 起两者都成立**。

---

## [0.19.0] - 2026-11-01

**主题**：**签名配置自动写回**（`t2h:sign` 的 apply 模式）—— 把"体检工具"变成"省事工具"。
工程没配签名时，一条命令把 `signingConfigs` 写进 `build-profile.json5`（自动备份、幂等、写后可直装）。
另沉淀长文 **`docs/鸿蒙自动签名机制.md`**：把 DevEco / flutter / deveco-cli 那套"签名材料工厂"
拆成可复刻的步骤（这条链之前只有零散结论，没有一份能照着实现的说明书）。

### Added

- **`t2h:sign` 的 apply 模式**（`apply: true` 或 `LINGQU_SIGN_APPLY=1`）：
  1. 判定工程缺签名（已有非空 `signingConfigs` 时**跳过而不是覆盖**）
  2. 找一个**用同一套材料**的 donor 工程（比对 `storeFile` 的 p12 文件名；范围：显式 `donor` /
     `LINGQU_SIGN_DONOR`，否则扫 `~/DevEcoStudioProjects`、`~/Documents`、`~/Desktop`，限深度 4）
  3. 把它的 `signingConfigs`（含 **DevEco AesGcmKit 加密口令**——我们造不出来，只能搬）原样注入
  4. 顺手把 `products[].signingConfig` 指到它；改动前存 `.lingqu/sign/<工程>.build-profile.json5.bak`
  5. **写后立刻重新判定**并回填结果 → 界面直接显示"可直装"，不用再点一次
- **纯函数层**（`src/compiler/sign.cj`）：`SigningMaterial` / `signingMaterialOf` / `signingBlockJson5` /
  `json5EscapeOf` / `injectSigningConfigs` / `pointProductSigningConfig` / `applySigningConfig` /
  `sameMaterialFile` / `fileNameOf` —— **纯文本手术，不重排整份 json5**
- **4 例新单测**（总 **136**）：写回主路径（含"写得进去 = 读得出来"的闭环断言 + 括号配平）、
  拒绝覆盖 / 材料不全 / 结构不认识、`signingConfig` 三种指向、材料身份与转义往返
- **⑤ 屏「写回签名配置」按钮** + `ui_report` 新增 `signApplied`
- **`docs/鸿蒙自动签名机制.md`**（长文，可直接改写为博客）：三方关系图、九步全链路、AGC 端点表、
  材料命名规则（**本机实测确认** hash = `sha256(前向斜杠路径)` base64url 去 padding）、
  `material/` 口令加密格式（PBKDF2 + AES-128-GCM）、C0–C10 复用检查、"上云生成 vs 离线复用"对比、
  复刻清单，以及**每条事实的出处与核对方式**

### Fixed（都是先红后绿）

- **注入后 json5 变成 `]]`**：`injectSigningConfigs` 从原数组的 `]` 处开始接原文，而新 body 自己已带 `]`
  → 多一个闭合括号，json5 语法错误。改为从 `]` 的**下一个字符**接；并加 `bracketBalance()` 断言防复发
- **donor 比对拿 `.p7b` 去比 `.p12`**：`sameMaterialFile` 比的是文件名，材料身份是 p12 → 永远匹配不上
  （实测 `applied=false`）。改为先把候选 `.p7b` 换成同 base 的 `.p12`
- **写回后 `filesExist`/`profileType`/`allowsDevice` 仍是写回前的旧值**：先按新配置重算材料路径与
  存在性、重解析 profile，再判定（否则会出现"已写回但报材料不存在"的自相矛盾）
- 探针失效：页面显式传 `apply:false` 会盖掉 `LINGQU_SIGN_APPLY=1` → 改成两者取「或」

### 验证证据（真机 + GUI 实测，2026-11-01）

拿一份 `signingConfigs: []` 的模拟工程（`%TEMP%\lingqu-apply-demo`，包名 `com.jiujiang.habit_tree`）
跑 `LINGQU_SIGN_PATH=<它> LINGQU_SIGN_APPLY=1 LINGQU_SIGN_DONOR=E:\test\rust\habit-tree`：

```
[verdict] ok=true reason=签名配置齐全，且 profile 绑定了本机 UDID，可直装
[apply] applied=true donor=E:\test\rust\habit-tree\src-tauri\gen\ohos\build-profile.json5
        backup=.lingqu/sign/lingqu-apply-demo.build-profile.json5.bak
[signing/after-apply] name=default type=HarmonyOS
        certpath=…default_ohos_m7Gx….cer  profile=…default_ohos_m7Gx….p7b  storeFile=…default_ohos_m7Gx….p12
ui_report：signOk=true signApplied=true signHasConfig=true signFilesExist=true
           signAllowsDevice=true signType=debug
```

写回后的 `build-profile.json5` 与 0.17.0 真机装成功的那份**同结构同材料**；demo 工程缺 entry 模块，
所以本轮**没有**在它上面重跑 `hvigor assembleHap`（如实标注，未验证到"装配"这一步）。
四道闸全绿：build 0 warning / test TOTAL=136 FAILED=0 / check / build-app 0 warning。

---

## [0.18.0] - 2026-11-01

**主题**：**签名体检 `t2h:sign`** —— 把 T5-5 挖到的"能不能装"判据做成一键体检。
**离线、免账号、免 IDE**：读 `hdc shell bm get --udid` + 工程 `build-profile.json5` + `~/.ohos/config/*.p7b`，
直接回答"现在装的上去吗；装不上要动什么"。

### Added

- **`src/compiler/sign.cj`**（`lingqu.compiler` 续）：签名判定的纯函数层
  - `extractProfileJson`：从 PKCS#7 二进制里**配对扫描**取出内嵌明文 JSON（字符串/转义感知）
  - `latin1Of`：字节 → **ASCII 净化视图**（可打印 ASCII 保留、其余换空格）
  - `parseOhosProfile` → `OhosProfile{profileType,bundleName,deviceIds,parseError}` + `allows(udid)`
  - `discoverProfiles` / `pickProfile`：扫 `~/.ohos/config` 全部 `.p7b`，挑"含本机 UDID"的那份
  - `parseProjSigning` + `json5ValueAfter` + `unescapeJson5`：**JSON5** 的轻量提取
    （注释/尾逗号/单引号/无引号键都认），拿 `signingConfigs` 的 `certpath/profile/storeFile` 与
    `products[].signingConfig`；**双反斜杠必须还原**，否则 Windows 上 `exists()` 永远假
  - `parseUdid`：不猜前缀文案，取**最长连续十六进制串**（≥16 位）
  - `judgeSign(hasConfig, filesExist, allowsDevice, profileType, udid, hasCandidate)` → 结论 + 可执行下一步
- **命令 `t2h:sign`**（三处联动齐全）：取 UDID → 解析工程签名配置（相对路径会按 `gen/ohos` 兜底解析）→
  扫本机材料（**优先挑包名也对得上的**，包名读 `AppScope/app.json5`）→ 判定 →
  落档 `.lingqu/sign/<工程>.json`（`lingqu/sign/v1`）+ `.log`（hdc 原文 + 每份 profile 的 type/bundle/devices/allowsLocal）
- **12 例新单测**（总 **132**）：脱敏 fixture 的全字段解析、坏 JSON/空 JSON、配对花括号（尾部 `0x7D` 不带进来）、
  JSON5 五类写法与转义还原、`judgeSign` 五条失败分支、真实 `~/.ohos/config` 扫得到且解析不炸
- **⑤ 屏签名卡**：UDID / 工程签名配置 / 材料文件 / profile 类型 / 含本机 UDID / 本机候选材料 六项，
  下面一行直接给"原因 + 下一步"；`ui_report` 新增 `signOk/signUdid/signHasConfig/signFilesExist/signAllowsDevice/signType/signCandCount`
- **`LINGQU_SIGN_PATH` 探针**：置了就在启动时跑一次体检（秒级，适合 CI）
- **`LINGQU_UI_SCREEN`**：启动即切到指定屏（`LINGQU_UI_SCREEN=build`），给"截某屏版面证据"一个可复现入口
- `samples/evidence/ohos-profile.sample.p7b.txt`：真实 profile 的**脱敏**内嵌 JSON（结构逐字段一致，包名与 UDID 换成合成值）

### Fixed

- `.p7b` 用 `String.fromUtf8` 直接转二进制 → 高位字节被吞/报 `Unexpected character: '?'`，内嵌 JSON 破掉。
  改 ASCII 净化视图（内嵌 JSON 全是 ASCII，净化后更稳）
- "取最后一个 `}`"当 JSON 结尾 → 证书二进制里的 `0x7D` 会把尾部垃圾带进 JSON。改**配对扫描**（含字符串/转义状态机）
- `quote` 当变量名编译报 `expected identifier or pattern after 'let'`（AGENTS §4-20 老坑再现，改名 `dquote`）

### 验证证据（真机 + GUI 实测，2026-11-01）

```
[hdc shell bm get --udid] exit=0
udid of current device is : B8861DAE97…6385
[config] C:\Users\<user>\.ohos\config（找到 4 份 .p7b）
[profile] default_ohos_m7Gx…p7b type=debug bundle=com.jiujiang.habit_tree devices=26 allowsLocal=true
[signing] name=default type=HarmonyOS … filesExist=true
[verdict] ok=true reason=签名配置齐全，且 profile 绑定了本机 UDID，可直装
```

`ui_report`（`activeScreen=build`）：`signOk=true signUdid=true signHasConfig=true signFilesExist=true
signAllowsDevice=true signType=debug signCandCount=4`，`errorCount=0`。
**未做**：`t2h:deploy`（安装/启动/取日志命令化）与 ⑥ 真机验证屏仍未接线；T5-4 release 签名两态未做；
ArkWeb 上的界面渲染仍需人眼确认（我无视觉能力）。

---

## [0.17.0] - 2026-10-31

**主题**：**T5-5 真机首验**（鸿蒙 PC `HAD-W32` / HarmonyOS 7.0.0.111 / API 26）：
`hdc install` + `aa start` 跑通，**签名不需要在 DevEco 里登录**。
同时落地 hdc 输出的纯函数解析层（`src/compiler/deploy.cj`）+ 6 例基于真实输出的单测。

### Added

- **`src/compiler/deploy.cj`**（`lingqu.compiler` 续）：hdc 输出的纯函数层
  - `parseHdcTargets`：解析 `hdc list targets`，**挡掉 `COM1 UART Ready` 这类串口噪声**
    （踩过"把 COM 口当设备"的幽灵设备坑），保留 USB 与 TCP（无线调试）目标
  - `parseInstallResult` / `parseStartResult`：按**文本**判定成败 —— 实测 **hdc 失败时退出码仍是 0**，
    只能靠 `install bundle successfully` / `start ability successfully` 判
  - `hdcFailCodeOf` / `hdcFailHintOf`：9568322（签名不可信）/ 9568269（安装路径）/ 10106102（锁屏）
    → 可执行处置，与 `diagnose.cj` 的 FP-012/013/014 同源
  - `hilogTail` / `hilogLooksHealthy`：日志尾部 + panic/SIGABRT/FATAL 健康判断
- **6 例新单测**（总 120），fixture 全部是 **2026-10-31 真机原始输出**
- 真机截图入库：`samples/evidence/habit-tree-ohos-device.jpeg`（3120×2080，170 KB）

### 签名调研结论（用户提出的问题，已实测验证）

| 做法 | 结果 |
|---|---|
| 用 SDK 自带的 **OpenHarmony 默认材料**签名（`sdk/default/openharmony/toolchains/lib/OpenHarmony.p12`） | ❌ `hdc install` 被拒：`code:9568322 signature verification failed due to not trusted app source` |
| 用 `~/.ohos/config` 里 **DevEco 自动签名的 debug 材料** | ✅ **`install bundle successfully`** |

关键发现：**`~/.ohos/config` 里那套材料还在，且 profile 的 `device-ids` 已包含本机 UDID**
（`B8861DAE97…6385`）。口令是 DevEco 加密串，但 **hvigor 自己会解密** ——
所以把历史里那份 `signingConfigs` 写回 `build-profile.json5`，`hvigor assembleHap` 就能签出可装 HAP，
**全程不需要打开 DevEco、也不需要重新登录**。

参考的 [flutter 提交](https://gitcode.com/oh-flutter/flutter_flutter/commit/e2793de97e8744b5f675da52d72e7076420bca3c)
是同一件事的自动化版（`DevEco-identical file naming + hap-sign-tool P12/CSR`、`OAuth loopback login`、
`AGC APIs + hdc 设备注册`）——**它省掉的是 IDE，不是账号**；本次发现的是更省的一条：
**复用机器上已有的签名材料，连账号都不需要**。

### Docs（签名知识沉淀，本轮的第二个交付物）

- **新增 `skills/t2h-ohos-port/references/signing.md`** —— 鸿蒙真机签名完整参考（本项目最有复用价值的一段）：
  - 三条路径对比：SDK 自带 OpenHarmony 默认材料（❌ 9568322）/ **复用 `~/.ohos/config` 自动签名材料（✅ 免账号免 IDE）**/
    flutter 式 OAuth+AGC（✅ 但要账号）
  - 材料结构说明（`default_<工程>_<hash>.{p12,cer,csr,p7b}`）+ **直接 grep `.p7b` 判 device-ids**（不需要解析 ASN.1）
  - **6 步配方**（抄 signingConfigs → ohpm install → hvigor assembleHap → hdc install → aa start → aa dump 验状态）
  - 失败码表（9568322 / 9568269 / 10106102）+ "什么时候才真需要账号"
  - 验证纪律（**别只看命令成功**：按文本判、状态里看 FOREGROUND、截图存证、崩溃目录、渲染要人眼）
- **`skills/t2h-ohos-port/SKILL.md`**：第 7 步（装配 HAP + 签名）改写为指向 signing.md，并把
  "真机调试必须切 debug 签名"补成"多数情况不需要登录账号"；references 表新增一行
- **`skills/t2h-ohos-port/references/pitfalls.md`**：9568322 那条补一句交叉链接
- **`docs/开发环境.md`**：原来那句"首次要在 DevEco 里自动签名（**需登录华为账号**）"**已过时**，
  改写为"先查 `~/.ohos/config` 的 p7b 有没有你的 UDID——有就免登录复用"
- **`AGENTS.md` §4** 新增两条坑（#39 真机签名 / #40 hdc 失败退出码仍为 0）
### 验证证据（真机，2026-10-31）

| 步骤 | 命令 | 结果 |
|---|---|---|
| 设备识别 | `hdc list targets` | `3QC0124B20000048`（HAD-W32，API 26，HarmonyOS 7.0.0.111） |
| 安装 | `hdc -t <sn> install -r entry-default-signed.hap` | **`install bundle successfully`** |
| 启动 | `hdc shell aa start -a EntryAbility -b com.jiujiang.habit_tree` | **`start ability successfully`** |
| 状态 | `hdc shell aa dump -a` | `Mission ID #77 … state #FOREGROUND`、`AbilityRecord #160 state #ACTIVE` |
| 视觉 | `snapshot_display` + `hdc file recv` | 3120×2080 jpeg，170 KB（已入库） |
| 崩溃 | `ls /data/log/faultlog/faultlogger/` | 空（无崩溃记录） |

**未做（如实标注）**：`t2h:deploy` 命令（安装/启动/取日志）与 ⑥ 真机验证屏**尚未接线**——
本轮只做手工链路验证 + 纯函数解析层；T5-4 签名两态（release/企业证书）仍未做。
另：ArkWeb 渲染子进程未观察到，**界面是否完整渲染需人眼看截图确认**（我无视觉能力）。

---

## [0.16.0] - 2026-10-30

**主题**：**P5 第三刀 —— T5-3 HAP 装配**：`t2h:hap` 上线，用 DevEco 自带的 node + hvigor
打 `assembleHap`，并对产物做**死资源校验**（`rawfile/` 必须为空——前端已编进 `.so`）。
P5 的"从源码到可安装 HAP"这条链**已闭合**，只差真机部署（T5-5）。

### Added

- **`src/compiler/hap.cj`**（`lingqu.compiler` 续）：
  - `parseHvigorOutput`：解析 hvigor 输出（`BUILD SUCCESSFUL` / `BUILD FAILED` 冲突时以 FAILED 为准、
    错误行计数与首条错误、产物名提取）；`stripAnsi` 先剥 ANSI，否则 `startsWith("ERROR")` 失配
  - `scanHapEntries`：**字节级**扫 HAP（zip 条目名明文存放，不用解压）→ `module.json` /
    `libs/arm64-v8a/*.so` / `rawfile/` 条目；非 ASCII 字节置换后再扫，1.4 MB 也是 O(n)
- **命令 `t2h:hap`**（三处联动齐全）：
  - 前置检查（脚手架 `gen/ohos/build-profile.json5`、DevEco 位置、node/hvigorw、SDK 目录）逐条给可执行提示
  - **自动补 `ohpm install --all`**（缺 `oh_modules` 时；`autoInstall=false` 可关）——
    否则 ArkTS 报 `Cannot find module '@ohos-rs/ability'`
  - 跑 `node <devEco>/tools/node/node.exe <devEco>/tools/hvigor/bin/hvigorw.js --mode module -p product=default assembleHap --no-daemon`
  - 落档 `.lingqu/hap/<工程>.json`（`lingqu/hap/v1`）+ `.log`（hvigor 全文）
- **第 8 道闸 `checkHapGate`**：装配成功 / 有 `module.json` / 有 `libs/arm64-v8a/*.so` / **无 rawfile 死资源**
- **⑤ 屏 HAP 卡**：「装配 HAP」按钮 + 装配/产物大小/签名态/arm64 库/rawfile/闸 六项指示；
  `ui_report` 新增 `hapOk/hapBuilt/hapBytes/hapSigned/hapRawfile/hapArm64/hapGate`；
  `LINGQU_HAP_PATH` 探针
- **9 例新单测**（总 114）：成功/失败日志解析、SUCCESS×FAILED 冲突、产物名提取、ANSI 剥离、
  HAP 条目扫描（健康/rawfile/边界/噪声）、HAP 闸四分支

### Fixed（三条都是**实机跑出来**的，单测覆盖不到）

1. **`executeWithOutput(node, ["--mode", ...])` 报 `node.exe: bad option: --mode`（exit=9）**
   argv 里**漏了 hvigorw.js 路径**，node 把 hvigor 的选项当成自己的。→ `[hvigorJs, "--mode", ...]`（AGENTS §4-36）
2. **hvigor 报 `00303217 Configuration Error: Invalid value of 'DEVECO_SDK_HOME'`，但手跑同命令成功**
   拼接出 `D:\oh\DevEcoStudio/sdk` —— **混合分隔符**被 hvigor 校验拒绝。→ `hostPath()` 按宿主归一（§4-37）
3. **过期环境变量覆盖了正确推导值**
   本机 `DEVECO_SDK_HOME` 仍指向已删除的旧 DevEco；"环境变量优先"的取值顺序把它当成了首选。
   → `firstExistingPath()`：路径类环境变量**必须目录存在**才采用（§4-38）。本机已连续踩到
   `DEVECO_HOME` / `DEVECO_SDK_HOME` / `NATIVE_OHOS_SDK` 三个过期值

### 验证证据（实机，`t2h:hap` 由界面探针触发）

| 断言项 | 值 |
|---|---|
| 装配 | `built=true`、`errorCount=0`、hvigor `BUILD SUCCESSFUL in 3 s 161 ms` |
| 产物 | `entry-default-signed.hap`，**1.40 MB**（`PackageHap` + `SignHap` 均 finished） |
| 条目 | `module.json` ✓、`libs/arm64-v8a/libentry.so` ✓、**rawfile = 0** ✓ |
| 第 8 道闸 | `gates.passed=true` |
| `ui_report` | `hapOk=true hapBuilt=true hapBytes=1469720 hapSigned=true hapRawfile=0 hapArm64=true hapGate=pass` |
| 门禁 | 四道闸全绿，build 0 warning，**TOTAL=114** |

> 另一个实测事实：`signingConfigs` 为空时 hvigor 仍产出 **signed** HAP（用 DevEco 内置的调试证书），
> 所以"签名态"要靠 `signed/unsigned` 两个文件是否存在来判断，不能靠配置猜。

**未做（如实标注）**：T5-4 签名两态（release 签名要 DevEco 登录华为账号）、T5-5 hdc 部署/启动/hilog —
**真机仍未连接**（`hdc list targets` = `[Empty]`），所以没有任何"装到鸿蒙 PC 上跑起来"的证据。

---

## [0.15.0] - 2026-10-30

**主题**：**P5 第二刀 —— T5-2 前端指纹校验**：把「`.so` 内嵌的前端产物」与 `dist/` 实际文件
对账，并让 **"只改前端不重编 `.so`" 这类"构建全绿、真机跑旧前端"的假成功自动报错**。
这是路线图点名的"本项目最硬的差异化点"，现在能自证。

### Added

- **`src/compiler/fingerprint.cj`**（`lingqu.compiler` 续）：
  - `extractAssetKeys`：**按字节**扫 `.so`（不依赖 UTF-8 解码），找 ASCII `assets/` 后吃合法 key
    字符直到非 key 字节，要求以已知前端扩展名结尾（js/css/mjs/html/png/svg/woff2… 共 18 种）；
    去重保序，非 `assets/` 下的产物不算
  - `compareAssetKeys` → `AssetDiff{matched, staleInSo, missingInSo}`：**两个方向分开记**
  - `distAssetKeysOf`：递归列 `dist/`，只收 `assets/` 下的资源（`dist/index.html` 是入口不算 AssetKey）
- **`t2h:build` 扩展**：编译成功后自动做指纹校验（`.so` 路径由 artifacts + `target/<target>/release`
  解析；`dist/` 路径读 `tauri.conf.json` 的 `frontendDist` 并按 src-tauri 相对解析）；
  新增 `verifyOnly: true` **只校验不编译**（CI / 自证用，秒级）；新增 `LINGQU_BUILD_VERIFY_ONLY=1` 探针
- **第 7 道闸 `checkAssetFingerprintGate`**（`src/port/gates.cj`）：
  `.so` 里没扫到资源 → 失败（frontendDist 没配？流水线顺序错？）；
  `staleInSo > 0` → 失败（真机会跑旧前端）；`missingInSo > 0` → 失败（`.so` 是旧的，必须重编）
- **⑤ 屏新增「前端指纹」指示 + 「校验前端指纹」按钮**（不重编，秒级出结论），
  `ui_report` 新增 `buildAssetOk/buildAssetMatched/buildAssetStale/buildAssetMissing`
- **6 例新单测**（总 105）：字节扫描（含去重/非法扩展名/0x00·0xFF 噪声）、三个比对方向、
  指纹闸四分支（无内嵌/stale/missing/干净）、`distAssetKeysOf` 真实目录 fixture

### 验证证据（实机三场景，全部可复跑）

| 场景 | 构造 | 结果 |
|---|---|---|
| 1 **一致** | habit-tree @ ohos 的 `.so` + 原 `dist/` | `assetDiff.ok=true matched=3 stale=0 missing=0`，闸 **pass**；`.so` 内嵌 `assets/index-BbUz51cz.css`、`assets/index-CNGJtM_T.js`、`assets/ui-BQiP9gYH.js` 与 `dist/assets/` 逐字吻合 |
| 2 **新前端没打包** | 往 `dist/assets/` 加一个 `index-FRESH99.js`（不重编 `.so`） | `missingInSo=[assets/index-FRESH99.js]`，闸 **fail**：「dist/ 里 1 个新产物没进 .so——.so 是旧的，必须重编」 |
| 3 **旧 `.so` 带旧前端** | 把 `dist/assets/index-BbUz51cz.css` 移走（不重编） | `staleInSo=[assets/index-BbUz51cz.css]`，闸 **fail**：「`.so` 内嵌的 1 个前端产物在 dist/ 里已不存在——改了前端没重编 .so，真机会跑旧前端」 |

> 重要操作提醒：正常跑 `cargo build` 时改 `dist/` **会触发自动重编**（`generate_context!` 的
> rerun-if-changed 覆盖前端产物），所以"只改前端不重编"不会在自动流水线里自然发生——
> 验证这道闸必须用 `verifyOnly`（或用真实设备装旧包）。场景 2/3 就是这么构造的。

| 断言项 | 值 |
|---|---|
| 门禁 | 四道闸全绿，build 0 warning |
| 单测 | **TOTAL=105，FAILED=0，ERROR=0** |
| `ui_report` | 三场景分别回投 `assetOk=true/false/false`、`matched=3/3/2`、`stale=0/0/1`、`missing=0/1/0` |

**未做（如实标注）**：T5-3 HAP 装配、T5-4 签名、T5-5 hdc 部署；真机仍未连，
`.so` 只在交叉编译层面验过，**没有任何真机加载/运行证据**。

---

## [0.14.0] - 2026-10-30

**主题**：**P5 第一刀 —— T5-1 交叉编译 + 结构化诊断**。`t2h:build` 上线：跑
`cargo build --release --target aarch64-unknown-linux-ohos`，把 stdout(JSONL) 与 stderr
两路结果归一化成结构化诊断，命中指纹就给"现象→根因→修法"，并过**编译闸 + 回归闸**。
同时**一次解锁三笔欠账**：P3 出口判据 1、P4 出口判据 1、六道闸里此前只有"闸位"的两道。

### Added

- **`src/compiler/compile.cj`（新，`lingqu.compiler` 包）**——T5-1 的纯函数半边：
  - `parseCargoJsonl`：解析 `--message-format=json` 的 JSONL，抽 `compiler-message`
    （level / code / message / 主 span 的 file:line:col / rendered 前 12 行）、
    `compiler-artifact`（只收 `.so`/`.a` 交付产物）、`build-finished.success`；
    **截断/混杂行只计数不炸**（`badLines`）——真实构建日志的最后一行常是半个 JSON
  - `countErrorLines` / `firstErrorLine`：从**stderr** 数 error 行（见下面 Fixed 1）
  - `diagsAsLogText`：归一化成可喂指纹库的文本（同时含"短描述"与"源码上下文"两类 marker）
- **`t2h:build` 命令**（三处联动齐全）：`{path, target?}` → 跑 cargo → 诊断 → 闸 → 落档
  `.lingqu/build/<工程>.{jsonl,log,json}`（`lingqu/build/v1`）；`LINGQU_CARGO` 可指定 cargo
- **六道闸补齐第 5/6 道**（`src/port/gates.cj`）：`checkCompileGate`（目标平台必须编过）、
  `checkRegressionGate`（error 数不得比上次涨）、`mergeGates`
- **指纹库 +2**（13 → **15 条**）：FP-016（`pkg-config has not been configured to support
  cross-compilation`，rule 档 → 重跑 `t2h:port` 根除）、FP-017（`failed to run custom build
  command for`，guide 档）——**依据是本轮真实构建失败，不是凭空编**
- **依赖规则 +1**（`R2-DEPS-012`）：GTK/glib 桌面链 8 个 crate（glib-sys / gobject-sys / gio-sys /
  gdk-sys / gdk-pixbuf-sys / pango-sys / cairo-sys-rs / atk-sys）判「不可用」，替代建议直指
  根因"patch 掉 wry/tao"，而不是让人去配 pkg-config
- **⑤ 构建打包屏接真数据**：路径输入 + 「交叉编译」按钮 + 退出码/错误数/警告数/产物/编译闸五项指示
  + 指纹命中列表；`ui_report` 新增 `buildOk/buildExit/buildErrors/buildWarns/buildDiags/buildFp/buildSo/buildGate`
  八个可断言字段；`LINGQU_BUILD_PATH` 探针（耗时以分钟计，只在显式设置时跑）
- **9 例新单测**（总 99）：JSONL 解析（含截断/空/混杂垃圾）、build-script 失败无 compiler-message、
  产物过滤、stderr 计数、编译闸、回归闸、合并闸、FP-016/017 命中真实失败、GTK 链规则
- 入库两份**真实构建输出**样本（脱敏裁剪）：`samples/evidence/cargo-jsonl-compile-error.jsonl`、
  `cargo-jsonl-build-script-fail.jsonl`、`cargo-jsonl-success-artifacts.jsonl`

### Fixed

1. **build-script 失败时 `errorCount=0` 却"编译失败"**（本轮实测撞到）
   `cargo` 的 JSON 流里只有 `build-finished{"success":false}`，**一条 `compiler-message` 都没有**——
   因为 `glib-sys` 这类失败发生在 build script 里，报错只进 stderr。处置：同时收 stderr 并
   `countErrorLines()` 数 `error:`/`error[` 行，取两路最大值作有效错误数（`stderrErrors` 单独回投）。详见 AGENTS §4-34。
2. **回归闸把"首次构建"误报成"回归"**
   无基线时按基线 0 处理，于是未迁移工程首跑打出「错误从 0 涨到 8（改了反而更糟）」——
   它根本没被"改"过。处置：无基线时**跳过回归闸**（首次的绝对要求由编译闸负责）。
3. **诊断提案被喂进补丁闸 → 假失败**
   `patchProposalsFromDiagnosis` 给的提案只有文件名（增删行数为未知占位 0），撞上"空补丁"闸
   必然失败。处置：`t2h:build` 只过编译闸 + 回归闸；补丁闸留给真正产生 diff 的 agent 应用路径。
4. **产物列表被中间态淹掉**：一次失败构建有 249 条 artifact（`.rlib`/`.rmeta`/`.d`/宿主 `.dll.a`），
   落档 12 KB 全是噪音。处置：只收 `.so`/`.a`（且排除 `.dll.a`）。
5. **`package lingqu.build` 与顶层 `build()` 撞名**（编译期直接报错）
   `src/build/` → `src/compiler/`（`lingqu.compiler`）。详见 AGENTS §4-35。

### 验证证据（实机，Windows 桌面会话 + Xvfb 均不需要）

| 场景 | 断言 | 结果 |
|---|---|---|
| **A 未迁移**（habit-tree @ main） | `t2h:build` | `exit=101 errorCount=8 stderrErrors=8 artifacts=0 baseline=-1`；闸 2 条失败（都指向编译）；指纹 **FP-016(rule) + FP-017(guide)**，`suggestRerunPort=true` |
| **B 已迁移**（habit-tree @ ohos） | `t2h:build` | **`exit=0 errorCount=0`，`gates.passed=true`**（P4 出口判据 1 达成）；产物 `libgrove_lib.so`（5.5 MB，`llvm-readobj` 实测 `Format=elf64-littleaarch64`）+ `libgrove_lib.a` |
| **P3 出口判据 1**（矩阵 ↔ 真实失败） | 依赖矩阵「不可用」清单 vs 真实失败点 | 真实失败 8 个（glib-sys/gobject-sys/gio-sys/gdk-sys/gdk-pixbuf-sys/pango-sys/cairo-sys-rs/atk-sys），矩阵 **8/8 判为不可用 = 100%**（判据要求 ≥80%）；另有 2 个"多识别"（gtk-sys/webkit2gtk-sys，构建未走到）如实登记 |
| **T5-2 可行性预验** | `.so` 内 vite AssetKey ↔ `dist/` | 从 `libgrove_lib.so` 提取到 `assets/index-BbUz51cz.css`、`assets/index-CNGJtM_T.js`、`assets/ui-BQiP9gYH.js`，与 `dist/assets/` **三个文件名逐字吻合** |
| 门禁 | 四道闸 | build 0 warning / **TOTAL=99** / `cj-tauri check` PASS / 骨架 build 0 warning |

**未做（如实标注）**：T5-2（`.so` 指纹校验命令化）、T5-3 HAP 装配、T5-4 签名、T5-5 hdc 部署全部未开始；
真机尚未连接（`hdc list targets` = `[Empty]`），所以**没有任何真机证据**。

---

## [0.13.1] - 2026-10-30

**主题**：P5 之前的**交接审核轮** —— 逐文件审 0.9.0～0.13.0（上一手 AI 交付的五轮），
修掉 7 个真缺陷、校准 4 处虚高数字、把「换机器就构建不了」的根因拔掉。
**没有新增功能**，目标是把地基修到可信：0.13.0 声称的「P4 判据 2/4 达成」里，判据 4 其实不成立。

### Fixed

0. **`t2h:ui_report` 并发写把自检日志截成碎片**（严重，0.13.1 实机首跑就撞到）
   现象：`.lingqu/ui-report.log` 里出现只有 `6902039 }` 的 9 字节残行，整条快照丢失，
   自检序列无法逐条断言（那个 tag `scan-kind-platform` 从此消失）。
   根因：落盘是「读全文 → 拼一行 → 覆盖写」，而 `t2h:ui_report` 会被多个前端定时器与
   页签切换**并发**调用，两个写者互相截断对方内容（审计里登记为"双写无锁"，这次实机取证）。
   处置：加进程级 `Mutex`（`gUiReportLock`）+ 上一行未以换行结尾时先补换行。
   **复跑实测：16/16 行都是完整快照，`scan-kind-platform` 回来了。**

1. **`t2h:revert` 自 0.11.0 起一直是坏的**（严重，且被文档写成"已达成"）
   现象：apply 之后点回滚永远报「没有备份可回滚」。
   根因：0.11.0 把备份从「单文件 `<工程>-Cargo.toml.bak`」改成「逐文件 `.lingqu/port/<工程>/<文件>.bak`」，
   **但 revert 没跟着改**，还在找旧路径；即使找到了也只回滚 Cargo.toml，其余 4 个被改文件留在原地。
   处置：新增 `revertPairs()` / `backupDirOf()` / `legacyCargoBakOf()`（`src/port/port.cj`，纯函数可单测），
   备份文件名收成 `BAK_*` 常量，**apply 与 revert 共用同一张表**；回滚覆盖 Cargo.toml /
   rust-toolchain.toml / .cargo/config.toml / lib.rs / index.html，并删除带 `lingqu: R2-PORT-014`
   标记的 `lingqu-dialog.js/.css`（不带标记的不动，避免误删用户文件）；旧路径备份仍兼容。

2. **`cjpm.toml` 里存着别的机器的绝对路径**（严重）
   现象：任何非 Linux 机器跑 `scripts/test.sh`，第一道闸直接红：
   `the path '/root/test/cj/cj-tauri' of module 'cjTauri' does not exist`。
   根因：`cjpm.toml` 是被跟踪文件，而 `scripts/setup.sh` 用 sed 把当前机器的路径写进去——
   谁跑过 setup 谁的本机路径就进 commit。
   处置：`cjpm.toml` 的 `dependencies.path` 与两处 `target.*.link-option` 全部改成 `${CJ_TAURI_ROOT}`
   （2026-10-30 实测 cjpm 对两处都展开）；`setup.sh` 从「sed 改写被跟踪文件」改为**环境体检 +
   检查仓里没有本机路径**。仓从此不含任何人的本机路径。

3. **R2-PORT-010 可以越过 R2-PORT-009 生效**（中高）
   现象：009 因故跳过（工程里没有 `fn run()`）时，010 照样在 `.setup()` 里插
   `install_panic_hook(app);` → 用户工程报 `cannot find function install_panic_hook`。
   处置：010 以 009 注入的 `fn install_panic_hook(` 为前置条件，缺则降 guide（给出模板但不动代码）。

4. **R2-PORT-002 会静默改行为 / 改坏文件**（中）
   现象 A：`tauri = { version = "2", default-features = false, ... }` 被重写成 `{ version, features }`，
   `default-features = false` 被丢掉——用户构建行为被静默改变。
   现象 B：多行 features（`features = [` 后接若干行）只匹配首行、拿不到 `]`，
   结果丢掉用户 features 却留下续行 → **Cargo.toml 语法错误**。
   处置：新增 `otherKeysOf()` 保留不认识的键；识别多行 features 时如实跳过并转 guide。

5. **`t2h:deps` 按名字去重导致少算包数**（中）
   现象：`depsTotal` 可能小于 `Cargo.lock` 的真实包数——直接违反 P3 出口判据 3。
   根因：按 crate 名去重，但同名多版本（bitflags 1.x/2.x）是 Cargo.lock 的常态。
   处置：改成「名字+版本」去重（`dedupeByNameVersion`）。

6. **`[patch.*]` 子表解析污染「已处置」集合**（中）
   `[patch.crates-io.tauri]` 形态下，表内的 `git` / `rev` 被当成 crate 名进结果集，
   而段头里的真名 `tauri` 反而漏掉 → 既可能误判"已处置"，也可能漏掉真正的 fork 替换。
   处置：从段头提取 crate 名，跳过 `git/rev/branch/tag/path/version/package/features/default-features/optional`。

7. **`t2h:decisions` 返回改前的旧列表**（低）
   record 成功后返回体与 `accepted/ignored` 计数仍在用旧 `items`——刚点「采纳」界面却显示「已决策 0」。
   处置：落盘成功后把 `items` 换成新表。

### Changed

- 备份文件名/目录改为 `src/port/port.cj` 的常量、由 apply 与 revert 共用——这次漂移的根因就是"两处各写一遍路径"。
- `scripts/setup.sh` 改为体检脚本（见 Fixed 2）：校验 `CANGJIE_HOME / CANGJIE_STDX / CJ_TAURI_ROOT`、
  检查 cj-tauri CLI 是否已编、检查 `cjpm.toml` 里没有本机绝对路径，**不再修改任何被跟踪文件**。
- 新增 `src/tests/port_revert_test.cj`（6 例）与 `src/tests/deps_review_test.cj`（4 例）：
  每条修复一个用例，用例写的是「修复前必然红」的断言（路径映射、保留键、多行 features、
  同名多版本、子表 crate 名）。

### Docs（虚高数字校准 —— 交付凭证必须可复算）

| 位置 | 原写法 | 实际（按 `git grep -c '^@Test'` 逐版本核对） |
|---|---|---|
| 0.10.0 单测 | 「7 例新单测／总 63」 | **6 例／总 56** |
| 0.12.0 单测 | 「5 例新单测／总 74」 | **5 例／总 69** |
| 0.13.0 单测 | 「8 例新单测／总 82」 | **8 例／总 77** |
| 0.13.0 指纹库 | 「15 条（FP-001~015）」 | **13 条（FP-001~007 + FP-010~015）**——FP-008/009 从未存在 |

- 0.11.0 的「总 64」复核无误（56+8）。
- 空位编号 FP-008/009 **不补编**（凭空补两条会违反"规则库不凭空编"）；保留编号可追溯性。
- 本轮新增 10 例 → 当前 **87 例单测**。

### 已知限制（本轮审核发现但未改，如实登记）

- **指纹库里有 3 条 marker 过泛**：FP-003 `linker \``、FP-005 `unresolved import`、FP-007 `custom-protocol`
  会在不相关的报错上命中并给出"很确定"的根因。它们仍是有用线索，但**结论需人复核**；
  收紧它们要真实日志语料（P5 交叉编译后才会有），现在不凭空改。
- `R2-PORT-014` 生成的 `lingqu-dialog.js/.css` 落在工程根目录（Vite 项目需自行搬进 `public/` 或 `src/`）。
- `R2-PORT-006` 只在完全没有 `[patch` 段时整段追加；已有其它 crate 的 patch 段时整条跳过，
  不会"只补缺口"（诊断里的 `suggestRerunPort` 因此对这类工程可能给不出改动）。

### 验证证据

**实机取证（Windows 桌面会话，`LINGQU_SCAN_PATH=E:\test\rust\habit-tree LINGQU_UI_PROBE=1`）**
—— 补上了本节早先缺的 `ui_report` 证据：

| 断言项 | 实测值 |
|---|---|
| 窗口 / 视口 / grid | 标题「灵渠迁移台 · Lingqu」；1264×801；`240px 652px 372px` |
| 屏数 / 当前屏 / JS 错误 | 7 / env / `errorCount=0` |
| WS 通道 | `wsState=connected`；`frames=2`，`lastFrameType=done`，回复「收到」 |
| ② 画像 | `scanR=24 scanC1=100 scanC2=100`；`scanKindRows=commands:12,events:0,plugins:0,frontend:7,platform:5`；落档 `.lingqu/scan/habit-tree.json` |
| ③ 依赖 | `depsTotal=453 depsPatch=0 depsUnavailable=0`；落档 `.lingqu/deps/habit-tree.json` |
| ④ 改造 | `portRules=14 portApplied=2 portAuto=1 portGuide=1 portDecided=0`（本机样本在 `ohos` 分支**已迁移**，故 001~007/009/011 全部按已迁移跳过；剩下正是 008 未设 `NATIVE_OHOS_SDK`→guide + 014 dialog 资源未生成→auto） |
| 自检日志 | **16/16 行完整快照**，每行带 `tag`+`ts`（修并发写前同场景出过碎片行） |

| 断言项 | 值 |
|---|---|
| 门禁 | 四道闸全绿（`scripts/test.sh -s`），build 0 warning |
| 单测 | **TOTAL=87，FAILED=0，ERROR=0**（`cjpm test` 实测输出） |
| 新增用例 | `port_revert_test.cj` 6 例 + `deps_review_test.cj` 4 例，逐条对应上面 Fixed |
| `cjpm.toml` | 无本机绝对路径（`setup.sh` 检查项；`grep` 实测 0 命中） |
| 换机器复现 | 本机（Windows）在仓库现有状态下直接四道闸全绿，不需要改任何被跟踪文件 |

---

## [0.13.0] - 2026-10-30

**主题**：P4 收官 —— T4-7 Agent 兜底闭环（错误指纹库 + 结构化补丁建议 + 六道闸校验器），
`t2h:diagnose` 命令上线。**P4 全部任务（T4-1～T4-9）完成**。

### Added

- **`src/port/diagnose.cj`（新）**——T4-7a/b：
  - **错误指纹库 13 条**（FP-001~007 + FP-010~015，与 `skills/t2h-ohos-port/references/pitfalls.md` 同源）：
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
- **8 例新单测**（总 77；0.13.1 校准，原写 82 是误记）：指纹库形态、rule 档命中与证据行号、同指纹去重、
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
| 指纹库 | 13 条（rule 7 + guide 6，FP-001~007 / FP-010~015；0.13.1 校准，原写「15 条」有误），marker 全部为报错原文稳定子串 |
| 诊断匹配 | FP-001/002 主路径命中 + 证据带日志行号；同指纹去重；无命中返回空 |
| 六道闸 | 白名单外/禁碰文件/多文件/大段删除/空补丁/超轮次/超失败全部拦截；干净补丁放行 |
| 门禁 | 四道闸全绿，**77 例单测** |

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
- **5 例新单测**（总 69；0.13.1 校准，原写 74 是误记）：接线插入位置与幂等、无 setup 块 guide、对话框资源形态、
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
- **8 例新单测**（总 64，复核无误）：两套工具链模板、SDK 路径替换、注入块形态、分档计数、
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
- **6 例新单测**（总 56；0.13.1 校准，原写「7 例／总 63」有误）：六条全应用 / 变换内容逐项断言 / 幂等二次跑 /
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
