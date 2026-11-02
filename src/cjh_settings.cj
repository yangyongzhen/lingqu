package lingqu

import std.fs.*
import stdx.encoding.json.*

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

// ============================================================
// 轮次预算（0.39.53）：AI 自动迁移开跑前把 cjh 的 max_iterations 抬到够用
// ============================================================
//
// 现场（2026-11-01 juCang）：整应用迁移跑到 **41 轮**时被截断——cjh 的 `max_iterations` 默认 40，
// `turn_done` 一到，agent 就没有回合用来收尾/补救，界面当时还只说"回合结束"。
//
// 纪律：
//   ① **只抬不降**：用户自己设过更大的值就原样不动；
//   ② 先走 **live**（`POST /api/settings`，cjh 自己的界面也走这条）——引擎在跑也能立刻生效；
//   ③ live 不通才落 `settings.json`（**先备份**，文本定点修补，不重排 JSON），并如实回投"需重启 cjh"。

/** 自动迁移需要的最小轮次预算（整应用迁移实测 41 轮才跑完一半） */
public let AUTOPORT_MIN_ITERATIONS: Int64 = 120

/**
 * 纯函数：这段 JSON 用的是哪种写法——**文件里是 `max_iterations`（snake），
 * `GET /api/settings` 回的是 `maxIterations`（camel）**。两种都认，返回带引号的字面量；没有给 ""。
 */
func maxIterKeyOf(json: String): String {
    let k1 = "\"max_iterations\""
    let k2 = "\"maxIterations\""
    match (json.indexOf(k1)) {
        case Some(_) => return k1
        case None => ()
    }
    match (json.indexOf(k2)) {
        case Some(_) => return k2
        case None => ()
    }
    return ""
}

/** 纯函数：从 settings JSON 里取轮次预算（snake / camel 两种写法都认；没有 / 读不到给 -1） */
public func maxIterationsOf(json: String): Int64 {
    let key = maxIterKeyOf(json)
    if (key == "") {
        return -1
    }
    let ki = match (json.indexOf(key)) {
        case Some(v) => v
        case None => return -1
    }
    let after = json[(ki + key.size)..]
    let ci = match (after.indexOf(":")) {
        case Some(v) => v
        case None => return -1
    }
    let bytes = after.toArray()
    var i = ci + 1
    while (i < Int64(bytes.size) && (bytes[i] == 32 || bytes[i] == 9 || bytes[i] == 10 || bytes[i] == 13)) {
        i += 1
    }
    var n: Int64 = 0
    var sawDigit = false
    while (i < Int64(bytes.size) && bytes[i] >= 48 && bytes[i] <= 57) {
        n = n * 10 + Int64(bytes[i]) - 48
        sawDigit = true
        i += 1
    }
    if (!sawDigit) {
        return -1
    }
    return n
}

/**
 * 纯函数：把 `max_iterations` 抬到 `target`（幂等、只抬不降、不重排 JSON）。
 *
 * - 已经 >= target → 原样返回
 * - 有该键且值较小 → 就地替换那个数字
 * - 没有该键 → 插到最外层 `{` 之后（`"max_iterations": 120,`）
 */
public func ensureMaxIterations(json: String, target: Int64): String {
    if (json.trimAscii().size == 0 || target <= 0) {
        return json
    }
    let key = if (maxIterKeyOf(json) != "") { maxIterKeyOf(json) } else { "\"max_iterations\"" }
    let cur = maxIterationsOf(json)
    if (cur >= target) {
        return json
    }
    let want = "${target}"
    if (cur > 0) {
        // 就地替换：定位 key → 冒号 → 数字区间
        let ki = match (json.indexOf(key)) {
            case Some(v) => v
            case None => return json
        }
        let after = json[(ki + key.size)..]
        let ci = match (after.indexOf(":")) {
            case Some(v) => v
            case None => return json
        }
        let base = ki + key.size + ci + 1
        let bytes = json.toArray()
        var i = base
        while (i < Int64(bytes.size) && (bytes[i] == 32 || bytes[i] == 9 || bytes[i] == 10 || bytes[i] == 13)) {
            i += 1
        }
        let numStart = i
        while (i < Int64(bytes.size) && bytes[i] >= 48 && bytes[i] <= 57) {
            i += 1
        }
        if (numStart == i) {
            return json
        }
        return json[0..numStart] + want + json[i..]
    }
    // 没有该键：插到第一个 '{' 之后
    let brace = match (json.indexOf("{")) {
        case Some(v) => v
        case None => return json
    }
    let at = brace + 1
    return json[0..at] + "\n  ${key}: ${want}," + json[at..]
}

