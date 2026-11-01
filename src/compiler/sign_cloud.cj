package lingqu.compiler

import std.collection.*
import std.crypto.digest.*
import std.fs.*
import std.process.*
import std.time.*
import stdx.crypto.digest.*
import stdx.encoding.json.*

/*
 * AGC 云侧动作：设备 / 证书 / profile / 安全下载（0.39.15）。
 *
 * 端点与请求体逐字照 flutter `cloud.dart` / `device.dart` / `profile.dart`
 * （见 docs/鸿蒙自动签名机制.md §4 端点清单与 `%TEMP%\flutter-signing\SPEC.md`）。
 *
 * 分层：**纯函数**负责"解析响应 / 拼请求体 / 判成功"，`agcXxx` 负责发请求。
 * 纯函数进单测（D-009），网络层不造假绿（§1 第 5 条）。
 *
 * 三条贯穿全文件的纪律：
 *   ① AGC 的成功判据是 **body 里的 `ret.code == 0`**，不是 HTTP 200；
 *   ② 错误文案优先取 `ret.msg`（可能是对象、也可能是被 JSON 编码过的字符串）；
 *   ③ 下载必须 **HTTPS + 非内网**（SSRF 护栏），且**先校验 sha256 再落盘**。
 */

/** 云端已注册设备 */
public class AgcDevice {
    public var udid: String = ""
    public var name: String = ""
    public var id: String = ""
}

/** 云端证书 */
public class AgcCert {
    public var id: String = ""
    public var certName: String = ""
    public var certObjectId: String = ""
    /** 到期时间（毫秒时间戳；取不到给 0） */
    public var expireMs: Int64 = 0
    /** AGC 侧状态（实测：1=可用、2=已过期） */
    public var status: Int64 = 0

    /**
     * 这张证书现在能不能用来申请 debug profile。
     *
     * 实测（0.39.21）：AGC 里那张 `auto_debug_<teamId>.cer` 名字对得上，但 `expireTime` 早已过去
     * （status=2），拿它申请会被回 `The certList is invalid.` —— 看名字复用是不够的，必须看**有效期**。
     */
    public func usable(): Bool {
        if (this.id == "") {
            return false
        }
        if (this.status != 0 && this.status != 1) {
            return false
        }
        if (this.expireMs > 0 && this.expireMs <= nowMs()) {
            return false
        }
        return true
    }
}

/** 当前时间（毫秒；取不到给 0 → 视为"无法判断过期"，让 usable() 放行） */
public func nowMs(): Int64 {
    try {
        return DateTime.now().toUnixTimeStamp().toMilliseconds()
    } catch (e: Exception) {
        let _ = e
        return 0
    }
}

// ============================================================
// 一、纯函数：响应解析与请求体拼装
// ============================================================

/** 解析 `device/list` 的响应（`devicesInfo` 或 `devices` 两种字段名都认） */
public func parseDeviceList(root: JsonValue): ArrayList<AgcDevice> {
    let out = ArrayList<AgcDevice>()
    if (!agcSucceeded(root)) {
        return out
    }
    var arr = jsonArrayField(root, "devicesInfo")
    if (arr.size() == 0) {
        arr = jsonArrayField(root, "devices")
    }
    if (arr.size() == 0) {
        arr = jsonArrayField(root, "deviceList")
    }
    if (arr.size() == 0) {
        arr = jsonArrayField(root, "deviceInfos")
    }
    // 实测（0.39.21）：AGC 真正用的字段名是 **`list`** —— 上面几个名字都不对，
    // 于是"设备已注册"永远判成"没注册"（随后 device/add 报 205389858 UDID is repeat）。
    if (arr.size() == 0) {
        arr = jsonArrayField(root, "list")
    }
    for (i in 0..arr.size()) {
        let d = AgcDevice()
        d.udid = jsonStringField(arr[i], "udid")
        d.name = jsonStringField(arr[i], "deviceName")
        d.id = jsonStringField(arr[i], "id")
        if (d.udid != "") {
            out.add(d)
        }
    }
    return out
}

/** 该 UDID 是否已注册（大小写不敏感：AGC 侧统一大写，我们统一大写后比） */
public func deviceRegistered(devices: ArrayList<AgcDevice>, udid: String): Bool {
    let want = upperAscii(udid).trimAscii()
    if (want == "") {
        return false
    }
    for (d in devices) {
        if (upperAscii(d.udid).trimAscii() == want) {
            return true
        }
    }
    return false
}

