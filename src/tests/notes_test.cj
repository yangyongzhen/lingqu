package lingqu.tests

import lingqu.*
import lingqu.port.*
import std.collection.*
import std.fs.*

/*
 * 本地经验（`src/notes.cj`）与未命中指纹台账（`src/diagnose_miss.cj`）的纯函数单测（0.39.55）。
 *
 * 需求口径：省的不是"人有没有时间写文档"，而是**上一个样本的坑能不能自动带到下一个样本**。
 * 守的口径：
 *   ① 渲染 → 解析必须**往返一致**（四段不能串位、次数不能丢）；
 *   ② 去重按标题（忽略空白与大小写）+ **次数累加**，不是覆盖；先到的字段为准；
 *   ③ 没经验就返回空串 / 「还没有」，**不编数字**（§4-94：界面与报告里不许出现假数据）；
 *   ④ 未命中签名要**稳定**（同一形态不同数字/不同大小写得同一个签名），否则攒不出次数；
 *   ⑤ 读写盘的动作层要**幂等**（同标题追加两次 → 一条、次数 2）。
 */

// ============================================================
// 经验（notes）
// ============================================================

/** 夹具：一条典型经验（真实形状：现象带错误码，其余一句话） */
func lessonFixture(title: String, symptom: String): LessonNote {
    let n = LessonNote(title, symptom, "根因一句话", "复现一句话", "修法一句话")
    n.project = "juCang"
    n.at = "2026-11-02 10:00:00"
    return n
}

@Test
public func testRenderLessonRoundTrip(): Unit {
    let n = lessonFixture("hvigor 00308018 不是签名问题", "t2h:hap 报 00308018，日志里 cargo tauri panicked")
    let text = renderLesson(n)
    // 四段标签齐全
    @Assert(text.contains("- 现象："), true)
    @Assert(text.contains("- 根因："), true)
    @Assert(text.contains("- 复现："), true)
    @Assert(text.contains("- 修法："), true)
    let back = parseLessons(text)
    @Assert(back.size, 1)
    @Assert(back[0].title, "hvigor 00308018 不是签名问题")
    @Assert(back[0].symptom, "t2h:hap 报 00308018，日志里 cargo tauri panicked")
    @Assert(back[0].cause, "根因一句话")
    @Assert(back[0].repro, "复现一句话")
    @Assert(back[0].fix, "修法一句话")
    @Assert(back[0].occurrences, 1)
    @Assert(back[0].project, "juCang")
    @Assert(back[0].at, "2026-11-02 10:00:00")
}

@Test
public func testRenderLessonSingleLines(): Unit {
    // 字段里的换行必须被压掉，否则 `- 键：值` 结构会被撕开、解析串位
    let n = LessonNote("多行标题\n第二行", "现象第一行\n现象第二行", "根因\r\n带换行", "", "")
    let text = renderLesson(n)
    let back = parseLessons(text)
    @Assert(back.size, 1)
    @Assert(back[0].symptom.contains("\n"), false)
    @Assert(back[0].cause.contains("\r"), false)
    @Assert(back[0].symptom, "现象第一行 现象第二行")
}

@Test
public func testParseLessonsToleratesHeaderAndJunk(): Unit {
    // 文件头（# 标题）不是经验；空标题段不算一条；坏输入不许抛
    var text = "# 本地经验（灵渠自动收集）\n\n"
    text += "### 第一条\n- 现象：a\n- 根因：b\n- 复现：c\n- 修法：d\n- 次数：2　工程：p　时间：t\n\n"
    text += "### \n"
    let list = parseLessons(text)
    @Assert(list.size, 1)
    @Assert(list[0].title, "第一条")
    @Assert(list[0].occurrences, 2)
    @Assert(list[0].project, "p")
    @Assert(parseLessons("").size, 0)
    @Assert(parseLessons("   \n\n").size, 0)
}

@Test
public func testLessonKeyNormalizesCaseAndSpaces(): Unit {
    let a = LessonNote("Hvigor 00308018  hooks", "", "", "", "")
    let b = LessonNote("hvigor00308018 HOOKS", "", "", "", "")
    @Assert(lessonKeyOf(a), lessonKeyOf(b))
    let c = LessonNote("hvigor00308018 hook", "", "", "", "")
    @Assert(lessonKeyOf(a) == lessonKeyOf(c), false)
}

