package lingqu

import std.collection.*

/*
 * AI 自动迁移（0.37.0）——**这是本项目的正题**，0.36.0 的「一键迁移」只是它的兜底通道。
 *
 * 两者的区别必须记牢（做反了就是把 AI 降级成"失败后给建议的顾问"）：
 *
 *   · 0.36.0 一键迁移 = **确定性流水线**：我们按固定顺序跑 8 个命令，失败就把现场问一次 AI，
 *     AI 只出建议、命令还得人来点。AI 在**边缘**。
 *   · 0.37.0 AI 自动迁移 = **agent 主循环**：目标与工具箱交给 cjh，它自己读落档、自己改代码、
 *     自己重跑，卡住了才找人。AI 在**中心**，我们是它的眼睛（落档）、手刹（预算/停止）与
 *     记录员（人工介入次数 = 验收指标 A3）。
 *
 * 所以本文件只产出三样东西（都是纯函数，可单测）：
 *   ① `buildAutoPortDirective` —— 任务书：目标 / 工具箱 / 工作循环 / 纪律 / 预算 / 何时升级给人
 *   ② `isStalled` —— 停滞判定：连续 N 次快照一模一样 → 它绕圈了，叫停比继续烧钱好
 *   ③ `autoportVerdict` / `escalationLine` —— 结论与"要人做什么"的一句话
 *
 * 判定依旧只认落档（`observeTaskStep`）：AI 说"迁好了"不算，`.lingqu/` 里写着才算。
 */

/** 默认轮次预算：够"读落档 → 改码 → 重跑"迭代十几次，又不至于失控烧钱 */
public let AUTOPORT_MAX_ITERATIONS: Int64 = 40

/** 默认时间预算（分钟）：到点就让 AI 收尾总结，别无限挂着 */
public let AUTOPORT_MAX_MINUTES: Int64 = 40

/**
 * 停滞判定阈值：连续多少次轮询快照完全一样就认为绕圈
 *
 * 轮询间隔 900ms，所以 6 次 ≈ 5.4 秒——比一次 LLM 思考（5–30 秒）还短。
 * 0.39.7 实测因此反复误报（agent 只是在一个长工具/一次长思考里）。
 * 20 次 ≈ 18 秒：仍能抓住"真绕圈"，但不会在正常停顿上叫停。
 */
public let AUTOPORT_STALL_POLLS: Int64 = 20

/** 一次 AI 自动迁移的输入（命令层填，纯函数只读） */
public class AutoPortInput {
    public var project: String = ""
    public var projectDir: String = ""
    /** `lingqu-cli` 的绝对路径（找不到给空串——任务书会退化到"用 lingqu-cli 命令名试"） */
    public var cliPath: String = ""
    /** 真机在不在线：决定它要不要跑 deploy/verify */
    public var device: Bool = false
    public var budget: Int64 = AUTOPORT_MAX_ITERATIONS
    public var minutes: Int64 = AUTOPORT_MAX_MINUTES
    /** 当前落档一句话一行（"扫描分析｜通过｜R=24…"），让 AI 一上手就知道从哪继续 */
    public var stateLines: String = ""
    /**
     * 作用域：`all` = 一键迁移（全自动，一路干到 verify）；
     * 其它 = 半自动（只干那一步，做完停下等人点下一步）——左侧各屏的「🤖 交给 AI」走这个。
     */
    public var scope: String = "all"

    public init() {}
}

/**
 * 任务书**落盘**后的开工信（纯函数，保持短消息）。
 *
 * 为什么要落文件而不是整段发过去（0.37.2 实测）：4.4 KB 的任务书单帧发过去，cjh 静默不处理
 * （`wsFrameTypes` 只有 `history_messages:1`，会话里也没有这条 user 消息）；同一状态下 9 个字的
 * 短句完全正常（`frames=5 / delta:2 / done:2`）。所以改成：
 *   ① 任务书写进**目标工程**的 `.lingqu/autoport-directive.md`（agent 的 cwd 就在那，它有 read 工具）
 *   ② 只发一条短 kickoff，让它自己去读
 * 这样对任何单帧长度上限都免疫，也符合 agent 的工作习惯（读文件比读长消息更可靠）。
 *
 * 纪律：这条 kickoff 必须**短**（<300 字），否则等于把问题搬回去——有单测钉住。
 */
