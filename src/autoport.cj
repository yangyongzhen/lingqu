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
 * 任务书小节的触发条件（0.39.112）。
 *
 * 为什么要给它一个"名字"而不是在单测里写死 `contains`：任务书不是所有小节都无条件出现
 * （没给 CLI 路径就没有工具箱之外的命令示范、没插真机就没有冒烟节），判"给全了没有"
 * 必须知道**这一份变体该有哪些**，否则只能靠人眼看。
 */
public let DIRECTIVE_WHEN_ALWAYS: String = "always"
/** 只有拿到 `lingqu-cli` 绝对路径时才出现（没路径时工具箱整段退化成命令名举例） */
public let DIRECTIVE_WHEN_CLI: String = "cli"
/** 真机在线才有（冒烟与移植验收的分母说明） */
public let DIRECTIVE_WHEN_DEVICE: String = "device"
/** 有落档摘要才有（"当前落档"那节，让 agent 一上手就知道从哪继续） */
public let DIRECTIVE_WHEN_STATE: String = "state"
/** 半自动作用域才有（只做一步、做完就停） */
public let DIRECTIVE_WHEN_HALF: String = "half"

/**
 * 任务书的一条必备小节。
 *
 * [section] 是小节标题的**稳定前缀**：生成物里必须原样出现，所以改文案就得同步改这里，
 * 而 `docs/任务书规范.md` §3 抄的是同一份清单（单测两端都钉住，见 §4-167 同族）。
 * [why] 写清"缺了会怎样"——它是判「这一条还能不能删」的唯一依据，删条款的人先读它。
 */
public class DirectiveClause {
    public var section: String = ""
    public var when: String = ""
    public var why: String = ""

    public init(section: String, when: String, why: String) {
        this.section = section
        this.when = when
        this.why = why
    }
}

/**
 * 任务书必备小节清单——**这是任务书层的"验收判据"，不是备忘录**。
 *
 * 每一条都对应一次真实事故（§4-130 / §4-150 那一族）：工具明明有能力、任务书没写，
 * agent 就只能瞎摸，白烧一轮人工介入。所以新增能力时问的不是"要不要写进任务书"，
 * 而是"写在哪个小节、缺了会怎样"。
 */
