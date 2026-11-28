package lingqu

import lingqu.verify.*
import lingqu.compiler.*
import std.collection.*
import std.env.*
import std.fs.*
import std.process.*
import std.time.*
import stdx.encoding.json.*

/*
 * `t2h:verify` 的取数与落档辅助（命令本体在 main.cj）。
 *
 * 分成单独文件的原因：main.cj 已经很厚，而这一层"读前面几轮的落档 + 采真机证据"
 * 有固定的几个解析动作，单拎出来便于对照 `.lingqu` 各目录下的落档 schema 复核。
 */

/**
 * 取某平台能力符号的**真机实测结论**（`probe.json` 的 `platform:<符号>` → (verdict, note)）。
 *
 * 为什么要它（0.39.133，EcoPaste 剪贴板）：静态判据只能看"代码里有没有鸿蒙分支"，
 * 看不出"分支跑了、也拿不到数据"——剪贴板就是这样：桥写了、能编能装、`getDataSync()`
 * 真机返回 `records=0`（未授权时静默抹内容）。只按代码算落地的话报告会报 100%，
 * 而用户手里的功能不可用（§4-136 那族假绿的极端版）。**实测结论优先于静态推断**，
 * 与 `event:` 通道同一口径。
 *
 * @return ("","") = 没有实测记录
 */
public func platformProbeVerdictOf(probe: JsonValue, name: String): (String, String) {
    let feats = objFieldOf(probe, "features")
    match (feats.kind()) {
        case JsonKind.JsObject =>
            let rec = objFieldOf(feats, "platform:${name}")
            match (rec.kind()) {
                case JsonKind.JsObject =>
                    return (jsonStrField(rec, "verdict"), jsonStrField(rec, "note"))
                case _ => return ("", "")
            }
        case _ => return ("", "")
    }
}

/**
 * 纯函数：取出 `probe.json` 里**按按钮文本**记的实测条目（0.39.159）。
 *
 * 排除 `platform:` / `event:` 两个前缀——它们各有专门通道（平台能力实测优先、事件触发计数），
 * 剩下的键才是 `probe --auto` 按按钮文本点出来的冒烟结论。以前这些条目**没有任何消费方**
 * ⇒ 「probe 完再 verify」是空操作（实测 8 条 2 pass，verify 的 `feat:*` 依旧全未测）。
 */
public func smokeProbesOf(probe: JsonValue): ArrayList<SmokeProbeInput> {
    let out = ArrayList<SmokeProbeInput>()
    let feats = objFieldOf(probe, "features")
    match (feats.kind()) {
        case JsonKind.JsObject =>
            for ((k, v) in feats.asObject().getFields()) {
                if (k.startsWith("platform:") || k.startsWith("event:")) {
                    continue
                }
                out.add(SmokeProbeInput(k, jsonStrField(v, "verdict"), jsonStrField(v, "note")))
            }
        case _ => ()
    }
    return out
}

/** 从落档 JSON 文本里取一层对象字段（找不到给空 JsonObject，省得每处判 None） */
func objFieldOf(root: JsonValue, key: String): JsonValue {
    match (root.kind()) {
        case JsonKind.JsObject =>
            match (root.asObject().get(key)) {
                case Some(v) => return v
                case None => return JsonObject()
            }
        case _ => return JsonObject()
    }
}

/** 数组字段的条数（不是数组给 0） */
func arraySizeFieldOf(v: JsonValue, key: String): Int64 {
    let arr = objFieldOf(v, key)
    match (arr.kind()) {
        case JsonKind.JsArray => return arr.asArray().size()
        case _ => return 0
    }
}

/** 布尔字段（不是布尔给 false） */
func boolFieldOf(v: JsonValue, key: String): Bool {
    let x = objFieldOf(v, key)
    match (x.kind()) {
        case JsonKind.JsBool => return x.asBool().getValue()
        case _ => return false
    }
}

/** 整数字段（不是整数给 fallback） */
func intFieldOf(v: JsonValue, key: String, fallback: Int64): Int64 {
    let x = objFieldOf(v, key)
    match (x.kind()) {
        case JsonKind.JsInt => return x.asInt().getValue()
        case _ => return fallback
    }
}

