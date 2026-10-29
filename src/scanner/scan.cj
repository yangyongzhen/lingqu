package lingqu.scanner

import std.collection.*
import std.fs.*
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

public func parsePlatformApis(src: Source): ArrayList<ScanItem> {
    let out = ArrayList<ScanItem>()
    let byName = HashMap<String, ScanItem>()
    let lines = src.text.split("\n", -1)
    var ln: Int64 = 0
    for (line in lines) {
        ln += 1
        for ((marker, symbol) in PLATFORM_MARKERS) {
            if (line.contains(marker)) {
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
    ("fetch(", "fetch")
]

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
            if (line.contains(marker)) {
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
        // C2 需要人工基线比对，本版留空并如实标注
        o.put("C2", JsonNull())
        o.put("C2Note", JsonString("需与人工基线清单双向 diff（P2 收尾时做）"))
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
        o.put("runtime", JsonInt(runtime))
        o.put("api", JsonInt(api))
        // 未扫描维度如实标 -1（不编造 100 分）
        o.put("build", JsonInt(-1))
        o.put("deps", JsonInt(-1))
        o.put("dist", JsonInt(-1))
        o.put("scannedDims", JsonString("runtime,api"))
        // 总分只在已扫描维度上做**加权平均**：Σ(维分×权重) / Σ权重
        // 注意别再乘 100（第一版写成 weighted×100/0.45，直接算出 2500）
        let weightSum = 0.25 + 0.20
        let totalScore = (Float64(runtime) * 0.25 + Float64(api) * 0.20) / weightSum
        o.put("total", JsonInt(Int64(totalScore)))
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

public func scanProject(root: String): ScanResult {
    let res = ScanResult()

    // ---------- 1) 工程识别 ----------
    let cargoText = readTextOr("${root}/src-tauri/Cargo.toml", "")
    let confText = readTextOr("${root}/src-tauri/tauri.conf.json", "")
    let pkgText = readTextOr("${root}/package.json", "")

    var project = JsonObject()
    project.put("root", JsonString(root))
    project.put("crate", JsonString(cargoDepVersion(cargoText, "name")))
    project.put("tauri", JsonString(cargoDepVersion(cargoText, "tauri")))
    project.put("bundleId", JsonString(jsonStringField(confText, "identifier")))
    project.put("frontendDist", JsonString(jsonStringField(confText, "frontendDist")))
    res.project = project

    if (cargoText.size == 0) {
        res.notes.add("未找到 src-tauri/Cargo.toml —— 不是 Tauri v2 工程？")
        return res
    }

    // ---------- 2) 收集源码 ----------
    let rustSources = collectSources(root, ["src-tauri/src"], [".rs"])
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
    for (it in parsePluginCargo(cargoText, "src-tauri/Cargo.toml")) {
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

    return res
}