public func directiveClauses(): ArrayList<DirectiveClause> {
    let out = ArrayList<DirectiveClause>()
    out.add(DirectiveClause("【灵渠 · AI 自动迁移任务书】", DIRECTIVE_WHEN_ALWAYS,
        "不点明这是任务书，模型会当成随便一段聊天，给完建议就停下"))
    out.add(DirectiveClause("**你是这次迁移的执行者，不是顾问。**", DIRECTIVE_WHEN_ALWAYS,
        "0.36.0 就是这么退化的：AI 只出建议，命令还得人点"))
    out.add(DirectiveClause("## 工具箱", DIRECTIVE_WHEN_ALWAYS,
        "agent 的 bash cwd 是目标工程，相对路径全失效；没有可复制的绝对路径，整条循环就断了（§4-70）"))
    out.add(DirectiveClause("## 原生 UI 能力", DIRECTIVE_WHEN_ALWAYS,
        "选文件/选目录/分享/开外部应用在 ArkWeb 里没有原生等价物，不写它就自己开浏览器或猜路径（§4-162）；" +
            "这条**无条件**给，因为桥的铁律与有没有 lingqu-cli 路径无关"))
    out.add(DirectiveClause("## 把踩到的坑记下来", DIRECTIVE_WHEN_CLI,
        "会话会被压缩，细节一压就淡；不落成笔记就等于没踩过（飞轮第 ①步的入口）"))
    out.add(DirectiveClause("**判断只认落档**", DIRECTIVE_WHEN_ALWAYS,
        "退出码 0 不等于通过（§4-63 假绿）；不写这条，它会拿\"跑完了\"当\"迁好了\""))
    out.add(DirectiveClause("## 工作循环", DIRECTIVE_WHEN_ALWAYS,
        "不给固定循环，它会跳步或反复重跑已通过的步骤，白烧轮次"))
    out.add(DirectiveClause("## 当前落档", DIRECTIVE_WHEN_STATE,
        "不给现状就会自己去猜从哪继续，通常等于重跑一遍扫描"))
    out.add(DirectiveClause("## 本次范围", DIRECTIVE_WHEN_HALF,
        "半自动不写范围，它会顺手把 build/hap/deploy 全跑了，人失去逐步确认的意义"))
    out.add(DirectiveClause("## 真机：", DIRECTIVE_WHEN_ALWAYS,
        "不说清设备在不在线，它会把\"未跑\"当成\"失败\"，或者对不存在的设备反复重试"))
    out.add(DirectiveClause("### 先证「移植做完了」", DIRECTIVE_WHEN_DEVICE,
        "D-020：A4 分母是移植项，不写清就会去替原作者逐条点业务功能，永远点不完"))
    out.add(DirectiveClause("### 业务功能冒烟", DIRECTIVE_WHEN_DEVICE,
        "不把冒烟单列，业务功能失败会被算进移植通过率（§4-63 第三态）"))
    out.add(DirectiveClause("## 纪律", DIRECTIVE_WHEN_ALWAYS,
        "平台限制≠失败、未验证≠通过、禁全盘搜索——不写就会谎报或挂死（2026-11-07 事故）"))
    out.add(DirectiveClause("## 插件不满足：三层适配优先于降级", DIRECTIVE_WHEN_ALWAYS,
        "外部反馈（2026-11-20）：轻易降级就丢原软件功能特性；不写清适配路径，agent 撞到无对应物的插件只会降级"))
    out.add(DirectiveClause("## 交叉编译的硬前置", DIRECTIVE_WHEN_ALWAYS,
        "缺 `.cargo/config.toml` 的 `[env]` 段时 cc-rs 必然失败，不说清它会去改 Rust 源码"))
    out.add(DirectiveClause("## TLS 栈", DIRECTIVE_WHEN_ALWAYS,
        "reqwest 默认特性拉进 openssl-sys，OHOS 上必死；技能里写了也没用，症状串对不上（§4-150）"))
    out.add(DirectiveClause("## 装配 HAP 前：鸿蒙脚手架必须先生成", DIRECTIVE_WHEN_ALWAYS,
        "不写 `cargo tauri ohos init --ci`，它到 hap 这一步只会撞墙，或去全盘搜 `gen/ohos`"))
    out.add(DirectiveClause("## 签名与登录", DIRECTIVE_WHEN_ALWAYS,
        "CLI 早就有 `--login`/`--auto`，任务书没写 ⇒ agent 自己开浏览器登录，白花一次人工介入（§4-130）"))
    out.add(DirectiveClause("## 预算与收尾", DIRECTIVE_WHEN_ALWAYS,
        "不给预算它会无限挂着；不给收尾格式，人就只能读一大段散文"))
    return out
}

/** [whens] 里有没有这个条件（小工具，避免依赖 Array 的 contains 语义） */
func directiveWhensContains(whens: Array<String>, w: String): Bool {
    for (x in whens) {
        if (x == w) {
            return true
        }
    }
    return false
}

/**
 * 按触发条件筛出**这一份变体**该有的必备小节（纯函数）。
 *
 * [whens] 传 `[DIRECTIVE_WHEN_CLI, DIRECTIVE_WHEN_DEVICE, …]` 这种"这份变体满足了哪些条件"。
 * `always` 不需要传——它永远算上。
 */
public func directiveSectionsOf(whens: Array<String>): Array<String> {
    let out = ArrayList<String>()
    for (c in directiveClauses()) {
        if (c.when == DIRECTIVE_WHEN_ALWAYS || directiveWhensContains(whens, c.when)) {
            out.add(c.section)
        }
    }
    return out.toArray()
}

/**
 * [body] 里缺了哪些必备小节（纯函数）。
 *
 * 空 body 一律判"全缺"——**不许把"读不到"当成"都齐了"**（§4-136 假绿的教训：
 * 拿不到现场不是没问题）。写盘失败、文件被清空都该走这条路报出来。
 */
public func directiveGapsOf(body: String, wants: Array<String>): ArrayList<String> {
    let gaps = ArrayList<String>()
    for (w in wants) {
        if (!body.contains(w)) {
            gaps.add(w)
        }
    }
    return gaps
}

