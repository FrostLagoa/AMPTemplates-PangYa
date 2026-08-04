param(
    [string]$ServerRoot = "D:\PangYa\Server",
    [string]$DatabaseHost = "127.0.0.1",
    [int]$DatabasePort = 3306,
    [string]$DatabaseName = "pangya",
    [int]$AuthPort = 7777,
    [int]$LoginPort = 10103,
    [int]$GamePort = 20202,
    [int]$MessagePort = 30303,
    [string]$ServerDisplayName = "Kallidos PangYa",
    [string]$ChannelName = "Kallidos Channel",
    [int]$ChannelMaxUsers = 200,
    [int]$ServerMaxUsers = 2000,
    [int]$PangRate = 100,
    [int]$ExperienceRate = 100,
    [int]$RareItemRate = 100,
    [int]$CookieItemRate = 100,
    [int]$ScratchyRate = 100,
    [int]$MasteryRate = 100,
    [int]$TreasureRate = 100,
    [int]$RainRate = 100,
    [string]$AngelEventEnabled = "false",
    [int]$ServerPropertyMask = 2048,
    [int]$ServerFeatureBlockMask = 0,
    [int]$ServerEventFlagMask = 0,
    [int]$ServerIcon = 1,
    [string]$PeriodicAnnouncementEnabled = "false",
    [string]$PeriodicAnnouncementText = "Welcome to Kallidos PangYa!",
    [int]$PeriodicAnnouncementRepeatCount = 1000,
    [int]$PeriodicAnnouncementIntervalMinutes = 30,
    [string]$DatabaseClientPath = "D:\Laragon\bin\mysql\mysql-8.4.3-winx64\bin\mysql.exe",
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
$script:logPath = Join-Path $PSScriptRoot "server.log"

function Write-SupervisorLine {
    param([string]$Message)
    [Console]::WriteLine($Message)
    try {
        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        $entry = "[$timestamp] $Message$([Environment]::NewLine)"
        [IO.File]::AppendAllText($script:logPath, $entry, [Text.UTF8Encoding]::new($false))
    }
    catch {}
}

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

function Assert-SafeDisplayText {
    param([string]$Value, [string]$Name, [int]$MaximumBytes)
    if ($null -eq $Value) { throw "$Name is required" }
    $normalized = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized.IndexOf('"') -ge 0 -or $normalized.IndexOf("`r") -ge 0 -or $normalized.IndexOf("`n") -ge 0) {
        throw "$Name is invalid"
    }
    $encoding = [Text.Encoding]::GetEncoding(1252)
    $bytes = $encoding.GetBytes($normalized)
    if ($bytes.Length -gt $MaximumBytes -or $encoding.GetString($bytes) -ne $normalized) {
        throw "$Name exceeds the legacy PangYa text contract"
    }
    return $normalized
}

function Set-LegacyConfigValue {
    param([string]$Text, [string]$Key, [object]$Value, [bool]$Quoted)
    $pattern = "(?m)^(?<prefix>\s*" + [Regex]::Escape($Key) + "\s*=\s*)(?<value>[^,\r\n]*)(?<suffix>\s*,[^\r\n]*)(?<ending>\r?)$"
    $matches = [Regex]::Matches($Text, $pattern)
    if ($matches.Count -ne 1) { throw "PangYa configuration key $Key was not found exactly once" }
    $serialized = if ($Quoted) { '"' + [string]$Value + '"' } else { [string]$Value }
    return [Regex]::Replace(
        $Text,
        $pattern,
        [Text.RegularExpressions.MatchEvaluator]{ param($match) $match.Groups["prefix"].Value + $serialized + $match.Groups["suffix"].Value + $match.Groups["ending"].Value },
        1
    )
}

function Get-LegacyConfigSecret {
    param([string]$Text, [string]$Key)
    $pattern = '(?m)^\s*' + [Regex]::Escape($Key) + '\s*=\s*"(?<value>[^"\r\n]*)"'
    $match = [Regex]::Match($Text, $pattern)
    if (-not $match.Success -or [string]::IsNullOrWhiteSpace($match.Groups["value"].Value)) {
        throw "PangYa protected database setting $Key is unavailable"
    }
    return $match.Groups["value"].Value
}

