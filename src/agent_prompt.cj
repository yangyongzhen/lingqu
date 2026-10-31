package lingqu

import std.collection.*
import stdx.encoding.json.*

/*
 * G1+G2「失败自动诊断」的纯函数层（0.36.0，AI 一体化第 5~6 步）。
 *
 * 为什么需要它：0.35.0 之前 agent 只是"人叫才动"——scan/build/hap 的落档就躺在盘上，
 * 人得自己复述一遍去问 AI，等于这条 AI 链路只当聊天窗用。这一层把**失败现场**变成一段
 * 可以直接发出去的提问正文：
 *
 *   现场 = 工程目录 + 观测结论（来自落档）+ 落档正文（截断）+ 日志尾部
 *   指令 = 根因一句话 → 下一步能不能用 lingqu-cli 跑 → 要人定的取舍写成决策块
 *
 * 纪律（与 §1 门禁同源）：
 *   · 数字全部来自落档；读不到就写"落档不存在"，**不猜**
 *   · 提问里必须带该步的判据（`stepAskCaveat`）——否则模型拿通用经验套鸿蒙移植，
 *     会把"debug 态装不上真机"这种正常状态当成 bug 去修
 *   · 这一层是纯函数：不读盘、不跑进程、不联网（读文件落在命令层 `t2h:ai_brief`）
 */

/** 日志尾部默认行数（够看出一次 hvigor/cargo 的失败上下文，又不至于把上下文撑爆） */
public let ASK_LOG_TAIL_LINES: Int64 = 40

/** 落档正文默认截断字数（落档是结构化 JSON，前半段就有判定字段） */
public let ASK_CLIP_CHARS: Int64 = 3000

/**
 * 一步的**日志**落档路径（`.lingqu/<步骤>/<工程>.log`）。
 *
 * 与 `taskArtifactPath`（JSON 落档）配对：scan/deps 只落 json，port 落的是备份目录 +
 * decisions.json，这三步没有整篇日志——返回空串，调用方据此如实写"没有日志"。
 */
public func taskStepLogPath(projName: String, stepId: String): String {
    if (projName.size == 0) {
        return ""
    }
    if (taskStepIndex(stepId) < 0) {
        return ""
    }
    if (stepId == "scan" || stepId == "deps" || stepId == "port") {
        return ""
    }
    return ".lingqu/${stepId}/${projName}.log"
}

/** 取文本最后 [maxLines] 行（`\r\n` 归一；不足则原样回；空文本回空串） */
public func tailLinesOf(text: String, maxLines: Int64): String {
    if (maxLines <= 0 || text.size == 0) {
        return ""
    }
    let parts = text.replace("\r\n", "\n").split("\n", -1)
    let n = parts.size
    let start = if (n > maxLines) { n - maxLines } else { 0 }
    var out = ""
    for (i in start..n) {
        if (out.size > 0) {
            out += "\n"
        }
        out += parts[i]
    }
    return out
}

/**
 * 按**字符**截断到 [maxChars]（不是按字节）。
 *
 * UTF-8 的续字节是 0x80..0xBF，只有"字符首字节"（<0x80 或 >=0xC0）才计数——
 * 这样切点永远落在字符边界上，不会把中文/emoji 切成半个（切坏了 `String.fromUtf8` 会丢字）。
 */
public func clipCharsOf(text: String, maxChars: Int64): String {
    if (maxChars <= 0) {
        return ""
    }
    let bytes = text.toArray()
    var count: Int64 = 0
    var i: Int64 = 0
    while (i < bytes.size) {
        let b = bytes[i]
        if (b < 128 || b >= 192) {
            if (count == maxChars) {
                return String.fromUtf8(bytes[0..i])
            }
            count += 1
        }
        i += 1
    }
    return text
}

/**
 * 哪些步骤的失败值得自动问 AI（纯判据）。
 *
 * `scan` 不进来：它失败的典型原因是"路径填错/目录不存在"，这种错 AI 看落档看不出来，
 * 界面上直接说"路径不对"更快。其余七步都有可观测的失败现场。
 */
public func autoAskStepAllowed(stepId: String): Bool {
    if (taskStepIndex(stepId) < 0) {
        return false
    }
    return stepId != "scan"
}

/**
 * 该步的判据提醒（拼进提问里，防止模型按"通用 Tauri 经验"乱下结论）。
 *
 * 内容都是本仓踩出来的口径（见 AGENTS §4 与 verify 判据），不是泛泛的建议。
 */
