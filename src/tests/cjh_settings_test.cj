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