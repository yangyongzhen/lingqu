package lingqu.tests

import lingqu.*

/*
 * 「当前工程」取值规则（`effectivePath`）单测。
 *
 * 背景：界面曾有 8 个各自独立的工程路径框，填错一个就对着别的工程执行
 * （build 用 A、deploy 用 B 而界面不提醒）。现在顶部「当前工程」是唯一权威，
 * 其余只回显；某步单独指定必须显式覆盖——这里锁住取值的优先级。
 */

@Test
public func testFallsBackToCurrentProject(): Unit {
    @Assert(effectivePath("E:/a", ""), "E:/a")
    @Assert(effectivePath("E:/a", "   "), "E:/a")   // 空白覆盖等于没覆盖
}

@Test
public func testOverrideWins(): Unit {
    // 显式覆盖优先于当前工程（这是"某一步用别的工程"的唯一合法途径）
    @Assert(effectivePath("E:/a", "E:/b"), "E:/b")
}

@Test
public func testBothEmptyIsEmpty(): Unit {
    // 都没给 → 空串，调用方必须拦住（不许默默拿默认工程跑）
    @Assert(effectivePath("", ""), "")
    @Assert(effectivePath("   ", "  "), "")
}

@Test
public func testProjectPromptCountIsOne(): Unit {
    // 判据：界面上"要用户填工程路径"的地方只该有 1 处（顶部权威框）
    @Assert(PROJECT_PROMPT_COUNT, 1)
    @Assert(PROJECT_ECHO_FIELDS, 8)   // 其余 8 处是回显，不该再让人填
}