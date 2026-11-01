package lingqu

import std.collection.*
import std.fs.*
import std.process.*
import stdx.encoding.json.*

/*
 * 从 Git 地址拉一个工程进来当"当前工程"（0.39.25）。
 *
 * 为什么要有它：以前"设置工程路径"只有两条路——手敲绝对路径（易错、还得知道工程在哪）与
 * 从最近列表里挑。而真实场景常常是"先把仓库 clone 下来再看"。这一层把它做成一条命令：
 *
 *   `t2h:git_clone { url: "https://…", dir?: "<父目录>", depth?: 1 }`
 *
 * 三条纪律：
 *   ① **参数一律走 argv，不经 shell**——URL 里可能有 `&`/`%`/`$`，交给 shell 必被吃掉
 *      （与 AGENTS §4-80 同源教训：`cmd /c` 会把 `&` 当分隔符）；
 *   ② URL **先过白名单**（https / ssh / git@host:path），并且拒绝以 `-` 开头
 *      （`git clone --upload-pack=…` 这类参数注入只靠 argv 还不够，得在入口挡掉）；
 *   ③ 目标目录**冲突不覆盖**：同名就在后面加 `-2`/`-3`，绝不把用户已有的目录当成空目录用。
 */

// ============================================================
// 一、纯函数层（可单测，不联网、不起进程）
// ============================================================

/** ASCII 小写（本包内私有：compiler 包的 `lowerAscii` 不在同一 package 里） */
func asciiLowerOf(s: String): String {
    let out = ArrayList<Byte>()
    for (b in s.toArray()) {
        if (b >= 65 && b <= 90) {
            out.add(UInt8(Int64(b) + 32))
        } else {
            out.add(b)
        }
    }
    return String.fromUtf8(out.toArray())
}

/** 判断一个 Git 地址是否允许拉取；不允许的返回原因（允许时返回 ""） */
public func gitUrlRejectReason(url: String): String {
    let u = url.trimAscii()
    if (u == "") {
        return "地址为空"
    }
    // argv 传参仍会被 git 自己当选项解析：`git clone --upload-pack=…` 就是这么被注入的
    if (u.startsWith("-")) {
        return "地址不能以 - 开头（会被 git 当成命令行选项）"
    }
    // 换行/制表进来基本就是想把一条命令拆成两条
    for (b in u.toArray()) {
        if (b == 10 || b == 13 || b == 9) {
            return "地址里不能有换行或制表符"
        }
        if (b == 32) {
            return "地址里不能有空格"
        }
    }
    let lower = asciiLowerOf(url)
    // 本地路径也允许（`file://` 或直接给目录），方便离线跑与自测
    if (lower.startsWith("https://") || lower.startsWith("http://")) {
        return ""
    }
    if (lower.startsWith("ssh://") || lower.startsWith("git://") || lower.startsWith("file://")) {
        return ""
    }
    // scp 形态：git@host:path（必须有 @ 且在 : 之前），别把 "a:b" 这种当远程
    var atIdx: Int64 = -1
    match (u.indexOf("@")) {
        case Some(i) => atIdx = i
        case None => ()
    }
    var colonIdx: Int64 = -1
    match (u.indexOf(":")) {
        case Some(i) => colonIdx = i
        case None => ()
    }
    if (atIdx > 0 && colonIdx > atIdx) {
        return ""
    }
    return "只认 https / ssh / git@host:path 形式的地址"
}

/**
 * 纯函数：这个字符串**像不像一个 Git 地址**（0.39.48）。
 *
 * 与 `gitUrlRejectReason` 分开：那个判"能不能拉"，这个判"是不是地址"。
 * 用途只有一个：用户把 `https://…` 填进"工程路径"时，给一句人话提示
 * （用户实测原话：「点迁移画像，提示扫描失败：路径不存在：https://gitcode.com/…」）。
 */
public func looksLikeGitUrl(s: String): Bool {
    let v = asciiLowerOf(s).trimAscii()
    if (v == "") {
        return false
    }
    if (v.startsWith("http://") || v.startsWith("https://") || v.startsWith("ssh://") ||
        v.startsWith("git://") || v.startsWith("file://")) {
        return true
    }
    // scp 形态 `git@host:path`：`@` 必须在第一个 `:` 之前。
    // 注意 `C:\work\x` 这种盘符路径会命中冒号但不命中 `@`，所以不会被误判成地址。
    var atIdx: Int64 = -1
    match (v.indexOf("@")) {
        case Some(i) => atIdx = i
        case None => ()
    }
    var colonIdx: Int64 = -1
    match (v.indexOf(":")) {
        case Some(i) => colonIdx = i
        case None => ()
    }
    return atIdx > 0 && colonIdx > atIdx
}

