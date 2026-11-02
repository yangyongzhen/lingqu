package lingqu

import std.collection.*
import std.fs.*

/*
 * 「从头重跑」的归档层（0.39.64，用户实测提出：「点 AI 一键迁移怎么直接完成了？那我没办法重新跑一遍吗？」）。
 *
 * 起因：判定只认落档（`observeTaskStep` / `collectTaskBoard` 每次都按盘上的 `.lingqu/` 重新观测）。
 * 一个工程只要跑过一轮，8 步落档就在那儿；再点「AI 一键迁移」，agent 一上手 `resume` 就看见
 * "8/8 有结论"，于是它当然没有活可干——表现就是"点一下就完成了"。这不是 bug，是"落档说了算"的必然结果。
 *
 * 所以"重跑"的正确定义是：**把上一轮的落档挪到档案目录**（不是删、不是假装没跑过），
 * 让观测重新从零开始。三条纪律：
 *   ① **只搬灵渠自己的落档**（8 个步骤目录 + report + tasks.json），工程源码、`.lingqu/notes`
 *      （经验）、`.lingqu/diagnose`（未命中台账）、`evidence`（截图）一律不动——
 *      经验是飞轮的输入，不能被一次"重跑"顺手清掉；
 *   ② **搬走而不是删除**：档案目录 `.lingqu/_archive-<时间戳>/` 可回退，事后能对账；
 *   ③ 判据是**产物真的挪过去了**（新旧路径都查），不是"rename 没抛异常"（D-013 静默失败零容忍）。
 */

/** 一键迁移的 8 个步骤目录 + 报告目录（就是断点板/报告读的那几份落档） */
public let RESET_STEP_DIRS: Array<String> = [
    "scan", "deps", "port", "build", "hap", "sign", "deploy", "verify", "report"
]

/** 断点板本身（跟着工程走的那份 tasks.json） */
public let RESET_BOARD_FILES: Array<String> = ["tasks.json", "tasks.json.bak"]

/** 档案目录前缀：`.lingqu/_archive-<时间戳>`（用 `_` 开头，与步骤目录区分，重跑时不会被再挑中） */
public let RESET_ARCHIVE_PREFIX: String = "_archive-"

/**
 * 纯函数：档案目录名（时间戳里的非法字符换成 `-`；空串给一个兜底名）。
 *
 * 时间戳来自 `nowText()`，形如 `2026-11-02T22:24:26.077+08:00`，含 `:` 与 `+`，
 * Windows 路径里都非法 —— 必须净化（§4-26 同族：落档路径非法会静默丢证据）。
 */
public func archiveDirNameOf(stamp: String): String {
    // ⚠ 别用 StringBuilder 拼字节：`append(Byte)` 会按**十进制整数**输出（"45" 而不是 "-"），
    // 这是仓颉的老坑（AGENTS §4-62 / §4-116）。攒 ArrayList<Byte> 最后整体解一次才对，
    // 中文/非 ASCII 的路径才不会坏——本函数第一个版本正是栽在这里（单测当场抓出）。
    let dash: Byte = 45
    var bytes = ArrayList<Byte>()
    for (b in RESET_ARCHIVE_PREFIX.toArray()) {
        bytes.add(b)
    }
    var n: Int64 = 0
    for (b in stamp.toArray()) {
        let bad = b == 58 || b == 43 || b == 47 || b == 92 || b == 32 || b == 84 // : + / \ 空格 T
        bytes.add(if (bad) { dash } else { b })
        n += 1
    }
    if (n <= 2) {
        return RESET_ARCHIVE_PREFIX + "manual"
    }
    return String.fromUtf8(bytes.toArray())
}

/**
 * 纯函数：从 `.lingqu` 的顶层条目里挑出**该搬走的**（按白名单，其余一律不动）。
 *
 * 白名单 = 9 个步骤目录 + `tasks.json(.bak)`；已经在档案目录里的（`_archive-` 前缀）不再入选，
 * 免得"连搬两次"把上一份档案套进新档案里。
 */
public func resetTargetsOf(entries: Array<String>): Array<String> {
    let out = ArrayList<String>()
    for (e in entries) {
        if (e.startsWith(RESET_ARCHIVE_PREFIX)) {
            continue
        }
        var hit = false
        for (d in RESET_STEP_DIRS) {
            if (e == d) {
                hit = true
                break
            }
        }
        if (!hit) {
            for (f in RESET_BOARD_FILES) {
                if (e == f) {
                    hit = true
                    break
                }
            }
        }
        if (hit) {
            out.add(e)
        }
    }
    return out.toArray()
}

/** 归档结果（回投给界面：搬了哪些、搬到哪、哪几条失败） */
public class ResetRecordsResult {
    public var ok: Bool = false
    public var archiveDir: String = ""
    public var moved: ArrayList<String> = ArrayList<String>()
    public var failed: ArrayList<String> = ArrayList<String>()
    public var error: String = ""

    public init() {}
}

/**
 * 动作层：把该工程的迁移落档搬进 `.lingqu/_archive-<时间戳>/`。
 *
 * @return 结果对象（`moved` 为空且无 `error` = 本来就没有落档，视作成功且幂等）
 */
public func archiveMigrateRecords(projPath: String, stamp: String): ResetRecordsResult {
    let r = ResetRecordsResult()
    let lq = lqDirOf(projPath)
    if (lq.size == 0) {
        r.error = "拿不到工程的 .lingqu 目录（工程路径为空？）"
        return r
    }
    if (!exists(Path(lq))) {
        // 还没跑过：没有可归档的，直接算成功（重跑本来就该从头开始）
        r.ok = true
        return r
    }
    var entries = ArrayList<String>()
    try {
        for (info in Directory.readFrom(Path(lq))) {
            entries.add(info.name)
        }
    } catch (e: Exception) {
        r.error = "读 ${lq} 失败：${e}"
        return r
    }
    let targets = resetTargetsOf(entries.toArray())
    if (targets.size == 0) {
        r.ok = true
        return r
    }
    let archive = lq + cjhPathSep() + archiveDirNameOf(stamp)
    try {
        if (!exists(Path(archive))) {
            Directory.create(Path(archive), recursive: true)
        }
    } catch (e: Exception) {
        r.error = "建档案目录失败：${archive}（${e}）"
        return r
    }
    for (t in targets) {
        let from = lq + cjhPathSep() + t
        let to = archive + cjhPathSep() + t
        try {
            // rename 的两个端点都是**命名参数**（from: / to:，见 std.fs）；目标已存在就先清掉，
            // 免得同名档案（同一时间戳）撞上导致整条归档失败
            if (exists(Path(to))) {
                removeIfExists(to, recursive: true)
            }
            rename(Path(from), to: Path(to))
        } catch (e: Exception) {
            r.failed.add(t)
            eprintln("[lingqu][reset] 搬不动 ${from} → ${to}：${e}")
        }
    }
    r.archiveDir = archive
    // 判据是**产物真的挪过去了**：源不在、目标在，才算搬成功（不要只看 rename 有没有抛异常）
    for (t in targets) {
        let from = lq + cjhPathSep() + t
        let to = archive + cjhPathSep() + t
        if (!exists(Path(from)) && exists(Path(to))) {
            r.moved.add(t)
        } else if (!r.failed.contains(t)) {
            r.failed.add(t)
        }
    }
    r.ok = r.failed.isEmpty() && r.archiveDir.size > 0
    if (!r.ok && r.error.size == 0) {
        r.error = "有 ${r.failed.size} 项没搬成功（详见日志）"
    }
    return r
}
