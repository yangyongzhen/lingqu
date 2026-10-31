# 上游回馈：cjh（可直接提 issue 的稿子）

> 背景：本项目（灵渠迁移台）在 0.32～0.37 把 **cjh 当成迁移主循环的执行者**用起来之后，
> 撞到下面几处能力缺口。每条都带**现象 / 根因（文件:行）/ 建议**，可直接粘成 issue。
> 版本基准：`cjh` 1.6.1（Windows x64 实测）。

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
| 1 | 不依赖声明式技能工具；把工具用法写进工程 `AGENTS.md` 区块 + 技能正文，让模型走 bash 调 `lingqu-cli` |
| 2 | 由界面（WebView）发任务书；后端只准备现场 + 盯落档（`t2h:autoport_*`） |
| 3 | 迁移前用 `t2h:cjh_settings_save {maxIterations: 40}` 临时抬全局值（**副作用已知，未还原**） |
| 4 | 技能装完提示"新建一次会话"；`t2h:agent_context` 走 workspace 切换降低影响 |
| 5 | `AGENTS.md` 里写 `lingqu-cli` 的**绝对路径**（`t2h:autoport_start` 现算） |