public func buildAutoPortKickoff(directivePath: String): String {
    return "【灵渠 · 开工】迁移任务书已写入：`${directivePath}`（范围、工具箱、纪律、预算、收尾条件都在里面）。\n" +
        "第一步：用 read 工具把这个文件读完，然后照它开工——先跑 `resume` 看落档停在哪一步，再动手。\n" +
        "注意：只看落档判定，不要问我确认。"
}

/** 作用域的中文标题（界面按钮、任务书标题共用一份，别各写各的） */public func autoPortScopeTitle(scope: String): String {
    if (scope == "port") {
        return "规则改造"
    }
    if (scope == "deps") {
        return "依赖评估"
    }
    if (scope == "build") {
        return "交叉编译"
    }
    if (scope == "hap") {
        return "HAP 装配"
    }
    if (scope == "sign") {
        return "签名体检"
    }
    if (scope == "deploy") {
        return "真机部署"
    }
    if (scope == "verify") {
        return "真机验证"
    }
    return "全流程"
}

/** 是不是全自动（`all` 或缺省），界面据此显示"一路干到验证"还是"只干这一步" */
public func isFullScope(scope: String): Bool {
    return scope == "" || scope == "all"
}

/**
 * 指定这一步的**收尾条件**（纯函数）。
 *
 * 半自动的关键：**做完就停**，不替人决定下一步——否则"只让它改改造"会变成它顺手把
 * build/hap/deploy 都跑了，人反而失去了"逐步确认"的意义。
 */
public func autoPortScopeGoal(scope: String): String {
    if (scope == "port") {
        return "- 先读 `.lingqu/scan/<工程>.json` 与 `.lingqu/deps/<工程>.json`，弄清这工程要改什么；\n" +
            "- 规则引擎能覆盖的先跑 `port --path . --apply`（幂等、留 .bak）；\n" +
            "- 规则覆盖不到的（wry/tao 差异、平台条件代码、前端 ArkWeb 兼容层）**你改代码**；\n" +
            "- 改完用 `build --path .` 验证编得过；\n" +
            "- **做完停下**，报告：改了哪些文件、按哪条依据、哪些留给人决定。"
    }
    if (scope == "deps") {
        return "- 读 `.lingqu/deps/<工程>.json`，把\"需 patch\"和\"不可用\"分开；\n" +
            "- 能 patch 的直接写进 `Cargo.toml` 的 `[patch.*]`（钉精确版本）；\n" +
            "- 不可用的给出替代 crate 或平台限制登记建议；\n" +
            "- **做完停下**，逐条说明理由（人工决策点用 lingqu-decision 块）。"
    }
    if (scope == "build") {
        return "- 跑 `build --path .`，读 JSONL 诊断与 stderr；\n" +
            "- 改代码/改依赖/改工具链，重跑，直到 `exitCode=0` 且 `gates.passed`；\n" +
            "- 同一错误最多试 2 种修法；\n" +
            "- **做完停下**，报告最终 exit 与改动清单。"
    }
    if (scope == "hap") {
        return "- 跑 `hap --path .`，读 `entries`（arm64 库、rawfile 死资源）与 `gates.failures`；\n" +
            "- 修装配问题（白名单、资源、`lib<模块名>.so`）；\n" +
            "- **做完停下**，报告 HAP 大小与闸结果。"
    }
    if (scope == "sign") {
        return "- 跑 `sign --path .` 体检，读 `mode`（debug/release）与 UDID 绑定情况；\n" +
            "- 需要写回 signingConfigs 时先说明理由再 `--apply`（会备份原文件）；\n" +
            "- **别把 release 态装不上真机当成 bug 去修**；\n" +
            "- **做完停下**，给出上架前还差什么。"
    }
    if (scope == "deploy" || scope == "verify") {
        return "- 只有真机在线才做；先看 `sign` 落档的签名态；\n" +
            "- 跑那一步，把 hdc 原文关键行贴出来；\n" +
            "- **做完停下**，报告装/启/hilog 或功能清单结果。"
    }
    return ""
}

/**
 * 迁移任务书（纯函数）。
 *
 * 写这份文本有三个"必须"：
 *   ① 必须说清**它是执行者不是顾问** —— 否则模型会给建议然后停下等确认（0.36.0 就是这么退化的）
 *   ② 必须给**可复制的工具路径** —— 它跑不动 `lingqu-cli` 时整条循环就断了
 *   ③ 必须给**纪律与预算** —— 平台限制不算失败、未验证不算通过、同样错误最多两个修法
 */
