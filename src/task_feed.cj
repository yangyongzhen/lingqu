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

/** 落档文件的统一位置（单点定义：产出方与消费方共用，见 AGENTS §4-33 的教训） */
public func taskBoardPath(): String {
    return ".lingqu/tasks.json"
}

/** 一步的落档观测结果 */
public class StepObservation {
    public var exists: Bool = false
    public var ok: Bool = false
    public var note: String = ""
    public var artifact: String = ""
}

/** 数组字段里第一个字符串元素（没有给空串）：失败原因、第一条产物名这类取"第一条就够" */
func firstArrayStrOf(v: JsonValue, key: String): String {
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
 * 摘要（note）是给人看的一句话证据，界面与报告直接引用；取不到就给空串，不编造。
 */
func observeTaskStep(projName: String, stepId: String): StepObservation {
    let obs = StepObservation()
    obs.artifact = taskArtifactPath(projName, stepId)
    if (obs.artifact == "" || !exists(Path(obs.artifact))) {
        // 规则改造的历史形态：decisions.json 只在"记过人工决策"时才写，但改造本身
        // 会留下 `.lingqu/port/<工程>/` 目录（逐文件备份）。目录在就说明改造跑过，
        // 否则"改造过了却永远显示未开始"，断点会一直停在这一步。
        if (stepId == "port") {
            let dir = ".lingqu/port/${projName}"
            if (exists(Path(dir))) {
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
        obs.ok = boolFieldOf(check, "ok")
        obs.note = jsonStrField(check, "reason")
        return
    }
    if (stepId == "deploy") {
        let installed = boolFieldOf(objFieldOf(root, "install"), "ok")
        let started = boolFieldOf(objFieldOf(root, "start"), "ok")
        let insText = if (installed) { "成功" } else { "失败" }
        let staText = if (started) { "成功" } else { "失败" }
        let healthy = if (boolFieldOf(root, "hilogHealthy")) { "健康" } else { "未见关键行" }
        obs.ok = installed && started
        obs.note = "装 ${insText} / 启 ${staText} / hilog ${intFieldOf(root, "hilogLines", 0)} 行（${healthy}）"
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
    match (readJsonOrNone(taskBoardPath())) {
        case Some(root) => board = parseTaskBoardValue(root)
        case None => board = newTaskBoard()
    }
    board.project = projName
    if (projPath != "") {
        board.path = projPath
    }
    board.updatedAt = now
    for (s in board.steps) {
        let obs = observeTaskStep(projName, s.id)
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

/** 落盘（命令层调用）：写前把旧文件留一份 `.bak`，断点记录本身就是证据，别让它被一次写坏 */
public func saveTaskBoard(board: TaskBoard): String {
    let p = taskBoardPath()
    try {
        if (!exists(Path(".lingqu"))) {
            Directory.create(Path(".lingqu"))
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
