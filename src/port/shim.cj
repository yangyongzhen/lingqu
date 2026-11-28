package lingqu.port

import std.collection.*
import std.fs.*

/*
 * T4-4 平台 cfg 分支注入 + T4-5 ArkWeb 兼容层。
 *
 * 注入内容逐字来自 habit-tree @ ohos 分支的真机验证实现：
 *   · lib.rs：resolve_app_data_dir()（OHOS 沙箱 /data/storage/el2/base/files，
 *     桌面走 Tauri 路径解析）+ install_panic_hook()（panic 落盘 panic.log——
 *     鸿蒙 hilog 不捕获 Rust stderr，不落盘就永远拿不到崩溃证据）
 *   · index.html：localStorage 内存 polyfill（ArkWeb 自定义 scheme 下
 *     window.localStorage 为 null，直接读写的页面会崩）
 *   · confirm/prompt 替换与 type=color 降级：**机械替换会改坏代码**
 *     （要配 Promise 化对话框 UI、要改每个调用点）——归 guide 档，
 *     只探测给出位置与方案，计人工介入（T4-8 口径，验收 A3 可审计）。
 */

/** lib.rs / main.rs 注入块（Rust 源码，逐字来自 habit-tree，注释保留） */
public func handleHelperBlockOf(): String {
    let all = libRsInjectionBlock()
    match (all.indexOf("/// 同上的 AppHandle 版本")) {
        case Some(i) =>
            if (i > 0) {
                return all[(i - 1)..]
            }
            return all[i..]
        case None => return ""
    }
}

public func libRsInjectionBlock(): String {
    var s = ""
    s += "\n// === lingqu: R2-PORT-009 ===\n"
    s += "// 平台路径解析：OHOS 无 HOME 环境变量，dirs::data_dir() 返回 None，\n"
    s += "// app_data_dir() 会报错导致 setup panic → SIGABRT（真机实测）。\n"
    s += "fn resolve_app_data_dir(app: &tauri::App) -> Result<PathBuf, tauri::Error> {\n"
    s += "    #[cfg(target_env = \"ohos\")]\n"
    s += "    {\n"
    s += "        Ok(PathBuf::from(\"/data/storage/el2/base/files\"))\n"
    s += "    }\n"
    s += "    #[cfg(not(target_env = \"ohos\"))]\n"
    s += "    {\n"
    s += "        app.path().app_data_dir()\n"
    s += "    }\n"
    s += "}\n"
    s += "\n"
    s += "/// 同上的 AppHandle 版本（0.39.161）：其他模块（cache.rs / commands/xxx.rs）拿的是 &AppHandle，\n"
    s += "/// 塞给收 &App 的版本会类型不符 —— 真机上这些模块同样写不进沙箱。\n"
    s += "pub(crate) fn resolve_app_data_dir_handle(h: &tauri::AppHandle) -> Result<PathBuf, tauri::Error> {\n"
    s += "    #[cfg(target_env = \"ohos\")]\n"
    s += "    {\n"
    s += "        Ok(PathBuf::from(\"/data/storage/el2/base/files\"))\n"
    s += "    }\n"
    s += "    #[cfg(not(target_env = \"ohos\"))]\n"
    s += "    {\n"
    s += "        h.path().app_data_dir()\n"
    s += "    }\n"
    s += "}\n"
    s += "\n"
    s += "/// 崩溃诊断：panic 消息 + 回溯写入数据目录 panic.log（鸿蒙 hilog 不捕获 Rust stderr）。\n"
    s += "fn install_panic_hook(app: &tauri::App) {\n"
    s += "    let log_path = resolve_app_data_dir(app)\n"
    s += "        .unwrap_or_else(|_| PathBuf::from(\".\"))\n"
    s += "        .join(\"panic.log\");\n"
    s += "    std::panic::set_hook(Box::new(move |info| {\n"
    s += "        let bt = std::backtrace::Backtrace::force_capture();\n"
    s += "        let msg = format!(\"[panic] {info}\\n{bt}\\n----\\n\");\n"
    s += "        let _ = std::fs::OpenOptions::new()\n"
    s += "            .create(true)\n"
    s += "            .append(true)\n"
    s += "            .open(&log_path)\n"
    s += "            .and_then(|mut f| f.write_all(msg.as_bytes()));\n"
    s += "    }));\n"
    s += "}\n"
    return s
}

