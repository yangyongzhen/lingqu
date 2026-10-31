# lingqu-cli —— 给 AI agent 的命令行入口

`t2h:*` 原先只有应用内 IPC 入口（页面 ↔ 应用），**agent 的 bash 调不到**；这个可执行文件补的就是这一环。
它与界面按钮**同一份实现**（直接调 `CommandHandler`），所以行为永远一致，不会出现"CLI 能跑、界面报错"。

## 构建

```bash
# 需要 CANGJIE_HOME / CANGJIE_STDX / CJ_TAURI_ROOT（与主工程一致）
cd cli && cjpm build
# 产物：cli/target/release/bin/main.exe（打包/分发时改名为 lingqu-cli.exe 即可）
```

`./scripts/test.sh` 的门禁 ⑤ 会编译它（零警告）。

## 用法

```bash
lingqu-cli <命令> --键 值 …        # --键=v 也认
lingqu-cli --list                  # 列出全部命令
lingqu-cli --help                  # 用法
```

| 命令 | 作用 |
|---|---|
| `scan --path <工程>` | 扫描画像（五类清单 + 评分 + C1/C2/C3） |
| `deps --path <工程>` | Cargo 依赖兼容矩阵 |
| `port --path <工程> [--apply]` | 规则改造（默认预览；apply 落盘且可 `revert`） |
| `revert --path <工程>` | 回滚上一轮改造 |
| `decisions --path <工程> --action record|list` | 人工决策留痕（A3 口径） |
| `diagnose --log <日志路径>` | 错误指纹诊断（命中即给修法，不调模型） |
| `build --path <工程> [--verifyOnly]` | 交叉编译；`verifyOnly` 只比前端指纹 |
| `hap --path <工程>` | 装配 HAP |
| `sign --path <工程> [--apply]` | 签名体检；`apply` 写回 signingConfigs |
| `deploy --path <工程>` | 真机装启 + hilog |
| `verify --path <工程>` | 采证 + 功能清单 + 可用率 + 报告 |
| `report --path <工程>` | 三段式迁移报告（MD/HTML/JSON） |
| `resume --path <工程>` | 8 步断点板 |
| `batch --samples "a\|b\|c"` | 多工程矩阵 |
| `skill [--action status\|install]` | 安装 AI 迁移技能到 cjh |
| `agent_context --path <工程> --action status\|install\|remove` | 工程上下文（AGENTS.md 区块 + 切 cjh workspace） |
| `env` | 工具链体检 |

## 退出码

- `0`：命令返回体里 `ok=true`
- `1`：失败或参数不全（stderr 里是错误原因；stdout 仍是 JSON）

## 运行环境

和主程序一样需要 DLL/PATH（`CJ_TAURI_ROOT/native`、`native/webview2`、`CANGJIE_STDX`、
`CANGJIE_HOME/runtime/lib/windows_x86_64_cjnative`）。打包分发时把 `lingqu-cli.exe` 与本包放在
同一目录，agent 用相对路径/绝对路径调用都行。

> 已知限制：cjh 技能 frontmatter 的 `tools:`（声明式工具）目前**硬编码 `/bin/bash -c`**，
> 在 Windows 上不可用（上游 `registry.cj` 的实现）。所以本项目的做法是：CLI + 在技能正文里
> 写清调用方式，让 agent 用它的 **bash 工具**（Windows 上自动选 Git Bash）去调。
