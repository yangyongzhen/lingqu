# P5 流水线 · Linux 首跑执行方案（环境就绪直接照做）

> **定位**：P5 的代码早已落地（`src/compiler/*`，Windows 上 3 样本跑到真机验证）——本方案
> 不是"设计实现"，而是**把 Linux 这台机器的环境补齐、把 9 步 CLI 首跑取证**的执行清单。
> 形态与 `docs/P3-出口判据1-验证方案.md` 相同：口径、步骤、判据都先钉死，环境就绪直接照做。
>
> **本机探测结论（2026-11-02 实测，见 §1）**：rust + ohos target ✅、node ✅；
> OHOS SDK **断链** ❌（`/opt/ohos-sdk` 符号链接指向不存在的 `/root/ohos-sdk/linux/`）、
> java / hdc / hvigorw ❌——需按 §2 补装后才能首跑。

---

## 0. 流水线与判据总览（P5 出口判据原文 → 取证方法）

| 出口判据（路线图 P5） | 取证方法 | 现状 |
|---|---|---|
| ① 一条命令从源码到真机启动成功（hdc 设备在线） | `lingqu-cli migrate --path <工程> --wait`（或逐条 CLI）→ 真机 hilog 无崩溃 | Windows 已验（0.21.0/0.36.0）；**Linux 未跑** |
| ② `.so` 指纹与 `dist/` 一致；HAP 内无 `rawfile`；**版本号与 `cj-tauri.toml` 一致** | build/hap 产物落档断言；**版本号一项此前未单独断言——本方案 §3.2 补上** | 部分（前两项已取证） |
| ③ 故意只改前端不重编 `.so`，**校验必须报错** | 单测三场景已覆盖（一致 pass / 新前端没打包 fail / 旧 .so fail）；Linux 上真跑一遍 | 单测已验；Linux 实跑待做 |

**与 P3 判据 1 的衔接**：`build` 步骤的完整 stderr 落 `.lingqu/build/<工程>.log`——
交叉编译跑通后，直接按 [`docs/P3-出口判据1-验证方案.md`](P3-出口判据1-验证方案.md) §3 八步对
依赖矩阵预测力（Recall ≥80%）。**一次环境投入喂两条判据。**

---

## 1. 环境现状（本机实测，2026-11-02）

| 依赖 | 现状 | 结论 |
|---|---|---|
| cargo / rustc | **1.96.0** ✅ | 可用 |
| rustup target `aarch64-unknown-linux-ohos` | **已装** ✅（且 armv7/x86_64-ohos 也在） | 可用 |
| Linux 宿主 toolchain channel | 默认 GNU 即可（**不需要 gnullvm**——那是 Windows llvm-mingw 的事，见 [`skills/t2h-ohos-port/references/toolchain.md`](../skills/t2h-ohos-port/references/toolchain.md)） | 可用 |
| OHOS SDK（native llvm/clang + sysroot） | ❌ **断链**：`/opt/ohos-sdk/sdk/default/openharmony/native` → `/root/ohos-sdk/linux/native`（**目标不存在**） | **重装** |
| node | **v22.22.0** ✅ | 可用（hvigor 走 npm 装） |
| java（hap-sign-tool 需要） | ❌ 未装 | **补装** |
| hdc | ❌ 未装 | **随 SDK toolchains 补** |
| hvigorw | ❌ 未装 | **补装**（@ohos/hvigor npm 包或 SDK 内置） |

---

## 2. 环境就绪清单（按序补装，每项带验证命令）

### 2.1 OHOS SDK（native + toolchains）

断链修复二选一：① 拿到 SDK 包后解压到 `/root/ohos-sdk/linux/`（恢复符号链接语义）；
② 删掉 `/opt/ohos-sdk` 断链，直接解压到新目录并让环境变量指向它（**推荐**——路径可自查）。

```bash
# 装完后的目录形态（OpenHarmony SDK：
#   native/   = llvm/bin/clang、sysroot/          → NATIVE_OHOS_SDK
#   toolchains/ = hdc                              → PATH
NATIVE_OHOS_SDK=<sdk>/default/openharmony/native
export PATH="$PATH:<sdk>/default/openharmony/toolchains"
```

**验证**：

