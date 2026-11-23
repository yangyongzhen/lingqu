# 启动与首屏：四条连着的坑（一次踩全，2026-11-22 dbx 真机实测）

> **什么时候读这篇**：应用"装上了、也启动了"，但
> ① 进程秒退（`SIGABRT`、hilog 无应用输出）；② 界面全黑；③ 白底 + 应用图标 + 转圈一直不动。
> 这三件事在鸿蒙上是**连着的**，修好一个会掉进下一个。按本文顺序排查，别跳。

---

## 0. 先拿证据：没有证据不要猜（本轮前两次推断都是错的）

| 想确认的事 | 命令 | 判据 |
|---|---|---|
| 进程是不是还活着 | `hdc shell "ps -ef \| grep <bundle> \| grep -v grep"` | 有行 = 活着；**`deploy` 的 `started=true` 不算**（只说明 ability 被拉起过） |
| 是不是前台 | `hdc shell "aa dump -l" \| grep -A3 <bundle>` | `state #FOREGROUND` |
| 界面有没有内容 | `hdc shell "snapshot_display -f /data/local/tmp/x.jpeg"` + `file recv` | **截图**才是判据；版面树不算（见 §4） |
| 崩没崩、崩在哪 | `hdc file recv -b <bundle> /data/storage/el2/base/files/panic-early.log ./pe.log` | 条数是否增长；消息里带 `file:line` |
| 页面加载过没有 | `hdc shell "hilog -x" \| grep -E "OnPageEnd\|OnPageBegin\|loadUrl\|SetUIContent"` | 一条都没有 = **从未加载** |

**取证通道铁律**：应用沙箱对 `hdc shell` / `hdc shell -b` 一律 `Permission denied`；
**只有 `hdc file recv -b <bundle> <远端> ./本地` 能读**。它报 `no such file` 才是"文件真的不存在"，
这条差别正好用来判"panic hook 到底有没有写盘"。

---

## 1. 起来即崩（SIGABRT），且**零线索**

### 现象
`appspawn … exit with signal:6`；hilog 里一行应用侧输出都没有；沙箱里连 `panic.log` 都没有。

### 根因（两条叠一起）
1. 工程通常 `panic = "abort"` ⇒ 任何 panic 都是 SIGABRT、没有栈；
2. `install_panic_hook(app)` 这类**依赖 `tauri::App`** 的 hook 装得太晚——插件初始化阶段 panic 时它还没装，
   于是**什么都不会落盘**。

### 处置（顺序别换）
1. 在 `pub fn run()` **第一行**装一个**只依赖 std** 的早期 hook，落 `<沙箱>/panic-early.log`：
   ```rust
   fn install_early_panic_hook() {
       #[cfg(target_env = "ohos")]
       let path = std::path::PathBuf::from("/data/storage/el2/base/files/panic-early.log");
       #[cfg(not(target_env = "ohos"))]
       let path = std::path::PathBuf::from("panic-early.log");
       std::panic::set_hook(Box::new(move |info| {
           use std::io::Write;
           let bt = std::backtrace::Backtrace::force_capture();
           let _ = std::fs::OpenOptions::new().create(true).append(true).open(&path)
               .and_then(|mut f| f.write_all(format!("[panic-early] {info}\n{bt}\n----\n").as_bytes()));
       }));
   }
   ```
2. 重编、部署，再用 `hdc file recv -b` 取日志——**第一次就能看到真因**（本轮就是靠它两次定位）。

---

## 2. 崩溃真因 A：数据目录 EPERM（`Failed to prepare app data dir`）

### 现象
```
[panic-early] panicked at src/lib.rs:NNNN:
Failed to prepare app data dir: Os { code: 1, kind: PermissionDenied, message: "Operation not permitted" }
```

### 根因
`dirs::data_dir()` 在鸿蒙返回**桌面口径**路径（`/storage/Users/currentUser`），拼上包名后
`prepare()` 里的 `create_dir_all` 一律 EPERM。
**关键时序**：这段代码跑在**构造 `Builder` 之前**，那时还没有 `App`，所以"在 setup 里用
`app.path().app_data_dir()` 修过"这件事**覆盖不到它**（见 pitfalls #17）。

