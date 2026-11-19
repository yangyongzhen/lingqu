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
    i.hasBuild = true
    i.hapOk = true
    i.hasHap = true
    i.hapBuilt = true
    i.hapSigned = true
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
    var unknown = 0
    for (it in items) {
        if (it.verdict == "pass") {
            pass += 1
        }
        if (it.verdict == "limit") {
            limit += 1
        }
        if (it.verdict == "unknown") {
            unknown += 1
        }
        // 全绿输入里不该出现失败
        @Assert(it.verdict != "fail", true)
    }
    // 装配侧全绿：launch / build / hap / plugins / frontend
    @Assert(pass, 5)
    // 0.39.89：没有「降级方案落地」的证据时**不许**记成平台限制（旧版这里 limit=1）
    @Assert(limit, 0)
    // ipc（只有"应用起来了"这条间接证据）/ events / platform-api 都只能是未测
    @Assert(unknown, 3)
    @Assert(itemOf(items, "ipc").verdict, "unknown")
}

@Test
public func testStatsExcludeLimitsFromDenominator(): Unit {
    // 分母 = 有结论的移植验收项，limit 与未测都剔出
    // （D-020 起 gate 项本身就是 transplant 类，所以这里不再有 gates-only；
    //   gates-only 只剩"一条移植项都没有"的兜底）
    let s = computeStats(buildChecklist(greenInput()))
    @Assert(s.scope, "transplant")
    @Assert(s.limit, 0)
    // 手工造：1 通过 + 1 限制 → 分母 1、可用率 100
    let items2 = ArrayList<CheckItem>()
    let a = CheckItem("a", "A")
    a.verdict = "pass"
    let b = CheckItem("b", "B")
    b.verdict = "limit"
    items2.add(a)
    items2.add(b)
    let s2 = computeStats(items2)
    @Assert(s2.covered, 1)
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
public func testRanButFailedIsNotReportedAsNeverRan(): Unit {
    // 0.39.23 实测踩到：m3u8dl 装配**跑过**（built=true、signed=true，8,273,766 字节），
    // 只是闸没过（rawfile/ 有 6 个死资源），verify 却报成「没跑过装配」。
    // "跑了没过" 与 "没跑过" 必须分开（AGENTS §4-63）——前者是 fail，后者才是 unknown。
    let i = greenInput()
    i.hapOk = false
    i.hasHap = true
    i.hapBuilt = true
    i.hapSigned = true
    i.hapFirstFailure = "HAP 闸：发现 6 个 rawfile/ 条目——前端已在 .so 里，这些是死资源（应清掉）"
    var hap: Option<CheckItem> = None
    for (it in buildChecklist(i)) {
        if (it.id == "hap") {
            hap = Some(it)
        }
    }
    match (hap) {
        case Some(h) =>
            @Assert(h.verdict, "fail")                          // 不是 unknown
            @Assert(h.note.contains("rawfile"), true)           // 把闸门第一条失败贴出来
            // 跑过的证据也要露出来，避免"失败=什么都没做"的误读
            var joined = ""
            for (e in h.evidence) {
                joined += e
            }
            @Assert(joined.contains("built=true"), true)
            @Assert(joined.contains("signed"), true)
        case None => @Assert(true, false)
    }
    // 落档不存在 → unknown（没跑过），且不能出现"跑过"的证据行
    let i2 = greenInput()
    i2.hapOk = false
    i2.hasHap = false
    i2.hapBuilt = false
    i2.hapSigned = false
    for (it in buildChecklist(i2)) {
        if (it.id == "hap") {
            @Assert(it.verdict, "unknown")
            @Assert(it.note.contains("没跑过"), true)
        }
    }
    // 同样的口径套到交叉编译上：跑过但 exit!=0 → fail，不是"没跑过"
    let i3 = greenInput()
    i3.buildOk = false
    i3.hasBuild = true
    for (it in buildChecklist(i3)) {
        if (it.id == "build") {
            @Assert(it.verdict, "fail")
            @Assert(it.note.contains("没通过"), true)
        }
    }
    let i4 = greenInput()
    i4.buildOk = false
    i4.hasBuild = false
    for (it in buildChecklist(i4)) {
        if (it.id == "build") {
            @Assert(it.verdict, "unknown")
            @Assert(it.note.contains("没跑过"), true)
        }
    }
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

// ============================================================
// 0.39.89：A4「核心功能可用率」的分母错了（先红后绿）
// ============================================================
//
// 现象（用户真机实测）：⑥ 屏报「核心功能可用率 100%」，而他在真机上点
//   「选择文件」「保存目录」两个按钮**完全没反应**。
//
// 根因三层叠在一起：
//   ① 分母是**装配步骤**（launch/build/hap/ipc/frontend），不是核心功能；
//      `ipc` 的判据只是"应用起来了 + hilog 干净"，一条命令都没调就判 pass。
//   ② `rfd::FileDialog` 被登记成"平台限制"后**剔出分母** —— 真机上不可用的功能对分数零影响。
//   ③ "降级方案落地了没有"根本没有判据，而实际是 OHOS 分支 `return None`、
//      前端 `if (p)` 静默吞掉（用户点按钮就是没反应）。
//
// 新口径（用户拍板）：分母 = 核心功能清单；没测 → unknown 不进分母但要计数；
//   平台限制只有**降级落地**才允许记 limit，否则该功能判 fail。

/** 造一条功能项 */
func featOf(cmd: String, title: String, api: String, landed: Bool): FeatureInput {
    let f = FeatureInput(cmd, title)
    f.degradedApi = api
    f.fallbackLanded = landed
    return f
}

/** 在清单里按 id 取一条（取不到就让用例红，别静默放过） */
func itemOf(items: ArrayList<CheckItem>, id: String): CheckItem {
    for (it in items) {
        if (it.id == id) {
            return it
        }
    }
    // 取不到时返回一个必定判红占位项，"没生成条目"本身就是要断的行为
    let miss = CheckItem(id, "MISSING:${id}")
    miss.verdict = "MISSING"
    return miss
}

@Test
public func testFeatureWithoutFallbackIsFailNotLimit(): Unit {
    // 现场形态：pick_m3u8_file 命中 rfd::FileDialog，OHOS 分支 return None，前端无兜底
    // D-020 后行为变了：**平台空壳的账记在移植项 platform-api 上**，业务功能本身没人实测 → unknown。
    // （早先这里判 fail，结果同一件事扣两次，业务清单还一片红，看着像"原应用全崩"）
    let i = greenInput()
    i.features.add(featOf("pick_m3u8_file", "选择本地 m3u8 文件", "rfd::FileDialog", false))
    i.features.add(featOf("pick_folder", "选择保存目录", "rfd::FileDialog", false))
    let items = buildChecklist(i)
    for (id in ["feat:pick_m3u8_file", "feat:pick_folder"]) {
        let it = itemOf(items, id)
        @Assert(it.category, "business")          // 不是移植项，不进分母
        @Assert(it.verdict, "unknown")            // 没实测过就只能记未测
        @Assert(it.note.contains("rfd::FileDialog"), true)
        @Assert(it.note.contains("platform-api"), true)   // 说清这笔账记在哪儿
    }
}

@Test
public func testFeatureVerdictPrefersHumanAndKeepsUntested(): Unit {
    let i = greenInput()
    // ① 降级落地了但没人测过 → 未测（不能因为"代码看起来写了"就算通过）
    i.features.add(featOf("start_download", "开始下载", "", true))
    // ② 人工实测可用 → pass
    let humanOk = featOf("cancel_download", "取消下载", "", true)
    humanOk.humanVerdict = "pass"
    i.features.add(humanOk)
    // ③ 人工实测不可用 → fail（人测的结论永远优先于任何推断）
    let humanBad = featOf("open_in_explorer", "在文件管理器打开", "", true)
    humanBad.humanVerdict = "fail"
    i.features.add(humanBad)
    let items = buildChecklist(i)
    @Assert(itemOf(items, "feat:start_download").verdict, "unknown")
    @Assert(itemOf(items, "feat:start_download").note.contains("未测"), true)
    @Assert(itemOf(items, "feat:cancel_download").verdict, "pass")
    @Assert(itemOf(items, "feat:open_in_explorer").verdict, "fail")
}

@Test
public func testStatsDenominatorIsCoveredNotAssemblySteps(): Unit {
    // 手工造清单，钉住统计口径本身：分母 = 有结论的项（pass+fail），未测单列
    let items = ArrayList<CheckItem>()
    let a = CheckItem("a", "A")
    a.verdict = "pass"
    let b = CheckItem("b", "B")
    b.verdict = "fail"
    let c = CheckItem("c", "C")
    c.verdict = "unknown"
    let d = CheckItem("d", "D")
    d.verdict = "limit"
    items.add(a)
    items.add(b)
    items.add(c)
    items.add(d)
    let s = computeStats(items)
    @Assert(s.pass, 1)
    @Assert(s.fail, 1)
    @Assert(s.notVerified, 1)   // ← 修之前没有这个字段（未测被混进分母）
    @Assert(s.covered, 2)       // ← 修之前 covered = total - limit = 3
    @Assert(s.ratePercent, 50)  // 1/2，不是 1/3
    // 全都未测：可用率必须是 0，而不是"没数据就给 100"
    let onlyUnknown = ArrayList<CheckItem>()
    let u1 = CheckItem("u1", "U1")
    u1.verdict = "unknown"
    onlyUnknown.add(u1)
    @Assert(computeStats(onlyUnknown).ratePercent, 0)
}

@Test
public func testPlatformLimitRequiresLandedFallback(): Unit {
    // 两处平台 API：一处降级落地了、一处没有 → 不许整项记 limit
    let i = greenInput()
    let p1 = PlatformInput("rfd::FileDialog")
    p1.verdict = "降级"
    p1.fallbackLanded = false
    p1.note = "commands.rs 的 OHOS 分支只 return None"
    let p2 = PlatformInput("window-state")
    p2.verdict = "改造"
    p2.fallbackLanded = true
    i.platformItems.add(p1)
    i.platformItems.add(p2)
    let lim = itemOf(buildChecklist(i), "platform-api")
    @Assert(lim.verdict, "fail")
    // 必须点名是哪一处没落地，不能只报"有平台限制"
    @Assert(lim.note.contains("rfd::FileDialog"), true)
    // 全部落地了才允许记成平台限制（这时才剔出分母）
    let i2 = greenInput()
    let q = PlatformInput("window-state")
    q.verdict = "改造"
    q.fallbackLanded = true
    i2.platformItems.add(q)
    @Assert(itemOf(buildChecklist(i2), "platform-api").verdict, "limit")
}

@Test
public func testOhosStubOnlyDetectsReturnNone(): Unit {
    // 现场原文（commands.rs，m3u8dl-tauri）
    @Assert(ohosStubOnly("None"), true)
    @Assert(ohosStubOnly("return None;"), true)
    @Assert(ohosStubOnly(""), true)
    @Assert(ohosStubOnly("todo!()"), true)
    @Assert(ohosStubOnly("unimplemented!()"), true)
    // 真写了替代实现的不许判成 stub
    @Assert(ohosStubOnly("let p = pick_from_tree(); Some(p)"), false)
    @Assert(ohosStubOnly("return Some(dir);"), false)
}

/**
 * 现场原文结构（与 m3u8dl-tauri 的 commands.rs 一致）：
 * 同名函数两套实现，桌面一套、鸿蒙一套，靠 `#[cfg(...)]` 区分。
 */
func sampleCommandsRs(): String {
    return "#[cfg(not(all(target_os = \"linux\", target_env = \"ohos\")))]\n" +
        "pub async fn pick_folder() -> Result<Option<String>, String> {\n" +
        "    let dir = rfd::FileDialog::new().pick_folder();\n" +
        "    Ok(dir.map(|p| p.to_string_lossy().to_string()))\n" +
        "}\n" +
        "\n" +
        "#[cfg(all(target_os = \"linux\", target_env = \"ohos\"))]\n" +
        "pub async fn pick_folder() -> Result<Option<String>, String> {\n" +
        "    // 鸿蒙上暂无文件选择器\n" +
        "    Ok(None)\n" +
        "}\n" +
        "\n" +
        "pub async fn start_download(id: String) -> Result<(), String> {\n" +
        "    let _ = id;\n" +
        "    Ok(())\n" +
        "}\n" +
        "\n" +
        "pub async fn pick_folder_extra() -> Result<(), String> {\n" +
        "    Ok(())\n" +
        "}\n"
}

@Test
public func testOhosImplStubOnlyReadsRealSourceShape(): Unit {
    let src = sampleCommandsRs()
    // 桌面分支不能算成鸿蒙分支（`not(...)` 里也有 ohos 字样）
    @Assert(fnImplsOf(src, "pick_folder").size, 2)
    // 鸿蒙分支只 Ok(None) → 空壳 = 降级没落地
    @Assert(ohosImplStubOnly(src, "pick_folder"), true)
    // 纯 Rust 命令没有鸿蒙分支，但也没碰平台 API：这里判"没有鸿蒙实现"= 空壳（由上层决定怎么用）
    @Assert(ohosImplStubOnly(src, "start_download"), true)
    // 名字前缀不能误命中（pick_folder_extra 不是 pick_folder）
    @Assert(fnImplsOf(src, "pick_folder_extra").size, 1)
    // 桌面体里出现平台 API 名 → 这个功能碰了平台专有能力
    let apis = ArrayList<String>()
    apis.add("rfd::FileDialog")
    @Assert(touchesAnyApi(src, "pick_folder", apis), true)
    @Assert(touchesAnyApi(src, "start_download", apis), false)
    // 鸿蒙分支写了真实现 → 落地了
    let landed = "#[cfg(all(target_os = \"linux\", target_env = \"ohos\"))]\n" +
        "pub async fn pick_folder() -> Result<Option<String>, String> {\n" +
        "    let p = pick_from_app_tree();\n" +
        "    Ok(p)\n" +
        "}\n"
    @Assert(ohosImplStubOnly(landed, "pick_folder"), false)
}

// ── 0.39.93：真机实测（探针落档）压过静态推断 + 全局 pass 不许当功能分子 ──────────
// 现场（m3u8dl-tauri，2026-11-08 15:32 落档）：核心功能 pass=0 / covered=3 → 0%，
// 报告结论句却写成「4/3 项有结论」——分子取了全局 pass（4，含 launch/build/hap/frontend），
// 分母取了功能 covered（3）。两个不同集合相除，用户一眼就看出来是假数字。

@Test
public func testProbeVerdictBeatsStaticInference(): Unit {
    let i = greenInput()
    // 静态推断：命中命令执行 API、鸿蒙侧空壳 → 本来判 fail
    let ok = featOf("start_download", "开始下载", "std::process::Command", false)
    // 但真机上点过，日志真的回了一句话 → 以实测为准
    ok.probeVerdict = "pass"
    ok.probeNote = "真机点按「开始下载」：运行日志回「请先输入 m3u8 地址或选择本地文件」"
    i.features.add(ok)
    // 反向：静态没命中平台 API（本来只会判"未测"），但真机点了毫无反应 → fail
    let bad = featOf("get_task", "查询任务进度", "", true)
    bad.probeVerdict = "fail"
    bad.probeNote = "真机点按：界面与日志均无任何变化"
    i.features.add(bad)
    let items = buildChecklist(i)
    let a = itemOf(items, "feat:start_download")
    @Assert(a.verdict, "pass")
    @Assert(a.note.contains("真机实测"), true)
    @Assert(a.note.contains("请先输入"), true)
    @Assert(itemOf(items, "feat:get_task").verdict, "fail")
}

@Test
public func testProbeEvidenceLandsInChecklistItem(): Unit {
    let i = greenInput()
    let f = featOf("detect_ffmpeg", "探测 ffmpeg", "", true)
    f.probeVerdict = "pass"
    f.probeNote = "界面显示「未找到（将回退为二进制合并）」= 探测跑了并给了结论"
    f.probeEvidence.add(".lingqu/shots/start.layout.json")
    i.features.add(f)
    let it = itemOf(buildChecklist(i), "feat:detect_ffmpeg")
    @Assert(it.verdict, "pass")
    var found = false
    for (e in it.evidence) {
        if (e.contains("start.layout.json")) {
            found = true
        }
    }
    // 证据要能自证：截图/版面树路径必须落进条目，否则"实测过"只是一句话
    @Assert(found, true)
}

@Test
public func testStatsExposeFeaturePassSeparately(): Unit {
    // 用户看到的现场：装配 5 项 pass + 3 条业务功能判 fail（平台 API 没落地）
    // D-020 之后：业务功能**不进分母**，所以这里验的是"它们被单独计数、且不污染通过率"
    let i = greenInput()
    i.features.add(featOf("pick_folder", "选择目录", "rfd::FileDialog", false))
    i.features.add(featOf("pick_m3u8_file", "选择文件", "rfd::FileDialog", false))
    i.features.add(featOf("open_in_explorer", "打开所在目录", "std::process::Command", false))
    let s = computeStats(buildChecklist(i))
    @Assert(s.scope, "transplant")
    // 分母构成必须自洽：transplantTotal = 有结论 + 未测（limit 已被剔出）
    @Assert(s.transplantTotal, s.covered + s.transplantNotVerified)
    @Assert(s.featurePass, 5)
    @Assert(s.covered, 5)
    @Assert(s.ratePercent, 100)
    // 业务功能：这 3 条只有静态推断（平台 API 空壳），没人实测 → 一条都不能算"测过"
    @Assert(s.businessTotal, 3)
    @Assert(s.businessTested, 0)
    @Assert(s.businessPass, 0)
}

@Test
public func testBusinessFeaturesAreNotInDenominator(): Unit {
    // 核心回归（D-020）：业务功能**无论通过还是失败**，都不许改变移植通过率。
    let items = ArrayList<CheckItem>()
    let t1 = CheckItem("launch", "应用启动")
    t1.verdict = "pass"
    items.add(t1)
    let t2 = CheckItem("hap", "HAP 装配")
    t2.verdict = "pass"
    items.add(t2)
    // 三条原应用业务功能：一条过、两条挂
    let b1 = CheckItem("feat:start_download", "下载")
    b1.kind = "feature"
    b1.category = "business"
    b1.verdict = "pass"
    let b2 = CheckItem("feat:ai_json_request", "AI 请求")
    b2.kind = "feature"
    b2.category = "business"
    b2.verdict = "fail"
    let b3 = CheckItem("feat:cancel_ai_request", "取消 AI 请求")
    b3.kind = "feature"
    b3.category = "business"
    b3.verdict = "fail"
    items.add(b1)
    items.add(b2)
    items.add(b3)
    let s = computeStats(items)
    @Assert(s.scope, "transplant")
    @Assert(s.transplantTotal, 2)
    @Assert(s.covered, 2)
    @Assert(s.ratePercent, 100)   // ← 业务功能全挂也照样 100：那是原应用的账，不是移植的
    @Assert(s.businessTotal, 3)
    @Assert(s.businessTested, 3)
    @Assert(s.businessPass, 1)
}

@Test
public func testSmokeDoesNotAffectTransplantRate(): Unit {
    // 真机冒烟（smoke）只作参考：挂了一条也不许把移植通过率拉下去
    let items = ArrayList<CheckItem>()
    let a = CheckItem("launch", "应用启动")
    a.verdict = "pass"
    let b = CheckItem("hap", "HAP 装配")
    b.verdict = "fail"
    items.add(a)
    items.add(b)
    let before = computeStats(items)
    @Assert(before.ratePercent, 50)   // 1/2
    let smoke = CheckItem("feat:probe:选择文件", "选择文件（冒烟）")
    smoke.kind = "feature"
    smoke.category = "smoke"
    smoke.verdict = "fail"
    items.add(smoke)
    let after = computeStats(items)
    @Assert(after.ratePercent, 50)    // 冒烟失败不改变移植通过率
    @Assert(after.covered, 2)         // 也不进分母
    @Assert(after.probeFeatures, 1)   // 但"实测过几条"要能数出来
    @Assert(after.businessTested, 1)
}
// ── 0.39.107：没有命令命中的平台 API，按命中行**所属函数**判降级落没落地 ──────────
// 现场（habit-tree）：app_data_dir 只出现在 lib.rs 的文档注释与本工程的 resolve_app_data_dir
// 及桌面专用 save_target_dir 里，一个 IPC 命令都没命中 → 旧判据记「无法判定 → 没落地」。

@Test
public func testFnNameOfLine(): Unit {
    @Expect(fnNameOfLine("fn foo(a: Int64) {"), "foo")
    @Expect(fnNameOfLine("pub async fn pick_folder() -> Option<String> {"), "pick_folder")
    @Expect(fnNameOfLine("    let x = my_fn(1);"), "")
    @Expect(fnNameOfLine("// fn commented() {"), "")
    @Expect(fnNameOfLine("#[cfg(not(target_env = \"ohos\"))] pub fn save(x: Int64) {"), "save")
}

@Test
public func testSiteLineOf(): Unit {
    @Expect(siteLineOf("src-tauri/src/commands.rs:157"), 157)
    @Expect(siteLineOf("E:/w/p/src/lib.rs:18"), 18)
    // 没有行号 → 0（调用方按"不知道"处理，不猜）
    @Expect(siteLineOf("src-tauri/src/lib.rs"), 0)
}

@Test
public func testJudgePlatformSiteLandedShapes(): Unit {
    let text = "#[cfg(not(target_env = \"ohos\"))]\n" +
        "fn save_target_dir() -> Option<String> {\n" +
        "    std::env::temp_dir().to_str().map(String::from)\n" +
        "}\n" +
        "fn resolve_app_data_dir(app: &App) -> Result<PathBuf, String> {\n" +
        "    #[cfg(not(target_env = \"ohos\"))]\n" +
        "    {\n" +
        "        app.path().app_data_dir().map_err(|e| e.to_string())\n" +
        "    }\n" +
        "    #[cfg(target_env = \"ohos\")]\n" +
        "    {\n" +
        "        Ok(sandbox_dir())\n" +
        "    }\n" +
        "}\n" +
        "#[cfg(target_env = \"ohos\")]\n" +
        "pub async fn pick_folder() -> Option<String> {\n" +
        "    None\n" +
        "}\n"
    // 桌面专用函数里的 temp_dir：鸿蒙上不编译 → 不算缺口
    @Expect(judgePlatformSite(text, 3)[0], false)
    // resolve_app_data_dir 的鸿蒙分支返回沙箱路径 → 落地了
    @Expect(judgePlatformSite(text, 8)[0], false)
    // 鸿蒙分支只 None → 缺口
    @Expect(judgePlatformSite(text, 17)[0], true)
    // 命中行在声明之上（找不到所属函数）→ 缺口（不猜"没问题"）
    @Expect(judgePlatformSite(text, 1)[0], true)
}

@Test
public func testJudgeFrontendSiteFallback(): Unit {
    let text = "async function fillVersion() {\n" +
        "  let v = APP_VERSION_FALLBACK;\n" +
        "  try {\n" +
        "    v = await getVersion();\n" +
        "  } catch {\n" +
        "    /* 无 Tauri API 时回落常量 */\n" +
        "  }\n" +
        "}\n" +
        "async function reportVersion() {\n" +
        "  return await getVersion();\n" +
        "}\n"
    // 包在 try/catch 里 → 有兜底，算落地
    @Expect(judgeFrontendSite(text, 4)[0], false)
    // 没有兜底 → 缺口
    @Expect(judgeFrontendSite(text, 10)[0], true)
    // ⓵ 命中行是 import 语句 → 根本不是调用点，不计缺口（EcoPaste App.tsx:1 实测）
    let imp = "import { getCurrentWebviewWindow } from \"@tauri-apps/api/webviewWindow\";\nexport const x = 1;\n"
    @Expect(judgeFrontendSite(imp, 1)[0], false)
    // ⓶ 箭头函数里带 try/catch → 也算落地（EcoPaste `const initializeAppMetadata = async () => {`）
    let arrow = "const initializeAppMetadata = async () => {\n  try {\n    const v = await getVersion();\n  } catch {\n    /* 回落 */\n  }\n};\n"
    @Expect(judgeFrontendSite(arrow, 3)[0], false)
}

@Test
public func testCommandImplLandedAcceptsInBodyCfg(): Unit {
    // 形态 ②：整函数不分 cfg，体内按 cfg 分块（habit-tree open_url 的真实形态）
    let inBody = "fn open_url(app: tauri::AppHandle, url: String) -> Result<(), String> {\n" +
        "    #[cfg(target_env = \"ohos\")]\n" +
        "    {\n" +
        "        crate::ohos_bridge::open_url(&app, url)?;\n" +
        "        return Ok(());\n" +
        "    }\n" +
        "    #[cfg(not(target_env = \"ohos\"))]\n" +
        "    {\n" +
        "        std::process::Command::new(\"xdg-open\").arg(&url).spawn()\n" +
        "    }\n" +
        "}\n" +
        "fn pick_m3u8_file() -> Option<String> {\n" +
        "    #[cfg(target_env = \"ohos\")]\n" +
        "    {\n" +
        "        None\n" +
        "    }\n" +
        "}\n"
    @Expect(commandImplLanded(inBody, "open_url"), true)
    // 鸿蒙分支是空壳（None）→ 仍算没落地
    @Expect(commandImplLanded(inBody, "pick_m3u8_file"), false)
    // 压根没有鸿蒙分支 → 没落地
    @Expect(commandImplLanded(inBody, "no_such_fn"), false)
}

@Test
public func testDesktopOnlyRecognizesOtherOsCfg(): Unit {
    // `#[cfg(target_os = "windows")]` 的函数在鸿蒙上根本不编译 ⇒ 应算桌面专属，
    // 不能判成"没有鸿蒙实现"（2026-11-19 EcoPaste 实测：platform-api 因此冤枉 fail）
    let win = "#[cfg(target_os = \"windows\")]\nfn is_scheduled_task_exists() -> bool {\n    Command::new(\"schtasks\").output().is_ok()\n}\n"
    @Expect(fnDesktopOnlyOf(win, 3), true)
    // 但 `target_os = "linux"` **不是**桌面专属——鸿蒙的 target_os 也是 linux
    let linux = "#[cfg(target_os = \"linux\")]\nfn f() -> bool {\n    Command::new(\"x\").status().is_ok()\n}\n"
    @Expect(fnDesktopOnlyOf(linux, 3), false)
    // 原有形态（not(...ohos...)）仍要认
    let notOhos = "#[cfg(not(all(target_os = \"linux\", target_env = \"ohos\")))]\nfn g() -> bool {\n    true\n}\n"
    @Expect(fnDesktopOnlyOf(notOhos, 3), true)
}

@Test
public func testHelperCallNamesInExtractsPathCallOnly(): Unit {
    // `core::paths::app_data_dir(` → 路径限定调用，取末段（EcoPaste storage.rs 的现场形态）。
    // 注：`PathBuf::from(` 这类 std 路径也会被收（都是 `::` 调用），但取数层在工程源码里
    // 找不到 `fn from` 的定义，自然追不到——所以这里夹具只放目标调用，size 才可断言为 1。
    let body = "let dir = core::paths::app_data_dir()?;\nOk(dir)\n"
    let names = helperCallNamesIn(body)
    @Expect(names.size, 1)
    @Expect(names.contains("app_data_dir"), true)
    // 方法调用与裸调用不收：tauri 的 `app.path().app_data_dir()` 是平台 API 本身，工程源码里
    // 不会有它的定义；泛型 turbofish 的 `(` 前不是标识符，也不收
    let noisy = "let a = app.path().app_data_dir();\nlet b = plain_call();\nlet c = foo::<T>(1);\n"
    let names2 = helperCallNamesIn(noisy)
    @Expect(names2.size, 0)
    // 重复调用去重
    let dup = "let a = core::paths::app_data_dir();\nlet b = paths::app_data_dir();\n"
    @Expect(helperCallNamesIn(dup).size, 1)
}

@Test
public func testJudgePlatformSiteFollowsHelper(): Unit {
    // EcoPaste `app_data_dir` 现场（0.39.128 记录的形态）：命令层无 cfg 分支，逻辑在 helper 里
    let cmd = "fn storage_cmd() -> Result<String, String> {\n" +
        "    let dir = core::paths::app_data_dir()?;\n" +
        "    Ok(dir)\n" +
        "}\n"
    let helper = "pub fn app_data_dir() -> Result<String, String> {\n" +
        "    #[cfg(target_env = \"ohos\")]\n" +
        "    {\n" +
        "        Ok(String::from(\"/data/storage/el2/base/files\"))\n" +
        "    }\n" +
        "    #[cfg(not(target_env = \"ohos\"))]\n" +
        "    {\n" +
        "        Ok(String::from(\"~/.local/share\"))\n" +
        "    }\n" +
        "}\n"
    // 旧判据（不追 helper）：仍是缺口——口径不许悄悄变（0.39.128 的假 fail 就是它）
    let (gap0, why0) = judgePlatformSite(cmd, 2)
    @Expect(gap0, true)
    @Expect(why0.contains("没有落地的鸿蒙实现"), true)
    // 追到 helper：体内鸿蒙分支落地 → 不算缺口，note 点名 helper
    var m = HashMap<String, String>()
    m.add("app_data_dir", helper)
    let (gap, why) = judgePlatformSiteWith(cmd, 2, m)
    @Expect(gap, false)
    @Expect(why.contains("app_data_dir"), true)
    // helper 没有鸿蒙分支 → 仍是缺口，但要说清追过了谁
    var m2 = HashMap<String, String>()
    m2.add("app_data_dir", "pub fn app_data_dir() -> Result<String, String> {\n    Ok(String::from(\"/tmp\"))\n}\n")
    let (gap2, why2) = judgePlatformSiteWith(cmd, 2, m2)
    @Expect(gap2, true)
    @Expect(why2.contains("helper"), true)
    // 整函数 cfg 的 helper 也算落地
    var m3 = HashMap<String, String>()
    m3.add("app_data_dir",
        "#[cfg(target_env = \"ohos\")]\npub fn app_data_dir() -> Result<String, String> {\n    Ok(String::from(\"/data/storage/el2/base/files\"))\n}\n")
    let (gap3, why3) = judgePlatformSiteWith(cmd, 2, m3)
    @Expect(gap3, false)
    @Expect(why3.contains("app_data_dir"), true)
}

@Test
public func testCommandImplLandedFollowsHelper(): Unit {
    let cmd = "fn storage_cmd() -> Result<String, String> {\n" +
        "    let dir = crate::core::paths::app_data_dir()?;\n" +
        "    Ok(dir)\n" +
        "}\n"
    let helper = "pub fn app_data_dir() -> Result<String, String> {\n" +
        "    #[cfg(target_env = \"ohos\")]\n" +
        "    {\n" +
        "        Ok(String::from(\"/data/storage/el2/base/files\"))\n" +
        "    }\n" +
        "    #[cfg(not(target_env = \"ohos\"))]\n" +
        "    {\n" +
        "        Ok(String::from(\"~/.local/share\"))\n" +
        "    }\n" +
        "}\n"
    // 旧口径：命令层没有 cfg → 没落地（不追 helper 时）
    @Expect(commandImplLanded(cmd, "storage_cmd"), false)
    var m = HashMap<String, String>()
    m.add("app_data_dir", helper)
    @Expect(commandImplLandedWith(cmd, "storage_cmd", m), true)
    // helper 缺鸿蒙分支 → 仍没落地
    var m2 = HashMap<String, String>()
    m2.add("app_data_dir", "pub fn app_data_dir() -> Result<String, String> {\n    Ok(String::from(\"/tmp\"))\n}\n")
    @Expect(commandImplLandedWith(cmd, "storage_cmd", m2), false)
}