/** 解析 `cert/list` 的响应（`certList`） */
public func parseCertList(root: JsonValue): ArrayList<AgcCert> {
    let out = ArrayList<AgcCert>()
    if (!agcSucceeded(root)) {
        return out
    }
    let arr = jsonArrayField(root, "certList")
    for (i in 0..arr.size()) {
        let c = AgcCert()
        c.id = jsonStringField(arr[i], "id")
        c.certName = jsonStringField(arr[i], "certName")
        c.certObjectId = jsonStringField(arr[i], "certObjectId")
        c.expireMs = jsonIntField(arr[i], "expireTime", 0)
        c.status = jsonIntField(arr[i], "status", 0)
        out.add(c)
    }
    return out
}

/** 按名字找**可用**（未过期）的证书；名字对得上但过期的会被跳过 */
public func findUsableCert(certs: ArrayList<AgcCert>, name: String): Option<AgcCert> {
    for (c in certs) {
        if (c.certName == name && c.usable()) {
            return Some(c)
        }
    }
    return None
}

/** 按名字找证书（`auto_debug_<teamId>.cer` 是确定性命名，所以这就是"要不要新建"的判据） */
public func findCertByName(certs: ArrayList<AgcCert>, name: String): Option<AgcCert> {
    for (c in certs) {
        if (c.certName == name) {
            return Some(c)
        }
    }
    return None
}

/**
 * 名字是不是**自动签名**产出的（`auto_debug_<teamId>.cer` / `auto_release_<teamId>.cer`）。
 *
 * 只删这个前缀的，是为了不碰用户自己在 AGC 控制台建的证书——删别人的东西不在工具职责里。
 */
public func isAutoSignCertName(name: String): Bool {
    let n = lowerAscii(name.trimAscii())
    return n.startsWith("auto_debug_") || n.startsWith("auto_release_")
}

/**
 * 挑出**已过期**的自动签名证书：AGC 的证书数量有上限（本账号实测 4 张），
 * 过期的那几张照样占位，于是新建会撞 `205389872 certificate number exceeds limit.`。
 * 它们的唯一用处就是占位，删掉才能腾出位置。
 */
public func staleCertsOf(certs: ArrayList<AgcCert>): ArrayList<AgcCert> {
    let out = ArrayList<AgcCert>()
    for (c in certs) {
        if (c.id != "" && !c.usable() && isAutoSignCertName(c.certName)) {
            out.add(c)
        }
    }
    return out
}

/**
 * `hdc shell getprop hw_sc.build.os.deviceType` 的输出 → AGC 的设备类型码。
 *
 * 判序照 flutter（`liteWearable` 必须先于 `wearable` 判，否则子串会把前者吃掉）：
 * liteWearable=1 / wearable=2 / tv=3 / 其它=4（手机/平板/PC 在 flutter 里都落 4）。
 */
public func deviceTypeOf(getpropOut: String): String {
    let t = getpropOut.trimAscii()
    if (t.indexOf("liteWearable").isSome()) {
        return "1"
    }
    if (t.indexOf("wearable").isSome()) {
        return "2"
    }
    if (t.indexOf("tv").isSome()) {
        return "3"
    }
    return "4"
}

/** `device/add` 的请求体（`deviceName` 要唯一：随机数 + 时间戳，与 flutter 同思路） */
public func buildDeviceAddBody(udid: String, deviceType: String, nonce: String): String {
    var o = JsonObject()
    o.put("deviceName", JsonString("lingqu_device_${nonce}"))
    o.put("udid", JsonString(upperAscii(udid).trimAscii()))
    o.put("deviceType", JsonString(deviceType))
    return o.toJsonString()
}

/** `cert/add` 的请求体（certType：1=debug / 2=release） */
public func buildCertAddBody(csrPem: String, certName: String, certType: String): String {
    var o = JsonObject()
    o.put("csr", JsonString(csrPem))
    o.put("certName", JsonString(certName))
    o.put("certType", JsonString(certType))
    return o.toJsonString()
}

/**
 * `provision/add` 的请求体。
 *
 * `deviceList` 只在 **debug（test）** profile 里带；`aclPermissionList` 为空时不带
 * （带空数组会被 AGC 判非法）。
 */
