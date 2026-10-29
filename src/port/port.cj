package lingqu.port

import std.collection.*
import stdx.encoding.json.*

/*
 * t2h:port —— 规则引擎与 Cargo.toml 改造（P4 第一刀：T4-1 / T4-2 / T4-6）
 *
 * 规则模型（T4-1）：每条规则 = id + 说明 + 「什么时候适用」+「怎么改」，
 * 改完给 RuleOutcome（applied / note / before / after）——四元组里的 verify/evidence
 * 在第一刀先由「幂等性」承担：改过的文件再跑一遍，所有规则 applied=false。
 *
 * 文本变换纪律（T4-2）：**只在行级做字面量操作，不引 regex、不重排既有行**——
 * 保注释、保顺序，改完的文件人要能直接读。判定"已改过"看目标状态（钉没钉、
 * 有没有该段），不依赖标记；追加块额外带 `# === lingqu: <rule-id> ===` 标记，
 * 让人工一眼看出哪些行是工具写的（T4-6 幂等的第一半；t2h:revert 是另一半）。
 *
 * 规则库来源（与 deps 包同源，全部实测）：
 *   habit-tree @ ohos 分支 `git diff main..ohos -- src-tauri/Cargo.toml`——
 *   6 条规则逐条对应迁移前后的 6 处改动。
 */

// ===== fork / 版本常量（与 deps 包 R2-DEPS-* 同源同值，改动要两边同步）=====
public let OHOS_TAURI_REV = "e3bf6eb168bacc7bb5c8c32d923bb8beaf77c92b"
public let OHOS_WRY_REV = "6aaf4b84b6e420015c6a14f264f1c7399f150392"
public let OHOS_TAO_REV = "813572fbe582005e2fb513458bc212842745ceab"
public let OHOS_ABILITY_REV = "295a276a699ba2352addc69b8cacb6acd3be6ab1"
public const OHOS_TAURI_URL = "https://github.com/yangyongzhen/tauri"
public let OHOS_WRY_URL = "https://github.com/tauri-apps/wry"
public let OHOS_TAO_URL = "https://github.com/tauri-apps/tao"
public let OHOS_ABILITY_URL = "https://github.com/yangyongzhen/openharmony-ability"
public let OHOS_ABILITY_UPSTREAM = "https://github.com/harmony-contrib/openharmony-ability.git"

/** 动作三档（T4-8）：auto=规则机械完成；guide=给方案留人工（计数进 A3 口径） */
public let T_AUTO = "auto"
public let T_GUIDE = "guide"

/** 规则执行结果（evidence 载体：before/after 给 UI 与报告直接展示） */
public class RuleOutcome {
    public var id: String
    public var applied: Bool
    public var note: String
    public var before: String
    public var after: String
    public var tier: String

    public init(id: String, applied: Bool, note: String, before: String, after: String) {
        this.id = id
        this.applied = applied
        this.note = note
        this.before = before
        this.after = after
        this.tier = T_AUTO
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("id", JsonString(this.id))
        o.put("applied", JsonBool(this.applied))
        o.put("note", JsonString(this.note))
        o.put("before", JsonString(this.before))
        o.put("after", JsonString(this.after))
        o.put("tier", JsonString(this.tier))
        return o
    }
}

/** 一轮规则执行的汇总（afterText 是改完的全文；dryRun 时不落盘） */
public class PortResult {
    public var outcomes: ArrayList<RuleOutcome> = ArrayList<RuleOutcome>()
    public var afterText: String = ""

    public func appliedCount(): Int64 {
        var n: Int64 = 0
        for (o in this.outcomes) {
            if (o.applied) {
                n += 1
            }
        }
        return n
    }

    /** T4-8 人工介入口径：本轮回合里 guide 档（留人工决策）的条数 */
    public func humanCount(): Int64 {
        var n: Int64 = 0
        for (o in this.outcomes) {
            if (o.tier == T_GUIDE && o.applied) {
                n += 1
            }
        }
        return n
    }

