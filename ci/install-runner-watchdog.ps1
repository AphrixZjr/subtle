[CmdletBinding()]
param(
    [string]$TaskName = 'Subtle CI Runner Watchdog',
    [string]$RunnerRoot = 'D:\actions-runner',
    [string]$InstallRoot = 'C:\subtle-ci',
    [int]$IntervalMinutes = 5
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
    throw 'Windows PowerShell 5.1 or later is required.'
}
if ($IntervalMinutes -lt 1) {
    throw 'IntervalMinutes must be at least 1.'
}

$sourceWatchdog = Join-Path $PSScriptRoot 'runner-watchdog.ps1'
$sourceRunnerEnv = Join-Path $PSScriptRoot 'runner.env.example'
$installedWatchdog = Join-Path $InstallRoot 'runner-watchdog.ps1'
$runnerEnv = Join-Path $RunnerRoot '.env'
$listenerPath = [IO.Path]::GetFullPath((Join-Path $RunnerRoot 'bin\Runner.Listener.exe'))
$runnerWasRunning = @(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -and [IO.Path]::GetFullPath($_.Path) -ieq $listenerPath } catch { $false }
}).Count -gt 0

foreach ($requiredFile in @($sourceWatchdog, $sourceRunnerEnv, (Join-Path $RunnerRoot '.runner'))) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required file is missing: $requiredFile"
    }
}

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
Copy-Item -LiteralPath $sourceWatchdog -Destination $installedWatchdog -Force
Unblock-File -LiteralPath $installedWatchdog -ErrorAction SilentlyContinue

$proxyKeyOrder = @('http_proxy', 'https_proxy', 'no_proxy')
$desiredProxyLines = @{}
foreach ($line in @(Get-Content -LiteralPath $sourceRunnerEnv)) {
    if ($line -notmatch '^\s*([^=]+?)\s*=.*$') {
        throw "Invalid runner proxy environment line: $line"
    }
    $desiredProxyLines[$Matches[1]] = $line
}

$existingRunnerEnv = if (Test-Path -LiteralPath $runnerEnv -PathType Leaf) {
    [IO.File]::ReadAllText($runnerEnv)
} else {
    ''
}
$mergedLines = New-Object System.Collections.Generic.List[string]
$writtenProxyKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($line in @($existingRunnerEnv -split '\r?\n')) {
    if ($line -match '^\s*([^#;][^=]*?)\s*=') {
        $key = $Matches[1].Trim()
        if ($proxyKeyOrder -icontains $key) {
            if ($writtenProxyKeys.Add($key)) {
                $mergedLines.Add([string]$desiredProxyLines[$key])
            }
            continue
        }
    }
    if ($line.Length -gt 0) {
        $mergedLines.Add($line)
    }
}
foreach ($key in $proxyKeyOrder) {
    if ($writtenProxyKeys.Add($key)) {
        $mergedLines.Add([string]$desiredProxyLines[$key])
    }
}
$runnerEnvNewLine = if ($existingRunnerEnv.Contains("`r`n")) {
    "`r`n"
} elseif ($existingRunnerEnv.Contains("`n")) {
    "`n"
} else {
    "`r`n"
}
$desiredRunnerEnv = ($mergedLines -join $runnerEnvNewLine) + $runnerEnvNewLine
$runnerEnvChanged = $existingRunnerEnv -cne $desiredRunnerEnv
if (Test-Path -LiteralPath $runnerEnv -PathType Leaf) {
    if ($runnerEnvChanged) {
        $backupPath = '{0}.before-watchdog-{1}.bak' -f $runnerEnv, (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $runnerEnv -Destination $backupPath -Force
        Write-Output "Backed up the existing runner environment to $backupPath"
    }
}
if ($runnerEnvChanged) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($runnerEnv, $desiredRunnerEnv, $utf8NoBom)
}

Import-Module ScheduledTasks -ErrorAction Stop
$account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$rcloneExe = Join-Path $InstallRoot 'rclone.exe'
$rcloneConfig = Join-Path $InstallRoot 'rclone.conf'
$actionArguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$installedWatchdog`" -RunnerRoot `"$RunnerRoot`" -StateRoot `"$InstallRoot`" -RcloneExe `"$rcloneExe`" -RcloneConfig `"$rcloneConfig`""
$action = New-ScheduledTaskAction `
    -Execute $powerShellExe `
    -Argument $actionArguments `
    -WorkingDirectory $InstallRoot
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $account
$repeatTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$principal = New-ScheduledTaskPrincipal `
    -UserId $account `
    -LogonType Interactive `
    -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 3)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Description 'Starts and monitors the Subtle GitHub runner and its local proxy while the user is logged on.' `
    -Action $action `
    -Trigger @($logonTrigger, $repeatTrigger) `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName

if ($runnerEnvChanged -and $runnerWasRunning) {
    Write-Warning 'Runner proxy settings are installed but will be loaded on the next runner restart.'
}

[pscustomobject]@{
    TaskName = $TaskName
    User = $account
    RunLevel = 'Limited'
    IntervalMinutes = $IntervalMinutes
    Watchdog = $installedWatchdog
    RunnerEnvironment = $runnerEnv
}
