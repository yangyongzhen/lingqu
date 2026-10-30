package lingqu.compiler

import std.collection.*
import stdx.encoding.json.*

/*
 * T5-1 交叉编译诊断的**纯函数半边**：解析 `cargo build --message-format=json` 输出。
 *
 * 为什么用 JSON 而不是 grep 文本：cargo 的 JSON 帧把「哪条 error / 哪个文件哪一行 / 建议」
 * 结构化给出，直接喂给六道闸和指纹库比正则稳。**但**实测（2026-10-30）有一条关键事实：
 *
 *   · Rust 编译错误 → 有 `compiler-message` 帧（带 rendered 全文 + spans）；
 *   · build-script / 链接 / pkg-config 这类失败 → **JSON 流里没有 compiler-message**，
 *     报错只出现在 stderr，stdout 只有 `build-finished{"success":false}`。
 *
 * 所以命令层必须**同时**收 stdout(JSONL) 与 stderr(人读日志)，本文件只负责前者 +
 * 归一化成可匹配指纹的文本；stderr 侧由命令层原样拼接后一起进指纹库。
 */

/** 一条构建诊断（从 compiler-message 归一化而来） */
public class BuildDiag {
    public var level: String      // error / warning / note / help
    public var code: String       // E0308 之类，可空
    public var message: String    // 一句话
    public var file: String       // 主 span 的文件（工程相对路径）
    public var line: Int64        // 主 span 行号（0 = 未知）
    public var column: Int64
    public var rendered: String   // cargo 给的完整人读片段（含源码上下文）

    public init(level: String, code: String, message: String, file: String, line: Int64,
        column: Int64, rendered: String) {
        this.level = level
        this.code = code
        this.message = message
        this.file = file
        this.line = line
        this.column = column
        this.rendered = rendered
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("level", JsonString(this.level))
        o.put("code", JsonString(this.code))
        o.put("message", JsonString(this.message))
        o.put("file", JsonString(this.file))
        o.put("line", JsonInt(this.line))
        o.put("column", JsonInt(this.column))
        return o
    }
}

/** 一次解析的总结果 */
public class BuildParse {
    public var diags: ArrayList<BuildDiag> = ArrayList<BuildDiag>()
    /** 产物文件名（compiler-artifact 的 filenames 末段；.so/.a/可执行） */
    public var artifacts: ArrayList<String> = ArrayList<String>()
    /** 是否见到 build-finished.success=true（cargo 自报成功） */
    public var finishedOk: Bool = false
    public var sawFinished: Bool = false
    /** 解析不过的行数（输出被截断/非 JSON 混杂时 > 0，用于如实标注） */
    public var badLines: Int64 = 0

    public func errorCount(): Int64 {
        var n: Int64 = 0
        for (d in this.diags) {
            if (d.level == "error") {
                n += 1
            }
        }
        return n
    }

    public func warningCount(): Int64 {
        var n: Int64 = 0
        for (d in this.diags) {
            if (d.level == "warning") {
                n += 1
            }
        }
        return n
    }
}

// ===== JSON 取值小工具（本库 get 返回 Option、kind 要显式判）=====

func strOf(v: JsonValue, key: String): String {
    match (v.kind()) {
        case JsonKind.JsObject =>
            match (v.asObject().get(key)) {
                case Some(sv) => match (sv.kind()) {
                    case JsonKind.JsString => return sv.asString().getValue()
                    case _ => return ""
                }
                case None => return ""
            }
        case _ => return ""
    }
}

func intOf(v: JsonValue, key: String): Int64 {
    match (v.kind()) {
        case JsonKind.JsObject =>
            match (v.asObject().get(key)) {
                case Some(sv) => match (sv.kind()) {
                    case JsonKind.JsInt => return sv.asInt().getValue()
                    case JsonKind.JsFloat => return Int64(sv.asFloat().getValue())
                    case _ => return 0
                }
                case None => return 0
            }
        case _ => return 0
    }
}

