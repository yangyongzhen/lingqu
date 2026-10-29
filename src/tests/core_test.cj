package lingqu.tests

import lingqu.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 灵渠的单元测试（门禁入口 scripts/test.ps1）。
 *
 * 只测**纯函数**：拼接、候选选择、端口解析、端点 JSON 形状、vendor 校验的失败路径。
 * 涉及进程、网络、WebView2、cjh 生命周期的部分一律以实机为准（AGENTS §1），
 * 不在这里造假绿——那是「看起来测过」而不是「测过」。
 *
 * 命名约定：文件名必须以 *_test.cj 结尾，发布构建会排除它（AGENTS §3）。
 */

// ---------------- joinPath：路径拼接的分隔符处理 ----------------

@Test
func testJoinPathAddsSeparator(): Unit {
    @Expect(joinPath("vendor", "cjh.exe"), "vendor\\cjh.exe")
}

@Test
func testJoinPathKeepsExistingBackslash(): Unit {
    @Expect(joinPath("vendor\\", "cjh.exe"), "vendor\\cjh.exe")
}

@Test
func testJoinPathKeepsExistingSlash(): Unit {
    // 跨平台路径（鸿蒙/Unix 也走同一份业务代码）
    @Expect(joinPath("vendor/", "cjh"), "vendor/cjh")
}

@Test
func testJoinPathEmptyBaseReturnsName(): Unit {
    @Expect(joinPath("", "cjh.exe"), "cjh.exe")
}

// ---------------- firstExisting：候选路径取第一个存在的 ----------------

@Test
func testFirstExistingPicksFirstHit(): Unit {
    // cjpm test 的工作目录是包根：cjpm.toml / README.md 一定在
    @Expect(firstExisting(["no-such-file-1", "cjpm.toml", "README.md"]), "cjpm.toml")
}

@Test
func testFirstExistingSkipsEmptyCandidate(): Unit {
    // 空串是「没配」的表示，不能被当成相对路径 CWD 去命中
    @Expect(firstExisting(["", "README.md"]), "README.md")
}

@Test
func testFirstExistingReturnsEmptyWhenNone(): Unit {
    @Expect(firstExisting(["no-such-file-1", "no-such-file-2"]), "")
}

// ---------------- parsePortEnv：端口环境变量的解析与兜底 ----------------

@Test
func testParsePortEnvAcceptsValidPort(): Unit {
    @Expect(parsePortEnv("8765", 1000), 8765)
    @Expect(parsePortEnv("1", 1000), 1)
    @Expect(parsePortEnv("65535", 1000), 65535)
}

@Test
func testParsePortEnvFallsBackOnOutOfRange(): Unit {
    @Expect(parsePortEnv("0", 1000), 1000)
    @Expect(parsePortEnv("65536", 1000), 1000)
    @Expect(parsePortEnv("-1", 1000), 1000)
}

@Test
func testParsePortEnvFallsBackOnGarbage(): Unit {
    @Expect(parsePortEnv("", 1000), 1000)
    @Expect(parsePortEnv("abc", 1000), 1000)
    @Expect(parsePortEnv("87x5", 1000), 1000)
}

// ---------------- putEndpoints：给前端的端点形状 ----------------

@Test
func testPutEndpointsShape(): Unit {
    var obj = JsonObject()
    putEndpoints(obj, 8765)
    @Expect(obj.get("port").getOrThrow().asInt().getValue(), 8765)
    @Expect(obj.get("apiUrl").getOrThrow().asString().getValue(), "http://127.0.0.1:8765")
    @Expect(obj.get("wsUrl").getOrThrow().asString().getValue(), "ws://127.0.0.1:8765/ws")
}

@Test
func testPutEndpointsOnlyLoopback(): Unit {
    // 安全约定：自己拉起的实例一律只绑回环，端点绝不能出现 0.0.0.0 或局域网地址
    var obj = JsonObject()
    putEndpoints(obj, 9000)
    let api = obj.get("apiUrl").getOrThrow().asString().getValue()
    let ws = obj.get("wsUrl").getOrThrow().asString().getValue()
    @Expect(api.startsWith("http://127.0.0.1:"), true)
    @Expect(ws.startsWith("ws://127.0.0.1:"), true)
    @Expect(api.contains("0.0.0.0"), false)
}

// ---------------- cjhVendorVerified：校验的失败路径 ----------------

@Test
func testVendorVerifyRejectsMissingDir(): Unit {
    // 目录不存在时必须回 false —— 上层据此报「引擎缺失」，而不是拿个空路径去执行
    @Expect(cjhVendorVerified("no-such-vendor-dir"), false)
}
