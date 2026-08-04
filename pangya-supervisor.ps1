param(
    [string]$ServerRoot = "D:\PangYa\Server",
    [string]$DatabaseHost = "127.0.0.1",
    [int]$DatabasePort = 3306,
    [string]$DatabaseName = "pangya",
    [int]$AuthPort = 7777,
    [int]$LoginPort = 10103,
    [int]$GamePort = 20202,
    [int]$MessagePort = 30303,
    [string]$AutoRestart = "true",
    [int]$RestartLimit = 3,
    [int]$RestartBackoffSeconds = 5,
    [int]$StartupTimeoutSeconds = 180,
    [int]$ShutdownTimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:stopping = $false
$script:exitCode = 0
$script:services = @()
$script:restartCount = 0
$script:setStartedAt = [DateTime]::MinValue

function ConvertTo-Switch {
    param([string]$Value)
    return @("1", "true", "yes", "on", "enabled") -contains $Value.Trim().ToLowerInvariant()
}

function Assert-SafePath {
    param([string]$Value, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.IndexOf('"') -ge 0) {
        throw "$Name is invalid"
    }
    return [IO.Path]::GetFullPath($Value)
}

function Test-TcpPort {
    param([string]$HostName = "127.0.0.1", [int]$Port, [int]$TimeoutMilliseconds = 500)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait($TimeoutMilliseconds)) { return $false }
        return $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

$restartEnabled = ConvertTo-Switch $AutoRestart
$RestartLimit = [Math]::Max(0, [Math]::Min(10, $RestartLimit))
$RestartBackoffSeconds = [Math]::Max(1, [Math]::Min(60, $RestartBackoffSeconds))
$StartupTimeoutSeconds = [Math]::Max(30, [Math]::Min(900, $StartupTimeoutSeconds))
$ShutdownTimeoutSeconds = [Math]::Max(10, [Math]::Min(120, $ShutdownTimeoutSeconds))
$ServerRoot = Assert-SafePath $ServerRoot "ServerRoot"
$DatabaseHost = $DatabaseHost.Trim()
$DatabaseName = $DatabaseName.Trim()
if ([string]::IsNullOrWhiteSpace($DatabaseHost) -or $DatabaseHost.IndexOf('"') -ge 0) { throw "DatabaseHost is invalid" }
if ([string]::IsNullOrWhiteSpace($DatabaseName) -or $DatabaseName -notmatch '^[A-Za-z0-9_]{1,64}$') { throw "DatabaseName is invalid" }
foreach ($port in @($DatabasePort, $AuthPort, $LoginPort, $GamePort, $MessagePort)) {
    if ($port -lt 1 -or $port -gt 65535) { throw "A configured port is invalid" }
}

$serviceDefinitions = @(
    [pscustomobject]@{ Name = "auth"; Folder = "Auth Server"; Executable = "Auth Server.exe"; Port = $AuthPort },
    [pscustomobject]@{ Name = "message"; Folder = "Message Server"; Executable = "Message Server.exe"; Port = $MessagePort },
    [pscustomobject]@{ Name = "game"; Folder = "Game Server"; Executable = "Game Server.exe"; Port = $GamePort },
    [pscustomobject]@{ Name = "login"; Folder = "Login Server"; Executable = "LoginServer.exe"; Port = $LoginPort }
)

$expectedHashes = @{
    "Auth Server\Auth Server.exe" = "B69A11DC8817805C0D44A75EA3FB19D4DAC84A51185C5C58FBC2620A58B7C2F1"
    "Game Server\Game Server.exe" = "BEF3D470173DB97C9074705FB98552E5922BDD8A30BC9F1F7D2D95723A941C70"
    "Login Server\LoginServer.exe" = "C0724774B9373584F5DA0A5FB9EAC5039141196338915BE022332598DDB33294"
    "Message Server\Message Server.exe" = "95AA4574B1806C6BD27093836F5C8C529CD65725124D8CF1AB2459378C63799E"
}
foreach ($folder in @("Auth Server", "Game Server", "Login Server", "Message Server")) {
    $expectedHashes["$folder\libmysql.dll"] = "8F08A8D1644FEC893459B187EC8D12CEAB454A559C5584BDCF061ED973D8472A"
    $expectedHashes["$folder\zip.dll"] = "3C5946C123893485681C7745E4FCE2B799BFD94982025C8023079B1099EA4203"
    $expectedHashes["$folder\zlib.dll"] = "18016BBE3A74107471415180E24CD72D45CFA805CDF96E6A4EB2E5825249DA7E"
}

function Assert-RuntimeIntegrity {
    foreach ($relativePath in $expectedHashes.Keys) {
        $path = Join-Path $ServerRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required PangYa file is missing: $relativePath" }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if (-not $actual.Equals($expectedHashes[$relativePath], [StringComparison]::OrdinalIgnoreCase)) {
            throw "PangYa runtime integrity check failed: $relativePath"
        }
    }
    foreach ($definition in $serviceDefinitions) {
        $configPath = Join-Path (Join-Path $ServerRoot $definition.Folder) "Config.ini"
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "PangYa configuration is missing: $($definition.Folder)" }
    }
}