function ConvertTo-Latin1HexLiteral {
    param([string]$Value)
    $encoding = [Text.Encoding]::GetEncoding(1252)
    $bytes = $encoding.GetBytes($Value)
    if ($encoding.GetString($bytes) -ne $Value) { throw "The announcement contains unsupported characters" }
    return "0x" + [BitConverter]::ToString($bytes).Replace("-", "")
}

function Invoke-PangYaSql {
    param([string]$Sql, [string]$UserName, [string]$Password)
    if (-not (Test-Path -LiteralPath $DatabaseClientPath -PathType Leaf)) {
        throw "The configured Laragon mysql.exe was not found"
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $DatabaseClientPath
    $startInfo.Arguments = ('--protocol=TCP --host="{0}" --port={1} --user="{2}" --database="{3}" --default-character-set=latin1 --batch --skip-column-names --silent' -f $DatabaseHost, $DatabasePort, $UserName, $DatabaseName)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables["MYSQL_PWD"] = $Password
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Could not start the Laragon MySQL client" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($Sql)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            throw "Timed out while synchronizing the PangYa announcement"
        }
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        [void]$stdoutTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "The PangYa announcement sync failed: $stderr"
        }
    }
    finally {
        $process.Dispose()
    }
}

function Sync-GameServerConfiguration {
    $gameConfigPath = Join-Path (Join-Path $ServerRoot "Game Server") "Config.ini"
    $encoding = [Text.Encoding]::GetEncoding(1252)
    $text = [IO.File]::ReadAllText($gameConfigPath, $encoding)
    $settings = @(
        [pscustomobject]@{ Key = "ServerName"; Value = $ServerDisplayName; Quoted = $true },
        [pscustomobject]@{ Key = "ServerProperty"; Value = $ServerPropertyMask; Quoted = $false },
        [pscustomobject]@{ Key = "ServerFlag"; Value = $ServerFeatureBlockMask; Quoted = $false },
        [pscustomobject]@{ Key = "ServerEventFlag"; Value = $ServerEventFlagMask; Quoted = $false },
        [pscustomobject]@{ Key = "ServerRareItemRate"; Value = $RareItemRate; Quoted = $false },
        [pscustomobject]@{ Key = "ServerCookieItemRate"; Value = $CookieItemRate; Quoted = $false },
        [pscustomobject]@{ Key = "ServerPangRate"; Value = $PangRate; Quoted = $false },
        [pscustomobject]@{ Key = "ServerExpRate"; Value = $ExperienceRate; Quoted = $false },
        [pscustomobject]@{ Key = "ServerAngelEvent"; Value = $(if ($angelEvent) { 1 } else { 0 }); Quoted = $false },
        [pscustomobject]@{ Key = "ServerScratchRate"; Value = $ScratchyRate; Quoted = $false },
        [pscustomobject]@{ Key = "ServerMasteryRate"; Value = $MasteryRate; Quoted = $false },
        [pscustomobject]@{ Key = "ServerTreasureRate"; Value = $TreasureRate; Quoted = $false },
        [pscustomobject]@{ Key = "ServerChuvaRate"; Value = $RainRate; Quoted = $false },
        [pscustomobject]@{ Key = "ServerIcon"; Value = $ServerIcon; Quoted = $false },
        [pscustomobject]@{ Key = "GSMaxUser"; Value = $ServerMaxUsers; Quoted = $false },
        [pscustomobject]@{ Key = "CanaisCount"; Value = 1; Quoted = $false },
        [pscustomobject]@{ Key = "CanalName_1"; Value = $ChannelName; Quoted = $true },
        [pscustomobject]@{ Key = "CanalMaxUser_1"; Value = $ChannelMaxUsers; Quoted = $false },
        [pscustomobject]@{ Key = "CanalID_1"; Value = 0; Quoted = $false },
        [pscustomobject]@{ Key = "CanalFlag_1"; Value = 1; Quoted = $false }
    )
    foreach ($setting in $settings) {
        $text = Set-LegacyConfigValue -Text $text -Key $setting.Key -Value $setting.Value -Quoted $setting.Quoted
    }
    $existing = [IO.File]::ReadAllText($gameConfigPath, $encoding)
    if ($text -ne $existing) {
        [IO.File]::WriteAllText($gameConfigPath, $text, $encoding)
        Write-SupervisorLine "[supervisor] CONFIG_SYNCED server-and-gameplay-settings"
    }
    return $text
}

