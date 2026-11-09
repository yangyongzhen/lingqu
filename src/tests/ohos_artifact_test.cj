package lingqu.tests

import std.collection.*
import lingqu.port.*

/*
 * P5 单测：鸿蒙产物闸（0.39.81）。
 *
 * 复现的 bug（0.39.79 实测）：rust-music-2 只有 bin target，cargo 编出
 * `target/aarch64-unknown-linux-ohos/release/rust-music`（11,084,368 字节的 **exe**），
 * 而 HAP 里要的是 `lib<name>.so`。旧版 build 只判 exitCode=0 / errorCount=0，
 * 于是把 exe 当移植产物报了"通过"——这就是假绿。
 */

private func binOnlyCargoToml(): String {
    return "[package]\nname = \"rust-music\"\nversion = \"0.1.0\"\n\n[dependencies]\ntauri = { version = \"2\" }\n"
}

private func cdylibCargoToml(): String {
    return "[package]\nname = \"rust-music\"\nversion = \"0.1.0\"\n\n[lib]\nname = \"rust_music_lib\"\ncrate-type = [\"staticlib\", \"cdylib\", \"rlib\"]\n"
}

@Test
public func testExpectedLibNamePrefersLibSection(): Unit {
    // `[lib] name` 才是 cargo 生成 lib<name>.so 的依据，包名只是兜底
    @Assert(expectedLibNameOf(cdylibCargoToml(), "rust-music"), "librust_music_lib.so")
    // 只有包名时：连字符换下划线（Cargo 的库名规则）
    @Assert(expectedLibNameOf(binOnlyCargoToml(), "rust-music"), "librust_music.so")
    // Cargo.toml 读不到（空串）时退回工程名，仍要给出一个可判定的期望值
    @Assert(expectedLibNameOf("", "my-app"), "libmy_app.so")
    @Assert(expectedLibNameOf("", ""), "libapp.so")
}

@Test
public func testHasCdylibCrateTypeDetectsDeclaration(): Unit {
    // 只有 bin target：没有 [lib] 段，也就没有 cdylib
    @Assert(hasCdylibCrateType(binOnlyCargoToml()), false)
    // 常规写法
    @Assert(hasCdylibCrateType(cdylibCargoToml()), true)
    // 跨行数组（真实工程的常见排版）
    let multi = "[lib]\nname = \"x\"\ncrate-type = [\n    \"staticlib\",\n    \"cdylib\",\n]\n"
    @Assert(hasCdylibCrateType(multi), true)
    // [lib] 里没有 cdylib（静态库工程）
    @Assert(hasCdylibCrateType("[lib]\nname = \"x\"\ncrate-type = [\"staticlib\"]\n"), false)
    // 注释里出现 cdylib 不算数（否则闸会被一句注释骗过）
    @Assert(hasCdylibCrateType("[lib]\n# crate-type = [\"cdylib\"] 先不开\nname = \"x\"\n"), false)
}

@Test
public func testOhosArtifactGateBlocksBinOnlyProject(): Unit {
    // 编译失败：由编译闸说，产物闸不重复报（两条失败其实是同一件事）
    @Assert(checkOhosArtifactGate(1, 3, "librust_music.so", "", false).passed, true)
    // 编译成功且产出了 .so：通过
    @Assert(checkOhosArtifactGate(0, 0, "librust_music.so", "/x/target/release/librust_music.so", true).passed, true)
    // 编译成功但没有 .so（0.39.79 的假绿现场）：必须失败
    let rep = checkOhosArtifactGate(0, 0, "librust_music.so", "", false)
    @Assert(rep.passed, false)
    @Assert(rep.failures.size, 1)
    let msg = rep.failures[0]
    @Assert(msg.contains("librust_music.so"), true)
    // 还要指出根因方向：没有 cdylib 声明
    @Assert(msg.contains("cdylib"), true)
    // 有 cdylib 声明却没产物，是另一类问题（编译产物被清/目标名不符），提示里再怪 cdylib 就是误导
    let rep2 = checkOhosArtifactGate(0, 0, "librust_music.so", "", true)
    @Assert(rep2.passed, false)
    @Assert(rep2.failures[0].contains("cdylib"), false)
}

@Test
public func testTomlValueOfLineHandlesQuotesAndComments(): Unit {
    @Assert(tomlValueOfLine("name = \"rust_music\"", "name"), "rust_music")
    @Assert(tomlValueOfLine("  name=\"x\"  ", "name"), "x")
    @Assert(tomlValueOfLine("name = 'y'", "name"), "y")
    @Assert(tomlValueOfLine("crate-type = [\"cdylib\", \"rlib\"]", "crate-type"), "[\"cdylib\", \"rlib\"]")
    // 行尾注释要切掉，否则库名后面会挂一段注解
    @Assert(tomlValueOfLine("name = \"z\"  # 库名", "name"), "z")
    // 键不匹配 / 不是 key=value：给空串（调用方据此退回包名）
    @Assert(tomlValueOfLine("version = \"0.1.0\"", "name"), "")
    @Assert(tomlValueOfLine("name", "name"), "")
}

/*
 * 复现 0.39.100 的假红（note-gen-2 现场，2026-11-09 实测）：
 * cargo 报的 artifact 顺序是 ["libpdf_inspector-<hash>.so", "libtauri_app_lib.a", "libtauri_app_lib.so"]，
 * 按「第一个 `.so`」取会拿 deps 里的 hash 中间产物，拼成 release/libpdf_inspector-<hash>.so
 * （不存在）⇒ 定位为空 ⇒ 产物闸报「编译成功但没产出 libtauri_app_lib.so」，前端指纹闸也被跳过。
 */
@Test
public func testSoCandidateRelsPutsExpectedArtifactFirst(): Unit {
    let arts = ArrayList<String>()
    arts.add("libpdf_inspector-dfd192e6df9e9eb4.so")
    arts.add("libtauri_app_lib.a")
    arts.add("libtauri_app_lib.so")
    let rels = soCandidateRelsOf(arts, "libtauri_app_lib.so")
    // 期望名排第一：这就是 HAP 真正要加载的那个
    @Assert(rels.size > 0, true)
    @Assert(rels[0], "libtauri_app_lib.so")
    // 不该把不带 hash 的期望名塞进 deps（它不在那儿）
    @Assert(rels[0] != "deps/libtauri_app_lib.so", true)
    // 其它 .so 仍作为兜底候选，且同时给出 deps 形态（hash 产物落在 deps 里）
    var hasDep = false
    for (r in rels) {
        if (r == "deps/libpdf_inspector-dfd192e6df9e9eb4.so") {
            hasDep = true
        }
    }
    @Assert(hasDep, true)
    // 期望名与 artifacts 重名时不重复列（只出现一次，避免无意义的重复 stat）
    let dup = ArrayList<String>()
    dup.add("libgrove_lib.so")
    let rels2 = soCandidateRelsOf(dup, "libgrove_lib.so")
    @Assert(rels2[0], "libgrove_lib.so")
    @Assert(rels2[1], "deps/libgrove_lib.so")
    @Assert(rels2.size, 2)
    // 没有产物名（拿不到 [lib]/包名）时只按 artifacts 罗列，不瞎猜
    let none = soCandidateRelsOf(arts, "")
    @Assert(none[0], "libpdf_inspector-dfd192e6df9e9eb4.so")
    // 一条 .so 都没有：空列表（调用方据此让闸如实报"没产出"）
    let empty = soCandidateRelsOf(ArrayList<String>(), "libx.so")
    @Assert(empty.size, 1)
    @Assert(empty[0], "libx.so")
}
