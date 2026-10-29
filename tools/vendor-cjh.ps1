# 把 cjh 产物灌入 vendor/cjh/win-x64/，并重算 SHA256SUMS
#
# 用法：
#   .\tools\vendor-cjh.ps1 -Source "E:\test\rust\test1\cjh"
#   .\tools\vendor-cjh.ps1 -Source "<cjh 构建输出>" -Version "v1.5.4"
#
# Source 目录里必须有：cjh.exe / libcangjie-runtime.dll / libssl-3-x64.dll / libcrypto-3-x64.dll

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Version = "v1.5.3"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$dst  = Join-Path $root "vendor\cjh\win-x64"
$need = @("cjh.exe", "libcangjie-runtime.dll", "libssl-3-x64.dll", "libcrypto-3-x64.dll")

if (-not (Test-Path $Source)) { Write-Host "[x] 源目录不存在：$Source" -ForegroundColor Red; exit 1 }
$missing = $need | Where-Object { -not (Test-Path (Join-Path $Source $_)) }
if ($missing) {
    Write-Host "[x] 源目录缺文件：$($missing -join ', ')" -ForegroundColor Red
    Write-Host "    提示：cjh 的 Windows 产物是「exe + 3 个同目录 DLL」，不是单文件。" -ForegroundColor Yellow
    exit 1
}

New-Item -ItemType Directory -Force -Path $dst | Out-Null
foreach ($n in $need) { Copy-Item (Join-Path $Source $n) (Join-Path $dst $n) -Force }

$lines = Get-ChildItem $dst | Where-Object { $_.Name -ne "SHA256SUMS" } | ForEach-Object {
    "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name
}
Set-Content -Path (Join-Path $root "vendor\cjh\SHA256SUMS") -Value $lines -Encoding ASCII

$mb = '{0:N1}' -f ((Get-ChildItem $dst | Measure-Object Length -Sum).Sum / 1MB)
Write-Host "[ok] 已灌入 $dst（$mb MB，版本 $Version）" -ForegroundColor Green
Write-Host "[ok] SHA256SUMS 已重算" -ForegroundColor Green
