#!/usr/bin/env bash
# 把 cjh 产物灌入 vendor/cjh/<平台>/，并重算 SHA256SUMS
#
# 用法：
#   ./tools/vendor-cjh.sh --source <目录|zip|tar.gz>            # 当前平台
#   ./tools/vendor-cjh.sh --source <目录|zip|tar.gz> --platform win-x64
#
# 期望的源（cjh 仓 dist/ 下的官方发布形态原样给就行，不必手工改名）：
#   Windows：cjh.exe 或 cjh-windows-x64.exe + 5 个随行件
#            （libboundscheck / libcangjie-runtime / libssl-3-x64 / libcrypto-3-x64）
#   Linux  ：cjh 或 cjh-linux-x64（单文件，静态链接，没有随行 DLL）
#
# 灌完之后**必须**同步 src/cjh_host.cj 里的 SHA256 常量（Windows 是 5 个，Linux 是 1 个），
# 否则应用启动时会报「vendor SHA256 不符」——这是设计如此：验不过就不执行。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC=""
PLATFORM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --source)   SRC="${2:-}"; shift 2 ;;
    --platform) PLATFORM="${2:-}"; shift 2 ;;
    -h|--help)  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[x] 未知参数：$1" >&2; exit 2 ;;
  esac
done

[ -n "$SRC" ] || { echo "[x] 需要 --source <目录|zip|tar.gz>" >&2; exit 2; }
[ -e "$SRC" ] || { echo "[x] 源不存在：$SRC" >&2; exit 1; }

if [ -z "$PLATFORM" ]; then
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) PLATFORM=win-x64 ;;
    Linux)                PLATFORM=linux-x64 ;;
    *) echo "[x] 未知平台，请用 --platform 指定（win-x64 / linux-x64）" >&2; exit 1 ;;
  esac
fi

# 官方发布包是归档形态：先解出目录再灌，免得每次手工 unzip/tar
EXTRACTED=""
cleanup() { [ -n "$EXTRACTED" ] && rm -rf "$EXTRACTED"; }
trap cleanup EXIT
case "$SRC" in
  *.zip)
    command -v unzip >/dev/null 2>&1 || { echo "[x] 需要 unzip 才能解开 $SRC" >&2; exit 1; }
    EXTRACTED="$(mktemp -d)"
    unzip -q "$SRC" -d "$EXTRACTED" || { echo "[x] 解包失败：$SRC" >&2; exit 1; }
    SRC="$EXTRACTED"
    ;;
  *.tar.gz|*.tgz)
    EXTRACTED="$(mktemp -d)"
    tar -xzf "$SRC" -C "$EXTRACTED" || { echo "[x] 解包失败：$SRC" >&2; exit 1; }
    SRC="$EXTRACTED"
    ;;
esac
[ -d "$SRC" ] || { echo "[x] 源目录不存在：$SRC" >&2; exit 1; }

if [ "$PLATFORM" = "win-x64" ]; then
  FILES=(cjh.exe libboundscheck.dll libcangjie-runtime.dll libssl-3-x64.dll libcrypto-3-x64.dll)
  # 归档里 exe 叫 cjh-windows-x64.exe（与裸产物 cjh.exe 区分），两种都认
  ALIAS=(cjh-windows-x64.exe:cjh.exe)
  BINNAME=cjh.exe
else
  FILES=(cjh)
  ALIAS=(cjh-linux-x64:cjh)
  BINNAME=cjh
fi

# 源里的实际文件名：先按原名找，找不到再按归档命名映射一次
pick() {
  local want="$1" a from to
  if [ -f "$SRC/$want" ]; then echo "$SRC/$want"; return 0; fi
  for a in "${ALIAS[@]}"; do
    from="${a%%:*}"; to="${a##*:}"
    if [ "$to" = "$want" ] && [ -f "$SRC/$from" ]; then echo "$SRC/$from"; return 0; fi
  done
  return 1
}

missing=()
for f in "${FILES[@]}"; do
  pick "$f" >/dev/null || missing+=("$f")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "[x] 源目录缺文件：${missing[*]}" >&2
  echo "    提示：Windows 产物是「exe + 4 个同目录 DLL」，不是单文件；Linux 产物是单个 cjh。" >&2
  exit 1
fi

DST="$ROOT/vendor/cjh/$PLATFORM"
mkdir -p "$DST"
for f in "${FILES[@]}"; do
  cp -f "$(pick "$f")" "$DST/$f"
done
chmod +x "$DST/$BINNAME" 2>/dev/null || true

# 重算总表（两个平台都列，方便一眼看全）
SUMS="$ROOT/vendor/cjh/SHA256SUMS"
: > "$SUMS"
for dir in win-x64 linux-x64; do
  [ -d "$ROOT/vendor/cjh/$dir" ] || continue
  for f in "$ROOT/vendor/cjh/$dir"/*; do
    [ -f "$f" ] || continue
    case "$f" in */SHA256SUMS) continue ;; esac
    if command -v sha256sum >/dev/null 2>&1; then
      h="$(sha256sum "$f" | awk '{print $1}')"
    else
      h="$(shasum -a 256 "$f" | awk '{print $1}')"
    fi
    printf '%s  %s/%s\n' "$h" "$dir" "$(basename "$f")" >> "$SUMS"
  done
done

echo "=== 已灌入 $DST ==="
ls -l "$DST"
echo
echo "=== SHA256SUMS（记得同步 src/cjh_host.cj 里的常量）==="
cat "$SUMS"
