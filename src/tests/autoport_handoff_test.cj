package lingqu.tests

import lingqu.*
import std.collection.*

/*
 * 「已交接」第三态的纯函数单测（0.39.88）。
 *
 * 复现的现场（0.39.87 端到端实测）：agent 自己 `turn_done`（rounds=33 / tools=32）之后就收工了，
 * 而界面依旧写「进行中：正在处理「交叉编译」」，stalled=false / finished=false —— 用户盯了五分钟，
 * 以为它还在干活。这不是绕圈（它没在动），也不是完工（活没干完），是**第三态**。
 *
 * 判据钉在这里：三条同时成立才算交接，任何一条不成立都不许报（宁可晚报，不可谎报）。
 */

func mkHandoffRow(step: String, ran: Bool, ok: Bool): MigrateRow {
    let r = MigrateRow()
    r.step = step
    r.title = taskStepTitle(step)
    r.ran = ran
    r.ok = ok
    r.note = ""
    return r
}

/** 主路径：agent 收工 + 计划没做完 + 没工具在跑 → 判交接 */
@Test
public func testHandoffDueMainPath(): Unit {
    @Assert(handoffDue(true, false, false), true)
}

/** 已完工（8 步都有结论）不许报交接——那是正常收尾，不是卡住 */
@Test
public func testHandoffNotDueWhenConcluded(): Unit {
    @Assert(handoffDue(true, true, false), false)
}

/** 工具正在跑（分钟级编译）不许报交接——它明明在干活 */
@Test
public func testHandoffNotDueWhenBusy(): Unit {
    @Assert(handoffDue(true, false, true), false)
}

/** 这一轮还没结束（没有 turn_done）不许报交接——那是正常进行中 */
@Test
public func testHandoffNotDueWhenTurnOpen(): Unit {
    @Assert(handoffDue(false, false, false), false)
    @Assert(handoffDue(false, false, true), false)
    @Assert(handoffDue(false, true, false), false)
}

/** 交接结论要说清：谁停了、几步有结论、卡在哪一步 */
@Test
public func testHandoffVerdictNamesProgressAndBlocker(): Unit {
    let rows = ArrayList<MigrateRow>()
    rows.add(mkHandoffRow("scan", true, true))
    rows.add(mkHandoffRow("build", true, false))
    rows.add(mkHandoffRow("verify", false, false))
    let v = autoportHandoffVerdict(rows)
    @Assert(v.contains("已交接"), true)
    @Assert(v.contains("1/3"), true)
    @Assert(v.contains("卡在「" + taskStepTitle("build") + "」"), true)
    // 边界：一步都没通过时不许出现 0/0，也不许缺步骤总数
    let empty = ArrayList<MigrateRow>()
    let v2 = autoportHandoffVerdict(empty)
    @Assert(v2.contains("已交接"), true)
    @Assert(v2.contains("0/0"), true)
}

/** 升级文案要给出**下一步怎么做**，不能只说"AI 停了" */
@Test
public func testHandoffEscalationSaysWhatToDo(): Unit {
    let rows = ArrayList<MigrateRow>()
    rows.add(mkHandoffRow("scan", true, true))
    rows.add(mkHandoffRow("build", false, false))
    let e = handoffEscalation(rows)
    @Assert(e.contains("自己收工"), true)
    @Assert(e.contains("1/2"), true)
    @Assert(e.contains("继续"), true)
    @Assert(e.contains("接管"), true)
}

/** 轨迹最后一条是 turn_done → 这一轮收工了（与 agentTraceBusy 的 "tool" 互补） */
@Test
public func testTraceLastKindOfText(): Unit {
    let ended = "{\"kind\": \"tool\", \"name\": \"bash\"}\n{\"kind\": \"tool_done\"}\n{\"kind\": \"turn_done\", \"detail\": \"rounds=33\"}\n"
    @Assert(traceLastKindOfText(ended), "turn_done")
    // 边界①：尾部空行/空白行不算"最后一条"
    @Assert(traceLastKindOfText(ended + "\n\n   \n"), "turn_done")
    // 边界②：最后一条是 tool（还没有 tool_done）= 正在跑工具，不判收工
    let busy = "{\"kind\": \"turn_done\"}\n{\"kind\": \"tool\", \"name\": \"bash\"}\n"
    @Assert(traceLastKindOfText(busy), "tool")
    // 边界③：空文本不崩、也给空串（不许把"没有轨迹"当成"已收工"）
    @Assert(traceLastKindOfText(""), "")
    @Assert(traceLastKindOfText("\n   \n"), "")
}
