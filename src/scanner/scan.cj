package lingqu.scanner

import std.collection.*
import std.fs.*
import std.env.*
import stdx.encoding.json.*

/*
 * t2h:scan —— Tauri 工程迁移扫描器（P2）
 *
 * 口径见 docs/P2-scan-口径草案.md（已拍板）：
 *   ① 一项 = 一个「迁移单元」（命令函数 / 事件名 / 插件 / 浏览器能力 / 平台 API 符号）
 *   ② 三个指标：C1 结论覆盖率 = D/R、C2 发现置信度（需人工基线，本版留空）、C3 人工占比 = H/R
 *   ③ 处置四值域：改造 / 降级 / 不适用 / 人工；`未知` 是禁用值（出现即 C1 < 100%）
 *
 * 实现取向：**不引 regex**。本仓的匹配对象都是字面量标记（`#[tauri::command]`、`rfd::FileDialog`、
 * `localStorage`…），按行做字面量匹配 + 自己取字符串字面量，零依赖、零正则回溯、行为可预测。
 * 代价是拿不到 AST 语义（比如宏展开出来的命令）；这类情况一律落 `未知` 或 `人工`，**不猜**。
 */

// ===== 处置结论（四值 + 一个禁用值）=====
public let V_REWRITE = "改造"
public let V_DOWNGRADE = "降级"
/** 不适用：含"平台无此概念"与"直接可用、无需处置"两种；evidence 里要写清是哪种 */
public let V_NA = "不适用"
public let V_MANUAL = "人工"
/** 未知：禁用值。出现即 C1 < 100%，门禁不放行 */
public let V_UNKNOWN = "未知"

// ===== 扫描项 =====
public class ScanItem {
    public var kind: String
    public var name: String
    public var sites: ArrayList<String> = ArrayList<String>()
    public var verdict: String = V_UNKNOWN
    public var rule: String = ""
    public var evidence: String = ""

    public init(kind: String, name: String) {
        this.kind = kind
        this.name = name
    }

    /** 记账一个出现点（文件:行）；同名项只记 sites，不重复计数 */
    public func site(rel: String, line: Int64): Unit {
        let s = "${rel}:${line}"
        if (!this.sites.contains(s)) {
            this.sites.add(s)
        }
    }

    public func decide(verdict: String, rule: String, evidence: String): Unit {
        this.verdict = verdict
        this.rule = rule
        this.evidence = evidence
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("kind", JsonString(this.kind))
        o.put("name", JsonString(this.name))
        o.put("verdict", JsonString(this.verdict))
        o.put("rule", JsonString(this.rule))
        o.put("evidence", JsonString(this.evidence))
        o.put("siteCount", JsonInt(Int64(this.sites.size)))
        var arr = JsonArray()
        for (s in this.sites) {
            arr.add(JsonString(s))
        }
        o.put("sites", arr)
        return o
    }
}

// ===== 一份源码 =====
public class Source {
    public var rel: String
    public var text: String
    public init(rel: String, text: String) {
        this.rel = rel
        this.text = text
    }
}

// ============================================================
// 文件收集：Directory.walk 非递归，自己递归（cj-tauri AGENTS 已记录该坑）
// ============================================================

func isSkippedDir(name: String, skip: Array<String>): Bool {
    for (s in skip) {
        if (name == s) {
            return true
        }
    }
    return false
}

func hasExt(name: String, exts: Array<String>): Bool {
    for (e in exts) {
        if (name.endsWith(e)) {
            return true
        }
    }
    return false
}

func walkCollect(
    absDir: String,
    relDir: String,
    exts: Array<String>,
    skip: Array<String>,
    out: ArrayList<Source>,
    depth: Int64
): Unit {
    if (depth > 8) {
        return
    }
    var entries: Array<FileInfo>
    try {
        entries = Directory.readFrom(absDir)
    } catch (e: Exception) {
        let _ = e
        return
    }
    for (info in entries) {
        let nm = info.name
        let childAbs = "${absDir}/${nm}"
        let childRel = if (relDir.size == 0) { nm } else { "${relDir}/${nm}" }
        if (info.isDirectory()) {
            if (!isSkippedDir(nm, skip)) {
                walkCollect(childAbs, childRel, exts, skip, out, depth + 1)
            }
        } else if (hasExt(nm, exts)) {
            try {
                let text = String.fromUtf8(File.readFrom(childAbs))
                out.add(Source(childRel, text))
            } catch (e: Exception) {
                let _ = e
            }
        }
    }
}

public func collectSources(root: String, subdirs: Array<String>, exts: Array<String>): ArrayList<Source> {
    let out = ArrayList<Source>()
    let skip = ["node_modules", "target", "dist", ".git", "gen", "build", "oh_modules", ".hvigor"]
    for (sub in subdirs) {
        let abs = "${root}/${sub}"
        if (exists(Path(abs))) {
            walkCollect(abs, sub, exts, skip, out, 0)
        }
    }
    return out
}

// ============================================================
// 小工具：行号 / 取字符串字面量 / 解析 Cargo 依赖键
// ============================================================

public func lineNumberAt(text: String, pos: Int64): Int64 {
    var n: Int64 = 1
    var i: Int64 = 0
    while (i < pos && i < text.size) {
        if (text[i] == 10u8) {
            n += 1
        }
        i += 1
    }
    return n
}

func isIdentByte(b: Byte): Bool {
    return (b >= 97u8 && b <= 122u8) || (b >= 65u8 && b <= 90u8) || (b >= 48u8 && b <= 57u8) || b == 95u8
}

/** 从 from 起读一个标识符（[A-Za-z0-9_]） */
func identAt(text: String, from: Int64): String {
    var i = from
    while (i < text.size && isIdentByte(text[i])) {
        i += 1
    }
    if (i <= from) {
        return ""
    }
    return text[from..i]
}

/** 从 from 起找第一个字符串字面量的内容（跳过空白；支持 ' 与 "；跨行即放弃）
 *  注：`trimLeftAscii(Byte)` 在标准库里不存在，所以用 start 记左引号下标再切片。 */
public func firstStringLiteral(text: String, from: Int64): String {
    var i = from
    var qm: Byte = 0u8
    var start: Int64 = 0
    while (i < text.size) {
        let b = text[i]
        if (qm == 0u8) {
            if (b == 34u8 || b == 39u8) {
                qm = b
                start = i + 1
            } else if (b == 10u8) {
                return ""
            }
        } else {
            if (b == qm) {
                return text[start..i]
            }
            if (b == 10u8) {
                return ""
            }
        }
        i += 1
    }
    return ""
}

/** 在 text 里全量扫描 marker，回调 (pos) */
func eachOccurrence(text: String, marker: String, cb: (Int64) -> Unit): Unit {
    if (marker.size == 0) {
        return
    }
    var from: Int64 = 0
    while (from < text.size) {
        match (text.indexOf(marker, from)) {
            case Some(p) =>
                cb(p)
                from = p + marker.size
            case None => return
        }
    }
}

// ============================================================
// ① 命令清单
// ============================================================

