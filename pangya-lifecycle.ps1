[CmdletBinding()]
param(
    [string]$ServerRoot = "D:\PangYa\Server",
    [string]$AdvertisedServerHost = "server.kallidos.com",
    # Kept for backward-compatible AMP command lines.  AMP stops this
    # controller through its supported process-tree termination mechanism.
    [string]$ExitFilePath = "",
    [int]$StartupTimeoutSeconds = 60,
    [switch]$ValidateOnly = $false
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:services = @()
$script:logPath = Join-Path $PSScriptRoot "lifecycle.log"

function Write-LifecycleLine {
    param([string]$Message)
    $line = "[pangya] $Message"
    [Console]::WriteLine($line)
    try {
        [IO.File]::AppendAllText(
            $script:logPath,
            ("[{0}] {1}{2}" -f [DateTime]::UtcNow.ToString("o"), $line, [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false)
        )
    }
    catch {}
}

function Assert-Path {
    param([string]$Value, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.IndexOf('"') -ge 0) {
        throw "$Name is invalid"
    }
    return [IO.Path]::GetFullPath($Value)
}

function Resolve-PublicIpv4 {
    param([string]$HostName)
    $candidate = $HostName.Trim()
    if ($candidate -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,251}[A-Za-z0-9]$') {
        throw "AdvertisedServerHost is invalid"
    }

    $address = $null
    if ([Net.IPAddress]::TryParse($candidate, [ref]$address)) {
        if ($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
            throw "AdvertisedServerHost must be an IPv4 address or hostname"
        }
        return $address.ToString()
    }

    foreach ($resolver in @("1.1.1.1", "8.8.8.8")) {
        try {
            $resolved = @(
                Resolve-DnsName -Name $candidate -Type A -DnsOnly -Server $resolver -ErrorAction Stop |
                    Where-Object { $_.Type -eq "A" -and $_.IPAddress } |
                    Select-Object -ExpandProperty IPAddress -Unique
            )
            if ($resolved.Count -eq 1) {
                $parsed = $null
                if ([Net.IPAddress]::TryParse($resolved[0], [ref]$parsed) -and $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
                    return $parsed.ToString()
                }
            }
        }
        catch {}
    }
    throw "Could not resolve AdvertisedServerHost to exactly one public IPv4 address"
}

function Set-AdvertisedServerAddress {
    param([string]$Address)
    $encoding = [Text.Encoding]::GetEncoding(1252)
    $changed = 0
    foreach ($relativePath in @("Login Server\Config.ini", "Game Server\Config.ini", "Message Server\Config.ini")) {
        $path = Join-Path $ServerRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Missing PangYa configuration file: $relativePath"
        }
        $original = [IO.File]::ReadAllText($path, $encoding)
        $matches = [Regex]::Matches($original, '(?m)^(?<prefix>\s*ServerIP\s*=\s*)"[^"]*"(?<suffix>\s*,\s*CHAR\s*,\s*18\s*;\s*)$')
        if ($matches.Count -ne 1) {
            throw "ServerIP was not found exactly once in $relativePath"
        }
        $updated = [Regex]::Replace(
            $original,
            '(?m)^(?<prefix>\s*ServerIP\s*=\s*)"[^"]*"(?<suffix>\s*,\s*CHAR\s*,\s*18\s*;\s*)$',
            [Text.RegularExpressions.MatchEvaluator]{ param($match) $match.Groups["prefix"].Value + '"' + $Address + '"' + $match.Groups["suffix"].Value },
            1
        )
        if ($updated -ne $original) {
            [IO.File]::WriteAllText($path, $updated, $encoding)
            $changed++
        }
    }
    Write-LifecycleLine "advertised IPv4=$Address changed_files=$changed"
}

