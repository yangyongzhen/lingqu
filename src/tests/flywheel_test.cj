package lingqu.tests

import lingqu.*
import lingqu.port.*
import std.collection.*

/*
 * 0.39.113 单测：飞轮阶段 4「用户级认知层」（`~/.lingqu/flywheel/`）。
 *
 * 只测**纯函数**（D-009：进程/网络/WebView2/真机不进单测）。这里钉住四条口径：
 *   ① 目录解析：覆盖值优先、两种分隔符都认、home 为空**不许**回落 CWD；
 *   ② 用户库 JSON 容错：坏 JSON / 少了 marker 的条目 → 不抛、不污染匹配顺序；
 *   ③ 合并优先级：用户级排前 + 同 id 用用户版本（顺序即匹配顺序，§4-150）；
 *   ④ 幂等：重跑归档不许让"次数"虚增（假数据比没有更坏，§4-94 同族）。
 *
 * 磁盘读写不在这里造假绿——真实链路用真二进制 + `LINGQU_FLYWHEEL_DIR` 指向临时目录跑一遍，
 * 证据记在 docs/进度记录.md。
 */

func fpOf(id: String, marker: String): Fingerprint {
    return Fingerprint(id, marker, "根因", "修法", "", PK_GUIDE)
}

func noteOf(title: String, occurrences: Int64): LessonNote {
    let n = LessonNote(title, "现象", "根因", "复现", "修法")
    n.occurrences = occurrences
    return n
}

// ===== ① 目录与路径解析 =====

@Test
public func userFlywheelDirUsesOverrideFirst(): Unit {
    // 覆盖值优先；末尾分隔符要剥掉，`/` 与 `\` 两种都认（§4-26 同族：只认一种必翻车）
    @Assert(userFlywheelDirOf("E:/tmp/fw", "C:/Users/x"), "E:/tmp/fw")
    @Assert(userFlywheelDirOf("E:\\tmp\\fw\\", "C:/Users/x"), "E:\\tmp\\fw")
    @Assert(userFlywheelDirOf("  E:/tmp/fw/  ", "C:/Users/x"), "E:/tmp/fw")
    // home 为空 → 空串：写盘前就能判出"定位不到用户级目录"，
    // 不许默默落到当前工作目录把"用户级"降级成"工程级"（还看不出来）
    @Assert(userFlywheelDirOf("", ""), "")
}

@Test
public func userFlywheelDirFallsBackToHome(): Unit {
    let d = userFlywheelDirOf("", "C:/Users/x")
    @Assert(d.contains(".lingqu"), true)
    @Assert(d.endsWith("flywheel"), true)
    @Assert(d.startsWith("C:/Users/x"), true)
}

@Test
public func userPathsLiveUnderDirAndEmptyWithoutDir(): Unit {
    @Assert(userFingerprintsPathOf("E:/fw").endsWith("fingerprints.json"), true)
    @Assert(userLessonsPathOf("E:/fw").endsWith("lessons.md"), true)
    @Assert(userRulesPathOf("E:/fw").endsWith("rules.json"), true)
    @Assert(userSkillsDirOf("E:/fw").endsWith("skills"), true)
    // 没有目录就一律空串（否则会拼出裸文件名落到 CWD）
    @Assert(userFingerprintsPathOf(""), "")
    @Assert(userLessonsPathOf(""), "")
    @Assert(userRulesPathOf(""), "")
    @Assert(userSkillsDirOf(""), "")
}

@Test
public func archiveTargetNormalizesAndRejectsUnknown(): Unit {
    @Assert(archiveTargetOf(""), ARCHIVE_TO_USER)
    @Assert(archiveTargetOf("  user "), ARCHIVE_TO_USER)
    @Assert(archiveTargetOf("repo"), ARCHIVE_TO_REPO)
    // 认不出必须给空串：默默当 user 会让用户以为经验进了 PR 队列，其实只在本机
    @Assert(archiveTargetOf("master"), "")
}

// ===== ② 用户库 JSON 的容错 =====

@Test
public func parseUserFingerprintsAcceptsBothTopShapes(): Unit {
    let bare = "[{\"id\":\"FP-U001\",\"marker\":\"boom\",\"fix\":\"改\"}]"
    let bareList = parseFingerprintsJson(bare)
    @Assert(bareList.size, 1)
    @Assert(bareList[0].id, "FP-U001")
    @Assert(bareList[0].marker, "boom")

    let wrapped = "{\"fingerprints\":[{\"id\":\"FP-U002\",\"marker\":\"bang\"}]}"
    let w = parseFingerprintsJson(wrapped)
    @Assert(w.size, 1)
    @Assert(w[0].id, "FP-U002")
}

