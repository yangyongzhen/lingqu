# AI 自动进化飞轮（Lingqu Flywheel）

> **一句话**：让**干迁移的那个 agent** 把自己踩的坑、遇到的不认识错误写进落档；
> 下一轮迁移**自动吃上**这些经验；人只做一次"这经验靠不靠谱"的裁决。
> 版本：**0.39.55**（2026-11-02）｜代码入口：`src/notes.cj`、`src/diagnose_miss.cj`、`src/autoport.cj`、`src/port/diagnose.cj`
> 相关文档：`AGENTS.md` §0.1（方向定盘星 D-015）· §4-113~119（本轮踩的坑）· `docs/进度记录.md` 0.39.55 节

---

## 0. 为什么这是本项目最有价值的一块

迁移工具的通病是**每次迁移都从零开始**：这次的报错、这次的绕法，写在会话里、日志里、人的脑子里，
下一个应用再来一遍，还是从零查。项目三条验收标准（A1 五个样本、A3 人工介入 ≤5、A4 可用率 ≥80%）
**全都是"重复劳动越少越好"**，所以"经验能不能复用"不是加分项，是主线。

飞轮要解决的就是这件事，而且它有一个明确的分界：

| 层 | 谁来产生 | 0.39.54 之前 | 0.39.55 之后 |
|---|---|---|---|
| **事实层**（落档 / 轨迹 / 报告） | 工具自动 | 已经是全自动 | 不变 |
| **经验层**（这个坑是什么、怎么修的） | **agent 自己写** | 只在会话里，**会话压缩就丢**（实测「21/24/30 条早期消息 → 摘要」） | **落盘**：`<工程>/.lingqu/notes/<工程>.md` |
| **认知层**（指纹 / 规则 / 技能 / §4） | 人（或人确认的 PR） | 每轮手写 | 由经验层的候选**喂料**，人只做裁决 |

一句话记住纪律：**机器负责"发现 + 攒证据 + 提议"，人负责"这条能不能进库"。**

---

## 1. 飞轮长什么样

```
              ┌──────────────────────────────────────────────────────────┐
              │                 ① 迁移现场（agent 真在干活）              │
              │   t2h:autoport_start → 任务书 → cjh 逐步骤跑 8 步流水线   │
              └───────────────┬──────────────────────────┬───────────────┘
                              │ 每步都落档               │ 撞坑：报错/重试/换方案
                              ▼                          ▼
              ┌───────────────────────────┐  ┌──────────────────────────────────┐
              │ ② 事实层（自动，客观）     │  │ ③ 经验层（agent 自述，主观）      │
              │ .lingqu/<步骤>/<工程>.json │  │ lingqu-cli notes --action append  │
              │ .lingqu/agent/trace.jsonl  │  │   → .lingqu/notes/<工程>.md       │
              │ .lingqu/report/*.{md,html} │  │   （四段 + 次数，同标题只累加）    │
              └───────────────┬───────────┘  └──────────────┬───────────────────┘
                              │                             │
                              │ ④ 不认识就攒证据（自动）      │
                              │ t2h:diagnose 未命中指纹 →     │
                              │ .lingqu/diagnose/misses.jsonl │
                              │ （归一签名 + 次数 + 样例）    │
                              ▼                             ▼
              ┌──────────────────────────────────────────────────────────┐
              │ ⑤ 候选池（机器提议，人裁决）—— 唯一的人工闸门             │
              │  · notes：次数 ≥2 且四段齐全                              │
              │  · misses：同签名 ≥3 次 → 「建议补指纹」                  │
              └───────────────┬──────────────────────────────────────────┘
                              │ 人（或人评审的 PR）确认
                              ▼
              ┌──────────────────────────────────────────────────────────┐
              │ ⑥ 认知层（固化，长期资产）                                │
              │  指纹库  fingerprintLibrary()  FP-001…FP-024              │
              │  规则库  R2-PORT-001…017                                  │
              │  技能库  skills/t2h-ohos-port/{SKILL.md,references/*}     │
              │  坑清单  AGENTS.md §4（1…119）                            │
              └───────────────┬──────────────────────────────────────────┘
                              │ ⑦ 回流：t2h:skill 装进 ~/.cjh/skills/
                              │     + 任务书写清该查什么
                              ▼
                   下一轮 ① （同一个 agent，但"知道得更多"）
```

