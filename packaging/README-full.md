# 灵渠迁移台 · 单文件版（Windows，**只有一个 exe**）

> 这个目录里只有两个文件：`main.exe` 与这份说明。
> **没有 DLL、没有 `assets/`、没有 `vendor/`** —— 它们全在 exe 里：

| 原来随包的东西 | 现在在哪 |
|---|---|
| 仓颉运行时 / std / stdx（98 个 DLL） | 静态链接进 exe |
| `libcjtbridge.dll`（C 桥） | 编成静态归档 `libcjtbridge.a` 链进 exe |
| `WebView2Loader.dll` | 字节编进 C 桥，首次运行释放到 `%TEMP%\cj-tauri-loader\` 后按绝对路径加载 |
| `assets/`（页面 + 能力清单） | base64 编进 exe，装配期由 `LingquAssetResolver` 解码 |
| `vendor/cjh/`（AI 引擎 + 3 个运行时 DLL） | 作为 **PE 资源**（RT_RCDATA）随行，首次运行释放到 `%LOCALAPPDATA%\lingqu\cjh` |

## 怎么用

双击 `main.exe` 即可（不需要 `run.bat`，也不需要任何环境变量）。

- **AI 面板**：`Ctrl+,` 打开设置 →「部署 / 拉起引擎」。首次会从 exe 里释放 cjh 到
  `%LOCALAPPDATA%\lingqu\cjh`（4 个文件，校验 SHA256 通过才执行），再 `cjh web --bind 127.0.0.1`。
- 日志：`%LOCALAPPDATA%\cj-tauri\logs\lingqu.log`；界面自检：运行目录下的 `.lingqu\ui-report.json`。
- 若杀软对"单文件自解压写盘"敏感，首次可能被拦一次，放行后即正常（这是单文件交付的通用现象）。

## 仍然需要外部工具的功能

| 功能 | 前提 |
|---|---|
| 交叉编译（⑤ 屏） | rustup + `aarch64-unknown-linux-ohos` + `NATIVE_OHOS_SDK` |
| HAP 装配 | DevEco Studio（`DEVECO_HOME`） |
| 签名体检 | `~/.ohos/config` 里的自动签名材料（免账号） |
| 真机部署（⑥ 屏） | 鸿蒙设备 + `hdc`（随 DevEco SDK） |

## 已知限制（如实）

- 未做代码签名，SmartScreen 可能提示"未知发布者"。
- 只打 windows-x64。
- ⑥ 屏的「功能清单 / 可用率」现已接真数据（`t2h:verify`），但其中两项需要先跑一次「交叉编译」才算得出。
- 打包脚本：`packaging/pack-win-single-full.sh`（机制照抄 `cj-tauri/scripts/pack-win-single.sh`）。
