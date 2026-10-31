package lingqu.tests

import lingqu.report.*
import std.collection.*

/*
 * T6-4 迁移报告的纯函数单测。
 *
 * 守的口径：
 *   ① 三段必须**从落档事实推导**——没跑的写"还没跑"，没过的写"没过"，不能糊成一句"未完成"；
 *   ② 平台限制（limit）与失败（fail）**分列**：混在一起会让人以为鸿蒙缺能力是工具的错；
 *   ③ 未验证（unknown）不是通过：它出现在"没做"与"需要你做"两段；
 *   ④ 数字来自事实，事实为 0 时报告就写 0（不许编）。
 */

/** 造一份"8 步全 done"的事实，供多个用例复用 */
func satisfiedFacts(): MigrationFacts {
    let f = MigrationFacts()
    f.project = "habit-tree"
    f.path = "E:\\test\\rust\\habit-tree"
    f.generatedAt = "2026-11-01 12:00:00"
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
    f.evidenceCount = 3
    f.artifacts.add(("验证清单", ".lingqu/verify/habit-tree.json"))
    return f
}

@Test
public func testReportSectionsGreenPath(): Unit {
    let doc = buildReport(satisfiedFacts())
    @Assert(doc.sections.size, 3)
    // 三段顺序固定：做了什么 → 没做什么 → 需要你做什么
    @Assert(doc.sections[0].key, "did")
    @Assert(doc.sections[1].key, "undone")
    @Assert(doc.sections[2].key, "need")
    // 八个步骤的标题都要出现在"做了什么"里
    let did = doc.linesOf("did")
    @Assert(did.size >= 8, true)
    var text = ""
    for (l in did) {
        text += l
    }
    @Assert(text.contains("扫描分析"), true)
    @Assert(text.contains("真机验证"), true)
    // 证据条数来自事实（3 份），不是编的
    @Assert(text.contains("3 份真机证据"), true)
    // 全部有结论时，"没做"与"需要你做"都该是"没有"而不是空白
    @Assert(doc.linesOf("undone").size, 1)
    @Assert(doc.linesOf("undone")[0].contains("没有已知遗留"), true)
    @Assert(doc.linesOf("need")[0].contains("没有需要你处理"), true)
}

@Test
public func testReportSeparatesLimitFromFailure(): Unit {
    let f = satisfiedFacts()
    f.limitItems.add("平台相关 API（4 处）按平台限制登记")
    f.failedItems.add("配置列表加载 / 搜索 / 排序")
    f.unknownItems.add("交叉编译通过，前端指纹一致")
    f.verifyPass = 3
    f.verifyFail = 1
    f.verifyUnknown = 1
    f.verifyRate = 60
    let doc = buildReport(f)
    let undone = doc.linesOf("undone")
    var text = ""
    for (l in undone) {
        text += l + "\n"
    }
    // 平台限制必须标注"不算失败"，且与真正的失败项分开表述
    @Assert(text.contains("平台限制（不算失败"), true)
    @Assert(text.contains("验证失败：配置列表加载"), true)
    @Assert(text.contains("未验证（没有证据就不算通过）"), true)
    // 需要你做：未验证项要给出补验证动作，失败项要给出处理动作
    let need = doc.linesOf("need")
    var ntext = ""
    for (l in need) {
        ntext += l + "\n"
    }
    @Assert(ntext.contains("补验证"), true)
    @Assert(ntext.contains("处理失败项"), true)
    // 结论里带可用率（60%），不四舍五入成"通过"
    @Assert(doc.conclusion.contains("60%"), true)
}

@Test
public func testReportPendingAndFailedSteps(): Unit {
    let f = MigrationFacts()
    f.project = "habit-tree"
    f.stepIds.add("scan")
    f.stepTitles.add("扫描分析")
    f.stepStatuses.add("done")
    f.stepNotes.add("单元 R=24")
    f.stepIds.add("deps")
    f.stepTitles.add("依赖评估")
    f.stepStatuses.add("failed")
    f.stepNotes.add("exit=1 / 依赖解析失败")
    f.stepIds.add("port")
    f.stepTitles.add("规则改造")
    f.stepStatuses.add("pending")
    f.stepNotes.add("")
    f.stepDone = 1
    f.stepTotal = 3
    f.stepPercent = 33
    let doc = buildReport(f)

    let did = doc.linesOf("did")
    @Assert(did[0].contains("扫描分析"), true)
    @Assert(did[0].contains("R=24"), true)
    // 没跑的步骤写"还没跑"，没过的写"没过"（两种状态不能混成一句）
    let undone = doc.linesOf("undone")
    var utext = ""
    for (l in undone) {
        utext += l + "\n"
    }
    @Assert(utext.contains("依赖评估"), true)
    @Assert(utext.contains("没过"), true)
    @Assert(utext.contains("规则改造"), true)
    @Assert(utext.contains("还没跑"), true)
    // 需要你做：按步骤顺序给出动作（deps 在前、port 在后），失败 → 重跑，没跑 → 去跑
    let need = doc.linesOf("need")
    @Assert(need.size, 2)
    @Assert(need[0].contains("依赖评估"), true)
    @Assert(need[0].contains("依赖扫描"), true)
    @Assert(need[1].contains("规则改造"), true)
    @Assert(need[1].contains("预览改造"), true)
}

