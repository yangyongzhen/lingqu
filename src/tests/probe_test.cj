package lingqu.tests

import std.collection.*
import stdx.encoding.json.*
import lingqu.*

/*
 * 真机功能探针（`lingqu-cli probe`）的单测（纯函数，D-009）。
 *
 * 这里钉的是**判据**，不是文案：
 *   · 点完"只有时钟在变"必须判 fail——版面节点数 35→34 这种差值造不出通过；
 *   · 点完真的冒出新东西（新节点文本 / 日志出现期望行）才算 pass；
 *   · dump 失败（点前版面是空的）只能判 unknown，绝不能当通过；
 *   · 写回落档是**合并**，不许把别的功能项的结论冲掉（`verify_feed` 按 features 逐项读）。
 */

/** 一个节点（测试里手工造版面树用） */
func nodeOf(text: String, bounds: String, clickable: Bool): LayoutNode {
    let n = LayoutNode()
    n.text = text
    match (parseBoundsOf(bounds)) {
        case Some(b) =>
            n.left = b[0]
            n.top = b[1]
            n.right = b[2]
            n.bottom = b[3]
        case None => ()
    }
    n.clickable = clickable
    return n
}

@Test
public func testParseBoundsCentre(): Unit {
    // 设备实际格式（1840×2800 视口）："[840,0][1000,80]"
    let b = match (parseBoundsOf("[840,0][1000,80]")) {
        case Some(v) => v
        case None => return
    }
    @Assert(b[0], 840)
    @Assert(b[1], 0)
    @Assert(b[2], 1000)
    @Assert(b[3], 80)
    let c = clickCentreOf(b[0], b[1], b[2], b[3])
    @Assert(c[0], 920)
    @Assert(c[1], 40)
    // 非法输入必须是 None，不许默默当成 0 坐标（点错地方比报错更糟）
    var bad = 0
    match (parseBoundsOf("")) {
        case Some(_) => bad += 1
        case None => ()
    }
    match (parseBoundsOf("[1,2][3]")) {
        case Some(_) => bad += 1
        case None => ()
    }
    match (parseBoundsOf("oops")) {
        case Some(_) => bad += 1
        case None => ()
    }
    @Assert(bad, 0)
}

@Test
public func testParseLayoutNodesNested(): Unit {
    // uitest dumpLayout 的真实形态：{attributes, children:[...]}，深两层
    let json = "{\"attributes\":{\"bounds\":\"[0,0][1840,2800]\",\"text\":\"\"},\"children\":[" +
        "{\"attributes\":{\"bounds\":\"[100,200][400,300]\",\"text\":\"开始下载\",\"clickable\":\"true\"},\"children\":[]}," +
        "{\"attributes\":{\"bounds\":\"[100,400][400,500]\",\"text\":\"选择文件\",\"clickable\":\"false\"}," +
        "\"children\":[{\"attributes\":{\"bounds\":\"[120,420][380,480]\",\"text\":\"选择文件\",\"clickable\":\"true\"},\"children\":[]}]}]}"
    let nodes = parseLayoutNodes(json)
    // 三条有文本的节点都要收到（根节点 text 空，不算）
    @Assert(nodes.size, 3)
    var foundStart = false
    for (n in nodes) {
        if (n.text == "开始下载") {
            foundStart = true
            @Assert(n.clickable, true)
            @Assert(n.left, 100)
            @Assert(n.right, 400)
        }
    }
    @Assert(foundStart, true)
}

@Test
public func testFindNodeByTextPrefersInner(): Unit {
    let nodes = ArrayList<LayoutNode>()
    nodes.add(nodeOf("选择文件", "[100,400][400,500]", false))
    nodes.add(nodeOf("选择文件", "[120,420][380,480]", true))
    nodes.add(nodeOf("开始下载", "[100,200][400,300]", true))
    let hit = match (findNodeByText(nodes, "选择文件")) {
        case Some(n) => n
        case None => return
    }
    // 取最小面积的那个（内层真正接收点击的节点），不是第一个命中的外框
    @Assert(hit.left, 120)
    @Assert(hit.right, 380)
}

@Test
public func testFindNodeByTextNotFound(): Unit {
    let nodes = ArrayList<LayoutNode>()
    nodes.add(nodeOf("开始下载", "[100,200][400,300]", true))
    var hits = 0
    match (findNodeByText(nodes, "选择文件")) {
        case Some(_) => hits += 1
        case None => ()
    }
    @Assert(hits, 0)
}

@Test
public func testTimeTextDetection(): Unit {
    @Assert(looksLikeTimeText("15:35:24"), true)
    @Assert(looksLikeTimeText("15:35"), true)
    @Assert(looksLikeTimeText("9:05"), true)
    @Assert(looksLikeTimeText("选择文件"), false)
    @Assert(looksLikeTimeText(""), false)
    @Assert(looksLikeTimeText("0 件商品"), false)
}

