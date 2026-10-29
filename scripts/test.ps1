# 灵渠迁移台 · 交付门禁（唯一交付凭证）
#
# 四道闸，缺一不可，任何一道红即整体失败（exit 1）：
#   ① 业务包 cjpm build  —— 零警告（cj-tauri 的硬规矩：unused/import/deprecated 一律清零）
#   ② 业务包 cjpm test    —— 单元测试全绿（FAILED=0 / ERROR=0）
#   ③ cj-tauri check     —— 清单校验 + 骨架漂移 + 能力三方比对（声明×自述×装配）
#   ④ 桌面产物 cjpm build —— 骨架侧也要编得过
#
# 用法：
#   .\scripts\test.ps1              # 全量（交付前必跑）
#   .\scripts\test.ps1 -Quick       # 只跑 ①②（改业务代码时的快速回路）
#   .\scripts\test.ps1 -Sync        # 先 cj-tauri sync 再跑（改了 cj-tauri.toml 之后）
#
# 注意：本文件必须带 UTF-8 BOM（Windows PowerShell 5.1 读无 BOM 的 .ps1 会按 GBK 解码，
# 中文注释会把字符串引号撑坏，报「数组索引表达式丢失或无效」）。

[CmdletBinding()]
param(
    [switch]$Quick,
    [switch]$Sync
)

$ErrorActionPreference = "Stop"

# ============================================================
# 配置区（换机器只改这里，与 scripts\run-dev.ps1 保持一致）
# ============================================================
$CangjieHome = "D:\Program Files (x86)\Cangjie"
$Stdx        = "D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx"
$CjTauriRoot = "E:\test\harmonyos\test\cj-tauri"
# ============================================================

