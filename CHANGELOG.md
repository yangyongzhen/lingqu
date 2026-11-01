# 更新日志

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的结构，
版本号三处一致：`cjpm.toml` / `cj-tauri.toml` / 本文件最新条目（见 `AGENTS.md` §6）。

---

## [0.39.26] - 2026-11-02

**主题**：顶栏在**非最大化窗口**下不再折行/溢出，且**最大化后底部能拉伸对齐**——两个都是布局口径的
硬错误，不是审美问题。

### 现象（用户两轮反馈）

1. 窗口没最大化时，顶部那行字"折叠"了；尤其红字 `未选工程：所有步骤都跑不了` 折成好几行、
   溢出压到标题上。
2. 修完上一条后，**最大化窗口时底部空出一大截**，内容不拉伸到底。

### 根因（两条都不是 CSS 写丑了，是布局基线错了）

1. **红字自己换行**：`#projNote` 没有任何 nowrap/省略约束，而顶栏是固定 48px 的一行 —— 文案一长就折，
   折出来的第二行直接溢出到标题区。1170px 级窗口下 `有 N 个步骤用了别的工程：迁移画像、依赖树…`
   这种句子必然折行。
2. **`.app` 用 grid 固定三行**（`48px auto 1fr`），而第二行的克隆面板默认 `display:none`：
   **`display:none` 的子元素不再是 grid item**，于是 `.body` 落进第 2 行（`auto`），
   第 3 行的 `1fr` 空着没人占 —— 小窗口时 `auto` 恰好等于内容高度所以"看着没事"，
   最大化时才暴露出底部那一大截空白。
3. 顺带发现：`#projPath` 上带着**行内 `style="min-width:260px"`**，行内样式压过样式表，
   我加的 `@media(max-width:1300px){min-width:80px}` 形同虚设 → 1264 宽时工程条仍被撑爆。

### 处置

- 顶栏整条 `flex-wrap:nowrap; overflow:hidden`，`#projBar` 与 `#projPath` 都可收缩（`min-width:0`，
  输入框宽度策略**只写在样式表里**，删掉行内 style）。
- 提示文案改**短句上屏 + 全文进 `title`**：`⚠ 未选工程`、`⚠ N 步用了别的工程`（悬停看详情），
  并给 `#projNote` 加 `white-space:nowrap; text-overflow:ellipsis`（真挤才截）。
- 窄窗按优先级让位：`<1560px` 撤"当前项目"胶囊 → `<1360px` 撤 logo 副标题 → `<1300px` 三个按钮收成
  图标（📁 / ⤓ / ▾，文字进 title）+ 输入框最小宽 80 → `<1120px` 撤"当前工程"标签。
- **`.app` 改成纵向 flex**（`.titlebar`、`#clonePanel` 都是 `flex:0 0 auto`，`.body{flex:1 1 auto;min-height:0}`）：
  隐藏项自然不占位，不再依赖"隐藏后还剩几行"。

### 自动断言（两处一起加，§4-60）

`ui_report` 新增 6 个字段：`topbarH` / `titlebarOverflow` / `projNoteLines` / `projNoteClipped` /
`projNoteText` / `projBarClipped` / `layoutGapBottom` / `bodyH` / `appH`。
判据：`titlebarOverflow=false`、`projNoteLines=1`、`projBarClipped=false`、`layoutGapBottom≈0`。
新增探针模式 **`LINGQU_UI_PROBE=layout`**：把三种状态（未选工程 / 某步覆盖 / 正常）各上报一次。

### 实测（`LINGQU_UI_PROBE=layout`，两份窗口尺寸都跑过）

| 窗口 | 状态 | gapBottom | noteLines | overflow | barClipped |
|---|---|---|---|---|---|
| 1264×801（默认） | 未选工程 | 0 | 1 | false | false |
| 1264×801 | 1 步覆盖 | 0 | 1 | false | false |
| 1264×801 | 正常 | 0 | 0 | false | false |
| 1884×1061（模拟最大化） | 同上三种 | 0 | 1 / 1 / 0 | false | false |

大窗那轮是把 `cj-tauri.toml` 临时改成 1900×1100 跑的，**跑完已恢复 1280×840 并重新 sync**。

### 坑

AGENTS §4-90（grid 固定行 + 隐藏子元素 → 剩余行错位）、§4-91（行内 style 压过媒体查询）。

## [0.39.25] - 2026-11-02

**主题**：选工程从"手敲路径一条路"变成**三条路并存**（手敲 / 原生目录框 / 从 Git 克隆），
并把左栏各屏那 8 个回显框做成**一眼看出不是输入框**的样子。

### 起因（用户反馈）

> 「当前工程旁边有个输入框，左侧迁移画像/依赖扫描/改造执行/真机验证/迁移报告等界面，还都留着输入框。
> 这些 UI 交互细节让人迷惑。另外，工程路径可否弹出文件选择框来选？或者支持给个网络链接自动 clone？」

### 做了什么

1. **保留手敲**（老习惯不断）：顶部输入框照旧可以粘贴绝对路径。
2. **「选择…」改成原生目录框**：装配框架 `DialogPlugin()`，走 `dialog:pickFolder`
   （框架自带、返回选中目录绝对路径）。**没装配该插件时自动回退到 `prompt`**——
   功能不会因为漏挂插件而消失，`ui_report.pickerUsed/pickerFallback` 能分辨走的哪条。
3. **新增「克隆…」**：从 Git 地址拉下来并自动设为当前工程。
   - 新命令 `t2h:git_clone { url, dir?, depth? }`（`src/git_clone.cj`）；
   - 默认克隆到**工作区根** `LINGQU_WORKSPACES` 或 `~/lingqu-workspaces`，浅克隆 `depth=1`（填 0 = 完整历史）；
   - 三条硬规则：① 参数走 **argv 不经 shell**（URL 里 `&`/`%` 交给 shell 必被吃掉，见 §4-80）；
     ② URL 先过白名单（https/http/ssh/git/file/git@host:path），**拒绝 `-` 开头**
     （`--upload-pack=…` 这类参数注入）；③ 同名目录**不覆盖**，自动换 `-2`/`-3`；
   - 克隆完给一句"像不像 Tauri 工程"的判断（有 `src-tauri/` / 只有 `package.json` / 都没有），
     只提示不拦截（monorepo 也能继续）。
4. **8 个回显框视觉改造**：加 `echo` 样式（透明底、无边框、灰字），只有被 `✎` 显式覆盖时
   才恢复成输入框外观并可编辑。**值仍存在 input 上**，所以各屏既有的 `$('xxx').value`
   读法一行都没改——这是有意的：改 DOM 结构会牵动十几处取值逻辑，风险远大于收益。
5. `ui_report` 新增 8 个字段（两处一起加，见 §4-60）：`echoInputsTotal / echoInputsEditable /
   echoInputsEchoStyled / pickerUsed / pickerFallback / pickerLastPath / clonePanelOpen /
   cloneUrlFilled`。**`echoInputsEditable` 必须为 0**——界面上不许再"到处都要填路径"。

### 顺带撞到的门禁口径问题

挂 `DialogPlugin()` 后 `cj-tauri check` 报
`已注册命令 dialog:message 未在 capabilities 声明`：插件一次性注册 open/save/pickFolder/message
四条，而命名权限集 `dialog:files` 只覆盖前三条 → 门禁按"已注册 ⊆ 已声明"判红。
现在用 `dialog:default`（四条全覆盖）。**这是框架侧可改进点**：门禁应先展开 permissions 再比对，
否则"用最小权限集"反而过不了门禁。

### 门禁与测试

- 五道闸全绿；单测 **338 例**（+6：URL 白名单、仓库目录名抽取、冲突命名、Tauri 特征提示、
  工作区根兜底、坏地址在起进程前就被拒）。
- 改动后端 + 前端，`targets/` 已重新 sync；版本三处对齐 **0.39.25**。

## [0.39.24] - 2026-11-02

**主题**：m3u8dl-tauri 最后两格补齐（**可用率 80% → 100%**），并修掉「报告结论自己打自己」的读档缺陷。

### 实测证据（同一条链，HarmonyOS PC `3QC0124B20000048`）

| 环节 | 清理前 | 清理后 |
|---|---|---|
| `hap` 闸 | `gates=false`（rawfile 6 条死资源） | **`gates=true`、`rawfileCount=0`、`signed=true`**，包体 8,273,766 → **8,257,155** B |
| `deploy --start` | installed/started 均 true | 仍 `ok=true`，hilog 40 行无崩溃 |
| 界面 | ArkWeb 已渲染 | `uitest dumpLayout` 仍命中本应用窗口 + `Web`/`rootWebArea` + 真实文案（**证明清死资源没影响渲染**） |
| `verify` | pass 4 / fail 1 → 80% | **pass 5 / fail 0 / limit 1 / unknown 0 → 100%** |
| `report` | 结论「可用率 尚未验证」 | **「8 步完成 8/8（100%），核心功能可用率 100%，0 处人工介入」** |

### 做了什么

- **清掉 m3u8dl 的 6 个死 rawfile 条目**（`app.js` / `index.html` / `style.css` 及 hvigor 记录里的镜像条目）：
  前端已在 `.so` 里（`/assets/index.html`、`/assets/app.js`、`/assets/style.css` 在 `.so` 内可见），
  源码（`*.ets`/`*.ts`/`*.json5`）**没有任何 rawfile 引用**——先落这三条证据再动手。
  清理前把 3 个文件**按 SHA256 校验着备份**到 `<工程>/.lingqu/evidence/rawfile-bak-<时间戳>/`。

### Fixed（报告读档，属 §4-75 同族但漏在 `report_feed`）

1. **`collectReportFacts` 全程用相对 CWD 的 `.lingqu/...` 读落档** → 从仓目录跑
   `report --path <别的工程>` 时读到本仓旧档（或读不到）→ 结论写「核心功能可用率 尚未验证」，
   而**同一份报告正文的任务板摘要写着 100%**——一份文档里两个数。
   现在：读按 `resolveLqPath(projPath, …)` 解析，附录仍显示工程内相对路径。
2. **`.lingqu` 前缀被喂给 `resolveLqPath` 会拼出 `.lingqu/.lingqu/...`**（它内部自己补一层），
   `exists()` 永远 false → 所有产物附录消失、可用率读不到。新增纯函数
   `bareLqRel`（剥前缀，两种分隔符都认，且不误伤 `.lingqu-extra/`）+ 单测钉住。
3. 顺带修一处**签名结论过期**：报告里的「签名体检没过」来自自动签名之前的旧落档；
   重跑 `sign --path` 后为 `ok=true / mode=debug / candidateBundleMatch=true`，
   报告因此只剩一条**真实**的提醒（debug 态不能上架）。

### 说明

- 单测 **332 例**（+1：`testBareLqRelStripsLingquPrefix`，含"不能把 100% 说成未验证"的结论口径）。
- 5 道门禁全绿。
- **遗留（口径缺口，非缺陷）**：报告的「0 处人工介入」只数 `port` 决策采纳；
  本轮 AGC 那次**浏览器授权点击**没被计进 A3，属口径未覆盖，已记录在 `docs/进度记录.md`。

## [0.39.23] - 2026-11-02

**主题**：把「跑过但没过」从「没跑过」里分出来——`verify` 之前会把**装配跑过、闸没过**说成
「没跑过装配」，既不诚实，也把一条**可修的失败**藏成了"待办"。

### 实测证据（同一条链跑到底，HarmonyOS PC `3QC0124B20000048`）

| 环节 | 结果 |
|---|---|
| `sign --auto --newKeys` | `ok=true` |
| `hap` | `built=true signed=true hapBytes=8,273,766` |
| `deploy --start` | `installed=true started=true ok=true`，hilog 40 行无崩溃 |
| 前台确认 | `aa dump -a`：`state #FOREGROUND`、Mission #149；`uitest dumpLayout` 里有本应用窗口（focused）与 **ArkWeb 的 `Web`/`rootWebArea` 节点**，且 dump 出真实界面文本（"m3u8dl 多线程下载器 · Rust + Tauri 2 复刻"、"下载配置"、"线程数"、"限速(KB/s)"…） |
| 截图 | `E:\test\rust\m3u8dl-tauri\.lingqu\evidence\m3u8dl-autosign.jpeg`（3120×2080，用户已人眼确认界面正常） |
| `verify` | `pass=4 fail=1 limit=1 unknown=0` → **可用率 80%**；唯一失败是 `hap` 闸（rawfile 死资源） |

### Fixed

- **"跑了没过" ≠ "没跑过"**（AGENTS §4-63 的口径被自己违反了）：`build`/`hap` 两条清单项原来只有
  一个 `xxxOk` 布尔，失败一律写成「没跑过…」。新增 `hasBuild` / `hasHap` 位 +
  `hapBuilt` / `hapSigned` / `hapFirstFailure`：
  - 落档不存在 → `unknown`「没跑过装配」；
  - 跑过但 hvigor 没成功 → `fail`「装配跑过但 hvigor 没成功」；
  - 跑过、包也出来了、是**闸**没过 → `fail`，并把闸门**第一条失败**贴进 note；
  - 跑过且过 → `pass`，证据里列出 `built=true` / `signed=true`。
  交叉编译那条同样处理（`exitCode != 0` 不再显示成"没跑过交叉编译"）。
- 新增纯函数 `firstArrayItemOf`（取闸门 `failures[0]`），单测 +1 例
  （`testRanButFailedIsNotReportedAsNeverRan`，覆盖 hap/build 各自的 跑过未过 / 没跑过 四种分支），
  合计 **331 例**。

### 说明（未验证 / 遗留）

- 剩下的 `fail` 是 **m3u8dl 工程自己的 `rawfile/` 有 6 个死资源**（前端已在 `.so` 里），
  与本轮签名无关；清掉后 `hap` 项即可转 pass（可用率 → 100%）。
- 复盘文档 `docs/自动签名实战复盘.md` 的「当前状态」表已按实测更新（启动/界面从"未验证"改为已验证，
  并补上 `uitest dumpLayout` 这条**可机器断言**的界面证据口径）。
- `README.md` 从 v0.1 骨架叙述整篇重写到当前状态（0.39.23 / 五道闸 / 331 例 / 35 条 `t2h:*` /
  真机实证 / 自动签名一节 / 22 个文档链接逐个核过存在性）。

## [0.39.22] - 2026-11-02

**主题**：**路线 A（AGC 云生成自动签名）真机打通**——`m3u8dl-tauri` 从"没有签名"走到
`signed=true`、**装机成功**（`install bundle successfully`），全程零手工点 DevEco。

### 实测证据（本机，HarmonyOS PC `3QC0124B20000048`）

| 环节 | 结果 |
|---|---|
| `sign --auto --newKeys` | `ok=true`：团队 40574614 → 设备已注册 → 生成密钥对/CSR → 建证书 → debug profile → 写回 |
| `hap` | `built=true signed=true hapBytes=8,273,766 errorCount=0` |
| `deploy` | `installed=true installDetail="install bundle successfully"` |
| `deploy --start` | 装上了但**设备锁屏**拒绝自动拉起（10106102，非签名问题） |

### Fixed（一条链上逐个撞出来的六个坑）

1. **证书"名字对得上"≠"能用"**：AGC 里 `auto_debug_40574614.cer` 名字对、`expireTime` 早已过去
   （`status=2`），拿它申请 profile 被回 `The certList is invalid.`。新增 `AgcCert.expireMs/status/usable()`
   与 `findUsableCert`——按**有效期**挑，不按名字挑。
2. **证书数量上限**：`cert/add` 回 `205389872 certificate number exceeds limit.`（本账号上限 4 张，
   **过期的照样占位**）。新增 `agcCertDelete` + `staleCertsOf`（只删"过期 **且** 名字是
   `auto_debug_*`/`auto_release_*`"的，不碰用户手工建的证书）。
   端点参数位置是实测出来的：删除是 **DELETE + 请求体** `{"certIds":[...]}`（放 query 一律被回
   `Body parameter is required.`），且请求体要带 Content-Length。
3. **同名证书绑的是旧公钥**：换了新密钥对后复用云端同名证书 → profile 里的证书与 `.p12` 对不上。
   现在 `--newKeys` 会先删同名旧证书再新建，并**强制重下**本地 `.cer`（本地那份是旧证书）。
4. **写回被自己的保护挡住**：工程里已有 `signingConfigs` 时旧实现一律拒绝，
   于是整条链死在第 ⑦ 步。新增 `replaceOwnSigningConfigs`（**同一套材料才就地更新**，
   换材料仍拒绝）+ 抽出共用的 `locateSigningArray`（按深度配对，跳过 json5 字符串）。
5. **`.p12` 的口令没人知道**：材料来自别处 / `material/` 重建过时，旧密文解不开
   （`GCM tag mismatch`）→ hvigor 报 `00303242 Signature material verification failed, as:
   Unsupported state or unable to authenticate data`。新增 `--newKeys`（旧材料**改名留底**后重生成），
   自己掌口令 → 自己加密 → hvigor 解得开。
   `DEVECO_SDK_HOME` 没设时按 `DEVECO_HOME/sdk` 推导出 `hap-sign-tool.jar` 位置。
6. **`9568332 install sign info inconsistent`**：同包名已装过另一套签名的版本（重签后必然撞上）。
   `deploy` 现在自动 `bm uninstall` 后重试一次并记进证据；`10106102`（锁屏）的结论文案也改对了
   （原来一律怪"ability 名写错"）。

### Added

- `sign --auto --newKeys`（`LINGQU_SIGN_NEWKEYS=1`）：丢弃并重生成材料。
- `t2h:sign --tool-check`（0.39.20 起）：自检 java / `hap-sign-tool.jar` / hdc，并真生成一对密钥验通路。
- 单测 +5 例（`usable()` 与过期挑选手法、`staleCertsOf` 只挑自己的、`replaceOwnSigningConfigs`
  就地更新/拒绝换材料/空数组分流），合计 **330 例**。

### 说明（未验证 / 遗留）

- **应用启动与界面未验证**：设备锁屏（开发者模式禁止自动解锁），`aa start` 报 10106102。
  装机已成功，启动与 `verify` 需解锁后重跑。
- `hap` 闸仍报 `rawfile/` 有 6 个死资源（前端已编进 `.so`）——与本轮签名无关，属 m3u8dl 工程的清资源待办。
- **复盘文档**：`docs/自动签名实战复盘.md`（全链路、六个坎的现象→根因→处置、可复跑手册、
  协议细节表、复用清单、边界）；`skills/t2h-ohos-port/references/signing.md` 同步更正
  "口令密文只能搬"的旧结论并补上路径 C 的用法。

## [0.39.21] - 2026-11-02

**主题**：AGC 云侧四处"字段名/编码"错误——它们让设备与证书这两步**看着成功其实没用**。

### Fixed

- **设备列表解析**：AGC 真正用的字段是 `list`（`devicesInfo`/`devices`/`deviceList`/`deviceInfos`
  全不存在）→ "设备已注册"永远判成没注册，随后 `device/add` 报 `205389858 UDID is repeat`。
- `205389858`（UDID 重复）**按已注册处理**：语义上就是"已经好了"，不该当失败。
- **profile 的 `deviceList` 要云端设备 id**：传 UDID（64 位）被拒
  （`deviceList[0].<list element>: size must be between 0 and 32`）。
- **证书下载 403**：AGC 给的是 SigV4 签名链，通用 HTTP 客户端会重新编码 query 使签名失效；
  改为**原样用系统 curl**取字节，再校验 sha256 落盘。

## [0.39.20] - 2026-11-02

**主题**：`sign --tool-check` —— 先把"别人的安装目录里那三样东西"体检清楚。

### Added

- `t2h:sign --tool-check`（`LINGQU_SIGN_TOOLCHECK=1`）：逐项报告 java / `hap-sign-tool.jar` / hdc
  是否存在、在哪、版本，并**真生成一对密钥再删**（证明它不只是"文件在"）。

## [0.39.19] - 2026-11-02

**主题**：把「回调判定」抽成纯函数并**放宽到只认 quit**——连续三次登录失败都出在"一次异常回调
弄死整次会话"，以及"_回调页被用户手动打开_"。

### Fixed（三个实测出来的坑）

1. **缺 `tempToken`/`siteId` 的回调会终止会话**：浏览器/华为页面的预检跳转就是这种形态——
   实测进程当场退出、端口不再监听，用户再登录必然失败。现在**只有显式 `quit` 才终止**。
2. **`code` 不一致硬拒绝**：华为回调里自带它自己的 `code`，与我们的防伪 code 天然不同 →
   正常登录被我们判成 `Bad code`。现在 `code` **只核对不拒绝**（安全边界改为：
   只绑 `127.0.0.1` + 一次性服务 + Host 白名单 + tempToken 仍要过华为校验）。
3. **`/callback` 被用户手动打开**（连续两次）：回调页现在**直接给出可点的登录页链接**，
   并写清"这是内部地址，别手动开"。

### Added

- `judgeCallback(code, tempToken, siteId, quit, expectCode)` **纯函数**（+`CallbackVerdict`）：
  三条规则一处实现，handler 只执行动作；4 例单测覆盖（正常 / code 不一致仍放行 /
  缺参数与非大陆站点只忽略 / 只有 quit 终止），合计 **325 例**。
- 回调证据落文件：`~/.lingqu/agc/login-callback.log`（记 code 长度、siteId、code 是否匹配——
  **不记 tempToken 明文**），下次出问题不用再靠猜。

### 说明（仍未验证）

真实授权仍未完成（本轮结束时重新起了一次登录并给出链接）。因此 AGC 侧（团队/设备/证书/profile）
与 `m3u8dl-tauri` 的 `signed=true` 都还没发生。
## [0.39.18] - 2026-11-02

**主题**：自动签名的**编排层**落地——登录之后的一整条链现在是一条命令。
（真实授权仍未完成，所以 `signed=true` 还没拿到；代码已就位，token 一到即可连跑。）

### Added