    /** auto 档：规则机械完成的条数 */
    public func autoCount(): Int64 {
        var n: Int64 = 0
        for (o in this.outcomes) {
            if (o.tier != T_GUIDE && o.applied) {
                n += 1
            }
        }
        return n
    }

    public func outcomesJson(): JsonArray {
        var arr = JsonArray()
        for (o in this.outcomes) {
            arr.add(o.toJson())
        }
        return arr
    }

    public func countersJson(): JsonObject {
        var o = JsonObject()
        o.put("auto", JsonInt(this.autoCount()))
        o.put("guide", JsonInt(this.humanCount()))
        return o
    }
}

// ===== 行级工具（不引 regex 的字面量操作）=====

public func indexOfOr(text: String, ch: String): Int64 {
    match (text.indexOf(ch)) {
        case Some(i) => return i
        case None => return -1
    }
}

/** 行首空白（本库没有 trimStartAscii——手数字符；TOML 行缩进只有空格/制表） */
public func leadingIndentOf(line: String): String {
    var n: Int64 = 0
    let bytes = line.toArray()
    for (b in bytes) {
        if (b == 32 || b == 9) {
            n += 1
        } else {
            break
        }
    }
    if (n == 0) {
        return ""
    }
    return line[0..n]
}

/** 取 `key = { ... }` 或 `key = "..."` 行的 key；非赋值行返回 "" */
public func keyOf(line: String): String {
    let eq = indexOfOr(line, "=")
    if (eq <= 0) {
        return ""
    }
    return line[0..eq].trimAscii()
}

/** 取行内 `features = [` ... `]` 的内容（不含括号）；没有返回 "" */
public func featuresInnerOf(line: String): String {
    let marker = "features"
    let fi = indexOfOr(line, marker)
    if (fi < 0) {
        return ""
    }
    let bo = indexOfOr(line[fi..], "[")
    if (bo < 0) {
        return ""
    }
    let openAbs = fi + bo
    let rest = line[(openAbs + 1)..]
    let bc = indexOfOr(rest, "]")
    if (bc < 0) {
        return ""
    }
    return rest[0..bc]
}

/** 段定位：返回 header 行下标；没有返回 -1 */
func sectionIndex(lines: ArrayList<String>, headerPrefix: String): Int64 {
    for (i in 0..lines.size) {
        if (lines[i].trimAscii().startsWith(headerPrefix)) {
            return i
        }
    }
    return -1
}

/** 段结束行（下一个段头）下标；段到文件尾返回 lines.size */
func sectionEnd(lines: ArrayList<String>, headerIdx: Int64): Int64 {
    var i = headerIdx + 1
    while (i < lines.size) {
        if (lines[i].trimAscii().startsWith("[")) {
            return i
        }
        i += 1
    }
    return lines.size
}

// ===== 六条 Cargo.toml 规则（对应 habit-tree main→ohos 的六处 diff）=====

/**
 * R2-PORT-001：[lib] crate-type 补 cdylib（OHOS 产出 .so 必需）。
 * 已有 crate-type 且含 cdylib → 跳过；有 crate-type 不含 → 原地补；
 * 没有 crate-type 行 → 在 [lib] 下插入。
 */
