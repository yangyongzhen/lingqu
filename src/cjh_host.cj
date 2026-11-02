package lingqu

import std.convert.*          // Int64.parse
import std.crypto.digest.*    // digest<T> 泛型函数在 std 侧
import stdx.crypto.digest.*   // 具体实现 SHA256 在 stdx 侧（两处都要 import）
import std.env.*
import std.fs.*
import std.io.*            // InputStream（读 HTTP 响应体）
import std.time.*          // DateTime（健康检查的宽容窗口要取时刻）
import std.collection.*    // ArrayList
// SubProcess / launch：非 Windows 分支一直用；Windows 侧 0.39.40 起也用它（让 cjh 继承
// 我们的隐藏控制台，避免它再拉 bash/find 时各自弹黑窗）。因此两边都要 import——
// 但各自仍需 @When 门禁，否则另一平台会多一条 unused import 警告。
import std.process.*
import cjTauri.*              // bytesToHex
import stdx.encoding.json.*
import stdx.net.http.*

/*
 * cjh web 托管：只管**生命周期**（发现 → 健康检查 → 按需拉起 → 退出收尾），数据面零参与。
 *
 * 移植自 cj-tauri/examples/ai-chat 的 cjh_host.cj（那份是 600 行、实机跑通的成熟实现），
 * 相对原版的三处适配：
 *   ① 环境变量前缀 CJ_AICHAT_* → LINGQU_*
 *   ② 二进制来源多一层「仓内 vendor 目录」——ai-chat 随包的是 zip（要解包），
 *      我们随包的是**已解包的目录**（vendor/cjh/win-x64），所以目录优先、zip 留作兜底
 *   ③ 退出收尾改由 wire 里的守护线程触发（新形态 AppSpec 没有 onExit 钩子，
 *      用 app.waitForExit() 等到窗口全退出再收，语义与 ai-chat 的 run 之后调 shutdownCjh 一致）
 *
 * 环境变量：
 *   LINGQU_CJH         —— cjh 可执行文件绝对路径（覆盖 vendor 与已部署的那份）
 *   LINGQU_CJH_PORT    —— 覆写端口（默认 8765，与 cjh web 默认一致）
 *   LINGQU_CJH_BUNDLE  —— 指到一份 zip / tar.gz 安装包（vendor 目录不可用时的兜底）
 *
 * 为什么显式 --bind 127.0.0.1：cjh web 默认绑 0.0.0.0 且默认不带鉴权 token，
 * 那等于把「能读写工作区、能跑 shell、能发消息给 LLM」的整套 API 摆在局域网上。
 * 我们的消费面全在本机（页面 / REST / WS 都是 127.0.0.1），所以收到回环。
 * 只对**我们自己拉起的**实例生效：用户自己起的 cjh 被复用那条路，绑定由用户决定。
 */

public let CJH_DEFAULT_PORT: Int64 = 8765

/** 全局持有 spawn 出来的子进程：装配期写一次、退出收尾读一次，不做并发保护 */
@When[os == "Windows"]
public var gCjhProc: Option<CjhHandle> = None
@When[os != "Windows"]
public var gCjhProc: Option<SubProcess> = None
/** true = cjh 是本应用拉起的（退出时要收尾）；false = 本来就在跑（别动人家的） */
public var gCjhOwned: Bool = false

/**
 * 两种拉起方式的统一句柄（0.39.40，仅 Windows）。
 *
 * 为什么需要它：`launchHidden`（C 桥，DETACHED_PROCESS）拿不到子进程输出、只留 pid；
 * 而「让 cjh 继承我们的隐藏控制台」只能走 `std.process.launch`（返回 SubProcess）。
 * 两边的存活判定/终止方法签名不同，所以收在一层里——上层（就绪等待 / 退出收尾）不必分叉。
 */
@When[os == "Windows"]
public class CjhHandle {
    private let hidden: Option<BackgroundProcess>
    private let sub: Option<SubProcess>

    public init(hidden: Option<BackgroundProcess>, sub: Option<SubProcess>) {
        this.hidden = hidden
        this.sub = sub
    }

    public func isAlive(): Bool {
        match (this.hidden) {
            case Some(h) => return h.isAlive()
            case None => ()
        }
        match (this.sub) {
            case Some(s) => return s.isAlive()
            case None => return false
        }
    }

    public func stop(): Unit {
        match (this.hidden) {
            case Some(h) => h.stop()
            case None => ()
        }
        match (this.sub) {
            case Some(s) =>
                try {
                    s.terminate(force: true)
                    sleep(Duration.millisecond * 200)
                    let _ = s.wait()
                } catch (e: Exception) {
                    ()
                }
            case None => ()
        }
    }
}

// ============================================================
// 端口 / 环境变量
// ============================================================

public func cjhPort(): Int64 {
    return intEnvOr("LINGQU_CJH_PORT", CJH_DEFAULT_PORT)
}

func intEnvOr(name: String, fallback: Int64): Int64 {
    match (getVariable(name)) {
        case Some(v) => parsePortEnv(v, fallback)
        case None => fallback
    }
}

public func parsePortEnv(v: String, fallback: Int64): Int64 {
    try {
        let n = Int64.parse(v)
        if (n > 0 && n <= 65535) {
            return n
        }
    } catch (e: Exception) {
        let _ = e
    }
    return fallback
}

/** 取第一个非空环境变量的值（一个都没有就回空串） */
func firstNonEmptyEnv(names: Array<String>): String {
    for (n in names) {
        if (let Some(v) <- getVariable(n)) {
            if (v.size > 0) {
                return v
            }
        }
    }
    return ""
}

/** 这个路径能不能打开（不存在 / 没权限都算不行）。只回布尔、不留 stderr */
func fileReadable(p: String): Bool {
    try {
        let f = File(Path(p), OpenMode.Read)
        f.close()
        return true
    } catch (e: Exception) {
        let _ = e
        return false
    }
}

// ============================================================
// 健康检查（唯一判据：GET /api/health 收到 200）
// ============================================================

/**
 * 「最近刚验活过」的宽容窗口（0.39.42）。
 *
 * 现象（用户实测）：浏览器打开 `http://127.0.0.1:8765/` 正常、WS 也连着，
 * 界面却报「AI 引擎缺失」——因为某几次 `/api/health` 读超时（引擎在处理回合/GC），
 * 状态轮询就把这一瞬间当成"引擎不存在"，而**发现路径也没找到二进制**（这一版没设 LINGQU_CJH
 * 时 `cjhBinPath()` 会空），于是落到 `missing`。
 *
 * 判据纪律（§2.3）：判活要宽容、**判死要有证据**。所以：
 *   ① 先单次探活；② 失败就重试 3 次；③ 仍失败但 20 秒内成功过 → 报「running + unstable」；
 *   ④ 只有连"最近成功"都没有、二进制也找不到，才报 missing。
 */
public let HEALTH_GRACE_MS: Int64 = 20000

var gCjhLastHealthyMs: Int64 = 0