/** 字符串数组的第一个元素（不是数组/空给 ""）——用来把闸门的第一条失败贴进清单 */
func firstArrayItemOf(v: JsonValue, key: String): String {
    let arr = objFieldOf(v, key)
    match (arr.kind()) {
        case JsonKind.JsArray =>
            let a = arr.asArray()
            if (a.size() == 0) {
                return ""
            }
            match (a.get(0)) {
                case Some(item) => match (item.kind()) {
                    case JsonKind.JsString => return item.asString().getValue()
                    case _ => return ""
                }
                case None => return ""
            }
        case _ => return ""
    }
}

/** 安全读一份落档 JSON；读不到/解析不了都返回 None（调用方按"没跑过"处理） */
func readJsonOrNone(p: String): Option<JsonValue> {
    if (!exists(Path(p))) {
        return None
    }
    try {
        let text = lenientUtf8(File.readFrom(p))
        return Some(JsonValue.fromStr(text))
    } catch (e: Exception) {
        let _ = e
        return None
    }
}

/**
 * `build` 落档 → 「编译通过 / 前端指纹一致」两个真值（纯函数）。
 *
 * 单拎出来的理由：这两个判定的字段形态违反直觉——`assetDiff.matched / staleInSo / missingInSo`
 * **都是数组**（AGENTS §4-57）。当成整数取会永远得 0，于是"指纹一致"被误判成"不一致"，
 * 可用率凭空掉一格（0.39.9 实测：habit-tree 明明 `matched=2 / stale=0 / missing=0`，
 * 清单却报"前端指纹不一致"）。纯函数化之后这条能被单测钉住。
 */
public func buildAssetFlagsOf(root: JsonValue): (Bool, Bool) {
    let exit = intFieldOf(root, "exitCode", -1)
    let buildOk = exit == 0 && boolFieldOf(objFieldOf(root, "gates"), "passed")
    let diff = objFieldOf(root, "assetDiff")
    let matched = arraySizeFieldOf(diff, "matched")
    let stale = arraySizeFieldOf(diff, "staleInSo")
    let missing = arraySizeFieldOf(diff, "missingInSo")
    let assetOk = matched > 0 && stale == 0 && missing == 0
    return (buildOk, assetOk)
}

/** `deploy` 落档 → 「装上 / 起来 / 日志健康」（纯函数，字段名按 `lingqu/deploy/v1` 的 install.ok / start.ok） */
public func deployFlagsOf(root: JsonValue): (Bool, Bool, Bool) {
    let installed = boolFieldOf(objFieldOf(root, "install"), "ok")
    let started = boolFieldOf(objFieldOf(root, "start"), "ok")
    let hilog = boolFieldOf(root, "hilogHealthy")
    return (installed, started, hilog)
}

/**
 * 把前面几轮的落档汇总成清单输入。
 *
 * 每段都刻意"读不到就当没跑过"——verify 的价值在于如实反映现状，
 * 不能因为缺一份落档就让整条流水线报错（那会让人误以为是 verify 坏了）。
 */
