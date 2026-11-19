package lingqu.verify

import std.collection.*
import stdx.encoding.json.*

/*
 * P6 验证与报告（T6-1 ~ T6-4）的纯函数层。
 *
 * 分工（与 port / compiler 两层一致）：
 *   · 本文件：**功能清单生成 + 可用率计算 + 报告渲染**，全是纯函数，可单测；
 *   · 命令层（`t2h:verify`，`src/main.cj`）：跑 hdc 采证据（截图 / hilog / faultlog）、
 *     读前面几轮落档的 scan / build / hap / deploy 结果，喂给本层，最后落盘。
 *
 * 三条口径先钉死，避免"数字好看但站不住"：
 *   ① **分母 = 移植验收项**（0.39.103 改，D-020）：装得上 / 起得来 / 渲染得出 / 前端资源进包 /
 *      IPC 与事件通道 / 平台能力有落地等价物。**原应用自己的业务功能不进分母**——
 *      逐条点永远点不完，缺网/缺配置也必然过不了，那不属移植职责。
 *      早先（0.39.89~0.39.102）曾把扫描到的每条 IPC 命令都当"核心功能"塞进分母，
 *      结果 note-gen-2 算出 4/16 = 25%，分母还挂着 169 项未测——**分母做不完，≥80% 就永远悬着**。
 *   ② **未测记未测**：`unknown` **不进分母**，但必须显式计数（`notVerified`）并写进报告与界面。
 *      少了这个数，"只测了 2 项、通过 2 项 = 100%"就会被读成"全都可用"。
 *   ③ **平台限制要拿"降级落地"换**：一处平台 API 只有在**工程里真的写了替代实现**时，
 *      才允许记 `limit` 并剔出分母；否则它的功能判 `fail`
 *      （现场：OHOS 分支 `return None`，前端 `if (p)` 静默吞掉 ⇒ 按钮点了没反应）。
 *   另外 ④ **证据逐项挂**：每条清单项都有自己的证据列表，不搞一个总结数字糊过去。
 */

/** 一条功能清单项 */
public class CheckItem {
    /** 稳定 id（报告与跨轮次对比用，别随文案改） */
    public var id: String = ""
    public var title: String = ""
    /**
     * 条目类别：`gate`（装配步骤：编得过 / 装配过 / 起得来）或 `feature`（功能项明细）。
     * 可用率的分母只认 `feature`——这是 0.39.89 的口径修正点。
     */
    public var kind: String = "gate"
    /**
     * 责任分类（D-020，0.39.103）：**A4 的分母只认 `transplant`**。
     *
     * - `transplant`：移植该负责的事——装得上 / 起得来 / 渲染得出 / 前端资源进包 / IPC 通道通 /
     *   平台 API 有落地的等价实现 / 插件与事件登记清楚；
     * - `business`：**原应用自己的业务功能**（`feat:<IPC 命令>`，如 start_download、ai_json_request）。
     *   这类逐条点永远点不完，缺网/缺配置也必然过不了，**不属移植职责**，只统计条数；
     * - `smoke`：业务功能的真机冒烟点按（`feat:probe:*`），单列，**不计入移植通过率**。
     *
     * 为什么必须分开：把业务功能塞进分母，等于替原应用的 bug 背锅，而且分母永远做不完
     * （见 D-020 与 §4-63 第三态）。
     */
    public var category: String = "transplant"
    /** 判定：pass / fail / limit（平台限制）/ unknown（证据没采到） */
    public var verdict: String = ""
    /** 挂在这条上的证据（截图 / hilog / 落档文件 / 命令返回） */
    public var evidence: ArrayList<String> = ArrayList<String>()
    /** 给人看的补充说明（失败原因 / 限制原因） */
    public var note: String = ""

    public init(id: String, title: String) {
        this.id = id
        this.title = title
    }

    public func isPass(): Bool {
        return this.verdict == "pass"
    }

    public func isLimit(): Bool {
        return this.verdict == "limit"
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("id", JsonString(this.id))
        o.put("title", JsonString(this.title))
        // D-020：classified 必须落档——界面要靠它把"移植验收项 / 业务功能 / 冒烟"分开显示，
        // 缺了这个字段，回读落档就只能靠 id 前缀猜，迟早猜错（§4-60 的同类坑：字段没写=静默丢证据）
        o.put("kind", JsonString(this.kind))
        o.put("category", JsonString(this.category))
        o.put("verdict", JsonString(this.verdict))
        o.put("note", JsonString(this.note))
        var e = JsonArray()
        for (x in this.evidence) {
            e.add(JsonString(x))
        }
        o.put("evidence", e)
        return o
    }
}

/**
 * 生成清单的输入：全部来自前面几轮的落档（scan / build / hap / deploy / 真机采集）。
 *
 * 为什么不直接吃扫描器的类型：这一层要能在**没有工程**时也跑（只做真机侧报告），
 * 松耦合的入参让"清单规则"能被单测逐条覆盖，而不必搭一整套扫描 fixture。
 */
public class ChecklistInput {
    /** 扫描结果：命令 / 事件 / 插件 / 前端文件 / 平台 API 的条数（0 = 没扫过） */
    public var commandCount: Int64 = 0
    public var eventCount: Int64 = 0
    public var pluginCount: Int64 = 0
    public var frontendCount: Int64 = 0
    public var platformCount: Int64 = 0
    /** 自研命令里"不可机械迁移"的比例线索：扫描给出的 blockers（阻塞项）条数 */
    public var blockerCount: Int64 = 0
    /** 交叉编译 + 前端指纹闸是否通过（`t2h:build` 落档） */
    public var buildOk: Bool = false
    public var assetOk: Bool = false
    /** 这一步**跑过没有**（落档存在）。缺了它，"跑了没过"会被报成"没跑过"（AGENTS §4-63） */
    public var hasBuild: Bool = false
    /** HAP 装配闸是否通过（`t2h:hap` 落档） */
    public var hapOk: Bool = false
    public var hasHap: Bool = false
    /** HAP 装配的子判据：编出来了吗 / 签名了吗 / 闸门第一条失败说什么 */
    public var hapBuilt: Bool = false
    public var hapSigned: Bool = false
    public var hapFirstFailure: String = ""
    /** 真机部署：装上了 / 起来了 / hilog 无崩溃（`t2h:deploy` 落档） */
    public var installed: Bool = false
    public var started: Bool = false
    public var hilogHealthy: Bool = false
    /** 证据采集结果：截图张数、faultlog 里的崩溃记录数 */
    public var screenshotCount: Int64 = 0
    public var crashCount: Int64 = 0
    /**
     * 核心功能清单（A4 的分母）：来自 scan 的 `items.commands`，一条命令一个功能。
     * 为空时说明没扫过——这时只能退回旧的聚合口径，并且**必须在报告里说清"没覆盖功能"**。
     */
    public var features: ArrayList<FeatureInput> = ArrayList<FeatureInput>()
    /** 平台 API 明细（scan 的 `items.platform`）：判"降级方案落地了吗"用 */
    public var platformItems: ArrayList<PlatformInput> = ArrayList<PlatformInput>()
}

/**
 * 一条**原应用的业务功能**（D-020：**不进 A4 分母**，只统计条数、供真机冒烟选点）。
 * 来源：scan 落档的 `items.commands`——每条 IPC 命令就是一个业务功能。
 *
 * 为什么不能拿业务功能当分母（0.39.103 用户指正）：每个应用上百条命令逐条点，永远验不完；
 * 没配网络、没配密钥、没登录，这些功能本来就跑不起来——**那不说明移植坏了**。
 * 分母只认移植验收项（装得上/起得来/渲染/通道/平台能力），见 D-020。
 */
