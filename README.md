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
| **cjh 引擎托管**（移植自 ai-chat 的 `cjh_host.cj`） | ✅ 已接真数据 |
| 迁移画像 / 依赖扫描 / 改造执行 / 构建 / 验证 / 报告 | ⏳ 界面占位，命令待接 |

> 骨架的验收标准很简单：**双击起来，环境体检全绿，引擎能起来并被探测到，关窗口后引擎被收走。**
> 这几件事不成立，后面的迁移引擎没有意义。

---

## 目录结构

```
lingqu/
├── cj-tauri.toml            # 应用清单——单一真相（id / 窗口 / 资产 / 能力目录 / 链接选项）
├── cjpm.toml                # 业务包（static 库；骨架以 path 依赖引用）
├── src/main.cj              # 业务装配点 build(): AppSpec（环境体检 / 命令注册 / 生命周期接线）
├── src/cjh_host.cj          # cjh 引擎托管（发现 / 健康检查 / 拉起 / 收尾 / 部署），移植自 ai-chat
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
与 `native\webview2\WebView2Loader.dll`）、stdx。**这些路径都在脚本里配好了**，详见 [`docs/开发环境.md`](docs/开发环境.md)。

```bash
./scripts/setup.sh          # 换机器先跑：把 cjpm.toml 里的本机绝对路径对齐
./scripts/test.sh -s        # 门禁四道闸（首次会派生骨架）
./scripts/run-dev.sh -b     # 编译 + 起窗口（AI 引擎自动拉起）
```

Windows 上把 `./scripts/xxx.sh` 换成 `scripts\xxx.bat`（同样参数）。**脚本一律 bash 为准，
`.bat` 只做「找 bash 再委托」**——一份实现、两个平台（见 ADR D-012）。

脚本做的事（少一条就跑不起来，全是实测报错换来的）：PATH 加**四段**——仓颉运行时、stdx、
框架 `native`、框架 `native\webview2`；**工作目录切到工程根**（launcher 用相对路径读 `assets/`）。

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

cjh 以 **web 模式**被驱动：`cjh web --port 8765 --bind 127.0.0.1`，对外是 REST（`/api/health`、`/api/sessions`、
`/api/models`、`/api/tasks`、`/api/skills`、`/api/mcp`、`/api/workspaces`、`/api/fs/list`）+ WS 流式事件。
生命周期托管整体移植自 cj-tauri `examples/ai-chat` 的成熟实现（`src/cjh_host.cj`）。

### 三条运维命令

| 命令 | 做什么 | 副作用 |
|---|---|---|
| `t2h:cjh_status` | 三态：`running`（已验证就绪）/ `ready`（找得到二进制，可拉起）/ `missing` | 无（纯读，可轮询） |
| `t2h:cjh_deploy` | 校验随包产物 → 必要时按安装包部署 → 拉起 → 健康检查 | 会起进程 |
| `t2h:cjh_start` | 按指定路径拉起（`{path:"..."}`） | 会起进程 |

**判定就一条**：`GET /api/health` 收到 200。没有"看着像起来了"这种模糊态。

### 生命周期

- **复用优先**：8765 上已有 cjh（可能是你自己的）就直接用，不抢、不杀、退出时不动它；
  只有本应用拉起的（`gCjhOwned=true`）才由本应用收尾。
- **拉起用 `launchHidden()`**：本应用是 GUI 子系统，`std.process.launch` 会让 Windows 给子进程
  单配一个控制台黑窗口。
- **退出收尾**：新形态 `AppSpec` 没有 onExit 钩子，所以用一条守护线程 `app.waitForExit()` 等窗口
  全退出后收；`t2h:quit` 命令则先收 cjh 再退窗口。收尾跑 5 轮（200ms 间隔）以覆盖"用户秒关窗口、
  后台拉起还在途中"的抢跑。
- **就绪等待**：100ms 一步、最多 10 秒（cjh web 要装 Agent 栈，秒级是正常量级）；超时不算成功。
- **只绑回环**：cjh web 默认绑 `0.0.0.0` 且默认不带鉴权 token，等于把「能跑 shell、能读写工作区、
  能调 LLM」的整套 API 摆到局域网上——我们自己拉起的实例一律 `--bind 127.0.0.1`。

### 二进制来源与校验

优先级：`LINGQU_CJH` 环境变量 → 已部署目录（`%LOCALAPPDATA%\lingqu\cjh`）→ **仓内 `vendor/cjh/win-x64/`**
（后者要过 SHA256 逐个比对 4 个文件：`cjh.exe` + `libcangjie-runtime.dll` + `libssl-3-x64.dll` + `libcrypto-3-x64.dll`）。
全都没有就如实报「引擎缺失」，AI 面板不可用但其余功能照常——不假装连上了。

校验不过**绝不解包也不执行**：这份二进制是能跑 shell 的 agent 引擎。若 vendor 不可用，可设
`LINGQU_CJH_BUNDLE` 指到一份 zip，由系统 bsdtar（`%SystemRoot%\System32\tar.exe`，绝对路径调用，
别写裸 `tar`——Git Bash 的 GNU tar 不认 zip）解包到安装目录后再拉起。

环境变量：`LINGQU_CJH` / `LINGQU_CJH_PORT`（默认 8765）/ `LINGQU_CJH_BUNDLE`。

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
| [`docs/实施路线图.md`](docs/实施路线图.md) | **可执行任务拆解**：P0–P8 阶段、每阶段的出口判据与证据、里程碑日历 |
| [`docs/案例素材.md`](docs/案例素材.md) | **素材清单**：6 个本地 Tauri 样本、框架/引擎仓库、文档与文章链接、素材→阶段映射 |
| [`AGENTS.md`](AGENTS.md) | **开发契约**：交付门禁、架构契约、编码规范、已踩坑清单、文档与提交纪律 |
| [`CHANGELOG.md`](CHANGELOG.md) | 版本更新日志（Keep a Changelog 风格） |
| [`docs/需求.md`](docs/需求.md) | 课题原始需求与验收标准（三条硬指标） |
| [`docs/需求追踪.md`](docs/需求追踪.md) | 验收标准 → 功能 → 界面 → 证据的追踪矩阵（五级状态） |
| [`docs/进度记录.md`](docs/进度记录.md) | 每轮做了什么、验证到什么程度、下一步 |
| [`docs/会话交接.md`](docs/会话交接.md) | 换会话/换机器怎么接（环境、配置三处、判据、命令速查） |
| [`docs/设计决策记录.md`](docs/设计决策记录.md) | ADR：11 条定了就不翻案的决策与理由 |
| [`docs/产品方案.md`](docs/产品方案.md) | 产品化方案：形态、三个关键决策、7 屏设计、18 周排期 |
| [`docs/技术思路.md`](docs/技术思路.md) | 引擎层技术思路：证据闸门、规则优先、ArkWeb 兼容层、六道反幻觉闸 |
| [`docs/开发环境.md`](docs/开发环境.md) | 环境变量表、构建命令、踩坑索引（按报错原文） |
| [`docs/ui-mockup.html`](docs/ui-mockup.html) | 七屏高保真 UI 效果图（可直接用浏览器打开） |

## 工程门禁

```bash
./scripts/test.sh -s        # 四道闸：业务包构建(零警告) + 单测 + check 三方比对 + 骨架构建
./scripts/test.sh -q        # 只跑前两道（改代码时的快速回路）
```

Windows：`scripts\test.bat -s`（同样参数）。**任何代码变更交付前必须全绿**，规范见 [`AGENTS.md`](AGENTS.md) §1。

界面改动额外有一条：`t2h:ui_report` 会把版面指标（grid 列宽 / 当前屏 / 设置面板 / 模型条数 / JS 错误）
落 `.lingqu/ui-report.{json,log}`；整段流程验证可用 `LINGQU_UI_PROBE=1` 让页面自跑序列——
**没有视觉也能证明版面对**。

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