**闭环判据**：飞轮转起来的证据不是"我们写了文档"，而是——
下一个样本撞上同一个坑时，**agent 一次就拿到修法**（指纹命中 / 技能里写着），
或者**人工介入次数下降**（A3），或者**轮次预算没被烧光**（§4-113 那类"白试 40 轮"不再发生）。

---

## 2. 七个环节的接口（照着能复现）

### ① 迁移现场：把任务书换成"带经验契约"的任务书

- 入口：`t2h:autoport_start`（页面「🤖 开始 AI 自动迁移」）→ 生成任务书 → 送进 cjh。
- 任务书在 `src/autoport.cj` 里拼，**路径一律绝对**（§4-70：agent 的 bash cwd 是目标工程）。
- **任务书层有独立规范**：[`docs/任务书规范.md`](任务书规范.md)——18 个必备小节、各自触发条件、
  缺了会怎样、新增能力该写在哪一层。改任务书**先读它**；改了小节的文案/增删，规范 §3 与本文档都要同步
  （`src/tests/directive_spec_test.cj` 读真实文档断言，漏了会红）。
- 0.39.55 起任务书里多了一节**「把踩到的坑记下来（必做，只记真发生过的）」**，
  并明确"内容写文件、别写进命令行参数"（理由见 §6 的 §4-119）。
- 同时任务书保留"判断只认落档"（§0.1 的判据）：agent 说迁好了不算。

### ② 事实层：已经自动，不用人管

| 产物 | 位置 | 谁消费 |
|---|---|---|
| 每步判定 | `<工程>/.lingqu/<步骤>/<工程>.json`（scan/deps/port/build/hap/sign/deploy/verify/report） | 断点板、报告、风险分级、`t2h:resume` |
| 同名日志 | `.lingqu/<步骤>/<工程>.log` | agent 排查（"先读最后 40 行"） |
| agent 轨迹 | `<工程>/.lingqu/agent/trace.jsonl` | 停滞判定（`autoportSnapshotWith` 把行数编进签名，避免"分钟级编译被误判为绕圈"） |
| 迁移报告 | `.lingqu/report/<工程>.{md,html,json}` | 人看结论 + 风险等级（0.39.47） |

### ③ 经验层：agent 自己写（`t2h:notes`）

**命令**（`src/notes.cj` + `src/main.cj` 的 `NotesCommand`，命令行 `lingqu-cli notes`）：

```bash
# 推荐路径：内容走文件（中文参数在 Windows 过不了 argv，§4-119）
cat > .lingqu/note-in.json <<'EOF'
{"title":"一句话标题","symptom":"看到的报错/现象","cause":"你判断的根因",
 "repro":"复现命令或落档位置","fix":"你实际怎么修好的"}
EOF
lingqu-cli notes --action append --path . --body .lingqu/note-in.json

lingqu-cli notes --path . --action list      # 看这个工程攒了多少条
lingqu-cli notes --path . --action export    # 整份 markdown（给报告/人看）
lingqu-cli notes --path . --action suggest   # 筛候选 + 出 PR 草稿（0.39.56，见 §8 阶段 1）
lingqu-cli notes --path . --action archive   # 已入库的移出候选池 + 台账滚动（0.39.56）
```

**落档格式**（`<工程>/.lingqu/notes/<工程>.md`，人可读、机器可解析；`- 入库：` 行只在该条已沉淀后才出现）：

```markdown
# 本地经验（灵渠自动收集，勿手改结构；可直接追加）

### hvigor 00308018 不是签名问题
- 现象：t2h:hap 报 00308018，日志里是 cargo tauri panic
- 根因：hvigorfile 的 tauri 钩子在非 dev 场景必然失败
- 复现：juCang 工程跑 t2h:hap
- 修法：R2-PORT-015 注掉 .afterRun(buildRustCode)
- 次数：2　工程：juCang　时间：2026-11-01T22:35:52+08:00
- 入库：FP-021          ← 人工裁决通过后才补这一行（然后 archive 会把它移出候选池）
```

**关键性质**

- **幂等去重**：去重键 = 标题（去空白 + ASCII 小写，`lessonKeyOf`）；重复时 `次数` 累加、
  其余字段**以先到的为准**（第一手现场通常更准）。返回 `added:<标题>` / `merged:<标题>（第 N 次）`。
- **只记真事**：空标题直接 `error:` 拒绝写盘；任务书里也写"别记『我猜可能』"。
- **不自动进技能库**：这是**故意**的（见 §5）。
- 报告集成：`MigrationFacts.lessonCount / lessonsLine` →「做了什么」多一行「本地经验 N 条（标题…）」，
  「需要你做什么」多一行复核提示，产物清单列出 `.lingqu/notes/<工程>.md`。

