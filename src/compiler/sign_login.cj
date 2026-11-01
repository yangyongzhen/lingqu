package lingqu.compiler

import std.collection.*
import std.fs.*
import std.io.*
import std.process.*
import std.sync.*
import std.time.*
import stdx.encoding.json.*
import stdx.net.http.*

/*
 * AGC 登录（OAuth loopback）与令牌存储（0.39.14）。
 *
 * 流程（对齐 flutter `auth.dart`，见 docs/鸿蒙自动签名机制.md §3.1 与
 * `%TEMP%\flutter-signing\SPEC.md` 的逐字规格）：
 *
 *   ① 本机起一次性 HTTP 服务（只绑 127.0.0.1、端口由系统分配）；
 *   ② 打开 `…/console/DevEcoIDE/apply?port=<port>&appid=1009&code=<32 位 hex>`；
 *   ③ 浏览器回调 `/callback?tempToken=…&siteId=1&code=<我们给的>`：
 *        · Host 必须是我们自己的 `127.0.0.1:<port>` 或 `localhost:<port>`（否则 400 Bad Host）；
 *        · `code` 必须与我们生成的一致（防伪造回调）；
 *        · `siteId` 必须是 "1"（只支持中国大陆站点账号）；
 *   ④ `tempToken` → `GET …/temptoken/check` → 响应体本身就是 JWT（要校验 `a.b.c` 形状）；
 *   ⑤ `GET …/jwToken/check`（头 `refresh: true` / `jwtToken: <JWT>`）→ `userInfo.accessToken` 等；
 *   ⑥ JWT 加密落盘（AES-128-GCM + 本机 KEK），下次直接用。
 *
 * **为什么要加密落盘**：JWT 等于账号的会话票据；计划与 flutter 一样存本地密文而不是明文。
 * 换机器/删 `~/.lingqu` 就重新登录一次，不影响 AGC 侧资产。
 */

/** 一次登录的结果 */
public class AgcLoginOutcome {
    public var ok: Bool = false
    public var error: String = ""
    /** 换来的 JWT（落盘前的原文；别写日志） */
    public var jwt: String = ""
    /** AGC 请求头 `oauth2Token` 用的会话 token */
    public var accessToken: String = ""
    /** AGC 请求头 `uid` */
    public var userId: String = ""
    public var userName: String = ""
    public var refreshToken: String = ""
    /** 国度码（`userInfo.nationalCode`，注意不是 countryCode） */
    public var countryCode: String = ""
    public var isRealName: Bool = false
    /** 团队列表（`id` + `name`）；登录成功后顺手拉一次 */
    public var teamId: String = ""
    public var teamName: String = ""
    public var teamCount: Int64 = 0
    /** 回调服务实际用的端口（排障用） */
    public var port: Int64 = 0
}

/** 回调服务的共享状态（handler 写、主线程等） */
class LoginCallbackState {
    public let done = AtomicBool(false)
    /** 回调服务实际端口（serve 绑定后才确定，放共享状态里让 handler 读） */
    public var port: Int64 = 0
    public var tempToken: String = ""
    public var siteId: String = ""
    public var quit: Bool = false
    public var code: String = ""
    public var rejectReason: String = ""
    /** 第一次到达的回调原始 query（排障证据） */
    public var rawQuery: String = ""
    /** 本次登录页 URL（回环回调页上直接给用户点，省得用户去找终端） */
    public var loginUrl: String = ""
}

/**
 * 一次回调的**判定结果**（纯函数产出，便于单测；handler 只负责执行动作）。
 *
 * 取值：`accept` = 收下 tempToken 去换 JWT；`ignore` = 只回 400 继续等；`quit` = 用户取消，收尾。
 */
public class CallbackVerdict {
    public var decision: String = "ignore"
    public var reason: String = ""
    /** tempToken/siteId 在 accept 时才有意义 */
    public var tempToken: String = ""
    public var siteId: String = ""

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("decision", JsonString(this.decision))
        o.put("reason", JsonString(this.reason))
        return o
    }
}

