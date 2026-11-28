package lingqu

import cjTauri.*
import std.collection.*
import std.fs.*
import std.process.*
import std.time.*
import stdx.encoding.json.*
import lingqu.scanner.*
import lingqu.compiler.*

/*
 * `lingqu-cli autoport`（0.39.153）——**无界面**地准备现场并生成任务书。
 *
 * 为什么要有它：`t2h:autoport_start` 是 IPC 专属（监管态 / 自动续跑 / ui_report），
 * 于是"跑一轮迁移"只能从界面点。可 D-015 的方向是「cjh 是执行者，界面只是前端之一」——
 * CI、脚本、换机器、以及"不受 WebView2 与探针时序影响"的实测都该能跑。
 * 所以把**任务书的生成**抽到这里，与界面共用同一个 `buildAutoPortDirective`
 * （一份任务书，不做第二份真相，§4-33 同族）。
 *
 * 无界面轮的形态（和界面一致）：任务书**落文件**，提示词只负责"把门推开"。
 * 提示词必须**纯 ASCII**——cjh 的 `--mode json <prompt>` 把提示词当命令行参数，
 * 而仓颉程序在 Windows 上接不了非 ASCII 的 argv（§4-119，直接抛
 * `Invalid unicode scalar value`）；中文全在任务书里，正好落在既有设计上。
 */

/** 任务书在工程里的相对位置（与 `t2h:autoport_start` 同源，别各写一份） */
public let AUTOPORT_DIRECTIVE_REL: String = ".lingqu/autoport-directive.md"

/**
 * 纯函数：无界面轮的提示词——**必须纯 ASCII**（见文件头注释与 §4-119）。
 *
 * 只写"去读哪个文件 + 别问确认 + 判据看落档"，不复述任务书内容：
 * 复述就是第二个漂移源（`docs/任务书规范.md` §2 同款理由）。
 */
public func autoPortHeadlessPromptOf(relDirective: String): String {
    return "Read the migration brief at " + relDirective + " and carry it out step by step. " +
        "Do not ask for confirmation; decide by the .lingqu records on disk."
}

/** 纯函数：字符串里有没有非 ASCII 字节（有就不能当 cjh 的 argv 用，§4-119） */
public func hasNonAsciiOf(s: String): Bool {
    for (b in s.toArray()) {
        if (Int64(b) >= 128) {
            return true
        }
    }
    return false
}

/**
 * 动作层：准备现场（技能 / 工程上下文）→ 读断点板与已入库经验 → 生成任务书并落盘。
 *
 * 与 `t2h:autoport_start` 的差别只有"不发 WS、不管监管态"：现场准备、任务书内容、
 * 落盘位置全部同源。回包把**能当证据的字段**都给出来（条数、字符数、是否 ASCII、
 * 建议的下一步命令），避免"说成功了但复现不了"。
 */