### ④ 未命中证据层：`t2h:diagnose` 的 misses 台账

原来 `t2h:diagnose` 没命中指纹就只回空数组——"这条错误没人认识"**不留痕**，下个样本再从零查。现在：

```
日志 → missSignatureOf(logText)  → 归一签名（数字/长数折叠成 #、空白压一格、ASCII 小写、截断 120）
     → 追加 <工程>/.lingqu/diagnose/misses.jsonl（一条一行的紧凑 JSON）
     → 同签名累计次数 → missCandidateHint(times)
```

| 次数 | 提示（原文） |
|---|---|
| 1 | 第 1 次见到这种错误——先记下（`.lingqu/diagnose/misses.jsonl`），不急着进指纹库 |
| 2 | 第 2 次见到同一种错误——可以考虑补一条指纹（现象/根因/修法三件齐全再进库） |
| ≥3 | 已出现 N 次同一种错误——**建议补指纹**：把日志里的稳定子串做成 marker，按 `fingerprintLibrary()` 的格式加一条（带单测） |

回投字段：`missSignature / missCount / missHint / missLedger`（页面与命令行都能看到）。

**为什么用"归一签名"而不是原文**：同一个错误每次带的路径、行号、字节数都不同；
不归一就永远是"新错误"，攒不出次数（这条是实测出来的，见 §6 的 bug ②）。

### ⑤ 候选池：机器提议，人裁决

| 来源 | 成为"候选"的条件 | 人怎么处理 |
|---|---|---|
| `notes` 里的经验 | `次数 ≥ 2` 且四段（现象/根因/复现/修法）齐全 | 判断是不是普遍坑：是 → 进 `skills/t2h-ohos-port/references/pitfalls.md` 或合并进 `AGENTS.md` §4 |
| `misses.jsonl` 的签名 | 同签名 ≥3 次 | 做成一条 `Fingerprint`（marker 用稳定子串）+ 单测 + 可能落到一条 `R2-PORT-*` 规则 |
| 规则/指纹引出的新事实 | 新样本暴露的机制差异 | 改规则 → 带单测 + 回滚表（`revertPairs()`，§4-33） |

**红线**：候选池到认知层这一步**不允许全自动**（理由是成本不对称——见 §5）。

### ⑥ 认知层：固化成长期资产

| 资产 | 位置 | 规模（0.39.111） | 下一轮怎么被吃上 |
|---|---|---|---|
| 错误指纹库 | `src/port/diagnose.cj` 的 `fingerprintLibrary()` | **FP-001…FP-024**（22 条；008/009 是空位，从未存在） | `t2h:diagnose` 命中即给修法，**不调模型**（省轮次） |
| 机械改造规则 | `src/port/*.cj` + `src/main.cj`（`R2-PORT-001…017`） | **17 条**，auto / guide 两档（017 只报不写） | `t2h:port` 直接改；guide 档计一次人工介入（A3 口径） |
| 技能库 | `skills/t2h-ohos-port/SKILL.md` + `references/{cargo-patches,toolchain,arkweb-shims,signing,pitfalls,native-ui-bridge,plugin-adaptation,startup-and-first-screen}.md` | 1 技能 + **8 参考**（0.39.136：新增 `startup-and-first-screen.md`——启动四连坑） | `t2h:skill` 装进 `~/.cjh/skills/t2h-ohos-port.md`（正文进 **system prompt**） |
| 坑清单 | `AGENTS.md` §4 | **196 条**（编号到 §4-205，中间有留给保留项的号） | 人和 agent 都读；改代码前的对照表 |

**同源不是靠纪律，是靠单测**（0.39.111）：指纹库里出现的**唯一错误码**（全数字、≥7 位，如 `9568322`）
必须能在 `references/*.md` 里查得到——`fingerprintDocGapsOf()` 把它做成纯函数，
`testRealReferencesCoverEveryFingerprintCode` 读真实文档断言"缺口为空"。
此前这条链路只写在注释里（"与 pitfalls.md 同源，改动两边同步"），实测**已经在漂移**
（`FP-020` 正文里的 `00308018` 在六个 reference 里一个都没有）。

技能安装的细节（`src/skill_install.cj`，照 cjh 既有约定，不自创）：