function Sync-ManagedAnnouncement {
    param([string]$GameConfigText)
    $databaseUser = Get-LegacyConfigSecret -Text $GameConfigText -Key "DB_USER_NAME"
    $databasePassword = Get-LegacyConfigSecret -Text $GameConfigText -Key "DB_USER_PASS"
    if ($databaseUser -notmatch '^[A-Za-z0-9_.@-]{1,128}$') {
        throw "The protected PangYa database username is invalid"
    }
    $magic = 1230193235
    $cleanup = @"
DELETE FROM pangya_notice_list
WHERE notice_id IN (
    SELECT arg1 FROM pangya_command
    WHERE command_id = 0 AND arg4 = $magic AND arg5 = 1
);
DELETE FROM pangya_command
WHERE command_id = 0 AND arg4 = $magic AND arg5 = 1;
"@
    if (-not $announcementEnabled) {
        Invoke-PangYaSql -Sql $cleanup -UserName $databaseUser -Password $databasePassword
        Write-SupervisorLine "[supervisor] ANNOUNCEMENT disabled"
        return
    }
    $messageHex = ConvertTo-Latin1HexLiteral $PeriodicAnnouncementText
    $sql = $cleanup + @"
INSERT INTO pangya_notice_list(message, replayCount, refreshTime)
VALUES(CONVERT($messageHex USING latin1), $PeriodicAnnouncementRepeatCount, $PeriodicAnnouncementIntervalMinutes);
SET @iris_notice_id := LAST_INSERT_ID();
INSERT INTO pangya_command(command_id, arg1, arg4, arg5, target, reserveDate, valid)
VALUES(0, @iris_notice_id, $magic, 1, $GamePort, NOW(), 1);
"@
    Invoke-PangYaSql -Sql $sql -UserName $databaseUser -Password $databasePassword
    Write-SupervisorLine ("[supervisor] ANNOUNCEMENT enabled interval_minutes={0} repetitions={1}" -f $PeriodicAnnouncementIntervalMinutes, $PeriodicAnnouncementRepeatCount)
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

function Test-LocalTcpListener {
    param([int]$Port)
    try {
        $listeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        return @($listeners | Where-Object Port -eq $Port).Count -gt 0
    }
    catch {
        return Test-TcpPort -Port $Port
    }
}

function Get-LocalTcpListenerAddresses {
    param([int]$Port)
    try {
        return @(
            [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
                Where-Object { $_.Port -eq $Port -and $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } |
                ForEach-Object { $_.Address.ToString() } |
                Sort-Object -Unique
        )
    }
    catch {
        return @()
    }
}

function Resolve-PrimaryIPv4Address {
    $client = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    try {
        $client.Connect("1.1.1.1", 53)
        $address = ([Net.IPEndPoint]$client.Client.LocalEndPoint).Address
    }
    finally {
        $client.Dispose()
    }
    if ($null -eq $address -or $address.Equals([Net.IPAddress]::Any) -or $address.Equals([Net.IPAddress]::Loopback)) {
        throw "Could not resolve the PangYa public listener address."
    }
    return $address.ToString()
}

$restartEnabled = ConvertTo-Switch $AutoRestart
$angelEvent = ConvertTo-Switch $AngelEventEnabled
$announcementEnabled = ConvertTo-Switch $PeriodicAnnouncementEnabled
$RestartLimit = [Math]::Max(0, [Math]::Min(10, $RestartLimit))
$RestartBackoffSeconds = [Math]::Max(1, [Math]::Min(60, $RestartBackoffSeconds))
$StartupTimeoutSeconds = [Math]::Max(30, [Math]::Min(900, $StartupTimeoutSeconds))
$ShutdownTimeoutSeconds = [Math]::Max(10, [Math]::Min(120, $ShutdownTimeoutSeconds))
$ServerRoot = Assert-SafePath $ServerRoot "ServerRoot"
$DatabaseClientPath = Assert-SafePath $DatabaseClientPath "DatabaseClientPath"
$DatabaseHost = $DatabaseHost.Trim()
$DatabaseName = $DatabaseName.Trim()
$ServerDisplayName = Assert-SafeDisplayText $ServerDisplayName "ServerDisplayName" 40
$ChannelName = Assert-SafeDisplayText $ChannelName "ChannelName" 64
if ($announcementEnabled) {
    $PeriodicAnnouncementText = Assert-SafeDisplayText $PeriodicAnnouncementText "PeriodicAnnouncementText" 1024
}
if ([string]::IsNullOrWhiteSpace($DatabaseHost) -or $DatabaseHost.IndexOf('"') -ge 0) { throw "DatabaseHost is invalid" }
if ([string]::IsNullOrWhiteSpace($DatabaseName) -or $DatabaseName -notmatch '^[A-Za-z0-9_]{1,64}$') { throw "DatabaseName is invalid" }
foreach ($port in @($DatabasePort, $AuthPort, $LoginPort, $GamePort, $MessagePort)) {
    if ($port -lt 1 -or $port -gt 65535) { throw "A configured port is invalid" }
}
foreach ($rate in @($PangRate, $ExperienceRate, $RareItemRate, $CookieItemRate, $ScratchyRate, $MasteryRate, $TreasureRate, $RainRate)) {
    if ($rate -lt 1 -or $rate -gt 32767) { throw "A configured PangYa rate is outside 1..32767" }
}
if ($ChannelMaxUsers -lt 1 -or $ChannelMaxUsers -gt 2000) { throw "ChannelMaxUsers is outside 1..2000" }
if ($ServerMaxUsers -lt 1 -or $ServerMaxUsers -gt 32767) { throw "ServerMaxUsers is outside 1..32767" }
if ($ServerPropertyMask -lt 0 -or $ServerFeatureBlockMask -lt 0 -or $ServerEventFlagMask -lt 0 -or $ServerEventFlagMask -gt 32767) {
    throw "A configured PangYa property or flag mask is invalid"
}
if ($ServerIcon -lt 0 -or $ServerIcon -gt 32767) { throw "ServerIcon is outside 0..32767" }
if ($PeriodicAnnouncementRepeatCount -lt 1 -or $PeriodicAnnouncementRepeatCount -gt 1000000) { throw "PeriodicAnnouncementRepeatCount is outside 1..1000000" }
if ($PeriodicAnnouncementIntervalMinutes -lt 1 -or $PeriodicAnnouncementIntervalMinutes -gt 10080) { throw "PeriodicAnnouncementIntervalMinutes is outside 1..10080" }

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
        ListenerAddress = ""
        Process = $process
        StdoutTask = $process.StandardOutput.ReadLineAsync()
        StderrTask = $process.StandardError.ReadLineAsync()
    }
    $script:services += $state
    Write-SupervisorLine ("[supervisor] STARTED service={0} pid={1} port={2}" -f $state.Name, $process.Id, $state.Port)
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
                    Write-SupervisorLine ("[{0}] OUTPUT_READ_FAILED {1}" -f $stream.Prefix, $_.Exception.Message)
                    $line = $null
                }
                if ($null -eq $line) {
                    $state.($stream.TaskProperty) = $null
                    break
                }
                Write-SupervisorLine ("[{0}] {1}" -f $stream.Prefix, $line)
                $task = $stream.Reader.ReadLineAsync()
                $state.($stream.TaskProperty) = $task
            }
        }
    }
}

