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
public func testCountersAutoAndGuide(): Unit {
    // T4-8 分档计数：auto/guide 各归各类，guide 只数 applied 的
    let res = PortResult()
    var a = RuleOutcome("R2-PORT-001", false, "", "", "")
    a.applied = true
    res.outcomes.add(a)
    var g = RuleOutcome("R2-PORT-012", false, "", "", "")
    g.tier = T_GUIDE
    g.applied = true
    res.outcomes.add(g)
    var g2 = RuleOutcome("R2-PORT-013", false, "", "", "")
    g2.tier = T_GUIDE
    res.outcomes.add(g2) // guide 但没 applied——不计数
    @Assert(res.autoCount(), 1)
    @Assert(res.humanCount(), 1)
    let cj = res.countersJson()
    // get 返回 Option，toString 是 "Some(1)"——先解包再比
    @Assert(cj.get("auto").getOrThrow().toString(), "1")
    @Assert(cj.get("guide").getOrThrow().toString(), "1")
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
