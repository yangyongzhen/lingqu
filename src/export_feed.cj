package lingqu

import std.fs.*
import std.time.*          // DateTime：导出时间戳与落档时刻
import stdx.encoding.json.*
// `sanitizeFileName` 在扫描器包里（工程名净化共用一份实现，别在本包另写）
import lingqu.scanner.*

/*
 * 移植成果导出（0.39.137）：把**迁移后的工程**复制一份到独立目录沉淀。
 *
 * 为什么需要它（用户 2026-11-22 提出）：迁移是**原地改**样本工程的（`C:\...\lingqu-workspaces\<样本>`），
 * 改动混在原始仓库里 ⇒ ① 成果散落在各样本目录，人找不到；② 想"把移植成功的项目源码提交上去"时，
 * 分不清哪些是迁移产物。导出的目的就是把"这一轮迁移后的样子"冻结成一个可归档、可提交的目录。
 *
 * 口径（用户拍的三个决定）：
 *   · 目标：默认 `%USERPROFILE%\lingqu-migrated\<工程>-<日期>`，`LINGQU_MIGRATED_DIR` 可覆盖；
 *   · 范围：**整个工程**，但排除构建产物与依赖缓存（`node_modules` / `target` / `dist` /
 *     `oh_modules` / `gen/ohos/entry/libs` 等，见 `exportSkipDirNames` / `exportSkipPrefixes`）；
 *   · 时机：手动（`lingqu-cli export` / `t2h:export`）**与**验收通过（无 fail）时自动各一次。
 *
 * 纪律：导出**只读源工程、只写目标目录**；写完成后再落 `.lingqu/export/<工程>.json` 当证据
 * （§0.1：落档说了算——界面/agent 只看这个就知道"导没导、导到哪"）。
 */

/** 默认排除的**目录名**（构建产物与依赖缓存：体积大、可重建、不该进仓库） */
public func exportSkipDirNames(): Array<String> {
    return ["node_modules", "target", "dist", "build", "oh_modules", ".git", ".lingqu",
        ".idea", ".vscode", ".svelte-kit", ".next", ".turbo", ".cache", "coverage", "__pycache__"]
}

/** 默认排除的**相对路径前缀**（产物藏在子目录里，光看目录名挡不住） */
public func exportSkipPrefixes(): Array<String> {
    return ["src-tauri/gen/ohos/entry/libs/", "src-tauri/gen/ohos/entry/build/",
        "src-tauri/gen/ohos/build/", "src-tauri/gen/ohos/oh_modules/",
        "src-tauri/gen/ohos/entry/.preview/", "src-tauri/gen/schemas/",
        "src-tauri/gen/android/", "src-tauri/gen/apple/"]
}

/** 默认排除的**文件后缀**（二进制产物；`.so` 尤其是 97 MB 级，绝不能进归档） */
public func exportSkipExts(): Array<String> {
    return [".so", ".hap", ".har", ".dll", ".exe", ".a", ".o", ".lib", ".pdb", ".dylib", ".zip"]
}

func hasAnyPrefix(rel: String, prefixes: Array<String>): Bool {
    for (p in prefixes) {
        if (rel.startsWith(p)) {
            return true
        }
    }
    return false
}

func hasAnyExt(rel: String, exts: Array<String>): Bool {
    for (e in exts) {
        if (rel.endsWith(e)) {
            return true
        }
    }
    return false
}

/**
 * 这个条目**不该导出**吗？（纯函数，单测钉住）
 *
 * `relPath` 用 `/` 分隔（调用方负责归一化）；`isDir` 区分"看目录名"还是"看后缀"。
 */
public func shouldSkipExportEntry(relPath: String, isDir: Bool): Bool {
    if (relPath.size == 0) {
        return false
    }
    let rel = relPath.replace("\\", "/")
    if (hasAnyPrefix(rel, exportSkipPrefixes())) {
        return true
    }
    if (isDir) {
        // 目录只看**最后一段**：`apps/desktop/node_modules` 与 `node_modules` 同等对待
        var last = rel
        // 仓颉里 `lastIndexOf` 返回 `Option<Int64>`（不是 -1），必须模式匹配取值
        if (let Some(i) <- rel.lastIndexOf("/")) {
            last = rel[(i + 1)..]
        }
        for (n in exportSkipDirNames()) {
            if (last == n) {
                return true
            }
        }
        return false
    }
    return hasAnyExt(rel, exportSkipExts())
}

