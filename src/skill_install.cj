package lingqu

import cjTauri.* // bytesToHex
import std.collection.*
import std.crypto.digest.*
import std.fs.*
import stdx.crypto.digest.*
import stdx.encoding.json.*
import stdx.net.http.*

/*
 * ① 把 `t2h-ohos-port` 技能装进 cjh（2026-11-01，AI 接入计划第 1 步）。
 *
 * 为什么需要这一步：cjh 的「技能」是 `~/.cjh/skills/<name>.md` 这种 Markdown 资产，
 * frontmatter 声明 name/description（可选 tools），正文会被**拼进 system prompt**。
 * 而本仓的 `skills/t2h-ohos-port/SKILL.md` 只是躺在仓库里——cjh 从来没见过它，
 * 所以 AI 助手对"鸿蒙移植的坑、签名配方、工具链差异"一无所知（只能靠模型自己的通用知识）。
 *
 * 设计要点（照 cjh 的既有约定来，不自创）：
 *   · 技能文件 = `<skills>/t2h-ohos-port.md`；正文里的 `references/x.md` 相对链接在 cjh 侧
 *     是**按 agent 的 cwd 解析**的，必然读不到 → 安装时改写成**绝对路径**（本函数纯字符串，可单测）
 *   · references 放进 `<skills>/.t2h-ohos-port/references/`：以 `.` 开头的隐藏子目录，
 *     不会被 cjh 的 `skills` 下的 `*.md` 扫描当成第二个技能
 *   · `enabled_skills` 为空 = **全部启用**（cjh 的白名单语义），所以默认**不改 settings.json**；
 *     只有当白名单非空且不含本技能时才提示"需要手动加进去"
 *   · 状态判定用**内容 SHA256**比对，不看时间戳（时间戳会被 checkout/复制骗过）
 */

public let SKILL_NAME: String = "t2h-ohos-port"
public let SKILL_FILE_NAME: String = "t2h-ohos-port.md"
/** references 目录在 skills 下的隐藏子目录名（`.t2h-ohos-port/references`） */
public let SKILL_REF_HIDDEN: String = ".t2h-ohos-port"

/** cjh 的技能目录（`<home>/.cjh/skills`）；home 空串 → 空串（调用方据此如实报错） */
public func cjhSkillsDirOf(home: String): String {
    if (home == "") {
        return ""
    }
    return home + cjhPathSep() + ".cjh" + cjhPathSep() + "skills"
}

/** 安装后的技能文件路径 */
public func skillTargetPathOf(home: String): String {
    let dir = cjhSkillsDirOf(home)
    if (dir == "") {
        return ""
    }
    return dir + cjhPathSep() + SKILL_FILE_NAME
}

/** 安装后的 references 目录（绝对路径；也用于把 SKILL.md 里的相对链接改写过去） */
public func skillRefDirOf(home: String): String {
    let dir = cjhSkillsDirOf(home)
    if (dir == "") {
        return ""
    }
    return dir + cjhPathSep() + SKILL_REF_HIDDEN + cjhPathSep() + "references"
}

/**
 * 纯函数：把 SKILL.md 里的相对引用改写成本机绝对路径。
 *
 * 两种形态都要管：
 *   · Markdown 链接 `[签名](references/signing.md)` —— 真正会被点击/被 agent 读的是这个
 *   · 正文裸提 `references/pitfalls.md` —— 也改，免得 agent 照着相对路径去 cwd 里找
 */
public func rewriteSkillLinks(body: String, refDirAbs: String): String {
    if (refDirAbs == "") {
        return body
    }
    var out = body.replace("(references/", "(" + refDirAbs + "/")
    out = out.replace(" references/", " " + refDirAbs + "/")
    return out
}

/**
 * 纯函数：技能状态三态。
 *
 *   missing   —— 没装
 *   outdated  —— 装了但内容与来源不一致（仓库里的 SKILL.md 更新过 / 手工改过）
 *   installed —— 已装且内容一致
 */
public func skillStateOf(hasInstalled: Bool, installedHash: String, sourceHash: String): String {
    if (!hasInstalled || installedHash == "") {
        return "missing"
    }
    if (sourceHash == "" || installedHash != sourceHash) {
        return "outdated"
    }
    return "installed"
}

/**
 * 纯函数：`enabled_skills` 白名单语义的说明（cjh：空 = 全部启用，非空 = 白名单）。
 *
 * 这一步很重要——**不能想当然地往白名单里塞一项**：白名单一旦非空，
 * 不在名单里的其它技能（比如 cjh 自带的仓颉知识技能）会统统被关掉。
 */