public class FeatureInput {
    /** IPC 命令名（`pick_folder` / `start_download` …），也是清单项 id 的后半段 */
    public var commandName: String = ""
    /** 给人看的中文名；空则回落到命令名 */
    public var title: String = ""
    /** 该功能命中的平台 API（如 `rfd::FileDialog`）；空 = 没命中，纯纯的自研逻辑 */
    public var degradedApi: String = ""
    /** 降级方案是否**在工程里真的落地了**（判据：OHOS 分支不是只 `return None`） */
    public var fallbackLanded: Bool = false
    /** 人工实测结论：`pass` / `fail` / 空 = 没测过（人的实测永远优先于推断） */
    public var humanVerdict: String = ""
    /**
     * **真机实测**结论：`pass` / `fail` / 空 = 没实测过。
     *
     * 来源是 `<工程>/.lingqu/verify/<工程>.probe.json`（我们自己在真机上点按取证后落的档）。
     * 和 `humanVerdict` 分开存是**故意的**：A3 数的是"人被打扰几次"，我们自己的探针不该虚增它，
     * 但它的证据强度高于任何静态推断（点了有没有响应是事实，代码看起来像什么只是推断）。
     */
    public var probeVerdict: String = ""
    /** 实测时看到了什么（进条目 note，别只留一个 pass/fail） */
    public var probeNote: String = ""
    /** 实测证据路径（截图 / 版面树 dump），落进条目的 evidence 供复核 */
    public var probeEvidence: ArrayList<String> = ArrayList<String>()
    /** 桥用的 ArkTS 分发 cmd 名（空 = 这条命令不走桥） */
    public var bridgeCmd: String = ""
    /**
     * 桥**只写了一半**的说明（空 = 没问题 / 不走桥）。
     *
     * 这是"Rust 调了 `call_arkts("x")`，但 ArkTS 没有 `case "x"`"那种情形：静态看像落地了、
     * `cargo build` 也 exit=0，真机点了却毫无反应（`cargo` 不审 ArkTS）。§4-162。
     */
    public var bridgeMissing: String = ""

    public init(commandName: String, title: String) {
        this.commandName = commandName
        this.title = title
    }
}

/** 一处平台 API 的降级落地情况（scan 的 `items.platform`，一处一条） */
public class PlatformInput {
    public var name: String = ""
    /** 扫描判定：降级 / 改造 / 不适用 */
    public var verdict: String = ""
    /** 降级方案落地了吗——**只有落地了才允许把这一处记成"平台限制"** */
    public var fallbackLanded: Bool = false
    /** 为什么这么判（落档里要能自证，别只留一个布尔） */
    public var note: String = ""
    /**
     * 第一处命中位置（`src-tauri/src/lib.rs:157`）。
     *
     * 用途只有一个：**没有任何 IPC 命令命中它**时（`app_data_dir` 常出现在 setup/辅助函数里），
     * 靠这行去源码里找"它所在的那个函数在鸿蒙侧有没有落地实现"。没有它就只能判"无法判定"，
     * 而"无法判定"会被算成"降级没落地"——habit-tree 的 `app_data_dir` 就是这么被误判的（0.39.107）。
     */
    public var site: String = ""

    public init(name: String) {
        this.name = name
    }
}

/**
 * 判一段 OHOS 分支实现是不是**等于没实现**（只 `return None` / `todo!()` / 空）。
 *
 * 这是"降级方案落地了吗"的判据本体。现场（m3u8dl-tauri 的 `commands.rs`）：
 *
 * ```
 * #[cfg(all(target_os = "linux", target_env = "ohos"))]
 * pub async fn pick_m3u8_file() -> Option<String> { None }     // ← 等于没实现
 * ```
 *
 * 前端 `if (p) { ... }` 拿到 `None` 就静默什么都不做 ⇒ 用户点按钮没反应、也不报错。
 * 纯函数，便于单测（不碰文件系统）。
 */
public func ohosStubOnly(body: String): Bool {
    // 只看"有没有真的写点东西"：注释、空白、分号、花括号都不算实现
    let code = compactCode(body)
    if (code.size == 0) {
        return true
    }
    // 直接占位宏：写了等于没写
    if (code.contains("todo!(") || code.contains("unimplemented!(") || code.contains("unreachable!(")) {
        return true
    }
    // 常量返回 None：现场写法有 `None` / `return None;` / `Ok(None)`（返回 Result 的命令）几种
    if (unwrapToValue(code) == "None") {
        return true
    }
    return false
}

/** 剥掉 `return` 与 `Ok(...)` / `Some(...)` / `Err(...)` 外壳，取到最里层的值表达式 */
func unwrapToValue(code: String): String {
    var s = code
    while (s.startsWith("return")) {
        s = s[6..s.size]
    }
    var guard = 0
    while (guard < 4) {
        guard += 1
        if (s.endsWith("()") && (s.startsWith("None(") || s.startsWith("Some("))) {
            // None() / Some() 这种"带空括号的常量返回"
            s = s[0..s.size - 2]
            continue
        }
        let wrapped = s.startsWith("Ok(") || s.startsWith("Some(") || s.startsWith("Err(")
        if (wrapped && s.endsWith(")")) {
            s = s[3..s.size - 1]
            continue
        }
        if (s.startsWith("return")) {
            s = s[6..s.size]
            continue
        }
        break
    }
    return s
}

/** 去掉空白、分号与花括号、以及 `//` 行注释（判"空壳实现"前的归一化） */func compactCode(s: String): String {
    let out = ArrayList<Byte>()
    var inLineComment = false
    var i = 0
    while (i < s.size) {
        let c = s[i]
        if (inLineComment) {
            // 换行结束行注释；换行本身也丢掉（它不携带语义）
            if (c == 10) {
                inLineComment = false
            }
            i += 1
            continue
        }
        if (c == 47 && i + 1 < s.size && s[i + 1] == 47) {
            inLineComment = true
            i += 2
            continue
        }
        if (c == 32 || c == 9 || c == 13 || c == 10 || c == 59 || c == 123 || c == 125) {
            i += 1
            continue
        }
        out.add(c)
        i += 1
    }
    return asciiSafeOf(out.toArray())
}

/**
 * 宽容解码（0.39.122）：样本源码可能是 **GBK / 非 UTF-8**（中文注释极常见），
 * 逐字节硬解会抛 `IllegalArgumentException: Invalid utf8 byte sequence`——
 * 2026-11-19 EcoPaste 真机 `verify` 就死在这里（§4-113 / §4-116 同族）。
 *
 * 本函数只用来"看代码形状"（查空壳实现），所以**只保留 ASCII、非 ASCII 换 `?`**：
 * 丢掉中文不影响判据，但保住"不抛"这条底线。
 */
func asciiSafeOf(bytes: Array<Byte>): String {
    let out = ArrayList<Byte>()
    for (b in bytes) {
        if (b < 128) {
            out.add(b)
        } else {
            out.add(UInt8(63))
        }
    }
    return String.fromUtf8(out.toArray())
}

/** 从 `from` 起找 `sub` 的字节位置（找不到给 -1；不依赖 String.indexOf 的参数形态） */
func findFrom(s: String, sub: String, from: Int64): Int64 {
    let n = s.size
    let m = sub.size
    if (m == 0 || m > n) {
        return -1
    }
    var i = if (from < 0) { 0 } else { from }
    while (i + m <= n) {
        var k = 0
        while (k < m && s[i + k] == sub[k]) {
            k += 1
        }
        if (k == m) {
            return i
        }
        i += 1
    }
    return -1
}

/**
 * 取 `openBrace` 处花括号包裹的**函数体文本**（不含花括号本身）。
 *
 * 只跳字符串字面量，不认 `'` 字符字面量——Rust 里 `&'static str` 的撇号会被当成"字符常量开头"
 * 从而把后面一大段吞掉，反而更糟。本项目判据只需体里"有没有真实现"，不对花括号做严格语法解析。
 */
func bodyRangeOf(s: String, openBrace: Int64): (Int64, Int64) {
    var depth: Int64 = 0
    var i = openBrace
    let start = openBrace + 1
    var inStr = false
    while (i < s.size) {
        let c = s[i]
        if (inStr) {
            if (c == 92) {
                i += 2
                continue
            }
            if (c == 34) {
                inStr = false
            }
            i += 1
            continue
        }
        if (c == 34) {
            inStr = true
            i += 1
            continue
        }
        if (c == 123) {
            depth += 1
        }
        if (c == 125) {
            depth -= 1
            if (depth == 0) {
                return (start, i)
            }
        }
        i += 1
    }
    return (start, s.size)
}

/** `fnName` 前最近的一条 `#[cfg(...)]` 属性文本（没有给 ""） */
func lastCfgAttrOf(attr: String): String {
    var best: Int64 = -1
    var i = findFrom(attr, "#[cfg(", 0)
    while (i >= 0) {
        best = i
        i = findFrom(attr, "#[cfg(", i + 1)
    }
    if (best < 0) {
        return ""
    }
    return attr[best..]
}

/** 一条实现：(是不是鸿蒙分支, 函数体文本) */
public class FnImpl {
    public var isOhos: Bool = false
    public var body: String = ""

    public init() {}
}

/**
 * 把源码里同名函数的**所有**实现摆出来（桌面一套、鸿蒙一套各自带 cfg 属性）。
 *
 * 现场形态（m3u8dl-tauri `commands.rs`）：
 * ```
 * #[cfg(not(all(target_os = "linux", target_env = "ohos")))]  pub async fn pick_folder() -> ... { rfd::... }
 * #[cfg(all(target_os = "linux", target_env = "ohos"))]       pub async fn pick_folder() -> ... { None }
 * ```
 * 注意 `not(...)` 里也含 `ohos` 字样，所以判"鸿蒙分支"必须是 **含 ohos 且不含 not(**
 * ——否则桌面实现会被误认成鸿蒙实现，判据直接反了。
 */
