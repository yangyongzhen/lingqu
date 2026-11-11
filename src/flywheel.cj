package lingqu

import std.collection.*
import std.fs.*
import stdx.encoding.json.*
import lingqu.port.*

/*
 * 飞轮阶段 4：用户级认知层（0.39.113）。
 *
 * 要解决的问题（docs/AI自进化飞轮.md §8 阶段 4）：经验裁决入库后，用户若没登录 atomgit、
 * 也不想给 lingqu 源仓提 PR，这条经验就**只对本工程有效**，下个工程又从零撞一遍。
 * 「贡献公共仓」是可选的分享，**本地飞轮必须是默认自用**——两条轨道分开，别把
 * "没账号" 当成 "不想积累"。
 *
 * 本地认知层 = `~/.lingqu/flywheel/`（`LINGQU_FLYWHEEL_DIR` 可覆盖，探针与多"用户"用它）：
 *   fingerprints.json  用户级错误指纹（**数据**：`diagnose` 会把它合并进内置库）
 *   lessons.md         用户级经验本（文本：跨工程累积、按 `lessonKeyOf` 去重）
 *   rules.json         规则**清单**（只读说明，见下面的诚实边界）
 *   skills/            用户级技能（照旧 `t2h:skill` → `~/.cjh/skills/`，这里只留位）
 *
 * 诚实边界：`R2-PORT-*` 规则是确定性的**文本变换函数**（`src/port/port.cj`），
 * 一份 JSON 没法安全地执行它们 ⇒ 用户级层**不装可执行规则**，只装指纹与经验/技能。
 * 想加规则仍得改仓（`--to repo` 出草稿 PR）。把安全边界让给"便利"才是真的坑。
 *
 * 合并口径（纯函数在 `lingqu.port` 的 diagnose.cj 里，同类知识放一处）：
 * 用户级指纹排前 + 同 id 用用户版本。
 */

/** 覆盖用户级认知层目录的环境变量（探针/多用户/测试都靠它，别去改真用户的 home） */
public let FLYWHEEL_ENV_DIR: String = "LINGQU_FLYWHEEL_DIR"

public let USER_FP_FILE: String = "fingerprints.json"
public let USER_RULES_FILE: String = "rules.json"
public let USER_LESSONS_FILE: String = "lessons.md"
public let USER_SKILLS_SUBDIR: String = "skills"

/** `t2h:notes --action archive --to <目标>` 的两个目标 */
public let ARCHIVE_TO_USER: String = "user"
public let ARCHIVE_TO_REPO: String = "repo"

/**
 * 纯函数：剥掉末尾路径分隔符（`/` 与 `\` **两种都认**——`§4-26` 的同族：只认一种必翻车）。
 * 盘符根（`C:\`）不剥：剥了就变成 `C:`，那已经不是目录了。
 */
func stripTrailingSepOf(p: String): String {
    var s = p
    var guard: Int64 = 0
    while (guard < 8 && s.size > 1) {
        if (!(s.endsWith("/") || s.endsWith("\\"))) {
            break
        }
        let bs = s.toArray()
        if (bs.size == 3 && bs[1] == 58) {
            break
        }
        s = s[0..(s.size - 1)]
        guard += 1
    }
    return s
}

/**
 * 纯函数：用户级认知层目录。
 *
 * `override` 非空就用它（测试/探针/多"用户"都走这条），否则 `home/.lingqu/flywheel`。
 * `home` 为空（容器里 USERPROFILE 与 HOME 都没设）→ 空串，**调用方必须如实报错**，
 * 不许默默写进当前工作目录（那会把"用户级"降级成"工程级"，还看不出来）。
 */
public func userFlywheelDirOf(override: String, home: String): String {
    let o = override.trimAscii()
    if (o.size > 0) {
        return stripTrailingSepOf(o)
    }
    let h = home.trimAscii()
    if (h.size == 0) {
        return ""
    }
    let sep = cjhPathSep()
    return stripTrailingSepOf(h) + sep + ".lingqu" + sep + "flywheel"
}

