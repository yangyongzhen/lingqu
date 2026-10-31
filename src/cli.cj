package lingqu

import cjTauri.*
import std.collection.*
import stdx.encoding.json.*

/*
 * ③ `t2h:*` 的 **CLI 入口**（AI 接入计划第 3 步，2026-11-01）。
 *
 * 为什么必须有这一步：`t2h:scan/build/deploy/...` 一直只是**应用内 IPC 命令**
 * （页面 ↔ 应用），agent 的 bash 根本调不到。装了技能、写了 AGENTS.md 之后，
 * AI 也只会"讲"迁移怎么做，不会"做"——缺的就是一个能被 bash 调的可执行入口。
 *
 * 做法（**零重构**）：命令实现都是 `CommandHandler`，本身就是
 * `handle(name, JsonObject, IpcContext) -> JsonValue` 的纯数据接口；CLI 直接
 * `XxxCommand().handle(name, args, IpcContext("cli", IpcHub()))` 即可——
 * 不需要窗口、不需要 WebView，事件类输出走 hub 的 no-op sink（CLI 不需要推事件）。
 *
 * 三层：
 *   · `argvToJson(argv)`  纯函数：`scan --path X --verifyOnly` → `{scan:{path:X, verifyOnly:true}}`
 *   · `cliCommandNames()` 纯函数：可用的命令名（给 `--list` 与错误提示）
 *   · `dispatchCli(argv)` 有 IO：按名字挑 handler、执行、把结果序列化成 JSON 文本
 */

/** CLI 支持的命令（与注册表一致；GUI 专属的 quit/cjh_* 不开放） */
public let CLI_COMMANDS: Array<String> = [
    "scan", "deps", "port", "revert", "decisions", "diagnose", "build", "hap", "sign",
    "deploy", "verify", "report", "batch", "resume", "env", "skill", "agent_context"
]

/** 允许的布尔开关（没有值就算 true；写成 `--x false` 也算 false） */
func cliIsBoolFlag(key: String): Bool {
    for (k in ["screenshot", "verifyOnly", "apply", "start", "all", "json"]) {
        if (k == key) {
            return true
        }
    }
    return false
}

/**
 * 纯函数：argv → `{命令: {参数}}`。
 *
 * 约定（给模型看，所以要好记）：
 *   `lingqu-cli scan --path E:/p --baseline b.json` → `{"scan":{"path":"E:/p","baseline":"b.json"}}`
 *   `lingqu-cli build --path E:/p --verifyOnly`      → 布尔开关不带值时算 true
 *   `lingqu-cli scan --path=E:/p`                     → 也认 `--k=v` 写法
 * 第一个非 `--` 参数是命令名；没有命令名返回空对象（调用方打印用法）。
 */
public func argvToJson(argv: Array<String>): JsonObject {
    let out = JsonObject()
    var cmd = ""
    for (a in argv) {
        if (a == "--list" || a == "-h" || a == "--help") {
            continue
        }
        if (!a.startsWith("--") && cmd == "") {
            cmd = a
            // 命令名一出现就占位：否则"不带任何开关"的命令（如 `lingqu-cli env`）
            // 解析出来是空对象，分派层会报"不认识的命令："（0.34.0 编译后实测踩到）
            out.put(cmd, JsonObject())
            continue
        }
        if (!a.startsWith("--")) {
            continue      // 多余的位置参数忽略（CLI 只用 --flag 形式）
        }
        var key = a[2..a.size]
        var value = ""
        var hasValue = false
        let eq = key.indexOf("=")
        match (eq) {
            case Some(i) =>
                value = key[(i + 1)..key.size]
                key = key[0..i]
                hasValue = true
            case None => ()
        }
        // 用 `--` 作为"这条命令行到此为止"没有意义（CLI 只解析自己的开关），保持简单
        if (key == "") {
            continue
        }
        match (out.get(cmd)) {
            case Some(v) =>
                match (v.kind()) {
                    case JsonKind.JsObject =>
                        if (hasValue) {
                            v.asObject().put(key, JsonString(value))
                        } else {
                            v.asObject().put(key, JsonBool(true))
                        }
                    case _ => ()
                }
            case None =>
                let args = JsonObject()
                if (hasValue) {
                    args.put(key, JsonString(value))
                } else {
                    args.put(key, JsonBool(true))
                }
                out.put(cmd, args)
        }
    }
    return out
}

/**
 * 纯函数：`--k v` 形态（值在下一个 argv 元素）要不要支持？
 *
 * 支持——但只在**纯解析**这一层判断：`argvToJson` 之上再走一遍，把
 * `{k:true, <下一个裸值>}` 这种形态粘起来。命令行习惯不容易统一，两种都认最省事。
 */
public func argvToJsonWithValues(argv: Array<String>): JsonObject {
    // 先把 `--k v` 归一成 `--k=v`，再交给 argvToJson（保持单一解析实现）
    let norm = ArrayList<String>()
    var i: Int64 = 0
    while (i < argv.size) {
        let a = argv[i]
        if (a.startsWith("--") && !a.contains("=")) {
            let isBool = cliIsBoolFlag(a[2..a.size])
            // 下一个元素不是开关、也不是命令名（前面已有命令名）→ 当作它的值
            if (!isBool && i + 1 < argv.size && !argv[i + 1].startsWith("--")) {
                norm.add(a + "=" + argv[i + 1])
                i += 2
                continue
            }
        }
        norm.add(a)
        i += 1
    }
    return argvToJson(norm.toArray())
}

