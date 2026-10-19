<#
.SYNOPSIS
  组装一个可独立运行的内嵌 Python 运行时（含 Scan-Relay 服务端与托盘的全部依赖）。

.DESCRIPTION
  产物是 dist\standalone\python\：
      python\python.exe, pythonw.exe   内嵌解释器（GUI 子系统版给托盘用，不弹控制台）
      python\site-packages\            依赖，全部由 pip 装好
      python\python315._pth            已把 site-packages 写进 sys.path

  两个刻意的设计选择：

  1. **用 pip 的 --target 交叉安装，而不是自己解压 wheel。**
     pip 会正确处理 wheel 里 `*.data/purelib|platlib` 这类需要重映射的目录；
     手工 Expand-Archive 会把它们原样倒进 site-packages，装出来的包是坏的，
     而且坏得不明显 —— 通常要到运行时才炸。多花几秒换掉一个隐蔽故障，值。

  2. **钉死版本 + 只用 wheel，不用源码包。**
     目标解释器是另一个版本（--python-version 3.15），pip 无法在本机编译扩展，
     一旦某个包只有 sdist 就会失败。所以 --only-binary=:all:，缺 wheel 立刻暴露，
     而不是回退到编译再产出一个 ABI 不匹配的二进制。

.PARAMETER PyVersion
  要内嵌的 Python 版本。默认 3.15.0 —— 与开发机一致，依赖的 cp315 wheel 已验证齐全。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File packaging\fetch-python.ps1
#>
[CmdletBinding()]
param(
    [string]$PyVersion = "3.15.0",
    [string]$Stage,
    [string]$Cache
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# 注意：这里**不能**写成 param() 默认值里的 (Join-Path $PSScriptRoot ...)。
# PowerShell 5.1 在带 [CmdletBinding()] 的脚本里，会在 $PSScriptRoot 就绪**之前**
# 求值参数默认表达式，于是拿到空字符串，Join-Path 当场报
# 「Path 参数不能为 Null 或空」。同名变量在脚本主体里才是正确的，所以推迟到这里取值。
$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $Stage) { $Stage = Join-Path $scriptDir "..\dist\standalone" }
if (-not $Cache) { $Cache = Join-Path $scriptDir ".cache" }

$parts = $PyVersion.Split(".")
$minor = "{0}.{1}" -f $parts[0], $parts[1]          # 3.15，给 pip 的 --python-version
$pthName = "python{0}{1}.zip" -f $parts[0], $parts[1]

$Stage = [System.IO.Path]::GetFullPath($Stage)
$Cache = [System.IO.Path]::GetFullPath($Cache)
$pyDir   = Join-Path $Stage "python"
$siteDir = Join-Path $pyDir  "site-packages"

New-Item -ItemType Directory -Force -Path $Stage, $Cache | Out-Null

# --------------------------------------------------------------- 1) 下载内嵌包
$zipUrl  = "https://www.python.org/ftp/python/$PyVersion/python-$PyVersion-embed-amd64.zip"
$zipPath = Join-Path $Cache ("python-$PyVersion-embed-amd64.zip")

if (Test-Path $zipPath) {
    Write-Host "[1/5] 内嵌包命中缓存: $(Split-Path $zipPath -Leaf)"
}
else {
    Write-Host "[1/5] 下载 $zipUrl"
    & curl.exe -fSL --retry 3 --retry-delay 2 --silent --show-error -o $zipPath $zipUrl
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $zipPath)) {
        throw "下载内嵌 Python 失败（HTTP $LASTEXITCODE）"
    }
}

# --------------------------------------------------------------- 2) 解压
if (Test-Path $pyDir) { Remove-Item $pyDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $pyDir | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $pyDir)

$pyExe = Join-Path $pyDir "python.exe"
if (-not (Test-Path $pyExe)) { throw "内嵌 python.exe 未生成: $pyExe" }
Write-Host "[2/5] 已解压 -> $pyDir"

# --------------------------------------------------------------- 3) 装依赖
$reqFile = Join-Path $PSScriptRoot "requirements-bundle.txt"
if (-not (Test-Path $reqFile)) { throw "缺少 $reqFile" }

Write-Host "[3/5] 交叉安装依赖（target=$minor / win_amd64 / 仅 wheel）"
New-Item -ItemType Directory -Force -Path $siteDir | Out-Null

# --target + --python-version 是 pip 官方支持的跨解释器安装方式；
# 它会代劳 wheel 内部目录的重映射，这是不手工解压 wheel 的根本原因。
& python -m pip install `
    --requirement $reqFile `
    --target $siteDir `
    --only-binary=:all: `
    --python-version $minor `
    --implementation cp `
    --platform win_amd64 `
    --cache-dir (Join-Path $Cache "pipcache") `
    --no-warn-script-location `
    --disable-pip-version-check `
    --quiet
if ($LASTEXITCODE -ne 0) {
    throw "依赖安装失败（缺 wheel 或版本冲突，见上方 pip 输出）"
}

# --------------------------------------------------------------- 4) 打开 sys.path
$pthFile = Get-ChildItem $pyDir -Filter "python*._pth" | Select-Object -First 1
if (-not $pthFile) { throw "找不到 python*_._pth（内嵌包结构变了？）" }

# _pth 一旦存在就**完全接管** sys.path：site 机制被跳过，site-packages 里的
# .pth 也不会被处理。所以不能写 `import site` 了事，必须把目录显式列进去。
# 相对路径按 _pth 所在目录解析，`.` 即 python 目录本身。
$lines = [System.IO.File]::ReadAllLines($pthFile.FullName)
$zipLine = $lines | Where-Object { $_ -like "*.zip" } | Select-Object -First 1
if (-not $zipLine) { $zipLine = $pthName }     # 兜底，不应发生

[System.IO.File]::WriteAllText($pthFile.FullName, (($zipLine, ".", "site-packages") -join "`n") + "`n")
Write-Host "[4/5] $($pthFile.Name) 已启用 site-packages"

# --------------------------------------------------------------- 5) 自检
Write-Host "[5/5] 内嵌运行时自检"
& $pyExe (Join-Path $PSScriptRoot "smoke.py")
if ($LASTEXITCODE -ne 0) { throw "内嵌运行时自检失败" }

$mb = "{0:N1}" -f ((Get-ChildItem $pyDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB)
Write-Host ""
Write-Host "OK  内嵌运行时就绪 ($mb MB): $pyDir" -ForegroundColor Green
