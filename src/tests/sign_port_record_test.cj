package lingqu.tests

import lingqu.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 0.39.114 单测：③ 规则改造 / ④ 签名 两屏的「落档回读」映射（纯函数）。
 *
 * 起因（§4-135 判据①）：agent 用 `lingqu-cli port --apply` / `lingqu-cli sign` 跑完，
 * 落档里 applied / 签名态俱全，界面却还是「—」/「尚未体检」——
 * 干活的那一方写了落档，显示的那一方没跟上（①②⑤⑥⑦ 在 0.39.87/88 补过，③④ 漏了）。
 * 回读**只读盘、不重跑**：重扫会得到"现在这一刻"的数，与落档成了两份（§4-138）。
 */

/* ---- ④ 签名 ---- */

@Test
public func testSignRecordOfMapsCheckRecord(): Unit {
    // 体检档：真值在 check.ok，顶层没有 ok（两种形态都要认，§4-115）
    let text = "{\"schema\":\"lingqu/sign/v1\",\"project\":\"habit-tree\"," +
        "\"udid\":\"3QC0124B20000048\",\"projectBundle\":\"com.a.b\",\"candidateCount\":2," +
        "\"candidatePath\":\"C:/u/.ohos/config/x.p7b\",\"candidateBundle\":\"com.a.b\"," +
        "\"candidateBundleMatch\":true,\"profileType\":\"debug\",\"generatedAt\":1765000000000," +
        "\"signing\":{\"configuredName\":\"default\",\"filesExist\":true}," +
        "\"check\":{\"ok\":true,\"reason\":\"\",\"nextStep\":\"\",\"configuredAllowsDevice\":true}," +
        "\"mode\":{\"mode\":\"debug\",\"modeLabel\":\"调试态\",\"canInstallDevice\":true," +
        "\"releaseReady\":false,\"reminder\":\"上架前要换 release profile\",\"releaseProfileCount\":0," +
        "\"switchSteps\":[\"申请 release 证书\"]}}"
    let res = signRecordOf(JsonValue.fromStr(text))
    @Assert(rlBoolOf(res, "loaded"), true)
    @Assert(rlBoolOf(res, "ok"), true)
    @Assert(rlBoolOf(res, "recordOnly"), true)
    @Expect(rlStrOf(res, "by"), "check")
    @Assert(rlBoolOf(res, "hasConfig"), true)
    @Expect(rlStrOf(res, "signingName"), "default")
    @Assert(rlBoolOf(res, "filesExist"), true)
    @Assert(rlBoolOf(res, "allowsDevice"), true)
    @Expect(rlStrOf(res, "profileType"), "debug")
    @Expect(rlStrOf(res, "mode"), "debug")
    @Assert(rlBoolOf(res, "canInstallDevice"), true)
    @Assert(rlBoolOf(res, "releaseReady"), false)
    @Assert(rlIntOf(res, "candidateCount"), 2)
    @Assert(rlIntOf(res, "generatedAt"), 1765000000000)
    @Assert(rlArrayLenOf(res, "switchSteps"), 1)
    @Expect(rlStrOf(res, "udid"), "3QC0124B20000048")
}

@Test
public func testSignRecordOfMapsAutoRecord(): Unit {
    // 自动签档：只有顶层 ok/error/nextStep + autoSign，没有 check/signing。
    // 这种档不该被渲染成"没配签名"——它恰恰是刚签成功的那一份。
    let text = "{\"schema\":\"lingqu/sign/v1\",\"project\":\"habit-tree\",\"by\":\"auto\",\"ok\":true," +
        "\"bundleName\":\"com.a.b\",\"generatedAt\":1765000001000," +
        "\"mode\":{\"mode\":\"auto\",\"modeLabel\":\"自动签名\",\"canInstallDevice\":true}}"
    let res = signRecordOf(JsonValue.fromStr(text))
    @Assert(rlBoolOf(res, "ok"), true)
    @Expect(rlStrOf(res, "by"), "auto")
    @Assert(rlBoolOf(res, "hasConfig"), true)
    @Assert(rlBoolOf(res, "filesExist"), true)
    // profile 类型不猜：落档没写就留空，别把 auto 硬说成 debug（猜错会让人以为"能装"）
    @Expect(rlStrOf(res, "profileType"), "")
    @Expect(rlStrOf(res, "mode"), "auto")
    @Assert(rlIntOf(res, "generatedAt"), 1765000001000)
}