@Test
public func parseUserFingerprintsIsLenient(): Unit {
    // 坏 JSON → 空表，绝不抛（这是**用户手写**的文件，一个逗号写错不该让诊断功能瞎掉）
    @Assert(parseFingerprintsJson("{oops").size, 0)
    // 顶层不是数组/容器对象 → 空表
    @Assert(parseFingerprintsJson("\"hello\"").size, 0)
    @Assert(parseFingerprintsJson("{\"fingerprints\":42}").size, 0)
    // 空文本 → 空表
    @Assert(parseFingerprintsJson("   ").size, 0)
    // 少 marker 的条目直接丢（认不出来的指纹只会污染匹配顺序）
    let mixed = "[{\"id\":\"FP-U003\"},{\"marker\":\"no-id\"},{\"id\":\"FP-U004\",\"marker\":\"ok\"}]"
    let l = parseFingerprintsJson(mixed)
    @Assert(l.size, 1)
    @Assert(l[0].id, "FP-U004")
}

@Test
public func parseUserFingerprintDefaultsPatchKindToGuide(): Unit {
    // 缺 / 乱写 patchKind 一律按 guide：guide 只给根因与修法，
    // 不会让 agent 去跑一个"用户以为存在"的确定性改造（保守优先）
    let l = parseFingerprintsJson("[{\"id\":\"FP-U010\",\"marker\":\"m1\"}]")
    @Assert(l[0].patchKind, PK_GUIDE)
    let bad = parseFingerprintsJson("[{\"id\":\"FP-U011\",\"marker\":\"m2\",\"patchKind\":\"whatever\"}]")
    @Assert(bad[0].patchKind, PK_GUIDE)
    let rule = parseFingerprintsJson("[{\"id\":\"FP-U012\",\"marker\":\"m3\",\"patchKind\":\"rule\"}]")
    @Assert(rule[0].patchKind, PK_RULE)
}

// ===== ③ 合并优先级 =====

@Test
public func mergePutsUserFirstAndOverridesById(): Unit {
    let builtin = ArrayList<Fingerprint>()
    builtin.add(fpOf("FP-001", "内置一"))
    builtin.add(fpOf("FP-002", "内置二"))
    builtin.add(fpOf("FP-003", "内置三"))
    let user = ArrayList<Fingerprint>()
    user.add(fpOf("FP-U001", "用户新增"))
    user.add(fpOf("FP-002", "用户改写的第二条"))

    let lib = mergeFingerprintLibraries(builtin, user)
    @Assert(lib.size, 4)
    // 用户级排前：刚学到的坑通常比内置泛串更具体，而本表顺序即匹配顺序（§4-150）
    @Assert(lib[0].id, "FP-U001")
    @Assert(lib[1].id, "FP-002")
    // 同 id 用用户版本（id 是身份不是位置）
    @Assert(lib[1].marker, "用户改写的第二条")
    // 内置其余按原顺序追加，且不重复
    @Assert(lib[2].id, "FP-001")
    @Assert(lib[3].id, "FP-003")
    @Assert(lib[3].marker, "内置三")
}

@Test
public func mergeKeepsFirstWhenUserFileRepeatsId(): Unit {
    let builtin = ArrayList<Fingerprint>()
    builtin.add(fpOf("FP-001", "内置一"))
    let user = ArrayList<Fingerprint>()
    user.add(fpOf("FP-900", "先写的"))
    user.add(fpOf("FP-900", "后写的笔误"))
    let lib = mergeFingerprintLibraries(builtin, user)
    @Assert(lib.size, 2)
    @Assert(lib[0].marker, "先写的")
}

@Test
public func libraryWithEmptyUserJsonIsBuiltinItself(): Unit {
    let lib = fingerprintLibraryWithUser("")
    @Assert(lib.size == fingerprintLibrary().size, true)
    // 坏 JSON 也一样：退回内置库，不抛
    @Assert(fingerprintLibraryWithUser("{bad").size == fingerprintLibrary().size, true)
}

// ===== ④ 用户级指纹写入（upsert 幂等）=====

@Test
public func nextUserIdSkipsBuiltinAndCountsUp(): Unit {
    let empty = ArrayList<Fingerprint>()
    @Assert(nextUserIdOf(empty), "FP-U001")
    let lib = ArrayList<Fingerprint>()
    lib.add(fpOf("FP-001", "内置"))
    lib.add(fpOf("FP-U004", "已有的用户级"))
    // 内置 id 不参与编号，用户级取最大号 +1
    @Assert(nextUserIdOf(lib), "FP-U005")
    let many = ArrayList<Fingerprint>()
    many.add(fpOf("FP-U009", "a"))
    @Assert(nextUserIdOf(many), "FP-U010")
}

