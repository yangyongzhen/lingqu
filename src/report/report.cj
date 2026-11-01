package lingqu.report

import std.collection.*

/*
 * T6-4 迁移报告的纯函数层（收数在 `src/report_feed.cj`，命令本体在 `main.cj` 的 `ReportCommand`）。
 *
 * 报告只有一个形状：**三段式**——做了什么 / 没做什么 / 需要你做什么。
 * 三段都是**从落档推导**的，不是模板文案：
 *
 *   · 做了什么  ← 8 步里真跑过且判定通过的步骤（每步带它自己的落档摘要）
 *   · 没做什么  ← 没跑的步骤 + 没过的步骤 + 平台限制项（**平台限制不算失败**，单列）
 *                 + 未采集证据的项（未验证 ≠ 通过）+ 人工跳过
 *   · 需要你做什么 ← 由上面两类衍生的**可执行动作**，每条都对应界面上的一个按钮
 *
 * 设计纪律（与 verify / task 一致）：
 *   ① 没数据就说没数据，**不编造**（"0 份证据"永远比编个"13 份"诚实）；
 *   ② 平台限制与失败分列，混在一起会让人以为鸿蒙缺能力是工具的错；
 *   ③ 报告里每个数字都要能追到一份落档（见附录的产物清单）。
 */

// ============================================================
// 风险分级（0.39.47）
// ============================================================
//
// 需求原文（`docs/需求.md`）要的是"输出结构化迁移报告，**支持风险分级**与断点续迁"，
// 但这份报告此前只有三段式。三段式回答"做了什么 / 没做什么 / 需要你做什么"，
// 回答不了用户最关心的那句：**"既然移植成功了，还有哪些潜在问题？"**
//
// 迁移成功（可用率 100%）≠ 没有风险：debug 签名上不了架、平台限制项、未验证项、
// 人工介入未复核、前端指纹可能与 `.so` 不同步——这些在落档里都有据可查，只是没人归类。
//
// 纪律（与三段式一致）：
//   ① 每条风险都必须能指到一份落档；没有落档的步骤只写"无法评估"，**不当成"没问题"**；
//   ② 级别只由事实推出来（高/中/低三档：`high` / `mid` / `low`），不写死；
//   ③ "总体"是明细推出来的最高一档，不单独存一份——免得两处说法不一致。

/** 风险级别字面量：落档、界面、报告共用一套，别各写一套字符串 */
public let RISK_HIGH: String = "high"
public let RISK_MID: String = "mid"
public let RISK_LOW: String = "low"

/** 级别 → 中文标签（界面的胶囊、报告的表头都用它） */
public func riskLevelLabel(level: String): String {
    if (level == RISK_HIGH) {
        return "高"
    }
    if (level == RISK_MID) {
        return "中"
    }
    return "低"
}

/** 一条风险：项 / 级别 / 影响面 / 处置（四列，与效果图一致） */
public class RiskItem {
    public var title: String = ""
    public var level: String = RISK_LOW
    public var impact: String = ""
    public var action: String = ""

    public init(title: String, level: String, impact: String, action: String) {
        this.title = title
        this.level = level
        this.impact = impact
        this.action = action
    }
}

/** 风险分级结果：逐条明细 + 各级计数（总体级别由明细推出来） */
public class ReportRisk {
    public var items: ArrayList<RiskItem> = ArrayList<RiskItem>()

    public func add(item: RiskItem): Unit {
        this.items.add(item)
    }

    public func countOf(level: String): Int64 {
        var n: Int64 = 0
        for (it in this.items) {
            if (it.level == level) {
                n += 1
            }
        }
        return n
    }

    /** 总体级别 = 最高的一档（高 > 中 > 低）；一条都没有也是"低"，但摘要会说明"无法评估" */
    public func overallLevel(): String {
        if (this.countOf(RISK_HIGH) > 0) {
            return RISK_HIGH
        }
        if (this.countOf(RISK_MID) > 0) {
            return RISK_MID
        }
        return RISK_LOW
    }
}

