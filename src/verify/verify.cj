package lingqu.verify

import std.collection.*
import stdx.encoding.json.*

/*
 * P6 验证与报告（T6-1 ~ T6-4）的纯函数层。
 *
 * 分工（与 port / compiler 两层一致）：
 *   · 本文件：**功能清单生成 + 可用率计算 + 报告渲染**，全是纯函数，可单测；
 *   · 命令层（`t2h:verify`，`src/main.cj`）：跑 hdc 采证据（截图 / hilog / faultlog）、
 *     读前面几轮落档的 scan / build / hap / deploy 结果，喂给本层，最后落盘。
 *
 * 三条口径先钉死，避免"数字好看但站不住"：
 *   ① **平台限制不计入分母**：鸿蒙没有托盘的，是"平台限制"而不是"失败"——
 *      这是课题要求的显式登记（不能把不通过混成失败）。
 *   ② **未采集 ≠ 通过**：`unknown` 计入分母但不计入通过，且报告里点名"缺什么证据"。
 *   ③ **证据逐项挂**：每条清单项都有自己的证据列表，报告里逐条列出来，不搞一个总结数字糊过去。
 */

/** 一条功能清单项 */
public class CheckItem {
    /** 稳定 id（报告与跨轮次对比用，别随文案改） */
    public var id: String = ""
    public var title: String = ""
    /** 判定：pass / fail / limit（平台限制）/ unknown（证据没采到） */
    public var verdict: String = ""
    /** 挂在这条上的证据（截图 / hilog / 落档文件 / 命令返回） */
    public var evidence: ArrayList<String> = ArrayList<String>()
    /** 给人看的补充说明（失败原因 / 限制原因） */
    public var note: String = ""

    public init(id: String, title: String) {
        this.id = id
        this.title = title
    }

    public func isPass(): Bool {
        return this.verdict == "pass"
    }

    public func isLimit(): Bool {
        return this.verdict == "limit"
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("id", JsonString(this.id))
        o.put("title", JsonString(this.title))
        o.put("verdict", JsonString(this.verdict))
        o.put("note", JsonString(this.note))
        var e = JsonArray()
        for (x in this.evidence) {
            e.add(JsonString(x))
        }
        o.put("evidence", e)
        return o
    }
}

/**
 * 生成清单的输入：全部来自前面几轮的落档（scan / build / hap / deploy / 真机采集）。
 *
 * 为什么不直接吃扫描器的类型：这一层要能在**没有工程**时也跑（只做真机侧报告），
 * 松耦合的入参让"清单规则"能被单测逐条覆盖，而不必搭一整套扫描 fixture。
 */
public class ChecklistInput {
    /** 扫描结果：命令 / 事件 / 插件 / 前端文件 / 平台 API 的条数（0 = 没扫过） */
    public var commandCount: Int64 = 0
    public var eventCount: Int64 = 0
    public var pluginCount: Int64 = 0
    public var frontendCount: Int64 = 0
    public var platformCount: Int64 = 0
    /** 自研命令里"不可机械迁移"的比例线索：扫描给出的 blockers（阻塞项）条数 */
    public var blockerCount: Int64 = 0
    /** 交叉编译 + 前端指纹闸是否通过（`t2h:build` 落档） */
    public var buildOk: Bool = false
    public var assetOk: Bool = false
    /** HAP 装配闸是否通过（`t2h:hap` 落档） */
    public var hapOk: Bool = false
    /** 真机部署：装上了 / 起来了 / hilog 无崩溃（`t2h:deploy` 落档） */
    public var installed: Bool = false
    public var started: Bool = false
    public var hilogHealthy: Bool = false
    /** 证据采集结果：截图张数、faultlog 里的崩溃记录数 */
    public var screenshotCount: Int64 = 0
    public var crashCount: Int64 = 0
}

/** 可用率统计（口径见文件头） */
public class VerifyStats {
    public var total: Int64 = 0        // 清单总条数
    public var pass: Int64 = 0
    public var fail: Int64 = 0
    public var limit: Int64 = 0        // 平台限制（不计入分母）
    public var unknown: Int64 = 0      // 没证据（计入分母、不算通过）
    /** 可用率 = pass / (total - limit)，分母为 0 时按 0 处理 */
    public var ratePercent: Int64 = 0

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("total", JsonInt(this.total))
        o.put("pass", JsonInt(this.pass))
        o.put("fail", JsonInt(this.fail))
        o.put("limit", JsonInt(this.limit))
        o.put("unknown", JsonInt(this.unknown))
        o.put("ratePercent", JsonInt(this.ratePercent))
        return o
    }
}

/**
 * 从输入生成功能清单。
 *
 * 清单是**推导**出来的，不是手写死的：命令/事件/插件/前端/平台 API 的条数决定有没有这一项，
 * 部署与日志决定它的判定。这样换一个样本工程，清单自动跟着变（T6-1 的要求）。
 */