- 正文里的 `references/x.md` 相对链接会被**改写成绝对路径**（agent 的 cwd 在目标工程，相对路径必然读不到）；
- references 放 `<skills>/.t2h-ohos-port/references/`（`.` 开头 → 不会被当成第二个技能）；
- `enabled_skills` 为空 = 全部启用，所以默认**不动 `settings.json`**；
- 状态判定用**内容 SHA256**（时间戳会被 checkout/复制骗过）。

### ⑦ 回流：下一轮自动吃上

两件事必须同时成立，否则"沉淀"只是文档：

1. 技能装进 cjh（`t2h:skill`，system prompt 里有它）；
2. 任务书里写清**遇到什么该查什么**（例如"看到 `cc-rs … "cc" …` 先查 `[env]`，别改 Rust 源码"）。

---

## 3. 数据结构速查

| 结构 | 形态 | 说明 |
|---|---|---|
| 经验（`LessonNote`） | markdown 段落 | `title/symptom/cause/repro/fix` + `occurrences/project/at`；解析宽容（缺字段留空、不抛） |
| `--body` 输入 | 单对象 JSON | 只认五个键：`title/symptom/cause/repro/fix`；坏 JSON / 非对象 / 类型不对 → 全空，标题空则拒绝写盘 |
| misses 台账 | **JSONL，一条一行** | `{"ts":…,"sig":…,"sample":…}`；**必须紧凑**（见 §6 bug ③） |
| 计数 | `missCountOf(ledgerText, sig)` | 按行比对，紧凑与美化两种形态都认 |

---

## 4. 度量：飞轮到底转没转

| 指标 | 怎么看 | 期望方向 |
|---|---|---|
| 本地经验条数 | `lingqu-cli notes --path <工程> --action list` → `count`；或报告「做什么」那一行 | ↑（说明 agent 真在记） |
| 未命中重复次数 | `<工程>/.lingqu/diagnose/misses.jsonl` 里同签名行数 | 补完指纹后同签名**应停止增长**（= 真的吃上了） |
| 指纹 / 规则条数 | `fingerprintLibrary()` 条数、`R2-PORT-*` 条数 | 缓慢 ↑（只进真通用的） |
| 人工介入 | `<工程>/.lingqu/port/<工程>/decisions.json` 的 `humanAccepted/humanIgnored`（A3） | ↓ |
| 可用率 | `.lingqu/verify/<工程>.json` 的 `ratePercent`（A4） | ↑ 或持平 |
| 烧轮次 | agent 回合的 `rounds/tools`、`.lingqu/agent/trace.jsonl` 行数 | 同一个坑**下次用更少轮次** |
| 风险等级 | 报告 `reportRisk`（0.39.47） | 高 → 中 → 低 |

**反例判据（看到就说明飞轮空转）**：
`notes` 一直是 0 条（agent 没在记）· 同一个签名在 `misses.jsonl` 里涨到 10 次还没人补指纹 ·
报告里"经验 N 条"每次都是同一批（说明没有新样本）· 人工介入次数不降（经验没被吃上）。

---

## 5. 纪律与反例（这块比代码重要）

1. **认知层不许全自动写**。指纹与规则会**直接指挥 agent 改用户工程**（`t2h:port` 会动 `Cargo.toml`、
   `lib.rs`、`hvigorfile.ts`）。一条没人看过的规则进了库 = 让陌生规则改别人的仓库，代价不对称：
   人复核一条规则 5 分钟，一条错规则毁掉一个样本的可信度。
2. **不自动覆盖本地 `skills/`**。技能正文进 **system prompt**，热替换 = prompt 漂移：
   行为变了但没人知道为什么、也难复现（这是本项目一贯的"异常/行为变化必须有可解释来源"）。
   要更新就"下一次启动生效"，不在会话中途换。
3. **只记验证过的事**。`notes` 是"我跑过、我看到"的记录，不是猜测池；四段里的「修法」必须是**实际生效**的那个。
4. **次数是可信度的代理**。一次偶然不是经验——候选门槛 `≥2`（notes）/`≥3`（misses）不是随手定的：
   1 次可能是我把命令写错，3 次基本就是系统的脾性。
5. **落档说了算**（§0.1）。经验写"修好了"不算数，要 `.lingqu/<步骤>/<工程>.json` 的判定字段也过。
6. **不编数据**（§4-94 / §4-95）。没有经验就写「0 条」或干脆不显示，不许写个示例值糊过去。
7. **台账要能长大，也要能收拾**：`misses.jsonl` 到 200 行整体归档（0.39.56，`MISS_ROLL_MIN_LINES`）；
   `notes` 已入库条目由 `archive` 移出候选池。真实累积节奏仍待样本检验（见 §6.3）。

