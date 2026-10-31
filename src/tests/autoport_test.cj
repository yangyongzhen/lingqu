package lingqu.tests

import lingqu.*
import std.collection.*

/*
 * AI 自动迁移编排层的纯函数单测（0.37.0）。
 *
 * 这一层的价值在**约束 agent 的行为**，所以断言都钉在"它不许怎么干"上：
 *   · 任务书必须说清"你是执行者不是顾问"（不然模型给完建议就停下等人）
 *   · 必须给出可复制的工具路径与"判断只认落档"
 *   · 停滞判定不许把"刚开始"误判成卡住
 */

func mkAutoRow(step: String, ran: Bool, ok: Bool, note: String): MigrateRow {
    let r = MigrateRow()
    r.step = step
    r.title = taskStepTitle(step)
    r.ran = ran
    r.ok = ok
    r.note = note
    return r
}

@Test
public func testDirectiveTellsAgentToActNotAdvise(): Unit {
    let inp = AutoPortInput()
    inp.project = "habit-tree"
    inp.projectDir = "E:/test/rust/habit-tree"
    inp.cliPath = "C:/lingqu/lingqu-cli.exe"
    inp.device = true
    let d = buildAutoPortDirective(inp)
    // ① 执行者定位（这是本轮的方向性要求，绝不能软）
    @Assert(d.contains("执行者，不是顾问"), true)
    @Assert(d.contains("不要输出"), true)
    // ② 工具路径可复制
    @Assert(d.contains("C:/lingqu/lingqu-cli.exe resume --path ."), true)
    @Assert(d.contains("--apply"), true)
    // ③ 判定只认落档
    @Assert(d.contains("判断只认落档"), true)
    @Assert(d.contains(".lingqu/"), true)
    // ④ 工作循环 / 修法上限 / 升级
    @Assert(d.contains("最多试 2 种不同修法"), true)
    @Assert(d.contains("lingqu-decision"), true)
    // ⑤ 纪律：平台限制不算失败、未验证不算通过
    @Assert(d.contains("平台限制 ≠ 失败"), true)
    @Assert(d.contains("未验证 ≠ 通过"), true)
    // ⑥ 有真机时要求跑 deploy/verify
    @Assert(d.contains("deploy"), true)
}

@Test
public func testDirectiveDegradesWhenNoCliOrDevice(): Unit {
    let inp = AutoPortInput()
    inp.project = "x"
    inp.projectDir = "E:/x"
    // 找不到 CLI 时不能写一条假的绝对路径
    inp.cliPath = ""
    inp.device = false
    let d = buildAutoPortDirective(inp)
    @Assert(d.contains("lingqu-cli resume --path ."), true)
    @Assert(d.contains("不在 PATH"), true)
    // 没真机：明确让它跳过，并且**不许**把跳过当失败
    @Assert(d.contains("跳过 deploy/verify"), true)
    @Assert(d.contains("别当成失败"), true)
}

@Test
public func testDirectiveCarriesBudgetAndState(): Unit {
    let inp = AutoPortInput()
    inp.project = "x"
    inp.projectDir = "E:/x"
    inp.budget = 12
    inp.minutes = 15
    inp.stateLines = "扫描分析｜通过｜R=24"
    let d = buildAutoPortDirective(inp)
    @Assert(d.contains("12 轮"), true)
    @Assert(d.contains("15 分钟"), true)
    // 当前落档要带进去，免得它从零开始重复跑
    @Assert(d.contains("扫描分析｜通过｜R=24"), true)
}

@Test
public func testStallDetectionNeedsEnoughIdenticalSamples(): Unit {
    let h = ArrayList<String>()
    // 样本不足：不许判卡住（刚开始那几次落档本来就一样）
    @Assert(isStalled(h, 3), false)
    h.add("a")
    h.add("a")
    @Assert(isStalled(h, 3), false)
    h.add("a")
    @Assert(isStalled(h, 3), true)
    // 一变就不算卡住
    let h2 = ArrayList<String>()
    h2.add("a")
    h2.add("a")
    h2.add("b")
    @Assert(isStalled(h2, 3), false)
    // 空签名不当卡住依据（读盘失败时宁可不报）
    let h3 = ArrayList<String>()
    h3.add("")
    h3.add("")
    h3.add("")
    @Assert(isStalled(h3, 3), false)
    // 边界：window<=1 永远 false
    @Assert(isStalled(h2, 1), false)
}

