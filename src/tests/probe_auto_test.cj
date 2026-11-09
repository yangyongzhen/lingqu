package lingqu.tests

import std.collection.*
import lingqu.*

/*
 * 自动验证（`probe --auto`）的纯函数单测（D-009）。
 *
 * 为什么要钉这些判据：自动枚举是**在真实用户的工程上**点按钮，两条错都不能犯——
 *   · 少滤一种"不是按钮"的文本 ⇒ 点完只有时钟在变，被记成 pass（假通过，谎报功能可用）；
 *   · 少滤一种危险词 ⇒ 自动顺手删了人家的数据。
 * 所以这里断的是"哪些文本能进候选"，不是文案。
 */

func nodeOf(text: String, clickable: Bool): LayoutNode {
    let n = LayoutNode()
    n.text = text
    n.clickable = clickable
    return n
}

@Test
public func testNonButtonTextFiltersClockAndDigits() {
    // 时钟 / 日期 / 纯数字：都不是按钮
    @Expect(nonButtonText("12:34"), true)
    @Expect(nonButtonText("2026-11-09"), true)
    @Expect(nonButtonText("2026/11/09 21:14"), true)
    @Expect(nonButtonText("123"), true)
    @Expect(nonButtonText(""), true)
    // 有正文的才是候选
    @Expect(nonButtonText("新建笔记"), false)
    @Expect(nonButtonText("v1.2.0"), false)
    @Expect(nonButtonText("3 个文件"), false)
}

@Test
public func testRiskyClickTextBlocksDestructive() {
    @Expect(riskyClickText("删除笔记"), true)
    @Expect(riskyClickText("清空回收站"), true)
    @Expect(riskyClickText("退出登录"), true)
    @Expect(riskyClickText("立即购买"), true)
    // 正常功能不该被拦
    @Expect(riskyClickText("新建笔记"), false)
    @Expect(riskyClickText("全局搜索"), false)
    @Expect(riskyClickText("插图"), false)
}

@Test
public func testCandidateTextOkCombinesRules() {
    @Expect(candidateTextOk("新建笔记"), true)
    @Expect(candidateTextOk(""), false)
    // 过长（>60 字节）的通常是段落不是按钮
    @Expect(candidateTextOk("这是一段非常长的说明文字，长到它不可能是一个按钮，只可能是正文段落里的内容，用来测试长度阈值"),
        false)
    @Expect(candidateTextOk("21:14"), false)
    @Expect(candidateTextOk("卸载"), false)
    // 实测候选里混进过「09, :, 52」这种时钟拼串——纯数字标点连起来的东西不是按钮
    @Expect(candidateTextOk("09, :, 52"), false)
    @Expect(candidateTextOk("09"), false)
    @Expect(candidateTextOk("..."), false)
    // 但"数字 + 汉字"的真实状态文本仍可点（字数统计、文件计数这类）
    @Expect(candidateTextOk("0 字符"), true)
}

@Test
public func testClickableTextsPreferClickableAndDedupe() {
    let nodes = ArrayList<LayoutNode>()
    nodes.add(nodeOf("普通文本", false))
    nodes.add(nodeOf("新建笔记", true))
    nodes.add(nodeOf("新建笔记", true))       // 重复渲染的同一个按钮
    nodes.add(nodeOf("12:34", true))          // 时钟即便标了 clickable 也不能进
    nodes.add(nodeOf("删除笔记", true))        // 危险词
    nodes.add(nodeOf("", true))               // 没文本的图标
    let got = clickableTextsOf(nodes, 5)
    // 可点的先收，重复/时钟/危险词/空文本一个都不许进
    @Expect(got.size, 2)
    @Expect(got[0], "新建笔记")
    @Expect(got[1], "普通文本")
}

@Test
public func testClickableTextsHonourTake() {
    let nodes = ArrayList<LayoutNode>()
    nodes.add(nodeOf("甲", true))
    nodes.add(nodeOf("乙", true))
    nodes.add(nodeOf("丙", true))
    @Expect(clickableTextsOf(nodes, 2).size, 2)
    // take<=0 直接空表（预算为 0 时不许乱点）
    @Expect(clickableTextsOf(nodes, 0).size, 0)
    // 候选不够就返回全部，不多不少
    @Expect(clickableTextsOf(nodes, 99).size, 3)
}

/*
 * 重枚举（0.39.102）：点一次现场就变一层，候选清单不能停在首屏快照上。
 * 实测 note-gen-2 2026-11-09：8 条候选点第二条起全「找不到节点」，7 条白花。
 */
