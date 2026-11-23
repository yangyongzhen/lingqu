package lingqu.compiler

import std.collection.*
import stdx.encoding.json.*

/*
 * T5-3 HAP 装配的纯函数半边：解析 hvigor 输出 + 扫 HAP（zip）条目做"死资源"校验。
 *
 * 实测口径（2026-10-30，habit-tree @ ohos，DevEco 6.1.1.300 / hvigor 6.24.4）：
 *   · 装配命令（不依赖 PATH，全用 DevEco 自带的 node + hvigorw.js）：
 *       <DEVECO_HOME>\tools\node\node.exe <DEVECO_HOME>\tools\hvigor\bin\hvigorw.js
 *         --mode module -p product=default assembleHap --no-daemon
 *     运行目录 = <src-tauri>/gen/ohos
 *   · 必需环境变量：DEVECO_HOME、DEVECO_SDK_HOME（= <DEVECO_HOME>\sdk）、
 *     OHOS_HOME（= <DEVECO_HOME>\sdk\default\openharmony）、NATIVE_OHOS_SDK
 *   · 装配前必须 `ohpm install --all`（否则 ArkTS 报 Cannot find module '@ohos-rs/ability'）
 *   · 产物：entry/build/default/outputs/default/entry-default-{signed,unsigned}.hap
 *   · 真机 HAP 里**没有 rawfile 目录**（前端被编进 .so），所以 rawfile 出现即为死资源
 */

/**
 * 从 `EntryAbility.ets` 文本里取 `public moduleName: string = "grove_lib"` 的值。
 *
 * 为什么要它：HAP 里必须出现 **`lib<moduleName>.so`** 才是"应用代码打进去了"。
 * 只看"有没有 arm64 的 .so"会被 DevEco 模板自带的 `libentry.so`（几 KB 的 `add` 示例桩）
 * 骗过去——2026-10-31 真机实测就是这么放过一个白屏 HAP 的。
 */
public func entryModuleNameOf(etsText: String): String {
    let key = "moduleName"
    let kb = key.toArray()
    let bytes = etsText.toArray()
    var from: Int64 = 0
    while (from + kb.size <= bytes.size) {
        // 手动找 key（String.indexOf 带起点参数在不同版本上不一致，别赌）
        var hit = true
        for (k in 0..kb.size) {
            if (bytes[from + k] != kb[k]) {
                hit = false
                break
            }
        }
        if (!hit) {
            from++
            continue
        }
        var i = from + kb.size
        while (i < bytes.size && bytes[i] != 61 && bytes[i] != 10 && bytes[i] != 59) {
            i++
        }
        if (i < bytes.size && bytes[i] == 61) {
            i++
            while (i < bytes.size && bytes[i] != 34 && bytes[i] != 39 && bytes[i] != 10 && bytes[i] != 59) {
                i++
            }
            if (i < bytes.size && (bytes[i] == 34 || bytes[i] == 39)) {
                let q = bytes[i]
                i++
                let begin = i
                while (i < bytes.size && bytes[i] != q) {
                    i++
                }
                if (i < bytes.size) {
                    let v = String.fromUtf8(bytes[begin..i]).trimAscii()
                    if (v != "") {
                        return v
                    }
                }
            }
        }
        from++
    }
    return ""
}

/** 期望的 .so 文件名：moduleName → `lib<name>.so`（`moduleName` 为空时返回 ""） */
public func expectedSoNameOf(moduleName: String): String {
    let m = moduleName.trimAscii()
    if (m == "") {
        return ""
    }
    // 有人会把 lib/.so 一起写进来，容错处理
    var base = m
    if (base.startsWith("lib")) {
        base = base[3..]
    }
    if (base.endsWith(".so")) {
        base = base[0..(base.size - 3)]
    }
    return "lib${base}.so"
}

/** HAP 里是否包含指定名字的 .so（`libs/arm64-v8a/<name>`，忽略大小写） */
public func hapHasSo(entries: HapEntries, soName: String): Bool {
    if (soName == "") {
        return false
    }
    let want = lowerAsciiOf(soName)
    for (n in entries.arm64Sos) {
        // 条目名形如 libs/arm64-v8a/libgrove_lib.so，比末段
        if (lowerAsciiOf(fileNameOf(n)) == want) {
            return true
        }
    }
    return false
}

