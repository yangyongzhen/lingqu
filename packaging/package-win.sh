#!/usr/bin/env bash
# ============================================================================
# 打包 Windows 便携版（开发/交付辅助，不进四道闸）
#
#   ./packaging/package-win.sh            # 动态链接版（默认，构建快）
#   ./packaging/package-win.sh --static   # 静态链接版（先重建 exe，见 build-static-win.sh）
#
# 依赖三个环境变量（与本仓其它脚本同口径，不写死任何人的本机绝对路径）：
#   CANGJIE_HOME     仓颉 SDK 根
#   CANGJIE_STDX     桌面版 stdx 目录（*.dll 在这里）
#   CJ_TAURI_ROOT    cj-tauri 框架目录（native/libcjtbridge.dll 在这里）
#
# 产物：dist/lingqu-<版本>-win-x64/（目录，可直接双击 run.bat）+ 同名 .zip
#
# 两条硬纪律（都是踩出来的，见 AGENTS §4-1/§4-2/§4-27/§4-49）：
#   ① **DLL 清单按导入闭包自动收**，不靠"拷一整个目录"：动态版 98 个、静态版 4 个，
#      写死清单总会漏（漏一个的症状是"开发机上好好的、拷给别人启动即退 0xC0000135"）
#   ② 收完必须**自检闭包**：任何 lib*/stdx* 依赖在包里找不到就失败退出
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="dynamic"
[ "${1:-}" = "--static" ] && MODE="static"

if [ -z "${CANGJIE_HOME:-}" ] || [ -z "${CANGJIE_STDX:-}" ] || [ -z "${CJ_TAURI_ROOT:-}" ]; then
    cat >&2 <<'EOF'
[x] 需要三个环境变量：
      export CANGJIE_HOME=<仓颉 SDK 根>
      export CANGJIE_STDX=<...stdx\windows_x86_64_cjnative\dynamic\stdx>
      export CJ_TAURI_ROOT=<cj-tauri 目录>
EOF
    exit 1
fi

