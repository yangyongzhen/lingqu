package lingqu.port

import std.collection.*
import std.fs.*

/*
 * R2-PORT-015：中性化 `gen/ohos/entry/hvigorfile.ts` 里的 tauri Rust 构建钩子（0.39.53）。
 *
 * 现场（2026-11-01 juCang）：`t2h:hap` 跑到 hvigor 报 `00308018 Unknown Error`，日志里真正的 trace 是
 *
 *     thread 'main' panicked: failed to read missing addr file %TEMP%\com.dicing.jucang-server-addr
 *     Command failed: cargo tauri ohos dev-eco-studio-script --target aarch64
 *
 * 也就是 `hvigorfile.ts` 里的 `tauriPlugin` 在 `default@ConfigureCmake.afterRun` 挂了
 * `cargo tauri ohos dev-eco-studio-script`——**那条脚本是给 `tauri ohos dev` 用的**，
 * 它要读 dev server 写下的 addr 文件；我们不是 dev 场景，文件不存在，tauri-cli 直接 panic。
 *
 * 与签名、与业务代码都无关。而本工具的 `t2h:hap` 已经负责把 `lib<模块>.so` 装配进
 * `libs/arm64-v8a`（§4-45），根本不需要这条钩子去编 Rust ⇒ 把它注掉即可。
 *
 * 纪律：
 *   ① 只改**一行**（`.afterRun(buildRustCode)`），保留文件其余结构与 `tauriPlugin` 的定义——
 *      一旦哪天真要用 dev 流程，把它注回来就行；
 *   ② 幂等：带 `lingqu: R2-PORT-015` 标记就跳过；
 *   ③ 不确定就不动：文件里没有 `dev-eco-studio-script` 时**不判命中**（别把别人工程的钩子按我们的规矩改）。
 */

/** 幂等标记（写进被注掉的那一行上方；revert 与二次运行都靠它判定） */
public let HVIGOR_HOOK_MARKER: String = "lingqu: R2-PORT-015"

/** 这条 r 的 id（与 diagnose/报告里出现的名字保持一处） */
public let HVIGOR_HOOK_RULE_ID: String = "R2-PORT-015"

/**
 * 纯函数：把这个 hvigorfile 里的 tauri Rust 钩子注掉（幂等）。
 *
 * 输入输出都是**整份文件文本**：没命中就原样返回（调用方据 `changed` 决定写不写）。
 */
public class HvigorHookFix {
    public var changed: Bool = false
    public var text: String = ""
    public var note: String = ""

    public init() {}
}

/** 找到 `.afterRun(` 那一行的行号（没有返回 -1）。逐行扫，避免正则。 */
func afterRunLineIndex(lines: ArrayList<String>): Int64 {
    var i: Int64 = 0
    while (i < Int64(lines.size)) {
        if (lines[i].contains(".afterRun(")) {
            return i
        }
        i += 1
    }
    return -1
}

/**
 * 纯函数：中性化 hvigorfile 里的 tauri 钩子（0.39.53）。
 *
 * 返回 `changed=false` 表示"不该动"或"已经动过"：
 *   · 没有 `dev-eco-studio-script` → 不是这类钩子，原样返回（note 说明不适用）；
 *   · 已经有 `lingqu: R2-PORT-015` 标记 → 幂等跳过；
 *   · 找不到 `.afterRun(` 那一行 → 不猜，原样返回并说明。
 */
public func neutralizeHvigorHook(text: String): HvigorHookFix {
    let fix = HvigorHookFix()
    fix.text = text
    if (!text.contains("dev-eco-studio-script")) {
        fix.note = "这个 hvigorfile 里没有 `cargo tauri ohos dev-eco-studio-script` 钩子——不适用"
        return fix
    }
    if (text.contains(HVIGOR_HOOK_MARKER)) {
        fix.note = "已经注过了（有 ${HVIGOR_HOOK_MARKER} 标记）——跳过"
        return fix
    }
    let lines = ArrayList<String>()
    for (l in text.split("\n", -1)) {
        lines.add(l)
    }
    let idx = afterRunLineIndex(lines)
    if (idx < 0) {
        fix.note = "找到 dev-eco-studio-script，但没找到 `.afterRun(` 那一行——不猜，保持原样"
        return fix
    }
    let out = ArrayList<String>()
    var i: Int64 = 0
    while (i < Int64(lines.size)) {
        if (i == idx) {
            let indent = leadingIndentOf(lines[i])
            out.add("${indent}// ${HVIGOR_HOOK_MARKER} 注掉 tauri 的 Rust 构建钩子：它跑")
            out.add("${indent}//   `cargo tauri ohos dev-eco-studio-script`，要读 dev server 的 addr 文件")
            out.add("${indent}//   （%TEMP%\\<包名>-server-addr），非 dev 场景必然 panic → hvigor 00308018。")
            out.add("${indent}//   本工程的 lib<模块>.so 由迁移台 t2h:hap 装配进 libs/arm64-v8a。")
            out.add("${indent}// ${lines[i].trimAscii()}")
        } else {
            out.add(lines[i])
        }
        i += 1
    }
    fix.text = joinLines(out)
    fix.changed = true
    fix.note = "注掉 hvigorfile 里的 tauri Rust 钩子（原本会跑 cargo tauri ohos dev-eco-studio-script 并 panic）"
    return fix
}

/**
 * R2-PORT-015 的产出（与其它规则同一形状，供 `t2h:port` 汇总）。
 *
 * `after` 是**整份文件的新内容**——命令层命中 `applied=true` 时备份原文件再整份写回（同 R2-PORT-011 的做法）。
 */
public func hvigorHookOutcome(hvigorFilePath: String): RuleOutcome {
    var o = RuleOutcome(HVIGOR_HOOK_RULE_ID, false, "", "", "")
    o.tier = T_AUTO
    if (!exists(Path(hvigorFilePath))) {
        // 工程还没生成 gen/ohos（没跑过 DevEco）——不是失败，也不该假装改过
        o.note = "没有 ${hvigorFilePath}（工程还没生成 ohos 工程）——跳过"
        return o
    }
    var text = ""
    try {
        text = String.fromUtf8(File.readFrom(hvigorFilePath))
    } catch (e: Exception) {
        o.note = "读 ${hvigorFilePath} 失败：${e}"
        return o
    }
    let fix = neutralizeHvigorHook(text)
    o.note = fix.note
    o.applied = fix.changed
    o.before = if (fix.changed) { text } else { "" }
    o.after = if (fix.changed) { fix.text } else { "" }
    return o
}