func ruleCdylib(lines: ArrayList<String>, out: RuleOutcome): ArrayList<String> {
    let libIdx = sectionIndex(lines, "[lib]")
    if (libIdx < 0) {
        out.note = "无 [lib] 段（单 bin 工程？）——跳过"
        return lines
    }
    let end = sectionEnd(lines, libIdx)
    var i = libIdx + 1
    while (i < end) {
        if (keyOf(lines[i]) == "crate-type") {
            if (lines[i].contains("cdylib")) {
                out.note = "crate-type 已含 cdylib——跳过"
                return lines
            }
            // crate-type 行形如 crate-type = ["a", "b"]——规范化为桌面+OHOS 双用形态
            // （与 habit-tree 真实 diff 一致：["rlib"] → ["staticlib", "cdylib", "rlib"]）
            let bo = indexOfOr(lines[i], "[")
            if (bo < 0) {
                out.note = "crate-type 行格式不认识——跳过（留人工）"
                return lines
            }
            let newline = lines[i][0..bo] + "[\"staticlib\", \"cdylib\", \"rlib\"]"
            out.applied = true
            out.before = lines[i]
            out.after = newline
            out.note = "crate-type 原地补 cdylib"
            lines[i] = newline
            return lines
        }
        i += 1
    }
    // 段里没有 crate-type 行：在 [lib] 头后插入
    let block = ["# === lingqu: R2-PORT-001 ===", "crate-type = [\"staticlib\", \"cdylib\", \"rlib\"]"]
    out.applied = true
    out.before = ""
    out.after = joinLines(block)
    out.note = "[lib] 段缺 crate-type，插入桌面+OHOS 双用形态"
    return insertLines(lines, libIdx + 1, block)
}

/**
 * R2-PORT-002：tauri 版本钉 =2.11.5 + features 补 custom-protocol / protocol-asset。
 * 只认 [dependencies] 段里 `tauri = ` 开头的行；features 原样保留并合并。
 */
func ruleTauriPin(lines: ArrayList<String>, out: RuleOutcome): ArrayList<String> {
    let depIdx = sectionIndex(lines, "[dependencies]")
    if (depIdx < 0) {
        out.note = "无 [dependencies] 段——跳过"
        return lines
    }
    let end = sectionEnd(lines, depIdx)
    var i = depIdx + 1
    while (i < end) {
        let t = lines[i].trimAscii()
        if (t.startsWith("tauri ") || t.startsWith("tauri =")) {
            if (t.contains("\"=2.11.5\"")) {
                out.note = "tauri 已钉 =2.11.5——跳过"
                return lines
            }
            // 拆 features
            var feats = ""
            let fi = indexOfOr(t, "features")
            if (fi >= 0) {
                feats = featuresInnerOf(t)
            }
            // 合并必需 features（已有就不重复）
            var merged = ArrayList<String>()
            if (feats.trimAscii() != "") {
                for (seg in feats.split(",", -1)) {
                    let s = seg.trimAscii().replace("\"", "")
                    if (s != "" && !merged.contains(s)) {
                        merged.add(s)
                    }
                }
            }
            if (!merged.contains("custom-protocol")) {
                merged.add("custom-protocol")
            }
            if (!merged.contains("protocol-asset")) {
                merged.add("protocol-asset")
            }
            var farr = ArrayList<String>()
            for (f in merged) {
                farr.add("\"${f}\"")
            }
            var joined = ""
            for (j in 0..farr.size) {
                if (j > 0) {
                    joined += ", "
                }
                joined += farr[j]
            }
            let indent = leadingIndentOf(lines[i])
            let newline = "${indent}tauri = { version = \"=2.11.5\", features = [${joined}] }"
            out.applied = true
            out.before = lines[i]
            out.after = "${indent}# 版本钉 =2.11.5：patch 按精确版本替换（^2.11 会绕过 patch，见 lingqu R2-PORT-002）\n${newline}"
            out.note = "tauri 钉 =2.11.5 + features 合并 custom-protocol/protocol-asset"
            // 行模型纪律：注释与代码各占一行元素，绝不往单个元素里塞 \n
            // （否则后续规则按行扫 "tauri" 时命中的是注释行，误判成非 Tauri 工程）
            return spliceLines(lines, i, 1, [
                "${indent}# 版本钉 =2.11.5：patch 按精确版本替换（^2.11 会绕过 patch，见 lingqu R2-PORT-002）",
                newline
            ])
        }
        i += 1
    }
    out.note = "[dependencies] 里没有 tauri——跳过（非 Tauri 工程？）"
    return lines
}

