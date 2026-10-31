package lingqu.report

import std.collection.*

/*
 * T6-4 迁移报告的纯函数层（收数在 `src/report_feed.cj`，命令本体在 `main.cj` 的 `ReportCommand`）。
 *
 * 报告只有一个形状：**三段式**——做了什么 / 没做什么 / 需要你做什么。
 * 三段都是**从落档推导**的，不是模板文案：
 *
 *   · 做了什么  ← 8 步里真跑过且判定通过的步骤（每步带它自己的落档摘要）
 *   · 没做什么  ← 没跑的步骤 + 没过的步骤 + 平台限制项（**平台限制不算失败**，单列）
 *                 + 未采集证据的项（未验证 ≠ 通过）+ 人工跳过
 *   · 需要你做什么 ← 由上面两类衍生的**可执行动作**，每条都对应界面上的一个按钮
 *
 * 设计纪律（与 verify / task 一致）：
 *   ① 没数据就说没数据，**不编造**（"0 份证据"永远比编个"13 份"诚实）；
 *   ② 平台限制与失败分列，混在一起会让人以为鸿蒙缺能力是工具的错；
 *   ③ 报告里每个数字都要能追到一份落档（见附录的产物清单）。
 */

/** 三段式里的一段 */
public class ReportSection {
    public var key: String
    public var title: String
    public var lines: ArrayList<String> = ArrayList<String>()

    public init(key: String, title: String) {
        this.key = key
        this.title = title
    }
}

/** 报告成品：三段 + 结论 + 附录产物清单 */
public class ReportDoc {
    public var title: String = ""
    public var project: String = ""
    public var path: String = ""
    public var generatedAt: String = ""
    public var conclusion: String = ""
    public var sections: ArrayList<ReportSection> = ArrayList<ReportSection>()
    public var artifacts: ArrayList<(String, String)> = ArrayList<(String, String)>()

    public init(title: String, project: String) {
        this.title = title
        this.project = project
    }

    public func sectionOf(key: String): Option<ReportSection> {
        for (s in this.sections) {
            if (s.key == key) {
                return Some(s)
            }
        }
        return None
    }

    public func lineCount(key: String): Int64 {
        match (this.sectionOf(key)) {
            case Some(s) => return Int64(s.lines.size)
            case None => return 0
        }
    }

    public func linesOf(key: String): ArrayList<String> {
        match (this.sectionOf(key)) {
            case Some(s) => return s.lines
            case None => return ArrayList<String>()
        }
    }
}

/**
 * 写报告要的全部事实（**全部来自落档**，命令层的 `report_feed` 负责填）。
 *
 * 8 步用并行的数组表示（id / 标题 / 状态 / 摘要），顺序即执行顺序——
 * 与 `t2h:resume` 的 `TASK_STEPS` 一致，报告与断点板看到的永远是同一份状态。
 */
public class MigrationFacts {
    public var project: String = ""
    public var path: String = ""
    public var bundleName: String = ""
    public var generatedAt: String = ""
    // 8 步状态机（来自 .lingqu/tasks.json 的观测结果）
    public var stepIds: ArrayList<String> = ArrayList<String>()
    public var stepTitles: ArrayList<String> = ArrayList<String>()
    public var stepStatuses: ArrayList<String> = ArrayList<String>()
    public var stepNotes: ArrayList<String> = ArrayList<String>()
    public var stepDone: Int64 = 0
    public var stepTotal: Int64 = 0
    public var stepPercent: Int64 = 0
    public var nextStep: String = ""
    // 功能清单与可用率（来自 .lingqu/verify/<工程>.json）
    public var verifyTotal: Int64 = 0
    public var verifyPass: Int64 = 0
    public var verifyFail: Int64 = 0
    public var verifyLimit: Int64 = 0
    public var verifyUnknown: Int64 = 0
    public var verifyRate: Int64 = -1
    public var limitItems: ArrayList<String> = ArrayList<String>()
    public var unknownItems: ArrayList<String> = ArrayList<String>()
    public var failedItems: ArrayList<String> = ArrayList<String>()
    // 证据与产物
    public var evidenceCount: Int64 = 0
    public var artifacts: ArrayList<(String, String)> = ArrayList<(String, String)>()
    // T5-4 签名两态：当前签名态 + 上架前强提醒（debug 态必须出现在"没做什么/需要你做什么"）
    public var signMode: String = ""
    public var signReminder: String = ""
    public var signReleaseNextStep: String = ""
    public var signReleaseReady: Bool = false
    // A3：人工介入（guide 项被采纳才算一次，忽略也要留痕）
    public var humanAccepted: Int64 = 0
    public var humanIgnored: Int64 = 0
    public var decisionsNote: String = ""
}