/** 读源文件文本（读不到给空串——"读不到"不是"没有裸调用"以外的另一种结论） */
func readPortTextOf(path: String): String {
    try {
        return String.fromUtf8(File.readFrom(path))
    } catch (e: Exception) {
        let _ = e
        return ""
    }
}

/** 模块级改写的累计结果（仓颉按值传参，用类收口） */
class ModuleRewriteTally {
    var files: Int64 = 0
    var sites: Int64 = 0
    var unknown: Int64 = 0
    var manifest: ArrayList<String> = ArrayList<String>()
}

/**
 * 动作层：把 `<srcDir>` 下其他 `.rs` 模块里的裸 `X.path().app_data_dir()` 改走对应 helper（0.39.161）。
 *
 * 为什么只改 lib.rs 不够：juCang 的 `cache.rs:79`（`cache_dir`）与 lib.rs 里的 `save_article`
 * 都直接调桌面语义 API ⇒ 真机上文章/视频缓存写进不可写路径；而 R2-PORT-009 原来只写 lib.rs/main.rs。
 *
 * 纪律：**逐文件备份 + `modules/manifest.txt`**，回滚成对（§4-33）；判不出接收者类型的保持原样并计数；
 * 跳过 `gen/`（脚手架）与 `target/`（产物），跳过自带 helper 定义的文件（防递归）。
 *
 * @return (改动的文件数, 改动处数, 判不出的处数)
 */
public func rewriteDataDirInModulesOf(srcDir: String, backupDir: String, depth: Int64): (Int64, Int64, Int64) {
    let tally = ModuleRewriteTally()
    walkDataDirModulesOf(srcDir, "", depth, tally, backupDir)
    if (tally.manifest.size > 0) {
        let mf = "${backupDir}/modules/manifest.txt"
        var text = ""
        if (exists(Path(mf))) {
            text = readPortTextOf(mf)
        }
        for (rel in tally.manifest) {
            if (!text.contains("${rel}\n")) {
                text += "${rel}\n"
            }
        }
        let _ = writePortTextOf("${backupDir}/modules", mf, text)
    }
    return (tally.files, tally.sites, tally.unknown)
}

/** 写文本（失败原因进返回值，别静默） */
func writePortTextOf(dir: String, file: String, text: String): String {
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir), recursive: true)
        }
        File.writeTo(file, text.toArray())
        return ""
    } catch (e: Exception) {
        return "${e}"
    }
}

func walkDataDirModulesOf(base: String, rel: String, depth: Int64, tally: ModuleRewriteTally, backupDir: String): Unit {
    let dir = if (rel == "") { base } else { "${base}/${rel}" }
    var entries: Array<FileInfo> = []
    try {
        entries = Directory.readFrom(Path(dir))
    } catch (e: Exception) {
        let _ = e
        return
    }
    for (info in entries) {
        let name = info.name
        let childRel = if (rel == "") { name } else { "${rel}/${name}" }
        if (info.isDirectory()) {
            if (name == "gen" || name == "target" || depth <= 1) {
                continue
            }
            walkDataDirModulesOf(base, childRel, depth - 1, tally, backupDir)
            continue
        }
        if (!name.endsWith(".rs") || name == "lib.rs" || name == "main.rs") {
            continue
        }
        let p = "${dir}/${name}"
        let text = readPortTextOf(p)
        if (text == "" || text.contains("fn resolve_app_data_dir")) {
            continue
        }
        let (fixed, changed, unk) = rewriteDataDirInModuleOf(text)
        tally.unknown += unk
        if (changed == 0) {
            continue
        }
        // 备份到 modules/<rel 用 __ 拍平>.bak（Windows 上避免多层目录），再写回
        let flat = childRel.replace("/", "__")
        let bak = "${backupDir}/modules/${flat}.bak"
        let bakErr = writePortTextOf("${backupDir}/modules", bak, text)
        if (bakErr != "") {
            continue
        }
        let writeErr = writePortTextOf(dir, p, fixed)
        if (writeErr == "") {
            tally.files += 1
            tally.sites += changed
            tally.manifest.add(childRel)
        }
    }
}