/** hvigor 输出解析结果 */public class HvigorResult {
    public var built: Bool = false
    public var errorCount: Int64 = 0
    public var firstError: String = ""
    /** 输出里出现的 .hap 文件名（signed / unsigned 都收） */
    public var hapNames: ArrayList<String> = ArrayList<String>()

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("built", JsonBool(this.built))
        o.put("errorCount", JsonInt(this.errorCount))
        o.put("firstError", JsonString(this.firstError))
        var arr = JsonArray()
        for (n in this.hapNames) {
            arr.add(JsonString(n))
        }
        o.put("hapNames", arr)
        return o
    }
}

/** 解析 hvigor 的 stdout/stderr：成功标志 + 错误行 + 产物名 */
public func parseHvigorOutput(text: String): HvigorResult {
    let r = HvigorResult()
    for (raw in text.split("\n", -1)) {
        let line = stripAnsi(raw).trimAscii()
        if (line.size == 0) {
            continue
        }
        if (line.contains("BUILD SUCCESSFUL")) {
            r.built = true
        }
        let isErr = line.startsWith("ERROR") || line.contains("ArkTS Compiler Error") || line.contains("> hvigor ERROR")
        if (isErr) {
            r.errorCount += 1
            if (r.firstError == "") {
                r.firstError = line
            }
        }
        if (line.contains(".hap")) {
            let name = hapNameIn(line)
            if (name != "" && !r.hapNames.contains(name)) {
                r.hapNames.add(name)
            }
        }
    }
    // 出现 BUILD FAILED 时不要被前面误判
    if (text.contains("BUILD FAILED")) {
        r.built = false
    }
    return r
}

/** 从一行里挑出 `xxx.hap` 文件名（只取末段，去掉日志前缀与引号） */
public func hapNameIn(line: String): String {
    let idx = line.indexOf(".hap")
    match (idx) {
        case Some(i) =>
            var start = i
            while (start > 0) {
                let b = line.toArray()[start - 1]
                // 允许字母数字 _ - . / \
                let isName = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b == 45 || b == 46 || b == 47 || b == 92
                if (isName) {
                    start -= 1
                } else {
                    break
                }
            }
            let full = line[start..(i + 4)]
            let sep = lastSepIndex(full)
            if (sep >= 0) {
                return full[(sep + 1)..]
            }
            return full
        case None => return ""
    }
}

/**
 * 逐字节把命令行输出转成文本，**非法字节换成 `?`，绝不抛异常**（0.39.51）。
 *
 * 为什么必须有它（实测事故，2026-11-01 20:42，juCang）：
 *   agent 跑 `t2h:hap` → `IllegalArgumentException: Invalid utf8 byte sequence` → 落档写成
 *   「HAP 0 字节 / arm64 条目 0」→ 整条迁移停在那里，而 agent 那一轮的轮次预算（40）刚好用完，
 *   于是界面只剩一句「回合结束 · 轮次 41」。
 *   罪魁是 `stripAnsi` 里 `out += String.fromUtf8([bytes[i]])`：**中文一个字节不是合法 UTF-8**，
 *   hvigor / ohpm / cmd 的输出里中文与 GBK 段都很常见，一碰就炸。
 * 纪律：`String.fromUtf8` 只对整个**合法序列**用；逐字节一律走这里（AGENTS §4-41 / §4-62）。
 */
public func lenientUtf8(bytes: Array<Byte>): String {
    let out = ArrayList<Byte>()
    var i: Int64 = 0
    while (i < bytes.size) {
        let b = Int64(bytes[i])
        var need: Int64 = 0
        if (b < 128) {
            // ASCII：原样
            out.add(bytes[i])
            i += 1
            continue
        } else if (b >= 0xC2 && b <= 0xDF) {
            need = 1
        } else if (b >= 0xE0 && b <= 0xEF) {
            need = 2
        } else if (b >= 0xF0 && b <= 0xF4) {
            need = 3
        } else {
            // 0x80..0xC1（野续字节）与 0xF5..0xFF：不可能是合法首字节
            need = -1
        }
        var ok = need > 0
        if (ok) {
            var k: Int64 = 1
            while (k <= need) {
                if (i + k >= bytes.size) {
                    ok = false
                    break
                }
                let c = Int64(bytes[i + k])
                if (c < 128 || c > 191) {
                    ok = false
                    break
                }
                k += 1
            }
        }
        if (!ok) {
            out.add(UInt8(63))   // '?'
            i += 1
            continue
        }
        var k2: Int64 = 0
        while (k2 <= need) {
            out.add(bytes[i + k2])
            k2 += 1
        }
        i += need + 1
    }
    return String.fromUtf8(out.toArray())
}

