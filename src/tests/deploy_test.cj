package lingqu.tests

import std.collection.*
import lingqu.compiler.*
import lingqu.port.*

/*
 * T5-5 单测：hdc 输出解析（纯函数，D-009）。
 * fixture 全部是 2026-10-31 在真机上抓到的**原始输出**（鸿蒙 PC HAD-W32 / HarmonyOS 7.0.0.111 / API 26）。
 */

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
