package lingqu

import cjTauri.*
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
    var o = JsonObject()
    o.put("id", JsonString(id))
    o.put("label", JsonString(label))
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
 * 把迁移所需的工具链一次性体检出来。
 * 判定口径：路径存在 = 就绪。版本号等「能跑起来才知道」的检查留给后续 t2h:doctor。
 */
public class EnvCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, _: JsonObject, _: IpcContext): JsonValue {
        let home = envOr("USERPROFILE", "")
        let ndk = envOr("NATIVE_OHOS_SDK", "")
        let deveco = envOr("DEVECO_HOME", "")
        let sdkRoot = envOr("DEVECO_SDK_HOME", "")

        var arr = JsonArray()

        addCheck(arr, "rustc", "Rust 工具链（rustc / cargo）",
            firstExisting([
                joinPath(home, ".cargo\\bin\\rustc.exe"),
                "C:\\Program Files\\Rust\\bin\\rustc.exe"
            ]),
            "装 rustup 后应在 %USERPROFILE%\\.cargo\\bin；迁移要靠它交叉编译 .so")

        addCheck(arr, "llvm-mingw", "llvm-mingw（Windows 链接前提）",
            firstExisting([
                "C:\\tool\\llvm-mingw\\bin\\x86_64-w64-mingw32-clang.exe"
            ]),
            "gnullvm 工具链不自带 C 编译器；缺它会报 linker x86_64-w64-mingw32-clang not found")

        var ndkClang = ""
        if (ndk.size > 0) {
            ndkClang = firstExisting([joinPath(ndk, "llvm\\bin\\clang.exe")])
        }
        addCheck(arr, "ohos-ndk", "OHOS NDK（clang / sysroot）", ndkClang,
            "设 NATIVE_OHOS_SDK 指向 SDK 的 native 目录（DevEco 下载 SDK 后就有）")

        addCheck(arr, "deveco", "DevEco Studio",
            firstExisting([deveco]),
            "设 DEVECO_HOME 指向 DevEco Studio 安装目录（打包 HAP 需要 hvigor / ohpm）")

        addCheck(arr, "hvigor", "hvigor 构建器",
            firstExisting([
                joinPath(deveco, "tools\\hvigor\\bin\\hvigorw.bat"),
                joinPath(deveco, "tools\\hvigor\\bin\\hvigorw")
            ]),
            "它随 DevEco 一起装；缺了说明 DEVECO_HOME 没指对")

        addCheck(arr, "ohpm", "ohpm 包管理器",
            firstExisting([
                joinPath(deveco, "tools\\ohpm\\bin\\ohpm.bat"),
                joinPath(deveco, "tools\\ohpm\\bin\\ohpm")
            ]),
            "它随 DevEco 一起装；HAP 装配前要装 oh 依赖")

        addCheck(arr, "hdc", "hdc 设备桥",
            firstExisting([
                joinPath(sdkRoot, "HarmonyOS-NEXT-DB6\\openharmony\\toolchains\\hdc.exe"),
                joinPath(sdkRoot, "default\\openharmony\\toolchains\\hdc.exe")
            ]),
            "它随 SDK 走；部署到鸿蒙 PC 真机靠它")

        // cjh 复用 cjh_host 的解析（env → 已部署 → 仓内 vendor，vendor 还要过 SHA256）
        addCheck(arr, "cjh", "AI 引擎 cjh（内置）", cjhBinPath(),
            "把 cjh.exe 放到 vendor/cjh/win-x64/ 或用 LINGQU_CJH 指向它；缺了 AI 面板不可用（其余功能照常）")

        var res = JsonObject()
        res.put("items", arr)
        res.put("cjhPort", JsonInt(cjhPort()))
        // 界面自检开关：置 1 时页面会自己跑一遍「开设置 → 折叠 → 展开 → 发一句」并逐步上报；
        // 置 approval 时改为发一条会触发危险操作审批的指令（验证审批卡）。
        res.put("uiProbe", JsonString(envOr("LINGQU_UI_PROBE", "")))
        // 扫描探针：给了路径就在启动时跑一次 t2h:scan，把指标回投到 ui_report（无视觉也能验扫描器）
        res.put("scanPath", JsonString(envOr("LINGQU_SCAN_PATH", "")))
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
        if (!exists(Path(path))) {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("路径不存在：${path}"))
            return res
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
                    let bl = parseBaseline(String.fromUtf8(File.readFrom(baselinePath)))
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

