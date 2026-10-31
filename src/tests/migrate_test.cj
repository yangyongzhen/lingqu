package lingqu.tests

import lingqu.*
import stdx.encoding.json.*

/*
 * 一键迁移编排层的纯函数单测（0.36.0）。
 *
 * 这一层最怕两种错（都会误导人）：
 *   ① 把"跳过"说成"失败"——没插设备时一键迁移永远红，用户会以为工具坏了；
 *   ② 把"没跑过"说成"通过"——落档不存在却报全绿，等于假证。
 * 所以下面每个断言都在钉这两种区分。
 */

/** 造一行结论（测试里反复用） */
func mkRow(step: String, ran: Bool, ok: Bool): MigrateRow {
    let r = MigrateRow()
    r.step = step
    r.title = taskStepTitle(step)
    r.ran = ran
    r.ok = ok
    return r
}

/* 读 JSON 的小工具：`intFieldOf` 那一套是 lingqu 包内的，测试包拿不到，这里自己写三个 */
func jInt(o: JsonObject, key: String): Int64 {
    match (o.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case _ => ()
            }
        case None => ()
    }
    return -1
}

func jStr(o: JsonObject, key: String): String {
    match (o.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => ()
            }
        case None => ()
    }
    return ""
}

func jBool(o: JsonObject, key: String): Bool {
    match (o.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsBool => return v.asBool().getValue()
                case _ => ()
            }
        case None => ()
    }
    return false
}

func jArrSize(o: JsonObject, key: String): Int64 {
    match (o.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsArray => return v.asArray().size()
                case _ => ()
            }
        case None => ()
    }
    return -1
}

@Test
public func testMigrateStepsRespectDevice(): Unit {
    @Assert(migrateNeedsDevice("deploy"), true)
    @Assert(migrateNeedsDevice("verify"), true)
    @Assert(migrateNeedsDevice("build"), false)
    // 有设备：8 步全跑
    @Assert(migrateSteps(true).size, 8)
    // 没设备：去掉 deploy/verify（跳过，不是失败）
    let noDev = migrateSteps(false)
    @Assert(noDev.size, 6)
    for (s in noDev) {
        @Assert(s == "deploy" || s == "verify", false)
    }
}

@Test
public func testMigratePercent(): Unit {
    let st = MigrateState()
    // 还没开始：0（不给 -1，界面显示 0% 而不是"—"）
    @Assert(migratePercent(st), 0)
    st.total = 8
    @Assert(migratePercent(st), 0)
    st.rows.add(mkRow("scan", true, true))
    st.rows.add(mkRow("deps", true, true))
    st.rows.add(mkRow("port", true, true))
    st.rows.add(mkRow("build", true, true))
    @Assert(migratePercent(st), 50)
    // 行数超过 total（理论上不该发生）：夹到 100，别算出 112%
    st.rows.add(mkRow("hap", true, true))
    st.rows.add(mkRow("sign", true, true))
    st.rows.add(mkRow("deploy", false, false))
    st.rows.add(mkRow("verify", false, false))
    st.rows.add(mkRow("extra", true, true))
    @Assert(migratePercent(st), 100)
}

@Test
public func testVerdictStates(): Unit {
    let st = MigrateState()
    @Assert(migrateVerdict(st), "还没开始")

    // 进行中
    st.running = true
    st.total = 8
    st.index = 2
    st.current = "port"
    @Assert(migrateVerdict(st).contains("3/8"), true)
    @Assert(migrateVerdict(st).contains("规则改造"), true)

    // 停在某一步：结论里必须带步骤名与原因
    st.running = false
    let bad = mkRow("build", true, false)
    bad.note = "exit=101 / 错误 3"
    st.rows.add(mkRow("scan", true, true))
    st.rows.add(bad)
    let v = migrateVerdict(st)
    @Assert(v.contains("交叉编译"), true)
    @Assert(v.contains("exit=101"), true)

    // 已停止
    st.cancelled = true
    @Assert(migrateVerdict(st).contains("已停止"), true)
}

