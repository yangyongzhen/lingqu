# Cargo.toml 改造规则（R2-PORT-001 ~ 006 / R2-DEPS-*）

> 语料：habit-tree `git diff main..ohos -- src-tauri/Cargo.toml`（真机验证）+
> cc-switch-harmonyos @ main + lingqu `src/port/port.cj`（规则化实现）。
> 六条规则的顺序就是执行顺序；每条都有幂等判定，迁移过的工程再跑全部跳过。

## 规则 001：`[lib]` crate-type 补 cdylib

- `["rlib"]` → `["staticlib", "cdylib", "rlib"]`
- **为什么**：OHOS 产出 `.so`（HAP 的 `libs/arm64-v8a/` 要的就是它），桌面照常走 rlib。

## 规则 002：tauri 钉精确版本 `=2.11.5` + features 合并

```toml
tauri = { version = "=2.11.5", features = ["custom-protocol", "protocol-asset"] }
```

- **为什么钉 `=`**：patch 按精确版本替换；crates.io 若发更高版本，`^2.11` 会解析到它而**绕过 patch**（编译报 OHOS 符号缺失，很难排查）。
- **为什么 `custom-protocol`**：生产模式必需（dev = !custom_protocol），缺了运行时加载 devUrl `http://localhost:5173` → 白屏。
- **为什么 `protocol-asset`**：真机加载打包资源必需，配合 tauri.conf.json 的 `assetProtocol.enable`。
- 已有 features（如 `image-png`）原样保留合并，不覆盖。

## 规则 003：tauri-build 钉 `=2.6.3`

理由同 002；tauri 与 tauri-build 版本必须配套（fork 基线 2.11.5 对应 build 2.6.3）。

## 规则 004：wry 钉 `=0.56.0` + `default-features = false`

```toml
wry = { version = "=0.56.0", default-features = false }
```

- **为什么**：registry 已有 0.56.1，`^0.56.0` 会解析到它而绕过 git patch。
- 仅当工程存在 tauri 依赖时才追加（非 Tauri 工程不加）。

## 规则 005：追加 OHOS target 段（napi 桥接）

```toml
[target.'cfg(target_env = "ohos")'.dependencies]
napi-derive-ohos = "1.1"
napi-ohos = { version = "1.1", features = ["napi8"] }
openharmony-ability = { git = "https://github.com/yangyongzhen/openharmony-ability", rev = "295a276a699ba2352addc69b8cacb6acd3be6ab1" }
```

- **为什么**：`mobile_entry_point` 宏展开必需，缺了报 `cannot find crate napi_ohos`。
- openharmony-ability 与 patch 段同源同 rev（解析合一）。

## 规则 006：追加 fork patch 段

```toml
[patch.crates-io]
tauri = { git = "https://github.com/yangyongzhen/tauri", rev = "e3bf6eb168bacc7bb5c8c32d923bb8beaf77c92b" }
tauri-build = { git = "https://github.com/yangyongzhen/tauri", rev = "e3bf6eb..." }
tauri-macros = { git = "...", rev = "e3bf6eb..." }
tauri-codegen = { git = "...", rev = "e3bf6eb..." }
tauri-utils = { git = "...", rev = "e3bf6eb..." }
tauri-runtime = { git = "...", rev = "e3bf6eb..." }
tauri-runtime-wry = { git = "...", rev = "e3bf6eb..." }
wry = { git = "https://github.com/tauri-apps/wry", rev = "6aaf4b84b6e420015c6a14f264f1c7399f150392" }
tao = { git = "https://github.com/tauri-apps/tao", rev = "813572fbe582005e2fb513458bc212842745ceab" }

[patch."https://github.com/harmony-contrib/openharmony-ability.git"]
openharmony-ability = { git = "https://github.com/yangyongzhen/openharmony-ability", rev = "295a276a699ba2352addc69b8cacb6acd3be6ab1" }
openharmony-ability-derive = { git = "https://github.com/yangyongzhen/openharmony-ability", rev = "295a276a699ba2352addc69b8cacb6acd3be6ab1" }
```

### 为什么用 `[patch]` 而不是 path 依赖？

cargo 解析器不会把 path 依赖当作其他 crate 的 tauri 版本候选（`links="Tauri"` 冲突）；patch 是标准机制，且 git URL + rev 固定后 clone 即用、可复现。

### 为什么 wry/tao 必须一并 patch？

fork 的 `tauri-runtime-wry` 按 registry 版本声明（0.56.0/0.36.0），其 OHOS 支持在 tauri-apps 官方仓的 feat/open-harmony 分支；**fork 根 Cargo.toml 的 workspace patch 不跨 workspace 继承**——只 patch tauri 不 patch wry/tao 是最常见的半吊子失败。

### 为什么 openharmony-ability 单独 patch？

main 已重构为 1.0.0-beta.1（webview 拆成独立插件 crate），而 wry/tauri 的 OHOS 分支仍要求 0.3.0 的 webview feature → patch 到 fork 的 feat/0.3.0 分支（= upstream 295a276）。**cargo 不允许 patch 指向同源不同 rev**，所以从 `[patch."harmony-contrib..."]` 改源。