/** 记一次成功探活（状态轮询、拉起、就绪等待都调它） */
public func noteCjhHealthy(): Unit {
    gCjhLastHealthyMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
}

/** 最近 [HEALTH_GRACE_MS] 内是否成功探活过 */
public func cjhHealthyRecently(): Bool {
    if (gCjhLastHealthyMs <= 0) {
        return false
    }
    let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
    return (nowMs - gCjhLastHealthyMs) <= HEALTH_GRACE_MS
}

/**
 * 探活用的 HTTP 客户端：**整条会话复用一条 keep-alive 连接**（0.39.42）。
 *
 * 为什么必须复用（2026-11-01 实测）：
 *   · 旧写法每次探活都 `ClientBuilder().build()` → 发请求 → `client.close()`，
 *     即**每 2 秒新建一条 TCP 再拆掉**；
 *   · 30 次这样的探活之后，8765 上留下 **30 个 TIME_WAIT**；同样 30 次改用 keep-alive
 *     单连接，**新增 0 个**；
 *   · cjh 侧对断开连接**不回收**（常驻 CLOSE_WAIT，见 docs/上游回馈-cjh.md 第 11 条），
 *     长会话里引擎的 socket 表只涨不落，偶发一次建连/accept 慢过 3s 就被判"引擎不在"。
 * 复用之后：churn 从「1 次/2 秒」降到「1 次/会话」。
 *
 * 出错就把缓存丢掉（下次重建）：一条坏连接不能拖死整个轮询。
 */
var gHealthClient: Option<Client> = None

/** 最近一次探活失败的原因（诊断用；成功时为 ""）。Cangjie 要求顶层变量**先定义后使用**。 */
var gLastHealthErr: String = ""

func healthClientOrBuild(): Client {
    match (gHealthClient) {
        case Some(c) => return c
        case None => ()
    }
    let c = ClientBuilder()
        .readTimeout(Duration.second * 3)
        .writeTimeout(Duration.second * 3)
        .build()
    gHealthClient = Some(c)
    return c
}

func dropHealthClient(): Unit {
    match (gHealthClient) {
        case Some(c) =>
            try {
                c.close()
            } catch (e: Exception) {
                let _ = e
            }
        case None => ()
    }
    gHealthClient = None
}

public func cjhHealthy(port: Int64): Bool {
    // 3s 而不是 1s（0.39.33 实测教训）：cjh 正在跑 agent 回合 / 大工具调用时，
    // /api/health 可能排队到 1s 以上才回 —— 1s 超时会把它判成"引擎不在"，
    // 于是应用**又拉起一只引擎**（端口被占，那只注定失败），用户侧表现为
    // 「连接已断开」+ 偶发的僵尸进程。判活要宽容，判死要有证据。
    var ok = false
    var broken = false
    try {
        let client = healthClientOrBuild()
        let req = HttpRequestBuilder().get().url("http://127.0.0.1:${port}/api/health").build()
        let resp = client.send(req)
        ok = Int64(resp.status) == 200
        resp.close()
        if (ok) {
            // 一次成功就记下时刻：后面几次读不到时，状态轮询靠它区分"引擎忙"与"引擎没了"
            noteCjhHealthy()
            gLastHealthErr = ""
        } else {
            gLastHealthErr = "status=${Int64(resp.status)}"
        }
    } catch (e: Exception) {
        // 失败原因要留证据（0.39.45）：界面报「引擎缺失」时必须能说出是超时、拒连还是没这端点
        gLastHealthErr = safeErrText(e)
        broken = true
    }
    if (broken) {
        dropHealthClient()
    }
    return ok
}

/** 最近一次探活失败的原因（诊断用；成功时为 ""）。异常文本截断，别把整段栈塞进 UI。 */
func safeErrText(e: Exception): String {
    var s = ""
    try {
        s = e.toString()
    } catch (e2: Exception) {
        let _ = e2
        s = "exception"
    }
    if (s.size > 160) {
        return s[0..160]
    }
    return s
}

public func cjhLastHealthErr(): String {
    return gLastHealthErr
}

/** 距上次成功探活多少毫秒；从没成功过回 -1（诊断用） */
func cjhHealthyAgoMs(): Int64 {
    if (gCjhLastHealthyMs <= 0) {
        return -1
    }
    return DateTime.now().toUnixTimeStamp().toMilliseconds() - gCjhLastHealthyMs
}

/**
 * 状态轮询的诊断串（0.39.45，给 `ui_report.cjhDiag`）。
 *
 * 起因：用户侧出现"页脚已连接、设置页却写引擎缺失"（`cjhState=missing` 而 `wsState=connected`，
 * 同时外部 `curl /api/health` 200）。只回一个 `state` 没法查——**判死要有证据**，
 * 所以把"探的哪个端口、最近一次失败原因、多久没成功过、env 里的二进制是否可读、
 * 发现路径有没有找到东西"一并回投，下次一句话就能定位。
 */
public func cjhDiagText(): String {
    let port = cjhPort()
    let rev = firstNonEmptyEnv(["LINGQU_CJH"])
    let revOk = if (rev.size > 0) { fileReadable(rev) } else { false }
    let install = installBinPath()
    let envShow = if (rev.size > 0) { rev } else { "-" }
    let instShow = if (install.size > 0) { install } else { "-" }
    let ago = cjhHealthyAgoMs()
    let owned = gCjhOwned
    return "port=${port} lastErr=${gLastHealthErr} lastOkAgoMs=${ago} envCjh=${envShow} readable=${revOk} install=${instShow} vendor=${cjhVendorDir()} owned=${owned}"
}

/**
 * 判活（带重试）：引擎**正在跑回合**时 /api/health 偶尔会慢，一次超时不算死。
 *
 * 0.39.33 实测：用户在一次长对话里看到「连接已断开」，同时进程表里**多出一只引擎**
 * （`main.exe web --port 8765` 起了两只，第二只绑不上端口）。根因就是这里 1s 超时误判
 * → `ensureCjhWeb()` 以为没有引擎 → 又 spawn 一只。现在：先重试 `tries` 次（每次 700ms），
 * 全都不通才认定"没有引擎"。判死要有证据，不能一次读超时就下结论（§2.3 的"就绪判据"同样适用）。
 */
public func cjhHealthyWithRetry(port: Int64, tries: Int64): Bool {
    var n: Int64 = 0
    while (n < tries) {
        if (cjhHealthy(port)) {
            return true
        }
        n += 1
        if (n < tries) {
            sleep(Duration.millisecond * 700)
        }
    }
    return false
}

/** 可用端点的统一形状：页面拿到就能自己接上 */
public func putEndpoints(obj: JsonObject, port: Int64): Unit {
    obj.put("port", JsonInt(port))
    obj.put("apiUrl", JsonString("http://127.0.0.1:${port}"))
    obj.put("wsUrl", JsonString("ws://127.0.0.1:${port}/ws"))
}

// ============================================================
// cjh REST 客户端（模型配置面板用）
// ============================================================
//
// 为什么不从页面直接 fetch：页面跑在 WebView 的自定义 scheme 下，跨源请求会撞 CORS；
// 而把 127.0.0.1 塞进 capabilities 的 scopes.http 又等于给页面开一条出网白名单。
// 这几个调用是「读引擎自身状态」，放后端更收得住——页面只走 invoke。

