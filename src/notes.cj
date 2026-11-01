package lingqu

import std.collection.*
import std.fs.*
import stdx.encoding.json.*

/*
 * 本地经验（lessons / notes）：让 **agent 自己**把"这次踩的坑"写下来（0.39.55）。
 *
 * 为什么要有它（0.39.54 之前的状态）：
 *   · 事实层全自动：每步落档、agent 轨迹（`.lingqu/agent/trace.jsonl`）、报告，一样不少；
 *   · **认知层靠人**：新坑 → 新指纹 / 新技能条目 / AGENTS §4，全是每轮手写。
 *   而 agent 的汇报留在会话里，会话一压缩（实测"21/24/30 条早期消息 → 摘要"）细节就淡了。
 *
 * 所以给 agent 一个**落盘的口子**：踩坑就按固定四段（现象 / 根因 / 复现 / 修法）追加到
 * `<工程>/.lingqu/notes/<工程>.md`；去重（同标题合并次数），可读回、可导出、可进报告。
 *
 * 纪律：
 *   ① 只记真事——写进来的是 agent 自己跑过、看过的东西，不是猜的；
 *   ② 幂等：同标题不重复堆，`次数` 累加；
 *   ③ 不自动改技能库：这里是"候选经验"，能不能进 `skills/` 要人或 PR 评审（prompt 漂移代价太大）。
 */

/** 经验落档目录（工程内，相对 `.lingqu/`） */
public let NOTES_SUBDIR: String = "notes"

/** 候选门槛：同标题出现 **≥2 次** 才值得看一眼（1 次往往只是命令自己写错了，见 `docs/经验入库规则.md`） */
public let MIN_LESSON_OCCURRENCES: Int64 = 2

/** 「已入库」标记的键名：人工把这条经验写进指纹/规则/技能后，在条目下补一行 `- 入库：<引用>` */
public let LESSON_ARCHIVED_KEY: String = "入库"

/** 一条经验（固定四段 + 出现次数/来源工程/时间 + 可选的"已入库"引用） */
public class LessonNote {
    public var title: String = ""
    public var symptom: String = ""
    public var cause: String = ""
    public var repro: String = ""
    public var fix: String = ""
    public var occurrences: Int64 = 1
    public var project: String = ""
    public var at: String = ""
    /** 已入库的引用（`FP-021` / `R2-PORT-016` / `references/pitfalls.md#3` …）；空 = 还没入库 */
    public var archivedRef: String = ""

    public init() {}

    public init(title: String, symptom: String, cause: String, repro: String, fix: String) {
        this.title = title
        this.symptom = symptom
        this.cause = cause
        this.repro = repro
        this.fix = fix
    }
}

/** 经验的落档路径：`<工程>/.lingqu/notes/<工程>.md`（跟着工程走，与其它落档一致） */
public func notesPathOf(projDir: String, projName: String): String {
    let base = lqDirOf(projDir)
    return base + cjhPathSep() + NOTES_SUBDIR + cjhPathSep() + "${projName}.md"
}

/** 单行化（换行会破坏 `- 字段：值` 的结构） */
func oneLineOf(s: String): String {
    var out = s.replace("\r", " ").replace("\n", " ")
    out = out.trimAscii()
    return out
}

/** 纯函数：把一条经验渲染成 markdown 段落（固定四段，机器与人都好处理） */
public func renderLesson(n: LessonNote): String {
    var s = "### ${oneLineOf(n.title)}\n"
    s += "- 现象：${oneLineOf(n.symptom)}\n"
    s += "- 根因：${oneLineOf(n.cause)}\n"
    s += "- 复现：${oneLineOf(n.repro)}\n"
    s += "- 修法：${oneLineOf(n.fix)}\n"
    s += "- 次数：${n.occurrences}　工程：${oneLineOf(n.project)}　时间：${oneLineOf(n.at)}\n"
    if (oneLineOf(n.archivedRef).size > 0) {
        s += "- ${LESSON_ARCHIVED_KEY}：${oneLineOf(n.archivedRef)}\n"
    }
    return s
}

/** 取 `- 键：值` 里的值（没有这个键给 ""） */
func lessonFieldOf(block: String, key: String): String {
    let marker = "- ${key}："
    match (block.indexOf(marker)) {
        case Some(i) =>
            let start = i + marker.size
            let rest = block[start..]
            let end = match (rest.indexOf("\n")) {
                case Some(e) => e
                case None => rest.size
            }
            return rest[0..end].trimAscii()
        case None => return ""
    }
}

