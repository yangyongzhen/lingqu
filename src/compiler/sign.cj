package lingqu.compiler

import std.collection.*
import std.crypto.digest.*
import std.fs.*
import stdx.crypto.digest.*
import stdx.encoding.json.*

/*
 * 鸿蒙真机签名体检（`t2h:sign`）的纯函数层。
 *
 * 背景（2026-10-31 真机实测 + 调研）：鸿蒙真机只信任「华为签发、且 profile 的 device-ids
 * 含本机 UDID」的证书。所以"能不能装"可以**完全本地判定**，不需要联网也不需要账号：
 *
 *   ① `~/.ohos/config/default_<工程>_<hash>.p7b` 是 PKCS#7 包着一个**明文 JSON**
 *      （字段：type / bundle-info.bundle-name / debug-info.device-ids）；直接按字节取 JSON 解析即可，
 *      不需要解 ASN.1（也不必像 flutter 那套一样写 DER 解析器）；
 *   ② 本机 UDID 用 `hdc shell bm get --udid` 取；
 *   ③ 两边对上 → 只要工程的 build-profile.json5 里有指向这套材料的 signingConfigs，就能直装。
 *
 * **0.39.12 起多了一件事**：口令不再只能"从别处搬"——`material/` 目录里的密钥材料本机就有，
 * 我们能按 AesGcmKit 的算法**自己加密**（见本文件末「材料生产（路线 A）」一节与
 * `docs/鸿蒙自动签名机制.md` §3.7b）。所以这套文件现在负责两半：
 *   · 体检与判断（离线，零网络）
 *   · 材料命名与口令密文（离线，纯函数，可单测）
 * 真正"上云"的部分（登录 / 证书 / profile）在命令层，靠本节的纯函数收口。
 */

/** 一份 profile 的关键信息（从 .p7b 里嵌的 JSON 解析） */
public class OhosProfile {
    public var p7bPath: String = ""
    public var profileType: String = ""   // debug / release（`type` 是仓颉关键字，不能当字段名）
    public var bundleName: String = ""
    public var deviceIds: ArrayList<String> = ArrayList<String>()
    public var parseError: String = ""

    /** 这台设备能不能用这份 profile 装 */
    public func allows(udid: String): Bool {
        if (this.profileType != "debug") {
            return false
        }
        for (d in this.deviceIds) {
            if (d == udid) {
                return true
            }
        }
        return false
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("p7b", JsonString(this.p7bPath))
        o.put("type", JsonString(this.profileType))
        o.put("bundleName", JsonString(this.bundleName))
        o.put("deviceCount", JsonInt(Int64(this.deviceIds.size)))
        o.put("parseError", JsonString(this.parseError))
        return o
    }
}

/**
 * 从 `.p7b` 原始字节（按 ASCII 净化视图）里取出内嵌的 JSON 文档。
 *
 * 实测：DevEco 生成的 profile 里 JSON 是**明文**（DER 之后紧跟），但从第一个 `{` 扫到
 * **深度归零**的那个 `}` 才算安全——后面是证书等二进制，高位字节虽被净化为空格，
 * 但 `0x7D` 会原样留下成 `}`，"取最后一个 `}`" 会把尾部垃圾带进 JSON（实测撞过）。
 * 扫描时按字符串字面量/转义规则跳过，避免 `"..."` 里的花括号干扰配对。
 */
public func extractProfileJson(raw: String): String {
    let bytes = raw.toArray()
    let openBrace: UInt8 = 123
    let closeBrace: UInt8 = 125
    let dquote: UInt8 = 34
    let backslash: UInt8 = 92
    var start: Int64 = -1
    for (i in 0..bytes.size) {
        if (bytes[i] == openBrace) {
            start = i
            break
        }
    }
    if (start < 0) {
        return ""
    }
    var depth: Int64 = 0
    var inStr = false
    var esc = false
    var i = start
    while (i < bytes.size) {
        let c = bytes[i]
        if (inStr) {
            if (esc) {
                esc = false
            } else if (c == backslash) {
                esc = true
            } else if (c == dquote) {
                inStr = false
            }
        } else if (c == dquote) {
            inStr = true
        } else if (c == openBrace) {
            depth++
        } else if (c == closeBrace) {
            depth--
            if (depth == 0) {
                return String.fromUtf8(bytes[start..(i + 1)])
            }
        }
        i++
    }
    return ""
}

/** 解析 profile 内嵌 JSON（结构：type / bundle-info.bundle-name / debug-info.device-ids） */
public func parseOhosProfile(json: String, p7bPath: String): OhosProfile {
    let p = OhosProfile()
    p.p7bPath = p7bPath
    let text = json.trimAscii()
    if (text.size == 0) {
        p.parseError = "profile 里没找到 JSON 文档"
        return p
    }
    var root: JsonValue
    try {
        root = JsonValue.fromStr(text)
    } catch (e: Exception) {
        p.parseError = "profile JSON 解析失败：${e}"
        return p
    }
    match (root.kind()) {
        case JsonKind.JsObject => ()
        case _ =>
            p.parseError = "profile JSON 不是对象"
            return p
    }
    let obj = root.asObject()
    p.profileType = strFieldOf(obj, "type")
    // bundle-name 在 bundle-info 里
    match (obj.get("bundle-info")) {
        case Some(bi) => match (bi.kind()) {
            case JsonKind.JsObject =>
                p.bundleName = strFieldOf(bi.asObject(), "bundle-name")
            case _ => ()
        }
        case None => ()
    }
    if (p.bundleName == "") {
        p.bundleName = strFieldOf(obj, "bundle-name")
    }
    // device-ids 在 debug-info 里（个别版本在顶层）
    var ids = arrFieldOf(obj, "device-ids")
    if (ids.size == 0) {
        match (obj.get("debug-info")) {
            case Some(di) => match (di.kind()) {
                case JsonKind.JsObject => ids = arrFieldOf(di.asObject(), "device-ids")
                case _ => ()
            }
            case None => ()
        }
    }
    p.deviceIds = ids
    return p
}

func strFieldOf(o: JsonObject, key: String): String {
    match (o.get(key)) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsString => return v.asString().getValue()
            case _ => return ""
        }
        case None => return ""
    }
}

func arrFieldOf(o: JsonObject, key: String): ArrayList<String> {
    let out = ArrayList<String>()
    match (o.get(key)) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsArray =>
                let arr = v.asArray()
                for (i in 0..arr.size()) {
                    let e = arr.get(i).getOrThrow()
                    match (e.kind()) {
                        case JsonKind.JsString => out.add(e.asString().getValue())
                        case _ => ()
                    }
                }
            case _ => ()
        }
        case None => ()
    }
    return out
}

/** `.p7b` 路径 → 同名的 `.p12` / `.cer`（DevEco 的命名规则：同 base 不同后缀） */
public func materialSiblingsOf(p7bPath: String): (String, String) {
    var base = p7bPath
    if (base.endsWith(".p7b")) {
        base = base[0..(base.size - 4)]
    }
    return ("${base}.p12", "${base}.cer")
}

/**
 * 工程 `build-profile.json5` 里与签名相关的信息。
 *
 * 为什么不用 JSON 库：`build-profile.json5` 是 **JSON5**（允许注释、尾逗号、单引号、无引号键），
 * 严格 JSON 解析器会直接报错。我们只关心几个固定键，按"键 → 下一个值"轻量提取足够，
 * 也免得为 json5 引第三方库。
 */
public class ProjSigning {
    /** 是否有非空的 `signingConfigs` 数组 */
    public var hasSigningConfigs: Bool = false
    /** `products[].signingConfig` 的值（空 = 没挂到 product 上） */
    public var signingConfigName: String = ""
    /** signingConfigs[].material.certpath */
    public var certPath: String = ""
    /** signingConfigs[].material.profile */
    public var profilePath: String = ""
    /** signingConfigs[].material.storeFile */
    public var storeFile: String = ""
    /** signingConfigs[].type（HarmonyOS / OpenHarmony） */
    public var certType: String = ""
}

