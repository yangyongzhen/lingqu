# 灵渠迁移台 · 项目开发规范（AGENTS.md）

> 本文件是本项目的**开发契约**：人类开发者与 AI 助手共同遵守，由 agent 自动加载注入。
> **改代码前先读 §1 门禁与 §2 架构契约。**
> 适用版本：**0.39.113**（2026-11-11），与 `CHANGELOG.md` 同步维护。
> 当前进度见 `docs/进度记录.md`；**阶段任务与技术验收判据见 `docs/实施路线图.md`**；
> 换机器/换会话先读 `docs/会话交接.md`；需求落地状态见 `docs/需求追踪.md`；决策与理由见 `docs/设计决策记录.md`；
> **改任务书先读 `docs/任务书规范.md`**（18 个必备小节与触发条件），改认知层先读 `docs/经验入库规则.md`。

---

## 0. 项目定位

**Tauri 应用 → 鸿蒙 PC 的开箱即用一站式 AI 迁移台**。三层技术栈：

| 层 | 用什么 | 说明 |
|---|---|---|
| 外壳 / UI | **cj-tauri**（仓颉 + 系统 WebView） | 窗口、IPC、资产、能力清单、打包；桌面 = WebView2，鸿蒙 = ArkWeb |
| AI 引擎 | **cjh**（仓颉 Coding Agent Harness，进程外 web 模式） | 迁移工具链的规划/诊断/改码，走 `127.0.0.1:8765` 的 REST + WS |
| 迁移引擎 | 仓颉主导 + 外部工具编排 | 扫描 / 规则改造 / 交叉编译 / HAP / hdc 部署 / 证据采集 |

**最终验收**（课题原文，见 `docs/需求.md`）：5 个真实 Tauri 应用迁移验证、迁移分析覆盖率 100%、
单应用平均人工介入 ≤ 5 处、鸿蒙电脑上核心功能可用率 ≥ 80%、工具开源并提供迁移指南。

### 0.1 方向的定盘星：**cjh 是执行者，工具是它的手，人只在它主动要求时介入**（ADR D-015）

> **这一节是方向，不是建议。动任何东西之前先读它，做完再拿它对一遍。**
> 一句话：**干移植的是内置的 agent（cjh），不是我们的代码、也不是人。**

四个角色，别串位：

| 谁 | 是什么 | 干什么 |
|---|---|---|
| **执行者** | **cjh**（内置 agent，`127.0.0.1:8765`） | 分析、改码、重跑、判断下一步。它是干活的，**不是"失败后给建议的顾问"** |
| **手** | `t2h:*` 命令 / `lingqu-cli` / `.lingqu/` 落档 | agent 的器官。我们的职责是**把器官递到它手上并保证能用**：绝对路径、技能、工程上下文、工作区、轮次预算 |
| **人** | 使用者 | 只在 agent **主动要求**时介入（要拍板的取舍、平台限制登记、真机操作）。"单应用人工介入 ≤5 处"是**验收指标**，所以要尽量少让人点 |
| **我们（灵渠）** | 这个应用 | 只做三件事：**眼睛**（读落档做进度与停滞观测）、**手刹**（预算 / 停滞 / 一键停止）、**记录员**（人工介入次数 = A3） |

判据：**落档说了算**。agent 说"迁好了"不算，`.lingqu/<步骤>/<工程>.json` 写着通过才算。

**🚩 反例清单——看到就说明做反了，立刻停手**

- 做成"每一步一个人点按钮"的向导；让人手动跑命令再点下一步；
- 把 AI 的输出只当解释/建议，动作却由我们的代码或人来做；
- 失败时只把现场发给 AI 要一段建议，却不让它接着动手；
- 我们替 agent 决定"这一步该怎么修"（那是抢它的活）；
- 以"安全"为名，把**本该由 agent 动手**的操作锁成只能人点——注意区分：
  `cliRunAllowed` 限制的是「**界面代它执行**」，**不是**限制 agent 通过 bash 自己干。

**依赖关系（这条决定优先级）**：这条方向能不能落地，取决于 **cjh 的能力**——
器官不通，界面再漂亮也只是让人多戳几下（缺口清单见 `docs/上游回馈-cjh.md`）。

- 主路径：`t2h:autoport_*`（准备现场 → 交任务书 → 盯落档 → 停滞/预算时叫人）
- 兜底与工具：`t2h:migrate`（确定性流程，无 AI 也能跑，同时是 agent 的一只手）

---

## 1. 交付门禁（唯一交付凭证）

**任何代码变更交付前必须满足：**

1. `./scripts/test.sh`（Linux/macOS/Git-Bash）或 `scripts\test.bat`（Windows）**全绿**。**五道闸**缺一不可：
   - ① 业务包 `cjpm build` —— **零警告**（unused 变量/导入、deprecated 一律清零，禁止"先交付后清理"）
   - ② 业务包 `cjpm test` —— `FAILED: 0`、`ERROR: 0`
   - ③ `cj-tauri check` —— 清单校验 + 骨架漂移 + **能力三方比对**（声明 × 插件自述 × 实际装配）
   - ④ `targets/desktop` 的 `cjpm build` —— 骨架侧也要编得过且零警告
   - ⑤ `cli/` 的 `cjpm build` —— AI 用的命令行入口也要编得过且零警告（AI 接入第 3 步）
   - **①②④⑤ 的"零警告"是硬判据，且必须看得到明细**：`warning: N` 只报条数的检查等于没检查
     （0.39.0 实测栽过：删了调用方留下的 unused 私有函数，门禁只报「2 条」，无从定位）。
     改了函数签名/删了函数/换了实现，**必须回头查旧调用方**——原来的辅助函数、导入、常量会立刻变 unused。
2. **新增行为必须有对应测试**：新增纯函数 → 至少覆盖主路径 + 错误路径 + 一个边界；
   bug 修复 → **先写复现该 bug 的用例（红）再修（绿）**。
3. **行为变更必须给可观测证据**：日志行、命令返回值、窗口标题、进程/端口状态。
   禁止「先交付后补证据」。
4. **跑不起来就如实说明**（含「哪些平台未验证」），禁止把未验证说成通过。
5. 涉及 WebView2 / cjh 进程 / 真机部署的部分，**单元测试不造假绿**——这类以实机为准，
   并在 `docs/进度记录.md` 写清「验证到什么程度、证据是什么」。
6. **界面改动要能被自动断言**：用 `t2h:ui_report` 回投版面指标（视口 / grid 列宽 / 当前屏 /
   设置面板状态 / 模型条数 / JS 错误数），需要整段流程时置 `LINGQU_UI_PROBE=1` 让页面自跑序列。
   产物落 `.lingqu/ui-report.{json,log}`（已 gitignore）。**没有视觉也要能证明版面对**。

---

## 2. 架构契约（改哪里、怎么改）

### 2.1 三层职责，别混

```
cj-tauri.toml          应用清单——单一真相（id / 窗口 / 资产 / 能力目录）
   ↓ cj-tauri sync（派生，勿手改）
targets/desktop/       桌面 launcher    ┐
targets/ohos/          鸿蒙 HAP 工程    ┘ 都是外壳，只调 lingqu.build()
   ↓ 以 path 依赖引用
src/ + assets/         业务包：一份业务代码，两端各编各的产物
```

- `targets/` **整个目录是派生品**（`.gitignore` 已忽略，含本机绝对路径）。手改会被 `check` 判漂移并被下次 sync 覆盖。
- 要改窗口标题/尺寸/资产/能力目录 → 改 `cj-tauri.toml`，然后 `cj-tauri sync`。
- 要改业务逻辑 → 改 `src/`；要改界面 → 改 `assets/ui/`。

### 2.2 新增命令必须三处联动（漏一处就是运行期报错）

1. `src/main.cj` 的 `build()` 里 `app.register("t2h:xxx", XxxCommand())`
2. `assets/capabilities/default.json` 的 `commands` 里放行 `t2h:xxx`
3. `assets/ui/index.html` 里 `tauri.invoke('t2h:xxx', {...})`

漏 ① → `command not registered`；漏 ② → `command not allowed`；漏 ③ → 界面没入口。
`cj-tauri check` 的三方比对该报这一条——**它是门禁，不是建议**。

### 2.3 cjh 引擎托管的语义（`src/cjh_host.cj`，移植自 cj-tauri `examples/ai-chat`）

| 契约 | 内容 |
|---|---|
| 就绪判据 | 只有一条：`GET /api/health` 收到 200。没有"看着像起来了"这种模糊态 |
| 复用优先 | 8765 上已有 cjh（可能是用户自己的）就复用，**不抢不杀**，退出时也不动它 |
| 收尾归属 | 只有本应用拉起的（`gCjhOwned=true`）才在退出时终止 |
| 拉起方式 | **有隐藏控制台时继承拉起、否则 `launchHidden()`**（0.39.40）：本应用是 GUI 子系统，`std.process.launch` 会给子进程**新配**一个黑窗口；但先用 `win_console.ensureHiddenConsole()` 给自己分一个**看不见的** console 之后，继承它反而让 cjh 及其 bash/find/lingqu-cli 全都不再弹窗。规则：`ensureHiddenConsole()` 成功 → `std.process.launch`（继承）；失败 → 回落 `launchHidden`（DETACHED，绝不顶出可见窗口）。两种句柄由 `CjhHandle` 收口 |
| 绑定地址 | 自己拉起的一律 `--bind 127.0.0.1`（cjh 默认绑 `0.0.0.0` 且默认无鉴权） |
| 就绪等待 | 100ms × 10s；超时**不算成功**，只是留着进程等重试 |
| 二进制校验 | vendor 目录 4 个文件逐个 SHA256；**验不过绝不解包也不执行** |
| 退出收尾 | 守护线程 `waitForExit()` 后收；`t2h:quit` 先收再退；收 5 轮以覆盖"秒关窗口"的抢跑 |

改动这一块之前先读 `docs/设计决策记录.md` 的 D-003 / D-004，别把语义改薄。

---

## 3. 编码规范

- **仓颉**：`cjpm build` 零警告是硬要求。未使用的形参写成 `_`（`handle(_: String, _: JsonObject, _: IpcContext)`），
  不要靠 `-Woff` 掩盖。
- **测试文件**命名必须以 `*_test.cj` 结尾（发布构建会排除它），放 `src/tests/`，包名 `lingqu.tests`。
- **只测纯函数**：进程、网络、WebView2、真机部署不在单测里模拟（见 §1 第 5 条）。
- **脚本一律 bash 为准**（跨平台一份实现）：`scripts/*.sh` 是功能本体，`*.bat` 只做「找 bash 再委托」。
  理由与教训见 ADR **D-012**：`.ps1` 有三大坑（无 BOM 按 GBK 解码、`2>&1` 把 stderr 变成
  ErrorRecord 后在 EAP=Stop 下炸且报错文案误导、`Set-Content` 给 `.cj`/`.toml` 加 BOM），
  且 Windows 专用不利于后续 Linux 接续。**不要再新增 `.ps1`**。
- **`.bat` 必须纯 ASCII**（cmd 按 OEM 代码页读）；**`.sh` 必须 LF**（由 `.gitattributes` 保证，
  否则 Linux 上撞 `/usr/bin/env: 'bash\r'`）。
- **禁止用 shell 做文本改写源码**（`Get-Content | Set-Content`）：PS 5.1 会按 GBK 误解码无 BOM 的
  UTF-8 文件（中文成乱码），并给文件加 BOM（`.cj`/`.toml` 都不该有）。改源码用编辑器/工具的
  精确替换能力，改完 `git diff` 复核。
- **临时调试脚本别留在仓里**：`scripts/.dbg*.ps1` 会被 `git add -A` 带进去。
- **提交信息里别用 `\"` 转义**：PowerShell 双引号串会把命令拆坏。多行/含引号的提交信息写进文件再 `git commit -F`。
- 仓颉细节坑（从 cjh / cj-tauri 继承，供参考）：`Directory.walk` **非递归**；
  `StringBuilder.append(Byte)` 按十进制整数输出；块注释内禁写 `/*` 序列；零参 lambda 写 `{ => }`。

---

## 4. 已踩坑清单（禁止重踩）

> 签名那块（§4-74、§4-82~87）的**完整复盘**（现象→根因→排查→处置、复跑手册）在
> **`docs/自动签名实战复盘.md`**，遇到签名问题先读它再翻本表。

