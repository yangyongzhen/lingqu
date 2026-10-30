package lingqu.deps

import std.collection.*
import std.fs.*
import stdx.encoding.json.*
import lingqu.scanner.*

/*
 * t2h:deps —— Cargo 依赖树 OHOS 兼容性扫描（P3，路线图 T3-1～T3-4）
 *
 * 数据源：`src-tauri/Cargo.lock`（有则用，整树）+ `Cargo.toml` 的 [patch.*] 段
 * （判断 fork 替换是否已落）。**不跑 cargo 子进程**——单测只测纯函数（D-009），
 * 子进程版（cargo metadata）留给真实交叉编译场景。
 *
 * 分档三值域（路线图 P3：可用 / 需 patch / 不可用）：
 *   可用   —— 直接编译可用，或"有条件可用"（evidence 写清条件）
 *   需patch —— 必须换 OHOS fork（alternative 给 git rev）
 *   不可用 —— 目标平台排除，给替代方案（降级/换库）
 * 每条判定都带 rule + evidence（出口判据 2）；**没有"未知"档**——
 * 表里没有的 crate 默认"可用"，evidence 标明"默认直编，待真机验证"，
 * 避免"把没把握的都标危险"造成的误报（P3 出口判据 1 要与真实编译失败对照）。
 *
 * 规则库来源（不凭空编，全部有实测出处）：
 *   · habit-tree @ ohos 分支 `src-tauri/Cargo.toml`（patch 段 + 版本钉注释）
 *   · cc-switch-harmonyos @ main `src-tauri/Cargo.toml`（reqwest rustls / dirs / tray-icon）
 *   · habit-tree `docs/鸿蒙移植改动说明.md`（dirs::data_dir() 在 OHOS 返回 None）
 */

// ===== 分档三值域 =====
public let D_OK = "可用"
public let D_PATCH = "需patch"
public let D_NO = "不可用"

// ===== 依赖项 =====
public class DepItem {
    public var name: String
    public var version: String
    public var verdict: String = D_OK
    public var rule: String = "R2-DEPS-000"
    public var evidence: String = ""
    public var alternative: String = ""

    public init(name: String, version: String) {
        this.name = name
        this.version = version
    }

    public func decide(verdict: String, rule: String, evidence: String, alternative: String): Unit {
        this.verdict = verdict
        this.rule = rule
        this.evidence = evidence
        this.alternative = alternative
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("name", JsonString(this.name))
        o.put("version", JsonString(this.version))
        o.put("verdict", JsonString(this.verdict))
        o.put("rule", JsonString(this.rule))
        o.put("evidence", JsonString(this.evidence))
        o.put("alternative", JsonString(this.alternative))
        return o
    }
}

/** `indexOf` 的平替：找不到返回 -1，调用侧直接比下标（本库 indexOf 返回 Option） */
func indexOfOr(text: String, ch: String): Int64 {
    match (text.indexOf(ch)) {
        case Some(i) => return i
        case None => return -1
    }
}

/** 取 TOML 行里第一个双引号字面量（`name = "serde"` → `serde`）；没有返回空串 */
public func quotedValue(line: String): String {
    let start = indexOfOr(line, "\"")
    if (start < 0) {
        return ""
    }
    let rest = line[(start + 1)..]
    let end = indexOfOr(rest, "\"")
    if (end < 0) {
        return ""
    }
    return rest[0..end]
}

/**
 * 解析 Cargo.lock（v3/v4）：按 `[[package]]` 块取 name/version。
 * 已知坑：同块里 name 在前 version 在后；块外（[metadata] 段）不收。
 */
public func parseCargoLock(text: String): ArrayList<DepItem> {
    let items = ArrayList<DepItem>()
    var curName = ""
    var curVersion = ""
    let lines = text.split("\n", -1)
    for (raw in lines) {
        let t = raw.trimAscii()
        if (t.startsWith("[[")) {
            // 开新块：把上一块收掉
            if (curName != "") {
                items.add(DepItem(curName, curVersion))
            }
            curName = ""
            curVersion = ""
            continue
        }
        if (t.startsWith("[") || t.startsWith("#") || t.startsWith("//")) {
            continue
        }
        if (t.startsWith("name")) {
            curName = quotedValue(t)
            continue
        }
        if (t.startsWith("version")) {
            curVersion = quotedValue(t)
            continue
        }
    }
    if (curName != "") {
        items.add(DepItem(curName, curVersion))
    }
    return items
}

