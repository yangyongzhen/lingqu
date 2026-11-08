package lingqu

import std.collection.*
import std.time.*

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

/**
 * 「正在跑一个工具」的豁免上限（秒）。
 *
 * `agentTraceBusy()` 的豁免本意是别把分钟级交叉编译误判成绕圈，但它**原先没有时间上限**：
 * 工具一旦挂死，`busy` 永远为真 ⇒ 停滞判定被永久清空 ⇒ 界面只剩「执行中 565s」，
 * 既不报停滞也不给建议。2026-11-07 实测正是这一幕：引擎的 `find /` 把工具调用挂住 565s+，
 * `trace.jsonl` 停在 `tool` 那条记录之后再无 `tool_done`，监管屏一直在"干活"里空转，
 * 用户只能自己去任务管理器里发现一个 605s CPU 的 `find.exe`。
 *
 * 300 秒的取法：正常人会等一个长编译，但不会指望单条工具跑满五分钟还不留痕。
 * 超限之后只是**恢复**停滞判定（还要再攒满 [AUTOPORT_STALL_POLLS] 次不变才报），
 * 不会立刻喊停——所以宁可设得宽一些。
 */
public let AUTOPORT_BUSY_MAX_SECS: Int64 = 300

/**
 * 单个工具调用的"豁免"是否仍然成立（纯函数）。
 *
 * 超上限即失效：之后按普通快照参与停滞判定，并在状态里带上 `busySecs`，
 * 让人看到"这个工具已经 X 秒没回音"而不是一片沉默。
 */
public func busyStillExempt(busySecs: Int64, limitSecs: Int64): Bool {
    if (limitSecs <= 0) {
        return true
    }
    return busySecs < limitSecs
}

