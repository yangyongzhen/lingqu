package lingqu.tests

import lingqu.port.*
import std.collection.*
import std.fs.*

/*
 * 0.39.116 单测：指纹库的**清单与同源判据**（纯函数 + 读真实文档，D-009）。
 *
 * 为什么需要它：指纹库本来就是单点（`fingerprintLibrary()`），但**没有任何判据**钉住
 * 「一共几条、编号连不连续、文档里写的条数对不对、文档引用的编号存不存在」。
 * 0.39.115 给改造规则做同款收口时看到过代价：条数只在文档里 ⇒ README 写 16、
 * 飞轮写 16、需求追踪写 15，而代码里一处都查不到（§4-166 同族：同一份知识写两处必然漂）。
 *
 * 三类读者都钉住：
 *   库 ↔ 自身   编号连续（跳过保留空位）、无重复、marker 不撞车、匹配顺序（具体先于泛串）
 *   库 ↔ 文档   门面文档的条数与编号范围、文档引用不存在的编号（**双向**）
 *   库 ↔ 规则   `patchKind=rule` 必须指向已登记的 `R2-PORT-*`（否则诊断给的是死路）
 *
 * 诚实的边界：只保证「有几条、编号怎么排、几处说法对不对得上」，**不保证指纹接得住真实日志**
 * ——那要看 5 个样本的实跑命中率（`docs/需求追踪.md` §五 R-2）。
 */

/** 取编号在清单里的位置（-1 = 没找到） */
func fpIndexOfOf(ids: Array<String>, id: String): Int64 {
    for (i in 0..ids.size) {
        if (ids[i] == id) {
            return i
        }
    }
    return -1
}

@Test
public func testFingerprintNumberingSkipsReservedGaps(): Unit {
    let ids = fingerprintIds()
    // 连号（跳过 FP-008/FP-009 两个从未存在的空位）、无重复
    @Assert(fingerprintNumberingTextOf(ids), "")
    @Assert(fingerprintCount(), ids.size)
    // 范围串必须由库首尾算出：`FP-001…FP-023`
    @Assert(fingerprintRangeTextOf(), ids[0] + "…" + ids[ids.size - 1])
    // "空位"这句话本身也得是真的：保留编号不许有内容
    for (gap in FP_RESERVED_GAP_IDS) {
        @Assert(!fingerprintKnownOf(gap))
    }
    // **顺序即匹配顺序**：具体指纹必须排在泛串之前，否则永远被泛串抢走归因（0.39.99 的教训）
    @Expect(fpIndexOfOf(ids, "FP-021") < fpIndexOfOf(ids, "FP-016"), true)
    @Expect(fpIndexOfOf(ids, "FP-022") < fpIndexOfOf(ids, "FP-005"), true)
}

@Test
public func testFingerprintNumberingCatchesHoleDupAndBadFormat(): Unit {
    // 缺号：001 之后直接 003（002 缺了）要红，并把编号不对的那条贴出来
    let hole = fingerprintNumberingTextOf(["FP-001", "FP-003"])
    @Expect(hole.size > 0, true)
    @Expect(hole.contains("FP-003"), true)
    // 保留空位是**允许**的：001..007 之后直接 010 不算缺号（历史决定，不是漂移）
    @Assert(fingerprintNumberingTextOf(
        ["FP-001", "FP-002", "FP-003", "FP-004", "FP-005", "FP-006", "FP-007", "FP-010"]), "")
    // 但**跳错空位**（跳过 002~009 全跳）要红
    @Expect(fingerprintNumberingTextOf(["FP-001", "FP-010"]).size > 0, true)
    // 保留空位本身不许有内容（"空位"这句话也得是真的）
    @Expect(fingerprintNumberingTextOf(["FP-008"]).size > 0, true)
    // 重复
    @Expect(fingerprintNumberingTextOf(["FP-001", "FP-001"]).contains("重复"), true)
    // 位数不对（`FP-1` 这种以后可能有人手写）
    @Expect(fingerprintNumberingTextOf(["FP-1"]).contains("三位"), true)
    // 空清单
    let empty: Array<String> = []
    @Expect(fingerprintNumberingTextOf(empty), "清单是空的")
}

