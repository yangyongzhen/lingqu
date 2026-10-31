package lingqu

import std.fs.*
import stdx.encoding.json.*
import stdx.net.http.*

/*
 * ② 面向 agent 的工程上下文（AI 接入计划第 2 步，2026-11-01）。
 *
 * 两步走（用户拍板的方案）：
 *   底座 —— **切 cjh 的 workspace**：`POST /api/workspaces/switch {path}` 会 chdir 到目标工程
 *            （并重置持久 bash 会话）。不切的话 agent 的 bash/文件工具还蹲在灵渠自己的目录，
 *            "知道工具"也跑不到用户的工程上。
 *   内容 —— 往目标工程的 `AGENTS.md` 写一块**受管区块**：cjh 会从 cwd 逐级向上找 AGENTS.md
 *            并注入 system prompt，这是唯一"自动生效"的载体。
 *
 * 受管区块的三条纪律（这是本轮的核心，别写薄）：
 *   ① **幂等**：区块用固定标记包起来，重复安装只是替换区块内容，不会叠加；
 *   ② **不吞用户内容**：用户原有的 AGENTS.md 正文原样保留（区块前后都不动）；
 *   ③ **可撤销**：`remove` 只删自己那块，用户内容不受影响；删完文件为空则删文件。
 */

/** 区块开始标记（带机器可读的说明，人也能看懂"这段是自动生成的"） */
public let AGENT_BLOCK_BEGIN: String = "<!-- lingqu:begin（灵渠自动生成，勿手改；可用「移除工程上下文」删掉本段） -->"
/** 区块结束标记 */
public let AGENT_BLOCK_END: String = "<!-- lingqu:end -->"

/** 目标工程的 AGENTS.md 路径（工程根） */
public func agentContextPathOf(projDir: String): String {
    if (projDir == "") {
        return ""
    }
    return projDir + cjhPathSep() + "AGENTS.md"
}

/**
 * 区块正文（纯函数）：告诉 agent 这个工程能用什么工具、结果落在哪、口径是什么。
 *
 * 写给**模型**看的，所以：命令要能直接复制、路径要写清、口径要能防它说错话
 * （"平台限制不算失败""未验证 ≠ 通过"这两条最容易让模型编假结论）。
 */
