package lingqu.tests

import lingqu.report.*
import std.collection.*

/*
 * 风险分级（0.39.47）的纯函数单测。
 *
 * 需求原文（`docs/需求.md`）："输出结构化迁移报告，**支持风险分级**与断点续迁"。
 * 守的口径：
 *   ① 「迁移成功」不等于「没有风险」——可用率 100% + debug 签名仍然判「中」；
 *   ② 落档缺就写「无法评估」，**不许**把「没报风险」当成「没问题」；
 *   ③ 级别只由事实推：失败 / 装不上 = 高，未验证 / 平台限制 / 没跑 = 中，可复核项 = 低；
 *   ④ 报告 MD 与 HTML 必须真的渲染出这张表，且外部内容要转义（报告本身就是 HTML 文件）。
 */

/** 造一份"8 步全 done、可用率 100%、debug 签名"的事实（habit-tree 的真实形状） */
func riskFactsGreen(): MigrationFacts {
    let f = MigrationFacts()
    f.project = "habit-tree"
    f.path = "E:\\test\\rust\\habit-tree"
    let ids = ["scan", "deps", "port", "build", "hap", "sign", "deploy", "verify"]
    let titles = ["扫描分析", "依赖评估", "规则改造", "交叉编译", "HAP 装配", "签名体检", "真机部署", "真机验证"]
    for (i in 0..ids.size) {
        f.stepIds.add(ids[i])
        f.stepTitles.add(titles[i])
        f.stepStatuses.add("done")
        f.stepNotes.add("")
    }
    f.stepDone = 8
    f.stepTotal = 8
    f.stepPercent = 100
    f.verifyTotal = 6
    f.verifyPass = 5
    f.verifyLimit = 1
    f.verifyUnknown = 0
    f.verifyRate = 100
    f.limitItems.add("平台相关 API（4 处）按平台限制登记")
    f.buildRan = true
    f.buildOk = true
    f.buildExit = 0
    f.hapRan = true
    f.hapBuilt = true
    f.hapSigned = true
    f.deployRan = true
    f.deployInstalled = true
    f.deployStarted = true
    f.deployHilogHealthy = true
    f.signMode = "debug"
    f.signReleaseReady = false
    return f
}

/** 把清单拼成一段可断言文本（标题 + 处置都要能查到） */
func riskText(risk: ReportRisk): String {
    var text = ""
    for (it in risk.items) {
        text += it.title + "｜" + it.level + "｜" + it.impact + "｜" + it.action + "\n"
    }
    return text
}

@Test
public func testRiskEmptyFactsSaysUnassessable(): Unit {
    // 什么都没跑：不许说"没问题"，要说"无法评估"
    let risk = assessRisks(MigrationFacts())
    @Assert(risk.items.size, 0)
    @Assert(risk.overallLevel(), RISK_LOW)
    let line = riskSummaryLine(risk)
    @Assert(line.contains("无法评估"), true)
    @Assert(line.contains("别把"), true)
}

@Test
public func testRiskGreenButDebugSignIsMid(): Unit {
    // 这是本轮最要紧的一条口径：移植成功（100%）但 debug 签名 + 平台限制 ⇒ 总体「中」
    let risk = assessRisks(riskFactsGreen())
    @Assert(risk.overallLevel(), RISK_MID)
    @Assert(risk.countOf(RISK_HIGH), 0)
    @Assert(risk.countOf(RISK_MID) >= 2, true)
    let text = riskText(risk)
    @Assert(text.contains("签名是 debug 态"), true)
    @Assert(text.contains("平台限制"), true)
    // 每条都必须给出处置（报告里"处置"列不许空着）
    for (it in risk.items) {
        @Assert(it.action.size > 0, true)
    }
    @Assert(riskSummaryLine(risk).contains("总体：中"), true)
}

@Test
public func testRiskReleaseSignDropsDebugItem(): Unit {
    let f = riskFactsGreen()
    f.signMode = "release"
    f.signReleaseReady = true
    let risk = assessRisks(f)
    @Assert(riskText(risk).contains("签名是 debug 态"), false)
    // release 态下仍有一项平台限制 → 还是「中」，但条数变少
    @Assert(risk.overallLevel(), RISK_MID)
    @Assert(risk.countOf(RISK_MID), 1)
}

@Test
public func testRiskFailedChecklistIsHigh(): Unit {
    let f = riskFactsGreen()
    f.verifyFail = 1
    f.failedItems.add("配置列表加载")
    f.failedItems.add("搜索")
    let risk = assessRisks(f)
    @Assert(risk.overallLevel(), RISK_HIGH)
    @Assert(risk.countOf(RISK_HIGH), 1)
    let text = riskText(risk)
    @Assert(text.contains("2 项核心功能验证失败"), true)
    @Assert(text.contains("配置列表加载"), true)
    @Assert(riskSummaryLine(risk).contains("总体：高"), true)
}