/**
 * R2-PORT-003：tauri-build 版本钉 =2.6.3（[build-dependencies] 段）。
 */
func ruleTauriBuildPin(lines: ArrayList<String>, out: RuleOutcome): ArrayList<String> {
    let idx = sectionIndex(lines, "[build-dependencies]")
    if (idx < 0) {
        out.note = "无 [build-dependencies] 段——跳过"
        return lines
    }
    let end = sectionEnd(lines, idx)
    var i = idx + 1
    while (i < end) {
        let t = lines[i].trimAscii()
        if (t.startsWith("tauri-build")) {
            if (t.contains("\"=2.6.3\"")) {
                out.note = "tauri-build 已钉 =2.6.3——跳过"
                return lines
            }
            let eq = indexOfOr(t, "\"")
            let eq2 = indexOfOr(t[eq + 1..], "\"")
            if (eq < 0 || eq2 < 0) {
                out.note = "tauri-build 行格式不认识——跳过（留人工）"
                return lines
            }
            let open = eq + 1
            let newline = t[0..open] + "=2.6.3" + t[(open + eq2)..]
            out.applied = true
            out.before = lines[i]
            out.after = newline
            out.note = "tauri-build 钉 =2.6.3"
            lines[i] = newline
            return lines
        }
        i += 1
    }
    out.note = "[build-dependencies] 里没有 tauri-build——跳过"
    return lines
}

/**
 * R2-PORT-004：wry 钉 =0.56.0 + default-features = false（防 registry 高版本绕过 patch）。
 * 有 wry 行 → 规范化改写；没有 → 在 [dependencies] 段尾追加。
 */
func ruleWryPin(lines: ArrayList<String>, out: RuleOutcome): ArrayList<String> {
    let canonical = "wry = { version = \"=0.56.0\", default-features = false }"
    let depIdx = sectionIndex(lines, "[dependencies]")
    if (depIdx < 0) {
        out.note = "无 [dependencies] 段——跳过"
        return lines
    }
    // 非 Tauri 工程不追加 wry（wry 钉版只在 tauri 存在时有意义）
    var hasTauri = false
    let depEnd = sectionEnd(lines, depIdx)
    var di = depIdx + 1
    while (di < depEnd) {
        let dt = lines[di].trimAscii()
        if (dt.startsWith("tauri ") || dt.startsWith("tauri =")) {
            hasTauri = true
            break
        }
        di += 1
    }
    if (!hasTauri) {
        out.note = "无 tauri 依赖（非 Tauri 工程）——跳过"
        return lines
    }
    let end = sectionEnd(lines, depIdx)
    var i = depIdx + 1
    while (i < end) {
        let t = lines[i].trimAscii()
        if (t.startsWith("wry ") || t.startsWith("wry =")) {
            if (t.contains("\"=0.56.0\"") && t.contains("default-features = false")) {
                out.note = "wry 已钉 =0.56.0 且 default-features=false——跳过"
                return lines
            }
            out.applied = true
            out.before = lines[i]
            out.after = canonical
            out.note = "wry 钉 =0.56.0 + default-features=false（防 ^ 绕过 patch）"
            lines[i] = canonical
            return lines
        }
        i += 1
    }
    out.applied = true
    out.before = ""
    out.after = "# === lingqu: R2-PORT-004 ===\n${canonical}"
    out.note = "[dependencies] 无 wry，追加钉版行"
    return insertLines(lines, end, ["# === lingqu: R2-PORT-004 ===", canonical])
}

/**
 * R2-PORT-005：追加 [target.'cfg(target_env = "ohos")'.dependencies] 段
 * （napi 桥接：mobile_entry_point 宏展开必需）。
 */