@Test
public func testReportConclusionAndHumanCount(): Unit {
    let f = satisfiedFacts()
    f.humanAccepted = 2
    f.humanIgnored = 1
    let doc = buildReport(f)
    @Assert(doc.conclusion.contains("8/8"), true)
    @Assert(doc.conclusion.contains("2 处人工介入"), true)
    // 有人工介入时要在"需要你做"里提示复核（A3 是验收指标）
    let need = doc.linesOf("need")
    var text = ""
    for (l in need) {
        text += l
    }
    @Assert(text.contains("复核 2 处人工介入"), true)

    // A3 计数口径：accepted 才算介入，ignored 只留痕
    let ds = ArrayList<String>()
    ds.add("accepted")
    ds.add("accepted")
    ds.add("ignored")
    ds.add("bogus")
    let hc = countHumanDecisions(ds)
    @Assert(hc.accepted, 2)
    @Assert(hc.ignored, 1)
    // 空表不报错
    let empty = countHumanDecisions(ArrayList<String>())
    @Assert(empty.accepted, 0)
}

@Test
public func testReportRendering(): Unit {
    let doc = buildReport(satisfiedFacts())
    let md = renderReportMarkdown(doc)
    // 三段标题都在，且附录存在（每个数字都能追到落档）
    @Assert(md.contains("## 做了什么"), true)
    @Assert(md.contains("## 没做什么"), true)
    @Assert(md.contains("## 需要你做什么"), true)
    @Assert(md.contains("附录：产物与落档"), true)
    @Assert(md.contains(".lingqu/verify/habit-tree.json"), true)
    @Assert(md.contains("平台限制不计入可用率分母"), true)

    let html = renderReportHtml(doc)
    @Assert(html.contains("<!DOCTYPE html>"), true)
    @Assert(html.contains("做了什么"), true)
    @Assert(html.contains("需要你做什么"), true)

    // 转义：工程内容里的尖括号不能当标签；中文必须原样保留（别按字节拼坏 UTF-8）
    let evil = MigrationFacts()
    evil.project = "<script>alert(1)</script>"
    evil.path = "E:\\工作\\demo"
    let evilDoc = buildReport(evil)
    let evilHtml = renderReportHtml(evilDoc)
    @Assert(evilHtml.contains("<script>alert(1)</script>"), false)
    @Assert(evilHtml.contains("&lt;script&gt;"), true)
    @Assert(evilHtml.contains("E:\\工作\\demo"), true)
    // 单独测转义函数：中文与实体都正确
    @Assert(escapeHtmlText("中文 <b>&\"</b>"), "中文 &lt;b&gt;&amp;&quot;&lt;/b&gt;")
    @Assert(escapeHtmlText(""), "")
}

@Test
public func testReportCarriesSignReleaseReminder(): Unit {
    // T5-4：debug 签名是"能装真机、不能上架"的态，报告必须两边（没做什么 + 需要你做什么）都提醒
    let f = satisfiedFacts()
    f.signMode = "debug"
    f.signReleaseReady = false
    f.signReminder = "⚠ 当前是 debug 签名：只能装到已注册设备，不能上架。"
    f.signReleaseNextStep = "上架前：把 signingConfig 切到 release 那份"
    let doc = buildReport(f)
    var undone = ""
    for (l in doc.linesOf("undone")) {
        undone += l + "\n"
    }
    @Assert(undone.contains("debug 态"), true)
    @Assert(undone.contains("不能上架"), true)
    var need = ""
    for (l in doc.linesOf("need")) {
        need += l + "\n"
    }
    @Assert(need.contains("debug 签名"), true)
    @Assert(need.contains("上架前"), true)

    // release 态（或上架已齐备）时不该再出现这条提醒——别让人去"修"一个正常状态
    let g = satisfiedFacts()
    g.signMode = "release"
    g.signReleaseReady = true
    let doc2 = buildReport(g)
    var need2 = ""
    for (l in doc2.linesOf("need")) {
        need2 += l + "\n"
    }
    @Assert(need2.contains("上架前"), false)
}

@Test
public func testStepActionHints(): Unit {
    // 每个步骤都要有可执行动作（报告里"需要你做什么"才落得到界面上）
    let ids = ["scan", "deps", "port", "build", "hap", "sign", "deploy", "verify"]
    for (id in ids) {
        let h = stepActionHint(id)
        @Assert(h.size > 4, true)
        @Assert(h != "重跑这一步", true)
    }
    // 不认识的步骤给兜底文案（不返回空串，界面别出现空白动作）
    @Assert(stepActionHint("nope"), "重跑这一步")
    // settled 口径与 t2h:resume 一致
    @Assert(reportStepSettled("done"), true)
    @Assert(reportStepSettled("skipped"), true)
    @Assert(reportStepSettled("failed"), false)
    @Assert(reportStepSettled("pending"), false)
    // 文件名 base：空工程名兜底成 unknown
    @Assert(reportFileBase("habit-tree"), "habit-tree")
    @Assert(reportFileBase(""), "unknown")
}
