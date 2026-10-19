<#
.SYNOPSIS
  一键产出 Scan-Relay-Setup-<版本>.exe，并放到桌面供手动上传到 Gitee/GitHub Release。

.DESCRIPTION
  五步：
    1. npm run build           构建加载项 -> addin\dist
    2. fetch-python.ps1        组装内嵌 Python 运行时 -> dist\standalone\python
    3. 生成 icon.ico 与 install-notes.txt -> dist\standalone\assets
    4. ISCC.exe 编译 scan-relay.iss -> dist\Scan-Relay-Setup-<版本>.exe
    5. 校验产物并复制到桌面

  环境前提：node/npm、Python(含 Pillow)、Inno Setup 6.3+。
  缺 Inno 时本脚本会给出提示；注意官方安装包现在只发布在 GitHub Releases，
  直连不可达的网络需要用镜像代理下载，**下载后务必验签再执行**：
      signtool verify /pa /v innosetup-x.y.z.exe
  签名通过后：
      innosetup-x.y.z.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-

.PARAMETER Version
  会同时决定输出文件名与 Inno 脚本里的 AppVersion。默认 1.3.0。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File packaging\build-release.ps1
#>
[CmdletBinding()]
param(
    [string]$Version = "1.3.0",
    [switch]$SkipAddinBuild,
    [switch]$SkipPythonBundle,
    [switch]$NoDesktopCopy
)

$ErrorActionPreference = "Stop"
$repo  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$stage = Join-Path $repo "dist\standalone"
$assets = Join-Path $stage "assets"

function Step([int]$n, [string]$msg) {
    Write-Host ""
    Write-Host ("[{0}/5] {1}" -f $n, $msg) -ForegroundColor Cyan
}

function Find-Iscc {
    $cands = @()
    if ($env:ISCC) { $cands += $env:ISCC }
    $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($cmd) { $cands += $cmd.Source }
    $cands += @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 7\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 7\ISCC.exe"
    )
    foreach ($c in $cands) {
        if ($c -and (Test-Path $c)) { return (Get-Item $c).FullName }
    }
    return $null
}

# ---------------------------------------------------------------- 1) 加载项
if ($SkipAddinBuild) {
    Step 1 "构建加载项（已跳过，-SkipAddinBuild）"
    if (-not (Test-Path (Join-Path $repo "addin\dist\taskpane.html"))) {
        throw "addin\dist 不存在。先不带 -SkipAddinBuild 跑一次。"
    }
}
else {
    Step 1 "构建加载项 -> addin\dist"
    Push-Location (Join-Path $repo "addin")
    try {
        if (-not (Test-Path "node_modules")) { npm install --no-audit --no-fund }
        npm run build
        if ($LASTEXITCODE -ne 0) { throw "npm run build 失败" }
    }
    finally { Pop-Location }
}
if (-not (Test-Path (Join-Path $repo "addin\dist\taskpane.html"))) {
    throw "构建产物缺失：addin\dist\taskpane.html"
}
Write-Host ("  OK  {0} 个文件" -f (Get-ChildItem (Join-Path $repo "addin\dist") -Recurse -File).Count)

# ---------------------------------------------------------------- 2) 运行时
if ($SkipPythonBundle) {
    Step 2 "内嵌运行时（已跳过，-SkipPythonBundle）"
    if (-not (Test-Path (Join-Path $stage "python\python.exe"))) {
        throw "dist\standalone\python 不存在。先不带 -SkipPythonBundle 跑一次。"
    }
}
else {
    Step 2 "组装内嵌 Python 运行时"
    & (Join-Path $PSScriptRoot "fetch-python.ps1")
}

# ---------------------------------------------------------------- 3) 图标与说明
Step 3 "生成 icon.ico 与 install-notes.txt"
New-Item -ItemType Directory -Force -Path $assets | Out-Null
& python (Join-Path $PSScriptRoot "make-ico.py") (Join-Path $assets "icon.ico")
if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $assets "icon.ico"))) {
    throw "生成 icon.ico 失败（需要 Pillow）"
}
Copy-Item (Join-Path $PSScriptRoot "install-notes.txt") (Join-Path $assets "install-notes.txt") -Force

# ---------------------------------------------------------------- 4) 编译安装包
Step 4 "编译安装包"
$iscc = Find-Iscc
if (-not $iscc) {
    throw @"
找不到 ISCC.exe（Inno Setup 6.3+）。

安装方式（官方安装包现只发布在 GitHub Releases）：
  winget install --id JRSoftware.InnoSetup
直连 GitHub 不可达时，用镜像代理下载后**必须验签再执行**：
  signtool verify /pa /v innosetup-x.y.z.exe
  innosetup-x.y.z.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-
也可设置环境变量 ISCC 指向 ISCC.exe 路径。
"@
}
$isccVer = (Get-Item $iscc).VersionInfo.ProductVersion
Write-Host "  ISCC $isccVer  ($iscc)"

# OutputDir 在 .iss 里是 ..\dist（相对 .iss 所在目录），即 <repo>\dist
$outDir = Join-Path $repo "dist"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

& $iscc "/Qp" "/DMyAppVersion=$Version" (Join-Path $PSScriptRoot "scan-relay.iss")
if ($LASTEXITCODE -ne 0) { throw "ISCC 编译失败（exit=$LASTEXITCODE）" }

$setup = Join-Path $outDir "Scan-Relay-Setup-$Version.exe"
if (-not (Test-Path $setup)) { throw "未产出 $setup" }

# ---------------------------------------------------------------- 5) 校验 + 放桌面
Step 5 "校验产物"
$sizeMB = "{0:N1}" -f ((Get-Item $setup).Length / 1MB)
Write-Host "  产物 $setup"
Write-Host "  大小 $sizeMB MB"
if (-not $NoDesktopCopy) {
    $desktop = [Environment]::GetFolderPath("Desktop")
    Copy-Item $setup $desktop -Force
    Write-Host "  已复制到 $desktop"
}

Write-Host ""
Write-Host "完成。上传前建议手动验一次安装包内容：" -ForegroundColor Green
Write-Host "  1. 双击安装包，装完**完全退出** Excel/Word/PPT 再打开" -ForegroundColor Green
Write-Host "  2. 加载项 → 我的加载项 → 共享文件夹 → Scan-Relay → 扫码录入" -ForegroundColor Green
Write-Host "  3. 桌面「Scan-Relay」双击 → 应弹「中转服务已启动」+ 通知区域出现图标" -ForegroundColor Green
Write-Host "  4. 右键图标 →「退出」应能停掉服务并撤掉图标" -ForegroundColor Green