func ruleOhosTargetDeps(lines: ArrayList<String>, out: RuleOutcome): ArrayList<String> {
    for (i in 0..lines.size) {
        if (lines[i].contains("target_env") && lines[i].contains("ohos") && lines[i].trimAscii().startsWith("[target")) {
            out.note = "已有 OHOS target 段——跳过"
            return lines
        }
    }
    let block = [
        "# === lingqu: R2-PORT-005 ===",
        "# OHOS：napi 桥接（mobile_entry_point 宏展开必需，缺了报 cannot find crate napi_ohos）",
        "[target.'cfg(target_env = \"ohos\")'.dependencies]",
        "napi-derive-ohos = \"1.1\"",
        "napi-ohos = { version = \"1.1\", features = [\"napi8\"] }",
        "openharmony-ability = { git = \"${OHOS_ABILITY_URL}\", rev = \"${OHOS_ABILITY_REV}\" }"
    ]
    // 插到 [profile 段之前（保持 profile 在文件尾的习惯），否则追加到文件尾
    var at = lines.size
    for (i in 0..lines.size) {
        if (lines[i].trimAscii().startsWith("[profile")) {
            at = i
            break
        }
    }
    out.applied = true
    out.before = ""
    out.after = joinLines(block)
    out.note = "追加 OHOS target 段（napi 桥接 + ArkTS 桥）"
    return insertLines(lines, at, block)
}

/**
 * R2-PORT-006：追加 [patch.crates-io] 与 [patch."harmony-contrib..."] 段
 * （fork 替换：用 git URL + rev 固定，clone 即用、可复现）。
 */
func rulePatchSection(lines: ArrayList<String>, out: RuleOutcome): ArrayList<String> {
    let existing = sectionIndex(lines, "[patch")
    if (existing >= 0) {
        out.note = "已有 [patch 段——跳过（已迁移或人工已配）"
        return lines
    }
    let block = [
        "# === lingqu: R2-PORT-006 ===",
        "# ---- OHOS fork 替换（yangyongzhen/tauri feat/open-harmony）----",
        "# 用 [patch] 而非 path 依赖：避免 links=\"Tauri\" 冲突；rev 固定保证可复现。",
        "# wry/tao 必须一并 patch（fork 的 workspace patch 不跨工程继承）。",
        "[patch.crates-io]",
        "tauri = { git = \"${OHOS_TAURI_URL}\", rev = \"${OHOS_TAURI_REV}\" }",
        "tauri-build = { git = \"${OHOS_TAURI_URL}\", rev = \"${OHOS_TAURI_REV}\" }",
        "tauri-macros = { git = \"${OHOS_TAURI_URL}\", rev = \"${OHOS_TAURI_REV}\" }",
        "tauri-codegen = { git = \"${OHOS_TAURI_URL}\", rev = \"${OHOS_TAURI_REV}\" }",
        "tauri-utils = { git = \"${OHOS_TAURI_URL}\", rev = \"${OHOS_TAURI_REV}\" }",
        "tauri-runtime = { git = \"${OHOS_TAURI_URL}\", rev = \"${OHOS_TAURI_REV}\" }",
        "tauri-runtime-wry = { git = \"${OHOS_TAURI_URL}\", rev = \"${OHOS_TAURI_REV}\" }",
        "wry = { git = \"${OHOS_WRY_URL}\", rev = \"${OHOS_WRY_REV}\" }",
        "tao = { git = \"${OHOS_TAO_URL}\", rev = \"${OHOS_TAO_REV}\" }",
        "",
        "# openharmony-ability main 已重构（webview 拆为独立 crate），",
        "# wry/tauri 的 OHOS 分支仍要求 0.3.0 webview feature → patch 到 295a276",
        "[patch.\"${OHOS_ABILITY_UPSTREAM}\"]",
        "openharmony-ability = { git = \"${OHOS_ABILITY_URL}\", rev = \"${OHOS_ABILITY_REV}\" }",
        "openharmony-ability-derive = { git = \"${OHOS_ABILITY_URL}\", rev = \"${OHOS_ABILITY_REV}\" }"
    ]
    out.applied = true
    out.before = ""
    out.after = joinLines(block)
    out.note = "追加 [patch.crates-io] + ability patch（fork 替换）"
    if (lines.size > 0 && lines[lines.size - 1].trimAscii() != "") {
        lines.add("")
    }
    for (l in block) {
        lines.add(l)
    }
    return lines
}

