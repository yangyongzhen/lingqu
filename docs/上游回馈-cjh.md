# 上游回馈：cjh（可直接提 issue 的稿子）

> 背景：本项目（灵渠迁移台）在 0.32～0.37 把 **cjh 当成迁移主循环的执行者**用起来之后，
> 撞到下面几处能力缺口。每条都带**现象 / 根因（文件:行）/ 建议**，可直接粘成 issue。
> 版本基准：`cjh` 1.6.1（Windows x64 实测）。
>
> **状态（2026-11-01）**：两条已修并各推一个分支（每个都是独立 PR，可分别 review）：
>
> | 分支 | 内容 | 验证 |
> |---|---|---|
> | `fix/declarative-tool-shell` | 第 1 条：`registry.cj` 的 `/bin/bash` → `ShellProvider` | build 0 warning / 540 例全绿 |
> | `feat/ws-frame-limit` | **新增第 6 条**：入站帧超限显式回 `error`（`frame_too_large`）+ `/api/capabilities` 公告 `features.ws.max_frame_bytes` | 同上 |
> | `fix/shell-provider-detect` | **新增第 7 条（本轮，最关键）**：`ShellProvider` 分层探测 + 死路径防护 + `features.shell` 自述 | `PASS=7 FAIL=0`，cjterm 98 例（+3） |
>
> 提 PR：
> - https://gitcode.com/qq8864/cjh/merge_requests/new?source_branch=fix/declarative-tool-shell
> - https://gitcode.com/qq8864/cjh/merge_requests/new?source_branch=feat/ws-frame-limit
> - https://gitcode.com/qq8864/cjh/merge_requests/new?source_branch=fix/shell-provider-detect
>
> **第 7 条现场（灵渠 0.39.0 实测）**：agent 每次 bash 都报
> `ProcessException: Created process failed, errMessage: "The system cannot find the file specified."`，
> 同轮 `read_file`/`list_dir` 正常 → 能看能规划，但**跑不了命令**。
> 根因：`ShellProvider` 只试三个**写死在 C 盘**的候选且不校验存在性；本机 Git 在
> `D:\Program Files\Git`，三个候选全不存在 → `shellPath` 指向死路径，spawn 必失败。
> **没装 Git 也一样**：现在降级 PowerShell（`isBash=false`），并把当前 shell 模式写进
> `bash` 工具描述 + `features.shell`，让模型与客户端都知道边界。
>
> **补记（同一分支第二个 commit）**：改完后 `cjpm build` 报「warning: 2 条」——
> 真凶是改造后**没人调的私有辅助 `getHomeUser()`**（改用 `%LOCALAPPDATA%` 拼路径）。删掉即
> **warning: 0 条**。顺手把 `scripts/test_win.ps1` 改成**打印 warning 明细**（只报条数的检查
> 等于没检查），并把「改完代码必回头查旧调用方」「warning 必须可见明细」写进 cjh AGENTS.md 门禁。


>
> **第 2 条（REST 对话入口）经用户指出后撤回**：产品是桌面 GUI，页面永远在场，WS 通道够用；
> 当初想加它其实是在给一个 WS bug 打补丁——而那个 bug 的**真因就是第 6 条**（超限帧静默丢弃）。
这条从"需求"降级为"可选的 headless 便利"。

---

## 1. 声明式技能工具硬编码 `/bin/bash`，Windows 上整类工具不可用（**最容易修**）

**现象**：技能（`~/.cjh/skills/*.md`）frontmatter 里声明的 `tools`，在 Windows 上调用必失败——
`executeWithOutput("/bin/bash", …)` 直接抛异常（`/bin/bash` 不存在），工具返回值恒为
`命令执行异常: …`。表现是"技能装上了、模型也看见了工具，但一调就错"。

**根因**：`src/tools/registry.cj:242`

```cangjie
var argv = Array<String>(2, repeat: "")
argv[0] = "-c"
argv[1] = cmd
let (code, stdoutBytes, stderrBytes) = executeWithOutput("/bin/bash", argv)
```

同一仓里 **`bash_session.cj:33/144` 与 `builtin.cj:100` 从 v1.3.17 起已改为
`ShellProvider` 按平台选 shell（Windows → Git Bash）**，只有 `registry.cj` 这条漏了。

**建议**：把 `registry.cj` 的 `execute` 换成 `ShellProvider` 的同款解析（3～5 行）。
顺带建议：`tools[].command` 支持 **argv 数组**（不拼 shell 字符串），这样带空格/引号的
绝对路径（Windows 上很常见）不需要额外转义。

---

## 2. 对话只有 `/ws`，没有 REST 入口 —— 非 WebView 调用方无法驱动 agent 循环

