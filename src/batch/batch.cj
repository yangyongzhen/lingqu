package lingqu.batch

import std.collection.*

/*
 * T7-3 批量矩阵的纯函数层（收数在 `src/batch_feed.cj`，命令本体在 `main.cj` 的 `BatchCommand`）。
 *
 * 5 个样本并排看的意义：单个工程的报告能说明"这个迁得怎样"，**并排才能说明"工具本身怎样"**
 * ——评分分布、自动修复命中、人工介入次数、可用率是否稳定在 A4 线（≥80%）之上。
 *
 * 三条口径（别改薄）：
 *   ① **未跑 ≠ 0 分**：没有落档的样本在矩阵里显示"未跑"，而不是拿 0 参与平均
 *      （否则"还没跑"会被算成"做得差"，反过来也会被算成"分母"把平均拉低）；
 *   ② 平均可用率只对**有 verify 落档的样本**求平均，并在表里写出分母（`已验证 1/5`）；
 *   ③ A4 判定必须**有样本**支撑：0 个已验证样本时判 `未验证`，绝不判"达标"。
 */

/** 一个样本的一行矩阵（全部来自它自己的 `.lingqu` 落档） */
public class BatchRow {
    public var project: String = ""
    public var path: String = ""
    // ② 扫描画像
    public var hasScan: Bool = false
    public var scanScore: Int64 = -1     // -1 = 没有落档
    public var scanUnits: Int64 = 0      // metrics.R（迁移单元数）
    public var scanUnknown: Int64 = 0    // metrics.U（未知项，必须清零的那种）
    // ③ 依赖矩阵
    public var hasDeps: Bool = false
    public var depsTotal: Int64 = 0
    public var depsUnavailable: Int64 = 0
    // ⑤ 构建链（每段都要区分"没跑"与"跑了没过"——把没跑画成「未过」是另一种撒谎）
    public var hasBuild: Bool = false
    public var buildOk: Bool = false
    public var hasHap: Bool = false
    public var hapOk: Bool = false
    public var signMode: String = ""
    public var releaseReady: Bool = false
    // ⑥ 真机
    public var hasDeploy: Bool = false
    public var deployOk: Bool = false
    public var hasVerify: Bool = false
    public var verifyRate: Int64 = -1
    public var verifyPass: Int64 = 0
    public var verifyTotal: Int64 = 0
    public var verifyLimit: Int64 = 0
    /** 有结论的项数 = 可用率分母（0.39.89）；老落档为 -1（回落 total−limit，并在文案里说明） */
    public var verifyCovered: Int64 = -1
    /** 未测项数（不进分母，但矩阵要写出来） */
    public var verifyNotVerified: Int64 = -1
    // 进度与 A3
    public var stepDone: Int64 = 0
    public var stepTotal: Int64 = 0
    public var humanAccepted: Int64 = 0
}

/** 矩阵 + 生成时间（落 `.lingqu/batch/matrix.json`） */
public class BatchMatrix {
    public var generatedAt: String = ""
    public var rows: ArrayList<BatchRow> = ArrayList<BatchRow>()

    public init() {}

    public func rowOf(project: String): Option<BatchRow> {
        for (r in this.rows) {
            if (r.project == project) {
                return Some(r)
            }
        }
        return None
    }
}

/** 汇总（A1/A3/A4 三个验收指标在矩阵层的读数） */
public class BatchSummary {
    /** 样本总数（= A1 的分母：课题要求 5 个） */
    public var samples: Int64 = 0
    /** 有 verify 落档（= 真机验过）的样本数 */
    public var verified: Int64 = 0
    /** 已验证样本的平均可用率；`verified=0` 时 -1（不是 0，别让人误读成"可用率 0%"） */
    public var avgRate: Int64 = -1
    /** 有扫描落档的样本的平均评分；0 个 → -1 */
    public var avgScore: Int64 = -1
    /** A3：人工介入总数（跨样本求和，验收看"单应用平均 ≤5 处"） */
    public var totalHuman: Int64 = 0
    /** A3 的单应用平均值（×10 存整数，避免浮点；-1 = 没有样本） */
    public var avgHumanTenths: Int64 = -1
    /** A4：平均可用率 ≥80 且至少一个已验证样本 */
    public var a4Pass: Bool = false
    /** A1：5 个样本是否都已跑出验证结论 */
    public var a1Pass: Bool = false
}

