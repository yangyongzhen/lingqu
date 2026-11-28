package lingqu.tests

import std.collection.*
import lingqu.compiler.*

/*
 * T5-5 单测：hdc 输出解析（纯函数，D-009）。
 * fixture 全部是 2026-10-31 在真机上抓到的**原始输出**（鸿蒙 PC HAD-W32 / HarmonyOS 7.0.0.111 / API 26）。
 */

/*
 * 0.39.149：无线调试下 `hdc list targets -v` 会偶发只列 `COM1/COM2` 串口噪声、甚至整段为空，
 * 而同一时刻 `hdc list targets` 有设备（用户实测：真机已连，cjh 却去启模拟器）。
 * 判据：`-v` 解析出设备就用 `-v`（带 state），否则回落纯列表。
 */
@Test
public func testMergeHdcTargetsFallsBackToPlainList(): Unit {
    let verboseNoise = "COM1\t\tUART\tReady\tunknown...\thdc\nCOM2\t\tUART\tReady\tunknown...\thdc\n"
    let plainWithDev = "192.168.3.13:46163\n"
    // ① -v 只有噪声 → 回落纯列表，能解析出那台真机
    let devs = parseHdcTargets(mergeHdcTargetsTextOf(verboseNoise, plainWithDev))
    @Assert(devs.size, 1)
    @Assert(devs[0].serial, "192.168.3.13:46163")
    // ② -v 有设备 → 用 -v（不信纯列表那份，避免两份口径打架）
    let verboseDev = "192.168.3.13:46163\t\tTCP\tConnected\tlocalhost\thdc\n"
    let m2 = parseHdcTargets(mergeHdcTargetsTextOf(verboseDev, "3QC0124B20000048\n"))
    @Assert(m2.size, 1)
    @Assert(m2[0].serial, "192.168.3.13:46163")
    // ③ 两边都没设备 → 原样返回 -v（保留噪声便于看现场），解析结果仍是 0 台
    @Assert(parseHdcTargets(mergeHdcTargetsTextOf(verboseNoise, "[Empty]\n")).size, 0)
}

@Test
public func testParseHdcTargetsSkipsSerialNoise(): Unit {
    // 真实输出：真设备一行 + 两条 COM/UART 噪声（本项目踩过"把 COM 口当设备"的坑）
    let text = "3QC0124B20000048\t\tUSB\tConnected\tlocalhost\thdc\nCOM1\t\tUART\tReady\tunknown...\thdc\nCOM2\t\tUART\tReady\tunknown...\thdc\n"
    let devs = parseHdcTargets(text)
    @Assert(devs.size, 1)
    @Assert(devs[0].serial, "3QC0124B20000048")
    // 空态
    @Assert(parseHdcTargets("[Empty]\n").size, 0)
    // 纯 COM 号（没有 UART 字样）也要挡掉
    @Assert(parseHdcTargets("COM12\n").size, 0)
    // TCP 目标（无线调试）要保留
    let tcp = parseHdcTargets("127.0.0.1:5555\t\tTCP\tConnected\n")
    @Assert(tcp.size, 1)
    @Assert(tcp[0].serial, "127.0.0.1:5555")
}

/*
 * 0.39.131 真机实测（SLG-W10 无线调试）：落档里记的是 USB 序列号，设备换到无线后
 * 每条 hdc 命令都回 `[Fail]Not match target founded, check connect-key please`，
 * probe 枚举 0 个节点、verify 采证三条全挂却仍报「已保存」。判据改成"以在线目标为准"。
 */

@Test
public func testResolveDeviceKeyPrefersLiveWhenRecordedStale(): Unit {
    // 现场原始输出：无线目标在线 + 两条串口噪声；落档里是 USB 时代那条序列号
    let live = "192.168.3.105:46163\t\tTCP\tConnected\tlocalhost\thdc\nCOM1\t\tUART\tReady\tunknown...\thdc\nCOM2\t\tUART\tReady\tunknown...\thdc\n"
    @Assert(resolveDeviceKeyOf(live, "3QC0124B20000048"), "192.168.3.105:46163")
}

@Test
public func testResolveDeviceKeyKeepsRecordedWhenStillOnline(): Unit {
    // 落档序列号仍在在线列表里 → 保持原键（历史证据与本次取证的键一致）
    let live = "3QC0124B20000048\t\tUSB\tConnected\tlocalhost\thdc\n192.168.3.105:46163\t\tTCP\tConnected\n"
    @Assert(resolveDeviceKeyOf(live, "3QC0124B20000048"), "3QC0124B20000048")
}

