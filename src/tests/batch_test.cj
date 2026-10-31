package lingqu.tests

import lingqu.batch.*
import std.collection.*

/*
 * T7-3 5 样本矩阵的纯函数单测。
 *
 * 守的三条口径（矩阵说错话比没有矩阵更糟）：
 *   ① **未跑 ≠ 0 分**：没有落档的样本显示「未跑」，且不参与任何平均；
 *   ② A4 判定必须有样本支撑：0 个已验证样本时判"未验证"，绝不判达标；
 *   ③ 平均可用率只在**有 verify 落档**的样本上求平均，并把分母如实报出来。
 */

/** 造一行"跑通了全流程"的样本 */
func fullRow(name: String, rate: Int64): BatchRow {
    let r = BatchRow()
    r.project = name
    r.hasScan = true
    r.scanScore = 70
    r.scanUnits = 24
    r.scanUnknown = 0
    r.hasDeps = true
    r.depsTotal = 430
    r.depsUnavailable = 10
    r.hasBuild = true
    r.buildOk = true
    r.hasHap = true
    r.hapOk = true
    r.signMode = "debug"
    r.hasDeploy = true
    r.deployOk = true
    r.hasVerify = true
    r.verifyRate = rate
    r.verifyPass = 3
    r.verifyTotal = 6
    r.verifyLimit = 1
    r.stepDone = 8
    r.stepTotal = 8
    r.humanAccepted = 1
    return r
}

/** 造一行"什么都没跑"的样本 */
func emptyRow(name: String): BatchRow {
    let r = BatchRow()
    r.project = name
    r.stepTotal = 8
    return r
}

@Test
public func testBatchVerdictThresholds(): Unit {
    // 刚过线（80）算达标；79 不算——A4 是"≥80%"
    @Assert(batchVerdict(fullRow("a", 80)), "达标")
    @Assert(batchVerdict(fullRow("b", 79)), "未达标")
    @Assert(batchVerdict(fullRow("c", 100)), "达标")
    @Assert(batchVerdict(fullRow("d", 0)), "未达标")
    // 没有 verify 落档 → 未验证（不是未达标，更不是达标）
    @Assert(batchVerdict(emptyRow("e")), "未验证")
    let half = fullRow("f", 60)
    half.hasVerify = false
    @Assert(batchVerdict(half), "未验证")
}

@Test
public func testBatchCompletion(): Unit {
    let r = fullRow("a", 90)
    @Assert(batchCompletion(r), 100)
    r.stepDone = 4
    @Assert(batchCompletion(r), 50)
    // stepTotal=0（没有断点板）按 0，不除零
    let e = BatchRow()
    @Assert(batchCompletion(e), 0)
}

@Test
public func testSummaryOnlyAveragesVerified(): Unit {
    let rows = ArrayList<BatchRow>()
    rows.add(fullRow("habit-tree", 60))
    rows.add(fullRow("cc-switch", 100))
    rows.add(emptyRow("m3u8dl"))     // 没跑过的样本
    let m = buildMatrix(rows, "2026-11-01 12:00:00")
    let s = summarize(m)

    @Assert(s.samples, 3)
    // 只有两行有 verify 落档：分母是 2，不是 3
    @Assert(s.verified, 2)
    @Assert(s.avgRate, 80)
    // 空行没扫描落档 → 不参与评分平均（70 的平均仍是 70）
    @Assert(s.avgScore, 70)
    // A3：两行各 1 处
    @Assert(s.totalHuman, 2)
    @Assert(s.avgHumanTenths, 6)     // 2*10/3 = 6（即 0.6 处/应用）
    // A4：80 ≥ 80 且已验证样本 > 0 → 达标
    @Assert(s.a4Pass, true)
    // A1：样本数 3 < 5，且没全验证 → 未达成
    @Assert(s.a1Pass, false)

    // 没有任何已验证样本时：平均可用率是 -1（不是 0！）且 A4 不达标
    let empty = ArrayList<BatchRow>()
    empty.add(emptyRow("x"))
    let s2 = summarize(buildMatrix(empty, "t"))
    @Assert(s2.verified, 0)
    @Assert(s2.avgRate, -1)
    @Assert(s2.avgScore, -1)
    @Assert(s2.a4Pass, false)

    // 5 个样本全部验证过 → A1 达成
    let five = ArrayList<BatchRow>()
    for (i in 0..5) {
        five.add(fullRow("s${i}", 85))
    }
    let s3 = summarize(buildMatrix(five, "t"))
    @Assert(s3.samples, 5)
    @Assert(s3.verified, 5)
    @Assert(s3.a1Pass, true)
    @Assert(s3.a4Pass, true)
}