- `src/compiler/sign_apply.cj`：
  - `autoSign(inp, token)`：① 令牌 → ② 团队 → ③ 设备（已注册跳过 / 否则注册）→
    ④ 材料命名 + 本地没有 p12 就 `hap-sign-tool` 生成密钥与 CSR → ⑤ 证书（按 `auto_debug_<teamId>.cer`
    精确复用，没有就用 CSR 新建并下载 .cer）→ ⑥ 按**新包名**申请 debug profile（带 deviceList）→
    下载 `.p7b` → ⑦ 用 `material/` 加密口令 → `applySigningConfig` 写回（先 `.bak`）
  - `AutoSignOutcome`：**逐步日志**（一行一步）+ 各文件路径 + `passwordLen`（只回长度，绝不回口令）
  - 复用旧 p12 时沿用工程里现有的口令密文；没有现成密文就要求删掉 p12 重新生成（不猜口令）
  - 每一步失败都带"是哪一步"，不出"跑完了但不知道哪步没做"的结果
- `t2h:sign --auto --path <工程>`（或 `LINGQU_SIGN_AUTO=1`）：组装 `bundleName`（AppScope）、
  UDID / deviceType（hdc）、令牌（`~/.lingqu/agc`），跑完整编排并按 JSON 回投。
- 2 例新单测（无令牌必须**秒级**报"先去登录"且一步不走；`AutoSignOutcome` 落档结构里不得出现口令），
  合计 **321 例**。

### 说明（仍未验证）

真实账号授权尚未完成（等一次浏览器点击）。因此 `autoSign` 的网络部分（团队/设备/证书/profile）
在本机**还没有真跑过**；`m3u8dl-tauri` 的 `signed=true` 尚未发生。
已就位并可复跑的离线证据仍是 0.39.16 的那条：**hvigor 能解开我们造的 AesGcmKit 口令密文**。
## [0.39.17] - 2026-11-02

**主题**：修掉「登录链接被 shell 拆开」这个真 bug——它就是用户"网页登录失败"的直接原因。

### 现象与根因

用户点登录链接后网页侧失败。查日志发现浏览器**只拿到了截断的地址**：

    openUrlInBrowser → `cmd /c start "" <url>`
    'appid' is not recognized as an internal or external command,
    'code' is not recognized as an internal or external command,

登录 URL 是 `…/apply?port=21570&appid=1009&code=<32位hex>`——`cmd` 把 **`&` 当命令分隔符**，
于是 `start` 只打开 `…?port=21570`，后面几段被当作命令执行。用户看到的是一个残缺链接的失败页。

### Fixed

- `openUrlInBrowser` 在 Windows 上改用 **`rundll32 url.dll,FileProtocolHandler <url>`**：
  不经过 cmd 的命令解析，URL 原样交给系统；其它平台仍用 `xdg-open` / `open`（按 argv 收参，无此问题）。
- 新增断言把这件事钉住（`testLoginUrlCarriesAmpersands`）：登录 URL 必须同时含
  `?port=<n>&`、`&appid=1009&`、`&code=<hex>` 三段——将来谁改拼装逻辑，少一段就红。

### 说明（仍未验证）

真实账号授权仍未完成（本轮结束时重新起了一次登录，链接已给用户）。
`m3u8dl-tauri` 的 `signed=true` 尚未发生。
## [0.39.16] - 2026-11-02

**主题**：**证明我们的 AesGcmKit 口令密文 hvigor 真能解开**——这是"全新生成签名材料"路上最后一个
未知数。附 `hap-sign-tool` 的定位与调用（生成密钥对与 CSR）。

### 决定性实验（本机实测，可复跑）

    # ① 用我们自己的实现重加密 habit-tree 现有口令密文（新 IV，同一口令）
    lingqu-cli sign --reencrypt --buildProfile E:\test\rust\habit-tree\src-tauri\gen\ohos\build-profile.json5
      → ok=true  storePwdLen=10  keyPwdLen=10  newStorePasswordPrefix=0000001af150…
      原密文前缀 0000001ABCEAD81D… → 新密文前缀 0000001af15004076fb1…（确实变了）

    # ② 让 hvigor 去解「我们造的密文」
    lingqu-cli hap --path E:\test\rust\habit-tree
      → hvigor Finished :entry:default@SignHap… after 2s 578ms
      → hvigor BUILD SUCCESSFUL in 14s 175ms
      → built=true signed=true hapBytes=7,249,832 gates.ok=true
    # 实验后 habit-tree 的 build-profile.json5 已还原（.bak 删除）

结论：**命令里那串口令密文可以完全由我们自己生成**，hvigor/DevEco 解得开——不必再"抄别人的密文"。

### Added

- `src/compiler/sign_tool.cj`（`hap-sign-tool.jar` 的定位与调用）：
  - `javaCandidates`（`JAVA_HOME` → DevEco JBR → PATH）/ `hapSignToolCandidates`（SDK 三档布局 +
    数字版本目录降序）/ `firstExisting`
  - `randomPasswordAlnum`（8 随机字节 → base64url → 去 `-_=`，纯字母数字、7~10 位，与 flutter 同规则）
  - `keypairArgs` / `csrArgs`（**`generate-keypair` 没有 `-outFile`，`generate-csr` 才有**）
  - `maskSecrets`：日志里把 `-keystorePwd` / `-keyPwd` 后面的值替换成 `******`
  - `genKeypair` / `genCsr` / `runSignTool`（失败带 exit 码与日志尾部）
- `t2h:sign --reencrypt`（或 `LINGQU_SIGN_REENCRYPT=1`）：读 `material/` → 解出原口令 → 用新 IV
  重新加密 → 写回（先留 `.bak`）；只回**口令长度**与前缀，绝不回明文。

### 说明（仍未验证）

真实账号授权未完成（等一次浏览器点击）。因此"用 AGC 侧给新包名签发的 profile + 我们自己生成的
密钥/口令"这一整条，还差最后一段；`m3u8dl-tauri` 的 `signed=true` 尚未发生。
## [0.39.15] - 2026-11-02

**主题**：AGC 云侧动作（设备 / 证书 / profile / 安全下载）落地——登录之后的整条链已经写完，
只等一次真实授权即可连跑。

### Added

- `src/compiler/sign_cloud.cj`
  - **纯函数**（全部单测）：`parseDeviceList` / `deviceRegistered`（UDID 大小写不敏感）/
    `parseCertList` / `findCertByName`（命名是确定性的，所以"要不要新建"= 一次名字精确匹配）/
    `deviceTypeOf`（`liteWearable` 必须先于 `wearable` 判，否则子串会吃掉前者）/
    `buildDeviceAddBody` / `buildCertAddBody` / `buildProvisionBody`（`deviceList` 只在 debug 带、
    空 ACL 不带该键）/ `parseProvisionAdd` / **`isSafeDownloadUrl`**（SSRF 护栏）/
    `upperAscii` `lowerAscii` `digitsOnlyValue`
  - **动作层**：`agcDeviceList`（分页 start=1 起、每页 100）/ `agcEnsureDevice`（已注册就跳过，
    名字重复自动换 nonce 重试一次）/ `agcCertList` / `agcCertAdd` /
    `agcDownloadObject`（`objects/url/reapply` 换临时链 → **先校验 sha256 再落盘**）/
    `agcProvisionDebug`（申请 → 下载 `.p7b` → **下载完立即删云端 profile**，与 flutter 一致）
- 8 例新单测（`src/tests/sign_cloud_test.cj`），合计 **318 例**。

### Fixed（单测当场抓到的两个真缺陷）

1. **SSRF 护栏漏判 IPv6 字面量**：按第一个 `:` 切 host 时，`https://[::1]/a` 会被切成 `[`，
   于是"本机回环"没被拦住。改成：带方括号的 IPv6 整段取到 `]`；其余含 `:` 的 host 一律拒（不猜）。
2. **一次错 code 的回调会废掉整次登录**（`sign_login.cj`）：Host 不合规 / code 不匹配以前都会
   `done.store(true)` 终止会话——实测代价是：上一轮贴给用户的登录链接在会话重启后 code 变了，
   用户仍点旧链接 → 整次登录被判失败。现在这两种情况**只回 400 并继续等**（只有 `quit` 才终止）。

### 说明（仍未验证）

真实账号授权**还没完成**：本轮结束时重新起了一次登录（新的 code），等人点击。
因此 jwtToken 校验之后的团队/设备/证书/profile 申请、以及 m3u8dl-tauri 的 `signed=true` 尚未发生。
另：`hap-sign-tool` 的 keypair/CSR 生成（全新材料的路径）也还没接。
## [0.39.14] - 2026-11-02

**主题**：路线 A 的**登录环节**落地——OAuth loopback（本机回调 + 防伪 code + Host 白名单）→
tempToken→JWT → JWT 校验 → 令牌加密落盘 → 团队列表。第一次需要人在浏览器里点一次授权。

### 自测证据（本机实测，无需账号即可验证链路）

    # 起服务后 /callback 的三条路径
    错误 code（伪造回调）  → 400 "Bad code"（客户端报「回调 code 与本机生成的不一致」，并终止）
    未知路径 /nope          → 404
    正确 code（假 tempToken）→ 302 跳 loginSuccess；随后客户端去打
                              https://cn.devecostudio.huawei.com/authrouter/auth/api/temptoken/check
                              返回 200 但响应不是 JWT → 我们按"不是 JWT"如实拦住：
                              「换 JWT 失败：HTTP 200，响应不是 JWT」
    端口获取：`port(0)` 由系统分配，必须 `afterBind` + SyncCounter 等绑定完成再读，
              一开始就读会拿到 0（实测踩到，已按此改）

### Added

- `src/compiler/sign_login.cj`：
  - `agcLogin(timeoutSec, openBrowser)`：阻塞式登录（起服务 → 打印/打开登录页 → 等回调 → 换 JWT →
    校验 → 拉团队），返回 `AgcLoginOutcome`（含 `port` 与逐步 error，排障一眼看出卡在哪）
  - `LoginCallbackHandler`：只认 `/callback`；Host 白名单 `127.0.0.1:<port>` / `localhost:<port>`；
    `code` 必须与本机一致；`siteId != "1"` 拒绝（只支持大陆站点）；`quit` 走失败页
  - `randomHex32` / `loginPageHtml` / `openUrlInBrowser`（Windows `cmd /c start`）
  - 令牌加密落盘：`~/.lingqu/agc/{keys/kek.bin, token.enc}`，AES-128-GCM（复用 0.39.13 的实现），
    信封 `{version, algorithm, iv, ciphertext, tag}` 全 hex；`loadAgcToken` 解不开就返回 None（要求重登）
  - `agcTeamList`：默认取第一个团队（与 flutter 的 `teams.first.id` 一致）
- `t2h:sign` 新增 `--login`（或 `LINGQU_SIGN_LOGIN=1`）：只做登录并落盘令牌，不走体检；
  探针 `LINGQU_SIGN_LOGIN_CODE`（自测时固定 32 位 code）、`--noBrowser`、`--timeout`。
- CLI 增加 `lingqu-cli sign --login` 的用法说明与调用路径。
- 4 例新单测（code 形态与随机性、成功/失败页文案、用户摘要不含 token），合计 **311 例**。

### 说明（仍未验证）

真实账号的登录**尚未完成**（本轮起好了服务并给出登录链接，等人授权）。
因此 jwtToken 校验、团队/设备/证书/profile 申请、以及 m3u8dl-tauri 的 `signed=true` 都还没发生。
## [0.39.13] - 2026-11-02

**主题**：把「口令密文」这一环打通——**纯仓颉 AES-128-GCM + hvigor AesGcmKit 兼容**。
这是路线 A 里最容易"静默失败"的一步：算错一位，hvigor 只会说"签名失败"，不会说 GCM 错了。

### 决定性验证（本机实测，两边独立实现互证）

    # 用本机现成的 ~/.ohos/config/material 解 habit-tree 已有口令密文
    仓颉实现（src/compiler/aes_gcm_kit.cj）：loadWorkKey + decryptPasswordHex → 通过（GCM 认证过了）
    Node 实现（DevEco 自带 node，走 OpenSSL）独立复算：
      workKey     = b730dc2388f8e70c645ac48fea7f22e4
      storePassword → "LtjnTDt7h8"（10 位字母数字，与 flutter 随机口令形态一致）
      keyPassword   → "LtjnTDt7h8"
    → 两边逐字节一致 ⇒ 我们**能自己生产 hvigor 解得开的口令密文**，不必再"抄别人的密文"

### Added

- `src/compiler/aes_gcm.cj`：**纯仓颉 AES-128-GCM**（296 行）。
  为什么自己写：仓颉 std / stdx 1.0.5.1 **没有 AES**——`stdx.crypto.crypto` 只给 `SM4`，
  标准库 `std.crypto.cipher` 只有 `BlockCipher` 接口；且本机实测 **SM4-GCM 直接抛**
  `CryptoException: Encrypt failed due to create tag error`（CBC/ECB/CTR 才可用）。
  实现用 NIST SP 800-38D 的 TC1/TC2/TC4 向量核对（期望值又用本机 Node/OpenSSL 独立复算），
  另测非 96bit nonce、多块、tag 篡改拒绝、换 key 拒绝。
- `src/compiler/aes_gcm_kit.cj`：AesGcmKit 兼容层
  - `hmacSha256` / `pbkdf2HmacSha256`（stdx 没有 PBKDF2，自写；4 组公开向量核对）
  - `lossyUtf8Bytes`：非法 UTF-8 序列 → U+FFFD（Node `toString('utf8')` 同语义；
    不做这一步 rootKey 必然不对）
  - `loadWorkKey(materialDir)`：读 `material/{ac,ce,fd/0..2}`（每目录恰好 1 个文件）→
    `PBKDF2(10000,16)` → AES-GCM 解出 workKey；错误逐条带原因
  - `encryptPasswordHex` / `decryptPasswordHex`：载荷 `[len(4BE)|IV(12)|ct|tag(16)]` → hex
  - `randomBytes`（`SecureRandom`：**注意 `nextBytes(buf)` 是填缓冲区，不是给长度返回数组**）
- 8 例新单测（AES 4 + kit 4），合计 **310 例**。

### 说明（仍未验证）

路线 A 的**联网部分**（OAuth 登录、团队/设备、证书、profile）仍未写；本轮只把"材料生产"里
最危险的密码学环节做穿。`m3u8dl-tauri` 的 `signed=true` 尚未发生。
## [0.39.12] - 2026-11-02

**主题**：自动签名「路线 A」（AGC 云生成）开工，第一批落地的是**纯函数地层**：
材料命名规则、口令密文的载荷布局、hex 编解码。都可在本机自证，不联网、不碰云端资产。

### 本轮确证的三个事实

1. **材料命名规则与本机磁盘逐字一致**（这是"复用 DevEco 已有材料"的地基）：
   `~/.ohos/config/{safeProduct}_{工程目录名}_{base64url(sha256(前向斜杠工程路径)) 去 padding}=.{p12|csr|cer|p7b}`
   - 实测：`sha256("E:/test/rust/habit-tree/src-tauri/gen/ohos")` → `m7Gxh5QRtg0h6LnDjtArCp3iYObE9iWm8BEssdAfmHM`，
     与磁盘上的 `default_ohos_m7Gxh5QR….p7b` 完全一致；换成反斜杠路径算出 `EuNnZ1gj…`（反例）→ 印证"hash 必须用前向斜杠"。
   - 文件名里 hash 与后缀之间那个 **`=` 是字面分隔符**，不是 base64 填充。
2. **AesGcmKit 载荷布局已钉住**：`[len(4B 大端)=|ct|+16 | IV(12) | ct | tag(16)]` → 小写 hex；
   `material/{ac,ce,fd/0..2}` 各恰好 1 个文件；固定分量 `31 f3 09 73 d6 af 5b b8 d3 be b1 58 65 83 c0 77`；
   `rootKey = PBKDF2-HMAC-SHA256(utf8(有损解码(XOR(fd0,fd1,fd2,固定分量))), salt, 10000, 16)`。
3. **仓颉侧缺 AES-GCM 原语**（重要，影响方案）：
   - `stdx.crypto.crypto` 只暴露 `OperationMode` / `PaddingMode` / `SecureRandom` / **SM4**（`GCM` 只是 SM4 的模式之一）；
   - 标准库 `std.crypto.cipher` 只有 `BlockCipher` **接口**（`encrypt`/`decrypt`），没有 AES 实现；
   - `stdx.crypto.digest` 的 `HMAC` 可用（`HMAC(key) { => SHA256() }` 编译通过），故 PBKDF2 可自写；
   - `stdx.net.http` 有 `ServerBuilder` / `HttpServer` / `TcpServer` → OAuth loopback 回调服务可行。
   → 两条可选路：**(a)** 自实现 AES-128 + GCM（约 300 行，可用 .NET `AesGcm` 生成权威测试向量对拍）；
   **(b)** 复用本机已有一套 p12/cer（连口令密文一起搬），只向 AGC 申请**新包名的 profile** —— 这样完全不碰 AES，更快通到 `signed=true`。

### Added

- `src/compiler/sign.cj`「材料生产」一节（纯函数，全部单测覆盖）：
  - `b64UrlNoPad()`（自带 base64url 编码；仓库原本只有解码）
  - `forwardSlashPath()` / `projectPathHash()` / `sanitizeSignName()` /
    `signingFileBaseName()` / `signingMaterialFileName()`
  - `toHexLower()` / `fromHexLower()` / `packGcmPayload()` / `unpackGcmPayload()`
  - 常量：`AES_GCM_IV_LEN` / `AES_GCM_TAG_LEN` / `AES_GCM_KEY_LEN` / `PBKDF2_ITERATIONS` / `SIGN_NAME_MAX_LEN`
- 6 例新单测（命名 hash 与磁盘一致 / 反斜杠反例 / 文件名那个 `=` / sanitize 边界 / hex 往返 / 载荷布局与异常长度），
  合计 **296 例**。
- 文件头注释同步纠正：口令不再只能"从别处搬"，`material/` 本机就有（见路线 A）。


### 追加（同一轮）：AGC 协议层与 HTTP 客户端骨架

- 新增 `src/compiler/sign_agc.cj`（路线 A 的协议层）：
  - **纯函数**：`oauthLoginUrl` / `tempTokenCheckUrl` / `jwtCheckUrl` / `agcUrl` / `loginRedirectUrl` /
    `isChinaSite` / `isJwtShaped` / `parseQueryParams` / `urlEncode` / `urlDecode` /
    `certNameFor`（`auto_debug_<teamId>.cer`）/ `provisionNameOf`（`sha256("p_b_b")[0:16]`）/
    `agcSucceeded`（判 `ret.code==0`）/ `agcErrorCode` / `agcErrorMsg`（`msg` 两种形态都认）
  - **动作层**：`agcHttp(method, url, headers, body, timeout)`、`ohosConfigDir` / `agcStateDir` / `agcTempDir`
- 6 例新单测（`src/tests/sign_agc_test.cj`），合计 **302 例**。`provisionNameOf` 的期望值来自
  **独立的 SHA256 计算**（PowerShell），不靠自证。

**从实测里学到的三条硬约束**（已写进代码注释，避免下次再踩）：

1. **HTTPS 必须显式 `tlsConfig(TlsClientConfig())`**，否则 `HttpException: TLS must be configured…`；
2. **必须 `.noProxy()`**——客户端默认读系统 `http_proxy/https_proxy`，否则连本机回环都可能被送去代理；
3. 响应体是 `InputStream`，用 `StringReader(resp.body).readToEnd()` 取字符串并 `close()`；且
   **lambda 不能捕获 `var` 局部变量**（loopback 回调要把结果带回主线程，得用类实例字段）。
### 说明（未验证的部分）

路线 A 的**联网部分**（OAuth 登录、团队、设备注册、证书、profile 申请与下载）本轮**一行未写**，
因此"自动签名打通 m3u8dl-tauri"尚未发生；本轮只有离线地层与事实核对。
`docs/鸿蒙自动签名机制.md` 已有的端点/流程与本轮实现一致，无需改口径。
## [0.39.11] - 2026-11-01

**主题**：把「签名不对」从**分钟级的白等**变成**秒级的说清**，并修掉一个让落档整块消失的建目录缺陷。
背景是上一轮把根因钉在「profile 按包名签发」之后，剩下的成本问题：`t2h:hap` 仍要先跑 `hvigor assembleHap`，
而包名不匹配这件事在跑之前就能判。

### 实测证据（Windows x64 · 鸿蒙 PC 在线）

    # ① 预检拦下（把 m3u8dl-tauri 的 signingConfigs 指向本机现存但**别的包名**的材料）
    lingqu-cli hap --path E:\test\rust\m3u8dl-tauri
      elapsed = 1s（此前要跑完 hvigor：约 3 分钟才拿到同一条 00303074）
      signPreflightBlock  = true
      signPreflightReason = 工程包名 `com.atomgit.m3u8dl_tauri` 与已配签名材料的包名
                            `com.yang.testcj` 不一致（hvigor 必然报 00303074，一个产物都不会有）…
      gates.failures      = 「HAP 闸（签名预检，已拦下）：…」       ← 落档 .lingqu/hap/<工程>.json
      （实验后已把样本 build-profile.json5 还原，storeFile 仍指向原路径）

    # ② 正常路径不受影响（habit-tree 包名匹配）
    lingqu-cli hap --path E:\test\rust\habit-tree
      signPreflightBlock=false · built=true · signed=true · gates.ok=true

### Fixed

- **落档整块丢失（5 个样本里 3 个中招）**：`ensureDirOf` 逐段 `Directory.create(Path(part))` 在
  「工程的 `.lingqu` 还不存在」时抛 `Failed to create directory …\.lingqu\sign, parent …\.lingqu does not exist`，
  于是 `t2h:sign` 的 `.lingqu/sign/<工程>.json` 一个都写不出来（cc-switch-harmonyos / atomMqtt /
  tauri-mqtt-client-ohos 实测）。改为优先 `Directory.create(Path(dir), recursive: true)`（与
  `saveTaskBoard` 同一种写法），失败再退回逐段创建——修后三份落档分别 4445 / 3736 / 4197 字节。
  这是 D-013「静默失败零容忍」的又一次落实：**证据写不出来必须能被发现**。
- **"读不到包名"被写成"包名不一致"**：`judgeSignForWriteback` 在工程 `AppScope/app.json5` 读不到
  `bundleName` 时，原先照样拼出"工程包名 （…读不到…） 与候选材料包名不一致"——读着像真结论，
  其实是没有事实支撑。现在只提示"无法判断候选材料是否匹配"，不动原判定的下一步。

### Added