/** `#[tauri::command]` 后紧跟的 `fn NAME(` —— 命令以**函数**为一项 */
public func parseCommands(src: Source): ArrayList<ScanItem> {
    let out = ArrayList<ScanItem>()
    let seen = HashMap<String, Bool>()
    eachOccurrence(src.text, "#[tauri::command]") { pos =>
        match (src.text.indexOf("fn ", pos)) {
            case Some(fpos) =>
                if (fpos - pos < 400) {
                    var nm = identAt(src.text, fpos + 3)
                    if (nm.size > 0) {
                        let line = lineNumberAt(src.text, pos)
                        if (!seen.contains(nm)) {
                            seen.add(nm, true)
                            let it = ScanItem("command", nm)
                            it.site(src.rel, line)
                            out.add(it)
                        }
                    }
                }
            case None => ()
        }
    }
    return out
}

/** `generate_handler![...]` 里注册了哪些命令（用于判断"实现了但没注册"） */
public func parseHandlerRegistrations(text: String): ArrayList<String> {
    let out = ArrayList<String>()
    eachOccurrence(text, "generate_handler!") { pos =>
        match (text.indexOf("[", pos)) {
            case Some(lb) =>
                match (text.indexOf("]", lb)) {
                    case Some(rb) =>
                        let body = text[lb + 1..rb]
                        for (seg in body.split(",", -1)) {
                            let t = seg.trimAscii()
                            if (t.size > 0) {
                                let name = match (t.lastIndexOf("::")) {
                                    case Some(i) => t[(i + 2)..t.size]
                                    case None => t
                                }
                                if (name.size > 0 && !out.contains(name)) {
                                    out.add(name)
                                }
                            }
                        }
                    case None => ()
                }
            case None => ()
        }
    }
    return out
}

// ============================================================
// ② 平台 API 使用面（Rust 侧）
// ============================================================

/** 标记 → 规范符号名 */
let PLATFORM_MARKERS: Array<(String, String)> = [
    ("rfd::FileDialog", "rfd::FileDialog"),
    ("rfd::MessageDialog", "rfd::MessageDialog"),
    ("app_data_dir(", "app_data_dir"),
    ("dirs::data_dir", "dirs::data_dir"),
    ("dirs::config_dir", "dirs::config_dir"),
    ("std::env::var(\"HOME\")", "HOME"),
    ("std::env::var(\"APPDATA\")", "APPDATA"),
    ("Command::new(", "std::process::Command"),
    ("std::process::Command", "std::process::Command"),
    ("std::env::temp_dir", "std::env::temp_dir"),
    ("tauri_plugin_opener", "tauri_plugin_opener"),
    ("open::that", "open::that")
]

/**
 * 去掉行尾 `//` 注释（要求 `//` 在行首或前面是空白——`"http://x"` 这类不算注释）。
 *
 * 为什么要有：`let _ = foo(); // 用 dirs::data_dir 那套` 会把注释里的名字当成使用点。
 */
public func stripTrailingCommentOf(line: String): String {
    var i: Int64 = 0
    while (i + 1 < line.size) {
        if (line[i] == 47 && line[i + 1] == 47) {
            if (i == 0) {
                return ""
            }
            let prev = line[i - 1]
            if (prev == 32 || prev == 9) {
                return line[0..i]
            }
            i += 2
            continue
        }
        i += 1
    }
    return line
}

/** 这一行是不是测试属性（`#[test]` / `#[cfg(test)]` / `#[tokio::test]` …） */
public func isTestAttrLine(trimmed: String): Bool {
    if (!trimmed.startsWith("#[")) {
        return false
    }
    if (trimmed.startsWith("#[test]") || trimmed.startsWith("#[cfg(test)]")) {
        return true
    }
    // `#[tokio::test]` / `#[async_std::test]` 这类带命名空间的
    if (trimmed.endsWith("test]") && !trimmed.startsWith("#[cfg(")) {
        return true
    }
    return false
}

/**
 * 逐行标出**出货代码**（`true` = 会进产物）。
 *
 * 为什么需要（0.39.107）：平台 API 清单原来按"整行包含标记"计，于是
 * ① 文档注释里的 `dirs::data_dir()`（habit-tree `lib.rs:15`，解释为什么要换沙箱路径）
 * ② `#[test]` 里的 `std::env::temp_dir()`（habit-tree `storage.rs:163`，造临时库）
 * ③ 桌面专用函数里的 `app_data_dir()`（`#[cfg(not(...ohos...))]`，鸿蒙上压根不编译）
 * 都被算成"平台 API 使用点"，进而被判"降级方案没落地" → 移植项 `platform-api` 判 fail。
 * 前两条**不进货**，判它等于凭空扣分（§4-144 同族：判据只认一种现场）。
 *
 * 测试作用域按 rustfmt 排版约定取：属性行之后第一条**顶格 `}`** 就是条目收尾
 * （`#[test] fn` 与 `#[cfg(test)] mod tests` 都成立；缩进的 `}` 是内层块的）。
 */
public func shippedLinesOf(text: String): Array<Bool> {
    let lines = text.split("\n", -1)
    let n = lines.size
    let flags = Array<Bool>(n, repeat: true)
    var inBlock = false
    var i: Int64 = 0
    while (i < n) {
        let t = lines[i].trimAscii()
        if (inBlock) {
            flags[i] = false
            if (t.contains("*/")) {
                inBlock = false
            }
            i += 1
            continue
        }
        if (isTestAttrLine(t)) {
            // 测试作用域：属性行 → 第一条顶格 `}`
            var j = i + 1
            while (j < n && !lines[j].startsWith("}")) {
                j += 1
            }
            let end = if (j < n) { j } else { n - 1 }
            var k = i
            while (k <= end) {
                flags[k] = false
                k += 1
            }
            i = end + 1
            continue
        }
        if (t.startsWith("//") || t.startsWith("/*")) {
            flags[i] = false
            if (t.startsWith("/*") && !t.contains("*/")) {
                inBlock = true
            }
            i += 1
            continue
        }
        i += 1
    }
    return flags
}

/**
 * 行内出现标记的位置（要求标记**前面不是标识符字符**，取第一个满足的）。
 *
 * 为什么要词边界：`app_data_dir(` 这个标记会命中工程自己写的包装函数
 * `resolve_app_data_dir(`——habit-tree 里 5 处"命中"有 3 处就是这么来的（真用法只有
 * `app.path().app_data_dir()` 一处）。子串匹配会把"我们已经封装好并在鸿蒙上落地了"的地方
 * 又算成缺口（§4-144 同族）。
 */
public func markerPresentIn(line: String, marker: String): Bool {
    var from: Int64 = 0
    while (from < line.size) {
        let at = findFromIn(line, marker, from)
        if (at < 0) {
            return false
        }
        if (at == 0) {
            return true
        }
        if (!isIdentByteOf(line[at - 1])) {
            return true
        }
        from = at + 1
    }
    return false
}

/** 从 `from` 开始的子串位置（-1 = 没有）；仓颉 String 的 indexOf 不带起点，这里补一个 */
func findFromIn(s: String, sub: String, from: Int64): Int64 {
    if (from >= s.size) {
        return -1
    }
    let tail = s[from..]
    return match (tail.indexOf(sub)) {
        case Some(i) => from + i
        case None => -1
    }
}

func isIdentByteOf(b: Byte): Bool {
    if (b >= 97 && b <= 122) {
        return true
    }
    if (b >= 65 && b <= 90) {
        return true
    }
    if (b >= 48 && b <= 57) {
        return true
    }
    return b == 95
}

