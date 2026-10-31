package lingqu

import std.collection.*
import stdx.encoding.json.*

/*
 * 「一键迁移」的编排层（0.36.0，AI 一体化第 7 步）。
 *
 * 目标（用户原话）：**一键完成检测与鸿蒙化移植，有真机就直接真机跑，能看见过程，最后给一份结果**。
 *
 * 编排的三条纪律：
 *   ① **判定只认落档**：每一步跑完都用 `observeTaskStep` 读盘上的落档，不读命令返回值里的乐观字段
 *      （存在 ≠ 成功，§4-63）。所以「一键」和「断点板」永远不会各说一套。
 *   ② **没设备不是失败**：deploy/verify 需要真机，没插设备/签名是 release 态时**跳过并说明**，
 *      不写进失败清单（否则一键迁移在没设备时会显得"永远失败"）。
 *   ③ **失败就地停**：停在哪一步、为什么、把下一步动作给出来；失败现场直接拼成提问正文
 *      （复用 G1/G2 的 `buildAutoAskPrompt`）交给 AI 分析。
 *
 * 本文件只有纯逻辑 + 一个状态容器；跑子进程/调 handler 在命令层 `MigrateCommand`。
 */

/** 一键迁移的步骤顺序（与 8 步断点板一致；deploy/verify 需要真机） */
public let MIGRATE_STEPS: Array<String> = [
    "scan", "deps", "port", "build", "hap", "sign", "deploy", "verify"
]

/** 需要真机的步骤 */
public func migrateNeedsDevice(step: String): Bool {
    return step == "deploy" || step == "verify"
}

/** 本次要跑的步骤：没设备就把 deploy/verify 去掉（跳过 ≠ 失败） */
public func migrateSteps(hasDevice: Bool): Array<String> {
    let out = ArrayList<String>()
    for (s in MIGRATE_STEPS) {
        if (!migrateNeedsDevice(s) || hasDevice) {
            out.add(s)
        }
    }
    return out.toArray()
}

/** 一步的结论（一行一条，界面/报告/日志共用同一份） */
public class MigrateRow {
    public var step: String = ""
    public var title: String = ""
    /** 这一步有没有跑过（落档存在）——没跑过和跑了没过必须分开 */
    public var ran: Bool = false
    public var ok: Bool = false
    /** 跳过原因（没设备 / release 态不给直装 / 用户停了） */
    public var skipped: String = ""
    public var note: String = ""
    public var at: String = ""

    public init() {}

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("step", JsonString(step))
        o.put("title", JsonString(title))
        o.put("ran", JsonBool(ran))
        o.put("ok", JsonBool(ok))
        o.put("skipped", JsonString(skipped))
        o.put("note", JsonString(note))
        o.put("at", JsonString(at))
        return o
    }
}

/** 一键迁移的可观测状态（命令层持有；页面轮询 `t2h:migrate_status` 读它） */
public class MigrateState {
    public var running: Bool = false
    public var done: Bool = false
    public var cancelled: Bool = false
    public var project: String = ""
    public var path: String = ""
    public var hasDevice: Bool = false
    /** 当前步骤下标（0 基）与总数 */
    public var index: Int64 = 0
    public var total: Int64 = 0
    public var current: String = ""
    public var message: String = ""
    public var rows: ArrayList<MigrateRow> = ArrayList<MigrateRow>()
    /** 失败现场拼成的提问正文（空 = 没有失败）；页面据此自动问 AI */
    public var askPrompt: String = ""
    public var reportMd: String = ""
    public var reportHtml: String = ""
    /** 一键迁移结果卡（`.lingqu/migrate/<工程>.md`） */
    public var resultMd: String = ""
    public var finishedAt: String = ""
    public var error: String = ""

    public init() {}

    /** 深拷贝一份（落锁内复制，锁外再拼 JSON——避免把序列化放进临界区） */
    public func snapshot(): MigrateState {
        let s = MigrateState()
        s.running = running
        s.done = done
        s.cancelled = cancelled
        s.project = project
        s.path = path
        s.hasDevice = hasDevice
        s.index = index
        s.total = total
        s.current = current
        s.message = message
        s.askPrompt = askPrompt
        s.reportMd = reportMd
        s.reportHtml = reportHtml
        s.resultMd = resultMd
        s.finishedAt = finishedAt
        s.error = error
        for (r in rows) {
            let c = MigrateRow()
            c.step = r.step
            c.title = r.title
            c.ran = r.ran
            c.ok = r.ok
            c.skipped = r.skipped
            c.note = r.note
            c.at = r.at
            s.rows.add(c)
        }
        return s
    }
}