@Test
public func testFingerprintMarkersAreUnique(): Unit {
    // 真库里 marker 撞车 = 后一条永远命不中（诊断静默归因给前一条）
    @Assert(gapsTextOf(fingerprintMarkerDupesOf(fingerprintLibrary())), "")
}

@Test
public func testFingerprintMarkerDupesOfDetectsConflict(): Unit {
    let fps = ArrayList<Fingerprint>()
    fps.add(Fingerprint("FP-901", "unresolved import", "根因", "修法", "", PK_GUIDE))
    // 大小写不同也算撞车：匹配走小写（diagLowerOf）
    fps.add(Fingerprint("FP-902", "UNRESOLVED IMPORT", "根因", "修法", "", PK_GUIDE))
    let gaps = fingerprintMarkerDupesOf(fps)
    @Expect(gaps.size, 1)
    @Expect(gaps[0].contains("FP-902"), true)
    @Expect(gaps[0].contains("FP-901"), true)
}

@Test
public func testFingerprintRuleLinksResolve(): Unit {
    @Assert(gapsTextOf(fingerprintRuleLinkGapsOf(fingerprintLibrary())), "")
    // 库里必须真有 rule 档——否则上一条是"空集合上恒真"的假绿（§4-136 同族）
    var pkRuleCount: Int64 = 0
    for (fp in fingerprintLibrary()) {
        if (fp.patchKind == PK_RULE) {
            pkRuleCount += 1
        }
    }
    @Assert(pkRuleCount > 0)
}

@Test
public func testFingerprintRuleLinkGapsOfDetectsDeadLink(): Unit {
    // rule 档却没关联规则编号
    let noRule = ArrayList<Fingerprint>()
    noRule.add(Fingerprint("FP-901", "x", "根因", "修法", "", PK_RULE))
    @Expect(fingerprintRuleLinkGapsOf(noRule).size, 1)
    // 关联了一条不存在的规则
    let deadRule = ArrayList<Fingerprint>()
    deadRule.add(Fingerprint("FP-902", "x", "根因", "修法", "R2-PORT-999", PK_RULE))
    @Expect(fingerprintRuleLinkGapsOf(deadRule).size, 1)
    // 档位写错（既不是 rule 也不是 guide）
    let badKind = ArrayList<Fingerprint>()
    badKind.add(Fingerprint("FP-903", "x", "根因", "修法", "", "bogus"))
    @Expect(fingerprintRuleLinkGapsOf(badKind).size, 1)
    // 正常形态不报（否则判据自己就是噪声源）
    let okOne = ArrayList<Fingerprint>()
    okOne.add(Fingerprint("FP-904", "x", "根因", "修法", "R2-PORT-016", PK_RULE))
    okOne.add(Fingerprint("FP-905", "y", "根因", "修法", "", PK_GUIDE))
    @Expect(fingerprintRuleLinkGapsOf(okOne).size, 0)
}

@Test
public func testFingerprintIdsInTextOf(): Unit {
    let ids = fingerprintIdsInTextOf("先看 FP-021，再看 FP-016；范围 FP-001…FP-023；裸前缀 FP-0xx 与短号 FP-1 不算")
    @Expect(ids.size, 4)
    @Expect(ids[0], "FP-021")
    @Expect(ids[1], "FP-016")
    @Expect(ids[2], "FP-001")
    @Expect(ids[3], "FP-023")
    // 重复的编号只算一次（文档里同一条被引两次不该变成两条缺口）
    @Expect(fingerprintIdsInTextOf("FP-021 与 FP-021").size, 1)
    @Assert(fingerprintIdsInTextOf("没有任何编号").size == 0)
}