/** 人工介入计数结果（A3 口径：accepted 才算一次介入） */
public class HumanCount {
    public var accepted: Int64 = 0
    public var ignored: Int64 = 0
}

/** 一步的"下一步动作"（界面上对应哪个按钮，报告里就写哪句，别让人猜） */
public func stepActionHint(stepId: String): String {
    if (stepId == "scan") {
        return "跑一次扫描（② 迁移画像「重新扫描」）"
    }
    if (stepId == "deps") {
        return "跑依赖评估（③ 依赖扫描「扫描 Cargo 依赖」）"
    }
    if (stepId == "port") {
        return "跑规则改造（④ 改造执行「预览改造」→「应用」）"
    }
    if (stepId == "build") {
        return "交叉编译（⑤ 构建打包「交叉编译（OHOS）」）；提示前端指纹不一致时先重编 .so"
    }
    if (stepId == "hap") {
        return "装配 HAP（⑤ 构建打包「装配 HAP」）"
    }
    if (stepId == "sign") {
        return "签名体检（⑤ 构建打包「签名体检」）；工程没配签名时先点「写回签名配置」"
    }
    if (stepId == "deploy") {
        return "真机部署（⑥ 真机验证「安装并启动」）"
    }
    if (stepId == "verify") {
        return "采证据算可用率（⑥ 真机验证「采集证据并算可用率」）"
    }
    return "重跑这一步"
}

/** 判定是否算"有结论"（done / skipped），与 `t2h:resume` 同一口径 */
public func reportStepSettled(status: String): Bool {
    return status == "done" || status == "skipped"
}

/** 「标题」+ 摘要的一段文字（摘要为空时只留标题，不留一个悬空的冒号） */
func titled(title: String, note: String): String {
    if (note == "") {
        return "「${title}」"
    }
    return "「${title}」：${note}"
}

/** 带判定词的步骤行：`「交叉编译」没过：<摘要>`。判定词在前，摘要跟在冒号后（读起来才顺） */
func verdictLine(title: String, verdict: String, note: String): String {
    if (note == "") {
        return "「${title}」${verdict}"
    }
    return "「${title}」${verdict}：${note}"
}

/**
 * 由事实生成三段式报告（**纯函数**：同样的落档永远得到同样的报告）。
 *
 * 段落顺序有意为之：做了什么 → 没做什么 → 需要你做什么。
 * 报告的第一读者是"接手的人"，不是写报告的人。
 */