public func buildProvisionBody(certIds: ArrayList<String>, bundleName: String, provisionName: String,
    deviceIds: ArrayList<String>, aclPermissions: ArrayList<String>): String {
    var o = JsonObject()
    var certs = JsonArray()
    for (c in certIds) {
        certs.add(JsonString(c))
    }
    o.put("certList", certs)
    o.put("packageName", JsonString(bundleName))
    o.put("provisionName", JsonString(provisionName))
    if (deviceIds.size > 0) {
        var devs = JsonArray()
        for (d in deviceIds) {
            devs.add(JsonString(d))
        }
        o.put("deviceList", devs)
    }
    if (aclPermissions.size > 0) {
        var acls = JsonArray()
        for (a in aclPermissions) {
            acls.add(JsonString(a))
        }
        o.put("aclPermissionList", acls)
    }
    return o.toJsonString()
}

/** 从 `provision/add` 响应里取 (profileId, provisionFileUrl) */
public func parseProvisionAdd(root: JsonValue): (String, String) {
    if (!agcSucceeded(root)) {
        return ("", "")
    }
    return (jsonStringField(root, "id"), jsonStringField(root, "provisionFileUrl"))
}

/**
 * 下载 URL 的 SSRF 护栏：只放 https、拒本机与内网地址。
 *
 * 这不是"多余的谨慎"：下载链是 AGC 返回的**临时 URL**，若被诱导去访问内网就是典型的 SSRF。
 * 内网清单按 flutter 的实现范围（localhost / 127.0.0.1 / ::1 / 10. / 192.168. / 172.16-31. /
 * 169.254. / .internal / .local）。
 */
public func isSafeDownloadUrl(u: String): Bool {
    let s = u.trimAscii()
    if (!s.startsWith("https://")) {
        return false
    }
    let lowered = lowerAscii(s)
    let afterScheme = lowered[8..lowered.size]
    var authority = afterScheme
    match (afterScheme.indexOf("/")) {
        case Some(at) => authority = afterScheme[0..at]
        case None => ()
    }
    // 取 host：**带方括号的 IPv6 要整段取到 `]`**，不能按第一个 `:` 切
    // （`[::1]` 按 `:` 切会得到 `[`，护栏就漏了——单测当场抓到）
    var host = authority
    if (authority.startsWith("[")) {
        match (authority.indexOf("]")) {
            case Some(at) => host = authority[0..(at + 1)]
            case None => host = authority
        }
    } else {
        match (authority.indexOf(":")) {
            case Some(at) => host = authority[0..at]
            case None => ()
        }
    }
    if (host == "" || host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]") {
        return false
    }
    // 其它带 `:` 的 host（未加方括号的 IPv6 等）一律拒：不猜
    if (host.indexOf(":").isSome()) {
        return false
    }
    if (host.startsWith("10.") || host.startsWith("192.168.") || host.startsWith("169.254.")) {
        return false
    }
    if (host.startsWith("172.")) {
        // 172.16.0.0/12：第二段 16-31（自己数数字，别用 Int64.parse —— 返回类型不是 Ok/Err 枚举）
        let parts = host.split(".", -1)
        if (parts.size >= 2) {
            let second = digitsOnlyValue(parts[1])
            if (second >= 16 && second <= 31) {
                return false
            }
        }
    }
    if (host.endsWith(".internal") || host.endsWith(".local")) {
        return false
    }
    return true
}

/** ASCII 大小写转换（仓颉没有现成的 toUpperCaseAscii / toLowerCaseAscii） */
public func upperAscii(s: String): String {
    let out = ArrayList<Byte>()
    for (b in s.toArray()) {
        if (b >= 97 && b <= 122) {
            out.add(UInt8(Int64(b) - 32))
        } else {
            out.add(b)
        }
    }
    return String.fromUtf8(out.toArray())
}

/** ASCII 小写 */
public func lowerAscii(s: String): String {
    let out = ArrayList<Byte>()
    for (b in s.toArray()) {
        if (b >= 65 && b <= 90) {
            out.add(UInt8(Int64(b) + 32))
        } else {
            out.add(b)
        }
    }
    return String.fromUtf8(out.toArray())
}

// ============================================================
// 二、动作层：发请求（网络 + 落盘，单测不覆盖）
// ============================================================

/** AGC 业务请求的公共头（`uid` / `teamId` / `oauth2Token` 三件套） */
func agcAuthHeaders(accessToken: String, uid: String, teamId: String): ArrayList<String> {
    let h = ArrayList<String>()
    h.add("oauth2Token: ${accessToken}")
    h.add("uid: ${uid}")
    h.add("teamId: ${teamId}")
    return h
}