| # | 坑 | 正确做法 |
|---|---|---|
| 1 | 启动即退，退出码 `-1073741515`（0xC0000135） | 缺 DLL。`llvm-objdump -p main.exe` 看导入表；常见缺 `libcjtbridge.dll`（PATH 加框架 `native`） |
| 2 | 导入表齐了还退 | 缺 `WebView2Loader.dll`（按名加载，不在导入表）→ PATH 加框架 `native\webview2` |
| 3 | `资产未找到：ui/index.html` / 加载 0 个 capability | **工作目录必须是工程根**（launcher 用相对路径读 `assets/`） |
| 4 | `create WebView2 controller failed: 0x800700AA` | WebView2 用户数据目录不可用 → 设 `WEBVIEW2_USER_DATA_FOLDER` 到可写目录 |
| 5 | `create WebView2 controller failed: 0x8000ffff` + Chromium `Check failed` | 宿主不允许 Chromium 起子进程/开命名管道（容器、受限沙箱常见）——换普通桌面会话，不是应用问题 |
| 6 | `ld.lld: failed to write the output file: Permission denied` | 上一版 `main.exe` 还在跑占用产物 → 先关窗口（门禁脚本会自动探测并提示） |
| 7 | `.gitignore` 的 `*.dll` 把 vendor 的运行时 DLL 一起忽略 | 已加例外 `!vendor/cjh/win-x64/*.dll`。少了它们的症状是「窗口照起、http 照通、只有 https 全灭」 |
| 8 | `cjpm build` 报 `imports package 'stdx.encoding.json' ... not added as a dependency` | 没设 `CANGJIE_STDX`（toml 里的 `${CANGJIE_STDX}` 展开为空） |
| 9 | `cjpm test` 报一堆 `undefined symbol: cj_bridge_*` | 业务包 `cjpm.toml` 缺 `-lcjtbridge`（测试可执行文件走的是业务包自己的链接行） |
| 10 | 跑 `.ps1` 报「数组索引表达式丢失或无效」且报错行中文是乱码 | 历史坑：本仓已弃用 `.ps1`（见 §3 与 ADR D-012）。若确要写 PowerShell 脚本，必须存成 UTF-8 **带 BOM** |
| 11 | `cj-tauri check` 报「骨架漂移」 | 改了 `cj-tauri.toml` 或 `assets/` 却没重跑 sync → `cj-tauri sync desktop` / `sync ohos`。**注意：`cj-tauri sync` 不带参数不会重新生成 `targets/*/cjpm.toml` 与 `AppScope/app.json5`**（改了版本号这类清单字段时，跑门禁的 `[0/5] sync` 之后 check 仍报漂移，实测 0.39.22）——要显式跑 `sync desktop` **和** `sync ohos` |
| 12 | 链接报 `undefined symbol: _CGP7cjTauri…`（符号名一串乱码） | 业务包公开接口变了（新增/改动 `public func`）但骨架的增量缓存还是旧对象 → `./scripts/test.sh -c`（删 `targets/desktop/target` 与 `target/` 后重建） |
| 13 | 页面报 `command not registered: t2h:xxx` | **同一个 handler 类的 `match` 里写了分支 ≠ 已注册**——每个命令名都要单独 `app.register`。`cj-tauri check` 只校验「已注册 ⊆ 已声明」，**不查反方向** |
| 14 | 后端 `eprintln` 不出现在 stderr 也不在 .log 里 | `setLogToDefaultFile` 会接管 stderr 的去向；**要当证据的东西落文件**（如 `.lingqu/ui-report.json`），别只打日志 |
| 15 | `cjpm test` 偶发 exit=1 但 `FAILED: 0 / ERROR: 0` | 业务包是 `output-type = "static"`，测试可执行文件静态链接；cjh 的 AGENTS 记录过同类「测试框架在退出时 double free」。**门禁失败必须打印日志尾部**（早期只 grep FAILED/ERROR，把真因藏了） |
| 16 | Windows 上 `scripts/*.sh` 里命令全部 `exit 127` | 机器上已导出 `CANGJIE_HOME=D:\...` 这种 Windows 形式路径，MSYS 的 PATH 里无效 → 脚本内统一 `to_posix`（`cygpath -u` 或手写转换） |
| 17 | 页面收到的帧被整条吞掉、只等到 `done` 显示空回复 | **帧解包必须先认 `p.type`**：`delta` 帧自带 `text` 字段，先按「包装体 `{text:...}`」去 `JSON.parse` 会抛异常。顺序：`p.type` → `p.text` → `p.data` → 字符串 parse（cjnote 踩过同款） |
| 18 | 审批卡一直不出现 | cjh **默认宽松模式**（`settings.json` 无 `capability` 段 = 所有工具放行）。要验审批需临时 `capability.enabled=true` + `approval:["*:*"]`，验完恢复；密钥在 `auth.json` 不在 `settings.json` |
| 19 | 误以为改 `settings.json` 会丢 API Key | 密钥存 `~/.cjh/auth.json`；改 `settings.json` 不影响。但**仍要先备份**——`ConvertTo-Json` 回写会重排格式 |
| 20 | 仓颉里 `quote` 不能当变量名 | **`quote` 是关键字**（quasiquote），报 "expected '(' here"。换个名字（本项目用 `qm`） |
| 21 | `HashMap.put(...)` 不存在 | 仓颉 HashMap 写入是 **`add(k, v)`**（`JsonObject` 才是 `put`）。同理 `contains(k)` / `get(k)` 返回 `Option` |
| 22 | `String.trimLeftAscii(Byte)` 不存在 | 只有零参 `trimAscii()`；要按引号切片就自己记 `start` 下标再 `s[start..i]` |
| 23 | 测试函数报 "not top level" 或不被收集 | 仓颉测试必须 **顶层 `public func`** + `@Test`，写进类里不认 |
| 24 | 不确定某个标准库 API 怎么写 | 查官方 skill 仓 **CangjieSkills**（地址与查法见 §8）：`python scripts/search_docs.py --query "HashMap add" --domain std --max-results 1`。**别按别的语言猜** |
| 25 | 从网页/赛事资料粘进仓的中文文档读不出来（工具报 `invalid UTF-8 text`），末尾还带一堆制表符 | 那是 **GBK/GB2312 粘贴稿**（`docs/仓颉资源地址.md` 就是）。显式按 936 解码再写回 UTF-8：`[Text.Encoding]::GetEncoding(936).GetString($bytes)` → `WriteAllText(..., UTF8Encoding($false))`，**不要**用 `Get-Content/Set-Content`（PS 5.1 会二次误解码） |
| 26 | 落档路径非法导致**静默丢证据**：`.lingqu/scan/E:\work\habit-tree.json` → `FSException: The input path 'parent' … does not exist` | 从路径取末段必须**两种分隔符都认**（`/` 与 `\` 取最后出现的那个），再净化非法字符。而且**写盘失败的原因要进返回值**（`outError`）给界面显示——只有 `eprintln` 等于没有（见第 14 条），0.6.0 因此丢了整轮扫描证据 |
| 27 | 直接在 PowerShell 里跑 cj-tauri CLI / main.exe 报 `-1073741515`（缺 DLL） | `run-dev.sh`·`test.sh` 会配一整套 PATH，手跑要自己补齐：`$CANGJIE_HOME\runtime\lib\windows_x86_64_cjnative`、`$CANGJIE_HOME\bin`、`tools\bin`、`tools\lib`、`$CANGJIE_STDX`、`<cj-tauri>\native`、`<cj-tauri>\native\webview2`。少任何一段都退 0xC0000135 |
| 28 | 写 `"""多行字符串"""` 报 `multi-line string must start with newline character` | 仓颉的多行字符串**必须以换行开头**：`"""\n{...}\n"""`。要写一行的 JSON 就直接用普通字符串 + `\"` 转义（测试里的基线 JSON 就是这么写的） |
| 29 | `JsonArray.size` 当成属性用 → `invalid binary operator '<' on type 'Int64' and '() -> Int64'` | `stdx.encoding.json` 的 `JsonArray.size` 是**方法**：写 `arr.size()`；而 `ArrayList` 的 `size` 是属性（`list.size`）。两者不一样 |
| 30 | Linux 上应用加载完 capability 清单后**静默退出**（无 GTK 报错） | `$DISPLAY` 可能是死的 X 转发会话（`xdpyinfo` 打不开）。无头/受限机器用 `xvfb-run -a -s "-screen 0 1600x900x24"` 跑，不要信 `$DISPLAY` 的存在 |
| 31 | Linux 手跑桌面产物报 `error while loading shared libraries`（先 `libstdx.encoding.json.so` 再 `libcjtbridge.so`） | 手跑要补运行库：`LD_LIBRARY_PATH=$CJ_TAURI_ROOT/native:$CANGJIE_STDX:$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative`。`run-dev.sh`/`test.sh` 内部已处理，直跑产物时容易漏 |
| 32 | 换机器后第一道闸直接红：`the path '/root/test/cj/cj-tauri' of module 'cjTauri' does not exist`；或手跑 `cjpm build` 报 `the path can't be empty` | **本机绝对路径被提交进仓**。`cjpm.toml` 是跟踪文件，谁跑过会改文件的脚本谁的本机路径就进 commit → `cjpm.toml` 一律用 `${CJ_TAURI_ROOT}`（cjpm 对 `dependencies.path` 与 `target.*.link-option` **两处都展开**，2026-10-30 实测）；`setup.sh` 只做体检不改文件。**手跑 `cjpm build` / 直接起 `main.exe` 前要先 `export CJ_TAURI_ROOT=<框架目录>`**，否则路径为空 |
| 33 | 改了「落盘路径/文件名」但回滚或消费方没跟着改（例：0.11.0 把备份改成逐文件，`t2h:revert` 仍找旧单文件路径 → 回滚永远报"没有备份"） | 路径/文件名**收成常量并由产出方与消费方共用**（本项目是 `port.cj` 的 `BAK_*` + `revertPairs()`），并给映射本身写纯函数单测。**只改一处 = 静默破坏另一条链路**，且命令层没有单测会替你发现 |
| 34 | `cargo build --message-format=json` 的 JSON 流里**一条 `compiler-message` 都没有**，但构建确实失败（`build-finished.success=false`） | build-script / 链接 / pkg-config 这类失败**只写在 stderr**。只解析 stdout 会得出「errorCount=0 却编译失败」的自相矛盾结论（0.14.0 实测）。**必须同时收 stdout(JSONL) 与 stderr**，stderr 侧用 `countErrorLines()` 数 `error:`/`error[` 行 |
| 35 | 新建子包 `src/build/`（`package lingqu.build`）报 `top-level declaration 'build' is conflicted with possible sub-package 'lingqu.build'` | 包名别与已有顶层函数撞名——`src/main.cj` 里有 `public func build(): AppSpec`。子包名要避开（本项目最终用 `src/compiler/` + `lingqu.compiler`） |
| 36 | 用 `executeWithOutput(node, ["--mode", ...])` 跑 hvigor 报 `node.exe: bad option: --mode`（exit=9） | **脚本路径必须是 argv 的第一个元素**：`[hvigorwJs, "--mode", ...]`。忘了它，node 会把 hvigor 的选项当成自己的（0.16.0 实机撞到） |
| 37 | hvigor 报 `00303217 Configuration Error: Invalid value of 'DEVECO_SDK_HOME'`，但手跑同一条命令是成功的 | 环境变量值里**混了分隔符**（`D:\oh\DevEcoStudio/sdk`）。hvigor 会校验该值，拼接后必须按宿主归一（Windows 全反斜杠）。见 `hostPath()` |
| 38 | 工具里"环境变量优先、否则推导"的取值顺序，在**环境变量过期**时把正确的推导值覆盖掉（本机 `DEVECO_SDK_HOME` 仍指着已删除的旧 DevEco，导致 hvigor 一直报配置错误） | 路径类环境变量**必须验证目录存在**才采用，否则落到推导值（`firstExistingPath()`）。本机已连续踩到 `DEVECO_HOME` / `DEVECO_SDK_HOME` / `NATIVE_OHOS_SDK` 三个过期值 |
| 39 | 真机装不上：`hdc install` 报 `9568322 signature verification failed due to not trusted app source` | **HarmonyOS 设备只信任华为签发、且 profile 的 `device-ids` 含本机 UDID 的证书**。用 SDK 自带 OpenHarmony 默认材料签没用；`hvigor assembleHap` 即使 `signingConfigs` 为空也会产出 signed.hap——**"有 signed 文件"≠"能装"**。正解：复用 `~/.ohos/config` 里自动签名的材料（p7b 里 grep 本机 UDID 对上），把 `signingConfigs` 抄回 `build-profile.json5`；口令由 hvigor 解密，**不需要登录 DevEco**。配方见 `skills/t2h-ohos-port/references/signing.md`（2026-10-31 真机实测） |
| 40 | `hdc install` / `aa start` 明明失败，脚本却当成功（退出码 0） | **`hdc` 失败时退出码仍是 0**，成败只能按输出文本判：`install bundle successfully` / `start ability successfully`；前端据此写 `parseInstallResult`/`parseStartResult`（`src/compiler/deploy.cj`）。同理 `hdc list targets -v` 会带 `COM1 UART Ready` 串口噪声，别当设备 |
| 41 | 从 PKCS#7（`.p7b`）里取内嵌 JSON 用了「第一个 `{` 到**最后一个** `}`」→ 解析报 `Unexpected character` 或莫名失败 | 证书等二进制里 `0x7D` 就是 `}`，会把尾部垃圾带进 JSON。**必须配对扫描**（深度归零即止，且要跳过字符串字面量与转义），见 `sign.cj` 的 `extractProfileJson`。同理**别用 `String.fromUtf8` 转二进制**：高位字节不是合法 UTF-8，会被吞或抛错（实测内嵌 JSON 被破成 `'?'`）——先做 ASCII 净化视图再取 |
| 42 | `build-profile.json5` 里的 Windows 路径取出来带双反斜杠（`D:\\oh\\...`），`exists()` 永远 false → 误判"签名材料不存在" | JSON/JSON5 字符串里的 `\\` 是**转义**，取值时必须还原（`unescapeJson5`）。而且 json5 允许注释/尾逗号/单引号/无引号键，**严格 JSON 解析器读不了**，按需做轻量"键 → 值"提取即可 |
| 43 | 往 json5 里注入数组时产出 `]]`（多一个闭合括号 → 文件语法错误） | 文本手术要**理清边界归属**：新 body 自带收尾 `]` 时，原文从原 `]` 的**下一个字符**接（`bytes[(close+1)..]`），从 `close` 接就重复。写完**必须断言括号配平**（`bracketBalance()`）——只测"能解析回来"不够，宽容提取器对 `]]` 照样读得出值 |
| 44 | 判"两个工程是否同一套签名材料"时拿 `.p7b` 去比 `signingConfigs.storeFile`（那是 `.p12`）→ 永不匹配 | 材料身份按**同 base 不同后缀**判：先 `materialSiblingsOf(p7b)` 换成 `.p12` 再比文件名（`sameMaterialFile` 只比文件名、忽略大小写）。同理**改完配置文件后所有派生值都要按新内容重算**（文件是否存在 / profile 类型 / 含不含 UDID），否则会出现"写回成功却报材料不存在" |
| 45 | 真机装上了、也启动了，但**界面全白**（`aa dump` 有 `#FOREGROUND`/`#ACTIVE`，hilog 里却没有任何 ArkWeb 活动） | 先查 HAP 里**有没有应用自己的 `.so`**：`EntryAbility.moduleName` 决定 `import("lib<name>.so")`，而 DevEco 模板自带的 `libentry.so`（几 KB 的 `add` 示例桩）让"有 arm64 .so"这种弱判据假通过。`lib<name>.so` 来自 `cargo build --target aarch64-unknown-linux-ohos`，**必须拷进 `gen/ohos/entry/libs/arm64-v8a/`**——hvigorfile 里的 cargo 钩子在 Windows 上已被移除，没人替你拷（`t2h:hap` 0.20.0 起自动做） |
| 46 | 装配闸只判"有没有 `libs/arm64-v8a/*.so`"→ 白屏 HAP 照样 pass | 存在性校验要**点名**：期望 `<moduleName>` → `lib<name>.so`（`entryModuleNameOf` + `expectedSoNameOf` + `hapHasSo`）。别的闸也别用"至少有一个"这种弱判据 |
| 47 | 修完 §4-45 仍白屏，但页面 `OnPageEnd httpStatusCode:200` | 比对 `.so` 与 `dist/` 的**时间戳与内嵌资源键**：tauri 把前端编进 `.so`（`index-XXXX.css/js` 明文可见），`dist/` 重建后 `.so` 没重编就是旧前端。`t2h:build` 的 verify 模式（前端指纹闸）会直接报 stale；修法是重编 `.so` 再装配（增量 30 s 级） |
| 48 | 拿截图证明"界面出来了"，其实拍的是桌面 | `snapshot_display` 拍**整屏**，应用窗口可能被桌面/其它窗口盖住。核对三件事：`uitest dumpLayout` 的前台 bundleName、`hidumper -s WindowManagerService -a '-a'` 里的窗口 bounds、以及与"不启动应用"截图的**逐点差异**（0% 说明拍的是桌面）。**没有视觉时不要拿"进程在跑/日志正常"代替"界面正常"** |
| 49 | 想打"静态包"，结果 exe 还是链接一堆 `libcangjie-std-*.dll` / `libstdx.*.dll` | 三件事缺一不可：① `compile-option = "--static-std"`（`--static-libs` 已 deprecated）；② `CANGJIE_STDX` 指向 **static 树**（`<stdx>\windows_x86_64_cjnative\static\stdx`），指向 dynamic 树就还是链 .dll；③ mingw 链接行补 `-lcrypt32 -lbcrypt -lws2_32 -liphlpapi -luserenv -lpsapi`——静态 stdx 的 x509 用 `CertCloseStore`，缺 `-lcrypt32` 直接 `undefined symbol`。做完静态版随包 DLL 98 → **5** 个（`libcangjie-runtime` 与 `libcjtbridge` 没静态版，省不掉） |
| 50 | 为了改编译选项去手改 `targets/desktop/cjpm.toml` → `cj-tauri check` 判骨架漂移 | `targets/` 是派生品。要临时改就用"**备份 → `trap EXIT` 无条件还原**"的脚本（`packaging/build-static-win.sh` 就是这么做的）；根治办法是给 `cj-tauri.toml` 加 `[build] compile_option/link_option` 透传（上游 TODO，见 AGENTS §8） |
| 51 | 打便携包时"整目录拷 DLL"，结果漏文件（别人的机器上启动即退 `0xC0000135`） | **按导入闭包自动收**：`llvm-objdump -p` 遍历 `main.exe` 与已收 DLL 的导入表做 BFS，从 `CANGJIE_HOME`/`CANGJIE_STDX`/框架 `native` 里解析；收完再跑一次闭包自检，缺任何 `lib*`/`stdx*` 就失败退出。本项目实测靠它抓到 `libwinpthread-1.dll` 与 `vendor/cjh/SHA256SUMS` 两个缺口 |
| 52 | 便携包里明明有 `vendor/cjh/win-x64/cjh.exe`，界面却报「没找到可用的 cjh」 | `cjhVendorDir()` 原先是**相对当前工作目录**的 `vendor/cjh/<平台>`：换个 CWD（快捷方式、`start`、从别处调 `run.bat`）就找不到。修法三件套：① 启动器 `run.bat` 写 `LINGQU_HOME` 并 `cd /d` 到包根；② 解析顺序 `LINGQU_CJH` → 部署目录 → `LINGQU_HOME/vendor` → `LINGQU_CJH_HOME/vendor` → **CWD 上溯 6 层** → 相对路径；③ 结果回投 `ui_report`（`cjhState/cjhBin/cjhVendorDir/cjhHome`）当证据——**仓颉 `eprintln` 不进应用日志**，证据必须落文件。根治要框架暴露 `cj_bridge_exe_dir`（§8） |
| 53 | `.bat` 里做「剥掉末尾反斜杠」（`if "%HERE:~-1%"=="\"`）→ cmd 报 `'tory' is not recognized ...`，整段脚本被拆坏 | cmd 对**引号紧邻反斜杠**的写法会误解码。别在 `.bat` 里玩这个花活：`%~dp0` 本来就带尾杠，直接用 `"%HERE%main.exe"` 拼；确实需要无尾杠版本就单独 `set "NB=%HERE:~0,-1%"` |
| 54 | 静态链 C 桥报 `ld.lld: error: undefined symbol: IID_IFileOpenDialog`（还有 `IID_IUnknown` / `IID_IDropTarget`），出错位置是 `libcjtbridge.a(bridge_win.o):(.refptr.*)` | mingw 下 COM 的 **IID 守卫符号**在 `libuuid.a`（`.refptr` 段是 clang 给 `&IID_xxx` 造的引用），桥的文件对话框/拖放实现引用了它们。链接行照框架 `native/build_win.bat` 补齐 `-lole32 -loleaut32 -luuid -lcomdlg32 -lgdi32 -loleacc -lshlwapi -lshcore`（0.25.0 实测通过）。**"静态化"不是把 `-lxxx` 换成 `.a` 就算完**：桥依赖的 Win32 导入库一件都不能少 |
| 55 | 想把 cjh 从「随包目录」改成「PE 资源」时，`extractEmbeddedAssets` 明明释放了文件，引擎仍不启用 | 释放 ≠ 可用：`shouldUseExtracted(释放数, SHA256 校验)` 两个条件都要过（校验不过绝不执行，与 §2.3 的 vendor 纪律一致）。另外 `cjhStatusJson` 的 `running` 分支原先**不回投 `binPath`**，界面只看到 `running`、分不清「内嵌释放的那份」与「用户自己起的」——已补纯函数 `knownBinPath` + 单测，`ui_report` 的 `cjhBin` 现在有值可查 |
| 56 | 写 `var out: Array<String> = []; out.add(x)` → `'add' is not a member of struct 'Array<Struct-String>'` | 仓颉的 **`Array` 是定长**，没有 `add`；要按需追加就用 `ArrayList<T>()` 再 `toArray()`（`HashMap` 也不是 `put`，见第 21 条）。写"拼数组"这类代码前先在仓里搜一眼现有写法 |
| 57 | 断点/报告里出现「HAP 0 字节」「前端指纹 0 项一致」这类**假数字**，实际落档里字段明明有值 | 读别人写的落档**必须对着 schema 抄字段名**：本项目实测 `hap.json` 是 `hapBytes` 不是 `bytes`、`rawfileCount` 嵌在 `entries` 里、`assetDiff.matched` 是**数组**（用 `arraySizeFieldOf` 取条数，别当整数）。判定与摘要写在同一处时，**失败必须把闸的第一条 `failures` 贴出来**——否则界面只有"失败"两个字，没人知道为什么 |
| 58 | 断点板里某步"跑过了却永远显示未开始" | 落档位置有历史形态：`t2h:port` 的 `decisions.json` 只在记过人工决策时才写，但改造本身留下 `.lingqu/port/<工程>/` 备份目录。观测规则要**同时认两种证据**（落档文件 or 备份目录），否则断点会一直卡在那一步。同理任何"落档路径"改动都要回看消费方（第 33 条） |
| 59 | `Directory.readFrom(dir)` 的返回值当字符串用 → `'toString' is not a member of struct 'FileInfo'`；或 `bytes[i] == 92` 换成 `for (s in [92,47]) if (bytes[i] == s)` → `invalid binary operator '==' on type 'UInt8' and 'Int64'` | `Directory.readFrom` 返回 `Array<FileInfo>`，**名字是 `info.name` 属性**（另有 `isDirectory()`）。而 Byte 只能和**字面量**比：`bytes[i] == 92` 可以，数组元素是 `Int64`、与 `Byte` 比要显式转换。两个错误都在 0.27.0 编译期报出——好在都是编译期，不会进产物 |
| 60 | 页面加了新的 `ui_report` 字段，JSON 里却**根本没有这个键**（界面上看着有值，报告里查不到） | `t2h:ui_report` 是**白名单**实现：`UiReportCommand` 里没写同名 `o.put(...)` 的键会被静默丢弃。0.28.0 的 `signSwitchRows` 就这么丢过一次。**新增 ui_report 字段必须两处一起加**（`assets/ui/index.html` 的 `reportUi` + `src/main.cj` 的 `o.put`），否则"版面可断言"是假的 |
| 61 | 报告里出现「上架前：上架前：…」这种叠词 | 跨层拼句子时，**先看被引用的那句是否已经自带前缀**（`sign.cj` 的 `releaseNextStep` 本身以「上架前：」开头）。原文引用就不要再加壳；要加壳就让来源给"纯内容"版本 |
| 62 | 拼路径时用 `cur += "${b}"`（`b` 是 `Byte`）→ 得到 `695892116101…` 这种数字串（0.29.0 的矩阵样本名就这么坏过） | **Byte 插值按十进制打印**，与 §3 的 `StringBuilder.append(Byte)` 同款坑。要按字节拼字符串就攒 `ArrayList<Byte>` 再 `String.fromUtf8(bytes.toArray())`，这样中文/非 ASCII 路径才不会坏 |
| 63 | 矩阵/报表里"没跑过"显示成「未过」「0 分」；**反向也栽过**：`verify` 把"装配**跑过**、闸没过"报成「没跑过装配」 | 每一列都要有**"有没有跑过"的位**（`hasScan/hasBuild/hasHap/hasDeploy/hasVerify`），"没跑"与"跑了没过"**必须分开写**，未跑的样本**不进平均**。`ChecklistInput` 的 `hasBuild/hasHap` + `hapBuilt/hapSigned/hapFirstFailure`：没跑过 → `unknown`；工具失败 → `fail`；产物出来了但**闸**没过 → `fail` **并把闸门第一条失败贴进 note**（0.39.23 实测踩到反向那一半） |
| 64 | AI 助手回复"没渲染"：表格变成一串带竖线的句子、列表挤成一行、代码块没有等宽 | 气泡**不能用 `textContent` 塞模型输出**——那等于放弃 Markdown。用 `renderMd`（移植自 `cj-tauri/examples/ai-chat`），顺序固定：**先摘代码块 → 再整体转义 → 只认受控标记**（外部内容先转义 `<>&"`，之后只加自己生成的标签）。改完用 `LINGQU_UI_PROBE=md` + `ui_report.mdOk/mdBlocks` 断言，别靠肉眼看 |
| 65 | 页内自检把好实现判红：`escape-code` 断言要求 `&lt;b&gt;hi&lt;/b&gt;` **连续出现**，接上 hljs 后 `&lt;` 被再切成 span，断言就假失败（`mdFail=escape-code`） | 断言要断**语义**不要断**字节顺序**：这里应写成"原文标签 `<b>` 不存在 **且** 出现 `&lt;`"。同理带高亮/格式化的输出，别断言"某段文本连续出现"——中间随时可能插 span |
| 66 | 右栏 372px 里再套一层气泡，内容只剩 299px（25 头像 + 9 间距 + 11 内边距全吃掉），看着"左侧一片空白" | 窄栏的 assistant 消息要**平铺**（`.msg:not(.me)` 去头像栏与气泡框，正文贴内容区左缘）；用 `ui_report` 的 `aiFlatLeft / aiBubbleW / aiAvatarsShown` 量化，别用"看起来差不多"。用户自己的消息保留气泡以便区分"谁说的" |
| 67 | 返回值类型写成 `func f(...) -> T`（Rust 肌肉记忆）→ 编译器报的是**下一个**函数声明：`body of function 'X' is missing` + `expected ';' or '<NL>', found '->'`，照报错位置改永远改不对 | 仓颉的返回值类型是 **`func f(...): T`**（冒号，同 Kotlin/C#）。0.36.0 为此查了半小时：报错位置指向的 `migrateResultMarkdown` 完全正常，真凶是同文件里唯一一个 `->`。**看到 `found '->'` 就在全文件 grep `->`**，别再顺着 `X` 往下找 |
| 68 | 一键迁移这类"分钟级 + 多步"的命令写成同步 handler → 整个 IPC 命令面被堵死，页面连进度、点「停止」都发不出去 | 长任务一律**起后台线程 + 状态放内存**，命令只返回"已启动"，进度用另一条只读命令轮询（本项目 900ms）。见 `t2h:migrate` / `t2h:migrate_status`；`wait` 只给命令行用 |
| 69 | 改了 `src/` 却只重建业务包 → `run-dev.sh` 起的还是旧行为（"改了没生效"） | `run-dev.sh` 跑的是 **`targets/desktop`** 的产物；业务包改了必须 `cd targets/desktop && cjpm build`（或直接跑 `scripts/test.sh` 的第 ④ 闸）。0.37.0 的绝对路径修复因此白跑了一轮实机探针 |
| 70 | 交给 agent 的工具有了，但它「跑不动」：任务书里写相对路径 `cli\target\release\bin\main.exe` | agent 的 bash **cwd = 目标工程**（`workspaces/switch` 之后），相对路径全部失效。凡是要给 agent 用的路径一律**绝对**（`getWorkingDirectory()` 拼），而且要先把工程上下文/工作区切好**再**发任务书 |
| 71 | agent 的 bash 里 `cat`/`sed`/`grep` 全报 `command not found`（exit 127），**看起来像模型把命令写错了**，于是它反复换写法重试、白烧轮次 | cjh 用**绝对路径**找到 Git Bash，但 `<git>/usr/bin`（coreutils）不在继承来的 PATH 上 —— 目标机器 Git 没进 PATH 时必然如此（`cjpm test` 里也撞到过：会话 PATH 一个 MSYS 目录都没有）。cjh 0.39.7 起 `shellPathFix()` 幂等追加 `<git>/bin`/`<git>/usr/bin`/`<git>/mingw64/bin`（**追加不覆盖**）。**排查口诀：`command -v cat`（内建）先探一下，再怀疑代码**；写测试也别把"外部命令存不存在"和"被测行为对不对"搅在一起 |
| 72 | 实机探针跑到一半应用**凭空退出**，日志里只剩几行 `[PASS]` | **别一边跑 `scripts/test.bat` 一边跑实机探针**：第 ④ 闸发现 `targets/desktop` 的 `main.exe` 在跑时会**结束进程以释放产物**（日志原文 `[!] 上一版 main.exe 仍在运行，先结束它以释放产物`）。要边看边改就先只跑 `cjpm test` 或第 ①②③ 闸，整个五道闸留到探针结束之后 |
| 73 | 改 `cjpm.toml` / `cj-tauri.toml` 的版本号或注释，改完中文全成乱码、还多了 BOM | **别用 `Get-Content \| Set-Content` 回写含中文的文件**（PS 5.1 按 GBK 误解码无 BOM 的 UTF-8，还顺手加 BOM）。单行改动（版本号）用编辑器/工具的精确替换；非要在 PowerShell 里写就用 `[System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))`，改完 `git diff` 逐行复核。**提交信息文件同理**：`Set-Content -Encoding UTF8` 写出的 `.txt` 带 BOM，`git commit -F` 会把 BOM 带进提交主题行（`git log --oneline` 显示成一个不可见字符；实测 0.39.23 栽过一次，靠 `reset --soft` + 重做两条提交 + `--force-with-lease` 洗掉）。写提交信息文件也走 `UTF8Encoding($false)` |
| 74 | `t2h:hap` 报 `assembleHap 没成功`，把 `signingConfigs` 从"不存在的材料"改成 `~/.ohos/config` 里**现存那套**（文件齐全、含本机 UDID）后仍然失败，错误变成 `00303074 Configuration Error: The bundleName in app.json5/hvigorfile.ts does not match the bundleName in the generated SigningConfigs` | **签名材料（profile）是按包名签发的**：`AppScope/app.json5` 的 `bundleName` 与 profile 的 `bundle-name` 不一致时，hvigor 在 `default@SignHap` 直接拦下。"有材料 + 含本机 UDID"只过了两道门里的一道。新包名**只能**去 DevEco 自动签名一次（需登录，计入 A3 人工介入）；`00303107 Invalid storeFile` 才是材料文件缺失。工具已把两条都翻成闸门失败行（`hapSignHint`）与指纹 FP-018/FP-019，别再去猜路径。见 ADR D-017 |
| 75 | `t2h:verify` 把**刚成功的部署**判成"装上了但没起来"，可用率凭空掉一大截；或 `t2h:report` 的数字与现场不符 | 两种"读档读错"叠在一起：① 取数还在按**相对 CWD** 读 `.lingqu/...`（0.38.0 起落档已改到 `<工程>/.lingqu/`）→ 读到上一次/别的工程的旧档，实测到的是 0.39.7 锁屏那轮的 `start.ok=false`；② `assetDiff.matched / staleInSo / missingInSo` 是**数组**（§4-57），用 `intFieldOf` 取永远得 0 → "指纹一致"被判"不一致"。**判据：落档里的每个字段先确认形态再取值**；读侧一律 `resolveLqPath(projPath, …)`，并把解析收成纯函数（`buildAssetFlagsOf` / `deployFlagsOf`）用单测钉住。**第二处漏网**：`report_feed.collectReportFacts` 同样相对 CWD 读，还把带 `.lingqu/` 前缀的路径喂给会再补一层的 `resolveLqPath`（→ `.lingqu/.lingqu/…`），报告结论写「尚未验证」而正文 100%（0.39.24）。**改了读档口径要全仓 grep 一遍 `.lingqu/` 字面量**，别只修撞到的那一处 |
| 76 | 某个命令"跑成功了"，但它的 `.lingqu/<步骤>/<工程>.json` **根本不存在**（界面/agent 只会看到"没跑过"） | **工程目录里还没有 `.lingqu` 时建子目录会失败**：`ensureDirOf` 原来逐段 `Directory.create(Path(part))`，实测抛 `Failed to create directory …\.lingqu\sign, parent …\.lingqu does not exist`——5 个样本里 3 个中招、证据整块丢失。**建目录一律用 `Directory.create(Path(dir), recursive: true)`**（与 `saveTaskBoard` 同写法），逐段创建只作兜底；写完还应核一次 `exists()`。属 D-013（静默失败零容忍）：证据没落地必须能被发现 |
| 77 | 明明能秒级判定的事，却让子进程跑完分钟级才报错（`t2h:hap` 白等 hvigor 三分钟只为拿一句 `00303074`） | **能前置的判定就前置**：`hvigor assembleHap` 之前先做签名预检（`judgeSignPreflight`：包名不一致 → 拦；材料缺文件 → 只提示；没配签名 → 不拦），把"必然失败"在 1 秒内说清并落进闸门。agent 的轮次预算稀缺（ADR D-015），工具的价值不只是"正确"，还有"少烧时间" |
| 78 | 以为仓颉能直接做 AES-GCM（写口令密文、与 hvigor 互操作时）→ 编译期 `undeclared identifier 'AES'`，或退而用 `SM4(OperationMode.GCM, …)` 运行期抛 `CryptoException: Encrypt failed due to create tag error` | **仓颉 std / stdx 1.0.5.1 没有 AES**：`stdx.crypto.crypto` 只有 `SM4`/`SecureRandom`/`OperationMode`/`PaddingMode`，标准库 `std.crypto.cipher` 只有 `BlockCipher` **接口**；SM4 的 GCM 在本机不可用（CBC/ECB/CTR 可用）。需要 AES 就自己实现（本项目 `src/compiler/aes_gcm.cj`，用 NIST SP 800-38D 向量 + 本机 Node/OpenSSL 互证），或改用不需要 AES 的方案。别指望 KB 里的写法一定存在——**KB 给形状，编译给真相** |
| 79 | 照知识库写 `SecureRandom().nextBytes(n)` 想拿到 n 字节随机数 → `mismatched types: expected 'Array<UInt8>', found 'Int64'` | `nextBytes` 是**填缓冲区**：先 `let buf = Array<Byte>(n, repeat: 0)`，再 `SecureRandom().nextBytes(buf)`，随后用 `buf`。VB 里同类"给长度返回数组"的语义在这里不成立 |
| 80 | 用 `cmd /c start "" <url>` 打开浏览器，用户却在网页侧登录失败 | **URL 里的 `&` 被 cmd 当命令分隔符**：`…apply?port=21570&appid=1009&code=…` 只会打开 `…?port=21570`，其余几段被当命令执行（日志里是 `'appid' is not recognized …`）。Windows 上打开 URL 用 **`rundll32 url.dll,FileProtocolHandler <url>`**（不经 shell 解析）；`xdg-open`/`open` 按 argv 收参没这问题。同理：任何**带 `&`/`%`/`^` 的参数**都别交给 `cmd /c`——要么绕开 shell，要么自己加引号并验证 |
| 81 | OAuth 回环登录"怎么点都不成"：网页提示 `Bad code` / `Bad Request`，或登录进程当场退出 | 三个坑叠在一起，逐个治：① **一次异常回调不许终止会话**——浏览器/华为页面的预检跳转不带 `tempToken`，把它当致命错误会让进程退出、端口不再监听（现在只有显式 `quit` 才终止）；② **`code` 只核对不拒绝**——华为回调自带它自己的 `code`，与我们的防伪值天然不同，硬比对会把正常登录判成失败（安全边界靠：只绑 `127.0.0.1` + 一次性服务 + Host 白名单 + tempToken 仍要过华为校验）；③ **别让用户去猜哪条链接**——`/callback` 是内部地址，手动打开必然报错，回调页上直接给出可点的登录页链接。判定抽成纯函数 `judgeCallback` 单测钉住 |
| 82 | AGC 建证书回 `205389872 certificate number exceeds limit.`，明明"只想签个新包名" | **调试证书有数量上限（本账号实测 4 张），过期的照样占位**。`staleCertsOf` 只挑「已过期 **且** 名字以 `auto_debug_`/`auto_release_` 开头」的调用 `agcCertDelete` 腾位；**别去删用户手工建的证书**。删除端点是 **DELETE + 请求体** `{"certIds":[...]}`（放 query 一律回 `Body parameter is required.`），且请求体要带 Content-Length |
| 83 | 证书名字对得上、`cert/list` 里也有，申请 profile 却被回 `The certList is invalid.` | **同名证书可能早已过期**（`status=2`、`expireTime` 过去）。可用性判据是**有效期**不是名字：`AgcCert.usable()` + `findUsableCert`。同理换了密钥对之后**不能**复用云端同名证书——它绑的是旧公钥，profile 里的证书会和 `.p12` 对不上（必须删旧建新，并重下本地 `.cer`） |
| 84 | `⑦ 写回失败：工程里已经有非空的 signingConfigs，不做覆盖` —— 整条自动签名死在最后一步 | 复用同一 `.p12` 时 `.p7b/.cer` 会随证书换发而变，所以"已有配置"并不等于"配置是对的"。`replaceOwnSigningConfigs` 在**同一套材料（同一个 `.p12` 文件名）**时就地更新，换材料仍拒绝。定位数组要**按深度配对并跳过 json5 字符串**，别"遇到第一个 `]` 就停"（那只在空数组上成立） |
| 85 | hvigor 报 `00303242 Signature material verification failed, as: Unsupported state or unable to authenticate data`；`sign --reencrypt` 报 `GCM tag mismatch` | **`.p12` 的口令没人知道**（材料是拷来的 / `material/` 重建过）→ 旧密文解不开，也就没法用本机 workKey 重加密。`GCM tag mismatch` 就是"这份密文与本机 material 不配套"的可判定证据。处置是 `--newKeys`：旧材料**改名留底**后重生成，自己掌口令、自己加密。**别猜口令、别把旧密文硬写回去** |
| 86 | 加了 `--newKeys` 却"什么都不做"（既不报错也不换材料），排查一小时 | 拼材料路径时手抄模板**漏了 `=` 分隔**（DevEco 命名是 `<base>=` + 后缀）→ `exists()` 全 false，一个文件都没被挪走。**同一组路径只能有一个构造点**（本项目收成 `matPrefix`），凡是"静默不生效"的开关先打印它读到的值再怀疑逻辑 |
| 87 | `hdc install` 报 `9568332 install sign info inconsistent` | 同包名**已装过另一套签名**的版本（重签后必然撞上）。调试机上正解是先 `bm uninstall -n <bundle>` 再装——`deploy` 已自动做一次并记进证据。反之 `10106102` 是**锁屏**（开发者模式禁止自动解锁），处置是"解锁后重试"，**不是** ability 名写错 |
| 88 | 装配框架插件 `DialogPlugin()` 后 `cj-tauri check` 报「已注册命令 `dialog:message` 未在 capabilities 声明」 | 插件**一次性注册** `open`/`save`/`pickFolder`/`message` 四条，而命名权限集 `dialog:files` 只覆盖前三条 → 门禁按「已注册 ⊆ 已声明」判红。现在用 `dialog:default`（四条全覆盖）。**这是门禁口径的可改进点**：应先把 `permissions` 展开成命令名再比对，否则"想只申请最小权限集"反而过不了门禁（0.39.25 实测，用户只要 `pickFolder` 却被迫拿到 `message`） |
| 89 | 目录**已存在**时调 `Directory.create(Path(p), recursive: true)` 抛 `FSException: ... is already exists` | **`recursive: true` 只保证父级会建出来，不保证"已存在也返回成功"**（与 `mkdir -p` 不同）：先 `if (!exists(Path(p)))` 再 create。§4-76 讲"父级不存在"，这条讲"已存在不是错误"（0.39.25） |
| 90 | 最大化窗口后**底部空一大截**（内容不拉伸到底），而小窗口看着正常 | `.app` 原来是 `display:grid;grid-template-rows:48px auto 1fr`，而第二行那个面板（克隆条）默认 `display:none` —— **`display:none` 的子元素不再是 grid item**，于是 `.body` 落进第 2 行（`auto`），第 3 行的 `1fr` 空着没人占。判据：`.app` 底边 − `.body` 底边 必须 ≈0（`ui_report.layoutGapBottom`）。修法：外层改**纵向 flex**（`.body{flex:1 1 auto;min-height:0}`），隐藏项自然不占位；若坚持 grid，就把隐藏项写成 `height:0;overflow:hidden` 而不是 `display:none` |
| 91 | 窄窗口适配的媒体查询**完全不生效**，元素该缩的时候不缩 | 元素上带着**行内 `style="...min-width:260px"`** —— 行内样式优先级高于样式表，媒体查询压不住它。**尺寸策略只写在样式表里**；行内 style 只用于一次性的定位微调。实测：`#projPath` 的行内 `min-width:260px` 让 `@media(max-width:1300px){min-width:80px}` 形同虚设，1264 宽时顶栏仍被撑爆（0.39.26） |
| 92 | 跑门禁时聊天面板「连接已断开」、点「立即拉起」也回不来 | **门禁 ④/⑤ 闸为释放产物执行 `taskkill /F /IM main.exe`，而 cjh 引擎的 exe 也叫 `main.exe`** ⇒ 把引擎一起杀了。改成 `kill_own_main_exe`：按 `Process.Path` **只结束路径落在本仓下的**（`targets/desktop`、`cli/`）；实测杀后引擎 `/api/health` 仍 200（0.39.27）。**第二条**：`t2h:cjh_deploy` 原先忽略 `LINGQU_CJH`，拉起的是旧副本 ⇒ 页面连不上；现在与 `cjhBinPath()` 同优先级 |
| 93 | 「只杀自己的进程」写好了却**还是把引擎杀了**：日志打出 `[kill] 6628 E:\...\cjh\target\release\bin\main.exe` | **bash 不预解析函数**——`ROOT_WIN="$(to_posix_rev_win "$ROOT")"` 写在 `to_posix_rev_win()` 定义**之前**，调用时报 `command not found`（被 `2>/dev/null` 或命令替换吞掉），`ROOT_WIN` 变成**空串**；而 `Path.StartsWith('')` **恒为真** → 过滤条件失效，等于回到"一刀切"。两条处置：① 赋值**挪到**函数定义之后；② **对过滤依据加空值守卫**，为空时拒绝结束任何进程并告警（宁可留一个占着产物的进程让人手动关，也不能误杀）。通用判据：**凡是"按某个值筛选/过滤"的破坏性操作，先断言那个值非空**——空值常常等于"全部匹配"（0.39.27 实测） |
| 94 | 顶栏一直显示「当前项目 habit-tree · v1.2.0 · 原生 TS + Rust」，**用户换了工程它一个字都不变** | 那段是 HTML 里**写死的示意文案**，`setCurrentProject()` 只更新输入框与回显框，从没碰过它。示意数据留在真实界面里 = **对用户谎报**，而且它长得跟真数据一模一样，用户没理由怀疑。规矩：① 界面上任何"看起来像数据"的文字都必须**绑定变量**；② 暂时没有真实来源的字段**宁可不显示**（`未扫描` / `—`），也不要写死一个示例值；③ 确要保留示意版面，就显式标注「示意数据」（本项目 `docs/ui-mockup.html` 与报告屏就是这么标的）。对应坑还有一半在 §4-95（0.39.28 实测） |
| 95 | 扫完当前工程后，顶栏胶囊仍说「未扫描（旁边的数字属于上一个工程）」 | **同一路径的两种写法**：后端回投的是 `E:\test\rust\m3u8dl-tauri`，输入框/`localStorage` 记住的是 `E:/test/rust/m3u8dl-tauri`，直接用 `===` 比较 → 判成两个工程。**路径比较一律先归一化**（`normPathKey()`：`\`→`/`、去尾分隔符、Windows 盘符与整串小写——Windows 路径大小写不敏感）。这条适用于所有"落档里的路径 vs 界面里的路径"（§4-26 是取末段时的同族坑，§4-75 是读档时的同族坑） |
| 96 | 「5 样本矩阵」把**迁完的工程显示成未跑**（m3u8dl-tauri 可用率 100% 却写「未跑 / 25%」），用户也就找不到"移植成功的项目在哪看" | 两条叠在一起：① `batch_feed.cj` 的 7 处读档**全是相对当前工作目录**的 `.lingqu/...`（§4-75 那族的第三处漏网，改 `report_feed` 时没 grep 全）；② 自动发现样本时**只捡工程名、不带路径**，天然定位不到样本自己的落档。处置：读档统一走 `readSampleLq(projPath, …)`（内部 `resolveLqPath`），发现改成扫候选根里**带 `.lingqu` 的目录**并带回路径。**判据：凡"多工程并排"的功能，每一行都必须能说出自己的工程路径**（现在 `title` 就挂着）——说不出来就一定会读错档 |
| 101 | 接续旧会话时服务商回 400：`The reasoning_content in the thinking mode must be passed back to the API` | **思考模式的模型要求把上一轮 assistant 的 `reasoning_content` 原样回传**，而 cjh 的 `ChatMessage` 里**根本没有 reasoning**（从来没落库）⇒ 新会话正常、**接续旧会话必然 400**。判据：报错文案里出现 `reasoning_content`；`服务商返回错误：` 出自 **cjh 自带网页 UI**，不是灵渠的文案。本仓处置：**识别到该 400 自动 `new_session`**（界面历史仍保留）；根治要 cjh 侧加 reasoning + 落盘 + 回传（`docs/上游回馈-cjh.md` 第 10 条，0.39.36 实测） |
| 103 | 页脚在「WS 已连接 · 帧 N · 会话」↔「未连接」之间**反复横跳** | **一次状态误判不允许掐连接**：`t2h:cjh_status` 回非 running 就 `wsClose()` 时，引擎忙于 SSE 流会让 `/api/health` 超时 → 误判 → 关连接 → 800ms 又连上。判据收成纯函数 `wsKeepDecision(running, streak, busy)`：判掉 1 次只算疑似、**连续 2 次且不在干活才 close**。页脚写清「连接中…（第 N 次）」「新会话（旧会话已弃用）」；`noteWsEvent()` 记最近 8 条「谁动了连接」回投 `wsEventText`；探针 `LINGQU_UI_PROBE=flap`。**排查提示**：cjh 日志每 5 秒一条 `Agent.interrupt` 而你没点停止，先看是否有浏览器标签开着 `127.0.0.1:8765` 的 cjh 网页 UI（0.39.38，详见 docs/进度记录） |
| 104 | 聊天窗宽度不可拖动 | 照 `cj-tauri/examples/cjnote` 的 `#ai-resizer` + `--ai-w`：① 宽度写 **CSS 变量**不写行内 style；② 夹取**跟窗口走**（`min(上限, 窗口宽 − 左栏 − 拖条 − 内容区保底)`）；③ `resize` 重夹但**折叠态跳过**（`display:none` 量出 0 会把宽度冲成下限）。本仓：四列 grid + `#aiResizer`（`col-resize`、双击复位、`localStorage` 键 `lingqu.aiw`）；断言 `aiDockW/aiW/aiResizerOk/aiDrags` + `LINGQU_UI_PROBE=resize`（0.39.39） |
| 105 | 写「进度 100%　未连接真机」，可应用已在真机上跑起来 | **一次性快照不许当"现在"报**：`migrateHasDevice()` 只在迁移开始查一次。判据双口径：`hasDevice`（起始时，决定是否跳过 deploy/verify）+ `deviceInRecord/deviceSerial`（`deployDeviceOf()` 读 `.lingqu/deploy/<工程>.json`）。文案三档标来源。取证先看落档（`deploy.deviceCount`、`verify.ratePercent`）与 `hdc list targets -v`，别只信界面（0.39.40） |
| 106 | DOS 黑窗一闪一闪（问过三次） | 本应用是 **GUI 子系统**：进程没有 console ⇒ `executeWithOutput`（hdc/cargo/hvigor/git/java/curl）每调一次 Windows 就给子进程**新配一个控制台窗口**；cjh（DETACHED）亦然。**单点修法**：`src/win_console.cj` 的 `ensureHiddenConsole()`（`AllocConsole` + `ShowWindow(SW_HIDE)`，FFI 要包 `unsafe`）让本进程持一个**看不见的** console，子进程继承；cjh 有隐藏控制台时改 `std.process.launch` 继承拉起（回落 `launchHidden`），句柄用 `CjhHandle` 收口。**断言**：`ui_report.consoleHidden=true` + spawn 一批子进程后 `conhost` 只 +1（不是每个子进程一个）；自拉起验证用 `LINGQU_CJH_PORT=8766`，别动用户的 8765（0.39.40） |
| 107 | 页面某段代码"什么都不做、也不报错"（左栏徽标永远是空的） | **同一个 `<script>` 里可能是两个作用域**：业务代码在内层 IIFE（`invoke`/`CJ`/`projectPathValue`），文件末尾那段（`setCurrentProject`/左栏代码）在**外层**。外层引用内层符号抛 `ReferenceError`，**只落 `window.onerror`，调用方与 promise 都看不到**。处置：外层只"读 DOM + 画"，取数据走内层注册的桥（`window.__railBridge`）；任何"静默不生效"的界面逻辑，第一动作是**把 `window.__uiErrors` 回投 `ui_report`**；**改完 `index.html` 必须重建 `targets/desktop`**（只 `cjpm build` 业务包不够）。**第二条**：`localStorage` 在本应用里被拒（origin `about://` → `setItem` 抛 `SecurityError`，被 try/catch 吞了）⇒「记住工程/宽度/偏好」从来没生效过；要真记住只能走落档通道（见 §4-110），判据 `LINGQU_UI_PROBE=store`（0.39.44） |
| 108 | 「AI 引擎缺失」，可浏览器打得开 8765；追问"状态轮询为啥偶发超时" | 实测：`/api/health` 空载 8~15ms、16 路并发 p90 9ms、8 路压重接口时 max 15ms —— **端点不慢**；慢在**我们自己**：`cjhHealthy()` 每次 `ClientBuilder().build()`→请求→`close()`，**每 2 秒换一条 TCP**；30 次探活后 8765 上留 **30 个 TIME_WAIT**（keep-alive 单连接新增 **0**），叠加 cjh 侧不回收 `CLOSE_WAIT`（上游第 11 条）⇒ 偶发建连 >3s 就判"引擎不在"。处置：① 探活**复用一条 keep-alive 客户端**（出错才重建）；② 判死要有证据：单次→重试 3 次→**20 秒宽容窗口**报 `running+unstable`；③ 界面用 `CJ.up` 兜底，**通道连着就不说缺失**。证据：修后轮询 50 秒 `TIME_WAIT=0`（0.39.42） |
| 109 | 左栏徽标写「通过」被指不合适（"它只表示检查做没做，不涉及合不合格"） | **状态词要分清层次**：左栏徽标表示**"这一步检查跑过没有"** ⇒ 用 `已完成 / 部分完成 / 有失败 / 未开始`；"合不合格"属于判定，放在 `title` 与落档 note 里（`已完成（判定失败）（拿不到设备 UDID…）`）。**但失败不能藏**——`ok=false` 必须显式报「有失败 N/M」，否则是另一种瞒报。`.done` 勾只认「已完成」。顺带一条实测：**落档会过期**（签名体检记录停在"设备没连"的时刻，设备接上后要重跑那一步才刷新）（0.39.43） |
| 110 | 每次开窗都要重新选工程（左栏六项全「未开始」） | **"存下来的工程"必须真的用上，而且"存哪儿"要有证据**：`localStorage` 在本应用被拒（§4-107）⇒ 改读落档——`t2h:env.lastProject` 来自上一次 `t2h:ui_report` 的 `currentProject`，页面据此 `setCurrentProject` 并立刻刷徽标；`pickRestoreProject` 只兜底。断言 `projRestored=backend` + 探针 `restore`/`store`（0.39.44） |
| 111 | 界面**一直显示旧状态**（页脚"已连接"、设置页"引擎缺失"），报告里 `cjhState=missing` 但引擎明明在跑 | **渲染函数的 DOM 依赖被别人清掉了**：历史回放 `chatBox().innerHTML=''` 把常驻的 `#aiHint` 一起冲掉，`renderStatus()` 每 5 秒写 `$('aiHint').style.display` 就抛 `Cannot read properties of null (reading 'style')`，整段状态渲染中断，异常又被 `.catch` 吞成 `missing`。判据：`cjhPollFail>0` / `cjhDiag` 里出现 TypeError / `aiHintOk≠1`。处置：清屏保住常驻节点 + `ensureAiHint()` 缺了就重建 + **查询失败报 `unknown` 不报 `missing`**（0.39.45） |
| 112 | AI 设置页「模型」只显示 id、看不到模型名，「当前」还紧贴在 id 后面 | **字段渲染漏了 `name`，判据也取错来源**：`/api/models` 返回 `{id,name,baseUrl}`，界面只拼 `m.id` ⇒ 模型名从来没显示、「当前」在 DOM 里成了 `id当前`；而「当前」取 `/api/models.current`，真正决定行为的却是 `settings.model`。处置：`name` 主标签 + `id` 副标签（对齐 cjh UI 的 `m.name \|\| m.id`）；「当前」以配置为准；配置/列表/本会话（`switch_model` 的 `ack.model`）不一致要亮提示；保存后补发 `switch_model` 才对本回合生效。**通用**：别人返回的字段先**对着 schema 列全**再决定渲染哪几个；"当前"必须写清是哪个来源的当前。断言 `ui_report.settingsDump`（0.39.46） |
| 113 | 一键迁移跑到一半**静默停住**：界面只有「回合结束 · 轮次 41 · 工具 54 · 157.5s」，不说为什么停，也不说哪条命令挂了 | 两件事叠在一起：① **逐字节 `String.fromUtf8([bytes[i]])` 是炸弹**——`stripAnsi` 剥 ANSI 时这么写，而中文/GBK 的一个字节本身不是合法 UTF-8，于是 `t2h:hap` 立刻抛 `IllegalArgumentException: Invalid utf8 byte sequence`、落档写成「HAP 0 字节」；② 那一轮 cjh 的 `max_iterations: 40` 刚好用完（`turn_done` 报 rounds=41），界面又只写"回合结束"。处置：命令行输出转文本**一律走 `lenientUtf8`**（非法字节换 `?`，永不抛；`compiler/hap.cj`），`stripAnsi` 改成攒 bytes 再整体解；界面在 `turn_done` 时**必须解释为什么停**（轮次预算 / 长度上限 / 回合异常 / 模型自己停了）并**贴出最后一条工具报错**（`CJ.lastToolErr`，回合开始清零），`ui_report` 增 `turnEndReason / lastToolErr / lastToolErrName`（0.39.51） |
| 114 | hvigor 报 `00308018 Unknown Error`，看着像签名或代码问题，agent 会反复试签名、重装依赖 | 日志里真正的 trace 是 `cargo tauri ohos dev-eco-studio-script` → `thread 'main' panicked: failed to read missing addr file %TEMP%\<包名>-server-addr` → **tauri-cli 自己 panic**。那条钩子（`gen/ohos/entry/hvigorfile.ts` 的 `tauriPlugin`）是给 `tauri ohos dev`（有 dev server）准备的，**非 dev 场景必然失败**，与签名/源码无关。处置：让 hvigorfile 不跑该钩子（本工具 `t2h:hap` 自己把 `lib<模块>.so` 装配进 `libs/arm64-v8a`，不需要它编 Rust），或先 `cargo tauri ohos dev` 起 dev server。已加指纹 **FP-020** + `hapSignHint`；**0.39.53 起由规则 R2-PORT-015 自动注掉那一行**（带 `hvigorfile.ts.bak` 备份、进 `revertPairs()` 可回滚）。实测 juCang：`t2h:hap` 从 `built=false / 0 字节 / 00308018` 变成 **`built=true / 15,338,218 字节`** |
| 115 | 想用 `POST /api/settings` 把 cjh 的轮次预算抬高（`max_iterations`），写完一查**没变**，只能回落成"改配置文件 + 提示需重启引擎" | **同一个设置有两种拼写**：`~/.cjh/settings.json` 里是 `max_iterations`（snake），而 `GET /api/settings` 回的是 `maxIterations`（camel）。只认一种 ⇒ live 路径读到 `-1`、误判"读不到"、白白回落。处置：`maxIterKeyOf()` 两种都认（`ensureMaxIterations` 插入新键时仍写 snake，与文件 schema 一致），单测钉住两种写法；**判据：凡"读别人 JSON 的某个字段"，先把 API 与文件两种形态都摸一遍**（§4-57 是同族：字段名/形态先对账再取值）（0.39.53） |
| 116 | 想给"经验去重键"做小写归一，写成逐字节 `String.fromUtf8([b])` 再拼字符串 → 中文标题**必抛** `IllegalArgumentException: Invalid utf8 byte sequence` | **一个字节单独拎出来常常不是合法 UTF-8**（中文占 3 字节）。凡"逐字节变换后再拼回字符串"，都要**先攒 `ArrayList<Byte>`、最后 `String.fromUtf8(bytes.toArray())` 解一次**——与 §4-113（`stripAnsi`）、§4-62（Byte 插值）同族；遇到"处理中文文本崩"先想这条（0.39.55） |
| 117 | 用 `JsonObject.toJsonString()` 写 JSONL 台账，写完**自己都读不回来**（同签名累计次数永远 1） | `stdx.encoding.json` 的 `toJsonString()` 是**美化输出**（一条记录摊成 4 行、冒号后带空格 `"sig": "x"`）⇒「一条一行 + 按行计数」的前提直接不成立。JSONL 要**手拼紧凑行**（值仍用 `JsonString(x).toJsonString()` 保证转义），读侧对两种形态都容错；**判据：凡"要按行解析 JSON 文件"，先看一眼盘上那行到底长什么样**（0.39.55） |
| 118 | 一行里塞多个字段（`- 次数：2　工程：p　时间：t`），取值取到**整行剩余部分** → `project` 变成 `juCang　时间：2026-11-02 …` | 多字段行的分隔符是**全角空格 `　`**（中文排版习惯）：`indexOf(键)` 之后必须再按 `　` 截断，不能"取到行尾"。写这种"人可读 + 机器可解"的落档格式，字段间只用一个分隔符，并在解析器里把它显式写出来（0.39.55） |
| 119 | **仓颉程序在 Windows 上接不了非 ASCII 的 argv**：`main.exe --help 中文` 直接抛 `IllegalArgumentException: Invalid unicode scalar value`，cmd / PowerShell / bash 三种调用方一样，`chcp 65001` 也没用 | 异常在 `main(args: Array<String>)` **之前**就抛 ⇒ 不是业务代码，是运行时解 argv 的口径问题。**判据：凡是"要传给 lingqu-cli 的内容可能是中文"，一律走文件，不走参数**——内容写 UTF-8 JSON/文本文件，命令收 `--body <文件>`（本项目 `t2h:notes` 即如此）。给 agent 的任务书里**必须写清这条**，否则它会把中文塞进参数、撞一个看不懂的异常后反复重试烧轮次。Linux 未验（0.39.55） |
| 120 | **浏览器打得开 `127.0.0.1:8765`、应用却一直说「未连接」，页脚连原因都没有** | 两条叠在一起：① **ws 握手死在 OpenSSL**——仓颉运行时的 TLS 加载器按**裸名**找 `libcrypto-3-x64.dll` / `libssl-3-x64.dll`，而 **SDK 与 stdx 都不带**，开发机上恰好命中 PATH 里别人带的那份 ⇒ "本机全通、换个启动方式就挂"；症状极具误导：`/api/health` 照常 200（cjh 自己带着这两个 DLL），**只有 ws 挂**（RFC6455 升级要算随机 nonce，明文 `ws://` 也逃不掉），插件原话是 `ws: connect failed: Can not load openssl library or function RAND_bytes.`；② **我们的连接状态只等事件**——`wsConnect()` 原来只靠 `ws:state` 事件置 `CJ.up`，而 invoke 成功不代表事件会到，事件不来时 `CJ.connecting` 永远 true ⇒ 之后每次状态轮询都被挡回去 ⇒ **永久"未连接"且不再重试**。处置：启动早期 `preloadEmbeddedLibrary()` 按绝对路径预加载（候选：单文件释放目录 → `vendor/cjh/win-x64`），`collect-runtime-dlls.sh` 同时把两件收进产物目录；连接语义照 cjnote 改成 **invoke resolve 即连上**、事件只用于发现掉线，失败把插件原话回投 `ui_report.wsErr`。**判据：凡是"http 通、ws 不通"，先怀疑裸名加载的 DLL（OpenSSL / WebView2Loader / sqlite3）**；凡是"状态永远停在某个值"，先查有没有一条路径把 `connecting` 这类闸门变量永久置真（0.39.65） |
| 121 | 框架升级后门禁 ③ 报 `三方比对：无头导出退出异常（code=3221225785）`，手跑 `targets/desktop/target/release/bin/main.exe` 也起不来；退出码换成十六进制就是 **`0xC0000139` STATUS_ENTRYPOINT_NOT_FOUND** | **产物目录里的 DLL 是"缺了才拷"，永远不刷新**：`scripts/collect-runtime-dlls.sh` 原来 `[ -f "$BIN_DIR/$dep" ] && continue`，于是 cj-tauri 2.1.2（11-05）换掉的 `libcjtbridge.dll`（732,160 → 742,912 B）被 11-02 的旧拷贝一直顶着；而 **Windows 加载顺序里 exe 同目录优先于 PATH**，新链接的 `main.exe` 配旧桥 DLL ⇒ 导入符号对不上。处置：脚本改成"缺则拷、**内容不同则刷新**"（`same_file()`：`sha256sum` → 退 `cmp`），OpenSSL 两件同改，汇总行报「刷新 N 个」。**判据：凡是"框架/SDK 升过级之后产物起不来"，先按 `sha256sum` 比对 exe 同目录 DLL 与框架 `native/` 是否同一份**——别去猜导入表；凡是"只在某台机器/某次构建后挂"的 `0xC0000135/0xC0000139`，先查产物目录里的库是不是旧的（0.39.76） |
| 122 | **随包引擎升过级，实际跑的却还是旧版**：0.39.75 把 vendor 换成 cjh 1.6.12，`/api/health` 却回 `version:"1.6.5"`，界面上一点异常都没有 | `cjhBinPath()` 的 ② 档「部署过的安装目录」（`%LOCALAPPDATA%\lingqu\cjh`）**只判 `fileReadable` 就 return**，抢在 ③ 档（vendor，**要 SHA256 校验**）前面命中上一次释放的旧副本。健康检查照样 200、只有 `version` 字段不同 ⇒ "升了级却没换引擎"是完全静默的。处置：② 档也过 SHA256（纯函数 `installBinUsable(可读, 校验通过)`），`cjhDeployAndStart` 的 ② 档同口径（副本不符就 `bsdtar -xf` 重解一次当刷新，解完**再核一次**；没有任何可解来源时如实拒绝，不执行未校验二进制）。**判据：会执行的二进制，「文件在」≠「内容对」**；凡"升级类"改动的验收，必须看**运行期实际用的那份**（进程 `Path` + `/api/health` 的 `version`），只看 vendor 目录等于没验（0.39.77） |
| 123 | 用户反馈「内置的 cjh 引擎起的这么慢」，一查 **15.5 秒**；而 vendor cjh 单独跑 `web --port 8772` 从 fork 到 `/api/health`=200 只要 **85 ms** | 慢的全在**拉起之前**：仓颉的 `ClientBuilder` **没有 connectTimeout**（上游 `cj-tauri/plugin_http.cj` 与 `cjh/web_fetch.cj` 两处注释都记了这坑），目标不可达时卡在 TCP connect —— **端口空着时一次 `/api/health` 要 2007 ms**（`.lingqu/cjh-start.log` 实测），而拉起前先 `cjhHealthyWithRetry(port, 6)` ⇒ 2s + 5×(2s+0.7s) ≈ 15 秒全花在"确认端口上没人"上。处置：先 `TcpSocket("127.0.0.1", port).connect(timeout: 250ms)` 探端口（**一个字节都不发**，不打扰在跑长回合的引擎）——没人在听就立刻拉起，有人在听才走 `/api/health` 的宽容重试（否则会拉起绑不上端口的僵尸，§4-103）。修后 **613 ms**。两条通用判据：① **"探活"问的是哪个问题决定手段**——只想知道"有没有人在听"就别用会走完整 HTTP 流程的客户端；② 凡是"启动慢"，先把**引擎进程的诞生时刻**与**主进程启动时刻**相减，分清是"拉起前慢"还是"拉起后慢"，别对着引擎猜（0.39.78） |
| 124 | 「一键迁移跑到一半不动了」：界面停在「执行中 565s」，**既不报停滞也不给建议**；任务管理器里有个 `find.exe` 累计 CPU 605s | 两件事叠在一起，一半在**上游**、一半在**我们自己**。① **上游 cjh 的超时收尾只杀得掉启动器**：`killSession()` 只 `terminate` 了 `SubProcess` 句柄那个 Git `bash.exe`，真正干活的 `/usr/bin/bash` 被 re-parent 成 `PPID=1`，它 fork 的 `find` 握着 stdout 写端 ⇒ 管道永不 EOF ⇒ `p.wait(5s)` 永挂，超时提示回不到模型。**三种"顺手"写法逐条实测全废**：`taskkill /T /F` 只收启动器（`find` 换 PID 继续活）、按 `ps -W` 的 PPID 递归只收到根 1 个、Windows 原生父链的中间层已消失（`find` 的 ppid 查出来是 GONE）、换 `usr\bin\bash.exe` 让 `p.pid` 指本体也一样。**唯一可靠的是进程组**：worker bash 的 `PGID == 自己`，子命令全在组里 ⇒ 会话启动时让 bash 把 `$$` 写进 `/tmp/cjh-sess-<启动器pid>.pid`，收尾 `kill -9 -$(cat …)` 整组收（cjh MR #12）。② **我们的 `agentTraceBusy()` 豁免没有时间上限**：工具一挂死 `busy` 永远为真 ⇒ 每轮 `clearHistory()` ⇒ 停滞判定被永久按住 ⇒ 界面只剩沉默。处置：`AUTOPORT_BUSY_MAX_SECS=300` + `busyStillExempt()`，超限恢复判定并把 `busySecs` 回投当证据；同时把「**禁止全盘搜索**（`find /` / `dir /s C:\` / 扫盘符根）、脚手架只在 `<工程>/gen/ohos` 与 `<工程>/src-tauri/gen/ohos`」写进任务书纪律。**三条判据**：① 凡是「某个状态永久卡住」，先问它有没有**时限**（豁免/退避/重试窗口最容易忘上限）；② 跨语言/跨子系统的进程清理，"父子关系"在 Windows+MSYS 下**经常是断的**，别按父链设计，按**进程组 / Job Object**；③ 上游失手时我们至少要能**说清在等什么**——不说话的等待等同于挂死（0.39.80） |

