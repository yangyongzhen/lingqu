# 原生 UI 能力桥（picker / 分享 / 打开外部应用）

> 什么时候读：**某个命令在鸿蒙侧是空壳**（`#[cfg(target_env = "ohos")] fn x() { None }` /
> `Err("当前平台不支持…")`），而桌面侧用的是 `rfd::FileDialog`、`std::process::Command::new("explorer")`、
> 系统分享、相册保存这类**原生 UI / 系统能力**。
> ArkWeb 里没有原生对话框——这类能力只能由 ArkTS 侧拉起系统 UI，Rust 经 NAPI 桥请它动手。

## 0. 先确认这是不是缺口（别把桌面专用当缺口）

判据（`src/verify/verify.cj` 的 `judgePlatformSite`）：

| 形态 | 算不算缺口 |
|---|---|
| 整个函数 `#[cfg(not(target_env = "ohos"))]`，鸿蒙侧没有同名实现 | **不算**（桌面专用） |
| 有 `#[cfg(target_env = "ohos")]` 分支但函数体是 `None` / `Err("不支持")` 空壳 | **算** |
| 函数体内按 cfg 分块，鸿蒙块里有真实调用 | **不算** |

`lingqu-cli verify --path .` 的 `platform-api` 项会列出命中的 API 与落点行号。

## 1. 桥的骨架（`src-tauri/src/ohos_bridge.rs`，仅 OHOS 编译）

```rust
#[cfg(target_env = "ohos")]
pub mod ohos_bridge;   // lib.rs 里加这一行

use napi_ohos::bindgen_prelude::{Function, JsObjectValue};
use napi_ohos::{Env, Result};
// 注意引用路径：多数 Tauri OHOS 工程对 openharmony-ability 只有 [patch] 没有直接依赖，
// 直接写 `use openharmony_ability::...` 会报 E0432 unresolved import。改走 tauri 的转出：
use tauri::ohos::openharmony_ability::get_main_thread_env;

pub fn call_arkts(msg: &str) -> Result<String> {
    let guard = get_main_thread_env();
    let env_opt = guard.borrow();
    let env: &Env = env_opt.as_ref().ok_or_else(|| napi_ohos::Error::from_reason("main thread env not ready"))?;
    let global = env.get_global()?;
    let dispatch: Function<'_, String, String> = global.get_named_property("__ohos_dispatch")?;
    dispatch.call(msg.to_string())
}
```

### 线程模型铁律（这条不遵守必定拿不到 env）

Tauri 命令在 **IPC / 异步线程**执行，而 `get_main_thread_env()` 是 **thread_local，只有主线程有值**。
所以必须**先投递主线程**再调：

```rust
fn dispatch_on_main(app: &tauri::AppHandle, msg: String) -> Result<String> {
    let (tx, rx) = std::sync::mpsc::channel::<Result<String>>();
    app.run_on_main_thread(move || { let _ = tx.send(call_arkts(&msg)); })
        .map_err(|e| napi_ohos::Error::from_reason(format!("投递主线程失败: {e}")))?;
    rx.recv().map_err(|e| napi_ohos::Error::from_reason(format!("主线程回调缺失: {e}")))?
}
```

需要 `AppHandle` 就把命令签名改成 `pub async fn pick_folder(app: tauri::AppHandle) -> Option<String>`，
Tauri 会自动注入，前端调用不变。

## 2. ArkTS 侧：全局分发器

在 `gen/ohos/entry/src/main/ets/entryability/EntryAbility.ets` 的 `onCreate` 里注册
（`(globalThis as ESObject).__ohos_dispatch`，注意 `as ESObject`，ArkTS 严格模式需要）：

```ts
import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';

async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
  super.onCreate(want, launchParam);
  (globalThis as ESObject).__ohos_dispatch = (msg: string): string => {
    const parsed = JSON.parse(msg) as DispatchMsg;
    if (parsed.plugin === '<工程名>' && parsed.cmd === 'pick_folder') { this.pickFolder(parsed.payload); }
    return JSON.stringify({ ok: true });
  };
}
```

### 2.1 ArkTS 严格模式必踩：对象字面量必须带类型（`arkts-no-untyped-obj-literals`）

`cargo build --target …ohos` **不审 ArkTS**，只有 hvigor 会审。所以 Rust 侧全绿也可能在
`hvigor … CompileArkTS` 一步炸，报：

```
10605038 ArkTS Compiler Error
Object literal must correspond to some explicitly declared class or interface
(arkts-no-untyped-obj-literals) At File: …/EntryAbility.ets:126:28
```