/**
 * 纯函数：调用处要不要补 `&`（0.39.161）。
 *
 * 命令层函数常把 `AppHandle` **按值**收（`app: tauri::AppHandle`），而我们的 helper 收的是
 * `&tauri::AppHandle`；Rust 只在**方法调用**上自动借用，普通函数调用 `f(app)` 不会 ⇒ 必须写成
 * `f(&app)`。引用形态（`&tauri::AppHandle`）就不要再加 `&`（会变成 `&&`）。
 */
public func dataDirNeedsRefOf(sig: String, receiver: String): Bool {
    let r = receiver.trimAscii()
    if (r.size == 0) {
        return false
    }
    if (sig.contains("${r}: &tauri::AppHandle") || sig.contains("${r}: &AppHandle") ||
        countNotFollowedOf(sig, "${r}: &tauri::App", "Handle") > 0 ||
        countNotFollowedOf(sig, "${r}: &App", "Handle") > 0) {
        return false
    }
    if (sig.contains("${r}: tauri::AppHandle") || sig.contains("${r}: AppHandle") ||
        countNotFollowedOf(sig, "${r}: tauri::App", "Handle") > 0 ||
        countNotFollowedOf(sig, "${r}: App", "Handle") > 0) {
        return true
    }
    return false
}

/** 从 from 开始找 needle（String.indexOf 没有起点参数，自己按字节扫） */
func indexOfFromOf(text: String, needle: String, from: Int64): Option<Int64> {
    let t = text.toArray()
    let p = needle.toArray()
    if (p.size == 0 || from < 0 || from >= Int64(t.size)) {
        return None
    }
    var i = from
    while (i + Int64(p.size) <= Int64(t.size)) {
        var ok = true
        var j: Int64 = 0
        while (j < Int64(p.size)) {
            if (t[i + j] != p[j]) {
                ok = false
                break
            }
            j += 1
        }
        if (ok) {
            return Some(i)
        }
        i += 1
    }
    return None
}

/** 数 needle 出现次数，但**后面紧邻 follow 的不算**（用来区分 `&App` 与 `&AppHandle`） */
func countNotFollowedOf(text: String, needle: String, follow: String): Int64 {
    var n: Int64 = 0
    var from: Int64 = 0
    while (true) {
        match (indexOfFromOf(text, needle, from)) {
            case Some(i) =>
                let after = i + Int64(needle.size)
                let tail = if (after + Int64(follow.size) <= Int64(text.size)) {
                    text[after..(after + Int64(follow.size))]
                } else {
                    ""
                }
                if (tail != follow) {
                    n += 1
                }
                from = i + 1
            case None => break
        }
    }
    return n
}

/**
 * 纯函数：某模块文件里，接收者 `recv` 该走哪个 helper（0.39.161）。
 *
 * 为什么要按签名判：`resolve_app_data_dir` 收 `&tauri::App`，而其他模块（`cache.rs` 的
 * `cache_dir`、`commands/xxx.rs`）拿的是 `&AppHandle` —— 机械塞给 App 版会**类型不符**（编不过）。
 * 顺序要紧：先判 `AppHandle`，再判 `App`（`&tauri::App` 是 `&tauri::AppHandle` 的前缀）。
 *
 * @return `resolve_app_data_dir_handle` / `resolve_app_data_dir` / `""`（判不出，调用方**保持原样**）
 */