---

## 6. 已知边界与踩过的坑（这一节是"真话"部分）

### 6.1 硬限制：Windows 上仓颉程序接不了非 ASCII 的 argv（`AGENTS.md` §4-119）

```text
main.exe --help 中文  →  IllegalArgumentException: Invalid unicode scalar value   （PowerShell / cmd）
                       →  IllegalArgumentException: Invalid utf8 byte sequence     （Git-Bash）
```

- 异常在 `main(args: Array<String>)` **之前**抛，三种调用方一致，`chcp 65001` 无效 ⇒ **不是业务代码的问题**。
- 影响：凡"中文内容当参数"的用法全废——经验正文、中文标题、中文工程路径。agent 的 bash 同样中招。
- 处置：**内容走文件**（`--body <json>`），路径本身保持 ASCII。**Linux 未验**（那边 argv 是字节流，大概率没这问题）。

### 6.2 单测当场抓出的三个真 bug（都过编译、跑起来必错）

| # | 现象 | 根因 | 现在怎么做 |
|---|---|---|---|
| ① | 中文标题一进合并就崩 | `lessonKeyOf` 逐字节 `String.fromUtf8([b])`，单个字节不是合法 UTF-8（§4-116，与 §4-113 同族） | 攒 `ArrayList<Byte>` 后整体解一次 |
| ② | `project` 变成 `juCang　时间：2026-11-02 …` | `fieldAfterSpace` 取到行尾，没在全角空格 `　` 截断（§4-118） | 按 `　` 截断 |
| ③ | 台账里同签名累计次数**永远 1** | `JsonObject.toJsonString()` 是**美化输出**（一条记录 4 行、冒号带空格）⇒「一条一行 + 按行计数」不成立（§4-117） | 手拼紧凑 JSONL + 读侧两种形态都认 |

### 6.3 还没验证的事（不许说成"已验证"）

- ~~agent 在真实迁移途中会不会真去调 `notes append`~~ → **已验证（0.39.65 前后，rust-music 迁移）**：
  agent 在迁移途中用编辑工具真实写入 `.lingqu/notes/rust-music.md`（截图 `docs/imgs/flywheel_shortcut.png`）；
  但**跨多个样本的稳定执行率**仍待统计（单样本证据 ≠ 每轮都照做）。
- `misses.jsonl` 目前只有单测造的数据，**还没有真实样本**（要 `t2h:diagnose` 真未命中才写）。
- 经验→技能条目的**映射规则**已写成文档（`docs/经验入库规则.md`，0.39.56），但**还没被第一批真实候选走一遍**。
- `misses.jsonl` 归档阈值（200 行）未在真实累积节奏下检验过。

---

## 7. 怎么证明它工作（可复核清单）

```bash
# 1. 单元测试（纯函数 + 落档往返）
cd <lingqu> && ./scripts/test.sh        # 六项全绿；单测 387 例（其中 src/tests/notes_test.cj 15 例）

# 2. 真 CLI 走一遍（中文内容走文件）
cat > .lingqu/note-in.json <<'EOF'
{"title":"hvigor 00308018 不是签名问题","symptom":"t2h:hap 报 00308018，日志里是 cargo tauri panic",
 "cause":"hvigorfile 的 tauri 钩子在非 dev 场景必然失败","repro":"juCang 工程跑 t2h:hap",
 "fix":"R2-PORT-015 注掉 .afterRun(buildRustCode)"}
EOF
./cli/target/release/bin/main.exe notes --path .lingqu/notes-probe --action append --body .lingqu/note-in.json
# 期望：{"ok":true,"result":"added:…","bodyUsed":true,"count":1}

# 3. 幂等：同标题再跑一次
# 期望：{"ok":true,"result":"merged:…（第 2 次）","count":1}      ← 条数不变、次数 +1

# 4. 落档复核
cat .lingqu/notes-probe/.lingqu/notes/notes-probe.md

# 5. 台账计数（纯函数有单测；真跑要制造一次未命中指纹的错误）
# <工程>/.lingqu/diagnose/misses.jsonl 应出现一条一行紧凑 JSON
```

**本轮实测记录（0.39.55）**