**处置**：给每个回投结构声明 `interface`，字面量写成带类型的常量（连 `JSON.stringify({ok:true})` 这种 ack 也算）：

```ts
interface BridgeAck { ok: boolean; pending?: boolean; err?: string }
interface PickResult { ok: boolean; paths?: string[]; path?: string; canceled?: boolean; err?: string }

const pending: BridgeAck = { ok: true, pending: true };
return JSON.stringify(pending);
```

**判据**：改完 `.ets` 必须跑一次 `lingqu-cli hap --path <工程根>`（第 3 步）才算验过——
只跑 `cargo build` / `cargo build --target …ohos` 属于"两步验"的漏网。

### 2.2 验证桥之前：先确认**前端走的是插件 JS API 还是自家命令**

最容易白干的一步（2026-11-22 dbx 真机实测）：鸿蒙侧写好了 `pick_files` 桥，
真机点「选择文件」却**毫无反应、也没有任何桥日志**。查前端才发现它用的是
`import("@tauri-apps/plugin-dialog").open({filters, multiple})` —— **插件 JS API**；
而鸿蒙侧为了避开 rfd 已经把 `tauri-plugin-dialog` 整插件排除，
这条 IPC 在鸿蒙上根本不存在 ⇒ 点击在 JS 层就失败（异常还被上层 catch 成"用户取消"）。
我们的桥只被 **Rust 命令**调用，从前端那条路到不了。

```bash
# 验证桥之前先跑这一条：有输出 = 前端走插件 JS API，你的桥在真机上不会被点出来
grep -rn "@tauri-apps/plugin-<插件名>" apps/ src/  # 前端源码根
```

要真能用，二选一：① 补**同名 IPC shim**（插件名 + 命令名 + ACL 权限三样对上，前端零改动）；
② 把前端调用点改成自家命令（改动面大）。

**判据**：点按有反应但无桥日志 ⇒ 先怀疑"没走到"，别怀疑桥写错；`import()` 动态加载会把异常吞掉。

### 2.3 想让前端"不用改代码"就用系统能力：补**同名 IPC shim**

场景：前端调 `@tauri-apps/plugin-dialog` 的 `open()`/`save()`，而该插件在鸿蒙被排除（§2.2）。
**正解是注册一个同名插件**，把 IPC 接到自己的平台实现，前端一行不改。三处必须一起对上，
少一处就是"编译过、运行期 `command not found` / `not allowed by ACL`"：

```rust
// ① src/dialog_shim.rs —— 插件名与命令名必须和官方插件一致
pub fn plugin() -> TauriPlugin<Wry> {
    Builder::new("dialog")                       // ← 名字决定 IPC 前缀 plugin:dialog|*
        .invoke_handler(tauri::generate_handler![open, save])
        .build()
}
// lib.rs：#[cfg(target_env = "ohos")] let builder = builder.plugin(dialog_shim::plugin());

// ② build.rs —— 应用内插件要在这里声明命令，tauri-build 才会生成 dialog:allow-open/allow-save
let attrs = tauri_build::Attributes::new().plugin(
    "dialog",
    tauri_build::InlinedPlugin::new().commands(&["open", "save"]),
);
tauri_build::try_build(attrs).expect("tauri build failed");

// ③ capabilities/<平台>.json —— 放行 + **窗口白名单里要有实际窗口 label**
//   "permissions": [..., "dialog:allow-open", "dialog:allow-save"]
//   "windows": ["main", "<你的窗口 label>", ...]
```

**两个最容易踩的点**（2026-11-22 dbx 真机）：
1. `acl-manifests.json` 里出现 `allow-open` 只证明**权限生成了**，不证明**授权生效了**——
   真机上照样可能报 `Command plugin:dialog|open not allowed by ACL`；
2. 报 ACL 时先比对**实际窗口 label** 与 capability 的 `windows` 通配：本项目为避开
   "重复 `main` webview" 把窗口 label 改成了 `dbx-main`，而白名单里还是 `main`
   ⇒ 整套权限一条都没生效（**应用自己的 `invoke` 命令不受 ACL 管，所以别的功能看着正常**，极易误判成"shim 没注册"）。

#### ✅ 已真机打通（2026-11-23 dbx，端到端）

