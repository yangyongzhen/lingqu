package lingqu.tests

import lingqu.*
import lingqu.port.*
import std.collection.*
import std.fs.*

/*
 * 0.39.115 单测：改造规则清单的**同源校验**（纯函数 + 读真实源码/文档，D-009）。
 *
 * 为什么需要它：17 条规则的编号原先只以 `RuleOutcome("R2-PORT-0xx")` 字面量散在 6 个文件里，
 * 没有任何地方能回答"一共几条"——于是 README 写 16 条、`docs/AI自进化飞轮.md` 写 16 条、
 * `docs/需求追踪.md` 写 15 条，三种说法并存（§4-166 同族：同一份知识写两处、只靠纪律必然漂）。
 *
 * 现在 `src/port/rules.cj` 是唯一清单，这里把它三类读者都钉住：
 *   清单 ↔ 源码构造点（双向：漏登记、漏实现、改成动态编号都红）
 *   清单 ↔ 诊断建议（`diagnose.cj` 里点名的规则必须真的存在）
 *   清单 ↔ 门面文档（README / 飞轮的编号范围与条数）
 *
 * 诚实的边界：只保证「有几条、编号连续、四处的编号对得上」，
 * **不保证规则行为对**——那只能靠 5 个样本的真机迁移验收。
 */

/** 规则构造点只可能出现在这几个文件里（`src/port/rules.cj` 自己是清单，刻意不在其中） */
func ruleSourceFilesOf(): Array<String> {
    return [
        "src/port/port.cj",
        "src/port/toolchain.cj",
        "src/port/shim.cj",
        "src/port/resolve.cj",
        "src/port/hvigor.cj",
        "src/main.cj"
    ]
}

/** 缺口拼成一行，失败时能直接看出缺哪几条 */
func gapsTextOf(gaps: ArrayList<String>): String {
    var s = ""
    for (g in gaps) {
        if (s.size > 0) {
            s += "；"
        }
        s += g
    }
    return s
}

/** 扫一份源码文件里的 `RuleOutcome(...)` 构造点：返回编号清单 + 认不出的行 */
func scanRuleConstructsOf(path: String, scanned: ArrayList<String>, unparsed: ArrayList<String>): Unit {
    let lines = String.fromUtf8(File.readFrom(path)).split("\n")
    for (line in lines) {
        if (!line.contains("RuleOutcome(")) {
            continue
        }
        let id = ruleIdFromConstructLine(line)
        if (id.size == 0) {
            unparsed.add("${path}: ${line.trimAscii()}")
            continue
        }
        scanned.add(id)
    }
}

@Test
public func testPortRuleNumberingIsContiguous(): Unit {
    let ids = portRuleIds()
    // 编号必须连号无重复（`001..NNN`）——空位会让"第 N 条"这类说法永久失真
    @Assert(ruleNumberingTextOf(ids), "")
    @Assert(portRuleCount(), ids.size)
    // 范围串必须由清单首尾算出：`R2-PORT-001…017`
    @Assert(portRuleRangeTextOf(), "R2-PORT-001…" + pad3Of(ids.size))
}

@Test
public func testRuleIdParsingCoversBothRealForms(): Unit {
    // 字面量形态（16 条规则）
    @Assert(ruleIdFromConstructLine("    var o1 = RuleOutcome(\"R2-PORT-001\", false, \"\", \"\", \"\")"),
        "R2-PORT-001")
    // 常量形态（015 就是这么写的）
    @Assert(ruleIdFromConstructLine("    var o = RuleOutcome(HVIGOR_HOOK_RULE_ID, false, \"\", \"\", \"\")"),
        "R2-PORT-015")
    // 非构造行 → 空串（不是"没编号"，是"这行不该被算"）
    @Assert(ruleIdFromConstructLine("    o.applied = true"), "")
    // 动态编号（以后有人写 `RuleOutcome(someVar, …)`）→ 空串，调用方据此判红，不许静默放过
    @Assert(ruleIdFromConstructLine("    var o = RuleOutcome(ruleIdOf(i), false, \"\", \"\", \"\")"), "")
    // 裸前缀不是编号（仓里真有 `R2-PORT-*` 这种写法）→ 不许切出垃圾串
    @Assert(r2PortIdFrom("* 现有 R2-PORT-* 规则就能修", "* 现有 R2-PORT-* 规则就能修".indexOf("R2-PORT-").getOrThrow()), "")
}

@Test
public func testPad3Of(): Unit {
    @Assert(pad3Of(7), "007")
    @Assert(pad3Of(17), "017")
    @Assert(pad3Of(123), "123")
}

@Test
public func testSourceConstructsMatchRegistry(): Unit {
    let scanned = ArrayList<String>()
    let unparsed = ArrayList<String>()
    for (f in ruleSourceFilesOf()) {
        scanRuleConstructsOf(f, scanned, unparsed)
    }
    // 认不出的构造行 = 判据守不住（以后改成动态编号，这条会红而不是静默通过）
    @Assert(gapsTextOf(unparsed), "")
    // 双向差集：清单有而源码没有（漏实现）、源码有而清单没登记（漏登记）
    @Assert(ruleDriftTextOf(scanned, portRuleIds()), "")
}

@Test
public func testDiagnoseAdviceRefersToKnownRules(): Unit {
    let text = String.fromUtf8(File.readFrom("src/port/diagnose.cj"))
    let ids = ruleIdsInTextOf(text)
    // 诊断建议里不点名任何规则 = 这份判据其实没在查东西（假绿，§4-136 同族）
    @Assert(ids.size > 0)
    let unknown = ArrayList<String>()
    for (id in ids) {
        if (!portRuleKnownOf(id)) {
            unknown.add(id)
        }
    }
    @Assert(gapsTextOf(unknown), "")
}

@Test
public func testFacadeDocsStateSameRangeAndCount(): Unit {
    let count = portRuleCount()
    let range = portRuleRangeTextOf()
    let gaps = ArrayList<String>()
    for (doc in ["README.md", "docs/AI自进化飞轮.md"]) {
        let text = String.fromUtf8(File.readFrom(doc))
        if (!text.contains(range)) {
            gaps.add("${doc} 没写规则编号范围 ${range}")
        }
        if (!text.contains("${count} 条")) {
            gaps.add("${doc} 没写规则条数 ${count} 条")
        }
        // 旧口径残留：条数变了却只改了别处，文档里会剩下上一个数字
        if (text.contains("${count - 1} 条规则")) {
            gaps.add("${doc} 还写着旧条数 ${count - 1} 条规则")
        }
    }
    @Assert(gapsTextOf(gaps), "")
}

@Test
public func testTitleLookupFallsBackToEmpty(): Unit {
    @Assert(portRuleTitleOf("R2-PORT-001").size > 0)
    // 查不到返回空串（不编造、不抛）——调用方好判断
    @Assert(portRuleTitleOf("R2-PORT-999"), "")
    // 只报不写的规则必须也在清单里（017 是这一类）
    let detectOnly = portDetectOnlyRuleIdsOf()
    @Assert(detectOnly.size > 0)
    for (id in detectOnly) {
        @Assert(portRuleKnownOf(id))
    }
}
