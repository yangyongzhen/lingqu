package lingqu

import std.fs.*
import stdx.encoding.json.*

/*
 * `t2h:resume` 的观测层：把 `.lingqu/<步骤>/<工程>.json` 这些**已经存在的落档**
 * 归约成断点板（纯逻辑在 `src/task.cj`，这里只做读盘 + 取字段）。
 *
 * 口径与 `t2h:verify` 一致，别改薄：
 *   · 落档不存在 = 这一步没跑过（pending），**不是失败**
 *   · 落档存在但判定没过 = failed（存在 ≠ 成功）
 *   · 观测只读不写工程文件，也不跑任何子进程——断点续迁不该有副作用
 */

/**
 * 断点板位置（单点定义）：**跟着工程走** —— `<工程>/.lingqu/tasks.json`。
 *
 * 0.39.8 之前板子在**灵渠应用目录**（相对 CWD 的 `.lingqu/tasks.json`），跨工程共用：
 * 打开 B 工程时顶部还显示 A 工程的进度 —— 和"8 个路径框各填一遍"是同一个毛病：
 * 同一件事实存了两份权威。现在板子归工程自包含，换机器/换会话都能自证。
 *
 * `projectPath` 为空 → 退回旧路径（CLI 或没有工程上下文的调用方仍然可用）。
 *
 * **读侧别直接拼**：一律用 `resolveLqPath(projPath, "tasks.json")`（工程优先、CWD 兜底），
 * 否则切换后旧板子会突然读不到 —— AGENTS §4-33 的教训（改落档路径必须产出方与消费方同批改）。
 */
public func taskBoardPathFor(projectPath: String): String {
    return lqPathOf(projectPath, "tasks.json")
}

/** 旧位置（应用级，只在没有工程路径时出现；迁移期读侧靠 resolveLqPath 兜底） */
public func legacyTaskBoardPath(): String {
    return lqPathOf("", "tasks.json")
}

/** 一步的落档观测结果 */
public class StepObservation {
    public var exists: Bool = false
    public var ok: Bool = false
    public var note: String = ""
    public var artifact: String = ""
}

/**
 * deploy 落档 → 一句话摘要（**纯函数**，单测覆盖）。
 *
 * 规矩：失败时**必须把最有用的那句带上**。优先级：
 *   ① `start.detail`（hdc 原文 + 我们给的处置提示，如"设备在锁屏，拒绝自动解锁 → 解锁后重试"）
 *   ② `verdict.reason`（判定层的一句话）
 * 只写"启 失败"等于把信息丢掉——0.36.0 真机实测：真实原因是设备锁屏，摘要里却只剩"启 失败"，
 * 人看到会去查签名/ability。
 */
public func deployNoteOf(installed: Bool, started: Bool, hilogLines: Int64, hilogHealthy: Bool,
    startDetail: String, reason: String): String {
    let insText = if (installed) { "成功" } else { "失败" }
    let staText = if (started) { "成功" } else { "失败" }
    let healthy = if (hilogHealthy) { "健康" } else { "未见关键行" }
    var note = "装 ${insText} / 启 ${staText} / hilog ${hilogLines} 行（${healthy}）"
    if (installed && started) {
        return note
    }
    let detail = startDetail.trimAscii()
    if (detail.size > 0) {
        // hdc 原文前缀（"error: failed to start ability."）对读者没价值，只留我们给的处置提示。
        // 用 `处置：` 做切点而不是按字节去掉前缀——切点必须落在字符边界上（AGENTS §4-67 相邻坑），
        // 也顺手避免了 "｜｜" 这种叠分隔符。
        match (detail.indexOf("处置：")) {
            case Some(i) => return note + "｜" + detail[i..detail.size]
            case None => return note + "｜" + detail
        }
    }
    let why = reason.trimAscii()
    if (why.size > 0) {
        return note + "｜" + why
    }
    return note
}

/** 数组字段里第一个字符串元素（没有给空串）：失败原因、第一条产物名这类取"第一条就够" */func firstArrayStrOf(v: JsonValue, key: String): String {
    let arr = objFieldOf(v, key)
    match (arr.kind()) {
        case JsonKind.JsArray =>
            if (arr.asArray().size() == 0) {
                return ""
            }
            let e = arr.asArray()[0]
            match (e.kind()) {
                case JsonKind.JsString => return e.asString().getValue()
                case _ => return ""
            }
        case _ => return ""
    }
}

/**
 * 读一步的落档并给出「在不在 / 过没过 / 一句摘要」。
 *
 * `projectPath` 非空时按新口径（工程优先、CWD 兜底）找落档；空串退回旧形态。
 * 摘要（note）是给人看的一句话证据，界面与报告直接引用；取不到就给空串，不编造。
 */
