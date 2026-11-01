package lingqu.tests

import std.collection.*
import stdx.encoding.json.*
import lingqu.compiler.*

/*
 * AGC 云侧纯函数单测（0.39.15）。
 *
 * 钉的是"请求体/解析/护栏"三件事——它们的共同点是**错了不会报错，只会静默做错**：
 * 请求体少一个字段 AGC 回一句看不懂的 code；下载护栏漏判就是把临时 URL 当地址随意抓。
 */

const DEV_LIST_JSON = "{\"ret\":{\"code\":0},\"devicesInfo\":[{\"udid\":\"aabbccdd\",\"deviceName\":\"d1\",\"id\":\"1\"},{\"udid\":\"EEFF0011\",\"deviceName\":\"d2\",\"id\":\"2\"}]}"

@Test
public func testParseDeviceListAndRegistered(): Unit {
    let devices = parseDeviceList(JsonValue.fromStr(DEV_LIST_JSON))
    @Assert(devices.size, 2)
    @Assert(devices[0].udid, "aabbccdd")
    @Assert(devices[1].name, "d2")
    // UDID 比较要大小写不敏感（AGC 侧统一大写，我们统一大写后比）
    @Assert(deviceRegistered(devices, "eeff0011"), true)
    @Assert(deviceRegistered(devices, "AAbbCCdd"), true)
    @Assert(deviceRegistered(devices, "nope"), false)
    @Assert(deviceRegistered(devices, ""), false)
    // 失败响应不该被当成"有设备"
    @Assert(parseDeviceList(JsonValue.fromStr("{\"ret\":{\"code\":1,\"msg\":\"x\"}}")).size, 0)
    @Assert(parseDeviceList(JsonValue.fromStr("[]")).size, 0)
}

@Test
public func testParseCertListAndFindByName(): Unit {
    let json = "{\"ret\":{\"code\":0},\"certList\":[" +
        "{\"id\":\"c1\",\"certName\":\"auto_debug_team.cer\",\"certObjectId\":\"o1\"}," +
        "{\"id\":\"c2\",\"certName\":\"other.cer\",\"certObjectId\":\"o2\"}]}"
    let certs = parseCertList(JsonValue.fromStr(json))
    @Assert(certs.size, 2)
    match (findCertByName(certs, "auto_debug_team.cer")) {
        case Some(c) =>
            @Assert(c.id, "c1")
            @Assert(c.certObjectId, "o1")
        case None => @Assert(true, false)
    }
    @Assert(findCertByName(certs, "nope.cer").isNone(), true)
    // 名字必须逐字相等（不猜前缀、不做包含匹配：命名是确定性的）
    @Assert(findCertByName(certs, "auto_debug").isNone(), true)
}

@Test
public func testDeviceTypeJudgingOrder(): Unit {
    // liteWearable 必须先于 wearable 判，否则 "wearable" 子串会把前者吃掉
    @Assert(deviceTypeOf("liteWearable"), "1")
    @Assert(deviceTypeOf("wearable"), "2")
    @Assert(deviceTypeOf("tv"), "3")
    @Assert(deviceTypeOf("default"), "4")
    @Assert(deviceTypeOf(""), "4")
    @Assert(deviceTypeOf("  phone \n"), "4")     // 手机/平板/PC 在 flutter 里都落 4
}

@Test
public func testRequestBodies(): Unit {
    // device/add：udid 归一成大写、deviceName 带前缀（唯一性靠 nonce）
    // 断语义不断字节：解析后按字段断（JSON 序列化的空白/转义不归这里管）
    let devJson = JsonValue.fromStr(buildDeviceAddBody("aabbccdd", "4", "abc123"))
    @Assert(strOf(devJson, "udid"), "AABBCCDD")
    @Assert(strOf(devJson, "deviceType"), "4")
    @Assert(strOf(devJson, "deviceName").contains("lingqu_device_abc123"), true)
    // cert/add：三个字段齐全（certType 1=debug / 2=release）
    let certJson = JsonValue.fromStr(buildCertAddBody("-----BEGIN CERTIFICATE REQUEST-----", "auto_debug_t.cer", "1"))
    @Assert(strOf(certJson, "certName"), "auto_debug_t.cer")
    @Assert(strOf(certJson, "certType"), "1")
    @Assert(strOf(certJson, "csr").contains("CERTIFICATE REQUEST"), true)
    // provision/add：debug 带 deviceList；空则不带；acl 空也不带（带空数组 AGC 会判非法）
    let certs = ArrayList<String>()
    certs.add("c1")
    let devs = ArrayList<String>()
    devs.add("AABB")
    let provJson = JsonValue.fromStr(buildProvisionBody(certs, "com.a.b", "0123456789abcdef", devs,
        ArrayList<String>()))
    @Assert(strOf(provJson, "packageName"), "com.a.b")
    @Assert(strOf(provJson, "provisionName"), "0123456789abcdef")
    @Assert(arrLenOf(provJson, "certList"), 1)
    @Assert(arrLenOf(provJson, "deviceList"), 1)          // debug profile 必须带设备白名单
    @Assert(arrLenOf(provJson, "aclPermissionList"), 0)   // 空 ACL 不带这个键
    let provNoDev = JsonValue.fromStr(buildProvisionBody(certs, "com.a.b", "p", ArrayList<String>(),
        ArrayList<String>()))
    @Assert(arrLenOf(provNoDev, "deviceList"), 0)
    let acls = ArrayList<String>()
    acls.add("ohos.permission.INTERNET")
    let provAclJson = JsonValue.fromStr(buildProvisionBody(certs, "com.a.b", "p", devs, acls))
    @Assert(arrLenOf(provAclJson, "aclPermissionList"), 1)
    @Assert(provAclJson.toString().contains("ohos.permission.INTERNET"), true)
}