/** 从 JSON5 文本里取 `"key"` 之后的值（支持双引号/单引号/裸值；取不到返回 ""） */
public func json5ValueAfter(text: String, key: String): String {
    let marker = "\"${key}\""
    let at = text.indexOf(marker)
    var pos: Int64 = 0
    match (at) {
        case Some(i) => pos = i + marker.size
        case None =>
            // 无引号键（JSON5 允许）：退化成找 key 后跟冒号
            match (text.indexOf("${key}:")) {
                case Some(j) => pos = j + key.size
                case None => return ""
            }
    }
    let bytes = text.toArray()
    var i = pos
    // 跳到冒号
    while (i < bytes.size && bytes[i] != 58 && bytes[i] != 10 && bytes[i] != 13) {
        i++
    }
    if (i >= bytes.size || bytes[i] != 58) {
        return ""
    }
    i++
    // 跳过空白
    while (i < bytes.size && (bytes[i] == 32 || bytes[i] == 9 || bytes[i] == 10 || bytes[i] == 13)) {
        i++
    }
    if (i >= bytes.size) {
        return ""
    }
    let dq: UInt8 = 34
    let sq: UInt8 = 39
    if (bytes[i] == dq || bytes[i] == sq) {
        let q = bytes[i]
        i++
        let begin = i
        var esc = false
        while (i < bytes.size) {
            let c = bytes[i]
            if (esc) {
                esc = false
            } else if (c == 92) {
                esc = true
            } else if (c == q) {
                return unescapeJson5(String.fromUtf8(bytes[begin..i]))
            }
            i++
        }
        return ""
    }
    // 裸值：读到分隔符为止
    let begin = i
    while (i < bytes.size) {
        let c = bytes[i]
        if (c == 44 || c == 125 || c == 93 || c == 10 || c == 13 || c == 32 || c == 9) {
            break
        }
        i++
    }
    return String.fromUtf8(bytes[begin..i])
}

/**
 * JSON5 字符串值的转义还原。
 *
 * 为什么必须做：Windows 上 `build-profile.json5` 的路径写成 `"D:\\oh\\...\\x.cer"`，
 * 不还原就带着双反斜杠去做 `exists()` 判断 → 永远"文件不存在"（真机上会误判成签名缺失）。
 * 只处理常见转义（`\\` `\/` `\"` `\n` `\t` `\r` `\b` `\f`），`\uXXXX` 与过长转义按原样保留。
 */
public func unescapeJson5(raw: String): String {
    let bytes = raw.toArray()
    let out = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < bytes.size) {
        let c = bytes[i]
        if (c != 92 || i + 1 >= bytes.size) {
            out.add(c)
            i++
            continue
        }
        let n = bytes[i + 1]
        if (n == 110) {          // n
            out.add(10)
        } else if (n == 116) {   // t
            out.add(9)
        } else if (n == 114) {   // r
            out.add(13)
        } else if (n == 98) {    // b
            out.add(8)
        } else if (n == 102) {   // f
            out.add(12)
        } else if (n == 117) {   // u：不还原，原样保留（路径里不该出现）
            out.add(c)
            out.add(n)
            i += 2
            continue
        } else {
            // \\ \" \/ \' 等：反斜杠是转义符，丢掉它只留字符
            out.add(n)
        }
        i += 2
    }
    return String.fromUtf8(out.toArray())
}

/** 解析 `build-profile.json5` 文本 → 签名相关信息 */
public func parseProjSigning(text: String): ProjSigning {
    let s = ProjSigning()
    if (text == "") {
        return s
    }
    s.signingConfigName = json5ValueAfter(text, "signingConfig")
    s.certPath = json5ValueAfter(text, "certpath")
    s.profilePath = json5ValueAfter(text, "profile")
    s.storeFile = json5ValueAfter(text, "storeFile")
    s.certType = json5ValueAfter(text, "type")
    // signingConfigs 是否非空：定位键后看紧邻的 `[` 里是不是立刻 `]`
    // 键可能是带引号的 `"signingConfigs"`，也可能是 JSON5 的裸键 `signingConfigs:`
    var from: Int64 = -1
    match (text.indexOf("\"signingConfigs\"")) {
        case Some(at) => from = at + "\"signingConfigs\"".size
        case None => match (text.indexOf("signingConfigs:")) {
            case Some(at) => from = at + "signingConfigs:".size
            case None => ()
        }
    }
    if (from >= 0) {
        let bytes = text.toArray()
        var i = from
        var sawOpen = false
        while (i < bytes.size) {
            let c = bytes[i]
            if (c == 91) {   // [
                sawOpen = true
                i++
                break
            }
            if (c == 123 || c == 34 || c == 93) {   // { " ]
                break
            }
            i++
        }
        if (sawOpen) {
            while (i < bytes.size) {
                let c = bytes[i]
                if (c == 93) {   // ]
                    break
                }
                if (c == 32 || c == 9 || c == 10 || c == 13 || c == 44) {
                    i++
                    continue
                }
                s.hasSigningConfigs = true
                break
            }
        }
    }
    return s
}

/**
 * 从 `hdc shell bm get --udid` 的输出里取 UDID。
 *
 * 不按固定排版解析（不同 hdc/系统版本前缀文案会变：`udid of current device is :` 之类），
 * 而是**取最长的连续十六进制串**（≥16 位）—— UDID 本身是 32/64 位十六进制，
 * 比去猜前缀稳得多。找不到返回 ""。
 */
public func parseUdid(out: String): String {
    let bytes = out.toArray()
    var best = ""
    var i: Int64 = 0
    while (i < bytes.size) {
        if (isHexDigit(bytes[i])) {
            let begin = i
            while (i < bytes.size && isHexDigit(bytes[i])) {
                i++
            }
            if (i - begin >= 16) {
                let cand = String.fromUtf8(bytes[begin..i])
                if (cand.size > best.size) {
                    best = cand
                }
            }
        } else {
            i++
        }
    }
    return best
}

func isHexDigit(b: UInt8): Bool {
    return (b >= 48 && b <= 57) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102)
}

/** 签名体检结论 */
public class SignCheck {
    public var ok: Bool = false
    /** 不能装时的原因（给人看的一句话） */
    public var reason: String = ""
    /** 可执行的下一步 */
    public var nextStep: String = ""
    /** 工程 build-profile.json5 里配的 signingConfig 名（空 = 没配） */
    public var configuredName: String = ""
    /** 工程配的材料是否存在 */
    public var configuredFilesExist: Bool = false
    /** 工程配的 profile 是否含本机 UDID */
    public var configuredAllowsDevice: Bool = false
    /** 本机 UDID */
    public var udid: String = ""
    /**
     * 本机候选材料的**包名**是否等于工程 `AppScope/app.json5` 的 bundleName。
     *
     * 不是"锦上添花"的字段：hvigor 在签名阶段会校验它，不匹配直接失败（0.39.9 实测）——
     * 所以"机器上有含本机 UDID 的材料"并不等于"能写回"。默认 true（不涉及候选的路径不受影响）。
     */
    public var bundleMatch: Bool = true

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("ok", JsonBool(this.ok))
        o.put("reason", JsonString(this.reason))
        o.put("nextStep", JsonString(this.nextStep))
        o.put("configuredName", JsonString(this.configuredName))
        o.put("configuredFilesExist", JsonBool(this.configuredFilesExist))
        o.put("configuredAllowsDevice", JsonBool(this.configuredAllowsDevice))
        o.put("udid", JsonString(this.udid))
        o.put("bundleMatch", JsonBool(this.bundleMatch))
        return o
    }
}

/**
 * 纯判定：给定「工程的签名配置是否齐全」+「配置所用 profile 是否含本机 UDID」，
 * 给出能否直装与下一步。`hasConfig=false` 时用 `candidate`（同 UDID 的可用材料）给出建议。
 */
