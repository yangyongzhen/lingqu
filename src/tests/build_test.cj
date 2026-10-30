package lingqu.tests

import std.collection.*
import std.fs.*
import lingqu.compiler.*
import lingqu.port.*

/*
 * T5-1 单测：cargo --message-format=json 的解析与归一化（纯函数，D-009）
 * + 编译闸/回归闸（T4-7 六道闸里此前只有"闸位"的两道，0.13.1 起有真输入）。
 *
 * fixture 来自 2026-10-30 的真实构建输出（路径已脱敏、行数已裁剪）：
 *   samples/evidence/cargo-jsonl-compile-error.jsonl   —— Rust 编译错误（含 compiler-message）
 *   samples/evidence/cargo-jsonl-build-script-fail.jsonl —— build-script 失败（**没有** compiler-message）
 */

func readEvidence(name: String): String {
    return String.fromUtf8(File.readFrom("samples/evidence/${name}"))
}

@Test
public func testParseCompileErrorJsonl(): Unit {
    let p = parseCargoJsonl(readEvidence("cargo-jsonl-compile-error.jsonl"))
    // 3 条 compiler-message：2 error + 1 warning
    @Assert(p.diags.size, 3)
    @Assert(p.errorCount(), 2)
    @Assert(p.warningCount(), 1)
    // 结构化字段：code / file / line / column
    @Assert(p.diags[0].code, "E0308")
    @Assert(p.diags[0].level, "error")
    @Assert(p.diags[0].file, "src\\lib.rs")
    @Assert(p.diags[0].line, 2)
    @Assert(p.diags[0].column, 18)
    @Assert(p.diags[1].code, "E0425")
    // cargo 自报失败
    @Assert(p.sawFinished, true)
    @Assert(p.finishedOk, false)
    // 失败构建不产出交付物：artifacts 为空正是"这次没东西可交付"的信号
    @Assert(p.artifacts.size, 0)
    @Assert(p.badLines, 0)
}

@Test
public func testParseBuildScriptFailureHasNoCompilerMessage(): Unit {
    // 关键实测事实：build-script / 链接类失败在 stdout 里**没有** compiler-message，
    // 只有 build-finished{success:false}——所以命令层必须同时看 stderr。
    let p = parseCargoJsonl(readEvidence("cargo-jsonl-build-script-fail.jsonl"))
    @Assert(p.diags.size, 0)
    @Assert(p.errorCount(), 0)
    @Assert(p.sawFinished, true)
    @Assert(p.finishedOk, false)
    // 交付产物为空（build-script 的 .exe 属宿主中间态，按口径不算交付物）
    @Assert(p.artifacts.size, 0)
}

@Test
public func testParseToleratesTruncatedAndGarbage(): Unit {
    // 边界 1：最后一行被缓冲截断成半个 JSON —— 计数但不炸（真实构建日志常见）
    let truncated = "{\"reason\":\"build-finished\",\"success\":true}\n{\"reason\":\"compiler-mes"
    let p1 = parseCargoJsonl(truncated)
    @Assert(p1.sawFinished, true)
    @Assert(p1.finishedOk, true)
    @Assert(p1.badLines, 1)
    // 边界 2：空输入
    let p2 = parseCargoJsonl("")
    @Assert(p2.diags.size, 0)
    @Assert(p2.sawFinished, false)
    // 边界 3：混进非 JSON 行（stderr 被误拼进来）
    let p3 = parseCargoJsonl("   Compiling foo v0.1.0\n")
    @Assert(p3.badLines, 1)
    @Assert(p3.diags.size, 0)
}

@Test
public func testDiagsAsLogTextIsFingerprintable(): Unit {
    let p = parseCargoJsonl(readEvidence("cargo-jsonl-compile-error.jsonl"))
    let text = diagsAsLogText(p.diags)
    // 头部形状：level[code] file:line:col message
    @Assert(text.contains("error[E0308] src\\lib.rs:2:18 mismatched types"), true)
    // rendered 片段也进来了（指纹库有些 marker 只在源码上下文里出现）
    @Assert(text.contains("expected `i32`, found `&str`"), true)
}

@Test
public func testFirstLinesAndLastSep(): Unit {
    @Assert(firstLines("a\nb\nc\nd", 2), "a\nb")
    @Assert(firstLines("a\nb", 0), "")
    // "a/b/c.rs" 的最后一个 `/` 在 3；"a\b\c.rs" 的最后一个 `\` 也在 3（两边都要认）
    @Assert(lastSepIndex("a/b/c.rs"), 3)
    @Assert(lastSepIndex("a\\b\\c.rs"), 3)
    @Assert(lastSepIndex("noleading.rs"), -1)
}

@Test
public func testCompileGate(): Unit {
    // 主路径：0 退出码 + 0 错误 → 过
    let ok = checkCompileGate(0, 0)
    @Assert(ok.passed, true)
    @Assert(ok.failures.size, 0)
    // 错误路径：退出码 101 + 2 个错误 → 两条失败原因都记下
    let bad = checkCompileGate(101, 2)
    @Assert(bad.passed, false)
    @Assert(bad.failures.size, 2)
}