@Test
public func testSnapshotChangesWhenStepChanges(): Unit {
    let rows = ArrayList<MigrateRow>()
    rows.add(mkAutoRow("scan", true, true, "R=24"))
    rows.add(mkAutoRow("build", false, false, ""))
    let s1 = autoportSnapshot(rows)
    @Assert(s1.contains("scan:ok"), true)
    @Assert(s1.contains("build:none"), true)
    // 落档一变，签名必须跟着变（否则停滞判定会把"推进了"当成"没动"）
    rows.add(mkAutoRow("build", true, false, "exit=101"))
    let s2 = autoportSnapshot(rows)
    @Assert(s1 == s2, false)
    @Assert(s2.contains("build:bad"), true)
}

@Test
public func testSnapshotWithAgentActivityBreaksTie(): Unit {
    // 0.39.8：落档一动不动但 agent 在干活（trace 在长）时，**不许**判成绕圈。
    // 0.39.7 端到端实测：分钟级交叉编译期间落档自然不变，连续 6 次轮询就报
    // 「AI 好像在绕圈」，把正在干活的代理判死。
    let rows = ArrayList<MigrateRow>()
    rows.add(mkAutoRow("scan", true, true, "R=24"))
    rows.add(mkAutoRow("build", false, false, ""))
    // 老快照（只落档）→ 三次一样 = 卡住
    let old = autoportSnapshot(rows)
    @Assert(isStalled(threeOf(old), 3), true)
    // 带 agent 活动量：trace 在长 → 签名跟着变 → 不算卡住
    let h = ArrayList<String>()
    h.add(autoportSnapshotWith(rows, 10))
    h.add(autoportSnapshotWith(rows, 12))
    h.add(autoportSnapshotWith(rows, 15))
    @Assert(isStalled(h, 3), false)
    // 取不到 trace（负数）→ 退化成只看落档
    @Assert(autoportSnapshotWith(rows, -1), old)
    // trace 也不动了 = 真的没动静 → 仍判卡住
    let flat = ArrayList<String>()
    flat.add(autoportSnapshotWith(rows, 20))
    flat.add(autoportSnapshotWith(rows, 20))
    flat.add(autoportSnapshotWith(rows, 20))
    @Assert(isStalled(flat, 3), true)
}

@Test
public func testDirectiveHasCrossCompilePrerequisites(): Unit {
    // 0.39.7 实测：m3u8dl-tauri 的 .cargo/config.toml 有 target 段但缺 [env]，
    // ring 的 cc-rs 退回宿主 cc → build 落档 exitCode=101。任务书必须把这条写成硬前置。
    let inp = AutoPortInput()
    inp.project = "lingqu-probe-app"
    inp.projectDir = "/tmp/lingqu-probe-app"
    inp.cliPath = "/opt/lingqu-cli"
    inp.budget = 40
    inp.minutes = 40
    let d = buildAutoPortDirective(inp)
    @Assert(d.contains("CC_aarch64_unknown_linux_ohos"), true)
    @Assert(d.contains("cc-rs"), true)
    @Assert(d.contains(".cargo/config.toml"), true)
    // 回滚纪律也要写上（只回滚 Cargo.toml 会把 build 打回失败态）
    @Assert(d.contains("别只回滚"), true)
}

/** 造一份"三次相同"的历史，给停滞判定用 */
func threeOf(sig: String): ArrayList<String> {
    let h = ArrayList<String>()
    h.add(sig)
    h.add(sig)
    h.add(sig)
    return h
}

@Test
public func testAutoportVerdictStates(): Unit {
    let empty = ArrayList<MigrateRow>()
    @Assert(autoportVerdict(empty, false, false), "还没开始")

    let rows = ArrayList<MigrateRow>()
    rows.add(mkAutoRow("scan", true, true, "R=24"))
    let bad = mkAutoRow("build", true, false, "exit=101")
    rows.add(bad)
    // 进行中：说的是"正在处理哪一步"
    @Assert(autoportVerdict(rows, false, false).contains("正在处理"), true)
    // 结束（AI 回合已收）：说的是"停在哪"
    @Assert(autoportVerdict(rows, true, false).contains("停在"), true)

    // 停滞优先于其它结论（人要第一时间知道它绕圈了）
    @Assert(autoportVerdict(rows, false, true).contains("绕圈"), true)

    // 跳过不算失败
    let sk = ArrayList<MigrateRow>()
    sk.add(mkAutoRow("scan", true, true, "R=24"))
    let d = mkAutoRow("deploy", false, false, "")
    d.skipped = "未连接真机"
    sk.add(d)
    let v = autoportVerdict(sk, true, false)
    @Assert(v.contains("跳过"), true)
    @Assert(v.contains("停在"), false)
}

