package lingqu.tests

import lingqu.*
import std.collection.*
import stdx.encoding.json.*

/*
 * ③ CLI 入口的纯函数单测（argv 解析 / 命令名判定）。
 *
 * 这一层最容易出的错是"参数形态没覆盖"——agent 写命令行不会总按我们想的样子写，
 * 所以两种形态（`--k v` 与 `--k=v`）、布尔开关、纯命令（不带任何开关）都要能解析。
 */

@Test
public func testArgvToJsonEqualsForm(): Unit {
    let argv = ["scan", "--path=E:/p", "--baseline=b.json"]
    let o = argvToJson(argv)
    assertHasKey(o, "scan")
    let args = objOf(o, "scan")
    assertStr(args, "path", "E:/p")
    assertStr(args, "baseline", "b.json")
}

@Test
public func testArgvToJsonSpaceForm(): Unit {
    // `--k v`：值在下一个元素（agent 最常这么写）
    let argv = ["build", "--path", "E:/p", "--verifyOnly"]
    let o = argvToJsonWithValues(argv)
    let args = objOf(o, "build")
    assertStr(args, "path", "E:/p")
    // 布尔开关不带值 → true
    match (args.get("verifyOnly")) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsBool => @Assert(v.asBool().getValue(), true)
                case _ => @Assert(false, true)
            }
        case None => @Assert(false, true)
    }
}

@Test
public func testArgvCommandWithoutFlags(): Unit {
    // 纯命令（不带开关）也要解析出命令键——否则分派层报"不认识的命令："（实测踩过）
    let o = argvToJson(["env"])
    assertHasKey(o, "env")
    // 未知命令同样要有键（这样才能给出"不认识的命令：nosuchcmd"而不是空名字）
    let o2 = argvToJson(["nosuchcmd"])
    assertHasKey(o2, "nosuchcmd")
    // 空 argv 里没有命令
    @Assert(cliHasCommand([]), false)
    @Assert(cliHasCommand(["--help"]), false)
    @Assert(cliHasCommand(["scan"]), true)
}

@Test
public func testCommandWhitelist(): Unit {
    // 界面上有的核心命令都要在 CLI 里可用（GUI 专属的 quit/cjh_* 不开放）
    for (c in ["scan", "deps", "port", "build", "hap", "sign", "deploy", "verify",
               "report", "batch", "resume", "skill", "agent_context"]) {
        @Assert(cliCommandSupported(c), true)
    }
    @Assert(cliCommandSupported("quit"), false)
    @Assert(cliCommandSupported("cjh_start"), false)
    @Assert(cliCommandSupported(""), false)
    // 用法文本要能列出全部命令（agent 靠它发现工具）
    let usage = cliUsage()
    for (c in CLI_COMMANDS) {
        @Assert(usage.contains(c), true)
    }
    @Assert(usage.contains("退出码"), true)
}

/* ---------- 测试内小工具 ---------- */

func assertHasKey(o: JsonObject, key: String): Unit {
    match (o.get(key)) {
        case Some(_) => ()
        case None => @Assert("缺少键 ${key}", "存在")
    }
}

func objOf(o: JsonObject, key: String): JsonObject {
    match (o.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsObject => return v.asObject()
                case _ => ()
            }
        case None => ()
    }
    return JsonObject()
}

func assertStr(o: JsonObject, key: String, expect: String): Unit {
    match (o.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => @Assert(v.asString().getValue(), expect)
                case _ => @Assert("${key} 不是字符串", expect)
            }
        case None => @Assert("缺少键 ${key}", expect)
    }
}