/**
 * 按字节区间切片，但**边界自动落到 UTF-8 字符起始处**。
 *
 * 2026-11-19 真机实测：`fnImplsOf` 直接 `src[a..b]` 切源码，而样本源码里有中文注释，
 * 一旦切在多字节字符中间就抛 `IllegalArgumentException: Invalid utf8 byte sequence`——
 * EcoPaste 的 `read_clipboard` 那条就是这么把整个 `verify` 打挂的（§4-113 同族）。
 */
func safeSliceOf(s: String, from: Int64, to: Int64): String {
    let bytes = s.toArray()
    var a = if (from < 0) { 0 } else { from }
    var b = if (to > bytes.size) { bytes.size } else { to }
    // 起点右移：跳过续字节（0x80..0xBF），让 a 落在字符首字节
    while (a > 0 && a < bytes.size && bytes[a] >= 128 && bytes[a] <= 191) {
        a += 1
    }
    // 终点左移：同理，别切在续字节上
    while (b > a && b < bytes.size && bytes[b] >= 128 && bytes[b] <= 191) {
        b -= 1
    }
    if (b <= a) {
        return ""
    }
    return s[a..b]
}

public func fnImplsOf(src: String, fnName: String): ArrayList<FnImpl> {
    let impls = ArrayList<FnImpl>()
    let needle = "fn " + fnName
    var i = findFrom(src, needle, 0)
    while (i >= 0) {
        let after = i + needle.size
        var nameEnds = false
        if (after < src.size) {
            let c = src[after]
            // 后面必须是 ( < 空白 之一，避免 pick_folder 撞上 pick_folder_extra
            if (c == 40 || c == 60 || c == 32 || c == 10 || c == 13 || c == 9) {
                nameEnds = true
            }
        }
        if (nameEnds) {
            // 属性区只从**上一个条目结束处**算起：往前找到最近的 `}`（上一条 fn 的收尾）就停。
            // 否则 600 字节窗口会把上一条函数的 `#[cfg(...)]` 圈进来——实测让"没有 cfg 的函数"
            // 被误判成鸿蒙分支（判据整个反过来），用例 testOhosImplStubOnlyReadsRealSourceShape 钉住。
            let lookback = if (i > 600) { i - 600 } else { 0 }
            var attrStart = lookback
            var j = i - 1
            while (j >= lookback) {
                if (src[j] == 125) {
                    attrStart = j + 1
                    break
                }
                j -= 1
            }
            let attr = safeSliceOf(src, attrStart, i)
            let cfg = lastCfgAttrOf(attr)
            let brace = findFrom(src, "{", i)
            if (brace >= 0) {
                let (bs, be) = bodyRangeOf(src, brace)
                let impl = FnImpl()
                impl.isOhos = cfg.contains("ohos") && !cfg.contains("not(")
                impl.body = safeSliceOf(src, bs, be)
                impls.add(impl)
            }
        }
        i = findFrom(src, needle, i + needle.size)
    }
    return impls
}

/**
 * 这个命令在鸿蒙侧是不是**空壳**（= 降级方案没落地）。
 *
 * 三种都算空壳：没有鸿蒙分支（桌面实现直接被 cfg 掉，鸿蒙上根本没这功能）、
 * 有鸿蒙分支但体是 `None`/`todo!()`、连函数都找不到。
 */
public func ohosImplStubOnly(src: String, fnName: String): Bool {
    let impls = fnImplsOf(src, fnName)
    var hasOhos = false
    var allStub = true
    for (im in impls) {
        if (im.isOhos) {
            hasOhos = true
            if (!ohosStubOnly(im.body)) {
                allStub = false
            }
        }
    }
    if (!hasOhos) {
        return true
    }
    return allStub
}

/** 这个命令的**桌面实现**里有没有出现任一平台 API 名（= 它会碰到平台专有能力） */
public func touchesAnyApi(src: String, fnName: String, apiNames: ArrayList<String>): Bool {
    return firstApiHitIn(src, fnName, apiNames) != ""
}

/** 命中的**第一个**平台 API 名（没命中给 ""）——清单里点名用，别只写"命中平台 API" */
public func firstApiHitIn(src: String, fnName: String, apiNames: ArrayList<String>): String {
    for (im in fnImplsOf(src, fnName)) {
        if (im.isOhos) {
            continue
        }
        for (api in apiNames) {
            if (api != "" && im.body.contains(api)) {
                return api
            }
        }
    }
    return ""
}

/**
 * 行内 `fn xxx(` 的 `xxx`（没有给 ""）。
 *
 * 只认 `fn` 前面是行首或空白，避免 `myfn(` / `xxxfn(` 撞上；跳过纯注释行。
 * 纯函数，便于单测（不碰文件系统）。
 */
