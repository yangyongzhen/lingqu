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

/**
 * 0.39.41：**活干完了不许喊"绕圈"**（用户实测：迁移全绿、报告已生成，
 * 界面还在说「AI 连续 20 次轮询落档没有变化，建议点「停止」」）。
 *
 * 三条判据：① 全部步骤有结论 ⇒ `autoportAllConcluded` 为真；
 * ② 此时 `escalationLineFor(..., finished=true)` 必须返回空串（不叫人）；
 * ③ 跳过也算"有结论"（没插设备的真机步骤不该拖着不让判完工）。
 */
@Test
public func testAllConcludedSuppressesStall(): Unit {
    // 三步全通过
    let allOk = ArrayList<MigrateRow>()
    allOk.add(mkAutoRow("scan", true, true, "R=24"))
    allOk.add(mkAutoRow("build", true, true, "exit=0"))
    allOk.add(mkAutoRow("hap", true, true, "signed=true"))
    @Assert(autoportConcludedCount(allOk), 3)
    @Assert(autoportAllConcluded(allOk), true)

    // 通过 + 明确跳过（未连接真机）也算全部有结论
    let withSkip = ArrayList<MigrateRow>()
    withSkip.add(mkAutoRow("scan", true, true, "R=24"))
    let dp = mkAutoRow("deploy", false, false, "")
    dp.skipped = "未连接真机"
    withSkip.add(dp)
    @Assert(autoportDoneCount(withSkip), 1)
    @Assert(autoportConcludedCount(withSkip), 2)
    @Assert(autoportAllConcluded(withSkip), true)

    // 还有一步没跑 → 不算完工
    let notYet = ArrayList<MigrateRow>()
    notYet.add(mkAutoRow("scan", true, true, "R=24"))
    notYet.add(mkAutoRow("build", false, false, ""))
    @Assert(autoportConcludedCount(notYet), 1)
    @Assert(autoportAllConcluded(notYet), false)

    // 空行表不能当成"完工"（否则刚开跑就不判停滞了）
    let empty = ArrayList<MigrateRow>()
    @Assert(autoportAllConcluded(empty), false)

    // 完工 ⇒ 升级文案必须为空（哪怕 stalled 传了 true）
    @Assert(escalationLineFor(true, false, 30, true), "")
    @Assert(escalationLineFor(false, true, 50, true), "")
    // 没完工时行为不变
    @Assert(escalationLineFor(true, false, 30, false).contains("没有变化"), true)
}

