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

// ===== 第 8 道：HAP 装配闸（T5-3）=====
//
// 判据来自实测（habit-tree @ ohos 的 entry-default-signed.hap，1.40 MB）：
//   必须含 `module.json`（HAP 清单）与 `libs/arm64-v8a/*.so`（原生库）；
//   **不应含 `rawfile/`** —— ArkWeb 下前端被编进 .so，rawfile 里的副本是死资源
//   （要么永远读不到，要么白白撑大包体）。
public func checkHapGate(built: Bool, hasModuleJson: Bool, hasArm64So: Bool, rawfileCount: Int64,
    expectedSoName: String, hasExpectedSo: Bool): GateReport {
    let rep = GateReport()
    if (!built) {
        rep.fail("HAP 闸：assembleHap 没成功（看 hvigor 输出与 .lingqu/hap/<工程>.log）")
    }
    if (built && !hasModuleJson) {
        rep.fail("HAP 闸：产物里没有 module.json——装的不是合法 HAP")
    }
    if (built && !hasArm64So) {
        rep.fail("HAP 闸：产物里没有 libs/arm64-v8a/*.so——原生库没打进去")
    }
    // 关键：**只数 .so 数量不够**。DevEco 模板自带 libentry.so（几 KB 的 add 示例桩），
    // 会让"有 arm64 .so"这条假通过；真正决定界面能不能出来的是应用自己的
    // `lib<EntryAbility.moduleName>.so`（2026-10-31 真机白屏就是这么漏的）
    if (built && expectedSoName != "" && !hasExpectedSo) {
        rep.fail("HAP 闸：产物里没有 ${expectedSoName}——应用代码没打进 HAP（先跑「交叉编译」拿到 .so，装配会自动拷进 entry/libs/arm64-v8a）")
    }
    if (rawfileCount > 0) {
        rep.fail("HAP 闸：发现 ${rawfileCount} 个 rawfile/ 条目——前端已在 .so 里，这些是死资源（应清掉）")
    }
    return rep
}

/**
 * 从 hvigor 输出里认**签名根因**（纯函数；返回 "" = 没命中）。
 *
 * 为什么单拎出来：`assembleHap 没成功` 这句话不指路，而真正的根因藏在几十行 task 日志中间。
 * 0.39.9 实测两条：
 *
 *   · `00303074` —— 签名材料的 bundleName 与 `AppScope/app.json5` 不一致。
 *     **profile 是按包名签发的**，本机没有这个包名的材料就装不上；写回别的包名的材料同样报这条。
 *     正解：在 DevEco 里对**该工程**点一次自动签名（需登录）——属必须计入 A3 的人工介入。
 *   · `00303107 Invalid storeFile value` —— 材料文件不存在（被删/换机器）。
 *
 * 这两条以前只以 hvigor 原文形式躺在 `.lingqu/hap/<工程>.log` 里，得人自己去扒；
 * 现在直接进 HAP 闸的 failures，界面第一眼就能看到"差哪一步、该找谁"。
 */
public func hapSignHint(logText: String): String {
    if (logText.contains("00303074")) {
        return "HAP 闸：签名材料的包名与工程不一致（hvigor 00303074）——" +
            "profile 按包名签发，本机没有该包名的材料时，写回/抄用别的包名的材料也会报这一条。" +
            "先在 DevEco 对本工程自动签名一次（需登录），再重跑装配；材料清单见「签名体检」"
    }
    if (logText.contains("00303107")) {
        return "HAP 闸：签名材料文件不存在（hvigor 00303107 Invalid storeFile）——" +
            "build-profile.json5 的 signingConfigs 指向的 .p12/.cer/.p7b 已被删除或换机器丢了；" +
            "先跑「签名体检」看材料是否齐全，缺就重新自动签名一次"
    }
    // 00308018 / dev-eco-studio-script（0.39.51，juCang 实测）：与签名、代码都无关——
    // hvigorfile 里的 tauri 钩子要读 dev server 的 addr 文件，非 dev 场景必 panic。
    if (logText.contains("dev-eco-studio-script") || logText.contains("server-addr") ||
        logText.contains("00308018")) {
        return "HAP 闸：hvigor 的 tauri 钩子失败（00308018）——它在跑 `cargo tauri ohos dev-eco-studio-script`，" +
            "而那条脚本要读 **dev server** 的 addr 文件（%TEMP%\\<包名>-server-addr）；" +
            "非 dev 场景没有这个文件，tauri-cli 直接 panic。" +
            "正解：让 gen/ohos/entry/hvigorfile.ts 不再跑这个钩子（本工具 t2h:hap 已把 lib<模块>.so 装配进 libs/arm64-v8a，" +
            "不依赖它编 Rust）；或先 `cargo tauri ohos dev` 起 dev server 再装配"
    }
    return ""
}

