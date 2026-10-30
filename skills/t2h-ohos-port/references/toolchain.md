# 工具链与交叉编译配置（R2-PORT-007 / 008）

> 语料：habit-tree `src-tauri/rust-toolchain.toml` + `.cargo/config.toml`（真机验证）、
> AtomMQTT 的 `OHOS-CROSS-COMPILE-GUIDE.md`、lingqu `src/port/toolchain.cj`（模板化实现）。
> 模板里 SDK 路径已参数化（`$OHOS_NATIVE` = OHOS native SDK 根目录）。

## rust-toolchain.toml（放 `src-tauri/` 下）

### Windows 宿主：必须 gnullvm

```toml
# === lingqu: R2-PORT-007 ===
[toolchain]
channel = "stable-x86_64-pc-windows-gnullvm"
targets = ["aarch64-unknown-linux-ohos"]
```

- **为什么 gnullvm**：llvm-mingw 环境里默认 GNU 工具链的链接器
  （`x86_64-w64-mingw32-gcc` → clang+lld）**找不到 `-lgcc_eh`**；
  gnullvm 基于 lld + compiler-rt，无需 libgcc。
- `cargo tauri ohos build` 内部调用的 cargo 同样遵循此文件。

### Linux 宿主：默认 GNU 即可

```toml
[toolchain]
channel = "stable-x86_64-unknown-linux-gnu"
targets = ["aarch64-unknown-linux-ohos"]
```

## .cargo/config.toml（放 `src-tauri/.cargo/` 下）

```toml
# === lingqu: R2-PORT-008 ===
[target.aarch64-unknown-linux-ohos]
linker = "$OHOS_NATIVE/llvm/bin/clang"
ar = "$OHOS_NATIVE/llvm/bin/llvm-ar"
rustflags = [
    "-C", "link-arg=-target",
    "-C", "link-arg=aarch64-linux-ohos",
    "-C", "link-arg=--sysroot=$OHOS_NATIVE/sysroot",
    "-C", "link-arg=-fuse-ld=lld",
    "-C", "link-arg=--rtlib=compiler-rt",
]

# C 依赖（cc crate）编译环境变量：纯 Rust 依赖树用不到，备用
[env]
CC_aarch64_unknown_linux_ohos = "$OHOS_NATIVE/llvm/bin/clang"
AR_aarch64_unknown_linux_ohos = "$OHOS_NATIVE/llvm/bin/llvm-ar"
CFLAGS_aarch64_unknown_linux_ohos = "-target aarch64-linux-ohos --sysroot=$OHOS_NATIVE/sysroot -D__MUSL__"
```

- **为什么直接用 NDK clang 作链接器**：NDK 自带的
  `aarch64-unknown-linux-ohos-clang` 是 **Unix shell 脚本**，Windows 跑不了——
  绕开包装、直接指到真正的 `llvm/bin/clang`。
- `--rtlib=compiler-rt` 与 gnullvm 配套；`-D__MUSL__` 是 cc crate 编 C 依赖时
  OHOS musl 环境需要的。
- `$OHOS_NATIVE` 典型值：Windows `D:\oh\DevEcoStudio\sdk\default\openharmony\native`；
  Mac/Linux 在 DevEco-Studio.app/Contents/sdk 或自定义安装处。
- **未设 SDK 路径时不要写模板占位符进文件**（lingqu 的做法：降级为 guide 提示，
  模板放在 outcome 的 after 字段里供人工填）。

## 编译命令与产物链路

```bash
cd src-tauri
cargo build --release --target aarch64-unknown-linux-ohos
# 产物：target/aarch64-unknown-linux-ohos/release/lib<crate>_lib.so
# 复制到 gen/ohos/entry/libs/arm64-v8a/lib<crate>_lib.so  ← hvigor 打包从这里取
```

- **改前端 / 改版本号 → 必须重编 .so**（前端资源嵌在 .so 里，见 SKILL.md 核心认知 1）。
- hvigor 有时会用 `entry/libs/` 里的**旧 .so**——clean 重建后核对 .so 内嵌的
  AssetKey 指纹（见 pitfalls.md 验证清单）。

## lingqu 侧的规则化落点

- R2-PORT-007/008 的幂等判定：文件已存在且含 `[toolchain]` / `aarch64-unknown-linux-ohos`
  标记即跳过（人工微调过的配置不被覆盖）。
- 备份：apply 时原文件存 `.lingqu/port/<工程>/rust-toolchain.toml.bak` 等，可 `t2h:revert`。
