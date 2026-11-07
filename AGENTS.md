# 灵渠迁移台 · 项目开发规范（AGENTS.md）

> 本文件是本项目的**开发契约**：人类开发者与 AI 助手共同遵守，由 agent 自动加载注入。
> **改代码前先读 §1 门禁与 §2 架构契约。**
> 适用版本：**0.39.55**（2026-11-02），与 `CHANGELOG.md` 同步维护。
> 当前进度见 `docs/进度记录.md`；**阶段任务与技术验收判据见 `docs/实施路线图.md`**；
> 换机器/换会话先读 `docs/会话交接.md`；需求落地状态见 `docs/需求追踪.md`；决策与理由见 `docs/设计决策记录.md`。

---

## 0. 项目定位

**Tauri 应用 → 鸿蒙 PC 的一站式 AI 迁移台**。三层技术栈：

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

---

## 5. 文档与提交

**一边做一边沉淀**：每轮改动完成时，同批更新

1. `CHANGELOG.md` —— 该版本做了什么（Keep a Changelog 风格，按 Added / Changed / Fixed 分组）
2. `docs/进度记录.md` —— 本轮做了什么、验证到什么程度、下一步
3. `docs/需求追踪.md` —— 涉及验收项时更新状态
4. `docs/会话交接.md` —— 会话结束/换机器时更新（元信息、未完成、怎么接）
5. 踩了新坑 → 同时进 §4 与 `docs/开发环境.md`
6. **对外门面**（`README.md` / `CONTRIBUTING.md` / `SECURITY.md`）——**能力、命令数、单测数、门禁数、验证样本数一变就要改**；
   README 里的数字不许留旧版（界面与 README 都不许出现"看起来像数据的假值"，同 §4-94 的口径）
7. **经验/指纹/技能这条链路的改动** → 同步 `docs/AI自进化飞轮.md`（结构、候选门槛、闸门位置一旦变就要写清）

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