/** 读响应体（流 → 字符串），上限 maxBytes：/api/models 之类都很小，超了就是异常 */
func readHttpBody(body: InputStream, maxBytes: Int64): String {
    var list = ArrayList<Byte>()
    let buf = Array<Byte>(8192, repeat: UInt8(0))
    try {
        while (list.size < maxBytes) {
            let n = body.read(buf)
            if (n <= 0) {
                break
            }
            for (i in 0..n) {
                list.add(buf[i])
            }
        }
    } catch (e: Exception) {
        let _ = e
    }
    var bytes = Array<Byte>(list.size, repeat: UInt8(0))
    for (i in 0..list.size) {
        bytes[i] = list[i]
    }
    return String.fromUtf8(bytes)
}

/**
 * 打 cjh 的 REST 接口：成功返回响应体原文，失败返回空串（调用方据此报错，不抛）。
 * 只用回环地址与短超时——引擎就在本机，2 秒不通就是不通。
 */
func cjhApiCall(method: String, path: String, jsonBody: String): String {
    let client = ClientBuilder()
        .readTimeout(Duration.second * 2)
        .writeTimeout(Duration.second * 2)
        .build()
    var out = ""
    try {
        let builder = HttpRequestBuilder()
        if (method == "POST") {
            builder.post()
        } else {
            builder.get()
        }
        builder.url("http://127.0.0.1:${cjhPort()}${path}")
        builder.header("Accept", "application/json")
        if (jsonBody.size > 0) {
            builder.header("Content-Type", "application/json")
            builder.body(jsonBody)
        }
        let resp = client.send(builder.build())
        let status = Int64(resp.status)
        if (status >= 200 && status < 300) {
            out = readHttpBody(resp.body, 512 * 1024)
        }
        resp.close()
    } catch (e: Exception) {
        let _ = e
    }
    client.close()
    return out
}

/** 把一段 JSON 文本包成 {ok:true, data:...}；失败回 {ok:false, error} */
func wrapJsonPayload(raw: String, what: String): JsonValue {
    var res = JsonObject()
    if (raw.size == 0) {
        res.put("ok", JsonBool(false))
        res.put("error", JsonString("${what}：cjh 没有响应（未启动或端口不通）"))
        return res
    }
    try {
        res.put("ok", JsonBool(true))
        res.put("data", JsonValue.fromStr(raw))
    } catch (e: Exception) {
        res.put("ok", JsonBool(false))
        res.put("error", JsonString("${what}：响应不是合法 JSON（${e}）"))
    }
    return res
}

// ============================================================
// 路径解析：环境变量 → 已部署 → 仓内 vendor（校验过）
// ============================================================

@When[os == "Windows"]
func cjhPathSep(): String {
    return "\\"
}

@When[os != "Windows"]
func cjhPathSep(): String {
    return "/"
}

/** 平台子目录名（`vendor/cjh/<平台>`） */
@When[os == "Windows"]
func cjhVendorSubdir(): String {
    return "win-x64"
}

@When[os != "Windows"]
func cjhVendorSubdir(): String {
    return "linux-x64"
}

/**
 * vendor 目录的候选路径（按优先级；纯函数，便于单测）。
 *
 * 为什么不能只写相对路径：`vendor/cjh/win-x64` 是相对**当前工作目录**解析的，
 * 而便携包里用户可能双击 `main.exe`、可能从快捷方式启动、也可能被 `start` 换了 CWD——
 * 只要 CWD 不是包根，就会报「没找到可用的 cjh」，可文件明明就在包里
 * （2026-10-31 便携包实测正是这个症状）。
 *
 * 顺序：① `LINGQU_HOME`（启动器 `run.bat` 写入的包根）；② `LINGQU_CJH_HOME`（自定义）；
 *       ③ 老口径相对路径（开发期在仓根跑仍然成立）。
 */
public func cjhVendorDirCandidates(lingquHome: String, cjhHome: String): ArrayList<String> {
    let out = ArrayList<String>()
    let sep = cjhPathSep()
    let sub = cjhVendorSubdir()
    if (lingquHome.size > 0) {
        out.add(lingquHome + sep + "vendor" + sep + "cjh" + sep + sub)
    }
    if (cjhHome.size > 0) {
        out.add(cjhHome + sep + "cjh" + sep + sub)
    }
    out.add("vendor" + sep + "cjh" + sep + sub)
    return out
}

/** 实际使用的 vendor 目录：第一个**存在**的候选；都不存在则退回老口径相对路径（让报错信息仍可读） */
public func cjhVendorDir(): String {
    let cands = cjhVendorDirCandidates(firstNonEmptyEnv(["LINGQU_HOME"]),
        firstNonEmptyEnv(["LINGQU_CJH_HOME"]))
    // 兜底：从**当前工作目录**逐级上溯找。相对路径在"换了个 CWD"时必然失效——
    // 例如直接从 `targets/desktop/target/release/bin` 起，或从包内子目录起（AGENTS §4-52）。
    for (c in vendorCandidatesFrom(getWorkingDirectoryOr(""), 6)) {
        cands.add(c)
    }
    for (c in cands) {
        if (exists(Path(c))) {
            return c
        }
    }
    return "vendor" + cjhPathSep() + "cjh" + cjhPathSep() + cjhVendorSubdir()
}

/** 取工作目录；拿不到返回 fallback（不让路径解析把启动流程炸掉） */
public func getWorkingDirectoryOr(fallback: String): String {
    try {
        return getWorkingDirectory().toString()
    } catch (e: Exception) {
        let _ = e
        return fallback
    }
}

/**
 * 从 [base] 起逐级上溯，生成 `…/vendor/cjh/<平台>` 候选（纯函数，最多 [levels] 层）。
 *
 * 例：`C:\repo\targets\desktop\target\release\bin` 上溯 6 层会产出
 * `…\bin\vendor\cjh\win-x64`、`…\release\…`、…、`C:\repo\vendor\cjh\win-x64`。
 */
public func vendorCandidatesFrom(base: String, levels: Int64): ArrayList<String> {
    let out = ArrayList<String>()
    var cur = trimPathSep(base)
    var up: Int64 = 0
    let sep = cjhPathSep()
    let sub = cjhVendorSubdir()
    while (cur.size > 0 && up <= levels) {
        out.add(cur + sep + "vendor" + sep + "cjh" + sep + sub)
        let idx = lastSepIndex(cur)
        if (idx <= 0) {
            break
        }
        cur = cur[0..idx]
        up += 1
    }
    return out
}

/** 去掉末尾的分隔符（`C:\repo\` → `C:\repo`） */
func trimPathSep(p: String): String {
    let bytes = p.toArray()
    var end = bytes.size
    while (end > 0 && (bytes[end - 1] == 92 || bytes[end - 1] == 47)) {
        end--
    }
    if (end <= 0) {
        return ""
    }
    return String.fromUtf8(bytes[0..end])
}