/** 动作层：本机用户级认知层目录（`LINGQU_FLYWHEEL_DIR` 优先，否则 `~/.lingqu/flywheel`） */
public func userFlywheelDir(): String {
    return userFlywheelDirOf(envOr(FLYWHEEL_ENV_DIR, ""), userHomeDir())
}

public func userFingerprintsPathOf(dir: String): String {
    if (dir.size == 0) {
        return ""
    }
    return dir + cjhPathSep() + USER_FP_FILE
}

public func userLessonsPathOf(dir: String): String {
    if (dir.size == 0) {
        return ""
    }
    return dir + cjhPathSep() + USER_LESSONS_FILE
}

public func userRulesPathOf(dir: String): String {
    if (dir.size == 0) {
        return ""
    }
    return dir + cjhPathSep() + USER_RULES_FILE
}

public func userSkillsDirOf(dir: String): String {
    if (dir.size == 0) {
        return ""
    }
    return dir + cjhPathSep() + USER_SKILLS_SUBDIR
}

public func userFingerprintsPath(): String {
    return userFingerprintsPathOf(userFlywheelDir())
}

public func userLessonsPath(): String {
    return userLessonsPathOf(userFlywheelDir())
}

/** 动作层：读用户级指纹 JSON 文本（读不到就是 ""；条数由调用方回投，别静默） */
public func readUserFingerprintsText(): String {
    return readTextOrEmpty(userFingerprintsPath())
}

/** 纯函数：用户级经验本全文（头 + 每条一段；沿用 `renderLesson` 的段落格式） */
public func renderUserLessonsFile(list: ArrayList<LessonNote>): String {
    var s = "# 灵渠用户级经验本（跨工程 · 本机自用）\n\n"
    s += "> 由 `lingqu-cli notes --action archive --to user` 累积，同一个坑自动去重。\n"
    s += "> **重跑归档不会让「次数」虚增**（归档是幂等动作）。\n"
    s += "> 想分享给所有人：用 `--to repo` 出草稿 PR，或直接在本仓提 PR。\n\n"
    for (n in list) {
        s += renderLesson(n) + "\n"
    }
    return s
}

/**
 * 纯函数：并入用户级经验本——同 `lessonKeyOf` **只留已有的那条，不累加次数**。
 *
 * 为什么不累加：归档是**幂等**动作。要是每跑一次 `archive` 就把次数 +1，
 * 用户看到的"出现 5 次"只是他手勤，而不是这个坑真的常见（假数据，§4-94 同族）。
 */
public func unionUserLessons(existing: ArrayList<LessonNote>,
    incoming: ArrayList<LessonNote>): ArrayList<LessonNote> {
    let out = ArrayList<LessonNote>()
    let seen = HashSet<String>()
    for (x in existing) {
        let k = lessonKeyOf(x)
        if (k.size == 0 || seen.contains(k)) {
            continue
        }
        seen.add(k)
        out.add(x)
    }
    for (x in incoming) {
        let k = lessonKeyOf(x)
        if (k.size == 0 || seen.contains(k)) {
            continue
        }
        seen.add(k)
        out.add(x)
    }
    return out
}

/** 建目录（已存在不算错，§4-89；建完核一次 exists，失败别假装成功） */
func ensureUserDirOf(dir: String): Bool {
    if (exists(Path(dir))) {
        return true
    }
    try {
        Directory.create(Path(dir), recursive: true)
    } catch (e: Exception) {
        let _ = e
    }
    return exists(Path(dir))
}

/** 动作层：把一批经验并入 `~/.lingqu/flywheel/lessons.md`；返回 `ok:` / `skip:` / `error:` */
public func mergeIntoUserLessons(lessons: ArrayList<LessonNote>): String {
    if (lessons.size == 0) {
        return "skip:没有可并入用户级认知层的经验"
    }
    let dir = userFlywheelDir()
    if (dir.size == 0) {
        return "error:拿不到用户主目录（USERPROFILE/HOME 为空）——无法定位用户级认知层"
    }
    let p = userLessonsPathOf(dir)
    let old = parseLessons(readTextOrEmpty(p))
    let merged = unionUserLessons(old, lessons)
    if (!ensureUserDirOf(dir)) {
        return "error:建用户级目录失败：${dir}"
    }
    try {
        File.writeTo(p, renderUserLessonsFile(merged).toArray())
    } catch (e: Exception) {
        return "error:写用户级经验本失败：${e}"
    }
    let added = Int64(merged.size) - Int64(old.size)
    return "ok:${p}（用户级经验 ${merged.size} 条，本次新增 ${added}）"
}

