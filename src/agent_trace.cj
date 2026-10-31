package lingqu

import std.fs.*
import stdx.encoding.json.*

/*
 * agent 行为轨迹（0.39.0）：把「AI 对这个工程做了什么」落成证据。
 *
 * 为什么要有它：cjh 的 web 会话**只在销毁时落盘**（session_mgr 的 destroy 路径），
 * 一个跑完的回合在 `~/.cjh/sessions/` 里仍然只有 system 消息（实测 158 B）。
 * 于是"AI 到底改了什么、跑了哪些命令"没有留痕——验收叙事里最缺的就是这块。
 *
 * 分工（与 ADR D-015 一致）：
 *   · cjh 负责干（它的会话是否落盘是它自己的短板，已作为上游缺口提出）
 *   · **我们负责记**：页面把收到的 `tool_start` / `tool_result` / 回合边界写进
 *     `<工程>/.lingqu/agent/trace.jsonl` —— 工程级证据，和 scan/build 落档同源，
 *     agent 自己也能读它做自检。
 *
 * 一条一行的 JSONL（便于 grep/追加，也不怕一次写坏整份文件）。
 */

/** 轨迹目录：`<工程>/.lingqu/agent`（工程路径空 → 应用目录的 `.lingqu/agent`） */
public func traceDirOf(projectPath: String): String {
    return lqDirOf(projectPath) + cjhPathSep() + "agent"
}

/** 轨迹文件：`<工程>/.lingqu/agent/trace.jsonl` */
public func tracePathOf(projectPath: String): String {
    return traceDirOf(projectPath) + cjhPathSep() + "trace.jsonl"
}

/** 详情截断（纯函数）：轨迹是证据不是备份，单条超过 [maxChars] 就截断并标注 */
public func clipTraceDetail(detail: String, maxChars: Int64): String {
    if (maxChars <= 0) {
        return ""
    }
    let one = detail.replace("\r\n", " ").replace("\n", " ").replace("\t", " ")
    let clipped = clipCharsOf(one, maxChars)
    if (clipped.size < one.size) {
        return clipped + "…（截断）"
    }
    return clipped
}

/**
 * 一条轨迹（纯函数）：`{ts, kind, name, detail}` 的单行 JSON。
 *
 * kind 约定：`turn_start`（人/系统发起）、`tool`（工具调用）、`tool_done`（工具结果）、
 * `turn_done`（回合结束）、`note`（我们自己插入的说明，如"一键迁移开始"）。
 */
public func agentTraceLine(ts: String, kind: String, name: String, detail: String): String {
    var o = JsonObject()
    o.put("ts", JsonString(ts))
    o.put("kind", JsonString(kind))
    o.put("name", JsonString(name))
    o.put("detail", JsonString(clipTraceDetail(detail, 1200)))
    // toJsonString() 是**美化输出**（带换行缩进）；JSONL 必须一行一条，
    // 所以把结构性换行压掉。字符串值里的换行在 JSON 里已是转义（`\n` 两个字符），不受影响。
    return o.toJsonString().replace("\r\n", " ").replace("\n", " ")
}

/** 追加一行到轨迹（有 IO：只在命令层调用）；失败返回原因，不抛 */
public func appendAgentTrace(projectPath: String, line: String): String {
    let dir = traceDirOf(projectPath)
    let f = tracePathOf(projectPath)
    try {
        ensureDirOf(dir)
        var prev = ""
        if (exists(Path(f))) {
            prev = String.fromUtf8(File.readFrom(f))
        }
        var text = prev
        if (text.size > 0 && !text.endsWith("\n")) {
            text += "\n"
        }
        File.writeTo(f, (text + line + "\n").toArray())
        return ""
    } catch (e: Exception) {
        return "写轨迹失败：${e}"
    }
}

/** 轨迹行数（给 ui_report 断言"真的记下来了"；读不到给 -1） */
public func agentTraceLines(projectPath: String): Int64 {
    let f = tracePathOf(projectPath)
    if (!exists(Path(f))) {
        return 0
    }
    try {
        let text = String.fromUtf8(File.readFrom(f))
        var n: Int64 = 0
        for (l in text.split("\n", -1)) {
            if (l.trimAscii().size > 0) {
                n += 1
            }
        }
        return n
    } catch (e: Exception) {
        return -1
    }
}