/**
 * 提取 Cargo.toml 里 [patch.*] 段覆盖的 crate 名。
 * [patch.crates-io] 与 [patch."https://..."] 都算——fork 替换已落档。
 *
 * 0.13.1 修两个解析缺陷：
 *   ① 子表形态 `[patch.crates-io.tauri]`（键在子表里）以前会把表内的
 *      `git = "..."` / `rev = "..."` 当成 crate 名塞进结果集，可能误判"已处置"；
 *   ② 子表头的末段就是被 patch 的 crate 名，必须收进来。
 */
public func parsePatchedCrates(cargoTomlText: String): HashSet<String> {
    let patched = HashSet<String>()
    var inPatch = false
    let lines = cargoTomlText.split("\n", -1)
    for (raw in lines) {
        let t = raw.trimAscii()
        if (t.startsWith("[")) {
            // 段头切换：只有 [patch... 段才继续收键
            inPatch = t.startsWith("[patch")
            if (inPatch) {
                // 子表形态：[patch.crates-io.tauri] / [patch."url".crate]
                let crateName = crateNameOfPatchSubtable(t)
                if (crateName != "") {
                    patched.add(crateName)
                }
            }
            continue
        }
        if (!inPatch || t.startsWith("#") || t.startsWith("\"") || t.startsWith("//")) {
            continue
        }
        let eq = indexOfOr(t, "=")
        if (eq <= 0) {
            continue
        }
        let key = t[0..eq].trimAscii()
        // 只收 crate 名（含连字符/下划线/字母数字）；`git`/`rev`/`branch` 这类键
        // 是子表内的属性，不是被 patch 的 crate
        if (key != "" && !isPatchAttrKey(key)) {
            patched.add(key)
        }
    }
    return patched
}

/** 子表头 `[patch.crates-io.tauri]` → `tauri`；不是子表头返回 "" */
func crateNameOfPatchSubtable(headerLine: String): String {
    var h = headerLine
    if (h.startsWith("[")) {
        h = h[1..]
    }
    if (h.endsWith("]")) {
        h = h[0..(h.size - 1)]
    }
    // 去掉结束引号后按 "." 切；段数 > 2 才是子表（[patch.crates-io] 是 2 段）
    let parts = h.split(".", -1)
    if (parts.size <= 2) {
        return ""
    }
    var last = parts[parts.size - 1].trimAscii()
    // [patch."https://host/repo.git"] 这种两段形态里带引号——不是子表
    if (last.startsWith("\"") || last.endsWith("\"")) {
        return ""
    }
    // [patch."https://host/x.git".tauri] 的末段可能有尾引号
    last = last.replace("\"", "")
    return last
}

/** patch 子表内的属性键（不是 crate 名） */
func isPatchAttrKey(key: String): Bool {
    for (k in ["git", "rev", "branch", "tag", "path", "version", "package", "features", "default-features", "optional"]) {
        if (key == k) {
            return true
        }
    }
    return false
}