VER="$(sed -n 's/^ *version *= *"\([^"]*\)".*/\1/p' cjpm.toml | head -1)"
[ -n "$VER" ] || { echo "[x] 读不到 cjpm.toml 的 version" >&2; exit 1; }

EXE="targets/desktop/target/release/bin/main.exe"
[ -f "$EXE" ] || { echo "[x] 找不到 $EXE —— 先跑 scripts/test.sh -s（第四道闸会编桌面产物）" >&2; exit 1; }

OBJDUMP="${CANGJIE_HOME}/third_party/llvm/bin/llvm-objdump.exe"
[ -f "$OBJDUMP" ] || { echo "[x] 找不到 llvm-objdump：$OBJDUMP（收不了 DLL 清单，宁可失败也不瞎拷）" >&2; exit 1; }

SUFFIX=""
[ "$MODE" = "static" ] && SUFFIX="-static"
NAME="lingqu-$VER-win-x64$SUFFIX"
OUT="dist/$NAME"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "[1/5] 主程序与资产（$MODE）"
cp "$EXE" "$OUT/main.exe"
cp -r assets "$OUT/assets"
cp packaging/run.bat "$OUT/run.bat"
cp packaging/README-run.md "$OUT/README.md"

# DLL 搜索目录：谁的依赖就从谁的 SDK/框架目录里找
SEARCH=(
    "$CANGJIE_HOME/runtime/lib/windows_x86_64_cjnative"
    "$CANGJIE_HOME/lib/windows_x86_64_cjnative"
    "$CANGJIE_HOME/tools/bin"          # libwinpthread-1.dll 等 mingw 运行时在这儿
    "$CANGJIE_HOME/bin"
    "$CANGJIE_HOME/third_party/mingw/lib"
    "$CANGJIE_STDX"
    "$CJ_TAURI_ROOT/native"
    "$CJ_TAURI_ROOT/native/webview2"
)

echo "[2/5] 按导入闭包收集 DLL"
cp "$CJ_TAURI_ROOT/native/webview2/WebView2Loader.dll" "$OUT/"   # 按名加载，不在导入表
# cj-tauri 的存储用 sqlite3（按名加载）；有就带上，没有不影响启动
[ -f "$CJ_TAURI_ROOT/native/sqlite3.dll" ] && cp "$CJ_TAURI_ROOT/native/sqlite3.dll" "$OUT/" || true

pending=("$OUT/main.exe")
declare -A seen=()
round=0
while [ ${#pending[@]} -gt 0 ]; do
    round=$((round + 1))
    next=()
    for f in "${pending[@]}"; do
        [ -n "${seen[$f]:-}" ] && continue
        seen[$f]=1
        while read -r dep; do
            [ -z "$dep" ] && continue
            case "$dep" in lib*|stdx*) ;; *) continue ;; esac     # 系统 DLL 不管
            if [ -f "$OUT/$dep" ]; then
                next+=("$OUT/$dep")
                continue
            fi
            found=""
            for d in "${SEARCH[@]}"; do
                if [ -f "$d/$dep" ]; then found="$d/$dep"; break; fi
            done
            if [ -n "$found" ]; then
                cp "$found" "$OUT/"
                next+=("$OUT/$dep")
            else
                echo "[x] 依赖 $dep 在 SDK/框架目录里都找不到（需要它的可能是 $(basename "$f")）" >&2
                exit 3
            fi
        done < <("$OBJDUMP" -p "$f" 2>/dev/null | sed -n 's/.*DLL Name: *//p' | tr -d '\r' | sort -u)
    done
    if [ ${#next[@]} -eq 0 ]; then break; fi
    pending=("${next[@]}")
done
echo "      $round 轮，收进 $(ls "$OUT"/*.dll 2>/dev/null | wc -l | tr -d ' ') 个 DLL"

echo "[3/5] 内置 AI 引擎 cjh（可选，缺了只影响右栏 AI）"
if [ -d vendor/cjh/win-x64 ]; then
    mkdir -p "$OUT/vendor/cjh"
    cp -r vendor/cjh/win-x64 "$OUT/vendor/cjh/"
    # SHA256SUMS 是引擎自校验用的：**少了它 cjh 不会被拉起**（验不过就不执行，AGENTS §2.3）
    for f in vendor/cjh/SHA256SUMS vendor/cjh/README.md; do
        [ -f "$f" ] && cp "$f" "$OUT/vendor/cjh/"
    done
    # cjh 自己的依赖（mingw 运行时）也走一遍闭包
    for f in "$OUT"/vendor/cjh/win-x64/*.dll; do
        while read -r dep; do
            [ -z "$dep" ] && continue
            case "$dep" in lib*|stdx*) ;; *) continue ;; esac
            [ -f "$OUT/$dep" ] && continue
            for d in "${SEARCH[@]}"; do
                if [ -f "$d/$dep" ]; then cp "$d/$dep" "$OUT/"; break; fi
            done
        done < <("$OBJDUMP" -p "$f" 2>/dev/null | sed -n 's/.*DLL Name: *//p' | tr -d '\r' | sort -u)
    done
else
    echo "      [!] vendor/cjh/win-x64 不存在，AI 面板将不可用" >&2
fi

echo "[4/5] 门禁脚本（可选）"
cp -r scripts "$OUT/scripts"

echo "[5/5] 依赖闭包自检 + 打 zip"
MISSING="$(
    for f in "$OUT"/*.dll "$OUT"/main.exe; do
        "$OBJDUMP" -p "$f" 2>/dev/null | sed -n 's/.*DLL Name: *//p'
    done | tr -d '\r' | sort -u \
         | grep -Ei '^(lib|stdx)' \
         | while read -r dep; do
               [ -f "$OUT/$dep" ] || echo "$dep"
           done | sort -u
)"
if [ -n "$MISSING" ]; then
    echo "[x] 依赖闭包不完整，缺：" >&2
    echo "$MISSING" | sed 's/^/      /' >&2
    exit 2
fi
echo "      闭包自检通过"

if command -v zip >/dev/null 2>&1; then
    (cd dist && zip -qr "$NAME.zip" "$NAME")
else
    rm -f "dist/$NAME.zip"
    powershell.exe -NoProfile -Command \
        "Compress-Archive -Path '$(cygpath -w "$OUT")' -DestinationPath '$(cygpath -w "dist/$NAME.zip")' -Force" \
        >/dev/null
fi

DLLS=$(ls "$OUT"/*.dll 2>/dev/null | wc -l | tr -d ' ')
SIZE=$(du -sm "$OUT" | cut -f1)
EXESZ=$(du -sm "$OUT/main.exe" | cut -f1)
echo "[ok] 版本 $VER（$MODE）｜main.exe ${EXESZ} MB｜DLL $DLLS 个｜整包约 ${SIZE} MB"
echo "     目录：$ROOT/$OUT"
echo "     压缩：$ROOT/dist/$NAME.zip"