func collectVerifyInput(projName: String, projPath: String): ChecklistInput {
    let inp = ChecklistInput()

    // ② 迁移画像（扫描）：清单规模来自这里
    // 读侧一律走 resolveLqPath（工程优先、CWD 兜底）：0.38.0 起落档落在 <工程>/.lingqu/，
    // 还按相对 CWD 读会**读到上一次或别的工程的旧档**——实测把"刚部署成功"报成"装上了但没起来"。
    let scanOpt = readJsonOrNone(resolveLqPath(projPath, "scan/${projName}.json"))
    match (scanOpt) {
        case Some(scan) =>
            let items = objFieldOf(scan, "items")
            inp.commandCount = arraySizeFieldOf(items, "commands")
            inp.eventCount = arraySizeFieldOf(items, "events")
            inp.pluginCount = arraySizeFieldOf(items, "plugins")
            inp.frontendCount = arraySizeFieldOf(items, "frontend")
            inp.platformCount = arraySizeFieldOf(items, "platform")
            match (objFieldOf(scan, "blockers").kind()) {
                case JsonKind.JsArray => inp.blockerCount = objFieldOf(scan, "blockers").asArray().size()
                case _ => inp.blockerCount = 0
            }
            // 核心功能清单（A4 的分母）+ 平台 API 落地情况
            let (feats, plats) = scanSurfaceOf(scan, projName, projPath)
            inp.features = feats
            inp.platformItems = plats
        case None => ()
    }

    // 事件实测通道（0.39.133）：`probe.json` 里以 `event:` 前缀登记的条目 = 真机上逐条触发过的事件。
    // 为什么单开一种键：事件不是"点某个按钮"，按文本点按的探针（`feat:probe:*`）覆盖不到它；
    // 而 `events` 项原来两分支都写 unknown ⇒ 没有这条通道就永远判不了 pass。
    match (readJsonOrNone(resolveLqPath(projPath, "verify/${projName}.probe.json"))) {
        case Some(root) =>
            let feats = objFieldOf(root, "features")
            match (feats.kind()) {
                case JsonKind.JsObject =>
                    for ((pk, pv) in feats.asObject().getFields()) {
                        if (!pk.startsWith("event:")) {
                            continue
                        }
                        if (jsonStrField(pv, "verdict") != "pass") {
                            continue
                        }
                        inp.eventProbePass += 1
                        inp.eventProbeNames.add(pk[6..pk.size])
                    }
                case _ => ()
            }
        case None => ()
    }

    // 平台能力的**实测结论优先**（0.39.133）：`probe.json` 的 `platform:<符号>` 覆盖静态推断。
    // 现场教训（EcoPaste 剪贴板）：桥写了、能编能装，静态判据会算"有落地"，可真机上
    // `getDataSync()` 返回 `records=0`——功能实际不可用，报告却 100%。
    match (readJsonOrNone(resolveLqPath(projPath, "verify/${projName}.probe.json"))) {
        case Some(root) =>
            for (p in inp.platformItems) {
                let (pv, pn) = platformProbeVerdictOf(root, p.name)
                if (pv == "") {
                    continue
                }
                if (pv == "fail") {
                    p.fallbackLanded = false
                    p.note = "真机实测不可用：${pn}"
                } else {
                    p.fallbackLanded = true
                    p.note = "真机实测：${pn}"
                }
            }
        case None => ()
    }

    // ⑤ 交叉编译：退出码 + 前端指纹比对
    // ② 交叉编译 + 前端指纹（"跑过没有"与"过没过"分开记：§4-63）
    match (readJsonOrNone(resolveLqPath(projPath, "build/${projName}.json"))) {
        case Some(build) =>
            let (bOk, aOk) = buildAssetFlagsOf(build)
            inp.buildOk = bOk
            inp.assetOk = aOk
            inp.hasBuild = true
        case None => ()
    }

    // ③ HAP 装配闸
    match (readJsonOrNone(resolveLqPath(projPath, "hap/${projName}.json"))) {
        case Some(hap) =>
            inp.hapOk = boolFieldOf(objFieldOf(hap, "gates"), "passed") && boolFieldOf(hap, "built")
            inp.hasHap = true
            inp.hapBuilt = boolFieldOf(hap, "built")
            inp.hapSigned = boolFieldOf(hap, "signed")
            inp.hapFirstFailure = firstArrayItemOf(objFieldOf(hap, "gates"), "failures")
        case None => ()
    }

    // ⑥ 真机部署：装 / 启 / 日志
    match (readJsonOrNone(resolveLqPath(projPath, "deploy/${projName}.json"))) {
        case Some(dep) =>
            let (inst, started, hilog) = deployFlagsOf(dep)
            inp.installed = inst
            inp.started = started
            inp.hilogHealthy = hilog
        case None => ()
    }

    return inp
}

