package lingqu.tests

import lingqu.*

/*
 * cjh 设置定点修补（`ensureKeepRunningOnDisconnect`）单测。
 *
 * 背景：cjh 断连会打断本轮（0.39.8 起可选），灵渠的 AI 自动迁移必须在
 * `autoport_start` 时自动把 `web.keep_running_on_disconnect` 打开，
 * 不该让用户手改 settings.json。这里覆盖四种形态 + 幂等。
 */

@Test
public func testInjectsKeyIntoExistingWebObject(): Unit {
    let json = "{\n  \"web\": {\n    \"port\": 8765\n  },\n  \"model\": \"x\"\n}"
    let out = ensureKeepRunningOnDisconnect(json)
    @Assert(out.contains("keep_running_on_disconnect"), true)
    @Assert(out.contains("\"keep_running_on_disconnect\": true"), true)
    @Assert(out.contains("\"port\": 8765"), true)   // 原有字段不丢
    @Assert(out.contains("\"model\": \"x\""), true) // web 段之外的也没被碰
}

@Test
public func testIdempotentWhenAlreadyTrue(): Unit {
    let json = "{\"web\": {\"keep_running_on_disconnect\": true, \"port\": 8765}}"
    @Assert(ensureKeepRunningOnDisconnect(json), json)
}

@Test
public func testFlipsFalseToTrue(): Unit {
    let json = "{\"web\": {\"keep_running_on_disconnect\": false, \"port\": 8765}}"
    let out = ensureKeepRunningOnDisconnect(json)
    @Assert(out.contains("\"keep_running_on_disconnect\": true"), true)
    @Assert(out.contains("false"), false)
    @Assert(out.contains("\"port\": 8765"), true)
}

@Test
public func testNoWebSectionLeavesJsonAlone(): Unit {
    // 没有 web 段：不猜、不动（调用方按"already"处理，不会写坏文件）
    let json = "{\"model\": \"x\"}"
    @Assert(ensureKeepRunningOnDisconnect(json), json)
}

@Test
public func testEmptyInputSafe(): Unit {
    @Assert(ensureKeepRunningOnDisconnect(""), "")
    @Assert(ensureKeepRunningOnDisconnect("   "), "   ")   // 空白输入原样返回
}

@Test
public func testEnsureCjhKeepRunningWithoutHome(): Unit {
    // 拿不到 home 时不许抛异常，返回可判定的串
    @Assert(ensureCjhKeepRunning(""), "no-home")
    // 不存在的目录 → 没有 settings.json
    @Assert(ensureCjhKeepRunning("/definitely-not-exist-lingqu-home"), "no-settings")
}

/*
 * 0.39.53：AI 自动迁移开跑前把 cjh 的 max_iterations 抬到够用。
 * 现场：整应用迁移跑到 41 轮被截断（cjh 默认 40），agent 没机会收尾。
 */

/** 夹具：贴近 `~/.cjh/settings.json` 的真实形状（字段顺序/缩进都照抄，别理想化） */
func cjhSettingsFixture(): String {
    var s = "{\n"
    s += "  \"base_url\": \"https://api.deepseek.com\",\n"
    s += "  \"model\": \"gpt-4o-mini\",\n"
    s += "  \"max_iterations\": 40,\n"
    s += "  \"temperature\": 0.7,\n"
    s += "  \"web\": {\n"
    s += "    \"keep_running_on_disconnect\": true\n"
    s += "  }\n"
    s += "}\n"
    return s
}

@Test
public func testMaxIterationsOf(): Unit {
    @Assert(maxIterationsOf(cjhSettingsFixture()), 40)
    // 没有这个键 → -1（不猜默认值）
    @Assert(maxIterationsOf("{\"model\":\"x\"}"), -1)
    // 键存在但值不是数字 → -1
    @Assert(maxIterationsOf("{\"max_iterations\": \"40\"}"), -1)
    @Assert(maxIterationsOf(""), -1)
}

