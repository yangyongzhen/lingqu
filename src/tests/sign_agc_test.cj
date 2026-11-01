package lingqu.tests

import std.collection.*
import stdx.encoding.json.*
import lingqu.compiler.*

/*
 * 自动签名「路线 A」纯函数层单测（0.39.12）。
 *
 * 这些函数决定"我们拼出的 URL / 派生出的名字"是否与 DevEco / AGC 一致——
 * 错一个字符的后果不是报错，而是**静默地问错东西或写出对不上号的文件**，所以逐条钉住。
 * 期望值来自 docs/鸿蒙自动签名机制.md（其 §9 标注了每条事实的源码出处）与独立计算。
 */

@Test
public func testOauthLoginUrlShape(): Unit {
    let u = oauthLoginUrl(18766, "0123456789abcdef0123456789abcdef")
    @Assert(u.startsWith("https://cn.devecostudio.huawei.com/console/DevEcoIDE/apply?"), true)
    @Assert(u.contains("port=18766"), true)
    @Assert(u.contains("appid=1009"), true)          // DevEco 系列固定 appid
    @Assert(u.contains("code=0123456789abcdef"), true)
    // JWT 校验地址与登录页不同源，别混
    @Assert(jwtCheckUrl(), "https://cn.devecostudio.huawei.com/authrouter/auth/api/jwToken/check")
    // AGC 业务接口基址
    @Assert(agcUrl(AGC_CERT_LIST_PATH), "https://connect-api.cloud.huawei.com/api/cps/harmony-cert-manage/v1/cert/list")
}

@Test
public func testTempTokenCheckUrl(): Unit {
    let u = tempTokenCheckUrl("abc123")
    @Assert(u.contains("tempToken=abc123"), true)
    @Assert(u.contains("site=CN"), true)             // 只支持大陆站点
    @Assert(u.contains("version=1.0.0"), true)
    @Assert(u.contains("appid=1009"), true)
    // 浏览器可能拼上额外参数：按 & 截断（flutter 的 .split('&').first）
    let u2 = tempTokenCheckUrl("tok&extra=1")
    @Assert(u2.contains("tempToken=tok&"), true)
    @Assert(u2.contains("extra"), false)
}

@Test
public func testParseQueryParamsAndUrlCodec(): Unit {
    let q = parseQueryParams("tempToken=aa%3Dbb&siteId=1&quit=&state")
    @Assert(q.contains("tempToken"), true)
    @Assert(q.get("tempToken").getOrThrow(), "aa=bb")
    @Assert(q.get("siteId").getOrThrow(), "1")
    @Assert(q.get("quit").getOrThrow(), "")
    // 裸键（无 =）也要收下，值按空串
    @Assert(q.get("state").getOrThrow(), "")
    // 重复键保留第一次
    let dup = parseQueryParams("a=1&a=2")
    @Assert(dup.get("a").getOrThrow(), "1")
    // 空串 / 只有分隔符
    @Assert(parseQueryParams("").size, 0)
    @Assert(parseQueryParams("&&&").size, 0)
    // 编解码往返
    @Assert(urlDecode("a%2Fb+c"), "a/b c")
    @Assert(urlEncode("a/b c"), "a%2Fb%20c")         // 空格必须是 %20，不是 '+'
    @Assert(urlDecode("bad%zz"), "bad%zz")           // 非法转义原样保留，不抛
}

@Test
public func testJwtAndSiteChecks(): Unit {
    @Assert(isJwtShaped("aaa.bbb.ccc"), true)
    @Assert(isJwtShaped("a-b_c.d.e-f_1"), true)
    @Assert(isJwtShaped("aaa.bbb"), false)           // 两段不是 JWT
    @Assert(isJwtShaped("aaa.bbb.ccc.ddd"), false)   // 四段不是
    @Assert(isJwtShaped("aaa.bb b.ccc"), false)      // 含空格
    @Assert(isJwtShaped(""), false)
    // 只认中国大陆站点（字符串 "1"，不是数字）
    @Assert(isChinaSite("1"), true)
    @Assert(isChinaSite(" 1 "), true)
    @Assert(isChinaSite("2"), false)
    @Assert(isChinaSite(""), false)
}