点「SQLite → 文件路径 → 浏览」→ 系统 `DocumentViewPicker` 弹出（版面 bundle 变成
`com.huawei.hmos.filemanager`，出现「安全访问文件 / 最近」）→ 选一个文件 → 「已选 (1/1)」→「打开」
→ 回到应用，**「文件路径」被回填成沙箱副本**
`/data/storage/el2/base/haps/entry/files/imported/<文件名>`。整条链不再出现 ACL 拒绝。

**但"哪一处改动让它通的"尚未坐实**（如实记，别当成结论照抄）：那一轮同时有两处差异——
① `capabilities/ohos.json` 去掉了 `platforms: ["openHarmony"]`；② 应用 crate 被**整份重编**。
而据 tauri 2.11.5 源码，`platforms: ["openHarmony"]` 按设计**本该生效**
（`tauri-build` 写 `TAURI_ENV_TARGET_TRIPLE=aarch64-unknown-linux-ohos` →
`Target::from_triple` 含 `ohos` → `OpenHarmony` → `Capability::is_active` 为真，
本机 `build/dbx-*/output` 里能查到这条 env）。所以更可能起作用的是 ②：

> **ACL 是编译期烘进二进制的**（`Resolved::resolve(..., Target)` 在 codegen 阶段算好并内嵌）。
> 改完 `capabilities/*.json` 若构建没真正重跑 build script，二进制里就是**旧 ACL**——
> 表现与"白名单没写对"一模一样，而且 `gen/schemas/capabilities.json` 看着是全对的。

**因此纪律**：改 capability 后不要相信"文件对了 + 重编过了"，要强制
`touch src-tauri/build.rs`（或 `cargo clean -p <应用crate>`）再编；要坐实归因就做**负向对照**
（把 `platforms` 加回去重编一次）——代价是一轮 45 分钟全量编译，本仓选择如实标注而不是猜。

排查顺序（按成本从低到高）：窗口 label vs `windows` 通配 → 三处联动
（插件名/命令名、`InlinedPlugin`、capabilities 放行）→ 强制重跑 build script → 带
`debug-assertions` 的构建拿 `resolve_access_message` 的明细（它会点名是 window / webview / origin 哪一维）。

## 3. 返回值怎么回去：三种形态，按需选
| 形态 | 适用 | 代价 |
|---|---|---|
| **A. 单向 fire-and-forget** | 通知类：打开链接、分享、保存到相册 | 拿不到用户结果（无法回报"选中了哪个"） |
| **B. 沙箱落档回读**（本仓采用） | **需要返回值**（选了哪个文件/目录） | Rust 轮询文件；需清理 |
| **C. 反向 napi 回调** | 同 B | ArkTS 需 `import xxx from 'lib<module>.so'` 调 Rust 导出函数——**额外导出在真机上是否可见未验证**，没有设备时别押它 |

形态 B 协议（已验证可用）：Rust 生成一次性 id + `<沙箱>/tmp/ohos_pick-<ms>.json`，随消息下发；
ArkTS 选完写 `{"ok":true,"path":...}`（取消 = `{"ok":false,"canceled":true}`），
**先写 `.tmp` 再 `fs.renameSync`** —— rename 保证 Rust 永远看不到半截 JSON；
Rust 以 100 ms 轮询、上限 5 分钟，读到即删。

## 4. 鸿蒙 API 语义差异（**最容易做出假绿的一段**）

### 4.1 Picker 返回的是 uri，不是路径

`new picker.DocumentViewPicker(ctx).select(opts)` 返回 `file://docs/...` **uri**。
`new fileUri.FileUri(uri).path` 能拿到路径，但——

> **系统目录的访问授权只在 uri 通道上生效，不覆盖同进程的 `std::fs` 裸路径读写。**

后果：Rust 拿这个路径去建目录/写分片，**下载到一半才 EACCES**，而界面此前一切正常。

### 4.2 因此两种命令要分别处置

- **选文件**：Picker → `fs.openSync(uri, READ_ONLY)` → `fs.copyFileSync(fd, '<沙箱>/imported/名字')`
  → 回传**沙箱路径**。Rust 按路径正常读。
- **选目录**：先取路径，**再由 Rust 侧探一次可写**（`create_dir_all` + 探针写入 + 删探针），
  不通过就回落应用沙箱 `files/downloads`，**并把实际落点作为返回值交回界面**
  （输入框里显示沙箱路径 = 用户看得见的真实落点，不谎报）。

### 4.3 目录选择的能力前提

`picker.DocumentSelectMode.FOLDER` 只在 **2in1 / PC** 形态可用；手机上会抛异常。
抛出来就 `{ok:false}` 回投、前端拿到 null 静默，不要吞。

