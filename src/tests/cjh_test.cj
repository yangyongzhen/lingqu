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
    @Assert(knownBinPath("", false, env, true, inst, true), env)
    // env 不可读 → 退到安装目录（这次是我们自己解析拉起的：owned=true）
    @Assert(knownBinPath("", true, env, false, inst, true), inst)
    // 两条都不可读 → 空串（界面据实显示"来源未知"，不编造路径）
    @Assert(knownBinPath("", true, env, false, inst, false), "")
    // 空串当来源 → 等同没有
    @Assert(knownBinPath("", true, "", true, "", true), "")
    // 只有安装目录（env 为空）也要能报出来
    @Assert(knownBinPath("", true, "", false, inst, true), inst)
    // **复用别人的实例**（owned=false）时，盘上的安装目录副本与在跑的进程无关 → 报未知
    @Assert(knownBinPath("", false, "", false, inst, true), "")
}

/**
 * 0.39.84：本应用亲手拉起的那份**最权威**。
 *
 * 实测起因：安装目录留着一个内容不符的旧副本（会被 `cjhBinPathResolve` 跳过、绝不执行），
 * 真正在跑的是 `vendor/` 那份；旧实现按"哪条路径可读"回投，界面于是报出那个没在跑的旧副本
 * ——「报的和跑的不一致」。
 */
@Test
public func testKnownBinPathPrefersLaunchedBin(): Unit {
    let env = "D:\\a\\cjh.exe"
    let inst = "C:\\Users\\u\\AppData\\Local\\lingqu\\cjh\\cjh.exe"
    let used = "E:\\work\\lingqu\\vendor\\cjh\\win-x64\\cjh.exe"
    // 自己拉起且记下来了 → 压过 env / 安装目录（哪怕它们都可读）
    @Assert(knownBinPath(used, true, env, true, inst, true), used)
    // 没记下（老路径还没拉起过）→ 退回老口径
    @Assert(knownBinPath("", true, env, true, inst, true), env)
    // 复用的是别人的实例（owned=false）→ 那个 used 不是"当前这份"，不许采信
    @Assert(knownBinPath(used, false, env, true, inst, true), env)
    // 都没有 → 空串
    @Assert(knownBinPath("", true, "", false, "", false), "")
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

/* ---------- 部署目录副本的可用判据（0.39.77） ---------- */

/**
 * 现象：0.39.75 把随包引擎升到 1.6.12，应用却一直跑 `%LOCALAPPDATA%\lingqu\cjh` 里的 1.6.5。
 * 根因：② 档「部署过的安装目录」只判 `fileReadable` 就返回，抢在 ③ 档（vendor，校验过）前面。
 * 判据：**文件在** 与 **内容对** 是两件事，会执行的二进制必须两件都满足。
 */
@Test
public func testInstallBinUsable(): Unit {
    // 主路径：文件在 + 校验通过 → 可用
    @Assert(installBinUsable(true, true), true)
    // 错误路径①：文件在但内容不符（升级前的旧引擎）→ 不可用
    @Assert(installBinUsable(true, false), false)
    // 错误路径②：校验通过但文件不在（删掉了）→ 不可用
    @Assert(installBinUsable(false, true), false)
    // 边界：两个都不成立（没部署过）→ 不可用，且不该算错误
    @Assert(installBinUsable(false, false), false)
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
/**
 * 0.39.82：拉起前的三态决策。
 *
 * 用户实测事故（2026-11-07）：迁移跑到一半，界面报「引擎还没起来」，应用自己又拉起一只，
 * 机器上留下 3 只 `cjh.exe` 同时监听 8765。根因是判据只有 Bool——**「端口空着」与
 * 「端口有人听但不响应」都返回 false**，调用方于是都当成"没有引擎，拉起一只"。
 * 而引擎忙着跑长回合时 `/api/health` 本来就会超时（用户随后看到"过了会儿又连上了"，
 * 说明引擎全程没退出）。判据必须是三态：有人在听就**绝对不许**再拉起。
 *
 * 比对用字符串视图 `spawnDecisionName`（仓内枚举一律以 `match` 比，见 cjh_host.cj）。
 */
@Test
public func testSpawnDecisionThreeStates(): Unit {
    // 主路径：端口空着（拒连）→ 允许拉起
    @Assert(spawnDecisionName(spawnDecisionOf(false, false)), "spawn")
    // 主路径：有人听且健康 → 复用
    @Assert(spawnDecisionName(spawnDecisionOf(true, true)), "reuse")
    // 错误路径（本次事故）：有人听但 health 不通（引擎在忙）→ occupied，不许拉起第二只
    @Assert(spawnDecisionName(spawnDecisionOf(true, false)), "occupied")
    // 边界：端口"有人在听"时，healthy 的取值都不得导致 spawn（钉住"有人听就不许再拉起"）
    @Assert(spawnDecisionName(spawnDecisionOf(true, true)) != "spawn", true)
    @Assert(spawnDecisionName(spawnDecisionOf(true, false)) != "spawn", true)
    // 边界：端口空着时 healthy 无意义（没人在听就不存在"健康"），仍必须是 spawn
    @Assert(spawnDecisionName(spawnDecisionOf(false, true)), "spawn")
}
