package lingqu

import lingqu.report.*
import lingqu.compiler.*
import std.collection.*
import std.fs.*
import stdx.encoding.json.*

/*
 * `t2h:report` 的收数层：把 `.lingqu/` 下已有的落档汇总成一份 `MigrationFacts`。
 *
 * 与 `verify_feed.cj` 的分工：那边是"为验证清单取数"，这边是"为迁移报告取数"——
 * 两者都**只读落档、不跑子进程**（报告不该有副作用：出报告不能反过来改工程）。
 *
 * 一条纪律：落档不存在就不写这段事实（不填假值）。报告里出现"0 份证据"是诚实的，
 * 出现一个编出来的数字才是事故。
 */

/** 统计目录里以 `<工程>-` 开头的文件（证据张数；读不到目录就给 0） */
func countEvidenceFiles(projName: String, projPath: String): Int64 {
    let dir = resolveLqPath(projPath, "evidence")
    if (!exists(Path(dir))) {
        return 0
    }
    var entries: Array<FileInfo>
    try {
        entries = Directory.readFrom(dir)
    } catch (e: Exception) {
        let _ = e
        return 0
    }
    var n: Int64 = 0
    for (info in entries) {
        if (info.isDirectory()) {
            continue
        }
        // FileInfo 的名字是 `name` 属性（不是 toString()，见 AGENTS §4-59）
        if (info.name.startsWith(projName + "-")) {
            n += 1
        }
    }
    return n
}

/** 读 `decisions.json` 里每条决策的 decision 值（没有落档给空表） */
func collectDecisionValues(projName: String, projPath: String): ArrayList<String> {
    let out = ArrayList<String>()
    let p = resolveLqPath(projPath, "port/${projName}/decisions.json")
    match (readJsonOrNone(p)) {
        case Some(root) =>
            let arr = objFieldOf(root, "items")
            match (arr.kind()) {
                case JsonKind.JsArray =>
                    var i: Int64 = 0
                    while (i < arr.asArray().size()) {
                        out.add(jsonStrField(arr.asArray()[i], "decision"))
                        i += 1
                    }
                case _ => ()
            }
        case None => ()
    }
    return out
}

/** 把 verify 清单里某一判定的标题收集起来（limit / unknown / fail 三类各取一份） */
func collectVerdictTitles(verifyRoot: JsonValue, verdict: String): ArrayList<String> {
    let out = ArrayList<String>()
    let arr = objFieldOf(verifyRoot, "items")
    match (arr.kind()) {
        case JsonKind.JsArray =>
            var i: Int64 = 0
            while (i < arr.asArray().size()) {
                let it = arr.asArray()[i]
                if (jsonStrField(it, "verdict") == verdict) {
                    out.add(jsonStrField(it, "title"))
                }
                i += 1
            }
        case _ => ()
    }
    return out
}

/**
 * 落档存在才加进附录（不存在的路径写进报告等于虚构证据）。
 *
 * 判存在用 `resolveLqPath(projPath, rel)`（工程内真实位置），
 * **写进报告仍用相对路径**——附录是给人看的，绝对路径一屏塞不下。
 */
func addArtifactIfExists(list: ArrayList<(String, String)>, label: String, rel: String,
    projPath: String): Unit {
    if (rel == "") {
        return
    }
    if (exists(Path(resolveLqPath(projPath, bareLqRel(rel))))) {
        list.add((label, rel))
    }
}

/**
 * 把"给人看的相对路径"（`.lingqu/scan/x.json`）转成 `resolveLqPath` 要的 **裸 rel**（`scan/x.json`）。
 *
 * 坑：`resolveLqPath` 内部会自己补 `<工程>/.lingqu/`，rel 里再带一层 `.lingqu/` 就会拼出
 * `<工程>/.lingqu/.lingqu/scan/x.json` → 永远 `exists()==false`，于是"有落档"被判成"没跑过"。
 * 实测（0.39.24）：报告结论因此写成「可用率 尚未验证」，而同一份报告正文写着 100%。
 */
public func bareLqRel(rel: String): String {
    let p = rel.trimAscii()
    let prefix = ".lingqu/"
    if (p.startsWith(prefix)) {
        return p[prefix.size..p.size]
    }
    let prefix2 = ".lingqu" + cjhPathSep()
    if (p.startsWith(prefix2)) {
        return p[prefix2.size..p.size]
    }
    return p
}

/**
 * 工程内相对路径落档，**读的时候必须按工程解析**（`resolveLqPath`），**显示的时候用相对路径**。
 *
 * 0.39.24 实测踩到：`collectReportFacts` 全程用 `.lingqu/xxx/<工程>.json` 这种**相对 CWD** 的路径读，
 * 于是从仓目录跑 `report --path <别的工程>` 时读到的是**本仓自己的旧档**（或什么都读不到）——
 * 报告头部因此写「核心功能可用率 尚未验证」，而同一份报告正文的任务板摘要却写着 100%，
 * **一份文档里两个数**。与 §4-75① 同源，`verify_feed` 当时修了、这里漏了。
 */
func lqArtifact(projPath: String, rel: String): String {
    return resolveLqPath(projPath, bareLqRel(rel))
}

