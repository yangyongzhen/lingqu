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
- **根因**（三种，先分清再动手）：
  - ① `build-profile.json5` 配的是 **release 签名**（app_gallery 分发 profile，无 device-ids），hdc 直装不信任；
  - ② debug 材料里的 profile 没有**本机 UDID**（设备没注册进团队）；
  - ③ **签 HAP 用的证书 ≠ profile 里绑的证书**——复用云端同名证书时本地 `.cer` 还是更早那张
    （实测：`.cer` 里是 serial `63E51AD2…`(11-01)，profile 里绑的是 `63E51D71…`(11-09)），
    hvigor 用旧证书签、profile 写新证书 → 真机这头才炸，而前面每一环都报"成功"。
    证书以**云端为准**，本地 `.cer` 只是缓存：`sign --auto` 现在会在 ⑥ 之后自检并重下。
- **修法**：① `products.default.signingConfig: "release" → "default"`（上架前改回 release）；
  ② 用 `sign --auto` 把设备注册进 profile；③ 让工具重下 `.cer`；重下仍报就说明
  `.p12` 与证书不是一把钥匙 → `sign --auto --newKeys`（旧材料改名留底）。
  **`9568332` 才是"设备上装着同包名的另一套签名"**，两者处置不同，别混。
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

### 16. `Downloading crates ...` 卡十几分钟 / `spurious network error`
- **现象**：`cargo build` 长时间没有任何输出，界面可能已报"停滞"；也可能是
  `warning: spurious network error (N tries remaining): [28] Timeout was reached
  (Operation timed out after 302571 milliseconds with 0 bytes received)`。
- **判据**（三条一起看，别只盯界面）：`rustc.exe` **一个都没起**、cargo 累计 CPU 几乎为 0、
  `registry/cache` 大小**不涨**，且 cargo 持着到 `146.75.x.x:443`（**Fastly = crates.io CDN**）的连接。
  三条齐了就是网络，**不是**工具挂死、也**不是**代码问题
  （2026-11-19 EcoPaste 实测：卡 **18 分钟**后自己通了，期间一度被判成工具故障）。
- **修法**：配国内镜像——`R2-PORT-008` 生成的 `.cargo/config.toml` **默认已带 rsproxy 稀疏索引**
  （`[source.crates-io] replace-with = "cn-rsproxy"` + `sparse+https://rsproxy.cn/index/`）；
  老工程手配 `[source.*]` 或设 HTTP 代理。指纹 **FP-024**。
- **两个边界**：① 镜像只覆盖 **registry** 依赖，**git 依赖**（从 github 拉 tauri/wry 的 fork）
  不受益，另需 ghproxy / `url.<base>.insteadOf` 或代理；② 已经在跑的 cargo **不会重读配置**，
  改完必须重跑；③ 卡住时**没有**报错文本，光靠指纹接不住"静默卡死"，得靠上面那三条现场判据。

### 17. 「起来即退」：装机/启动都"成功"，进程 10ms 消失且 hilog 无应用侧日志
- **现象**：`hdc install` 回 `install bundle successfully`、`aa start` 回 `ability started`，
  但 `ps -ef` 里没有进程、`uitest dumpLayout` 只有 `com.ohos.sceneboard`、**hilog 一条应用日志都没有**、
  沙箱里的 `panic.log` 也不更新。**别把"装机成功 / 启动成功"当成"跑起来了"。**
- **为什么什么都没留下**：崩在 `run()` 里但**早于 `setup`**（插件初始化阶段），
  而 `eprintln` 在鸿蒙不进 hilog、setup 里的 panic hook 也来不及装。
- **第一步永远是**：在 `run()` **第一行**装一个**不依赖 `App`** 的早期 panic hook，写
  `/data/storage/el2/base/files/panic-early.log`（hdc 可直接 `file recv` 取回）。
  装上它就一次抓到原因，否则只能猜。
- **两个已实测的真凶**（2026-11-19 EcoPaste）：
  | 真凶 | 原文 | 修法 |
  |---|---|---|
  | `tauri-plugin-log` 的 `TargetKind::LogDir` 在鸿蒙建目录 EPERM | `PluginInitialization("log", "Operation not permitted (os error 1)")` | 鸿蒙下改 `TargetKind::Folder` 指向 `/data/storage/el2/base/files/logs` |
  | `app_local_data_dir()` **不报错**却返回桌面风格 `/storage/Users/currentUser/.local/share/…` | 应用日志：`window state store initialization failed: … Operation not permitted` ⇒ setup `Err` ⇒ 退出 | 鸿蒙下**不信返回值**，固定落 `/data/storage/el2/base/files` |