/** 最后一个路径分隔符的下标（没有返回 -1） */
func lastSepIndex(p: String): Int64 {
    let bytes = p.toArray()
    var found: Int64 = -1
    for (i in 0..bytes.size) {
        if (bytes[i] == 92 || bytes[i] == 47) {
            found = i
        }
    }
    return found
}

@When[os == "Windows"]
func cjhBinName(): String {
    return "cjh.exe"
}

@When[os != "Windows"]
func cjhBinName(): String {
    return "cjh"
}

/**
 * 随包目录里「按名字 LoadLibrary」的运行时库：cjh.exe 的 PE 导入表里没有它们，
 * 缺了只在启动时炸（症状是「窗口照起、http 照通，只有 https 全灭」），所以逐个点名核对。
 */
@When[os == "Windows"]
let CJH_VENDOR_FILES: Array<(String, String)> = [
    ("cjh.exe", "3dc9db6f270ed93eae98a9eb930ffad495c09ab8c87292f9937d913e65b23f1d"),
    ("libcangjie-runtime.dll", "03f4d59a13c7fc1d71523bdd42a05587657105aff14c8288adfdd8fbe5bea089"),
    ("libssl-3-x64.dll", "bbaf8a8c37b4cfdd7fe5feee9ff1d0072078f430bb5ef2b3da38a600f4039b03"),
    ("libcrypto-3-x64.dll", "a997e132b8c548212d4c292bb3f61bcdee88cf726b89c60f32969ad6cbaa9698")
]

/** 对文件算 SHA256 十六进制（读不到回空串） */
func sha256FileHex(p: String): String {
    var bytes: Array<Byte> = []
    try {
        bytes = File.readFrom(p)
    } catch (e: Exception) {
        let _ = e
        return ""
    }
    return bytesToHex(digest(SHA256(), bytes))
}

/**
 * 校验仓内 vendor 目录：4 个文件齐全且 SHA256 与入库常量逐字一致。
 *
 * 为什么要校验而不是直接用：这份二进制是「能跑 shell、能读写工作区」的 agent 引擎，
 * 来路不明的同名文件不该被静默执行。校验失败只留一行 stderr 并回 false，
 * 上层据此报「引擎不可用」，绝不解包也不执行。
 */
@When[os == "Windows"]
public func cjhVendorVerified(dir: String): Bool {
    for (entry in CJH_VENDOR_FILES) {
        let name = entry[0]
        let want = entry[1]
        let p = dir + cjhPathSep() + name
        if (!fileReadable(p)) {
            eprintln("[lingqu] vendor 缺文件：${p}")
            return false
        }
        let got = sha256FileHex(p)
        if (got != want) {
            eprintln("[lingqu] vendor SHA256 不符：${name} expected=${want} got=${got}")
            return false
        }
    }
    return true
}

/** Linux 版随包二进制的 SHA256：单文件、静态链接，没有随行 DLL（与 Windows 形态不同） */
@When[os != "Windows"]
let CJH_LINUX_SHA: String = "2821d90f0285c77aeab51234f23c1539af18479410d302f05e3d5af7e9a7ab31"

@When[os != "Windows"]
public func cjhVendorVerified(dir: String): Bool {
    // Linux/其它类 Unix：单文件二进制，同样要过 SHA256——理由与 Windows 侧一致
    let p = dir + cjhPathSep() + cjhBinName()
    if (!fileReadable(p)) {
        eprintln("[lingqu] vendor 缺文件：${p}")
        return false
    }
    let got = sha256FileHex(p)
    if (got != CJH_LINUX_SHA) {
        eprintln("[lingqu] vendor SHA256 不符：${cjhBinName()} expected=${CJH_LINUX_SHA} got=${got}")
        return false
    }
    return true
}

/** 部署后的安装目录；拿不到返回空串（调用方据此如实报错） */
@When[os == "Windows"]
func cjhInstallDir(): String {
    let base = firstNonEmptyEnv(["LOCALAPPDATA", "USERPROFILE"])
    if (base.size == 0) {
        return ""
    }
    return base + "\\lingqu\\cjh"
}

@When[os != "Windows"]
func cjhInstallDir(): String {
    let home = firstNonEmptyEnv(["HOME"])
    if (home.size == 0) {
        return ""
    }
    return home + "/.local/share/lingqu/cjh"
}

/** 安装目录里的 cjh 可执行文件路径（拿不到安装目录回空串）；**不判存在性**，调用方自己判 */
func installBinPath(): String {
    let dir = cjhInstallDir()
    if (dir.size == 0) {
        return ""
    }
    return dir + cjhPathSep() + cjhBinName()
}

/**
 * cjh 可执行文件的实际路径，按优先级找；都没有返回空串（上层如实报「引擎缺失」，不猜路径）。
 *   ① LINGQU_CJH 环境变量
 *   ② 部署过的安装目录
 *   ③ 仓内 vendor 目录（**校验通过**才用）
 */
public func cjhBinPath(): String {
    let fromEnv = firstNonEmptyEnv(["LINGQU_CJH"])
    if (fromEnv.size > 0 && fileReadable(fromEnv)) {
        // 成功路径也要留一行证据：排查"引擎没起来"时，先看它用的是哪个二进制
        eprintln("[lingqu] cjh: 用 LINGQU_CJH 指定的${fromEnv}")
        return fromEnv
    }
    let install = installBinPath()
    if (install.size > 0 && fileReadable(install)) {
        eprintln("[lingqu] cjh: 用部署目录里的${install}")
        return install
    }
    let vendor = cjhVendorDir()
    if (cjhVendorVerified(vendor)) {
        let p = vendor + cjhPathSep() + cjhBinName()
        eprintln("[lingqu] cjh: 用随包引擎 ${p}")
        return p
    }
    // 真·单文件产物：vendor/ 根本不在盘上，cjh（+3 个运行时 DLL）是 **PE 资源**，
    // 运行期由框架 `extractEmbeddedAssets` 释放到安装目录再用（机制见 packaging/pack-win-single-full.sh）。
    // 普通构建这里返回 0（没有内嵌资源），什么都不做。
    let extracted = extractEmbeddedCjh()
    if (shouldUseExtracted(extracted, cjhVendorVerified(cjhInstallDir()))) {
        let p = installBinPath()
        eprintln("[lingqu] cjh: 用内嵌释放的引擎 ${p}（释放 ${extracted} 个文件）")
        return p
    }
    eprintln("[lingqu] cjh: 随包引擎不可用，查过的目录 = ${vendor}（可用 LINGQU_HOME / LINGQU_CJH_HOME / LINGQU_CJH 覆盖）")
    return ""
}

// ============================================================
// 状态（三态，纯读无副作用，页面可以随便轮询）
// ============================================================

/**
 * cjh 当前状态（`t2h:cjh_status` 的正文）：
 *   running    —— 端口上有活的 cjh（我们拉起的或用户自己的），直接可用
 *   ready      —— 没在跑，但找得到可用二进制（可直接拉起）
 *   missing    —— 既没在跑也没有可用二进制（给下载 / 部署引导）
 */
