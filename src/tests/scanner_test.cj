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

// ---------------- 落档文件名：路径末段（回归 v0.6.0 的静默写档失败） ----------------

@Test
public func testProjectNameOfHandlesWindowsSeparator(): Unit {
    // 只用 "/" 切会把整条 Windows 路径当名字 → `.lingqu/scan/E:\test\rust\x.json` 非法
    @Expect(projectNameOf("E:\\test\\rust\\habit-tree"), "habit-tree")
    @Expect(projectNameOf("E:/test/rust/habit-tree"), "habit-tree")
    @Expect(projectNameOf("/home/u/cc-switch"), "cc-switch")
    // 没有分隔符：整串就是名字
    @Expect(projectNameOf("habit-tree"), "habit-tree")
    // 末尾带分隔符：末段为空，由调用方回退到默认名
    @Expect(projectNameOf("E:\\test\\habit-tree\\"), "habit-tree")
}

@Test
public func testSanitizeFileNameReplacesIllegalChars(): Unit {
    @Expect(sanitizeFileName("habit-tree"), "habit-tree")
    @Expect(sanitizeFileName("c:app"), "c_app")
    @Expect(sanitizeFileName("a?b*c"), "a_b_c")
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

/*
 * 0.39.133：路径类 API 不止 `app_data_dir`。EcoPaste 的 `app_log_dir()` 就是这么漏掉的——
 * 名单里只有 app_data_dir，于是「命令内部路径 EPERM」这类缺口在判据分母里**根本不存在**
 * （用户点「Log Directory → Open」提示「Open Directory failed，没有权限」，
 *  而 scan / verify 全程没看见它）。
 */
@Test
public func testParsePlatformApisCoversPathApis(): Unit {
    let text = """
fn a(app: &App) {
    let d = app.path().app_log_dir().unwrap();
    let e = app.path().app_local_data_dir().unwrap();
    let f = app.path().app_config_dir().unwrap();
    let g = app.path().app_cache_dir().unwrap();
}
"""
    let items = parsePlatformApis(src("src-tauri/src/lib.rs", text))
    var names = ArrayList<String>()
    for (it in items) {
        names.add(it.name)
    }
    @Expect(names.contains("app_log_dir"), true)
    @Expect(names.contains("app_local_data_dir"), true)
    @Expect(names.contains("app_config_dir"), true)
    @Expect(names.contains("app_cache_dir"), true)
    // 这几个前缀不该被 app_data_dir 误命中（反过来也一样）
    @Expect(names.contains("app_data_dir"), false)
}

/*
 * 0.39.133：剪贴板是比 opener 更常用的一类，之前**完全没进扫描名单**。
 * EcoPaste 真机实测「复制了内容、界面 0 条」，查依赖源码才看清：
 * clipboard-rs 0.3.5 的 `src/platform/` 只有 win/macos/ios/x11/wayland，**没有 ohos**；
 * 而鸿蒙 `target_os` 也是 linux ⇒ 落进 unix 分支找 X11/Wayland，设备上根本没有。
 */
@Test
public func testParsePlatformApisCoversClipboard(): Unit {
    let text = """
use clipboard_rs::{ClipboardWatcher, ClipboardWatcherContext};
fn start() {
    let mut w = ClipboardWatcherContext::new().unwrap();
    w.start_watch();
}
"""
    let items = parsePlatformApis(src("src-tauri/src/clipboard/watcher.rs", text))
    var names = ArrayList<String>()
    for (it in items) {
        names.add(it.name)
    }
    @Expect(names.contains("clipboard-rs"), true)
    // 判定档要能指出"鸿蒙不可用 + 需授权"，而不是落进"未归类 → 人工"
    let v = verdictOfPlatform("clipboard-rs")
    @Expect(v[0], V_DOWNGRADE)
    @Expect(v[1], "R3-015")
    // 扫描层就直接给结论（用户要求：再遇到用 clipboard 插件的工程，扫出来就提示）
    @Expect(v[2].contains("不可用"), true)
    @Expect(v[2].contains("READ_PASTEBOARD"), true)
    @Expect(v[2].contains("9568289"), true)
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

// ---------------- 工程布局（rust-music-3 实测：只认 src-tauri/ 会让清单恒为 0） ----------------

@Test
public func testSrcTauriDirOf(): Unit {
    // 传统布局：Cargo.toml 在 src-tauri/
    @Expect(srcTauriDirOf(true, false).getOrThrow(), "src-tauri")
    // 扁平布局：Cargo.toml 就在工程根，相对位置是空串（不是 "src-tauri"）
    @Expect(srcTauriDirOf(false, true).getOrThrow(), "")
    // 两种都有时以传统布局为准（老工程里可能存在无关的根 Cargo.toml，比如 workspace 汇总）
    @Expect(srcTauriDirOf(true, true).getOrThrow(), "src-tauri")
    // 都没有：None 让调用方报「不是 Tauri 工程」，绝不默认成某一种布局
    @Expect(srcTauriDirOf(false, false).isSome(), false)
}

// ---------------- 平台 API 使用面：注释与测试代码不算（0.39.107） ----------------

@Test
public func testShippedLinesOfSkipCommentsAndTests(): Unit {
    let text = "#[test]\n" +
        "func temp_db() {\n" +
        "    let d = std::env::temp_dir();\n" +
        "}\n" +
        "/* 块注释\n" +
        "   app_data_dir( 在这里也不算\n" +
        "*/\n" +
        "fn real(app: &App) {\n" +
        "    let d = app.path().app_data_dir();\n" +
        "    // 行尾注释 dirs::data_dir\n" +
        "}\n"
    let flags = shippedLinesOf(text)
    // 测试函数体（含 fn 行与收尾 `}`）全部 false，块注释内 false，行尾注释所在行仍是 true
    @Expect(flags[0], false)
    @Expect(flags[1], false)
    @Expect(flags[2], false)
    @Expect(flags[3], false)
    @Expect(flags[4], false)
    @Expect(flags[5], false)
    @Expect(flags[7], true)
    @Expect(flags[8], true)
    // 整行的 `//` 注释（不是代码行）也不算出货代码；行尾注释由 stripTrailingCommentOf 处理
    @Expect(flags[9], false)
}

@Test
public func testParsePlatformApisIgnoresCommentsAndTestCode(): Unit {
    // 现场（habit-tree）：dirs::data_dir 只在文档注释里、std::env::temp_dir 只在 #[test] 里，
    // 两个都被算成"使用点"→ platform-api 判「降级没落地」。
    let text = "/// 鸿蒙没有 HOME，dirs::data_dir() 返回 None，所以要换沙箱路径\n" +
        "fn resolve(app: &App) {\n" +
        "    let d = app.path().app_data_dir();\n" +
        "}\n" +
        "#[cfg(test)]\n" +
        "mod tests {\n" +
        "    #[test]\n" +
        "    fn temp_db() {\n" +
        "        let d = std::env::temp_dir();\n" +
        "    }\n" +
        "}\n"
    let items = parsePlatformApis(src("src-tauri/src/lib.rs", text))
    var names = ArrayList<String>()
    for (it in items) {
        names.add(it.name)
    }
    @Expect(names.contains("app_data_dir"), true)
    @Expect(names.contains("dirs::data_dir"), false)
    @Expect(names.contains("std::env::temp_dir"), false)
}

@Test
public func testStripTrailingCommentOf(): Unit {
    // 行尾注释剥掉
    @Expect(stripTrailingCommentOf("let x = 1; // 用 dirs::data_dir"), "let x = 1; ")
    // URL 里的 // 不是注释（前面不是空白）
    @Expect(stripTrailingCommentOf("let u = \"https://x/y\";"), "let u = \"https://x/y\";")
    // 整行注释 → 空串
    @Expect(stripTrailingCommentOf("// app_data_dir("), "")
}

@Test
public func testMarkerPresentInUsesWordBoundary(): Unit {
    // 真用法：方法调用，前面是 `.`
    @Expect(markerPresentIn("    let d = app.path().app_data_dir();", "app_data_dir("), true)
    // 工程自己的包装函数名 `resolve_app_data_dir(` **不是**平台 API 用法（habit-tree 的误报源）
    @Expect(markerPresentIn("    let dir = resolve_app_data_dir(app)?;", "app_data_dir("), false)
    // 前面是空白/行首都算真命中
    @Expect(markerPresentIn("app_data_dir(arg)", "app_data_dir("), true)
    @Expect(markerPresentIn("rfd::FileDialog::new()", "rfd::FileDialog"), true)
    @Expect(markerPresentIn("my_rfd::FileDialog::new()", "rfd::FileDialog"), false)
}

// 回归：空工程/什么都没扫到时不能算 100 分（rust-music-3 目录被清空后实测到总分 100）
@Test
public func testScoreOfEmptyScanIsNoBasisNotPerfect(): Unit {
    let res = ScanResult()
    let s = res.scoreJson()
    @Expect(s.get("runtime").getOrThrow().asInt().getValue(), -1)
    @Expect(s.get("api").getOrThrow().asInt().getValue(), -1)
    @Expect(s.get("total").getOrThrow().asInt().getValue(), -1)
    @Expect(s.get("scannedDims").getOrThrow().asString().getValue(), "")
}
