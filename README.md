# 灵渠 · Lingqu

> **Tauri 应用 → 鸿蒙 PC 的一站式 AI 迁移台**
> 用 [cj-tauri](https://atomgit.com/qq8864/cj-tauri)（仓颉版 Tauri）做工作台外壳，内置 [cjh](https://atomgit.com/qq8864/cjh)（仓颉 Coding Agent Harness）当 AI 引擎，
> 把「照几千字踩坑笔记手工移植一个 Tauri 应用」变成**看得见、可断点、有证据**的一条流水线。

课题：**AI 驱动的 Tauri 应用迁移到鸿蒙 PC 的工具**（研发效能与自动化工具）。交付期：2027-03-03。

**当前版本 `0.39.23`** · 五道门禁全绿 · **331 例**单测 · **35 条 `t2h:*` 命令**（能力清单共 43 条通道）· P0–P6 完成、P7 进行中。

---

## 一句话现状

| 能力 | 状态 | 实证 |
|---|---|---|
| **迁移流水线**：扫描 → 依赖 → 改造 → 构建 → **HAP 装配** → **自动签名** → 真机部署 → 验证 → 三段式报告（界面是七屏导航） | ✅ 全部落地 | 命令 `t2h:scan/deps/port/build/hap/sign/deploy/verify/report` |
| **真机跑通**（鸿蒙 PC，含签名、装机、启动、界面） | ✅ 两个样本 | **habit-tree 可用率 100%**；**m3u8dl-tauri 80%**（唯一 fail 是工程侧死资源） |
| **自动签名（路线 A：AGC 云生成）** | ✅ 真机打通 | `sign --auto` 一条命令拿到 `signed=true` + `install bundle successfully`，**不需要打开 DevEco** |
| **一键迁移 + AI 兜底**：`t2h:migrate` 后台跑 8 步 / `t2h:autoport_*` 把任务书交给 cjh 让它自己干 | ✅ 已接真数据 | 实机跑过（停在真机部署时是**设备锁屏**，不是代码问题） |
| **给 AI 用的命令行** `lingqu-cli`（18 条子命令，`--json` 输出） | ✅ | 门禁第 ⑤ 闸会校验它能编过 |
| cc-switch / tauri-mqtt-client-ohos / atomMqtt 等样本 | ⏳ 待逐个推到验证 | 扫描与依赖矩阵已跑过（cc-switch 依赖 625 项） |

---

## 快速开始

前置：仓颉 SDK（`cjpm` / `cjc`）、[cj-tauri 框架仓](https://atomgit.com/qq8864/cj-tauri)（含 `native\libcjtbridge.dll`
与 `native\webview2\WebView2Loader.dll`）、stdx。路径细节见 [`docs/开发环境.md`](docs/开发环境.md)。

```bash
./scripts/setup.sh              # 换机器先跑：环境体检（只校验，不改任何文件）
./scripts/test.sh -s            # 五道门禁（首次会派生骨架）
./scripts/run-dev.sh -b         # 编译 + 起窗口（AI 引擎自动拉起）
```

Windows 上 `scripts\test.bat` / `scripts\run-dev.bat` 参数相同（`setup.sh` 只有 bash 版，在 Git Bash 里跑）。
**脚本一律 bash 为准，`.bat` 只做「找 bash 再委托」**——一份实现、两个平台（见 ADR D-012）。

打包成可分发的便携包（含「真·单文件」形态：cjh 与 WebView2Loader 变成 PE 资源，运行期释放）：

```bash
bash packaging/pack-win-single-full.sh   # 产物只有一个 main.exe
bash packaging/package-win.sh            # 或常规目录包（DLL 按导入闭包自动收）
```

### 迁移一个应用（最小路径）

```bash
lingqu-cli scan   --path <工程>     # 五类清单 + 评分 + 覆盖率
lingqu-cli deps   --path <工程>     # Cargo 依赖 → OHOS 兼容矩阵
lingqu-cli port   --path <工程>     # 14 条规则改造（幂等、可回滚、决策可审计）
lingqu-cli build  --path <工程>     # 交叉编译 + .so 前端指纹闸
lingqu-cli hap    --path <工程>     # HAP 装配（点名校验 lib<module>.so）
lingqu-cli sign   --auto --path <工程>   # 自签名材料（见下节）
lingqu-cli deploy --path <工程> --start  # hdc 装机 + 拉起 + hilog
lingqu-cli verify --path <工程>     # 功能清单 → 可用率
lingqu-cli report --path <工程>     # 三段式报告（做了什么/没做什么/需要你做什么）
```

> 想要"一条命令跑完，卡住时让 AI 接着干"：`lingqu-cli migrate --path <工程> --wait`
> （确定性流程 8 步；或 GUI 里 `t2h:autoport_start` 把任务书交给 cjh，由它自己动手改码重跑）。
> **落档说了算**：`.lingqu/<步骤>/<工程>.json` 写着通过才算通过。

`.lingqu/<步骤>/` 落档 + `<工程>/.lingqu/evidence/` 证据（截图、hilog 尾、p7b 核对）就是交付凭证。

---

## 自动签名（路线 A：AGC 云生成）—— 这条以前一直卡人

鸿蒙真机只信任**华为签发、且 profile 的 `device-ids` 含本机 UDID** 的证书。所以「SDK 里有 p12 就能签」
是错觉，`OpenHarmony 默认材料`直装必报 `9568322 not trusted app source`。

灵渠把 DevEco 的自动签名整条流程脚本化了：

```
① 浏览器授权一次（OAuth loopback，令牌 AES-128-GCM 加密留在 ~/.lingqu/agc/）
② 团队 → ③ 设备注册（UDID + deviceType）
④ 本地生成密钥对与 CSR（hap-sign-tool；**私钥永不出本机**）
⑤ 证书（按**有效期**挑可用 / 没有就新建 / 配额满则删自己的过期件腾位）
⑥ 按**工程自己的 bundleName** 申请 debug profile（带本机 UDID）
⑦ 用 ~/.ohos/config/material 的 workKey 写 hvigor 认的口令密文 → 写回 build-profile.json5
```

```bash
lingqu-cli sign --login                  # 唯一的人工介入：浏览器点一次
lingqu-cli sign --auto --path <工程>      # 复用本机材料
lingqu-cli sign --auto --newKeys --path <工程>   # 材料来路不明 / 口令丢了时用
lingqu-cli sign --tool-check             # java / hap-sign-tool.jar / hdc 体检
```

> **不需要打开 DevEco、也不需要每次登录**。仓颉 std/stdx 没有 AES，项目里自带一份纯仓颉
> AES-128-GCM（NIST 向量 + Node/OpenSSL 互证），与 hvigor 的 AesGcmKit 逐字节兼容。
>
> 完整复盘（六个坑、协议细节表、协议端点、失败码、复用清单）见
> **[`docs/自动签名实战复盘.md`](docs/自动签名实战复盘.md)**。

---

## 目录结构

```
lingqu/
├── cj-tauri.toml            # 应用清单——单一真相（id / 窗口 / 资产 / 能力目录）
├── cjpm.toml                # 业务包（static 库；骨架以 path 依赖引用）
├── src/                     # 业务代码（仓颉）：外壳装配 + 编排 + 落档
│   ├── main.cj              # build(): AppSpec —— 命令注册 / 生命周期接线（35 条 t2h:*）
│   ├── migrate.cj / autoport.cj / agent_*.cj   # 一键迁移 / 把任务书交给 cjh / agent 观测
│   ├── compiler/            # 迁移引擎：compile / hap / deploy / fingerprint / sign*
│   └── tests/               # 39 个 *_test.cj（331 例，纯函数口径）
├── cli/                     # `lingqu-cli`：AI 用的命令行入口（18 条子命令）
├── assets/
│   ├── ui/index.html        # 前端工作台（原生 HTML/CSS/JS，七屏）
│   └── capabilities/default.json   # 能力白名单（命令 / 事件 / 权限集）
├── skills/t2h-ohos-port/    # 给 cjh 用的移植技能（含 signing.md 签名配方）
├── vendor/cjh/              # 内置 AI 引擎产物（cjh.exe + 3 DLL + SHA256SUMS）
├── scripts/                 # setup / test / run-dev（bash 为准，.bat 只委托）
├── packaging/               # 便携包与「真·单文件」打包脚本
├── docs/                    # 方案、路线图、进度、复盘、ADR、交接
└── targets/                 # `cj-tauri sync` 派生（.gitignore 忽略；勿手改，check 会判漂移）
    ├── desktop/             #   桌面可执行（launcher 调 lingqu.build()）
    └── ohos/                #   鸿蒙 HAP 工程（DevEco + build-hap.sh）
```

**一份业务代码，两端产物**：`src/` 与 `assets/` 是唯一真相，`targets/` 下各端只是外壳。

---

## 与 cjh 的关系：它是执行者，工具是它的手

> 方向定盘星见 [`AGENTS.md`](AGENTS.md) §0.1 与 ADR **D-015**：**干移植的是 agent，不是我们的代码、也不是人**。
> 灵渠只做三件事：**眼睛**（读落档做进度与停滞观测）、**手刹**（预算 / 停滞 / 一键停止）、
> **记录员**（人工介入次数 = 验收指标 A3）。

cjh 以 **web 模式**被驱动：`cjh web --port 8765 --bind 127.0.0.1`，对外是 REST（`/api/health`、`/api/sessions`、
`/api/models`、`/api/tasks`、`/api/skills`、`/api/mcp`、`/api/workspaces`、`/api/fs/list`）+ WS 流式事件。
生命周期托管移植自 cj-tauri `examples/ai-chat`（`src/cjh_host.cj`）。

| 命令 | 做什么 |
|---|---|
| `t2h:cjh_status` | 三态：`running`（已验证就绪）/ `ready`（找得到二进制，可拉起）/ `missing` |
| `t2h:cjh_deploy` / `t2h:cjh_start` | 校验随包产物 → 部署 → 拉起 → 健康检查（会起进程） |

**就绪判定只有一条**：`GET /api/health` 收到 200。没有"看着像起来了"这种模糊态。
**复用优先**：8765 上已有 cjh 就直接用，不抢不杀；只有本应用拉起的才由本应用收尾。
**只绑回环**：cjh web 默认绑 `0.0.0.0` 且无鉴权，我们自己拉起的一律 `--bind 127.0.0.1`。
**校验不过绝不解包也不执行**（4 个文件逐个 SHA256）。

---

## 加一个迁移命令的三步

1. `src/main.cj`：写一个 `<: CommandHandler` 的实现，并在 `build()` 里 `app.register("t2h:xxx", YourCommand())`；
2. `assets/capabilities/default.json`：`commands` 里加 `t2h:xxx`（**只写代码不放行 = 前端拿到 `command not allowed`**）；
3. `assets/ui/index.html`：`tauri.invoke('t2h:xxx', {...})`。

`cj-tauri check` 会交叉核对「能力声明 × 插件自描述 × 实际装配」，三方不一致当场报出来。

---

## 工程门禁（交付唯一凭证）

```bash
./scripts/test.sh -s        # 五道闸：业务包构建(零警告) + 单测 + check 三方比对 + 骨架构建 + CLI 构建
./scripts/test.sh -q        # 只跑前两道（改代码时的快速回路）
./scripts/test.sh -c        # 清缓存重建（改了公开接口后用）
```

Windows：`scripts\test.bat -s`（同样参数）。**任何代码变更交付前必须全绿**，规范见 [`AGENTS.md`](AGENTS.md) §1。
「零警告」必须看得到明细（只报条数的检查等于没检查）。

界面改动额外有一条：`t2h:ui_report` 会把版面指标（grid 列宽 / 当前屏 / 设置面板 / 模型条数 / JS 错误）
落 `.lingqu/ui-report.{json,log}`；整段流程验证可用 `LINGQU_UI_PROBE=1` 让页面自跑序列——
**没有视觉也能证明版面对**。

真机侧的口径：**别看退出码**（`hdc install` 失败也返回 0），只能按输出文本判
（`install bundle successfully` / `start ability successfully`）；界面是否真的画出来，用
`uitest dumpLayout` 断言「本应用窗口在前台 + 有 `Web`/`rootWebArea` 节点 + 有真实界面文案」。

---

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/自动签名实战复盘.md`](docs/自动签名实战复盘.md) | **自动签名六个坑的完整复盘** + 协议细节 + 可照抄手册 + 复用清单 |
| [`docs/鸿蒙自动签名机制.md`](docs/鸿蒙自动签名机制.md) | 机制研究：AGC 端点表、失败码、与 DevEco/flutter 实现对照 |
| [`docs/实施路线图.md`](docs/实施路线图.md) | **可执行任务拆解**：P0–P8 阶段、每阶段出口判据与证据 |
| [`AGENTS.md`](AGENTS.md) | **开发契约**：门禁、架构契约、编码规范、**§4 已踩坑清单（87 条）** |
| [`CHANGELOG.md`](CHANGELOG.md) | 版本更新日志（现象 → 根因 → 处置，含实测证据） |
| [`docs/进度记录.md`](docs/进度记录.md) | 每轮做了什么、验证到什么程度、下一步 |
| [`docs/会话交接.md`](docs/会话交接.md) | 换会话/换机器怎么接（30 分钟上手） |
| [`docs/需求追踪.md`](docs/需求追踪.md) | 验收标准 → 功能 → 界面 → 证据的追踪矩阵 |
| [`docs/设计决策记录.md`](docs/设计决策记录.md) | ADR：D-001~D-018（含 D-015 方向、D-017/018 签名材料与云生成边界） |
| [`docs/案例素材.md`](docs/案例素材.md) | 素材清单：本地 Tauri 样本、框架/引擎仓、素材→阶段映射 |
| [`docs/P2-scan-口径草案.md`](docs/P2-scan-口径草案.md) | 度量口径：覆盖率（C1/C2/C3）、处置值域、评分规则、scan schema |
| [`docs/5样本矩阵-实测.md`](docs/5样本矩阵-实测.md) | 5 样本 × 5 步实测矩阵（`t2h:batch` 产出） |
| [`docs/集成cjh.md`](docs/集成cjh.md) | cjh 集成指南（WS 协议、托管语义） |
| [`docs/上游回馈-cjh.md`](docs/上游回馈-cjh.md) | 发现的上游缺口与建议（含"cjh 缺 REST 对话入口"） |
| [`docs/产品方案.md`](docs/产品方案.md) · [`docs/技术思路.md`](docs/技术思路.md) | 产品形态与引擎层设计 |
| [`docs/开发环境.md`](docs/开发环境.md) | 环境变量表、构建命令、踩坑索引（按报错原文） |
| [`docs/ui-mockup.html`](docs/ui-mockup.html) | 七屏高保真 UI 效果图（浏览器直接打开） |
| [`skills/t2h-ohos-port/`](skills/t2h-ohos-port/SKILL.md) | 给 cjh 的移植技能（含 `references/signing.md` 签名配方） |

---

## 路线

```
P0–P6 ✅  外壳 / 对话通道 / 扫描 / 依赖 / 改造 / 构建·HAP·签名·部署 / 验证·报告
P7   🔶  5 样本矩阵已上线（t2h:batch）；样本验证 2/5（habit-tree 100%、m3u8dl 80%）；
         待办：清 m3u8dl 的 rawfile 死资源、其余 3 个样本推到底、T7-4 基线 / T7-5 消融
P8   ⬜  迁移指南 + 开源收尾
```

验收标准（课题原文，见 [`docs/需求.md`](docs/需求.md)）：5 个真实开源 Tauri 应用迁移验证 ·
迁移分析覆盖率 **100%** · 单应用平均人工介入 **≤5 处** · 鸿蒙电脑上核心功能可用率 **≥80%** ·
工具**开源 + 迁移指南**。