- **判据**：`Err` 与"成功返回一个不可写路径"是**两种失败**——只兜 `Err` 兜不住后者（§4-38 同族）。
- **验收**：进程常驻 + `dumpLayout` 里有自己的 bundleName + **截图看得见界面**（三样缺一不算跑起来）。

### 18. `no method named center/decorations/maximizable…`：fork 里方法在，但被 `cfg(desktop)` 门控
- **现象**：`WebviewWindowBuilder` 上一串方法报"不存在"，可你在 fork 源码里 `grep "pub fn center"` **明明有**。
- **判据**：看它落在**哪个 `impl` 块**——`crates/tauri/src/webview/webview_window.rs` 里
  `#[cfg(desktop)]` 的 impl 从 446 行起（`center` / `maximizable` / `minimizable` / `focused` /
  `decorations` / `always_on_top` / `skip_taskbar` / `shadow`），非门控 impl 在 814 行起
  （`title` / `inner_size` / `min_inner_size` / `resizable` / `visible` / `focusable`）与 914 行起
  （`accept_first_mouse` / `transparent` / `disable_drag_drop_handler`）。
- **改法**：按门控拆链，鸿蒙侧保留可用方法：
  ```rust
  let builder = WebviewWindowBuilder::new(..).title(..).inner_size(..).resizable(false);
  #[cfg(not(target_env = "ohos"))]
  let builder = builder.decorations(false).shadow(false).skip_taskbar(true).center();
  #[cfg(target_env = "ohos")]
  let builder = builder;
  ```
  同类：`WebviewWindow::cursor_position` → OHOS 版函数直接 `Ok(None)`；`set_always_on_top` → no-op。
- **别做**：把整段删掉改桌面行为（那会让桌面端回归）；也别改 fork 源码（换环境就丢）。

### 19. 签名：**优先自签名**；`11014003 Init keystore failed` 是什么意思
- **首选（也是默认路径）**：`lingqu-cli sign --login`（浏览器授权一次）→
  `lingqu-cli sign --auto --path .` ——自动拿证书、生成**含本机 UDID** 的 debug profile 并写回
  `signingConfigs`，不需要 DevEco。之后 `hap` 出 `signed=true`，`deploy` 能装。
  **能自签名就自签名**：复用别工程的材料会把应用装成**别人的包名**，验收时不成立。
- **离线/CI 兜底才考虑复用本机已有材料**（且必须标注"这是本地验证手段，不是交付路径"）：
  ① profile 按 `bundleName` 签发、`device-ids` 必须含本机 UDID
  （`grep -l "<UDID>" ~/.ohos/config/*.p7b` → `grep -ao "bundle-name[^,]*"`）；
  ② 目标工程 `AppScope/app.json5` 的 bundleName 改成该材料的包名、**`versionCode` 抬高**（否则判降级）；
  ③ 抄 `signingConfigs` 整块（含密文 `storePassword`/`keyPassword`）并确认 `products[].signingConfig` 指向它。
- **`11014003 Init keystore failed`** = **口令密文与 `.p12` 不配套**（或这组密文已失效）。
  正确处置是 `sign --auto --newKeys` 换一套自己掌口令的材料；**别猜口令、别改密文、别反复重下证书**。
- 相关：`00303074` 包名与 profile 不一致、`9568322` 设备不信任该证书（见 `signing.md` 与 FP-018/FP-023）。

### 20. crate 级版本漂移：插件与 fork 版 tauri 对不上（不是编译参数问题）
- **现象**：`error[E0609]: no field 'appimage' on type 'Env'`，位置在 registry 里的
  `tauri-plugin-updater-2.10.1/src/lib.rs` —— 因为鸿蒙的 `target_os` 也是 `linux`，
  插件把 Linux 专属分支编进来了，而 OHOS fork 的 `Env` 没有 `appimage` 字段。
- **修法**：**vendor 一份插件并按 `not(target_env = "ohos")` 收窄那几处 cfg**，
  用 `[patch.crates-io] tauri-plugin-updater = { path = "vendor/…" }` 挂上；
  或在鸿蒙侧直接不引入该插件（`cfg(not(target_env = "ohos"))` 的门控依赖）。
- **同类**：`rfd` 的 build script panic（`You need to choose at least one backend: gtk3 or xdg-portal`）
  ⇒ 鸿蒙侧不要引入依赖 rfd 的插件（如 `tauri-plugin-dialog`），改用 ArkTS 文件选择桥接。

