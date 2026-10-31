package lingqu

import lingqu.batch.*
import lingqu.report.*
import std.collection.*
import std.fs.*

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

/** 收集一个样本的一行（落档缺失时对应 `has*` 为 false） */
public func collectBatchRow(projName: String, projPath: String, now: String): BatchRow {
    let row = BatchRow()
    row.project = projName
    row.path = projPath

    // ② 扫描画像：评分 + 单元数 + 未知项
    match (readJsonOrNone(".lingqu/scan/${projName}.json")) {
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
    match (readJsonOrNone(".lingqu/deps/${projName}.json")) {
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
    match (readJsonOrNone(".lingqu/build/${projName}.json")) {
        case Some(build) =>
            row.hasBuild = true
            let gates = objFieldOf(build, "gates")
            row.buildOk = intFieldOf(build, "exitCode", -1) == 0 && boolFieldOf(gates, "passed")
        case None => ()
    }
    match (readJsonOrNone(".lingqu/hap/${projName}.json")) {
        case Some(hap) =>
            row.hasHap = true
            row.hapOk = boolFieldOf(hap, "built") && boolFieldOf(objFieldOf(hap, "gates"), "passed")
        case None => ()
    }
    match (readJsonOrNone(".lingqu/sign/${projName}.json")) {
        case Some(sign) =>
            let mode = objFieldOf(sign, "mode")
            row.signMode = jsonStrField(mode, "mode")
            row.releaseReady = boolFieldOf(mode, "releaseReady")
        case None => ()
    }

    // ⑥ 真机部署与验证
    match (readJsonOrNone(".lingqu/deploy/${projName}.json")) {
        case Some(dep) =>
            row.hasDeploy = true
            row.deployOk = boolFieldOf(objFieldOf(dep, "install"), "ok") &&
                boolFieldOf(objFieldOf(dep, "start"), "ok")
        case None => ()
    }
    match (readJsonOrNone(".lingqu/verify/${projName}.json")) {
        case Some(verify) =>
            let stats = objFieldOf(verify, "stats")
            let total = intFieldOf(stats, "total", 0)
            if (total > 0) {
                row.hasVerify = true
                row.verifyRate = intFieldOf(stats, "ratePercent", -1)
                row.verifyPass = intFieldOf(stats, "pass", 0)
                row.verifyTotal = total
                row.verifyLimit = intFieldOf(stats, "limit", 0)
            }
        case None => ()
    }

    // 8 步进度（与断点板同源）
    let board = collectTaskBoard(projName, projPath, now)
    let pr = taskProgress(board)
    row.stepDone = pr.done
    row.stepTotal = pr.total

    // A3 人工介入（采纳才算一次）
    let hc = countHumanDecisions(collectDecisionValues(projName))
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
