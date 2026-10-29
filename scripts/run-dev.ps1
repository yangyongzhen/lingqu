# 灵渠迁移台 · Windows 开发启动脚本
#
# 遵循框架 run_win.bat 的口径（那份脚本是踩完坑写的）：
#   运行时目录 + stdx + 框架 native + 框架 native\webview2 四段 PATH，
#   并且**必须 cd 到工程根**——launcher 用相对路径读 assets/ui 与 assets/capabilities。
#
# 用法：
#   .\scripts\run-dev.ps1                     # 跑已构建产物
#   .\scripts\run-dev.ps1 -Build              # 先 cjpm build
#   .\scripts\run-dev.ps1 -Cjh                # 顺带把 vendor 里的 cjh 引擎拉起来
#   .\scripts\run-dev.ps1 -Sync               # 先 cj-tauri sync（改了 cj-tauri.toml 之后）
#
# 需要按本机情况改的都在下面的「配置区」。
# 注意：本文件必须是「带 UTF-8 BOM」的 —— Windows PowerShell 5.1 读无 BOM 的 .ps1
#       会按 ANSI(GBK) 解码，中文注释会把字符串引号撑坏，报「数组索引表达式丢失或无效」。

[CmdletBinding()]
param(
    [switch]$Build,
    [switch]$Cjh,
    [switch]$Sync
)

$ErrorActionPreference = "Stop"

# ============================================================
# 配置区（换机器只改这里）
# ============================================================
$CangjieHome = "D:\Program Files (x86)\Cangjie"
$Stdx        = "D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx"
$CjTauriRoot = "E:\test\harmonyos\test\cj-tauri"
$CjhPort     = 8765
# ============================================================

function Say([string]$m, [string]$c = "Gray") { Write-Host $m -ForegroundColor $c }
function Die([string]$m) { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

$root = Split-Path -Parent $PSScriptRoot
$bin  = Join-Path $root "targets\desktop\target\release\bin"
$exe  = Join-Path $bin "main.exe"
$cli  = Join-Path $CjTauriRoot "cli\target\release\bin\main.exe"

# ---------- 0) 前置检查 ----------
foreach ($p in @($CangjieHome, $Stdx, (Join-Path $CjTauriRoot "native"))) {
    if (-not (Test-Path $p)) { Die "缺目录：$p（改脚本顶部配置区）" }
}
$wvDir = Join-Path $CjTauriRoot "native\webview2"
if (-not (Test-Path (Join-Path $wvDir "WebView2Loader.dll"))) {
    Die "缺 WebView2Loader.dll：$wvDir（先在框架仓跑 native\build_win.bat）"
}

$env:CANGJIE_HOME = $CangjieHome
$env:CANGJIE_STDX = $Stdx
$env:CJ_TAURI_ROOT = $CjTauriRoot
$env:PATH = "$CangjieHome\runtime\lib\windows_x86_64_cjnative;$Stdx;$(Join-Path $CjTauriRoot 'native');$wvDir;" + $env:PATH

# ---------- 1) 可选：sync ----------
if ($Sync) {
    Say "[sync] cj-tauri sync（重新派生 targets/desktop 与 targets/ohos）..." Cyan
    if (-not (Test-Path $cli)) { Die "找不到 cj-tauri CLI：$cli" }
    Push-Location $root
    try { & $cli sync; if ($LASTEXITCODE -ne 0) { throw "sync 失败" } } finally { Pop-Location }
    Say "       done" Green
}

# ---------- 2) 可选：build ----------
if ($Build) {
    Say "[build] cjpm build（targets/desktop）..." Cyan
    Push-Location (Join-Path $root "targets\desktop")
    try { cjpm build; if ($LASTEXITCODE -ne 0) { throw "cjpm build 失败" } } finally { Pop-Location }
    Say "        done" Green
}

if (-not (Test-Path $exe)) { Die "找不到 $exe —— 先跑 .\scripts\run-dev.ps1 -Build" }

# ---------- 3) 可选：拉起 cjh 引擎 ----------
$vendorCjh = Join-Path $root "vendor\cjh\win-x64\cjh.exe"
if (Test-Path $vendorCjh) { $env:LINGQU_CJH = $vendorCjh }

if ($Cjh) {
    Say "[cjh] 拉起引擎（端口 $CjhPort）..." Cyan
    if (-not (Test-Path $vendorCjh)) { Die "仓内没有 cjh：$vendorCjh（跑 tools\vendor-cjh.ps1 或放一份）" }
    $alive = $false
    try {
        $c = New-Object Net.Sockets.TcpClient
        $ok = $c.ConnectAsync("127.0.0.1", $CjhPort).Wait(400)
        if ($ok -and $c.Connected) { $alive = $true }
        $c.Close()
    } catch { }
    if ($alive) {
        Say "      端口 $CjhPort 上已有 cjh，复用（不抢你的实例）" Yellow
    } else {
        Start-Process -FilePath $vendorCjh -ArgumentList @("web", "--port", "$CjhPort", "--bind", "127.0.0.1") -WindowStyle Hidden
        Start-Sleep -Seconds 2
        Say "      已拉起" Green
    }
}

# ---------- 4) 启动（工作目录 = 工程根，这条不能少） ----------
Say "[run] $exe" Cyan
Say "      cwd: $root" DarkGray
Push-Location $root
try {
    & $exe
    Say "      exit code: $LASTEXITCODE" DarkGray
} finally { Pop-Location }
