package lingqu.tests

import lingqu.scanner.*
import std.collection.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 扫描器（P2）的单元测试。
 *
 * 只测**纯解析与判定**（给它一段源码文本，看它吐出什么）——
 * 文件遍历、真实工程跑分属于集成验证，放在 docs/进度记录.md 的证据里，不在这里造假绿（AGENTS §1.5）。
 */

func src(rel: String, text: String): Source {
    return Source(rel, text)
}

// ---------------- 命令清单：以函数为一项 ----------------

@Test
public func testParseCommandsFindsFns(): Unit {
    let text = """
#[tauri::command]
pub fn list_trees(app: tauri::AppHandle) -> Result<Vec<Tree>, String> { Ok(vec![]) }

#[tauri::command]
pub async fn upsert_tree(app: tauri::AppHandle, tree: Tree) -> Result<(), String> { Ok(()) }
"""
    let items = parseCommands(src("src-tauri/src/commands.rs", text))
    @Expect(items.size, 2)
    @Expect(items[0].name, "list_trees")
    @Expect(items[1].name, "upsert_tree")
    // 行号：第一个宏在第 1 行
    @Expect(items[0].sites[0], "src-tauri/src/commands.rs:1")
}

@Test
public func testParseCommandsIgnoresNonCommandFn(): Unit {
    let text = """
fn helper(x: i32) -> i32 { x }

#[tauri::command]
fn real_command() {}
"""
    let items = parseCommands(src("a.rs", text))
    @Expect(items.size, 1)
    @Expect(items[0].name, "real_command")
}

@Test
public func testParseHandlerRegistrations(): Unit {
    let text = """
.invoke_handler(tauri::generate_handler![
    commands::list_trees,
    commands::upsert_tree,
    ping
])
"""
    let names = parseHandlerRegistrations(text)
    @Expect(names.size, 3)
    @Expect(names.contains("list_trees"), true)
    @Expect(names.contains("ping"), true)
}

// ---------------- 平台 API：符号为一项，多调用点合并 ----------------

@Test
public func testParsePlatformApisMergesSites(): Unit {
    let text = """
fn a(app: &App) {
    let d = app.path().app_data_dir().unwrap();
    let e = app.path().app_data_dir().unwrap();
}
fn b() {
    rfd::FileDialog::new().pick_folder();
}
"""
    let items = parsePlatformApis(src("src-tauri/src/lib.rs", text))
    var names = ArrayList<String>()
    for (it in items) {
        names.add(it.name)
    }
    @Expect(names.contains("app_data_dir"), true)
    @Expect(names.contains("rfd::FileDialog"), true)
    // 同名合并成一项，sites 记两处
    for (it in items) {
        if (it.name == "app_data_dir") {
            @Expect(it.sites.size, 2)
        }
    }
}

@Test
public func testVerdictOfPlatform(): Unit {
    @Expect(verdictOfPlatform("rfd::FileDialog")[0], V_DOWNGRADE)
    @Expect(verdictOfPlatform("rfd::FileDialog")[1], "R3-004")
    @Expect(verdictOfPlatform("app_data_dir")[0], V_REWRITE)
    @Expect(verdictOfPlatform("app_data_dir")[1], "R3-001")
    @Expect(verdictOfPlatform("std::process::Command")[0], V_DOWNGRADE)
    // 未归类 → 人工（不是"未知"：未知只用于解析失败）
    @Expect(verdictOfPlatform("some_unknown_api")[0], V_MANUAL)
}

// ---------------- 前端能力：按能力计项 ----------------

@Test
public func testParseFrontendCapabilities(): Unit {
    let text = """
const raw = localStorage.getItem("k");
if (confirm("删除？")) { doIt(); }
document.body.innerHTML = '<input type="color" id="c">';
"""
    let items = parseFrontend(src("src/ui.ts", text))
    var names = ArrayList<String>()
    for (it in items) {
        names.add(it.name)
    }
    @Expect(names.contains("localStorage"), true)
    @Expect(names.contains("window.confirm"), true)
    @Expect(names.contains("input[type=color]"), true)
}

@Test
public func testParseFrontendSkipsComments(): Unit {
    let text = """
// 这里有 localStorage 字样，但只是注释
const x = 1;
"""
    let items = parseFrontend(src("src/ui.ts", text))
    @Expect(items.size, 0)
}

@Test
public func testVerdictOfFrontend(): Unit {
    @Expect(verdictOfFrontend("localStorage")[1], "R5-001")
    @Expect(verdictOfFrontend("window.confirm")[1], "R5-002")
    @Expect(verdictOfFrontend("input[type=color]")[1], "R5-005")
    @Expect(verdictOfFrontend("Notification")[0], V_DOWNGRADE)
    // 跨源 fetch 需要人确认 → 人工
    @Expect(verdictOfFrontend("fetch")[0], V_MANUAL)
}

// ---------------- 插件与事件 ----------------

@Test
public func testParsePluginCargo(): Unit {
    let text = """
[dependencies]
tauri = { version = "2.11.5" }
tauri-plugin-clipboard-manager = "2"
tauri-plugin-notification = "2"
# tauri-plugin-commented = "9"
"""
    let items = parsePluginCargo(text, "src-tauri/Cargo.toml")
    @Expect(items.size, 2)
    @Expect(items[0].name, "clipboard-manager")
    @Expect(items[1].name, "notification")
}