function Say([string]$m, [string]$c = "Gray") { Write-Host $m -ForegroundColor $c }
function Pass([string]$m) { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Fail([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }

$root = Split-Path -Parent $PSScriptRoot
$cli  = Join-Path $CjTauriRoot "cli\target\release\bin\main.exe"
$results = @()

# ---------- 0) 环境 ----------
foreach ($p in @($CangjieHome, $Stdx, (Join-Path $CjTauriRoot "native"))) {
    if (-not (Test-Path $p)) { Write-Host "[x] 缺目录：$p（改脚本顶部配置区）" -ForegroundColor Red; exit 1 }
}
$env:CANGJIE_HOME  = $CangjieHome
$env:CANGJIE_STDX  = $Stdx
$env:CJ_TAURI_ROOT = $CjTauriRoot
$env:PATH = "$CangjieHome\runtime\lib\windows_x86_64_cjnative;$CangjieHome\bin;$CangjieHome\tools\bin;$CangjieHome\tools\lib;$Stdx;$(Join-Path $CjTauriRoot 'native');$(Join-Path $CjTauriRoot 'native\webview2');" + $env:PATH

Say "=== 灵渠交付门禁 ===" Cyan
Say "工程: $root" DarkGray

# ---------- 可选：sync ----------
if ($Sync) {
    Say "[0/4] cj-tauri sync ..." Cyan
    Push-Location $root
    try { & $cli sync; if ($LASTEXITCODE -ne 0) { throw "sync 失败" } } finally { Pop-Location }
    Pass "sync"
}

# 统计「warning:」行数：cjpm 的输出带 ANSI，先剥掉再数
function CountWarnings([string[]]$lines) {
    $clean = $lines | ForEach-Object { $_ -replace "`e\[[0-9;]*m", "" }
    return ($clean | Where-Object { $_ -match '^\s*warning:' }).Count
}

# ---------- ① 业务包构建（零警告） ----------
Say "[1/4] 业务包 cjpm build（零警告）..." Cyan
Push-Location $root
$out = cjpm build 2>&1
$buildExit = $LASTEXITCODE
Pop-Location
$warn = CountWarnings $out
if ($buildExit -eq 0 -and $warn -eq 0) {
    Pass "cjpm build（0 warning）"
    $results += "build-biz:PASS"
} else {
    Fail "cjpm build exit=$buildExit warnings=$warn"
    ($out | ForEach-Object { $_ -replace "`e\[[0-9;]*m", "" } | Where-Object { $_ -match 'error|warning:' } | Select-Object -First 15) | ForEach-Object { Write-Host "      $_" }
    $results += "build-biz:FAIL"
}

# ---------- ② 单元测试 ----------
Say "[2/4] 业务包 cjpm test ..." Cyan
Push-Location $root
$out = cjpm test 2>&1
$testExit = $LASTEXITCODE
Pop-Location
$clean = $out | ForEach-Object { $_ -replace "`e\[[0-9;]*m", "" }
$summary = ($clean | Where-Object { $_ -match '^\s*Summary: TOTAL:' } | Select-Object -Last 1)
$notGreen = ($clean | Where-Object { $_ -match 'FAILED:\s*[1-9]|ERROR:\s*[1-9]' }).Count
if ($testExit -eq 0 -and $notGreen -eq 0) {
    Pass "cjpm test（$($summary -replace '\s+',' ')）"
    $results += "test:PASS"
} else {
    Fail "cjpm test exit=$testExit（有 FAILED/ERROR）"
    ($clean | Where-Object { $_ -match 'FAILED|ERROR|error' } | Select-Object -First 15) | ForEach-Object { Write-Host "      $_" }
    $results += "test:FAIL"
}

if ($Quick) {
    Say ""
    Say "（-Quick：跳过 ③④）" DarkGray
    $failed = ($results | Where-Object { $_ -like '*FAIL' }).Count
    if ($failed -gt 0) { exit 1 } else { Say "结果：$($results -join '  ')" Green; exit 0 }
}

# ---------- ③ cj-tauri check（三方比对 + 漂移） ----------
Say "[3/4] cj-tauri check（能力三方比对 / 骨架漂移）..." Cyan
if (-not (Test-Path $cli)) { Fail "找不到 CLI：$cli"; $results += "check:FAIL" }
else {
    Push-Location $root
    $out = & $cli check 2>&1
    $checkExit = $LASTEXITCODE
    Pop-Location
    if ($checkExit -eq 0) {
        Pass "cj-tauri check"
        $results += "check:PASS"
    } else {
        Fail "cj-tauri check"
        ($out | ForEach-Object { $_ -replace "`e\[[0-9;]*m", "" }) | ForEach-Object { Write-Host "      $_" }
        $results += "check:FAIL"
    }
}

# ---------- ④ 桌面产物构建 ----------
Say "[4/4] 桌面产物 cjpm build（targets/desktop）..." Cyan
$appDir = Join-Path $root "targets\desktop"
if (-not (Test-Path $appDir)) {
    Fail "骨架不存在：$appDir（先跑 .\scripts\test.ps1 -Sync）"
    $results += "build-app:FAIL"
} else {
    # 产物被占用是最常见的假失败：上一版窗口还开着，ld.lld 报 Permission denied
    Get-Process -Name main -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$root*" } | ForEach-Object {
        Write-Host "      [!] 上一版 main.exe 仍在运行（pid=$($_.Id)），先结束它以释放产物" -ForegroundColor Yellow
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
    Push-Location $appDir
    $out = cjpm build 2>&1
    $appExit = $LASTEXITCODE
    Pop-Location
    $warn = CountWarnings $out
    if ($appExit -eq 0 -and $warn -eq 0) {
        Pass "targets/desktop cjpm build（0 warning）"
        $results += "build-app:PASS"
    } else {
        Fail "targets/desktop cjpm build exit=$appExit warnings=$warn"
        ($out | ForEach-Object { $_ -replace "`e\[[0-9;]*m", "" } | Where-Object { $_ -match 'error|warning:' } | Select-Object -First 15) | ForEach-Object { Write-Host "      $_" }
        $results += "build-app:FAIL"
    }
}

# ---------- 汇总 ----------
$failed = ($results | Where-Object { $_ -like '*FAIL' }).Count
Say ""
if ($failed -gt 0) {
    Say "门禁未通过：$($results -join '  ')" Red
    Say "修到全绿再提交（AGENTS.md §1）" Red
    exit 1
}
Say "门禁全绿：$($results -join '  ')" Green
Say "别忘了同步 CHANGELOG.md 与 docs/进度记录.md（AGENTS.md §5）" Green
exit 0