function Sync-AmpManagedLegacyConfiguration {
    # AMP persists editable legacy settings as individual fragments.  Applying
    # those fragments line-by-line is intentionally the only configuration
    # work done at start: no relay, binary patch, SQL mutation, or restart loop.
    $managedRoot = Join-Path $ServerRoot "managed"
    if (-not (Test-Path -LiteralPath $managedRoot -PathType Container)) { return }

    $specifications = @(
        [pscustomobject]@{ Fragment = "auth-char.ini"; Target = "Auth Server\Config.ini"; Keys = @("ServerName", "ServerVersion") },
        [pscustomobject]@{ Fragment = "auth-int32.ini"; Target = "Auth Server\Config.ini"; Keys = @("ServerPacketVersion", "ServerGUID", "GSMaxUser") },
        [pscustomobject]@{ Fragment = "login-char.ini"; Target = "Login Server\Config.ini"; Keys = @("ServerName", "ServerVersion") },
        [pscustomobject]@{ Fragment = "login-int32.ini"; Target = "Login Server\Config.ini"; Keys = @("ServerPacketVersion", "ServerGUID", "GSMaxUser", "CreateAccount", "AccessFlag") },
        [pscustomobject]@{ Fragment = "game-char40.ini"; Target = "Game Server\Config.ini"; Keys = @("ServerName", "ServerVersion") },
        [pscustomobject]@{ Fragment = "game-int32.ini"; Target = "Game Server\Config.ini"; Keys = @("ServerPacketVersion", "ServerGUID", "ServerProperty", "GSMaxUser", "CanaisCount", "CanalFlag_1") },
        [pscustomobject]@{ Fragment = "game-int64.ini"; Target = "Game Server\Config.ini"; Keys = @("ServerFlag") },
        [pscustomobject]@{ Fragment = "game-int16.ini"; Target = "Game Server\Config.ini"; Keys = @("ServerEventFlag", "ServerRareItemRate", "ServerCookieItemRate", "ServerPangRate", "ServerExpRate", "ServerAngelEvent", "ServerScratchRate", "ServerMasteryRate", "ServerTreasureRate", "ServerChuvaRate", "ServerIcon", "CanalMaxUser_1", "CanalMaxUser_2", "CanalMaxUser_3") },
        [pscustomobject]@{ Fragment = "game-char64.ini"; Target = "Game Server\Config.ini"; Keys = @("CanalName_1", "CanalName_2", "CanalName_3") },
        [pscustomobject]@{ Fragment = "game-int8.ini"; Target = "Game Server\Config.ini"; Keys = @("CanalID_1", "CanalID_2", "CanalID_3") },
        [pscustomobject]@{ Fragment = "message-char.ini"; Target = "Message Server\Config.ini"; Keys = @("ServerName", "ServerVersion") },
        [pscustomobject]@{ Fragment = "message-int32.ini"; Target = "Message Server\Config.ini"; Keys = @("ServerPacketVersion", "ServerGUID", "ServerProperty", "GSMaxUser") }
    )
    $legacyEncoding = [Text.Encoding]::GetEncoding(1252)
    $fragmentEncoding = [Text.UTF8Encoding]::new($false, $true)
    $changedFiles = 0
    $changedSettings = 0
    foreach ($specification in $specifications) {
        $fragmentPath = Join-Path $managedRoot $specification.Fragment
        if (-not (Test-Path -LiteralPath $fragmentPath -PathType Leaf)) { continue }
        $targetPath = Join-Path $ServerRoot $specification.Target
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) { throw "Missing PangYa configuration file: $($specification.Target)" }
        $text = [IO.File]::ReadAllText($targetPath, $legacyEncoding)
        $original = $text
        foreach ($line in [IO.File]::ReadAllLines($fragmentPath, $fragmentEncoding)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $fragmentMatch = [Regex]::Match($line, '^\s*(?<key>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<value>"[^"\r\n]*"|-?\d+|true|false)\s*,\s*(?<type>CHAR|INT8|INT16|INT32|INT64)\s*,\s*(?<size>\d+)\s*;\s*$')
            if (-not $fragmentMatch.Success) { throw "PangYa managed fragment $($specification.Fragment) contains an invalid line" }
            $key = $fragmentMatch.Groups["key"].Value
            if ($specification.Keys -notcontains $key) { throw "PangYa managed fragment $($specification.Fragment) contains unexpected key $key" }
            $managedLine = $line
            if ($fragmentMatch.Groups["value"].Value -in @("true", "false")) {
                if ($fragmentMatch.Groups["type"].Value -eq "CHAR") { throw "PangYa managed fragment $($specification.Fragment) contains a boolean CHAR value" }
                $numericValue = if ($fragmentMatch.Groups["value"].Value -eq "true") { "1" } else { "0" }
                $managedLine = "{0} = {1}, {2}, {3};" -f $key, $numericValue, $fragmentMatch.Groups["type"].Value, $fragmentMatch.Groups["size"].Value
            }
            if ($legacyEncoding.GetString($legacyEncoding.GetBytes($managedLine)) -ne $managedLine) { throw "PangYa managed value for $key is not representable in Windows-1252" }
            $targetPattern = '(?m)^\s*' + [Regex]::Escape($key) + '\s*=.*?(?<ending>\r?)$'
            if ([Regex]::Matches($text, $targetPattern).Count -ne 1) { throw "PangYa configuration key $key was not found exactly once" }
            $text = [Regex]::Replace($text, $targetPattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $managedLine + $match.Groups["ending"].Value }, 1)
            $changedSettings++
        }
        if ($text -ne $original) {
            [IO.File]::WriteAllText($targetPath, $text, $legacyEncoding)
            $changedFiles++
        }
    }
    Write-LifecycleLine "managed configuration synchronized files=$changedFiles settings=$changedSettings"
}

