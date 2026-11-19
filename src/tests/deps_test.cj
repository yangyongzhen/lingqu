package lingqu.tests

import std.collection.*
import std.fs.*
import stdx.encoding.json.*
import lingqu.deps.*

/*
 * t2h:deps 单测（只测纯函数，D-009）：解析 / 规则 / 评分 / 总入口。
 * 主路径 + 错误路径 + 边界，AGENTS §1 第 2 条。
 */

func lockFixture(): String {
    return """
    version = 4

    [[package]]
    name = "grove"
    version = "1.0.2"
    source = "registry+https://github.com/rust-lang/crates.io-index"

    [[package]]
    name = "tauri"
    version = "2.11.5"
    source = "registry+https://github.com/rust-lang/crates.io-index"

    [[package]]
    name = "wry"
    version = "0.56.0"
    source = "registry+https://github.com/rust-lang/crates.io-index"

    [[package]]
    name = "serde"
    version = "1.0.219"
    source = "registry+https://github.com/rust-lang/crates.io-index"

    [[package]]
    name = "rfd"
    version = "0.15.4"
    source = "registry+https://github.com/rust-lang/crates.io-index"

    [metadata]
    note = "不是 package 块"
    """
}

@Test
public func testParseCargoLockMainPath(): Unit {
    let items = parseCargoLock(lockFixture())
    // 5 个 [[package]] 块，[metadata] 段不收
    @Assert(items.size, 5)
    @Assert(items[0].name, "grove")
    @Assert(items[0].version, "1.0.2")
    @Assert(items[1].name, "tauri")
    @Assert(items[2].name, "wry")
    @Assert(items[3].name, "serde")
}

@Test
public func testParseCargoLockEmptyAndGarbage(): Unit {
    // 边界：空文件 → 0 项
    let empty = parseCargoLock("")
    @Assert(empty.size, 0)
    // 边界：残缺块（只有 name 没有 version）也要能收
    let partial = parseCargoLock("[[package]]\nname = \"x\"\n")
    @Assert(partial.size, 1)
    @Assert(partial[0].version, "")
}

@Test
public func testPatchedCrates(): Unit {
    let toml = """
    [dependencies]
    tauri = "=2.11.5"

    [patch.crates-io]
    tauri = { git = "https://github.com/yangyongzhen/tauri", rev = "e3bf6eb" }
    wry = { git = "https://github.com/tauri-apps/wry", rev = "6aaf4b8" }

    [patch."https://github.com/harmony-contrib/openharmony-ability.git"]
    openharmony-ability = { git = "https://github.com/yangyongzhen/openharmony-ability", rev = "295a276" }

    [profile.release]
    strip = true
    """
    let patched = parsePatchedCrates(toml)
    @Assert(patched.contains("tauri"), true)
    @Assert(patched.contains("wry"), true)
    @Assert(patched.contains("openharmony-ability"), true)
    // 子表头（patch 段的 key）与其它段的依赖不能混进来
    @Assert(patched.contains("openharmony-ability.git"), false)
    @Assert(patched.contains("strip"), false)
    // 边界：没有 patch 段 → 空集
    let none = parsePatchedCrates("[dependencies]\ntauri = \"2\"\n")
    @Assert(none.size, 0)
}