@Test
public func testVerdictOfPlugin(): Unit {
    // 鸿蒙走 pasteboard FFI → 直接可用，无需处置
    @Expect(verdictOfPlugin("clipboard-manager")[0], V_NA)
    @Expect(verdictOfPlugin("notification")[0], V_DOWNGRADE)
    @Expect(verdictOfPlugin("random-thing")[0], V_MANUAL)
}

@Test
public func testParseEvents(): Unit {
    let text = """
app.emit("config_changed", payload)?;
window.listen("tick", cb);
let s = "listen(not an event";
"""
    let items = parseEvents(src("src-tauri/src/lib.rs", text))
    var names = ArrayList<String>()
    for (it in items) {
        names.add(it.name)
    }
    @Expect(names.contains("config_changed"), true)
    @Expect(names.contains("tick"), true)
}

// ---------------- 度量：C1/C3 与禁用值 ----------------

@Test
public func testMetricsCountsAndCoverage(): Unit {
    let res = ScanResult()
    let a = ScanItem("frontend", "localStorage")
    a.decide(V_REWRITE, "R5-001", "x")
    let b = ScanItem("platform", "rfd::FileDialog")
    b.decide(V_DOWNGRADE, "R3-004", "x")
    let c = ScanItem("event", "tick")
    c.decide(V_MANUAL, "", "x")
    res.items.add(a)
    res.items.add(b)
    res.items.add(c)

    let counts = res.counts()
    @Expect(counts[0], 3)   // R
    @Expect(counts[1], 3)   // D（人工也算有结论）
    @Expect(counts[2], 1)   // H
    @Expect(counts[3], 0)   // U

    let m = res.metricsJson()
    @Expect(m.get("C1").getOrThrow().asFloat().getValue(), 100.0)
    @Expect(Float64(Int64(m.get("C3").getOrThrow().asFloat().getValue() * 10.0)) / 10.0 > 33.0, true)
}

@Test
public func testUnknownVerdictDropsCoverage(): Unit {
    let res = ScanResult()
    let a = ScanItem("frontend", "localStorage")
    a.decide(V_REWRITE, "R5-001", "x")
    let b = ScanItem("platform", "mystery")   // 默认 V_UNKNOWN
    res.items.add(a)
    res.items.add(b)

    let counts = res.counts()
    @Expect(counts[3], 1)   // U = 1 → C1 < 100%
    @Expect(res.metricsJson().get("C1").getOrThrow().asFloat().getValue(), 50.0)
}

@Test
public func testScoreMarksUnscannedDims(): Unit {
    let res = ScanResult()
    let a = ScanItem("frontend", "localStorage")
    a.decide(V_REWRITE, "R5-001", "x")
    res.items.add(a)
    let s = res.scoreJson()
    // build/deps/dist 未扫描 → -1，不许编造 100 分
    @Expect(s.get("build").getOrThrow().asInt().getValue(), -1)
    @Expect(s.get("deps").getOrThrow().asInt().getValue(), -1)
    @Expect(s.get("partial").getOrThrow().asBool().getValue(), true)
    @Expect(s.get("runtime").getOrThrow().asInt().getValue(), 95)
}

// 回归：第一版把总分写成 weighted×100/0.45，扫 habit-tree 时算出 2500
@Test
public func testScoreTotalIsWeightedAverageNotScaledTwice(): Unit {
    let res = ScanResult()
    let a = ScanItem("frontend", "localStorage")
    a.decide(V_REWRITE, "R5-001", "x")     // runtime −5 → 95
    let b = ScanItem("platform", "rfd::FileDialog")
    b.decide(V_DOWNGRADE, "R3-004", "x")   // api −15 → 85
    res.items.add(a)
    res.items.add(b)
    let s = res.scoreJson()
    let total = s.get("total").getOrThrow().asInt().getValue()
    // (95×0.25 + 85×0.20) / 0.45 = 90.55… → 90
    @Expect(total <= 100, true)
    @Expect(total, 90)
}

// 命令一律"不适用"：要改的是它调用的平台 API，决策落在 platform 类清单上
@Test
public func testVerdictOfCommandAlwaysNotApplicable(): Unit {
    @Expect(verdictOfCommand("list_trees", true)[0], V_NA)
    @Expect(verdictOfCommand("get_version", false)[0], V_NA)
    @Expect(verdictOfCommand("list_trees", true)[2].contains("platform"), true)
}

// ---------------- 小工具 ----------------

@Test
public func testJsonStringField(): Unit {
    let conf = """
{ "productName": "habit-tree", "identifier": "com.grove.habittrees",
  "build": { "frontendDist": "../dist" } }
"""
    @Expect(jsonStringField(conf, "identifier"), "com.grove.habittrees")
    @Expect(jsonStringField(conf, "frontendDist"), "../dist")
    @Expect(jsonStringField(conf, "nope"), "")
}

@Test
public func testCargoDepVersion(): Unit {
    let cargo = """
[package]
name = "grove"
version = "1.2.0"

[dependencies]
tauri = { version = "=2.11.5", features = ["protocol-asset"] }
serde = "1"
"""
    @Expect(cargoDepVersion(cargo, "name"), "grove")
    @Expect(cargoDepVersion(cargo, "tauri"), "=2.11.5")
    @Expect(cargoDepVersion(cargo, "serde"), "1")
}