public func cjhStatusJson(): JsonValue {
    let port = cjhPort()
    let obj = JsonObject()
    obj.put("port", JsonInt(port))
    // 诊断串（0.39.45）：每个分支都带上，界面报"缺失"时才有据可查
    obj.put("diag", JsonString(cjhDiagText()))
    if (cjhHealthy(port)) {
        noteCjhHealthy()
        obj.put("state", JsonString("running"))
        putEndpoints(obj, port)
        obj.put("owned", JsonBool(gCjhOwned))
        // running 也要回投是哪一份二进制：单文件产物里"内嵌释放的那份"与"用户自己起的"必须能区分，
        // 否则界面只显示 running，排查时不知道到底在跑哪个文件。
        // 这里**不做 SHA256 校验**（已在跑就不该因为校验慢卡住轮询），只查 env 与安装目录两条。
        let envBin = firstNonEmptyEnv(["LINGQU_CJH"])
        let installBin = installBinPath()
        obj.put("binPath", JsonString(knownBinPath(envBin, fileReadable(envBin), installBin,
            fileReadable(installBin))))
        return obj
    }
    // 判活要宽容、判死要有证据（0.39.42）：一次 `/api/health` 读超时就改口说"引擎缺失"，
    // 用户侧看到的是「网页能打开、界面说引擎缺失」。重试几次，并给"最近刚验活过"留一条宽容窗口。
    if (cjhHealthyWithRetry(port, 3)) {
        noteCjhHealthy()
        obj.put("state", JsonString("running"))
        obj.put("unstable", JsonBool(true))
        putEndpoints(obj, port)
        obj.put("owned", JsonBool(gCjhOwned))
        return obj
    }
    if (cjhHealthyRecently()) {
        // 刚刚还在，只是这几秒读不到：如实说"在跑，但健康检查变慢"，**不是缺失**
        obj.put("state", JsonString("running"))
        obj.put("unstable", JsonBool(true))
        putEndpoints(obj, port)
        obj.put("owned", JsonBool(gCjhOwned))
        obj.put("note", JsonString("健康检查最近一次成功在 ${HEALTH_GRACE_MS / 1000} 秒内，按「在跑」处理"))
        return obj
    }
    let bin = cjhBinPath()
    if (bin.size > 0) {
        obj.put("state", JsonString("ready"))
        obj.put("binPath", JsonString(bin))
    } else {
        obj.put("state", JsonString("missing"))
        // 把"查过的目录"和"包根线索"都回投：报障时一句话就能定位是路径问题还是文件缺失
        obj.put("vendorDir", JsonString(cjhVendorDir()))
        obj.put("lingquHome", JsonString(firstNonEmptyEnv(["LINGQU_HOME"])))
        obj.put("cjhHome", JsonString(firstNonEmptyEnv(["LINGQU_CJH_HOME"])))
    }
    return obj
}

// ============================================================
// 拉起 / 等待就绪 / 收尾
// ============================================================

/** 等就绪的三态：抽成枚举 + 一个共享等待循环，两平台的差异只在「怎么起、怎么判活着」 */
enum CjhWait {
    | Ready
    | Died
    | Timeout
}

/** 拉起 cjh web 的参数（两平台同源；--bind 的理由见文件头） */
func cjhWebArgs(): Array<String> {
    return ["web", "--port", cjhPort().toString(), "--bind", "127.0.0.1"]
}

/** 100ms 一步、最多 10 秒：cjh web 启动要装 Agent 栈，秒级是正常量级 */
func awaitCjhReady(port: Int64, alive: () -> Bool): CjhWait {
    var waited: Int64 = 0
    while (waited < 10000) {
        if (cjhHealthy(port)) {
            eprintln("[lingqu] cjh web 已就绪（port=${port}，等了 ${waited}ms）")
            return CjhWait.Ready
        }
        if (!alive()) {
            return CjhWait.Died
        }
        sleep(Duration.millisecond * 100)
        waited += 100
    }
    eprintln("[lingqu] cjh web 启动后 10s 健康检查仍不通——按不可用处理（进程留着，可重试）")
    return CjhWait.Timeout
}

@When[os == "Windows"]
func spawnCjhWeb(bin: String): Bool {
    // 拉起前先把上一只**我们拉起的**收掉：换路径重试时旧进程若还占着端口，新的那只绑定会失败
    if (let Some(old) <- gCjhProc) {
        terminateCjhProc(old)
        gCjhProc = None
    }
    // 0.39.40：本进程若已分到**隐藏控制台**（win_console.ensureHiddenConsole），就让 cjh
    // **继承**它（走 std.process.launch），而不是 DETACHED 掉——这样 cjh 再拉 bash / find /
    // lingqu-cli 时都继承这个看不见的 console，用户不会再看到一个个黑窗闪。
    // 没有隐藏控制台时回落到 launchHidden：那时若继承，cjh 会顶出一个**可见**的黑窗（更糟）。
    let inherited = launchCjhInheritingConsole(bin)
    match (inherited) {
        case Some(sub) =>
            return awaitCjhOwned(CjhHandle(None, Some(sub)), "继承隐藏控制台")
        case None => ()
    }
    let held = launchHidden(bin, cjhWebArgs())
    if (let None <- held) {
        eprintln("[lingqu] 启动 cjh web 失败（${bin}）——C 桥的 spawn 没拿到 pid")
        return false
    }
    return awaitCjhOwned(CjhHandle(Some(held.getOrThrow()), None), "launchHidden")
}

/** 隐藏控制台可用时，用「继承 console」的方式拉起 cjh；不可用或失败返回 None（调用方回落） */
@When[os == "Windows"]
func launchCjhInheritingConsole(bin: String): Option<SubProcess> {
    if (!gConsoleHidden) {
        return None
    }
    try {
        let p = launch(bin, cjhWebArgs())
        eprintln("[lingqu] cjh web 以「继承隐藏控制台」方式拉起：子进程不再各自弹黑窗")
        return Some(p)
    } catch (e: Exception) {
        eprintln("[lingqu] 继承控制台方式拉起失败，回落到 launchHidden：${e}")
        return None
    }
}

/** 拉起后等就绪 + 记账（两种拉起方式共用；`how` 只用于日志） */
@When[os == "Windows"]
func awaitCjhOwned(h: CjhHandle, how: String): Bool {
    gCjhProc = Some(h)
    match (awaitCjhReady(cjhPort(), { => h.isAlive() })) {
        case CjhWait.Ready =>
            gCjhOwned = true
            eprintln("[lingqu] cjh web 已就绪（${how}）")
            return true
        case CjhWait.Died =>
            eprintln("[lingqu] cjh web 进程退出（${how}）——检查这个可执行文件与 cjh 配置")
            gCjhProc = None
            return false
        case CjhWait.Timeout =>
            gCjhOwned = true
            return false
    }
}