/**
 * 动作层：把**本工程已归档的经验**并进用户级经验本。
 *
 * 为什么读归档件而不是读主页：`archiveLessons` 已经把已入库的条目从主文件挪走了，
 * 主文件里只剩待裁决的（`§4-33`：产出方与消费方对同一份落档要有一致的认知）。
 */
public func mergeArchivedIntoUserBook(projDir: String, projName: String): String {
    let t = readTextOrEmpty(archivedNotesPathOf(projDir, projName))
    if (t.trimAscii().size == 0) {
        return "skip:本工程还没有已归档的经验（先在条目下补归档引用再试）"
    }
    return mergeIntoUserLessons(parseLessons(t))
}

/** 用户级指纹写回结果（把"新增几条 / 覆盖几条"当证据回投，别只说成功） */
public class FpUpsertResult {
    public var text: String = ""
    public var added: Int64 = 0
    public var replaced: Int64 = 0
    public var total: Int64 = 0
}

/** 纯函数：一条指纹的**单行** JSON（走对象 `toJsonString()` 保证转义，再压掉换行） */
func fingerprintJsonLineOf(fp: Fingerprint): String {
    let o = JsonObject()
    o.put("id", JsonString(fp.id))
    o.put("marker", JsonString(fp.marker))
    o.put("rootCause", JsonString(fp.rootCause))
    o.put("fix", JsonString(fp.fix))
    o.put("ruleId", JsonString(fp.ruleId))
    o.put("patchKind", JsonString(fp.patchKind))
    return o.toJsonString().replace("\r\n", " ").replace("\n", " ").replace("\r", " ")
}

/** 纯函数：渲染用户级指纹文件（一条一行，便于 `git diff` 看人眼；末尾留换行） */
public func renderUserFingerprints(list: ArrayList<Fingerprint>): String {
    var s = "[\n"
    var i: Int64 = 0
    let n = Int64(list.size)
    while (i < n) {
        s += "  " + fingerprintJsonLineOf(list[i])
        if (i + 1 < n) {
            s += ","
        }
        s += "\n"
        i += 1
    }
    return s + "]\n"
}

/**
 * 纯函数：把一批指纹并进现有文件文本（同 id **覆盖**，新 id 追加）。
 *
 * 同一批里重复写同一个 id：**先写的算**（后写的当笔误忽略，不吵不闹）。
 */
public func upsertUserFingerprints(existingText: String,
    incoming: ArrayList<Fingerprint>): FpUpsertResult {
    let res = FpUpsertResult()
    let old = parseFingerprintsJson(existingText)
    let byId = HashMap<String, Fingerprint>()
    for (x in incoming) {
        let id = x.id.trimAscii()
        if (id.size > 0 && !byId.contains(id)) {
            byId.add(id, x)
        }
    }
    let out = ArrayList<Fingerprint>()
    let seen = HashSet<String>()
    for (x in old) {
        let id = x.id.trimAscii()
        if (id.size == 0 || seen.contains(id)) {
            continue
        }
        seen.add(id)
        match (byId.get(id)) {
            case Some(nv) =>
                out.add(nv)
                res.replaced += 1
            case None => out.add(x)
        }
    }
    for (x in incoming) {
        let id = x.id.trimAscii()
        if (id.size == 0 || seen.contains(id)) {
            continue
        }
        seen.add(id)
        out.add(x)
        res.added += 1
    }
    res.text = renderUserFingerprints(out)
    res.total = Int64(out.size)
    return res
}

