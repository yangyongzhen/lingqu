# 灵渠迁移台 · 开发运行脚本（Windows）
#
# 为什么需要它：直接双击 main.exe 会连挂 5 次，每次报错都不一样，而且都不像「环境变量没配」。
# 这个脚本把这 5 个前提一次性配好：
#   ① 工作目录必须是工程根（launcher 用相对路径找 assets/ui/index.html 与 assets/capabilities）
#   ② PATH 要有仓颉运行时目录（libcangjie-runtime.dll / libboundscheck.dll）
#   ③ PATH 要有 stdx 动态目录（libstdx.encoding.json.dll）
#   ④ PATH 要有框架 native 目录（libcjtbridge.dll）
#   ⑤ exe 旁边要有 WebView2Loader.dll
# 外加把 WEBVIEW2_USER_DATA_FOLDER 指到仓内（避免 %LOCALAPPDATA% 被占用/不可写时 0x800700AA）。
#
# 用法：
#   .\scripts\run-dev.ps1                 # 直接跑已构建产物
#   .\scripts\run-dev.ps1 -Build          # 先 cjpm build 再跑
#   .\scripts\run-dev.ps1 -Build -Cjh     # 先构建，再把内置 cjh 引擎一起拉起来

[CmdletBinding()]
param(
    [switch]$Build,
    [switch]$Cjh,
    [string]$CangjieHome = "D:\Program Files (x86)\Cangjie",
    [string]$Stdx        = "D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx",
    [string]$CjTauriRoot = "E:\test\harmonyos\test\cj-tauri",
    [string]$CjhPath     = "E:\test\rust\test1\cjh\cjh.exe"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$bin  = Join-Path $root "targets\desktop\target\release\bin"
$exe  = Join-Path $bin "main.exe"

function Say([string]$m, [string]$c = "Gray") { Write-Host $m -ForegroundColor $c }
function Die([string]$m) { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

# ---------- ① 构建（可选） ----------
if ($Build) {
    Say "[1/4] cjpm build（targets/desktop）..." Cyan
    $env:CANGJIE_HOME = $CangjieHome
    $env:CANGJIE_STDX = $Stdx
    $env:PATH = "$CangjieHome\runtime\lib\windows_x86_64_cjnative;$CangjieHome\bin;$CangjieHome\tools\bin;$CangjieHome\tools\lib;$Stdx;" + $env:PATH
    Push-Location (Join-Path $root "targets\desktop")
    try { cjpm build; if ($LASTEXITCODE -ne 0) { throw "cjpm build 失败" } } finally { Pop-Location }
    Say "      构建通过" Green
}

if (-not (Test-Path $exe)) { Die "找不到 $exe —— 先跑 .\scripts\run-dev.ps1 -Build" }

# ---------- ② PATH：运行时 / stdx / C 桥 ----------
Say "[2/4] 组装 PATH..." Cyan
foreach ($p in @($CangjieHome, $Stdx, (Join-Path $CjTauriRoot "native"))) {
    if (-not (Test-Path $p)) { Die "缺目录：$p（检查脚本顶部的参数）" }
}
$env:CANGJIE_HOME = $CangjieHome
$env:CANGJIE_STDX = $Stdx
$env:PATH = "$CangjieHome\runtime\lib\windows_x86_64_cjnative;$Stdx;$(Join-Path $CjTauriRoot 'native');$bin;" + $env:PATH
Say "      运行时 + stdx + libcjtbridge 已就位" Green

# ---------- ③ WebView2Loader.dll ----------
Say "[3/4] 检查 WebView2Loader.dll..." Cyan
$wv = Join-Path $bin "WebView2Loader.dll"
if (-not (Test-Path $wv)) {
    $cands = @()
    $cands += Get-ChildItem (Join-Path $CjTauriRoot "examples") -Recurse -Filter "WebView2Loader.dll" -ErrorAction SilentlyContinue |
              Select-Object -ExpandProperty FullName
    $cands += (Join-Path $CjTauriRoot "native\WebView2Loader.dll")
    $src = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $src) {
        Die "找不到 WebView2Loader.dll。二选一：从 NuGet 取 Microsoft.Web.WebView2 的 runtimes/win-x64/native/ 那份，或从框架仓任一 examples\*\target\release\bin\ 里拷一份放到 $bin"
    }
    Copy-Item $src $wv -Force
    Say "      已从 $src 拷贝" Green
} else {
    Say "      已存在" Green
}

# ---------- ④ WebView2 用户数据目录 + 启动 ----------
$env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $root ".wv2data"
New-Item -ItemType Directory -Force -Path $env:WEBVIEW2_USER_DATA_FOLDER | Out-Null

if ($Cjh) {
    Say "[4/4] 拉起内置 cjh 引擎..." Cyan
    if (-not (Test-Path $CjhPath)) { Die "找不到 cjh：$CjhPath（用 -CjhPath 指定）" }
    Start-Process -FilePath $CjhPath -ArgumentList @("web", "--port", "8765", "--bind", "127.0.0.1") -WindowStyle Hidden
    Start-Sleep -Seconds 2
    Say "      cjh 已拉起（8765）" Green
} else {
    Say "[4/4] 启动工作台（不自动拉 cjh，界面里点『启动引擎』）..." Cyan
}

# 注意：工作目录必须是工程根，否则页面与能力清单都找不到
Push-Location $root
try {
    Say ""
    Say "  工作目录 : $root" DarkGray
    Say "  WebView2 : $env:WEBVIEW2_USER_DATA_FOLDER" DarkGray
    Say "  关闭窗口即退出" DarkGray
    Say ""
    & $exe
} finally { Pop-Location }
