# 灵渠 · Lingqu

> **Tauri 应用 → 鸿蒙 PC 的一站式 AI 迁移台**
> 用 [cj-tauri](https://atomgit.com/qq8864/cj-tauri)（仓颉版 Tauri）做工作台外壳，内置 [cjh](https://atomgit.com/qq8864/cjh)（仓颉 Coding Agent Harness）当 AI 引擎，
> 把「照几千字踩坑笔记手工移植一个 Tauri 应用」变成**看得见、可断点、有证据**的一条流水线。

课题：**AI 驱动的 Tauri 应用迁移到鸿蒙 PC 的工具**（研发效能与自动化工具）。
交付期：2027-03-03。

---

## 现在到哪一步（v0.1 骨架）

| 能力 | 状态 |
|---|---|
| 工作台外壳（cj-tauri 2.0，1280×840，桌面 + 鸿蒙双目标骨架） | ✅ 可编译可运行 |
| 七步流程导航（项目/画像/依赖/改造/构建/验证/报告） | ✅ 结构就位 |
| **环境体检** `t2h:env` —— Rust / llvm-mingw / OHOS NDK / DevEco / hvigor / ohpm / hdc / cjh 一次查清 | ✅ 已接真数据 |
| **cjh 引擎接入** `t2h:cjh_probe` / `t2h:cjh_start` —— 探测 8765、复用优先、`launchHidden` 静默拉起 | ✅ 已接真数据 |
| 迁移画像 / 依赖扫描 / 改造执行 / 构建 / 验证 / 报告 | ⏳ 界面占位，命令待接 |

> 骨架的验收标准很简单：**双击起来，环境体检全绿，点「启动引擎」cjh 能起来并被探测到。**
> 这三件事不成立，后面的迁移引擎没有意义。

---

## 目录结构

```
lingqu/
├── cj-tauri.toml            # 应用清单——单一真相（id / 窗口 / 资产 / 能力目录 / 链接选项）
├── cjpm.toml                # 业务包（static 库；骨架以 path 依赖引用）
├── src/main.cj              # 业务装配点 build(): AppSpec（零平台知识）
├── assets/
│   ├── ui/index.html        # 前端工作台（任意 Web 技术栈；当前是原生 HTML/CSS/JS）
│   └── capabilities/default.json   # 能力白名单（命令 / 事件 / 权限集）
├── vendor/cjh/              # 内置 AI 引擎产物（cjh.exe + 3 DLL + SHA256SUMS）
├── scripts/run-dev.ps1      # 一条命令配齐全部运行前提并启动
├── tools/vendor-cjh.ps1     # 更新 vendor 里的 cjh 并重算校验
├── docs/                    # 方案、技术思路、需求、开发环境、UI 效果图
└── targets/                 # `cj-tauri sync` 派生（.gitignore 忽略；勿手改，check 会判漂移）
    ├── desktop/             #   桌面可执行（launcher 调 lingqu.build()）
    └── ohos/                #   鸿蒙 HAP 工程（DevEco + build-hap.sh）
```

**一份业务代码，两端产物**：`src/` 与 `assets/` 是唯一真相，`targets/` 下各端只是外壳。

---

## 构建与运行

前置：仓颉 SDK（`cjpm` / `cjc`）、[cj-tauri 框架仓](https://atomgit.com/qq8864/cj-tauri)（含 `native\libcjtbridge.dll`
与 `native\webview2\WebView2Loader.dll`）、stdx。**这些路径都在一个脚本里配好**，详见 [`docs/开发环境.md`](docs/开发环境.md)。

```powershell
.\scripts\run-dev.ps1 -Sync -Build -Cjh
```

| 开关 | 作用 |
|---|---|
| `-Sync` | 先 `cj-tauri sync`（改了 `cj-tauri.toml` 之后要重跑） |
| `-Build` | 先 `cd targets\desktop && cjpm build` |
| `-Cjh` | 顺带把 `vendor/cjh/win-x64/cjh.exe` 拉起来（8765 上已有实例则复用） |

脚本做的事（少一条就跑不起来，全是实测报错换来的）：PATH 加**四段**——仓颉运行时、stdx、
框架 `native`、框架 `native\webview2`；**工作目录切到工程根**（launcher 用相对路径读 `assets/`）；
`LINGQU_CJH` 指向仓内 cjh。

鸿蒙端（PC / 2in1）：

```bash
export CANGJIE_STDX_OHOS=D:/cangjie-stdx-ohos/linux_ohos_aarch64_cjnative/dynamic/stdx
cd targets/ohos && bash build-hap.sh            # 编 HAP
cd targets/ohos && bash build-hap.sh --install  # 编完装到设备并拉起
```

> 提醒：模板不带签名证书。首次要在 DevEco 里 *File → Project Structure → Signing Configs*
> 勾「Automatically generate signature」（需登录华为账号），否则只能编出 unsigned HAP，装不进设备。

---

## 与 cjh 的关系：内置引擎，复用优先

- cjh 以 **web 模式**被驱动：`cjh web --port 8765 --bind 127.0.0.1`，对外是 REST（`/api/health`、`/api/sessions`、
  `/api/models`、`/api/tasks`、`/api/skills`、`/api/mcp`、`/api/workspaces`、`/api/fs/list`）+ WS 流式事件。
- 拉起走框架的 `launchHidden()`（`std.process.launch` 会让 GUI 子系统的应用蹦出黑窗口）。
- **复用优先**：8765 上已有用户自己的 cjh 就直接用，不抢、不杀；只有本应用拉起的那份才归本应用收尾。
- cjh 路径优先级：`LINGQU_CJH` 环境变量 → `vendor/cjh/win-x64/cjh.exe`（工作目录=工程根）
  → 同上上跳一层 → 开发期本机兜底路径。全无则如实报「引擎缺失」，其余功能照常（手动模式）。
- 仓内自带一份 cjh（`vendor/cjh/`，含 `SHA256SUMS`），开箱即用；更新用 `tools/vendor-cjh.ps1`。

---

## 加一个迁移命令的三步

1. `src/main.cj`：写一个 `<: CommandHandler` 的实现，并在 `build()` 里 `app.register("t2h:xxx", YourCommand())`；
2. `assets/capabilities/default.json`：`commands` 里加 `t2h:xxx`（**只写代码不放行 = 前端拿到 `command not allowed`**）；
3. `assets/ui/index.html`：`tauri.invoke('t2h:xxx', {...})`。

`cj-tauri check` 会交叉核对「能力声明 × 插件自描述 × 实际装配」，三方不一致当场报出来。

---

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/需求.md`](docs/需求.md) | 课题原始需求与验收标准（三条硬指标） |
| [`docs/产品方案.md`](docs/产品方案.md) | 产品化方案：形态、三个关键决策、7 屏设计、18 周排期 |
| [`docs/技术思路.md`](docs/技术思路.md) | 引擎层技术思路：证据闸门、规则优先、ArkWeb 兼容层、六道反幻觉闸 |
| [`docs/ui-mockup.html`](docs/ui-mockup.html) | 七屏高保真 UI 效果图（可直接用浏览器打开） |
| [`docs/开发环境.md`](docs/开发环境.md) | 环境变量表、构建命令、排错清单 |

---

## 路线

```
v0.1 骨架（当前）→ 环境体检 + cjh 接入 + 七步导航
v0.2 扫描   → t2h:scan（五类清单 + 评分 + 覆盖率口径）
v0.3 依赖   → t2h:deps（Cargo 依赖树 OHOS 兼容矩阵 + 替代建议）
v0.4 改造   → t2h:port（规则引擎 + ArkWeb 兼容层 + 审批卡）
v0.5 构建   → t2h:build/deploy（交叉编译 + HAP + .so 指纹校验 + hdc）
v0.6 验证   → t2h:verify/report（功能清单 + 证据 + 断点续迁）
```