public func buildAutoPortDirective(inp: AutoPortInput): String {
    let budget = if (inp.budget > 0) { inp.budget } else { AUTOPORT_MAX_ITERATIONS }
    let minutes = if (inp.minutes > 0) { inp.minutes } else { AUTOPORT_MAX_MINUTES }
    let full = isFullScope(inp.scope)
    let title = autoPortScopeTitle(inp.scope)
    var d = "【灵渠 · AI 自动迁移任务书】"
    if (full) {
        d += "（全流程）\n\n"
    } else {
        d += "（半自动：只做「${title}」这一步）\n\n"
    }
    d += "工程：`${inp.project}`　目录：`${inp.projectDir}`（你的工作目录就是这里）\n\n"
    d += "**你是这次迁移的执行者，不是顾问。** 自己读落档、自己改代码、自己重跑工具，"
    d += "直到落档证明迁完；不要输出\"建议你执行…\"然后停下等人。\n"
    d += "人只在你明确要求时才介入——每次介入都算一次人工干预，验收指标是 **≤5 次/应用**。\n\n"

    d += "## 工具箱（在 bash 里直接调用；每条命令都会打印 JSON 并把结果落到 `.lingqu/`）\n"
    if (inp.cliPath.size > 0) {
        d += "```bash\n" + inp.cliPath + " resume --path .     # 先看停在哪一步\n" +
            inp.cliPath + " scan   --path .     # 扫描画像\n" +
            inp.cliPath + " deps   --path .     # 依赖矩阵\n" +
            inp.cliPath + " port   --path . --apply   # 规则改造（会改源码，逐文件留 .bak，可回滚）\n" +
            inp.cliPath + " build  --path .     # 交叉编译（--verifyOnly 只比前端指纹）\n" +
            inp.cliPath + " hap    --path .     # 装配 HAP\n" +
            inp.cliPath + " sign   --path .     # 签名体检（--apply 写回 signingConfigs）\n" +
            inp.cliPath + " deploy --path .     # 真机装启 + hilog\n" +
            inp.cliPath + " verify --path .     # 采证 + 功能清单 + 可用率\n" +
            inp.cliPath + " report --path .     # 三段式报告\n```\n"
        d += "（路径里有空格就整条用双引号括起来。）\n"
    } else {
        d += "```bash\nlingqu-cli resume --path .\nlingqu-cli scan --path .\n```\n"
        d += "（`lingqu-cli` 不在 PATH 里的话，让应用帮你定位，或直接读 `.lingqu/` 落档做判断。）\n"
    }
    d += "\n**判断只认落档**：`.lingqu/<步骤>/<工程>.json` 里的判定字段才算数，退出码为 0 不等于通过。\n"
    d += "日志在 `.lingqu/<步骤>/<工程>.log`；失败先读它的最后 40 行，再动手。\n\n"

    d += "## 工作循环（照顺序做，别跳步、别重复跑已通过的步骤）\n"
    d += "1. `resume` 定位当前步骤；\n"
    d += "2. 跑那一步 → 读落档与日志 → 判定过没过；\n"
    d += "3. **没过就你动手修**：Cargo.toml、Rust 源码、前端、`src-tauri/gen/ohos` 的配置都算你的活；"
    d += "改完重跑那一步；\n"
    d += "4. 同一个失败**最多试 2 种不同修法**，还不过就换思路，或升级给人；\n"
    d += "5. 循环到 `verify` 落档，或用完预算。\n\n"

    if (inp.stateLines.size > 0) {
        d += "## 当前落档（灵渠刚读的，别重复造）\n```text\n${inp.stateLines}\n```\n\n"
    }
    if (!full) {
        // 半自动：把范围与收尾条件写清楚——做完就停，不替人决定下一步
        d += "## 本次范围：**只做「${title}」这一步**\n"
        d += autoPortScopeGoal(inp.scope) + "\n"
        d += "**做完就停**：不要顺手把后面的步骤也做了，下一步由人点。\n\n"
    }
    d += "## 真机：" + (if (inp.device) { "在线 —— `deploy` / `verify` 要跑，装不上先看签名态\n" }
        else { "**不在线** —— 跳过 deploy/verify（落档会是\"未跑\"，如实报告即可，别当成失败）\n" }) + "\n"

    d += "## 纪律（说错一句就露馅）\n"
    d += "- **平台限制 ≠ 失败**：鸿蒙没有的能力登记为限制，不算 bug，更不许写\"已修复\"；\n"
    d += "- **未验证 ≠ 通过**：没证据的项写 unknown；\n"
    d += "- 改代码前先 `git status` 看看工作区；**别动与迁移无关的文件**；\n"
    d += "- 真机装不上先看 `.lingqu/sign/<工程>.json` 的签名态：release 态装不上（9568322）是正常的，别去修；\n"
    d += "- 不确定就先用 `git stash` 或用我们 `.lingqu` 里的备份兜底，再重试。\n\n"

    d += "## 交叉编译的硬前置（缺了必然失败）\n"
    d += "- 交叉编译依赖工程里的 `src-tauri/.cargo/config.toml` 两段：\n"
    d += "  ① `[target.aarch64-unknown-linux-ohos]` 的 linker / ar / rustflags；\n"
    d += "  ② **`[env]` 段的 `CC_aarch64_unknown_linux_ohos` / `AR_…` / `CFLAGS_…`** —— "
    d += "ring、openssl 这类**含 C 代码**的依赖靠它找到 NDK clang。\n"
    d += "- 缺 ② 的症状：`cc-rs: command did not execute successfully: \"cc\" … "
    d += "--target=aarch64-unknown-linux-ohos`（0.39.7 实测：`ring` 的 curve25519.c 编译失败，build 落档 exitCode=101）。\n"
    d += "- 看到这条错**先查 `.cargo/config.toml` 的 `[env]` 段**，不要改 Rust 源码；"
    d += "`t2h:port` 的 R2-PORT-008 在缺段时会给出要追加的片段。\n"
    d += "- 回滚改造时别只回滚 `Cargo.toml`：`.cargo/config.toml` 与 `rust-toolchain.toml` 是交叉编译的地基，"
    d += "把它们回滚掉等于把 build 打回失败态。\n\n"

    d += "## 预算与收尾\n"
    d += "- 最多 ${budget} 轮工具调用、约 ${minutes} 分钟；到上限就收尾，别硬撑；\n"
    d += "- **每完成一步用一行报进度**：`[步骤] 通过/未过 ｜ 一句话`；\n"
    d += "- 收尾分三段、每段不超过 3 行：**做了什么 / 没做什么 / 需要你做什么**；\n"
    d += "- 需要人拍板的（要不要 patch 某依赖、签名走 debug 还是 release、要不要装某 SDK）："
    d += "用 `lingqu-decision` 代码块写，块里一行 JSON `{\"rule\":\"…\",\"decision\":\"accepted|ignored\",\"why\":\"…\"}`，"
    d += "界面会渲染成确认卡；\n"
    d += "- 现在开始：先跑 `resume`，然后按上面的循环干活，不要等我确认。\n"
    return d
}