function Test-ListeningPort {
    param([int]$Port)
    return @(
        Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    ).Count -gt 0
}

function Start-ServiceProcess {
    param([pscustomobject]$Definition)
    $workingDirectory = Join-Path $ServerRoot $Definition.Folder
    $executable = Join-Path $workingDirectory $Definition.Executable
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Missing PangYa executable: $($Definition.Folder)\\$($Definition.Executable)"
    }
    $process = Start-Process -FilePath $executable -WorkingDirectory $workingDirectory -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        if ($process.HasExited) {
            throw "$($Definition.Name) exited during startup with code $($process.ExitCode)"
        }
        if (Test-ListeningPort -Port $Definition.Port) {
            $script:services += [pscustomobject]@{ Definition = $Definition; Process = $process }
            Write-LifecycleLine "started $($Definition.Name) port=$($Definition.Port) pid=$($process.Id)"
            return
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "$($Definition.Name) did not open TCP port $($Definition.Port) within $StartupTimeoutSeconds seconds"
}

function Stop-ServiceSet {
    if ($script:services.Count -eq 0) { return }
    $reverse = @($script:services)
    [Array]::Reverse($reverse)
    foreach ($service in $reverse) {
        try {
            if (-not $service.Process.HasExited) {
                [void]$service.Process.CloseMainWindow()
            }
        }
        catch {}
    }
    Start-Sleep -Seconds 3
    foreach ($service in $reverse) {
        try {
            if (-not $service.Process.HasExited) {
                Stop-Process -Id $service.Process.Id -Force -ErrorAction Stop
            }
            $service.Process.Dispose()
        }
        catch {}
    }
    $script:services = @()
}

try {
    $ServerRoot = Assert-Path $ServerRoot "ServerRoot"
    if (-not (Test-Path -LiteralPath $ServerRoot -PathType Container)) {
        throw "PangYa server root does not exist: $ServerRoot"
    }
    if ($StartupTimeoutSeconds -lt 10 -or $StartupTimeoutSeconds -gt 300) {
        throw "StartupTimeoutSeconds must be between 10 and 300"
    }
    & (Join-Path $PSScriptRoot "amp-config-link.ps1") -ServerRoot $ServerRoot
    Sync-AmpManagedLegacyConfiguration
    $publicAddress = Resolve-PublicIpv4 -HostName $AdvertisedServerHost
    Set-AdvertisedServerAddress -Address $publicAddress
    if ($ValidateOnly) {
        Write-LifecycleLine "validation complete"
        exit 0
    }

    $definitions = @(
        [pscustomobject]@{ Name = "auth"; Folder = "Auth Server"; Executable = "Auth Server.exe"; Port = 7777 },
        [pscustomobject]@{ Name = "message"; Folder = "Message Server"; Executable = "Message Server.exe"; Port = 30303 },
        [pscustomobject]@{ Name = "game"; Folder = "Game Server"; Executable = "Game Server.exe"; Port = 20202 },
        [pscustomobject]@{ Name = "login"; Folder = "Login Server"; Executable = "LoginServer.exe"; Port = 10103 }
    )
    foreach ($definition in $definitions) {
        Start-ServiceProcess -Definition $definition
    }
    Write-LifecycleLine "ready"
    while ($true) {
        foreach ($service in $script:services) {
            if ($service.Process.HasExited) {
                throw "$($service.Definition.Name) exited unexpectedly with code $($service.Process.ExitCode)"
            }
        }
        Start-Sleep -Seconds 1
    }
    exit 0
}
catch {
    Write-LifecycleLine "failed: $($_.Exception.Message)"
    exit 1
}
finally {
    Stop-ServiceSet
}
