package lingqu.tests

import lingqu.*
import lingqu.port.*
import std.collection.*

/*
 * R2-PORT-016（reqwest TLS 栈）+ FP-021 的单测（0.39.99）。
 *
 * 复现的现场（note-gen-2，2026-11-08）：
 *   src-tauri/Cargo.toml:76
 *     reqwest = { version = "0.12", features = ["json","multipart","stream","rustls-tls","socks"] }
 *   `cargo build --release --target aarch64-unknown-linux-ohos` 死在
 *     failed to run custom build command for `openssl-sys v0.9.109`
 *     Could not find directory of OpenSSL installation
 *   明明写了 `rustls-tls`——因为那只是"多加一个后端"，`default-tls` 仍在默认集合里，
 *   于是 native-tls → openssl-sys 一起进树。这类坑的判据必须埋在工具里（规则 + 指纹），
 *   靠"技能里写一句"是兜不住的。
 */

/** 只有 [dependencies] 的最小 Cargo.toml（其余规则各自跳过/追加，不影响本条断言） */
func tlsTomlWith(depLine: String): String {
    return "[package]\nname = \"probe\"\nversion = \"1.0.0\"\n\n[dependencies]\n${depLine}\n"
}

func outcomeOf(res: PortResult, id: String): RuleOutcome {
    for (o in res.outcomes) {
        if (o.id == id) {
            return o
        }
    }
    return RuleOutcome(id, false, "（规则未执行）", "", "")
}

/** 主路径：写了 rustls-tls 但没关默认特性 → 关掉它，并把纯 Rust 默认项补回来 */
@Test
public func testReqwestDisablesDefaultTls(): Unit {
    let toml = tlsTomlWith("reqwest = { version = \"0.12\", features = [\"json\", \"rustls-tls\"] }")
    let res = applyCargoTomlRules(toml)
    let o = outcomeOf(res, "R2-PORT-016")
    @Assert(o.applied, true)
    @Assert(o.tier, T_AUTO)
    let t = res.afterText
    @Assert(t.contains("default-features = false"), true)
    @Assert(t.contains("\"rustls-tls\""), true)
    // 只关默认特性会顺手丢行为——charset/http2（0.12 还有 system-proxy）必须补回来
    @Assert(t.contains("\"charset\""), true)
    @Assert(t.contains("\"http2\""), true)
    @Assert(t.contains("\"system-proxy\""), true)
    // 原有 features 一个都不许丢
    @Assert(t.contains("\"json\""), true)
    @Assert(t.contains("version = \"0.12\""), true)
}

/** 幂等：改过的文件再跑一遍，本条 applied=false 且文本逐字节不变 */
@Test
public func testReqwestRuleIdempotent(): Unit {
    let toml = tlsTomlWith("reqwest = { version = \"0.12\", features = [\"json\", \"rustls-tls\", \"socks\"] }")
    let first = applyCargoTomlRules(toml)
    @Assert(outcomeOf(first, "R2-PORT-016").applied, true)
    let second = applyCargoTomlRules(first.afterText)
    @Assert(outcomeOf(second, "R2-PORT-016").applied, false)
    @Assert(second.afterText == first.afterText, true)
}

/** 边界：features 是多行数组 → 不碰（机械合并会留下续行，把 Cargo.toml 改坏） */
@Test
public func testReqwestMultilineFeaturesGoesGuide(): Unit {
    let toml = tlsTomlWith("reqwest = { version = \"0.12\", features = [\n    \"json\",\n] }")
    let res = applyCargoTomlRules(toml)
    let o = outcomeOf(res, "R2-PORT-016")
    @Assert(o.applied, false)
    @Assert(o.tier, T_GUIDE)
    @Assert(res.afterText.contains("default-features = false"), false)
}

/** 边界：显式要了原生 TLS → guide（换后端是语义变更，不能机械改） */
@Test
public func testReqwestExplicitNativeTlsGoesGuide(): Unit {
    let toml = tlsTomlWith("reqwest = { version = \"0.12\", features = [\"native-tls\"] }")
    let o = outcomeOf(applyCargoTomlRules(toml), "R2-PORT-016")
    @Assert(o.applied, false)
    @Assert(o.tier, T_GUIDE)
}

/** 错误路径：reqwest 太老（0.11 以前默认特性集合不同）→ guide，不猜 */
@Test
public func testReqwestOldVersionGoesGuide(): Unit {
    let toml = tlsTomlWith("reqwest = { version = \"0.10\", features = [\"json\"] }")
    let o = outcomeOf(applyCargoTomlRules(toml), "R2-PORT-016")
    @Assert(o.applied, false)
    @Assert(o.tier, T_GUIDE)
}

