package lingqu.tests

import std.collection.*
import lingqu.port.*

/*
 * t2h:port 单测（P4 第一刀：Cargo.toml 六条规则）。
 * 主路径（habit-tree 迁移前 Cargo.toml 逐条应用）+ 幂等（T4-6）+ 错误路径（格式不认识跳过）。
 */

/** habit-tree 迁移前 Cargo.toml 的精简复刻（main 分支 @ 0a1 前后，结构与真实文件一致） */
func cargoBeforeFixture(): String {
    return """
    [package]
    name = "grove"
    version = "1.1.0"
    description = "Visualize your growth - fractal habit trees"
    edition = "2021"

    [lib]
    name = "grove_lib"
    # 桌面版仅需 rlib（cdylib/staticlib 是移动端预留）
    crate-type = ["rlib"]

    [build-dependencies]
    tauri-build = { version = "2", features = [] }

    [dependencies]
    tauri = { version = "2", features = [] }
    serde = { version = "1", features = ["derive"] }
    serde_json = "1"
    redb = "2"
    chrono = "0.4"
    base64 = "0.22"

    [profile.release]
    strip = true
    """
}

@Test
public func testAllSixRulesApplyOnUnmigrated(): Unit {
    let res = applyCargoTomlRules(cargoBeforeFixture())
    // 主路径：六条规则全部 applied
    @Assert(res.appliedCount(), 6)
    let ids = ArrayList<String>()
    for (o in res.outcomes) {
        ids.add(o.id)
    }
    @Assert(ids.contains("R2-PORT-001"), true)
    @Assert(ids.contains("R2-PORT-002"), true)
    @Assert(ids.contains("R2-PORT-003"), true)
    @Assert(ids.contains("R2-PORT-004"), true)
    @Assert(ids.contains("R2-PORT-005"), true)
    @Assert(ids.contains("R2-PORT-006"), true)
}

@Test
public func testTransformedContentIsRight(): Unit {
    let res = applyCargoTomlRules(cargoBeforeFixture())
    let t = res.afterText
    // 001：cdylib 进 crate-type
    @Assert(t.contains("\"staticlib\", \"cdylib\", \"rlib\""), true)
    // 002：tauri 钉 =2.11.5 且 features 合并了 custom-protocol 与 protocol-asset
    @Assert(t.contains("version = \"=2.11.5\""), true)
    @Assert(t.contains("custom-protocol"), true)
    @Assert(t.contains("protocol-asset"), true)
    // 003：tauri-build 钉 =2.6.3
    @Assert(t.contains("tauri-build = { version = \"=2.6.3\""), true)
    // 004：wry 钉版 + 关 default-features
    @Assert(t.contains("wry = { version = \"=0.56.0\", default-features = false }"), true)
    // 005：OHOS target 段（napi 桥接）
    @Assert(t.contains("cfg(target_env = \"ohos\")"), true)
    @Assert(t.contains("napi-ohos"), true)
    // 006：patch 段（fork + rev 固定）
    @Assert(t.contains("[patch.crates-io]"), true)
    @Assert(t.contains(OHOS_TAURI_REV), true)
    @Assert(t.contains("[patch.\"${OHOS_ABILITY_UPSTREAM}\"]"), true)
}

@Test
public func testIdempotentSecondRun(): Unit {
    // T4-6 核心：改过的文件再跑一遍，六条规则全部 applied=false，文本不变
    let first = applyCargoTomlRules(cargoBeforeFixture())
    @Assert(first.appliedCount(), 6)
    let second = applyCargoTomlRules(first.afterText)
    @Assert(second.appliedCount(), 0)
    @Assert(isIdempotent(first), true)
    @Assert(second.afterText == first.afterText, true)
}

@Test
public func testAlreadyPatchedProjectSkipsAll(): Unit {
    // 错误路径的反面：已迁移工程（有 [patch 段）——六条全跳过，文本逐字节不变
    let res = applyCargoTomlRules(cargoBeforeFixture())
    let migrated = applyCargoTomlRules(res.afterText).afterText
    let again = applyCargoTomlRules(migrated)
    @Assert(again.appliedCount(), 0)
    @Assert(again.afterText == migrated, true)
}

@Test
public func testNonTauriProjectSkipsPins(): Unit {
    // 边界：非 Tauri 工程（没有 tauri/tauri-build/wry 依赖行）——钉版规则跳过不崩
    let text = """
    [package]
    name = "plain"
    version = "0.1.0"

    [dependencies]
    serde = "1"
    """
    let res = applyCargoTomlRules(text)
    for (o in res.outcomes) {
        if (o.id == "R2-PORT-002" || o.id == "R2-PORT-003" || o.id == "R2-PORT-004") {
            @Assert(o.applied, false)
        }
    }
}

@Test
public func testQuotedValueHelpersEdge(): Unit {
    // 行级工具的边界：没有 = / 没有引号 / features 缺右括号
    @Assert(keyOf("tauri = { version = \"2\" }"), "tauri")
    @Assert(keyOf("# 注释行"), "")
    @Assert(featuresInnerOf("tauri = { version = \"2\", features = [\"a\", \"b\"] }"), "\"a\", \"b\"")
    @Assert(featuresInnerOf("tauri = { version = \"2\" }"), "")
    @Assert(leadingIndentOf("    indented"), "    ")
    @Assert(leadingIndentOf("no-indent"), "")
}
