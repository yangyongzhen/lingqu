package lingqu.tests

import lingqu.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 0.39.114 单测：`notes archive --to repo` ↔ `t2h:pr_prepare` 的接头（飞轮阶段 2）。
 *
 * 起因：`--to repo` 原先只回一句「经验留在候选草稿里，等你提 PR」，而 `pr_prepare` 只认
 * **仍未入库**的候选（`candidateLessons` 跳过已归档）⇒ 刚归档的那批**两边都不认**，
 * 人按提示去提 PR 会发现草稿里根本没有它。现在归档当场产出可合并块，pr_prepare 并进正文。
 */

/** 单条候选（ArrayList 显式构造：仓里没有 Array.toArrayList() 的先例，别赌） */
func oneNote(title: String): ArrayList<LessonNote> {
    let l = ArrayList<LessonNote>()
    l.add(repoLessonOf(title))
    return l
}

func repoLessonOf(title: String): LessonNote {
    let n = LessonNote(title, "现象一句话", "根因一句话", "复现一句话", "修法一句话")
    n.project = "habit-tree"
    n.occurrences = 3
    return n
}

@Test
public func testRepoBlockCarriesMarkersAndItems(): Unit {
    let list = ArrayList<LessonNote>()
    list.add(repoLessonOf("桥只写了一半"))
    let b = renderRepoLessonsBlock("habit-tree", list)
    @Assert(b.startsWith(LESSONS_SECTION_BEGIN), true)
    @Assert(b.indexOf(LESSONS_SECTION_END).isSome(), true)
    @Assert(b.indexOf("桥只写了一半").isSome(), true)
    @Assert(b.indexOf("habit-tree").isSome(), true)
}

@Test
public func testUpsertIsIdempotent(): Unit {
    // 重跑 archive / pr_prepare 不能让同一批经验在正文里叠成两份
    let block = renderRepoLessonsBlock("p", oneNote("A"))
    let once = upsertLessonsSectionOf("# PR 正文\n\n原有内容\n", block)
    let twice = upsertLessonsSectionOf(once, block)
    @Expect(twice, once)
    @Assert(once.indexOf("原有内容").isSome(), true)
}

@Test
public func testUpsertReplacesOldBlockInPlace(): Unit {
    // 第二次运行带了新经验：旧块要被**替换**（不是留下两份）
    let oldBlock = renderRepoLessonsBlock("p", oneNote("旧经验"))
    let newBlock = renderRepoLessonsBlock("p", oneNote("新经验"))
    let doc = "# 正文\n" + oldBlock + "\n### 尾部\n"
    let out = upsertLessonsSectionOf(doc, newBlock)
    @Assert(out.indexOf("新经验").isSome(), true)
    @Assert(out.indexOf("旧经验").isNone(), true)
    @Assert(out.indexOf("### 尾部").isSome(), true)
}

@Test
public func testUpsertAppendsWhenNoMarker(): Unit {
    let block = renderRepoLessonsBlock("p", oneNote("A"))
    let out = upsertLessonsSectionOf("# 没有标记的正文", block)
    @Assert(out.startsWith("# 没有标记的正文"), true)
    @Assert(out.indexOf(LESSONS_SECTION_BEGIN).isSome(), true)
}

@Test
public func testEmptyCandidatesProduceNoDraft(): Unit {
    // 空候选不产空壳文件：说清原因，别让人以为"已经准备好了"（§4-63）
    let r = stageRepoLessons("E:/tmp/lingqu-not-created", "p", ArrayList<LessonNote>())
    @Assert(r.ready, false)
    @Expect(r.path, "")
    @Assert(r.note.indexOf("没有可归档的经验").isSome(), true)
}