public func fnNameOfLine(line: String): String {
    let t = line.trimAscii()
    if (t.startsWith("//") || t.startsWith("*")) {
        return ""
    }
    var from: Int64 = 0
    while (from < t.size) {
        let at = findFrom(t, "fn ", from)
        if (at < 0) {
            return ""
        }
        var ok = at == 0
        if (at > 0) {
            let prev = t[at - 1]
            ok = prev == 32 || prev == 9
        }
        if (ok) {
            let start = at + 3
            var j = start
            while (j < t.size && isIdentByteOf(t[j])) {
                j += 1
            }
            if (j > start) {
                return t[start..j]
            }
        }
        from = at + 3
    }
    return ""
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

/** 命中行（1 基行号）所属函数名（往前找最近的 `fn` 声明；找不到给 ""） */
public func enclosingFnOf(src: String, lineNo: Int64): String {
    let lines = src.split("\n", -1)
    var i = if (lineNo > lines.size) { lines.size - 1 } else { lineNo - 1 }
    while (i >= 0) {
        let nm = fnNameOfLine(lines[i])
        if (nm != "") {
            return nm
        }
        i -= 1
    }
    return ""
}

/**
 * 命中行所属函数是不是**桌面专用**（上方属性区里有 `#[cfg(...)]` 且同时含 `not(` 与 `ohos`）。
 *
 * 这类函数在鸿蒙上压根不编译，命中点不构成"降级没落地"——
 * 典型现场：habit-tree `save_target_dir` 是 `#[cfg(not(target_env = "ohos"))]`。
 */
public func fnDesktopOnlyOf(src: String, lineNo: Int64): Bool {
    let lines = src.split("\n", -1)
    var i = if (lineNo > lines.size) { lines.size - 1 } else { lineNo - 1 }
    var fnIdx: Int64 = -1
    while (i >= 0) {
        if (fnNameOfLine(lines[i]) != "") {
            fnIdx = i
            break
        }
        i -= 1
    }
    if (fnIdx < 0) {
        return false
    }
    var j = fnIdx - 1
    while (j >= 0) {
        let t = lines[j].trimAscii()
        if (t == "") {
            j -= 1
            continue
        }
        if (!t.startsWith("#[")) {
            break
        }
        if (t.contains("cfg")) {
            if (t.contains("ohos") && t.contains("not(")) {
                return true
            }
            // `#[cfg(target_os = "windows")]` / `"macos"`：这段在鸿蒙上根本不编译，不算"没落地"。
            // 2026-11-19 EcoPaste 实测：`is_scheduled_task_exists()` 全是 `#[cfg(target_os = "windows")]`，
            // 却被判成"没有鸿蒙实现"⇒ platform-api 冤枉地 fail（§4-157 同族：观测缺陷当功能缺陷）。
            // **不能**把 `target_os = "linux"` 当桌面专属——鸿蒙的 target_os 也是 linux。
            if (t.contains("target_os") && (t.contains("windows") || t.contains("macos")) &&
                !t.contains("ohos")) {
                return true
            }
        }
        j -= 1
    }
    return false
}

/**
 * 函数**体内**有没有落地的鸿蒙分支块。
 *
 * `fnImplsOf` 只认"整个函数被 `#[cfg(...)]` 包裹"的写法（m3u8dl-tauri 的 pick_folder 是那种），
 * 但现场还有一半写法是**一个函数、体内两块 cfg**（habit-tree 的 resolve_app_data_dir）：
 *
 * ```
 * fn resolve_app_data_dir(app: &tauri::App) -> Result<PathBuf, tauri::Error> {
 *     #[cfg(target_env = "ohos")]
 *     {
 *         Ok(PathBuf::from("/data/storage/el2/base/files"))
 *     }
 *     #[cfg(not(target_env = "ohos"))]
 *     {
 *         app.path().app_data_dir()
 *     }
 * }
 * ```
 *
 * 这种形态 `ohosImplStubOnly` 判不出来（函数本身没有 cfg），于是一个**已经落地**的
 * 降级方案会被判成"没有鸿蒙实现"。纯函数，便于单测。
 */
public func hasLandedOhosBlockIn(body: String): Bool {
    let marker = "#[cfg("
    var i = findFrom(body, marker, 0)
    while (i >= 0) {
        let close = findFrom(body, ")]", i)
        if (close >= 0) {
            let attr = body[i..close + 2]
            // `not(...)` 里也含 ohos 字样——那是桌面分支，不能当鸿蒙分支（同 fnImplsOf 的口径）
            if (attr.contains("ohos") && !attr.contains("not(")) {
                let brace = findFrom(body, "{", close + 2)
                if (brace >= 0) {
                    let (bs, be) = bodyRangeOf(body, brace)
                    if (!ohosStubOnly(body[bs..be])) {
                        return true
                    }
                }
            }
        }
        i = findFrom(body, marker, i + marker.size)
    }
    return false
}

/**
 * 一处平台 API 命中点**算不算缺口**（= 降级方案没落地）。返回 (是缺口, 为什么)。
 *
 * 判序（0.39.107）：桌面专用函数 → 不算缺口（鸿蒙上不编译这段）；
 * 所在函数有落地的鸿蒙实现 → 不算缺口；其余（含"压根没有鸿蒙分支"）→ 算缺口。
 *
 * 为什么需要它：`app_data_dir` 这类平台 API 常出现在 setup / 辅助函数里，**没有 IPC 命令命中**，
 * 旧判据直接落"无法判定 → 没落地"，于是明明 `resolve_app_data_dir()` 在鸿蒙上返回沙箱路径，
 * 移植项 `platform-api` 还是判 fail。
 */
public func judgePlatformSite(src: String, lineNo: Int64): (Bool, String) {
    let fnName = enclosingFnOf(src, lineNo)
    if (fnName == "") {
        return (true, "找不到命中行所属函数，无法判定降级落没落地")
    }
    if (fnDesktopOnlyOf(src, lineNo)) {
        return (false, "用在 `${fnName}` 里，该函数桌面专用（`#[cfg(not(...ohos...))]`），鸿蒙上不编译这段")
    }
    if (!ohosImplStubOnly(src, fnName)) {
        return (false, "用在 `${fnName}` 里，该函数有落地的鸿蒙实现")
    }
    // 一个函数、体内两块 cfg 的写法（habit-tree resolve_app_data_dir）：看函数体里的鸿蒙块
    for (im in fnImplsOf(src, fnName)) {
        if (hasLandedOhosBlockIn(im.body)) {
            return (false, "用在 `${fnName}` 里，该函数体内的鸿蒙分支有落地的实现")
        }
    }
    return (true, "用在 `${fnName}` 里，该函数没有落地的鸿蒙实现")
}

/**
 * 一个命令的回调函数在鸿蒙侧**有没有落地实现**（两种形态都认）：
 * ① 整个函数被 `#[cfg(target_env = "ohos")]` 包裹；② 单函数体内再按 cfg 分块
 * （habit-tree `resolve_app_data_dir` / `open_url` 就是第 ② 种）。
 *
 * 只认 ① 会把"已经落了鸿蒙分支"的函数判成空壳（反过来只认 ② 同理），
 * 两种写法在真机上效果一样，判据必须都收。
 */
public func commandImplLanded(src: String, fnName: String): Bool {
    if (fnName == "") {
        return false
    }
    if (!ohosImplStubOnly(src, fnName)) {
        return true
    }
    for (im in fnImplsOf(src, fnName)) {
        if (hasLandedOhosBlockIn(im.body)) {
            return true
        }
    }
    return false
}

// ============================================================
// 桥的双侧判据（0.39.114 / §4-162）：Rust 侧调了桥 ≠ 真机能用
// ============================================================
//
// 实测动机：把 `rfd::FileDialog` / `explorer` 这类原生 UI 换成桥之后，verify 判 pass、
// 交叉编译 exit=0，**真机点了没反应**——因为 `.ets` 里根本没有对应的 `cmd` 分支，
// 而 `cargo build`（含 `--target aarch64-unknown-linux-ohos`）**根本不编译 ArkTS**，
// 只有 `hvigor`（`lingqu-cli hap`）才会查。
//
// 所以"落地"的定义是**两侧都在**：Rust 分支里 `call_arkts("x")`，且 ArkTS 分发器里
// `case "x":` 存在。少任何半边都不算落地——只查 Rust 半边就是假绿（§4-116 同族）。

/** Rust 分支里往 ArkTS 走的那条调用的 cmd 名（不走桥就给空串） */
public func bridgeCmdInRustOf(body: String): String {
    for (m in ["call_arkts(\"", "callArkts(\""]) {
        let i = findFrom(body, m, 0)
        if (i >= 0) {
            let start = i + m.size
            let end = findFrom(body, "\"", start)
            if (end > start) {
                return body[start..end]
            }
        }
    }
    return ""
}

/**
 * ArkTS 分发器里有没有这个 cmd 分支。认现场的真实两种写法：
 *
 * - `switch` 形态：`case "pickFile":` / `case 'pickFile':`
 * - 协议字段形态（habit-tree / m3u8dl 实际就是这么写的）：`parsed.cmd === 'save_card'`
 *
 * 判据刻意收紧：命中的那处字符串**前 64 字符内必须出现 `cmd` 或 `case`**——
 * 否则注释里、别的协议字段里出现同名串就会被当成"实现了"（§4-65 那类假绿）。
 */
public func arktsDispatchHasCmdOf(etsSrc: String, cmd: String): Bool {
    if (cmd == "" || etsSrc == "") {
        return false
    }
    for (form in ["\"${cmd}\"", "'${cmd}'"]) {
        var from = 0
        while (true) {
            let i = findFrom(etsSrc, form, from)
            if (i < 0) {
                break
            }
            let back = if (i > 64) { i - 64 } else { 0 }
            let head = etsSrc[back..i]
            if (findFrom(head, "cmd", 0) >= 0 || findFrom(head, "case", 0) >= 0) {
                return true
            }
            from = i + form.size
        }
    }
    return false
}

/**
 * Rust 侧发出去的桥命令名（两种形态都要认，只认一种就会漏掉半个现场）：
 *
 * - 字面量形态：`call_arkts("open_url", ...)`
 * - 协议字段形态：`"cmd": "save_card"` / `cmd: "open_url"`（habit-tree 的 `ohos_bridge.rs`）
 */
public func rustBridgeCmdsOf(text: String): ArrayList<String> {
    let out = ArrayList<String>()
    if (text == "") {
        return out
    }
    // ① call_arkts("<cmd>"
    var from = 0
    while (true) {
        let i = findFrom(text, "call_arkts(\"", from)
        if (i < 0) {
            break
        }
        let start = i + "call_arkts(\"".size
        let e = findFrom(text, "\"", start)
        if (e <= start) {
            break
        }
        addCmdUnique(out, text[start..e])
        from = e + 1
    }
    // ② "cmd": "<cmd>" 与 cmd: "<cmd>"（冒号必须紧跟，否则会捞到别处的值）
    for (k in ["\"cmd\": ", "cmd: "]) {
        var f2 = 0
        while (true) {
            let i = findFrom(text, k, f2)
            if (i < 0) {
                break
            }
            var p = i + k.size
            while (p < text.size && (text[p] == 32 || text[p] == 9)) {
                p += 1
            }
            if (p < text.size) {
                let q = text[p]
                if (q == 34 || q == 39) {
                    let e = findFrom(text, if (q == 34) { "\"" } else { "'" }, p + 1)
                    if (e > p + 1) {
                        addCmdUnique(out, text[(p + 1)..e])
                        f2 = e + 1
                        continue
                    }
                }
            }
            f2 = i + k.size
        }
    }
    return out
}

/** 命令名只收 [a-z0-9_]（防把注释/句子当成 cmd） */
func isCmdNameOf(s: String): Bool {
    if (s.size == 0 || s.size > 40) {
        return false
    }
    for (i in 0..s.size) {
        let c = s[i]
        if ((c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95) {
            continue
        }
        return false
    }
    return true
}

func addCmdUnique(out: ArrayList<String>, c: String): Unit {
    if (isCmdNameOf(c) && !out.contains(c)) {
        out.add(c)
    }
}

/**
 * 项目级双侧比对：Rust 发出去的 cmd 里，有哪些 ArkTS 分发器**没实现**。
 *
 * 这是"桥只写半边"的权威判据（§4-162）：空数组 = 两侧都在，非空 = 真机点了没反应的那几个。
 */
public func missingBridgeCmdsOf(rustText: String, etsSrc: String): ArrayList<String> {
    let out = ArrayList<String>()
    for (c in rustBridgeCmdsOf(rustText)) {
        if (!arktsDispatchHasCmdOf(etsSrc, c)) {
            out.add(c)
        }
    }
    return out
}

/** 一条命令的桥落地结论（两侧都有才算落地） */
public class BridgeVerdict {
    /** Rust 侧确实要往 ArkTS 走（否则这条命令与桥无关，判据不适用） */
    public var callsBridge: Bool = false
    /** 两侧都在 */
    public var landed: Bool = false
    /** 桥用的 cmd 名 */
    public var cmd: String = ""
    /** 结论一行（缺了哪一半要说清，否则界面只有"没落地"三个字） */
    public var reason: String = ""

    public init() {}
}

/**
 * 纯判定：这条命令的桥是不是**两侧都在**。
 *
 * 返回的 `callsBridge=false` 表示"不适用"（纯 Rust 逻辑，没有桥），调用方不该拿它扣分；
 * `callsBridge=true && landed=false` 才是要拦的那种——真机上点了不会有任何反应。
 */
public func bridgeTwoSidedOf(rustSrc: String, etsSrc: String, fnName: String): BridgeVerdict {
    let v = BridgeVerdict()
    if (fnName == "") {
        v.reason = "没有命令名，判不了"
        return v
    }
    var cmd = ""
    for (im in fnImplsOf(rustSrc, fnName)) {
        let c = bridgeCmdInRustOf(im.body)
        if (c != "") {
            cmd = c
            break
        }
    }
    if (cmd == "") {
        v.reason = "这个命令不经过 ArkTS 桥"
        return v
    }
    v.callsBridge = true
    v.cmd = cmd
    if (etsSrc == "") {
        v.reason = "Rust 侧调了 call_arkts(\"${cmd}\")，但工程里找不到 ArkTS 分发器（没有含 __ohos_dispatch 的 .ets）"
        return v
    }
    if (!arktsDispatchHasCmdOf(etsSrc, cmd)) {
        v.reason = "Rust 侧调了 call_arkts(\"${cmd}\")，但 ArkTS 分发器里没有 case \"${cmd}\" 分支——" +
            "真机点了不会有反应（cargo 不审 ArkTS，只有 hvigor 会审）"
        return v
    }
    v.landed = true
    v.reason = "两侧都在：Rust call_arkts(\"${cmd}\") + ArkTS case \"${cmd}\""
    return v
}

/** 落档里的命中位置（`src-tauri/src/commands.rs:157`）→ 行号（取不到给 0） */
public func siteLineOf(site: String): Int64 {
    var cut: Int64 = -1
    var i = 0
    while (i < site.size) {
        if (site[i] == 58 && i + 1 < site.size && site[i + 1] >= 48 && site[i + 1] <= 57) {
            cut = i
        }
        i += 1
    }
    if (cut < 0) {
        return 0
    }
    var v: Int64 = 0
    var j = cut + 1
    while (j < site.size) {
        let c = site[j]
        if (c < 48 || c > 57) {
            break
        }
        v = v * 10 + Int64(c) - 48
        j += 1
    }
    return v
}

/**
 * 前端（`.ts` / `.js` / `.html`）里一处平台 API 调用**算不算缺口**。返回 (是缺口, 为什么)。
 *
 * 前端没有 `#[cfg(target_env = "ohos")]` 可判，落地的形态是**兜底路径**：
 * ```
 * async function fillVersion() {
 *   let v = APP_VERSION_FALLBACK;      // 兜底值
 *   try { v = await getVersion(); }    // 平台有就取真的
 *   catch { /* 没有就留兜底 */ }
 * }
 * ```
 * 判据只有一条：命中点所在函数块里有 `catch` → 失败有去处，算落地；没有 → 缺口。
 * 纯函数（不碰文件系统），便于单测。
 */
public func judgeFrontendSite(src: String, lineNo: Int64): (Bool, String) {
    let lines = src.split("\n", -1)
    // ⓿ 命中行如果是 `import` / `export … from`，那**根本不是调用点**——
    //    2026-11-19 EcoPaste 实测：`App.tsx:1` 与 `useAppTheme.ts:2` 都是
    //    `import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow"`，
    //    却被当成"平台 API 调用"判缺口（§4-157 同族：观测缺陷当功能缺陷）。
    if (lineNo - 1 < lines.size) {
        let hit = lines[lineNo - 1].trimAscii()
        if (hit.startsWith("import ") || (hit.startsWith("export ") && hit.contains(" from "))) {
            return (false, "命中行是 import 语句，不是调用点，不计缺口")
        }
    }
    // ① 命中行的字节偏移（用来界定"往上找函数"的范围）
    var off: Int64 = 0
    var k: Int64 = 0
    while (k < lineNo - 1 && k < lines.size) {
        off = off + lines[k].size + 1
        k += 1
    }
    // ② 最近的函数起点：`function ` 与**箭头函数**（`const f = async () => {`）都要认。
    //    只认 `function ` 会把 EcoPaste 的 `const initializeAppMetadata = async () => {`
    //    判成"找不到所属函数"，而它里面明明有 try/catch 兜底。
    var start: Int64 = -1
    var idx: Int64 = 0
    while (idx < lineNo - 1 && idx < lines.size) {
        let t = lines[idx].trimAscii()
        if (t.contains("function ") || (t.contains("=>") && (t.endsWith("{") || t.endsWith("=> {")))) {
            start = idx
        }
        idx += 1
    }
    if (start < 0) {
        return (true, "找不到命中点所属函数（无法判定有没有兜底）")
    }
    // ③ 从函数起点往后 60 行内看有没有 catch：前端落地的形态就是 try/catch 兜底
    var body = ""
    var m = start
    while (m < lines.size && m < start + 60) {
        body += lines[m] + "\n"
        m += 1
    }
    if (body.contains("catch")) {
        return (false, "调用点所在函数有 try/catch 兜底，平台不支持时走回落（前端降级已落地）")
    }
    return (true, "调用点所在函数没有 try/catch 兜底，平台不支持时直接抛错/静默失败")
}