@Test
public func testEnsureMaxIterationsRaisesAndIsIdempotent(): Unit {
    let fixed = ensureMaxIterations(cjhSettingsFixture(), 120)
    @Assert(maxIterationsOf(fixed), 120)
    // 其它字段一个都不能丢/不能重排（定点修补，不整体序列化）
    @Assert(fixed.contains("\"model\": \"gpt-4o-mini\""), true)
    @Assert(fixed.contains("\"temperature\": 0.7"), true)
    @Assert(fixed.contains("\"keep_running_on_disconnect\": true"), true)
    // 幂等：再抬一次原样返回
    @Assert(ensureMaxIterations(fixed, 120), fixed)
    // 只抬不降：已经 120，要求 60 也不动
    @Assert(ensureMaxIterations(fixed, 60), fixed)
    // 用户自己设得更大：不动
    let big = ensureMaxIterations("{\"max_iterations\": 500}", 120)
    @Assert(maxIterationsOf(big), 500)
}

@Test
public func testEnsureMaxIterationsInsertsWhenMissing(): Unit {
    let noKey = "{\n  \"model\": \"x\"\n}\n"
    let fixed = ensureMaxIterations(noKey, 120)
    @Assert(maxIterationsOf(fixed), 120)
    @Assert(fixed.contains("\"model\": \"x\""), true)
    // 空文本不乱改
    @Assert(ensureMaxIterations("", 120), "")
}

@Test
public func testIterationsAwareOfBothKeySpellings(): Unit {
    // 关键差异（0.39.53 实测）：**文件**里是 `max_iterations`（snake），而 `GET /api/settings`
    // 回的是 `maxIterations`（camel）。只认一种的话，live 路径会误判成"读不到"，白落文件。
    let apiBody = "{\"baseUrl\":\"x\",\"maxIterations\":120}"
    @Assert(maxIterationsOf(apiBody), 120)
    @Assert(maxIterKeyOf(apiBody), "\"maxIterations\"")
    // 文件形态
    @Assert(maxIterKeyOf(cjhSettingsFixture()), "\"max_iterations\"")
    // camel 形态也能就地抬高（并保持其它字段）
    let camel40 = "{\"model\":\"gpt-4o-mini\",\"maxIterations\":40}"
    let raised = ensureMaxIterations(camel40, 120)
    @Assert(maxIterationsOf(raised), 120)
    @Assert(raised.contains("\"model\":\"gpt-4o-mini\""), true)
}

/* ============================================================
 * 接入协议（0.39.62）：openai 兼容 / anthropic
 *
 * 为什么要有这一组：cjh 的 `POST /api/settings` 白名单里**没有** provider_protocol，
 * 只能定点修补 `~/.cjh/settings.json`。修补写坏了 = 用户下次起引擎直接起不来，
 * 所以取值/写入/幂等都按纯函数钉死。
 * ============================================================ */

@Test
public func testNormalizeProtocol(): Unit {
    @Assert(normalizeProtocol("openai"), "openai")
    @Assert(normalizeProtocol("anthropic"), "anthropic")
    @Assert(normalizeProtocol("  Anthropic "), "anthropic")   // 大小写与空白都归一
    @Assert(normalizeProtocol("gemini"), "")                  // 不认识 → 空（绝不猜）
    @Assert(normalizeProtocol(""), "")
}

@Test
public func testProviderProtocolOf(): Unit {
    // 文件形态（snake，带缩进）
    @Assert(providerProtocolOf("{\n  \"provider_protocol\": \"anthropic\",\n  \"model\": \"x\"\n}"), "anthropic")
    // camel 也认（API/手写都可能出现）
    @Assert(providerProtocolOf("{\"providerProtocol\":\"openai\"}"), "openai")
    // 没有该键 / 不是字符串 / 空文本 → 空串（调用方按 cjh 默认 openai 理解）
    @Assert(providerProtocolOf("{\"model\":\"x\"}"), "")
    @Assert(providerProtocolOf("{\"provider_protocol\": null}"), "")
    @Assert(providerProtocolOf("{\"provider_protocol\": 1}"), "")
    @Assert(providerProtocolOf(""), "")
}