public func agentContextBody(projName: String, projDir: String): String {
    var text = "## 这个工程正在用「灵渠迁移台」做 Tauri → 鸿蒙 PC 迁移\n\n"
    text += "工程：`${projName}`　工程根：`${projDir}`（工作目录就是这里）。\n"
    text += "所有工具结果都落在本工程的 `.lingqu/` 下，**先读落档再下结论**，别凭印象推断。\n\n"
    text += "### 可用的落档（只读，先看这里）\n\n"
    text += "| 落档 | 内容 |\n|---|---|\n"
    text += "| `.lingqu/scan/${projName}.json` | 扫描画像：五类清单、评分、覆盖率、阻塞项 |\n"
    text += "| `.lingqu/deps/${projName}.json` | Cargo 依赖矩阵：兼容/需 patch/不可用 |\n"
    text += "| `.lingqu/build/${projName}.json` | 交叉编译：退出码、诊断、**前端指纹比对** |\n"
    text += "| `.lingqu/hap/${projName}.json` | HAP 装配：产物大小、arm64 库、rawfile 死资源 |\n"
    text += "| `.lingqu/sign/${projName}.json` | 签名体检：UDID、材料、**debug/release 两态** |\n"
    text += "| `.lingqu/deploy/${projName}.json` | 真机部署：装/启/hilog |\n"
    text += "| `.lingqu/verify/${projName}.json` | 功能清单 + 可用率 + 证据 |\n"
    text += "| `.lingqu/tasks.json` | 8 步断点板（当前停在哪一步） |\n"
    text += "| `.lingqu/report/${projName}.md` | 三段式迁移报告 |\n\n"
    text += "### 工具（CLI 可直接跑；界面上的按钮是同一份实现）\n\n"
    text += "在工程目录里跑，结果既打印 JSON、也落工程自己的 `.lingqu/`：\n\n"
    text += "```bash\n"
    text += "lingqu-cli resume --path .            # 先看停在 8 步的哪一步\n"
    text += "lingqu-cli scan   --path .            # 扫描画像\n"
    text += "lingqu-cli deps   --path .            # 依赖矩阵\n"
    text += "lingqu-cli port   --path .            # 规则改造（预览；apply 才落盘）\n"
    text += "lingqu-cli build  --path .            # 交叉编译（--verifyOnly 只比前端指纹）\n"
    text += "lingqu-cli hap    --path .            # 装配 HAP\n"
    text += "lingqu-cli sign   --path .            # 签名体检（--apply 写回 signingConfigs）\n"
    text += "lingqu-cli deploy --path .            # 真机装启 + hilog\n"
    text += "lingqu-cli verify --path .            # 采证 + 功能清单 + 可用率\n"
    text += "lingqu-cli report --path .            # 三段式迁移报告\n"
    text += "```\n\n"
    text += "规则：**先 `resume` 看停在哪步，再跑那一步**；" +
        "判断「能不能用」只认 `verify` 的落档，不要拿 `build` 通过就宣称可用。\n\n"
    text += "### 口径（说结论时必须遵守，否则会误导人）\n\n"
    text += "1. **前端资源编进 `.so`**：改前端/版本号后必须重编 `.so`，只重打 HAP 无效；\n"
    text += "   `rawfile/` 是死资源。前端指纹闸报了 stale 就是「改了前端没重编」。\n"
    text += "2. **平台限制 ≠ 失败**：鸿蒙没有的能力要在清单里**登记**为平台限制，别算进失败。\n"
    text += "3. **未验证 ≠ 通过**：没有证据的项是 `unknown`，不能说成「可用」。\n"
    text += "4. **签名两态**：debug 只能装已注册设备、不能上架；release 可上架但不能直装（9568322 正常）。\n"
    text += "5. 真机装不上先看 `9568322`：证书不是华为签发 / profile 不含本机 UDID / 用了 release 包。\n\n"
    text += "### 你可以做什么\n\n"
    text += "- 读上面的落档，回答「这个工程迁到哪一步了、还差什么、下一步点哪个按钮」；\n"
    text += "- 改工程源码（`src-tauri/`、前端）——改完提醒用户重跑对应工具（改前端就要重编 `.so`）；\n"
    text += "- 不要凭空编造评分/可用率：这两个数字只能来自 `scan` 与 `verify` 的落档。\n\n"
    text += "### 让界面能执行你的建议（0.36.0 起，两个约定，请照格式写）\n\n"
    text += "灵渠的界面会**解析你的回复**并渲染成可点的卡片，所以格式固定：\n\n"
    text += "1. **建议命令**：一行一条，写成 `lingqu-cli <命令> --path <工程目录>`。" +
        "只读命令（scan/deps/sign/verify/report/batch/resume/env/diagnose）在用户开了" +
        "「自动跑只读命令」时会**自动执行**；会改工程或动真机的（port --apply/revert/hap/deploy）" +
        "也会渲染成按钮，但必须人点。\n"
    text += "2. **要人定的取舍**：写成围栏代码块（语言标记 `lingqu-decision`），块里一行 JSON：\n\n"
    text += "```lingqu-decision\n" +
        "{\"rule\":\"一句话决策点，例如：reqwest 改用 rustls 后端\",\"decision\":\"accepted\",\"why\":\"为什么这么建议\"}\n" +
        "```\n\n"
    text += "   `decision` 取 `accepted`（建议采纳）或 `ignored`（建议忽略）。界面会渲染成确认卡，" +
        "**人点一下才落进 `.lingqu/port/${projName}/decisions.json`**——你只是提案，决定权在人。\n" +
        "   同一 rule 重复提案按最后一次算（与 decisions 的覆盖语义一致）。\n"
    return text
}

/** 纯函数：text 里有没有受管区块 */
public func hasAgentBlock(text: String): Bool {
    return text.contains(AGENT_BLOCK_BEGIN) && text.contains(AGENT_BLOCK_END)
}

/**
 * 纯函数：写入/更新受管区块（**幂等**）。
 *
 *   · 原文为空 → 直接给"标记 + 正文"
 *   · 原文已有区块 → 只替换区块内容（用户内容原样不动）
 *   · 原文没有区块 → 追加到末尾，中间留一空行
 */