/**
 * ISO 时间串 → 目录名里的日期戳（`2026-11-22T21:40:05+08:00` → `20261122-2140`）。
 * 取到分钟即可：同一分钟内重复导出由调用方加序号（见 `exportTargetDirOf` 的 `seq`）。
 */
public func exportStampOf(iso: String): String {
    let digits = iso.replace("-", "").replace(":", "").replace("T", "").replace(" ", "")
    if (digits.size < 12) {
        // 兜底：拿不到可解析的时间就别造一个假的，直接用原串净化
        var cleaned = iso.replace("-", "").replace(":", "").replace("T", "").replace(" ", "")
        cleaned = cleaned.replace("+", "").replace(".", "")
        return if (cleaned.size > 12) { cleaned[0..12] } else { cleaned }
    }
    return digits[0..8] + "-" + digits[8..12]
}

/**
 * 目标目录：`<root>/<工程>-<戳>`；`seq > 1` 时补 `-<seq>`（同一分钟内重复导出不互相覆盖）。
 * 纯函数（root 由调用方按环境变量解析）。
 */
public func exportTargetDirOf(root: String, projectName: String, stamp: String, seq: Int64): String {
    let name = sanitizeFileName(projectName)
    let base = root + cjhPathSep() + name + "-" + stamp
    if (seq <= 1) {
        return base
    }
    return base + "-" + seq.toString()
}

/** 迁移成果根目录：`LINGQU_MIGRATED_DIR` 优先，否则 `<home>/lingqu-migrated`（有 IO：读环境变量） */
public func migratedRootOf(): String {
    let override = envOr("LINGQU_MIGRATED_DIR", "")
    if (override.size > 0) {
        return normalizeHostSep(override)
    }
    var home = envOr("USERPROFILE", "")
    if (home.size == 0) {
        home = envOr("HOME", "")
    }
    if (home.size == 0) {
        home = "."
    }
    return normalizeHostSep(home) + cjhPathSep() + "lingqu-migrated"
}

/** 统一成宿主分隔符（Windows 上把 `/` 归一成 `\`，避免同一路径两种写法导致"找不到"） */
func normalizeHostSep(p: String): String {
    if (cjhPathSep() == "/") {
        return p.replace("\\", "/")
    }
    return p.replace("/", "\\")
}

// ===== 以下是 IO 半边：拷贝 + 说明文件 + 落档 =====

/** 一次导出的结果（命令层与界面都只看这个） */
public class ExportResult {
    public var ok = false
    public var outDir = ""
    public var project = ""
    public var sourcePath = ""
    public var trigger = ""
    public var copiedFiles: Int64 = 0
    public var skippedEntries: Int64 = 0
    public var totalBytes: Int64 = 0
    public var verifyRate: Int64 = -1
    public var error = ""
}

func ensureDirRecursive(p: String): Unit {
    if (exists(Path(p))) {
        return
    }
    Directory.create(Path(p), recursive: true)
}

/** 读验收落档的统计（读不到就全给 -1：**"没跑过"不许说成 0%**，§4-63） */
func verifyStatsOf(projPath: String, projName: String): (Int64, Int64, Int64, Int64) {
    match (readJsonOrNone(resolveLqPath(projPath, "verify/${projName}.json"))) {
        case Some(root) =>
            let st = objFieldOf(root, "stats")
            return (intFieldOf(st, "ratePercent", -1), intFieldOf(st, "pass", -1),
                intFieldOf(st, "covered", -1), intFieldOf(st, "fail", -1))
        case None => return (-1, -1, -1, -1)
    }
}