@Test
public func testMergeLessonsDedupesAndAccumulates(): Unit {
    let existing = ArrayList<LessonNote>()
    existing.add(lessonFixture("签名 00303074", "bundleName 与 profile 不一致"))
    let incoming = ArrayList<LessonNote>()
    // 同一条（标题只差空白）→ 次数累加，其余字段以**先到的**为准
    let again = LessonNote("签名  00303074", "第二次看到的现象", "后面的根因", "后面的复现", "后面的修法")
    again.occurrences = 3
    incoming.add(again)
    incoming.add(lessonFixture("克隆按钮点了没反应", "setCurrentProject 收到 URL"))
    let merged = mergeLessons(existing, incoming)
    @Assert(merged.size, 2)
    @Assert(merged[0].occurrences, 4)
    @Assert(merged[0].symptom, "bundleName 与 profile 不一致")
    @Assert(merged[1].title, "克隆按钮点了没反应")
}

@Test
public func testLessonsSummaryLine(): Unit {
    // 没有经验 → 空串（不编数字，报告据此决定"不提这一项"）
    @Assert(lessonsSummaryLine(ArrayList<LessonNote>()), "")
    let list = ArrayList<LessonNote>()
    list.add(lessonFixture("甲", "s"))
    list.add(lessonFixture("乙", "s"))
    list.add(lessonFixture("丙", "s"))
    let line = lessonsSummaryLine(list)
    @Assert(line.contains("3 条"), true)
    @Assert(line.contains("甲"), true)
    @Assert(line.contains("丙"), true)
    // 超过三条：列前三条 + 「等 N 条」
    list.add(lessonFixture("丁", "s"))
    let line4 = lessonsSummaryLine(list)
    @Assert(line4.contains("等 4 条"), true)
}

@Test
public func testRenderLessonsMdEmpty(): Unit {
    let md = renderLessonsMd("juCang", ArrayList<LessonNote>())
    @Assert(md.contains("juCang"), true)
    @Assert(md.contains("还没有记录任何经验"), true)
}

@Test
public func testNotesPathIsUnderProject(): Unit {
    let p = notesPathOf("E:\\work\\juCang", "juCang")
    @Assert(p.contains(".lingqu"), true)
    @Assert(p.contains(NOTES_SUBDIR), true)
    @Assert(p.endsWith("juCang.md"), true)
}

@Test
public func testAppendLessonIdempotent(): Unit {
    // 动作层（写盘）：同标题追加两次 → 一条、次数 2。目录不可写则跳过，不造假。
    let dir = ".lingqu/tmp-test-notes"
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir), recursive: true)
        }
        // 上一轮跑剩的旧档要先清掉，否则"首次必须是 added"会假失败
        let stale = Path(notesPathOf(dir, "probe"))
        if (exists(stale)) {
            remove(stale)
        }
    } catch (e: Exception) {
        return
    }
    let first = appendLesson(dir, "probe", lessonFixture("磁盘往返", "第一次"))
    @Assert(first.startsWith("added:"), true)
    let second = appendLesson(dir, "probe", lessonFixture("磁盘往返", "第二次"))
    @Assert(second.startsWith("merged:"), true)
    @Assert(second.contains("第 2 次"), true)
    let back = loadLessons(dir, "probe")
    @Assert(back.size, 1)
    @Assert(back[0].occurrences, 2)
    @Assert(back[0].symptom, "第一次")
    // 空标题：直接拒绝，不写盘
    let bad = appendLesson(dir, "probe", LessonNote("", "s", "c", "r", "f"))
    @Assert(bad.startsWith("error:"), true)
}

// ============================================================
// 候选池 + 归档（阶段 1，0.39.56）
// ============================================================

/** 夹具：一条"次数达标、四段齐全"的经验 */
func candidateFixture(title: String, times: Int64): LessonNote {
    let n = lessonFixture(title, "现象：${title}")
    n.occurrences = times
    return n
}

