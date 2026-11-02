# 上游回馈：cj-tauri（可直接提 issue 的稿子）

> 背景：本项目（灵渠迁移台）从 0.13.1 起把 `cjpm.toml` 里的框架依赖路径全部改成
> **环境变量占位符**（`${CJ_TAURI_ROOT}`，仓里不再含任何人的本机路径），撞到 CLI 定位层
> 的一个缺口。每条带**现象 / 根因（文件:行）/ 建议**，可直接粘成 issue。
> 版本基准：`cj-tauri` main @ `7dfea72`（Linux x64，cjc 1.2.0 实测，2026-11-02）。
>
> **状态（2026-11-02）**：第 1 条已提 issue（**cj-tauri#7**）并各推修复分支：

| 条 | 内容 | 状态 |
|---|---|---|
| 1 | `sync` 不展开依赖路径里的 `${CJ_TAURI_ROOT}` 占位符（cjpm 能展开，sync 不能） | issue #7 已提；修复分支 `fix/sync-expand-env-placeholder`（本文档写作时验证：lingqu `test.sh -s` 的 sync 步骤从 FAIL → PASS，六项全绿） |

提 PR：https://atomgit.com/qq8864/cj-tauri/pull/new/fix/sync-expand-env-placeholder （关联 issue #7）

---

## 第 1 条：sync 不展开 `${CJ_TAURI_ROOT}` 占位符（cjpm 能展开，sync 不能）

### 现象

`cjpm.toml` 依赖声明改为环境变量占位符（lingqu 0.13.1+）：

```toml
[dependencies]
cjTauri = { path = "${CJ_TAURI_ROOT}" }
```

- `cjpm build` / `cjpm test`：**正常**——cjpm 对 dependencies.path 与 target.*.link-option
  两处都会展开（2026-10-30 实测）；
- `cj-tauri sync`（不带参数）：**失败**——CLI 从 cjpm.toml 读框架根时拿到**字面量**：

```
[cj-tauri] 框架路径取自业务包声明：/path/to/proj/${CJ_TAURI_ROOT}
[cj-tauri] 未找到 ohos 骨架模板：/path/to/proj/${CJ_TAURI_ROOT}/cli/templates/ohos-skeleton（框架根定位有误？）
```

导致 `test.sh -s`（先 sync 再跑）的门禁在换机 / 新环境首跑必挂——**依赖路径本身是合法的**
（cjpm 能用），只是 sync 的框架定位层不认，而且报错把字面量当成了"业务包声明"继续往下走。

### 根因（文件:行）

- `cli/src/sync.cj` `readBizFrameworkPath()`（约 L388）：按行提取 `cjTauri = { path = ... }`
  的 path 后直接 `absolutizeBizPath(p)`；
- `absolutizeBizPath()`（约 L470）：只处理两种情况——`/` 开头视为绝对路径原样返回，否则拼
  CWD。**没有对 `${VAR}` 形式做环境变量展开**，也没有在结果不存在时回退
  `resolveFrameworkRoot()`（`CJ_TAURI_ROOT` / 仓内定位）——字面量被当成"合法声明"继续用。

### 建议修法（本分支的实现，两步）

1. **`${VAR}` 展开**：新增 `expandVarPlaceholders()`——逐字节找 `${` … `}`，取变量名用
   `std.env.getVariable()` 展开为环境变量值；**未定义的变量保留原样**（好诊断——报错里能
   看到是谁没设）；
2. **存在性校验 + 回退**：`bizFrameworkPathOf()`——展开并绝对化后**路径不存在就回退**
   `resolveFrameworkRoot()`（CJ_TAURI_ROOT / 仓内定位），与"读不到声明回 None"的旧行为一致——
   字面量不是合法声明，别拿它继续走。

### 陷阱记录（实现时踩的，两个都是仓颉 1.2.0 解析器的已知脾性）

- 字符串字面量里**不能写 `"${"`**——`${` 是插值起始符，没有配对 `}` 直接报
  `unterminated single-line string`。要拼原样文本就分开写：`"$" + "{" + varName + "}"`；
- 嵌套 match 的 **case 块里放多条语句**（`out += ...` ×4）报
  `expected '=>' in lambda expression`——复杂逻辑抽顶层辅助函数（case 块里只放 return），
  与 `resolve.cj` `jsonStrOf` 同款口径。

### 验证（修复分支实测）

```
lingqu @ 0.39.57（cjpm.toml 使用 ${CJ_TAURI_ROOT}）：
  修复前：scripts/test.sh -s → [0/5] sync FAIL（框架路径取自业务包声明：…/${CJ_TAURI_ROOT}）
  修复后：scripts/test.sh -s → [0/5] sync PASS（不带任何参数，纯靠环境变量），六项全绿
未定义变量：${NOT_DEFINED_VAR} 保留原样（不会悄悄展开成空串，报错可诊断）
```

### 临时绕过（修复合入前）

```bash
cj-tauri sync --framework "$CJ_TAURI_ROOT"
```
