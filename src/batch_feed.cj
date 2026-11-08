package lingqu

import lingqu.batch.*
import lingqu.report.*
import lingqu.scanner.*
import std.collection.*
import std.fs.*
import stdx.encoding.json.*

/*
 * `t2h:batch` 的收数层：把每个样本自己的 `.lingqu` 落档汇总成矩阵的一行。
 *
 * 与 `report_feed.cj` 的分工：那边是"一个工程出一份报告"，这边是"多个工程并排比"。
 * 同样**只读落档**：批量矩阵不该反过来影响任何样本。
 *
 * 一条纪律（矩阵的意义所在）：**没有落档就留"没有"**——`hasScan/hasDeps/hasVerify`
 * 三个布尔位决定单元格显示"未跑"还是数字。把"没跑"补成 0 会让平均分凭空变低，
 * 那是比"缺数据"更坏的错误。
 */

/**
 * 读一个样本的落档：**按该样本自己的工程路径解析**（`<工程>/.lingqu/…`）。
 *
 * 0.39.29 修复：这里原来一律是相对当前工作目录的 `.lingqu/...`，于是矩阵读的是
 * **本仓/当前目录**的旧档，而不是样本工程自己的落档 —— 实测 m3u8dl-tauri 明明跑到了
 * 可用率 100%，矩阵里却写着「未跑 / 25%」。同族问题在 `report_feed`（0.39.24）修过一遍，
 * 这是漏网的第二处（AGENTS §4-75）。工程路径为空时 `resolveLqPath` 自动落回相对路径，老行为不丢。
 */
public func readSampleLq(projPath: String, rel: String): Option<JsonValue> {
    let p = projPath.trimAscii()
    // 工程目录**根本不存在**（改名/删掉/路径敲错）时，不要落回 `.lingqu/<rel>`：
    // 那会把本仓里同名工程的旧档**冒名**算到这个样本头上（§4-96 的核心教训——
    // 矩阵读错档时显示的是"别人的成绩"）。路径存在但还没 `.lingqu` 时仍允许兜底，
    // 兼容 0.38.0 之前留在仓库根下的老落档。
    if (p.size > 0 && !exists(Path(hostPath(p)))) {
        return None
    }
    return readJsonOrNone(resolveLqPath(p, rel))
}

/** 落档相对路径（步骤 + 工程名 → `.lingqu` 下的相对路径），单测钉住名字拼法 */
public func sampleLqRel(step: String, projName: String): String {
    return "${step}/${projName}.json"
}

/** 收集一个样本的一行（落档缺失时对应 `has*` 为 false） */
public func collectBatchRow(projName: String, projPath: String, now: String): BatchRow {
    let row = BatchRow()
    row.project = projName
    row.path = projPath

    // ② 扫描画像：评分 + 单元数 + 未知项
    match (readSampleLq(projPath, sampleLqRel("scan", projName))) {
        case Some(scan) =>
            row.hasScan = true
            let metrics = objFieldOf(scan, "metrics")
            let score = objFieldOf(scan, "score")
            row.scanScore = intFieldOf(score, "total", -1)
            row.scanUnits = intFieldOf(metrics, "R", 0)
            row.scanUnknown = intFieldOf(metrics, "U", 0)
        case None => ()
    }

    // ③ 依赖矩阵
    match (readSampleLq(projPath, sampleLqRel("deps", projName))) {
        case Some(deps) =>
            let m = objFieldOf(deps, "metrics")
            let total = intFieldOf(m, "total", 0)
            if (total > 0) {
                row.hasDeps = true
                row.depsTotal = total
                row.depsUnavailable = intFieldOf(m, "unavailable", 0)
            }
        case None => ()
    }

    // ⑤ 编译 / 装配 / 签名态
    match (readSampleLq(projPath, sampleLqRel("build", projName))) {
        case Some(build) =>
            row.hasBuild = true
            let gates = objFieldOf(build, "gates")
            row.buildOk = intFieldOf(build, "exitCode", -1) == 0 && boolFieldOf(gates, "passed")
        case None => ()
    }
    match (readSampleLq(projPath, sampleLqRel("hap", projName))) {
        case Some(hap) =>
            row.hasHap = true
            row.hapOk = boolFieldOf(hap, "built") && boolFieldOf(objFieldOf(hap, "gates"), "passed")
        case None => ()
    }
    match (readSampleLq(projPath, sampleLqRel("sign", projName))) {
        case Some(sign) =>
            let mode = objFieldOf(sign, "mode")
            row.signMode = jsonStrField(mode, "mode")
            row.releaseReady = boolFieldOf(mode, "releaseReady")
        case None => ()
    }

    // ⑥ 真机部署与验证
    match (readSampleLq(projPath, sampleLqRel("deploy", projName))) {
        case Some(dep) =>
            row.hasDeploy = true
            row.deployOk = boolFieldOf(objFieldOf(dep, "install"), "ok") &&
                boolFieldOf(objFieldOf(dep, "start"), "ok")
        case None => ()
    }
    match (readSampleLq(projPath, sampleLqRel("verify", projName))) {
        case Some(verify) =>
            let stats = objFieldOf(verify, "stats")
            let total = intFieldOf(stats, "total", 0)
            if (total > 0) {
                row.hasVerify = true
                row.verifyRate = intFieldOf(stats, "ratePercent", -1)
                row.verifyPass = intFieldOf(stats, "pass", 0)
                row.verifyTotal = total
                row.verifyLimit = intFieldOf(stats, "limit", 0)
                row.verifyCovered = intFieldOf(stats, "covered", -1)
                row.verifyNotVerified = intFieldOf(stats, "notVerified", -1)
            }
        case None => ()
    }

    // 8 步进度（与断点板同源）
    let board = collectTaskBoard(projName, projPath, now)
    let pr = taskProgress(board)
    row.stepDone = pr.done
    row.stepTotal = pr.total

    // A3 人工介入（采纳才算一次）
    let hc = countHumanDecisions(collectDecisionValues(projName, projPath))
    row.humanAccepted = hc.accepted
    return row
}

