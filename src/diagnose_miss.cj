package lingqu

import std.collection.*
import std.fs.*
import stdx.encoding.json.*

/*
 * 未命中指纹的"攒候选"落档（0.39.55）。
 *
 * 为什么要有它：`t2h:diagnose` 未命中时以前只返回空数组——"这条错误没人认识"这件事**不留痕**，
 * 下一个样本再撞上还是从零查起。现在把归一签名（`missSignatureOf`）追加到
 * `<工程>/.lingqu/diagnose/misses.jsonl`，同签名出现几次就有几次；达到阈值时
 * `missCandidateHint` 会给出"该补指纹"的人话提示。
 *
 * 纪律：这里只攒**证据**。指纹库会指导 agent 怎么改用户代码，进库必须人确认（不自动写）。
 */

/** 落档相对位置（工程内 `.lingqu/` 下） */
public let DIAG_MISS_LEDGER_REL: String = "diagnose/misses.jsonl"

/** ledger 的绝对路径 */
public func diagMissLedgerPath(projDir: String): String {
    return lqDirOf(projDir) + cjhPathSep() + "diagnose" + cjhPathSep() + "misses.jsonl"
}

/**
 * 纯函数：这段 ledger 文本里某个签名出现过几次（按行比对，不做整段 JSON 解析，容错优先）。
 *
 * 注意：两种缩进形态都要认：`stdx.encoding.json` 的 `JsonObject.toJsonString()` 是**美化输出**
 * （一条记录会摊成 4 行、冒号后带空格），而本项目写台账是**紧凑单行**。
 * 只认紧凑形态会让"刚写进去的记录读不回来"（0.39.55 实测：累计次数永远返回 1）。
 */
public func missCountOf(ledgerText: String, sig: String): Int64 {
    if (ledgerText.size == 0 || sig.size == 0) {
        return 0
    }
    let quoted = JsonString(sig).toJsonString()
    let compact = "\"sig\":" + quoted
    let spaced = "\"sig\": " + quoted
    var n: Int64 = 0
    for (line in ledgerText.split("\n", -1)) {
        if (line.contains(compact) || line.contains(spaced)) {
            n += 1
        }
    }
    return n
}

/**
 * 动作层：记一次"未命中"。
 *
 * 落档是 **JSONL（一条一行）**：手动拼紧凑 JSON 而不是 `JsonObject.toJsonString()`
 * （后者会把一条记录摊成多行，按行计数/`tail` 都不再成立）。
 *
 * @return `(同签名累计次数, ledger 路径)`；读写失败时次数仍返回（至少本次算 1），路径照给，便于界面显示。
 */
public func recordDiagnoseMiss(projDir: String, sig: String, sample: String): (Int64, String) {
    let p = diagMissLedgerPath(projDir)
    let dir = lqDirOf(projDir) + cjhPathSep() + "diagnose"
    if (!exists(Path(dir))) {
        try {
            Directory.create(Path(dir), recursive: true)
        } catch (e: Exception) {
            let _ = e
        }
    }
    var prev = ""
    if (exists(Path(p))) {
        try {
            prev = String.fromUtf8(File.readFrom(p))
        } catch (e: Exception) {
            let _ = e
        }
    }
    let line = "{\"ts\":" + JsonString(nowText()).toJsonString() +
        ",\"sig\":" + JsonString(sig).toJsonString() +
        ",\"sample\":" + JsonString(oneLineOf(sample)).toJsonString() + "}\n"
    let total = missCountOf(prev, sig) + 1
    try {
        File.writeTo(p, (prev + line).toArray())
    } catch (e: Exception) {
        let _ = e
    }
    return (total, p)
}

// ============================================================
// 候选与归档（阶段 1，0.39.56）
//
// 台账只追加会越长越大：所以给一个**可判定的滚动阈值**（`MISS_ROLL_MIN_LINES`），
// 到量就整体挪到 `misses.<时间戳>.jsonl` 留档，当前台账从零开始。
// 语义：补完指纹后同签名**应当停止增长**；归档是"这一轮查清了"的分界线，不是删证据。
// ============================================================

/** 台账滚动阈值（行数）：超过就把当前台账整体归档（历史留在 `misses.<stamp>.jsonl`） */
public let MISS_ROLL_MIN_LINES: Int64 = 200

/** 纯函数：台账里有多少条非空行（= 记了多少次未命中） */
public func missLedgerLineCount(text: String): Int64 {
    var n: Int64 = 0
    for (line in text.split("\n", -1)) {
        if (line.trimAscii().size > 0) {
            n += 1
        }
    }
    return n
}

/**
 * 从 `i` 处读一个 JSON 字符串字面量（`"..."`，能跳过 `\"` / `\\` 这类转义）；不合法给 None。
 *
 * 为什么要自己扫：台账可能是**紧凑行**（本项目写的）也可能被别人写成**美化多行**，
 * 而"`"sig":` 后面不一定紧贴引号"——直接按 marker 切片，遇到 `"sig": "x"` 会漏（0.39.56 单测抓到）。
 */