@Test
public func testProbeFailsWhenOnlyClockChanges(): Unit {
    // 现场真值（m3u8dl-tauri 点「选择文件」）：节点 35→34，只有时钟文本变了
    let before = ArrayList<LayoutNode>()
    before.add(nodeOf("15:35:01", "[900,10][1000,60]", false))
    before.add(nodeOf("开始下载", "[100,200][400,300]", true))
    let after = ArrayList<LayoutNode>()
    after.add(nodeOf("15:35:24", "[900,10][1000,60]", false))
    after.add(nodeOf("开始下载", "[100,200][400,300]", true))
    let v = judgeProbe(before, after, "", "")
    @Assert(v.verdict, "fail")
    // note 必须说清"没有新东西"，不能让读的人以为测过了
    @Assert(v.note.contains("新增"), false)
}

@Test
public func testProbePassesOnNewNode(): Unit {
    // 点了之后真弹出选择器：多出一批新文本
    let before = ArrayList<LayoutNode>()
    before.add(nodeOf("开始下载", "[100,200][400,300]", true))
    let after = ArrayList<LayoutNode>()
    after.add(nodeOf("开始下载", "[100,200][400,300]", true))
    after.add(nodeOf("最近使用", "[80,900][1760,960]", false))
    let v = judgeProbe(before, after, "", "")
    @Assert(v.verdict, "pass")
    @Assert(v.note.contains("最近使用"), true)
}

@Test
public func testProbePassesOnExpectedLog(): Unit {
    // 版面没变，但运行日志出现期望行（例：「请先输入 m3u8 地址」）→ 通道是通的
    let before = ArrayList<LayoutNode>()
    before.add(nodeOf("开始下载", "[100,200][400,300]", true))
    let after = ArrayList<LayoutNode>()
    after.add(nodeOf("开始下载", "[100,200][400,300]", true))
    let v = judgeProbe(before, after, "请先输入 m3u8 地址", "15:35:24 请先输入 m3u8 地址或选择本地文件")
    @Assert(v.verdict, "pass")
}

@Test
public func testProbeUnknownWhenDumpFailed(): Unit {
    // 点前就没 dump 到（设备没连 / uitest 起不来）：只能 unknown，绝不是 pass
    let before = ArrayList<LayoutNode>()
    let after = ArrayList<LayoutNode>()
    after.add(nodeOf("开始下载", "[100,200][400,300]", true))
    let v = judgeProbe(before, after, "", "")
    @Assert(v.verdict, "unknown")
}

@Test
public func testMergeProbeKeepsOtherFeatures(): Unit {
    // 已有别的功能的结论，这次只补一个新功能——老条目一个字都不能丢
    let existing = "{\"_schema\":\"lingqu/verify-probe/v1\",\"serial\":\"OLD\",\"features\":{" +
        "\"start_download\":{\"verdict\":\"pass\",\"note\":\"老结论\",\"evidence\":\"a.json\"}}}"
    let merged = mergeProbeDocument(existing, "pick_m3u8_file", "fail", "点「选择文件」无弹出",
        ".lingqu/shots/pick.layout.json", "5VFUN26310G06052", "2026-11-08T16:00:00+08:00")
    let root = JsonValue.fromStr(merged).asObject()
    let feats = jsonFieldAsObject(root, "features")
    // 老条目还在
    let old = jsonFieldAsObject(feats, "start_download")
    @Assert(jsonFieldAsString(old, "verdict"), "pass")
    @Assert(jsonFieldAsString(old, "note"), "老结论")
    // 新条目按 verify_feed 认的字段名写（verdict / note / evidence）
    let nw = jsonFieldAsObject(feats, "pick_m3u8_file")
    @Assert(jsonFieldAsString(nw, "verdict"), "fail")
    @Assert(jsonFieldAsString(nw, "note"), "点「选择文件」无弹出")
    @Assert(jsonFieldAsString(nw, "evidence"), ".lingqu/shots/pick.layout.json")
    // 顶层 schema 与 serial 跟着刷新
    @Assert(jsonFieldAsString(root, "_schema"), "lingqu/verify-probe/v1")
    @Assert(jsonFieldAsString(root, "serial"), "5VFUN26310G06052")
}

@Test
public func testMergeProbeIntoEmptyDocument(): Unit {
    // 落档不存在（第一次跑）：从空串起也要能写出合法 JSON
    let merged = mergeProbeDocument("", "detect_ffmpeg", "pass", "未找到（回退二进制合并）", "", "S1",
        "2026-11-08T16:00:00+08:00")
    let root = JsonValue.fromStr(merged).asObject()
    @Assert(jsonFieldAsString(root, "_schema"), "lingqu/verify-probe/v1")
    let feats = jsonFieldAsObject(root, "features")
    let it = jsonFieldAsObject(feats, "detect_ffmpeg")
    @Assert(jsonFieldAsString(it, "verdict"), "pass")
}