@Test
public func upsertReplacesByIdAndAppendsNew(): Unit {
    let existing = "[\n  {\"id\":\"FP-U001\",\"marker\":\"old\"},\n  {\"id\":\"FP-U002\",\"marker\":\"keep\"}\n]\n"
    let incoming = ArrayList<Fingerprint>()
    incoming.add(fpOf("FP-U001", "new"))
    incoming.add(fpOf("FP-U003", "added"))
    let up = upsertUserFingerprints(existing, incoming)
    @Assert(up.added, 1)
    @Assert(up.replaced, 1)
    @Assert(up.total, 3)
    // 写出来的文本必须能读回（JSON 转义靠对象 toJsonString()，别手拼）
    let back = parseFingerprintsJson(up.text)
    @Assert(back.size, 3)
    @Assert(back[0].marker, "new")
    @Assert(back[1].marker, "keep")
    @Assert(back[2].marker, "added")
}

@Test
public func upsertIsIdempotentOnRerun(): Unit {
    // 归档/写指纹都是**幂等**动作：同一批再写一次只能"覆盖 N 条"，不许"又新增 N 条"
    let incoming = ArrayList<Fingerprint>()
    incoming.add(fpOf("FP-U001", "same"))
    let first = upsertUserFingerprints("", incoming)
    @Assert(first.added, 1)
    @Assert(first.replaced, 0)
    let second = upsertUserFingerprints(first.text, incoming)
    @Assert(second.added, 0)
    @Assert(second.replaced, 1)
    @Assert(second.total, 1)
}

@Test
public func renderUserFingerprintsIsOneLinePerEntry(): Unit {
    let list = ArrayList<Fingerprint>()
    list.add(fpOf("FP-U001", "带\"引号\"的串"))
    list.add(fpOf("FP-U002", "第二"))
    let text = renderUserFingerprints(list)
    // 一条一行（便于人眼 diff）+ 引号必须被转义（手拼就坏了）
    @Assert(text.contains("\\\""), true)
    @Assert(text.size < 400, true)
    let back = parseFingerprintsJson(text)
    @Assert(back.size, 2)
    @Assert(back[0].marker, "带\"引号\"的串")
}

// ===== ⑤ fp-add 的 body 解析 =====

@Test
public func parseUserFpBodyAutoNumbersMissingId(): Unit {
    let existing = ArrayList<Fingerprint>()
    existing.add(fpOf("FP-U001", "旧"))
    let one = "{\"marker\":\"新坑\",\"rootCause\":\"根因\",\"fix\":\"修法\"}"
    let (list, err) = parseUserFpBody(one, existing)
    @Assert(err, "")
    @Assert(list.size, 1)
    @Assert(list[0].id, "FP-U002")
    @Assert(list[0].marker, "新坑")
}

@Test
public func parseUserFpBodyNumbersBatchDistinctly(): Unit {
    // 一批里两条都不带 id：必须拿到 FP-U001 / FP-U002，不许都算成 U001（会互相覆盖）
    let existing = ArrayList<Fingerprint>()
    let body = "[{\"marker\":\"a\"},{\"marker\":\"b\"}]"
    let (list, err) = parseUserFpBody(body, existing)
    @Assert(err, "")
    @Assert(list.size, 2)
    @Assert(list[0].id, "FP-U001")
    @Assert(list[1].id, "FP-U002")
}

@Test
public func parseUserFpBodyRejectsMarkerlessAndGarbage(): Unit {
    let existing = ArrayList<Fingerprint>()
    let (l1, e1) = parseUserFpBody("{\"id\":\"FP-U001\"}", existing)
    @Assert(e1.contains("marker"), true)
    @Assert(l1.size, 0)
    let (l2, e2) = parseUserFpBody("{bad json", existing)
    @Assert(e2.startsWith("error:"), true)
    @Assert(l2.size, 0)
    let (l3, e3) = parseUserFpBody("   ", existing)
    @Assert(e3.startsWith("error:"), true)
    @Assert(l3.size, 0)
    let (l4, e4) = parseUserFpBody("[]", existing)
    @Assert(e4.startsWith("error:"), true)
    @Assert(l4.size, 0)
}

// ===== ⑥ 用户级经验本（去重、不虚增次数）=====

