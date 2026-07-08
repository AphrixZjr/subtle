<#
.SYNOPSIS
    将 Windows 构建产物上传到 Google Drive 的固定文件夹（rclone + OAuth 用户令牌 → 个人 My Drive）。

.DESCRIPTION
    - 定位 build-windows.ps1 / windows-repack-test.ps1 产出的 zip（src-tauri\target\release\subtle *windows x64.zip）。
    - 用命名 remote 'gdrive'（在 rclone.conf 里，含 OAuth refresh token）上传到目标文件夹。
    - 目标文件名带上游短 SHA，保留历史版本；对外稳定链接是该文件夹的共享链接。
    - CI 中由 workflow 提供 RCLONE_CONFIG / GDRIVE_FOLDER_ID / UPSTREAM_SHA 环境变量；
      本地手动运行时回退读取 ci\rclone.conf 与 ci\ci.env。

.NOTES
    需先安装 rclone 并完成 OAuth 授权（见 ci\README.md）。
#>
[CmdletBinding()]
param(
    [string]$Remote = 'gdrive'
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Path $PSCommandPath -Parent
$repoRoot  = Split-Path -Path $scriptDir -Parent

# --- 1) rclone 存在性 -------------------------------------------------------
if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    throw "rclone 未安装或不在 PATH。安装：winget install Rclone.Rclone（详见 ci/README.md）。"
}

# --- 2) rclone 配置：优先 $env:RCLONE_CONFIG（runner 常驻），否则回退 ci\rclone.conf ---
$rcloneConf = if ($env:RCLONE_CONFIG) { $env:RCLONE_CONFIG } else { Join-Path $scriptDir 'rclone.conf' }
if (-not (Test-Path $rcloneConf)) {
    throw "找不到 rclone 配置：$rcloneConf。请先按 ci/README.md 用 'rclone config' 完成 OAuth 授权。"
}
$env:RCLONE_CONFIG = $rcloneConf
Write-Host "使用 rclone 配置：$rcloneConf" -ForegroundColor Green

# --- 目标文件夹 ID：优先环境变量，否则从 ci\ci.env 解析 ----------------------
$folderId = $env:GDRIVE_FOLDER_ID
if (-not $folderId) {
    $envFile = Join-Path $scriptDir 'ci.env'
    if (Test-Path $envFile) {
        foreach ($line in Get-Content $envFile) {
            if ($line -match '^\s*GDRIVE_FOLDER_ID\s*=\s*(.+?)\s*$') {
                $folderId = $Matches[1].Trim().Trim('"').Trim("'")
                break
            }
        }
    }
}
if (-not $folderId) {
    throw "缺少 GDRIVE_FOLDER_ID（My Drive 目标文件夹 ID）。设为 Actions Variable 或写入 ci/ci.env。"
}

# --- 3) 定位构建产物 zip ----------------------------------------------------
$relDir = Join-Path $repoRoot 'src-tauri\target\release'
if (-not (Test-Path $relDir)) {
    throw "构建输出目录不存在：$relDir。请先运行 build-windows-local.ps1。"
}
$zip = Get-ChildItem -Path $relDir -Filter 'subtle *windows x64.zip' -File -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $zip) {
    throw "未找到构建产物 zip（subtle *windows x64.zip）于 $relDir。构建或 repack 可能失败。"
}
Write-Host "找到产物：$($zip.Name)" -ForegroundColor Green

# --- 4) 目标文件名：带上游短 SHA（保留历史；稳定链接靠文件夹） ---------------
$sha = if ($env:UPSTREAM_SHA -and $env:UPSTREAM_SHA.Length -ge 7) { $env:UPSTREAM_SHA.Substring(0, 7) } else { 'local' }
$destName = "{0} {1}{2}" -f $zip.BaseName, $sha, $zip.Extension

# --- 5) 上传 ---------------------------------------------------------------
Write-Host "上传到 remote '$Remote' 文件夹 $folderId 作为：$destName" -ForegroundColor Cyan
& rclone copyto "$($zip.FullName)" "${Remote}:$destName" `
    --drive-root-folder-id=$folderId `
    --progress --stats-one-line
if ($LASTEXITCODE -ne 0) {
    throw "rclone 上传失败（exit $LASTEXITCODE）。检查授权与网络（rclone config reconnect ${Remote}:）。"
}

# --- 6) 输出稳定文件夹链接 --------------------------------------------------
$folderLink = "https://drive.google.com/drive/folders/$folderId"
Write-Host "已上传：$destName" -ForegroundColor Green
Write-Host "共享文件夹链接（稳定）：$folderLink" -ForegroundColor Green

if ($env:GITHUB_STEP_SUMMARY) {
    @(
        "## 构建产物已上传",
        "",
        "- 文件：``$destName``",
        "- [打开下载文件夹]($folderLink)"
    ) -join "`n" | Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8
}

exit 0
