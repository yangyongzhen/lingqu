package lingqu.tests

import lingqu.verify.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 0.39.114 单测：桥的**双侧判据**（§4-162）。
 *
 * 起因：把原生 UI 换成桥之后，Rust 侧调了 `call_arkts("pickFile")`，ArkTS 分发器里却没有
 * `case "pickFile"` —— `cargo build`（含 `--target aarch64-unknown-linux-ohos`）照样 exit=0，
 * `verify` 判 pass，**真机点了毫无反应**。因为 cargo 根本不编译 ArkTS，只有 hvigor 会审。
 *
 * 所以"落地"必须是两侧都在；只查 Rust 那一半就是假绿（§4-116 同族）。
 */

/** 造一个带桥调用的 Rust 命令（`#[cfg(ohos)]` 里走桥，桌面走原生） */
func rustBridgeFnOf(cmd: String): String {
    return "pub fn pick_file() -> Result<Option<String>, String> {\n" +
        "    #[cfg(all(target_os = \"linux\", target_env = \"ohos\"))]\n" +
        "    {\n" +
        "        return call_arkts(\"" + cmd + "\", \"{}\");\n" +
        "    }\n" +
        "    #[cfg(not(all(target_os = \"linux\", target_env = \"ohos\")))]\n" +
        "    {\n" +
        "        Ok(None)\n" +
        "    }\n" +
        "}\n"
}

/** 造一个只有纯 Rust 逻辑的命令（不该被桥判据扣分） */
func rustPlainFnOf(): String {
    return "pub fn add_two(a: i64) -> i64 {\n    a + 2\n}\n"
}

func arktsDispatchOf(cmd: String): String {
    return "const d = (cmd: string, args: string): string => {\n" +
        "  switch (cmd) {\n" +
        "    case \"" + cmd + "\":\n" +
        "      return handle(args);\n" +
        "    default:\n" +
        "      return JSON.stringify({ ok: false });\n" +
        "  }\n" +
        "};\n" +
        "(globalThis as ESObject).__ohos_dispatch = d;\n"
}

@Test
public func testBridgeCmdExtractedFromRust(): Unit {
    let src = rustBridgeFnOf("pickFile")
    @Expect(bridgeCmdInRustOf(src), "pickFile")
    @Expect(bridgeCmdInRustOf(rustPlainFnOf()), "")
}

@Test
public func testNonBridgeCommandIsNotJudged(): Unit {
    // 纯 Rust 逻辑：callsBridge=false —— 调用方不该拿它扣分（"不适用"≠"没落地"）
    let v = bridgeTwoSidedOf(rustPlainFnOf(), arktsDispatchOf("pickFile"), "add_two")
    @Assert(v.callsBridge, false)
    @Assert(v.landed, false)
}

@Test
public func testBothSidesLanded(): Unit {
    let v = bridgeTwoSidedOf(rustBridgeFnOf("pickFile"), arktsDispatchOf("pickFile"), "pick_file")
    @Assert(v.callsBridge, true)
    @Assert(v.landed, true)
    @Expect(v.cmd, "pickFile")
}

@Test
public func testOnlyRustSideIsNotLanded(): Unit {
    // 关键的假绿场景：Rust 调了桥，ArkTS 没有这一支 —— 必须判"没落地"并把缺的 cmd 说清
    let v = bridgeTwoSidedOf(rustBridgeFnOf("pickFile"), arktsDispatchOf("saveFile"), "pick_file")
    @Assert(v.callsBridge, true)
    @Assert(v.landed, false)
    @Assert(v.reason.indexOf("pickFile").isSome(), true)
}

@Test
public func testNoArktsDispatcherAtAll(): Unit {
    let v = bridgeTwoSidedOf(rustBridgeFnOf("pickFile"), "", "pick_file")
    @Assert(v.callsBridge, true)
    @Assert(v.landed, false)
    @Assert(v.reason.indexOf("__ohos_dispatch").isSome(), true)
}

