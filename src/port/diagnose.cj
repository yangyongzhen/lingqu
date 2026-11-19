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
        "某个 C 依赖的 build script 交叉编译时找不到 pkg-config 配置。**先看紧随其后的 custom build command 是哪条 crate**：glib-sys/gtk 系 → 通常是 wry/tao 还是 registry 版本、拉进 GTK/glib 桌面依赖链；libdbus-sys/dbus（2026-11-19 mark_note 实测）→ 系统总线类 crate，OHOS 无 D-Bus，patch tauri 也去不掉，得换实现或降级（R2-DEPS-013）；openssl-sys → 见 FP-021（那是 reqwest 默认特性，不是 GTK）",
        "glib-sys/gtk 系：重跑 t2h:port（R2-PORT-006 patch 掉 wry/tao）即可根除；libdbus-sys/dbus：换 zbus 或降级/桥接系统能力（别指望 patch tauri，也别硬配 pkg-config）；openssl-sys：走 FP-021 / R2-PORT-016。三者都**不要**去给交叉编译硬配 pkg-config",
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

    // FP-024（0.39.119，EcoPaste 首轮实测）：`cargo build` 卡在下载依赖，18 分钟零字节。
    // 现场判据：`rustc.exe` 一个都没起、cargo CPU 几乎为 0、`registry/cache` 不涨、
    // 连接落在 `146.75.x.x:443`（Fastly = crates.io CDN）——极易被误诊成"工具挂死"。
    // marker 取 cargo 自己的错误原文（唯一）；**卡住时并没有这条报错**，所以任务书侧
    // 另有"先看是不是在下载"的纪律，两条一起才治得住。
    lib.add(Fingerprint("FP-024", "spurious network error",
        "crates.io 连接抖动/超时：国内直连 `static.crates.io`、`index.crates.io`（Fastly CDN）经常慢、抖、断；表现是 `Downloading crates ...` 长时间不动，或直接报 spurious network error / failed to download from",
        "配国内镜像（R2-PORT-008 生成的 .cargo/config.toml 默认已带 rsproxy 稀疏索引）或设 HTTP 代理后重跑；git 依赖走 github 时另需 ghproxy/.insteadOf。**不要**判成代码或工具 bug，也不要对同一网络原样重试",
        "", PK_GUIDE))

    return lib
}

// ===== 用户级认知层（飞轮阶段 4，0.39.113）：内置库 + `~/.lingqu/flywheel/fingerprints.json` =====
//
// 为什么要有它（docs/AI自进化飞轮.md §8 阶段 4）：经验裁决入库后，用户若没登录 atomgit、
// 也不想给源仓提 PR，这条经验就只对本工程有效，下个工程又从零开始。**贡献是可选分享，
// 本地飞轮是默认自用**——两条轨道分开。
//
// 合并口径两条，都由单测钉住：
//   ① **用户级排前**：用户刚学到的坑通常比内置的泛串更具体，而**本表顺序即匹配顺序**
//      （0.39.99 的教训：FP-021 必须排在通用的 FP-016 之前，否则永远被泛串抢走）；
//   ② **同 id 用用户版本**：id 是身份不是位置——用户改写了 FP-012 的修法就该以他为准。
//
// 诚实边界：`R2-PORT-*` 规则是确定性的**文本变换函数**（`src/port/port.cj`），
// 一份 JSON 没法安全地执行它们 ⇒ 用户级层**不装可执行规则**，只装指纹与经验/技能；
// 要加规则仍得改仓（走 `--to repo` 的草稿 PR）。别把安全边界当便利丢掉。

/** 用户库文件的容器键（两种顶层形态都认：`{"fingerprints":[…]}` 与裸数组 `[…]`） */
public let USER_FP_CONTAINER_KEY: String = "fingerprints"

/** 取 JSON 字符串字段（不存在/类型不对给 ""）——用户库解析与"缺 id 自动编号"共用 */
public func fpStrFieldOf(o: JsonObject, key: String): String {
    match (o.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return ""
            }
        case None => return ""
    }
}

/**
 * 纯函数：从一份 JSON 对象解一条指纹。
 * 缺 `id` 或 `marker` 一律不要——认不出来的指纹只会污染匹配顺序。
 * `patchKind` 缺省按 **guide**（保守：guide 只给根因与修法，不会让 agent 去跑确定性改造）。
 */
