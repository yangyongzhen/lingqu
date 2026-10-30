# 鸿蒙真机签名（HAP 直装）

> 语料来源：2026-10-31 在**鸿蒙 PC `HAD-W32`**（HarmonyOS 7.0.0.111 SP12C00E100R13P5 / API 26）
> 上的端到端实测，含 DevEco 6.1.1.300 + hvigor 6.24.4 + hdc 3.2.0d。每条结论都能在本机复现。
> **结论先讲**：真机直装**不需要打开 DevEco、也不需要重新登录华为账号**——只要机器上还留着
> 当年自动签名生成的素材，并且那份 profile 的 `device-ids` 里有这台设备的 UDID。

## 1. 三条路，先看清差别

| 路径 | 能不能装到 **HarmonyOS**（华为发行版）真机 | 要不要账号 | 要不要 IDE |
|---|---|---|---|
| A. SDK 自带的 **OpenHarmony 默认材料**（`toolchains/lib/OpenHarmony.p12`） | ❌ 实测被拒（见 §2） | 不要 | 不要 |
| **B. 复用 `~/.ohos/config` 里自动签名的 debug 材料** | ✅ 实测 `install bundle successfully` | **不要** | **不要** |
| C. flutter 那套自动化（OAuth 登录 + AGC 建证书/注册设备） | ✅ | 要（一次性授权） | 不要 |

- 路径 A 失败原因：**HarmonyOS 设备只信任华为签发的证书链**；OpenHarmony 默认材料是自签的，直装报
  `9568322 not trusted app source`。所以"SDK 里有 p12 就能签"是错觉。