@Test
public func testStatePushSigKeepsWindow(): Unit {
    let st = AutoPortState()
    st.reset("E:/x", "x", 10, 20)
    @Assert(st.active, true)
    // 推 window 条数再多推 5 条：窗口只保留最后 AUTOPORT_STALL_POLLS 条。
    // 用常量驱动（0.39.6 把阈值 6 → 20，硬编码条数的用例会假红）
    let pushes = AUTOPORT_STALL_POLLS + 5
    for (i in 0..pushes) {
        st.pushSig("sig${i}")
    }
    @Assert(Int64(st.history.size), AUTOPORT_STALL_POLLS)
    @Assert(st.history[Int64(st.history.size) - 1], "sig${pushes - 1}")
    @Assert(st.polls, pushes)
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

@Test
public func testAutoPortStateClearHistoryKeepsPolls(): Unit {
    // agent 正在跑工具时清快照：窗口重开，但 polls 计数保留（进度显示要用）
    let st = AutoPortState()
    st.pushSig("a")
    st.pushSig("a")
    st.pushSig("a")
    @Assert(st.polls, 3)
    @Assert(isStalled(st.history, 3), true)
    st.clearHistory()
    @Assert(Int64(st.history.size), 0)
    @Assert(st.polls, 3)
    @Assert(isStalled(st.history, 3), false)
}

@Test
public func testStallWindowIsLongerThanOneLlmTurn(): Unit {
    // 轮询 900ms：阈值必须明显大于一次 LLM 思考（5-30s），否则正常停顿就误报。
    // 0.39.7 把阈值设成 6（≈5.4s），端到端实跑反复误报。
    @Assert(AUTOPORT_STALL_POLLS >= 15, true)
}

@Test
public func testBusyExemptHasUpperBound(): Unit {
    // 「正在跑工具」的豁免必须有上限：工具挂死后 busy 不能永久压住停滞判定
    // （2026-11-07 实测：引擎的 find / 把工具调用挂住 565s+，界面只剩"执行中"）
    @Assert(busyStillExempt(0, AUTOPORT_BUSY_MAX_SECS), true)
    @Assert(busyStillExempt(AUTOPORT_BUSY_MAX_SECS - 1, AUTOPORT_BUSY_MAX_SECS), true)
    @Assert(busyStillExempt(AUTOPORT_BUSY_MAX_SECS, AUTOPORT_BUSY_MAX_SECS), false)
    @Assert(busyStillExempt(565, AUTOPORT_BUSY_MAX_SECS), false)  // 挂死现场的实际读数
    // 上限 <= 0 = 不设限：显式关掉这道闸时不能反过来一直判停滞
    @Assert(busyStillExempt(99999, 0), true)
}

@Test
public func testNoteBusyMeasuresSecondsSinceToolStart(): Unit {
    let st = AutoPortState()
    // 首次见到 busy：只是记下起点
    @Assert(st.noteBusy(1000), 0)
    // 同一时刻再问：仍是 0，且起点不被刷新（否则永远算不出年龄）
    @Assert(st.noteBusy(1000), 0)
    // 5.6 秒后：向下取整到 5 秒
    @Assert(st.noteBusy(6600), 5)
    // 工具结束 → 计时清零，下一条工具重新起算
    st.clearBusy()
    @Assert(st.noteBusy(7000), 0)
    @Assert(st.noteBusy(9000), 2)
    // 新一轮迁移不该继承上一轮的计时
    st.reset("/p", "p", 120, 40)
    @Assert(st.noteBusy(12000), 0)
}

@Test
public func testDirectiveForbidsFullDiskSearch(): Unit {
    // 2026-11-07 事故：agent 为找 gen/ohos 跑 `find /` 全盘扫描，把工具调用挂死 565s+
    let inp = AutoPortInput()
    inp.project = "demo"
    inp.projectDir = "C:/work/demo"
    inp.scope = "all"
    let d = buildAutoPortDirective(inp)
    @Assert(d.contains("禁止全盘搜索"), true)
    @Assert(d.contains("find /"), true)
    // 必须同时给出"正确找法"，否则纪律只是一句禁令
    @Assert(d.contains("<工程>/gen/ohos"), true)
    @Assert(d.contains("<工程>/src-tauri/gen/ohos"), true)
    @Assert(d.contains("如实报告缺脚手架"), true)
}

@Test
public func testDirectiveTellsAgentHowToSignAndLogin(): Unit {
    // 2026-11-07 实测：任务书只写了 `sign --path .`，没写 CLI 早就有的 `--login` / `--auto`，
    // agent 于是自己开浏览器登录 AGC 网页（拿不到 tempToken、不注册设备），白花一次人工介入。
    let inp = AutoPortInput()
    inp.project = "demo"
    inp.projectDir = "C:/work/demo"
    inp.cliPath = "C:/lingqu/lingqu-cli.exe"
    inp.scope = "all"
    inp.device = true
    let d = buildAutoPortDirective(inp)
    // ① 两条真实存在的入口都要给到，且带可复制的绝对路径
    @Assert(d.contains("C:/lingqu/lingqu-cli.exe sign   --login"), true)
    @Assert(d.contains("C:/lingqu/lingqu-cli.exe sign   --auto --path ."), true)
    // ② 顺序写死：体检 → 登录 → 自动签发 → 重跑 hap
    @Assert(d.contains("## 签名与登录"), true)
    @Assert(d.contains("device-ids"), true)
    // ③ 明确「登录只能人做」，并且**禁止它自己开浏览器假扮**
    @Assert(d.contains("必须人在浏览器里授权一次"), true)
    @Assert(d.contains("不要自己 `start` / `rundll32` / `open`"), true)
    @Assert(d.contains("tempToken"), true)
    // ④ 要人介入时该说清的三件事（少一件人就得猜）
    @Assert(d.contains("为什么必须登录"), true)
    @Assert(d.contains("本机 UDID"), true)
    // ⑤ 报错对照：四种典型必须都在，别让 agent 拿 9568322 去瞎改代码
    @Assert(d.contains("9568320"), true)
    @Assert(d.contains("9568322"), true)
    @Assert(d.contains("00303074"), true)
    @Assert(d.contains("00303242"), true)
    // ⑥ 底线：不许伪造签名 / 改包名蹭别人 profile
    @Assert(d.contains("不许伪造签名"), true)
    @Assert(d.contains("不许改 `bundleName`"), true)
}

@Test
public func testSignScopeDirectiveAlsoCarriesLoginPath(): Unit {
    // 半自动「只做签名」这一步时同样要给出登录与自动签发，
    // 否则"点签名这一步"反而比全自动知道得更少（同一知识不能只在一条分支里）
    let inp = AutoPortInput()
    inp.project = "demo"
    inp.projectDir = "C:/work/demo"
    inp.scope = "sign"
    let d = buildAutoPortDirective(inp)
    @Assert(d.contains("sign --login"), true)
    @Assert(d.contains("sign --auto --path ."), true)
    @Assert(d.contains("不要自己开浏览器登录 AGC 网页"), true)
    // 半自动仍要"做完就停"
    @Assert(d.contains("做完停下"), true)
}