@When[os != "Windows"]
func spawnCjhWeb(bin: String): Bool {
    if (let Some(old) <- gCjhProc) {
        terminateCjhProc(old)
        gCjhProc = None
    }
    var launched: Option<SubProcess> = None
    try {
        launched = Some(launch(bin, cjhWebArgs()))
    } catch (e: Exception) {
        eprintln("[lingqu] 启动 cjh web 失败：${e}")
        return false
    }
    let proc = launched.getOrThrow()
    gCjhProc = Some(proc)
    match (awaitCjhReady(cjhPort(), { => proc.isAlive() })) {
        case CjhWait.Ready =>
            gCjhOwned = true
            return true
        case CjhWait.Died =>
            eprintln("[lingqu] cjh web 进程退出（exit=${proc.wait()}）——检查这个可执行文件与 cjh 配置")
            gCjhProc = None
            return false
        case CjhWait.Timeout =>
            gCjhOwned = true
            return false
    }
}

/** 应用退出时收尾：只终止**自己拉起的** cjh（复用的不动——那是用户自己的实例） */
public func shutdownCjh(): Unit {
    if (!gCjhOwned) {
        return
    }
    if (let Some(p) <- gCjhProc) {
        terminateCjhProc(p)
    }
}

@When[os == "Windows"]
func terminateCjhProc(p: CjhHandle): Unit {
    if (p.isAlive()) {
        eprintln("[lingqu] 收尾：终止 cjh web")
        p.stop()
    }
}

@When[os != "Windows"]
func terminateCjhProc(p: SubProcess): Unit {
    if (p.isAlive()) {
        eprintln("[lingqu] 收尾：终止 cjh web")
        p.terminate()
        sleep(Duration.millisecond * 200)
        let _ = p.wait()
    }
}

/**
 * 确保 cjh web 就绪（启动路径）：端口上已有活的就复用（gCjhOwned=false，退出不收）；
 * 没有就按 cjhBinPath() 找二进制并拉起。失败不致命——页面拿「未连接」，其余功能照常。
 */
public func ensureCjhWeb(): Bool {
    let port = cjhPort()
    // 先按"可能只是忙"重试，避免在长回合期间误判引擎已死、再拉起一只绑不上端口的僵尸
    if (cjhHealthyWithRetry(port, 6)) {
        eprintln("[lingqu] cjh web 已在运行（port=${port}），直接复用")
        gCjhOwned = false
        return true
    }
    let bin = cjhBinPath()
    if (bin.size == 0) {
        eprintln("[lingqu] cjh web 未运行，也没找到可用二进制（LINGQU_CJH / 已部署目录 / 仓内 vendor 都不可用）" +
            "——AI 面板不可用，其余功能照常；可调 t2h:cjh_deploy 或设 LINGQU_CJH")
        return false
    }
    return spawnCjhWeb(bin)
}

// ============================================================
// 一键部署（t2h:cjh_deploy）：校验随包产物，必要时解包到安装目录，然后拉起
// ============================================================

@When[os == "Windows"]
let CJH_WIN_RUNTIME_DLLS: Array<String> = [
    "libcangjie-runtime.dll", "libboundscheck.dll", "libssl-3-x64.dll", "libcrypto-3-x64.dll"
]

/** 随包安装包的路径：LINGQU_CJH_BUNDLE 优先（打包产物里 vendor 不在 cwd 旁时指过来） */
func cjhBundlePath(): String {
    match (getVariable("LINGQU_CJH_BUNDLE")) {
        case Some(p) => return p
        case None => return ""
    }
}

/** 系统 bsdtar 的绝对路径（别写裸 `tar`：Git Bash 起应用时 PATH 里 MSYS 的 GNU tar 在前，它不认 zip） */
@When[os == "Windows"]
func cjhWindowsTarExe(): String {
    let root = firstNonEmptyEnv(["SystemRoot", "windir"])
    if (root.size == 0) {
        return "C:\\Windows\\System32\\tar.exe"
    }
    return root + "\\System32\\tar.exe"
}

/** 「装好了却没起来」最常见的那半句原因（平台失败面不同，笼统写反而让人白查） */
@When[os == "Windows"]
func cjhStartFailHint(): String {
    return "这份二进制与本机不兼容（例如被 SmartScreen / 杀软拦下、缺 VC 运行时），或启动即崩"
}

@When[os != "Windows"]
func cjhStartFailHint(): String {
    return "这份二进制与本机不兼容（例如它要求更新的 glibc），或启动即崩"
}

/**
 * 从安装包解包到安装目录。判据是**产物真的落盘**，不是退出码：
 * Windows 走 launchHidden 拿不到 tar 的退出码，而「解不全」本来就会让产物检查失败。
 */
@When[os == "Windows"]
func cjhExtractBundle(bundle: String, installDir: String): Option<String> {
    try {
        Directory.create(Path(installDir))
    } catch (e: Exception) {
        let _ = e
    }
    // 判据用 exists(Path(dir))，**不要**用 File(Path(dir), OpenMode.Read)：
    // Windows 对目录 open 直接 Access is denied（这条错只在 Windows 侧炸）
    if (!exists(Path(installDir))) {
        let why = "安装目录建不出来：${installDir}"
        eprintln("[lingqu] ${why}")
        return Some(why)
    }
    let tarExe = cjhWindowsTarExe()
    if (!fileReadable(tarExe)) {
        let why = "找不到系统 bsdtar：${tarExe}（Win10 1803+ 才自带；也可手动解压后用 LINGQU_CJH 指定）"
        eprintln("[lingqu] ${why}")
        return Some(why)
    }
    match (launchHidden(tarExe, ["-xf", bundle, "-C", installDir])) {
        case Some(p) =>
            var waited: Int64 = 0
            while (waited < 30000) {
                if (!p.isAlive()) {
                    break
                }
                sleep(Duration.millisecond * 100)
                waited += 100
            }
            if (p.isAlive()) {
                let why = "bsdtar 解包 30s 没结束（bundle=${bundle}）"
                eprintln("[lingqu] ${why}")
                p.stop()
                return Some(why)
            }
        case None =>
            let why = "启动解包工具失败：${tarExe}（C 桥的 spawn 没拿到 pid）"
            eprintln("[lingqu] ${why}")
            return Some(why)
    }
    // 产物核对：二进制 + 4 个按名字加载的 DLL 都得躺着
    let bin = installDir + cjhPathSep() + cjhBinName()
    if (!fileReadable(bin)) {
        let why = "解包后没找到 ${bin}（bundle=${bundle}）——zip 不完整或被拦下"
        eprintln("[lingqu] ${why}")
        return Some(why)
    }
    for (dll in CJH_WIN_RUNTIME_DLLS) {
        let p = installDir + cjhPathSep() + dll
        if (!fileReadable(p)) {
            let why = "解包后缺运行时库 ${p}——cjh.exe 起不来（按名字 LoadLibrary）"
            eprintln("[lingqu] ${why}")
            return Some(why)
        }
    }
    return None
}