/** 可用率统计（口径见文件头） */
public class VerifyStats {
    public var total: Int64 = 0        // 清单总条数
    public var pass: Int64 = 0
    public var fail: Int64 = 0
    public var limit: Int64 = 0        // 平台限制（不计入分母）
    public var unknown: Int64 = 0      // 没证据（计入分母、不算通过）
    /** 有结论的项数（pass + fail）——**这才是 A4 的分母** */
    public var covered: Int64 = 0
    /** 未测项数（unknown）：**不进分母**，但必须在报告与界面里显式写出来 */
    public var notVerified: Int64 = 0
    /**
     * **移植验收项**里的通过条数（`category == "transplant"` 且 verdict=pass）。
     *
     * 为什么不复用 `pass`：`pass` 含 launch/build/hap/frontend 这些装配项，而 `covered` 只数移植项。
     * 两者相除就是用户实测看到的「可用率 0%（**4/3 项有结论**）」——分子比分母还大（0.39.93）。
     */
    public var featurePass: Int64 = 0
    /**
     * 移植验收项总数（D-020：**A4 的分母只认这一类**）。
     *
     * 业务功能（`category == "business"`，即 `feat:<IPC 命令>`）**不进这个数**——
     * 逐条点永远点不完，缺网/缺配置也必然过不了，那不属移植职责。
     */
    public var transplantTotal: Int64 = 0
    /** 移植项里没证据的条数（不进分母，但必须在报告与界面里写出来） */
    public var transplantNotVerified: Int64 = 0
    /** 业务功能条数（只统计"扫到多少"，**不要求逐条有结论**） */
    public var businessTotal: Int64 = 0
    /** 业务功能里真机冒烟点过的条数（单列，不计分） */
    public var businessTested: Int64 = 0
    /** 业务冒烟里通过的条数（同样不计分，只作参考） */
    public var businessPass: Int64 = 0
    /** 移植项里**来自真机实测**的条数（口径说明要能说清来源） */
    public var probeFeatures: Int64 = 0
    /** 分母的口径来源：`transplant`（移植验收项）/ `gates-only`（没扫过，只能退回装配口径） */
    public var scope: String = ""
    /** 口径来源的人话解释（直接进报告，别让人猜这个百分比在算谁） */
    public var scopeNote: String = ""
    /** 可用率 = transplantPass / transplantCovered；分母为 0 时按 0 处理（绝不"没数据就给 100"） */
    public var ratePercent: Int64 = 0

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("total", JsonInt(this.total))
        o.put("pass", JsonInt(this.pass))
        o.put("fail", JsonInt(this.fail))
        o.put("limit", JsonInt(this.limit))
        o.put("unknown", JsonInt(this.unknown))
        o.put("covered", JsonInt(this.covered))
        o.put("notVerified", JsonInt(this.notVerified))
        o.put("featurePass", JsonInt(this.featurePass))
        o.put("transplantTotal", JsonInt(this.transplantTotal))
        o.put("transplantNotVerified", JsonInt(this.transplantNotVerified))
        o.put("businessTotal", JsonInt(this.businessTotal))
        o.put("businessTested", JsonInt(this.businessTested))
        o.put("businessPass", JsonInt(this.businessPass))
        o.put("probeFeatures", JsonInt(this.probeFeatures))
        o.put("scope", JsonString(this.scope))
        o.put("scopeNote", JsonString(this.scopeNote))
        o.put("ratePercent", JsonInt(this.ratePercent))
        return o
    }
}

