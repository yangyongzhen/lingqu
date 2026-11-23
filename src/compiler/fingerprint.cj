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
func assetExts(): Array<String> {
    return [".js", ".mjs", ".cjs", ".css", ".map", ".html", ".json", ".png", ".jpg",
        ".jpeg", ".webp", ".gif", ".svg", ".ico", ".woff", ".woff2", ".ttf", ".otf", ".wasm"]
}

func isAssetExt(name: String): Bool {
    for (e in assetExts()) {
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
 * 口径（0.39.136 重写）：`.so` 里前端 key 是**合并字符串池**里的裸字节，相邻两条之间
 * 常常**没有 NUL 分隔**，于是出现两种真形态，旧口径（"整段必须以扩展名结尾"）两种都判错：
 *
 *   · 粘连：`assets/A.js/assets/B.js` 被吃成一条假 key ⇒ 判成"旧产物"（假 stale）
 *   · 段尾粘字：`assets/AiAssistant-….cssInvalid`（键后紧跟别处的串）整段被丢 ⇒ 判成"没打包"（假 missing）
 *
 * 现口径：
 *   ① 找到 `assets/` 起点，吃到「连续 key 字符」为止（这一段里可能夹着更多 key）；
 *   ② 段内每个再出现的 `assets/` 都是一条新 key 的起点 ⇒ 按它切段，每段各自成型；
 *   ③ 段尾可能粘着别处的正文 ⇒ 按「段内能匹配到的**最长**已知扩展名」截断
 *      （`a.woff2` 不许被截成 `a.woff`）。取不出扩展名就丢弃。
 *
 * 实测（2026-11-22 dbx，97 MB cdylib / 599 个前端产物）：旧口径报 5 假 stale + 20 假 missing，
 * 而 `dist/` 的 599 个键 `.so` 里**一个不缺**——闸把"编好了"报成"没重编"。
 */
public func extractAssetKeys(data: Array<UInt8>): ArrayList<String> {
    let out = ArrayList<String>()
    let mb = "assets/".toArray()
    if (data.size < mb.size) {
        return out
    }
    var i: Int64 = 0
    while (i + mb.size <= data.size) {
        if (!markerAt(data, i, mb)) {
            i += 1
            continue
        }
        // ① 吃整段合法 key 字符
        var j = i
        while (j < data.size && isKeyChar(data[j])) {
            j += 1
        }
        // ② 段内再出现的 `assets/` 是下一条 key 的起点：切段后各自成型
        var segStart = i
        var p = i + 1
        while (p + mb.size <= j) {
            if (markerAt(data, p, mb)) {
                addKeyIfNew(out, keyOfSegment(data, segStart, p))
                segStart = p
                p += mb.size
                continue
            }
            p += 1
        }
        addKeyIfNew(out, keyOfSegment(data, segStart, j))
        i = if (j > i) { j } else { i + 1 }
    }
    return out
}

/** 位置 p 处是否正好是 marker（调用方已保证 p + marker.size 不越界） */
func markerAt(data: Array<UInt8>, p: Int64, mb: Array<UInt8>): Bool {
    for (k in 0..mb.size) {
        if (data[p + k] != mb[k]) {
            return false
        }
    }
    return true
}

/**
 * `[s, endExclusive)` 这段是否以某个已知扩展名结尾；返回命中的扩展名长度（0 = 没命中）。
 * 同一处同时命中 `.woff` 与 `.woff2` 时返回更长的那条，供 `keyOfSegment` 优先采用。
 */
func endsWithAssetExt(data: Array<UInt8>, s: Int64, endExclusive: Int64): Int64 {
    var best: Int64 = 0
    for (ext in assetExts()) {
        let eb = ext.toArray()
        if (endExclusive - s < eb.size || eb.size <= best) {
            continue
        }
        var hit = true
        for (k in 0..eb.size) {
            if (data[endExclusive - eb.size + k] != eb[k]) {
                hit = false
                break
            }
        }
        if (hit) {
            best = eb.size
        }
    }
    return best
}

/**
 * 从 `[s, e)` 这一「key 字符段」里取出一条 AssetKey：按**最长**已知扩展名截断。
 * 段尾粘着别处正文（`X.cssInvalid`）时只取到扩展名；一个扩展名都匹配不上则返回空串。
 *
 * 0.39.122 的教训仍适用：这里是**从 .so 二进制里**取键，非 UTF-8 字节一定会有，
 * 必须走 `lenientUtf8`（硬解会抛 `Invalid utf8 byte sequence`）。
 */
func keyOfSegment(data: Array<UInt8>, s: Int64, e: Int64): String {
    if (e <= s + 1) {
        return ""
    }
    var bestEnd: Int64 = -1
    var bestExt: Int64 = 0
    var end = s + 1
    while (end <= e) {
        let extLen = endsWithAssetExt(data, s, end)
        if (extLen > bestExt) {
            bestExt = extLen
            bestEnd = end
        }
        end += 1
    }
    if (bestEnd < 0) {
        return ""
    }
    return lenientUtf8(data[s..bestEnd])
}

func addKeyIfNew(out: ArrayList<String>, key: String): Unit {
    if (key.size == 0 || out.contains(key)) {
        return
    }
    out.add(key)
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