/** 一句话总体：`总体：中（高 0 / 中 3 / 低 1，共 4 条）`；没有可判定项时把话说明白 */
public func riskSummaryLine(risk: ReportRisk): String {
    let hi = risk.countOf(RISK_HIGH)
    let mid = risk.countOf(RISK_MID)
    let lo = risk.countOf(RISK_LOW)
    let n = risk.items.size
    if (n == 0) {
        return "总体：低（落档里没有可判定的风险项；**没跑过的步骤无法评估**——别把「没报风险」当成「没问题」）"
    }
    return "总体：${riskLevelLabel(risk.overallLevel())}（高 ${hi} / 中 ${mid} / 低 ${lo}，共 ${n} 条）"
}

/** 把若干标题拼成一句（最多 3 条，再多写"等 N 项"）：风险表的一格塞不下长清单 */
func briefTitles(titles: ArrayList<String>): String {
    if (titles.size == 0) {
        return ""
    }
    var text = ""
    var i: Int64 = 0
    while (i < titles.size && i < 3) {
        if (i > 0) {
            text += "、"
        }
        text += titles[i]
        i += 1
    }
    if (titles.size > 3) {
        text += " 等 ${titles.size} 项"
    }
    return text
}

/** 落档判定覆盖了哪些步骤：这些步骤有专属风险规则，别再重复报一条"没过" */
func riskCoveredStep(id: String, facts: MigrationFacts): Bool {
    if (id == "build") {
        return facts.buildRan
    }
    if (id == "hap") {
        return facts.hapRan
    }
    if (id == "deploy") {
        return facts.deployRan
    }
    if (id == "verify") {
        return facts.verifyRate >= 0
    }
    if (id == "sign") {
        return facts.signMode != ""
    }
    return false
}

/**
 * 由落档事实推风险清单（**纯函数**：同样的落档永远得到同样的风险表）。
 *
 * 顺序有意为之：先"能不能装/能不能跑"（高），再"能不能上架/能不能复核"（中），最后"要不要看一眼"（低）。
 */