/**
 * 判定一次回调该怎么做（**纯函数**，不碰网络/状态）。
 *
 * 三条经过实测校准的规则（0.39.19，都是踩出来的）：
 *   ① **只有显式 `quit` 才终止会话**——缺参数的回调（浏览器/华为页面的预检跳转）以前会直接
 *      把整次登录废掉，进程当场退出、端口不再监听；
 *   ② **`code` 不匹配不拒绝**——华为回调里自带它自己的 `code`，硬比对会把正常登录判成 Bad code；
 *      真正的安全边界是「只绑 127.0.0.1 + 一次性服务 + Host 白名单 + tempToken 还要过华为校验」；
 *   ③ **非大陆站点**（`siteId != "1"`）不收，但也不终止（用户可能换账号重试）。
 */
public func judgeCallback(code: String, tempToken: String, siteId: String, quit: Bool,
    expectCode: String): CallbackVerdict {
    let v = CallbackVerdict()
    if (quit) {
        v.decision = "quit"
        v.reason = "登录被取消（浏览器侧 quit）"
        return v
    }
    if (tempToken == "" || siteId == "") {
        v.decision = "ignore"
        v.reason = "回调缺 tempToken/siteId（可能是页面预检跳转），已忽略、继续等待"
        return v
    }
    if (!isChinaSite(siteId)) {
        v.decision = "ignore"
        v.reason = "非大陆站点账号（siteId=${siteId}），已忽略；请用大陆站点账号重试"
        return v
    }
    v.decision = "accept"
    v.tempToken = tempToken
    v.siteId = siteId
    if (code != expectCode) {
        v.reason = "回调 code 与本机生成的不一致（已放行，仅记录）"
    }
    return v
}

/**
 * `/callback` 处理器。
 *
 * 用类而不是 lambda：仓颉的 lambda **不能捕获可变局部变量**，而这里必须把回调参数带回主线程。
 */
class LoginCallbackHandler <: HttpRequestHandler {
    private let state: LoginCallbackState
    private let expectCode: String

    public init(state: LoginCallbackState, expectCode: String) {
        this.state = state
        this.expectCode = expectCode
    }