public func parsePlatformApis(src: Source): ArrayList<ScanItem> {
    let out = ArrayList<ScanItem>()
    let byName = HashMap<String, ScanItem>()
    let lines = src.text.split("\n", -1)
    let shipped = shippedLinesOf(src.text)
    var ln: Int64 = 0
    for (line in lines) {
        ln += 1
        // 注释 / 块注释 / 测试代码都不是"鸿蒙侧要落地的使用点"（见 shippedLinesOf 注释）
        if (!shipped[ln - 1]) {
            continue
        }
        let code = stripTrailingCommentOf(line)
        if (code.trimAscii() == "") {
            continue
        }
        for ((marker, symbol) in PLATFORM_MARKERS) {
            if (markerPresentIn(code, marker)) {
                match (byName.get(symbol)) {
                    case Some(it) => it.site(src.rel, ln)
                    case None =>
                        let it = ScanItem("platform", symbol)
                        it.site(src.rel, ln)
                        byName.add(symbol, it)
                        out.add(it)
                }
            }
        }
    }
    return out
}

// ============================================================
// ③ 事件清单（emit / listen）
// ============================================================

let EVENT_EMIT_MARKERS: Array<String> = ["emit(", "emit_all(", "emit_to("]
let EVENT_LISTEN_MARKERS: Array<String> = ["listen(", "listen_global(", "once("]

public func parseEvents(src: Source): ArrayList<ScanItem> {
    let out = ArrayList<ScanItem>()
    let byName = HashMap<String, ScanItem>()
    let lines = src.text.split("\n", -1)
    var ln: Int64 = 0
    for (line in lines) {
        ln += 1
        var markers = ArrayList<String>()
        for (m in EVENT_EMIT_MARKERS) {
            markers.add(m)
        }
        for (m in EVENT_LISTEN_MARKERS) {
            markers.add(m)
        }
        for (m in markers) {
            match (line.indexOf(m)) {
                case Some(p) =>
                    let lit = firstStringLiteral(line, p + m.size)
                    // 只认像事件名的字面量（排除空串与带空格的句子）
                    if (lit.size > 0 && lit.size <= 64 && !lit.contains(" ")) {
                        match (byName.get(lit)) {
                            case Some(it) => it.site(src.rel, ln)
                            case None =>
                                let it = ScanItem("event", lit)
                                it.site(src.rel, ln)
                                byName.add(lit, it)
                                out.add(it)
                        }
                    }
                case None => ()
            }
        }
    }
    return out
}

// ============================================================
// ④ 前端浏览器能力（按**能力**计项，不按文件数）
// ============================================================

let FRONTEND_MARKERS: Array<(String, String)> = [
    ("localStorage", "localStorage"),
    ("sessionStorage", "sessionStorage"),
    ("confirm(", "window.confirm"),
    ("prompt(", "window.prompt"),
    ("type=\"color\"", "input[type=color]"),
    ("type='color'", "input[type=color]"),
    ("type=\"file\"", "input[type=file]"),
    ("type='file'", "input[type=file]"),
    ("new Notification", "Notification"),
    ("Notification.", "Notification"),
    ("navigator.clipboard", "navigator.clipboard"),
    ("createObjectURL", "Blob 下载"),
    ("download=", "Blob 下载"),
    // canvas 导出图片：ArkWeb 下 toDataURL 的长 base64 跨桥有大文件风险（C2 基线对照后补）
    ("toDataURL(", "canvas.toDataURL"),
    ("toBlob(", "canvas.toDataURL"),
    // 读本地文件（配合 input[type=file] 用）
    ("new FileReader", "FileReader"),
    ("FileReader(", "FileReader"),
    // 外链回退路径
    ("window.open(", "window.open"),
    ("fetch(", "fetch")
]

/**
 * 前端侧 @tauri-apps/api 模块 → 平台 API 项（kind 仍是 `platform`）。
 * 为什么单独一类：这些能力在 OHOS **没有对应实现**，属于要换系统 API 的平台差异，
 * 不是浏览器能力。habit-tree 的 `getVersion` 就是这么漏掉的（C2 基线对照发现的）。
 * `@tauri-apps/api/core`（invoke）与 `.../event`（emit/listen）**不算**——前者是桥本身、
 * 后者归事件清单，避免一项两算。
 */
let FRONTEND_TAURI_API_MARKERS: Array<(String, String)> = [
    ("getVersion(", "getVersion"),
    ("@tauri-apps/api/window", "tauri window API"),
    ("@tauri-apps/api/path", "tauri path API"),
    ("@tauri-apps/api/fs", "tauri fs API"),
    ("@tauri-apps/api/dialog", "tauri dialog API"),
    ("@tauri-apps/api/webview", "tauri webview API")
]

public func parseFrontendTauriApis(src: Source): ArrayList<ScanItem> {
    let out = ArrayList<ScanItem>()
    let byName = HashMap<String, ScanItem>()
    let lines = src.text.split("\n", -1)
    var ln: Int64 = 0
    for (line in lines) {
        ln += 1
        let t = line.trimAscii()
        if (t.startsWith("//") || t.startsWith("*")) {
            continue
        }
        for ((marker, symbol) in FRONTEND_TAURI_API_MARKERS) {
            if (markerPresentIn(line, marker)) {
                match (byName.get(symbol)) {
                    case Some(it) => it.site(src.rel, ln)
                    case None =>
                        let it = ScanItem("platform", symbol)
                        it.site(src.rel, ln)
                        byName.add(symbol, it)
                        out.add(it)
                }
            }
        }
    }
    return out
}

public func parseFrontend(src: Source): ArrayList<ScanItem> {
    let out = ArrayList<ScanItem>()
    let byName = HashMap<String, ScanItem>()
    let lines = src.text.split("\n", -1)
    var ln: Int64 = 0
    for (line in lines) {
        ln += 1
        // 跳过注释行，减少噪声（// 与 * 开头）
        let t = line.trimAscii()
        if (t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")) {
            continue
        }
        for ((marker, api) in FRONTEND_MARKERS) {
            if (markerPresentIn(line, marker)) {
                match (byName.get(api)) {
                    case Some(it) => it.site(src.rel, ln)
                    case None =>
                        let it = ScanItem("frontend", api)
                        it.site(src.rel, ln)
                        byName.add(api, it)
                        out.add(it)
                }
            }
        }
    }
    return out
}

// ============================================================
// ⑤ 插件清单（Cargo.toml + package.json）
// ============================================================

public func parsePluginCargo(text: String, rel: String): ArrayList<ScanItem> {
    let out = ArrayList<ScanItem>()
    let seen = HashMap<String, Bool>()
    let lines = text.split("\n", -1)
    var ln: Int64 = 0
    for (line in lines) {
        ln += 1
        let t = line.trimAscii()
        if (t.startsWith("#")) {
            continue
        }
        match (t.indexOf("tauri-plugin-")) {
            case Some(p) =>
                var i = p
                while (i < t.size) {
                    let b = t[i]
                    let ok = (b >= 97u8 && b <= 122u8) || (b >= 48u8 && b <= 57u8) || b == 45u8
                    if (!ok) {
                        break
                    }
                    i += 1
                }
                if (i > p) {
                    let full = t[p..i]
                    let short = full[(("tauri-plugin-").size)..full.size]
                    if (!seen.contains(short)) {
                        seen.add(short, true)
                        let it = ScanItem("plugin", short)
                        it.site(rel, ln)
                        out.add(it)
                    }
                }
            case None => ()
        }
    }
    return out
}