/** 发一次 AGC 请求并解析 JSON；返回 (根对象, 错误) */
func agcCall(method: String, path: String, accessToken: String, uid: String, teamId: String,
    body: String): (JsonValue, String) {
    let r = agcHttp(method, agcUrl(path), agcAuthHeaders(accessToken, uid, teamId), body, 30000)
    if (r.error != "") {
        return (JsonObject(), r.error)
    }
    if (r.body.trimAscii() == "") {
        return (JsonObject(), "AGC 返回空响应（HTTP ${r.status}）")
    }
    var root: JsonValue
    try {
        root = JsonValue.fromStr(r.body)
    } catch (e: Exception) {
        return (JsonObject(), "AGC 响应不是 JSON（HTTP ${r.status}）：${e}")
    }
    if (!agcSucceeded(root)) {
        return (root, "AGC 错误 ${agcErrorCode(root)}：${agcErrorMsg(root)}")
    }
    return (root, "")
}

/** 拉设备列表（分页：`start` 从 1 起、每页 100，与 flutter 一致） */
public func agcDeviceList(accessToken: String, uid: String, teamId: String): (ArrayList<AgcDevice>, String) {
    let all = ArrayList<AgcDevice>()
    var page: Int64 = 1
    while (page <= 10) {          // 硬上限：设备上千台的账号不该在这个工具里折腾
        let (root, err) = agcCall("GET",
            "${AGC_DEVICE_LIST_PATH}?encodeFlag=0&start=${page}&pageSize=100",
            accessToken, uid, teamId, "")
        if (err != "") {
            return (all, err)
        }
        let got = parseDeviceList(root)
        for (d in got) {
            all.add(d)
        }
        if (got.size < 100) {
            break
        }
        page += 1
    }
    return (all, "")
}

/** 注册本机设备（已注册就跳过） */
public func agcEnsureDevice(accessToken: String, uid: String, teamId: String, udid: String,
    deviceType: String): (Bool, String) {
    let (devices, e1) = agcDeviceList(accessToken, uid, teamId)
    if (e1 != "") {
        return (false, "拉设备列表失败：${e1}")
    }
    if (deviceRegistered(devices, udid)) {
        return (true, "设备已注册（共 ${devices.size} 台）")
    }
    let nonce = toHexLower(randomBytes(3))
    let body = buildDeviceAddBody(udid, deviceType, nonce)
    let (_, e2) = agcCall("POST", AGC_DEVICE_ADD_PATH, accessToken, uid, teamId, body)
    if (e2 != "") {
        // `205389858 UDID is repeat`：**这个 UDID 已经注册过了**（可能在本团队也可能在别处）。
        // 语义上等于"已注册"，不该当失败——否则用户会被一个"其实已经好了"的错误卡住。
        if (e2.contains("205389858")) {
            return (true, "设备已注册（AGC 回报 UDID 重复，视为已注册）")
        }
        // 名字重复/数量超限都不是致命：前者换个 nonce 重试一次，后者要人处理
        if (e2.contains("205389857")) {
            let body2 = buildDeviceAddBody(udid, deviceType, toHexLower(randomBytes(4)))
            let (_, e3) = agcCall("POST", AGC_DEVICE_ADD_PATH, accessToken, uid, teamId, body2)
            if (e3 == "") {
                return (true, "设备注册成功（换名重试）")
            }
            return (false, "注册设备失败：${e3}")
        }
        return (false, "注册设备失败：${e2}")
    }
    return (true, "设备注册成功")
}

/** 证书列表 */
public func agcCertList(accessToken: String, uid: String, teamId: String): (ArrayList<AgcCert>, String) {
    let (root, err) = agcCall("GET", AGC_CERT_LIST_PATH, accessToken, uid, teamId, "")
    if (err != "") {
        return (ArrayList<AgcCert>(), "拉证书列表失败：${err}")
    }
    return (parseCertList(root), "")
}

/** 新建证书（`csr` 是 PEM 文本） */
public func agcCertAdd(accessToken: String, uid: String, teamId: String, csrPem: String,
    certName: String, certType: String): (AgcCert, String) {
    let body = buildCertAddBody(csrPem, certName, certType)
    let (_, err) = agcCall("POST", AGC_CERT_ADD_PATH, accessToken, uid, teamId, body)
    if (err != "") {
        return (AgcCert(), "新增证书失败：${err}")
    }
    // 新增接口不一定回证书 id → 重新列一遍按名字找
    let (certs, e2) = agcCertList(accessToken, uid, teamId)
    if (e2 != "") {
        return (AgcCert(), e2)
    }
    match (findCertByName(certs, certName)) {
        case Some(c) => return (c, "")
        case None => return (AgcCert(), "证书已创建但列表里找不到 ${certName}（可能需要等一下再试）")
    }
}