@Test
public func testResolveDeviceKeyFallsBackToRecordedWithoutLive(): Unit {
    // 解析不到在线设备（空态 / 只有串口噪声）→ 沿用落档值，不比旧行为更差
    @Assert(resolveDeviceKeyOf("[Empty]\n", "3QC0124B20000048"), "3QC0124B20000048")
    @Assert(resolveDeviceKeyOf("COM1\t\tUART\tReady\tunknown...\thdc\n", "3QC0124B20000048"), "3QC0124B20000048")
    // 落档也没有：给空串，让调用方按"没有可用设备"处置，而不是拿垃圾键去跑命令
    @Assert(resolveDeviceKeyOf("", ""), "")
}

@Test
public func testResolveDeviceKeyUsesLiveWhenNoRecord(): Unit {
    // 首次连接（还没有部署落档）：直接用在线目标，不必等落档
    @Assert(resolveDeviceKeyOf("192.168.3.105:46163\t\tTCP\tConnected\n", ""), "192.168.3.105:46163")
}

@Test
public func testParseInstallFailureSigningCode(): Unit {
    // 真实失败输出：用 OpenHarmony 默认材料签名后直装（未绑定设备）被拒
    let text = "[Info]App install path:E:\\x\\entry-default-signed.hap msg:error: failed to install bundle. code:9568322 error: signature verification failed due to not trusted app source. \nAppMod finish\n"
    let step = parseInstallResult(text, 0)  // 注意：hdc 失败时退出码仍是 0！
    @Assert(step.ok, false)
    @Assert(step.failCode, 9568322)
    @Assert(step.detail.contains("9568322"), true)
    // 失败码要带可执行处置（与 FP-012 口径一致）
    @Assert(step.detail.contains("device-ids") || step.detail.contains("调试签名"), true)
}

@Test
public func testParseInstallUnknownCodeIsFailure(): Unit {
    // 0.39.109 真机实测输出：9568423 = 本机 UDID 不在 profile 的 device-ids 里。
    // 修前 hdcFailCodeOf 只认 5 个硬编码码 ⇒ 回 0 ⇒ ok 被兜底成 true，
    // 于是 deploy 报「installed=true」并继续 aa start（起的其实是设备上的旧版本）。
    let text = "[Info]App install path:E:\\x\\entry-default-signed.hap msg:error: failed to install bundle. code:9568423 error: device is unauthorized, make sure the UDID of your device is configured in the signing profile. \nAppMod finish\n"
    let step = parseInstallResult(text, 0)
    @Assert(step.ok, false)
    @Assert(step.failCode, 9568423)
    @Assert(step.detail.contains("UDID"), true)
}

@Test
public func testGenericFailCodeOf(): Unit {
    @Assert(genericFailCodeOf("msg:error: failed to install bundle. code:9568423 x"), 9568423)
    @Assert(genericFailCodeOf("code:10106102"), 10106102)
    // 短数字不算失败码（避开 code: 0 这类正常字段）
    @Assert(genericFailCodeOf("code: 0"), 0)
    @Assert(genericFailCodeOf("all good"), 0)
}

@Test
public func testHdcErrorTextSeen(): Unit {
    @Assert(hdcErrorTextSeen("error: failed to install bundle. code:1"), true)
    @Assert(hdcErrorTextSeen("failed to start ability"), true)
    @Assert(hdcErrorTextSeen("msg:install bundle successfully."), false)
    @Assert(hdcErrorTextSeen("msg:start ability successfully."), false)
}

@Test
public func testParseInstallSuccess(): Unit {
    // 真实成功输出：用绑定本机 UDID 的 debug 材料签名后安装
    let text = "[Info]App install path:E:\\x\\entry-default-signed.hap msg:install bundle successfully. \nAppMod finish\n"
    let step = parseInstallResult(text, 0)
    @Assert(step.ok, true)
    @Assert(step.failCode, 0)
}

@Test
public func testParseStartResult(): Unit {
    // 真实成功输出
    @Assert(parseStartResult("start ability successfully.\n", 0).ok, true)
    @Assert(parseStartResult("StartAbility success\n", 0).ok, true)
    @Assert(parseStartResult("Operation successful\n", 0).ok, true)
    // 失败 + 锁屏码
    let locked = parseStartResult("error: failed to start ability. code:10106102\n", 0)
    @Assert(locked.ok, false)
    @Assert(locked.failCode, 10106102)
    @Assert(locked.detail.contains("解锁"), true)
}

@Test
public func testHilogTailAndHealth(): Unit {
    let log = "a\n\nb\n  \nc\nd\ne"
    let tail = hilogTail(log, 2)
    @Assert(tail.size, 2)
    @Assert(tail[0], "d")
    @Assert(tail[1], "e")
    // 请求多于现有行 → 全给
    @Assert(hilogTail(log, 99).size, 5)
    @Assert(hilogTail("", 3).size, 0)
    // 健康判断：出现 panic / SIGABRT 即不健康
    @Assert(hilogLooksHealthy("normal logs"), true)
    @Assert(hilogLooksHealthy("[panic] boom"), false)
    @Assert(hilogLooksHealthy("E SIGABRT"), false)
    @Assert(hilogLooksHealthy("FATAL EXCEPTION: main"), false)
}

