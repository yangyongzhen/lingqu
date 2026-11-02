#!/usr/bin/env bash
# ============================================================================
# 单文件打包（Windows x64）：把页面与能力清单**编进 exe**，不再需要 assets/ 目录。
#
#   ./packaging/pack-win-single.sh
#
# 产物：dist/lingqu-<版本>-win-x64-single/（exe + 依赖 DLL + vendor/cjh，**没有 assets/**）
#
# 机制（与 cj-tauri/examples/ai-chat 同款，不自己发明）：
#   ① 脚本把 `assets/ui/index.html` 与 `assets/capabilities/` 下各 json 转成 base64，
#      覆盖写进 `src/packed_assets.cj`（仓库里那是空存根，正常构建仍读盘）；
#   ② 应用侧 `src/packed_resources.cj` 的 `LingquAssetResolver` 做到"内嵌优先、缺则读盘"，
#      并在 `wire()` 里把骨架默认的 DirectoryAssetResolver 换掉、顺手补挂内嵌能力清单；
#   ③ 静态链接（见 build-static-win.sh）+ 按导入闭包收 DLL（见 package-win.sh）。
#
# 为什么不内嵌 cjh：它是**外部可执行文件**（13 MB），不是本应用代码；
# 内嵌需要走 PE 资源（RT_RCDATA）+ 运行期释放（框架 `extractEmbeddedAssets` 支持），
# 且 cj-tauri 的 C 桥得编成静态归档才谈得上"真单文件"——留作下一步，见文末 TODO。
#
# 结束时**无条件还原** `src/packed_assets.cj`（trap EXIT），仓里永远只有空存根。
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PA="src/packed_assets.cj"
[ -f "$PA" ] || { echo "[x] 缺 $PA（内嵌资源存根）" >&2; exit 1; }
[ -f assets/ui/index.html ] || { echo "[x] 缺 assets/ui/index.html" >&2; exit 1; }
[ -d assets/capabilities ] || { echo "[x] 缺 assets/capabilities/" >&2; exit 1; }

BAK="$(mktemp -t packed_assets.XXXXXX)"
cp "$PA" "$BAK"
restore() {
    cp "$BAK" "$PA"
    rm -f "$BAK"
    echo "[i] 已还原 $PA（存根回到空串）"
}
trap restore EXIT

echo "[1/3] 生成内嵌资源（base64）"
UI_B64="$(base64 -w0 assets/ui/index.html)"
CAPS_B64=""
for f in assets/capabilities/*.json; do
    [ -f "$f" ] || continue
    one="$(base64 -w0 "$f")"
    if [ -z "$CAPS_B64" ]; then
        CAPS_B64="$one"
    else
        CAPS_B64="$CAPS_B64,$one"
    fi
done
[ -n "$CAPS_B64" ] || { echo "[x] assets/capabilities/ 下没有 json" >&2; exit 1; }
# 技能正文（0.39.64 补）：漏了它单文件构建编不过（`undeclared identifier 'PACKED_SKILL_B64'`），
# 且单文件产物里没有 skills/ 目录 ⇒ 不带这份正文就装不上迁移技能。
SKILL_MD="skills/t2h-ohos-port/SKILL.md"
SKILL_B64=""
[ -f "$SKILL_MD" ] && SKILL_B64="$(base64 -w0 "$SKILL_MD")"
{
    echo 'package lingqu'
    echo ''
    echo '/* 本文件由 packaging/pack-win-single.sh 在构建期整体覆盖（仓库里是空存根）：'
    echo ' * PACKED_UI_B64  = assets/ui/index.html 的 base64'
    echo ' * PACKED_CAPS_B64 = assets/capabilities 下各 json 的 base64，英文逗号分隔'
    echo ' * PACKED_SKILL_B64 = skills/t2h-ohos-port/SKILL.md 的 base64'
    echo ' * 取用见 src/packed_resources.cj 与 src/skill_install.cj（内嵌优先、缺则读盘）。 */'
    echo ''
    printf 'public let PACKED_UI_B64: String = "%s"\n' "$UI_B64"
    printf 'public let PACKED_CAPS_B64: String = "%s"\n' "$CAPS_B64"
    printf 'public let PACKED_SKILL_B64: String = "%s"\n' "$SKILL_B64"
} > "$PA"
echo "      页面 $((${#UI_B64} / 1024)) KB｜能力清单 $((${#CAPS_B64} / 1024)) KB｜技能正文 $((${#SKILL_B64} / 1024)) KB（base64）"

echo "[2/3] 静态构建 + 打包（不带 assets/）"
./packaging/build-static-win.sh --no-assets

echo "[3/3] 结果"
VER="$(sed -n 's/^ *version *= *"\([^"]*\)".*/\1/p' cjpm.toml | head -1)"
OUT="dist/lingqu-$VER-win-x64-static"
[ -d "$OUT" ] && mv "$OUT" "dist/lingqu-$VER-win-x64-single"
if [ -f "dist/lingqu-$VER-win-x64-static.zip" ]; then
    rm -f "dist/lingqu-$VER-win-x64-single.zip"
    # 打包机通常没有 zip 命令（Git Bash 默认不带），交给 PowerShell 的 Compress-Archive（一行委托）
    if command -v zip >/dev/null 2>&1; then
        ( cd dist && zip -qr "lingqu-$VER-win-x64-single.zip" "lingqu-$VER-win-x64-single" )
    else
        powershell.exe -NoProfile -Command \
            "Compress-Archive -Path '$(cygpath -w "$ROOT/dist/lingqu-$VER-win-x64-single")' -DestinationPath '$(cygpath -w "$ROOT/dist/lingqu-$VER-win-x64-single.zip")' -Force" \
            >/dev/null
    fi
    rm -f "dist/lingqu-$VER-win-x64-static.zip"
fi
echo "      目录：$ROOT/dist/lingqu-$VER-win-x64-single"
echo "      压缩：$ROOT/dist/lingqu-$VER-win-x64-single.zip"
echo
echo "TODO（下一步，对齐 ai-chat 的完整单文件）：把 cjh 作为 PE 资源编进 exe，"
echo "     运行期经 cj-tauri 的 extractEmbeddedAssets 释放到 %LOCALAPPDATA%\\lingqu\\runtime，"
echo "     并让 C 桥提供静态归档 —— 那样连 vendor/cjh 目录与 libcjtbridge.dll 都不需要。"
