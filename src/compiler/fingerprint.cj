package lingqu.compiler

import std.collection.*
import std.fs.*
import stdx.encoding.json.*

/*
 * T5-2 前端指纹校验的纯函数半边：`.so` 内嵌的前端 AssetKey ↔ `dist/` 真实文件。
 *
 * 为什么这是本项目最硬的差异化点：
 *   ArkWeb 下前端资源**不是**从磁盘读的，而是被 tauri 的 `generate_context!` 在编译期
 *   打进 `.so`（`AssetKey` 明文可见）。于是有一条真实的坑：**只改前端、没重编 `.so`** ——
 *   装到真机上跑的还是旧前端，而所有构建步骤都"成功"。这种失败靠肉眼看不出来，
 *   只能靠比对"`.so` 里记的 key"与"`dist/` 里实际产物"。
 *
 * 实测（2026-10-30，habit-tree @ ohos）：
 *   从 libgrove_lib.so 里扫到 assets/index-BbUz51cz.css / index-CNGJtM_T.js / ui-BQiP9gYH.js，
 *   与 dist/assets/ 三个文件名逐字吻合 —— 校验口径成立。
 */

/** 前端资源扩展名（只认这些，避免把 .so 里其它 "assets/..." 字样误当资源） */
func isAssetExt(name: String): Bool {
    for (e in [".js", ".mjs", ".cjs", ".css", ".map", ".html", ".json", ".png", ".jpg",
        ".jpeg", ".webp", ".gif", ".svg", ".ico", ".woff", ".woff2", ".ttf", ".otf", ".wasm"]) {
        if (name.endsWith(e)) {
            return true
        }
    }
    return false
}

/** 资源 key 的合法字符（vite 产物名形如 assets/index-CNGJtM_T.js） */
func isKeyChar(b: UInt8): Bool {
    // 0-9 A-Z a-z _ - . /
    if (b >= 48 && b <= 57) {
        return true
    }
    if (b >= 65 && b <= 90) {
        return true
    }
    if (b >= 97 && b <= 122) {
        return true
    }
    if (b == 95 || b == 45 || b == 46 || b == 47) {
        return true
    }
    return false
}

/**
 * 从二进制里扫前端 AssetKey（不依赖 UTF-8 解码——`.so` 是任意二进制）。
 *
 * 口径：找 ASCII 子串 `assets/`，然后继续吃合法 key 字符直到遇到其它字节，
 * 最后要求以已知前端扩展名结尾。去重、保序。
 */
public func extractAssetKeys(data: Array<UInt8>): ArrayList<String> {
    let out = ArrayList<String>()
    let marker = "assets/"
    let mb = marker.toArray()
    if (data.size < mb.size) {
        return out
    }
    var i: Int64 = 0
    while (i + mb.size <= data.size) {
        // 先比对 marker
        var hit = true
        for (k in 0..mb.size) {
            if (data[i + k] != mb[k]) {
                hit = false
                break
            }
        }
        if (!hit) {
            i += 1
            continue
        }
        // 吃 key（含 marker 自身）
        var j = i
        while (j < data.size && isKeyChar(data[j])) {
            j += 1
        }
        // 0.39.122：这里是**从 .so 二进制里**取资源键，非 UTF-8 字节一定会有——
        // 硬解会抛 `Invalid utf8 byte sequence`（2026-11-19 EcoPaste 真机 verify 死在这）。
        // 资源键本来就是 ASCII 路径，非 ASCII 字节换成 '?' 不影响比对。
        let key = lenientUtf8(data[i..j])
        if (isAssetExt(key) && !out.contains(key)) {
            out.add(key)
        }
        i = if (j > i) { j } else { i + 1 }
    }
    return out
}

/** 一次比对的结果（三个方向分开记，报告能说清"哪个方向不一致"） */
public class AssetDiff {
    /** 两边都有：`.so` 与 `dist/` 一致的部分 */
    public var matched: ArrayList<String> = ArrayList<String>()
    /** 只在 `.so` 里：**真机上跑的是这份**，但 `dist/` 已经没有 → 改了前端没重编 */
    public var staleInSo: ArrayList<String> = ArrayList<String>()
    /** 只在 `dist/` 里：新前端产物没进 `.so` → 同样说明 `.so` 是旧的 */
    public var missingInSo: ArrayList<String> = ArrayList<String>()

    public func ok(): Bool {
        return this.staleInSo.size == 0 && this.missingInSo.size == 0
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("ok", JsonBool(this.ok()))
        o.put("matched", intJson(this.matched))
        o.put("staleInSo", intJson(this.staleInSo))
        o.put("missingInSo", intJson(this.missingInSo))
        return o
    }
}

func intJson(items: ArrayList<String>): JsonArray {
    var arr = JsonArray()
    for (s in items) {
        arr.add(JsonString(s))
    }
    return arr
}

