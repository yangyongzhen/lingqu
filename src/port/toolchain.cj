package lingqu.port

import std.collection.*
import std.fs.*

/*
 * T4-3 工具链落盘：`rust-toolchain.toml` + `.cargo/config.toml` 生成。
 *
 * 模板逐字来自 habit-tree @ ohos 分支的真实文件（已真机验证），只把
 * Windows 专属的 SDK 绝对路径参数化——`sdkNative` 由调用方传入
 * （OHOS native SDK 的 sysroot 上级目录），其余内容不动。
 *
 * 为什么 gnullvm：llvm-mingw 环境里默认 GNU 工具链链接器找不到 -lgcc_eh，
 * 必须用 gnullvm（lld + compiler-rt，无需 libgcc）。
 * 为什么直接用 NDK clang 作链接器：NDK 自带的 aarch64-unknown-linux-ohos-clang
 * 是 Unix shell 脚本，Windows 跑不了。
 */

/** `rust-toolchain.toml` 全文（host 工具链按宿主平台二选一） */
public func rustToolchainToml(hostIsWindows: Bool): String {
    var channel = "stable-x86_64-unknown-linux-gnu"
    if (hostIsWindows) {
        channel = "stable-x86_64-pc-windows-gnullvm"
    }
    var s = ""
    s += "# === lingqu: R2-PORT-007 ===\n"
    s += "# llvm-mingw 环境：默认 GNU 工具链链接器找不到 -lgcc_eh，\n"
    s += "# 必须使用 gnullvm 工具链（基于 lld + compiler-rt，无需 libgcc）。\n"
    s += "# cargo tauri ohos build 内部调用的 cargo 同样遵循此文件。\n"
    s += "[toolchain]\n"
    s += "channel = \"${channel}\"\n"
    s += "targets = [\"aarch64-unknown-linux-ohos\"]\n"
    return s
}

/**
 * 纯函数：把路径改成能安全放进 TOML **双引号串**的形态。
 *
 * 0.39.79 实测（rust-music-2 全流程）：`sdkNative` 传入 Windows 形态
 * `D:\oh\DevEcoStudio\sdk\...\native` 时，生成的 `.cargo/config.toml` 里是
 * `linker = "D:\oh\..."` —— TOML 只认 `\b \t \n \f \r \\ \" \uXXXX`，
 * `\o` 是非法转义，cargo 直接报：
 *   `could not parse TOML configuration in ...\.cargo\config.toml`
 *   `missing escaped value, expected 'b', 'e', 'f', 'n', 'r', '\\', '"', 'x', 'u', 'U'`
 * 于是 build 连 manifest 都读不进去（exit=101）。cargo 在 Windows 上同样认
 * 正斜杠，所以统一转 `/` 最省事，也顺带避开 `\t`/`\n` 这类"看着合法其实变形"的坑。
 */
public func tomlSafePath(p: String): String {
    return p.replace("\\", "/")
}

/** `.cargo/config.toml` 全文（sdkNative = OHOS native SDK 根目录） */
public func cargoConfigToml(sdkNative: String): String {
    let sdk = tomlSafePath(sdkNative)
    var s = ""
    s += "# === lingqu: R2-PORT-008 ===\n"
    s += "# OHOS (OpenHarmony) 交叉编译配置 —— 由 lingqu t2h:port 生成\n"
    s += "# 直接以 NDK clang 作链接器（NDK 自带 aarch64-unknown-linux-ohos-clang 是 Unix shell 脚本）。\n"
    s += "[target.aarch64-unknown-linux-ohos]\n"
    s += "linker = \"${sdk}/llvm/bin/clang\"\n"
    s += "ar = \"${sdk}/llvm/bin/llvm-ar\"\n"
    s += "rustflags = [\n"
    s += "    \"-C\", \"link-arg=-target\",\n"
    s += "    \"-C\", \"link-arg=aarch64-linux-ohos\",\n"
    s += "    \"-C\", \"link-arg=--sysroot=${sdk}/sysroot\",\n"
    s += "    \"-C\", \"link-arg=-fuse-ld=lld\",\n"
    s += "    \"-C\", \"link-arg=--rtlib=compiler-rt\",\n"
    s += "]\n"
    s += "\n"
    s += "# C 依赖（cc crate）编译环境变量：纯 Rust 依赖树用不到，备用\n"
    s += "[env]\n"
    s += "# 0.39.79 实测（rust-music-2）：ohos-arkui-sys 的 build.rs 直接\n"
    s += "# `env::var(\"OHOS_NDK_HOME\").expect(...)`，缺它 build 当场 panic（exit=101）。\n"
    s += "# cargo 的 [env] 段对 build script 同样生效，所以写在这里工程就自足了。\n"
    s += "OHOS_NDK_HOME = \"${sdk}\"\n"
    s += "CC_aarch64_unknown_linux_ohos = \"${sdk}/llvm/bin/clang\"\n"
    s += "AR_aarch64_unknown_linux_ohos = \"${sdk}/llvm/bin/llvm-ar\"\n"
    s += "CFLAGS_aarch64_unknown_linux_ohos = \"-target aarch64-linux-ohos --sysroot=${sdk}/sysroot -D__MUSL__\"\n"
    s += cargoMirrorSection()
    return s
}

