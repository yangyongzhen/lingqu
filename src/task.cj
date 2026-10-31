package lingqu

import std.collection.*
import stdx.encoding.json.*

/*
 * T6-5 断点续迁的纯函数层（命令本体在 `main.cj` 的 `ResumeCommand`，落档 `.lingqu/tasks.json`）。
 *
 * 为什么要有这一层：迁移一条链有 8 步（扫描 → 依赖 → 改造 → 编译 → 装配 → 签名 → 部署 → 验证），
 * 中间任何一步都可能因为"缺签名材料 / 真机没插 / 网络断了 / 人工吃饭去了"停下来。
 * 断点续迁要回答三个问题，而且**答案必须能从盘上的证据推出来**，不能靠内存里的进度条：
 *
 *   ① 哪些步骤真的做过？（读 `.lingqu/<步骤>/<工程>.json` 落档，不是读"我记得做过"）
 *   ② 做的结果算不算通过？（落档里的判定字段；落档存在 ≠ 成功——这条口径与 verify 一致）
 *   ③ 从哪一步继续？（第一个既没 done 也没 skipped 的步骤）
 *
 * 因此本文件只放**纯函数**：状态归一化、落档→状态的归约、断点定位、进度统计、序列化。
 * 读写盘、跑子进程都在命令层（D-009：只测纯函数，进程/网络/真机以实机为准）。
 *
 * 一条重要纪律：**人工跳过（skipped）也算"有结论"**，断点会越过它；
 * 而"落档不存在"永远是 pending——不能因为"上次好像跑过了"就把步骤算成完成。
 */

/** 流水线步骤：id 同时是落档目录名（`port` 特殊，落的是目录下的 decisions.json） */
public let TASK_STEPS: Array<(String, String)> = [
    ("scan", "扫描分析"),
    ("deps", "依赖评估"),
    ("port", "规则改造"),
    ("build", "交叉编译"),
    ("hap", "HAP 装配"),
    ("sign", "签名体检"),
    ("deploy", "真机部署"),
    ("verify", "真机验证")
]

public let TASK_STATUS_PENDING: String = "pending"
public let TASK_STATUS_RUNNING: String = "running"
public let TASK_STATUS_DONE: String = "done"
public let TASK_STATUS_FAILED: String = "failed"
public let TASK_STATUS_SKIPPED: String = "skipped"

/** ASCII 小写化（不依赖标准库大小写 API，避免踩细节） */
func taskLowerAscii(s: String): String {
    let bytes = s.toArray()
    for (i in 0..bytes.size) {
        let b = bytes[i]
        if (b >= 65 && b <= 90) {
            bytes[i] = b + 32
        }
    }
    return String.fromUtf8(bytes)
}

/** 把任意输入归一到五态之一；不认识的一律 pending（**不猜**成 done） */
public func normalizeTaskStatus(raw: String): String {
    let s = taskLowerAscii(raw.trimAscii())
    // 用 if 链而不是 match：case 模式要求常量表达式，引用 public let 不保证可用
    if (s == TASK_STATUS_DONE) {
        return TASK_STATUS_DONE
    }
    if (s == TASK_STATUS_FAILED) {
        return TASK_STATUS_FAILED
    }
    if (s == TASK_STATUS_RUNNING) {
        return TASK_STATUS_RUNNING
    }
    if (s == TASK_STATUS_SKIPPED) {
        return TASK_STATUS_SKIPPED
    }
    return TASK_STATUS_PENDING
}

/** 步骤下标（不认识回 -1） */
public func taskStepIndex(id: String): Int64 {
    var i: Int64 = 0
    for (pair in TASK_STEPS) {
        if (pair[0] == id) {
            return i
        }
        i += 1
    }
    return -1
}

/** 步骤中文标题（不认识的 id 原样回，界面别显示空白） */
public func taskStepTitle(id: String): String {
    for (pair in TASK_STEPS) {
        if (pair[0] == id) {
            return pair[1]
        }
    }
    return id
}

/** 全部步骤 id（顺序即执行顺序；用于拼错误提示与界面下拉，别让调用方自己遍历） */
public func taskStepIds(): Array<String> {
    let out = ArrayList<String>()
    for (pair in TASK_STEPS) {
        out.add(pair[0])
    }
    return out.toArray()
}

/**
 * 步骤的落档路径（纯字符串拼接）。
 *
 * 约定与本仓其它命令一致：`.lingqu/<步骤 id>/<工程名>.json`。
 * `port` 是历史例外：它的落档在**目录**里（`.lingqu/port/<工程>/decisions.json`），
 * 因为改造要按文件逐份备份（见 AGENTS §4-33 的教训：路径变了消费方必须跟着变）。
 */