/**
 * 停滞判定（纯函数）：最近 [window] 次快照是否**完全一样**。
 *
 * 为什么要它：agent 绕圈是真实风险（同一个错改两遍又改回去）。落档不动 = 它没在推进，
 * 这时候叫停、让它总结、把主动权交回人，比继续烧 token 好。
 * 空历史/样本不足 → false（**不许**把"刚开始"误判成卡住）。
 */
public func isStalled(history: ArrayList<String>, window: Int64): Bool {
    if (window <= 1) {
        return false
    }
    if (Int64(history.size) < window) {
        return false
    }
    let first = history[0]
    if (first.size == 0) {
        return false
    }
    for (h in history) {
        if (h != first) {
            return false
        }
    }
    return true
}

/** 快照签名：把 8 步的 (步骤, 在不在, 过没过, 摘要) 压成一行，用于停滞比较 */
public func autoportSnapshot(rows: ArrayList<MigrateRow>): String {
    return autoportSnapshotWith(rows, -1)
}

/**
 * 快照签名 + **agent 活动量**（0.39.8）
 *
 * 为什么必须带上 agent 活动：0.39.7 端到端实测，agent 正在跑分钟级交叉编译时落档当然不动，
 * 连续 6 次轮询就被判「AI 好像在绕圈」——它其实在干活（那轮 trace 有 24 次工具调用）。
 * 假停滞会诱导人去按中止，等于把正在干活的代理打断。
 *
 * @param traceLines 会话跟踪文件（`<工程>/.lingqu/agent/trace.jsonl`）的行数；
 *                   传负数表示"取不到"，此时退化成只看落档（老行为）。
 */