**现象**：`src/web/rest_api.cj:58-68` 的路由表里有 health/capabilities/sessions/models/
tasks/skills/mcp/settings/workspaces/fs，**没有 chat**。于是"让 agent 自己跑一条自动化流水线"
这件事，只能由一个常驻的 WebView 页面发起。我们想做「一条命令跑完 AI 迁移」
（`lingqu-cli migrate --ai --path …`，CI 里也能跑），后端没有 WS 客户端就拿不到回复流。

**建议**：加一个最薄的同步入口，够自动化用即可：

```
POST /api/chat   { "message": "...", "session_id": "可选", "max_iterations": 可选 }
→ 200 { "session_id": "...", "text": "最终回复", "tools": [{"name":…, "ok":…, "summary":…}],
        "finish_reason": "stop|cancelled|error", "rounds": 7, "duration_ms": 12345 }
```

（不需要流式；流式已有 `/ws`。对后端驱动者来说"一次调用拿到最终文本 + 工具调用摘要"就够了。）

---

## 3. `maxIterations` 只有全局 settings，没有 per-session 覆盖

**现象**：`rest_api.cj:550` 的 `case "maxIterations"` 改的是进程级 `this.config`，
`session_mgr.cj:110` / `channel.cj:1167` 建会话时直接读它。我们为了让**一次迁移**拿到
足够轮次（40 轮），只能把用户的全局配置从 8 改成 40 —— 影响他所有其它会话。

**建议**：`AgentConfig` 的 `maxIterations` 本来就是构造参数，让 `/api/chat` 或
`/api/sessions` 接受一个 `max_iterations` 覆盖值即可（一次性、不改全局）。

---

## 4. 改 `systemPrompt` 不刷新运行中的会话

**现象**：装完技能后 `POST /api/settings {systemPrompt}` 成功，但**已经在跑的会话**仍用旧
system prompt（我们的对策只能是"提示用户新建一次会话"，见 0.33.0 的界面文案）。

**建议**：要么新会话一律重读 settings 里的 systemPrompt 组装（现状大概率如此，语焉不详），
要么提供 `POST /api/sessions/reload` 明确刷新；文档里把"system prompt 在何时装配"写死。

---

## 5. （可选）技能无法声明"工具可执行文件的绝对路径"

**现象**：跨平台工具（本项目的 `lingqu-cli`）即使 shell 修好，也只能靠 `PATH` 找到。
Windows 上往 `PATH` 里塞目录是全局副作用，我们只能退化成"在 AGENTS.md 里写绝对路径 +
让模型自己拼命令行"。

**建议**：技能 frontmatter 支持 `tools[].exec`（绝对路径 + 默认 argv），
`registry` 直接 `executeWithOutput(exec, argv)`，不经 shell。跨平台工具的作者会立刻受益。

---

## 附：本项目当前的规避方式（不阻塞，但都是绕路）

| 缺口 | 我们的绕法 |
|---|---|
| 1 | ✅ 已修（分支 `fix/declarative-tool-shell`） |
| 5 | `AGENTS.md` 里写 `lingqu-cli` 的**绝对路径**（`t2h:autoport_start` 现算） |
| 3 | 迁移前用 `t2h:cjh_settings_save {maxIterations: 40}` 临时抬全局值（**副作用已知，未还原**） |
| 4 | 技能装完提示"新建一次会话"；`t2h:agent_context` 走 workspace 切换降低影响 |

---

## 排障进度：`chat` 帧发出去 cjh 不干活（比上面几条更值得先查）

**现象（灵渠 0.37.0，`LINGQU_UI_PROBE=ai` 三次实跑一致）**

```
wsSendFail   = 0            ← 发送本身没报错
wsFrameTypes = "history_messages:1"   ← cjh 只回了这一帧，之后 70 秒静默
frames = 1, toolCards = 0
～/.cjh/sessions/<新会话>.json = 158 B（只有一条 system 消息，没有 user/assistant）
```

也就是说：页面通过既有的 `ws:send {text: JSON.stringify({type:'chat', message})}` 发了 4448 字的
任务书（**发送成功**），cjh 回了一帧 `history_messages` 就再没动，会话文件里也没落我们那条消息。

**已排除**

- ❌ 通道不通：同一次会话里探针的短消息 `{type:'chat', message:'只回复两个字：收到'}` 正常得到
  `frames=3 / lastFrameType=done / replyPreview=收到`。
- ❌ 发送失败：`wsSendFail=0`、`wsLastSendErr=""`。
- ❌ 我们多余地发 `new_session`：已去掉，现象不变。

**剩下的两个变量（下一步一次跑完就能二分）**