/**
 * 落档里一条命中位置（`src-tauri/src/commands.rs:95`）→ 文件部分。
 *
 * 只认"冒号后面紧跟数字"的那个分隔（行号），避免把 Windows 盘符 `C:` 也切断。
 */
func siteFileOf(site: String): String {
    var cut: Int64 = -1
    var i = 0
    while (i < site.size) {
        if (site[i] == 58 && i + 1 < site.size && site[i + 1] >= 48 && site[i + 1] <= 57) {
            cut = i
        }
        i += 1
    }
    if (cut < 0) {
        return site
    }
    return site[0..cut]
}

/** 读工程里的源文件（读不到给空串——调用方按"没证据"处理，绝不当"通过"） */
func readProjectSrc(projPath: String, rel: String): String {
    if (rel == "") {
        return ""
    }
    let p = projPath + cjhPathSep() + rel
    if (!exists(Path(p))) {
        return ""
    }
    try {
        return lenientUtf8(File.readFrom(p))
    } catch (e: Exception) {
        let _ = e
        return ""
    }
}

/** 限深收集 `.ets`（`Directory.walk` 非递归；gen/ohos 里还有 oh_modules 这类重目录，跳过） */
func collectEtsUnder(dir: String, depth: Int64, out: ArrayList<String>): Unit {
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
        if (nm == "node_modules" || nm == "oh_modules" || nm == ".git" || nm == "target" ||
            nm == "build" || nm == ".hvigor") {
            continue
        }
        let full = dir + cjhPathSep() + nm
        if (info.isDirectory()) {
            collectEtsUnder(full, depth - 1, out)
        } else if (nm.size > 4 && nm[(nm.size - 4)..nm.size] == ".ets") {
            out.add(full)
        }
    }
}

/** 限深收集 `.rs` 源文件内容（判据沿 helper 追一层要用；跳过与 collectEtsUnder 同款重目录 + gen） */
func collectRsContents(dir: String, depth: Int64, out: ArrayList<String>): Unit {
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
        if (nm == "node_modules" || nm == "oh_modules" || nm == ".git" || nm == "target" ||
            nm == "build" || nm == ".hvigor" || nm == "gen") {
            continue
        }
        let full = dir + cjhPathSep() + nm
        if (info.isDirectory()) {
            collectRsContents(full, depth - 1, out)
        } else if (nm.size > 3 && nm[(nm.size - 3)..nm.size] == ".rs") {
            var t = ""
            try {
                t = lenientUtf8(File.readFrom(full))
            } catch (e: Exception) {
                let _ = e
            }
            if (t != "") {
                out.add(t)
            }
        }
    }
}

/** 工程里 Rust 源码的内容集合：src-tauri/src 优先，扁平工程的 src 兜底（都没有 → 空集，追不动） */
func readAllRsOf(projPath: String): ArrayList<String> {
    let out = ArrayList<String>()
    for (r in ["src-tauri/src", "src"]) {
        collectRsContents(projPath + cjhPathSep() + r, 10, out)
    }
    return out
}

/** 把候选 helper 名 → 定义所在源文填进 resolved（工程内找不到的不放，判据按"没追到"处理） */
func fillHelperSrcs(names: ArrayList<String>, contents: ArrayList<String>,
    resolved: HashMap<String, String>): Unit {
    for (nm in names) {
        if (nm == "" || resolved.contains(nm)) {
            continue
        }
        for (t in contents) {
            if (fnImplsOf(t, nm).size > 0) {
                resolved.add(nm, t)
                break
            }
        }
    }
}

/**
 * 递归填 helper 源表（最多 maxDepth 层）。
 *
 * 只填一层时，`cmd → app_data_dir → bootstrap_dir` 这种链上的第二层查不到 ⇒ 判据就算想追也追不动
 * （0.39.131，EcoPaste 实测：`bootstrap_dir` 的鸿蒙分支明明存在，却被判成"都没落地"）。
 */
