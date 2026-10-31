package lingqu.tests

import lingqu.*

/*
 * T6-5 断点续迁的纯函数单测（D-009：只测纯函数；读写盘与真机流程以实机为准）。
 *
 * 这里守的三条口径，改代码前先想清楚：
 *   ① 落档不存在 = 没跑过（pending），**不是失败**，也不能算完成；
 *   ② 落档存在但判定没过 = failed（存在 ≠ 成功）；
 *   ③ 人工跳过（skipped）算"有结论"，断点要越过它——但它不是通过，所以进度里单列。
 */

@Test
public func testTaskStepsOrdered(): Unit {
    let ids = taskStepIds()
    @Assert(ids.size, 8)
    // 顺序就是执行顺序：扫描在前、验证在后
    @Assert(ids[0], "scan")
    @Assert(ids[ids.size - 1], "verify")
    @Assert(taskStepIndex("port"), 2)
    @Assert(taskStepIndex("build"), 3)
    // 不认识的一律 -1 / 原样回标题（界面别显示空白）
    @Assert(taskStepIndex("nope"), -1)
    @Assert(taskStepTitle("nope"), "nope")
    @Assert(taskStepTitle("hap"), "HAP 装配")
    // 步骤 id 不重复（重复会让 findStep 永远返回第一个，断点定位就错了）
    for (i in 0..ids.size) {
        for (j in (i + 1)..ids.size) {
            @Assert(ids[i] == ids[j], false)
        }
    }
}

@Test
public func testTaskArtifactPath(): Unit {
    // 一般步骤：.lingqu/<id>/<工程>.json
    @Assert(taskArtifactPath("habit-tree", "scan"), ".lingqu/scan/habit-tree.json")
    @Assert(taskArtifactPath("habit-tree", "verify"), ".lingqu/verify/habit-tree.json")
    // port 是历史例外：落档在目录里（逐文件备份 + decisions.json）
    @Assert(taskArtifactPath("habit-tree", "port"), ".lingqu/port/habit-tree/decisions.json")
    // 未知步骤不给路径（别造出一个不存在的落档位置，那会让观测假 pass）
    @Assert(taskArtifactPath("habit-tree", "nope"), "")
}

@Test
public func testNormalizeTaskStatus(): Unit {
    @Assert(normalizeTaskStatus("done"), "done")
    // 大小写与空白容错（手改过 tasks.json 是常态）
    @Assert(normalizeTaskStatus(" DONE "), "done")
    @Assert(normalizeTaskStatus("Failed"), "failed")
    @Assert(normalizeTaskStatus("skipped"), "skipped")
    @Assert(normalizeTaskStatus("RUNNING"), "running")
    // 不认识的**绝不猜成 done**
    @Assert(normalizeTaskStatus("bogus"), "pending")
    @Assert(normalizeTaskStatus(""), "pending")
    @Assert(normalizeTaskStatus("success"), "pending")
}

@Test
public func testReconcileStepStatus(): Unit {
    // 落档在且判定过 → done（哪怕旧状态是 failed）
    @Assert(reconcileStepStatus("failed", true, true), "done")
    // 落档在但判定没过 → failed（存在 ≠ 成功，与 verify 同一口径）
    @Assert(reconcileStepStatus("pending", true, false), "failed")
    @Assert(reconcileStepStatus("done", true, false), "failed")
    // 落档不在 → 回到 pending（"上次跑过"不可信）
    @Assert(reconcileStepStatus("done", false, false), "pending")
    @Assert(reconcileStepStatus("failed", false, false), "pending")
    // 人工跳过要保留：断点会越过它，但别把人的判断冲掉
    @Assert(reconcileStepStatus("skipped", false, false), "skipped")
    @Assert(reconcileStepStatus("SKIPPED", false, false), "skipped")
}

@Test
public func testFirstUnfinishedAndProgress(): Unit {
    let board = newTaskBoard()
    @Assert(board.steps.size, 8)
    // 全新的板子：断点是第一步
    @Assert(firstUnfinished(board), "scan")
    let p0 = taskProgress(board)
    @Assert(p0.done, 0)
    @Assert(p0.total, 8)
    @Assert(p0.percent, 0)

    // scan done、deps skipped（人工判定做不了）、port failed → 断点在 port
    markTaskStep(board, "scan", "done", "t1", "")
    markTaskStep(board, "deps", "skipped", "t2", "不需要")
    markTaskStep(board, "port", "failed", "t3", "规则失败")
    @Assert(firstUnfinished(board), "port")
    let p1 = taskProgress(board)
    @Assert(p1.done, 1)
    @Assert(p1.skipped, 1)
    @Assert(p1.failed, 1)
    // skipped 算"已完成"计入百分比：(1 + 1) * 100 / 8 = 25
    @Assert(p1.percent, 25)

    // 全部有结论 → 断点为空（可以出报告）
    for (id in taskStepIds()) {
        markTaskStep(board, id, "done", "t4", "")
    }
    @Assert(firstUnfinished(board), "")
    @Assert(taskProgress(board).percent, 100)
    @Assert(stepIsSettled("skipped"), true)
    @Assert(stepIsSettled("done"), true)
    @Assert(stepIsSettled("failed"), false)
    @Assert(stepIsSettled("pending"), false)
    @Assert(stepIsSettled("running"), false)
}

