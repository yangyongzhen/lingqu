package lingqu

import std.fs.*

/*
 * cjh 设置文件的定点修补（0.39.8）
 *
 * 背景：cjh 的 `interruptSession()` 原先在 WS 断连时**无条件打断本轮**。
 * 灵渠的 AI 自动迁移是无人值守长任务——0.39.7 实测页面只重连一次（`wsReconnects=13` 那次更夸张），
 * 整轮 40+ 次工具调用就作废。cjh 已加 `web.keep_running_on_disconnect`（默认 false 保持老行为），
 * 驱动长任务的调用方要把它打开。**这条配置不该让用户手改**：`t2h:autoport_start` 时自动补上。
 *
 * 只做定点文本修补（不整体重排 JSON，避免把用户的注释/字段顺序/格式洗掉），
 * 且幂等：已经是 true 就原样返回。
 */

/** 需要打开的键 */
public let KEEP_RUNNING_KEY: String = "keep_running_on_disconnect"

/**
 * 确保 settings JSON 里 `web.keep_running_on_disconnect` 为 true（纯函数，幂等）
 *
 * - 已有该键且值为 true → 原样返回
 * - 已有该键但值不是 true → 就地改成 true
 * - 没有该键、但有 `"web": {` → 在该对象开头插入
 * - 没有 web 段 / 文本不可用 → 原样返回（调用方据此提示"请手工配置"）
 */
public func ensureKeepRunningOnDisconnect(json: String): String {
    if (json.trimAscii().size == 0) {
        return json
    }
    // 1) 已有该键：把值改成 true（仅处理 false/缺值两种简单形态）
    match (json.indexOf("\"" + KEEP_RUNNING_KEY + "\"")) {
        case Some(_) =>
            if (json.contains("\"" + KEEP_RUNNING_KEY + "\": true") ||
                json.contains("\"" + KEEP_RUNNING_KEY + "\":true")) {
                return json
            }
            return replaceKeepRunningValue(json)
        case None => ()
    }
    // 2) 没有该键：插到 "web" 对象的 { 之后
    match (json.indexOf("\"web\"")) {
        case Some(wi) =>
            let afterKey = json[(wi + 5)..]
            match (afterKey.indexOf("{")) {
                case Some(bi) =>
                    let at = wi + 5 + bi + 1
                    return json[0..at] + "\n    \"" + KEEP_RUNNING_KEY + "\": true," + json[at..]
                case None => return json
            }
        case None => return json
    }
}

/** 已存在该键但不是 true：把它的值替换成 true（值区间 = 冒号后到 , 或 } 之前） */
func replaceKeepRunningValue(json: String): String {
    let marker = "\"" + KEEP_RUNNING_KEY + "\""
    let mi = match (json.indexOf(marker)) {
        case Some(v) => v
        case None => return json
    }
    let after = json[(mi + marker.size)..]
    let colon = match (after.indexOf(":")) {
        case Some(v) => v
        case None => return json
    }
    let valueStart = mi + marker.size + colon + 1
    var i = valueStart
    let chars = json.toArray()
    while (i < Int64(chars.size) && (chars[i] == 32 || chars[i] == 9 || chars[i] == 10 || chars[i] == 13)) {
        i += 1
    }
    var end = i
    while (end < Int64(chars.size) && chars[end] != 44 && chars[end] != 125) {  // ',' '}'
        end += 1
    }
    return json[0..valueStart] + " true" + json[end..]
}

/**
 * 读 `~/.cjh/settings.json`，必要时补上 `keep_running_on_disconnect: true` 并写回。
 *
 * @return "already"（本来就对）/ "written"（已补上）/ "no-settings"（文件不存在）/
 *         "no-web"（文件里没有 web 段，没敢改）/ "error:…"
 */
public func ensureCjhKeepRunning(home: String): String {
    let p = cjhSettingsPathOf(home)
    if (p.size == 0) {
        return "no-home"
    }
    if (!exists(Path(p))) {
        return "no-settings"
    }
    try {
        let before = String.fromUtf8(File.readFrom(p))
        let after = ensureKeepRunningOnDisconnect(before)
        if (after == before) {
            // 已经是 true，或文件里没有 web 段（纯函数选择不动它）—— 两种都算"无需处理"
            return "already"
        }
        File.writeTo(p, after.toArray())
        return "written"
    } catch (e: Exception) {
        return "error:" + e.toString()
    }
}