func fillHelperSrcsDeep(names: ArrayList<String>, contents: ArrayList<String>,
    resolved: HashMap<String, String>, maxDepth: Int64): Unit {
    var frontier = names
    var depth: Int64 = 0
    while (depth < maxDepth && frontier.size > 0) {
        fillHelperSrcs(frontier, contents, resolved)
        let next = ArrayList<String>()
        for (nm in frontier) {
            match (resolved.get(nm)) {
                case Some(t) =>
                    for (h in helperCallNamesOfLoose(t, nm)) {
                        if (h != nm && !resolved.contains(h) && !next.contains(h)) {
                            next.add(h)
                        }
                    }
                case None => ()
            }
        }
        frontier = next
        depth += 1
    }
}

/**
 * 工程里的 ArkTS 分发器正文（含 `__ohos_dispatch` 的 `.ets` 拼起来；找不到给空串）。
 *
 * 为什么要它：桥的"落地"是**两侧**的事（Rust 调 `call_arkts("x")` + ArkTS 有 `case "x"`）。
 * `cargo build`（含 `--target ...ohos`）**不编译 ArkTS**，只有 hvigor 审——只查 Rust 半边
 * 就会把"半实现"判成落地（§4-162，真机点了没反应那种假绿）。
 */
func readArktsDispatcherOf(projPath: String): String {
    let files = ArrayList<String>()
    for (r in ["src-tauri/gen/ohos", "gen/ohos", "src-tauri/ohos", "ohos"]) {
        let p = projPath + cjhPathSep() + r
        if (exists(Path(p))) {
            collectEtsUnder(p, 8, files)
        }
    }
    var text = ""
    for (f in files) {
        var t = ""
        try {
            t = lenientUtf8(File.readFrom(f))
        } catch (e: Exception) {
            let _ = e
        }
        if (t != "" && t.indexOf("__ohos_dispatch").isSome()) {
            text += t + "\n"
        }
    }
    return text
}

/**
 * scan 落档 → **原应用业务功能清单**（每条 IPC 命令一项）+ **平台 API 落地情况**。
 *
 * D-020：这些业务功能**不进 A4 分母**（属原应用职责，缺网/缺配置就必然过不了），
 * 但"命中的平台 API 有没有落地等价实现"仍是**移植该负责的事**——所以照旧要读源码判降级。
 *
 * 为什么要读源码：scan 只记了"这条命令在哪一行"和"这里用了 rfd::FileDialog"，
 * 而判据要的是"降级方案**落地了没有**"——那必须看 `#[cfg(target_env = "ohos")]`
 * 那一套实现里到底写了什么（现场是 `None`，等于没落地）。
 * 判定本体是 `verify.cj` 里的纯函数（`ohosImplStubOnly` / `firstApiHitIn`），这里只负责取数。
 *
 * 人工实测结论读 `<工程>/.lingqu/verify/<工程>.human.json`：`{ "pick_folder": "fail" }`。
 * **人的实测永远优先**——推断只能说明"看起来能不能用"。
 */
