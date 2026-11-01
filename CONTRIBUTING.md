# 贡献指南（CONTRIBUTING）

> 本仓是「AI 驱动的 Tauri 应用迁移到鸿蒙 PC 的工具」（灵渠 / Lingqu）。
> **先读 [`AGENTS.md`](AGENTS.md) §0.1（方向）、§1（门禁）、§4（119 条踩坑清单）**，
> 再动代码。本文只讲"参与流程"，规矩的权威定义在 `AGENTS.md`。

---

## 1. 提 issue 之前

1. 先在 [`AGENTS.md`](AGENTS.md) §4 与 [`docs/开发环境.md`](docs/开发环境.md) 里搜报错原文——
   本项目绝大多数"看起来莫名其妙的失败"都有记录（`0xC0000135`、`command not allowed`、`9538322`、`00308074`…）。
2. 真机相关的问题，请附**落档**：`<工程>/.lingqu/<步骤>/<工程>.json` + `.log` 的尾部（把本机路径里的用户名脱敏）。
3. 涉及密钥/证书口令/Token 的内容**不要**放进公开 issue → 见 [`SECURITY.md`](SECURITY.md)。

## 2. 开发流程

```bash
git clone https://atomgit.com/qq8864/lingqu.git && cd lingqu
./scripts/setup.sh          # 环境体检（只校验，不改文件）
./scripts/test.sh -s        # 六项门禁（首次派生 targets/ 骨架）
./scripts/run-dev.sh -b     # 起窗口开发
```

改完代码提 PR 前，本地必须：

```bash
./scripts/test.sh           # 六项全绿：build(零警告) / test / check / 页面脚本语法 / desktop build / cli build
git status                  # 干净（临时调试脚本别留在仓里）
```

门禁是**唯一交付凭证**，`ci` 之外没有例外。窗口在跑的时候跑门禁会被结束进程以释放产物（见 §4-72），
所以"边看边改"只跑前两道：`./scripts/test.sh -q`。

## 3. 改动规矩（摘要）

| 规矩 | 说明 |
|---|---|
| **先写红的用例，再修** | bug 修复必须提交一个能复现该 bug 的单测；修完它转绿 |
| **新增纯函数必须有测试** | 主路径 + 错误路径 + 一个边界；放 `src/tests/`，文件名 `*_test.cj`，包 `lingqu.tests`，顶层 `public func` + `@Test` |
| **只测纯函数** | 进程 / 网络 / WebView2 / 真机部署**不在单测里造假绿**，这类以实机为准并在 `docs/进度记录.md` 写清验证程度 |
| **零警告** | `cjpm build` 未使用变量/导入一律清零，不许 `-Woff` 掩盖 |
| **行为变更要有可观测证据** | 日志行 / 命令返回值 / 落档字段 / 进程状态；界面改动还要 `t2h:ui_report` 的版面断言 |
| **文档同批更新** | `CHANGELOG.md` + `docs/进度记录.md`（涉及验收项再加 `docs/需求追踪.md`）；踩了新坑 → `AGENTS.md` §4 |
| **不加 `.ps1`** | 脚本一律 bash 为准，`.bat` 只做"找 bash 再委托"（ADR D-012）；`.bat` 必须纯 ASCII，`.sh` 必须 LF |
| **不手改 `targets/`** | 那是 `cj-tauri sync` 的派生品，改了会被 `check` 判漂移 |
| **不把本机绝对路径写进仓** | `cjpm.toml` 一律用 `${CJ_TAURI_ROOT}` 等变量 |
| **不用 shell 改源码** | PS 5.1 的 `Get-Content | Set-Content` 会按 GBK 误解码并加 BOM；用编辑器或精确替换，改完 `git diff` 复核 |
| **面向用户的文本可能是中文** | 若要通过命令行参数传递，先读 `AGENTS.md` §4-119（Windows 上仓颉接不了非 ASCII argv，内容要走 `--body <文件>`） |

## 4. 常见扩展点

**加一条 `t2h:*` 命令**（三处联动，漏一处就是运行期报错）：

1. `src/main.cj`：实现 `<: CommandHandler` 并在 `build()` 里 `app.register("t2h:xxx", XxxCommand())`；
2. `assets/capabilities/default.json`：`commands` 里放行 `t2h:xxx`；
3. `assets/ui/index.html`：`tauri.invoke('t2h:xxx', {...})`（纯 agent 侧工具可以没有 UI 入口，但要在 CHANGELOG 说明）。

**加一条改造规则**（`src/port/`）：写 `RuleOutcome`（auto / guide 两档）、进回滚表（`revertPairs()`，§4-33）、
带单测，并在 `docs/需求追踪.md` 的 C3 行补证据。

**加一条错误指纹**（`src/port/diagnose.cj` 的 `fingerprintLibrary()`）：marker 取日志里的**稳定子串**
（不要带行号/路径/字节数），写"根因 + 修法"，补单测。
如果你是从 `.lingqu/diagnose/misses.jsonl` 里"同签名出现 ≥3 次"的候选提炼出来的，请在 PR 里贴那段台账。

**把一条经验变成技能条目**：经验在 `<工程>/.lingqu/notes/<工程>.md`，四段（现象/根因/复现/修法）。
提炼进 `skills/t2h-ohos-port/references/pitfalls.md` 时保持"现象 → 根因 → 修法"三段并标注实测出处；
**门槛：出现 ≥2 次且四段齐全**（设计见 [`docs/AI自进化飞轮.md`](docs/AI自进化飞轮.md) §5）。

## 5. 提交信息

```
<type>(<scope>): <一句话>

现象：……
根因：……
处置：……
证据：……（命令返回值 / 落档字段 / 日志行 / 截图路径）
```

`type` 用 `feat` / `fix` / `docs` / `refactor` / `test` / `chore`。

**注意**：多行或含引号的提交信息**写进文件**再 `git commit -F <file>`，且文件用
`[System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))` 写（不要带 BOM）。

## 6. PR 检查清单

- [ ] `./scripts/test.sh` 六项全绿（贴最后一段输出）
- [ ] 新增/修复有对应单测（修复类：先红后绿）
- [ ] 行为变更附可观测证据；界面改动附 `ui_report` 字段
- [ ] `CHANGELOG.md` + `docs/进度记录.md` 已更新；踩了新坑进 `AGENTS.md` §4
- [ ] 未验证的部分在文档里如实标注（不许把"没跑过"写成"通过"）
- [ ] `git status` 干净，无临时脚本 / 无本机绝对路径 / 无密钥

## 7. 行为准则

讲事实、给证据、不夸大。评审里最常见的两条反对意见是"这没有证据"和"这会把方向做反"
（方向见 `AGENTS.md` §0.1：**干迁移的是 agent，不是我们的代码、也不是人**）。
