package lingqu.scanner

import std.collection.*
import stdx.encoding.json.*

/*
 * C2 发现置信度 —— 与**人工基线清单**双向 diff（P2 收尾，口径见 docs/P2-scan-口径草案.md §A4）
 *
 * 为什么需要它：C1 = D/R 只证明「识别到的项都有结论」，**证明不了「该识别的没漏」**。
 * 一个只认得 3 个能力的扫描器也能拿 C1=100%（或者干脆把一切都标 `人工`）。
 * C2 用人工通读代码列出的清单做地基，量两个方向：
 *   ① 漏识别（recall 面）：基线有、扫描没有 → C2 = 1 − 漏识别/基线项数
 *   ② 误识别（precision 面）：扫描有、基线没有 → 单列，不计入 C2（但计数要能看见）
 * 另外记一项「结论分歧 verdictDiff」：两边都识别到，但给的处置结论不同 —— 用来盯判定表质量。
 *
 * 基线的**判定结论不参与** C1/C2 计算，只作对照；覆盖率永远由扫描器自己的结论决定。
 */

// ===== 基线清单 =====

/** 基线里的一项：kind 取扫描器的同名口径（command/event/plugin/frontend/platform） */
public class BaselineItem {
    public var kind: String
    public var name: String
    /** 人工给的参考结论（改造/降级/不适用/人工），仅用于对照，不参与覆盖率 */
    public var verdict: String
    public var note: String

    public init(kind: String, name: String, verdict: String, note: String) {
        this.kind = kind
        this.name = name
        this.verdict = verdict
        this.note = note
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("kind", JsonString(this.kind))
        o.put("name", JsonString(this.name))
        o.put("verdict", JsonString(this.verdict))
        o.put("note", JsonString(this.note))
        return o
    }
}

/** 一份人工基线（`lingqu/baseline/v1`） */
public class Baseline {
    public var schema: String = ""
    public var project: String = ""
    /** 这份清单怎么来的（谁、什么时候、通读了哪些文件）——可复核才有意义 */
    public var source: String = ""
    public var items: ArrayList<BaselineItem> = ArrayList<BaselineItem>()

    public init() {}

    public func total(): Int64 {
        return this.items.size
    }

    public func add(kind: String, name: String, verdict: String, note: String): Unit {
        this.items.add(BaselineItem(kind, name, verdict, note))
    }

    public func countOf(kind: String): Int64 {
        var n: Int64 = 0
        for (it in this.items) {
            if (it.kind == kind) {
                n += 1
            }
        }
        return n
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("schema", JsonString(if (this.schema.size == 0) { "lingqu/baseline/v1" } else { this.schema }))
        o.put("project", JsonString(this.project))
        o.put("source", JsonString(this.source))
        var arr = JsonArray()
        for (it in this.items) {
            arr.add(it.toJson())
        }
        o.put("items", arr)
        o.put("count", JsonInt(this.total()))
        return o
    }
}

/** 容错解析：语法错、缺 items、单项缺 kind/name 都只跳过，不抛（基线的坏数据不该让扫描失败） */
public func parseBaseline(text: String): Baseline {
    let bl = Baseline()
    var root: JsonValue
    try {
        root = JsonValue.fromStr(text)
    } catch (e: Exception) {
        let _ = e
        return bl
    }
    var obj: JsonObject
    match (root.kind()) {
        case JsonKind.JsObject => obj = root.asObject()
        case _ => return bl
    }
    bl.schema = jsonStrOf(obj, "schema")
    bl.project = jsonStrOf(obj, "project")
    bl.source = jsonStrOf(obj, "source")
    match (obj.get("items")) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsArray =>
                    let arr = v.asArray()
                    var i: Int64 = 0
                    while (i < arr.size()) {
                        let e = arr[i]
                        match (e.kind()) {
                            case JsonKind.JsObject =>
                                let eo = e.asObject()
                                let k = jsonStrOf(eo, "kind")
                                let n = jsonStrOf(eo, "name")
                                if (k.size > 0 && n.size > 0) {
                                    bl.items.add(BaselineItem(k, n, jsonStrOf(eo, "verdict"), jsonStrOf(eo, "note")))
                                }
                            case _ => ()
                        }
                        i += 1
                    }
                case _ => ()
            }
        case None => ()
    }
    return bl
}

/** 取对象里的字符串字段（缺失/类型不符回空串） */
func jsonStrOf(o: JsonObject, key: String): String {
    match (o.get(key)) {
        case Some(v) => match (v.kind()) {
            case JsonKind.JsString => return v.asString().getValue()
            case _ => return ""
        }
        case None => return ""
    }
}

// ===== 双向 diff =====

/** 一个类别上的比对结果 */
public class KindConf {
    public var kind: String
    public var baseline: Int64 = 0
    public var matched: Int64 = 0
    public var missed: ArrayList<String> = ArrayList<String>()
    public var extra: ArrayList<String> = ArrayList<String>()
    public var verdictDiff: ArrayList<String> = ArrayList<String>()

    public init(kind: String) {
        this.kind = kind
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("kind", JsonString(this.kind))
        o.put("baseline", JsonInt(this.baseline))
        o.put("matched", JsonInt(this.matched))
        o.put("missed", IntArrayJson(this.missed))
        o.put("extra", IntArrayJson(this.extra))
        o.put("verdictDiff", IntArrayJson(this.verdictDiff))
        return o
    }
}