@Test
public func testArktsSingleQuoteAndIfChainAlsoCount(): Unit {
    // 真实写法不止 switch one 种：单引号 case、以及 `if (cmd === 'x')` 都算落地
    let singleQuote = "switch (cmd) {\n  case 'pickFile':\n    return x;\n}\n"
    @Assert(arktsDispatchHasCmdOf(singleQuote, "pickFile"), true)
    let ifChain = "if (cmd === 'pickFile') { return x; }\n"
    @Assert(arktsDispatchHasCmdOf(ifChain, "pickFile"), true)
}

@Test
public func testArktsCmdMatchingIsNotSubstringSloppy(): Unit {
    // "pickFile" 不能因为页面上有 "pickFile2" 就判存在：比较要带引号（否则 c1 被 c1x 蒙过）
    @Assert(arktsDispatchHasCmdOf("case \"pickFile2\":", "pickFile"), false)
    @Assert(arktsDispatchHasCmdOf("case \"pickFile\":", "pickFile"), true)
}

// ---- 以下是 habit-tree / m3u8dl 的真实形态：cmd 走 JSON 协议字段，不在 call_arkts 参数里 ----

func habitTreeRustOf(): String {
    return "fn open_url(app: &AppHandle, url: String) -> Result<()> {\n" +
        "    let msg = format!(r#\"{{\"plugin\": \"grove\",\n" +
        "        \"cmd\": \"open_url\"}}\"#);\n" +
        "    dispatch_on_main(&msg)\n" +
        "}\n" +
        "fn save_card(...) -> Result<()> {\n" +
        "    let msg = format!(r#\"{{ \"plugin\": \"grove\", \"cmd\": \"save_card\" }}\"#);\n" +
        "    dispatch_on_main(&msg)\n" +
        "}\n"
}

func habitTreeEtsOf(): String {
    return "    (globalThis as ESObject).__ohos_dispatch = (msg: string): string => {\n" +
        "      const parsed = JSON.parse(msg) as DispatchMsg;\n" +
        "      if (parsed.plugin === 'grove' && parsed.cmd === 'save_card') {\n" +
        "        this.saveCardToGallery(parsed.payload.base64, parsed.payload.filename);\n" +
        "      }\n" +
        "      if (parsed.plugin === 'grove' && parsed.cmd === 'open_url') {\n" +
        "        this.openExternalUrl(parsed.payload.url);\n" +
        "      }\n" +
        "      return JSON.stringify({ ok: false, err: 'unknown cmd' });\n" +
        "    };\n"
}

@Test
public func testProtocolFormCmdsAreCollected(): Unit {
    // `"cmd": "x"` 这种形态必须收得到，否则整个 habit-tree 现场被判"不走桥"= 漏检
    let cmds = rustBridgeCmdsOf(habitTreeRustOf())
    @Assert(cmds.contains("open_url"), true)
    @Assert(cmds.contains("save_card"), true)
}

@Test
public func testProtocolFormEtsCountsAsLanded(): Unit {
    // `parsed.cmd === 'save_card'` 就是落地了（不是只有 switch case 才算）
    @Assert(arktsDispatchHasCmdOf(habitTreeEtsOf(), "save_card"), true)
    @Assert(arktsDispatchHasCmdOf(habitTreeEtsOf(), "share_card"), false)
}

@Test
public func testProjectLevelMissingDetectsHalfImplementation(): Unit {
    // 项目级比对：Rust 发了两个，ArkTS 只实现了一个 —— 缺的那个就是真机上没反应的那个
    let miss = missingBridgeCmdsOf(habitTreeRustOf(), habitTreeEtsOf())
    @Expect(miss.size, 0)   // open_url 与 save_card 两侧都在
    let halfEts = "parsed.cmd === \"save_card\"\n"
    let miss2 = missingBridgeCmdsOf(habitTreeRustOf(), halfEts)
    @Expect(miss2.size, 1)
    @Expect(miss2[0], "open_url")
}

@Test
public func testRustCmdNamesMustLookLikeIdentifiers(): Unit {
    // 注释/句子里出现的 "cmd": "..." 不该被当成命令名（否则会报一堆假缺口）
    let noisy = "// cmd: 这个字段由前端给\nlet cmd = \"随便什么值\";\n"
    @Expect(rustBridgeCmdsOf(noisy).size, 0)  // 没有冒号紧跟的引号值 → 不收
}