### 处置
```rust
#[cfg(target_env = "ohos")]
let default_data_dir = std::path::PathBuf::from("/data/storage/el2/base/files");
#[cfg(not(target_env = "ohos"))]
let default_data_dir = dirs::data_dir().expect("…").join(&context.config().identifier);
```
顺带把 log 插件在鸿蒙的目标从默认的 `TargetKind::LogDir` 换成沙箱 `Folder`
（默认目标里就有 `LogDir`，同样会在沙箱建目录失败——属**预防性**修复，不是本次主因）。

---

## 3. 崩溃真因 B：`a webview with label 'main' already exists`

### 现象
```
[panic-early] panicked at tauri/src/app.rs:NNNN:
Failed to setup app: error encountered during setup hook: a webview with label `main` already exists
```
panic 栈里会出现 ArkUI 的 `PipelineContext::FlushVsync` / `EventRunner::Run` —— 说明是**主线程 UI 管线**里发起的。

### 根因
ability 侧（`EntryAbility extends RustAbility`，`defaultPage: true`）与 tauri 按 `tauri.conf.json`
的 `app.windows` **抢同一个 label**：窗口配置**不写 `label` 时默认就是 `main`**。

### 处置
**给窗口一个非 `main` 的 label**（这是跑通样本 EcoPaste 的做法：它的 label 是 `clipboard`）：
```json
"app": { "windows": [ { "label": "myapp-main", "title": "…", "visible": true } ] }
```
> ⚠️ 别用"清空 `app.windows`"来绕（`context.config_mut().app.windows.clear()`）——
> 那会让 tauri **根本不建窗**，于是没人导航前端 ⇒ **全黑**（见 §4）。

---

## 4. 全黑 / 白底转圈：`defaultPage` 与窗口 `label` 是一对开关

### 四种组合的真机读数（缺一条证据就会误判）

| 组合 | 真机表现 | 结论 |
|---|---|---|
| 清空 `app.windows`（不建窗） | 全黑；hilog **无任何页面加载日志**；版面树只有 `XComponent`/`NodeContainer` | 没窗口 ⇒ 没人导航前端 |
| 建窗 + `defaultPage: true` + label 默认 `main` | **SIGABRT**（§3） | 两侧抢同一 label |
| 建窗 + `defaultPage: false` | 不崩，但**白底 + 应用图标 + 转圈**、CPU 恒 0；hilog `SetUIContent timeout, persistentId=N` | **关掉默认页连带关掉了页面加载** |
| 建窗 + `defaultPage: true` + label 非 `main` | **✅ 正常**：进程 + `:<name>:render` 进程都在、`#FOREGROUND`、截图是真实界面 | 两侧各用各的 label |

### 判据（这几条最容易骗人）
- **「应用图标 + 转圈」不是"界面出来了"**；`SetUIContent timeout` 才是没加载的硬证据；
- **非空版面树 ≠ 有内容**：ArkWeb 内容**不在无障碍树**里，`root → ContainerModal → … → XComponent → NodeContainer`
  这棵树**有节点但全是容器**。要看内容只能看**截图**（或用 `uitest` 找可点节点，但 ArkWeb 常找不到）；
- **判"界面好了"要两处读数**：panic 计数（有没有崩）+ 截图（有没有内容）。单看一处必误判；
- `visible: false` + "等 setup 收尾再 `show`"这套桌面写法，在鸿蒙上**不一定成立**——默认就 `visible: true` 更稳。

---

## 5. 把这些固化进工具（lingqu 侧的做法，可照抄）

- `t2h:verify` 的 `launch` 项**不能只看** `started`/`hilogHealthy`：它们是**瞬时**判据
  （`aa start` 成功只说明被拉起过；`crashCount` 读 `/data/log/faultlog/faultlogger` 而三方 shell 读不到 ⇒ 恒 0）。
  正确做法是部署后**隔几秒再取一次"还活着"的证据**（`ps` / `aa dump` / 持续 hilog），把 `alive` 落档。
- 判"有没有界面"要落到**可读内容**（有 `Text`/按钮节点，或截图里有非黑像素），不是"版面树非空"。

---

## 6. 一句话版本

> 先让 panic 能落盘（早期 hook）→ 数据目录在**构造 Builder 之前**就定死沙箱路径 →
> 窗口 label **别用默认 `main`** → `defaultPage` 保持 `true` →
> 判界面一律**看截图**，判存活一律**看进程**，判加载一律**看 `OnPageEnd`/`SetUIContent`**。
