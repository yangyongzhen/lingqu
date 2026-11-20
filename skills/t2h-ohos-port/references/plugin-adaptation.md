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
