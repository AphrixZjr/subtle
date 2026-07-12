[CmdletBinding()]
param(
    [string]$RunnerRoot = 'D:\actions-runner',
    [string]$V2rayNPath = 'D:\v2rayN-windows-64\v2rayN.exe',
    [int]$ProxyPort = 10808,
    [string]$RcloneExe = 'C:\subtle-ci\rclone.exe',
    [string]$RcloneConfig = 'C:\subtle-ci\rclone.conf',
    [string]$DriveFolderId = '1Y2Cutr-QaUggJv4VOVc0jfw6eVF3F5nn',
    [string]$StateRoot = 'C:\subtle-ci',
    [int]$RcloneHealthHours = 24,
    [int]$RcloneRetryMinutes = 60,
    [int]$RcloneBusyWarningHours = 2
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$logPath = Join-Path $StateRoot 'runner-watchdog.log'
$rcloneSuccessStamp = Join-Path $StateRoot '.last-rclone-health-success'
$rcloneAttemptStamp = Join-Path $StateRoot '.last-rclone-health-attempt'

function Initialize-WatchdogLog {
    if (-not (Test-Path -LiteralPath $StateRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    }

    if ((Test-Path -LiteralPath $logPath -PathType Leaf) -and
        (Get-Item -LiteralPath $logPath).Length -gt 1MB) {
        Move-Item -LiteralPath $logPath -Destination "$logPath.1" -Force
    }
}

function Write-WatchdogLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = '[{0}] [{1}] {2}' -f [DateTime]::UtcNow.ToString('o'), $Level, $Message
    [IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, $utf8NoBom)
    Write-Output $line
}

function Test-LocalTcpPort {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [int]$TimeoutMilliseconds = 2000
    )

    $client = New-Object System.Net.Sockets.TcpClient
    $asyncResult = $null
    try {
        $asyncResult = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }

        $client.EndConnect($asyncResult)
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $asyncResult -and $null -ne $asyncResult.AsyncWaitHandle) {
            $asyncResult.AsyncWaitHandle.Close()
        }
        $client.Close()
    }
}

function Wait-LocalTcpPort {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-LocalTcpPort -Port $Port) {
            return $true
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Ensure-Proxy {
    if (Test-LocalTcpPort -Port $ProxyPort) {
        Write-WatchdogLog "Proxy port 127.0.0.1:$ProxyPort is available."
        return
    }

    if (-not (Test-Path -LiteralPath $V2rayNPath -PathType Leaf)) {
        throw "v2rayN executable is missing: $V2rayNPath"
    }

    $v2rayProcesses = @(Get-Process -Name 'v2rayN' -ErrorAction SilentlyContinue)
    if ($v2rayProcesses.Count -eq 0) {
        $v2rayWorkingDirectory = Split-Path -Parent $V2rayNPath
        $started = Start-Process -FilePath $V2rayNPath `
            -WorkingDirectory $v2rayWorkingDirectory `
            -WindowStyle Hidden `
            -PassThru
        Write-WatchdogLog "Started v2rayN process $($started.Id)."
    } else {
        Write-WatchdogLog 'v2rayN is already running but the proxy port is not ready; waiting without starting another instance.' 'WARN'
    }

    if (-not (Wait-LocalTcpPort -Port $ProxyPort -TimeoutSeconds 30)) {
        throw "Proxy port 127.0.0.1:$ProxyPort did not become available."
    }

    Write-WatchdogLog "Proxy port 127.0.0.1:$ProxyPort became available."
}

function Get-TargetRunnerListeners {
    $listenerPath = [IO.Path]::GetFullPath((Join-Path $RunnerRoot 'bin\Runner.Listener.exe'))
    $matches = @()

    foreach ($candidate in @(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue)) {
        try {
            if ($candidate.Path -and [IO.Path]::GetFullPath($candidate.Path) -ieq $listenerPath) {
                $matches += $candidate
            }
        } catch {
            # A process may exit while its Path property is being read. Ignore it.
        }
    }

    return $matches
}

function Test-TargetRunnerLauncher {
    $runCmd = [IO.Path]::GetFullPath((Join-Path $RunnerRoot 'run.cmd'))
    try {
        $launchers = @(Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($runCmd) })
        return $launchers.Count -gt 0
    } catch {
        throw "Unable to inspect existing runner launchers: $($_.Exception.Message)"
    }
}

function Wait-TargetRunnerListener {
    param([int]$TimeoutSeconds = 30)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $listeners = @(Get-TargetRunnerListeners)
        if ($listeners.Count -gt 0) {
            return $listeners[0]
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Ensure-Runner {
    $runCmd = Join-Path $RunnerRoot 'run.cmd'
    if (-not (Test-Path -LiteralPath $runCmd -PathType Leaf)) {
        throw "GitHub runner run.cmd is missing: $runCmd"
    }

    $listeners = @(Get-TargetRunnerListeners)
    if ($listeners.Count -gt 0) {
        Write-WatchdogLog "GitHub runner listener $($listeners[0].Id) is running."
        return
    }

    $workers = @(Get-Process -Name 'Runner.Worker' -ErrorAction SilentlyContinue)
    if ($workers.Count -gt 0) {
        throw 'Runner.Worker exists without the target listener; refusing to start a second runner.'
    }

    if (Test-TargetRunnerLauncher) {
        Write-WatchdogLog 'The target run.cmd launcher exists while the listener is absent; waiting for runner self-update or retry.' 'WARN'
    } else {
        $arguments = @('/d', '/c', "`"$runCmd`"")
        $launcher = Start-Process -FilePath $env:ComSpec `
            -ArgumentList $arguments `
            -WorkingDirectory $RunnerRoot `
            -WindowStyle Hidden `
            -PassThru
        Write-WatchdogLog "Started GitHub runner launcher process $($launcher.Id)."
    }

    $listener = Wait-TargetRunnerListener -TimeoutSeconds 30
    if ($null -eq $listener) {
        if (Test-TargetRunnerLauncher) {
            throw 'The runner launcher is active, but Runner.Listener did not become ready within 30 seconds.'
        }
        throw 'The GitHub runner failed to start.'
    }

    Write-WatchdogLog "GitHub runner listener $($listener.Id) became available."
}

function Test-StampIsRecent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [TimeSpan]$MaximumAge
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $age = [DateTime]::UtcNow - (Get-Item -LiteralPath $Path).LastWriteTimeUtc
    return $age -ge [TimeSpan]::Zero -and $age -lt $MaximumAge
}

