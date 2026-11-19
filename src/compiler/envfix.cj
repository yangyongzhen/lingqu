package lingqu.compiler

import std.collection.*
import std.fs.*

/*
 * 0.39.126（R-2 环境关）：交叉编译前修两件"必然挡路"的事，证据落 build 落档。
 *
 * ① 样本自带的 `.cargo/config.toml` 可能把**过期 SDK 路径**写死
 *    （cc-switch-harmonyos 实测：`sdk/HarmonyOS-NEXT-DB6/…` 目录早就不存在），
 *    而工程配置优先级**高于**我们从环境推导的值 ⇒ cargo 直接 `ToolNotFound`（§4-171）。
 *    判据：路径类取值**必须存在才采用**，否则按推导出的 NDK 重写同一"尾巴"。
 * ② 未迁移工程裸跑时，C 依赖（`-sys` / `ring` / `aws-lc-sys`）的 cc-rs 拿宿主 `cc`
 *    + `--target=…ohos` ⇒ `fatal error: 'assert.h' file not found`（§4-172）。
 *    处置：依赖树里有 C 依赖、而工程配置缺 `CC_aarch64_unknown_linux_ohos` 时，
 *    把 `[env]` 段补上（复用 R2-PORT-008 的片段，幂等）。
 *
 * 这些函数都不碰"判定谁对谁错"，只做**能存在性校验的文本修正**，并把修了什么回投给上层当证据。
 */

/** 从一行 TOML 里取**第一个**引号内的值（没有/不配对给空串） */
public func quotedValueOf(line: String): String {
    let bytes = line.toArray()
    var first: Int64 = -1
    var i: Int64 = 0
    while (i < bytes.size) {
        if (bytes[i] == 34) {
            first = i
            break
        }
        i += 1
    }
    if (first < 0) {
        return ""
    }
    var j = first + 1
    while (j < bytes.size) {
        if (bytes[j] == 34) {
            return line[(first + 1)..j]
        }
        j += 1
    }
    return ""
}

/** 反斜杠归一成正斜杠（写进 TOML 基本字符串前必须做：`D:\oh` 里的 `\o` 不是合法转义） */
public func posixPathOf(p: String): String {
    var out = ""
    for (b in p.toArray()) {
        if (b == 92) {
            out += "/"
        } else {
            out += String.fromUtf8([b])
        }
    }
    return out
}

/**
 * 把 TOML/JSON 字符串里的**转义反斜杠**还原成单反斜杠。
 *
 * 2026-11-19 实测教训：cc-switch 的 `.cargo/config.toml` 里路径是 `D:\\oh\\…\\clang.exe`（双反斜杠），
 * 直接拿去 `exists()` 必然为假、尾巴也认不出，于是自动改写会**把行改坏**（§4-42 同族）。
 * 所以检测必须先反解义；**写回**这一步暂时不自动做（见 `staleSdkSuggestionsOf` 的说明）。
 */
public func unescapePathOf(p: String): String {
    var out = ""
    let bytes = p.toArray()
    var i: Int64 = 0
    while (i < bytes.size) {
        if (bytes[i] == 92 && i + 1 < bytes.size && bytes[i + 1] == 92) {
            out += "\\"
            i += 2
            continue
        }
        out += String.fromUtf8([bytes[i]])
        i += 1
    }
    return out
}

/** 路径里可由 NDK 重建的"尾巴"（认不出给空串）—— 只认 SDK 里那几个固定位置 */
public func sdkTailOf(p: String): String {
    for (t in ["llvm/bin/clang++", "llvm/bin/clang", "llvm/bin/llvm-ar", "sysroot"]) {
        match (p.indexOf(t)) {
            case Some(i) => return p[i..]
            case None => ()
        }
    }
    return ""
}

/**
 * 一行里**所有**能认出尾巴的绝对路径，逐个改写成 `ndk/<同一尾巴>`。
 *
 * 不能在"整条引号值"上做替换：`rustflags = ["-C", "link-arg=--sysroot=D:/…/sysroot"]`
 * 这种一行里有多个引号值，按首尾引号取会把整段当路径，改出来是坏行（实测踩过）。
 * 所以改成扫"尾巴"：找到 `llvm/bin/clang` / `llvm/bin/llvm-ar` / `sysroot` 出现处，
 * 向左走到路径起点（空白/引号/`=` 为止），只替换那一段。
 */
