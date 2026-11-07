#!/usr/bin/env bash
# 灵渠迁移台 · 开发启动脚本（跨平台：Windows / Linux / macOS）
#
# 做三件事：
#   ① 配好运行时环境（PATH / 动态库），缺一条都起不来——全是实测报错换来的；
#   ② **把工作目录切到工程根**（launcher 用相对路径读 assets/ui 与 assets/capabilities，
#      目录不对会报「资产未找到：ui/index.html」且能力清单加载 0 份）；
#   ③ 启动产物。AI 引擎（cjh）由应用自己托管——启动即自动拉起，不需要这里去管。
#
# 用法：
#   ./scripts/run-dev.sh            # 跑已构建产物
#   ./scripts/run-dev.sh -b         # 先 cjpm build
#   ./scripts/run-dev.sh -s -b      # 先 sync 再 build 再跑（改了 cj-tauri.toml 之后）
#
# 环境变量：CANGJIE_HOME / CANGJIE_STDX / CJ_TAURI_ROOT（都有按平台的默认值）

set -uo pipefail

BUILD=0
SYNC=0
for arg in "$@"; do
  case "$arg" in
    -b|--build) BUILD=1 ;;
    -s|--sync)  SYNC=1 ;;
    -h|--help)  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[x] 未知参数：$arg（可用 -b / -s / -h）" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  Linux)                OS=linux ;;
  Darwin)               OS=macos ;;
  *)                    OS=unknown ;;
esac

# Windows 形式的路径（D:\x\y）在 MSYS 的 PATH 里无效 —— 机器上若已导出
# CANGJIE_HOME=D:\...，直接塞进 PATH 会让所有命令 exit 127。统一转成 /d/x/y。
to_posix() {
  case "$1" in
    [A-Za-z]:[\\/]*)
      if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$1"
      else
        local drive rest
        drive="$(printf '%s' "${1:0:1}" | tr 'A-Z' 'a-z')"
        rest="${1:2}"
        rest="${rest//\\//}"
        printf '/%s%s\n' "$drive" "$rest"
      fi
      ;;
    *) printf '%s\n' "$1" ;;
  esac
}

if [ "$OS" = "windows" ]; then
  : "${CANGJIE_HOME:=/d/Program Files (x86)/Cangjie}"
  : "${CANGJIE_STDX:=/d/cangjie-stdx/windows_x86_64_cjnative/dynamic/stdx}"
  : "${CJ_TAURI_ROOT:=/e/test/harmonyos/test/cj-tauri}"
else
  : "${CANGJIE_HOME:=/opt/cangjie/cangjie}"
  : "${CANGJIE_STDX:=/opt/cangjie-stdx/linux_x86_64_cjnative/dynamic/stdx}"
  : "${CJ_TAURI_ROOT:=$ROOT/../cj-tauri}"
fi

CANGJIE_HOME="$(to_posix "$CANGJIE_HOME")"
CANGJIE_STDX="$(to_posix "$CANGJIE_STDX")"
CJ_TAURI_ROOT="$(to_posix "$CJ_TAURI_ROOT")"
export CANGJIE_HOME CANGJIE_STDX CJ_TAURI_ROOT

if [ "$OS" = "windows" ]; then
  RUNTIME_LIB="$CANGJIE_HOME/runtime/lib/windows_x86_64_cjnative"
  EXTRA="$CJ_TAURI_ROOT/native:$CJ_TAURI_ROOT/native/webview2"
else
  RUNTIME_LIB="$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative"
  EXTRA="$CJ_TAURI_ROOT/native"
  export LD_LIBRARY_PATH="$RUNTIME_LIB:$CANGJIE_STDX:$CJ_TAURI_ROOT/native:${LD_LIBRARY_PATH:-}"
fi
export PATH="$RUNTIME_LIB:$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$CANGJIE_HOME/tools/lib:$CANGJIE_STDX:$EXTRA:$PATH"

if [ "$OS" = "windows" ]; then
  BIN="$ROOT/targets/desktop/target/release/bin/main.exe"
else
  BIN="$ROOT/targets/desktop/target/release/bin/main"
fi

say()  { printf '\033[36m%s\033[0m\n' "$*"; }
good() { printf '  \033[32m%s\033[0m\n' "$*"; }
bad()  { printf '  \033[31m%s\033[0m\n' "$*" >&2; }

[ -d "$CANGJIE_HOME" ] || { bad "缺仓颉 SDK：$CANGJIE_HOME"; exit 1; }
[ -d "$CJ_TAURI_ROOT/native" ] || { bad "缺 cj-tauri 框架：$CJ_TAURI_ROOT（设 CJ_TAURI_ROOT）"; exit 1; }

CLI="$CJ_TAURI_ROOT/cli/target/release/bin/main.exe"
[ "$OS" = "linux" ] && CLI="$CJ_TAURI_ROOT/cli/target/release/bin/main"

if [ "$SYNC" = "1" ]; then
  say "[sync] cj-tauri sync"
  ( cd "$ROOT" && "$CLI" sync ) || { bad "sync 失败"; exit 1; }
  good "done"
fi

if [ "$BUILD" = "1" ]; then
  say "[build] cjpm build（targets/desktop）"
  ( cd "$ROOT/targets/desktop" && cjpm build ) || { bad "构建失败"; exit 1; }
  good "done"
fi

[ -f "$BIN" ] || { bad "找不到产物 $BIN —— 先跑 ./scripts/run-dev.sh -b"; exit 1; }

# 把运行时 DLL 收进产物目录（用户实测："为啥启动时总报少 libstdx.dll 啊"）：
# 本脚本自己配了 PATH 所以能起，但**双击 main.exe / 快捷方式**不会带我们的 PATH ——
# 那些 libstdx.*.dll / libcjtbridge.dll 不在 exe 旁边就找不到，启动即退（0xC0000135）。
# 拷一份到 exe 隔壁（Windows 搜索顺序里 exe 目录排第一），双击也就稳了。
if [ "$OS" = "windows" ] && [ -x "$ROOT/scripts/collect-runtime-dlls.sh" -o -f "$ROOT/scripts/collect-runtime-dlls.sh" ]; then
  say "[dll] 收运行时 DLL 到产物目录（幂等：缺则拷、内容不同则刷新）"
  ( "$ROOT/scripts/collect-runtime-dlls.sh" ) || warn "收 DLL 失败——用本脚本仍能起（PATH 已配），但别指望双击 main.exe"
  good "done"
fi

say "[run] $BIN"
printf '      cwd: %s\n' "$ROOT"
( cd "$ROOT" && "$BIN" )
say "      退出码：$?"
