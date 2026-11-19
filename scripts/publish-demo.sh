#!/usr/bin/env bash
# 灵渠迁移台 · 把 docs/ui-mockup.html 发布成 GitHub Pages 在线演示
#
# 为什么要这个脚本：主库在 AtomGit，而"点开就能看界面"需要一个公网静态地址。
# GitHub Pages 免费、不需要服务器；代价是**建仓 + 开 Pages 必须在你的 GitHub 账号下做**
# （本机没有 gh CLI，也没有 GitHub 凭据）。所以这里把能自动化的四件事收成一条命令：
#
#   1) 打包站点（index.html = docs/ui-mockup.html，另加 .nojekyll，纯静态、零外部依赖）
#   2) 建仓（public；已存在则跳过）
#   3) 把站点推到 gh-pages 分支（凭据走 git credential helper，**不写进 remote、不打印**）
#   4) 调 Pages API 开站点，并把 html_url 回写在仓库 homepage 上
#
# 用法：
#   GITHUB_TOKEN=<pat> ./scripts/publish-demo.sh
#   GITHUB_TOKEN=<pat> ./scripts/publish-demo.sh --repo lingqu --owner yangyongzhen
#   ./scripts/publish-demo.sh --dry-run          # 只打包 + 自检，不联网
#
# 凭据来源（按序）：$GITHUB_TOKEN / $GH_TOKEN / ~/.github_token（文件内容一行）
# 需要的最小权限：classic PAT 勾 `repo`；fine-grained 则要 Contents: RW + Pages: RW +
# Administration: RW（建仓用）。**不要**把 token 贴进聊天或提交进仓。
#
# 产物地址：https://<owner>.github.io/<repo>/
#
# 退出码：0 成功；1 用法/自检失败；2 缺凭据；3 GitHub API 失败

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API="https://api.github.com"
SRC="$ROOT/docs/ui-mockup.html"

OWNER=""
REPO="lingqu"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --owner) OWNER="${2:-}"; shift 2 ;;
    --repo)  REPO="${2:-}";  shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[x] 未知参数：$1（可用 --owner / --repo / --dry-run / -h）" >&2; exit 1 ;;
  esac
done

say() { echo "[*] $*"; }
die() { echo "[x] $*" >&2; exit "${2:-1}"; }

# ---------- ① 自检：源页面必须是**自包含**的（Pages 上取不到任何相对资源） ----------
[ -f "$SRC" ] || die "源页面不存在：$SRC"
say "源页面：$SRC（$(wc -c < "$SRC" | tr -d ' ') 字节）"

EXTERNAL="$(grep -Eo '(src|href)="[^"]+"' "$SRC" | grep -v '^\(src\|href\)="#' || true)"
if [ -n "$EXTERNAL" ]; then
  echo "[!] 源页面里有外部引用，Pages 上可能 404（下列第一行为例）：" >&2
  echo "$EXTERNAL" | head -5 >&2
  die "请先把这些资源内联（本仓规矩：示意版面必须单文件，见 AGENTS §4-94）"
fi
say "自检：零外部引用（src/href 一个都没有）"

# ---------- ② 打包站点目录 ----------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$SRC" "$STAGE/index.html"
# 同时留一份原名，方便文档里的旧链接继续可用
cp "$SRC" "$STAGE/ui-mockup.html"
# 关掉 Jekyll：纯静态页面不需要它处理，也免得某个文件名被当成模板
: > "$STAGE/.nojekyll"
cat > "$STAGE/README.md" <<'MD'
# 灵渠迁移台 · 界面效果图（GitHub Pages）

本分支只放**一份纯静态页面**（`index.html`），内容与主库
[`docs/ui-mockup.html`](https://atomgit.com/qq8864/lingqu/blob/main/docs/ui-mockup.html) 逐字一致。

⚠️ 页面里的数字与列表都是**示意数据**，用于展示版面与交互，不是某次真实迁移的运行结果。
真实结果以主库 `docs/进度记录.md` 与各样本 `.lingqu/` 落档为准。

源码与门禁在 AtomGit：<https://atomgit.com/qq8864/lingqu>
MD
say "打包完成：$STAGE（index.html + ui-mockup.html + .nojekyll + README.md）"

if [ "$DRY_RUN" = "1" ]; then
  say "--dry-run：跳过建仓/推送/开 Pages。站点目录内容："
  ls -la "$STAGE" | sed 's/^/    /'
  exit 0
fi

# ---------- ③ 凭据 ----------
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$TOKEN" ] && [ -f "$HOME/.github_token" ]; then
  TOKEN="$(tr -d '\r\n' < "$HOME/.github_token")"
fi
[ -n "$TOKEN" ] || die "没有 GitHub 凭据。设 GITHUB_TOKEN=<pat> 再跑，或把 token 写进 ~/.github_token（chmod 600）。**别贴进聊天窗**" 2

api() { # api <METHOD> <PATH> [body]
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method" -H "Authorization: Bearer $TOKEN"
              -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28"
              -w '\n%{http_code}')
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" -d "$body")
  curl "${args[@]}" "$API$path"
}

# 拿登录名（--owner 没给时用）
if [ -z "$OWNER" ]; then
  RESP="$(api GET /user)"
  CODE="${RESP##*$'\n'}"
  [ "$CODE" = "200" ] || die "GET /user 失败（HTTP $CODE）——token 无效或权限不足" 3
  OWNER="$(printf '%s' "$RESP" | sed '$d' | grep -o '"login"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  [ -n "$OWNER" ] || die "拿不到登录名，请用 --owner 指定" 3
fi
say "目标仓库：$OWNER/$REPO"

PAGES_URL="https://$OWNER.github.io/$REPO/"

# ---------- ④ 建仓（已存在则跳过） ----------
RESP="$(api POST /user/repos "{\"name\":\"$REPO\",\"description\":\"灵渠迁移台 · Tauri → 鸿蒙 PC 迁移工具的界面效果图（纯静态演示页；源码在 AtomGit）\",\"homepage\":\"$PAGES_URL\",\"private\":false,\"has_issues\":false,\"has_wiki\":false}")"
CODE="${RESP##*$'\n'}"
case "$CODE" in
  201) say "已建仓：$OWNER/$REPO" ;;
  422) say "仓库已存在，跳过建仓（继续更新 Pages）" ;;
  *)   printf '%s\n' "${RESP%$'\n'*}" | head -20 >&2; die "建仓失败（HTTP $CODE）" 3 ;;
