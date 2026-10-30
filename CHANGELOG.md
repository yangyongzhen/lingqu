# 更新日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的结构，
版本号三处一致：`cjpm.toml` / `cj-tauri.toml` / 本文件最新条目（见 `AGENTS.md` §6）。

---

## [0.17.0] - 2026-10-31

**主题**：**T5-5 真机首验**（鸿蒙 PC `HAD-W32` / HarmonyOS 7.0.0.111 / API 26）：
`hdc install` + `aa start` 跑通，**签名不需要在 DevEco 里登录**。
同时落地 hdc 输出的纯函数解析层（`src/compiler/deploy.cj`）+ 6 例基于真实输出的单测。

### Added

- **`src/compiler/deploy.cj`**（`lingqu.compiler` 续）：hdc 输出的纯函数层
  - `parseHdcTargets`：解析 `hdc list targets`，**挡掉 `COM1 UART Ready` 这类串口噪声**
    （踩过"把 COM 口当设备"的幽灵设备坑），保留 USB 与 TCP（无线调试）目标
  - `parseInstallResult` / `parseStartResult`：按**文本**判定成败 —— 实测 **hdc 失败时退出码仍是 0**，
    只能靠 `install bundle successfully` / `start ability successfully` 判
  - `hdcFailCodeOf` / `hdcFailHintOf`：9568322（签名不可信）/ 9568269（安装路径）/ 10106102（锁屏）
    → 可执行处置，与 `diagnose.cj` 的 FP-012/013/014 同源
  - `hilogTail` / `hilogLooksHealthy`：日志尾部 + panic/SIGABRT/FATAL 健康判断
- **6 例新单测**（总 120），fixture 全部是 **2026-10-31 真机原始输出**
- 真机截图入库：`samples/evidence/habit-tree-ohos-device.jpeg`（3120×2080，170 KB）

### 签名调研结论（用户提出的问题，已实测验证）

| 做法 | 结果 |
|---|---|
| 用 SDK 自带的 **OpenHarmony 默认材料**签名（`sdk/default/openharmony/toolchains/lib/OpenHarmony.p12`） | ❌ `hdc install` 被拒：`code:9568322 signature verification failed due to not trusted app source` |
| 用 `~/.ohos/config` 里 **DevEco 自动签名的 debug 材料** | ✅ **`install bundle successfully`** |

关键发现：**`~/.ohos/config` 里那套材料还在，且 profile 的 `device-ids` 已包含本机 UDID**
（`B8861DAE97…6385`）。口令是 DevEco 加密串，但 **hvigor 自己会解密** ——
所以把历史里那份 `signingConfigs` 写回 `build-profile.json5`，`hvigor assembleHap` 就能签出可装 HAP，
**全程不需要打开 DevEco、也不需要重新登录**。