function Set-HealthStamp {
    param([Parameter(Mandatory = $true)][string]$Path)

    Set-Content -LiteralPath $Path -Value ([DateTime]::UtcNow.ToString('o')) -Encoding Ascii
}

function Invoke-RcloneHealthCheck {
    if (Test-StampIsRecent -Path $rcloneSuccessStamp -MaximumAge ([TimeSpan]::FromHours($RcloneHealthHours))) {
        Write-WatchdogLog 'The daily rclone health check is still current.'
        return
    }

    if (Test-StampIsRecent -Path $rcloneAttemptStamp -MaximumAge ([TimeSpan]::FromMinutes($RcloneRetryMinutes))) {
        throw "The previous rclone health check failed; retry is deferred for $RcloneRetryMinutes minutes."
    }

    $activeRcloneProcesses = @(Get-Process -Name 'rclone' -ErrorAction SilentlyContinue)
    if ($activeRcloneProcesses.Count -gt 0) {
        foreach ($activeProcess in $activeRcloneProcesses) {
            try {
                if ([DateTime]::Now - $activeProcess.StartTime -ge [TimeSpan]::FromHours($RcloneBusyWarningHours)) {
                    throw "rclone process $($activeProcess.Id) has been active for at least $RcloneBusyWarningHours hours."
                }
            } catch {
                if ($_.Exception.Message -like 'rclone process *') {
                    throw
                }
                throw "Unable to inspect active rclone process $($activeProcess.Id): $($_.Exception.Message)"
            }
        }
        Write-WatchdogLog 'Another rclone process is active; deferring the health check to avoid a config write race.' 'WARN'
        return
    }

    if (-not (Test-Path -LiteralPath $RcloneExe -PathType Leaf)) {
        throw "rclone executable is missing: $RcloneExe"
    }
    if (-not (Test-Path -LiteralPath $RcloneConfig -PathType Leaf)) {
        throw "rclone config is missing: $RcloneConfig"
    }
    if ($DriveFolderId -notmatch '^[A-Za-z0-9_-]{10,}$') {
        throw 'The Google Drive folder ID is invalid.'
    }

    Set-HealthStamp -Path $rcloneAttemptStamp
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 converts native stderr into an ErrorRecord.
        # Keep it non-terminating here so the native exit code remains authoritative.
        $ErrorActionPreference = 'Continue'
        & $RcloneExe --config $RcloneConfig lsf 'gdrive:' `
            "--drive-root-folder-id=$DriveFolderId" `
            --max-depth 1 `
            --dirs-only `
            --contimeout 10s `
            --timeout 30s `
            --retries 1 `
            --low-level-retries 1 `
            --log-level ERROR 1>$null 2>$null
        $rcloneExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($rcloneExitCode -ne 0) {
        throw "The rclone Google Drive health check failed with exit code $rcloneExitCode."
    }

    Set-HealthStamp -Path $rcloneSuccessStamp
    Write-WatchdogLog 'The rclone Google Drive health check succeeded.'
}

try {
    Initialize-WatchdogLog
    Write-WatchdogLog 'Watchdog run started.'
    Ensure-Proxy

    $proxyUrl = "http://127.0.0.1:$ProxyPort"
    $env:HTTP_PROXY = $proxyUrl
    $env:HTTPS_PROXY = $proxyUrl
    $env:NO_PROXY = '127.0.0.1,localhost'
    $env:http_proxy = $proxyUrl
    $env:https_proxy = $proxyUrl
    $env:no_proxy = '127.0.0.1,localhost'

    Ensure-Runner
    Invoke-RcloneHealthCheck
    Write-WatchdogLog 'Watchdog run completed successfully.'
    exit 0
} catch {
    try {
        if (-not (Test-Path -LiteralPath $StateRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
        }
        Write-WatchdogLog $_.Exception.Message 'ERROR'
    } catch {
        Write-Error "Watchdog failed and could not write its log: $($_.Exception.Message)"
    }
    exit 1
}