/** 纯函数：解析一段 notes 文本（宽容：不认识的段落跳过，缺字段留空，绝不抛） */
public func parseLessons(text: String): ArrayList<LessonNote> {
    let out = ArrayList<LessonNote>()
    if (text.trimAscii().size == 0) {
        return out
    }
    // 以 "### " 切块；第一块常常是文件头（# 标题），没有 "### " 就不算
    let parts = text.split("\n### ", -1)
    var i: Int64 = 0
    while (i < Int64(parts.size)) {
        var block = parts[i]
        if (i > 0) {
            block = "### " + block
        }
        if (block.startsWith("### ")) {
            let firstNl = match (block.indexOf("\n")) {
                case Some(e) => e
                case None => block.size
            }
            let title = block[3..firstNl].trimAscii()
            if (title != "") {
                let n = LessonNote()
                n.title = title
                n.symptom = lessonFieldOf(block, "现象")
                n.cause = lessonFieldOf(block, "根因")
                n.repro = lessonFieldOf(block, "复现")
                n.fix = lessonFieldOf(block, "修法")
                let occ = lessonFieldOf(block, "次数")
                // `次数：2　工程：x　时间：y` —— 取开头的数字
                var num: Int64 = 0
                var saw = false
                for (ch in countOfDigits(occ)) {
                    num = num * 10 + ch
                    saw = true
                }
                n.occurrences = if (saw) { num } else { 1 }
                if (n.occurrences < 1) {
                    n.occurrences = 1
                }
                n.project = fieldAfterSpace(occ, "工程：")
                n.at = fieldAfterSpace(occ, "时间：")
                n.archivedRef = lessonFieldOf(block, LESSON_ARCHIVED_KEY)
                out.add(n)
            }
        }
        i += 1
    }
    return out
}

/** 取字符串开头连续数字的各位（"2　工程：x" → [2]） */
func countOfDigits(s: String): ArrayList<Int64> {
    let out = ArrayList<Int64>()
    for (b in s.toArray()) {
        if (b >= 48 && b <= 57) {
            out.add(Int64(b) - 48)
        } else {
            break
        }
    }
    return out
}

/**
 * 取 `工程：` / `时间：` 这类"同一行多字段"的值（没有给 ""）。
 *
 * 行形如 `次数：2　工程：p　时间：t`（字段之间是**全角空格** `　`）——
 * 取到该字段结尾就停，否则 `工程` 会把后面的 `时间` 一起吃进去（0.39.55 实测踩到：
 * 单测里 `project` 变成 `juCang　时间：2026-11-02 …`）。
 */
func fieldAfterSpace(s: String, marker: String): String {
    match (s.indexOf(marker)) {
        case Some(i) =>
            let rest = s[(i + marker.size)..]
            let end = match (rest.indexOf("　")) {
                case Some(e) => e
                case None => rest.size
            }
            return rest[0..end].trimAscii()
        case None => return ""
    }
}

/**
 * 纯函数：去重键（标题归一化：去空白、ASCII 小写）。
 *
 * 注意：不能逐字节 `String.fromUtf8([b])` 再拼（§4-113 同族坑）：中文标题的某个字节
 * 单独拎出来不是合法 UTF-8，会抛 `IllegalArgumentException: Invalid utf8 byte sequence`。
 * 正确做法是攒 `ArrayList<Byte>` 后整体解一次。
 */
public func lessonKeyOf(n: LessonNote): String {
    let out = ArrayList<Byte>()
    for (b in n.title.toArray()) {
        if (b == 32 || b == 9) {
            continue
        }
        out.add(if (b >= 65 && b <= 90) { UInt8(Int64(b) + 32) } else { b })
    }
    return String.fromUtf8(out.toArray())
}

/**
 * 纯函数：合并两份经验列表（**去重 + 次数累加**，先出现的顺序保留）。
 *
 * 去重键是同名标题（`lessonKeyOf`）；重复时 `occurrences` 相加，其余字段以**先到的**为准
 * （先写下来的那条通常是第一手现场）。
 */
public func mergeLessons(existing: ArrayList<LessonNote>, incoming: ArrayList<LessonNote>): ArrayList<LessonNote> {
    let out = ArrayList<LessonNote>()
    let index = HashMap<String, Int64>()
    for (n in existing) {
        let k = lessonKeyOf(n)
        index.add(k, Int64(out.size))
        out.add(n)
    }
    for (n in incoming) {
        let k = lessonKeyOf(n)
        match (index.get(k)) {
            case Some(i) =>
                out[i].occurrences += n.occurrences
            case None =>
                index.add(k, Int64(out.size))
                out.add(n)
        }
    }
    return out
}