public func taskArtifactPath(projName: String, stepId: String): String {
    if (taskStepIndex(stepId) < 0) {
        return ""
    }
    if (stepId == "port") {
        return ".lingqu/port/${projName}/decisions.json"
    }
    return ".lingqu/${stepId}/${projName}.json"
}

/** 一步的状态记录 */
public class TaskStep {
    public var id: String
    public var title: String
    public var status: String = TASK_STATUS_PENDING
    public var at: String = ""
    public var note: String = ""
    public var artifact: String = ""

    public init(id: String, title: String) {
        this.id = id
        this.title = title
    }

    public func toJson(): JsonObject {
        let o = JsonObject()
        o.put("id", JsonString(this.id))
        o.put("title", JsonString(this.title))
        o.put("status", JsonString(this.status))
        o.put("at", JsonString(this.at))
        o.put("note", JsonString(this.note))
        o.put("artifact", JsonString(this.artifact))
        return o
    }
}

/** 断点板：`.lingqu/tasks.json` 的内存形态 */
public class TaskBoard {
    public var project: String = ""
    public var path: String = ""
    public var updatedAt: String = ""
    /** cjh 会话 id：断点续迁要能"连 agent 会话一起续"（页面重连后 resume_session） */
    public var sessionId: String = ""
    public var steps: ArrayList<TaskStep> = ArrayList<TaskStep>()

    public init() {}

    public func findStep(id: String): Option<TaskStep> {
        for (s in this.steps) {
            if (s.id == id) {
                return Some(s)
            }
        }
        return None
    }

    public func statusOf(id: String): String {
        match (this.findStep(id)) {
            case Some(s) => return s.status
            case None => return ""
        }
    }

    public func toJson(): JsonObject {
        let o = JsonObject()
        o.put("schema", JsonString("lingqu/tasks/v1"))
        o.put("project", JsonString(this.project))
        o.put("path", JsonString(this.path))
        o.put("updatedAt", JsonString(this.updatedAt))
        o.put("sessionId", JsonString(this.sessionId))
        o.put("next", JsonString(firstUnfinished(this)))
        let p = taskProgress(this)
        o.put("done", JsonInt(p.done))
        o.put("failed", JsonInt(p.failed))
        o.put("skipped", JsonInt(p.skipped))
        o.put("total", JsonInt(p.total))
        o.put("percent", JsonInt(p.percent))
        o.put("hint", JsonString(resumeHint(this)))
        let arr = JsonArray()
        for (s in this.steps) {
            arr.add(s.toJson())
        }
        o.put("steps", arr)
        return o
    }

    public func toJsonString(): String {
        return this.toJson().toJsonString()
    }
}

/** 空板：按 `TASK_STEPS` 的顺序铺满 pending（顺序即执行顺序，界面直接照抄） */
public func newTaskBoard(): TaskBoard {
    let b = TaskBoard()
    for (pair in TASK_STEPS) {
        b.steps.add(TaskStep(pair[0], pair[1]))
    }
    return b
}

/**
 * 容错解析 `.lingqu/tasks.json`（手改过、旧版本、字段缺失都不该让命令挂掉）。
 *
 * 规则：**以 `TASK_STEPS` 为准**——文件里有未知 id 就忽略（可能来自更早/更晚的版本），
 * 缺的步骤按 pending 补齐（步骤表是代码里的常量，不是文件说了算）。
 */
public func parseTaskBoard(text: String): TaskBoard {
    if (text.trimAscii().size == 0) {
        return newTaskBoard()
    }
    var root: JsonValue = JsonObject()
    try {
        root = JsonValue.fromStr(text)
    } catch (e: Exception) {
        let _ = e
        return newTaskBoard()
    }
    return parseTaskBoardValue(root)
}

/** 同上，直接吃已解析好的 JSON（命令层/观测层省一次字符串往返） */
public func parseTaskBoardValue(root: JsonValue): TaskBoard {
    let board = newTaskBoard()
    match (root.kind()) {
        case JsonKind.JsObject =>
            board.project = jsonStrField(root, "project")
            board.path = jsonStrField(root, "path")
            board.updatedAt = jsonStrField(root, "updatedAt")
            board.sessionId = jsonStrField(root, "sessionId")
            match (root.asObject().get("steps")) {
                case Some(v) =>
                    match (v.kind()) {
                        case JsonKind.JsArray => fillTaskSteps(board, v.asArray())
                        case _ => ()
                    }
                case None => ()
            }
        case _ => ()
    }
    return board
}

