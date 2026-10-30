# ArkWeb 前端三坑与兼容层（R2-PORT-011 / 012 / 013）

> 语料：habit-tree `src/index.html`（polyfill 实测代码）、`src/ui.ts`（对话框实现）、
> 《鸿蒙移植改动说明》《真机部署踩坑记录》（真机取证）。前端**业务逻辑零改动**，
> 兼容层全部是注入式的。

## 坑 1：`window.localStorage` 为 null（R2-PORT-011，auto）

- **现象**：ArkWeb 自定义 scheme 下直接读写 localStorage 抛异常 / 崩——theme.ts 这类
  启动即读的模块直接挂。
- **方案**：在**业务 script 之前**（`</head>` 后）注入内存 polyfill——API 完全兼容
  （同步内存 Map），底层经 `__TAURI_INTERNALS__.invoke` 持久化到 Rust 侧（redb 表
  `ls_get_all/ls_set/ls_remove/ls_clear`）。桌面（localStorage 原生可用）此段不生效，零影响。
- **幂等判定**：页面已有 `__lsInit` 或 lingqu 标记则跳过。

```html
<script>
if (typeof window !== "undefined" && !window.localStorage) {
  var __lsMap = new Map();
  function __lsInvoke(cmd, args) {
    try {
      if (window.__TAURI_INTERNALS__ && typeof window.__TAURI_INTERNALS__.invoke === "function") {
        return window.__TAURI_INTERNALS__.invoke(cmd, args);
      }
    } catch (e) { /* fallthrough */ }
    return Promise.reject(new Error("no tauri bridge"));
  }
  Object.defineProperty(window, "localStorage", {
    value: {
      getItem: function (k) { k = String(k); return __lsMap.has(k) ? __lsMap.get(k) : null; },
      setItem: function (k, v) { k = String(k); __lsMap.set(k, String(v)); },
      removeItem: function (k) { k = String(k); __lsMap.delete(k); },
      clear: function () { __lsMap.clear(); },
      key: function (i) { return Array.from(__lsMap.keys())[i] || null; },
      get length() { return __lsMap.size; }
    },
    configurable: true, writable: true
  });
}
</script>
```

- **启动同步点**：业务入口要 `await window.__lsInit?.()` 后再动态 import 业务模块
  （先从 Rust 侧预加载持久化数据进内存，再执行会读写 localStorage 的代码）。
  habit-tree 的做法：`main.ts` 改为 `await window.__lsInit?.(); import('./ui')`。
- **简化版 vs 完整版**：上面是 lingqu 注入的简化版（同步写、无防抖持久化）；
  habit-tree 真机版另有 `__lsFlush()` 防抖批量持久化 + `__lsDirty` 脏标记——
  数据量大的应用建议抄完整版（`habit-tree @ ohos: src/index.html`）。

## 坑 2：没有原生 confirm / prompt（R2-PORT-012，guide）

- **现象**：ArkWeb 未接 `onJsConfirm`/`onJsPrompt` 回调——原生 `confirm()` **静默返回
  false**、`prompt()` 返回 null。依赖它的功能（删除确认、重命名）静默失效，不报错。
- **为什么是 guide 不是 auto**：替换 = ① 写 Promise 化 `confirmDialog`/`promptDialog`
  （应用内 `.dialog` 遮罩 + 卡片样式，z-index 80 复用设计令牌）② 逐调用点改写
  `if (confirm(x))` → `if (await confirmDialog(x))`（外层函数要变 async）——**机械替换
  会改坏控制流**，必须逐点看语义。
- **处置**：探测列出调用点（文件:行）+ 方案原文，留人工/AI 兜底；
  实现参考 `habit-tree @ ohos: src/ui.ts`（`openDialog`/`confirmDialog`/`promptDialog`）。
- **探测的语义边界**：`confirm(` 不会误命中 `confirmDialog(`（confirm 后跟 D 不是括号）——
  迁移后的样本探测结果应为零。

## 坑 3：`<input type="color">` 不支持（R2-PORT-013，guide）

- **现象**：点击无反应（应用市场审核实测）；**更阴的是** `display:none` 隐藏时该元素
  **仍参与合成层**——对话框滚动后打开 → 内容整块不绘制（DOM 正常、视觉空白、uitest
  点击失效），排查极其困难（habit-tree 真机踩了一整轮才定位）。
- **方案**（唯一正确解）：`supportsNativeColorPicker()` 为 false 时 **`remove()` 彻底移除
  元素**（不能只隐藏！），UI 走应用内色板：预设色板（点击即选即用）+ hex 输入 + 确定/取消，
  桌面（WebView2）保留原生取色器。参考 `habit-tree @ ohos: src/ui.ts getColorDialog`。
- **另一个实测坑**：ArkWeb 多层 `.dialog` 叠加渲染不稳（DOM 在、绘制丢）——
  对话框保持**单层结构**，别做"色块方框 + 二级选色器"两层。

## 配套配置（前端能跑的前提，别漏）

```jsonc
// tauri.conf.json
{
  "app": { "withGlobalTauri": true },                      // ArkWeb 需要 window.__TAURI__ 全局桥
  "security": { "assetProtocol": { "enable": true, "scope": [] } }  // protocol-asset 的 allowlist 前提
}
```