/** 纯函数：一句话摘要（给报告/界面用；空列表返回空串，不编数字） */
public func lessonsSummaryLine(lessons: ArrayList<LessonNote>): String {
    if (lessons.size == 0) {
        return ""
    }
    var titles = ""
    var i: Int64 = 0
    while (i < Int64(lessons.size) && i < 3) {
        if (i > 0) {
            titles += "、"
        }
        titles += lessons[i].title
        i += 1
    }
    if (lessons.size > 3) {
        titles += " 等 ${lessons.size} 条"
    }
    return "本地经验 ${lessons.size} 条（${titles}）"
}

// ============================================================
// 候选池（阶段 1，0.39.56）：机器提议、人裁决
//
// 为什么要有这一步：经验落盘了，但"哪些值得进技能库/指纹库"以前靠人翻文件。
// 现在按**可判定的门槛**筛出来，并给每条配一段 PR 正文草稿——人只做"确认/驳回"。
// 门槛（见 `docs/经验入库规则.md`）：`次数 ≥ 2` + 四段齐全 + 还没入库。
// ============================================================

/** 纯函数：这条经验是否已入库（人工补过 `- 入库：…`） */
public func isLessonArchived(n: LessonNote): Bool {
    return oneLineOf(n.archivedRef).size > 0
}

/** 纯函数：四段是否齐全（技能/指纹条目的最低要求：现象 / 根因 / 复现 / 修法 都要有） */
public func isLessonComplete(n: LessonNote): Bool {
    return oneLineOf(n.title).size > 0 && oneLineOf(n.symptom).size > 0 &&
        oneLineOf(n.cause).size > 0 && oneLineOf(n.repro).size > 0 && oneLineOf(n.fix).size > 0
}

/**
 * 纯函数：筛出候选经验（**未入库 + 四段齐全 + 次数达标**，顺序保留）。
 *
 * 三条缺一不可：次数不够 = 可能只是命令写错；四段不齐 = 写不出技能条目；
 * 已入库 = 已经沉淀过了，再提就是重复 PR。
 */
public func candidateLessons(list: ArrayList<LessonNote>): ArrayList<LessonNote> {
    let out = ArrayList<LessonNote>()
    for (n in list) {
        if (isLessonArchived(n)) {
            continue
        }
        if (n.occurrences < MIN_LESSON_OCCURRENCES) {
            continue
        }
        if (!isLessonComplete(n)) {
            continue
        }
        out.add(n)
    }
    return out
}

/** 纯函数：按"是否已入库"拆成 (已入库, 待裁决)，顺序都保留 */
public func splitArchivedLessons(list: ArrayList<LessonNote>): (ArrayList<LessonNote>, ArrayList<LessonNote>) {
    let archived = ArrayList<LessonNote>()
    let kept = ArrayList<LessonNote>()
    for (n in list) {
        if (isLessonArchived(n)) {
            archived.add(n)
        } else {
            kept.add(n)
        }
    }
    return (archived, kept)
}

/** 纯函数：候选清单里的一条（一句话，给渲染用） */
func candidateRowOf(n: LessonNote): String {
    var s = "- **${oneLineOf(n.title)}**　次数 ${n.occurrences}"
    if (oneLineOf(n.project).size > 0) {
        s += "　工程：${oneLineOf(n.project)}"
    }
    if (oneLineOf(n.fix).size > 0) {
        s += "　修法：${oneLineOf(n.fix)}"
    }
    return s + "\n"
}

/**
 * 纯函数：一条经验的 **PR 正文草稿**（人复制进 PR body 即可）。
 *
 * 刻意把"提交前确认"三问写进草稿：四段是否实测、有没有夹带本机信息、是否跨样本复现过——
 * 这三条挡住的正是"用一条没验证过的经验去改别人的工程"。
 */