public func judgeSign(hasConfig: Bool, filesExist: Bool, allowsDevice: Bool, profileType: String,
    udid: String, hasCandidate: Bool): SignCheck {
    let c = SignCheck()
    c.udid = udid
    c.configuredFilesExist = filesExist
    c.configuredAllowsDevice = allowsDevice
    if (udid == "") {
        c.ok = false
        c.reason = "拿不到设备 UDID（设备没连？跑 `hdc shell bm get --udid` 看看）"
        c.nextStep = "连上鸿蒙设备并开启 USB 调试后重试"
        return c
    }
    if (!hasConfig) {
        c.ok = false
        c.reason = "工程的 build-profile.json5 里没有 signingConfigs（或 products 没指 signingConfig）"
        if (hasCandidate) {
            c.nextStep = "机器上已有匹配本机 UDID 的材料：把历史/其它工程里那份 signingConfigs 抄回 build-profile.json5（口令是 DevEco 加密串，hvigor 会解密），然后重跑 hvigor assembleHap"
        } else {
            c.nextStep = "在 DevEco 里勾一次「Automatically generate signature」（需华为账号，会把本机 UDID 注册进 profile），或走 AGC 自动签名流程"
        }
        return c
    }
    if (!filesExist) {
        c.ok = false
        c.reason = "signingConfigs 指向的 .p12/.cer/.p7b 有文件不存在（材料被删/换机器）"
        c.nextStep = "确认 certify/profile/storeFile 三个路径都存在；缺了就在 DevEco 里重新自动签名一次"
        return c
    }
    if (profileType != "debug") {
        c.ok = false
        c.reason = "当前 signingConfig 用的是 ${profileType} profile（上架用，不含 device-ids），真机直装必失败 9568322"
        c.nextStep = "products.<product>.signingConfig 切到 debug 那份（上架前再切回 release）"
        return c
    }
    if (!allowsDevice) {
        c.ok = false
        c.reason = "profile 的 device-ids 里没有本机 UDID（设备没注册进这份 profile）"
        c.nextStep = "在 DevEco 里自动签名一次把本机注册进去，或换一份含本机 UDID 的材料"
        return c
    }
    c.ok = true
    c.reason = "签名配置齐全，且 profile 绑定了本机 UDID，可直装"
    c.nextStep = "hvigor assembleHap → hdc install -r → aa start"
    return c
}

// ============================================================
// 包名门槛：**签名材料的 bundle-name 必须等于工程的 bundleName**（0.39.9 实测）
// ============================================================
//
// 0.39.7 的遗留问题写的是"材料文件不存在"，照那个改法（换成 ~/.ohos/config 里现存的另一套）
// 仍然装不上：hvigor 在 `default@SignHap` 直接拦下并报
//
//     00303074 Configuration Error
//     The bundleName in app.json5/hvigorfile.ts does not match the bundleName in the
//     generated SigningConfigs.
//
// 也就是说：**profile 是按包名签发的**。"机器上有含本机 UDID 的材料"只过了两道门里的一道，
// 另一道是包名。所以这里把包名独立成一条判定，而不是塞进 `filesExist` 之类的开关里——
// 否则工具会给出"抄回来即可"这种**照着做也失败**的建议（比不说更糟）。
//
// 正解只有一条：在 DevEco 里对**该工程**点一次自动签名（需登录华为账号），
// 由签名服务按这个包名签发 profile。它属于必须计入 A3 的人工介入，工具要做的是
// **一次说清**（哪个包名缺、本机有哪些包名、hvigor 会报什么码、该点哪里），别让人试错。

/** hvigor 的包名不匹配错误码（写进 reason 里，方便按报错原文检索） */
public let SIGN_BUNDLE_MISMATCH_CODE: String = "00303074"

/** 候选材料的包名是否等于工程包名（两边都非空且逐字符相等；bundleName 区分大小写） */
public func bundleMatches(projectBundle: String, candidateBundle: String): Bool {
    let a = projectBundle.trimAscii()
    let b = candidateBundle.trimAscii()
    if (a == "" || b == "") {
        return false
    }
    return a == b
}

/**
 * 本机材料的包名清单（回答"为什么没有我这个包名的"）：`com.a(27台/含本机)、com.b(26台/含本机)`。
 *
 * 空目录返回 ""；解析失败的份不列（列出来只会误导）。
 */
public func profileBundleCensus(cands: ArrayList<OhosProfile>, udid: String): String {
    var text = ""
    for (p in cands) {
        if (p.parseError != "" || p.bundleName == "") {
            continue
        }
        if (text != "") {
            text += "、"
        }
        let allows = if (udid == "") { "UDID未知" } else if (p.allows(udid)) { "含本机" } else {
            "不含本机"
        }
        text += "${p.bundleName}(${p.deviceIds.size}台/${allows})"
    }
    return text
}

/**
 * 把包名门槛叠到体检结论上（纯函数，`judgeSign` 的补充而不是替代）。
 *
 * 只在"需要走候选材料"的两条路径上动结论（没配签名 / 配了但材料缺），且**只在包名不匹配时**改：
 * 已经能装（ok=true）的工程原样返回——它用的材料当然是匹配的那个包名的。
 *
 * 返回**副本**（不改入参，方便调用方保留原始判定做对照）。
 */
public func judgeSignForWriteback(c: SignCheck, projectBundle: String, candidateBundle: String,
    census: String): SignCheck {
    let out = SignCheck()
    out.ok = c.ok
    out.reason = c.reason
    out.nextStep = c.nextStep
    out.configuredName = c.configuredName
    out.configuredFilesExist = c.configuredFilesExist
    out.configuredAllowsDevice = c.configuredAllowsDevice
    out.udid = c.udid
    out.bundleMatch = bundleMatches(projectBundle, candidateBundle)
    if (out.ok || out.bundleMatch) {
        return out
    }
    if (candidateBundle.trimAscii() == "") {
        // 压根没有候选材料（没连设备 / 目录里没有 .p7b）：judgeSign 自查给出的那句话已经够具体，
        // 再叠一层"包名不一致"只会误导（实测：设备离线时 udid="" 就会走到这里）
        return out
    }
    if (projectBundle.trimAscii() == "") {
        // 读不到工程包名：**不能**断言"包名不一致"（那是编事实）。只提示先确认 AppScope
        out.reason = "${out.reason}；读不到工程 AppScope/app.json5 的 bundleName，无法判断候选材料是否匹配"
        return out
    }
    // 候选材料是"别的包名"，写回/抄过来都会在 hvigor 的 SignHap 阶段被 00303074 拦下
    let mine = if (projectBundle == "") { "（工程 AppScope/app.json5 里没读到 bundleName）" } else {
        "`${projectBundle}`"
    }
    let others = if (census == "") { "（本机 ~/.ohos/config 里没有可解析的材料）" } else { census }
    let tail = "工程包名 ${mine} 没有对应的签名材料（profile 按包名签发）。" +
        "本机现有材料的包名：${others}。" +
        "hvigor 写回/抄用别的包名的材料会报 ${SIGN_BUNDLE_MISMATCH_CODE}" +
        "（bundleName 与 SigningConfigs 不一致）。"
    let how = "在 DevEco 里对**本工程**点一次「Automatically generate signature」" +
        "（需登录华为账号，会把本机 UDID 注册进这个包名的 profile）；" +
        "或把 AppScope/app.json5 的 bundleName 临时改成上面某个已有包名（仅限本机验证，别用于交付）。"
    out.reason = "${out.reason}；工程包名 ${mine} 与候选材料包名不一致"
    out.nextStep = tail + how
    return out
}

// ============================================================
// 装配前的签名预检（0.39.11）：能秒级说清的事，别让 hvigor 跑三分钟去说
// ============================================================
//
// 实测动机（m3u8dl-tauri）：`t2h:hap` 先跑 `hvigor assembleHap`（分钟级），最后只换来一句
// `00303074`——而"签名材料的包名与工程 bundleName 不一致"这件事**跑之前**就能判定。
// agent 的轮次预算是稀缺资源（ADR D-015：工具要"好用"，不只是"正确"）。