public func parsePluginNpm(text: String, rel: String): ArrayList<ScanItem> {
    let out = ArrayList<ScanItem>()
    let seen = HashMap<String, Bool>()
    let lines = text.split("\n", -1)
    var ln: Int64 = 0
    for (line in lines) {
        ln += 1
        match (line.indexOf("@tauri-apps/plugin-")) {
            case Some(p) =>
                var i = p + ("@tauri-apps/plugin-").size
                let start = i
                while (i < line.size) {
                    let b = line[i]
                    let ok = (b >= 97u8 && b <= 122u8) || (b >= 48u8 && b <= 57u8) || b == 45u8
                    if (!ok) {
                        break
                    }
                    i += 1
                }
                if (i > start) {
                    let short = line[start..i]
                    if (!seen.contains(short)) {
                        seen.add(short, true)
                        let it = ScanItem("plugin", short)
                        it.site(rel, ln)
                        out.add(it)
                    }
                }
            case None => ()
        }
    }
    return out
}

// ============================================================
// 判定规则：符号/能力 → (verdict, rule, evidence)
// 规则 id 与 docs/技术思路.md 的规则包编号一致（R3 平台 API / R5 前端 / R2 依赖）
// ============================================================

public func verdictOfPlatform(symbol: String): Array<String> {
    if (symbol == "rfd::FileDialog") {
        return [V_DOWNGRADE, "R3-004", "鸿蒙无原生文件对话框（能力位 0）→ 应用内目录树"]
    }
    if (symbol == "rfd::MessageDialog") {
        return [V_DOWNGRADE, "R3-005", "鸿蒙无原生对话框（能力位 0）→ 应用内确认框"]
    }
    if (symbol == "app_data_dir" || symbol == "dirs::data_dir" || symbol == "dirs::config_dir") {
        return [V_REWRITE, "R3-001", "OHOS 无 HOME 环境变量，路径解析返回 None（启动 panic 高发点）→ 沙箱路径 + cfg 分支"]
    }
    if (symbol == "HOME" || symbol == "APPDATA") {
        return [V_REWRITE, "R3-002", "OHOS 不提供该环境变量 → 沙箱路径 + cfg 分支"]
    }
    if (symbol == "std::process::Command") {
        return [V_DOWNGRADE, "R3-007", "鸿蒙应用沙箱内起子进程受限 → 应用内实现或如实拒绝"]
    }
    if (symbol == "std::env::temp_dir") {
        return [V_DOWNGRADE, "R3-008", "临时目录语义不同 → 用应用沙箱 cache 目录"]
    }
    if (symbol == "tauri_plugin_opener" || symbol == "open::that") {
        return [V_DOWNGRADE, "R3-009", "打开链接/文件依赖宿主能力（鸿蒙能力位 0）→ 应用内提示"]
    }
    // ---- 前端侧 @tauri-apps/api 能力（C2 基线对照后补的一类：OHOS 无对应实现，要换系统 API）----
    if (symbol == "getVersion") {
        return [V_REWRITE, "R3-010", "鸿蒙无 app 版本 API（@tauri-apps/api/app 走宿主）→ bundleManager 桥接"]
    }
    if (symbol == "tauri window API") {
        return [V_REWRITE, "R3-011", "窗口 API 走宿主 window 能力，鸿蒙窗口能力面不同 → 校准 + cfg 分支"]
    }
    if (symbol == "tauri path API") {
        return [V_REWRITE, "R3-012", "path API 依赖 HOME/沙箱路径 → 同 R3-001，改沙箱路径"]
    }
    if (symbol == "tauri fs API") {
        return [V_DOWNGRADE, "R3-013", "fs scope 语义不同（沙箱）→ 校准 capabilities 的 scopes.fs"]
    }
    if (symbol == "tauri dialog API") {
        return [V_DOWNGRADE, "R3-014", "鸿蒙无原生对话框（能力位 0）→ 应用内 overlay"]
    }
    if (symbol == "tauri webview API") {
        return [V_MANUAL, "", "WebView 直接操作在 ArkWeb 下能力面不同，需要人判断影响面"]
    }
    return [V_MANUAL, "", "未归类的平台 API：需要人判断影响面"]
}

public func verdictOfFrontend(api: String): Array<String> {
    if (api == "localStorage") {
        return [V_REWRITE, "R5-001", "ArkWeb 自定义 scheme 下 localStorage 为 null → 透明桥（内存缓存 + 防抖写回）"]
    }
    if (api == "sessionStorage") {
        return [V_REWRITE, "R5-001b", "同 localStorage 的自定义 scheme 限制 → 同款透明桥"]
    }
    if (api == "window.confirm" || api == "window.prompt") {
        return [V_REWRITE, "R5-002", "ArkWeb 未接 onJsConfirm/onJsPrompt：confirm 静默 false、prompt 返回 null → 应用内 Promise 化对话框"]
    }
    if (api == "input[type=color]") {
        return [V_REWRITE, "R5-005", "ArkWeb 不支持且 display:none 仍参与合成层（会拖掉整块 dialog 绘制）→ remove() 元素 + 应用内色板"]
    }
    if (api == "input[type=file]") {
        return [V_DOWNGRADE, "R5-006", "ArkWeb 文件选择需原生选择器桥 → 未接时该功能不可用"]
    }
    if (api == "Notification") {
        return [V_DOWNGRADE, "R5-008", "鸿蒙系统通知能力位 0 → 页内提示 / 可选开关"]
    }
    if (api == "navigator.clipboard") {
        return [V_REWRITE, "R5-007", "ArkWeb 剪贴板受限 → 走宿主 pasteboard（NDK FFI）"]
    }
    if (api == "Blob 下载") {
        return [V_DOWNGRADE, "R5-009", "ArkWeb 下载桥未接线 → Rust 端写文件 + 系统保存"]
    }
    if (api == "canvas.toDataURL") {
        return [V_REWRITE, "R5-010", "ArkWeb canvas 可用但导出大图有内存/编码差异 → 改走 toBlob + 原生保存（不要 base64 长串跨桥）"]
    }
    if (api == "FileReader") {
        return [V_NA, "", "FileReader 本身 ArkWeb 可用；只有配合 <input type=file> 才受限（那条单独计项）"]
    }
    if (api == "window.open") {
        return [V_NA, "", "主路径已走 open_url 命令；window.open 仅浏览器开发回退，ArkWeb 不可用也不影响功能"]
    }
    if (api == "fetch") {
        return [V_MANUAL, "", "跨源 fetch：需确认 ArkWeb 的 CORS 与出网白名单（能力/清单）"]
    }
    return [V_MANUAL, "", "未归类的前端能力：需要人判断"]
}

