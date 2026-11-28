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

/**
 * helper `fn resolve_app_data_dir` 的函数体区间（首个 `{` 到配平的 `}`）；找不到给 (-1,-1)。
 *
 * 为什么需要区间：改写裸调用时必须**跳过 helper 自己**——它的桌面分支本来就要调
 * `app.path().app_data_dir()`，一起改会把 helper 改成递归。括号按字节数，够用；
 * 已知局限：函数体里若有含花括号的字符串会被数错（本 helper 没有）。
 */
func helperBodyRangeOf(text: String): (Int64, Int64) {
    match (text.indexOf("fn resolve_app_data_dir")) {
        case Some(s) =>
            let bs = text.toArray()
            var i = s
            while (i < Int64(bs.size) && Int64(bs[i]) != 123) {
                i += 1
            }
            if (i >= Int64(bs.size)) {
                return (-1, -1)
            }
            var depth: Int64 = 0
            var j = i
            while (j < Int64(bs.size)) {
                let b = Int64(bs[j])
                if (b == 123) {
                    depth += 1
                } else if (b == 125) {
                    depth -= 1
                    if (depth == 0) {
                        return (i, j)
                    }
                }
                j += 1
            }
            return (-1, -1)
        case None => return (-1, -1)
    }
}

/**
 * 纯函数：**helper 之外**还有几处裸 `app.path().app_data_dir()`（0.39.156 真机实测的缺口）。
 *
 * 现场：R2-PORT-009 只注入了 helper，juCang 的 setup 里**第二次**用裸 `app_data_dir()` 开 SQLite ⇒
 * 鸿蒙上拿到 `/storage/Users/currentUser/…`（不可写、且**不报错**）⇒ 开库失败 ⇒ setup 返回 Err
 * ⇒ 进程 abort（`signal:6`），hilog 一行不留。规则不把已有的裸调用改掉，等于这一条没落地。
 */
public func bareAppDataDirCallsOf(text: String): Int64 {
    let needle = "app.path().app_data_dir()"
    let (hs, he) = helperBodyRangeOf(text)
    if (hs < 0) {
        return Int64(text.split(needle, -1).size) - 1
    }
    let before = text[0..hs]
    let after = text[(he + 1)..]
    return Int64(before.split(needle, -1).size) + Int64(after.split(needle, -1).size) - 2
}

/**
 * 纯函数：把 helper 之外的裸 `app.path().app_data_dir()` 改写成 `resolve_app_data_dir(app)`。
 *
 * 为什么可以机械替换：两者**返回类型与错误类型完全相同**（`Result<PathBuf, tauri::Error>`），
 * 而 `resolve_app_data_dir` 在鸿蒙分支固定给沙箱路径、桌面分支本来就走 `app_data_dir()`。
 * 幂等：改写后的文本不再含 needle。
 */
public func rewriteAppDataDirCallsOf(text: String): String {
    let needle = "app.path().app_data_dir()"
    let repl = "resolve_app_data_dir(app)"
    let (hs, he) = helperBodyRangeOf(text)
    if (hs < 0) {
        return text.replace(needle, repl)
    }
    return text[0..hs].replace(needle, repl) + text[hs..(he + 1)] +
        text[(he + 1)..].replace(needle, repl)
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
        // juCang 现场：helper 在（009 早先跑过），但 setup 里第二处 `app.path().app_data_dir()`
        // 还在 ⇒ 真机白屏闪退。这里补一次改写（after 留空，只做原地替换）。
        let text = readPortTextOf(path)
        let bare = bareAppDataDirCallsOf(text)
        if (bare > 0) {
            o.applied = true
            o.after = ""
            o.note = "已有 resolve_app_data_dir；本次把 ${bare} 处裸 `app.path().app_data_dir()` 改走它（鸿蒙上那是不可写路径）"
            return o
        }
        o.note = "lib.rs 已有 resolve_app_data_dir，且没有裸 app_data_dir() 调用——跳过"
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