function Start-ServiceProcess {
    param([Parameter(Mandatory = $true)]$Definition)
    $workingDirectory = Join-Path $ServerRoot $Definition.Folder
    $executable = Join-Path $workingDirectory $Definition.Executable
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $executable
    $startInfo.WorkingDirectory = $workingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Could not start PangYa $($Definition.Name) service" }
    $state = [pscustomobject]@{
        Name = $Definition.Name
        Port = [int]$Definition.Port
        Process = $process
        StdoutTask = $process.StandardOutput.ReadLineAsync()
        StderrTask = $process.StandardError.ReadLineAsync()
    }
    $script:services += $state
    [Console]::WriteLine(("[supervisor] STARTED service={0} pid={1} port={2}" -f $state.Name, $process.Id, $state.Port))
}

function Drain-ServiceOutput {
    foreach ($state in @($script:services)) {
        foreach ($stream in @(
            [pscustomobject]@{ TaskProperty = "StdoutTask"; Reader = $state.Process.StandardOutput; Prefix = $state.Name },
            [pscustomobject]@{ TaskProperty = "StderrTask"; Reader = $state.Process.StandardError; Prefix = "$($state.Name):stderr" }
        )) {
            $task = $state.($stream.TaskProperty)
            while ($null -ne $task -and $task.IsCompleted) {
                try { $line = $task.GetAwaiter().GetResult() }
                catch {
                    [Console]::WriteLine(("[{0}] OUTPUT_READ_FAILED {1}" -f $stream.Prefix, $_.Exception.Message))
                    $line = $null
                }
                if ($null -eq $line) {
                    $state.($stream.TaskProperty) = $null
                    break
                }
                [Console]::WriteLine(("[{0}] {1}" -f $stream.Prefix, $line))
                $task = $stream.Reader.ReadLineAsync()
                $state.($stream.TaskProperty) = $task
            }
        }
    }
}

function Wait-PortReady {
    param([string]$ServiceName, [int]$Port, [DateTime]$Deadline)
    do {
        Drain-ServiceOutput
        $state = $script:services | Where-Object Name -eq $ServiceName | Select-Object -First 1
        if ($null -eq $state -or $state.Process.HasExited) { return $false }
        if (Test-TcpPort -Port $Port) { return $true }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $Deadline)
    return $false
}

function Start-ServiceSet {
    if (-not (Test-TcpPort -HostName $DatabaseHost -Port $DatabasePort -TimeoutMilliseconds 1000)) {
        throw "Laragon MySQL is unavailable at ${DatabaseHost}:$DatabasePort"
    }
    Assert-RuntimeIntegrity
    $script:services = @()
    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    foreach ($definition in $serviceDefinitions) {
        Start-ServiceProcess -Definition $definition
        if (-not (Wait-PortReady -ServiceName $definition.Name -Port $definition.Port -Deadline $deadline)) {
            throw "PangYa $($definition.Name) service did not open TCP port $($definition.Port)"
        }
    }
    $script:setStartedAt = [DateTime]::UtcNow
    [Console]::WriteLine(("[supervisor] READY auth={0} login={1} game={2} message={3}" -f $AuthPort, $LoginPort, $GamePort, $MessagePort))
}

function Stop-Descendants {
    param([int]$ParentId)
    $children = @(Get-CimInstance Win32_Process -Filter ("ParentProcessId={0}" -f $ParentId) -ErrorAction SilentlyContinue)
    foreach ($child in $children) { Stop-Descendants -ParentId ([int]$child.ProcessId) }
    foreach ($child in $children) { Stop-Process -Id ([int]$child.ProcessId) -Force -ErrorAction SilentlyContinue }
}