func observeTaskStepAt(projName: String, stepId: String, projectPath: String): StepObservation {
    let obs = StepObservation()
    let rel = taskArtifactRelPath(projName, stepId)
    if (rel == "") {
        return obs
    }
    obs.artifact = resolveLqPath(projectPath, rel)
    if (!exists(Path(obs.artifact))) {
        // 规则改造的历史形态：decisions.json 只在"记过人工决策"时才写，但改造本身
        // 会留下 `.lingqu/port/<工程>/` 目录（逐文件备份）。目录在就说明改造跑过，
        // 否则"改造过了却永远显示未开始"，断点会一直停在这一步。
        if (stepId == "port") {
            let dir = lqDirOf(projectPath) + cjhPathSep() + "port" + cjhPathSep() + projName
            let legacyDir = ".lingqu/port/${projName}"
            if (exists(Path(dir)) || exists(Path(legacyDir))) {
                obs.exists = true
                obs.ok = true
                obs.note = "已应用改造（有备份，未记人工决策）"
            }
        }
        return obs
    }
    obs.exists = true
    match (readJsonOrNone(obs.artifact)) {
        case Some(root) => fillObservation(obs, stepId, root)
        case None =>
            // 落档在但读不出来：算"存在但没过"——不能因为坏文件就当成成功
            obs.ok = false
            obs.note = "落档无法解析"
    }
    return obs
}

/** 旧签名（只认 CWD 落档）；新代码请用 `observeTaskStepAt` 并把工程路径带上 */
func observeTaskStep(projName: String, stepId: String): StepObservation {
    return observeTaskStepAt(projName, stepId, "")
}

/** 按步骤种类取判定与摘要（各命令的落档 schema：scan/deps/port/build/hap/sign/deploy/verify v1） */
func fillObservation(obs: StepObservation, stepId: String, root: JsonValue): Unit {
    if (stepId == "scan") {
        let m = objFieldOf(root, "metrics")
        let score = objFieldOf(root, "score")
        // 扫描落档存在即算跑过；条数为 0 也要如实报（"工程里没可扫描的东西"是结论，不是失败）
        obs.ok = true
        obs.note = "单元 R=${intFieldOf(m, "R", 0)} / D=${intFieldOf(m, "D", 0)} / U=${intFieldOf(m, "U", 0)}" +
            " / 评分 ${intFieldOf(score, "total", 0)} / 阻塞 ${arraySizeFieldOf(root, "blockers")} 项"
        return
    }
    if (stepId == "deps") {
        let m = objFieldOf(root, "metrics")
        let total = intFieldOf(m, "total", 0)
        obs.ok = total > 0
        obs.note = "依赖 ${total} 包 / 需 patch ${intFieldOf(m, "patch", 0)} / 不可用 ${intFieldOf(m, "unavailable", 0)}"
        return
    }
    if (stepId == "port") {
        obs.ok = true
        obs.note = "人工决策 ${arraySizeFieldOf(root, "items")} 条"
        return
    }
    if (stepId == "build") {
        let exit = intFieldOf(root, "exitCode", -1)
        let gates = objFieldOf(root, "gates")
        let passed = boolFieldOf(gates, "passed")
        let diff = objFieldOf(root, "assetDiff")
        obs.ok = exit == 0 && passed
        obs.note = "exit=${exit} / 错误 ${intFieldOf(root, "errorCount", 0)}" +
            " / 前端指纹 一致 ${arraySizeFieldOf(diff, "matched")}、过期 ${arraySizeFieldOf(diff, "staleInSo")}、" +
            "缺 ${arraySizeFieldOf(diff, "missingInSo")}"
        if (!obs.ok) {
            // 判失败时把闸的第一条原因贴出来：人第一眼要能看到"为什么不算通过"
            let why = firstArrayStrOf(gates, "failures")
            if (why != "") {
                obs.note = obs.note + "｜闸未过：${why}"
            }
        }
        return
    }
    if (stepId == "hap") {
        let gates = objFieldOf(root, "gates")
        let entries = objFieldOf(root, "entries")
        obs.ok = boolFieldOf(root, "built") && boolFieldOf(gates, "passed")
        obs.note = "HAP ${intFieldOf(root, "hapBytes", 0)} 字节 / arm64 库条目 ${arraySizeFieldOf(entries, "arm64Sos")} 个" +
            " / rawfile ${intFieldOf(entries, "rawfileCount", 0)} 个死资源"
        return
    }
    if (stepId == "sign") {
        let check = objFieldOf(root, "check")
        let modeObj = objFieldOf(root, "mode")
        let modeName = jsonStrField(modeObj, "mode")
        // T5-4：**release 态也算这一步"有结论"**——它装不上真机是设计使然（profile 不含
        // device-ids），不能因此在断点板上显示"失败"，否则人会去"修"一个正常的状态。
        // 老落档没有 mode 段（0.26 之前），此时退回"可直装就算过"的旧口径。
        obs.ok = boolFieldOf(check, "ok") || modeName == "release"
        let label = jsonStrField(modeObj, "modeLabel")
        let reason = jsonStrField(check, "reason")
        if (modeName != "") {
            var tail = ""
            if (reason != "") {
                tail = "｜" + reason
            }
            obs.note = "签名态 ${label}${tail}"
        } else {
            obs.note = reason
        }
        return
    }
    if (stepId == "deploy") {
        let installed = boolFieldOf(objFieldOf(root, "install"), "ok")
        let started = boolFieldOf(objFieldOf(root, "start"), "ok")
        obs.ok = installed && started
        obs.note = deployNoteOf(installed, started, intFieldOf(root, "hilogLines", 0),
            boolFieldOf(root, "hilogHealthy"),
            jsonStrField(objFieldOf(root, "start"), "detail"),
            jsonStrField(objFieldOf(root, "verdict"), "reason"))
        return
    }
    if (stepId == "verify") {
        let stats = objFieldOf(root, "stats")
        let total = intFieldOf(stats, "total", 0)
        obs.ok = total > 0
        obs.note = "可用率 ${intFieldOf(stats, "ratePercent", 0)}%（通过 ${intFieldOf(stats, "pass", 0)}/${total}" +
            "，平台限制 ${intFieldOf(stats, "limit", 0)}）"
        return
    }
    obs.ok = false
    obs.note = ""
}