@Test
public func testIsLessonCompleteAndArchived(): Unit {
    let full = lessonFixture("完整的", "s")
    @Assert(isLessonComplete(full), true)
    @Assert(isLessonArchived(full), false)
    // 缺任一段都不算齐全（技能条目写不出来）
    let noFix = LessonNote("缺修法", "s", "c", "r", "")
    @Assert(isLessonComplete(noFix), false)
    let noRepro = LessonNote("缺复现", "s", "c", "", "f")
    @Assert(isLessonComplete(noRepro), false)
    // 打了入库标记 → 已入库
    let done = lessonFixture("已入库的", "s")
    done.archivedRef = "FP-021"
    @Assert(isLessonArchived(done), true)
    // 入库标记能往返（渲染 → 解析）
    let back = parseLessons(renderLesson(done))
    @Assert(back.size, 1)
    @Assert(back[0].archivedRef, "FP-021")
    // 没标记的条目解析出来是空串，不是 "None"
    @Assert(parseLessons(renderLesson(full))[0].archivedRef, "")
}

@Test
public func testCandidateLessonsFilters(): Unit {
    let list = ArrayList<LessonNote>()
    list.add(candidateFixture("次数够、四段齐", 2))       // ✓ 候选
    list.add(candidateFixture("只出现一次", 1))           // ✗ 次数不够
    let incomplete = candidateFixture("次数够但缺修法", 3)
    incomplete.fix = ""
    list.add(incomplete)                                  // ✗ 四段不齐
    let archived = candidateFixture("已入库", 5)
    archived.archivedRef = "pitfalls.md#3"
    list.add(archived)                                    // ✗ 已入库
    list.add(candidateFixture("次数高、四段齐", 9))        // ✓ 候选
    let cands = candidateLessons(list)
    @Assert(cands.size, 2)
    @Assert(cands[0].title, "次数够、四段齐")
    @Assert(cands[1].title, "次数高、四段齐")
    // 空列表不出候选，也不抛
    @Assert(candidateLessons(ArrayList<LessonNote>()).size, 0)
}

@Test
public func testSplitArchivedLessons(): Unit {
    let list = ArrayList<LessonNote>()
    list.add(lessonFixture("甲", "s"))
    let b = lessonFixture("乙", "s")
    b.archivedRef = "FP-001"
    list.add(b)
    list.add(lessonFixture("丙", "s"))
    let (archived, kept) = splitArchivedLessons(list)
    @Assert(archived.size, 1)
    @Assert(archived[0].title, "乙")
    @Assert(kept.size, 2)
    @Assert(kept[0].title, "甲")
    @Assert(kept[1].title, "丙")
}

@Test
public func testRenderPrDraft(): Unit {
    let n = candidateFixture("hvigor 00308018 不是签名问题", 2)
    n.project = "juCang"
    let draft = renderPrDraft(n)
    @Assert(draft.contains("PR 草稿"), true)
    @Assert(draft.contains("**现象**"), true)
    @Assert(draft.contains("**根因**"), true)
    @Assert(draft.contains("**复现**"), true)
    @Assert(draft.contains("**修法**"), true)
    @Assert(draft.contains("出现次数：2"), true)
    @Assert(draft.contains("工程：juCang"), true)
    @Assert(draft.contains("pitfalls.md"), true)
    // 三条"提交前确认"必须在草稿里（这是人工闸门的说明书）
    @Assert(draft.contains("实测"), true)
    @Assert(draft.contains("UDID"), true)
    @Assert(draft.contains("- 入库："), true)
}