| 125 | 交叉编译落档写着 `ok=true / exitCode=0 / errorCount=0`，界面报"通过"，可 HAP 装不上——产物是 **11,084,368 字节的 exe**，不是 `lib<name>.so` | **编译成功的判据 ≠ 移植产物的判据**：样本只有 `src/main.rs`（bin target），Cargo 自然编出一个可执行文件；HAP/ArkWeb 要的是 `[lib] crate-type=["cdylib"]` 生成的 `lib<name>.so`。旧 build 只判 `exitCode`/`errorCount` ⇒ **假绿**（0.39.79 记的"build 假绿"）。处置：新增**鸿蒙产物闸** `checkOhosArtifactGate`——编译失败时不重复报，编译通过却没预期的 `.so` 就 fail，并按「有没有 cdylib 声明」分两档提示（没声明 = 移植没做完，别去查编译参数）；期望产物名由 `expectedLibNameOf`（`[lib] name` → 包名 → 工程名）与 `hasCdylibCrateType`（**注释里的 `cdylib` 不算数**）解析，`expectedSo` 进 build 落档当证据。**两条判据**：① 凡是"产出了东西就算成功"的闸，都要点名**期望产物的确切文件名**（§4-46 同族：别用"至少有一个 .so"这种弱判据）；② 判"跳过"前先看**声明**（`[lib]`/`crate-type`），别拿"编译过了"当"该有的都有了"（0.39.81） |
| 127 | 迁移跑到一半界面报「引擎还没起来」，应用自己又拉起一只；任务管理器里**3 只 `cjh.exe` 同时监听 8765**，WS 还挂在上一轮的孤儿上。用户"过了会儿它又自己连上了" | **判据只有 Bool，把"忙"和"没有"混成了一件事**：`cjhCheckBeforeSpawn` 对「端口空着」与「端口有人听但 `/api/health` 超时」**都返回 false**，而 `ensureCjhWeb` / `cjhDeployAndStart` 都把 false 读成"没有引擎 → 拉起一只"。引擎跑长回合时 health 本来就会超时（②）⇒ 误判 ⇒ 又不加锁（③）⇒ 两路并发各拉一只；**Windows 允许重复绑定同一端口**（SO_REUSEADDR），第二只静默"就绪"，之后 WS 与 REST 可能落在不同实例上（会话/模型/预算全对不上）。处置：① 判据升级成三态 `CjhSpawnDecision{Spawn,Reuse,Occupied}` + 纯函数 `spawnDecisionOf`（`Occupied` = 有人在听但读不到 ⇒ **绝不拉起第二只**）；② `probeCjhForSpawn` 先 `TcpSocket` 探端口，没人在听才拉起；③ `ensureCjhWeb`/`cjhDeployAndStart` 整段加 `gCjhSpawnLock`（探活→判断→拉起是读-判断-写）；④ `cjh_status` 不再把"有监听读不到"报成 `ready`，改 `running+portBusy+原因`；⑤ 探死原因（`gLastHealthErr`）落进 `.lingqu/cjh-start.log`。**三条判据**：① 凡是"要不要做某事"的判据里同时包含"不存在"与"暂时不可用"，就必须分开（Bool 装不下两种事实）；② 凡是"探活→动手"的序列，先问**并发时会不会各做一遍**；③ 服务类端口"绑定成功"不代表你是唯一实例——**同端口多实例在 Windows 上是静默成功的**（0.39.82） |
| 128 | 明明把 `max_iterations` 抬到了 120，整应用迁移还是跑到 **回合 62/40** 断掉，界面只写"回合结束" | **"写进去了"被当成"生效了"**：`ensureCjhIterationBudget` 的 live 路径不通时会落文件并返回 `file:…（需重启 cjh 生效）`，而调用方只 `eprintln` 结果、**没人区分返回值形态**；正在跑回合的引擎内存里还是默认 40（叠加 §4-127 的多实例，live POST 落到的未必是干活那只）。处置：`iterBudgetStateOf` 把 `live:`/`restart-ok:` 判为真生效、`file:` 一律等于没生效；`enforceIterBudgetBeforeRun` 在**开跑前**对"需重启"的自己拉起引擎做一次重启（~0.5s）再回读，非本应用拉起的按 D-003 只回投"需人工重启"。页面侧再加一层保险：回合因预算结束时若迁移监管态仍在跑且未停滞，**自动续跑**（`AUTO_CONTINUE_MAX=3`，到上限明确交回人），并把次数回投 `ui_report.autoContinue`。**三条判据**：① 凡是"设置类"改动，验收看**运行期实际读到的值**，不看写入返回值；② 返回串的**形态**（前缀）就是语义，调用方必须分支处置，不能一律 eprintln；③ 长任务"做一半停"要么**开跑前把前置条件修好**，要么**停了就自动接上**——把原因写清了但什么都不做，仍是坏体验（0.39.82） |
| 129 | 用户问「没有提示让我访问网页登录呀」；同一轮登录命令最长要等 5 分钟，期间整个界面像卡住 | **长任务占着 IPC + 结果只回聊天**：`t2h:sign --login` 是同步 handler（起本机回调、等人点浏览器，最长 300s），§4-68 明令这种要起后台线程；而且登录页 URL 只存在于函数内部/输出文本里——**页面既拿不到"正在等你登录"，也拿不到那条链接**，人只能从 cjh 的聊天文字里猜。还有一层：界面跑在 WebView2/ArkWeb 里，`<a target="_blank">` **不保证**能唤起系统浏览器（点了没反应比没有链接更糟）。处置：拆成 `t2h:sign_login`（起后台线程，立刻返回）+ `t2h:sign_login_status`（只读共享状态，回投 `url/port/running/done/error`），登录页地址在 `agcLogin` 算出时通过 `publishSignLoginUrl` 公布；界面签名屏把链接给成**按钮**，点击走 `t2h:open_url`（`rundll32`/`xdg-open` 按 argv 传参，不经 shell，避开 §4-80 的 `&` 截断）；回合结束若最后一条工具报错含"登录"，主动起登录并提示入口；证据回投 `ui_report.signLoginState/signLoginUrl`。**三条判据**：① 凡是"要人去做一件事"的步骤，界面必须给出**可点的东西**，不能只写文字；② 链接在 WebView 里能不能打开**要实测**，别假设 `target=_blank` 生效；③ 长任务的状态必须能被另一条命令**轮询**到，否则等于没有状态（0.39.82） | ① **二次 `--apply` 覆盖原始备份**：Cargo.toml 的备份是 `File.writeTo` 直写，重跑一次 apply 就把迁移后的内容存成"原始备份"，revert 只能"回滚成迁移态"（`backupFile` 早有"已存在不写"，这条路径绕过了它）。② **备份目录相对/绝对不一致**：`backupDirOf(safeName)` 返回 CWD 相对的 `.lingqu/port/<工程>`，apply 写的却是 `<工程>/.lingqu/port/<工程>` ⇒ CWD 不是工程目录就**永远**"没有备份"。③ **回滚表写死 `src-tauri/`**：扁平布局工程（`src-tauri` 就是工程根，如 rust-music-2）回滚时一个文件都对不上。处置：备份目录收成**唯一构造点** `portBackupDirOf(projectDir, safeName)`（apply 与 revert 共用），回滚单元改用 `REL_SRC`/`REL_PROJECT` 标记 + 纯函数 `resolveRevertTarget` 按实际布局解析（解析不出返回空串 → 计 `skipped`，**不猜路径**），单 bin 工程的 `lib.rs` 兜底也不再写死 `src-tauri/src/main.rs`；`t2h:port` 每次跑完还落 `decisions.json` 的 `portRun` 块（以前只有记过人工决策才生成，断点板看不出"跑过 port 没有"，§4-58 的窟窿）。**三条判据**：① 备份/回滚这类"成对"的路径**只能有一个构造点**，两侧各拼一份迟早漂移（§4-33）；② 写盘前先问"**已存在时这样做还对吗**"——备份、安装、缓存都适用；③ 凡是写死 `src-tauri/` 的地方，都要问一句"扁平布局呢"（0.39.81） |
| 130 | 用户实测后点破：「cjh 的提示词是不是没给全？它不知道自己该跳转签名页让我签名，最后是拉外部浏览器让我登录」 | **工具有能力、任务书没写**：`lingqu-cli sign --login` 与 `sign --auto` **本来就存在**（`src/cli.cj` 的帮助里就写着，`--auto` 一条命令跑完 设备→证书→profile→写回），但 `buildAutoPortDirective` 的工具箱只有 `sign --path .`，半自动 `scope=sign` 更只剩"体检 + 写回"一句 ⇒ agent 只能瞎摸，摸到"自己开浏览器登录 AGC 网页"这条死路（拿不到本机回调的 `tempToken`、也不把设备注册进 profile，签名照样过不了，白花一次人工介入）。现场证据：样本 `.lingqu/sign-login-stdout.txt` **是空的**、`sign-auto-stdout.txt` 只有 `[exit code 1]`。处置：任务书补「签名与登录」整节——顺序写死 体检 → `--login` → `--auto` → 重跑 `hap`；**明令禁止**用 `start`/`rundll32`/`open` 自己开浏览器；要人登录时用 `lingqu-decision` 一次说清「为什么必须登录 / 点哪里 / 本机 UDID 是多少」；五个报错号对照（`9568320` / `9568322` / `00303074` / `00303242` / `9568332`）写进正文；纪律里那句「release 态装不上是正常的」改成区分 **release profile 无 device-ids（正常）** 与 **debug 材料缺本机 UDID（要人登录）**。**三条判据**：① 凡是"命令层/CLI 已经有"的能力，任务书必须写进去——**能力在手、说明书没给 = agent 只能瞎摸**；② 同一份知识不许只写在一条分支里（全流程补了、半自动同一步也得有，否则"只点这一步"反而知道得更少）；③ 写"某报错是正常的"时**必须把同号不同成因的那种也写清**，否则 agent 会拿它当挡箭牌放过真问题（0.39.83） |
| 131 | 用户追问「修复的 cjh 替换 vendor 下的没？」——一查：修好的**超时杀树从来没进随包**，应用一直在跑官方 1.6.12（新二进制有的 `sessionPgFile` / `/tmp/cjh-sess-` 特征串，旧的一份 **0 处**） | **"修在分支里"≠"发出去的是修好的"**：`vendor/cjh/win-x64/cjh.exe` 是 0.39.75 灌的官方版（SHA256 `2cb384f0…`），PR #12（`9a4f6d5`）只活在 cjh 仓的**本地构建产物**里；更要命的是**两版版本串都报 `cjh v1.6.12`**，拿 `--version` 永远发现不了差别。处置：从修复分支重建 → 换入 vendor（13,769,216 B，`7dda9caf…`）→ **同步改两处**：`vendor/cjh/SHA256SUMS` 与 `src/cjh_host.cj` 的 `CJH_VENDOR_FILES` 常量（漏一处 `cjhVendorVerified` 就判不过，引擎「验不过绝不执行」= 直接不可用）。**三条判据**：① 判"修好的二进制有没有发出去"看**特征串/行为证据**，不看版本号（同版本号可以对应完全不同的字节）；② 换随包二进制必须**清单与代码常量一起改**（§4-33 成对路径同族）；③ 验替换成功要**逐文件 SHA256 + 直接跑一次 `--version`**，别只看文件大小（0.39.84） |
| 132 | 照 `scripts/winbuild.sh` 重建 cjh，报一串 `root package 'cjh' imports package 'stdx.encoding.json' … not added as a dependency`；改成 `D:/` 路径后报错又挪到子包 `cjllm` | **两件事**：① `winbuild.sh` 追加的目标键是 `[target.x86_64-pc-windows-gnu.bin-dependencies]`，而 cjpm 在 Windows 宿主上判「该 target 等价于本地 target `x86_64-w64-mingw32`」⇒ **走原生编译、追加段不被采信**；② cjh 的 `libs/*` 五个子包各自也有 `cjpm.toml` 且只有 Linux 的 `[target.x86_64-unknown-linux-gnu.bin-dependencies]`。处置：**根包 + `libs/{cjcfg,cjconfig,cjllm,cjlog,cjterm,cjutil}` 都补 `[target.x86_64-w64-mingw32.bin-dependencies]`**，路径写 **Windows 形式 `D:/…`**——cjpm 是原生程序，写 `/d/…` 会直接报 `can not find path '/d/cangjie-stdx/…'`（与 §4-16 的 MSYS 路径坑同族，但方向相反：**给 cjpm 的路径必须是 Windows 形式**）。三个 `cjpm.toml` 全用「备份 → `trap EXIT` 无条件还原」保护，跑完 `git status --porcelain` 必须为 0。另：本机 `x86_64-w64-mingw32-strip` 是调 `llvm-strip` 的壳而 llvm-strip **缺失** ⇒ 裁剪改用 `/c/tool/llvm-mingw-…/bin/objcopy.exe --strip-all`（38,822,400 → 13,769,216 B）（0.39.84） |
| 133 | 迁移报告屏写着「核心功能可用率（A4 ≥80%）**66%**」，可 `.lingqu/verify/<工程>.json` 与 `.lingqu/report/<工程>.json` **都是 100%**（21:19 同批生成） | **真值没错，错的是界面"那一代快照"**：⑦ 屏的 `REPORT` 只在「点生成迁移报告」与「AI 迁移收尾」时渲染，⑥ 屏把验证从 66%（`launch` 判 fail）重跑到 100% 之后**没有任何东西叫它重出**，旧数字就一直挂在屏幕上——而界面上**没有一句"你看到的比落档旧"**。证据形态很典型：`.lingqu/ui-report.json` 里 `verifyRate: 100` 与 `reportRate: 66` **并排出现**，两个口径自己打架。处置：① 进 ⑦ 屏先校正新鲜度（`autoReportOnEnter`，key = 工程路径 + ⑥ 屏当前可用率；同代就跳过，避免反复写盘）；② ⑥ 屏 `t2h:verify` 成功后把报告标脏（`REPORT_AUTO.key=''`）；③ 不同代时 `rpNote` 明写"这是旧快照：它按 66% 算的，落档已是 100%"；④ `ui_report` 增 `reportStale`/`reportGeneratedAt`/`reportAutoCount`（**两处一起加**，§4-60），自检 `LINGQU_UI_PROBE=reportstale`。**通用判据**：凡是"按落档渲染出的一份快照"（报告、矩阵、断点板、诊断），都要有**"这是哪一代"的位**（生成时间/来源计数）与**"落档变了会不会跟上"的通道**；"两个屏幕上的同一个指标并存且不一致"永远优先怀疑**渲染时机**，而不是取数字段（§4-63 的第三态：*跑过了，但屏幕上是上一代的结果*）（0.39.85） |
| 134 | 用户实测：「在上次完成移植的基础上重新选了个新项目，但 **AI 自动迁移还是上次执行完的状态，不能点**」 | **"点不动"与"显示旧的"是两个独立根因，只修一个都会让人觉得没修**：① `#btnAiPort` 只在 `r.ok !== true` 与 `invoke` 异常两处恢复 `disabled = false`，**成功路径再没有一处置回** ⇒ 点过一次之后它在整个进程生命周期里都是死的（换工程、重开设置页都救不回来）；② `setCurrentProject()` 只换路径回显 + 顶栏胶囊 + 左栏徽标，**运行态一个字没清** ⇒ 进度条、时间轴、结果卡、AI 过程消息，以及 ⑤⑥⑦ 三屏的数据面板全挂着上一个工程的数字。处置：内层 `resetProjectRunState(prev,next)` 挂 `window.__onProjectSwitch`，由外层经桥调用（§4-107）；停两条轮询 → `AIP`/`MIG` 归零（`AIP.active` **必须**归零，否则 `noteTurnEnded` 会把后续普通问答当成"迁移还没完成"，0.39.63 同族）→ 面板按**初始化快照**还原（手抄占位文案 = 多一份漂移源）→ 状态对象清成**空对象**而不是"初始形状"（`renderPipeline` 判 `dp.ok === false` 会写「安装失败」，把"没跑过"渲染成"失败"是另一种谎报，§4-63 反向）→ 按钮恢复、「停止」只在真在跑时留着；切换判据用 `normPathKey`（`E:\x` 与 `E:/x` 是同一工程，否则"重复设为同一工程"也会把面板白白清掉，§4-95 同族），同时清 `PATH_OVERRIDE`；切换时 `AIP.active` 为真则**照清面板但明写"上一个工程那次没被停止"**（偷偷清掉同样是不说实话）。断言 `ui_report.projSwitches/projResets/aiPortBtn` + `LINGQU_UI_PROBE=projswitch`。**三条判据**：① 任何 `disabled = true` 都必须有**配对的置回路径**，否则就是永久死按钮；② "换了上下文"（工程/会话/分支）时，面板就是**该上下文下的观测结果**，不清 = 拿别人的数字冒充现状；③ "重置成未开始"要重置成**空**，不是重置成"失败"——"没跑过"与"跑失败"在落档里是两个不同的位（0.39.86） |
| 135 | 用户实测：「执行 AI 自动迁移后会自动执行左侧的迁移画像和依赖扫描等操作，但**各个项里面的内容没有更新**，看到的可迁移度等仍是空的」 | **不是 AI 没干活，是没人去读它干出来的东西**：① 迁移画像 / ② 依赖扫描两屏的渲染**只挂在人点按钮**上（`btnScan` → `runScan` → `renderScan`），AI 走的是 `lingqu-cli scan\|deps`，落档写进 `<工程>/.lingqu/scan\|deps/` 却**没有任何路径读回界面** ⇒ "AI 说扫描已完成"与"可迁移度空白"同时成立（与 §4-133 同族：干活的那一方写了落档、显示的那一方没跟上）。处置：① `t2h:scan` / `t2h:deps` 加 `action:"load"`（`scanRecordResponse` / `depsRecordResponse`）——**纯读盘、绝不重跑**：重跑得到的是"现在这一刻的数"，用户拿它去对落档就会对不上（§0.1「落档说了算」）；扫描落档 `lingqu/scan/v1` 自包含 `metrics`/`score`/`items`/`blockers`，回读出来与落档逐字一致。② 进屏自动回填（`__onScreen('profile'\|'deps')`）。③ AI 轮询里按 `MigrateRow.ran` 的**假→真跳变**回读一次（"跑没跑过"与"跑没跑过闸"是两个位，§4-63）。④ 换工程清 `STEP_SEEN`/`STEP_FILL`，否则新工程被旧记忆挡住。⑤ 落档不存在时 `ok=false`+`loaded=false`+原因，**不把"没跑过"渲染成"扫描失败"**。断言 `ui_report.stepFillN>0 ∧ scanScore>=0`。**两条判据**：① 凡是"agent 会自己跑"的步骤，界面都**必须有从落档回读的通道**——按钮触发的渲染只覆盖"人点的那条路"；② 回读**只能读盘、不能重跑**，否则屏幕与落档成了两份互不相干的数字（③–⑦ 屏尚无同类回读，见 `docs/进度记录.md` 0.39.87 未验证段）（0.39.87） |
| 136 | 界面一直写「**进行中**：正在处理「交叉编译」」，可 agent 早收工了（轨迹里 `turn_done`，rounds=33）；用户盯了五分钟以为它还在跑 | **状态只有"在跑/完工"两档，漏了第三档「已交接」**：`stalled` 只认"落档连续不变"，而 agent 一收工落档当然就不动了，但攒不满 20 次快照 ⇒ `stalled=false`；`finished` 只认 8 步全有结论 ⇒ 也是 false。两种假都指向同一格：**没人推、也没人知道**。处置：`handoffDue(turnEnded, allConcluded, busy)` 三条同时成立才判交接（轨迹最后一条是 `turn_done` / 活没干完 / 没有工具在跑），`verdict` 改成「AI 本轮已收尾——已交接给你：x/8 步有结论，卡在「X」」，note 里**贴最后一条工具报错**并写明"光等它不会自己再动"。判据只认落档/轨迹（`agentTraceTurnEnded`），不靠页面记忆。**两条判据**：① 任何"跑着/跑完了"的二元状态，都要问一句**"那没人干的时候显示什么"**——第三档不许默认落进"在跑"；② 反方向同样致命：报"已交接"必须**三条全中**，正在跑分钟级编译时报交接等于把干活的 agent 打断（§4-124 同族）（0.39.97） |
| 136 | 结论句写「核心功能可用率 0%（**4/3 项有结论**，另 4 项未测）」，用户当场质问"其他核心功能不可能 0%" | **分子分母取自两个不同集合**：分子 `verifyPass` 是全局通过（含 launch/build/hap/frontend 装配项），分母 `verifyCovered` 只数功能项 ⇒ 数字自相矛盾（分子比还比分母大），真实能力也被"未测项不进分母"压成 0%。处置：`VerifyStats` 单列 `featurePass`，`features` 口径用它与 `covered` 同源相除；同时补**真机实测落档通道** `.lingqu/verify/<工程>.probe.json`（判定顺序 **真机实测 > 人工实测 > 静态推断 > 未测**，且不虚增 A3）。**三条判据**：① 任何比例的分子分母必须同源，写出来先自查"分子会不会大于分母"；② "未测"不进分母是对的，但要意识到**分母会变小**——小分母的百分比必须把"另 N 项未测"放在同一句里，否则读者只看到夸张的 0%/100%；③ 有能力就该有落档通道：只有 `human.json` 时，我们自己做的实测无处可写，等于把已经知道的事实丢掉。**取坐标只能用 `uitest dumpLayout` 的 `bounds`（真实像素）**，别按缩放后的截图估算——实测因此点到了「限速」输入框而不是「开始下载」（0.39.93） |
| 136 | 探针"跑过了"，其实**什么都没测到**：`LINGQU_UI_PROBE=reportstale` 三段回投全是 `reportStale=false`，看着像"通过" | **判据自己带前提**：`reportStaleNow()` 是「报告里的可用率 `a` **且** ⑥ 屏当前可用率 `b`」**两边都有数**（`a>=0 && b>=0`）才比；拿一个**没有 `verify` 落档**的工程跑，`a=-1` ⇒ 第二段（强行把 `VERIFY.rate` 改成 7）永远亮不起来。换带 `stats.verifyRate=100` 的 `habit-tree` 才真正亮到 `true`。**判据：探针要断某条判据，先确认它在这份样本上"可能为真"**——假绿比失败更危险，它长得跟通过一模一样（与 §4-63「没跑过 vs 跑了没过」同族：这次是*测了 vs 没测到*）（0.39.87-验证） |
| 137 | 跑完探针，界面把 `E:/tmp/lingqu-probe-pa` 当成「上次工程」恢复 | **用假路径做断言的探针会自己把污染固化下来**：① `setCurrentProject()` 会把该路径的落档目录**建出来**（`tasks.json` 等），于是 `exists` 判据从此为真；② `ui_report.currentProject` 被写成假路径，而它正是下一次启动 `lastProject` 的来源（`lastProjectFromReport`）。**凡是拿假路径做断言的探针，收尾必须复原「上次工程 / 最近项目」**；排查口诀：开窗就落到 `E:/tmp/…` 这种不在业务里的路径，先怀疑上一次探针（0.39.87-验证） |
| 138 | 想用 `LINGQU_SCAN_PATH` 顺手"恢复现场"，结果它**真重扫了一遍**，把落档 `score.total` 从 77 改成 72 | `LINGQU_SCAN_PATH` 接的是**真人点按钮那条路**（`runScanProbe` → `t2h:scan` 真跑），**不是回读**；回读只有 `action:"load"` 与进屏 `fillStepFromRecord`。要证明"屏上显示的是落档里的数"，就**别让同一次启动顺手重扫**——两份数会互相覆盖，事后分不清那个值是读来的还是算来的。判据：验回读时环境变量只用 `LINGQU_UI_SCREEN`，扫描类探针另开一轮（0.39.87-验证） |
| 139 | 同一块屏幕上两处说法打架：提示写「换了工程：**这里还没跑过**」，左栏六个徽标却全「已完成」（用户实测） | **"没跑过"必须来自落档，不能来自"刚换了工程"这件事本身**：`resetProjectRunState` 换工程时**无条件**写「这里还没跑过」⇒ 与读落档的左栏自相矛盾，而且它长得像事实（§4-94 / §4-63 同族，这次是*没跑过*方向的谎报）。处置：提示改成按**同一次 `t2h:resume` 结果**三档生成（`has-record` / `empty` / `unknown`），与左栏徽标共用一份数据；`wasActive` 那档（「上一个工程那次没被停止」）**不许**被落档实况顶掉；`ui_report` 增 `switchNoteKind/switchNoteSteps/switchNoteOk/switchNoteFail`（两处一起加，§4-60）。**第二条（探针假绿）**：断言写 `indexOf('旧落档')`，而**旧文案里本来就有**「要沿用旧落档就点…」⇒ 第一次跑出来是绿的（§4-65 同款）。凡断"某句提示变了"，必须断**只有新行为才会出现的词**（这里用「有旧落档」），并加一条"旧措辞不许出现"的反向断言。**判据**：① 界面上两处对同一件事的说法必须**同源**（读同一份落档），否则迟早打架；② 探针一次就绿时，先怀疑断言会不会被旧文本满足（0.39.88） |
| 140 | ⑦ 迁移报告屏报 `reportOk=false / reportRate=-1`（看着像"从没生成过"），可 `.lingqu/report/<工程>.json` 明明是 19:26 生成的那一份，结论俱全 | **回读通道只补了一半**：0.39.87 给 ① 迁移画像 / ② 依赖扫描补了 `action:"load"`，0.39.88 又给 ⑤ 构建 / ⑥ 验证补上，**⑦ 报告屏漏在外面**——它的每个数字都挂在 `REPORT` 这个"这次生成出来的"对象上，只有人点「生成迁移报告」才被填，于是 agent 用 `lingqu-cli report` 跑过的落档在界面上等于不存在（§4-135 同族，第三次漏网）。处置：`t2h:report {action:"load"}` + 纯函数 `reportRecordOf`（按盘上 `lingqu/report/v1` 抄字段，嵌套 `risk{…}` 展成界面要的扁平 `riskXxx`，`files.md/html` 是**相对 CWD** 的路径必须按工程路径重定位），进 ⑦ 屏**先回读、再判要不要重出**（重出要写盘、会改数字，必须排在只读回读之后）；`ui_report` 增 `reportLoaded/reportSource`（断言 `reportLoaded=1 ∧ reportOk=1`）。**两条判据**：① 给一个屏补了回读通道，就要**把同族的屏全列一遍**（这次 ①②⑤⑥ 都补了、⑦ 漏了）——补漏靠清单，不靠"想起了哪一屏"；② 凡是"屏幕上的数字只有某个人为动作才会刷新"，都要问一句**"agent 自己干完的时候谁来刷"**（0.39.98） |