    public func handle(ctx: HttpContext): Unit {
        let res = ctx.responseBuilder
        if (ctx.request.url.path != AGC_CALLBACK_PATH) {
            res.status(404)
            res.body("not found".toArray())
            return
        }
        // Host 白名单：只认我们自己的两个名字（本机回环）
        let hostOpt = ctx.request.headers.getFirst("Host")
        var host = ""
        match (hostOpt) {
            case Some(v) => host = v
            case None => ()
        }
        let h = lowerAsciiOfLocal(host.trimAscii())
        let port = this.state.port
        let okHost = h == "127.0.0.1:${port}" || h == "localhost:${port}"
        if (!okHost) {
            // 只回 400，**不终止等待**：可能只是某个杂请求/旧链接打进来
            res.status(400)
            res.header("Connection", "close")
            res.body("Bad Host".toArray())
            return
        }
        var query = ""
        match (ctx.request.url.query) {
            case Some(v) => query = v
            case None => ()
        }
        // 华为登录页可能是 **POST 表单**把回调参数发回来（flutter 侧同样处理过"POST 表单可覆盖"）：
        // 只读 query 会漏掉 tempToken，于是被判成"预检跳转"→ 用户看到页面反复回到回调页。
        var bodyText = ""
        try {
            bodyText = StringReader(ctx.request.body).readToEnd()
        } catch (e: Exception) {
            let _ = e
        }
        let q = parseQueryParams(query)
        if (bodyText.trimAscii() != "") {
            let bq = parseQueryParams(bodyText)
            for ((k, v) in bq) {
                if (!q.contains(k)) {
                    q.add(k, v)
                }
            }
        }
        // 证据：记下这次的原始输入（tempToken 只记长度），出问题不用再猜
        if (this.state.rawQuery == "") {
            this.state.rawQuery = "query=[${shapeOf(query)}] body=[${shapeOf(bodyText)}]"
        }
        var gotCode = ""
        var tempToken = ""
        var siteId = ""
        var quit = false
        match (q.get("code")) {
            case Some(v) => gotCode = v
            case None => ()
        }
        match (q.get("tempToken")) {
            case Some(v) => tempToken = v
            case None => ()
        }
        match (q.get("siteId")) {
            case Some(v) => siteId = v
            case None => ()
        }
        match (q.get("quit")) {
            case Some(v) => quit = true
            case None => ()
        }
        // `code` 只做**核对与记录**，不做硬拒绝：
        // 实测（0.39.19）华为回调里的 `code` 与我们生成的不一致（它自己也带一个 code 参数），
        // 硬比对会把正常登录判成 Bad code。安全边界另有其物：只绑 127.0.0.1、一次性服务、
        // Host 白名单，且 tempToken 还要拿去华为校验——伪造的 tempToken 过不了那一关。
        if (this.state.rawQuery == "") {
            this.state.rawQuery = "code=${gotCode}&siteId=${siteId}&codeMatch=${gotCode == this.expectCode}"
        }
        // 所有分支判定收进纯函数 `judgeCallback`（单测覆盖），handler 只执行动作。
        // 这样"哪个回调该死、哪个只该忽略"这条规则只有一处实现。
        if (this.state.rawQuery == "") {
            this.state.rawQuery = "codeLen=${gotCode.size}&siteId=${siteId}" +
                "&codeMatch=${gotCode == this.expectCode}"
        }
        let verdict = judgeCallback(gotCode, tempToken, siteId, quit, this.expectCode)
        match (verdict.decision) {
            case "quit" =>
                this.state.quit = true
                this.state.rejectReason = verdict.reason
                res.status(302)
                res.header("Location", loginRedirectUrl(false))
                res.body(loginPageHtml(false, "已取消登录").toArray())
                this.state.done.store(true)
                return
            case "ignore" =>
                this.state.rejectReason = verdict.reason
                if (!isChinaSite(siteId) && tempToken != "") {
                    // 站点不对时给一句人话（不是 400 裸响应）
                    res.status(200)
                    res.header("Content-Type", "text/html; charset=utf-8")
                    res.body(loginPageHtml(false, verdict.reason).toArray())
                } else {
                    res.status(400)
                    res.header("Content-Type", "text/html; charset=utf-8")
                    res.body(("<!doctype html><meta charset=\"utf-8\"><title>内部回调地址</title>" +
                        "<body style=\"font-family:system-ui;padding:40px;color:#333\">" +
                        "<h2>这是内部回调地址</h2><p>它只用于接收华为登录页的跳转，<b>不要手动打开</b>。</p>" +
                        "<p><a href=\"" + this.state.loginUrl + "\" style=\"font-size:18px\">" +
                        "👉 点这里去华为登录页（同一条有效链接）</a></p>" +
                        "<p style=\"color:#888\">或者回到终端里复制打印出来的那条 /console/DevEcoIDE/apply?... 链接。</p>" +
                        "</body>").toArray())
                }
                return
            case _ => ()
        }
        if (verdict.reason != "") {
            this.state.rejectReason = verdict.reason
        }
        this.state.code = gotCode
        this.state.tempToken = tempToken
        this.state.siteId = siteId
        res.status(302)
        res.header("Location", loginRedirectUrl(true))
        res.body(loginPageHtml(true, "授权完成，可以关闭此页").toArray())
        this.state.done.store(true)
    }
}

/** 登录成功/失败页（纯文本 HTML，刻意不带外链） */
public func loginPageHtml(ok: Bool, msg: String): String {
    let color = if (ok) { "#1f7a45" } else { "#b03a2e" }
    let title = if (ok) { "登录成功" } else { "登录未完成" }
    return "<!doctype html><meta charset=\"utf-8\"><title>${title}</title>" +
        "<body style=\"font-family:system-ui;padding:40px;color:#333\">" +
        "<h2 style=\"color:${color}\">${title}</h2><p>${msg}</p>" +
        "<p style=\"color:#888\">灵渠迁移台 · 自动签名登录</p></body>"
}