public func assessRisks(facts: MigrationFacts): ReportRisk {
    let risk = ReportRisk()

    // ① 交叉编译：落档在才评（没跑过 ≠ 没过）
    if (facts.buildRan) {
        if (!facts.buildOk) {
            risk.add(RiskItem("交叉编译没过（exit=${facts.buildExit}）", RISK_HIGH,
                "没有 arm64 产物，装配与部署都无从谈起", stepActionHint("build")))
        } else {
            let drift = facts.assetStale + facts.assetMissing
            if (drift > 0) {
                risk.add(RiskItem("前端资源与 .so 不同步（stale=${facts.assetStale} / missing=${facts.assetMissing}）",
                    RISK_HIGH, "装上去可能是旧界面，严重时白屏",
                    "重编 .so 后再装配 HAP（前端指纹闸会拦）"))
            }
            if (facts.buildWarn > 0) {
                risk.add(RiskItem("交叉编译有 ${facts.buildWarn} 条警告", RISK_LOW,
                    "不阻塞产物，但可能藏着平台差异", "看 .lingqu/build 落档的 diags 明细"))
            }
        }
    }

    // ② HAP 装配：装不出来 / 没签名 都是"机器上跑不起来"
    if (facts.hapRan) {
        if (!facts.hapBuilt) {
            risk.add(RiskItem("HAP 没装配出来", RISK_HIGH,
                "没有可安装的产物，真机验证没有前提", stepActionHint("hap")))
        } else {
            if (!facts.hapSigned) {
                risk.add(RiskItem("HAP 没有签名", RISK_HIGH,
                    "设备会拒绝安装（hdc 9568322 / install sign info inconsistent）",
                    "跑「签名体检」；新包名用 sign --auto 走 AGC 签发"))
            }
            if (facts.hapRawfile > 0) {
                risk.add(RiskItem("HAP 里有 ${facts.hapRawfile} 个前端死资源（rawfile）", RISK_LOW,
                    "包体变大，且可能读到旧前端", "清空 rawfile 目录后重新装配 HAP"))
            }
        }
    }

    // ③ 真机部署：装不上 / 起不来 / 起来了但有崩溃痕迹
    if (facts.deployRan) {
        if (!facts.deployInstalled) {
            risk.add(RiskItem("真机安装失败", RISK_HIGH,
                "装不上就没法验证；常见根因是签名不一致或设备锁屏",
                "看 .lingqu/deploy 落档的 install 详情（failCode）"))
        } else if (!facts.deployStarted) {
            risk.add(RiskItem("真机启动失败", RISK_HIGH,
                "装上了但起不来，用户看不到界面", "看 hilog 首屏报错，并确认 ability 名与锁屏状态"))
        } else if (!facts.deployHilogHealthy) {
            risk.add(RiskItem("启动后 hilog 有异常痕迹", RISK_MID,
                "可能后台崩溃或界面白屏", "抓 .lingqu/evidence 里的 hilog 看首屏"))
        }
    }

    // ④ 功能清单三类：失败（高）> 未验证（中）> 平台限制（中，但不算失败）
    if (facts.failedItems.size > 0) {
        risk.add(RiskItem("${facts.failedItems.size} 项核心功能验证失败（${briefTitles(facts.failedItems)}）",
            RISK_HIGH, "这些功能在鸿蒙上不可用，可用率因此不达标",
            "处理完再采一次证据：⑥ 屏「采集证据并算可用率」"))
    } else if (facts.verifyFail > 0) {
        risk.add(RiskItem("${facts.verifyFail} 项核心功能验证失败", RISK_HIGH,
            "这些功能在鸿蒙上不可用，可用率因此不达标", "看 .lingqu/verify 落档的 items 明细"))
    }
    if (facts.unknownItems.size > 0) {
        risk.add(RiskItem("${facts.unknownItems.size} 项功能未验证（${briefTitles(facts.unknownItems)}）",
            RISK_MID, "没有证据就不算可用（未验证 ≠ 通过）",
            "补验证：采到证据后才会从「未验证」变成通过"))
    }
    if (facts.limitItems.size > 0) {
        risk.add(RiskItem("${facts.limitItems.size} 项功能受平台限制（${briefTitles(facts.limitItems)}）",
            RISK_MID, "这些能力在鸿蒙上降级或不可用（已登记，不算失败）",
            "确认产品上可接受；必要时改交互方案"))
    }

    // ⑤ 签名两态：debug 是"能装真机、不能上架"的态，属于典型"迁移成功但还有坑"
    if (facts.signMode == "debug" && !facts.signReleaseReady) {
        risk.add(RiskItem("签名是 debug 态", RISK_MID,
            "只能直装已注册设备，「不能上架」（AGC 不接受 debug 证书）",
            "出 release 前把 signingConfig 切到 release profile 并重装 HAP"))
    }

    // ⑥ 人工介入：A3 的验收口径是 ≤5 处，且有介入就意味着"这段是人工判断的"
    if (facts.humanAccepted > 0) {
        risk.add(RiskItem("有 ${facts.humanAccepted} 处人工介入", RISK_LOW,
            "这些是人工判断的改动，后续版本回归要复查",
            "验收口径：单应用 ≤5 处；复核 .lingqu/port/<工程>/decisions.json"))
    }

    // ⑦ 依赖：不可用 crate 数（已按矩阵给了替代方案，或这些能力没被实际用到）
    if (facts.depsRan && facts.depsUnavailable > 0) {
        risk.add(RiskItem("${facts.depsUnavailable} 个 crate 在 OHOS 不可用（共 ${facts.depsTotal} 个依赖）",
            RISK_LOW, "已按矩阵给替代方案，或这些能力没被实际用到",
            "看 .lingqu/deps 的兼容矩阵与替代建议"))
    }

    // ⑧ 步骤级兜底：有专属规则的步骤上面已评过，这里只补"没有落档判定"的没过与没跑
    let failedTitles = ArrayList<String>()
    let pendingTitles = ArrayList<String>()
    var i: Int64 = 0
    while (i < facts.stepIds.size) {
        let id = facts.stepIds[i]
        let title = if (i < facts.stepTitles.size) { facts.stepTitles[i] } else { id }
        let status = if (i < facts.stepStatuses.size) { facts.stepStatuses[i] } else { "pending" }
        let note = if (i < facts.stepNotes.size) { facts.stepNotes[i] } else { "" }
        if (status == "failed") {
            if (!riskCoveredStep(id, facts)) {
                failedTitles.add(if (note == "") { title } else { "${title}（${note}）" })
            }
        } else if (status != "done" && status != "skipped" && status != "running") {
            pendingTitles.add(title)
        }
        i += 1
    }
    if (failedTitles.size > 0) {
        risk.add(RiskItem("${failedTitles.size} 步没过：${briefTitles(failedTitles)}", RISK_HIGH,
            "这几步没有结论，报告里的产物不一定能装、能跑", "按「需要你做什么」逐条重跑"))
    }
    if (pendingTitles.size > 0) {
        risk.add(RiskItem("还有 ${pendingTitles.size} 步没跑：${briefTitles(pendingTitles)}", RISK_MID,
            "这几步没有落档，风险无法评估（不等于没问题）", "按序补跑，跑完重出报告"))
    }
    return risk
}

