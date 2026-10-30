package lingqu.port

import std.collection.*
import stdx.encoding.json.*

/*
 * T4-7a/b 错误指纹库与结构化诊断（Agent 兜底闭环的"不调模型"半边）。
 *
 * 设计依据：docs/技术思路.md §5.5——已有真实迁移的踩坑语料可提炼
 * "报错指纹 → 修复模板"映射，**命中时不调用模型**：更快、更准、可审计，
 * 也是与"纯 LLM 一把梭"方案拉开差距的地方。LLM 只处理指纹未命中的长尾。
 *
 * 指纹 = 报错原文里的**稳定子串**（报错原文索引，pitfalls.md 同源）。
 * patchKind 两档：
 *   "rule"  —— 现有 R2-PORT-* 规则就能修：建议直接重跑 t2h:port（确定性修复）
 *   "guide" —— 需要人/AI 介入：给根因与修法模板
 */

public let PK_RULE = "rule"
public let PK_GUIDE = "guide"

/** 一条错误指纹（现象子串 → 根因 → 修法 → 关联规则） */
public class Fingerprint {
    public var id: String
    public var marker: String          // 报错原文里的稳定子串（字面量匹配）
    public var rootCause: String
    public var fix: String
    public var ruleId: String          // patchKind=rule 时关联的 R2-PORT-*；否则 ""
    public var patchKind: String       // PK_RULE / PK_GUIDE

    public init(id: String, marker: String, rootCause: String, fix: String, ruleId: String, patchKind: String) {
        this.id = id
        this.marker = marker
        this.rootCause = rootCause
        this.fix = fix
        this.ruleId = ruleId
        this.patchKind = patchKind
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("id", JsonString(this.id))
        o.put("marker", JsonString(this.marker))
        o.put("rootCause", JsonString(this.rootCause))
        o.put("fix", JsonString(this.fix))
        o.put("ruleId", JsonString(this.ruleId))
        o.put("patchKind", JsonString(this.patchKind))
        return o
    }
}

/** 一次诊断结果：命中的指纹 + 在日志中的证据行 */
public class Diagnosis {
    public var fingerprint: Fingerprint
    public var evidence: String        // 日志中命中指纹的行（file:line 式证据，行号 = 日志行号）
    public var patchKind: String
    public var ruleId: String

    public init(fp: Fingerprint, evidence: String) {
        this.fingerprint = fp
        this.evidence = evidence
        this.patchKind = fp.patchKind
        this.ruleId = fp.ruleId
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("fingerprint", this.fingerprint.toJson())
        o.put("evidence", JsonString(this.evidence))
        o.put("patchKind", JsonString(this.patchKind))
        o.put("ruleId", JsonString(this.ruleId))
        return o
    }
}

// ===== 指纹库（与 skills/t2h-ohos-port/references/pitfalls.md 同源，改动两边同步）=====
// 编号 FP-xxx；顺序即匹配顺序（先特异后一般）。

public func fingerprintLibrary(): ArrayList<Fingerprint> {
    let lib = ArrayList<Fingerprint>()

    // ---- 交叉编译/链接期（rule 档：现有规则可修）----
    lib.add(Fingerprint("FP-001", "cannot find crate napi_ohos",
        "缺 OHOS target 段的 napi 桥接依赖（mobile_entry_point 宏展开必需）",
        "Cargo.toml 加 [target.'cfg(target_env = \"ohos\")'.dependencies] napi-ohos/napi-derive-ohos",
        "R2-PORT-005", PK_RULE))
    lib.add(Fingerprint("FP-002", "-lgcc_eh",
        "llvm-mingw 环境下默认 GNU 工具链的链接器找不到 libgcc_eh",
        "rust-toolchain.toml 换 gnullvm（lld + compiler-rt，无需 libgcc）",
        "R2-PORT-007", PK_RULE))
    lib.add(Fingerprint("FP-003", "linker `",
        "OHOS 目标链接器未配置或路径错误",
        ".cargo/config.toml 配 NDK clang 直作链接器 + sysroot rustflags（NATIVE_OHOS_SDK）",
        "R2-PORT-008", PK_RULE))
    lib.add(Fingerprint("FP-004", "cannot find crate tauri",
        "tauri 依赖未被 fork patch 替换（版本漂移绕过 patch 或 patch 段缺失）",
        "核对 [patch.crates-io] 段存在且 tauri 钉精确版本 =2.11.5",
        "R2-PORT-002", PK_RULE))
    lib.add(Fingerprint("FP-005", "unresolved import",
        "wry/tao 未一并 patch（fork 的 workspace patch 不跨工程继承）",
        "[patch.crates-io] 补 wry/tao 的 fork rev",
        "R2-PORT-006", PK_RULE))
    lib.add(Fingerprint("FP-006", "failed to select a version",
        "patch 指向的 rev/版本与依赖需求无法解析（版本钉缺失或错位）",
        "tauri/wry 钉精确版本（=2.11.5 / =0.56.0）后重锁 Cargo.lock",
        "R2-PORT-002", PK_RULE))
    lib.add(Fingerprint("FP-007", "custom-protocol",
        "生产模式缺 custom-protocol feature → 运行时加载 devUrl 白屏",
        "tauri features 合并 custom-protocol（t2h:port 规则 002 会带上）",
        "R2-PORT-002", PK_RULE))

    // ---- 运行期（guide 档：涉及真机/语义，规则面不直接改）----
    lib.add(Fingerprint("FP-010", "app_data_dir",
        "OHOS 无 HOME 环境变量，dirs::data_dir() 返回 None → setup panic（SIGABRT）",
        "lib.rs 注入 resolve_app_data_dir()（沙箱 /data/storage/el2/base/files）并在 setup 接线",
        "R2-PORT-009", PK_GUIDE))
    lib.add(Fingerprint("FP-011", "SIGABRT",
        "setup 阶段 panic 的进程表现（常由 FP-010 引发，先查它）",
        "panic.log 在数据目录；确认 install_panic_hook 已接线后复跑取证",
        "", PK_GUIDE))
    lib.add(Fingerprint("FP-012", "9568322",
        "release 分发签名（无 device-ids）直装不被真机信任",
        "signingConfig: release → default（debugKey）；上架前改回",
        "", PK_GUIDE))
    lib.add(Fingerprint("FP-013", "9568269",
        "hdc file send 保留了源目录结构，设备上没有 .hap",
        "cd 到 HAP 所在目录再 file send 文件名；bm install -p 接目录",
        "", PK_GUIDE))
    lib.add(Fingerprint("FP-014", "10106102",
        "开发者模式拒绝自动解锁（aa start 前设备在锁屏）",
        "手动解锁后重试；自动化脚本留等待点",
        "", PK_GUIDE))
    lib.add(Fingerprint("FP-015", "rawfile",
        "把 rawfile 当运行时资源（实为死资源——前端嵌在 .so 里）",
        "改前端必须重编 .so 并核对 AssetKey 指纹（见 pitfalls.md 第 10 条）",
        "", PK_GUIDE))

    return lib
}

