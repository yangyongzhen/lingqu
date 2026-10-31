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