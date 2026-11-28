package lingqu.tests

import lingqu.*
import std.collection.*
import std.fs.*

/*
 * 0.39.112 单测：任务书层的**同源校验**（纯函数 + 一条读真实文档的断言，D-009）。
 *
 * 为什么需要它：任务书是 agent 唯一必读的入口（docs/任务书规范.md §1 的三次事故都指向这句），
 * 而它的小节是**手写拼接**的——删一节、改一句文案、把一个条件分支写成无条件，
 * 编译期一句警告都不会有，症状要等下一轮真机迁移才暴露（agent 撞墙白烧轮次）。
 *
 * 所以把"这一份变体该有哪些小节"做成清单（`directiveClauses`），两端都钉住：
 *   生成物 ↔ 清单（四种变体，含缺 CLI / 缺真机 / 半自动）
 *   清单   ↔ 规范文档 §3（读真实 markdown，读不到直接红，不许静默通过）
 *
 * 诚实的边界：这里只保证"小节在"，**不保证 agent 读了、照做了**——那只能靠真实迁移验收（规范 §8）。
 */

/** 规范文档正文（真实文件，不是样本） */
func taskSpecDocOf(): String {
    return String.fromUtf8(File.readFrom("docs/任务书规范.md"))
}

/** 缺口拼成一行，失败时能直接看出缺哪几条 */
func sectionsTextOf(gaps: ArrayList<String>): String {
    var s = ""
    for (g in gaps) {
        if (s.size > 0) {
            s += "；"
        }
        s += g
    }
    return s
}

/** 全流程 + 有 CLI + 真机在线 + 有落档：最完整的现场 */
func fullDirectiveOf(): String {
    let inp = AutoPortInput()
    inp.project = "habit-tree"
    inp.projectDir = "E:/test/rust/habit-tree"
    inp.cliPath = "C:/lingqu/lingqu-cli.exe"
    inp.device = true
    inp.stateLines = "[1/8] scan 通过"
    return buildAutoPortDirective(inp)
}

@Test
public func testClausesAreWellFormed(): Unit {
    let clauses = directiveClauses()
    // 清单不能是空的——空清单会让所有同源断言变成假绿（§4-136 假绿同族）
    // 0.39.130：18 → 19（「插件不满足：三层适配优先于降级」，外部反馈采纳）；
    // 19 → 20（「鸿蒙知识库（MCP 工具）」，cjh 1.6.13 接入华为开发者知识库后补"何时该查"纪律）
    // 20 → 21（0.39.143 之后的条款）；21 → 22（「已入库经验（跨工程，先看这里）」，0.39.150）
    @Expect(clauses.size, 22)
    let seen = ArrayList<String>()
    for (c in clauses) {
        @Assert(c.section.size > 0)
        // 删条款的人靠 why 判断"这条还成不成立"，空理由等于不许删也不用知道为什么
        @Assert(c.why.size > 0)
        // 触发条件只能是这六个之一，写错一个字就会让整条永远不出现在判据里
        @Assert(c.when == DIRECTIVE_WHEN_ALWAYS || c.when == DIRECTIVE_WHEN_CLI ||
            c.when == DIRECTIVE_WHEN_DEVICE || c.when == DIRECTIVE_WHEN_STATE ||
            c.when == DIRECTIVE_WHEN_HALF || c.when == DIRECTIVE_WHEN_LESSONS)
        for (s in seen) {
            // 重名会让"缺了哪一条"指向不明
            @Assert(s != c.section)
        }
        seen.add(c.section)
    }
}

@Test
public func testFullDirectiveCarriesEveryApplicableSection(): Unit {
    let d = fullDirectiveOf()
    let whens: Array<String> = [DIRECTIVE_WHEN_CLI, DIRECTIVE_WHEN_DEVICE, DIRECTIVE_WHEN_STATE]
    // 缺口必须是空——失败时 Assert 会把缺哪几条原样打出来
    @Assert(sectionsTextOf(directiveGapsOf(d, directiveSectionsOf(whens))), "")
}