public func skillEnableNoteOf(whitelist: ArrayList<String>): String {
    if (whitelist.size == 0) {
        return "enabled_skills 为空 = cjh 全部启用，装好即生效（不需要改 settings.json）"
    }
    for (n in whitelist) {
        if (n == SKILL_NAME) {
            return "enabled_skills 白名单已包含 ${SKILL_NAME}，可生效"
        }
    }
    return "enabled_skills 白名单非空但不含 ${SKILL_NAME}——需要在 ~/.cjh/settings.json 里加进去才生效" +
        "（当前白名单：${joinNames(whitelist)}）"
}

/** 名字列表拼成 `a、b、c`（错误提示里要能看清到底有哪些） */
func joinNames(names: ArrayList<String>): String {
    var text = ""
    for (n in names) {
        if (text != "") {
            text += "、"
        }
        text += n
    }
    return text
}

/** 读 `~/.cjh/settings.json` 里的 `enabled_skills`（读不到给空表 = 全部启用） */
public func readEnabledSkills(settingsPath: String): ArrayList<String> {
    let out = ArrayList<String>()
    if (settingsPath == "" || !exists(Path(settingsPath))) {
        return out
    }
    try {
        let text = String.fromUtf8(File.readFrom(settingsPath))
        let root = JsonValue.fromStr(text)
        let arr = objFieldOf(root, "enabled_skills")
        match (arr.kind()) {
            case JsonKind.JsArray =>
                var i: Int64 = 0
                while (i < arr.asArray().size()) {
                    let e = arr.asArray()[i]
                    match (e.kind()) {
                        case JsonKind.JsString => out.add(e.asString().getValue())
                        case _ => ()
                    }
                    i += 1
                }
            case _ => ()
        }
    } catch (e: Exception) {
        let _ = e
    }
    return out
}

/** `~/.cjh/settings.json` 路径（home 空 → 空串） */
public func cjhSettingsPathOf(home: String): String {
    if (home == "") {
        return ""
    }
    return home + cjhPathSep() + ".cjh" + cjhPathSep() + "settings.json"
}

/** 当前用户 home（USERPROFILE 优先，Unix 用 HOME） */
public func userHomeDir(): String {
    let h = firstNonEmptyEnv(["USERPROFILE", "HOME"])
    if (h == "") {
        return ""
    }
    return hostPath(h)
}

/** 技能正文的 SHA256 十六进制（纯字节计算，便于对"来源内容"与"已装内容"做同口径比较） */
public func skillHashOfBytes(bytes: Array<Byte>): String {
    return bytesToHex(digest(SHA256(), bytes))
}

/** 读一份文件算哈希；读不到回空串 */
public func skillHashOfFile(p: String): String {
    if (p == "" || !exists(Path(p))) {
        return ""
    }
    try {
        return skillHashOfBytes(File.readFrom(p))
    } catch (e: Exception) {
        let _ = e
        return ""
    }
}

/**
 * 纯函数：从 base 目录起**逐级向上**给出 `skills/t2h-ohos-port` 的候选路径。
 *
 * 别用 `vendorCandidatesFrom` —— 那个是给 vendor/cjh 用的，返回形如 `<dir>/vendor/cjh/<平台>`，
 * 与技能目录不是一个形状（0.32.0 第一版就错用了它，结果开发期永远找不到仓库里的技能）。
 * 末尾分隔符归一；空 base 不产生候选。
 */
public func skillSourceCandidates(base: String, levels: Int64): ArrayList<String> {
    let out = ArrayList<String>()
    if (base == "" || levels <= 0) {
        return out
    }
    var cur = base
    // 末尾分隔符归一（`E:\repo\` 与 `E:\repo` 等价）。`cur[i]` 是 Byte，只能和整数字面量比
    // （与 String 比会报 "operator func ==(right: Struct-String)" —— 0.32.0 编译期踩到过）
    while (cur.size > 0) {
        let bytes = cur.toArray()
        if (bytes[bytes.size - 1] == 92 || bytes[bytes.size - 1] == 47) {
            cur = cur[0..(cur.size - 1)]
        } else {
            break
        }
    }
    var i: Int64 = 0
    while (i < levels && cur.size > 0) {
        out.add(cur + cjhPathSep() + "skills" + cjhPathSep() + SKILL_NAME)
        let idx = lastSepIndex(cur)
        if (idx <= 0) {
            break
        }
        cur = cur[0..idx]
        i += 1
    }
    return out
}