function Stop-ServiceSet {
    if ($script:services.Count -eq 0) { return }
    [Console]::WriteLine("[supervisor] STOPPING")
    $reverseServices = @($script:services)
    [Array]::Reverse($reverseServices)
    foreach ($state in $reverseServices) {
        if (-not $state.Process.HasExited) {
            try {
                $state.Process.StandardInput.WriteLine("exit")
                $state.Process.StandardInput.Flush()
                [Console]::WriteLine(("[supervisor] GRACEFUL_STOP_REQUESTED service={0}" -f $state.Name))
            }
            catch { [Console]::WriteLine(("[supervisor] GRACEFUL_STOP_FAILED service={0}" -f $state.Name)) }
        }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($ShutdownTimeoutSeconds)
    while (($script:services | Where-Object { -not $_.Process.HasExited }).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
        Drain-ServiceOutput
        Start-Sleep -Milliseconds 200
    }
    foreach ($state in $reverseServices) {
        if (-not $state.Process.HasExited) {
            [Console]::WriteLine(("[supervisor] FORCE_STOP service={0} pid={1}" -f $state.Name, $state.Process.Id))
            Stop-Descendants -ParentId $state.Process.Id
            $state.Process.Kill()
            [void]$state.Process.WaitForExit(5000)
        }
        $state.Process.Dispose()
    }
    $script:services = @()
    [Console]::WriteLine("[supervisor] STOPPED")
}

function Write-ServiceStatus {
    $parts = foreach ($definition in $serviceDefinitions) {
        $state = $script:services | Where-Object Name -eq $definition.Name | Select-Object -First 1
        $running = $null -ne $state -and -not $state.Process.HasExited
        $ready = Test-TcpPort -Port $definition.Port -TimeoutMilliseconds 200
        "{0}_running={1} {0}_ready={2}" -f $definition.Name, $running.ToString().ToLowerInvariant(), $ready.ToString().ToLowerInvariant()
    }
    [Console]::WriteLine(("[supervisor] STATUS {0}" -f ($parts -join " ")))
}

try {
    [Console]::WriteLine(("[supervisor] ROOT {0} database={1}:{2}/{3}" -f $ServerRoot, $DatabaseHost, $DatabasePort, $DatabaseName))
    Start-ServiceSet
    $inputClosed = $false
    $readTask = [Console]::In.ReadLineAsync()
    $keepRunning = $true
    while ($keepRunning -and -not $script:stopping) {
        Drain-ServiceOutput
        $failed = @($script:services | Where-Object { $_.Process.HasExited })
        if ($failed.Count -gt 0) {
            $failedText = ($failed | ForEach-Object { "{0}:{1}" -f $_.Name, $_.Process.ExitCode }) -join ","
            $lifetime = ([DateTime]::UtcNow - $script:setStartedAt).TotalSeconds
            [Console]::WriteLine(("[supervisor] SERVICE_SET_FAILED services={0} lifetime_seconds={1:N1}" -f $failedText, $lifetime))
            if (-not $restartEnabled) { throw "A PangYa service exited and automatic restart is disabled" }
            if ($lifetime -ge 300) { $script:restartCount = 0 }
            $script:restartCount++
            if ($script:restartCount -gt $RestartLimit) { throw "PangYa exceeded the restart limit" }
            Stop-ServiceSet
            $delay = [Math]::Min(60, $RestartBackoffSeconds * $script:restartCount)
            [Console]::WriteLine(("[supervisor] RESTARTING attempt={0}/{1} delay_seconds={2}" -f $script:restartCount, $RestartLimit, $delay))
            Start-Sleep -Seconds $delay
            Start-ServiceSet
        }
        if (-not $inputClosed -and $readTask.IsCompleted) {
            try { $line = $readTask.GetAwaiter().GetResult() } catch { $line = $null }
            if ($null -eq $line) { $inputClosed = $true }
            else {
                $normalizedCommand = $line.Trim().ToLowerInvariant()
                if ($normalizedCommand -in @("ampstop", "shutdown", "exit", "quit")) {
                    $script:stopping = $true
                    $keepRunning = $false
                }
                elseif ($normalizedCommand -eq "status") { Write-ServiceStatus }
                elseif (-not [string]::IsNullOrWhiteSpace($normalizedCommand)) {
                    [Console]::WriteLine("[supervisor] Unsupported command. Use status or AMP controls.")
                }
                $readTask = [Console]::In.ReadLineAsync()
            }
        }
        Start-Sleep -Milliseconds 200
    }
}
catch {
    [Console]::WriteLine(("[supervisor] FATAL type={0} message={1}" -f $_.Exception.GetType().FullName, $_.Exception.Message))
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        [Console]::WriteLine(("[supervisor] FATAL_STACK {0}" -f ($_.ScriptStackTrace -replace "[\r\n]+", " | ")))
    }
    $script:exitCode = 1
}
finally {
    Stop-ServiceSet
}

exit $script:exitCode
