package lingqu

import cjTauri.*
import std.collection.*
import std.fs.*
import stdx.encoding.json.*
import lingqu.scanner.*

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
