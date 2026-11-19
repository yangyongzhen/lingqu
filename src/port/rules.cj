package lingqu.port

import std.collection.*

/*
 * 0.39.115：改造规则的**唯一清单**（`R2-PORT-*`）。
 *
 * 为什么需要它：17 条规则的编号原先只以 `RuleOutcome("R2-PORT-0xx")` 字面量散在 6 个文件里
 * （`port.cj` / `toolchain.cj` / `shim.cj` / `resolve.cj` / `hvigor.cj` / `main.cj`），
 * **没有任何地方能回答"一共几条、编号连不连续"**。于是文档里的条数只能靠人数：
 * README 写 16 条、`docs/AI自进化飞轮.md` 写 16 条、`docs/需求追踪.md` 写 15 条，
 * 三种说法同时存在（§4-166 同族：同一份知识写两处、只靠"记得同步"必然漂）。
 *
 * 收法：这里给出清单，`src/tests/port_rules_test.cj` 把它与**源码里的构造点**双向对齐
 * （多一条、少一条、改成动态编号都红），再与 README / 飞轮文档的编号范围对齐（文档写错也红）。
 *
 * 诚实的边界：这不保证规则的**行为**对，只保证「有几条、叫什么、编号连不连续」这一层
 * 不再各说各的。规则的 tier 是**运行期按现场降档**的（008 半配好、016 多行数组都降 guide），
 * 所以这里只登记"是否只报不写"这条静态事实，不登记档位——否则又是一份会漂的副本。
 */

/** 一条改造规则的登记项 */
public class PortRule {
    /** 编号，形如 `R2-PORT-001` */
    public var id: String
    /** 一句话标题（与实现处的文档注释同义，只用于清单展示） */
    public var title: String
    /** 只报不写：不改用户文件，产出 guide 提示让 agent 自己动手（如 017 桥双侧） */
    public var detectOnly: Bool

    public init(id: String, title: String, detectOnly: Bool) {
        this.id = id
        this.title = title
        this.detectOnly = detectOnly
    }
}

/**
 * 全部改造规则（**唯一清单**，顺序即编号顺序）。
 *
 * 加一条规则时**同时**做三件事：① 实现处构造 `RuleOutcome("R2-PORT-0NN", …)`；
 * ② 在这里登记；③ 改 README / 飞轮文档的条数与编号范围。
 * 漏任何一处，`port_rules_test.cj` 会红并把缺口贴出来。
 */
public func portRules(): ArrayList<PortRule> {
    let out = ArrayList<PortRule>()
    out.add(PortRule("R2-PORT-001", "[lib] crate-type 补 cdylib（OHOS 要产 .so）", false))
    out.add(PortRule("R2-PORT-002", "tauri 版本钉 =2.11.5 + features 补 custom-protocol / protocol-asset", false))
    out.add(PortRule("R2-PORT-003", "tauri-build 版本钉 =2.6.3", false))
    out.add(PortRule("R2-PORT-004", "wry 钉 =0.56.0 + default-features = false", false))
    out.add(PortRule("R2-PORT-005", "追加 [target.'cfg(target_env = \"ohos\")'.dependencies] 段", false))
    out.add(PortRule("R2-PORT-006", "追加 [patch.crates-io] / [patch.\"harmony-contrib\"] 段", false))
    out.add(PortRule("R2-PORT-007", "生成 rust-toolchain.toml（gnullvm + aarch64-unknown-linux-ohos）", false))
    out.add(PortRule("R2-PORT-008", "生成 .cargo/config.toml（linker + [env] C 依赖交叉编译环境 + 国内镜像）", false))
    out.add(PortRule("R2-PORT-009", "lib.rs 注入沙箱路径解析 + panic hook", false))
    out.add(PortRule("R2-PORT-010", "setup 接线（install_panic_hook）", false))
    out.add(PortRule("R2-PORT-011", "index.html 注入 localStorage polyfill", false))
    out.add(PortRule("R2-PORT-012", "confirm/prompt → 应用内对话框（guide）", false))
    out.add(PortRule("R2-PORT-013", "type=color → 应用内色板（guide）", false))
    out.add(PortRule("R2-PORT-014", "对话框资源生成（lingqu-dialog.js / .css）", false))
    out.add(PortRule("R2-PORT-015", "中性化 hvigorfile.ts 的 tauri Rust 构建钩子", false))
    out.add(PortRule("R2-PORT-016", "reqwest 关 default-tls + 补 rustls-tls（防 openssl-sys）", false))
    out.add(PortRule("R2-PORT-017", "桥两侧检测（Rust call_arkts ↔ ArkTS 分发器），只报不写", true))
    return out
}

