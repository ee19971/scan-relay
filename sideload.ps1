# Scan-Relay add-in one-click sideload (Windows desktop Excel)
# Scan-Relay 加载项一键侧载
#
# Usage / 用法：
#   .\sideload.ps1                    # default: copy manifest to C:\ScanRelay and register
#   .\sideload.ps1 -ShareDir D:\Apps  # custom shared dir
#
# Excel sideload uses the Trusted Add-in Catalogs registry key. The Url value must
# point at the UNC shared FOLDER (not the manifest file). Restart Excel fully afterwards.
# 参见 README「Excel 侧载的历史坑」。

param(
    [string]$ShareDir = "C:\ScanRelay",
    [string]$Manifest = (Join-Path $PSScriptRoot "addin\manifest.xml")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Manifest)) {
    Write-Host "[error] manifest not found: $Manifest" -ForegroundColor Red
    exit 1
}

# Fixed GUID = the catalog already active on this machine; re-running only updates it.
# 固定 GUID：与本机已生效目录一致，重复运行只更新同一条，不会越积越多
$catalogGuid = "{43d8e154-b154-47b6-b16e-2188d640be71}"

# 1) copy manifest / 复制 manifest 到共享目录
if (-not (Test-Path $ShareDir)) { New-Item -ItemType Directory -Path $ShareDir | Out-Null }
Copy-Item $Manifest (Join-Path $ShareDir "manifest.xml") -Force
Write-Host "[1/3] manifest copied to $ShareDir / 已复制" -ForegroundColor Green

# 2) UNC via admin share \\localhost\C$\... (readable by current user, no extra share setup)
#    UNC 走管理共享，免去新建共享+授权
$drive = (Split-Path $ShareDir -Qualifier).TrimEnd(":")   # "C"
$rest  = $ShareDir.Substring(3) -replace "/", "\"          # "ScanRelay"
$unc   = '\\localhost\{0}$\{1}' -f $drive, $rest
Write-Host "[2/3] UNC: $unc"

# 3) write registry TrustedCatalogs (HKCU, no admin needed) / 写注册表（无需管理员）
$regPath = "HKCU:\Software\Microsoft\Office\16.0\Wef\TrustedCatalogs\$catalogGuid"
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
New-ItemProperty -Path $regPath -Name "Id"    -Value $catalogGuid -PropertyType String -Force | Out-Null
New-ItemProperty -Path $regPath -Name "Url"   -Value $unc         -PropertyType String -Force | Out-Null
New-ItemProperty -Path $regPath -Name "Flags" -Value 1            -PropertyType DWord  -Force | Out-Null
Write-Host "[3/3] registry written: $regPath" -ForegroundColor Green

Write-Host ""
Write-Host "Done. Fully quit Excel (incl. background) then reopen:" -ForegroundColor Cyan
Write-Host "  File -> Get Add-ins -> My Add-ins -> Scan-Relay" -ForegroundColor Cyan
Write-Host "If missing, tick 'Shared folder' / 勾选「来自我的计算机的共享文件夹」." -ForegroundColor Cyan