@Test
public func testRiskAssetDriftIsHigh(): Unit {
    let f = riskFactsGreen()
    f.assetStale = 1
    f.assetMissing = 2
    let risk = assessRisks(f)
    @Assert(risk.overallLevel(), RISK_HIGH)
    let text = riskText(risk)
    @Assert(text.contains("前端资源与 .so 不同步"), true)
    @Assert(text.contains("stale=1"), true)
    @Assert(text.contains("missing=2"), true)
    @Assert(text.contains("重编 .so"), true)
}

@Test
public func testRiskHapUnsignedOrMissing(): Unit {
    let f = riskFactsGreen()
    f.hapSigned = false
    let unsignedRisk = assessRisks(f)
    @Assert(unsignedRisk.overallLevel(), RISK_HIGH)
    @Assert(riskText(unsignedRisk).contains("HAP 没有签名"), true)

    // 装配都没出来时只报"没装配"，不该再叠一条"没签名"（同因重复会让人以为有两个问题）
    f.hapBuilt = false
    let missingRisk = assessRisks(f)
    let text = riskText(missingRisk)
    @Assert(text.contains("HAP 没装配出来"), true)
    @Assert(text.contains("HAP 没有签名"), false)
}

@Test
public func testRiskPendingAndUnarchivedFailedSteps(): Unit {
    // 没有专属落档判定的步骤（这里 port 没过、build 没跑）要靠步骤级兜底报出来
    let f = MigrationFacts()
    f.project = "demo"
    f.stepIds.add("scan")
    f.stepTitles.add("扫描分析")
    f.stepStatuses.add("done")
    f.stepNotes.add("R=24")
    f.stepIds.add("port")
    f.stepTitles.add("规则改造")
    f.stepStatuses.add("failed")
    f.stepNotes.add("apply 失败")
    f.stepIds.add("build")
    f.stepTitles.add("交叉编译")
    f.stepStatuses.add("pending")
    f.stepNotes.add("")
    let risk = assessRisks(f)
    let text = riskText(risk)
    @Assert(text.contains("1 步没过"), true)
    @Assert(text.contains("规则改造"), true)
    @Assert(text.contains("还有 1 步没跑"), true)
    @Assert(text.contains("交叉编译"), true)
    @Assert(risk.overallLevel(), RISK_HIGH)
}

@Test
public func testRiskAppearsInMarkdownAndHtml(): Unit {
    let f = riskFactsGreen()
    f.verifyFail = 1
    f.failedItems.add("<script>alert(1)</script>")
    f.limitItems.add("竖线|要转义")
    let doc = buildReport(f)
    @Assert(doc.risk.items.size > 0, true)

    let md = renderReportMarkdown(doc)
    @Assert(md.contains("## 风险分级"), true)
    @Assert(md.contains("| 项 | 级别 | 影响面 | 处置 |"), true)
    @Assert(md.contains("总体："), true)
    // 竖线会把表格撑坏：**表格行里**的 `|` 必须换成全角。
    // （同一个清单项也出现在三段的列表里，列表里的原样竖线无害，所以不能整篇断言"不含竖线"）
    @Assert(md.contains("竖线／要转义"), true)
    var rowPipes: Int64 = 0
    for (line in md.split("\n")) {
        if (line.startsWith("| ") && line.contains("竖线")) {
            for (b in line.toArray()) {
                if (b == 124) {
                    rowPipes += 1
                }
            }
        }
    }
    // 四列 + 两侧 = 5 个竖线；多了说明单元里的竖线没被替换（表格会被撑坏）
    @Assert(rowPipes, 5)

    let html = renderReportHtml(doc)
    @Assert(html.contains("<h2>风险分级</h2>"), true)
    @Assert(html.contains("class=\"lv lv-high\""), true)
    // 报告是 HTML 文件，外部内容照抄进 <td> 就是 XSS
    @Assert(html.contains("<script>alert(1)</script>"), false)
    @Assert(html.contains("&lt;script&gt;"), true)
}

@Test
public func testRiskLevelLabelsAndPrecedence(): Unit {
    @Assert(riskLevelLabel(RISK_HIGH), "高")
    @Assert(riskLevelLabel(RISK_MID), "中")
    @Assert(riskLevelLabel(RISK_LOW), "低")
    // 不认识的级别兜底成「低」，不抛（界面上宁可显示低，也不能空着）
    @Assert(riskLevelLabel("nope"), "低")

    let risk = ReportRisk()
    @Assert(risk.overallLevel(), RISK_LOW)
    risk.add(RiskItem("a", RISK_LOW, "", ""))
    @Assert(risk.overallLevel(), RISK_LOW)
    risk.add(RiskItem("b", RISK_MID, "", ""))
    @Assert(risk.overallLevel(), RISK_MID)
    risk.add(RiskItem("c", RISK_HIGH, "", ""))
    @Assert(risk.overallLevel(), RISK_HIGH)
    @Assert(risk.countOf(RISK_LOW), 1)
    @Assert(risk.countOf(RISK_MID), 1)
    @Assert(risk.countOf(RISK_HIGH), 1)
    // 总体级别是"推出来"的：明细变了就跟着变，不存第二份
    @Assert(riskSummaryLine(risk).contains("共 3 条"), true)
}
