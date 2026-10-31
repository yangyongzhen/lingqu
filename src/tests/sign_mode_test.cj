package lingqu.tests

import lingqu.compiler.*

/*
 * T5-4 签名两态（debug / release）的纯函数单测。
 *
 * 守的口径：
 *   ① 两态的**用途不同**：debug 能直装不能上架，release 能上架不能直装——判反了后果都很贵；
 *   ② 判不出来就说"未判定"（unknown），**不猜 debug**（猜错会让人以为能装机）；
 *   ③ debug 态的提醒必须出现"不能上架 + 切回 release"，否则这条提醒等于没有；
 *   ④ 本机没有 release profile 时，下一步要写明"先去 AGC 生成材料"，而不是"切一下开关"。
 */

@Test
public func testJudgeSignMode(): Unit {
    // 没配 signingConfigs → 无从判断，给 unknown
    @Assert(judgeSignMode(false, "debug"), "unknown")
    @Assert(judgeSignMode(false, ""), "unknown")
    // 配了且能读出 profile 类型
    @Assert(judgeSignMode(true, "debug"), "debug")
    @Assert(judgeSignMode(true, "release"), "release")
    // 读不出类型（坏文件/旧格式）→ unknown，不猜
    @Assert(judgeSignMode(true, ""), "unknown")
    @Assert(judgeSignMode(true, "enterprise"), "unknown")
    // 大小写不宽容：profile 里的 type 是固定小写，别把 "Release" 当成 release
    @Assert(judgeSignMode(true, "Release"), "unknown")

    @Assert(signModeLabel("debug"), "debug（开发直装）")
    @Assert(signModeLabel("release"), "release（上架）")
    @Assert(signModeLabel("unknown"), "未判定")
    @Assert(signModeLabel(""), "未判定")
}

@Test
public func testSignRemindersCoverBothModes(): Unit {
    let d = signModeReminder("debug")
    // debug 态：必须说清"不能上架"并指向 release
    @Assert(d.contains("不能上架"), true)
    @Assert(d.contains("release"), true)
    @Assert(d.contains("debug"), true)

    let r = signModeReminder("release")
    // release 态：必须说清"可以上架"且"直装被拒是正常的"（否则人会去乱改）
    @Assert(r.contains("可以上架"), true)
    @Assert(r.contains("9568322"), true)
    @Assert(r.contains("正常"), true)

    let u = signModeReminder("unknown")
    @Assert(u.contains("无法判定"), true)
    @Assert(u.contains("签名体检"), true)
    // 空串与未知态同样处理（不返回空提醒，界面上不能出现空白）
    @Assert(signModeReminder(""), u)
}

@Test
public func testAssessSignModeDebug(): Unit {
    let st = assessSignMode(true, true, "debug", 0)
    @Assert(st.mode, "debug")
    @Assert(st.canInstallDevice, true)
    // debug 态**不能上架**——这是 T5-4 的核心结论
    @Assert(st.releaseReady, false)
    @Assert(st.reminder.contains("不能上架"), true)
    @Assert(st.installNextStep.contains("hdc install"), true)
    // 本机 0 份 release profile：下一步必须是"先去生成材料"，不是"切开关"
    @Assert(st.releaseNextStep.contains("还没有 release profile"), true)
    // 切 release 的步骤要够具体（照做能成事，至少 5 步）
    @Assert(st.switchSteps.size >= 5, true)
    var text = ""
    for (s in st.switchSteps) {
        text += s + "\n"
    }
    @Assert(text.contains("release profile"), true)
    @Assert(text.contains("build-profile.json5"), true)
    @Assert(text.contains("装配 HAP"), true)

    // 本机已有 release 材料时，说法要变（别一直说"没有"）
    let st2 = assessSignMode(true, true, "debug", 2)
    @Assert(st2.releaseNextStep.contains("2 份"), true)
    // 材料缺失 → 还不能直装（配置在、文件不在）
    let st3 = assessSignMode(true, false, "debug", 0)
    @Assert(st3.canInstallDevice, false)
    @Assert(st3.releaseReady, false)
}

@Test
public func testAssessSignModeRelease(): Unit {
    let st = assessSignMode(true, true, "release", 3)
    @Assert(st.mode, "release")
    // release 态可以上架、不能直装（profile 不含 device-ids）
    @Assert(st.releaseReady, true)
    @Assert(st.canInstallDevice, false)
    @Assert(st.reminder.contains("可以上架"), true)
    // 想装真机 → 给出切回 debug 的步骤
    @Assert(st.installNextStep.contains("切回 debug"), true)
    @Assert(st.switchSteps.size >= 3, true)
    var text = ""
    for (s in st.switchSteps) {
        text += s + "\n"
    }
    @Assert(text.contains("debug"), true)
    // release profile 份数要如实回投（界面上显示"本机 release profile：3 份"）
    @Assert(st.releaseProfileCount, 3)
}

@Test
public func testAssessSignModeUnknown(): Unit {
    let st = assessSignMode(false, false, "", 0)
    @Assert(st.mode, "unknown")
    @Assert(st.modeLabel, "未判定")
    @Assert(st.canInstallDevice, false)
    @Assert(st.releaseReady, false)
    @Assert(st.reminder.contains("无法判定"), true)
    // 两个方向的下一步都要给出（先配签名，再谈装/上架）
    @Assert(st.installNextStep != "", true)
    @Assert(st.releaseNextStep != "", true)
    @Assert(st.switchSteps.size > 0, true)
    // 序列化必须带齐字段（`t2h:sign` 的落档与 ui_report 直接吃这份 JSON）
    let json = st.toJson().toJsonString()
    @Assert(json.contains("\"mode\""), true)
    @Assert(json.contains("\"releaseReady\""), true)
    @Assert(json.contains("\"switchSteps\""), true)
}