/** 去掉 ANSI 颜色转义（hvigor 输出带色，不剥会让 startsWith 判断失效） */
public func stripAnsi(s: String): String {
    let bytes = s.toArray()
    let out = ArrayList<Byte>()
    var i: Int64 = 0
    while (i < bytes.size) {
        if (bytes[i] == 27 && i + 1 < bytes.size && bytes[i + 1] == 91) {
            // ESC [ ... m  → 跳过直到 'm'
            var j = i + 2
            while (j < bytes.size) {
                let b = bytes[j]
                if ((b >= 65 && b <= 90) || (b >= 97 && b <= 122)) {
                    break
                }
                j += 1
            }
            i = if (j < bytes.size) { j + 1 } else { bytes.size }
            continue
        }
        out.add(bytes[i])
        i += 1
    }
    return lenientUtf8(out.toArray())
}

/** HAP（zip）里的关键条目扫描结果 */
public class HapEntries {
    public var hasModuleJson: Bool = false
    public var hasArm64So: Bool = false
    /** 出现的 arm64 .so 条目名 */
    public var arm64Sos: ArrayList<String> = ArrayList<String>()
    /** rawfile/ 相关条目数（>0 = 有死资源） */
    public var rawfileCount: Int64 = 0
    public var rawfileNames: ArrayList<String> = ArrayList<String>()

    public func ok(): Bool {
        return this.hasModuleJson && this.hasArm64So && this.rawfileCount == 0
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("ok", JsonBool(this.ok()))
        o.put("hasModuleJson", JsonBool(this.hasModuleJson))
        o.put("hasArm64So", JsonBool(this.hasArm64So))
        var arr = JsonArray()
        for (s in this.arm64Sos) {
            arr.add(JsonString(s))
        }
        o.put("arm64Sos", arr)
        o.put("rawfileCount", JsonInt(this.rawfileCount))
        var rf = JsonArray()
        for (s in this.rawfileNames) {
            rf.add(JsonString(s))
        }
        o.put("rawfileNames", rf)
        return o
    }
}

/**
 * 扫 HAP 字节流里的 zip 条目名（zip 把文件名明文存在本地头与中央目录里，
 * 所以字节扫描足够，不需要解压——HAP 里的 .so 是 deflate 压缩的，名字仍在）。
 *
 * 实现注意：HAP 是 MB 级二进制，**先一次性做成"ASCII 视图"字节数组**再扫，
 * 不要边扫边 `String +=`（那是 O(n²)，1.4 MB 就会卡成秒级）。
 */
public func scanHapEntries(data: Array<UInt8>): HapEntries {
    let e = HapEntries()
    // ASCII 视图：可打印字节照原样，其它换成 0（0 不会出现在我们找的 needle 里）
    let view: Array<UInt8> = Array<UInt8>(data.size, repeat: 0)
    for (i in 0..data.size) {
        let b = data[i]
        if (b >= 32 && b <= 126) {
            view[i] = b
        }
    }
    e.hasModuleJson = findBytes(view, "module.json", 0) >= 0

    // libs/arm64-v8a 下的 .so 条目
    var i: Int64 = 0
    while (true) {
        let idx = findBytes(view, "libs/arm64-v8a/", i)
        if (idx < 0) {
            break
        }
        var j = idx + "libs/arm64-v8a/".size
        while (j < view.size && isNameByte(view[j])) {
            j += 1
        }
        // 0.39.136：相邻条目在字节流里可能**紧贴**（zip 名字区之间没有分隔符，而 `isNameByte`
        // 又允许 `/` 与 `-`），贪婪吃到段尾会拼出假条目 —— 真机实测拿到过
        // `libdbx_lib.solibs/arm64-v8a/libentry.so`（§4-196 同族：从二进制按"连续合法字符"取串，
        // 永远要假设旁边就挨着别的串）。名字到**第一个** `.so` 就该结束。
        let soEnd = firstSuffixEndOf(view, idx + "libs/arm64-v8a/".size, j, ".so")
        if (soEnd > 0) {
            let name = String.fromUtf8(view[idx..soEnd])
            e.hasArm64So = true
            if (!e.arm64Sos.contains(name)) {
                e.arm64Sos.add(name)
            }
        }
        // 从下一个字节继续扫，而不是跳到 j：紧贴的那一条同样以 `libs/arm64-v8a/` 开头，
        // 跳过去就等于把它漏掉（dedup 由 contains 兜住）。
        i = idx + 1
    }

    // rawfile/（死资源：前端已编进 .so，真机产物里不该有）
    var k: Int64 = 0
    while (true) {
        let idx = findBytes(view, "rawfile/", k)
        if (idx < 0) {
            break
        }
        var j = idx + "rawfile/".size
        while (j < view.size && (isNameByte(view[j]) || view[j] == 47)) {
            j += 1
        }
        let name = String.fromUtf8(view[idx..j])
        e.rawfileCount += 1
        if (!e.rawfileNames.contains(name) && e.rawfileNames.size < 20) {
            e.rawfileNames.add(name)
        }
        k = if (j > idx) { j } else { idx + 1 }
    }
    return e
}

