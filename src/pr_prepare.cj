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
    s += "\n> 合并后**下次启动**才刷新本地技能（不热替换——prompt 漂移会让行为变了却没人知道为什么）。\n"
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
    /** 正文里并进了 `archive --to repo` 落下的经验块（阶段 2 打通，0.39.114） */
    public var lessonsMerged: Bool = false
    /** 没凭据时"怎么开"的可操作路径（0.39.118：不再只丢一句"未设置环境变量"） */
    public var howToEnable: String = ""

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("bodyPath", JsonString(this.bodyPath))
        o.put("suggestionPath", JsonString(this.suggestionPath))
        o.put("branchPath", JsonString(this.branchPath))
        o.put("branch", JsonString(this.branch))
        o.put("prepared", JsonInt(this.prepared))
        o.put("canSubmit", JsonBool(this.canSubmit))
        o.put("degraded", JsonBool(this.degraded))
        o.put("lessonsMerged", JsonBool(this.lessonsMerged))
        o.put("howToEnable", JsonString(this.howToEnable))
        o.put("note", JsonString(this.note))
        o.put("outError", JsonString(this.outError))
        return o
    }
}

/**
 * 阶段 3 护栏（飞轮 §8）：单轮 PR 最多带 N 条候选——一次 PR 改太多条，
 * 评审就变成"信任 AI"而不是"逐条复核"。超出部分截断进 note，下轮再提。
 */
public let MAX_CANDIDATES_PER_PR: Int64 = 5

/**
 * 提交凭据的**环境变量名**（顺序即优先级）。
 *
 * 0.39.118：原先只认 `LINGQU_GITCODE_TOKEN` 一个——用户当场点破这不合理：
 * "否则单靠个人意愿，未必现实"。一个变量没设就把"能不能发 PR"判死，
 * 等于把飞轮闭合的那一步交给运气（R-1 的 1.3 就是因此一直拿不到证据）。
 * 现在把同义变量都认上，探测不到时**不再静默退化**，而是给出可操作的开启路径。
 */
public let SUBMIT_TOKEN_ENVS: Array<String> = [
    "LINGQU_GITCODE_TOKEN", "GITCODE_TOKEN", "ATOMGIT_TOKEN", "GH_TOKEN"
]

/** 凭据探测结果：有则带来源（便于回投与排障），无则空串 */
public class SubmitAuth {
    public var token: String = ""
    public var source: String = ""
    public var available: Bool = false
    public var howToEnable: String = ""

    public func toJson(): JsonObject {
        var o = JsonObject()
        // 只回投"有没有 / 从哪来"，**绝不回投 token 本身**
        o.put("available", JsonBool(this.available))
        o.put("source", JsonString(this.source))
        o.put("howToEnable", JsonString(this.howToEnable))
        return o
    }
}

/** 环境变量名清单（只读副本，供界面/文档与单测对齐，避免两处各写一份） */
public func submitTokenEnvNamesOf(): Array<String> {
    return SUBMIT_TOKEN_ENVS
}

/**
 * 没凭据时该怎么说：**给出能动手的三条路**，而不是一句"未设置环境变量"。
 * 第三条（自己提）必须写——不授权也该有出路，否则等于拿授权要挟用户。
 */
public func submitEnableHintOf(): String {
    return "开一条就行：① 导出个人访问令牌（认 LINGQU_GITCODE_TOKEN / GITCODE_TOKEN / " +
        "ATOMGIT_TOKEN / GH_TOKEN 任一）；② 本机登录 atomgit CLI，让工具代管凭据后重跑；" +
        "③ 不想授权也没关系——`pr-body.md` 已生成，自己提同样有效"
}

/** 多源探测提交凭据（IO：读环境变量），返回值里**只带来源与提示，不带 token 值** */
public func resolveSubmitAuth(): SubmitAuth {
    let auth = SubmitAuth()
    for (name in SUBMIT_TOKEN_ENVS) {
        let v = envOr(name, "")
        if (v.size > 0) {
            auth.token = v
            auth.source = "env:${name}"
            auth.available = true
            return auth
        }
    }
    auth.howToEnable = submitEnableHintOf()
    return auth
}

/**
 * 阶段 2 编排：筛候选 → 产三份文件 → 按 token 状态标记 canSubmit/degraded。
 * 只写 `.lingqu/pr/`，不碰 skills/（合并是人/CI 的事，永远不做自动合并）。
 * 阶段 3 护栏：同类去重（lessonKeyOf）+ 单轮候选上限（MAX_CANDIDATES_PER_PR）。
 */