public func dataDirHelperForOf(fileText: String, receiver: String): String {
    let r = receiver.trimAscii()
    if (r.size == 0) {
        return ""
    }
    var h: Int64 = 0
    h += Int64(fileText.split("${r}: &tauri::AppHandle", -1).size) - 1
    h += Int64(fileText.split("${r}: &AppHandle", -1).size) - 1
    // 按值形态（`app: tauri::AppHandle`，命令层常见）——漏了它 juCang 的 save_article/load_article 就改不到
    h += Int64(fileText.split("${r}: tauri::AppHandle", -1).size) - 1
    h += Int64(fileText.split("${r}: AppHandle", -1).size) - 1
    var a: Int64 = 0
    a += countNotFollowedOf(fileText, "${r}: &tauri::App", "Handle")
    a += countNotFollowedOf(fileText, "${r}: &App", "Handle")
    a += countNotFollowedOf(fileText, "${r}: tauri::App", "Handle")
    a += countNotFollowedOf(fileText, "${r}: App", "Handle")
    if (h > 0 && a == 0) {
        return "resolve_app_data_dir_handle"
    }
    if (a > 0 && h == 0) {
        return "resolve_app_data_dir"
    }
    return ""
}

/**
 * 纯函数：模块文件里的裸 `<recv>.path().app_data_dir()` 改走对应 helper（0.39.161）。
 *
 * 判不出接收者类型（或接收者不是一个标识符链，例如 `(app)`）时**保持原样**并计数——
 * 不猜类型，猜错就是编不过或运行期拿错路径。返回 (新文本, 改了几处, 判不出几处)。
 */
public func rewriteDataDirInModuleOf(text: String): (String, Int64, Int64) {
    return rewriteDataDirCallsGenericOf(text, true)
}

/** 空白/换行字节（跨行写法要跳过它们才取得到接收者） */
func isSpaceByteOf(c: Int64): Bool {
    return c == 32 || c == 9 || c == 10 || c == 13
}

/** helper 自身函数体区间（App 版与 AppHandle 版各一段）——区间内的调用**不许改**，否则变成递归 */
func helperBodyRangesOf(text: String): (Array<Int64>, Array<Int64>) {
    let starts = ArrayList<Int64>()
    let ends = ArrayList<Int64>()
    let bs = text.toArray()
    for (marker in ["fn resolve_app_data_dir_handle", "fn resolve_app_data_dir"]) {
        var from: Int64 = 0
        while (true) {
            match (indexOfFromOf(text, marker, from)) {
                case Some(s) =>
                    var i = s
                    while (i < Int64(bs.size) && Int64(bs[i]) != 123) {
                        i += 1
                    }
                    var depth: Int64 = 0
                    var j = i
                    var found = false
                    while (j < Int64(bs.size)) {
                        let b = Int64(bs[j])
                        if (b == 123) {
                            depth += 1
                        } else if (b == 125) {
                            depth -= 1
                            if (depth == 0) {
                                starts.add(i)
                                ends.add(j)
                                found = true
                                break
                            }
                        }
                        j += 1
                    }
                    from = if (found) { j + 1 } else { s + Int64(marker.size) }
                case None => break
            }
        }
    }
    return (starts.toArray(), ends.toArray())
}

/** 调用点所在函数的签名（从最近的 `fn ` 到其后的 `{`）；找不到给 "" */
func enclosingFnSigOf(text: String, at: Int64): String {
    var from: Int64 = 0
    var last: Int64 = -1
    while (true) {
        match (indexOfFromOf(text, "fn ", from)) {
            case Some(i) =>
                if (i < at) {
                    last = i
                    from = i + 3
                } else {
                    break
                }
            case None => break
        }
    }
    if (last < 0) {
        return ""
    }
    let bytes = text.toArray()
    var j = last
    while (j < Int64(bytes.size) && Int64(bytes[j]) != 123) {
        j += 1
    }
    return text[last..j]
}