public func fingerprintFromJson(o: JsonObject): Option<Fingerprint> {
    let id = fpStrFieldOf(o, "id").trimAscii()
    let marker = fpStrFieldOf(o, "marker")
    if (id.size == 0 || marker.size == 0) {
        return None
    }
    var kind = fpStrFieldOf(o, "patchKind").trimAscii()
    if (kind != PK_RULE && kind != PK_GUIDE) {
        kind = PK_GUIDE
    }
    return Some(Fingerprint(id, marker, fpStrFieldOf(o, "rootCause"),
        fpStrFieldOf(o, "fix"), fpStrFieldOf(o, "ruleId"), kind))
}

/**
 * 纯函数：解析用户级指纹 JSON（**宽容**：坏 JSON / 顶层形态不对 → 空表，绝不抛）。
 *
 * 为什么宽容：这份文件是用户手写的，一个逗号写错不该让整个诊断功能瞎掉；
 * 「加载到 0 条」由上层用条数如实报出来（`t2h:notes --action fp-list`），不静默。
 */
public func parseFingerprintsJson(text: String): ArrayList<Fingerprint> {
    let out = ArrayList<Fingerprint>()
    if (text.trimAscii().size == 0) {
        return out
    }
    var v: JsonValue
    try {
        v = JsonValue.fromStr(text)
    } catch (e: Exception) {
        let _ = e
        return out
    }
    var arr = JsonArray()
    match (v.kind()) {
        case JsonKind.JsArray => arr = v.asArray()
        case JsonKind.JsObject =>
            match (v.asObject().get(USER_FP_CONTAINER_KEY)) {
                case Some(k) =>
                    match (k.kind()) {
                        case JsonKind.JsArray => arr = k.asArray()
                        case _ => return out
                    }
                case None => return out
            }
        case _ => return out
    }
    var i: Int64 = 0
    while (i < arr.size()) {
        match (arr[i].kind()) {
            case JsonKind.JsObject =>
                match (fingerprintFromJson(arr[i].asObject())) {
                    case Some(fp) => out.add(fp)
                    case None => let _ = 0
                }
            case _ => let _ = 0
        }
        i += 1
    }
    return out
}

/**
 * 纯函数：合并内置库与用户库（**用户级排前 + 同 id 用用户版本**，其余内置按原顺序追加）。
 *
 * 同一份用户文件里重复写同一个 id：**先写的那条算**（后写的当笔误忽略，不吵不闹）。
 */
public func mergeFingerprintLibraries(builtin: ArrayList<Fingerprint>,
    user: ArrayList<Fingerprint>): ArrayList<Fingerprint> {
    let out = ArrayList<Fingerprint>()
    let seen = HashSet<String>()
    for (u in user) {
        let id = u.id.trimAscii()
        if (id.size == 0 || seen.contains(id)) {
            continue
        }
        seen.add(id)
        out.add(u)
    }
    for (b in builtin) {
        let id = b.id.trimAscii()
        if (seen.contains(id)) {
            continue
        }
        seen.add(id)
        out.add(b)
    }
    return out
}

/** 动作层（不读盘）：内置库 + 给定的用户库 JSON 文本；用户库为空/坏了就是内置库本身 */
public func fingerprintLibraryWithUser(userJson: String): ArrayList<Fingerprint> {
    let builtin = fingerprintLibrary()
    let user = parseFingerprintsJson(userJson)
    if (user.size == 0) {
        return builtin
    }
    return mergeFingerprintLibraries(builtin, user)
}

/** 纯函数：下一个用户级指纹 id（`FP-U001` 起，取已有最大号 +1；不覆盖用户自己指定的 id） */
public func nextUserIdOf(existing: ArrayList<Fingerprint>): String {
    var max: Int64 = 0
    for (fp in existing) {
        let id = fp.id.trimAscii()
        if (!id.startsWith("FP-U")) {
            continue
        }
        var num: Int64 = 0
        var digits = 0
        for (b in id[4..].toArray()) {
            if (b < 48 || b > 57) {
                break
            }
            num = num * 10 + (Int64(b) - 48)
            digits += 1
        }
        if (digits > 0 && num > max) {
            max = num
        }
    }
    let next = max + 1
    var s = "FP-U"
    if (next < 10) {
        s += "00"
    } else if (next < 100) {
        s += "0"
    }
    return s + "${next}"
}