public func autoportSnapshotWith(rows: ArrayList<MigrateRow>, traceLines: Int64): String {
    var s = ""
    for (r in rows) {
        var state = "none"
        if (r.skipped.size > 0) {
            state = "skip"
        } else if (r.ran && r.ok) {
            state = "ok"
        } else if (r.ran) {
            state = "bad"
        }
        if (s.size > 0) {
            s += "|"
        }
        s += "${r.step}:${state}:${r.note}"
    }
    if (traceLines >= 0) {
        s += "|agent:${traceLines}"
    }
    return s
}

/** 有多少步已经有结论（ran 且 ok） */
public func autoportDoneCount(rows: ArrayList<MigrateRow>): Int64 {
    var n: Int64 = 0
    for (r in rows) {
        if (r.ran && r.ok) {
            n += 1
        }
    }
    return n
}

/**
 * 一句话结论（AI 自动迁移版）。
 *
 * 与确定性流程的区别：这里的"通过"只认落档，而且**跳过也算进了进度**（没插设备是环境事实）。
 */
public func autoportVerdict(rows: ArrayList<MigrateRow>, finished: Bool, stalled: Bool): String {
    if (rows.size == 0) {
        return "还没开始"
    }
    if (stalled) {
        return "AI 好像在绕圈（落档连续没变化）——建议停下看它卡在哪"
    }
    var failed = ""
    var skipped = 0
    for (r in rows) {
        if (r.ran && !r.ok && r.skipped.size == 0 && failed.size == 0) {
            failed = r.title
        }
        if (r.skipped.size > 0) {
            skipped += 1
        }
    }
    let done = autoportDoneCount(rows)
    if (failed.size > 0) {
        if (finished) {
            return "停在「${failed}」（已通过 ${done} 步）"
        }
        return "进行中：正在处理「${failed}」"
    }
    if (skipped > 0) {
        return "代码链 ${done} 步通过；真机步骤跳过 ${skipped} 步"
    }
    return "全部通过（${done} 步）"
}

/** 升级给人的一句话（预算/停滞/失败都走它，界面直接显示在结果卡顶部） */
public func escalationLine(stalled: Bool, overBudget: Bool, minutes: Int64): String {
    if (stalled) {
        return "AI 连续 ${AUTOPORT_STALL_POLLS} 次轮询落档没有变化，建议点「停止」后让它总结，或直接接管。"
    }
    if (overBudget) {
        return "已超过时间预算（${minutes} 分钟）：点「停止」让它收尾，别硬等。"
    }
    return ""
}

/**
 * AI 自动迁移的**监管状态**（命令层持有；页面轮询 `t2h:autoport_status` 读它）。
 *
 * 只记"人看得懂的那点东西"：跑到哪、第几次轮询、最近几次落档快照（给停滞判定用）。
 * 落档本身永远是真相来源——这里丢了也不影响结论（重启后重新读盘即可）。
 */
public class AutoPortState {
    public var active: Bool = false
    public var path: String = ""
    public var project: String = ""
    public var budget: Int64 = AUTOPORT_MAX_ITERATIONS
    public var minutes: Int64 = AUTOPORT_MAX_MINUTES
    public var polls: Int64 = 0
    public var history: ArrayList<String> = ArrayList<String>()

    public init() {}

    /** 压入一次快照签名，只保留最后 [AUTOPORT_STALL_POLLS] 条 */
    public func pushSig(sig: String): Unit {
        history.add(sig)
        while (Int64(history.size) > AUTOPORT_STALL_POLLS) {
            history.remove(at: 0)
        }
        polls += 1
    }

    /**
     * 丢弃已有快照（但**保留** polls 计数）：agent 正在跑工具时调用。
     *
     * 为什么要清：单个长工具调用期间落档与轨迹都不动，这期间的签名会攒成一串相同值；
     * 工具一结束如果不清理，窗口里还留着那一串，下一次轮询就立刻判"停滞"。
     */
    public func clearHistory(): Unit {
        history.clear()
    }

    /** 清空（开始新一轮时） */
    public func reset(newPath: String, newProject: String, budgetNow: Int64, minutesNow: Int64): Unit {
        active = true
        path = newPath
        project = newProject
        budget = budgetNow
        minutes = minutesNow
        polls = 0
        history = ArrayList<String>()
    }

    public func stop(): Unit {
        active = false
    }
}