/** 边界：`reqwest = "0.12"` 简写形态也要能改，且版本号不能被吞 */
@Test
public func testReqwestPlainVersionForm(): Unit {
    let toml = tlsTomlWith("reqwest = \"0.12\"")
    let res = applyCargoTomlRules(toml)
    let o = outcomeOf(res, "R2-PORT-016")
    @Assert(o.applied, true)
    @Assert(res.afterText.contains("version = \"0.12\""), true)
    @Assert(res.afterText.contains("default-features = false"), true)
}

/** 错误路径：没有 reqwest 的工程不许被塞一条 */
@Test
public func testReqwestAbsentSkipped(): Unit {
    let toml = tlsTomlWith("serde = \"1\"")
    let res = applyCargoTomlRules(toml)
    @Assert(outcomeOf(res, "R2-PORT-016").applied, false)
    @Assert(res.afterText.contains("reqwest"), false)
}

/** 行尾注释要活着（保注释是这套行级改写纪律的一部分） */
@Test
public func testReqwestKeepsTrailingComment(): Unit {
    let toml = tlsTomlWith("reqwest = { version = \"0.12\", features = [\"json\"] }  # 只走 HTTPS")
    let res = applyCargoTomlRules(toml)
    @Assert(outcomeOf(res, "R2-PORT-016").applied, true)
    @Assert(res.afterText.contains("# 只走 HTTPS"), true)
}

/** 纯函数：补回的默认特性跟版本走（0.11 没有 system-proxy，0.12 才有） */
@Test
public func testPreservedDefaultFeaturesByVersion(): Unit {
    let v11 = preservedDefaultFeatures("0.11.20")
    @Assert(v11.contains("charset"), true)
    @Assert(v11.contains("http2"), true)
    @Assert(v11.contains("system-proxy"), false)
    let v12 = preservedDefaultFeatures("0.12.22")
    @Assert(v12.contains("system-proxy"), true)
    // 0.10 及更早：集合不同，交给 guide，不机械补
    @Assert(preservedDefaultFeatures("0.10.9").size, 0)
    @Assert(reqwestMinorOf("0.12.22"), 12)
    @Assert(reqwestMinorOf("garbage"), -1)
}

/** 纯函数：两种写法都要能取到版本 */
@Test
public func testDepVersionOfForms(): Unit {
    @Assert(depVersionOf("reqwest = { version = \"0.12\", features = [] }"), "0.12")
    @Assert(depVersionOf("reqwest = \"0.12\"  # x"), "0.12")
    @Assert(depVersionOf("reqwest = { git = \"https://x/y\" }"), "https://x/y")
}

/** 纯函数：行尾注释只在引号之外才认（URL 里的 # 不算） */
@Test
public func testTrailingCommentRespectsQuotes(): Unit {
    @Assert(trailingCommentOf("reqwest = { git = \"https://x/#frag\" }"), "")
    @Assert(trailingCommentOf("reqwest = \"1\"  # 注释"), "# 注释")
    @Assert(trailingCommentOf("reqwest = \"1\""), "")
}

func indexOfFp(items: ArrayList<Diagnosis>, id: String): Int64 {
    var k: Int64 = 0
    while (k < items.size) {
        if (items[k].fingerprint.id == id) {
            return k
        }
        k += 1
    }
    return -1
}

/**
 * FP-021 命中，且**排在 FP-016 之前**。
 * 现场这两串日志是同时出现的（openssl-sys 的 build script 也打 pkg-config 那句），
 * 而 FP-016 归因给 glib-sys/GTK——顺序错了，agent 就会顺着 GTK 那条走偏。
 */
@Test
public func testFp021OpenSslHitsAndPrecedesFp016(): Unit {
    let log = "error: failed to run custom build command for `openssl-sys v0.9.109`\n" +
        "--- stderr\n" +
        "Could not find directory of OpenSSL installation, and this `-sys` crate cannot\n" +
        "pkg-config has not been configured to support cross-compilation.\n"
    let items = diagnoseLog(log)
    let i21 = indexOfFp(items, "FP-021")
    let i16 = indexOfFp(items, "FP-016")
    @Assert(i21 >= 0, true)
    @Assert(i16 >= 0, true)
    @Assert(i21 < i16, true)
    @Assert(items[i21].ruleId, "R2-PORT-016")
    @Assert(items[i21].patchKind, PK_RULE)
}

/** 任务书必须自己说清这条（agent 唯一必读的入口；技能是按需读的） */
@Test
public func testDirectiveMentionsTlsStack(): Unit {
    let inp = AutoPortInput()
    inp.project = "probe"
    inp.projectDir = "C:/probe"
    inp.cliPath = "C:/lingqu/cli/target/release/bin/main.exe"
    let d = buildAutoPortDirective(inp)
    @Assert(d.contains("TLS 栈"), true)
    @Assert(d.contains("openssl-sys"), true)
    @Assert(d.contains("R2-PORT-016"), true)
    // 自查命令与"别去装 OpenSSL"的死路提示都要在
    @Assert(d.contains("-i openssl-sys"), true)
    @Assert(d.contains("PKG_CONFIG_ALLOW_CROSS"), true)
}