@When[os != "Windows"]
func cjhExtractBundle(bundle: String, installDir: String): Option<String> {
    try {
        Directory.create(Path(installDir))
    } catch (e: Exception) {
        let _ = e
    }
    if (!exists(Path(installDir))) {
        let why = "安装目录建不出来：${installDir}"
        eprintln("[lingqu] ${why}")
        return Some(why)
    }
    var proc: SubProcess
    try {
        proc = launch("tar", ["-xzf", bundle, "-C", installDir])
    } catch (e: Exception) {
        let why = "启动 tar 解包失败：${e}"
        eprintln("[lingqu] ${why}")
        return Some(why)
    }
    let code = proc.wait()
    if (code != 0) {
        let why = "tar 解包失败 exit=${code}"
        eprintln("[lingqu] ${why}")
        return Some(why)
    }
    var chmod: SubProcess
    try {
        chmod = launch("chmod", ["+x", installDir + cjhPathSep() + cjhBinName()])
    } catch (e: Exception) {
        let why = "启动 chmod 失败：${e}"
        eprintln("[lingqu] ${why}")
        return Some(why)
    }
    let ccode = chmod.wait()
    if (ccode != 0) {
        let why = "chmod +x 失败 exit=${ccode}"
        eprintln("[lingqu] ${why}")
        return Some(why)
    }
    return None
}

/**
 * 一键部署并启动：{ok, reused|deployed, port, apiUrl, wsUrl} / {ok:false, error}。
 * 失败**不抛异常**——原因是要显示给人看的一行话，抛出去前端只剩一句 reject 文本。
 *
 * 三档优先级：已跑就复用 → 仓内 vendor 校验通过就用它 → 否则按安装包部署。
 */
func cjhDeployAndStart(): JsonObject {
    let obj = JsonObject()
    let port = cjhPort()
    // 同 ensureCjhWeb：引擎忙的时候 health 会慢，先重试再下"没有引擎"的结论
    if (cjhHealthyWithRetry(port, 4)) {
        obj.put("ok", JsonBool(true))
        obj.put("reused", JsonBool(true))
        putEndpoints(obj, port)
        obj.put("detail", JsonString("端口 ${port} 上已有 cjh，直接复用"))
        return obj
    }

    // ⓪ 显式指定（`LINGQU_CJH`）最优先：开发期跑的是**自己构建的 cjh**，
    //    不该被"部署随包引擎"顶掉。0.39.27 实测教训：门禁把引擎杀了之后，用户点
    //    「立即拉起」→ 这里直接跳到 vendor / 已部署目录，拉起了 `%LOCALAPPDATA%\lingqu\cjh\cjh.exe`
    //    （旧副本），于是页面一直停在「连接已断开」，点几次都回不来。
    //    顺序与 `cjhBinPath()` 保持一致，避免"能拉起"和"拉起了谁"两套口径。
    let fromEnv = firstNonEmptyEnv(["LINGQU_CJH"])
    if (fromEnv.size > 0 && fileReadable(fromEnv)) {
        if (spawnCjhWeb(fromEnv)) {
            obj.put("ok", JsonBool(true))
            obj.put("reused", JsonBool(false))
            obj.put("deployed", JsonString(fromEnv))
            putEndpoints(obj, port)
            obj.put("detail", JsonString("已按 LINGQU_CJH 拉起 cjh（${fromEnv}）"))
            return obj
        }
        obj.put("ok", JsonBool(false))
        obj.put("error", JsonString("按 LINGQU_CJH 拉起 ${fromEnv} 失败——${cjhStartFailHint()}"))
        return obj
    }

    // ① 仓内 vendor（已解包形态）：校验通过就直接拉起，无需部署
    let vendor = cjhVendorDir()
    if (cjhVendorVerified(vendor)) {
        let bin = vendor + cjhPathSep() + cjhBinName()
        if (spawnCjhWeb(bin)) {
            obj.put("ok", JsonBool(true))
            obj.put("reused", JsonBool(false))
            obj.put("deployed", JsonString(bin))
            putEndpoints(obj, port)
            obj.put("detail", JsonString("已用仓内 vendor（SHA256 校验通过）拉起 cjh"))
            return obj
        }
        obj.put("ok", JsonBool(false))
        obj.put("error", JsonString("vendor 校验通过但 cjh 没在 10 秒内就绪——${cjhStartFailHint()}"))
        return obj
    }

    // ② 退到安装包部署（LINGQU_CJH_BUNDLE 指到的 zip / tar.gz）
    let installDir = cjhInstallDir()
    if (installDir.size == 0) {
        obj.put("ok", JsonBool(false))
        obj.put("error", JsonString("拿不到安装目录（LOCALAPPDATA/HOME 为空）——请用 LINGQU_CJH 手动指定 cjh"))
        return obj
    }
    let installed = installDir + cjhPathSep() + cjhBinName()
    if (!fileReadable(installed)) {
        let bundle = cjhBundlePath()
        if (bundle.size == 0 || !fileReadable(bundle)) {
            obj.put("ok", JsonBool(false))
            obj.put("error", JsonString("仓内 vendor 校验未通过，且没有可用安装包（设 LINGQU_CJH_BUNDLE 指向 zip）"))
            return obj
        }
        match (cjhExtractBundle(bundle, installDir)) {
            case Some(why) =>
                obj.put("ok", JsonBool(false))
                obj.put("error", JsonString("解包/安装失败：${why}"))
                return obj
            case None => ()
        }
        eprintln("[lingqu] cjh 已部署到 ${installed}")
    }
    if (spawnCjhWeb(installed)) {
        obj.put("ok", JsonBool(true))
        obj.put("reused", JsonBool(false))
        obj.put("deployed", JsonString(installed))
        putEndpoints(obj, port)
        obj.put("detail", JsonString("已部署并拉起"))
        return obj
    }
    obj.put("ok", JsonBool(false))
    obj.put("error", JsonString("部署完成但 cjh 没在 10 秒内就绪——${cjhStartFailHint()}"))
    return obj
}

/** 按指定路径拉起（页面「选择 cjh 可执行文件」走这条）：失败回 {ok:false, error}，不抛 */
func cjhStartByPath(path: String): JsonObject {
    let obj = JsonObject()
    let port = cjhPort()
    if (cjhHealthy(port)) {
        obj.put("ok", JsonBool(true))
        obj.put("reused", JsonBool(true))
        putEndpoints(obj, port)
        obj.put("detail", JsonString("端口 ${port} 上已有 cjh，直接复用"))
        return obj
    }
    if (!fileReadable(path)) {
        obj.put("ok", JsonBool(false))
        obj.put("error", JsonString("打不开这个文件：${path}（不存在或没有读权限）"))
        return obj
    }
    if (spawnCjhWeb(path)) {
        obj.put("ok", JsonBool(true))
        obj.put("reused", JsonBool(false))
        putEndpoints(obj, port)
        obj.put("detail", JsonString("已拉起（${path}）"))
        return obj
    }
    obj.put("ok", JsonBool(false))
    obj.put("error", JsonString("cjh 没在 10 秒内就绪：确认选的是 cjh 的可执行文件；启动错误见应用日志"))
    return obj
}

// ============================================================
// 命令面：t2h:cjh_status / t2h:cjh_start / t2h:cjh_deploy
// ============================================================

