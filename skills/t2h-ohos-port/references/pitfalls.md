# 真机踩坑指纹表（现象 → 根因 → 修法）

> 语料：habit-tree《真机部署踩坑记录》（2026-08-22 真机复测沉淀）、《移植实录》5 类坑、
> lingqu `AGENTS.md` §4。**按报错原文/现象索引**；每条都有真机取证。
> 构建期的问题先查本表第 1-4 条 + 第 13 条，部署期查 5-9，验证查 10-12。

## 构建期

### 1. `cannot find crate napi_ohos` / `mobile_entry_point` 宏展开失败
- **根因**：`[target.'cfg(target_env = "ohos")'.dependencies]` 段缺失。
- **修法**：加 napi-ohos + napi-derive-ohos + openharmony-ability（见 cargo-patches.md 规则 005）。

### 2. 链接期找不到 `-lgcc_eh`（llvm-mingw 环境）
- **根因**：Windows 上默认 GNU 工具链的链接器不适配。
- **修法**：`rust-toolchain.toml` 换 `stable-x86_64-pc-windows-gnullvm`（见 toolchain.md）。

### 3. crates.io 高版本"绕过" patch → OHOS 符号缺失
- **现象**：明明配了 patch，编译还是走官方 tauri/wry。
- **根因**：依赖写 `^2.11` / `^0.56`，crates.io 发了更高版本被解析器选中——patch 只替换精确版本。
- **修法**：钉 `=2.11.5` / `=0.56.0`；wry 还要 `default-features = false`。

### 4. Windows 上 HAP 装配必然失败
- **根因**：tauri CLI 生成 DevEco 工程壳只生成一半（预期行为，不是你的错）。
- **修法**：手工装配——`.so` 放 `gen/ohos/entry/libs/arm64-v8a/`，前端 dist 快照放
  `rawfile`（仅打包用，运行时不读！），hvigor/devecocli 打包。

## 部署期

### 5. `9568322 not trusted app source`（bm install）
- **根因**：`build-profile.json5` 默认配 **release 签名**（app_gallery 分发 profile，
  无 device-ids 字段），hdc 直装不信任。
- **修法**：`products.default.signingConfig: "release" → "default"`（debugKey，含设备 UDID）；
  **上架前改回 release**——lingqu 的构建规则里这是强提醒项。
  **进阶**：连 DevEco 都不用打开——`~/.ohos/config` 里自动签名材料的 profile 若含本机 UDID，
  把 `signingConfigs` 抄回 `build-profile.json5` 即可（详见 [signing.md](signing.md)）。

### 6. `9568269 install file path invalid`（bm install）
- **根因**：`hdc file send <相对路径>` 会**保留源目录结构**——设备上出现
  `src-tauri/...` 子目录而非 .hap。
- **修法**：**cd 到 HAP 所在目录**再 `hdc file send entry-default-signed.hap <设备目录>/`；
  `bm install -p` 接受目录（目录内所有 hap）。

### 7. `aa start` 报 `10106102`（启动失败）
- **根因**：开发者模式下系统拒绝自动解锁；`power-shell wakeup` 只能亮屏不能解锁，
  模拟上滑对密码/PIN 锁无效。
- **修法**：用户手动解锁后重试（自动化脚本要留这个等待点）。

### 8. `uitest uiInput inputText` 注入异常
- **现象**：对聚焦的**空输入框**有效（中文 OK）；对已有值的 input 追加注入不稳定；
  删除键 keyEvent 67 无效。
- **修法**：先清空再注入；验证探针尽量用"清空+输入"两步。

### 9. cjh / HTTPS 全灭（lingqu 自身工程坑，随包引擎场景）
- **现象**：窗口起、HTTP 通、HTTPS 全灭。
- **根因**：打包时 `*.dll`/so 规则把 vendor 运行时一起忽略了。
- **修法**：gitignore 加例外（`!vendor/cjh/win-x64/*.dll`），SHA256 校验验过再解包。

## 验证期（移植完 ≠ 装上了，装上了 ≠ 是新版）

### 10. 真机始终显示旧界面（**头号坑**）
- **现象**：前端改了、rawfile 同步了、HAP 重打了（BUILD SUCCESSFUL），真机还是旧版。
- **根因**：前端资源编译嵌进 `.so`（`EmbeddedAssets` 对所有 target 生效），**rawfile 是死资源**；
  只同步 rawfile / 只重打 HAP 无效。
- **修法**：重编 `.so` 并复制到 `gen/ohos/entry/libs/arm64-v8a/`。
- **验证指纹**：grep `.so` 二进制里的 **AssetKey**（vite 产物文件名明文，如 `ui-<hash>.js`）：
  `python3 -c "print(b'ui-XXXX.js' in open('libgrove_lib.so','rb').read())"`
  新文件名在 = 嵌了最新 dist；资源内容是压缩存储，明文 grep HTML 搜不到。

