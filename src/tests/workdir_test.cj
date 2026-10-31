package lingqu.tests

import lingqu.*

/*
 * 落档位置（0.38.0「落档跟着工程走」）的纯函数单测。
 *
 * 断言故意**不依赖分隔符**（Windows 反斜杠 / Linux 斜杠都要过），
 * 因为宿主差异不该让测试变红——真正要钉的是"拼对了没、优先级对不对"。
 */

@Test
public func testLqDirOf(): Unit {
    // 空工程路径 → 退回旧行为（相对 CWD）
    @Assert(lqDirOf(""), ".lingqu")
    @Assert(lqDirOf("."), ".lingqu")
    @Assert(lqDirOf("   "), ".lingqu")
    // 正常工程：末尾拼 .lingqu
    let d = lqDirOf("E:/test/rust/habit-tree")
    @Assert(d.endsWith(".lingqu"), true)
    @Assert(d.contains("habit-tree"), true)
    // 末尾带分隔符也不许多一个分隔符（x//.lingqu 这种拼法会让落档路径变丑）
    let d2 = lqDirOf("E:/test/rust/habit-tree/")
    @Assert(d2 == d, true)
}

@Test
public func testLqPathOf(): Unit {
    let p = lqPathOf("E:/x", "scan/a.json")
    @Assert(p.endsWith("a.json"), true)
    @Assert(p.contains("scan"), true)
    @Assert(p.contains(".lingqu"), true)
    // rel 自带前导分隔符也要能吃
    let p2 = lqPathOf("E:/x", "/scan/a.json")
    @Assert(p2 == p, true)
    // 空工程路径 → 旧形态（分隔符按宿主，断言只钉形状不钉分隔符）
    let legacy = lqPathOf("", "scan/a.json")
    @Assert(legacy.contains(".lingqu"), true)
    @Assert(legacy.endsWith("a.json"), true)
    @Assert(legacy.contains("scan"), true)
}

@Test
public func testResolveLqPathFallsBackToLegacy(): Unit {
    // 两个都不存在时：有工程路径就回"应该写在那里"的新位置（报错指向正确地方）
    let r = resolveLqPath("E:/nonexist-project", "scan/none-habit-tree.json")
    @Assert(r.contains(".lingqu"), true)
    @Assert(r.contains("nonexist-project"), true)
    // 没有工程路径 → 回旧相对路径（调用方据此写/读 CWD 落档；分隔符按宿主）
    let legacy = resolveLqPath("", "scan/none-habit-tree.json")
    @Assert(legacy.contains(".lingqu"), true)
    @Assert(legacy.endsWith("none-habit-tree.json"), true)
}

@Test
public func testLqIsProjectScoped(): Unit {
    let proj = "E:/test/rust/habit-tree"
    let inside = lqPathOf(proj, "scan/x.json")
    @Assert(lqIsProjectScoped(inside, proj), true)
    // 旧路径不算工程内
    @Assert(lqIsProjectScoped(".lingqu/scan/x.json", proj), false)
    // 没有工程路径时恒 false
    @Assert(lqIsProjectScoped(inside, ""), false)
}