/** 把落档里的 steps 数组灌进板子（未知 id 丢弃、状态归一化） */
func fillTaskSteps(board: TaskBoard, arr: JsonArray): Unit {
    var i: Int64 = 0
    while (i < arr.size()) {
        let item = arr[i]
        let id = jsonStrField(item, "id")
        match (board.findStep(id)) {
            case Some(s) =>
                s.status = normalizeTaskStatus(jsonStrField(item, "status"))
                s.at = jsonStrField(item, "at")
                s.note = jsonStrField(item, "note")
                s.artifact = jsonStrField(item, "artifact")
            case None => ()
        }
        i += 1
    }
}

/**
 * 落档观测 → 状态（断点续迁的核心归约，纯函数便于单测）。
 *
 *   · 落档不存在 → `skipped` 只有在**人工标记过跳过**时保留，否则回到 pending
 *     （"上次跑过"这种记忆不可信，盘上没有就是没跑）
 *   · 落档存在且判定通过 → done
 *   · 落档存在但判定没过 → failed（**存在 ≠ 成功**，与 verify 同一口径）
 */
public func reconcileStepStatus(prevStatus: String, artifactExists: Bool, artifactOk: Bool): String {
    let prev = normalizeTaskStatus(prevStatus)
    if (!artifactExists) {
        if (prev == TASK_STATUS_SKIPPED) {
            return TASK_STATUS_SKIPPED
        }
        return TASK_STATUS_PENDING
    }
    if (artifactOk) {
        return TASK_STATUS_DONE
    }
    return TASK_STATUS_FAILED
}

/** 一步算不算"有结论"（断点要越过它）：done 与 skipped 都算 */
public func stepIsSettled(status: String): Bool {
    let s = normalizeTaskStatus(status)
    return s == TASK_STATUS_DONE || s == TASK_STATUS_SKIPPED
}

/** 断点：第一个既没 done 也没 skipped 的步骤 id；全部有结论回 "" */
public func firstUnfinished(board: TaskBoard): String {
    for (s in board.steps) {
        if (!stepIsSettled(s.status)) {
            return s.id
        }
    }
    return ""
}

/** 进度统计（skipped 计入"已完成"，但它不是通过——所以单列出来） */
public class TaskProgress {
    public var done: Int64 = 0
    public var failed: Int64 = 0
    public var skipped: Int64 = 0
    public var total: Int64 = 0
    public var percent: Int64 = 0
}

public func taskProgress(board: TaskBoard): TaskProgress {
    let p = TaskProgress()
    for (s in board.steps) {
        p.total += 1
        let st = normalizeTaskStatus(s.status)
        if (st == TASK_STATUS_DONE) {
            p.done += 1
        } else if (st == TASK_STATUS_FAILED) {
            p.failed += 1
        } else if (st == TASK_STATUS_SKIPPED) {
            p.skipped += 1
        }
    }
    if (p.total > 0) {
        p.percent = (p.done + p.skipped) * 100 / p.total
    }
    return p
}

/**
 * 一句话告诉人"上次停在哪、接下来做什么"（界面与报告直接引用，避免各处自己拼话）。
 *
 * 三种说法对应三种真实状态：全部有结论 / 停在失败的一步 / 停在还没跑的一步。
 */
public func resumeHint(board: TaskBoard): String {
    let next = firstUnfinished(board)
    let p = taskProgress(board)
    if (next == "") {
        return "8 步全部有结论（${p.done} 通过 / ${p.skipped} 跳过）——可以出报告了"
    }
    let title = taskStepTitle(next)
    let st = board.statusOf(next)
    if (st == TASK_STATUS_RUNNING) {
        return "上次停在「${title}」跑了一半——确认现场后从这一步接着做"
    }
    if (st == TASK_STATUS_FAILED) {
        return "上次停在「${title}」失败——修好后重跑这一步，再点「刷新断点」"
    }
    return "下一步是「${title}」——从这一步接着做（前 ${p.done} 步已有落档证据）"
}

/** 手动覆盖某一步的状态（agent 应用补丁后可记 done / 人工判定做不了可记 skipped） */
public func markTaskStep(board: TaskBoard, id: String, status: String, at: String, note: String): Bool {
    match (board.findStep(id)) {
        case Some(s) =>
            s.status = normalizeTaskStatus(status)
            s.at = at
            if (note != "") {
                s.note = note
            }
            return true
        case None => return false
    }
}

/**
 * 从某一步重来：该步及其之后全部回到 pending（重新采集状态时，落档不存在的会自然留在 pending）。
 * 回 true 表示 id 存在。用途：编译失败改了配置后，"从 build 重来"而不是从头再扫一遍。
 */
public func redoFromStep(board: TaskBoard, id: String): Bool {
    let start = taskStepIndex(id)
    if (start < 0) {
        return false
    }
    for (s in board.steps) {
        if (taskStepIndex(s.id) >= start) {
            s.status = TASK_STATUS_PENDING
            s.at = ""
            s.note = ""
        }
    }
    return true
}
