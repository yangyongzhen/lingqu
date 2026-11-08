package lingqu.tests

import lingqu.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 0.39.88 单测：⑤ 构建打包 / ⑥ 真机验证 两屏的「落档回读」映射（纯函数）。
 *
 * 起因（§4-135 判据①）：agent 用 `lingqu-cli build|verify` 跑完，落档里
 * exitCode/产物/可用率俱全，界面却还写着"还没跑交叉编译 / 尚未验证"——
 * 干活的那一方写了落档，显示的那一方没跟上。
 * 回读**只读盘、不重跑**：重编一次是分钟级，而且显示的就成了另一份数字。
 */

func rlIntOf(o: JsonObject, k: String): Int64 {
    match (o.get(k)) {
        case Some(v) => return match (v.kind()) {
            case JsonKind.JsInt => v.asInt().getValue()
            case _ => -999
        }
        case None => return -999
    }
}

func rlBoolOf(o: JsonObject, k: String): Bool {
    match (o.get(k)) {
        case Some(v) => return match (v.kind()) {
            case JsonKind.JsBool => v.asBool().getValue()
            case _ => false
        }
        case None => return false
    }
}

func rlStrOf(o: JsonObject, k: String): String {
    match (o.get(k)) {
        case Some(v) => return match (v.kind()) {
            case JsonKind.JsString => v.asString().getValue()
            case _ => ""
        }
        case None => return ""
    }
}

func rlArrayLenOf(o: JsonObject, k: String): Int64 {
    match (o.get(k)) {
        case Some(v) => return match (v.kind()) {
            case JsonKind.JsArray => v.asArray().size()
            case _ => -999
        }
        case None => return -999
    }
}

/* ---- ⑤ 构建打包 ---- */

@Test
public func testBuildRecordOfMapsSuccess(): Unit {
    let text = "{\"schema\":\"lingqu/build/v1\",\"target\":\"aarch64-unknown-linux-ohos\"," +
        "\"exitCode\":0,\"errorCount\":0,\"warningCount\":0,\"baselineErrors\":0,\"stderrErrors\":0," +
        "\"artifacts\":[\"libnote_gen.so\"]," +
        "\"gates\":{\"passed\":true,\"failures\":[]}," +
        "\"assetDiff\":{\"ok\":true,\"matched\":[\"a.js\"],\"staleInSo\":[],\"missingInSo\":[]}," +
        "\"soPath\":\"C:/x/libnote_gen.so\",\"expectedSo\":\"libnote_gen.so\",\"diags\":[]}"
    let res = buildRecordOf(JsonObject(), JsonValue.fromStr(text))
    @Assert(rlBoolOf(res, "ok"), true)
    @Assert(rlIntOf(res, "exitCode"), 0)
    @Assert(rlIntOf(res, "errorCount"), 0)
    @Expect(rlStrOf(res, "soPath"), "C:/x/libnote_gen.so")
    @Expect(rlStrOf(res, "expectedSo"), "libnote_gen.so")
    @Assert(rlArrayLenOf(res, "artifacts"), 1)
}

@Test
public func testBuildRecordOfMapsFailure(): Unit {
    // 失败构建：退出码非 0 ⇒ ok=false，但**数字照抄**（别把 7 条错误读成 0，§4-57）
    let text = "{\"schema\":\"lingqu/build/v1\",\"exitCode\":101,\"errorCount\":7,\"warningCount\":2," +
        "\"artifacts\":[],\"gates\":{\"passed\":false,\"failures\":[\"编译未通过\"]}}"
    let res = buildRecordOf(JsonObject(), JsonValue.fromStr(text))
    @Assert(rlBoolOf(res, "ok"), false)
    @Assert(rlIntOf(res, "exitCode"), 101)
    @Assert(rlIntOf(res, "errorCount"), 7)
    @Assert(rlArrayLenOf(res, "artifacts"), 0)
}

@Test
public func testBuildRecordOfToleratesMissingFields(): Unit {
    // 老落档 / 半截落档：缺字段一律回落 -1 / 空数组，绝不编 0（"没跑过"与"跑了 0 错误"是两个位，§4-63）
    let res = buildRecordOf(JsonObject(), JsonValue.fromStr("{}"))
    @Assert(rlBoolOf(res, "ok"), false)
    @Assert(rlIntOf(res, "exitCode"), -1)
    @Assert(rlArrayLenOf(res, "artifacts"), 0)
    @Assert(rlArrayLenOf(res, "diags"), 0)
}

/* ---- ⑥ 真机验证 ---- */

@Test
public func testVerifyRecordOfMapsStats(): Unit {
    // 字段形态按真实落档抄：统计在 `stats` 段里，不在顶层（§4-57 第 1 条）
    let text = "{\"schema\":\"lingqu/verify/v1\",\"project\":\"m3u8dl-tauri\",\"bundleName\":\"com.x.note\"," +
        "\"serial\":\"3QC0124B20000048\"," +
        "\"stats\":{\"total\":12,\"pass\":7,\"fail\":1,\"limit\":0,\"unknown\":4,\"covered\":3," +
        "\"notVerified\":4,\"ratePercent\":100,\"scope\":\"features\",\"scopeNote\":\"分母=核心功能清单\"}," +
        "\"items\":[{\"id\":\"launch\",\"verdict\":\"pass\"},{\"id\":\"get_task\",\"verdict\":\"unknown\"}]}"
    let res = verifyRecordOf(JsonObject(), JsonValue.fromStr(text), 1, "C:/p/m3u8dl-tauri", "m3u8dl-tauri")
    @Assert(rlBoolOf(res, "ok"), true)
    @Assert(rlIntOf(res, "ratePercent"), 100)
    @Assert(rlIntOf(res, "pass"), 7)
    @Assert(rlIntOf(res, "covered"), 3)
    @Assert(rlIntOf(res, "notVerified"), 4)
    @Assert(rlIntOf(res, "screenshots"), 1)
    @Assert(rlArrayLenOf(res, "items"), 2)
    @Expect(rlStrOf(res, "scope"), "features")
    @Expect(rlStrOf(res, "bundleName"), "com.x.note")
}

@Test
public func testVerifyRecordOfLegacyWithoutCovered(): Unit {
    // 0.39.89 之前的老落档没有 covered/notVerified：要原样透出 -1，让界面标明"旧口径"，
    // 而不是拿 0 当分母（0/0 会被渲染成 0% 可用率，那是凭空下降）
    let text = "{\"schema\":\"lingqu/verify/v1\",\"stats\":{\"total\":9,\"pass\":5,\"fail\":1,\"limit\":2," +
        "\"unknown\":1,\"ratePercent\":71},\"items\":[]}"
    let res = verifyRecordOf(JsonObject(), JsonValue.fromStr(text), 0, "C:/p/x", "x")
    @Assert(rlIntOf(res, "covered"), -1)
    @Assert(rlIntOf(res, "notVerified"), -1)
    @Assert(rlIntOf(res, "ratePercent"), 71)
    @Assert(rlIntOf(res, "limit"), 2)
}
