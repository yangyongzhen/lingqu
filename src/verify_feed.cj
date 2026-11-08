package lingqu

import lingqu.verify.*
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
        let text = String.fromUtf8(File.readFrom(p))
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
    match (readJsonOrNone(resolveLqPath(projPath, "scan/${projName}.json"))) {
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
        return String.fromUtf8(File.readFrom(p))
    } catch (e: Exception) {
        let _ = e
        return ""
    }
}

/**
 * scan 落档 → **核心功能清单**（每条 IPC 命令一项）+ **平台 API 落地情况**。
 *
 * 为什么要读源码：scan 只记了"这条命令在哪一行"和"这里用了 rfd::FileDialog"，
 * 而 A4 新口径要的是"降级方案**落地了没有**"——那必须看 `#[cfg(target_env = "ohos")]`
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
                            platforms.add(PlatformInput(nm))
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
                                f.fallbackLanded = !ohosImplStubOnly(src, nm)
                            }
                            f.humanVerdict = jsonStrField(human, nm)
                            // 真机探针（有就记，没测过就留空 → 条目照旧判"未测"）
                            let pr = objFieldOf(probeFeatures, nm)
                            let pv = jsonStrField(pr, "verdict")
                            if (pv == "pass" || pv == "fail") {
                                f.probeVerdict = pv
                                f.probeNote = jsonStrField(pr, "note")
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
            p.note = "没有 IPC 命令命中它（可能用在非命令路径）→ 无法判定是否落地，不能算平台限制"
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
        let name = "${projName}-verify.jpeg"
        let remote = "/data/local/tmp/${name}"
        try {
            let (code, out, errOut) = executeWithOutput(hdc,
                ["-t", serial, "shell", "snapshot_display", "-f", remote])
            ev.log += "[evidence] snapshot exit=${code}\n" + String.fromUtf8(out) + String.fromUtf8(errOut) + "\n"
        } catch (e: Exception) {
            ev.log += "[evidence] snapshot 起不来：${e}\n"
        }
        let local = "${dir}/${name}"
        try {
            let (code, out, errOut) = executeWithOutput(hdc, ["-t", serial, "file", "recv", remote, local])
            ev.log += "[evidence] recv exit=${code}\n" + String.fromUtf8(out) + String.fromUtf8(errOut) + "\n"
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
        let text = String.fromUtf8(out) + String.fromUtf8(errOut)
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
