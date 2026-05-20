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
    $defaults = [PSCustomObject]@{ RconPassword = ""; Notes = ""; LaunchIp = ""; ExtraArgs = @() }
    $path = Join-Path $ManagerPath "config.json"
    if (-not (Test-Path $path)) { return $defaults }
    try {
        $mc = Get-Content $path -Raw | ConvertFrom-Json
        # Fill any missing fields with defaults
        if (-not (Get-Member -InputObject $mc -Name "LaunchIp"  -MemberType NoteProperty)) {
            $mc | Add-Member -NotePropertyName "LaunchIp"  -NotePropertyValue "" -Force
        }
        if (-not (Get-Member -InputObject $mc -Name "ExtraArgs" -MemberType NoteProperty)) {
            $mc | Add-Member -NotePropertyName "ExtraArgs" -NotePropertyValue @() -Force
        }
        return $mc
    }
    catch {
        Write-Log "Failed to read manager config: $_" "WARNING"
        return $defaults
    }
}

function Build-LaunchArgs {
    param(
        $Metadata,
        $ManagerConfig,
        [string]$Map,
        [string]$GameMode,
        [int]$Port
    )

    $args = [System.Collections.Generic.List[string]]::new()

    # -game <folder> from metadata
    $args.Add("-game $($Metadata.GameFolder)")

    # Fixed args defined per-game in metadata
    if ($Metadata.DefaultLaunchArgs) {
        foreach ($a in $Metadata.DefaultLaunchArgs) { $args.Add($a) }
    }

    # Map and game mode
    if ($Map)      { $args.Add("+map $Map") }
    if ($GameMode) { $args.Add("+mp_gamemode $GameMode") }

    # Port
    if ($Port -gt 0) { $args.Add("-port $Port") }

    # IP binding
    $ip = if ($ManagerConfig -and $ManagerConfig.LaunchIp) { $ManagerConfig.LaunchIp } else { "" }
    if ($ip -eq "auto") {
        $detected = Get-PreferredLocalIP
        if ($detected) {
            $args.Add("-ip $detected")
            Write-Log "Auto-detected IP for server binding: $detected" "INFO"
        }
    }
    elseif ($ip -ne "") {
        $args.Add("-ip $ip")
    }

    # Extra args from server-specific config
    if ($ManagerConfig -and $ManagerConfig.ExtraArgs) {
        foreach ($a in $ManagerConfig.ExtraArgs) { $args.Add($a) }
    }

    return $args.ToArray()
}

function Build-ServerLaunchCommand {
    param(
        [string]$InstallPath,
        [string]$ManagerPath,
        [string]$Game,
        [string]$Map,
        [string]$GameMode,
        [int]$Port = 27015
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

    $launchArgs = Build-LaunchArgs `
        -Metadata      $metadata `
        -ManagerConfig $managerConfig `
        -Map           $Map `
        -GameMode      $GameMode `
        -Port          $Port

    return @{
        Executable = $srcdsPath
        Arguments  = $launchArgs -join " "
        ArgsArray  = $launchArgs
        Map        = $Map
        GameMode   = $GameMode
        Port       = $Port
    }
}

function Get-ServerLaunchBatch {
    param(
        [string]$InstallPath,
        [string]$ManagerPath,
        [string]$Game,
        [string]$GameMode,
        [string]$Map,
        [int]$Port = 27015,
        [string]$OutputPath
    )

    $cmd = Build-ServerLaunchCommand `
        -InstallPath $InstallPath `
        -ManagerPath $ManagerPath `
        -Game        $Game `
        -GameMode    $GameMode `
        -Map         $Map `
        -Port        $Port

    if (-not $cmd) { return $false }

    $serverDir = Split-Path $cmd.Executable -Parent

    $batchContent = "@echo off`r`n"
    $batchContent += "REM Generated by Source Server Manager`r`n"
    $batchContent += "REM Game: $Game`r`n"
    $batchContent += "REM GameMode: $GameMode`r`n"
    $batchContent += "REM Map: $Map`r`n"
    $batchContent += "REM Port: $Port`r`n"
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
    Get-PreferredLocalIP