/** 装配前签名预检的结论 */
public class SignPreflight {
    /** true = 别跑 hvigor 了，必然失败 */
    public var block: Bool = false
    /** 拦下/提示的原因（空 = 一切正常） */
    public var reason: String = ""
    /** 工程 `AppScope/app.json5` 的 bundleName（读不到为空） */
    public var projectBundle: String = ""
    /** 已配 profile 的 bundle-name（读不到为空） */
    public var profileBundle: String = ""

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("block", JsonBool(this.block))
        o.put("reason", JsonString(this.reason))
        o.put("projectBundle", JsonString(this.projectBundle))
        o.put("profileBundle", JsonString(this.profileBundle))
        return o
    }
}

/**
 * 纯判定（不读盘，调用方把事实传进来）。三条规则——**只在真的必然失败时才拦**：
 *
 *   ① 没配 signingConfigs → 不拦（不签名也能产 HAP；闸门会如实报"未签名"）
 *   ② 配了但材料文件不存在 → **不拦**，只留提示（hvigor 报 00303107，但 unsigned HAP 仍可能产出，
 *      对"只想看看包里有什么"的人还有用）
 *   ③ 材料存在但 profile 的 bundle-name ≠ 工程 bundleName → **拦**（hvigor 必然 00303074，
 *      一个产物都不会有，白等三分钟）
 */
public func judgeSignPreflight(hasConfig: Bool, profileExists: Bool, projectBundle: String,
    profileBundle: String): SignPreflight {
    let out = SignPreflight()
    out.projectBundle = projectBundle
    out.profileBundle = profileBundle
    if (!hasConfig) {
        return out
    }
    if (!profileExists) {
        out.reason = "签名材料文件不存在（hvigor 会报 00303107 Invalid storeFile）：先跑「签名体检」" +
            "确认 build-profile.json5 里 certify/profile/storeFile 三个路径"
        return out
    }
    if (projectBundle.trimAscii() == "") {
        // 读不到工程包名（AppScope 里的写法超出轻量 json5 提取能力）：不拦，交给 hvigor 自己判
        out.reason = "读不到工程 AppScope/app.json5 的 bundleName，签名预检跳过（hvigor 会自己判定）"
        return out
    }
    if (!bundleMatches(projectBundle, profileBundle)) {
        out.block = true
        out.reason = "工程包名 `${projectBundle}` 与已配签名材料的包名 `${profileBundle}` 不一致" +
            "（hvigor 必然报 ${SIGN_BUNDLE_MISMATCH_CODE}，一个产物都不会有）：" +
            "在 DevEco 里对本工程自动签名一次，或把 signingConfig 换成本机同包名的材料"
    }
    return out
}

// ============================================================
// T5-4 签名两态（debug / release）+ 上架前强提醒
// ============================================================
//
// 两态的**用途不同，不能互相替代**（这是本模块唯一要讲清的事）：
//
//   debug   —— profile 含 device-ids，只认已注册的设备；能直装真机做验证，**不能上架**
//              （AGC 不接受 debug 证书）
//   release —— profile 不含 device-ids，可上架；**直装真机必被 9568322 拒**（这是正常的）
//
// 所以工具的价值不是"帮你签名"，而是**在正确的时机说清楚"你现在是哪一态、另一态该怎么切"**：
//   · 开发期忘了切 debug → 装机失败（0.18.0 的 judgeSign 已经在拦）
//   · 上架前忘了切 release → 提交审核被拒（本案要补的那一半）
// 判定全部是纯函数，可单测；读盘/跑 hdc 在命令层。

public let SIGN_MODE_DEBUG: String = "debug"
public let SIGN_MODE_RELEASE: String = "release"
public let SIGN_MODE_UNKNOWN: String = "unknown"

/** 签名态评估（`t2h:sign` 回投、⑤ 屏渲染、报告引用都用这一个结构，避免各处各说一套） */
public class SignModeState {
    /** 当前工程配置所处的态：debug / release / unknown */
    public var mode: String = SIGN_MODE_UNKNOWN
    /** 给人看的一行态名 */
    public var modeLabel: String = ""
    /** 能不能直装真机（= debug 且材料齐全） */
    public var canInstallDevice: Bool = false
    /** 是否具备上架条件（= release 且材料齐全）；真正上传 AGC 还有隐私/图标等非签名项 */
    public var releaseReady: Bool = false
    /** 强提醒（上架前必须看到的那句话；unknown 态也给出说明） */
    public var reminder: String = ""
    /** 想装真机时的下一步 */
    public var installNextStep: String = ""
    /** 想上架时的下一步 */
    public var releaseNextStep: String = ""
    /** 切到目标态的步骤清单 */
    public var switchSteps: ArrayList<String> = ArrayList<String>()
    /** 本机 `~/.ohos/config` 里可解析的 release profile 份数（0 说明还没做过 release 签名） */
    public var releaseProfileCount: Int64 = 0

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("mode", JsonString(this.mode))
        o.put("modeLabel", JsonString(this.modeLabel))
        o.put("canInstallDevice", JsonBool(this.canInstallDevice))
        o.put("releaseReady", JsonBool(this.releaseReady))
        o.put("reminder", JsonString(this.reminder))
        o.put("installNextStep", JsonString(this.installNextStep))
        o.put("releaseNextStep", JsonString(this.releaseNextStep))
        o.put("releaseProfileCount", JsonInt(this.releaseProfileCount))
        var arr = JsonArray()
        for (s in this.switchSteps) {
            arr.add(JsonString(s))
        }
        o.put("switchSteps", arr)
        return o
    }
}

/**
 * 纯判定：工程当前的签名态。
 *
 * 只看 profile 的 `type` 字段——`hasConfig=false`（没配 signingConfigs）时无从判断，
 * 给 unknown 而不是猜成 debug：**猜错会让人以为"能装"，这个代价太贵**。
 */
public func judgeSignMode(hasConfig: Bool, profileType: String): String {
    if (!hasConfig) {
        return SIGN_MODE_UNKNOWN
    }
    if (profileType == SIGN_MODE_DEBUG) {
        return SIGN_MODE_DEBUG
    }
    if (profileType == SIGN_MODE_RELEASE) {
        return SIGN_MODE_RELEASE
    }
    return SIGN_MODE_UNKNOWN
}

/** 态名（界面与报告共用一份措辞） */
public func signModeLabel(mode: String): String {
    if (mode == SIGN_MODE_DEBUG) {
        return "debug（开发直装）"
    }
    if (mode == SIGN_MODE_RELEASE) {
        return "release（上架）"
    }
    return "未判定"
}

/**
 * 上架前强提醒（**这一句是 T5-4 的核心交付**）。
 *
 * debug 态必须明确写出"不能上架 + 上架前要切回 release"——上架被拒的成本远高于多一句提醒。
 */
public func signModeReminder(mode: String): String {
    if (mode == SIGN_MODE_DEBUG) {
        return "⚠ 当前是 debug 签名：profile 绑定了本机 UDID，只能装到已注册设备，**不能上架**" +
            "（AGC 不接受 debug 证书）。上架前必须切回 release profile 并重新签名。"
    }
    if (mode == SIGN_MODE_RELEASE) {
        return "当前是 release 签名：可以上架。真机直装会被 9568322 拒（release profile 不含 " +
            "device-ids），这是正常的——真机验证请切回 debug 那份。"
    }
    return "无法判定签名态：工程没配 signingConfigs，或 profile 读取/解析失败。" +
        "先跑一次「签名体检」，没配的话点「写回签名配置」。"
}

/** 切到 release 的步骤（上架前照着做；顺序不能乱，第 1 步没做后面全是空谈） */
public func signReleaseSteps(): ArrayList<String> {
    let out = ArrayList<String>()
    out.add("在 AGC（AppGallery Connect）或 DevEco 里生成 **release 证书**（.cer）+ **release profile**（.p7b，不含 device-ids）")
    out.add("把 .p12 / .cer / .p7b 三个文件放进工程（或记下绝对路径）")
    out.add("build-profile.json5：新增（或切换）一份 release 的 signingConfigs，并让 products.<product>.signingConfig 指过去")
    out.add("重跑「装配 HAP」——产出 release 签名包（本工具会校验签名态仍是 release）")
    out.add("上传 AGC 前再跑一次「签名体检」确认 mode=release（debug 包被拒是常见返工原因）")
    return out
}