public func buildReport(facts: MigrationFacts): ReportDoc {
    let doc = ReportDoc("${facts.project} 迁移报告", facts.project)
    doc.path = facts.path
    doc.generatedAt = facts.generatedAt

    let did = ReportSection("did", "做了什么")
    let undone = ReportSection("undone", "没做什么（已知限制与未验证）")
    let need = ReportSection("need", "需要你做什么")

    var i: Int64 = 0
    while (i < facts.stepIds.size) {
        let id = facts.stepIds[i]
        let title = if (i < facts.stepTitles.size) { facts.stepTitles[i] } else { id }
        let status = if (i < facts.stepStatuses.size) { facts.stepStatuses[i] } else { "pending" }
        let note = if (i < facts.stepNotes.size) { facts.stepNotes[i] } else { "" }
        if (status == "done") {
            did.lines.add(titled(title, note))
        } else if (status == "failed") {
            // 失败归"没做什么"，原因就在摘要里（断点板与报告用同一句摘要，不会各说一套）
            undone.lines.add(verdictLine(title, "没过", note))
        } else if (status == "skipped") {
            undone.lines.add(verdictLine(title, "按人工判断跳过", note))
        } else if (status != "running") {
            undone.lines.add(verdictLine(title, "还没跑", note))
        }
        i += 1
    }
    if (facts.evidenceCount > 0) {
        did.lines.add("采集到 ${facts.evidenceCount} 份真机证据（截图在 .lingqu/evidence/）")
    }
    if (facts.verifyPass > 0) {
        let denom = facts.verifyTotal - facts.verifyLimit
        did.lines.add("功能清单通过 ${facts.verifyPass}/${denom} 项（平台限制已从分母剔除）")
    }
    if (did.lines.size == 0) {
        did.lines.add("还没有任何步骤跑出结果——先跑一次扫描")
    }

    // 平台限制 / 未验证 / 失败三类**分开写**：混成一句"未完成"会让人误判
    for (t in facts.limitItems) {
        undone.lines.add("平台限制（不算失败，已在清单登记）：${t}")
    }
    for (t in facts.unknownItems) {
        undone.lines.add("未验证（没有证据就不算通过）：${t}")
    }
    for (t in facts.failedItems) {
        undone.lines.add("验证失败：${t}")
    }
    if (facts.decisionsNote != "") {
        undone.lines.add(facts.decisionsNote)
    }
    // T5-4：debug 签名是"能装真机但绝不能上架"的态，必须出现在"没做什么"里——
    // 这是上架前最容易漏的一条（真机跑得好好的，提交审核却被拒）
    if (facts.signMode == "debug" && !facts.signReleaseReady) {
        undone.lines.add("签名是 debug 态：可直装真机，但**不能上架**（AGC 不接受 debug 证书）")
    }
    if (undone.lines.size == 0) {
        undone.lines.add("没有已知遗留——8 步都有结论，清单项全部通过或已登记平台限制")
    }

    // 需要你做什么：从上面两类推动作，每条都能落到界面上的一个按钮
    i = 0
    while (i < facts.stepIds.size) {
        let id = facts.stepIds[i]
        let title = if (i < facts.stepTitles.size) { facts.stepTitles[i] } else { id }
        let status = if (i < facts.stepStatuses.size) { facts.stepStatuses[i] } else { "pending" }
        if (status == "failed") {
            need.lines.add("「${title}」没过 → ${stepActionHint(id)}")
        } else if (!reportStepSettled(status) && status != "running") {
            need.lines.add("「${title}」还没跑 → ${stepActionHint(id)}")
        }
        i += 1
    }
    for (t in facts.unknownItems) {
        need.lines.add("补验证：${t}（采到证据才会从「未验证」变成通过）")
    }
    for (t in facts.failedItems) {
        need.lines.add("处理失败项：${t}")
    }
    if (facts.humanAccepted > 0) {
        need.lines.add("复核 ${facts.humanAccepted} 处人工介入的结论（验收 A3：单应用 ≤5 处）")
    }
    // T5-4 上架前强提醒：原文照引（含"必须切回 release"那句），后面再给出具体下一步
    if (facts.signMode == "debug" && !facts.signReleaseReady) {
        if (facts.signReminder != "") {
            need.lines.add(facts.signReminder)
        }
        if (facts.signReleaseNextStep != "") {
            // 这句自己已经以「上架前：」开头（sign.cj 的措辞），别再叠一层前缀
            need.lines.add(facts.signReleaseNextStep)
        } else {
            need.lines.add("上架前：把 signingConfig 切到 release profile，重跑「装配 HAP」再提交审核")
        }
    }
    if (need.lines.size == 0) {
        need.lines.add("没有需要你处理的事项——报告可直接归档")
    }

    doc.sections.add(did)
    doc.sections.add(undone)
    doc.sections.add(need)
    doc.artifacts = facts.artifacts
    doc.conclusion = reportConclusion(facts)
    return doc
}

/** 一句话结论：8 步进度 + 可用率 + 人工介入数（A3/A4 两个验收指标都在这一句里） */
public func reportConclusion(facts: MigrationFacts): String {
    let rateText = if (facts.verifyRate >= 0) { "${facts.verifyRate}%" } else { "尚未验证" }
    return "${facts.project}：8 步完成 ${facts.stepDone}/${facts.stepTotal}" +
        "（${facts.stepPercent}%），核心功能可用率 ${rateText}，" +
        "${facts.humanAccepted} 处人工介入"
}

/**
 * 字符级 HTML 转义：按字节走，**只替换 5 个危险 ASCII 字符，中文原样保留**。
 *
 * 别用"按字节拼数字再回头 fromUtf8"那种写法：中文是多字节，逐字节转字符串会被拆碎
 * （这正是 0.12.0 踩过的坑，见 AGENTS §4-41 的同类教训）。
 */
