#!/usr/bin/env bash
# 灵渠迁移台 · 交付门禁（唯一交付凭证）
#
# 四道闸，缺一不可，任何一道红即整体失败（exit 1）：
#   ① 业务包 cjpm build   —— 零警告（cj-tauri 的硬规矩：unused/import/deprecated 一律清零）
#   ② 业务包 cjpm test    —— 单元测试全绿（FAILED=0 / ERROR=0）
#   ③ cj-tauri check     —— 清单校验 + 骨架漂移 + 能力三方比对（声明×自述×装配）
#   ④ 桌面产物 cjpm build —— 骨架侧也要编得过
#
# 为什么是 bash：本仓要跨平台（当前 Windows + Linux，后续鸿蒙 PC）。
# 一份实现，Windows 用 scripts/test.bat 包装（它只负责找到 bash 再委托过来），
# 与 cj-tauri / cjh 两个上游仓的口径一致（它们也是 test.sh + run_win.bat 的组合）。
#
# 用法：
#   ./scripts/test.sh               # 全量（交付前必跑）
#   ./scripts/test.sh -q            # 只跑 ①②（改业务代码时的快速回路）
#   ./scripts/test.sh -s            # 先 cj-tauri sync 再跑（改了 cj-tauri.toml 之后）
#   ./scripts/test.sh -c            # 删增量缓存再跑（业务包公开接口变更后必须）
#
# 环境变量（都有按平台的默认值，跨机器时覆盖即可）：
#   CANGJIE_HOME / CANGJIE_STDX / CJ_TAURI_ROOT

set -uo pipefail

QUICK=0
SYNC=0
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    -q|--quick) QUICK=1 ;;
    -s|--sync)  SYNC=1 ;;
    -c|--clean) CLEAN=1 ;;
    -h|--help)
      sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "[x] 未知参数：$arg（可用 -q / -s / -c / -h）" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 注意：ROOT_WIN 必须**在** to_posix_rev_win 定义之后再算（见下方）。
# bash 不会预解析函数，写在前面会「command not found」→ ROOT_WIN 空串 →
# `Path.StartsWith('')` 恒为真 → 把 cjh 引擎也一起杀了（0.39.27 实测踩到）。

# ---------- 平台探测 ----------
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  Linux)                OS=linux ;;
  Darwin)               OS=macos ;;
  *)                    OS=unknown ;;
esac

# Windows 形式的路径（D:\x\y 或 D:/x/y）在 MSYS 的 PATH 里是无效条目——
# 机器上若已导出 CANGJIE_HOME=D:\... ，直接把 Windows 形式塞进 PATH 会导致
# 所有命令 exit 127（command not found）。统一转成 /d/x/y。
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