/** 切回 debug 的步骤（要装真机验证时照着做） */
public func signDebugSteps(): ArrayList<String> {
    let out = ArrayList<String>()
    out.add("把 products.<product>.signingConfig 切回含本机 UDID 的 debug 那份")
    out.add("工程没有 debug 材料时，点「写回签名配置」（t2h:sign apply）从本机同套材料的工程抄回")
    out.add("重跑「装配 HAP」，再「安装并启动」（hdc install -r → aa start）")
    return out
}

/**
 * 两态汇总：给界面/报告一个"当前态 + 两个方向怎么走"的完整结论。
 *
 * `releaseProfileCount` 是本机可解析的 release profile 份数——0 说明还没做过 release 签名，
 * 提醒里要能体现这一点（否则人以为是"切一下开关"那么简单）。
 */
public func assessSignMode(hasConfig: Bool, filesExist: Bool, profileType: String,
    releaseProfileCount: Int64): SignModeState {
    let st = SignModeState()
    st.mode = judgeSignMode(hasConfig, profileType)
    st.modeLabel = signModeLabel(st.mode)
    st.releaseProfileCount = releaseProfileCount
    st.reminder = signModeReminder(st.mode)
    st.canInstallDevice = st.mode == SIGN_MODE_DEBUG && filesExist
    st.releaseReady = st.mode == SIGN_MODE_RELEASE && filesExist
    if (st.mode == SIGN_MODE_RELEASE) {
        st.installNextStep = "要装真机请先切回 debug（见下），release 包直装会被拒是正常的"
        st.switchSteps = signDebugSteps()
    } else if (st.mode == SIGN_MODE_DEBUG) {
        st.installNextStep = "hvigor assembleHap → hdc install -r → aa start（debug 态已可直装）"
        if (releaseProfileCount == 0) {
            st.releaseNextStep = "上架前：本机还没有 release profile（~/.ohos/config 里 0 份），" +
                "先去 AGC 生成 release 证书与 profile，再按下面步骤切"
        } else {
            st.releaseNextStep = "上架前：把 signingConfig 切到 release 那份（本机已有 ${releaseProfileCount} 份 release profile）"
        }
        st.switchSteps = signReleaseSteps()
    } else {
        st.installNextStep = "先配好签名（t2h:sign apply 写回，或在 DevEco 里自动签名一次）"
        st.releaseNextStep = "先确认签名态，再谈上架"
        let steps = signDebugSteps()
        for (s in steps) {
            st.switchSteps.add(s)
        }
    }
    return st
}

/** 扫 `~/.ohos/config` 下的 `.p7b`，返回能解析的 profile 列表（解析失败也收，带 parseError） */
public func discoverProfiles(configDir: String): ArrayList<OhosProfile> {    let out = ArrayList<OhosProfile>()
    if (!exists(Path(configDir))) {
        return out
    }
    var entries: Array<FileInfo>
    try {
        entries = Directory.readFrom(configDir)
    } catch (e: Exception) {
        let _ = e
        return out
    }
    for (info in entries) {
        if (info.isDirectory() || !info.name.endsWith(".p7b")) {
            continue
        }
        let p = "${configDir}/${info.name}"
        try {
            let raw = latin1Of(File.readFrom(p))
            out.add(parseOhosProfile(extractProfileJson(raw), p))
        } catch (e: Exception) {
            let bad = OhosProfile()
            bad.p7bPath = p
            bad.parseError = "读不到：${e}"
            out.add(bad)
        }
    }
    return out
}

/**
 * 字节 → **ASCII 净化视图**：可打印 ASCII 原样保留，其余（高位/控制字节）统一换成空格。
 *
 * 为什么不用 `String.fromUtf8` 直接转：`.p7b` 是 PKCS#7 二进制，高位字节不是合法 UTF-8，
 * 强转会吞字节或抛错，实测把内嵌 JSON 破成 `Unexpected character: '?'`。
 * 而我们要找的 JSON 段全是 ASCII（键名、包名、UDID、base64 证书），净化后反而更稳。
 */
public func latin1Of(data: Array<UInt8>): String {
    let view = Array<UInt8>(data.size, repeat: 32)
    for (i in 0..data.size) {
        let b = data[i]
        if (b >= 32 && b <= 126) {
            view[i] = b
        }
    }
    return String.fromUtf8(view)
}

/** 在候选材料里挑「type=debug 且含本机 UDID」的那份；bundle 非空时还要包名一致 */
public func pickProfile(cands: ArrayList<OhosProfile>, udid: String, bundle: String): Option<OhosProfile> {
    for (p in cands) {
        if (!p.allows(udid)) {
            continue
        }
        if (bundle != "" && p.bundleName != bundle) {
            continue
        }
        return Some(p)
    }
    return None
}

// ============================================================
// 写回签名配置（apply）：把"体检通过但工程没配"变成"配好了"
// ============================================================
//
// 为什么需要"抄别人的 signingConfigs"而不是自己造口令：
// `storePassword` / `keyPassword` 是 **DevEco AesGcmKit 密文**，密钥在 `.p12` 旁边的
// `material/` 目录里（PBKDF2 + AES-128-GCM，见 docs/鸿蒙自动签名机制.md §3.7b）。
// 我们**拿不到明文口令**（它是随机生成的，只以密文存在），所以只能：
//   ① 找一台/一个已经用**同一套材料**的工程（donor），把它那段 signingConfigs 原样搬过来；
//   ② 或者让用户去 DevEco 点一次自动签名。
// 好在"同一套材料"= 同一个 `.p12` 文件 → 口令密文通用，搬家是安全的。

/** 一段 signingConfigs 里 material 的字段（口令是密文，原样搬运） */
public class SigningMaterial {
    public var name: String = "default"
    public var certType: String = "HarmonyOS"
    public var storeFile: String = ""
    public var storePassword: String = ""
    public var keyAlias: String = "debugKey"
    public var keyPassword: String = ""
    public var signAlg: String = "SHA256withECDSA"
    public var profile: String = ""
    public var certpath: String = ""

    /** 口令齐了才算可用（缺口令的块搬过去 hvigor 也解不开） */
    public func complete(): Bool {
        if (this.storeFile == "" || this.profile == "" || this.certpath == "") {
            return false
        }
        return this.storePassword != "" && this.keyPassword != ""
    }
}

/** 路径取文件名（两种分隔符都认） */
public func fileNameOf(p: String): String {
    var cut: Int64 = -1
    let bytes = p.toArray()
    for (i in 0..bytes.size) {
        if (bytes[i] == 47 || bytes[i] == 92) {
            cut = i
        }
    }
    if (cut < 0) {
        return p
    }
    return p[(cut + 1)..]
}

/** 两个路径是不是指向同一份材料（只比文件名：材料都在 ~/.ohos/config 下，文件名即身份） */
public func sameMaterialFile(a: String, b: String): Bool {
    if (a == "" || b == "") {
        return false
    }
    return lowerAsciiOf(fileNameOf(a)) == lowerAsciiOf(fileNameOf(b))
}

/** ASCII 小写化（不用 String 的大小写 API，避免踩标准库细节） */
func lowerAsciiOf(s: String): String {
    let bytes = s.toArray()
    for (i in 0..bytes.size) {
        let b = bytes[i]
        if (b >= 65 && b <= 90) {
            bytes[i] = b + 32
        }
    }
    return String.fromUtf8(bytes)
}