```text
cjpm build      → 0 warning
cjpm test       → TOTAL=387, FAILED=0, ERROR=0
scripts/test.sh → 六项全绿：build-biz / test / check / js-syntax / build-app / build-cli
cj-tauri sync desktop + sync ohos → check 通过：com.lingqu.migrator@0.39.55
真 CLI --body   → added:hvigor 00308018 不是签名问题 / bodyUsed=true / 落档中文逐字正确
```

---

## 8. 演进路线（下一步做什么）

### 阶段 1：候选池做成可操作的东西（不联网，最安全）—— ✅ **0.39.56 已完成**

- ✅ `t2h:notes --action suggest`：按 `次数 ≥ 2` + 四段齐全 + 未入库筛候选，写
  `<工程>/.lingqu/notes/<工程>-candidates.md`（`--out` 可指定），每条配一段 **PR 正文草稿**
  （`renderPrDraft`：现象/根因/复现/修法 + 次数/工程 + 建议落点 + **提交前三问** + 三段式填空模板）；
  未命中台账里**同签名 ≥3 次**的也一并列出。
  ~~产出 `docs/skills-候选.md`~~ → 改到**工程自己的 `.lingqu/notes/`** 下（落档纪律：证据跟着工程走）；
  要放到仓里看，用 `--out docs/skills-候选.md`。
- ✅ `t2h:notes --action archive`：打了 `- 入库：<引用>` 的条目挪到 `<工程>-archived.md`（先写归档件再改主文件）；
  `misses.jsonl` 到 **200 行**（`MISS_ROLL_MIN_LINES`）整体挪到 `diagnose/misses.<时间戳>.jsonl`。
- ✅ `docs/经验入库规则.md`：三条件 + 人的三追问、四个去处与选型判据、四段 → `pitfalls.md` 三段 的映射与完整示例、
  回写标记与归档流程、命令与回包字段、七条反例、PR 前复核清单。

**实测（0.39.56，`.lingqu/notes-e2e` 探针工程）**

```
种子：一条四段齐全出现 2 次 / 一条只有标题 / 一条完整但只出现 1 次；台账 4 行（同签名 3 次 + 另一个 1 次）
suggest → candidateCount=1  missCandidateCount=1  lessonTotal=3  missLedgerLines=4     ← 门槛三层都生效
手工补 `- 入库：FP-021` → suggest → candidateCount=0（已入库不再提议），指纹候选仍为 1
archive → archivedNotes=1 keptNotes=2  notesNote="ok:归档 1 条，主文件保留 2 条"
          missNote="台账 4 行，未到 200 行阈值，不归档"（不假装归档）
```

**实测（0.39.108，一次真实入库的链路走位）**

m3u8dl-tauri 的 picker 缺口修完后，经验**没有停在会话里**，按「经验入库规则」的四个去处分别落位：

| 去处 | 本轮实际落点 | 选它的理由 |
|---|---|---|
| 规则 | `R2-PORT-017`（脚手架，**下一轮**） | 只有**可枚举的机械改造**才配进规则；桥的命名与命令语义要判断，留给 agent |
| 指纹 | `FP-022`（marker `openharmony_ability`） | 能被**报错原文唯一认出**才进指纹表；`Permission denied` 这类泛串会污染匹配顺序，只进技能与坑表 |
| 技能 reference | `references/native-ui-bridge.md` + `pitfalls.md` 14/15 | 需要判断的形态选择（三种返回值形态、uri 语义） |
| AGENTS §4 | §4-162~164 | 跨样本复现的**结构性问题**写进坑表，附三条判据 |

这条链路的**验收不是"文档写了"**，而是**换一个带原生 UI 的工程重跑 `autoport`**，看 agent 是否按任务书那一节动手——
与 §4-164 的判据一致：文档存在 ≠ agent 会用（§4-150）。

### 阶段 2：半自动 PR（人只点"提交"）—— ✅ **0.39.58 已完成**

- ✅ `t2h:pr_prepare`（`src/pr_prepare.cj` + `PrPrepareCommand`，三处联动）：把候选整理成
  一个分支的**草稿 PR 产物**，正文自动带证据链：标题 / 现象 / 根因 / 复现（哪个样本、哪条命令）/
  修法 / 出现次数 / 关联指纹或规则；
- token 只走环境变量，**绝不落 `settings.json`**；`canSubmit=true` 路径**没有真发 PR**
  （token 只探测不使用，提交动作永远在人手里）；
- 实测与未验证细节见 `CHANGELOG.md` 0.39.58。