---

| 140 | 用源码判"这个函数在鸿蒙侧有没有实现"，第一条用例就红：**没有 `#[cfg]` 的函数被判成了鸿蒙分支** | **回看属性时的窗口不能只按字节数截**：`fnImplsOf` 原先取"`fn xxx` 往前 600 字节"当属性区，结果把**上一条函数**的 `#[cfg(all(... target_env = "ohos"))]` 圈了进来 ⇒ 无 cfg 的函数也被认成"鸿蒙实现"，判据整个反过来（`hasOhos` 变真、空壳判定失效）。处置：属性区只从**上一个条目结束处**算起——往前找到最近的 `}`（上一条 fn 的收尾）就停。另一条同源判据：`not(...)` 里也含 `ohos` 字样，判"鸿蒙分支"必须 **含 `ohos` 且不含 `not(`**，否则桌面实现被误认成鸿蒙实现。**判据**：凡是"按邻近文本判定归属"（属性、注释、doc block、宏前缀），都要有**明确的边界**（上一个声明的收尾 / 空行 / 顶层分隔），别用固定字节窗口——窗口一大就把别人家的东西算自己的（0.39.89） |
| 141 | "写了等于没写"的函数判不出来：现场鸿蒙分支是 `Ok(None)`（返回 `Result`），而空壳判定只认 `None` / `return None;` | **判空返回要认"包装形态"**：`None` / `return None` / `None()` / `Ok(None)` / `Some(None)` 在语义上是同一件事，只比字面量就会漏掉一半现场写法（漏掉的那一半恰好在真机上让按钮点了没反应）。处置：`unwrapToValue()` 逐层剥 `return` 与 `Ok(`/`Some(`/`Err(` 外壳再比 `None`。**判据**：判"等于没实现"时，先把现场可能的**返回形态**列全（裸值 / `return` / `Result`/`Option` 包装 / 占位宏），再写比较；只对着自己脑子里那一种写法写，等于只测自己。另附两条编译期小坑：① `public func` 返回 `internal` 类会报 `'public' declaration uses 'internal' types`（要一并公开该类）；② 仓颉字符串字面量只能用 `"` 包裹，**中文引号要写成「」**，在字符串里直接写 `"全都可用"` 直接编译失败（0.39.89） |
| 142 | 用户报「点『选择』不弹文件选择框了吗？」，查按钮/权限/插件全是好的——**窗口其实是个"已经退出到一半"的空壳** | 现象与根因隔着一层：那轮 12:14:53 日志出现过 `[cj-bridge] destroy: host thread still running, handle kept`（事件循环结束、宿主开始销毁），此后**窗口仍可见、进程仍在**，页面照旧发 `js -> native`（实测 467 条），但原生回投 `ExecuteScript` **0 条** ⇒ 所有 invoke 的 Promise 永不 settle ⇒ 不弹框、不报错、连 `prompt` 兜底和 `.catch` 都走不到。同一版程序 5 分钟前还成功弹过 5 次目录框（`dialog: kind=6 … ok=1`），所以"按钮坏了"是错觉。处置：页面加**后端心跳**（`system:ping`，连续 3 次无回包 ≈15s 判定失联，单次不算——长回合时 IPC 会短暂排不上，§4-103 同族），亮红条明写「后端已停止响应…请关闭后重新启动」，并在判失联那一刻立刻 `reportUi('backend-lost')`（此后 IPC 全哑，再等就没有第二次上报机会）；字段 `backendLost/backendMiss/backendOkBeats/backendAgeSec/backendWhy/backendNote/backendProbe/backendProbeFail`（**两处一起加**，§4-60）；判据写成纯函数 `backendVerdictOf(miss, ageMs)` + 自检 `LINGQU_UI_PROBE=backendlost`。框架侧已提 cj-tauri issue #8（`cj_plat_fini` 早退后窗口既不销毁、也不给调用方任何"没做成"的信号）。**三条判据**：① 凡是"按钮点了没反应"，先分清**是按钮的问题还是对面已经没人了**——查"入站有没有回投"最快（`js -> native` 与 `ExecuteScript` 计数一对比就清楚）；② 界面绝不能因为"事件没来"就静默——状态类判断要么自己发心跳，要么超时降级成"未知"（§4-111 同族）；③ 探针断"处置说明"要断**动作**（含"关闭"+"重新启动"），别断某个词连续出现（§4-65：第一版断言写 `重启`、文案写的是「重新启动」，探针当场红）（0.39.90） |
| 143 | 改了业务包与骨架，`cjpm build` 回 exit 0 且**一行输出都没有**，可运行起来还是旧行为（新加的 `ui_report` 字段照样被丢） | 三件事叠在一起：① 手跑构建时**没把 `CANGJIE_HOME/bin` 放进 PATH** ⇒ `cjpm: command not found`（**exit 127**）；② 命令写成 `cjpm build 2>&1 \| tail -20` ⇒ 管道的退出码是 `tail` 的 **0**，127 被吞掉；③ 于是"构建成功"是假象，`main.exe` 的时间戳还停在几小时前（本次实测 13:10 说"构建完成"，产物却是 **10:52** 那份）——用的是 `DirectoryAssetResolver("assets")` 所以页面居然更新了（`LINGQU_UI_PROBE` 探针能跑），**唯独后端白名单是旧的**，症状表现为"页面发了新字段、报告里却没有这个键"，极易误判成 §4-60 又漏了一处。**判据**：① 跑构建**不许用管道收输出**（要短输出就用工具自带的 `output_tail_lines`），或用 `set -o pipefail`；② 验收"改的东西真生效了"看**三重证据**：产物 mtime 变新 + `cjpm build` 的真实退出码 + 行为侧字段/日志；③ 手跑构建一律走 `./scripts/run-dev.sh -b`（它自己配 PATH 与运行库），别手工 `export` 半套环境（§4-27 同族）（0.39.90） |
| 144 | 真机样本构建**三次全红**、闸报「`.so` 里没有内嵌前端资源」，可 `.so` 里明明嵌着 `index.html`／`/index.html`（各 5 处） | **三层叠加**，修一层还是红：① tauri v2 的 `frontendDist` 是 **`build.frontendDist`**（嵌在 `build` 段），旧代码按**顶层键**取 ⇒ 永远空串；② `tauri.conf.json` 在**扁平布局**下位于工程根，旧代码只看 `src-tauri/` ⇒ 配置都读不到；③ 两处取键只认 vite 的 `assets/` 前缀，而该工程是 `frontendDist: "ui"` + 单个 `index.html` ⇒ 抽 0 键。处置：`jsonStringPathOf`（点路径取值，`build.frontendDist` 与顶层两种都认）+ `resolveDistDirOf` 两处 conf 位置都找 + `assetLayoutOf`/`distEntryKeysOf`/`compareEntryKeys`/`binaryContainsKey`（`assets/` 有产物走老三方比对，只有入口文件走**存在性**比对）。**别改成"扫所有像路径的串"**：`.so` 里 `module.json` 之类会被当资源，那是另一种假红。真实数据验证：`rust-music-3` 跑 `build --verifyOnly` → `passed:true`、`distDir=…/ui`、`failures:[]`。**判据：闸报红时先问"是工程没迁好，还是我们的判据只认一种布局/一个字段名"**——`build.frontendDist` 这种"字段藏在段里"的同族坑见 §4-115（`max_iterations` vs `maxIterations`）（0.39.91） |
| 145 | `t2h:hap` 报 `ohpm install 起不来：Created process failed, errMessage: "The system cannot find the file specified."`——可 `ohpm.bat` 文件就在那儿 | Windows 的 `CreateProcess` **不能直启 `.bat`/`.cmd`**：文件存在也报"找不到文件"（误导性极强，会被当成路径写错）。正解：DevEco 自带的 `tools/ohpm/bin/pm-cli.js` 用 `tools/node/node.exe` 直跑（实测 `--version` → `6.1.2.285`），与 hvigor 的 `node + js` 同款、**不经 shell**（顺带避开 §4-80 的 `&` 截断）。判定收成 `ohpmLauncherOf(...)`：Windows 优先 node，POSIX 仍用 `.bat`，都没有就如实报"缺 ohpm"，不许静默跳过。**绝对不要改 SDK 里的 `ohpm.bat`**——换个环境/换个人就没有了（2026-11-08 用户当场指正）（0.39.91） |
| 146 | 轮次预算「明明抬到了 120」，下一个回合还是 **41 轮**就断；一查 `~/.cjh/settings.json` 里仍是 `max_iterations: 40` | `POST /api/settings` 只改**引擎内存**；旧 `already` 判据只看 live 值 ⇒ 判定"已满足"、**不落文件** ⇒ 引擎一重启回落 40（`cjh.log` 里 `41 rounds` 实测 15 次）。处置：`iterBudgetSatisfiedOf(liveValue, fileValue, target)` —— **两处都达标才算满足**；live 达标时也照样把文件抬上去；文件没落成就在返回值里明写「重启会回落」，**不许报 already**。**判据：凡是"设置类"改动，验收看运行期实际读到的值 + 落盘值两处**，别信其中一处（§4-128 的同一族，这次是"被内存值骗"）（0.39.91） |
| 147 | 一键迁移跑到签名这步**没弹出网页让登录 AGC**，用户只能看着"停了" | 两层夹击：① **agent 没跑 `sign --login` 就直接 `sign --auto`** —— 它拿到的只是"token 可能已失效，重跑 `sign --login`"这句 stdout，而**CLI 的登录链接只打到 stdout，人看不见**；② 应用侧"回合结束自动起登录"的判据**只看最后一条工具报错**（`CJ.lastToolErr`）——现场卡点在中间的 `sign --auto`，随后 `deploy` 也失败把它盖掉了 ⇒ 判定不触发、入口一次没递出去。处置：`CJ.needLoginSeen` **整回合留痕**（任何一条工具失败命中 `loginHintOf` 就记下，回合结束据此起登录并给可点按钮），`loginHintOf` 同时认中文「登录」与英文 `login` / `token 可能已失效` / `拉团队列表失败`。**两条判据**：① "需要人动手"的信号**不能存在"最后一条"里**——同一回合后面的失败会把它盖掉（§4-113 的同族升级版）；② 工具已经把能力（`sign --login`）做出来了，**文案却还写"去 DevEco 手点"** ⇒ agent 照着做就只能停在等人（§4-130 同族）。已把 `sign.cj` / `main.cj` 里 9 处 DevEco 指路改成 `lingqu-cli sign --login` + `sign --auto`（0.39.91） |
| 148 | `sign --auto` 明明全套成功（新证书 + 含本机 UDID 的 profile + `signingConfigs` 写回、HAP 出 signed、真机装上并启动、verify 100%），报告却写「8 步完成 7/8（87%）」、`nextStep` 仍指 `sign`，断点板也当这一步没跑过 | **命令做成了、落档没写**：`t2h:sign` 的 `--auto` 分支从 3237 一路 `return res4`，**没有一处**写 `.lingqu/sign/<工程>.json`（只有"体检"路径写）⇒ 消费方读到的还是几小时前的旧档，"签名跑过了"这件事在证据里根本不存在；现场两个数字并排打架（`hap.signed=true` 与 `sign.mode` 未知）。**判据**：① 凡是有落档 schema 的步骤，**每一条出口都要落档**（成功/失败/体检/自动），别只在"人点的那条路"上写；② 看得到产物（有 signed HAP）**不等于**这一步被记录——真值只认落档（§0.1）。处置：`--auto` 出口补写 `lingqu/sign/v1`（`mode{mode,modeLabel,canInstallDevice}` + `by=auto` + `autoSign`，失败带 `error` 与 `nextStep` 指引），实测报告 `stepPercent` 87 → 100、`nextStep` 消失（0.39.92） |
| 150 | `reqwest` 的 Cargo.toml 明明写了 `features = [… "rustls-tls" …]`，交叉编译到 OHOS 还是死在 `failed to run custom build command for `openssl-sys`` + `Could not find directory of OpenSSL installation`；而**技能里早就写着**"`default-features=false`，禁 default，会拉进 openssl-sys" | **"写在技能里"≠"agent 读得到、更≠它能把日志串对到那一条"**：① 技能是**按需读**的（`SKILL.md` 的 references 索引明写"不要全读"），而现场症状串与"reqwest 默认特性"**没有字面联系**，它凭什么想到去翻 `cargo-patches.md`；② 任务书那节把 `ring`/`openssl` 一起归因到 `[env]` 的 CC 变量——**写歪了比没写更坏**，agent 会顺着"配 CC / 配 pkg-config / 装 OpenSSL"白烧一轮；③ 指纹 FP-016 的 marker 是 `pkg-config has not been configured to support cross-compilation` 却归因 glib-sys/GTK，而 **openssl-sys 的 build script 也打这一句**（两串同时命中，顺序决定 agent 走哪条）。处置：规则 **R2-PORT-016**（`default-features = false` + 补回 `charset`/`http2`/`system-proxy` 这些**纯 Rust 默认项**——只关默认特性等于静默砍特性）+ 指纹 **FP-021 插在 FP-016 之前** + 任务书「TLS 栈」节（含 `cargo tree --target aarch64-unknown-linux-ohos -i openssl-sys` 自查与三条死路禁令）+ 技能补症状串。**三条判据**：① 能确定性解决的**进规则**，别指望"读到就会用"——技能管"人能查"，兜底要进 agent 绕不过去的规则/指纹/任务书；② 报错指纹的 marker 若**多个组件共用**（`pkg-config …`、`failed to run custom build command`），必须靠**紧随其后的 crate 名**分流，且**特殊指纹排在通用指纹之前**；③ 修"默认特性"这类缺省值，**关掉之后必须把无关联的默认项补回来**，否则是顺手改行为（0.39.99） |
| 151 | ⑥ 验证屏的「分节折叠」看着正常，可**没有任何读数能证明**它生效；顺手发现 `verNote` 里那句「业务功能 N 条…不计入」**从来没出现过** | 三件事叠在一起：① `verifyRows` 数的是 `#verList .evi`，**连 `<details>` 折叠体内的行一起数**（`querySelectorAll` 不看可见性）⇒ 折叠与不折叠读数一模一样，等于没断言；② `renderVerify` 重建 `VERIFY` 时漏取 `businessTotal`/`businessTested`，而 biz 分支读的正是 `VERIFY.businessTotal` ⇒ 恒 `undefined > 0` = false，那句话永远不渲染（**后端一直在回投、回读白名单里也有** ⇒ 不是后端没给，是界面没接，§4-57 的界面侧同族）；③ `fillStepFromRecord` 成功分支无条件把 `verNote` 改写成「已按落档回读：路径」，把 `renderVerify` 刚算好的「移植验收通过率 X%（分母 N 项有结论…）」整段顶掉（§4-135 同族）。处置：读数拆成 `verifySections/verifyMainRows/verifyBizRows/verifyBizOpen/verifyBizText/verifyNoteText/verifyListH`（`> .evi` 与 `details .evi` **分开数**）；`renderVerify` 补齐四个计数字段；`verify` 步的回读来源**只追加后缀**不覆盖；新增 `LINGQU_UI_PROBE=verifysections`（进屏→判默认态→展开→收回复查，无落档报 `no-record` 不假绿）。**三条判据**：① 凡是"折叠/收起/虚拟滚动"这类**视觉上减少行数**的优化，都必须有「分节条数 / 各节行数 / 是否展开」的读数——用总行数证明不了任何折叠；② 界面取后端字段前先对一遍**后端实际回投的键名**（本次 `businessTotal` 后端有、界面没接）；③ "回读来源"与"业务口径说明"抢同一个 DOM 位时，来源必须降级成后缀——**信息量大的留着**（0.39.104） |