        let outDir = ".lingqu/scan"
        let outFile = "${outDir}/${name}.json"
        var wrote = false
        // 写盘失败必须能被看见：eprintln 在 GUI 里会被框架日志接管（AGENTS §4 第 14 条），
        // 只打日志等于没证据 —— 所以把原因塞进返回值，页面和 ui_report 都能断言。
        var outErr = ""
        try {
            if (!exists(Path(".lingqu"))) {
                Directory.create(Path(".lingqu"))
            }
            if (!exists(Path(outDir))) {
                Directory.create(Path(outDir))
            }
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
        let dir = ".lingqu/port/${sanitizeFileName(name)}"
        let file = "${dir}/decisions.json"
        let action = argStr(args, "action", "list")

        // 读现有记录（不存在则空表）
        var items = JsonArray()
        try {
            if (exists(Path(file))) {
                let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(file)))
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
            item.put("note", JsonString(argStr(args, "note", "")))
            newItems.add(item)
            var root = JsonObject()
            root.put("schema", JsonString("lingqu/decisions/v1"))
            root.put("project", JsonString(name))
            root.put("items", newItems)
            try {
                ensurePortDirs()
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
                logText = String.fromUtf8(File.readFrom(logPath))
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

        let items = diagnoseLog(logText)
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
        if (!exists(Path(path))) {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("路径不存在：${path}"))
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
            before = String.fromUtf8(File.readFrom(tomlPath))
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
        let frontend = "${srcTauriDir}/.."
        result.outcomes.add(localStorageOutcome("${frontend}/index.html"))
        let dialogAssets = dialogAssetsOutcome(frontend)
        for (d in dialogAssets) {
            result.outcomes.add(d)
        }
        let guides = frontendGuideOutcomes(frontend)
        for (g in guides) {
            result.outcomes.add(g)
        }
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
                ensurePortDirs()
                backupPath = ".lingqu/port/${safeName}"
                var wroteAny = false
                if (result.appliedCount() > 0) {
                    File.writeTo("${backupPath}/${BAK_CARGO}", before.toArray())
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
                        let old = String.fromUtf8(File.readFrom(p))
                        File.writeTo(p, (old + o.after).toArray())
                        wroteAny = true
                    }
                    if (o.id == "R2-PORT-010" && o.applied) {
                        // 与 009 同一文件：009 先追加函数定义，010 再在 setup 块内接线
                        let p = if (exists(Path("${srcTauriDir}/src/lib.rs"))) { "${srcTauriDir}/src/lib.rs" } else { "${srcTauriDir}/src/main.rs" }
                        backupFile(p, "${backupPath}/${BAK_LIBRS}")
                        let old = String.fromUtf8(File.readFrom(p))
                        File.writeTo(p, applySetupWiring(old).toArray())
                        wroteAny = true
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
                        let old = String.fromUtf8(File.readFrom(p))
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
                ensurePortDirs()
                File.writeTo(".lingqu/port/${safeName}-Cargo.toml.preview", result.afterText.toArray())
            } catch (e: Exception) {
                eprintln("[lingqu][port] 预览落档失败：${e}")
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

func ensurePortDirs(): Unit {
    if (!exists(Path(".lingqu"))) {
        Directory.create(Path(".lingqu"))
    }
    if (!exists(Path(".lingqu/port"))) {
        Directory.create(Path(".lingqu/port"))
    }
}

/** 备份单文件（目标存在才备；备份路径是 .lingqu/port 下的绝对工程外位置） */
func backupFile(src: String, dst: String): Unit {
    if (exists(Path(src)) && !exists(Path(dst))) {
        File.writeTo(dst, File.readFrom(src))
    }
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
        let dir = backupDirOf(safeName)
        let legacy = legacyCargoBakOf(safeName)
        let tomlPath = cargoTomlPathOf(path)

        var restored = JsonArray()
        var skipped = JsonArray()
        var removed = JsonArray()
        var errMsg = ""
        var usedLegacy = false

        if (exists(Path(dir))) {
            // 工程目录：按表逐文件回滚
            for (pair in revertPairs()) {
                let bak = "${dir}/${pair.backupFile}"
                if (!exists(Path(bak))) {
                    continue
                }
                // 目标路径：Cargo.toml 用解析结果，其余按相对路径；lib.rs 单 bin 工程退回 main.rs
                var target = ""
                if (pair.relTarget == "") {
                    target = tomlPath
                } else {
                    target = "${path}/${pair.relTarget}"
                    if (pair.backupFile == BAK_LIBRS && !exists(Path(target))) {
                        target = "${path}/src-tauri/src/main.rs"
                    }
                }
                if (target == "") {
                    skipped.add(JsonString(pair.backupFile))
                    continue
                }
                try {
                    let bakText = String.fromUtf8(File.readFrom(bak))
                    File.writeTo(target, bakText.toArray())
                    restored.add(JsonString(target))
                } catch (e: Exception) {
                    errMsg = "回滚 ${target} 失败：${e}"
                }
            }
            // 014 生成的前端资源：带 lingqu 标记才算工具产物，删掉才算"回到干净仓库"
            for (f in ["lingqu-dialog.js", "lingqu-dialog.css"]) {
                let p = "${path}/${f}"
                if (fileContains(p, "lingqu: R2-PORT-014")) {
                    try {
                        remove(Path(p))
                        removed.add(JsonString(p))
                    } catch (e: Exception) {
                        errMsg = "删除 ${p} 失败：${e}"
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
                let bak = String.fromUtf8(File.readFrom(legacy))
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
        if (!exists(Path(path))) {
            res.put("ok", JsonBool(false))
            res.put("error", JsonString("路径不存在：${path}"))
            return res
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
            let outDir = ".lingqu/deps"
            let outFile = "${outDir}/${name}.json"
            try {
                if (!exists(Path(".lingqu"))) {
                    Directory.create(Path(".lingqu"))
                }
                if (!exists(Path(outDir))) {
                    Directory.create(Path(outDir))
                }
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
        res.put("out", JsonString(if (wrote) { ".lingqu/deps/${name}.json" } else { "" }))
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
        // 引擎发现证据：state（running/ready/missing）+ 实际用的二进制 + 查过的 vendor 目录
        o.put("cjhState", JsonString(argStr(args, "cjhState", "")))
        o.put("cjhBin", JsonString(argStr(args, "cjhBin", "")))
        o.put("cjhVendorDir", JsonString(argStr(args, "cjhVendorDir", "")))
        o.put("cjhHome", JsonString(argStr(args, "cjhHome", "")))
        o.put("frames", JsonInt(argInt(args, "frames", 0)))
        o.put("toolCards", JsonInt(argInt(args, "toolCards", 0)))
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
        o.put("verifyTotal", JsonInt(argInt(args, "verifyTotal", 0)))
        o.put("verifyLimit", JsonInt(argInt(args, "verifyLimit", 0)))
        o.put("verifyUnknown", JsonInt(argInt(args, "verifyUnknown", 0)))
        o.put("verifyShots", JsonInt(argInt(args, "verifyShots", 0)))
        o.put("verifyMd", JsonString(argStr(args, "verifyMd", "")))
        // 清单行的版面指标（没有视觉也能断言"没竖排、没溢出"）
        o.put("verifyRows", JsonInt(argInt(args, "verifyRows", 0)))
        o.put("verifyOverflow", JsonInt(argInt(args, "verifyOverflow", 0)))
        o.put("verifyRowH", JsonInt(argInt(args, "verifyRowH", 0)))
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
        // T7-3 批量矩阵（t2h:batch 回投）：样本数 / 已验证数 / 平均可用率 / A4 判定
        o.put("batchOk", JsonBool(argBool(args, "batchOk", false)))
        o.put("batchSamples", JsonInt(argInt(args, "batchSamples", 0)))
        o.put("batchVerified", JsonInt(argInt(args, "batchVerified", 0)))
        o.put("batchAvgRate", JsonInt(argInt(args, "batchAvgRate", -1)))
        o.put("batchAvgScore", JsonInt(argInt(args, "batchAvgScore", -1)))
        o.put("batchHuman", JsonInt(argInt(args, "batchHuman", 0)))
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
                    prev = String.fromUtf8(File.readFrom(logf))
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
        if (!verifyOnly) {
            try {
                let argv = ["build", "--release", "--target", target, "--message-format=json"]
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
        let hits = diagnoseLog(combined)
        let dj = diagnosisJson(hits)
        // stderr 侧的 error 行：build-script / 链接类失败的**唯一**痕迹
        let stderrErrors = countErrorLines(stderrText)
        let effectiveErrors = if (parsed.errorCount() > stderrErrors) { parsed.errorCount() } else { stderrErrors }

        // ---- T5-2 前端指纹校验：`.so` 内嵌 AssetKey ↔ dist/ 实际产物 ----
        // 只在"编译成功且产出了 .so"时才有得比；失败构建天然没有 .so，闸会如实说"没扫到"。
        let soPath = findSoArtifactOf(srcDir, target, parsed.artifacts)
        // verifyOnly 模式下没有 cargo 输出，直接从磁盘上找最近产出的 .so
        let soPathFinal = if (soPath != "") { soPath } else if (verifyOnly) { findSoOnDisk(srcDir, target) } else { "" }
        var distDir = resolveDistDirOf(path, srcDir)
        var embeddedKeys = ArrayList<String>()
        var distKeys = ArrayList<String>()
        var assetDiff = AssetDiff()
        var assetError = ""
        if (soPathFinal != "") {
            try {
                embeddedKeys = extractAssetKeys(File.readFrom(soPathFinal))
                distKeys = distAssetKeysOf(distDir)
                assetDiff = compareAssetKeys(embeddedKeys, distKeys)
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
            if (!exists(Path(".lingqu"))) {
                Directory.create(Path(".lingqu"))
            }
            if (!exists(Path(".lingqu/build"))) {
                Directory.create(Path(".lingqu/build"))
            }
            outJsonl = ".lingqu/build/${safeName}.jsonl"
            outLog = ".lingqu/build/${safeName}.log"
            outJson = ".lingqu/build/${safeName}.json"
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
        if (code == 0 && String.fromUtf8(out).contains("cargo")) {
            return "cargo"
        }
    } catch (e: Exception) {
        let _ = e
    }
    return ""
}

/** 找 cargo 产出的 .so 绝对路径：优先按 artifacts 里的文件名去 target 目录拼 */
func findSoArtifactOf(srcDir: String, target: String, artifacts: ArrayList<String>): String {
    var soName = ""
    for (a in artifacts) {
        if (a.endsWith(".so")) {
            soName = a
            break
        }
    }
    if (soName == "") {
        return ""
    }
    let p = "${srcDir}/target/${target}/release/${soName}"
    if (exists(Path(p))) {
        return p
    }
    return ""
}

/**
 * verifyOnly 模式用：从 `target/<target>/release` 里挑一个 .so（cargo 输出不可用时）
 */
func findSoOnDisk(srcDir: String, target: String): String {
    let dir = "${srcDir}/target/${target}/release"
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
 * 解析前端产物目录：读 `src-tauri/tauri.conf.json` 的 `frontendDist`（相对 src-tauri 解析），
 * 读不到就退回工程根的 `dist/`。
 */
func resolveDistDirOf(projectDir: String, srcDir: String): String {
    let conf = "${srcDir}/tauri.conf.json"
    var dist = ""
    if (exists(Path(conf))) {
        try {
            let text = String.fromUtf8(File.readFrom(conf))
            dist = jsonStringFieldOf(text, "frontendDist")
        } catch (e: Exception) {
            dist = ""
        }
    }
    if (dist == "") {
        return "${projectDir}/dist"
    }
    // frontendDist 相对 src-tauri；也常见 "../dist" 这种写法
    if (dist.startsWith("./")) {
        dist = dist[2..]
    }
    return "${srcDir}/${dist}"
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

/** 上一次落档的 errorCount（做回归闸基线）；没有落档返回 -1 */
func lastBuildErrorCountOf(projectDir: String): Int64 {
    let f = ".lingqu/build/${sanitizeFileName(projectNameOf(projectDir))}.json"
    if (!exists(Path(f))) {
        return -1
    }
    try {
        let root = JsonValue.fromStr(String.fromUtf8(File.readFrom(f)))
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
            try {
                let (code, out, errOut) = executeWithOutput(ohpm, ["install", "--all"], workingDirectory: Path(ohosDir))
                phaseLog += "[ohpm install] exit=${code}\n" + String.fromUtf8(out) + "\n" + String.fromUtf8(errOut) + "\n"
                installedDeps = code == 0
                if (code != 0) {
                    errMsg = "ohpm install 失败（exit=${code}）：${firstLines(String.fromUtf8(errOut), 3)}"
                }
            } catch (e: Exception) {
                errMsg = "ohpm install 起不来：${e}"
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
                    moduleName = entryModuleNameOf(String.fromUtf8(File.readFrom(entryAbility)))
                } catch (e: Exception) {
                    let _ = e
                }
            }
            expectedSo = expectedSoNameOf(moduleName)
            if (expectedSo != "") {
                let relSo = "${srcDir}/target/aarch64-unknown-linux-ohos/release/${expectedSo}"
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

        // ---- hvigor assembleHap ----
        var hvigorText = ""
        if (errMsg == "") {
            try {
                // 注意：argv 第一个元素必须是 hvigorw.js 的路径——漏了它 node 会把
                // --mode 当成自己的选项（实测 `bad option: --mode`，exit=9）
                let argv = [hvigorJs, "--mode", "module", "-p", "product=default", "assembleHap", "--no-daemon"]
                let (code, out, errOut) = executeWithOutput(node, argv, workingDirectory: Path(ohosDir))
                hvigorText = String.fromUtf8(out) + "\n" + String.fromUtf8(errOut)
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
        let gates = mergeGates(gateReports)

        var outError = ""
        var outJson = ""
        var outLog = ""
        let safeName = sanitizeFileName(projectNameOf(path))
        try {
            if (!exists(Path(".lingqu/hap"))) {
                if (!exists(Path(".lingqu"))) {
                    Directory.create(Path(".lingqu"))
                }
                Directory.create(Path(".lingqu/hap"))
            }
            outJson = ".lingqu/hap/${safeName}.json"
            outLog = ".lingqu/hap/${safeName}.log"
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
            root.put("installedDeps", JsonBool(installedDeps))
            root.put("expectedSo", JsonString(expectedSo))
            root.put("soCopied", JsonString(soCopied))
            root.put("soSource", JsonString(soSource))
            root.put("soNote", JsonString(soNote))
            File.writeTo(outJson, root.toJsonString().toArray())
        } catch (e: Exception) {
            outError = "落档失败：${e}"
        }

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
public class SignCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
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
                let text = String.fromUtf8(out) + "\n" + String.fromUtf8(errOut)
                hdcLog = "[hdc shell bm get --udid] ${hdc} exit=${code}\n${text}"
                // 注意：hdc 失败时退出码仍是 0（AGENTS §4-40），UDID 只能按输出文本判
                udid = parseUdid(text)
            } catch (e: Exception) {
                hdcLog = "[hdc] 起不来：${e}"
            }
        }

        // ---- ② 工程签名配置（build-profile.json5 是 JSON5，用轻量提取） ----
        let buildProfile = if (ohosDir == "") { "" } else { hostPath("${ohosDir}/build-profile.json5") }
        var projText = ""
        var buildProfileError = ""
        if (buildProfile != "" && exists(Path(buildProfile))) {
            try {
                projText = String.fromUtf8(File.readFrom(buildProfile))
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
                bundleName = json5ValueAfter(String.fromUtf8(File.readFrom(appJson)), "bundleName")
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
        let check = judgeSign(hasConfig, filesExist, configured.allows(udid), configured.profileType,
            udid, candidatePath != "")
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
                            let origin = String.fromUtf8(File.readFrom(buildProfile))
                            let (newText, err) = applySigningConfig(origin, m)
                            if (err != "") {
                                applyError = err
                            } else {
                                if (!exists(Path(".lingqu/sign"))) {
                                    if (!exists(Path(".lingqu"))) {
                                        Directory.create(Path(".lingqu"))
                                    }
                                    Directory.create(Path(".lingqu/sign"))
                                }
                                backupPath = ".lingqu/sign/${projName}.build-profile.json5.bak"
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
                            }
                        } catch (e: Exception) {
                            applyError = "写回失败：${e}"
                        }
                    case None =>
                        applyError = "没找到用同一套材料的工程（口令是 DevEco 加密串，只能从已有工程搬）：" +
                            "可在 DevEco 里对该工程自动签名一次，或传 donor=<已有工程路径>"
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
            if (!exists(Path(".lingqu/sign"))) {
                if (!exists(Path(".lingqu"))) {
                    Directory.create(Path(".lingqu"))
                }
                Directory.create(Path(".lingqu/sign"))
            }
            outJson = ".lingqu/sign/${projName}.json"
            outLog = ".lingqu/sign/${projName}.log"
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
        let wantShots = argBool(args, "screenshot", true)
        var serial = argStr(args, "serial", "")
        if (serial == "") {
            serial = deploySerialOf(projName)
        }
        let hdc = hdcPathOr()

        // ① + ② 取数与采证
        let inp = collectVerifyInput(projName)
        let ev = collectEvidence(projName, hdc, serial, wantShots)
        if (ev.saved > 0) {
            inp.screenshotCount = ev.saved
        }
        inp.crashCount = ev.crashes

        // ③ 清单 / 可用率 / 报告
        let items = buildChecklist(inp)
        let stats = computeStats(items)
        let ctx = ReportContext(projName)
        ctx.bundleName = deployBundleOf(projName)
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
            if (!exists(Path(".lingqu/verify"))) {
                if (!exists(Path(".lingqu"))) {
                    Directory.create(Path(".lingqu"))
                }
                Directory.create(Path(".lingqu/verify"))
            }
            outJson = ".lingqu/verify/${projName}.json"
            outMd = ".lingqu/verify/${projName}.md"
            outHtml = ".lingqu/verify/${projName}.html"
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
                outEvidence = ".lingqu/verify/${projName}.evidence.log"
                File.writeTo(outEvidence, ev.log.toArray())
            }
        } catch (e: Exception) {
            outError = "落档失败：${e}"
        }

        var res = JsonObject()
        res.put("ok", JsonBool(outError == ""))
        res.put("project", JsonString(projName))
        res.put("screenshots", JsonInt(ev.saved))
        res.put("crashes", JsonInt(ev.crashes))
        res.put("total", JsonInt(stats.total))
        res.put("pass", JsonInt(stats.pass))
        res.put("fail", JsonInt(stats.fail))
        res.put("limit", JsonInt(stats.limit))
        res.put("unknown", JsonInt(stats.unknown))
        res.put("ratePercent", JsonInt(stats.ratePercent))
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
        eprintln("[lingqu][verify] ${projName} pass=${stats.pass}/${stats.total - stats.limit} " +
            "limit=${stats.limit} unknown=${stats.unknown} rate=${stats.ratePercent}%")
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
public class ResumeCommand <: CommandHandler {
    public init() {}

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
            match (readJsonOrNone(taskBoardPath())) {
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

        var outError = ""
        if (err == "") {
            outError = saveTaskBoard(board)
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
        res.put("out", JsonString(taskBoardPath()))
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
        res.put("error", JsonString(err))
        res.put("outError", JsonString(outError))
        eprintln("[lingqu][resume] ${board.project} action=${action} " +
            "done=${p.done}/${p.total} next=${next} ${resumeHint(board)}")
        return res
    }
}

/** 步骤 id 列表（错误提示里要能列全，别让人猜） */
func taskStepIdsJoined(): String {
    var text = ""
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
        var projName = ""
        if (path.size > 0) {
            projName = sanitizeFileName(projectNameOf(path))
        } else {
            // 没给路径：沿用断点板里的工程名，省得为了出报告再填一遍
            match (readJsonOrNone(taskBoardPath())) {
                case Some(root) => projName = parseTaskBoardValue(root).project
                case None => ()
            }
        }
        if (projName == "") {
            projName = "unknown"
        }
        var outDir = argStr(args, "outDir", "")
        if (outDir.size == 0) {
            outDir = ".lingqu/report"
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

/** 确保目录存在（逐级建；`a/b/c` 这种导出目录要能一次建好） */
func ensureDirOf(dir: String): Unit {
    if (dir == "" || dir == "." || exists(Path(dir))) {
        return
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
                Directory.create(Path(part))
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
        let names = ArrayList<String>()

        // ① 显式给了样本路径：按给的顺序，工程名与各命令落档用的名字保持一致
        if (raw.size > 0) {
            for (p in splitSamplePaths(raw)) {
                let name = sanitizeFileName(projectNameOf(p))
                if (name == "") {
                    continue
                }
                samples.add((name, p))
                names.add(name)
            }
        }

        // ② 没给就从落档目录里发现（同名去重，插入排序保证可复现）
        if (samples.size == 0) {
            for (name in discoverSampleNames()) {
                samples.add((name, ""))
                names.add(name)
            }
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
            ro.put("verifyDenom", JsonInt(r.verifyTotal - r.verifyLimit))
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
            let s = String.fromUtf8(buf.toArray()).trimAscii()
            if (s != "") {
                out.add(s)
            }
            buf = ArrayList<Byte>()
        } else {
            buf.add(b)
        }
    }
    let last = String.fromUtf8(buf.toArray()).trimAscii()
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
 * t2h:deploy —— 真机部署与启动体检（T5-5 命令化，0.21.0）。
 *
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
                        bundleName = json5ValueAfter(String.fromUtf8(File.readFrom(appJson)), "bundleName")
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
            listText = String.fromUtf8(out) + "\n" + String.fromUtf8(errOut)
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
                    installText = String.fromUtf8(out) + "\n" + String.fromUtf8(errOut)
                    installStep = parseInstallResult(installText, code)
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
                    startText = String.fromUtf8(out) + "\n" + String.fromUtf8(errOut)
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
                hilogText = String.fromUtf8(out) + "\n" + String.fromUtf8(errOut)
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
            if (!exists(Path(".lingqu/deploy"))) {
                if (!exists(Path(".lingqu"))) {
                    Directory.create(Path(".lingqu"))
                }
                Directory.create(Path(".lingqu/deploy"))
            }
            outJson = ".lingqu/deploy/${projName}.json"
            outLog = ".lingqu/deploy/${projName}.log"
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
            text = String.fromUtf8(File.readFrom(p))
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
        .plugin(LogPlugin())
        // WS：cjh 的对话/工具/审批都走 ws://127.0.0.1:<port>/ws（帧类型见 docs/实施路线图.md P1）
        .plugin(WsPlugin())
        .wire({ app =>
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
            app.register("t2h:quit", QuitCommand(app))
            app.register("t2h:ui_report", UiReportCommand())
            app.register("t2h:scan", ScanCommand())
            app.register("t2h:deps", DepsCommand())
            app.register("t2h:port", PortCommand())
            app.register("t2h:revert", RevertCommand())
            app.register("t2h:decisions", DecisionsCommand())
            app.register("t2h:diagnose", DiagnoseCommand())
        app.register("t2h:build", BuildCommand())
        app.register("t2h:hap", HapCommand())
        app.register("t2h:sign", SignCommand())
        app.register("t2h:deploy", DeployCommand())
        app.register("t2h:verify", VerifyCommand())
        app.register("t2h:resume", ResumeCommand())
        app.register("t2h:report", ReportCommand())
        app.register("t2h:batch", BatchCommand())
        app.register("t2h:skill", SkillCommand())

            // cjh 命令面：handler 是同一个类，但**每个命令名都要单独 register**
            // （match 里写了分支 ≠ 已注册；漏注册的症状是页面拿到 command not registered）
            let cjhCmds = CjhCommands()
            app.register("t2h:cjh_status", cjhCmds)
            app.register("t2h:cjh_start", cjhCmds)
            app.register("t2h:cjh_deploy", cjhCmds)
            app.register("t2h:cjh_models", cjhCmds)
            app.register("t2h:cjh_settings", cjhCmds)
            app.register("t2h:cjh_settings_save", cjhCmds)

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