/** 文件名里允许的字节（字母数字 _ - . /） */
func isNameByte(b: UInt8): Bool {
    if ((b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)) {
        return true
    }
    return b == 95 || b == 45 || b == 46 || b == 47
}

/** 在字节数组里从 from 起找 needle 首次出现的位置；没有返回 -1 */
func findBytes(data: Array<UInt8>, needle: String, from: Int64): Int64 {
    let n = needle.toArray()
    if (n.size == 0 || data.size < n.size) {
        return -1
    }
    var i = if (from < 0) { 0 } else { from }
    while (i + n.size <= data.size) {
        var hit = true
        for (k in 0..n.size) {
            if (data[i + k] != n[k]) {
                hit = false
                break
            }
        }
        if (hit) {
            return i
        }
        i += 1
    }
    return -1
}

/**
 * 在 `[s, e)` 里找 `suffix` **首次出现处的结尾位置**（返回 exclusive end）；没有返回 -1。
 *
 * 用途：从 zip 名字区那种"没有分隔符"的字节流里取条目名时，名字必须截到第一个已知后缀
 * （`.so`）为止——贪婪吃到段尾会把下一条目拼进来（真机实测拿到过
 * `libdbx_lib.solibs/arm64-v8a/libentry.so`，§4-196 同族）。
 */
func firstSuffixEndOf(data: Array<UInt8>, s: Int64, e: Int64, suffix: String): Int64 {
    let sb = suffix.toArray()
    if (sb.size == 0 || e - s < sb.size) {
        return -1
    }
    var p = s
    while (p + sb.size <= e) {
        var hit = true
        for (k in 0..sb.size) {
            if (data[p + k] != sb[k]) {
                hit = false
                break
            }
        }
        if (hit) {
            return p + sb.size
        }
        p += 1
    }
    return -1
}

/** 解析 hvigor 日志文本并做 HAP 校验的总入口（命令层负责 IO，本函数只做判断） */
public func hapVerifyOf(hapBytes: Array<UInt8>): HapEntries {
    return scanHapEntries(hapBytes)
}

/**
 * 纯函数：`ohpm` 用哪种方式拉起（0.39.91）。
 *
 * 现场（rust-music-3，2026-11-08）：`t2h:hap` 在装配前要 `ohpm install --all`，
 * 代码直接 `executeWithOutput("<DevEco>/tools/ohpm/bin/ohpm.bat", …)`，Windows 上
 * 报 **`Created process failed, errMessage: "The system cannot find the file specified."`**
 * —— 文件明明存在，因为 **CreateProcess 不能直启 `.bat`**（得经 cmd.exe 或 node）。
 * 后果不是一句报错：hap 连红四轮，agent 只能自己手工 `ohpm install` 再重跑才过，
 * 白烧轮次（ADR D-015 里最贵的东西）。
 *
 * 所以判据是"用哪个启动器"，而不是"文件在不在"：
 *   · Windows + 有 node 与 `pm-cli.js` → `node`（与 hvigor 同款，实测可跑，且不经 shell）
 *   · 否则有 `ohpm.bat` → `bat`（POSIX 下正常）
 *   · 都没有 → 空串（调用方如实报"缺 ohpm"，不要静默跳过）
 */
/** 宿主是否 Windows（编译期分支，同 cjh_host.cj 的写法） */
@When[os == "Windows"]
public func hostIsWindows(): Bool {
    return true
}

@When[os != "Windows"]
public func hostIsWindows(): Bool {
    return false
}

public func ohpmLauncherOf(isWindows: Bool, nodeExists: Bool, cliJsExists: Bool,
    batExists: Bool): String {
    if (isWindows) {
        if (nodeExists && cliJsExists) {
            return "node"
        }
        if (batExists) {
            return "bat"
        }
        return ""
    }
    if (batExists) {
        return "bat"
    }
    if (nodeExists && cliJsExists) {
        return "node"
    }
    return ""
}