public func escapeHtmlText(s: String): String {
    let out = ArrayList<Byte>()
    for (b in s.toArray()) {
        if (b == 60) {
            appendAscii(out, "&lt;")
        } else if (b == 62) {
            appendAscii(out, "&gt;")
        } else if (b == 38) {
            appendAscii(out, "&amp;")
        } else if (b == 34) {
            appendAscii(out, "&quot;")
        } else {
            out.add(b)
        }
    }
    return String.fromUtf8(out.toArray())
}

/** 把一段 ASCII 文本的字节追加到缓冲区（转义实体都是纯 ASCII） */
func appendAscii(out: ArrayList<Byte>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

/** Markdown 渲染（三段 + 附录）。刻意不用表格：产物路径长短不一会撑爆表格布局 */
public func renderReportMarkdown(doc: ReportDoc): String {
    var text = "# ${doc.title}\n\n"
    text += "- 工程：`${doc.path}`\n"
    if (doc.generatedAt != "") {
        text += "- 生成时间：${doc.generatedAt}\n"
    }
    text += "- 结论：**${doc.conclusion}**\n\n"
    for (sec in doc.sections) {
        text += "## ${sec.title}\n\n"
        for (line in sec.lines) {
            text += "- ${line}\n"
        }
        text += "\n"
    }
    text += "## 附录：产物与落档（每个数字都能追到这里）\n\n"
    for (entry in doc.artifacts) {
        text += "- ${entry[0]}：`${entry[1]}`\n"
    }
    text += "\n> 本报告由灵渠迁移台自动生成；口径：平台限制不计入可用率分母，未验证 ≠ 通过。\n"
    return text
}

/** HTML 渲染（自包含单文件，不引外部资源，双击即可看） */
public func renderReportHtml(doc: ReportDoc): String {
    var text = "<!DOCTYPE html>\n<html lang=\"zh-CN\"><head><meta charset=\"utf-8\">\n"
    text += "<title>${escapeHtmlText(doc.title)}</title>\n"
    text += "<style>body{font:14px/1.7 -apple-system,'Segoe UI','Microsoft YaHei',sans-serif;" +
        "max-width:860px;margin:32px auto;padding:0 18px;color:#1d2330}" +
        "h1{font-size:22px}h2{font-size:16px;margin-top:26px;border-left:3px solid #6c8cff;padding-left:9px}" +
        "li{margin:5px 0}code{background:#f3f5fa;padding:1px 5px;border-radius:4px;font-size:12.5px}" +
        ".concl{background:#f6f8fd;border:1px solid #e2e8f5;border-radius:8px;padding:10px 13px}" +
        ".foot{margin-top:22px;color:#6b7488;font-size:12px}</style></head><body>\n"
    text += "<h1>${escapeHtmlText(doc.title)}</h1>\n"
    text += "<p>工程：<code>${escapeHtmlText(doc.path)}</code>"
    if (doc.generatedAt != "") {
        text += "　生成时间：${escapeHtmlText(doc.generatedAt)}"
    }
    text += "</p>\n<p class=\"concl\">${escapeHtmlText(doc.conclusion)}</p>\n"
    for (sec in doc.sections) {
        text += "<h2>${escapeHtmlText(sec.title)}</h2>\n<ul>\n"
        for (line in sec.lines) {
            text += "<li>${escapeHtmlText(line)}</li>\n"
        }
        text += "</ul>\n"
    }
    text += "<h2>附录：产物与落档</h2>\n<ul>\n"
    for (entry in doc.artifacts) {
        text += "<li>${escapeHtmlText(entry[0])}：<code>${escapeHtmlText(entry[1])}</code></li>\n"
    }
    text += "</ul>\n<p class=\"foot\">本报告由灵渠迁移台自动生成；口径：平台限制不计入可用率分母，未验证 ≠ 通过。</p>\n"
    text += "</body></html>\n"
    return text
}

/**
 * 人工介入计数（A3 口径）：`decisions.json` 的 items 里 `accepted` 算一次介入，
 * `ignored` 只留痕（"不需要改"也是人工判断，但它不是一次介入）。
 */
public func countHumanDecisions(decisions: ArrayList<String>): HumanCount {
    let hc = HumanCount()
    for (d in decisions) {
        let v = d.trimAscii()
        if (v == "accepted") {
            hc.accepted += 1
        } else if (v == "ignored") {
            hc.ignored += 1
        }
    }
    return hc
}

/** 报告文件名 base（三种格式共用同一个 base，导出目录里一眼能对上） */
public func reportFileBase(project: String): String {
    if (project.size == 0) {
        return "unknown"
    }
    return project
}