func joinLines(block: Array<String>): String {
    var s = ""
    for (i in 0..block.size) {
        if (i > 0) {
            s += "\n"
        }
        s += block[i]
    }
    return s
}

/**
 * 在下标 at 处插入多行（本库 ArrayList 没有 insert，只有 add 追加——
 * 用重建实现；行数量级是 Cargo.toml 几十行，重建无性能顾虑）。
 */
func insertLines(lines: ArrayList<String>, at: Int64, block: Array<String>): ArrayList<String> {
    return spliceLines(lines, at, 0, block)
}

/** 把 at 起 count 行替换为 block（行模型纪律：一行一个元素，绝不往元素里塞 \n） */
func spliceLines(lines: ArrayList<String>, at: Int64, count: Int64, block: Array<String>): ArrayList<String> {
    let out = ArrayList<String>()
    var inserted = false
    var i: Int64 = 0
    while (i < lines.size) {
        if (i == at && !inserted) {
            for (l in block) {
                out.add(l)
            }
            inserted = true
            i += count
            continue
        }
        out.add(lines[i])
        i += 1
    }
    if (!inserted) {
        for (l in block) {
            out.add(l)
        }
    }
    return out
}

// ===== 规则执行器（T4-1 的"跑"半边）=====

/** 对 Cargo.toml 文本按序执行六条规则；幂等——改过的文件再跑 applied 全 false */
public func applyCargoTomlRules(text: String): PortResult {
    var lines = ArrayList<String>()
    for (l in text.split("\n", -1)) {
        lines.add(l)
    }
    let res = PortResult()

    // 001 cdylib
    var o1 = RuleOutcome("R2-PORT-001", false, "", "", "")
    lines = ruleCdylib(lines, o1)
    res.outcomes.add(o1)

    // 002 tauri 钉版
    var o2 = RuleOutcome("R2-PORT-002", false, "", "", "")
    lines = ruleTauriPin(lines, o2)
    res.outcomes.add(o2)

    // 003 tauri-build 钉版
    var o3 = RuleOutcome("R2-PORT-003", false, "", "", "")
    lines = ruleTauriBuildPin(lines, o3)
    res.outcomes.add(o3)

    // 004 wry 钉版
    var o4 = RuleOutcome("R2-PORT-004", false, "", "", "")
    lines = ruleWryPin(lines, o4)
    res.outcomes.add(o4)

    // 005 OHOS target 段
    var o5 = RuleOutcome("R2-PORT-005", false, "", "", "")
    lines = ruleOhosTargetDeps(lines, o5)
    res.outcomes.add(o5)

    // 006 patch 段
    var o6 = RuleOutcome("R2-PORT-006", false, "", "", "")
    lines = rulePatchSection(lines, o6)
    res.outcomes.add(o6)

    // 拼回全文（保留原换行风格：统一 \n；以换行结尾的输入末尾也补回换行）
    var sb = ""
    for (i in 0..lines.size) {
        if (i > 0) {
            sb += "\n"
        }
        sb += lines[i]
    }
    if (text.endsWith("\n") && !sb.endsWith("\n")) {
        sb += "\n"
    }
    res.afterText = sb
    return res
}

/** 幂等自检（T4-6）：对结果再跑一遍，返回是否已稳定（applied 全 false） */
public func isIdempotent(res: PortResult): Bool {
    let second = applyCargoTomlRules(res.afterText)
    return second.appliedCount() == 0
}