### 阶段 3：防失控护栏（自动提交真发 PR 仍除外）—— ✅ **0.39.59 已完成，§8 阶段 1–3 至此全部落地**

- ✅ 三道栏杆：**单轮上限** / **同类去重** / **启动刷新语义**（不热替换 `skills/`，见 §5-2）；
- 合并仍要人/CI 评审——"永远不做"清单（自动合并、自动覆盖 `skills/`、把"AI 认为有价值"当评审结论）不变；
- 细节见 `CHANGELOG.md` 0.39.59。

**飞轮机制层面已全部落地（0.39.59 起）；剩下的不是写代码，而是闭环验证**：
推更多真实样本 → 撞真实坑 → `notes` / `misses` 攒出真实数据 → 人裁决入库 →
下一个样本**少烧轮次**（§4 的度量方向真正被观测到）。

### 阶段 4：用户级认知层（不登录、不贡献，飞轮照样转）—— ✅ **0.39.113 已完成，§8 阶段 1–4 至此全部落地**

**问题**（2026-11-03 用户提出）：指纹库 / 规则库编译在代码里、skills 在仓里——用户裁决
"这条经验值得入库"后，如果**没登录 atomgit 或不想给 lingqu 源仓提 PR**，经验就只对当前
工程有效，不会变成"下次迁别的工程自动吃上"的全局认知。**贡献公共仓是可选的"分享"，
本地飞轮必须是默认的"自用"**——两条轨道要分开。

**方案：裁决入库的去处从"一个"变成"三个"**

```
裁决（人工闸门）后的去处：
  ① 本工程 notes（已有，不变）
  ② 用户级认知层 ~/.lingqu/flywheel/（新增，离线、零登录）——本阶段主体
       fingerprints.json / rules.json / skills/
       加载顺序：内置库 + 用户库合并（用户级追加，id 冲突时用户级优先）
  ③ 公共仓 PR（可选，想分享才走；t2h:pr_prepare 的 degraded/canSubmit 双轨已就绪）
```

**实现落点（都很薄，纯函数可单测）**：

| # | 改动 | 位置 |
|---|---|---|
| 4.1 | **加载合并**：`diagnoseLog` / 规则匹配先查用户库（`~/.lingqu/flywheel/fingerprints.json`、`rules.json`）再合并内置库；用户库格式与内置同构（`Fingerprint` / 规则条目的 JSON 形态），id 冲突用户级优先 | `src/port/diagnose.cj` 的 `fingerprintLibrary()` + 规则加载 |
| 4.2 | **裁决动作扩展**：候选池 `archive` 加目标参数（`--to user` 默认 → 写用户级认知层；`--to repo` → 走既有 `t2h:pr_prepare` PR 草稿）——**"入库"不再等于"改 lingqu 源码"** | `src/notes.cj` 的 `archiveLessons` |
| 4.3 | **回流复用现成件**：用户级技能照走 `t2h:skill` → `~/.cjh/skills/`（机制已有，零新增） | `src/skill_install.cj`（不改） |
| 4.4 | **（可选）团队共享**：`~/.lingqu/flywheel/` 整目录可拷贝 / 同步到团队私有仓——共享经验也不需要公共贡献 | 无代码，文档说明 |

**与"永远不做"清单的关系**：不冲突且互补——阶段 4 让"不贡献的用户"也有完整飞轮；
PR 路线照旧是人只点提交；认知层仍不许全自动写（用户级入库同样要过人工闸门）。

**及格判据**：不登录任何平台，全程离线完成"迁移 → 撞坑 → 经验 → 裁决入库 → 下一个
工程 diagnose 命中用户级指纹"整链；单测覆盖加载合并（用户级优先/追加/格式容错）与
archive 双目标。

**落地口径（0.39.113 实际做了什么）**

| # | 落点 | 实际形态 |
|---|---|---|
| 4.1 | `src/flywheel.cj` + `src/port/diagnose.cj` | `fingerprintLibrary()` 不动，新增纯函数 `mergeFingerprintLibraries(内置, 用户)` / `fingerprintLibraryWithUser(json文本)` / `nextUserIdOf`；`t2h:diagnose` 与 `migrate` 内的诊断都走合并库，回投 `userFingerprints` / `librarySize` / `userFingerprintsDir` |
| 4.2 | `t2h:notes --action archive --to user\|repo` | `user`（默认）= 并入 `~/.lingqu/flywheel/lessons.md`（`unionUserLessons` 去重、**不累加次数**）；`repo` = 留在候选草稿等提 PR，**不写用户级**；`--to` 认不出 → `ok=false` 并说明 |
| 4.3 | 无代码 | 技能回流仍是 `t2h:skill` → `~/.cjh/skills/`；`~/.lingqu/flywheel/skills/` 只留位与说明 |
| 4.4 | 无代码 | `~/.lingqu/flywheel/` 整目录可拷/同步到团队私有仓（`LINGQU_FLYWHEEL_DIR` 指过去即可） |

