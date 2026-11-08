package lingqu

import lingqu.compiler.*      // hilogTail
import lingqu.scanner.*       // projectNameOf / sanitizeFileName
import std.collection.*
import std.convert.*          // Int64.parse
import std.env.*              // getWorkingDirectory
import std.fs.*               // File / Path / exists / Directory
import std.process.*          // executeWithOutput
import std.time.*             // DateTime
import stdx.encoding.json.*

/*
 * 真机功能探针（`lingqu-cli probe`）——把"点一下看有没有反应"变成 agent 的一只手。
 *
 * 为什么需要它（D-015）：`t2h:verify` 只采证（截图 / 崩溃计数），**不会点按钮**，
 * 所以功能项永远停在"未测"。而人肉点按那套（dumpLayout → 取 bounds 中心 → uiInput click
 * → 再 dump 比对 → 截图 → 落档）**每一步都可脚本化**，没有任何一步需要人判断。
 * 把它做成命令，A4 的证据就不再只有人能产生。
 *
 * 判据（这里是纯函数，测试钉住）：
 *   · 点后**只有时钟文本在变** ⇒ fail（现场实测：节点 35→34，只变了时间）；
 *   · 点后出现新文本节点 ⇒ pass；命中期望日志行 ⇒ pass；
 *   · 点前就没 dump 到 ⇒ unknown，**绝不当通过**（同 verify 口径：没采集 ≠ 通过）。
 *
 * 落档 `<工程>/.lingqu/verify/<工程>.probe.json`，schema `lingqu/verify-probe/v1`，
 * 字段名必须与读取侧 `verify_feed.cj` 对齐（`features.<命令>.verdict / note / evidence`），
 * 且是**合并**写入——别的功能项的结论一个字都不能被冲掉（AGENTS §4-33 成对路径同族）。
 */

/** 版面树里的一个节点（从 `uitest dumpLayout` 的 JSON 抽出来的最小信息） */
public class LayoutNode {
    public var text: String = ""
    public var nodeType: String = ""
    public var clickable: Bool = false
    public var left: Int64 = 0
    public var top: Int64 = 0
    public var right: Int64 = 0
    public var bottom: Int64 = 0
    public init() {}
}

/** 一次探针的判定 */
public class ProbeVerdict {
    public var verdict: String = "unknown"
    public var note: String = ""
    public init() {}
}

func probeAreaOf(n: LayoutNode): Int64 {
    let w = if (n.right > n.left) { n.right - n.left } else { 0 }
    let h = if (n.bottom > n.top) { n.bottom - n.top } else { 0 }
    return w * h
}

/** `JsonObject` 里取对象字段（不是对象就给空对象，不抛） */
public func jsonFieldAsObject(o: JsonObject, key: String): JsonObject {
    match (o.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsObject => return v.asObject()
                case _ => return JsonObject()
            }
        case None => return JsonObject()
    }
}

/** `JsonObject` 里取字符串字段（不是字符串就给空串） */
public func jsonFieldAsString(o: JsonObject, key: String): String {
    match (o.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return ""
            }
        case None => return ""
    }
}

/**
 * 解析设备上的 bounds 字符串 `"[840,0][1000,80]"` → (left, top, right, bottom)。
 *
 * 解析不出来**必须返回 None**：默默当成 (0,0,0,0) 会让探针点到屏幕角落，
 * 比报错更糟（点错地方等于没测，还会污染现场）。
 */
public func parseBoundsOf(s: String): Option<(Int64, Int64, Int64, Int64)> {
    let cleaned = s.replace("][", ",").replace("[", "").replace("]", "")
    let parts = cleaned.split(",")
    if (parts.size != 4) {
        return None
    }
    try {
        let a = Int64.parse(parts[0].trimAscii())
        let b = Int64.parse(parts[1].trimAscii())
        let c = Int64.parse(parts[2].trimAscii())
        let d = Int64.parse(parts[3].trimAscii())
        return Some((a, b, c, d))
    } catch (e: Exception) {
        let _ = e
        return None
    }
}

/** 节点中心点（点击坐标） */
public func clickCentreOf(left: Int64, top: Int64, right: Int64, bottom: Int64): (Int64, Int64) {
    return ((left + right) / 2, (top + bottom) / 2)
}

