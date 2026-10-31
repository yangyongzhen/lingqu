#!/usr/bin/env bash
# ============================================================================
# 打包 Windows 便携版（开发/交付辅助，不进四道闸）
#
#   ./packaging/package-win.sh
#
# 依赖三个环境变量（与本仓其它脚本同口径，不写死任何人的本机绝对路径）：
#   CANGJIE_HOME     仓颉 SDK 根
#   CANGJIE_STDX     桌面版 stdx 目录（*.dll 在这里）
#   CJ_TAURI_ROOT    cj-tauri 框架目录（native/libcjtbridge.dll 在这里）
#
# 产物：dist/lingqu-<版本>-win-x64/（目录，可直接双击 run.bat）+ 同名 .zip
#
# 为什么把"要拷哪些文件"写死成清单：漏一个 DLL 的症状是启动即退
# （0xC0000135），在别人的机器上极难自查（AGENTS §4-1/§4-2/§4-27）。
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

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

NAME="lingqu-$VER-win-x64"
OUT="dist/$NAME"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "[1/5] 主程序与资产"
cp "$EXE" "$OUT/main.exe"
cp -r assets "$OUT/assets"
cp packaging/run.bat "$OUT/run.bat"
cp packaging/README-run.md "$OUT/README.md"

echo "[2/5] 仓颉运行时 DLL"
n=0
for f in "$CANGJIE_HOME"/runtime/lib/windows_x86_64_cjnative/*.dll; do
    [ -f "$f" ] && cp "$f" "$OUT/" && n=$((n + 1))
done
echo "      $n 个"

echo "[3/5] stdx + cj-tauri 原生库"
cp "$CANGJIE_STDX"/*.dll "$OUT/" 2>/dev/null || true
cp "$CJ_TAURI_ROOT/native/libcjtbridge.dll" "$OUT/"
cp "$CJ_TAURI_ROOT/native/webview2/WebView2Loader.dll" "$OUT/"
# sqlite3 是 cj-tauri 的存储依赖，缺了会在开窗口前就退
[ -f "$CJ_TAURI_ROOT/native/sqlite3.dll" ] && cp "$CJ_TAURI_ROOT/native/sqlite3.dll" "$OUT/"
# MinGW 线程运行库：libstdx.net.tlsFFI.dll 显式依赖它，缺了就是启动即退 0xC0000135
# （cj-tauri 自己的 examples/*/dist-win 里也带这个文件，可作执法依据）
for cand in "$CANGJIE_HOME/tools/bin/libwinpthread-1.dll" "$CJ_TAURI_ROOT/native/libwinpthread-1.dll"; do
    [ -f "$cand" ] && cp "$cand" "$OUT/" && break
done
# OpenSSL（cjh 自带一份；缺了 AI 面板的 https 会全灭，见 AGENTS §4-7）
for cand in "$OUT/vendor/cjh/win-x64/libcrypto-3-x64.dll" "$CJ_TAURI_ROOT/native/libcrypto-3-x64.dll"; do
    [ -f "$cand" ] && cp "$cand" "$OUT/" && break
done
for cand in "$OUT/vendor/cjh/win-x64/libssl-3-x64.dll" "$CJ_TAURI_ROOT/native/libssl-3-x64.dll"; do
    [ -f "$cand" ] && cp "$cand" "$OUT/" && break
done

echo "[4/5] 内置 AI 引擎 cjh（可选，缺了只影响右栏 AI）"
if [ -d vendor/cjh/win-x64 ]; then
    mkdir -p "$OUT/vendor/cjh"
    cp -r vendor/cjh/win-x64 "$OUT/vendor/cjh/"
    # SHA256SUMS 是引擎自校验用的：**少了它 cjh 不会被拉起**（引擎验不过就不执行，见 AGENTS §2.3）
    for f in vendor/cjh/SHA256SUMS vendor/cjh/README.md; do
        [ -f "$f" ] && cp "$f" "$OUT/vendor/cjh/"
    done
else
    echo "      [!] vendor/cjh/win-x64 不存在，AI 面板将不可用" >&2
fi

echo "[5/5] 门禁脚本（可选）+ 依赖闭包自检 + 打 zip"
cp -r scripts "$OUT/scripts"

# ---------------------------------------------------------------------------
# 依赖闭包自检：把 main.exe 与所有随包 DLL 的导入表走一遍，凡是 lib*/stdx* 前缀
# 的依赖都必须能在包里找到。缺一个的症状就是"在开发机上好好的、拷给别人启动即退
# 0xC0000135"——那类问题在别人机器上几乎无法自查（AGENTS §4-1/§4-2/§4-27）。
# ---------------------------------------------------------------------------
OBJDUMP="${CANGJIE_HOME}/third_party/llvm/bin/llvm-objdump.exe"
if [ -f "$OBJDUMP" ]; then
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
        echo "    补进 packaging/package-win.sh 的拷贝清单后重跑。" >&2
        exit 2
    fi
    echo "      闭包自检通过"
else
    echo "      [!] 没有 llvm-objdump，跳过闭包自检" >&2
fi

if command -v zip >/dev/null 2>&1; then
    (cd dist && zip -qr "$NAME.zip" "$NAME")
else
    powershell.exe -NoProfile -Command \
        "Compress-Archive -Path '$(cygpath -w "$OUT")' -DestinationPath '$(cygpath -w "dist/$NAME.zip")' -Force" \
        >/dev/null
fi

DLLS=$(ls "$OUT"/*.dll 2>/dev/null | wc -l | tr -d ' ')
SIZE=$(du -sm "$OUT" | cut -f1)
echo "[ok] 版本 $VER｜根目录 DLL $DLLS 个｜约 ${SIZE} MB"
echo "     目录：$ROOT/$OUT"
echo "     压缩：$ROOT/dist/$NAME.zip"
