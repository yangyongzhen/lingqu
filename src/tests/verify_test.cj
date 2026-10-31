package lingqu.tests

import std.collection.*
import lingqu.verify.*

/*
 * P6 验证层的单测（纯函数，D-009）。
 *
 * 这里钉的是**口径**，不是文案：
 *   · 平台限制不计入分母；
 *   · 未采集 ≠ 通过（unknown 计入分母）；
 *   · 报告三段式必须把"没做什么 / 需要你做什么"逐条列出来，不能只给一个总数。
 */

/** 全绿的输入：装上了、起来了、日志干净、有截图、编译与装配都过 */
func greenInput(): ChecklistInput {
    let i = ChecklistInput()
    i.commandCount = 12
    i.eventCount = 2
    i.pluginCount = 3
    i.frontendCount = 7
    i.platformCount = 5
    i.buildOk = true
    i.assetOk = true
    i.hapOk = true
    i.installed = true
    i.started = true
    i.hilogHealthy = true
    i.screenshotCount = 1
    i.crashCount = 0
    return i
}

@Test
public func testChecklistGreenPathAllPassOrLimit(): Unit {
    let items = buildChecklist(greenInput())
    // 有命令/事件/插件/前端/平台 API 的都要出条目，再加 launch/build/hap 三条基础
    @Assert(items.size, 8)
    var pass = 0
    var limit = 0
    for (it in items) {
        if (it.verdict == "pass") {
            pass += 1
        }
        if (it.verdict == "limit") {
            limit += 1
        }
        // 全绿输入里不该出现失败
        @Assert(it.verdict != "fail", true)
    }
    // 事件那条是 unknown（没逐条触发），所以 pass 不会等于总数
    @Assert(pass >= 6, true)
    @Assert(limit, 1)   // 平台 API 一条，登记为限制
}

@Test
public func testStatsExcludeLimitsFromDenominator(): Unit {
    let items = buildChecklist(greenInput())
    let s = computeStats(items)
    @Assert(s.total, 8)
    @Assert(s.limit, 1)
    // 分母 = total - limit，可用率 = pass / 分母
    let denom = s.total - s.limit
    @Assert(s.ratePercent, (s.pass * 100) / denom)
    // 全部通过时（把 unknown 那条改成 pass 验证口径）：分母仍排除 limit
    let items2 = ArrayList<CheckItem>()
    let a = CheckItem("a", "A")
    a.verdict = "pass"
    let b = CheckItem("b", "B")
    b.verdict = "limit"
    items2.add(a)
    items2.add(b)
    let s2 = computeStats(items2)
    @Assert(s2.ratePercent, 100)
    // 只有限制项（分母 0）时按 0 处理，不能除零
    let items3 = ArrayList<CheckItem>()
    let c = CheckItem("c", "C")
    c.verdict = "limit"
    items3.add(c)
    @Assert(computeStats(items3).ratePercent, 0)
}

@Test
public func testUnknownIsNotPass(): Unit {
    // 只装上了、没启动、没截图：launch 判定失败，其余多为未验证
    let i = ChecklistInput()
    i.commandCount = 3
    i.installed = true
    let items = buildChecklist(i)
    let s = computeStats(items)
    @Assert(s.pass, 0)
    @Assert(s.fail >= 1, true)
    // 可用率必须是 0，而不是"没数据就给 100"
    @Assert(s.ratePercent, 0)
}

@Test
public func testChecklistShrinksWithScan(): Unit {
    // 没扫过（各项 0）时，只有 launch/build/hap 三条基础项，不该凭空造条目
    let empty = ChecklistInput()
    let items = buildChecklist(empty)
    @Assert(items.size, 3)
    for (it in items) {
        @Assert(it.id == "launch" || it.id == "build" || it.id == "hap", true)
    }
}

@Test
public func testMarkdownReportHasThreeSections(): Unit {
    let i = greenInput()
    i.started = false      // 造一个失败项，验证"需要你做什么"有内容
    let items = buildChecklist(i)
    let stats = computeStats(items)
    let ctx = ReportContext("habit-tree")
    ctx.bundleName = "com.jiujiang.habit_tree"
    ctx.deviceSerial = "3QC0124B20000048"
    ctx.version = "0.22.0"
    let md = renderMarkdown(ctx, items, stats)
    @Assert(md.contains("# 迁移验证报告 · habit-tree"), true)
    @Assert(md.contains("## 一、做了什么"), true)
    @Assert(md.contains("## 二、没做什么"), true)
    @Assert(md.contains("## 三、需要你做什么"), true)
    @Assert(md.contains("com.jiujiang.habit_tree"), true)
    @Assert(md.contains("平台限制"), true)
    // 失败项要落在"需要你做什么"里
    @Assert(md.contains("修 应用启动无 panic"), true)
}

@Test
public func testHtmlReportEscapesAndHasTable(): Unit {
    let items = ArrayList<CheckItem>()
    let it = CheckItem("x", "带 <script> 的标题 & 引号\"")
    it.verdict = "pass"
    it.evidence.add("证据 <b>1</b>")
    items.add(it)
    let stats = computeStats(items)
    let html = renderHtml(ReportContext("p"), items, stats)
    @Assert(html.startsWith("<!doctype html>"), true)
    @Assert(html.contains("<table>"), true)
    // 转义：正文里的尖括号不能变成标签
    @Assert(html.contains("&lt;script&gt;"), true)
    @Assert(html.contains("<script>"), false)
    @Assert(html.contains("&amp; 引号&quot;"), true)
    @Assert(html.contains("class=\"pass\""), true)
}

@Test
public func testVerdictLabels(): Unit {
    @Assert(verdictLabel("pass"), "通过")
    @Assert(verdictLabel("fail"), "失败")
    @Assert(verdictLabel("limit"), "平台限制")
    @Assert(verdictLabel("unknown"), "未验证")
    @Assert(verdictLabel("whatever"), "未验证")
}