func walkLayout(v: JsonValue, out: ArrayList<LayoutNode>): Unit {
    match (v.kind()) {
        case JsonKind.JsObject =>
            let o = v.asObject()
            let attrs = jsonFieldAsObject(o, "attributes")
            let text = jsonFieldAsString(attrs, "text")
            if (text != "") {
                let n = LayoutNode()
                n.text = text
                n.nodeType = jsonFieldAsString(attrs, "type")
                n.clickable = jsonFieldAsString(attrs, "clickable") == "true"
                match (parseBoundsOf(jsonFieldAsString(attrs, "bounds"))) {
                    case Some(b) =>
                        n.left = b[0]
                        n.top = b[1]
                        n.right = b[2]
                        n.bottom = b[3]
                    case None => ()
                }
                out.add(n)
            }
            match (o.get("children")) {
                case Some(c) =>
                    match (c.kind()) {
                        case JsonKind.JsArray =>
                            let arr = c.asArray()
                            var i: Int64 = 0
                            while (i < arr.size()) {
                                match (arr.get(i)) {
                                    case Some(ch) => walkLayout(ch, out)
                                    case None => ()
                                }
                                i += 1
                            }
                        case _ => ()
                    }
                case None => ()
            }
        case _ => ()
    }
}

/**
 * 解析 `uitest dumpLayout` 的 JSON → 有文本的节点清单（递归）。
 *
 * 只收 `text` 非空的节点：空文本节点对"点哪个"与"点完多了什么"都没有信息量，
 * 留在表里只会让节点数的变化看着像"有反应"（现场真值：35→34 差的那一个就是时钟）。
 */
public func parseLayoutNodes(jsonText: String): ArrayList<LayoutNode> {
    let out = ArrayList<LayoutNode>()
    if (jsonText.trimAscii().size == 0) {
        return out
    }
    try {
        walkLayout(JsonValue.fromStr(jsonText), out)
    } catch (e: Exception) {
        let _ = e
    }
    return out
}

/**
 * 按文本找节点：命中多个时取**面积最小**的那个（内层真正接收点击的节点），
 * 面积相同再偏向 `clickable`。一个都没命中 → None（调用方据此判"找不到节点"，不猜坐标）。
 */
public func findNodeByText(nodes: ArrayList<LayoutNode>, want: String): Option<LayoutNode> {
    if (want.size == 0) {
        return None
    }
    var best: Option<LayoutNode> = None
    for (n in nodes) {
        if (!n.text.contains(want)) {
            continue
        }
        match (best) {
            case Some(b) =>
                let na = probeAreaOf(n)
                let ba = probeAreaOf(b)
                if (na < ba || (na == ba && n.clickable && !b.clickable)) {
                    best = Some(n)
                }
            case None => best = Some(n)
        }
    }
    return best
}

/** 像时钟/时间戳的文本（`15:35` / `9:05` / `15:35:24`）——这类变化不算"界面有反应" */
public func looksLikeTimeText(s: String): Bool {
    let t = s.trimAscii()
    if (t.size == 0) {
        return false
    }
    let parts = t.split(":")
    if (parts.size != 2 && parts.size != 3) {
        return false
    }
    for (p in parts) {
        if (p.size == 0 || p.size > 2) {
            return false
        }
        try {
            let _ = Int64.parse(p)
        } catch (e: Exception) {
            let _ = e
            return false
        }
    }
    return true
}

/** 点后新增的文本（忽略时钟类）——`pass` 的正面证据就是这个非空 */
public func newTextsOf(before: ArrayList<LayoutNode>, after: ArrayList<LayoutNode>): ArrayList<String> {
    let seen = ArrayList<String>()
    for (b in before) {
        seen.add(b.text)
    }
    let added = ArrayList<String>()
    for (a in after) {
        if (a.text.size == 0 || looksLikeTimeText(a.text)) {
            continue
        }
        if (!seen.contains(a.text) && !added.contains(a.text)) {
            added.add(a.text)
        }
    }
    return added
}

func joinFirstFew(items: ArrayList<String>, n: Int64): String {
    var s = ""
    var i: Int64 = 0
    while (i < items.size && i < n) {
        if (i > 0) {
            s += "、"
        }
        s += items[i]
        i += 1
    }
    return s
}

/**
 * 点完的判定（纯函数，一行 IO 都不做）。
 *
 * 优先级：期望日志命中 → pass（版面不变但通道通，例如"点了以后日志回「请先输入地址」"）；
 * 点前版面空（dump 失败）→ unknown；点后出现新文本 → pass；否则 fail。
 */
