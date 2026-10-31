package lingqu.tests

import std.fs.*
import lingqu.*

/*
 * 断点板位置（`taskBoardPathFor` / `resolveLqPath`）单测 —— 0.39.8「板子跟着工程走」。
 *
 * 背景：板子 0.39.7 之前写在**灵渠应用目录**，跨工程共用 → 打开 B 工程时顶部还显示
 * A 工程的进度（与"8 个路径框各填一遍"同源：同一件事实两份权威）。
 * 这里钉住：① 有工程 → 落在工程里；② 没工程 → 退回旧位置；
 * ③ 迁移期读侧双查（工程优先、CWD 兜底），别让旧板子突然读不到（AGENTS §4-33）。
 */

@Test
public func testBoardPathFollowsProject(): Unit {
    let p = taskBoardPathFor("E:/test/rust/habit-tree")
    @Assert(p.contains("habit-tree"), true)          // 前缀是工程根
    @Assert(p.endsWith("tasks.json"), true)
    @Assert(p.contains("/.lingqu/") || p.contains("\\.lingqu\\"), true)
    // 结尾带分隔符不该拼出 `x//.lingqu`
    @Assert(taskBoardPathFor("E:/test/rust/habit-tree/"), p)
}

@Test
public func testBoardPathFallsBackToLegacyWhenNoProject(): Unit {
    // 没有工程上下文（CLI/老调用方）：仍是应用级旧位置，不会因为这次改动而失效
    @Assert(taskBoardPathFor(""), legacyTaskBoardPath())
    @Assert(legacyTaskBoardPath().endsWith("tasks.json"), true)
    @Assert(legacyTaskBoardPath().startsWith(".lingqu"), true)   // 应用级旧位置
    @Assert(legacyTaskBoardPath().contains("habit-tree"), false)
}

@Test
public func testResolvePrefersProjectBoard(): Unit {
    // 迁移期双查：工程里有板子就读工程的
    let proj = "/tmp/lingqu-board-probe"
    let dir = proj + "/.lingqu"
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir), recursive: true)
        }
        File.writeTo(dir + "/tasks.json", "{}".toArray())
    } catch (e: Exception) {
        return   // /tmp 不可写则跳过，不造假
    }
    @Assert(resolveLqPath(proj, "tasks.json"), taskBoardPathFor(proj))
}

@Test
public func testResolveFallsBackToCwdBoard(): Unit {
    // 工程里没有板子、也没有工程路径 → 回旧位置（不抛、不返回空）
    @Assert(resolveLqPath("", "tasks.json"), legacyTaskBoardPath())
    // 有工程、但工程里没有板子：CWD 若存在旧板子就回落它（迁移期不丢证据）；
    // 两处都没有时回"应该写在那里"的工程位置。这里只钉住"不空、文件名对、二选一"，
    // 因为测试 CWD（仓库根）可能本来就有应用级旧板子。
    let r = resolveLqPath("/tmp/lingqu-board-empty-probe", "tasks.json")
    @Assert(r.endsWith("tasks.json"), true)
    @Assert(r.size > 0, true)
    @Assert(r == taskBoardPathFor("/tmp/lingqu-board-empty-probe") || r == legacyTaskBoardPath(), true)
}
