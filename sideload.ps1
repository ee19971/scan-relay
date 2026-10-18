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
Write-Host "[1/5] manifest copied to $ShareDir / 已复制" -ForegroundColor Green

# 2) UNC via admin share \\localhost\C$\... (readable by current user, no extra share setup)
#    UNC 走管理共享，免去新建共享+授权
$drive = (Split-Path $ShareDir -Qualifier).TrimEnd(":")   # "C"
$rest  = $ShareDir.Substring(3) -replace "/", "\"          # "ScanRelay"
$unc   = '\\localhost\{0}$\{1}' -f $drive, $rest
Write-Host "[2/5] UNC: $unc"

# 3) write registry TrustedCatalogs (HKCU, no admin needed) / 写注册表（无需管理员）
$regPath = "HKCU:\Software\Microsoft\Office\16.0\Wef\TrustedCatalogs\$catalogGuid"
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
New-ItemProperty -Path $regPath -Name "Id"    -Value $catalogGuid -PropertyType String -Force | Out-Null
New-ItemProperty -Path $regPath -Name "Url"   -Value $unc         -PropertyType String -Force | Out-Null
New-ItemProperty -Path $regPath -Name "Flags" -Value 1            -PropertyType DWord  -Force | Out-Null
Write-Host "[3/5] registry written: $regPath" -ForegroundColor Green

# 4) register scanrelay:// protocol (HKCU, no admin needed)
#    注册自定义协议，加载项里的「一键启动服务器」按钮靠它唤起 launcher.vbs
$launcher = Join-Path $PSScriptRoot "launcher.vbs"
if (-not (Test-Path $launcher)) {
    Write-Host "[4/5] launcher.vbs not found, skipping protocol registration" -ForegroundColor Yellow
} else {
    $protoPath = "HKCU:\Software\Classes\scanrelay"
    $cmdPath   = "HKCU:\Software\Classes\scanrelay\shell\open\command"
    if (-not (Test-Path $protoPath)) { New-Item -Path $protoPath -Force | Out-Null }
    New-ItemProperty -Path $protoPath -Name "(default)"    -Value "URL:Scan-Relay Launcher" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $protoPath -Name "URL Protocol" -Value ""                        -PropertyType String -Force | Out-Null
    if (-not (Test-Path $cmdPath)) { New-Item -Path $cmdPath -Force | Out-Null }
    $protoCmd = 'wscript.exe "{0}" "%1"' -f $launcher
    New-ItemProperty -Path $cmdPath -Name "(default)" -Value $protoCmd -PropertyType String -Force | Out-Null
    Write-Host "[4/5] protocol registered: scanrelay:// -> $launcher" -ForegroundColor Green
}

# 5) shortcuts: Desktop + Start Menu (NO autostart, per user choice)
#    创建桌面/开始菜单快捷方式（按需求：不写 Startup，不做开机自启）
$wsh = New-Object -ComObject WScript.Shell
$desktop  = [Environment]::GetFolderPath("Desktop")
$programs = Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs"
$shortcuts = @(
    @{ Dir = $desktop;  Name = "Scan-Relay 服务.lnk" },
    @{ Dir = $programs; Name = "Scan-Relay 服务.lnk" }
)
foreach ($s in $shortcuts) {
    if (-not (Test-Path $s.Dir)) { continue }
    $lnk = $wsh.CreateShortcut((Join-Path $s.Dir $s.Name))
    $lnk.TargetPath = "$env:SystemRoot\System32\wscript.exe"
    $lnk.Arguments  = '"{0}"' -f $launcher
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.Description = "启动 Scan-Relay 中转服务（最小化窗口，关闭即停止）"
    $lnk.Save()
}
Write-Host "[5/5] shortcuts created (Desktop + Start Menu, no autostart)" -ForegroundColor Green

Write-Host ""
Write-Host "Done. Fully quit Excel/Word/PowerPoint (incl. background) then reopen:" -ForegroundColor Cyan
Write-Host "  Home tab -> Scan-Relay group -> 扫码录入" -ForegroundColor Cyan
Write-Host "If missing, tick 'Shared folder' / 勾选「来自我的计算机的共享文件夹」." -ForegroundColor Cyan
Write-Host "Server start paths / 服务器启动方式:" -ForegroundColor Cyan
Write-Host "  - 双击「Scan-Relay 服务」快捷方式（桌面/开始菜单）" -ForegroundColor Cyan
Write-Host "  - Excel/Word/PPT 任务窗格里的「一键启动服务器」按钮" -ForegroundColor Cyan
Write-Host "  - 双击 启动Scan-Relay.bat（看控制台输出）" -ForegroundColor Cyan
