package lingqu.tests

import lingqu.*

/*
 * 「从头重跑」归档层（`src/reset_records.cj`）的纯函数单测。
 *
 * 为什么必须有单测：这两个函数决定了"哪些落档会被搬走"和"搬到哪个目录"——
 * 判错一次就是**误搬用户的真机证据/经验/源码**，或者把档案目录套成俄罗斯套娃。
 * 只测纯函数（白名单挑选 + 目录名净化），文件搬运本身以实跑为准（AGENTS §1-5）。
 */

@Test
public func testResetTargetsPicksOnlyOwnRecords(): Unit {
    let entries = ["scan", "deps", "port", "build", "hap", "sign", "deploy", "verify", "report",
                   "tasks.json", "tasks.json.bak",
                   "notes", "diagnose", "evidence", "agent", "migrate", "src", "package.json"]
    let got = resetTargetsOf(entries)
    @Assert(got.size, 11)
    for (want in ["scan", "deps", "report", "tasks.json", "tasks.json.bak"]) {
        @Assert(got.contains(want), true)
    }
    // 经验/台账/截图/源码一律不许动（飞轮的输入，不能被"重跑"顺手清掉）
    for (keep in ["notes", "diagnose", "evidence", "agent", "src", "package.json"]) {
        @Assert(got.contains(keep), false)
    }
}

@Test
public func testResetTargetsSkipsExistingArchives(): Unit {
    // 连搬两次：旧档案目录不能再被套进新档案里
    let entries = ["_archive-2026-11-02T22-00-00", "scan", "_archive-manual"]
    let got = resetTargetsOf(entries)
    @Assert(got.size, 1)
    @Assert(got[0], "scan")
}

@Test
public func testResetTargetsEmptyDir(): Unit {
    // 空目录（或只有不属于我们的东西）→ 什么都不搬，调用方按"没落档"处理
    @Assert(resetTargetsOf(Array<String>()).size, 0)
    @Assert(resetTargetsOf(["notes", "diagnose"]).size, 0)
}

@Test
public func testArchiveDirNameSanitized(): Unit {
    // nowText() 的形态是 2026-11-02T22:24:26.077+08:00 —— `:` `+` `T` 在 Windows 路径里非法/难看，必须净化成 `-`。
    // 断言**整串精确值**：第一版用 StringBuilder.append(Byte) 拼，字节被按十进制打印成 "45"，
    // 而"只断言不含 ':'"这种弱判据照样通过（AGENTS §4-62 同族坑，单测当场抓出）。
    let n = archiveDirNameOf("2026-11-02T22:24:26.077+08:00")
    @Assert(n, "_archive-2026-11-02-22-24-26.077-08-00")
    @Assert(n.contains(":"), false)
    @Assert(n.contains("+"), false)
    @Assert(n.contains("/"), false)
    @Assert(n.contains("\\"), false)
    @Assert(n.contains(" "), false)
}

@Test
public func testArchiveDirNameFallback(): Unit {
    // 时间戳为空/太短 → 给兜底名，别产出等于前缀的空目录（否则下次会被当成档案跳过）
    @Assert(archiveDirNameOf(""), "_archive-manual")
    @Assert(archiveDirNameOf("x"), "_archive-manual")
}