func insideRangesOf(rb: Array<Int64>, re: Array<Int64>, i: Int64): Bool {
    var k = 0
    while (k < Int64(rb.size)) {
        if (i >= rb[k] && i <= re[k]) {
            return true
        }
        k += 1
    }
    return false
}

/**
 * 纯函数：把裸 `<recv>` + 空白 + `.path()` + 空白 + `.app_data_dir()` 改走对应 helper（0.39.161）。
 *
 * **必须允许跨行**：juCang 的 `cache.rs` 写的是 `let dir = app` 换行 `.path()` 换行 `.app_data_dir()`
 * ——只认单行 `.path().app_data_dir()` 的初版因此一处都没改到（实测 `port --apply` 后 `cache.rs:79`
 * 原样不动，`platform-api` 也照旧 fail）。
 * helper 自身函数体里的调用跳过（否则把 helper 改成递归）；`[cratePrefix]`：其他模块引用 lib.rs 里的
 * helper 要带 `crate::`，lib.rs 自己不带。
 */
public func rewriteDataDirCallsGenericOf(text: String, cratePrefix: Bool): (String, Int64, Int64) {
    let tail = ".app_data_dir()"
    let bytes = text.toArray()
    let (skipB, skipE) = helperBodyRangesOf(text)
    var out = ""
    var cursor: Int64 = 0
    var changed: Int64 = 0
    var unknown: Int64 = 0
    var from: Int64 = 0
    while (true) {
        match (indexOfFromOf(text, tail, from)) {
            case Some(i) =>
                let end = i + Int64(tail.size)
                from = end
                var handled = false
                let inHelperBody = insideRangesOf(skipB, skipE, i)
                if (!inHelperBody) {
                    var j = i
                    while (j > 0 && isSpaceByteOf(Int64(bytes[j - 1]))) {
                        j -= 1
                    }
                    if (j >= 7 && text[(j - 7)..j] == ".path()") {
                        var k = j - 7
                        while (k > 0 && isSpaceByteOf(Int64(bytes[k - 1]))) {
                            k -= 1
                        }
                        var s = k
                        while (s > 0) {
                            let c = Int64(bytes[s - 1])
                            let isIdent = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) ||
                                (c >= 97 && c <= 122) || c == 95 || c == 46
                            if (!isIdent) {
                                break
                            }
                            s -= 1
                        }
                        let recv = text[s..k].trimAscii()
                        // 按**所在函数**的签名判类型：同一文件里 `app` 可能既是 &App（lib.rs setup）
                        // 又是 &AppHandle（save_article / cache.rs），按整文件判会两边都命中 ⇒ 判不出。
                        let sig = enclosingFnSigOf(text, s)
                        // 整段都没有 `fn`（片段/测试文本）时按旧行为假定 App 版：真实代码里调用必然在函数内，
                        // 所以这条只在"被人当片段用"时生效，不会误判真实工程。
                        let helper = if (sig.size == 0) { "resolve_app_data_dir" } else { dataDirHelperForOf(sig, recv) }
                        if (helper.size > 0 && recv.size > 0) {
                            out += text[cursor..s]
                            let arg = if (dataDirNeedsRefOf(sig, recv)) { "&" + recv } else { recv }
                            if (cratePrefix) {
                                out += "crate::" + helper + "(" + arg + ")"
                            } else {
                                out += helper + "(" + arg + ")"
                            }
                            cursor = end
                            changed += 1
                            handled = true
                        }
                    }
                }
                // helper 自身函数体里的调用是**静默跳过**（那是 helper 的实现细节，不存在"判不出"）；
                // 只有"真在业务代码里、但接收者类型判不出"才算判不出并保持原样。
                if (!handled && !inHelperBody) {
                    unknown += 1
                }
            case None => break
        }
    }
    if (changed == 0) {
        return (text, 0, unknown)
    }
    out += text[cursor..]
    return (out, changed, unknown)
}