/** 三段式里的一段 */
public class ReportSection {
    public var key: String
    public var title: String
    public var lines: ArrayList<String> = ArrayList<String>()

    public init(key: String, title: String) {
        this.key = key
        this.title = title
    }
}

/** 报告成品：三段 + 结论 + 附录产物清单 */
public class ReportDoc {
    public var title: String = ""
    public var project: String = ""
    public var path: String = ""
    public var generatedAt: String = ""
    public var conclusion: String = ""
    public var sections: ArrayList<ReportSection> = ArrayList<ReportSection>()
    public var artifacts: ArrayList<(String, String)> = ArrayList<(String, String)>()
    // 风险分级（0.39.47）：独立于三段之外——三段说"做了什么/没做什么/要你做什么"，
    // 风险表说"虽然成功了，但还有哪些潜在问题"。两件事分开写，谁也不会被稀释。
    public var risk: ReportRisk = ReportRisk()

    public init(title: String, project: String) {
        this.title = title
        this.project = project
    }

    public func sectionOf(key: String): Option<ReportSection> {
        for (s in this.sections) {
            if (s.key == key) {
                return Some(s)
            }
        }
        return None
    }

    public func lineCount(key: String): Int64 {
        match (this.sectionOf(key)) {
            case Some(s) => return Int64(s.lines.size)
            case None => return 0
        }
    }

    public func linesOf(key: String): ArrayList<String> {
        match (this.sectionOf(key)) {
            case Some(s) => return s.lines
            case None => return ArrayList<String>()
        }
    }
}

/**
 * 写报告要的全部事实（**全部来自落档**，命令层的 `report_feed` 负责填）。
 *
 * 8 步用并行的数组表示（id / 标题 / 状态 / 摘要），顺序即执行顺序——
 * 与 `t2h:resume` 的 `TASK_STEPS` 一致，报告与断点板看到的永远是同一份状态。
 */
public class MigrationFacts {
    public var project: String = ""
    public var path: String = ""
    public var bundleName: String = ""
    public var generatedAt: String = ""
    // 8 步状态机（来自 .lingqu/tasks.json 的观测结果）
    public var stepIds: ArrayList<String> = ArrayList<String>()
    public var stepTitles: ArrayList<String> = ArrayList<String>()
    public var stepStatuses: ArrayList<String> = ArrayList<String>()
    public var stepNotes: ArrayList<String> = ArrayList<String>()
    public var stepDone: Int64 = 0
    public var stepTotal: Int64 = 0
    public var stepPercent: Int64 = 0
    public var nextStep: String = ""
    // 功能清单与可用率（来自 .lingqu/verify/<工程>.json）
    public var verifyTotal: Int64 = 0
    public var verifyPass: Int64 = 0
    public var verifyFail: Int64 = 0
    public var verifyLimit: Int64 = 0
    public var verifyUnknown: Int64 = 0
    public var verifyRate: Int64 = -1
    public var limitItems: ArrayList<String> = ArrayList<String>()
    public var unknownItems: ArrayList<String> = ArrayList<String>()
    public var failedItems: ArrayList<String> = ArrayList<String>()
    // 证据与产物
    public var evidenceCount: Int64 = 0
    public var artifacts: ArrayList<(String, String)> = ArrayList<(String, String)>()
    // T5-4 签名两态：当前签名态 + 上架前强提醒（debug 态必须出现在"没做什么/需要你做什么"）
    public var signMode: String = ""
    public var signReminder: String = ""
    public var signReleaseNextStep: String = ""
    public var signReleaseReady: Bool = false
    // A3：人工介入（guide 项被采纳才算一次，忽略也要留痕）
    public var humanAccepted: Int64 = 0
    public var humanIgnored: Int64 = 0
    public var decisionsNote: String = ""
    // 各步落档的判定事实（只给风险分级用；落档缺失时保持"没跑过"的默认值——没落档就不猜）
    public var buildRan: Bool = false
    public var buildOk: Bool = false
    public var buildExit: Int64 = -1
    public var buildWarn: Int64 = 0
    public var assetStale: Int64 = 0
    public var assetMissing: Int64 = 0
    public var hapRan: Bool = false
    public var hapBuilt: Bool = false
    public var hapSigned: Bool = false
    public var hapRawfile: Int64 = 0
    public var deployRan: Bool = false
    public var deployInstalled: Bool = false
    public var deployStarted: Bool = false
    public var deployHilogHealthy: Bool = true
    public var depsRan: Bool = false
    public var depsTotal: Int64 = 0
    public var depsUnavailable: Int64 = 0
    // 本地经验（0.39.55）：agent 自己记下来的踩坑条数 + 一句话摘要（空 = 一条都没有，不编）
    public var lessonCount: Int64 = 0
    public var lessonsLine: String = ""
}

