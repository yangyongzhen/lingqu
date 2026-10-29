package lingqu.tests

import lingqu.scanner.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * C2 发现置信度的单元测试（P2 收尾）。
 *
 * 只测纯函数：解析基线、双向 diff、C2/precision 的算法边界。
 * 「真实工程的 C2 是多少」属于集成证据，写在 docs/进度记录.md，不在这里造假。
 */

func bl(items: Array<(String, String, String)>): Baseline {
    let b = Baseline()
    b.project = "demo"
    b.source = "人工通读（测试）"
    for ((k, n, v) in items) {
        b.add(k, n, v, "")
    }
    return b
}

func item(kind: String, name: String): ScanItem {
    let it = ScanItem(kind, name)
    it.site("src/x.ts", 1)
    return it
}

// ---------------- 解析：容错比严格更重要 ----------------

@Test
public func testParseBaselineReadsItems(): Unit {
    let text = "{\"schema\":\"lingqu/baseline/v1\",\"project\":\"demo\",\"source\":\"人工通读 src/\",\"items\":[{\"kind\":\"command\",\"name\":\"list_x\",\"verdict\":\"不适用\",\"note\":\"纯数据\"},{\"kind\":\"frontend\",\"name\":\"localStorage\",\"verdict\":\"改造\"}]}"
    let b = parseBaseline(text)
    @Expect(b.project, "demo")
    @Expect(b.source, "人工通读 src/")
    @Expect(b.total(), 2)
    @Expect(b.items[0].kind, "command")
    @Expect(b.items[0].name, "list_x")
    @Expect(b.items[0].verdict, "不适用")
    @Expect(b.items[1].verdict, "改造")
    // 缺 note 字段回空串，不抛、不产生"null"字面量
    @Expect(b.items[1].note, "")
    @Expect(b.countOf("frontend"), 1)
}

@Test
public func testParseBaselineToleratesBadInput(): Unit {
    // 语法错：返回空基线（扫描照常进行，C2 退化为"未对照"）
    @Expect(parseBaseline("{不是 json").total(), 0)
    // 顶层不是对象
    @Expect(parseBaseline("[1,2,3]").total(), 0)
    // 没有 items 字段
    @Expect(parseBaseline("{\"project\":\"x\"}").total(), 0)
    // 单项缺 kind/name → 跳过该项，其余保留
    let mixed = "{\"items\":[{\"name\":\"orphan\"},{\"kind\":\"command\",\"name\":\"ok\"},{\"kind\":\"command\"}]}"
    let b = parseBaseline(mixed)
    @Expect(b.total(), 1)
    @Expect(b.items[0].name, "ok")
}

// ---------------- diff：两个方向都要看 ----------------

@Test
public func testDiffConfidenceAllMatched(): Unit {
    let base = bl([("command", "a", "不适用"), ("frontend", "localStorage", "改造")])
    let items = ArrayList<ScanItem>()
    items.add(item("command", "a"))
    items.add(item("frontend", "localStorage"))
    let cf = diffConfidence(base, items)
    @Expect(cf.baselineTotal, 2)
    @Expect(cf.matched, 2)
    @Expect(cf.missed.size, 0)
    @Expect(cf.extra.size, 0)
    @Expect(Int64(cf.c2()), 100)
    @Expect(Int64(cf.precision()), 100)
}

@Test
public func testDiffConfidenceCountsMissed(): Unit {
    // 基线 3 项、扫描只认出 2 项 → C2 = 2/3
    let base = bl([("command", "a", ""), ("command", "b", ""), ("frontend", "canvas.toDataURL", "改造")])
    let items = ArrayList<ScanItem>()
    items.add(item("command", "a"))
    items.add(item("command", "b"))
    let cf = diffConfidence(base, items)
    @Expect(cf.missed.size, 1)
    @Expect(cf.missed[0], "frontend/canvas.toDataURL")
    @Expect(Int64(cf.c2()), 66)  // 66.66… 截断
    // 漏识别会落到对应类别的 missed 里，能定位
    var feMissed: Int64 = -1
    for (kc in cf.byKind) {
        if (kc.kind == "frontend") {
            feMissed = kc.missed.size
        }
    }
    @Expect(feMissed, 1)
}

@Test
public func testDiffConfidenceCountsExtra(): Unit {
    // 扫描多认一项：不扣 C2，但要计数（可能基线漏写，也可能扫描器多认）
    let base = bl([("command", "a", "")])
    let items = ArrayList<ScanItem>()
    items.add(item("command", "a"))
    items.add(item("platform", "getVersion"))
    let cf = diffConfidence(base, items)
    @Expect(cf.extra.size, 1)
    @Expect(cf.extra[0], "platform/getVersion")
    @Expect(Int64(cf.c2()), 100)
    @Expect(Int64(cf.precision()), 50)  // 1 命中 / 2 扫描项
}

@Test
public func testDiffConfidenceNoBaselineIsNotHundred(): Unit {
    // 没基线时 C2 必须是 -1（未对照），绝不能顺口算成 100
    let cf = diffConfidence(Baseline(), ArrayList<ScanItem>())
    @Expect(cf.baselineTotal, 0)
    @Expect(Int64(cf.c2()), -1)
    @Expect(Int64(cf.precision()), -1)
}

@Test
public func testDiffConfidenceDetectsVerdictDiff(): Unit {
    let base = bl([("frontend", "fetch", "降级")])
    let items = ArrayList<ScanItem>()
    let it = item("frontend", "fetch")
    it.decide("人工", "", "跨源 fetch 待确认")
    items.add(it)
    let cf = diffConfidence(base, items)
    @Expect(cf.missed.size, 0)
    @Expect(cf.verdictDiff.size, 1)
    @Expect(Int64(cf.c2()), 100)  // 发现到了就算命中；结论分歧单列
}

@Test
public func testDiffConfidenceTrimsNameWhitespace(): Unit {
    // 基线是人手写的，行尾空格/制表符很常见 —— 去掉首尾空白再比
    let base = bl([("frontend", " localStorage ", "改造")])
    let items = ArrayList<ScanItem>()
    items.add(item("frontend", "localStorage"))
    let cf = diffConfidence(base, items)
    @Expect(cf.missed.size, 0)
    @Expect(cf.matched, 1)
}
