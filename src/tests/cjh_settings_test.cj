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
