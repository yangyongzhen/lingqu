# vendor/cjh —— 内置 AI 引擎

灵渠的 AI 能力全部来自 [cjh](https://atomgit.com/qq8864/cjh)（仓颉实现的 Coding Agent Harness）。
这里放一份**可直接运行的 cjh 产物**，让仓库开箱即用，不必先让使用者自己去下载编译。

## 版本与形态（两个平台）

| 平台 | 目录 | 产物形态 | 说明 |
|---|---|---|---|
| Windows x64 | `win-x64/` | `cjh.exe` + 4 个同目录 DLL | cjh 版本 **v1.6.18**（`dist/cjh-v1.6.18-windows-x64-selfcontained.zip`），实测 `--version` → `cjh v1.6.18` |
| Linux x64 | `linux-x64/` | 单个 `cjh` | 静态链接，**没有随行 DLL**（形态与 Windows 不同，这是 cjh 官方分发形态决定的）；v1.6.18，`--version` 实测 `cjh v1.6.18` |

Windows 那四个 DLL 是**按名字 `dlopen`/`LoadLibrary` 加载**的，不在导入表里，缺一个的症状很隐蔽：

```
TlsException: Can not load openssl library or function …
```

也就是「窗口照起、`http://` 照通，**只有 https（LLM 调用）全灭**」。
所以 `.gitignore` 里对它们做了例外（模板的 `*.dll` 规则会把它们一起忽略）。

| 文件 | 大小 | 作用 |
|---|---|---|
| `cjh.exe` | 13.7 MB | 引擎本体，`cjh web --port 8765 --bind 127.0.0.1` |
| `libboundscheck.dll` | 44 KB | 边界检查运行时（1.6.5 起随行，1.6.12 未变） |
| `libcangjie-runtime.dll` | 1.2 MB | 仓颉运行时 |
| `libssl-3-x64.dll` | 1.2 MB | TLS（按名字加载，必须与 exe 同目录） |
| `libcrypto-3-x64.dll` | 6.3 MB | 同上 |

## 校验

应用侧**不会**静默使用来路不明的二进制：`src/cjh_host.cj` 内置了每个文件的 SHA256 常量，
启动/部署时逐个比对，**验不过就绝不解包也不执行**（这份二进制能跑 shell、能读写工作区，
必须防同名替换）。`t2h:env` 也会把它作为一项体检项报出来。

手工核对：

```bash
# Linux / Git Bash
sha256sum -c <(cat vendor/cjh/SHA256SUMS | sed 's| win-x64/| vendor/cjh/win-x64/|;s| linux-x64/| vendor/cjh/linux-x64/|')
```

## 更新这份产物

```bash
# Windows 产物（exe + 4 DLL）：直接喂 cjh 仓 dist/ 下的官方发布包即可
./tools/vendor-cjh.sh --source <cjh>/dist/cjh-v1.6.18-windows-x64-selfcontained.zip --platform win-x64

# Linux 产物（单个 cjh）
./tools/vendor-cjh.sh --source <cjh>/dist/cjh-v1.6.18-linux-x64.tar.gz --platform linux-x64
```

`--source` 收**目录或归档**（`.zip` / `.tar.gz`）；归档里的 `cjh-windows-x64.exe` / `cjh-linux-x64`
会自动改名成 `cjh.exe` / `cjh`，不必手工解包改名。

灌入后**必须同步 `src/cjh_host.cj` 里的 SHA256 常量**（Windows 5 个、Linux 1 个），
否则启动时会报「vendor SHA256 不符」。这是设计如此。

## 路径解析顺序（见 `src/cjh_host.cj` 的 `cjhBinPath()`）

1. `LINGQU_CJH` 环境变量
2. 已部署目录（Windows `%LOCALAPPDATA%\lingqu\cjh`；Linux `$HOME/.local/share/lingqu/cjh`）
3. 仓内 `vendor/cjh/<平台>/`（**要过 SHA256**）
4. 全都没有 → 如实报「引擎缺失」，AI 面板不可用但其余功能照常（手动模式）

## 为什么不直接内嵌进单个 exe

框架 `docs/单文件包内嵌 cjh 方案.md` 给了结论：能，但形态是「一个 exe + 首次运行释放几个文件」——
卡点不在 cjh 代码，而在仓颉运行时的 TLS 加载器**按名字 dlopen openssl**，静态链接吃不掉。
那属于打包阶段（P2）的工作，骨架阶段先用目录式随包，最稳。
