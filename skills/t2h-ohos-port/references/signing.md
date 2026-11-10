# 鸿蒙真机签名（HAP 直装）

> 语料来源：2026-10-31 在**鸿蒙 PC `HAD-W32`**（HarmonyOS 7.0.0.111 SP12C00E100R13P5 / API 26）
> 上的端到端实测，含 DevEco 6.1.1.300 + hvigor 6.24.4 + hdc 3.2.0d。
> **2026-11-02 追加**：在鸿蒙 PC `3QC0124B20000048` 上把**路径 C 全自动化**跑通了
> （`m3u8dl-tauri` → `signed=true` + `install bundle successfully`），本篇据此更正了两处旧结论。
> 每个结论都能在本机复现；完整复盘见 `docs/自动签名实战复盘.md`。
>
> **结论先讲**：真机直装**不需要打开 DevEco、也不需要每次登录华为账号**——
> ① 机器上还留着当年自动签名素材时，直接复用（路径 B，连账号都省）；
> ② 没有素材 / 换了包名 / 换了设备时，用 `t2h:sign --auto` 让**云侧现签**（路径 C，一次授权即可）。

## 1. 四条路，先看清差别

| 路径 | 能不能装到 **HarmonyOS**（华为发行版）真机 | 要不要账号 | 要不要 IDE |
|---|---|---|---|
| A. SDK 自带的 **OpenHarmony 默认材料**（`toolchains/lib/OpenHarmony.p12`） | ❌ 实测被拒（见 §2） | 不要 | 不要 |
| **B. 复用 `~/.ohos/config` 里自动签名的 debug 材料** | ✅ 实测 `install bundle successfully` | **不要** | **不要** |
| **C. 本项目 `t2h:sign --auto`（OAuth 登录 + AGC 建证书/注册设备/签 profile）** | ✅ **实测 `signed=true` + 装机成功（2026-11-02）** | 要（**一次性**授权，令牌留本机） | **不要** |
| D. DevEco 里手点「Automatically generate signature」 | ✅ | 要 | 要 |

- 路径 A 失败原因：**HarmonyOS 设备只信任华为签发的证书链**；OpenHarmony 默认材料是自签的，直装报
  `9568322 not trusted app source`。所以"SDK 里有 p12 就能签"是错觉。
