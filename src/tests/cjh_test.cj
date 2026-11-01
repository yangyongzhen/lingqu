package lingqu.tests

import std.collection.*
import lingqu.*

/*
 * cjh 引擎托管的纯函数单测（D-009：只测纯函数，进程/网络以实机为准）。
 *
 * 这里只覆盖"vendor 目录怎么找"——2026-10-31 便携包实测的坑：
 * `vendor/cjh/win-x64` 是相对**当前工作目录**解析的，用户双击 exe 或从快捷方式启动时
 * CWD 不是包根，于是文件明明在包里却报「没找到可用的 cjh」。
 * 修法：启动器写 `LINGQU_HOME`（包根），解析时优先用它，最后才退回相对路径。
 */

@Test
public func testCjhVendorDirCandidates(): Unit {
    let isWin = cjhPathSep() == "\\"
    let sub = if (isWin) { "win-x64" } else { "linux-x64" }

    // ① 只给 LINGQU_HOME：包根优先，相对路径兜底
    let a = cjhVendorDirCandidates("C:\\pkg", "")
    @Assert(a.size, 2)
    @Assert(a[0].contains("pkg"), true)
    @Assert(a[0].contains("vendor"), true)
    @Assert(a[0].contains(sub), true)
    @Assert(a[1].startsWith("vendor"), true)

    // ② 两个都给：三个候选，顺序 = LINGQU_HOME → LINGQU_CJH_HOME → 相对
    let b = cjhVendorDirCandidates("C:\\pkg", "C:\\custom")
    @Assert(b.size, 3)
    @Assert(b[0].contains("pkg"), true)
    @Assert(b[1].contains("custom"), true)
    @Assert(b[2].startsWith("vendor"), true)

    // ③ 都不给：只剩相对路径（开发期在仓根跑的老口径，不能破）
    let c = cjhVendorDirCandidates("", "")
    @Assert(c.size, 1)
    @Assert(c[0].startsWith("vendor"), true)
    @Assert(c[0].contains(sub), true)
}

@Test
public func testVendorCandidatesWalkUpFromCwd(): Unit {
    // 直接从产物目录起（targets\desktop\target\release\bin）→ 必须能上溯到仓根
    let base = if (cjhPathSep() == "\\") {
        "C:\\repo\\targets\\desktop\\target\\release\\bin"
    } else {
        "/repo/targets/desktop/target/release/bin"
    }
    let cands = vendorCandidatesFrom(base, 6)
    @Assert(cands.size >= 6, true)
    // 第一层是"当前目录下的 vendor"，最后一层应能到仓根
    @Assert(cands[0].contains("bin"), true)
    var hitRoot = false
    for (c in cands) {
        if (c.contains("repo" + cjhPathSep() + "vendor")) {
            hitRoot = true
        }
    }
    @Assert(hitRoot, true)
    // 末尾分隔符不影响结果（C:\repo\ 与 C:\repo 等价）
    let withSep = vendorCandidatesFrom(base + cjhPathSep(), 1)
    let noSep = vendorCandidatesFrom(base, 1)
    @Assert(withSep[0], noSep[0])
    // 空 base 不产生候选（别造出 "/vendor/cjh/..." 这种绝对路径）
    @Assert(vendorCandidatesFrom("", 6).size, 0)
}

/* ---------- 引擎已在跑时回投「用的是哪一份二进制」 ---------- */

@Test
public func testKnownBinPath(): Unit {
    let env = "D:\\a\\cjh.exe"
    let inst = "C:\\Users\\u\\AppData\\Local\\lingqu\\cjh\\cjh.exe"
    // LINGQU_CJH 优先（用户显式指定就是说"我要这份"）
    @Assert(knownBinPath(env, true, inst, true), env)
    // env 不可读 → 退到安装目录（单文件产物里就是内嵌释放的那份）
    @Assert(knownBinPath(env, false, inst, true), inst)
    // 两条都不可读 → 空串（界面据实显示"来源未知"，不编造路径）
    @Assert(knownBinPath(env, false, inst, false), "")
    // 空串当来源 → 等同没有
    @Assert(knownBinPath("", true, "", true), "")
    // 只有安装目录（env 为空）也要能报出来
    @Assert(knownBinPath("", false, inst, true), inst)
}

/* ---------- 单文件产物的内嵌释放（PE 资源） ---------- */

@Test
public func testShouldUseExtracted(): Unit {
    // 有资源且校验过 → 用
    @Assert(shouldUseExtracted(1, true), true)
    @Assert(shouldUseExtracted(4, true), true)
    // 没有内嵌资源（普通构建）→ 不用，也不算错误
    @Assert(shouldUseExtracted(0, false), false)
    // 释放了但校验不过 → 绝不用（来路不明的同名文件不该被静默执行）
    @Assert(shouldUseExtracted(4, false), false)
}
/**
 * 0.39.42：健康检查的「宽容窗口」。
 *
 * 用户实测：浏览器打得开 8765、WS 也连着，界面却报「AI 引擎缺失」——
 * 某次 `/api/health` 读超时被当成"引擎不存在"。纪律是**判死要有证据**：
 * 只要最近 20 秒内成功探活过，就不许改口说缺失（状态改成 running+unstable）。
 */
@Test
public func testCjhHealthyRecentlyWindow(): Unit {
    // 刚记过一次成功 → 必须算"最近活着"
    noteCjhHealthy()
    @Assert(cjhHealthyRecently(), true)
    // 窗口是正的（常量被改成 0 或负数就等于关闭这条宽容，属于语义破坏）
    @Assert(HEALTH_GRACE_MS > 0, true)
    @Assert(HEALTH_GRACE_MS >= 10000, true)
}