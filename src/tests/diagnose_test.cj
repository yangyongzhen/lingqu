package lingqu.tests

import std.collection.*
import lingqu.port.*

/*
 * P4 第四刀（T4-7）单测：错误指纹库诊断、结构化补丁建议、六道闸校验器。
 * 全部纯函数（D-009）；编译闸/回归闸需 cargo 子进程，由命令层负责。
 */

@Test
public func testFingerprintLibraryShape(): Unit {
    // 指纹库非空且每条字段齐全；marker 是字面量子串（供 contains 匹配）
    let lib = fingerprintLibrary()
    @Assert(lib.size >= 10, true)
    for (fp in lib) {
        @Assert(fp.marker != "", true)
        @Assert(fp.rootCause != "", true)
        @Assert(fp.fix != "", true)
        @Assert(fp.patchKind == PK_RULE || fp.patchKind == PK_GUIDE, true)
    }
}

@Test
public func testDiagnoseLogHitsRuleFingerprints(): Unit {
    // 主路径：napi 缺依赖与 -lgcc_eh 两条 rule 档指纹（rule 档 → 建议重跑 t2h:port）
    // 注意日志行不要带其他指纹的 marker（如 unresolved import / linker ` 会交叉命中）
    let log = """
    error[E0432]: cannot find crate napi_ohos
      --> src-tauri/src/lib.rs:3:5
    note: required by `mobile_entry_point`
    error: cannot find -lgcc_eh
    """
    let hits = diagnoseLog(log)
    @Assert(hits.size, 2)
    var hasNapi = false
    var hasGcc = false
    for (d in hits) {
        if (d.fingerprint.id == "FP-001") {
            hasNapi = true
            @Assert(d.patchKind, PK_RULE)
            @Assert(d.ruleId, "R2-PORT-005")
            @Assert(d.evidence.contains("log:1"), true) // 证据行带日志行号
        }
        if (d.fingerprint.id == "FP-002") {
            hasGcc = true
        }
    }
    @Assert(hasNapi, true)
    @Assert(hasGcc, true)
}

@Test
public func testDiagnoseLogDeduplicatesPerFingerprint(): Unit {
    // 边界：同一指纹在日志里出现多次只报一次（取首行）
    let log = "cannot find crate napi_ohos\nagain: cannot find crate napi_ohos\n"
    let hits = diagnoseLog(log)
    var n = 0
    for (d in hits) {
        if (d.fingerprint.id == "FP-001") {
            n += 1
        }
    }
    @Assert(n, 1)
}

@Test
public func testDiagnoseLogNoHitReturnsEmpty(): Unit {
    // 错误路径：无关日志 → 空命中（长尾走 LLM，不硬凑）
    let hits = diagnoseLog("everything is fine\nnothing to see here\n")
    @Assert(hits.size, 0)
}

@Test
public func testPatchProposalsFromDiagnosis(): Unit {
    // rule 档 → 按 ruleId 映射目标文件并按文件去重；guide 档不生成
    let log = "cannot find crate napi_ohos\nerror: cannot find -lgcc_eh\n"
    let hits = diagnoseLog(log)
    let proposals = patchProposalsFromDiagnosis(hits)
    // FP-001 → Cargo.toml、FP-002 → rust-toolchain.toml：两个不同文件
    @Assert(proposals.size, 2)
    var files = ArrayList<String>()
    for (p in proposals) {
        files.add(p.file)
    }
    @Assert(files.contains("src-tauri/Cargo.toml"), true)
    @Assert(files.contains("src-tauri/rust-toolchain.toml"), true)
}