@Test
public func testVerdictDistinguishesSkippedFromFailed(): Unit {
    let st = MigrateState()
    st.total = 8
    for (s in ["scan", "deps", "port", "build", "hap", "sign"]) {
        st.rows.add(mkRow(s, true, true))
    }
    // deploy/verify 没设备 → skipped（ran=false，ok=false）
    let d = mkRow("deploy", false, false)
    d.skipped = "未连接真机"
    st.rows.add(d)
    let v = mkRow("verify", false, false)
    v.skipped = "未连接真机"
    st.rows.add(v)

    // 关键断言：跳过 ≠ 失败——不能出现"停在"
    let verdict = migrateVerdict(st)
    @Assert(verdict.contains("停在"), false)
    @Assert(verdict.contains("代码链全部通过"), true)
    @Assert(verdict.contains("未连接真机"), true)
    // 同一原因只出现一次（两个 skipped 行别把句子重复两遍）
    @Assert(migrateSkipReasons(st), "未连接真机")

    // 全过
    let st2 = MigrateState()
    st2.total = 2
    st2.rows.add(mkRow("scan", true, true))
    st2.rows.add(mkRow("deps", true, true))
    @Assert(migrateVerdict(st2), "全部通过")
}

@Test
public func testRowLineFourStates(): Unit {
    let never = mkRow("scan", false, false)
    @Assert(migrateRowLine(never).contains("未跑"), true)

    let sk = mkRow("deploy", false, false)
    sk.skipped = "未连接真机"
    @Assert(migrateRowLine(sk).contains("跳过"), true)
    @Assert(migrateRowLine(sk).contains("未连接真机"), true)

    let ok = mkRow("scan", true, true)
    ok.note = "单元 R=12"
    @Assert(migrateRowLine(ok).contains("通过"), true)
    @Assert(migrateRowLine(ok).contains("单元 R=12"), true)

    let failed = mkRow("build", true, false)
    failed.note = "exit=101"
    @Assert(migrateRowLine(failed).contains("未过"), true)
    // "未跑" 与 "未过" 不能混：未过的行必须带上证据
    @Assert(migrateRowLine(failed).contains("exit=101"), true)
}

@Test
public func testSnapshotIsDeepCopy(): Unit {
    let st = MigrateState()
    st.project = "habit-tree"
    st.rows.add(mkRow("scan", true, true))
    let snap = st.snapshot()
    @Assert(snap.rows.size, 1)
    // 改原状态不许影响快照（snapshot 的意义就是"锁外读一份稳定的"）
    st.rows.add(mkRow("deps", true, false))
    st.project = "changed"
    @Assert(snap.rows.size, 1)
    @Assert(snap.project, "habit-tree")
}

@Test
public func testStateJsonCarriesEverythingUiNeeds(): Unit {
    let st = MigrateState()
    st.project = "habit-tree"
    st.path = "E:/test/rust/habit-tree"
    st.hasDevice = false
    st.total = 8
    st.rows.add(mkRow("scan", true, true))
    st.askPrompt = "【灵渠 · 一键迁移中断】…"
    st.reportMd = ".lingqu/report/habit-tree.md"
    st.resultMd = ".lingqu/migrate/habit-tree.md"
    let o = migrateStateJson(st)
    @Assert(jInt(o, "percent"), 12)
    @Assert(jInt(o, "total"), 8)
    @Assert(jStr(o, "project"), "habit-tree")
    @Assert(jStr(o, "verdict"), migrateVerdict(st))
    @Assert(jArrSize(o, "rows"), 1)
    @Assert(jStr(o, "askPrompt").contains("一键迁移中断"), true)
    @Assert(jStr(o, "resultMd"), ".lingqu/migrate/habit-tree.md")
    // 结果卡正文也随状态一起给（界面 renderMd 直接用，命令行也直接打印）
    @Assert(jStr(o, "markdown").contains("一键迁移结果"), true)
    // hasDevice 也必须在（页面据此写"真机：未连接"）
    @Assert(jBool(o, "hasDevice"), false)
}

@Test
public func testResultMarkdownThreeParts(): Unit {
    let st = MigrateState()
    st.project = "habit-tree"
    st.path = "E:/test/rust/habit-tree"
    st.hasDevice = true
    st.total = 8
    st.rows.add(mkRow("scan", true, true))
    let bad = mkRow("build", true, false)
    bad.note = "exit=101 | 链接失败"
    st.rows.add(bad)
    st.reportMd = ".lingqu/report/habit-tree.md"
    let md = migrateResultMarkdown(st, ".lingqu/report/habit-tree.md")
    // 三段：结论 / 逐步表 / 接下来
    @Assert(md.contains("一键迁移结果"), true)
    @Assert(md.contains("| 步骤 | 状态 | 证据 |"), true)
    @Assert(md.contains("**接下来**"), true)
    @Assert(md.contains("交叉编译"), true)
    // 表格单元格里的 | 必须被替换，否则整张表塌掉
    @Assert(md.contains("exit=101 ／ 链接失败"), true)
    // 报告路径要能点到
    @Assert(md.contains(".lingqu/report/habit-tree.md"), true)
}