- `src/compiler/sign.cj`：`SignPreflight` + `judgeSignPreflight()`（纯函数）。三条规则**只在必然失败时拦**：
  没配 signingConfigs 不拦（能产 unsigned HAP）· 材料文件缺失只提示（unsigned 仍可能产出，
  提示 00303107）· 包名不一致**拦**（必然 00303074，产物为零）· 读不到工程包名不拦（交回 hvigor）。
- `src/main.cj`：`t2h:hap` 在跑 hvigor 之前做预检，结论进 `phaseLog`、落档 `signPreflight{}` 与
  HAP 闸 failures；返回值加 `signPreflightBlock / signPreflightReason / projectBundle / profileBundle`。
  `profileBundleOf(p7bPath)` 读 profile 的 `bundle-name`（与 `profileTypeOf` / `profileAllows` 同族）。
- 4 例新单测（`judgeSignPreflight` 四态），总 **290 例**。

### 5 样本签名就绪度（同一台机器 · 已连设备，`t2h:sign` 实跑）

| 样本 | 工程 bundleName | 本机候选材料包名 | 可签吗 |
|---|---|---|---|
| habit-tree | `com.jiujiang.habit_tree` | 同（`m7Gx…`） | ✅ `ok=true`，已装机 |
| m3u8dl-tauri | `com.atomgit.m3u8dl_tauri` | `com.yang.testcj` | ❌ 需 DevEco 对本工程自动签名 |
| cc-switch-harmonyos | `com.ccswitch.desktop` | `com.yang.testcj` | ❌ 同上 |
| tauri-mqtt-client-ohos | `com.atomgit.mqtt_client_ohos` | `com.yang.testcj` | ❌ 同上 |
| atomMqtt | （无 `gen/ohos/AppScope`） | `com.yang.testcj` | ❌ 先补鸿蒙脚手架 |

**口径**：这四条"❌"不是工具缺陷，是**每个新包名都需要一次 DevEco 登录自动签名**（ADR D-017，
计入 A3 人工介入）。本轮还确认了没有可脚本化的替代入口：`devecocli`（1.0.0）只有 `build/run/device`，
`DevEcoStudio6.1` 的配置目录里没有任何登录态文件，`hap-sign-tool.jar` 只能签、不能签发 profile。

## [0.39.10] - 2026-11-01

**主题**：**habit-tree 首次拿到真机的完整链路与 100% 可用率**，同时修掉让可用率"假低分"的两个
取数缺陷。签名这条也终于在**包名匹配**的样本上跑通（`signed=true` → 装 → 启）。

### 真机实跑证据（Windows x64 · 鸿蒙 PC `3QC0124B20000048` · habit-tree @ `ohos` 分支）

    lingqu-cli sign   --path E:\test\rust\habit-tree
      ok=true  udid=B8861DAE…6385  hasConfig=true filesExist=true allowsDevice=true profileType=debug
      projectBundle=com.jiujiang.habit_tree  candidateBundle=com.jiujiang.habit_tree  candidateBundleMatch=true
    lingqu-cli hap    --path E:\test\rust\habit-tree
      built=true  signed=true  hapBytes=7,249,833  gates.passed=true  errorCount=0
      hvigor：BUILD SUCCESSFUL（SignHap UP-TO-DATE）
    lingqu-cli deploy --path E:\test\rust\habit-tree
      installed=true（install bundle successfully） started=true（ability started）
      hilogHealthy=true（40 行，无崩溃）  serial=3QC0124B20000048
    lingqu-cli verify --path E:\test\rust\habit-tree
      清单 6 项：通过 5 / 平台限制 1 / 未验证 0
      → **核心功能可用率 100%**（分母剔除平台限制），截图 .lingqu/evidence/habit-tree-verify.jpeg

### Fixed

- **verify 取数读到别处/过期的旧档（假低分主因）**：`collectVerifyInput` / `deploySerialOf` /
  `deployBundleOf` / `collectEvidence` 用的是**相对 CWD** 的 `.lingqu/...`（0.38.0 之前的落档位置）。
  实测后果：`t2h:deploy` 刚报 `start.ok=true`，紧接着 `t2h:verify` 却按应用目录里 0.39.7 份旧档
  （`start.ok=false`，锁屏那轮）判定"装上了但没起来"。现在读侧一律 `resolveLqPath(projPath, …)`
  （工程优先、CWD 兜底），截图证据也落到**工程**的 `.lingqu/evidence/`。
- **`assetDiff` 三个字段是数组，被当整数取**（AGENTS §4-57 的老坑复发）：`matched / staleInSo /
  missingInSo` 用 `intFieldOf` 永远得 0 → "前端指纹一致"被误判成"不一致（会白屏）"，
  连带可用率掉一格。改为 `arraySizeFieldOf`，并把解析收成纯函数 `buildAssetFlagsOf` /
  `deployFlagsOf`（`src/verify_feed.cj`），单测钉住字段形态。

### Added

- `src/verify_feed.cj`：`buildAssetFlagsOf(root)` / `deployFlagsOf(root)` 纯函数（两条判定单点定义）。
- `src/tests/verify_test.cj`：`testBuildAssetFlagsTreatsAssetDiffAsArrays`（数组形态 / stale / missing /
  编译失败四态）与 `testDeployFlagsReadInstallAndStartSeparately`（装≠起）。

### 说明（签名这条的口径，别读错）

`t2h:sign` 的包名门槛（0.39.9）在 habit-tree 上按预期放行：材料 bundle-name 与工程 bundleName 一致
→ `candidateBundleMatch=true` → `signed=true`。**m3u8dl-tauri 仍是不可签**（本机没有
`com.atomgit.m3u8dl_tauri` 的 profile），需 DevEco 登录自动签名一次——那是外部人工步骤，
工具已给出可执行说明（见 ADR D-017），不是本仓能脚本化的（`devecocli` 只有 build/run，
`~/.ohos/config` 里没有登录态）。

## [0.39.9] - 2026-11-01

**主题**：**签名链路的真根因是「包名」，不是「材料路径」**。0.39.7 把 `hap/sign` 的 `ok=false`
记成「`signingConfigs` 指向不存在的材料，改指向现存那套即可」——**这个改法照着做仍然装不上**。
本轮把它钉死：`profile` 是**按包名签发**的，hvigor 在 `default@SignHap` 会校验它。

### 决定性证据（Windows x64，m3u8dl-tauri，bundleName=`com.atomgit.m3u8dl_tauri`）

把工程 `signingConfigs` 改成指向本机**现存且文件齐全、含本机 UDID** 的那套材料（`default_ohos-probe…`，
口令密文一并从用同一套材料的工程搬过来），`hvigor assembleHap` 仍然失败，而且错误变了：

    > hvigor ERROR: Failed :entry:default@SignHap...
    > hvigor ERROR: 00303074 Configuration Error
    Error Message: The bundleName in app.json5/hvigorfile.ts does not match the bundleName
    in the generated SigningConfigs. At file: …\src-tauri\gen\ohos\build-profile.json5

本机 4 套 profile 的包名是 `com.yang.testcj` / `com.jiujiang.habit_tree` / `com.yang.ohosnes.fceux`，
**没有** `com.atomgit.m3u8dl_tauri`。结论：这道门不是路径问题，是**包名门槛**；
"机器上有含本机 UDID 的材料"≠"能写回"。（实验后已把工程文件按原样还原，SHA256 校验一致。）

### 实跑证据（`lingqu-cli sign --path E:\test\rust\m3u8dl-tauri`）

    reason   : …有文件不存在…；工程包名 `com.atomgit.m3u8dl_tauri` 与候选材料包名不一致
    nextStep : 工程包名 `com.atomgit.m3u8dl_tauri` 没有对应的签名材料（profile 按包名签发）。
               本机现有材料的包名：com.yang.testcj(27台/含本机)、com.jiujiang.habit_tree(26台/含本机)…
               hvigor 写回/抄用别的包名的材料会报 00303074（bundleName 与 SigningConfigs 不一致）。
               在 DevEco 里对**本工程**点一次「Automatically generate signature」（需登录）…
    candidateBundleMatch : false
    apply（LINGQU_SIGN_APPLY=1）: applied=false，applyError="拒绝写回：本机候选材料的包名是 com.yang.testcj…"
    且工程 build-profile.json5 的 SHA256 前后一致（**拒绝而不是写坏**）

### Added

- `src/compiler/sign.cj`：`bundleMatches()` / `profileBundleCensus()` / `judgeSignForWriteback()`
  —— 把"包名门槛"做成独立判定（`SignCheck.bundleMatch`），不再塞进 `filesExist` 之类的开关里。
  没有候选材料时**不叠**这句（设备离线就是"拿不到 UDID"，别把人带偏）。
- `src/port/gates.cj`：`hapSignHint(logText)` —— HAP 闸直接给出签名根因
  （`00303074` 包名不一致 / `00303107` 材料文件不存在），不用再自己去 `.lingqu/hap/<工程>.log` 里扒。
- 指纹库 **FP-018**（00303074）/ **FP-019**（00303107），走 guide 档（涉及 DevEco 登录，不自动改）。
- 探针 `LINGQU_SIGN_UDID`：设备离线/无设备机器上复跑签名体检（日志里标注"探针覆盖，非 hdc 实测"）。
- `ui_report` 新增 `signBundleMatch` / `signCandidateBundles`（前端 `reportUi` 与后端白名单两处同批加，
  见 AGENTS §4-60）；⑤ 屏候选行改成「N 份（可用：有 / 无——包名不符）」，hover 给出两边包名。

### Fixed

- **误导性建议**：候选材料包名与工程不一致时，以前会说"抄回来即可"——照着做 hvigor 必然 00303074。
  现在结论明确不可用，并把"缺哪个包名 / 本机有哪些包名 / 该点哪里"一次说清。
- **apply 不再写坏工程**：包名不匹配时拒绝写回（以前会写进一份注定失败的 signingConfigs，
  比"没配"更难排查——人会以为是口令/路径问题）。
- HAP 装配失败时闸门只报「assembleHap 没成功」→ 现在带签名根因那一行。

### 测试

`cjpm test` **284 例**（+9）：`bundleMatches` 边界（空/空白/大小写）· `profileBundleCensus`
（解析失败不列 / UDID 未知不写"不含本机"）· **复现用例** `testWritebackRefusesOtherBundle`（先红后绿）·
无候选时不误报 · 包名匹配时保留原建议 · `hapSignHint` 两条 + 不瞎猜 · 指纹 FP-018/FP-019 命中。

## [0.39.8] - 2026-11-01

**主题**：**断点板跟着工程走**。`tasks.json` 原先写在灵渠应用目录、跨工程共用，
于是打开 B 工程时顶部还显示 A 工程的进度——和「8 个路径框各填一遍」是同一个毛病：
**同一件事实存了两份权威**。现在板子落在 `<工程>/.lingqu/tasks.json`，工程自包含。

### 实跑证据（Windows x64，`lingqu-cli resume --path <工程>`，五道闸全绿 / 275 例）

    habit-tree   → "out": "E:\\test\\rust\\habit-tree\\.lingqu\\tasks.json"     done=7/8 next=deploy
    m3u8dl-tauri → "out": "E:\\test\\rust\\m3u8dl-tauri\\.lingqu\\tasks.json"   done=4/8 next=hap
    habit-tree 板子 SHA256 在跑 m3u8dl-tauri 前后**不变**（两工程互不覆盖）

### Changed

- `src/task_feed.cj`：`taskBoardPath()` → **`taskBoardPathFor(projectPath)`**（单点定义，内部走
  `lqPathOf`）+ `legacyTaskBoardPath()` 保留旧应用级位置；`saveTaskBoard(board, projectPath)`
  改工程级写盘，目录改为 **`recursive: true`** 创建（换成工程级路径后不建目录会直接写失败）。
- **读侧双查**（迁移期不丢证据）：读板一律 `resolveLqPath(projPath, "tasks.json")` —— 工程优先、
  CWD 兜底，旧板子照旧读得到（AGENTS §4-33 的纪律：产出方与消费方同批改）。
- 消费方同批切换：`ResumeCommand`（读板 + `out` 回投 + 写回落 `path`，没给就沿用板子里记的工程）、
  `ReportCommand`（读板取工程名）、`report_feed.cj` 的证据清单（记实际用的那个路径）。
- 文案三处对齐事实：`agent_context.cj` 的注入说明（原写"在灵渠应用目录、跨工程共用"）、
  界面「刷新断点」的 tooltip、`agent_ctx_path_test.cj` 的断言。

### Added

- `src/tests/task_board_path_test.cj`（4 例）：板子跟工程走 / 无工程回落旧位置 /
  双读工程优先 / 双读回落不抛。**断言不断死分隔符**（`cjhPathSep()` 在 Windows 上是 `\`），
  且明确允许「工程与 CWD 都没有板子 → 回落旧板子」这条合法路径（测试 CWD 是仓库根，
  本来就躺着一块应用级旧板子，这个分支没法稳定构造成"两处都没有"）。
- ADR **D-016**：断点板跟工程走（写入位置 = 工程，读侧双查兜底，迁移完成后可删兜底）。

## [0.39.7] - 2026-11-01

**主题**：把"假停滞"彻底修掉（0.39.6 只修了一半），并拿到第一次**完整链路**实跑证据：
`build` 落档从 `exitCode=101` 变成 **0**，hap/sign 也真的被跑到。

### 实跑证据（Windows x64，`LINGQU_UI_PROBE=ai-full`，m3u8dl-tauri，cjh 分支构建 + `CJH_BASH_TIMEOUT=600`）

    wsFrameTypes：delta:86  done:1  tool_start:40  tool_result:40   ← 40/40 完全配对，无丢帧
    aiPortPolls=151  aiPortStalled=false  abortSource=""  wsReconnects=0  errorCount=0
    trace.jsonl：67 KB；trace 里 `| tail` 0 次、`> /tmp/` 5 次（长命令都改成重定向了）
    落档：scan ✓ / deps ✓ / port ✓ / **build exitCode=0** / hap（hvigor BUILD FAILED，但已产出 7.9 MB HAP）/ sign（debug，材料探测不到）

- **build exitCode=0 的原因**：agent 读了任务书新加「交叉编译的硬前置」+ R2-PORT-008 的 guide 片段，
  自己给 `src-tauri/.cargo/config.toml` 补了 `[env] CC_aarch64_unknown_linux_ohos`（trace 里有那条 edit），
  `ring` / `ohos-arkui-sys` 的 C 依赖这才找到 NDK clang。
- **这轮把应用中途打断的是我自己的门禁**：`scripts/test.bat` 第 ④ 闸检测到旧 `main.exe` 在跑，
  结束进程以释放产物（日志原文：`[!] 上一版 main.exe 仍在运行，先结束它以释放产物`），
  所以 deploy/verify 没跑到。**教训进 §4：实机探针与门禁不要同时跑。**

### Fixed

- **假停滞（第二轮）**：0.39.6 只把"轨迹行数"编进签名，但**单个长工具调用期间轨迹也不动**
  （tool / tool_done 各一条）——实跑到 poll≈106 又报了「AI 好像在绕圈」。现在：
  ① 新增 `agentTraceBusy(path)`（最后一条轨迹是 `tool` 且没有 `tool_done` = 正在干活），
  正在跑工具时**不判停滞**并清空已攒的窗口（`AutoPortState.clearHistory()`，polls 计数保留）；
  ② `AUTOPORT_STALL_POLLS` 6 → **20**（轮询 900ms，6 次 ≈5.4 秒，比一次 LLM 思考还短，必然误报）。

### Changed

- 用例改成常量驱动：`testStatePushSigKeepsWindow` 原先硬编码"推 12 条、留 6 条"，
  阈值一改就假红——现在按 `AUTOPORT_STALL_POLLS + 5` 推、按常量断言。

### 追加（同一轮补做）：`autoport_start` 自动打开「断连不打断」

上一条把责任推给了"用户手工配 settings.json"——这不对，**配置不该由人记**。现在
`t2h:autoport_start` 在准备现场时自动调用 `ensureCjhKeepRunning(userHomeDir())`：

- 新增 `src/cjh_settings.cj`：`ensureKeepRunningOnDisconnect(json)` 对 settings JSON 做
  **定点修补**（不整体重排、不动用户注释与字段顺序），幂等；没有 `web` 段时原样返回、不乱写。
- 结果回投 `keepRunningOnDisconnect` 字段（`already` / `written` / `no-settings` / `no-home` /
  `error:…`），排障时一眼看出到底改没改。
- 测试 `src/tests/cjh_settings_test.cj`：注入 / 幂等 / false→true / 无 web 段不动 / 空输入 /
  home 缺失不抛。`cjpm test` 267 例全 PASS。

**诊断（hap/sign 的 `ok=false`，同一个根因）**：hap 不是装配失败 —— 落档里
`hapBytes=8151230`、`hasArm64So=true`、两个 so 都在（`libentry.so` + `libm3u8dl_tauri_lib.so`）；
失败在 `default@SignHap`：

    hvigor ERROR 00303107 Configuration Error
    Invalid storeFile value. Make sure it is not null or empty.
    The file must be included in 'C:\Users\yang\.ohos\config\default_ohos_cqJPvSnvtx…'

工程 `build-profile.json5` 的 `signingConfigs` 指向 `default_ohos_cqJPvSnvtx…{cer,p7b,p12}`，
而 `~/.ohos/config` 里现存的材料是另外几套（`sign` 落档 `candidateCount=4`，探测到
`default_ohos-probe_…p7b` / `default_ohos_m7Gxh5…p7b` 等）——**写回时选中的那套文件不存在**。
所以 hap 与 sign 是同一件事：签名材料选错/未写回，跟装配、跟 agent 都无关。下一步按
`skills/t2h-ohos-port/references/signing.md` 的配方，改成"只挑现存且在 `~/.ohos/config` 内、
profile 含本机 UDID（`B8861DAE…`）的那套"再写回，并重跑 `t2h:hap` 验证。
### 追加：这一轮把「整轮被打断」的**真凶**找到了（cjh 侧已修）

复跑时观察到 `Agent.interrupt` 出现但 `abortSource=""`（两处 UI abort 入口都没被点），
顺着 `~/.cjh/logs/cjh.log` 定位到 cjh 的**断连处理本身**就打断回合：

    [23:54:12] Agent.interrupt 已请求：interruptFlag=true + abort() 已调用
    [23:56:21] WebChannel 发送失败，连接判定为断开，后续帧跳过（上一轮的 WsSendGuard 生效）
    [23:56:21] Agent.run 被用户中断（24 轮后）

调用点是 `gateway/channel.cj` 的 `interruptSession()`（WS 断连时调用）。对交互式合理，
对**无人值守的长任务**是灾难：WebView 只重连一次（`wsReconnects=1`），
40 次工具调用、交叉编译已经跑到 `exitCode=0` 的整轮迁移当场作废。

cjh 已加 `web.keep_running_on_disconnect`（默认 false 保持老行为；开着则断开后本轮跑完、
结果落会话、重连靠 `history_messages` 补看）。**本机 `~/.cjh/settings.json` 已置 true 用于验证**
（备份在 `%TEMP%\cjh_settings_backup.json`）。灵渠侧下一步要做的：`t2h:autoport_start` 时
把这条设置自动写进去，别让用户手改。

### 验证：开关打开后重跑，回合**扛住了 13 次断连**

    [00:08:53] 客户端断开，本轮继续执行（web.keep_running_on_disconnect=true）   ← cjh 新逻辑
    [00:11:01] build 落档 exitCode=0
    [00:13:03] Agent.run 正常结束: 41 rounds, 49 tools, 328028ms               ← 跑完并收尾

    ui_report：wsReconnects=13  aiPortStalled=false  abortSource=""  toolCards=33
    落档：scan ✓ / deps ✓ / build **ok=true exitCode=0** / hap 落档 ok=false / sign 落档 ok=false

对比上一轮（不加开关、只加写容错）：同样是重连，那次 `Agent.run 被用户中断（24 轮后）` 直接作废；
这次 49 次工具调用跑完整轮、`build` 拿到 `exitCode=0`，hap 与 sign 也真的被执行到
（各自 `ok=false`，原因待查：hap 是 `hvigor BUILD FAILED`、sign 是 debug 态且探测不到签名材料）。



  阈值一改就假红——现在按 `AUTOPORT_STALL_POLLS + 5` 推、按常量断言。

---

## [0.39.6] - 2026-11-01

**主题**：端到端实跑暴露的两个"能打死整轮"的问题各修一处——停滞判定并入 agent 活动、
abort 留痕；交叉编译的 C 依赖环境不再"半配好就当已配好"。

### 实跑证据（Windows x64，`LINGQU_UI_PROBE=ai-full`，m3u8dl-tauri，cjh 分支构建 + `CJH_BASH_TIMEOUT=600`）

    ui_report：wsState=connected  wsSendFail=0  cjhBin=<分支产物>  toolCards=24  agentTraceLines=48
    wsFrameTypes：delta:91  tool_start:24  tool_result:23  history_messages:1
    落档：scan 5.8 KB / deps 175 KB / port（5 条规则 applied）/ build（6.3 KB + 298 KB jsonl + 4.7 KB log）

- **好的一面（上一轮 cjh 修复生效）**：agent 的长命令变成
  `"…main.exe" build --path . > /tmp/build.log 2>&1; echo "EXIT:$?"; tail -40 /tmp/build.log`
  —— **不再 `| tail`**；24 次工具调用无一次卡满超时；事后会话 shell 空闲、无残留子进程。
- **坏的一面（本轮修）**：① 页面重连两次后 cjh 往旧 WS 写帧抛 10053，**整轮 run 当场结束**，
  那条 build 的 `tool_result` 永久丢失（cjh 侧已修，MR !11 `840dc85`）；
  ② 分钟级交叉编译期间落档当然不动，连续 6 次轮询被判「AI 好像在绕圈」——假停滞。
  该轮 `Agent.interrupt` 有记录但**没有** `autoport-stop` 标签，说明按的是对话面板那个 abort；
  现在两处 abort 都会标来源。

### Added

- `t2h:ui_report` 新增 `abortSource` / `abortAt`：停止按钮 → `stop-button`、对话面板「中止」→ `chat-abort`，
  不再出现"cjh 收到 interrupt 却查不到谁按的"。
- `autoportSnapshotWith(rows, traceLines)`：停滞签名并入 agent 活动量
  （`<工程>/.lingqu/agent/trace.jsonl` 行数）；`autoportSnapshot` 保留，等价于 `traceLines=-1`。
- `cargoEnvOnlyToml(sdkNative)`：只补 `[env]` 段的片段，用于工程已有 `.cargo/config.toml`
  但缺 C 依赖环境的场景（不覆盖既有 linker 配置）。

### Changed

- 任务书新增「交叉编译的硬前置」：`.cargo/config.toml` 的 `[target…]` **和** `[env]` 两段都要在；
  缺 `[env]` 的症状是 `cc-rs: … "cc" … --target=aarch64-unknown-linux-ohos`（`ring` 的 curve25519.c
  实测失败，build 落档 `exitCode=101`）；看到这条错先查 `[env]`，别改 Rust 源码；
  回滚改造别只回滚 `Cargo.toml`。

### Fixed

- **R2-PORT-008 幂等判据误判"已配好"**：原判据只看文件里有没有 `aarch64-unknown-linux-ohos`。
  m3u8dl-tauri 的 `.cargo/config.toml` 有 target 段却**没有 `[env]`**，于是被判"跳过"，
  而 `ring` 这类含 C 代码的依赖只能退回宿主 `cc` → 交叉编译必然失败。现在要求
  target 段 + `CC_aarch64_unknown_linux_ohos` 都在才算跳过；半配好降成 **guide**
  （`applied=false` / `needsHuman=true` / `after` 给出应追加的片段），既不动用户文件也不假装完成。
- 版本三处对齐：`cjpm.toml` / `cj-tauri.toml` 0.39.3 → **0.39.6**（此前已落后代码两个小版本）。

---

## [0.39.5] - 2026-11-01

### Fixed

- 页面断线**重连不设次数上限**（backoff 封顶 5s）：换引擎实例 / 引擎重启后，页面不再永久停在
  「连接已断开——回复可能不完整」。
- `t2h:ui_report` 新增 `wsReconnects`，用来断言"页面真的在重连"。

---

## [0.39.4] - 2026-11-01

**主题**：cjh 第 4 个 PR（bash `timeout` 参数）合入后复跑全自动 —— **AI 第一次把没迁过的样本编译到 exit=0**。

### 实跑证据（Windows x64，`LINGQU_UI_PROBE=ai-full`，m3u8dl-tauri，`CJH_BASH_TIMEOUT=600`）

    ui_report：toolCards=49  frames=110  errorCount=0  agentTraceLines=98
    trace.jsonl：bash 77 次，**命令超时 0 次**，exit code: 0 共 37 条
    build 落档：project=m3u8dl-tauri  target=aarch64-unknown-linux-ohos
                exitCode=0  errorCount=0  ← 交叉编译成功（0.39.2 时是 exitCode=101）
                gates.passed=false，唯一失败项：前端指纹闸「.so 里没有内嵌前端资源（frontendDist 配了吗）」
    行为：它自己写了 src-tauri/src/lib.rs（write_file，2242 字符），随后在跑命令继续处理

对照：0.39.2 同一路径 25 次 bash 全失败、build exit=101；现在 77 次调用零超时、**编译通过**。

### 仍未完成（下一步）

- 前端指纹闸还没修好（frontendDist 未配），所以没走到 hap/sign/deploy；
- 实测最后一条 trace 是 in-flight 的 `python - <<EOF`（heredoc），4 分钟无结果 —— 疑点：
  这条命令依赖 PATH 里的 python，且 heredoc 在持久 bash 会话里可能吞掉后续输入。
  排查方向：① 机器上 python 是否存在；② 是否需要提示 agent「heredoc 少用，改写脚本文件再执行」。
## [0.39.3] - 2026-11-01

**主题**：修 `--path .` 让落档名变成 `.`（0.39.2 实测暴露，`..json` 那种）。

### 现象与根因

agent 按我们的任务书在**工程根**用 `--path .` 跑 `lingqu-cli build`，落档写成
`..json / ..jsonl / ..log`。根因：`projectNameOf(".")` 把 `"."` 原样当名字，
`sanitizeFileName` 再清成空串。而「在工程根用 `--path .`」正是我们自己教它的写法。

### 处置

- `src/scanner/scan.cj` 新增**纯函数** `projectNameOfPath(path, cwd)`（cwd 注入，可单测）：
  `"."` → cwd 末段；`".."` → cwd 父目录末段；`"./x"` → `x`；绝对路径照旧取末段；
  末尾分隔符归一（顺带修了旧契约"末尾带分隔符返回空串"——现在返回名字）
- `projectNameOf` 改为先按 cwd 解析、拿不到 cwd 才退回旧逻辑（不崩）
- 单测 `src/tests/project_name_test.cj`（3 例）：`.`/`./`/空串/反斜杠 cwd/`..`/相对子路径/绝对路径，
  外加一条"退化输入不许返回 `.` 或空串"的兜底断言（252 例全绿）

### 证据

```
在工程根： lingqu-cli build --path . --verifyOnly
  outJson = .lingqu\build\m3u8dl-tauri.json        ← 正确名字（修前是 ..json）
  .lingqu/build/ 下：m3u8dl-tauri.{json,jsonl,log}