public func prepareAutoPortHeadless(args: JsonObject): JsonObject {
    var path = argStr(args, "path", "")
    if (path.size == 0) {
        path = envOr("LINGQU_SCAN_PATH", "")
    }
    let res = JsonObject()
    if (path.size == 0) {
        res.put("ok", JsonBool(false))
        res.put("error", JsonString("autoport 需要 --path（或置 LINGQU_SCAN_PATH）"))
        return res
    }
    var name = projectNameOf(path)
    if (name.size == 0) {
        name = "project"
    }
    let safe = sanitizeFileName(name)
    let budget = argInt(args, "budget", AUTOPORT_MAX_ITERATIONS)
    let minutes = argInt(args, "minutes", AUTOPORT_MAX_MINUTES)
    var scope = argStr(args, "scope", "all")
    if (scope.size == 0) {
        scope = "all"
    }

    // 现场准备（幂等；失败如实回投，不静默——缺了它 agent 就"看不见工具"）
    var skillNote = ""
    try {
        var sargs = JsonObject()
        sargs.put("action", JsonString("install"))
        let sv = SkillCommand().handle("t2h:skill", sargs, IpcContext("autoport", IpcHub()))
        skillNote = if (cmdOkOf(sv)) { "已装（~/.cjh/skills）" } else { "安装失败（见 t2h:skill 返回）" }
    } catch (e: Exception) {
        skillNote = "安装异常：${e}"
    }
    var agentNote = ""
    try {
        var aargs = JsonObject()
        aargs.put("action", JsonString("install"))
        aargs.put("path", JsonString(path))
        let av = AgentContextCommand().handle("t2h:agent_context", aargs, IpcContext("autoport", IpcHub()))
        agentNote = if (cmdOkOf(av)) { "已写工程 AGENTS.md 区块并把 cjh 工作区切到该工程" }
            else { "写入失败（见 t2h:agent_context 返回）" }
    } catch (e: Exception) {
        agentNote = "写入异常：${e}"
    }

    let cliPath = resolveCliExe()
    let device = migrateHasDevice()

    // 当前落档（与 IPC 同款：逐步骤一行）
    let rows = ArrayList<MigrateRow>()
    for (step in MIGRATE_STEPS) {
        let obs = observeTaskStepAt(safe, step, path)
        let row = MigrateRow()
        row.step = step
        row.title = taskStepTitle(step)
        row.ran = obs.exists
        row.ok = obs.exists && obs.ok
        row.note = obs.note
        rows.add(row)
    }
    var stateLines = ""
    for (r in rows) {
        if (stateLines.size > 0) {
            stateLines += "\n"
        }
        stateLines += migrateRowLine(r)
    }

    let lessonsDigest = readUserLessonsDigest(LESSON_DIGEST_MAX)
    let inp = AutoPortInput()
    inp.project = name
    inp.projectDir = path
    inp.cliPath = cliPath
    inp.device = device
    inp.budget = budget
    inp.minutes = minutes
    inp.stateLines = stateLines
    inp.scope = scope
    inp.knownLessons = lessonsDigest
    let directive = buildAutoPortDirective(inp)

    // 落盘（建目录用 recursive；已存在不算错，§4-76 / §4-89）
    let lqDir = path + cjhPathSep() + ".lingqu"
    let directivePath = lqDir + cjhPathSep() + "autoport-directive.md"
    var writeErr = ""
    try {
        if (!exists(Path(lqDir))) {
            Directory.create(Path(lqDir), recursive: true)
        }
        File.writeTo(directivePath, directive.toArray())
    } catch (e: Exception) {
        writeErr = "${e}"
    }
    if (writeErr.size > 0 || !exists(Path(directivePath))) {
        res.put("ok", JsonBool(false))
        res.put("error", JsonString("写任务书失败：${writeErr}（路径：${directivePath}）"))
    } else {
        res.put("ok", JsonBool(true))
    }

    let prompt = autoPortHeadlessPromptOf(AUTOPORT_DIRECTIVE_REL)
    res.put("project", JsonString(name))
    res.put("path", JsonString(path))
    res.put("directivePath", JsonString(directivePath))
    res.put("directiveChars", JsonInt(Int64(directive.size)))
    res.put("lessonsDigestItems", JsonInt(lessonsDigestCountOf(lessonsDigest)))
    res.put("lessonsDigestChars", JsonInt(Int64(lessonsDigest.size)))
    res.put("device", JsonBool(device))
    res.put("budget", JsonInt(budget))
    res.put("minutes", JsonInt(minutes))
    res.put("scope", JsonString(scope))
    res.put("cliPath", JsonString(cliPath))
    res.put("skill", JsonString(skillNote))
    res.put("agentContext", JsonString(agentNote))
    res.put("stateLines", JsonString(stateLines))
    res.put("kickoff", JsonString(buildAutoPortKickoff(directivePath)))
    res.put("headlessPrompt", JsonString(prompt))
    res.put("promptAscii", JsonBool(!hasNonAsciiOf(prompt)))
    res.put("cjhBin", JsonString(cjhBinPath()))
    // 建议的下一步（人/CI 照着跑；prompt 是 ASCII，可以直接进 argv）
    res.put("runHint", JsonString("cd " + path + " && " + cjhBinPath() + " --mode json \"" + prompt + "\""))
    return res
}