@Test
public func testSetProviderProtocolReplacesInPlace(): Unit {
    // 主路径：已有键、值不同 → 就地替换，其它字段一个不动
    let src = "{\n  \"provider_protocol\": \"openai\",\n  \"model\": \"gpt-4o-mini\"\n}"
    let out = setProviderProtocol(src, "anthropic")
    @Assert(providerProtocolOf(out), "anthropic")
    @Assert(out.contains("\"provider_protocol\": \"anthropic\""), true)
    @Assert(out.contains("\"model\": \"gpt-4o-mini\""), true)
    // 幂等：同值原样返回（不产生 diff，就不会白白覆盖用户文件）
    @Assert(setProviderProtocol(out, "anthropic"), out)
}

@Test
public func testSetProviderProtocolInsertsWhenMissing(): Unit {
    // 没有该键 → 插到最外层 `{` 之后，原有字段保留
    let out = setProviderProtocol("{\n  \"model\": \"x\"\n}", "anthropic")
    @Assert(providerProtocolOf(out), "anthropic")
    @Assert(out.contains("\"model\": \"x\""), true)
    // 边界：不认识的值 / 空 JSON / 没有 `{` 都不许动
    @Assert(setProviderProtocol("{\"provider_protocol\": \"openai\"}", "gemini"),
        "{\"provider_protocol\": \"openai\"}")
    @Assert(setProviderProtocol("", "openai"), "")
    @Assert(setProviderProtocol("not json", "openai"), "not json")
}

@Test
public func testSetProviderProtocolHandlesEscapesAndCamel(): Unit {
    // 值里带转义的引号：不能让扫描器把 `\"` 当成结束引号（否则会把文件截断）
    let src = "{\"provider_protocol\": \"a\\\"b\", \"model\": \"x\"}"
    let out = setProviderProtocol(src, "openai")
    @Assert(providerProtocolOf(out), "openai")
    @Assert(out.contains("\"model\": \"x\""), true)
    // camel 形态就地替换时也用回 camel 键（不新增一个 snake 键，避免同一文件两套写法）
    let camel = setProviderProtocol("{\"providerProtocol\": \"openai\"}", "anthropic")
    @Assert(camel.contains("\"providerProtocol\": \"anthropic\""), true)
    @Assert(camel.contains("provider_protocol"), false)
}

/**
 * 0.39.82：轮次预算「落地了没有」的判据。
 *
 * 现场：用户实测整应用迁移跑到 **62/40** 就停了，界面只写"回合结束"。
 * 查下来 `ensureCjhIterationBudget` 返回 `file:…（需重启 cjh 生效）`——
 * 值写进了 `~/.cjh/settings.json`，但正在跑回合的引擎内存里还是默认 40，
 * 于是"抬上去"这件事等于没做，直到 40 轮被截断。判据必须区分"写进去了"与"引擎认了"。
 */
@Test
public func testIterBudgetStateOf(): Unit {
    // 引擎现在就认：live（POST 生效）与 restart-ok（重启后复验通过）都算落地
    @Assert(iterBudgetStateOf("live:40->120"), "applied")
    @Assert(iterBudgetStateOf("restart-ok:120"), "applied")
    // 本来就够：不必动
    @Assert(iterBudgetStateOf("already:120>=120"), "already")
    // 只写了文件 = **没生效**（本次 62/40 的真凶）
    @Assert(iterBudgetStateOf("file:40->120（需重启 cjh 生效）"), "needs-restart")
    // 写不进去的几种形态都要归到 failed，别被当成"已落地"
    @Assert(iterBudgetStateOf("error:FSException: permission denied"), "failed")
    @Assert(iterBudgetStateOf("no-settings"), "failed")
    // 边界：空串/认不出的形态 → failed（宁可报没做成，也不能报做成）
    @Assert(iterBudgetStateOf(""), "failed")
    @Assert(iterBudgetStateOf("  "), "failed")
    // 边界：前后空白不影响判定（日志里带缩进是常事）
    @Assert(iterBudgetStateOf("  file:40->120  "), "needs-restart")
}

