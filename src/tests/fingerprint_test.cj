package lingqu.tests

import std.collection.*
import std.fs.*
import lingqu.compiler.*
import lingqu.port.*

/*
 * T5-2 单测：前端指纹校验（`.so` 内嵌 AssetKey ↔ `dist/`）——纯函数，D-009。
 *
 * 口径来自真实取值：从 habit-tree @ ohos 的 libgrove_lib.so 里扫到
 *   assets/index-BbUz51cz.css / assets/ui-BQiP9gYH.js / assets/index-CNGJtM_T.js
 * 与 dist/assets/ 三个文件名逐字吻合。sample 里额外混了若干噪声，验解析的收敛性。
 */

func sampleKeysBytes(): Array<UInt8> {
    return File.readFrom("samples/evidence/so-assetkeys.sample.txt")
}

@Test
public func testExtractAssetKeysFromBinary(): Unit {
    let keys = extractAssetKeys(sampleKeysBytes())
    // 三个真实 key 都扫到
    @Assert(keys.contains("assets/index-BbUz51cz.css"), true)
    @Assert(keys.contains("assets/ui-BQiP9gYH.js"), true)
    @Assert(keys.contains("assets/index-CNGJtM_T.js"), true)
    // 重复出现的只留一份（去重）
    var oldCount: Int64 = 0
    for (k in keys) {
        if (k == "assets/index-OLD.js") {
            oldCount += 1
        }
    }
    @Assert(oldCount, 1)
    // 裸 "assets/"（后面跟中文括号）不产生空 key，也不产生非法 key
    for (k in keys) {
        @Assert(k.startsWith("assets/"), true)
        @Assert(k.size > 8, true)
    }
}

@Test
public func testExtractAssetKeysEdgeCases(): Unit {
    // 空输入 / 比 marker 还短的输入 → 空结果，不炸
    let empty = ArrayList<UInt8>()
    @Assert(extractAssetKeys(empty.toArray()).size, 0)
    // 只有 marker、没有合法 key
    @Assert(extractAssetKeys("assets/".toArray()).size, 0)
    // 非法扩展名不算前端资源
    @Assert(extractAssetKeys("assets/foo.rs".toArray()).size, 0)
    // 任意二进制噪声不炸（含 0x00 / 0xFF）
    let noise: Array<UInt8> = [0, 255, 65, 47, 0, 66, 200, 47]
    @Assert(extractAssetKeys(noise).size, 0)
}

@Test
public func testCompareAssetsAllMatched(): Unit {
    let embedded = ArrayList<String>()
    embedded.add("assets/index-AAA.js")
    embedded.add("assets/style-BBB.css")
    let dist = ArrayList<String>()
    dist.add("assets/index-AAA.js")
    dist.add("assets/style-BBB.css")
    let d = compareAssetKeys(embedded, dist)
    @Assert(d.matched.size, 2)
    @Assert(d.staleInSo.size, 0)
    @Assert(d.missingInSo.size, 0)
    @Assert(d.ok(), true)
}

@Test
public func testCompareAssetsDetectsStaleSo(): Unit {
    // 核心场景：改了前端、dist 已更新，但 .so 还是旧的
    //   .so 里记 index-OLD.js（磁盘上没了）→ staleInSo
    //   dist 里是 index-NEW.js（.so 里没有）→ missingInSo
    let embedded = ArrayList<String>()
    embedded.add("assets/index-OLD.js")
    let dist = ArrayList<String>()
    dist.add("assets/index-NEW.js")
    let d = compareAssetKeys(embedded, dist)
    @Assert(d.ok(), false)
    @Assert(d.staleInSo.size, 1)
    @Assert(d.staleInSo[0], "assets/index-OLD.js")
    @Assert(d.missingInSo.size, 1)
    @Assert(d.missingInSo[0], "assets/index-NEW.js")
}

@Test
public func testAssetFingerprintGate(): Unit {
    // 干净：两边一致 → 通过
    @Assert(checkAssetFingerprintGate(0, 0, 3).passed, true)
    // .so 里压根没有前端资源（frontendDist 没配 / 纯 Rust 库）→ 失败并说清原因
    let none = checkAssetFingerprintGate(0, 0, 0)
    @Assert(none.passed, false)
    @Assert(none.failures[0].contains("没有内嵌前端资源"), true)
    // 旧 .so（stale）→ 失败，文案要能直接指导动作（重编）
    let stale = checkAssetFingerprintGate(1, 0, 3)
    @Assert(stale.passed, false)
    @Assert(stale.failures[0].contains("重编"), true)
    // 新 dist 没打包（missing）→ 失败
    let missing = checkAssetFingerprintGate(0, 2, 3)
    @Assert(missing.passed, false)
    @Assert(missing.failures[0].contains("dist/"), true)
}