/** 人工介入计数结果（A3 口径：accepted 才算一次介入） */
public class HumanCount {
    public var accepted: Int64 = 0
    public var ignored: Int64 = 0
}

/** 一步的"下一步动作"（界面上对应哪个按钮，报告里就写哪句，别让人猜） */
public func stepActionHint(stepId: String): String {
    if (stepId == "scan") {
        return "跑一次扫描（② 迁移画像「重新扫描」）"
    }
    if (stepId == "deps") {
        return "跑依赖评估（③ 依赖扫描「扫描 Cargo 依赖」）"
    }
    if (stepId == "port") {
        return "跑规则改造（④ 改造执行「预览改造」→「应用」）"
    }
    if (stepId == "build") {
        return "交叉编译（⑤ 构建打包「交叉编译（OHOS）」）；提示前端指纹不一致时先重编 .so"
    }
    if (stepId == "hap") {
        return "装配 HAP（⑤ 构建打包「装配 HAP」）"
    }
    if (stepId == "sign") {
        return "签名体检（⑤ 构建打包「签名体检」）；工程没配签名时先点「写回签名配置」"
    }
    if (stepId == "deploy") {
        return "真机部署（⑥ 真机验证「安装并启动」）"
    }
    if (stepId == "verify") {
        return "采证据算可用率（⑥ 真机验证「采集证据并算可用率」）"
    }
    return "重跑这一步"
}

/** 判定是否算"有结论"（done / skipped），与 `t2h:resume` 同一口径 */
public func reportStepSettled(status: String): Bool {
    return status == "done" || status == "skipped"
}

/** 「标题」+ 摘要的一段文字（摘要为空时只留标题，不留一个悬空的冒号） */
func titled(title: String, note: String): String {
    if (note == "") {
        return "「${title}」"
    }
    return "「${title}」：${note}"
}

/** 带判定词的步骤行：`「交叉编译」没过：<摘要>`。判定词在前，摘要跟在冒号后（读起来才顺） */
func verdictLine(title: String, verdict: String, note: String): String {
    if (note == "") {
        return "「${title}」${verdict}"
    }
    return "「${title}」${verdict}：${note}"
}

/**
 * 由事实生成三段式报告（**纯函数**：同样的落档永远得到同样的报告）。
 *
 * 段落顺序有意为之：做了什么 → 没做什么 → 需要你做什么。
 * 报告的第一读者是"接手的人"，不是写报告的人。
 */