```
## [0.39.2] - 2026-11-01

**主题**：**第一次让 AI 全自动迁一个从没迁过的样本**（`m3u8dl-tauri`，此前只有 scan/deps）。跑通 4 步，卡在两个新缺陷上（都已定位）。

### 实跑证据（Windows x64，`LINGQU_UI_PROBE=ai-full`，scope=all，合入后构建的 cjh）

    ui_report：toolCards=32  frames=78  errorCount=0  agentTraceLines=64
    trace.jsonl：bash 59 次，命令执行异常 = 0，exit code: 0 共 26 条
    工程落档（**从零生成**）：m3u8dl-tauri/.lingqu/{scan,deps,port,build}
    build 落档：target=aarch64-unknown-linux-ohos  exitCode=101  errorCount=1  ← 真编译错，等 AI 修

顺序与行为：scan → deps → port --apply（有备份目录）→ build；中间自己 `cat` 了 build 日志
（trace 里有真实 cargo 输出 `Compiling cfg-if v1.0.4 …`），最后调用 `lingqu-cli build --path .` 重跑。

### 暴露的两个新缺陷（下一轮第一件事）

1. **`--path .` 让落档名变成 `.`** → 文件写成 `..json / ..jsonl / ..log`
   根因：`projectNameOf(".")` 原样返回 `"."`，`sanitizeFileName(".")` 清成空串；而我们的
   AGENTS.md/任务书**正是教 agent 用 `--path .`**（agent cwd = 工程根）。
   修法：命令入口统一把相对路径解析成绝对（`absProjectPath`），或 `projectNameOf` 对 `.`/`..`/空串
   回退到 cwd 末段名。
2. **长命令会卡住回合**：cargo 交叉编译是分钟级，而 cjh 的 bash 工具单条命令有超时；实测最后一帧
   停在"已发起 build、结果没回"，`aiPortPolls=127` 但落档不再变化。
   修法（cjh 侧建议）：bash 工具加"后台执行 + 轮询"，或暴露 `timeout` 参数让 agent 自己传。
## [0.39.1] - 2026-11-01

**主题**：**AI 真的能动手了** —— cjh 的三个 PR 合入后，实机验证 agent 从"能看不能跑"变成"能看能跑"。

### 证据（Windows x64，`LINGQU_UI_PROBE=ai-port`，habit-tree，用**合入后重新构建**的 cjh）

```
① 合并后的二进制接口自述（不是单测，是 GET /api/capabilities）：
   shell = {"path":"D:\\Program Files\\Git\\bin\\bash.exe","mode":"bash","source":"GIT_BASH"}
   ws    = {"max_frame_bytes":262144}
   → Git 装在 D 盘也能找到；WS 帧上限也公告出来了

② 端到端（半自动档 ④「🤖 交给 AI 改造」）：
   ui_report：toolCards=19  frames=45  errorCount=0  agentTraceLines=38
   trace.jsonl：bash 调用 33 次，**真正的 ProcessException 失败 = 0**，`exit code: 0` 共 14 条
   逐条节选（trace 原文）：
     exit code: 0  stdout: Counter({'可用': 443, '不可用': 10})        ← 读 deps 落档
     exit code: 0  stdout: "id": "R2-PORT-011", "applied": false ...   ← 读 port 落档
     exit code: 0  stdout: .lingqu/port/habit-tree/Cargo.toml.bak === git status === M src-tauri/gen/ohos…
     exit code: 0  stdout: .lingqu/port: total 4 …
   → 它在真跑 `port --apply`、看备份、看 git status
```

对照 0.39.0：25 次 bash **全部** ProcessException；本轮 33 次**零**失败。

### 本轮暴露的下一处（诚实记录）

- **停滞判定会误报**：`aiPortVerdict` 报"AI 好像在绕圈（落档连续没变化）"，实际它一直在干活（33 次 bash）——
  因为判定**只看落档**；habit-tree 已迁移完、`port --apply` 不产生改动 → 落档自然不动。
  修法：把 `agentTraceLines`（工具活动）纳入停滞判据，**落档不动且没有工具活动**才算卡住。

## [0.39.0] - 2026-11-01

**主题**：agent 行为轨迹落成工程证据（`<工程>/.lingqu/agent/trace.jsonl`）。

cjh 的 web 会话只在销毁时落盘，跑完的回合在 `~/.cjh/sessions/` 里仍只有 system 消息（实测 158 B），
"AI 改了什么、跑了哪些命令"因此没有留痕。现在由**我们**记：`src/agent_trace.cj`（纯函数 + 4 例单测）
+ 命令 `t2h:agent_trace` + 页面 `onFrame` 挂钩（tool_start / tool_result / done），
`ui_report` 新增 `agentTraceLines`。分工依据见 ADR D-015（我们是记录员）。

## [0.38.1] - 2026-11-01

**主题**：**落档跟着工程走 —— 全部写入者迁完**（12 个产出者里 11 个在工程内，2 个按设计留在应用目录）。

### Changed（写侧全量迁移，每个命令一次 `cjpm test`）

| 命令 | 落档新位置 | 备注 |
|---|---|---|
| `t2h:scan`（0.38.0） | `<工程>/.lingqu/scan/<工程>.json` | — |
| `t2h:deps` | `<工程>/.lingqu/deps/<工程>.json` | — |
| `t2h:build` | `<工程>/.lingqu/build/<工程>.{json,jsonl,log}` | 读侧（回归闸基线 `lastBuildErrorCountOf`）改走 `resolveLqPath` |
| `t2h:hap` | `<工程>/.lingqu/hap/<工程>.{json,log}` | — |
| `t2h:sign` | `<工程>/.lingqu/sign/<工程>.{json,log}` + `signingConfigs` 备份 | 读侧 `signModeOf(proj, path)` 也跟着带工程路径 |
| `t2h:verify` | `<工程>/.lingqu/verify/<工程>.{json,md,html,evidence.log}` | — |
| `t2h:deploy` | `<工程>/.lingqu/deploy/<工程>.{json,log}` | — |
| `t2h:report` | `<工程>/.lingqu/report/<工程>.{md,html,json}` | — |
| `t2h:migrate`（结果卡） | `<工程>/.lingqu/migrate/<工程>.md` | — |
| `t2h:port`（备份/预览/决策） | `<工程>/.lingqu/port/<工程>/…` | `ensurePortDirs()` 改成 `ensurePortDirs(dir)`：不再硬编码 `.lingqu/port` |
| `t2h:resume`（`tasks.json`） | **仍在应用目录** | 断点板是"跨工程的工具状态"，不属于单个工程（待讨论，见下） |
| `t2h:batch`（矩阵） / `ui_report` | **仍在应用目录（有意）** | 矩阵是多样本的工具体产物；`ui-report` 是界面自检证据，与被迁移工程无关。两处代码里已加注释，避免后人"顺手改掉" |

### 未做（诚实标注）

- `t2h:resume` 的 `.lingqu/tasks.json` 仍写在应用目录：它是**跨工程**的断点状态（一个板记 8 步 + 会话 id）。
  要不要按工程拆成 `<工程>/.lingqu/tasks.json`，需要先定"用户在界面切换工程时断点板怎么表现"，
  这是产品决定，不在这轮硬改。
- AGENTS.md 文案（"落在本工程的 `.lingqu/` 下"）**现在才变成真的**，但还没写准确路径 → 下一步。
- `resolveLqPath` 的 CWD 兜底仍保留（旧落档还能读）；全部验证完再删。

## [0.38.0] - 2026-11-01

**主题**：**落档跟着工程走（第 1~2 步：底座 + 第一个命令）** —— 让 agent 与界面看**同一份**落档。

### 为什么

0.37.2 实测暴露：界面/命令跑出的落档在**灵渠应用目录**（`<lingqu>/.lingqu/`），而 agent（cjh）
的 cwd 是**目标工程**（`<project>/`）→ 它看不见落档；我们注入的 AGENTS.md 却写"落在本工程的
`.lingqu/` 下"——**与事实不符**（agent 原话：'`.lingqu/` 里只有任务书本身，没有任何落档 JSON'）。
这是"AI 能自己判断下一步"的前提，必须修。

### Added

- `src/workdir.cj`（纯函数 + 4 条单测，243 例）：
  - `lqDirOf(工程路径)` → `<工程>/.lingqu`（空路径退回 `.lingqu`，末尾分隔符归一，不会拼出 `x//.lingqu`）
  - `lqPathOf(工程路径, rel)` → `<工程>/.lingqu/<rel>`
  - **`resolveLqPath(工程路径, rel)` → 工程优先、CWD 兜底**（迁移期新旧落档都能读到，不丢证据）
  - `lqIsProjectScoped(path, 工程路径)` —— 报告里标注口径用
- `taskArtifactRelPath(projName, stepId)`：落档的**相对路径**单点定义（`taskArtifactPath` 改为
  调它 + `.lingqu/` 前缀，保持旧行为），产出方与消费方从此共用一份（AGENTS §4-33）
- `observeTaskStepAt(projName, stepId, 工程路径)`：读侧双查；旧签名 `observeTaskStep` 保留并委托
- 单测故意**不依赖分隔符**（Windows `\` / Linux `/` 都过）：钉的是"拼对了、优先级对了"

### Changed（迁移进度：12 个产出者里已完成 1 个）

| 步骤 | 命令 | 状态 |
|---|---|---|
| **1** | **底座 `workdir.cj` + 单测** | ✅ 完成 |
| **2** | **`t2h:scan`（写侧改工程内）** | ✅ 完成，实测 `out = E:\test\rust\habit-tree\.lingqu\scan\habit-tree.json` |
| 2 | `t2h:deps` / `port` / `build` / `hap` / `sign` / `deploy` / `verify` / `report` / `batch` / `resume(tasks.json)` / `migrate(结果卡)` | ⏳ 待迁（每个命令一次门禁） |
| 3 | 读侧（`collectTaskBoard`、`migrate` / `autoport_status` / `stepBriefOf` 已切 `observeTaskStepAt`） | ✅ 主链路已切 |
| 4 | AGENTS.md 文案去掉"本工程"、写准确路径 | ⏳ 待做（**现在这句还是错的**） |
| 5 | `resolveLqPath` 的 CWD 兜底删除 | ⏳ 待全部迁完后 |

### 证据

```
门禁：五道闸全绿 build-biz:PASS test:PASS(TOTAL=243) check:PASS build-app:PASS build-cli:PASS
lingqu-cli scan --path E:\test\rust\habit-tree
  → out = E:\test\rust\habit-tree\.lingqu\scan\habit-tree.json（文件存在）
```

## [0.37.3] - 2026-11-01

**主题**：把 0.37.2 那个坑**从上游堵掉**——cjh 的 WS 读侧不再静默丢弃超限帧。

### cjh 侧（两个独立 PR 分支，均已推）

| 分支 | 内容 | 验证 |
|---|---|---|
| `fix/declarative-tool-shell` | `registry.cj` 的 `/bin/bash` → `ShellProvider`（Windows 声明式技能工具可用） | build 0 warning / 540 例全绿 |
| `feat/ws-frame-limit` | 新增 `WS_MAX_INBOUND_BYTES`（256 KiB）：超限帧回 `{"type":"error","code":"frame_too_large","retryable":false}` 并 continue（不杀连接）；读异常同样先回 `ws_read_failed`；`/api/capabilities` 的 `features.ws.max_frame_bytes` 公告上限 | 同上 |

提 PR：
- https://gitcode.com/qq8864/cjh/merge_requests/new?source_branch=fix/declarative-tool-shell
- https://gitcode.com/qq8864/cjh/merge_requests/new?source_branch=feat/ws-frame-limit

### 说明

- 灵渠侧 0.37.2 的「任务书落文件 + 短 kickoff」**不依赖**这两个 PR（已自证可用：
  `tool_start:40 / tool_result:40 / done:1`）；PR 的价值是**让下一个调用方不用再踩**——
  失败会得到明确 error，而不是"没有回帧"。
- 「落档跟着工程走」（`<工程>/.lingqu/...`）本轮**未做**：它要改所有命令的落档前缀，
  属于跨 10+ 文件的迁移，必须配"读两处（工程优先、CWD 兜底）+ 逐命令切换"的迁移策略与单测，
  不适合在上下文将尽时动。设计已写进 `docs/进度记录.md` 的下一步。

## [0.37.2] - 2026-11-01

**主题**：**AI 终于真的开工了** —— 定位并修掉「任务书发过去 cjh 不干活」，第一次拿到
agent 自主跑完一个回合的实据（**40 次工具调用、886 帧、done 收尾**）。

### 二分定位（一次探针定死）

| 变量 | 实验 | 结果 |
|---|---|---|
| 通道不通？ | 同会话发 9 字短句 | ❌ 排除：`frames=5, delta:2, done:2, replyPreview=收到` |
| 发送失败？ | `wsSendFail` | ❌ 排除：`0` |
| 多余 `new_session`？ | 已去掉再跑 | ❌ 排除：现象不变 |
| **workspace 切换后状态坏了？** | **切完工作区只发短句**（新探针 `LINGQU_UI_PROBE=ai-short`） | ❌ 排除：短句照样正常 |
| **消息太长？** | 同上：4448 字长文 vs 9 字短句 | ✅ **就是这个**：短句有回、长文静默 |

### Fixed

- **任务书改为「落文件 + 短 kickoff」**：写进**目标工程**的 `.lingqu/autoport-directive.md`，
  只发一条 <400 字的开工信（`buildAutoPortKickoff`，纯函数 + 1 条"必须短"的单测），
  让 agent 用自己的 `read` 工具去读。对任何单帧长度上限免疫，也更符合 agent 的工作习惯
- 写盘失败时如实退回"整段发送"并在返回值里带 `directiveError`（不静默）

### 证据（Windows x64，`LINGQU_UI_PROBE=ai`，habit-tree）

```
wsFrameTypes = "history_messages:1, delta:804, tool_start:40, tool_result:40, done:1"
frames = 886    toolCards = 40    errorCount = 0
任务书落盘：E:\test\rust\habit-tree\.lingqu\autoport-directive.md（4448 B）
AI 的自述（实时回复节选）："任务书已读完。按指示先跑 resume 看落档。
  .lingqu/ 里只有任务书本身，没有任何落档 JSON。我先核实落档是否存放在别处。"
门禁：五道闸全绿（TOTAL=239）
```

### 新发现（下一步第一件事）

**落档位置跟 agent 的 cwd 对不上**：界面/命令跑出来的落档在**灵渠应用的工作目录**
（`E:\test\rust\test1\lingqu\.lingqu\`），而 agent 的工作目录是**目标工程**
（`E:\test\rust\habit-tree\`）。`t2h:agent_context` 写进工程的 AGENTS.md 说"落在本工程的
`.lingqu/` 下"——**与事实不符**，agent 因此先花了几轮去核实。

两种修法，倾向第一种：

1. **落档跟着工程走**（正解）：所有命令的落档路径改为 `<工程>/.lingqu/...`，工程自包含，
   换机器/换会话都能自证；代价是每个命令的落档前缀要统一改（`lingquWorkDir(projectPath)`）。
2. 只改文案：告诉 agent"落档在灵渠应用目录"，但这样 agent 与界面就永远各看一套落档。

## [0.37.1] - 2026-11-01

**主题**：**两种自动化档次 + 把 WS 排障的证据补齐**。

用户澄清了产品形态，这一轮据此对齐：

| 档位 | 入口 | 谁干活 | 收尾 |
|---|---|---|---|
| **半自动** | 左栏各屏（②画像 / ③依赖 / ④改造 / ⑤构建 …） | 人点一步，**AI 干那一步**（改代码、跑验证） | 做完**停下**，下一步由人点 |
| **全自动** | 「⚡ AI 自动迁移」（默认屏 / 顶栏） | cjh 一路干到 verify | 卡住/超预算才叫人 |

两档共用**同一套引擎**（`t2h:autoport_start { scope }`），只有任务书的"范围与收尾条件"不同。

### Added

- `scope` 参数（`all` = 全自动；`port`/`deps`/`build`/`hap`/`sign`/`deploy`/`verify` = 半自动）：
  `autoPortScopeTitle` / `isFullScope` / `autoPortScopeGoal`（纯函数 + 5 条单测）。
  半自动任务书会写明「只做「规则改造」这一步」+ 该步收尾条件 + **做完就停，不要顺手把后面几步也做了**
- ④ 改造执行屏新增 **`🤖 交给 AI 改造`** 按钮（与「预览改造 / 应用（落盘）」并排，互不冲突：
  规则引擎是不花模型钱的快通道，也是 agent 的手）
- `ui_report` 新增排障字段：`wsSendFail` / `wsLastSendErr` / `wsFrameTypes`（帧类型计数）
  —— 以前发送失败是静默的，分不清"没发出去"和"cjh 没回"

### Changed

- 撤回 0.37.0 的"补 `POST /api/chat`"计划：**用户指出 WS 已经能直接发消息**，产品是桌面 GUI、
  页面永远在场，REST 对话入口不是需求。那是在给一个 WS bug 打补丁（详见 docs/上游回馈-cjh.md 排障进度）

### 证据（Windows x64，2026-11-01）

```
门禁：五道闸全绿 build-biz:PASS test:PASS(TOTAL=238) check:PASS build-app:PASS build-cli:PASS
WS 排障（LINGQU_UI_PROBE=ai，habit-tree）：
  wsSendFail=0  wsFrameTypes="history_messages:1"  frames=1  toolCards=0
  → 任务书**发送成功**，cjh 只回一帧 history_messages 就静默；会话文件 158 B（只有 system 消息）
  同会话里探针短消息正常：frames=3 / lastFrameType=done / replyPreview=收到
  ⇒ 排除"通道不通"与"发送失败"；剩下两个变量：消息长度（4448 字）与 workspace 切换后的会话状态
