function Get-NextServerPort {
    # Returns the first port >= BasePort not already used by any registered server
    param([int]$BasePort = 27016)

    $usedPorts = [System.Collections.Generic.HashSet[int]]::new()

    $servers = @(Get-ServerRegistry)
    foreach ($s in $servers) {
        $managerCfgPath = Join-Path (Join-Path $s.Path "manager") "config.json"
        if (Test-Path $managerCfgPath) {
            try {
                $mc = Get-Content $managerCfgPath -Raw | ConvertFrom-Json
                if ($mc.Port -and [int]$mc.Port -gt 0) {
                    $usedPorts.Add([int]$mc.Port) | Out-Null
                }
            } catch { }
        }
    }

    $port = $BasePort
    while ($usedPorts.Contains($port)) { $port++ }
    return $port
}

function Get-PreferredLocalIP {
    # Return the IP of the adapter that has a default gateway, excluding virtual adapters
    try {
        $configs = Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq 'Up' }
        $real = $configs | Where-Object {
            $_.InterfaceAlias -notmatch 'VirtualBox|Hyper-V|VMware|vEthernet|Loopback'
        }
        $chosen = if ($real) { $real | Select-Object -First 1 } else { $configs | Select-Object -First 1 }
        if ($chosen -and $chosen.IPv4Address) {
            return $chosen.IPv4Address.IPAddress
        }
    }
    catch {
        Write-Log "Could not detect preferred local IP: $_" "WARNING"
    }
    return $null
}

function Get-GameMetadata {
    param([string]$Game)
    $path = Join-Path $RootPath "games\$Game\metadata.json"
    if (-not (Test-Path $path)) {
        Write-Log "Game metadata not found: $path" "ERROR"
        return $null
    }
    try {
        return Get-Content $path -Raw | ConvertFrom-Json
    }
    catch {
        Write-Log "Failed to read game metadata: $_" "ERROR"
        return $null
    }
}

function Get-ServerManagerConfig {
    param([string]$ManagerPath)
    $path = Join-Path $ManagerPath "config.json"
    if (-not (Test-Path $path)) { return $null }
    try {
        return Get-Content $path -Raw | ConvertFrom-Json
    }
    catch {
        Write-Log "Failed to read manager config: $_" "WARNING"
        return $null
    }
}

# Read a single value from manager config, fallback to metadata default, then to hardcoded fallback
function Resolve-ServerParam {
    param(
        $ManagerConfig,
        [string]$Field,
        $MetadataDefault,
        $HardcodedDefault
    )
    if ($ManagerConfig -and (Get-Member -InputObject $ManagerConfig -Name $Field -MemberType NoteProperty)) {
        $val = $ManagerConfig.$Field
        if ($val -ne $null -and "$val" -ne "") { return $val }
    }
    if ($MetadataDefault -ne $null -and "$MetadataDefault" -ne "") { return $MetadataDefault }
    return $HardcodedDefault
}