esac

# ---------- ⑤ 推 gh-pages（token 走 credential helper，不进 argv/remote） ----------
(
  cd "$STAGE" || exit 1
  git init -q -b gh-pages
  git -c user.name="lingqu-publish" -c user.email="noreply@atomgit.com" add -A
  git -c user.name="lingqu-publish" -c user.email="noreply@atomgit.com" commit -qm "docs(demo): 灵渠迁移台界面效果图（GitHub Pages）"
) || die "本地提交失败"

HELPER='!f() { test "$1" = get || return 1; echo username=x-access-token; echo "password=$LINGQU_GH_TOKEN"; }; f'
( cd "$STAGE" && LINGQU_GH_TOKEN="$TOKEN" \
  git -c credential.helper="$HELPER" push -q --force \
      "https://github.com/$OWNER/$REPO.git" HEAD:gh-pages ) \
  || die "推送 gh-pages 失败（token 是否含 Contents: 写权限？）" 3
say "已推送 gh-pages"

# ---------- ⑥ 开 Pages + 回写 homepage ----------
RESP="$(api POST "/repos/$OWNER/$REPO/pages" '{"source":{"branch":"gh-pages","path":"/"}}')"
CODE="${RESP##*$'\n'}"
case "$CODE" in
  201) say "Pages 已开启（首次构建约 1 分钟）" ;;
  409) say "Pages 已开启，跳过" ;;
  *)   printf '%s\n' "${RESP%$'\n'*}" | head -20 >&2; die "开 Pages 失败（HTTP $CODE）" 3 ;;
esac

api PATCH "/repos/$OWNER/$REPO" "{\"homepage\":\"$PAGES_URL\"}" >/dev/null || true

# 等第一次构建（最多 90 秒），拿到 html_url 更可信
i=0
while [ "$i" -lt 18 ]; do
  RESP="$(api GET "/repos/$OWNER/$REPO/pages")"
  CODE="${RESP##*$'\n'}"
  if [ "$CODE" = "200" ]; then
    STATUS="$(printf '%s' "$RESP" | sed '$d' | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
    case "$STATUS" in
      built|curing) say "构建状态：$STATUS" ;;
      *) say "构建状态：${STATUS:-unknown}" ;;
    esac
    [ "$STATUS" = "built" ] && break
  fi
  i=$((i + 1)); sleep 5
done

echo
say "演示地址：$PAGES_URL"
say "源文件   ：docs/ui-mockup.html（改完重跑本脚本即更新）"
say "提示     ：Pages 首次构建可能还要几十秒；若 404 就等一会儿再刷"