/**
 * 比对：`.so` 内嵌 key 集合 ↔ `dist/` 实际产物集合。
 *
 * 判定口径（**两边都要看**）：
 *   · 只在 `.so` 里（staleInSo）→ 失败：真机跑的前端磁盘上已经不存在，典型"改了没重编"
 *   · 只在 `dist/` 里（missingInSo）→ 失败：新产物没打进 `.so`，同样是旧 `.so`
 *   · 只有两边都空或不相上下才通过 —— 但"两边都空"要单独标注（可能 frontendDist 配错了）
 */
public func compareAssetKeys(embedded: ArrayList<String>, distKeys: ArrayList<String>): AssetDiff {
    let d = AssetDiff()
    for (k in embedded) {
        if (distKeys.contains(k)) {
            d.matched.add(k)
        } else {
            d.staleInSo.add(k)
        }
    }
    for (k in distKeys) {
        if (!embedded.contains(k)) {
            d.missingInSo.add(k)
        }
    }
    return d
}

/**
 * 列 `dist/` 下的前端资源（递归一层多的子目录），返回**工程内相对路径**，
 * 形如 `assets/index-XXX.js`（与 `.so` 里内嵌 key 的口径一致）。
 */
public func distAssetKeysOf(distDir: String): ArrayList<String> {
    let out = ArrayList<String>()
    if (!exists(Path(distDir))) {
        return out
    }
    walkDistForAssets(distDir, distDir, out)
    return out
}

/**
 * 列 `dist/` **根目录**下的入口文件（`index.html` 之类），相对路径即文件名。
 *
 * 为什么要单列：`frontendDist` 不一定是 vite 那种 `assets/` 布局。现场（rust-music-3，
 * 2026-11-08）是 `frontendDist: "ui"` + 只有一个 `index.html`，两处取键都只认 `assets/`
 * 前缀 ⇒ 抽出 0 个键 ⇒ 指纹闸把"编译成功、前端也确实在里面"判成红（假红）。
 */
public func distEntryKeysOf(distDir: String): ArrayList<String> {
    let out = ArrayList<String>()
    if (!exists(Path(distDir))) {
        return out
    }
    var entries: Array<FileInfo>
    try {
        entries = Directory.readFrom(distDir)
    } catch (e: Exception) {
        let _ = e
        return out
    }
    for (info in entries) {
        if (info.isDirectory()) {
            continue
        }
        let name = info.name
        if (isAssetExt(name) && !out.contains(name)) {
            out.add(name)
        }
    }
    return out
}

/**
 * 布局判定（纯函数）：决定这次用哪套指纹口径。
 *   · `assets` —— dist 里有 `assets/` 产物（vite 等现代前端），沿用 stale/missing 三方比对
 *   · `entry`  —— 没有 `assets/`，但有入口文件（`index.html` 这类）。`.so` 里没有可枚举的
 *                键前缀，只能做「存在性」比对（见 compareEntryKeys）
 *   · `none`   —— 两边都没有前端资源：闸该红，但文案要说"没有"而不是"旧了"
 */
public func assetLayoutOf(distKeys: ArrayList<String>, entryKeys: ArrayList<String>): String {
    if (distKeys.size > 0) {
        return "assets"
    }
    if (entryKeys.size > 0) {
        return "entry"
    }
    return "none"
}

/** 字节级包含（`.so` 是任意二进制，不解码；needle 只支持 ASCII 键） */
public func binaryContainsKey(data: Array<UInt8>, key: String): Bool {
    let nb = key.toArray()
    if (nb.size == 0 || data.size < nb.size) {
        return false
    }
    var i: Int64 = 0
    while (i + nb.size <= data.size) {
        var hit = true
        for (k in 0..nb.size) {
            if (data[i + k] != nb[k]) {
                hit = false
                break
            }
        }
        if (hit) {
            return true
        }
        i += 1
    }
    return false
}

/**
 * `entry` 布局的比对：只有"这个键在不在 `.so` 里"。
 * 没有 stale 方向——`.so` 里没有可枚举的键表，凭空扫"像路径的串"只会把
 * `module.json` 之类的无关字符串当成资源（那是另一种假红）。
 */
public func compareEntryKeys(data: Array<UInt8>, entryKeys: ArrayList<String>): AssetDiff {
    let d = AssetDiff()
    for (k in entryKeys) {
        if (binaryContainsKey(data, k)) {
            d.matched.add(k)
        } else {
            d.missingInSo.add(k)
        }
    }
    return d
}

func walkDistForAssets(root: String, cur: String, out: ArrayList<String>): Unit {
    var entries: Array<FileInfo>
    try {
        entries = Directory.readFrom(cur)
    } catch (e: Exception) {
        let _ = e
        return
    }
    for (info in entries) {
        let name = info.name
        let child = "${cur}/${name}"
        if (info.isDirectory()) {
            walkDistForAssets(root, child, out)
            continue
        }
        if (!isAssetExt(name)) {
            continue
        }
        var rel = child
        if (child.startsWith(root + "/")) {
            rel = child[(root.size + 1)..]
        }
        // dist/index.html 这类根文件不是 AssetKey（tauri 把它作为入口单独处理）
        if (rel.startsWith("assets/") && !out.contains(rel)) {
            out.add(rel)
        }
    }
}