public func judgeProbe(before: ArrayList<LayoutNode>, after: ArrayList<LayoutNode>,
    expectLog: String, logText: String): ProbeVerdict {
    let v = ProbeVerdict()
    let want = expectLog.trimAscii()
    if (want.size > 0 && logText.contains(want)) {
        v.verdict = "pass"
        v.note = "运行日志出现期望行「${want}」"
        return v
    }
    if (before.size == 0) {
        v.verdict = "unknown"
        v.note = "点前没 dump 到版面（设备/uitest/窗口不可用），无法判定——不当通过"
        return v
    }
    let added = newTextsOf(before, after)
    if (added.size > 0) {
        v.verdict = "pass"
        v.note = "点后版面多出 ${added.size} 条文本：${joinFirstFew(added, 3)}"
        return v
    }
    v.verdict = "fail"
    v.note = "点后版面没有新内容（忽略时钟后与点击前一致，文本节点 ${before.size}→${after.size}）"
    return v
}

/**
 * 合并写落档（纯函数）：把这一条结论并进已有文档，**保留其它功能项**。
 *
 * 字段名照着读取侧抄：`features.<命令> = {verdict, note, evidence}`（`verify_feed.cj`）。
 * `existing` 不是合法 JSON 时从空文档起——不能因为上一次写坏就整块丢证据。
 */
public func mergeProbeDocument(existing: String, feature: String, verdict: String, note: String,
    evidence: String, serial: String, atIso: String): String {
    var feats = JsonObject()
    if (existing.trimAscii().size > 0) {
        try {
            let root = JsonValue.fromStr(existing).asObject()
            feats = jsonFieldAsObject(root, "features")
        } catch (e: Exception) {
            let _ = e
        }
    }
    let one = JsonObject()
    one.put("verdict", JsonString(verdict))
    one.put("note", JsonString(note))
    if (evidence.size > 0) {
        one.put("evidence", JsonString(evidence))
    }
    feats.put(feature, one)
    let out = JsonObject()
    out.put("_schema", JsonString("lingqu/verify-probe/v1"))
    out.put("_note", JsonString("真机点按取证（agent 侧实测，不计入 A3 人工介入）。有证据才写，没测到的命令不写。"))
    if (serial.size > 0) {
        out.put("serial", JsonString(serial))
    }
    if (atIso.size > 0) {
        out.put("at", JsonString(atIso))
    }
    out.put("features", feats)
    return out.toJsonString()
}

// ------------------------------------------------------------------
// IO 层：真机取数（dumpLayout / uiInput click / hilog / 截图 / 落档）
// ------------------------------------------------------------------

func probeIsoNow(): String {
    return DateTime.now().toString()
}

/** 建目录：已存在不算错（§4-89），父级缺了能一路建出来（§4-76） */
func ensureProbeDir(dir: String): String {
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir), recursive: true)
        }
        return ""
    } catch (e: Exception) {
        return "${e}"
    }
}

/** 一条 hdc 命令 → (退出码, 输出文本)；起不来给 (-1, 原因)，绝不静默当成成功 */
func probeHdc(hdc: String, serial: String, tail: Array<String>): (Int64, String) {
    let argv = ArrayList<String>()
    if (serial.size > 0) {
        argv.add("-t")
        argv.add(serial)
    }
    for (a in tail) {
        argv.add(a)
    }
    try {
        let (code, out, errOut) = executeWithOutput(hdc, argv.toArray())
        return (code, String.fromUtf8(out) + String.fromUtf8(errOut))
    } catch (e: Exception) {
        return (-1, "起不来：${e}")
    }
}

/** 设备序列号：先认部署落档（那是真装过的机器），没有才问 hdc */
func probeDeviceOf(hdc: String, projName: String, projPath: String): String {
    let fromRecord = deploySerialOf(projName, projPath)
    if (fromRecord.size > 0) {
        return fromRecord
    }
    let (code, text) = probeHdc(hdc, "", ["list", "targets", "-v"])
    if (code != 0) {
        return ""
    }
    for (line in text.split("\n")) {
        let t = line.trimAscii()
        if (t.size == 0 || t.startsWith("COM")) {
            continue     // §4-40：`COM1 UART Ready` 是串口噪声，不是设备
        }
        let parts = t.split("\t")
        if (parts.size >= 2 && parts[0].trimAscii().size > 0) {
            return parts[0].trimAscii()
        }
    }
    return ""
}