/**
 * 只看**条件性**小节（永不含 `always`）——用于断言"条件不满足时它确实不在"。
 *
 * 为什么不复用 `directiveSectionsOf`：那个函数的口径是"这一份变体该有的**全部**小节"，
 * 天然含 always；拿它去断"不在"会把每条必给小节都断成失败（0.39.112 第一版单测就这么红的，
 * 属于**测试自己错了**，不是被测代码错——这种情况必须先分清，别去改被测代码迎合测试）。
 */
public func directiveConditionalSectionsOf(whens: Array<String>): Array<String> {
    let out = ArrayList<String>()
    for (c in directiveClauses()) {
        if (c.when != DIRECTIVE_WHEN_ALWAYS && directiveWhensContains(whens, c.when)) {
            out.add(c.section)
        }
    }
    return out.toArray()
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
            inp.cliPath + " probe  --path . --auto --max 8   # " +
            "**自动验证**：自己去版面枚举能点的文本，逐个点、逐个比对、逐个落档\n" +
            inp.cliPath + " probe  --path . --feature <功能名> --click-file <按钮文本文件>   # " +
            "真机点一下再判定（写 .lingqu/verify/<工程>.probe.json）\n" +
            inp.cliPath + " verify --path .     # 采证 + 功能清单 + 可用率（会优先采用 probe 的结论）\n" +
            inp.cliPath + " report --path .     # 三段式报告\n```\n"
        d += "（路径里有空格就整条用双引号括起来。）\n"
    } else {
        d += "```bash\nlingqu-cli resume --path .\nlingqu-cli scan --path .\n```\n"
        d += "（`lingqu-cli` 不在 PATH 里的话，让应用帮你定位，或直接读 `.lingqu/` 落档做判断。）\n"
    }
    // 0.39.108（AGENTS §4-130 的教训）：**能力已经有、说明书没给 = agent 只能瞎摸**。
    // 「原生 UI 能力」这一类缺口重复率极高（选文件/选目录/分享/相册/打开外部应用），而它撞出来的
    // 第一反应往往是"自己开个浏览器/自己猜路径"，白烧一轮人工介入。顺序、铁律、验证三步写死在这里；
    // 细节（桥骨架、三种返回值形态、picker 的 uri 授权语义）在技能 references/native-ui-bridge.md。
    // 命令名兜底：这一段是**无条件**出现的，而 `inp.cliPath` 在定位不到时是空串——
    // 直接拼进去会产出 `` ` hap --path .` ``（程序名丢了），agent 照着跑必然 "command not found"。
    // 与「工具箱」那节同一个口径：退化成命令名，让它自己去找（§4-94：不许出现看起来像命令的假值）。
    let cliRef = if (inp.cliPath.size > 0) { inp.cliPath } else { "lingqu-cli" }
    d += "\n## 原生 UI 能力（选择文件/目录、分享、打开外部应用）\n"
    d += "`verify` 的 `platform-api` 项里若出现「鸿蒙侧是空壳」（`None` / `Err(\"当前平台不支持…\")`），"
    d += "指的是桌面侧用了 `rfd::FileDialog` / `explorer` / 系统分享这类**原生 UI**。ArkWeb 里没有原生对话框，"
    d += "只能由 ArkTS 拉起系统 UI、Rust 通过 NAPI 桥请它动手。细则见技能 "
    d += "`skills/t2h-ohos-port/references/native-ui-bridge.md`（**先读它再动手**）。三条铁律：\n"
    d += "1. **线程**：Tauri 命令在 IPC 线程跑，`get_main_thread_env()` 只有主线程有值 ⇒ "
    d += "必须 `app.run_on_main_thread(...)` 投递后再调桥；\n"
    d += "2. **uri ≠ 路径**：Picker 返回 `file://docs/…` 的 **uri**，授权只在 uri 通道生效、"
    d += "**不覆盖 `std::fs` 的裸路径读写**。选文件要拷进沙箱再回传；选目录要**探一次可写**"
    d += "（建目录+探针写+删探针），不可写回落 `files/downloads` 并把真实落点交回界面；\n"
    d += "3. **要返回值就别 fire-and-forget**：写一次性结果文件（先 `.tmp` 再 rename）+ Rust 轮询读取。\n"
    d += "**验证三步缺一不可**：`cargo build`（桌面别弄坏）→ "
    d += "`cargo build --target aarch64-unknown-linux-ohos --release` → "
    d += "`" + cliRef + " hap --path .`（**只有 hvigor 会编译 `.ets`**，"
    d += "前两步全绿而 `.ets` 少个 import，真机上点了就是不弹框）。\n"
    d += "**别自己开浏览器、别猜路径**：要人操作就用 `lingqu-decision` 说清要人做什么。\n\n"

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
        // D-020：**A4 的分母是移植验收项**（装得上/起得来/渲染得出/前端资源进包/通道通/平台能力有落地），
        // 不是原应用那上百条业务功能。逐条点业务功能永远点不完，缺网/缺配置也必然过不了，
        // 那不属移植职责——所以这里只要求**移植项有结论**，业务功能点按降为可选冒烟。
        d += "### 先证「移植做完了」，再谈业务功能（别把时间花在替原作者点按钮上）\n"
        d += "移植该负责的事只有这几类：**装得上、起得来、界面渲染得出、前端资源进包、IPC 与事件通道通、"
        d += "命中的平台 API 有落地的等价实现**。这些都在 `.lingqu/verify/<工程>.json` 里（`category=transplant`），"
        d += "**它们才进 A4 分母**。\n"
        d += "**原应用自己的业务功能（`category=business`，如 start_download / ai_json_request）不要求逐条验证**："
        d += "没有网络、没有密钥、没有登录，它们本来就跑不起来，那说明不了移植好坏。\n\n"
        d += "### 业务功能冒烟（可选，`--max` 给 3 就够）\n"
        d += "想确认壳没接错，可以顺手点几个，但**不要为它烧轮次**：\n"
        d += "```bash\n"
        d += cliRef + " probe --path . --auto --max 3    # 自动点 3 个候选，结论落 .probe.json（单列，不计分）\n"
        d += "```\n"
        d += "- 判据是**版面变化**：点后冒出新的实质文本 → `pass`；点了没动静 → 记 `unknown`（分不清没点中还是真无响应，"
        d += "不许直接判 fail 拉低数字）；\n"
        d += "- 结论写进 `.lingqu/verify/<工程>.probe.json` 的 `smoke` 单列，**不进移植通过率**，你**不用**手写这个文件；\n"
        d += "- 探针是你在做实验，**不计人工介入**（A3）；\n"
        d += "- 想点名探某一个，用 `--feature <命令名> --click-file <含中文按钮文本的文件>`"
        d += "（中文一律写文件，别塞命令行参数——Windows argv 过不了非 ASCII）；\n"
        d += "- **别为凑数硬点**：需要前置现场（例：取消下载要先有\"下载进行中\"）、需要滚动或跨窗口才看得见的节点，"
        d += "如实记「未测」并写清缺什么现场；一轮 3~8 个候选足够说明壳接没接上；\n"
        d += "- 点不动先分清是**壳没接**（该命令在 OHOS 分支是空实现）还是**真崩了**："
        d += "看源码里那条命令的 OHOS 分支，别反复试点。\n\n"
    }

    d += "## 纪律（说错一句就露馅）\n"
    d += "- **每撞一次坑，先落经验再重试**：失败后第一件事是 `lingqu-cli notes --path . --rule <规则号或指纹号> --body-file <文件>`（或 `diagnose`），\n"
    d += "  然后再动代码/重跑。跑完一轮 `.lingqu/notes/<工程>.md` 里没东西 = 这轮的坑白踩了（2026-11-19 实测：\n"
    d += "  EcoPaste 连撞 4 次坑、notes 与 diagnose 目录全空，飞轮等于没转）。\n"
    d += "- **`build` 长时间没输出先看是不是在下载依赖**：`rustc.exe` 一个都没起、cargo CPU 近 0、\n"
    d += "  `registry/cache` 不涨 ⇒ 是 crates.io（Fastly）卡了，**不是工具挂死**。先等 2~3 分钟，\n"
    d += "  仍不动就配国内镜像（`R2-PORT-008` 生成的 `.cargo/config.toml` 已默认带 rsproxy）\n"
    d += "  或设代理后重跑；**别把它诊断成代码问题**，也别对同一网络原样重试。\n"
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
    d += "两处都没有就**如实报告缺脚手架**，并写明生成命令是 `cargo tauri ohos init --ci`"
    d += "（见「装配 HAP 前：鸿蒙脚手架必须先生成」），不要满盘搜、不要换个盘再搜；\n"
    d += "- 单条命令要能自己结束：别写会长时间挂住的扫描/交互式命令；"
    d += "估算超过 2 分钟的命令先说明理由再跑。\n\n"

    // 2026-11-20 外部反馈：tauri→鸿蒙移植遇到鸿蒙侧没有的插件/能力时，不要轻易降级——
    // 降级就丢原软件的功能特性。三层适配路径（差异层 → 条件编译 → API 映射）写进任务书，
    // 技能 references（plugins.md）同步；降级是最后手段且必须登记（limit + 人工介入 A3）。
    d += "## 插件不满足：三层适配优先于降级\n"
    d += "- 遇到鸿蒙侧没有对应物的 tauri 插件 / 平台 API，**按顺序走三层适配**，降级是最后手段：\n"
    d += "  ① **wry/tao 差异层**：先查 fork 里有没有 OHOS 分支实现——很多 desktop 方法只是被 "
    d += "`#[cfg(desktop)]` 门控（`center`/`maximizable`/`decorations`…），照 `#[cfg(not(target_env = \"ohos\"))]` "
    d += "拆链即可，**别把\"方法不存在\"当成\"平台没有\"**；能力实在缺就在 fork（github.com/yangyongzhen/tauri / "
    d += "openharmony-ability）建 `fix/<工程>-<问题>` 分支补，patch rev 钉住。\n"
    d += "  ② **平台条件编译补丁**：依赖层的差异用 `cfg(target_env = \"ohos\")` 依赖段、`[patch.crates-io]`、"
    d += "特性替换解决（同 R2-PORT-005/006/016 的口径——换等价实现，**顺手关掉的默认特性要补回来**）。\n"
    d += "  ③ **API → ArkWeb/鸿蒙系统能力映射**：原生能力（选文件/分享/开应用）用 `ohos_bridge.rs` + ArkTS "
    d += "分发器桥到系统等价物（`DocumentViewPicker` 等），落地要双侧（Rust 调桥 + ArkTS 有同名 cmd 分支）；"
    d += "web 能力找 ArkWeb 等价物（localStorage polyfill、confirm/prompt→应用内对话框）。\n"
    d += "- **降级（登记为 limit）之前必须能说清**：三层为什么都走不通。降级要如实登记（落档 limit + "
    d += "必要时让人拍板），**静默砍功能不算限制，算移植失败**。\n"
    d += "- 判\"平台没有某 API\"前先看它落在 fork 源码的**哪个 impl 块**、有没有被 cfg 门控"
    d += "（§4-174：报错说\"没有\"≠ 真的没实现）。\n\n"

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

    // 0.39.99（note-gen-2 实测，2026-11-08）：技能 references 里**早就写了**「reqwest 要
    // default-features = false + rustls-tls」，agent 照样踩——因为日志症状串（OpenSSL /
    // pkg-config）与"reqwest 的默认特性"之间没有字面联系，而上面「硬前置」那节又把它
    // 引向"配 CC / pkg-config"。所以这条必须进任务书（agent 唯一必读的入口），
    // 规则 R2-PORT-016 是兜底（重跑 port 就改好了）。
    d += "## TLS 栈（reqwest 拉 openssl-sys 在 OHOS 上是必死项）\n"
    d += "- 症状（两串常同时出现）：`Could not find directory of OpenSSL installation`、"
    d += "`pkg-config has not been configured to support cross-compilation`；"
    d += "紧随其后的 custom build command 是 `openssl-sys`。\n"
    d += "- 根因：`reqwest` 的**默认特性**含 `default-tls`（→ native-tls → openssl-sys）。"
    d += "工程里写了 `features = [… \"rustls-tls\" …]` **不等于**关掉了它，两个后端会同时进依赖树。\n"
    d += "- 处置：`t2h:port` 的 **R2-PORT-016** 已经自动改——加 `default-features = false`、"
    d += "补 `rustls-tls`，并把 `charset` / `http2` / `system-proxy` 这些**纯 Rust 的默认项补回来**"
    d += "（否则是顺手砍特性、改行为）。**先重跑 `port --path . --apply`**，不要手改；"
    d += "它转 guide 说明是 git/path 依赖或 reqwest < 0.11，那时按 `after` 里的模板改。\n"
    d += "- 自查（改完这条应为空）：`cargo tree --target aarch64-unknown-linux-ohos -i openssl-sys`。\n"
    d += "- **死路，别走**：去装 OpenSSL、给 pkg-config 配 `PKG_CONFIG_ALLOW_CROSS`、"
    d += "把 `OPENSSL_DIR` 指到宿主的 OpenSSL——目标平台根本没有它，只会白烧轮次。"
    d += "同理依赖树里出现 `native-tls` / `openssl` crate，都该换成 `rustls`。\n\n"

    // 0.39.100（note-gen-2 实测，2026-11-09）：⑤ build 过了接 ⑥ hap，工具如实报
    // 「找不到鸿蒙工程脚手架 <src-tauri>/gen/ohos/build-profile.json5 —— 先用 cargo tauri ohos init --ci 生成」，
    // 可任务书与技能 references 里**一次都没提 init**（技能只有 `cargo tauri ohos build`）⇒ agent 到这一步
    // 只会撞墙，或去全盘搜 ohos 目录（2026-11-07 那次为找 gen/ohos 全盘扫描、挂死 565s）。
    // 与 §4-130 同一个补法：能力/命令必须进任务书，并写清「哪一步之前必须有它」。
    d += "## 装配 HAP 前：鸿蒙脚手架必须先生成\n"
    d += "- 判据只有一处：`<工程>/src-tauri/gen/ohos/build-profile.json5` 存在"
    d += "（扁平布局工程就是 `<工程>/gen/ohos/build-profile.json5`）。没有它，`hap` 会在前置检查里"
    d += "**1 秒内**如实报「找不到鸿蒙工程脚手架」，根本不会进 hvigor —— 看到这句就补脚手架，别去查签名或 SDK。\n"
    d += "- 生成：在 `src-tauri` 目录下跑 `cargo tauri ohos init --ci`（需要 tauri-cli 的 OHOS 分支）；"
    d += "工程本来就有 `ohos` 分支或已提交的 `gen/ohos` 时，从那里取回，别重新 init。\n"
    d += "- **别删掉整个 `gen/ohos` 再 init**：签名材料与 `bundleName` 都挂在 `build-profile.json5` 上，"
    d += "重生成等于把它们清掉，`hap` 会改报签名类错误（下一节）。要么在它上面改，要么先备份。\n"
    // 0.39.100（note-gen-2 实测）：脚手架是**后生成**的，而 `port --apply` 跑在它还不存在的时候
    // ⇒ R2-PORT-015 无文件可改 ⇒ 新 hvigorfile.ts 带着 tauri 钩子，hap 直接死在 00308018。
    // 生成类命令会把你做过的改造覆盖回去，**顺序必须写死**。
    d += "- **脚手架就位后必须重跑一次改造**：`port --path . --apply`（幂等，带标记即跳过）。"
    d += "它在注掉 `gen/ohos/entry/hvigorfile.ts` 里的 tauri Rust 钩子（规则 R2-PORT-015）——"
    d += "那条钩子跑 `cargo tauri ohos dev-eco-studio-script`，要读 dev server 的 addr 文件，"
    d += "非 dev 场景必 panic ⇒ hvigor `00308018 Unknown Error`。\n"
    d += "  判据：看 `hvigorfile.ts` 里 `afterRun(buildRustCode)` 那行**还在不在**、同目录有没有 `.bak`"
    d += "与 `lingqu: R2-PORT-015` 标记；**「规则存在」不等于「已经注过」**。\n"
    d += "- 「有脚手架」≠「能装配」：通过只看 `hap` 落档的 `built` 与 `gates.failures`；"
    d += "`built=true` 之后还要点名 `libs/arm64-v8a/lib<模块名>.so` 在不在。\n\n"

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
    d += "- `9568322 signature verification failed due to not trusted app source` → 三种，先分清是哪种：" +
        "① **release profile 不含 device-ids（正常，别修）**；" +
        "② debug 材料里没有本机 UDID（用 `--auto` 注册设备）；" +
        "③ **签 HAP 用的证书 ≠ profile 里绑的证书**（复用云端同名证书时本地 `.cer` 还是更早那张，" +
        "`sign --auto` 现在会自检并重下；重下后仍报就说明 `.p12` 与证书不是一把钥匙 → " +
        "`sign --auto --newKeys` 换一套材料）；" +
        "**注意「设备上装着同包名的另一套签名」报的是 `9568332`（见下一条），别混**；\n"
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
 * R-1 的监管态提醒（0.39.129）：连撞 ≥2 步而 `.lingqu/notes/` 还是空的 → 提醒一句。
 *
 * 为什么需要它：0.39.120 首轮取证——EcoPaste 连撞 4 次坑，notes / diagnose / pr 三个目录全空，
 * 界面只写"步骤失败"，看不出"机制在位但 agent 没在用"。任务书纪律（0.39.126）是"要求"侧，
 * 这是"观测"侧：撞了坑没落经验，界面上必须说出来。
 *
 * 判据：失败步 = `ran && !ok && skipped == ""`（跳过是环境事实，如没插设备，不算撞坑）；
 * `notesPresent=true`（agent 在用飞轮）→ 不提醒。纯函数，便于单测。
 */