/**
 * 对构建/运行日志文本做指纹匹配（T4-7a 纯函数）。
 * 返回全部命中（同一指纹只报一次，取首次命中的日志行作证据）。
 */
public func diagnoseLog(logText: String): ArrayList<Diagnosis> {
    return diagnoseLogWith(logText, fingerprintLibrary())
}

/**
 * 同 `diagnoseLog`，但**库由调用方给**（用户级认知层合并后的库从这里进来，0.39.113）。
 *
 * 为什么不直接让 `diagnoseLog` 自己读盘：单测必须确定性——开发机上恰好有一份
 * `~/.lingqu/flywheel/fingerprints.json` 时，内置库的用例不该跟着变（D-009）。
 */
public func diagnoseLogWith(logText: String, lib: ArrayList<Fingerprint>): ArrayList<Diagnosis> {
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
            case "R2-PORT-017" => file = "src-tauri/src/ohos_bridge.rs"
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

// ===== 指纹清单与判据（0.39.116）=====
//
// 0.39.115 给「17 条改造规则」立了单点清单，并把"文档里的条数"做成能红的判据；
// 指纹侧做同款收口，但**不另立一份清单**：`fingerprintLibrary()` 本身就是唯一清单，
// 再抄一份只会多一个漂移源（§4-63：能算出来的就别手写）。
// 这里补的是三类判据：
//   ① 编号连续性（含保留空位）—— 只靠"数一遍"发现不了缺号/乱序/重复；
//   ② 库 ↔ 技能文档 / 门面文档（**双向**）—— 文档引用了不存在的编号、文档写着旧条数都要红；
//   ③ 库 ↔ 规则清单 —— `patchKind=rule` 的指纹必须指向已登记的 `R2-PORT-*`，
//      否则 agent 拿到的是一条死路（§4-130：说明书指错地方比没写更坏）。
//
// 为什么编号留着空位：`FP-008` / `FP-009` 在 0.13.0 之前就**从未存在**过，不补编是为了让
// 历史落档/日志里引用的编号永远指同一个东西。所以"连号"判据必须显式跳过这两个，
// 否则会把一个历史决定判成漂移——判据自造的假红比漏判更消磨人（§4-156 同族）。

/** 保留空位编号：从未存在过、也不补编（跳过后才算连号） */
public let FP_RESERVED_GAP_IDS: Array<String> = ["FP-008", "FP-009"]

/** 指纹编号清单（**顺序即匹配顺序**：先特异后一般） */
public func fingerprintIds(): Array<String> {
    let out = ArrayList<String>()
    for (fp in fingerprintLibrary()) {
        out.add(fp.id)
    }
    return out.toArray()
}

/** 指纹条数（库就是单点，不另存一份数字） */
public func fingerprintCount(): Int64 {
    return fingerprintLibrary().size
}

/**
 * 编号范围文本（如 `FP-001…FP-023`）——**由库首尾算出**，
 * 文档里引用的就是这个串，所以它不会与条数脱钩（§4-63）。
 */
public func fingerprintRangeTextOf(): String {
    let ids = fingerprintIds()
    if (ids.size == 0) {
        return ""
    }
    return "${ids[0]}…${ids[ids.size - 1]}"
}

/** 编号是否在库里 */
public func fingerprintKnownOf(id: String): Bool {
    for (fp in fingerprintLibrary()) {
        if (fp.id == id) {
            return true
        }
    }
    return false
}

/** 是否是保留空位编号（存在过？没有——只是不补编） */
public func fingerprintReservedGapOf(id: String): Bool {
    for (g in FP_RESERVED_GAP_IDS) {
        if (g == id) {
            return true
        }
    }
    return false
}

/**
 * 编号连续性检查：库里的编号必须恰好是 `FP-001..FP-NNN` **跳过保留空位**的那一组，
 * 无重复、无缺号、无越界；返回空串表示没问题。
 *
 * **只看集合、不看数组顺序**：库的数组顺序是**匹配顺序**（具体指纹要排在泛串之前，
 * 所以 `FP-022` 就夹在 `FP-004` 与 `FP-005` 之间，`FP-021` 排在 `FP-016` 之前）。
 * 把"顺序"也塞进这条判据，就会把一个刻意的设计判成漂移——这条教训是本轮实测撞到的
 * （第一版按位比编号，真库当场红）。匹配顺序由单测里的先后断言单独钉住。
 *
 * 判据本身用三位补零的字符串比较，不解析数字（§4-116 同族：别逐字节拼字符串再转数字）。
 */
public func fingerprintNumberingTextOf(ids: Array<String>): String {
    let prefix = "FP-"
    if (ids.size == 0) {
        return "清单是空的"
    }
    var seen = ArrayList<String>()
    for (id in ids) {
        if (id.size != prefix.size + 3) {
            return "编号不是 `FP-` + 三位数字：${id}"
        }
        for (s in seen) {
            if (s == id) {
                return "编号重复：${id}"
            }
        }
        seen.add(id)
    }
    // 按"应有的一组编号"造出期望集合：001 起连号，跳过保留空位
    let expected = ArrayList<String>()
    var n: Int64 = 1
    while (expected.size < ids.size) {
        if (n > 999) {
            return "编号超出 FP-999（当前 ${ids.size} 条）"
        }
        let want = prefix + pad3Of(n)
        n += 1
        if (fingerprintReservedGapOf(want)) {
            continue
        }
        expected.add(want)
    }
    for (id in ids) {
        var hit = false
        for (w in expected) {
            if (w == id) {
                hit = true
                break
            }
        }
        if (!hit) {
            return "编号不在连续范围里：${id}（应为 ${expected[0]}…${expected[expected.size - 1]}，跳过保留空位）"
        }
    }
    return ""
}

/**
 * marker 撞车检查：同一个 marker（忽略大小写，匹配走小写）出现两次，
 * 后一条永远不会被命中——诊断会静默归因给前一条。
 */
public func fingerprintMarkerDupesOf(fps: ArrayList<Fingerprint>): ArrayList<String> {
    let out = ArrayList<String>()
    var keys = ArrayList<String>()
    var owners = ArrayList<String>()
    for (fp in fps) {
        let key = diagLowerOf(fp.marker)
        var dupAt: Int64 = -1
        for (j in 0..keys.size) {
            if (keys[j] == key) {
                dupAt = j
                break
            }
        }
        if (dupAt >= 0) {
            out.add("${fp.id} 与 ${owners[dupAt]} 的 marker 相同（后者永远命不中）：${fp.marker}")
            continue
        }
        keys.add(key)
        owners.add(fp.id)
    }
    return out
}

/**
 * 库 ↔ 规则清单：`patchKind=rule` 的指纹必须关联一条**已登记**的 `R2-PORT-*`；
 * `patchKind` 只允许 rule / guide。返回空数组表示一致。
 */
public func fingerprintRuleLinkGapsOf(fps: ArrayList<Fingerprint>): ArrayList<String> {
    let out = ArrayList<String>()
    for (fp in fps) {
        if (fp.patchKind != PK_RULE && fp.patchKind != PK_GUIDE) {
            out.add("${fp.id} 的 patchKind 既不是 rule 也不是 guide：${fp.patchKind}")
            continue
        }
        if (fp.patchKind != PK_RULE) {
            continue
        }
        if (fp.ruleId.size == 0) {
            out.add("${fp.id} 是 rule 档却没关联规则编号（诊断只会说'重跑 port'，说不出哪条）")
        } else if (!portRuleKnownOf(fp.ruleId)) {
            out.add("${fp.id} 关联的 ${fp.ruleId} 不在规则清单里")
        }
    }
    return out
}

/**
 * 从 `text` 的下标 `at`（`FP-` 起点）取编号；**后面不是三位数字就返回空串**。
 * 守卫的意义同 `r2PortIdFrom`：别把裸前缀切成垃圾串（§4-156 同族）。
 */
public func fpIdFrom(text: String, at: Int64): String {
    let marker = "FP-"
    let start = at + marker.size
    if (text.size < start + 3) {
        return ""
    }
    for (i in 0..3) {
        let c = text[start + i]
        if (c < 48 || c > 57) {
            return ""
        }
    }
    return marker + text[start..start + 3]
}

/** 扫一段文本里出现的全部指纹编号（去重、保序）——文档 ↔ 库 双向校验用 */
public func fingerprintIdsInTextOf(text: String): ArrayList<String> {
    let out = ArrayList<String>()
    let marker = "FP-"
    var rest = text
    while (true) {
        var at: Int64 = -1
        match (rest.indexOf(marker)) {
            case Some(i) => at = i
            case None => at = -1
        }
        if (at < 0) {
            break
        }
        let id = fpIdFrom(rest, at)
        if (id.size > 0) {
            var dup = false
            for (s in out) {
                if (s == id) {
                    dup = true
                    break
                }
            }
            if (!dup) {
                out.add(id)
            }
        }
        rest = rest[(at + marker.size)..]
    }
    return out
}

/** 从 `end` 往前跳过空格/星号/反引号，取紧邻的数字串（取不到返回空串） */
func digitsBeforeOf(text: String, end: Int64): String {
    let bytes = text.toArray()
    var i = end - 1
    while (i >= 0) {
        let b = bytes[i]
        if (b == 32 || b == 42 || b == 96) {
            i -= 1
            continue
        }
        break
    }
    let stop = i + 1
    while (i >= 0) {
        let b = bytes[i]
        if (b < 48 || b > 57) {
            break
        }
        i -= 1
    }
    let start = i + 1
    if (start >= stop) {
        return ""
    }
    return text[start..stop]
}

/** 纯数字串转 Int64（不受地域设置影响；超长串在文档里不会出现） */
func digitsToInt64Of(run: String): Int64 {
    var n: Int64 = 0
    for (b in run.toArray()) {
        n = n * 10 + Int64(b) - 48
    }
    return n
}

/**
 * 从文档里抽出「N 条指纹」/「N 条错误指纹」的**条数说法**（去重、保序）。
 * 只认这两种形态：`21 条指纹` / `21 条错误指纹`；表格里的 `✅ 21 条 |` 不算
 * （表格那种靠"必须出现 `${count} 条`"的粗判据兜底，见单测）。
 */
public func fingerprintCountClaimsOf(text: String): ArrayList<Int64> {
    let out = ArrayList<Int64>()
    for (tail in ["条错误指纹", "条指纹"]) {
        var rest = text
        while (true) {
            var at: Int64 = -1
            match (rest.indexOf(tail)) {
                case Some(i) => at = i
                case None => at = -1
            }
            if (at < 0) {
                break
            }
            let run = digitsBeforeOf(rest, at)
            if (run.size > 0) {
                let n = digitsToInt64Of(run)
                if (!out.contains(n)) {
                    out.add(n)
                }
            }
            rest = rest[(at + tail.size)..]
        }
    }
    return out
}

/**
 * 文档里的每条「N 条指纹」都应当等于实际条数。返回空数组表示没有说错的条数；
 * **说错的**按「文档写着 N 条指纹，实际 M 条」逐条列出（不去重成一句，方便直接看出改哪处）。
 */
public func fingerprintCountClaimGapsOf(docName: String, docText: String, expected: Int64): ArrayList<String> {
    let gaps = ArrayList<String>()
    for (n in fingerprintCountClaimsOf(docText)) {
        if (n != expected) {
            gaps.add("${docName} 写着 ${n} 条指纹，实际 ${expected} 条")
        }
    }
    return gaps
}

/**
 * 文档 → 库：文档里点名的指纹编号必须真实存在（保留空位不算——那是历史决定，允许被提到）。
 * 缺口的写法指名「哪个文档引用了哪条不存在的指纹」，agent 一点就能找到。
 */
public func fingerprintDocIdGapsOf(docName: String, docText: String): ArrayList<String> {
    let gaps = ArrayList<String>()
    for (id in fingerprintIdsInTextOf(docText)) {
        if (fingerprintReservedGapOf(id)) {
            continue
        }
        if (!fingerprintKnownOf(id)) {
            gaps.add("${docName} 引用了 ${id}，但指纹库里没有这一条")
        }
    }
    return gaps
}