function Wait-ServiceListener {
    param([string]$ServiceName, [int]$Port, [DateTime]$Deadline)
    do {
        Drain-ServiceOutput
        $state = $script:services | Where-Object Name -eq $ServiceName | Select-Object -First 1
        if ($null -eq $state -or $state.Process.HasExited) { return $null }
        $addresses = @(Get-LocalTcpListenerAddresses -Port $Port)
        if ($addresses.Count -gt 0) { return [string]$addresses[0] }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $Deadline)
    return $null
}

function Start-PortRelay {
    param([string]$ListenAddress, [object[]]$Routes, [DateTime]$Deadline)
    if ($Routes.Count -eq 0) { return }
    $relayPath = Join-Path $PSScriptRoot "pangya-port-relay.ps1"
    if (-not (Test-Path -LiteralPath $relayPath -PathType Leaf)) {
        throw "The PangYa managed port relay is missing."
    }
    $routesJson = ConvertTo-Json -InputObject $Routes -Depth 3 -Compress
    $routesBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($routesJson))
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.Arguments = ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ListenAddress "{1}" -RoutesBase64 "{2}"' -f $relayPath, $ListenAddress, $routesBase64)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Could not start the PangYa managed port relay" }
    $state = [pscustomobject]@{
        Name = "relay"
        Port = 0
        ListenerAddress = $ListenAddress
        Process = $process
        StdoutTask = $process.StandardOutput.ReadLineAsync()
        StderrTask = $process.StandardError.ReadLineAsync()
    }
    $script:services += $state
    Write-SupervisorLine ("[supervisor] STARTED service=relay pid={0} routes={1}" -f $process.Id, $Routes.Count)
    foreach ($route in $Routes) {
        do {
            Drain-ServiceOutput
            if ($process.HasExited) { throw "The PangYa managed port relay exited during startup" }
            if (Test-TcpPort -HostName $ListenAddress -Port ([int]$route.listen_port)) { break }
            Start-Sleep -Milliseconds 200
        } while ([DateTime]::UtcNow -lt $Deadline)
        if (-not (Test-TcpPort -HostName $ListenAddress -Port ([int]$route.listen_port))) {
            throw "The PangYa managed port relay did not open TCP port $($route.listen_port)"
        }
    }
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
        $listenerAddress = Wait-ServiceListener -ServiceName $definition.Name -Port $definition.Port -Deadline $deadline
        if ([string]::IsNullOrWhiteSpace($listenerAddress)) {
            throw "PangYa $($definition.Name) service did not open TCP port $($definition.Port)"
        }
        ($script:services | Where-Object Name -eq $definition.Name | Select-Object -First 1).ListenerAddress = $listenerAddress
    }
    $publicAddress = Resolve-PrimaryIPv4Address
    $routes = @(
        foreach ($definition in $serviceDefinitions | Where-Object Name -ne "auth") {
            $state = $script:services | Where-Object Name -eq $definition.Name | Select-Object -First 1
            if ($state.ListenerAddress -notin @("0.0.0.0", $publicAddress)) {
                [pscustomobject]@{
                    listen_port = [int]$definition.Port
                    target_address = [string]$state.ListenerAddress
                    target_port = [int]$definition.Port
                }
            }
        }
    )
    if ($routes.Count -gt 0) {
        Start-PortRelay -ListenAddress $publicAddress -Routes $routes -Deadline $deadline
    }
    $script:setStartedAt = [DateTime]::UtcNow
    Write-SupervisorLine ("[supervisor] READY auth={0} login={1} game={2} message={3}" -f $AuthPort, $LoginPort, $GamePort, $MessagePort)
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
        $ready = Test-LocalTcpListener -Port $definition.Port
        "{0}_running={1} {0}_ready={2}" -f $definition.Name, $running.ToString().ToLowerInvariant(), $ready.ToString().ToLowerInvariant()
    }
    [Console]::WriteLine(("[supervisor] STATUS {0}" -f ($parts -join " ")))
}

try {
    Write-SupervisorLine ("[supervisor] ROOT {0} database={1}:{2}/{3}" -f $ServerRoot, $DatabaseHost, $DatabasePort, $DatabaseName)
    if (-not (Test-TcpPort -HostName $DatabaseHost -Port $DatabasePort -TimeoutMilliseconds 1000)) {
        throw "Laragon MySQL is unavailable at ${DatabaseHost}:$DatabasePort"
    }
    Assert-RuntimeIntegrity
    $gameConfigText = Sync-GameServerConfiguration
    Sync-ManagedAnnouncement -GameConfigText $gameConfigText
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
    Write-SupervisorLine ("[supervisor] FATAL type={0} message={1}" -f $_.Exception.GetType().FullName, $_.Exception.Message)
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        Write-SupervisorLine ("[supervisor] FATAL_STACK {0}" -f ($_.ScriptStackTrace -replace "[\r\n]+", " | "))
    }
    $script:exitCode = 1
}
finally {
    Stop-ServiceSet
}

exit $script:exitCode