public func flywheelHintOf(rows: ArrayList<MigrateRow>, notesPresent: Bool): String {
    if (notesPresent) {
        return ""
    }
    var failed: Int64 = 0
    for (r in rows) {
        if (r.ran && !r.ok && r.skipped == "") {
            failed += 1
        }
    }
    if (failed < 2) {
        return ""
    }
    return "已 ${failed} 步失败而 `.lingqu/notes/` 还是空的——按任务书纪律，让 agent 先落经验（`lingqu-cli notes append` / `diagnose`）再重试（R-1：机制在位 ≠ 会用）"
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
 * 「已交接」判定（纯函数，0.39.88）。
 *
 * 为什么需要：`isStalled` 只认"落档连续不变"，而 0.39.87 实测的现场是**没人推、也没人知道**——
 * agent 自己 `turn_done`（rounds=33 / tools=32）之后交了报告就收工，监管态却仍显示
 * 「进行中：正在处理「交叉编译」」，`stalled=false / finished=false`，用户盯着屏幕以为它在干活。
 * 这不是绕圈（它没在动），也不是完工（活没干完），是**第三态：已交接**。
 *
 * 三条同时成立才算，任何一条不成立都不许报（宁可晚报，不可谎报）：
 *   turnEnded     轨迹最后一条是 `turn_done` —— 这一轮真的收了
 *   !allConcluded 8 步还有没结论的 —— 活确实没干完
 *   !busy         没有工具在跑 —— 不是"正在干活"
 */
public func handoffDue(turnEnded: Bool, allConcluded: Bool, busy: Bool): Bool {
    return turnEnded && !allConcluded && !busy
}

/** 交接时的一句话结论（纯函数）：说清「谁停了 / 到哪一步 / 该谁接手」 */
public func autoportHandoffVerdict(rows: ArrayList<MigrateRow>): String {
    let done = autoportDoneCount(rows)
    let total = Int64(rows.size)
    var failed = ""
    for (r in rows) {
        if (r.ran && !r.ok && r.skipped.size == 0 && failed.size == 0) {
            failed = r.title
        }
    }
    var at = ""
    if (failed.size > 0) {
        at = "，卡在「${failed}」"
    }
    return "AI 本轮已收尾（自己认为无法再推进）——已交接给你：${done}/${total} 步有结论${at}"
}

/** 交接时升级给人的那句话（纯函数）：与「停滞 / 超预算」同一处上屏，说清下一步怎么做 */
public func handoffEscalation(rows: ArrayList<MigrateRow>): String {
    let done = autoportDoneCount(rows)
    let total = Int64(rows.size)
    return "这一轮 AI 已经自己收工，迁移没做完（${done}/${total}）：先把最后那条工具报错修掉再点「继续」，" +
        "或者直接接管；光等它不会自己再动。"
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
