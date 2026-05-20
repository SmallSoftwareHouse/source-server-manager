function Generate-ServerCfg {
    param(
        [string]$ServerId
    )

    Write-Log "Generating server.cfg for server: $ServerId"

    $server = Get-ServerById $ServerId

    if (-not $server) {
        Write-Log "Server not found: $ServerId" "ERROR"
        return $false
    }

    $templatePath = Join-Path $RootPath "games\$($server.Game)\templates\server.cfg"

    if (-not (Test-Path $templatePath)) {
        Write-Log "Template not found: $templatePath" "ERROR"
        return $false
    }

    $gameMetadata = $null
    $metaFile = Join-Path $RootPath "games\$($server.Game)\metadata.json"
    if (Test-Path $metaFile) {
        try { $gameMetadata = Get-Content $metaFile -Raw | ConvertFrom-Json } catch { }
    }
    $gameFolder = if ($gameMetadata -and $gameMetadata.GameFolder) { $gameMetadata.GameFolder } else { $server.Game }
    $cfgPath = Join-Path (Join-Path $server.Path "server") "$gameFolder\cfg\server.cfg"

    $cfgDirectory = Split-Path $cfgPath -Parent

    if (-not (Test-Path $cfgDirectory)) {
        New-Item -ItemType Directory -Path $cfgDirectory -Force | Out-Null
    }

    $cfgContent = Get-Content $templatePath -Raw -Encoding UTF8

    $rconPassword = ""
    $managerConfig = Join-Path (Join-Path $server.Path "manager") "config.json"
    if (Test-Path $managerConfig) {
        try {
            $mc = Get-Content $managerConfig -Raw | ConvertFrom-Json
            if ($mc.RconPassword) { $rconPassword = $mc.RconPassword }
        } catch { }
    }

    $cfgContent = $cfgContent.Replace("{{HOSTNAME}}", $server.Name)
    $cfgContent = $cfgContent.Replace("{{RCON_PASSWORD}}", $rconPassword)
    $cfgContent = $cfgContent.Replace("{{SEARCH_KEY}}", "")
    $cfgContent = $cfgContent.Replace("{{STEAM_GROUP}}", "")

    Set-Content `
        -Path $cfgPath `
        -Value $cfgContent `
        -Encoding UTF8

    Write-Log "server.cfg generated successfully: $cfgPath"

    return $true
}

function Generate-ServerMarker {
    param(
        [string]$ServerId
    )

    Write-Log "Generating server marker for server: $ServerId"

    $server = Get-ServerById $ServerId

    if (-not $server) {
        Write-Log "Server not found: $ServerId" "ERROR"
        return $false
    }

    $markerPath = Join-Path (Join-Path $server.Path "manager") "server_marker.cfg"

    $content = @"
managed=1
server_id=$($server.ServerId)
game=$($server.Game)
name=$($server.Name)
created_at=$($server.CreatedAt)
last_update=$($server.LastUpdate)
"@

    Set-Content -Path $markerPath -Value $content -Encoding UTF8

    Write-Log "server_marker.cfg generated: $markerPath"

    return $true
}

function Select-ServerMapAndGameMode {
    param(
        [string]$GameType
    )

    $gamesDir = Join-Path $RootPath "games\$GameType\configs"

    $mapsFile = Join-Path $gamesDir "maps.json"
    if (-not (Test-Path $mapsFile)) {
        Write-Host "`n$(Get-Message -Key 'Config_MapsNotFound')`n" -ForegroundColor Red
        return $null
    }

    $mapsData = Get-Content $mapsFile -Raw | ConvertFrom-Json
    $maps = if ($mapsData -is [array]) { $mapsData } else { @($mapsData) }

    $gamemodesFile = Join-Path $gamesDir "gamemodes.json"
    if (-not (Test-Path $gamemodesFile)) {
        Write-Host "`n$(Get-Message -Key 'Config_GamemodesNotFound')`n" -ForegroundColor Red
        return $null
    }

    $gamemodesData = Get-Content $gamemodesFile -Raw | ConvertFrom-Json
    $gamemodes = if ($gamemodesData -is [array]) { $gamemodesData } else { @($gamemodesData) }

    Write-Host "`n$(Get-Message -Key 'Config_SelectGameMode'):`n"
    for ($i = 0; $i -lt $gamemodes.Count; $i++) {
        $num = $i + 1
        $gm = $gamemodes[$i]
        Write-Host "  $num) $($gm.name) - $($gm.description)"
    }
    Write-Host ""

    $gmSel = Read-Host (Get-Message -Key "Common_SelectNumber")
    if ([string]::IsNullOrWhiteSpace($gmSel)) { return $null }

    $gmIdx = [int]$gmSel - 1
    if ($gmIdx -lt 0 -or $gmIdx -ge $gamemodes.Count) {
        Write-Host "`n$(Get-Message -Key 'Common_InvalidSelection')`n" -ForegroundColor Red
        return $null
    }

    $selectedGameMode = $gamemodes[$gmIdx]

    Write-Host "`n$(Get-Message -Key 'Config_SelectMap'):`n"
    for ($i = 0; $i -lt $maps.Count; $i++) {
        $num = $i + 1
        $map = $maps[$i]
        Write-Host "  $num) $($map.name) -- $($map.campaign)"
    }
    Write-Host ""

    $mapSel = Read-Host (Get-Message -Key "Common_SelectNumber")
    if ([string]::IsNullOrWhiteSpace($mapSel)) { return $null }

    $mapIdx = [int]$mapSel - 1
    if ($mapIdx -lt 0 -or $mapIdx -ge $maps.Count) {
        Write-Host "`n$(Get-Message -Key 'Common_InvalidSelection')`n" -ForegroundColor Red
        return $null
    }

    $selectedMap = $maps[$mapIdx]

    return @{
        GameMode = $selectedGameMode.id
        GameModeName = $selectedGameMode.name
        Map = $selectedMap.id
        MapName = $selectedMap.name
    }
}

function Initialize-ServerConfiguration {
    param(
        [string]$ServerId
    )

    Write-Log "Initializing server configuration for: $ServerId"

    $server = Get-ServerById $ServerId
    if (-not $server) {
        Write-Log "Server not found: $ServerId" "ERROR"
        return $false
    }

    $config = Select-ServerMapAndGameMode -GameType $server.Game
    if (-not $config) {
        Write-Log "Configuration selection cancelled for: $ServerId" "INFO"
        return $false
    }

    # Write Map, GameMode (and Port if not already set) to manager/config.json
    $managerPath   = Join-Path $server.Path "manager"
    $managerCfgPath = Join-Path $managerPath "config.json"
    $managerCfg = if (Test-Path $managerCfgPath) {
        try { Get-Content $managerCfgPath -Raw | ConvertFrom-Json } catch { [PSCustomObject]@{} }
    } else { [PSCustomObject]@{} }

    $managerCfg | Add-Member -NotePropertyName "Map"      -NotePropertyValue $config.Map      -Force
    $managerCfg | Add-Member -NotePropertyName "GameMode" -NotePropertyValue $config.GameMode -Force

    # Set Port from metadata default if not already configured
    if (-not (Get-Member -InputObject $managerCfg -Name "Port" -MemberType NoteProperty) -or -not $managerCfg.Port) {
        $metaFile = Join-Path $RootPath "games\$($server.Game)\metadata.json"
        $defaultPort = 27016
        if (Test-Path $metaFile) {
            try { $defaultPort = (Get-Content $metaFile -Raw | ConvertFrom-Json).DefaultGamePort } catch { }
        }
        $managerCfg | Add-Member -NotePropertyName "Port" -NotePropertyValue $defaultPort -Force
    }

    $managerCfg | ConvertTo-Json | Set-Content $managerCfgPath -Encoding UTF8
    Write-Log "manager/config.json updated - Map: $($config.Map), GameMode: $($config.GameMode)" "INFO"

    $cfgResult    = Generate-ServerCfg    -ServerId $ServerId
    $markerResult = Generate-ServerMarker -ServerId $ServerId

    if (-not $cfgResult -or -not $markerResult) {
        Write-Log "Initialization failed for server: $ServerId" "ERROR"
        return $false
    }

    $batchPath    = Join-Path $managerPath "start_server.bat"
    $launchResult = Get-ServerLaunchBatch `
        -InstallPath (Join-Path $server.Path "server") `
        -ManagerPath $managerPath `
        -Game        $server.Game `
        -OutputPath  $batchPath

    if (-not $launchResult) {
        Write-Log "Failed to create launch batch for: $ServerId" "ERROR"
        return $false
    }

    $registry = @(Get-ServerRegistry)
    foreach ($s in $registry) {
        if ($s.ServerId -eq $ServerId) {
            $s.Status = "Installed"
            $s | Add-Member -NotePropertyName "ConfiguredMap"      -NotePropertyValue $config.Map      -Force
            $s | Add-Member -NotePropertyName "ConfiguredGameMode" -NotePropertyValue $config.GameMode -Force
            $s.LastUpdate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    Save-ServerRegistry $registry

    $logMsg = "Server configuration initialized - Map: $($config.Map), GameMode: $($config.GameMode)"
    Write-Log $logMsg "INFO"

    return $true
}

function Update-ServerMapAndGameMode {
    param(
        [string]$ServerId
    )

    Write-Log "Updating map/gamemode for server: $ServerId"

    $server = Get-ServerById $ServerId
    if (-not $server) {
        Write-Log "Server not found: $ServerId" "ERROR"
        return $false
    }

    if ($server.Status -ne "Configured") {
        Write-Host "`n$(Get-Message -Key 'Config_NotConfigured')`n" -ForegroundColor Red
        return $false
    }

    $config = Select-ServerMapAndGameMode -GameType $server.Game
    if (-not $config) {
        Write-Log "Update cancelled for: $ServerId" "INFO"
        return $false
    }

    # Update Map and GameMode in manager/config.json
    $managerPath2    = Join-Path $server.Path "manager"
    $managerCfgPath2 = Join-Path $managerPath2 "config.json"
    $managerCfg2 = if (Test-Path $managerCfgPath2) {
        try { Get-Content $managerCfgPath2 -Raw | ConvertFrom-Json } catch { [PSCustomObject]@{} }
    } else { [PSCustomObject]@{} }

    $managerCfg2 | Add-Member -NotePropertyName "Map"      -NotePropertyValue $config.Map      -Force
    $managerCfg2 | Add-Member -NotePropertyName "GameMode" -NotePropertyValue $config.GameMode -Force
    $managerCfg2 | ConvertTo-Json | Set-Content $managerCfgPath2 -Encoding UTF8
    Write-Log "manager/config.json updated - Map: $($config.Map), GameMode: $($config.GameMode)" "INFO"

    # Regenerate start_server.bat with new values
    $batchPath2 = Join-Path $managerPath2 "start_server.bat"
    Get-ServerLaunchBatch `
        -InstallPath (Join-Path $server.Path "server") `
        -ManagerPath $managerPath2 `
        -Game        $server.Game `
        -OutputPath  $batchPath2 | Out-Null

    $cfgResult = Generate-ServerCfg -ServerId $ServerId

    if (-not $cfgResult) {
        Write-Log "Update failed for server: $ServerId" "ERROR"
        return $false
    }

    $registry = @(Get-ServerRegistry)
    foreach ($s in $registry) {
        if ($s.ServerId -eq $ServerId) {
            $s | Add-Member -NotePropertyName "ConfiguredMap"      -NotePropertyValue $config.Map      -Force
            $s | Add-Member -NotePropertyName "ConfiguredGameMode" -NotePropertyValue $config.GameMode -Force
            $s.LastUpdate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    Save-ServerRegistry $registry

    Write-Log "Server updated - Map: $($config.Map), GameMode: $($config.GameMode)"

    return $true
}

Export-ModuleMember -Function Generate-ServerCfg, Generate-ServerMarker, Initialize-ServerConfiguration, Update-ServerMapAndGameMode, Select-ServerMapAndGameMode