/**
 * 收集矩阵：`samples` 是 (工程名, 工程路径) 列表，顺序即表格顺序。
 *
 * 工程名由命令层统一净化（`sanitizeFileName(projectNameOf(path))`），
 * 与各命令落档用的名字一致——否则矩阵会读到空落档，显示"整片未跑"。
 */
public func collectBatchMatrix(samples: ArrayList<(String, String)>, now: String): BatchMatrix {
    let rows = ArrayList<BatchRow>()
    for (s in samples) {
        rows.add(collectBatchRow(s[0], s[1], now))
    }
    return buildMatrix(rows, now)
}

/** 落档目录里出现过的工程名（union）——没传 samples 时的默认集合，按名字排序 */
public func discoverSampleNames(): ArrayList<String> {
    let seen = ArrayList<String>()
    let dirs = [".lingqu/scan", ".lingqu/deps", ".lingqu/verify", ".lingqu/report", ".lingqu/hap"]
    for (d in dirs) {
        if (!exists(Path(d))) {
            continue
        }
        var entries: Array<FileInfo>
        try {
            entries = Directory.readFrom(d)
        } catch (e: Exception) {
            let _ = e
            continue
        }
        for (info in entries) {
            if (info.isDirectory() || !info.name.endsWith(".json")) {
                continue
            }
            let name = info.name[0..(info.name.size - ".json".size)]
            if (name == "" || name.startsWith("tmp")) {
                continue
            }
            var dup = false
            for (s in seen) {
                if (s == name) {
                    dup = true
                }
            }
            if (!dup) {
                seen.add(name)
            }
        }
    }
    // 简单插入排序（样本量很小，不引额外依赖）
    let out = ArrayList<String>()
    for (name in seen) {
        var idx: Int64 = 0
        while (idx < out.size && out[idx] < name) {
            idx += 1
        }
        out.add("")
        var i = out.size - 1
        while (i > idx) {
            out[i] = out[i - 1]
            i -= 1
        }
        out[idx] = name
    }
    return out
}

// ============================================================
// 样本发现（0.39.29）：从"只发现工程名"升级到"发现工程路径"
// ============================================================
//
// 为什么要升级：0.38.0 起落档在 `<工程>/.lingqu/`，但 `discoverSampleNames()` 只从
// **当前目录**的 `.lingqu` 里捡名字，捡到之后又没有路径可读 —— 于是矩阵要么读不到、
// 要么读到本仓的旧档。真正的"我迁过哪些工程"要看**工作区里哪些目录带 `.lingqu`**。

/** 显式给的样本路径会记在这里（一行一个），下次自动发现也带上，免得每回都手填 */
public const BATCH_SAMPLES_FILE: String = ".lingqu/batch/samples.txt"