/** 单行判定：达标（≥80）/ 未达标 / 未验证 */
public func batchVerdict(row: BatchRow): String {
    if (!row.hasVerify || row.verifyRate < 0) {
        return "未验证"
    }
    if (row.verifyRate >= 80) {
        return "达标"
    }
    return "未达标"
}

/** 8 步完成度（0–100；stepTotal=0 时按 0，不除零） */
public func batchCompletion(row: BatchRow): Int64 {
    if (row.stepTotal <= 0) {
        return 0
    }
    return row.stepDone * 100 / row.stepTotal
}

/**
 * 汇总：**只对已验证样本求平均可用率**，并把分母写进 summary（`verified`），
 * 报告里据此说"已验证 N/M"，而不是拿未跑的样本凑数。
 */
public func summarize(batch: BatchMatrix): BatchSummary {
    let s = BatchSummary()
    var rateSum: Int64 = 0
    var scoreSum: Int64 = 0
    var scoreCount: Int64 = 0
    for (r in batch.rows) {
        s.samples += 1
        if (r.hasVerify && r.verifyRate >= 0) {
            s.verified += 1
            rateSum += r.verifyRate
        }
        if (r.hasScan && r.scanScore >= 0) {
            scoreSum += r.scanScore
            scoreCount += 1
        }
        s.totalHuman += r.humanAccepted
    }
    if (s.verified > 0) {
        s.avgRate = rateSum / s.verified
    }
    if (scoreCount > 0) {
        s.avgScore = scoreSum / scoreCount
    }
    if (s.samples > 0) {
        s.avgHumanTenths = s.totalHuman * 10 / s.samples
    }
    // A4 必须有样本支撑：0 个已验证样本时不算达标（"没验"不是"通过"）
    s.a4Pass = s.verified > 0 && s.avgRate >= 80
    // A1：5 个样本且全部有验证结论
    s.a1Pass = s.samples >= 5 && s.verified == s.samples
    return s
}

/** 构造矩阵（纯）：按给定顺序保留样本，未跑字段一律保持"没有落档"的初值 */
public func buildMatrix(rows: ArrayList<BatchRow>, now: String): BatchMatrix {
    let m = BatchMatrix()
    m.generatedAt = now
    for (r in rows) {
        m.rows.add(r)
    }
    return m
}

/** 单元格文本：没有落档时必须显示"未跑"（不是 0、也不是空） */
func cellOf(has: Bool, value: String): String {
    if (!has) {
        return "未跑"
    }
    return value
}

/** 一行的表格单元格（Markdown 与 HTML 共用同一份取值口径） */
public func batchRowCells(row: BatchRow): ArrayList<String> {
    let out = ArrayList<String>()
    out.add(row.project)
    out.add(cellOf(row.hasScan, "${row.scanScore}"))
    out.add(cellOf(row.hasScan, "${row.scanUnits} / 未知 ${row.scanUnknown}"))
    out.add(cellOf(row.hasDeps, "${row.depsTotal} 包 / 不可用 ${row.depsUnavailable}"))
    out.add(if (row.hasBuild) { if (row.buildOk) { "通过" } else { "未过" } } else { "未跑" })
    out.add(if (row.hasHap) { if (row.hapOk) { "通过" } else { "未过" } } else { "未跑" })
    out.add(if (row.signMode == "") { "未跑" } else { row.signMode })
    out.add(if (row.hasDeploy) { if (row.deployOk) { "成功" } else { "未过" } } else { "未跑" })
    // 分母 = 有结论的项（0.39.89）；老落档没这个字段 → 回落 total−limit，
    // 只在**新落档**（有未测计数）时才补「未测 N」，旧档的显示保持原样。
    let covered = if (row.verifyCovered > 0) { row.verifyCovered } else { row.verifyTotal - row.verifyLimit }
    let denomTail = if (row.verifyNotVerified >= 0) { " 未测 ${row.verifyNotVerified}" } else { "" }
    out.add(cellOf(row.hasVerify, "${row.verifyRate}%（${row.verifyPass}/${covered}${denomTail}）"))
    out.add("${row.stepDone}/${row.stepTotal}（${batchCompletion(row)}%）")
    out.add("${row.humanAccepted}")
    out.add(batchVerdict(row))
    return out
}