@Test
public func testFingerprintCountClaimsOf(): Unit {
    let one = fingerprintCountClaimsOf("现共 21 条指纹")
    @Expect(one.size, 1)
    @Expect(one[0], 21)
    // 加粗写法与括号写法都要抽得出来（现场就是这么写的）
    @Expect(fingerprintCountClaimsOf("**15 条错误指纹** + 六道闸")[0], 15)
    @Expect(fingerprintCountClaimsOf("（13 条指纹）")[0], 13)
    // 同一个数字出现两次只算一条
    @Expect(fingerprintCountClaimsOf("21 条指纹 … 再写一遍 21 条指纹").size, 1)
    // 表格里的 `✅ 21 条 |`（紧跟"指纹"二字）抽不到——由"必须写对条数"的粗判据兜底
    @Expect(fingerprintCountClaimsOf("| ✅ 21 条 |").size, 0)
}

@Test
public func testFingerprintCountClaimGapsOf(): Unit {
    @Expect(fingerprintCountClaimGapsOf("d", "21 条指纹", 21).size, 0)
    @Expect(fingerprintCountClaimGapsOf("d", "15 条指纹", 21).size, 1)
    // 一处对一处错 → 只报错的那处，且指名文档
    let gaps = fingerprintCountClaimGapsOf("d", "21 条指纹 与 15 条错误指纹", 21)
    @Expect(gaps.size, 1)
    @Expect(gaps[0].contains("d"), true)
    @Expect(gaps[0].contains("15"), true)
    // 没写条数不算缺口：只核对"说了什么"，不强迫每份文档都写数字
    @Expect(fingerprintCountClaimGapsOf("d", "处置见技能 references", 21).size, 0)
}

@Test
public func testFingerprintDocIdGapsOf(): Unit {
    @Expect(fingerprintDocIdGapsOf("d", "命中 FP-021 与范围 FP-001…FP-023").size, 0)
    let gaps = fingerprintDocIdGapsOf("d", "见 FP-077")
    @Expect(gaps.size, 1)
    @Expect(gaps[0].contains("FP-077"), true)
    // 保留空位允许被提到（那是历史事实，不是"不存在的指纹"）
    @Expect(fingerprintDocIdGapsOf("d", "FP-008 / FP-009 从未存在，空位不补编").size, 0)
}

/** 现状文档：写着"现在有几条指纹"的那几份（历史记录类文档刻意不在集合里，§4-160） */
func fpLiveDocsOf(): Array<String> {
    return ["README.md", "docs/AI自进化飞轮.md", "docs/迁移指南.md", "docs/需求追踪.md"]
}

@Test
public func testLiveDocsStateSameCountAndRange(): Unit {
    let count = fingerprintCount()
    let range = fingerprintRangeTextOf()
    let gaps = ArrayList<String>()
    for (doc in fpLiveDocsOf()) {
        let text = String.fromUtf8(File.readFrom(doc))
        // 至少要写出正确条数（`21 条`）——否则读者看到的还是旧数字
        if (!text.contains("${count} 条")) {
            gaps.add("${doc} 没写指纹条数 ${count} 条")
        }
        // 严格形态（`N 条[错误]指纹`）里的每个 N 都必须是现在的条数
        for (g in fingerprintCountClaimGapsOf(doc, text, count)) {
            gaps.add(g)
        }
        // 文档引用不存在的指纹编号也算缺口
        for (g in fingerprintDocIdGapsOf(doc, text)) {
            gaps.add(g)
        }
    }
    // 编号范围这两份门面必须写全（其余文档按需）
    for (doc in ["README.md", "docs/AI自进化飞轮.md"]) {
        let text = String.fromUtf8(File.readFrom(doc))
        if (!text.contains(range)) {
            gaps.add("${doc} 没写指纹编号范围 ${range}")
        }
    }
    @Assert(gapsTextOf(gaps), "")
}

@Test
public func testSkillDocsReferencedFingerprintsExist(): Unit {
    let refs = refsTextOf()
    // 文档读不到时不许静默"通过"——直接红（与 fingerprint_sync_test 同款守卫）
    @Expect(refs.size > 0, true)
    @Assert(gapsTextOf(fingerprintDocIdGapsOf("技能 references", refs)), "")
}
