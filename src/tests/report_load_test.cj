package lingqu.tests

import lingqu.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 0.39.98 单测：⑦ 迁移报告屏的「落档回读」映射（纯函数）。
 *
 * 起因（§4-135 判据①，⑤⑥ 屏的同族）：agent 用 `lingqu-cli report` 跑完，
 * `.lingqu/report/<工程>.json` 躺在盘上、结论俱全，界面却渲染成
 * `reportOk=false / reportRate=-1` —— 因为 `REPORT` 只在人点「生成迁移报告」时才被填。
 * 回读**只读盘、不重新生成**：重出一遍会写盘三份文件，屏幕上的数字就成了"重算的那份"。
 */

func rpIntOf(o: JsonObject, k: String): Int64 {
    match (o.get(k)) {
        case Some(v) => return match (v.kind()) {
            case JsonKind.JsInt => v.asInt().getValue()
            case _ => -999
        }
        case None => return -999
    }
}

func rpBoolOf(o: JsonObject, k: String): Bool {
    match (o.get(k)) {
        case Some(v) => return match (v.kind()) {
            case JsonKind.JsBool => v.asBool().getValue()
            case _ => false
        }
        case None => return false
    }
}

func rpStrOf(o: JsonObject, k: String): String {
    match (o.get(k)) {
        case Some(v) => return match (v.kind()) {
            case JsonKind.JsString => v.asString().getValue()
            case _ => ""
        }
        case None => return ""
    }
}

func rpArrayLenOf(o: JsonObject, k: String): Int64 {
    match (o.get(k)) {
        case Some(v) => return match (v.kind()) {
            case JsonKind.JsArray => v.asArray().size()
            case _ => -999
        }
        case None => return -999
    }
}

/** 取嵌套对象的整数字段（`stats.stepDone` / `risk.high` 这种） */
func rpNestedIntOf(o: JsonObject, objKey: String, k: String): Int64 {
    match (o.get(objKey)) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsObject => return rpIntOf(v.asObject(), k)
            case _ => return -999
        }
        case None => return -999
    }
}

let RP_FULL = "{\"schema\":\"lingqu/report/v1\",\"project\":\"demo\",\"path\":\".\"," +
    "\"generatedAt\":\"2026-11-08T19:26:25+08:00\"," +
    "\"conclusion\":\"demo：8 步完成 3/8（37%），核心功能可用率 尚未验证，0 处人工介入\"," +
    "\"sections\":[" +
    "{\"key\":\"did\",\"title\":\"做了什么\",\"lines\":[\"a\",\"b\"]}," +
    "{\"key\":\"undone\",\"title\":\"没做什么\",\"lines\":[\"c\"]}," +
    "{\"key\":\"need\",\"title\":\"需要你做什么\",\"lines\":[\"d\",\"e\",\"f\"]}]," +
    "\"artifacts\":[{\"label\":\"报告\",\"path\":\"x.md\"}]," +
    "\"risk\":{\"level\":\"high\",\"label\":\"高\",\"summary\":\"总体：高（高 1 / 中 1 / 低 1，共 3 条）\"," +
    "\"high\":1,\"mid\":1,\"low\":1," +
    "\"items\":[{\"title\":\"t\",\"level\":\"high\",\"levelLabel\":\"高\",\"impact\":\"i\",\"action\":\"a\"}]}," +
    "\"stats\":{\"stepDone\":3,\"stepTotal\":8,\"stepPercent\":37,\"nextStep\":\"build\"," +
    "\"verifyRate\":-1,\"humanAccepted\":0}," +
    "\"files\":{\"md\":\"x.md\",\"html\":\"x.html\"}}"