### 11. HAP 内 rawfile 死资源
- **验证**：解包 HAP `any('rawfile' in n for n in zipfile.ZipFile(hap).namelist())`——
  rawfile 可作为打包快照存在，但**运行时不读**，不要往里同步东西当"兜底"。

### 12. 版本号不变（同坑 10 的另一种表现）
- **机制**：真机设置页 vX.Y.Z 来自 tauri `getVersion` → `.so` 内嵌 dist 版本。
- **唯一版本源**：`gen/ohos/AppScope/app.json5`；改版本后 npm build 会同步链，
  但 **.so 必须重编**（version.ts 变 → dist hash 变 → .so 内嵌变）。
  看到旧版本号 = .so 未更新。

## 诊断证据链（panic / 白屏排查顺序）

1. **panic.log**：Rust panic 落在数据目录 `/data/storage/el2/base/files/panic.log`
   （hilog 不捕获 Rust stderr——**没有 panic hook 就永远拿不到崩溃证据**，
   注入见 SKILL.md 第 5 步）。
2. **ArkWeb console**：前端报错走 WebView 控制台；连不上调试器时靠页面错误计数
   （lingqu 的 `ui_report.errorCount` 思路）。
3. **hilog**：系统侧（ArkTS/ability 生命周期）有效；Rust 侧无效。
4. **白屏**：先查 `custom-protocol` feature（缺了加载 devUrl localhost:5173），
   再查 AssetKey 指纹（.so 旧），再查 withGlobalTauri。

## 构建期补充（日志串对号，别猜）

### 13. `pkg-config has not been configured to support cross-compilation` 有两种归因
- **现象**：交叉编译死在某个 `-sys` crate 的 build script。**这一句本身不告诉你是谁**。
- **判据**：看**紧随其后的 `failed to run custom build command for \`<crate> v<ver>\``**：
  - `glib-sys` / `gtk-sys` / 其它 GTK 系 → wry/tao 还是 registry 版本，拉进了桌面依赖链
    → 重跑 `t2h:port`（R2-PORT-006 patch 掉 wry/tao）即根除；
  - `openssl-sys` → **不是 GTK 问题**。根因是 `reqwest` 没关默认特性（`default-tls` → native-tls）。
    修法见 `cargo-patches.md` 的「`reqwest` 忘了关默认特性长什么样」，工具侧是
    **R2-PORT-016**（重跑 `t2h:port` 自动改）+ 指纹 **FP-021**。
- **别做的事**：给交叉编译配 `PKG_CONFIG_ALLOW_CROSS`、装宿主 OpenSSL、`OPENSSL_DIR` 指过去——
  目标平台没有 OpenSSL。这条死路会白烧整轮预算（2026-11-08 note-gen-2 实测）。
- **自查**：`cargo tree --target aarch64-unknown-linux-ohos -i openssl-sys` 应为空。

### 14. 接了 Picker 却"下载到一半才失败" / "点了不弹框"
两种表现，同一族根因，处置都在 `native-ui-bridge.md`：

- **点了不弹框**：`verify` 判 pass（Rust 分支调了桥）但真机没反应 ⇒ 多半是 ArkTS 侧
  `__ohos_dispatch` 里没有同名 `cmd` 分支，或者 `.ets` 的符号压根没导入——
  **`cargo build` 与交叉编译都不检查 `.ets`**，只有 `lingqu-cli hap`（hvigor）会查。
- **下载到一半 EACCES / 建目录失败**：Picker 返回的是 `file://docs/...` **uri**，
  授权只在 uri 通道上生效，**不覆盖 `std::fs` 的裸路径读写**。选目录必须由 Rust 侧探可写
  （建目录 + 探针写 + 删探针），不可写回落沙箱 `files/downloads` 并把真实落点交回界面。

### 15. `use openharmony_ability::…` 报 E0432 unresolved import
- **现象**：写桥时 `error[E0432]: unresolved import \`openharmony_ability\``（交叉编译期）。
- **根因**：多数 Tauri OHOS 工程对 `openharmony-ability` **只有 `[patch]` 段，没有直接依赖**
  （它是 tauri fork 的内部依赖）。`[patch]` 只改来源，**不等于把 crate 加进你的依赖图**。
- **修法**：改走 tauri 的转出 —— `use tauri::ohos::openharmony_ability::get_main_thread_env;`
  （同一个 crate、同一个 rev，无需动 Cargo.toml / Cargo.lock）。指纹 **FP-022**。