@Test
public func testEscalationLine(): Unit {
    @Assert(escalationLine(true, false, 30).contains("没有变化"), true)
    @Assert(escalationLine(false, true, 40).contains("40 分钟"), true)
    @Assert(escalationLine(false, false, 40), "")
}

@Test
public func testStatePushSigKeepsWindow(): Unit {
    let st = AutoPortState()
    st.reset("E:/x", "x", 10, 20)
    @Assert(st.active, true)
    for (i in 0..12) {
        st.pushSig("sig${i}")
    }
    // 只留最后 AUTOPORT_STALL_POLLS 条（否则历史无限长，判定也要扫全表）
    @Assert(Int64(st.history.size), AUTOPORT_STALL_POLLS)
    @Assert(st.history[Int64(st.history.size) - 1], "sig11")
    @Assert(st.polls, 12)
    st.stop()
    @Assert(st.active, false)
}

/* ---------- 半自动作用域（0.37.0：左侧各屏「🤖 交给 AI」与一键迁移共用一套引擎）---------- */

@Test
public func testScopeTitlesAndFullFlag(): Unit {
    @Assert(autoPortScopeTitle("port"), "规则改造")
    @Assert(autoPortScopeTitle("build"), "交叉编译")
    @Assert(autoPortScopeTitle("all"), "全流程")
    @Assert(autoPortScopeTitle(""), "全流程")
    @Assert(isFullScope("all"), true)
    @Assert(isFullScope(""), true)
    @Assert(isFullScope("port"), false)
}

@Test
public func testHalfAutoDirectiveScopesToOneStep(): Unit {
    let inp = AutoPortInput()
    inp.project = "habit-tree"
    inp.projectDir = "E:/test/rust/habit-tree"
    inp.cliPath = "C:/lingqu/lingqu-cli.exe"
    inp.device = true
    inp.scope = "port"
    let d = buildAutoPortDirective(inp)
    // 标题与范围都要点明"只做这一步"
    @Assert(d.contains("半自动"), true)
    @Assert(d.contains("规则改造"), true)
    @Assert(d.contains("只做"), true)
    // 收尾条件：读完落档 → 改代码 → 跑 build 验证 → 停下
    @Assert(d.contains(".lingqu/scan/"), true)
    @Assert(d.contains(".lingqu/deps/"), true)
    @Assert(d.contains("build --path ."), true)
    // 关键约束：做完就停，不许顺手做后面几步
    @Assert(d.contains("做完就停"), true)
    @Assert(d.contains("不要顺手把后面的步骤也做了"), true)
    // 仍然是"执行者不是顾问"
    @Assert(d.contains("执行者，不是顾问"), true)
}

@Test
public func testFullAutoDirectiveHasNoHalfAutoClause(): Unit {
    let inp = AutoPortInput()
    inp.project = "x"
    inp.projectDir = "E:/x"
    inp.scope = "all"
    let d = buildAutoPortDirective(inp)
    @Assert(d.contains("全流程"), true)
    // 全自动不该出现"做完就停"（那是半自动的约束，出现就说明两档混了）
    @Assert(d.contains("做完就停"), false)
}

@Test
public func testKickoffStaysShortAndPointsAtFile(): Unit {
    // 0.37.2 的教训：任务书整段单帧发不进去（4.4KB 被静默丢弃），改为落文件 + 短 kickoff。
    // 这条断言钉住"短"——否则等于把问题搬回去。
    let k = buildAutoPortKickoff("E:/x/.lingqu/autoport-directive.md")
    @Assert(k.contains("E:/x/.lingqu/autoport-directive.md"), true)
    @Assert(k.contains("read"), true)
    @Assert(k.contains("resume"), true)
    @Assert(k.size < 400, true)
}

@Test
public func testEveryScopeHasAGoal(): Unit {
    // 每个 scope 都要有收尾条件，否则半自动任务书会缺一段（写漏了 AI 会自己发挥）
    for (s in ["port", "deps", "build", "hap", "sign", "deploy", "verify"]) {
        let g = autoPortScopeGoal(s)
        @Assert(g.size > 20, true)
        @Assert(g.contains("做完"), true)
    }
    // 未知 scope：空串（调用方据此退回全自动文案，不编一段假目标）
    @Assert(autoPortScopeGoal("nope"), "")
    @Assert(autoPortScopeGoal("all"), "")
}