public func buildReport(facts: MigrationFacts): ReportDoc {
    let doc = ReportDoc("${facts.project} 迁移报告", facts.project)
    doc.path = facts.path
    doc.generatedAt = facts.generatedAt

    let did = ReportSection("did", "做了什么")
    let undone = ReportSection("undone", "没做什么（已知限制与未验证）")
    let need = ReportSection("need", "需要你做什么")

    var i: Int64 = 0
    while (i < facts.stepIds.size) {
        let id = facts.stepIds[i]
        let title = if (i < facts.stepTitles.size) { facts.stepTitles[i] } else { id }
        let status = if (i < facts.stepStatuses.size) { facts.stepStatuses[i] } else { "pending" }
        let note = if (i < facts.stepNotes.size) { facts.stepNotes[i] } else { "" }
        if (status == "done") {
            did.lines.add(titled(title, note))
        } else if (status == "failed") {
            // 失败归"没做什么"，原因就在摘要里（断点板与报告用同一句摘要，不会各说一套）
            undone.lines.add(verdictLine(title, "没过", note))
        } else if (status == "skipped") {
            undone.lines.add(verdictLine(title, "按人工判断跳过", note))
        } else if (status != "running") {
            undone.lines.add(verdictLine(title, "还没跑", note))
        }
        i += 1
    }
    if (facts.evidenceCount > 0) {
        did.lines.add("采集到 ${facts.evidenceCount} 份真机证据（截图在 .lingqu/evidence/）")
    }
    // 0.39.55：agent 自己记的踩坑经验（`.lingqu/notes/`）——"这次学到了什么"也要进报告
    if (facts.lessonCount > 0 && facts.lessonsLine != "") {
        did.lines.add(facts.lessonsLine)
    }
    if (facts.verifyPass > 0) {
        let denom = facts.verifyTotal - facts.verifyLimit
        did.lines.add("功能清单通过 ${facts.verifyPass}/${denom} 项（平台限制已从分母剔除）")
    }
    if (did.lines.size == 0) {
        did.lines.add("还没有任何步骤跑出结果——先跑一次扫描")
    }

    // 平台限制 / 未验证 / 失败三类**分开写**：混成一句"未完成"会让人误判
    for (t in facts.limitItems) {
        undone.lines.add("平台限制（不算失败，已在清单登记）：${t}")
    }
    for (t in facts.unknownItems) {
        undone.lines.add("未验证（没有证据就不算通过）：${t}")
    }
    for (t in facts.failedItems) {
        undone.lines.add("验证失败：${t}")
    }
    if (facts.decisionsNote != "") {
        undone.lines.add(facts.decisionsNote)
    }
    // T5-4：debug 签名是"能装真机但绝不能上架"的态，必须出现在"没做什么"里——
    // 这是上架前最容易漏的一条（真机跑得好好的，提交审核却被拒）
    if (facts.signMode == "debug" && !facts.signReleaseReady) {
        undone.lines.add("签名是 debug 态：可直装真机，但**不能上架**（AGC 不接受 debug 证书）")
    }
    if (undone.lines.size == 0) {
        undone.lines.add("没有已知遗留——8 步都有结论，清单项全部通过或已登记平台限制")
    }

    // 需要你做什么：从上面两类推动作，每条都能落到界面上的一个按钮
    i = 0
    while (i < facts.stepIds.size) {
        let id = facts.stepIds[i]
        let title = if (i < facts.stepTitles.size) { facts.stepTitles[i] } else { id }
        let status = if (i < facts.stepStatuses.size) { facts.stepStatuses[i] } else { "pending" }
        if (status == "failed") {
            need.lines.add("「${title}」没过 → ${stepActionHint(id)}")
        } else if (!reportStepSettled(status) && status != "running") {
            need.lines.add("「${title}」还没跑 → ${stepActionHint(id)}")
        }
        i += 1
    }
    for (t in facts.unknownItems) {
        need.lines.add("补验证：${t}（采到证据才会从「未验证」变成通过）")
    }
    for (t in facts.failedItems) {
        need.lines.add("处理失败项：${t}")
    }
    if (facts.humanAccepted > 0) {
        need.lines.add("复核 ${facts.humanAccepted} 处人工介入的结论（验收 A3：单应用 ≤5 处）")
    }
    // 经验要有人过一眼：进技能库会改变 agent 的指令，不能自动写（0.39.55）
    if (facts.lessonCount > 0) {
        need.lines.add("复核 ${facts.lessonCount} 条本地经验（「lingqu-cli notes --action export --path .」），" +
            "确认后可整理进 skills/t2h-ohos-port 的 pitfalls")
    }
    // T5-4 上架前强提醒：原文照引（含"必须切回 release"那句），后面再给出具体下一步
    if (facts.signMode == "debug" && !facts.signReleaseReady) {
        if (facts.signReminder != "") {
            need.lines.add(facts.signReminder)
        }
        if (facts.signReleaseNextStep != "") {
            // 这句自己已经以「上架前：」开头（sign.cj 的措辞），别再叠一层前缀
            need.lines.add(facts.signReleaseNextStep)
        } else {
            need.lines.add("上架前：把 signingConfig 切到 release profile，重跑「装配 HAP」再提交审核")
        }
    }
    if (need.lines.size == 0) {
        need.lines.add("没有需要你处理的事项——报告可直接归档")
    }

    doc.sections.add(did)
    doc.sections.add(undone)
    doc.sections.add(need)
    doc.artifacts = facts.artifacts
    doc.risk = assessRisks(facts)
    doc.conclusion = reportConclusion(facts)
    return doc
}