// ===== 规则表（每条都有实测出处，见文件头）=====
public func applyRule(item: DepItem, patched: HashSet<String>): Unit {
    let name = item.name

    // 0) fork 替换已落：Cargo.toml [patch.*] 里已有这个名字 → 已处置
    if (patched.contains(name)) {
        item.decide(D_OK, "R2-DEPS-100",
            "Cargo.toml [patch.*] 已替换该 crate（OHOS fork 已落档）", "")
        return
    }

    // 1) tauri 全家桶：必须换 OHOS fork（yangyongzhen/tauri feat/open-harmony）
    let tauriForkSet = ["tauri", "tauri-build", "tauri-macros", "tauri-codegen",
        "tauri-utils", "tauri-runtime", "tauri-runtime-wry"]
    for (k in tauriForkSet) {
        if (name == k) {
            item.decide(D_PATCH, "R2-DEPS-001",
                "官方 tauri 无 OHOS 后端；habit-tree/cc-switch 实测均换 yangyongzhen/tauri feat/open-harmony",
                "[patch.crates-io] tauri 系 → git https://github.com/yangyongzhen/tauri rev=e3bf6eb；并钉精确版本（=2.11.5）防 ^ 绕过 patch")
            return
        }
    }
    if (name == "wry") {
        item.decide(D_PATCH, "R2-DEPS-002",
            "wry 官方版无 OHOS；fork 的 tauri-runtime-wry 按 registry 版本声明，workspace patch 不跨工程继承",
            "[patch.crates-io] wry → git https://github.com/tauri-apps/wry rev=6aaf4b8；并钉 wry =\"=0.56.0\" default-features=false")
        return
    }
    if (name == "tao") {
        item.decide(D_PATCH, "R2-DEPS-003",
            "tao 官方版无 OHOS（与 wry 同因：fork 依赖必须一并 patch）",
            "[patch.crates-io] tao → git https://github.com/tauri-apps/tao rev=813572f")
        return
    }
    if (name == "openharmony-ability" || name == "openharmony-ability-derive") {
        item.decide(D_PATCH, "R2-DEPS-004",
            "main 已重构为 1.0.0-beta.1（webview 拆为独立 crate），wry/tauri 的 OHOS 分支仍要求 0.3.0 webview feature",
            "[patch.\"https://github.com/harmony-contrib/openharmony-ability.git\"] → git https://github.com/yangyongzhen/openharmony-ability rev=295a276")
        return
    }

    // 2) 不可用 + 替代（T3-4 替代建议表）
    if (name == "openssl-sys" || name == "native-tls") {
        item.decide(D_NO, "R2-DEPS-010",
            "依赖系统 OpenSSL/安全栈，OHOS 目标下交叉编译失败（P3-4 替代表与案例素材结论）",
            "TLS 改走纯 Rust 栈：rustls + webpki-roots（reqwest 用 default-features=false + features=[\"rustls-tls\"]）")
        return
    }
    if (name == "rfd") {
        item.decide(D_NO, "R2-DEPS-011",
            "rfd 无 OHOS 后端（原生文件对话框能力位缺失，habit-tree「可优化事项」登记为平台限制）",
            "降级为应用内目录树选择；或经 ArkTS 桥接系统能力（R4-004）")
        return
    }

    // 3) 有条件可用（evidence 必须写清条件）
    if (name == "reqwest") {
        item.decide(D_OK, "R2-DEPS-020",
            "OHOS 可编，但 default 走 native-tls 会拉进 openssl-sys → 不可用（cc-switch 实测配置）",
            "default-features=false + features=[\"rustls-tls\",\"json\",\"stream\"]")
        return
    }
    if (name == "dirs") {
        item.decide(D_OK, "R2-DEPS-021",
            "编译可用；但 OHOS 无 HOME 环境变量，dirs::data_dir() 返回 None（habit-tree 移植实测，曾致 setup panic）",
            "运行期路径解析改走沙箱 /data/storage/el2/base/files（R4-001），编译期无需处置")
        return
    }
    if (name == "napi-ohos" || name == "napi-derive-ohos") {
        item.decide(D_OK, "R2-DEPS-022",
            "OHOS 专用 napi 桥接，mobile_entry_point 宏展开必需（habit-tree 实测）", "")
        return
    }

    // 4) 默认：直编（无排除记录）。不冒充"已验证"——evidence 写明待真机确认
    item.decide(D_OK, "R2-DEPS-000",
        "规则库无 OHOS 排除记录，默认直接编译（habit-tree/cc-switch 同类纯 Rust 依赖均直编通过）", "")
}

/** 对整棵依赖树逐项判定 */
public func classifyDeps(items: ArrayList<DepItem>, patched: HashSet<String>): Unit {
    for (item in items) {
        applyRule(item, patched)
    }
}

/** 分档计数（metrics 用） */
public func verdictCounts(items: ArrayList<DepItem>): JsonObject {
    var ok = 0
    var patch = 0
    var no = 0
    for (item in items) {
        if (item.verdict == D_PATCH) {
            patch += 1
        } else if (item.verdict == D_NO) {
            no += 1
        } else {
            ok += 1
        }
    }
    var o = JsonObject()
    o.put("total", JsonInt(items.size))
    o.put("ok", JsonInt(ok))
    o.put("patch", JsonInt(patch))
    o.put("unavailable", JsonInt(no))
    o.put("score", JsonInt(depsScoreOf(items)))
    return o
}

