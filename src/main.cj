package lingqu

import cjTauri.*
import cjTauri.plugins.log.*
import cjTauri.plugins.ws.*
import lingqu.scanner.*
import lingqu.deps.*
import lingqu.port.*
import std.env.*
import std.fs.*
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
 */
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
        o.put("frames", JsonInt(argInt(args, "frames", 0)))
        o.put("toolCards", JsonInt(argInt(args, "toolCards", 0)))
        o.put("approvals", JsonInt(argInt(args, "approvals", 0)))
        o.put("lastFrameType", JsonString(argStr(args, "lastFrameType", "")))
        o.put("replyPreview", JsonString(argStr(args, "replyPreview", "")))
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
            if (!exists(Path(dir))) {
                Directory.create(Path(dir))
            }
            File.writeTo(snap, text.toArray())
            var prev = ""
            if (exists(Path(logf))) {
                prev = String.fromUtf8(File.readFrom(logf))
            }
            File.writeTo(logf, (prev + oneline + "\n").toArray())
            wrote = true
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

            app.register("t2h:env", EnvCommand())
            app.register("t2h:quit", QuitCommand(app))
            app.register("t2h:ui_report", UiReportCommand())
            app.register("t2h:scan", ScanCommand())
            app.register("t2h:deps", DepsCommand())
            app.register("t2h:port", PortCommand())
            app.register("t2h:revert", RevertCommand())
            app.register("t2h:decisions", DecisionsCommand())
            app.register("t2h:diagnose", DiagnoseCommand())

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
