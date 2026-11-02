#!/usr/bin/env bash
# 灵渠迁移台 · 把运行时 DLL 收进桌面产物目录（Windows）
#
# 为什么需要它（用户实测：「为啥启动时总报少 libstdx.dll 啊」）：
#   `targets/desktop/target/release/bin/main.exe` 的导入表里有
#   `libcangjie-runtime.dll` / `libstdx.encoding.json.dll` / `libstdx.net.http.dll` /
#   `libcjtbridge.dll` / `libboundscheck.dll` …，这些**不在 exe 旁边**，只在 SDK/框架目录里。
#   所以：
#     · 用 `scripts/run-dev.bat`（会配好 PATH）→ 能起；
#     · **直接双击 main.exe / 快捷方式 / 从别的目录 start** → Windows 找不到 → 启动即退
#       （`0xC0000135 / -1073741515`，症状就是弹"缺少 libstdx.*.dll"）。
#   Windows 的 DLL 搜索顺序里，**exe 所在目录排第一**：把闭包拷到它旁边，双击就能跑，
#   不必依赖谁去配 PATH。与 `packaging/package-win.sh` 同一条纪律（§4-51：按导入闭包自动收，
#   收完再自检一遍），区别只是落点不同（这里是开发产物目录，那里是 dist/ 便携包）。
#
# 用法：
#   ./scripts/collect-runtime-dlls.sh          # 收进 targets/desktop/target/release/bin/
#   ./scripts/collect-runtime-dlls.sh --clean  # 先清掉之前收进去的（排查"拷了旧的"时用）
#
# 环境变量（与其它脚本同口径，都有该平台默认值）：CANGJIE_HOME / CANGJIE_STDX / CJ_TAURI_ROOT
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[x] 未知参数：$arg（可用 --clean / -h）" >&2; exit 2 ;;
    esac
done

OS="$(uname -s)"
case "$OS" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) echo "[i] 非 Windows（$OS）：这一步只对 Windows 有意义，跳过"; exit 0 ;;
esac

: "${CANGJIE_HOME:=/d/Program Files (x86)/Cangjie}"
: "${CANGJIE_STDX:=/d/cangjie-stdx/windows_x86_64_cjnative/dynamic/stdx}"
: "${CJ_TAURI_ROOT:=/e/test/harmonyos/test/cj-tauri}"

to_posix() {
    case "$1" in
        [A-Za-z]:[\\/]*)
            if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else
                local d r; d="$(printf '%s' "${1:0:1}" | tr 'A-Z' 'a-z')"; r="${1:2}"; r="${r//\\//}"; printf '/%s%s\n' "$d" "$r"
            fi ;;
        *) printf '%s\n' "$1" ;;
    esac
}
CANGJIE_HOME="$(to_posix "$CANGJIE_HOME")"
CANGJIE_STDX="$(to_posix "$CANGJIE_STDX")"
CJ_TAURI_ROOT="$(to_posix "$CJ_TAURI_ROOT")"

BIN_DIR="targets/desktop/target/release/bin"
EXE="$BIN_DIR/main.exe"
[ -f "$EXE" ] || { echo "[x] 找不到 $EXE —— 先跑 scripts/test.sh -s（或 scripts/run-dev.sh -b）编出桌面产物" >&2; exit 1; }

OBJDUMP="$CANGJIE_HOME/third_party/llvm/bin/llvm-objdump.exe"
[ -f "$OBJDUMP" ] || { echo "[x] 找不到 llvm-objdump：$OBJDUMP（收不了依赖清单，宁可失败也不瞎拷）" >&2; exit 1; }

if [ "$CLEAN" = "1" ]; then
    # 只清"我们自己收进来的"（都是 lib*/stdx*/WebView2Loader/sqlite3），不碰 main.exe 与 .cjo
    find "$BIN_DIR" -maxdepth 1 -type f \( -name 'lib*.dll' -o -name 'stdx*.dll' -o -name 'WebView2Loader.dll' -o -name 'sqlite3.dll' \) -delete 2>/dev/null || true
    echo "[clean] 已清掉 $BIN_DIR 里的运行时 DLL"
fi

SEARCH=(
    "$CANGJIE_HOME/runtime/lib/windows_x86_64_cjnative"
    "$CANGJIE_HOME/lib/windows_x86_64_cjnative"
    "$CANGJIE_HOME/tools/bin"
    "$CANGJIE_HOME/bin"
    "$CANGJIE_HOME/third_party/mingw/lib"
    "$CANGJIE_STDX"
    "$CJ_TAURI_ROOT/native"
    "$CJ_TAURI_ROOT/native/webview2"
)