public func renderPrDraft(n: LessonNote): String {
    var s = "### PR 草稿：${oneLineOf(n.title)}\n\n"
    s += "**现象**：${oneLineOf(n.symptom)}\n\n"
    s += "**根因**：${oneLineOf(n.cause)}\n\n"
    s += "**复现**：${oneLineOf(n.repro)}\n\n"
    s += "**修法**：${oneLineOf(n.fix)}\n\n"
    s += "- 出现次数：${n.occurrences}"
    if (oneLineOf(n.project).size > 0) {
        s += "（工程：${oneLineOf(n.project)}）"
    }
    s += "\n"
    s += "- 建议落点：`skills/t2h-ohos-port/references/pitfalls.md`（现象 → 根因 → 修法 三段）；" +
        "若日志里有稳定子串，更适合做成一条 `Fingerprint`（命中即给修法，不烧模型轮次）\n"
    s += "- 提交前确认：① 四段都是**实测过**的（不是推测）；② 没有夹带本机路径 / UDID / 密钥；" +
        "③ 在**另一个样本**上也复现过一次（或明确写「单样本」）\n"
    s += "- 入库后在经验条目下补一行 `- 入库：<引用>`（如 `FP-021` / `pitfalls.md#3`），" +
        "再跑 `notes --action archive` 就会把它移出候选池\n\n"
    s += "```text\n现象：\n根因：\n修法：\n实测出处：<样本> / <步骤落档路径> / <日期>\n```\n"
    return s
}

/**
 * 纯函数：候选清单 markdown（`notes --action suggest` 的产物）。
 *
 * 三段：本地经验候选 / 未命中指纹候选 / 逐条 PR 草稿。没有候选就**明说"没有"**，不写空表。
 */
public func renderCandidatesMd(projName: String, candidates: ArrayList<LessonNote>,
    missSigs: ArrayList<String>, missTimes: ArrayList<Int64>): String {
    var s = "# ${projName} 经验候选（机器提议，需人裁决）\n\n"
    s += "> 生成规则：同标题出现 **≥${MIN_LESSON_OCCURRENCES} 次** + 四段齐全 + **未入库**。\n"
    s += "> 入库后在那条经验下补一行 `- 入库：<引用>`，再跑 `lingqu-cli notes --action archive` 即移出候选池。\n"
    s += "> 入库标准与改写格式见 `docs/经验入库规则.md`。\n\n"
    s += "## 一、本地经验候选（${candidates.size} 条）\n\n"
    if (candidates.size == 0) {
        s += "（没有达到门槛的经验：要么次数还不够，要么四段不齐，要么已经入库过了）\n\n"
    } else {
        for (n in candidates) {
            s += candidateRowOf(n)
        }
        s += "\n"
    }
    s += "## 二、未命中指纹候选（同签名 ≥3 次，${missSigs.size} 条）\n\n"
    if (missSigs.size == 0) {
        s += "（还没有出现 ≥3 次的未命中签名——`t2h:diagnose` 真未命中才会往台账里写）\n\n"
    } else {
        var i: Int64 = 0
        while (i < Int64(missSigs.size) && i < Int64(missTimes.size)) {
            s += "- 出现 ${missTimes[i]} 次：`${missSigs[i]}`\n"
            i += 1
        }
        s += "\n"
    }
    s += "## 三、逐条 PR 正文草稿（${candidates.size} 条）\n\n"
    if (candidates.size == 0) {
        s += "（无可提交的草稿）\n"
    } else {
        for (n in candidates) {
            s += renderPrDraft(n)
        }
    }
    return s
}

/** 候选清单的落档路径：`<工程>/.lingqu/notes/<工程>-candidates.md`（跟着工程走） */
public func candidatesPathOf(projDir: String, projName: String): String {
    let base = lqDirOf(projDir)
    return base + cjhPathSep() + NOTES_SUBDIR + cjhPathSep() + "${projName}-candidates.md"
}

/** 归档件的路径：`<工程>/.lingqu/notes/<工程>-archived.md` */
public func archivedNotesPathOf(projDir: String, projName: String): String {
    let base = lqDirOf(projDir)
    return base + cjhPathSep() + NOTES_SUBDIR + cjhPathSep() + "${projName}-archived.md"
}

/** 经验文件全文（头 + 每条一段）；`appendLesson` 与归档共用，保证写出的形状只有一个来源 */
public func lessonsFileText(list: ArrayList<LessonNote>): String {
    var text = "# 本地经验（灵渠自动收集，勿手改结构；可直接追加）\n\n"
    for (x in list) {
        text += renderLesson(x) + "\n"
    }
    return text
}