/** 从地址里取仓库目录名（去掉 `.git`，净化成合法目录名；取不到给 "repo"） */
public func repoDirNameOf(url: String): String {
    var u = url.trimAscii()
    // 尾随 `/` 与 `.git` 都去掉
    while (u.size > 0 && (u.endsWith("/") || u.endsWith("\\"))) {
        u = u[0..(u.size - 1)]
    }
    if (asciiLowerOf(u).endsWith(".git")) {
        u = u[0..(u.size - 4)]
    }
    // ① 先剥协议前缀（`https://` / `ssh://` / `file://` / `git://`）：剩下才是路径部分。
    //    不先剥的话，`ssh://git@host:2222/org/repo` 里的端口号会被当成路径分隔。
    let schemeSep = "://"
    match (u.indexOf(schemeSep)) {
        case Some(i) => u = u[(i + schemeSep.size)..u.size]
        case None => ()
    }
    // ② scp 形态 `git@host:path`：`@` 在第一个 `:` 之前 → 取 `:` 之后。
    //    注意**不能**把 `:` 一律当分隔符：`a:b*c` 这种名字会被切成 `b*c`。
    var atIdx: Int64 = -1
    match (u.indexOf("@")) {
        case Some(i) => atIdx = i
        case None => ()
    }
    match (u.indexOf(":")) {
        case Some(c) => if (atIdx >= 0 && c > atIdx) {
            u = u[(c + 1)..u.size]
        }
        case None => ()
    }
    // ③ 取最后一段（两种分隔符都认）
    let bytes = u.toArray()
    var cut: Int64 = -1
    for (i in 0..bytes.size) {
        let b = bytes[i]
        if (b == 47 || b == 92) {
            cut = i
        }
    }
    var name = if (cut >= 0) { u[(cut + 1)..u.size] } else { u }
    // 净化：只留字母数字与 `._-`，其余换 `_`（Windows 目录名不能有 `:?*"<>|`）
    let out = ArrayList<Byte>()
    for (b in name.toArray()) {
        let keep = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) ||
            b == 46 || b == 95 || b == 45
        out.add(if (keep) { b } else { UInt8(95) })
    }
    name = String.fromUtf8(out.toArray())
    if (name == "" || name == "." || name == "..") {
        return "repo"
    }
    return name
}

/** 克隆到 `<root>/<repo名>`；冲突时的候选名（第 n 次尝试） */public func cloneDirNameAt(name: String, attempt: Int64): String {
    if (attempt <= 1) {
        return name
    }
    return "${name}-${attempt}"
}

/**
 * 工程"像不像 Tauri 工程"的三个线索（纯函数，只用于给提示，不做拦截）。
 *
 * 判据故意放宽：clone 下来的可能是 monorepo（`src-tauri/` 在子目录里），所以
 * 只看**这三样在不在根上**，缺了也只是"提示检查一下"，不拦着人继续跑。
 */
public func tauriProjectHints(hasSrcTauri: Bool, hasPackageJson: Bool, hasCargoToml: Bool): String {
    if (hasSrcTauri) {
        return "像一个 Tauri 工程（有 src-tauri/）"
    }
    if (hasCargoToml && hasPackageJson) {
        return "像 Tauri 工程，但没找到 src-tauri/（也许是 monorepo，请在子目录里选）"
    }
    if (hasCargoToml || hasPackageJson) {
        return "有 Rust/前端工程文件，但不像完整 Tauri 工程（缺 src-tauri/）"
    }
    return "没发现 Tauri 特征（src-tauri/ 与 package.json/Cargo.toml 都没有）"
}

/** 工作区根目录：`LINGQU_WORKSPACES` → 否则 `<用户目录>/lingqu-workspaces` */
public func workspaceRootDir(): String {
    let env = firstNonEmptyEnv(["LINGQU_WORKSPACES"])
    if (env.trimAscii() != "") {
        return env
    }
    let home = firstNonEmptyEnv(["USERPROFILE", "HOME"])
    if (home == "") {
        return "lingqu-workspaces"
    }
    return hostPath("${home}/lingqu-workspaces")
}