public func verdictOfPlugin(short: String): Array<String> {
    // 直接可用的（鸿蒙侧已有等价实现，框架真机验证过）
    if (short == "clipboard-manager") {
        return [V_NA, "", "直接可用：鸿蒙走 pasteboard NDK FFI（框架已真机验证）"]
    }
    if (short == "store") {
        return [V_NA, "", "直接可用：纯仓颉 KV 持久化，无平台依赖"]
    }
    // 宿主能力位为 0 → 降级
    if (short == "notification") {
        return [V_DOWNGRADE, "R6-001", "鸿蒙通知能力位 0 → 降级 + 可选开关"]
    }
    if (short == "dialog") {
        return [V_DOWNGRADE, "R6-002", "鸿蒙无原生对话框（能力位 0）→ 应用内 overlay"]
    }
    if (short == "shell") {
        return [V_DOWNGRADE, "R6-003", "打开链接走宿主；launchHidden 走 C 桥（鸿蒙无 C 桥）→ 降级"]
    }
    if (short == "opener") {
        return [V_DOWNGRADE, "R6-005", "打开外部链接/文件依赖宿主能力（鸿蒙能力位 0）→ 应用内提示或系统分享"]
    }
    if (short == "process") {
        return [V_DOWNGRADE, "R6-006", "restart/exit 等进程控制在鸿蒙应用沙箱内不可用 → 降级"]
    }
    if (short == "updater") {
        return [V_DOWNGRADE, "R6-007", "鸿蒙应用更新走应用市场通道，无应用内自更新 → 降级并改分发说明"]
    }
    if (short == "deep-link") {
        return [V_DOWNGRADE, "R6-008", "URL scheme 唤起需鸿蒙侧 want/uri 声明 → 降级或改为应用内路由"]
    }
    if (short == "single-instance") {
        return [V_DOWNGRADE, "R6-009", "单实例语义需鸿蒙侧任务栈/ability 机制承接 → 降级"]
    }
    if (short == "global-shortcut" || short == "tray-icon" || short == "autostart") {
        return [V_DOWNGRADE, "R6-010", "鸿蒙能力位 0（全局快捷键/托盘/开机自启）→ 降级"]
    }
    // 语义不同的 → 改造
    if (short == "fs") {
        return [V_REWRITE, "R6-004", "路径 scope 语义不同（沙箱）→ 校准 capabilities 的 scopes.fs"]
    }
    if (short == "window-state") {
        return [V_REWRITE, "R6-011", "窗口尺寸/位置持久化依赖宿主窗口 API，鸿蒙窗口能力面不同 → 改走应用侧存储 + 窗口配置"]
    }
    if (short == "log") {
        return [V_REWRITE, "R6-012", "日志落盘点要改沙箱目录（鸿蒙无 HOME）→ 改走宿主 log 或应用 files 目录"]
    }
    if (short == "os") {
        return [V_REWRITE, "R6-013", "平台信息取值（版本/架构/主机名）鸿蒙与桌面不同 → 校准取值与降级分支"]
    }
    // 需要实测确认的（真·人工）
    if (short == "http" || short == "ws") {
        return [V_MANUAL, "", "出网/TLS 在鸿蒙走系统网络栈；需实测连通与流式能力"]
    }
    if (short == "sqlite") {
        return [V_MANUAL, "", "需确认鸿蒙侧 libsqlite3 可用性与链接方式"]
    }
    if (short == "serial") {
        return [V_MANUAL, "", "USB 串口需 ArkTS 侧发起或 system_grant 权限，应用内 FFI 不可达"]
    }
    return [V_MANUAL, "", "未归类的插件：需要人判断"]
}

/**
 * 事件的处置结论：**事件桥本身不是迁移障碍**——cj-tauri 的 IPC 双向桥（invoke / 事件回投）
 * 在 Windows / Linux / 鸿蒙三端均已真机闭环（框架 `docs/平台能力矩阵.md`）。
 * 所以事件名一律 `不适用`，避免把 20 多个事件名都算成"人工介入"（那会直接把 A3 的 ≤5 撑爆）。
 * 真正要看的载荷里有没有平台句柄——那属于具体命令/平台 API 的事，已在 platform 类里覆盖。
 */
public func verdictOfEvent(_: String): Array<String> {
    return [V_NA, "", "事件桥三端闭环（框架真机验证）；载荷若含平台句柄见 platform 类清单"]
}

/**
 * 命令的处置结论：**命令本身通常不需要改**——要改的是它内部用到的平台 API，
 * 而那些决策已经落在 `platform` 类清单上（同文件命中会记在 evidence 里）。
 * 所以这里一律 `不适用`，避免"12 条命令全判改造"这种把清单条数当改动量的过度归因。
 */
public func verdictOfCommand(_: String, nearPlatformApi: Bool): Array<String> {
    if (nearPlatformApi) {
        return [V_NA, "", "命令本身无需改动；同文件命中平台 API，处置见 platform 类清单"]
    }
    return [V_NA, "", "命令本身无需改动；未命中平台 API（自动判定）"]
}

// ============================================================
// 扫描结果与编排
// ============================================================

public class ScanResult {
    public var project = JsonObject()
    public var items: ArrayList<ScanItem> = ArrayList<ScanItem>()
    public var notes: ArrayList<String> = ArrayList<String>()
    /** C2 对照结果：只有给了人工基线才有（没基线时为空，指标如实标 -1，不编 100） */
    public var conf: Option<Confidence> = None

    public func counts(): Array<Int64> {
        var total: Int64 = 0
        var decided: Int64 = 0
        var manual: Int64 = 0
        var unknown: Int64 = 0
        for (it in this.items) {
            total += 1
            if (it.verdict == V_UNKNOWN) {
                unknown += 1
            } else {
                decided += 1
            }
            if (it.verdict == V_MANUAL) {
                manual += 1
            }
        }
        return [total, decided, manual, unknown]
    }

    public func metricsJson(): JsonObject {
        let c = this.counts()
        let total = c[0]
        let decided = c[1]
        let manual = c[2]
        let unknown = c[3]
        var o = JsonObject()
        o.put("R", JsonInt(total))
        o.put("D", JsonInt(decided))
        o.put("H", JsonInt(manual))
        o.put("U", JsonInt(unknown))
        // C1 结论覆盖率（百分比，保留一位小数）
        let c1 = if (total == 0) { 0.0 } else { Float64(decided) * 100.0 / Float64(total) }
        let c3 = if (total == 0) { 0.0 } else { Float64(manual) * 100.0 / Float64(total) }
        o.put("C1", JsonFloat(c1))
        o.put("C3", JsonFloat(c3))
        // C2 发现置信度：只有做了人工基线 diff 才有数（没做就是 -1 + 说明，绝不编 100）
        match (this.conf) {
            case Some(cf) =>
                o.put("C2", JsonFloat(cf.c2()))
                o.put("C2Note", JsonString("(基线项 ${cf.baselineTotal} − 漏识别 ${cf.missed.size}) ÷ 基线项 ${cf.baselineTotal}；来源：${cf.source}"))
                o.put("confMissed", JsonInt(Int64(cf.missed.size)))
                o.put("confExtra", JsonInt(Int64(cf.extra.size)))
                o.put("confPrecision", JsonFloat(cf.precision()))
            case None =>
                o.put("C2", JsonNull())
                o.put("C2Note", JsonString("未提供人工基线（samples/baselines/<工程>.json），本次不出 C2"))
        }
        return o
    }