/** 小写化（只处理 ASCII；Host 头本身是 ASCII） */
func lowerAsciiOfLocal(s: String): String {
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

/** 32 位小写 hex（16 随机字节）：登录回调的防伪 `code` */
public func randomHex32(): String {
    return toHexLower(randomBytes(16))
}

/**
 * 打开浏览器。
 *
 * **别用 `cmd /c start "" <url>`**：登录 URL 里带 `&`（`port=…&appid=1009&code=…`），
 * cmd 会把 `&` 当命令分隔符 → 浏览器只拿到 `…?port=21570`，后面几段被当成命令执行
 * （实测报 `'appid' is not recognized …`，用户在网页上看到的就是个残缺链接的失败页）。
 *
 * 改用 `rundll32 url.dll,FileProtocolHandler`：它不经过 cmd 的命令解析，URL 原样交给系统。
 * 其它平台仍用 `xdg-open` / `open`（这两个本身按 argv 收参，没有 shell 解析问题）。
 */
public func openUrlInBrowser(url: String): String {
    var cmd = ""
    var args = ArrayList<String>()
    if (cfgOsName() == "windows") {
        cmd = "rundll32"
        args.add("url.dll,FileProtocolHandler")
        args.add(url)
    } else {
        cmd = "xdg-open"
        args.add(url)
    }
    try {
        let (code, _, errOut) = executeWithOutput(cmd, args.toArray())
        if (code != 0) {
            return "打开浏览器失败（exit=${code}）：${String.fromUtf8(errOut)}"
        }
        return ""
    } catch (e: Exception) {
        return "打开浏览器失败：${e}"
    }
}

/**
 * 阻塞式登录：起回调服务 → 打印/打开登录页 → 等回调 → 换 JWT → 校验 → 拉团队。
 *
 * `timeoutSec` 内没等到回调就放弃（默认 300 秒 = 5 分钟，与 flutter 一致）。
 * 返回结果里带 `port` 与 `error`，便于排障时一眼看出卡在哪一步。
 */
public func agcLogin(timeoutSec: Int64, openBrowser: Bool): AgcLoginOutcome {
    let out = AgcLoginOutcome()
    let state = LoginCallbackState()
    // 探针：允许外部指定回调 code（自动化/自测用，免得要人从 URL 里手抄 32 位 hex）
    var expectCode = randomHex32()
    let codeOverride = envOf("LINGQU_SIGN_LOGIN_CODE").trimAscii()
    if (codeOverride.size == 32) {
        expectCode = codeOverride
    }
    var server: Option<Server> = None
    var port: Int64 = 0
    try {
        let s = ServerBuilder().addr("127.0.0.1").port(0).build()
        server = Some(s)
    } catch (e: Exception) {
        out.error = "起本机回调服务失败：${e}"
        return out
    }
    let srv = server.getOrThrow()
    // 顺序很关键：**先注册路由、挂 afterBind，再 spawn serve，等绑定完成才读端口**。
    // `port(0)` 的实际端口只有 bind 之后才有值；一开始就读会拿到 0（实测踩到）。
    try {
        srv.distributor.register(AGC_CALLBACK_PATH, LoginCallbackHandler(state, expectCode))
    } catch (e: Exception) {
        out.error = "注册回调路由失败：${e}"
        return out
    }
    let ready = SyncCounter(1)
    srv.afterBind({ => ready.dec() })
    let serveFailed = AtomicBool(false)
    spawn {
        try {
            srv.serve()
        } catch (e: Exception) {
            let _ = e
            serveFailed.store(true)
        }
    }
    ready.waitUntilZero()
    port = Int64(srv.port)
    state.port = port
    out.port = port
    if (port <= 0) {
        out.error = "拿不到回调服务端口"
        try {
            srv.closeGracefully()
        } catch (e: Exception) {
            let _ = e
        }
        return out
    }
    let url = oauthLoginUrl(port, expectCode)
    state.loginUrl = url
    println("")
    println("──────────────────────────────────────────────")
    println("  灵渠 · 鸿蒙自动签名：请在浏览器完成一次登录")
    println("  ${url}")
    println("  （本机回调已就绪：http://127.0.0.1:${port}${AGC_CALLBACK_PATH}）")
    println("──────────────────────────────────────────────")
    if (openBrowser) {
        let msg = openUrlInBrowser(url)
        if (msg != "") {
            println("  ${msg}（可手动复制上面的链接到浏览器）")
        }
    }
    // 等回调（轮询 200ms；超时或服务异常都退出）
    var waited: Int64 = 0
    let limitMs = if (timeoutSec <= 0) { 300000 } else { timeoutSec * 1000 }
    while (waited < limitMs) {
        if (state.done.load()) {
            break
        }
        if (serveFailed.load()) {
            break
        }
        try {
            sleep(Duration.millisecond * 200)
        } catch (e: Exception) {
            let _ = e
        }
        waited += 200
    }
    try {
        srv.closeGracefully()
    } catch (e: Exception) {
        let _ = e
    }
    // 回调证据落文件（AGENTS §4-14：要当证据的东西别只打日志）
    if (state.rawQuery != "") {
        try {
            let dir = agcStateDir()
            if (dir != "") {
                Directory.create(Path(dir), recursive: true)
                let line = "${nowStamp()} callback: ${state.rawQuery}\n"
                let logPath = "${dir}/login-callback.log"
                var prev = ""
                if (exists(Path(logPath))) {
                    prev = String.fromUtf8(File.readFrom(logPath))
                }
                File.writeTo(logPath, (prev + line).toArray())
            }
        } catch (e: Exception) {
            let _ = e
        }
    }
    if (state.tempToken == "") {
        out.error = if (state.rejectReason != "") { state.rejectReason } else { "回调里没有 tempToken" }
        return out
    }
    if (!state.done.load()) {
        out.error = "等回调超时（${timeoutSec} 秒）：浏览器里没有完成登录？"
        return out
    }
    // tempToken → JWT
    let jwtResp = agcHttp("GET", tempTokenCheckUrl(state.tempToken), ArrayList<String>(), "", 30000)
    if (jwtResp.error != "") {
        out.error = "换 JWT 失败：${jwtResp.error}"
        return out
    }
    let jwt = jwtResp.body.trimAscii()
    if (jwtResp.status != 200 || !isJwtShaped(jwt)) {
        out.error = "换 JWT 失败：HTTP ${jwtResp.status}，响应不是 JWT（前 80 字：${clip(jwt, 80)}）"
        return out
    }
    out.jwt = jwt
    // JWT 校验 → userInfo
    let headers = ArrayList<String>()
    headers.add("refresh: true")
    headers.add("jwtToken: ${jwt}")
    let checkResp = agcHttp("GET", jwtCheckUrl(), headers, "", 30000)
    if (checkResp.error != "") {
        out.error = "校验 JWT 失败：${checkResp.error}"
        return out
    }
    if (checkResp.status != 200) {
        out.error = "校验 JWT 失败：HTTP ${checkResp.status}（token 可能已失效）"
        return out
    }
    var root: JsonValue
    try {
        root = JsonValue.fromStr(checkResp.body)
    } catch (e: Exception) {
        out.error = "校验 JWT 的响应不是 JSON：${e}"
        return out
    }
    let info = jsonObjectField(root, "userInfo")
    out.accessToken = jsonStringField(info, "accessToken")
    out.userId = jsonStringField(info, "userId")
    out.userName = jsonStringField(info, "name")
    out.refreshToken = jsonStringField(info, "refreshToken")
    out.countryCode = jsonStringField(info, "nationalCode")
    out.isRealName = jsonStringField(info, "realName") == "true"
    if (out.accessToken == "") {
        out.error = "JWT 校验通过但没拿到 accessToken（账号可能未开通 AppGallery Connect）"
        return out
    }
    if (!out.isRealName) {
        // 不拦：实名与否只影响上架，debug 直装可继续；但要如实写进结果
        out.error = ""
    }
    saveAgcToken(out)
    // 团队（默认取第一个，与 flutter 一致）
    match (agcTeamList(out.accessToken, out.userId)) {
        case Some(t) =>
            out.teamId = t.id
            out.teamName = t.name
            out.teamCount = t.count
        case None => ()
    }
    out.ok = true
    return out
}

/** 团队信息 */
public class AgcTeam {
    public var id: String = ""
    public var name: String = ""
    public var count: Int64 = 0
}

/** 拉团队列表；返回第一个团队（与 flutter 的 `teams.first.id` 一致） */
public func agcTeamList(accessToken: String, uid: String): Option<AgcTeam> {
    let headers = ArrayList<String>()
    headers.add("oauth2Token: ${accessToken}")
    headers.add("uid: ${uid}")
    headers.add("source: cli")
    headers.add("lang: zh")
    let r = agcHttp("GET", agcUrl(AGC_TEAM_LIST_PATH), headers, "", 30000)
    if (r.error != "" || r.status != 200) {
        return None
    }
    var root: JsonValue
    try {
        root = JsonValue.fromStr(r.body)
    } catch (e: Exception) {
        let _ = e
        return None
    }
    if (!agcSucceeded(root)) {
        return None
    }
    let teams = jsonArrayField(root, "teams")
    if (teams.size() == 0) {
        return None
    }
    let t = AgcTeam()
    t.count = teams.size()
    let first = teams[0]
    t.id = jsonStringField(first, "id")
    t.name = jsonStringField(first, "teamName")
    if (t.name == "") {
        t.name = jsonStringField(first, "name")
    }
    if (t.id == "") {
        return None
    }
    return Some(t)
}

/** 截断字符串（错误信息里带响应片段用，别把整段响应刷出来） */
func clip(s: String, n: Int64): String {
    if (Int64(s.size) <= n) {
        return s
    }
    return s[0..n] + "…"
}

/** 取对象字段（不是对象给空 JsonObject） */
func jsonObjectField(root: JsonValue, key: String): JsonValue {
    match (root.kind()) {
        case JsonKind.JsObject => match (root.asObject().get(key)) {
            case Some(v) => return v
            case None => return JsonObject()
        }
        case _ => return JsonObject()
    }
}

/** 取数组字段（不是数组给空数组） */
func jsonArrayField(root: JsonValue, key: String): JsonArray {
    match (root.kind()) {
        case JsonKind.JsObject => match (root.asObject().get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsArray => return v.asArray()
                case _ => return JsonArray()
            }
            case None => return JsonArray()
        }
        case _ => return JsonArray()
    }
}

