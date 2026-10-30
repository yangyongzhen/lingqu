package lingqu.tests

import std.collection.*
import std.fs.*
import lingqu.compiler.*
import lingqu.port.*

/*
 * T5-3 单测：hvigor 输出解析 + HAP 条目扫描 + HAP 装配闸（纯函数，D-009）。
 *
 * fixture 来自 2026-10-30 的真实运行（已剥 ANSI、裁剪）：
 *   samples/evidence/hvigor-assemble-hap.log  —— 成功那次（PackageHap + SignHap + BUILD SUCCESSFUL）
 *   samples/evidence/hvigor-arkts-error.log   —— 失败那次（ArkTS 缺 @ohos-rs/ability）
 */

func readLog(name: String): String {
    return String.fromUtf8(File.readFrom("samples/evidence/${name}"))
}

@Test
public func testParseHvigorSuccess(): Unit {
    let r = parseHvigorOutput(readLog("hvigor-assemble-hap.log"))
    @Assert(r.built, true)
    @Assert(r.errorCount, 0)
}

@Test
public func testParseHvigorFailure(): Unit {
    let r = parseHvigorOutput(readLog("hvigor-arkts-error.log"))
    @Assert(r.built, false)
    @Assert(r.errorCount > 0, true)
    @Assert(r.firstError.contains("ERROR"), true)
}

@Test
public func testParseHvigorBuildFailedWins(): Unit {
    // 边界：日志里既有 SUCCESSFUL 字样又有 BUILD FAILED（多模块时的常见噪声）→ 以 FAILED 为准
    let text = "> hvigor Finished :entry:assembleHap... after 1 ms\n" +
        "> hvigor BUILD FAILED in 2 s\n"
    @Assert(parseHvigorOutput(text).built, false)
    // 只有 SUCCESSFUL → true
    @Assert(parseHvigorOutput("> hvigor BUILD SUCCESSFUL in 11 s 441 ms\n").built, true)
    // 空输入
    @Assert(parseHvigorOutput("").built, false)
}

@Test
public func testHapNameIn(): Unit {
    @Assert(hapNameIn("> hvigor Finished :entry:assembleHap → entry/build/default/outputs/default/entry-default-signed.hap"),
        "entry-default-signed.hap")
    @Assert(hapNameIn("no hap here"), "")
    // 带引号/分隔符也能取到末段
    @Assert(hapNameIn("write \"a/b/entry-default.hap\""), "entry-default.hap")
}

@Test
public func testStripAnsi(): Unit {
    let colored = "\u{1b}[91mERROR\u{1b}[39m: boom"
    @Assert(stripAnsi(colored), "ERROR: boom")
    @Assert(stripAnsi("no color"), "no color")
}

/** 造一段"像 zip 的"字节流：只放文件名，够 scanHapEntries 扫 */
func zipish(names: Array<String>): Array<UInt8> {
    var s = ""
    for (n in names) {
        // zip 本地头里文件名前有个固定字节区，这里用 0 分隔模拟
        s += "\u{0}\u{0}" + n + "\u{0}"
    }
    return s.toArray()
}

@Test
public func testScanHapEntriesHealthy(): Unit {
    // 真实 HAP 里出现过的条目（1.40 MB 的 entry-default-signed.hap）
    let data = zipish(["module.json", "modules.abc", "libs/arm64-v8a/libentry.so",
        "pkgContextInfo.json", "resources/base/media/startIcon.png"])
    let e = scanHapEntries(data)
    @Assert(e.hasModuleJson, true)
    @Assert(e.hasArm64So, true)
    @Assert(e.arm64Sos.size, 1)
    @Assert(e.arm64Sos[0], "libs/arm64-v8a/libentry.so")
    @Assert(e.rawfileCount, 0)
    @Assert(e.ok(), true)
}

@Test
public func testScanHapEntriesFindsRawfile(): Unit {
    // 死资源：前端已在 .so 里，rawfile 下的副本读不到
    let data = zipish(["module.json", "libs/arm64-v8a/libentry.so",
        "rawfile/index.html", "rawfile/assets/index-AAA.js"])
    let e = scanHapEntries(data)
    @Assert(e.rawfileCount >= 2, true)
    @Assert(e.rawfileNames[0].startsWith("rawfile/"), true)
    @Assert(e.ok(), false)
}

@Test
public func testScanHapEntriesEdgeCases(): Unit {
    let empty: Array<UInt8> = []
    let e = scanHapEntries(empty)
    @Assert(e.hasModuleJson, false)
    @Assert(e.rawfileCount, 0)
    // 有 module.json 但没有 arm64 .so → 不 ok
    let onlyJson = scanHapEntries(zipish(["module.json"]))
    @Assert(onlyJson.hasModuleJson, true)
    @Assert(onlyJson.ok(), false)
    // 任意二进制噪声不炸
    let noise: Array<UInt8> = [0, 255, 1, 2, 3]
    @Assert(scanHapEntries(noise).ok(), false)
}

@Test
public func testHapGate(): Unit {
    // 干净：装配成功 + 有 module.json + 有 arm64 .so + 无 rawfile
    @Assert(checkHapGate(true, true, true, 0).passed, true)
    // 装配失败
    let notBuilt = checkHapGate(false, false, false, 0)
    @Assert(notBuilt.passed, false)
    @Assert(notBuilt.failures[0].contains("assembleHap"), true)
    // 缺 module.json
    let noJson = checkHapGate(true, false, true, 0)
    @Assert(noJson.passed, false)
    @Assert(noJson.failures[0].contains("module.json"), true)
    // 缺 arm64 .so
    let noSo = checkHapGate(true, true, false, 0)
    @Assert(noSo.passed, false)
    @Assert(noSo.failures[0].contains("libs/arm64-v8a"), true)
    // 有 rawfile 死资源
    let dead = checkHapGate(true, true, true, 3)
    @Assert(dead.passed, false)
    @Assert(dead.failures[0].contains("死资源"), true)
}
