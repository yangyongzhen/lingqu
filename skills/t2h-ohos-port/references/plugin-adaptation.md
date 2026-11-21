# 插件/平台能力不满足：三层适配优先于降级

> 来源：外部反馈（2026-11-20）+ lingqu 移植实战（§4-162 文件选择桥、§4-174 cfg 门控方法、
> R2-PORT-005/006/016 依赖层补丁）。核心原则：**轻易降级 = 丢原软件的功能特性**；
> 降级是最后手段，且必须登记（limit），静默砍功能算移植失败。

## 判定顺序（先问"真的没有吗"，再谈适配/降级）

1. **报错说"没有" ≠ 平台没有**。查 fork 源码里那行落在**哪个 impl 块**：
   `WebviewWindowBuilder` 的 `center` / `maximizable` / `decorations` / `skip_taskbar` 等只是
   被 `#[cfg(desktop)]` 门控（wry/tao fork 里 desktop 块从 ~446 行起，非门控的在 814 行起）。
   照 `#[cfg(not(target_env = "ohos"))] let builder = builder.center()…;` 拆链即可。
2. **配置层说"没启用" ≠ 平台没有**。先查 `tauri.conf.json` 的 capability / feature 开关，
   再查 fork 的分支实现。

## 三层适配（按顺序走，能不走降级就不走）

### ① wry/tao 差异层（fork 先行）

- tauri / wry / tao / openharmony-ability 用 **fork + patch rev 钉住**（R2-PORT-006 已生成）。
- fork 仓：github.com/yangyongzhen/tauri、github.com/yangyongzhen/openharmony-ability。
- 能力缺口在 fork 里补：建 `fix/<工程>-<问题>` 分支，commit 注明动机，patch rev 钉住继续移植，
  之后整理 PR 回上游。**等上游 = 流水线停摆**。
- 实证：cc-switch 用官方 feat/open-harmony 分支；habit-tree 用 ability feat/0.3.0 patch。

### ② 平台条件编译补丁（依赖层）

- 差异依赖用 `cfg(target_env = "ohos")` 依赖段 + `[patch.crates-io]` 解决（R2-PORT-005/006）。
- 特性替换要**等价**：reqwest 换 rustls 栈时必须补回 `charset` / `http2` / `system-proxy`
  这些纯 Rust 默认项——只关 `default-features` 等于顺手砍特性、改行为（R2-PORT-016）。
- TLS 栈的具体症状与自查见 [cargo-patches.md](cargo-patches.md)。

### ③ 插件 API → ArkWeb / 鸿蒙系统能力映射

- **原生能力**（选文件/选目录/分享/开外部应用）：`ohos_bridge.rs` 的 `call_arkts` +
  `dispatch_on_main` 桥到 ArkTS 分发器，用系统等价物（`DocumentViewPicker` / `DocumentViewPicker` 目录 /
  `want` 分享 / `startAbility`）。落地必须**双侧**：Rust 分支调了桥 **且** ArkTS 分发器里有同名 `cmd`
  分支——只写半边，`verify` 会判通过而真机点了没反应（§4-162）。
  具体形态见 [native-ui-bridge.md](native-ui-bridge.md)。
- **web 能力**：找 ArkWeb 等价物——localStorage polyfill（业务 script 之前）、
  confirm/prompt → 应用内对话框、type=color → 色板化。见 [arkweb-shims.md](arkweb-shims.md)。
- **线程铁律**：Tauri 命令在 IPC 线程跑，`get_main_thread_env()` 只有主线程有值，
  必须 `run_on_main_thread` 投递；要返回值就不能 fire-and-forget（ArkTS 写 `.tmp` 再 rename，
  Rust 轮询，避免读到半截 JSON）。

## 降级（limit）的登记口径

- 三层都走不通**才能**降级，且回答得出"为什么走不通"；
- 降级落地 = 仍要给最小可用替代（不是删功能），如实登记为 limit；
- limit 不算 bug，但**静默砍功能不算 limit，算移植失败**（D-020：移植项判据是
  "平台能力有落地等价物"）；
- 需要人拍板的取舍走 `lingqu-decision`，计入 A3（人工介入 ≤5 处是验收指标——
  这也是为什么适配优先于降级：降级越多，丢的功能越多）。

## 已知插件的映射配方（初始清单）

> 标注纪律：**实测** = 移植样本上真机验证过；**推断** = 按官方 Kit 文档给出的等价物，
> 语义与坑未在真机上核过，用之前先按 §4-162 三步（桌面 + 交叉 + `hap`）取证。
> 撞到清单外的插件：先按上面三层走，走通后**回填本清单**（飞轮第 ②步）。

### 实测过（有真机证据）