func jsonStringAt(t: String, i: Int64): Option<String> {
    let bytes = t.toArray()
    if (i < 0 || i >= Int64(bytes.size) || bytes[i] != 34) {
        return None
    }
    let out = ArrayList<Byte>()
    var j = i + 1
    while (j < Int64(bytes.size)) {
        let b = bytes[j]
        if (b == 34) {
            return Some(String.fromUtf8(out.toArray()))
        }
        if (b == 92 && j + 1 < Int64(bytes.size)) {
            let nx = bytes[j + 1]
            // `\n` / `\r` / `\t` 还原成空格（签名里换行会被压成一格），其余转义取原字节
            if (nx == 110 || nx == 114 || nx == 116) {
                out.add(UInt8(32))
            } else {
                out.add(nx)
            }
            j += 2
            continue
        }
        out.add(b)
        j += 1
    }
    return None
}

/** 纯函数：一行台账里 `"sig"` 的值（没有/不合法给 ""） */
func sigFieldOf(line: String): String {
    let key = "\"sig\""
    match (line.indexOf(key)) {
        case Some(i) =>
            let bytes = line.toArray()
            var p = i + key.size
            while (p < Int64(bytes.size) && (bytes[p] == 32 || bytes[p] == 9)) {
                p += 1
            }
            if (p < Int64(bytes.size) && bytes[p] == 58) {
                p += 1
            }
            while (p < Int64(bytes.size) && (bytes[p] == 32 || bytes[p] == 9)) {
                p += 1
            }
            match (jsonStringAt(line, p)) {
                case Some(v) => return v
                case None => return ""
            }
        case None => return ""
    }
}

/** 纯函数：台账里出现过的签名（**去重 + 首次出现顺序**；按行取 `"sig"` 字段） */
public func missSignatureList(text: String): ArrayList<String> {
    let out = ArrayList<String>()
    for (line in text.split("\n", -1)) {
        let t = line.trimAscii()
        if (t.size == 0) {
            continue
        }
        let sig = sigFieldOf(t)
        if (sig.size == 0) {
            continue
        }
        var dup = false
        for (x in out) {
            if (x == sig) {
                dup = true
                break
            }
        }
        if (!dup) {
            out.add(sig)
        }
    }
    return out
}

/** 纯函数：是否该滚动（行数达到阈值；空的/没到量都不动） */
public func shouldRollMisses(text: String, minLines: Int64): Bool {
    if (minLines <= 0) {
        return missLedgerLineCount(text) > 0
    }
    return missLedgerLineCount(text) >= minLines
}

/**
 * 纯函数：归档文件名（时间戳里的 `:`/`.`/空格/斜杠换掉，Windows 文件名才合法）。
 *
 * 注意：**攒字节再整体解**（§4-116）——逐字节 `String.fromUtf8([b])` 碰到非 ASCII 会抛。
 */
public func missArchiveFileName(ts: String): String {
    let out = ArrayList<Byte>()
    for (b in oneLineOf(ts).toArray()) {
        if (b == 58 || b == 46 || b == 32 || b == 47 || b == 92 || b == 43) {
            out.add(UInt8(45))
        } else {
            out.add(b)
        }
    }
    if (out.size == 0) {
        return "misses.unknown.jsonl"
    }
    return "misses.${String.fromUtf8(out.toArray())}.jsonl"
}

/** 归档件路径：`<工程>/.lingqu/diagnose/misses.<stamp>.jsonl` */
public func missArchivePathOf(projDir: String, ts: String): String {
    return lqDirOf(projDir) + cjhPathSep() + "diagnose" + cjhPathSep() + missArchiveFileName(ts)
}

/**
 * 动作层：台账到量就整体归档。
 *
 * @return `(归档行数, 归档路径, 说明)`；没到量时行数给当前行数、路径为空、说明写"不用归档"。
 */
public func rollMissesLedger(projDir: String, ts: String, minLines: Int64): (Int64, String, String) {
    let p = diagMissLedgerPath(projDir)
    if (!exists(Path(p))) {
        return (0, "", "没有未命中台账（`t2h:diagnose` 真未命中才会写）")
    }
    var text = ""
    try {
        text = String.fromUtf8(File.readFrom(p))
    } catch (e: Exception) {
        return (0, "", "error:读台账失败：${e}")
    }
    let lines = missLedgerLineCount(text)
    if (lines == 0) {
        return (0, "", "台账是空的，不用归档")
    }
    if (!shouldRollMisses(text, minLines)) {
        return (lines, "", "台账 ${lines} 行，未到 ${minLines} 行阈值，不归档")
    }
    let dst = missArchivePathOf(projDir, ts)
    try {
        File.writeTo(dst, text.toArray())
    } catch (e: Exception) {
        return (lines, "", "error:写归档件失败（台账未动）：${e}")
    }
    // 归档件写成功后才重置当前台账（先写后清，别丢证据）
    try {
        remove(Path(p))
    } catch (e: Exception) {
        return (lines, dst, "error:归档件已写好，但重置台账失败：${e}")
    }
    return (lines, dst, "ok:已归档 ${lines} 行到 ${dst}")
}
