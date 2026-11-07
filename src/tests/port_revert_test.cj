package lingqu.tests

import std.collection.*
import std.fs.*
import lingqu.*
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
        // 0.39.81：不再写死 `src-tauri/`，改用布局标记（REL_SRC / REL_PROJECT）
        if (p.backupFile == BAK_TOOLCHAIN && p.relTarget == REL_SRC + "rust-toolchain.toml") {
            sawToolchain = true
        }
        if (p.backupFile == BAK_CARGO_CONFIG && p.relTarget == REL_SRC + ".cargo/config.toml") {
            sawConfig = true
        }
        if (p.backupFile == BAK_LIBRS && p.relTarget == REL_SRC + "src/lib.rs") {
            sawLib = true
        }
        if (p.backupFile == BAK_INDEX && p.relTarget == REL_PROJECT + "index.html") {
            sawIndex = true
        }
        if (p.backupFile == BAK_HVIGORFILE && p.relTarget == REL_SRC + "gen/ohos/entry/hvigorfile.ts") {
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
    // 回滚表里**不许**再出现写死的 src-tauri 前缀（扁平工程会一个都匹配不上）
    for (p in pairs) {
        @Assert(p.relTarget.startsWith("src-tauri/"), false)
    }
}

@Test
public func testResolveRevertTargetFollowsLayout(): Unit {
    // 传统布局：src 目录是 `<工程>/src-tauri`，配置都在它下面
    let trad = "/w/habit-tree"
    let tradSrc = "/w/habit-tree/src-tauri"
    @Assert(resolveRevertTarget(REL_SRC + "rust-toolchain.toml", trad, tradSrc, "${tradSrc}/Cargo.toml"),
        "/w/habit-tree/src-tauri/rust-toolchain.toml")
    @Assert(resolveRevertTarget(REL_PROJECT + "index.html", trad, tradSrc, "${tradSrc}/Cargo.toml"),
        "/w/habit-tree/index.html")
    @Assert(resolveRevertTarget("", trad, tradSrc, "${tradSrc}/Cargo.toml"), "/w/habit-tree/src-tauri/Cargo.toml")
    // 扁平布局（rust-music-2）：src 目录就是工程根 —— 修复前这里会拼成 `<工程>/src-tauri/...` 而永远 miss
    let flat = "C:/work/rust-music-2"
    @Assert(resolveRevertTarget(REL_SRC + "rust-toolchain.toml", flat, flat, "${flat}/Cargo.toml"),
        "C:/work/rust-music-2/rust-toolchain.toml")
    @Assert(resolveRevertTarget(REL_SRC + ".cargo/config.toml", flat, flat, "${flat}/Cargo.toml"),
        "C:/work/rust-music-2/.cargo/config.toml")
    @Assert(resolveRevertTarget(REL_SRC + "gen/ohos/entry/hvigorfile.ts", flat, flat, "${flat}/Cargo.toml"),
        "C:/work/rust-music-2/gen/ohos/entry/hvigorfile.ts")
    // 工程里没有 Cargo.toml（srcDir 为空）：不给路径，让命令层记 skipped，别猜
    @Assert(resolveRevertTarget(REL_SRC + "rust-toolchain.toml", flat, "", ""), "")
}

@Test
public func testPortBackupDirIsAbsoluteAndFollowsProject(): Unit {
    // 修复前：revert 用 CWD 相对的 `.lingqu/port/<工程>`，apply 写 `<工程>/.lingqu/port/<工程>`
    // → CWD 不是工程目录时回滚永远"没有备份"。两侧必须同源（同一条构造）。
    // 注意：`portBackupDirOf` 走 lqDirOf → hostPath，Windows 上得到的是反斜杠，断言前先归一化。
    let proj = "C:/work/rust-music-2"
    let dir = portBackupDirOf(proj, "rust-music-2").replace("\\", "/")
    @Assert(dir, "C:/work/rust-music-2/.lingqu/port/rust-music-2")
    // 与相对形态同源（改名/迁移时两边一起改）
    @Assert(dir.endsWith(backupRelDirOf("rust-music-2")), true)
    // 空工程路径时退回 `.lingqu/port/<工程>`（lqDirOf 的既有语义），不崩
    @Assert(portBackupDirOf("", "p").replace("\\", "/").endsWith(".lingqu/port/p"), true)
}

