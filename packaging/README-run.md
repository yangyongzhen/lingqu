# 灵渠迁移台 · Windows 便携包

> 有两种包：**动态版**（`lingqu-<ver>-win-x64`，根目录 48 个 DLL，构建快）与
> **静态版**（`lingqu-<ver>-win-x64-static`，根目录 **5 个 DLL**，仓颉 std 与 stdx 都进了 exe）。
> 使用方式完全一样；静态版更适合拷给别人。

## 怎么跑

双击 `run.bat`（推荐），或在该目录下直接运行 `main.exe`。

> **别把 `main.exe` 单独拷走**：它按相对路径读 `assets/`、按同目录找 DLL 与 `vendor/cjh/`，
> 目录结构必须整体保留。首次启动若一闪而过，**再点一次**（历史现象，见 AGENTS §4）。

## 包里有什么

| 路径 | 作用 |
|---|---|
| `main.exe` | 主程序（cj-tauri 外壳 + 仓颉业务代码，桌面 = WebView2） |
| `run.bat` | 把本目录加入 PATH 后启动（省得你手工配 PATH） |
| `assets/` | 界面与能力清单（`ui/index.html`、`capabilities/default.json`）——**必需** |
| `*.dll`（根目录） | 仓颉运行时 + `libcjtbridge`（C 桥）+ `libstdx.encoding.json` + `WebView2Loader` |
| `vendor/cjh/win-x64/` | 内置 AI 引擎 cjh 1.6.1（`cjh.exe --version` 已验证可跑）；**`vendor/cjh/SHA256SUMS` 也在包里**——少了它引擎不会被拉起（自校验不过就不执行），右栏 AI 面板会显示"可拉起"但起不来 |
| `scripts/` | `test.bat` / `test.sh` 等门禁脚本（可选，自测用） |

## AI 面板怎么启用

右栏 AI 不是打开就有，第一次要**拉一次引擎**：`Ctrl+,` 打开设置 → 点「部署 / 拉起引擎」。
它会先校验 `vendor/cjh/` 四个文件的 SHA256，再拉起 `cjh --bind 127.0.0.1`（默认 8765），
就绪判据只有一条：`GET /api/health` 返回 200。之后模型与密钥也在同一面板里配。

## 能干什么（都要 Windows 上装了对应外部工具）

| 功能 | 前提 |
|---|---|
| 扫描 / 依赖 / 改造规则 / 诊断（①②③④ 屏） | 只要有 Tauri 工程源码，无需别的 |
| 交叉编译（⑤ 屏「交叉编译（OHOS）」） | rustup + `aarch64-unknown-linux-ohos` target + `NATIVE_OHOS_SDK` 指向 DevEco 的 `sdk\default\openharmony\native` |
| HAP 装配（⑤ 屏「装配 HAP」） | DevEco Studio（`DEVECO_HOME`），会自动补 `ohpm install`，并**自动把交叉编译出的 `.so` 装进 HAP** |
| 签名体检 / 写回（⑤ 屏） | `~/.ohos/config` 里有 DevEco 自动签名材料（免账号、免 IDE、不联网） |
| 安装并启动（⑥ 屏） | 鸿蒙设备连上并开 USB 调试；`hdc` 随 DevEco SDK 提供 |
| AI 面板（右栏） | `vendor/cjh/win-x64/` 在位；模型/密钥在应用内「设置」（Ctrl+,）配置 |

环境变量（可选，工具会自己从 `DEVECO_HOME` 推导；**过期的值会被自动忽略**）：

```
DEVECO_HOME       D:\oh\DevEcoStudio
DEVECO_SDK_HOME   D:\oh\DevEcoStudio\sdk
OHOS_HOME         D:\oh\DevEcoStudio\sdk\default\openharmony
NATIVE_OHOS_SDK   D:\oh\DevEcoStudio\sdk\default\openharmony\native
```

## 无界面自检（可选，出问题时报给我）

```powershell
# 版面/通道自检（跑一轮界面自检序列，回投指标）
$env:LINGQU_UI_PROBE='1'; .\run.bat

# 真机部署体检（装 → 启 → 抓 hilog），结果落 .lingqu\deploy\<工程>.json
$env:LINGQU_DEPLOY_PATH='E:\test\rust\habit-tree'; .\run.bat

# 签名体检（秒级，免账号）
$env:LINGQU_SIGN_PATH='E:\test\rust\habit-tree'; .\run.bat
```

日志：`%LOCALAPPDATA%\cj-tauri\logs\lingqu.log`；界面自检：`.lingqu\ui-report.json`。

## 已知限制（如实）

- 本包**未做代码签名**，Windows SmartScreen 可能提示"未知发布者"，选"仍要运行"即可。
- 只打了 **windows-x64**；Linux 版需要在那台机器上 `scripts/test.sh` 自己编（运行库见 `AGENTS.md` §4-31）。
- ⑥ 屏的「功能清单 / 可用率」仍是占位示意，等 P6 的 `t2h:verify`。
- T5-4 release 签名（上架用）需要企业证书/华为账号，属外部依赖，未做。