```

## [0.37.0] - 2026-11-01

**主题**：**方向纠偏 —— AI 是执行者，不是"失败后给建议的顾问"**。

0.36.0 的「一键迁移」其实是**确定性流水线**：我们按固定顺序跑 8 个命令，失败就把现场问一次 AI，
AI 只出建议、命令还得人点。用户当场指出这做反了：**这个项目内置了 cjh 这个 agent，
移植的活本来就该它干**。0.37.0 把它摆正：

| | 0.36.0（做反了） | 0.37.0（摆正） |
|---|---|---|
| 谁在干 | 我们跑命令，AI 只在失败后被问一次 | **cjh 自己读落档 → 改代码 → 重跑**，我们准备现场 |
| 人的位置 | 每一步都要人点按钮 | 只在 AI 主动要求时才介入（介入次数 = 验收指标 A3） |
| 落档的角色 | 我们的输出 | **AI 的输入 + 我们的唯一判据** |
| 确定性流程 | 主路径 | 降级为「▶ 确定性流程」按钮 = 无 AI 兜底，也是 agent 的工具 |

### Added

- **`t2h:autoport_start` / `_status` / `_stop`（三处联动齐全）**：
  - `start`：准备现场（把 `t2h-ohos-port` 技能装进 `~/.cjh/skills`、往目标工程写 AGENTS.md 受管区块、
    把 cjh 工作区切到该工程、**算出 `lingqu-cli` 的绝对路径**）+ 生成任务书 → 返回 `{directive, cliPath, prep}`
  - `status`：纯读落档（`observeTaskStep` × 8）→ 进度/结论/**停滞判定**（连续 6 次快照一样 → 提示绕圈）
  - `stop`：收监管状态（页面同时发 WS `abort` 真打断模型回合）
- **任务书 `buildAutoPortDirective`（纯函数 + 单测）**：明确"你是执行者不是顾问"、可复制的工具命令行、
  "判断只认落档"、工作循环（同错最多 2 种修法）、纪律（平台限制不算失败 / 未验证不算通过）、
  预算（轮次 + 分钟）、收尾三段式、要人拍板的用 `lingqu-decision` 块
- **界面改成 AI 优先**：屏名「AI 自动迁移」，主按钮 `🤖 开始 AI 自动迁移`，其次是「▶ 确定性流程」（原一键迁移）
  与「继续」（AI 回合停了但没迁完时让它接着干）；时间轴读的是**落档**，不是我们自己的执行进度
- `ui_report` 新增 `aiPortActive/aiPortPolls/aiPortStalled/aiPortVerdict/aiPortDirective/aiPortCli`
- `docs/上游回馈-cjh.md`：5 条可直接提 issue 的 cjh 能力缺口（见下）

### Fixed

- **任务书里的工具路径是相对路径**（首次实跑暴露）：`cli\target\release\bin\main.exe` 在 agent 的
  bash 里（cwd = 目标工程）根本不存在 → 现在 `resolveCliExe()` 一定返回**绝对路径**
- 任务书发送顺序：`autoport_start` 会切 cjh 的 workspace（重置其持久 bash 会话），
  **必须先 `new_session` 再发任务书**，否则消息进了旧会话

### 未打通 / 未验证（如实记录，下一步第一件事）

- ⛔ **任务书没能送进 cjh 的对话回合**：三次实跑都是 `frames=1（history_messages）`、`toolCards=0`，
  cjh 新会话文件里只有一条 system 消息（158 B）——`new_session` 到达了、`chat` 帧没被处理。
  落档因此没变化（`aiPortPolls=17`、`aiPortStalled=true`），**AI 一次工具都没调起来**。
  根因未定位到行；已按用户授权把「cjh 没有 REST 对话入口（只有 `/ws`）」记成上游缺口 #2
- ⛔ 因此本轮**没有任何"AI 自主完成迁移"的实跑证据**。已通的只有：现场准备（技能 8639 B 已装、
  工程 AGENTS.md 已写、工作区已切）、任务书生成（4433 字）、绝对路径、停滞判定、时间轴读落档

## [0.36.0] - 2026-11-01

**主题**：**从"AI 副驾"到"AI 干活"** —— ① 一键迁移（一个按钮跑完 8 步）、
② 失败自动问 AI（现场由落档拼成提问正文）、③ 只读命令自动执行、④ 决策块回写 decisions.json。
本轮先回答了一个尖锐的问题：「当前这些工具、命令或技能，有主动调用 agent 吗？」答案是**没有**——
cjh 只被用于生命周期与配置，迁移八步一次模型都不问，AI 只是"人叫才动"的聊天窗。0.36.0 开始接闭环。

### Added

- **一键迁移 `t2h:migrate` / `t2h:migrate_status` / `t2h:migrate_cancel`（三处联动齐全）**

  | 环节 | 做法 |
  |---|---|
  | 跑在哪 | `t2h:migrate` 只起**后台线程**并立即返回（一次迁移以分钟计，堵住 IPC 就连进度都读不到）；页面 900ms 轮询 `t2h:migrate_status` |
  | 判定 | 每步跑完都 `observeTaskStep` **读盘上的落档**，不信命令返回值的乐观字段（存在 ≠ 成功，§4-63） |
  | 步骤 | scan → deps → port(apply) → build → hap → sign(体检→必要时写回) → deploy → verify → 出报告 |
  | 跳过 | 没插设备 / 签名是 release 态 → deploy+verify **跳过并写明原因**，不算失败 |
  | 失败 | 就地停下，用 `migrateAskPrompt`（复用 G1/G2 模板）拼好提问正文交给 AI |
  | 结果 | 结果卡 Markdown + `.lingqu/migrate/<工程>.md` + 三段式报告 `.lingqu/report/<工程>.{md,html}` |

- **新屏「⚡ 一键迁移」**（左栏第一项、默认屏）+ 顶栏按钮：路径框、`自动应用代码改造`（留 `.bak` 可回滚）、
  进度条、8 步时间轴（待跑/进行中/通过/未过/跳过 五态）、结果卡（`renderMd` 渲染，含报告路径）
- **`lingqu-cli migrate --path <工程>`**：命令行一条命令跑完整条链（内部强制 `--wait`，
  跑到出结果才返回，直接打印结果 JSON/Markdown）——这是 agent 能真正"干完所有的活"的入口
- **`t2h:ai_brief`（G1+G2）**：`{path, step}` → 把该步的**落档正文（截断 3000 字）+ 日志尾 40 行 +
  该步判据**拼成提问正文。判定权在后端（`observeTaskStep`），**没跑过（落档不存在）不算失败**、
  不打扰模型；`force` 仅供界面探针
- **`t2h:ai_decide`（G4）**：从 AI 回复里抽 `lingqu-decision` 围栏块 → 确认卡（采纳/忽略）→
  人点一下才落 `.lingqu/port/<工程>/decisions.json`，`source=ai` 标出"AI 提案、人确认"
- 前端两个开关（localStorage 记住）：`失败自动问 AI`（默认开）、`自动跑只读命令`（默认关）
- `cliAutoRunAllowed`（纯函数 + 单测）：自动执行的**更严一层**白名单
  （`scan/deps/sign/verify/report/batch/resume/env/diagnose`），`build/hap/port/revert/deploy/migrate` 一律不自动跑
- `t2h:cli_run` 新增 `preflight`（只回答能不能跑、不执行）与 `auto`（是否在自动白名单）
- 纯函数层：`src/agent_prompt.cj`（`tailLinesOf` / `clipCharsOf`（按字符切，不切坏汉字）/
  `stepAskCaveat` 八步判据 / `buildAutoAskPrompt` / `parseDecisionBlocks`）、
  `src/migrate.cj`（步骤编排、`MigrateState` 深拷贝快照、`migrateVerdict` 四态、
  `migrateResultMarkdown`、`migrateAskPrompt`）
- `ui_report` 新增：`autoDiag*/autoRun*/decide*/migrate*` 共 15 个字段（页面 + 后端白名单两处一起加）
- 技能与工程上下文同步写进两个新约定（建议命令一行一条、`lingqu-decision` 决策块格式），
  否则模型不会产出界面能解析的东西

### Fixed

- **写错返回值语法时编译器指错位置**：`func f(...) -> T` 少写冒号会把错误报到**下一个**函数声明
  （`body of function 'X' is missing` / `found '->'`），照报错位置改永远改不对（§4-67）
- **`t2h:port` 的 `apply` 在新工程上必失败**（0.11.0 起潜伏）：`ensurePortDirs()` 只建到
  `.lingqu/port`，逐文件备份目录 `.lingqu/port/<工程>/` 要等 `t2h:decisions` 记过决策才碰巧存在 →
  第一次「应用改造」抛 `The input path 'parent' … does not exist`、`ok=false`。现在 apply 前自建
- 一键迁移结果卡写不进去：把**文件**路径传给了 `ensureDirOf`（它按目录逐段建）→ 先建 `.lingqu/migrate`
- 「规则改造」在已迁移工程上显示**未跑**：port 的落档是可选的（没东西可改就不写 decisions.json /
  不留 .bak）。改为"命令 ok 且落档不存在 → 通过（幂等）"
- deploy 摘要把最有用的那句丢了：只写"启 失败"，看不出为什么。抽纯函数 `deployNoteOf`
  在失败时带上 `start.detail` 的处置提示（真机实测：设备锁屏 `10106102`），且不叠 `｜｜`

### 证据（本机 Windows x64，2026-11-01）

```
门禁：五道闸全绿 build-biz:PASS test:PASS(TOTAL=226) check:PASS build-app:PASS build-cli:PASS

① 一键迁移真机实跑（`lingqu-cli migrate --path E:\test\rust\habit-tree --wait`，约 60 秒）：
   扫描分析｜通过｜单元 R=24 / D=24 / U=0 / 评分 63 / 阻塞 1 项
   依赖评估｜通过｜依赖 453 包 / 需 patch 0 / 不可用 10
   规则改造｜通过｜已应用改造（有备份，未记人工决策）
   交叉编译｜通过｜exit=0 / 错误 0 / 前端指纹 一致 0、过期 0、缺 0
   HAP 装配｜通过｜HAP 7249833 字节 / arm64 库条目 3 个 / rawfile 0 个死资源
   签名体检｜通过｜签名态 debug（开发直装）｜profile 绑定了本机 UDID，可直装
   真机部署｜未过｜装 成功 / 启 失败｜处置：设备在锁屏，拒绝自动解锁 → 解锁后重试（FP-014）
   → percent=87，结论「停在真机部署」；报告 .lingqu/report/habit-tree.{md,html}；
     结果卡 .lingqu/migrate/habit-tree.md；askPrompt 已拼好（含落档 + 日志尾 40 行 + 判据）

② 新屏无 JS 错误（`LINGQU_UI_PROBE=1` 实机）：
   ui_report：screens=8 activeScreen=migrate migrateRows=8 autoDiag=true autoRun=false
              gridColumns=240px 652px 372px wsState=connected frames=3 mdOk=true errorCount=0
   同一次运行的断点板：resumeDone=7 resumeFailed=1 resumePercent=87 resumeNext=deploy
   —— 与一键迁移的 percent=87 /「停在真机部署」逐字一致（两条链路读同一份落档）
```

## [0.35.0] - 2026-11-01

**主题**：**AI 接入第 4 步 —— 一键执行 + 结果回填**：AI 回复里出现的 `lingqu-cli …` 建议
直接变成可点按钮；点一下真跑，结果卡回填对话，还能一键「让 AI 分析结果」。**闭环成立**。

### Added

- **命令 `t2h:cli_run`**（三处联动齐全）：`{cmd, flags}` → 组装 argv → 复用 `dispatchCli`
  （与 CLI/界面**同一份实现**）→ 回 `{ok, allowed, reason, exitCode, result}`
- **安全边界 `cliRunAllowed`（纯函数 + 单测）**——误点一个按钮不该能把工程改坏：

  | 放开（只读/幂等可回滚） | 拒绝（并告诉人该去哪个界面点） |
  |---|---|
  | `scan` `deps` `resume` `report` `verify` `env` `diagnose` `batch` `build` | `deploy`（动真机）→ ⑥ 屏「安装并启动」 |
  | `sign`（体检）| `sign --apply`（改用户工程）→ ⑤ 屏「写回签名配置」 |
  | `skill` / `agent_context`（status/install，幂等且可移除） | `port`（改源码）→ ④ 屏；`revert` → ④ 屏；`hap`（耗时+产物）→ ⑤ 屏；`decisions` → ④ 屏 |

- 前端：`cliSuggestParseInPage` 从回复里抽建议（列表符号/行内码/去重）→ 挂一排「▶ 命令」按钮
  → 点击后结果卡（退出码 + 摘要 + JSON 预览 + **「让 AI 分析结果」**按钮，点它才发消息，
  不悄悄多花一次模型调用）
- `ui_report` 新增 `cliSuggest/cliSuggestRows/cliLastCmd/cliLastExit/cliLastOk/cliRan/cliBlocked/cliResultCards`
- 探针 `LINGQU_UI_PROBE=cli`（点一次允许的命令）与 `cli-block`（点一条会被拦下的命令）

### 证据（本机 Windows x64，2026-11-01）

```
① 允许路径 LINGQU_UI_PROBE=cli（确定性注入一条 `lingqu-cli resume --path …` 建议再点它）：
   ui_report：cliSuggest=1 cliSuggestRows=1 cliLastCmd=resume cliLastExit=0 cliLastOk=true
              cliRan=1 cliBlocked=0 cliResultCards=1 errorCount=0
② 拦截路径 LINGQU_UI_PROBE=cli-block（注入 `lingqu-cli deploy --path …` 再点）：
   ui_report：cliLastCmd=deploy cliLastExit=-2 cliLastOk=false cliBlocked=1 cliResultCards=1 errorCount=0
   → 界面显示「⚠ 这条命令要在界面里点：真机部署会安装并启动应用，请在 ⑥ 屏点「安装并启动」」
门禁：五道闸全绿（build 0 warning / TOTAL=201 / check / 骨架 build / cli build）
```

### 未做（如实）

- 「让 AI 分析结果」是**手动点**（避免每条建议都自动多一轮模型调用）；自动回填留作可选项
- 建议解析只认 `lingqu-cli <cmd>` 开头（不猜 `t2h:` 或自然语言里的命令名）
- ④ 之后 AI 接入四步全部就绪；P7 的 5 样本推进仍未做

---

## [0.34.0] - 2026-11-01

**主题**：**AI 接入第 3 步 —— `t2h:*` CLI 化**：新增 `lingqu-cli` 可执行文件，让 **agent 的 bash
能把工具真跑起来**（此前只有应用内 IPC 入口，AI 只能"讲"不能"做"）。

### Added

- **`cli/` 目标**（独立可执行 `lingqu-cli`，产物 `cli/target/release/bin/main.exe`，分发时改名即可）：
  `scan / deps / port / revert / decisions / diagnose / build / hap / sign / deploy / verify /
  report / batch / resume / skill / agent_context / env`
- `src/cli.cj`（业务包内，可单测）：
  - `argvToJson` / `argvToJsonWithValues`：`--k v` 与 `--k=v` 两种形态都认；布尔开关（`verifyOnly`
    等）不带值算 true；**纯命令（不带开关）也会占位**——否则会报"不认识的命令："
  - `cliCommandSupported` / `cliHasCommand` / `cliUsage`：白名单 + 用法（GUI 专属 `quit`/`cjh_*` 不开放）
  - `dispatchCli`：**零重构复用** `CommandHandler`——`XxxCommand().handle(name, args, IpcContext("cli", IpcHub()))`，
    所以 CLI 与界面按钮是**同一份实现**，不会出现"CLI 能跑、界面报错"
- 门禁从 **4 道 → 5 道**：新增 ⑤ `cli cjpm build`（零警告）
- `cli/README.md`（命令表 / 退出码 / 运行环境 / 已知限制）
- 技能正文与 `AGENTS.md` 受管区块都改成**能真跑的命令**（`lingqu-cli scan --path .` 等），
  并写明"先 `resume` 看停在哪步，再跑那一步"

### 证据（本机 Windows x64，2026-11-01）

```
门禁：build-biz:PASS test:PASS(TOTAL=198) check:PASS build-app:PASS build-cli:PASS
--list：列出 17 个命令（用法 + 退出码说明）
resume --path E:\test\rust\habit-tree → exit=0，JSON 4498 B
   {"ok":true,"project":"habit-tree","next":"port",
    "hint":"下一步是「规则改造」——从这一步接着做（前 6 步已有落档证据）"}
scan --path E:\test\rust\habit-tree（在空目录里跑）→ exit=0
   {"ok":true,"out":".lingqu/scan/habit-tree.json","R":24,"C1":100,…}
   → 落档真的写在**当前目录**：.lingqu/scan/habit-tree.json 10113 B
坏命令 nosuchcmd → exit=1，stderr 给出"不认识的命令：nosuchcmd"
```

> 关键点：`scan` 是在一个**空目录**里跑的，落档落在那个目录的 `.lingqu/` ——
> 这正是 agent 需要的行为（它在用户工程目录里跑，产物就该进用户工程）。

### 未做（如实）

- `lingqu-cli.exe` 的名字要打包/分发时改（cjpm 产物固定叫 `main.exe`）；尚未加进 `packaging/`
- cjh 技能 frontmatter 的 `tools:`（声明式工具）**硬编码 `/bin/bash -c`**，Windows 上用不了
  （上游 `registry.cj` 实现），所以本项目让 agent 用它的 bash 工具（Windows 上自动选 Git Bash）调 CLI；
  这条已记进 `cli/README.md` 与进度记录，作为上游回馈项
- ④（AI 建议命令的一键执行 + 结果回填）未开工

---

## [0.33.0] - 2026-11-01

**主题**：**AI 接入第 2 步 —— 工程上下文**：让 agent 的 bash/文件工具真正落到用户的工程上，
并把「工具链 + 落档位置 + 口径」写进工程的 `AGENTS.md`（cjh 会自动注入 system prompt）。

### Added

- **命令 `t2h:agent_context`**（三处联动齐全）：`status` / `install` / `remove`
  - `install`：往目标工程写 `AGENTS.md` **受管区块** + `POST /api/workspaces/switch`
    把 cjh 的 workspace 切到该工程（cjh 会 chdir **并重置持久 bash 会话**）
  - `remove`：只删灵渠那块，用户原有内容保留；文件因此变空时直接删文件
- `src/agent_context.cj`：
  - 纯函数：`agentContextPathOf` / `agentContextBody`（落档清单 + 工具清单 + 五条口径）/
    `hasAgentBlock` / `injectAgentBlock`（**幂等**）/ `removeAgentBlock`（**可撤销**）
  - IO：`cjhSwitchWorkspace`（POST 切工作区）/ `cjhCurrentWorkspace`（GET 回读）
- ① 屏「工程上下文（AGENTS.md）」卡：受管区块状态 / cjh 工作区 / 「查状态」「装上下文」「移除区块」
- `ui_report` 新增 `agentHasBlock/agentPath/agentSwitched/agentWorkspace/agentError`；
  探针 `LINGQU_AGENT=install|status|remove` + `LINGQU_AGENT_PATH`

### 为什么这样做（用户拍板）

| 方案 | 取舍 |
|---|---|
| 只写 AGENTS.md 不切 workspace | ❌ 只做一半：agent 的 bash 还在灵渠目录，知识再全也落不到工程上 |
| 只切 workspace 不写内容 | ❌ agent 不知道有哪些工具、落档在哪、口径是什么 |
| **切 workspace + 受管区块 AGENTS.md** | ✅ 本轮采纳：cjh 原生机制（AGENTS.md 自动注入 + workspace chdir） |
| 改 cjh 全局 `systemPrompt` | ⏸ 仅作兜底：全局单值、切换工程要重写、别的客户端用不到 |

### 证据（本机 Windows x64，2026-11-01，临时工程 `.lingqu/tmp-agent/demo-app`）

```
造一个"用户已有自己的 AGENTS.md"的工程（4 行用户内容）：
LINGQU_AGENT=install LINGQU_AGENT_PATH=<tmp> →
  ui_report：agentHasBlock=true agentSwitched=true
             agentWorkspace=E:\...\.lingqu\tmp-agent\demo-app agentError="" errorCount=0
  AGENTS.md：用户原有 4 行**原样保留**，其后追加
             <!-- lingqu:begin … --> 区块 + 落档表 + 工具清单 + 五条口径 <!-- lingqu:end -->
LINGQU_AGENT=remove →
  ui_report：agentHasBlock=false errorCount=0
  AGENTS.md 回到用户原来那 4 行（灵渠区块整段消失）