# to_posix 的反向：`/e/test/x` → `E:\test\x`
# 用途：让 Windows 侧的 PowerShell 能判断"这个 main.exe 是不是本仓的产物"
# （`tasklist` 不给可执行路径，只能靠 PowerShell 的 Process.Path 比前缀）。
to_posix_rev_win() {
  case "$1" in
    /[A-Za-z]/*)
      local drive rest
      drive="$(printf '%s' "${1:1:1}" | tr 'a-z' 'A-Z')"
      rest="${1:2}"
      # 注意：`${rest//\//\\}` 在不同 bash 上产出可能是两个反斜杠，
      # 会让后面的 StartsWith 永远匹配不上（实测踩到：本该杀掉的应用被判成"不是本仓的"）。
      # 这里用 tr 做一次性替换，结果是确定的单反斜杠。
      printf '%s:%s\n' "$drive" "$(printf '%s' "$rest" | tr '/' '\\')"
      ;;
    *) printf '%s\n' "$1" ;;
  esac
}

ROOT_WIN="$(to_posix_rev_win "$ROOT")"

# ---------- 默认路径（环境变量优先） ----------
if [ "$OS" = "windows" ]; then
  : "${CANGJIE_HOME:=/d/Program Files (x86)/Cangjie}"
  : "${CANGJIE_STDX:=/d/cangjie-stdx/windows_x86_64_cjnative/dynamic/stdx}"
  : "${CJ_TAURI_ROOT:=/e/test/harmonyos/test/cj-tauri}"
else
  : "${CANGJIE_HOME:=/opt/cangjie/cangjie}"
  : "${CANGJIE_STDX:=/opt/cangjie-stdx/linux_x86_64_cjnative/dynamic/stdx}"
  : "${CJ_TAURI_ROOT:=$ROOT/../cj-tauri}"
fi

say()  { printf '%s\n' "$*"; }
info() { printf '\033[36m%s\033[0m\n' "$*"; }
pass() { printf '  \033[32m[PASS]\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }
warn() { printf '      \033[33m%s\033[0m\n' "$*"; }

# 三个根路径统一归一化（Windows 上环境变量可能是 D:\... 形式）
CANGJIE_HOME="$(to_posix "$CANGJIE_HOME")"
CANGJIE_STDX="$(to_posix "$CANGJIE_STDX")"
CJ_TAURI_ROOT="$(to_posix "$CJ_TAURI_ROOT")"
export CANGJIE_HOME CANGJIE_STDX CJ_TAURI_ROOT

for d in "$CANGJIE_HOME" "$CANGJIE_STDX" "$CJ_TAURI_ROOT/native"; do
  [ -d "$d" ] || { echo "[x] 缺目录：$d（用环境变量覆盖脚本内置默认值）" >&2; exit 1; }
done

CLI="$CJ_TAURI_ROOT/cli/target/release/bin/main.exe"
[ "$OS" = "linux" ] && CLI="$CJ_TAURI_ROOT/cli/target/release/bin/main"

# ---------- PATH / 动态库 ----------
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

# 跑原生命令并同时收 stdout+stderr（写临时文件，不做管道捕获：
# 管道里的 stderr 记录对象在 set -e 环境下会带来一堆噪音，落文件最干净）
TEXT=""
CODE=0
run_capture() {
  local dir="$1"; shift
  local log
  log="$(mktemp 2>/dev/null || echo "/tmp/lingqu-gate.$$")"
  ( cd "$dir" && "$@" ) >"$log" 2>&1
  CODE=$?
  # 去掉 ANSI 转义（cjpm 的彩色输出）
  TEXT="$(sed -E "s/$(printf '\033')\[[0-9;]*m//g" "$log" 2>/dev/null || cat "$log")"
  rm -f "$log"
}

count_pattern() { printf '%s\n' "$TEXT" | grep -c -E "$1" || true; }

# 跑原生命令，并**只对"根本没起来"重试**（126 / 127 = EACCES / command not found）。
#
# 起因（0.39.152 实测）：本机安全软件偶发拦进程创建（§4-152 同族），`cj-tauri` CLI 会在 exec 阶段
# 直接 `Permission denied`（126）或静默 127。今天实测同一份 PATH 下 `--version` **30/30 成功**、
# `sync` **3/3 成功** ⇒ 不是缺 DLL、也不是缺 PATH（§4-210 早先那条"必红"的归因据此修正），
# 而是**偶发**；对它重试比改环境更贴近真相。
# 命令真跑起来但自己失败（check 返回 1 并打印原因）**不重试**——那是真红。
ATTEMPTS=0
run_capture_retry() {
  local tries="$1"; shift
  local n=0
  while : ; do
    n=$((n + 1))
    run_capture "$@"
    ATTEMPTS=$n
    case "$CODE" in
      126|127) ;;
      *) return 0 ;;
    esac
    [ "$n" -ge "$tries" ] && return 0
    say "      （启动失败 rc=${CODE}，第 ${n} 次重试…）"
    sleep 1
  done
}

# 启动失败时的通用提示：让看日志的人别再往"缺 DLL / 缺 PATH"上猜
spawn_fail_hint() {
  case "$CODE" in
    126|127) warn "进程起不来（rc=${CODE}）：多为安全软件拦进程创建，重试一次通常就过（AGENTS §4-152 / §4-210）" ;;
  esac
}

# ---------- 只结束"本仓自己的" main.exe（别按进程名一刀切） ----------
# 现象（0.39.27 实测）：dev 期间一边开着应用一边跑门禁，第 ④/⑤ 闸为了释放产物
# 执行 `taskkill /F /IM main.exe` —— **按进程名一刀切**，于是把同样叫 main.exe 的
# **cjh 引擎**也杀了（cjh 的可执行文件就叫 main.exe）。用户看到的是聊天面板
# 「连接已断开——回复可能不完整」，然后再也连不回去。
# 因此：只结束路径落在**本仓**下的 main.exe（targets/desktop 的产物、cli/ 的产物），
# 绝不碰 cjh / cj-tauri 的 main.exe。
kill_own_main_exe() {
  if [ "$OS" != "windows" ]; then
    return 0
  fi
  # 空串会让 StartsWith('') 恒真 → 等于回到"一刀切"，先拦住（§4-93）
  if [ -z "$ROOT_WIN" ]; then
    warn "[!] ROOT_WIN 为空，无法判定哪些 main.exe 属于本仓 —— 为免误杀 cjh 引擎，本次不结束任何进程"
    return 1
  fi
  # 用 PowerShell 拿 Process.Path 过滤（tasklist 不给路径，做不到"只杀自己的"）
  powershell -NoProfile -Command "
    Get-Process main -ErrorAction SilentlyContinue |
      Where-Object { \$_.Path -and (\$_.Path.StartsWith('$ROOT_WIN', [System.StringComparison]::OrdinalIgnoreCase)) } |
      ForEach-Object { Write-Host ('  [kill] ' + \$_.Id + '  ' + \$_.Path); \$_.Kill() }
  " 2>/dev/null || true
}

# 失败时打印捕获日志的尾部：失败原因往往既不含 FAILED 也不含 error:（而是崩溃/链接错），
# 只 grep 关键词会把真正原因藏起来。
dump_tail() {
  local n="${1:-30}"
  printf '%s\n' "$TEXT" | tail -n "$n" | while IFS= read -r l; do warn "$l"; done
}

RESULTS=()

info "=== 灵渠交付门禁（$OS）==="
say "工程      : $ROOT"
say "仓颉 SDK  : $CANGJIE_HOME"
say "stdx      : $CANGJIE_STDX"
say "cj-tauri  : $CJ_TAURI_ROOT"

# ---------- 可选：sync ----------
if [ "$SYNC" = "1" ]; then
  info "[0/5] cj-tauri sync ..."
  if [ ! -x "$CLI" ] && [ ! -f "$CLI" ]; then fail "找不到 cj-tauri CLI：$CLI"; exit 1; fi
  run_capture_retry 3 "$ROOT" "$CLI" sync
  if [ "$CODE" -ne 0 ]; then fail "sync 失败（rc=${CODE}）"; spawn_fail_hint; printf '%s\n' "$TEXT"; exit 1; fi
  pass "sync"
fi

# ---------- ① 业务包构建（零警告） ----------
info "[1/5] 业务包 cjpm build（零警告）..."
run_capture "$ROOT" cjpm build
WARN="$(count_pattern '^[[:space:]]*warning:')"
if [ "$CODE" -eq 0 ] && [ "$WARN" -eq 0 ]; then
  pass "cjpm build（0 warning）"
  RESULTS+=("build-biz:PASS")
else
  fail "cjpm build exit=$CODE warnings=$WARN"
  dump_tail 40
  RESULTS+=("build-biz:FAIL")
fi

# ---------- ② 单元测试 ----------
info "[2/5] 业务包 cjpm test ..."
run_capture "$ROOT" cjpm test
FAILN="$(count_pattern 'FAILED:[[:space:]]*[1-9]')"
ERRN="$(count_pattern 'ERROR:[[:space:]]*[1-9]')"
TOTAL="$(printf '%s\n' "$TEXT" | grep -oE 'TOTAL:[[:space:]]*[0-9]+' | tail -1 | grep -oE '[0-9]+' || true)"
if [ "$CODE" -eq 0 ] && [ "$FAILN" -eq 0 ] && [ "$ERRN" -eq 0 ]; then
  pass "cjpm test（TOTAL=${TOTAL:-?}，FAILED=0，ERROR=0）"
  RESULTS+=("test:PASS")
else
  fail "cjpm test exit=$CODE（FAILED=$FAILN ERROR=$ERRN）"
  # 不要只 grep FAILED/ERROR —— 测试二进制崩溃/编译失败时日志里根本没有这两个词，
  # 早先版本就是因为只 grep 而把真实原因藏了（见 AGENTS §4 第 13 条）
  dump_tail 40
  RESULTS+=("test:FAIL")
fi

if [ "$QUICK" = "1" ]; then
  say ""
  say "（-q：跳过 ③④）"
  if printf '%s\n' "${RESULTS[@]}" | grep -q 'FAIL'; then exit 1; fi
  printf '\033[32m结果：%s\033[0m\n' "${RESULTS[*]}"
  exit 0
fi

# ---------- ③ cj-tauri check（三方比对 + 漂移） ----------
info "[3/5] cj-tauri check（能力三方比对 / 骨架漂移）..."
if [ ! -f "$CLI" ] && [ ! -x "$CLI" ]; then
  fail "找不到 CLI：$CLI"
  RESULTS+=("check:FAIL")
else
  run_capture_retry 3 "$ROOT" "$CLI" check
  if [ "$CODE" -eq 0 ]; then
    if [ "$ATTEMPTS" -gt 1 ]; then
      pass "cj-tauri check（第 ${ATTEMPTS} 次才起来：瞬时进程创建失败，已重试）"
    else
      pass "cj-tauri check"
    fi
    RESULTS+=("check:PASS")
  else
    fail "cj-tauri check（rc=${CODE}）"
    spawn_fail_hint
    printf '%s\n' "$TEXT" | head -20 | while IFS= read -r l; do [ -n "$l" ] && warn "$l"; done
    RESULTS+=("check:FAIL")
  fi
fi

# ---------- ③ 页面脚本语法（0.39.52）----------
# 起因：改 index.html 时用"行范围替换"误留了一个多余的 `}`，页面**整块 JS 都跑不起来**——
# 表现是窗口照起、界面全空、ui-report.log 都不生成（又一个"点了没反应"）。
# 这种错误 `cjpm build` 与 `cj-tauri check` 都看不见，只能用解析器查：有 node 就查，没有就跳过并说明。
if command -v node >/dev/null 2>&1; then
  info "[3b/5] 页面脚本语法（node --check 抽取 index.html 的 <script> 块）..."
  JS_TMP="$(mktemp -d)"
  node -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");
const out = process.argv[2];
const re = /<script>([\s\S]*?)<\/script>/g;
let m, i = 0, files = [];
while ((m = re.exec(src)) !== null) {
  i += 1;
  const f = out + "/blk" + i + ".js";
  fs.writeFileSync(f, m[1]);
  files.push(f);
}
console.log(files.join("\n"));
' "$ROOT/assets/ui/index.html" "$JS_TMP" > "$JS_TMP/list.txt" 2>&1
  JS_FAIL=0
  if [ -s "$JS_TMP/list.txt" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      if ! OUT="$(node --check "$f" 2>&1)"; then
        JS_FAIL=1
        warn "语法错误：$(basename "$f")"
        printf '%s\n' "$OUT" | head -8 | while IFS= read -r l; do [ -n "$l" ] && warn "  $l"; done
      fi
    done < "$JS_TMP/list.txt"
  else
    JS_FAIL=1
    warn "抽取 <script> 失败：$(head -3 "$JS_TMP/list.txt")"
  fi
  rm -rf "$JS_TMP"
  if [ "$JS_FAIL" -eq 0 ]; then
    pass "页面脚本语法"
    RESULTS+=("js-syntax:PASS")
  else
    fail "页面脚本语法（有语法错误的页面整块 JS 不执行，界面会像'点了没反应'）"
    RESULTS+=("js-syntax:FAIL")
  fi
else
  warn "[3b/5] 没找到 node，跳过页面脚本语法检查（不影响其它闸）"
fi

# ---------- ④ 桌面产物构建 ----------
info "[4/5] 桌面产物 cjpm build（targets/desktop）..."
APPDIR="$ROOT/targets/desktop"
if [ ! -d "$APPDIR" ]; then
  fail "骨架不存在：$APPDIR（先跑 ./scripts/test.sh -s）"
  RESULTS+=("build-app:FAIL")
else
  if [ "$CLEAN" = "1" ]; then
    # 业务包公开接口变了之后，骨架的增量缓存会留下旧对象
    # （现象：链接报一串乱码符号名 undefined symbol: _CGP7cjTauri…）
    warn "-c：删除增量缓存（targets/desktop/target 与 target/）"
    rm -rf "$APPDIR/target" "$ROOT/target"
  fi
  # 产物被占用是最常见的假失败：上一版窗口还开着，链接器报 Permission denied
  if [ "$OS" = "windows" ]; then
    if tasklist 2>/dev/null | grep -qi '^main\.exe'; then
      warn "[!] 上一版 main.exe 仍在运行，先结束**本仓的**那些（不碰 cjh 引擎，见 §4-92）"
      kill_own_main_exe
      sleep 1
    fi
  else
    pgrep -x main >/dev/null 2>&1 && {
      warn "[!] 上一版 lingqu 仍在运行，先结束它以释放产物"
      pkill -x main >/dev/null 2>&1 || true
      sleep 1
    }
  fi
  run_capture "$APPDIR" cjpm build
  WARN="$(count_pattern '^[[:space:]]*warning:')"
  if [ "$CODE" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    pass "targets/desktop cjpm build（0 warning）"
    RESULTS+=("build-app:PASS")
  else
    fail "targets/desktop cjpm build exit=$CODE warnings=$WARN"
    printf '%s\n' "$TEXT"
    RESULTS+=("build-app:FAIL")
  fi
fi

# ---------- ⑤ CLI 入口构建（给 agent 的 bash 用）----------
info "[5/5] CLI 入口 cjpm build（cli/，AI 接入第 3 步）..."
CLIDIR="$ROOT/cli"
if [ ! -d "$CLIDIR" ]; then
  fail "CLI 目标不存在：$CLIDIR"
  RESULTS+=("build-cli:FAIL")
else
  if [ "$OS" = "windows" ]; then
    if tasklist 2>/dev/null | grep -qi '^main\.exe'; then
      warn "[!] 上一版 main.exe 仍在运行，先结束**本仓的**那些（不碰 cjh 引擎，见 §4-92）"
      kill_own_main_exe
      sleep 1
    fi
  fi
  run_capture "$CLIDIR" cjpm build
  WARN="$(count_pattern '^[[:space:]]*warning:')"
  if [ "$CODE" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    pass "cli cjpm build（0 warning）"
    RESULTS+=("build-cli:PASS")
  else
    fail "cli cjpm build exit=$CODE warnings=$WARN"
    printf '%s\n' "$TEXT"
    RESULTS+=("build-cli:FAIL")
  fi
fi

# ---------- 汇总 ----------
say ""
if printf '%s\n' "${RESULTS[@]}" | grep -q 'FAIL'; then
  printf '\033[31m门禁未通过：%s\033[0m\n' "${RESULTS[*]}"
  printf '\033[31m修到全绿再提交（AGENTS.md §1）\033[0m\n'
  exit 1
fi
printf '\033[32m门禁全绿：%s\033[0m\n' "${RESULTS[*]}"
printf '\033[32m别忘了同步 CHANGELOG.md 与 docs/进度记录.md（AGENTS.md §5）\033[0m\n'
exit 0