| 151 | `t2h:build` 在 note-gen-2 上报「鸿蒙产物闸：编译成功但没产出 `libtauri_app_lib.so`」，可那个 `.so` **明明就在盘上**（33,012,312 B，就是这次编出来的）；同时 `assetDiff` 三组全是空数组——指纹闸压根没跑 | **"第一个 `.so`"不等于"应用自己的那个 `.so`"**：cargo `--message-format=json` 报的 artifact 顺序是 `["libpdf_inspector-<hash>.so", "libtauri_app_lib.a", "libtauri_app_lib.so"]`——**deps 里的 hash 中间产物排在前面**。旧 `findSoArtifactOf` 取"第一个 `.so`"就拼成 `release/libpdf_inspector-<hash>.so`（它在 `deps/` 下，不在 `release/` 下），`exists()` 为假 ⇒ 返回空串 ⇒ 产物闸假红、前端指纹闸被一起跳过。于是"没找到 .so"与".so 就在盘上"同时成立，agent 会去怀疑 cdylib 声明/编译参数。处置：候选顺序收成**纯函数** `soCandidateRelsOf`（**期望名优先**，即 `expectedLibNameOf` 算出的 `lib<name>.so`——HAP 真正加载的就是它；再逐个试 `release/` 与 `deps/`），并把 `expectedSo` 的算点**提到找 .so 之前**；cargo 一条 artifact 都没报（增量全 Fresh）时按磁盘兜底——**"这条命令没输出"不等于"没有产物"**。实测修后 `gates.passed=true`、`soPath` 有值、`assetDiff.matched=12`（此前 12 个前端键一个都没比）。**三条判据**：① 凡是"从一堆产物里挑一个"，都要能说出**为什么是它**——按名字点名的优先于"列表里第一个"（§4-46 同族：别用"至少有一个 .so"这种弱判据）；② 判"没产出"之前先分清**产物不存在**与**我们找错了位置**，后者会把已经成功的步骤整片判假红；③ 闸的输入（期望产物名）算得比闸**晚**，是漏判的常见来源——先算期望，再定位，再判（0.39.100） |
| 152 | 门禁第 ② 闸 `[FAIL] cjpm test exit=1（FAILED=0 ERROR=0）`，输出里只有一句 `Created process failed, errMessage: "Access is denied."`，看不出哪条用例挂了 | **那是安全软件拦了"进程创建"，不是用例失败**（360 安全卫士实测）。判据：`FAILED=0 / ERROR=0` 与 exit=1 同时出现 ⇒ 先怀疑**起不来**而不是**跑挂了**；绕过门禁脚本直接跑 `target/release/unittest_bin/lingqu.tests.exe`，若它自己回 `TOTAL/PASSED/FAILED` 全绿就证明确是用例全过。处置：放行/白名单该测试可执行文件后重跑门禁即绿（本次实测放行后 `TOTAL=500，FAILED=0，ERROR=0`）。**别在这种红面前去改用例**——§4-15 是同一族（门禁必须打印日志尾部），这次补一条：| 153 | `t2h:hap` 报 `> hvigor ERROR: Error Code: 00308018 Unknown Error`，闸提示「hvigor 的 tauri 钩子失败」，可 0.39.53 早就加了规则 **R2-PORT-015** 来注掉那行钩子；`gen/ohos/entry/hvigorfile.ts` 里 `node.getTaskByName('default@ConfigureCmake')!.afterRun(buildRustCode);` **原样还在，也没有 `.bak`** | **生成器会把它覆盖掉的改造又写回来，而改造是在"文件不存在"时跑的**：note-gen-2 的 `gen/ohos` 是 2026-11-09 才 `cargo tauri ohos init --ci` 生成的，而上一轮 `port --apply` 跑在**脚手架还不存在**的时候 ⇒ R2-PORT-015 无文件可改 ⇒ 新生成的 `hvigorfile.ts` 带着钩子进 hvigor ⇒ 00308018（`cargo tauri ohos dev-eco-studio-script` 要读 dev server 的 addr 文件，非 dev 场景必 panic）。**判据**：看那一行 `afterRun(buildRustCode)` 是否还在、同目录有没有 `.bak` 与 `lingqu: R2-PORT-015` 标记——不是"规则存在"就等于"已经注过"。处置：脚手架就位后**重跑 `port --path . --apply`**（幂等，带标记即跳过），再 `hap`。实测同一份工程：重跑前 `built=false / errors=3 / 空 HAP`，重跑后 `built=true / errorCount=0 / 34,457,633 B / libs 里 libentry.so + libtauri_app_lib.so 齐 / gates.passed=true`。**两条判据**：① 凡是"我们改过的文件由某个生成器产出"（`tauri ohos init`、`cj-tauri sync`、脚手架重建），**生成之后必须重跑改造**——顺序写进任务书，别指望人记得（§4-11 的骨架漂移是同一族）；② "规则已实现" ≠ "改造已落地"，验收要看**盘上那份文件的真实内容**（有没有标记、有没有备份），而不是规则表里写着 applied（0.39.100） |
| 154 | `probe --auto --max 8` 真机第一次跑只拿到 **1 条 pass**，另外 7 条全是「点前版面树里找不到「X」」；改 `--max 4` 那轮更怪：4 条全 **fail** | **候选清单只枚举了一次，而现场是"点一下变一层"**：`runProbeAuto` 从首份版面 dump 挑出 8 条文本就照着点，点「文本」弹出记录框后，其余「插图/链接/文件/待办」已不在这一屏 ⇒ 每条虽然都重新 dump 了（注释也写着要），但**候选没跟着重算**，第一条之后全废。处置：`firstUntriedOf(cands, tried)` 纯函数 + **每轮按当前版面重新枚举**，`tried` 账去重，点完再 dump 下一次（落档新增 `tried`）。**判据**：凡是"按一份快照逐条操作、而每次操作都会改现场"，快照就必须**每次重取**——"每步都重新读一遍"这句话，要检查读的是**输入**还是只是**状态**（0.39.102） |
| 156 | 真机探针把「保存到」判 **pass**，理由写着"点后版面多出 3 条文本：09、:、48"；「添加」判 pass 是因为多出「, ? !」 | **判"点了有反应"靠的是"版面多了什么"，而页面上自己会变的东西里全是纯数字与半角标点**：时钟（`09` / `:` / `48`）、字数（`0`）、编辑器里的逗号问号感叹号。只滤时钟不够——一台机器上"时钟被拆成三个节点"就绕过去了。处置：`hasWordContent()`（**含 ASCII 字母或任一非 ASCII 字节**才算有内容；只按字节比，不逐字节拼字符串，避开 §4-116），`newTextsOf` 与候选准入都用它。**判据**：① 凡是"靠差异判定发生了某事"，先问**这份差异里有多少是会自己变的噪声**，把"实质内容"下成纯函数并单测；② **假 pass 比漏测更坏**——它让可用率凭噪声上涨，而且长得跟真结论一模一样（0.39.102） |
| 157 | 自动探针点完 7 条全判 **fail**（"点后版面没有新内容"），可用率跟着往下掉；可人眼看那几条按钮是能点的 | **"点了没反应" ≠ "功能不可用"**：工具分不清"**没点中**"（ArkWeb 里文本节点 bounds 与实际可点区域常常不一致）与"功能确实无响应"，判 fail 就是拿**观测缺陷**冒充功能缺陷——与 §4-156 的假 pass 对称的谎报。处置：改判 `unknown`，note 明写「可能是没点中，不据此判不可用」。**判据**：凡是"以否证形式下结论"（fail / not-supported / 不支持），要先能说出**这条否证是怎么排除"我们没测到"的**；排除不掉就记未测（§4-63 的第三态：*跑了，但没测出结论*）（0.39.102） |
| 158 | A4「核心功能可用率」算出 **4/16 = 25%**，而分母（192 项）里 **180 项是 note-gen-2 自己的 IPC 业务命令**（`ai_json_request` / `start_download`…）；用户当场点破：「每个软件都这么验要验到什么时候？没配网没配参数，有些功能必然过不了——移植可不是给作者测业务功能」 | **分母里混进了不归我们负责的项**：把"原应用的业务功能"当成"移植该证明的事"。两个后果同时成立——① 分母永远做不完（每应用上百条命令），"≥80%"就成了悬着的数；② 缺网/缺密钥/没登录时这些功能本来就跑不起来，失败与移植质量无关，却被算成移植不达标（§4-63 第三态的升级版：*分母装错了东西*）。处置：`CheckItem` 加 `category`（**transplant / business / smoke**），**分母只认 transplant**（装得上/起得来/渲染得出/前端资源进包/IPC 与事件通道/平台能力有落地等价物）；业务功能只统计条数、单列冒烟、**不判 fail**；统计与报告/矩阵/界面/任务书口径全部同步（D-020）。**三条判据**：① 验收指标先问「**这项是谁的职责**」——把别人的账算进自己分母，指标就永远不会达标，而且达标了也说明不了自己做好了；② 凡是"要逐条穷举"的分母，先问它**有没有上界**——没有上界的分母等同于没有指标；③ 降低分母**不等于放宽判据**：transplant 项的判据一条都没松（平台限制仍要"降级落地"才算 limit），改的只是"该数谁"（0.39.103） |
| 159 | ⑥ 屏主行显示 **9** 条，而落档里移植验收项只有 **7** 条；同一屏折叠摘要写「实测 **0** 条」，note 却写「冒烟 **2** 条」 | **按类别分流时只写了类别全集里的一半**：`renderVerify` 里是 `category === 'business' ? 折叠节 : 主行`，而真机冒烟项是 `category='smoke'`（`feat:probe:*`，`verify.cj` 明写"单列、不计入通过率"）⇒ 它既不是 business 也不该进主行，顺着 `else` 掉进主行，7 条移植项变 9 条；摘要又只统计 `business`，于是「实测 0 条」与 note（用后端 `businessTested`）的「冒烟 2 条」同屏打架（§4-139 同族：同一屏两处说法不同源）。处置：`business` 与 `smoke` 一并归折叠节，摘要拆成「业务功能 N 条 + 真机冒烟 M 条（冒烟实测 X 条：通 Y / 未过 Z）」。**判据**：① 凡是"按类别分两类"的渲染，**先把类别全集写出来**再写条件（这里是 transplant / business / smoke 三类），`if 某一类 else 其余` 等于默认把新类别都归到 else；② 加了一个新类别就回头查所有按类别分流的地方（§4-158 定的是"该数谁"，这条是"该显示在哪"）（0.39.105） |
| 160 | 探针注释写着「展开 details → `verifyBizOpen` 必须变 1（证明真能展开）」，可那一步**只回投不断言**，展开失效时照样 `verifyProbe=1` | **注释承诺的判据没有落到代码里**：`verifysections` 序列 6800ms 那步只有 `d.open = true; reportUi(...)`，结果没并进 `__verifyProbe`；收回阶段还写着 `d ? (d.open === false) : true`——**拿不到 details 时回落"收回成功"**。两处都是"长得跟通过一模一样"的假绿（§4-136 同族）。处置：展开后复查 `details.open === true`（失败记 `open-not-applied` / `no-biz-section`），收回阶段 `d == null` 判 `restore-failed`。**判据**：① 探针每一步都问「**这一步的结果进了判定吗**」——只 `reportUi` 不并入结论的动作等于没测；② 判"成功"的表达式里出现 `? : true` 这种**默认真值**，一律改成默认失败（"拿不到现场"不是"没问题"）（0.39.105） |
| 162 | 鸿蒙侧"点了不弹框"，可 `verify` 判 pass、桌面与交叉编译都 exit=0；另一头是**接上 Picker 后下载到一半 EACCES** | 两件事同属「原生 UI 能力」这一族（`rfd::FileDialog` / `explorer` / 分享 / 相册），根因各不相同：① **`.ets` 没有人编译**——`cargo build` 与 `cargo build --target …ohos` **都不查 ArkTS**，只有 `lingqu-cli hap`（hvigor）会查，于是"Rust 全绿、ArkTS 少个 import"能一路绿灯到真机；② **Picker 返回的是 uri 不是路径**——授权**只在 uri 通道生效，不覆盖 `std::fs` 裸路径读写**，拿路径去建目录/写分片必然在下到一半 EACCES；③ **线程**：Tauri 命令在 IPC 线程跑，`get_main_thread_env()` 是 thread_local、只有主线程有值，不 `run_on_main_thread` 投递就拿不到 env；④ **要返回值就不能 fire-and-forget**。处置：`src-tauri/src/ohos_bridge.rs`（`call_arkts` / `dispatch_on_main`）+ ArkTS `(globalThis as ESObject).__ohos_dispatch` + `DocumentViewPicker`，返回值走「ArkTS 先写 `.tmp` 再 `rename` → Rust 100ms 轮询」（rename 保证读不到半截 JSON）；选文件 `copyFileSync` 进沙箱再回传，选目录**由 Rust 探一次可写**、不可写回落 `files/downloads` 并把真实落点交回界面。**三条判据**：① 凡是"接系统 UI"，验收必须跑到**第三步**（`hap` 过 hvigor），前两步全绿只证明 Rust 侧；② **uri 授权 ≠ 文件路径权限**，跨这一层的地方都要探可写；③ **落地要双侧**（Rust 分支调了桥 **且** ArkTS 分发器里有同名 `cmd` 分支）——只写半边，`commandImplLanded` 会判通过而真机点了没反应（0.39.108） |
| 163 | 桥代码写 `use openharmony_ability::…`，交叉编译报 `error[E0432]: unresolved import` | **`[patch]` 只改来源，不把 crate 加进依赖图**：多数 Tauri OHOS 工程对 `openharmony-ability` 只有 `[patch.crates-io]` 段（它是 tauri fork 的内部依赖），照抄桥骨架就会撞 E0432。处置：改走 tauri 的转出 `use tauri::ohos::openharmony_ability::get_main_thread_env;`——同一 crate、同一 rev，**不动 `Cargo.toml` / `Cargo.lock`**（新增 git 依赖会带来锁漂移与"换机器拉不到"的风险）。已记为指纹 **FP-022** 并**排在通用 `unresolved import`（FP-005）之前**（0.39.108） |
| 165 | 重签后装机回 `9568322 not trusted app source`，可 `sign` 落档 `ok=true`、`canInstallDevice=true`、profile 的 `device-ids` 里**明明有本机 UDID**、HAP `signed=true`；`bm uninstall` 清掉旧版本后照样拒 | **签 HAP 用的证书 ≠ profile 里绑的证书**，而这条**没有任何环节会报错**：`sign --auto` 第 ⑤ 步判据是 `if (freshCert \|\| !exists(cerPath))`——复用云端**同名**证书时，只要本地 `.cer` 还在就**永不重下**。实测本地是 11-01 的证书（serial `63E51AD2…`）、这轮 profile 绑的是云端 11-09 那张（`63E51D71…`）⇒ hvigor 用旧的签、设备按新的验。**证书以云端为准，本地 `.cer` 只是缓存**（§4-122 同族：文件在 ≠ 内容对）。处置：⑥ 之后做一致性自检（从 p7b 取 `bundle-info.development-certificate` 正文，与 `.cer` 链比对，不一致按 `certObjectId` 重下并复核）。**第二层紧接着暴露**：重下后 hvigor 报 `11111002 Certificates error`——云端那张证书**不是本地 `.p12` 这把钥匙签的**，重下多少次都没用，只能 `sign --auto --newKeys`（已入 FP-023 + `hapSignHint`）。三条判据：① 凡是"复用远端同名资源"，都要问**本地缓存与远端那一份是不是同一个东西**（名字相同 ≠ 内容相同）；② 一条链上"每一步都报成功、只有最后一步炸"，优先怀疑**中间有一份缓存没刷新**；③ 材料类问题要分清 **文件缺 / 内容旧 / 钥匙不配**——三者处置完全不同（补文件 / 重下 / 换密钥对），别拿"重下"去治"钥匙不配"（0.39.110） |
| 167 | 新写了个私有辅助函数 `readTextOrEmpty`，`cjpm build` 报 **16 个错**，可见的 8 条全是 `ambiguous match` / `ambiguous API`，且每条**报错位置都在调用方**（`main.cj` / `flywheel.cj` 的业务代码上） | **同包（`package lingqu`）里已经有同名函数**（`src/agent_context.cj:208` 的 `public func readTextOrEmpty`）：仓颉不按"文件内私有优先"解析，两个候选都匹配 ⇒ 报 ambiguous。处置：① 写新辅助函数前先 `grep -rn 'func <名字>' src/` 确认没重名；② 已有同名就**复用它**（单点实现，§4-33 同族），要改行为就改那一处——本轮顺带把复用的那个从 `String.fromUtf8` 换成 `lenientUtf8`（用户手写的落档有一个非法字节就抛 → 整份文件读成空串 = 静默丢全部内容）。**判据**：`ambiguous` 类报错先查"这名字是不是已在别处定义过"，别顺着报错位置去改调用方（§4-67 同族：报错位置 ≠ 真凶位置）（0.39.113） |
，回头核对时发现**已经在漂移**：`FP-020` 的正文写着 hvigor 报 `00308018`，而六个 `references/*.md` 里一个都没有；任务书点名的 `9568320` 同样查不到 | **手写维护的"同一份知识"放在两处，只靠注释里一句「改动两边同步」必然漂移**——补指纹和补技能常常不是同一人、同一轮做的事，而漂移的后果很具体：`t2h:diagnose` 命中后 agent 拿着归因去技能里找处置，**找不到**（§4-130 同款：能力在、说明书没给）。处置：把同源做成**判据**而不是纪律——`isUniqueErrorCodeOf` / `uniqueErrorCodesOf` / `codesMissingInDocsOf` / `fingerprintDocGapsOf` 四个纯函数，外加一条**读真实 `references/*.md` 的单测**（文档读不到直接红，不许静默通过）。三条判据：① 凡是"同一份知识写在两处"，就要有一条**能红**的断言，否则迟早漂移；② 断言的**粒度只到"唯一可识别"那一档**——非数字 marker（`unresolved import`、`openharmony_ability`）本身不唯一，硬要求"文档里必须有"等于把泛串也钉进判据；③ 自检序列"跑一遍总是绿"不算数，要能说出**怎么让它红**（本轮：删掉文档里那个码，断言立刻列缺口）（0.39.111） |