/* ===== 0.39.155：无界面轮的观测（`--run` 写状态、`--status` 只读回看） =====
 *
 * 起因（0.39.153 实测留下的话柄）：无界面轮只有在**末尾**吐一串 JSON，跑的过程中外面什么都看不到；
 * 应用侧那套 `.lingqu/agent/trace.jsonl` / `ui_report` / 停滞监控**一概没有**。
 * 于是补两件最小可用的"眼睛"：状态文件（首尾两次写入）+ 进度原文日志 + 一条只读状态命令。
 * **诚实边界**：`executeWithOutput` 是一条阻塞调用，拿不到逐行流 ⇒ 状态只在首尾更新，
 * `--status` 判"还在跑"靠的是时间（超预算 + 2 分钟还没终态 ⇒ 看起来已中断），不是真监控。
 */

/** 无界面轮的状态文件：`<工程>/.lingqu/agent/cli-run.json` */
public func autoPortRunStatusPathOf(projDir: String): String {
    return projDir + cjhPathSep() + ".lingqu" + cjhPathSep() + "agent" + cjhPathSep() + "cli-run.json"
}

/** 无界面轮的进度原文：`<工程>/.lingqu/agent/cli-run.log`（cjh 的 stderr） */
public func autoPortRunLogPathOf(projDir: String): String {
    return projDir + cjhPathSep() + ".lingqu" + cjhPathSep() + "agent" + cjhPathSep() + "cli-run.log"
}

/**
 * 纯函数：从 cjh 的 stderr 进度里数工具调用次数与最后一次工具名。
 *
 * `cjh --mode json` 把进度写 stderr（`[cjh] tool start: bash`），stdout 只在末尾一次性给 JSON ⇒
 * 想看"它在动"只能数这份 stderr。
 */
public func cjhProgressOf(stderrText: String): (Int64, String) {
    var tools: Int64 = 0
    var last = ""
    let marker = "tool start: "
    for (line in stderrText.split("\n", -1)) {
        let l = line.trimAscii()
        match (l.indexOf(marker)) {
            case Some(i) =>
                tools += 1
                last = l[(i + marker.size)..].trimAscii()
            case None => ()
        }
    }
    return (tools, last)
}

/**
 * 纯函数：无界面轮的状态判定。
 *
 * 状态文件只在**首尾**更新 ⇒ `state=running` 且已超「预算 + 2 分钟」还没有终态时，多半进程没了；
 * 这时必须说「看起来已中断」——一直显示"跑着"就是 §4-136 那种第三态缺失。
 */
public func cliRunVerdictOf(state: String, elapsedSecs: Int64, budgetMinutes: Int64): String {
    if (state == "done") {
        return "已完成"
    }
    if (state == "error") {
        return "失败（看 cli-run.log 尾部）"
    }
    if (state != "running") {
        return "未知（状态文件里的 state=${state}）"
    }
    let budget = if (budgetMinutes > 0) { budgetMinutes } else { AUTOPORT_MAX_MINUTES }
    let limit = budget * 60 + 120
    if (elapsedSecs <= limit) {
        return "跑着"
    }
    return "看起来已中断（超过预算 ${budget} 分钟 + 2 分钟仍无终态；看 cli-run.log 尾巴）"
}

/**
 * 纯函数：设备不在线时该不该**拦住这一轮**（0.39.157）。
 *
 * 为什么要拦：任务书里的「真机」是生成那一刻的快照。设备离线时起跑，agent 会跳过
 * deploy/verify/probe，或更糟——`verify` 把真机项记成 `unknown`（0.39.154 的行为）覆盖掉上次
 * 真机证据。用户为此已经付过一次代价（juCang 17:09 那轮，83% 被压成 50%）。
 * 所以默认**拒绝起跑**并说清怎么办；确实要离线跑（只想让它改代码/看落档）就加 `--allow-offline`。
 */