```bash
"$NATIVE_OHOS_SDK/llvm/bin/clang" --version          # 输出 clang 版本（target 明细可带 ohos）
ls "$NATIVE_OHOS_SDK/sysroot/usr/lib/aarch64-linux-ohos" | head -3   # sysroot 就位
hdc version                                          # hdc 就位
```

### 2.2 java（签名用，hap-sign-tool 依赖）

```bash
apt install -y openjdk-17-jre-headless               # 或用 DevEco 自带 jbr 指 JAVA_HOME
java -version
```

> 若走 `sign --auto`（AGC 云生成，路线 A），java 由签名工具调用；AGC 授权在浏览器做一次，
> token 缓存后免浏览器（详见 [`docs/自动签名实战复盘.md`](自动签名实战复盘.md)——**六个坑先读**）。

### 2.3 hvigor（HAP 装配）

```bash
cd <目标工程>/gen/ohos && npm install --save-dev @ohos/hvigor @ohos/hvigor-ohos-plugin
# 或 SDK 内置 hvigorw：找到 <sdk>/.../hvigor/bin/hvigorw.js 后由 hap.cj 以 node 调起
```

**验证**：`lingqu-cli hap --path <工程>` 走到 `assembleHap` 阶段不再报"找不到 hvigorw"。

### 2.4 环境变量汇总（放 profile 或每次 export；`lingqu-cli env` 可体检）

```bash
export NATIVE_OHOS_SDK=<sdk>/default/openharmony/native
export PATH="$PATH:$NATIVE_OHOS_SDK/../toolchains"     # hdc
export JAVA_HOME=<java 根>                             # 签名
export DEVECO_SDK_HOME=<sdk>/default                   # 签名工具找 hap-sign-tool.jar（Linux 布局待核，见 §5 风险 1）
```

> **为什么四个变量都要**：`compiler/hap.cj`、`sign_apply.cj`、`sign_tool.cj` 的查找顺序是
> `DEVECO_HOME` → `DEVECO_SDK_HOME` → `OHOS_HOME` → `NATIVE_OHOS_SDK`（Windows 布局优先），
> Linux 上无 DevEco 目录时**必须显式给出**，缺失报错原文里会点名变量（§4-30 同款排查法）。

---

## 3. 首跑执行序列（选一个**未迁移原始工程**——juCang 或 mark_note）

> 选未迁移工程的理由：**一次首跑同时喂两条判据**——流水线本身（本方案）+ P3 判据 1
> （未迁移依赖树的真实失败点对矩阵预测力）。habit-tree 这类已迁移工程留作第二跑（验证
> "已落 patch → 零失败"）。

### 3.1 逐条跑（每步停一下看判据）

```bash
lingqu-cli scan   --path <工程>   # 画像：C1=100% 且无"未知"才继续（出现未知 = 扫描器缺口，先记）
lingqu-cli deps   --path <工程>   # 依赖矩阵：记下"预测失败集"（P3 判据 1 的输入，勿改工程）
lingqu-cli port   --path <工程>   # 17 条规则：dry-run 看预览 → apply；guide 项逐条决策
lingqu-cli build  --path <工程>   # 交叉编译：.so 产出 + 前端指纹闸 PASS；失败日志进 P3 对照
lingqu-cli hap    --path <工程>   # HAP 装配：点名校验 lib<module>.so；rawfile=0
lingqu-cli sign   --auto --path <工程>   # AGC 自动签名（浏览器授权一次）
lingqu-cli deploy --path <工程> --start  # hdc 装机 + 拉起（真机在线；hilog 四段判据）
lingqu-cli verify --path <工程>   # 功能清单 → 可用率
lingqu-cli report --path <工程>   # 三段式报告 + 风险分级
```

### 3.2 每步判据（不靠退出码，靠落档与输出文本）