public func stepAskCaveat(stepId: String): String {
    if (stepId == "deps") {
        return "依赖矩阵里「不可用」才是阻塞；「需 patch」是可修的，别把两者混着说。"
    }
    if (stepId == "port") {
        return "规则改造只改能在仓颉/鸿蒙侧等价实现的部分；改不动的要留人工决策，不要编造改写。"
    }
    if (stepId == "build") {
        return "判据是 exitCode=0 **且** gates.passed；build-script/链接类失败只写在 stderr，别只看 JSONL 里的诊断条数。"
    }
    if (stepId == "hap") {
        return "判据是 built 且 gates.passed；HAP 存在 ≠ 能装。白屏先查 HAP 里有没有应用自己的 lib<模块名>.so，" +
            "以及 .so 内嵌前端资源与 dist/ 是否对得上（前端指纹过期时界面照起但内容是旧的）。"
    }
    if (stepId == "sign") {
        return "签名有两态：debug 态只能直装、**装不上真机是设计使然**（profile 不含 device-ids），" +
            "release 态才谈上架。别建议去「修」debug 态装不上。"
    }
    if (stepId == "deploy") {
        return "hdc 失败时退出码仍是 0，成败只能按输出文本判（install bundle successfully / start ability successfully）。"
    }
    if (stepId == "verify") {
        return "存在 ≠ 成功；平台限制项不计入分母，unknown 进分母但不计通过——别把 unknown 当 0 分。"
    }
    return ""
}

/**
 * 一次自动诊断的输入（全部字段都由命令层从**盘上的落档**填，不从内存里的进度条取）。
 *
 * 用无参 init + 赋值：字段会陆续补齐，长参数列表反而容易漏。
 */
public class StepBrief {
    public var project: String = ""
    public var projectDir: String = ""
    public var step: String = ""
    public var stepTitle: String = ""
    public var note: String = ""
    public var artifact: String = ""
    public var artifactExists: Bool = false
    public var artifactClip: String = ""
    public var logPath: String = ""
    public var logTail: String = ""
    public var tailLines: Int64 = ASK_LOG_TAIL_LINES

    public init() {}
}

/** 字段兜底：空串换成一句人话占位（提问里不能出现"工程目录："这种空行，模型会当没填） */
func briefOr(value: String, fallback: String): String {
    if (value.trimAscii().size == 0) {
        return fallback
    }
    return value
}

/**
 * 把失败现场拼成一段提问正文（纯函数）。
 *
 * 四条指令是有意写死的顺序：先要根因（防止模型上来就列 10 条建议），再要可执行动作，
 * 再要"要人定的取舍"，最后明确**允许说不知道**——不写这条，模型会给一堆看起来很对、
 * 实际没法验证的修复步骤（这是 0.36.0 之前人工问答里最常出现的浪费）。
 */
public func buildAutoAskPrompt(b: StepBrief): String {
    let dir = briefOr(b.projectDir, "（未提供——见工程名）")
    let note = briefOr(b.note, "落档里没有可用的判定字段")
    let art = briefOr(b.artifact, "（该步骤没有 JSON 落档路径）")
    let artState = if (b.artifactExists) { "存在" } else { "不存在" }
    let logP = briefOr(b.logPath, "（该步骤没有日志落档）")
    let logState = if (b.logTail.trimAscii().size > 0) {
        "附最后 ${b.tailLines} 行"
    } else {
        "没找到内容"
    }
    var p = "【灵渠 · 自动诊断】工程 ${briefOr(b.project, "?")} 的「${b.stepTitle}」这一步没过。\n\n"
    p += "## 现场（灵渠从落档读出来的，未经你加工）\n"
    p += "- 工程目录：${dir}\n"
    p += "- 观测结论：${note}\n"
    p += "- 落档：${art}（${artState}）\n"
    p += "- 日志：${logP}（${logState}）\n"
    let caveat = stepAskCaveat(b.step)
    if (caveat.size > 0) {
        p += "- 本步判据：${caveat}\n"
    }
    if (b.artifactClip.trimAscii().size > 0) {
        p += "\n## 落档正文（超过 ${ASK_CLIP_CHARS} 字已截断）\n```json\n${b.artifactClip}\n```\n"
    }
    if (b.logTail.trimAscii().size > 0) {
        p += "\n## 日志尾部（最后 ${b.tailLines} 行）\n```text\n${b.logTail}\n```\n"
    }
    p += "\n## 请你按这个顺序回答（不要反问，不要复述上面的内容）\n"
    p += "1. **根因**：一句话，必须引用上面具体某一行作为依据；\n"
    p += "2. **下一步**：能直接跑的写成单独一行 `lingqu-cli <命令> --path ${briefOr(b.projectDir, "<工程目录>")}`；" +
        "只读命令界面会自动执行，会改工程或动真机的也照写，但要注明在第几屏点（界面会拦下来等人点）；\n"
    p += "3. **要人定的取舍**（比如某依赖要不要 patch、签名走 debug 还是 release）：写成 `lingqu-decision` 代码块，" +
        "块里一行 JSON：`{\"rule\":\"一句话决策点\",\"decision\":\"accepted|ignored\",\"why\":\"为什么\"}`，" +
        "界面会渲染成确认卡，人点一下才落进 decisions.json；\n"
    p += "4. 判断不了就写「需要 <具体哪份证据>」，**不要编造修复步骤**；如果是平台限制或环境问题，" +
        "直接说\"不用改码\"并说明依据。\n"
    return p
}