/** 进度百分比（0..100；总数 0 时给 0，别给 -1 让界面显示"—"） */
public func migratePercent(st: MigrateState): Int64 {
    if (st.total <= 0) {
        return 0
    }
    var finished: Int64 = Int64(st.rows.size)
    if (finished > st.total) {
        finished = st.total
    }
    return finished * 100 / st.total
}

/** 有没有失败行（有 = "停在这里"） */
public func migrateFirstFailure(st: MigrateState): Option<MigrateRow> {
    for (r in st.rows) {
        if (r.ran && !r.ok) {
            return Some(r)
        }
    }
    return None
}

/**
 * 一句话结论（给界面大标题与报告结论用）。
 *
 * 四种态，别混：全部通过 / 代码链通过但真机未验证 / 停在某一步 / 还没开始。
 */
public func migrateVerdict(st: MigrateState): String {
    if (st.cancelled) {
        return "已停止（停在第 ${st.rows.size} 步之后，落档保留，可继续）"
    }
    if (st.running) {
        return "进行中：${st.index + 1}/${st.total}「${taskStepTitle(st.current)}」"
    }
    if (st.rows.size == 0) {
        return "还没开始"
    }
    match (migrateFirstFailure(st)) {
        case Some(f) => return "停在「${f.title}」：${briefOr(f.note, "落档判定未过")}"
        case None => ()
    }
    // 没有失败：要么全过，要么真机步骤被跳过
    var skippedDevice = false
    for (r in st.rows) {
        if (r.skipped.size > 0) {
            skippedDevice = true
        }
    }
    if (skippedDevice) {
        return "代码链全部通过；真机步骤已跳过（${migrateSkipReasons(st)}）"
    }
    return "全部通过"
}

/** 跳过原因合并成一句（同一原因只出现一次） */
public func migrateSkipReasons(st: MigrateState): String {
    var text = ""
    for (r in st.rows) {
        if (r.skipped.size == 0) {
            continue
        }
        if (text.contains(r.skipped)) {
            continue
        }
        if (text.size > 0) {
            text += "；"
        }
        text += r.skipped
    }
    if (text.size == 0) {
        return "无"
    }
    return text
}

/** 每步一行（界面时间轴、日志、报告表格共用） */
public func migrateRowLine(r: MigrateRow): String {
    var state = "未跑"
    if (r.skipped.size > 0) {
        state = "跳过"
    } else if (r.ran && r.ok) {
        state = "通过"
    } else if (r.ran) {
        state = "未过"
    }
    let tail = if (r.skipped.size > 0) { r.skipped } else { r.note }
    return "${r.title}｜${state}｜${tail}"
}

/** 全部步骤摘要文本（落日志/报告用，一眼看完） */
public func migrateSummaryText(st: MigrateState): String {
    var text = ""
    for (r in st.rows) {
        if (text.size > 0) {
            text += "\n"
        }
        text += migrateRowLine(r)
    }
    return text
}

/**
 * 失败后给 AI 的提问正文（复用 G1/G2 的模板，只补一段"这是一键迁移"的上下文）。
 *
 * 为什么要补上下文：模型看到一段日志片段会当成孤立报错；告诉它"这是一键迁移链的第 5 步、
 * 后面还有哪几步"，它的建议才会落在"接下来该怎么办"上，而不是"请你手动跑一下 build"。
 */
public func migrateAskPrompt(st: MigrateState, brief: StepBrief): String {
    var p = "【灵渠 · 一键迁移中断】工程 ${st.project} 的一键迁移停在第 ${st.rows.size}/${st.total} 步。\n\n"
    p += "已跑过的步骤与结论：\n"
    let rows = migrateSummaryText(st)
    if (rows.size > 0) {
        p += "```text\n${rows}\n```\n\n"
    }
    p += buildAutoAskPrompt(brief)
    return p
}

