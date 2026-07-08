<#
.SYNOPSIS
    临时包装脚本：不修改 build-windows.ps1，先让它能找到本机 MSYS2，然后调用它。

.DESCRIPTION
    build-windows.ps1 的 Find-Msys2Installation 只从注册表
    (HKCU/HKLM:\Software\msys2 的 InstallDir) 或 Scoop 布局识别 MSYS2。
    本脚本自动探测本机 MSYS2 安装目录，写入 HKCU:\Software\msys2\InstallDir，
    然后原样调用 build-windows.ps1，完成后可选择还原注册表。

.PARAMETER Msys2Path
    手动指定 MSYS2 安装根目录（该目录下应存在 msys2.exe，例如 C:\msys64）。
    不传则自动探测。

.PARAMETER KeepRegistry
    构建结束后保留写入的注册表项（默认构建后还原到执行前状态）。

.EXAMPLE
    .\build-windows-local.ps1
    .\build-windows-local.ps1 -Msys2Path 'D:\tools\msys64' -KeepRegistry
#>
[CmdletBinding()]
param(
    [string]$Msys2Path,
    [switch]$KeepRegistry
)

$ErrorActionPreference = 'Stop'

function Test-Msys2Root {
    param([string]$Path)
    return ($Path -and (Test-Path (Join-Path $Path 'msys2.exe')))
}

function Resolve-Msys2Root {
    param([string]$Explicit)

    # 1) 显式参数
    if ($Explicit) {
        if (Test-Msys2Root $Explicit) { return (Resolve-Path $Explicit).Path }
        throw "指定的 -Msys2Path '$Explicit' 下未找到 msys2.exe。"
    }

    # 2) 已有注册表项（若已可用则直接沿用）
    foreach ($rp in @('HKCU:\Software\msys2', 'HKLM:\Software\msys2')) {
        try {
            $d = (Get-ItemProperty -Path $rp -Name 'InstallDir' -ErrorAction Stop).InstallDir
            if (Test-Msys2Root $d) { return $d }
        } catch { }
    }

    # 3) 常见环境变量
    foreach ($v in @($env:MSYS2_ROOT, $env:MSYS2_PATH, $env:MSYS64_ROOT)) {
        if (Test-Msys2Root $v) { return (Resolve-Path $v).Path }
    }

    # 4) 常见安装路径
    $candidates = @(
        'C:\msys64', 'C:\msys2', 'C:\tools\msys64',
        (Join-Path $env:USERPROFILE 'scoop\apps\msys2\current'),
        (Join-Path ${env:ProgramData} 'chocolatey\lib\msys2\tools\msys64'),
        'D:\msys64', 'D:\msys2'
    )
    foreach ($c in $candidates) {
        if (Test-Msys2Root $c) { return (Resolve-Path $c).Path }
    }

    # 5) PATH 上的 msys2.exe
    $onPath = Get-Command msys2.exe -ErrorAction SilentlyContinue
    if ($onPath) {
        $root = Split-Path -Parent $onPath.Source
        if (Test-Msys2Root $root) { return $root }
    }

    return $null
}

$scriptDir  = Split-Path -Path $PSCommandPath -Parent
$buildScript = Join-Path $scriptDir 'build-windows.ps1'
if (-not (Test-Path $buildScript)) {
    throw "未找到 build-windows.ps1（期望位置：$buildScript）。"
}

$root = Resolve-Msys2Root -Explicit $Msys2Path
if (-not $root) {
    throw "未能自动定位本机 MSYS2。请用 -Msys2Path 指定安装根目录（该目录下需有 msys2.exe）。"
}
Write-Host "使用 MSYS2: $root" -ForegroundColor Green

# 记录原注册表状态以便还原
$regPath = 'HKCU:\Software\msys2'
$hadKey   = Test-Path $regPath
$oldValue = $null
if ($hadKey) {
    try { $oldValue = (Get-ItemProperty -Path $regPath -Name 'InstallDir' -ErrorAction Stop).InstallDir } catch { }
}

New-Item -Path $regPath -Force | Out-Null
Set-ItemProperty -Path $regPath -Name 'InstallDir' -Value $root
Write-Host "已写入 $regPath\InstallDir = $root" -ForegroundColor Yellow

try {
    & $buildScript
    $exitCode = $LASTEXITCODE
} finally {
    if (-not $KeepRegistry) {
        if ($hadKey) {
            if ($null -ne $oldValue) {
                Set-ItemProperty -Path $regPath -Name 'InstallDir' -Value $oldValue
            } else {
                Remove-ItemProperty -Path $regPath -Name 'InstallDir' -ErrorAction SilentlyContinue
            }
            Write-Host "已还原原有注册表项。" -ForegroundColor DarkGray
        } else {
            Remove-Item -Path $regPath -Recurse -ErrorAction SilentlyContinue
            Write-Host "已移除临时注册表项。" -ForegroundColor DarkGray
        }
    }
}

exit $exitCode