function Build-LaunchArgs {
    param(
        $Metadata,
        $ManagerConfig
    )

    $argList = [System.Collections.Generic.List[string]]::new()

    # Fixed args per game (e.g. -console)
    if ($Metadata.DefaultLaunchArgs) {
        foreach ($a in $Metadata.DefaultLaunchArgs) { $argList.Add($a) }
    }

    # -game uses GameId (the Source Engine game identifier)
    $gameId = if ($Metadata.GameId) { $Metadata.GameId } else { $Metadata.GameFolder }
    $argList.Add("-game $gameId")

    # Map: config.json -> metadata default -> "c1m4_atrium"
    $map = Resolve-ServerParam -ManagerConfig $ManagerConfig -Field "Map" `
        -MetadataDefault $Metadata.DefaultMap -HardcodedDefault "c1m4_atrium"
    $argList.Add("+map $map")

    # GameMode: config.json -> metadata default -> "coop"
    $gameMode = Resolve-ServerParam -ManagerConfig $ManagerConfig -Field "GameMode" `
        -MetadataDefault $Metadata.DefaultGameMode -HardcodedDefault "coop"
    $argList.Add("+mp_gamemode $gameMode")

    # Port: config.json -> metadata default -> 27016
    $port = [int](Resolve-ServerParam -ManagerConfig $ManagerConfig -Field "Port" `
        -MetadataDefault $Metadata.DefaultGamePort -HardcodedDefault 27016)
    $argList.Add("-port $port")

    # IP binding: config.json LaunchIp -> skip if empty
    $ip = if ($ManagerConfig -and $ManagerConfig.LaunchIp) { $ManagerConfig.LaunchIp } else { "" }
    if ($ip -eq "auto") {
        $detected = Get-PreferredLocalIP
        if ($detected) {
            $argList.Add("-ip $detected")
            Write-Log "Auto-detected IP for server binding: $detected" "INFO"
        }
    }
    elseif ($ip -ne "") {
        $argList.Add("-ip $ip")
    }

    # Extra args: config.json ExtraArgs array
    if ($ManagerConfig -and $ManagerConfig.ExtraArgs) {
        foreach ($a in $ManagerConfig.ExtraArgs) { $argList.Add($a) }
    }

    return $argList.ToArray()
}

function Build-ServerLaunchCommand {
    param(
        [string]$InstallPath,
        [string]$ManagerPath,
        [string]$Game
    )

    $metadata      = Get-GameMetadata       -Game $Game
    $managerConfig = Get-ServerManagerConfig -ManagerPath $ManagerPath

    if (-not $metadata) { return $null }

    $executableName = if ($metadata.Executable) { $metadata.Executable } else { "srcds.exe" }
    $srcdsPath = Join-Path $InstallPath $executableName
    if (-not (Test-Path $srcdsPath)) {
        Write-Log "Server executable not found at: $srcdsPath" "ERROR"
        return $null
    }

    $launchArgs = Build-LaunchArgs -Metadata $metadata -ManagerConfig $managerConfig

    # Read effective values for reference (callers may need them)
    $effectiveMap      = Resolve-ServerParam -ManagerConfig $managerConfig -Field "Map"      -MetadataDefault $metadata.DefaultMap      -HardcodedDefault "c1m4_atrium"
    $effectiveGameMode = Resolve-ServerParam -ManagerConfig $managerConfig -Field "GameMode" -MetadataDefault $metadata.DefaultGameMode -HardcodedDefault "coop"
    $effectivePort     = [int](Resolve-ServerParam -ManagerConfig $managerConfig -Field "Port" -MetadataDefault $metadata.DefaultGamePort -HardcodedDefault 27016)

    return @{
        Executable = $srcdsPath
        Arguments  = $launchArgs -join " "
        ArgsArray  = $launchArgs
        Map        = $effectiveMap
        GameMode   = $effectiveGameMode
        Port       = $effectivePort
    }
}

function Get-ServerLaunchBatch {
    param(
        [string]$InstallPath,
        [string]$ManagerPath,
        [string]$Game,
        [string]$OutputPath
    )

    $cmd = Build-ServerLaunchCommand -InstallPath $InstallPath -ManagerPath $ManagerPath -Game $Game

    if (-not $cmd) { return $false }

    $serverDir = Split-Path $cmd.Executable -Parent

    $batchContent  = "@echo off`r`n"
    $batchContent += "REM Generated by Source Server Manager`r`n"
    $batchContent += "REM Game: $Game`r`n"
    $batchContent += "REM Map: $($cmd.Map)`r`n"
    $batchContent += "REM GameMode: $($cmd.GameMode)`r`n"
    $batchContent += "REM Port: $($cmd.Port)`r`n"
    $batchContent += "`r`n"
    $batchContent += "cd /d `"$serverDir`"`r`n"
    $batchContent += "`r`n"
    $batchContent += "`"$($cmd.Executable)`" $($cmd.Arguments)`r`n"
    $batchContent += "`r`n"
    $batchContent += "pause`r`n"

    Set-Content -Path $OutputPath -Value $batchContent -Encoding ASCII
    Write-Log "Launch batch created: $OutputPath" "INFO"
    return $true
}

Export-ModuleMember -Function `
    Build-ServerLaunchCommand, `
    Get-ServerLaunchBatch, `
    Build-LaunchArgs, `
    Get-GameMetadata, `
    Get-ServerManagerConfig, `
    Get-PreferredLocalIP, `
    Get-NextServerPort, `
    Resolve-ServerParam
