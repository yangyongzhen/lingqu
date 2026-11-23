package lingqu

import cjTauri.*
import cjTauri.plugins.dialog.*
import cjTauri.plugins.log.*
import cjTauri.plugins.ws.*
import lingqu.scanner.*
import lingqu.deps.*
import lingqu.port.*
import lingqu.compiler.*
import lingqu.verify.*
import lingqu.report.*
import lingqu.batch.*
import std.collection.*
import std.env.*
import std.fs.*
import std.process.*
import std.sync.*
import std.time.*
import stdx.encoding.json.*

/*
 * 灵渠迁移台 · 业务装配点（RFC-002 §4.1）
 *
 * 分工：
 *   - 本文件：环境体检（doctor）+ 命令注册 + 生命周期接线
 *   - cjh_host.cj：cjh 引擎托管（发现 / 健康检查 / 拉起 / 收尾 / 部署），移植自 ai-chat
 *
 * 平台知识为零：窗口、页面、资产、能力目录都由清单 cj-tauri.toml 决定，
 * 桌面 launcher 与鸿蒙 entry 各自覆盖——同一份业务代码编出两端。
 */

// ============================================================
// 小工具
// ============================================================

/** 隐藏控制台是否建立成功（0.39.40；回投 ui_report.consoleHidden 当证据）。
 *  声明在文件前部是必须的：仓颉顶层变量**先定义后使用**，放到文件末尾会报
 *  `variable 'gConsoleHidden' is used before being defined`。 */
var gConsoleHidden: Bool = false

/** 拼路径：自动处理分隔符，避免 base 末尾已有分隔符时出现双分隔 */
public func joinPath(base: String, name: String): String {
    if (base.size == 0) {
        return name
    }
    let last = base[base.size - 1]
    if (last == 92u8 || last == 47u8) {
        return base + name
    }
    return base + "\\" + name
}

/** 读环境变量，空值按缺省处理 */
func envOr(name: String, fallback: String): String {
    match (getVariable(name)) {
        case Some(v) =>
            if (v.size > 0) {
                return v
            }
            return fallback
        case None => return fallback
    }
}

/** 从候选路径里取第一个存在的（体检用：同一工具在不同机器上位置不同） */
public func firstExisting(cands: Array<String>): String {
    for (p in cands) {
        if (p.size > 0 && exists(p)) {
            return p
        }
    }
    return ""
}

/** 体检项：ok 由「找到与否」决定，缺了给一句「缺了就怎么办」 */
func addCheck(arr: JsonArray, id: String, label: String, found: String, hint: String): Unit {
    addCheckScoped(arr, id, label, "", found, hint)
}

/**
 * 带「它影响哪一步」的体检项（0.39.95）。
 *
 * 起因是用户实测的一句诘问：「这些是不是准确？llvm-mingw 跟移植不相关吧，不相干的不需要展示」。
 * 症状：面板把「宿主机构建前提」和「移植必需」混在同一排、缺失时都只写「缺失」，
 * 于是看得出「处处阻塞」，却看不出「这项该不该管」——而两项其实在本机都装着，
 * 报缺失本身就是**判定错**（hdc 走的是过期环境变量，llvm-mingw 只认一条写死路径）。
 * 处置：① 判定改成「真的能跑到」（复用具名解析 / 看 PATH）；② 每项标出影响面（scope），
 * 界面据此显示小字；③ 不适用当前宿主机的项**整项不出现**，不拿它污染「缺 N 项」。
 */
public func addCheckScoped(arr: JsonArray, id: String, label: String, scope: String, found: String, hint: String): Unit {
    var o = JsonObject()
    o.put("id", JsonString(id))
    o.put("label", JsonString(label))
    o.put("scope", JsonString(scope))
    let ok = found.size > 0
    o.put("ok", JsonBool(ok))
    o.put("path", JsonString(found))
    var hintText = ""
    if (!ok) {
        hintText = hint
    }
    o.put("hint", JsonString(hintText))
    arr.add(o)
}

// ============================================================
// ① 环境体检（t2h:env）
// ============================================================

/**
 * `t2h:git_clone`：把一个 Git 地址克隆成"当前工程"（0.39.25）。
 *
 * 与「手敲路径 / 原生选目录」并列的第三条路：工程还没在本机时，先拉下来再选。
 * 参数：`url`（必填）、`dir`（父目录，留空＝工作区根 `LINGQU_WORKSPACES` 或 `~/lingqu-workspaces`）、
 * `depth`（默认 1：浅克隆，够跑迁移；要完整历史传 0）。
 * 回投：`ok / target / hint（像不像 Tauri 工程）/ outputTail / error`。
 */
/**
 * 纯函数：「上次用过的工程」要不要在启动时带回来（0.39.48）。
 *
 * 0.39.44 只把路径带回来、**没校验存在性**，于是"上次工程被删/移走/换机器"时顶层仍显示旧路径、
 * 左栏徽标全「未开始」，用户点下去只得到「路径不存在」——正是 0.39.44 文档里如实记下的那个缺口。
 * 存在性由调用方查（页面没有文件系统能力），这里只做判定，便于单测。
 */
public func shouldRestoreLastProject(last: String, existsOnDisk: Bool): Bool {
    if (last.trimAscii() == "") {
        return false
    }
    return existsOnDisk
}

/**
 * 纯函数：工程路径参数的前置校验（scan / port / deps 共用，0.39.48）。
 *
 * 为什么单拎出来：这三条命令各自复制过同一段判断，而用户最常犯的错——**把 Git 地址填进工程路径**——
 * 它们只会回一句「路径不存在：https://…」。文案没错但等于没说（用户实测原话：
 * 「点迁移画像，提示扫描失败：路径不存在：https://gitcode.com/qq8864/juCang」）。
 * 现在先认"这是地址"，直接告诉他该点哪个按钮。
 *
 * 返回 "" = 可用；否则是给人看的原因（空串不判：空路径由各命令自己的文案处理）。
 */
public func projectPathRejectReason(path: String): String {
    let p = path.trimAscii()
    if (p == "") {
        return ""
    }
    if (looksLikeGitUrl(p)) {
        return "这是 Git 地址，不是本地工程目录：${p}\n先点顶部「克隆…」把它拉下来（拉完会自动设为当前工程），或用「打开工程」选已有目录"
    }
    if (!exists(Path(p))) {
        return "路径不存在：${p}"
    }
    return ""
}

public class GitCloneCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        let url = argStr(args, "url", "")
        let dir = argStr(args, "dir", "")
        let depth = argInt(args, "depth", 1)
        let r = gitCloneProject(url, dir, depth)
        eprintln("[lingqu][git_clone] ok=${r.ok} url=${r.url} target=${r.target} err=${r.error}")
        var o = r.toJson()
        // 顺手把工作区根回投给界面（"克隆到哪"要能看见，别让人猜）
        o.put("workspaceRoot", JsonString(workspaceRootDir()))
        o.put("depth", JsonInt(depth))
        return o
    }
}

/**
 * 把迁移所需的工具链一次性体检出来。
 * 判定口径：路径存在 = 就绪。版本号等「能跑起来才知道」的检查留给后续 t2h:doctor。
 */
/**
 * 纯函数：从 `t2h:ui_report` 落的 JSON 文本里取「上次的当前工程」（0.39.44）。
 *
 * 为什么"记住上次工程"要靠后端：本应用的页面跑在 WebView2 里，**localStorage 被拒**
 * （实测 `setItem` 抛 `SecurityError`，见 `LINGQU_UI_PROBE=store` 自检），于是
 * `localStorage['lingqu.proj']` 永远是空——"最近工程 / 聊天窗宽度 / 偏好开关"这些
 * 记忆全部失效。真值只能来自落档：上一次 ui_report 的 `currentProject` 就是上次用的工程。
 *
 * 取不到（空文本 / 没这个键 / 不是字符串 / JSON 坏了）一律回空串，不抛异常。
 */
public func lastProjectOf(text: String): String {
    if (text.size == 0) {
        return ""
    }
    try {
        return jsonStrField(JsonValue.fromStr(text), "currentProject")
    } catch (e: Exception) {
        let _ = e
        return ""
    }
}

/** 上次用过的工程：读 `.lingqu/ui-report.json`（上一次 ui_report 落的档，本来就带 currentProject）。 */
func lastProjectFromReport(): String {
    let p = ".lingqu/ui-report.json"
    if (!exists(Path(p))) {
        return ""
    }
    try {
        return lastProjectOf(lenientUtf8(File.readFrom(p)))
    } catch (e: Exception) {
        let _ = e
        return ""
    }
}

public class EnvCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, _: JsonObject, _: IpcContext): JsonValue {
        let home = envOr("USERPROFILE", "")
        // 路径类环境变量**必须验存在**才采用，否则落到推导值（AGENTS §4-38）：
        // 本机 DEVECO_SDK_HOME 仍指着已删除的旧 DevEco（`D:\Program Files\Huawei\DevEco Studio\sdk`），
        // 直接拿来拼路径就必然判「hdc/NDK 缺失」，而它们其实都在 DEVECO_HOME 那套 SDK 里。
        let deveco = devecoHomeOr()
        let ndkEnv = envOr("NATIVE_OHOS_SDK", "").trimAscii()

        var arr = JsonArray()

        addCheckScoped(arr, "rustc", "Rust 工具链（rustc / cargo）", "交叉编译",
            firstExisting([
                joinPath(home, ".cargo\\bin\\rustc.exe"),
                "C:\\Program Files\\Rust\\bin\\rustc.exe"
            ]),
            "装 rustup 后应在 %USERPROFILE%\\.cargo\\bin；迁移要靠它交叉编译 .so")

        // 只判「Windows 宿主」这一态：别的平台上 gnullvm 的 C 编译器前提根本不存在，
        // 拿它报缺失就是拿不相干的项污染结论（用户实测指出过这一点）。
        if (hostIsWindows()) {
            addCheckScoped(arr, "llvm-mingw", "llvm-mingw（宿主 C 编译器）", "仅 Windows 主机构建",
                firstExisting(llvmMingwClangCandidates()),
                "gnullvm 通道不自带 C 编译器：凡依赖里有需要编译的 C 代码，缺它就会报 linker x86_64-w64-mingw32-clang not found。装好把它加进 PATH 即可")
        }

        // NDK：环境变量与「DEVECO_HOME 那套 SDK」并列做候选，按**clang 文件**是否存在判定
        var ndkCands = ArrayList<String>()
        if (ndkEnv.size > 0) {
            ndkCands.add(joinPath(ndkEnv, "llvm/bin/clang.exe"))
        }
        let devNdk = joinPath(joinPath(deveco, "sdk"), "default/openharmony/native")
        ndkCands.add(joinPath(devNdk, "llvm/bin/clang.exe"))
        addCheckScoped(arr, "ohos-ndk", "OHOS NDK（clang / sysroot）", "交叉编译",
            firstExisting(ndkCands.toArray()),
            "设 NATIVE_OHOS_SDK 指向 SDK 的 native 目录（DevEco 下载 SDK 后就有）")

        addCheckScoped(arr, "deveco", "DevEco Studio", "HAP 装配",
            firstExisting([deveco]),
            "设 DEVECO_HOME 指向 DevEco Studio 安装目录（打包 HAP 需要 hvigor / ohpm）")

        addCheckScoped(arr, "hvigor", "hvigor 构建器", "HAP 装配",
            firstExisting([
                joinPath(deveco, "tools\\hvigor\\bin\\hvigorw.bat"),
                joinPath(deveco, "tools\\hvigor\\bin\\hvigorw")
            ]),
            "它随 DevEco 一起装；缺了说明 DEVECO_HOME 没指对")

        addCheckScoped(arr, "ohpm", "ohpm 包管理器", "HAP 装配",
            firstExisting([
                joinPath(deveco, "tools\\ohpm\\bin\\ohpm.bat"),
                joinPath(deveco, "tools\\ohpm\\bin\\ohpm")
            ]),
            "它随 DevEco 一起装；HAP 装配前要装 oh 依赖")

        // hdc 复用 hdcPathOr()：环境变量→推导→常见安装路径都在里面验过（0.39.95）。
        // 以前这里自己用裸 DEVECO_SDK_HOME 拼了一份，环境变量一过期就报「缺失」。
        addCheckScoped(arr, "hdc", "hdc 设备桥", "真机部署",
            hdcPathOr(),
            "它随 SDK 走；部署到鸿蒙 PC 真机靠它。找不到时设 DEVECO_HOME / DEVECO_SDK_HOME 指向有效安装")

        // cjh 复用 cjh_host 的解析（env → 已部署 → 仓内 vendor，vendor 还要过 SHA256）
        addCheckScoped(arr, "cjh", "AI 引擎 cjh（内置）", "AI 面板",
            cjhBinPath(),
            "把 cjh.exe 放到 vendor/cjh/win-x64/ 或用 LINGQU_CJH 指向它；缺了 AI 面板不可用（其余功能照常）")

        var res = JsonObject()
        res.put("items", arr)
        res.put("cjhPort", JsonInt(cjhPort()))
        // 界面自检开关：置 1 时页面会自己跑一遍「开设置 → 折叠 → 展开 → 发一句」并逐步上报；
        // 置 approval 时改为发一条会触发危险操作审批的指令（验证审批卡）。
        res.put("uiProbe", JsonString(envOr("LINGQU_UI_PROBE", "")))
        // 上次用过的工程（0.39.44）：页面启动时用它把工程带回来（localStorage 不可用，
        // 见 lastProjectOf 的注释与 `LINGQU_UI_PROBE=store` 自检）。
        res.put("lastProject", JsonString(lastProjectFromReport()))
        // 上次工程还在不在（0.39.48）：0.39.44 只带回路径、不校验存在性，于是"上次工程被删/移走"
        // 时顶层仍显示旧路径、徽标全「未开始」，用户点下去只会得到「路径不存在」。
        // 这里让后端判一次（页面没有文件系统能力），带不回来就当没有。
        let lp = lastProjectFromReport()
        var lpOk = false
        if (lp.trimAscii() != "") {
            lpOk = exists(Path(hostPath(lp)))
        }
        res.put("lastProjectOk", JsonBool(shouldRestoreLastProject(lp, lpOk)))
        // 扫描探针：给了路径就在启动时跑一次 t2h:scan，把指标回投到 ui_report（无视觉也能验扫描器）
        res.put("scanPath", JsonString(envOr("LINGQU_SCAN_PATH", "")))
        // 克隆探针（0.39.48）：`LINGQU_UI_PROBE=clone` 时页面用这个地址跑一遍"填地址→被拦→真克隆"，
        // 不设就用默认的公开仓库；`LINGQU_CLONE_DIR` 可指定父目录（默认工作区根）
        res.put("cloneUrl", JsonString(envOr("LINGQU_CLONE_URL", "")))
        res.put("cloneDir", JsonString(envOr("LINGQU_CLONE_DIR", "")))
        // 编译探针（T5-1）：置 LINGQU_BUILD_PATH 就在启动时跑一次 t2h:build（交叉编译），
        // 结果与指纹命中回投 ui_report。**耗时以分钟计**，只在显式设置时才跑。
        res.put("buildPath", JsonString(envOr("LINGQU_BUILD_PATH", "")))
        // 置 LINGQU_BUILD_VERIFY_ONLY=1 时，build 探针改为**只校验不编译**（T5-2 前端指纹；
        // 也是"改了前端没重编 .so 必须报错"这条自证用得上的一键入口）
        res.put("buildVerifyOnly", JsonString(envOr("LINGQU_BUILD_VERIFY_ONLY", "")))
        // 置 LINGQU_HAP_PATH 就在启动时跑一次 t2h:hap（HAP 装配，耗时以分钟计）
        res.put("hapPath", JsonString(envOr("LINGQU_HAP_PATH", "")))
        // 置 LINGQU_SIGN_PATH 就在启动时跑一次 t2h:sign（签名体检，秒级、不需要账号）
        res.put("signPath", JsonString(envOr("LINGQU_SIGN_PATH", "")))
        // 置 LINGQU_UI_SCREEN 就把启动时的初始屏切过去（截某屏版面证据的可复现入口）
        res.put("uiScreen", JsonString(envOr("LINGQU_UI_SCREEN", "")))
        // 置 LINGQU_DEPLOY_PATH 就在启动时跑一次 t2h:deploy（装 → 启 → 抓 hilog，秒级）
        res.put("deployPath", JsonString(envOr("LINGQU_DEPLOY_PATH", "")))
        // 置 LINGQU_VERIFY_PATH 就在启动时跑一次 t2h:verify（采证 + 可用率 + 报告）
        res.put("verifyPath", JsonString(envOr("LINGQU_VERIFY_PATH", "")))
        // 置 LINGQU_RESUME_PATH 就在启动时跑一次 t2h:resume（T6-5 断点续迁，纯读盘、秒级）
        res.put("resumePath", JsonString(envOr("LINGQU_RESUME_PATH", "")))
        // 置 LINGQU_REPORT_PATH 就在启动时出一次迁移报告（T6-4，纯读盘、秒级）
        res.put("reportPath", JsonString(envOr("LINGQU_REPORT_PATH", "")))
        // 置 LINGQU_BATCH_SAMPLES（`路径1|路径2`）就在启动时出一次 5 样本矩阵（T7-3，纯读盘、秒级）
        res.put("batchSamples", JsonString(envOr("LINGQU_BATCH_SAMPLES", "")))
        // 置 LINGQU_SKILL=install 就在启动时装一次迁移技能（status 只查状态；秒级）
        res.put("skillAction", JsonString(envOr("LINGQU_SKILL", "")))
        // 置 LINGQU_AGENT=install|status|remove 就在启动时装工程上下文（写 AGENTS.md 区块 + 切 workspace）
        res.put("agentAction", JsonString(envOr("LINGQU_AGENT", "")))
        res.put("agentPath", JsonString(envOr("LINGQU_AGENT_PATH", "")))
        return res
    }
}

// ============================================================
// ② 退出（t2h:quit）：先收 cjh，再退窗口
// ============================================================

/**
 * 前端主动退应用。顺序有意为之：**先收我们自己拉起的 cjh，再退窗口**——
 * 反过来的话窗口一关事件循环就返回，收尾只能靠守护线程兜底（那条路也留着，见 startLifecycleWaiter）。
 */
public class QuitCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(_: String, _: JsonObject, _: IpcContext): JsonValue {
        eprintln("[lingqu] 前端请求退出")
        shutdownCjh()
        this.app.quit()
        return JsonBool(true)
    }
}

// ============================================================
// ③ 生命周期接线
// ============================================================

/**
 * 退出收尾的守护线程。
 *
 * 为什么需要它：新形态 AppSpec 没有 onExit 钩子，业务拿不到「run 之后」那一行——
 * ai-chat 是 `app.run(html)` 之后直接调 shutdownCjh()，这里改成用 waitForExit() 等窗口全退出。
 *
 * 两个前提：① wire 在 run 之前执行，此刻窗口还没登记，得先等主窗出现，
 * 否则 allWindowsExited() 立刻为真、收尾会在拉起 cjh 之前就跑完（等于没收）；
 * ② 只收自己拉起的（shutdownCjh 内部按 gCjhOwned 判定）。
 */
func startLifecycleWaiter(app: TauriApp): Unit {
    spawn {
        var spins: Int64 = 0
        var registered = false
        while (!registered && spins < 300) {
            match (app.hostOf("main")) {
                case Some(_) => registered = true
                case None =>
                    sleep(Duration.millisecond * 100)
                    spins += 1
            }
        }
        if (!registered) {
            eprintln("[lingqu] 主窗 30s 内没登记——退出收尾不挂载（cjh 不会被自动收回）")
            return
        }
        app.waitForExit()
        eprintln("[lingqu] 窗口已全部退出，开始收尾")
        // 收尾跑几轮：自动拉起引擎在后台线程里，可能与"用户秒关窗口"抢跑——
        // 单次 shutdownCjh 有可能在 gCjhOwned 变 true 之前就跑完，等于没收
        var i: Int64 = 0
        while (i < 5) {
            shutdownCjh()
            sleep(Duration.millisecond * 200)
            i += 1
        }
    }
}

// ============================================================
// ⑤ 迁移扫描（t2h:scan）：P2
// ============================================================

/**
 * 扫描一个 Tauri 工程，产出 `lingqu/scan/v1` 的画像（五类清单 + 覆盖率 + 评分）。
 * 口径见 `docs/P2-scan-口径草案.md`：一项 = 迁移单元；未知是禁用值。
 * 结果同时落 `.lingqu/scan/<工程名>.json`（证据留档，报告从这里派生）。
 */
/**
 * 只读回读**扫描**落档（0.39.87）：`t2h:scan {action:"load"}` 走这里。
 *
 * 为什么要它：AI 自动迁移时 cjh 会自己跑 `lingqu-cli scan`，落档写得整整齐齐，可界面上的
 * 「可迁移度 / 覆盖率 / 五类清单」**仍旧是空的**——那些面板原先只在人点「开始扫描」时才渲染
 * （用户实测原话：「会自动执行左侧的迁移画像和依赖扫描等操作，但各个项里面的内容没有更新」）。
 * 为什么不干脆重跑一遍扫描：那样页面显示的是"现在重算的数"，可能是与落档不同的另一份，
 * 正好撞上本项目最怕的那类谎报（§0.1「落档说了算」）。**读盘回投，页面看到的就是落档。**
 */
func scanRecordResponse(path: String): JsonObject {
    var res = JsonObject()
    var nm = projectNameOf(path)
    if (nm.size == 0) {
        nm = "project"
    }
    nm = sanitizeFileName(nm)
    let outFile = lqPathOf(path, "scan/${nm}.json")
    res.put("project", JsonString(nm))
    res.put("out", JsonString(outFile))
    if (!exists(Path(outFile))) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("还没有扫描落档（${outFile}）：先点「开始扫描」，或让 agent 跑 " +
            "lingqu-cli scan --path <工程>"))
        return res
    }
    var root = JsonValue.fromStr("{}")
    try {
        root = JsonValue.fromStr(lenientUtf8(File.readFrom(outFile)))
    } catch (e: Exception) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("读扫描落档失败：${e}"))
        return res
    }
    res.put("ok", JsonBool(true))
    res.put("loaded", JsonBool(true))
    res.put("scan", root)
    // metrics / score 落档里就自带（`lingqu/scan/v1` 自包含这两段），原样透传，
    // 前端两处取值（res.metrics 与 res.scan.metrics 兜底）才不会打架。
    var obj = JsonObject()
    match (root.kind()) {
        case JsonKind.JsObject => obj = root.asObject()
        case _ => ()
    }
    match (obj.get("metrics")) {
        case Some(v) => res.put("metrics", v)
        case None => ()
    }
    match (obj.get("score")) {
        case Some(v) => res.put("score", v)
        case None => ()
    }
    return res
}

/**
 * 只读回读**依赖矩阵**落档（0.39.87）：`t2h:deps {action:"load"}` 走这里。
 * 与 `scanRecordResponse` 同因同理——AI 跑完依赖扫描，② 屏的矩阵不该还是空的。
 */
func depsRecordResponse(path: String): JsonObject {
    var res = JsonObject()
    var nm = projectNameOf(path)
    if (nm.size == 0) {
        nm = "project"
    }
    nm = sanitizeFileName(nm)
    let outFile = lqPathOf(path, "deps/${nm}.json")
    res.put("project", JsonString(nm))
    res.put("out", JsonString(outFile))
    if (!exists(Path(outFile))) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("还没有依赖矩阵落档（${outFile}）：先点「扫描依赖」，或让 agent 跑 " +
            "lingqu-cli deps --path <工程>"))
        return res
    }
    var root = JsonValue.fromStr("{}")
    try {
        root = JsonValue.fromStr(lenientUtf8(File.readFrom(outFile)))
    } catch (e: Exception) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("读依赖矩阵落档失败：${e}"))
        return res
    }
    res.put("ok", JsonBool(true))
    res.put("loaded", JsonBool(true))
    // error 留空：落档内部自带 outError，页面按 `r.error || deps.outError` 兜底
    res.put("error", JsonString(""))
    res.put("deps", root)
    return res
}

/**
 * 只读回读**构建**落档（0.39.88）：`t2h:build {action:"load"}` 走这里。
 *
 * 与 scan/deps 同因（§4-135 判据①）：⑤ 屏原先只在人点「交叉编译」时渲染，
 * agent 用 `lingqu-cli build` 跑完之后，屏上仍是"还没跑交叉编译"——落档里
 * `exitCode=0 / 产物 .so / 六道闸` 俱全，界面却一无所知。
 * **纯读盘、不重跑**：重编一次是分钟级，而且显示的就成了"现在重算的那份"，
 * 与落档不是同一份（§0.1「落档说了算」）。
 */
func buildRecordResponse(path: String): JsonObject {
    var res = JsonObject()
    var nm = projectNameOf(path)
    if (nm.size == 0) {
        nm = "project"
    }
    nm = sanitizeFileName(nm)
    let outFile = lqPathOf(path, "build/${nm}.json")
    res.put("project", JsonString(nm))
    res.put("outJson", JsonString(outFile))
    if (!exists(Path(outFile))) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("还没有构建落档（${outFile}）：先点「交叉编译」，或让 agent 跑 " +
            "lingqu-cli build --path <工程>"))
        return res
    }
    var root = JsonValue.fromStr("{}")
    try {
        root = JsonValue.fromStr(lenientUtf8(File.readFrom(outFile)))
    } catch (e: Exception) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("读构建落档失败：${e}"))
        return res
    }
    res.put("loaded", JsonBool(true))
    return buildRecordOf(res, root)
}

/**
 * 把 `lingqu/build/v1` 落档映射成 `t2h:build` 的返回体（纯函数，有单测）。
 * 字段名对着落档 schema 抄（§4-57）：`errorCount` / `artifacts` / `gates` / `assetDiff` 同名透传，
 * 落档里没有的只有 `ok`（由 exitCode 推）与 `error`（读完就没有错误）。
 */
func buildRecordOf(res: JsonObject, root: JsonValue): JsonObject {
    var obj = JsonObject()
    match (root.kind()) {
        case JsonKind.JsObject => obj = root.asObject()
        case _ => ()
    }
    let exitCode = argInt(obj, "exitCode", -1)
    // 判据与命令本身一致：编译退出码 0 才算通过（产物闸的失败在 gates 里，页面自己会显示）
    res.put("ok", JsonBool(exitCode == 0))
    for (k in ["target", "diagnosis", "gates", "assetDiff", "soPath", "expectedSo", "distDir"]) {
        match (obj.get(k)) {
            case Some(v) => res.put(k, v)
            case None => ()
        }
    }
    for (k in ["exitCode", "errorCount", "warningCount", "baselineErrors", "stderrErrors"]) {
        res.put(k, JsonInt(argInt(obj, k, -1)))
    }
    match (obj.get("artifacts")) {
        case Some(v) => res.put("artifacts", v)
        case None => res.put("artifacts", JsonArray())
    }
    match (obj.get("diags")) {
        case Some(v) => res.put("diags", v)
        case None => res.put("diags", JsonArray())
    }
    res.put("error", JsonString(""))
    return res
}

/**
 * 只读回读**验证**落档（0.39.88）：`t2h:verify {action:"load"}` 走这里。
 * ⑥ 屏的可用率/清单/证据三块同理——agent 跑过 `lingqu-cli verify` 之后不该还显示"尚未验证"。
 */
func verifyRecordResponse(path: String): JsonObject {
    var res = JsonObject()
    var nm = projectNameOf(path)
    if (nm.size == 0) {
        nm = "project"
    }
    nm = sanitizeFileName(nm)
    let outFile = lqPathOf(path, "verify/${nm}.json")
    res.put("project", JsonString(nm))
    res.put("outJson", JsonString(outFile))
    if (!exists(Path(outFile))) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("还没有验证落档（${outFile}）：先点「采集证据并算可用率」，或让 agent 跑 " +
            "lingqu-cli verify --path <工程>"))
        return res
    }
    var root = JsonValue.fromStr("{}")
    try {
        root = JsonValue.fromStr(lenientUtf8(File.readFrom(outFile)))
    } catch (e: Exception) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("读验证落档失败：${e}"))
        return res
    }
    res.put("loaded", JsonBool(true))
    return verifyRecordOf(res, root, countEvidenceShots(path), path, nm)
}

/**
 * 把 `lingqu/verify/v1` 落档映射成 `t2h:verify` 的返回体（纯函数，有单测）。
 * 统计在落档的 `stats` 段里（不是在顶层）：`total/pass/fail/limit/unknown/covered/notVerified/
 * ratePercent/scope/scopeNote`，清单在 `items`。**按 schema 抄字段名**（§4-57 第 1 条）。
 */
func verifyRecordOf(res: JsonObject, root: JsonValue, shots: Int64, projPath: String, projName: String): JsonObject {
    var obj = JsonObject()
    match (root.kind()) {
        case JsonKind.JsObject => obj = root.asObject()
        case _ => ()
    }
    var stats = JsonObject()
    match (obj.get("stats")) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsObject => stats = v.asObject()
            case _ => ()
        }
        case None => ()
    }
    for (k in ["total", "pass", "fail", "limit", "unknown", "covered", "notVerified", "ratePercent",
               "featurePass", "transplantTotal", "transplantNotVerified",
               "businessTotal", "businessTested", "businessPass"]) {
        res.put(k, JsonInt(argInt(stats, k, -1)))
    }
    res.put("scope", JsonString(argStr(stats, "scope", "")))
    res.put("scopeNote", JsonString(argStr(stats, "scopeNote", "")))
    match (obj.get("items")) {
        case Some(v) => res.put("items", v)
        case None => res.put("items", JsonArray())
    }
    res.put("bundleName", JsonString(argStr(obj, "bundleName", "")))
    res.put("serial", JsonString(argStr(obj, "serial", "")))
    res.put("screenshots", JsonInt(shots))
    // 证据/报告三件套按工程路径重新定位（落档只记了内容，没记自己的 md/html 路径）
    res.put("md", JsonString(lqPathOf(projPath, "verify/${projName}.md")))
    res.put("html", JsonString(lqPathOf(projPath, "verify/${projName}.html")))
    res.put("evidenceLog", JsonString(lqPathOf(projPath, "evidence/verify.log")))
    res.put("ok", JsonBool(true))
    res.put("error", JsonString(""))
    return res
}

/** 证据目录里的真机截图张数（`format png`；读不到就 0——不编数字，§4-63） */
func countEvidenceShots(path: String): Int64 {
    let dir = lqPathOf(path, "evidence")
    if (!exists(Path(dir))) {
        return 0
    }
    var n: Int64 = 0
    try {
        for (f in Directory.readFrom(Path(dir))) {
            if (f.name.endsWith(".png")) {
                n += 1
            }
        }
    } catch (e: Exception) {
        return n
    }
    return n
}

public class ScanCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        var res = JsonObject()
        if (path.size == 0) {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("t2h:scan 需要参数 path（或设环境变量 LINGQU_SCAN_PATH）"))
            return res
        }
        // 路径校验收成一处（0.39.48）：URL 误填进工程路径时要说"先克隆"，别只说"路径不存在"
        let badPath = projectPathRejectReason(path)
        if (badPath != "") {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString(badPath))
            return res
        }

        // ---- action=load（0.39.87）：**只回读落档，不重跑扫描** ----
        // 界面在"进 ① 屏"和"AI 刚把扫描这一步跑完"时走这条，页面看到的就是 agent 写下的那份。
        if (argStr(args, "action", "") == "load") {
            return scanRecordResponse(path)
        }

        // 工程名取路径末段（"/" 与 "\" 都认——Windows 路径只按 "/" 切会把整条路径当名字）
        var name = projectNameOf(path)
        if (name.size == 0) {
            name = "project"
        }
        // 兜底：个别字符（`:` 等）在文件名里不合法，统一替换成 `_`
        name = sanitizeFileName(name)

        // ---- C2 人工基线：参数 baseline 优先，否则自动找 samples/baselines/<工程名>.json ----
        // 基线是「人工通读得出的该被识别的项」；没有基线就不出 C2（如实标 -1，绝不编 100）
        var baselinePath = argStr(args, "baseline", "")
        var baselineErr = ""
        if (baselinePath.size == 0) {
            let guess = "samples/baselines/${name}.json"
            if (exists(Path(guess))) {
                baselinePath = guess
            }
        }
        var blOpt: Option<Baseline> = None
        if (baselinePath.size > 0) {
            if (exists(Path(baselinePath))) {
                try {
                    let bl = parseBaseline(lenientUtf8(File.readFrom(baselinePath)))
                    if (bl.total() > 0) {
                        blOpt = Some(bl)
                    } else {
                        baselineErr = "基线文件解析出 0 项：${baselinePath}"
                    }
                } catch (e: Exception) {
                    baselineErr = "读基线失败：${e}"
                }
            } else {
                baselineErr = "基线文件不存在：${baselinePath}"
            }
        }

        let scan = scanProject(path, blOpt)
        let json = scan.toJson()

        // 落档跟着工程走（0.38.0）：写进 `<工程>/.lingqu/scan/`，agent（cwd=工程）与界面看到同一份
        let outDir = lqDirOf(path) + cjhPathSep() + "scan"
        let outFile = outDir + cjhPathSep() + name + ".json"
        var wrote = false
        // 写盘失败必须能被看见：eprintln 在 GUI 里会被框架日志接管（AGENTS §4 第 14 条），
        // 只打日志等于没证据 —— 所以把原因塞进返回值，页面和 ui_report 都能断言。
        var outErr = ""
        try {
            ensureDirOf(outDir)
            File.writeTo(outFile, json.toJsonString().toArray())
            wrote = true
        } catch (e: Exception) {
            outErr = "${e}"
            eprintln("[lingqu][scan] 写扫描结果失败：${e}")
        }

        res.put("ok", JsonBool(true))
        res.put("project", JsonString(name))
        res.put("out", JsonString(if (wrote) { outFile } else { "" }))
        res.put("outError", JsonString(outErr))
        var baselineUsed = ""
        match (blOpt) {
            case Some(_) => baselineUsed = baselinePath
            case None => ()
        }
        res.put("baseline", JsonString(baselineUsed))
        res.put("baselineError", JsonString(baselineErr))
        res.put("metrics", scan.metricsJson())
        res.put("score", scan.scoreJson())
        res.put("scan", json)
        match (scan.conf) {
            case Some(cf) => res.put("confidence", cf.toJson())
            case None => ()
        }
        let c = scan.counts()
        eprintln("[lingqu][scan] ${name}: R=${c[0]} D=${c[1]} H=${c[2]} U=${c[3]}")
        return res
    }
}

/**
 * 取 JsonValue（对象）里的字符串字段；缺失/类型不符回空串。
 * （嵌套 match 的 case 块里只能放 return 式表达式，不能放 let/语句——故抽函数）
 */
func jsonStrField(v: JsonValue, key: String): String {
    match (v.kind()) {
        case JsonKind.JsObject =>
            match (v.asObject().get(key)) {
                case Some(sv) =>
                    match (sv.kind()) {
                        case JsonKind.JsString => return sv.asString().getValue()
                        case _ => return ""
                    }
                case None => return ""
            }
        case _ => return ""
    }
}

/**
 * t2h:decisions —— 人工决策记录（T4-8 可审计的另一半）。
 *   action=record：{path, rule, decision: accepted|ignored, note?}
 *     → 追加/覆盖写 `.lingqu/port/<工程>/decisions.json`（lingqu/decisions/v1）
 *   action=list：{path} → 返回该工程的决策记录
 * A3 口径：guide 项被"采纳"即一次人工介入；被"忽略"也要留痕（说明为什么不需要）。
 */
public class DecisionsCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        var res = JsonObject()
        if (path.size == 0) {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("t2h:decisions 需要参数 path"))
            return res
        }
        var name = projectNameOf(path)
        if (name.size == 0) {
            name = "project"
        }
        let dir = lqDirOf(path) + cjhPathSep() + "port" + cjhPathSep() + "${sanitizeFileName(name)}"
        let file = "${dir}/decisions.json"
        let action = argStr(args, "action", "list")

        // 读现有记录（不存在则空表）
        var items = JsonArray()
        try {
            if (exists(Path(file))) {
                let root = JsonValue.fromStr(lenientUtf8(File.readFrom(file)))
                match (root.kind()) {
                    case JsonKind.JsObject =>
                        match (root.asObject().get("items")) {
                            case Some(v) => items = v.asArray()
                            case None => ()
                        }
                    case _ => ()
                }
            }
        } catch (e: Exception) {
            // 坏文件按空表起（record 会重写覆盖）；list 时如实带 outError
            if (action == "list") {
                res.put("ok", JsonBool(false))
                res.put("error", JsonString("决策记录文件损坏：${e}"))
                return res
            }
        }

        if (action == "record") {
            let rule = argStr(args, "rule", "")
            let decision = argStr(args, "decision", "")
            if (rule.size == 0 || (decision != "accepted" && decision != "ignored")) {
                res.put("ok", JsonBool(false))
                res.put("error", JsonString("record 需要 rule 与 decision（accepted|ignored）"))
                return res
            }
            // 同 rule 覆盖最新决策（重复点采纳/忽略不产生重复条目）
            var newItems = JsonArray()
            for (i in 0..items.size()) {
                let it = items.get(i).getOrThrow()
                if (jsonStrField(it, "rule") == rule) {
                    continue // 旧条目被新决策覆盖
                }
                newItems.add(it)
            }
            var item = JsonObject()
            item.put("rule", JsonString(rule))
            item.put("decision", JsonString(decision))
            // source：谁提的案（"" = 人在界面里手点；"ai" = AI 提案经人确认）——报告要能分开数
            item.put("source", JsonString(argStr(args, "source", "")))
            item.put("note", JsonString(argStr(args, "note", "")))
            newItems.add(item)
            var root = JsonObject()
            root.put("schema", JsonString("lingqu/decisions/v1"))
            root.put("project", JsonString(name))
            root.put("items", newItems)
            try {
                ensurePortDirs(lqDirOf(path) + cjhPathSep() + "port")
                if (!exists(Path(dir))) {
                    Directory.create(Path(dir))
                }
                File.writeTo(file, root.toJsonString().toArray())
            } catch (e: Exception) {
                res.put("ok", JsonBool(false))
                res.put("outError", JsonString("${e}"))
                eprintln("[lingqu][decisions] 写决策记录失败：${e}")
                return res
            }
            // 落盘成功后把 items 换成新表——否则返回值与 accepted/ignored 计数都是改前的
            // 旧数据，界面刚点完"采纳"却看到"已决策 0"（0.13.1 修）
            items = newItems
            res.put("total", JsonInt(newItems.size()))
        }

        res.put("ok", JsonBool(true))
        res.put("project", JsonString(name))
        res.put("file", JsonString(file))
        res.put("items", items)
        var accepted: Int64 = 0
        var ignored: Int64 = 0
        for (i in 0..items.size()) {
            let dv = jsonStrField(items.get(i).getOrThrow(), "decision")
            if (dv == "accepted") {
                accepted += 1
            } else if (dv == "ignored") {
                ignored += 1
            }
        }
        res.put("accepted", JsonInt(accepted))
        res.put("ignored", JsonInt(ignored))
        eprintln("[lingqu][decisions] ${name}: action=${action} accepted=${accepted} ignored=${ignored}")
        return res
    }
}

/**
 * 组装一步的**失败现场**（AiBriefCommand 与一键迁移共用同一份实现）。
 *
 * 共用是有意的：两处各写一套必然漂移——一键迁移里说的"为什么失败"和界面按钮问 AI 的
 * "为什么失败"必须是同一句话（AGENTS §4-33）。
 */
func stepBriefOf(projName: String, path: String, step: String, logLines: Int64): StepBrief {
    let obs = observeTaskStepAt(projName, step, path)
    let b = StepBrief()
    b.project = projName
    b.projectDir = path
    b.step = step
    b.stepTitle = taskStepTitle(step)
    b.note = obs.note
    b.artifact = obs.artifact
    b.artifactExists = obs.exists
    // 落档正文：读不出来就留空——提问里会写"没有落档正文"，而不是塞一段假 JSON
    if (obs.exists && obs.artifact != "") {
        b.artifactClip = clipCharsOf(readTextOrEmpty(obs.artifact).trimAscii(), ASK_CLIP_CHARS)
    }
    // 日志尾部：`port`/`scan`/`deps` 没有整篇日志，`taskStepLogPath` 回空串
    let logP = taskStepLogPath(projName, step)
    b.logPath = logP
    b.tailLines = if (logLines > 0) { logLines } else { ASK_LOG_TAIL_LINES }
    if (logP != "") {
        b.logTail = clipCharsOf(tailLinesOf(readTextOrEmpty(logP), b.tailLines), ASK_CLIP_CHARS)
    }
    return b
}

/** t2h:ai_brief —— G1+G2：把某一步的**失败现场**拼成一段可以直接发给 AI 的提问。
 *
 *   {path, step, logLines?} → {ok, step, stepTitle, project, prompt, artifact, artifactExists, logPath, logLines}
 *
 * 为什么把这层放在后端而不是页面里拼：落档字段名（`hapBytes`、`entries.rawfileCount`、
 * `gates.failures`）只有这一侧知道（AGENTS §4-57 的教训），页面拼必然写出「HAP 0 字节」这类假数字。
 * 这里复用 `observeTaskStep`（断点板同一套观测），所以提问里的结论与断点板**永远不会各说一套**。
 *
 * 只读：读 `.lingqu/<step>/<工程>.json` 与同名 `.log`，不改任何文件、不跑子进程。
 * 该步骤不值得自动诊断（`autoAskStepAllowed` 为假）时返回 `{ok:false, skipped:true}`，
 * 让页面如实显示"这步不自动问"，而不是假装发了一次。
 */
public class AiBriefCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        let step = argStr(args, "step", "")
        var res = JsonObject()
        res.put("step", JsonString(step))
        if (taskStepIndex(step) < 0) {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("t2h:ai_brief 需要 step（${taskStepIdsJoined()} 之一）"))
            eprintln("[lingqu][ai] brief: 步骤不认识「${step}」")
            return res
        }
        res.put("stepTitle", JsonString(taskStepTitle(step)))
        if (!autoAskStepAllowed(step)) {
            res.put("ok", JsonBool(false))
            res.put("skipped", JsonBool(true))
            res.put("error", JsonString("「${taskStepTitle(step)}」不自动诊断：失败多半是路径/参数填错，" +
                "界面上直接提示比发给模型更快"))
            eprintln("[lingqu][ai] brief: skip step=${step}（autoAskStepAllowed=false）")
            return res
        }
        var name = projectNameOf(path)
        if (name.size == 0) {
            name = "project"
        }
        let safe = sanitizeFileName(name)
        let obs = observeTaskStepAt(safe, step, path)
        let asked = argInt(args, "logLines", ASK_LOG_TAIL_LINES)
        let b = stepBriefOf(safe, path, step, asked)
        // 提问里用的工程名是原始名（路径末段），落档目录用的是净化名——两者都要给的场合分开写
        b.project = name
        let prompt = buildAutoAskPrompt(b)
        res.put("ok", JsonBool(true))
        res.put("skipped", JsonBool(false))
        res.put("project", JsonString(name))
        res.put("artifact", JsonString(obs.artifact))
        res.put("artifactExists", JsonBool(obs.exists))
        res.put("logPath", JsonString(b.logPath))
        res.put("logLines", JsonInt(if (b.logTail.size > 0) { b.tailLines } else { 0 }))
        res.put("note", JsonString(obs.note))
        res.put("prompt", JsonString(prompt))
        res.put("promptChars", JsonInt(Int64(prompt.size)))
        // 判定权在落档，不在页面：**没跑过（落档不存在）不算失败**，不许因此去打扰模型
        // （与断点板 §4-63 同一口径：未跑 ≠ 0 分 ≠ 通过）
        var verdictOk = true
        if (obs.exists) {
            verdictOk = obs.ok
        }
        // force：给界面自检探针用（验"链路通不通"而不是"这一步到底过没过"）——
        // 只有 probe 会传，正常路径永远按落档判
        if (argBool(args, "force", false)) {
            verdictOk = false
        }
        res.put("verdictOk", JsonBool(verdictOk))
        eprintln("[lingqu][ai] brief step=${step} project=${name} 落档=${obs.exists} 判定=${verdictOk} " +
            "日志尾部=${b.logPath} 提问=${prompt.size} 字")
        return res
    }
}

/**
 * t2h:ai_decide —— G4：从 AI 回复里抽 `lingqu-decision` 块，渲染成确认卡的数据源。
 *
 *   {text} → {ok, proposals:[{rule, decision, why, line}]}
 *
 * 解析放在后端而不是页面：`parseDecisionBlocks` 有单测、与 `t2h:decisions` 的字段口径同源，
 * 页面自己再写一份正则必然会和落档 schema 漂移（AGENTS §4-33：只改一处 = 静默破坏另一条链路）。
 * 只读：不改任何文件；真正落档要人点确认卡，走 `t2h:decisions`。
 */
public class AiDecideCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        let text = argStr(args, "text", "")
        let proposals = parseDecisionBlocks(text)
        var arr = JsonArray()
        for (p in proposals) {
            var o = JsonObject()
            o.put("rule", JsonString(p.rule))
            o.put("decision", JsonString(p.decision))
            o.put("why", JsonString(p.why))
            o.put("line", JsonString(decisionProposalLine(p)))
            arr.add(o)
        }
        var res = JsonObject()
        res.put("ok", JsonBool(true))
        res.put("count", JsonInt(Int64(proposals.size)))
        res.put("proposals", arr)
        if (proposals.size > 0) {
            eprintln("[lingqu][ai] decide: 抽出 ${proposals.size} 条决策提案")
        }
        return res
    }
}

/**
 * t2h:diagnose —— 错误指纹诊断（T4-7 Agent 兜底闭环的"不调模型"半边）。
 *   输入：args.log（日志全文）或 args.logPath（日志文件路径）
 *   输出：命中的指纹（现象→根因→修法）、rule 档建议（重跑 t2h:port 即可修）
 *   与补丁提案的六道闸校验结果（默认 0 轮 0 失败——闸的轮次计数在 agent 闭环层持有）。
 *   指纹未命中时如实返回空（长尾才走 LLM，见技术思路 §5.5）。
 */
public class DiagnoseCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var res = JsonObject()
        var logText = argStr(args, "log", "")
        let logPath = argStr(args, "logPath", "")
        if (logText.size == 0 && logPath.size > 0) {
            try {
                logText = lenientUtf8(File.readFrom(logPath))
            } catch (e: Exception) {
                res.put("ok", JsonBool(false))
                res.put("error", JsonString("读日志文件失败：${e}"))
                return res
            }
        }
        if (logText.size == 0) {
            logText = envOr("LINGQU_DIAGNOSE_LOG", "")
        }
        if (logText.size == 0) {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("t2h:diagnose 需要参数 log（日志全文）或 logPath（日志文件路径）"))
            return res
        }

        // 飞轮阶段 4（0.39.113）：内置库 + **用户级认知层**（`~/.lingqu/flywheel/fingerprints.json`）。
        // 用户级排前、同 id 用用户版本——这条"自己学到的坑，下个工程就命中"的通路不登录也能走。
        let userFpText = readUserFingerprintsText()
        let fpLib = fingerprintLibraryWithUser(userFpText)
        let items = diagnoseLogWith(logText, fpLib)
        res.put("userFingerprintsDir", JsonString(userFlywheelDir()))
        res.put("userFingerprints", JsonInt(Int64(parseFingerprintsJson(userFpText).size)))
        res.put("librarySize", JsonInt(Int64(fpLib.size)))
        // 0.39.115：规则清单也回投——「一共几条改造规则、编号范围是什么」不再只能靠人数
        // （`src/port/rules.cj` 是唯一清单，这里只是它的读者；条数漂移由 port_rules_test 判红）。
        res.put("ruleCount", JsonInt(portRuleCount()))
        res.put("ruleRange", JsonString(portRuleRangeTextOf()))
        var ruleArr = JsonArray()
        for (rid in portRuleIds()) {
            ruleArr.add(JsonString(rid))
        }
        res.put("ruleIds", ruleArr)
        // 0.39.116：指纹清单也回投——「一共几条指纹、编号范围是什么」不再只能靠人数
        // （`fingerprintLibrary()` 本身就是唯一清单，这里只是它的读者；条数漂移由
        //  fingerprint_manifest_test 判红，含保留空位 FP-008/FP-009 的编号连续性）。
        res.put("fingerprintCount", JsonInt(fingerprintCount()))
        res.put("fingerprintRange", JsonString(fingerprintRangeTextOf()))
        var fpIdArr = JsonArray()
        for (fid in fingerprintIds()) {
            fpIdArr.add(JsonString(fid))
        }
        res.put("fingerprintIds", fpIdArr)
        // 0.39.55：**未命中也要落档**——否则"这条错误没人认识"这件事不留痕，下个样本又从零开始。
        // 只在 items 为空时记；同签名累加次数，攒到阈值就提示"该补指纹"。
        var missInfo = JsonObject()
        if (items.size == 0) {
            let sig = missSignatureOf(logText)
            if (sig.size > 0) {
                let projDir = argStr(args, "path", ".")
                let missRec = recordDiagnoseMiss(projDir, sig, logText)
                missInfo.put("missed", JsonBool(true))
                missInfo.put("missSig", JsonString(sig))
                missInfo.put("missCount", JsonInt(missRec[0]))
                missInfo.put("missHint", JsonString(missCandidateHint(missRec[0])))
                missInfo.put("missLedger", JsonString(missRec[1]))
            }
        }
        let proposals = patchProposalsFromDiagnosis(items)
        let rounds = argInt(args, "rounds", 0)
        let sameFails = argInt(args, "sameFingerprintFails", 0)
        let gates = checkGates(proposals, Int64(rounds), Int64(sameFails))

        var proposalsArr = JsonArray()
        for (p in proposals) {
            var o = JsonObject()
            o.put("file", JsonString(p.file))
            o.put("ruleId", JsonString(""))
            o.put("fingerprintId", JsonString(p.fingerprintId))
            proposalsArr.add(o)
        }

        res.put("ok", JsonBool(true))
        // 未命中攒候选（0.39.55）：missed / missSig / missCount / missHint / missLedger
        for ((k, v) in missInfo.getFields()) {
            res.put(k, v)
        }
        let dj = diagnosisJson(items)
        res.put("diagnosis", dj)
        res.put("proposals", proposalsArr)
        res.put("gates", gates.toJson())
        // rule 档命中 → 建议直接重跑 t2h:port（幂等修）；无命中 → 走 LLM 长尾（对话通道）
        let suggest = dj.get("suggestRerunPort")
        res.put("suggestRerunPort", suggest.getOrThrow())
        eprintln("[lingqu][diagnose] 命中=${dj.get("total").toString()} gates.passed=${gates.passed}")
        return res
    }
}

/**
 * t2h:pr_prepare —— 飞轮阶段 2：把候选经验整理成"人只点提交"的草稿 PR 产物。
 * 产物落 `<工程>/.lingqu/pr/<工程>/`（pr-body.md / pitfalls-suggestion.md / branch.txt），
 * **不碰 skills/ 本体**——合并仍要人/CI（飞轮 §8 的"永远不做"清单）。
 * token 只认环境变量 LINGQU_GITCODE_TOKEN：有则 canSubmit，无则退化本地产物（degraded），
 * **绝不读取/写回 settings.json**（密钥在 auth.json，也不碰）。
 */
public class PrPrepareCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        if (path.size == 0) {
            path = "."
        }
        let projName = sanitizeFileName(projectNameOf(path))
        // 0.39.118：凭据**多源**探测（LINGQU_GITCODE_TOKEN / GITCODE_TOKEN / ATOMGIT_TOKEN / GH_TOKEN），
        // 并把"从哪来 / 怎么开"一起回投——只认单一变量的做法会把"能不能发 PR"变成个人自觉。
        let auth = resolveSubmitAuth()
        let r = preparePr(path, projName, auth.token)
        var res = r.toJson()
        res.put("tokenSource", JsonString(auth.source))
        res.put("tokenAvailable", JsonBool(auth.available))
        res.put("ok", JsonBool(r.outError == ""))
        res.put("project", JsonString(projName))
        if (r.outError != "") {
            res.put("error", JsonString(r.outError))
            eprintln("[lingqu][pr_prepare] ${projName}: 落盘失败 ${r.outError}")
        } else {
            eprintln("[lingqu][pr_prepare] ${projName}: prepared=${r.prepared} canSubmit=${r.canSubmit}")
        }
        return res
    }
}

// ============================================================
// 业务装配点
// ============================================================

/**
 * 定位工程的 src-tauri/Cargo.toml（没有就退回工程根 Cargo.toml）。
 * 两个都不存在时返回 ""（由命令层给 outError，D-013 不静默）。
 */
func cargoTomlPathOf(projectDir: String): String {
    let a = projectDir + "/src-tauri/Cargo.toml"
    let b = projectDir + "/Cargo.toml"
    if (exists(Path(a))) {
        return a
    }
    if (exists(Path(b))) {
        return b
    }
    return ""
}

/** 宿主平台判定（工具链 channel 二选一用；@When 编译期门禁，镜像 cj-tauri host 层写法） */
@When[os == "Windows"]
func hostIsWindows(): Bool {
    return true
}
@When[os != "Windows"]
func hostIsWindows(): Bool {
    return false
}

/**
 * t2h:port —— 规则改造（P4：Cargo.toml 六条 + 工具链两条 + lib.rs 注入 + 前端兼容层）。
 *   dryRun=true（默认）：只算不动文件，返回逐条 outcome；Cargo.toml 预览落 preview 文件
 *   apply=true：每个被改文件先备份到 .lingqu/port/<工程>/<文件名>.bak 再落盘
 * 幂等：已迁移的工程再跑，全部 applied=false。
 * 分档（T4-8）：auto=规则机械完成；guide=给方案留人工（confirm/prompt、type=color），
 * guide 计数进人工介入（验收 A3 ≤5 口径）。
 */
/**
 * R2-PORT-017（0.39.114）：桥是不是**两侧都在**（Rust `call_arkts("x")` + ArkTS `case "x"`）。
 *
 * 实测动机（§4-162）：把 `rfd::FileDialog` / `explorer` 这类原生能力换成桥以后，Rust 分支调了
 * `call_arkts("pickFile")`，而 ArkTS 分发器里没有那一支——`cargo build`（含 ohos target）
 * 照样 exit=0、`verify` 判 pass，**真机点了毫无反应**（`cargo` 不审 ArkTS，只有 hvigor 审）。
 *
 * 为什么只报不写：补 ArkTS 那一半要读业务语义（选什么、回什么、uri 怎么落地），机械改写会把
 * 桥写坏。所以 tier=guide，把"缺哪个 cmd、该去哪个文件"说清，让 agent 自己动手（D-015）。
 */
func bridgeSidesOutcome(projPath: String, srcTauriDir: String): RuleOutcome {
    var o = RuleOutcome("R2-PORT-017", false, "", "", "")
    o.tier = T_GUIDE
    let srcDir = "${srcTauriDir}/src"
    if (!exists(Path(srcDir))) {
        o.note = "没有 ${srcDir}——跳过"
        return o
    }
    let rsFiles = ArrayList<String>()
    collectRsFilesUnder(srcDir, 6, rsFiles)
    var rustText = ""
    for (f in rsFiles) {
        try {
            rustText += lenientUtf8(File.readFrom(f)) + "\n"
        } catch (e: Exception) {
            let _ = e
        }
    }
    let cmds = rustBridgeCmdsOf(rustText)
    if (cmds.size == 0) {
        o.note = "没有 Rust 侧桥调用（call_arkts / \"cmd\": ...）——这个工程不经过 ArkTS 桥"
        return o
    }
    let ets = readArktsDispatcherOf(projPath)
    let missing = missingBridgeCmdsOf(rustText, ets)
    if (missing.size == 0) {
        o.note = "桥两侧都在（${cmds.size} 个 cmd）"
        return o
    }
    var miss = ""
    for (i in 0..missing.size) {
        if (i > 0) {
            miss += "、"
        }
        miss += "\"${missing[i]}\""
    }
    o.note = if (ets == "") {
        "Rust 侧有 ${cmds.size} 个桥 cmd，但工程里找不到 ArkTS 分发器（没有含 __ohos_dispatch 的 .ets）：" +
            "${miss} 到真机上不会有反应。先确认 gen/ohos 已生成，再补 __ohos_dispatch 分发"
    } else {
        "桥只写了一半：Rust 侧发了 ${miss}，但 ArkTS 分发器里没有对应分支——cargo 不审 ArkTS，" +
            "这会一路绿灯到真机才发现点了没反应。补 ArkTS 的 case / parsed.cmd 分支" +
            "（按 uri 语义落盘，别直接拿路径读写）"
    }
    return o
}

/** 限深收集 `.rs`（桥调用只在 src 下，跳过 target 这类大目录） */
func collectRsFilesUnder(dir: String, depth: Int64, out: ArrayList<String>): Unit {
    if (depth <= 0 || !exists(Path(dir))) {
        return
    }
    var infos: Array<FileInfo> = []
    try {
        infos = Directory.readFrom(dir)
    } catch (e: Exception) {
        let _ = e
        return
    }
    for (info in infos) {
        let nm = info.name
        if (nm == "target" || nm == ".git" || nm == "node_modules") {
            continue
        }
        let full = dir + cjhPathSep() + nm
        if (info.isDirectory()) {
            collectRsFilesUnder(full, depth - 1, out)
        } else if (nm.size > 3 && nm[(nm.size - 3)..nm.size] == ".rs") {
            out.add(full)
        }
    }
}

public class PortCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        var res = JsonObject()
        if (path.size == 0) {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("t2h:port 需要参数 path（或设环境变量 LINGQU_SCAN_PATH）"))
            return res
        }
        // ---- action=load（0.39.114）：只回读 decisions.json 的 portRun 摘要 ----
        // 纯读盘：不扫描、不改文件、不写盘。回读通道与重跑必须分开，
        // 否则屏上的数与落档里的数成了两份互不相干的（§4-138）。
        if (argStr(args, "action", "") == "load") {
            return portRecordResponse(path)
        }
        let badPortPath = projectPathRejectReason(path)
        if (badPortPath != "") {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString(badPortPath))
            return res
        }
        let tomlPath = cargoTomlPathOf(path)
        if (tomlPath == "") {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("未找到 Cargo.toml（找过 ${path}/src-tauri/Cargo.toml 与 ${path}/Cargo.toml）"))
            return res
        }
        let srcTauriDir = if (tomlPath.endsWith("/Cargo.toml")) {
            tomlPath[0..(tomlPath.size - "/Cargo.toml".size)]
        } else {
            path
        }

        var before = ""
        try {
            before = lenientUtf8(File.readFrom(tomlPath))
        } catch (e: Exception) {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("读 ${tomlPath} 失败：${e}"))
            return res
        }

        let apply = argBool(args, "apply", false)
        let result = applyCargoTomlRules(before)

        // ---- P4 第二刀：工具链（T4-3）+ lib.rs 注入（T4-4）+ 前端兼容层（T4-5）----
        var sdkNative = envOr("NATIVE_OHOS_SDK", "")
        let toolchain = toolchainOutcomes(srcTauriDir, sdkNative, hostIsWindows())
        let libRs = "${srcTauriDir}/src/lib.rs"
        var libOutcome = libRsOutcome(libRs)
        if (!exists(Path(libRs))) {
            // 单 bin 工程：退回 main.rs
            libOutcome = libRsOutcome("${srcTauriDir}/src/main.rs")
        }
        for (o in toolchain) {
            result.outcomes.add(o)
        }
        result.outcomes.add(libOutcome)
        let libPath = if (exists(Path(libRs))) { libRs } else { "${srcTauriDir}/src/main.rs" }
        result.outcomes.add(setupWiringOutcome(libPath))
        var frontendDist = ""
        let confPath = "${srcTauriDir}/tauri.conf.json"
        if (exists(Path(confPath))) {
            try {
                frontendDist = jsonStringFieldOf(lenientUtf8(File.readFrom(confPath)), "frontendDist")
            } catch (e: Exception) {
                frontendDist = ""
            }
        }
        let frontend = frontendDirOf(path, srcTauriDir, frontendDist)
        result.outcomes.add(localStorageOutcome("${frontend}/index.html"))
        let dialogAssets = dialogAssetsOutcome(frontend)
        for (d in dialogAssets) {
            result.outcomes.add(d)
        }
        let guides = frontendGuideOutcomes(frontend)
        for (g in guides) {
            result.outcomes.add(g)
        }
        // R2-PORT-015（0.39.53）：hvigorfile.ts 里的 tauri Rust 钩子会 panic（hvigor 00308018）——
        // 本工具的 t2h:hap 自己装配 .so，不需要它，命中就注掉（有备份、可回滚、幂等）
        result.outcomes.add(hvigorHookOutcome("${srcTauriDir}/gen/ohos/entry/hvigorfile.ts"))
        // 桥的双侧检测（0.39.114）：只报不写，见 bridgeSidesOutcome 的注释
        result.outcomes.add(bridgeSidesOutcome(path, srcTauriDir))
        // 未设 SDK 路径时 008 没法生成可用链接器配置——降级为提示（不写坏文件）
        if (sdkNative.size == 0) {
            for (o in result.outcomes) {
                if (o.id == "R2-PORT-008") {
                    o.applied = false
                    o.tier = T_GUIDE
                    // 不写盘（applied=false），但这是**必须人填**的一项 → 计入 A3 人工介入
                    o.needsHuman = true
                    o.note = "未设 NATIVE_OHOS_SDK 环境变量——链接器路径留人工填写（模板见 after）"
                }
            }
        }
        var name = projectNameOf(path)
        if (name.size == 0) {
            name = "project"
        }
        let safeName = sanitizeFileName(name)

        var backupPath = ""
        var outErr = ""
        if (apply) {
            // 逐文件备份 + 落盘：Cargo.toml / rust-toolchain.toml / .cargo/config.toml / lib.rs / index.html
            try {
                ensurePortDirs(lqDirOf(path) + cjhPathSep() + "port")
                backupPath = portBackupDirOf(path, safeName)
                // 每个工程的备份目录要**自己建**：ensurePortDirs 只建到 `.lingqu/port`。
                // 0.36.0 一键迁移实跑暴露了这个洞——只有先记过人工决策（DecisionsCommand 会建
                // `<safeName>/`）才恰好能备份；新工程第一次 apply 会直接抛
                // `The input path 'parent' '.lingqu/port/<工程>' does not exist`。
                if (!exists(Path(backupPath))) {
                    Directory.create(Path(backupPath))
                }
                var wroteAny = false
                if (result.appliedCount() > 0) {
                    // 备份只在**不存在**时写：二次 apply 时工程里已是迁移后的文件，
                    // 若照样覆盖，备份里存的就是迁移态——revert 只会"回滚"成迁移态（0.39.79 实测）。
                    backupFile(tomlPath, "${backupPath}/${BAK_CARGO}")
                    File.writeTo(tomlPath, result.afterText.toArray())
                    wroteAny = true
                }
                for (o in result.outcomes) {
                    if (o.id == "R2-PORT-007" && o.applied) {
                        let p = "${srcTauriDir}/rust-toolchain.toml"
                        backupFile(p, "${backupPath}/${BAK_TOOLCHAIN}")
                        File.writeTo(p, o.after.toArray())
                        wroteAny = true
                    }
                    if (o.id == "R2-PORT-008" && o.applied) {
                        let dir = "${srcTauriDir}/.cargo"
                        if (!exists(Path(dir))) {
                            Directory.create(Path(dir))
                        }
                        let p = "${dir}/config.toml"
                        backupFile(p, "${backupPath}/${BAK_CARGO_CONFIG}")
                        File.writeTo(p, o.after.toArray())
                        wroteAny = true
                    }
                    if (o.id == "R2-PORT-009" && o.applied) {
                        let p = if (exists(Path("${srcTauriDir}/src/lib.rs"))) { "${srcTauriDir}/src/lib.rs" } else { "${srcTauriDir}/src/main.rs" }
                        backupFile(p, "${backupPath}/${BAK_LIBRS}")
                        let old = lenientUtf8(File.readFrom(p))
                        File.writeTo(p, (old + o.after).toArray())
                        wroteAny = true
                    }
                    if (o.id == "R2-PORT-010" && o.applied) {
                        // 与 009 同一文件：009 先追加函数定义，010 再在 setup 块内接线
                        let p = if (exists(Path("${srcTauriDir}/src/lib.rs"))) { "${srcTauriDir}/src/lib.rs" } else { "${srcTauriDir}/src/main.rs" }
                        backupFile(p, "${backupPath}/${BAK_LIBRS}")
                        let old = lenientUtf8(File.readFrom(p))
                        File.writeTo(p, applySetupWiring(old).toArray())
                        wroteAny = true
                    }
                    if (o.id == "R2-PORT-015" && o.applied) {
                        // hvigorfile.ts：备份原文件 → 整份写回（注掉 tauri 钩子的版本）
                        let p = "${srcTauriDir}/gen/ohos/entry/hvigorfile.ts"
                        if (exists(Path(p)) && o.after != "") {
                            backupFile(p, "${backupPath}/${BAK_HVIGORFILE}")
                            File.writeTo(p, o.after.toArray())
                            wroteAny = true
                        }
                    }
                    if (o.id == "R2-PORT-014" && o.applied) {
                        let jsPath = "${frontend}/lingqu-dialog.js"
                        let cssPath = "${frontend}/lingqu-dialog.css"
                        if (!exists(Path(jsPath))) {
                            File.writeTo(jsPath, dialogJsContent().toArray())
                            wroteAny = true
                        }
                        if (!exists(Path(cssPath))) {
                            File.writeTo(cssPath, dialogCssContent().toArray())
                            wroteAny = true
                        }
                    }
                    if (o.id == "R2-PORT-011" && o.applied) {
                        let p = "${frontend}/index.html"
                        backupFile(p, "${backupPath}/${BAK_INDEX}")
                        let old = lenientUtf8(File.readFrom(p))
                        // 注到 <head> 之后（业务 script 之前）——habit-tree 同位置
                        let headEnd = indexOfOr(old, "</head>")
                        var newText = old
                        if (headEnd >= 0) {
                            let at = headEnd + "</head>".size
                            newText = old[0..at] + "\n" + o.after + old[at..]
                        } else {
                            newText = o.after + old
                        }
                        File.writeTo(p, newText.toArray())
                        wroteAny = true
                    }
                }
                if (!wroteAny) {
                    eprintln("[lingqu][port] apply 但无可写改动（工程可能已迁移）")
                }
            } catch (e: Exception) {
                outErr = "${e}"
                eprintln("[lingqu][port] 落盘失败（已备份的原文件未动）：${e}")
            }
        } else if (result.appliedCount() > 0) {
            // dry-run 也落一份预览：UI 的 diff 预览与实测对照都要用（可断言、可复核）
            try {
                ensurePortDirs(lqDirOf(path) + cjhPathSep() + "port")
                File.writeTo(lqDirOf(path) + cjhPathSep() + "port" + cjhPathSep() + "${safeName}-Cargo.toml.preview", result.afterText.toArray())
            } catch (e: Exception) {
                eprintln("[lingqu][port] 预览落档失败：${e}")
            }
        }

        // 落 decisions.json（0.39.81）：以前**只有记过一条人工决策**才会生成它，于是
        // "这个工程跑过 port 没有"在断点板与 agent 上下文里无从判断（§4-58 的窟窿）。
        // 现在每次跑完都把本轮摘要写进去，`items` 保持原样（不抹人工决策）。
        try {
            let decDir = portBackupDirOf(path, safeName)
            ensureDirOf(decDir)
            let decFile = "${decDir}/decisions.json"
            var runOutcomes = ArrayList<String>()
            for (o in result.outcomes) {
                var line = "${o.id} ${if (o.applied) { "applied" } else { o.tier }}"
                if (o.note.size > 0) {
                    line += " | ${o.note}"
                }
                runOutcomes.add(line)
            }
            let atMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
            let decText = decisionsJsonWithPortRun(readTextOrEmpty(decFile), safeName, apply,
                result.appliedCount(), result.autoCount(), result.humanCount(), atMs, runOutcomes)
            File.writeTo(decFile, decText.toArray())
        } catch (e: Exception) {
            // 证据没落地必须能被发现（D-013）：只打日志等于没有（§4-14）
            if (outErr.size == 0) {
                outErr = "decisions.json 落盘失败：${e}"
            }
        }

        res.put("ok", JsonBool(outErr == ""))
        res.put("toml", JsonString(tomlPath))
        res.put("apply", JsonBool(apply))
        res.put("applied", JsonInt(result.appliedCount()))
        res.put("counters", result.countersJson())
        res.put("idempotent", JsonBool(isIdempotent(result)))
        res.put("rules", result.outcomesJson())
        res.put("afterPreview", JsonString(result.afterText))
        res.put("backup", JsonString(backupPath))
        res.put("outError", JsonString(outErr))
        eprintln("[lingqu][port] ${tomlPath}: applied=${result.appliedCount()} apply=${apply} counters=${result.countersJson().toJsonString()}")
        return res
    }
}

/**
 * 保证落档目录存在（0.38.0：跟着工程走，由调用方给工程根下的目录）。
 *
 * 以前是硬编码 `.lingqu/port`——只对 CWD 有效，agent 在工程里就看不见；
 * 现在统一按传入的目录建，拼法由 `lqDirOf/lqPathOf` 决定（见 src/workdir.cj）。
 */
func ensurePortDirs(dir: String): Unit {
    ensureDirOf(dir)
}

/**
 * 备份单文件（目标存在才备；**已有备份不再覆盖**）。
 *
 * 第二条是 0.39.81 修的：二次 apply 时源文件已是迁移后的内容，覆盖备份等于把
 * "原始状态"弄丢，revert 之后工程还是迁移态——回滚能力静默失效（§4-33 同族）。
 */
public func backupFile(src: String, dst: String): Unit {
    if (exists(Path(src)) && !exists(Path(dst))) {
        File.writeTo(dst, File.readFrom(src))
    }
}

/**
 * apply / revert 共用的备份目录（**绝对路径，跟着工程走**）。
 *
 * 0.39.81 修：revert 以前用 CWD 相对的 `.lingqu/port/<工程>`，而 apply 写的是
 * `<工程>/.lingqu/port/<工程>`——只要 CWD 不是该工程目录，回滚就永远"没有备份"。
 * 单点构造（产出方与消费方共用这一条），别再各拼一份（§4-33）。
 */
public func portBackupDirOf(projectDir: String, safeName: String): String {
    return lqDirOf(projectDir) + cjhPathSep() + "port" + cjhPathSep() + safeName
}

/**
 * t2h:revert —— 回滚 t2h:port 的落盘改动（T4-6 的另一半）。
 *
 * 0.13.1 修：apply 从 0.11.0 起把备份改到 `.lingqu/port/<工程>/<文件名>.bak`（逐文件），
 * 而这里仍在找旧的单文件 `.lingqu/port/<工程>-Cargo.toml.bak`——**回滚从 0.11.0 起
 * 一直是坏的**（永远报"没有备份可回滚"）。现在按 `revertPairs()` 全表逐文件回滚
 * （Cargo.toml / rust-toolchain.toml / .cargo/config.toml / lib.rs / index.html），
 * 并清掉 014 生成的 lingqu-dialog.js/.css（带 lingqu 标记才算工具产物，不误删用户的）；
 * 旧路径备份仍兼容（只回滚 Cargo.toml 并在 note 里说明）。
 */
public class RevertCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        var res = JsonObject()
        if (path.size == 0) {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("t2h:revert 需要参数 path"))
            return res
        }
        var name = projectNameOf(path)
        if (name.size == 0) {
            name = "project"
        }
        let safeName = sanitizeFileName(name)
        let dir = portBackupDirOf(path, safeName)
        let legacy = legacyCargoBakOf(safeName)
        let tomlPath = cargoTomlPathOf(path)

        var restored = JsonArray()
        var skipped = JsonArray()
        var removed = JsonArray()
        var errMsg = ""
        var usedLegacy = false

        if (exists(Path(dir))) {
            // src 目录 = 含 Cargo.toml 的那层：传统工程是 src-tauri/，扁平工程就是工程根。
            // 回滚表用 REL_SRC / REL_PROJECT 标记，这里按实际布局解析（0.39.81：不再硬编码 src-tauri/）
            var revSrcDir = ""
            if (tomlPath != "") {
                revSrcDir = tomlPath[0..(tomlPath.size - "/Cargo.toml".size)]
            }
            // 工程目录：按表逐文件回滚
            for (pair in revertPairs()) {
                let bak = "${dir}/${pair.backupFile}"
                if (!exists(Path(bak))) {
                    continue
                }
                // 目标路径：Cargo.toml 用解析结果，其余按布局标记解析；lib.rs 单 bin 工程退回 main.rs
                var target = resolveRevertTarget(pair.relTarget, path, revSrcDir, tomlPath)
                if (pair.backupFile == BAK_LIBRS && (target == "" || !exists(Path(target)))) {
                    target = if (revSrcDir.size > 0) { "${revSrcDir}/src/main.rs" } else { "" }
                }
                if (target == "") {
                    skipped.add(JsonString(pair.backupFile))
                    continue
                }
                try {
                    let bakText = lenientUtf8(File.readFrom(bak))
                    File.writeTo(target, bakText.toArray())
                    restored.add(JsonString(target))
                } catch (e: Exception) {
                    errMsg = "回滚 ${target} 失败：${e}"
                }
            }
            // 014 生成的前端资源：带 lingqu 标记才算工具产物，删掉才算"回到干净仓库"
            // 路径口径必须与写入侧（frontendDirOf）一致，否则回滚永远删不到；
            // 同时看工程根——历史版本曾写到 `<工程>/`（扁平工程 frontendDist 读不到时的退路）。
            var frontendForRevert = path
            if (tomlPath != "") {
                let revSrc = tomlPath[0..(tomlPath.size - "/Cargo.toml".size)]
                var revDist = ""
                let revConf = "${revSrc}/tauri.conf.json"
                if (exists(Path(revConf))) {
                    try {
                        revDist = jsonStringFieldOf(lenientUtf8(File.readFrom(revConf)), "frontendDist")
                    } catch (e: Exception) {
                        revDist = ""
                    }
                }
                frontendForRevert = frontendDirOf(path, revSrc, revDist)
            }
            for (f in ["lingqu-dialog.js", "lingqu-dialog.css"]) {
                for (dir in [frontendForRevert, path]) {
                    let p = "${dir}/${f}"
                    if (fileContains(p, "lingqu: R2-PORT-014")) {
                        try {
                            remove(Path(p))
                            removed.add(JsonString(p))
                        } catch (e: Exception) {
                            errMsg = "删除 ${p} 失败：${e}"
                        }
                    }
                }
            }
        } else if (exists(Path(legacy))) {
            // 兼容 0.10.0 的旧单文件备份
            usedLegacy = true
            if (tomlPath == "") {
                res.put("ok", JsonBool(false))
                res.put("error", JsonString("找不到要回滚的 Cargo.toml（工程路径变了？）"))
                return res
            }
            try {
                let bak = lenientUtf8(File.readFrom(legacy))
                File.writeTo(tomlPath, bak.toArray())
                restored.add(JsonString(tomlPath))
            } catch (e: Exception) {
                errMsg = "回滚 ${tomlPath} 失败：${e}"
            }
        } else {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("没有备份可回滚：找过 ${dir}/ 与 ${legacy}（先跑 apply=true 的 t2h:port）"))
            return res
        }

        let okFlag = errMsg == "" && restored.size() > 0
        res.put("ok", JsonBool(okFlag))
        res.put("restored", restored)
        res.put("removed", removed)
        res.put("skipped", skipped)
        res.put("backup", JsonString(if (usedLegacy) { legacy } else { dir }))
        res.put("legacy", JsonBool(usedLegacy))
        if (errMsg != "") {
            res.put("error", JsonString(errMsg))
        }
        eprintln("[lingqu][revert] ${safeName}: restored=${restored.size()} removed=${removed.size()} legacy=${usedLegacy} err=${errMsg}")
        return res
    }
}

/**
 * t2h:deps —— Cargo 依赖树 OHOS 兼容性扫描（P3）。
 * 数据源：src-tauri/Cargo.lock（整树）+ Cargo.toml 的 [patch.*] 段（fork 是否已落）。
 * 结果落 `.lingqu/deps/<工程名>.json`（lingqu/deps/v1），失败原因进 outError（D-013）。
 */
public class DepsCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        var res = JsonObject()
        if (path.size == 0) {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("t2h:deps 需要参数 path（或设环境变量 LINGQU_SCAN_PATH）"))
            return res
        }
        let badDepsPath = projectPathRejectReason(path)
        if (badDepsPath != "") {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString(badDepsPath))
            return res
        }

        // ---- action=load（0.39.87）：只回读依赖矩阵落档，不重跑 ----
        if (argStr(args, "action", "") == "load") {
            return depsRecordResponse(path)
        }

        var name = projectNameOf(path)
        if (name.size == 0) {
            name = "project"
        }
        name = sanitizeFileName(name)

        let deps = depsScanJson(path)

        // 读盘失败不静默：outError 原样透传，落档跳过
        // （口径与 baseline.cj 的 jsonStrOf 同款：match v.kind() 再 asString().getValue()）
        var errText = ""
        match (deps.get("outError")) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => errText = v.asString().getValue()
                case _ => ()
            }
            case None => ()
        }

        var wrote = false
        var outErr = ""
        if (errText.size == 0) {
            // 落档跟着工程走（0.38.0）
            let outDir = lqDirOf(path) + cjhPathSep() + "deps"
            let outFile = outDir + cjhPathSep() + name + ".json"
            try {
                ensureDirOf(outDir)
                File.writeTo(outFile, deps.toJsonString().toArray())
                wrote = true
                eprintln("[lingqu][deps] ${name}: 落档 ${outFile}")
            } catch (e: Exception) {
                outErr = "${e}"
                eprintln("[lingqu][deps] 写依赖矩阵失败：${e}")
            }
        } else {
            eprintln("[lingqu][deps] ${name}: ${errText}")
        }

        res.put("ok", JsonBool(errText.size == 0))
        res.put("project", JsonString(name))
        res.put("out", JsonString(if (wrote) { lqPathOf(path, "deps/${name}.json") } else { "" }))
        res.put("outError", JsonString(outErr))
        res.put("error", JsonString(errText))
        res.put("deps", deps)
        return res
    }
}

// ============================================================
// ④ 界面自检（t2h:ui_report）：让界面自己报版面指标
// ============================================================

/**
 * 页面在首次渲染完成后把版面指标回投后端，后端只做一件事：写一行结构化日志。
 *
 * 为什么需要它：GUI「对不对」习惯靠肉眼，而肉眼不可自动化——CI 里、
 * 以及 AI 助手没有视觉能力时，都无法判断「三栏布局还在不在、折叠有没有生效」。
 * 这条命令把版面变成可断言的数字：视口尺寸、grid 列宽、当前屏、屏数、id 数、JS 错误数。
 *
 * 落盘要加锁：命令会被多个前端定时器与页签切换并发调用，而落盘是
 * 「读全文 → 拼一行 → 覆盖写」——不加锁时两个写者会互相截断内容。2026-10-30 实测把
 * 某条快照写成只剩 `6902039 }` 的碎片，整份自检序列因此不可判定。
 */
/** ui_report 落盘互斥锁（见 UiReportCommand 头注释：并发写会互相截断） */
let gUiReportLock = Mutex()

public class UiReportCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var o = JsonObject()
        o.put("width", JsonInt(argInt(args, "width", 0)))
        o.put("height", JsonInt(argInt(args, "height", 0)))
        o.put("gridColumns", JsonString(argStr(args, "gridColumns", "?")))
        o.put("screens", JsonInt(argInt(args, "screens", 0)))
        o.put("activeScreen", JsonString(argStr(args, "activeScreen", "?")))
        o.put("aiHidden", JsonBool(argBool(args, "aiHidden", false)))
        o.put("idCount", JsonInt(argInt(args, "idCount", 0)))
        o.put("settingsOpen", JsonBool(argBool(args, "settingsOpen", false)))
        o.put("modelItems", JsonInt(argInt(args, "modelItems", 0)))
        o.put("modelError", JsonString(argStr(args, "modelError", "")))
        o.put("wsState", JsonString(argStr(args, "wsState", "unknown")))
        // 轮次预算用完后的自动续跑次数（0.39.82）：用户报"62/40 又做一半停了"，
        // 这一项直接说明有没有走到续跑、续了几次（0 = 没触发）；白名单不加等于报告里查不到（§4-60）。
        o.put("autoContinue", JsonInt(argInt(args, "autoContinue", 0)))
        // 登录入口证据（0.39.82）：卡片状态 + 登录页 URL（有值说明"可点链接"真的给到了界面）
        o.put("signLoginState", JsonString(argStr(args, "signLoginState", "")))
        o.put("signLoginUrl", JsonString(argStr(args, "signLoginUrl", "")))
        // 「导出移植成果」按钮的读数（0.39.139）：按钮以前没有任何可断言字段，点完只有一行 pill。
        // 白名单不加等于报告里查不到（§4-60：前端与这里必须两处一起加）。
        o.put("exportOk", JsonBool(argBool(args, "exportOk", false)))
        o.put("exportTries", JsonInt(argInt(args, "exportTries", 0)))
        o.put("exportFiles", JsonInt(argInt(args, "exportFiles", 0)))
        o.put("exportBytes", JsonInt(argInt(args, "exportBytes", 0)))
        o.put("exportDir", JsonString(argStr(args, "exportDir", "")))
        o.put("exportErr", JsonString(argStr(args, "exportErr", "")))
        // 对话通道连不上的原话（0.39.65）：用户实测"网页能打开 8765，软件却说未连接"，
        // 而报告里只有 connected/closed 两态、拿不到原因 —— 加这三项才排得动。
        o.put("wsErr", JsonString(argStr(args, "wsErr", "")))
        o.put("wsConnectTries", JsonInt(argInt(args, "wsConnectTries", 0)))
        o.put("wsConnectMs", JsonInt(argInt(args, "wsConnectMs", -1)))
        // 引擎发现证据：state（running/ready/missing）+ 实际用的二进制 + 查过的 vendor 目录
        o.put("cjhState", JsonString(argStr(args, "cjhState", "")))
        o.put("cjhBin", JsonString(argStr(args, "cjhBin", "")))
        o.put("cjhVendorDir", JsonString(argStr(args, "cjhVendorDir", "")))
        o.put("cjhHome", JsonString(argStr(args, "cjhHome", "")))
        // 引擎状态诊断（0.39.45）：说清"为什么判成缺失"——端口 / 最近失败原因 / 多久没成功 / 二进制可读性
        o.put("cjhDiag", JsonString(argStr(args, "cjhDiag", "")))
        // 状态查询失败（0.39.45）：IPC 失败 ≠ 引擎缺失。fail 是累计次数，last 是最近一次的报错文本
        o.put("cjhPollFail", JsonInt(argInt(args, "cjhPollFail", -1)))
        o.put("cjhPollLast", JsonString(argStr(args, "cjhPollLast", "")))
        // 提示卡节点是否还在（0.39.45）：被清屏冲掉会让状态渲染整段抛异常
        o.put("aiHintOk", JsonInt(argInt(args, "aiHintOk", 0)))
        // 设置面板回读值（0.39.46）："界面上到底显示了什么"，与 cjh /api/settings 的真值对账
        o.put("settingsDump", JsonString(argStr(args, "settingsDump", "")))
        // 测试连通（0.39.62）：页面用表单值真发一条最小对话来验"模型名/地址/密钥"通不通，
        // 结果必须能被自动断言——否则等于给用户一个"点了不知道成没成"的按钮（§1-6 界面可断言）。
        o.put("settingsProbe", JsonString(argStr(args, "settingsProbe", "")))
        o.put("settingsProbeMs", JsonInt(argInt(args, "settingsProbeMs", -1)))
        o.put("settingsProbeNote", JsonString(argStr(args, "settingsProbeNote", "")))
        o.put("settingsProbeFrames", JsonInt(argInt(args, "settingsProbeFrames", 0)))
        // 候选模型清单已删（0.39.62）：空清单不是错误，也不再拿清单当校验
        o.put("settingsModelEmpty", JsonInt(argInt(args, "settingsModelEmpty", 0)))
        // 接入协议（0.39.62）：表单里选中的值 vs 配置文件里读回的值——两者不一致就是"改了还没重启"
        o.put("settingsProto", JsonString(argStr(args, "settingsProto", "")))
        o.put("settingsProtoSaved", JsonString(argStr(args, "settingsProtoSaved", "")))
        // ⚙ 按钮走的那条作用域桥是否就绪（0.39.62：外层作用域直接调内层函数会静默抛错）
        o.put("settingsOpenBridge", JsonInt(argInt(args, "settingsOpenBridge", 0)))
        o.put("frames", JsonInt(argInt(args, "frames", 0)))
        o.put("toolCards", JsonInt(argInt(args, "toolCards", 0)))
        // 工具卡片折叠证据（0.39.37）：open=当前展开几张（成功调用应 0，失败自动展开），
        // chars=这轮工具输出总字数（说明"输出体量"与"占用版面"已经解耦）
        o.put("toolCardsOpen", JsonInt(argInt(args, "toolCardsOpen", 0)))
        o.put("toolResultChars", JsonInt(argInt(args, "toolResultChars", 0)))
        // 引擎状态横跳证据（0.39.38）：seen=判掉 1 次但连接保住了；flaps=真的断了/关了
        o.put("statusFlapsSeen", JsonInt(argInt(args, "statusFlapsSeen", 0)))
        o.put("statusFlaps", JsonInt(argInt(args, "statusFlaps", 0)))
        o.put("sessionRetired", JsonString(argStr(args, "sessionRetired", "")))
        // 连接横跳判据的页内自检（0.39.38）：flapCases=断言条数，flapFail=失败明细（空=全过）
        o.put("flapCases", JsonInt(argInt(args, "flapCases", 0)))
        o.put("flapFail", JsonString(argStr(args, "flapFail", "")))        // WS 状态流水（0.39.38）：最近 8 条「谁动了连接」（conn / closed / close(原因)）
        o.put("wsEventText", JsonString(argStr(args, "wsEventText", "")))
        // 聊天窗宽度可拖动（0.39.39）：aiW=生效宽度、aiResizerOk=拖条可用、aiDrags=拖过几次
        o.put("aiW", JsonInt(argInt(args, "aiW", 0)))
        o.put("aiResizerOk", JsonBool(argBool(args, "aiResizerOk", false)))
        o.put("aiDrags", JsonInt(argInt(args, "aiDrags", 0)))
        // 隐藏控制台（0.39.40）：true = 本进程有一个不可见的 console，子进程不会再各自弹黑窗
        o.put("consoleHidden", JsonBool(gConsoleHidden))
        // 设备状态口径（0.39.40）：deviceInRecord=落档里核实到过真机（界面据此不再写"未连接"）
        o.put("deviceInRecord", JsonBool(argBool(args, "deviceInRecord", false)))
        // 设备文案自检（0.39.40）：migratePctText=那行字的实际内容，deviceFail=失败明细（空=全过）
        o.put("migratePctText", JsonString(argStr(args, "migratePctText", "")))
        o.put("deviceFail", JsonString(argStr(args, "deviceFail", "")))
        o.put("approvals", JsonInt(argInt(args, "approvals", 0)))
        o.put("lastFrameType", JsonString(argStr(args, "lastFrameType", "")))
        o.put("replyPreview", JsonString(argStr(args, "replyPreview", "")))
        // AI 回复的 Markdown 渲染自检（2026-11-01）：mdOk=页内自检全过；mdBlocks=版面里
        // 真正渲染出的块级元素数（表格/列表/代码块…）——没有视觉也能断言"不是一坨纯文本"
        o.put("mdOk", JsonBool(argBool(args, "mdOk", false)))
        o.put("mdFail", JsonString(argStr(args, "mdFail", "")))
        o.put("mdBlocks", JsonInt(argInt(args, "mdBlocks", 0)))
        o.put("mdCodeCopy", JsonInt(argInt(args, "mdCodeCopy", 0)))
        // 语法高亮（hljs）：版面里被切成词法 span 的数量（0 = 库在但没生效）
        o.put("mdHljs", JsonInt(argInt(args, "mdHljs", 0)))
        // 右栏版面量尺：气泡是否铺满可用宽度（aiBubbleGap 正常≈聊天区 padding 14px）
        o.put("aiDockW", JsonInt(argInt(args, "aiDockW", 0)))
        o.put("aiBubbleW", JsonInt(argInt(args, "aiBubbleW", 0)))
        o.put("aiBubbleGap", JsonInt(argInt(args, "aiBubbleGap", -1)))
        o.put("aiInnerLeft", JsonInt(argInt(args, "aiInnerLeft", -1)))
        o.put("aiLastHtml", JsonString(argStr(args, "aiLastHtml", "")))
        // 「平铺展开」：aiFlatLeft≈0（回复贴聊天区左边缘）、aiAvatarsShown=0（头像栏已隐藏）
        o.put("aiFlatLeft", JsonInt(argInt(args, "aiFlatLeft", -1)))
        o.put("aiAvatars", JsonInt(argInt(args, "aiAvatars", 0)))
        o.put("aiAvatarsShown", JsonInt(argInt(args, "aiAvatarsShown", 0)))
        // AI 迁移技能（2026-11-01）：装没装 / cjh 看没看见 / references 份数
        o.put("skillState", JsonString(argStr(args, "skillState", "")))
        o.put("skillPath", JsonString(argStr(args, "skillPath", "")))
        o.put("skillRefs", JsonInt(argInt(args, "skillRefs", 0)))
        o.put("skillCjhSeen", JsonBool(argBool(args, "skillCjhSeen", false)))
        o.put("skillCjhCount", JsonInt(argInt(args, "skillCjhCount", 0)))
        o.put("skillSource", JsonString(argStr(args, "skillSource", "")))
        o.put("skillNote", JsonString(argStr(args, "skillNote", "")))
        // 工程上下文（AGENTS.md 受管区块 + cjh workspace）
        o.put("agentHasBlock", JsonBool(argBool(args, "agentHasBlock", false)))
        o.put("agentPath", JsonString(argStr(args, "agentPath", "")))
        o.put("agentSwitched", JsonBool(argBool(args, "agentSwitched", false)))
        o.put("agentWorkspace", JsonString(argStr(args, "agentWorkspace", "")))
        o.put("agentError", JsonString(argStr(args, "agentError", "")))
        // ④ 一键执行（2026-11-01）：建议条数 / 最后执行的命令与退出码 / 被拦下次数
        o.put("cliSuggest", JsonInt(argInt(args, "cliSuggest", 0)))
        o.put("cliSuggestRows", JsonInt(argInt(args, "cliSuggestRows", 0)))
        o.put("cliLastCmd", JsonString(argStr(args, "cliLastCmd", "")))
        o.put("cliLastExit", JsonInt(argInt(args, "cliLastExit", -1)))
        o.put("cliLastOk", JsonBool(argBool(args, "cliLastOk", false)))
        o.put("cliRan", JsonInt(argInt(args, "cliRan", 0)))
        o.put("cliBlocked", JsonInt(argInt(args, "cliBlocked", 0)))
        o.put("cliResultCards", JsonInt(argInt(args, "cliResultCards", 0)))
        // G1+G2 失败自动诊断（0.36.0）：失败后是否**真的**把现场发给了模型
        // autoDiagChars=0 而 autoDiag=true 是自相矛盾的，断言时两条一起看
        o.put("autoDiag", JsonBool(argBool(args, "autoDiag", false)))
        o.put("autoDiagStep", JsonString(argStr(args, "autoDiagStep", "")))
        o.put("autoDiagAsked", JsonInt(argInt(args, "autoDiagAsked", 0)))
        o.put("autoDiagChars", JsonInt(argInt(args, "autoDiagChars", 0)))
        o.put("autoDiagNote", JsonString(argStr(args, "autoDiagNote", "")))
        // G3 自动执行只读命令：开关状态 / 自动跑了几条 / 被安全边界拦下几条
        o.put("autoRun", JsonBool(argBool(args, "autoRun", false)))
        o.put("autoRan", JsonInt(argInt(args, "autoRan", 0)))
        o.put("autoBlocked", JsonInt(argInt(args, "autoBlocked", 0)))
        // G4 决策回写：渲染出的确认卡数 / 已落档条数 / 最后一条摘要
        o.put("decideCards", JsonInt(argInt(args, "decideCards", 0)))
        o.put("decideRecorded", JsonInt(argInt(args, "decideRecorded", 0)))
        o.put("decideLast", JsonString(argStr(args, "decideLast", "")))
        // ⓪ 一键迁移（0.36.0）：进度 / 结论 / 时间轴行数 / 结果正文长度
        o.put("migrateRunning", JsonBool(argBool(args, "migrateRunning", false)))
        o.put("migratePercent", JsonInt(argInt(args, "migratePercent", 0)))
        o.put("migrateVerdict", JsonString(argStr(args, "migrateVerdict", "")))
        o.put("migrateRows", JsonInt(argInt(args, "migrateRows", 0)))
        o.put("migrateResultChars", JsonInt(argInt(args, "migrateResultChars", 0)))
        o.put("migrateReport", JsonString(argStr(args, "migrateReport", "")))
        // AI 自动迁移（0.37.0）：agent 在不在跑 / 轮询数 / 停滞 / 任务书字数 / 工具路径
        o.put("aiPortActive", JsonBool(argBool(args, "aiPortActive", false)))
        o.put("aiPortPolls", JsonInt(argInt(args, "aiPortPolls", 0)))
        o.put("aiPortStalled", JsonBool(argBool(args, "aiPortStalled", false)))
        // 自动迁移是否"全部有结论"（0.39.41）：界面据此不再喊"绕圈"
        o.put("aiPortFinished", JsonBool(argBool(args, "aiPortFinished", false)))
        o.put("aiPortVerdict", JsonString(argStr(args, "aiPortVerdict", "")))
        // 第三态「已交接」（0.39.88）：agent 自己收尾、计划没做完——断言 aiPortHandoff=1
        // 且 aiPortVerdict 里出现「已交接」，不再把"没人干活"显示成「进行中」
        o.put("aiPortHandoff", JsonBool(argBool(args, "aiPortHandoff", false)))
        o.put("aiPortTurnEnded", JsonBool(argBool(args, "aiPortTurnEnded", false)))
        // 左栏步骤徽标（0.39.41）：profile=通过 | deps=未开始 | …（写死的「待接入」已删）
        o.put("railBadges", JsonString(argStr(args, "railBadges", "")))
        o.put("railFail", JsonString(argStr(args, "railFail", "")))
        o.put("aiPortDirective", JsonInt(argInt(args, "aiPortDirective", 0)))
        o.put("aiPortCli", JsonString(argStr(args, "aiPortCli", "")))
        // R-1 提醒是否在展示（0.39.129）：flywheelHint 非空即提醒中（前端 reportUi 同名字段回投）
        o.put("flywheelHint", JsonString(argStr(args, "flywheelHint", "")))
        // 换工程清理（0.39.86）：用户实测「换了个新工程，AI 自动迁移还是上次执行完的状态、不能点」。
        // 断言口径：projSwitches>0 且 projResets==projSwitches（每次切换都清过）且 aiPortBtn=1（按钮恢复可点）。
        o.put("projSwitches", JsonInt(argInt(args, "projSwitches", 0)))
        o.put("projResets", JsonInt(argInt(args, "projResets", 0)))
        o.put("projResetActive", JsonInt(argInt(args, "projResetActive", 0)))
        o.put("aiPortBtn", JsonInt(argInt(args, "aiPortBtn", 0)))
        o.put("uiErrors", JsonString(argStr(args, "uiErrors", "")))
        // 换工程提示与落档实况（0.39.88）：用户实测「提示说『这里还没跑过』，左栏却写着已完成」。
        // kind: pending / has-record / empty / unknown；steps=新工程已做过几步（读 t2h:resume 的落档）
        o.put("switchNoteKind", JsonString(argStr(args, "switchNoteKind", "")))
        o.put("switchNoteSteps", JsonInt(argInt(args, "switchNoteSteps", 0)))
        o.put("switchNoteOk", JsonInt(argInt(args, "switchNoteOk", 0)))
        o.put("switchNoteFail", JsonString(argStr(args, "switchNoteFail", "")))
        // 换工程清理自检（LINGQU_UI_PROBE=projswitch）：1=通过；失败原因在 note（0.39.86）
        o.put("projSwitchOk", JsonInt(argInt(args, "projSwitchOk", 0)))
        o.put("projSwitchNote", JsonString(argStr(args, "projSwitchNote", "")))
        // 行为轨迹行数（0.39.0）
        o.put("agentTraceLines", JsonInt(argInt(args, "agentTraceLines", 0)))
        // WS 发送可观测（0.37.0）：发送失败数 / 最后一次失败原因 / 收到的帧类型计数
        o.put("wsSendFail", JsonInt(argInt(args, "wsSendFail", 0)))
        o.put("wsLastSendErr", JsonString(argStr(args, "wsLastSendErr", "")))
        // 出站帧体检（0.39.35）：为了定位 cjh 的 `ws_read_failed`（Invalid utf8 byte sequence）
        o.put("wsSendCount", JsonInt(argInt(args, "wsSendCount", 0)))
        o.put("wsLastSendBytes", JsonInt(argInt(args, "wsLastSendBytes", 0)))
        o.put("wsLastSendType", JsonString(argStr(args, "wsLastSendType", "")))
        o.put("wsLoneSurrogate", JsonInt(argInt(args, "wsLoneSurrogate", 0)))
        o.put("wsLastSendSanitized", JsonBool(argBool(args, "wsLastSendSanitized", false)))
        o.put("wsErrCodes", JsonString(argStr(args, "wsErrCodes", "")))
        o.put("wsLastErrCode", JsonString(argStr(args, "wsLastErrCode", "")))
        o.put("wsProbeSent", JsonInt(argInt(args, "wsProbeSent", 0)))
        o.put("wsProbeLastHint", JsonInt(argInt(args, "wsProbeLastHint", 0)))
        o.put("wsTruncated", JsonInt(argInt(args, "wsTruncated", 0)))
        o.put("wsFrameTypes", JsonString(argStr(args, "wsFrameTypes", "")))
        // 断线重连次数（0.39.5）：重连不设上限后，用它断言"页面真的在重连"
        o.put("wsReconnects", JsonInt(argInt(args, "wsReconnects", 0)))
        // 中止来源（0.39.8）：0.39.7 端到端跑出现"cjh 收到 interrupt 但查不到谁按的"，
        // 现在两处 abort 入口（停止按钮 / 对话面板中止）都标来源，随报告留痕
        o.put("abortSource", JsonString(argStr(args, "abortSource", "")))
        // 当前工程（0.39.8）：界面只有一个权威输入，其余 8 处是只读回显。
        // projectPromptCount 修好后必须为 1；stepPathOverride 非空说明某步用了别的工程。
        o.put("currentProject", JsonString(argStr(args, "currentProject", "")))
        // 启动带回上次工程（0.39.44）：saved＝localStorage 记着的当前工程 /
        // recent＝最近列表兜底 / none＝真没有（不造默认值）。restoreFail 为纯函数自检的失败项。
        o.put("projRestored", JsonString(argStr(args, "projRestored", "")))
        o.put("projRestorePath", JsonString(argStr(args, "projRestorePath", "")))
        o.put("restoreFail", JsonString(argStr(args, "restoreFail", "")))
        // 存储自检（0.39.44）："before|after|<读回值>|<抛错名>"——判定 localStorage 能否跨刷新持久化
        o.put("storeProbe", JsonString(argStr(args, "storeProbe", "")))
        o.put("projectPromptCount", JsonInt(argInt(args, "projectPromptCount", 0)))
        o.put("pathFieldCount", JsonInt(argInt(args, "pathFieldCount", 0)))
        o.put("stepPathOverride", JsonString(argStr(args, "stepPathOverride", "")))
        // 选工程的三条路（0.39.25）：手敲 / 原生目录框 / Git 克隆。
        // echoInputsEditable 必须为 0：8 个回显框默认全只读（界面上不许"到处都要填路径"）。
        o.put("echoInputsTotal", JsonInt(argInt(args, "echoInputsTotal", 0)))
        o.put("echoInputsEditable", JsonInt(argInt(args, "echoInputsEditable", 0)))
        o.put("echoInputsEchoStyled", JsonInt(argInt(args, "echoInputsEchoStyled", 0)))
        o.put("pickerUsed", JsonInt(argInt(args, "pickerUsed", 0)))
        o.put("pickerFallback", JsonInt(argInt(args, "pickerFallback", 0)))
        o.put("pickerLastPath", JsonString(argStr(args, "pickerLastPath", "")))
        o.put("clonePanelOpen", JsonBool(argBool(args, "clonePanelOpen", false)))
        o.put("cloneUrlFilled", JsonBool(argBool(args, "cloneUrlFilled", false)))
        // 顶栏版面（0.39.26）：titlebarOverflow 必须 false、projNoteLines 必须 1、topbarH 必须 48。
        // 这三条就是"非最大化窗口下顶部不折叠/不溢出"的自动判据（§4-60：两处一起加）。
        o.put("topbarH", JsonInt(argInt(args, "topbarH", 0)))
        o.put("titlebarOverflow", JsonBool(argBool(args, "titlebarOverflow", false)))
        o.put("projNoteLines", JsonInt(argInt(args, "projNoteLines", 0)))
        o.put("projNoteClipped", JsonBool(argBool(args, "projNoteClipped", false)))
        o.put("projNoteText", JsonString(argStr(args, "projNoteText", "")))
        o.put("projBarClipped", JsonBool(argBool(args, "projBarClipped", false)))
        // 顶栏「当前项目」胶囊（0.39.28）：它以前是写死的习惯用语（habit-tree · v1.2.0 · …），
        // 换了工程一个字都不变。现在只显示工程名 + 扫描状态，这两组字段让"换工程后胶囊跟着换"可断言。
        o.put("tbProjName", JsonString(argStr(args, "tbProjName", "")))
        o.put("tbProjMeta", JsonString(argStr(args, "tbProjMeta", "")))
        o.put("tbProjScanned", JsonInt(argInt(args, "tbProjScanned", 0)))
        o.put("tbProjStale", JsonInt(argInt(args, "tbProjStale", 0)))
        // 底部贴齐（0.39.26）：layoutGapBottom 必须 ≈0（.app 底边 - .body 底边），
        // 否则"最大化后底部空一截"这类布局缺陷没人能自动发现。
        o.put("layoutGapBottom", JsonInt(argInt(args, "layoutGapBottom", -1)))
        o.put("bodyH", JsonInt(argInt(args, "bodyH", 0)))
        o.put("appH", JsonInt(argInt(args, "appH", 0)))
        o.put("abortAt", JsonInt(argInt(args, "abortAt", 0)))
        o.put("scanR", JsonInt(argInt(args, "scanR", 0)))
        o.put("scanD", JsonInt(argInt(args, "scanD", 0)))
        o.put("scanH", JsonInt(argInt(args, "scanH", 0)))
        o.put("scanU", JsonInt(argInt(args, "scanU", 0)))
        o.put("scanC1", JsonInt(argInt(args, "scanC1", 0)))
        o.put("scanTotal", JsonInt(argInt(args, "scanTotal", 0)))
        o.put("scanOut", JsonString(argStr(args, "scanOut", "")))
        o.put("scanError", JsonString(argStr(args, "scanError", "")))
        o.put("scanOutError", JsonString(argStr(args, "scanOutError", "")))
        o.put("scanKindRows", JsonString(argStr(args, "scanKindRows", "")))
        // C2 对照指标：-1 表示没对照基线（页面上显示"未对照"）
        o.put("scanC2", JsonInt(argInt(args, "scanC2", -1)))
        o.put("scanMissed", JsonInt(argInt(args, "scanMissed", 0)))
        o.put("scanExtra", JsonInt(argInt(args, "scanExtra", 0)))
        o.put("scanVerdictDiff", JsonInt(argInt(args, "scanVerdictDiff", 0)))
        o.put("scanBaseline", JsonString(argStr(args, "scanBaseline", "")))
        o.put("scanKind", JsonString(argStr(args, "scanKind", "")))
        o.put("scanRows", JsonInt(argInt(args, "scanRows", 0)))
        // 按落档回填的证据（0.39.87）：AI 跑完 scan/deps 后 ①② 屏应当不再空
        o.put("scanScore", JsonInt(argInt(args, "scanScore", -1)))
        // 工具链体检的证据（0.39.95）：回投「缺哪几项 / 每项影响哪一步」，
        // 让"hdc / llvm-mingw 被误报缺失"这类问题能被 ui_report 直接断言出来
        o.put("envTotal", JsonInt(argInt(args, "envTotal", -1)))
        o.put("envOk", JsonInt(argInt(args, "envOk", -1)))
        o.put("envMiss", JsonInt(argInt(args, "envMiss", -1)))
        o.put("envMissIds", JsonString(argStr(args, "envMissIds", "")))
        o.put("envScopes", JsonString(argStr(args, "envScopes", "")))
        o.put("depsRows", JsonInt(argInt(args, "depsRows", 0)))
        o.put("stepFillN", JsonInt(argInt(args, "stepFillN", 0)))
        o.put("stepFillLast", JsonString(argStr(args, "stepFillLast", "")))
        o.put("stepFillErr", JsonString(argStr(args, "stepFillErr", "")))
        // 0.39.114：③ 规则改造 / ④ 签名卡的落档回读痕迹（页面侧 reportUi 同步加，§4-60）
        o.put("portRecLoaded", JsonInt(argInt(args, "portRecLoaded", 0)))
        o.put("portRecApplied", JsonInt(argInt(args, "portRecApplied", -1)))
        o.put("portRecAt", JsonInt(argInt(args, "portRecAt", -1)))
        o.put("signRecLoaded", JsonInt(argInt(args, "signRecLoaded", 0)))
        o.put("signRecMode", JsonString(argStr(args, "signRecMode", "")))
        o.put("signRecAt", JsonInt(argInt(args, "signRecAt", -1)))
        o.put("scanBlockers", JsonInt(argInt(args, "scanBlockers", 0)))
        // P3 依赖矩阵指标（t2h:deps 探针回投；depsTotal=0 且 depsOut 空表示未扫）
        o.put("depsTotal", JsonInt(argInt(args, "depsTotal", 0)))
        o.put("depsPatch", JsonInt(argInt(args, "depsPatch", 0)))
        o.put("depsUnavailable", JsonInt(argInt(args, "depsUnavailable", 0)))
        o.put("depsRows", JsonInt(argInt(args, "depsRows", 0)))
        o.put("depsOut", JsonString(argStr(args, "depsOut", "")))
        o.put("depsError", JsonString(argStr(args, "depsError", "")))
        // P4 改造执行指标（t2h:port 回投；applied=6 为全量，0 表示已迁移/无可改）
        o.put("portApplied", JsonInt(argInt(args, "portApplied", 0)))
        o.put("portRules", JsonInt(argInt(args, "portRules", 0)))
        o.put("portAuto", JsonInt(argInt(args, "portAuto", 0)))
        o.put("portGuide", JsonInt(argInt(args, "portGuide", 0)))
        o.put("portDecided", JsonInt(argInt(args, "portDecided", 0)))
        o.put("portError", JsonString(argStr(args, "portError", "")))
        // T5-1 交叉编译（t2h:build 回投；buildExit=-1 表示没跑过）
        o.put("buildOk", JsonBool(argBool(args, "buildOk", false)))
        o.put("buildExit", JsonInt(argInt(args, "buildExit", -1)))
        o.put("buildErrors", JsonInt(argInt(args, "buildErrors", 0)))
        o.put("buildWarns", JsonInt(argInt(args, "buildWarns", 0)))
        o.put("buildDiags", JsonInt(argInt(args, "buildDiags", 0)))
        o.put("buildFp", JsonInt(argInt(args, "buildFp", 0)))
        o.put("buildSo", JsonString(argStr(args, "buildSo", "")))
        o.put("buildGate", JsonString(argStr(args, "buildGate", "")))
        // T5-2 前端指纹（.so 内嵌 AssetKey ↔ dist/）
        o.put("buildAssetOk", JsonBool(argBool(args, "buildAssetOk", false)))
        o.put("buildAssetMatched", JsonInt(argInt(args, "buildAssetMatched", 0)))
        o.put("buildAssetStale", JsonInt(argInt(args, "buildAssetStale", 0)))
        o.put("buildAssetMissing", JsonInt(argInt(args, "buildAssetMissing", 0)))
        // T5-3 HAP 装配（t2h:hap 回投）
        o.put("hapOk", JsonBool(argBool(args, "hapOk", false)))
        o.put("hapBuilt", JsonBool(argBool(args, "hapBuilt", false)))
        o.put("hapBytes", JsonInt(argInt(args, "hapBytes", 0)))
        o.put("hapSigned", JsonBool(argBool(args, "hapSigned", false)))
        o.put("hapRawfile", JsonInt(argInt(args, "hapRawfile", 0)))
        o.put("hapArm64", JsonBool(argBool(args, "hapArm64", false)))
        o.put("hapGate", JsonString(argStr(args, "hapGate", "")))
        // T5-5 签名体检（t2h:sign 回投）
        o.put("signOk", JsonBool(argBool(args, "signOk", false)))
        o.put("signUdid", JsonBool(argBool(args, "signUdid", false)))
        o.put("signHasConfig", JsonBool(argBool(args, "signHasConfig", false)))
        o.put("signFilesExist", JsonBool(argBool(args, "signFilesExist", false)))
        o.put("signAllowsDevice", JsonBool(argBool(args, "signAllowsDevice", false)))
        o.put("signType", JsonString(argStr(args, "signType", "")))
        o.put("signCandCount", JsonInt(argInt(args, "signCandCount", 0)))
        // 包名门槛（0.39.9）：候选材料包名是否等于工程 bundleName
        // （false = 有材料但用不了，hvigor 会报 00303074；「候选数 > 0」不能当"能写回"）
        o.put("signBundleMatch", JsonBool(argBool(args, "signBundleMatch", false)))
        o.put("signCandidateBundles", JsonString(argStr(args, "signCandidateBundles", "")))
        o.put("signApplied", JsonBool(argBool(args, "signApplied", false)))
        // T5-4 签名两态（debug / release）：当前态 + 上架齐备度 + 强提醒
        o.put("signMode", JsonString(argStr(args, "signMode", "")))
        o.put("signModeLabel", JsonString(argStr(args, "signModeLabel", "")))
        o.put("signReleaseReady", JsonBool(argBool(args, "signReleaseReady", false)))
        o.put("signReminder", JsonString(argStr(args, "signReminder", "")))
        o.put("signReleaseProfiles", JsonInt(argInt(args, "signReleaseProfiles", 0)))
        // 切态步骤行数（版面可断言：提醒有了，步骤没渲染出来同样是 bug）
        o.put("signSwitchRows", JsonInt(argInt(args, "signSwitchRows", 0)))
        // T5-5 真机部署（t2h:deploy 回投）
        o.put("deployOk", JsonBool(argBool(args, "deployOk", false)))
        o.put("deploySerial", JsonString(argStr(args, "deploySerial", "")))
        o.put("deployDeviceCount", JsonInt(argInt(args, "deployDeviceCount", 0)))
        o.put("deployInstalled", JsonBool(argBool(args, "deployInstalled", false)))
        o.put("deployStarted", JsonBool(argBool(args, "deployStarted", false)))
        o.put("deployHilogOk", JsonBool(argBool(args, "deployHilogOk", false)))
        o.put("deployError", JsonString(argStr(args, "deployError", "")))
        // P6 验证与报告（t2h:verify 回投）
        o.put("verifyOk", JsonBool(argBool(args, "verifyOk", false)))
        o.put("verifyRate", JsonInt(argInt(args, "verifyRate", -1)))
        o.put("verifyPass", JsonInt(argInt(args, "verifyPass", 0)))
        // 功能口径分子（0.39.88）：与 verifyCovered 配对，判「通过 7/3」那类混口径读数有没有修好
        o.put("verifyFeaturePass", JsonInt(argInt(args, "verifyFeaturePass", -1)))
        o.put("verifyTotal", JsonInt(argInt(args, "verifyTotal", 0)))
        o.put("verifyLimit", JsonInt(argInt(args, "verifyLimit", 0)))
        o.put("verifyUnknown", JsonInt(argInt(args, "verifyUnknown", 0)))
        // 通过率口径（D-020，0.39.103）：分母=移植验收项里有结论的条数，业务功能不进分母、未测单列
        o.put("verifyCovered", JsonInt(argInt(args, "verifyCovered", -1)))
        o.put("verifyNotVerified", JsonInt(argInt(args, "verifyNotVerified", -1)))
        o.put("verifyScope", JsonString(argStr(args, "verifyScope", "")))
        o.put("verifyShots", JsonInt(argInt(args, "verifyShots", 0)))
        o.put("verifyMd", JsonString(argStr(args, "verifyMd", "")))
        // 清单行的版面指标（没有视觉也能断言"没竖排、没溢出"）
        o.put("verifyRows", JsonInt(argInt(args, "verifyRows", 0)))
        o.put("verifyOverflow", JsonInt(argInt(args, "verifyOverflow", 0)))
        o.put("verifyRowH", JsonInt(argInt(args, "verifyRowH", 0)))
        // 分节折叠（D-020，0.39.104）：移植项与业务功能分节，业务那节默认折叠。
        // 这些读数只回答"屏幕上分了几节、折叠了几条"，不参与判定（§4-60：字段要两处一起加）
        o.put("verifySections", JsonInt(argInt(args, "verifySections", 0)))
        o.put("verifyMainRows", JsonInt(argInt(args, "verifyMainRows", 0)))
        o.put("verifyBizRows", JsonInt(argInt(args, "verifyBizRows", 0)))
        o.put("verifyBizOpen", JsonInt(argInt(args, "verifyBizOpen", -1)))
        o.put("verifyBizText", JsonString(argStr(args, "verifyBizText", "")))
        o.put("verifyNoteText", JsonString(argStr(args, "verifyNoteText", "")))
        o.put("verifyListH", JsonInt(argInt(args, "verifyListH", 0)))
        // 口径字段有没有被界面接住（0.39.104 实测：VERIFY 重建时漏取 businessTotal，
        // 于是 verNote 里那句「业务功能 N 条…不计入」永远是空的一支）
        o.put("verifyBusinessTotal", JsonInt(argInt(args, "verifyBusinessTotal", -1)))
        o.put("verifyTransplantTotal", JsonInt(argInt(args, "verifyTransplantTotal", -1)))
        // 折叠分节自检结论（LINGQU_UI_PROBE=verifysections）：1=通过，0=没跑或不通过
        o.put("verifyProbe", JsonInt(argInt(args, "verifyProbe", 0)))
        o.put("verifyProbeFail", JsonString(argStr(args, "verifyProbeFail", "")))
        // T6-5 断点续迁（t2h:resume 回投）：next 是"从哪一步继续"，percent 是完成度
        o.put("resumeOk", JsonBool(argBool(args, "resumeOk", false)))
        o.put("resumeNext", JsonString(argStr(args, "resumeNext", "")))
        o.put("resumeDone", JsonInt(argInt(args, "resumeDone", 0)))
        o.put("resumeFailed", JsonInt(argInt(args, "resumeFailed", 0)))
        o.put("resumeSkipped", JsonInt(argInt(args, "resumeSkipped", 0)))
        o.put("resumeTotal", JsonInt(argInt(args, "resumeTotal", 0)))
        o.put("resumePercent", JsonInt(argInt(args, "resumePercent", -1)))
        o.put("resumeHint", JsonString(argStr(args, "resumeHint", "")))
        o.put("resumeSession", JsonString(argStr(args, "resumeSession", "")))
        // 版面孔径：步骤行数 / 行高（和 verify 一个套路——没有视觉也能证明"没竖排"）
        o.put("resumeRows", JsonInt(argInt(args, "resumeRows", 0)))
        o.put("resumeRowH", JsonInt(argInt(args, "resumeRowH", 0)))
        // T6-4 迁移报告（t2h:report 回投）：三段条数 + 结论数字 + 导出路径
        o.put("reportOk", JsonBool(argBool(args, "reportOk", false)))
        o.put("reportDid", JsonInt(argInt(args, "reportDid", 0)))
        o.put("reportUndone", JsonInt(argInt(args, "reportUndone", 0)))
        o.put("reportNeed", JsonInt(argInt(args, "reportNeed", 0)))
        o.put("reportRate", JsonInt(argInt(args, "reportRate", -1)))
        o.put("reportHuman", JsonInt(argInt(args, "reportHuman", 0)))
        o.put("reportHtml", JsonString(argStr(args, "reportHtml", "")))
        o.put("reportMd", JsonString(argStr(args, "reportMd", "")))
        o.put("reportConclusion", JsonString(argStr(args, "reportConclusion", "")))
        o.put("reportRows", JsonInt(argInt(args, "reportRows", 0)))
        // 报告与落档同代（0.39.85）：stale=界面上这一代已落后于 ⑥ 屏最新落档（必须 false）；
        // generatedAt=这一代按什么时候的落档出的；autoCount=进屏自动重出了几次。白名单两处都要加（§4-60）
        o.put("reportStale", JsonBool(argBool(args, "reportStale", false)))
        // ⑦ 屏的这份报告是从哪来的（0.39.98）：record=按落档回读（只读盘）/ generated=这次重出
        o.put("reportLoaded", JsonBool(argBool(args, "reportLoaded", false)))
        o.put("reportSource", JsonString(argStr(args, "reportSource", "")))
        o.put("reportGeneratedAt", JsonString(argStr(args, "reportGeneratedAt", "")))
        o.put("reportAutoCount", JsonInt(argInt(args, "reportAutoCount", 0)))
        // 风险分级（0.39.47）：总体级别 / 标签 / 条数 / 高风险条数——白名单两处都要加（§4-60）
        o.put("reportRisk", JsonString(argStr(args, "reportRisk", "")))
        o.put("reportRiskLabel", JsonString(argStr(args, "reportRiskLabel", "")))
        o.put("reportRiskRows", JsonInt(argInt(args, "reportRiskRows", 0)))
        o.put("reportRiskHi", JsonInt(argInt(args, "reportRiskHi", 0)))
        o.put("reportRiskSum", JsonString(argStr(args, "reportRiskSum", "")))
        // 卡片顺序与矩阵标题（0.39.47）：断言"迁移矩阵在风险等级下面"且标题不含「5 样本」「T7-3」
        o.put("reportOrder", JsonString(argStr(args, "reportOrder", "")))
        o.put("reportMatrixTitle", JsonString(argStr(args, "reportMatrixTitle", "")))
        // 克隆链路的可观测性（0.39.48）：以前"点了没反应"现场只有 uiErr=3 这么个数字，
        // 现在把面板原文 / 是否在跑 / 克隆到哪 / 地址被拦次数 / **异常原文**都收进来
        o.put("cloneNote", JsonString(argStr(args, "cloneNote", "")))
        o.put("cloneBusy", JsonBool(argBool(args, "cloneBusy", false)))
        o.put("cloneTarget", JsonString(argStr(args, "cloneTarget", "")))
        o.put("gitUrlGuard", JsonInt(argInt(args, "gitUrlGuard", 0)))
        o.put("uiErrText", JsonString(argStr(args, "uiErrText", "")))
        // 后端心跳（0.39.90）：僵尸窗口的可断言证据 —— backendLost=1 就是「这个窗口点了没反应」。
        // 白名单实现必须与页面 reportUi **两处一起加**，否则键会被静默丢掉（AGENTS §4-60）
        o.put("backendLost", JsonInt(argInt(args, "backendLost", 0)))
        o.put("backendMiss", JsonInt(argInt(args, "backendMiss", 0)))
        o.put("backendOkBeats", JsonInt(argInt(args, "backendOkBeats", 0)))
        o.put("backendAgeSec", JsonInt(argInt(args, "backendAgeSec", -1)))
        o.put("backendWhy", JsonString(argStr(args, "backendWhy", "")))
        o.put("backendNote", JsonString(argStr(args, "backendNote", "")))
        o.put("backendProbe", JsonInt(argInt(args, "backendProbe", -1)))
        o.put("backendProbeFail", JsonString(argStr(args, "backendProbeFail", "")))
        // 上次工程不存在而未被带回（0.39.48）：空 = 没发生；有值 = 那条路径已不在
        o.put("projRestoreSkipped", JsonString(argStr(args, "projRestoreSkipped", "")))
        // 假数据清账（0.39.49）：mockLeft=页面上还剩几块「占位示意」（必须是 0）；
        // execLogLines/execLogLast=执行日志是真记的；pipeline=⑤ 屏五格的真实态
        o.put("mockLeft", JsonInt(argInt(args, "mockLeft", 0)))
        // 假数据回归闸（0.39.49）：页面里还剩几个"示例串"（必须是 0）
        o.put("fakeLeft", JsonInt(argInt(args, "fakeLeft", 0)))
        // ① 屏「最近项目」：行数与来源（行数 0 且无错 = 确实没有迁过的工程，不是没实现）
        o.put("projRows", JsonInt(argInt(args, "projRows", -1)))
        o.put("projListSrc", JsonString(argStr(args, "projListSrc", "")))
        o.put("projListErr", JsonString(argStr(args, "projListErr", "")))
        // ① 屏「AI 过程消息」（0.39.52）：条数与最后一条原文（空 = AI 还没说话，不是没实现）
        o.put("migAiLines", JsonInt(argInt(args, "migAiLines", 0)))
        o.put("migAiLast", JsonString(argStr(args, "migAiLast", "")))
        // 回合结束的"为什么停"（0.39.51）：用户实测"回合结束了界面什么都不说，就这么停在这了"
        o.put("turnEndReason", JsonString(argStr(args, "turnEndReason", "")))
        o.put("lastToolErr", JsonString(argStr(args, "lastToolErr", "")))
        o.put("lastToolErrName", JsonString(argStr(args, "lastToolErrName", "")))
        // 错误卡计数（0.39.63）：用户实测"发 hello 收到正常回复后，屏幕上多出一张红卡说迁移还没完成"。
        // 这类"多了个红块"的问题必须能数字断言——聊天正常收尾时它必须是 0。
        o.put("errorCards", JsonInt(argInt(args, "errorCards", 0)))
        // 从头重跑（0.39.64）：归档搬了几项 / 搬到哪个目录 / 失败原因（-1 = 还没点过）
        o.put("resetMoved", JsonInt(argInt(args, "resetMoved", -1)))
        o.put("resetArchive", JsonString(argStr(args, "resetArchive", "")))
        o.put("resetOk", JsonBool(argBool(args, "resetOk", false)))
        o.put("resetErr", JsonString(argStr(args, "resetErr", "")))
        // AI 跑完自动出报告（0.39.54）：done=真出了；path=md 落档；risk=风险总体；err=失败原因
        o.put("autoReportDone", JsonBool(argBool(args, "autoReportDone", false)))
        o.put("autoReportPath", JsonString(argStr(args, "autoReportPath", "")))
        o.put("autoReportRisk", JsonString(argStr(args, "autoReportRisk", "")))
        o.put("autoReportErr", JsonString(argStr(args, "autoReportErr", "")))
        o.put("execLogLines", JsonInt(argInt(args, "execLogLines", 0)))
        o.put("execLogLast", JsonString(argStr(args, "execLogLast", "")))
        o.put("pipeline", JsonString(argStr(args, "pipeline", "")))
        // T7-3 批量矩阵（t2h:batch 回投）：样本数 / 已验证数 / 平均可用率 / A4 判定
        o.put("batchOk", JsonBool(argBool(args, "batchOk", false)))
        o.put("batchSamples", JsonInt(argInt(args, "batchSamples", 0)))
        o.put("batchVerified", JsonInt(argInt(args, "batchVerified", 0)))
        o.put("batchAvgRate", JsonInt(argInt(args, "batchAvgRate", -1)))
        o.put("batchAvgScore", JsonInt(argInt(args, "batchAvgScore", -1)))
        o.put("batchHuman", JsonInt(argInt(args, "batchHuman", 0)))
        // 0.39.29：矩阵"已迁移成功几个" + 样本是从哪儿发现的（explicit/workspace/remembered/cwd-lingqu）
        o.put("batchPassed", JsonInt(argInt(args, "batchPassed", 0)))
        o.put("batchSource", JsonString(argStr(args, "batchSource", "")))
        o.put("batchSumText", JsonString(argStr(args, "batchSumText", "")))
        // 鸿蒙工程根（`<工程>/src-tauri/gen/ohos`）——DevEco Studio 打开的就是这个目录
        o.put("hapOhosDir", JsonString(argStr(args, "hapOhosDir", "")))
        // 工具执行心跳（0.39.32）：长命令期间"还在干活"的可断言位
        o.put("aiToolRunning", JsonInt(argInt(args, "aiToolRunning", 0)))
        o.put("aiToolName", JsonString(argStr(args, "aiToolName", "")))
        o.put("aiToolElapsed", JsonInt(argInt(args, "aiToolElapsed", 0)))
        o.put("aiBusyText", JsonString(argStr(args, "aiBusyText", "")))
        // 断线恢复（0.39.33）：收到 history_messages 后按历史重建了几条
        o.put("historyIn", JsonInt(argInt(args, "historyIn", 0)))
        o.put("historyShown", JsonInt(argInt(args, "historyShown", 0)))
        o.put("batchA4", JsonBool(argBool(args, "batchA4", false)))
        o.put("batchA1", JsonBool(argBool(args, "batchA1", false)))
        o.put("batchHtml", JsonString(argStr(args, "batchHtml", "")))
        o.put("batchRows", JsonInt(argInt(args, "batchRows", 0)))
        o.put("batchA4Rows", JsonInt(argInt(args, "batchA4Rows", 0)))
        o.put("errorCount", JsonInt(argInt(args, "errorCount", 0)))
        // 自检序列可判定性（0.13.1 补）：以前 tag 只进 console.log，落盘 7 条快照长得
        // 一模一样，无法回答"哪条是 probe-initial、哪条是 probe-done"
        o.put("tag", JsonString(argStr(args, "tag", "")))
        o.put("ts", JsonInt(argInt(args, "ts", 0)))
        let text = o.toJsonString()
        // 落文件而不是只打日志：GUI 的 stderr 去向受框架日志重定向影响（见 AGENTS §4 第 14 条），
        // 落盘的东西才是可复核的证据。
        //   .lingqu/ui-report.json —— 最新一次快照（覆盖写，pretty）
        //   .lingqu/ui-report.log  —— 自检序列（**每次一行压缩 JSON**，追加），用于断言状态流转。
        //     0.13.1 修正：以前把 pretty JSON 直接追加进 .log，7 条快照占了 259 行，
        //     而注释与文档都写"每次一行"——按行 grep 的断言全失效。这里压成单行。
        let dir = ".lingqu"
        // 注意：**故意留在应用目录**——这是"界面自检"的证据，不属于任何被迁移工程（0.38.0）
        let snap = ".lingqu/ui-report.json"
        let logf = ".lingqu/ui-report.log"
        let oneline = text.replace("\n", " ").replace("\r", " ")
        var wrote = false
        try {
            // 互斥：t2h:ui_report 会被多个定时器/页签切换并发调用，而落盘是
            // 「读全文 → 拼一行 → 覆盖写」。不加锁时两个写者会互相截断对方的内容——
            // 2026-10-30 实测把某条快照写成了只剩 `6902039 }` 的碎片，整份自检序列不可信。
            synchronized(gUiReportLock) {
                if (!exists(Path(dir))) {
                    Directory.create(Path(dir))
                }
                File.writeTo(snap, text.toArray())
                var prev = ""
                if (exists(Path(logf))) {
                    prev = lenientUtf8(File.readFrom(logf))
                }
                // 上一行没以换行结尾（上次写到一半挂了）时先补一个，避免两行粘连
                var line = oneline
                if (prev != "" && !prev.endsWith("\n")) {
                    line = "\n" + line
                }
                File.writeTo(logf, (prev + line + "\n").toArray())
                wrote = true
            }
        } catch (e: Exception) {
            eprintln("[lingqu][ui] 写报告失败：${e}")
        }
        eprintln("[lingqu][ui] ${text}")
        var res = JsonObject()
        res.put("ok", JsonBool(wrote))
        res.put("path", JsonString(snap))
        res.put("log", JsonString(logf))
        return res
    }
}

/**
 * t2h:build —— 交叉编译 + 结构化诊断（T5-1）。
 *
 * 一条命令做四件事（全部落盘，D-013 不静默）：
 *   ① 跑 `cargo build --release --target <target> --message-format=json`
 *   ② stdout(JSONL) → 解析成结构化诊断；stderr 原样保留（**build-script/链接类失败只在 stderr**）
 *   ③ 两份文本一起喂指纹库 → 命中就给"现象→根因→修法"，rule 档建议重跑 t2h:port
 *   ④ 过六道闸里的编译闸 + 回归闸（基线取上一次落档的 errorCount）
 *
 * 落档：`.lingqu/build/<工程>.jsonl`（原始 JSONL）/ `.log`（人读全文）/ `.json`（lingqu/build/v1）
 */
public class BuildCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        var res = JsonObject()
        if (path.size == 0) {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("t2h:build 需要参数 path（或设环境变量 LINGQU_SCAN_PATH）"))
            return res
        }
        // ---- action=load（0.39.88）：只回读构建落档，不跑 cargo、也不要求 Cargo.toml 还在 ----
        if (argStr(args, "action", "") == "load") {
            return buildRecordResponse(path)
        }
        let tomlPath = cargoTomlPathOf(path)
        if (tomlPath == "") {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("未找到 Cargo.toml（找过 ${path}/src-tauri/Cargo.toml 与 ${path}/Cargo.toml）"))
            return res
        }
        let srcDir = tomlPath[0..(tomlPath.size - "/Cargo.toml".size)]
        let target = argStr(args, "target", "aarch64-unknown-linux-ohos")
        let cargoBin = resolveCargoBin()
        if (cargoBin == "") {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("找不到 cargo（不在 PATH？可用环境变量 LINGQU_CARGO 指定 cargo 绝对路径）"))
            return res
        }

        var exitCode: Int64 = -1
        var stdoutText = ""
        var stderrText = ""
        var spawnError = ""
        // verifyOnly：跳过 cargo，只拿已有 .so 与 dist/ 做前端指纹校验（CI 与"自证"场景用）
        let verifyOnly = argBool(args, "verifyOnly", false)
        var ndkHome = ""
        if (!verifyOnly) {
            // OHOS crate（ohos-arkui-sys 等）的 build.rs 直接 `env::var("OHOS_NDK_HOME").expect(...)`，
            // 缺它当场 panic（0.39.79 rust-music-2 实测 exit=101）。新工程的 [env] 段里已经带上，
            // 这里再兜一层：救"已迁移但没重跑 port"的老工程。子进程 cargo 继承本进程环境。
            if (envOr("OHOS_NDK_HOME", "") == "") {
                let ndk = envOr("NATIVE_OHOS_SDK", "")
                if (ndk != "") {
                    setVariable("OHOS_NDK_HOME", ndk)
                    ndkHome = ndk
                }
            }
            // 0.39.126（R-2 环境关）：交叉编译前先修两件"必然挡路"的事，修了什么要留下证据。
            //  ① 工程自带的 .cargo/config.toml 里可能有**过期 SDK 路径**（工程配置优先级高于
            //     我们从环境推导的值）⇒ 路径必须存在才采用，否则按推导 NDK 重写同一尾巴；
            //  ② 依赖树有 C 依赖但工程缺 target CC ⇒ 补 [env] 段，否则 cc-rs 拿宿主 cc 必失败。
            let ndkForFix = if (ndkHome != "") { ndkHome } else { envOr("NATIVE_OHOS_SDK", "") }
            let cfgPath = firstExistingPath([srcDir + "/.cargo/config.toml", srcDir + "/.cargo/config"])
            var fixups = ArrayList<String>()
            if (ndkForFix != "" && cfgPath != "") {
                for (f in fixStaleCargoConfigOf(cfgPath, ndkForFix)) {
                    fixups.add("过期 SDK 路径（需手改，本工具不自动改写）：${f}")
                }
                if (ensureTargetCcOf(cfgPath, ndkForFix, readTextOrEmpty(srcDir + "/Cargo.lock"))) {
                    fixups.add("依赖树含 C 依赖但缺 target CC：已补 [env] CC_aarch64_unknown_linux_ohos")
                }
            }
            if (fixups.size > 0) {
                var fixArr = JsonArray()
                for (f in fixups) {
                    eprintln("[build] 环境关已修：${f}")
                    fixArr.add(JsonString(f))
                }
                res.put("configFixups", fixArr)
            }
            // CMake toolchain 显式钉住：`aws-lc-sys` 之类的 CMake 依赖会把 OHOS_NDK_HOME 当 SDK 根
            // 再拼 `/native/build/cmake/…`，我们若给 `…/native` 就得到 `native/native`（2026-11-19 实测）。
            // 直接按"存在的那个文件"设变量，谁的口径都不用猜。
            if (ndkForFix != "") {
                let tc = cmakeToolchainPathOf(ndkForFix)
                if (exists(Path(tc))) {
                    setVariable("CMAKE_TOOLCHAIN_FILE_aarch64_unknown_linux_ohos", tc)
                    setVariable("CMAKE_TOOLCHAIN_FILE", tc)
                    res.put("cmakeToolchain", JsonString(tc))
                }
            }
            try {
                // `--lib`：鸿蒙 HAP 要的是 cdylib（`lib<name>.so`），桌面 bin 不是迁移产物。
                // 不加它会连 bin 一起编：dbx 实测 bin 链接阶段 rustc 直接崩
                // （`exit code: 0xc0000409, STATUS_STACK_BUFFER_OVERRUN`），
                // 于是 exitCode=101、落档写"构建失败"，而 `.so` 其实已经产出来了（假失败）。
                let argv = ["build", "--release", "--target", target, "--lib", "--message-format=json"]
                let (code, rawOut, rawErr) = executeWithOutput(cargoBin, argv, workingDirectory: Path(srcDir))
                exitCode = code
                stdoutText = String.fromUtf8(rawOut)
                stderrText = String.fromUtf8(rawErr)
            } catch (e: Exception) {
                spawnError = "${e}"
            }
        } else {
            exitCode = 0
        }

        // ---- 解析 + 诊断 ----
        let parsed = parseCargoJsonl(stdoutText)
        // build-script / 链接类失败在 stdout 里没有 compiler-message，只能靠 stderr；
        // 两份文本拼起来喂指纹库，才不会漏掉最常见的那类失败。
        let combined = diagsAsLogText(parsed.diags) + "\n" + stderrText
        // 0.39.113：同样带上用户级认知层的指纹（自己学到的坑，迁移时就该命中）
        let hits = diagnoseLogWith(combined, fingerprintLibraryWithUser(readUserFingerprintsText()))
        let dj = diagnosisJson(hits)
        // stderr 侧的 error 行：build-script / 链接类失败的**唯一**痕迹
        let stderrErrors = countErrorLines(stderrText)
        let effectiveErrors = if (parsed.errorCount() > stderrErrors) { parsed.errorCount() } else { stderrErrors }

        // ---- T5-2 前端指纹校验：`.so` 内嵌 AssetKey ↔ dist/ 实际产物 ----
        // 只在"编译成功且产出了 .so"时才有得比；失败构建天然没有 .so，闸会如实说"没扫到"。
        // 0.39.100：期望产物名要**先**算出来——cargo 的 artifact 顺序不保证应用自己的排在前面，
        // 靠"第一个 .so"取会拿到 deps 里的 hash 中间产物（§4-151）。
        // 鸿蒙产物闸的输入（0.39.81）：库名与 cdylib 声明决定"期望的产物叫什么"
        let cargoTomlText = readTextOrEmpty("${srcDir}/Cargo.toml")
        let expectedSo = expectedLibNameOf(cargoTomlText, projectNameOf(path))
        let soPath = findSoArtifactOf(srcDir, target, parsed.artifacts, expectedSo)
        // verifyOnly 模式下没有 cargo 输出，直接从磁盘上找最近产出的 .so
        let soPathFinal = if (soPath != "") { soPath } else if (verifyOnly) { findSoOnDisk(srcDir, target) } else { "" }
        var distDir = resolveDistDirOf(path, srcDir)
        var embeddedKeys = ArrayList<String>()
        var distKeys = ArrayList<String>()
        var assetDiff = AssetDiff()
        var assetError = ""
        var assetLayout = "none"
        if (soPathFinal != "") {
            try {
                let soBytes = File.readFrom(soPathFinal)
                distKeys = distAssetKeysOf(distDir)
                // 0.39.91：`frontendDist` 未必是 vite 的 `assets/` 布局（现场 rust-music-3
                // 是 `ui/` + 单个 index.html）。没有 assets/ 时改做「存在性」比对——
                // 旧口径两处都只认 `assets/` 前缀，会把"编好了、前端也在里面"判成假红。
                let entryKeys = distEntryKeysOf(distDir)
                assetLayout = assetLayoutOf(distKeys, entryKeys)
                if (assetLayout == "entry") {
                    assetDiff = compareEntryKeys(soBytes, entryKeys)
                    embeddedKeys = assetDiff.matched
                } else {
                    embeddedKeys = extractAssetKeys(soBytes)
                    assetDiff = compareAssetKeys(embeddedKeys, distKeys)
                }
            } catch (e: Exception) {
                assetError = "读 .so 失败：${e}"
            }
        }

        // ---- 六道闸：编译闸 + 回归闸 + 前端指纹闸 ----
        // 注：**不**把诊断提案喂给补丁闸——diagnose 出来的提案只带文件名（增删行数未知，
        // 真实 diff 由 t2h:port 幂等重跑产生），拿 0/0 去撞"空补丁"闸只会造出假失败（实测撞到过）。
        let gateReports = ArrayList<GateReport>()
        let baselineErrors = if (verifyOnly) { -1 } else { lastBuildErrorCountOf(path) }
        if (!verifyOnly) {
            gateReports.add(checkCompileGate(exitCode, effectiveErrors))
            gateReports.add(checkRegressionGate(baselineErrors, effectiveErrors))
            // 编译成功 ≠ 移植产物出来了：只编出 exe（没有 cdylib）的工程在这里被拦下
            gateReports.add(checkOhosArtifactGate(exitCode, effectiveErrors, expectedSo,
                soPathFinal, hasCdylibCrateType(cargoTomlText)))
        }
        if (soPathFinal != "" && assetError == "") {
            gateReports.add(checkAssetFingerprintGate(Int64(assetDiff.staleInSo.size),
                Int64(assetDiff.missingInSo.size), Int64(embeddedKeys.size)))
        }
        let gates = mergeGates(gateReports)

        // ---- 落档（三份：原始 JSONL / 人读日志 / 结构化摘要）----
        var outError = ""
        var outJson = ""
        var outLog = ""
        var outJsonl = ""
        let safeName = sanitizeFileName(projectNameOf(path))
        try {
            // 落档跟着工程走（0.38.0）
            let bDir = lqDirOf(path) + cjhPathSep() + "build"
            ensureDirOf(bDir)
            outJsonl = bDir + cjhPathSep() + safeName + ".jsonl"
            outLog = bDir + cjhPathSep() + safeName + ".log"
            outJson = bDir + cjhPathSep() + safeName + ".json"
            File.writeTo(outJsonl, stdoutText.toArray())
            File.writeTo(outLog, (combined).toArray())
            var root = JsonObject()
            root.put("schema", JsonString("lingqu/build/v1"))
            root.put("project", JsonString(safeName))
            root.put("target", JsonString(target))
            root.put("exitCode", JsonInt(exitCode))
            root.put("errorCount", JsonInt(effectiveErrors))
            root.put("warningCount", JsonInt(parsed.warningCount()))
            root.put("baselineErrors", JsonInt(baselineErrors))
            root.put("stderrErrors", JsonInt(stderrErrors))
            var arts = JsonArray()
            for (a in parsed.artifacts) {
                arts.add(JsonString(a))
            }
            root.put("artifacts", arts)
            root.put("diags", diagsJson(parsed.diags, 40))
            root.put("diagnosis", dj)
            root.put("gates", gates.toJson())
            root.put("soPath", JsonString(soPathFinal))
            root.put("expectedSo", JsonString(expectedSo))
            root.put("distDir", JsonString(distDir))
            root.put("assetDiff", assetDiff.toJson())
            root.put("stderrTail", JsonString(firstLines("\n" + stderrText, 200)))
            File.writeTo(outJson, root.toJsonString().toArray())
        } catch (e: Exception) {
            outError = "落档失败：${e}"
        }

        res.put("ok", JsonBool(spawnError == "" && outError == "" && exitCode == 0))
        res.put("target", JsonString(target))
        res.put("exitCode", JsonInt(exitCode))
        res.put("errorCount", JsonInt(effectiveErrors))
        res.put("warningCount", JsonInt(parsed.warningCount()))
        res.put("stderrErrors", JsonInt(stderrErrors))
        res.put("baselineErrors", JsonInt(baselineErrors))
        res.put("badLines", JsonInt(parsed.badLines))
        var arts2 = JsonArray()
        for (a in parsed.artifacts) {
            arts2.add(JsonString(a))
        }
        res.put("artifacts", arts2)
        res.put("diags", diagsJson(parsed.diags, 20))
        res.put("diagnosis", dj)
        let suggest = dj.get("suggestRerunPort")
        res.put("suggestRerunPort", suggest.getOrThrow())
        res.put("gates", gates.toJson())
        res.put("soPath", JsonString(soPathFinal))
        // 兜底注入的证据（空串 = 环境里本来就有，或没设 NATIVE_OHOS_SDK）
        res.put("ndkHome", JsonString(ndkHome))
        res.put("distDir", JsonString(distDir))
        res.put("assetDiff", assetDiff.toJson())
        res.put("assetError", JsonString(assetError))
        var keysArr = JsonArray()
        for (k in embeddedKeys) {
            keysArr.add(JsonString(k))
        }
        res.put("soAssetKeys", keysArr)
        res.put("outJson", JsonString(outJson))
        res.put("outLog", JsonString(outLog))
        res.put("outJsonl", JsonString(outJsonl))
        var errMsg = spawnError
        if (errMsg == "") {
            errMsg = outError
        }
        if (errMsg == "" && exitCode != 0) {
            errMsg = firstLines(stderrText, 6)
        }
        res.put("error", JsonString(errMsg))
        eprintln("[lingqu][build] ${safeName} target=${target} exit=${exitCode} errors=${effectiveErrors} " +
            "fp=${dj.get("total").toString()} gates=${gates.passed}")
        return res
    }
}

/** 找 cargo：LINGQU_CARGO 优先，其次 PATH 里的 cargo */
func resolveCargoBin(): String {
    let fromEnv = envOr("LINGQU_CARGO", "")
    if (fromEnv.size > 0 && exists(Path(fromEnv))) {
        return fromEnv
    }
    try {
        let (code, out, _) = executeWithOutput("cargo", ["--version"])
        if (code == 0 && lenientUtf8(out).contains("cargo")) {
            return "cargo"
        }
    } catch (e: Exception) {
        let _ = e
    }
    return ""
}

/** 取父目录（`/` 与 `\` 都认；到根/无分隔符返回空串）。 */
public func parentDirOf(p: String): String {
    let bs = p.toArray()
    var i = Int64(bs.size) - 1
    while (i >= 0) {
        if (bs[i] == 47 || bs[i] == 92) {
            if (i == 0) {
                return ""
            }
            return p[0..i]
        }
        i -= 1
    }
    return ""
}

/**
 * 从 cargo 配置文本里取 `[build] target-dir`（纯函数，可单测；找不到给空串）。
 * 只认 `[build]` 段里的这一项——`[env]` 段同名前缀不算。
 */
public func targetDirInCargoConfigOf(text: String): String {
    var inBuild = false
    for (raw in text.split("\n")) {
        let line = raw.trimAscii()
        if (line.size == 0 || line.startsWith("#")) {
            continue
        }
        if (line.startsWith("[")) {
            inBuild = (line == "[build]")
            continue
        }
        if (!inBuild || !line.startsWith("target-dir")) {
            continue
        }
        let eqOpt = line.indexOf("=")
        if (eqOpt.isNone()) {
            continue
        }
        let eq = eqOpt.getOrThrow()
        var v = line[eq + 1..].trimAscii()
        let hashOpt = v.indexOf("#")
        if (hashOpt.isSome()) {
            v = v[0..hashOpt.getOrThrow()].trimAscii()
        }
        let vb = v.toArray()
        if (vb.size >= 2 && ((vb[0] == 34 && vb[vb.size - 1] == 34) || (vb[0] == 39 && vb[vb.size - 1] == 39))) {
            v = v[1..v.size - 1]
        }
        return v
    }
    return ""
}

/**
 * 工程的 cargo 产物根目录（**尊重 `build.target-dir`**，读不到才回落 `<srcDir>/target`）。
 *
 * 2026-11-21 dbx 实测：dbx 因 C 盘只剩 2G 把 `target-dir` 配到 `E:/tmp/dbx-target`，
 * 工具却一直按 `<srcDir>/target` 找 `.so` ⇒ `exitCode=0` 却报「编译成功但没产出 libdbx_lib.so」
 * （假红，§4-151 同族：**找错位置 ≠ 没产出**）。
 * 查找顺序与 cargo 一致：从 `srcDir` 向上最多 4 层找 `.cargo/config.toml`；
 * 相对路径按 cargo 语义相对该配置的父目录解析。
 */
public func cargoTargetRootOf(srcDir: String): String {
    var cur = srcDir
    var depth = 0
    while (depth < 4) {
        let cfg = "${cur}/.cargo/config.toml"
        if (exists(Path(cfg))) {
            let v = targetDirInCargoConfigOf(readTextOrEmpty(cfg))
            if (v.size > 0) {
                let vb = v.toArray()
                let abs = (vb.size >= 2 && vb[1] == 58) || (vb.size >= 1 && (vb[0] == 47 || vb[0] == 92))
                if (abs) {
                    return v
                }
                return "${cur}/${v}"
            }
        }
        let up = parentDirOf(cur)
        if (up.size == 0 || up == cur) {
            break
        }
        cur = up
        depth += 1
    }
    return "${srcDir}/target"
}

/** `<产物根>/<triple>/release` —— `.so` 定位与产物闸共用这一处口径。 */
public func releaseDirOf(srcDir: String, target: String): String {
    return "${cargoTargetRootOf(srcDir)}/${target}/release"
}

/**
 * 找 cargo 产出的 .so 绝对路径：期望名优先 → artifacts 逐个试 `release/` 与 `deps/` → 磁盘兜底。
 *
 * 0.39.100：按「artifacts 第一个 `.so`」取会拿到 deps 里的 hash 中间产物（note-gen-2 现场），
 * 拼出的路径不存在 ⇒ 整条链被判"没产出 .so"（§4-151）。候选顺序由纯函数
 * `soCandidateRelsOf` 决定，可单测。
 */
func findSoArtifactOf(srcDir: String, target: String, artifacts: ArrayList<String>,
    expectedSo: String): String {
    let rel = releaseDirOf(srcDir, target)
    for (c in soCandidateRelsOf(artifacts, expectedSo)) {
        let p = "${rel}/${c}"
        if (exists(Path(p))) {
            return p
        }
    }
    // cargo 一条 artifact 都没报（增量编译全是 Fresh）⇒ 只能按磁盘兜底，别报假红。
    // 编译失败时闸会先短路，这里不会把"没编出来"变成通过。
    if (artifacts.size == 0) {
        return findSoOnDisk(srcDir, target)
    }
    return ""
}

/**
 * verifyOnly 模式用：从 `target/<target>/release` 里挑一个 .so（cargo 输出不可用时）
 */
func findSoOnDisk(srcDir: String, target: String): String {
    let dir = releaseDirOf(srcDir, target)
    if (!exists(Path(dir))) {
        return ""
    }
    var entries: Array<FileInfo>
    try {
        entries = Directory.readFrom(dir)
    } catch (e: Exception) {
        let _ = e
        return ""
    }
    for (info in entries) {
        if (!info.isDirectory() && info.name.endsWith(".so")) {
            return "${dir}/${info.name}"
        }
    }
    return ""
}

/**
 * 解析前端产物目录：读 `tauri.conf.json` 的 `frontendDist`（相对**配置文件所在目录**解析），
 * 读不到就退回工程根的 `dist/`。
 *
 * 0.39.91：配置文件未必在 `src-tauri/` 下——**扁平布局**（`src-tauri` 就是工程根，
 * 现场 rust-music-3）时它在工程根。旧实现只看 `srcDir`，读不到 `frontendDist` 就退回
 * `dist/`，而该工程前端在 `ui/`、`dist/` 是空的 ⇒ 指纹闸一路假红（§4-144）。
 */
public func resolveDistDirOf(projectDir: String, srcDir: String): String {
    var conf = "${srcDir}/tauri.conf.json"
    var confDir = srcDir
    if (!exists(Path(conf))) {
        let alt = "${projectDir}/tauri.conf.json"
        if (exists(Path(alt))) {
            conf = alt
            confDir = projectDir
        }
    }
    var dist = ""
    if (exists(Path(conf))) {
        try {
            let text = lenientUtf8(File.readFrom(conf))
            // tauri v2：`build.frontendDist`；v1 与部分模板是顶层键，两个都认
            dist = jsonStringPathOf(text, "build.frontendDist")
            if (dist == "") {
                dist = jsonStringPathOf(text, "frontendDist")
            }
        } catch (e: Exception) {
            dist = ""
        }
    }
    if (dist == "") {
        return "${projectDir}/dist"
    }
    // frontendDist 相对配置文件所在目录；也常见 "../dist" 这种写法（就地拼接，exists 认 `..`）
    if (dist.startsWith("./")) {
        dist = dist[2..]
    }
    let joined = "${confDir}/${dist}"
    if (exists(Path(joined))) {
        return joined
    }
    return "${projectDir}/dist"
}

/** 从 JSON 文本里取顶层字符串字段（tauri.conf.json 用；找不到返回 ""） */
func jsonStringFieldOf(text: String, key: String): String {
    try {
        let root = JsonValue.fromStr(text)
        match (root.kind()) {
            case JsonKind.JsObject =>
                match (root.asObject().get(key)) {
                    case Some(v) => match (v.kind()) {
                        case JsonKind.JsString => return v.asString().getValue()
                        case _ => return ""
                    }
                    case None => return ""
                }
            case _ => return ""
        }
    } catch (e: Exception) {
        return ""
    }
}

/**
 * 从 JSON 文本里按**点路径**取字符串字段（`build.frontendDist`），找不到返回 ""。
 *
 * 0.39.91：tauri v2 的 `frontendDist` 是 **`build.frontendDist`**，不是顶层键
 * （tauri v1 才是顶层 `distDir`）——只看顶层永远取到空串，于是 distDir 回落成
 * 工程根的 `dist/`，而现场那个工程的前端在 `ui/`（§4-144 假红的最后一环）。
 */
public func jsonStringPathOf(text: String, path: String): String {
    try {
        var cur = JsonValue.fromStr(text)
        for (seg in path.split(".")) {
            // JsonKind 是枚举，不能直接 ==；用 match 收窄
            let isObj = match (cur.kind()) {
                case JsonKind.JsObject => true
                case _ => false
            }
            if (!isObj) {
                return ""
            }
            match (cur.asObject().get(seg)) {
                case Some(v) => cur = v
                case None => return ""
            }
        }
        return match (cur.kind()) {
            case JsonKind.JsString => cur.asString().getValue()
            case _ => ""
        }
    } catch (e: Exception) {
        return ""
    }
}

/** 上一次落档的 errorCount（做回归闸基线）；没有落档返回 -1 */
func lastBuildErrorCountOf(projectDir: String): Int64 {
    // 读侧双查（工程优先、CWD 兜底）：迁移期旧落档仍能当基线
    let f = resolveLqPath(projectDir, "build/${sanitizeFileName(projectNameOf(projectDir))}.json")
    if (!exists(Path(f))) {
        return -1
    }
    try {
        let root = JsonValue.fromStr(lenientUtf8(File.readFrom(f)))
        match (root.kind()) {
            case JsonKind.JsObject =>
                match (root.asObject().get("errorCount")) {
                    case Some(v) => match (v.kind()) {
                        case JsonKind.JsInt => return v.asInt().getValue()
                        case _ => return -1
                    }
                    case None => return -1
                }
            case _ => return -1
        }
    } catch (e: Exception) {
        return -1
    }
}

/**
 * t2h:hap —— HAP 装配 + 死资源校验（T5-3）。
 *
 * 不依赖 PATH：全程用 DevEco 自带的 node + hvigorw.js（实测 6.1.1.300 / hvigor 6.24.4）：
 *   <DEVECO_HOME>\tools\node\node.exe <DEVECO_HOME>\tools\hvigor\bin\hvigorw.js
 *     --mode module -p product=default assembleHap --no-daemon
 * 运行目录 = `<src-tauri>/gen/ohos`。
 *
 * 必需环境（缺了逐条报可执行提示，不猜）：DEVECO_HOME / DEVECO_SDK_HOME / OHOS_HOME。
 * 另：装配前必须 `ohpm install --all`，否则 ArkTS 报 Cannot find module '@ohos-rs/ability'
 *     （本命令在 oh_modules 缺失时自动装一次，可用 autoInstall=false 关掉）。
 *
 * 落档：`.lingqu/hap/<工程>.json`（lingqu/hap/v1）+ `.lingqu/hap/<工程>.log`（hvigor 全文）
 */
public class HapCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        var res = JsonObject()
        if (path.size == 0) {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("t2h:hap 需要参数 path（或设环境变量 LINGQU_SCAN_PATH）"))
            return res
        }
        let tomlPath = cargoTomlPathOf(path)
        if (tomlPath == "") {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("未找到 Cargo.toml（找过 ${path}/src-tauri/Cargo.toml 与 ${path}/Cargo.toml）"))
            return res
        }
        let srcDir = tomlPath[0..(tomlPath.size - "/Cargo.toml".size)]
        let ohosDir = "${srcDir}/gen/ohos"

        // ---- 前置检查：脚手架 / DevEco 位置 ----
        var preflight = ""
        if (!exists(Path("${ohosDir}/build-profile.json5"))) {
            preflight = "找不到鸿蒙工程脚手架 ${ohosDir}/build-profile.json5 —— 先用 `cargo tauri ohos init --ci` 生成，或从工程的 ohos 分支取回 gen/ohos"
        }
        let deveco = devecoHomeOr()
        if (preflight == "" && deveco == "") {
            preflight = "找不到 DevEco Studio：设环境变量 DEVECO_HOME（本机实测 D:\\oh\\DevEcoStudio）"
        }
        let node = "${deveco}/tools/node/node.exe"
        let hvigorJs = "${deveco}/tools/hvigor/bin/hvigorw.js"
        if (preflight == "" && (!exists(Path(node)) || !exists(Path(hvigorJs)))) {
            preflight = "DevEco 里找不到 node/hvigorw.js：${node} / ${hvigorJs}"
        }
        let ohpm = "${deveco}/tools/ohpm/bin/ohpm.bat"
        let ohpmCli = "${deveco}/tools/ohpm/bin/pm-cli.js"
        if (preflight != "") {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString(preflight))
            res.put("ohosDir", JsonString(ohosDir))
            return res
        }

        // ---- 环境变量：父进程没设就从 DEVECO_HOME 推，不让用户逐个 export ----
        // 分隔符必须与宿主一致：hvigor 会校验 DEVECO_SDK_HOME 的值，混合分隔符
        // （D:\oh\DevEcoStudio/sdk）会被判 Illegal value（实测 00303217 Configuration Error）
        // 关键：机器上常见**过期**的环境变量（本机实测 DEVECO_SDK_HOME 仍指着已删除的旧 DevEco），
        // 直接用会让 hvigor 报 00303217 Configuration Error。所以：环境变量值**必须在磁盘上存在**
        // 才采用，否则落到从 DEVECO_HOME 推导的值。
        let sdkHome = hostPath(firstExistingPath([envOr("DEVECO_SDK_HOME", ""), "${deveco}/sdk"]))
        let ohosHome = hostPath(firstExistingPath([envOr("OHOS_HOME", ""), "${sdkHome}/default/openharmony"]))
        if (sdkHome == "" || ohosHome == "") {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("推不出 OHOS SDK 位置：DEVECO_HOME=${deveco}（DEVECO_SDK_HOME/OHOS_HOME 均不存在）"))
            return res
        }
        setVariable("DEVECO_HOME", hostPath(deveco))
        setVariable("DEVECO_SDK_HOME", sdkHome)
        setVariable("OHOS_HOME", ohosHome)

        var phaseLog = ""
        var errMsg = ""
        let autoInstall = argBool(args, "autoInstall", true)
        var installedDeps = false
        if (!exists(Path("${ohosDir}/oh_modules"))) {
            if (!autoInstall) {
                res.put("ok", JsonBool(false))
                res.put("error", JsonString("缺 ${ohosDir}/oh_modules —— 需要先 `ohpm install --all`（或设 autoInstall=true）"))
                return res
            }
            // 0.39.91：**不能直启 ohpm.bat**——Windows 的 CreateProcess 起不来 .bat，
            // 实测报 `Created process failed … The system cannot find the file specified.`，
            // 而文件明明在。改走 node + pm-cli.js（与 hvigor 同款，不经 shell）。
            let launcher = ohpmLauncherOf(hostIsWindows(), exists(Path(node)),
                exists(Path(ohpmCli)), exists(Path(ohpm)))
            if (launcher == "") {
                errMsg = "缺 ohpm：既没有 ${ohpmCli} 也没有 ${ohpm}（DevEco 装全了吗）"
            } else {
                try {
                    let (code, out, errOut) = if (launcher == "node") {
                        executeWithOutput(node, [ohpmCli, "install", "--all"], workingDirectory: Path(ohosDir))
                    } else {
                        executeWithOutput(ohpm, ["install", "--all"], workingDirectory: Path(ohosDir))
                    }
                    phaseLog += "[ohpm install/${launcher}] exit=${code}\n" + lenientUtf8(out) + "\n" + lenientUtf8(errOut) + "\n"
                    installedDeps = code == 0
                    if (code != 0) {
                        errMsg = "ohpm install 失败（exit=${code}）：${firstLines(lenientUtf8(errOut), 3)}"
                    }
                } catch (e: Exception) {
                    errMsg = "ohpm install 起不来（launcher=${launcher}）：${e}"
                }
            }
        }

        // ---- 装配前：把 cargo 交叉编译出来的 .so 拷进 entry/libs/arm64-v8a ----
        //
        // 这一步是 2026-10-31 真机白屏的根因：HAP 里只有 DevEco 模板自带的 libentry.so，
        // 应用自己的 lib<moduleName>.so 从来没被打进去（样本仓把它写成手工 `cp`，
        // 而 hvigorfile 里的 cargo 钩子在 Windows 上早被移除了）。
        // 症状不是"装不上"，而是**装得上、起得来、界面全白**——所以装配链必须自己补这一步。
        var soCopied = ""
        var soSource = ""
        var expectedSo = ""
        var soNote = ""
        if (errMsg == "") {
            // 期望的 .so 名取自 EntryAbility 的 moduleName（真机加载的就是它）
            let entryAbility = "${ohosDir}/entry/src/main/ets/entryability/EntryAbility.ets"
            var moduleName = ""
            if (exists(Path(entryAbility))) {
                try {
                    moduleName = entryModuleNameOf(lenientUtf8(File.readFrom(entryAbility)))
                } catch (e: Exception) {
                    let _ = e
                }
            }
            expectedSo = expectedSoNameOf(moduleName)
            if (expectedSo != "") {
                let relSo = "${releaseDirOf(srcDir, "aarch64-unknown-linux-ohos")}/${expectedSo}"
                soSource = hostPath(relSo)
                if (!exists(Path(soSource))) {
                    errMsg = "找不到交叉编译产物 ${soSource} —— 先点「交叉编译（OHOS）」（t2h:build）再装配"
                } else {
                    let soDir = hostPath("${ohosDir}/entry/libs/arm64-v8a")
                    try {
                        if (!exists(Path(soDir))) {
                            Directory.create(Path(soDir), recursive: true)
                        }
                        let dst = "${soDir}/${expectedSo}"
                        // std.fs 的拷贝是具名参数版本：copy(from, to: ..., overwrite: ...)
                        copy(soSource, to: dst, overwrite: true)
                        soCopied = dst
                        soNote = "${expectedSo} → entry/libs/arm64-v8a"
                        phaseLog += "[copy-so] ${soSource} → ${dst}\n"
                    } catch (e: Exception) {
                        errMsg = "拷贝 .so 失败：${e}"
                    }
                }
            } else {
                soNote = "EntryAbility.ets 里没找到 moduleName，跳过 .so 装配（闸门也不会硬要求）"
                phaseLog += "[copy-so] ${soNote}\n"
            }
        }

        // ---- 签名预检（0.39.11）：包名不一致时**别让 hvigor 白跑三分钟** ----
        //
        // 实测动机：m3u8dl-tauri 的 signingConfigs 指向别的包名的材料，hvigor 跑完只报 00303074；
        // 而这件事在跑之前就能从「AppScope/app.json5 的 bundleName」与「已配 profile 的 bundle-name」
        // 判定出来（判定是纯函数 judgeSignPreflight，见 sign.cj）。
        var pre = SignPreflight()
        var preProjectBundle = ""
        var preProfileBundle = ""
        if (errMsg == "") {
            var hasSignCfg = false
            var cfgProfilePath = ""
            let appJson = "${ohosDir}/AppScope/app.json5"
            if (exists(Path(appJson))) {
                try {
                    preProjectBundle = json5ValueAfter(lenientUtf8(File.readFrom(appJson)), "bundleName")
                } catch (e: Exception) {
                    let _ = e
                }
            }
            let bp = "${ohosDir}/build-profile.json5"
            if (exists(Path(bp))) {
                try {
                    let proj = parseProjSigning(lenientUtf8(File.readFrom(bp)))
                    hasSignCfg = proj.hasSigningConfigs && proj.signingConfigName != ""
                    cfgProfilePath = resolveProjectPath(proj.profilePath, ohosDir)
                } catch (e: Exception) {
                    let _ = e
                }
            }
            let profileOK = cfgProfilePath != "" && exists(Path(cfgProfilePath))
            if (profileOK) {
                preProfileBundle = profileBundleOf(cfgProfilePath)
            }
            pre = judgeSignPreflight(hasSignCfg, profileOK, preProjectBundle, preProfileBundle)
            phaseLog += "[sign-preflight] block=${pre.block} project=${preProjectBundle} " +
                "profile=${preProfileBundle} reason=${pre.reason}\n"
            if (pre.block) {
                errMsg = "签名预检未通过（未跑 hvigor，省一次分钟级白等）：${pre.reason}"
            }
        }

        // ---- hvigor assembleHap ----
        var hvigorText = ""
        if (errMsg == "") {
            try {
                // 注意：argv 第一个元素必须是 hvigorw.js 的路径——漏了它 node 会把
                // --mode 当成自己的选项（实测 `bad option: --mode`，exit=9）
                let argv = [hvigorJs, "--mode", "module", "-p", "product=default", "assembleHap", "--no-daemon"]
                let (code, out, errOut) = executeWithOutput(node, argv, workingDirectory: Path(ohosDir))
                hvigorText = lenientUtf8(out) + "\n" + lenientUtf8(errOut)
                phaseLog += "[hvigor] exit=${code}\n"
            } catch (e: Exception) {
                errMsg = "hvigor 起不来：${e}"
            }
        }
        let hv = parseHvigorOutput(hvigorText)

        // ---- 找产物 + 死资源校验 ----
        let outDir = "${ohosDir}/entry/build/default/outputs/default"
        let signedPath = "${outDir}/entry-default-signed.hap"
        let unsignedPath = "${outDir}/entry-default-unsigned.hap"
        var hapPath = ""
        if (exists(Path(signedPath))) {
            hapPath = signedPath
        } else if (exists(Path(unsignedPath))) {
            hapPath = unsignedPath
        }
        var hapBytes: Int64 = 0
        var entries = HapEntries()
        var readError = ""
        if (hapPath != "") {
            try {
                let data = File.readFrom(hapPath)
                hapBytes = Int64(data.size)
                entries = scanHapEntries(data)
            } catch (e: Exception) {
                readError = "读 HAP 失败：${e}"
            }
        }

        let gateReports = ArrayList<GateReport>()
        gateReports.add(checkHapGate(hv.built, entries.hasModuleJson, entries.hasArm64So, entries.rawfileCount,
            expectedSo, hapHasSo(entries, expectedSo)))
        // 签名根因（00303074 / 00303107）：光有「assembleHap 没成功」不指路，把 hvigor 里
        // 真正的原因翻成人话进闸门（纯函数，见 gates.cj 的 hapSignHint）
        let signHint = hapSignHint(hvigorText)
        if (signHint != "") {
            let hintRep = GateReport()
            hintRep.fail(signHint)
            gateReports.add(hintRep)
            phaseLog += "[sign-hint] ${signHint}\n"
        }
        // 预检的提示也要进闸门：没拦下（材料缺文件）不代表没问题，得让人看见
        if (pre.reason != "" && !pre.block) {
            let preRep = GateReport()
            preRep.fail("HAP 闸（签名预检）：${pre.reason}")
            gateReports.add(preRep)
        } else if (pre.block) {
            let preRep = GateReport()
            preRep.fail("HAP 闸（签名预检，已拦下）：${pre.reason}")
            gateReports.add(preRep)
        }
        let gates = mergeGates(gateReports)

        var outError = ""
        var outJson = ""
        var outLog = ""
        let safeName = sanitizeFileName(projectNameOf(path))
        try {
            // 落档跟着工程走（0.38.0）
            let hDir = lqDirOf(path) + cjhPathSep() + "hap"
            ensureDirOf(hDir)
            outJson = hDir + cjhPathSep() + safeName + ".json"
            outLog = hDir + cjhPathSep() + safeName + ".log"
            File.writeTo(outLog, (phaseLog + hvigorText).toArray())
            var root = JsonObject()
            root.put("schema", JsonString("lingqu/hap/v1"))
            root.put("project", JsonString(safeName))
            root.put("ohosDir", JsonString(ohosDir))
            root.put("built", JsonBool(hv.built))
            root.put("errorCount", JsonInt(hv.errorCount))
            root.put("firstError", JsonString(hv.firstError))
            root.put("signed", JsonBool(exists(Path(signedPath))))
            root.put("hapPath", JsonString(hapPath))
            root.put("hapBytes", JsonInt(hapBytes))
            root.put("entries", entries.toJson())
            root.put("gates", gates.toJson())
            root.put("signPreflight", pre.toJson())
            root.put("installedDeps", JsonBool(installedDeps))
            root.put("expectedSo", JsonString(expectedSo))
            root.put("soCopied", JsonString(soCopied))
            root.put("soSource", JsonString(soSource))
            root.put("soNote", JsonString(soNote))
            File.writeTo(outJson, root.toJsonString().toArray())
        } catch (e: Exception) {
            outError = "落档失败：${e}"
        }

        res.put("signPreflightBlock", JsonBool(pre.block))
        res.put("signPreflightReason", JsonString(pre.reason))
        res.put("projectBundle", JsonString(preProjectBundle))
        res.put("profileBundle", JsonString(preProfileBundle))
        res.put("ok", JsonBool(errMsg == "" && outError == "" && gates.passed))
        res.put("ohosDir", JsonString(ohosDir))
        res.put("built", JsonBool(hv.built))
        res.put("errorCount", JsonInt(hv.errorCount))
        res.put("firstError", JsonString(hv.firstError))
        res.put("hapPath", JsonString(hapPath))
        res.put("hapBytes", JsonInt(hapBytes))
        res.put("signed", JsonBool(exists(Path(signedPath))))
        res.put("entries", entries.toJson())
        res.put("gates", gates.toJson())
        res.put("installedDeps", JsonBool(installedDeps))
        res.put("expectedSo", JsonString(expectedSo))
        res.put("soCopied", JsonString(soCopied))
        res.put("soSource", JsonString(soSource))
        res.put("soNote", JsonString(soNote))
        res.put("outJson", JsonString(outJson))
        res.put("outLog", JsonString(outLog))
        var em = errMsg
        if (em == "") {
            em = outError
        }
        if (em == "") {
            em = readError
        }
        if (em == "" && !hv.built) {
            em = if (hv.firstError != "") { hv.firstError } else { firstLines(hvigorText, 5) }
        }
        res.put("error", JsonString(em))
        eprintln("[lingqu][hap] ${safeName} built=${hv.built} errors=${hv.errorCount} " +
            "rawfile=${entries.rawfileCount} so=${expectedSo} gates=${gates.passed}")
        return res
    }
}

/**
 * t2h:sign —— 真机签名体检（T5-5 真机部署链的前置判定，0.18.0）。
 *
 * 解决的具体痛点（2026-10-31 真机实测）：`hvigor assembleHap` 即使没配签名也会产出
 * `entry-default-signed.hap`，而 `hdc install` 却报 `9568322 signature verification failed
 * due to not trusted app source`——"有 signed 文件"≠"能装"。真正的判据是：
 * **profile 的 device-ids 里有没有本机 UDID**，而这一条完全可以离线判定（见 sign.cj）。
 *
 * 本命令做四件事（全部落盘，不静默）：
 *   ① `hdc shell bm get --udid` 取本机 UDID（hdc 定位不到就如实说"没找到"）
 *   ② 解析工程 `build-profile.json5`（JSON5）的 signingConfigs 与 products.signingConfig
 *   ③ 扫 `~/.ohos/config` 下所有 `.p7b`，解析出 type/bundle/device-ids（不需要账号、不需要联网）
 *   ④ `judgeSign()` 给结论 + **可执行的下一步**（抄回哪份材料 / 去 DevEco 自动签 / 切 debug）
 *
 * 落档：`.lingqu/sign/<工程>.json`（lingqu/sign/v1）+ `.log`（hdc 原始输出与扫描明细）
 */
/**
 * 后台登录入口（0.39.82）：立刻返回 `{ok, started|already}`，登录页地址由
 * `t2h:sign_login_status` 轮询回投。
 *
 * 为什么不复用 `t2h:sign --login`：那条是**阻塞**的（起本机回调 + 等人点浏览器，
 * 最长 5 分钟），一跑就把整个 IPC 命令面堵住——页面连"正在等你登录"都刷不出来（§4-68）。
 * 用户实测的原话就是「没有提示让我访问网页登录呀」。
 */
public class SignLoginCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        let openBrowser = !argBool(args, "noBrowser", false)
        return startSignLogin(openBrowser)
    }
}

/** 登录进度查询（只读、不联网）：界面每 1 秒问一次，拿到 URL 就给可点链接 */
public class SignLoginStatusCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, _: JsonObject, _: IpcContext): JsonValue {
        return signLoginStatusJson()
    }
}

/**
 * 在系统浏览器打开一个链接（0.39.82，用户提的："能否在 UI 里跳转到网页登录链接"）。
 *
 * 为什么不让页面直接 `<a target="_blank">`：界面跑在 WebView2 / ArkWeb 里，
 * 新窗口请求**不保证**能唤起系统浏览器（有的宿主直接拦掉，用户点了没反应——
 * 那比没有链接更糟：他会以为登录坏了）。所以链接统一走这条命令，交给系统默认浏览器。
 *
 * 安全边界：只放行 http/https，且**不做 shell 拼接**——`openUrlInBrowser` 按 argv 传参，
 * §4-80 那类「`cmd /c start` 把 `&` 当命令分隔符、URL 被截断」的坑不会重现。
 * 非 http(s) 一律拒绝，免得被拿来打开本地文件/命令。
 */
public class OpenUrlCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        let url = argStr(args, "url", "").trimAscii()
        let o = JsonObject()
        // 注意：`||` 不能写在行首——编译器会报 "possibly confusing line terminator"
        // （零警告是硬门禁），所以拆成两个变量再合并。
        let okLower = url.startsWith("http://") || url.startsWith("https://")
        let okUpper = url.startsWith("HTTP://") || url.startsWith("HTTPS://")
        let okScheme = okLower || okUpper
        if (!okScheme) {
            o.put("ok", JsonBool(false))
            o.put("error", JsonString("只允许 http/https 链接（收到：${url}）"))
            return o
        }
        let msg = openUrlInBrowser(url)
        o.put("ok", JsonBool(msg.size == 0))
        o.put("url", JsonString(url))
        o.put("error", JsonString(msg))
        return o
    }
}

public class SignCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        // ---- 路线 A 的入口：`--login`（或 LINGQU_SIGN_LOGIN=1）只做 AGC 登录并落盘令牌 ----
        //
        // 为什么单列一条：登录要起本机回调服务 + 等人点浏览器（最长 5 分钟），
        // 与"体检"的秒级语义完全不同；混在一起会让体检这条快路径被拖住。
        //
        // ⚠ 只有 SignCommand 该有这段：它让**当前命令**变成"只去登录、别的事都不干"。
        // 0.39.114 实测扫出另外 10 个 handler（scan/decisions/ai_brief/port/revert/deps/
        // build/hap/migrate/autoport_start）里逐字粘了同一段——只要环境里有
        // `LINGQU_SIGN_LOGIN=1`，这些命令就全变成"去登录并返回登录结果"（§4-167 同族：
        // 能力复制粘贴到不相干命令上，表现为命令被静默劫持）。
        // 需要登录就用 `lingqu-cli sign --login`，别在别的命令里加这条分支。
        if (argBool(args, "login", false) || envOr("LINGQU_SIGN_LOGIN", "") == "1") {
            let timeoutSec = argInt(args, "timeout", 300)
            let noBrowser = argBool(args, "noBrowser", false) || envOr("LINGQU_SIGN_NO_BROWSER", "") == "1"
            let outc = agcLogin(timeoutSec, !noBrowser)
            var res2 = JsonObject()
            res2.put("ok", JsonBool(outc.ok))
            res2.put("user", JsonString(agcUserLine(outc)))
            res2.put("userId", JsonString(outc.userId))
            res2.put("userName", JsonString(outc.userName))
            res2.put("countryCode", JsonString(outc.countryCode))
            res2.put("isRealName", JsonBool(outc.isRealName))
            res2.put("teamId", JsonString(outc.teamId))
            res2.put("teamName", JsonString(outc.teamName))
            res2.put("teamCount", JsonInt(outc.teamCount))
            res2.put("port", JsonInt(outc.port))
            res2.put("tokenSaved", JsonBool(loadAgcToken().isSome()))
            res2.put("error", JsonString(outc.error))
            eprintln("[lingqu][sign:login] ok=${outc.ok} uid=${outc.userId} team=${outc.teamId} " +
                "teams=${outc.teamCount} err=${outc.error}")
            return res2
        }
        // ---- action=load（0.39.114）：只回读 `.lingqu/sign/<工程>.json` ----
        // 纯读盘：不跑 hdc、不扫 ~/.ohos/config、不重新体检（体检要连设备，秒级变十秒级，
        // 且得到的是"现在这一刻"的结论，与落档可能不同）。
        if (argStr(args, "action", "") == "load") {
            var lp = argStr(args, "path", "")
            if (lp.size == 0) {
                lp = envOr("LINGQU_SCAN_PATH", "")
            }
            if (lp.size == 0) {
                lp = envOr("LINGQU_BUILD_PATH", "")
            }
            return signRecordResponse(lp)
        }
        // ---- `--checkMaterial`（0.39.114）：证书 / .p12 / profile 是不是"一套"（纯读盘、秒级） ----
        //
        // 这条链上"签 HAP 用的证书 ≠ profile 绑的证书"**没有任何环节会报错**，
        // 只有装机回 9568322 或 hvigor 报 11111002 才知道（§4-165）。下面几步全是读文件，
        // 一秒内给结论——比等 hvigor 跑三分钟便宜得多（§4-77）。
        if (argBool(args, "checkMaterial", false) || argBool(args, "check-material", false) ||
            envOr("LINGQU_SIGN_CHECK_MATERIAL", "") == "1") {
            return signMaterialCheckResponse(argStr(args, "path", ""))
        }
        // ---- `--reencrypt`：用本机 material/ 重新加密 build-profile 里的口令密文 ----
        //
        // 用途：① 证明我们的 AesGcmKit 实现与 hvigor 逐字节兼容（把密文换成我们造的，让 hvigor 去解）；
        //      ② `material/` 被重建后，旧密文会失效，需要按同一口令重新加密。
        // 做法保守：读原口令 → 解出来 → 用**新 IV** 重新加密 → 写回（先留 .bak），任一步失败都不动原文件。
        if (argBool(args, "reencrypt", false) || envOr("LINGQU_SIGN_REENCRYPT", "") == "1") {
            var res3 = JsonObject()
            let bpPath = argStr(args, "buildProfile", "")
            if (bpPath == "" || !exists(Path(bpPath))) {
                res3.put("ok", JsonBool(false))
                res3.put("error", JsonString("要给 build-profile.json5 的路径（--buildProfile）"))
                return res3
            }
            let cfgDir = ohosConfigDir()
            let mdir = materialDirOfConfig(cfgDir)
            let (workKey, e1) = loadWorkKey(mdir)
            if (e1 != "") {
                res3.put("ok", JsonBool(false))
                res3.put("error", JsonString("读 material/ 失败：${e1}（material 目录：${mdir}）"))
                return res3
            }
            var origin = ""
            try {
                origin = lenientUtf8(File.readFrom(bpPath))
            } catch (e: Exception) {
                res3.put("ok", JsonBool(false))
                res3.put("error", JsonString("读 ${bpPath} 失败：${e}"))
                return res3
            }
            let m = signingMaterialOf(origin)
            if (m.storePassword == "") {
                res3.put("ok", JsonBool(false))
                res3.put("error", JsonString("工程里没有 storePassword（未配 signingConfigs？）"))
                return res3
            }
            let (pwd, e2) = decryptPasswordHex(workKey, m.storePassword)
            if (e2 != "") {
                res3.put("ok", JsonBool(false))
                res3.put("error", JsonString("解 storePassword 失败：${e2}"))
                return res3
            }
            let (pwd2, e3) = decryptPasswordHex(workKey, m.keyPassword)
            if (e3 != "") {
                res3.put("ok", JsonBool(false))
                res3.put("error", JsonString("解 keyPassword 失败：${e3}"))
                return res3
            }
            let (newStore, e4) = encryptPasswordHex(workKey, pwd)
            if (e4 != "") {
                res3.put("ok", JsonBool(false))
                res3.put("error", JsonString("重加密 storePassword 失败：${e4}"))
                return res3
            }
            let (newKey, e5) = encryptPasswordHex(workKey, pwd2)
            if (e5 != "") {
                res3.put("ok", JsonBool(false))
                res3.put("error", JsonString("重加密 keyPassword 失败：${e5}"))
                return res3
            }
            var out = origin
            out = out.replace(m.storePassword, newStore)
            out = out.replace(m.keyPassword, newKey)
            if (out == origin) {
                res3.put("ok", JsonBool(false))
                res3.put("error", JsonString("替换失败：原文里没找到原口令密文（格式可能变了）"))
                return res3
            }
            let bak = "${bpPath}.lingqu-reencrypt.bak"
            var outError = ""
            try {
                File.writeTo(bak, origin.toArray())
                File.writeTo(bpPath, out.toArray())
            } catch (e: Exception) {
                outError = "写回失败：${e}"
            }
            res3.put("ok", JsonBool(outError == ""))
            res3.put("buildProfile", JsonString(bpPath))
            res3.put("backup", JsonString(bak))
            res3.put("storePwdLen", JsonInt(Int64(pwd.size)))       // 只回长度，不回明文
            res3.put("keyPwdLen", JsonInt(Int64(pwd2.size)))
            res3.put("newStorePasswordPrefix", JsonString(if (newStore.size > 12) { newStore[0..12] } else { newStore }))
            res3.put("error", JsonString(outError))
            eprintln("[lingqu][sign:reencrypt] ok=${outError == ""} bp=${bpPath} storePwdLen=${pwd.size}")
            return res3
        }
        // ---- `--tool-check`：自检自动签名依赖的外部工具（java / hap-sign-tool.jar / hdc） ----
        // 为什么单列：这三样缺任何一样，"全新材料"那条路就跑不动，而它们都在**别人的安装目录**里。
        // 与其在关键路径上撞墙，不如先 1 秒说清"有没有、在哪、能不能真生成一对密钥"。
        if (argBool(args, "toolCheck", false) || envOr("LINGQU_SIGN_TOOLCHECK", "") == "1") {
            var res5 = JsonObject()
            let javaHome = envOr("JAVA_HOME", "")
            let devecoHome = envOr("DEVECO_HOME", "")
            let sdkHome = envOr("DEVECO_SDK_HOME", "")
            let javaExe = firstExisting(javaCandidates(javaHome, devecoHome))
            let jar = firstExisting(hapSignToolCandidates(sdkHome))
            let hd = hdcPathOr()
            res5.put("javaHome", JsonString(javaHome))
            res5.put("devecoHome", JsonString(devecoHome))
            res5.put("sdkHome", JsonString(sdkHome))
            res5.put("java", JsonString(javaExe))
            res5.put("hapSignToolJar", JsonString(jar))
            res5.put("hdc", JsonString(hd))
            var genOK = false
            var genMsg = ""
            if (javaExe != "" && jar != "") {
                let dir = "${agcTempDir()}/lingqu-sign-toolcheck"
                try {
                    Directory.create(Path(dir), recursive: true)
                } catch (e: Exception) {
                    let _ = e
                }
                let p12 = "${dir}/probe.p12"
                let csr = "${dir}/probe.csr"
                let pwd = randomPasswordAlnum()
                let kp = genKeypair(javaExe, jar, p12, pwd, dir)
                if (!kp.ok) {
                    genMsg = "generate-keypair 失败：${kp.error}"
                } else {
                    let c2 = genCsr(javaExe, jar, p12, pwd, csr, dir)
                    if (!c2.ok) {
                        genMsg = "generate-csr 失败：${c2.error}"
                    } else {
                        genOK = exists(Path(p12)) && exists(Path(csr))
                        genMsg = if (genOK) { "生成密钥对与 CSR 成功（${p12}）" } else {
                            "命令成功但产物缺失"
                        }
                    }
                }
                res5.put("probeDir", JsonString(dir))
            } else {
                genMsg = "java 或 hap-sign-tool.jar 缺失，跳过生成尝试"
            }
            res5.put("generated", JsonBool(genOK))
            res5.put("generateMessage", JsonString(genMsg))
            res5.put("ok", JsonBool(javaExe != "" && jar != "" && hd != "" && genOK))
            eprintln("[lingqu][sign:toolcheck] java=${javaExe} jar=${jar} hdc=${hd} gen=${genOK}")
            return res5
        }
        // ---- `--auto`：自动签名全流程（需要先 `--login` 过） ----
        //
        // 一条命令把「设备 → 证书 → 新包名 profile → 按 DevEco 命名落盘 → 写 build-profile」跑完。
        // 属于**长任务**（要跑 hvigor 之外的多步网络 + java），但每一步都是秒级到十几秒，
        // 不像一键迁移那样分钟级，所以这里同步返回（CLI/agent 都适用）；界面侧另走后台轮询。
        if (argBool(args, "auto", false) || envOr("LINGQU_SIGN_AUTO", "") == "1") {
            var res4 = JsonObject()
            let projPath = argStr(args, "path", "")
            if (projPath == "") {
                res4.put("ok", JsonBool(false))
                res4.put("error", JsonString("要给工程路径（--path）"))
                return res4
            }
            let tomlPath = cargoTomlPathOf(projPath)
            if (tomlPath == "") {
                res4.put("ok", JsonBool(false))
                res4.put("error", JsonString("${projPath} 不像 Tauri 工程（找不到 src-tauri/Cargo.toml）"))
                return res4
            }
            let srcDir = tomlPath[0..(tomlPath.size - "/Cargo.toml".size)]
            let ohosDir = hostPath("${srcDir}/gen/ohos")
            let bp = "${ohosDir}/build-profile.json5"
            if (!exists(Path(bp))) {
                res4.put("ok", JsonBool(false))
                res4.put("error", JsonString("找不到 ${bp}（先跑 `cargo tauri ohos init`）"))
                return res4
            }
            // bundleName：AppScope/app.json5
            var bundle = ""
            let appJson = "${ohosDir}/AppScope/app.json5"
            if (exists(Path(appJson))) {
                try {
                    bundle = json5ValueAfter(lenientUtf8(File.readFrom(appJson)), "bundleName")
                } catch (e: Exception) {
                    let _ = e
                }
            }
            if (bundle == "") {
                res4.put("ok", JsonBool(false))
                res4.put("error", JsonString("读不到 ${appJson} 里的 bundleName"))
                return res4
            }
            // 设备：UDID + deviceType
            let hdc = hdcPathOr()
            if (hdc == "") {
                res4.put("ok", JsonBool(false))
                res4.put("error", JsonString("找不到 hdc（设 DEVECO_HOME / DEVECO_SDK_HOME）"))
                return res4
            }
            var udid = envOr("LINGQU_SIGN_UDID", "")
            var deviceType = "4"
            if (udid == "") {
                try {
                    let (_, out, errOut) = executeWithOutput(hdc, ["shell", "bm", "get", "--udid"])
                    udid = parseUdid(lenientUtf8(out) + "\n" + lenientUtf8(errOut))
                } catch (e: Exception) {
                    let _ = e
                }
            }
            if (udid == "") {
                res4.put("ok", JsonBool(false))
                res4.put("error", JsonString("拿不到设备 UDID（设备没连？）"))
                return res4
            }
            try {
                let (_, out2, errOut2) = executeWithOutput(hdc,
                    ["shell", "getprop", "hw_sc.build.os.deviceType"])
                deviceType = deviceTypeOf(String.fromUtf8(out2) + "\n" + String.fromUtf8(errOut2))
            } catch (e: Exception) {
                let _ = e
            }
            // 令牌
            let tokOpt = loadAgcToken()
            var token = AgcLoginOutcome()
            match (tokOpt) {
                case Some(v) => token = v
                case None =>
                    res4.put("ok", JsonBool(false))
                    res4.put("error", JsonString("还没有登录令牌：先跑 `lingqu-cli sign --login` 完成一次浏览器授权"))
                    return res4
            }
            let inp = AutoSignInput()
            inp.configDir = ohosConfigDir()
            inp.product = argStr(args, "product", "default")
            inp.projectRoot = ohosDir
            inp.bundleName = bundle
            inp.buildProfile = bp
            inp.udid = udid
            inp.deviceType = deviceType
            // `--newKeys`：丢掉本地旧材料、重新生成密钥对与自己掌握口令的 .p12。
            // 什么时候要它：材料是从别处拷来的 / `material/` 重建过 —— 旧 .p12 的口令无人知道，
            // 密文解不开就没法用本机 workKey 重加密，hvigor 必然报 00303242。
            inp.forceNewKeys = argBool(args, "newKeys", false) || envOr("LINGQU_SIGN_NEWKEYS", "") == "1"
            let result = autoSign(inp, token)
            res4 = result.toJson()
            res4.put("bundleName", JsonString(bundle))
            res4.put("udid", JsonString(udid))
            res4.put("deviceType", JsonString(deviceType))
            eprintln("[lingqu][sign:auto] ok=${result.ok} bundle=${bundle} cert=${result.certName} " +
                "newKeys=${inp.forceNewKeys} err=${result.error}")
            // 0.39.91 现场实测缺口：`--auto` 成功也**必须落档**。之前这条分支只 return 结果，
            // `.lingqu/sign/` 里留着几小时前的旧档 ⇒ 报告判「8 步完成 7/8」、nextStep 仍指 sign，
            // 界面/断点板看到的和事实相反（§4-136 同族：证据没落地等于没发生）。
            try {
                let autoName = sanitizeFileName(projectNameOf(projPath))
                let sgDir2 = lqDirOf(projPath) + cjhPathSep() + "sign"
                ensureDirOf(sgDir2)
                var root3 = JsonObject()
                root3.put("schema", JsonString("lingqu/sign/v1"))
                root3.put("project", JsonString(autoName))
                root3.put("ohosDir", JsonString(ohosDir))
                root3.put("buildProfile", JsonString(bp))
                root3.put("udid", JsonString(udid))
                root3.put("projectBundle", JsonString(bundle))
                root3.put("by", JsonString("auto"))
                // 「这份结论是哪一代的」：回读要靠它说清"旧档 vs 现状"（§4-109 / §4-133）
                root3.put("generatedAt", JsonInt(DateTime.now().toUnixTimeStamp().toMilliseconds()))
                root3.put("ok", JsonBool(result.ok))
                if (!result.ok) {
                    root3.put("error", JsonString(result.error))
                    root3.put("nextStep", JsonString(
                        "重跑 `lingqu-cli sign --login` 换新令牌后 `sign --auto --path .`；" +
                        "材料口令解不开时加 `--newKeys`"))
                }
                var modeObj = JsonObject()
                modeObj.put("mode", JsonString(if (result.ok) { "auto" } else { "auto-failed" }))
                modeObj.put("modeLabel", JsonString(if (result.ok) { "自动签" } else { "自动签失败" }))
                modeObj.put("canInstallDevice", JsonBool(result.ok))
                root3.put("mode", modeObj)
                root3.put("autoSign", res4)
                File.writeTo(sgDir2 + cjhPathSep() + "${autoName}.json", root3.toJsonString().toArray())
            } catch (e: Exception) {
                let _ = e
                eprintln("[lingqu][sign:auto] 落档写入失败（工程里没有 .lingqu？）：${e}")
            }
            return res4
        }
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        if (path.size == 0) {
            path = envOr("LINGQU_BUILD_PATH", "")
        }
        var res = JsonObject()

        // ---- 工程位置（缺 path 时仍做"设备 + 本机材料"体检，给的是通用结论） ----
        var ohosDir = ""
        var projName = "unknown"
        if (path.size > 0) {
            projName = sanitizeFileName(projectNameOf(path))
            let tomlPath = cargoTomlPathOf(path)
            if (tomlPath != "") {
                let srcDir = tomlPath[0..(tomlPath.size - "/Cargo.toml".size)]
                ohosDir = hostPath("${srcDir}/gen/ohos")
            }
        }

        // ---- ① 本机 UDID ----
        let hdc = hdcPathOr()
        var udid = ""
        var hdcLog = ""
        if (hdc == "") {
            hdcLog = "[hdc] 没找到 hdc（找过 OHOS_HOME / DEVECO_SDK_HOME / DEVECO_HOME 下的 toolchains）"
        } else {
            try {
                let (code, out, errOut) = executeWithOutput(hdc, ["shell", "bm", "get", "--udid"])
                let text = lenientUtf8(out) + "\n" + lenientUtf8(errOut)
                hdcLog = "[hdc shell bm get --udid] ${hdc} exit=${code}\n${text}"
                // 注意：hdc 失败时退出码仍是 0（AGENTS §4-40），UDID 只能按输出文本判
                udid = parseUdid(text)
            } catch (e: Exception) {
                hdcLog = "[hdc] 起不来：${e}"
            }
        }

        // 探针：显式指定 UDID（设备离线/无设备机器上复跑取证用；日志里标明来源，不当成 hdc 实测）
        let udidOverride = envOr("LINGQU_SIGN_UDID", "")
        if (udidOverride != "") {
            udid = udidOverride.trimAscii()
            hdcLog += "[udid/override] LINGQU_SIGN_UDID=${udid}（探针覆盖，非 hdc 实测）\n"
        }

        // ---- ② 工程签名配置（build-profile.json5 是 JSON5，用轻量提取） ----
        let buildProfile = if (ohosDir == "") { "" } else { hostPath("${ohosDir}/build-profile.json5") }
        var projText = ""
        var buildProfileError = ""
        if (buildProfile != "" && exists(Path(buildProfile))) {
            try {
                projText = lenientUtf8(File.readFrom(buildProfile))
            } catch (e: Exception) {
                buildProfileError = "读不到 ${buildProfile}：${e}"
            }
        } else if (buildProfile != "") {
            buildProfileError = "找不到 ${buildProfile}（还没生成鸿蒙脚手架？）"
        }
        let proj = parseProjSigning(projText)
        var certPath = resolveProjectPath(proj.certPath, ohosDir)
        var storeFile = resolveProjectPath(proj.storeFile, ohosDir)
        var profilePath = resolveProjectPath(proj.profilePath, ohosDir)
        var filesExist = false
        if (certPath != "" && storeFile != "" && profilePath != "") {
            filesExist = exists(Path(certPath)) && exists(Path(storeFile)) && exists(Path(profilePath))
        }

        // 工程配的那份 profile 解析（判定"含不含本机 UDID"的关键）
        let configured = OhosProfile()
        if (profilePath != "" && exists(Path(profilePath))) {
            try {
                let raw = latin1Of(File.readFrom(profilePath))
                let parsed = parseOhosProfile(extractProfileJson(raw), profilePath)
                configured.profileType = parsed.profileType
                configured.bundleName = parsed.bundleName
                configured.parseError = parsed.parseError
                for (d in parsed.deviceIds) {
                    configured.deviceIds.add(d)
                }
            } catch (e: Exception) {
                configured.parseError = "读 profile 失败：${e}"
            }
        }

        // ---- ③ 本机候选材料（~/.ohos/config/*.p7b） ----
        let home = firstNonEmpty([envOr("USERPROFILE", ""), envOr("HOME", "")])
        let configDir = if (home == "") { "" } else { hostPath("${home}/.ohos/config") }
        var cands = ArrayList<OhosProfile>()
        if (configDir != "") {
            cands = discoverProfiles(configDir)
            // 分隔符归一到宿主形式（`C:\...\config/xxx.p7b` 这种混写看着像 bug，也容易被人误抄）
            for (p in cands) {
                p.p7bPath = hostPath(p.p7bPath)
            }
        }
        // 工程包名（AppScope/app.json5）：优先挑**包名也对得上**的候选材料，
        // 否则会把别的工程的 profile（同样含本机 UDID）误报成"可用材料"。
        var bundleName = ""
        let appJson = if (ohosDir == "") { "" } else { hostPath("${ohosDir}/AppScope/app.json5") }
        if (appJson != "" && exists(Path(appJson))) {
            try {
                bundleName = json5ValueAfter(lenientUtf8(File.readFrom(appJson)), "bundleName")
            } catch (e: Exception) {
                let _ = e
            }
        }
        var candidatePath = ""
        var candidateBundle = ""
        match (pickProfile(cands, udid, bundleName)) {
            case Some(p) =>
                candidatePath = p.p7bPath
                candidateBundle = p.bundleName
            case None => match (pickProfile(cands, udid, "")) {
                case Some(p) =>
                    candidatePath = p.p7bPath
                    candidateBundle = p.bundleName
                case None => ()
            }
        }

        // ---- ④ 判定 ----
        var hasConfig = proj.hasSigningConfigs && proj.signingConfigName != ""
        var outProfileType = configured.profileType
        var outAllowsDevice = configured.allows(udid)
        // 包名门槛（0.39.9）：profile 是按包名签发的，候选材料包名不等于工程 bundleName 时
        // **不能**建议"抄回来"——hvigor 在 SignHap 会报 00303074（实测）。见 sign.cj 的注
        let census = profileBundleCensus(cands, udid)
        let base = judgeSign(hasConfig, filesExist, configured.allows(udid), configured.profileType,
            udid, candidatePath != "")
        let check = judgeSignForWriteback(base, bundleName, candidateBundle, census)
        check.configuredName = proj.signingConfigName

        // ---- ⑤ 写回签名配置（apply=true / LINGQU_SIGN_APPLY=1）----
        //
        // 这是把"体检工具"变成"省事工具"的一步：工程没配签名时，直接把它配好。
        // 关键约束：**口令（storePassword/keyPassword）是 DevEco AesGcmKit 密文，我们无法生成**，
        // 所以只能从"用同一套材料（同一个 .p12 文件名）的其它工程"原样搬过来——材料即身份，
        // 那条规则由 `sameMaterialFile()` 保证。
        // 界面传 apply=true 或置 LINGQU_SIGN_APPLY=1 都算（探针走环境变量；两者取「或」，
        // 这样页面显式传 false 也不会把探针关掉）
        let wantApply = argBool(args, "apply", false) || envOr("LINGQU_SIGN_APPLY", "") == "1"
        var donorPath = argStr(args, "donor", envOr("LINGQU_SIGN_DONOR", ""))
        var applyText = ""          // 写回后的 build-profile.json5（成功时）
        var applySkipped = ""
        var applyError = ""
        var backupPath = ""
        var appliedName = ""
        if (wantApply) {
            if (hasConfig && filesExist) {
                applySkipped = "工程已经配好签名（${proj.signingConfigName}），不需要写回"
            } else if (buildProfile == "") {
                applyError = "找不到工程位置（要传 path 参数）"
            } else if (!exists(Path(buildProfile))) {
                applyError = "找不到 ${buildProfile}（先跑 `cargo tauri ohos init --ci` 生成脚手架）"
            } else if (candidatePath == "") {
                applyError = "机器上没有含本机 UDID 的可用材料，无可写回的内容（先在 DevEco 自动签名一次）"
            } else if (!bundleMatches(bundleName, candidateBundle)) {
                // 写回一份别的包名的材料 = 制造一个 hvigor 必然报 00303074 的配置，
                // 比"没配"更难排查（人会以为是口令/路径问题）。宁可拒绝并说清怎么做。
                applyError = "拒绝写回：本机候选材料的包名是 ${candidateBundle}，与工程包名 ${bundleName} 不一致" +
                    "（hvigor 会报 ${SIGN_BUNDLE_MISMATCH_CODE}）。" +
                    "正解：跑 `lingqu-cli sign --login`（网页登录一次）+ `sign --auto --path .`，让签名服务按本工程包名签发，" +
                    "或把 AppScope/app.json5 的 bundleName 临时改成 ${candidateBundle}（仅本机验证）。" +
                    "本机现有材料的包名：${census}"
            } else {
                // 比对基准必须是 p12（signingConfigs 里的 storeFile 就是 p12）——
                // 拿 .p7b 去比会永远不匹配（实测踩到）
                let (candP12, _) = materialSiblingsOf(candidatePath)
                match (findDonorMaterial(candP12, donorPath)) {
                    case Some(hit) =>
                        donorPath = hit.donorPath
                        let m = hit.material
                        // 材料路径统一取本机这一套（donor 那份可能指向别的目录/旧路径）
                        let (p12, cer) = materialSiblingsOf(candidatePath)
                        m.storeFile = p12
                        m.certpath = cer
                        m.profile = candidatePath
                        appliedName = m.name
                        try {
                            let origin = lenientUtf8(File.readFrom(buildProfile))
                            let (newText, err) = applySigningConfig(origin, m)
                            if (err != "") {
                                applyError = err
                            } else {
                                let sgDir = lqDirOf(path) + cjhPathSep() + "sign"
                                ensureDirOf(sgDir)
                                backupPath = sgDir + cjhPathSep() + "${projName}.build-profile.json5.bak"
                                File.writeTo(backupPath, origin.toArray())
                                File.writeTo(buildProfile, newText.toArray())
                                applyText = newText
                                // 写回完**立刻重新判定**：让界面直接显示"现在可以直装了"，
                                // 而不是让人再点一次体检（判定用的还是同一套材料/UDID）
                                let proj2 = parseProjSigning(newText)
                                hasConfig = proj2.hasSigningConfigs && proj2.signingConfigName != ""
                                // 材料路径与存在性也要按**新配置**重算（旧配置里是空的，
                                // 直接用旧值会误报"材料不存在"——实测踩到）
                                let cert2 = resolveProjectPath(proj2.certPath, ohosDir)
                                let prof2 = resolveProjectPath(proj2.profilePath, ohosDir)
                                let store2 = resolveProjectPath(proj2.storeFile, ohosDir)
                                filesExist = cert2 != "" && prof2 != "" && store2 != "" &&
                                    exists(Path(cert2)) && exists(Path(prof2)) && exists(Path(store2))
                                let type2 = profileTypeOf(prof2)
                                let allows2 = profileAllows(prof2, udid)
                                outProfileType = type2
                                outAllowsDevice = allows2
                                let fresh = judgeSign(hasConfig, filesExist, allows2, type2, udid, true)
                                check.ok = fresh.ok
                                check.reason = fresh.reason
                                check.nextStep = fresh.nextStep
                                check.configuredName = proj2.signingConfigName
                                check.configuredFilesExist = filesExist
                                check.configuredAllowsDevice = allows2
                                // 写回只在包名匹配时发生（上面已拦），所以包名门槛这关算过了
                                check.bundleMatch = true
                            }
                        } catch (e: Exception) {
                            applyError = "写回失败：${e}"
                        }
                    case None =>
                        applyError = "没找到用同一套材料的工程（口令是 DevEco 加密串，只能从已有工程搬）：" +
                            "跑 `lingqu-cli sign --login` + `sign --auto` 重新签一次，或传 donor=<已有工程路径>"
                }
            }
        }

        // ---- ④.5 T5-4 签名两态：当前是哪一态 + 上架前强提醒 ----
        // 本机 release profile 份数直接从已扫到的候选里数（0 份 = 还没做过 release 签名，
        // 这时"切回 release"不是切开关，是要先去 AGC 生成材料——提醒里必须说清）
        var releaseProfileCount: Int64 = 0
        for (p in cands) {
            if (p.profileType == SIGN_MODE_RELEASE && p.parseError == "") {
                releaseProfileCount += 1
            }
        }
        let modeState = assessSignMode(hasConfig, filesExist, outProfileType, releaseProfileCount)

        // ---- 落档（证据：hdc 原文 + 材料明细，供人复核） ----
        var outError = ""
        var outJson = ""
        var outLog = ""
        var logText = hdcLog + "\n"
        logText += "[config] ${configDir}（找到 ${cands.size} 份 .p7b）\n"
        for (p in cands) {
            logText += "[profile] ${p.p7bPath} type=${p.profileType} bundle=${p.bundleName} " +
                "devices=${p.deviceIds.size} allowsLocal=${p.allows(udid)} err=${p.parseError}\n"
        }
        logText += "[project] ${buildProfile}\n"
        logText += "[bundle] project=${bundleName} candidate=${candidateBundle} " +
            "match=${check.bundleMatch}\n"
        logText += "[bundle/census] ${census}\n"
        logText += "[signing] name=${proj.signingConfigName} type=${proj.certType} " +
            "certpath=${certPath} profile=${profilePath} storeFile=${storeFile} filesExist=${filesExist}\n"
        logText += "[verdict] ok=${check.ok} reason=${check.reason}\n"
        logText += "[mode] ${modeState.mode} label=${modeState.modeLabel} canInstall=${modeState.canInstallDevice} " +
            "releaseReady=${modeState.releaseReady} releaseProfiles=${releaseProfileCount}\n"
        logText += "[mode/reminder] ${modeState.reminder}\n"
        if (applyText != "") {
            // 写回后重读一遍：日志里要留"改完之后长什么样"，否则事后只剩一个 applied=true
            let after = parseProjSigning(applyText)
            logText += "[signing/after-apply] name=${after.signingConfigName} type=${after.certType} " +
                "certpath=${after.certPath} profile=${after.profilePath} storeFile=${after.storeFile}\n"
        }
        if (wantApply) {
            logText += "[apply] applied=${applyText != ""} donor=${donorPath} backup=${backupPath} " +
                "skipped=${applySkipped} error=${applyError}\n"
        }
        try {
            let sgDir = lqDirOf(path) + cjhPathSep() + "sign"
            ensureDirOf(sgDir)
            outJson = sgDir + cjhPathSep() + "${projName}.json"
            outLog = sgDir + cjhPathSep() + "${projName}.log"
            File.writeTo(outLog, logText.toArray())
            var root = JsonObject()
            root.put("schema", JsonString("lingqu/sign/v1"))
            root.put("project", JsonString(projName))
            root.put("ohosDir", JsonString(ohosDir))
            root.put("buildProfile", JsonString(buildProfile))
            root.put("buildProfileError", JsonString(buildProfileError))
            root.put("hdc", JsonString(hdc))
            root.put("udid", JsonString(udid))
            root.put("configDir", JsonString(configDir))
            root.put("candidateCount", JsonInt(Int64(cands.size)))
            root.put("candidatePath", JsonString(candidatePath))
            root.put("candidateBundle", JsonString(candidateBundle))
            root.put("projectBundle", JsonString(bundleName))
            root.put("candidateBundleMatch", JsonBool(check.bundleMatch))
            root.put("candidateBundles", JsonString(census))
            // profile 类型与落档时间：回读要能直接给出「debug / release」与「这是哪一代的结论」，
            // 否则界面只能按 mode 猜（§4-133：按落档渲染的快照要有"哪一代"的位）
            root.put("profileType", JsonString(outProfileType))
            root.put("generatedAt", JsonInt(DateTime.now().toUnixTimeStamp().toMilliseconds()))
            var carr = JsonArray()
            for (p in cands) {
                carr.add(p.toJson())
            }
            root.put("profiles", carr)
            root.put("signing", signingJson(proj, certPath, profilePath, storeFile, filesExist))
            root.put("check", check.toJson())
            root.put("mode", modeState.toJson())
            var applyObj = JsonObject()
            applyObj.put("requested", JsonBool(wantApply))
            applyObj.put("applied", JsonBool(applyText != ""))
            applyObj.put("donor", JsonString(donorPath))
            applyObj.put("backup", JsonString(backupPath))
            applyObj.put("configName", JsonString(appliedName))
            applyObj.put("skipped", JsonString(applySkipped))
            applyObj.put("error", JsonString(applyError))
            root.put("apply", applyObj)
            File.writeTo(outJson, root.toJsonString().toArray())
        } catch (e: Exception) {
            outError = "落档失败：${e}"
        }

        // ---- 返回给界面 ----
        res.put("ok", JsonBool(check.ok && outError == ""))
        res.put("udid", JsonString(udid))
        res.put("hdc", JsonString(hdc))
        res.put("reason", JsonString(check.reason))
        res.put("nextStep", JsonString(check.nextStep))
        res.put("hasConfig", JsonBool(hasConfig))
        res.put("filesExist", JsonBool(filesExist))
        res.put("allowsDevice", JsonBool(outAllowsDevice))
        res.put("profileType", JsonString(outProfileType))
        res.put("signingName", JsonString(proj.signingConfigName))
        res.put("candidateCount", JsonInt(Int64(cands.size)))
        res.put("candidatePath", JsonString(candidatePath))
        res.put("candidateBundle", JsonString(candidateBundle))
        res.put("projectBundle", JsonString(bundleName))
        res.put("candidateBundleMatch", JsonBool(check.bundleMatch))
        res.put("candidateBundles", JsonString(census))
        res.put("buildProfile", JsonString(buildProfile))
        res.put("applyRequested", JsonBool(wantApply))
        res.put("applied", JsonBool(applyText != ""))
        res.put("applyDonor", JsonString(donorPath))
        res.put("applyBackup", JsonString(backupPath))
        res.put("applySkipped", JsonString(applySkipped))
        res.put("applyError", JsonString(applyError))
        res.put("outJson", JsonString(outJson))
        res.put("outLog", JsonString(outLog))
        // T5-4 签名两态：mode/两态齐备度/强提醒/双向切态步骤
        res.put("mode", JsonString(modeState.mode))
        res.put("modeLabel", JsonString(modeState.modeLabel))
        res.put("canInstallDevice", JsonBool(modeState.canInstallDevice))
        res.put("releaseReady", JsonBool(modeState.releaseReady))
        res.put("signReminder", JsonString(modeState.reminder))
        res.put("installNextStep", JsonString(modeState.installNextStep))
        res.put("releaseNextStep", JsonString(modeState.releaseNextStep))
        res.put("releaseProfileCount", JsonInt(releaseProfileCount))
        var switchArr = JsonArray()
        for (s in modeState.switchSteps) {
            switchArr.add(JsonString(s))
        }
        res.put("switchSteps", switchArr)
        var em = outError
        if (em == "") {
            em = buildProfileError
        }
        if (em == "" && wantApply && applyText == "") {
            em = applyError
        }
        res.put("error", JsonString(em))
        eprintln("[lingqu][sign] ${projName} udid=${udid} ok=${check.ok} candidates=${cands.size} " +
            "hasConfig=${hasConfig} filesExist=${filesExist} mode=${modeState.mode} " +
            "releaseReady=${modeState.releaseReady}")
        return res
    }
}

/** 读一份 `.p7b` 的 profile 类型（读不到返回 ""，不抛） */
func profileTypeOf(p7bPath: String): String {
    if (p7bPath == "" || !exists(Path(p7bPath))) {
        return ""
    }
    try {
        let raw = latin1Of(File.readFrom(p7bPath))
        return parseOhosProfile(extractProfileJson(raw), p7bPath).profileType
    } catch (e: Exception) {
        let _ = e
        return ""
    }
}

/** 这份 `.p7b` 是否允许该 UDID 装机（读不到一律 false：宁可误报"不行"，也不误报"能装"） */
func profileAllows(p7bPath: String, udid: String): Bool {
    if (p7bPath == "" || udid == "" || !exists(Path(p7bPath))) {
        return false
    }
    try {
        let raw = latin1Of(File.readFrom(p7bPath))
        return parseOhosProfile(extractProfileJson(raw), p7bPath).allows(udid)
    } catch (e: Exception) {
        let _ = e
        return false
    }
}

/**
 * 这份 `.p7b` 签给哪个包名（读不到返回 ""）。
 *
 * 0.39.11 起 `t2h:hap` 的签名预检要用它：profile 按包名签发，包名对不上 hvigor 直接 00303074。
 */
func profileBundleOf(p7bPath: String): String {
    if (p7bPath == "" || !exists(Path(p7bPath))) {
        return ""
    }
    try {
        let raw = latin1Of(File.readFrom(p7bPath))
        return parseOhosProfile(extractProfileJson(raw), p7bPath).bundleName
    } catch (e: Exception) {
        let _ = e
        return ""
    }
}

/**
 * t2h:verify —— 证据采集 + 可用率 + 报告导出（P6，0.24.0）。
 *
 * 一条命令把前面几轮的东西串起来：
 *   ① 读落档：`.lingqu/scan`（清单规模）、`.lingqu/build`（编译闸 + 前端指纹）、
 *      `.lingqu/hap`（装配闸）、`.lingqu/deploy`（装 / 启 / 日志）
 *   ② 采真机证据：截图（snapshot_display + file recv 到 `.lingqu/evidence/`）、
 *      faultlog 崩溃计数
 *   ③ 生成清单 + 算可用率 + 渲染三段式报告（纯函数在 `lingqu.verify`）
 *   ④ 落档 `.lingqu/verify/<工程>.json` / `.md` / `.html`
 *
 * 口径（详见 `src/verify/verify.cj` 文件头）：平台限制不计入分母；未采集 ≠ 通过；证据逐项挂。
 * **采不到证据只会让该项变成"未验证"，绝不会变成"通过"**——这是这个命令存在的意义。
 */
public class VerifyCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_VERIFY_PATH", "")
        }
        if (path.size == 0) {
            path = envOr("LINGQU_DEPLOY_PATH", "")
        }
        var projName = "unknown"
        if (path.size > 0) {
            projName = sanitizeFileName(projectNameOf(path))
        }
        // ---- action=load（0.39.88）：只回读验证落档，**不重新采证**（采证要真机 + 分钟级）----
        if (argStr(args, "action", "") == "load") {
            if (path.size == 0) {
                var res0 = JsonObject()
                res0.put("ok", JsonBool(false))
                res0.put("error", JsonString("t2h:verify action=load 需要参数 path（或设环境变量 LINGQU_VERIFY_PATH）"))
                return res0
            }
            return verifyRecordResponse(path)
        }
        let wantShots = argBool(args, "screenshot", true)
        let hdc = hdcPathOr()
        var serial = argStr(args, "serial", "")
        if (serial == "") {
            // 0.39.131：落档里的序列号可能已过期（设备从 USB 换到无线调试后 connect-key 变了），
            // 旧实现直接用落档值 ⇒ 截图/faultlog 三条命令全回「Not match target founded」，
            // 落档却仍写「已保存」（§4-38 过期值盖掉现场）
            serial = resolveDeviceKeyOf(liveHdcTargetsText(hdc), deploySerialOf(projName, path))
        }

        // ① + ② 取数与采证
        let inp = collectVerifyInput(projName, path)
        let ev = collectEvidence(projName, path, hdc, serial, wantShots)
        if (ev.saved > 0) {
            inp.screenshotCount = ev.saved
        }
        inp.crashCount = ev.crashes

        // ③ 清单 / 可用率 / 报告
        let items = buildChecklist(inp)
        let stats = computeStats(items)
        let ctx = ReportContext(projName)
        ctx.bundleName = deployBundleOf(projName, path)
        ctx.deviceSerial = serial
        ctx.generatedAt = nowText()
        let md = renderMarkdown(ctx, items, stats)
        let html = renderHtml(ctx, items, stats)

        // ④ 落档
        var outError = ""
        var outJson = ""
        var outMd = ""
        var outHtml = ""
        var outEvidence = ""
        try {
            let vDir = lqDirOf(path) + cjhPathSep() + "verify"
            ensureDirOf(vDir)
            outJson = vDir + cjhPathSep() + "${projName}.json"
            outMd = vDir + cjhPathSep() + "${projName}.md"
            outHtml = vDir + cjhPathSep() + "${projName}.html"
            File.writeTo(outMd, md.toArray())
            File.writeTo(outHtml, html.toArray())
            var root = JsonObject()
            root.put("schema", JsonString("lingqu/verify/v1"))
            root.put("project", JsonString(projName))
            root.put("bundleName", JsonString(ctx.bundleName))
            root.put("serial", JsonString(serial))
            root.put("stats", stats.toJson())
            var arr = JsonArray()
            for (it in items) {
                arr.add(it.toJson())
            }
            root.put("items", arr)
            File.writeTo(outJson, root.toJsonString().toArray())
            // 采证日志单独落一份，便于核对"截图为什么没采到"
            if (ev.log != "") {
                outEvidence = lqDirOf(path) + cjhPathSep() + "verify" + cjhPathSep() + "${projName}.evidence.log"
                File.writeTo(outEvidence, ev.log.toArray())
            }
        } catch (e: Exception) {
            outError = "落档失败：${e}"
        }

        // 0.39.137：**验收通过（有结论且无 fail）时自动导出一次移植成果**，沉淀到独立目录。
        // 为什么要自动：迁移是原地改样本工程的，成果不冻结就会散在各样本目录里，人找不到也不好提交。
        // 纪律：导出失败**不改写验收结论**（验收是验收、归档是归档），但原因必须回投，不许静默。
        var exportDir = ""
        var exportNote = ""
        if (outError == "" && stats.fail == 0 && stats.covered > 0) {
            let exp = exportProject(path, "verify-pass")
            exportDir = normalizeHostSep(exp.outDir)
            exportNote = if (exp.ok) {
                "验收通过，已自动导出移植成果（${exp.copiedFiles} 个文件）"
            } else {
                "验收通过，但自动导出失败：${exp.error}"
            }
        }

        var res = JsonObject()
        res.put("ok", JsonBool(outError == ""))
        res.put("project", JsonString(projName))
        res.put("screenshots", JsonInt(ev.saved))
        res.put("crashes", JsonInt(ev.crashes))
        res.put("total", JsonInt(stats.total))
        res.put("pass", JsonInt(stats.pass))
        // 功能口径的分子（0.39.88）：`pass` 是全局通过数（含启动/构建等基础设施项），
        // 与 ⑥ 屏那对分母（covered=核心功能项数）不同源。两者一起回投，界面按口径取，
        // 才不会再出现 "通过 7/3" 这种把两套口径混在一起的读数。
        res.put("featurePass", JsonInt(stats.featurePass))
        res.put("fail", JsonInt(stats.fail))
        res.put("limit", JsonInt(stats.limit))
        res.put("unknown", JsonInt(stats.unknown))
        // 核心功能口径（0.39.89）：分母是有结论的项，未测单列——界面必须两者都显示，
        // 只显示一个百分比就等于把"测了 2 项全过"说成"全都可用"。
        res.put("covered", JsonInt(stats.covered))
        res.put("notVerified", JsonInt(stats.notVerified))
        // D-020：分母只认移植验收项；业务功能单列回投，界面据此写"属原应用职责、不计入"
        res.put("transplantTotal", JsonInt(stats.transplantTotal))
        res.put("transplantNotVerified", JsonInt(stats.transplantNotVerified))
        res.put("businessTotal", JsonInt(stats.businessTotal))
        res.put("businessTested", JsonInt(stats.businessTested))
        res.put("businessPass", JsonInt(stats.businessPass))
        res.put("scope", JsonString(stats.scope))
        res.put("scopeNote", JsonString(stats.scopeNote))
        res.put("ratePercent", JsonInt(stats.ratePercent))
        // 自动导出的结果（0.39.137）：空串 = 没触发（未通过）；非空 = 成果目录
        res.put("exportDir", JsonString(exportDir))
        res.put("exportNote", JsonString(exportNote))
        var arr2 = JsonArray()
        for (it in items) {
            arr2.add(it.toJson())
        }
        res.put("items", arr2)
        res.put("md", JsonString(outMd))
        res.put("html", JsonString(outHtml))
        res.put("outJson", JsonString(outJson))
        res.put("evidenceLog", JsonString(outEvidence))
        res.put("error", JsonString(outError))
        // 分子分母必须同源：全局 pass（含启动/构建等基础设施项）配功能分母会写成 "6/5"。
        // 功能口径用 featurePass/covered，全局口径单独写 pass，读的人一眼能分清。
        eprintln("[lingqu][verify] ${projName} feature=${stats.featurePass}/${stats.covered} " +
            "scope=${stats.scope} pass=${stats.pass} " +
            "limit=${stats.limit} unknown=${stats.unknown} notVerified=${stats.notVerified} rate=${stats.ratePercent}%")
        return res
    }
}

/**
 * t2h:resume —— 断点续迁（T6-5，0.26.0）。
 *
 * 迁移是 8 步的一条链（扫描 → 依赖 → 改造 → 编译 → 装配 → 签名 → 部署 → 验证），
 * 中间任何一步都可能因为"缺签名材料 / 真机没插 / 人工吃饭去了"停下来。
 * 这条命令把"上次停在哪、下一步做什么"变成**盘上可查的证据**（`.lingqu/tasks.json`），
 * 而不是内存里的进度条——关掉应用、换台机器、隔两天回来都能接上。
 *
 * action（默认 status）：
 *   status —— 逐步骤**观测落档**（`.lingqu/<步骤>/<工程>.json`）→ 归约状态 → 写 `.lingqu/tasks.json`
 *   mark   —— 人工覆盖一步：{step, status: done|failed|skipped|running, note?}
 *             （agent 应用完补丁记 done；判定做不了记 skipped，断点会越过它）
 *   redo   —— 从某步重来：{step} → 该步及其之后回到 pending（清备注，提示"落档是上一轮的"）
 *   reset  —— 整块回到 pending（只清状态，**不删落档**——证据不该被断点操作毁掉）
 *   session—— 记 cjh 会话 id：{sessionId}（页面在 CJ.session 变化时存，重启后据此 resume_session）
 *
 * 口径与 `t2h:verify` 一致：落档不存在 = 没跑过（pending，不是失败）；
 * 落档存在但判定没过 = failed（**存在 ≠ 成功**）。
 */
/**
 * t2h:reset_records —— 「从头重跑」：把该工程的迁移落档搬进 `.lingqu/_archive-<时间戳>/`。
 *
 * 为什么需要它（0.39.64，用户实测）：判定只认落档，跑过一轮的工程 8 步落档都在，
 * 再点「AI 一键迁移」agent 一看 `resume` 就"没活可干"，界面表现为"点一下直接完成"。
 * 想真重跑就必须让观测从零开始 —— 但**只能搬我们自己的落档**（经验/台账/截图/源码不碰），
 * 而且**搬走不删**（档案可回退、可对账）。
 *
 * 入参：{path}
 * 出参：{ok, archiveDir, moved:[], failed:[], error}
 */
public class ResetRecordsCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        var res = JsonObject()
        if (path.size == 0) {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("从头重跑需要工程路径"))
            return res
        }
        let out = archiveMigrateRecords(path, nowText())
        var mv = JsonArray()
        for (m in out.moved) {
            mv.add(JsonString(m))
        }
        var fa = JsonArray()
        for (f in out.failed) {
            fa.add(JsonString(f))
        }
        eprintln("[lingqu][reset] path=${path} archive=${out.archiveDir} moved=${out.moved.size} failed=${out.failed.size}")
        res.put("ok", JsonBool(out.ok))
        res.put("archiveDir", JsonString(out.archiveDir))
        res.put("moved", mv)
        res.put("failed", fa)
        res.put("error", JsonString(out.error))
        return res
    }
}

public class ResumeCommand <: CommandHandler {    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_RESUME_PATH", "")
        }
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        let action = argStr(args, "action", "status")
        let now = nowText()

        // 有工程路径 → 观测该工程；没有 → 沿用板子里记的工程名（界面上只点「刷新断点」也能用）
        var board = newTaskBoard()
        var projName = ""
        if (path.size > 0) {
            projName = sanitizeFileName(projectNameOf(path))
        }
        if (projName != "") {
            board = collectTaskBoard(projName, path, now)
        } else {
            match (readJsonOrNone(resolveLqPath(path, "tasks.json"))) {
                case Some(root) =>
                    board = parseTaskBoardValue(root)
                    // 板子里有工程名就按它重新观测（"接着上次继续"不需要再填一次路径）
                    if (board.project != "") {
                        board = collectTaskBoard(board.project, board.path, now)
                    }
                case None => board = newTaskBoard()
            }
        }

        var err = ""
        if (action == "mark") {
            let step = argStr(args, "step", "")
            let status = argStr(args, "status", "")
            if (!markTaskStep(board, step, status, now, argStr(args, "note", ""))) {
                err = "没有这一步：${step}（可选：${taskStepIdsJoined()}）"
            }
        } else if (action == "redo") {
            let step = argStr(args, "step", "")
            if (!redoFromStep(board, step)) {
                err = "没有这一步：${step}（可选：${taskStepIdsJoined()}）"
            } else {
                // 明确写清"落档是上一轮的"：否则刷新后看到 done 会误以为重跑过了
                match (board.findStep(step)) {
                    case Some(s) => s.note = "待重跑（落档还是上一轮的）"
                    case None => ()
                }
            }
        } else if (action == "reset") {
            for (s in board.steps) {
                s.status = TASK_STATUS_PENDING
                s.at = ""
                s.note = ""
            }
        } else if (action == "session") {
            board.sessionId = argStr(args, "sessionId", "")
        } else if (action != "status") {
            err = "不认识的 action：${action}（status|mark|redo|reset|session）"
        }

        // 板子跟着工程走：有 path 用它，没给就沿用板子里记的工程路径（"接着上次继续"）
        let writePath = if (path.size > 0) { path } else { board.path }
        var outError = ""
        if (err == "") {
            outError = saveTaskBoard(board, writePath)
        }

        let p = taskProgress(board)
        let next = firstUnfinished(board)
        var arr = JsonArray()
        for (s in board.steps) {
            arr.add(s.toJson())
        }
        var res = JsonObject()
        res.put("ok", JsonBool(err == "" && outError == ""))
        res.put("action", JsonString(action))
        res.put("project", JsonString(board.project))
        res.put("path", JsonString(board.path))
        res.put("out", JsonString(taskBoardPathFor(writePath)))
        res.put("next", JsonString(next))
        res.put("nextTitle", JsonString(if (next == "") { "" } else { taskStepTitle(next) }))
        res.put("done", JsonInt(p.done))
        res.put("failed", JsonInt(p.failed))
        res.put("skipped", JsonInt(p.skipped))
        res.put("total", JsonInt(p.total))
        res.put("percent", JsonInt(p.percent))
        res.put("hint", JsonString(resumeHint(board)))
        res.put("sessionId", JsonString(board.sessionId))
        res.put("summary", JsonString(taskBoardSummary(board)))
        res.put("steps", arr)
        // 报告落档（0.39.64，用户实测"AI 跑完 8/8、报告也自动生成了，但左栏「报告」徽标仍是未开始"）：
        // 断点板只有 8 步（scan…verify），**没有 report 这一步**，而左栏第 6 项按 `rows['report']` 取数
        // ⇒ 永远 undefined ⇒ 永远「未开始」。这里把报告文件的存在性与路径直接回投，让徽标有据可依。
        let repPath = if (writePath.size > 0) { reportOutPathOf(writePath, board.project) } else { "" }
        res.put("reportOut", JsonString(repPath))
        res.put("reportExists", JsonBool(repPath.size > 0 && exists(Path(repPath))))
        res.put("error", JsonString(err))
        res.put("outError", JsonString(outError))
        eprintln("[lingqu][resume] ${board.project} action=${action} " +
            "done=${p.done}/${p.total} next=${next} ${resumeHint(board)}")
        return res
    }
}

/**
 * 报告落档路径（与 `t2h:report` 的默认落点同一口径：`<工程>/.lingqu/report/<工程>.md`）。
 *
 * 单独收成函数是因为**产出方与消费方必须共用一份构造规则**（§4-33：只改一处 = 静默破坏另一条链路）。
 * 左栏「报告」徽标、断点板、报告命令三处都从这里取。
 */
public func reportOutPathOf(projPath: String, projName: String): String {
    if (projPath.size == 0) {
        return ""
    }
    let name = if (projName.size > 0) { projName } else { sanitizeFileName(projectNameOf(projPath)) }
    if (name.size == 0) {
        return ""
    }
    return lqDirOf(projPath) + cjhPathSep() + "report" + cjhPathSep() + reportFileBase(name) + ".md"
}

/**
 * 只读回读**迁移报告**落档（0.39.98）：`t2h:report {action:"load"}` 走这里。
 *
 * 为什么要有：⑦ 屏的每个数字都挂在 `REPORT` 这个"这次生成出来的"对象上，只有人点
 * 「生成迁移报告」才被填。于是 agent 跑过 `lingqu-cli report`、`.lingqu/report/<工程>.json`
 * 明明躺在盘上，界面却渲染成 `reportOk=false / reportRate=-1`（看着像"从没生成过"）。
 * 与 ⑤⑥ 屏同一病因（§4-135）：干活的那一方写了落档，显示的那一方没跟上。
 *
 * **纯读盘**：不重新生成、不写任何文件——屏幕上的数字必须与落档逐字一致。
 */
func reportRecordResponse(path: String): JsonObject {
    var res = JsonObject()
    let nm = sanitizeFileName(projectNameOf(path))
    res.put("project", JsonString(if (nm.size > 0) { nm } else { "unknown" }))
    res.put("path", JsonString(path))
    if (path.trimAscii().size == 0) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("t2h:report action=load 需要参数 path（或设环境变量 LINGQU_REPORT_PATH）"))
        return res
    }
    let outFile = lqPathOf(path, "report/${reportFileBase(nm)}.json")
    res.put("outJson", JsonString(outFile))
    if (!exists(Path(outFile))) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("还没有迁移报告落档（${outFile}）：点「生成迁移报告」，或让 agent 跑 " +
            "lingqu-cli report --path <工程>"))
        return res
    }
    var root = JsonValue.fromStr("{}")
    try {
        root = JsonValue.fromStr(lenientUtf8(File.readFrom(outFile)))
    } catch (e: Exception) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("读迁移报告落档失败：${e}"))
        return res
    }
    res.put("loaded", JsonBool(true))
    return reportRecordOf(res, root, path, nm)
}

// ============================================================
// 落档回读：③ 规则改造 / ④ 签名（0.39.114）
// ============================================================

/**
 * `decisions.json` → `t2h:port {action:"load"}` 的返回体（纯函数，有单测）。
 *
 * 为什么要它：③ 屏原先只认人点「预览改造 / 应用改造」，`port` 落档里的 `portRun`
 * （本轮应用几条、有没有写盘、什么时候跑）**没有任何路径读回界面**——agent 用
 * `lingqu-cli port --apply` 跑完，屏上还是「—」，与 §4-135 的判据①同族
 * （agent 会自己跑的步骤，界面必须有从落档回读的通道）。
 *
 * 回读**只给摘要、不给规则明细**：规则明细要靠重跑扫描算，重算得到的是"现在这一刻"的数，
 * 与落档对不上（§4-138 的教训）。所以返回体带 `recordOnly=true`，界面据此不渲染规则表。
 */
public func portRecordOf(root: JsonValue): JsonObject {
    var res = JsonObject()
    res.put("ok", JsonBool(false))
    res.put("loaded", JsonBool(false))
    var obj = JsonObject()
    match (root.kind()) {
        case JsonKind.JsObject => obj = root.asObject()
        case _ =>
            res.put("error", JsonString("decisions.json 不是一个 JSON 对象"))
            return res
    }
    let items = jsonArrayOrEmpty(obj, "items")
    res.put("decisionsCount", JsonInt(items.size()))
    var run = JsonObject()
    var hasRun = false
    match (obj.get("portRun")) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsObject =>
                run = v.asObject()
                hasRun = true
            case _ => ()
        }
        case None => ()
    }
    if (!hasRun) {
        // 老落档：只有人工决策、没有 portRun。这是**第三态**——看得出记过决策，
        // 看不出改造跑没跑。既不许当"没跑过"，也不许当"跑过了"（§4-63）。
        if (items.size() > 0) {
            res.put("ok", JsonBool(true))
            res.put("loaded", JsonBool(true))
        }
        res.put("recordOnly", JsonBool(true))
        res.put("error", JsonString("这份 decisions.json 里没有 portRun 段：只记过 ${items.size()} 条人工决策，" +
            "看不出改造有没有跑过。要摘要就重跑一次 `lingqu-cli port --path .`"))
        return res
    }
    res.put("ok", JsonBool(true))
    res.put("loaded", JsonBool(true))
    res.put("recordOnly", JsonBool(true))
    res.put("apply", JsonBool(argBool(run, "apply", false)))
    res.put("applied", JsonInt(argInt(run, "applied", 0)))
    res.put("auto", JsonInt(argInt(run, "auto", 0)))
    res.put("guide", JsonInt(argInt(run, "human", 0)))
    res.put("at", JsonInt(argInt(run, "at", -1)))
    let outs = jsonArrayOrEmpty(run, "outcomes")
    res.put("outcomesCount", JsonInt(outs.size()))
    res.put("outcomes", outs)
    return res
}

/** 只读回读**规则改造**落档（`t2h:port {action:"load"}` 走这里，纯读盘、不重扫） */
public func portRecordResponse(path: String): JsonObject {
    var res = JsonObject()
    var nm = projectNameOf(path)
    if (nm.size == 0) {
        nm = "project"
    }
    nm = sanitizeFileName(nm)
    res.put("project", JsonString(nm))
    if (path.size == 0) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("t2h:port 需要参数 path（或设环境变量 LINGQU_SCAN_PATH）"))
        return res
    }
    // 与写入侧共用 `portBackupDirOf` 的落点（AGENTS §4-33：成对路径只能有一个构造点）
    let outFile = portBackupDirOf(path, nm) + cjhPathSep() + "decisions.json"
    res.put("out", JsonString(outFile))
    if (!exists(Path(outFile))) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("还没有改造落档（${outFile}）：先点「预览改造」，或让 agent 跑 " +
            "`lingqu-cli port --path <工程> --apply`"))
        return res
    }
    var root = JsonValue.fromStr("{}")
    try {
        root = JsonValue.fromStr(lenientUtf8(File.readFrom(outFile)))
    } catch (e: Exception) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("读改造落档失败：${e}"))
        return res
    }
    let body = portRecordOf(root)
    body.put("project", JsonString(nm))
    body.put("out", JsonString(outFile))
    return body
}

/**
 * `t2h:sign {checkMaterial:true}` / `lingqu-cli sign --checkMaterial`：证书 / `.p12` / profile 是不是"一套"。
 *
 * 只回答一件事：**profile 里绑的那张开发证书，在不在本地 `.cer` 证书链里**。
 * 不在就必然 `11111002 Certificates error`（装到真机则 `9568322`），而这在跑 hvigor 之前
 * 一秒内就能判掉（§4-77）。不判口令、不连设备、不跑 hvigor——那些各有专门入口。
 *
 * 落档刻意写到 **`<工程>.material.json`**，不动 `<工程>.json`：后者是体检/自动签的结论，
 * 被"只查了证书配套性"的一轮覆盖掉，界面就会显示成一次失败的签名（§4-33 的成对路径同族）。
 */
func signMaterialCheckResponse(projPathIn: String): JsonObject {
    var pp = projPathIn
    if (pp.size == 0) {
        pp = envOr("LINGQU_SCAN_PATH", "")
    }
    if (pp.size == 0) {
        pp = envOr("LINGQU_BUILD_PATH", "")
    }
    let res = JsonObject()
    if (pp.size == 0) {
        res.put("ok", JsonBool(false))
        res.put("error", JsonString("要给工程路径（--path）：这项体检要读工程的 build-profile.json5"))
        return res
    }
    let path = hostPath(pp)
    let projName = sanitizeFileName(projectNameOf(path))
    // 鸿蒙脚手架位置（与体检同口径：以 Cargo.toml 位置推 src-tauri 根）
    var ohosDir = ""
    let tomlPath = cargoTomlPathOf(path)
    if (tomlPath != "") {
        let srcDir = tomlPath[0..(tomlPath.size - "/Cargo.toml".size)]
        ohosDir = hostPath("${srcDir}/gen/ohos")
    }
    let buildProfile = if (ohosDir == "") { "" } else { hostPath("${ohosDir}/build-profile.json5") }
    if (buildProfile == "" || !exists(Path(buildProfile))) {
        res.put("ok", JsonBool(false))
        res.put("blocked", JsonBool(false))
        res.put("error", JsonString("找不到 ${buildProfile}（还没生成鸿蒙脚手架？）"))
        res.put("nextStep", JsonString("先 `lingqu-cli port --apply` 生成 gen/ohos，再回来体检"))
        return res
    }
    var projText = ""
    try {
        projText = lenientUtf8(File.readFrom(buildProfile))
    } catch (e: Exception) {
        res.put("ok", JsonBool(false))
        res.put("error", JsonString("读 ${buildProfile} 失败：${e}"))
        return res
    }
    let proj = parseProjSigning(projText)
    let certPath = resolveProjectPath(proj.certPath, ohosDir)
    let profilePath = resolveProjectPath(proj.profilePath, ohosDir)
    let storeFile = resolveProjectPath(proj.storeFile, ohosDir)
    // 本地证书正文（.cer 是一条链）
    var cerText = ""
    let hasCer = certPath != "" && exists(Path(certPath))
    if (hasCer) {
        try {
            cerText = lenientUtf8(File.readFrom(certPath))
        } catch (e: Exception) {
            let _ = e
        }
    }
    // profile 里绑的开发证书（读不出 = 空串，判定层不拦）
    var devPem = ""
    let hasProfile = profilePath != "" && exists(Path(profilePath))
    if (hasProfile) {
        try {
            devPem = profileDevCertPemOf(extractProfileJson(latin1Of(File.readFrom(profilePath))))
        } catch (e: Exception) {
            let _ = e
        }
    }
    let v = judgeMaterialKeys(hasCer, cerText, devPem)
    var outJson = ""
    var outError = ""
    try {
        let sgDir = lqDirOf(path) + cjhPathSep() + "sign"
        ensureDirOf(sgDir)
        outJson = sgDir + cjhPathSep() + "${projName}.material.json"
        var root = JsonObject()
        root.put("schema", JsonString("lingqu/sign/v1"))
        root.put("project", JsonString(projName))
        root.put("by", JsonString("material"))
        root.put("ok", JsonBool(v.ok))
        root.put("blocked", JsonBool(v.blocked))
        root.put("ohosDir", JsonString(ohosDir))
        root.put("buildProfile", JsonString(buildProfile))
        root.put("cerPath", JsonString(certPath))
        root.put("profilePath", JsonString(profilePath))
        root.put("storeFile", JsonString(storeFile))
        root.put("hasConfig", JsonBool(proj.signingConfigName != ""))
        root.put("hasCer", JsonBool(hasCer))
        root.put("hasProfile", JsonBool(hasProfile))
        root.put("profileCertReadable", JsonBool(devPem != ""))
        root.put("reason", JsonString(v.reason))
        root.put("nextStep", JsonString(v.nextStep))
        root.put("generatedAt", JsonInt(DateTime.now().toUnixTimeStamp().toMilliseconds()))
        root.put("material", v.toJson())
        File.writeTo(outJson, root.toJsonString().toArray())
    } catch (e: Exception) {
        outError = "落档失败：${e}"
    }
    eprintln("[lingqu][sign:material] ok=${v.ok} blocked=${v.blocked} hasCer=${hasCer} " +
        "pem=${devPem != ""} out=${outJson} err=${outError}")
    res.put("ok", JsonBool(v.ok && outError == ""))
    res.put("blocked", JsonBool(v.blocked))
    res.put("reason", JsonString(v.reason))
    res.put("nextStep", JsonString(v.nextStep))
    res.put("hasConfig", JsonBool(proj.signingConfigName != ""))
    res.put("hasCer", JsonBool(hasCer))
    res.put("hasProfile", JsonBool(hasProfile))
    res.put("profileCertReadable", JsonBool(devPem != ""))
    res.put("cerPath", JsonString(certPath))
    res.put("profilePath", JsonString(profilePath))
    res.put("storeFile", JsonString(storeFile))
    res.put("by", JsonString("material"))
    res.put("out", JsonString(outJson))
    res.put("outError", JsonString(outError))
    return res
}

/**
 * `lingqu/sign/v1` → `t2h:sign {action:"load"}` 的返回体（纯函数，有单测）。
 *
 * 落档有两种形态，字段名不同（§4-115 的教训：先摸清两种拼写再取值）：
 * - 体检档：`check{ok,reason,nextStep,…}` + `signing{configuredName,filesExist}` + 顶层 `candidateCount`
 * - 自动签档：顶层 `ok/error/nextStep` + `autoSign{…}`，没有 `check`/`signing`
 * 界面读的是**扁平**字段（`renderSign` 那一套），这里把两种形态都归一成扁平的。
 */
public func signRecordOf(root: JsonValue): JsonObject {
    var res = JsonObject()
    res.put("ok", JsonBool(false))
    res.put("loaded", JsonBool(false))
    var obj = JsonObject()
    match (root.kind()) {
        case JsonKind.JsObject => obj = root.asObject()
        case _ =>
            res.put("error", JsonString("sign 落档不是一个 JSON 对象"))
            return res
    }
    let check = jsonObjectOrEmpty(obj, "check")
    let mode = jsonObjectOrEmpty(obj, "mode")
    let signing = jsonObjectOrEmpty(obj, "signing")
    let isAuto = argStr(obj, "by", "") == "auto"
    let modeName = argStr(mode, "mode", "")
    // 体检档没有顶层 ok（真值在 check.ok）；自动签档有顶层 ok。两处都认。
    let ok = argBool(obj, "ok", argBool(check, "ok", false))
    let configuredName = argStr(signing, "configuredName", "")
    let filesExist = argBool(signing, "filesExist", false)
    var profileType = argStr(obj, "profileType", "")
    if (profileType == "" && (modeName == "debug" || modeName == "release")) {
        profileType = modeName
    }
    res.put("ok", JsonBool(ok))
    res.put("loaded", JsonBool(true))
    res.put("recordOnly", JsonBool(true))
    res.put("by", JsonString(if (isAuto) { "auto" } else { "check" }))
    res.put("udid", JsonString(argStr(obj, "udid", argStr(check, "udid", ""))))
    res.put("reason", JsonString(argStr(check, "reason", "")))
    res.put("nextStep", JsonString(argStr(obj, "nextStep", argStr(check, "nextStep", ""))))
    res.put("error", JsonString(argStr(obj, "error", "")))
    res.put("hasConfig", JsonBool(configuredName != "" || (isAuto && ok)))
    res.put("signingName", JsonString(configuredName))
    res.put("filesExist", JsonBool(filesExist || (isAuto && ok)))
    res.put("allowsDevice", JsonBool(argBool(check, "configuredAllowsDevice", false)))
    res.put("profileType", JsonString(profileType))
    res.put("candidateCount", JsonInt(argInt(obj, "candidateCount", 0)))
    res.put("candidatePath", JsonString(argStr(obj, "candidatePath", "")))
    res.put("projectBundle", JsonString(argStr(obj, "projectBundle", "")))
    res.put("candidateBundle", JsonString(argStr(obj, "candidateBundle", "")))
    res.put("candidateBundles", JsonString(argStr(obj, "candidateBundles", "")))
    res.put("candidateBundleMatch", JsonBool(argBool(obj, "candidateBundleMatch", false)))
    res.put("mode", JsonString(modeName))
    res.put("modeLabel", JsonString(argStr(mode, "modeLabel", "")))
    res.put("canInstallDevice", JsonBool(argBool(mode, "canInstallDevice", false)))
    res.put("releaseReady", JsonBool(argBool(mode, "releaseReady", false)))
    res.put("signReminder", JsonString(argStr(mode, "reminder", "")))
    res.put("installNextStep", JsonString(argStr(mode, "installNextStep", "")))
    res.put("releaseNextStep", JsonString(argStr(mode, "releaseNextStep", "")))
    res.put("releaseProfileCount", JsonInt(argInt(mode, "releaseProfileCount", 0)))
    res.put("switchSteps", jsonArrayOrEmpty(mode, "switchSteps"))
    // 「这份结论是哪一代的」——落档时间必须回投，否则界面拿旧档当真值（§4-109 / §4-133）
    res.put("generatedAt", JsonInt(argInt(obj, "generatedAt", -1)))
    return res
}

/** 只读回读**签名**落档（`t2h:sign {action:"load"}` 走这里，纯读盘、不重新体检） */
public func signRecordResponse(path: String): JsonObject {
    var res = JsonObject()
    var nm = projectNameOf(path)
    if (nm.size == 0) {
        nm = "project"
    }
    nm = sanitizeFileName(nm)
    res.put("project", JsonString(nm))
    if (path.size == 0) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("t2h:sign 需要参数 path（或设环境变量 LINGQU_SCAN_PATH）"))
        return res
    }
    let outFile = lqPathOf(path, "sign/${nm}.json")
    res.put("out", JsonString(outFile))
    if (!exists(Path(outFile))) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("还没有签名落档（${outFile}）：先点「签名体检」，或让 agent 跑 " +
            "`lingqu-cli sign --path <工程>`"))
        return res
    }
    var root = JsonValue.fromStr("{}")
    try {
        root = JsonValue.fromStr(lenientUtf8(File.readFrom(outFile)))
    } catch (e: Exception) {
        res.put("ok", JsonBool(false))
        res.put("loaded", JsonBool(false))
        res.put("error", JsonString("读签名落档失败：${e}"))
        return res
    }
    let body = signRecordOf(root)
    body.put("project", JsonString(nm))
    body.put("out", JsonString(outFile))
    return body
}

/**
 * 把 `lingqu/report/v1` 落档映射成 `t2h:report` 的返回体（纯函数，有单测）。
 *
 * 落档形态对着盘上那份抄（§4-57）：`sections[{key,title,lines}]`、`artifacts[{label,path}]`、
 * `risk{level,label,summary,high,mid,low,items}`、`stats{stepDone…verifyRate…}`、`files{md,html}`。
 * 界面侧读的是**扁平**的 `riskLevel/riskLabel/…`，所以这里补别名，不逼界面记两套。
 * `files.md/html` 里记的是**相对 CWD** 的路径（实测 `.lingqu\report/x.md`），一律按工程路径重定位。
 */
/** 取对象里的数组字段，取不到/类型不对就给空数组（回读落档时到处要用） */
func jsonArrayOrEmpty(o: JsonObject, k: String): JsonArray {
    match (o.get(k)) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsArray => return v.asArray()
            case _ => return JsonArray()
        }
        case None => return JsonArray()
    }
}

/** 取对象里的对象字段，取不到/类型不对就给空对象 */
func jsonObjectOrEmpty(o: JsonObject, k: String): JsonObject {
    match (o.get(k)) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsObject => return v.asObject()
            case _ => return JsonObject()
        }
        case None => return JsonObject()
    }
}

func reportRecordOf(res: JsonObject, root: JsonValue, projPath: String, projName: String): JsonObject {
    var obj = JsonObject()
    match (root.kind()) {
        case JsonKind.JsObject => obj = root.asObject()
        case _ => ()
    }
    res.put("generatedAt", JsonString(argStr(obj, "generatedAt", "")))
    res.put("conclusion", JsonString(argStr(obj, "conclusion", "")))
    // 三段（did / undone / need）与证据清单原样透传：界面按 sections[index] 取，后端别重排
    var secs = JsonArray()
    var counts = [0, 0, 0]
    let rawSecs = jsonArrayOrEmpty(obj, "sections")
    var i: Int64 = 0
    while (i < rawSecs.size()) {
        let sec = rawSecs[i]
        var so = JsonObject()
        match (sec.kind()) {
            case JsonKind.JsObject => so = sec.asObject()
            case _ => ()
        }
        if (i < 3) {
            counts[i] = jsonArrayOrEmpty(so, "lines").size()
        }
        secs.add(sec)
        i += 1
    }
    res.put("sections", secs)
    res.put("didCount", JsonInt(counts[0]))
    res.put("undoneCount", JsonInt(counts[1]))
    res.put("needCount", JsonInt(counts[2]))
    match (obj.get("artifacts")) {
        case Some(v) => res.put("artifacts", v)
        case None => res.put("artifacts", JsonArray())
    }
    var stats = JsonObject()
    match (obj.get("stats")) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsObject => stats = v.asObject()
            case _ => ()
        }
        case None => ()
    }
    res.put("stats", stats)
    // 风险分级：落档是嵌套的 risk{…}，界面要扁平的 riskXxx（0.39.47 起就是这个口径）
    var risk = JsonObject()
    match (obj.get("risk")) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsObject => risk = v.asObject()
            case _ => ()
        }
        case None => ()
    }
    res.put("riskLevel", JsonString(argStr(risk, "level", "")))
    res.put("riskLabel", JsonString(argStr(risk, "label", "")))
    res.put("riskSummary", JsonString(argStr(risk, "summary", "")))
    res.put("riskHigh", JsonInt(argInt(risk, "high", 0)))
    res.put("riskMid", JsonInt(argInt(risk, "mid", 0)))
    res.put("riskLow", JsonInt(argInt(risk, "low", 0)))
    match (risk.get("items")) {
        case Some(v) => res.put("riskItems", v)
        case None => res.put("riskItems", JsonArray())
    }
    // 三份产物按工程路径重定位（落档记的是相对 CWD 的路径，换个工作目录就指错地方）
    let base = reportFileBase(projName)
    res.put("md", JsonString(lqPathOf(projPath, "report/${base}.md")))
    res.put("html", JsonString(lqPathOf(projPath, "report/${base}.html")))
    res.put("json", JsonString(lqPathOf(projPath, "report/${base}.json")))
    res.put("ok", JsonBool(true))
    res.put("error", JsonString(""))
    return res
}

/** 步骤 id 列表（错误提示里要能列全，别让人猜） */
func taskStepIdsJoined(): String {    var text = ""
    for (id in taskStepIds()) {
        if (text != "") {
            text += "|"
        }
        text += id
    }
    return text
}

/**
 * t2h:report —— 迁移报告（三段式导出，T6-4）。
 *
 * 与 `t2h:verify` 的分工（别混）：
 *   · verify  **采证**：跑 hdc 截图/faultlog，生成功能清单与可用率 → `.lingqu/verify/<工程>.{json,md,html}`
 *   · report  **出报告**：把已有落档（含 verify 的结果、8 步断点板、决策记录）汇总成
 *              「做了什么 / 没做什么 / 需要你做什么」→ `.lingqu/report/<工程>.{md,html,json}`
 * 出报告**不采证、不跑子进程、不改工程**：它只读盘，所以可以反复出、随时出。
 *
 * 参数：{path?, outDir?}。`path` 缺省取 LINGQU_REPORT_PATH / LINGQU_VERIFY_PATH，
 * 都没给就沿用 `.lingqu/tasks.json` 里记的工程名（"接着上次出报告"）。
 */
public class ReportCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_REPORT_PATH", "")
        }
        if (path.size == 0) {
            path = envOr("LINGQU_VERIFY_PATH", "")
        }
        // ---- action=load（0.39.98）：只回读报告落档，**不重新生成**（生成要写盘三份文件）----
        if (argStr(args, "action", "") == "load") {
            return reportRecordResponse(path)
        }
        var projName = ""
        if (path.size > 0) {
            projName = sanitizeFileName(projectNameOf(path))
        } else {
            // 没给路径：沿用断点板里的工程名，省得为了出报告再填一遍
            match (readJsonOrNone(resolveLqPath(path, "tasks.json"))) {
                case Some(root) => projName = parseTaskBoardValue(root).project
                case None => ()
            }
        }
        if (projName == "") {
            projName = "unknown"
        }
        var outDir = argStr(args, "outDir", "")
        if (outDir.size == 0) {
            outDir = lqDirOf(path) + cjhPathSep() + "report"
        }
        let base = reportFileBase(projName)
        let now = nowText()

        let facts = collectReportFacts(projName, path, now)
        let doc = buildReport(facts)
        let md = renderReportMarkdown(doc)
        let html = renderReportHtml(doc)

        var outError = ""
        var outMd = ""
        var outHtml = ""
        var outJson = ""
        try {
            if (!exists(Path(".lingqu"))) {
                Directory.create(Path(".lingqu"))
            }
            ensureDirOf(outDir)
            outMd = "${outDir}/${base}.md"
            outHtml = "${outDir}/${base}.html"
            outJson = "${outDir}/${base}.json"
            File.writeTo(outMd, md.toArray())
            File.writeTo(outHtml, html.toArray())
            File.writeTo(outJson, reportJson(doc, facts, outMd, outHtml).toJsonString().toArray())
        } catch (e: Exception) {
            outError = "导出报告失败：${e}"
        }

        var secArr = JsonArray()
        for (sec in doc.sections) {
            var so = JsonObject()
            so.put("key", JsonString(sec.key))
            so.put("title", JsonString(sec.title))
            var ls = JsonArray()
            for (line in sec.lines) {
                ls.add(JsonString(line))
            }
            so.put("lines", ls)
            secArr.add(so)
        }
        var stats = JsonObject()
        stats.put("stepDone", JsonInt(facts.stepDone))
        stats.put("stepTotal", JsonInt(facts.stepTotal))
        stats.put("stepPercent", JsonInt(facts.stepPercent))
        stats.put("nextStep", JsonString(facts.nextStep))
        stats.put("verifyRate", JsonInt(facts.verifyRate))
        stats.put("verifyPass", JsonInt(facts.verifyPass))
        stats.put("verifyTotal", JsonInt(facts.verifyTotal))
        stats.put("verifyLimit", JsonInt(facts.verifyLimit))
        stats.put("verifyUnknown", JsonInt(facts.verifyUnknown))
        stats.put("verifyCovered", JsonInt(facts.verifyCovered))
        stats.put("verifyNotVerified", JsonInt(facts.verifyNotVerified))
        stats.put("verifyScope", JsonString(facts.verifyScope))
        stats.put("humanAccepted", JsonInt(facts.humanAccepted))
        stats.put("evidenceCount", JsonInt(facts.evidenceCount))

        var artArr = JsonArray()
        for (entry in doc.artifacts) {
            var ao = JsonObject()
            ao.put("label", JsonString(entry[0]))
            ao.put("path", JsonString(entry[1]))
            artArr.add(ao)
        }

        var res = JsonObject()
        res.put("ok", JsonBool(outError == ""))
        res.put("project", JsonString(projName))
        res.put("path", JsonString(path))
        res.put("generatedAt", JsonString(now))
        res.put("conclusion", JsonString(doc.conclusion))
        res.put("sections", secArr)
        res.put("stats", stats)
        res.put("didCount", JsonInt(doc.lineCount("did")))
        res.put("undoneCount", JsonInt(doc.lineCount("undone")))
        res.put("needCount", JsonInt(doc.lineCount("need")))
        res.put("md", JsonString(outMd))
        res.put("html", JsonString(outHtml))
        res.put("json", JsonString(outJson))
        res.put("artifacts", artArr)
        // 风险分级（0.39.47）：需求原文要的"支持风险分级"，随报告一起回投，界面直接渲染
        var riskArr = JsonArray()
        for (it in doc.risk.items) {
            var ro = JsonObject()
            ro.put("title", JsonString(it.title))
            ro.put("level", JsonString(it.level))
            ro.put("levelLabel", JsonString(riskLevelLabel(it.level)))
            ro.put("impact", JsonString(it.impact))
            ro.put("action", JsonString(it.action))
            riskArr.add(ro)
        }
        res.put("riskLevel", JsonString(doc.risk.overallLevel()))
        res.put("riskLabel", JsonString(riskLevelLabel(doc.risk.overallLevel())))
        res.put("riskSummary", JsonString(riskSummaryLine(doc.risk)))
        res.put("riskHigh", JsonInt(doc.risk.countOf(RISK_HIGH)))
        res.put("riskMid", JsonInt(doc.risk.countOf(RISK_MID)))
        res.put("riskLow", JsonInt(doc.risk.countOf(RISK_LOW)))
        res.put("riskItems", riskArr)
        res.put("error", JsonString(outError))
        eprintln("[lingqu][report] ${projName} → ${outHtml}｜${doc.conclusion}")
        return res
    }
}

/** 报告的 JSON 落档（lingqu/report/v1）：三段全文 + 计数 + 文件路径，便于机器再加工 */
func reportJson(doc: ReportDoc, facts: MigrationFacts, outMd: String, outHtml: String): JsonObject {
    var root = JsonObject()
    root.put("schema", JsonString("lingqu/report/v1"))
    root.put("project", JsonString(doc.project))
    root.put("path", JsonString(doc.path))
    root.put("generatedAt", JsonString(doc.generatedAt))
    root.put("conclusion", JsonString(doc.conclusion))
    var secs = JsonArray()
    for (sec in doc.sections) {
        var so = JsonObject()
        so.put("key", JsonString(sec.key))
        so.put("title", JsonString(sec.title))
        var ls = JsonArray()
        for (line in sec.lines) {
            ls.add(JsonString(line))
        }
        so.put("lines", ls)
        secs.add(so)
    }
    root.put("sections", secs)
    var arts = JsonArray()
    for (entry in doc.artifacts) {
        var ao = JsonObject()
        ao.put("label", JsonString(entry[0]))
        ao.put("path", JsonString(entry[1]))
        arts.add(ao)
    }
    root.put("artifacts", arts)
    // 风险分级（0.39.47）：加在 lingqu/report/v1 里属于**新增字段**（旧读取方忽略即可，不改 schema 名）
    var riskObj = JsonObject()
    riskObj.put("level", JsonString(doc.risk.overallLevel()))
    riskObj.put("label", JsonString(riskLevelLabel(doc.risk.overallLevel())))
    riskObj.put("summary", JsonString(riskSummaryLine(doc.risk)))
    riskObj.put("high", JsonInt(doc.risk.countOf(RISK_HIGH)))
    riskObj.put("mid", JsonInt(doc.risk.countOf(RISK_MID)))
    riskObj.put("low", JsonInt(doc.risk.countOf(RISK_LOW)))
    var riskItemsJson = JsonArray()
    for (it in doc.risk.items) {
        var ro = JsonObject()
        ro.put("title", JsonString(it.title))
        ro.put("level", JsonString(it.level))
        ro.put("levelLabel", JsonString(riskLevelLabel(it.level)))
        ro.put("impact", JsonString(it.impact))
        ro.put("action", JsonString(it.action))
        riskItemsJson.add(ro)
    }
    riskObj.put("items", riskItemsJson)
    root.put("risk", riskObj)
    var stats = JsonObject()
    stats.put("stepDone", JsonInt(facts.stepDone))
    stats.put("stepTotal", JsonInt(facts.stepTotal))
    stats.put("stepPercent", JsonInt(facts.stepPercent))
    stats.put("nextStep", JsonString(facts.nextStep))
    stats.put("verifyRate", JsonInt(facts.verifyRate))
    stats.put("verifyPass", JsonInt(facts.verifyPass))
    stats.put("verifyTotal", JsonInt(facts.verifyTotal))
    stats.put("verifyFail", JsonInt(facts.verifyFail))
    stats.put("verifyLimit", JsonInt(facts.verifyLimit))
    stats.put("verifyUnknown", JsonInt(facts.verifyUnknown))
    stats.put("verifyCovered", JsonInt(facts.verifyCovered))
    stats.put("verifyNotVerified", JsonInt(facts.verifyNotVerified))
    stats.put("verifyScope", JsonString(facts.verifyScope))
    stats.put("humanAccepted", JsonInt(facts.humanAccepted))
    stats.put("humanIgnored", JsonInt(facts.humanIgnored))
    stats.put("evidenceCount", JsonInt(facts.evidenceCount))
    root.put("stats", stats)
    var files = JsonObject()
    files.put("md", JsonString(outMd))
    files.put("html", JsonString(outHtml))
    root.put("files", files)
    return root
}

/**
 * 确保目录存在。
 *
 * 0.39.11 修：原来逐段 `Directory.create(Path(part))` 在「工程的 `.lingqu` 还不存在」时会炸
 * （`Failed to create directory …\.lingqu\sign, parent …\.lingqu does not exist`），
 * 于是**落档整块丢掉**——实测 5 个样本里有 3 个（cc-switch / atomMqtt / tauri-mqtt）就因为这个
 * 拿不到 `.lingqu/sign/<工程>.json`。现在优先用标准库的递归创建（`recursive: true`，
 * 与 `saveTaskBoard` 同一种写法），失败再退回逐段创建。
 */
func ensureDirOf(dir: String): Unit {
    if (dir == "" || dir == "." || exists(Path(dir))) {
        return
    }
    try {
        Directory.create(Path(dir), recursive: true)
        if (exists(Path(dir))) {
            return
        }
    } catch (e: Exception) {
        let _ = e
    }
    var start: Int64 = 0
    let bytes = dir.toArray()
    var i: Int64 = 0
    while (i < bytes.size) {
        // 字面量 92/47 直接比，别拿 Int64 数组元素跟 Byte 比（类型不匹配，见 AGENTS §4-59）
        let isSep = bytes[i] == 92 || bytes[i] == 47
        if (isSep && i > start) {
            let part = dir[start..i]
            if (part.size > 0 && !exists(Path(part))) {
                try {
                    Directory.create(Path(part))
                } catch (e: Exception) {
                    let _ = e
                }
            }
            start = i + 1
        }
        i += 1
    }
    if (!exists(Path(dir))) {
        Directory.create(Path(dir))
    }
}

/**
 * t2h:batch —— 5 样本迁移矩阵（T7-3）。
 *
 * 单个工程的报告说明"这个迁得怎样"；**并排才能说明"工具本身怎样"**：
 * 评分分布、自动修复命中、人工介入次数（A3）、可用率是否稳定在 A4 线（≥80%）。
 *
 * 参数：{samples?: "路径1|路径2|..."（也认逗号）, outDir?}
 *   `samples` 缺省时按 `.lingqu` 下出现过的工程名收集（"我跑过哪些就有哪些"）。
 * 落档：`.lingqu/batch/matrix.{md,html,json}`（`lingqu/batch/v1`）。
 * 纯读盘：不采证、不改任何样本工程。
 */
public class BatchCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var raw = argStr(args, "samples", "")
        if (raw.size == 0) {
            raw = envOr("LINGQU_BATCH_SAMPLES", "")
        }
        let now = nowText()
        let samples = ArrayList<(String, String)>()
        // 样本是从哪儿来的（回投给界面/命令行，别让人猜"这些行是哪来的"）
        var source = ""

        // ① 显式给了样本路径：按给的顺序，工程名与各命令落档用的名字保持一致
        if (raw.size > 0) {
            for (p in splitSamplePaths(raw)) {
                let name = sanitizeFileName(projectNameOf(p))
                if (name == "") {
                    continue
                }
                samples.add((name, p))
            }
            if (samples.size > 0) {
                source = "explicit"
            }
        }

        // ② 没给就从工作区发现（0.39.29：发现的是**工程路径**，不只名字 ——
        //    只发现名字会读不到样本自己的 `<工程>/.lingqu`，矩阵就会把"迁完的"显示成"未跑"）
        if (samples.size == 0) {
            let roots = sampleRootsOf(envOr("LINGQU_SAMPLES_ROOT", ""),
                envOr("LINGQU_WORKSPACES", ""),
                firstNonEmptyEnv(["USERPROFILE", "HOME"]))
            for (pair in discoverSampleProjects(roots)) {
                samples.add((pair[0], pair[1]))
            }
            if (samples.size > 0) {
                source = "workspace"
            }
        }
        // ③ 还没发现到：用上次显式给过、记在 `.lingqu/batch/samples.txt` 的路径
        if (samples.size == 0) {
            for (p in loadBatchSamplePaths()) {
                let name = sanitizeFileName(projectNameOf(p))
                if (name.size == 0) {
                    continue
                }
                samples.add((name, p))
            }
            if (samples.size > 0) {
                source = "remembered"
            }
        }
        // ④ 最后的兜底：当前目录 `.lingqu` 里出现过的工程名（老行为，路径留空）
        if (samples.size == 0) {
            for (name in discoverSampleNames()) {
                samples.add((name, ""))
            }
            if (samples.size > 0) {
                source = "cwd-lingqu"
            }
        }
        // 显式给了路径就记下来，下次自动发现也带上
        if (raw.size > 0) {
            let given = ArrayList<String>()
            for (s in samples) {
                if (s[1].size > 0) {
                    given.add(s[1])
                }
            }
            saveBatchSamplePaths(given)
        }

        let matrix = collectBatchMatrix(samples, now)
        let summary = summarize(matrix)

        var outDir = argStr(args, "outDir", "")
        if (outDir.size == 0) {
            outDir = ".lingqu/batch"
        }
        let outError = writeBatchMatrix(matrix, summary, outDir)
        let base = "${outDir}"

        var rowArr = JsonArray()
        for (r in matrix.rows) {
            var ro = JsonObject()
            ro.put("project", JsonString(r.project))
            ro.put("path", JsonString(r.path))
            ro.put("hasScan", JsonBool(r.hasScan))
            ro.put("scanScore", JsonInt(r.scanScore))
            ro.put("scanUnits", JsonInt(r.scanUnits))
            ro.put("scanUnknown", JsonInt(r.scanUnknown))
            ro.put("hasDeps", JsonBool(r.hasDeps))
            ro.put("depsTotal", JsonInt(r.depsTotal))
            ro.put("depsUnavailable", JsonInt(r.depsUnavailable))
            ro.put("buildOk", JsonBool(r.buildOk))
            ro.put("hasBuild", JsonBool(r.hasBuild))
            ro.put("hapOk", JsonBool(r.hapOk))
            ro.put("hasHap", JsonBool(r.hasHap))
            ro.put("signMode", JsonString(r.signMode))
            ro.put("deployOk", JsonBool(r.deployOk))
            ro.put("hasDeploy", JsonBool(r.hasDeploy))
            ro.put("hasVerify", JsonBool(r.hasVerify))
            ro.put("verifyRate", JsonInt(r.verifyRate))
            ro.put("verifyPass", JsonInt(r.verifyPass))
            ro.put("verifyTotal", JsonInt(r.verifyTotal))
            ro.put("verifyLimit", JsonInt(r.verifyLimit))
            // 分母 = 有结论的移植验收项（D-020）；老落档没 covered → 回落 total−limit
            let vDenom = if (r.verifyCovered > 0) { r.verifyCovered } else { r.verifyTotal - r.verifyLimit }
            ro.put("verifyDenom", JsonInt(vDenom))
            ro.put("verifyCovered", JsonInt(r.verifyCovered))
            ro.put("verifyNotVerified", JsonInt(r.verifyNotVerified))
            ro.put("stepDone", JsonInt(r.stepDone))
            ro.put("stepTotal", JsonInt(r.stepTotal))
            ro.put("humanAccepted", JsonInt(r.humanAccepted))
            ro.put("verdict", JsonString(batchVerdict(r)))
            ro.put("completion", JsonInt(batchCompletion(r)))
            rowArr.add(ro)
        }

        var res = JsonObject()
        res.put("ok", JsonBool(outError == ""))
        res.put("generatedAt", JsonString(now))
        res.put("samples", JsonInt(summary.samples))
        res.put("verified", JsonInt(summary.verified))
        res.put("avgRate", JsonInt(summary.avgRate))
        res.put("avgScore", JsonInt(summary.avgScore))
        res.put("totalHuman", JsonInt(summary.totalHuman))
        res.put("a4Pass", JsonBool(summary.a4Pass))
        res.put("a1Pass", JsonBool(summary.a1Pass))
        res.put("summary", JsonString(summaryLine(matrix)))
        // 样本从哪来的（explicit / workspace / remembered / cwd-lingqu）：
        // 让界面与命令行都能说明"这 5 行是怎么被找到的"，而不是让人怀疑是编的
        res.put("sampleSource", JsonString(source))
        res.put("samplesFile", JsonString(BATCH_SAMPLES_FILE))
        res.put("rows", rowArr)
        res.put("outDir", JsonString(base))
        res.put("md", JsonString("${outDir}/matrix.md"))
        res.put("html", JsonString("${outDir}/matrix.html"))
        res.put("json", JsonString("${outDir}/matrix.json"))
        res.put("error", JsonString(outError))
        eprintln("[lingqu][batch] ${summaryLine(matrix)}")
        return res
    }
}

/**
 * 把 `a|b|c` 或 `a,b,c` 拆成路径列表（两种分隔符都认：Windows 路径里逗号罕见，| 更安全）。
 *
 * 注意：**别用 `cur += "${b}"` 拼字节**——那会把 `b` 按十进制打印成数字，
 * 路径会变成 "695892116…" 这种鬼东西（AGENTS §3 的 StringBuilder.append(Byte) 同款坑）。
 * 这里攒字节再 `String.fromUtf8`，中文目录名才不会坏。
 */
func splitSamplePaths(raw: String): ArrayList<String> {
    let out = ArrayList<String>()
    var buf = ArrayList<Byte>()
    for (b in raw.toArray()) {
        if (b == 124 || b == 44) {
            let s = lenientUtf8(buf.toArray()).trimAscii()
            if (s != "") {
                out.add(s)
            }
            buf = ArrayList<Byte>()
        } else {
            buf.add(b)
        }
    }
    let last = lenientUtf8(buf.toArray()).trimAscii()
    if (last != "") {
        out.add(last)
    }
    return out
}

/** 落盘矩阵三份文件（返回错误串，空串 = 成功） */
func writeBatchMatrix(matrix: BatchMatrix, summary: BatchSummary, outDir: String): String {
    try {
        if (!exists(Path(".lingqu"))) {
            Directory.create(Path(".lingqu"))
        }
        ensureDirOf(outDir)
        File.writeTo("${outDir}/matrix.md", renderMatrixMarkdown(matrix).toArray())
        File.writeTo("${outDir}/matrix.html", renderMatrixHtml(matrix).toArray())
        var root = JsonObject()
        root.put("schema", JsonString("lingqu/batch/v1"))
        root.put("generatedAt", JsonString(matrix.generatedAt))
        var sObj = JsonObject()
        sObj.put("samples", JsonInt(summary.samples))
        sObj.put("verified", JsonInt(summary.verified))
        sObj.put("avgRate", JsonInt(summary.avgRate))
        sObj.put("avgScore", JsonInt(summary.avgScore))
        sObj.put("totalHuman", JsonInt(summary.totalHuman))
        sObj.put("a4Pass", JsonBool(summary.a4Pass))
        sObj.put("a1Pass", JsonBool(summary.a1Pass))
        sObj.put("summary", JsonString(summaryLine(matrix)))
        root.put("summary", sObj)
        var rows = JsonArray()
        for (r in matrix.rows) {
            var ro = JsonObject()
            ro.put("project", JsonString(r.project))
            ro.put("path", JsonString(r.path))
            ro.put("scanScore", JsonInt(r.scanScore))
            ro.put("scanUnits", JsonInt(r.scanUnits))
            ro.put("scanUnknown", JsonInt(r.scanUnknown))
            ro.put("depsTotal", JsonInt(r.depsTotal))
            ro.put("depsUnavailable", JsonInt(r.depsUnavailable))
            ro.put("buildOk", JsonBool(r.buildOk))
            ro.put("hasBuild", JsonBool(r.hasBuild))
            ro.put("hapOk", JsonBool(r.hapOk))
            ro.put("hasHap", JsonBool(r.hasHap))
            ro.put("signMode", JsonString(r.signMode))
            ro.put("deployOk", JsonBool(r.deployOk))
            ro.put("hasDeploy", JsonBool(r.hasDeploy))
            ro.put("verifyRate", JsonInt(r.verifyRate))
            ro.put("verifyPass", JsonInt(r.verifyPass))
            ro.put("verifyTotal", JsonInt(r.verifyTotal))
            ro.put("stepDone", JsonInt(r.stepDone))
            ro.put("stepTotal", JsonInt(r.stepTotal))
            ro.put("humanAccepted", JsonInt(r.humanAccepted))
            ro.put("verdict", JsonString(batchVerdict(r)))
            rows.add(ro)
        }
        root.put("rows", rows)
        File.writeTo("${outDir}/matrix.json", root.toJsonString().toArray())
    } catch (e: Exception) {
        return "落档失败：${e}"
    }
    return ""
}

/**
 * t2h:skill —— 把 `t2h-ohos-port` 技能装进 cjh（AI 接入计划第 1 步）。
 *
 * 背景：cjh 的技能是 `~/.cjh/skills/<name>.md`（frontmatter + 正文），正文会被拼进
 * system prompt。本仓 `skills/t2h-ohos-port/` 一直只是躺在仓库里，cjh 从未见过，
 * 所以 AI 助手对鸿蒙移植的坑/签名/工具链一无所知。这条命令负责"装进去 + 验证它真的看见了"。
 *
 * action：
 *   status（默认）—— 查安装状态（missing/installed/outdated）+ 白名单语义 + references 份数
 *   install       —— 安装（备份旧文件、链接改写为绝对路径、拷 references），装完问 cjh `/api/skills`
 */
public class SkillCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        let action = argStr(args, "action", "status")
        let home = userHomeDir()
        let settings = cjhSettingsPathOf(home)
        let whitelist = readEnabledSkills(settings)
        let enableNote = skillEnableNoteOf(whitelist)
        let target = skillTargetPathOf(home)
        let srcDir = skillSourceDir()

        var installNote = ""
        var backupPath = ""
        var error = ""
        var sourceKind = if (srcDir != "") { "repo" } else { "embedded" }
        if (action == "install") {
            let r = installSkill(home)
            installNote = r.note
            backupPath = r.backupPath
            error = r.error
            if (r.sourceKind != "") {
                sourceKind = r.sourceKind
            }
        }

        // 状态（install 之后重新算，别用装之前的缓存值）。
        // 来源哈希**必须**用"应该装上去的那份正文"（含链接改写）算——拿原始 SKILL.md 去比
        // 会永远报 outdated（0.32.0 第一版踩过）
        let installedHash = skillHashOfFile(target)
        let finalBody = skillFinalBodyOf(home)
        let sourceHash = if (finalBody != "") { skillHashOfBytes(finalBody.toArray()) } else { "" }
        let state = skillStateOf(installedHash != "", installedHash, sourceHash)
        let refs = skillRefFiles(skillRefDirOf(home))
        // 问 cjh：真看见了才算生效（没在跑就如实说未验证）
        let seen = cjhSkillNames(cjhPort())
        var seenIt = false
        for (n in seen) {
            if (n == SKILL_NAME) {
                seenIt = true
            }
        }

        var res = JsonObject()
        res.put("ok", JsonBool(error == ""))
        res.put("action", JsonString(action))
        res.put("state", JsonString(state))
        res.put("targetPath", JsonString(target))
        res.put("refDir", JsonString(skillRefDirOf(home)))
        res.put("refCount", JsonInt(Int64(refs.size)))
        res.put("sourceDir", JsonString(srcDir))
        res.put("sourceKind", JsonString(sourceKind))
        res.put("enableNote", JsonString(enableNote))
        res.put("whitelistCount", JsonInt(Int64(whitelist.size)))
        res.put("backupPath", JsonString(backupPath))
        res.put("note", JsonString(installNote))
        res.put("error", JsonString(error))
        res.put("cjhSkills", JsonInt(Int64(seen.size)))
        res.put("cjhSeen", JsonBool(seenIt))
        var names = JsonArray()
        for (n in seen) {
            names.add(JsonString(n))
        }
        res.put("cjhSkillNames", names)
        eprintln("[lingqu][skill] action=${action} state=${state} refs=${refs.size} " +
            "cjhSeen=${seenIt} source=${sourceKind}")
        return res
    }
}

/**
 * t2h:agent_context —— 给 agent 装"工程上下文"（AI 接入计划第 2 步）。
 *
 * 两步（用户拍板的方案）：
 *   ① 底座：切 cjh 的 workspace 到这个工程（`POST /api/workspaces/switch`，cjh 会 chdir +
 *      重置持久 bash 会话）——不切的话 agent 的工具还蹲在灵渠目录，知识再全也落不到工程上；
 *   ② 内容：往工程的 `AGENTS.md` 写**受管区块**（cjh 从 cwd 逐级向上找 AGENTS.md 并注入）。
 *      幂等、保留用户原有内容、可移除。
 *
 * action：status（默认）/ install / remove
 */
public class AgentContextCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_AGENT_PATH", "")
        }
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        let action = argStr(args, "action", "status")
        var projName = "unknown"
        if (path.size > 0) {
            projName = sanitizeFileName(projectNameOf(path))
        }
        let projDir = if (path.size > 0) { hostPath(path) } else { "" }
        let target = agentContextPathOf(projDir)

        var existed = readTextOrEmpty(target)
        var wrote = false
        var backup = ""
        var error = ""
        var switched = false
        if (action == "install") {
            if (projDir == "" || !exists(Path(projDir))) {
                error = "要传工程路径（path），或置 LINGQU_AGENT_PATH——工程目录不存在就写不了上下文"
            } else {
                // 带工具绝对路径：agent 的 cwd 是目标工程，相对路径在那里不存在（AGENTS §4-70）
                let body = agentContextBodyWith(projName, projDir, resolveCliExe())
                let merged = injectAgentBlock(existed, body)
                try {
                    // 覆盖前留 .bak（用户原有内容万一被误改，能救回来）
                    if (existed != "" && !exists(Path(target + ".lingqu.bak"))) {
                        backup = target + ".lingqu.bak"
                        File.writeTo(backup, existed.toArray())
                    }
                    File.writeTo(target, merged.toArray())
                    wrote = true
                    existed = merged
                } catch (e: Exception) {
                    error = "写 ${target} 失败：${e}"
                }
                // 切 workspace（cjh 没在跑也不算安装失败，但要如实回投）
                switched = cjhSwitchWorkspace(cjhPort(), projDir)
            }
        } else if (action == "remove") {
            if (projDir == "" || !exists(Path(projDir))) {
                error = "要传工程路径（path）"
            } else if (!hasAgentBlock(existed)) {
                error = ""
            } else {
                let merged = removeAgentBlock(existed)
                try {
                    if (merged.trimAscii() == "") {
                        // 用户原本没有 AGENTS.md：删掉文件，别留一个空文件占地方
                        if (exists(Path(target))) {
                            removeIfExists(target)
                        }
                    } else {
                        File.writeTo(target, merged.toArray())
                    }
                    existed = merged
                    wrote = true
                } catch (e: Exception) {
                    error = "移除 ${target} 里的区块失败：${e}"
                }
            }
        }

        let hasBlock = hasAgentBlock(existed)
        let current = cjhCurrentWorkspace(cjhPort())

        var res = JsonObject()
        res.put("ok", JsonBool(error == ""))
        res.put("action", JsonString(action))
        res.put("project", JsonString(projName))
        res.put("projDir", JsonString(projDir))
        res.put("path", JsonString(target))
        res.put("hasBlock", JsonBool(hasBlock))
        res.put("wrote", JsonBool(wrote))
        res.put("backup", JsonString(backup))
        res.put("switched", JsonBool(switched))
        res.put("cjhWorkspace", JsonString(current))
        res.put("error", JsonString(error))
        eprintln("[lingqu][agent] action=${action} proj=${projName} hasBlock=${hasBlock} " +
            "wrote=${wrote} switched=${switched} cjhWorkspace=${current}")
        return res
    }
}

// ============================================================
// ⑥ 一键迁移（t2h:migrate）：8 步串起来跑，过程可观测，最后给一份结果
// ============================================================

/*
 * 为什么要有它（用户原话）："一键完成检测与鸿蒙化移植，让 agent 自动干完所有的活，
 * 有真机就直接真机跑，用户可看到过程和最后给用户呈现结果"。
 *
 * 实现要点（三条，改之前先读）：
 *   ① **后台线程跑，状态放内存**：一次迁移以分钟计（cargo build + hvigor assembleHap），
 *      在 IPC handler 里同步跑会把整个命令面堵死（页面连进度都读不到）。所以
 *      `t2h:migrate` 只负责起线程 + 立即返回，进度靠 `t2h:migrate_status` 轮询。
 *   ② **判定只认落档**：每步跑完 `observeTaskStep` 读盘，不信命令返回值的乐观字段
 *      （存在 ≠ 成功，§4-63）。断点板与一键迁移因此永远一致。
 *   ③ **跳过 ≠ 失败**：没插设备 / 签名是 release 态时跳过 deploy+verify 并写明原因。
 */

/** 一键迁移的共享状态（`let` 绑定可变对象；读写都在 `gMigrateLock` 里） */
let gMigrateLock = Mutex()
let gMigrate = MigrateState()

/** 当前有没有真机（hdc list targets -v 里解析出来的设备数 > 0） */
/**
 * 部署落档里的真机证据（0.39.40）：`(有记录且 deviceCount>0, 序列号)`。
 *
 * 为什么需要它：`migrateHasDevice()` 只在迁移**开始**那一刻查一次，之后插上设备也不会变。
 * 界面上那行「100% 未连接真机」就是拿这个一次性快照当"现在"显示的（用户实测：
 * 应用明明已经在真机上跑起来了，落档 `deploy.deviceCount=1`、`verify` 100%，界面还在说未连接）。
 * 判据必须**都说清出处**：`hasDevice`=本次起始时；`deviceInRecord`=最近一次部署核实到。
 */
func deployDeviceOf(projName: String, projectPath: String): (Bool, String) {
    if (projName.size == 0) {
        return (false, "")
    }
    match (readJsonOrNone(resolveLqPath(projectPath, "deploy/${projName}.json"))) {
        case Some(root) =>
            let cnt = intFieldOf(root, "deviceCount", 0)
            let serial = jsonStrField(root, "serial")
            return (cnt > 0, serial)
        case None => return (false, "")
    }
}

func migrateHasDevice(): Bool {
    let hdc = hdcPathOr()
    if (hdc == "") {
        return false
    }
    try {
        let (code, out, errOut) = executeWithOutput(hdc, ["list", "targets", "-v"])
        let _ = code
        let listText = lenientUtf8(out) + "\n" + lenientUtf8(errOut)
        return parseHdcTargets(listText).size > 0
    } catch (e: Exception) {
        eprintln("[lingqu][migrate] 查设备失败：${e}")
        return false
    }
}

/**
 * `hdc list targets -v` 的原始输出（拿不到给空串）。
 *
 * 给 `resolveDeviceKeyOf` 用：设备从 USB 换到无线调试后 connect-key 会变，
 * 必须按**现场在线目标**校正落档里的旧序列号（0.39.131 真机实测）。
 */
func liveHdcTargetsText(hdc: String): String {
    if (hdc == "") {
        return ""
    }
    try {
        let (code, out, errOut) = executeWithOutput(hdc, ["list", "targets", "-v"])
        let _ = code
        return lenientUtf8(out) + "\n" + lenientUtf8(errOut)
    } catch (e: Exception) {
        eprintln("[lingqu] 查在线设备失败：${e}")
        return ""
    }
}

/** 签名态（读 `sign/<工程>.json` 的 mode.mode；没有落档/没这一段回空串） */
func signModeOf(projName: String, projectPath: String): String {
    match (readJsonOrNone(resolveLqPath(projectPath, "sign/${projName}.json"))) {
        case Some(root) => return jsonStrField(objFieldOf(root, "mode"), "mode")
        case None => return ""
    }
}

/** 命令返回值里的 ok（各命令都带；缺了按 false——宁可当失败，也别把"没结果"当成功） */
func cmdOkOf(v: JsonValue): Bool {
    match (v.kind()) {
        case JsonKind.JsObject => return boolFieldOf(v, "ok")
        case _ => return false
    }
}

/** 跑一步（handler 直接调用：与界面按钮、lingqu-cli 是同一份实现）；返回命令层 ok */
func migrateRunStep(step: String, path: String, applyPort: Bool): Bool {
    let ctx = IpcContext("migrate", IpcHub())
    var args = JsonObject()
    args.put("path", JsonString(path))
    let name = "t2h:${step}"
    if (step == "scan") {
        return cmdOkOf(ScanCommand().handle(name, args, ctx))
    }
    if (step == "deps") {
        return cmdOkOf(DepsCommand().handle(name, args, ctx))
    }
    if (step == "port") {
        args.put("apply", JsonBool(applyPort))
        return cmdOkOf(PortCommand().handle(name, args, ctx))
    }
    if (step == "build") {
        return cmdOkOf(BuildCommand().handle(name, args, ctx))
    }
    if (step == "hap") {
        return cmdOkOf(HapCommand().handle(name, args, ctx))
    }
    if (step == "sign") {
        // 先做只读体检；体检未过但**有候选材料**时才写回 signingConfigs（原文件留 .bak）
        args.put("apply", JsonBool(false))
        let first = SignCommand().handle(name, args, ctx)
        let okNow = cmdOkOf(first)
        var cands: Int64 = 0
        match (first.kind()) {
            case JsonKind.JsObject => cands = intFieldOf(first, "candidateCount", 0)
            case _ => ()
        }
        if (!okNow && cands > 0) {
            eprintln("[lingqu][migrate] 签名体检未过，但有 ${cands} 份候选材料 → 写回 signingConfigs")
            args.put("apply", JsonBool(true))
            return cmdOkOf(SignCommand().handle(name, args, ctx))
        }
        return okNow
    }
    if (step == "deploy") {
        args.put("start", JsonBool(true))
        return cmdOkOf(DeployCommand().handle(name, args, ctx))
    }
    if (step == "verify") {
        args.put("screenshot", JsonBool(true))
        return cmdOkOf(VerifyCommand().handle(name, args, ctx))
    }
    return false
}

/**
 * 迁移主循环（**在后台线程里跑**）。
 *
 * 每一步：报进度 → 跑 handler → 读落档判定 → 记一行；失败就拼提问正文并停。
 * 结束后无条件出一份三段式报告 + 一份结果卡（失败也出，人要看到"做完到哪、下一步做什么"）。
 */
func runMigrateChain(path: String, applyPort: Bool): Unit {
    let proj = sanitizeFileName(projectNameOf(path))
    let hasDevice = migrateHasDevice()
    synchronized(gMigrateLock) {
        gMigrate.running = true
        gMigrate.done = false
        gMigrate.cancelled = false
        gMigrate.project = proj
        gMigrate.path = path
        gMigrate.hasDevice = hasDevice
        gMigrate.total = Int64(MIGRATE_STEPS.size)
        gMigrate.index = 0
        gMigrate.current = ""
        gMigrate.message = "准备中…"
        gMigrate.rows = ArrayList<MigrateRow>()
        gMigrate.askPrompt = ""
        gMigrate.reportMd = ""
        gMigrate.reportHtml = ""
        gMigrate.resultMd = ""
        gMigrate.finishedAt = ""
        gMigrate.error = ""
    }
    eprintln("[lingqu][migrate] 开始：${proj} device=${hasDevice} applyPort=${applyPort} " +
        "steps=${MIGRATE_STEPS.size}")

    var stop = false
    var releaseMode = ""
    var i: Int64 = 0
    while (i < MIGRATE_STEPS.size && !stop) {
        let step = MIGRATE_STEPS[i]
        var cancelledNow = false
        synchronized(gMigrateLock) {
            gMigrate.index = i
            gMigrate.current = step
            gMigrate.message = "正在${taskStepTitle(step)}…"
            cancelledNow = gMigrate.cancelled
        }
        if (cancelledNow) {
            eprintln("[lingqu][migrate] 用户停止：在 ${step} 之前")
            stop = true
            break
        }
        // 需要真机的两步：没设备 / release 态就跳过（跳过 ≠ 失败）
        var skipWhy = ""
        if (migrateNeedsDevice(step)) {
            if (!hasDevice) {
                skipWhy = "未连接真机：没插设备，或 hdc 没识别到（hdc list targets）"
            } else if (releaseMode == "release") {
                skipWhy = "签名是 release 态：装不上真机是设计使然（9568322），" +
                    "要真机验证请先切 debug 态再重跑"
            }
        }
        let row = MigrateRow()
        row.step = step
        row.title = taskStepTitle(step)
        row.at = nowText()
        if (skipWhy != "") {
            row.skipped = skipWhy
            synchronized(gMigrateLock) {
                gMigrate.rows.add(row)
            }
            eprintln("[lingqu][migrate] 跳过 ${step}：${skipWhy}")
            i += 1
            continue
        }
        let cmdOk = migrateRunStep(step, path, applyPort)
        if (step == "sign") {
            releaseMode = signModeOf(proj, path)
        }
        let obs = observeTaskStepAt(proj, step, path)
        row.ran = obs.exists
        row.ok = obs.exists && obs.ok
        row.note = obs.note
        // 规则改造的落档是**可选**的：工程本来就迁好了 → 没有可改的地方，既不写 decisions.json
        // 也不留 .bak。这种"跑过且没东西可改"必须算通过，否则一键迁移在已迁移的工程上
        // 永远显示「规则改造｜未跑」，看起来像漏了一步。
        if (!obs.exists && step == "port" && cmdOk) {
            row.ran = true
            row.ok = true
            row.note = "已跑：没有需要改的地方（幂等）"
        }
        synchronized(gMigrateLock) {
            gMigrate.rows.add(row)
        }
        eprintln("[lingqu][migrate] ${step} ran=${row.ran} ok=${row.ok} ${row.note}")
        if (row.ran && !row.ok) {
            // 失败现场 → 提问正文（复用 G1/G2：一键迁移里对 AI 说的话与界面按钮说的必须一致）
            let brief = stepBriefOf(proj, path, step, ASK_LOG_TAIL_LINES)
            synchronized(gMigrateLock) {
                gMigrate.askPrompt = migrateAskPrompt(gMigrate, brief)
            }
            eprintln("[lingqu][migrate] 停在 ${step}，已拼好失败提问")
            stop = true
        }
        i += 1
    }

    // ---- 收尾：三段式报告 + 结果卡（失败也出）----
    var outMd = ""
    var outHtml = ""
    var reportErr = ""
    try {
        let ctx = IpcContext("migrate", IpcHub())
        var rargs = JsonObject()
        rargs.put("path", JsonString(path))
        let rv = ReportCommand().handle("t2h:report", rargs, ctx)
        match (rv.kind()) {
            case JsonKind.JsObject =>
                outMd = jsonStrField(rv, "md")
                outHtml = jsonStrField(rv, "html")
                reportErr = jsonStrField(rv, "error")
            case _ => ()
        }
    } catch (e: Exception) {
        reportErr = "出报告失败：${e}"
    }

    var snap = MigrateState()
    synchronized(gMigrateLock) {
        gMigrate.reportMd = outMd
        gMigrate.reportHtml = outHtml
        if (reportErr.size > 0 && gMigrate.error.size == 0) {
            gMigrate.error = reportErr
        }
        gMigrate.finishedAt = nowText()
        gMigrate.running = false
        gMigrate.done = true
        gMigrate.current = ""
        gMigrate.message = "完成"
        snap = gMigrate.snapshot()
    }
    // 结果卡落 `.lingqu/migrate/<工程>.md`：重开机/换会话后也能翻出"上次一键跑到了哪"
    let resultPath = lqDirOf(path) + cjhPathSep() + "migrate" + cjhPathSep() + "${proj}.md"
    var resultErr = ""
    try {
        // 注意：这里要给的是**目录**，不是文件路径——ensureDirOf 会把每一段都当目录建
        ensureDirOf(lqDirOf(path) + cjhPathSep() + "migrate")
        File.writeTo(resultPath, migrateResultMarkdown(snap, if (outMd.size > 0) { outMd } else { "报告未生成" }).toArray())
    } catch (e: Exception) {
        resultErr = "写结果卡失败：${e}"
        eprintln("[lingqu][migrate] ${resultErr}")
    }
    synchronized(gMigrateLock) {
        gMigrate.resultMd = resultPath
        if (resultErr.size > 0 && gMigrate.error.size == 0) {
            gMigrate.error = resultErr
        }
    }
    eprintln("[lingqu][migrate] 结束：${migrateLogLine(snap)} 报告=${outMd}")
}

/**
 * t2h:migrate —— 一键迁移（起后台线程，立即返回）。
 *
 *   {path, applyPort?} → {ok, started, device}
 *
 * 同时只允许一个迁移在跑：两个线程同时改同一个工程（尤其 port apply）是灾难。
 */
public class MigrateCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        var res = JsonObject()
        if (path.size == 0) {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("一键迁移需要工程路径（或置 LINGQU_SCAN_PATH）"))
            return res
        }
        // 默认**自动应用**代码改造：一键迁移的意义就是把能自动做的都做掉；
        // 但改造逐文件留 .bak，随时可 t2h:revert 回滚（界面结果卡里会提示）。
        let applyPort = argBool(args, "applyPort", true)
        var busy = false
        synchronized(gMigrateLock) {
            busy = gMigrate.running
            if (!busy) {
                gMigrate.running = true
            }
        }
        if (busy) {
            res.put("ok", JsonBool(false))
            res.put("busy", JsonBool(true))
            res.put("error", JsonString("已经有一键迁移在跑，等它跑完或先停止"))
            eprintln("[lingqu][migrate] 拒绝重复启动（还在跑）")
            return res
        }
        let snapshotPath = path
        spawn {
            try {
                runMigrateChain(snapshotPath, applyPort)
            } catch (e: Exception) {
                eprintln("[lingqu][migrate] 线程异常：${e}")
                synchronized(gMigrateLock) {
                    gMigrate.running = false
                    gMigrate.done = true
                    gMigrate.error = "${e}"
                    gMigrate.message = "异常结束"
                    gMigrate.finishedAt = nowText()
                }
            }
        }
        res.put("ok", JsonBool(true))
        res.put("started", JsonBool(true))
        res.put("path", JsonString(path))
        res.put("applyPort", JsonBool(applyPort))
        res.put("pollWith", JsonString("t2h:migrate_status"))
        eprintln("[lingqu][migrate] 已启动：${path} applyPort=${applyPort}")
        // wait：给命令行用（`lingqu-cli migrate --wait` 要的是"跑完再打印结果"）。
        // 界面永远不传——界面靠轮询，不能把 IPC 堵死几分钟。
        if (argBool(args, "wait", false)) {
            var spins: Int64 = 0
            while (true) {
                var doneNow = false
                synchronized(gMigrateLock) {
                    doneNow = gMigrate.done
                }
                if (doneNow) {
                    break
                }
                sleep(Duration.millisecond * 500)
                spins += 1
                if (spins % 240 == 0) {
                    eprintln("[lingqu][migrate] 仍在跑（已等 ${spins / 2} 秒）")
                }
            }
            var snap = MigrateState()
            synchronized(gMigrateLock) {
                snap = gMigrate.snapshot()
            }
            return migrateStateJson(snap)
        }
        return res
    }
}

/**
 * t2h:migrate_status —— 读一键迁移的进度（纯读内存，页面 500~1000ms 轮询一次）。
 *
 * 返回 `migrateStateJson`：running/done/percent/verdict/rows/askPrompt/reportMd…
 * 页面据此画时间轴；`askPrompt` 非空时页面把失败现场自动发给 AI（G1/G2 的复用点）。
 */
public class MigrateStatusCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, _: JsonObject, _: IpcContext): JsonValue {
        var snap = MigrateState()
        synchronized(gMigrateLock) {
            snap = gMigrate.snapshot()
        }
        var o = migrateStateJson(snap)
        o.put("ok", JsonBool(true))
        // 设备状态的**两条口径**分开报（0.39.40）：
        //   `hasDevice`       = 本次迁移**开始时**的检测结果（决定要不要跳过 deploy/verify）
        //   `deviceInRecord`  = 落档里最近一次部署核实到的真机（`.lingqu/deploy/<工程>.json`）
        // 之前界面只显示前者，于是"开始时没插设备、中途插上了"就一直写着「未连接真机」——
        // 用户明明看见应用在真机上跑（落档 deploy 里 deviceCount=1、verify 100%）。
        let (devRec, devSerial) = deployDeviceOf(snap.project, snap.path)
        o.put("deviceInRecord", JsonBool(devRec))
        o.put("deviceSerial", JsonString(devSerial))
        o.put("deviceText", JsonString(deviceTextOf(snap.hasDevice, devRec, devSerial)))
        return o
    }
}

/** t2h:migrate_cancel —— 停止一键迁移（只在步骤之间生效：不打断正在跑的 cargo/hvigor） */
public class MigrateCancelCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, _: JsonObject, _: IpcContext): JsonValue {
        var was = false
        synchronized(gMigrateLock) {
            was = gMigrate.running
            if (was) {
                gMigrate.cancelled = true
            }
        }
        var res = JsonObject()
        res.put("ok", JsonBool(true))
        res.put("wasRunning", JsonBool(was))
        res.put("note", JsonString(if (was) { "已请求停止：当前步骤跑完就停（落档保留，可继续）" } else { "当前没有在跑的迁移" }))
        eprintln("[lingqu][migrate] cancel wasRunning=${was}")
        return res
    }
}

// ============================================================
// ⓪ AI 自动迁移（t2h:autoport_*）——**正题**：agent 是执行者，我们是眼睛与手刹
// ============================================================

/*
 * 与 `t2h:migrate`（确定性流程）的分工，别混：
 *   · migrate  ：我们按固定顺序跑 8 个命令（无模型、可复现）——它是 agent 的工具，也是无 AI 时的兜底
 *   · autoport ：把目标与工具箱交给 cjh，**它自己读落档 → 改代码 → 重跑**；我们只负责
 *                ① 准备现场（技能 / 工程 AGENTS.md / cjh 工作区 / 工具绝对路径）
 *                ② 写任务书（`buildAutoPortDirective`）
 *                ③ 盯落档：进度、停滞、预算；把"要人定的事"变成卡片
 * 判定永远只认落档 —— AI 说"迁好了"不算。
 */

let gAutoPortLock = Mutex()
let gAutoPort = AutoPortState()

/** `lingqu-cli` 可执行文件的候选位置（纯路径拼接；逐个判存在在 `resolveCliExe`） */
func cliExeCandidates(): Array<String> {
    let out = ArrayList<String>()
    let env = envOr("LINGQU_CLI", "")
    if (env.size > 0) {
        out.add(env)
    }
    // 开发态：cli/ 自己的产物
    out.add("cli/target/release/bin/main.exe")
    out.add("cli/target/release/bin/lingqu-cli.exe")
    // 发布态：和主程序同目录（packaging 会把 lingqu-cli 放旁边）
    out.add("lingqu-cli.exe")
    out.add("bin/lingqu-cli.exe")
    return out.toArray()
}

/** 找到能给 agent 用的 `lingqu-cli` **绝对路径**；找不到回空串（任务书会退化，不编假路径） */
func resolveCliExe(): String {
    // 必须是绝对路径：agent 的 bash cwd 是**目标工程**，相对路径 `cli\target\...` 在那里不存在。
    // 0.37.0 首次实跑就是这么断的（任务书里给了相对路径，AI 一次工具都没调起来）。
    let cwd = getWorkingDirectory().toString()
    for (c in cliExeCandidates()) {
        if (exists(Path(c))) {
            return hostPath(cwd + cjhPathSep() + c)
        }
    }
    return ""
}

/**
 * t2h:autoport_start —— 准备现场 + 交出任务书（真的干活的推理由页面走 WS 发给 cjh）。
 *
 *   {path, budget?, minutes?} → {ok, project, directive, cliPath, device, prep:{…}, steps:[…]}
 *
 * 为什么由页面发提问：cjh 的对话只有 WS 一条通道（`/ws` 的 `{type:"chat"}`），
 * 后端没有 WS 客户端；页面本来就连着，且能把流式回复直接显示给人看。
 */
public class AutoPortStartCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        var res = JsonObject()
        if (path.size == 0) {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("AI 自动迁移需要工程路径（或置 LINGQU_SCAN_PATH）"))
            return res
        }
        var name = projectNameOf(path)
        if (name.size == 0) {
            name = "project"
        }
        let safe = sanitizeFileName(name)
        let budget = argInt(args, "budget", AUTOPORT_MAX_ITERATIONS)
        let minutes = argInt(args, "minutes", AUTOPORT_MAX_MINUTES)
        // scope：`all` = 一键迁移（全自动）；`port`/`deps`/`build`/… = 左侧各屏的「🤖 交给 AI」（半自动）
        var scope = argStr(args, "scope", "all")
        if (scope.size == 0) {
            scope = "all"
        }

        // ---- ① 准备现场：技能 / 工程 AGENTS.md + 工作区 / 工具路径 ----
        // 三件都是幂等的；缺哪件 agent 就"看不见工具"，所以每次开始前补一遍（不猜、不静默失败）
        var skillNote = ""
        var skillOk = false
        try {
            var sargs = JsonObject()
            sargs.put("action", JsonString("install"))
            let sv = SkillCommand().handle("t2h:skill", sargs, IpcContext("autoport", IpcHub()))
            skillOk = cmdOkOf(sv)
            skillNote = if (skillOk) { "已装（~/.cjh/skills）" } else { "安装失败：见 t2h:skill 返回" }
        } catch (e: Exception) {
            skillNote = "安装异常：${e}"
        }
        var agentOk = false
        var agentNote = ""
        try {
            var aargs = JsonObject()
            aargs.put("action", JsonString("install"))
            aargs.put("path", JsonString(path))
            let av = AgentContextCommand().handle("t2h:agent_context", aargs, IpcContext("autoport", IpcHub()))
            agentOk = cmdOkOf(av)
            agentNote = if (agentOk) { "已写工程 AGENTS.md 区块并把 cjh 工作区切到该工程" }
                else { "写入失败：见 t2h:agent_context 返回" }
        } catch (e: Exception) {
            agentNote = "写入异常：${e}"
        }
        let cliPath = resolveCliExe()
        let device = migrateHasDevice()

        // ---- ② 当前落档（让 AI 一上手就知道从哪继续）----
        let rows = ArrayList<MigrateRow>()
        for (step in MIGRATE_STEPS) {
            let obs = observeTaskStepAt(safe, step, path)
            let row = MigrateRow()
            row.step = step
            row.title = taskStepTitle(step)
            row.ran = obs.exists
            row.ok = obs.exists && obs.ok
            row.note = obs.note
            rows.add(row)
        }
        var stateLines = ""
        for (r in rows) {
            if (stateLines.size > 0) {
                stateLines += "\n"
            }
            stateLines += migrateRowLine(r)
        }

        // ---- ③ 任务书 ----
        // 先把 cjh 的「断连不打断本轮」打开：AI 自动迁移是无人值守长任务，
        // 页面重连一次就把整轮 40+ 次工具调用作废，代价太大（0.39.7 实测）。
        // 这条配置不该让用户手改，启动时补上；结果回投给界面便于断言。
        let keepRunning = ensureCjhKeepRunning(userHomeDir())
        // MCP 知识库（0.39.130）：cjh 1.6.13 支持 transport:"http" 后，把华为 HarmonyOS
        // 开发者知识库端点注册进 cjh 工具箱——agent 干鸿蒙移植就有权威资料可查，
        // 不再只靠模型记忆。已有同名配置不覆盖；幂等。
        let mcpKms = ensureCjhMcpKms(userHomeDir())
        eprintln("[lingqu][autoport] MCP 知识库（${MCP_KMS_SERVER_NAME}）：${mcpKms}")
        // 轮次预算（0.39.53）：整应用迁移实测 41 轮就撞上 cjh 默认的 max_iterations=40，
        // 回合被截断、agent 没机会收尾（juCang 现场就是这样停住的）。
        // 0.39.82（用户实测 62/40 停了）：原来只调 ensureCjhIterationBudget——它写盘成功就返回
        // `file:…（需重启 cjh 生效）`，而**正在跑回合的引擎内存里还是 40**，于是"抬升"白做。
        // 现在改 enforceIterBudgetBeforeRun：要重启才生效的，就在开跑前重启（不拖到中途被截断）。
        let iterBudget = enforceIterBudgetBeforeRun(userHomeDir(), AUTOPORT_MIN_ITERATIONS)
        eprintln("[lingqu][autoport] 轮次预算：${iterBudget}")
        traceStartup("autoport 轮次预算：${iterBudget}", 0)
        let inp = AutoPortInput()
        inp.project = name
        inp.projectDir = path
        inp.cliPath = cliPath
        inp.device = device
        inp.budget = budget
        inp.minutes = minutes
        inp.stateLines = stateLines
        inp.scope = scope
        let directive = buildAutoPortDirective(inp)

        // 任务书**落进目标工程**（agent 的 cwd 就是那里），消息里只发短 kickoff。
        // 实测依据：4.4 KB 单帧发过去 cjh 静默丢弃，9 字短句正常（见 docs/上游回馈-cjh.md 排障进度）。
        let directivePath = path + cjhPathSep() + ".lingqu" + cjhPathSep() + "autoport-directive.md"
        var directiveErr = ""
        try {
            let ddir = path + cjhPathSep() + ".lingqu"
            if (!exists(Path(ddir))) {
                Directory.create(Path(ddir))
            }
            File.writeTo(directivePath, directive.toArray())
        } catch (e: Exception) {
            directiveErr = "写任务书失败：${e}"
            eprintln("[lingqu][autoport] ${directiveErr}")
        }
        let kickoff = if (directiveErr.size == 0) {
            buildAutoPortKickoff(directivePath)
        } else {
            // 写不进盘就退回整段发（可能被丢，但至少不留空）；同时在返回里如实带上错误
            directive
        }

        synchronized(gAutoPortLock) {
            gAutoPort.reset(path, safe, budget, minutes)
        }
        var res2 = JsonObject()
        res2.put("ok", JsonBool(true))
        res2.put("project", JsonString(name))
        res2.put("path", JsonString(path))
        res2.put("budget", JsonInt(budget))
        res2.put("minutes", JsonInt(minutes))
        res2.put("device", JsonBool(device))
        res2.put("scope", JsonString(scope))
        res2.put("scopeTitle", JsonString(autoPortScopeTitle(scope)))
        res2.put("cliPath", JsonString(cliPath))
        res2.put("directive", JsonString(directive))
        res2.put("directiveChars", JsonInt(Int64(directive.size)))
        res2.put("keepRunningOnDisconnect", JsonString(keepRunning))
        res2.put("iterationBudget", JsonString(iterBudget))
        res2.put("directivePath", JsonString(directivePath))
        res2.put("directiveError", JsonString(directiveErr))
        // 真正要发出去的是这条短消息（任务书靠 agent 自己 read）
        res2.put("kickoff", JsonString(kickoff))
        res2.put("kickoffChars", JsonInt(Int64(kickoff.size)))
        var prep = JsonObject()
        prep.put("skill", JsonBool(skillOk))
        prep.put("skillNote", JsonString(skillNote))
        prep.put("agentContext", JsonBool(agentOk))
        prep.put("agentNote", JsonString(agentNote))
        res2.put("prep", prep)
        res2.put("stateLines", JsonString(stateLines))
        eprintln("[lingqu][autoport] start project=${name} device=${device} cli=${cliPath} " +
            "skill=${skillOk} agent=${agentOk} 任务书=${directive.size} 字")
        return res2
    }
}

/**
 * t2h:autoport_status —— AI 自动迁移的进度（纯读落档 + 监管状态）。
 *
 *   {path?} → {ok, active, polls, stalled, verdict, escalation, percent, rows:[…], doneCount}
 *
 * 页面 3 秒轮一次：时间轴因此反映的是**AI 打到哪一步了**，而不是我们跑到哪一步了。
 */
public class AutoPortStatusCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        var project = ""
        var active = false
        var budget: Int64 = AUTOPORT_MAX_ITERATIONS
        var minutes: Int64 = AUTOPORT_MAX_MINUTES
        synchronized(gAutoPortLock) {
            if (path.size == 0) {
                path = gAutoPort.path
            }
            project = gAutoPort.project
            active = gAutoPort.active
            budget = gAutoPort.budget
            minutes = gAutoPort.minutes
        }
        var name = project
        if (name.size == 0) {
            name = sanitizeFileName(projectNameOf(path))
        }
        if (name.size == 0) {
            name = "project"
        }
        let rows = ArrayList<MigrateRow>()
        // 设备口径（0.39.133）：**AI 路径也要回投**。前端是拿 autoport_status 的返回喂
        // renderMigrate 的，之前这里没有 deviceInRecord ⇒ 永远显示「未连接真机（无部署记录）」，
        // 而同一轮 deploy 落档里明明有设备（用户实测：跑完 8 步全绿，那行字还写未连接）。
        let (devRec, devSerial) = deployDeviceOf(name, path)
        let hasDevNow = devRec || migrateHasDevice()
        for (step in MIGRATE_STEPS) {
            let obs = observeTaskStepAt(name, step, path)
            let row = MigrateRow()
            row.step = step
            row.title = taskStepTitle(step)
            row.ran = obs.exists
            row.ok = obs.exists && obs.ok
            row.note = obs.note
            // 起始快照 + 落档兜底：中途插上设备、或落档里已核实过，就不要再标「未连接真机」
            if (migrateNeedsDevice(step) && !hasDevNow) {
                row.skipped = "未连接真机"
            }
            rows.add(row)
        }
        // 停滞判定要带上 agent 活动量：分钟级交叉编译期间落档当然不动，
        // 只看落档会把"正在干活"误判成"在绕圈"（0.39.7 实测踩到）
        //
        // 0.39.34 再加一路活动量：**页面收到的 WS 帧数**（`activity`）。
        // 实测踩到的假停滞是这样的：agent 连续 30+ 秒都在"思考/流式回话"、一个工具都不调，
        // 落档不动、轨迹也不动 → 20 次轮询（3s × 20 = 60s）后判「AI 在绕圈」，
        // 可它其实一直在吐 delta 帧（界面在动）。页面把帧数带进来，这一整类误判就没了。
        let activity = argInt(args, "activity", 0)
        let sig = autoportSnapshotWith(rows, agentTraceLines(path)) + "|a=${activity}"
        // 但**单个长工具调用期间**连轨迹都不动（tool / tool_done 各一条）——
        // 这时按"正在干活"处理：不判停滞，并清空已攒的快照（否则工具一结束就立刻误报）
        //
        // 0.39.80：这个豁免**必须有上限**。工具一旦挂死（2026-11-07 实测：引擎的
        // `find /` 把工具调用挂住 565s+，trace.jsonl 再无 tool_done），busy 永远为真
        // ⇒ 停滞判定被永久清空 ⇒ 界面只剩「执行中 565s」，既不报停滞也不给建议。
        // 超过 AUTOPORT_BUSY_MAX_SECS 就恢复判定，并把 busySecs 回投给界面当证据。
        let busyRaw = agentTraceBusy(path)
        var busy = busyRaw
        var busySecs: Int64 = 0
        synchronized(gAutoPortLock) {
            if (busyRaw) {
                busySecs = gAutoPort.noteBusy(nowMsOf())
            } else {
                gAutoPort.clearBusy()
            }
        }
        if (busyRaw && !busyStillExempt(busySecs, AUTOPORT_BUSY_MAX_SECS)) {
            busy = false
        }
        // 0.39.41：**活干完了就不许判停滞**。全部步骤都有结论（通过或跳过）之后，
        // 落档/轨迹/帧数都不再变化是正常的——旧逻辑照样攒满 20 次快照就喊
        // 「AI 连续 20 次轮询落档没有变化，建议点「停止」后让它总结」，
        // 而用户看到的现场是：迁移全绿、报告已生成。这是"已完工"被当成"在绕圈"。
        let allConcluded = autoportAllConcluded(rows)
        var stalled = false
        var polls: Int64 = 0
        synchronized(gAutoPortLock) {
            if (gAutoPort.active) {
                if (busy || allConcluded) {
                    // agent 正在跑工具 / 或者活已经干完：清掉攒下的快照，且本轮不判停滞
                    gAutoPort.clearHistory()
                    gAutoPort.polls += 1
                } else {
                    gAutoPort.pushSig(sig)
                    stalled = isStalled(gAutoPort.history, AUTOPORT_STALL_POLLS)
                }
                polls = gAutoPort.polls
            }
        }
        let done = autoportDoneCount(rows)
        let concluded = autoportConcludedCount(rows)
        // 0.39.88 第三态「已交接」：agent 自己收尾了，落档里还有没结论的步骤。
        // 判据全部来自落档/轨迹（turn_done + 未完成 + 没工具在跑），不依赖页面记忆——
        // 页面被刷新/换屏也不该改变"到底谁在干活"这个事实。
        let turnEnded = agentTraceTurnEnded(path)
        let handoff = handoffDue(turnEnded, allConcluded, busy)
        var verdict = autoportVerdict(rows, allConcluded || !active, stalled)
        var escalation = escalationLineFor(stalled, false, minutes, allConcluded)
        if (handoff) {
            verdict = autoportHandoffVerdict(rows)
            escalation = handoffEscalation(rows)
        }
        var arr = JsonArray()
        for (r in rows) {
            arr.add(r.toJson())
        }
        var o = JsonObject()
        o.put("ok", JsonBool(true))
        o.put("active", JsonBool(active))
        o.put("project", JsonString(name))
        o.put("path", JsonString(path))
        o.put("polls", JsonInt(polls))
        o.put("budget", JsonInt(budget))
        o.put("minutes", JsonInt(minutes))
        o.put("doneCount", JsonInt(done))
        o.put("concludedCount", JsonInt(concluded))
        o.put("finished", JsonBool(allConcluded))
        o.put("total", JsonInt(Int64(MIGRATE_STEPS.size)))
        o.put("percent", JsonInt(done * 100 / Int64(MIGRATE_STEPS.size)))
        o.put("stalled", JsonBool(stalled))
        o.put("busySecs", JsonInt(busySecs))
        o.put("turnEnded", JsonBool(turnEnded))
        o.put("handoff", JsonBool(handoff))
        // 设备三件套（0.39.133）：AI 路径的起始检测我们没存 ⇒ hasDevice 传 false，
        // 靠落档那档说话；前端优先用这里的 deviceText（口径单点在 deviceTextOf）。
        o.put("deviceInRecord", JsonBool(devRec))
        o.put("deviceSerial", JsonString(devSerial))
        o.put("deviceText", JsonString(deviceTextOf(false, devRec, devSerial)))
        o.put("verdict", JsonString(verdict))
        o.put("escalation", JsonString(escalation))
        // 飞轮有没有真的转（R-1 判据位）：跑完一轮 `.lingqu/notes/<工程>.md` 还是空的，
        // 就说明"撞了坑没落经验"。2026-11-19 首轮实测：EcoPaste 连撞 4 次坑，
        // notes / diagnose / pr 三目录全空，而界面上只显示"步骤失败"，看不出这件事。
        let notesFile = resolveLqPath(path, "notes/${name}.md")
        var notesBytes: Int64 = 0
        if (exists(Path(notesFile))) {
            notesBytes = File.readFrom(notesFile).size
        }
        o.put("flywheelNotesBytes", JsonInt(notesBytes))
        o.put("flywheelNotesPresent", JsonBool(notesBytes > 0))
        // R-1 观测侧（0.39.129）：连撞 ≥2 步而 notes 空 → 界面提醒（flywheelHintOf 纯函数单测钉住）
        o.put("flywheelHint", JsonString(flywheelHintOf(rows, notesBytes > 0)))
        o.put("rows", arr)
        return o
    }
}

/** t2h:autoport_stop —— 监管状态收尾（页面同时会发 WS abort 真正打断模型回合） */
public class AutoPortStopCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, _: JsonObject, _: IpcContext): JsonValue {
        var was = false
        synchronized(gAutoPortLock) {
            was = gAutoPort.active
            gAutoPort.stop()
        }
        var res = JsonObject()
        res.put("ok", JsonBool(true))
        res.put("wasActive", JsonBool(was))
        eprintln("[lingqu][autoport] stop wasActive=${was}")
        return res
    }
}

/**
 * t2h:agent_trace —— 记一条 agent 行为轨迹（0.39.0）。
 *
 *   {path, kind, name, detail} → 追加一行到 `<工程>/.lingqu/agent/trace.jsonl`
 *
 * 为什么要我们自己记：cjh 的 web 会话**只在销毁时落盘**，跑完的回合在 `~/.cjh/sessions/`
 * 里仍只有 system 消息（实测 158 B）——"AI 改了什么、跑了哪些命令"没有留痕。
 * 页面已经收到 `tool_start`/`tool_result` 帧，落到**工程的** `.lingqu/agent/` 里，
 * 和 scan/build 落档同源，agent 自己也能读它自检（ADR D-015：我们是记录员）。
 *
 * 只追加、不读改写；写失败进 outError，不抛。
 */
public class AgentTraceCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        // 注意：这里以前误粘了 `SignCommand` 的 `--login`（AGC 登录）分支——
        // 一旦机器上导出了 `LINGQU_SIGN_LOGIN=1`，页面每记一条轨迹就会去跑一次登录。
        // 0.39.34 删除。轨迹命令只做一件事：追加一行。
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        let kind = argStr(args, "kind", "note")
        let name = argStr(args, "name", "")
        let detail = argStr(args, "detail", "")
        let line = agentTraceLine(nowText(), kind, name, detail)
        let err = appendAgentTrace(path, line)
        var res = JsonObject()
        res.put("ok", JsonBool(err.size == 0))
        res.put("file", JsonString(tracePathOf(path)))
        res.put("kind", JsonString(kind))
        res.put("lines", JsonInt(agentTraceLines(path)))
        res.put("outError", JsonString(err))
        if (err.size > 0) {
            eprintln("[lingqu][trace] ${err}")
        }
        return res
    }
}

/**
 * t2h:cli_run —— 把 AI 建议的命令**一键执行**（AI 接入第 4 步）。
 *
 * 安全边界在 `cliRunAllowed`（纯函数 + 单测）：只读/幂等可回滚的才放开；
 * 会动真机（deploy）、会改用户工程（port/revert）、耗时且有产物（hap）、
 * 会改签名配置（sign --apply）的一律拒绝，并告诉人"该去哪个界面点"。
 *
 * 参数：{cmd, flags?, preflight?}（flags 是 JsonObject，原样转成 `--键 值`）
 * 返回：{ok, cmd, allowed, auto, reason, exitCode, result:{…}}
 *   · `auto=true` 表示这条命令在**自动执行**白名单里（只说能跑，不代表已经跑了）
 *   · `preflight=true` 只回答 `allowed/auto`，不执行——页面的自动执行靠它先筛
 */
public class CliRunCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        let cmd = argStr(args, "cmd", "")
        var flags = JsonObject()
        match (args.get("flags")) {
            case Some(v) =>
                match (v.kind()) {
                    case JsonKind.JsObject => flags = v.asObject()
                    case _ => ()
                }
            case None => ()
        }
        let (allowed, reason) = cliRunAllowed(cmd, flags)

        var res = JsonObject()
        res.put("cmd", JsonString(cmd))
        res.put("allowed", JsonBool(allowed))
        res.put("reason", JsonString(reason))
        // auto：这条命令能不能**不经人点**就自动跑（G3，`cliAutoRunAllowed` 白名单）
        res.put("auto", JsonBool(cliAutoRunAllowed(cmd, flags)))
        // preflight：只问"能不能自动跑"，不执行——页面的自动执行靠它先筛一遍，
        // 免得自动点下去才被拒（那样界面上会冒一排"请在界面里点"，噪音且误导）
        if (argBool(args, "preflight", false) || !allowed) {
            res.put("ok", JsonBool(false))
            res.put("preflight", JsonBool(true))
            res.put("exitCode", JsonInt(-2))
            res.put("result", JsonObject())
            if (!allowed) {
                eprintln("[lingqu][cli_run] 拒绝 ${cmd}：${reason}")
            } else {
                eprintln("[lingqu][cli_run] preflight ${cmd}: auto=${cliAutoRunAllowed(cmd, flags)}")
            }
            return res
        }
        if (!cliCommandSupported(cmd)) {
            res.put("ok", JsonBool(false))
            res.put("exitCode", JsonInt(-3))
            res.put("reason", JsonString("CLI 里没有这个命令：${cmd}"))
            res.put("result", JsonObject())
            return res
        }

        // 组装 argv：`cmd --k v …`（布尔 false 的开关不带，省得命令行里出现 --x=false）
        let argv = ArrayList<String>()
        argv.add(cmd)
        for ((k, v) in flags.getFields()) {
            match (v.kind()) {
                case JsonKind.JsBool =>
                    if (v.asBool().getValue()) {
                        argv.add("--" + k)
                    }
                case JsonKind.JsString =>
                    let s = v.asString().getValue()
                    if (s != "") {
                        argv.add("--" + k)
                        argv.add(s)
                    }
                case JsonKind.JsInt =>
                    argv.add("--" + k)
                    argv.add(v.asInt().getValue().toString())
                case _ => ()
            }
        }
        let run = dispatchCli(argv.toArray())
        var inner: JsonValue = JsonObject()
        if (run.json != "") {
            try {
                inner = JsonValue.fromStr(run.json)
            } catch (e: Exception) {
                let _ = e
            }
        }
        res.put("ok", JsonBool(run.exitCode == 0 && run.error == ""))
        res.put("exitCode", JsonInt(run.exitCode))
        res.put("result", inner)
        if (run.error != "") {
            res.put("error", JsonString(run.error))
        }
        eprintln("[lingqu][cli_run] ${cmd} exit=${run.exitCode} allowed=${allowed}")
        return res
    }
}

/**
 * t2h:deploy —— 真机部署与启动体检（T5-5 命令化，0.21.0）。 *
 * 把 0.17.0 手工跑通的那条链做成命令：`hdc list targets` → `hdc install -r` → `aa start` → 抓 hilog。
 * 两条纪律来自真机实测，别改成"看起来更顺"的写法：
 *   · **hdc 失败时退出码仍是 0**（AGENTS §4-40）——成败只看输出文本，交给 deploy.cj 的解析层
 *   · **安装成功 ≠ 界面出来**（§4-45）：装 / 启 / 日志三段分开报，最靠前的那段失败才是真因
 *
 * 落档：`.lingqu/deploy/<工程>.json`（lingqu/deploy/v1）+ `.log`（三段 hdc 原文 + hilog 尾部）
 */
public class DeployCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_DEPLOY_PATH", "")
        }
        if (path.size == 0) {
            path = envOr("LINGQU_HAP_PATH", "")
        }
        var res = JsonObject()
        let hdc = hdcPathOr()
        if (hdc == "") {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("找不到 hdc（找过 OHOS_HOME / DEVECO_SDK_HOME / DEVECO_HOME 下的 toolchains）"))
            return res
        }

        // ---- 工程位置：bundleName / ability / HAP 产物 ----
        var bundleName = ""
        var ohosDir = ""
        var projName = "unknown"
        if (path.size > 0) {
            projName = sanitizeFileName(projectNameOf(path))
            let tomlPath = cargoTomlPathOf(path)
            if (tomlPath != "") {
                let srcDir = tomlPath[0..(tomlPath.size - "/Cargo.toml".size)]
                ohosDir = hostPath("${srcDir}/gen/ohos")
                let appJson = "${ohosDir}/AppScope/app.json5"
                if (exists(Path(appJson))) {
                    try {
                        bundleName = json5ValueAfter(lenientUtf8(File.readFrom(appJson)), "bundleName")
                    } catch (e: Exception) {
                        let _ = e
                    }
                }
            }
        }
        var hapPath = argStr(args, "hap", "")
        if (hapPath == "") {
            hapPath = envOr("LINGQU_DEPLOY_HAP", "")
        }
        if (hapPath == "" && ohosDir != "") {
            hapPath = "${ohosDir}/entry/build/default/outputs/default/entry-default-signed.hap"
        }
        var ability = argStr(args, "ability", "")
        if (ability == "") {
            ability = "EntryAbility"
        }
        let wantStart = argBool(args, "start", true)
        let logLines = argInt(args, "logLines", 40)

        // ---- ① 设备 ----
        var listText = ""
        try {
            let (code, out, errOut) = executeWithOutput(hdc, ["list", "targets", "-v"])
            listText = lenientUtf8(out) + "\n" + lenientUtf8(errOut)
            let _ = code
        } catch (e: Exception) {
            listText = "hdc 起不来：${e}"
        }
        let devices = parseHdcTargets(listText)
        var serial = argStr(args, "serial", "")
        if (serial == "") {
            serial = envOr("LINGQU_DEPLOY_SERIAL", "")
        }
        if (serial == "" && devices.size > 0) {
            serial = devices[0].serial
        }
        var serialOk = false
        if (serial != "") {
            if (devices.size == 0) {
                serialOk = true   // 列表拿不到（老版本 hdc）时信任显式 serial
            } else {
                for (d in devices) {
                    if (d.serial == serial) {
                        serialOk = true
                    }
                }
            }
        }

        // ---- ② 安装 ----
        var installText = ""
        var installStep = DeployStep("install", false, "未执行", 0)
        if (serialOk) {
            if (!exists(Path(hapPath))) {
                installStep = DeployStep("install", false, "找不到 HAP：${hapPath}（先跑「装配 HAP」）", 0)
            } else {
                try {
                    let (code, out, errOut) = executeWithOutput(hdc, ["-t", serial, "install", "-r", hapPath])
                    installText = lenientUtf8(out) + "\n" + lenientUtf8(errOut)
                    installStep = parseInstallResult(installText, code)
                    // `9568332 install sign info inconsistent`：同包名已装过**另一套签名**的版本。
                    // 自动签名会换材料（旧证书过期后必须换），重签后再装必然撞这个码 →
                    // 先卸载再装一次（调试机上这是常规动作，不动用户数据之外的东西）。
                    if (!installStep.ok && installStep.failCode == 9568332 && bundleName != "") {
                        let (_, uOut, uErrOut) = executeWithOutput(hdc,
                            ["-t", serial, "shell", "bm", "uninstall", "-n", bundleName])
                        let unText = (String.fromUtf8(uOut) + "\n" + String.fromUtf8(uErrOut)).trimAscii()
                        try {
                            let (code2, out2, errOut2) = executeWithOutput(hdc,
                                ["-t", serial, "install", "-r", hapPath])
                            installText = installText + "\n-- 卸载后重装（${unText}）--\n" +
                                String.fromUtf8(out2) + "\n" + String.fromUtf8(errOut2)
                            installStep = parseInstallResult(String.fromUtf8(out2) + String.fromUtf8(errOut2),
                                code2)
                            if (installStep.ok) {
                                installStep.detail = installStep.detail + "（先卸载了旧签名的同包名版本）"
                            }
                        } catch (e2: Exception) {
                            installStep.detail = installStep.detail + " ｜ 卸载后重装失败：${e2}"
                        }
                    }
                } catch (e: Exception) {
                    installStep = DeployStep("install", false, "hdc install 起不来：${e}", 0)
                }
            }
        }

        // ---- ③ 启动 ----
        var startText = ""
        var startStep = DeployStep("start", false, "未执行", 0)
        if (!wantStart) {
            startStep = DeployStep("start", true, "按参数跳过启动", 0)
        } else if (serialOk && installStep.ok) {
            if (bundleName == "") {
                startStep = DeployStep("start", false, "读不到 bundleName（AppScope/app.json5），可用 bundle 参数指定", 0)
            } else {
                try {
                    let (code, out, errOut) = executeWithOutput(hdc,
                        ["-t", serial, "shell", "aa", "start", "-a", ability, "-b", bundleName])
                    startText = lenientUtf8(out) + "\n" + lenientUtf8(errOut)
                    startStep = parseStartResult(startText, code)
                } catch (e: Exception) {
                    startStep = DeployStep("start", false, "aa start 起不来：${e}", 0)
                }
            }
        }

        // ---- ④ hilog（启动后抓尾部，判崩溃）----
        var hilogText = ""
        var healthy = true
        if (serialOk && startStep.ok) {
            try {
                let (code, out, errOut) = executeWithOutput(hdc, ["-t", serial, "shell", "hilog", "-x"])
                hilogText = lenientUtf8(out) + "\n" + lenientUtf8(errOut)
                let _ = code
                healthy = hilogLooksHealthy(hilogText)
            } catch (e: Exception) {
                hilogText = "抓 hilog 失败：${e}"
            }
        }
        let tailLines = hilogTail(hilogText, logLines)

        // ---- 判定 ----
        let verdict = judgeDeploy(serialOk, installStep.ok, startStep.ok, healthy, serial,
            installStep.failCode)
        // 启动失败时别一律怪"ability 名写错"：锁屏（10106102）是最常见的一类，
        // 它的处置是"解锁后重试"，跟名字无关（实测误导过一轮，见 FP-014）
        if (!startStep.ok && startStep.failCode == 10106102) {
            verdict.reason = "装上了，但设备锁屏拒绝自动拉起（设备 ${serial}，10106102）"
            verdict.nextStep = "解锁设备后重跑 deploy --start（开发者模式下无法自动解锁）"
        }

        // ---- 落档 ----
        var outError = ""
        var outJson = ""
        var outLog = ""
        var logText = "[devices]\n" + listText + "\n"
        logText += "[install] serial=${serial} ok=${installStep.ok} code=${installStep.failCode}\n" + installText + "\n"
        logText += "[start] ok=${startStep.ok}\n" + startText + "\n"
        logText += "[hilog] healthy=${healthy} lines=${tailLines.size}\n"
        for (line in tailLines) {
            logText += line + "\n"
        }
        try {
            let dDir = lqDirOf(path) + cjhPathSep() + "deploy"
            ensureDirOf(dDir)
            outJson = dDir + cjhPathSep() + "${projName}.json"
            outLog = dDir + cjhPathSep() + "${projName}.log"
            File.writeTo(outLog, logText.toArray())
            var root = JsonObject()
            root.put("schema", JsonString("lingqu/deploy/v1"))
            root.put("project", JsonString(projName))
            root.put("hdc", JsonString(hdc))
            root.put("serial", JsonString(serial))
            root.put("deviceCount", JsonInt(Int64(devices.size)))
            root.put("hapPath", JsonString(hapPath))
            root.put("bundleName", JsonString(bundleName))
            root.put("ability", JsonString(ability))
            root.put("install", installStep.toJson())
            root.put("start", startStep.toJson())
            root.put("hilogHealthy", JsonBool(healthy))
            root.put("hilogLines", JsonInt(Int64(tailLines.size)))
            root.put("verdict", verdict.toJson())
            File.writeTo(outJson, root.toJsonString().toArray())
        } catch (e: Exception) {
            outError = "落档失败：${e}"
        }

        res.put("ok", JsonBool(verdict.ok && outError == ""))
        res.put("serial", JsonString(serial))
        res.put("deviceCount", JsonInt(Int64(devices.size)))
        res.put("hapPath", JsonString(hapPath))
        res.put("bundleName", JsonString(bundleName))
        res.put("installed", JsonBool(installStep.ok))
        res.put("installDetail", JsonString(installStep.detail))
        res.put("installCode", JsonInt(installStep.failCode))
        res.put("started", JsonBool(startStep.ok))
        res.put("startDetail", JsonString(startStep.detail))
        res.put("hilogHealthy", JsonBool(healthy))
        res.put("hilogLines", JsonInt(Int64(tailLines.size)))
        res.put("reason", JsonString(verdict.reason))
        res.put("nextStep", JsonString(verdict.nextStep))
        res.put("outJson", JsonString(outJson))
        res.put("outLog", JsonString(outLog))
        var em = outError
        if (em == "" && !verdict.ok) {
            em = verdict.reason
        }
        res.put("error", JsonString(em))
        eprintln("[lingqu][deploy] ${projName} serial=${serial} installed=${installStep.ok} " +
            "started=${startStep.ok} hilogHealthy=${healthy} ok=${verdict.ok}")
        return res
    }
}

/** 签名配置 → JSON（落档用） */
func signingJson(proj: ProjSigning, certPath: String, profilePath: String, storeFile: String,
    filesExist: Bool): JsonObject {
    var o = JsonObject()
    o.put("configuredName", JsonString(proj.signingConfigName))
    o.put("certType", JsonString(proj.certType))
    o.put("certPath", JsonString(certPath))
    o.put("profilePath", JsonString(profilePath))
    o.put("storeFile", JsonString(storeFile))
    o.put("filesExist", JsonBool(filesExist))
    return o
}

/**
 * 工程里写的材料路径可能是相对路径（相对 `gen/ohos`）。
 * 先按原样判存在，不行再拼工程根，最后原样返回（让上层如实报"不存在"）。
 */
func resolveProjectPath(p: String, base: String): String {
    if (p == "") {
        return ""
    }
    if (exists(Path(p))) {
        return p
    }
    if (base == "") {
        return p
    }
    let joined = "${base}/${p}"
    if (exists(Path(joined))) {
        return joined
    }
    return p
}

/** 找到"用同一套材料"的工程：返回 (donor 工程路径, 它的 signingConfigs 字段) */
public class DonorHit {
    public var donorPath: String = ""
    public var material: SigningMaterial = SigningMaterial()
}

/**
 * 找能提供口令密文的 donor 工程。
 *
 * 为什么要找：`storePassword` / `keyPassword` 是 DevEco **AesGcmKit 密文**（随机口令 + `material/`
 * 密钥派生），我们既拿不到明文也造不出密文；但只要**同一个 `.p12`**，那份密文就是通用的，
 * 于是从别的工程"搬"过来即可。搜索范围限定在几个常见的工程目录（深度有限），避免全盘扫。
 */
func findDonorMaterial(p12Path: String, explicitDonor: String): Option<DonorHit> {
    var candidates = ArrayList<String>()
    // 显式指定：可以是工程根（含 src-tauri/gen/ohos），也可以是直接指向 build-profile.json5
    if (explicitDonor != "") {
        if (exists(Path(explicitDonor))) {
            collectBuildProfiles(explicitDonor, 0, 5, candidates)
        }
    }
    if (candidates.size == 0) {
        let home = firstNonEmpty([envOr("USERPROFILE", ""), envOr("HOME", "")])
        if (home != "") {
            for (sub in ["DevEcoStudioProjects", "Documents", "Desktop"]) {
                let root = hostPath("${home}/${sub}")
                if (exists(Path(root))) {
                    collectBuildProfiles(root, 0, 4, candidates)
                }
            }
        }
    }
    for (p in candidates) {
        var text = ""
        try {
            text = lenientUtf8(File.readFrom(p))
        } catch (e: Exception) {
            let _ = e
            continue
        }
        let m = signingMaterialOf(text)
        if (!m.complete()) {
            continue
        }
        if (!sameMaterialFile(m.storeFile, p12Path)) {
            continue
        }
        // donor 工程路径：build-profile.json5 往上两级（…/gen/ohos/build-profile.json5）
        let hit = DonorHit()
        hit.donorPath = p
        hit.material = m
        return Some(hit)
    }
    return None
}

/** 递归收集 `build-profile.json5`（限深度、跳过重型目录；Directory.walk 非递归，所以自己走） */
func collectBuildProfiles(dir: String, depth: Int64, maxDepth: Int64, out: ArrayList<String>): Unit {
    if (depth > maxDepth) {
        return
    }
    var entries: Array<FileInfo>
    try {
        entries = Directory.readFrom(dir)
    } catch (e: Exception) {
        let _ = e
        return
    }
    for (info in entries) {
        if (info.isDirectory()) {
            let n = info.name
            if (n == ".git" || n == "node_modules" || n == "oh_modules" || n == "target" ||
                n == "build" || n == ".hvigor" || n == ".gradle") {
                continue
            }
            collectBuildProfiles("${dir}/${n}", depth + 1, maxDepth, out)
        } else if (info.name == "build-profile.json5") {
            out.add("${dir}/${info.name}")
        }
    }
}

/** hdc 位置：OHOS_HOME / DEVECO_SDK_HOME / DEVECO_HOME 下的 toolchains（找不到返回 ""） */func hdcPathOr(): String {
    var cands = ArrayList<String>()
    let ohosHome = envOr("OHOS_HOME", "")
    if (ohosHome != "") {
        cands.add("${ohosHome}/toolchains/hdc.exe")
        cands.add("${ohosHome}/toolchains/hdc")
    }
    let deveco = devecoHomeOr()
    let sdk = firstExistingPath([envOr("DEVECO_SDK_HOME", ""), "${deveco}/sdk"])
    if (sdk != "") {
        cands.add("${sdk}/default/openharmony/toolchains/hdc.exe")
        cands.add("${sdk}/default/openharmony/toolchains/hdc")
    }
    for (c in cands) {
        if (exists(Path(c))) {
            return hostPath(c)
        }
    }
    return ""
}

/** DevEco 位置：DEVECO_HOME 优先，其次常见安装路径（都不存在返回 ""） */func devecoHomeOr(): String {
    let fromEnv = envOr("DEVECO_HOME", "")
    if (fromEnv.size > 0 && exists(Path(fromEnv))) {
        return fromEnv
    }
    for (cand in ["D:/oh/DevEcoStudio", "C:/Program Files/Huawei/DevEco Studio"]) {
        if (exists(Path(cand))) {
            return cand
        }
    }
    return ""
}

/**
 * 纯函数：把 PATH 变量值拆成目录列表（去空、去首尾空白；sep 显式传入）。
 *
 * sep 不按宿主机猜：Windows 用 `;`（路径里本来就带 `:`，按 `:` 切会把盘符切开），
 * POSIX 用 `:`。显式传入还有个好处——纯函数，两端都能被单测钉住。
 */
public func pathDirsOf(pathEnv: String, sep: String): Array<String> {
    var out = ArrayList<String>()
    if (pathEnv.size == 0) {
        return out.toArray()
    }
    for (part in pathEnv.split(sep, -1)) {
        let dir = part.trimAscii()
        if (dir.size == 0) {
            continue
        }
        if (!out.contains(dir)) {
            out.add(dir)
        }
    }
    return out.toArray()
}

/**
 * 纯函数：llvm-mingw 的候选安装根（去空、保序去重）。
 * 安装位置五花八门：`C:\tool\llvm-mingw*`（本机就装这儿，带版本号）、
 * `%ProgramFiles%\llvm-mingw*`、以及不带版本号的旧目录。
 */
public func llvmMingwRootsOf(toolDir: String, programFiles: String, programFilesX86: String): Array<String> {
    var out = ArrayList<String>()
    for (r in [toolDir.trimAscii(), programFiles.trimAscii(), programFilesX86.trimAscii()]) {
        if (r.size == 0 || out.contains(r)) {
            continue
        }
        out.add(r)
    }
    return out.toArray()
}

/** 目录里名字以 `llvm-mingw` 开头的子目录（读不到就当没有，绝不抛） */
func llvmMingwDirsUnder(root: String): Array<String> {
    var out = ArrayList<String>()
    if (root.size == 0 || !exists(Path(root))) {
        return out.toArray()
    }
    var entries: Array<FileInfo>
    try {
        entries = Directory.readFrom(root)
    } catch (e: Exception) {
        let _ = e
        return out.toArray()
    }
    for (info in entries) {
        // 目录名判定用纯函数（发行包的目录名一律小写：llvm-mingw-20260324-ucrt-x86_64）
        if (info.isDirectory() && isLlvmMingwDirName(info.name)) {
            out.add(joinPath(root, info.name))
        }
    }
    return out.toArray()
}

/** 纯函数：目录名像不像 llvm-mingw 的发行目录（只按前缀判，不猜版本号格式） */
public func isLlvmMingwDirName(name: String): Bool {
    return name.trimAscii().startsWith("llvm-mingw")
}

/**
 * llvm-mingw 的 clang 候选（0.39.95）。
 *
 * 判据是「构建时能不能按名字找到它」，不是「某个目录里有没有文件」——cargo 是按名字
 * 在 PATH 上找链接器的。旧实现写死 `C:\tool\llvm-mingw\bin\…`，而本机装的是带版本号的
 * 目录（`C:\tool\llvm-mingw-20260324-ucrt-x86_64\bin`，且只在 PATH 里）⇒ 明明能用却报「缺失」。
 */
func llvmMingwClangCandidates(): Array<String> {
    let exe = "x86_64-w64-mingw32-clang.exe"
    var out = ArrayList<String>()
    // ① PATH 上那份就是构建真正会用到的那份；PATH 里可能放的是安装根，再补一层 bin
    var pathEnv = envOr("PATH", "")
    if (pathEnv.size == 0) {
        pathEnv = envOr("Path", "")
    }
    for (dir in pathDirsOf(pathEnv, ";")) {
        out.add(joinPath(dir, exe))
        out.add(joinPath(joinPath(dir, "bin"), exe))
    }
    // ② 常见安装根下的版本化目录
    let roots = llvmMingwRootsOf(
        joinPath(envOr("SystemDrive", "C:"), "\\tool"),
        envOr("ProgramFiles", ""),
        envOr("ProgramFiles(x86)", ""))
    for (root in roots) {
        for (d in llvmMingwDirsUnder(root)) {
            out.add(joinPath(joinPath(d, "bin"), exe))
        }
    }
    // ③ 旧的不带版本号目录兜底
    out.add("C:\\tool\\llvm-mingw\\bin\\${exe}")
    return out.toArray()
}

/** 把路径分隔符统一成宿主形式（Windows 用反斜杠；其它平台保持正斜杠） */
func hostPath(p: String): String {
    if (!hostIsWindows()) {
        return p
    }
    return p.replace("/", "\\")
}

/** 取第一个非空字符串 */
func firstNonEmpty(cands: Array<String>): String {
    for (c in cands) {
        if (c.size > 0) {
            return c
        }
    }
    return ""
}

/**
 * 取第一个**在磁盘上存在**的路径候选；都不存在返回 ""。
 * 用于"环境变量 vs 推导值"二选一：环境变量可能是过期值（本机就踩到过），不能盲信。
 */
func firstExistingPath(cands: Array<String>): String {
    for (c in cands) {
        if (c.size > 0 && exists(Path(c))) {
            return c
        }
    }
    return ""
}

/** 取整数参数（缺失/类型不符回默认值） */
func argInt(args: JsonObject, key: String, fallback: Int64): Int64 {
    match (args.get(key)) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsInt => return v.asInt().getValue()
            case JsonKind.JsFloat => return Int64(v.asFloat().getValue())
            case _ => return fallback
        }
        case None => return fallback
    }
}

/** 取字符串参数 */
func argStr(args: JsonObject, key: String, fallback: String): String {
    match (args.get(key)) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsString => return v.asString().getValue()
            case _ => return fallback
        }
        case None => return fallback
    }
}

/** 取布尔参数 */
func argBool(args: JsonObject, key: String, fallback: Bool): Bool {
    match (args.get(key)) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsBool => return v.asBool().getValue()
            case _ => return fallback
        }
        case None => return fallback
    }
}

/**
 * 装配：命令注册 + 引擎接线。
 * 新命令记得同步 assets/capabilities/default.json，否则前端拿到 command not allowed。
 */
public func build(): AppSpec {
    return AppSpec()
        .window(WindowConfig("lingqu", 1280, 840))
        // 日志落盘：GUI 产物双击没控制台，报障时一个文件看全
        // 原生「选目录」框：让"设工程路径"不只有手敲一条路（dialog:pickFolder）
        .plugin(DialogPlugin())
        .plugin(LogPlugin())
        // WS：cjh 的对话/工具/审批都走 ws://127.0.0.1:<port>/ws（帧类型见 docs/实施路线图.md P1）
        .plugin(WsPlugin())
        .wire({ app =>
            // 隐藏控制台（0.39.40）：GUI 子系统没有 console，于是每次 executeWithOutput 都会给
            // 子进程新配一个黑窗口（hdc / cargo / hvigor / git / java / curl 各闪一下），
            // cjh 里再拉 bash/find 也各自闪。先给本进程分一个**看不见**的 console，子进程继承它即可。
            gConsoleHidden = ensureHiddenConsole()
            // OpenSSL 预加载（0.39.65）：WS 握手要 RAND_bytes，而 libcrypto-3-x64.dll /
            // libssl-3-x64.dll 是"按裸名加载"、SDK 与 stdx 都不带 —— 不预加载就表现为
            // 「浏览器能开 8765，应用却永远未连接」。必须早于任何 ws:connect。
            let sslNote = preloadOpensslLibs()
            eprintln("[lingqu] openssl: ${sslNote}")
            // 日志落盘：GUI 产物双击没控制台，报障时一个文件看全（C 桥 + 仓颉 + 页面 log:write）
            let _ = app.setLogToDefaultFile("lingqu")

            // 资产解析：**内嵌优先、缺则读盘**（单文件打包用，见 src/packed_resources.cj）。
            // 骨架默认注入 DirectoryAssetResolver("assets")，这里换成我们的版本——打包产物里页面
            // 来自 PACKED_UI_B64，于是不再需要 assets/ 目录，也不会再因为"工作目录不是包根"加载不到页面。
            let _ = app.assets(LingquAssetResolver("assets"))
            // 能力清单同理：单文件产物没有 assets/capabilities 目录，清单编在二进制里。
            // 装配顺序上 wire() 在 loadCapabilities() 之后跑，所以在这里补挂（0 份 = 仓库内构建，等于不做事）。
            for (capsJson in embeddedCapabilityJsons()) {
                let _ = app.addCapabilityJson(JsonValue.fromStr(capsJson))
            }

            app.register("t2h:env", EnvCommand())
        app.register("t2h:git_clone", GitCloneCommand())
            app.register("t2h:quit", QuitCommand(app))
            app.register("t2h:ui_report", UiReportCommand())
            app.register("t2h:scan", ScanCommand())
            app.register("t2h:deps", DepsCommand())
            app.register("t2h:port", PortCommand())
            app.register("t2h:revert", RevertCommand())
            app.register("t2h:decisions", DecisionsCommand())
            app.register("t2h:diagnose", DiagnoseCommand())
            app.register("t2h:pr_prepare", PrPrepareCommand())
    app.register("t2h:notes", NotesCommand())
        app.register("t2h:build", BuildCommand())
        app.register("t2h:hap", HapCommand())
        app.register("t2h:sign", SignCommand())
        // 后台登录（0.39.82）：界面要给出可点链接，而不是让人从聊天里抄 URL
        app.register("t2h:sign_login", SignLoginCommand())
        app.register("t2h:sign_login_status", SignLoginStatusCommand())
        // 界面里的链接统一走系统浏览器（0.39.82）：WebView 的 target=_blank 不保证生效
        app.register("t2h:open_url", OpenUrlCommand())
        app.register("t2h:deploy", DeployCommand())
        app.register("t2h:verify", VerifyCommand())
        app.register("t2h:resume", ResumeCommand())
        // 从头重跑（0.39.64）：把该工程的迁移落档搬进 .lingqu/_archive-<时间戳>/，让观测从零开始
        app.register("t2h:reset_records", ResetRecordsCommand())
        app.register("t2h:report", ReportCommand())
        // 0.39.137：把迁移成果导出到独立目录（CLI `export` 同款实现）
        app.register("t2h:export", ExportCommand())
        app.register("t2h:batch", BatchCommand())
        app.register("t2h:skill", SkillCommand())
        app.register("t2h:agent_context", AgentContextCommand())
        app.register("t2h:cli_run", CliRunCommand())
        // G1+G2 失败自动诊断：把某一步的落档 + 日志尾拼成提问正文（只读）
        app.register("t2h:ai_brief", AiBriefCommand())
        // G4 决策回写：从 AI 回复里抽 lingqu-decision 块（只读解析，落档仍走 t2h:decisions）
        app.register("t2h:ai_decide", AiDecideCommand())
        // ⑥ 一键迁移：后台线程跑 8 步，进度靠 status 轮询
        app.register("t2h:migrate", MigrateCommand())
        app.register("t2h:migrate_status", MigrateStatusCommand())
        app.register("t2h:migrate_cancel", MigrateCancelCommand())
        // ⓪ AI 自动迁移：agent 是执行者（页面走 WS 发任务书，后端只准备现场 + 盯落档）
        app.register("t2h:autoport_start", AutoPortStartCommand())
        app.register("t2h:autoport_status", AutoPortStatusCommand())
        app.register("t2h:autoport_stop", AutoPortStopCommand())
        // agent 行为轨迹（0.39.0）：AI 对工程做了什么，落 <工程>/.lingqu/agent/trace.jsonl
        app.register("t2h:agent_trace", AgentTraceCommand())

            // cjh 命令面：handler 是同一个类，但**每个命令名都要单独 register**
            // （match 里写了分支 ≠ 已注册；漏注册的症状是页面拿到 command not registered）
            let cjhCmds = CjhCommands()
            app.register("t2h:cjh_status", cjhCmds)
            app.register("t2h:cjh_start", cjhCmds)
            app.register("t2h:cjh_deploy", cjhCmds)
            app.register("t2h:cjh_models", cjhCmds)
            app.register("t2h:cjh_settings", cjhCmds)
            app.register("t2h:cjh_settings_save", cjhCmds)
            // 重启引擎（0.39.62）：接入协议只认配置文件，改完必须重启才生效
            app.register("t2h:cjh_restart", cjhCmds)

            // 退出收尾（窗口关掉也生效）
            startLifecycleWaiter(app)

            // 引擎随窗口一起起来：放后台线程，别让 cjh 的 10s 就绪等待挡住窗口出现
            spawn {
                let ok = ensureCjhWeb()
                if (ok) {
                    eprintln("[lingqu] AI 引擎就绪：127.0.0.1:${cjhPort()}")
                }
            }
        })
}

/**
 * t2h:notes —— 本地经验的读写（0.39.55）。
 *
 * 为什么给 agent 一条命令而不是只让它写文件：**落档形状要一致**（四段 + 次数），
 * 而且要能去重、能读回、能进报告；agent 自己拼 markdown 迟早拼歪。
 *
 * action：
 *   · `list`（默认）：列出已有经验 + 一句话摘要
 *   · `append`：写一条（`title` / `symptom` / `cause` / `repro` / `fix`，或 `--body <json 文件>`）——**同标题只累加次数**
 *   · `export`：整份 markdown（给报告/人看）
 *   · `suggest`：**筛候选**（次数 ≥2 + 四段齐全 + 未入库）→ 写 `<工程>-candidates.md` + 逐条 PR 正文草稿；
 *     未命中台账里同签名 ≥3 次的也一并列出来（0.39.56）
 *   · `archive`：把已入库（`- 入库：…`）的经验移出候选池；台账到 `MISS_ROLL_MIN_LINES` 行就整体归档（0.39.56）；
 *     **`--to user|repo` 决定这份经验去哪**（0.39.113，默认 `user`）：
 *     `user` = 并入用户级认知层 `~/.lingqu/flywheel/lessons.md`（不登录、不提 PR 也能累积）；
 *     `repo` = 留在候选草稿里等你提 PR 给公共仓（不写用户级）
 *   · `fp-list`：列出**合并后**的指纹库（内置 N + 用户级 M，带来源）——`~/.lingqu/flywheel/fingerprints.json`
 *   · `fp-add`：写一条/一批**用户级**指纹（`--body <json 文件>`，支持 单对象 / 数组 / `{"fingerprints":[…]}`；
 *     缺 `id` 自动编号 `FP-U001` 起，缺 `marker` 直接报错）（0.39.113）
 */
public class NotesCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        let rawAction = argStr(args, "action", "")
        let action = if (rawAction.size == 0) { "list" } else { rawAction }
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_SCAN_PATH", "")
        }
        if (path.size == 0) {
            path = "."
        }
        let projName = sanitizeFileName(projectNameOf(path))
        var res = JsonObject()
        if (action == "append") {
            let n = LessonNote()
            // `--body <文件>`：内容走文件（**中文参数在 Windows 上过不了 argv**，见 AGENTS §4-119）
            let bodyPath = argStr(args, "body", "")
            var bodyUsed = false
            if (bodyPath.size > 0) {
                var bodyText = ""
                var readErr = ""
                try {
                    bodyText = lenientUtf8(File.readFrom(bodyPath))
                } catch (e: Exception) {
                    readErr = "${e}"
                }
                if (readErr.size > 0) {
                    res.put("ok", JsonBool(false))
                    res.put("result", JsonString("error:读不了 --body 文件：${readErr}"))
                    res.put("path", JsonString(notesPathOf(path, projName)))
                    putLessonsInto(res, loadLessons(path, projName))
                    return res
                }
                let fromBody = parseLessonBody(bodyText)
                n.title = fromBody.title
                n.symptom = fromBody.symptom
                n.cause = fromBody.cause
                n.repro = fromBody.repro
                n.fix = fromBody.fix
                bodyUsed = true
            } else {
                n.title = argStr(args, "title", "")
                n.symptom = argStr(args, "symptom", "")
                n.cause = argStr(args, "cause", "")
                n.repro = argStr(args, "repro", "")
                n.fix = argStr(args, "fix", "")
            }
            n.project = projName
            n.at = nowText()
            let r = appendLesson(path, projName, n)
            res.put("ok", JsonBool(!r.startsWith("error:")))
            res.put("result", JsonString(r))
            res.put("project", JsonString(projName))
            res.put("path", JsonString(notesPathOf(path, projName)))
            res.put("bodyUsed", JsonBool(bodyUsed))
            putLessonsInto(res, loadLessons(path, projName))
            eprintln("[lingqu][notes] ${r}")
            return res
        }
        // suggest（0.39.56）：筛候选 + 出 PR 正文草稿（**机器提议，人裁决**）
        if (action == "suggest") {
            let all = loadLessons(path, projName)
            let cands = candidateLessons(all)
            var ledgerText = ""
            if (exists(Path(diagMissLedgerPath(path)))) {
                try {
                    ledgerText = lenientUtf8(File.readFrom(diagMissLedgerPath(path)))
                } catch (e: Exception) {
                    let _ = e
                }
            }
            let sigs = ArrayList<String>()
            let times = ArrayList<Int64>()
            for (sig in missSignatureList(ledgerText)) {
                let t = missCountOf(ledgerText, sig)
                if (t >= 3) {
                    sigs.add(sig)
                    times.add(t)
                }
            }
            let outPath = argStr(args, "out", "")
            let w = writeCandidates(path, projName, cands, sigs, times, outPath)
            res.put("ok", JsonBool(!w.startsWith("error:")))
            res.put("project", JsonString(projName))
            res.put("result", JsonString(w))
            res.put("out", JsonString(if (w.startsWith("ok:")) { w[3..] } else { "" }))
            res.put("candidateCount", JsonInt(Int64(cands.size)))
            res.put("missCandidateCount", JsonInt(Int64(sigs.size)))
            res.put("lessonTotal", JsonInt(Int64(all.size)))
            res.put("missLedgerLines", JsonInt(missLedgerLineCount(ledgerText)))
            var titles = JsonArray()
            for (n in cands) {
                titles.add(JsonString(n.title))
            }
            res.put("candidates", titles)
            var sigArr = JsonArray()
            var i: Int64 = 0
            while (i < Int64(sigs.size) && i < Int64(times.size)) {
                var o = JsonObject()
                o.put("sig", JsonString(sigs[i]))
                o.put("times", JsonInt(times[i]))
                sigArr.add(o)
                i += 1
            }
            res.put("missCandidates", sigArr)
            eprintln("[lingqu][notes] suggest → ${w}（经验候选 ${cands.size} / 指纹候选 ${sigs.size}）")
            return res
        }
        // archive（0.39.56）：已入库的经验移出候选池 + 台账到量滚动
        // 飞轮阶段 4（0.39.113）：`--to` 决定这份经验去哪——
        //   user（默认）= 并入用户级认知层 `~/.lingqu/flywheel/lessons.md`；
        //   repo       = 留在候选草稿里等你提 PR 给公共仓（**不写用户级**，两条轨道别混）。
        if (action == "archive") {
            // 归档前先取**本轮要归档的那批 = 已入库经验**（archiveLessons 会把它们移进归档文件，
            // 之后再取就只剩空）。提上游仓的应该是"已经沉淀过的"，不是还没裁决的候选（0.39.114）
            let (repoNotes, _) = splitArchivedLessons(loadLessons(path, projName))
            let ar = archiveLessons(path, projName)
            let toRaw = argStr(args, "to", ARCHIVE_TO_USER)
            let to = archiveTargetOf(toRaw)
            let (missLines, missPath, missNote) = rollMissesLedger(path, nowText(), MISS_ROLL_MIN_LINES)
            // 认不出的 --to 必须报错，不许默默当成 user（§4-111：期望与结果不一致又不报错最难查）
            var userNote = "skip:--to repo：经验留在候选草稿里，等你提 PR"
            var repoPrReady = false
            var repoPrPath = ""
            if (to.size == 0) {
                userNote = "error:--to 只接受 user / repo（收到「${toRaw}」）"
            } else if (to == ARCHIVE_TO_USER) {
                userNote = mergeArchivedIntoUserBook(path, projName)
            } else if (to == ARCHIVE_TO_REPO) {
                // 阶段 2（0.39.114）：不再只回一句"等你提 PR"——当场产出可合并块，pr_prepare 会并进正文
                let st = stageRepoLessons(path, projName, repoNotes)
                repoPrReady = st.ready
                repoPrPath = st.path
                userNote = if (st.outError != "") {
                    "error:${st.outError}"
                } else {
                    st.note
                }
            }
            var toLabel = to
            if (toLabel.size == 0) {
                toLabel = "invalid"
            }
            res.put("ok", JsonBool(!ar.note.startsWith("error:") && to.size > 0))
            res.put("project", JsonString(projName))
            res.put("archivedNotes", JsonInt(ar.archived))
            res.put("keptNotes", JsonInt(ar.kept))
            res.put("archivePath", JsonString(ar.archivePath))
            res.put("notesNote", JsonString(ar.note))
            res.put("to", JsonString(toLabel))
            res.put("repoPrReady", JsonBool(repoPrReady))
            res.put("repoPrPath", JsonString(repoPrPath))
            res.put("userLessonsPath", JsonString(userLessonsPath()))
            res.put("userNote", JsonString(userNote))
            res.put("missLedgerLines", JsonInt(missLines))
            res.put("missArchivePath", JsonString(missPath))
            res.put("missNote", JsonString(missNote))
            putLessonsInto(res, loadLessons(path, projName))
            eprintln("[lingqu][notes] archive(${toLabel}): ${ar.note}｜${userNote}｜${missNote}")
            return res
        }
        // fp-list / fp-add（0.39.113）：**不登录任何平台**也能攒下自己学到的坑
        if (action == "fp-list") {
            let userText = readUserFingerprintsText()
            let lib = fingerprintLibraryWithUser(userText)
            let userCount = Int64(parseFingerprintsJson(userText).size)
            res.put("ok", JsonBool(true))
            res.put("project", JsonString(projName))
            res.put("userDir", JsonString(userFlywheelDir()))
            res.put("userFingerprintsPath", JsonString(userFingerprintsPath()))
            res.put("userFingerprints", JsonInt(userCount))
            res.put("librarySize", JsonInt(Int64(lib.size)))
            res.put("fingerprints", fingerprintsJsonOf(lib, userText))
            eprintln("[lingqu][notes] fp-list: 合并库 ${lib.size} 条（用户级 ${userCount} 条）@ ${userFlywheelDir()}")
            return res
        }
        if (action == "fp-add") {
            let bodyPath = argStr(args, "body", "")
            if (bodyPath.size == 0) {
                res.put("ok", JsonBool(false))
                res.put("error", JsonString(
                    "t2h:notes action=fp-add 需要参数 body（指纹 JSON 文件路径）——中文内容别走 argv，见 AGENTS §4-119"))
                return res
            }
            var bodyText = ""
            var readErr = ""
            try {
                bodyText = lenientUtf8(File.readFrom(bodyPath))
            } catch (e: Exception) {
                readErr = "${e}"
            }
            if (readErr.size > 0) {
                res.put("ok", JsonBool(false))
                res.put("error", JsonString("读 body 文件失败：${readErr}"))
                return res
            }
            let (incoming, bodyErr) = parseUserFpBody(bodyText, parseFingerprintsJson(readUserFingerprintsText()))
            if (bodyErr.size > 0) {
                res.put("ok", JsonBool(false))
                res.put("error", JsonString(bodyErr))
                return res
            }
            let note = addUserFingerprints(incoming)
            res.put("ok", JsonBool(note.startsWith("ok:")))
            res.put("project", JsonString(projName))
            res.put("incoming", JsonInt(Int64(incoming.size)))
            res.put("userFingerprintsPath", JsonString(userFingerprintsPath()))
            res.put("userNote", JsonString(note))
            res.put("librarySize", JsonInt(Int64(fingerprintLibraryWithUser(readUserFingerprintsText()).size)))
            eprintln("[lingqu][notes] fp-add: ${note}")
            return res
        }
        let lessons = loadLessons(path, projName)
        res.put("ok", JsonBool(true))
        res.put("project", JsonString(projName))
        res.put("path", JsonString(notesPathOf(path, projName)))
        res.put("summary", JsonString(lessonsSummaryLine(lessons)))
        if (action == "export") {
            res.put("markdown", JsonString(renderLessonsMd(projName, lessons)))
        }
        putLessonsInto(res, lessons)
        return res
    }
}

/** 把经验列表塞进回包（count + lessons 数组） */
func putLessonsInto(res: JsonObject, lessons: ArrayList<LessonNote>): Unit {
    var arr = JsonArray()
    for (n in lessons) {
        arr.add(lessonToJson(n))
    }
    res.put("count", JsonInt(Int64(lessons.size)))
    res.put("lessons", arr)
}

/**
 * 把**合并后**的指纹库塞进回包，并标出每条来自哪一层（0.39.113）。
 *
 * 为什么必须标来源：用户级指纹是**排在前面的**，一条 `FP-U001` 抢在 `FP-012` 之前命中时，
 * 界面上要是分不清"这是内置的还是我自己写的"，就没法判断该改哪一边（§4-63 同族）。
 */
func fingerprintsJsonOf(lib: ArrayList<Fingerprint>, userText: String): JsonArray {
    let userIds = HashSet<String>()
    for (x in parseFingerprintsJson(userText)) {
        userIds.add(x.id.trimAscii())
    }
    var arr = JsonArray()
    for (fp in lib) {
        var o = JsonObject()
        o.put("id", JsonString(fp.id))
        o.put("marker", JsonString(fp.marker))
        o.put("rootCause", JsonString(fp.rootCause))
        o.put("fix", JsonString(fp.fix))
        o.put("ruleId", JsonString(fp.ruleId))
        o.put("patchKind", JsonString(fp.patchKind))
        o.put("source", JsonString(if (userIds.contains(fp.id.trimAscii())) { "user" } else { "builtin" }))
        arr.add(o)
    }
    return arr
}

/**
 * `t2h:export` / `lingqu-cli export`（0.39.137）：把**迁移后的工程**复制到独立目录沉淀。
 *
 * 为什么要它：迁移是原地改样本工程的，成果散落在各样本目录里，人找不到、也不好单独提交。
 * 导出把"这一轮迁移后的样子"冻结成可归档/可提交的目录（附 `MIGRATION.md` + `migration-manifest.json`）。
 *
 * 参数：`path`（工程根；缺省取 `LINGQU_EXPORT_PATH`，再缺省取当前工作目录）、
 *       `out`（成果根目录；缺省 `%USERPROFILE%\lingqu-migrated`，`LINGQU_MIGRATED_DIR` 可覆盖）、
 *       `trigger`（`manual` / `verify-pass`，只用于落档溯源）。
 */
public class ExportCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var path = argStr(args, "path", "")
        if (path.size == 0) {
            path = envOr("LINGQU_EXPORT_PATH", "")
        }
        if (path.size == 0) {
            path = getWorkingDirectoryOr("")
        }
        path = normalizeHostSep(path)
        let outRoot = normalizeHostSep(argStr(args, "out", migratedRootOf()))
        var trigger = argStr(args, "trigger", "")
        if (trigger.size == 0) {
            trigger = "manual"
        }

        let res = exportProjectInto(path, outRoot, trigger)
        let o = JsonObject()
        o.put("ok", JsonBool(res.ok))
        o.put("project", JsonString(res.project))
        o.put("sourcePath", JsonString(normalizeHostSep(res.sourcePath)))
        o.put("outDir", JsonString(normalizeHostSep(res.outDir)))
        o.put("trigger", JsonString(res.trigger))
        o.put("copiedFiles", JsonInt(res.copiedFiles))
        o.put("skippedEntries", JsonInt(res.skippedEntries))
        o.put("totalBytes", JsonInt(res.totalBytes))
        o.put("verifyRate", JsonInt(res.verifyRate))
        o.put("error", JsonString(res.error))
        o.put("outJson", JsonString(lqDirOf(path) + cjhPathSep() + "export" + cjhPathSep() +
            sanitizeFileName(res.project) + ".json"))
        o.put("nextStep", JsonString(if (res.ok) {
            "成果目录：${normalizeHostSep(res.outDir)}（含 MIGRATION.md 与 migration-manifest.json）"
        } else {
            "导出失败，先看 error"
        }))
        return o
    }
}