| 步骤 | 判据（**全部落档**，字段级） | Linux 特有注意点 |
|---|---|---|
| port | `.lingqu/port/<工程>/decisions.json` + 回滚表；幂等二次跑 applied=0 | 纯函数路径，应无平台差异 |
| build | `.lingqu/tasks.json` artifacts 段：`.so` 大小 + AssetKey；**编译日志全文留 `.lingqu/build/<工程>.log`**（P3 判据 1 输入） | 链接器路径用 `$NATIVE_OHOS_SDK/llvm/bin/clang`（规则 008 生成的 config） |
| hap | `lib<module>.so` 点名校验 PASS；HAP 解包 `rawfile=0`；**版本号断言**：HAP 内 `app.json5` 的 versionName == `cj-tauri.toml` 的 version（**出口判据 ② 的缺口项，本方案补上**） | hvigorw 用 node 调（§2.3）；路径分隔符若报错按 §5 风险 2 |
| sign | `signed=true`；**调试用 debug 态**（release 直装 9568322） | AGC 授权浏览器流程与平台无关 |
| deploy | 输出文本判：`install bundle successfully` + `start ability successfully` + hilog 无 panic | hdc 目录坑：cd 到 HAP 目录再 send（9568269）；真机锁屏 10106102 |
| verify/report | 功能清单三态 + 报告"每个数可追溯到落档" | — |

### 3.3 判据 ③ 的自证（Linux 上重做一遍）

```bash
# 改前端（改 dist 里任一产物）但不重编 .so → build/hap 必须报"指纹不一致"
echo "/* touch */" >> <工程>/dist/assets/<某 js>
lingqu-cli build --path <工程>   # 期望：FAIL，指纹闸报 AssetKey 不一致
# 恢复：重新前端构建 + 重编 .so → PASS（单测三场景的真机口径复验）
```

---

## 4. 首跑后的两份对照（一次环境投入，喂两条判据）

1. **P3 判据 1**：4 样本的 `.lingqu/build/<工程>.log` → 按
   [`docs/P3-出口判据1-验证方案.md`](P3-出口判据1-验证方案.md) §3 八步算 Recall ≥80%；
2. **P5 出口判据**：§3.2 的落档字段逐项打勾 → `docs/需求追踪.md` P5 行状态翻转
   （含补上"版本号一致"断言后 ② 全达成）。

两份对照**共用同一次首跑的日志与落档**，不要分开跑两遍。

---

## 5. 风险预案（Linux 特有，按风险排）

| # | 风险 | 触发信号 | 预案 |
|---|---|---|---|
| 1 | **compiler 代码的 Windows 布局假设**：`hap.cj`/`sign_apply.cj` 的路径拼接与查找顺序按 DevEco Windows 布局写（`\tools\node\node.exe` 等） | Linux 首跑报"找不到 hvigorw / hap-sign-tool.jar"，但环境变量明明设了 | 逐个核对 `firstExistingEnv` 的查找序；**若代码硬编码 `\` 或 `.exe`——这是真 bug，修 compiler 并补单测**（先红后绿）；同时把 Linux 布局结论回写 `docs/开发环境.md` |
| 2 | hvigor 版本/插件与 npm 装的 @ohos/hvigor 不匹配 | assembleHap 阶段报插件解析失败 | 固定版本（与目标工程 `hvigor/hvigor-config.json5` 一致）；或用 SDK 内置 hvigorw |
| 3 | `cargo build` 里 C 依赖（cc crate）找不到编译器 | 纯 Rust 工程没事；带 `-sys` 依赖的工程报 cc 错误 | config.toml 的 `[env]` 段 CC/CFLAGS 已由规则 008 生成；缺则补 `-D__MUSL__` 口径 |
| 4 | hdc 找不到真机 / 无真机 | `hdc list targets` 空 | 首跑可以先到 hap+sign 为止（**不上真机也喂饱 P3 判据 1**）；真机步骤单独排 |
| 5 | AGC 自动签名依赖浏览器授权 | sign --auto 卡在授权 | 用本地 debug 证书走 `t2h:sign` 手动态（judgeSignMode 会给两态判定）；AGC 留到有账号时 |
| 6 | 405 例单测与门禁先于流水线变红 | 门禁挂 | **门禁优先于首跑**——门禁不绿不进 §3（本方案的前提就是 0.39.59 六项全绿） |

---

## 6. 完成后的动作

1. `docs/进度记录.md` 追加"Linux 首跑"一节（现象 → 根因 → 处置 + 落档证据），**Windows↔Linux 差异**逐条回写
   `docs/开发环境.md` 与 AGENTS §4（这是"跨平台一份实现"叙事的实测补强）；
2. README「平台与验证范围」的 Linux 行更新（按实际验证程度，不写"已支持"）；
3. P3 判据 1 对照表（Recall/Precision + 差异解释）→ `docs/需求追踪.md` C2/M2 状态翻转；
4. P5 出口判据 ②的"版本号一致"断言补进回归（此后每轮门禁都验）。