/** 规则编号清单（顺序同 `portRules()`） */
public func portRuleIds(): Array<String> {
    let out = ArrayList<String>()
    for (r in portRules()) {
        out.add(r.id)
    }
    return out.toArray()
}

/** 规则条数 */
public func portRuleCount(): Int64 {
    return portRules().size
}

/**
 * 编号范围文本（如 `R2-PORT-001…017`）——**由清单首尾算出**，
 * 文档里引用的就是这个串，所以它不会与条数脱钩（§4-63：别让两处数字各写一份）。
 */
public func portRuleRangeTextOf(): String {
    let ids = portRuleIds()
    if (ids.size == 0) {
        return ""
    }
    let first = ids[0]
    let last = ids[ids.size - 1]
    let cut = "R2-PORT-".size
    if (last.size <= cut) {
        return first
    }
    return "${first}…${last[cut..]}"
}

/** 编号是否登记在清单里 */
public func portRuleKnownOf(id: String): Bool {
    for (r in portRules()) {
        if (r.id == id) {
            return true
        }
    }
    return false
}

/** 按编号取标题（查不到返回空串） */
public func portRuleTitleOf(id: String): String {
    for (r in portRules()) {
        if (r.id == id) {
            return r.title
        }
    }
    return ""
}

/** 只报不写的规则编号（供诊断/报告区分"改了文件"与"只给提示"） */
public func portDetectOnlyRuleIdsOf(): Array<String> {
    let out = ArrayList<String>()
    for (r in portRules()) {
        if (r.detectOnly) {
            out.add(r.id)
        }
    }
    return out.toArray()
}

/**
 * 从一行源码里取 `RuleOutcome(...)` 的规则编号；**不是构造行、或认不出的写法返回空串**。
 *
 * 认两种真实形态：字面量 `RuleOutcome("R2-PORT-012", …)` 与常量写法
 * `RuleOutcome(HVIGOR_HOOK_RULE_ID, …)`（015 就是这么写的）。
 * 返回空串**不等于**没问题——调用方（单测）要把"含 `RuleOutcome(` 却认不出"的行贴出来，
 * 否则以后有人改成动态编号，这里会静默放过（§4-160：判据不许有默认真值）。
 */
public func ruleIdFromConstructLine(line: String): String {
    var isConstruct = false
    match (line.indexOf("RuleOutcome(")) {
        case Some(_) => isConstruct = true
        case None => isConstruct = false
    }
    if (!isConstruct) {
        return ""
    }
    let marker = "R2-PORT-"
    match (line.indexOf(marker)) {
        case Some(at) =>
            let id = r2PortIdFrom(line, at)
            if (id.size > 0) {
                return id
            }
            if (line.contains("HVIGOR_HOOK_RULE_ID")) {
                return HVIGOR_HOOK_RULE_ID
            }
            return ""
        case None =>
            if (line.contains("HVIGOR_HOOK_RULE_ID")) {
                return HVIGOR_HOOK_RULE_ID
            }
            return ""
    }
}

/**
 * 从 `text` 的下标 `at`（`R2-PORT-` 起点的位置）取编号；**后面不是三位数字就返回空串**。
 *
 * 为什么要这道守卫：仓里真实存在 `R2-PORT-*` 这种裸前缀（文档注释里说"现有 R2-PORT-* 规则
 * 就能修"），只按前缀切片会取到 `*`\`` 之类的垃圾串，把判据变成自己制造的假红（§4-156 同族）。
 */