/** 一句话结论：8 步进度 + 可用率 + 人工介入数（A3/A4 两个验收指标都在这一句里） */
public func reportConclusion(facts: MigrationFacts): String {
    let rateText = if (facts.verifyRate >= 0) { "${facts.verifyRate}%" } else { "尚未验证" }
    return "${facts.project}：8 步完成 ${facts.stepDone}/${facts.stepTotal}" +
        "（${facts.stepPercent}%），核心功能可用率 ${rateText}，" +
        "${facts.humanAccepted} 处人工介入"
}

/**
 * 字符级 HTML 转义：按字节走，**只替换 5 个危险 ASCII 字符，中文原样保留**。
 *
 * 别用"按字节拼数字再回头 fromUtf8"那种写法：中文是多字节，逐字节转字符串会被拆碎
 * （这正是 0.12.0 踩过的坑，见 AGENTS §4-41 的同类教训）。
 */
public func escapeHtmlText(s: String): String {
    let out = ArrayList<Byte>()
    for (b in s.toArray()) {
        if (b == 60) {
            appendAscii(out, "&lt;")
        } else if (b == 62) {
            appendAscii(out, "&gt;")
        } else if (b == 38) {
            appendAscii(out, "&amp;")
        } else if (b == 34) {
            appendAscii(out, "&quot;")
        } else {
            out.add(b)
        }
    }
    return String.fromUtf8(out.toArray())
}