/** 写候选清单（动作层；建目录先判存在，见 §4-89） */
public func writeCandidates(projDir: String, projName: String,
    candidates: ArrayList<LessonNote>, missSigs: ArrayList<String>, missTimes: ArrayList<Int64>,
    outPath: String): String {
    var p = outPath
    if (p.size == 0) {
        p = candidatesPathOf(projDir, projName)
    }
    let dir = lqDirOf(projDir) + cjhPathSep() + NOTES_SUBDIR
    if (!exists(Path(dir))) {
        try {
            Directory.create(Path(dir), recursive: true)
        } catch (e: Exception) {
            return "error:建目录失败：${e}"
        }
    }
    try {
        File.writeTo(p, renderCandidatesMd(projName, candidates, missSigs, missTimes).toArray())
    } catch (e: Exception) {
        return "error:写盘失败：${e}"
    }
    return "ok:${p}"
}

/** 归档结果（回投界面/命令行） */
public class ArchiveResult {
    public var archived: Int64 = 0
    public var kept: Int64 = 0
    public var archivePath: String = ""
    public var note: String = ""
}

/**
 * 动作层：把**已入库**的经验挪到 `<工程>-archived.md`，主文件只留待裁决的。
 *
 * 两条纪律：① 归档失败绝不动主文件（先写归档件、成功后再重写主文件）；
 * ② 没有已入库条目时**什么都不做**，返回 `note` 说明（别写空文件冒充"归档过了"）。
 */
public func archiveLessons(projDir: String, projName: String): ArchiveResult {
    let res = ArchiveResult()
    let all = loadLessons(projDir, projName)
    let (archived, kept) = splitArchivedLessons(all)
    res.archived = Int64(archived.size)
    res.kept = Int64(kept.size)
    res.archivePath = archivedNotesPathOf(projDir, projName)
    if (archived.size == 0) {
        res.note = "没有已入库的经验（先在条目下补 `- ${LESSON_ARCHIVED_KEY}：<引用>`）"
        return res
    }
    let dir = lqDirOf(projDir) + cjhPathSep() + NOTES_SUBDIR
    if (!exists(Path(dir))) {
        try {
            Directory.create(Path(dir), recursive: true)
        } catch (e: Exception) {
            res.note = "error:建目录失败：${e}"
            return res
        }
    }
    // ① 先写归档件（已存在就**并入**：解析 → 合并去重 → 落盘）
    let existingArchive = archivedNotesPathOf(projDir, projName)
    let old = ArrayList<LessonNote>()
    if (exists(Path(existingArchive))) {
        try {
            let t = String.fromUtf8(File.readFrom(existingArchive))
            for (x in parseLessons(t)) {
                old.add(x)
            }
        } catch (e: Exception) {
            let _ = e
        }
    }
    let merged = mergeLessons(old, keptOfArchive(archived))
    try {
        File.writeTo(existingArchive, lessonsFileText(merged).toArray())
    } catch (e: Exception) {
        res.note = "error:写归档件失败（主文件未改）：${e}"
        return res
    }
    // ② 再按归档后的结果重写主文件
    try {
        File.writeTo(notesPathOf(projDir, projName), lessonsFileText(kept).toArray())
    } catch (e: Exception) {
        res.note = "error:写主文件失败（归档件已写好）：${e}"
        return res
    }
    res.note = "ok:归档 ${res.archived} 条，主文件保留 ${res.kept} 条"
    return res
}

/** 复制一份（`mergeLessons` 会把入参对象放进结果，避免共享可变实例） */
func keptOfArchive(src: ArrayList<LessonNote>): ArrayList<LessonNote> {
    let out = ArrayList<LessonNote>()
    for (x in src) {
        out.add(x)
    }
    return out
}

// ============================================================
// 动作层（读写盘；单测只覆盖纯函数）
// ============================================================

/** 读回该项目已有的经验（文件不存在/读不了给空表） */
public func loadLessons(projDir: String, projName: String): ArrayList<LessonNote> {
    let p = notesPathOf(projDir, projName)
    if (!exists(Path(p))) {
        return ArrayList<LessonNote>()
    }
    var text = ""
    try {
        text = String.fromUtf8(File.readFrom(p))
    } catch (e: Exception) {
        let _ = e
        return ArrayList<LessonNote>()
    }
    return parseLessons(text)
}

/**
 * 追加一条经验（**幂等**：同标题只累加次数）。
 *
 * 返回给人看的说明：`added:<标题>` / `merged:<标题>（第 N 次）` / `error:…`
 */