/**
 * 纯函数：**helper 之外**还有几处裸 `app.path().app_data_dir()`（0.39.156 真机实测的缺口）。
 *
 * 现场：R2-PORT-009 只注入了 helper，juCang 的 setup 里**第二次**用裸 `app_data_dir()` 开 SQLite ⇒
 * 鸿蒙上拿到 `/storage/Users/currentUser/…`（不可写、且**不报错**）⇒ 开库失败 ⇒ setup 返回 Err
 * ⇒ 进程 abort（`signal:6`），hilog 一行不留。规则不把已有的裸调用改掉，等于这一条没落地。
 */
public func bareAppDataDirCallsOf(text: String): Int64 {
    let (_, changed, unknown) = rewriteDataDirCallsGenericOf(text, false)
    return changed + unknown
}

/**
 * 纯函数：把 helper 之外的裸 `X.path().app_data_dir()` 改写成对应 helper（lib.rs 内，不带 `crate::`）。
 *
 * 0.39.161 起走通用实现：**允许跨行**（`app` 换行 `.path()` 换行 `.app_data_dir()` 是常见写法），
 * 并按文件签名选 App / AppHandle 版 helper。
 */
public func rewriteAppDataDirCallsOf(text: String): String {
    let (out, _, _) = rewriteDataDirCallsGenericOf(text, false)
    return out
}

/**
 * R2-PORT-009：lib.rs 注入沙箱路径解析 + panic hook（T4-4）。
 * 幂等判定：文件里已有 `resolve_app_data_dir` 就跳过。
 * 调用点接线（setup 里 install_panic_hook(app)）涉及语义，归 guide 提示。
 */
public func libRsOutcome(path: String): RuleOutcome {
    let block = libRsInjectionBlock()
    var o = RuleOutcome("R2-PORT-009", false, "", "", block)
    o.tier = T_AUTO
    if (fileContains(path, "resolve_app_data_dir")) {
        // 0.39.156：helper 已注入 ≠ 这条规则落地了——**已有的裸调用也得改掉**。
        // 0.39.161：且要区分"两版 helper 都在"与"只有 App 版"——后者要**补注入 AppHandle 版**，
        // 否则 0.39.161 在 cache.rs 等模块改写出来的 `crate::resolve_app_data_dir_handle(...)`
        // 会指向一个不存在的函数（编不过）。实测 juCang 就卡在这个状态。
        let text = readPortTextOf(path)
        let bare = bareAppDataDirCallsOf(text)
        let needHandle = !fileContains(path, "resolve_app_data_dir_handle")
        if (bare > 0 || needHandle) {
            o.applied = true
            o.after = if (needHandle) { handleHelperBlockOf() } else { "" }
            o.note = if (needHandle && bare > 0) {
                "已有 App 版 helper；本次补注入 AppHandle 版，并改写 ${bare} 处裸 app_data_dir() 调用"
            } else if (needHandle) {
                "已有 App 版 helper；本次补注入 AppHandle 版（供 cache.rs 等其他模块用）"
            } else {
                "两版 helper 都在；本次改写 ${bare} 处裸 app_data_dir() 调用"
            }
            return o
        }
        o.note = "lib.rs 已有两版 helper，且没有裸 app_data_dir() 调用——跳过"
        return o
    }
    if (!fileContains(path, "fn run()")) {
        o.note = "未找到 fn run()（不像 Tauri 后端入口）——跳过"
        return o
    }
    o.applied = true
    o.note = "lib.rs 注入沙箱路径解析 + panic hook，并把裸 app_data_dir() 调用改走它；**还需在 setup 里接线调用（guide）**"
    return o
}

