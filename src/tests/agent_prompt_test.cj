package lingqu.tests

import lingqu.*
import stdx.encoding.json.*

/*
 * G1+G2（失败自动诊断）与 G4（决策回写）的纯函数单测。
 *
 * 这一层的价值全在"现场是不是真的"：
 *   · 提问里的数字必须来自落档（读不到就写"不存在"，不许编）
 *   · 截断必须落在字符边界（切坏半个汉字 = 发出去的证据本身是坏的）
 *   · 决策块解析必须**容忍坏块但不静默成功**（坏 JSON 跳过，不算解析成功）
 */

@Test
public func testStepLogPath(): Unit {
    // 有整篇日志的步骤
    @Assert(taskStepLogPath("habit-tree", "build"), ".lingqu/build/habit-tree.log")
    @Assert(taskStepLogPath("habit-tree", "hap"), ".lingqu/hap/habit-tree.log")
    @Assert(taskStepLogPath("habit-tree", "deploy"), ".lingqu/deploy/habit-tree.log")
    // scan/deps 只落 json，port 落的是备份目录 + decisions.json——都没有整篇日志
    @Assert(taskStepLogPath("habit-tree", "scan"), "")
    @Assert(taskStepLogPath("habit-tree", "deps"), "")
    @Assert(taskStepLogPath("habit-tree", "port"), "")
    // 边界：未知步骤 / 空工程名
    @Assert(taskStepLogPath("habit-tree", "nope"), "")
    @Assert(taskStepLogPath("", "build"), "")
}

@Test
public func testTailLines(): Unit {
    let text = "l1\nl2\nl3\nl4\nl5"
    @Assert(tailLinesOf(text, 2), "l4\nl5")
    // 行数不足：原样返回（不要补空行）
    @Assert(tailLinesOf(text, 99), text)
    // CRLF 归一：落档里的日志是 Windows 工具写的，行尾常是 \r\n
    @Assert(tailLinesOf("a\r\nb\r\nc", 2), "b\nc")
    // 边界
    @Assert(tailLinesOf(text, 0), "")
    @Assert(tailLinesOf("", 3), "")
}

@Test
public func testClipCharsIsCharSafe(): Unit {
    // 中文按**字符**切，不是按字节（一个汉字 3 字节，按字节切会切出半个字符）
    @Assert(clipCharsOf("灵渠迁移台", 2), "灵渠")
    @Assert(clipCharsOf("灵渠迁移台", 99), "灵渠迁移台")
    // 中英混排：切点必须落在字符边界
    @Assert(clipCharsOf("a灵b", 2), "a灵")
    @Assert(clipCharsOf("a灵b", 3), "a灵b")
    // 边界
    @Assert(clipCharsOf("abc", 0), "")
    @Assert(clipCharsOf("", 5), "")
}

@Test
public func testAutoAskStepAllowed(): Unit {
    // scan 不自动问：它失败通常是"路径填错"，AI 看落档也看不出来
    @Assert(autoAskStepAllowed("scan"), false)
    for (s in ["deps", "port", "build", "hap", "sign", "deploy", "verify"]) {
        @Assert(autoAskStepAllowed(s), true)
    }
    @Assert(autoAskStepAllowed("nope"), false)
}

@Test
public func testStepCaveatCoversCriticalSteps(): Unit {
    // 判据必须提到本仓踩过的坑，否则模型会拿通用经验乱下结论
    @Assert(stepAskCaveat("sign").contains("debug"), true)
    @Assert(stepAskCaveat("hap").contains("lib"), true)
    @Assert(stepAskCaveat("deploy").contains("退出码"), true)
    @Assert(stepAskCaveat("verify").contains("分母"), true)
    @Assert(stepAskCaveat("build").contains("stderr"), true)
    @Assert(stepAskCaveat("nope"), "")
}

@Test
public func testAutoAskPromptCarriesEvidenceAndInstructions(): Unit {
    let b = StepBrief()
    b.project = "habit-tree"
    b.projectDir = "E:/test/rust/habit-tree"
    b.step = "hap"
    b.stepTitle = "HAP 装配"
    b.note = "HAP 0 字节 / arm64 库条目 0 个"
    b.artifact = ".lingqu/hap/habit-tree.json"
    b.artifactExists = true
    b.artifactClip = "{\"built\":false}"
    b.logPath = ".lingqu/hap/habit-tree.log"
    b.logTail = "BUILD FAILED"
    let p = buildAutoAskPrompt(b)
    // 现场四要素
    @Assert(p.contains("habit-tree"), true)
    @Assert(p.contains("E:/test/rust/habit-tree"), true)
    @Assert(p.contains("HAP 0 字节"), true)
    @Assert(p.contains(".lingqu/hap/habit-tree.json"), true)
    @Assert(p.contains("BUILD FAILED"), true)
    // 判据（该步的坑）必须带上
    @Assert(p.contains("lib<模块名>.so"), true)
    // 三条指令：根因 / lingqu-cli / 决策块
    @Assert(p.contains("根因"), true)
    @Assert(p.contains("lingqu-cli"), true)
    @Assert(p.contains("lingqu-decision"), true)
    @Assert(p.contains("不要编造"), true)
}