# 按名加载、不在导入表里的两件（§4-2：缺了只在运行期炸）
[ -f "$CJ_TAURI_ROOT/native/webview2/WebView2Loader.dll" ] && cp -f "$CJ_TAURI_ROOT/native/webview2/WebView2Loader.dll" "$BIN_DIR/" 2>/dev/null
[ -f "$CJ_TAURI_ROOT/native/sqlite3.dll" ] && cp -f "$CJ_TAURI_ROOT/native/sqlite3.dll" "$BIN_DIR/" 2>/dev/null

# OpenSSL 两件（0.39.65，用户实测"浏览器能开 8765、应用却说未连接"）：
# 仓颉运行时的 TLS 加载器**按裸名**找 `libcrypto-3-x64.dll` / `libssl-3-x64.dll`，
# 而 SDK 与 stdx 都不带它们 —— 开发机上恰好命中 PATH 里别人带的那份，换个启动方式就挂，
# 症状是 http 照常 200、**只有 ws 握手失败**（`Can not load openssl library or function RAND_bytes`）。
# 我们随包的 cjh（vendor/cjh/win-x64）里正好带着同版本 OpenSSL 3，直接收过来即可。
for pair in "libcrypto-3-x64.dll" "libssl-3-x64.dll"; do
    [ -f "$BIN_DIR/$pair" ] && continue
    for d in "$CJ_TAURI_ROOT/native" "$CJ_TAURI_ROOT/native/webview2" "$ROOT/vendor/cjh/win-x64" \
             "$CANGJIE_STDX" "$CANGJIE_HOME/runtime/lib/windows_x86_64_cjnative"; do
        if [ -f "$d/$pair" ]; then cp -f "$d/$pair" "$BIN_DIR/"; break; fi
    done
done

pending=("$EXE")
declare -A seen=()
round=0
copied=0
while [ ${#pending[@]} -gt 0 ]; do
    round=$((round + 1))
    next=()
    for f in "${pending[@]}"; do
        [ -n "${seen[$f]:-}" ] && continue
        seen[$f]=1
        while read -r dep; do
            [ -z "$dep" ] && continue
            # 只关心我们的库；系统 DLL（KERNEL32/USER32/msvcrt…）不拷，拷了反而出错
            case "$dep" in lib*|stdx*) ;; *) continue ;; esac
            if [ -f "$BIN_DIR/$dep" ]; then
                next+=("$BIN_DIR/$dep")
                continue
            fi
            found=""
            for d in "${SEARCH[@]}"; do
                if [ -f "$d/$dep" ]; then found="$d/$dep"; break; fi
            done
            if [ -n "$found" ]; then
                cp -f "$found" "$BIN_DIR/"
                copied=$((copied + 1))
                next+=("$BIN_DIR/$dep")
            else
                echo "[x] 依赖 $dep 在 SDK/框架目录里都找不到（需要它的可能是 $(basename "$f")）" >&2
                exit 3
            fi
        done < <("$OBJDUMP" -p "$f" 2>/dev/null | sed -n 's/.*DLL Name: *//p' | tr -d '\r' | sort -u)
    done
    if [ ${#next[@]} -eq 0 ]; then break; fi
    pending=("${next[@]}")
done

# 收完自检一遍闭包：任何 lib*/stdx* 依赖在目录里找不到就失败（"拷了但漏一个"最坑）
MISSING="$(
    for f in "$BIN_DIR"/*.dll "$EXE"; do
        [ -f "$f" ] || continue
        "$OBJDUMP" -p "$f" 2>/dev/null | sed -n 's/.*DLL Name: *//p'
    done | tr -d '\r' | sort -u \
         | grep -Ei '^(lib|stdx)' \
         | while read -r dep; do [ -f "$BIN_DIR/$dep" ] || echo "$dep"; done | sort -u
)"
if [ -n "$MISSING" ]; then
    echo "[x] 依赖闭包不完整，还缺：" >&2
    echo "$MISSING" | sed 's/^/      /' >&2
    exit 2
fi

TOTAL=$(ls "$BIN_DIR"/*.dll 2>/dev/null | wc -l | tr -d ' ')
echo "[ok] 运行时已就位：$BIN_DIR（本轮新拷 ${copied} 个，现有 ${TOTAL} 个 DLL；闭包自检通过）"
echo "     现在直接双击 $BIN_DIR/main.exe 也能起（不再依赖 PATH）"