/** 探针执行日志（每一条外部命令的退出码与输出都要留痕，§1-3 证据纪律） */
class ProbeLog {
    public var text: String = ""
    public func add(s: String): Unit {
        text += s
    }
}

/** dump 一次版面到本地并解析；dump 不到就回空表（由 judgeProbe 判 unknown） */
func probeDumpTo(hdc: String, serial: String, local: String, remote: String,
    log: ProbeLog): ArrayList<LayoutNode> {
    let (c1, o1) = probeHdc(hdc, serial, ["shell", "uitest", "dumpLayout", "-p", remote])
    log.add("[dumpLayout] exit=${c1} ${o1.trimAscii()}\n")
    let (c2, o2) = probeHdc(hdc, serial, ["file", "recv", remote, local])
    log.add("[recv] exit=${c2} ${o2.trimAscii()}\n")
    if (!exists(Path(local))) {
        return ArrayList<LayoutNode>()
    }
    return parseLayoutNodes(readTextOrEmpty(local))
}

/**
 * `lingqu-cli probe --path . --feature <命令> --click <界面文本> [--expect-log <日志行>] [--shot true]`
 *
 * 这不是单元测试能覆盖的部分（真机 / 进程 / WebView，§1-5），只保证：
 * 每条外部命令的退出码与输出都进 `log`，判定走纯函数，落档是合并写入。
 */
