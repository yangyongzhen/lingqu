# 灵渠迁移台 · 项目开发规范（AGENTS.md）

> 本文件是本项目的**开发契约**：人类开发者与 AI 助手共同遵守，由 agent 自动加载注入。
> **改代码前先读 §1 门禁与 §2 架构契约。**
> 适用版本：**0.19.0**（2026-11-01），与 `CHANGELOG.md` 同步维护。
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

---

## 1. 交付门禁（唯一交付凭证）

**任何代码变更交付前必须满足：**

1. `./scripts/test.sh`（Linux/macOS/Git-Bash）或 `scripts\test.bat`（Windows）**全绿**。四道闸缺一不可：
   - ① 业务包 `cjpm build` —— **零警告**（unused 变量/导入、deprecated 一律清零，禁止"先交付后清理"）
   - ② 业务包 `cjpm test` —— `FAILED: 0`、`ERROR: 0`
   - ③ `cj-tauri check` —— 清单校验 + 骨架漂移 + **能力三方比对**（声明 × 插件自述 × 实际装配）
   - ④ `targets/desktop` 的 `cjpm build` —— 骨架侧也要编得过且零警告
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
| 拉起方式 | 必须 `launchHidden()`（本应用是 GUI 子系统，`std.process.launch` 会给子进程配黑窗口） |
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
- **临时调试脚本别留在仓里**：`scripts/.dbg*.ps1` 这类东西会被 `git add -A` 带进去。
- **提交信息里别用 `\"` 转义**：PowerShell 双引号串会把命令拆坏。多行/含引号的提交信息写进文件再 `git commit -F`。
- 仓颉细节坑（从 cjh / cj-tauri 继承，供参考）：`Directory.walk` **非递归**；
  `StringBuilder.append(Byte)` 按十进制整数输出；块注释内禁写 `/*` 序列；零参 lambda 写 `{ => }`。

---

## 4. 已踩坑清单（禁止重踩）

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
| 11 | `cj-tauri check` 报「骨架漂移」 | 改了 `cj-tauri.toml` 或 `assets/` 却没重跑 sync → `cj-tauri sync desktop` / `sync ohos` |
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

---

## 5. 文档与提交

**一边做一边沉淀**：每轮改动完成时，同批更新

1. `CHANGELOG.md` —— 该版本做了什么（Keep a Changelog 风格，按 Added / Changed / Fixed 分组）
2. `docs/进度记录.md` —— 本轮做了什么、验证到什么程度、下一步
3. `docs/需求追踪.md` —— 涉及验收项时更新状态
4. `docs/会话交接.md` —— 会话结束/换机器时更新（元信息、未完成、怎么接）
5. 踩了新坑 → 同时进 §4 与 `docs/开发环境.md`

**提交信息**：`<type>(<scope>): <一句话>`，正文写「现象 → 根因 → 处置」，行为变更附证据。
type 用 `feat` / `fix` / `docs` / `refactor` / `test` / `chore`。

---

## 6. 版本与发版

- 版本号三处一致：`cjpm.toml` 的 `version`、`cj-tauri.toml` 的 `version`、`CHANGELOG.md` 的最新条目。
- 重大更新递增中间位（0.2.0 → 0.3.0），小修递增最后位（0.2.0 → 0.2.1）。
- 发版前：`./scripts/test.sh`（或 `scripts\test.bat`）全绿 → 更新 CHANGELOG（写清日期与验证范围）→ 打 tag。

---

## 7. 交付检查清单

- [ ] `./scripts/test.sh` 或 `scripts\test.bat` 全绿（四道闸）
- [ ] 界面改动有 `t2h:ui_report` 的版面证据（或 `LINGQU_UI_PROBE=1` 序列）
- [ ] 新增纯函数有测试；bug 修复有复现用例
- [ ] 新增命令三处联动齐全（register × capabilities × UI）
- [ ] 行为变更有可观测证据（日志/返回值/窗口/进程状态）
- [ ] `CHANGELOG.md` + `docs/进度记录.md` 已更新
- [ ] 未验证的部分已在文档里如实标注
- [ ] `git status` 干净，提交信息符合 §5