| 168 | "16 条改造规则"这个数字在四份文档里各写一个（README 16 / 飞轮 16 / 需求追踪 15），而**代码里没有任何地方能回答"一共几条"** | 17 条规则原先只以 `RuleOutcome("R2-PORT-0xx")` 字面量散在 6 个文件里 ⇒ 清单**只存在于人的记忆里**，改完 README 又跟另两份打架。§4-166 说"同一份知识写两处就该能红"，这条是它的**前置条件**：连单点都没有，判据无处可写。处置：`src/port/rules.cj` 立唯一清单 `portRules()`（编号 + 标题 + 是否只报不写），配三件判据工具（`ruleIdFromConstructLine` 认「字面量 / `HVIGOR_HOOK_RULE_ID`」两种真实形态，**认不出返回空串让调用方判红**；`ruleDriftTextOf` 清单 ↔ 源码**双向**差集；`ruleNumberingTextOf` 连号无重复），范围串 `R2-PORT-001…017` **由清单首尾算出**（不手写，§4-63）；`src/tests/port_rules_test.cj` 读**真实源码与文档**对齐（漏登记 / 漏实现 / 改成动态编号 / 文档写错条数，四种都红）。**三条判据**：① 凡是"文档里会反复出现的计数"，先在代码里立**单点**再谈断言——没有单点的同步只能靠人；② 扫描类判据必须有"认不出就红"的出口，否则以后有人写 `RuleOutcome(someVar, …)` 会被静默放过（§4-160：判据不许有默认真值）；③ 判"裸前缀"要验形态——`R2-PORT-*` 这种写法真实存在，按前缀切三位会切出 `` *` `` 之类的垃圾串、把判据变成自己制造的假红（§4-156 同族）。**边界**：只保证"有几条、编号连续、四处对得上"，不保证规则行为对（0.39.115） |
| 169 | 给指纹做「编号连续性」判据，第一次跑就红：真库 21 条一条不缺，判据却说「第 5 条应为 FP-005，实际 FP-022」 | **数组顺序是"匹配顺序"，不是编号顺序**：`fingerprintLibrary()` 里 `FP-022` 刻意夹在 `FP-004` 与 `FP-005` 之间、`FP-021` 刻意排在 `FP-016` 之前（具体指纹必须先于泛串，§4-150 判据②）。连续性判据若按"第 k 项 == 编号 k"逐位比，就把一个**刻意的设计**判成漂移。处置：连续性只断**集合**（编号须恰好是 `FP-001..FP-023` 跳过 `FP-008/009` 保留空位的那一组，无重复 / 缺号 / 越界），顺序另用先后断言钉住（`fpIndexOfOf(ids,"FP-021") < …("FP-016")`）。**判据**：凡"校验一串编号"，先问**这串的排列有没有语义**——有语义（匹配顺序 / 优先级 / 挂载顺序）就不能拿"顺位 == 编号"当判据，那是自造假红（§4-156 同族）（0.39.116） |
| 170 | 门禁 ② 报 `ld.lld: error: undefined symbol __declspec(dllimport) CertOpenSystemStoreA`（referenced by `libstdx.crypto.x509.a(rootca.c.o)`），同时 `FAILED=0 / ERROR=0` 却 exit=1；同一份代码上一轮是绿的 | **机器级 `CANGJIE_STDX` 指向了 static 树**（`…/static/stdx`），而门禁脚本自己的默认是 `dynamic/stdx`。static stdx 的 `rootca.c.o` 会被**真正链进来**，它需要 `-lcrypt32`（仓颉默认链接行只带 advapi32/shell32/user32/kernel32，与 §4-54 同源）；动态树只挂导入库，所以从来不需要。处置：按脚本默认口径重跑即绿（`CANGJIE_STDX=<…/dynamic/stdx> ./scripts/test.sh`）；要长期支持 static 树，就得给 `cjpm.toml` 的 mingw `link-option` 补 `-lcrypt32`（及 §4-49 列的其余静态期 libs）。**判据**：① `FAILED=0/ERROR=0` + exit=1 一律先怀疑**起不来 / 链不上**，别去改用例（§4-152 同族）；② 看到静态期符号（`CertXxx` / `__imp_`）先查 `CANGJIE_STDX` 指哪棵树，再怀疑代码（0.39.116） |
| 171 | 交叉编译报 `ToolNotFound: failed to find tool "…sdk/**HarmonyOS-NEXT-DB6**/…clang.exe" (os error 3)`，而同一份日志里工具自己设的是 `sdk/default/openharmony/native/…`（那条路径是**对的**） | **样本自带的 `.cargo/config.toml` 把过期 SDK 写死了**：`cc-switch-harmonyos/src-tauri/.cargo/config.toml` 的 `linker` / `ar` / `sysroot` 三处全指向 `sdk/HarmonyOS-NEXT-DB6/…`（该目录**不存在**）。这是 §4-38「过期值盖掉推导值」的**样本内**版本——工程自己的 cargo 配置优先级高于环境推导。排查口诀：`grep -rn "HarmonyOS-NEXT-DB6" <样本>/.cargo/config.toml`；处置方向是"采样配置里的路径**必须存在才采用**，否则按推导值覆盖并告警"（0.39.117 R-2 抓到的环境级缺陷，**未修**） |
| 172 | 未迁移工程跑交叉编译，`ring` 的 build script 直接失败：`fatal error: 'assert.h' file not found`，命令是宿主 `cc` + `--target=aarch64-unknown-linux-ohos` | **C 依赖缺 target CC**：`R2-PORT-008` 写的 `.cargo/config.toml`（`[env] CC_aarch64-…` / `CFLAGS` / `AR`）只对**已迁移**工程生效；未迁移工程裸跑时 cc-rs 只能拿宿主 `cc`，于是找不到目标 sysroot 的头文件。判据：日志里同时出现 `CC_aarch64-unknown-linux-ohos = None` 与 `'assert.h' file not found` 就是这一类，属**工具链**、不进 R-2 的 crate 分母（§2.1）。处置方向：build 前若依赖树含 C 依赖（`-sys` / `ring` / `aws-lc-sys`）而工程没配 target CC，就**前置提示或按 NDK 注入**（0.39.117，**未修**） |

 | **单点修复不复利 = 白修**：只把 m3u8dl 的选择框接上桥，下一个工程还会重走一遍"不知道要桥 → 不知道线程铁律 → 不知道 uri 语义 → 漏跑 hvigor"。沉淀必须**按层级落位**，每层解决不同的失效方式：**规则层**（`R2-PORT-0xx`，可枚举的机械改造，别烧 agent 轮次）→ **指纹层**（`diagnose.cj` 的 `FP-0xx`，**只收能被报错原文唯一认出的**，泛串会污染匹配顺序、必须具体优先）→ **技能层**（`references/*.md`，需要判断的形态选择）→ **任务书层**（`buildAutoPortDirective`，agent **每轮必读**；§4-130：能力已有、说明书没给 = 它只能瞎摸）→ **飞轮层**（`t2h:notes` + `AI自进化飞轮.md`，留痕并记录"入库：FP-022"）。**判据**：① 不是每个经验都进指纹表——认不出唯一 marker 的（如 `Permission denied`）只能进技能与 AGENTS；② 只进技能等于没沉淀（§4-150：写在技能里 ≠ agent 读得到），凡是"agent 不主动查就必错"的知识，任务书必须有独立一节；③ 沉淀完的验收是**换一个工程重跑 autoport**，看它是否照着做，而不是"文档里写了"（0.39.108） |




**一边做一边沉淀**：每轮改动完成时，同批更新

1. `CHANGELOG.md` —— 该版本做了什么（Keep a Changelog 风格，按 Added / Changed / Fixed 分组）
2. `docs/进度记录.md` —— 本轮做了什么、验证到什么程度、下一步
3. `docs/需求追踪.md` —— 涉及验收项时更新状态
4. `docs/会话交接.md` —— 会话结束/换机器时更新（元信息、未完成、怎么接）
5. 踩了新坑 → 同时进 §4 与 `docs/开发环境.md`
6. **对外门面**（`README.md` / `CONTRIBUTING.md` / `SECURITY.md`）——**能力、命令数、单测数、门禁数、验证样本数一变就要改**；
   README 里的数字不许留旧版（界面与 README 都不许出现"看起来像数据的假值"，同 §4-94 的口径）
7. **经验/指纹/技能这条链路的改动** → 同步 `docs/AI自进化飞轮.md`（结构、候选门槛、闸门位置一旦变就要写清）
8. **任务书层改动**（`src/autoport.cj` 的 `directiveClauses` / 小节文案 / 触发条件 / 预算常量）
   → 同步 [`docs/任务书规范.md`](docs/任务书规范.md) §3 清单与 §9 变更流程。
   **两端由单测钉住**（`src/tests/directive_spec_test.cj` 会读真实文档断言"每个小节都列到了"）——
   但"清单齐了"只保证小节在，**不保证 agent 照做**，行为验收要换工程重跑一轮（规范 §8）。

**提交信息**：`<type>(<scope>): <一句话>`，正文写「现象 → 根因 → 处置」，行为变更附证据。
type 用 `feat` / `fix` / `docs` / `refactor` / `test` / `chore`。

---

## 6. 版本与发版

- 版本号三处一致：`cjpm.toml` 的 `version`、`cj-tauri.toml` 的 `version`、`CHANGELOG.md` 的最新条目。
- 重大更新递增中间位（0.2.0 → 0.3.0），小修递增最后位（0.2.0 → 0.2.1）。
- 发版前：`./scripts/test.sh`（或 `scripts\test.bat`）全绿 → 更新 CHANGELOG（写清日期与验证范围）→ 打 tag。

---

## 7. 交付检查清单

- [ ] **方向自检（§0.1 / D-015）**：这轮改动让 **cjh 更能干活**了吗？还是又变成"人点按钮 / 我们替它做决定"？
      按反例清单逐条对一遍——方向错了，门禁全绿也是白干
- [ ] `./scripts/test.sh` 或 `scripts\test.bat` 全绿（五道闸）
- [ ] 界面改动有 `t2h:ui_report` 的版面证据（或 `LINGQU_UI_PROBE=1` 序列）
- [ ] 新增纯函数有测试；bug 修复有复现用例
- [ ] 新增命令三处联动齐全（register × capabilities × UI）
- [ ] 行为变更有可观测证据（日志/返回值/窗口/进程状态）
- [ ] `CHANGELOG.md` + `docs/进度记录.md` 已更新
- [ ] 未验证的部分已在文档里如实标注
- [ ] `git status` 干净，提交信息符合 §5

---

## 8. 参考资源（卡住先来这里找，别猜）

**完整清单见 `docs/仓颉资源地址.md`；只列最常用的三条：**

| 资源 | 地址 / 位置 | 什么时候用 |
|---|---|---|
| **CangjieSkills**（仓颉官方知识库） | **https://atomgit.com/Cangjie-SIG/CangjieSkills** | **写仓颉卡在标准库 API 写法时，第一动作就是查它** |
| 仓颉官网 / API 文档 | https://cangjie-lang.cn/ · https://cangjie-lang.cn/api.html | 语法与标准库权威定义 |
| 仓颉中心仓（三方库） | https://pkg.cangjie-lang.cn/index | 找 `stdx` 能力或第三方依赖 |

CangjieSkills 查法（`--domain` 取 `language` / `std` / `stdx` / `tools` / `examples`）：

```bash
# 只写地址、不写本机路径——换机器/换环境时 clone 到哪都行
git clone https://atomgit.com/Cangjie-SIG/CangjieSkills.git
cd CangjieSkills
python scripts/search_docs.py --query "HashMap add" --domain std --max-results 1
python scripts/search_docs.py --query "string 切片" --domain language --view leaves
```

> 靠它避开过 `quote` 是关键字 / `HashMap` 用 `add` / 只有零参 `trimAscii()`（§4 第 20–22 条）——都是"按别的语言猜"猜出来的错。

上游框架仓（**只记远程地址，不记本机路径**——换环境时 clone 到任意目录并 `export CJ_TAURI_ROOT=<它>`
即可，`cjpm.toml` 里写的就是 `${CJ_TAURI_ROOT}`（0.13.1 起）；改这些仓之前先看它们自己的 AGENTS.md）：

| 仓 | 远程地址 | 说明 |
|---|---|---|
| cj-tauri | **https://atomgit.com/qq8864/cj-tauri** | 外壳/UI 框架；`examples/ai-chat` 是 cjh 托管的参照实现 |
| cjh | **https://atomgit.com/qq8864/cjh** | 内嵌 AI 引擎；WS 协议见 `src/web/protocol.cj`；集成指南见本仓 `docs/集成cjh.md` |

**上游回馈纪律**：用 cj-tauri / cjh 时发现**能力不满足、行为异常或有新坑**，别只在本地绕过——
到对应仓**提 issue**（现象 → 根因 → 复现/证据 → 建议），有通用修法的提 PR（见 `cj-tauri-contribute` skill）。
这也是课题"工具开源"验收的生态贡献证据。

**移植阻塞的 fork 先行策略**：tauri / openharmony-ability 的能力不满足（缺 API、行为缺陷、
真机专属问题）时**不要等上游**——在 https://github.com/yangyongzhen/tauri 或
https://github.com/yangyongzhen/openharmony-ability 下建分支先解决（`fix/<工程>-<问题>`，
commit 注明动机），用 patch rev 钉住继续推进，之后再整理成 PR 回上游。等上游 = 流水线停摆。
（实证：cc-switch 的 feat/open-harmony 分支、habit-tree 的 ability feat/0.3.0 patch）

鸿蒙侧工具与技能生态（P4/P5 构建·部署链与 skill 沉淀的直接相关方；gitcode 页面有反爬，
**访问不到时按 atomgit 同路径域名试**）：

| 仓 | 远程地址 | 说明 |
|---|---|---|
| **deveco-cli** | **https://atomgit.com/openharmony-sig/deveco-cli**（= gitcode.com/openharmony-sig/deveco-cli） | 集成 HarmonyOS 应用开发工具集（知识文档 + 精品 Skills，多智能体）。命令 `devecocli`：`devecocli build` 打 HAP、`devecocli run --device <serial>` 构建+安装+启动——habit-tree 真机部署链（P5）实际用它替代裸 hvigorw/hdc 序列 |
| **harmonyos-agent-skills** | **https://atomgit.com/HarmonyOS_Skills/harmonyos-agent-skills**（= gitcode 同名仓，MIT） | 官方 HarmonyOS 应用开发 skills 集合——与本项目 `skills/t2h-ohos-port`（Tauri→鸿蒙移植 skill）同生态；新 skill 沉淀时参考其组织形态，成熟后可回馈 |

换环境后：clone 上面两个仓，再 `CJ_TAURI_ROOT=<cj-tauri 目录> ./scripts/setup.sh`（只体检、不改文件）。

