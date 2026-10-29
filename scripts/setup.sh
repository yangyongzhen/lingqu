#!/usr/bin/env bash
# 灵渠迁移台 · 新机器初始化（跨平台）
#
# 本仓被 cj-tauri create 生成时，几处**本机绝对路径**被写死进了 cjpm.toml
# （框架依赖 path + 两处 -L<native>）。换机器/换平台后跑一次这个脚本即可，
# 不必重跑 create（那会把业务代码覆盖掉）。
#
# 用法：
#   ./scripts/setup.sh                          # 用默认的 CJ_TAURI_ROOT
#   CJ_TAURI_ROOT=/path/to/cj-tauri ./scripts/setup.sh
#
# 之后按提示跑 ./scripts/test.sh -s

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  Linux)                OS=linux ;;
  Darwin)               OS=macos ;;
  *)                    OS=unknown ;;
esac

if [ "$OS" = "windows" ]; then
  : "${CJ_TAURI_ROOT:=/e/test/harmonyos/test/cj-tauri}"
else
  : "${CJ_TAURI_ROOT:=$ROOT/../cj-tauri}"
fi

say()  { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m%s\033[0m\n' "$*"; }
die()  { printf '  \033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ -d "$CJ_TAURI_ROOT" ] || die "找不到 cj-tauri 框架仓：$CJ_TAURI_ROOT（用 CJ_TAURI_ROOT 指定）"
[ -f "$ROOT/cjpm.toml" ] || die "找不到 $ROOT/cjpm.toml"

TOML="$ROOT/cjpm.toml"
# cjpm 在 Windows 上接受正斜杠；统一成正斜杠，两端都好用
FRAMEWORK_POSIX="${CJ_TAURI_ROOT//\\//}"

say "工程      : $ROOT"
say "cj-tauri  : $FRAMEWORK_POSIX"

cp "$TOML" "$TOML.bak"

# ① 框架依赖 path
sed -i -E "s|cjTauri = \{ path = \"[^\"]*\" \}|cjTauri = { path = \"$FRAMEWORK_POSIX\" }|" "$TOML"

# ② 两处 -L<native>（测试可执行文件的链接行要用到 C 桥）
sed -i -E "s|-L[^ \"]*/native|-L$FRAMEWORK_POSIX/native|g" "$TOML"

if cmp -s "$TOML" "$TOML.bak"; then
  ok "cjpm.toml 已经是当前框架路径，无需改动"
  rm -f "$TOML.bak"
else
  ok "cjpm.toml 已更新（原文件备份为 cjpm.toml.bak）"
  printf '\n'
  printf '  改动预览：\n'
  diff -u "$TOML.bak" "$TOML" | sed -n '3,20p' | sed 's/^/    /'
  rm -f "$TOML.bak"
fi

printf '\n'
printf '下一步：\n'
printf '  1) ./scripts/test.sh -s      # 派生骨架 + 过四道闸（首次必跑）\n'
printf '  2) ./scripts/run-dev.sh -b   # 编译并起窗口（AI 引擎会自动拉起）\n'