@Test
public func testRegressionGate(): Unit {
    // 无基线（-1）= 该工程第一次跑：**不判回归**（没有"之前"就谈不上"变糟"）。
    // 首次的绝对要求由编译闸负责（exit=0 且 0 error），所以这里放行不会漏。
    // 2026-10-30 实机教训：把它当基线 0 会在"未迁移工程首次构建"上误报"错误从 0 涨到 8"。
    @Assert(checkRegressionGate(-1, 0).passed, true)
    @Assert(checkRegressionGate(-1, 8).passed, true)
    // 有基线：不涨才过
    @Assert(checkRegressionGate(2, 2).passed, true)
    @Assert(checkRegressionGate(2, 3).passed, false)
    // 变好也算过
    @Assert(checkRegressionGate(3, 1).passed, true)
}

@Test
public func testCountErrorLinesOnStderr(): Unit {
    // build-script / 链接类失败只在 stderr 留痕——这三行是 2026-10-30 实测的原文形状
    let stderr = "   Compiling glib-sys v0.18.1\n" +
        "warning: glib-sys@0.18.1: pkg-config has not been configured to support cross-compilation.\n" +
        "error: failed to run custom build command for `glib-sys v0.18.1`\n" +
        "warning: build failed, waiting for other jobs to finish...\n" +
        "error: failed to run custom build command for `gobject-sys v0.18.0`\n"
    @Assert(countErrorLines(stderr), 2)
    @Assert(countErrorLines(""), 0)
    // error[E0308] 这种带 code 的行也算
    @Assert(countErrorLines("error[E0308]: mismatched types\n"), 1)
    // 缩进的 "error" 不算（cargo 的源码上下文里会有 "error" 字样）
    @Assert(countErrorLines("  | expected due to this error\n"), 0)
    @Assert(firstErrorLine(stderr), "error: failed to run custom build command for `glib-sys v0.18.1`")
    @Assert(firstErrorLine("all good\n"), "")
}

@Test
public func testArtifactsKeepOnlyFinalProducts(): Unit {
    // 成功构建：.so 与 .a 是交付物；.rlib/.rmeta/.d 是中间态、
    // serde 的 rlib 是依赖（非本工程交付物）→ 都要过滤掉。
    let p = parseCargoJsonl(readEvidence("cargo-jsonl-success-artifacts.jsonl"))
    @Assert(p.finishedOk, true)
    @Assert(p.artifacts.size, 2)
    @Assert(p.artifacts[0], "libdemo.so")
    @Assert(p.artifacts[1], "libhelper.a")
    // 列表里不能出现中间态或宿主产物（.dll.a 是 Windows 上 proc-macro 的导入库，以 .a 结尾但不算交付物）
    for (a in p.artifacts) {
        @Assert(a.endsWith(".rlib") || a.endsWith(".rmeta") || a.endsWith(".d")
            || a.endsWith(".dll.a") || a.endsWith(".dll"), false)
    }
}

@Test
public func testMergeGates(): Unit {
    let a = checkCompileGate(0, 0)
    let b = checkRegressionGate(0, 0)
    let list1 = ArrayList<GateReport>()
    list1.add(a)
    list1.add(b)
    let merged = mergeGates(list1)
    @Assert(merged.passed, true)
    let list2 = ArrayList<GateReport>()
    list2.add(a)
    list2.add(checkCompileGate(1, 1))
    let bad = mergeGates(list2)
    @Assert(bad.passed, false)
    @Assert(bad.failures.size, 2)
}

@Test
public func testFingerprintCatchesRealCrossCompileFailure(): Unit {
    // 0.13.1 新增的 FP-016/017 必须能命中"真实见过的"未迁移工程失败
    let log = "error: failed to run custom build command for `glib-sys v0.18.1`\n" +
        "  cargo:warning=pkg-config has not been configured to support cross-compilation.\n"
    let hits = diagnoseLog(log)
    @Assert(hits.size >= 2, true)
    var saw016 = false
    var saw017 = false
    var ruleTier = false
    for (h in hits) {
        if (h.fingerprint.id == "FP-016") {
            saw016 = true
            // 这条是 rule 档：重跑 t2h:port 就能根除（patch 掉 wry/tao）
            if (h.patchKind == PK_RULE && h.ruleId == "R2-PORT-006") {
                ruleTier = true
            }
        }
        if (h.fingerprint.id == "FP-017") {
            saw017 = true
        }
    }
    @Assert(saw016, true)
    @Assert(saw017, true)
    @Assert(ruleTier, true)
    // 并因此建议重跑 port（"命中即不调模型"的那条闭环）
    let dj = diagnosisJson(hits)
    @Assert(dj.get("suggestRerunPort").getOrThrow().asBool().getValue(), true)
}