| tauri 侧 | 鸿蒙等价物 | 要点 |
|---|---|---|
| `rfd` 文件/目录选择 | `DocumentViewPicker`（`@kit.CoreFileKit`） | uri 授权**不覆盖裸路径**；Rust 侧经 `ohos_bridge.rs` + ArkTS 分发器（见 native-ui-bridge.md） |
| `tauri-plugin-dialog`（alert/confirm/prompt） | ArkWeb 无阻塞对话框 → 应用内对话框 | R2-PORT-012/014（lingqu-dialog.js） |
| `tauri-plugin-log`（LogDir） | log 插件 `TargetKind::Folder` 指沙箱 | 鸿蒙建 LogDir EPERM，`run()` 直接 panic（§4-175） |
| 路径类（`app_local_data_dir` 等） | 固定 `/data/storage/el2/base/files` | 鸿蒙返回桌面风格路径**且不报错**（§4-175：别信返回值） |
| `tauri-plugin-opener` → `open_url` | `startAbility` + Want：`action: 'ohos.want.action.viewData'`、`entities: ['entity.system.browsable']`、`uri: <url>` | **真机验过**（2026-11-21 EcoPaste / SLG-W10）：hilog `open_url ok: …` + 前台切到 `com.huawei.hmos.browser`。Rust 侧经 `ohos_bridge.rs` + ArkTS 分发器（cmd `open_url`）；要点是**主线程投递**与**两侧同名 cmd**（见 native-ui-bridge.md） |
| `tauri-plugin-opener` → `open_path` / `reveal_item_in_dir` | 同上（`uri: fileUri.getUriFromPath(path)`） | **目录打不开（真机三条路全证伪）**：裸 `viewData+uri` 被 WPS 接走"打开"、加 `type: 'inode/directory'` 仍给 WPS、显式 `bundle=com.huawei.hmos.files + EntryAbility` 只弹「暂无可用打开方式」⇒ 三方应用无法浏览**应用沙箱目录**。目录改成**如实提示路径**（toast，`hdc file recv` 可取回）并登记 limit；单文件仍可 `viewData`。`open_path` 的真机按钮路径未复验（§4-186/§4-187） |
| `app_log_dir()` | 固定 `/data/storage/el2/base/files/logs`（与 log 插件 `TargetKind::Folder` 落点一致） | 与 `app_local_data_dir` **同族病**：返回桌面风格路径且不报错 ⇒ `create_dir_all` **EPERM**。**用户实测症状**：点设置「Log Directory → Open」提示「**Open Directory failed，没有权限**」——命令在到桥之前就失败（0.39.132） |
| `clipboard-rs` / `tauri-plugin-clipboard-manager` | **做不了**（能力位 limit）：免权限的只有 `getChangeCount()`/`hasDataType()`；读内容需 `ohos.permission.READ_PASTEBOARD`，而**声明它设备就拒绝安装**（`9568289`） | **真机三步实测（2026-11-21）**：① 装 `clipboard-rs` 的版本编译能过、运行时落进 unix 分支找 X11/Wayland（`src/platform/` 无 ohos）⇒ watcher 起不来；② 改走 ArkTS 桥 + `getDataSync()`：`getChangeCount()` 从 1→2→3 **一直在涨**（复制确实被系统记录），但 `getDataSync()` 返回的 PasteData **`records=0`**（未授权时**不抛错、静默返回空**）；③ 在 module.json5 声明 `READ_PASTEBOARD` ⇒ 安装直接失败 `9568289`。**结论：剪贴板历史这类自动采集在三方应用里不可实现**，产品上只能做"用户主动粘贴/拖入/应用内导入"，并在界面如实说明（别写"已适配"） |

### 推断（Kit 等价物明确，语义待真机核）

| tauri 侧 | 鸿蒙等价物 | 要点与坑 |
|---|---|---|
| `tauri-plugin-notification` | `@kit.NotificationKit`：`notificationManager.publish()` | 先 `requestEnableNotification()` 拿授权；图标/点击跳转字段与 tauri 不一一对应 |
| `tauri-plugin-clipboard-manager` | `@kit.BasicServicesKit` 的 `pasteboard`（`systemPasteboard`） | 粘贴板数据是 **PasteData** 包装（`createData`/`addTextRecord`），不是裸字符串；隐私弹窗行为待核 |
| 分享（`tauri-plugin-share` 类需求） | `@kit.ShareKit`：`systemShare.sendRequest`（UIAbility 场景） | 需 UIAbility 上下文，经主线程投递（见铁律） |
| 深链/协议唤起 | Want 显式/隐式匹配 + `skills` 标签（module.json5 的 `uris`） | tauri 的 `register_url_scheme` 语义要在 ArkTS 侧重新声明 |
| 自定义协议（`register_uri_scheme_protocol`） | ArkWeb `onInterceptRequest`（`@ohos.web`） | 资源仍来自 `.so` 内嵌 dist；响应流构造待核 |

### 无系统级等价物（预期 limit，降级也要给最小替代）

| tauri 侧 | 鸿蒙现状 | 最小替代 |
|---|---|---|
| `tauri-plugin-updater`（自动更新） | 三方应用**没有**自更新系统 API；HAP 分发走应用市场/企业渠道 | 沙箱内查新（HTTP 对比版本）+ 提示用户下载新 HAP；**别写自安装**（需系统权限，走这个路必撞墙） |
| 系统托盘（tray） | PC 端三方应用无系统托盘 API | 常驻通知（`notificationManager`）+ 应用内控制入口；窗口最小化语义改为回桌面 |
| 全局快捷键（`tauri-plugin-global-shortcut`） | 三方应用无全局按键拦截 API | 应用内快捷键（ArkWeb keyevent）；系统级需求登记 limit |
| 自启动（autostart） | 需系统签名权限，三方不可用 | limit：文档写清"手动打开"，别试 |

> 清单外的插件先回本文件三层路径；真机验通一条就回填一行——**这条清单自己就是飞轮的一部分**。
