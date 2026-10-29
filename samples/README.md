# samples/ —— 人工基线与验证证据

这个目录放「**非代码的验证材料**」：人工基线清单（C2 的地基）与关键扫描快照（证据留档）。
都是**入库文件**，换机器/换会话都能复核。

## baselines/ —— 人工基线（`lingqu/baseline/v1`）

基线 = **人工通读样本代码**列出的「该被识别的迁移单元」+ 每条的人工参考结论。
`t2h:scan` 按工程名自动找 `samples/baselines/<工程名>.json` 做双向 diff，算出 **C2 发现置信度**。

| 文件 | 样本 | 项数 | 五类分布 |
|---|---|---|---|
| `habit-tree.json` | `E:\test\rust\habit-tree`（grove 1.1.0，Tauri 2.11.5） | 24 | cmd12 / ev0 / plg0 / fe7 / api5 |

**口径与边界**（完整版见 `docs/P2-scan-口径草案.md` §三之二 A4）：

- 只收五类清单的迁移单元：命令 / 事件 / 插件 / 浏览器能力 / 平台 API 符号（含前端 `@tauri-apps/api` 能力）
- **不收**库依赖（`serde`/`chrono`/`redb`/`base64`/`std::fs`）——那是 P3 依赖维；也不收纯业务逻辑
- **死代码里的能力要收**，结论写 `不适用`（例：habit-tree 的 `FileReader` 出现在一个没被任何元素引用的
  导入处理函数里 → 人工会看到它并给结论；不收的话扫描器"多识别"会被误判为误识别）
- 基线的 `verdict` **只作对照**，不参与 C1/C2 计算

### 新增一个样本的步骤

```bash
# 1) 人工通读样本（先别跑扫描器，避免"照着扫描结果写基线"）
#    路径建议：src-tauri/src/*.rs（命令/平台API/事件）+ Cargo.toml（插件）+ src/**/*.ts|html（浏览器能力）
# 2) 写基线（kind 用扫描器的同名口径）
$EDITOR samples/baselines/<工程名>.json
# 3) 跑扫描看漏识别（工具会自动找到这份基线）
LINGQU_SCAN_PATH=<样本路径> ./scripts/run-dev.sh      # 或界面上点「扫描」
cat .lingqu/scan/<工程名>.json | jq '.confidence'      # C2 / missed / extra / verdictDiff
# 4) 有漏识别 → **补扫描规则**（src/scanner/scan.cj），不是改基线；重跑到漏识别为 0
```

## evidence/ —— 关键快照

| 文件 | 是什么 | 为什么留 |
|---|---|---|
| `habit-tree-scan-before-c2.json` | 0.7.0（补 C2 规则前）的 habit-tree 扫描结果，R=20 | 证明第一轮 C2=83.3% 的**漏识别是从真实 diff 里发现的**，不是编的 |

> 新的快照命名约定：`<工程名>-scan-<里程碑>.json`，并在 `docs/进度记录.md` 里写清它对应哪一轮。