@Test
public func testDirectiveWithoutSideConditionsDropsOnlyThoseSections(): Unit {
    // 没 CLI、没落档、没真机：只该剩 always 那批
    let inp = AutoPortInput()
    inp.project = "habit-tree"
    inp.projectDir = "E:/test/rust/habit-tree"
    let d = buildAutoPortDirective(inp)
    @Assert(sectionsTextOf(directiveGapsOf(d, directiveSectionsOf([]))), "")
    // 反方向：条件性小节**确实消失**了（否则上面那句会变成"反正都写着"的假绿）。
    // 注意用只含条件性小节的 `directiveConditionalSectionsOf`——`directiveSectionsOf` 含 always，
    // 拿它断"不在"会把每条必给小节都断成失败（那是测试自己错，不是被测代码错）。
    var leaked = ""
    for (s in directiveConditionalSectionsOf([DIRECTIVE_WHEN_CLI, DIRECTIVE_WHEN_STATE,
        DIRECTIVE_WHEN_DEVICE, DIRECTIVE_WHEN_HALF])) {
        if (d.contains(s)) {
            leaked += s + "；"
        }
    }
    @Assert(leaked, "")
    // 命令名兜底：没有 CLI 路径时，无条件的段落也不许拼出丢了程序名的命令
    // （0.39.112 实测：`## 原生 UI 能力` 无条件渲染却裸拼 cliPath，产出 `` ` hap --path .` ``，
    //   agent 照着跑必然 command not found——与 §4-94「不许有看起来像数据的假值」同族）
    @Assert(!d.contains("` hap --path ."))
}

@Test
public func testCliPathIsUsedWhenAvailable(): Unit {
    // 反方向：拿到路径时就必须用真路径，别让兜底把真路径也顶掉
    @Assert(fullDirectiveOf().contains("C:/lingqu/lingqu-cli.exe hap --path ."))
}

@Test
public func testHalfAutoDirectiveCarriesScopeSection(): Unit {
    let inp = AutoPortInput()
    inp.project = "habit-tree"
    inp.projectDir = "E:/test/rust/habit-tree"
    inp.cliPath = "C:/lingqu/lingqu-cli.exe"
    inp.scope = "sign"
    let d = buildAutoPortDirective(inp)
    @Assert(sectionsTextOf(directiveGapsOf(d, directiveSectionsOf([DIRECTIVE_WHEN_CLI, DIRECTIVE_WHEN_HALF]))), "")
    // 半自动的核心承诺：只做这一步、做完就停（不许顺手把后面几步也跑了）
    @Assert(d.contains("做完就停"))
    // 签名那一支也必须带登录路径（0.39.83：只点这一步的人反而知道得更少是反例）
    @Assert(d.contains("--login"))
}

@Test
public func testGapsReportMissingSectionsByName(): Unit {
    // 截断的正文：缺的必须逐条点名，而不是只报"不完整"
    let body = "## 工具箱\n## 纪律"
    let gaps = directiveGapsOf(body, ["## 工具箱", "## 纪律", "## TLS 栈"])
    @Expect(gaps.size, 1)
    @Expect(gaps[0], "## TLS 栈")
    // 空正文一律判"全缺"：读不到 ≠ 都齐了（写盘失败/文件被清空走这条）
    @Expect(directiveGapsOf("", ["## 工具箱", "## 纪律"]).size, 2)
    // 全都有 → 空
    @Assert(directiveGapsOf(body, ["## 工具箱"]).size == 0)
}

@Test
public func testLessonsSectionAppearsOnlyWhenProvided(): Unit {
    // 有经验 → 该节出现，摘要原样带上、条数写对（这是"经验被复用"的唯一证据位）
    let inp = AutoPortInput()
    inp.project = "habit-tree"
    inp.projectDir = "E:/test/rust/habit-tree"
    inp.knownLessons = "- **坑甲**：先查 `.cargo/config.toml`（入库：FP-021）\n"
    let d = buildAutoPortDirective(inp)
    @Assert(sectionsTextOf(directiveGapsOf(d, directiveSectionsOf([DIRECTIVE_WHEN_LESSONS]))), "")
    @Assert(d.contains("- **坑甲**：先查 `.cargo/config.toml`（入库：FP-021）"), true)
    @Assert(d.contains("共 1 条"), true)
    // 没有经验 → 整节不许出现：留个空标题等于告诉 agent「经验库是空的」（§4-136 同族）
    let inp2 = AutoPortInput()
    inp2.project = "habit-tree"
    inp2.projectDir = "E:/test/rust/habit-tree"
    @Assert(buildAutoPortDirective(inp2).contains("## 已入库经验"), false)
}

@Test
public func testSpecDocListsEveryClause(): Unit {
    let doc = taskSpecDocOf()
    // 文档读不到时不能静默"通过"——直接红
    @Expect(doc.size > 0, true)
    let all = ArrayList<String>()
    for (c in directiveClauses()) {
        all.add(c.section)
    }
    @Assert(sectionsTextOf(directiveGapsOf(doc, all.toArray())), "")
}