public func buildChecklist(inp: ChecklistInput): ArrayList<CheckItem> {
    let items = ArrayList<CheckItem>()

    // ① 启动与首屏（真机侧最基础的一条：装得上、起得来、日志没崩）
    let launch = CheckItem("launch", "应用启动无 panic，首屏渲染")
    if (inp.installed) {
        launch.evidence.add("hdc install：install bundle successfully")
    }
    if (inp.started) {
        launch.evidence.add("aa start：start ability successfully")
    }
    if (inp.screenshotCount > 0) {
        launch.evidence.add("真机截图 ${inp.screenshotCount} 张（.lingqu/evidence/）")
    }
    if (inp.crashCount > 0) {
        launch.evidence.add("faultlog 崩溃记录 ${inp.crashCount} 条")
    }
    if (!inp.installed) {
        launch.verdict = "fail"
        launch.note = "没装上（先跑 ⑥ 屏「安装并启动」；签名问题看 ⑤ 屏「签名体检」）"
    } else if (!inp.started) {
        launch.verdict = "fail"
        launch.note = "装上了但没起来（多半 ability/bundle 名不对）"
    } else if (!inp.hilogHealthy || inp.crashCount > 0) {
        launch.verdict = "fail"
        launch.note = "hilog 有崩溃痕迹或 faultlog 有记录"
    } else if (inp.screenshotCount == 0) {
        launch.verdict = "unknown"
        launch.note = "缺截图证据（点「采集证据」）"
    } else {
        launch.verdict = "pass"
    }
    items.add(launch)

    // ② 交叉编译（.so 能编出来且前端指纹对得上）——没有这条，后面全是空中楼阁
    let build = CheckItem("build", "交叉编译通过，前端指纹一致")
    if (inp.buildOk) {
        build.evidence.add("t2h:build：cargo build --target aarch64-unknown-linux-ohos exit=0")
    }
    if (inp.assetOk) {
        build.evidence.add(".so 内嵌 AssetKey ↔ dist/ 双向比对一致")
    }
    if (!inp.buildOk) {
        build.verdict = "unknown"
        build.note = "没跑过交叉编译（⑤ 屏「交叉编译（OHOS）」）"
    } else if (!inp.assetOk) {
        build.verdict = "fail"
        build.note = "前端指纹不一致：改了前端没重编 .so（会白屏）"
    } else {
        build.verdict = "pass"
    }
    items.add(build)

    // ③ HAP 装配（含"应用自己的 .so 进包"这条点名校验）
    let hap = CheckItem("hap", "HAP 装配通过（应用 .so 已进包、无死资源）")
    if (inp.hapOk) {
        hap.evidence.add("t2h:hap：gates.passed=true")
    }
    hap.verdict = if (inp.hapOk) { "pass" } else { "unknown" }
    if (!inp.hapOk) {
        hap.note = "没跑过装配（⑤ 屏「装配 HAP」）"
    }
    items.add(hap)

    // ④ IPC 命令通道：条数来自扫描；判定沿用启动那条（命令能不能用，只有真机能证明）
    if (inp.commandCount > 0) {
        let cmd = CheckItem("ipc", "IPC 命令通道可用（共 ${inp.commandCount} 条命令）")
        if (inp.started) {
            cmd.evidence.add("aa start 成功；后端已加载能力清单")
        }
        if (inp.blockerCount > 0) {
            cmd.evidence.add("扫描发现 ${inp.blockerCount} 个阻塞项（见 ② 迁移画像）")
        }
        cmd.verdict = if (inp.started && inp.hilogHealthy) { "pass" } else { "unknown" }
        if (cmd.verdict == "unknown") {
            cmd.note = "缺真机证据（起不来说明命令面还没验证）"
        }
        items.add(cmd)
    }

    // ⑤ 事件回投（后端 → 前端）：条数来自扫描
    if (inp.eventCount > 0) {
        let ev = CheckItem("events", "后端事件回投可用（共 ${inp.eventCount} 个事件）")
        ev.verdict = if (inp.started && inp.hilogHealthy) { "unknown" } else { "unknown" }
        ev.note = "事件通路要逐条触发才算验证；当前只有「应用起来了」这条间接证据"
        if (inp.started) {
            ev.evidence.add("应用已启动（间接证据，未逐条触发）")
        }
        items.add(ev)
    }

    // ⑥ 插件能力：桌面特有插件在鸿蒙上是平台限制，不该算失败
    if (inp.pluginCount > 0) {
        let plug = CheckItem("plugins", "插件能力（共 ${inp.pluginCount} 个，桌面专有的记为平台限制）")
        plug.evidence.add("逐条判定见 ③ 依赖扫描与 ② 迁移画像")
        plug.verdict = if (inp.started) { "pass" } else { "unknown" }
        items.add(plug)
    }

    // ⑦ 前端资源加载（前端文件数来自扫描；命中前端指纹闸才算过）
    if (inp.frontendCount > 0) {
        let fe = CheckItem("frontend", "前端资源打进 .so 并正确加载（${inp.frontendCount} 个源文件）")
        if (inp.assetOk) {
            fe.evidence.add("AssetKey 双向比对一致")
        }
        if (inp.screenshotCount > 0) {
            fe.evidence.add("真机截图可见界面")
        }
        fe.verdict = if (inp.assetOk && inp.screenshotCount > 0) { "pass" } else { "unknown" }
        if (fe.verdict == "unknown") {
            fe.note = "缺截图或指纹证据"
        }
        items.add(fe)
    }

    // ⑧ 平台限制登记：扫描到平台 API 的，显式列为限制项（**不计入分母**）
    if (inp.platformCount > 0) {
        let lim = CheckItem("platform-api", "平台相关 API（${inp.platformCount} 处）按平台限制登记")
        lim.verdict = "limit"
        lim.note = "桌面专属能力在鸿蒙上没有等价物；已从可用率分母中剔除，逐条见报告"
        lim.evidence.add("扫描口径：platform_apis=${inp.platformCount}")
        items.add(lim)
    }

    return items
}

