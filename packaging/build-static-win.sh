#!/usr/bin/env bash
# ============================================================================
# 构建 **静态链接** 的桌面版（仓颉 std 与 stdx 全部进 exe），并打出便携包
#
#   ./packaging/build-static-win.sh
#
# 为什么不能直接改 targets/desktop/cjpm.toml 了事：
#   targets/ 是 `cj-tauri sync` 派生的，手改会被 `cj-tauri check` 判漂移。
#   所以这里 **临时改 → 构建 → 无论成败都还原**（trap EXIT），派生文件始终保持同步状态。
#   上游若能给 cj-tauri.toml 加一个 `[build] compile-option / link-option` 的入口，
#   这个脚本就可以删掉（见下）。
#
# 需要的三件事（都已实测，缺一个就链不出来）：
#   1. `--static-std`：std 以 libcangjie-std-*.a 形式入链
#      （`--static-libs` 已 deprecated，不再用）
#   2. `CANGJIE_STDX` 指向 **static 树**（...\windows_x86_64_cjnative\static\stdx），
#      否则 stdx 仍按 .dll 链
#   3. mingw 链接行补 Windows 系统库：static 版 stdx 的 x509 会用到 wincrypt
#      （`CertCloseStore`），缺 `-lcrypt32` 直接 undefined symbol
#
# 效果：exe 从 5.4 MB → 11.7 MB，但随包 DLL 从 98 个 → **4 个**
#   （libcangjie-runtime / libboundscheck / libcjtbridge / WebView2Loader）
#   —— 后两个只能是 DLL：仓颉运行时没有静态版，cj-tauri 的 C 桥只发了 .dll.a
#
# 上游 TODO（AGENTS §8 回馈纪律）：给 cj-tauri.toml 增加
#   `[build] compile_option / link_option` 透传；当前 manifest.cj 把 compile-option 写成空串。
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Git Bash 里直接调 cjpm 需要把仓颉工具链放进 PATH（路径要转 posix，
# 否则 MSYS 找不到 —— 与本仓 scripts/*.sh 同一套做法，见 AGENTS §4-16）
to_posix() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi; }
: "${CANGJIE_HOME:?需要 CANGJIE_HOME}"
export PATH="$(to_posix "$CANGJIE_HOME/runtime/lib/windows_x86_64_cjnative"):$(to_posix "$CANGJIE_HOME/bin"):$(to_posix "$CANGJIE_HOME/tools/bin"):$(to_posix "$CANGJIE_HOME/tools/lib"):$PATH"
CJPM="$(to_posix "$CANGJIE_HOME/tools/bin/cjpm.exe")"

TOML="targets/desktop/cjpm.toml"
[ -f "$TOML" ] || { echo "[x] 没有 $TOML —— 先跑一次 cj-tauri sync（或 scripts/test.sh）" >&2; exit 1; }

STDX_STATIC="$(dirname "${CANGJIE_STDX:?需要 CANGJIE_STDX}")/../static/stdx"
[ -d "$STDX_STATIC" ] || {
    echo "[x] 找不到静态 stdx 树：$STDX_STATIC" >&2
    echo "    仓颉 stdx 发行包里应同时有 dynamic/ 与 static/ 两个目录" >&2
    exit 1
}

BAK="$(mktemp -t desktop-cjpm.XXXXXX)"
cp "$TOML" "$BAK"
restore() {
    cp "$BAK" "$TOML"
    rm -f "$BAK"
    echo "[i] 已还原 $TOML（派生文件保持 sync 状态）"
}
trap restore EXIT

echo "[1/4] 临时打开静态链接选项"
# compile-option：把 std 静态连进来
sed -i 's|^\(  compile-option = \)""$|\1"--static-std"|' "$TOML"
# mingw 链接行：补 Windows 系统库（只在静态 stdx 下才需要）
sed -i 's|^\(  link-option = ".*-lcjtbridge\) --subsystem=windows"$|\1 -lcrypt32 -lbcrypt -lws2_32 -liphlpapi -luserenv -lpsapi --subsystem=windows"|' "$TOML"
grep -q -- '--static-std' "$TOML" || { echo "[x] 没能改上 compile-option（toml 结构变了？）" >&2; exit 1; }
grep -q -- '-lcrypt32' "$TOML" || { echo "[x] 没能改上 link-option（toml 结构变了？）" >&2; exit 1; }

echo "[2/4] 重建桌面产物（静态，全量重编；几分钟）"
export CANGJIE_STDX="$STDX_STATIC"
rm -rf targets/desktop/target
( cd targets/desktop && "$CJPM" build )

echo "[3/4] 校验 exe 真的静态化了"
OBJDUMP="${CANGJIE_HOME:?需要 CANGJIE_HOME}/third_party/llvm/bin/llvm-objdump.exe"
EXE="targets/desktop/target/release/bin/main.exe"
DYN_LIBS="$("$OBJDUMP" -p "$EXE" | sed -n 's/.*DLL Name: *//p' | tr -d '\r' \
            | grep -Ei '^(lib|stdx)' | sort -u | tr '\n' ' ')"
COUNT=$(echo "$DYN_LIBS" | wc -w | tr -d ' ')
echo "      仍动态链接的 lib: $DYN_LIBS"
if [ "$COUNT" -gt 4 ]; then
    echo "[x] 期望只剩运行时/桥接 4 个 DLL，实际 $COUNT 个 —— 静态链接没完全生效" >&2
    exit 4
fi

echo "[4/4] 打包（--static）"
CANGJIE_STDX="$(dirname "$STDX_STATIC")/../dynamic/stdx" ./packaging/package-win.sh --static