> **已二分完成（0.37.2）**：`LINGQU_UI_PROBE=ai-short`（切完工作区**只发短句**）结果
> `frames=5, delta:2, done:2, replyPreview=收到` → 排除"切换后状态"。
> **根因是消息长度**：4448 字的任务书单帧发过去被静默丢弃，9 字短句正常。
> 灵渠侧已改为「任务书落进目标工程 `.lingqu/autoport-directive.md` + 只发 <400 字 kickoff」，
> 改后 agent 正常开工：`tool_start:40 / tool_result:40 / done:1`（886 帧）。
>
> **仍建议 cjh 侧做一件事**：WS 读侧对**超限帧显式回一个 `error` 帧**（现在是静默丢弃，
> 客户端只能靠"没有回帧"猜），并在 `/api/capabilities` 里给出 `ws.max_frame_bytes`。
> 这条比下面几条都省事，而且能救所有踩同一坑的调用方。

1. **消息长度**：失败的都是 4448 字任务书，成功的是 9 字短句。怀疑 WS 读侧有单帧上限，
   超长帧被截断/丢弃（截断的 JSON 也不会有 error 帧，正好符合"静默"）。
2. **`POST /api/workspaces/switch` 之后的状态**：失败路径都先切了 cjh 的 workspace
   （chdir + 重置持久 bash 会话），成功路径没有。

**建议的验证顺序**（都很便宜）

- ② 先发短句 `ping` 再发长任务书：短句有 delta/done 而长文没有 → 就是长度问题；
  两者都静默 → 是 workspace 切换后的会话状态问题。
- 若是长度：请 cjh 在 WS 读侧对超限帧**显式回一个 `error` 帧**（现在是静默丢弃），
  并给出上限值；灵渠侧则把任务书按段发送。
- 若是切换：建议 `POST /api/workspaces/switch` 的响应里带上"会话是否需要重建"的字段，
  或在切换后主动给所有连接推一帧 `session_reset`，让客户端知道要 `new_session`。

---

## 排障进度：bash 会话 `tool_done` 永不返回（已修，MR !11）

**现象（灵渠 0.39.5，`m3u8dl-tauri` 全自动迁移）**：agent 跑

```
cd /e/test/rust/m3u8dl-tauri && export OHOS_NDK_HOME="…" && "…/main.exe" build --path . 2>&1 | tail -50
```

带 `timeout=1800`。命令 **27 秒就跑完**（`.lingqu/build/m3u8dl-tauri.json` 已写入 6724 B、
进程表里 `lingqu-cli` 已退出），但 **`tool_done` 永远不来**，回合挂死；trace 最后一条是 `tool_start`。

**归因过程（第一版结论是错的，留档以警后人）**：一开始认定「`| tail` 把结束标记吞了」，
并据此改成"含 `|`/`>` 就改走非会话路径"——**问题没解决，还白丢了持久会话的 cwd/env**。
四个 bash 探针推翻了它（详见 cjh `docs/开发文档与踩坑记录.md` §3.57）：

| 探针（Git Bash 实测） | 结果 |
|---|---|
| `{ printf 'a\nb\nc\n' \| tail -2; } 2>&1; echo CODE; echo MARKER` | MARKER 正常到（echo 在管道**外面**，吞不掉） |
| `{ bash -c 'sleep 6 & echo hi' \| tail -1; }` | **6 秒**才返回（右端等 stdin EOF，左端残留后代握着写端） |
| 同上换 `> /tmp/out` 重定向 | **0 秒**返回（重定向不卡） |
| `{ exec 1>/dev/null; echo hi; } 2>&1; echo CODE; echo MARKER` | 只剩 `hi`（命令把 fd1 **永久改道**，这才是"标记被吞"的真形态） |