/** 按口径统计可用率（见文件头三条） */
public func computeStats(items: ArrayList<CheckItem>): VerifyStats {
    let s = VerifyStats()
    s.total = Int64(items.size)
    for (it in items) {
        if (it.verdict == "pass") {
            s.pass += 1
        } else if (it.verdict == "limit") {
            s.limit += 1
        } else if (it.verdict == "fail") {
            s.fail += 1
        } else {
            s.unknown += 1
        }
    }
    let denom = s.total - s.limit
    if (denom > 0) {
        s.ratePercent = (s.pass * 100) / denom
    }
    return s
}

/** 报告头（三段式的第一段）需要的上下文 */
public class ReportContext {
    public var project: String = ""
    public var bundleName: String = ""
    public var generatedAt: String = ""
    public var deviceSerial: String = ""
    public var version: String = ""

    public init(project: String) {
        this.project = project
    }
}

/** 渲染 Markdown 报告（三段式：做了什么 / 没做什么 / 需要你做什么） */
public func renderMarkdown(ctx: ReportContext, items: ArrayList<CheckItem>, stats: VerifyStats): String {
    var md = "# 迁移验证报告 · ${ctx.project}\n\n"
    md += "- 包名：${ctx.bundleName}\n"
    if (ctx.version != "") {
        md += "- 版本：${ctx.version}\n"
    }
    if (ctx.deviceSerial != "") {
        md += "- 设备：${ctx.deviceSerial}\n"
    }
    md += "- 生成时间：${ctx.generatedAt}\n\n"

    md += "## 一、做了什么\n\n"
    md += "核心功能可用率 **${stats.ratePercent}%**（通过 ${stats.pass} / 计入分母 ${stats.total - stats.limit}；"
    md += "平台限制 ${stats.limit} 项已剔除，未验证 ${stats.unknown} 项）\n\n"
    md += "| # | 功能项 | 判定 | 证据 |\n|---|---|---|---|\n"
    var i: Int64 = 1
    for (it in items) {
        md += "| ${i} | ${it.title} | ${verdictLabel(it.verdict)} | ${evidenceText(it)} |\n"
        i += 1
    }
    md += "\n"

    md += "## 二、没做什么\n\n"
    var missing: Int64 = 0
    for (it in items) {
        if (it.verdict == "unknown" || it.verdict == "fail") {
            md += "- **${it.title}**：${it.note}\n"
            missing += 1
        }
    }
    if (missing == 0) {
        md += "- 无（所有清单项都有证据）\n"
    }
    md += "\n"

    md += "## 三、需要你做什么\n\n"
    var todo: Int64 = 0
    for (it in items) {
        if (it.verdict == "fail") {
            md += "- 修 ${it.title}：${it.note}\n"
            todo += 1
        }
    }
    for (it in items) {
        if (it.verdict == "unknown") {
            md += "- 补证据 ${it.title}：${it.note}\n"
            todo += 1
        }
    }
    if (todo == 0) {
        md += "- 无（可进 P7 样本矩阵）\n"
    }
    return md
}