@Test
public func testParseProvisionAdd(): Unit {
    let (id, url) = parseProvisionAdd(
        JsonValue.fromStr("{\"ret\":{\"code\":0},\"id\":\"98\",\"provisionFileUrl\":\"https://x/y.p7b\"}"))
    @Assert(id, "98")
    @Assert(url, "https://x/y.p7b")
    // 失败响应不返回任何东西（别把错误响应当成"拿到 id 了"）
    let (id2, url2) = parseProvisionAdd(JsonValue.fromStr("{\"ret\":{\"code\":205389938}}"))
    @Assert(id2, "")
    @Assert(url2, "")
}

@Test
public func testDownloadUrlSsrfGuard(): Unit {
    // 只放 https 公网
    @Assert(isSafeDownloadUrl("https://obs.cn-north-4.myhuaweicloud.com/a/b.p7b"), true)
    @Assert(isSafeDownloadUrl("http://obs.example.com/a.p7b"), false)         // 非 https
    // 本机回环
    @Assert(isSafeDownloadUrl("https://127.0.0.1/a"), false)
    @Assert(isSafeDownloadUrl("https://localhost:8443/a"), false)
    @Assert(isSafeDownloadUrl("https://[::1]/a"), false)
    // 内网段
    @Assert(isSafeDownloadUrl("https://10.1.2.3/a"), false)
    @Assert(isSafeDownloadUrl("https://192.168.0.9/a"), false)
    @Assert(isSafeDownloadUrl("https://169.254.1.1/a"), false)
    @Assert(isSafeDownloadUrl("https://172.16.5.4/a"), false)
    @Assert(isSafeDownloadUrl("https://172.31.5.4/a"), false)
    // 172.32 不在私有段内，应放行（别把整段 172 都拒了）
    @Assert(isSafeDownloadUrl("https://172.32.5.4/a"), true)
    @Assert(isSafeDownloadUrl("https://172.15.5.4/a"), true)
    // 内网后缀
    @Assert(isSafeDownloadUrl("https://svc.internal/a"), false)
    @Assert(isSafeDownloadUrl("https://svc.local/a"), false)
    @Assert(isSafeDownloadUrl(""), false)
}

@Test
public func testAsciiCaseAndDigitHelpers(): Unit {
    @Assert(upperAscii("abC-12_中文"), "ABC-12_中文")     // 只动 ASCII
    @Assert(lowerAscii("AbC-12"), "abc-12")
    @Assert(upperAscii(""), "")
    @Assert(digitsOnlyValue("31"), 31)
    @Assert(digitsOnlyValue(" 16 "), 16)
    @Assert(digitsOnlyValue("1a"), -1)
    @Assert(digitsOnlyValue(""), -1)
    @Assert(digitsOnlyValue("999999999"), -1)             // 荒谬的长数字不参与判断
}

/** 本地取字符串字段（compiler 包里的同名函数不对外，测试里自备一个） */
func strOf(root: JsonValue, key: String): String {
    match (root.kind()) {
        case JsonKind.JsObject => match (root.asObject().get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return ""
            }
            case None => return ""
        }
        case _ => return ""
    }
}

/** 本地取数组长度（0 = 没这个键或不是数组） */
func arrLenOf(root: JsonValue, key: String): Int64 {
    match (root.kind()) {
        case JsonKind.JsObject => match (root.asObject().get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsArray => return v.asArray().size()
                case _ => return 0
            }
            case None => return 0
        }
        case _ => return 0
    }
}

// ============================================================
// 0.39.18：自动签名编排层（不联网即可验的部分）
// ============================================================

@Test
public func testAutoSignFailsFastWithoutToken(): Unit {
    // 没有令牌时必须**立刻**报"先去登录"，不能先跑去连 AGC（那样既慢又难排障）
    let inp = AutoSignInput()
    inp.bundleName = "com.a.b"
    inp.udid = "AABB"
    let tok = AgcLoginOutcome()          // 空令牌
    let r = autoSign(inp, tok)
    @Assert(r.ok, false)
    @Assert(r.error.contains("--login"), true)
    @Assert(r.steps.size, 0)             // 一步都没走
    // 只有 accessToken 没有 userId 也算没有令牌（AGC 头要 uid）
    let tok2 = AgcLoginOutcome()
    tok2.accessToken = "x"
    @Assert(autoSign(inp, tok2).ok, false)
}

@Test
public func testAutoSignOutcomeJsonShape(): Unit {
    let o = AutoSignOutcome()
    o.add("① 一")
    o.add("② 二")
    o.teamId = "t1"
    o.certName = "auto_debug_t1.cer"
    o.passwordLen = 10
    let j = o.toJson()
    let steps = arrLenOf(j, "steps")
    @Assert(steps, 2)
    @Assert(strOf(j, "teamId"), "t1")
    @Assert(strOf(j, "certName"), "auto_debug_t1.cer")
    @Assert(j.toString().contains("\"passwordLen\":10"), true)
    // 落档里**不能**出现任何口令明文/密文（只有长度）
    @Assert(j.toString().contains("storePassword"), false)
}