public func autoPortOfflineGuardOf(device: Bool, allowOffline: Bool): String {
    if (device || allowOffline) {
        return ""
    }
    return "设备不在线：这一轮会跳过 deploy/verify/probe，还可能把 verify 里的真机结论写成 unknown。" +
        "连上设备（`hdc tconn <ip:port>` 或插 USB）后重跑；确实要离线跑就加 `--allow-offline`"
}

/** 建目录并写文件（失败返回原因，别静默） */
func writeTextUnderDirOf(dir: String, file: String, text: String): String {
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir), recursive: true)
        }
        File.writeTo(file, text.toArray())
        return ""
    } catch (e: Exception) {
        return "${e}"
    }
}

/** 动作层：写状态文件（best effort；失败进返回值，调用方负责回投） */
func writeCliRunStatusOf(projDir: String, obj: JsonObject): String {
    let p = autoPortRunStatusPathOf(projDir)
    let dir = projDir + cjhPathSep() + ".lingqu" + cjhPathSep() + "agent"
    return writeTextUnderDirOf(dir, p, obj.toJsonString())
}

/** 动作层：`autoport --run` —— 真起一轮无界面回合，并把状态与进度落盘 */
public func runAutoPortHeadlessRound(args: JsonObject): JsonObject {
    let res = JsonObject()
    var path = argStr(args, "path", "")
    if (path.size == 0) {
        path = envOr("LINGQU_SCAN_PATH", "")
    }
    if (path.size == 0) {
        res.put("ok", JsonBool(false))
        res.put("error", JsonString("autoport --run 需要 --path（或置 LINGQU_SCAN_PATH）"))
        return res
    }
    let prep = prepareAutoPortHeadless(args)
    let prepOk = match (prep.get("ok")) {
        case Some(v) => v.asBool().getValue()
        case None => false
    }
    if (!prepOk) {
        res.put("ok", JsonBool(false))
        res.put("error", JsonString("准备现场失败（任务书没写成），未起回合"))
        res.put("prepareError", JsonString(match (prep.get("error")) {
            case Some(v) => v.asString().getValue()
            case None => ""
        }))
        return res
    }
    let minutes = argInt(args, "minutes", AUTOPORT_MAX_MINUTES)
    let directivePath = match (prep.get("directivePath")) {
        case Some(v) => v.asString().getValue()
        case None => path
    }
    // 0.39.157：设备离线默认**不白烧一轮**（见 autoPortOfflineGuardOf 的注释）
    let deviceNow = match (prep.get("device")) {
        case Some(v) => v.asBool().getValue()
        case None => false
    }
    let guard = autoPortOfflineGuardOf(deviceNow, argBool(args, "allow-offline", false))
    if (guard.size > 0) {
        res.put("ok", JsonBool(false))
        res.put("state", JsonString("refused"))
        res.put("device", JsonBool(deviceNow))
        res.put("directivePath", JsonString(directivePath))
        res.put("error", JsonString(guard))
        return res
    }
    let lessonsItems = match (prep.get("lessonsDigestItems")) {
        case Some(v) => v.asInt().getValue()
        case None => 0
    }
    let prompt = autoPortHeadlessPromptOf(AUTOPORT_DIRECTIVE_REL)
    let cjh = cjhBinPath()
    let projName = sanitizeFileName(projectNameOf(path))
    let startedMs = DateTime.now().toUnixTimeStamp().toMilliseconds()

    var running = JsonObject()
    running.put("schema", JsonString("lingqu/cli-run/v1"))
    running.put("state", JsonString("running"))
    running.put("project", JsonString(projName))
    running.put("path", JsonString(path))
    running.put("directivePath", JsonString(directivePath))
    running.put("cjhBin", JsonString(cjh))
    running.put("prompt", JsonString(prompt))
    running.put("budgetMinutes", JsonInt(minutes))
    running.put("lessonsDigestItems", JsonInt(lessonsItems))
    running.put("startedAtMs", JsonInt(startedMs))
    running.put("logPath", JsonString(autoPortRunLogPathOf(path)))
    let startWriteErr = writeCliRunStatusOf(path, running)

    var code: Int64 = -1
    var stdoutText = ""
    var stderrText = ""
    var runErr = ""
    try {
        let (c, out, err) = executeWithOutput(cjh, ["--mode", "json", prompt], workingDirectory: Path(path))
        code = c
        stdoutText = lenientUtf8(out)
        stderrText = lenientUtf8(err)
    } catch (e: Exception) {
        runErr = "${e}"
    }
    let elapsedSecs = (DateTime.now().toUnixTimeStamp().toMilliseconds() - startedMs) / 1000
    let (tools, lastTool) = cjhProgressOf(stderrText)
    var rounds: Int64 = 0
    var truncated = false
    if (stdoutText.trimAscii().size > 0) {
        try {
            let root = JsonValue.fromStr(stdoutText)
            let o = root.asObject()
            match (o.get("usage")) {
                case Some(u) => rounds = intFieldOf(u, "rounds", 0)
                case None => ()
            }
            truncated = match (o.get("truncated")) {
                case Some(v) => v.asBool().getValue()
                case None => false
            }
        } catch (e: Exception) {
            let _ = e
        }
    }
    let state = if (runErr.size > 0 || code != 0) { "error" } else { "done" }
    let verdict = cliRunVerdictOf(state, elapsedSecs, minutes)

    // 进度原文落盘（cjh 的 stderr 就是"它在干什么"）
    let logDir = path + cjhPathSep() + ".lingqu" + cjhPathSep() + "agent"
    var logText = "[cli-run] cjh=${cjh}\n[cli-run] cwd=${path}\n[cli-run] directive=${directivePath}\n" +
        "[cli-run] prompt=${prompt}\n[cli-run] exitCode=${code} elapsedSecs=${elapsedSecs}\n\n" +
        "[stderr]\n" + stderrText + "\n[stdoutChars] ${stdoutText.size}\n"
    let logErr = writeTextUnderDirOf(logDir, autoPortRunLogPathOf(path), logText)

    var done = JsonObject()
    done.put("schema", JsonString("lingqu/cli-run/v1"))
    done.put("state", JsonString(state))
    done.put("project", JsonString(projName))
    done.put("path", JsonString(path))
    done.put("directivePath", JsonString(directivePath))
    done.put("cjhBin", JsonString(cjh))
    done.put("budgetMinutes", JsonInt(minutes))
    done.put("lessonsDigestItems", JsonInt(lessonsItems))
    done.put("startedAtMs", JsonInt(startedMs))
    done.put("elapsedSecs", JsonInt(elapsedSecs))
    done.put("exitCode", JsonInt(code))
    done.put("tools", JsonInt(tools))
    done.put("lastTool", JsonString(lastTool))
    done.put("rounds", JsonInt(rounds))
    done.put("truncated", JsonBool(truncated))
    done.put("stdoutChars", JsonInt(Int64(stdoutText.size)))
    done.put("verdict", JsonString(verdict))
    done.put("logPath", JsonString(autoPortRunLogPathOf(path)))
    done.put("runError", JsonString(runErr))
    let statusErr = writeCliRunStatusOf(path, done)

    res.put("ok", JsonBool(state == "done"))
    res.put("state", JsonString(state))
    res.put("exitCode", JsonInt(code))
    res.put("elapsedSecs", JsonInt(elapsedSecs))
    res.put("tools", JsonInt(tools))
    res.put("lastTool", JsonString(lastTool))
    res.put("rounds", JsonInt(rounds))
    res.put("verdict", JsonString(verdict))
    res.put("directivePath", JsonString(directivePath))
    res.put("lessonsDigestItems", JsonInt(lessonsItems))
    res.put("logPath", JsonString(autoPortRunLogPathOf(path)))
    res.put("statusPath", JsonString(autoPortRunStatusPathOf(path)))
    res.put("statusWriteError", JsonString(startWriteErr + statusErr + logErr))
    res.put("runError", JsonString(runErr))
    return res
}