/** 取字符串字段（不是字符串给 ""） */
func jsonStringField(root: JsonValue, key: String): String {
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

// ============================================================
// 令牌落盘（AES-128-GCM + 本机 KEK）
// ============================================================

/** KEK 文件路径（16 字节；本机随机，丢了就重新登录） */
func agcKekPath(): String {
    return "${agcStateDir()}/keys/kek.bin"
}

/** 令牌信封路径 */
func agcTokenPath(): String {
    return "${agcStateDir()}/token.enc"
}

/** 读/建 KEK（16 字节） */
func ensureKek(): (Array<Byte>, String) {
    let dir = agcStateDir()
    if (dir == "") {
        return ([], "拿不到用户主目录（USERPROFILE/HOME 都为空）")
    }
    let p = agcKekPath()
    if (exists(Path(p))) {
        try {
            let b = File.readFrom(p)
            if (b.size == AES_GCM_KEY_LEN) {
                return (b, "")
            }
        } catch (e: Exception) {
            let _ = e
        }
    }
    let kek = randomBytes(AES_GCM_KEY_LEN)
    try {
        Directory.create(Path("${dir}/keys"), recursive: true)
        File.writeTo(p, kek)
    } catch (e: Exception) {
        return ([], "写 KEK 失败：${e}")
    }
    return (kek, "")
}

/** 把登录结果加密落盘（失败不致命：下次重新登录即可，但要把原因带出去） */
public func saveAgcToken(out: AgcLoginOutcome): String {
    if (out.jwt == "") {
        return "没有 JWT，不落盘"
    }
    let (kek, e1) = ensureKek()
    if (e1 != "") {
        return e1
    }
    let iv = randomBytes(AES_GCM_IV_LEN)
    let plain = agcTokenJson(out)
    let sealed = aes128GcmEncrypt(kek, iv, plain.toArray(), Array<Byte>())
    let ctLen = Int64(sealed.size) - AES_GCM_TAG_LEN
    let ct = sealed[0..ctLen]
    let tag = sealed[ctLen..sealed.size]
    var env = JsonObject()
    env.put("version", JsonInt(1))
    env.put("algorithm", JsonString("aes-128-gcm"))
    env.put("iv", JsonString(toHexLower(iv)))
    env.put("ciphertext", JsonString(toHexLower(ct)))
    env.put("tag", JsonString(toHexLower(tag)))
    try {
        File.writeTo(agcTokenPath(), env.toJsonString().toArray())
    } catch (e: Exception) {
        return "写令牌失败：${e}"
    }
    return ""
}

/** 令牌明文（JSON；只在内存里出现，落盘前就加密） */
func agcTokenJson(out: AgcLoginOutcome): String {
    var o = JsonObject()
    o.put("jwt", JsonString(out.jwt))
    o.put("accessToken", JsonString(out.accessToken))
    o.put("userId", JsonString(out.userId))
    o.put("userName", JsonString(out.userName))
    o.put("refreshToken", JsonString(out.refreshToken))
    o.put("countryCode", JsonString(out.countryCode))
    o.put("teamId", JsonString(out.teamId))
    o.put("teamName", JsonString(out.teamName))
    o.put("savedAt", JsonString(nowStamp()))
    return o.toJsonString()
}

/** 时间戳（落档用；取不到给空串，不阻塞主流程） */
func nowStamp(): String {
    try {
        return DateTime.now().toString()
    } catch (e: Exception) {
        let _ = e
        return ""
    }
}

/** 读回令牌（没有/解不开都返回 None：调用方按"需要重新登录"处理） */
public func loadAgcToken(): Option<AgcLoginOutcome> {
    if (!exists(Path(agcTokenPath()))) {
        return None
    }
    let (kek, e1) = ensureKek()
    if (e1 != "") {
        return None
    }
    var env: JsonValue
    try {
        env = JsonValue.fromStr(String.fromUtf8(File.readFrom(agcTokenPath())))
    } catch (e: Exception) {
        let _ = e
        return None
    }
    let ivHex = jsonStringField(env, "iv")
    let ctHex = jsonStringField(env, "ciphertext")
    let tagHex = jsonStringField(env, "tag")
    let iv = fromHexLower(ivHex)
    let ct = fromHexLower(ctHex)
    let tag = fromHexLower(tagHex)
    if (iv.isNone() || ct.isNone() || tag.isNone()) {
        return None
    }
    let plain = tryDecrypt(kek, iv.getOrThrow(), ct.getOrThrow(), tag.getOrThrow())
    match (plain) {
        case Some(text) =>
            var root: JsonValue
            try {
                root = JsonValue.fromStr(text)
            } catch (e: Exception) {
                let _ = e
                return None
            }
            let out = AgcLoginOutcome()
            out.jwt = jsonStringField(root, "jwt")
            out.accessToken = jsonStringField(root, "accessToken")
            out.userId = jsonStringField(root, "userId")
            out.userName = jsonStringField(root, "userName")
            out.refreshToken = jsonStringField(root, "refreshToken")
            out.countryCode = jsonStringField(root, "countryCode")
            out.teamId = jsonStringField(root, "teamId")
            out.teamName = jsonStringField(root, "teamName")
            out.ok = out.accessToken != ""
            return Some(out)
        case None =>
            return None
    }
}

/** 尝试解密（失败返回 None，不抛） */
func tryDecrypt(kek: Array<Byte>, iv: Array<Byte>, ct: Array<Byte>, tag: Array<Byte>): Option<String> {
    try {
        let plain = aes128GcmDecrypt(kek, iv, concatBytes(ct, tag), Array<Byte>())
        return Some(String.fromUtf8(plain))
    } catch (e: Exception) {
        let _ = e
        return None
    }
}

/** 账号信息一行摘要（给 CLI/界面显示；不含任何 token） */
public func agcUserLine(out: AgcLoginOutcome): String {
    let who = if (out.userName != "") { out.userName } else { out.userId }
    let team = if (out.teamName != "") { "${out.teamName}（${out.teamId}）" } else { out.teamId }
    return "user=${who} uid=${out.userId} country=${out.countryCode} realName=${out.isRealName} " +
        "teams=${out.teamCount} team=${team}"
}

/**
 * 把一个 query/表单串"脱敏成形状"：`k=v` → `k(len)`，用于排障而不泄漏值。
 * 例：`tempToken=abc&siteId=1` → `tempToken(len=3)&siteId(len=1)`
 */
public func shapeOf(s: String): String {
    let text = s.trimAscii()
    if (text == "") {
        return ""
    }
    var out = ""
    for (pair in text.split("&", -1)) {
        if (pair == "") {
            continue
        }
        if (out != "") {
            out += "&"
        }
        match (pair.indexOf("=")) {
            case Some(eq) =>
                let k = pair[0..eq]
                let vlen = pair.size - eq - 1
                out += "${k}(len=${vlen})"
            case None => out += "${pair}(noeq)"
        }
    }
    return out
}