/**
 * 动作层：确保 cjh 的轮次预算 >= target。
 *
 * @return 说明串（回投给界面/日志）：`live:40->120` / `file:40->120（需重启 cjh 生效）` /
 *         `already:120>=120` / `no-settings` / `error:…`
 */
public func ensureCjhIterationBudget(home: String, target: Int64): String {
    // ① live：问一下当前值（顺带确认引擎在线）
    var cur: Int64 = -1
    let got = cjhApiCall("GET", "/api/settings", "")
    if (got.trimAscii().size > 0) {
        cur = maxIterationsOf(got)
    }
    if (cur >= target) {
        return "already:${cur}>=${target}"
    }
    // ② live 写入
    var payload = JsonObject()
    payload.put("maxIterations", JsonInt(target))
    let posted = cjhApiCall("POST", "/api/settings", payload.toJsonString())
    if (posted.trimAscii().size > 0 && !posted.contains("\"ok\":false") && !posted.contains("\"ok\": false")) {
        let after = maxIterationsOf(cjhApiCall("GET", "/api/settings", ""))
        if (after >= target) {
            return "live:${cur}->${after}"
        }
    }
    // ③ 落文件（先备份；文本定点修补）
    let p = cjhSettingsPathOf(home)
    if (p.size == 0 || !exists(Path(p))) {
        return "no-settings"
    }
    try {
        let before = String.fromUtf8(File.readFrom(p))
        let after = ensureMaxIterations(before, target)
        if (after == before) {
            return "already:${maxIterationsOf(before)}>=${target}"
        }
        // 备份：settings.json.bak.autoport（同一份只留一份，覆盖写；内容就是"抬高之前"）
        let bak = p + ".bak.autoport"
        try {
            File.writeTo(bak, before.toArray())
        } catch (e: Exception) {
            let _ = e
        }
        File.writeTo(p, after.toArray())
        return "file:${maxIterationsOf(before)}->${target}（需重启 cjh 生效）"
    } catch (e: Exception) {
        return "error:" + e.toString()
    }
}

// ============================================================
// 接入协议（0.39.62）：openai 兼容 / anthropic
// ============================================================
//
// 为什么必须落文件而不能走 `POST /api/settings`：cjh 的 `applySettingsUpdate` 白名单里
// **没有** provider_protocol（它只认 baseUrl/model/apiKey/温度/tokens/轮次…），协议是
// "启动时读一次配置文件"的字段。所以这里与轮次预算同款做法：**定点文本修补 + 先备份**，
// 不重排 JSON（重排会丢掉用户手写的注释键、把格式全冲掉），并如实回投"需重启 cjh 生效"。

/** 协议取值：只认这两个（其它一律按"保持不变"处理，绝不猜） */
public let CJH_PROTOCOLS: Array<String> = ["openai", "anthropic"]

/** 纯函数：规范化协议值（大小写不敏感；不认识给 ""） */
public func normalizeProtocol(v: String): String {
    let s = v.trimAscii().toAsciiLower()
    for (p in CJH_PROTOCOLS) {
        if (s == p) {
            return p
        }
    }
    return ""
}

/** 纯函数：settings.json 里协议字段的键字面量（文件是 snake；camel 也认）；没有给 "" */
func protocolKeyOf(json: String): String {
    let k1 = "\"provider_protocol\""
    let k2 = "\"providerProtocol\""
    match (json.indexOf(k1)) {
        case Some(_) => return k1
        case None => ()
    }
    match (json.indexOf(k2)) {
        case Some(_) => return k2
        case None => ()
    }
    return ""
}