@Test
public func testRenderCandidatesMd(): Unit {
    // 没有候选：明确写"没有"，不造空表
    let empty = renderCandidatesMd("p", ArrayList<LessonNote>(), ArrayList<String>(), ArrayList<Int64>())
    @Assert(empty.contains("本地经验候选（0 条）"), true)
    @Assert(empty.contains("没有达到门槛的经验"), true)
    @Assert(empty.contains("未命中指纹候选（同签名 ≥3 次，0 条）"), true)
    // 有候选 + 有指纹候选：三段都要有内容
    let cands = ArrayList<LessonNote>()
    cands.add(candidateFixture("候选甲", 3))
    let sigs = ArrayList<String>()
    let times = ArrayList<Int64>()
    sigs.add("error: boom")
    times.add(4)
    let md = renderCandidatesMd("p", cands, sigs, times)
    @Assert(md.contains("本地经验候选（1 条）"), true)
    @Assert(md.contains("**候选甲**"), true)
    @Assert(md.contains("出现 4 次"), true)
    @Assert(md.contains("`error: boom`"), true)
    @Assert(md.contains("逐条 PR 正文草稿（1 条）"), true)
    // 门槛写进产物，避免"为什么它没被列出来"的追问
    @Assert(md.contains("≥2 次"), true)
}

@Test
public func testArchiveLessonsMovesMarkedOnes(): Unit {
    let dir = ".lingqu/tmp-test-archive"
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir), recursive: true)
        }
        for (f in [notesPathOf(dir, "probe"), archivedNotesPathOf(dir, "probe")]) {
            if (exists(Path(f))) {
                remove(Path(f))
            }
        }
    } catch (e: Exception) {
        return
    }
    // 造两条：一条已入库、一条待裁决
    let a = lessonFixture("已沉淀的", "s")
    a.archivedRef = "FP-021"
    a.occurrences = 3
    let _ = appendLesson(dir, "probe", a)
    let b = lessonFixture("还在池子里的", "s")
    b.occurrences = 2
    let _ = appendLesson(dir, "probe", b)
    @Assert(loadLessons(dir, "probe").size, 2)
    let r = archiveLessons(dir, "probe")
    @Assert(r.archived, 1)
    @Assert(r.kept, 1)
    @Assert(r.note.startsWith("ok:"), true)
    // 主文件只剩待裁决的；归档件里有那条已入库的
    let kept = loadLessons(dir, "probe")
    @Assert(kept.size, 1)
    @Assert(kept[0].title, "还在池子里的")
    let archivedText = String.fromUtf8(File.readFrom(r.archivePath))
    @Assert(archivedText.contains("已沉淀的"), true)
    @Assert(archivedText.contains("入库：FP-021"), true)
    // 第二次跑：没有已入库的了 → 什么都不做（别写空文件冒充"归档过了"）
    let r2 = archiveLessons(dir, "probe")
    @Assert(r2.archived, 0)
    @Assert(r2.note.contains("没有已入库的经验"), true)
}

// ============================================================
// 未命中台账的候选与滚动（0.39.56）
// ============================================================

@Test
public func testMissLedgerLineCountAndSignatures(): Unit {
    let ledger = "{\"ts\":\"t\",\"sig\":\"error: boom\",\"sample\":\"a\"}\n" +
        "{\"ts\":\"t\",\"sig\":\"error: other\",\"sample\":\"b\"}\n" +
        "{\"ts\":\"t\",\"sig\":\"error: boom\",\"sample\":\"c\"}\n\n"
    @Assert(missLedgerLineCount(ledger), 3)
    let sigs = missSignatureList(ledger)
    @Assert(sigs.size, 2)
    @Assert(sigs[0], "error: boom")
    @Assert(sigs[1], "error: other")
    // 美化形态（冒号带空格）也认
    let pretty = "{\n  \"sig\": \"error: pretty\"\n}\n"
    @Assert(missSignatureList(pretty).size, 1)
    @Assert(missSignatureList(pretty)[0], "error: pretty")
    // 空/垃圾行不产生签名，也不抛
    @Assert(missSignatureList("").size, 0)
    @Assert(missSignatureList("not json\n").size, 0)
}

@Test
public func testShouldRollMissesAndFileName(): Unit {
    let few = "{\"sig\":\"a\"}\n{\"sig\":\"b\"}\n"
    @Assert(shouldRollMisses(few, 200), false)
    var many = ""
    var i: Int64 = 0
    while (i < 200) {
        many += "{\"sig\":\"s${i}\"}\n"
        i += 1
    }
    @Assert(missLedgerLineCount(many), 200)
    @Assert(shouldRollMisses(many, 200), true)
    @Assert(shouldRollMisses(few, 2), true)
    // 时间戳里的非法字符要换掉（Windows 文件名不能有 `:`）
    let name = missArchiveFileName("2026-11-02T10:20:30.123+08:00")
    @Assert(name.startsWith("misses."), true)
    @Assert(name.endsWith(".jsonl"), true)
    @Assert(name.contains(":"), false)
    @Assert(name.contains(".jsonl.jsonl"), false)
    @Assert(missArchiveFileName("").contains("unknown"), true)
}