/**
 * 国内镜像段（0.39.119）：**默认给上**。
 *
 * 现场（2026-11-19 EcoPaste 首轮真实迁移）：`cargo build` 卡在 `Downloading crates ...`
 * 整整 **18 分钟**一个字节没进——`static.crates.io` / `index.crates.io` 都走 Fastly
 * （连接落在 `146.75.x.x:443`），国内直连经常慢、抖，甚至挂到 cargo 自己超时。
 * 那时的现场极易误诊：`rustc.exe` **一个都没起**、cargo CPU 几乎为 0、`registry/cache`
 * 大小不动——看着像"工具挂死"，其实是网络。
 *
 * 所以迁移台生成 `.cargo/config.toml` 时顺手把 **rsproxy 稀疏索引**配上：一个工程配一次，
 * 后面 `port` → `build` → agent 自己重跑都不再等跨境 CDN。不想用就删掉这两段（或换成自己的源）。
 */
public func cargoMirrorSection(): String {
    var s = ""
    s += "\n"
    s += "# === lingqu: R2-PORT-008 国内镜像 ===\n"
    s += "# crates.io 走 Fastly，国内直连常卡在 `Downloading crates ...`（2026-11-19 实测 18 分钟才通）；\n"
    s += "# 换 rsproxy 稀疏索引后同一工程秒级起步。不想用就删掉这两段（或改成你自己的源）。\n"
    s += "[source.crates-io]\n"
    s += "replace-with = \"cn-rsproxy\"\n"
    s += "\n"
    s += "[source.cn-rsproxy]\n"
    s += "registry = \"sparse+https://rsproxy.cn/index/\"\n"
    return s
}

/** 只含 `[env]` 段的片段：给"已有 .cargo/config.toml 但缺 C 依赖环境"的工程追加用 */
public func cargoEnvOnlyToml(sdkNative: String): String {
    let sdk = tomlSafePath(sdkNative)
    var s = ""
    s += "\n# === lingqu: R2-PORT-008（补齐 C 依赖交叉编译环境）===\n"
    s += "# 缺这段时 ring / openssl 这类 C 依赖的 cc-rs 会退回宿主 `cc`，报\n"
    s += "# `cc-rs: command did not execute successfully: \"cc\" … --target=aarch64-unknown-linux-ohos`。\n"
    s += "[env]\n"
    s += "OHOS_NDK_HOME = \"${sdk}\"\n"
    s += "CC_aarch64_unknown_linux_ohos = \"${sdk}/llvm/bin/clang\"\n"
    s += "AR_aarch64_unknown_linux_ohos = \"${sdk}/llvm/bin/llvm-ar\"\n"
    s += "CFLAGS_aarch64_unknown_linux_ohos = \"-target aarch64-linux-ohos --sysroot=${sdk}/sysroot -D__MUSL__\"\n"
    return s
}

/**
 * T4-3 编排：检查两个工具链文件是否已存在，缺则给出要写的内容。
 * 只生成 outcome（含 fullContent），写盘由命令层统一做（ dry-run 不动文件）。
 */
public func toolchainOutcomes(srcTauriDir: String, sdkNative: String, hostIsWindows: Bool): ArrayList<RuleOutcome> {
    let out = ArrayList<RuleOutcome>()

    // R2-PORT-007 rust-toolchain.toml
    let tcPath = srcTauriDir + "/rust-toolchain.toml"
    let tcContent = rustToolchainToml(hostIsWindows)
    var o7 = RuleOutcome("R2-PORT-007", false, "", "", tcContent)
    o7.tier = T_AUTO
    if (fileContains(tcPath, "[toolchain]")) {
        o7.note = "rust-toolchain.toml 已存在且含 [toolchain]——跳过"
    } else {
        o7.applied = true
        o7.note = "生成 rust-toolchain.toml（gnullvm + aarch64-unknown-linux-ohos）"
    }
    out.add(o7)

    // R2-PORT-008 .cargo/config.toml
    let ccPath = srcTauriDir + "/.cargo/config.toml"
    let ccContent = cargoConfigToml(sdkNative)
    var o8 = RuleOutcome("R2-PORT-008", false, "", "", ccContent)
    o8.tier = T_AUTO
    if (fileContains(ccPath, "[env]") && fileContains(ccPath, "CC_aarch64_unknown_linux_ohos")) {
        o8.note = ".cargo/config.toml 已配 OHOS target + [env] C 依赖环境——跳过"
    } else if (fileContains(ccPath, "aarch64-unknown-linux-ohos")) {
        // 0.39.8 实测教训：只判"文件里出现过 aarch64-unknown-linux-ohos"会误判成已配好。
        // m3u8dl-tauri 的 config.toml 有 target 段却**没有 [env] 段** → ring 的 cc-rs
        // 退回宿主 `cc` → `cc-rs: command did not execute successfully: "cc" …
        // --target=aarch64-unknown-linux-ohos`，交叉编译必然失败。
        // 既不覆盖用户既有的 linker 配置，也不假装已配好：降成 guide，
        // 把缺的那段作为方案交给人/agent 追加（applied=false ⇒ 命令层不写盘）。
        o8.tier = T_GUIDE
        o8.needsHuman = true
        o8.after = cargoEnvOnlyToml(sdkNative)
        o8.note = ".cargo/config.toml 有 OHOS target 段但缺 [env] 的 CC_/AR_/CFLAGS_" +
            "——C 依赖（ring/openssl 等）会用宿主 cc 编译而失败；把 after 段追加进去（不覆盖现有 linker 配置）"
    } else {
        o8.applied = true
        o8.note = "生成 .cargo/config.toml（NDK clang 链接器 + sysroot rustflags + [env] C 依赖环境）"
    }
    out.add(o8)

    return out
}

/** 文件存在且包含标记串（不存在的文件返回 false，不算错误） */
public func fileContains(path: String, marker: String): Bool {
    try {
        let text = String.fromUtf8(File.readFrom(path))
        return text.contains(marker)
    } catch (e: Exception) {
        return false
    }
}
