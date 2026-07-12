<#
.SYNOPSIS
    验证并上传本次 Windows 构建产物到固定 Google Drive 文件夹。

.DESCRIPTION
    - 只接受按 package.json 版本计算出的确切 ZIP，不再按修改时间猜测历史产物。
    - 验证路径、生成时间、ZIP 内的 subtle.exe、文件大小与 SHA-256。
    - 使用 runner 常驻的 rclone OAuth 配置上传，并读回远端大小。
#>
[CmdletBinding()]
param(
    [string]$Remote = 'gdrive',
    [string]$ArtifactPath = $env:BUILD_ARTIFACT_PATH,
    [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Path $PSCommandPath -Parent
$repoRoot = if ($SourceRoot) {
    [IO.Path]::GetFullPath($SourceRoot)
} else {
    Split-Path -Path $scriptDir -Parent
}
if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) {
    throw "源码根目录不存在：$repoRoot"
}

function Resolve-RcloneExecutable {
    if ($env:RCLONE_EXE) {
        if (-not (Test-Path -LiteralPath $env:RCLONE_EXE -PathType Leaf)) {
            throw "RCLONE_EXE 指向的文件不存在：$env:RCLONE_EXE"
        }
        return (Resolve-Path -LiteralPath $env:RCLONE_EXE).Path
    }

    $command = Get-Command rclone -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $runnerCopy = 'C:\subtle-ci\rclone.exe'
    if (Test-Path -LiteralPath $runnerCopy -PathType Leaf) {
        return $runnerCopy
    }

    throw "rclone 未安装或不可用。请安装 rclone，或设置 RCLONE_EXE（详见 ci/README.md）。"
}

# rclone/Go 不自动读取 WinINET 代理；未显式传入代理时，沿用当前 Windows 用户设置。
if (-not $env:HTTPS_PROXY) {
    try {
        $internet = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($internet.ProxyEnable -and $internet.ProxyServer) {
            $proxy = [string]$internet.ProxyServer
            if ($proxy.Contains(';')) {
                $entries = @{}
                foreach ($item in $proxy.Split(';')) {
                    $parts = $item.Split('=', 2)
                    if ($parts.Count -eq 2) { $entries[$parts[0].ToLowerInvariant()] = $parts[1] }
                }
                $proxy = if ($entries.ContainsKey('https')) { $entries['https'] }
                         elseif ($entries.ContainsKey('http')) { $entries['http'] }
                         else { $null }
            }
            if ($proxy) {
                if ($proxy -notmatch '^https?://') { $proxy = "http://$proxy" }
                $env:HTTP_PROXY = $proxy
                $env:HTTPS_PROXY = $proxy
                if (-not $env:NO_PROXY) { $env:NO_PROXY = '127.0.0.1,localhost' }
                Write-Host '已沿用 Windows 当前用户的系统代理。' -ForegroundColor DarkGray
            }
        }
    } catch {
        Write-Verbose "读取 Windows 系统代理失败：$_"
    }
}

$rcloneExe = Resolve-RcloneExecutable
$rcloneConf = if ($env:RCLONE_CONFIG) { $env:RCLONE_CONFIG } else { Join-Path $scriptDir 'rclone.conf' }
if (-not (Test-Path -LiteralPath $rcloneConf -PathType Leaf)) {
    throw "找不到 rclone 配置：$rcloneConf。请先按 ci/README.md 完成 OAuth。"
}
$env:RCLONE_CONFIG = $rcloneConf

$folderId = $env:GDRIVE_FOLDER_ID
if (-not $folderId) {
    $envFile = Join-Path $scriptDir 'ci.env'
    if (Test-Path -LiteralPath $envFile) {
        foreach ($line in Get-Content -LiteralPath $envFile) {
            if ($line -match '^\s*GDRIVE_FOLDER_ID\s*=\s*(.+?)\s*$') {
                $folderId = $Matches[1].Trim().Trim('"').Trim("'")
                break
            }
        }
    }
}
if (-not $folderId) {
    throw '缺少 GDRIVE_FOLDER_ID（My Drive 目标文件夹 ID）。'
}
if ($folderId -notmatch '^[A-Za-z0-9_-]+$') {
    throw 'GDRIVE_FOLDER_ID 格式非法。'
}

$releaseRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'src-tauri\target\release'))
$version = (Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'package.json') | ConvertFrom-Json).version
if ($version -notmatch '^[0-9A-Za-z][0-9A-Za-z.+-]{0,63}$') {
    throw "package.json version 格式非法：$version"
}
$expectedArtifactName = "subtle $version windows x64.zip"
if (-not $ArtifactPath) {
    $ArtifactPath = Join-Path $releaseRoot $expectedArtifactName
}

