<!-- 提交 PR 前请照着勾一遍；详细规矩见 CONTRIBUTING.md 与 AGENTS.md §1 -->

## 这个 PR 做了什么

<!-- 一句话 -->

## 现象 → 根因 → 处置

- **现象**：
- **根因**：
- **处置**：

## 证据（必填，本项目"没有证据 = 没做完"）

- [ ] `./scripts/test.sh` 六项全绿，单测条数与结果：

```
（贴最后一段输出：build-biz:PASS test:PASS check:PASS js-syntax:PASS build-app:PASS build-cli:PASS）
```

- [ ] 行为变更的可观测证据（命令返回值 / 落档字段 / 日志行 / 界面 `ui_report` 字段）：

- [ ] 若是界面改动：`t2h:ui_report` 相关字段（或 `LINGQU_UI_PROBE=…` 探针输出）：

## 文档与测试

- [ ] 新增/修复有单测（**修复类：先红后绿**，贴红→绿的证据）
- [ ] `CHANGELOG.md` 已更新
- [ ] `docs/进度记录.md` 已更新（涉及验收项：`docs/需求追踪.md`；踩了新坑：`AGENTS.md` §4）
- [ ] 未验证的部分已如实标注（写清"没跑过 / 只在某平台跑过"）

## 自查

- [ ] `git status` 干净，无临时脚本、无本机绝对路径、无密钥/证书/UDID
- [ ] 没有手改 `targets/`（派生品）
- [ ] 新命令三处联动齐全（register × capabilities × UI），或在说明里写了"纯 agent 侧工具、无 UI 入口"
- [ ] 传递中文内容没有走命令行参数（见 `AGENTS.md` §4-119）
