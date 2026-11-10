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
    // 排在通用 `unresolved import`（FP-005）之前：marker 更具体，先认它
    lib.add(Fingerprint("FP-022", "openharmony_ability",
        "桥代码直接 `use openharmony_ability::…`，但本工程对它只有 [patch] 段没有直接依赖（[patch] 只改来源，不把 crate 加进依赖图）",
        "改走 tauri 的转出 `use tauri::ohos::openharmony_ability::get_main_thread_env;`（同一 crate 同一 rev，无需动 Cargo.toml/lock）",
        "R2-PORT-017", PK_RULE))
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

    // ---- 0.39.99：reqwest 默认特性拉 openssl-sys（note-gen-2 实测，2026-11-08）----
    // 现场（note-gen-2/src-tauri/Cargo.toml:76）：
    //   reqwest = { version="0.12", features=["json","multipart","stream","rustls-tls","socks"] }
    // 写了 rustls-tls 却**没关 default-features** ⇒ 默认的 default-tls 仍在
    //   ⇒ native-tls ⇒ openssl-sys，交叉编译到 OHOS 必然失败：
    //     Could not find directory of OpenSSL installation, and this `-sys` crate cannot proceed …
    //     pkg-config has not been configured to support cross-compilation.
    // 要紧的是**这条与 FP-016 会同时命中**（openssl-sys 的 build script 也会打 pkg-config 那句），
    // 而 FP-016 归因给 glib-sys/GTK。所以 FP-021 必须排在它前面：先给出正确的归因，
    // 否则 agent 会顺着"GTK 链 → 重跑 port 就好"或"装 OpenSSL / 配 pkg-config"烧完一轮预算。
    lib.add(Fingerprint("FP-021", "Could not find directory of OpenSSL installation",
        "某个 -sys crate 的 C 依赖在交叉编译时找不到 OpenSSL；在 Tauri 工程上绝大多数是 **reqwest 没关默认特性**——默认的 default-tls → native-tls → openssl-sys 进了依赖树（即使 features 里已经写了 rustls-tls，两者会同时存在）",
        "重跑 t2h:port：规则 R2-PORT-016 会给 reqwest 加 default-features = false 并补 rustls-tls（含 charset/http2/system-proxy 这些纯 Rust 默认项）。自查：`cargo tree --target aarch64-unknown-linux-ohos -i openssl-sys` 应为空。**别去装 OpenSSL、别配 pkg-config**——目标平台没有它，那条路走不通",
        "R2-PORT-016", PK_RULE))
    // ---- 0.13.1 审核轮补：T5-1 首次真机交叉编译实测到的失败（不是凭空编的）----
    // 证据：habit-tree @ main 分支（未迁移）在 Windows 上
    //   cargo build --release --target aarch64-unknown-linux-ohos
    // 的首个失败就是 glib-sys 的 build script —— 根因是 wry/tao 仍是 registry 版本、
    // 拉进了 GTK/glib 桌面依赖链（未迁移工程的必经之路）。
    lib.add(Fingerprint("FP-016", "pkg-config has not been configured to support cross-compilation",
        "某个 C 依赖的 build script 交叉编译时找不到 pkg-config 配置。**先看紧随其后的 custom build command 是哪条 crate**：glib-sys/gtk 系 → 通常是 wry/tao 还是 registry 版本、拉进 GTK/glib 桌面依赖链；openssl-sys → 见 FP-021（那是 reqwest 默认特性，不是 GTK）",
        "glib-sys/gtk 系：重跑 t2h:port（R2-PORT-006 patch 掉 wry/tao）即可根除；openssl-sys：走 FP-021 / R2-PORT-016。两者都**不要**去给交叉编译硬配 pkg-config",
        "R2-PORT-006", PK_RULE))
    lib.add(Fingerprint("FP-017", "failed to run custom build command for",
        "C 依赖 crate 的 build script 失败（交叉编译缺 sysroot / pkg-config / 目标平台不支持）",
        "看紧随其后的 `cargo:warning=` 行确定缺什么；桌面专属依赖（glib/gtk/x11）应 patch 掉而不是硬配 pkg-config",
        "", PK_GUIDE))

    // ---- 0.39.9：签名材料的包名门槛（实测信号来自 hvigor 的 default@SignHap）----
    // 证据：m3u8dl-tauri（bundleName=com.atomgit.m3u8dl_tauri）在本机 `~/.ohos/config` 的 4 套
    // profile（com.yang.testcj / com.jiujiang.habit_tree / com.yang.ohosnes.fceux）里没有自己这份，
    // 即使把 signingConfigs 改指向一份**文件齐全**的材料，hvigor 仍然这样失败：
    //     00303074 Configuration Error
    //     The bundleName in app.json5/hvigorfile.ts does not match the bundleName in the generated SigningConfigs.
    // 结论：profile 按包名签发，**没有该包名的材料就装不上**，写回别的包名的材料只是把
    // 「材料缺失」换成「配置错误」。正解是 DevEco 自动签名一次（需登录，计入 A3 人工介入）。
    lib.add(Fingerprint("FP-018", "00303074",
        "签名材料的 bundleName 与工程 AppScope/app.json5 的 bundleName 不一致（profile 按包名签发，本机没有该包名的材料）",
        "在 DevEco 里对**本工程**点一次自动签名（需登录华为账号）拿到该包名的 profile；临时验证可把 bundleName 改成已有材料的包名",
        "", PK_GUIDE))
    lib.add(Fingerprint("FP-019", "00303107",
        "build-profile.json5 的 signingConfigs 指向的签名材料文件不存在（.p12/.cer/.p7b 被删或换机器丢了）",
        "跑「签名体检」确认三个路径是否都在；缺了就重新自动签名一次，别手填别的工程的路径",
        "", PK_GUIDE))
    // FP-020（0.39.51，juCang 实测）：hvigor 报 00308018，日志里真正的 trace 是
    //   thread 'main' panicked … failed to read missing addr file %TEMP%\<包名>-server-addr
    //   Command failed: cargo tauri ohos dev-eco-studio-script --target aarch64
    // 那条钩子是给 `tauri ohos dev`（有 dev server）准备的：它要读 dev server 写下的 addr 文件，
    // 非 dev 场景（我们就是）必然 panic。它和签名、代码都没关系，别再让 agent 反复烧轮次去查。
    lib.add(Fingerprint("FP-020", "dev-eco-studio-script",
        "hvigorfile.ts 里的 tauri 钩子在跑 `cargo tauri ohos dev-eco-studio-script`，它要读 dev server 的 addr 文件（%TEMP%\\<包名>-server-addr）；非 dev 场景没有这个文件 → tauri-cli panic → hvigor 00308018",
        "让 gen/ohos/entry/hvigorfile.ts 不再跑这个钩子（迁移台的 t2h:hap 已负责把 lib<模块>.so 装配进 libs/arm64-v8a，不需要它编 Rust）；或者先 `cargo tauri ohos dev` 起 dev server 再装配",
        "", PK_GUIDE))
    // FP-023（0.39.110，m3u8dl-tauri 实测）：材料文件齐全、包名也对，但 `.p12` 与证书不是一对。
    // 现场链条：sign --auto 复用云端同名证书（那是**另一次**从别的 CSR 签出来的）→ 本地 .cer 被重下成
    // 新证书、.p12 仍是旧的 → hvigor default@SignHap 直接 11111002；重下证书解决不了，只能换密钥对。
    // marker 用错误码（唯一），不用 "Certificates error" 这类泛串（§4-164）。
    lib.add(Fingerprint("FP-023", "11111002",
        "签名材料里 `.p12` 私钥与 build-profile 指向的证书不是同一把钥匙（hvigor 11111002 Certificates error；00303242 'Unable to authenticate data' 同源）——常见于复用云端同名证书、或材料从别处拷来",
        "换一套自己能掌握口令的材料重签：`lingqu-cli sign --auto --newKeys --path .`（旧材料改名留底），再重跑 t2h:hap / deploy。**别去重下 .cer、别改包名**——证书换成新的、钥匙还是旧的，重下多少次都对不上",
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
            case "R2-PORT-016" => file = "src-tauri/Cargo.toml"
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

// ============================================================
// 未命中指纹的"攒候选"（0.39.55）：让飞轮自己转起来
// ============================================================
//
// 以前 `t2h:diagnose` 未命中就只返回空数组——于是"这条错误没人认识"这件事**没有落档**，
// 下一个样本再撞上还是从零开始。现在把未命中的日志归一成一个**签名**记下来，
// 同形态累积到阈值就提示"该补指纹"，并给出候选条目的草稿要素。
//
// 纪律：机器只负责**发现与攒证据**，新指纹进库仍要人确认（指纹库会指导 agent 怎么改代码，
// 自动写进去 = 让一个没人看过的规则去改用户工程，代价太大）。

/** 纯函数：把错误行归一成"签名"（数字/长十六进制折叠、ASCII 小写、空白压成单空格、截断 120） */
public func missSignatureOf(logText: String): String {
    var sample = ""
    for (line in logText.split("\n", -1)) {
        let t = line.trimAscii()
        if (t.size == 0) {
            continue
        }
        let lower = diagLowerOf(t)
        if (lower.contains("error") || lower.contains("failed") || lower.contains("panic")) {
            sample = t
            break
        }
    }
    if (sample.size == 0) {
        return ""
    }
    let bytes = sample.toArray()
    let out = ArrayList<Byte>()
    var i: Int64 = 0
    while (i < Int64(bytes.size)) {
        let b = bytes[i]
        // 连续数字 → 一个 '#'
        if (b >= 48 && b <= 57) {
            out.add(UInt8(35))
            while (i < Int64(bytes.size) && bytes[i] >= 48 && bytes[i] <= 57) {
                i += 1
            }
            continue
        }
        // 空白压成一个空格
        if (b == 32 || b == 9) {
            out.add(UInt8(32))
            while (i < Int64(bytes.size) && (bytes[i] == 32 || bytes[i] == 9)) {
                i += 1
            }
            continue
        }
        // ASCII 小写
        out.add(if (b >= 65 && b <= 90) { UInt8(Int64(b) + 32) } else { b })
        i += 1
    }
    var sig = String.fromUtf8(out.toArray()).trimAscii()
    if (sig.size > 120) {
        sig = sig[0..120]
    }
    return sig
}

/** 纯函数：同形态攒到几次该怎么处置（给界面/报告看，一句话说清"下一步"） */
public func missCandidateHint(times: Int64): String {
    if (times <= 0) {
        return ""
    }
    if (times == 1) {
        return "第 1 次见到这种错误——先记下（`.lingqu/diagnose/misses.jsonl`），不急着进指纹库"
    }
    if (times == 2) {
        return "第 2 次见到同一种错误——可以考虑补一条指纹（现象/根因/修法三件齐全再进库）"
    }
    return "已出现 ${times} 次同一种错误——**建议补指纹**：把日志里的稳定子串做成 marker，" +
        "按 `fingerprintLibrary()` 的格式加一条（带单测），下次 agent 一次就能拿到修法"
}

/** ASCII 小写（本包私有；`lingqu` 包里那个同名函数不在本包作用域，§4 跨包不共享私有符号） */
func diagLowerOf(s: String): String {
    let out = ArrayList<Byte>()
    for (b in s.toArray()) {
        out.add(if (b >= 65 && b <= 90) { UInt8(Int64(b) + 32) } else { b })
    }
    return String.fromUtf8(out.toArray())
}

// ===== 指纹库 ↔ 技能文档 的同源校验（0.39.111）=====
// 两条教训撞在一起：§4-164 说"只有能被报错原文唯一认出的串才进指纹表"，
// §4-130 说"工具有能力、说明书没给 = agent 只能瞎摸"。
// 推论：**指纹表里出现的唯一错误码，技能文档里必须查得到处置**。
// 这两处都是手写维护，一定会漂移；把它做成纯函数，才能用单测钉住（而不是靠谁记得同步）。

/** 是否是"唯一可识别错误码"：全 ASCII 数字且 ≥7 位（`9568322` / `00303074` / `11111002`） */
public func isUniqueErrorCodeOf(s: String): Bool {
    let bytes = s.toArray()
    if (bytes.size < 7) {
        return false
    }
    for (b in bytes) {
        if (b < 48 || b > 57) {
            return false
        }
    }
    return true
}

/** 从任意文本里抽出全部 7 位以上纯数字串（保序去重）—— 用来扫指纹正文与任务书正文 */
public func uniqueErrorCodesOf(text: String): ArrayList<String> {
    let out = ArrayList<String>()
    let cur = ArrayList<Byte>()
    let bytes = text.toArray()
    var i = 0
    while (i <= bytes.size) {
        let isDigit = if (i < bytes.size) { bytes[i] >= 48 && bytes[i] <= 57 } else { false }
        if (isDigit) {
            cur.add(bytes[i])
        } else {
            if (cur.size >= 7) {
                let code = String.fromUtf8(cur.toArray())
                if (!out.contains(code)) {
                    out.add(code)
                }
            }
            cur.clear()
        }
        i += 1
    }
    return out
}

/** 给定文本里有哪些错误码在 `docText` 中查不到 */
public func codesMissingInDocsOf(text: String, docText: String): ArrayList<String> {
    let gaps = ArrayList<String>()
    for (code in uniqueErrorCodesOf(text)) {
        match (docText.indexOf(code)) {
            case Some(_) => ()
            case None => gaps.add(code)
        }
    }
    return gaps
}

/**
 * 指纹库 → 技能文档 的同源缺口。
 * 每条指纹的 marker / 根因 / 修法里出现的唯一错误码，都应当能在技能 references 里查到；
 * 查不到的按「FP-0xx 的错误码 xxx 在技能文档里查不到」返回（空数组 = 两边一致）。
 */
public func fingerprintDocGapsOf(fps: ArrayList<Fingerprint>, docText: String): ArrayList<String> {
    let gaps = ArrayList<String>()
    let checked = ArrayList<String>()
    for (fp in fps) {
        let codes = uniqueErrorCodesOf(fp.marker + " " + fp.rootCause + " " + fp.fix)
        for (code in codes) {
            if (checked.contains(code)) {
                continue
            }
            checked.add(code)
            match (docText.indexOf(code)) {
                case Some(_) => ()
                case None => gaps.add("${fp.id} 的错误码 ${code} 在技能文档里查不到")
            }
        }
    }
    return gaps
}