/** 加进列表（去重，保持插入顺序） */
func addUniqueStr(list: ArrayList<String>, v: String): Unit {
    if (v.size == 0) {
        return
    }
    for (x in list) {
        if (x == v) {
            return
        }
    }
    list.add(v)
}

/** 拆根目录列表：`|` / `;` / 逗号 / 换行都能当分隔符，去空白去重（纯函数，单测覆盖） */
public func splitRootList(raw: String): ArrayList<String> {
    let out = ArrayList<String>()
    let normalized = raw.replace("\r", "\n").replace("|", "\n").replace(";", "\n").replace(",", "\n")
    for (part in normalized.split("\n", -1)) {
        addUniqueStr(out, part.trimAscii())
    }
    return out
}

/**
 * 候选根目录（纯函数）：`LINGQU_SAMPLES_ROOT` → `LINGQU_WORKSPACES` → `~/lingqu-workspaces`。
 *
 * 三者是**并集**（不是择一）：显式根最优先，工作区根常备，家目录默认工作区兜底。
 */
public func sampleRootsOf(samplesRootEnv: String, workspacesEnv: String, homeDir: String): ArrayList<String> {
    let out = splitRootList(samplesRootEnv)
    for (r in splitRootList(workspacesEnv)) {
        addUniqueStr(out, r)
    }
    if (homeDir.trimAscii().size > 0) {
        addUniqueStr(out, hostPath("${homeDir}/lingqu-workspaces"))
    }
    return out
}

/** 这个目录像不像"迁过的工程"：有 `.lingqu` 目录就算（落档都写在那儿） */
func looksLikeMigratedProject(dir: String): Bool {
    return exists(Path(dir + cjhPathSep() + ".lingqu"))
}

/**
 * 在候选根下发现样本工程 → `(工程名, 工程绝对路径)`，同名只留第一个。
 *
 * 扫描深度为 1 层（根自身 + 其子目录）：再深就会把 `node_modules`/`targets` 之类扫进来。
 */
public func discoverSampleProjects(roots: ArrayList<String>): ArrayList<(String, String)> {
    let out = ArrayList<(String, String)>()
    let seenNames = ArrayList<String>()

    for (root in roots) {
        if (!exists(Path(root))) {
            continue
        }
        if (looksLikeMigratedProject(root)) {
            let name = sanitizeFileName(projectNameOf(root))
            if (name.size > 0 && !seenNames.contains(name)) {
                out.add((name, root))
                seenNames.add(name)
            }
        }
        var entries: Array<FileInfo>
        try {
            entries = Directory.readFrom(root)
        } catch (e: Exception) {
            let _ = e
            continue
        }
        for (info in entries) {
            if (!info.isDirectory()) {
                continue
            }
            let child = root + cjhPathSep() + info.name
            if (!looksLikeMigratedProject(child)) {
                continue
            }
            let name = sanitizeFileName(info.name)
            if (name.size == 0 || name.startsWith("tmp") || seenNames.contains(name)) {
                continue
            }
            out.add((name, child))
            seenNames.add(name)
        }
    }
    return out
}

/** 记下显式样本路径（下次自动发现带上）；写盘失败只影响"下次要重填"，不阻断本次矩阵 */
public func saveBatchSamplePaths(paths: ArrayList<String>): Unit {
    if (paths.size == 0) {
        return
    }
    let dir = ".lingqu/batch"
    if (!exists(Path(dir))) {
        try {
            Directory.create(Path(dir), recursive: true)
        } catch (e: Exception) {
            let _ = e
            return
        }
    }
    var text = ""
    for (p in paths) {
        text += "${p}\n"
    }
    try {
        File.writeTo(BATCH_SAMPLES_FILE, text.toArray())
    } catch (e: Exception) {
        let _ = e
    }
}

/** 读回上次记的样本路径（不存在/读不了就当没有） */
public func loadBatchSamplePaths(): ArrayList<String> {
    let out = ArrayList<String>()
    if (!exists(Path(BATCH_SAMPLES_FILE))) {
        return out
    }
    var text = ""
    try {
        text = String.fromUtf8(File.readFrom(BATCH_SAMPLES_FILE))
    } catch (e: Exception) {
        let _ = e
        return out
    }
    for (line in text.split("\n", -1)) {
        addUniqueStr(out, line.trimAscii())
    }
    return out
}