@Test
public func testRowCellsShowNotRunHonestly(): Unit {
    let empty = emptyRow("m3u8dl")
    let cells = batchRowCells(empty)
    @Assert(cells.size, 12)
    // 表头与单元格必须一一对应（多一列少一列都会让 Markdown 表格错位）
    @Assert(cells.size, batchHeaders().size)
    @Assert(cells[0], "m3u8dl")
    // 没跑的列写「未跑」，而不是 0、空、或「未过」——**"没跑"和"跑了没过"必须分开**
    @Assert(cells[1], "未跑")
    @Assert(cells[2], "未跑")
    @Assert(cells[3], "未跑")
    @Assert(cells[4], "未跑")
    @Assert(cells[5], "未跑")
    @Assert(cells[6], "未跑")
    @Assert(cells[7], "未跑")
    @Assert(cells[8], "未跑")
    // 判定列
    @Assert(cells[11], "未验证")

    let full = fullRow("habit-tree", 60)
    let c2 = batchRowCells(full)
    @Assert(c2[1], "70")
    @Assert(c2[2], "24 / 未知 0")
    @Assert(c2[3], "430 包 / 不可用 10")
    @Assert(c2[4], "通过")
    @Assert(c2[6], "debug")
    @Assert(c2[8], "60%（3/5）")     // 分母 = 6 − 1（平台限制已剔除）
    @Assert(c2[9], "8/8（100%）")
    @Assert(c2[11], "未达标")
}

@Test
public func testMatrixRendering(): Unit {
    let rows = ArrayList<BatchRow>()
    rows.add(fullRow("habit-tree", 60))
    rows.add(emptyRow("<script>x"))
    let m = buildMatrix(rows, "2026-11-01 12:00:00")

    let md = renderMatrixMarkdown(m)
    @Assert(md.contains("5 样本迁移矩阵"), true)
    @Assert(md.contains("habit-tree"), true)
    @Assert(md.contains("未跑"), true)
    @Assert(md.contains("已验证 1 个"), true)
    // 表头 12 列 → Markdown 分隔行里有 12 个 `---`（列数不对会让整张表错位）
    var barCount: Int64 = 0
    for (line in md.split("\n")) {
        if (line.startsWith("| --- |")) {
            for (seg in line.split("|")) {
                if (seg.trimAscii() == "---") {
                    barCount += 1
                }
            }
        }
    }
    @Assert(barCount, 12)

    let html = renderMatrixHtml(m)
    @Assert(html.contains("<!DOCTYPE html>"), true)
    @Assert(html.contains("5 样本迁移矩阵"), true)
    // 样本名里的尖括号必须转义（工程名来自用户路径，不能当标签）
    @Assert(html.contains("<script>x"), false)
    @Assert(html.contains("&lt;script&gt;x"), true)
    // 中文原样保留（别按字节拼坏 UTF-8）
    @Assert(html.contains("判定"), true)
}

@Test
public func testSummaryLineMentionsDenominator(): Unit {
    let rows = ArrayList<BatchRow>()
    rows.add(fullRow("a", 60))
    rows.add(emptyRow("b"))
    let line = summaryLine(buildMatrix(rows, "t"))
    // 必须写"样本 N 个（已验证 M 个）"——不写分母就等于虚报
    @Assert(line.contains("样本 2 个"), true)
    @Assert(line.contains("已验证 1 个"), true)
    @Assert(line.contains("60%"), true)
    @Assert(line.contains("人工介入"), true)
}