/** 从工程 `build-profile.json5` 文本里读出那份 signingConfigs 的字段（读不到字段就留空） */
public func signingMaterialOf(text: String): SigningMaterial {
    let m = SigningMaterial()
    let name = json5ValueAfter(text, "name")
    if (name != "") {
        m.name = name
    }
    let t = json5ValueAfter(text, "type")
    if (t != "") {
        m.certType = t
    }
    m.storeFile = json5ValueAfter(text, "storeFile")
    m.storePassword = json5ValueAfter(text, "storePassword")
    let alias = json5ValueAfter(text, "keyAlias")
    if (alias != "") {
        m.keyAlias = alias
    }
    m.keyPassword = json5ValueAfter(text, "keyPassword")
    let alg = json5ValueAfter(text, "signAlg")
    if (alg != "") {
        m.signAlg = alg
    }
    m.profile = json5ValueAfter(text, "profile")
    m.certpath = json5ValueAfter(text, "certpath")
    return m
}

/** 按 DevEco 的结构生成 `signingConfigs` 数组里的那一块（缩进按 indent 对齐） */
public func signingBlockJson5(m: SigningMaterial, indent: String): String {
    let i1 = indent
    let i2 = indent + "  "
    let i3 = indent + "    "
    return "${i1}{\n" +
        "${i2}\"name\": \"${m.name}\",\n" +
        "${i2}\"type\": \"${m.certType}\",\n" +
        "${i2}\"material\": {\n" +
        "${i3}\"certpath\": \"${json5EscapeOf(m.certpath)}\",\n" +
        "${i3}\"storePassword\": \"${m.storePassword}\",\n" +
        "${i3}\"keyAlias\": \"${m.keyAlias}\",\n" +
        "${i3}\"keyPassword\": \"${m.keyPassword}\",\n" +
        "${i3}\"profile\": \"${json5EscapeOf(m.profile)}\",\n" +
        "${i3}\"signAlg\": \"${m.signAlg}\",\n" +
        "${i3}\"storeFile\": \"${json5EscapeOf(m.storeFile)}\"\n" +
        "${i2}}\n" +
        "${i1}}"
}

/** 写进 json5 的字符串要做反向转义（Windows 路径的 `\` 必须成 `\\`） */
public func json5EscapeOf(s: String): String {
    let bytes = s.toArray()
    let out = ArrayList<UInt8>()
    for (b in bytes) {
        if (b == 92) {
            out.add(92)
            out.add(92)
        } else if (b == 34) {
            out.add(92)
            out.add(34)
        } else {
            out.add(b)
        }
    }
    return String.fromUtf8(out.toArray())
}

/**
 * 定位 `signingConfigs` 的 `[` 与配对的 `]`。
 *
 * 返回 (open 下标, close 下标, 键所在行的缩进, 错误)。扫描**按深度配对**并跳过 json5 字符串，
 * 因为就地更新时要处理"数组里已经有内容"的形态——早期实现"遇到第一个 `]` 就停"，
 * 只在空数组上成立（0.39.22 要改写已有 block，才把它抽成共用函数）。
 */
func locateSigningArray(text: String): (Int64, Int64, String, String) {
    let bytes = text.toArray()
    var keyEnd: Int64 = -1
    var lineStart: Int64 = 0
    match (text.indexOf("\"signingConfigs\"")) {
        case Some(at) =>
            keyEnd = at + "\"signingConfigs\"".size
            lineStart = at
        case None => match (text.indexOf("signingConfigs:")) {
            case Some(at) =>
                keyEnd = at + "signingConfigs:".size
                lineStart = at
            case None => return (-1, -1, "", "找不到 signingConfigs 字段（build-profile.json5 结构不认识）")
        }
    }
    // 该行的缩进：从键位置往回找到行首
    while (lineStart > 0 && bytes[lineStart - 1] != 10 && bytes[lineStart - 1] != 13) {
        lineStart--
    }
    var indentLen: Int64 = 0
    while (lineStart + indentLen < keyEnd && (bytes[lineStart + indentLen] == 32 || bytes[lineStart + indentLen] == 9)) {
        indentLen++
    }
    let keyIndent = String.fromUtf8(bytes[lineStart..(lineStart + indentLen)])
    // 找紧邻的 `[`
    var i = keyEnd
    while (i < bytes.size && bytes[i] != 91) {   // [
        if (bytes[i] == 123 || bytes[i] == 125) {   // { }
            return (-1, -1, "", "signingConfigs 后面没找到数组")
        }
        i++
    }
    if (i >= bytes.size) {
        return (-1, -1, "", "signingConfigs 后面没找到数组")
    }
    let open = i
    var depth: Int64 = 0
    var inStr = false
    var esc = false
    i++
    while (i < bytes.size) {
        let c = bytes[i]
        if (inStr) {
            if (esc) {
                esc = false
            } else if (c == 92) {        // \
                esc = true
            } else if (c == 34) {        // "
                inStr = false
            }
        } else if (c == 34) {
            inStr = true
        } else if (c == 91) {            // [
            depth++
        } else if (c == 93) {            // ]
            if (depth == 0) {
                return (open, i, keyIndent, "")
            }
            depth--
        }
        i++
    }
    return (-1, -1, "", "signingConfigs 数组没闭合")
}

/** `[` 与 `]` 之间是不是只有空白与逗号（即"空数组"） */
func arrayBodyIsBlank(text: String, open: Int64, close: Int64): Bool {
    let bytes = text.toArray()
    if (open < 0 || close <= open || close >= bytes.size) {
        return false
    }
    for (i in (open + 1)..close) {
        let c = bytes[i]
        if (c != 32 && c != 9 && c != 10 && c != 13 && c != 44) {
            return false
        }
    }
    return true
}

/**
 * 就地**更新**已有的 `signingConfigs`（只允许在同一套材料上更新）。
 *
 * 为什么需要它：自动签名复用本地 p12 时，`.p7b/.cer` 会换成新签发的（旧证书过期后必须换），
 * 这时工程里的 block 已经存在——按"非空就拒绝"处理会让整条路线走到最后一步失败
 * （实测 0.39.22：`⑦ 写回失败：工程里已经有非空的 signingConfigs`）。
 *
 * 安全边界：**只有当工程里那份 `storeFile` 与我们要写的是同一份材料（同一个 .p12 文件名）**
 * 才就地更新；换材料不做静默覆盖，报错让人决定。
 */
public func replaceOwnSigningConfigs(text: String, m: SigningMaterial): (String, String) {
    if (text == "") {
        return ("", "build-profile.json5 内容为空")
    }
    if (!m.complete()) {
        return ("", "材料不完整（缺 .p12/.cer/.p7b 或口令密文），无法写回")
    }
    // 判序：先看"有没有东西可更新"，再看"是不是同一套材料"。
    // 反过来会让空数组也落进"另一套材料"的报错里，话说不清（单测抓到的）。
    if (!parseProjSigning(text).hasSigningConfigs) {
        return ("", "signingConfigs 是空数组，应该走注入而不是更新")
    }
    let cur = signingMaterialOf(text)
    if (!sameMaterialFile(cur.storeFile, m.storeFile)) {
        return ("", "工程里已有另一套签名材料（${cur.storeFile}），不做覆盖（要换材料请先清空 signingConfigs）")
    }
    let (open, close, keyIndent, loErr) = locateSigningArray(text)
    if (loErr != "") {
        return ("", loErr)
    }
    // 名字沿用工程里那份：products[].signingConfig 指的就是它，改名会打断这条引用
    let keepName = if (cur.name != "") { cur.name } else { m.name }
    let savedName = m.name
    m.name = keepName
    let elemIndent = keyIndent + "  "
    let body = "[\n${signingBlockJson5(m, elemIndent)}\n${keyIndent}]"
    m.name = savedName
    let bytes = text.toArray()
    let head = String.fromUtf8(bytes[0..open])
    let tail = String.fromUtf8(bytes[(close + 1)..bytes.size])
    return (head + body + tail, "")
}

/**
 * 把一块 signingConfigs 注入 `build-profile.json5` 文本（**纯文本手术，不重排整份文件**）。
 *
 * 只处理"`signingConfigs` 是空数组"这一种情况（其余一律不动）：空数组里塞进 block，
 * 缩进对齐到 `signingConfigs` 键所在行的缩进。
 * 返回 (新文本, 错误)：错误非空时不写文件。
 */
