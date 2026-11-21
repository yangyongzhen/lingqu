package lingqu.tests

import std.collection.*
import std.fs.*
import lingqu.port.*

/*
 * P4 第二刀单测：工具链落盘（T4-3）、lib.rs 注入（T4-4）、前端兼容层（T4-5）、分档计数（T4-8）。
 * 只测纯函数（D-009）：模板内容 / 幂等判定 / guide 档探测，写盘由命令层负责。
 */

@Test
public func testRustToolchainTomlBothHosts(): Unit {
    // Windows：gnullvm（llvm-mingw 环境缺 -lgcc_eh 的实测结论）
    let win = rustToolchainToml(true)
    @Assert(win.contains("stable-x86_64-pc-windows-gnullvm"), true)
    @Assert(win.contains("aarch64-unknown-linux-ohos"), true)
    // Linux：默认 GNU channel 即可
    let linux = rustToolchainToml(false)
    @Assert(linux.contains("stable-x86_64-unknown-linux-gnu"), true)
    @Assert(linux.contains("lingqu: R2-PORT-007"), true)
}

@Test
public func testCargoConfigTomlSubstitutesSdkPath(): Unit {
    let cfg = cargoConfigToml("/opt/sdk/native")
    @Assert(cfg.contains("linker = \"/opt/sdk/native/llvm/bin/clang\""), true)
    @Assert(cfg.contains("--sysroot=/opt/sdk/native/sysroot"), true)
    @Assert(cfg.contains("CC_aarch64_unknown_linux_ohos"), true)
    @Assert(cfg.contains("lingqu: R2-PORT-008"), true)
}

@Test
public func testCargoConfigTomlSafeForWindowsPath(): Unit {
    // 0.39.79 实测复现（rust-music-2 全流程）：NATIVE_OHOS_SDK 是 Windows 形态时，
    // 路径被原样拼进 TOML 双引号串 → `\o`/`\D` 不是合法转义 → cargo 报
    // `could not parse TOML configuration`，build 连 manifest 都读不进去（exit=101）。
    // 判据：生成的内容里**一个反斜杠都不该剩**，且路径仍是可用的正斜杠形态。
    let win = cargoConfigToml("D:\\oh\\DevEcoStudio\\sdk\\default\\openharmony\\native")
    @Assert(win.contains("D:/oh/DevEcoStudio/sdk/default/openharmony/native/llvm/bin/clang"), true)
    @Assert(win.contains("\\"), false)
    // 追加片段（guide 档的 after）同口径
    let envOnly = cargoEnvOnlyToml("D:\\oh\\sdk\\native")
    @Assert(envOnly.contains("\\"), false)
    // Linux 形态不受影响
    @Assert(tomlSafePath("/opt/sdk/native"), "/opt/sdk/native")
}

/*
 * 0.39.131：R2-PORT-008 的跳过判据不能只看「键在不在」。
 * EcoPaste 现场：旧版本生成的 `.cargo/config.toml` 里 `linker = "D:\oh\…"` 的 `\o` 是非法
 * 转义，cargo 连 manifest 都读不进去（exit=101），而 `[env]` / `CC_…` 两个键都在 ⇒ 永远跳过。
 */
@Test
public func testTomlBareBackslashDetection(): Unit {
    // 真坏：双引号内的 `\o` / `\D` 不是 TOML 合法转义
    @Assert(tomlHasBareBackslashOf("linker = \"D:\\oh\\DevEcoStudio/native/llvm/bin/clang\"\n"), true)
    @Assert(tomlHasBareBackslashOf("CC_x = \"D:\\oh\\sdk\"\n"), true)
    // 合法转义不算：`\\` `\t` `\n` `\"` `\uXXXX`
    @Assert(tomlHasBareBackslashOf("a = \"C:\\\\x\"\n"), false)
    @Assert(tomlHasBareBackslashOf("a = \"x\\ty\"\n"), false)
    @Assert(tomlHasBareBackslashOf("a = \"x\\ny\"\n"), false)
    @Assert(tomlHasBareBackslashOf("a = \"q\\\"w\"\n"), false)
    @Assert(tomlHasBareBackslashOf("a = \"\\u4e2d\"\n"), false)
    // 引号外的反斜杠（注释里）不算问题
    @Assert(tomlHasBareBackslashOf("# 这是 D:\\oh 式的注释\nlinker = \"D:/oh/x\"\n"), false)
    // 空串/正常内容
    @Assert(tomlHasBareBackslashOf(""), false)
    // 当前模板生成的永远是合法的（防回归：生成器自己产出坏内容时这条会红）
    @Assert(tomlHasBareBackslashOf(cargoConfigToml("D:\\oh\\DevEcoStudio\\sdk\\default\\openharmony\\native")), false)
}

