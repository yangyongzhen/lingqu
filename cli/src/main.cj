package lingqu_cli

import lingqu.*

/*
 * lingqu-cli —— 灵渠迁移台的命令行入口（AI 接入计划第 3 步）。
 *
 * 存在的唯一理由：`t2h:*` 原先只有应用内 IPC 入口，**agent 的 bash 调不到**。
 * 有了这个可执行文件，AI 就能真的跑扫描/编译/装配/部署，而不是只会"讲"。
 *
 * 与界面**同一份实现**（直接调 `CommandHandler`），所以行为永远一致；
 * CLI 只多做三件事：解析 argv、打印结果 JSON、按 `ok` 定退出码。
 *
 * 参数约定（对齐 cjh 的做法）：`main(args)` 里 args **不含**可执行文件名。
 */

main(args: Array<String>): Int64 {
    // 无参数 → 打用法并按失败退出（让人知道该怎么用）
    if (args.size == 0) {
        out(cliUsage())
        return 1
    }
    if (hasFlag(args, "--help") || hasFlag(args, "-h") || hasFlag(args, "--list")) {
        out(cliUsage())
        return 0
    }
    let r = dispatchCli(args)
    if (r.error != "") {
        err(r.error)
    }
    if (r.json != "") {
        out(r.json)
    }
    return r.exitCode
}

/** argv 里有没有某个开关（`--k` 与 `--k=v` 两种形态都认） */
func hasFlag(argv: Array<String>, flag: String): Bool {
    for (a in argv) {
        if (a == flag || a.startsWith(flag + "=")) {
            return true
        }
    }
    return false
}

/** 写 stdout（内容自带换行就不补，避免多空行） */
func out(s: String): Unit {
    print(s)
    if (!s.endsWith("\n")) {
        println()
    }
}

/** 写 stderr（去掉尾部空白，别在终端里刷屏） */
func err(s: String): Unit {
    let t = s.trimAscii()
    if (t != "") {
        eprintln(t)
    }
}