@Test
public func testRollMissesLedgerMovesAndResets(): Unit {
    let dir = ".lingqu/tmp-test-missroll"
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir), recursive: true)
        }
        let p = diagMissLedgerPath(dir)
        if (exists(Path(p))) {
            remove(Path(p))
        }
    } catch (e: Exception) {
        return
    }
    // 没台账：明说没有，不抛
    let (n0, path0, note0) = rollMissesLedger(dir, "t0", 10)
    @Assert(n0, 0)
    @Assert(path0, "")
    @Assert(note0.contains("没有未命中台账"), true)
    // 写 3 条，阈值 10 → 不归档
    let _ = recordDiagnoseMiss(dir, "error: boom", "样例")
    let _ = recordDiagnoseMiss(dir, "error: boom", "样例")
    let _ = recordDiagnoseMiss(dir, "error: other", "样例")
    let (n1, path1, note1) = rollMissesLedger(dir, "t1", 10)
    @Assert(n1, 3)
    @Assert(path1, "")
    @Assert(note1.contains("不归档"), true)
    // 阈值降到 3 → 整体挪走，当前台账被重置
    let (n2, path2, note2) = rollMissesLedger(dir, "2026-11-02T10:20:30.123", 3)
    @Assert(n2, 3)
    @Assert(note2.startsWith("ok:"), true)
    @Assert(path2.contains("misses.2026-11-02T10-20-30-123.jsonl"), true)
    @Assert(exists(Path(path2)), true)
    @Assert(exists(Path(diagMissLedgerPath(dir))), false)
    // 归档件内容完整（证据不丢）
    let archived = String.fromUtf8(File.readFrom(path2))
    @Assert(missLedgerLineCount(archived), 3)
    @Assert(missCountOf(archived, "error: boom"), 2)
}

// ============================================================
// `--body <文件>` 的 JSON 解析（中文内容不能走 argv，见 AGENTS §4-119）
// ============================================================

@Test
public func testParseLessonBody(): Unit {
    let text = "{\"title\":\"签名 00303074\",\"symptom\":\"包名不一致\",\"cause\":\"profile 按包名签发\"," +
        "\"repro\":\"lingqu-cli hap --path .\",\"fix\":\"AGC 重新签发\"}"
    let n = parseLessonBody(text)
    @Assert(n.title, "签名 00303074")
    @Assert(n.symptom, "包名不一致")
    @Assert(n.cause, "profile 按包名签发")
    @Assert(n.repro, "lingqu-cli hap --path .")
    @Assert(n.fix, "AGC 重新签发")
    // 只有标题也行（其余留空）
    let only = parseLessonBody("{\"title\":\"只写标题\"}")
    @Assert(only.title, "只写标题")
    @Assert(only.symptom, "")
    // 坏 JSON / 非对象 / 类型不对 → 全空、不抛（上层看到空标题就拒绝写盘）
    @Assert(parseLessonBody("").title, "")
    @Assert(parseLessonBody("not json").title, "")
    @Assert(parseLessonBody("[1,2,3]").title, "")
    @Assert(parseLessonBody("{\"title\":123}").title, "")
}

@Test
public func testMissSignatureStableAcrossNumbers(): Unit {
    // 同一形态、不同数字/大小写 → 同一个签名（否则攒不出次数）
    let a = missSignatureOf("error[E0432]: unresolved import `foo` at line 12\nnext line\n")
    let b = missSignatureOf("ERROR[E0432]: unresolved import `foo` at line 987\n")
    @Assert(a.size > 0, true)
    @Assert(a, b)
    @Assert(a.contains("#"), true)
    @Assert(a.contains("12"), false)
}