@Test
public func unionUserLessonsDedupesWithoutInflation(): Unit {
    let existing = ArrayList<LessonNote>()
    existing.add(noteOf("坑甲", 3))
    let incoming = ArrayList<LessonNote>()
    incoming.add(noteOf("坑甲", 3))
    incoming.add(noteOf("坑乙", 1))
    let merged = unionUserLessons(existing, incoming)
    @Assert(merged.size, 2)
    // 已有的那条次数保持 3，不许因为重跑归档变成 6（那是"手勤"，不是"常见"）
    @Assert(merged[0].occurrences, 3)
    @Assert(merged[1].title, "坑乙")
}

@Test
public func renderUserLessonsFileCarriesHeaderAndAllNotes(): Unit {
    let list = ArrayList<LessonNote>()
    list.add(noteOf("坑甲", 2))
    list.add(noteOf("坑乙", 1))
    let text = renderUserLessonsFile(list)
    @Assert(text.startsWith("# 灵渠用户级经验本"), true)
    @Assert(text.contains("坑甲"), true)
    @Assert(text.contains("坑乙"), true)
    // 读回来条数要对得上（头是 markdown，解析器不能把它当条目）
    @Assert(parseLessons(text).size, 2)
}

// ===== ⑦ 经验摘要（0.39.150：把已入库经验拼进任务书）=====

@Test
public func truncateUtf8BytesKeepsCharsWhole(): Unit {
    // 中文每字 3 字节：截到 5 字节只能留 1 个字，且绝不许切出半个（§4-116 同族）
    let s = "中文截断测试"
    @Assert(truncateUtf8BytesOf(s, 7), "中文")
    @Assert(truncateUtf8BytesOf(s, 6), "中文")
    @Assert(truncateUtf8BytesOf(s, 5), "中")
    @Assert(truncateUtf8BytesOf(s, 0), "")
    // 不超上限时原样返回（别顺手多截一刀）
    @Assert(truncateUtf8BytesOf("abc", 10), "abc")
    // ASCII 与中文混排也要断在字符边界上
    @Assert(truncateUtf8BytesOf("ab中", 3), "ab")
}

@Test
public func lessonsDigestIsCappedByItemsAndBytes(): Unit {
    // 空经验本 → 空串（调用方据此让整节不出现，不许留空标题）
    @Assert(lessonsDigestFromText("", LESSON_DIGEST_MAX), "")
    // 条数上限
    let many = ArrayList<LessonNote>()
    var i: Int64 = 0
    while (i < 10) {
        many.add(noteOf("坑${i}", 1))
        i += 1
    }
    @Assert(lessonsDigestCountOf(lessonsDigestOf(many, 3)), 3)
    // 字节上限：100 条超长正文也只能截到 LESSON_DIGEST_MAX_BYTES 之内
    // （任务书越长越危险——0.37.2 实测长单帧被 cjh 静默丢弃，不是越全越好）
    let fat = ArrayList<LessonNote>()
    var j: Int64 = 0
    while (j < 100) {
        fat.add(LessonNote("标题${j}", "现象", "根因", "复现", "修法很长很长很长很长很长很长很长"))
        j += 1
    }
    let digest = lessonsDigestOf(fat, 100)
    @Assert(Int64(digest.size) <= LESSON_DIGEST_MAX_BYTES, true)
    @Assert(lessonsDigestCountOf(digest) > 0, true)
}

@Test
public func lessonsDigestCarriesFixAndArchiveRef(): Unit {
    let n = LessonNote("坑甲", "现象", "根因在 A", "复现命令", "改 B 再重跑")
    n.archivedRef = "FP-021"
    let line = lessonsDigestLineOf(n)
    @Assert(line.startsWith("- **坑甲**：改 B 再重跑"), true)
    @Assert(line.contains("（入库：FP-021）"), true)
    // 没有修法就退回根因：摘要要回答"下次怎么躲"，不是只复述现象
    let n2 = LessonNote("坑乙", "现象", "根因在 C", "复现", "")
    @Assert(lessonsDigestLineOf(n2).contains("根因在 C"), true)
    // 标题空 → 这一条不给（一条没头没尾的摘要只会占位置）
    @Assert(lessonsDigestLineOf(LessonNote("  ", "现象", "根因", "复现", "修法")), "")
}

@Test
public func lessonsDigestParsesRealBookText(): Unit {
    // 走真实段落格式（`renderUserLessonsFile` 的产出），确认摘要取自经验本而非某种巧合格式
    let list = ArrayList<LessonNote>()
    let n = LessonNote("坑甲", "现象", "根因", "复现", "改 B")
    n.occurrences = 2
    list.add(n)
    let digest = lessonsDigestFromText(renderUserLessonsFile(list), LESSON_DIGEST_MAX)
    @Assert(lessonsDigestCountOf(digest), 1)
    @Assert(digest.contains("改 B"), true)
}
