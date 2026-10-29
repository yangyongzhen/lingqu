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

/** `.cargo/config.toml` 全文（sdkNative = OHOS native SDK 根目录） */
public func cargoConfigToml(sdkNative: String): String {
    var s = ""
    s += "# === lingqu: R2-PORT-008 ===\n"
    s += "# OHOS (OpenHarmony) 交叉编译配置 —— 由 lingqu t2h:port 生成\n"
    s += "# 直接以 NDK clang 作链接器（NDK 自带 aarch64-unknown-linux-ohos-clang 是 Unix shell 脚本）。\n"
    s += "[target.aarch64-unknown-linux-ohos]\n"
    s += "linker = \"${sdkNative}/llvm/bin/clang\"\n"
    s += "ar = \"${sdkNative}/llvm/bin/llvm-ar\"\n"
    s += "rustflags = [\n"
    s += "    \"-C\", \"link-arg=-target\",\n"
    s += "    \"-C\", \"link-arg=aarch64-linux-ohos\",\n"
    s += "    \"-C\", \"link-arg=--sysroot=${sdkNative}/sysroot\",\n"
    s += "    \"-C\", \"link-arg=-fuse-ld=lld\",\n"
    s += "    \"-C\", \"link-arg=--rtlib=compiler-rt\",\n"
    s += "]\n"
    s += "\n"
    s += "# C 依赖（cc crate）编译环境变量：纯 Rust 依赖树用不到，备用\n"
    s += "[env]\n"
    s += "CC_aarch64_unknown_linux_ohos = \"${sdkNative}/llvm/bin/clang\"\n"
    s += "AR_aarch64_unknown_linux_ohos = \"${sdkNative}/llvm/bin/llvm-ar\"\n"
    s += "CFLAGS_aarch64_unknown_linux_ohos = \"-target aarch64-linux-ohos --sysroot=${sdkNative}/sysroot -D__MUSL__\"\n"
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
    if (fileContains(ccPath, "aarch64-unknown-linux-ohos")) {
        o8.note = ".cargo/config.toml 已配置 OHOS target——跳过"
    } else {
        o8.applied = true
        o8.note = "生成 .cargo/config.toml（NDK clang 链接器 + sysroot rustflags）"
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
