#!/usr/bin/env bash
# ============================================================================
# **真·单文件**打包（Windows x64）：产出**只有一个 main.exe**（无 DLL、无 assets/、无 vendor/）。
#
#   ./packaging/pack-win-single-full.sh
#   产物：dist/lingqu-<版本>-win-x64-full/main.exe（+ README-single.md）
#
# 与 pack-win-single.sh 的区别：那个还留着 5 个 DLL 与 vendor/ 目录；这个把它们全部处理掉：
#
#   ① 仓颉 std / stdx 静态链接          → compile-option = "--static --static-std" + stdx 的 static 树
#   ② C 桥编成静态归档 libcjtbridge.a   → 不再有 libcjtbridge.dll
#   ③ WebView2Loader.dll 的字节编进桥   → -DCJ_EMBED_WEBVIEW2_LOADER，首次运行释放到 %TEMP% 后按绝对路径加载
#   ④ cjh 与它的 3 个运行时 DLL 作为 PE 资源（RT_RCDATA）随行
#      → -DCJ_PACK_ASSETS_EMBEDDED + windres 编 pack_assets.o，运行期 extractEmbeddedAssets
#        释放到 %LOCALAPPDATA%\lingqu\cjh，再按绝对路径拉起
#   ⑤ 页面与能力清单编进二进制        → packaging/pack-win-single.sh 那套（本脚本复用其做法）
#
# 机制**照抄** `cj-tauri/scripts/pack-win-single.sh`（成熟实现），不自己发明；差异只有两处：
#   · 我们不是 examples/* 结构，资产在 assets/ 与 vendor/，所以 bridge 与 rc 的路径按本仓写；
#   · 我们走 targets/desktop 骨架，所以改的是派生 cjpm.toml 并 **trap 无条件还原**（AGENTS §4-50）。
#
# 依赖（本机已具备）：CANGJIE_HOME、CANGJIE_STDX_ROOT（含 static/stdx）、
#   WEBVIEW2_SDK_ROOT/build/native/include/WebView2.h、llvm-mingw 的 gcc/ar/windres、
#   cj-tauri 的 native/core + native/platforms/windows 与 native/webview2/WebView2Loader.dll。
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() { echo "[pack-full] $*" >&2; exit 1; }
to_posix() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi; }
to_win()   { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1" | sed 's|\\|/|g'; fi; }

# ---------- 环境 ----------
: "${CANGJIE_HOME:?需要 CANGJIE_HOME}"
CANGJIE_HOME="$(to_posix "$CANGJIE_HOME")"
SDK_LIB="$CANGJIE_HOME/runtime/lib/windows_x86_64_cjnative"

STDX_ROOT="${CANGJIE_STDX_ROOT:-/d/cangjie-stdx/windows_x86_64_cjnative}"
STDX_STATIC="$STDX_ROOT/static/stdx"
[ -d "$STDX_STATIC" ] || die "缺 stdx 静态包: $STDX_STATIC（设 CANGJIE_STDX_ROOT 指向解压根）"

WEBVIEW2_SDK_ROOT="${WEBVIEW2_SDK_ROOT:-/d/webview2sdk/sdk-1.0.2365.46}"
WEBVIEW2_INCLUDE="$WEBVIEW2_SDK_ROOT/build/native/include"
[ -f "$WEBVIEW2_INCLUDE/WebView2.h" ] || die "缺 WebView2 头文件: $WEBVIEW2_INCLUDE/WebView2.h"

FRAMEWORK="$(to_posix "${CJ_TAURI_ROOT:?需要 CJ_TAURI_ROOT}")"
NATIVE="$FRAMEWORK/native"
[ -f "$NATIVE/core/bridge_core.c" ] || die "缺框架 C 桥源码: $NATIVE/core/bridge_core.c"
[ -f "$NATIVE/platforms/windows/bridge_win.c" ] || die "缺框架 C 桥源码: $NATIVE/platforms/windows/bridge_win.c"
[ -f "$NATIVE/webview2/WebView2Loader.dll" ] || die "缺 $NATIVE/webview2/WebView2Loader.dll"

for t in gcc ar windres base64; do
    command -v "$t" >/dev/null 2>&1 || die "缺工具 $t（llvm-mingw + Git Bash coreutils）"
done

VER="$(sed -n 's/^ *version *= *"\([^"]*\)".*/\1/p' cjpm.toml | head -1)"
[ -n "$VER" ] || die "读不到 cjpm.toml 的 version"
NAME="lingqu-$VER-win-x64-full"
OUT="dist/$NAME"
WORK="dist/.work-full"
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/bridge" "$OUT"

# ---------- ① 静态桥：WebView2Loader 字节 + 随包资源表 ----------
echo "[1/6] 编静态桥（内嵌 WebView2Loader + 随包资源表）"
LOADER_DLL="$NATIVE/webview2/WebView2Loader.dll"
LOADER_BYTES="$(stat -c%s "$LOADER_DLL")"
{
    printf '#define CJ_WV2_LOADER_SIZE %su\n' "$LOADER_BYTES"
    printf 'static const unsigned char CJ_WV2_LOADER_BYTES[CJ_WV2_LOADER_SIZE] = {\n'
    od -An -v -tu1 "$LOADER_DLL" | awk '{for (i = 1; i <= NF; i++) printf "0x%02x,", $i; printf "\n"}'
    printf '};\n'
} > "$WORK/bridge/webview2_loader_embed.h"

RC_FILE="$WORK/bridge/pack_assets.rc"
MAP_HDR="$WORK/bridge/pack_assets_map.h"
: > "$RC_FILE"
{
    printf '/* 打包器生成：资源 ID -> 释放文件名。不要手改。 */\n'
    printf 'typedef struct {\n    int id;\n    const char *name;\n} CjPackAsset;\n'
    printf 'static const CjPackAsset CJ_PACK_ASSETS[] = {\n'
} > "$MAP_HDR"
ASSET_COUNT=0
ASSET_ID=1001
while IFS= read -r line; do
    line="$(printf '%s' "$line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$line" in '' | '#'*) continue ;; esac
    [ -f "$ROOT/$line" ] || die "packaging/pack-assets.txt 指向的文件不存在: $line"
    printf '%d RCDATA "%s"\n' "$ASSET_ID" "$(to_win "$ROOT/$line")" >> "$RC_FILE"
    printf '    { %d, "%s" },\n' "$ASSET_ID" "$(basename "$line")" >> "$MAP_HDR"
    ASSET_COUNT=$((ASSET_COUNT + 1))
    ASSET_ID=$((ASSET_ID + 1))
done < packaging/pack-assets.txt
printf '};\n' >> "$MAP_HDR"
[ "$ASSET_COUNT" -gt 0 ] || die "pack-assets.txt 里没有有效条目"
echo "      随包资源 $ASSET_COUNT 个；WebView2Loader ${LOADER_BYTES} 字节"

# windres 是原生 Windows 程序，要用相对路径 + cd 进去（认 MSYS 的 /e/... 会报 no such file）
( cd "$WORK/bridge" && windres -O coff -i pack_assets.rc -o pack_assets.o ) || die "windres 编译资源失败"

BRIDGE_WIN="$(to_win "$ROOT/$WORK/bridge")"
( cd "$WORK/bridge" && gcc -c -O2 -fstack-protector-all \
    -DCJ_EMBED_WEBVIEW2_LOADER -DCJ_PACK_ASSETS_EMBEDDED \
    -I"$BRIDGE_WIN" -I"$(to_win "$NATIVE/core")" -I"$(to_win "$WEBVIEW2_INCLUDE")" \
    "$(to_win "$NATIVE/core/bridge_core.c")" "$(to_win "$NATIVE/platforms/windows/bridge_win.c")" && \
    ar rcs libcjtbridge.a bridge_core.o bridge_win.o ) || die "静态桥编译失败"
BRIDGE_LIB="$WORK/bridge/libcjtbridge.a"
[ -f "$BRIDGE_LIB" ] || die "静态桥没产出"

# ---------- ② 内嵌页面与能力清单（复用 pack-win-single.sh 的做法） ----------
echo "[2/6] 生成内嵌页面与能力清单（base64）"
PA="src/packed_assets.cj"
PA_BAK="$WORK/packed_assets.cj.bak"
cp "$PA" "$PA_BAK"
TOML="targets/desktop/cjpm.toml"
TOML_BAK="$WORK/desktop-cjpm.toml.bak"
cp "$TOML" "$TOML_BAK"
restore() {
    cp "$PA_BAK" "$PA"
    cp "$TOML_BAK" "$TOML"
    rm -rf "$WORK"
    echo "[i] 已还原 src/packed_assets.cj 与 targets/desktop/cjpm.toml"
}
trap restore EXIT

# 内嵌哪几个常量，**以存根声明为准**（照 cj-tauri/scripts/pack-win-single.sh 的做法）：
# 存根里写了几行 `public let PACKED_*_B64: String = ""`，这里就必须生成几行。
# 为什么要这样：0.39.64 之前两个脚本都写死 "只生成 UI + CAPS"，而 0.39.x 给技能正文加了
# `PACKED_SKILL_B64` ⇒ 单文件构建直接编不过（`undeclared identifier 'PACKED_SKILL_B64'`）。
# 写死清单的脚本，永远会跟存根漂移；改成"按声明生成 + 不认识就报错"才不会再犯。
gen_asset() {
    local name="$1"
    case "$name" in
        PACKED_UI_B64)
            base64 -w0 assets/ui/index.html ;;
        PACKED_CAPS_B64)
            local out="" one
            for f in assets/capabilities/*.json; do
                [ -f "$f" ] || continue
                one="$(base64 -w0 "$f")"
                if [ -z "$out" ]; then out="$one"; else out="$out,$one"; fi
            done
            [ -n "$out" ] || die "assets/capabilities/ 下没有 json（单文件产物没有随行清单，命令会全被拒）"
            printf '%s' "$out" ;;
        PACKED_SKILL_B64)
            [ -f skills/t2h-ohos-port/SKILL.md ] || die "缺 skills/t2h-ohos-port/SKILL.md（单文件包里装技能会失败）"
            base64 -w0 skills/t2h-ohos-port/SKILL.md ;;
        *)
            # 存根声明了本脚本不认识的资源：宁可失败，也不要悄悄产出一个"少一块内容"的单文件包
            die "存根声明了 $name，但本脚本不知道怎么生成它（新增内嵌资源请在这里补一行）" ;;
    esac
}

ASSET_NAMES=()
while IFS= read -r n; do
    [ -n "$n" ] && ASSET_NAMES+=("$n")
done < <(sed -n 's/^public let \(PACKED_[A-Z0-9_]*_B64\): String = "".*/\1/p' "$PA")
[ ${#ASSET_NAMES[@]} -gt 0 ] || die "src/packed_assets.cj 里没有 `public let PACKED_*_B64` 空存根（单文件包必须有内嵌资源）"

{
    echo 'package lingqu'
    echo ''
    echo '/* 由 packaging/pack-win-single-full.sh 在构建期整体覆盖（仓库里是空存根）。 */'
    echo ''
    for n in "${ASSET_NAMES[@]}"; do
        v="$(gen_asset "$n")"
        printf 'public let %s: String = "%s"\n' "$n" "$v"
        echo "      $n：$((${#v} / 1024)) KB(base64)" >&2
    done
} > "$PA"

# ---------- ③ 改派生 cjpm.toml：静态三件套 + 静态桥 + 资源对象 ----------
echo "[3/6] 临时改 $TOML（静态链接 + 静态桥），构建后无条件还原"
sed -i 's|^\(  compile-option = \)""$|\1"--static --static-std"|' "$TOML"
# 资源对象必须作为**链接输入**直接给 ld.lld：静态库按需提取，没有符号引用的资源对象塞进 .a 不会被取
# 用 awk 整行替换更稳：sed 的 BRE 里「可选分组」写法在不同 sed 上表现不一（实测没改上）
# COM 的 IID_* 守卫符号（IID_IFileOpenDialog / IID_IDropTarget …）在 mingw 的 libuuid.a 里，
# 桥的 Windows 实现用了文件对话框与拖放，所以 -luuid -lole32 -loleaut32 一个都不能少；
# 这套清单与框架自带的 native/build_win.bat 对齐（那边是 DLL 版桥，链接库相同）。
LINK_LINE="  link-option = \"-L$BRIDGE_WIN -lcjtbridge $BRIDGE_WIN/pack_assets.o -lole32 -loleaut32 -luuid -lcomdlg32 -lgdi32 -loleacc -lshlwapi -lshcore -lshell32 -ladvapi32 -lcrypt32 -lbcrypt -lws2_32 -liphlpapi -luserenv -lpsapi --subsystem=windows\""
awk -v repl="$LINK_LINE" '
    /--subsystem=windows/ { print repl; next }
    { print }
' "$TOML" > "$TOML.new" && mv "$TOML.new" "$TOML"
grep -q -- '--static --static-std' "$TOML" || die "没改上 compile-option（派生 toml 结构变了？）"
grep -q -- 'pack_assets.o' "$TOML" || die "没改上 link-option（派生 toml 结构变了？）"
# 只校验 **mingw 那行**（--subsystem=windows）：Linux 那行的 -L native 是另一码事
MINGW_LINK="$(grep -- '--subsystem=windows' "$TOML" | head -1)"
echo "$MINGW_LINK" | grep -q 'native' && die "mingw 链接行里还留着框架 native 的 -L（会链到 DLL 导入库）"

# ---------- ④ 构建 ----------
echo "[4/6] 静态构建（全量重编；几分钟）"
export CANGJIE_STDX="$STDX_STATIC"
export PATH="$(to_posix "$SDK_LIB"):$(to_posix "$CANGJIE_HOME/bin"):$(to_posix "$CANGJIE_HOME/tools/bin"):$(to_posix "$CANGJIE_HOME/tools/lib"):$PATH"
rm -rf targets/desktop/target
( cd targets/desktop && "$(to_posix "$CANGJIE_HOME/tools/bin/cjpm.exe")" build )

EXE="targets/desktop/target/release/bin/main.exe"
[ -f "$EXE" ] || die "没有产出 $EXE"
SIZE_RAW="$(stat -c%s "$EXE")"
cp "$EXE" "$OUT/main.exe"
cp packaging/README-full.md "$OUT/README.md"

# strip（照 cj-tauri/scripts/pack-win-single.sh）：仓颉 release 产物带着完整调试信息，
# 静态单文件实测 61 MB → strip 后小一大截，交出去才像回事。
# 两个已被踩过的坑：
#   ① 原生 llvm 工具（strip/objcopy）只认 `C:/...` 形式路径，传 MSYS 的 `/e/...` 报 No such file；
#   ② llvm-mingw 的 `strip.exe` 是包装器，真身 `llvm-strip` 有些发行包里缺失 —— 直接 `2>/dev/null`
#      会把真实报错吞掉、看起来像"strip 对这个 exe 无效"。所以失败回退 SDK 自带的 llvm-objcopy。
EXE_W="$(to_win "$OUT/main.exe")"
if strip "$EXE_W" 2>/dev/null; then
    echo "[strip] $SIZE_RAW → $(stat -c%s "$OUT/main.exe") 字节（strip）"
elif [ -f "$CANGJIE_HOME/third_party/llvm/bin/llvm-objcopy.exe" ] && \
     "$(to_posix "$CANGJIE_HOME/third_party/llvm/bin/llvm-objcopy.exe")" --strip-all "$EXE_W" 2>/dev/null; then
    echo "[strip] $SIZE_RAW → $(stat -c%s "$OUT/main.exe") 字节（llvm-objcopy 回退）"
else
    echo "[strip] 警告：strip 失败，保留未裁剪的 exe（$SIZE_RAW 字节）" >&2
fi

# ---------- ⑤ 自检：不许再依赖那些 DLL，且必须有资源节 ----------
echo "[5/6] 自检（导入表 / 资源节）"
OBJDUMP="$(to_posix "$CANGJIE_HOME/third_party/llvm/bin/llvm-objdump.exe")"
IMPORTS="$("$OBJDUMP" -p "$OUT/main.exe" | sed -n 's/.*DLL Name: *//p' | tr -d '\r' | sort -u)"
for bad in libcjtbridge.dll WebView2Loader.dll libcangjie-runtime.dll libboundscheck.dll; do
    if echo "$IMPORTS" | grep -qi "^${bad}$"; then
        echo "[x] main.exe 仍导入 $bad —— 静态化没成功" >&2
        echo "$IMPORTS" | sed 's/^/      /' >&2
        exit 4
    fi
done
if ! "$OBJDUMP" -h "$OUT/main.exe" | grep -qi '\.rsrc'; then
    die "main.exe 没有 .rsrc 节 —— 随包资源（cjh）没嵌进去，运行期会报 AI 引擎缺失"
fi
echo "      导入表：$(echo "$IMPORTS" | tr '\n' ' ')"
echo "      有 .rsrc 资源节 ✔"

# ---------- ⑥ 打 zip ----------
echo "[6/6] 打 zip"
SIZE_MB=$(( $(stat -c%s "$OUT/main.exe") / 1024 / 1024 ))
if command -v zip >/dev/null 2>&1; then
    ( cd dist && rm -f "$NAME.zip" && zip -qr "$NAME.zip" "$NAME" )
else
    rm -f "dist/$NAME.zip"
    powershell.exe -NoProfile -Command \
        "Compress-Archive -Path '$(to_win "$OUT")' -DestinationPath '$(to_win "$ROOT/dist/$NAME.zip")' -Force" >/dev/null
fi
echo "[ok] 版本 $VER（full single-file）｜main.exe ${SIZE_MB} MB｜包里只有 main.exe + README"
echo "     目录：$ROOT/$OUT"
echo "     压缩：$ROOT/dist/$NAME.zip"