/** 纯函数：从 settings JSON 里取协议（缺失/类型不对给 ""——调用方按 cjh 默认 openai 理解） */
public func providerProtocolOf(json: String): String {
    let key = protocolKeyOf(json)
    if (key == "") {
        return ""
    }
    let ki = match (json.indexOf(key)) {
        case Some(v) => v
        case None => return ""
    }
    let after = json[(ki + key.size)..]
    let ci = match (after.indexOf(":")) {
        case Some(v) => v
        case None => return ""
    }
    let bytes = after.toArray()
    var i = ci + 1
    while (i < Int64(bytes.size) && (bytes[i] == 32 || bytes[i] == 9 || bytes[i] == 10 || bytes[i] == 13)) {
        i += 1
    }
    if (i >= Int64(bytes.size) || bytes[i] != 34) {
        return ""     // 值不是字符串 → 不认（不把 null/数字硬解释成协议名）
    }
    let start = i + 1
    var j = start
    while (j < Int64(bytes.size) && bytes[j] != 34) {
        if (bytes[j] == 92) {
            j += 2     // 跳过转义（`\"` 之类）
            continue
        }
        j += 1
    }
    if (j >= Int64(bytes.size)) {
        return ""
    }
    return after[start..j].trimAscii()
}

/**
 * 纯函数：把 `provider_protocol` 设成 `proto`（幂等、定点修补、不重排 JSON）。
 *
 * - `proto` 不认识 / JSON 空 → 原样返回
 * - 已有该键且值相同 → 原样返回
 * - 已有该键且值不同 → 就地替换那个字符串字面量
 * - 没有该键 → 插到最外层 `{` 之后（跟着一行 `"provider_protocol": "x",`）
 */
public func setProviderProtocol(json: String, proto: String): String {
    let want = normalizeProtocol(proto)
    if (want == "" || json.trimAscii().size == 0) {
        return json
    }
    let key = if (protocolKeyOf(json) != "") { protocolKeyOf(json) } else { "\"provider_protocol\"" }
    let cur = providerProtocolOf(json)
    if (cur == want) {
        return json
    }
    if (cur != "") {
        // 就地替换：定位 key → 冒号 → 第一个字符串字面量的开引号
        let ki = match (json.indexOf(key)) {
            case Some(v) => v
            case None => return json
        }
        let bytes = json.toArray()
        var i = ki + key.size
        // 冒号
        while (i < Int64(bytes.size) && bytes[i] != 58) { i += 1 }
        if (i >= Int64(bytes.size)) {
            return json
        }
        i += 1
        while (i < Int64(bytes.size) && (bytes[i] == 32 || bytes[i] == 9 || bytes[i] == 10 || bytes[i] == 13)) { i += 1 }
        if (i >= Int64(bytes.size) || bytes[i] != 34) {
            return json
        }
        let open = i
        var j = open + 1
        while (j < Int64(bytes.size) && bytes[j] != 34) {
            if (bytes[j] == 92) {
                j += 2        // 跳过转义（`\"` 之类）
                continue
            }
            j += 1
        }
        if (j >= Int64(bytes.size)) {
            return json
        }
        return json[0..(open + 1)] + want + json[j..]
    }
    // 没有该键：插到第一个 '{' 之后
    let brace = match (json.indexOf("{")) {
        case Some(v) => v
        case None => return json
    }
    let at = brace + 1
    return json[0..at] + "\n  ${key}: \"${want}\"," + json[at..]
}

/**
 * 动作层：把接入协议写进 `~/.cjh/settings.json`（先备份；写失败如实回投）。
 *
 * @return `already:openai` / `file:openai->anthropic（需重启 cjh 生效）` /
 *         `no-settings` / `no-home` / `bad-protocol:<原值>` / `error:…`
 */
public func ensureCjhProviderProtocol(home: String, proto: String): String {
    let want = normalizeProtocol(proto)
    if (want == "") {
        return "bad-protocol:" + proto
    }
    let p = cjhSettingsPathOf(home)
    if (p.size == 0) {
        return "no-home"
    }
    if (!exists(Path(p))) {
        return "no-settings"
    }
    try {
        let before = String.fromUtf8(File.readFrom(p))
        let cur = providerProtocolOf(before)
        let after = setProviderProtocol(before, want)
        if (after == before) {
            return "already:" + (if (cur == "") { "（未设置，按 cjh 默认 openai）" } else { cur })
        }
        // 备份：settings.json.bak.protocol（覆盖写；内容就是"改之前"）
        let bak = p + ".bak.protocol"
        try {
            File.writeTo(bak, before.toArray())
        } catch (e: Exception) {
            let _ = e
        }
        File.writeTo(p, after.toArray())
        let shown = if (cur == "") { "（未设置）" } else { cur }
        return "file:${shown}->${want}（需重启 cjh 生效）"
    } catch (e: Exception) {
        return "error:" + e.toString()
    }
}