@Test
public func testNextHintForSkippedVerify(): Unit {
    let st = MigrateState()
    st.total = 8
    for (s in ["scan", "deps", "port", "build", "hap", "sign"]) {
        st.rows.add(mkRow(s, true, true))
    }
    let v = mkRow("verify", false, false)
    v.skipped = "未连接真机"
    st.rows.add(v)
    let hint = migrateNextHint(st)
    // 没做真机验证 → 必须明确告诉人去哪做
    @Assert(hint.contains("真机验证还没做"), true)
}

@Test
public func testAskPromptCarriesChainContext(): Unit {
    let st = MigrateState()
    st.project = "habit-tree"
    st.path = "E:/test/rust/habit-tree"
    st.total = 8
    st.index = 3
    let bad = mkRow("build", true, false)
    bad.note = "exit=101"
    st.rows.add(mkRow("scan", true, true))
    st.rows.add(bad)

    let brief = StepBrief()
    brief.project = "habit-tree"
    brief.step = "build"
    brief.stepTitle = "交叉编译"
    brief.note = "exit=101 / 错误 3"
    let p = migrateAskPrompt(st, brief)
    // 必须告诉模型"这是链中的一环"，否则它只看到一个孤立报错
    @Assert(p.contains("一键迁移中断"), true)
    @Assert(p.contains("扫描分析｜通过"), true)
    @Assert(p.contains("交叉编译｜未过"), true)
    // 复用 G1/G2 的模板：现场的判断依据不能丢
    @Assert(p.contains("## 现场"), true)
    @Assert(p.contains("lingqu-cli"), true)
}

@Test
public func testLogLineIsOneLine(): Unit {
    let st = MigrateState()
    st.project = "habit-tree"
    st.total = 8
    st.done = true
    let line = migrateLogLine(st)
    @Assert(line.contains("project=habit-tree"), true)
    @Assert(line.contains("device=false"), true)
    @Assert(line.contains("\n"), false)
}

@Test
public func testMigrateIsNotOneClickRunnableButIsCliRunnable(): Unit {
    let empty = JsonObject()
    // 界面上的「一键执行 AI 建议」不许替你跑整条迁移：它改工程、占机器几分钟、还可能动真机
    let (allowed, why) = cliRunAllowed("migrate", empty)
    @Assert(allowed, false)
    @Assert(why.contains("一键迁移"), true)
    @Assert(cliAutoRunAllowed("migrate", empty), false)
    // 但 CLI 里必须能直接调——agent 靠 `lingqu-cli migrate --path …` 一条命令跑完整条链
    @Assert(cliCommandSupported("migrate"), true)
    @Assert(cliUsage().contains("lingqu-cli migrate"), true)
}

@Test
public func testDeployNoteCarriesReasonOnFailure(): Unit {
    // 两件都成：摘要里不要塞多余的 reason（那时候 reason 往往是空的，塞了也是噪音）
    let okNote = deployNoteOf(true, true, 128, true, "", "")
    @Assert(okNote.contains("装 成功"), true)
    @Assert(okNote.contains("启 成功"), true)
    @Assert(okNote.contains("128 行"), true)
    // 装成功但启动失败（0.36.0 真机实测：设备锁屏）→ 优先用 start.detail（hdc 原文 + 处置提示）
    let detail = "error: failed to start ability. ｜ 处置：设备在锁屏，拒绝自动解锁 → 解锁后重试（FP-014）"
    let badNote = deployNoteOf(true, false, 0, true, detail, "装上了但启动失败——多半是 ability 名不对")
    @Assert(badNote.contains("启 失败"), true)
    @Assert(badNote.contains("设备在锁屏"), true)
    // 英文前缀只出现一次（别叠成 "error: ... ｜ error: ..."）；分隔符也不许叠成 "｜｜"
    @Assert(badNote.contains("failed to start ability"), false)
    @Assert(badNote.contains("｜｜"), false)
    // 没有 detail 就退回 verdict.reason
    let fromReason = deployNoteOf(false, false, 3, false, "", "证书不被信任")
    @Assert(fromReason.contains("证书不被信任"), true)
    // 两样都没有：不许崩、不许写出空尾巴
    let bare = deployNoteOf(false, false, 3, false, "", "")
    @Assert(bare.contains("｜"), false)
}