参考的 [flutter 提交](https://gitcode.com/oh-flutter/flutter_flutter/commit/e2793de97e8744b5f675da52d72e7076420bca3c)
是同一件事的自动化版（`DevEco-identical file naming + hap-sign-tool P12/CSR`、`OAuth loopback login`、
`AGC APIs + hdc 设备注册`）——**它省掉的是 IDE，不是账号**；本次发现的是更省的一条：
**复用机器上已有的签名材料，连账号都不需要**。

### Docs（签名知识沉淀，本轮的第二个交付物）

- **新增 `skills/t2h-ohos-port/references/signing.md`** —— 鸿蒙真机签名完整参考（本项目最有复用价值的一段）：
  - 三条路径对比：SDK 自带 OpenHarmony 默认材料（❌ 9568322）/ **复用 `~/.ohos/config` 自动签名材料（✅ 免账号免 IDE）**/
    flutter 式 OAuth+AGC（✅ 但要账号）
  - 材料结构说明（`default_<工程>_<hash>.{p12,cer,csr,p7b}`）+ **直接 grep `.p7b` 判 device-ids**（不需要解析 ASN.1）
  - **6 步配方**（抄 signingConfigs → ohpm install → hvigor assembleHap → hdc install → aa start → aa dump 验状态）
  - 失败码表（9568322 / 9568269 / 10106102）+ "什么时候才真需要账号"
  - 验证纪律（**别只看命令成功**：按文本判、状态里看 FOREGROUND、截图存证、崩溃目录、渲染要人眼）
- **`skills/t2h-ohos-port/SKILL.md`**：第 7 步（装配 HAP + 签名）改写为指向 signing.md，并把
  "真机调试必须切 debug 签名"补成"多数情况不需要登录账号"；references 表新增一行
- **`skills/t2h-ohos-port/references/pitfalls.md`**：9568322 那条补一句交叉链接
- **`docs/开发环境.md`**：原来那句"首次要在 DevEco 里自动签名（**需登录华为账号**）"**已过时**，
  改写为"先查 `~/.ohos/config` 的 p7b 有没有你的 UDID——有就免登录复用"
- **`AGENTS.md` §4** 新增两条坑（#39 真机签名 / #40 hdc 失败退出码仍为 0）
### 验证证据（真机，2026-10-31）

| 步骤 | 命令 | 结果 |
|---|---|---|
| 设备识别 | `hdc list targets` | `3QC0124B20000048`（HAD-W32，API 26，HarmonyOS 7.0.0.111） |
| 安装 | `hdc -t <sn> install -r entry-default-signed.hap` | **`install bundle successfully`** |
| 启动 | `hdc shell aa start -a EntryAbility -b com.jiujiang.habit_tree` | **`start ability successfully`** |
| 状态 | `hdc shell aa dump -a` | `Mission ID #77 … state #FOREGROUND`、`AbilityRecord #160 state #ACTIVE` |
| 视觉 | `snapshot_display` + `hdc file recv` | 3120×2080 jpeg，170 KB（已入库） |
| 崩溃 | `ls /data/log/faultlog/faultlogger/` | 空（无崩溃记录） |

**未做（如实标注）**：`t2h:deploy` 命令（安装/启动/取日志）与 ⑥ 真机验证屏**尚未接线**——
本轮只做手工链路验证 + 纯函数解析层；T5-4 签名两态（release/企业证书）仍未做。
另：ArkWeb 渲染子进程未观察到，**界面是否完整渲染需人眼看截图确认**（我无视觉能力）。

---

## [0.16.0] - 2026-10-30

**主题**：**P5 第三刀 —— T5-3 HAP 装配**：`t2h:hap` 上线，用 DevEco 自带的 node + hvigor
打 `assembleHap`，并对产物做**死资源校验**（`rawfile/` 必须为空——前端已编进 `.so`）。
P5 的"从源码到可安装 HAP"这条链**已闭合**，只差真机部署（T5-5）。

### Added

- **`src/compiler/hap.cj`**（`lingqu.compiler` 续）：
  - `parseHvigorOutput`：解析 hvigor 输出（`BUILD SUCCESSFUL` / `BUILD FAILED` 冲突时以 FAILED 为准、
    错误行计数与首条错误、产物名提取）；`stripAnsi` 先剥 ANSI，否则 `startsWith("ERROR")` 失配
  - `scanHapEntries`：**字节级**扫 HAP（zip 条目名明文存放，不用解压）→ `module.json` /
    `libs/arm64-v8a/*.so` / `rawfile/` 条目；非 ASCII 字节置换后再扫，1.4 MB 也是 O(n)
- **命令 `t2h:hap`**（三处联动齐全）：
  - 前置检查（脚手架 `gen/ohos/build-profile.json5`、DevEco 位置、node/hvigorw、SDK 目录）逐条给可执行提示
  - **自动补 `ohpm install --all`**（缺 `oh_modules` 时；`autoInstall=false` 可关）——
    否则 ArkTS 报 `Cannot find module '@ohos-rs/ability'`
  - 跑 `node <devEco>/tools/node/node.exe <devEco>/tools/hvigor/bin/hvigorw.js --mode module -p product=default assembleHap --no-daemon`
  - 落档 `.lingqu/hap/<工程>.json`（`lingqu/hap/v1`）+ `.log`（hvigor 全文）
- **第 8 道闸 `checkHapGate`**：装配成功 / 有 `module.json` / 有 `libs/arm64-v8a/*.so` / **无 rawfile 死资源**
- **⑤ 屏 HAP 卡**：「装配 HAP」按钮 + 装配/产物大小/签名态/arm64 库/rawfile/闸 六项指示；
  `ui_report` 新增 `hapOk/hapBuilt/hapBytes/hapSigned/hapRawfile/hapArm64/hapGate`；
  `LINGQU_HAP_PATH` 探针
- **9 例新单测**（总 114）：成功/失败日志解析、SUCCESS×FAILED 冲突、产物名提取、ANSI 剥离、
  HAP 条目扫描（健康/rawfile/边界/噪声）、HAP 闸四分支

### Fixed（三条都是**实机跑出来**的，单测覆盖不到）

1. **`executeWithOutput(node, ["--mode", ...])` 报 `node.exe: bad option: --mode`（exit=9）**
   argv 里**漏了 hvigorw.js 路径**，node 把 hvigor 的选项当成自己的。→ `[hvigorJs, "--mode", ...]`（AGENTS §4-36）
2. **hvigor 报 `00303217 Configuration Error: Invalid value of 'DEVECO_SDK_HOME'`，但手跑同命令成功**
   拼接出 `D:\oh\DevEcoStudio/sdk` —— **混合分隔符**被 hvigor 校验拒绝。→ `hostPath()` 按宿主归一（§4-37）
3. **过期环境变量覆盖了正确推导值**
   本机 `DEVECO_SDK_HOME` 仍指向已删除的旧 DevEco；"环境变量优先"的取值顺序把它当成了首选。
   → `firstExistingPath()`：路径类环境变量**必须目录存在**才采用（§4-38）。本机已连续踩到
   `DEVECO_HOME` / `DEVECO_SDK_HOME` / `NATIVE_OHOS_SDK` 三个过期值

### 验证证据（实机，`t2h:hap` 由界面探针触发）

| 断言项 | 值 |
|---|---|
| 装配 | `built=true`、`errorCount=0`、hvigor `BUILD SUCCESSFUL in 3 s 161 ms` |
| 产物 | `entry-default-signed.hap`，**1.40 MB**（`PackageHap` + `SignHap` 均 finished） |
| 条目 | `module.json` ✓、`libs/arm64-v8a/libentry.so` ✓、**rawfile = 0** ✓ |
| 第 8 道闸 | `gates.passed=true` |
| `ui_report` | `hapOk=true hapBuilt=true hapBytes=1469720 hapSigned=true hapRawfile=0 hapArm64=true hapGate=pass` |
| 门禁 | 四道闸全绿，build 0 warning，**TOTAL=114** |

> 另一个实测事实：`signingConfigs` 为空时 hvigor 仍产出 **signed** HAP（用 DevEco 内置的调试证书），
> 所以"签名态"要靠 `signed/unsigned` 两个文件是否存在来判断，不能靠配置猜。

**未做（如实标注）**：T5-4 签名两态（release 签名要 DevEco 登录华为账号）、T5-5 hdc 部署/启动/hilog —
**真机仍未连接**（`hdc list targets` = `[Empty]`），所以没有任何"装到鸿蒙 PC 上跑起来"的证据。

---

## [0.15.0] - 2026-10-30

**主题**：**P5 第二刀 —— T5-2 前端指纹校验**：把「`.so` 内嵌的前端产物」与 `dist/` 实际文件
对账，并让 **"只改前端不重编 `.so`" 这类"构建全绿、真机跑旧前端"的假成功自动报错**。
这是路线图点名的"本项目最硬的差异化点"，现在能自证。

### Added

- **`src/compiler/fingerprint.cj`**（`lingqu.compiler` 续）：
  - `extractAssetKeys`：**按字节**扫 `.so`（不依赖 UTF-8 解码），找 ASCII `assets/` 后吃合法 key
    字符直到非 key 字节，要求以已知前端扩展名结尾（js/css/mjs/html/png/svg/woff2… 共 18 种）；
    去重保序，非 `assets/` 下的产物不算
  - `compareAssetKeys` → `AssetDiff{matched, staleInSo, missingInSo}`：**两个方向分开记**
  - `distAssetKeysOf`：递归列 `dist/`，只收 `assets/` 下的资源（`dist/index.html` 是入口不算 AssetKey）
- **`t2h:build` 扩展**：编译成功后自动做指纹校验（`.so` 路径由 artifacts + `target/<target>/release`
  解析；`dist/` 路径读 `tauri.conf.json` 的 `frontendDist` 并按 src-tauri 相对解析）；
  新增 `verifyOnly: true` **只校验不编译**（CI / 自证用，秒级）；新增 `LINGQU_BUILD_VERIFY_ONLY=1` 探针
- **第 7 道闸 `checkAssetFingerprintGate`**（`src/port/gates.cj`）：
  `.so` 里没扫到资源 → 失败（frontendDist 没配？流水线顺序错？）；
  `staleInSo > 0` → 失败（真机会跑旧前端）；`missingInSo > 0` → 失败（`.so` 是旧的，必须重编）
- **⑤ 屏新增「前端指纹」指示 + 「校验前端指纹」按钮**（不重编，秒级出结论），
  `ui_report` 新增 `buildAssetOk/buildAssetMatched/buildAssetStale/buildAssetMissing`
- **6 例新单测**（总 105）：字节扫描（含去重/非法扩展名/0x00·0xFF 噪声）、三个比对方向、
  指纹闸四分支（无内嵌/stale/missing/干净）、`distAssetKeysOf` 真实目录 fixture

### 验证证据（实机三场景，全部可复跑）

| 场景 | 构造 | 结果 |
|---|---|---|
| 1 **一致** | habit-tree @ ohos 的 `.so` + 原 `dist/` | `assetDiff.ok=true matched=3 stale=0 missing=0`，闸 **pass**；`.so` 内嵌 `assets/index-BbUz51cz.css`、`assets/index-CNGJtM_T.js`、`assets/ui-BQiP9gYH.js` 与 `dist/assets/` 逐字吻合 |
| 2 **新前端没打包** | 往 `dist/assets/` 加一个 `index-FRESH99.js`（不重编 `.so`） | `missingInSo=[assets/index-FRESH99.js]`，闸 **fail**：「dist/ 里 1 个新产物没进 .so——.so 是旧的，必须重编」 |
| 3 **旧 `.so` 带旧前端** | 把 `dist/assets/index-BbUz51cz.css` 移走（不重编） | `staleInSo=[assets/index-BbUz51cz.css]`，闸 **fail**：「`.so` 内嵌的 1 个前端产物在 dist/ 里已不存在——改了前端没重编 .so，真机会跑旧前端」 |

> 重要操作提醒：正常跑 `cargo build` 时改 `dist/` **会触发自动重编**（`generate_context!` 的
> rerun-if-changed 覆盖前端产物），所以"只改前端不重编"不会在自动流水线里自然发生——
> 验证这道闸必须用 `verifyOnly`（或用真实设备装旧包）。场景 2/3 就是这么构造的。

| 断言项 | 值 |
|---|---|
| 门禁 | 四道闸全绿，build 0 warning |
| 单测 | **TOTAL=105，FAILED=0，ERROR=0** |
| `ui_report` | 三场景分别回投 `assetOk=true/false/false`、`matched=3/3/2`、`stale=0/0/1`、`missing=0/1/0` |

**未做（如实标注）**：T5-3 HAP 装配、T5-4 签名、T5-5 hdc 部署；真机仍未连，
`.so` 只在交叉编译层面验过，**没有任何真机加载/运行证据**。

---

## [0.14.0] - 2026-10-30

**主题**：**P5 第一刀 —— T5-1 交叉编译 + 结构化诊断**。`t2h:build` 上线：跑
`cargo build --release --target aarch64-unknown-linux-ohos`，把 stdout(JSONL) 与 stderr
两路结果归一化成结构化诊断，命中指纹就给"现象→根因→修法"，并过**编译闸 + 回归闸**。
同时**一次解锁三笔欠账**：P3 出口判据 1、P4 出口判据 1、六道闸里此前只有"闸位"的两道。

### Added

- **`src/compiler/compile.cj`（新，`lingqu.compiler` 包）**——T5-1 的纯函数半边：
  - `parseCargoJsonl`：解析 `--message-format=json` 的 JSONL，抽 `compiler-message`
    （level / code / message / 主 span 的 file:line:col / rendered 前 12 行）、
    `compiler-artifact`（只收 `.so`/`.a` 交付产物）、`build-finished.success`；
    **截断/混杂行只计数不炸**（`badLines`）——真实构建日志的最后一行常是半个 JSON
  - `countErrorLines` / `firstErrorLine`：从**stderr** 数 error 行（见下面 Fixed 1）
  - `diagsAsLogText`：归一化成可喂指纹库的文本（同时含"短描述"与"源码上下文"两类 marker）
- **`t2h:build` 命令**（三处联动齐全）：`{path, target?}` → 跑 cargo → 诊断 → 闸 → 落档
  `.lingqu/build/<工程>.{jsonl,log,json}`（`lingqu/build/v1`）；`LINGQU_CARGO` 可指定 cargo
- **六道闸补齐第 5/6 道**（`src/port/gates.cj`）：`checkCompileGate`（目标平台必须编过）、
  `checkRegressionGate`（error 数不得比上次涨）、`mergeGates`
- **指纹库 +2**（13 → **15 条**）：FP-016（`pkg-config has not been configured to support
  cross-compilation`，rule 档 → 重跑 `t2h:port` 根除）、FP-017（`failed to run custom build
  command for`，guide 档）——**依据是本轮真实构建失败，不是凭空编**
- **依赖规则 +1**（`R2-DEPS-012`）：GTK/glib 桌面链 8 个 crate（glib-sys / gobject-sys / gio-sys /
  gdk-sys / gdk-pixbuf-sys / pango-sys / cairo-sys-rs / atk-sys）判「不可用」，替代建议直指
  根因"patch 掉 wry/tao"，而不是让人去配 pkg-config
- **⑤ 构建打包屏接真数据**：路径输入 + 「交叉编译」按钮 + 退出码/错误数/警告数/产物/编译闸五项指示
  + 指纹命中列表；`ui_report` 新增 `buildOk/buildExit/buildErrors/buildWarns/buildDiags/buildFp/buildSo/buildGate`
  八个可断言字段；`LINGQU_BUILD_PATH` 探针（耗时以分钟计，只在显式设置时跑）
- **9 例新单测**（总 99）：JSONL 解析（含截断/空/混杂垃圾）、build-script 失败无 compiler-message、
  产物过滤、stderr 计数、编译闸、回归闸、合并闸、FP-016/017 命中真实失败、GTK 链规则
- 入库两份**真实构建输出**样本（脱敏裁剪）：`samples/evidence/cargo-jsonl-compile-error.jsonl`、
  `cargo-jsonl-build-script-fail.jsonl`、`cargo-jsonl-success-artifacts.jsonl`

### Fixed

1. **build-script 失败时 `errorCount=0` 却"编译失败"**（本轮实测撞到）
   `cargo` 的 JSON 流里只有 `build-finished{"success":false}`，**一条 `compiler-message` 都没有**——
   因为 `glib-sys` 这类失败发生在 build script 里，报错只进 stderr。处置：同时收 stderr 并
   `countErrorLines()` 数 `error:`/`error[` 行，取两路最大值作有效错误数（`stderrErrors` 单独回投）。详见 AGENTS §4-34。
2. **回归闸把"首次构建"误报成"回归"**
   无基线时按基线 0 处理，于是未迁移工程首跑打出「错误从 0 涨到 8（改了反而更糟）」——
   它根本没被"改"过。处置：无基线时**跳过回归闸**（首次的绝对要求由编译闸负责）。
3. **诊断提案被喂进补丁闸 → 假失败**
   `patchProposalsFromDiagnosis` 给的提案只有文件名（增删行数为未知占位 0），撞上"空补丁"闸
   必然失败。处置：`t2h:build` 只过编译闸 + 回归闸；补丁闸留给真正产生 diff 的 agent 应用路径。
4. **产物列表被中间态淹掉**：一次失败构建有 249 条 artifact（`.rlib`/`.rmeta`/`.d`/宿主 `.dll.a`），
   落档 12 KB 全是噪音。处置：只收 `.so`/`.a`（且排除 `.dll.a`）。
5. **`package lingqu.build` 与顶层 `build()` 撞名**（编译期直接报错）
   `src/build/` → `src/compiler/`（`lingqu.compiler`）。详见 AGENTS §4-35。

### 验证证据（实机，Windows 桌面会话 + Xvfb 均不需要）

| 场景 | 断言 | 结果 |
|---|---|---|
| **A 未迁移**（habit-tree @ main） | `t2h:build` | `exit=101 errorCount=8 stderrErrors=8 artifacts=0 baseline=-1`；闸 2 条失败（都指向编译）；指纹 **FP-016(rule) + FP-017(guide)**，`suggestRerunPort=true` |
| **B 已迁移**（habit-tree @ ohos） | `t2h:build` | **`exit=0 errorCount=0`，`gates.passed=true`**（P4 出口判据 1 达成）；产物 `libgrove_lib.so`（5.5 MB，`llvm-readobj` 实测 `Format=elf64-littleaarch64`）+ `libgrove_lib.a` |
| **P3 出口判据 1**（矩阵 ↔ 真实失败） | 依赖矩阵「不可用」清单 vs 真实失败点 | 真实失败 8 个（glib-sys/gobject-sys/gio-sys/gdk-sys/gdk-pixbuf-sys/pango-sys/cairo-sys-rs/atk-sys），矩阵 **8/8 判为不可用 = 100%**（判据要求 ≥80%）；另有 2 个"多识别"（gtk-sys/webkit2gtk-sys，构建未走到）如实登记 |
| **T5-2 可行性预验** | `.so` 内 vite AssetKey ↔ `dist/` | 从 `libgrove_lib.so` 提取到 `assets/index-BbUz51cz.css`、`assets/index-CNGJtM_T.js`、`assets/ui-BQiP9gYH.js`，与 `dist/assets/` **三个文件名逐字吻合** |
| 门禁 | 四道闸 | build 0 warning / **TOTAL=99** / `cj-tauri check` PASS / 骨架 build 0 warning |

**未做（如实标注）**：T5-2（`.so` 指纹校验命令化）、T5-3 HAP 装配、T5-4 签名、T5-5 hdc 部署全部未开始；
真机尚未连接（`hdc list targets` = `[Empty]`），所以**没有任何真机证据**。

---

## [0.13.1] - 2026-10-30

**主题**：P5 之前的**交接审核轮** —— 逐文件审 0.9.0～0.13.0（上一手 AI 交付的五轮），
修掉 7 个真缺陷、校准 4 处虚高数字、把「换机器就构建不了」的根因拔掉。
**没有新增功能**，目标是把地基修到可信：0.13.0 声称的「P4 判据 2/4 达成」里，判据 4 其实不成立。

### Fixed

0. **`t2h:ui_report` 并发写把自检日志截成碎片**（严重，0.13.1 实机首跑就撞到）
   现象：`.lingqu/ui-report.log` 里出现只有 `6902039 }` 的 9 字节残行，整条快照丢失，
   自检序列无法逐条断言（那个 tag `scan-kind-platform` 从此消失）。
   根因：落盘是「读全文 → 拼一行 → 覆盖写」，而 `t2h:ui_report` 会被多个前端定时器与
   页签切换**并发**调用，两个写者互相截断对方内容（审计里登记为"双写无锁"，这次实机取证）。
   处置：加进程级 `Mutex`（`gUiReportLock`）+ 上一行未以换行结尾时先补换行。
   **复跑实测：16/16 行都是完整快照，`scan-kind-platform` 回来了。**

1. **`t2h:revert` 自 0.11.0 起一直是坏的**（严重，且被文档写成"已达成"）
   现象：apply 之后点回滚永远报「没有备份可回滚」。
   根因：0.11.0 把备份从「单文件 `<工程>-Cargo.toml.bak`」改成「逐文件 `.lingqu/port/<工程>/<文件>.bak`」，
   **但 revert 没跟着改**，还在找旧路径；即使找到了也只回滚 Cargo.toml，其余 4 个被改文件留在原地。
   处置：新增 `revertPairs()` / `backupDirOf()` / `legacyCargoBakOf()`（`src/port/port.cj`，纯函数可单测），
   备份文件名收成 `BAK_*` 常量，**apply 与 revert 共用同一张表**；回滚覆盖 Cargo.toml /
   rust-toolchain.toml / .cargo/config.toml / lib.rs / index.html，并删除带 `lingqu: R2-PORT-014`
   标记的 `lingqu-dialog.js/.css`（不带标记的不动，避免误删用户文件）；旧路径备份仍兼容。

2. **`cjpm.toml` 里存着别的机器的绝对路径**（严重）
   现象：任何非 Linux 机器跑 `scripts/test.sh`，第一道闸直接红：
   `the path '/root/test/cj/cj-tauri' of module 'cjTauri' does not exist`。
   根因：`cjpm.toml` 是被跟踪文件，而 `scripts/setup.sh` 用 sed 把当前机器的路径写进去——
   谁跑过 setup 谁的本机路径就进 commit。
   处置：`cjpm.toml` 的 `dependencies.path` 与两处 `target.*.link-option` 全部改成 `${CJ_TAURI_ROOT}`
   （2026-10-30 实测 cjpm 对两处都展开）；`setup.sh` 从「sed 改写被跟踪文件」改为**环境体检 +
   检查仓里没有本机路径**。仓从此不含任何人的本机路径。

3. **R2-PORT-010 可以越过 R2-PORT-009 生效**（中高）
   现象：009 因故跳过（工程里没有 `fn run()`）时，010 照样在 `.setup()` 里插
   `install_panic_hook(app);` → 用户工程报 `cannot find function install_panic_hook`。
   处置：010 以 009 注入的 `fn install_panic_hook(` 为前置条件，缺则降 guide（给出模板但不动代码）。

4. **R2-PORT-002 会静默改行为 / 改坏文件**（中）
   现象 A：`tauri = { version = "2", default-features = false, ... }` 被重写成 `{ version, features }`，
   `default-features = false` 被丢掉——用户构建行为被静默改变。
   现象 B：多行 features（`features = [` 后接若干行）只匹配首行、拿不到 `]`，
   结果丢掉用户 features 却留下续行 → **Cargo.toml 语法错误**。
   处置：新增 `otherKeysOf()` 保留不认识的键；识别多行 features 时如实跳过并转 guide。

5. **`t2h:deps` 按名字去重导致少算包数**（中）
   现象：`depsTotal` 可能小于 `Cargo.lock` 的真实包数——直接违反 P3 出口判据 3。
   根因：按 crate 名去重，但同名多版本（bitflags 1.x/2.x）是 Cargo.lock 的常态。
   处置：改成「名字+版本」去重（`dedupeByNameVersion`）。

6. **`[patch.*]` 子表解析污染「已处置」集合**（中）
   `[patch.crates-io.tauri]` 形态下，表内的 `git` / `rev` 被当成 crate 名进结果集，
   而段头里的真名 `tauri` 反而漏掉 → 既可能误判"已处置"，也可能漏掉真正的 fork 替换。
   处置：从段头提取 crate 名，跳过 `git/rev/branch/tag/path/version/package/features/default-features/optional`。

7. **`t2h:decisions` 返回改前的旧列表**（低）
   record 成功后返回体与 `accepted/ignored` 计数仍在用旧 `items`——刚点「采纳」界面却显示「已决策 0」。
   处置：落盘成功后把 `items` 换成新表。

### Changed

- 备份文件名/目录改为 `src/port/port.cj` 的常量、由 apply 与 revert 共用——这次漂移的根因就是"两处各写一遍路径"。
- `scripts/setup.sh` 改为体检脚本（见 Fixed 2）：校验 `CANGJIE_HOME / CANGJIE_STDX / CJ_TAURI_ROOT`、
  检查 cj-tauri CLI 是否已编、检查 `cjpm.toml` 里没有本机绝对路径，**不再修改任何被跟踪文件**。
- 新增 `src/tests/port_revert_test.cj`（6 例）与 `src/tests/deps_review_test.cj`（4 例）：
  每条修复一个用例，用例写的是「修复前必然红」的断言（路径映射、保留键、多行 features、
  同名多版本、子表 crate 名）。

### Docs（虚高数字校准 —— 交付凭证必须可复算）

| 位置 | 原写法 | 实际（按 `git grep -c '^@Test'` 逐版本核对） |
|---|---|---|
| 0.10.0 单测 | 「7 例新单测／总 63」 | **6 例／总 56** |
| 0.12.0 单测 | 「5 例新单测／总 74」 | **5 例／总 69** |
| 0.13.0 单测 | 「8 例新单测／总 82」 | **8 例／总 77** |
| 0.13.0 指纹库 | 「15 条（FP-001~015）」 | **13 条（FP-001~007 + FP-010~015）**——FP-008/009 从未存在 |

- 0.11.0 的「总 64」复核无误（56+8）。
- 空位编号 FP-008/009 **不补编**（凭空补两条会违反"规则库不凭空编"）；保留编号可追溯性。
- 本轮新增 10 例 → 当前 **87 例单测**。

### 已知限制（本轮审核发现但未改，如实登记）

- **指纹库里有 3 条 marker 过泛**：FP-003 `linker \``、FP-005 `unresolved import`、FP-007 `custom-protocol`
  会在不相关的报错上命中并给出"很确定"的根因。它们仍是有用线索，但**结论需人复核**；
  收紧它们要真实日志语料（P5 交叉编译后才会有），现在不凭空改。
- `R2-PORT-014` 生成的 `lingqu-dialog.js/.css` 落在工程根目录（Vite 项目需自行搬进 `public/` 或 `src/`）。
- `R2-PORT-006` 只在完全没有 `[patch` 段时整段追加；已有其它 crate 的 patch 段时整条跳过，
  不会"只补缺口"（诊断里的 `suggestRerunPort` 因此对这类工程可能给不出改动）。

### 验证证据

**实机取证（Windows 桌面会话，`LINGQU_SCAN_PATH=E:\test\rust\habit-tree LINGQU_UI_PROBE=1`）**
—— 补上了本节早先缺的 `ui_report` 证据：

| 断言项 | 实测值 |
|---|---|
| 窗口 / 视口 / grid | 标题「灵渠迁移台 · Lingqu」；1264×801；`240px 652px 372px` |
| 屏数 / 当前屏 / JS 错误 | 7 / env / `errorCount=0` |
| WS 通道 | `wsState=connected`；`frames=2`，`lastFrameType=done`，回复「收到」 |
| ② 画像 | `scanR=24 scanC1=100 scanC2=100`；`scanKindRows=commands:12,events:0,plugins:0,frontend:7,platform:5`；落档 `.lingqu/scan/habit-tree.json` |
| ③ 依赖 | `depsTotal=453 depsPatch=0 depsUnavailable=0`；落档 `.lingqu/deps/habit-tree.json` |
| ④ 改造 | `portRules=14 portApplied=2 portAuto=1 portGuide=1 portDecided=0`（本机样本在 `ohos` 分支**已迁移**，故 001~007/009/011 全部按已迁移跳过；剩下正是 008 未设 `NATIVE_OHOS_SDK`→guide + 014 dialog 资源未生成→auto） |
| 自检日志 | **16/16 行完整快照**，每行带 `tag`+`ts`（修并发写前同场景出过碎片行） |

| 断言项 | 值 |
|---|---|
| 门禁 | 四道闸全绿（`scripts/test.sh -s`），build 0 warning |
| 单测 | **TOTAL=87，FAILED=0，ERROR=0**（`cjpm test` 实测输出） |
| 新增用例 | `port_revert_test.cj` 6 例 + `deps_review_test.cj` 4 例，逐条对应上面 Fixed |
| `cjpm.toml` | 无本机绝对路径（`setup.sh` 检查项；`grep` 实测 0 命中） |
| 换机器复现 | 本机（Windows）在仓库现有状态下直接四道闸全绿，不需要改任何被跟踪文件 |

---

## [0.13.0] - 2026-10-30

**主题**：P4 收官 —— T4-7 Agent 兜底闭环（错误指纹库 + 结构化补丁建议 + 六道闸校验器），
`t2h:diagnose` 命令上线。**P4 全部任务（T4-1～T4-9）完成**。

### Added

- **`src/port/diagnose.cj`（新）**——T4-7a/b：
  - **错误指纹库 13 条**（FP-001~007 + FP-010~015，与 `skills/t2h-ohos-port/references/pitfalls.md` 同源）：
    编译链接期 7 条（napi 缺依赖 / -lgcc_eh / 链接器未配置 / patch 绕过 / wry·tao 未一并 patch /
    版本解析失败 / custom-protocol 白屏）+ 运行部署期 8 条（app_data_dir panic / SIGABRT /
    9568322 签名 / 9568269 安装路径 / 10106102 锁屏 / rawfile 死资源）
  - **patchKind 两档**：`rule`（现有规则可修 → 建议重跑 t2h:port，幂等只补缺口）/
    `guide`（需人工或 AI）；**命中时不调用模型**——更快、更准、可审计（技术思路 §5.5 的差异化点）
  - `diagnoseLog`：日志逐行字面量匹配，同指纹去重取首行证据（带日志行号）
  - `patchProposalsFromDiagnosis`：rule 档按 ruleId 映射目标文件（按文件去重）
- **`src/port/gates.cj`（新）**——T4-7c 六道闸（可纯函数化的四道 + 命令层两道）：
  1. 文件白名单（白名单前缀 + 绝对禁碰 .git/target/node_modules/dist/Cargo.lock）
  2. 单点原则（一次一文件）
  3. 结构约束（删除 >80 行 ≈ 整体重写，拒；空补丁拒）
  4. 轮次与经济性（>8 轮拒、同指纹失败 ≥2 转 guide——`FailLedger` 跨轮计数）
  （编译闸/回归闸需 cargo 子进程，P5 落地后接入）
- **`t2h:diagnose` 命令**（三处联动）：输入 `log` 全文或 `logPath` 文件路径 →
  命中指纹（现象→根因→修法）+ 补丁提案过闸结果 + `suggestRerunPort`；
  **未命中如实返回空**（长尾才走 LLM 对话通道）。④ 屏新增"诊断"入口
  （日志路径 → 渲染"[FP-xxx] 根因 → 修法（重跑预览改造即可修 / 需人工）"）
- **8 例新单测**（总 77；0.13.1 校准，原写 82 是误记）：指纹库形态、rule 档命中与证据行号、同指纹去重、
  无命中返回空、补丁提案文件映射与去重、六道闸（白名单/单点/结构/轮次/经济性/正常放行）、
  FailLedger 分指纹计数

### Changed

- **AGENTS.md §8 上游回馈纪律 + fork 先行策略**：cj-tauri/cjh 能力不满足 → 提 issue（有修法提 PR）；
  **tauri/openharmony-ability 能力不满足时不等上游**——在 yangyongzhen fork 下建
  `fix/<工程>-<问题>` 分支先解决，patch rev 钉住继续移植，后续整理 PR 贡献上游
  （实证：cc-switch 官方 feat/open-harmony、habit-tree 的 ability feat/0.3.0 patch）
- **§8 新增鸿蒙侧工具与技能生态表**：deveco-cli（`devecocli build/run`，P5 部署链实际使用）、
  harmonyos-agent-skills（官方鸿蒙 skills 集合，skill 沉淀的参照形态与回馈对象）；
  gitcode 反爬时按 atomgit 同路径域名访问

### 验证证据

| 断言项 | 值 |
|---|---|
| 指纹库 | 13 条（rule 7 + guide 6，FP-001~007 / FP-010~015；0.13.1 校准，原写「15 条」有误），marker 全部为报错原文稳定子串 |
| 诊断匹配 | FP-001/002 主路径命中 + 证据带日志行号；同指纹去重；无命中返回空 |
| 六道闸 | 白名单外/禁碰文件/多文件/大段删除/空补丁/超轮次/超失败全部拦截；干净补丁放行 |
| 门禁 | 四道闸全绿，**77 例单测** |

**P4 出口判据达成情况（如实标注）**：判据 2（人工介入 ≤5 有记录）、4（幂等可回滚）已达成并有
单测与实测证据；判据 1（`cargo check --target ohos` 0 error）、3（规则命中率 ≥60%）**需 P5
交叉编译流水线**才能取证——指纹库与六道闸就是为那一刻准备的（编译闸/回归闸届时接入）。

---

## [0.12.0] - 2026-10-30

**主题**：P4 第三刀 —— setup 接线机械化（R2-PORT-010）+ 对话框资源生成（R2-PORT-014）
+ 人工决策记录可审计（`t2h:decisions`，T4-8 收口）。

### Added

- **`src/port/resolve.cj`（新）**：
  - **R2-PORT-010**（auto）：`.setup(|app| {` 块内接线 `install_panic_hook(app)` 与
    沙箱目录调用（4 行，形态照 habit-tree 迁移后 lib.rs）；幂等——二次 apply 文本不变；
    已接线/无 setup 块分别走跳过与 guide（不猜）
  - **R2-PORT-014**（auto）：生成 `lingqu-dialog.js` + `lingqu-dialog.css`——应用内
    Promise 化 `confirmDialog`/`promptDialog` 模块（单层 `.dialog`、z-index 80、
    颜色跟随页面 CSS 变量）；**confirm/prompt 调用点替换仍归 012 guide**（改控制流，
    机械替换会改坏代码——边界不移）
- **`t2h:decisions` 命令**（三处联动）：`action=record`（同 rule 覆盖最新决策，防重复条目）
  / `action=list`；落 `.lingqu/port/<工程>/decisions.json`（`lingqu/decisions/v1`）。
  A3 口径：guide 采纳 = 一次人工介入；忽略也要留痕
- **④ 屏 guide 项待确认卡**：guide 行标"待你确认"，行内采纳/忽略按钮；
  已决策显示"人工·已采纳/已忽略"；顶部计数变为"已决策 n，待决策 m"；
  `ui_report` 新增 `portDecided` 字段（服务端白名单同批放行）
- **5 例新单测**（总 69；0.13.1 校准，原写 74 是误记）：接线插入位置与幂等、无 setup 块 guide、对话框资源形态、
  不存在目录 outcome

### 验证证据（habit-tree 迁移前文件实测，Xvfb + `ui_report`）

| 断言项 | 值 |
|---|---|
| portRules / portApplied | **14 / 11**（auto 10 + guide 1） |
| guide 1 条 | 本机未设 `NATIVE_OHOS_SDK` → R2-PORT-008 如实降级（同 0.11.0 行为） |
| portDecided | 0（决策记录链路已通，端到端点选待实机） |
| errorCount | 0 |
| 门禁 | 四道闸全绿，**74 例单测** |

**未做（如实标注）**：决策记录的端到端点选（Xvfb 下无指针交互，命令层逻辑已编译验证）；
confirm/prompt 调用点替换仍 guide（设计边界）；`cargo check --target ohos` 需 P5。

---

## [0.11.0] - 2026-10-30

**主题**：P4 第二刀 —— 工具链落盘（T4-3）+ 平台 cfg 分支注入（T4-4）+ ArkWeb 兼容层（T4-5）
+ 三档动作与人工介入计数（T4-8），`t2h:port` 从"Cargo.toml 改造"扩展为完整规则面。

### Added

- **`src/port/toolchain.cj`（新）**——T4-3 工具链落盘：
  - R2-PORT-007 `rust-toolchain.toml`：Windows 走 `gnullvm`（llvm-mingw 缺 `-lgcc_eh` 的实测结论）、
    Linux 走默认 GNU；targets 统一加 `aarch64-unknown-linux-ohos`
  - R2-PORT-008 `.cargo/config.toml`：NDK clang 直作链接器（自带 clang 包装是 Unix shell 脚本）
    + sysroot rustflags + cc 环境变量；SDK 路径从 `NATIVE_OHOS_SDK` 读取，
    **未设时如实降级为 guide 提示，不写坏文件**
- **`src/port/shim.cj`（新）**——T4-4 / T4-5：
  - R2-PORT-009 `lib.rs` 注入 `resolve_app_data_dir()`（OHOS 沙箱 `/data/storage/el2/base/files`）
    + `install_panic_hook()`（panic 落盘 `panic.log`——鸿蒙 hilog 不捕获 Rust stderr）
  - R2-PORT-011 `index.html` 注入 localStorage 内存 polyfill（ArkWeb 自定义 scheme 下
    `window.localStorage` 为 null；桌面原生可用时不生效，业务零改动）
  - R2-PORT-012 / 013（**guide 档**）：探测裸 `confirm(`/`prompt(` 调用点与
    `<input type="color">`——只给位置与处置方案（Promise 化对话框 / 应用内色板），
    **不机械替换**（会改坏代码）；计数进人工介入（验收 A3 可审计）
- **T4-8 分档计数**：`RuleOutcome` 增加 `tier`（auto/guide），`PortResult.countersJson()`
  输出 auto/guide 两计数；④ 屏显示"人工介入 n/5"；`ui_report` 新增 `portAuto/portGuide`
- **t2h:port apply 扩展**：逐文件备份到 `.lingqu/port/<工程>/`（Cargo.toml / rust-toolchain /
  cargo config / lib.rs / index.html），备份不覆盖（首次为准）
- **8 例新单测**（总 64，复核无误）：两套工具链模板、SDK 路径替换、注入块形态、分档计数、
  guide 探测（正向 fixture + 迁移后样本应为 false）

### 验证证据（habit-tree 迁移前文件实测，Xvfb + `ui_report`）

| 断言项 | 值 |
|---|---|
| portRules / portApplied | 12 / 9（auto 8 + guide 1） |
| guide 1 条 | 本机未设 `NATIVE_OHOS_SDK` → R2-PORT-008 如实降级提示（不编造链接器路径） |
| errorCount | 0 |
| 门禁 | 四道闸全绿，**64 例单测** |

**未做（如实标注）**：注入函数的 setup 接线（`install_panic_hook(app)` 调用点）涉及语义，留 guide；
confirm/prompt 的应用内对话框实现属 P4 第三刀（跟 T4-8 审批卡一起）；
`cargo check --target ohos` 出口判据需 P5 交叉编译环境。

---

## [0.10.0] - 2026-10-30

**主题**：P4 第一刀 —— 规则引擎 + Cargo.toml 文本变换（路线图 T4-1 / T4-2 / T4-6），
`t2h:port` / `t2h:revert` 命令上线，④ 改造执行屏接真数据。

### Added

- **`src/port/port.cj`（新，`lingqu.port` 包）**：
  - 规则模型（T4-1）：每条规则 = id + 适用条件 + 变换 + `RuleOutcome`
    （applied / note / before / after——evidence 载体，UI 与报告直接展示）
  - 六条 Cargo.toml 规则（T4-2），**逐条对应 habit-tree `main→ohos` 分支的真实 diff**：
    R2-PORT-001 `[lib]` crate-type 补 cdylib（`["rlib"]` → `["staticlib", "cdylib", "rlib"]`）、
    002 tauri 钉 `=2.11.5` + features 合并 custom-protocol/protocol-asset（已有 features 原样保留）、
    003 tauri-build 钉 `=2.6.3`、004 wry 钉 `=0.56.0` + `default-features=false`（仅当存在 tauri 依赖）、
    005 追加 OHOS target 段（napi-ohos / openharmony-ability 桥）、006 追加 `[patch.crates-io]`
    与 ability patch 段（git URL + rev 固定）
  - 幂等与回滚（T4-6）：追加块带 `# === lingqu: <rule-id> ===` 标记；原地改写看目标状态判定
    （钉没钉/有没有该段）；`isIdempotent` 可断言"再跑一遍 applied=0"；
    **apply 前自动备份原文件到 `.lingqu/port/<工程>-Cargo.toml.bak`，`t2h:revert` 一键写回**
  - dry-run 落预览 `.lingqu/port/<工程>-Cargo.toml.preview`——UI diff 预览与实测对照的载体
- **命令 `t2h:port` / `t2h:revert`**（三处联动齐全）；④ 改造执行屏新增规则改造卡
  （预览/应用/回滚三按钮 + 逐条 outcome 表 + `portApplied/portRules/portError` 自检字段，
  服务端白名单同批补放行）
- **6 例新单测**（总 56；0.13.1 校准，原写「7 例／总 63」有误）：六条全应用 / 变换内容逐项断言 / 幂等二次跑 /
  已迁移工程逐字节不变 / 非 Tauri 工程跳过钉版 / 行级工具边界

### Fixed

- `spliceLines` 死循环：`count=0` 且 `i==at` 时 `i += 0` 后 `continue`，无限插入直到
  OutOfMemoryError（单测二进制直跑抓到的栈）。修法：`inserted` 标志位
- 行模型纪律：规则内禁止往单个行元素塞 `\n`——ruleTauriPin 曾把注释与代码并进一个元素，
  导致后续规则按行扫 `tauri` 时命中的是注释行、误判成非 Tauri 工程。抽 `spliceLines` 统一处理

### 验证证据（habit-tree 迁移前 Cargo.toml 实测，Xvfb + `ui_report`）

| 断言项 | 值 |
|---|---|
| portApplied | **6 / 6**（六条规则在未迁移文件上全部应用） |
| **规则产物 vs 真实迁移 diff** | **功能性代码行全部一致**（crate-type / 钉版 / features / OHOS target 段 / 两段 patch 的 rev 与 URL 逐字符吻合）；差异仅：注释措辞、人工按需加的 `image-png` feature、上游版本号演进——**规则覆盖了该工程 Cargo.toml 迁移的全部机械改动** |
| 幂等 | `idempotent=true`（二次跑 applied=0，文本逐字节不变） |
| 门禁 | 四道闸全绿，**63 例单测** |

**未做（如实标注）**：T4-3（工具链落盘）/ T4-4（cfg 分支注入）/ T4-5（ArkWeb 兼容层）/
T4-8（三档审批与人工计数）留给 P4 第二刀；T4-7（Agent 兜底）按砍单顺序最后；
`cargo check --target aarch64-unknown-linux-ohos` 出口判据需 P5 交叉编译环境。

---

## [0.9.0] - 2026-10-30

**主题**：P3 `t2h:deps` —— Cargo 依赖树 OHOS 兼容性矩阵 + 替代建议库（路线图 T3-1～T3-5），
③ 依赖扫描屏接真数据，依赖维评分上线。

### Added

- **`src/deps/deps.cj`（新，`lingqu.deps` 包）**：
  - `parseCargoLock`：解析 `Cargo.lock`（v3/v4）整树，按 `[[package]]` 块取 name/version；
    `[metadata]` 段不收；残缺块（缺 version）也收。**不跑 cargo 子进程**——单测只测纯函数（D-009）
  - `parsePatchedCrates`：提取 `Cargo.toml` 的 `[patch.*]` 段覆盖的 crate 名
    （`[patch.crates-io]` 与 `[patch."https://…"]` 都算），用于判断 fork 替换是否已落档
  - `applyRule` 规则表（**每条都有实测出处，不凭空编**）：tauri 全家桶 / wry / tao /
    openharmony-ability → 需 patch（alternative 给 git rev 与版本钉法）；
    `openssl-sys` / `native-tls` / `rfd` → 不可用 + 替代方案（rustls / 应用内降级）；
    `reqwest` / `dirs` / `napi-ohos` → 有条件可用（evidence 写清条件）；
    **已在 `[patch.*]` 里的 crate 优先判「已处置」（R2-DEPS-100）**——这是迁移前后的关键区别；
    表外的 crate 默认"可用"，evidence 标明"待真机验证"，**不冒充已验证**（避免误报，P3 出口判据 1）
  - `depsScanJson`：总入口，产出 `lingqu/deps/v1`；读盘失败走 `outError`（D-013 不静默）
  - `depsScoreOf`：依赖维评分（不可用 −15 / 需 patch −5，与 runtime/api 维同口径），floor 0
- **命令 `t2h:deps` + 三处联动**：`src/main.cj` 注册、capabilities 放行、UI 调用；
  结果落 `.lingqu/deps/<工程名>.json`
- **③ 依赖扫描屏接真数据**：工程路径输入 + 扫描按钮 + 全量/需 patch/不可用筛选页签 +
  状态 pill / 规则 / 依据 / 替代建议四列表格；`ui_report` 新增
  `depsTotal / depsPatch / depsUnavailable / depsRows / depsOut / depsError` 六个可断言字段
  （**后端 `UiReportCommand` 是显式字段白名单，前端新字段必须同批在服务端补放行**——本轮踩到）
- **② 画像的依赖维评分条点亮**：`t2h:deps` 出分后 ② 屏 deps 维从"—"变为真分数
  （build/dist 仍属 P5，如实保持 -1）
- **9 例新单测**（总 50）：lock 解析（主路径/空文件/残缺块）、patch 提取（含子表头排除）、
  规则表逐档断言、已 patch 优先、评分（主路径/扣到底不出负数）、错误路径（无 Cargo.lock → outError）、
  真实样本回归（cc-switch-ohos，无样本时跳过不造假）、`quotedValue` 边界

### Fixed

- `ui_report` 服务端字段白名单漏新字段：前端加了 `deps*` 指标但落盘日志里始终不出现
  （回投被服务端丢弃）。处置：`UiReportCommand` 同批补放行，探针可断言

### 验证证据（cc-switch-ohos 真实样本，`.lingqu/ui-report.log`）

| 断言项 | 值 |
|---|---|
| depsTotal / depsRows | **625**（与 Cargo.lock 包数一致——出口判据 3） |
| depsPatch | 0（该工程 `[patch.*]` 已落，tauri/wry 全部命中"已处置"R2-DEPS-100） |
| depsUnavailable | 1（`rfd` 0.16.0 → R2-DEPS-011 + 替代建议） |
| depsOut | `.lingqu/deps/cc-switch-ohos.json`（真实落档） |
| 依赖维评分 | 85 |
| errorCount | 0 |
| 门禁 | 四道闸全绿，**50 例单测** |

**未做（如实标注）**：规则库只覆盖已实测的 10+ 个 crate（tauri 系 / wry / tao / napi-ohos /
openssl 系 / rfd / dirs / reqwest），其余 615 个 crate 走默认直编——**不可用清单与真实交叉编译
失败点的 ≥80% 吻合度验证（出口判据 1）需 P5 交叉编译流水线到位后做**；`cargo metadata` 子进程
版采集层未做（当前用 Cargo.lock 静态解析，够用且可单测）。

---

## [0.8.0] - 2026-10-30

**主题**：P2 收尾 —— **C2 发现置信度**落地（人工基线双向 diff），并据此补齐 4 条扫描规则。

### Added

- **`src/scanner/baseline.cj`（新）**：`lingqu/baseline/v1` 解析 + 双向 diff + `lingqu/confidence/v1` 输出
  - 漏识别（基线有、扫描无）扣 **C2 = (基线项 − 漏)/基线项**；误识别（扫描有、基线无）只计数；
    结论分歧（两边都有但结论不同）只计数、用于盯判定表质量
  - **没有基线时 C2 = -1**（页面显示"未对照"），绝不顺口算成 100
  - 解析容错：语法错 / 顶层非对象 / 缺 items / 单项缺 kind 或 name 都只跳过，不让扫描失败
- **命令 `t2h:scan` 接入基线**：按工程名自动找 `samples/baselines/<工程>.json`（参数 `baseline` 可覆盖），
  返回值新增 `baseline` / `baselineError` / `confidence`
- **② 迁移画像新增「C2 发现置信度 · 人工基线对照」卡片**：基线项 / 命中 / 漏识别 / 误识别 +
  基线来源 + 漏识别与误识别明细；C1/C2/C3 三个指标并列显示（防止只看 C1）
- **`samples/`**：`baselines/habit-tree.json`（人工基线 24 项，注明来源与口径）、
  `evidence/habit-tree-scan-before-c2.json`（补规则前的扫描快照，第一轮 C2 的底稿）、`README.md`（口径 + 加样本步骤）
- **8 例新单测**（总 41）：基线解析（正常/坏 JSON/顶层非对象/缺字段）、全命中、数漏识别、数误识别、
  无基线不算 100、结论分歧、名字首尾空白容错

### Fixed（C2 第一轮 diff 直接扫出来的 4 个漏识别，全部补规则而不是改基线）

| 漏识别 | 处置 |
|---|---|
| `canvas.toDataURL`（celebrate.ts 导出 PNG，2 处） | 新增前端标记 + 规则 `R5-010`：长 base64 跨桥风险 → `toBlob` + 原生保存 |
| `FileReader`（ui.ts 导入处理） | 新增前端标记 + 规则：本身可用、配合 `<input type=file>` 才受限（判 `不适用`） |
| `window.open`（ui.ts 外链回退） | 新增前端标记 + 规则：主路径已走 `open_url` 命令，判 `不适用` |
| `getVersion`（前端 `@tauri-apps/api/app`） | **新增一类解析 `parseFrontendTauriApis`**：前端侧 Tauri API 能力并进平台 API 维，规则 `R3-010`（OHOS 走 bundleManager）；同时补上 window/path/fs/dialog/webview 五个模块的判定 |

### Changed

- 版本 0.7.0 → 0.8.0，`cj-tauri sync` 重派生骨架
- `docs/P2-scan-口径草案.md` 新增 §三之二「A4 人工基线口径」：基线的**边界**（库依赖归 P3、死代码也要收）
  与「先人工列基线再补规则」的自证流程

### 验证范围

| 断言项（habit-tree 实测） | 第一轮（0.7.0，未补规则） | 本轮（0.8.0） |
|---|---|---|
| R（识别项） | 20 | **24** |
| C1 结论覆盖率 | 100% | 100% |
| **C2 发现置信度** | **83.3%**（漏 4 项） | **100%**（漏 0 / 误 0 / 分歧 0） |
| 五类分布 | cmd12 / ev0 / plg0 / fe4 / api4 | cmd12 / ev0 / plg0 / **fe7** / **api5** |
| C3 人工占比 | 5.0% | 4.2%（1/24） |

- ✅ 四道闸全绿；**41 例单测**；`ui_report` 断言 `scanC2=100, scanMissed=0, scanExtra=0, scanVerdictDiff=0,
  scanBaseline=samples/baselines/habit-tree.json`，逐页签 `scanRows` 12/0/0/7/5，`errorCount=0`
- ⚠️ **只做了 1 个样本的基线**（habit-tree）。cc-switch（R=317）尚无基线 → 它的 C2 如实显示"未对照"；
  5 样本基线矩阵排在 P7。build/deps/dist 三维仍为 `-1`（待 P3/P5）

---

## [0.7.0] - 2026-10-30

**主题**：②「迁移画像」界面接真数据（`t2h:scan` 驱动），并把参考资源写进开发契约。

### Added

- **② 迁移画像改成数据驱动**：`assets/ui/index.html` 的整屏由 `lingqu/scan/v1` 渲染——
  评分环（`--v` = 后端总分）、五维条（未扫描维如实显示 `—`，不编造 100）、
  R/D/H/U 与 C1/C3、五类清单表（处置 pill / 规则 / 出现点 / 依据）、阻塞项列表
  （未知 = hard 红条、人工 = soft 黄条）；页签切换即换数据源
- **扫描入口**：右上角工程路径输入 + 「扫描」按钮（`t2h:scan`），失败原因直接显示在提示行
- **自检扩展**：`ui_report` 新增 `scanKind / scanRows / scanBlockers / scanOutError / scanKindRows`；
  `LINGQU_SCAN_PATH` 探针扫完会**把五类页签逐个切一遍并逐次回投**
- **`AGENTS.md` §8 参考资源**：**CangjieSkills 地址**
  （https://atomgit.com/Cangjie-SIG/CangjieSkills ）+ 本机克隆路径 + `search_docs.py` 用法，
  以及 cj-tauri / cjh 本地仓位置——写仓颉卡住时的第一查阅点，防止后续会话遗忘
- **`projectNameOf` / `sanitizeFileName`**（`lingqu.scanner`，公开纯函数，各带测试）

### Fixed

- **`.lingqu/scan/<工程>.json` 从来没写成功过（0.6.0 就在丢证据）**：
  工程名只按 `/` 取末段，Windows 路径 `E:\test\rust\habit-tree` 整条被当名字 →
  落档路径非法 → `FSException: The input path 'parent' … does not exist`；
  而 `eprintln` 在 GUI 里被框架日志接管（AGENTS §4 第 14 条），**失败是静默的**。
  处置：路径末段 `(`/` 与 `\` 取最后出现者）+ 非法字符转 `_` + **写档失败原因进返回值 `outError`
  并由页面显示**——同类静默失败以后看得见
- **`docs/仓颉资源地址.md` 编码**：原文件是 GBK 粘贴稿（`read` 报 "invalid UTF-8 text"）→
  显式按 936 解码转 UTF-8，并重排成五节表格

### Changed

- 版本号 0.6.0 → 0.7.0（`cjpm.toml` / `cj-tauri.toml` / 本文件三处一致），`cj-tauri sync` 重派生骨架

### 验证范围

| 断言项（habit-tree 实测） | 值 |
|---|---|
| R / D / H / U | 20 / 20 / 1 / 0 |
| C1 / total | 100% / 68（partial） |
| `scanOut` | `.lingqu/scan/habit-tree.json`，8606 B（**本轮才真的写出来**） |
| `scanKindRows` | `commands:12,events:0,plugins:0,frontend:4,platform:4` |
| 逐页签 `scanRows` | 12 / 0 / 0 / 4 / 4 |
| JS 错误数 | 0 |

- ✅ 四道闸全绿；**33 例单测**（新增 2 例：路径末段 + 文件名净化）
- ⚠️ **未做**：C2 发现置信度（需人工基线双向 diff）；鸿蒙端 HAP 未开始；
  五维里 build/deps/dist 仍为 `-1`（待 P3/P5）

---

## [0.6.0] - 2026-10-30

**主题**：P2 `t2h:scan` 扫描器（五类清单 + 覆盖率 + 评分），口径按 `docs/P2-scan-口径草案.md` 落地。

### Added

- **`src/scanner/scan.cj`（新增包 `lingqu.scanner`）**
  - 工程识别：`Cargo.toml`（crate / tauri 版本）、`tauri.conf.json`（bundleId / frontendDist）
  - **五类清单**：命令（`#[tauri::command]` 函数 + `generate_handler!` 注册核对）、事件（emit/listen）、
    插件（Cargo + package.json 两侧合并）、**前端浏览器能力**（按能力计项，不按文件）、平台 API 符号
  - 处置四值域 + `未知` 禁用值；**同一符号/能力跨文件合并**，sites 只记账
  - 度量：`R/D/H/U`、`C1`（结论覆盖率）、`C3`（人工占比）、`C2`（留空并标注需人工基线）
  - 评分：runtime / api 两维实算；build / deps / dist 标 `-1`（未扫描）且 `partial=true`，
    **不编造 100 分**；总分是加权平均（`Σ维分×权重 / Σ权重`）
  - 输出 `lingqu/scan/v1` JSON，落 `.lingqu/scan/<工程>.json`
- **命令 `t2h:scan {path}`** + capabilities 声明 + `.gitignore` 覆盖 `.lingqu/`
- **扫描探针**：环境变量 `LINGQU_SCAN_PATH` → 页面启动即跑一次扫描，指标回投 `t2h:ui_report`
  （`scanR/D/H/U/C1/total/out/error`），**无视觉也能验扫描器**
- **16+2 例单测**（`src/tests/scanner_test.cj`）：命令/事件/插件/前端/平台解析、判定表、
  C1/C3 计算、禁用值拉低覆盖、评分不重复乘 100、命令一律 `不适用`

### Fixed（都是实测扫出来的）

- **总分算成 2500**：`weighted × 100 / 0.45` 把 100 乘了两遍 → 改为加权平均（回归测试锁住）
- **跨文件同名项没合并**：`app_data_dir`、`localStorage` 在多个文件各生成一项 → 编排层按名字合并
  （habit-tree 的 `localStorage` 从 5 项合成 1 项、17 个 sites）
- **扣分过重**：改造按 −10 算导致 habit-tree runtime/api 双双见底 25 分（与"该应用已迁移成功"矛盾）
  → 改造 −5 / 降级 −15，总分回到 68
- **事件与插件过度归因为"人工"**：cc-switch 上 22 个事件名 + 7 个插件全判人工，H=30 直接违反 A3（≤5）
  → 事件桥三端闭环判 `不适用`；插件判定表补齐（updater/deep-link/window-state/process/opener/
    global-shortcut/log/os 等）→ 两个样本 H 都降到 **1**

### 验证范围

| 样本 | R | C1 | H | C3 | total | 五类分布 |
|---|---|---|---|---|---|---|
| habit-tree | 20 | 100% | 1 | 5.0% | 68（partial） | cmd12 / ev0 / plg0 / fe4 / api4 |
| cc-switch | 317 | 100% | 1 | 0.3% | 65（partial） | cmd275 / ev22 / plg10 / fe4 / api6 |

- ✅ 四道闸全绿；**31 例单测**；能力三方比对通过
- ✅ 两个真实样本上 R/D/U 一致、无重复符号、sites 计数正确
- ⚠️ **未做**：C2 发现置信度（需人工基线双向 diff）、UI ② 迁移画像接真数据（仍是示意）、
  events/plugins 在 habit-tree 上为 0（该应用确实没用 `tauri-plugin-*` 与 `emit/listen`，非漏扫）

---

## [0.5.0] - 2026-10-30

**主题**：P1 对话通道接通（WS 流式 + 工具卡 + 审批卡）。

### Added

- **装配 `WsPlugin`**：capabilities 声明 `ws:connect/send/close`、事件 `ws:frame/ws:state`、
  `permissions: ["ws:default"]`、`scopes.ws: ["127.0.0.1","localhost"]`
- **页面 WS 通道**（对齐 cj-tauri `examples/cjnote` 的跑通实现）：
  - 引擎就绪自动连 `ws://127.0.0.1:<port>/ws`；`ws:state` 是唯一连接判据；断线退避重连（上限 12 次）
  - 帧分发：`delta`（增量累积 + 90ms 节流重绘）/ `tool_start` / `tool_result`（认 `is_error`）/
    `done`（认 `finish_reason`）/ `ack` / `cancelled` / `approval_request` / `error` / `history_messages` / `raw`
  - 帧解包**先认 `p.type`**（delta 帧自带 `text`，先按包装体 parse 会把帧吞掉——cjnote 踩过）
  - 会话续接：从帧里接住 `session_id`，重连后自动 `resume_session`，不另起会话
- **工具调用卡**：工具名 + 参数 + 结果回填（失败标红）；结果超 2000 字符截断显示
- **审批卡**：工具名 / 命中规则 / 参数（JSON）/ 倒计时（与 `expires_in_ms` 同步）/ 批准·拒绝；
  超时或断连就地标「按拒绝收场」；回执走 `approval_response{request_id, approved}`
- **错误可执行化**：按 `error.code`（`model_unavailable` / `provider_error` / `no_api_key` 等）给下一步提示
- **会话控制**：面板头「＋ 新建会话」「■ 中断」
- **自检扩展**：`ui_report` 增 `wsState / frames / toolCards / approvals / lastFrameType / replyPreview`；
  `LINGQU_UI_PROBE=1` 跑常规序列（含真实发问），`LINGQU_UI_PROBE=approval` 触发审批并**自动点拒绝**验证回执链路

### 验证范围

- ✅ **通道连通**：`ws=connected`，一问一答 `frames=2`（`delta`+`done`），`replyPreview="收到"`
- ✅ **审批闭环**：临时把 cjh 置严格模式（`capability.approval=["*:*"]`）→ `approvals=1`（卡片出现）
  → 自检自动点「拒绝」→ 回合继续到 `done`（`frames=268`）。**验证后已恢复原配置**
- ✅ 四道闸全绿；能力三方比对通过（ws 命令与事件均声明齐）
- ⚠️ 未验证：多轮长对话的滚动/性能、`tasks` 帧的面板（尚未接）、鸿蒙端 WS（cjh 在鸿蒙无 ws 能力位）

### 已知限制（诚实标注）

- cjh **默认是宽松模式**（无 `capability` 段 = 所有工具放行），所以审批卡只有在 cjh 侧开启
  `capability.enabled=true` + `approval` 命中时才会出现。工具不替用户改 cjh 的安全策略，
  只在卡片出现时正确渲染与回执。验证配方见 `docs/实施路线图.md` P1。

---

## [0.4.0] - 2026-10-30

**主题**：跨平台工程化（Windows + Linux 同源）+ 界面可自动验证。

### Added

- **门禁改 bash 为准（跨平台一份实现）**：`scripts/test.sh`（Linux / macOS / Windows-Git-Bash 通用）
  + `scripts/test.bat`（Windows 只做"找 bash 再委托"，纯 ASCII）。与 cj-tauri / cjh 两个上游仓同口径。
  支持 `-q`（快速回路）/ `-s`（先 sync）/ `-c`（清增量缓存）
- **`scripts/run-dev.sh` + `run-dev.bat`**：跨平台启动（PATH/动态库/工作目录一次配好；引擎由应用自己托管）
- **`scripts/setup.sh`**：换机器时把 `cjpm.toml` 里写死的本机绝对路径（框架 path + 两处 `-L<native>`）
  一键改成本机值，不必重跑 `cj-tauri create`（那会覆盖业务代码）
- **Linux 版内置引擎**：`vendor/cjh/linux-x64/cjh`（单文件、静态链接，无随行 DLL），
  并在 `cjhVendorVerified` 的 Linux 分支里加了 SHA256 校验
- **`.gitattributes`**：`.sh` 强制 LF 且保留可执行位、`.bat` 用 CRLF、二进制不动——
  否则 Linux 上会撞 `/usr/bin/env: 'bash\r': No such file or directory`
- **界面自检闭环 `t2h:ui_report`**：页面把版面指标（视口、grid 列宽、当前屏、屏数、id 数、
  设置面板状态、模型条数、JS 错误数）回投后端，后端落 `.lingqu/ui-report.json` 与 `ui-report.log`；
  置 `LINGQU_UI_PROBE=1` 时页面自己跑一遍「开设置 → 折叠 → 展开」序列。
  **没有视觉能力也能验证版面**（本项目首次做到）
- **快捷键 `Ctrl+,`** 打开模型与服务商设置

### Fixed

- **`t2h:cjh_models` / `cjh_settings` / `cjh_settings_save` 未注册**：`CjhCommands` 的 `match`
  里写了分支，但没给这三个命令名逐条 `app.register` → 页面拿到 `command not registered`。
  由界面自检抓出（`cj-tauri check` 只校验"已注册 ⊆ 已声明"，不查"已声明 ⊆ 已注册"）
- **门禁把失败原因藏了**：失败时只 `grep FAILED|ERROR|error:`，而真实原因（崩溃 / 链接错）里没有这些词。
  改为失败即打印日志尾部
- `run-dev.sh` 与 `test.sh` 在 Windows 上会因环境里的 `CANGJIE_HOME=D:\...` 形式路径导致
  所有命令 `exit 127`：统一加 `to_posix`（`cygpath -u` 或手写转换）

### Changed

- **弃用 `.ps1` 脚本**（`test.ps1` / `run-dev.ps1` / `tools/vendor-cjh.ps1`）：
  PowerShell 5.1 的坑太多（无 BOM 按 GBK 解码、`2>&1` 把 stderr 变成 ErrorRecord 后
  在 EAP=Stop 下炸、`Set-Content` 给 `.cj`/`.toml` 加 BOM），且 Windows 专用不利跨平台。
  替代为 `scripts/*.sh` + `*.bat` + `tools/vendor-cjh.sh`
- `tools/vendor-cjh.sh` 支持 `--platform win-x64|linux-x64`，一次重算两平台的 `SHA256SUMS`

### 验证范围

- ✅ `scripts/test.sh` 与 `scripts/test.bat` 均实测执行通过（三连全量 + 干净构建）
- ✅ 窗口实机截图（1280×840，标题 `灵渠迁移台 · Lingqu`）、WebView2 起 6 个渲染进程
- ✅ 界面自检序列实测：`240px 652px 372px` → 开设置 `models=2` → 折叠 `240px 1024px` → 展开复原，`jsErrors=0`
- ✅ cjh 由应用从 `vendor/` 自动拉起，`/api/health` → `{"status":"ok","version":"1.6.1"}`
- ⚠️ Linux 侧脚本**未在 Linux 上执行过**（按约定留给后续接续时验证）
- ⚠️ 纯视觉层面（配色、字距、留白）未做人工目检

---

## [0.3.0] - 2026-10-29

**主题**：UI 门面重做（对齐效果图）+ 模型配置。

### Added

- **七屏全部按效果图填实**：评分环与五维条、覆盖率分子分母、五类清单页签、阻塞项（严重度色标）、
  Cargo 依赖矩阵、改造步骤时间线、实时日志（着色）、构建五阶段、产物卡（含 `.so` 的 AssetKey 指纹）、
  功能清单打勾表 + 证据缩略图、报告三段式与风险分级
- **AI 助手可折叠**：面板头 `»`、顶栏「AI 助手」、快捷键 `Ctrl+B` 三条入口；折叠后中栏占满，
  右侧留一条竖向悬浮唤出条
- **模型与服务商配置视图**（参考 cjnote `examples/cjnote`）：引擎状态与端点、模型列表（点选即切）、
  Base URL / API Key（**永不回填**）/ 模型名 / 温度 / 单轮最大 tokens / 最大工具轮数，
  「保存并生效」直接推给运行中的 cjh（外部实例也生效，不必重启）
- **后端命令**：`t2h:cjh_models`（GET `/api/models`）、`t2h:cjh_settings`（GET `/api/settings`）、
  `t2h:cjh_settings_save`（POST `/api/settings`，**只提交用户真填了的字段**）
- 深/浅色主题切换（同一套令牌，与 cj-tauri 生态一致）
- 引擎未就绪时，对话区给**可操作**的提示卡（「立刻拉起」/「校验并重试」），而不是干巴巴的"未连接"

### Changed

- **去掉「指定路径启动」入口**——引擎是内置随包的，启动即自动托管；`t2h:cjh_start` 保留为后端兜底
- 引擎三态同时显示在顶栏、左栏底部、输入框上方，任何一屏都看得见
- REST 调用放后端而不是页面直接 fetch：避免 WebView 自定义 scheme 的跨源问题，
  也不用把 `127.0.0.1` 写进 `scopes.http` 给页面开一条出网白名单
- 前端**不持久化任何状态到 localStorage**——ArkWeb 自定义 scheme 下它不可用，
  这正是本工具要写进规则库（R5-001）的坑，自己不能踩

### 验证范围（诚实标注）

- ✅ `scripts/test.ps1` 四道闸全绿；后端零警告；13 例单测通过；HTML 结构平衡（7 屏 / 302 div / 43 button）
- ✅ 前后端命令面三方一致（`cj-tauri check` 比对通过）
- ⚠️ 界面渲染、折叠、模型读取/保存的实际交互仍需人工目视验证（受限宿主里窗口起不来）

---

## [0.2.0] - 2026-10-29

**主题**：AI 引擎托管完整化 + 工程规范落地。

### Added

- **`src/cjh_host.cj`**：完整移植 cj-tauri `examples/ai-chat` 的 cjh 托管实现
  - 健康检查 `GET /api/health`（`stdx.net.http`），替代原先的裸 TCP 探测
  - 三态状态机 `running` / `ready` / `missing`，纯读可轮询
  - `launchHidden` 静默拉起 + 100ms × 10s 就绪等待（`Ready` / `Died` / `Timeout`）
  - 复用优先：8765 上已有实例不抢不杀；只有 `gCjhOwned` 的才在退出时收尾
  - 拉起前先收掉自己上一只，避免旧进程占端口导致新实例绑定失败
  - 二进制三级来源：`LINGQU_CJH` → 已部署目录 → 仓内 vendor（4 文件逐个 SHA256）
  - vendor 不可用时按 `LINGQU_CJH_BUNDLE` 的 zip 用系统 bsdtar（绝对路径）解包后拉起
- **三条运维命令**：`t2h:cjh_status` / `t2h:cjh_start` / `t2h:cjh_deploy`；`t2h:quit`（先收引擎再退窗口）
- **生命周期收尾**：守护线程 `waitForExit()` 后收 cjh（新形态 `AppSpec` 无 onExit 钩子），
  收尾跑 5 轮覆盖「用户秒关窗口 + 后台拉起在途」的抢跑
- **单元测试** `src/tests/core_test.cj`：13 例，覆盖 `joinPath` / `firstExisting` / `parsePortEnv` /
  `putEndpoints` / `cjhVendorVerified` 的主路径与边界
- **交付门禁** `scripts/test.ps1`：业务包构建（零警告）+ 单测 + `cj-tauri check` 三方比对 + 骨架构建
- **工程规范文档**：`AGENTS.md`、本 `CHANGELOG.md`、`docs/需求追踪.md`、`docs/进度记录.md`、
  `docs/会话交接.md`、`docs/设计决策记录.md`

### Changed

- 日志落盘：`setLogToDefaultFile("lingqu")` → `%LOCALAPPDATA%\cj-tauri\logs\lingqu.log`
- 启动时在**后台线程**自动 ensure 引擎，不再挡住窗口出现
- 工作台 UI：cjh 从"alive 布尔"改为三态展示；新增「一键部署并启动引擎」「用指定路径启动」「退出」入口
- `cjpm.toml` 补 `[target.x86_64-w64-mingw32]` / `[target.x86_64-unknown-linux-gnu]` 的
  `link-option`（`-lcjtbridge`）——`cjpm test` 的测试可执行文件走业务包自己的链接行

### Fixed

- 加 `LogPlugin` 却没在能力清单声明 `log:path` / `log:write`，被 `cj-tauri check` 三方比对拦下
- `vendor/cjh/win-x64/*.dll` 被模板 `.gitignore` 的 `*.dll` 规则忽略（克隆后 HTTPS 全灭的隐患）

### 验证范围（诚实标注）

- ✅ 编译零警告；`cj-tauri check` 通过；13 例单测全绿；门禁四道闸全绿
- ✅ 退出收尾线程实测触发（日志 `窗口已全部退出，开始收尾`）
- ✅ 仓内 vendor 实测可用：`/api/health` → `{"status":"ok","version":"1.6.1","web_port":8765}`
- ⚠️ 窗口渲染在受限宿主（容器/沙箱）里不可验证：Chromium 起不了子进程 → `0x8000ffff`；
  需在普通桌面会话运行（开发机已验证窗口标题 `灵渠迁移台 · Lingqu`）
- ⚠️ 鸿蒙端 HAP 尚未构建验证

---

## [0.1.1] - 2026-10-28

### Added

- `vendor/cjh/win-x64/`：内置 cjh 产物（`cjh.exe` + 3 个运行时 DLL）+ `SHA256SUMS`
- `tools/vendor-cjh.ps1`：重新灌入 cjh 产物并重算校验
- `scripts/run-dev.ps1`：一条命令配齐运行前提（四段 PATH / 工作目录 / cjh 指向），支持 `-Sync` / `-Build` / `-Cjh`
- `docs/开发环境.md`：环境变量表 + 踩坑索引（按报错原文）

### Fixed

- **`.ps1` 存为 UTF-8 BOM**：Windows PowerShell 5.1 读无 BOM 的脚本按 GBK 解码，
  中文注释会把字符串引号撑坏，报「数组索引表达式丢失或无效 / 字符串缺少终止符」
- `.gitignore` 放行 `vendor/cjh/win-x64/*.dll`（运行时依赖，不是构建产物）
- cjh 版本号纠正：实测 `/api/health` 回报 **1.6.1**（原按 cj-tauri 仓里的 1.5.3 写成）

---

## [0.1.0] - 2026-10-28

### Added

- cj-tauri 2.0 工程骨架：业务包（static）+ `targets/desktop` + `targets/ohos`，`cj-tauri check` 通过
- 七步流程导航（项目 / 画像 / 依赖 / 改造 / 构建 / 验证 / 报告），中栏 + 右栏 Agent Dock
- **环境体检** `t2h:env`：Rust / llvm-mingw / OHOS NDK / DevEco / hvigor / ohpm / hdc / cjh 八项
- cjh 探测与拉起（当时的精简版：TCP 探测 + `launchHidden`）
- 方案文档沉淀：`docs/需求.md`、`docs/产品方案.md`、`docs/技术思路.md`、`docs/ui-mockup.html`
