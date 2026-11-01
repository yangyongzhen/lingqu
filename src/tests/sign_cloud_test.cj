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

// ============================================================
// 0.39.20：签名工具链的定位逻辑（纯函数部分）
// ============================================================

@Test
public func testJavaAndJarCandidatesShapes(): Unit {
    // java：JAVA_HOME → DevEco JBR → PATH 裸名，三条都要在（顺序即优先级）
    // 四条：JAVA_HOME → DevEco JBR → DevEco JRE → PATH 裸名（顺序即优先级）
    let j = javaCandidates("D:/jdk", "D:/DevEco")
    @Assert(j.size, 4)
    @Assert(j[0].contains("jdk"), true)
    @Assert(j[0].endsWith("java.exe"), true)
    @Assert(j[1].contains("jbr"), true)
    @Assert(j[2].contains("jre"), true)
    @Assert(j[3], "java")                       // 兜底裸名，交给 PATH
    // 两个环境变量都空时只剩裸名（不猜路径）
    let j2 = javaCandidates("", "")
    @Assert(j2.size, 1)
    @Assert(j2[0], "java")

    // jar：SDK 三档布局都要试到（default → 根 → 版本目录）
    let jars = hapSignToolCandidates("D:/sdk")
    @Assert(jars.size >= 2, true)
    @Assert(jars[0].contains("default"), true)
    @Assert(jars[0].endsWith("hap-sign-tool.jar"), true)
    @Assert(jars[1].contains("openharmony"), true)
    // SDK 为空的极端情况：不返回任何候选（由调用方报"找不到 jar"）
    @Assert(hapSignToolCandidates("").size, 0)
}

@Test
public func testFirstExistingSkipsBareName(): Unit {
    // 裸名 "java" 无从判断存在性 → 必须跳过，交给执行期
    let cands = ArrayList<String>()
    cands.add("java")
    @Assert(firstExisting(cands), "")
    // 真实存在的路径要挑出来（用当前目录下的 cjpm.toml 当靶子）
    let c2 = ArrayList<String>()
    c2.add("java")
    c2.add("cjpm.toml")
    @Assert(firstExisting(c2), "cjpm.toml")
}

@Test
public func testPasswordAndArgBuilding(): Unit {
    // 随机口令：纯字母数字、7~10 位（8 随机字节 → base64url 去 -_= 后长度会变）
    let pwd = randomPasswordAlnum()
    @Assert(pwd.size >= 6 && pwd.size <= 11, true)
    for (b in pwd.toArray()) {
        let alnum = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
        @Assert(alnum, true)                     // 不能出现 - _ = ，否则当命令行参数会出问题
    }
    @Assert(randomPasswordAlnum() == randomPasswordAlnum(), false)
    // keypair 参数：**没有 -outFile**；csr 参数：**有 -outFile**
    let ka = keypairArgs("debugKey", "x.p12", "pwd")
    var hasOut = false
    for (a in ka) {
        if (a == "-outFile") {
            hasOut = true
        }
    }
    @Assert(hasOut, false)
    let ca = csrArgs("debugKey", "x.p12", "pwd", "x.csr")
    var hasOut2 = false
    for (a in ca) {
        if (a == "-outFile") {
            hasOut2 = true
        }
    }
    @Assert(hasOut2, true)
    // 打码：紧跟 -keystorePwd / -keyPwd 的值必须变成 ******
    let masked = maskSecrets(ka)
    @Assert(masked.contains("******"), true)
    @Assert(masked.contains("pwd"), false)       // 原始口令不得出现在日志串里
}

@Test
public func testUsableCertAndStaleSelection(): Unit {
    // 0.39.22：证书"名字对得上"≠"能用" —— 过期那张拿去申请 profile 会被回
    // `The certList is invalid.`，所以可用性必须看有效期/状态
    let mk = { id: String, name: String, expire: Int64, status: Int64 =>
        let c = AgcCert()
        c.id = id
        c.certName = name
        c.expireMs = expire
        c.status = status
        c
    }
    let now = nowMs()
    let live = mk("c1", "auto_debug_40574614.cer", now + 86400000, 1)
    let dead = mk("c2", "auto_debug_40574614.cer", now - 86400000, 2)
    let noExpire = mk("c3", "x.cer", 0, 0)          // 取不到到期时间 → 视为不判过期
    @Assert(live.usable(), true)
    @Assert(dead.usable(), false)
    @Assert(noExpire.usable(), true)
    @Assert(mk("", "y.cer", now + 1, 1).usable(), false)     // 没有 id 就没法申请 profile

    // 按名字挑"可用"的那张：同名的过期件要被跳过
    let all = ArrayList<AgcCert>()
    all.add(dead)
    all.add(live)
    match (findUsableCert(all, "auto_debug_40574614.cer")) {
        case Some(c) => @Assert(c.id, "c1")
        case None => @Assert(true, false)
    }
    // 只有过期件时 → 找不到可用证书（触发"删旧+新建"分支）
    let onlyDead = ArrayList<AgcCert>()
    onlyDead.add(dead)
    @Assert(findUsableCert(onlyDead, "auto_debug_40574614.cer").isNone(), true)
    @Assert(findCertByName(onlyDead, "auto_debug_40574614.cer").isSome(), true)

    // 自动签名的命名识别：只认自己产出的前缀，别去删用户在控制台建的证书
    @Assert(isAutoSignCertName("auto_debug_40574614.cer"), true)
    @Assert(isAutoSignCertName("AUTO_RELEASE_40574614.cer"), true)   // 大小写不敏感
    @Assert(isAutoSignCertName("yangTest"), false)
    @Assert(isAutoSignCertName("my_auto_debug_x.cer"), false)        // 前缀必须从头开始
    @Assert(isAutoSignCertName(""), false)

    // 腾位置：只挑"过期 + 自动签名命名"的
    let pool = ArrayList<AgcCert>()
    pool.add(dead)                                   // 过期 + auto_debug → 选中
    pool.add(live)                                   // 未过期 → 不选
    pool.add(mk("c4", "yangTest", now - 1, 2))       // 过期但不是我们建的 → 不碰
    pool.add(mk("c5", "auto_release_40574614.cer", now - 1, 2))   // 过期 + auto_release → 选中
    let stale = staleCertsOf(pool)
    @Assert(stale.size, 2)
    @Assert(stale[0].id, "c2")
    @Assert(stale[1].id, "c5")
    // 空列表 / 全都可用 → 不删任何东西
    @Assert(staleCertsOf(ArrayList<AgcCert>()).size, 0)
    let allLive = ArrayList<AgcCert>()
    allLive.add(live)
    @Assert(staleCertsOf(allLive).size, 0)
}