**诚实边界（这条别在后续版本里被"顺手放宽"）**：用户级层**只装能合并的东西**——指纹（JSON 数据）
与经验/技能（文本）。`R2-PORT-*` 规则是确定性的**文本变换函数**（`src/port/port.cj`），
一份 JSON 没法安全执行它 ⇒ **规则仍只能改仓**（`--to repo` 出草稿）。
把安全边界让给"便利"，换来的不是飞轮，是"用户下载一份别人写的 JSON 就能改我的源码"。

**实测（0.39.113，全程离线：不登录、不联网）**

```
$ LINGQU_FLYWHEEL_DIR=E:/tmp/lingqu-fw-probe lingqu-cli notes --action fp-add --body E:/tmp/fp-body.json --path E:/tmp/lingqu-proj
  ok:E:/tmp/lingqu-fw-probe\fingerprints.json（新增 1 / 覆盖 0 / 共 1 条）
$ lingqu-cli notes --action fp-list --path E:/tmp/lingqu-proj
  合并库 22 条（用户级 1 条）@ E:/tmp/lingqu-fw-probe
$ lingqu-cli diagnose --path E:/tmp/lingqu-proj --log "boom LINGQU-PROBE-MARKER happened"
  hits[0].fingerprint = { id: FP-U001, marker: LINGQU-PROBE-MARKER, patchKind: guide }   ← 用户级指纹命中
$ lingqu-cli notes --action archive --to user --path E:/tmp/lingqu-proj
  archivedNotes: 1 / to: user / userNote: ok:…\lessons.md（用户级经验 1 条，本次新增 1）
$ cat E:/tmp/lingqu-fw-probe/lessons.md        ← 四段完整落进用户级经验本，头部写明"重跑不虚增"
```

单测 `src/tests/flywheel_test.cj`（19 条）：覆盖目录解析（两种分隔符 / home 为空**不回落 CWD**）、
用户库 JSON 容错（坏 JSON / 少 marker / `patchKind` 缺省按 guide）、合并优先级（用户级排前 + 同 id
用用户版本 + 同批重复只取先写的）、`upsert` 幂等（重跑只能"覆盖 N 条"、不许"又新增 N 条"）、
`fp-add` 的 body 自动编号与批内不撞号、经验本去重不虚增次数。
`TOTAL=564，FAILED=0，ERROR=0`；五道闸全绿。

**未验证**：Linux 侧（本机只有 Windows）；`--to repo` 与 `t2h:pr_prepare` 尚无自动联动（人工把草稿
挪进 PR 产物），这一步仍靠人。

---

## 9. 和其它文档的关系

| 文档 | 与本文的关系 |
|---|---|
| `AGENTS.md` §0.1（D-015） | 方向：cjh 是执行者，工具是它的手 —— 飞轮是这个方向在"学习"上的体现 |
| `AGENTS.md` §4-113~119 | 本轮飞轮落地踩的坑（逐字节 UTF-8 / 美化 JSON / 全角空格 / 非 ASCII argv） |
| `src/notes.cj` / `src/diagnose_miss.cj` / `src/tests/notes_test.cj` | 经验层与台账的实现与单测 |
| `src/skill_install.cj`（`t2h:skill`） | 认知层 → 下一轮的回流通道 |
| `src/port/diagnose.cj`（`fingerprintLibrary()`） | 认知层的指纹库；`misses` 台账就是它的候选来源 |
| `skills/t2h-ohos-port/references/pitfalls.md` | 经验固化的目标形状（构建期/部署期/验证期三段） |
| **`docs/经验入库规则.md`** | **谁改了 `pitfalls.md` / 指纹库 / 规则库之前先读它**：三条件 + 三追问、选型判据、四段→三段映射与示例、回写标记、反例、PR 清单 |
| `docs/进度记录.md` 0.39.55 / 0.39.56 · `CHANGELOG.md` 同版本 | 本轮的验证范围与未验证项（0.39.55 经验落盘与台账；0.39.56 候选池与归档） |