/**
 * 从输入生成功能清单。
 *
 * 清单是**推导**出来的，不是手写死的：命令/事件/插件/前端/平台 API 的条数决定有没有这一项，
 * 部署与日志决定它的判定。这样换一个样本工程，清单自动跟着变（T6-1 的要求）。
 */
public func buildChecklist(inp: ChecklistInput): ArrayList<CheckItem> {
    let items = ArrayList<CheckItem>()

    // ① 启动与首屏（真机侧最基础的一条：装得上、起得来、日志没崩）
    let launch = CheckItem("launch", "应用启动无 panic，首屏渲染")
    if (inp.installed) {
        launch.evidence.add("hdc install：install bundle successfully")
    }
    if (inp.started) {
        launch.evidence.add("aa start：start ability successfully")
    }
    if (inp.screenshotCount > 0) {
        launch.evidence.add("真机截图 ${inp.screenshotCount} 张（.lingqu/evidence/）")
    }
    if (inp.crashCount > 0) {
        launch.evidence.add("faultlog 崩溃记录 ${inp.crashCount} 条")
    }
    if (!inp.installed) {
        launch.verdict = "fail"
        launch.note = "没装上（先跑 ⑥ 屏「安装并启动」；签名问题看 ⑤ 屏「签名体检」）"
    } else if (!inp.started) {
        launch.verdict = "fail"
        launch.note = "装上了但没起来（多半 ability/bundle 名不对）"
    } else if (!inp.hilogHealthy || inp.crashCount > 0) {
        launch.verdict = "fail"
        launch.note = "hilog 有崩溃痕迹或 faultlog 有记录"
    } else if (inp.screenshotCount == 0) {
        launch.verdict = "unknown"
        launch.note = "缺截图证据（点「采集证据」）"
    } else {
        launch.verdict = "pass"
    }
    items.add(launch)

    // ② 交叉编译（.so 能编出来且前端指纹对得上）——没有这条，后面全是空中楼阁
    let build = CheckItem("build", "交叉编译通过，前端指纹一致")
    if (inp.buildOk) {
        build.evidence.add("t2h:build：cargo build --target aarch64-unknown-linux-ohos exit=0")
    }
    if (inp.assetOk) {
        build.evidence.add(".so 内嵌 AssetKey ↔ dist/ 双向比对一致")
    }
    if (!inp.hasBuild) {
        build.verdict = "unknown"
        build.note = "没跑过交叉编译（⑤ 屏「交叉编译（OHOS）」）"
    } else if (!inp.buildOk) {
        build.verdict = "fail"
        build.note = "交叉编译跑过但没通过（看 .lingqu/build/<工程>.json 的 exitCode / firstError）"
    } else if (!inp.assetOk) {
        build.verdict = "fail"
        build.note = "前端指纹不一致：改了前端没重编 .so（会白屏）"
    } else {
        build.verdict = "pass"
    }
    items.add(build)

    // ③ HAP 装配（含"应用自己的 .so 进包"这条点名校验）
    let hap = CheckItem("hap", "HAP 装配通过（应用 .so 已进包、无死资源）")
    if (inp.hapOk) {
        hap.evidence.add("t2h:hap：gates.passed=true")
    }
    if (inp.hapBuilt) {
        hap.evidence.add("hvigor assembleHap 成功（built=true）")
    }
    if (inp.hapSigned) {
        hap.evidence.add("产物是 signed HAP（signed=true）")
    }
    if (!inp.hasHap) {
        hap.verdict = "unknown"
        hap.note = "没跑过装配（⑤ 屏「装配 HAP」）"
    } else if (!inp.hapBuilt) {
        hap.verdict = "fail"
        hap.note = "装配跑过但 hvigor 没成功（看 .lingqu/hap/<工程>.log）"
    } else if (!inp.hapOk) {
        // 跑过、包也出来了，是**闸**没过（最典型：rawfile/ 里有死资源）——
        // 这是"跑了没过"，必须报 fail 并把第一条失败贴出来，不能混成"没跑过"
        hap.verdict = "fail"
        hap.note = if (inp.hapFirstFailure != "") {
            "装配闸未通过：${inp.hapFirstFailure}"
        } else {
            "装配闸未通过（看 .lingqu/hap/<工程>.json 的 gates.failures）"
        }
    } else {
        hap.verdict = "pass"
    }
    items.add(hap)

    // ④ 原应用业务功能逐条（D-020：**不进 A4 分母**，只统计条数 + 供真机冒烟）
    //   判定顺序固定：人测过 → 以人的结论为准；命中平台 API 且降级未落地 → fail（说明这个平台能力没接上）；
    //   其余 → 未测（不是"不可用"，是"没人验过"）
    for (f in inp.features) {
        let title = if (f.title != "") { f.title } else { f.commandName }
        let it = CheckItem("feat:${f.commandName}", title)
        it.kind = "feature"
        // D-020：扫描出来的 IPC 命令是**原应用自己的业务功能**，不进移植验收分母、也不判 fail；
        // `probe:` 前缀的是真机冒烟点按，单独归 smoke（同样不计入通过率）
        it.category = if (f.commandName.startsWith("probe:")) { "smoke" } else { "business" }
        if (f.degradedApi != "") {
            it.evidence.add("命中平台 API：${f.degradedApi}")
        }
        if (f.bridgeCmd != "") {
            it.evidence.add("ArkTS 桥 cmd：${f.bridgeCmd}")
        }
        if (f.bridgeMissing != "") {
            it.evidence.add(f.bridgeMissing)
        }
        if (f.fallbackLanded) {
            it.evidence.add("鸿蒙侧有落地的替代实现（不是空壳分支）")
        } else if (f.degradedApi != "") {
            it.evidence.add("鸿蒙侧分支是空壳（只 return None / todo!()）→ 前端拿到 null 静默不做任何事")
        }
        if (f.probeVerdict != "") {
            // 真机点过 → 以实测为准（证据强度高于任何静态推断）
            it.verdict = f.probeVerdict
            let seen = if (f.probeNote != "") { f.probeNote } else { "真机上点按过" }
            it.note = "真机实测：${seen}"
            for (e in f.probeEvidence) {
                it.evidence.add("实测证据：${e}")
            }
        } else if (f.humanVerdict == "fail") {
            it.verdict = "fail"
            it.note = "人工实测：真机上这项不可用"
        } else if (f.humanVerdict == "pass") {
            it.verdict = "pass"
            it.note = "人工实测：真机上可用"
        } else if (f.degradedApi != "" && !f.fallbackLanded) {
            // D-020：平台 API 空壳是**移植项**（platform-api）该记的账，那里已经判 fail 了；
            // 业务功能本身没人实测过 → 只能记未测。否则同一件事扣两次，还会让业务清单
            // 出现一片红色 fail，看着像"原应用全崩"——那是误报，不是移植结论。
            it.verdict = "unknown"
            it.note = "未实测；它依赖的「${f.degradedApi}」在鸿蒙侧是空壳（这条已由移植项 platform-api 记 fail），" +
                "业务功能本身不计分"
        } else {
            it.verdict = "unknown"
            it.note = "未测：需要真机交互证据（点了真的出结果）或人工确认；不进可用率分母，但计入未测项"
        }
        items.add(it)
    }

    // ⑤ 聚合的 IPC 项：只在**没有功能明细**（没扫过）时保留。
    //   判据只剩"应用起来了"，一条命令都没调过 → 只能是 unknown（旧版判 pass，正是分母虚高的源头）。
    if (inp.features.size == 0 && inp.commandCount > 0) {
        let cmd = CheckItem("ipc", "IPC 命令通道可用（共 ${inp.commandCount} 条命令）")
        if (inp.started) {
            cmd.evidence.add("aa start 成功；后端已加载能力清单")
        }
        if (inp.blockerCount > 0) {
            cmd.evidence.add("扫描发现 ${inp.blockerCount} 个阻塞项（见 ② 迁移画像）")
        }
        cmd.verdict = "unknown"
        cmd.note = "只有「应用起来了」这条间接证据，一条命令都没真调过 → 未测（旧版据此判通过，可用率才虚高）"
        items.add(cmd)
    }

    // ⑤ 事件回投（后端 → 前端）：条数来自扫描
    if (inp.eventCount > 0) {
        let ev = CheckItem("events", "后端事件回投可用（共 ${inp.eventCount} 个事件）")
        ev.verdict = if (inp.started && inp.hilogHealthy) { "unknown" } else { "unknown" }
        ev.note = "事件通路要逐条触发才算验证；当前只有「应用起来了」这条间接证据"
        if (inp.started) {
            ev.evidence.add("应用已启动（间接证据，未逐条触发）")
        }
        items.add(ev)
    }

    // ⑥ 插件能力：桌面特有插件在鸿蒙上是平台限制，不该算失败
    if (inp.pluginCount > 0) {
        let plug = CheckItem("plugins", "插件能力（共 ${inp.pluginCount} 个，桌面专有的记为平台限制）")
        plug.evidence.add("逐条判定见 ③ 依赖扫描与 ② 迁移画像")
        plug.verdict = if (inp.started) { "pass" } else { "unknown" }
        items.add(plug)
    }

    // ⑦ 前端资源加载（前端文件数来自扫描；命中前端指纹闸才算过）
    if (inp.frontendCount > 0) {
        let fe = CheckItem("frontend", "前端资源打进 .so 并正确加载（${inp.frontendCount} 个源文件）")
        if (inp.assetOk) {
            fe.evidence.add("AssetKey 双向比对一致")
        }
        if (inp.screenshotCount > 0) {
            fe.evidence.add("真机截图可见界面")
        }
        fe.verdict = if (inp.assetOk && inp.screenshotCount > 0) { "pass" } else { "unknown" }
        if (fe.verdict == "unknown") {
            fe.note = "缺截图或指纹证据"
        }
        items.add(fe)
    }

    // ⑧ 平台限制登记：**只有降级方案真的落地了**才允许记 limit（用户可以少算它），
    //   否则这一处的功能在真机上就是不可用的，必须判 fail 并点名——不能靠"登记为平台限制"把它藏起来。
    if (inp.platformCount > 0 || inp.platformItems.size > 0) {
        let n = if (inp.platformItems.size > 0) { inp.platformItems.size } else { inp.platformCount }
        let lim = CheckItem("platform-api", "平台限制（${n} 处）是否都有落地的降级方案")
        var unlanded = ArrayList<String>()
        for (p in inp.platformItems) {
            if (!p.fallbackLanded) {
                unlanded.add(p.name)
            }
        }
        if (inp.platformItems.size == 0) {
            lim.verdict = "unknown"
            lim.note = "登记了 ${inp.platformCount} 处平台 API，但没有「降级方案是否落地」的证据 → 不能算平台限制"
        } else if (unlanded.size > 0) {
            lim.verdict = "fail"
            lim.note = "${unlanded.size} 处没有落地的降级方案：${joinNames(unlanded)}" +
                "（对应功能在真机上不可用，不许剔出分母）"
        } else {
            lim.verdict = "limit"
            lim.note = "每一处都有落地的降级方案，按平台限制剔出可用率分母"
        }
        lim.evidence.add("扫描口径：platform_apis=${inp.platformCount}")
        for (p in inp.platformItems) {
            if (p.note != "") {
                lim.evidence.add("${p.name}：${p.note}")
            }
        }
        items.add(lim)
    }

    return items
}

