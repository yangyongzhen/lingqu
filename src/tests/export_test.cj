package lingqu.tests

import std.collection.*
import lingqu.*

/*
 * 移植成果导出（0.39.137）的单测：**只测纯函数**（排除规则 / 时间戳 / 目标目录）。
 *
 * IO 半边（真拷贝）不在这里造夹具——按 AGENTS §1 第 5 条，文件系统行为靠真跑验证；
 * 这里钉住的是"该跳的跳不跳、目录名怎么拼"这类一错就静默的判断。
 */

@Test
public func testShouldSkipExportEntryDirs(): Unit {
    // 依赖与产物目录：任意层级都跳（只看最后一段）
    @Assert(shouldSkipExportEntry("node_modules", true), true)
    @Assert(shouldSkipExportEntry("apps/desktop/node_modules", true), true)
    @Assert(shouldSkipExportEntry("src-tauri/target", true), true)
    @Assert(shouldSkipExportEntry("dist", true), true)
    @Assert(shouldSkipExportEntry("src-tauri/gen/ohos/oh_modules", true), true)
    @Assert(shouldSkipExportEntry(".git", true), true)
    // 源码目录不许跳
    @Assert(shouldSkipExportEntry("src", true), false)
    @Assert(shouldSkipExportEntry("src-tauri/gen/ohos/entry/src/main/ets", true), false)
    // 只是**名字里含** node_modules 的普通目录，不该被误跳
    @Assert(shouldSkipExportEntry("docs/node_modules-guide", true), false)
}

@Test
public func testShouldSkipExportEntryFiles(): Unit {
    // 二进制产物按后缀跳
    @Assert(shouldSkipExportEntry("a/b/libfoo.so", false), true)
    @Assert(shouldSkipExportEntry("app.hap", false), true)
    @Assert(shouldSkipExportEntry("x/y/z.dll", false), true)
    // 源码/配置/文档必须留
    @Assert(shouldSkipExportEntry("src/main.rs", false), false)
    @Assert(shouldSkipExportEntry("package.json", false), false)
    @Assert(shouldSkipExportEntry("README.md", false), false)
    // 产物前缀（.so 藏在 libs 下时，即使不带 .so 后缀也跳）
    @Assert(shouldSkipExportEntry("src-tauri/gen/ohos/entry/libs/arm64-v8a/libx.so", false), true)
    @Assert(shouldSkipExportEntry("src-tauri/gen/ohos/entry/build/default/x.bin", false), true)
    // Windows 反斜杠进来也要按同一口径判（调用方可能没归一化）
    @Assert(shouldSkipExportEntry("apps\\desktop\\node_modules\\x.js", false), false)
    @Assert(shouldSkipExportEntry("apps\\desktop\\node_modules", true), true)
}

@Test
public func testExportStampOf(): Unit {
    // 标准 ISO：取到分钟
    @Assert(exportStampOf("2026-11-22T21:40:05+08:00"), "20261122-2140")
    // 带小数秒与空格分隔
    @Assert(exportStampOf("2026-01-02 03:04:05.123"), "20260102-0304")
    // 解析不出来也别造假的：原串净化后返回（长度不足 12 也要非空且不含非法字符）
    let odd = exportStampOf("x")
    @Assert(odd.size > 0, true)
    @Assert(odd.contains(":"), false)
    @Assert(odd.contains("T"), false)
}

@Test
public func testExportTargetDirOf(): Unit {
    let root = "C:\\Users\\tester\\lingqu-migrated"
    let d1 = exportTargetDirOf(root, "dbx", "20261122-2140", 1)
    @Assert(d1.contains("dbx-20261122-2140"), true)
    // 同一分钟重复导出要能区分（否则会覆盖上一次的成果）
    let d2 = exportTargetDirOf(root, "dbx", "20261122-2140", 2)
    @Assert(d2.contains("dbx-20261122-2140-2"), true)
    @Assert(d1 == d2, false)
    // 工程名里的非法字符要净化掉（不能拼出非法路径，§4-26 同族）。
    // 注意：不能断言"整串不含 `:`"——根目录自带的盘符（`C:`）是合法路径内容。
    // 这里用两个不依赖宿主分隔符的判据：① 整串不含 `*`（根里没有）；② 末段等于净化后的名字。
    let d3 = exportTargetDirOf(root, "a:b*c", "20261122-2140", 1)
    @Assert(d3.contains("*"), false)
    @Assert(d3.endsWith("a_b_c-20261122-2140"), true)
}

/*
 * 导出停滞判据（0.39.140）：导出经 IPC 时曾在大文件处静默卡死（§4-211），
 * 所以"卡住"必须能被判出来并报错。这里只测纯函数的三档。
 */
@Test
public func testExportStallVerdictOf(): Unit {
    // 没在跑：idle 再大也不许说"卡住"（跑完了/没开始都不是停滞）
    @Assert(exportStallVerdictOf(false, 0) == "")
    @Assert(exportStallVerdictOf(false, 99999) == "")
    // 在跑且有进展 ⇒ running
    @Assert(exportStallVerdictOf(true, 0) == "running")
    // 边界：阈值是"秒"，差 1 秒还不算卡（别把慢文件误判成卡死）
    @Assert(exportStallVerdictOf(true, EXPORT_STALL_SECS - 1) == "running")
    // 到阈值（含）⇒ stalled；阈值本身必须为正，否则判据形同虚设
    @Assert(EXPORT_STALL_SECS > 0, true)
    @Assert(exportStallVerdictOf(true, EXPORT_STALL_SECS) == "stalled")
    @Assert(exportStallVerdictOf(true, EXPORT_STALL_SECS + 300) == "stalled")
}

/*
 * 分块拷贝的写入长度（0.39.142）：末块只写实读部分是这类改动最容易错的地方——
 * 多写会把缓冲尾部残留的 0 塞进目标文件，文件大小还对、内容已坏。
 */
@Test
public func testExportWriteLenOf(): Unit {
    // EOF / 异常返回值：一个字节都不写
    @Expect(exportWriteLenOf(0, 1024), 0)
    @Expect(exportWriteLenOf(-1, 1024), 0)
    // 末块：只写实读部分（这是唯一会坏的边界）
    @Expect(exportWriteLenOf(500, 1024), 500)
    // 满块 / 超过缓冲（防御）：夹到缓冲大小，绝不超过
    @Expect(exportWriteLenOf(1024, 1024), 1024)
    @Expect(exportWriteLenOf(4096, 1024), 1024)
    // 块大小本身必须是正数，否则判据形同虚设
    @Assert(EXPORT_CHUNK_BYTES > 0, true)
}