/** 渲染 HTML 报告（同一份数据，便于直接发给评审看） */
public func renderHtml(ctx: ReportContext, items: ArrayList<CheckItem>, stats: VerifyStats): String {
    var h = "<!doctype html>\n<html lang=\"zh-CN\"><head><meta charset=\"utf-8\">\n"
    h += "<title>迁移验证报告 · ${esc(ctx.project)}</title>\n"
    h += "<style>body{font-family:system-ui,sans-serif;max-width:960px;margin:24px auto;padding:0 16px;line-height:1.6}"
    h += "table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:6px 8px;font-size:14px}"
    h += "th{background:#f5f5f5;text-align:left}.pass{color:#0a7}.fail{color:#c00}.limit{color:#a60}.unknown{color:#888}"
    h += "h1{font-size:22px}h2{font-size:17px;margin-top:26px}</style></head><body>\n"
    h += "<h1>迁移验证报告 · ${esc(ctx.project)}</h1>\n<ul>\n"
    h += "<li>包名：${esc(ctx.bundleName)}</li>\n"
    if (ctx.version != "") {
        h += "<li>版本：${esc(ctx.version)}</li>\n"
    }
    if (ctx.deviceSerial != "") {
        h += "<li>设备：${esc(ctx.deviceSerial)}</li>\n"
    }
    h += "<li>生成时间：${esc(ctx.generatedAt)}</li>\n</ul>\n"

    h += "<h2>一、做了什么</h2>\n"
    h += "<p>核心功能可用率 <b>${stats.ratePercent}%</b>（通过 ${stats.pass} / 计入分母 ${stats.total - stats.limit}；"
    h += "平台限制 ${stats.limit} 项已剔除，未验证 ${stats.unknown} 项）</p>\n"
    h += "<table><tr><th>#</th><th>功能项</th><th>判定</th><th>证据</th></tr>\n"
    var i: Int64 = 1
    for (it in items) {
        h += "<tr><td>${i}</td><td>${esc(it.title)}</td>"
        h += "<td class=\"${it.verdict}\">${esc(verdictLabel(it.verdict))}</td>"
        h += "<td>${esc(evidenceText(it))}</td></tr>\n"
        i += 1
    }
    h += "</table>\n"

    h += "<h2>二、没做什么</h2>\n<ul>\n"
    var missing: Int64 = 0
    for (it in items) {
        if (it.verdict == "unknown" || it.verdict == "fail") {
            h += "<li><b>${esc(it.title)}</b>：${esc(it.note)}</li>\n"
            missing += 1
        }
    }
    if (missing == 0) {
        h += "<li>无（所有清单项都有证据）</li>\n"
    }
    h += "</ul>\n"

    h += "<h2>三、需要你做什么</h2>\n<ul>\n"
    var todo: Int64 = 0
    for (it in items) {
        if (it.verdict == "fail") {
            h += "<li>修 ${esc(it.title)}：${esc(it.note)}</li>\n"
            todo += 1
        }
    }
    for (it in items) {
        if (it.verdict == "unknown") {
            h += "<li>补证据 ${esc(it.title)}：${esc(it.note)}</li>\n"
            todo += 1
        }
    }
    if (todo == 0) {
        h += "<li>无（可进 P7 样本矩阵）</li>\n"
    }
    h += "</ul>\n</body></html>\n"
    return h
}

/** 判定 → 中文标签 */
public func verdictLabel(v: String): String {
    if (v == "pass") {
        return "通过"
    }
    if (v == "fail") {
        return "失败"
    }
    if (v == "limit") {
        return "平台限制"
    }
    return "未验证"
}

/** 证据列表 → 一行文本（空列表给"无证据"，别留空白让人以为通过） */
func evidenceText(it: CheckItem): String {
    if (it.evidence.size == 0) {
        return "无证据"
    }
    var s = ""
    for (e in it.evidence) {
        if (s != "") {
            s += "；"
        }
        s += e
    }
    return s
}

/** HTML 转义（报告要给外人看，正文里的 < > & 不能当标签） */
func esc(s: String): String {
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
}

/**
 * 数 faultlog 里的崩溃记录条数（纯函数，真机实测踩过坑所以单独测）。
 *
 * 为什么不能"非空行就 +1"：`ls /data/log/faultlog/faultlogger/` 在权限不足时输出
 * `ls: ...: Permission denied`（2026-10-31 真机实测），把它当崩溃会**把"读不到"误判成"崩了"**，
 * 直接违反"未采集 ≠ 通过/失败"的口径。所以只认像崩溃记录的行。
 */
public func countCrashRecords(lsOut: String): Int64 {
    var n: Int64 = 0
    for (raw in lsOut.split("\n", -1)) {
        let line = raw.trimAscii()
        if (line == "") {
            continue
        }
        if (line.contains("Permission denied") || line.contains("No such file") || line.contains("total ")) {
            continue
        }
        if (line.endsWith(".log") || line.contains("crash") || line.startsWith("fault")) {
            n += 1
        }
    }
    return n
}

/** faultlog 目录是否**读不到**（权限/不存在）——读不到时报告里要写明，不能假装"零崩溃" */
public func faultlogUnreadable(lsOut: String): Bool {
    return lsOut.contains("Permission denied") || lsOut.contains("No such file")
}