@Test
public func testMissSignaturePicksErrorLineAndEmptyCases(): Unit {
    // 前面有噪声行，签名取第一条含 error / failed / panic 的行
    let sig = missSignatureOf("hvigor start\nerror: signing config missing\n")
    @Assert(sig.contains("signing config missing"), true)
    // 没有任何错误行 → 空串（不编一个假签名）
    @Assert(missSignatureOf("all good\nnothing to see\n"), "")
    @Assert(missSignatureOf(""), "")
    // 空白压缩：连续空格/制表符压成一个空格
    let sig2 = missSignatureOf("failed\t\tto    write   file\n")
    @Assert(sig2.contains("  "), false)
    @Assert(sig2.contains("failed to write file"), true)
}

@Test
public func testMissCountOf(): Unit {
    let ledger = "{\"sig\":\"error: boom\"}\n{\"sig\":\"error: other\"}\n{\"sig\":\"error: boom\"}\n"
    @Assert(missCountOf(ledger, "error: boom"), 2)
    @Assert(missCountOf(ledger, "error: other"), 1)
    @Assert(missCountOf(ledger, "error: never"), 0)
    @Assert(missCountOf("", "error: boom"), 0)
    @Assert(missCountOf(ledger, ""), 0)
    // 美化输出形态（`JsonObject.toJsonString()` 冒号后带空格）也要认，否则刚写的记录读不回来
    let pretty = "{\n  \"ts\": \"t\",\n  \"sig\": \"error: boom\",\n  \"sample\": \"s\"\n}\n"
    @Assert(missCountOf(pretty, "error: boom"), 1)
}

@Test
public func testMissCandidateHint(): Unit {
    @Assert(missCandidateHint(0), "")
    @Assert(missCandidateHint(1).contains("第 1 次"), true)
    @Assert(missCandidateHint(2).contains("补一条指纹"), true)
    @Assert(missCandidateHint(5).contains("5 次"), true)
    @Assert(missCandidateHint(5).contains("建议补指纹"), true)
}

@Test
public func testRecordDiagnoseMissAccumulates(): Unit {
    // 动作层（写盘）：同签名累加、不同签名各算各的、台账可读回
    let dir = ".lingqu/tmp-test-misses"
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir), recursive: true)
        }
        // 清掉上一轮的台账，否则累计次数会从上一轮接着数
        let stale = Path(diagMissLedgerPath(dir))
        if (exists(stale)) {
            remove(stale)
        }
    } catch (e: Exception) {
        return
    }
    let (n1, path1) = recordDiagnoseMiss(dir, "error: boom", "样例一")
    @Assert(n1, 1)
    @Assert(path1.endsWith("misses.jsonl"), true)
    let (n2, _) = recordDiagnoseMiss(dir, "error: boom", "样例二")
    @Assert(n2, 2)
    let (n3, _) = recordDiagnoseMiss(dir, "error: other", "样例三")
    @Assert(n3, 1)
    let text = String.fromUtf8(File.readFrom(path1))
    @Assert(missCountOf(text, "error: boom"), 2)
    @Assert(text.contains("样例三"), true)
    // 台账必须是**一条一行**的紧凑 JSONL（美化输出会摊成多行，按行计数就废了）
    @Assert(text.split("\n", -1).size, 4)
}

// ===== 0.39.150：notes 缺 --action 时不许"静默只读" =====

@Test
public func notesWithoutActionButWithWriteArgsIsRejected(): Unit {
    // 任务书「纪律」曾教过漏 `--action append` 的写法：那样会落进只读分支，
    // 回 ok:true 而 count:0——什么都没写却报成功（0.39.150 实测）。
    @Assert(notesMissingActionErrorOf("E:/tmp/note-in.json", "").size > 0, true)
    @Assert(notesMissingActionErrorOf("", "R2-PORT-015").size > 0, true)
    @Assert(notesMissingActionErrorOf("E:/tmp/n.json", "FP-021").size > 0, true)
    // 纯读命令（list / digest / fp-list）不带写入参数，必须照常通过
    @Assert(notesMissingActionErrorOf("", ""), "")
    @Assert(notesMissingActionErrorOf("  ", "  "), "")
}