func boolOf(v: JsonValue, key: String): Bool {
    match (v.kind()) {
        case JsonKind.JsObject =>
            match (v.asObject().get(key)) {
                case Some(sv) => match (sv.kind()) {
                    case JsonKind.JsBool => return sv.asBool().getValue()
                    case _ => return false
                }
                case None => return false
            }
        case _ => return false
    }
}

func objOf(v: JsonValue, key: String): Option<JsonValue> {
    match (v.kind()) {
        case JsonKind.JsObject => return v.asObject().get(key)
        case _ => return None
    }
}

/** 取 `message.code.code`（形如 {"code":"E0308","explanation":null}）；没有返回 "" */
func codeOf(v: JsonValue): String {
    match (objOf(v, "code")) {
        case Some(c) => return strOf(c, "code")
        case None => return ""
    }
}

/**
 * 取主 span：优先 `is_primary == true` 的那条，否则第一条。
 * 返回 (file, line, column)；没有 span 返回 ("", 0, 0)。
 */
func primarySpanOf(v: JsonValue): (String, Int64, Int64) {
    match (objOf(v, "spans")) {
        case Some(sp) => match (sp.kind()) {
            case JsonKind.JsArray =>
                let arr = sp.asArray()
                if (arr.size() == 0) {
                    return ("", 0, 0)
                }
                var pick = arr.get(0).getOrThrow()
                for (i in 0..arr.size()) {
                    let s = arr.get(i).getOrThrow()
                    if (boolOf(s, "is_primary")) {
                        pick = s
                        break
                    }
                }
                return (strOf(pick, "file_name"), intOf(pick, "line_start"), intOf(pick, "column_start"))
            case _ => return ("", 0, 0)
        }
        case None => return ("", 0, 0)
    }
}

/** 取 `--message-format=json` 里 rendered 的前 n 行（太长会撑爆报告） */
public func firstLines(text: String, n: Int64): String {
    var taken: Int64 = 0
    var s = ""
    for (line in text.split("\n", -1)) {
        if (taken >= n) {
            break
        }
        if (taken > 0) {
            s += "\n"
        }
        s += line
        taken += 1
    }
    return s
}

/** 解析 `cargo build --message-format=json` 的整段输出（按行 JSONL） */
public func parseCargoJsonl(text: String): BuildParse {
    let res = BuildParse()
    for (raw in text.split("\n", -1)) {
        let line = raw.trimAscii()
        if (line.size == 0) {
            continue
        }
        if (!line.startsWith("{")) {
            // 非 JSON 行（stderr 被误混进来、或被截断的半行）——计数，不炸
            res.badLines += 1
            continue
        }
        var v: JsonValue
        try {
            v = JsonValue.fromStr(line)
        } catch (e: Exception) {
            // 最常见的真实现象：最后一行被缓冲截断 → 半个 JSON。容忍它。
            res.badLines += 1
            continue
        }
        let reason = strOf(v, "reason")
        if (reason == "compiler-message") {
            match (objOf(v, "message")) {
                case Some(m) =>
                    let level = strOf(m, "level")
                    let (file, ln, col) = primarySpanOf(m)
                    res.diags.add(BuildDiag(level, codeOf(m), strOf(m, "message"), file, ln, col,
                        firstLines(strOf(m, "rendered"), 12)))
                case None => res.badLines += 1
            }
        } else if (reason == "compiler-artifact") {
            match (objOf(v, "filenames")) {
                case Some(fns) => match (fns.kind()) {
                    case JsonKind.JsArray =>
                        let arr = fns.asArray()
                        for (i in 0..arr.size()) {
                            let p = arr.get(i).getOrThrow()
                            // 本库 JsonKind 不能 == 比较（AGENTS §4：改用 match）
                            match (p.kind()) {
                                case JsonKind.JsString =>
                                    let full = p.asString().getValue()
                                    // 只留文件名，避免把本机绝对路径写进报告
                                    var base = full
                                    let slash = lastSepIndex(full)
                                    if (slash >= 0) {
                                        base = full[(slash + 1)..]
                                    }
                                    // 只收"最终产物"：.so/.a/.dll/.exe。
                                    // .rlib/.rmeta 是编译中间态，一个工程几百个，写进报告纯噪音。
                                    if (!isFinalArtifact(base)) {
                                        continue
                                    }
                                    if (!res.artifacts.contains(base)) {
                                        res.artifacts.add(base)
                                    }
                                case _ => ()
                            }
                        }
                    case _ => ()
                }
                case None => ()
            }
        } else if (reason == "build-finished") {
            res.sawFinished = true
            res.finishedOk = boolOf(v, "success")
        }
    }
    return res
}