/** 把一段 ASCII 文本的字节追加到缓冲区（转义实体都是纯 ASCII） */
func appendAscii(out: ArrayList<Byte>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

/** Markdown 表格的一个单元：竖线与换行会把表格撑坏，换成安全字符 */
func mdCell(s: String): String {
    let one = s.replace("\r", " ").replace("\n", " ")
    return one.replace("|", "／")
}

/** Markdown 渲染（risk + 三段 + 附录）。刻意不用表格：产物路径长短不一会撑爆表格布局 */
public func renderReportMarkdown(doc: ReportDoc): String {
    var text = "# ${doc.title}\n\n"
    text += "- 工程：`${doc.path}`\n"
    if (doc.generatedAt != "") {
        text += "- 生成时间：${doc.generatedAt}\n"
    }
    text += "- 结论：**${doc.conclusion}**\n\n"
    // 风险分级放在结论之后、三段之前：用户第一眼要问的正是"成功了吗？那还剩什么坑？"
    text += "## 风险分级\n\n"
    text += "- **${riskSummaryLine(doc.risk)}**\n\n"
    if (doc.risk.items.size > 0) {
        text += "| 项 | 级别 | 影响面 | 处置 |\n|---|---|---|---|\n"
        for (it in doc.risk.items) {
            text += "| ${mdCell(it.title)} | ${riskLevelLabel(it.level)} | ${mdCell(it.impact)} | ${mdCell(it.action)} |\n"
        }
        text += "\n"
    }
    text += "> 口径：级别由落档证据判定（编译/装配/部署判定、清单三类、签名态、前端指纹、人工介入）；\n"
    text += "> 没有落档的步骤只写「无法评估」，不会被当成「没问题」。\n\n"
    for (sec in doc.sections) {
        text += "## ${sec.title}\n\n"
        for (line in sec.lines) {
            text += "- ${line}\n"
        }
        text += "\n"
    }
    text += "## 附录：产物与落档（每个数字都能追到这里）\n\n"
    for (entry in doc.artifacts) {
        text += "- ${entry[0]}：`${entry[1]}`\n"
    }
    text += "\n> 本报告由灵渠迁移台自动生成；口径：平台限制不计入可用率分母，未验证 ≠ 通过。\n"
    return text
}

/** HTML 渲染（自包含单文件，不引外部资源，双击即可看） */
public func renderReportHtml(doc: ReportDoc): String {
    var text = "<!DOCTYPE html>\n<html lang=\"zh-CN\"><head><meta charset=\"utf-8\">\n"
    text += "<title>${escapeHtmlText(doc.title)}</title>\n"
    text += "<style>body{font:14px/1.7 -apple-system,'Segoe UI','Microsoft YaHei',sans-serif;" +
        "max-width:860px;margin:32px auto;padding:0 18px;color:#1d2330}" +
        "h1{font-size:22px}h2{font-size:16px;margin-top:26px;border-left:3px solid #6c8cff;padding-left:9px}" +
        "li{margin:5px 0}code{background:#f3f5fa;padding:1px 5px;border-radius:4px;font-size:12.5px}" +
        ".concl{background:#f6f8fd;border:1px solid #e2e8f5;border-radius:8px;padding:10px 13px}" +
        ".risk{width:100%;border-collapse:collapse;font-size:12.5px;margin:4px 0 2px}" +
        ".risk th,.risk td{border-bottom:1px solid #e6eaf3;padding:5px 7px;text-align:left;vertical-align:top}" +
        ".risk th{color:#6b7488;font-size:11.5px;font-weight:600}" +
        ".lv{display:inline-block;padding:1px 7px;border-radius:9px;font-size:11px;border:1px solid}" +
        ".lv-high{color:#d64545;border-color:#f0c2c2;background:#fdf1f1}" +
        ".lv-mid{color:#b26a00;border-color:#f3dcae;background:#fdf7e9}" +
        ".lv-low{color:#2f7a4f;border-color:#c6e7d3;background:#f1faf4}" +
        ".muted{color:#6b7488}" +
        ".foot{margin-top:22px;color:#6b7488;font-size:12px}</style></head><body>\n"
    text += "<h1>${escapeHtmlText(doc.title)}</h1>\n"
    text += "<p>工程：<code>${escapeHtmlText(doc.path)}</code>"
    if (doc.generatedAt != "") {
        text += "　生成时间：${escapeHtmlText(doc.generatedAt)}"
    }
    text += "</p>\n<p class=\"concl\">${escapeHtmlText(doc.conclusion)}</p>\n"
    // 风险分级（0.39.47）：紧跟结论——"成功了，但还剩什么坑"是用户第一眼要找的东西
    text += "<h2>风险分级</h2>\n<p class=\"concl\">${escapeHtmlText(riskSummaryLine(doc.risk))}</p>\n"
    if (doc.risk.items.size > 0) {
        text += "<table class=\"risk\"><thead><tr><th>项</th><th>级别</th><th>影响面</th><th>处置</th></tr></thead><tbody>\n"
        for (it in doc.risk.items) {
            text += "<tr><td>${escapeHtmlText(it.title)}</td>"
            text += "<td><span class=\"lv lv-${it.level}\">${escapeHtmlText(riskLevelLabel(it.level))}</span></td>"
            text += "<td>${escapeHtmlText(it.impact)}</td>"
            text += "<td class=\"muted\">${escapeHtmlText(it.action)}</td></tr>\n"
        }
        text += "</tbody></table>\n"
    }
    for (sec in doc.sections) {
        text += "<h2>${escapeHtmlText(sec.title)}</h2>\n<ul>\n"
        for (line in sec.lines) {
            text += "<li>${escapeHtmlText(line)}</li>\n"
        }
        text += "</ul>\n"
    }
    text += "<h2>附录：产物与落档</h2>\n<ul>\n"
    for (entry in doc.artifacts) {
        text += "<li>${escapeHtmlText(entry[0])}：<code>${escapeHtmlText(entry[1])}</code></li>\n"
    }
    text += "</ul>\n<p class=\"foot\">本报告由灵渠迁移台自动生成；口径：平台限制不计入可用率分母，未验证 ≠ 通过。</p>\n"
    text += "</body></html>\n"
    return text
}

/**
 * 人工介入计数（A3 口径）：`decisions.json` 的 items 里 `accepted` 算一次介入，
 * `ignored` 只留痕（"不需要改"也是人工判断，但它不是一次介入）。
 */
public func countHumanDecisions(decisions: ArrayList<String>): HumanCount {
    let hc = HumanCount()
    for (d in decisions) {
        let v = d.trimAscii()
        if (v == "accepted") {
            hc.accepted += 1
        } else if (v == "ignored") {
            hc.ignored += 1
        }
    }
    return hc
}

/** 报告文件名 base（三种格式共用同一个 base，导出目录里一眼能对上） */
public func reportFileBase(project: String): String {
    if (project.size == 0) {
        return "unknown"
    }
    return project
}