func scanSurfaceOf(scan: JsonValue, projName: String,
    projPath: String): (ArrayList<FeatureInput>, ArrayList<PlatformInput>) {
    let features = ArrayList<FeatureInput>()
    let platforms = ArrayList<PlatformInput>()
    let items = objFieldOf(scan, "items")

    // 平台 API 名单（判"这条命令碰没碰平台专有能力"要用）
    let apiNames = ArrayList<String>()
    // 0.39.129：判据沿 helper 追一层的素材——工程 Rust 源码读一次（没有 .rs 时追不动，
    // 行为与旧判据一致）。EcoPaste 现场：命令层调 core::paths::app_data_dir()，
    // 鸿蒙回沙箱逻辑在 helper 里，只看命中文件会冤枉 fail（§4-157 同族）。
    let rsContents = readAllRsOf(projPath)
    let helperSrcs = HashMap<String, String>()
    // ArkTS 分发器只读一次：桥的双侧判据要用它（§4-162；cargo 不审 ArkTS，别只查 Rust 半边）
    let arktsDispatch = readArktsDispatcherOf(projPath)
    let platArr = objFieldOf(items, "platform")
    match (platArr.kind()) {
        case JsonKind.JsArray =>
            let a = platArr.asArray()
            var k: Int64 = 0
            while (k < a.size()) {
                match (a.get(k)) {
                    case Some(v) =>
                        let nm = jsonStrField(v, "name")
                        if (nm != "" && !apiNames.contains(nm)) {
                            apiNames.add(nm)
                            let pi = PlatformInput(nm)
                            pi.site = firstArrayItemOf(v, "sites")
                            platforms.add(pi)
                        }
                    case None => ()
                }
                k += 1
            }
        case _ => ()
    }

    // 人工实测结论（没有这个文件就是"全都还没人测过"，不是错误）
    var human = JsonObject()
    match (readJsonOrNone(resolveLqPath(projPath, "verify/${projName}.human.json"))) {
        case Some(h) => human = h.asObject()
        case None => ()
    }

    // 真机实测结论（我们自己点按取证后落的档，**不算人工介入**）：
    //   {"features": {"start_download": {"verdict":"pass","note":"日志回「请先输入…」","evidence":"<截图路径>"}}}
    // 与 human.json 分开存是故意的——A3 数的是"人被打扰几次"，探针不该虚增它；
    // 但它的证据强度高于静态推断：点了有没有响应是事实，代码看起来像空壳只是推断（0.39.93）。
    var probeFeatures = JsonObject()
    match (readJsonOrNone(resolveLqPath(projPath, "verify/${projName}.probe.json"))) {
        case Some(p) =>
            let feats = objFieldOf(p, "features")
            match (feats.kind()) {
                case JsonKind.JsObject => probeFeatures = feats.asObject()
                case _ => ()
            }
        case None => ()
    }

    // 逐条命令：命中哪处平台 API / 鸿蒙侧是不是空壳 / 人测过没有
    let cmdArr = objFieldOf(items, "commands")
    var matchedProbe = ArrayList<String>()
    match (cmdArr.kind()) {
        case JsonKind.JsArray =>
            let a = cmdArr.asArray()
            var k: Int64 = 0
            while (k < a.size()) {
                match (a.get(k)) {
                    case Some(v) =>
                        let nm = jsonStrField(v, "name")
                        if (nm != "") {
                            let f = FeatureInput(nm, nm)
                            let src = readProjectSrc(projPath, siteFileOf(firstArrayItemOf(v, "sites")))
                            if (src != "") {
                                f.degradedApi = firstApiHitIn(src, nm, apiNames)
                                fillHelperSrcsDeep(helperCallNamesOf(src, nm), rsContents, helperSrcs,
                                    HELPER_TRACE_DEPTH)
                                f.fallbackLanded = commandImplLandedWith(src, nm, helperSrcs)
                                // 桥命令必须**两侧都在**：Rust 调了 call_arkts("x")，ArkTS 得有 case "x"。
                                // 只写半边时 cargo 照样 exit=0，真机点了没反应（§4-162）。
                                let bv = bridgeTwoSidedOf(src, arktsDispatch, nm)
                                if (bv.callsBridge) {
                                    f.bridgeCmd = bv.cmd
                                    if (!bv.landed) {
                                        f.bridgeMissing = bv.reason
                                        f.fallbackLanded = false
                                    }
                                }
                            }
                            f.humanVerdict = jsonStrField(human, nm)
                            // 真机探针（有就记，没测过就留空 → 条目照旧判"未测"）
                            let pr = objFieldOf(probeFeatures, nm)
                            let pv = jsonStrField(pr, "verdict")
                            if (pv == "pass" || pv == "fail") {
                                f.probeVerdict = pv
                                f.probeNote = jsonStrField(pr, "note")
                                matchedProbe.add(nm)
                                let pe = jsonStrField(pr, "evidence")
                                if (pe != "") {
                                    f.probeEvidence.add(pe)
                                }
                            }
                            features.add(f)
                        }
                    case None => ()
                }
                k += 1
            }
        case _ => ()
    }

    // 真机实测过、但扫描的命令清单里没有同名项的功能——**不许静默丢**。
    // 实测现场（note-gen-2 2026-11-09）：探针点的是界面语义名（new_note / new_canvas / global_search），
    // 而清单是 IPC 命令名（ai_json_request …），对不上号 ⇒ 两条真机 pass 被丢掉，报告照旧写 0%。
    // 证据强度上，点过就是事实（高于任何静态推断），所以单独成项进清单，标题里写明来源。
    for ((pk, pv) in probeFeatures.getFields()) {
        if (matchedProbe.contains(pk)) {
            continue
        }
        let pvd = jsonStrField(pv, "verdict")
        if (pvd != "pass" && pvd != "fail") {
            continue
        }
        let pf = FeatureInput("probe:${pk}", "真机实测（未对应到扫描命令）：${pk}")
        pf.probeVerdict = pvd
        pf.probeNote = jsonStrField(pv, "note")
        let pev = jsonStrField(pv, "evidence")
        if (pev != "") {
            pf.probeEvidence.add(pev)
        }
        features.add(pf)
    }

    // 每处平台 API：碰它的命令在鸿蒙侧都落地了，才算"有降级方案"
    for (p in platforms) {
        var related: Int64 = 0
        var landed: Int64 = 0
        for (f in features) {
            if (f.degradedApi == p.name) {
                related += 1
                if (f.fallbackLanded) {
                    landed += 1
                }
            }
        }
        p.fallbackLanded = related > 0 && landed == related
        if (related == 0) {
            // 没有 IPC 命令命中它 → 看**命中行所在的那个函数**在鸿蒙侧落没落地。
            // 典型现场：habit-tree / m3u8dl-tauri 的 app_data_dir 都在 resolve_app_data_dir()
            // 里，鸿蒙分支返回沙箱路径（已落地）；旧判据对这种"非命令路径"直接记"无法判定
            // → 没落地"，platform-api 就冤枉地判 fail（0.39.107）。
            let siteFile = siteFileOf(p.site)
            let src = readProjectSrc(projPath, siteFile)
            if (src == "") {
                p.note = "没有 IPC 命令命中它，命中行的源码也读不到 → 无法判定是否落地，不能算平台限制"
            } else {
                // 前端没有 `#[cfg]` 可判，落地的形态是 try/catch 兜底（getVersion 就是）
                let isFrontend = siteFile.endsWith(".ts") || siteFile.endsWith(".js") ||
                    siteFile.endsWith(".tsx") || siteFile.endsWith(".html")
                let (gap, why) = if (isFrontend) {
                    judgeFrontendSite(src, siteLineOf(p.site))
                } else {
                    fillHelperSrcsDeep(helperCallNamesOf(src, enclosingFnOf(src, siteLineOf(p.site))),
                        rsContents, helperSrcs, HELPER_TRACE_DEPTH)
                    judgePlatformSiteWith(src, siteLineOf(p.site), helperSrcs)
                }
                p.fallbackLanded = !gap
                p.note = why
            }
        } else if (landed == related) {
            p.note = "${related} 个命令在鸿蒙侧都有落地的实现"
        } else {
            p.note = "${related - landed}/${related} 个命令的鸿蒙分支是空壳（等于没实现）"
        }
    }

    return (features, platforms)
}