@Test
public func testDecisionsJsonWithPortRunKeepsItems(): Unit {
    // 复现的窟窿（§4-58）：只有"记过人工决策"才生成 decisions.json，
    // 于是"跑过 port 没有"没有落档证据。现在 port 写入 portRun 块，items 必须原样保留。
    let existing = "{\"schema\":\"lingqu/decisions/v1\",\"items\":[{\"rule\":\"R2-PORT-001\",\"decision\":\"accepted\"}]}"
    var outs = ArrayList<String>()
    outs.add("R2-PORT-002 applied")
    outs.add("R2-PORT-008 guide | 未设 NATIVE_OHOS_SDK")
    let text = decisionsJsonWithPortRun(existing, "rust-music-2", true, 3, 2, 1, 1762400000000, outs)
    // 人工决策不许被覆盖
    @Assert(text.contains("\"R2-PORT-001\""), true)
    @Assert(text.contains("accepted"), true)
    // 本轮摘要确实落了
    @Assert(text.contains("\"portRun\""), true)
    @Assert(portRunAtOf(text), 1762400000000)
    @Assert(text.contains("rust-music-2"), true)
    @Assert(text.contains("R2-PORT-008 guide"), true)

    // 坏文件（不是 JSON）时不许抛：items 按空表起，portRun 照写
    let broken = decisionsJsonWithPortRun("{不是 JSON", "p", false, 0, 0, 1, 42, outs)
    @Assert(portRunAtOf(broken), 42)
    // 二次写入要合并上一次的 items（port 重跑不许把人工决策抹掉）
    let second = decisionsJsonWithPortRun(text, "rust-music-2", false, 1, 1, 0, 1762400001000, outs)
    @Assert(second.contains("R2-PORT-001"), true)
    @Assert(portRunAtOf(second), 1762400001000)
    // 空文件 / 没有 portRun：-1（"没跑过"与"跑过但读不出时刻"要能分开）
    @Assert(portRunAtOf(""), -1)
    @Assert(portRunAtOf("{\"items\":[]}"), -1)
    @Assert(portRunAtOf("{坏"), -1)
}

@Test
public func testBackupFileNeverOverwritesOriginal(): Unit {
    // 0.39.79 实测：二次 apply 把"已迁移的文件"又备份了一遍，revert 于是"回滚成迁移态"
    let dir = ".lingqu/tmp-test-bak"
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir))
        }
    } catch (e: Exception) {
        return // 目录不可写则跳过，不造假
    }
    let src = "${dir}/Cargo.toml"
    let dst = "${dir}/Cargo.toml.bak"
    File.writeTo(src, "原始内容".toArray())
    backupFile(src, dst)
    @Assert(String.fromUtf8(File.readFrom(dst)), "原始内容")
    // 模拟二次 apply：源文件已被迁移改写
    File.writeTo(src, "迁移后内容".toArray())
    backupFile(src, dst)
    @Assert(String.fromUtf8(File.readFrom(dst)), "原始内容")
    // 源文件不存在时不该凭空造备份
    let ghost = "${dir}/ghost.bak"
    backupFile("${dir}/not-exist.toml", ghost)
    @Assert(exists(Path(ghost)), false)
}

@Test
public func testBackupPathsAreDistinctFromLegacy(): Unit {
    // 新路径与旧路径不能撞在一起，否则旧备份会被当成新备份写回错文件
    let name = "habit-tree"
    @Assert(backupRelDirOf(name), ".lingqu/port/habit-tree")
    @Assert(legacyCargoBakOf(name), ".lingqu/port/habit-tree-Cargo.toml.bak")
    @Assert(backupRelDirOf(name) != legacyCargoBakOf(name), true)
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