/** 文本字段：非空才写入（空串＝不改，避免把 cjh 现有服务商清空），返回写入个数 */
func putIfText(o: JsonObject, key: String, v: JsonValue): Int64 {
    match (v.kind()) {
        case JsonKind.JsString =>
            let s = v.asString().getValue()
            if (s.size > 0) {
                o.put(key, JsonString(s))
                return 1
            }
            return 0
        case _ => return 0
    }
}

/** 密钥字段：空串与含 *** 的掩码都表示"不改" */
func putIfSecret(o: JsonObject, v: JsonValue): Int64 {
    match (v.kind()) {
        case JsonKind.JsString =>
            let s = v.asString().getValue()
            if (s.size > 0 && !s.contains("***")) {
                o.put("apiKey", JsonString(s))
                return 1
            }
            return 0
        case _ => return 0
    }
}

/** 数字字段：整数按整数发，小数按小数发（温度是 Float64） */
func putIfNumber(o: JsonObject, key: String, v: JsonValue): Int64 {
    match (v.kind()) {
        case JsonKind.JsInt =>
            o.put(key, JsonInt(v.asInt().getValue()))
            return 1
        case JsonKind.JsFloat =>
            o.put(key, JsonFloat(v.asFloat().getValue()))
            return 1
        case _ => return 0
    }
}

/** 取 JsonValue 里的布尔（类型不对或没有都给 false） */
func boolOrFalse(v: JsonValue): Bool {
    match (v.kind()) {
        case JsonKind.JsBool => return v.asBool().getValue()
        case _ => return false
    }
}

/**
 * 保存模型配置：只把**用户真的填了**的字段发给 cjh，留空的字段一个都不碰。
 * 这条很要紧——cjh 对 apiKey 有"空串/掩码不更新"的保护，但对 baseUrl/model 没有：
 * 把空串发过去会把用户已有的服务商清掉。
 */
func cjhSaveSettings(args: JsonObject): JsonValue {
    var payload = JsonObject()
    var n: Int64 = 0
    match (args.get("data")) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsObject =>
                    for ((k, val) in v.asObject().getFields()) {
                        match (k) {
                            case "baseUrl" => n += putIfText(payload, "baseUrl", val)
                            case "model" => n += putIfText(payload, "model", val)
                            case "apiKey" => n += putIfSecret(payload, val)
                            case "temperature" => n += putIfNumber(payload, "temperature", val)
                            case "maxTokens" => n += putIfNumber(payload, "maxTokens", val)
                            case "maxIterations" => n += putIfNumber(payload, "maxIterations", val)
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        case None => ()
    }
    var res = JsonObject()
    if (n == 0) {
        res.put("ok", JsonBool(false))
        res.put("error", JsonString("没有要保存的字段（留空的字段会跳过，不会覆盖 cjh 现有配置）"))
        return res
    }
    let wrapped = wrapJsonPayload(cjhApiCall("POST", "/api/settings", payload.toJsonString()), "保存配置")
    // 保存成功时把「实际写入了几个字段」回给页面，反馈才准确
    var okFlag = false
    match (wrapped.asObject().get("ok")) {
        case Some(v) => okFlag = boolOrFalse(v)
        case None => ()
    }
    if (okFlag) {
        wrapped.asObject().put("savedFields", JsonInt(n))
    }
    return wrapped
}

/**
 * cjh 的运维与配置命令。放在应用里而不是做成插件：它们管的是**本应用自己 spawn 的进程**
 * （句柄就在本文件的两个全局里），没有跨应用复用价值。
 *
 * 命令面：
 *   t2h:cjh_status         三态 + 端点（纯读，可轮询）
 *   t2h:cjh_deploy         校验/部署/拉起/健康检查
 *   t2h:cjh_start          按指定路径拉起（部署不可用时的兜底，UI 默认不给入口）
 *   t2h:cjh_models         GET  /api/models   → {ok, data:{current, models:[...]}}
 *   t2h:cjh_settings       GET  /api/settings → {ok, data:{...}}（密钥是掩码）
 *   t2h:cjh_settings_save  POST /api/settings ← 只提交给到的字段
 */
public class CjhCommands <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = ipc
        match (cmd) {
            case "t2h:cjh_status" => cjhStatusJson()
            case "t2h:cjh_start" => cjhStartByPath(stringArgOr(args, "path", ""))
            case "t2h:cjh_deploy" => cjhDeployAndStart()
            case "t2h:cjh_models" => wrapJsonPayload(cjhApiCall("GET", "/api/models", ""), "读取模型列表")
            case "t2h:cjh_settings" => wrapJsonPayload(cjhApiCall("GET", "/api/settings", ""), "读取配置")
            case "t2h:cjh_settings_save" => cjhSaveSettings(args)
            case _ => throw CommandException("unknown cjh command: ${cmd}")
        }
    }

    /** 取字符串参数：缺失或类型不符都退回默认值（调用方自己判空，给出更贴业务的话） */
    private func stringArgOr(args: JsonObject, key: String, fallback: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return fallback
            }
            case None => return fallback
        }
    }
}

/**
 * 纯函数：引擎已经在跑时，报告「用的是哪一份二进制」。
 *
 * 只认两条**不需要 SHA 校验**的来源（`LINGQU_CJH` 与安装目录）：正在跑的进程不该因为
 * 轮询里做 4 个文件的哈希而变慢；校验只在"要拉起"的路径上做（`cjhBinPath`）。
 * 两条都拿不到就回空串——界面据此显示「已在运行（来源未知）」，不编造路径。
 */
public func knownBinPath(fromEnv: String, envReadable: Bool, installBin: String, installReadable: Bool): String {
    if (envReadable && fromEnv.size > 0) {
        return fromEnv
    }
    if (installReadable && installBin.size > 0) {
        return installBin
    }
    return ""
}

/**
 * 把内嵌的随包资源（cjh + 它的运行时 DLL）释放到安装目录。
 *
 * 单文件产物里这些文件是 PE 资源（RT_RCDATA），编不进静态库、也不在导入表里，
 * 只能运行期写盘再用绝对路径拉起。普通构建没有内嵌资源，本函数返回 0（**不是错误**）。
 * 幂等：目标已在且大小一致时框架会跳过，所以每次启动都可以调。
 */
public func extractEmbeddedCjh(): Int64 {
    let dir = cjhInstallDir()
    if (dir == "") {
        return 0
    }
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir), recursive: true)
        }
    } catch (e: Exception) {
        eprintln("[lingqu] 建安装目录失败：${dir}（${e}）")
        return 0
    }
    return extractEmbeddedAssets(dir)
}

/**
 * 纯函数：释放出来的文件能不能用。
 *
 * 两个条件都要满足：确实释放出了文件（>0），且**SHA256 校验通过**——
 * 校验不过绝不执行（与 vendor 目录同一条纪律：来路不明的同名文件不该被静默运行）。
 */
public func shouldUseExtracted(extracted: Int64, verified: Bool): Bool {
    return extracted > 0 && verified
}
