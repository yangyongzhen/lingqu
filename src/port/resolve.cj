package lingqu.port

import std.collection.*
import std.fs.*

/*
 * P4 第三刀补充规则：setup 接线（R2-PORT-010）与对话框资源生成（R2-PORT-014）。
 *
 * 010：把 009 注入的 install_panic_hook / resolve_app_data_dir 接进 .setup() 块——
 *      形态照 habit-tree 迁移后 lib.rs（`.setup(|app| {` 后插两行调用）。
 *      语义判定足够机械（固定两行、位置固定），从 guide 升 auto；没找到
 *      `.setup(|app| {` 的工程保持 guide（留人工）。
 * 014：往前端目录落 `lingqu-dialog.js` + `lingqu-dialog.css`——独立模块，
 *      页面自行引入；confirm/prompt **调用点的替换**仍归 012 的 guide
 *      （要改控制流，机械替换会改坏代码——这条边界不移）。
 */

/** setup 块内要注入的调用行（照 habit-tree 迁移后的实际形态） */
public func setupWiringLines(): Array<String> {
    return [
        "            // === lingqu: R2-PORT-010 ===",
        // 0.39.156 真机实测：**先建目录、再装 hook**。反过来的话，崩溃那一刻 hook 自己
        // 连日志都写不进去（沙箱目录还不存在）⇒ 白屏闪退只剩一句 `exit with signal:6`。
        "            let dir = resolve_app_data_dir(app)?;",
        "            std::fs::create_dir_all(&dir)?;",
        "            install_panic_hook(app);",
    ]
}

/**
 * R2-PORT-010：setup 接线。lib.rs（或 main.rs）含 `.setup(|app| {` 且未调用
 * install_panic_hook → 在该行后插入接线；已调用 → 跳过；无 setup 块 → guide 留人工。
 */
public func setupWiringOutcome(path: String): RuleOutcome {
    var o = RuleOutcome("R2-PORT-010", false, "", "", "")
    o.tier = T_AUTO
    var text = ""
    try {
        text = String.fromUtf8(File.readFrom(path))
    } catch (e: Exception) {
        let _ = e
        o.note = "读不到源文件——跳过"
        return o
    }
    if (text.contains("install_panic_hook(app)")) {
        o.note = "setup 已接线 install_panic_hook——跳过"
        return o
    }
    // 前置条件：009 必须已经把函数定义注入进去了。否则在这里插调用会得到
    // `cannot find function install_panic_hook` —— 工具把用户工程改坏，比不改更糟。
    if (!text.contains("fn install_panic_hook(")) {
        o.tier = T_GUIDE
        o.applied = false
        o.needsHuman = true
        o.note = "未找到 install_panic_hook 函数定义（R2-PORT-009 未落地）——接线留人工（模板见 after）"
        o.after = joinLines(setupWiringLines())
        return o
    }
    if (!text.contains(".setup(|app| {") && !text.contains(".setup(|app|{")) {
        o.tier = T_GUIDE
        o.applied = false
        o.needsHuman = true
        o.note = "未找到 .setup(|app| { 块——接线位置留人工（模板见 after）"
        o.after = joinLines(setupWiringLines())
        return o
    }
    let wiring = joinLines(setupWiringLines())
    o.applied = true
    o.before = ".setup(|app| {"
    o.after = wiring
    o.note = "setup 块内注入 panic hook + 沙箱目录接线（4 行）"
    return o
}

/** 在文本中执行 setup 接线插入：返回新文本；没找到插入点或已接线原样返回（幂等） */
public func applySetupWiring(text: String): String {
    // 幂等：已接线（二次 apply）不再插
    if (text.contains("install_panic_hook(app)")) {
        return text
    }
    let lines = text.split("\n", -1)
    var at = -1
    for (i in 0..lines.size) {
        let t = lines[i].trimAscii()
        if (t.startsWith(".setup(|app| {") || t.startsWith(".setup(|app|{")) {
            at = i
            break
        }
    }
    if (at < 0) {
        return text
    }
    var out = ArrayList<String>()
    var i: Int64 = 0
    while (i < lines.size) {
        out.add(lines[i])
        if (i == at) {
            for (l in setupWiringLines()) {
                out.add(l)
            }
        }
        i += 1
    }
    var sb = ""
    for (j in 0..out.size) {
        if (j > 0) {
            sb += "\n"
        }
        sb += out[j]
    }
    if (text.endsWith("\n") && !sb.endsWith("\n")) {
        sb += "\n"
    }
    return sb
}