/** 当前毫秒时钟（busy 计时用；本文件已依赖 std.time，main.cj 不必再引一遍） */
public func nowMsOf(): Int64 {
    return DateTime.now().toUnixTimeStamp().toMilliseconds()
}

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
        return "- 跑 `sign --path .` 体检，读 `mode`（debug/release）、材料、profile 里有没有本机 UDID；\n" +
            "- 材料不全/UDID 没绑定：`sign --login`（**要人在浏览器授权一次**）→ `sign --auto --path .`" +
            "（注册设备→申请证书→申请 profile→写回 `build-profile.json5`，原文件会备份）；\n" +
            "- 需要写回 signingConfigs 时先说明理由再 `--apply`（会备份原文件）；\n" +
            "- `--login` 你替不了：**不要自己开浏览器登录 AGC 网页**，" +
            "那样拿不到本机回调的 tempToken、也不注册设备，白花一次人工介入；\n" +
            "- **别把 release 态装不上真机当成 bug 去修**（release profile 不含 device-ids，直装必被 9568322 拒，正常）；\n" +
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
            inp.cliPath + " sign   --path .     # 签名体检（mode / 材料 / profile 有没有本机 UDID）\n" +
            inp.cliPath + " sign   --login      # AGC 登录（浏览器授权一次，必须人配合）\n" +
            inp.cliPath + " sign   --auto --path .  # 自动签发：注册设备→证书→profile→写回 build-profile\n" +
            inp.cliPath + " deploy --path .     # 真机装启 + hilog\n" +
            inp.cliPath + " probe  --path . --feature <功能名> --click-file <按钮文本文件>   # " +
            "真机点一下再判定（写 .lingqu/verify/<工程>.probe.json）\n" +
            inp.cliPath + " verify --path .     # 采证 + 功能清单 + 可用率（会优先采用 probe 的结论）\n" +
            inp.cliPath + " report --path .     # 三段式报告\n```\n"
        d += "（路径里有空格就整条用双引号括起来。）\n"
    } else {
        d += "```bash\nlingqu-cli resume --path .\nlingqu-cli scan --path .\n```\n"
        d += "（`lingqu-cli` 不在 PATH 里的话，让应用帮你定位，或直接读 `.lingqu/` 落档做判断。）\n"
    }
    // 0.39.55：让 agent **自己把踩的坑写下来**。它的文字汇报会留在会话里，而会话会被压缩
    // （实测"21/24/30 条早期消息 → 摘要"），细节一压缩就淡；落成文件才留得住、才能进报告与技能库。
    //
    // 注意：内容必须走 **`--body <文件>`**，不能写进命令行参数：仓颉程序在 Windows 上接不了非 ASCII 的
    // argv（`Invalid unicode scalar value`，见 AGENTS §4-119），而经验内容天然是中文。
    if (inp.cliPath.size > 0) {
        d += "\n## 把踩到的坑记下来（**必做**，只记真发生过的）\n"
        d += "某一步**重试 ≥2 次才通**、或**换了方案才通**、或撞到与平台相关的坑时，立刻追加一条。\n"
        d += "内容写进 JSON 文件再交给命令（**别把中文写进命令行参数**——Windows 上 argv 过不了非 ASCII，"
        d += "会直接抛 `Invalid unicode scalar value`）：\n"
        d += "```bash\n"
        d += "cat > .lingqu/note-in.json <<'EOF'\n"
        d += "{\"title\":\"一句话标题\",\"symptom\":\"看到的报错/现象\",\"cause\":\"你判断的根因\"," +
            "\"repro\":\"复现命令或落档位置\",\"fix\":\"你实际怎么修好的\"}\n"
        d += "EOF\n"
        d += inp.cliPath + " notes --action append --path . --body .lingqu/note-in.json\n"
        d += "```\n"
        d += "（同标题只累加次数，不会重复堆；写进 `.lingqu/notes/<工程>.md`，报告里会引用。）\n"
        d += "**别记「我猜可能」的东西**——只记你亲手验证过的。\n\n"
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
    d += "## 真机：" + (if (inp.device) { "在线 —— `deploy` / `verify` / `probe` 都要跑，装不上先看签名态\n" }
        else { "**不在线** —— 跳过 deploy/verify/probe（落档会是\"未跑\"，如实报告即可，别当成失败）\n" }) + "\n"
    if (inp.device) {
        // A4「核心功能可用率」的分母是核心功能清单，而清单里每一项都要有**真机上的结论**。
        // 光跑 verify 只能采证（数崩溃、读截图），点不点得动它一概不知道 —— 实测就是这么把
        // 两个空壳命令放过成"未测"的（AGENTS §4-48：进程在跑 ≠ 界面正常）。
        d += "### 功能是**点**出来的，不是看出来的\n"
        d += "「装上了 / 进程在跑 / 日志没报错 / 截图看着像」都不能算功能可用。要判定某一项，"
        d += "就在真机上点它一下，再对比点了之后发生了什么 —— 这件事你自己能做，也应当你做：\n"
        d += "```bash\n"
        d += "printf '选择文件' > .lingqu/click.txt      # 中文一律写文件，别写进命令行参数（Windows argv 过不了非 ASCII）\n"
        d += inp.cliPath + " probe --path . --feature pick_file --click-file .lingqu/click.txt\n"
        d += inp.cliPath + " probe --path . --feature start_download --click-file .lingqu/start.txt " +
            "--expect-log-file .lingqu/expect.txt\n"
        d += "```\n"
        d += "- 判据是**版面变化**：点后冒出新的文本 → `pass`；版面一字不差 → `fail`（说明这个按钮是死的）；"
        d += "日志命中 `--expect-log` 也算 `pass`；\n"
        d += "- 结论自动落进 `.lingqu/verify/<工程>.probe.json`，`verify` 会**优先**采用它；"
        d += "你**不用**手写这个文件；\n"
        d += "- 探针是你在做实验，**不计人工介入**（A3）；\n"
        d += "- 判不了就如实记「未测」，别凑：需要前置现场的（例：取消下载要先有\"下载进行中\"）、"
        d += "需要滚动或跨窗口才看得见的节点，都算未测，写清缺什么现场。\n"
        d += "- 点不动先分清是**壳没接**（该命令在 OHOS 分支是空实现）还是**真崩了**："
        d += "看源码里那条命令的 OHOS 分支，别反复试点。\n\n"
    }

    d += "## 纪律（说错一句就露馅）\n"
    d += "- **平台限制 ≠ 失败**：鸿蒙没有的能力登记为限制，不算 bug，更不许写\"已修复\"；\n"
    d += "- **未验证 ≠ 通过**：没证据的项写 unknown；\n"
    d += "- 改代码前先 `git status` 看看工作区；**别动与迁移无关的文件**；\n"
    d += "- 真机装不上先看 `.lingqu/sign/<工程>.json` 的签名态与 `## 签名与登录` 那节的对照表：" +
        "release 态装不上是正常的（profile 不含 device-ids），UDID 没绑定则要人登录一次；\n"
    d += "- 不确定就先用 `git stash` 或用我们 `.lingqu` 里的备份兜底，再重试；\n"
    // 2026-11-07 实测事故：agent 为找 `gen/ohos` 跑了 `find / -maxdepth 6 -type d -name ohos
    // -path "*gen*"` 全盘扫描，把整轮工具调用挂死 565s+（孤儿 find 累计 CPU 605s），
    // 迁移就此停住。脚手架位置是**确定的**，没有就是没有——不许拿全盘搜索去碰运气。
    d += "- **禁止全盘搜索**（`find /`、`dir /s C:\\`、`Get-ChildItem -Recurse` 扫盘符根都算）：\n"
    d += "  命令一律在**本工程目录内**执行（工作目录就是工程根，用相对路径或 `.` 即可）；\n"
    d += "  要找脚手架只有两处：`<工程>/gen/ohos` 与 `<工程>/src-tauri/gen/ohos`；"
    d += "两处都没有就**如实报告缺脚手架**（并写明生成命令），不要满盘搜、不要换个盘再搜；\n"
    d += "- 单条命令要能自己结束：别写会长时间挂住的扫描/交互式命令；"
    d += "估算超过 2 分钟的命令先说明理由再跑。\n\n"

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

    // 2026-11-07 实测：任务书**只写了 `sign --path .`**，没写 CLI 早就有的 `--login` / `--auto`，
    // agent 于是在签名这一步自己开浏览器登录 AGC 网页——拿不到本机回调的 tempToken、也不注册设备，
    // 白花一次人工介入，签名照样没过。凡"工具明明有能力、任务书没写"的缺口，都按这个补法：
    // **把两条路和判据写死**，并明确哪一步只能人做、人做之前要先说清什么。
    d += "## 签名与登录（真机装不上，绝大多数卡在这一步）\n"
    d += "华为设备**只信任华为签发、且 profile 的 device-ids 含本机 UDID 的证书**。"
    d += "所以「有 signed.hap」≠「能装」，判据是这三样对不对得上：`mode` / 材料 / profile 里的 UDID。\n"
    d += "顺序固定，别跳步：\n"
    d += "1. `sign --path .` —— 体检：读 `mode`（debug/release）、材料是否齐全、profile 里有没有本机 UDID；\n"
    d += "2. `sign --login` —— AGC 登录：**必须人在浏览器里授权一次**，回调到本机后才有 token；\n"
    d += "3. `sign --auto --path .` —— 自动签发：注册设备 → 申请调试证书 → 申请 profile → " +
        "按 DevEco 命名落盘 → 写回 `build-profile.json5`（原文件先备份）；\n"
    d += "4. 再重跑 `hap --path .` → `deploy --path .`。\n"
    d += "**第 2 步你替不了，也不许假扮**：不要自己 `start` / `rundll32` / `open` 去打开 AGC 网页登录——" +
        "那样拿不到本机回调的 tempToken，也不会把设备注册进 profile，等于白花一次人工介入。\n"
    d += "要人登录时，用 `lingqu-decision` 块一次性说清三件事：**为什么必须登录 / 点哪里" +
        "（应用界面的「华为账号登录」按钮，或 `sign --login`）/ 本机 UDID 是多少**；说完停下等人，别绕圈。\n"
    d += "报错对照（先对号，别乱改代码）：\n"
    d += "- `9568320 no signature file` → 压根没签上，走上面第 2、3 步；\n"
    d += "- `9568322 signature verification failed due to not trusted app source` → 两种：" +
        "**release profile 不含 device-ids（正常，别修）**；或 debug 材料里没有本机 UDID（用 `--auto` 注册设备）；\n"
    d += "- `00303074 … bundleName … does not match` → 包名与 profile 不一致：**新包名只能去 DevEco 自动签名一次**" +
        "（计一次人工介入）；**不许改 `bundleName` 去蹭别人签发的 profile**；\n"
    d += "- `00303242` / `GCM tag mismatch` → `.p12` 口令解不开（材料多半是拷来的），用 `sign --newKeys` 重生成材料；\n"
    d += "- `9568332 install sign info inconsistent` → 同包名装过另一套签名，先 `bm uninstall -n <包名>` 再装。\n"
    d += "**底线**：不许伪造签名、不许改包名套别人的 profile——宁可如实报「签名未完成、等人登录」，" +
        "也不要交一个装不上的 HAP 说成迁完了。\n\n"

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
 * 有多少步**已经有定论**：通过（ran && ok）**或**明确跳过（如"未连接真机"）。
 *
 * 与 `autoportDoneCount` 的区别：跳过的步不算"通过"，但它确实"有结论、不用再等"。
 * 停滞判定要用这一条——见 `autoportAllConcluded`。
 */
public func autoportConcludedCount(rows: ArrayList<MigrateRow>): Int64 {
    var n: Int64 = 0
    for (r in rows) {
        if ((r.ran && r.ok) || r.skipped.size > 0) {
            n += 1
        }
    }
    return n
}

/**
 * 全部步骤都有结论了吗（0.39.41）。
 *
 * 为什么停滞判定必须让它一票否决：**活干完了，落档本来就不会再变**。
 * 0.39.34 只处理了"还在干活"（agent 活动量、WS 帧数），却没处理"已经干完"——
 * 于是用户看到的现象是：迁移全绿、报告都生成了，界面还在喊
 * 「AI 连续 20 次轮询落档没有变化，建议点「停止」后让它总结，或直接接管」。
 * 判据：8 步全部"通过或跳过" ⇒ 没有"该变而没变"的东西 ⇒ 不判停滞。
 */
public func autoportAllConcluded(rows: ArrayList<MigrateRow>): Bool {
    if (rows.size == 0) {
        return false
    }
    return autoportConcludedCount(rows) >= Int64(rows.size)
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
    return escalationLineFor(stalled, overBudget, minutes, false)
}

/**
 * 同上，但把「已经全部有结论」也纳入判据（0.39.41）。
 *
 * `finished=true` 时一律不叫人：活干完了，落档不再变化是**正常**，不是绕圈。
 * 这正是用户实测的那条误报——迁移全绿了，界面还在喊"建议点停止后让它总结"。
 */
public func escalationLineFor(stalled: Bool, overBudget: Bool, minutes: Int64, finished: Bool): String {
    if (finished) {
        return ""
    }
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
    /** 「正在跑工具」的起始时刻（毫秒；0 = 当前没有在跑工具）——给 busy 豁免算年龄 */
    public var busyStartMs: Int64 = 0

    public init() {}

    /**
     * 记一次「正在跑工具」，返回它已经持续了多少秒（第一次调用返回 0）。
     *
     * 时间由状态自己记，不去解析轨迹里的 `ts`：那是页面写的 ISO 字符串，
     * 解析它等于把停滞判定绑死在另一种格式上；这里只需要"多久没回音"。
     */
    public func noteBusy(nowMs: Int64): Int64 {
        if (busyStartMs <= 0) {
            busyStartMs = nowMs
            return 0
        }
        let ms = nowMs - busyStartMs
        if (ms <= 0) {
            return 0
        }
        return ms / 1000
    }

    /** 工具已结束 / 本轮不再 busy：清掉计时 */
    public func clearBusy(): Unit {
        busyStartMs = 0
    }

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
        busyStartMs = 0
    }

    public func stop(): Unit {
        active = false
    }
}