/** 递归拷贝（`Directory.walk` 非递归，这里自己走；跳过规则由纯函数判定） */
func copyTreeInto(srcDir: String, dstDir: String, relPrefix: String, res: ExportResult): Unit {
    ensureDirRecursive(dstDir)
    for (info in Directory.readFrom(Path(srcDir))) {
        let rel = if (relPrefix.size == 0) { info.name } else { relPrefix + "/" + info.name }
        let isDir = info.isDirectory()
        if (shouldSkipExportEntry(rel, isDir)) {
            res.skippedEntries += 1
            continue
        }
        let src = srcDir + cjhPathSep() + info.name
        let dst = dstDir + cjhPathSep() + info.name
        if (isDir) {
            copyTreeInto(src, dst, rel, res)
            continue
        }
        try {
            let bytes = File.readFrom(src)
            File.writeTo(dst, bytes)
            res.copiedFiles += 1
            res.totalBytes += bytes.size
        } catch (e: Exception) {
            // 单个文件读不了不该中断整次导出，但要计数（别静默丢）
            res.skippedEntries += 1
        }
    }
}

/** 导出的 manifest（可复核：包含来源、规则、验收读数） */
func exportManifestOf(res: ExportResult, exportedAt: String): String {
    let o = JsonObject()
    o.put("schema", JsonString("lingqu/export/v1"))
    o.put("project", JsonString(res.project))
    o.put("sourcePath", JsonString(normalizeHostSep(res.sourcePath)))
    o.put("exportDir", JsonString(normalizeHostSep(res.outDir)))
    o.put("exportedAt", JsonString(exportedAt))
    o.put("trigger", JsonString(res.trigger))
    o.put("copiedFiles", JsonInt(res.copiedFiles))
    o.put("skippedEntries", JsonInt(res.skippedEntries))
    o.put("totalBytes", JsonInt(res.totalBytes))
    let v = JsonObject()
    v.put("ratePercent", JsonInt(res.verifyRate))
    v.put("note", JsonString("导出时的移植验收读数；-1 = 当时还没跑过 verify"))
    o.put("verify", v)
    let ex = JsonObject()
    let dirs = JsonArray()
    for (d in exportSkipDirNames()) {
        dirs.add(JsonString(d))
    }
    let prefixes = JsonArray()
    for (p in exportSkipPrefixes()) {
        prefixes.add(JsonString(p))
    }
    let exts = JsonArray()
    for (e in exportSkipExts()) {
        exts.add(JsonString(e))
    }
    ex.put("dirNames", dirs)
    ex.put("pathPrefixes", prefixes)
    ex.put("extensions", exts)
    o.put("exclusions", ex)
    return o.toJsonString()
}

/** 给人看的迁移说明（构建/部署怎么做、改了什么、证据在哪） */
func migrationGuideOf(res: ExportResult, exportedAt: String): String {
    var t = "# ${res.project} — 鸿蒙移植成果\n\n"
    t += "> 由灵渠迁移台导出（${exportedAt}，触发：${res.trigger}）。\n"
    t += "> 源工程：`${normalizeHostSep(res.sourcePath)}`\n\n"
    t += "## 这份目录是什么\n\n"
    t += "原 Tauri 工程**迁移到鸿蒙后的完整源码**（已排除 `node_modules` / `target` / `dist` /\n"
    t += "`gen/ohos/entry/libs` 等可重建产物）。拿到后可直接构建 HAP。\n\n"
    t += "## 怎么构建\n\n"
    t += "前置：仓颉 SDK（`CANGJIE_HOME`）、stdx（`CANGJIE_STDX`）、cj-tauri（`CJ_TAURI_ROOT`）。\n\n"
    t += "```bash\n"
    t += "lingqu-cli build  --path .    # 交叉编译，产出 lib<name>.so（鸿蒙 cdylib）\n"
    t += "lingqu-cli hap    --path .    # 装配 HAP（含 ohos 脚手架与签名）\n"
    t += "lingqu-cli sign   --path . --auto --newKeys   # 首次：生成证书/profile 并写回\n"
    t += "lingqu-cli deploy --path . --start            # 装到真机并启动\n"
    t += "lingqu-cli verify --path .    # 采证并判定移植验收\n"
    t += "```\n\n"
    t += "## 迁移改了什么\n\n"
    t += "改动清单看原工程的 `.lingqu/port/`（逐文件备份）与 `migration-manifest.json` 的 `exclusions`；\n"
    t += "导出目录里保留的是**迁移后的现状**，逐条 diff 请对照原始上游仓库。\n\n"
    t += "## 验收读数（导出当时）\n\n"
    if (res.verifyRate >= 0) {
        t += "- 移植验收通过率：**${res.verifyRate}%**（详见 `migration-manifest.json` 的 `verify`）\n"
    } else {
        t += "- 移植验收：**导出时尚未跑过 verify**（`-1`），拿到后请自行 `lingqu-cli verify`\n"
    }
    t += "\n## 统计\n\n"
    t += "- 复制文件：${res.copiedFiles} 个，共 ${res.totalBytes} 字节\n"
    t += "- 跳过条目：${res.skippedEntries} 个（构建产物/依赖缓存）\n"
    return t
}