- 路径 C 的做法（参照 [flutter_flutter e2793de](https://gitcode.com/oh-flutter/flutter_flutter/commit/e2793de97e8744b5f675da52d72e7076420bca3c)）：
  `material: DevEco-identical file naming + hap-sign-tool P12/CSR`、`auth: OAuth loopback login`、
  `cloud/device/profile: AGC APIs + hdc 设备注册`、`keymanager: DevEco DecipherUtil-compatible 口令加密`，
  在 `assembleHap` 前把 `signingConfigs` 写进 `build-profile.json5`。
- 路径 B 与 C 的选择：**有材料可用就 B（最省），否则 C**。`t2h:sign --path <工程>`（离线体检）
  会告诉你当前属于哪种。

> ⚠️ **更正旧结论**：本文件早期写过"口令是 AesGcmKit 密文，**我们造不出来，只能搬**"。
> 2026-11-02 已否掉——纯仓颉实现 AES-128-GCM + AesGcmKit 的 workKey 推导后，
> **我们自己造的密文 hvigor 解得开**（把 habit-tree 的密文整段替换成我们造的 → `Finished :default@SignHap`
> + `BUILD SUCCESSFUL`）。配方见 `docs/自动签名实战复盘.md` §2.4。
> 所以路径 C 不必依赖"别处现成的密文"。

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
> `build-profile.json5`——含口令密文，改前自动备份 `.lingqu/sign/<工程>.build-profile.json5.bak`，
> 写完立刻重判。机制细节见 `docs/鸿蒙自动签名机制.md` §3.7。
> （apply 模式仍是"搬"；要**自己造**密文就给 p12 一份自己掌的口令，见 §3.4 与复盘 §2.4。）

## 3.4 路径 C：`t2h:sign --auto`（没有可用材料时）

```bash
lingqu-cli sign --tool-check                  # 先确认 java / hap-sign-tool.jar / hdc 都在
lingqu-cli sign --login                       # 唯一的人工介入：浏览器点一次授权
lingqu-cli sign --path <工程>                  # 离线体检：本机材料能不能装这台设备
lingqu-cli sign --auto --path <工程>           # 复用本机材料，跑完整的 AGC 链
lingqu-cli sign --auto --newKeys --path <工程> # 材料来路不明/口令丢了时用（旧材料改名留底）
lingqu-cli hap    --path <工程>                # 期望 signed=true
lingqu-cli deploy --path <工程> --start        # 期望 installed=true / started=true
```

它做的十件事（每件失败都会指到步骤号）：

```text
① 令牌（~/.lingqu/agc/，AES-128-GCM 落盘）→ ② 团队 → ③ 设备（已注册跳过）
④ 材料命名（DevEco 同名规则）= 本地 p12/CSR（hap-sign-tool，随机口令不进日志）
⑤ 证书（**按有效期**挑可用；没有就新建；配额满则删自己的过期件腾位）
⑥ 按**工程自己的 bundleName** 申请 debug profile（deviceList 放**云端设备 id**）
⑦ 用 ~/.ohos/config/material 的 workKey 加密口令 → 写回 build-profile.json5（先 .bak）
```

**四条硬判据**（错在这儿会报很远的错误）：

1. 证书可用性看 `expireTime`/`status`，**不看名字**（同名旧证书可能早过期）。
2. profile 的 `device-ids` 必须含本机 UDID，`bundle-name` 必须等于工程 `AppScope/app.json5` 的 `bundleName`。
3. 换密钥对后**不能**复用云端同名证书（它绑旧公钥）→ 删旧建新 + 重下本地 `.cer`。
4. 密文能不能沿用，判据是 `sign --reencrypt` 能不能解开；`GCM tag mismatch` = 必须换材料。

完整复盘（六个坎的现象/根因/处置）见 `docs/自动签名实战复盘.md` §3。

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
| **9568322** | `signature verification failed due to not trusted app source`——三种成因：①签的是 release/上架 profile（不含 device-ids）；②debug 材料里没有本机 UDID；③**签 HAP 用的证书 ≠ profile 里绑的证书** | ①②换**绑定本机 UDID 的 debug profile**（§3）；③见下条 `11111002`——证书以**云端为准**，本地 `.cer` 只是一份缓存，`sign --auto` 会自检并重下 |
| **9568320** | `no signature file`——压根没签上（HAP 里没有签名块） | 先 `sign --auto` 备好材料再 `hvigor assembleHap` 装配；**别去查设备**（这不是装机问题） |
| **9568332** | `install sign info inconsistent`——同包名已装过**另一套签名**的版本（换材料后必然如此） | `bm uninstall -n <bundle>` 后重装（`t2h:deploy` 会自动做一次） |
| **9568269** | `install file path invalid`——hdc 发文件保留了源目录结构 | 先 `cd` 到 HAP 所在目录再 `file send` 文件名；或直接 `hdc install -r <绝对路径>` |
| **10106102** | `aa start` 被拒：设备在锁屏（开发者模式禁止自动解锁） | 解锁后重试；自动化流程要留等待点。**与 ability/bundle 名无关**，别去改名字 |

hvigor 侧（`assembleHap` 失败时）：

| 码 | 含义 | 处置 |
|---|---|---|
| **00308018** | `Unknown Error`——真 trace 不在这一行，往日志深处找：`cargo tauri ohos dev-eco-studio-script` → `thread 'main' panicked: failed to read missing addr file %TEMP%\<包名>-server-addr` → tauri-cli 自己 panic | `gen/ohos/entry/hvigorfile.ts` 里那条 `afterRun(buildRustCode)` 钩子只给 `tauri ohos dev`（有 dev server）准备；非 dev 场景必失败 → 注掉它（规则 `R2-PORT-015` 自动注，带 `.bak`），**重新生成过 `gen/ohos` 就要重跑 `port --path . --apply`**。与签名、源码都无关，别去反复试签名（§4-114 / §4-153） |
| **00303074** | `bundleName in app.json5 … does not match the bundleName in the generated SigningConfigs` | profile 是按包名签发的 → 给**这个**包名签一份（`sign --auto`） |
| **00303242** | `Signature material verification failed, as: Unsupported state or unable to authenticate data` | 口令密文解不开（`material/` 换了 / 口令丢了）→ `sign --auto --newKeys` |
| **00303107** | `Invalid storeFile` | 材料文件缺失（路径错或文件被删） |

AGC 侧（`ret.code`）：

| 码 | 含义 | 处置 |
|---|---|---|
| **205389848** | `certList is invalid` | 证书已过期或类型不符 → 按有效期挑、给 debug profile 用 debug 证书 |
| **205389872** | `certificate number exceeds limit` | 证书配额满（过期件占位）→ 删自己的过期件后重试 |
| **205389858** | `UDID is repeat` | 该 UDID 已注册 → **视为已注册**，不是错误 |
| **205389857** | 设备名重复 | 换一个 `deviceName`（带随机 nonce）重试 |

## 5. 什么时候**必须**要账号（别误判）

- 机器上**没有**任何 `~/.ohos/config/*.p7b`（换机器、重装系统、清过用户目录）→ 路径 B 不可用；
- 有材料但**profile 的 device-ids 里没有当前设备**（换了 / 新增了设备）→ 需要重新注册设备；
- 有材料但**profile 的 `bundle-name` 不是要装的包名**（新包名 / tauri 的 `com.atomgit.*` 一类）→
  需要为这个包名现签一份；
- 以上三种情况 → 走**路径 C**（`t2h:sign --auto`，一次授权即可，之后不需要再登录），
  或 DevEco 里点一次「自动签名」。

> 实测反例（值得记住）：某台机器重装 DevEco 6.1.1 后一度以为"debug 签名材料丢了"，
> 实际是**材料还在 `~/.ohos/config`、只是工程的 `build-profile.json5` 被重置成空 `signingConfigs`**。
> 先把配置抄回去再判断，不要先怀疑材料。

## 5.1 三条"看着成功其实没用"的假象

1. `hvigor assembleHap` 在 `signingConfigs` 为空时**也会产出 `entry-default-signed.hap`**
   （用 SDK 自带的 OpenHarmony 材料）——有 signed 文件 ≠ 能装。
2. `cert/list` 里有同名证书 ≠ 能用（可能已过期）；`provision add` 返回 200 ≠ 成功
   （要看 `ret.code == 0`）。
3. `hdc install` 退出码 0 ≠ 装上了（只能按输出文本判）。

## 6. 验证纪律（别只看"命令成功"）

1. `hdc install` 的输出文本里有 `install bundle successfully`（**不是退出码**）；
2. `aa start` 输出 `start ability successfully`，且 `aa dump -a` 里该包 `state #FOREGROUND`；
3. `ps -ef | grep <包名>` 能看到进程（PID 会变，别把它当断言）；
4. 截图存证：`hdc shell snapshot_display -f /data/local/tmp/x.jpeg` + `hdc file recv …`；
5. 崩溃面：`ls /data/log/faultlog/faultlogger/`（空 = 没崩）；ArkWeb 白屏时先看 hilog 与 `panic.log`。
6. **渲染要看人眼**：结构/进程/状态都能自动断言，但"界面真的画出来了"目前只能靠截图人工确认
   （`arkweb_render` 子进程**不一定存在**，别拿它当"没渲染"的判据）。

---

## 7. 最常见的**一次性卡点**：本机有含本机 UDID 的材料，但**包名对不上**

现场实测（rust-music-3，2026-11-08）：

| 事实 | 值 |
|---|---|
| 工程包名 | `com.example.rustmusic`（`AppScope/app.json5`） |
| 本机 UDID | `667BA4F7…` |
| 候选材料 | 7 套；其中 **3 套含本机 UDID**：`com.yang.testcj`(27 台)、`com.atomgit.m3u8dl_tauri`(6 台)、`com.jiujiang.habit_tree`(26 台) |
| **`com.example.rustmusic` 的材料** | 5 台，**不含本机** ⇒ `device-ids` 没过 ⇒ 装不上 |
| 工具判定 | `check.ok=false`、`apply` 拒绝写回（包名不一致）、`mode.canInstallDevice=false` |

**关键认知：profile（`.p7b`）是按 bundleName 签发的**，别的包名的材料哪怕含本机也**不能**给这个包名用
（`hvigor` 会以 `00303074` 直接拦）。所以"有含本机 UDID 的材料"不等于"能装"。

### 两条出路（第一条是正路）

1. **网页登录一次自动签**（推荐，一次人工）：
   ```bash
   lingqu-cli sign --login          # 打开浏览器登录 AGC，本机回环回调收码，令牌落 ~/.lingqu/agc/token.enc
   lingqu-cli sign --auto --path <工程>   # 建证书 → 申请 profile（含本机 UDID）→ 写回 signingConfigs
   ```
   然后重跑 `t2h:hap`（或 `lingqu-cli hap`）出 **signed** HAP，再 `deploy`。
   **别去 DevEco 手点**——那是旧路，多一道人工，还与"单应用人工介入 ≤5"的验收指标对抗。
2. **临时改包名做本机验证**（不用于交付）：把 `AppScope/app.json5` 的 `bundleName` 改成
   `com.atomgit.m3u8dl_tauri` 之类"本机已有含 UDID 材料"的包名，装起来跑 A4 可用率。

### 登录这一步的常见坑（全部实测过）

- `sign --auto` 在没登录时报 **`拉团队列表失败（token 可能已失效，重跑 sign --login）`**；
  **令牌约 4 小时过期**，过期就重跑 `--login`。
- CLI 的登录**只把链接打到 stdout**（重定向即 0 字节），agent 跑它时人看不到链接；
  让 agent 走 `lingqu-decision` 把链接交出来，或用应用签名屏的「登录」按钮（走 `t2h:open_url`）。
- WebView 里的 `<a target="_blank">` **不保证**能唤起系统浏览器 —— 给按钮，别给裸链接。
- 登录成功后 `token.enc` 的 mtime 就是证据（`uid` / 团队数在登录输出里）。