public func r2PortIdFrom(text: String, at: Int64): String {
    let marker = "R2-PORT-"
    let start = at + marker.size
    if (text.size < start + 3) {
        return ""
    }
    for (i in 0..3) {
        let c = text[start + i]
        if (c < 48 || c > 57) {
            return ""
        }
    }
    return marker + text[start..start + 3]
}

/**
 * 扫一段文本里出现的**全部**规则编号（去重、保序）——用于断言"文档/诊断里点名的规则确实存在"。
 * 非编号的裸前缀（`R2-PORT-*`）会被跳过，不算编号。
 */
public func ruleIdsInTextOf(text: String): ArrayList<String> {
    let out = ArrayList<String>()
    let marker = "R2-PORT-"
    var rest = text
    var offset = 0
    while (true) {
        var at: Int64 = -1
        match (rest.indexOf(marker)) {
            case Some(i) => at = i
            case None => at = -1
        }
        if (at < 0) {
            break
        }
        let id = r2PortIdFrom(rest, at)
        if (id.size > 0) {
            var dup = false
            for (s in out) {
                if (s == id) {
                    dup = true
                    break
                }
            }
            if (!dup) {
                out.add(id)
            }
        }
        offset = at + marker.size
        rest = rest[offset..]
    }
    return out
}

/**
 * 源码扫描结果里与清单的差集（双向）——拼成一行，失败时能直接看出缺哪条 / 多哪条。
 *
 * `scanned` 是从源码构造点扫出来的编号（去重前），`expected` 是清单。
 * 返回空串表示两边一致。
 */
public func ruleDriftTextOf(scanned: ArrayList<String>, expected: Array<String>): String {
    var gaps = ArrayList<String>()
    for (id in expected) {
        var hit = false
        for (s in scanned) {
            if (s == id) {
                hit = true
                break
            }
        }
        if (!hit) {
            gaps.add("清单有 ${id} 但源码没有构造点")
        }
    }
    var unknown = ArrayList<String>()
    for (s in scanned) {
        if (portRuleKnownOf(s)) {
            continue
        }
        var dup = false
        for (u in unknown) {
            if (u == s) {
                dup = true
                break
            }
        }
        if (dup) {
            continue
        }
        unknown.add(s)
        gaps.add("源码有 ${s} 但清单没登记")
    }
    var text = ""
    for (g in gaps) {
        if (text.size > 0) {
            text += "；"
        }
        text += g
    }
    return text
}

/**
 * 编号连续性检查：清单必须是 `001..NNN` 连号、无重复；返回空串表示没问题。
 * 空位编号会让"第 N 条"这类说法永久失真（FP-008/009 是**指纹**的空位、那是历史决定，
 * 规则这边不留空位）。
 *
 * 判据只看"第 i 项的编号是否等于 `R2-PORT-(i+1)`"，不解析数字——三位补零的字符串比较
 * 已经覆盖"缺号 / 乱序 / 非数字"，也不碰逐字节转数字那类坑（§4-116 同族）。
 */
public func ruleNumberingTextOf(ids: Array<String>): String {
    let prefix = "R2-PORT-"
    if (ids.size == 0) {
        return "清单是空的"
    }
    var seen = ArrayList<String>()
    for (i in 0..ids.size) {
        let id = ids[i]
        if (id.size != prefix.size + 3) {
            return "编号不是 `R2-PORT-` + 三位数字：${id}"
        }
        for (s in seen) {
            if (s == id) {
                return "编号重复：${id}"
            }
        }
        seen.add(id)
        let want = prefix + pad3Of(i + 1)
        if (id != want) {
            return "编号不连续：第 ${i + 1} 条应为 ${want}，实际 ${id}"
        }
    }
    return ""
}

/** 数字补足三位（`7` → `007`） */
public func pad3Of(n: Int64): String {
    if (n < 10) {
        return "00${n}"
    }
    if (n < 100) {
        return "0${n}"
    }
    return "${n}"
}
