package lingqu.tests

import lingqu.*
import stdx.encoding.json.*

/*
 * agent 行为轨迹的纯函数单测（0.39.0）。
 *
 * 这一层的风险是"记了但记不准"：一条轨迹要是把参数截没了、或把 JSON 拼坏，
 * 证据就变成噪声。所以钉三件事：路径拼法、截断语义、单行 JSON 可解析。
 */

@Test
public func testTracePaths(): Unit {
    // 跟着工程走（与落档同源）
    let p = tracePathOf("E:/test/rust/habit-tree")
    @Assert(p.contains("habit-tree"), true)
    @Assert(p.contains(".lingqu"), true)
    @Assert(p.endsWith("trace.jsonl"), true)
    // 空工程路径 → 应用目录（保持可用，不抛）
    let legacy = tracePathOf("")
    @Assert(legacy.contains(".lingqu"), true)
    @Assert(legacy.endsWith("trace.jsonl"), true)
    // 目录与文件同源（否则会出现"目录建了文件写别处"的经典坑）
    @Assert(p.startsWith(traceDirOf("E:/test/rust/habit-tree")), true)
}

@Test
public func testClipTraceDetail(): Unit {
    // 短内容原样保留（只把换行压成空格，保证一条一行）
    @Assert(clipTraceDetail("a\nb\tc", 100), "a b c")
    // 超长必截断且**明确标注**（读者要知道这不是全文）
    var long = ""
    var i = 0
    while (i < 200) {
        long += "x"
        i += 1
    }
    let clipped = clipTraceDetail(long, 20)
    @Assert(clipped.contains("截断"), true)
    @Assert(clipped.size < long.size, true)
    // 按字符切，不切坏汉字
    @Assert(clipTraceDetail("灵渠迁移台", 2).startsWith("灵渠"), true)
    // 边界
    @Assert(clipTraceDetail("abc", 0), "")
}

@Test
public func testAgentTraceLineIsParseableSingleLine(): Unit {
    let line = agentTraceLine("2026-11-01T10:00:00", "tool", "bash",
        "lingqu-cli build --path .\n(第二行不能破坏一行一条)")
    // 一行一条：不许带换行
    @Assert(line.contains("\n"), false)
    // 字段得真的在（别只信字符串包含：解析回来核对）
    // 注：toJsonString 是美化输出（`"kind": "tool"` 带空格），所以断言只认键值出现，不认紧凑形态
    @Assert(line.contains("\"kind\""), true)
    @Assert(line.contains("\"tool\""), true)
    @Assert(line.contains("\"bash\""), true)
    @Assert(line.contains("build --path"), true)
    let v = JsonValue.fromStr(line)
    match (v.kind()) {
        case JsonKind.JsObject =>
            let o = v.asObject()
            @Assert(o.size(), 4)
        case _ => @Assert("轨迹必须是 JSON 对象", line)
    }
}

@Test
public func testTraceLinesCountOfMissingFile(): Unit {
    // 不存在的工程：0 行（不是 -1，也不是抛异常）
    @Assert(agentTraceLines("E:/definitely-not-exist-project"), 0)
}
