package lingqu

import std.collection.*
import std.fs.*
import stdx.encoding.json.*

/*
 * 飞轮阶段 2：t2h:pr_prepare —— 把候选经验整理成"人只点提交"的草稿 PR 产物。
 * （docs/AI自进化飞轮.md §8 阶段 2）
 *
 * 产物（全部落 `<工程>/.lingqu/pr/<工程>/`，不碰 skills/ 本体——合并仍要人/CI，阶段 3 的事）：
 *   pr-body.md              PR 正文：证据链齐全（标题/现象/根因/复现/修法/次数/工程）
 *   pitfalls-suggestion.md  建议追加到 skills/t2h-ohos-port/references/pitfalls.md 的段
 *                           （四段 → 三段：现象 / 根因→修法；照 docs/经验入库规则.md 的映射）
 *   branch.txt              建议分支名
 *
 * token 纪律：只认环境变量 LINGQU_GITCODE_TOKEN（canSubmit=true 提示可走 CLI 提交），
 * **绝不读取/写回 settings.json**（密钥在 auth.json，也不碰）；没有 token 就退化成
 * 本地产物（degraded=true），人自己贴。
 */

/** 建议分支名：flywheel/<工程>-notes-<经验条数>（去非法字符，git ref 安全） */
public func prBranchName(projName: String, lessonCount: Int64): String {
    var safe = ""
    for (b in projName.toArray()) {
        // git ref 分支名安全集：字母数字 . - _（其余换 -）
        let ok = (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) || b == 45 || b == 46 || b == 95
        if (ok) {
            let arr = ArrayList<Byte>()
            arr.add(b)
            safe += String.fromUtf8(arr.toArray())
        } else {
            safe += "-"
        }
    }
    // 兜底：空串或只剩一串 "-"（如 "///" 全被换掉）都算没有可用名字 → proj
    var meaningful = false
    for (b in safe.toArray()) {
        if (b != 45) { // '-'
            meaningful = true
            break
        }
    }
    if (!meaningful) {
        safe = "proj"
    }
    return "flywheel/${safe}-notes-${lessonCount}"
}

/** 单条经验的 PR 段（证据链：标题/现象/根因/复现/修法/次数/工程；复用 renderPrDraft 的口径） */
func prSectionOf(n: LessonNote, idx: Int64): String {
    var s = ""
    s += "### ${idx}. ${n.title}\n\n"
    s += "- **现象**：${n.symptom}\n"
    s += "- **根因**：${n.cause}\n"
    s += "- **复现**：${n.repro}（样本：${n.project}，出现 ${n.occurrences} 次）\n"
    s += "- **修法**：${n.fix}\n"
    return s
}

/**
 * PR 正文全文：把候选经验整理成可直接贴的草稿。
 * 证据链要求（飞轮 §8 阶段 2）：标题 / 现象 / 根因 / 复现（哪个样本、哪条命令）/ 修法 / 出现次数。
 */
public func renderPrBody(projName: String, candidates: ArrayList<LessonNote>): String {
    var s = ""
    s += "## 飞轮经验入库（${projName}，${candidates.size} 条）\n\n"
    s += "> 由 lingqu `t2h:pr_prepare` 整理，人工复核后提交。入库标准见 `docs/经验入库规则.md`"
    s += "（三条件：次数 ≥2 / 四段齐全 / 未入库；提交前三问见正文末尾）。\n\n"
    if (candidates.size == 0) {
        s += "（本工程当前没有满足门槛的候选经验——不硬凑。）\n"
        return s
    }
    var i: Int64 = 1
    for (n in candidates) {
        s += prSectionOf(n, i)
        i += 1
    }
    s += "\n### 提交前确认三问\n\n"
    s += "1. 修法是**实际生效**的那个吗（不是「理论上应该行」）？\n"
    s += "2. 换个工程还成立吗（只有本工程特有的坑不该进通用库）？\n"
    s += "3. 落点选对了吗（指纹 / 规则 / 技能 / §4 坑清单——见经验入库规则的选型判据）？\n"
    return s
}