/**
 * 导出一次：只读源工程、只写目标目录，最后落 `.lingqu/export/<工程>.json` 当证据。
 *
 * `trigger` 记来源（`manual` / `verify-pass`），落档里能看出"这次是谁触发的"。
 */
public func exportProject(projPath: String, trigger: String): ExportResult {
    return exportProjectInto(projPath, migratedRootOf(), trigger)
}

/** 同 `exportProject`，但显式指定成果根目录（CLI `--out` 用；避免为了传参去改环境变量） */
public func exportProjectInto(projPath: String, outRoot: String, trigger: String): ExportResult {
    let res = ExportResult()
    res.trigger = trigger
    res.sourcePath = projPath
    try {
        if (projPath.size == 0 || !exists(Path(projPath))) {
            res.error = "工程路径不存在：${projPath}"
            return res
        }
        let projName = sanitizeFileName(projectNameOf(projPath))
        res.project = projName
        let root = outRoot
        ensureDirRecursive(root)
        let nowMs = DateTime.now().toUnixTimeStamp().toMilliseconds()
        let iso = DateTime.now().toString()
        let stamp = exportStampOf(iso)
        var seq: Int64 = 1
        var target = exportTargetDirOf(root, projName, stamp, seq)
        while (seq < 100 && exists(Path(target))) {
            seq += 1
            target = exportTargetDirOf(root, projName, stamp, seq)
        }
        res.outDir = target
        let (rate, _, _, _) = verifyStatsOf(projPath, projName)
        res.verifyRate = rate
        copyTreeInto(projPath, target, "", res)
        let exportedAt = iso
        File.writeTo(target + cjhPathSep() + "MIGRATION.md", migrationGuideOf(res, exportedAt).toArray())
        File.writeTo(target + cjhPathSep() + "migration-manifest.json",
            exportManifestOf(res, exportedAt).toArray())
        res.ok = true
        writeExportRecord(projPath, projName, res, nowMs, exportedAt)
        return res
    } catch (e: Exception) {
        res.ok = false
        res.error = "导出失败：${e}"
        return res
    }
}

/** 落档 `.lingqu/export/<工程>.json`（界面与 agent 只看这个就知道"导没导、导到哪"） */
func writeExportRecord(projPath: String, projName: String, res: ExportResult, nowMs: Int64, exportedAt: String): Unit {
    try {
        let dir = lqDirOf(projPath) + cjhPathSep() + "export"
        ensureDirRecursive(dir)
        let o = JsonObject()
        o.put("schema", JsonString("lingqu/export/v1"))
        o.put("project", JsonString(projName))
        o.put("ok", JsonBool(res.ok))
        o.put("trigger", JsonString(res.trigger))
        o.put("exportDir", JsonString(normalizeHostSep(res.outDir)))
        o.put("sourcePath", JsonString(normalizeHostSep(res.sourcePath)))
        o.put("copiedFiles", JsonInt(res.copiedFiles))
        o.put("skippedEntries", JsonInt(res.skippedEntries))
        o.put("totalBytes", JsonInt(res.totalBytes))
        o.put("verifyRate", JsonInt(res.verifyRate))
        o.put("exportedAt", JsonString(exportedAt))
        o.put("exportedAtMs", JsonInt(nowMs))
        o.put("error", JsonString(res.error))
        File.writeTo(dir + cjhPathSep() + projName + ".json", o.toJsonString().toArray())
    } catch (e: Exception) {
        // 落档失败不改变"导出本身成功了"，但要让调用方能从 error 里看到（§4-26：写盘失败原因要进返回值）
        res.error = "导出成功但落档失败：${e}"
    }
}
