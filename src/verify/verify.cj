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
 *   ① **分母 = 核心功能清单**（0.39.89 改）：扫描到的每条 IPC 命令就是一条核心功能，
 *      可用率 = 其中**有结论的**（pass + fail）里通过的比例。不许拿"装得上 / 编得过 / 起得来"
 *      这类**装配步骤**冒充功能可用性——用户真机实测过：⑥ 屏报 100%，
 *      而「选择文件」「保存目录」两个按钮点了**完全没反应**。
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
     * 条目类别：`gate`（装配步骤：编得过 / 装配过 / 起得来）或 `feature`（核心功能）。
     * 可用率的分母只认 `feature`——这是 0.39.89 的口径修正点。
     */
    public var kind: String = "gate"
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
 * 一条**核心功能**（A4 的分母）。来源：scan 落档的 `items.commands`——每条 IPC 命令就是一个功能。
 *
 * 为什么不能拿"装配步骤"当分母（0.39.89 用户真机实测）：⑥ 屏报「核心功能可用率 100%」，
 * 而「选择文件」「保存目录」两个按钮在真机上**点了完全没反应**——装得上 ≠ 功能能用。
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
            let attr = src[attrStart..i]
            let cfg = lastCfgAttrOf(attr)
            let brace = findFrom(src, "{", i)
            if (brace >= 0) {
                let (bs, be) = bodyRangeOf(src, brace)
                let impl = FnImpl()
                impl.isOhos = cfg.contains("ohos") && !cfg.contains("not(")
                impl.body = src[bs..be]
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
     * **核心功能**里的通过条数（`kind == "feature"` 且 verdict=pass）。
     *
     * 为什么不复用 `pass`：`pass` 含 launch/build/hap/frontend 这些装配项，而 `covered` 只数功能项。
     * 两者相除就是用户实测看到的「可用率 0%（**4/3 项有结论**）」——分子比分母还大（0.39.93）。
     */
    public var featurePass: Int64 = 0
    /** 分母的口径来源：`features`（核心功能清单）/ `gates-only`（没扫过，只能退回装配口径） */
    public var scope: String = ""
    /** 口径来源的人话解释（直接进报告，别让人猜这个百分比在算谁） */
    public var scopeNote: String = ""
    /** 可用率 = pass / covered；分母为 0 时按 0 处理（绝不"没数据就给 100"） */
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

    // ④ 核心功能逐条（**A4 的分母**）：扫描到的每条命令一条
    //   判定顺序固定：人测过 → 以人的结论为准；命中平台 API 且降级未落地 → fail；其余 → 未测
    for (f in inp.features) {
        let title = if (f.title != "") { f.title } else { f.commandName }
        let it = CheckItem("feat:${f.commandName}", title)
        it.kind = "feature"
        if (f.degradedApi != "") {
            it.evidence.add("命中平台 API：${f.degradedApi}")
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
            it.verdict = "fail"
            it.note = "「${f.degradedApi}」在鸿蒙上没有等价物，降级方案未落地 → 真机上该功能不可用（这不是平台限制）"
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
 * 按口径统计可用率（见文件头 ①②）。
 *
 * **分母优先取核心功能项**：只有一条功能明细都没有（没扫过）时，才退回装配口径，
 * 而且在 `scope / scopeNote` 里写明"这不代表功能可用"——让人一眼看出这个百分比在算谁。
 */
public func computeStats(items: ArrayList<CheckItem>): VerifyStats {
    let s = VerifyStats()
    s.total = Int64(items.size)
    for (it in items) {
        if (it.verdict == "pass") {
            s.pass += 1
        } else if (it.verdict == "limit") {
            s.limit += 1
        } else if (it.verdict == "fail") {
            s.fail += 1
        } else {
            s.unknown += 1
        }
    }
    // 核心功能面：只数功能项，limit 项照旧不进分母，未测的单列
    var featureTotal: Int64 = 0
    var fPass: Int64 = 0
    var fCovered: Int64 = 0
    var fNotVerified: Int64 = 0
    for (it in items) {
        if (it.kind != "feature") {
            continue
        }
        featureTotal += 1
        if (it.verdict == "pass") {
            fPass += 1
            fCovered += 1
        } else if (it.verdict == "fail") {
            fCovered += 1
        } else if (it.verdict == "unknown") {
            fNotVerified += 1
        }
    }
    if (featureTotal > 0) {
        s.scope = "features"
        s.scopeNote = "分母 = 核心功能清单（${featureTotal} 条来自扫描的命令），通过 ${fPass} / 有结论 ${fCovered}；" +
            "另有 ${fNotVerified} 项未测，不计入分母"
        s.covered = fCovered
        s.notVerified = fNotVerified
        s.featurePass = fPass
        if (fCovered > 0) {
            s.ratePercent = (fPass * 100) / fCovered
        }
    } else {
        s.scope = "gates-only"
        s.scopeNote = "没扫过核心功能清单 → 退回装配口径（编得过 / 装配过 / 起得来），**不代表功能可用**"
        s.covered = s.pass + s.fail
        s.notVerified = s.unknown
        // 装配口径下分子分母同源，就是全局 pass（没有功能项可数）
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
    md += "核心功能可用率 **${stats.ratePercent}%**（通过 ${stats.pass} / 有结论 ${stats.covered}）\n\n"
    md += "- 口径：${stats.scopeNote}\n"
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
    h += "<p>核心功能可用率 <b>${stats.ratePercent}%</b>（通过 ${stats.pass} / 有结论 ${stats.covered}）</p>\n"
    h += "<p>口径：${esc(stats.scopeNote)}</p>\n"
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