public func runProbe(args: JsonObject): JsonObject {
    let out = JsonObject()
    let hdc = hdcPathOr()
    var projPath = argStr(args, "path", "")
    if (projPath.trimAscii().size == 0) {
        projPath = getWorkingDirectory().toString()
    }
    let feature = argStr(args, "feature", "").trimAscii()
    var clickText = argStr(args, "click", "").trimAscii()
    if (clickText.size == 0) {
        // §4-119：仓颉在 Windows 上接不到非 ASCII 的 argv（'Invalid unicode scalar value'），
        // 界面文本几乎必然是中文 ⇒ 给文件入参这条正路
        let cf = argStr(args, "click-file", "").trimAscii()
        if (cf.size > 0) {
            clickText = readTextOrEmpty(cf).trimAscii()
        }
    }
    var expectLog = argStr(args, "expect-log", "").trimAscii()
    if (expectLog.size == 0) {
        let lf = argStr(args, "expect-log-file", "").trimAscii()
        if (lf.size > 0) {
            expectLog = readTextOrEmpty(lf).trimAscii()
        }
    }
    if (expectLog.size == 0) {
        expectLog = argStr(args, "expectLog", "").trimAscii()
    }
    let wantShot = argBool(args, "shot", true)
    out.put("path", JsonString(projPath))
    out.put("feature", JsonString(feature))
    if (hdc.size == 0) {
        out.put("ok", JsonBool(false))
        out.put("error", JsonString("没有 hdc（DEVECO_SDK_HOME / DEVECO_HOME / OHOS_HOME 下都没找到 toolchains）"))
        return out
    }
    if (feature.size == 0) {
        out.put("ok", JsonBool(false))
        out.put("error", JsonString("缺少 --feature：要写核心功能清单里的命令名（如 start_download）"))
        return out
    }
    if (clickText.size == 0) {
        out.put("ok", JsonBool(false))
        out.put("error", JsonString("缺少 --click / --click-file：要指界面上能看到的按钮文本（中文一律写进 UTF-8 文件，argv 传中文会崩，§4-119）"))
        return out
    }
    let projName = sanitizeFileName(projectNameOf(projPath))
    let serial = probeDeviceOf(hdc, projName, projPath)
    if (serial.size == 0) {
        out.put("ok", JsonBool(false))
        out.put("error", JsonString("没有可用设备（hdc list targets 为空或只有串口噪声）"))
        return out
    }
    let shotsDir = lqPathOf(projPath, "shots")
    let verifyDir = lqPathOf(projPath, "verify")
    let e1 = ensureProbeDir(shotsDir)
    let e2 = ensureProbeDir(verifyDir)
    if (e1.size > 0 || e2.size > 0) {
        out.put("ok", JsonBool(false))
        out.put("error", JsonString("建落档目录失败：${e1} ${e2}"))
        return out
    }
    let stem = "probe-${sanitizeFileName(feature)}"
    let beforeFile = "${shotsDir}/${stem}-before.layout.json"
    let afterFile = "${shotsDir}/${stem}-after.layout.json"
    let shotFile = "${shotsDir}/${stem}.jpeg"
    let logBuf = ProbeLog()
    logBuf.add("[probe] 工程 ${projName} 设备 ${serial} 功能 ${feature} 点击「${clickText}」\n")
    let beforeNodes = probeDumpTo(hdc, serial, beforeFile, "/data/local/tmp/probe-before.json", logBuf)
    var verdict = ProbeVerdict()
    var clicked = false
    match (findNodeByText(beforeNodes, clickText)) {
        case Some(n) =>
            let c = clickCentreOf(n.left, n.top, n.right, n.bottom)
            if (expectLog.size > 0) {
                // 只清 hilog 缓冲（要判"这次点击产生的日志"），不动别的落档
                let (cr, or) = probeHdc(hdc, serial, ["shell", "hilog", "-r"])
                logBuf.add("[hilog -r] exit=${cr} ${or.trimAscii()}\n")
            }
            let (cc, oc) = probeHdc(hdc, serial,
                ["shell", "uitest", "uiInput", "click", "${c[0]}", "${c[1]}"])
            logBuf.add("[click] (${c[0]},${c[1]}) 「${n.text}」 exit=${cc} ${oc.trimAscii()}\n")
            clicked = cc == 0
            sleep(Duration.millisecond * 900)
        case None =>
            verdict.verdict = "unknown"
            verdict.note = "点前版面树里找不到「${clickText}」（可能不在前台 / 文本不同 / 需要先滑动）"
            logBuf.add("[click] ${verdict.note}\n")
    }
    out.put("beforeNodes", JsonInt(beforeNodes.size))
    if (clicked) {
        let afterNodes = probeDumpTo(hdc, serial, afterFile, "/data/local/tmp/probe-after.json", logBuf)
        out.put("afterNodes", JsonInt(afterNodes.size))
        var logText = ""
        if (expectLog.size > 0) {
            let (cl, ol) = probeHdc(hdc, serial, ["shell", "hilog", "-x"])
            logBuf.add("[hilog -x] exit=${cl}\n")
            for (line in hilogTail(ol, 200)) {
                logText += line + "\n"
            }
        }
        if (wantShot) {
            let remoteShot = "/data/local/tmp/${stem}.jpeg"
            let (cs, os) = probeHdc(hdc, serial, ["shell", "snapshot_display", "-f", remoteShot])
            logBuf.add("[snapshot] exit=${cs} ${os.trimAscii()}\n")
            let (cg, og) = probeHdc(hdc, serial, ["file", "recv", remoteShot, shotFile])
            logBuf.add("[recv shot] exit=${cg} ${og.trimAscii()}\n")
        }
        verdict = judgeProbe(beforeNodes, afterNodes, expectLog, logText)
        logBuf.add("[judge] ${verdict.verdict} —— ${verdict.note}\n")
    }
    let probeFile = lqPathOf(projPath, "verify/${projName}.probe.json")
    var evidence = ""
    if (exists(Path(afterFile))) {
        evidence = ".lingqu/shots/${stem}-after.layout.json"
    }
    let existing = if (exists(Path(probeFile))) { readTextOrEmpty(probeFile) } else { "" }
    let doc = mergeProbeDocument(existing, feature, verdict.verdict, verdict.note, evidence, serial, probeIsoNow())
    var writeErr = ""
    try {
        File.writeTo(probeFile, doc.toArray())
    } catch (e: Exception) {
        writeErr = "${e}"
    }
    out.put("verdict", JsonString(verdict.verdict))
    out.put("note", JsonString(verdict.note))
    out.put("serial", JsonString(serial))
    out.put("evidence", JsonString(evidence))
    out.put("probeFile", JsonString(probeFile))
    out.put("log", JsonString(logBuf.text))
    // ok = "测到了"（pass / fail 都算），unknown 与写盘失败都算没测成，退出码非 0
    out.put("ok", JsonBool(verdict.verdict != "unknown" && writeErr.size == 0))
    if (writeErr.size > 0) {
        out.put("error", JsonString("写落档失败：${writeErr}"))
    }
    return out
}