public func appendLesson(projDir: String, projName: String, n: LessonNote): String {
    if (oneLineOf(n.title).size == 0) {
        return "error:经验必须有标题"
    }
    n.symptom = oneLineOf(n.symptom)
    n.cause = oneLineOf(n.cause)
    n.repro = oneLineOf(n.repro)
    n.fix = oneLineOf(n.fix)
    if (n.project.size == 0) {
        n.project = projName
    }
    let p = notesPathOf(projDir, projName)
    // 建目录：**先判存在再用 recursive**（§4-89：已存在时 recursive 也会抛）
    let dir = lqDirOf(projDir) + cjhPathSep() + NOTES_SUBDIR
    if (!exists(Path(dir))) {
        try {
            Directory.create(Path(dir), recursive: true)
        } catch (e: Exception) {
            return "error:建目录失败：${e}"
        }
    }
    let existing = loadLessons(projDir, projName)
    let before = ArrayList<LessonNote>()
    for (x in existing) {
        before.add(x)
    }
    let incoming = ArrayList<LessonNote>()
    incoming.add(n)
    let merged = mergeLessons(before, incoming)
    try {
        File.writeTo(p, lessonsFileText(merged).toArray())
    } catch (e: Exception) {
        return "error:写盘失败：${e}"
    }
    if (merged.size == before.size) {
        match (findLessonByKey(merged, lessonKeyOf(n))) {
            case Some(idx) => return "merged:${n.title}（第 ${merged[idx].occurrences} 次）"
            case None => return "merged:${n.title}"
        }
    }
    return "added:${n.title}"
}

/** 按去重键找下标 */
func findLessonByKey(list: ArrayList<LessonNote>, key: String): Option<Int64> {
    var i: Int64 = 0
    while (i < Int64(list.size)) {
        if (lessonKeyOf(list[i]) == key) {
            return Some(i)
        }
        i += 1
    }
    return None
}

/** 全量导出（报告/工具用）：所有经验渲染成一段 markdown */
public func renderLessonsMd(projName: String, lessons: ArrayList<LessonNote>): String {
    var text = "# ${projName} 本地经验\n\n"
    if (lessons.size == 0) {
        text += "（还没有记录任何经验）\n"
        return text
    }
    for (x in lessons) {
        text += renderLesson(x) + "\n"
    }
    return text
}

/** 经验 → JSON（回投界面/命令行用） */
public func lessonToJson(n: LessonNote): JsonObject {
    var o = JsonObject()
    o.put("title", JsonString(n.title))
    o.put("symptom", JsonString(n.symptom))
    o.put("cause", JsonString(n.cause))
    o.put("repro", JsonString(n.repro))
    o.put("fix", JsonString(n.fix))
    o.put("occurrences", JsonInt(n.occurrences))
    o.put("project", JsonString(n.project))
    o.put("at", JsonString(n.at))
    o.put("archivedRef", JsonString(n.archivedRef))
    return o
}

/**
 * 纯函数：从一段 JSON 里解出一条经验（`--body <文件>` 用；0.39.55）。
 *
 * **为什么需要它**：仓颉程序在 Windows 上**接不了非 ASCII 的 argv**
 * （`IllegalArgumentException: Invalid unicode scalar value`，在 `main(args)` 之前就抛，见 AGENTS §4-119）。
 * 而经验内容天然是中文 ⇒ 只能让 agent 先把 JSON 写进文件（bash 写盘是 UTF-8 字节），
 * 命令再用 `--body <文件>` 读进来。**路径本身仍要 ASCII**（同样受 argv 限制）。
 *
 * 宽容：JSON 坏了/字段缺了都不抛，缺的留空（标题为空时上层会拒绝写盘）。
 */
public func parseLessonBody(text: String): LessonNote {
    let n = LessonNote()
    var obj: JsonObject
    try {
        obj = JsonValue.fromStr(text).asObject()
    } catch (e: Exception) {
        let _ = e
        return n
    }
    n.title = lessonStrOf(obj, "title")
    n.symptom = lessonStrOf(obj, "symptom")
    n.cause = lessonStrOf(obj, "cause")
    n.repro = lessonStrOf(obj, "repro")
    n.fix = lessonStrOf(obj, "fix")
    return n
}

/** 取 JSON 里某键的字符串值（不存在/类型不对给 ""） */
func lessonStrOf(obj: JsonObject, key: String): String {
    match (obj.get(key)) {
        case Some(v) =>
            try {
                return v.asString().getValue()
            } catch (e: Exception) {
                let _ = e
                return ""
            }
        case None => return ""
    }
}