```

> `agentSwitched=true` 来自 cjh 的 `POST /api/workspaces/switch` 回执；`agentWorkspace` 是紧接着
> `GET /api/workspaces` 回读的最近工作区——**不是"我们以为切了"**。

### 未做（如实）

- 装完上下文后 **cjh 的 system prompt 不会自动刷新**（它在会话开始时装配）——界面提示"新建一次会话"；
  真正自动刷新需要 cjh 侧支持，属上游改造
- 没做"按工程自动切 workspace"（目前要用户点一下）；③ 的工具 CLI 化之后再串成一条链
- ③（`t2h:*` CLI 化）与 ④（一键执行闭环）未开工

---

## [0.32.0] - 2026-11-01

**主题**：**AI 接入第 1 步 —— 把 `t2h-ohos-port` 技能真正装进 cjh**。
在此之前 `skills/t2h-ohos-port/` 只是躺在仓库里，cjh 从未见过它：AI 助手对鸿蒙移植的坑、
签名配方、工具链差异一无所知（只能靠模型自己的通用知识）。

### Added

- **命令 `t2h:skill`**（三处联动齐全，五个动作里本轮做两个）：
  - `status`：安装状态（missing / installed / outdated，按**内容 SHA256**判，不看时间戳）
    + `enabled_skills` 白名单语义 + references 份数 + **问 cjh `GET /api/skills` 是否真的加载了**
  - `install`：把 SKILL.md 写到 `~/.cjh/skills/t2h-ohos-port.md`，references 拷到
    `~/.cjh/skills/.t2h-ohos-port/references/`；覆盖前留 `.bak`；幂等
- `src/skill_install.cj`（`lingqu` 包）：
  - 纯函数：`cjhSkillsDirOf/skillTargetPathOf/skillRefDirOf`（路径约定）、
    `rewriteSkillLinks`（把 `references/x.md` 改成**绝对路径**——agent 的 cwd 是用户工程，
    相对路径必然读不到）、`skillStateOf`（三态）、`skillEnableNoteOf`（白名单语义，
    **空=全部启用，不要乱加白名单**——加了会把别的技能关掉）、`skillSourceCandidates`（向上找仓库）
  - 有 IO：`skillSourceDir`（`LINGQU_SKILL_SRC` → `LINGQU_HOME/skills` → cwd 上溯 6 层）、
    `skillFinalBodyOf`（**安装与期望哈希共用同一条生成路径**）、`installSkill`、`cjhSkillNames`
- ① 屏「AI 迁移技能」卡：安装状态 / cjh 已加载 / references 份数 / 来源 + 「查状态」「安装技能」
- `ui_report` 新增 `skillState/skillPath/skillRefs/skillCjhSeen/skillCjhCount/skillSource/skillNote`；
  探针 `LINGQU_SKILL=install|status`
- `src/packed_assets.cj` 增 `PACKED_SKILL_B64` 存根（单文件产物里没有 `skills/` 目录时用内嵌正文）

### 口径

| 判据 | 怎么判 | 为什么 |
|---|---|---|
| 装了没 | 目标文件存在 + **内容哈希**比对来源 | 时间戳会被 checkout/复制骗过 |
| 生效没 | **问 cjh `/api/skills` 里有没有它** | 装到磁盘 ≠ cjh 加载了（frontmatter 坏了/白名单关了都不可见） |
| 白名单 | 空 = 全部启用；非空才提示"要不要加进去" | 乱加一项会把 cjh 自带的仓颉知识技能一起关掉 |

### 证据（本机 Windows x64，2026-11-01）

```
装前：~/.cjh/skills 不存在
LINGQU_SKILL=install →
  ~/.cjh/skills/t2h-ohos-port.md                       5829 B
  ~/.cjh/skills/.t2h-ohos-port/references/{arkweb-shims,cargo-patches,pitfalls,signing,toolchain}.md
                                                      4668 / 5184 / 5467 / 9652 / 3267 B
  ui_report：skillState=installed skillRefs=5 skillSource=repo
             skillCjhSeen=true skillCjhCount=1 errorCount=0
技能里的相对链接已改写为绝对路径：
  [signing.md](C:\Users\yang\.cjh\skills\.t2h-ohos-port\references/signing.md)
```

> `skillCjhSeen=true` 是本轮最关键的证据：cjh 自己的 `/api/skills` 列出了这个技能，
> 说明它**已经进入 system prompt 的注入范围**，不是"文件在那儿"而已。

### 未做（如实）

- 单文件产物里目前只能装**内嵌正文**（`PACKED_SKILL_B64` 存根还没被打包脚本填充，下一轮补）；
  references 要 `LINGQU_SKILL_SRC` 指到仓库才拷得到
- 「一键移除/卸载技能」没做；白名单写入（`POST /api/settings`）没做——当前机器 `enabled_skills`
  为空（= 全部启用），不需要写配置，需要时再补
- ① 之后的 ②③④ 见 `docs/进度记录.md` 的 AI 接入计划

---

## [0.31.0] - 2026-11-01

**主题**：**代码块语法高亮 + AI 回复平铺展开**。0.30.0 把 Markdown 渲染补上了；
这一轮补齐两块：① 代码块从"等宽纯文本"升级为 hljs 高亮；② 用户裁定"回复正文铺满整栏"，
assistant 消息去掉头像栏与气泡框，正文从聊天区左边缘起排。

### Added

- **highlight.js v11.9.0 整份内联**（BSD-3-Clause，取自 `cj-tauri/examples/ai-chat` 的
  `ui/vendor/highlight.min.js`）：页面要被打进单文件 exe（`pack-win-single` 只内联
  `ui/index.html`），外部 `<script src>` 在单文件产物里会 404，所以必须内联。
  更新方式写在插入处的注释里（拿 ai-chat 那份整段替换）
- 代码块高亮：带语言标注按语言、否则 `highlightAuto`；**库缺失/未知语言/词法异常一律退化为
  `escHtml`**——高亮失败不能把整条回复弄挂
- 配色不引 vendor 主题：关键字紫 / 字符串橙 / 数字·内建青 / 函数名蓝 / 注释灰（`.hljs-*` 类名由库生成）
- 页内自检从 12 条 → **16 条**（新增 `hl-keyword` / `hl-string` / `hl-comment` / `hl-unknown-lang`）
- `ui_report` 新增 `mdHljs`（版面里被切成词法 span 的数量）与右栏版面量尺：
  `aiDockW / aiBubbleW / aiBubbleGap / aiInnerLeft / aiFlatLeft / aiAvatars / aiAvatarsShown / aiLastHtml`

### Changed（版面：平铺展开，用户裁定 A）

- `.msg:not(.me)`：头像栏隐藏、气泡框（背景/边框/内边距/圆角）全部去掉，正文贴聊天区左边缘；
  **用户自己发的消息仍保留气泡**（"我说的话"要和"AI 说的话"一眼区分）
- Markdown 表格 `width:100%`：能放下时撑满整栏，放不下时外层 `.tbl` 横向滚动

### 证据（本机 Windows x64，`LINGQU_UI_PROBE=md`，cjh 真实回复）

```
渲染：mdOk=true mdFail=""（16 条自检全过，含 4 条高亮）
      mdBlocks=4（h2 + ol + table + pre）  mdCodeCopy=1（复制按钮）  mdHljs=6（代码块里 6 段词法）
版面：aiDockW=372 aiBubbleW=299→333（多给内容 34px） aiBubbleGap=24
      aiFlatLeft=14（= 聊天区 padding，回复贴左边缘；改前是 14+25+9=48）
      aiAvatarsShown=0（头像栏已隐藏，DOM 里仍有 5 个节点但宽度为 0）
      errorCount=0 tag=probe-done
```

### 未做（如实）

- 用户自己的消息不渲染 Markdown（保持纯文本，避免"我打的星号被吃掉"）
- 高亮只影响代码块；行内 `code` 按统一配色，不做语言识别
- 内联 hljs 让 `ui/index.html` 从 ~187 KB 涨到 ~310 KB（单文件 exe 里可忽略；dev 加载同样走同一份）

---

## [0.30.0] - 2026-11-01

**主题**：**AI 回复的 Markdown 渲染**——气泡一直是 `textContent = acc` 塞纯文本，
模型输出的标题/列表/表格/代码块全被压平（表格变成一串带竖线的句子），"看起来不像个界面"。
本轮对齐 `cj-tauri/examples/ai-chat` 的 `renderMd`，把渲染补上。

### Added

- **`renderMd(src)`**（`assets/ui/index.html`，移植自 ai-chat 并减少差异）：
  - 块级：代码围栏（带语言标注）、`#`~`######` 标题、`---` 分隔线、`>` 引用、无序/有序列表、
    **表格**（外层 `.tbl` 横向可滚）、段落
  - 行内：行内码、粗体、斜体、删除线、链接（**只放行 http/https**，其余只留文字）
  - 顺序固定：**先摘代码块 → 再整体转义 → 只认受控标记**（模型输出是外部内容，
    先转义 `<` `>` `&` `"`，之后加的都是我们自己生成的标签）
- 代码块**复制按钮**（`MD_CODES` 里存原文，复制源码而不是高亮后的 HTML），事件委托绑在聊天容器上
- Markdown 排版 CSS（标题/列表/表格/代码块/引用/分隔线/链接 + 流式光标 `.md-cur`）
- 流式与收尾都走 renderMd：`flushStream` 追加光标块，`finishTurn` 出完整版
- **页内自检 + 版面证据**：`mdSelfCheck()` 12 条断言（转义/粗体/行内码/代码块/标题/列表/有序表/
  表格/引用/链接白名单/非字符串容错），结果回投 `ui_report` 的 `mdOk/mdFail`；
  另加 `mdBlocks`（版面里真正渲染出的块级元素数）与 `mdCodeCopy`（复制按钮数）
- 探针 `LINGQU_UI_PROBE=md`：让模型用 markdown 回「标题 + 有序列表 + 表格 + 代码块」，
  这样版面证据不依赖人肉看截图

### 与 ai-chat 的差异（有意为之）

ai-chat 的 vendor 里内联了 highlight.js（122 KB）做语法高亮；本项目页面要编进单文件 exe，
本轮**只做 Markdown**（代码块保留等宽 + 复制按钮），语法高亮留作可选后续——
要加的话是"内联成熟库"，不是自己写 tokenizer（ai-chat 的注释里也是这个结论）。

### 证据（本机 Windows x64，2026-11-01）

```
LINGQU_UI_PROBE=md（cjh 真实回复，原文含 ## 标题 / 有序列表 / 表格 / ```bash 代码块）
ui_report：mdOk=true  mdFail=""（12 条页内自检全过）
           mdBlocks=4（h2 + ol + table + pre 各一，确实渲染成了元素而不是文本）
           mdCodeCopy=1（代码块复制按钮已渲染）
           frames=68 lastFrameType=done errorCount=0 tag=probe-done
```

> 对照：渲染前同一条回复在气泡里是 `## 构建步骤 1. … | 命令 | 作用 | …` 一整坨纯文本。

### 未做（如实）

- 语法高亮（highlight.js）未引入：见上面的取舍；要加就是内联 vendor（约 122 KB）
- 用户自己发的消息仍是纯文本转义（不回渲染 markdown）——避免"我打的星号被吃掉"
- 渲染只在 `assets/ui/index.html` 侧，未做单测：纯字符串函数靠页内自检 + `ui_report` 断言
  （渲染不在仓颉侧的纯函数层，无法进 `cjpm test`）

---

## [0.29.0] - 2026-11-01

**主题**：**P7 开工 —— T7-3 5 样本迁移矩阵**：把每个样本自己的落档并排成一张表
（评分 / 依赖 / 编译 / 装配 / 签名态 / 部署 / 可用率 / 8 步 / 人工介入 / 判定），
A1/A3/A4 三个验收指标在矩阵层有了直接读数。

### Added

- **命令 `t2h:batch`**（三处联动齐全）：`samples`（`路径1|路径2`，也认逗号）缺省时按
  `.lingqu` 下出现过的工程名收集 → 落 `.lingqu/batch/matrix.{md,html,json}`（`lingqu/batch/v1`）
- `src/batch/batch.cj`（纯函数层，`lingqu.batch`）：
  - `batchVerdict`（达标 ≥80 / 未达标 / **未验证**）、`batchCompletion`、
    `summarize`（样本数 / 已验证数 / 平均可用率 / 平均评分 / A3 人工介入 / A1·A4 判定）
  - `batchRowCells` + `batchHeaders`（12 列，表头与单元格共用一份口径）、
    `renderMatrixMarkdown` / `renderMatrixHtml`、`summaryLine`
- `src/batch_feed.cj`：逐样本读自己的落档汇总成一行（**只读盘**，不影响任何样本）
- ⑦ 屏新增「5 样本迁移矩阵」卡：样本路径输入 + 生成按钮 + 12 列横向滚动表 + 汇总与 A1/A4 判定
- `ui_report` 新增 `batchOk/batchSamples/batchVerified/batchAvgRate/batchAvgScore/batchHuman/`
  `batchA4/batchA1/batchHtml/batchRows/batchA4Rows`；探针 `LINGQU_BATCH_SAMPLES`
- `docs/5样本矩阵-实测.md`：把本机实测矩阵原样留档

### 口径（矩阵说错话比没有矩阵更糟）

| 情形 | 矩阵里怎么写 | 为什么 |
|---|---|---|
| 没有落档 | 该列写「未跑」，**不参与任何平均** | 未验证 ≠ 0 分（把没跑算成 0 会让平均凭空变低），也 ≠ 通过 |
| 跑了但没过 | 「未过」 | 与「未跑」必须分开——否则人分不清"还没做"和"做了不行" |
| 0 个已验证样本 | 平均可用率 `-1`（界面显示 `—`）、A4 判未达标 | "没验"不能算"通过" |

### 证据（本机 Windows x64，2026-11-01，5 个真实样本）

```
LINGQU_BATCH_SAMPLES=E:\test\rust\habit-tree|E:\test\rust\cc-switch-harmonyos|
                    E:\test\rust\m3u8dl-tauri|E:\test\rust\atomMqtt|E:\test\rust\tauri-mqtt-client-ohos
汇总：样本 5 个（已验证 1 个）｜平均评分 66｜平均可用率 60%｜人工介入 0 处（均 0.0 处/应用）

| 样本 | 评分 | 单元/未知 | 依赖 | 编译 | 装配 | 签名态 | 部署 | 可用率 | 8步 | 人工 | 判定 |
| habit-tree | 63 | 24 / 未知 0 | 430 包 / 不可用 10 | 未过 | 通过 | debug | 成功 | 60%（3/5） | 6/8（75%） | 0 | 未达标 |
| cc-switch-harmonyos | 58 | 320 / 未知 0 | 724 包 / 不可用 11 | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 2/8（25%） | 0 | 未验证 |
| m3u8dl-tauri | 77 | 11 / 未知 0 | 602 包 / 不可用 11 | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 2/8（25%） | 0 | 未验证 |
| atomMqtt | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 0/8（0%） | 0 | 未验证 |
| tauri-mqtt-client-ohos | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 未跑 | 0/8（0%） | 0 | 未验证 |

ui_report：batchOk=true batchSamples=5 batchVerified=1 batchAvgRate=60 batchAvgScore=66
           batchHuman=0 batchA4=false batchA1=false batchRows=5 errorCount=0
```

### 未做（如实）

- **A1 未达成（1/5 验证）**：cc-switch-harmonyos 与 m3u8dl-tauri 只跑了扫描 + 依赖，
  编译/装配/签名/部署/验证都没跑；atomMqtt 与 tauri-mqtt-client-ohos 一行落档都没有。
  下一轮按样本逐个推（每个样本的构建链以分钟计）
- 矩阵暂无"耗时"列（落档不记每步耗时，需改各命令 schema）；T7-4 基线实验与 T7-5 消融未开工

---

## [0.28.0] - 2026-11-01

**主题**：**T5-4 签名两态（debug / release）+ 上架前强提醒**——P5 的最后一块。
工具现在会明确告诉你"当前是哪一态、另一态怎么切"，而不是只在装机失败时给一句 9568322。

### Added

- `src/compiler/sign.cj` 新增两态纯函数层：
  - `judgeSignMode(hasConfig, profileType)` → `debug` / `release` / `unknown`；
    **判不出来就说 unknown，绝不猜 debug**（猜错会让人以为能装机）
  - `assessSignMode(...)` → `SignModeState`：当前态 + 能否直装 + 是否上架齐备 +
    **强提醒** + 双向下一步 + 切态步骤 + 本机 release profile 份数
  - `signModeReminder(mode)`：debug 态写明「只能装已注册设备，**不能上架**」；
    release 态写明「可以上架；真机直装被 9568322 拒是正常的」
  - `signReleaseSteps()` / `signDebugSteps()`：两个方向的可照做步骤清单
- `t2h:sign` 回投并落档 `mode` 段（`mode / modeLabel / canInstallDevice / releaseReady /
  reminder / installNextStep / releaseNextStep / releaseProfileCount / switchSteps`），
  日志增 `[mode]` 行
- ⑤ 屏签名卡：签名态 / 可直装 / 上架齐备三个指标 + 按态染色的提醒栏 + 切态步骤清单
- `ui_report` 新增 `signMode/signModeLabel/signReleaseReady/signReminder/signReleaseProfiles/signSwitchRows`
- 报告（`t2h:report`）：debug 态时「没做什么」写「签名是 debug 态：可直装真机，但**不能上架**」，
  「需要你做什么」原文引用强提醒 + 上架下一步
- 断点板（`t2h:resume`）：**release 态不再被算成"签名体检失败"**——它装不上真机是设计使然

### Changed

- 版本 0.27.0 → **0.28.0**；单测 **171 → 177**（`src/tests/sign_mode_test.cj` 5 例 +
  报告带签名的 1 例）

### 证据（本机 Windows x64 + 真机 HAD-W32 在线的 UDID 读取，2026-11-01，habit-tree）

```
LINGQU_SIGN_PATH=E:\test\rust\habit-tree
.lingqu/sign/habit-tree.json 的 mode 段：
  mode=debug  modeLabel="debug（开发直装）"  canInstallDevice=true  releaseReady=false
  releaseProfileCount=0
  reminder="⚠ 当前是 debug 签名：profile 绑定了本机 UDID，只能装到已注册设备，**不能上架**
            （AGC 不接受 debug 证书）。上架前必须切回 release profile 并重新签名。"
  releaseNextStep="上架前：本机还没有 release profile（~/.ohos/config 里 0 份），
                   先去 AGC 生成 release 证书与 profile，再按下面步骤切"
  switchSteps=5 条（生成 release 证书/profile → 放材料 → 改 build-profile.json5 →
                    重跑装配 HAP → 上传前再体检确认 mode=release）
ui_report：signMode=debug signModeLabel=debug（开发直装） signReleaseReady=false
           signReleaseProfiles=0 signSwitchRows=5 errorCount=0
报告（.lingqu/report/habit-tree.md）：
  没做什么：签名是 debug 态：可直装真机，但**不能上架**（AGC 不接受 debug 证书）
  需要你做什么：⚠ 当前是 debug 签名…（强提醒原文）+ 上架前：本机还没有 release profile…
           （reportDid=8 reportUndone=7 reportNeed=6，errorCount=0）
```

> 真机侧事实：`hdc shell bm get --udid` 读到本机 UDID、profile 含它 → debug 态判定可直装；
> `~/.ohos/config` 里 **0 份 release profile**，所以"切回 release"不是拨开关，要先做材料——
> 提醒里如实写了这一点（不做 release 签名的前提是**没有**华为 release 证书，本机确实没有）。

### 未做（如实）

- **release 态的实机判定未验证**：本机没有 release 材料，无法造出 release profile 来跑一遍
  `mode=release` 的真机路径（判定逻辑有单测覆盖 `assessSignMode(release)`，属"纯函数已验、
  真机未验"）。拿到 release 证书后需补一次真机实测
- 未做"一键切换 signingConfig"（要改工程文件且依赖 release 材料存在，风险高；本轮只给步骤与提醒）
- 上架除签名外还有隐私政策/图标/兼容 SDK 版本等非签名项，不在 T5-4 范围

---

## [0.27.0] - 2026-11-01

**主题**：**P6 收口 —— `t2h:report` 上线 + ⑦ 迁移报告屏接真数据**：三段式报告完全从落档推导，
MD / HTML / JSON 一键导出；⑦ 屏原来的假数据（"38 分钟 / 3 处人工介入 / 87% 可用率"）全部换成真实读数。

### Added

- **命令 `t2h:report`**（三处联动齐全）：读 `.lingqu` 下的落档 → 生成三段式报告
  → `.lingqu/report/<工程>.{md,html,json}`（`lingqu/report/v1`）。
  纯读盘：**不采证、不跑子进程、不改工程**，可以反复出。
- `src/report/report.cj`（纯函数层，`lingqu.report`）：
  - `buildReport`：8 步状态 + 可用率清单 + 决策 → 三段（做了什么 / 没做什么 / 需要你做什么）；
    没跑的写「还没跑」、没过的写「没过」、跳过的写「按人工判断跳过」——**三种状态不混**；
  - `stepActionHint`：每步对应界面上一个按钮（报告里的"需要你做什么"因此可执行、不是空话）；
  - `renderReportMarkdown` / `renderReportHtml`（自包含单文件）/ `escapeHtmlText`
    （按字节替换 5 个危险 ASCII，**中文原样保留**）；
  - `countHumanDecisions`（A3 口径：`accepted` 才算一次介入，`ignored` 只留痕）
- `src/report_feed.cj`：把落档汇总成 `MigrationFacts`（8 步走 `t2h:resume` 的同一套观测、
  清单三类判定分列、证据文件计数、附录只列**真实存在**的落档）
- **⑦ 屏接真数据**：四个指标（工程 / 8 步进度 / 人工介入 A3 / 可用率 A4）+ 三段卡片 +
  「生成迁移报告」「导出 Markdown / JSON / HTML」+ 证据索引（附录逐条列出落档路径）
- `ui_report` 新增 `reportOk/reportDid/reportUndone/reportNeed/reportRate/reportHuman/`
  `reportHtml/reportMd/reportConclusion/reportRows`；探针 `LINGQU_REPORT_PATH`

### Changed

- 版本 0.26.0 → **0.27.0**；单测 **165 → 171**（`src/tests/report_test.cj`，6 例）

### 口径（与 verify / task 一致，别改薄）

| 类别 | 报告里的位置 | 为什么 |
|---|---|---|
| 平台限制 | 没做什么（标注「不算失败」） | 鸿蒙没有托盘是能力位 0，不是工具失败；混进失败会让人误判 |
| 未验证 | 没做什么 + 需要你做什么（补验证） | 没证据就不算通过（A4 的分母口径） |
| 失败 | 没做什么 + 需要你做什么（重跑） | 失败要能一眼看到闸的第一条原因 |
| 人工跳过 | 没做什么（标注「按人工判断跳过」） | 跳过是人的结论，但它不是通过 |

### 证据（本机 Windows x64，2026-11-01，habit-tree）