/**
 * 从 AI 回复里抽 `lingqu-decision` 代码块（G4 决策回写，纯函数）。
 *
 * 为什么用围栏代码块而不是普通行：模型回复里天天出现 `accepted/ignored` 这些词，
 * 只按"看起来像"去抓一定会误伤；围栏是模型自己就会产的格式，判据干净。
 *
 * 容忍度（都有单测）：
 *   · 块里有多余空白/换行 → 照抓
 *   · JSON 坏 / 缺 rule / decision 不在 accepted|ignored → **跳过这一块**，不算整体失败
 *   · 同一个 rule 出现多次 → 后者覆盖前者（与 `t2h:decisions record` 的覆盖语义一致）
 */
public class DecisionProposal {
    public var rule: String = ""
    public var decision: String = ""
    public var why: String = ""

    public init(rule: String, decision: String, why: String) {
        this.rule = rule
        this.decision = decision
        this.why = why
    }
}

/** 决策块的围栏标记（与 SKILL.md、AGENTS.md 受管区块里写的必须一致） */
public let DECISION_FENCE: String = "lingqu-decision"

/**
 * 解析回复正文里的决策块；返回**去重后**的提案（同 rule 取最后一次）。
 *
 * 不用 JSON 解析器扫全文（回复里有大量非 JSON 花括号），而是先按围栏切段，再逐段当 JSON 读。
 */
public func parseDecisionBlocks(text: String): Array<DecisionProposal> {
    var out = ArrayList<DecisionProposal>()
    if (text.trimAscii().size == 0) {
        return out.toArray()
    }
    let lines = text.replace("\r\n", "\n").split("\n", -1)
    var i: Int64 = 0
    while (i < lines.size) {
        let t = lines[i].trimAscii()
        if (t.startsWith("```" + DECISION_FENCE)) {
            // 收集到下一个 ``` 为止（没有收尾围栏就吃到末尾——模型偶尔会漏写收尾）
            let buf = ArrayList<String>()
            var j = i + 1
            while (j < lines.size) {
                if (lines[j].trimAscii().startsWith("```")) {
                    break
                }
                buf.add(lines[j])
                j += 1
            }
            let body = joinLines(buf)
            match (decisionProposalOf(body)) {
                case Some(p) =>
                    // 同 rule 覆盖：先删旧的再追加，保证"最后一次说法"生效
                    var kept = ArrayList<DecisionProposal>()
                    for (old in out) {
                        if (old.rule != p.rule) {
                            kept.add(old)
                        }
                    }
                    kept.add(p)
                    out = kept
                case None => ()
            }
            i = j + 1
            continue
        }
        i += 1
    }
    return out.toArray()
}

/** 按 `\n` 拼行（不用标准库的 join：参数命名与重载各版本不一致，自己拼最稳） */
func joinLines(lines: ArrayList<String>): String {
    var out = ""
    var first = true
    for (l in lines) {
        if (!first) {
            out += "\n"
        }
        out += l
        first = false
    }
    return out
}

/** 单块正文 → 提案（坏 JSON / 缺字段 / 未知名 → None，不抛） */
func decisionProposalOf(body: String): Option<DecisionProposal> {
    let t = body.trimAscii()
    if (t.size == 0) {
        return None
    }
    // 给一个确定的初值再覆盖：否则 catch 分支外的引用会被判"可能未初始化"
    var root = JsonValue.fromStr("{}")
    try {
        root = JsonValue.fromStr(t)
    } catch (e: Exception) {
        return None
    }
    match (root.kind()) {
        case JsonKind.JsObject => ()
        case _ => return None
    }
    let rule = jsonStrField(root, "rule").trimAscii()
    let decision = jsonStrField(root, "decision").trimAscii()
    if (rule.size == 0) {
        return None
    }
    if (decision != "accepted" && decision != "ignored") {
        return None
    }
    return Some(DecisionProposal(rule, decision, jsonStrField(root, "why").trimAscii()))
}

/** 提案的一句话摘要（界面卡片标题、日志、报告都用它，别各处自己拼） */
public func decisionProposalLine(p: DecisionProposal): String {
    let verdict = if (p.decision == "accepted") { "建议采纳" } else { "建议忽略" }
    if (p.why.size == 0) {
        return "${verdict}｜${p.rule}"
    }
    return "${verdict}｜${p.rule}（${p.why}）"
}