public func preparePr(projDir: String, projName: String, tokenEnv: String): PrPrepareResult {
    let res = PrPrepareResult()
    // 同类去重：lessonKeyOf（title+cause）相同视为同一条——loader 已去重，这里防御一次
    var all = candidateLessons(loadLessons(projDir, projName))
    let seen = HashSet<String>()
    var deduped = ArrayList<LessonNote>()
    for (n in all) {
        let key = lessonKeyOf(n)
        if (seen.contains(key)) {
            continue
        }
        seen.add(key)
        deduped.add(n)
    }
    all = deduped
    // 护栏：单轮上限——超出截断（不是丢弃：候选池还在 notes.md，下轮再提）
    var truncated = false
    if (all.size > MAX_CANDIDATES_PER_PR) {
        var capped = ArrayList<LessonNote>()
        for (i in 0..MAX_CANDIDATES_PER_PR) {
            capped.add(all[i])
        }
        all = capped
        truncated = true
    }
    res.prepared = all.size

    // 0.39.118：凭据由 `resolveSubmitAuth()` **多源**探测（四个同义环境变量），这里只按结果分支。
    // 探测不到时**不静默退化**：把"怎么开"当场写进 note 与 howToEnable 字段（§4-129：要人做一件事，
    // 就得把可点的东西摆到面前），第三条路明确给出"不授权也能自己提"。
    if (tokenEnv != "") {
        res.canSubmit = true
        res.note = "检测到提交凭据：产物可直接提交（分支与人评由你把关）"
    } else {
        res.degraded = true
        res.howToEnable = submitEnableHintOf()
        res.note = "未检测到 AtomGit / GitCode 提交凭据，已退化为本地产物——" + res.howToEnable
    }
    if (truncated) {
        res.note = "单轮候选超上限 ${MAX_CANDIDATES_PER_PR}，本轮只带前 ${MAX_CANDIDATES_PER_PR} 条（其余留在候选池）——" + res.note
    }

    let dir = prDirOf(projDir, projName)
    let bodyPath = "${dir}/pr-body.md"
    let sugPath = "${dir}/pitfalls-suggestion.md"
    let branchPath = "${dir}/branch.txt"
    let lessonBlockPath = "${dir}/lessons-suggestion.md"
    let hasLessonBlock = exists(Path(lessonBlockPath))

    if (all.size == 0 && !hasLessonBlock) {
        res.note = "没有满足门槛的候选经验（次数 ≥2 + 四段齐全 + 未入库）——" + res.note
        return res
    }
    // ⚠ 候选被 `archive --to repo` 清空、但 repo 经验块在：正文以**经验块为主体**。
    // 少了这一段，"归档 → 提 PR"这条链在最后一步永远返回"没有候选"，经验块并不进正文
    // （0.39.114 实测撞到：repoPrReady=true 但 pr-body.md 不存在）
    if (all.size == 0) {
        res.branch = "lingqu/lessons/" + projName
        try {
            if (!exists(Path(dir))) {
                Directory.create(Path(dir))
            }
            let lb = String.fromUtf8(File.readFrom(lessonBlockPath))
            File.writeTo(bodyPath, ("# ${projName}：经验沉淀（待合并）\n\n" + lb).toArray())
            File.writeTo(branchPath, (res.branch + "\n").toArray())
            res.bodyPath = bodyPath
            res.lessonsMerged = true
            res.note = "候选池已清空（经验已归档），正文只带 repo 经验块——" + res.note
        } catch (e: Exception) {
            res.outError = "${e}"
        }
        return res
    }

    res.branch = prBranchName(projName, all.size)
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir))
        }
        let body0 = renderPrBody(projName, all)
        // 阶段 2 打通（0.39.114）：archive --to repo 落下的经验块并进正文，人不用手动搬运
        var body = body0
        if (hasLessonBlock) {
            try {
                let lb = String.fromUtf8(File.readFrom(lessonBlockPath))
                body = upsertLessonsSectionOf(body0, lb)
                res.lessonsMerged = true
                res.note = "正文已并入 repo 归档的经验块——" + res.note
            } catch (e: Exception) {
                // 并块失败不能吞：正文照写，但要把原因带回去（§4-111 期望与结果不一致要说清）
                let _ = e
                res.note = "repo 经验块读取失败（正文未并入）——" + res.note
            }
        }
        File.writeTo(bodyPath, body.toArray())
        File.writeTo(sugPath, renderPitfallsSuggestion(projName, all).toArray())
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

// ============================================================
// 阶段 2 打通（0.39.114）：`notes archive --to repo` ↔ `t2h:pr_prepare`
// ============================================================
//
// 之前两件事各干各的：`--to repo` 只回一句「经验留在候选草稿里，等你提 PR」，而 `pr_prepare`
// 只认**仍未入库**的候选（`candidateLessons` 会跳过 `isLessonArchived`）。于是**刚归档的那批
// 经验两边都不认**——归档把它移出候选池，pr_prepare 又不读归档 ⇒ 人按提示去提 PR，草稿里
// 却没有它（§4-136 同族：跑过了，但没进入下一步的输入）。
//
// 现在的口径：归档到 repo **当场**产出一份带标记的可合并块 `lessons-suggestion.md`，
// `pr_prepare` 再把这份块并进 `pr-body.md`。唯一的搬运是"人复核 + 提交"——仍然不自动合并。

public let LESSONS_SECTION_BEGIN: String = "<!-- lingqu:repo-lessons:begin -->"
public let LESSONS_SECTION_END: String = "<!-- lingqu:repo-lessons:end -->"