/** 状态文件里取字符串（缺键给空串；文件是我们自己写的，类型可信） */
func statusStrOf(o: JsonObject, key: String): String {
    return match (o.get(key)) {
        case Some(v) => v.asString().getValue()
        case None => ""
    }
}

/** 状态文件里取整数（缺键给默认值） */
func statusIntOf(o: JsonObject, key: String, fallback: Int64): Int64 {
    return match (o.get(key)) {
        case Some(v) => v.asInt().getValue()
        case None => fallback
    }
}

/**
 * 动作层：`autoport --status` —— **只读**回看无界面轮（绝不重跑）。
 *
 * 回投 `state / verdict / elapsedSecs / tools / rounds / lastTool / logTail`：无界面轮没有界面那套
 * 监管态，这份状态文件 + `cli-run.log` 就是它全部的"眼睛"。
 */
public func autoPortRunStatusOf(args: JsonObject): JsonObject {
    var path = argStr(args, "path", "")
    if (path.size == 0) {
        path = envOr("LINGQU_SCAN_PATH", "")
    }
    let res = JsonObject()
    if (path.size == 0) {
        res.put("ok", JsonBool(false))
        res.put("error", JsonString("autoport --status 需要 --path（或置 LINGQU_SCAN_PATH）"))
        return res
    }
    let statusPath = autoPortRunStatusPathOf(path)
    let logPath = autoPortRunLogPathOf(path)
    if (!exists(Path(statusPath))) {
        res.put("ok", JsonBool(false))
        res.put("state", JsonString("none"))
        res.put("statusPath", JsonString(statusPath))
        res.put("error", JsonString("还没有无界面轮的记录（先跑 `lingqu-cli autoport --run --path .`）"))
        return res
    }
    var o = JsonObject()
    var readErr = ""
    try {
        o = JsonValue.fromStr(lenientUtf8(File.readFrom(statusPath))).asObject()
    } catch (e: Exception) {
        readErr = "${e}"
    }
    if (readErr.size > 0) {
        res.put("ok", JsonBool(false))
        res.put("statusPath", JsonString(statusPath))
        res.put("error", JsonString("状态文件读不出来：${readErr}"))
        return res
    }
    let state = statusStrOf(o, "state")
    let started = statusIntOf(o, "startedAtMs", 0)
    let budget = statusIntOf(o, "budgetMinutes", AUTOPORT_MAX_MINUTES)
    let elapsedSecs = if (started > 0) {
        (DateTime.now().toUnixTimeStamp().toMilliseconds() - started) / 1000
    } else {
        0
    }
    let verdict = cliRunVerdictOf(state, elapsedSecs, budget)
    var logTail = ""
    if (exists(Path(logPath))) {
        let lines = lenientUtf8(File.readFrom(logPath)).split("\n", -1)
        let total = Int64(lines.size)
        var i = if (total > 6) { total - 6 } else { 0 }
        while (i < total) {
            logTail = logTail + lines[i] + "\n"
            i += 1
        }
    }
    res.put("ok", JsonBool(state == "done"))
    res.put("state", JsonString(state))
    res.put("verdict", JsonString(verdict))
    res.put("elapsedSecs", JsonInt(elapsedSecs))
    res.put("budgetMinutes", JsonInt(budget))
    res.put("exitCode", JsonInt(statusIntOf(o, "exitCode", -1)))
    res.put("tools", JsonInt(statusIntOf(o, "tools", 0)))
    res.put("rounds", JsonInt(statusIntOf(o, "rounds", 0)))
    res.put("lastTool", JsonString(statusStrOf(o, "lastTool")))
    res.put("lessonsDigestItems", JsonInt(statusIntOf(o, "lessonsDigestItems", 0)))
    res.put("directivePath", JsonString(statusStrOf(o, "directivePath")))
    res.put("statusPath", JsonString(statusPath))
    res.put("logPath", JsonString(logPath))
    res.put("logTail", JsonString(logTail))
    return res
}