    public func scoreJson(): JsonObject {
        let c = this.counts()
        let manual = c[2]
        let unknown = c[3]
        // 运行时维：前端能力项为主；平台 API 维：平台符号为主
        var runtimeDeduct: Int64 = 0
        var apiDeduct: Int64 = 0
        var frontendCount: Int64 = 0
        var platformCount: Int64 = 0
        for (it in this.items) {
            if (it.kind == "frontend") {
                frontendCount += 1
                // 改造 = 规则能自动改，代价低；降级 = 要换实现/牺牲能力，代价高
                if (it.verdict == V_DOWNGRADE) {
                    runtimeDeduct += 15
                } else if (it.verdict == V_REWRITE) {
                    runtimeDeduct += 5
                }
            } else if (it.kind == "platform") {
                platformCount += 1
                if (it.verdict == V_DOWNGRADE) {
                    apiDeduct += 15
                } else if (it.verdict == V_REWRITE) {
                    apiDeduct += 5
                }
            }
        }
        var runtime = 100 - runtimeDeduct
        if (runtime < 0) {
            runtime = 0
        }
        var api = 100 - apiDeduct
        if (api < 0) {
            api = 0
        }
        var o = JsonObject()
        // 「一项都没扫出来」≠「一项问题都没有」：没有前端项/平台项时该维度**没有依据**，
        // 如实标 -1（与 build/deps/dist 同口径）。否则空目录的 runtime/api 双双算 100 分、
        // 总分 100——看起来像"完美工程"，实际是什么都没扫到（0.39.107 实测踩到）。
        let rtOk = frontendCount > 0
        let apiOk = platformCount > 0
        o.put("runtime", JsonInt(if (rtOk) { runtime } else { -1 }))
        o.put("api", JsonInt(if (apiOk) { api } else { -1 }))
        // 未扫描维度如实标 -1（不编造 100 分）
        o.put("build", JsonInt(-1))
        o.put("deps", JsonInt(-1))
        o.put("dist", JsonInt(-1))
        var dims = ""
        if (rtOk) {
            dims = "runtime"
        }
        if (apiOk) {
            dims = if (dims == "") { "api" } else { dims + ",api" }
        }
        o.put("scannedDims", JsonString(dims))
        // 总分只在已扫描维度上做**加权平均**：Σ(维分×权重) / Σ权重
        // 注意别再乘 100（第一版写成 weighted×100/0.45，直接算出 2500）
        var weightSum = 0.0
        var weighted = 0.0
        if (rtOk) {
            weightSum = weightSum + 0.25
            weighted = weighted + Float64(runtime) * 0.25
        }
        if (apiOk) {
            weightSum = weightSum + 0.20
            weighted = weighted + Float64(api) * 0.20
        }
        // 两个维度都没依据 → 总分 -1（不编造分数）
        let totalScore = if (weightSum > 0.0) { Int64(weighted / weightSum) } else { -1 }
        o.put("total", JsonInt(totalScore))
        o.put("partial", JsonBool(true))
        o.put("note", JsonString("build/deps/dist 三维待 P3/P5 扫描；本分数只反映 runtime+api 两维"))
        o.put("manualItems", JsonInt(manual))
        o.put("unknownItems", JsonInt(unknown))
        return o
    }

    public func itemsByKind(kind: String): JsonArray {
        var arr = JsonArray()
        for (it in this.items) {
            if (it.kind == kind) {
                arr.add(it.toJson())
            }
        }
        return arr
    }

    public func toJson(): JsonObject {
        let c = this.counts()
        var o = JsonObject()
        o.put("schema", JsonString("lingqu/scan/v1"))
        o.put("project", this.project)
        o.put("metrics", this.metricsJson())
        o.put("score", this.scoreJson())
        var items = JsonObject()
        items.put("commands", this.itemsByKind("command"))
        items.put("events", this.itemsByKind("event"))
        items.put("plugins", this.itemsByKind("plugin"))
        items.put("frontend", this.itemsByKind("frontend"))
        items.put("platform", this.itemsByKind("platform"))
        o.put("items", items)
        // 阻塞项：未知=hard（必须清零），人工=soft（计入 A3）
        var blockers = JsonArray()
        var seq: Int64 = 0
        for (it in this.items) {
            if (it.verdict == V_UNKNOWN || it.verdict == V_MANUAL) {
                seq += 1
                var b = JsonObject()
                b.put("id", JsonString("B-" + seq.toString()))
                b.put("severity", JsonString(if (it.verdict == V_UNKNOWN) { "hard" } else { "soft" }))
                b.put("kind", JsonString(it.kind))
                b.put("name", JsonString(it.name))
                b.put("site", JsonString(if (it.sites.size > 0) { it.sites[0] } else { "" }))
                b.put("evidence", JsonString(it.evidence))
                blockers.add(b)
            }
        }
        o.put("blockers", blockers)
        // C2 对照（有基线时才有这一段）
        match (this.conf) {
            case Some(cf) => o.put("confidence", cf.toJson())
            case None => ()
        }
        var notes = JsonArray()
        for (n in this.notes) {
            notes.add(JsonString(n))
        }
        o.put("notes", notes)
        o.put("counts", JsonInt(c[0]))
        return o
    }

    public func toJsonString(): String {
        return this.toJson().toJsonString()
    }
}

// ============================================================
// 编排：scanProject
// ============================================================

func readTextOr(p: String, fallback: String): String {
    try {
        return String.fromUtf8(File.readFrom(p))
    } catch (e: Exception) {
        let _ = e
        return fallback
    }
}

/** 从 "key": "value" 形式里取值（只认双引号字符串值；取不到回空串） */
public func jsonStringField(text: String, key: String): String {
    match (text.indexOf("\"" + key + "\"")) {
        case Some(p) =>
            match (text.indexOf(":", p + key.size + 2)) {
                case Some(colon) => return firstStringLiteral(text, colon + 1)
                case None => return ""
            }
        case None => return ""
    }
}

/** 从 Cargo.toml 里取某个依赖的版本（支持 `x = "1.2"` 与 `x = { version = "1.2" ... }`） */
public func cargoDepVersion(cargoText: String, dep: String): String {
    let lines = cargoText.split("\n", -1)
    for (line in lines) {
        let t = line.trimAscii()
        if (t.startsWith(dep) && t.size > dep.size && (t[dep.size] == 32u8 || t[dep.size] == 62u8) || t.startsWith(dep + " =")) {
            match (t.indexOf("=")) {
                case Some(eq) =>
                    let rest = t[(eq + 1)..t.size]
                    match (rest.indexOf("version")) {
                        case Some(vp) =>
                            match (rest.indexOf("=", vp)) {
                                case Some(e2) => return firstStringLiteral(rest, e2 + 1)
                                case None => ()
                            }
                        case None => return firstStringLiteral(rest, 0)
                    }
                case None => ()
            }
        }
    }
    return ""
}

/**
 * 从工程路径取末段名字（落档文件名用）。
 *
 * 坑：Windows 路径是 `E:\test\rust\habit-tree` 这种**反斜杠**形式，只按 `/` 切会把整条路径
 * 当成名字，拼出来的落档路径 `.lingqu/scan/E:\test\rust\habit-tree.json` 非法 →
 * `FSException: The input path 'parent' ... does not exist`（写档静默失败，v0.6.0 一直在丢证据）。
 * 所以两种分隔符都要认，取**最后出现的那个**。
 * 末尾带分隔符时返回空串，由调用方回退到默认名。
 */