## 5. 验证三步（缺一步就是没做完）

```bash
# 1. 桌面别弄坏
cd src-tauri && cargo build

# 2. 鸿蒙分支真能编过（桌面编过 ≠ 鸿蒙编过）
cargo build --target aarch64-unknown-linux-ohos --release

# 3. ArkTS 只有 hvigor 会编译 —— 这一步才能查出 .ets 的语法/类型错误
lingqu-cli hap --path <工程根>
# 期望 gates.passed=true / errors=0 / signed HAP 产出
```

**只跑第 1、2 步最常见**：Rust 全绿、`verify` 也转 pass，但 `.ets` 里一个符号没导入，
真机上点了就是不弹框——这是"编译通过"与"功能可用"之间的假绿。
（第 3 步不需要真机；装不上是后面的事。）

## 6. 落地判据要双侧（防止只写半边就算落地）

`commandImplLanded` 认的是「鸿蒙分支有真实调用」，**不查 ArkTS 那边有没有同名 `cmd` 分支**。
所以自检两条：

1. `ohos_bridge.rs` 里 `dispatch_on_main(app, ...)` 传的 `cmd` 字符串，
2. `EntryAbility.ets` 的 `__ohos_dispatch` 里能 `grep` 到同名分支。

只满足 1 的，真机表现是「点了没反应」，落档却写"已落地"。

## 7. 真机怎么验桥（判据在 hilog + 前台，不在点击返回值）

桥「编译过 + hvigor 过」只说明两侧都落地了，**功能性要真机点一次**。2026-11-21 EcoPaste 实测的可复跑套路：

1. **选有文本的入口**去点（例：设置 → About → GitHub 行的 `Open`）。ArkWeb 内**纯图标**控件
   在 `uitest dumpLayout` 里**不映射成独立节点**，只能靠截图比例估坐标——估出来的点十有八九不中。
2. **判定看三路旁证**：① 应用自己的 hilog（在 ArkTS 成功分支里打 `hilog.info(DOMAIN, TAG, 'open_url ok: %s')`）；
   ② 前台 bundle（`aa dump -l | grep -A6 FOREGROUND`，如切到 `com.huawei.hmos.browser`）；③ 截图。
3. **`uitest uiInput click` 回 `No Error` ≠ 点中**：它只表示命令送出去了。
4. **点了没日志，先分清两种情况**：
   - *没点中*（版面/坐标问题）——换有文本的入口重试；
   - *命令在到桥之前就失败*——典型是路径类 API EPERM（见 §4.1 与 AGENTS §4-175），
     前端常有提示（EcoPaste 的「Open Directory failed，没有权限」），而 hilog 里没有桥日志正是因为它没走到桥。
5. **`hdc shell ls` 读不到应用沙箱**（`/data/storage/el2/base/files` 一律 `Permission denied`）——
   别拿它当"目录不存在"的证据。
6. 整页都要靠 UI 进入的验证（设置页），**进不去就如实记「未复验」**，别继续盲点、更别据此说桥不生效（AGENTS §4-186）。
7. **打开"目录"和"文件"是两件事，目录基本打不开**（真机三条路证伪，AGENTS §4-187）：
   裸 `viewData + uri` 会被任意处理类应用抢走（现场是 WPS "打开"了日志目录）、加
   `type: 'inode/directory'` 也照样被抢、显式 `bundle=com.huawei.hmos.files + EntryAbility`
   只弹「暂无可用打开方式」。**应用沙箱目录给不了外部应用浏览** ⇒ 目录类入口改成如实提示路径
   （`hdc file recv` 可取回）并登记 limit；只有单文件才用 `viewData`。

## 8. 纪律与反例

- **别自己去开浏览器 / 别猜路径**：需要人登录、需要人操作时，用工具自己的命令（`lingqu-decision`
  说清要人做什么），不要 `start` / `rundll32` / `open` 自己造一条路（AGENTS §4-130）。
- **别把 `eprintln` 当证据**：鸿蒙侧 Rust stderr 不进 hilog（AGENTS §4-14）。要当证据的东西落文件
  （picker 的结果文件本身就是落档）。
- **别在 OHOS 分支写 `None` 了事**：那会被 `verify` 判 fail 并一直占 A4 分母。
- **别把 `__ohos_dispatch` 注册在 `onCreate` 之外**：窗口/页面还没起时 Rust 就可能在投消息。