/*
 * 0.39.91 复现：**flat 布局**（tauri 原生嵌入）曾把闸判成假红。
 *
 * 现场（rust-music-3，2026-11-08）：`tauri.conf.json` 的 `frontendDist` 是 `ui`，
 * `ui/` 下只有一个 `index.html`；`.so` 里明明白白嵌着 `index.html` / `/index.html`，
 * 但旧口径两处都只认 `assets/` 前缀 ⇒ 抽出 0 个键 ⇒ 闸报「.so 里没有内嵌前端资源」，
 * 三次构建全红、agent 只能自己绕。
 *
 * 判据改成先定布局：assets/ 有产物走老口径；没有 assets/ 但有入口文件（index.html
 * 这类）就走「存在性」比对。**因为 .so 里没有可枚举的键前缀，只能问"这个键在不在里面"。**
 */
@Test
public func testAssetLayoutOfFlatDist(): Unit {
    let assets = ArrayList<String>()
    assets.add("assets/index-AAA.js")
    let empty = ArrayList<String>()
    // dist 里有 assets/ → 老口径
    @Assert(assetLayoutOf(assets, empty), "assets")
    // dist 里只有入口文件 → 新口径（现场就是这一格）
    let entries = ArrayList<String>()
    entries.add("index.html")
    @Assert(assetLayoutOf(empty, entries), "entry")
    // 两边都没有 → 没前端资源（闸该红，但要说清是"没有"而不是"旧了"）
    @Assert(assetLayoutOf(empty, empty), "none")
}

@Test
public func testDistEntryKeysOfFlatDist(): Unit {
    let dir = ".lingqu/tmp-test-flat"
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir))
        }
        File.writeTo("${dir}/index.html", "<html><body>hi</body></html>".toArray())
        // 非前端文件不该算入口
        File.writeTo("${dir}/README.md", "#x".toArray())
    } catch (e: Exception) {
        return // 目录不可写则跳过，不造假
    }
    let keys = distEntryKeysOf(dir)
    @Assert(keys.size, 1)
    @Assert(keys[0], "index.html")
    // assets/ 口径下这个 dist 一个键都没有 —— 正是假红的来源
    @Assert(distAssetKeysOf(dir).size, 0)
    // 不存在的目录 → 空，而不是抛异常
    @Assert(distEntryKeysOf("${dir}/nonexistent").size, 0)
}

@Test
public func testCompareEntryKeysPresence(): Unit {
    // `.so` 里含 index.html（现场取值：index.html / /index.html 各 5 处）
    let soBytes = "\u{0}index.html\u{0}/index.html\u{0}ui/index.html".toArray()
    let entries = ArrayList<String>()
    entries.add("index.html")
    let d = compareEntryKeys(soBytes, entries)
    @Assert(d.matched.size, 1)
    @Assert(d.missingInSo.size, 0)
    @Assert(d.staleInSo.size, 0)
    @Assert(d.ok(), true)
    // 键不在 .so 里 → 记为 missingInSo（真机上跑的是旧 .so 或压根没打包）
    let absent = compareEntryKeys("nothing here".toArray(), entries)
    @Assert(absent.matched.size, 0)
    @Assert(absent.missingInSo.size, 1)
    @Assert(absent.missingInSo[0], "index.html")
    @Assert(absent.ok(), false)
    // 有匹配时闸通过（embedded 数按"命中的入口"算）
    @Assert(checkAssetFingerprintGate(Int64(d.staleInSo.size), Int64(d.missingInSo.size),
        Int64(d.matched.size)).passed, true)
}

@Test
public func testDistAssetKeysOfRealDist(): Unit {
    // 用真实样本的 dist 目录（samples 里没有 dist，走临时目录 fixture）
    let dir = ".lingqu/tmp-test-dist"
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir))
        }
        if (!exists(Path("${dir}/assets"))) {
            Directory.create(Path("${dir}/assets"))
        }
        File.writeTo("${dir}/index.html", "<html></html>".toArray())
        File.writeTo("${dir}/assets/index-AAA.js", "//x".toArray())
        File.writeTo("${dir}/assets/style-BBB.css", "/*x*/".toArray())
    } catch (e: Exception) {
        return // 目录不可写则跳过，不造假
    }
    let keys = distAssetKeysOf(dir)
    // 只收 assets/ 下的资源；dist/index.html 不是 AssetKey
    @Assert(keys.size, 2)
    @Assert(keys.contains("assets/index-AAA.js"), true)
    @Assert(keys.contains("assets/style-BBB.css"), true)
    // 不存在的目录 → 空，而不是抛异常
    @Assert(distAssetKeysOf("${dir}/nonexistent").size, 0)
}