/** 去掉末尾分隔符（纯函数） */
func nameStripTail(p: String): String {
    var s = p.trimAscii()
    while (s.size > 0 && (s.endsWith("/") || s.endsWith("\\"))) {
        s = s[0..(s.size - 1)]
    }
    return s
}

/** 路径最后一段（纯函数；空串给空串） */
func nameLastSegment(p: String): String {
    let s = nameStripTail(p)
    if (s.size == 0) {
        return ""
    }
    var cut: Int64 = -1
    match (s.lastIndexOf("/")) {
        case Some(i) => cut = i
        case None => ()
    }
    match (s.lastIndexOf("\\")) {
        case Some(i) => if (i > cut) { cut = i } else { () }
        case None => ()
    }
    if (cut < 0) {
        return s
    }
    return s[(cut + 1)..s.size]
}

/** 相对路径判据（纯函数）：无盘符、不以分隔符开头 */
public func nameIsRelPath(p: String): Bool {
    let s = p.trimAscii()
    if (s.size == 0) {
        return true
    }
    if (s.startsWith("/") || s.startsWith("\\")) {
        return false
    }
    if (s.size >= 2 && s[1] == 58) {
        return false   // ':' → 盘符
    }
    return true
}

/**
 * 工程名解析（**纯函数**，cwd 由调用方注入，便于单测）。
 *
 * 0.39.2 的坑：agent 按我们的任务书用 `--path .` 跑，旧实现把 `"."` 原样当名字
 * （再被 sanitizeFileName 清成空串）→ 落档写成 `..json`。这里按 cwd 解析相对路径：
 *   `"."` → cwd 末段；`".."` → cwd 的上一级末段；`"./x"` → `x`；绝对路径照旧取末段。
 */
public func projectNameOfPath(path: String, cwd: String): String {
    let p = nameStripTail(hostPathOf(path))
    let base = nameStripTail(hostPathOf(cwd))
    if (p.size == 0 || p == ".") {
        return nameLastSegment(base)
    }
    if (p == "..") {
        // 取 base 的父目录末段（先砍掉 base 自己的末段）
        let own = nameLastSegment(base)
        if (own.size == 0 || base.size <= own.size) {
            return nameLastSegment(base)
        }
        return nameLastSegment(base[0..(base.size - own.size - 1)])
    }
    if (!nameIsRelPath(p)) {
        let seg = nameLastSegment(p)
        if (seg.size == 0 || seg == "." || seg == "..") {
            return nameLastSegment(base)
        }
        return seg
    }
    // 相对路径：按 cwd 拼再取末段（消化 `./` 与 `..` 这类段）
    let seg2 = nameLastSegment(base + "/" + p)
    if (seg2.size == 0 || seg2 == "." || seg2 == "..") {
        return nameLastSegment(base)
    }
    return seg2
}

/** 宿主路径归一（纯函数，仅把 `\` 统一成 `/`；不碰盘符） */
func hostPathOf(p: String): String {
    return p.trimAscii().replace("\\", "/")
}
public func projectNameOf(path: String): String {
    // 0.39.2 修：`--path .` 曾把名字取成 `"."`（再被 sanitize 清成空串 → 落档写成 `..json`）。
    // 我们的 AGENTS.md 正是教 agent 在工程根用 `--path .`，所以这里必须把相对路径按 cwd 解析。
    var cwd = ""
    try {
        cwd = getWorkingDirectory().toString()
    } catch (e: Exception) {
        let _ = e
    }
    if (cwd.size > 0) {
        let n = projectNameOfPath(path, cwd)
        if (n.size > 0) {
            return n
        }
    }
    var cut: Int64 = -1
    match (path.lastIndexOf("/")) {
        case Some(i) => cut = i
        case None => ()
    }
    match (path.lastIndexOf("\\")) {
        case Some(i) => if (i > cut) { cut = i }
        case None => ()
    }
    if (cut < 0) {
        return path
    }
    return path[(cut + 1)..path.size]
}

/**
 * 把名字里在 Windows 文件名中非法的字符换成 `_`（`: * ? " < > |`）。
 * 只管「能不能当文件名」，不改变可读性：`habit-tree` 这类正常名原样返回。
 */
public func sanitizeFileName(name: String): String {
    var s = name
    for (bad in [":", "*", "?", "\"", "<", ">", "|"]) {
        s = s.replace(bad, "_")
    }
    return s
}

/**
 * 判定「Rust 工程根相对工程目录的位置」：
 *   · `Some("src-tauri")` —— 传统布局（Cargo.toml 在 `<工程>/src-tauri/`）
 *   · `Some("")`          —— 扁平布局（`src-tauri` 就是工程根，`Cargo.toml` 在工程根）
 *   · `None`              —— 两种都没有，调用方报「不是 Tauri 工程」
 *
 * 为什么单独收成函数：布局是**多处共用的判据**（Cargo.toml 位置、tauri.conf.json 位置、
 * `src/` 位置、落档里的站点标签）。散在代码里就会漂移——rust-music-3 实测栽过：
 * 只认 `src-tauri/` 时扫描器报「不是 Tauri v2 工程」，五类清单恒为 0，
 * verify 的分母随之缩到 3 项、可用率虚高成 100%（§4-129 扁平布局同族坑）。
 */
public func srcTauriDirOf(hasNested: Bool, hasFlat: Bool): Option<String> {
    if (hasNested) {
        return Some("src-tauri")
    }
    if (hasFlat) {
        return Some("")
    }
    return None
}

public func scanProject(root: String): ScanResult {
    return scanProject(root, None)
}

/**
 * 带人工基线的扫描：算完五类清单后做**双向 diff**，把 C2 发现置信度填进结果。
 * 没有基线就按 None 走 —— C2 留空并写明原因，不编造 100。
 */