/**
 * 汇总报告事实：8 步状态（走 `t2h:resume` 的同一套观测）+ 可用率清单 + 证据 + 产物 + A3 计数。
 */
public func collectReportFacts(projName: String, projPath: String, now: String): MigrationFacts {
    let facts = MigrationFacts()
    facts.project = projName
    facts.path = projPath
    facts.generatedAt = now
    // 显示用：统一写成"工程内相对路径"，读用 lqArtifact 解析成真实路径
    let relVerify = ".lingqu/verify/${projName}.json"

    // ① 8 步状态机：与断点板同源（同一份观测，报告不会与 ④ 屏各说一套）
    let board = collectTaskBoard(projName, projPath, now)
    let pr = taskProgress(board)
    facts.stepDone = pr.done
    facts.stepTotal = pr.total
    facts.stepPercent = pr.percent
    facts.nextStep = firstUnfinished(board)
    for (s in board.steps) {
        facts.stepIds.add(s.id)
        facts.stepTitles.add(s.title)
        facts.stepStatuses.add(s.status)
        facts.stepNotes.add(s.note)
    }

    // ② 可用率与清单
    match (readJsonOrNone(lqArtifact(projPath, relVerify))) {
        case Some(root) =>
            let stats = objFieldOf(root, "stats")
            facts.verifyTotal = intFieldOf(stats, "total", 0)
            facts.verifyPass = intFieldOf(stats, "pass", 0)
            facts.verifyFail = intFieldOf(stats, "fail", 0)
            facts.verifyLimit = intFieldOf(stats, "limit", 0)
            facts.verifyUnknown = intFieldOf(stats, "unknown", 0)
            facts.verifyRate = intFieldOf(stats, "ratePercent", -1)
            facts.limitItems = collectVerdictTitles(root, "limit")
            facts.unknownItems = collectVerdictTitles(root, "unknown")
            facts.failedItems = collectVerdictTitles(root, "fail")
            facts.bundleName = jsonStrField(root, "bundleName")
        case None => ()
    }

    // ③ T5-4 签名两态：debug 态必须进"没做什么"与"需要你做什么"（上架前强提醒）
    // ③ T5-4 签名两态：debug 态必须进"没做什么"与"需要你做什么"（上架前强提醒）
    match (readJsonOrNone(lqArtifact(projPath, ".lingqu/sign/${projName}.json"))) {
        case Some(root) =>
            let modeObj = objFieldOf(root, "mode")
            facts.signMode = jsonStrField(modeObj, "mode")
            facts.signReminder = jsonStrField(modeObj, "reminder")
            facts.signReleaseNextStep = jsonStrField(modeObj, "releaseNextStep")
            facts.signReleaseReady = boolFieldOf(modeObj, "releaseReady")
            if (facts.signMode == SIGN_MODE_DEBUG) {
                facts.artifacts.add(("签名体检（debug 态）", ".lingqu/sign/${projName}.json"))
            }
        case None => ()
    }

    // ④ A3 人工介入：只有"采纳"才算一次介入；没有记录就如实说明
    let decisions = collectDecisionValues(projName, projPath)
    let hc = countHumanDecisions(decisions)
    facts.humanAccepted = hc.accepted
    facts.humanIgnored = hc.ignored
    if (decisions.size == 0) {
        facts.decisionsNote = "本工程没有人工决策记录（A3 口径：guide 项被采纳才计一次介入）"
    } else {
        facts.decisionsNote = "人工决策：采纳 ${hc.accepted} 条 / 忽略 ${hc.ignored} 条（落 .lingqu/port/${projName}/decisions.json）"
    }

    // ⑤ 证据与产物（**存在性按工程解析，附录里写相对路径**）
    facts.evidenceCount = countEvidenceFiles(projName, projPath)
    facts.artifacts.add(("断点板（8 步状态）", resolveLqPath(projPath, "tasks.json")))
    addArtifactIfExists(facts.artifacts, "扫描画像", ".lingqu/scan/${projName}.json", projPath)
    addArtifactIfExists(facts.artifacts, "依赖矩阵", ".lingqu/deps/${projName}.json", projPath)
    addArtifactIfExists(facts.artifacts, "人工决策", ".lingqu/port/${projName}/decisions.json", projPath)
    addArtifactIfExists(facts.artifacts, "编译落档", ".lingqu/build/${projName}.json", projPath)
    addArtifactIfExists(facts.artifacts, "HAP 装配", ".lingqu/hap/${projName}.json", projPath)
    addArtifactIfExists(facts.artifacts, "签名体检", ".lingqu/sign/${projName}.json", projPath)
    addArtifactIfExists(facts.artifacts, "真机部署", ".lingqu/deploy/${projName}.json", projPath)
    addArtifactIfExists(facts.artifacts, "验证清单", relVerify, projPath)
    addArtifactIfExists(facts.artifacts, "三段式报告（MD）", ".lingqu/verify/${projName}.md", projPath)
    addArtifactIfExists(facts.artifacts, "三段式报告（HTML）", ".lingqu/verify/${projName}.html", projPath)
    if (facts.evidenceCount > 0) {
        facts.artifacts.add(("真机证据目录", ".lingqu/evidence/"))
    }
    return facts
}
