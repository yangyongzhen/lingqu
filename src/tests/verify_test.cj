package lingqu.tests

import std.collection.*
import stdx.encoding.json.*
import lingqu.*
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

/* ---------- faultlog 解析（真机实测踩过的坑） ---------- */

@Test
public func testCountCrashRecordsOnlyCountsRealCrashes(): Unit {
    // 权限不足：不能算崩溃（这是 2026-10-31 真机实测的原始输出）
    let denied = "ls: /data/log/faultlog/faultlogger/: Permission denied\n"
    @Assert(countCrashRecords(denied), 0)
    @Assert(faultlogUnreadable(denied), true)
    // 目录不存在
    let missing = "ls: /data/log/faultlog/faultlogger/: No such file or directory\n"
    @Assert(countCrashRecords(missing), 0)
    // 空目录（仅有 total 行）
    @Assert(countCrashRecords("total 0\n"), 0)
    // 有两条崩溃记录
    let two = "faultlogger-grove-20261031.log\njscrash-com.jiujiang.habit_tree-20261031.log\n"
    @Assert(countCrashRecords(two), 2)
    // 读得到且为空：既不是崩溃也不是读不到
    @Assert(countCrashRecords(""), 0)
    @Assert(faultlogUnreadable(""), false)
}

// ============================================================
// 0.39.9：verify 取数层的两处「照着 schema 抄错类型」缺陷（先红后绿）
// ============================================================
//
// 缺陷 ①：build 落档的 assetDiff.matched / staleInSo / missingInSo **都是数组**，
//   原先用 intFieldOf 当整数取 → 永远 0 → "指纹一致"被误判成"不一致"，
//   清单里出现"前端指纹不一致（会白屏）"，可用率凭空掉一格。
//   现场：habit-tree 的 build 落档是 matched=[…2 项]、staleInSo=[]、missingInSo=[]。
// 缺陷 ②：verify 读落档用的是**相对 CWD** 的 `.lingqu/...`（0.38.0 之前的落档位置），
//   于是读到上一次/别的工程的旧档——实测把"刚部署成功"报成"装上了但没起来"。
//   读侧现在一律 resolveLqPath（工程优先、CWD 兜底），这里钉解析层。

@Test
public func testBuildAssetFlagsTreatsAssetDiffAsArrays(): Unit {
    // 与真实落档同形：三个字段都是数组
    let ok = """
    {"exitCode":0,"gates":{"passed":true},"assetDiff":{"ok":true,"matched":["index-a.js","index-b.css"],"staleInSo":[],"missingInSo":[]}}
    """
    let (bOk, aOk) = buildAssetFlagsOf(JsonValue.fromStr(ok))
    @Assert(bOk, true)
    @Assert(aOk, true)          // ← 修之前这里是 false（intFieldOf 取数组得 0）
    // 旧 .so 带旧前端：staleInSo 有 1 项 → 必须判不一致
    let stale = """
    {"exitCode":0,"gates":{"passed":true},"assetDiff":{"matched":["a.js"],"staleInSo":["assets/index-OLD.js"],"missingInSo":[]}}
    """
    let (_, aOk2) = buildAssetFlagsOf(JsonValue.fromStr(stale))
    @Assert(aOk2, false)
    // 新前端没打包：missingInSo 有 1 项 → 同样不一致
    let missing = """
    {"exitCode":0,"gates":{"passed":true},"assetDiff":{"matched":["a.js"],"staleInSo":[],"missingInSo":["assets/index-NEW.js"]}}
    """
    let (_, aOk3) = buildAssetFlagsOf(JsonValue.fromStr(missing))
    @Assert(aOk3, false)
    // 编译失败 / 没有指纹信息（matched 为空）：编译不过 → 两条都 false
    let bad = """
    {"exitCode":101,"gates":{"passed":false},"assetDiff":{"matched":[],"staleInSo":[],"missingInSo":[]}}
    """
    let (bOk4, aOk4) = buildAssetFlagsOf(JsonValue.fromStr(bad))
    @Assert(bOk4, false)
    @Assert(aOk4, false)        // matched=0 时不能靠"没 stale"蒙成一致
}

@Test
public func testDeployFlagsReadInstallAndStartSeparately(): Unit {
    // 真机成功那次：装/启/日志 三项都 true
    let ok = """
    {"install":{"ok":true,"detail":"install bundle successfully"},"start":{"ok":true,"detail":"ability started"},"hilogHealthy":true}
    """
    let (inst, started, hilog) = deployFlagsOf(JsonValue.fromStr(ok))
    @Assert(inst, true)
    @Assert(started, true)
    @Assert(hilog, true)
    // 0.39.7 锁屏那次的真实形态：装上但没起来 —— 不能因为装上了就算通过
    let lock = """
    {"install":{"ok":true},"start":{"ok":false,"detail":"10106102"},"hilogHealthy":true}
    """
    let (inst2, started2, _) = deployFlagsOf(JsonValue.fromStr(lock))
    @Assert(inst2, true)
    @Assert(started2, false)
    // 空对象：三项全 false（缺档 = 没跑过，不猜）
    let (i3, s3, h3) = deployFlagsOf(JsonObject())
    @Assert(i3, false)
    @Assert(s3, false)
    @Assert(h3, false)
}