# 工具全量清单与自检/自装（`lingqu-cli` / `devecocli`）

> 什么时候读：需要完整子命令与参数（不是只跑 8 步流水线那几条），或要查鸿蒙平台文档、
> 拉官方 skills、读设备日志时。**索引与"先 `resume` 再跑那一步"的口径在 `SKILL.md`。**

## 1. `lingqu-cli` 全量子命令

灵渠迁移台的命令行入口，和界面按钮**同一份实现**（`lingqu-cli <命令> --键 值`）。
在工程目录里直接跑，结果既打印 JSON、也落工程自己的 `.lingqu/`。

```bash
lingqu-cli scan   --path .                   # 扫描画像 → .lingqu/scan/<工程>.json
lingqu-cli deps   --path .                   # 依赖矩阵 → .lingqu/deps/<工程>.json
lingqu-cli port   --path .                   # 规则改造（预览；apply 才落盘且可 revert）
lingqu-cli revert --path .                   # 回滚 port 的改动
lingqu-cli decisions --path .                # 人工决策台账
lingqu-cli build  --path .                   # 交叉编译；--verifyOnly 只比前端指纹
lingqu-cli hap    --path .                   # 装配 HAP
lingqu-cli sign   --path .                   # 签名体检（--apply 写回 signingConfigs）
lingqu-cli deploy --path .                   # 真机装启 + hilog
lingqu-cli verify --path .                   # 采证 + 功能清单 + 可用率
lingqu-cli report --path .                   # 三段式迁移报告
lingqu-cli resume --path .                   # 8 步断点板（下一步是哪步）
lingqu-cli batch  --samples "a|b|c"          # 多工程矩阵
lingqu-cli probe  --path . --auto --max 8    # 自动验证：枚举版面里能点的文本逐个点
lingqu-cli probe  --path . --feature <名> --click-file <按钮文本文件>   # 真机点一下再判定
lingqu-cli migrate --path .                  # 8 步一条命令跑完（分钟级，别当探活用）
lingqu-cli diagnose --log <正文> | --logPath <文件>   # 报错诊断（**文件用 --logPath**）
lingqu-cli notes  --path . --action append --body <json文件>   # 记一条经验（中文必须走文件）
lingqu-cli export --path . --out <目录>      # 导出移植成果（默认 %USERPROFILE%\lingqu-migrated）
```

规则：**先 `resume` 看停在哪步，再跑那一步**；判断"能不能用"只认 `verify` 的落档，
不要拿 `build` 通过就宣称可用。真机装不上先 `sign` 体检再看 `deploy` 的 hilog。

### 中文一律走文件

仓颉在 Windows 上接不到非 ASCII 的 argv（`--click 选择文件` 会直接抛
`Invalid unicode scalar value`）⇒ 任何中文内容都写进 UTF-8 文件再传：
`--click-file` / `--expect-log-file` / `notes --body` / `diagnose --logPath`。

## 2. `devecocli`（HarmonyOS 官方工具集 CLI）

`devecocli`（`@deveco/deveco-cli`）能查平台文档、拉官方 skills、读设备日志。
**先探再用，别一上来 `npm i -g` 覆盖用户环境**：

```bash
"$APPDATA/npm/devecocli.cmd" --version    # 绝对路径探（它不在 cjh 继承来的 PATH 上）
command -v devecocli                      # 有就直接用
```

探不到才装：`npm i -g @deveco/deveco-cli`（装完仍是上面那个绝对路径）。实测 1.0.0 子命令：

| 子命令 | 用途 |
|---|---|
| `device` / `emulator` | 列设备、起模拟器 |
| `log --bundle-name <包名> --keyword <词> --tail 200` | 拉 hilog——**崩溃/白屏先看它** |
| `docs search <词>` / `docs read` / `docs catalog` | 查本地平台文档 |
| `skills list` / `skills find` / `skills add --skill <hmos-*> --path ~/.cjh/skills` | 拉官方 skills（61 个 `hmos-*`） |
| `init --path ~/.cjh/skills --agent` | 把 skills 装成 agent 可用的形态 |
| `create` / `build` / `run` / `serve` / `update` | 建/编/跑工程 |

**它没有 `sign`**：签名走 `lingqu-cli sign --login` + `sign --auto`，别指望它。两条边界：
`skills list` 是**线上拉取**（断网就空）；`docs` 依赖本地 `docs.zip`，缺了先 `update`。
它也没有"点了有没有反应"的判定能力——那件事用 `lingqu-cli probe`（见 `device-probe.md`）。

## 3. 技能空间的预算（装新技能前必须知道）

cjh 把 `~/.cjh/skills/*.md` 的**正文**拼进 system prompt，但**总长度有预算，超出后按目录遍历顺序
静默丢弃**（2026-11-24 实测：13.7 KB 的技能 + 272 B 的探针 → 探针不出现；把探针改名到字母序靠前 → 两者都在；
而 `/api/skills` 对两份都回 `enabled: true`）。

⇒ 本技能因此改成「索引 + `references/` 按需读」：`SKILL.md` 只留必做动作，细节都在 `references/`
（隐藏子目录，**不进提示词**）。新增经验时：**短的进 `SKILL.md` 的判据/索引，长的进 `references/`**，
别把 `SKILL.md` 又写回 10 KB 以上——那会把别人的技能挤出预算（AGENTS §4-214 / cjh issue #16）。