// ===== 第 8 道：鸿蒙产物闸（0.39.81）=====
//
// 挡的是"编译成功、但不是移植产物"这类**最危险的假绿**：
// 工程只有 bin target（Cargo.toml 里没有 `[lib] crate-type = ["cdylib"]`）时，
// cargo 编出来的是 `target/<target>/release/<工程名>` **可执行文件**，不是 `lib<name>.so`；
// 而 HAP 里要的、`t2h:hap` 装配的、真机加载的都是 `.so`。
//
// 旧版只判 exitCode 与 errorCount，于是把 rust-music-2 编出来的 **11,084,368 字节 exe**
// 当成移植产物报了通过（0.39.79 实测），后续 hap 才在"找不到 lib*.so"处一脸茫然。
// 闸门要说的正是这句话：**编译过了，但移植产物没有**。

/** 从一行 `key = "value"` 里取值（`[lib]`/`[package]` 的 `name` 用）；取不到给空串 */
public func tomlValueOfLine(line: String, key: String): String {
    let t = line.trimAscii()
    if (!t.startsWith(key)) {
        return ""
    }
    var rest = t[key.size..].trimAscii()
    if (!rest.startsWith("=")) {
        return ""
    }
    rest = rest[1..].trimAscii()
    if (rest.startsWith("\"") || rest.startsWith("'")) {
        let q = rest[0..1]
        let body = rest[1..]
        match (body.indexOf(q)) {
            case Some(e) => return body[0..e]
            case None => return ""
        }
    }
    // 无引号：整行剩余部分即值——数组 `crate-type = ["cdylib", "rlib"]` 里的逗号与空格是内容，
    // 按空白/逗号切只会拿到 `["cdylib",` 这种半截值（0.39.81 单测抓到）。只剥行尾注释。
    match (rest.indexOf("#")) {
        case Some(i) => return rest[0..i].trimAscii()
        case None => return rest.trimAscii()
    }
}

/**
 * 鸿蒙侧期望的库文件名（纯函数）：`[lib] name` 优先，否则 `[package] name`（`-` 换 `_`）。
 *
 * cdylib 产物名由 cargo 的 **lib target name** 决定：`lib<name>.so`，
 * 与 `[package] name` 不同（`rust-music` 的包名带连字符，库名是 `rust_music`）。
 */
public func expectedLibNameOf(cargoToml: String, fallback: String): String {
    let text = cargoToml.replace("\r\n", "\n")
    var pkg = ""
    var lib = ""
    var section = ""
    for (raw in text.split("\n", -1)) {
        let line = raw.trimAscii()
        if (line.size == 0 || line.startsWith("#")) {
            continue
        }
        if (line.startsWith("[")) {
            section = line
            continue
        }
        if (section.startsWith("[lib]")) {
            if (lib == "") {
                lib = tomlValueOfLine(line, "name")
            }
            continue
        }
        if (section.startsWith("[package]") && pkg == "") {
            pkg = tomlValueOfLine(line, "name")
        }
    }
    var name = ""
    if (lib != "") {
        name = lib
    } else if (pkg != "") {
        name = pkg.replace("-", "_")
    } else {
        name = fallback.replace("-", "_")
    }
    if (name == "") {
        name = "app"
    }
    return "lib${name}.so"
}

/** Cargo.toml 是否声明了 cdylib 产物（`[lib] crate-type` 里含 cdylib，支持跨行数组） */
public func hasCdylibCrateType(cargoToml: String): Bool {
    let text = cargoToml.replace("\r\n", "\n")
    var section = ""
    for (raw in text.split("\n", -1)) {
        let line = raw.trimAscii()
        if (line.size == 0 || line.startsWith("#")) {
            continue
        }
        if (line.startsWith("[")) {
            section = line
            continue
        }
        if (!section.startsWith("[lib]")) {
            continue
        }
        if (line.contains("cdylib")) {
            return true
        }
    }
    return false
}

/**
 * 鸿蒙产物闸：编译成功就必须看到 `lib<name>.so`。
 *
 * 编译本身没过时**不重复报**（那是编译闸/回归闸的事，两条失败其实是同一件事）。
 */
public func checkOhosArtifactGate(exitCode: Int64, errorCount: Int64, expectedSo: String,
    actualSo: String, hasCdylib: Bool): GateReport {
    let rep = GateReport()
    if (exitCode != 0 || errorCount > 0) {
        return rep
    }
    if (actualSo != "") {
        return rep
    }
    let expect = if (expectedSo != "") {
        expectedSo
    } else {
        "lib*.so"
    }
    var msg = "鸿蒙产物闸：编译成功但没产出 ${expect}——没有 .so 就装不进 HAP，不能算移植成功"
    if (!hasCdylib) {
        msg += "；工程的 Cargo.toml 里没有 `[lib] crate-type = [\"cdylib\"]`，cargo 只编出了可执行文件："
        msg += "先把它改成库产物（补 `[lib]` 段 + 让 tauri 以 lib 形式链接）再谈移植"
    }
    rep.fail(msg)
    return rep
}