/**
 * 对构建/运行日志文本做指纹匹配（T4-7a 纯函数）。
 * 返回全部命中（同一指纹只报一次，取首次命中的日志行作证据）。
 */
public func diagnoseLog(logText: String): ArrayList<Diagnosis> {
    let lib = fingerprintLibrary()
    let out = ArrayList<Diagnosis>()
    let hit = HashSet<String>()
    let lines = logText.split("\n", -1)
    for (i in 0..lines.size) {
        let line = lines[i]
        for (j in 0..lib.size) {
            let fp = lib[j]
            if (hit.contains(fp.id)) {
                continue
            }
            if (line.contains(fp.marker)) {
                let evidence = "log:${i + 1}: ${line.trimAscii()}"
                out.add(Diagnosis(fp, evidence))
                hit.add(fp.id)
            }
        }
    }
    return out
}

/** 诊断结果的 JSON（命令面直接返回） */
public func diagnosisJson(items: ArrayList<Diagnosis>): JsonObject {
    var arr = JsonArray()
    var ruleCount: Int64 = 0
    var guideCount: Int64 = 0
    for (d in items) {
        arr.add(d.toJson())
        if (d.patchKind == PK_RULE) {
            ruleCount += 1
        } else {
            guideCount += 1
        }
    }
    var o = JsonObject()
    o.put("items", arr)
    o.put("total", JsonInt(items.size))
    o.put("rule", JsonInt(ruleCount))
    o.put("guide", JsonInt(guideCount))
    // rule 档存在的统一动作建议：重跑 t2h:port（幂等，只会补缺口）
    var hasRule = false
    if (ruleCount > 0) {
        hasRule = true
    }
    o.put("suggestRerunPort", JsonBool(hasRule))
    return o
}

/**
 * T4-7b：结构化补丁建议——把 rule 档诊断映射为过闸用的 PatchProposal
 * （ruleId → 目标文件；行数为 0 占位，真实增删由 t2h:port 幂等重跑产生）。
 * guide 档不生成 proposal（需人工/AI，不走六道闸直接改码路径）。
 */
public func patchProposalsFromDiagnosis(items: ArrayList<Diagnosis>): ArrayList<PatchProposal> {
    let out = ArrayList<PatchProposal>()
    let seen = HashSet<String>()
    for (d in items) {
        if (d.patchKind != PK_RULE) {
            continue
        }
        var file = ""
        match (d.ruleId) {
            case "R2-PORT-002" => file = "src-tauri/Cargo.toml"
            case "R2-PORT-004" => file = "src-tauri/Cargo.toml"
            case "R2-PORT-005" => file = "src-tauri/Cargo.toml"
            case "R2-PORT-006" => file = "src-tauri/Cargo.toml"
            case "R2-PORT-007" => file = "src-tauri/rust-toolchain.toml"
            case "R2-PORT-008" => file = "src-tauri/.cargo/config.toml"
            case "R2-PORT-009" => file = "src-tauri/src/lib.rs"
            case _ => file = ""
        }
        if (file == "" || seen.contains(file)) {
            continue
        }
        seen.add(file)
        out.add(PatchProposal(file, 0, 0, d.fingerprint.id))
    }
    return out
}
