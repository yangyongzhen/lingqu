package lingqu.tests

import lingqu.*

/*
 * AI 接入第 2 步（工程上下文 = AGENTS.md 受管区块 + 切 cjh workspace）的纯函数单测。
 *
 * 三条纪律必须守住（这是用户拍板方案的核心）：
 *   ① **幂等**：重复装只替换区块，不叠第二份；
 *   ② **不吞用户内容**：用户原有正文在区块前后都原样保留；
 *   ③ **可撤销**：移除只删自己那块；用户原本没有 AGENTS.md 时移除后应是空文本（调用方据此删文件）。
 */

@Test
public func testAgentBlockMarkers(): Unit {
    // 标记必须成对出现才算"有区块"
    @Assert(hasAgentBlock(AGENT_BLOCK_BEGIN + "\n正文\n" + AGENT_BLOCK_END), true)
    @Assert(hasAgentBlock(AGENT_BLOCK_BEGIN + "\n正文没结束"), false)
    @Assert(hasAgentBlock("普通 AGENTS.md，没有灵渠的区块"), false)
    @Assert(hasAgentBlock(""), false)
}

@Test
public func testInjectIntoEmptyFile(): Unit {
    let out = injectAgentBlock("", "## 上下文\n\n内容")
    @Assert(hasAgentBlock(out), true)
    @Assert(out.startsWith(AGENT_BLOCK_BEGIN), true)
    @Assert(out.contains("## 上下文"), true)
    // 结尾要有换行（git diff 好看，且追加时不会粘连）
    @Assert(out.endsWith("\n"), true)
}

@Test
public func testInjectPreservesUserContentAndIsIdempotent(): Unit {
    let user = "# 我自己的 AGENTS.md\n\n- 这个工程用 pnpm\n"
    let once = injectAgentBlock(user, "第一版上下文")
    // 用户内容原样保留
    @Assert(once.startsWith(user), true)
    @Assert(once.contains("第一版上下文"), true)
    @Assert(hasAgentBlock(once), true)

    // 再装一次（换正文）：只替换区块，不叠第二块
    let twice = injectAgentBlock(once, "第二版上下文")
    @Assert(twice.contains("第二版上下文"), true)
    @Assert(twice.contains("第一版上下文"), false)
    @Assert(twice.startsWith(user), true)
    // 只有一个 begin / end
    @Assert(countOccurrences(twice, AGENT_BLOCK_BEGIN), 1)
    @Assert(countOccurrences(twice, AGENT_BLOCK_END), 1)

    // 第三次仍幂等（同样输入 → 同样输出）
    let thrice = injectAgentBlock(twice, "第二版上下文")
    @Assert(thrice, twice)
}

@Test
public func testRemoveBlockKeepsUserContent(): Unit {
    let user = "# 用户自己的内容\n\n保持住\n"
    let installed = injectAgentBlock(user, "上下文正文")
    let removed = removeAgentBlock(installed)
    // 用户内容还在，灵渠那块没了
    @Assert(removed.contains("用户自己的内容"), true)
    @Assert(removed.contains("上下文正文"), false)
    @Assert(hasAgentBlock(removed), false)
    // 重复移除是 no-op
    @Assert(removeAgentBlock(removed), removed)

    // 用户原本没有 AGENTS.md：移除后应是空文本（调用方据此删文件而不是留空文件）
    let only = injectAgentBlock("", "上下文正文")
    @Assert(removeAgentBlock(only).trimAscii(), "")
    // 没有区块的文本移除时原样返回（别误伤）
    @Assert(removeAgentBlock(user), user)
}

@Test
public func testAgentContextPathAndBody(): Unit {
    // 路径是工程根的 AGENTS.md
    let p = agentContextPathOf("E:\\work\\habit-tree")
    @Assert(p.endsWith("AGENTS.md"), true)
    @Assert(p.startsWith("E:\\work\\habit-tree"), true)
    // 空工程目录不给路径（调用方据此报错，而不是写到 cwd）
    @Assert(agentContextPathOf(""), "")

    // 正文必须带上这个工程的名字，以及三类关键信息（落档 / 工具 / 口径）
    let body = agentContextBody("habit-tree", "E:\\work\\habit-tree")
    @Assert(body.contains("habit-tree"), true)
    @Assert(body.contains(".lingqu/scan/habit-tree.json"), true)
    @Assert(body.contains("t2h:scan"), true)
    @Assert(body.contains("t2h:deploy"), true)
    // 两条最容易让模型说错话的口径必须显式写出
    @Assert(body.contains("平台限制 ≠ 失败"), true)
    @Assert(body.contains("未验证 ≠ 通过"), true)
    // 前端编进 .so 这条最容易漏（改了前端不重编 → 白屏）
    @Assert(body.contains(".so"), true)
}

/** 数子串出现次数（测试内小工具） */
func countOccurrences(text: String, needle: String): Int64 {
    var n: Int64 = 0
    var rest = text
    while (true) {
        match (rest.indexOf(needle)) {
            case Some(i) =>
                n += 1
                rest = rest[(i + needle.size)..rest.size]
            case None => break
        }
    }
    return n
}