// ============================================================
// 二、动作层（起 git 进程、落盘，单测不覆盖）
// ============================================================

/** git 可执行文件：`LINGQU_GIT` → PATH 里的 `git` */
func gitExeOf(): String {
    let env = firstNonEmptyEnv(["LINGQU_GIT"])
    if (env != "") {
        return env
    }
    return "git"
}

/** 克隆结果 */
public class GitCloneResult {
    public var ok: Bool = false
    public var url: String = ""
    public var target: String = ""
    public var hint: String = ""
    public var outputTail: String = ""
    public var error: String = ""

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("ok", JsonBool(this.ok))
        o.put("url", JsonString(this.url))
        o.put("target", JsonString(this.target))
        o.put("hint", JsonString(this.hint))
        o.put("outputTail", JsonString(this.outputTail))
        o.put("error", JsonString(this.error))
        return o
    }
}

/** 取命令行输出尾部若干行（错误时给人看的那几行） */
func gitTailOf(text: String, maxLines: Int64): String {
    let lines = text.split("\n")
    var start: Int64 = 0
    if (Int64(lines.size) > maxLines) {
        start = Int64(lines.size) - maxLines
    }
    var out = ""
    var i = start
    while (i < Int64(lines.size)) {
        let l = lines[i].trimAscii()
        if (l != "") {
            if (out != "") {
                out += "\n"
            }
            out += l
        }
        i += 1
    }
    return out
}

/**
 * 把 `url` 克隆到工作区（或指定父目录），返回**克隆出来的工程路径**（失败给 error）。
 *
 * 不覆盖已有目录：同名目录已存在就换 `-2`/`-3`（最多试 20 次），20 次都撞就报错让人自己定。
 */
public func gitCloneProject(url: String, dir: String, depth: Int64): GitCloneResult {
    let r = GitCloneResult()
    r.url = url.trimAscii()
    let bad = gitUrlRejectReason(r.url)
    if (bad != "") {
        r.error = "地址不可用：${bad}"
        return r
    }
    let parent = if (dir.trimAscii() != "") { hostPath(dir.trimAscii()) } else { workspaceRootDir() }
    // 已存在就别再 create：仓颉的 `Directory.create(..., recursive: true)` 对**已存在**的目录会抛
    // `… is already exists`（0.39.25 实测：第二次克隆同一个仓库就撞上，报"建不了父目录"）。
    if (!exists(Path(parent))) {
        try {
            Directory.create(Path(parent), recursive: true)
        } catch (e: Exception) {
            r.error = "建不了父目录 ${parent}：${e}"
            return r
        }
    }
    let name = repoDirNameOf(r.url)
    var attempt: Int64 = 1
    var target = ""
    while (attempt <= 20) {
        let cand = hostPath("${parent}/${cloneDirNameAt(name, attempt)}")
        if (!exists(Path(cand))) {
            target = cand
            break
        }
        attempt += 1
    }
    if (target == "") {
        r.error = "父目录里 ${name} 相关目录已占满 20 个，换个目录或先清理"
        return r
    }
    let args = ArrayList<String>()
    args.add("clone")
    if (depth > 0) {
        args.add("--depth")
        args.add("${depth}")
    }
    args.add("--")
    args.add(r.url)
    args.add(target)
    try {
        let (code, out, errOut) = executeWithOutput(gitExeOf(), args.toArray())
        let all = String.fromUtf8(out) + "\n" + String.fromUtf8(errOut)
        r.outputTail = gitTailOf(all, 6)
        if (code != 0) {
            r.error = "git clone 失败（exit=${code}）：${r.outputTail}"
            return r
        }
    } catch (e: Exception) {
        r.error = "起不了 git（设 LINGQU_GIT 指向 git.exe）：${e}"
        return r
    }
    if (!exists(Path(target))) {
        r.error = "git 说成功了，但目标目录不存在：${target}"
        return r
    }
    r.target = target
    r.ok = true
    let hasSrcTauri = exists(Path("${target}/src-tauri"))
    let hasPackageJson = exists(Path("${target}/package.json"))
    let hasCargoToml = exists(Path("${target}/Cargo.toml"))
    r.hint = tauriProjectHints(hasSrcTauri, hasPackageJson, hasCargoToml)
    return r
}