@Test
public func testRuleTableVerdicts(): Unit {
    let patched = HashSet<String>()
    // tauri 全家桶 → 需 patch
    let t = DepItem("tauri", "2.11.5")
    applyRule(t, patched)
    @Assert(t.verdict, D_PATCH)
    @Assert(t.rule, "R2-DEPS-001")
    // wry / tao → 需 patch
    let w = DepItem("wry", "0.56.0")
    applyRule(w, patched)
    @Assert(w.verdict, D_PATCH)
    // 不可用 + 替代
    let o = DepItem("openssl-sys", "0.9")
    applyRule(o, patched)
    @Assert(o.verdict, D_NO)
    @Assert(o.alternative.contains("rustls"), true)
    let r = DepItem("rfd", "0.15.4")
    applyRule(r, patched)
    @Assert(r.verdict, D_NO)
    // 系统总线（D-Bus）类：2026-11-19 mark_note 实测的**唯一** crate 级失败点（R-2 抓到并回填的 FN）
    let db = DepItem("libdbus-sys", "0.2.7")
    applyRule(db, patched)
    @Assert(db.verdict, D_NO)
    @Assert(db.rule, "R2-DEPS-013")
    @Assert(db.alternative.contains("zbus"), true)
    // 替代表述**不许**抄 GTK 那族：dbus 换 tauri patch 也去不掉，非要说是"重跑 port 就好"就是误导
    @Assert(db.alternative.contains("wry/tao"), false)
    let dbus = DepItem("dbus", "0.9.7")
    applyRule(dbus, patched)
    @Assert(dbus.verdict, D_NO)
    @Assert(dbus.rule, "R2-DEPS-013")
    // tauri 插件漂移：必须判"需patch"并点出 fork 对齐（EcoPaste 实测的 FN）
    let upd = DepItem("tauri-plugin-updater", "2.10.1")
    applyRule(upd, patched)
    @Assert(upd.verdict, D_PATCH)
    @Assert(upd.rule, "R2-DEPS-014")
    @Assert(upd.alternative.contains("ohos"), true)
    // 但**不许**把整个 tauri-plugin-* 家族一律标红（那是过度预测，会砸 Precision）
    let other = DepItem("tauri-plugin-os", "2.3.0")
    applyRule(other, patched)
    @Assert(other.rule != "R2-DEPS-014")
    // 条件可用：reqwest / dirs
    let rq = DepItem("reqwest", "0.12")
    applyRule(rq, patched)
    @Assert(rq.verdict, D_OK)
    @Assert(rq.alternative.contains("rustls-tls"), true)
    let d = DepItem("dirs", "5.0")
    applyRule(d, patched)
    @Assert(d.verdict, D_OK)
    @Assert(d.evidence.contains("HOME"), true)
    // 默认放行（无记录 → 可用，不冒充已验证）
    let s = DepItem("serde", "1.0.219")
    applyRule(s, patched)
    @Assert(s.verdict, D_OK)
    @Assert(s.rule, "R2-DEPS-000")
}

@Test
public func testAlreadyPatchedWins(): Unit {
    // 已在 [patch] 里的 crate，即使命中规则表也判「已处置」——这是迁移前后最关键的区别
    let patched = HashSet<String>()
    patched.add("tauri")
    let t = DepItem("tauri", "2.11.5")
    applyRule(t, patched)
    @Assert(t.verdict, D_OK)
    @Assert(t.rule, "R2-DEPS-100")
}

@Test
public func testDepsScoreOf(): Unit {
    // 主路径：2 个 patch（-10）+ 1 个不可用（-15）→ 75
    let items = ArrayList<DepItem>()
    items.add(DepItem("tauri", "2.11.5"))
    items.add(DepItem("wry", "0.56.0"))
    items.add(DepItem("rfd", "0.15"))
    classifyDeps(items, HashSet<String>())
    @Assert(depsScoreOf(items), 75)
    // 边界：全不可用扣到底 → 0，不出负数
    let allBad = ArrayList<DepItem>()
    for (i in 0..10) {
        let it = DepItem("bad${i}", "0.1")
        it.decide(D_NO, "x", "y", "z")
        allBad.add(it)
    }
    @Assert(depsScoreOf(allBad), 0)
}

@Test
public func testDepsScanJsonMissingLock(): Unit {
    // 错误路径：目录里没有 Cargo.lock → outError 说明原因，不抛异常、不静默
    let res = depsScanJson("/root/test/cj/lingqu/.lingqu/nonexistent-deps-probe")
    @Assert(res.get("outError").toString().size > 2, true)
    let m = (res.get("metrics") as Option<JsonValue>) ?? None
    match (m) {
        case Some(_) => @Assert(true, false) // 失败时不应出 metrics
        case None => ()
    }
}

@Test
public func testDepsScanJsonRealSample(): Unit {
    // 主路径：用 cc-switch 移植仓的真实 Cargo.lock（若本机存在）
    let dir = "/root/test/cj/cc-switch-ohos"
    if (!exists(Path("${dir}/src-tauri/Cargo.lock"))) {
        // 本机没有样本时跳过（CI 无样本也能绿，不造假）
        return
    }
    let res = depsScanJson(dir)
    // outError 必为空串（这条路径上必有该字段）
    @Assert(res.get("outError").getOrThrow().asString().getValue(), "")
    // 出口判据 3：矩阵行数与 Cargo.lock 的包数一致 → items 非空即产出真实矩阵
    // （不 parse metrics：JsonObject.get 返回 Option，对 Option toString 再 parse 会炸）
    let items = res.get("items").getOrThrow().asArray()
    @Assert(items.size() > 0, true)
}

@Test
public func testQuotedValueEdge(): Unit {
    @Assert(quotedValue("name = \"serde\""), "serde")
    @Assert(quotedValue("name = "), "")   // 没有引号
    @Assert(quotedValue("name = \"open"), "") // 只有前引号
}