$artifactFullPath = [IO.Path]::GetFullPath($ArtifactPath)
$releasePrefix = $releaseRoot.TrimEnd('\') + '\'
if (-not $artifactFullPath.StartsWith($releasePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "拒绝上传 release 目录之外的文件：$artifactFullPath"
}
if ([IO.Path]::GetFileName($artifactFullPath) -cne $expectedArtifactName) {
    throw "产物文件名必须与 package.json 版本严格匹配：$expectedArtifactName"
}
if (-not (Test-Path -LiteralPath $artifactFullPath -PathType Leaf)) {
    throw "本次构建产物不存在：$artifactFullPath"
}

$zip = Get-Item -LiteralPath $artifactFullPath
if ($zip.Extension -ne '.zip' -or $zip.Length -le 0) {
    throw "构建产物不是有效的非空 ZIP：$artifactFullPath"
}

if ($env:BUILD_STARTED_UTC) {
    $started = [DateTime]::MinValue
    $parsed = [DateTime]::TryParse(
        $env:BUILD_STARTED_UTC,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$started
    )
    if (-not $parsed) { throw "BUILD_STARTED_UTC 格式非法：$env:BUILD_STARTED_UTC" }
    if ($zip.LastWriteTimeUtc -lt $started.ToUniversalTime().AddSeconds(-2)) {
        throw "ZIP 早于本次构建开始时间，拒绝上传陈旧产物：$($zip.LastWriteTimeUtc.ToString('o'))"
    }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zip.FullName)
try {
    $exeEntries = @($archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -eq 'subtle.exe' })
    if ($exeEntries.Count -ne 1 -or $exeEntries[0].Length -le 0) {
        throw 'ZIP 必须且只能包含一个非空 subtle.exe。'
    }
} finally {
    $archive.Dispose()
}

$sha256 = (Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$md5 = (Get-FileHash -LiteralPath $zip.FullName -Algorithm MD5).Hash.ToLowerInvariant()
$sourceSha = if ($env:UPSTREAM_SHA -and $env:UPSTREAM_SHA -match '^[0-9a-fA-F]{12,40}$') {
    $env:UPSTREAM_SHA.Substring(0, 12).ToLowerInvariant()
} else {
    'local'
}
$buildKey = if ($env:CONTROLLER_SHA -and $env:CONTROLLER_SHA -match '^[0-9a-fA-F]{7,40}$') {
    "{0}-ci{1}" -f $sourceSha, $env:CONTROLLER_SHA.Substring(0, 7).ToLowerInvariant()
} else {
    $sourceSha
}
$destName = "{0} {1}{2}" -f $zip.BaseName, $buildKey, $zip.Extension

Write-Host "上传已验证产物：$($zip.Name)（$($zip.Length) bytes）" -ForegroundColor Cyan
& $rcloneExe copyto $zip.FullName "${Remote}:$destName" `
    --drive-root-folder-id=$folderId `
    --immutable `
    --stats-one-line
if ($LASTEXITCODE -ne 0) {
    throw "rclone 上传失败（exit $LASTEXITCODE）。"
}

$remoteJson = & $rcloneExe lsjson "${Remote}:$destName" --drive-root-folder-id=$folderId --stat --hash --hash-type MD5
if ($LASTEXITCODE -ne 0 -or -not $remoteJson) {
    throw '无法读回刚上传的远端文件。'
}
$remoteStat = ($remoteJson | Out-String | ConvertFrom-Json)
if ([int64]$remoteStat.Size -ne [int64]$zip.Length) {
    throw "远端大小校验失败：local=$($zip.Length), remote=$($remoteStat.Size)"
}
$remoteMd5 = [string]$remoteStat.Hashes.md5
if (-not $remoteMd5 -or $remoteMd5.ToLowerInvariant() -ne $md5) {
    throw "远端 MD5 校验失败：local=$md5, remote=$remoteMd5"
}

$folderLink = "https://drive.google.com/drive/folders/$folderId"
Write-Host "已上传并读回验证：$destName" -ForegroundColor Green
Write-Host "共享文件夹：$folderLink" -ForegroundColor Green
Write-Host "SHA-256：$sha256" -ForegroundColor Green

if ($env:GITHUB_STEP_SUMMARY) {
    @(
        '## 构建产物已上传并验证',
        '',
        "- 文件：``$destName``",
        "- 大小：``$($zip.Length) bytes``",
        "- SHA-256：``$sha256``",
        "- [打开下载文件夹]($folderLink)"
    ) -join "`n" | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
}

exit 0