/** localStorage 透明桥（JS，逐字来自 habit-tree index.html 的内存 polyfill） */
public func localStorageShimJs(): String {
    var s = ""
    s += "<script>\n"
    s += "// === lingqu: R2-PORT-011 ===\n"
    s += "// ArkWeb 自定义 scheme 下 window.localStorage 为 null——装内存 polyfill。\n"
    s += "// 桌面（localStorage 原生可用）此段不生效；业务代码零改动。\n"
    s += "if (typeof window !== \"undefined\" && !window.localStorage) {\n"
    s += "  var __lsMap = new Map();\n"
    s += "  var __lsDirty = new Set();\n"
    s += "  var __lsTimer = null;\n"
    s += "  function __lsInvoke(cmd, args) {\n"
    s += "    try {\n"
    s += "      if (window.__TAURI_INTERNALS__ && typeof window.__TAURI_INTERNALS__.invoke === \"function\") {\n"
    s += "        return window.__TAURI_INTERNALS__.invoke(cmd, args);\n"
    s += "      }\n"
    s += "    } catch (e) { /* fallthrough */ }\n"
    s += "    return Promise.reject(new Error(\"no tauri bridge\"));\n"
    s += "  }\n"
    s += "  Object.defineProperty(window, \"localStorage\", {\n"
    s += "    value: {\n"
    s += "      getItem: function (k) { k = String(k); return __lsMap.has(k) ? __lsMap.get(k) : null; },\n"
    s += "      setItem: function (k, v) { k = String(k); __lsMap.set(k, String(v)); },\n"
    s += "      removeItem: function (k) { k = String(k); __lsMap.delete(k); },\n"
    s += "      clear: function () { __lsMap.clear(); },\n"
    s += "      key: function (i) { return Array.from(__lsMap.keys())[i] || null; },\n"
    s += "      get length() { return __lsMap.size; }\n"
    s += "    },\n"
    s += "    configurable: true, writable: true\n"
    s += "  });\n"
    s += "}\n"
    s += "</script>\n"
    return s
}

/**
 * R2-PORT-011：index.html 注入 localStorage polyfill（T4-5）。
 * 幂等判定：已有 `window.localStorage` polyfill 标记（含 lingqu 标记或 __lsInit）就跳过。
 */
public func localStorageOutcome(path: String): RuleOutcome {
    let shim = localStorageShimJs()
    var o = RuleOutcome("R2-PORT-011", false, "", "", shim)
    o.tier = T_AUTO
    if (fileContains(path, "__lsInit") || fileContains(path, "lingqu: R2-PORT-011")) {
        o.note = "index.html 已有 localStorage 兼容层——跳过"
        return o
    }
    if (!fileContains(path, "<!DOCTYPE html>") && !fileContains(path, "<html")) {
        o.note = "不是 HTML 文件——跳过"
        return o
    }
    o.applied = true
    o.note = "index.html 注入 localStorage 内存 polyfill（head 后，业务 script 之前）"
    return o
}

/**
 * T4-5 guide 档探测：confirm/prompt 调用点与 type=color 出现位置。
 * 只探测不改（机械替换会改坏代码），给出行号与处置方案 → 人工介入计数。
 */
