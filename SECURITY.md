# 安全策略（SECURITY）

## 报告安全问题

**不要开公开 issue。** 请通过以下任一方式联系维护者：

- AtomGit / GitCode 仓库所有者私信（<https://atomgit.com/qq8864/lingqu>）
- 邮件：`qq8864@gmail.com`

请写清：影响版本（`cjpm.toml` 的 `version`）、复现步骤、影响面（是否泄露密钥 / 是否能写用户工程 / 是否需要本机已被攻破），
以及你希望的处理时限。我们会在确认后同步修复与公告，并征得你同意后在 `CHANGELOG.md` 里致谢。

## 本仓的敏感数据边界（提交前自查）

| 数据 | 存放位置 | 说明 |
|---|---|---|
| 模型 API Key | **`~/.cjh/auth.json`**（cjh 自己管） | 本应用**不另存**任何 Key；`t2h:cjh_settings_save` 写的是 cjh 的 `settings.json`，不含密钥 |
| AGC 访问令牌 | `~/.lingqu/agc/`（**AES-128-GCM 加密**） | 浏览器 OAuth 授权后落盘；请勿把该目录提交或用明文复制到别处 |
| 签名材料口令 | `build-profile.json5` 里 hvigor 认的密文 | 私钥 `.p12` **永不出本机**；`sign --auto` 只做本地生成与云端申请 |
| 设备 UDID / 证书 | `~/.ohos/config/*.p7b`、`.lingqu/sign/` 落档 | 落档里可能含 UDID：贴 issue 前请脱敏 |

**永远不要**：把 `~/.cjh/`、`~/.lingqu/`、`~/.ohos/`、`*.p12`、`*.p7b`、`*.cer`、`auth.json`、`.env` 提交进仓，
或贴到公开 issue / 截图里（截图前先确认顶栏与设置面板没有 Key 回显）。

## 本仓已有的安全设计（可复核）

- **随包 AI 引擎校验**：`vendor/cjh/` 的 4 个文件逐个 **SHA256**，验不过**绝不解包、绝不执行**
  （`src/cjh_host.cj` / `shouldUseExtracted`）。
- **引擎只绑回环**：自拉起的 cjh 一律 `--bind 127.0.0.1`（cjh 默认 `0.0.0.0` 且无鉴权）。
- **不抢不杀**：8765 上已有 cjh（可能是用户的）就复用，退出时只收自己拉起的那个。
- **规则改造可回滚**：`t2h:port` 的每处改动都进 `revertPairs()` 备份表，`t2h:revert` 可整体还原。
- **破坏性操作先验边界**：门禁挑进程时只结束**本仓路径下**的 `main.exe`，且对过滤值做非空守卫
  （§4-93：空值等于"全匹配"，宁可留着也不误杀）。
- **命令白名单**：前端只能调用 `assets/capabilities/default.json` 里声明的 `t2h:*`；
  `cj-tauri check` 做「已注册 ⊆ 已声明」的比对。

## 已知边界（如实说明）

- 本工具会**按规则修改用户工程文件**（`Cargo.toml` / `lib.rs` / `hvigorfile.ts` / `tauri.conf.json` 等）。
  这是它的本职，但请**先 `git commit` 或用干净副本**再跑；所有改动可回滚，备份在 `<工程>/.lingqu/port/<工程>/`。
- AI agent 拥有执行 shell 命令的能力（这是设计：它是执行者）。生产环境请在自己的隔离工作区里跑，
  并把"人工介入"当成正常的审批点，而不是障碍。