/**
 * 删除云端证书（**DELETE + 请求体**）。
 *
 * 参数位置是实测定出来的：`?certIds=<id>`、`?certIds[]=<id>`、JSON 数组编码都被回
 * `... Parameter is [reqParams]. Processor is [body]. Message is [Body parameter is required.]`；
 * 而 `DELETE` 带体 `{"certIds":["<id>"]}`（且要有 Content-Length）回 `{"ret":{"code":0,"msg":"OK"}}`。
 */
public func agcCertDelete(accessToken: String, uid: String, teamId: String,
    certIds: ArrayList<String>): (Bool, String) {
    if (certIds.size == 0) {
        return (false, "没有要删除的证书 id")
    }
    var arr = JsonArray()
    for (id in certIds) {
        arr.add(JsonString(id))
    }
    var o = JsonObject()
    o.put("certIds", arr)
    let (_, err) = agcCall("DELETE", AGC_CERT_DELETE_PATH, accessToken, uid, teamId, o.toJsonString())
    if (err != "") {
        return (false, "删除证书失败：${err}")
    }
    return (true, "已删除 ${certIds.size} 张云端证书")
}

/**
 * 把 AGC 的对象 URL 换成**带签名的临时下载链**，并下载到本地。
 *
 * 顺序照 flutter：先 `objects/url/reapply`（body 是 `{"sourceUrls":"<单字符串>"}`），
 * 拿到 `urlsInfo[0].newUrl`，校验 SSRF 护栏与 sha256 后再落盘。
 */
public func agcDownloadObject(accessToken: String, uid: String, teamId: String, sourceUrl: String,
    destPath: String): (String, String) {
    if (sourceUrl == "") {
        return ("", "没有可下载的对象 URL")
    }
    var body = JsonObject()
    body.put("sourceUrls", JsonString(sourceUrl))
    let (root, err) = agcCall("POST", AGC_DOWNLOAD_URL_PATH, accessToken, uid, teamId,
        body.toJsonString())
    if (err != "") {
        return ("", "换下载链失败：${err}")
    }
    let infos = jsonArrayField(root, "urlsInfo")
    if (infos.size() == 0) {
        return ("", "换下载链失败：响应里没有 urlsInfo")
    }
    let newUrl = jsonStringField(infos[0], "newUrl")
    let wantSha = lowerAscii(jsonStringField(infos[0], "sha256"))
    if (!isSafeDownloadUrl(newUrl)) {
        return ("", "拒绝下载：下载链不是安全的 HTTPS 公网地址（${newUrl}）")
    }
    // 下载**必须原样使用**这条签名 URL：AWS SigV4 对 query 的字节敏感，
    // 而通用 HTTP 客户端会把 `%2F` 之类的转义重新编码 → 签名失效 → **403**
    // （实测：同一 URL 用 curl 原样 GET 是 200/2914 字节，用我们自己的客户端 403）。
    // 所以这里优先走系统 curl（Win10+ / Linux 都自带），拿不到再退回内置客户端。
    let bytes = downloadRawBytes(newUrl)
    if (bytes.size == 0) {
        return ("", "下载失败：curl 与内置客户端都没拿到内容（URL 可能已过期，签名链有效期很短）")
    }
    if (bytes.size == 0) {
        return ("", "下载到 0 字节（AGC 对象可能已过期）")
    }
    if (wantSha != "") {
        let got = toHexLower(digest(SHA256(), bytes))
        if (got != wantSha) {
            return ("", "下载校验失败：sha256 期望 ${wantSha}，实际 ${got}（拒绝落盘）")
        }
    }
    try {
        ensureParentDirOf(destPath)
        File.writeTo(destPath, bytes)
    } catch (e: Exception) {
        return ("", "写盘失败 ${destPath}：${e}")
    }
    return (destPath, "")
}

/** 建父目录（`a/b/c.txt` → 建 `a/b`） */
public func ensureParentDirOf(path: String): Unit {
    let bytes = path.toArray()
    var cut: Int64 = -1
    for (i in 0..bytes.size) {
        if (bytes[i] == 47 || bytes[i] == 92) {
            cut = i
        }
    }
    if (cut <= 0) {
        return
    }
    let dir = path[0..cut]
    if (!exists(Path(dir))) {
        Directory.create(Path(dir), recursive: true)
    }
}