/** 整份比对结果：C2 与误识别都在这里 */
public class Confidence {
    public var source: String = ""
    public var baselineTotal: Int64 = 0
    public var matched: Int64 = 0
    public var missed: ArrayList<String> = ArrayList<String>()
    public var extra: ArrayList<String> = ArrayList<String>()
    public var verdictDiff: ArrayList<String> = ArrayList<String>()
    public var byKind: ArrayList<KindConf> = ArrayList<KindConf>()

    public init() {}

    /** C2 发现置信度（百分比）= (基线项 − 漏识别) / 基线项；无基线时返回 -1（**不是** 100） */
    public func c2(): Float64 {
        if (this.baselineTotal == 0) {
            return -1.0
        }
        return Float64(this.baselineTotal - this.missed.size) * 100.0 / Float64(this.baselineTotal)
    }

    /** 误识别占比的反面：precision = 命中 / 扫描项；无扫描项时 -1 */
    public func precision(): Float64 {
        let denom = this.matched + this.extra.size
        if (denom == 0) {
            return -1.0
        }
        return Float64(this.matched) * 100.0 / Float64(denom)
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("schema", JsonString("lingqu/confidence/v1"))
        o.put("source", JsonString(this.source))
        o.put("baselineTotal", JsonInt(this.baselineTotal))
        o.put("matched", JsonInt(this.matched))
        o.put("missedCount", JsonInt(Int64(this.missed.size)))
        o.put("extraCount", JsonInt(Int64(this.extra.size)))
        o.put("verdictDiffCount", JsonInt(Int64(this.verdictDiff.size)))
        o.put("C2", JsonFloat(this.c2()))
        o.put("precision", JsonFloat(this.precision()))
        o.put("missed", IntArrayJson(this.missed))
        o.put("extra", IntArrayJson(this.extra))
        o.put("verdictDiff", IntArrayJson(this.verdictDiff))
        var kinds = JsonArray()
        for (k in this.byKind) {
            kinds.add(k.toJson())
        }
        o.put("byKind", kinds)
        return o
    }
}

/** 字符串列表 → JsonArray（项目里反复要用，集中一处） */
func IntArrayJson(xs: ArrayList<String>): JsonArray {
    var arr = JsonArray()
    for (s in xs) {
        arr.add(JsonString(s))
    }
    return arr
}

/** 比对键：类别 + 规范化名字（只去首尾空白；**大小写敏感**，因为规范名是人定的、要对得上） */
func confKey(kind: String, name: String): String {
    return kind + "|" + name.trimAscii()
}

let CONF_KINDS: Array<String> = ["command", "event", "plugin", "frontend", "platform"]

/**
 * 双向 diff：基线 × 扫描项。
 *
 * - 漏识别（missed）：基线有、扫描没有 —— 这一项直接扣 C2
 * - 误识别（extra）：扫描有、基线没有 —— 只计数（可能是基线漏写，也可能是扫描器多认，都要人看）
 * - 结论分歧（verdictDiff）：两边都有但结论不同 —— 只计数，不影响 C1/C2
 */
public func diffConfidence(baseline: Baseline, items: ArrayList<ScanItem>): Confidence {
    let conf = Confidence()
    conf.source = baseline.source
    conf.baselineTotal = baseline.total()

    let scanByKey = HashMap<String, ScanItem>()
    for (it in items) {
        scanByKey.add(confKey(it.kind, it.name), it)
    }
    let blByKey = HashMap<String, BaselineItem>()
    for (bi in baseline.items) {
        blByKey.add(confKey(bi.kind, bi.name), bi)
    }

    // 类别有序：先按固定五类，再补基线里出现的未知类别（出现的也要看得见，不能静默消失）
    let kindOrder = ArrayList<String>()
    for (k in CONF_KINDS) {
        kindOrder.add(k)
    }
    for (bi in baseline.items) {
        if (!kindOrder.contains(bi.kind)) {
            kindOrder.add(bi.kind)
        }
    }
    let confByKind = HashMap<String, KindConf>()
    for (k in kindOrder) {
        confByKind.add(k, KindConf(k))
    }

    // 方向一：基线 → 扫描（漏识别 + 结论分歧）
    for (bi in baseline.items) {
        let key = confKey(bi.kind, bi.name)
        match (confByKind.get(bi.kind)) {
            case Some(kc) => kc.baseline += 1
            case None => ()
        }
        if (!scanByKey.contains(key)) {
            match (confByKind.get(bi.kind)) {
                case Some(kc) => kc.missed.add(bi.name)
                case None => ()
            }
            conf.missed.add("${bi.kind}/${bi.name}")
        } else {
            match (confByKind.get(bi.kind)) {
                case Some(kc) => kc.matched += 1
                case None => ()
            }
            conf.matched += 1
            let hit = scanByKey.get(key).getOrThrow()
            if (bi.verdict.size > 0 && hit.verdict != bi.verdict) {
                match (confByKind.get(bi.kind)) {
                    case Some(kc) => kc.verdictDiff.add(bi.name)
                    case None => ()
                }
                conf.verdictDiff.add("${bi.kind}/${bi.name}: 扫描=${hit.verdict} 基线=${bi.verdict}")
            }
        }
    }

    // 方向二：扫描 → 基线（误识别）
    for (it in items) {
        if (!blByKey.contains(confKey(it.kind, it.name))) {
            match (confByKind.get(it.kind)) {
                case Some(kc) => kc.extra.add(it.name)
                case None => ()
            }
            conf.extra.add("${it.kind}/${it.name}")
        }
    }

    for (k in kindOrder) {
        match (confByKind.get(k)) {
            case Some(kc) => conf.byKind.add(kc)
            case None => ()
        }
    }
    return conf
}