@Test
public func testAutoAskPromptDegradesHonestly(): Unit {
    // 落档/日志都缺时：如实写"不存在""没找到"，不许出现空行冒充实证
    let b = StepBrief()
    b.project = "x"
    b.step = "build"
    b.stepTitle = "交叉编译"
    let p = buildAutoAskPrompt(b)
    @Assert(p.contains("不存在"), true)
    @Assert(p.contains("没找到内容"), true)
    @Assert(p.contains("没有可用的判定字段"), true)
    // 没有落档正文/日志就不该冒出空的 json/text 围栏
    @Assert(p.contains("```json"), false)
    @Assert(p.contains("```text"), false)
}

@Test
public func testParseDecisionBlocksMainPath(): Unit {
    let text = "先说结论。\n\n```lingqu-decision\n" +
        "{\"rule\":\"reqwest 用 rustls\",\"decision\":\"accepted\",\"why\":\"ohos 无 openssl\"}\n```\n\n收尾。"
    let arr = parseDecisionBlocks(text)
    @Assert(arr.size, 1)
    @Assert(arr[0].rule, "reqwest 用 rustls")
    @Assert(arr[0].decision, "accepted")
    @Assert(arr[0].why, "ohos 无 openssl")
}

@Test
public func testParseDecisionBlocksSkipsBadBlocks(): Unit {
    // 坏 JSON / 缺 rule / decision 不认识 / 空块 → 全部跳过，但好块照抓
    let text = "```lingqu-decision\nnot json\n```\n" +
        "```lingqu-decision\n{\"decision\":\"accepted\"}\n```\n" +
        "```lingqu-decision\n{\"rule\":\"r\",\"decision\":\"maybe\"}\n```\n" +
        "```lingqu-decision\n\n```\n" +
        "```lingqu-decision\n{\"rule\":\"ok\",\"decision\":\"ignored\"}\n```\n"
    let arr = parseDecisionBlocks(text)
    @Assert(arr.size, 1)
    @Assert(arr[0].rule, "ok")
    @Assert(arr[0].decision, "ignored")
    // 没有 why 也是合法的（提案可以不解释）
    @Assert(arr[0].why, "")
}

@Test
public func testParseDecisionBlocksDedupesAndToleratesMissingFenceEnd(): Unit {
    // 同 rule 后者覆盖（与 t2h:decisions record 的覆盖语义一致）
    let text = "```lingqu-decision\n{\"rule\":\"r1\",\"decision\":\"accepted\"}\n```\n" +
        "```lingqu-decision\n{\"rule\":\"r1\",\"decision\":\"ignored\",\"why\":\"改了主意\"}\n```"
    let arr = parseDecisionBlocks(text)
    @Assert(arr.size, 1)
    @Assert(arr[0].decision, "ignored")
    // 边界：没有围栏 / 空文本
    @Assert(parseDecisionBlocks("普通回复，没提议案").size, 0)
    @Assert(parseDecisionBlocks("").size, 0)
}

@Test
public func testDecisionProposalLine(): Unit {
    @Assert(decisionProposalLine(DecisionProposal("r", "accepted", "why")), "建议采纳｜r（why）")
    @Assert(decisionProposalLine(DecisionProposal("r", "ignored", "")), "建议忽略｜r")
}

@Test
public func testAutoRunAllowlistIsStricterThanCliRunAllowed(): Unit {
    let empty = JsonObject()
    // 只读/幂等：自动执行放开
    for (c in ["scan", "deps", "sign", "verify", "report", "batch", "resume", "env", "diagnose"]) {
        @Assert(cliAutoRunAllowed(c, empty), true)
    }
    // build 允许人点一下就跑（cliRunAllowed=true），但**不能**自动跑：分钟级且产物会覆盖
    let (buildOk, _) = cliRunAllowed("build", empty)
    @Assert(buildOk, true)
    @Assert(cliAutoRunAllowed("build", empty), false)
    // 改工程 / 动真机 / 写签名配置：两条都必须拒（合取）
    for (c in ["port", "revert", "hap", "deploy", "decisions"]) {
        @Assert(cliAutoRunAllowed(c, empty), false)
    }
    let apply = JsonObject()
    apply.put("apply", JsonBool(true))
    let (signApplyOk, _) = cliRunAllowed("sign", apply)
    @Assert(signApplyOk, false)
    @Assert(cliAutoRunAllowed("sign", apply), false)
    // 未知命令不许自动跑（别把"没听过"当"只读"）
    @Assert(cliAutoRunAllowed("rm_rf", empty), false)
}