public func injectAgentBlock(existing: String, body: String): String {
    let block = AGENT_BLOCK_BEGIN + "\n" + body + "\n" + AGENT_BLOCK_END
    if (existing == "") {
        return block + "\n"
    }
    if (!hasAgentBlock(existing)) {
        var base = existing
        if (!base.endsWith("\n")) {
            base += "\n"
        }
        return base + "\n" + block + "\n"
    }
    // 已有区块：取 begin 之前 + 新块 + end 之后
    let beginIdx = existing.indexOf(AGENT_BLOCK_BEGIN)
    let endIdx = existing.indexOf(AGENT_BLOCK_END)
    match (beginIdx) {
        case Some(b) =>
            match (endIdx) {
                case Some(e) =>
                    if (e <= b) {
                        // 结束标记跑到开始前面（被手工改坏了）→ 按"追加"处理，别把整份文件吃掉
                        var base = existing
                        if (!base.endsWith("\n")) {
                            base += "\n"
                        }
                        return base + "\n" + block + "\n"
                    }
                    let head = existing[0..b]
                    let tail = existing[(e + AGENT_BLOCK_END.size)..existing.size]
                    return head + block + tail
                case None => ()
            }
        case None => ()
    }
    return existing
}

/**
 * 纯函数：移除受管区块（**可撤销**）：只删自己那块，用户内容保留。
 *
 * 删完只剩空白（用户原本没有 AGENTS.md）时返回空串，调用方据此删文件而不是留一个空文件。
 */
public func removeAgentBlock(existing: String): String {
    if (!hasAgentBlock(existing)) {
        return existing
    }
    let beginIdx = existing.indexOf(AGENT_BLOCK_BEGIN)
    let endIdx = existing.indexOf(AGENT_BLOCK_END)
    match (beginIdx) {
        case Some(b) =>
            match (endIdx) {
                case Some(e) =>
                    if (e <= b) {
                        return existing
                    }
                    let head = existing[0..b]
                    let tail = existing[(e + AGENT_BLOCK_END.size)..existing.size]
                    let merged = (head + tail).trimAscii()
                    return merged
                case None => return existing
            }
        case None => return existing
    }
}

/** 读文件文本（读不到给空串） */
public func readTextOrEmpty(p: String): String {
    if (p == "" || !exists(Path(p))) {
        return ""
    }
    try {
        return String.fromUtf8(File.readFrom(p))
    } catch (e: Exception) {
        let _ = e
        return ""
    }
}

/**
 * 切 cjh 的 workspace 到目标工程（`POST /api/workspaces/switch {path}`）。
 *
 * cjh 侧会 chdir + 记工作区 + 重置持久 bash 会话；返回 true 表示 cjh 确认切换成功。
 * cjh 没在跑时返回 false，调用方如实标"未切换到（引擎未就绪）"。
 */
public func cjhSwitchWorkspace(port: Int64, path: String): Bool {
    if (port <= 0 || path == "") {
        return false
    }
    try {
        let client = ClientBuilder()
            .readTimeout(Duration.second * 3)
            .writeTimeout(Duration.second * 3)
            .build()
        var obj = JsonObject()
        obj.put("path", JsonString(path))
        let req = HttpRequestBuilder()
            .post()
            .url("http://127.0.0.1:${port}/api/workspaces/switch")
            .header("Content-Type", "application/json")
            .body(obj.toJsonString())
            .build()
        let resp = client.send(req)
        let ok = Int64(resp.status) == 200
        resp.close()
        return ok
    } catch (e: Exception) {
        let _ = e
        return false
    }
}

/** cjh 当前工作区列表里的最后一项（`GET /api/workspaces`；拿不到给空串） */
public func cjhCurrentWorkspace(port: Int64): String {
    if (port <= 0) {
        return ""
    }
    var body = ""
    try {
        let client = ClientBuilder()
            .readTimeout(Duration.second * 2)
            .writeTimeout(Duration.second * 2)
            .build()
        let req = HttpRequestBuilder().get().url("http://127.0.0.1:${port}/api/workspaces").build()
        let resp = client.send(req)
        if (Int64(resp.status) != 200) {
            resp.close()
            return ""
        }
        body = readHttpBody(resp.body, 64 * 1024)
        resp.close()
    } catch (e: Exception) {
        let _ = e
        return ""
    }
    var latest = ""
    try {
        let root = JsonValue.fromStr(body)
        let arr = objFieldOf(root, "workspaces")
        match (arr.kind()) {
            case JsonKind.JsArray =>
                var i: Int64 = 0
                while (i < arr.asArray().size()) {
                    let p = jsonStrField(arr.asArray()[i], "path")
                    if (p != "") {
                        latest = p     // 列表按最近访问倒序，最后取到的就是"最近"的那条
                    }
                    i += 1
                }
            case _ => ()
        }
    } catch (e: Exception) {
        let _ = e
    }
    return latest
}
