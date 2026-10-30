#!/usr/bin/env bash
# 灵渠迁移台 · 新机器初始化检查（跨平台）
#
# 历史（0.13.0 及以前）：本仓由 cj-tauri create 生成时，几处**本机绝对路径**被写死进
# cjpm.toml（框架依赖 path + 两处 -L<native>），于是 setup.sh 只能用 sed 把当前机器的
# 路径盖进去。副作用很严重：cjpm.toml 是被跟踪文件，谁跑过 setup.sh 谁的本机路径就会
# 进 commit——2026-10-30 的仓里就躺着 /root/test/cj/cj-tauri，别的机器一律构建失败。
#
# 现在（0.13.1）：cjpm.toml 全部改成 ${CJ_TAURI_ROOT} 环境变量（cjpm 对
# dependencies.path 与 target.*.link-option 两处都展开，已实测）。仓里不再存任何人的
# 本机路径，本脚本因此不再改文件，只做**环境体检**：解析路径 → 校验目录 → 报告问题。
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
  : "${CANGJIE_HOME:=/d/Program Files (x86)/Cangjie}"
  : "${CANGJIE_STDX:=/d/cangjie-stdx/windows_x86_64_cjnative/dynamic/stdx}"
  : "${CJ_TAURI_ROOT:=/e/test/harmonyos/test/cj-tauri}"
else
  : "${CANGJIE_HOME:=/opt/cangjie/cangjie}"
  : "${CANGJIE_STDX:=/opt/cangjie-stdx/linux_x86_64_cjnative/dynamic/stdx}"
  : "${CJ_TAURI_ROOT:=$ROOT/../cj-tauri}"
fi

say()  { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m%s\033[0m\n' "$*"; }
warn() { printf '  \033[33m%s\033[0m\n' "$*"; }
die()  { printf '  \033[31m%s\033[0m\n' "$*" >&2; exit 1; }

say "=== 灵渠环境体检（$OS）==="
printf '  CANGJIE_HOME    : %s\n' "$CANGJIE_HOME"
printf '  CANGJIE_STDX    : %s\n' "$CANGJIE_STDX"
printf '  CJ_TAURI_ROOT   : %s\n' "$CJ_TAURI_ROOT"

[ -d "$CANGJIE_HOME" ]      || die "找不到仓颉 SDK：$CANGJIE_HOME（用 CANGJIE_HOME 指定）"
[ -d "$CANGJIE_STDX" ]      || die "找不到 stdx：$CANGJIE_STDX（用 CANGJIE_STDX 指定）"
[ -d "$CJ_TAURI_ROOT" ]     || die "找不到 cj-tauri 框架仓：$CJ_TAURI_ROOT（用 CJ_TAURI_ROOT 指定）"
[ -d "$CJ_TAURI_ROOT/native" ] || die "找不到框架 native 目录：$CJ_TAURI_ROOT/native"
[ -f "$ROOT/cjpm.toml" ]    || die "找不到 $ROOT/cjpm.toml"

CLI="$CJ_TAURI_ROOT/cli/target/release/bin/main.exe"
[ "$OS" = "linux" ] && CLI="$CJ_TAURI_ROOT/cli/target/release/bin/main"
if [ -f "$CLI" ]; then
  ok "cj-tauri CLI 就绪"
else
  warn "[!] 还没编 cj-tauri CLI：$CLI（首次在框架仓里编一次：cd $CJ_TAURI_ROOT && ./scripts/test.sh 或按其 README 编 cli）"
fi

# cjpm.toml 必须不含本机绝对路径——这是 0.13.1 的硬要求（否则换机器必挂）
if grep -nE "(path *= *\"[/A-Za-z]:|path *= *\"/(root|home|Users|opt|e|d)/|-L/(root|home|Users|opt)/)" "$ROOT/cjpm.toml" >/dev/null 2>&1; then
  warn "[!] cjpm.toml 里仍有本机绝对路径（应为 \${CJ_TAURI_ROOT}）："
  grep -nE "(path *= *\"[/A-Za-z]:|path *= *\"/(root|home|Users|opt|e|d)/|-L/(root|home|Users|opt)/)" "$ROOT/cjpm.toml" | sed 's/^/      /'
  warn "    这类路径一旦提交，别的机器就构建不了——请改回 \${CJ_TAURI_ROOT}"
else
  ok "cjpm.toml 无本机绝对路径（用 \${CJ_TAURI_ROOT} 展开）"
fi

printf '\n'
ok "环境体检通过"
printf '\n下一步：\n'
printf '  export CJ_TAURI_ROOT=%s   # 换机器时提交前记得不要让它进 cjpm.toml\n' "$CJ_TAURI_ROOT"
printf '  1) ./scripts/test.sh -s      # 派生骨架 + 过四道闸（首次必跑）\n'
printf '  2) ./scripts/run-dev.sh -b   # 编译并起窗口（AI 引擎会自动拉起）\n'
