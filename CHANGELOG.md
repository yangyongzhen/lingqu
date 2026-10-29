# 更新日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的结构，
版本号三处一致：`cjpm.toml` / `cj-tauri.toml` / 本文件最新条目（见 `AGENTS.md` §6）。

---

## [0.2.0] - 2026-10-29

**主题**：AI 引擎托管完整化 + 工程规范落地。

### Added

- **`src/cjh_host.cj`**：完整移植 cj-tauri `examples/ai-chat` 的 cjh 托管实现
  - 健康检查 `GET /api/health`（`stdx.net.http`），替代原先的裸 TCP 探测
  - 三态状态机 `running` / `ready` / `missing`，纯读可轮询
  - `launchHidden` 静默拉起 + 100ms × 10s 就绪等待（`Ready` / `Died` / `Timeout`）
  - 复用优先：8765 上已有实例不抢不杀；只有 `gCjhOwned` 的才在退出时收尾
  - 拉起前先收掉自己上一只，避免旧进程占端口导致新实例绑定失败
  - 二进制三级来源：`LINGQU_CJH` → 已部署目录 → 仓内 vendor（4 文件逐个 SHA256）
  - vendor 不可用时按 `LINGQU_CJH_BUNDLE` 的 zip 用系统 bsdtar（绝对路径）解包后拉起
- **三条运维命令**：`t2h:cjh_status` / `t2h:cjh_start` / `t2h:cjh_deploy`；`t2h:quit`（先收引擎再退窗口）
- **生命周期收尾**：守护线程 `waitForExit()` 后收 cjh（新形态 `AppSpec` 无 onExit 钩子），
  收尾跑 5 轮覆盖「用户秒关窗口 + 后台拉起在途」的抢跑
- **单元测试** `src/tests/core_test.cj`：13 例，覆盖 `joinPath` / `firstExisting` / `parsePortEnv` /
  `putEndpoints` / `cjhVendorVerified` 的主路径与边界
- **交付门禁** `scripts/test.ps1`：业务包构建（零警告）+ 单测 + `cj-tauri check` 三方比对 + 骨架构建
- **工程规范文档**：`AGENTS.md`、本 `CHANGELOG.md`、`docs/需求追踪.md`、`docs/进度记录.md`、
  `docs/会话交接.md`、`docs/设计决策记录.md`

### Changed

- 日志落盘：`setLogToDefaultFile("lingqu")` → `%LOCALAPPDATA%\cj-tauri\logs\lingqu.log`
- 启动时在**后台线程**自动 ensure 引擎，不再挡住窗口出现
- 工作台 UI：cjh 从"alive 布尔"改为三态展示；新增「一键部署并启动引擎」「用指定路径启动」「退出」入口
- `cjpm.toml` 补 `[target.x86_64-w64-mingw32]` / `[target.x86_64-unknown-linux-gnu]` 的
  `link-option`（`-lcjtbridge`）——`cjpm test` 的测试可执行文件走业务包自己的链接行

### Fixed

- 加 `LogPlugin` 却没在能力清单声明 `log:path` / `log:write`，被 `cj-tauri check` 三方比对拦下
- `vendor/cjh/win-x64/*.dll` 被模板 `.gitignore` 的 `*.dll` 规则忽略（克隆后 HTTPS 全灭的隐患）

### 验证范围（诚实标注）

- ✅ 编译零警告；`cj-tauri check` 通过；13 例单测全绿；门禁四道闸全绿
- ✅ 退出收尾线程实测触发（日志 `窗口已全部退出，开始收尾`）
- ✅ 仓内 vendor 实测可用：`/api/health` → `{"status":"ok","version":"1.6.1","web_port":8765}`
- ⚠️ 窗口渲染在受限宿主（容器/沙箱）里不可验证：Chromium 起不了子进程 → `0x8000ffff`；
  需在普通桌面会话运行（开发机已验证窗口标题 `灵渠迁移台 · Lingqu`）
- ⚠️ 鸿蒙端 HAP 尚未构建验证

---

## [0.1.1] - 2026-10-28

### Added

- `vendor/cjh/win-x64/`：内置 cjh 产物（`cjh.exe` + 3 个运行时 DLL）+ `SHA256SUMS`
- `tools/vendor-cjh.ps1`：重新灌入 cjh 产物并重算校验
- `scripts/run-dev.ps1`：一条命令配齐运行前提（四段 PATH / 工作目录 / cjh 指向），支持 `-Sync` / `-Build` / `-Cjh`
- `docs/开发环境.md`：环境变量表 + 踩坑索引（按报错原文）

### Fixed

- **`.ps1` 存为 UTF-8 BOM**：Windows PowerShell 5.1 读无 BOM 的脚本按 GBK 解码，
  中文注释会把字符串引号撑坏，报「数组索引表达式丢失或无效 / 字符串缺少终止符」
- `.gitignore` 放行 `vendor/cjh/win-x64/*.dll`（运行时依赖，不是构建产物）
- cjh 版本号纠正：实测 `/api/health` 回报 **1.6.1**（原按 cj-tauri 仓里的 1.5.3 写成）

---

## [0.1.0] - 2026-10-28

### Added

- cj-tauri 2.0 工程骨架：业务包（static）+ `targets/desktop` + `targets/ohos`，`cj-tauri check` 通过
- 七步流程导航（项目 / 画像 / 依赖 / 改造 / 构建 / 验证 / 报告），中栏 + 右栏 Agent Dock
- **环境体检** `t2h:env`：Rust / llvm-mingw / OHOS NDK / DevEco / hvigor / ohpm / hdc / cjh 八项
- cjh 探测与拉起（当时的精简版：TCP 探测 + `launchHidden`）
- 方案文档沉淀：`docs/需求.md`、`docs/产品方案.md`、`docs/技术思路.md`、`docs/ui-mockup.html`
