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

/* ---------- ④ 一键执行：安全边界（纯函数） ---------- */

@Test
public func testCliRunAllowedReadOnly(): Unit {
    let empty = JsonObject()
    // 只读/幂等可回滚的放开
    for (c in ["scan", "deps", "resume", "report", "verify", "env", "diagnose", "batch", "build"]) {
        let (ok, _) = cliRunAllowed(c, empty)
        @Assert(ok, true)
    }
    // sign 体检允许，但 --apply（改用户工程）必须拒
    let (sigOk, _) = cliRunAllowed("sign", empty)
    @Assert(sigOk, true)
    let apply = JsonObject()
    apply.put("apply", JsonBool(true))
    let (sigApplyOk, why) = cliRunAllowed("sign", apply)
    @Assert(sigApplyOk, false)
    @Assert(why.contains("写回签名配置"), true)
}

@Test
public func testCliRunAllowedBlocksRisky(): Unit {
    let empty = JsonObject()
    // 动真机 / 改工程 / 耗时长：一律拒，并且要告诉人"去哪点"
    let cases = [("deploy", "安装并启动"), ("port", "预览改造"), ("revert", "回滚"), ("hap", "装配 HAP"),
                 ("decisions", "人工决策")]
    for (pair in cases) {
        let (ok, why) = cliRunAllowed(pair[0], empty)
        @Assert(ok == false, true)
        @Assert(why.contains(pair[1]), true)
    }
    // 不认识的命令也拒（别把未知命令当只读放过去）
    let (ok, _) = cliRunAllowed("rm_rf", empty)
    @Assert(ok, false)
}

@Test
public func testCliSuggestParse(): Unit {
    // 从 AI 回复里抽建议命令：列表符号、行内码、重复行都要处理
    let text = "建议这样跑：\n- `lingqu-cli resume --path .`\n* lingqu-cli scan --path .\n"
        + "lingqu-cli resume --path .\n其它文字不含命令\n"
    let sug = cliSuggestParse(text)
    @Assert(sug.size, 2)     // resume 与 scan 各一条（重复的 resume 去重）
    @Assert(sug[0].contains("resume"), true)
    @Assert(sug[1].contains("scan"), true)
    // 拆 argv：去掉 lingqu-cli 本身
    let argv = cliSuggestArgv("lingqu-cli build --path . --verifyOnly")
    @Assert(argv.size, 4)
    @Assert(argv[0], "build")
    @Assert(cliArgvCommand(argv.toArray()), "build")
    // 空文本 / 没有命令 → 空表（别造出空建议按钮）
    @Assert(cliSuggestParse("").size, 0)
    @Assert(cliSuggestParse("这里只有普通文字").size, 0)
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

// ===== 0.39.153：无界面入口 autoport 可达 =====

@Test
public func autoportIsReachableFromCli(): Unit {
    @Assert(cliCommandSupported("autoport"), true)
    let o = argvToJson(["autoport", "--path", "E:/p"])
    @Assert(o.get("autoport").isSome(), true)
    // 用法文本要列出来（agent 靠它发现工具）
    @Assert(cliUsage().contains("lingqu-cli autoport"), true)
    // 界面上"一键跑"必须拒（会起一整轮 agent + 改工程），命令行仍可直跑
    let (ok, why) = cliRunAllowed("autoport", JsonObject())
    @Assert(ok, false)
    @Assert(why.contains("一键迁移"), true)
}