public func frontendGuideOutcomes(srcDir: String): ArrayList<RuleOutcome> {
    let out = ArrayList<RuleOutcome>()

    // R2-PORT-012：confirm/prompt → 应用内对话框（guide）
    var o12 = RuleOutcome("R2-PORT-012", false, "", "", "")
    o12.tier = T_GUIDE
    let jsHits = grepMarker(srcDir, ["confirm(", "prompt("], [".ts", ".js"], ["dialog", "polyfill"])
    if (jsHits.size == 0) {
        o12.note = "前端未发现原生 confirm/prompt 调用——无需处置"
    } else {
        o12.applied = true
        o12.needsHuman = true
        o12.before = joinLines(jsHits)
        o12.after = "方案：加 Promise 化 confirmDialog/promptDialog（应用内对话框）后逐调用点替换——参考 habit-tree src/ui.ts openDialog"
        o12.note = "原生 confirm/prompt 在 ArkWeb 静默失效（未接 onJsConfirm/onJsPrompt 回调）"
    }
    out.add(o12)

    // R2-PORT-013：type=color → 应用内色板（guide）
    var o13 = RuleOutcome("R2-PORT-013", false, "", "", "")
    o13.tier = T_GUIDE
    let colorHits = grepMarker(srcDir, ["type=\"color\"", "type='color'", "type=color"], [".ts", ".js", ".html", ".vue"], [])
    if (colorHits.size == 0) {
        o13.note = "前端未发现 <input type=\"color\">——无需处置"
    } else {
        o13.applied = true
        o13.needsHuman = true
        o13.before = joinLines(colorHits)
        o13.after = "方案：换应用内色板对话框（预设色板 + hex 输入）；display:none 隐藏无效，必须 remove()——参考 habit-tree src/ui.ts getColorDialog"
        o13.note = "ArkWeb 不支持原生取色器（点击无反应，应用市场审核实测）"
    }
    out.add(o13)

    return out
}

/**
 * 极简探测：目录下按扩展名找包含标记的文件:行（排除排除词所在的行，
 * 比如对话框实现自身）——只找第一处起最多 8 行证据，防报告爆炸。
 */
func grepMarker(dir: String, markers: Array<String>, exts: Array<String>, excludeLineContains: Array<String>): ArrayList<String> {
    let hits = ArrayList<String>()
    try {
        walkCollectFiles(dir, dir, exts, hits, markers, excludeLineContains)
    } catch (e: Exception) {
        // 目录不存在等：返回已有 hits（可能为空）
    }
    return hits
}

func walkCollectFiles(root: String, cur: String, exts: Array<String>, hits: ArrayList<String>,
    markers: Array<String>, excludeLineContains: Array<String>): Unit {
    if (hits.size >= 8) {
        return
    }
    var entries: Array<FileInfo>
    try {
        entries = Directory.readFrom(cur)
    } catch (e: Exception) {
        let _ = e
        return
    }
    for (info in entries) {
        if (hits.size >= 8) {
            return
        }
        let name = info.name
        let childAbs = "${cur}/${name}"
        if (info.isDirectory()) {
            // 跳过 node_modules / dist / 目标目录
            if (name == "node_modules" || name == "dist" || name == "target" || name.startsWith(".")) {
                continue
            }
            walkCollectFiles(root, childAbs, exts, hits, markers, excludeLineContains)
            continue
        }
        var matched = false
        for (e in exts) {
            if (name.endsWith(e)) {
                matched = true
                break
            }
        }
        if (!matched) {
            continue
        }
        try {
            let text = String.fromUtf8(File.readFrom(childAbs))
            let lines = text.split("\n", -1)
            for (i in 0..lines.size) {
                if (hits.size >= 8) {
                    return
                }
                let l = lines[i]
                var hasMarker = false
                for (m in markers) {
                    if (l.contains(m)) {
                        hasMarker = true
                        break
                    }
                }
                if (!hasMarker) {
                    continue
                }
                var excluded = false
                for (x in excludeLineContains) {
                    if (l.contains(x)) {
                        excluded = true
                        break
                    }
                }
                if (excluded) {
                    continue
                }
                var rel = childAbs
                if (childAbs.startsWith(root + "/")) {
                    rel = childAbs[(root.size + 1)..]
                }
                hits.add("${rel}:${i + 1}: ${l.trimAscii()}")
            }
        } catch (e: Exception) {
            // 单文件读不了就跳过
        }
    }
}

func joinLines(items: ArrayList<String>): String {
    var s = ""
    for (i in 0..items.size) {
        if (i > 0) {
            s += "\n"
        }
        s += items[i]
    }
    return s
}