```
启动参数：LINGQU_REPORT_PATH=E:\test\rust\habit-tree  LINGQU_UI_SCREEN=report  LINGQU_UI_PROBE=1
产物：.lingqu/report/habit-tree.md (2804 B) / .html (3796 B) / .json (3912 B)
结论：habit-tree：8 步完成 5/8（62%），核心功能可用率 60%，0 处人工介入
做了什么（7 条）：扫描 R=24… / 依赖 430 包… / HAP 7249837 字节… / 部署装启成功 hilog 40 行 /
                验证可用率 60% / 采集到 2 份真机证据 / 功能清单通过 3/5 项
没做什么（7 条）：「规则改造」还没跑 /「交叉编译」没过：…闸未过：.so 内嵌的 1 个前端产物在 dist/
                里已不存在 /「签名体检」还没跑 / 平台限制（不算失败）1 项 / 未验证 2 项 / 无人工决策记录
需要你做什么（5 条）：三条步骤动作（各对应界面按钮）+ 两条补验证
ui_report：reportOk=true reportDid=7 reportUndone=7 reportNeed=5 reportRate=60 reportHuman=0
           reportRows=19 errorCount=0 activeScreen=report
```

### 未做（如实）

- 报告里没有"总耗时"这一项——落档目前不记每步耗时（要改各命令的落档 schema，单独一轮做）；
  ⑦ 屏因此也去掉了原来的"38 分钟"假数字，而不是编一个
- 报告未做「打开文件」按钮（跨平台 opener 涉及启动外部进程，本轮不动）；路径已给全，可自行打开
- T5-4 release 签名两态、P7 5 样本矩阵仍未开工

---

## [0.26.0] - 2026-11-01

**主题**：**T6-5 断点续迁**——8 步迁移链的进度变成盘上可查的证据（`.lingqu/tasks.json`），
关掉应用、隔天回来能接着做；④ 屏的占位步骤条换成真数据。

### Added

- **命令 `t2h:resume`**（三处联动齐全）：
  - `status`（默认）：读 `.lingqu/{scan,deps,port,build,hap,sign,deploy,verify}/<工程>.json`
    → 归约成 8 步状态 → 落 `.lingqu/tasks.json`（`lingqu/tasks/v1`）
  - `mark`：人工覆盖一步（agent 应用补丁后记 `done`；判定做不了记 `skipped`，断点会越过它）
  - `redo`：从某步重来（该步及之后回 `pending`，落档不动）
  - `reset`：整块回 `pending`（**不删落档**，证据不该被断点操作毁掉）
  - `session`：记 cjh 会话 id → 重开应用后页面据此 `resume_session`，**agent 会话一起续**
- `src/task.cj`（纯函数层）：`TASK_STEPS` 步骤表、`normalizeTaskStatus`、
  `reconcileStepStatus`、`firstUnfinished`、`taskProgress`、`resumeHint`、
  `markTaskStep` / `redoFromStep`、`parseTaskBoard`（容错）/ `TaskBoard.toJson`
- `src/task_feed.cj`（观测层）：`observeTaskStep` 读各步落档 → `exists / ok / 一句话摘要`，
  `collectTaskBoard` / `saveTaskBoard`（写前留 `.bak`）
- ④ 屏「断点续迁 · 8 步状态机」卡（**替换原占位步骤条**）：完成/失败/跳过/进度/下一步五个指标、
  逐步行（勾选 / 步骤名 + 落档证据 / 判定 + 「从这步重来」）、「刷新断点」按钮
- `ui_report` 新增 `resumeOk/resumeNext/resumeDone/resumeFailed/resumeSkipped/resumeTotal/`
  `resumePercent/resumeHint/resumeSession` + 版面指标 `resumeRows/resumeRowH`；
  探针 `LINGQU_RESUME_PATH`

### Changed

- 版本 0.25.0 → **0.26.0**；单测 **156 → 165**（`src/tests/task_test.cj`，9 例）

### 口径（与 `t2h:verify` 一致，别改薄）

| 情形 | 判定 | 为什么 |
|---|---|---|
| 落档不存在 | `pending`（没跑过） | "上次好像跑过"不可信，盘上没有就是没跑 |
| 落档存在但判定没过 | `failed` | **存在 ≠ 成功**（0.24.0 的 verify 也是这条口径） |
| 人工 `skipped` | 保留，断点越过它 | 跳过是人的结论，但它不是"通过"，进度里单列 |

### 证据（本机 Windows x64，2026-11-01，habit-tree）

```
启动参数：LINGQU_RESUME_PATH=E:\test\rust\habit-tree  LINGQU_UI_SCREEN=port  LINGQU_UI_PROBE=1
.lingqu/tasks.json（lingqu/tasks/v1）：
  project=habit-tree  next=port  done=5  failed=1  skipped=0  total=8  percent=62
  hint="下一步是「规则改造」——从这一步接着做（前 5 步已有落档证据）"
  sessionId=s1793421167.504.1（页面在帧里收到会话 id 后由 t2h:resume action=session 落盘）
  scan    done    单元 R=24 / D=24 / U=0 / 评分 63 / 阻塞 1 项
  deps    done    依赖 430 包 / 需 patch 9 / 不可用 10
  port    pending .lingqu/port/habit-tree/decisions.json（没有落档 → 没跑过，不猜）
  build   failed  exit=0 / 错误 0 / 前端指纹 一致 2、过期 1、缺 0｜闸未过：.so 内嵌的
                  1 个前端产物在 dist/ 里已不存在——改了前端没重编 .so
  hap     done    HAP 7249837 字节 / arm64 库条目 3 个 / rawfile 0 个死资源
  sign    pending 该工程没有签名落档（只有 lingqu-apply-demo 那份）
  deploy  done    装 成功 / 启 成功 / hilog 40 行（健康）
  verify  done    可用率 60%（通过 3/6，平台限制 1）
ui_report（④ 屏断点板）：resumeOk=true resumeNext=port resumeDone=5 resumeFailed=1
  resumeTotal=8 resumePercent=62 resumeRows=8 resumeRowH=37 resumeSession=s1793421167.504.1
  errorCount=0 tag=probe-done
  → 8 行**单行**渲染（37px/行，与 verify 清单同一套排版纪律），会话 id 与 tasks.json 一致
```

> 注意 `build=failed` 是**真实状态**：`exit=0` 且错误 0，但前端指纹闸没过（`.so` 里还留着
> `index-BbUz51cz.css`，dist 已经换成新的）——这正是 0.20.0 白屏问题的指纹形态。
> 断点因此停在更前面的 `port`（改造还没跑），而不是自欺地报"编译通过"。

### 未做（如实）

- `t2h:report` 命令面（报告文件 0.24.0 已由 `t2h:verify` 产出 `.lingqu/verify/<工程>.{md,html}`，
  缺的是"单独出报告"的命令与 ⑦ 屏导出按钮）；T5-4 release 签名两态；P7 5 样本矩阵
- `redo` 之后立刻 `status` 会用落档把状态刷回真实情况（落档还是上一轮的，摘要里写了"待重跑"）——
  设计如此，但需要在文档里说清，避免被误读成"重来没生效"

---

## [0.25.0] - 2026-11-01

**主题**：**真·单文件包**——整份应用只剩一个 `main.exe`（无 DLL、无 `assets/`、无 `vendor/`），
cjh 引擎与 WebView2Loader 变成 PE 资源随二进制走，运行期释放再用。

### Added

- **`packaging/pack-win-single-full.sh`**：把四件事一次做完（机制照抄框架
  `cj-tauri/scripts/pack-win-single.sh`，不自创）：
  ① 仓颉 std/stdx 静态链接（`--static --static-std` + stdx 的 static 树）；
  ② C 桥编成静态归档 `libcjtbridge.a`（`-DCJ_EMBED_WEBVIEW2_LOADER -DCJ_PACK_ASSETS_EMBEDDED`）；
  ③ `windres` 把随包资源打成 `pack_assets.o`（RT_RCDATA，**必须作为链接输入**直接给 ld.lld，
     塞进 `.a` 不会被取用）；
  ④ 页面与能力清单 base64 进二进制（复用 `pack-win-single.sh` 的 `packed_assets.cj` 做法）
- `packaging/pack-assets.txt`（随包清单：`cjh.exe` + 3 个运行时 DLL）、`packaging/README-full.md`
- `src/cjh_host.cj`：`extractEmbeddedCjh()`（释放到 `%LOCALAPPDATA%\lingqu\cjh`）、
  `shouldUseExtracted()`（**释放数 > 0 且 SHA256 校验通过**才用，纯函数 + 单测）、
  `installBinPath()`；`cjhBinPath()` 增加「内嵌释放」兜底分支
- `cjhStatusJson()` 在 `running` 分支回投 `binPath`：引擎已在跑时也能看出用的是哪一份二进制
  （纯函数 `knownBinPath` + 单测）——单文件产物里这直接区分「内嵌释放的那份」与「用户自己起的」

### Changed

- 版本 0.24.0 → **0.25.0**；单测 **154 → 156**（`testShouldUseExtracted` + `testKnownBinPath`）

### Fixed

- **静态链接 C 桥报 `undefined symbol: IID_IFileOpenDialog / IID_IUnknown / IID_IDropTarget`**：
  mingw 下 COM 的 IID 守卫符号在 `libuuid.a` 里，桥的文件对话框与拖放实现引用了它们。
  链接行补齐 `-lole32 -loleaut32 -luuid -lcomdlg32 -lgdi32 -loleacc -lshlwapi -lshcore`
  （与框架 `native/build_win.bat` 对齐），链接通过

### 证据（本机 Windows x64，2026-11-01，0.25.0 产物）

```
[1/6] 随包资源 4 个；WebView2Loader 162392 字节
[4/6] cjpm build success（静态全量重编，0 warning）
[5/6] 导入表：CRYPT32 KERNEL32 SHCORE SHELL32 USER32 WS2_32 comdlg32 dbghelp msvcrt ole32
      （**没有** libcjtbridge.dll / WebView2Loader.dll / libcangjie-runtime.dll / libboundscheck.dll）
      PE 资源节 .rsrc：有
[6/6] 产物：dist/lingqu-0.25.0-win-x64-full/main.exe（58,998,784 字节）+ README.md —— 目录里只有这两个文件
```

隔离验证（拷到 `C:\lingqu-full-test`，目录里**只有 main.exe**，`%LOCALAPPDATA%\lingqu` 先删空）：

```
启动后 %LOCALAPPDATA%\lingqu\cjh\ 出现 4 个文件：
  cjh.exe 13446144 / libcangjie-runtime.dll 1206272 / libcrypto-3-x64.dll 6614528 / libssl-3-x64.dll 1241600
SHA256 与 CJH_VENDOR_FILES 常量逐字一致（3dc9db6f… / 03f4d59a… / a997e132… / bbaf8a8c…）
8765 监听者路径 = C:\Users\<u>\AppData\Local\lingqu\cjh\cjh.exe ← 跑的是**释放出来的**那份
ui_report：screens=7 idCount=156 wsState=connected errorCount=0 tag=probe-done
           cjhState=running、cjhBin=C:\Users\<u>\AppData\Local\lingqu\cjh\cjh.exe（本版新增回投）
关窗 → main 与 cjh 同时退出，8765 释放（ownership 语义未被单文件化改薄）
```

### 未做（如实）

- 单文件包**只在 Windows x64 验证**；Linux/鸿蒙侧的静态桥仍是上游 TODO
- `dist/` 产物不入库（gitignore）；复现请跑 `packaging/pack-win-single-full.sh`
  （需要 `CANGJIE_STDX_ROOT` 的 static 树、`WEBVIEW2_SDK_ROOT`、llvm-mingw、`CJ_TAURI_ROOT`）
- 未做代码签名：单文件 exe 首次运行仍可能被 SmartScreen 拦（与 0.24.0 相同）

---

## [0.24.0] - 2026-10-31

**主题**：**P6 第二刀 —— `t2h:verify` 上线**：采证据 → 出清单 → 算可用率 → 导出三段式报告，
⑥ 屏「功能清单 / 可用率」接真数据（不再是占位示意）。

### Added

- **命令 `t2h:verify`**（三处联动齐全）：
  - 读落档：`.lingqu/scan`（清单规模：命令/事件/插件/前端/平台 API 条数 + 阻塞项）、
    `.lingqu/build`（退出码 + 前端指纹比对）、`.lingqu/hap`（装配闸）、`.lingqu/deploy`（装 / 启 / 日志）
  - 采真机证据：`snapshot_display` + `file recv` 落 `.lingqu/evidence/`（**以文件真的落盘为准**，
    不看 hdc 退出码）；`ls /data/log/faultlog/faultlogger/` 数崩溃记录
  - 落档 `.lingqu/verify/<工程>.{json,md,html}`（+ `.evidence.log` 记录采证过程）
- **⑥ 屏接真数据**：四张统计卡改为可用率 / 通过 / 平台限制（剔除分母）/ 未验证·失败；
  功能清单逐条渲染（判定 pill + 勾选 + 标题，证据与说明进 tooltip）；「采集证据并算可用率」按钮
- `ui_report` 新增 `verifyOk/verifyRate/verifyPass/verifyTotal/verifyLimit/verifyUnknown/verifyShots/verifyMd`
  **以及版面指标 `verifyRows/verifyOverflow/verifyRowH`**（没有视觉也能断言"没竖排、没溢出"）
- `LINGQU_VERIFY_PATH` 探针；`src/verify_feed.cj`（落档解析 + 采证）；2 例新单测（总 **154**）

### Fixed（真机实测暴露的两个）

- **`faultlog` 读不到被当成「崩溃」**：`ls` 返回 `Permission denied` 时，旧逻辑"非空行就算一条"
  把无权限误判成崩溃 → 启动项假失败（可用率 40% → 修后 60%）。现在只认像崩溃记录的行
  （`.log` / `crash` / `fault` 开头），读不到时在报告里写明"无证据"，不再编造。
  纯函数 `countCrashRecords` / `faultlogUnreadable` + 单测
- **清单行被长文本挤成竖排**：证据文本原先塞进 `.chips`（`flex:0 0 auto`），把整行压变形。
  改成单行三列（勾选 / 标题可截断 / 判定），证据与说明进 tooltip——
  版面指标实测：`verifyRowH` **134px → 45px**、`verifyOverflow` 0、`errorCount` 0

### 证据（本机 + 真机，2026-10-31）

```
t2h:verify（LINGQU_VERIFY_PATH=E:\test\rust\habit-tree，设备 3QC0124B20000048）
落档：.lingqu/verify/habit-tree.{json,md,html} + .evidence.log
stats：rate=60% pass=3/5 limit=1 unknown=2 fail=0
  清单：[pass] 应用启动无 panic，首屏渲染
        [unknown] 交叉编译通过，前端指纹一致（本轮没跑 t2h:build，如实记未验证）
        [pass] HAP 装配通过（应用 .so 已进包、无死资源）
        [pass] IPC 命令通道可用（共 7 条命令）
        [unknown] 前端资源打进 .so 并正确加载（9 个源文件）
        [limit] 平台相关 API（4 处）按平台限制登记
截图：.lingqu/evidence/habit-tree-verify.jpeg（3120×2080，173 KB）
ui_report：verifyRate=60 verifyPass=3 verifyLimit=1 verifyUnknown=2 verifyShots=1
           verifyRows=6 verifyOverflow=0 verifyRowH=45 errorCount=0
```

### 未做（如实）

T6-5 断点续迁（`.lingqu/tasks.json` + `t2h:resume`）未开工；⑦ 屏报告导出按钮仍是占位
（报告文件已生成，路径在 ⑥ 屏"证据与报告"卡里，可直接打开看）；两份 unknown 需要跑一次
「交叉编译（OHOS）」才能补齐。

---

## [0.23.0] - 2026-10-31

**主题**：**P6 第一刀 —— 验证与报告的纯函数层**（T6-1 清单推导 / T6-3 可用率 / T6-4 报告渲染）。

### Added

- **`src/verify/verify.cj`**（`lingqu.verify`）：三条口径先钉死，再谈数字
  - `buildChecklist(ChecklistInput)` —— 功能清单**推导**而非手写：命令 / 事件 / 插件 / 前端 / 平台 API
    的条数决定出哪些条目（换样本自动跟着变），部署与日志决定判定
  - `computeStats(items)` —— 可用率 = 通过 ÷ (总数 − **平台限制**)，分母为 0 按 0 处理
  - `renderMarkdown` / `renderHtml` —— 三段式报告（做了什么 / 没做什么 / 需要你做什么），
    逐项挂证据；HTML 侧对正文做转义（报告要给外人看，`<script>` 不能当标签）
  - `verdictLabel` / `CheckItem.toJson` / `VerifyStats.toJson`
- **7 例新单测**（总 **153**），钉的是口径不是文案：
  平台限制不计入分母、**未采集 ≠ 通过**（`unknown` 计入分母）、分母为 0 不除零、
  清单随扫描伸缩（没扫过就只剩 launch/build/hap 三条）、报告三段齐全、HTML 转义

### 未做（本刀的边界，下一步接着做）

- `t2h:verify` **命令**还没接线（要跑 hdc 采截图 / hilog / faultlog，并读 scan·build·hap·deploy 的落档）；
- ⑥ 屏「功能清单 / 可用率」还是占位示意；⑦ 报告的导出按钮也还没接；
- T6-5 断点续迁（`.lingqu/tasks.json` + `t2h:resume`）未开工。

---

## [0.22.0] - 2026-10-31

**主题**：**单文件包** —— 页面与能力清单**编进 exe**，包里不再有 `assets/` 目录
（照 `cj-tauri/examples/ai-chat` 的成熟机制，不自己发明）。

### Added

- `src/packed_assets.cj`（空存根）：`PACKED_UI_B64` / `PACKED_CAPS_B64` 两个常量，
  仓库里恒为空串；`packaging/pack-win-single.sh` 在构建期把它们覆盖成真实 base64。
- `src/packed_resources.cj`：
  - `decodeBase64` / `splitBytesBy`（与 ai-chat 同款实现，只服务这条链路）
  - **`LingquAssetResolver`**：内嵌优先、缺则读盘。装配期由 `wire()` 换掉骨架默认的
    `DirectoryAssetResolver`（`app.assets(...)` 是 setter，wire 又在 `loadCapabilities` 之后跑，
    所以不需要改任何派生文件）
  - `embeddedCapabilityJsons()`：单文件产物没有 `assets/capabilities` 目录，
    能力清单在 `wire()` 里用 `addCapabilityJson` 补挂（否则所有命令都会 `command not allowed`）
- `packaging/pack-win-single.sh`：生成 base64 → 静态构建 → 打包（`--no-assets`）→ 改名成
  `lingqu-<ver>-win-x64-single`；`trap EXIT` **无条件还原**存根，仓里永远只有空串
- `packaging/README-single.md`：单文件版的使用说明与"还差什么"
- 4 例新单测（总 **146**）：base64 往返（含中文多字节、换行、非法字符）、按字节切分、
  "空存根时能力清单为 0"、resolver 的读盘回退分支

### Changed

- `package-win.sh` 增加 `--no-assets`（单文件模式不拷 `assets/`、换用 `README-single.md`）；
  `build-static-win.sh` 把额外参数透传给打包脚本

### 验证（干净 PATH，从别的工作目录启动）

```
包内顶层：main.exe + 5 个 DLL + vendor/cjh + scripts + README.md + run.bat
          assets/ 不存在（页面在 exe 里）
启动：run.bat，WorkingDirectory 故意设成 C:\Windows\Temp
结果：ui_report screens=7 / idCount=146 / activeScreen=env / errorCount=0（自检跑到 probe-frames）
      cjhState=running、wsState=connected；cjh 进程路径 = 包内 vendor/cjh/win-x64/cjh.exe
```

### 未做（如实）

**还不是"一个文件"**：`vendor/cjh`（13.4 MB 的外部引擎）与 5 个 DLL 仍在旁边。
要彻底单文件，需要 ① 把 cjh 作为 PE 资源编进 exe、运行期用框架的 `extractEmbeddedAssets`
释放到 `%LOCALAPPDATA%\lingqu\runtime`；② C 桥编成静态归档（`libcjtbridge.a`），
否则 `libcjtbridge.dll` 省不掉；③ 仓颉运行时目前没有静态版，`libcangjie-runtime.dll` 也得留。
这三条都已写进 `packaging/pack-win-single.sh` 末尾的 TODO。

---

## [0.21.2] - 2026-10-31

**主题**：**修便携包「没找到可用的 cjh」** —— `cjh.exe` 本来就在包里（13.4 MB、SHA256 对得上），
缺的是**发现路径**：`cjhVendorDir()` 用的是相对当前工作目录的 `vendor/cjh/<平台>`。

### Fixed

- **引擎目录解析不再依赖 CWD**。按序解析：`LINGQU_CJH`（显式指定二进制）→ 应用数据目录的部署副本 →
  `LINGQU_HOME/vendor` → `LINGQU_CJH_HOME/vendor` → **从 CWD 逐级上溯 6 层** → 最后退回相对路径
  （开发期在仓根跑的口径不变，旧行为不被破坏）
- **`run.bat` 两处修正**：写 `LINGQU_HOME`（包根）供应用使用；`cd /d` 到包根（`assets/` 是相对读的）。
  并删掉「剥末尾反斜杠」那一行——cmd 对引号紧邻反斜杠的写法会误解码，把整段脚本拆坏
  （真实报错：`'tory' is not recognized as an internal or external command`）
- **引擎发现结果可复核**：`ui_report` 新增 `cjhState / cjhBin / cjhVendorDir / cjhHome`。
  之前只有界面文案，而**仓颉的 `eprintln` 不会进 `%LOCALAPPDATA%\cj-tauri\logs\lingqu.log`**
  （只有 C 桥日志进得去，AGENTS §4-14），所以"找到没找到、用的哪一份"必须落文件
- 2 例新单测（总 **142**）：vendor 候选顺序（LINGQU_HOME → 自定义 → 相对）、CWD 逐级上溯与尾分隔符容错

### 验证（干净 PATH + 故意从别的工作目录启动）

```
包内引擎：…\dist\lingqu-0.21.2-win-x64-static\vendor\cjh\win-x64\cjh.exe（13.4 MB）
启动：cmd /c run.bat，工作目录故意设成 C:\Windows\Temp，PATH 只留 System32
结果：跑起来的 cjh 进程实测路径 = 包内那一份；8765 处于监听
      ui_report：cjhState=running、wsState=connected、errorCount=0
```

### 上游 TODO（AGENTS §8 回馈项）