/**
 * 建议追加到 pitfalls.md 的段（四段 → 三段：现象 / 根因→修法；带样本出处）。
 * 只是**建议文本**（人复制进 pitfalls.md 或走阶段 3 PR），本函数不改 skills/。
 */
public func renderPitfallsSuggestion(projName: String, candidates: ArrayList<LessonNote>): String {
    var s = ""
    s += "<!-- lingqu pr_prepare 建议追加段（来自 ${projName}，人工复核后落位到对应小节） -->\n\n"
    for (n in candidates) {
        s += "### ${n.title}\n\n"
        s += "- **现象**：${n.symptom}\n"
        s += "- **根因 → 修法**：${n.cause} → ${n.fix}\n"
        s += "- **出处**：${n.project}（出现 ${n.occurrences} 次）\n\n"
    }
    return s
}

/** pr_prepare 的产物清单与 token 状态 */
public class PrPrepareResult {
    public var bodyPath: String = ""
    public var suggestionPath: String = ""
    public var branchPath: String = ""
    public var branch: String = ""
    public var prepared: Int64 = 0
    public var canSubmit: Bool = false
    public var degraded: Bool = false
    public var note: String = ""
    public var outError: String = ""

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("bodyPath", JsonString(this.bodyPath))
        o.put("suggestionPath", JsonString(this.suggestionPath))
        o.put("branchPath", JsonString(this.branchPath))
        o.put("branch", JsonString(this.branch))
        o.put("prepared", JsonInt(this.prepared))
        o.put("canSubmit", JsonBool(this.canSubmit))
        o.put("degraded", JsonBool(this.degraded))
        o.put("note", JsonString(this.note))
        o.put("outError", JsonString(this.outError))
        return o
    }
}

/**
 * 阶段 2 编排：筛候选 → 产三份文件 → 按 token 状态标记 canSubmit/degraded。
 * 只写 `.lingqu/pr/`，不碰 skills/（合并是人/CI 的事，永远不做自动合并）。
 */
public func preparePr(projDir: String, projName: String, tokenEnv: String): PrPrepareResult {
    let res = PrPrepareResult()
    let candidates = candidateLessons(loadLessons(projDir, projName))
    res.prepared = candidates.size

    // token 只走环境变量：有则 canSubmit（可直接走 gitcode CLI 提交），无则退化本地产物
    if (tokenEnv != "") {
        res.canSubmit = true
        res.note = "检测到 LINGQU_GITCODE_TOKEN：产物可直接提交（分支与人评由你把关）"
    } else {
        res.degraded = true
        res.note = "未设 LINGQU_GITCODE_TOKEN：退化为本地产物——人复核后自行提交"
    }

    if (candidates.size == 0) {
        res.note = "没有满足门槛的候选经验（次数 ≥2 + 四段齐全 + 未入库）——" + res.note
        return res
    }

    let dir = prDirOf(projDir, projName)
    let bodyPath = "${dir}/pr-body.md"
    let sugPath = "${dir}/pitfalls-suggestion.md"
    let branchPath = "${dir}/branch.txt"
    res.branch = prBranchName(projName, candidates.size)
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir))
        }
        let body = renderPrBody(projName, candidates)
        File.writeTo(bodyPath, body.toArray())
        File.writeTo(sugPath, renderPitfallsSuggestion(projName, candidates).toArray())
        File.writeTo(branchPath, (res.branch + "\n").toArray())
        res.bodyPath = bodyPath
        res.suggestionPath = sugPath
        res.branchPath = branchPath
    } catch (e: Exception) {
        res.outError = "${e}"
    }
    return res
}

/** pr 产物目录（与 notes/candidates 同层：`<工程>/.lingqu/pr/<工程>/`，复用 lqPathOf 口径） */
public func prDirOf(projDir: String, projName: String): String {
    return lqPathOf(projDir, "pr/" + projName)
}