/** 可合并的经验块（带标记：upsert 靠它定位，人也靠它一眼看出这段是机器整理的） */
public func renderRepoLessonsBlock(projName: String, notes: ArrayList<LessonNote>): String {
    var s = LESSONS_SECTION_BEGIN + "\n\n"
    s += "## 经验沉淀（${projName}，${notes.size} 条，待合并）\n\n"
    s += "> 由 lingqu `notes archive --to repo` 整理。入库判据见 `docs/经验入库规则.md`；"
    s += "落位选型（指纹 / 规则 / 技能 / §4 坑清单）也按它选，别一股脑塞进 AGENTS。\n\n"
    var i: Int64 = 1
    for (n in notes) {
        s += "### ${i}. ${n.title}\n\n"
        s += "- **现象**：${n.symptom}\n"
        s += "- **根因**：${n.cause}\n"
        s += "- **修法**：${n.fix}\n"
        s += "- **出处**：${n.project}（出现 ${n.occurrences} 次）\n\n"
        i += 1
    }
    s += LESSONS_SECTION_END + "\n"
    return s
}

/**
 * 幂等 upsert：文档里已有标记就**整段替换**，没有就追加到末尾（保留人写的内容）。
 *
 * 为什么要幂等：`archive --to repo` / `pr_prepare` 都可能跑多次，直接追加会让同一批经验
 * 在正文里叠成两份、三份（§4-129 那类"重跑一次就重复"的坑）。
 */
public func upsertLessonsSectionOf(doc: String, block: String): String {
    var start: Int64 = -1
    var end: Int64 = -1
    match (doc.indexOf(LESSONS_SECTION_BEGIN)) {
        case Some(v) => start = v
        case None => start = -1
    }
    match (doc.indexOf(LESSONS_SECTION_END)) {
        case Some(v) => end = v
        case None => end = -1
    }
    if (start >= 0 && end > start) {
        let head = doc[0..start]
        var tail = doc[(end + LESSONS_SECTION_END.size)..]
        // 块自带收尾换行时，别让 tail 的换行再叠一个——否则重跑一次就多一行，upsert 不幂等
        if (block.endsWith("\n") && tail.startsWith("\n")) {
            tail = tail[1..]
        }
        return head + block + tail
    }
    var out = doc
    // 别用 `out[(out.size - 1)..out.size]` 判末字符：那是**取最后一个字节**，中文必抛
    // IllegalArgumentException: Invalid utf8 byte sequence（§4-116 同族）
    if (out.size > 0 && !out.endsWith("\n")) {
        out += "\n"
    }
    out += "\n" + block
    return out
}

/** 归档到 repo 的产物状态（ready / 落点 / 并进了哪份正文 / 说清下一步） */
public class RepoStageResult {
    public var ready: Bool = false
    public var path: String = ""
    public var mergedInto: String = ""
    public var note: String = ""
    public var outError: String = ""

    public init() {}

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("ready", JsonBool(this.ready))
        o.put("path", JsonString(this.path))
        o.put("mergedInto", JsonString(this.mergedInto))
        o.put("note", JsonString(this.note))
        o.put("outError", JsonString(this.outError))
        return o
    }
}

/**
 * `archive --to repo` 的落盘：写 `lessons-suggestion.md`，草稿正文已存在就顺手并进去。
 *
 * 空候选不产文件（`ready=false` + 说清原因）——不产空壳让人以为"已经准备好了"（§4-63）。
 */
public func stageRepoLessons(projDir: String, projName: String,
                             notes: ArrayList<LessonNote>): RepoStageResult {
    let r = RepoStageResult()
    if (notes.size == 0) {
        r.note = "本轮没有可归档的经验（候选池为空或都没过门槛）——不产 PR 草稿"
        return r
    }
    let dir = prDirOf(projDir, projName)
    let p = "${dir}/lessons-suggestion.md"
    let block = renderRepoLessonsBlock(projName, notes)
    try {
        // §4-76：父级不存在要 recursive 建；§4-89：已存在时 recursive create 会抛，先判
        if (!exists(Path(dir))) {
            Directory.create(Path(dir), recursive: true)
        }
        File.writeTo(p, block.toArray())
        r.path = p
        r.ready = true
    } catch (e: Exception) {
        r.outError = "${e}"
        return r
    }
    let body = "${dir}/pr-body.md"
    if (exists(Path(body))) {
        try {
            let old = String.fromUtf8(File.readFrom(body))
            File.writeTo(body, upsertLessonsSectionOf(old, block).toArray())
            r.mergedInto = body
        } catch (e: Exception) {
            r.outError = "${e}"
            return r
        }
    }
    r.note = if (r.mergedInto == "") {
        "经验块已落 ${p}；跑 t2h:pr_prepare 会把它并进草稿正文，也可直接贴进 PR"
    } else {
        "经验块已落 ${p} 并已并入 ${r.mergedInto}——复核后提交即可"
    }
    return r
}