/** 部署落档里的设备序列号（没有给 ""） */func deploySerialOf(projName: String, projPath: String): String {
    match (readJsonOrNone(resolveLqPath(projPath, "deploy/${projName}.json"))) {
        case Some(dep) => return jsonStrField(dep, "serial")
        case None => return ""
    }
}

/** 部署落档里的 bundleName（没有给 ""） */
func deployBundleOf(projName: String, projPath: String): String {
    match (readJsonOrNone(resolveLqPath(projPath, "deploy/${projName}.json"))) {
        case Some(dep) => return jsonStrField(dep, "bundleName")
        case None => return ""
    }
}

/** 采证结果 */
class EvidenceShot {
    var saved: Int64 = 0
    var crashes: Int64 = 0
    var log: String = ""
}

/**
 * 采真机证据：截图 + faultlog 计数。
 *
 * 两条纪律：
 *   · **hdc 失败时退出码仍是 0**（AGENTS §4-40）——所以截图以"文件真的落盘了"为准，
 *     不看退出码；`file recv` 之后 `exists()` 才算成功。
 *   · 采集失败不影响主流程：清单会把它记成 `unknown`（缺证据），而不是把"采不到"当"通过"。
 */
func collectEvidence(projName: String, projPath: String, hdc: String, serial: String,
    wantShots: Bool): EvidenceShot {
    let ev = EvidenceShot()
    if (hdc == "" || serial == "") {
        ev.log = "[evidence] 跳过：没有 hdc 或设备序列号\n"
        return ev
    }
    // 证据也跟着工程走（截图是对这个工程的真机取证）
    let dir = lqDirOf(projPath) + cjhPathSep() + "evidence"
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir), recursive: true)
        }
    } catch (e: Exception) {
        ev.log += "[evidence] 建目录失败：${e}\n"
        return ev
    }
    if (wantShots) {
        // 0.39.131：文件名带时间戳。此前固定叫 `<工程>-verify.jpeg`，recv 失败时
        // 「本地有文件」会把**上一次的截图**当成本次证据（真机实测：三条 hdc 命令全回
        // `Not match target founded`，落档却写「已保存」——§4-63 的"跑了但没测到"变体）。
        // 唯一文件名让"文件存在"只可能来自这一次。
        let name = "${projName}-verify-${evidenceStampOf()}.jpeg"
        let remote = "/data/local/tmp/${name}"
        try {
            let (code, out, errOut) = executeWithOutput(hdc,
                ["-t", serial, "shell", "snapshot_display", "-f", remote])
            ev.log += "[evidence] snapshot exit=${code}\n" + lenientUtf8(out) + lenientUtf8(errOut) + "\n"
        } catch (e: Exception) {
            ev.log += "[evidence] snapshot 起不来：${e}\n"
        }
        let local = "${dir}/${name}"
        try {
            let (code, out, errOut) = executeWithOutput(hdc, ["-t", serial, "file", "recv", remote, local])
            ev.log += "[evidence] recv exit=${code}\n" + lenientUtf8(out) + lenientUtf8(errOut) + "\n"
        } catch (e: Exception) {
            ev.log += "[evidence] recv 起不来：${e}\n"
        }
        if (exists(Path(local))) {
            ev.saved += 1
            ev.log += "[evidence] 已保存 ${local}\n"
        } else {
            ev.log += "[evidence] 截图没落盘（${local} 不存在）\n"
        }
    }
    // faultlog：有崩溃记录就计数（空目录 = 0）
    try {
        let (code, out, errOut) = executeWithOutput(hdc,
            ["-t", serial, "shell", "ls", "/data/log/faultlog/faultlogger/"])
        let text = lenientUtf8(out) + lenientUtf8(errOut)
        ev.log += "[evidence] faultlog exit=${code}\n" + text + "\n"
        // 只认像崩溃记录的行：`ls` 权限不足时的 "Permission denied" 绝不能算成崩溃
        // （这是真机实测踩到的坑，见 verify.cj 的 countCrashRecords）
        ev.crashes = countCrashRecords(text)
        if (faultlogUnreadable(text)) {
            ev.log += "[evidence] faultlog 读不到（权限或目录不存在）——按「无证据」处理，不当作崩溃\n"
        }
    } catch (e: Exception) {
        ev.log += "[evidence] faultlog 起不来：${e}\n"
    }
    return ev
}

/** 采证文件名用的时间戳（毫秒；取不到给 0，不阻塞采证） */
func evidenceStampOf(): String {
    try {
        return "${DateTime.now().toUnixTimeStamp().toMilliseconds()}"
    } catch (e: Exception) {
        return "0"
    }
}

/** 当前时间（报告里要用）；取不到给空串，不阻塞落档 */
func nowText(): String {
    match (getVariable("LINGQU_NOW")) {
        case Some(v) =>
            if (v != "") {
                return v
            }
        case None => ()
    }
    try {
        return DateTime.now().toString()
    } catch (e: Exception) {
        let _ = e
        return ""
    }
}
