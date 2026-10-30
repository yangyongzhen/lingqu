package lingqu.port

import std.collection.*
import stdx.encoding.json.*

/*
 * T4-7c 六道闸校验器（Agent 兜底闭环的安全边界，docs/技术思路.md §5.5）。
 *
 * 六道闸里可纯函数化的四道在实现（编译闸/回归闸需要 cargo 子进程，
 * 由命令层在 apply 前跑，本文件只提供闸位的判定输入）：
 *   1. 文件白名单 —— 只允许改 Tauri 工程内的白名单路径；禁碰 .git/target/gen/ohos 之外的一切
 *   2. 单点原则   —— 一次只允许一处语义修改（一文件一 diff）
 *   3. 结构约束   —— 拒绝整体重写：删除行占比过高即拒（无 AST 的保守代理判定）
 *   4. 轮次与经济性 —— 轮次上限 8；同指纹失败 2 次即转 guide，不再烧 token
 *
 * 输入是"待应用的补丁"（文件路径 + 增删行数），输出 GateReport（全过才允许 apply）。
 */

public class PatchProposal {
    public var file: String          // 补丁目标文件的工程相对路径
    public var added: Int64          // 新增行数
    public var removed: Int64        // 删除行数
    public var fingerprintId: String // 触发本补丁的指纹 id（空 = 非指纹驱动）

    public init(file: String, added: Int64, removed: Int64, fingerprintId: String) {
        this.file = file
        this.added = added
        this.removed = removed
        this.fingerprintId = fingerprintId
    }
}

public class GateReport {
    public var passed: Bool = true
    public var failures: ArrayList<String> = ArrayList<String>()

    public func fail(msg: String): Unit {
        this.passed = false
        this.failures.add(msg)
    }

    public func toJson(): JsonObject {
        var arr = JsonArray()
        for (f in failures) {
            arr.add(JsonString(f))
        }
        var o = JsonObject()
        o.put("passed", JsonBool(this.passed))
        o.put("failures", arr)
        return o
    }
}

/** 白名单前缀（相对 Tauri 工程根；技术思路 §5.5 第 1 闸原文口径） */
func whitelistedPrefixes(): ArrayList<String> {
    let p = ArrayList<String>()
    p.add("src-tauri/Cargo.toml")
    p.add("src-tauri/src/")
    p.add("src-tauri/tauri.conf.json")
    p.add("src-tauri/capabilities/")
    p.add("src-tauri/rust-toolchain.toml")
    p.add("src-tauri/.cargo/")
    p.add("src/")
    p.add("index.html")
    return p
}

/** 绝对禁碰（比白名单更早拦）：版本控制、构建产物、锁文件、生成工程 */
func forbiddenMarkers(): ArrayList<String> {
    let p = ArrayList<String>()
    p.add(".git/")
    p.add("target/")
    p.add("node_modules/")
    p.add("dist/")
    p.add("Cargo.lock")   // 锁文件由 cargo 重解析，agent 不手改
    return p
}

func isWhitelisted(file: String): Bool {
    let f = file.trimAscii()
    for (m in forbiddenMarkers()) {
        if (f.contains(m)) {
            return false
        }
    }
    for (p in whitelistedPrefixes()) {
        if (f == p || f.startsWith(p)) {
            return true
        }
    }
    return false
}

/**
 * 六道闸的可纯函数部分：对一批补丁提案过闸。
 *   - 每个文件必须在白名单内（第 1 闸）
 *   - 每个文件算一处语义修改；单次 apply 只允许一个文件（第 2 闸单点原则）
 *   - 删除行数超过 60 行且占原文件比例未知时的保守代理：删除 > 80 行直接拒（第 3 闸结构约束的保守版——
 *     无 AST 时用"大段删除"近似"整体重写"）
 *   - 轮次与同指纹失败由命令层计数后传入（第 4 闸）：rounds > 8 或同指纹失败 ≥ 2 直接拒
 */
public func checkGates(proposals: ArrayList<PatchProposal>, rounds: Int64, sameFingerprintFails: Int64): GateReport {
    let rep = GateReport()

    // 第 4 闸：轮次与经济性（最先判——超轮次直接拒，不看内容）
    if (rounds > 8) {
        rep.fail("轮次闸：已进行 ${rounds} 轮（上限 8），转 guide 交人工")
    }
    if (sameFingerprintFails >= 2) {
        rep.fail("经济性闸：同指纹已失败 ${sameFingerprintFails} 次（阈值 2），转 guide 交人工")
    }

    // 第 2 闸：单点原则
    if (proposals.size > 1) {
        rep.fail("单点闸：一次只允许一处语义修改，收到 ${proposals.size} 个文件的补丁")
    }

    for (p in proposals) {
        // 第 1 闸：文件白名单
        if (!isWhitelisted(p.file)) {
            rep.fail("白名单闸：${p.file} 不在允许修改的路径内")
        }
        // 第 3 闸：结构约束（保守代理：大段删除 ≈ 整体重写）
        if (p.removed > 80) {
            rep.fail("结构闸：${p.file} 删除 ${p.removed} 行（阈值 80）——疑似整体重写，拒绝")
        }
        if (p.added == 0 && p.removed == 0) {
            rep.fail("结构闸：${p.file} 是空补丁")
        }
    }
    return rep
}