/** 表头（顺序与 `batchRowCells` 一一对应，改一处必须改另一处） */
public func batchHeaders(): ArrayList<String> {
    let out = ArrayList<String>()
    out.add("样本")
    out.add("评分")
    out.add("单元 / 未知")
    out.add("依赖")
    out.add("编译")
    out.add("装配")
    out.add("签名态")
    out.add("部署")
    out.add("可用率（通过/分母）")
    out.add("8 步")
    out.add("人工介入")
    out.add("判定")
    return out
}

/** 汇总一句话（报告与界面都引用它，避免各写一套说法） */
public func summaryLine(batch: BatchMatrix): String {
    let s = summarize(batch)
    let rateText = if (s.avgRate >= 0) { "${s.avgRate}%" } else { "尚未验证" }
    let scoreText = if (s.avgScore >= 0) { "${s.avgScore}" } else { "—" }
    let humanText = if (s.avgHumanTenths >= 0) {
        "${s.totalHuman} 处（均 ${s.avgHumanTenths / 10}.${s.avgHumanTenths % 10} 处/应用）"
    } else {
        "—"
    }
    return "样本 ${s.samples} 个（已验证 ${s.verified} 个）｜平均评分 ${scoreText}｜" +
        "平均可用率 ${rateText}｜人工介入 ${humanText}"
}

/** Markdown 矩阵（给报告/命令行看） */
public func renderMatrixMarkdown(batch: BatchMatrix): String {
    let headers = batchHeaders()
    var text = "# 5 样本迁移矩阵\n\n"
    text += "- 生成时间：${batch.generatedAt}\n"
    text += "- 汇总：${summaryLine(batch)}\n\n"
    // 表头
    text += "|"
    for (h in headers) {
        text += " ${h} |"
    }
    text += "\n|"
    for (h in headers) {
        text += " --- |"
    }
    text += "\n"
    for (r in batch.rows) {
        let cells = batchRowCells(r)
        text += "|"
        for (c in cells) {
            text += " ${c} |"
        }
        text += "\n"
    }
    text += "\n> 口径：没有落档的样本显示「未跑」，不参与平均（未验证 ≠ 0 分，也 ≠ 通过）；" +
        "可用率 = 通过 ÷ 有结论的核心功能项（未测项不进分母，矩阵里单列「未测 N」）。\n"
    return text
}

/** 字符级 HTML 转义（与 report 模块同一策略：只换 5 个危险 ASCII，中文原样保留） */
func escHtml(s: String): String {
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

func appendAscii(out: ArrayList<Byte>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

/** HTML 矩阵（自包含单文件，界面里也能直接打开） */
public func renderMatrixHtml(batch: BatchMatrix): String {
    let headers = batchHeaders()
    var text = "<!DOCTYPE html>\n<html lang=\"zh-CN\"><head><meta charset=\"utf-8\">\n"
    text += "<title>5 样本迁移矩阵</title>\n"
    text += "<style>body{font:13px/1.6 -apple-system,'Segoe UI','Microsoft YaHei',sans-serif;" +
        "margin:26px auto;padding:0 16px;max-width:1180px;color:#1d2330}" +
        "h1{font-size:20px}table{border-collapse:collapse;width:100%;margin-top:14px}" +
        "th,td{border:1px solid #e2e8f5;padding:6px 8px;text-align:left;white-space:nowrap}" +
        "th{background:#f6f8fd;font-weight:600}tr:nth-child(even) td{background:#fafbff}" +
        ".sum{background:#f6f8fd;border:1px solid #e2e8f5;border-radius:8px;padding:9px 12px}" +
        ".foot{margin-top:16px;color:#6b7488;font-size:12px}</style></head><body>\n"
    text += "<h1>5 样本迁移矩阵</h1>\n"
    text += "<p class=\"sum\">${escHtml(summaryLine(batch))}</p>\n"
    text += "<table><thead><tr>"
    for (h in headers) {
        text += "<th>${escHtml(h)}</th>"
    }
    text += "</tr></thead><tbody>\n"
    for (r in batch.rows) {
        text += "<tr>"
        for (c in batchRowCells(r)) {
            text += "<td>${escHtml(c)}</td>"
        }
        text += "</tr>\n"
    }
    text += "</tbody></table>\n"
    text += "<p class=\"foot\">生成时间：${escHtml(batch.generatedAt)}。口径：没有落档的样本显示「未跑」，" +
        "不参与平均（未验证 ≠ 0 分，也 ≠ 通过）；可用率 = 通过 ÷ 有结论的核心功能项" +
        "（未测项不进分母，矩阵里单列「未测 N」）。</p>\n"
    text += "</body></html>\n"
    return text
}
