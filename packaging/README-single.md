# 灵渠迁移台 · 单文件版（Windows）

> 这份包**没有 `assets/` 目录**：页面与能力清单已经编进 `main.exe`（base64，装配期由
> `LingquAssetResolver` 解码）。因此不存在"工作目录不对就加载不到页面"这类问题。

## 怎么跑

双击 `run.bat`（或直接运行 `main.exe`）。首次启动若一闪而过，再点一次（历史现象）。

## 包里有什么

| 路径 | 作用 |
|---|---|
| `main.exe` | 主程序（静态链接：仓颉 std 与 stdx 都在 exe 里）+ **内嵌页面与能力清单** |
| `run.bat` | 设好 `LINGQU_HOME`（包根）与工作目录后启动 |
| 根目录若干 DLL | 只剩省不掉的几个：`libcangjie-runtime`（运行时无静态版）、`libcjtbridge`（C 桥只有 .dll.a）、`libboundscheck`、`WebView2Loader`、`sqlite3` |
| `vendor/cjh/win-x64/` + `SHA256SUMS` | 内置 AI 引擎（右栏 AI 用；`SHA256SUMS` 缺了引擎不会被拉起） |
| `scripts/` | 门禁脚本（可选） |

## AI 面板

`Ctrl+,` 打开设置 →「部署 / 拉起引擎」。它会校验 `vendor/cjh` 四个文件的 SHA256，
再拉起 `cjh web --bind 127.0.0.1`（默认 8765），就绪判据只有一条：`GET /api/health` 200。

引擎发现顺序（找不到时按这个顺序查）：`LINGQU_CJH`（直接指 cjh.exe）→ 应用数据目录里部署过的副本 →
`LINGQU_HOME/vendor` → `LINGQU_CJH_HOME/vendor` → 从当前目录逐级上溯 → 相对路径。
实际用的哪一份会写进 `.lingqu\ui-report.json` 的 `cjhState / cjhBin / cjhVendorDir`。

## 还差什么（如实）

- 本包**不是**"一个文件搞定"：`vendor/cjh` 与几个 DLL 仍在旁边。真正的单文件要把 cjh 作为 PE 资源
  编进 exe、并在运行期释放（框架有 `extractEmbeddedAssets` 支持），且 C 桥需要静态归档——
  这一步还没做，见 `packaging/pack-win-single.sh` 末尾的 TODO。
- 未做代码签名，SmartScreen 可能提示"未知发布者"。
- ⑥ 屏的「功能清单 / 可用率」仍是占位示意，等 P6 的 `t2h:verify`。