public func scanProject(root: String, baseline: Option<Baseline>): ScanResult {
    let res = ScanResult()

    // ---------- 1) 工程识别 ----------
    // 两种布局都认（§4-129 同族）：传统 `<工程>/src-tauri/Cargo.toml`，扁平布局（`src-tauri` 就是
    // 工程根，如 rust-music-3）直接在工程根。只认第一种会把扁平工程判成"不是 Tauri 工程"→
    // 五类清单恒为 0 → verify 的分母缩到只剩装配项、可用率虚高。
    var srcDir = ""
    let hasNested = exists(Path("${root}/src-tauri/Cargo.toml"))
    let hasFlat = exists(Path("${root}/Cargo.toml"))
    match (srcTauriDirOf(hasNested, hasFlat)) {
        case Some(d) => srcDir = d
        case None =>
            res.notes.add("未找到 Cargo.toml（找过 ${root}/src-tauri/Cargo.toml 与 ${root}/Cargo.toml）—— 不是 Tauri v2 工程？")
            return res
    }
    let cargoRel = if (srcDir == "") { "Cargo.toml" } else { "${srcDir}/Cargo.toml" }
    let confRel = if (srcDir == "") { "tauri.conf.json" } else { "${srcDir}/tauri.conf.json" }
    let cargoText = readTextOr("${root}/${cargoRel}", "")
    let confText = readTextOr("${root}/${confRel}", "")
    let pkgText = readTextOr("${root}/package.json", "")

    var project = JsonObject()
    project.put("root", JsonString(root))
    project.put("crate", JsonString(cargoDepVersion(cargoText, "name")))
    project.put("tauri", JsonString(cargoDepVersion(cargoText, "tauri")))
    project.put("bundleId", JsonString(jsonStringField(confText, "identifier")))
    project.put("frontendDist", JsonString(jsonStringField(confText, "frontendDist")))
    res.project = project

    if (cargoText.size == 0) {
        // 文件在、但读不出来（编码/权限）与"压根没有"是两件事，别混成一句"不是 Tauri 工程"
        res.notes.add("找到了 ${cargoRel} 但读不出内容（可能是编码或权限问题）")
        return res
    }

    // ---------- 2) 收集源码 ----------
    let rustRoots = if (srcDir == "") { ["src"] } else { ["${srcDir}/src"] }
    let rustSources = collectSources(root, rustRoots, [".rs"])
    let frontSources = collectSources(root, ["src", "app", "frontend", "ui"], [".ts", ".tsx", ".js", ".jsx", ".html", ".css"])
    res.notes.add("Rust 源文件 ${rustSources.size} 个，前端源文件 ${frontSources.size} 个")

    // ---------- 3) 平台 API（先扫，命令要靠它判"同文件命中"）----------
    // 合并口径：**同一符号跨文件合并成一项**（口径草案 Q1）；文件内部由 parse 负责去重
    let platformRel = HashMap<String, Bool>()
    var platformMap = HashMap<String, ScanItem>()
    for (src in rustSources) {
        let hit = parsePlatformApis(src)
        if (hit.size > 0) {
            platformRel.add(src.rel, true)
        }
        for (it in hit) {
            match (platformMap.get(it.name)) {
                case Some(old) => for (s in it.sites) {
                    old.sites.add(s)
                }
                case None => platformMap.add(it.name, it)
            }
        }
    }
    var platformOrder = ArrayList<String>()
    for (src in rustSources) {
        for (it in parsePlatformApis(src)) {
            if (!platformOrder.contains(it.name)) {
                platformOrder.add(it.name)
            }
        }
    }
    for (nm in platformOrder) {
        match (platformMap.get(nm)) {
            case Some(it) =>
                let rule = verdictOfPlatform(it.name)
                it.decide(rule[0], rule[1], rule[2])
                res.items.add(it)
            case None => ()
        }
    }

    // ---------- 4) 前端能力（同一能力跨文件合并）----------
    var frontMap = HashMap<String, ScanItem>()
    var frontOrder = ArrayList<String>()
    for (src in frontSources) {
        for (it in parseFrontend(src)) {
            if (!frontOrder.contains(it.name)) {
                frontOrder.add(it.name)
            }
            match (frontMap.get(it.name)) {
                case Some(old) => for (s in it.sites) {
                    old.sites.add(s)
                }
                case None => frontMap.add(it.name, it)
            }
        }
    }
    for (nm in frontOrder) {
        match (frontMap.get(nm)) {
            case Some(it) =>
                let rule = verdictOfFrontend(it.name)
                it.decide(rule[0], rule[1], rule[2])
                res.items.add(it)
            case None => ()
        }
    }

    // ---------- 4.5) 前端侧 @tauri-apps/api 能力（并进平台 API 类）----------
    var feApiMap = HashMap<String, ScanItem>()
    var feApiOrder = ArrayList<String>()
    for (src in frontSources) {
        for (it in parseFrontendTauriApis(src)) {
            if (!feApiOrder.contains(it.name)) {
                feApiOrder.add(it.name)
            }
            match (feApiMap.get(it.name)) {
                case Some(old) => for (s in it.sites) {
                    old.sites.add(s)
                }
                case None => feApiMap.add(it.name, it)
            }
        }
    }
    for (nm in feApiOrder) {
        match (feApiMap.get(nm)) {
            case Some(it) =>
                let rule = verdictOfPlatform(it.name)
                it.decide(rule[0], rule[1], rule[2])
                res.items.add(it)
            case None => ()
        }
    }

    // ---------- 5) 事件（同一事件名跨文件合并）----------
    var eventMap = HashMap<String, ScanItem>()
    var eventOrder = ArrayList<String>()
    var allSources = ArrayList<Source>()
    for (s in rustSources) {
        allSources.add(s)
    }
    for (s in frontSources) {
        allSources.add(s)
    }
    for (src in allSources) {
        for (it in parseEvents(src)) {
            if (!eventOrder.contains(it.name)) {
                eventOrder.add(it.name)
            }
            match (eventMap.get(it.name)) {
                case Some(old) => for (s in it.sites) {
                    old.sites.add(s)
                }
                case None => eventMap.add(it.name, it)
            }
        }
    }
    for (nm in eventOrder) {
        match (eventMap.get(nm)) {
            case Some(it) =>
                let ev = verdictOfEvent(it.name)
                it.decide(ev[0], ev[1], ev[2])
                res.items.add(it)
            case None => ()
        }
    }

    // ---------- 6) 插件 ----------
    let pluginItems = HashMap<String, ScanItem>()
    for (it in parsePluginCargo(cargoText, cargoRel)) {
        match (pluginItems.get(it.name)) {
            case Some(old) => for (s in it.sites) {
                old.sites.add(s)
            }
            case None => pluginItems.add(it.name, it)
        }
    }
    for (it in parsePluginNpm(pkgText, "package.json")) {
        match (pluginItems.get(it.name)) {
            case Some(old) => for (s in it.sites) {
                old.sites.add(s)
            }
            case None => pluginItems.add(it.name, it)
        }
    }
    for ((_, it) in pluginItems) {
        let rule = verdictOfPlugin(it.name)
        it.decide(rule[0], rule[1], rule[2])
        res.items.add(it)
    }

    // ---------- 7) 命令（最后，靠平台命中判 cfg 需求）----------
    let registered = ArrayList<String>()
    for (src in rustSources) {
        for (n in parseHandlerRegistrations(src.text)) {
            if (!registered.contains(n)) {
                registered.add(n)
            }
        }
    }
    for (src in rustSources) {
        let nearPlatform = platformRel.contains(src.rel)
        for (it in parseCommands(src)) {
            let rule = verdictOfCommand(it.name, nearPlatform)
            it.decide(rule[0], rule[1], rule[2])
            if (!registered.contains(it.name)) {
                it.evidence = it.evidence + "；未在 generate_handler! 注册（可能是内部函数或注册写法非常规）"
            }
            res.items.add(it)
        }
    }
    if (registered.size > 0) {
        res.notes.add("generate_handler! 注册了 ${registered.size} 个命令")
    }

    // ---------- 8) C2 发现置信度：与人工基线双向 diff ----------
    match (baseline) {
        case Some(bl) =>
            let cf = diffConfidence(bl, res.items)
            res.conf = Some(cf)
            res.notes.add("C2 对照基线「${bl.project}」（${bl.total()} 项）：漏识别 ${cf.missed.size}，误识别 ${cf.extra.size}，结论分歧 ${cf.verdictDiff.size}")
            if (cf.missed.size > 0) {
                res.notes.add("漏识别：${cf.missed}")
            }
            if (cf.extra.size > 0) {
                res.notes.add("误识别（扫描有、基线无）：${cf.extra}")
            }
        case None =>
            res.notes.add("未提供人工基线，C2 不出数（口径见 docs/P2-scan-口径草案.md §A4）")
    }

    return res
}