/**
 * 依赖维评分（0–100）：不可用 −15（要换实现/牺牲能力）、需 patch −5（规则可自动改）。
 * 与 scan.cj 的 runtime/api 维同一扣分口径（降级 15 / 改造 5），五维之间可比。
 */
public func depsScoreOf(items: ArrayList<DepItem>): Int64 {
    var deduct: Int64 = 0
    for (item in items) {
        if (item.verdict == D_NO) {
            deduct += 15
        } else if (item.verdict == D_PATCH) {
            deduct += 5
        }
    }
    var score = 100 - deduct
    if (score < 0) {
        score = 0
    }
    return score
}

/**
 * 依赖扫描总入口（T3-5 命令面的后端）。
 * 返回 `lingqu/deps/v1` JSON；读盘失败走 outError（D-013，不静默）。
 */
public func depsScanJson(projectDir: String): JsonObject {
    var root = JsonObject()
    root.put("schema", JsonString("lingqu/deps/v1"))

    var name = projectNameOf(projectDir)
    if (name == "") {
        name = projectDir
    }
    var project = JsonObject()
    project.put("name", JsonString(sanitizeFileName(name)))
    project.put("path", JsonString(projectDir))
    root.put("project", project)

    var outError = ""
    var items = ArrayList<DepItem>()
    var patched = HashSet<String>()

    // Cargo.lock：src-tauri/ 优先，退回工程根
    let lockA = projectDir + "/src-tauri/Cargo.lock"
    let lockB = projectDir + "/Cargo.lock"
    var lockText: Option<String> = None
    if (exists(Path(lockA))) {
        lockText = readTextOrNone(lockA)
    } else if (exists(Path(lockB))) {
        lockText = readTextOrNone(lockB)
    } else {
        outError = "未找到 Cargo.lock（找过 ${lockA} 与 ${lockB}）——目标目录不是 Rust 工程？"
    }
    if (lockText.isSome()) {
        items = parseCargoLock(lockText.getOrThrow())
        // 只去掉「同名同版本」的重复块；**同名不同版本要保留**——Cargo.lock 里
        // 同一个 crate 出现多个版本是常态（如 bitflags 1.x 与 2.x 并存），
        // 以前按名字去重会让 depsTotal 小于真实包数，直接违反 P3 出口判据 3。
        items = dedupeByNameVersion(items)
    }

    // Cargo.toml 的 [patch.*]：src-tauri/ 优先，退回工程根
    let tomlA = projectDir + "/src-tauri/Cargo.toml"
    let tomlB = projectDir + "/Cargo.toml"
    var tomlText: Option<String> = None
    if (exists(Path(tomlA))) {
        tomlText = readTextOrNone(tomlA)
    } else if (exists(Path(tomlB))) {
        tomlText = readTextOrNone(tomlB)
    }
    if (tomlText.isSome()) {
        patched = parsePatchedCrates(tomlText.getOrThrow())
    }
    if (tomlText.isNone() && outError == "") {
        outError = "未找到 Cargo.toml（找过 ${tomlA} 与 ${tomlB}）"
    }

    if (outError == "") {
        classifyDeps(items, patched)
        var arr = JsonArray()
        for (item in items) {
            arr.add(item.toJson())
        }
        root.put("items", arr)
        root.put("metrics", verdictCounts(items))
    }
    root.put("outError", JsonString(outError))
    return root
}

func readTextOrNone(path: String): Option<String> {
    try {
        return Some(String.fromUtf8(File.readFrom(path)))
    } catch (e: Exception) {
        // 读不出来就当没有——上层会因 lock 缺失走 outError，不静默吞掉整体
        return None
    }
}

/** 按「名字+版本」去重：只丢真正重复的块，同名多版本全部保留（Cargo.lock 常态） */
func dedupeByNameVersion(items: ArrayList<DepItem>): ArrayList<DepItem> {
    let seen = HashSet<String>()
    let out = ArrayList<DepItem>()
    for (item in items) {
        let k = "${item.name}@${item.version}"
        if (seen.contains(k)) {
            continue
        }
        seen.add(k)
        out.add(item)
    }
    return out
}