@Test
public func testGatesWhitelistAndSinglePoint(): Unit {
    // 第 1 闸：白名单外的文件拒；禁碰 .git/target/Cargo.lock
    var ps = ArrayList<PatchProposal>()
    ps.add(PatchProposal("../../.git/config", 1, 0, ""))
    var rep = checkGates(ps, 0, 0)
    @Assert(rep.passed, false)
    ps = ArrayList<PatchProposal>()
    ps.add(PatchProposal("src-tauri/Cargo.lock", 1, 0, ""))
    rep = checkGates(ps, 0, 0)
    @Assert(rep.passed, false)
    // 第 2 闸：一次只允许一个文件
    ps = ArrayList<PatchProposal>()
    ps.add(PatchProposal("src-tauri/Cargo.toml", 2, 0, ""))
    ps.add(PatchProposal("src/main.ts", 1, 0, ""))
    rep = checkGates(ps, 0, 0)
    @Assert(rep.passed, false)
    // 白名单内单文件 → 过
    ps = ArrayList<PatchProposal>()
    ps.add(PatchProposal("src-tauri/src/lib.rs", 4, 0, ""))
    rep = checkGates(ps, 0, 0)
    @Assert(rep.passed, true)
}

@Test
public func testGatesStructureAndRounds(): Unit {
    // 第 3 闸：大段删除（>80 行）疑似整体重写，拒；空补丁拒
    var ps = ArrayList<PatchProposal>()
    ps.add(PatchProposal("src/ui.ts", 2, 120, ""))
    var rep = checkGates(ps, 0, 0)
    @Assert(rep.passed, false)
    ps = ArrayList<PatchProposal>()
    ps.add(PatchProposal("src/ui.ts", 0, 0, ""))
    rep = checkGates(ps, 0, 0)
    @Assert(rep.passed, false)
    // 第 4 闸：轮次超 8 或同指纹失败 ≥2 → 拒（哪怕补丁本身干净）
    ps = ArrayList<PatchProposal>()
    ps.add(PatchProposal("src-tauri/Cargo.toml", 1, 0, "FP-001"))
    rep = checkGates(ps, 9, 0)
    @Assert(rep.passed, false)
    rep = checkGates(ps, 2, 2)
    @Assert(rep.passed, false)
    // 正常轮次内 → 过
    rep = checkGates(ps, 3, 1)
    @Assert(rep.passed, true)
}

@Test
public func testFailLedgerCountsPerFingerprint(): Unit {
    // 同指纹失败计数累加；不同指纹分开计数
    let led = FailLedger()
    led.recordFail("FP-001")
    led.recordFail("FP-001")
    led.recordFail("FP-002")
    match (led.counts.get("FP-001")) {
        case Some(v) => @Assert(v, 2)
        case None => @Assert(true, false)
    }
    match (led.counts.get("FP-002")) {
        case Some(v) => @Assert(v, 1)
        case None => @Assert(true, false)
    }
    @Assert(led.rounds, 3)
}

@Test
public func testDiagnoseSignMaterialFingerprints(): Unit {
    // 0.39.9 实测的两条 hvigor 签名失败信号：包名不一致（00303074）/ 材料文件不存在（00303107）
    // 注意（AGENTS §4-28）：仓颉多行字符串必须以换行开头，且串内反斜杠仍是转义
    let mismatch = """
    hvigor ERROR: Failed :entry:default@SignHap...
    > hvigor ERROR: 00303074 Configuration Error
    The bundleName in app.json5/hvigorfile.ts does not match the bundleName in the generated SigningConfigs.
    """
    let hits = diagnoseLog(mismatch)
    var found = false
    for (d in hits) {
        if (d.fingerprint.id == "FP-018") {
            found = true
            @Assert(d.patchKind, PK_GUIDE)              // 涉及 DevEco 登录 → guide 档，不自动改
            @Assert(d.fingerprint.fix.contains("DevEco"), true)
            @Assert(d.evidence.contains("00303074"), true)
        }
    }
    @Assert(found, true)
    // 材料缺文件那条
    let missing = "hvigor ERROR 00303107 Configuration Error: Invalid storeFile value."
    var found2 = false
    for (d in diagnoseLog(missing)) {
        if (d.fingerprint.id == "FP-019") {
            found2 = true
        }
    }
    @Assert(found2, true)
}