- 路径 C 的做法（[flutter_flutter e2793de](https://gitcode.com/oh-flutter/flutter_flutter/commit/e2793de97e8744b5f675da52d72e7076420bca3c)）：
  `material: DevEco-identical file naming + hap-sign-tool P12/CSR`、`auth: OAuth loopback login`、
  `cloud/device/profile: AGC APIs + hdc 设备注册`、`keymanager: DevEco DecipherUtil-compatible 口令加密`，
  在 `assembleHap` 前把 `signingConfigs` 写进 `build-profile.json5`。
  **它省掉的是 IDE，不是账号**——适合"干净机器 + 有账号"的流水线。
- 路径 B 是本项目推荐的：**连账号都省**，适用于"这台机器以前用 DevEco 自动签名装过应用"的情况。

## 2. 路径 A 为什么不行（实测原文，别再试）

```text
$ hdc -t <serial> install -r entry-default-signed.hap
[Info]App install path:…\entry-default-signed.hap msg:error: failed to install bundle.
 code:9568322 error: signature verification failed due to not trusted app source.
AppMod finish
```

注意两点：
1. `hvigor` 在 `signingConfigs` 为空时**仍会产出 `entry-default-signed.hap`**（用 SDK 的
   OpenHarmony 默认材料）——所以"有 signed 文件"不等于"能装"。判断签名态要看**装得进去**。
2. **`hdc install` 失败时退出码仍是 0**，只能按输出文本判（`install bundle successfully`）。

## 3. 路径 B：复用本机自动签名材料（推荐）

### 3.1 材料长什么样

DevEco 的「Automatically generate signature」把材料放在 **`%USERPROFILE%\.ohos\config\`**
（Linux/macOS：`~/.ohos/config/`），每个工程一组、文件名带工程名与哈希：

```text
default_<工程名>_<hash>.p12   # 密钥库（keyAlias 通常是 debugKey）
default_<工程名>_<hash>.cer   # 证书（华为签发）
default_<工程名>_<hash>.csr   # 证书签名请求（生成过程残留）
default_<工程名>_<hash>.p7b   # profile（PKCS#7，内含 JSON：type / bundle-name / device-ids）
```

`.p7b` 是 DER 包着的 JSON，**可直接按字节 grep**（不需要解析 ASN.1）：

```powershell
$raw=[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes("$env:USERPROFILE\.ohos\config\xxx.p7b"))
if ($raw -match '"device-ids"\s*:\s*\[([^\]]*)\]') { $matches[1] }   # 看里面有哪些设备
if ($raw -match '"bundle-name"\s*:\s*"([^"]+)"')   { $matches[1] }   # 这个 profile 绑的是哪个包名
```

### 3.2 判定能不能直接用

```powershell
# 1) 取本机设备 UDID
D:\oh\DevEcoStudio\sdk\default\openharmony\toolchains\hdc.exe shell bm get --udid
#   → udid of current device is : B8861DAE97…6385

# 2) 在 .p7b 里找这个 UDID（同时要确认 bundle-name 与你要装的包一致）
```

两个都对上 → 这套材料可以直接签，**不用登录**。对不上（换了设备）→ 只能走路径 C 或在 DevEco 里
重新"自动签名"一次（那一步要账号，把新设备注册进 profile）。

> **省事版**：灵渠迁移台把这一节整个做成了命令 —— `t2h:sign`（置 `LINGQU_SIGN_PATH=<工程>` 起 GUI，
> 或点 ⑤ 屏「签名体检」）。它做四件事并落档 `.lingqu/sign/<工程>.{json,log}`：取 UDID → 解析工程
> `build-profile.json5` 的 `signingConfigs` → 扫 `~/.ohos/config` 全部 `.p7b`（优先挑包名也对得上的）→
> 给「装得上吗 + 要动什么」。**纯离线、免账号**。判定实现见 `src/compiler/sign.cj`。
>
> 连下面"把 signingConfigs 抄回工程"这一步也自动化了：**apply 模式**（点 ⑤ 屏「写回签名配置」，
> 或置 `LINGQU_SIGN_APPLY=1`）会找一个**用同一套材料**的 donor 工程（`LINGQU_SIGN_DONOR=<已有工程>`，
> 否则扫 `~/DevEcoStudioProjects`、`~/Documents`、`~/Desktop`），把它的 `signingConfigs` 原样搬进
> `build-profile.json5`——**含 DevEco 加密口令**（那是 AesGcmKit 密文，我们造不出来，只能搬），
> 改前自动备份 `.lingqu/sign/<工程>.build-profile.json5.bak`，写完立刻重判。机制细节（为什么口令只能搬）
> 见 `docs/鸿蒙自动签名机制.md` §3.7。

### 3.3 配方（全程命令行，6 步）

```powershell
$deveco = 'D:\oh\DevEcoStudio'
$sdk    = "$deveco\sdk\default\openharmony"

# ① 把 signingConfigs 写进 HAP 工程的 build-profile.json5
#    （<工程>\src-tauri\gen\ohos\build-profile.json5）
#    字段形状（值来自你机器上那一套材料；口令保持 DevEco 加密串原样）：
#      "signingConfigs": [{ "name":"default", "type":"HarmonyOS",
#        "material": { "certpath": "...\.cer", "profile": "...\.p7b", "storeFile": "...\.p12",
#                      "keyAlias": "debugKey", "signAlg": "SHA256withECDSA",
#                      "storePassword": "0000001A…", "keyPassword": "0000001A…" }}]
#    并在 products[0].signingConfig 指到 "default"
#    ⚠️ 口令不用自己解密——**hvigor 会用 DevEco 的机制解密**（这也是为什么它必须是那种 0000001A… 形态）
#    历史工程的 build-profile.json5 里通常就有这份配置：git log 里翻一下直接抄

# ② 装配前补依赖（只第一次；缺 oh_modules 时 ArkTS 会报 Cannot find module '@ohos-rs/ability'）
& "$deveco\tools\ohpm\bin\ohpm.bat" install --all   # cwd = <工程>\src-tauri\gen\ohos

# ③ 装配（cwd 同上；hvigor 会调用 cargo 编 .so 再打包签名）
$env:DEVECO_HOME=$deveco
$env:DEVECO_SDK_HOME="$deveco\sdk"
$env:OHOS_HOME="$deveco\sdk\default\openharmony"
& "$deveco\tools\node\node.exe" "$deveco\tools\hvigor\bin\hvigorw.js" `
    --mode module -p product=default assembleHap --no-daemon
#   期望：`Finished :entry:default@SignHap` + `BUILD SUCCESSFUL`
#   产物：<工程>\src-tauri\gen\ohos\entry\build\default\outputs\default\entry-default-signed.hap

# ④ 装
& "$sdk\toolchains\hdc.exe" -t <serial> install -r <上述 signed.hap>
#   期望输出里出现 `install bundle successfully`（**别看退出码**）

# ⑤ 启动
& "$sdk\toolchains\hdc.exe" shell aa start -a EntryAbility -b <bundleName>
#   期望 `start ability successfully`

# ⑥ 验状态（证明真在前台，而不是"命令返回了就完事"）
& "$sdk\toolchains\hdc.exe" shell aa dump -a
#   找 `bundle name [<你的包>]` 且 `state #FOREGROUND` / `AbilityRecord … state #ACTIVE`
```

## 4. 失败码对照（都实测过）

| 码 | 含义 | 处置 |
|---|---|---|
| **9568322** | `signature verification failed due to not trusted app source`——装的不是设备信任的证书，或 profile 没有本机 UDID | 换**绑定本机 UDID 的 debug profile**（§3）；release/上架 profile 直装必失败 |
| **9568269** | `install file path invalid`——hdc 发文件保留了源目录结构 | 先 `cd` 到 HAP 所在目录再 `file send` 文件名；或直接 `hdc install -r <绝对路径>` |
| **10106102** | `aa start` 被拒：设备在锁屏 | 解锁后重试；自动化流程要留等待点 |

## 5. 什么时候**必须**要账号（别误判）

- 机器上**没有**任何 `~/.ohos/config/*.p7b`（换机器、重装系统、清过用户目录）→ 路径 B 不可用；
- 有材料但**profile 的 device-ids 里没有当前设备**（换了 / 新增了设备）→ 需要重新注册设备；
- 这两种情况才需要：DevEco 里点一次「自动签名」（账号登录），或走路径 C 的 OAuth+AGC 流程。

> 实测反例（值得记住）：某台机器重装 DevEco 6.1.1 后一度以为"debug 签名材料丢了"，
> 实际是**材料还在 `~/.ohos/config`、只是工程的 `build-profile.json5` 被重置成空 `signingConfigs`**。
> 先把配置抄回去再判断，不要先怀疑材料。

## 6. 验证纪律（别只看"命令成功"）

1. `hdc install` 的输出文本里有 `install bundle successfully`（**不是退出码**）；
2. `aa start` 输出 `start ability successfully`，且 `aa dump -a` 里该包 `state #FOREGROUND`；
3. `ps -ef | grep <包名>` 能看到进程（PID 会变，别把它当断言）；
4. 截图存证：`hdc shell snapshot_display -f /data/local/tmp/x.jpeg` + `hdc file recv …`；
5. 崩溃面：`ls /data/log/faultlog/faultlogger/`（空 = 没崩）；ArkWeb 白屏时先看 hilog 与 `panic.log`。
6. **渲染要看人眼**：结构/进程/状态都能自动断言，但"界面真的画出来了"目前只能靠截图人工确认
   （`arkweb_render` 子进程**不一定存在**，别拿它当"没渲染"的判据）。