/** 动作层：写回用户级 `fingerprints.json`；返回 `ok:` / `skip:` / `error:` */
public func addUserFingerprints(list: ArrayList<Fingerprint>): String {
    if (list.size == 0) {
        return "skip:没有要写的指纹"
    }
    let dir = userFlywheelDir()
    if (dir.size == 0) {
        return "error:拿不到用户主目录（USERPROFILE/HOME 为空）——无法定位用户级认知层"
    }
    let p = userFingerprintsPathOf(dir)
    let up = upsertUserFingerprints(readTextOrEmpty(p), list)
    if (!ensureUserDirOf(dir)) {
        return "error:建用户级目录失败：${dir}"
    }
    try {
        File.writeTo(p, up.text.toArray())
    } catch (e: Exception) {
        return "error:写用户级指纹失败：${e}"
    }
    return "ok:${p}（新增 ${up.added} / 覆盖 ${up.replaced} / 共 ${up.total} 条）"
}

/**
 * 纯函数：解析 `--body <文件>` 里的用户级指纹。
 *
 * 三种写法都认：单条对象 / 数组 / `{"fingerprints":[…]}`（与手写库文件的形态一致）。
 * 缺 `id` 自动编号（`FP-U001` 起）——用户手写时最容易被这一步卡住；
 * 缺 `marker` **直接报错**：没有触发串的指纹永远不会命中，写进去只是让"我有 12 条指纹"
 * 看起来很美（§4-94 同族：不许拿看起来像数据的假值充数）。
 */
public func parseUserFpBody(text: String,
    existing: ArrayList<Fingerprint>): (ArrayList<Fingerprint>, String) {
    let out = ArrayList<Fingerprint>()
    if (text.trimAscii().size == 0) {
        return (out, "error:--body 指向的指纹 JSON 是空的")
    }
    var v: JsonValue
    try {
        v = JsonValue.fromStr(text)
    } catch (e: Exception) {
        return (out, "error:指纹 JSON 解析失败：${e}")
    }
    var arr = JsonArray()
    match (v.kind()) {
        case JsonKind.JsObject =>
            let o = v.asObject()
            match (o.get(USER_FP_CONTAINER_KEY)) {
                case Some(k) =>
                    match (k.kind()) {
                        case JsonKind.JsArray => arr = k.asArray()
                        case _ => return (out, "error:${USER_FP_CONTAINER_KEY} 必须是数组")
                    }
                case None => arr.add(v)
            }
        case JsonKind.JsArray => arr = v.asArray()
        case _ => return (out, "error:指纹 JSON 顶层只能是对象或数组")
    }
    // 编号要在**已有 + 本次已收**之上算，否则一批里两条都会拿到 FP-U001
    let assigned = ArrayList<Fingerprint>()
    for (x in existing) {
        assigned.add(x)
    }
    var i: Int64 = 0
    while (i < arr.size()) {
        match (arr[i].kind()) {
            case JsonKind.JsObject =>
                let o = arr[i].asObject()
                if (fpStrFieldOf(o, "id").trimAscii().size == 0) {
                    o.put("id", JsonString(nextUserIdOf(assigned)))
                }
                match (fingerprintFromJson(o)) {
                    case Some(fp) =>
                        out.add(fp)
                        assigned.add(fp)
                    case None => return (out, "error:第 ${i + 1} 条缺 marker（没有触发串的指纹永远不会命中）")
                }
            case _ => return (out, "error:第 ${i + 1} 条不是 JSON 对象")
        }
        i += 1
    }
    if (out.size == 0) {
        return (out, "error:这只 body 里一条指纹都没有")
    }
    return (out, "")
}

/**
 * 纯函数：`--to` 目标归一（空 → `user`；认不出 → 空串）。
 *
 * 认不出**必须**回空串：默默当成 `user` 的话，用户以为自己的经验进了仓库 PR 队列，
 * 实际只落在本机——这种"期望与结果不一致且不报错"最难查（§4-111 同族）。
 */
public func archiveTargetOf(raw: String): String {
    let t = raw.trimAscii()
    if (t.size == 0) {
        return ARCHIVE_TO_USER
    }
    if (t == ARCHIVE_TO_USER || t == ARCHIVE_TO_REPO) {
        return t
    }
    return ""
}