/** 状态 → JSON（`t2h:migrate_status` 的返回值；页面据此画时间轴与结果卡） */
public func migrateStateJson(st: MigrateState): JsonObject {
    var o = JsonObject()
    o.put("running", JsonBool(st.running))
    o.put("done", JsonBool(st.done))
    o.put("cancelled", JsonBool(st.cancelled))
    o.put("project", JsonString(st.project))
    o.put("path", JsonString(st.path))
    o.put("hasDevice", JsonBool(st.hasDevice))
    o.put("index", JsonInt(st.index))
    o.put("total", JsonInt(st.total))
    o.put("current", JsonString(st.current))
    o.put("currentTitle", JsonString(taskStepTitle(st.current)))
    o.put("message", JsonString(st.message))
    o.put("percent", JsonInt(migratePercent(st)))
    o.put("verdict", JsonString(migrateVerdict(st)))
    o.put("askPrompt", JsonString(st.askPrompt))
    o.put("reportMd", JsonString(st.reportMd))
    o.put("reportHtml", JsonString(st.reportHtml))
    o.put("resultMd", JsonString(st.resultMd))
    o.put("finishedAt", JsonString(st.finishedAt))
    o.put("error", JsonString(st.error))
    let arr = JsonArray()
    for (r in st.rows) {
        arr.add(r.toJson())
    }
    o.put("rows", arr)
    // 结果卡正文（界面直接 renderMd；命令行也直接打印，省得两边各拼一遍）
    let reportForMd = if (st.reportMd.size > 0) { st.reportMd } else { "报告未生成" }
    o.put("markdown", JsonString(migrateResultMarkdown(st, reportForMd)))
    return o
}

/**
 * 结果卡正文（Markdown，界面直接渲染；也是 `.lingqu/migrate/<工程>.md` 的内容）。
 *
 * 三段：结论 → 逐步 → 接下来。**只写落档里有的东西**，没有的写"未验证"。
 */
public func migrateResultMarkdown(st: MigrateState, appName: String): String {
    var md = "### 一键迁移结果 · ${st.project}\n\n"
    md += "- 工程：`${st.path}`\n"
    md += "- 结论：**${migrateVerdict(st)}**\n"
    let devText = if (st.hasDevice) { "已连接" } else { "未连接（deploy/verify 已跳过）" }
    md += "- 真机：${devText}\n"
    if (st.finishedAt.size > 0) {
        md += "- 完成时间：${st.finishedAt}\n"
    }
    md += "\n| 步骤 | 状态 | 证据 |\n|---|---|---|\n"
    for (r in st.rows) {
        var state = "未跑"
        if (r.skipped.size > 0) {
            state = "跳过"
        } else if (r.ran && r.ok) {
            state = "通过"
        } else if (r.ran) {
            state = "未过"
        }
        let tail = if (r.skipped.size > 0) { r.skipped } else { r.note }
        md += "| ${r.title} | ${state} | ${mdCell(tail)} |\n"
    }
    md += "\n**接下来**\n\n"
    let next = migrateNextHint(st)
    if (next.size == 0) {
        md += "- 无待办：一键迁移已经跑完，报告见 ${appName}\n"
    } else {
        md += next
    }
    if (st.reportMd.size > 0) {
        md += "\n- 三段式报告：`${st.reportMd}`（HTML 版 `${st.reportHtml}`）\n"
    }
    return md
}

/** 表格单元格净化：`|` 会破坏表格，换行会破坏行 */
func mdCell(text: String): String {
    let one = text.replace("\r\n", " ").replace("\n", " ")
    return one.replace("|", "／")
}

/** "接下来"清单（Markdown 列表；空串表示没有待办） */
public func migrateNextHint(st: MigrateState): String {
    var out = ""
    match (migrateFirstFailure(st)) {
        case Some(f) =>
            out += "- 先处理「${f.title}」：${briefOr(f.note, "看落档")}\n"
        case None => ()
    }
    var hasDeviceRow = false
    var verifySkipped = false
    var verifyOk = false
    for (r in st.rows) {
        if (r.step == "deploy" && r.skipped.size == 0 && r.ok) {
            hasDeviceRow = true
        }
        if (r.step == "verify") {
            if (r.skipped.size > 0) {
                verifySkipped = true
            } else if (r.ok) {
                verifyOk = true
            }
        }
    }
    if (verifySkipped) {
        out += "- 真机验证还没做：插上鸿蒙设备后点「一键迁移」重跑，或到 ⑥ 屏手动「安装并启动」+「采证」\n"
    }
    if (hasDeviceRow && !verifyOk && !verifySkipped) {
        out += "- 设备已装但验证未过：去 ⑥ 屏看功能清单，把不通过的项按平台限制登记或补适配\n"
    }
    if (out.size == 0 && st.rows.size > 0 && !st.running) {
        out += "- 没有待办\n"
    }
    return out
}

/** 一键迁移的小结句（日志与 ui_report 用：一行看完） */
public func migrateLogLine(st: MigrateState): String {
    return "project=${st.project} device=${st.hasDevice} step=${st.index + 1}/${st.total} " +
        "done=${st.done} rows=${st.rows.size} pct=${migratePercent(st)} verdict=${migrateVerdict(st)}"
}