public func injectSigningConfigs(text: String, m: SigningMaterial): (String, String) {
    if (text == "") {
        return ("", "build-profile.json5 内容为空")
    }
    if (parseProjSigning(text).hasSigningConfigs) {
        return ("", "工程里已经有非空的 signingConfigs，不做覆盖（要重配请先手动清空）")
    }
    // 定位 signingConfigs 键（带引号 / 裸键两种写法）→ 交给共用的定位器
    let (open, close, keyIndent, loErr) = locateSigningArray(text)
    if (loErr != "") {
        return ("", loErr)
    }
    if (!arrayBodyIsBlank(text, open, close)) {
        // 空数组里居然有东西：解析口径与 hasSigningConfigs 不一致，别动
        return ("", "signingConfigs 数组非空（或结构异常），不做覆盖")
    }
    let elemIndent = keyIndent + "  "
    let body = "[\n${signingBlockJson5(m, elemIndent)}\n${keyIndent}]"
    let bytes = text.toArray()
    let head = String.fromUtf8(bytes[0..open])
    // 从 `]` 的**下一个字符**开始接原文：body 自己已经带上了收尾的 `]`，
    // 若从 `close` 起接会多出一个 `]`（实测把 json5 写成 `]]`，语法错误）
    let tail = String.fromUtf8(bytes[(close + 1)..bytes.size])
    return (head + body + tail, "")
}

/**
 * 把 `products[].signingConfig` 指到 [name]。
 * 三种情形：已指向目标（不动）／是空串（填上）／指向别的名字（报错，不猜）。
 */
public func pointProductSigningConfig(text: String, name: String): (String, String) {
    if (text == "") {
        return ("", "build-profile.json5 内容为空")
    }
    if (name == "") {
        return ("", "签名配置名为空")
    }
    let marker = "\"signingConfig\""
    var at: Int64 = -1
    match (text.indexOf(marker)) {
        case Some(i) => at = i
        case None => return ("", "找不到 products[].signingConfig 字段")
    }
    let bytes = text.toArray()
    var i = at + marker.size
    // 跳冒号
    while (i < bytes.size && bytes[i] != 58 && bytes[i] != 10) {
        i++
    }
    if (i >= bytes.size || bytes[i] != 58) {
        return ("", "products[].signingConfig 后面没有冒号")
    }
    i++
    while (i < bytes.size && (bytes[i] == 32 || bytes[i] == 9 || bytes[i] == 10 || bytes[i] == 13)) {
        i++
    }
    if (i >= bytes.size || bytes[i] != 34) {   // "
        return ("", "products[].signingConfig 的值不是字符串")
    }
    let valueStart = i + 1
    var valueEnd = valueStart
    while (valueEnd < bytes.size && bytes[valueEnd] != 34) {
        valueEnd++
    }
    if (valueEnd >= bytes.size) {
        return ("", "products[].signingConfig 的字符串没闭合")
    }
    let current = String.fromUtf8(bytes[valueStart..valueEnd])
    if (current == name) {
        return (text, "")
    }
    if (current != "") {
        return ("", "products[].signingConfig 已指向「${current}」，不自动改（请手动确认）")
    }
    let head = String.fromUtf8(bytes[0..valueStart])
    let tail = String.fromUtf8(bytes[valueEnd..bytes.size])
    return (head + name + tail, "")
}

/** 一次性做完「注入 signingConfigs + 指向 product」，任一步失败就返回原文本与错误 */
public func applySigningConfig(text: String, m: SigningMaterial): (String, String) {
    if (!m.complete()) {
        return ("", "材料不完整（缺 .p12/.cer/.p7b 或口令密文），无法写回")
    }
    let (step1, err1) = injectSigningConfigs(text, m)
    if (err1 != "") {
        return ("", err1)
    }
    let (step2, err2) = pointProductSigningConfig(step1, m.name)
    if (err2 != "") {
        return ("", err2)
    }
    return (step2, "")
}

// ============================================================
// 材料生产（路线 A）：命名规则与口令密文的纯函数层
// ============================================================
//
// 依据：`docs/鸿蒙自动签名机制.md` §3.7 + flutter_flutter 提交 e2793de 的
// `lib/src/ohos/signing/material.dart`（`sanitizeSignName` / `projectPathHash` /
// `signingFileBaseName` / `signingFilePath`）与 `keymanager.dart`。
//
// **为什么要一模一样**：材料文件名是"确定性"的（DevEco / ark-cli / flutter / 我们共用
// `~/.ohos/config`），hash 算错一位就与 DevEco 已生成的材料对不上号，复用链路直接断掉。
// 本机实测核对：habit-tree 的工程根（DevEco 眼中的 `gen/ohos` 目录，**前向斜杠**）算出
// `m7Gxh5QRtg0h6LnDjtArCp3iYObE9iWm8BEssdAfmHM`，与磁盘上的
// `default_ohos_m7Gxh5QRtg0h6LnDjtArCp3iYObE9iWm8BEssdAfmHM=.p7b` 逐字一致；
// 换成反斜杠会算出 `EuNnZ1gj…` —— 这就是"两个细节错一个就复不上"的现场。

/** base64url 字母表（`+`→`-`、`/`→`_`），**不带** `=` 填充 */
func b64UrlChar(v: Int64): Byte {
    if (v < 26) {
        return UInt8(65 + v)            // A-Z
    }
    if (v < 52) {
        return UInt8(97 + v - 26)       // a-z
    }
    if (v < 62) {
        return UInt8(48 + v - 52)       // 0-9
    }
    if (v == 62) {
        return UInt8(45)                // '-'
    }
    return UInt8(95)                    // '_'
}

/**
 * base64url 编码，**去掉 `=` 填充**（DevEco 的 hash 就是这么算的）。
 *
 * 不引第三方：仓库里只有 base64 **解码**（`packed_resources.cj`），这里补一个编码，
 * 顺带把 `+/` → `-_` 的映射做在字母表里（少一次字符串替换，也少一次出错机会）。
 */
public func b64UrlNoPad(data: Array<Byte>): String {
    let out = ArrayList<Byte>()
    var i: Int64 = 0
    let n = Int64(data.size)
    while (i + 2 < n) {
        let b0 = Int64(data[i])
        let b1 = Int64(data[i + 1])
        let b2 = Int64(data[i + 2])
        out.add(b64UrlChar(b0 >> 2))
        out.add(b64UrlChar(((b0 & 3) << 4) | (b1 >> 4)))
        out.add(b64UrlChar(((b1 & 15) << 2) | (b2 >> 6)))
        out.add(b64UrlChar(b2 & 63))
        i += 3
    }
    let rest = n - i
    if (rest == 1) {
        let b0 = Int64(data[i])
        out.add(b64UrlChar(b0 >> 2))
        out.add(b64UrlChar((b0 & 3) << 4))
    } else if (rest == 2) {
        let b0 = Int64(data[i])
        let b1 = Int64(data[i + 1])
        out.add(b64UrlChar(b0 >> 2))
        out.add(b64UrlChar(((b0 & 3) << 4) | (b1 >> 4)))
        out.add(b64UrlChar((b1 & 15) << 2))
    }
    return String.fromUtf8(out.toArray())
}

/** 把宿主路径归一成**前向斜杠**（DevEco 的 hash 用前向斜杠；反斜杠算出的是另一个值） */
public func forwardSlashPath(p: String): String {
    let bytes = p.toArray()
    let out = ArrayList<Byte>()
    for (b in bytes) {
        if (b == 92) {
            out.add(UInt8(47))
        } else {
            out.add(b)
        }
    }
    return String.fromUtf8(out.toArray())
}

/**
 * 工程路径的 hash：`base64url(sha256(前向斜杠路径))`，去 `=` 填充（43 字符）。
 *
 * 注意：**`-` 与 `_` 要保留**（base64url 字母表），不要误当"非法文件名字符"清掉。
 */
public func projectPathHash(projectRoot: String): String {
    let text = forwardSlashPath(projectRoot.trimAscii())
    return b64UrlNoPad(digest(SHA256(), text.toArray()))
}