@Test
public func testLibRsInjectionBlockShape(): Unit {
    let block = libRsInjectionBlock()
    @Assert(block.contains("fn resolve_app_data_dir"), true)
    @Assert(block.contains("/data/storage/el2/base/files"), true)
    @Assert(block.contains("fn install_panic_hook"), true)
    @Assert(block.contains("panic.log"), true)
    @Assert(block.contains("lingqu: R2-PORT-009"), true)
}

@Test
public func testLocalStorageShimJsShape(): Unit {
    let shim = localStorageShimJs()
    @Assert(shim.contains("!window.localStorage"), true)
    @Assert(shim.contains("__TAURI_INTERNALS__"), true)
    @Assert(shim.contains("defineProperty"), true)
    @Assert(shim.contains("lingqu: R2-PORT-011"), true)
}

@Test
public func testToolchainOutcomesIdempotentFlag(): Unit {
    // applied 的判定只看"文件有没有配过"——本测试不落盘，所以两条都应为 applied=true
    let outs = toolchainOutcomes("/tmp/lingqu-nonexistent-port-probe", "/opt/sdk/native", false)
    @Assert(outs.size, 2)
    @Assert(outs[0].id, "R2-PORT-007")
    @Assert(outs[0].applied, true)
    @Assert(outs[1].id, "R2-PORT-008")
    @Assert(outs[1].applied, true)
}

@Test
public func testCargoEnvOnlyTomlShape(): Unit {
    // R2-PORT-008 缺段时给"只补 [env]"的片段：不能整份覆盖用户既有的 linker 配置
    let s = cargoEnvOnlyToml("/opt/sdk/native")
    @Assert(s.contains("[env]"), true)
    @Assert(s.contains("CC_aarch64_unknown_linux_ohos = \"/opt/sdk/native/llvm/bin/clang\""), true)
    @Assert(s.contains("AR_aarch64_unknown_linux_ohos"), true)
    @Assert(s.contains("--sysroot=/opt/sdk/native/sysroot"), true)
    // 片段里不该再出现 target 段（那是既有文件已经有的）
    @Assert(s.contains("[target.aarch64-unknown-linux-ohos]"), false)
}

@Test
public func testToolchain008GuideWhenEnvMissing(): Unit {
    // 0.39.7 实测：m3u8dl-tauri 的 .cargo/config.toml 有 target 段、缺 [env] →
    // ring 的 cc-rs 退回宿主 cc，报 `cc-rs: … "cc" … --target=aarch64-unknown-linux-ohos`。
    // 这种"半配好"必须降成 guide（不写盘、不覆盖），而不是当成已配好跳过。
    let dir = "/tmp/lingqu-ccenv-probe"
    let cargoDir = "${dir}/.cargo"
    try {
        if (!exists(Path(cargoDir))) {
            Directory.create(Path(cargoDir), recursive: true)
        }
        File.writeTo("${cargoDir}/config.toml",
            "[target.aarch64-unknown-linux-ohos]\nlinker = \".\\\\ohos-clang.cmd\"\n".toArray())
    } catch (e: Exception) {
        return // /tmp 不可写则跳过，不造假
    }
    let outs = toolchainOutcomes(dir, "/opt/sdk/native", false)
    let o8 = outs[1]
    @Assert(o8.id, "R2-PORT-008")
    @Assert(o8.applied, false)          // 不覆盖用户文件
    @Assert(o8.tier, T_GUIDE)
    @Assert(o8.needsHuman, true)        // 计一次人工介入（A3 口径）
    @Assert(o8.note.contains("缺 [env]"), true)
    @Assert(o8.after.contains("CC_aarch64_unknown_linux_ohos"), true)
}