/** 把名字拼成一行人话（`a、b、c`），报告里点名用 */
func joinNames(names: ArrayList<String>): String {
    var s = ""
    for (x in names) {
        if (s != "") {
            s += "、"
        }
        s += x
    }
    return s
}

/**
 * 按口径统计通过率（见文件头 ①②，D-020）。
 *
 * **分母只认移植验收项**（`category=transplant`）：装得上/起得来/渲染/前端资源/通道/平台能力。
 * 原应用的业务功能（`business`）与真机冒烟（`smoke`）**单独计数、不进分母**——逐条点永远点不完。
 * 一条移植项都没有（没跑过 verify）时退回装配口径，并在 `scope / scopeNote` 里写明
 * "这不代表功能可用"——让人一眼看出这个百分比在算谁。
 */
public func computeStats(items: ArrayList<CheckItem>): VerifyStats {
    let s = VerifyStats()
    // 全局计数（total/pass/fail/limit/unknown）**只覆盖移植项**：界面顶栏拿它显示
    // 「通过 5/6」「失败 2」，若把冒烟项也算进来，一条业务功能点不亮就会被读成移植失败。
    // 业务功能与冒烟各自单独计数（businessTotal/…/probeFeatures），见下面的分支。
    // 口径（D-020）：**分母只认 `category=transplant`**——移植该负责的事。
    // 业务功能（`feat:<IPC 命令>`）与真机冒烟单独计数：逐条点永远点不完，缺网/缺配置也必然过不了，
    // 那不属移植职责，塞进分母就是替原应用的 bug 背锅（§4-63 第三态）。
    var tTotal: Int64 = 0
    var tPass: Int64 = 0
    var tCovered: Int64 = 0
    var tNotVerified: Int64 = 0
    var bTotal: Int64 = 0
    var bTested: Int64 = 0
    var bPass: Int64 = 0
    var sSmoke: Int64 = 0
    for (it in items) {
        if (it.category == "business") {
            bTotal += 1
            if (it.verdict == "pass") {
                bTested += 1
                bPass += 1
            } else if (it.verdict == "fail") {
                bTested += 1
            }
            continue
        }
        if (it.category == "smoke") {
            sSmoke += 1
            if (it.verdict == "pass") {
                bTested += 1
                bPass += 1
            } else if (it.verdict == "fail") {
                bTested += 1
            }
            continue
        }
        // transplant：平台限制项照旧不进分母（但计入 total 与 limit，让人看得见"有限制"）
        s.total += 1
        if (it.verdict == "pass") {
            s.pass += 1
        } else if (it.verdict == "fail") {
            s.fail += 1
        } else if (it.verdict == "limit") {
            s.limit += 1
        } else {
            s.unknown += 1
        }
        if (it.verdict == "limit") {
            continue
        }
        tTotal += 1
        if (it.verdict == "pass") {
            tPass += 1
            tCovered += 1
        } else if (it.verdict == "fail") {
            tCovered += 1
        } else if (it.verdict == "unknown") {
            tNotVerified += 1
        }
    }
    s.transplantTotal = tTotal
    s.transplantNotVerified = tNotVerified
    s.businessTotal = bTotal
    s.businessTested = bTested
    s.businessPass = bPass
    s.probeFeatures = sSmoke
    if (tTotal > 0) {
        s.scope = "transplant"
        let unmeasured = if (tNotVerified > 0) { "；另有 ${tNotVerified} 项未测" } else { "" }
        s.scopeNote = "分母 = 移植验收项 ${tTotal} 条（装得上/起得来/渲染得出/前端资源进包/IPC 与事件通道/" +
            "平台能力有落地等价物），通过 ${tPass} / 有结论 ${tCovered}${unmeasured}" +
            "。业务功能 ${bTotal} 条只作冒烟记录（实测 ${bTested} 条，通过 ${bPass} 条），属原应用职责，不计入移植验收"
        s.covered = tCovered
        s.notVerified = tNotVerified
        s.featurePass = tPass
        if (tCovered > 0) {
            s.ratePercent = (tPass * 100) / tCovered
        }
    } else {
        s.scope = "gates-only"
        s.scopeNote = "没有任何移植验收项 → 退回装配口径（编得过 / 装配过 / 起得来），**不等于可用**"
        s.covered = s.pass + s.fail
        s.notVerified = s.unknown
        s.featurePass = s.pass
        if (s.covered > 0) {
            s.ratePercent = (s.pass * 100) / s.covered
        }
    }
    return s
}

/** 报告头（三段式的第一段）需要的上下文 */
public class ReportContext {
    public var project: String = ""
    public var bundleName: String = ""
    public var generatedAt: String = ""
    public var deviceSerial: String = ""
    public var version: String = ""