---

## 8. 参考资源（卡住先来这里找，别猜）

**完整清单见 `docs/仓颉资源地址.md`。下面只列「写代码时会用到」的三条，防止后续遗忘：**

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

> 本项目已靠它避开三个坑：`quote` 是关键字、`HashMap` 用 `add` 不是 `put`、只有零参 `trimAscii()`
> （§4 第 20–22 条）。**这三条都是「按别的语言的习惯写」写出来的错，查一下就不会犯。**

上游框架仓（**只记远程地址，不记本机路径**——换环境时 clone 到任意目录并 `export CJ_TAURI_ROOT=<它>`
即可，`cjpm.toml` 里写的就是 `${CJ_TAURI_ROOT}`（0.13.1 起）；改这些仓之前先看它们自己的 AGENTS.md）：

| 仓 | 远程地址 | 说明 |
|---|---|---|
| cj-tauri | **https://atomgit.com/qq8864/cj-tauri** | 外壳/UI 框架；`examples/ai-chat` 是 cjh 托管的参照实现 |
| cjh | **https://atomgit.com/qq8864/cjh** | 内嵌 AI 引擎；WS 协议见 `src/web/protocol.cj`；集成指南见本仓 `docs/集成cjh.md` |

**上游回馈纪律**：使用 cj-tauri / cjh 过程中发现**能力不满足、行为异常或有新坑**时，
不要只在本地绕过——到对应仓**提 issue**（现象 → 根因 → 复现/证据 → 建议），有通用修法的
进一步提 PR（方法见 `cj-tauri-contribute` skill）。这是框架自进化的通道，也是课题"工具
开源"验收的生态贡献证据。

**移植阻塞的 fork 先行策略**：移植过程中发现 **tauri / openharmony-ability 的能力不满足**
（缺 API、行为缺陷、真机专属问题）时，**不要等上游修复**——直接在
https://github.com/yangyongzhen/tauri 或 https://github.com/yangyongzhen/openharmony-ability
下**建分支先解决**（`fix/<工程>-<问题>` 命名，commit 注明动机），用 patch rev 钉住继续推进移植；
**后续再把分支内容整理成 PR 贡献回上游**。等上游 = 移植流水线停摆，fork 先行 = 不阻塞交付，
两边不矛盾（记录来源：cc-switch 官方 feat/open-harmony 分支与 habit-tree 的 ability
feat/0.3.0 patch 都是这条路的实证）。

鸿蒙侧工具与技能生态（P4/P5 构建·部署链与 skill 沉淀的直接相关方；gitcode 页面有反爬，
**访问不到时按 atomgit 同路径域名试**）：

| 仓 | 远程地址 | 说明 |
|---|---|---|
| **deveco-cli** | **https://atomgit.com/openharmony-sig/deveco-cli**（= gitcode.com/openharmony-sig/deveco-cli） | 集成 HarmonyOS 应用开发工具集（知识文档 + 精品 Skills，多智能体）。命令 `devecocli`：`devecocli build` 打 HAP、`devecocli run --device <serial>` 构建+安装+启动——habit-tree 真机部署链（P5）实际用它替代裸 hvigorw/hdc 序列 |
| **harmonyos-agent-skills** | **https://atomgit.com/HarmonyOS_Skills/harmonyos-agent-skills**（= gitcode 同名仓，MIT） | 官方 HarmonyOS 应用开发 skills 集合——与本项目 `skills/t2h-ohos-port`（Tauri→鸿蒙移植 skill）同生态；新 skill 沉淀时参考其组织形态，成熟后可回馈 |

拿到新环境后的一次性动作（路径不需要记，`setup.sh` 会问/给默认值）：

```bash
git clone https://atomgit.com/qq8864/cj-tauri.git
git clone https://atomgit.com/qq8864/cjh.git
CJ_TAURI_ROOT=<你 clone 的 cj-tauri 目录> ./scripts/setup.sh   # 环境体检（只校验，不改任何文件）
```