@Test
public func testToolchain008SkipsWhenEnvPresent(): Unit {
    // 正常路径：target 段 + [env] 都在 → 跳过，不误报人工介入
    let dir = "/tmp/lingqu-ccenv-probe2"
    let cargoDir = "${dir}/.cargo"
    try {
        if (!exists(Path(cargoDir))) {
            Directory.create(Path(cargoDir), recursive: true)
        }
        File.writeTo("${cargoDir}/config.toml", cargoConfigToml("/opt/sdk/native").toArray())
    } catch (e: Exception) {
        return
    }
    let outs = toolchainOutcomes(dir, "/opt/sdk/native", false)
    let o8 = outs[1]
    @Assert(o8.applied, false)
    @Assert(o8.needsHuman, false)
    @Assert(o8.note.contains("跳过"), true)
}

@Test
public func testCountersAutoAndGuide(): Unit {
    // T4-8 分档计数（0.13.1 语义）：auto = 规则机械完成；guide = **需要人拍板**（needsHuman），
    // 与 applied（动没动手）分开——008/010 那种"不写坏文件但必须人来填"的项以前被漏计
    let res = PortResult()
    var a = RuleOutcome("R2-PORT-001", false, "", "", "")
    a.applied = true
    res.outcomes.add(a)
    var g = RuleOutcome("R2-PORT-012", false, "", "", "")
    g.tier = T_GUIDE
    g.applied = true
    g.needsHuman = true
    res.outcomes.add(g)
    var g2 = RuleOutcome("R2-PORT-013", false, "", "", "")
    g2.tier = T_GUIDE
    res.outcomes.add(g2) // guide 但探测无命中（无可处置项）——不计数
    var g3 = RuleOutcome("R2-PORT-008", false, "", "", "")
    g3.tier = T_GUIDE
    g3.needsHuman = true // 未设 NATIVE_OHOS_SDK：没写盘，但必须人填 → 计入人工介入
    res.outcomes.add(g3)
    @Assert(res.autoCount(), 1)
    @Assert(res.humanCount(), 2)
    let cj = res.countersJson()
    // get 返回 Option，toString 是 "Some(1)"——先解包再比
    @Assert(cj.get("auto").getOrThrow().toString(), "1")
    @Assert(cj.get("guide").getOrThrow().toString(), "2")
}

@Test
public func testGuideOutcomesOnNonexistentDir(): Unit {
    // 错误路径：目录不存在 → guide 两条都不 applied（不抛异常、不静默崩）
    let outs = frontendGuideOutcomes("/tmp/lingqu-nonexistent-port-probe")
    @Assert(outs.size, 2)
    @Assert(outs[0].id, "R2-PORT-012")
    @Assert(outs[0].applied, false)
    @Assert(outs[1].id, "R2-PORT-013")
    @Assert(outs[1].applied, false)
}

@Test
public func testGuideOutcomesDetectRealCalls(): Unit {
    // 主路径：临时前端 fixture 里放一个裸 confirm( 调用，探测应命中
    // （habit-tree 本机样本是**迁移后**工程，裸 confirm( 已全部换成 confirmDialog——
    //   对它 applied=false 才是正确行为，正向用 fixture 验证）
    let dir = "/tmp/lingqu-guide-probe"
    let sub = "${dir}/js"
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir))
        }
        if (!exists(Path(sub))) {
            Directory.create(Path(sub))
        }
        File.writeTo("${sub}/app.ts", "const ok = confirm(\"确定删除？\");\n".toArray())
    } catch (e: Exception) {
        return // /tmp 不可写则跳过，不造假
    }
    let outs = frontendGuideOutcomes(dir)
    @Assert(outs[0].applied, true)
    @Assert(outs[0].before.contains("app.ts:1"), true)
    // 迁移后的 habit-tree 前端：裸调用已清零，applied=false 才对
    let migrated = "/root/test/cj/habit-tree-ohos/src"
    if (exists(Path(migrated))) {
        let outs2 = frontendGuideOutcomes(migrated)
        @Assert(outs2[0].applied, false)
    }
}
