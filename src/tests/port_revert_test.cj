package lingqu.tests

import std.collection.*
import std.fs.*
import lingqu.port.*

/*
 * 0.13.1 审核修复的回归用例（每条对应 `docs/进度记录.md` 的审核轮次）。
 *
 * 这些用例的共同点：它们**本来应该是红的**——说明修复前的问题不是"没人写测试"，
 * 而是"该测的地方没测"（命令层的路径/常量漂移、规则对真实工程的破坏性改写）。
 */

// ===== 修 1：t2h:revert 与 apply 的备份路径必须同源 =====

@Test
public func testRevertPairsCoverAllAppliedFiles(): Unit {
    // 现象（0.11.0~0.13.0）：apply 把备份写到 .lingqu/port/<工程>/<文件>.bak，
    // 而 revert 还在找旧路径 .lingqu/port/<工程>-Cargo.toml.bak → 回滚永远报"没有备份"。
    // 这条用例锁的是「映射表本身」，命令层只需按表做 IO，不会再各写一份路径。
    let pairs = revertPairs()
    // 0.39.53：R2-PORT-015 也会改工程文件（gen/ohos/entry/hvigorfile.ts），回滚表跟着变 6 条。
    // 这条断言的作用就是"改了文件却没进回滚表"时当场报红（§4-33）。
    @Assert(pairs.size, 6)

    var cargoRel = "unset"
    var sawToolchain = false
    var sawConfig = false
    var sawLib = false
    var sawIndex = false
    var sawHvigor = false
    for (p in pairs) {
        if (p.backupFile == BAK_CARGO) {
            cargoRel = p.relTarget
        }
        if (p.backupFile == BAK_TOOLCHAIN && p.relTarget == "src-tauri/rust-toolchain.toml") {
            sawToolchain = true
        }
        if (p.backupFile == BAK_CARGO_CONFIG && p.relTarget == "src-tauri/.cargo/config.toml") {
            sawConfig = true
        }
        if (p.backupFile == BAK_LIBRS && p.relTarget == "src-tauri/src/lib.rs") {
            sawLib = true
        }
        if (p.backupFile == BAK_INDEX && p.relTarget == "index.html") {
            sawIndex = true
        }
        if (p.backupFile == BAK_HVIGORFILE && p.relTarget == "src-tauri/gen/ohos/entry/hvigorfile.ts") {
            sawHvigor = true
        }
    }
    // Cargo.toml 的落点由命令层用 cargoTomlPathOf 解析（可能在 src-tauri/ 也可能在根）
    @Assert(cargoRel, "")
    @Assert(sawToolchain, true)
    @Assert(sawConfig, true)
    @Assert(sawLib, true)
    @Assert(sawIndex, true)
    @Assert(sawHvigor, true)
}

@Test
public func testBackupPathsAreDistinctFromLegacy(): Unit {
    // 新路径与旧路径不能撞在一起，否则旧备份会被当成新备份写回错文件
    let name = "habit-tree"
    @Assert(backupDirOf(name), ".lingqu/port/habit-tree")
    @Assert(legacyCargoBakOf(name), ".lingqu/port/habit-tree-Cargo.toml.bak")
    @Assert(backupDirOf(name) != legacyCargoBakOf(name), true)
}

// ===== 修 2：tauri 钉版规则不得丢用户的键、不得改坏多行 features =====

@Test
public func testTauriPinPreservesOtherKeys(): Unit {
    // 修复前：一律重写成 { version, features } → default-features = false 被静默丢掉（改行为）
    let toml = "        [dependencies]\n        tauri = { version = \"2\", default-features = false, features = [\"devtools\"] }\n"
    let res = applyCargoTomlRules(toml)
    @Assert(res.afterText.contains("default-features = false"), true)
    @Assert(res.afterText.contains("\"devtools\""), true)
    @Assert(res.afterText.contains("custom-protocol"), true)
    @Assert(res.afterText.contains("protocol-asset"), true)
    @Assert(res.afterText.contains("\"=2.11.5\""), true)
    // 改完必须幂等（第二次跑 applied=0）
    @Assert(isIdempotent(res), true)
}

@Test
public func testTauriPinMultilineFeaturesNotTouched(): Unit {
    // 修复前：多行 features 只匹配到首行、拿不到 `]` → 丢掉用户 features 却留下续行 →
    // Cargo.toml 语法都坏了。现在如实跳过并转 guide（不猜、不破坏）。
    let toml = "        [dependencies]\n        tauri = { version = \"2\", features = [\n            \"devtools\",\n        ] }\n"
    let res = applyCargoTomlRules(toml)
    var applied = true
    var tier = ""
    for (o in res.outcomes) {
        if (o.id == "R2-PORT-002") {
            applied = o.applied
            tier = o.tier
        }
    }
    @Assert(applied, false)
    @Assert(tier, T_GUIDE)
    // 原始行一个字节都没动（续行还在，语法不坏）
    @Assert(res.afterText.contains("tauri = { version = \"2\", features = ["), true)
    @Assert(res.afterText.contains("\"devtools\","), true)
}

@Test
public func testOtherKeysOfParsesTopLevelOnly(): Unit {
    // 顶层逗号切分：features 数组内部的逗号不能当分隔符（否则会切出半个 feature）
    let line = "tauri = { version = \"2\", default-features = false, features = [\"a\", \"b\"] }"
    let extra = otherKeysOf(line, ["version", "features"])
    @Assert(extra, "default-features = false")
    // 没有花括号 → 空串（普通 "2" 版本行没有可保留的键）
    @Assert(otherKeysOf("tauri = \"2\"", ["version"]), "")
}

// ===== 修 3：R2-PORT-010 必须先有 009 注入的函数定义 =====

@Test
public func testSetupWiringBlockedWithout009(): Unit {
    // 修复前：009 没落地（没有 fn install_panic_hook）时，010 照样在 setup 里插调用
    // → 用户工程报 cannot find function install_panic_hook —— 工具把人工程改坏了
    let dir = ".lingqu/tmp-test-010"
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir))
        }
        File.writeTo("${dir}/lib.rs", "pub fn run() {\n    tauri::Builder::default()\n        .setup(|app| {\n            Ok(())\n        })\n}\n".toArray())
    } catch (e: Exception) {
        return // 目录不可写则跳过，不造假
    }
    let o = setupWiringOutcome("${dir}/lib.rs")
    @Assert(o.id, "R2-PORT-010")
    @Assert(o.applied, false)
    @Assert(o.tier, T_GUIDE)
    @Assert(o.note.contains("R2-PORT-009"), true)
    @Assert(o.after.contains("install_panic_hook(app)"), true)
}