@Test
public func testFirstUntriedSkipsTried() {
    let cands = ArrayList<String>()
    cands.add("甲")
    cands.add("乙")
    cands.add("丙")
    let tried = ArrayList<String>()
    // 一条都没试过 → 取第一条
    match (firstUntriedOf(cands, tried)) {
        case Some(x) => @Expect(x, "甲")
        case None => @Expect("不该为空", "")
    }
    // 试过前两条 → 取第三条（即使首屏清单里前两条已经不在当前版面了）
    tried.add("甲")
    tried.add("乙")
    match (firstUntriedOf(cands, tried)) {
        case Some(x) => @Expect(x, "丙")
        case None => @Expect("不该为空", "")
    }
}

@Test
public func testFirstUntriedEmptyWhenAllTried() {
    let cands = ArrayList<String>()
    cands.add("甲")
    let tried = ArrayList<String>()
    tried.add("甲")
    match (firstUntriedOf(cands, tried)) {
        case Some(_) => @Expect("应该没有候选了", "甲")
        case None => @Expect("ok", "ok")
    }
    // 空候选表也必须是 None（不能编一条出来乱点）
    let empty = ArrayList<String>()
    match (firstUntriedOf(empty, tried)) {
        case Some(_) => @Expect("空表不该给候选", "x")
        case None => @Expect("ok", "ok")
    }
}

@Test
public func testFirstUntriedFollowsCurrentScreen() {
    // 模拟"点了之后换了一屏"：新一屏的候选里旧账已试过的那条必须被跳过
    let screen1 = ArrayList<String>()
    screen1.add("文本")
    screen1.add("插图")
    let tried = ArrayList<String>()
    match (firstUntriedOf(screen1, tried)) {
        case Some(x) => tried.add(x)
        case None => ()
    }
    let screen2 = ArrayList<String>()   // 换了屏，出现一批新文本
    screen2.add("文本")                  // 旧屏也有的文本
    screen2.add("保存到")
    match (firstUntriedOf(screen2, tried)) {
        case Some(x) => @Expect(x, "保存到")
        case None => @Expect("新屏应该还有候选", "")
    }
}

/*
 * 前台闸（0.39.102）：锁屏时版面上是桌面（com.ohos.sceneboard）的日期文本，
 * 自动枚举照着点了一遍，落档里多了 4 条「日期点了没反应 → fail」——拿桌面冒充功能。
 */
@Test
public func testForegroundBundleSkipsEmptyRootValue() {
    // 根节点那几个 bundleName 是空串，取第一个非空的
    let js = "{\"attributes\":{\"bundleName\":\"\",\"text\":\"\"},\"children\":[{\"attributes\":" +
        "{\"bundleName\":\"com.ohos.sceneboard\"}}]}"
    @Expect(foregroundBundleOf(js), "com.ohos.sceneboard")
    // 读不到就如实给空串（调用方据此降级，不是猜一个）
    @Expect(foregroundBundleOf("{}"), "")
    @Expect(foregroundBundleOf(""), "")
    // 值里有转义引号时不许把半截当包名
    let js2 = "{\"bundleName\":\"com.x.note\"}"
    @Expect(foregroundBundleOf(js2), "com.x.note")
}

@Test
public func testForegroundGateBlocksSystemShell() {
    // 期望包名已知：对不上就拦，并且把两个包名都写出来
    let r1 = foregroundGateOf("com.ohos.sceneboard", "com.x.note")
    @Expect(r1.size > 0, true)
    @Expect(r1.contains("com.ohos.sceneboard"), true)
    @Expect(r1.contains("com.x.note"), true)
    // 对得上就放行
    @Expect(foregroundGateOf("com.x.note", "com.x.note"), "")
    // 期望包名未知：只拦系统界面，别的应用不拦（可能是别人起的调试场景）
    @Expect(foregroundGateOf("com.ohos.sceneboard", "").size > 0, true)
    @Expect(foregroundGateOf("com.third.party", ""), "")
    // 版面里没包名：不拦（别因为读不到就什么都不做）
    @Expect(foregroundGateOf("", "com.x.note"), "")
}

/*
 * 实质文本判据（0.39.102）：实测「保存到」判 pass 只因版面冒出了「09、:、48」，
 * 「添加」判 pass 只因冒出了「, ? !」——时钟与标点不许当"点了有反应"。
 */
@Test
public func testHasWordContentRejectsDigitsAndPunctuation() {
    // 纯数字 / 半角标点 / 空白：都不算内容
    @Expect(hasWordContent("48"), false)
    @Expect(hasWordContent("09"), false)
    @Expect(hasWordContent(":"), false)
    @Expect(hasWordContent("?"), false)
    @Expect(hasWordContent(","), false)
    @Expect(hasWordContent("0"), false)
    @Expect(hasWordContent("   "), false)
    @Expect(hasWordContent(""), false)
    // 汉字（含"数字 + 汉字"这种真实界面文本）与字母：算内容
    @Expect(hasWordContent("保存到"), true)
    @Expect(hasWordContent("0 字符"), true)
    @Expect(hasWordContent("3 个文件"), true)
    @Expect(hasWordContent("Save"), true)
}