### 三个「写得对却不生效」的坑（2026-11-21 dbx 实测）

1. **`[patch]` 必须写在 workspace 根**。写在成员（如 `src-tauri/Cargo.toml`）里会被 cargo **完全忽略**——
   日志只有一行 `warning: patch for the non root package will be ignored`，然后 tauri 仍是 registry 版
   ⇒ GTK 链照旧进图 ⇒ 编译死在下游（`glib-sys`），而**根因在 patch 位置**。
2. **patch 表不能混放**。把 `tauri` / `tokio-postgres` 之类写进 `[patch."https://…"]` 表里，
   cargo 报的是「patch 未被使用 / perhaps you meant crates-io」，**不会报错停止**、只是静默失效。
   一张表只放该 URL 对应的 crate（`[patch.crates-io]` 放 registry 的，git 表放该 git 源的）。
3. **`.cargo/config.toml` 有作用域**：cargo 只读 **CWD 及其父目录** 的配置。`src-tauri/.cargo/config.toml`
   里配的 `CC_aarch64_unknown_linux_ohos` / `AR` / `sysroot`，**从 workspace 根跑 cargo 就全部失效**
   ⇒ `ring` 这类 C 依赖立刻失败（输出只有 `cargo:rerun-if-env-changed=…` 然后 exit=1，很有误导性）。

**判据**：patch 改完先 `cargo tree --target aarch64-unknown-linux-ohos -i <crate>` 确认**来源真的变了**
（显示 `path` / `git+…`），再看编译进度；只看"编到哪一步"容易把"patch 没生效"当成"环境问题"。

## 依赖兼容性速查（lingqu `lingqu.deps` 规则表，判定必带出处）

| crate | 结论 | 说明 |
|---|---|---|
| tauri 全家桶 / wry / tao / openharmony-ability(-derive) | **需 patch** | 替代：上表 rev |
| openssl-sys / native-tls | **不可用** | 依赖系统 OpenSSL；TLS 改 rustls + webpki-roots。**症状串**：`Could not find directory of OpenSSL installation` |
| rfd | **不可用** | 无 OHOS 后端；降级应用内目录树或 ArkTS 桥 |
| reqwest | 有条件可用 | `default-features=false` + `features=["rustls-tls",...]`（禁 default，会拉进 openssl-sys）。**症状串**：`Could not find directory of OpenSSL installation` / `pkg-config has not been configured to support cross-compilation` + custom build command 是 `openssl-sys` |
| dirs | 可用（运行期坑） | 编译过；但 OHOS 无 HOME，`data_dir()` 返回 None → 路径改走沙箱（见 SKILL.md 第 5 步） |
| napi-ohos / napi-derive-ohos | 可用 | OHOS 专用桥接 |
| 已在 `[patch.*]` 里的 crate | 已处置 | 迁移前后的关键区别，先查这个再判 |
| 其余 | 默认直编 | 标"待真机验证"，不冒充已验证（serde/chrono/redb/base64/log/toml 等纯 Rust 均实测直编过） |

## `reqwest` 忘了关默认特性长什么样（2026-11-08 note-gen-2 实测）

**最容易误判的一种**：`Cargo.toml` 里明明写了 `rustls-tls`，交叉编译还是死在 OpenSSL 上。
原因是 `features` 里的 `rustls-tls` 只是**多加一个后端**，`default-tls` 仍在默认集合里：

```toml
# ✗ 看起来开了 rustls，实际 native-tls 也一起进树
reqwest = { version = "0.12", features = ["json", "multipart", "stream", "rustls-tls", "socks"] }

# ✓ 关默认 + 把与 TLS 无关的纯 Rust 默认项补回来
reqwest = { version = "0.12", default-features = false,
            features = ["json", "multipart", "stream", "socks",
                        "rustls-tls", "charset", "http2", "system-proxy"] }
```

- **默认集合**：0.11+ 是 `["default-tls", "charset", "http2"]`，0.12 起还有 `system-proxy`。
  只写 `default-features = false` 会**顺手丢掉 charset/http2**——那是改行为，不是迁移。
- **症状**（`cargo build --target aarch64-unknown-linux-ohos` 的输出尾部）：
  ```
  error: failed to run custom build command for `openssl-sys v0.9.109`
  --- stderr
  Could not find directory of OpenSSL installation, and this `-sys` crate cannot
  proceed without knowing the path to OpenSSL installation.
  pkg-config has not been configured to support cross-compilation.
  ```
  第二条 `pkg-config …` 会和 GTK/glib 那条**长得一样**——所以判据不是"看到 pkg-config 就当 GTK"，
  而是**看紧随其后的 custom build command 是哪条 crate**（`openssl-sys` vs `glib-sys`）。
- **不要走的路**：装 OpenSSL、给 pkg-config 配 `PKG_CONFIG_ALLOW_CROSS`、`OPENSSL_DIR` 指宿主——
  目标平台没有 OpenSSL，这些只会白烧轮次。
- **工具已机械化**：`lingqu` 的规则 **R2-PORT-016**（重跑 `t2h:port` 即生效）与指纹 **FP-021**。
  自查：`cargo tree --target aarch64-unknown-linux-ohos -i openssl-sys` 应为空。