/** 应用内对话框 JS（lingqu-dialog.js 全文；API 对齐 habit-tree 的 confirmDialog/promptDialog） */
public func dialogJsContent(): String {
    var s = ""
    s += "// === lingqu: R2-PORT-014 ===\n"
    s += "// 应用内对话框（Promise 化）：替代 ArkWeb 不支持的原生 confirm/prompt。\n"
    s += "// 引入：<script src=\"lingqu-dialog.js\"></script>（lingqu-dialog.css 同理）。\n"
    s += "// 替换调用点：if (confirm(x)) → if (await confirmDialog(x))（外层函数需 async）。\n"
    s += "(function () {\n"
    s += "  function ensureEl() {\n"
    s += "    var el = document.getElementById('lingqu-dialog');\n"
    s += "    if (el) return el;\n"
    s += "    el = document.createElement('div');\n"
    s += "    el.id = 'lingqu-dialog';\n"
    s += "    el.className = 'lq-dialog';\n"
    s += "    el.innerHTML = '<div class=\"lq-dialog-card\">'\n"
    s += "      + '<h3 class=\"lq-dialog-title\"></h3>'\n"
    s += "      + '<p class=\"lq-dialog-message\"></p>'\n"
    s += "      + '<input class=\"lq-dialog-input\" style=\"display:none\">'\n"
    s += "      + '<div class=\"lq-dialog-actions\">'\n"
    s += "      + '<button class=\"lq-btn lq-cancel\">取消</button>'\n"
    s += "      + '<button class=\"lq-btn lq-ok dialog-ok\">确定</button>'\n"
    s += "      + '</div></div>';\n"
    s += "    document.body.appendChild(el);\n"
    s += "    return el;\n"
    s += "  }\n"
    s += "  var resolver = null;\n"
    s += "  function openDialog(opts) {\n"
    s += "    var el = ensureEl();\n"
    s += "    el.querySelector('.lq-dialog-title').textContent = opts.title || '';\n"
    s += "    var msg = el.querySelector('.lq-dialog-message');\n"
    s += "    msg.textContent = opts.message || '';\n"
    s += "    msg.style.display = opts.message ? '' : 'none';\n"
    s += "    var input = el.querySelector('.lq-dialog-input');\n"
    s += "    var hasInput = opts.inputValue !== undefined || opts.inputPlaceholder !== undefined;\n"
    s += "    input.style.display = hasInput ? '' : 'none';\n"
    s += "    input.value = opts.inputValue || '';\n"
    s += "    var ok = el.querySelector('.lq-ok');\n"
    s += "    ok.textContent = opts.okText || '确定';\n"
    s += "    ok.classList.toggle('btn-error', opts.danger === true);\n"
    s += "    ok.classList.toggle('lq-primary', opts.danger !== true);\n"
    s += "    return new Promise(function (resolve) {\n"
    s += "      resolver = resolve;\n"
    s += "      el.classList.add('show');\n"
    s += "      if (hasInput) { input.focus(); input.select(); } else ok.focus();\n"
    s += "    });\n"
    s += "  }\n"
    s += "  window.lingquCloseDialog = function (v) {\n"
    s += "    var el = document.getElementById('lingqu-dialog');\n"
    s += "    if (!el) return;\n"
    s += "    el.classList.remove('show');\n"
    s += "    var r = resolver; resolver = null; if (r) r(v);\n"
    s += "  };\n"
    s += "  window.confirmDialog = function (message, okText, danger) {\n"
    s += "    return openDialog({ title: '确认', message: message, okText: okText || '确定', cancelText: '取消', danger: danger })\n"
    s += "      .then(function (v) { return v !== null; });\n"
    s += "  };\n"
    s += "  window.promptDialog = function (label, value, placeholder) {\n"
    s += "    return openDialog({ title: label, okText: '确定', cancelText: '取消', inputValue: value || '', inputPlaceholder: placeholder || '' });\n"
    s += "  };\n"
    s += "  document.addEventListener('click', function (ev) {\n"
    s += "    var el = document.getElementById('lingqu-dialog');\n"
    s += "    if (!el || !resolver) return;\n"
    s += "    if (ev.target.closest('.lq-ok')) { lingquCloseDialog(el.querySelector('.lq-dialog-input').value); }\n"
    s += "    else if (ev.target.closest('.lq-cancel')) { lingquCloseDialog(null); }\n"
    s += "  });\n"
    s += "})();\n"
    return s
}