@Test
public func testHdcFailCodeTable(): Unit {
    @Assert(hdcFailCodeOf("x 9568322 y"), 9568322)
    @Assert(hdcFailCodeOf("error 9568269"), 9568269)
    @Assert(hdcFailCodeOf("code:10106102"), 10106102)
    @Assert(hdcFailCodeOf("all good"), 0)
    @Assert(hdcFailHintOf(9568322).contains("签名"), true)
    @Assert(hdcFailHintOf(9568269).contains("目录"), true)
    @Assert(hdcFailHintOf(0), "")
}

/* ---------- 部署判定（t2h:deploy 的结论层） ---------- */

@Test
public func testJudgeDeployHappyPath(): Unit {
    let v = judgeDeploy(true, true, true, true, "3QC0124B20000048", 0)
    @Assert(v.ok, true)
    @Assert(v.reason.contains("安装 + 启动成功"), true)
    @Assert(v.nextStep.contains("截图"), true)
}

@Test
public func testJudgeDeployOrderedFailures(): Unit {
    // ① 没设备：最靠前，且要提示串口噪声坑
    let noDev = judgeDeploy(false, false, false, true, "", 0)
    @Assert(noDev.ok, false)
    @Assert(noDev.reason.contains("没有在线设备"), true)
    @Assert(noDev.nextStep.contains("USB"), true)
    // ② 装不上：报失败码 + 对应处置（9568322 = 签名不可信）
    let badSign = judgeDeploy(true, false, false, true, "SN1", 9568322)
    @Assert(badSign.ok, false)
    @Assert(badSign.reason.contains("9568322"), true)
    @Assert(badSign.nextStep.contains("签名"), true)
    // 装不上但没失败码 → 指向落档日志
    let noCode = judgeDeploy(true, false, false, true, "SN1", 0)
    @Assert(noCode.nextStep.contains(".lingqu/deploy"), true)
    // ③ 装上了但启动失败：要点明「不是签名问题」，避免误诊
    let badStart = judgeDeploy(true, true, false, true, "SN1", 0)
    @Assert(badStart.ok, false)
    @Assert(badStart.reason.contains("启动失败"), true)
    @Assert(badStart.reason.contains("不是签名问题"), true)
    @Assert(badStart.nextStep.contains("EntryAbility"), true)
    // ④ 启了但日志有崩溃：指向 faultlog（缺 .so / 资源这类真机坑）
    let crashed = judgeDeploy(true, true, true, false, "SN1", 0)
    @Assert(crashed.ok, false)
    @Assert(crashed.reason.contains("崩溃"), true)
    @Assert(crashed.nextStep.contains("faultlog"), true)
}
// ===== 0.39.150：Offline / Unauthorized 的目标不算"在线设备" =====

@Test
public func offlineTargetIsNotCountedAsOnline(): Unit {
    // 现场原文：`hdc list targets` 是 [Empty]，`-v` 却有一条 Offline，任务书曾据此写「真机：在线」
    let verboseOffline = "192.168.3.13:46163\t\tTCP\tOffline\tunknown...\thdc\n"
    let devs = parseHdcTargets(verboseOffline)
    @Assert(devs.size, 1)
    // ① state 必须是 Offline（旧实现取行尾字段，拿到的是 hdc）
    @Assert(devs[0].state, "Offline")
    @Assert(devs[0].usable(), false)
    // ② 在线判据只认能用的
    @Assert(onlineHdcTargetsOf(verboseOffline).size, 0)
    // ③ -v 只有 Offline、纯列表 [Empty] ⇒ 合并后仍是 0 台能用
    @Assert(onlineHdcTargetsOf(mergeHdcTargetsTextOf(verboseOffline, "[Empty]\n")).size, 0)
    // ④ connect-key 不许再选那台离线的（旧行为会拿它去 hdc -t，必然 Not match target founded）
    @Assert(resolveDeviceKeyOf(verboseOffline, ""), "")
    // ⑤ 对照组：Connected 就算在线，且沿用落档号
    let verboseOk = "192.168.3.13:46163\t\tTCP\tConnected\tunknown...\thdc\n"
    @Assert(onlineHdcTargetsOf(verboseOk).size, 1)
    @Assert(resolveDeviceKeyOf(verboseOk, "192.168.3.13:46163"), "192.168.3.13:46163")
    // ⑥ 未授权（Unauthorized）同样不算在线
    @Assert(onlineHdcTargetsOf("X1\t\tUSB\tUnauthorized\tunknown...\thdc\n").size, 0)
    // ⑦ 老口径保留：列表整段空白（hdc 不可用）时沿用落档，不凭空说"没有设备"
    @Assert(resolveDeviceKeyOf("", "3QC0124B20000048"), "3QC0124B20000048")
}