/** 指纹失败计数器（命令层跨轮次持有的纯数据） */
public class FailLedger {
    public var counts: HashMap<String, Int64> = HashMap<String, Int64>()
    public var rounds: Int64 = 0

    public func recordFail(fingerprintId: String): Int64 {
        var n: Int64 = 0
        match (this.counts.get(fingerprintId)) {
            case Some(v) => n = v
            case None => n = 0
        }
        n += 1
        this.counts.add(fingerprintId, n)
        this.rounds += 1
        return n
    }
}

// ===== 第 5/6 闸：编译闸与回归闸（0.13.1 起有真数据可用）=====
//
// 这两道闸以前只是"闸位预留"（要 cargo 子进程才有输入）。T5-1 之后 `t2h:build`
// 会把 (退出码, error 数, warning 数) 交进来，于是可以真正判：
//   编译闸：目标平台编译必须成功（退出码 0 且 0 个 error）；
//   回归闸：改了代码之后 error 数不得比改之前更多（0 → 0 才算真进步）。

/** 编译闸：目标平台编译必须过 */
public func checkCompileGate(exitCode: Int64, errorCount: Int64): GateReport {
    let rep = GateReport()
    if (exitCode != 0) {
        rep.fail("编译闸：目标平台编译失败（退出码 ${exitCode}）")
    }
    if (errorCount > 0) {
        rep.fail("编译闸：仍有 ${errorCount} 个编译错误")
    }
    return rep
}

/**
 * 回归闸：error 数不得超过基线。
 *
 * `baselineErrors < 0` = 没有基线（该工程第一次跑）：**此时不判回归**——没有"之前"，
 * 就谈不上"变糟"。首次的绝对要求由编译闸负责（exit=0 且 0 error），所以这里放行不会漏。
 * 早先版本把无基线当基线 0，结果在"未迁移工程首次构建"上报"错误从 0 涨到 8"，
 * 把"本来就没迁移"误报成"回归"（2026-10-30 实机撞到）。
 */
public func checkRegressionGate(baselineErrors: Int64, currentErrors: Int64): GateReport {
    let rep = GateReport()
    if (baselineErrors < 0) {
        return rep
    }
    if (currentErrors > baselineErrors) {
        rep.fail("回归闸：错误从 ${baselineErrors} 涨到 ${currentErrors}（改了反而更糟）")
    }
    return rep
}

/** 把多份闸报告合成一份（任一失败即整体失败） */
public func mergeGates(reports: ArrayList<GateReport>): GateReport {
    let merged = GateReport()
    for (r in reports) {
        if (!r.passed) {
            merged.passed = false
        }
        for (f in r.failures) {
            merged.failures.add(f)
        }
    }
    return merged
}

// ===== 第 7 道：前端指纹闸（T5-2）=====
//
// 这一道挡的是肉眼看不见、且所有构建步骤都"成功"的那类失败：
// **只改前端、没重编 `.so`** —— ArkWeb 下前端被编译进 `.so`，装到真机上跑的是旧前端。
// 判据（两个方向都要看）：
//   staleCount > 0   → `.so` 里记的前端产物在 `dist/` 已不存在（旧 .so 带旧前端）
//   missingCount > 0 → `dist/` 有新产物没进 `.so`（新前端没打包）
public func checkAssetFingerprintGate(staleCount: Int64, missingCount: Int64, embeddedCount: Int64): GateReport {
    let rep = GateReport()
    if (embeddedCount == 0) {
        // `.so` 里压根没扫到前端资源：可能是 frontendDist 没配、或产的是纯 Rust 库
        rep.fail("前端指纹闸：`.so` 里没有内嵌前端资源（frontendDist 配了吗？流水线顺序对吗？）")
        return rep
    }
    if (staleCount > 0) {
        rep.fail("前端指纹闸：`.so` 内嵌的 ${staleCount} 个前端产物在 dist/ 里已不存在——改了前端没重编 .so，真机会跑旧前端")
    }
    if (missingCount > 0) {
        rep.fail("前端指纹闸：dist/ 里 ${missingCount} 个新产物没进 .so——.so 是旧的，必须重编")
    }
    return rep
}