**cjh 侧已修**（分支 `fix/piped-cmd-nonsession` → MR
[!11](https://gitcode.com/qq8864/cjh/merge_requests/11)，提交 `e7a3134` + `95f9b02`）：

1. 结束标记与退出码写**独立 fd 3**（`exec 3>&1; { cmd; } 2>&1; echo CODE 1>&3; echo marker 1>&3; exec 1>&3`），
   命令怎么折腾 fd1 都不影响结束信号；命令后复位 fd1。回归用例 `BashMarkerFdTest`（旧包装必卡到超时）。
2. 回退「含 `|`/`>` 就分流」，只保留 heredoc 分流。**随后 heredoc 也回归会话了**：
   真因是包装把收尾 `}` 与终止符挤在一行，`}` 挪到独占一行即可（探针实证），
   `needsFreshShell` 整段删除 —— 现在**没有任何命令会因为写法被踢出会话**，cwd/env 无例外。
3. 超时**先抓进程快照再杀会话**（`ps -ef` 裁剪后塞进 ToolResult）——快照会随 `tool_done`
   进灵渠的 `.lingqu/agent/trace.jsonl`，下次不必靠推理猜"谁握着管道"。
4. **会话 shell 的 PATH 补齐**（`src/tools/shell_path.cj`）：cjh 用绝对路径找到 Git Bash，
   但它的 `/usr/bin` 未必在继承的 PATH 上 —— 缺了 agent 跑 `cat`/`sed`/`grep` 全是
   `command not found`（127）。现在每条命令前幂等追加 `<git>/bin`、`<git>/usr/bin`、
   `<git>/mingw64/bin`（追加不覆盖）。
5. PowerShell 非会话分支不再静默丢命令（原实现算了 base64 却没拼进命令）。

> 第 4 条对灵渠的意义：如果目标机器上 Git 没进 PATH（很常见），以前 agent 的每次
> `cat`/`sed` 都会失败并被当成"模型写错命令"，现在这一整类假故障消失。

**灵渠侧要跟着守的一条纪律**：`| tail` 那一族（右端等 EOF）cjh 治不了，只能靠**给 agent 的口径**——
长命令写 `<cmd> > build.log 2>&1`（立即返回）再 `read_file` 看日志，别用 `| tail`。
cjh 已在工具描述与超时提示里写明；灵渠的任务书/技能里也**不要出现 `| tail` 示范**
（本轮复查：`src/`、`assets/`、`skills/` 均无此写法，保持）。

---

## 8. Windows 上每条 bash 命令都闪一个控制台窗口（GUI 宿主里尤其刺眼）

**现象**（灵渠 0.39.32 实测，用户报告）

> 「右侧 AI 聊天窗口信息不更新了，但屏幕上仍不时看到 dos 窗口一闪而过，像是还在执行」

在**GUI 宿主**（灵渠是 cj-tauri 窗口应用，用 `launchHidden` 起 cjh，所以 cjh 自己**没有控制台**）
里跑 agent，每执行一条 bash 命令都会闪出一个黑色控制台窗口；命令跑得越勤（构建/测试/搜索），
闪得越频繁。用户在长任务期间只能看着它闪 + 聊天区不动，很容易误判"卡死"。

现场证据（`Get-CimInstance Win32_Process`，灵渠本机）：

```
14668 main.exe (cjh web，由灵渠 launchHidden 拉起 → 无控制台)
└─ 18468 bash.exe        ← 持久会话（BashSession）
   └─ 4820 bash.exe
      └─ 15356 bash.exe  ← 每条命令
      └─ conhost.exe     ← 这就是"闪一下"的那个窗口
```

**根因**：`src/tools/bash_session.cj:158` 的 `ensureStarted()` 用标准库 `launch` 起 shell：

```cangjie
let p = launch(this.shell.shellPath, Array<String>(0, repeat: ""), stdIn: Pipe, stdOut: Pipe, stdErr: Pipe)
```

`std.process.launch` 不带 `CREATE_NO_WINDOW`。当**父进程自己没有控制台**（GUI 子系统，或父进程也是被
`CREATE_NO_WINDOW` 拉起的）时，Windows 会给子进程**新分配**一个控制台 → 于是每个 bash 都带一个
`conhost.exe` 与一个可见窗口。同理，`registry.cj` / `builtin.cj` 里那些 `executeWithOutput(...)`
出的子进程也一样。

> 注：这条与「聊天区不动」是**两件事**，但用户看到的是同一个画面。聊天区不动是协议使然
> （`tool_start` 之后工具跑完才 `tool_result`，中间没有 delta），灵渠 0.39.32 已在界面上加
> 「⏳ 工具执行中 · Ns」秒表（`ui_report.aiToolRunning / aiToolElapsed / aiBusyText`）把"还在干活"
> 显示出来。**窗口闪烁只能由 cjh 侧消除。**

**建议（按代价从低到高）**

1. **cjutil 增加一个隐藏启动的封装**（首选）：`launchHidden(cmd, argv, stdIn/stdOut/stdErr)`，
   Windows 分支用 `CreateProcessW` 并把 `dwCreationFlags` 置 `CREATE_NO_WINDOW`
   （**不要**用 `CREATE_NEW_CONSOLE` + `SW_HIDE`：`SW_HIDE` 对 console 不生效，窗口照样闪一下）。
   POSIX 分支等价于现有 `launch`。`bash_session.cj` / `registry.cj` / `builtin.cj` 全换成它，
   并给 `features` 报一个 `features.process.hidden_window = true`，客户端可据此判断。
2. 若短期不便动 FFI：至少**在工具描述与 `features.shell` 里声明**"Windows 下每条 bash 会闪控制台窗口"，
   让客户端能提前告诉用户（灵渠已在自己的 UI 上加了秒表，但无法消除窗口）。
3. 长期可考虑：Windows 下持久会话走 `conhost.exe --headless` 或 ConPTY（`CreatePseudoConsole`），
   顺带把"交互式命令也支持"补齐。

**复现**

```
# 任意 Windows GUI 宿主（无控制台）里：
cjh web --port 8765 --bind 127.0.0.1        # 用 launchHidden 起，确保 cjh 自己没有控制台
# 然后在任意 WS 客户端发一句会让模型跑 bash 的话
# 观察：Get-CimInstance Win32_Process | ? {$_.Name -eq 'conhost.exe'} 逐条增多
```

**当前状态**：仅记录（灵渠侧已做秒表 + 本机 issue 记录）；需要 cjh 侧加 `launchHidden` 才能根治。

---

## 9. 大帧被分片后，续帧（continuation frame）被丢弃 → `ws_read_failed: Invalid utf8 byte sequence`

**现象**（灵渠 0.39.35 实测，用户报告）

聊天区弹出：

```
读取 WebSocket 帧失败（多半是单帧超过实现上限）：IllegalArgumentException: Invalid utf8 byte sequence.
code=ws_read_failed
```

**证据（灵渠侧分档探针 `LINGQU_UI_PROBE=wssend`）**

一次运行里按 4KB / 16KB / 40KB / 81KB 各发一条中文 JSON，结果 `wsErrCodes = ws_read_failed:1`
——**只有最大那档**失败。对照实验：用 node 直连 `/ws` 发 1KB~100KB **单帧**中文全部正常，
300KB 才收到显式的 `frame_too_large`（符合 cjh 的 256KB 上限）。

⇒ **不是 cjh 的读侧上限问题，而是"大负载被拆成多帧、续帧没人拼"**。

**根因**

- cj-tauri 的 WS 客户端是 `w.write(TextWebFrame, text.toArray())`（`src/plugins/ws/plugin_ws.cj:241`），
  由 stdx 的 WebSocket 实现在大负载时自行**分片**（首帧 opcode=1、后续 opcode=0）；
- cjh 的 `src/web/ws_handler.cj` 的 `messageLoop` 只处理 `TextWebFrame` / `Binary` / `Close` / `Ping` / `Pong`，
  **`ContinuationWebFrame` 落到 `case _ => ()` 被丢弃**；
- 于是 cjh 拿到的是**第一个分片**（被截断的 payload），`frameToText` 里
  `String.fromUtf8(bytes)` 在截断处正好切断一个多字节 UTF-8 字符 → `IllegalArgumentException:
  Invalid utf8 byte sequence` → 回 `ws_read_failed`。

**建议（按代价）**

1. **cjh 侧拼续帧**（正解，二十来行）：`TextWebFrame` 若 `!frame.fin` 则缓存 payload，
   后续 `ContinuationWebFrame` 依次 append，直到 `fin` 再交给 `handleWsMessage`；
   顺带把 `fin`/opcode 也记进日志，便于排障。
2. 客户端侧：把超大文本改成"落文件 + 只发路径"（灵渠已在本仓先做**60KB 截断守卫**作为止血，
   并在 `ui_report.wsTruncated` 计数；根治仍需第 1 条）。

**灵渠侧的临时处置**（0.39.35）：`wsSend` 对 `chat` 正文做 60KB 上限守卫（截断 + 明确提示），
并把出站帧体检回投 `ui_report`：`wsSendCount / wsLastSendBytes / wsLastSendType /
wsErrCodes / wsLastErrCode / wsTruncated`，下次同类问题一句话就能定位。

---

## 10. 接续旧会话时 DeepSeek 思考模式报 400：必须回传 `reasoning_content`

**现象**（用户实测，2026-11-01）

```
❌ 服务商返回错误：服务商拒绝了本次请求（Exception: HTTP 400:
   {"error":{"message":"The `reasoning_content` in the thinking mode must be passed back to the API.",
             "type":"invalid_request_error"}}）
```

**根因（cjh 侧两处口径缺失）**

1. `ChatMessage`（agent 层）只有 `role / content / toolCalls`，**没有 reasoning 字段**；
   `src/agent/loop.cj:852/987` 把模型回的 assistant 消息入历史时不带 `reasoning_content`；
2. `~/.cjh/sessions/*.json` 的落盘（`SessionStore`）也只存 role/content/name/tool_call_id
   （`src/gateway/channel.cj:1149` 的历史帧同理），**reasoning 根本没落库**。
   ⇒ 只要**接续旧会话**（`resume_session` / 进程重启后恢复），回传的历史就缺该字段 →
   DeepSeek 思考模式直接 400；全新会话不受影响。

**建议**

1. `ChatMessage` 增加 `reasoning: String`（空串=无），入历史与回传时都带上 `reasoning_content`；
2. `SessionStore` 落盘/读取保持一致（老档没有该字段时按空处理，别把老会话读坏）；
3. `history_messages` 帧也带 reasoning（客户端展示可选）；`/api/capabilities` 的 `features` 里
   声明 `reasoning_passthrough=true`，客户端就能知道"这个引擎能接续思考模式会话"。

**灵渠侧的临时处置**（0.39.36）：识别到该 400 就**自动 `new_session` 并提示**
（界面上的历史仍保留），避免用户被一条"必须重置会话"的隐性规则卡死。

---

## 11. 断开的 WS 客户端套接字不回收（常驻 `CLOSE_WAIT`），且 `/api/health` 在忙时超时

**现象 1：套接字泄漏**（2026-11-01 实测）

客户端进程被结束后，引擎侧仍留着大量 `CLOSE_WAIT`：

```
TCP 127.0.0.1:8765 -> 127.0.0.1:2189   CLOSE_WAIT   14668   （×15，来源进程 12448 早已退出）
```

即 `ws_handler`/`WebChannel` 在检测到对端关闭后**没有关闭本端 socket**（`dead=true` 只停了
发送，没有 `close()`），长时间运行会累积，最终占满端口/句柄。

**建议**：`dead` 判定成立时对底层连接显式 `close()`（或把读循环退出作为唯一的收尾点），
并在 `WebChannel` 里补一条「已关闭，丢弃后续帧」的日志（现在只有发送失败那条）。

**现象 2：`/api/health` 在引擎忙时超过 3 秒**

0.39.37 的探针日志里，同一个客户端窗口在 WS 帧正常接收的情况下，`t2h:cjh_status` 轮询
出现 `running` → `missing` → `running` 的抖动（`cjhBin` 也一度为空）。推测 `/api/health`
的实现与 agent 回合共用线程/事件循环，SSE 流式输出期间被饿住。

**建议**：`/api/health` 走独立线程或加超时保护（无条件 200 + 一份"忙/闲"标记），
让客户端能可靠区分"引擎挂了"与"引擎正忙"。客户端侧（灵渠 0.39.38）已改为
**连续两次判掉且不在干活时才断开**，但引擎侧给出可靠的健康语义更根本。

---

## 12. 超时收尾只杀得掉会话 bash 本体 → 孤儿握着管道，`p.wait` 永不返回（agent 卡死在一条工具调用里）

**现象**（2026-11-07 灵渠实机，`rust-music-2` 全流程回归时撞到）

agent 自己写的全盘扫描 `find / -maxdepth 6 -type d -name "ohos" -path "*gen*" | head -10`
带 `timeout: 120` 发出，120s 后会话被杀、超时提示本该回到模型，但**工具调用再也不返回**：
灵渠界面停在「执行中 565s」，`.lingqu/agent/trace.jsonl` 停在 13:30:55 之后再无 `tool_done`，
整轮迁移就此僵住。

现场两条证据：

```
find.exe  PID 23964  起于 13:30:55  累计 CPU 605s（会话 bash 已于 ~13:32:55 被超时杀掉）
.lingqu/agent/trace.jsonl  最后一条 tool_call 13:30:55，此后无 tool_done
```
手工 `taskkill /F /IM find.exe` 之后 **3 秒内** agent 恢复（13:44:15 新的工具调用、13:44:16 `tool_done`）
—— 说明卡住的就是 `killSession()` 里的 `p.wait`，它在等一个**被孤儿握着写端**的管道。

**根因**

`src/tools/bash_session.cj` 超时分支：`procSnapshotOf()` → `killSession()` →
`p.terminate(force: true)` → `p.wait(timeout: 5s)`。
`terminate` 只能作用于 `SubProcess` 句柄那一个进程（Git 的 `bash.exe` 启动器），
而命令真正的执行者是它 fork/exec 出来的 `/usr/bin/bash` 及其子孙；子孙持有 stdout 管道的
**写端**，于是管道永不 EOF，`wait` 就永远等不到——超时提示卡在工具调用里回不到模型。

**为什么"顺手"的三种写法都不行（逐条实测，别再重踩）**

| 写法 | 实测结果 |
|---|---|
| `taskkill /T /F /PID <pid>` | 只收掉启动器（`terminate` 报 `pid not exist`），`find.exe` 仍活（三次分别 PID 21972 / 21216 / 24008），`wait` 照挂 |
| 用 `ps -W` 的 WINPID 把原生 PID 对成 MSYS PID、再按 **PPID 递归**收子孙 | 只收到根 1 个：干活的 bash 被 re-parent 成 `PPID=1`，从启动器连不过去 —— 实测同一时刻 `4203880 0 0 9576`（启动器）与 `12279 1 12279 8940`（worker）**无父子关系** |
| 按 **Windows 原生父子链**递归 | 中间那层也已消失：`find.exe (22244)` 的 `ParentProcessId` 查出来是 GONE |
| `usr\bin\bash.exe` 替代 `bin\bash.exe` 让 `SubProcess.pid` 指向本体 | 一样：`p.pid` 仍是启动器、worker 仍 `PPID=1` |

（隔离验证：`kill -9 <MSYS pid>` 从**另一个** bash 发是有效的——`sleep` 立刻消失；
所以问题不在 `kill` 本身，而在**找不到该杀谁**。）

**唯一可靠的线索：进程组**

同一时刻 `ps -W`：

```
12298    1  12298  20552  /usr/bin/bash     ← worker：PGID == 自己的 MSYS pid
12299 12298 12298  22244  /usr/bin/find     ← 子命令在同一个进程组里
```

即 worker bash 是进程组组长，子命令及其 `head` 全在组内。据此实测
`kill -9 -<pgid>` → `find-alive=0`，比 `/T` 干净。

**修法**（`src/tools/bash_session.cj`）

1. 会话启动后立刻让 bash 把自己的 `$$` 写进一份临时文件
   （`/tmp/cjh-sess-<启动器 pid>.pid`，文件名带 pid 保证每个会话唯一）；
2. `killSession()` 收尾时 `kill -9 -$(cat '<pidfile>') 2>/dev/null; rm -f '<pidfile>'`
   —— 一次把 worker bash、`find`、`head` 整组收掉，写端随之关闭，`p.wait` 立即返回；
3. `taskkill /T /F /PID` 保留为兜底（非 bash 模式，或 pid 文件没写上时至少收掉启动器）；
4. 拿不到 pid 文件时退回原行为，不引入新的失败面。

**验证**（cjh 本轮改动，本机 Windows）

- 新增用例 `src/tests/bash_session_win_test.cj` 的
  `BashSessionWindowsTest.testTimeoutReturnsWithGrandchildHoldingPipe`：
  `find / … | head -10` + `timeout 5` → **PASSED，6.08 s 返回**（旧实现 644s+ 不返回），
  且返回后会话可重建（`echo recovered` 正常）；
- 跑完测试 `tasklist /FI "IMAGENAME eq find.exe"` → **无残留**；
- 原 `bash_session_test.cj` 整个类带 `@When[os != "Windows"]`，正是该路径零 Windows 覆盖
  的原因——这次把 Windows 侧补成独立文件；
- cjh `build warning: 0`。

**仍建议上游做的一步（更彻底）**：把会话进程放进 Windows **Job Object**
（`CreateJobObject` + `AssignProcessToJobObject` + 超时 `TerminateJobObject`），
即使子孙再 re-parent 也逃不出 job。pid 文件方案已能解掉挂死与残留，故不阻塞本次修复。

---

## 13. `--web` 模式下技能正文与 `AGENTS.md` 不进系统提示词；且技能/提示词只在进程启动时读一次（已提 issue #16；**v1.6.23 已修复，实测复核**）

> ✅ **2026-11-24 复核（随包升到 cjh v1.6.23）**：本条两条诉求都落地了。
> - **`AGENTS.md` 进 web 会话了**：在 cwd 放带 `MARKER-AGENTS-1623` 的 `AGENTS.md`，起 `cjh web --port 8766`，
>   用最小 WS 客户端发一轮 chat 问"你的 system prompt 里有没有这个串"→ **YES**。
> - **技能改成「索引 + 按需加载正文」（渐进披露）**：prompt 里是
>   `## Available skills (progressive disclosure)` + 明写 *"Skill bodies are not loaded … call `skill_load` with its name"*；
>   我们 `SKILL.md` 正文里的串（`铁律（逐条对一遍）`）**不在** prompt 里 ⇒ 只注入索引，正文按需 `skill_load`。
>   `/api/skills` 每项新增 `injected` / `reason` 字段（正是本条第 ③ 条建议），并新增热加载端点
>   **`POST /api/skills/reload`**（建议 ②）。
> - 附带影响：**"6,000 字节技能区上限"只适用 ≤1.6.18**，1.6.23 不再注入正文，也就不存在截断丢技能的问题。
> - 仍未验：`--web` 下"每会话重建提示词"这个实现细节（探针只证明内容在，不证明时机）；`skill_load` 返回正文时
>   链接是否仍是我们改写好的绝对路径（未逐字核）。


**现象**（2026-11-24 源码核对，v1.6.12 树；已提
[issue #16](https://atomgit.com/qq8864/cjh/issues/16)）

`cjh --web` 下 `~/.cjh/skills/*.md` 的**正文**与工作目录的 `AGENTS.md` 都没有进入系统提示词，
而 `GET /api/skills` 会正常列出这些技能（name / description 齐全）⇒ 集成方据此判"技能已加载可用"，
模型其实看不到任何正文。顺带：两者都是**进程启动快照**，改完文件不重启没有任何效果
（`/api/skills` 每请求扫目录，反而"看起来"更新了）。

**判据（一条命令可区分）**：技能正文写唯一 marker → 起 `cjh --web --port 8766` →
`curl -s http://127.0.0.1:8766/api/settings | grep <marker>` **无输出**，而同一条命令换
`cjh --json` / `--cli` / `--tui` 时 marker 在提示词里。

**根因**（源码口径）：`src/entries.cj` 的 `runWeb()` 只调 `loadSkillTools(...)`
（读 frontmatter 的 `tools:` 段注册声明式工具），**没有**调 `buildSystemPrompt(...)`；
后者只在 `runCli` / `runJson` / `runTui` 三个入口被调用（`src/entries.cj:298 / 456 / 641`）。
而 `src/web/session_mgr.cj` 的 `buildAgent()` 直接用 `this.config.systemPrompt`
（`settings.json` 原值）+ 启动时构造好的 `this.registry`。同一函数还负责 `memoryDir` 的项目记忆注入，
所以 web 模式下项目记忆也没有进提示词。

**建议**：① `runWeb()` 与其它三个入口对齐（启动时同样走 `buildSystemPrompt`，或把组装挪进
`buildAgent()` 每会话现算）；② 加 `POST /api/skills/reload` 热加载；③ `GET /api/skills`
区分 `listed` 与 `injected`，别让"目录里有"被读成"模型能看到"。

**本项目的规避方式**（不阻塞，但要记清代价）：技能**不适合作"及时复用"的通道**——
新经验走两条正路：任务书（每轮重新下发，天然最新）与 `.lingqu/notes` 落档；
技能只承担"人可查、agent 需要时按需读的细节库"。若确需让运行中的引擎看到新技能，
`POST /api/settings {"systemPrompt": "<base + 技能正文拼接>"}` 可即时生效（只改内存、重启回落）。

### 13.1 探针实测（2026-11-24，官方 v1.6.18 Windows 包）：一条被推翻、一条被坐实、一条新发现

**① 推翻**：`--mode json` / `--cli` / `--tui` 下技能正文**是会注入的**——此前只看源码就写成"没注入"，错了。
实测：往 `~/.cjh/skills/` 放一份带唯一标识的探针技能，问模型「列出 system prompt 里以 `### Skill` 开头的行」，
它原样给出 `### Skill: t2h-ohos-port`（1.6.18 的分节标题是英文 `## Available skills (load on demand)`）。
**教训**：`buildSystemPrompt` 在不在调用链上，与"模型能不能照它做"是两件事；判"注入有没有发生"
要用**引用正文**的判据，别用"指令有没有被执行"（技能是"按需参考"，模型可能不照做，那是设计不是缺陷）。

**② 新发现（真缺陷）：技能注入有总量预算，超出按遍历顺序静默丢弃**。同一台机、同一二进制、`--mode json`：

| `~/.cjh/skills/` 内容 | 模型看到的 `### Skill` 行 |
|---|---|
| `t2h-ohos-port.md`（13,738 B）+ `zz-probe.md`（272 B） | 只有 `t2h-ohos-port` —— 272 B 那份**被丢掉** |
| 把探针改名 `aa-probe.md`（内容不变） | `zz-probe` 与 `t2h-ohos-port` **都在** |

而 `GET /api/skills` 对两份都回 `enabled: true` ⇒ 集成方看不出"写了但没生效"。
已把实测与建议（`/api/skills` 增 `injected/reason`，或至少打日志）回投 issue #16。
**判据**：见到的技能条目数与 `ls ~/.cjh/skills/*.md` 的份数不一致，就先怀疑预算/顺序，别怀疑文件写坏了。

**③ web 那条仍是源码口径**：`src/web/` 没有 `buildSystemPrompt` / `loadSkills` /
`loadProjectInstructions` 调用；`GET /api/settings` 的 `systemPrompt` 是**原始配置值**（本例 `""`），
不是会话提示词。要坐实需要一条 WS 会话，本轮没做 ⇒ 第 13 条前半句仍按源码口径看待。

**④ 附带行为观察**：`AGENTS.md` 与技能指令冲突时，模型明确选项目指令并报告冲突
（「`AGENTS.md` requires AAGMARKER77, while the `zz-probe` skill text requires ZZMARKER42;
I followed the project instruction」）——与"项目指令 > 按需参考技能"的分层一致。





