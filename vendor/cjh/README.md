# vendor/cjh —— 内置 AI 引擎

灵渠的 AI 能力全部来自 [cjh](https://atomgit.com/qq8864/cjh)（仓颉实现的 Coding Agent Harness）。
这里放一份**可直接运行的 cjh 产物**，让仓库开箱即用，不必先让使用者自己去下载编译。

## 版本

- cjh 版本：v1.5.3（Windows x64）
- 形态：**非单文件**——`cjh.exe` + 3 个同目录 DLL（缺一个的典型症状：
  `TlsException: Can not load openssl library or function`，即「窗口照起、http 照通、只有 https 全灭」）

| 文件 | 大小 | 作用 |
|---|---|---|
| `cjh.exe` | 13.4 MB | 引擎本体，`cjh web --port 8765 --bind 127.0.0.1` |
| `libcangjie-runtime.dll` | 1.2 MB | 仓颉运行时 |
| `libssl-3-x64.dll` | 1.2 MB | TLS（cjh 按名字 dlopen，**必须与 exe 同目录**） |
| `libcrypto-3-x64.dll` | 6.3 MB | 同上 |

## 校验

```powershell
cd vendor/cjh
Get-FileHash win-x64/cjh.exe -Algorithm SHA256
# 与 SHA256SUMS 里那一行逐字比对
```

应用侧不会静默使用来路不明的二进制：`t2h:env` 会把它作为一项体检项报出来（就绪 / 缺失）。

## 更新这份产物

```powershell
# 从 cjh 的构建输出目录重新灌入，并重算 SHA256SUMS
.\tools\vendor-cjh.ps1 -Source <cjh 产物目录>
```

`<cjh 产物目录>` 里需要有 `cjh.exe`、`libcangjie-runtime.dll`、`libssl-3-x64.dll`、`libcrypto-3-x64.dll`。

## 路径解析顺序（见 `src/main.cj` 的 `cjhPath()`）

1. `LINGQU_CJH` 环境变量
2. `vendor/cjh/win-x64/cjh.exe`（工作目录 = 工程根）
3. `../vendor/cjh/win-x64/cjh.exe`（工作目录 = `targets/desktop`）
4. 开发期兜底的本机路径

全都没有时，应用如实报「引擎缺失」，其余功能照常可用（手动模式）。

## 为什么不直接内嵌进单个 exe

框架 `docs/单文件包内嵌 cjh 方案.md` 给了结论：能，但形态是「一个 exe + 首次运行释放几个文件」——
卡点不在 cjh 代码，而在仓颉运行时的 TLS 加载器**按名字 dlopen openssl**，静态链接吃不掉。
那属于打包阶段（P2）的工作，骨架阶段先用目录式随包，最稳。