/** 纯函数：有没有命令名（没有就该打印用法） */
public func cliHasCommand(argv: Array<String>): Bool {
    for (a in argv) {
        if (!a.startsWith("--")) {
            return true
        }
    }
    return false
}

/** 纯函数：命令名是否受支持 */
public func cliCommandSupported(name: String): Bool {
    for (c in CLI_COMMANDS) {
        if (c == name) {
            return true
        }
    }
    return false
}

/** CLI 用法（打印给人和模型看） */
public func cliUsage(): String {
    var text = "lingqu-cli —— 灵渠迁移台的命令行入口（给 AI agent 的 bash 用）\n\n"
    text += "用法：lingqu-cli <命令> --键 值 … [--json]\n"
    text += "      lingqu-cli --list            列出可用命令\n\n"
    text += "可用命令：\n"
    for (c in CLI_COMMANDS) {
        text += "  ${c}\n"
    }
    text += "\n示例：\n"
    text += "  lingqu-cli scan --path E:/work/habit-tree\n"
    text += "  lingqu-cli build --path E:/work/habit-tree --verifyOnly\n"
    text += "  lingqu-cli sign --path E:/work/habit-tree\n"
    text += "  lingqu-cli resume --path E:/work/habit-tree\n"
    text += "  lingqu-cli report --path E:/work/habit-tree\n\n"
    text += "说明：命令与界面上的按钮一一对应（同一份实现），结果同时落工程里的 .lingqu/。\n"
    text += "退出码：0 = ok；1 = 失败或参数不全（stderr 里会是 JSON 的错误原因）。\n"
    return text
}

/** CLI 一次调用的结果 */
public class CliResult {
    public var exitCode: Int64 = 0
    public var json: String = ""
    public var error: String = ""
}

/**
 * 执行一条 CLI 命令：挑 handler → 调 `handle` → 序列化结果。
 *
 * 注意：这里刻意**不做参数校验**——校验在各自命令里（界面上同一套），CLI 只是"另一个前端"。
 * 这样界面和 CLI 的行为永远一致，不会出现"CLI 能跑、界面报错"这种分叉。
 */
public func dispatchCli(argv: Array<String>): CliResult {
    let r = CliResult()
    if (!cliHasCommand(argv)) {
        r.exitCode = 1
        r.error = cliUsage()
        return r
    }
    let parsed = argvToJsonWithValues(argv)
    var cmd = ""
    var args = JsonObject()
    for ((k, v) in parsed.getFields()) {
        cmd = k
        match (v.kind()) {
            case JsonKind.JsObject => args = v.asObject()
            case _ => ()
        }
    }
    if (!cliCommandSupported(cmd)) {
        r.exitCode = 1
        r.error = "不认识的命令：${cmd}\n\n" + cliUsage()
        return r
    }
    // CLI 用不上上下文：窗口名固定 "cli"，hub 的 jsSink 是 no-op（不往任何前端推事件）
    let ctx = IpcContext("cli", IpcHub())
    let fullName = "t2h:${cmd}"
    var out: JsonValue = JsonBool(false)
    try {
        out = runCliHandler(cmd, fullName, args, ctx)
    } catch (e: Exception) {
        r.exitCode = 1
        r.error = "执行 ${fullName} 失败：${e}"
        return r
    }
    r.json = out.toJsonString()
    // 退出码看返回体里的 ok（各命令都带这个字段）；没有 ok 字段按成功处理
    match (out.kind()) {
        case JsonKind.JsObject =>
            match (out.asObject().get("ok")) {
                case Some(b) =>
                    match (b.kind()) {
                        case JsonKind.JsBool => r.exitCode = if (b.asBool().getValue()) { 0 } else { 1 }
                        case _ => r.exitCode = 0
                    }
                case None => r.exitCode = 0
            }
        case _ => r.exitCode = 0
    }
    return r
}

/** 命令名 → handler（新增命令时两处一起加：这里 + `main.build()` 的 register） */
func runCliHandler(cmd: String, fullName: String, args: JsonObject, ctx: IpcContext): JsonValue {
    if (cmd == "scan") {
        return ScanCommand().handle(fullName, args, ctx)
    }
    if (cmd == "deps") {
        return DepsCommand().handle(fullName, args, ctx)
    }
    if (cmd == "port") {
        return PortCommand().handle(fullName, args, ctx)
    }
    if (cmd == "revert") {
        return RevertCommand().handle(fullName, args, ctx)
    }
    if (cmd == "decisions") {
        return DecisionsCommand().handle(fullName, args, ctx)
    }
    if (cmd == "diagnose") {
        return DiagnoseCommand().handle(fullName, args, ctx)
    }
    if (cmd == "build") {
        return BuildCommand().handle(fullName, args, ctx)
    }
    if (cmd == "hap") {
        return HapCommand().handle(fullName, args, ctx)
    }
    if (cmd == "sign") {
        return SignCommand().handle(fullName, args, ctx)
    }
    if (cmd == "deploy") {
        return DeployCommand().handle(fullName, args, ctx)
    }
    if (cmd == "verify") {
        return VerifyCommand().handle(fullName, args, ctx)
    }
    if (cmd == "report") {
        return ReportCommand().handle(fullName, args, ctx)
    }
    if (cmd == "batch") {
        return BatchCommand().handle(fullName, args, ctx)
    }
    if (cmd == "resume") {
        return ResumeCommand().handle(fullName, args, ctx)
    }
    if (cmd == "env") {
        return EnvCommand().handle(fullName, args, ctx)
    }
    if (cmd == "skill") {
        return SkillCommand().handle(fullName, args, ctx)
    }
    return AgentContextCommand().handle(fullName, args, ctx)
}
