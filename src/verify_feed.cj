package lingqu

import lingqu.verify.*
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
        case None => ()
    }

    // ⑤ 交叉编译：退出码 + 前端指纹比对
    match (readJsonOrNone(resolveLqPath(projPath, "build/${projName}.json"))) {
        case Some(build) =>
            let (bOk, aOk) = buildAssetFlagsOf(build)
            inp.buildOk = bOk
            inp.assetOk = aOk
        case None => ()
    }

    // ⑤ HAP 装配闸
    match (readJsonOrNone(resolveLqPath(projPath, "hap/${projName}.json"))) {
        case Some(hap) =>
            inp.hapOk = boolFieldOf(objFieldOf(hap, "gates"), "passed") && boolFieldOf(hap, "built")
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

/** 部署落档里的设备序列号（没有给 ""） */
func deploySerialOf(projName: String, projPath: String): String {
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