/**
 * 采集断点板：读旧板（保留人工标记 / 会话 id）+ 逐步骤观测落档 → 归约状态。
 *
 * `now` 由调用方给（命令层用 `nowText()`），这样这一层除了读盘没有别的副作用。
 */
public func collectTaskBoard(projName: String, projPath: String, now: String): TaskBoard {
    var board = newTaskBoard()
    // 工程优先、CWD 兜底：迁移期旧板子（应用目录）照样读得到
    match (readJsonOrNone(resolveLqPath(projPath, "tasks.json"))) {
        case Some(root) => board = parseTaskBoardValue(root)
        case None => board = newTaskBoard()
    }
    board.project = projName
    if (projPath != "") {
        board.path = projPath
    }
    board.updatedAt = now
    for (s in board.steps) {
        let obs = observeTaskStepAt(projName, s.id, projPath)
        s.status = reconcileStepStatus(s.status, obs.exists, obs.ok)
        s.artifact = obs.artifact
        if (obs.note != "") {
            // 观测到的摘要**总是覆盖**人工写的备注：盘上的证据比"我记得"更可信（且过期备注会误导）
            s.note = obs.note
        }
        if (s.status == TASK_STATUS_DONE || s.status == TASK_STATUS_FAILED) {
            if (s.at == "") {
                s.at = now
            }
        } else if (s.status == TASK_STATUS_PENDING) {
            s.at = ""
            if (obs.note == "") {
                s.note = ""
            }
        }
    }
    return board
}

/**
 * 落盘（命令层调用）：写前把旧文件留一份 `.bak`，断点记录本身就是证据，别让它被一次写坏。
 *
 * 写位置由 `projectPath` 决定（工程级）；工程路径为空时退回旧的应用级位置。
 * 目录不存在会**递归创建**——0.39.7 之前这里只 `Directory.create(".lingqu")`，
 * 换成工程级路径后不建目录会直接写失败。
 */
public func saveTaskBoard(board: TaskBoard, projectPath: String): String {
    let p = taskBoardPathFor(projectPath)
    let dir = lqDirOf(projectPath)
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir), recursive: true)
        }
        if (exists(Path(p))) {
            File.writeTo("${p}.bak", File.readFrom(p))
        }
        File.writeTo(p, board.toJsonString().toArray())
    } catch (e: Exception) {
        return "写断点板失败：${e}"
    }
    return ""
}

/** 断点板里的步骤摘要（给界面渲染成一行一条，不需视觉也能断言条数） */
public func stepSummaryLine(step: TaskStep): String {
    let st = normalizeTaskStatus(step.status)
    let tail = if (step.note != "") { step.note } else { step.artifact }
    return "${taskStepTitle(step.id)}｜${st}｜${tail}"
}

/** 全部步骤的摘要文本（落档/日志里一眼能看懂，`t2h:resume` 返回值也带它） */
public func taskBoardSummary(board: TaskBoard): String {
    var text = ""
    for (s in board.steps) {
        if (text != "") {
            text += "\n"
        }
        text += stepSummaryLine(s)
    }
    return text
}