/**
 * 技能来源目录（含 `SKILL.md` 与 `references/` 的那一层）。
 *
 * 顺序：`LINGQU_SKILL_SRC`（显式指定）→ `LINGQU_HOME/skills/t2h-ohos-port`（便携包根）
 *       → 当前目录上溯 6 层找 `skills/t2h-ohos-port`（开发期）。
 * 都找不到回空串——此时走"内嵌 SKILL.md"（只有正文、没有 references），如实告知。
 */
public func skillSourceDir(): String {
    let env = firstNonEmptyEnv(["LINGQU_SKILL_SRC"])
    if (env != "" && exists(Path(hostPath(env) + cjhPathSep() + "SKILL.md"))) {
        return hostPath(env)
    }
    let home = firstNonEmptyEnv(["LINGQU_HOME"])
    if (home != "") {
        let p = hostPath(home) + cjhPathSep() + "skills" + cjhPathSep() + SKILL_NAME
        if (exists(Path(p + cjhPathSep() + "SKILL.md"))) {
            return p
        }
    }
    // 开发期：从当前目录上溯（最多 6 层）
    let cwd = getWorkingDirectoryOr("")
    for (cand in skillSourceCandidates(cwd, 6)) {
        if (exists(Path(cand + cjhPathSep() + "SKILL.md"))) {
            return cand
        }
    }
    return ""
}

/** 内嵌的 SKILL.md 正文（单文件产物里没有 skills/ 目录时用；空存根 → 空串） */
public func embeddedSkillBody(): String {
    if (PACKED_SKILL_B64 == "") {
        return ""
    }
    try {
        return decodeBase64(PACKED_SKILL_B64)
    } catch (e: Exception) {
        let _ = e
        return ""
    }
}

/** references 目录下的文件名列表（没有目录回空表） */
public func skillRefFiles(refDir: String): ArrayList<String> {
    let out = ArrayList<String>()
    if (refDir == "" || !exists(Path(refDir))) {
        return out
    }
    var entries: Array<FileInfo>
    try {
        entries = Directory.readFrom(refDir)
    } catch (e: Exception) {
        let _ = e
        return out
    }
    for (info in entries) {
        if (!info.isDirectory() && info.name.endsWith(".md")) {
            out.add(info.name)
        }
    }
    return out
}

/** 安装结果（命令层据此回投界面与 ui_report） */
public class SkillInstallResult {
    public var ok: Bool = false
    public var state: String = "missing"
    public var sourceDir: String = ""
    public var sourceKind: String = ""      // repo / embedded / env
    public var targetPath: String = ""
    public var refDir: String = ""
    public var refCount: Int64 = 0
    public var backupPath: String = ""
    public var note: String = ""
    public var error: String = ""
}

/**
 * 纯/半纯函数：本次**应该装上去的正文**（来源正文 + 链接改写 + 必要说明）。
 *
 * 关键：安装与"期望哈希"必须走**同一条**生成路径，否则永远报 `outdated`
 * （0.32.0 第一版就是这样：安装时改写了链接，比较时却拿原始来源的哈希去比）。
 * 返回空串表示来源不可用（调用方据此报错或判 outdated）。
 */
public func skillFinalBodyOf(home: String): String {
    var body = ""
    let srcDir = skillSourceDir()
    if (srcDir != "") {
        try {
            body = String.fromUtf8(File.readFrom(srcDir + cjhPathSep() + "SKILL.md"))
        } catch (e: Exception) {
            let _ = e
            return ""
        }
    } else {
        body = embeddedSkillBody()
        if (body == "") {
            return ""
        }
        body += "\n\n> 注：本次装的是**内嵌正文**（没有随包 references 下的 md）。" +
            "要带参考文档就在仓库里跑一次安装，或置 LINGQU_SKILL_SRC 指过去重装。\n"
    }
    if (!body.startsWith("---")) {
        return ""
    }
    return rewriteSkillLinks(body, skillRefDirOf(home))
}

/**
 * 安装技能：把 SKILL.md（链接改写为绝对路径）写到 `~/.cjh/skills/t2h-ohos-port.md`，
 * 再把 `references` 下的 `*.md` 拷到 `~/.cjh/skills/.t2h-ohos-port/references/`。
 *
 * 幂等：每次都整体覆盖（内容由来源决定），覆盖前留 `.bak`；references 目录里的旧文件不删
 * （多留一份不影响——cjh 只扫 `skills` 下的 `*.md`，嵌套目录不会被当成技能）。
 */