/** 应用内对话框 CSS（lingqu-dialog.css 全文；单层 .dialog，深浅色跟随 CSS 变量） */
public func dialogCssContent(): String {
    var s = ""
    s += "/* === lingqu: R2-PORT-014 === */\n"
    s += "/* 应用内对话框样式：单层结构（ArkWeb 多层 .dialog 叠加渲染不稳，实测）。\n"
    s += "   颜色跟随页面既有 CSS 变量（--bg/--panel/--line/--fg/--err 等），无则回退。 */\n"
    s += ".lq-dialog { position: fixed; inset: 0; display: none; align-items: center; justify-content: center; background: rgba(0,0,0,.45); z-index: 80; }\n"
    s += ".lq-dialog.show { display: flex; }\n"
    s += ".lq-dialog-card { background: var(--panel, #fff); border: 1px solid var(--line, #ddd); border-radius: 12px; padding: 18px 20px; min-width: 280px; max-width: 86vw; color: var(--fg, #222); }\n"
    s += ".lq-dialog-title { margin: 0 0 8px; font-size: 16px; }\n"
    s += ".lq-dialog-message { margin: 0 0 12px; font-size: 14px; line-height: 1.6; }\n"
    s += ".lq-dialog-input { width: 100%; box-sizing: border-box; margin-bottom: 12px; padding: 8px 10px; border: 1px solid var(--line, #ddd); border-radius: 8px; background: var(--panel2, #f5f5f5); color: var(--fg, #222); }\n"
    s += ".lq-dialog-actions { display: flex; gap: 10px; justify-content: flex-end; }\n"
    s += ".lq-btn { padding: 7px 16px; border-radius: 8px; border: 1px solid var(--line, #ddd); background: transparent; color: var(--fg, #222); cursor: pointer; }\n"
    s += ".lq-primary { background: var(--acc, #4f6ef7); border-color: var(--acc, #4f6ef7); color: #fff; }\n"
    s += ".btn-error { background: var(--err, #c8372d); border-color: var(--err, #c8372d); color: #fff; }\n"
    return s
}

/**
 * 纯函数：port 阶段"前端目录"落在哪。
 *
 * 0.39.79 实测事故（rust-music-2 全流程）：经典布局里 `Cargo.toml` 在
 * `<工程>/src-tauri/`，所以前端目录 = `srcTauriDir/..`（= 工程根）是对的；
 * 但这个工程是**扁平布局**（`Cargo.toml` 就在工程根），`srcTauriDir/..` 于是
 * 指到了**工程外**的 `C:\Users\yang\lingqu-workspaces\`。后果有两个，都是静默的：
 *   ① `R2-PORT-014` 在父目录里撞见**另一个样本**遗留的 `lingqu-dialog.js`
 *      → 判「已存在——跳过」，本工程从此没有对话框模块；
 *   ② `R2-PORT-012` 的 before 证据里出现 `juCang/lingqu-dialog.js:4` ——
 *      跨工程证据污染，看落档的人会以为改的是别的工程。
 *
 * 判据：只有 `srcTauriDir == projPath`（扁平布局）才改口径，优先用
 * `tauri.conf.json` 的 `frontendDist`（rust-music-2 是 `ui`）；经典布局原样返回，
 * 不动已验证过的样本行为。
 */
public func frontendDirOf(projPath: String, srcTauriDir: String, frontendDist: String): String {
    if (srcTauriDir != projPath) {
        return "${srcTauriDir}/.."
    }
    var dist = frontendDist
    if (dist.startsWith("./")) {
        dist = dist[2..]
    }
    // 只接相对路径：绝对路径 / 带盘符的写法原样返回工程根，绝不拼到工程外
    let isAbsolute = dist.startsWith("/") || dist.contains(":") || dist.startsWith("..")
    if (dist != "" && !isAbsolute) {
        return "${projPath}/${dist}"
    }
    return projPath
}

/**
 * R2-PORT-014：对话框资源生成（两个文件落盘，资源存在则跳过）。
 * 只生成模块，调用点替换归 012 guide。
 */
public func dialogAssetsOutcome(frontendDir: String): ArrayList<RuleOutcome> {
    let out = ArrayList<RuleOutcome>()
    let jsPath = "${frontendDir}/lingqu-dialog.js"
    let cssPath = "${frontendDir}/lingqu-dialog.css"
    var o = RuleOutcome("R2-PORT-014", false, "", "", dialogJsContent() + "\n---\n" + dialogCssContent())
    o.tier = T_AUTO
    if (fileContains(jsPath, "confirmDialog") || fileContains(cssPath, "lq-dialog")) {
        o.note = "lingqu-dialog.js/.css 已存在——跳过"
    } else {
        o.applied = true
        o.note = "生成 lingqu-dialog.js/.css（引入后按 012 的方案替换调用点）"
    }
    out.add(o)
    return out
}