/** 主路径：三段计数、统计、风险别名、产物路径重定位都要对得上落档 */
@Test
public func testReportRecordOfMapsFullRecord(): Unit {
    let res = reportRecordOf(JsonObject(), JsonValue.fromStr(RP_FULL), "C:/work/demo", "demo")
    @Assert(rpBoolOf(res, "ok"), true)
    @Assert(rpStrOf(res, "generatedAt"), "2026-11-08T19:26:25+08:00")
    @Assert(rpStrOf(res, "conclusion").contains("3/8"), true)
    // 三段计数按 sections 顺序（did/undone/need），不是按 key 猜
    @Assert(rpIntOf(res, "didCount"), 2)
    @Assert(rpIntOf(res, "undoneCount"), 1)
    @Assert(rpIntOf(res, "needCount"), 3)
    @Assert(rpArrayLenOf(res, "sections"), 3)
    @Assert(rpArrayLenOf(res, "artifacts"), 1)
    // 统计整段透传：界面按 stepDone/verifyRate 取，不能丢
    @Assert(rpNestedIntOf(res, "stats", "stepDone"), 3)
    @Assert(rpNestedIntOf(res, "stats", "verifyRate"), -1)
    // 风险：落档是嵌套 risk{...}，界面读扁平 riskXxx，两套都得有值
    @Assert(rpStrOf(res, "riskLevel"), "high")
    @Assert(rpStrOf(res, "riskLabel"), "高")
    @Assert(rpIntOf(res, "riskHigh"), 1)
    @Assert(rpArrayLenOf(res, "riskItems"), 1)
    // 产物路径按工程路径重定位（落档里记的是相对 CWD 的路径）。
    // 只断"落在工程目录里 + 文件名对"，**不断 `C:/…` 字面量**：`lqPathOf` 会按宿主归一分隔符
    // （Windows 上是反斜杠），断字面量等于断错了对象（§4-65 同族：断言要断语义）
    let md = rpStrOf(res, "md")
    @Assert(md.contains("report"), true)
    @Assert(md.contains("demo.md"), true)
    @Assert(md.contains("work"), true)
    @Assert(md.startsWith(".lingqu"), false)
}

/** 边界①：空落档不崩——sections/artifacts/risk 都给空，计数给 0（不是 -1） */
@Test
public func testReportRecordOfToleratesEmptyRecord(): Unit {
    let res = reportRecordOf(JsonObject(), JsonValue.fromStr("{}"), "C:/work/demo", "demo")
    @Assert(rpIntOf(res, "didCount"), 0)
    @Assert(rpIntOf(res, "undoneCount"), 0)
    @Assert(rpIntOf(res, "needCount"), 0)
    @Assert(rpArrayLenOf(res, "sections"), 0)
    @Assert(rpArrayLenOf(res, "riskItems"), 0)
    @Assert(rpStrOf(res, "riskLevel"), "")
    @Assert(rpStrOf(res, "error"), "")
    // 落档里没有 stats 时也必须回一个对象（界面读 st.stepDone 不能炸）
    @Assert(rpNestedIntOf(res, "stats", "stepDone"), -999)
}

/** 边界②：只有一段（历史落档/半成品）时后面两段计 0，不许错位 */
@Test
public func testReportRecordOfPartialSections(): Unit {
    let text = "{\"sections\":[{\"key\":\"did\",\"title\":\"做了什么\",\"lines\":[\"a\",\"b\",\"c\"]}]}"
    let res = reportRecordOf(JsonObject(), JsonValue.fromStr(text), "C:/work/demo", "demo")
    @Assert(rpIntOf(res, "didCount"), 3)
    @Assert(rpIntOf(res, "undoneCount"), 0)
    @Assert(rpIntOf(res, "needCount"), 0)
}

/** 边界③：verifyRate=-1 是"尚未验证"，回读不许把它变成 0（§4-63：没跑过 ≠ 0 分） */
@Test
public func testReportRecordOfKeepsNotVerifiedSentinel(): Unit {
    let other = "{\"stats\":{\"stepDone\":8,\"stepTotal\":8,\"stepPercent\":100,\"verifyRate\":-1}}"
    let res = reportRecordOf(JsonObject(), JsonValue.fromStr(other), "C:/work/demo", "demo")
    @Assert(rpNestedIntOf(res, "stats", "verifyRate"), -1)
    @Assert(rpNestedIntOf(res, "stats", "stepPercent"), 100)
}