/**
 * 申请 debug（test）profile，下载 `.p7b` 到目标路径。
 *
 * **下载完立即删除云端 profile**（flutter 也是这么做的：profile 有数量配额，
 * 而本地材料已经够用了）。删除失败不影响结果，只记在返回串里。
 */
public func agcProvisionDebug(accessToken: String, uid: String, teamId: String, certId: String,
    bundleName: String, product: String, deviceIds: ArrayList<String>, aclPermissions: ArrayList<String>,
    destP7b: String): (String, String) {
    let certIds = ArrayList<String>()
    certIds.add(certId)
    let provName = provisionNameOf(product, bundleName)
    let body = buildProvisionBody(certIds, bundleName, provName, deviceIds, aclPermissions)
    let (root, err) = agcCall("POST", AGC_PROVISION_ADD_TEST_PATH, accessToken, uid, teamId, body)
    if (err != "") {
        return ("", "申请 profile 失败：${err}")
    }
    let (provId, fileUrl) = parseProvisionAdd(root)
    if (fileUrl == "") {
        return ("", "申请 profile 成功但没给 provisionFileUrl（id=${provId}）")
    }
    let (saved, e2) = agcDownloadObject(accessToken, uid, teamId, fileUrl, destP7b)
    var note = ""
    if (provId != "") {
        let (_, e3) = agcCall("DELETE", "${AGC_PROVISION_DELETE_PATH}?id=${provId}", accessToken, uid,
            teamId, "")
        note = if (e3 == "") { "云端 profile 已删除（id=${provId}）" } else { "云端 profile 删除失败：${e3}" }
    }
    if (e2 != "") {
        return ("", e2)
    }
    return (saved, note)
}

/** 纯数字串 → 数值（非纯数字返回 -1）；给网段判断用，避开 Int64.parse 的返回类型差异 */
public func digitsOnlyValue(s: String): Int64 {
    let t = s.trimAscii()
    if (t == "") {
        return -1
    }
    var v: Int64 = 0
    for (b in t.toArray()) {
        if (b < 48 || b > 57) {
            return -1
        }
        v = v * 10 + Int64(b - 48)
        if (v > 1000000) {
            return -1
        }
    }
    return v
}

/**
 * 用系统 `curl` 原样下载（保留 URL 的原始字节，避免签名被重编码）。
 *
 * 为什么不用内置客户端：签名链是 AWS SigV4，query 里 `%2F`、`+` 这类字符一旦被重新编码，
 * 签名就对不上 → 403。curl 是"把 URL 当字节"的，最稳。Win10 1803+ 与主流 Linux 都自带。
 * 返回值：拿到的字节（失败返回空）。
 */
public func downloadRawBytes(url: String): Array<Byte> {
    let tmp = "${agcTempDir()}/lingqu-dl-${toHexLower(randomBytes(4))}.bin"
    // `-sS` 静默但报错、`-L` 跟随跳转、`-f` HTTP 错误码当失败、`--max-time` 防挂死
    let args = ArrayList<String>()
    args.add("-sS")
    args.add("-L")
    args.add("-f")
    args.add("--max-time")
    args.add("90")
    args.add("-o")
    args.add(tmp)
    args.add(url)
    try {
        let (code, _, _) = executeWithOutput("curl", args.toArray())
        if (code != 0) {
            // curl 不可用或下载失败：退回内置客户端（可能仍失败，但至少留证据）
            let r = agcHttp("GET", url, ArrayList<String>(), "", 60000)
            if (r.error == "" && r.status == 200) {
                return r.body.toArray()
            }
            return []
        }
        if (!exists(Path(tmp))) {
            return []
        }
        let data = File.readFrom(tmp)
        try {
            remove(Path(tmp))
        } catch (e: Exception) {
            let _ = e
        }
        return data
    } catch (e: Exception) {
        let _ = e
        return []
    }
}

/** 取整数字段（数字或"数字字符串"都认；取不到给 fallback） */
func jsonIntField(root: JsonValue, key: String, fallback: Int64): Int64 {
    match (root.kind()) {
        case JsonKind.JsObject => match (root.asObject().get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case JsonKind.JsString => return digitsOnlyValue(v.asString().getValue())
                case _ => return fallback
            }
            case None => return fallback
        }
        case _ => return fallback
    }
}