框架若暴露 `cj_bridge_exe_dir`（C 桥里已经在用 `GetModuleFileNameW`），应用就能直接按 **exe 目录**
定位 `vendor/`，彻底摆脱 CWD 与启动器变量。更彻底的做法参考 `cj-tauri/examples/ai-chat` 的**单文件打包**：
页面与能力清单 base64 编进二进制、cjh 作 PE 资源随行，运行期由 `extractEmbeddedAssets`
释放到 `%LOCALAPPDATA%\<应用名>\runtime`——那样连 `assets/` 与 `vendor/` 两个目录都不需要，
本仓下一步照此收掉即可。

---

## [0.21.1] - 2026-10-31

**主题**：**静态链接的 Windows 便携包** —— 随包 DLL 从 **98 个降到 5 个**（zip 24.7 MB → 13.9 MB）。

### Added

- **`packaging/build-static-win.sh`**：一条命令产出静态版（`main.exe` 11.7 MB，仓颉 std + stdx 全进 exe）。
  做对三件事才链得出来（都实测过，缺一个就失败）：
  1. `compile-option = "--static-std"`（`--static-libs` 已 deprecated，别用）
  2. `CANGJIE_STDX` 指向 **static 树** `<stdx>\windows_x86_64_cjnative\static\stdx`，否则 stdx 仍按 `.dll` 链
  3. mingw 链接行补 `-lcrypt32 -lbcrypt -lws2_32 -liphlpapi -luserenv -lpsapi`——
     静态版 stdx 的 x509 用到 `CertCloseStore`，缺 `-lcrypt32` 直接 `undefined symbol`
- **`packaging/package-win.sh` 重写**：不再"整目录拷 DLL"，改为**按导入闭包自动收**
  （BFS 遍历 `main.exe` 与已收 DLL 的导入表，从 `CANGJIE_HOME`/`CANGJIE_STDX`/框架 `native` 里解析；
  收完再跑一次闭包自检，缺任何 `lib*`/`stdx*` 就失败退出）。动态版 98 个、静态版 5 个，同一份脚本
- 新增 `--static` 模式与 `-static` 后缀包名（`lingqu-<ver>-win-x64-static.zip`）

### 注意（老实话）

- **只有两个 DLL 无论如何也省不掉**：`libcangjie-runtime.dll`（仓颉运行时没有静态版）、
  `libcjtbridge.dll`（cj-tauri 的 C 桥只发了 `.dll.a` 导入库）。再加按名加载的 `WebView2Loader.dll`
  与 cj-tauri 存储用的 `sqlite3.dll`，合计 5 个。
- `targets/desktop/cjpm.toml` 是 `cj-tauri sync` **派生**的（手改会被 `check` 判漂移），
  所以静态构建走的是"**临时改 → 构建 → `trap EXIT` 无条件还原**"。上游若能给
  `cj-tauri.toml` 加 `[build] compile_option/link_option` 透传，这个临时手法就能删掉
  （已记进 `packaging/build-static-win.sh` 的 TODO，按 AGENTS §8 属回馈项）。

### 验证

```
[ok] 版本 0.21.1（static）｜main.exe 12 MB｜DLL 5 个｜整包约 39 MB
zip = 13.9 MB；根目录：main.exe 11.7 + cangjie-runtime 1.2 + sqlite3 3.4 + cjtbridge 0.7
                   + libboundscheck + WebView2Loader
干净 PATH + zip 解压到临时目录 + run.bat → 窗口"灵渠迁移台 · Lingqu"
ui_report：screens=7 idCount=146 activeScreen=env errorCount=0（自检跑到 probe-frames）
```

---

## [0.21.0] - 2026-10-31

**主题**：**`t2h:deploy` 命令化 + ⑥ 真机验证屏接真数据** —— P5 的最后一块拼图。
0.17.0 手工跑通的 `hdc install -r` → `aa start` → 抓 hilog，现在是一条命令，并且**三段分开报**
（装得上 ≠ 界面出来，这是 0.20.0 白屏的教训）。

### Added

- **命令 `t2h:deploy`**（三处联动齐全）：
  - `hdc list targets -v` → `parseHdcTargets`（挡 `COM1 UART Ready` 串口噪声）→ 选设备
    （`serial` 参数 / `LINGQU_DEPLOY_SERIAL` / 第一台 USB；显式 serial 也会在列表里核对）
  - `hdc -t <serial> install -r <hap>` → `parseInstallResult`（**按文本判**，hdc 失败退出码仍是 0）
  - `hdc -t <serial> shell aa start -a <ability> -b <bundle>` → `parseStartResult`
    （ability 默认 `EntryAbility`，bundle 读 `AppScope/app.json5`）
  - `hilog -x` 抓尾部 → `hilogLooksHealthy` 判 panic / SIGABRT / JS error
  - 落档 `.lingqu/deploy/<工程>.json`（`lingqu/deploy/v1`）+ `.log`（三段 hdc 原文 + hilog 尾部）
- **判定层 `judgeDeploy`**（纯函数）：按「设备 → 安装 → 启动 → 日志」**顺序短路**，只报最靠前那段失败——
  装不上给失败码处置（9568322 → 签名），**装上了但启动失败明确写"不是签名问题"**（多半是 ability/bundle 名不对），
  启动了但日志有崩溃则指向 `faultlog`
- **2 例新单测**（总 **140**）：happy path + 四个有序失败分支
- **⑥ 屏接真数据**：路径输入 +「安装并启动」/「仅安装」按钮 + 部署卡（设备 / 安装 / 启动 / hilog / HAP 五项）
  + 原因与下一步；占位的"功能清单"卡明确标了 `占位示意`（不冒充真数据）
- `ui_report` 新增 `deployOk/deploySerial/deployDeviceCount/deployInstalled/deployStarted/deployHilogOk/deployError`
- `LINGQU_DEPLOY_PATH` 探针（置了就启动时跑一次部署体检）

### Added（打包）

- **`packaging/package-win.sh`**：产出 `dist/lingqu-<版本>-win-x64/`（可直接双击 `run.bat`）+ 同名 `.zip`
  （24.7 MB）。清单里显式列出"运行期真的需要的文件"，并带 **依赖闭包自检**：
  把 `main.exe` 与所有随包 DLL 的导入表走一遍，缺失任何 `lib*`/`stdx*` 依赖就直接失败退出——
  这类漏文件的症状是"开发机上好好的、拷给别人启动即退 0xC0000135"，在别人机器上几乎无法自查
- **踩到并修掉的两个打包缺口**（自检就是为了不再犯）：
  `libwinpthread-1.dll`（`libstdx.net.tlsFFI.dll` 显式依赖，缺了启动即退）；
  `vendor/cjh/SHA256SUMS`（少了它引擎自校验不过、压根不会被拉起）
- `packaging/README-run.md`（随包交付的使用说明）、`run.bat`（把本目录加进 PATH 再启动）、
  `.gitignore` 增 `dist/`

### 证据（真机 HAD-W32 / HarmonyOS 7.0.0.111 / API 26，2026-10-31）

```
[devices] 3QC0124B20000048 USB Connected localhost hdc   （COM1/COM2 UART 噪声已滤掉）
[install] serial=3QC0124B20000048 ok=true code=0   msg:install bundle successfully.
[start]   ok=true   start ability successfully.
[hilog]   healthy=true lines=40
verdict:  安装 + 启动成功，hilog 无崩溃痕迹（设备 3QC0124B20000048）
ui_report（activeScreen=verify）：deployOk=true deploySerial=3QC0124B20000048 deployDeviceCount=1
          deployInstalled=true deployStarted=true deployHilogOk=true
```

**便携包实测（2026-10-31）**：把 zip 解压到干净目录、把 PATH 剥到只剩 `System32`，
双击 `run.bat` → 窗口标题 `灵渠迁移台 · Lingqu`、`ui_report` 回投 `screens=7 idCount=146
activeScreen=env errorCount=0`（自检序列跑到 `probe-frames`）；包内 `cjh.exe --version` → `cjh v1.6.1`。

**未做（如实）**：⑥ 屏的「功能清单 / 可用率」仍是占位示意——那要等 P6 的 `t2h:verify`（从画像生成清单 +
逐项挂证据）；T5-4 release 签名两态仍未开工。

---

## [0.20.0] - 2026-10-31

**主题**：**修真机白屏的两个真缺陷**（T5-3/T5-5 的漏检）—— 用户报"habit-tree 在真机上跑起来但看不到界面"，
查下去发现是**装配链漏了两步**，而且 0.17.0 的"真机验证成功"结论**过宽**（装了、启动了，但界面是白的）。

### Fixed

- **`t2h:hap` 不把应用自己的 `.so` 打进 HAP**（白屏根因①）。HAP 里只有 DevEco 模板自带的
  `libentry.so`（6 KB 的 `add` 示例桩）与 `libc++_shared.so`，`libgrove_lib.so`（5.7 MB）**从未进入产物**。
  样本仓把这步写成手工 `cp target/aarch64-unknown-linux-ohos/release/libgrove_lib.so
  gen/ohos/entry/libs/arm64-v8a/`，而 `entry/hvigorfile.ts` 里的 cargo 钩子早被移除（Windows 拉不起），
  所以链路上没人做这件事 → `EntryAbility.moduleName="grove_lib"` 的 `import("libgrove_lib.so")` 失败 →
  ArkTS 页面空 Column → **白屏**。
  现在 `t2h:hap` 装配前自动：读 `EntryAbility.ets` 的 `moduleName` → 定位
  `<src-tauri>/target/aarch64-unknown-linux-ohos/release/lib<name>.so` → 拷进 `entry/libs/arm64-v8a/`
  （产物缺失时直接报"先跑交叉编译"），并在返回值/落档里带 `expectedSo` / `soCopied` / `soSource`
- **HAP 闸放过了"没有应用 .so"的包**（白屏根因②的漏检面）。旧闸只判"有没有 `libs/arm64-v8a/*.so`"，
  被模板的 `libentry.so` 骗过。`checkHapGate` 增加 `expectedSoName` + `hasExpectedSo`：
  **必须存在 `lib<moduleName>.so`**，否则失败并指向"先交叉编译"
- **`.so` 里嵌的是旧前端**：修完白屏①后仍然白屏，因为 `libgrove_lib.so` 的时间戳（22:24）
  早于 `dist/`（22:52）——`.so` 里嵌着旧的 `index-BbUz51cz.css / index-CNGJtM_T.js`，
  而 `dist/` 是 `index-CBRNBEtE.css / index-Cn-J9RFq.js`。重编 `.so`（增量 33 s）后界面出来。
  **这正是 T5-2 前端指纹闸存在的理由**（`t2h:build` 的 verify 模式会报 stale），本轮把它跑在了真机链路上

### Added

- `src/compiler/hap.cj`：`entryModuleNameOf`（从 `EntryAbility.ets` 取 `moduleName`）、
  `expectedSoNameOf`（→ `lib<name>.so`，容错 `lib`/`.so` 写法）、`hapHasSo`（在 HAP 条目里按末段比名，忽略大小写）
- **4 例新单测**（总 **138**）：闸门新参数、`moduleName` 抽取（单/双引号、无则返回空）、
  `.so` 名字推导、"只有模板 stub 必须失败"的白屏复现用例

### 证据（真机 HAD-W32 / HarmonyOS 7.0.0.111 / API 26，2026-10-31）

| 步骤 | 结果 |
|---|---|
| 修前 HAP 条目 | `libs/arm64-v8a/{libc++_shared.so, libentry.so}`（1.47 MB）——**没有 libgrove_lib.so** |
| 修前 hilog | ArkTS 起窗口后再无 NAPI/webview 日志；截图中央区 **97.8% 纯白、仅 70 色** |
| 拷 `.so` + 重装 | HAP 7.25 MB，条目含 `libs/arm64-v8a/libgrove_lib.so`；hilog 出现 `cef` / `chromium` / `gpu` 进程与 `[WebNavigation]` |
| 页面加载 | `LoadUrlWithHeaders url:tauri://loc…` → `OnPageEnd httpStatusCode:200` → `DOMContentLoaded` → `PageLoadFinished` |
| 仍白屏 | 截图 350 KB、中央区 97.8% 纯白 → 定位到 `.so` 嵌旧前端（见上） |
| 重编 `.so` 后 | 截图 173 KB、中央区 **574 色**、主色 `12,15,24`（36.6%）；ArkWeb `gpu`+2×`render` 子进程在跑，无 faultlog |

**人眼确认（2026-10-31，用户）**：修完后界面正常显示 —— 白屏问题闭环。
我这边抓屏仍与"仅桌面"截图逐点相同（11310 采样差 1）、窗口管理器里 `habit_tree0` 的 bounds 为
`[515,281]-[2605,1675]`，但 `uitest dumpLayout` 的前台是 `com.ohos.sceneboard`——
**说明"截屏 + 窗口树"不能替代人眼**（抓屏可能拍到桌面）。0.17.0 的"真机首验通过"结论按此收窄：
**链路（装/启/签名）当时成立，界面呈现不成立；0.20.0 起两者都成立**。

---

## [0.19.0] - 2026-11-01

**主题**：**签名配置自动写回**（`t2h:sign` 的 apply 模式）—— 把"体检工具"变成"省事工具"。
工程没配签名时，一条命令把 `signingConfigs` 写进 `build-profile.json5`（自动备份、幂等、写后可直装）。
另沉淀长文 **`docs/鸿蒙自动签名机制.md`**：把 DevEco / flutter / deveco-cli 那套"签名材料工厂"
拆成可复刻的步骤（这条链之前只有零散结论，没有一份能照着实现的说明书）。

### Added

- **`t2h:sign` 的 apply 模式**（`apply: true` 或 `LINGQU_SIGN_APPLY=1`）：
  1. 判定工程缺签名（已有非空 `signingConfigs` 时**跳过而不是覆盖**）
  2. 找一个**用同一套材料**的 donor 工程（比对 `storeFile` 的 p12 文件名；范围：显式 `donor` /
     `LINGQU_SIGN_DONOR`，否则扫 `~/DevEcoStudioProjects`、`~/Documents`、`~/Desktop`，限深度 4）
  3. 把它的 `signingConfigs`（含 **DevEco AesGcmKit 加密口令**——我们造不出来，只能搬）原样注入
  4. 顺手把 `products[].signingConfig` 指到它；改动前存 `.lingqu/sign/<工程>.build-profile.json5.bak`
  5. **写后立刻重新判定**并回填结果 → 界面直接显示"可直装"，不用再点一次
- **纯函数层**（`src/compiler/sign.cj`）：`SigningMaterial` / `signingMaterialOf` / `signingBlockJson5` /
  `json5EscapeOf` / `injectSigningConfigs` / `pointProductSigningConfig` / `applySigningConfig` /
  `sameMaterialFile` / `fileNameOf` —— **纯文本手术，不重排整份 json5**
- **4 例新单测**（总 **136**）：写回主路径（含"写得进去 = 读得出来"的闭环断言 + 括号配平）、
  拒绝覆盖 / 材料不全 / 结构不认识、`signingConfig` 三种指向、材料身份与转义往返
- **⑤ 屏「写回签名配置」按钮** + `ui_report` 新增 `signApplied`
- **`docs/鸿蒙自动签名机制.md`**（长文，可直接改写为博客）：三方关系图、九步全链路、AGC 端点表、
  材料命名规则（**本机实测确认** hash = `sha256(前向斜杠路径)` base64url 去 padding）、
  `material/` 口令加密格式（PBKDF2 + AES-128-GCM）、C0–C10 复用检查、"上云生成 vs 离线复用"对比、
  复刻清单，以及**每条事实的出处与核对方式**

### Fixed（都是先红后绿）

- **注入后 json5 变成 `]]`**：`injectSigningConfigs` 从原数组的 `]` 处开始接原文，而新 body 自己已带 `]`
  → 多一个闭合括号，json5 语法错误。改为从 `]` 的**下一个字符**接；并加 `bracketBalance()` 断言防复发
- **donor 比对拿 `.p7b` 去比 `.p12`**：`sameMaterialFile` 比的是文件名，材料身份是 p12 → 永远匹配不上
  （实测 `applied=false`）。改为先把候选 `.p7b` 换成同 base 的 `.p12`
- **写回后 `filesExist`/`profileType`/`allowsDevice` 仍是写回前的旧值**：先按新配置重算材料路径与
  存在性、重解析 profile，再判定（否则会出现"已写回但报材料不存在"的自相矛盾）
- 探针失效：页面显式传 `apply:false` 会盖掉 `LINGQU_SIGN_APPLY=1` → 改成两者取「或」

### 验证证据（真机 + GUI 实测，2026-11-01）

拿一份 `signingConfigs: []` 的模拟工程（`%TEMP%\lingqu-apply-demo`，包名 `com.jiujiang.habit_tree`）
跑 `LINGQU_SIGN_PATH=<它> LINGQU_SIGN_APPLY=1 LINGQU_SIGN_DONOR=E:\test\rust\habit-tree`：

```
[verdict] ok=true reason=签名配置齐全，且 profile 绑定了本机 UDID，可直装
[apply] applied=true donor=E:\test\rust\habit-tree\src-tauri\gen\ohos\build-profile.json5
        backup=.lingqu/sign/lingqu-apply-demo.build-profile.json5.bak
[signing/after-apply] name=default type=HarmonyOS
        certpath=…default_ohos_m7Gx….cer  profile=…default_ohos_m7Gx….p7b  storeFile=…default_ohos_m7Gx….p12
ui_report：signOk=true signApplied=true signHasConfig=true signFilesExist=true
           signAllowsDevice=true signType=debug
```

写回后的 `build-profile.json5` 与 0.17.0 真机装成功的那份**同结构同材料**；demo 工程缺 entry 模块，
所以本轮**没有**在它上面重跑 `hvigor assembleHap`（如实标注，未验证到"装配"这一步）。
四道闸全绿：build 0 warning / test TOTAL=136 FAILED=0 / check / build-app 0 warning。

---

## [0.18.0] - 2026-11-01

**主题**：**签名体检 `t2h:sign`** —— 把 T5-5 挖到的"能不能装"判据做成一键体检。
**离线、免账号、免 IDE**：读 `hdc shell bm get --udid` + 工程 `build-profile.json5` + `~/.ohos/config/*.p7b`，
直接回答"现在装的上去吗；装不上要动什么"。

### Added

- **`src/compiler/sign.cj`**（`lingqu.compiler` 续）：签名判定的纯函数层
  - `extractProfileJson`：从 PKCS#7 二进制里**配对扫描**取出内嵌明文 JSON（字符串/转义感知）
  - `latin1Of`：字节 → **ASCII 净化视图**（可打印 ASCII 保留、其余换空格）
  - `parseOhosProfile` → `OhosProfile{profileType,bundleName,deviceIds,parseError}` + `allows(udid)`
  - `discoverProfiles` / `pickProfile`：扫 `~/.ohos/config` 全部 `.p7b`，挑"含本机 UDID"的那份
  - `parseProjSigning` + `json5ValueAfter` + `unescapeJson5`：**JSON5** 的轻量提取
    （注释/尾逗号/单引号/无引号键都认），拿 `signingConfigs` 的 `certpath/profile/storeFile` 与
    `products[].signingConfig`；**双反斜杠必须还原**，否则 Windows 上 `exists()` 永远假
  - `parseUdid`：不猜前缀文案，取**最长连续十六进制串**（≥16 位）
  - `judgeSign(hasConfig, filesExist, allowsDevice, profileType, udid, hasCandidate)` → 结论 + 可执行下一步
- **命令 `t2h:sign`**（三处联动齐全）：取 UDID → 解析工程签名配置（相对路径会按 `gen/ohos` 兜底解析）→
  扫本机材料（**优先挑包名也对得上的**，包名读 `AppScope/app.json5`）→ 判定 →
  落档 `.lingqu/sign/<工程>.json`（`lingqu/sign/v1`）+ `.log`（hdc 原文 + 每份 profile 的 type/bundle/devices/allowsLocal）
- **12 例新单测**（总 **132**）：脱敏 fixture 的全字段解析、坏 JSON/空 JSON、配对花括号（尾部 `0x7D` 不带进来）、
  JSON5 五类写法与转义还原、`judgeSign` 五条失败分支、真实 `~/.ohos/config` 扫得到且解析不炸
- **⑤ 屏签名卡**：UDID / 工程签名配置 / 材料文件 / profile 类型 / 含本机 UDID / 本机候选材料 六项，
  下面一行直接给"原因 + 下一步"；`ui_report` 新增 `signOk/signUdid/signHasConfig/signFilesExist/signAllowsDevice/signType/signCandCount`
- **`LINGQU_SIGN_PATH` 探针**：置了就在启动时跑一次体检（秒级，适合 CI）
- **`LINGQU_UI_SCREEN`**：启动即切到指定屏（`LINGQU_UI_SCREEN=build`），给"截某屏版面证据"一个可复现入口
- `samples/evidence/ohos-profile.sample.p7b.txt`：真实 profile 的**脱敏**内嵌 JSON（结构逐字段一致，包名与 UDID 换成合成值）

### Fixed

- `.p7b` 用 `String.fromUtf8` 直接转二进制 → 高位字节被吞/报 `Unexpected character: '?'`，内嵌 JSON 破掉。
  改 ASCII 净化视图（内嵌 JSON 全是 ASCII，净化后更稳）
- "取最后一个 `}`"当 JSON 结尾 → 证书二进制里的 `0x7D` 会把尾部垃圾带进 JSON。改**配对扫描**（含字符串/转义状态机）
- `quote` 当变量名编译报 `expected identifier or pattern after 'let'`（AGENTS §4-20 老坑再现，改名 `dquote`）

### 验证证据（真机 + GUI 实测，2026-11-01）

```
[hdc shell bm get --udid] exit=0
udid of current device is : B8861DAE97…6385
[config] C:\Users\<user>\.ohos\config（找到 4 份 .p7b）
[profile] default_ohos_m7Gx…p7b type=debug bundle=com.jiujiang.habit_tree devices=26 allowsLocal=true
[signing] name=default type=HarmonyOS … filesExist=true
[verdict] ok=true reason=签名配置齐全，且 profile 绑定了本机 UDID，可直装
```

`ui_report`（`activeScreen=build`）：`signOk=true signUdid=true signHasConfig=true signFilesExist=true
signAllowsDevice=true signType=debug signCandCount=4`，`errorCount=0`。
**未做**：`t2h:deploy`（安装/启动/取日志命令化）与 ⑥ 真机验证屏仍未接线；T5-4 release 签名两态未做；
ArkWeb 上的界面渲染仍需人眼确认（我无视觉能力）。

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