@Test
public func testResumeHint(): Unit {
    let board = newTaskBoard()
    // 全新：说"下一步是 X"
    @Assert(resumeHint(board).contains("下一步"), true)
    @Assert(resumeHint(board).contains("扫描分析"), true)
    // 失败：说"停在 X 失败"，并给出处置动作
    markTaskStep(board, "scan", "done", "t", "")
    markTaskStep(board, "deps", "failed", "t", "")
    let h = resumeHint(board)
    @Assert(h.contains("依赖评估"), true)
    @Assert(h.contains("失败"), true)
    // 全部有结论：提示可以出报告，而不是"继续"
    for (id in taskStepIds()) {
        markTaskStep(board, id, "done", "t", "")
    }
    @Assert(resumeHint(board).contains("全部"), true)
}

@Test
public func testParseTaskBoardTolerant(): Unit {
    // 空文本 / 坏 JSON → 八步 pending（不能因为文件坏了就当成"没步骤"）
    @Assert(parseTaskBoard("").steps.size, 8)
    @Assert(parseTaskBoard("not json at all").steps.size, 8)
    @Assert(firstUnfinished(parseTaskBoard("not json at all")), "scan")

    // 手工改过的板子：大写状态、未知步骤 id、缺字段
    let text = "{\"project\":\"habit-tree\",\"path\":\"E:/work/habit-tree\"," +
        "\"sessionId\":\"sess-42\",\"steps\":[" +
        "{\"id\":\"scan\",\"status\":\"DONE\",\"note\":\"清单 68 条\"}," +
        "{\"id\":\"deps\",\"status\":\"failed\"}," +
        "{\"id\":\"unknown-step\",\"status\":\"done\"}]}"
    let board = parseTaskBoard(text)
    @Assert(board.project, "habit-tree")
    @Assert(board.sessionId, "sess-42")
    @Assert(board.steps.size, 8)
    @Assert(board.statusOf("scan"), "done")
    @Assert(board.statusOf("deps"), "failed")
    @Assert(board.statusOf("port"), "pending")
    // 观测到的摘要要保留（界面直接显示这句）
    match (board.findStep("scan")) {
        case Some(s) => @Assert(s.note, "清单 68 条")
        case None => @Assert(false, true)
    }
    // 未知 id 不污染板子
    @Assert(board.statusOf("unknown-step"), "")
    // deps 是 failed（不是 settled）→ 断点就停在 deps，而不是跳过它去 port
    @Assert(firstUnfinished(board), "deps")
}

@Test
public func testMarkAndRedo(): Unit {
    let board = newTaskBoard()
    // 不认识的步骤 → false（别静默成功，界面会以为记上了）
    @Assert(markTaskStep(board, "nope", "done", "t", ""), false)
    @Assert(redoFromStep(board, "nope"), false)

    @Assert(markTaskStep(board, "scan", "done", "2026-11-01 10:00:00", "R=24"), true)
    @Assert(markTaskStep(board, "deps", "done", "2026-11-01 10:01:00", ""), true)
    @Assert(markTaskStep(board, "port", "done", "2026-11-01 10:02:00", ""), true)
    @Assert(markTaskStep(board, "build", "done", "2026-11-01 10:03:00", ""), true)
    match (board.findStep("scan")) {
        case Some(s) =>
            @Assert(s.at, "2026-11-01 10:00:00")
            @Assert(s.note, "R=24")
        case None => @Assert(false, true)
    }

    // 从 build 重来：build 及其之后回 pending，之前的保持完成
    @Assert(redoFromStep(board, "build"), true)
    @Assert(board.statusOf("port"), "done")
    @Assert(board.statusOf("build"), "pending")
    @Assert(board.statusOf("verify"), "pending")
    @Assert(firstUnfinished(board), "build")
    // 重置要清掉时间戳（不然界面会显示一个"pending 但有过时间"的怪状态）
    match (board.findStep("build")) {
        case Some(s) => @Assert(s.at, "")
        case None => @Assert(false, true)
    }
}

@Test
public func testTaskBoardJsonRoundTrip(): Unit {
    let board = newTaskBoard()
    board.project = "habit-tree"
    board.path = "E:\\test\\rust\\habit-tree"
    board.updatedAt = "2026-11-01 11:00:00"
    board.sessionId = "sess-7"
    markTaskStep(board, "scan", "done", "2026-11-01 10:00:00", "清单 68 条")
    markTaskStep(board, "deps", "skipped", "2026-11-01 10:01:00", "本工程无 Rust 依赖")

    let text = board.toJsonString()
    let back = parseTaskBoard(text)
    @Assert(back.project, "habit-tree")
    @Assert(back.sessionId, "sess-7")
    @Assert(back.statusOf("scan"), "done")
    @Assert(back.statusOf("deps"), "skipped")
    @Assert(back.statusOf("port"), "pending")
    @Assert(firstUnfinished(back), "port")
    // 序列化里必须带"从哪一步继续"，报告/界面直接引用，不用各自算
    @Assert(text.contains("\"next\""), true)
    @Assert(text.contains("lingqu/tasks/v1"), true)
}
