package lingqu

import std.fs.*

/*
 * 落档位置（0.38.0）：**跟着工程走**。
 *
 * 背景：以前所有落档都是相对 CWD 的 `.lingqu/...`，于是出现两套真相——
 *   · 界面/命令跑出来的落档在**灵渠应用目录**（`<lingqu>/.lingqu/`）
 *   · 而 agent（cjh）的 cwd 是**目标工程**（`<project>/`），它看不见落档
 *   · 我们注入的 AGENTS.md 却写"落在本工程的 `.lingqu/` 下"——**与事实不符**
 *     （agent 已实测指出：'`.lingqu/` 里只有任务书本身，没有任何落档 JSON'）
 *
 * 目标：落档落在 `<工程>/.lingqu/`，工程自包含（换机器/换会话都能自证），
 * agent 与界面看**同一份**落档——这是让 AI 能自己判断"下一步做什么"的前提。
 *
 * 迁移纪律（**别一把梭**）：
 *   ① 先加这层的三个函数（本文件），不动任何命令；
 *   ② 一个命令一个命令地把写侧切到 `lqDirOf/lqPathOf`，每切一个跑一次门禁；
 *   ③ 读侧一律用 `resolveLqPath`（**工程优先、CWD 兜底**），旧落档不会失效；
 *   ④ 全切完再改 AGENTS.md 文案，最后删掉兜底。
 */

/** 去掉开头的分隔符（`/x`、`\x` → `x`；用于拼相对落档路径） */
func stripLeadSep(rel: String): String {
    var r = rel.trimAscii()
    while (r.size > 0 && (r.startsWith("/") || r.startsWith("\\"))) {
        r = r[1..r.size]
    }
    return r
}

/**
 * 工程的落档根目录：`<工程>/.lingqu`。
 *
 * 工程路径为空/`"."` → 退回 `.lingqu`（保持旧行为，给"没有工程上下文"的调用方用）。
 * 末尾分隔符会被吃掉，避免拼出 `x//.lingqu`。
 */
public func lqDirOf(projectPath: String): String {
    let p = hostPath(projectPath.trimAscii())
    if (p.size == 0 || p == ".") {
        return ".lingqu"
    }
    var base = p
    if (base.endsWith("/") || base.endsWith("\\")) {
        base = base[0..(base.size - 1)]
    }
    return base + cjhPathSep() + ".lingqu"
}

/** 工程里的落档路径：`<工程>/.lingqu/<rel>`（`rel` 形如 `scan/habit-tree.json`） */
public func lqPathOf(projectPath: String, rel: String): String {
    return lqDirOf(projectPath) + cjhPathSep() + stripLeadSep(rel)
}

/**
 * 读侧双查：**工程优先 → CWD 兜底**（`.lingqu/<rel>`）。
 *
 * 两个都没有时，若有工程路径就回"应该写在那里"的新路径（让报错指向正确位置），
 * 否则回旧的相对路径。这样迁移期间新旧落档都能读到，不会因为切换而丢证据。
 */
public func resolveLqPath(projectPath: String, rel: String): String {
    let r = stripLeadSep(rel)
    let hasProject = projectPath.trimAscii().size > 0
    if (hasProject) {
        let inProject = lqPathOf(projectPath, r)
        if (exists(Path(inProject))) {
            return inProject
        }
    }
    let legacy = lqPathOf("", r)
    if (exists(Path(legacy))) {
        return legacy
    }
    if (hasProject) {
        return lqPathOf(projectPath, r)
    }
    return legacy
}

/** 落档是不是落在工程里（`resolveLqPath` 的结果是不是新位置）——报告里用来标注口径 */
public func lqIsProjectScoped(path: String, projectPath: String): Bool {
    if (projectPath.trimAscii().size == 0 || path.size == 0) {
        return false
    }
    return path.startsWith(lqDirOf(projectPath))
}