public func rewriteStaleSdkLineOf(line: String, ndk: String): String {
    if (ndk == "") {
        return line
    }
    var out = line
    for (t in ["llvm/bin/clang++", "llvm/bin/clang", "llvm/bin/llvm-ar", "sysroot"]) {
        var idx: Int64 = 0
        while (idx < out.size) {
            var at: Int64 = -1
            match (out[idx..].indexOf(t)) {
                case Some(rel) => at = idx + rel
                case None => at = -1
            }
            if (at < 0) {
                break
            }
            var start = at
            let bytes = out.toArray()
            while (start > 0) {
                let c = bytes[start - 1]
                if (c == 32 || c == 34 || c == 39 || c == 61 || c == 9 || c == 10 || c == 13) {
                    break
                }
                start -= 1
            }
            let end = at + t.size
            let cur = out[start..end]
            if (cur.startsWith(ndk)) {
                idx = end
            } else {
                out = out[..start] + ndk + "/" + t + out[end..]
                idx = start + ndk.size + 1 + t.size
            }
        }
    }
    return out
}

/** 依赖树里有没有"要 C 编译器"的 crate（判据只认名字，不做语义推断） */
public func hasCDepOf(lockText: String): Bool {
    for (k in ["-sys\"", "name = \"ring\"", "aws-lc-sys\"", "libdbus-sys\""]) {
        match (lockText.indexOf(k)) {
            case Some(_) => return true
            case None => ()
        }
    }
    return false
}

/**
 * 修工程自带的 `.cargo/config.toml` 里的**过期 SDK 路径**（存在性校验后才改）。
 * 返回修了哪些（`旧 → 新`，空数组 = 没动）。改前留 `<文件>.lingqu-bak`。
 */
public func fixStaleCargoConfigOf(configPath: String, ndk: String): ArrayList<String> {
    let fixes = ArrayList<String>()
    if (ndk == "" || !exists(Path(configPath))) {
        return fixes
    }
    let text = lenientUtf8(File.readFrom(configPath))
    for (ln in text.split("\n")) {
        let bytes = ln.toArray()
        for (t in ["llvm/bin/clang++", "llvm/bin/clang", "llvm/bin/llvm-ar", "sysroot"]) {
            var idx: Int64 = 0
            while (idx < ln.size) {
                var at: Int64 = -1
                match (ln[idx..].indexOf(t)) {
                    case Some(r) => at = idx + r
                    case None => at = -1
                }
                if (at < 0) {
                    break
                }
                var start = at
                while (start > 0) {
                    let c = bytes[start - 1]
                    if (c == 32 || c == 34 || c == 61 || c == 9 || c == 39) {
                        break
                    }
                    start -= 1
                }
                let raw = ln[start..(at + t.size)]
                let real = unescapePathOf(raw)
                if (!exists(Path(real))) {
                    let sug = "${raw} → ${ndk}/${t}"
                    var dup = false
                    for (f in fixes) {
                        if (f == sug) {
                            dup = true
                            break
                        }
                    }
                    if (!dup) {
                        fixes.add(sug)
                    }
                }
                idx = at + t.size
            }
        }
    }
    return fixes
}

/**
 * 依赖树有 C 依赖、而工程配置缺 target CC ⇒ 补 `[env]` 段（幂等）。
 * 返回 true 表示补了。
 */
public func ensureTargetCcOf(configPath: String, ndk: String, lockText: String): Bool {
    if (ndk == "" || !hasCDepOf(lockText)) {
        return false
    }
    var text = ""
    if (exists(Path(configPath))) {
        text = lenientUtf8(File.readFrom(configPath))
        if (text.contains("CC_aarch64_unknown_linux_ohos")) {
            return false
        }
    }
    // 与 R2-PORT-008 生成的 `[env]` 片段**逐字一致**（此处内联而不是 import lingqu.port，
    // 避免 compiler ↔ port 的包依赖成环；两边改动要同步，见 toolchain.cj 的 cargoEnvOnlyToml）。
    // 注意：写进 TOML 基本字符串的路径**必须正斜杠**（`D:\oh` 里的 `\o` 不是合法转义，
    // 实测把 tauri-mqtt 的配置写成解析失败）。
    let ndkP = posixPathOf(ndk)
    var frag = "\n[env]\n"
    frag += "OHOS_NDK_HOME = \"${ndkP}\"\n"
    frag += "CC_aarch64_unknown_linux_ohos = \"${ndkP}/llvm/bin/clang\"\n"
    frag += "AR_aarch64_unknown_linux_ohos = \"${ndkP}/llvm/bin/llvm-ar\"\n"
    frag += "CFLAGS_aarch64_unknown_linux_ohos = \"-target aarch64-linux-ohos --sysroot=${ndkP}/sysroot -D__MUSL__\"\n"
    try {
        let bak = configPath + ".lingqu-bak"
        if (exists(Path(configPath)) && !exists(Path(bak))) {
            File.writeTo(Path(bak), File.readFrom(configPath))
        }
        File.writeTo(Path(configPath), (text + frag + "\n").toArray())
        return true
    } catch (e: Exception) {
        let _ = e
        return false
    }
}