    public init(project: String) {
        this.project = project
    }
}

/** 渲染 Markdown 报告（三段式：做了什么 / 没做什么 / 需要你做什么） */
public func renderMarkdown(ctx: ReportContext, items: ArrayList<CheckItem>, stats: VerifyStats): String {
    var md = "# 迁移验证报告 · ${ctx.project}\n\n"
    md += "- 包名：${ctx.bundleName}\n"
    if (ctx.version != "") {
        md += "- 版本：${ctx.version}\n"
    }
    if (ctx.deviceSerial != "") {
        md += "- 设备：${ctx.deviceSerial}\n"
    }
    md += "- 生成时间：${ctx.generatedAt}\n\n"

    md += "## 一、做了什么\n\n"
    md += "移植验收通过率 **${stats.ratePercent}%**（通过 ${stats.featurePass} / 有结论 ${stats.covered}）\n\n"
    md += "- 口径：${stats.scopeNote}\n"
    if (stats.businessTotal > 0) {
        md += "- 业务功能 ${stats.businessTotal} 条属**原应用职责**，未逐条验证" +
            "（真机冒烟 ${stats.businessTested} 条，通过 ${stats.businessPass} 条）——不计入上面的百分比\n"
    }
    if (stats.notVerified > 0) {
        md += "- 注意：有 ${stats.notVerified} 项**未测**（不计入分母）：这个百分比只代表已测的那部分\n"
    }
    if (stats.limit > 0) {
        md += "- 平台限制 ${stats.limit} 项（降级方案已落地，已剔出分母）\n"
    }
    md += "\n"
    md += "| # | 功能项 | 判定 | 证据 |\n|---|---|---|---|\n"
    var i: Int64 = 1
    for (it in items) {
        md += "| ${i} | ${it.title} | ${verdictLabel(it.verdict)} | ${evidenceText(it)} |\n"
        i += 1
    }
    md += "\n"

    md += "## 二、没做什么\n\n"
    var missing: Int64 = 0
    for (it in items) {
        if (it.verdict == "unknown" || it.verdict == "fail") {
            md += "- **${it.title}**：${it.note}\n"
            missing += 1
        }
    }
    if (missing == 0) {
        md += "- 无（所有清单项都有证据）\n"
    }
    md += "\n"

    md += "## 三、需要你做什么\n\n"
    var todo: Int64 = 0
    for (it in items) {
        if (it.verdict == "fail") {
            md += "- 修 ${it.title}：${it.note}\n"
            todo += 1
        }
    }
    for (it in items) {
        if (it.verdict == "unknown") {
            md += "- 补证据 ${it.title}：${it.note}\n"
            todo += 1
        }
    }
    if (todo == 0) {
        md += "- 无（可进 P7 样本矩阵）\n"
    }
    return md
}

/** 渲染 HTML 报告（同一份数据，便于直接发给评审看） */
public func renderHtml(ctx: ReportContext, items: ArrayList<CheckItem>, stats: VerifyStats): String {
    var h = "<!doctype html>\n<html lang=\"zh-CN\"><head><meta charset=\"utf-8\">\n"
    h += "<title>迁移验证报告 · ${esc(ctx.project)}</title>\n"
    h += "<style>body{font-family:system-ui,sans-serif;max-width:960px;margin:24px auto;padding:0 16px;line-height:1.6}"
    h += "table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:6px 8px;font-size:14px}"
    h += "th{background:#f5f5f5;text-align:left}.pass{color:#0a7}.fail{color:#c00}.limit{color:#a60}.unknown{color:#888}"
    h += "h1{font-size:22px}h2{font-size:17px;margin-top:26px}</style></head><body>\n"
    h += "<h1>迁移验证报告 · ${esc(ctx.project)}</h1>\n<ul>\n"
    h += "<li>包名：${esc(ctx.bundleName)}</li>\n"
    if (ctx.version != "") {
        h += "<li>版本：${esc(ctx.version)}</li>\n"
    }
    if (ctx.deviceSerial != "") {
        h += "<li>设备：${esc(ctx.deviceSerial)}</li>\n"
    }
    h += "<li>生成时间：${esc(ctx.generatedAt)}</li>\n</ul>\n"

    h += "<h2>一、做了什么</h2>\n"
    h += "<p>移植验收通过率 <b>${stats.ratePercent}%</b>（通过 ${stats.featurePass} / 有结论 ${stats.covered}）</p>\n"
    h += "<p>口径：${esc(stats.scopeNote)}</p>\n"
    if (stats.businessTotal > 0) {
        h += "<p>业务功能 ${stats.businessTotal} 条属<b>原应用职责</b>，未逐条验证" +
            "（真机冒烟 ${stats.businessTested} 条，通过 ${stats.businessPass} 条）——不计入上面的百分比</p>\n"
    }
    if (stats.notVerified > 0) {
        h += "<p>注意：有 ${stats.notVerified} 项<b>未测</b>（不计入分母）：这个百分比只代表已测的那部分</p>\n"
    }
    if (stats.limit > 0) {
        h += "<p>平台限制 ${stats.limit} 项（降级方案已落地，已剔出分母）</p>\n"
    }
    h += "<table><tr><th>#</th><th>功能项</th><th>判定</th><th>证据</th></tr>\n"
    var i: Int64 = 1
    for (it in items) {
        h += "<tr><td>${i}</td><td>${esc(it.title)}</td>"
        h += "<td class=\"${it.verdict}\">${esc(verdictLabel(it.verdict))}</td>"
        h += "<td>${esc(evidenceText(it))}</td></tr>\n"
        i += 1
    }
    h += "</table>\n"

    h += "<h2>二、没做什么</h2>\n<ul>\n"
    var missing: Int64 = 0
    for (it in items) {
        if (it.verdict == "unknown" || it.verdict == "fail") {
            h += "<li><b>${esc(it.title)}</b>：${esc(it.note)}</li>\n"
            missing += 1
        }
    }
    if (missing == 0) {
        h += "<li>无（所有清单项都有证据）</li>\n"
    }
    h += "</ul>\n"

    h += "<h2>三、需要你做什么</h2>\n<ul>\n"
    var todo: Int64 = 0
    for (it in items) {
        if (it.verdict == "fail") {
            h += "<li>修 ${esc(it.title)}：${esc(it.note)}</li>\n"
            todo += 1
        }
    }
    for (it in items) {
        if (it.verdict == "unknown") {
            h += "<li>补证据 ${esc(it.title)}：${esc(it.note)}</li>\n"
            todo += 1
        }
    }
    if (todo == 0) {
        h += "<li>无（可进 P7 样本矩阵）</li>\n"
    }
    h += "</ul>\n</body></html>\n"
    return h
}

/** 判定 → 中文标签 */
public func verdictLabel(v: String): String {
    if (v == "pass") {
        return "通过"
    }
    if (v == "fail") {
        return "失败"
    }
    if (v == "limit") {
        return "平台限制"
    }
    return "未验证"
}

/** 证据列表 → 一行文本（空列表给"无证据"，别留空白让人以为通过） */
func evidenceText(it: CheckItem): String {
    if (it.evidence.size == 0) {
        return "无证据"
    }
    var s = ""
    for (e in it.evidence) {
        if (s != "") {
            s += "；"
        }
        s += e
    }
    return s
}

/** HTML 转义（报告要给外人看，正文里的 < > & 不能当标签） */
func esc(s: String): String {
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
}

/**
 * 数 faultlog 里的崩溃记录条数（纯函数，真机实测踩过坑所以单独测）。
 *
 * 为什么不能"非空行就 +1"：`ls /data/log/faultlog/faultlogger/` 在权限不足时输出
 * `ls: ...: Permission denied`（2026-10-31 真机实测），把它当崩溃会**把"读不到"误判成"崩了"**，
 * 直接违反"未采集 ≠ 通过/失败"的口径。所以只认像崩溃记录的行。
 */
public func countCrashRecords(lsOut: String): Int64 {
    var n: Int64 = 0
    for (raw in lsOut.split("\n", -1)) {
        let line = raw.trimAscii()
        if (line == "") {
            continue
        }
        if (line.contains("Permission denied") || line.contains("No such file") || line.contains("total ")) {
            continue
        }
        if (line.endsWith(".log") || line.contains("crash") || line.startsWith("fault")) {
            n += 1
        }
    }
    return n
}

/** faultlog 目录是否**读不到**（权限/不存在）——读不到时报告里要写明，不能假装"零崩溃" */
public func faultlogUnreadable(lsOut: String): Bool {
    return lsOut.contains("Permission denied") || lsOut.contains("No such file")
}