/** 文件名片段的最长长度（与 flutter / DevEco 一致） */
public let SIGN_NAME_MAX_LEN: Int64 = 64

/**
 * 把 product / 工程目录名净化成安全的文件名片段：
 * `\ / : * ? " < > | = -` 一律换成 `_`，连续的点换 `_`，超长截断 64，空则回落 `default`。
 *
 * `=` 也在非法列表里，这点容易漏：hash 后面那个 `=` 是**我们自己拼上去的字面量**，
 * 名字里再出现 `=` 就会让"哪段是 hash"变得歧义。
 */
public func sanitizeSignName(raw: String): String {
    let trimmed = raw.trimAscii()
    if (trimmed == "") {
        return "default"
    }
    let bytes = trimmed.toArray()
    let out = ArrayList<Byte>()
    var pendingDot = false
    for (b in bytes) {
        if (out.size >= SIGN_NAME_MAX_LEN) {
            break
        }
        var ch = b
        let illegal = ch == 92 || ch == 47 || ch == 58 || ch == 42 || ch == 63 || ch == 34 ||
            ch == 60 || ch == 62 || ch == 124 || ch == 61 || ch == 45
        if (illegal) {
            ch = UInt8(95)
        }
        if (ch == 46) {          // 连续的点合成一个 '_'（与 DevEco / flutter 同款）
            pendingDot = true
            continue
        }
        if (pendingDot) {
            out.add(UInt8(95))
            pendingDot = false
            if (out.size >= SIGN_NAME_MAX_LEN) {
                break
            }
        }
        out.add(ch)
    }
    if (pendingDot && out.size < SIGN_NAME_MAX_LEN) {
        out.add(UInt8(95))
    }
    if (out.size == 0) {
        return "default"
    }
    return String.fromUtf8(out.toArray())
}

/** 工程目录名（路径末段；两种分隔符都认） */
func lastPathSegment(p: String): String {
    let bytes = p.toArray()
    var cut: Int64 = -1
    for (i in 0..bytes.size) {
        if (bytes[i] == 47 || bytes[i] == 92) {
            cut = i
        }
    }
    if (cut < 0) {
        return p
    }
    return p[(cut + 1)..p.size]
}

/** 四个材料文件共用的名字主干：`{product}_{工程目录名}_{hash}`（**不含**末尾的 `=`） */
public func signingFileBaseName(product: String, projectRoot: String): String {
    let dirName = lastPathSegment(projectRoot.trimAscii())
    let safeDir = if (dirName == "") { "default" } else { sanitizeSignName(dirName) }
    return "${sanitizeSignName(product)}_${safeDir}_${projectPathHash(projectRoot)}"
}

/**
 * 一个材料文件的文件名：`{主干}=.{suffix}`。
 *
 * **注意那个 `=`**：它是 hash 与后缀之间的字面分隔符，不是 base64 填充
 * （填充已经在 `projectPathHash` 里去掉了）。错成"带填充的 base64"就与 DevEco 对不上。
 */
public func signingMaterialFileName(product: String, projectRoot: String, suffix: String): String {
    return "${signingFileBaseName(product, projectRoot)}=.${suffix}"
}

// ------------------------------------------------------------
// 口令密文的字节层（纯函数；加密原语在下一节）
// ------------------------------------------------------------
//
// AesGcmKit 的载荷布局（与 DevEco / hvigor 的 decipher-util.js 一致）：
//
//   [ len(4 字节大端) | IV(12) | ciphertext | tag(16) ]   len = |ciphertext| + 16
//
// 写进 build-profile.json5 的是这整段的**小写 hex**。这条布局错一个字节，
// hvigor 就解不开口令（表现是"签名失败"，而不是"口令错"），所以先把它做成纯函数钉住。

/** 小写 hex 编码 */
public func toHexLower(data: Array<Byte>): String {
    let digits = "0123456789abcdef".toArray()
    let out = ArrayList<Byte>()
    for (b in data) {
        let v = Int64(b)
        out.add(digits[(v >> 4) & 15])
        out.add(digits[v & 15])
    }
    return String.fromUtf8(out.toArray())
}

/** hex → 字节（`Option`：长度奇数或含非 hex 字符时为 None，调用方按"材料坏了"处理） */
public func fromHexLower(s: String): Option<Array<Byte>> {
    let text = s.trimAscii()
    let bytes = text.toArray()
    if (bytes.size % 2 != 0 || bytes.size == 0) {
        return None
    }
    let out = ArrayList<Byte>()
    var i: Int64 = 0
    while (i < bytes.size) {
        let hi = hexNibbleOf(bytes[i])
        let lo = hexNibbleOf(bytes[i + 1])
        if (hi < 0 || lo < 0) {
            return None
        }
        out.add(UInt8((hi << 4) | lo))
        i += 2
    }
    return Some(out.toArray())
}

/** 单个 hex 字符的数值（非 hex 给 -1） */
func hexNibbleOf(b: Byte): Int64 {
    if (b >= 48 && b <= 57) {
        return Int64(b - 48)
    }
    if (b >= 97 && b <= 102) {
        return Int64(b - 87)
    }
    if (b >= 65 && b <= 70) {
        return Int64(b - 55)
    }
    return -1
}

/** 口令密文的长度常量（写在这里当"单点真相"，别在各处散着魔数） */
public let AES_GCM_IV_LEN: Int64 = 12
public let AES_GCM_TAG_LEN: Int64 = 16
public let AES_GCM_KEY_LEN: Int64 = 16
public let PBKDF2_ITERATIONS: Int64 = 10000

/** 一段口令密文的三个组成部分 */
public class GcmPayload {
    public var iv: Array<Byte> = []
    public var ciphertext: Array<Byte> = []
    public var tag: Array<Byte> = []

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("ivLen", JsonInt(Int64(this.iv.size)))
        o.put("ctLen", JsonInt(Int64(this.ciphertext.size)))
        o.put("tagLen", JsonInt(Int64(this.tag.size)))
        return o
    }
}

/** 按 AesGcmKit 布局打包：`[len(4BE) | IV(12) | ct | tag(16)]`，`len = |ct| + 16` */
public func packGcmPayload(iv: Array<Byte>, ciphertext: Array<Byte>,
    tag: Array<Byte>): Option<Array<Byte>> {
    if (iv.size != AES_GCM_IV_LEN || tag.size != AES_GCM_TAG_LEN) {
        return None
    }
    let bodyLen = Int64(ciphertext.size) + AES_GCM_TAG_LEN
    let out = ArrayList<Byte>()
    out.add(UInt8((bodyLen >> 24) & 0xFF))
    out.add(UInt8((bodyLen >> 16) & 0xFF))
    out.add(UInt8((bodyLen >> 8) & 0xFF))
    out.add(UInt8(bodyLen & 0xFF))
    for (b in iv) {
        out.add(b)
    }
    for (b in ciphertext) {
        out.add(b)
    }
    for (b in tag) {
        out.add(b)
    }
    return Some(out.toArray())
}

/** 拆包（长度不符 / 太短 / 声明长度与实到不符 → None） */
public func unpackGcmPayload(raw: Array<Byte>): Option<GcmPayload> {
    let minLen = 4 + AES_GCM_IV_LEN + AES_GCM_TAG_LEN
    if (Int64(raw.size) < minLen) {
        return None
    }
    let bodyLen = (Int64(raw[0]) << 24) | (Int64(raw[1]) << 16) | (Int64(raw[2]) << 8) |
        Int64(raw[3])
    if (bodyLen < AES_GCM_TAG_LEN || 4 + AES_GCM_IV_LEN + bodyLen > Int64(raw.size)) {
        return None
    }
    let p = GcmPayload()
    p.iv = raw[4..(4 + AES_GCM_IV_LEN)]
    let body = raw[(4 + AES_GCM_IV_LEN)..(4 + AES_GCM_IV_LEN + bodyLen)]
    let ctLen = Int64(body.size) - AES_GCM_TAG_LEN
    p.ciphertext = body[0..ctLen]
    p.tag = body[ctLen..body.size]
    return Some(p)
}