@Test
public func testSignRecordOfFallsBackToModeWhenProfileTypeMissing(): Unit {
    // 老落档没写 profileType：按 mode 回填（mode 本身就是 profileType 的判定结果）
    let text = "{\"schema\":\"lingqu/sign/v1\",\"check\":{\"ok\":true}," +
        "\"mode\":{\"mode\":\"release\",\"modeLabel\":\"发布态\"}}"
    let res = signRecordOf(JsonValue.fromStr(text))
    @Expect(rlStrOf(res, "profileType"), "release")
    @Assert(rlBoolOf(res, "hasConfig"), false)
    // 缺字段一律回落 -1，绝不编 0（"没跑过"与"跑了 0"是两个位，§4-63）
    @Assert(rlIntOf(res, "generatedAt"), -1)
}

@Test
public func testSignRecordOfRejectsNonObject(): Unit {
    let res = signRecordOf(JsonValue.fromStr("[1,2,3]"))
    @Assert(rlBoolOf(res, "ok"), false)
    @Assert(rlBoolOf(res, "loaded"), false)
    @Assert(rlStrOf(res, "error").size > 0, true)
}

/* ---- ③ 规则改造 ---- */

@Test
public func testPortRecordOfMapsPortRun(): Unit {
    let text = "{\"schema\":\"lingqu/decisions/v1\",\"project\":\"p\"," +
        "\"items\":[{\"rule\":\"R1\"},{\"rule\":\"R2\"}]," +
        "\"portRun\":{\"apply\":true,\"applied\":3,\"auto\":2,\"human\":1,\"at\":1765000000000," +
        "\"outcomes\":[\"R1 applied\",\"R2 confirm\"]}}"
    let res = portRecordOf(JsonValue.fromStr(text))
    @Assert(rlBoolOf(res, "ok"), true)
    @Assert(rlBoolOf(res, "loaded"), true)
    @Assert(rlBoolOf(res, "recordOnly"), true)
    @Assert(rlBoolOf(res, "apply"), true)
    @Assert(rlIntOf(res, "applied"), 3)
    @Assert(rlIntOf(res, "auto"), 2)
    @Assert(rlIntOf(res, "guide"), 1)
    @Assert(rlIntOf(res, "at"), 1765000000000)
    @Assert(rlIntOf(res, "outcomesCount"), 2)
    @Assert(rlIntOf(res, "decisionsCount"), 2)
}

@Test
public func testPortRecordOfThirdStateHasItemsButNoRun(): Unit {
    // 第三态：只有人工决策、没有 portRun ⇒ 看得出记过决策，看不出改造跑没跑。
    // 既不许渲染成"跑过了（0 条）"，也不许渲染成"没跑过"（§4-63）。
    let text = "{\"schema\":\"lingqu/decisions/v1\",\"project\":\"p\"," +
        "\"items\":[{\"rule\":\"R1\",\"decision\":\"reject\"}]}"
    let res = portRecordOf(JsonValue.fromStr(text))
    @Assert(rlBoolOf(res, "loaded"), true)
    @Assert(rlBoolOf(res, "ok"), true)
    @Assert(rlIntOf(res, "decisionsCount"), 1)
    @Assert(rlIntOf(res, "applied"), -999)   // 没有这个位，不是 0
    @Assert(rlStrOf(res, "error").size > 0, true)
}

@Test
public func testPortRecordOfEmptyIsNotLoaded(): Unit {
    // 空对象 = 什么都没跑过：ok=false 且带原因，别让它显示成"应用了 0 条"（§4-94）
    let res = portRecordOf(JsonValue.fromStr("{}"))
    @Assert(rlBoolOf(res, "ok"), false)
    @Assert(rlBoolOf(res, "loaded"), false)
    @Assert(rlIntOf(res, "decisionsCount"), 0)
    @Assert(rlStrOf(res, "error").size > 0, true)
}

@Test
public func testPortRecordOfRejectsNonObject(): Unit {
    let res = portRecordOf(JsonValue.fromStr("\"oops\""))
    @Assert(rlBoolOf(res, "ok"), false)
    @Assert(rlBoolOf(res, "loaded"), false)
}