@Test
public func testCertAndProvisionNaming(): Unit {
    // 证书名确定性：auto_debug_<teamId 去掉 \ / . :>.cer
    @Assert(certNameFor("abc123"), "auto_debug_abc123.cer")
    @Assert(certNameFor("team.1/2:3\\4"), "auto_debug_team_1_2_3_4.cer")
    // provisionName = sha256("{product}_{bundle}_{bundle}")[0:16]
    // 期望值由独立实现（PowerShell 的 SHA256）算出，不是自证
    @Assert(provisionNameOf("default", "com.atomgit.m3u8dl_tauri"), "9619c9927145017d")
    @Assert(provisionNameOf("default", "com.a.b"), "751a75f6616cc3d4")
    @Assert(provisionNameOf("default", "com.a.b").size, 16)
    // bundle 出现两次是刻意（DevEco 的确定性命名），改一次就必须两边都改
    @Assert(provisionNameOf("default", "com.a.b"), provisionNameOf("default", "com.a.b"))
}

@Test
public func testAgcResponseJudging(): Unit {
    // 成功判据是 body 里 ret.code == 0，不是 HTTP 200
    let ok = JsonValue.fromStr("{\"ret\":{\"code\":0,\"msg\":\"ok\"}}")
    @Assert(agcSucceeded(ok), true)
    @Assert(agcErrorCode(ok), 0)
    let bad = JsonValue.fromStr("{\"ret\":{\"code\":205389857,\"msg\":\"The device name already exists\"}}")
    @Assert(agcSucceeded(bad), false)
    @Assert(agcErrorCode(bad), 205389857)
    @Assert(agcErrorMsg(bad), "The device name already exists")
    // msg 可能是被 JSON 编码过的字符串 / 对象；对象形态也要能取
    let objMsg = JsonValue.fromStr("{\"ret\":{\"code\":1,\"msg\":{\"detail\":\"x\"}}}")
    @Assert(agcErrorMsg(objMsg).contains("detail"), true)
    // 非对象 / 缺 ret / 缺 code 一律按失败处理（不猜成功）
    @Assert(agcSucceeded(JsonValue.fromStr("[]")), false)
    @Assert(agcSucceeded(JsonValue.fromStr("{}")), false)
    @Assert(agcSucceeded(JsonValue.fromStr("{\"ret\":{}}")), false)
    @Assert(agcErrorCode(JsonValue.fromStr("{}")), -1)
    @Assert(agcErrorMsg(JsonValue.fromStr("{}")), "")
}

// ============================================================
// 0.39.14：登录层的纯函数（loopback 回调与页面文案）
// ============================================================

@Test
public func testLoginPurePartsFromModule(): Unit {
    // 32 位小写 hex（防伪 code 的形态）
    let code = randomHex32()
    @Assert(code.size, 32)
    @Assert(fromHexLower(code).isSome(), true)
    // 两次生成必须不同（随机源真的在动；同值说明拿到了固定种子）
    @Assert(randomHex32() == randomHex32(), false)
    // 成功/失败页文案：成功走绿色、失败走红色，都带"关闭此页"类提示
    let okPage = loginPageHtml(true, "授权完成，可以关闭此页")
    @Assert(okPage.contains("登录成功"), true)
    @Assert(okPage.contains("#1f7a45"), true)
    @Assert(okPage.contains("灵渠迁移台"), true)
    let badPage = loginPageHtml(false, "只支持中国大陆站点账号")
    @Assert(badPage.contains("登录未完成"), true)
    @Assert(badPage.contains("#b03a2e"), true)
    // 用户摘要串：不含任何 token，只放身份与团队
    let o = AgcLoginOutcome()
    o.userId = "u1"
    o.userName = "张三"
    o.countryCode = "CN"
    o.teamId = "t1"
    o.teamName = "我的团队"
    o.teamCount = 1
    let line = agcUserLine(o)
    @Assert(line.contains("uid=u1"), true)
    @Assert(line.contains("我的团队"), true)
    @Assert(line.contains("token"), false)             // 摘要里绝不能出现 token 字样
}

// 0.39.17：登录 URL 含 `&`，打开浏览器时**不能经过 shell 解析**
// （实测踩到：`cmd /c start "" <url>` 把 `&appid=...` 当命令执行，浏览器只拿到截断地址）
@Test
public func testLoginUrlCarriesAmpersands(): Unit {
    let u = oauthLoginUrl(21570, "e02979284c2f35434ea60f19eabd8bc5")
    // 三个参数必须都在（少一个就不是能用的登录链接）
    @Assert(u.contains("?port=21570&"), true)
    @Assert(u.contains("&appid=1009&"), true)
    @Assert(u.contains("&code=e02979284c2f35434ea60f19eabd8bc5"), true)
    // 提醒未来改这段代码的人：url 里带 & 就绝不能交给 shell 解析
    @Assert(u.split("&", -1).size >= 3, true)
}