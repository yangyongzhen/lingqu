package lingqu.compiler

import std.collection.*
import std.fs.*
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
 *   ③ 两边对上 → 只要工程的 build-profile.json5 里有指向这套材料的 signingConfigs（含 DevEco
 *      加密口令，**我们无法自行合成**，只能从工程/历史/DevEco 自动签名处带过来），就能直装。
 *
 * 所以本模块做的是「**体检 + 判断 + 给出可执行下一步**」，而不是伪造签名材料。
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

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("ok", JsonBool(this.ok))
        o.put("reason", JsonString(this.reason))
        o.put("nextStep", JsonString(this.nextStep))
        o.put("configuredName", JsonString(this.configuredName))
        o.put("configuredFilesExist", JsonBool(this.configuredFilesExist))
        o.put("configuredAllowsDevice", JsonBool(this.configuredAllowsDevice))
        o.put("udid", JsonString(this.udid))
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

/** 扫 `~/.ohos/config` 下的 `.p7b`，返回能解析的 profile 列表（解析失败也收，带 parseError） */
public func discoverProfiles(configDir: String): ArrayList<OhosProfile> {
    let out = ArrayList<OhosProfile>()
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
    // 定位 signingConfigs 键（带引号 / 裸键两种写法）
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
            case None => return ("", "找不到 signingConfigs 字段（build-profile.json5 结构不认识）")
        }
    }
    let bytes = text.toArray()
    // 该行的缩进：从键位置往回找到行首
    while (lineStart > 0 && bytes[lineStart - 1] != 10 && bytes[lineStart - 1] != 13) {
        lineStart--
    }
    var indentLen: Int64 = 0
    while (lineStart + indentLen < keyEnd && (bytes[lineStart + indentLen] == 32 || bytes[lineStart + indentLen] == 9)) {
        indentLen++
    }
    let keyIndent = String.fromUtf8(bytes[lineStart..(lineStart + indentLen)])
    // 找紧邻的 [ ... ]
    var i = keyEnd
    while (i < bytes.size && bytes[i] != 91) {
        if (bytes[i] == 123 || bytes[i] == 125) {   // { }
            return ("", "signingConfigs 后面没找到数组")
        }
        i++
    }
    if (i >= bytes.size) {
        return ("", "signingConfigs 后面没找到数组")
    }
    let open = i
    var close: Int64 = -1
    i++
    while (i < bytes.size) {
        let c = bytes[i]
        if (c == 93) {   // ]
            close = i
            break
        }
        if (c != 32 && c != 9 && c != 10 && c != 13 && c != 44) {
            // 空数组里居然有东西：解析口径与 hasSigningConfigs 不一致，别动
            return ("", "signingConfigs 数组非空（或结构异常），不做覆盖")
        }
        i++
    }
    if (close < 0) {
        return ("", "signingConfigs 数组没闭合")
    }
    let elemIndent = keyIndent + "  "
    let body = "[\n${signingBlockJson5(m, elemIndent)}\n${keyIndent}]"
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

