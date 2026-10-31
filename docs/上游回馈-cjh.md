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