@Test
public func testIterBudgetSatisfiedOf(): Unit {
    // 0.39.91 复现：live 已被上次 POST 抬到 120，而 ~/.cjh/settings.json 里还是 40。
    // 旧判据只看 live ⇒ 判 already、不写盘 ⇒ 引擎一重启回落 40（41 rounds 实测 15 次）。
    @Assert(iterBudgetSatisfiedOf(120, 40, 120), false)
    // 双达标才算满足
    @Assert(iterBudgetSatisfiedOf(120, 120, 120), true)
    @Assert(iterBudgetSatisfiedOf(200, 300, 120), true)
    // live 读不到（引擎不在）→ 没满足，该去落文件
    @Assert(iterBudgetSatisfiedOf(-1, 120, 120), false)
    // 两边都没有 → 没满足
    @Assert(iterBudgetSatisfiedOf(-1, -1, 120), false)
    // 文件高、live 低（引擎刚起还没应用）→ 没满足，需重启才能生效那一路
    @Assert(iterBudgetSatisfiedOf(40, 120, 120), false)
}

// ------------------------------------------------------------
// MCP HTTP 服务器注入（ensureMcpHttpServer / ensureCjhMcpKms）
// ------------------------------------------------------------

@Test
public func testMcpHttpInsertsIntoExistingMcpServersSection(): Unit {
    let json = "{\n  \"model\": \"x\",\n  \"mcp_servers\": {\n    \"local\": { \"transport\": \"stdio\", \"command\": \"npx\" }\n  }\n}"
    let out = ensureMcpHttpServer(json, "harmonyos_developer_knowledge", "https://example.com/mcp")
    // 新服务器插进已有段里
    @Assert(out.contains("\"harmonyos_developer_knowledge\""), true)
    @Assert(out.contains("\"transport\": \"http\""), true)
    @Assert(out.contains("\"url\": \"https://example.com/mcp\""), true)
    // 原有服务器与字段不丢
    @Assert(out.contains("\"local\""), true)
    @Assert(out.contains("\"model\": \"x\""), true)
    @Assert(out.contains("\"command\": \"npx\""), true)
}

@Test
public func testMcpHttpAddsWholeSectionWhenAbsent(): Unit {
    let json = "{\n  \"model\": \"x\"\n}"
    let out = ensureMcpHttpServer(json, "harmonyos_developer_knowledge", "https://example.com/mcp")
    @Assert(out.contains("\"mcp_servers\""), true)
    @Assert(out.contains("\"harmonyos_developer_knowledge\""), true)
    @Assert(out.contains("\"model\": \"x\""), true)
}

@Test
public func testMcpHttpIdempotentWhenServerExists(): Unit {
    let json = "{\"mcp_servers\": {\"harmonyos_developer_knowledge\": { \"transport\": \"http\", \"url\": \"https://mine.example/mcp\" }}}"
    // 已有同名服务器：绝不覆盖（用户可能自己调过 url/env）
    @Assert(ensureMcpHttpServer(json, "harmonyos_developer_knowledge", "https://example.com/mcp"), json)
}

@Test
public func testMcpHttpRejectsEmptyInput(): Unit {
    @Assert(ensureMcpHttpServer("", "a", "https://e.com"), "")
    @Assert(ensureMcpHttpServer("{}", "", "https://e.com"), "{}")
    @Assert(ensureMcpHttpServer("{}", "a", ""), "{}")
    // 没有 '{' 的畸形文本：原样返回
    @Assert(ensureMcpHttpServer("not json", "a", "https://e.com"), "not json")
}