public func installSkill(home: String): SkillInstallResult {
    let r = SkillInstallResult()
    let target = skillTargetPathOf(home)
    let refDir = skillRefDirOf(home)
    if (target == "") {
        r.error = "拿不到用户主目录（USERPROFILE/HOME 为空）——无法定位 ~/.cjh/skills"
        return r
    }
    r.targetPath = target
    r.refDir = refDir

    // ① 正文：与"期望哈希"共用同一条生成路径
    let srcDir = skillSourceDir()
    r.sourceDir = srcDir
    r.sourceKind = if (srcDir != "") {
        if (firstNonEmptyEnv(["LINGQU_SKILL_SRC"]) != "") { "env" } else { "repo" }
    } else {
        "embedded"
    }
    let finalBody = skillFinalBodyOf(home)
    if (finalBody == "") {
        r.error = "找不到可用的技能来源：仓库里没有 skills/t2h-ohos-port/SKILL.md，" +
            "二进制里也没有内嵌副本（可用 LINGQU_SKILL_SRC 指向仓库的 skills/t2h-ohos-port）"
        return r
    }

    // ② 建目录 + 备份旧文件
    try {
        if (!exists(Path(cjhSkillsDirOf(home)))) {
            Directory.create(Path(cjhSkillsDirOf(home)), recursive: true)
        }
        if (exists(Path(target))) {
            r.backupPath = target + ".bak"
            File.writeTo(r.backupPath, File.readFrom(target))
        }
    } catch (e: Exception) {
        r.error = "准备技能目录失败：${e}"
        return r
    }

    // ③ 拷 references（先拷再改写链接，保证链接指向的文件真的在）
    if (srcDir != "") {
        let srcRefs = srcDir + cjhPathSep() + "references"
        for (name in skillRefFiles(srcRefs)) {
            try {
                if (!exists(Path(refDir))) {
                    Directory.create(Path(refDir), recursive: true)
                }
                File.writeTo(refDir + cjhPathSep() + name, File.readFrom(srcRefs + cjhPathSep() + name))
                r.refCount += 1
            } catch (e: Exception) {
                // 单个参考文档失败不致命，但要在 note 里留痕（别静默）
                r.note += "（references/${name} 拷贝失败）"
            }
        }
    }

    // ④ 写技能文件（finalBody 已在上面按"安装=比较同一条路径"生成，含链接改写）
    try {
        File.writeTo(target, finalBody.toArray())
    } catch (e: Exception) {
        r.error = "写技能文件失败：${e}"
        return r
    }

    // ⑤ 复算状态（用写入后的真实内容与来源比）
    let writtenHash = skillHashOfFile(target)
    let sourceHash = skillHashOfBytes(finalBody.toArray())
    r.state = skillStateOf(true, writtenHash, sourceHash)
    r.ok = r.state == "installed"
    if (!r.ok) {
        r.note += "（写完复核哈希不一致——可能被别的进程改写？）"
    }
    return r
}

/**
 * 问 cjh「你看到这个技能了吗」：GET /api/skills，解析返回里的 names。
 *
 * 为什么要这一步：装到磁盘 ≠ cjh 真的加载了（技能可能因为 frontmatter 坏了、或白名单关掉而不可见）。
 * 探针拿不到 cjh（没在跑）时返回空表，调用方如实标"未验证"。
 */
public func cjhSkillNames(port: Int64): ArrayList<String> {
    let out = ArrayList<String>()
    if (port <= 0) {
        return out
    }
    var body = ""
    try {
        let client = ClientBuilder()
            .readTimeout(Duration.second * 2)
            .writeTimeout(Duration.second * 2)
            .build()
        let req = HttpRequestBuilder().get().url("http://127.0.0.1:${port}/api/skills").build()
        let resp = client.send(req)
        if (Int64(resp.status) != 200) {
            resp.close()
            return out
        }
        // 响应体是流：复用 cjh_host 里的 readHttpBody（技能清单很小，64KB 上限够）
        body = readHttpBody(resp.body, 64 * 1024)
        resp.close()
    } catch (e: Exception) {
        let _ = e
        return out
    }
    try {
        let root = JsonValue.fromStr(body)
        // 兼容两种形态：{skills:[{name:...}]} 或 {items:[...]}；解析用 match（JsonKind 不能直接比 ==）
        var arr = objFieldOf(root, "skills")
        var isArr = false
        match (arr.kind()) {
            case JsonKind.JsArray => isArr = true
            case _ => isArr = false
        }
        if (!isArr) {
            arr = objFieldOf(root, "items")
        }
        match (arr.kind()) {
            case JsonKind.JsArray =>
                var i: Int64 = 0
                while (i < arr.asArray().size()) {
                    let e = arr.asArray()[i]
                    let name = jsonStrField(e, "name")
                    if (name != "") {
                        out.add(name)
                    }
                    i += 1
                }
            case _ => ()
        }
    } catch (e: Exception) {
        let _ = e
    }
    return out
}