/**
 * 只把**目标平台的交付产物**算进 artifacts：`.so`（OHOS 的 .so）/ `.a`（静态库）。
 *
 * 过滤掉的三类都不是交付物：`.rlib`/`.rmeta`（编译中间态，一个工程几百个）、
 * `.d`（依赖清单）、`.dll`/`.dll.a`/`.exe`（宿主侧的 build-script 与 proc-macro 二进制）。
 * 实测未迁移工程一次构建就产出 249 条 artifact，全列出来等于把报告淹掉。
 */
func isFinalArtifact(name: String): Bool {
    // 先排除宿主侧的导入库：Windows 上 proc-macro 的产物是 `libfoo.dll.a`，它也以 .a 结尾
    if (name.endsWith(".dll.a") || name.endsWith(".dll") || name.endsWith(".exe")) {
        return false
    }
    if (name.endsWith(".so") || name.endsWith(".a")) {
        return true
    }
    return false
}

/**
 * 从**人读日志（stderr）**里数 error 行。
 *
 * 为什么必须有这个：实测（2026-10-30）未迁移工程交叉编译的首个失败是 `glib-sys` 的
 * build script —— cargo 只在 stderr 打 `error: failed to run custom build command for ...`，
 * stdout 的 JSON 流里**一条 compiler-message 都没有**。只数 JSON 会得到
 * 「errorCount=0 但编译失败」这种自相矛盾的结论。
 */
public func countErrorLines(text: String): Int64 {
    var n: Int64 = 0
    for (raw in text.split("\n", -1)) {
        let t = raw.trimAscii()
        if (t.startsWith("error:") || t.startsWith("error[")) {
            n += 1
        }
    }
    return n
}

/** 从日志里取第一条 error 行（给界面显示"为什么失败"）；没有返回 "" */
public func firstErrorLine(text: String): String {
    for (raw in text.split("\n", -1)) {
        let t = raw.trimAscii()
        if (t.startsWith("error:") || t.startsWith("error[")) {
            return t
        }
    }
    return ""
}

/** 从路径取最后一段（`/` 与 `\` 都认——Windows 上 cargo 给的是反斜杠） */
public func lastSepIndex(p: String): Int64 {
    var idx: Int64 = -1
    let bytes = p.toArray()
    for (i in 0..bytes.size) {
        if (bytes[i] == 47 || bytes[i] == 92) {
            idx = i
        }
    }
    return idx
}

/**
 * 归一化成「可喂给指纹库」的文本：把每条诊断拼成
 * `error[E0308] file.rs:2:18 mismatched types` + rendered 片段。
 * 这样 diagnose.cj 的字面量匹配能同时命中「短描述」与「源码上下文」两类 marker。
 */
public func diagsAsLogText(diags: ArrayList<BuildDiag>): String {
    var s = ""
    for (d in diags) {
        if (s.size > 0) {
            s += "\n"
        }
        var head = d.level
        if (d.code != "") {
            head += "[${d.code}]"
        }
        if (d.file != "") {
            head += " ${d.file}:${d.line}:${d.column}"
        }
        head += " ${d.message}"
        s += head
        if (d.rendered != "") {
            s += "\n${d.rendered}"
        }
    }
    return s
}

/** 诊断总数的 JSON（UI 与报告直接展示） */
public func diagsJson(diags: ArrayList<BuildDiag>, limit: Int64): JsonArray {
    var arr = JsonArray()
    var n: Int64 = 0
    for (d in diags) {
        if (n >= limit) {
            break
        }
        arr.add(d.toJson())
        n += 1
    }
    return arr
}
