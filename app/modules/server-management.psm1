# Module-level state (session caches and tracking)
$script:_PubIPCache    = $null
$script:_PubIPCacheAge = $null
$script:_StartedThisSession = @()

function Get-ShortPath {
    param([string]$Path, [string]$RootPath)
    $prefix = $RootPath + "\"
    if ($Path.StartsWith($prefix)) {
        return $Path.Substring($prefix.Length)
    }
    return $Path
}

function Find-UnregisteredServers {
    # Scans DefaultInstallRoot for server folders (managed or flat) not in registry.
    param([string]$DefaultInstallRoot)

    $basePath = $DefaultInstallRoot
    $registry = @(Get-ServerRegistry)

    # Collect all paths already registered (Path and GamePath)
    $regPaths = @($registry | ForEach-Object {
        if ($_.Path)     { $_.Path.TrimEnd('\').ToLower() }
        if ($_.GamePath) { $_.GamePath.TrimEnd('\').ToLower() }
    })

    $orphans = @()

    if (-not (Test-Path $basePath)) { return $orphans }

    $subs = @(Get-ChildItem -Path $basePath -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            (-not ($_.Attributes -band [System.IO.FileAttributes]::Hidden)) -and
            (-not ($_.Attributes -band [System.IO.FileAttributes]::System))
        })

    foreach ($sub in $subs) {
        $structType = Test-ServerStructure -Path $sub.FullName
        if ($null -eq $structType) { continue }
        $normPath = $sub.FullName.TrimEnd('\').ToLower()
        if ($regPaths -contains $normPath) { continue }
        $orphans += [PSCustomObject]@{ Path = $sub.FullName; Type = $structType }
    }

    return $orphans
}

function Invoke-ListServers {
    param([string]$DefaultInstallRoot)

    Show-Header
    Write-Host (Format-SectionTitle (Get-Message -Key "List_Title"))
    Write-Host ""

    Validate-ServerRegistry | Out-Null
    $servers = @(Get-ServerRegistry)

    if ($servers.Count -eq 0) {
        Write-Host "$(Get-Message -Key 'Common_NoServersRegistered')`n"
    }
    else {
        foreach ($s in $servers) {
            $disk = Get-ServerDiskStatus -Path (Get-GamePath $s)
            $instFile = Join-Path (Get-ManagerPath $s) ".installing"
            $activeDl = $false
            if (($s.Status -eq "Installing") -and (Test-Path $instFile)) {
                try { $d = Get-Content $instFile -Raw | ConvertFrom-Json; $activeDl = $null -ne (Get-Process -Id $d.InstallerPID -ErrorAction SilentlyContinue) } catch {}
                if (-not $activeDl) { Remove-Item $instFile -Force -ErrorAction SilentlyContinue }
            }

            if ($disk -eq "Installed" -and $s.Status -eq "Installed") {
                $symbol = "[OK]"; $color = "Green"
            } elseif ($activeDl) {
                $symbol = "[>>]"; $color = "Cyan"
            } elseif ($s.Status -eq "Installing") {
                $symbol = "[!!]"; $color = "Yellow"
            } elseif ($disk -eq "Missing") {
                $symbol = "[--]"; $color = "Red"
            } else {
                $symbol = "[!!]"; $color = "Yellow"
            }

            Write-Host "$symbol " -NoNewline -ForegroundColor $color
            Write-Host (Get-Message -Key "List_Name" -MsgArgs @($s.Name))
            Write-Host (Get-Message -Key "List_Path"     -MsgArgs @($s.Path))
            Write-Host (Get-Message -Key "List_Game"     -MsgArgs @($s.Game))
            Write-Host (Get-Message -Key "List_Registry" -MsgArgs @($s.Status))
            Write-Host (Get-Message -Key "List_Disk"     -MsgArgs @($disk))
            Write-Host (Get-Message -Key "List_Created"  -MsgArgs @($s.CreatedAt))
            Write-Host ""
        }
    }

    Read-Host (Get-Message -Key "Common_PressEnter")
}


function Register-UnregisteredServers {
    # Batch-registers a list of orphan server candidates (output of Find-UnregisteredServers).
    param([array]$Orphans)

    Write-Host ""
    Write-Host (Get-Message -Key "Scan_Registering") -ForegroundColor Cyan
    $count = 0

    foreach ($o in $Orphans) {
        $folderName  = Split-Path -Leaf $o.Path
        $isFlat      = ($o.Type -eq "flat")
        $gamePath    = Join-Path $o.Path "server"
        $managerPath = Join-Path $o.Path "manager"

        if (Get-ServerByName -Name $folderName) {
            Write-Host "  [SKIP] $folderName -- $(Get-Message -Key 'Recover_NameExists')" -ForegroundColor DarkGray
            continue
        }

        if ($isFlat) {
            try {
                New-Item -ItemType Directory -Path $gamePath    -Force -ErrorAction Stop | Out-Null
                New-Item -ItemType Directory -Path $managerPath -Force -ErrorAction Stop | Out-Null
                $items = @(Get-ChildItem -Path $o.Path -ErrorAction Stop |
                    Where-Object { $_.Name -ne "server" -and $_.Name -ne "manager" })
                foreach ($item in $items) {
                    Move-Item -Path $item.FullName -Destination $gamePath -ErrorAction Stop
                }
            }
            catch {
                Write-Log "Ristrutturazione fallita per $folderName : $_" "ERROR"
                Write-Host "  [FAIL] $folderName -- $(Get-Message -Key 'Recover_RestructureFailed' -MsgArgs @($_))" -ForegroundColor Red
                if ((Test-Path $gamePath)    -and (Get-ChildItem $gamePath).Count    -eq 0) { Remove-Item $gamePath    -Force -ErrorAction SilentlyContinue }
                if ((Test-Path $managerPath) -and (Get-ChildItem $managerPath).Count -eq 0) { Remove-Item $managerPath -Force -ErrorAction SilentlyContinue }
                continue
            }
        }

        $existingConfig = $null
        $configFile = Join-Path $managerPath "config.json"
        if (Test-Path $configFile) {
            try { $existingConfig = Get-Content $configFile -Raw | ConvertFrom-Json } catch { }
        }

        $diskStatus = Get-ServerDiskStatus -Path $gamePath
        $regStatus  = if ($diskStatus -eq "Installed") { "Installed" } else { "Installing" }

        $entry = @{
            ServerId           = [guid]::NewGuid().ToString()
            Name               = $folderName
            Game               = if ($existingConfig -and $existingConfig.Game) { $existingConfig.Game } else { "l4d2" }
            Path               = $o.Path
            Status             = $regStatus
            FirewallPort       = if ($existingConfig -and $existingConfig.FirewallPort) { [int]$existingConfig.FirewallPort } else { Get-NextAvailablePort -BasePort 27016 }
            ConfiguredMap      = if ($existingConfig -and $existingConfig.ConfiguredMap) { $existingConfig.ConfiguredMap } else { $null }
            ConfiguredGameMode = if ($existingConfig -and $existingConfig.ConfiguredGameMode) { $existingConfig.ConfiguredGameMode } else { $null }
            CreatedAt          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            LastUpdate         = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }

        Add-ServerToRegistry $entry
        Write-Log "Server registrato: $folderName -> $($o.Path)" "INFO"
        Write-Host "  [OK] $folderName" -ForegroundColor Green
        $count++
    }

    Write-Host ""
    Write-Host (Get-Message -Key "Scan_RegisterDone" -MsgArgs @($count)) -ForegroundColor Green
    Start-Sleep -Seconds 2
}

function Invoke-RenameServer {
    param($server)

    Write-Host "`n$(Get-Message -Key 'Rename_Title')`n"
    Write-Host (Get-Message -Key "Rename_CurrentName" -MsgArgs @($server.Name))
    $newName = Read-Host (Get-Message -Key "Rename_NewNamePrompt")
    if ([string]::IsNullOrWhiteSpace($newName) -or $newName -eq $server.Name) { return $false }

    $nameError = Test-ServerName -Name $newName
    if ($nameError) {
        Write-Host "`n$nameError`n" -ForegroundColor Red
        Read-Host (Get-Message -Key "Common_PressEnter")
        return $false
    }

    if (Get-ServerByName -Name $newName) {
        Write-Host "`n$(Get-Message -Key 'Rename_NameInUse')`n" -ForegroundColor Red
        Read-Host (Get-Message -Key "Common_PressEnter")
        return $false
    }

    $registry = @(Get-ServerRegistry)
    foreach ($s in $registry) {
        if ($s.ServerId -eq $server.ServerId) {
            $s.Name = $newName
            $s.LastUpdate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    Save-ServerRegistry $registry
    Write-Log "Server rinominato: $($server.Name) -> $newName" "INFO"
    Write-Host "`n$(Get-Message -Key 'Rename_Done' -MsgArgs @($newName))`n" -ForegroundColor Green
    Read-Host (Get-Message -Key "Common_PressEnter")
    return $true
}

function Invoke-MoveServer {
    param($server, [string]$DefaultInstallRoot)

    Write-Host "`n$(Get-Message -Key 'Move_Title')`n"
    Write-Host (Get-Message -Key "Move_CurrentPath" -MsgArgs @($server.Path))
    Write-Host ""

    # Offer default folder as quick option
    $defaultBase    = $DefaultInstallRoot
    $defaultDest    = Join-Path $defaultBase $server.Name
    $defaultFreeGB  = Get-PathFreeGB -Path $defaultBase
    $defaultSuffix  = Get-SpaceSuffix -GB $defaultFreeGB
    $defaultColor   = Get-SpaceColor  -GB $defaultFreeGB

    Write-Host "  1) " -NoNewline
    Write-Host "$defaultDest" -NoNewline -ForegroundColor White
    Write-Host $defaultSuffix -ForegroundColor $defaultColor
    Write-Host "  2) $(Get-Message -Key 'Move_ChooseFolder')" -ForegroundColor White
    Write-Host "  0) $(Get-Message -Key 'Common_Cancel')"
    Write-Host ""

    $pick = (Read-Host (Get-Message -Key "Common_Select")).Trim()

    $chosenBase = $null
    switch ($pick) {
        "1" { $chosenBase = $defaultBase }
        "2" { $chosenBase = Select-FolderInteractive }
        "0" { return $false }
        default { return $false }
    }
    if ($null -eq $chosenBase) { return $false }

    # Append server name as subfolder (same rule as Create)
    $newPath = Join-Path $chosenBase $server.Name

    if ($newPath -eq $server.Path) {
        Write-Host "`n$(Get-Message -Key 'Move_SamePath')`n" -ForegroundColor Yellow
        Read-Host (Get-Message -Key "Common_PressEnter")
        return $false
    }

    if (Test-Path $newPath) {
        Write-Host "`n$(Get-Message -Key 'Move_DestExists')`n" -ForegroundColor Red
        Read-Host (Get-Message -Key "Common_PressEnter")
        return $false
    }

    Write-Host ""
    Write-Host "  $($server.Path)" -ForegroundColor DarkGray
    Write-Host "  -> $newPath" -ForegroundColor Cyan
    Write-Host ""
    $confirm = Read-Host (Get-Message -Key "Common_ConfirmPrompt")
    if ($confirm -ne (Get-Message -Key "ConfirmYes")) { return $false }

    Write-Host "`n$(Get-Message -Key 'Move_InProgress')" -ForegroundColor Cyan

    try {
        Move-Item -Path $server.Path -Destination $newPath -ErrorAction Stop

        $registry = @(Get-ServerRegistry)
        foreach ($s in $registry) {
            if ($s.ServerId -eq $server.ServerId) {
                $s.Path = $newPath
                $s.LastUpdate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
        Save-ServerRegistry $registry
        Write-Log "Server spostato: $($server.Path) -> $newPath" "INFO"
        Write-Host "$(Get-Message -Key 'Move_Done')`n" -ForegroundColor Green
        Read-Host (Get-Message -Key "Common_PressEnter")
        return $true
    }
    catch {
        Write-Log "Errore spostamento: $_" "ERROR"
        Write-Host "`n$(Get-Message -Key 'Move_Failed' -MsgArgs @($_))`n" -ForegroundColor Red
        Read-Host (Get-Message -Key "Common_PressEnter")
        return $false
    }
}

function Invoke-StartServer {
    param($server, [string]$RootPath)

    Write-Host "`n$(Get-Message -Key 'Start_Title' -MsgArgs @($server.Name))`n" -ForegroundColor Cyan

    if ($server.Status -ne "Configured" -and $server.Status -ne "Installed") {
        Write-Host "`n$(Get-Message -Key 'Start_NotConfigured')`n" -ForegroundColor Yellow
        Read-Host (Get-Message -Key "Common_PressEnter")
        return $false
    }

    Write-Host "$(Get-Message -Key 'Start_SelectMode'):`n"
    Write-Host "  1) $(Get-Message -Key 'Start_NormalMode')"
    Write-Host "  2) $(Get-Message -Key 'Start_AutoRestartMode')"
    Write-Host ""

    $modeChoice = Read-Host (Get-Message -Key "Common_Select")

    if ($modeChoice -ne "1" -and $modeChoice -ne "2") {
        Write-Host "`n$(Get-Message -Key 'Common_InvalidOption')`n" -ForegroundColor Yellow
        return $false
    }

    $gamePath    = Get-GamePath    $server
    $managerPath = Get-ManagerPath $server

    # All launch params (map, gamemode, port) come from manager/config.json -> metadata defaults
    $launchCmd = Build-ServerLaunchCommand `
        -InstallPath $gamePath `
        -ManagerPath $managerPath `
        -Game        $server.Game
    $argString = if ($launchCmd) { $launchCmd.Arguments } else { "" }

    Write-Host "`n$(Get-Message -Key 'Start_Starting')`n"

    try {
        if ($modeChoice -eq "1") {
            $serverPID = Start-ServerNormal -InstallPath $gamePath -ArgString $argString

            if ($serverPID -is [int] -and $serverPID -gt 0) {
                $runningFile = Join-Path $managerPath ".running"
                @{
                    ServerPath = $server.Path
                    ServerName = $server.Name
                    ServerProcessId = $serverPID
                    StartedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                } | ConvertTo-Json | Set-Content $runningFile -Encoding UTF8
                $result = $true
            } else {
                $result = $serverPID
            }
        }
        else {
            $monitoringScript = @"
`$RootPath = '$RootPath'
`$host.ui.RawUI.WindowTitle = 'Monitoring: $($server.Name)'
Import-Module "`$RootPath\modules\server-monitor.psm1" -Force
Import-Module "`$RootPath\modules\logging.psm1" -Force
Start-ServerWithMonitoring -InstallPath '$gamePath' -ManagerPath '$managerPath' -ArgString '$argString'
"@

            $process = Start-Process powershell.exe -ArgumentList "-NoExit", "-Command", $monitoringScript -WindowStyle Normal -PassThru

            $runningFile = Join-Path $managerPath ".running"
            @{
                ServerPath = $server.Path
                ServerName = $server.Name
                PowerShellPID = $process.Id
                StartedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            } | ConvertTo-Json | Set-Content $runningFile -Encoding UTF8

            Write-Host "$(Get-Message -Key 'Start_AutoRestartActive')`n" -ForegroundColor Cyan
        }

        # Mark this server as started in the current session
        $script:_StartedThisSession = @($script:_StartedThisSession) + $server.ServerId

        Write-Log "Server avviato: $($server.Name)" "INFO"
        Write-Host "`n$(Get-Message -Key 'Start_Success')`n" -ForegroundColor Green
        Read-Host (Get-Message -Key "Common_PressEnter")
        return $true
    }
    catch {
        Write-Log "Errore avvio server: $_" "ERROR"
        Write-Host "`n$(Get-Message -Key 'Start_Failed' -MsgArgs @($_))`n" -ForegroundColor Red
        Read-Host (Get-Message -Key "Common_PressEnter")
        return $false
    }
}

function Stop-ServerMonitoring {
    param($server)

    $runningFile = Join-Path (Get-ManagerPath $server) ".running"
    if (-not (Test-Path $runningFile)) {
        Write-Host "`n$(Get-Message -Key 'Common_InvalidOption')`n" -ForegroundColor Yellow
        return $false
    }

    try {
        $runningData = Get-Content $runningFile -Raw | ConvertFrom-Json
        $psPID = $runningData.PowerShellPID
        $serverPID = $runningData.ServerProcessId

        $psProcessAlive = $false
        $serverProcessAlive = $false

        if ($serverPID) {
            $serverProcess = Get-Process -Id $serverPID -ErrorAction SilentlyContinue
            if ($serverProcess) { $serverProcessAlive = $true }
        }

        if ($psPID) {
            $psProcess = Get-Process -Id $psPID -ErrorAction SilentlyContinue
            if ($psProcess) { $psProcessAlive = $true }
        }

        if (-not $serverProcessAlive -and -not $psProcessAlive) {
            Remove-Item $runningFile -Force
            Write-Log "Server era gia chiuso: $($server.Name)" "INFO"
            Write-Host "`n$(Get-Message -Key 'Start_AlreadyStopped')`n" -ForegroundColor Yellow
            return $true
        }

        Write-Host "`n$(Get-Message -Key 'Start_Stopping')`n"

        if ($serverProcessAlive) {
            Stop-Process -Id $serverPID -Force -ErrorAction SilentlyContinue
        }

        if ($psProcessAlive) {
            Stop-Process -Id $psPID -Force -ErrorAction SilentlyContinue
        }

        Remove-Item $runningFile -Force

        Write-Log "Server arrestato: $($server.Name)" "INFO"
        Write-Host "$(Get-Message -Key 'Start_Stopped')`n" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Log "Errore arresto server: $_" "ERROR"
        Write-Host "`n$(Get-Message -Key 'Start_StopFailed' -MsgArgs @($_))`n" -ForegroundColor Red
        return $false
    }
}

function Get-CachedPublicIP {
    $now = Get-Date
    $stale = (-not $script:_PubIPCacheAge) -or
             (($now - $script:_PubIPCacheAge).TotalMinutes -gt 10)
    if ($stale) {
        try {
            $fetched = (Invoke-WebRequest -Uri "https://api.ipify.org?format=json" `
                        -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop | ConvertFrom-Json).ip
            if ($fetched) {
                $script:_PubIPCache    = $fetched
                $script:_PubIPCacheAge = $now
            }
        } catch {}
    }
    return $script:_PubIPCache
}

function Invoke-NetworkMenu {
    param(
        [object]$Selected,
        [bool]$IsRunning = $false,
        [string]$RootPath,
        $Config
    )

    $fwMeta = Get-GameMetadata -Game $Selected.Game
    $fwCfg  = Get-ServerManagerConfig -ManagerPath (Get-ManagerPath $Selected)
    $fwPort = [int](Resolve-ServerParam -ManagerConfig $fwCfg -Field "Port" `
                   -MetadataDefault ($fwMeta.DefaultGamePort) -HardcodedDefault 27016)

    while ($true) {
        # Re-check running state on each loop iteration
        $netRunFile2 = Join-Path (Get-ManagerPath $Selected) ".running"
        $IsRunning = $false
        if (Test-Path $netRunFile2) {
            try {
                $netRd2 = Get-Content $netRunFile2 -Raw | ConvertFrom-Json
                if ($netRd2.PowerShellPID) {
                    $pp2 = Get-Process -Id $netRd2.PowerShellPID -ErrorAction SilentlyContinue
                    if ($pp2 -and $pp2.ProcessName -match "powershell|pwsh") { $IsRunning = $true }
                }
                if (-not $IsRunning -and $netRd2.ServerProcessId) {
                    $sp2 = Get-Process -Id $netRd2.ServerProcessId -ErrorAction SilentlyContinue
                    if ($sp2 -and $sp2.ProcessName -like "*srcds*") { $IsRunning = $true }
                }
            } catch {}
        }

        # Fallback: if .running file is absent or stale, check via A2S_INFO query
        if (-not $IsRunning) {
            $netFbLocalIP = Get-PreferredLocalIP
            if ($netFbLocalIP) {
                $IsRunning = Test-SourceQueryReachable -IP $netFbLocalIP -Port $fwPort -TimeoutMs 1000
            }
        }

        $runTag = if ($IsRunning) { "" } else { "  $(Get-Message -Key 'Tag_ServerOff')" }

        Show-Header
        Write-Host ""
        Write-Host "  $($Selected.Name)  --  $(Get-Message -Key 'Manage_NetworkFirewall')" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  1) $(Get-Message -Key 'NetMenu_Firewall')"
        Write-Host "  2) $(Get-Message -Key 'NetMenu_Diagnostics')$runTag" -ForegroundColor $(if ($IsRunning) { "White" } else { "DarkGray" })
        Write-Host "  3) $(Get-Message -Key 'NetMenu_StartAndTest')" -ForegroundColor $(if (-not $IsRunning) { "White" } else { "DarkGray" })
        Write-Host ""
        Write-Host "  0) $(Get-Message -Key 'Manage_Back')"
        Write-Host ""

        $netChoice = Read-Host (Get-Message -Key "Common_Select")
        switch ($netChoice) {
            "1" {
                Invoke-FirewallManagement -ServerName $Selected.Name `
                    -RootPath $RootPath -Language $Config.Language -Port $fwPort
            }
            "2" {
                Invoke-NetworkDiagnostics -Server $Selected -IsRunning $IsRunning
            }
            "3" {
                if ($IsRunning) {
                    Write-Host "`n  $(Get-Message -Key 'NetMenu_AlreadyRunning')`n" -ForegroundColor Yellow
                    Read-Host (Get-Message -Key "Common_PressEnter") | Out-Null
                } else {
                    # Start server in normal mode (no monitoring window)
                    $netGamePath = Get-GamePath $Selected
                    $netMgrPath  = Get-ManagerPath $Selected
                    $netCmd      = Build-ServerLaunchCommand `
                        -InstallPath $netGamePath -ManagerPath $netMgrPath -Game $Selected.Game
                    $netArgs     = if ($netCmd) { $netCmd.Arguments } else { "" }

                    Write-Host ""
                    Write-Host "  $(Get-Message -Key 'NetMenu_Starting')..." -ForegroundColor Cyan
                    $netPID = Start-ServerNormal -InstallPath $netGamePath -ArgString $netArgs
                    if ($netPID -is [int] -and $netPID -gt 0) {
                        $netRf = Join-Path $netMgrPath ".running"
                        @{
                            ServerPath      = $Selected.Path
                            ServerName      = $Selected.Name
                            ServerProcessId = $netPID
                            StartedAt       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        } | ConvertTo-Json | Set-Content $netRf -Encoding UTF8

                        # Poll until server responds to Source queries (max 60s)
                        $netLocalIP = Get-PreferredLocalIP
                        Write-Host "  $(Get-Message -Key 'NetMenu_WaitingStartup')" -NoNewline -ForegroundColor DarkGray
                        $netReady = Wait-ServerReady -IP $netLocalIP -Port $fwPort -MaxSeconds 60
                        if ($netReady) {
                            Write-Host " [OK]" -ForegroundColor Green
                        } else {
                            Write-Host " $(Get-Message -Key 'NetMenu_StartupTimeout')" -ForegroundColor Yellow
                        }
                        Start-Sleep -Seconds 1
                        Invoke-NetworkDiagnostics -Server $Selected -IsRunning $true
                    } else {
                        Write-Host "  $(Get-Message -Key 'Start_Failed')`n" -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                }
            }
            "0" { return }
        }
    }
}

function Show-ServerStatusBox {
    param($server, [string]$RootPath)

    $gamePath    = Get-GamePath    $server
    $managerPath = Get-ManagerPath $server

    $loadingRow = [Console]::CursorTop
    Write-Host "  $(Get-Message -Key 'Common_Loading')..." -ForegroundColor DarkGray

    $disk        = Get-ServerDiskStatus -Path $gamePath
    $runningFile = Join-Path $managerPath ".running"
    $isRunning = $false

    if (Test-Path $runningFile) {
        try {
            $runningData = Get-Content $runningFile -Raw | ConvertFrom-Json
            $processFound = $false

            if ($runningData.PowerShellPID) {
                $psProc = Get-Process -Id $runningData.PowerShellPID -ErrorAction SilentlyContinue
                if ($psProc -and $psProc.ProcessName -match "powershell|pwsh") { $processFound = $true }
            }

            if (-not $processFound -and $runningData.ServerProcessId) {
                $srvProc = Get-Process -Id $runningData.ServerProcessId -ErrorAction SilentlyContinue
                # Verify the process name matches the expected game executable
                $expectedExe = "srcds"
                $chkMeta = Get-GameMetadata -Game $server.Game
                if ($chkMeta -and $chkMeta.Executable) {
                    $expectedExe = [System.IO.Path]::GetFileNameWithoutExtension($chkMeta.Executable)
                }
                if ($srvProc -and $srvProc.ProcessName -like "*$expectedExe*") { $processFound = $true }
            }

            if ($processFound) {
                $isRunning = $true
            } else {
                # Stale .running file -- remove it
                Remove-Item $runningFile -Force -ErrorAction SilentlyContinue
                Write-Log "Removed stale .running file for server: $($server.Name)" "INFO"
            }
        } catch { }
    }

    # Fallback: if no .running file or stale, check via A2S_INFO query
    if (-not $isRunning) {
        $fbMeta = Get-GameMetadata -Game $server.Game
        $fbCfg  = Get-ServerManagerConfig -ManagerPath $managerPath
        $fbPort = [int](Resolve-ServerParam -ManagerConfig $fbCfg -Field "Port" `
                    -MetadataDefault ($fbMeta.DefaultGamePort) -HardcodedDefault 27016)
        $fbIP   = Get-PreferredLocalIP
        if ($fbIP -and (Test-SourceQueryReachable -IP $fbIP -Port $fbPort -TimeoutMs 1000)) {
            $isRunning = $true
            Write-Log "Server $($server.Name) detected via A2S_INFO (no .running file)" "INFO"
        }
    }

    # Installation Status
    $instFile3 = Join-Path (Get-ManagerPath $server) ".installing"
    $activeDl3 = $false
    if (($server.Status -eq "Installing") -and (Test-Path $instFile3)) {
        try { $d3 = Get-Content $instFile3 -Raw | ConvertFrom-Json; $activeDl3 = $null -ne (Get-Process -Id $d3.InstallerPID -ErrorAction SilentlyContinue) } catch {}
        if (-not $activeDl3) { Remove-Item $instFile3 -Force -ErrorAction SilentlyContinue }
    }
    if ($disk -eq "Installed" -and $server.Status -eq "Installed") {
        $instSymbol = "[OK]"; $instColor = "Green"; $instText = "ServerInfo_Installed"
    } elseif ($activeDl3) {
        $instSymbol = "[>>]"; $instColor = "Cyan"; $instText = "ServerInfo_Downloading"
    } elseif ($server.Status -eq "Installing") {
        $instSymbol = "[!!]"; $instColor = "Yellow"; $instText = "ServerInfo_Installing"
    } elseif ($disk -eq "Missing") {
        $instSymbol = "[--]"; $instColor = "Red"; $instText = "ServerInfo_Missing"
    } else {
        $instSymbol = "[!!]"; $instColor = "Yellow"; $instText = "ServerInfo_Corrupted"
    }

    # Configuration Status
    if (-not [string]::IsNullOrWhiteSpace($server.ConfiguredMap) -and -not [string]::IsNullOrWhiteSpace($server.ConfiguredGameMode)) {
        $cfgSymbol = "[OK]"; $cfgColor = "Green"; $cfgText = "ServerInfo_Configured"
    } else {
        $cfgSymbol = "[!!]"; $cfgColor = "Yellow"; $cfgText = "ServerInfo_NotConfigured"
    }

    # Windows Firewall state (via MpsSvc service)
    $wfSvc = Get-Service -Name "MpsSvc" -ErrorAction SilentlyContinue
    $wfEnabled = ($wfSvc -and $wfSvc.Status -eq "Running")
    if ($wfEnabled) {
        $wfSymbol = "[OK]"; $wfColor = "Green"
        $wfLabel  = Get-Message -Key "ServerInfo_FWEnabled"
    } else {
        $wfSymbol = "[!!]"; $wfColor = "Yellow"
        $wfLabel  = Get-Message -Key "ServerInfo_FWDisabled"
    }

    # Third-party firewall (SecurityCenter2)
    $tpFwName   = $null
    $tpFwActive = $false
    try {
        $fwProducts = @(Get-CimInstance -Namespace "root/SecurityCenter2" -ClassName "FirewallProduct" -ErrorAction SilentlyContinue)
        foreach ($fp in $fwProducts) {
            if ($fp.displayName -notmatch "Windows") {
                $tpFwName = $fp.displayName
                # productState hex: 3rd nibble from left (index 2) == '1' means enabled
                $stateHex = "{0:X6}" -f [int]$fp.productState
                $tpFwActive = ($stateHex.Length -ge 3 -and $stateHex[2] -eq '1')
                break
            }
        }
    } catch { }

    if ($tpFwName) {
        # Third-party present: Windows Firewall is irrelevant
        $wfSymbol = "[--]"; $wfColor = "DarkGray"
        $wfLabel  = Get-Message -Key "ServerInfo_FWIrrelevant"

        $tpSymbol = "[OK]"; $tpColor = "Cyan"
        $tpUnmanaged = Get-Message -Key "ServerInfo_FWThirdPartyUnmanaged"
        if ($tpFwActive) {
            $tpLabel = "$tpFwName  [$tpUnmanaged]"
        } else {
            $tpLabel = "$tpFwName  [$tpUnmanaged]"
        }
    } else {
        $tpSymbol = ""; $tpColor = "DarkGray"
        $tpLabel  = Get-Message -Key "ServerInfo_FWThirdPartyNone"
    }

    # Mod Status (disk-based)
    $mmSymbol = "[--]"; $mmColor = "DarkGray"; $mmLabel = Get-Message -Key "ServerInfo_ModNone"
    $smSymbol = "[--]"; $smColor = "DarkGray"; $smLabel = Get-Message -Key "ServerInfo_ModNone"
    $mmInstalled = $false; $smInstalled = $false
    $modStatus = $null
    $modsConfigPath = Join-Path $RootPath "games\$($server.Game)\configs\mods.json"
    if (Test-Path $modsConfigPath) {
        try {
            $mc = Get-Content $modsConfigPath -Raw | ConvertFrom-Json
            $modStatus = Get-ModStatus -ServerPath $gamePath -GameFolder $mc.GameFolder -ManagerPath $managerPath
            $mmInstalled = $modStatus.MetaMod
            $smInstalled = $modStatus.SourceMod
            if ($mmInstalled) {
                $mmSymbol = "[OK]"; $mmColor = "Green"
                $mmLabel = if ($modStatus.MetaModVersion) { "v$($modStatus.MetaModVersion)" } else { Get-Message -Key "Mod_Installed" }
            }
            if ($smInstalled) {
                $smSymbol = "[OK]"; $smColor = "Green"
                $smLabel = if ($modStatus.SourceModVersion) { "v$($modStatus.SourceModVersion)" } else { Get-Message -Key "Mod_Installed" }
            }
        } catch { }
    }

    # Running Status
    if ($isRunning) {
        $runSymbol = "[OK]"; $runColor = "Green"; $runText = "ServerInfo_Running"
    } else {
        $runSymbol = "[--]"; $runColor = "Yellow"; $runText = "ServerInfo_NotRunning"
    }

    # Session line: player count + connection type (from console.log + RCON)
    $sessionLabel    = "-----"
    $sessionColor    = "DarkGray"
    $sessionPlayers  = $null
    $sessionConnType = $null

    # Read game metadata early (needed for console info + box display)
    $boxMeta = Get-GameMetadata -Game $server.Game
    $boxCfg  = Get-ServerManagerConfig -ManagerPath $managerPath
    $boxMap  = Resolve-ServerParam -ManagerConfig $boxCfg -Field "Map"     -MetadataDefault ($boxMeta.DefaultMap)      -HardcodedDefault "?"
    $boxMode = Resolve-ServerParam -ManagerConfig $boxCfg -Field "GameMode"-MetadataDefault ($boxMeta.DefaultGameMode) -HardcodedDefault "?"
    $boxPort = Resolve-ServerParam -ManagerConfig $boxCfg -Field "Port"    -MetadataDefault ($boxMeta.DefaultGamePort) -HardcodedDefault 27016

    # Console log info: connection type detection
    if ($isRunning) {
        $gameFolder = if ($boxMeta -and $boxMeta.GameFolder) { $boxMeta.GameFolder } else { "left4dead2" }
        $consoleInfo = Get-ServerConsoleInfo -ServerPath $server.Path -GameFolder $gameFolder
        if ($consoleInfo -and $consoleInfo.LastConnectionType) {
            $sessionConnType = $consoleInfo.LastConnectionType
        }
    }

    # RCON Status
    $managerConfigPath = Join-Path $managerPath "config.json"
    $rconPasswordSet = $false
    if (Test-Path $managerConfigPath) {
        try {
            $mc2 = Get-Content $managerConfigPath -Raw | ConvertFrom-Json
            $rconPasswordSet = -not [string]::IsNullOrWhiteSpace($mc2.RconPassword)
        } catch { }
    }

    # RCON password status (disk-based, always shown)
    $rconSymbol = "[--]"; $rconColor = "Yellow"; $rconLabel = Get-Message -Key "ServerInfo_RconNoPassword"
    if ($rconPasswordSet) {
        $rconSymbol = "[OK]"; $rconColor = "Green"; $rconLabel = Get-Message -Key "ServerInfo_RconPasswordSet"
    }

    if ($rconPasswordSet -and $isRunning) {
        $statusResp = Invoke-ServerRcon -Server $server -Command "status"
        if ($null -ne $statusResp) {
            $rconLabel = Get-Message -Key "ServerInfo_RconActive"
            if ($statusResp -match 'players\s*:\s*(\d+)\s+humans.*?\((\d+)\s+max\)') {
                $sessionPlayers = "$($Matches[1])/$($Matches[2])"
            }

            if ($mmInstalled) {
                $mmResp = Invoke-ServerRcon -Server $server -Command "meta version"
                if ($null -ne $mmResp -and $mmResp -match "Metamod") {
                    $mmLabel = "$(Get-Message -Key 'ServerInfo_ModActive')$(if ($modStatus -and $modStatus.MetaModVersion) { ' v' + $modStatus.MetaModVersion })"
                } else {
                    $mmSymbol = "[!!]"; $mmColor = "Yellow"
                    $mmLabel = Get-Message -Key "ServerInfo_ModNotLoaded"
                }
            }
            if ($smInstalled) {
                $smResp = Invoke-ServerRcon -Server $server -Command "sm version"
                if ($null -ne $smResp -and $smResp -match "SourceMod") {
                    $smLabel = "$(Get-Message -Key 'ServerInfo_ModActive')$(if ($modStatus -and $modStatus.SourceModVersion) { ' v' + $modStatus.SourceModVersion })"
                } else {
                    $smSymbol = "[!!]"; $smColor = "Yellow"
                    $smLabel = Get-Message -Key "ServerInfo_ModNotLoaded"
                }
            }
        } else {
            $rconSymbol = "[!!]"; $rconColor = "Yellow"; $rconLabel = Get-Message -Key "ServerInfo_RconInactive"
        }
    }

    # Build session line now that we have player count from RCON
    if ($isRunning) {
        $playersPart = if ($sessionPlayers) { "$sessionPlayers  " } else { "?/?  " }
        # Extract current player count to decide if session is active
        $currentPlayers = 0
        if ($sessionPlayers -and $sessionPlayers -match '^(\d+)/') {
            $currentPlayers = [int]$Matches[1]
        }
        # Show connection type only if players are currently connected
        if ($currentPlayers -gt 0 -and $sessionConnType -eq "matchmaking") {
            $sessionLabel = "$playersPart$(Get-Message -Key 'ServerInfo_ConnMatchmaking')"
            $sessionColor = "Green"
        } elseif ($currentPlayers -gt 0 -and $sessionConnType -eq "direct") {
            $sessionLabel = "$playersPart$(Get-Message -Key 'ServerInfo_ConnDirect')"
            $sessionColor = "Yellow"
        } else {
            $sessionLabel = "$playersPart$(Get-Message -Key 'ServerInfo_ConnAvailable')"
            $sessionColor = "White"
        }
    }

    [Console]::SetCursorPosition(0, $loadingRow)
    Write-Host (" " * ([Console]::WindowWidth - 1)) -NoNewline
    [Console]::SetCursorPosition(0, $loadingRow)

    # --- Info box with aligned labels ---
    $boxWidth = 44
    $divider  = "  " + ("=" * $boxWidth)

    # Collect label strings for alignment
    $lInstall  = Get-Message -Key "ServerInfo_Installation"
    $lConfig   = Get-Message -Key "ServerInfo_Configuration"
    $lPort     = Get-Message -Key "ServerInfo_Port"
    $lWinFW    = Get-Message -Key "ServerInfo_WinFirewall"
    $lThirdFW  = Get-Message -Key "ServerInfo_ThirdPartyFW"
    $lLanIP    = Get-Message -Key "ServerInfo_LanIP"
    $lPubIP    = Get-Message -Key "ServerInfo_PublicIP"
    $lMap      = Get-Message -Key "ServerInfo_Map"
    $lMode     = Get-Message -Key "ServerInfo_GameMode"
    $lMeta     = Get-Message -Key "ServerInfo_MetaMod"
    $lSource   = Get-Message -Key "ServerInfo_SourceMod"
    $lStatus   = Get-Message -Key "ServerInfo_Status"
    $lRcon     = Get-Message -Key "ServerInfo_Rcon"

    $colW = (@($lInstall,$lConfig,$lPort,$lWinFW,$lThirdFW,$lLanIP,$lPubIP,$lMap,$lMode,$lMeta,$lSource,$lStatus,$lRcon) |
             Measure-Object -Maximum -Property Length).Maximum + 1

    function Write-InfoLine {
        param([string]$Label, [string]$Value, [string]$Color = "White", [switch]$DimLabel)
        $pad    = $Label.PadRight($colW)
        $prefix = "  $pad : "
        if ($DimLabel) {
            Write-Host $prefix -NoNewline -ForegroundColor DarkGray
        } else {
            Write-Host $prefix -NoNewline
        }
        Write-Host $Value -ForegroundColor $Color
    }

    # Get local IP (primary adapter) and cached public IP
    $boxLocalIP  = Get-PreferredLocalIP
    $boxPublicIP = Get-CachedPublicIP
    $boxLanAddr  = if ($boxLocalIP)  { "$boxLocalIP`:$boxPort" }  else { "?:$boxPort" }
    $boxPubAddr  = if ($boxPublicIP) { "$boxPublicIP`:$boxPort" } else { Get-Message -Key "ServerInfo_PublicIPUnknown" }

    Write-Host ""
    Write-Host $divider -ForegroundColor DarkGray
    Write-InfoLine $lInstall "$instSymbol $(Get-Message -Key $instText)" $instColor
    Write-InfoLine $lConfig  "$cfgSymbol $(Get-Message -Key $cfgText)"   $cfgColor
    Write-InfoLine $lPort    $boxPort
    Write-InfoLine $lWinFW   "$wfSymbol $wfLabel" $wfColor
    $tpLine = "$tpSymbol $tpLabel".Trim()
    Write-InfoLine $lThirdFW $tpLine $tpColor
    Write-InfoLine $lLanIP   $boxLanAddr
    $pubIPColor = if ($boxPublicIP) { "White" } else { "DarkGray" }
    Write-InfoLine $lPubIP   $boxPubAddr  $pubIPColor
    Write-InfoLine $lMap     $boxMap
    Write-InfoLine $lMode    $boxMode
    Write-InfoLine $lMeta    "$mmSymbol $mmLabel" $mmColor
    Write-InfoLine $lSource  "$smSymbol $smLabel" $smColor
    Write-InfoLine $lStatus  "$runSymbol $(Get-Message -Key $runText)" $runColor
    Write-InfoLine (Get-Message -Key "ServerInfo_Session") $sessionLabel $sessionColor
    Write-InfoLine $lRcon    "$rconSymbol $rconLabel" $rconColor
    Write-Host $divider -ForegroundColor DarkGray
    Write-Host ""
}

function Show-PlayersMenu {
    param([object]$Server, [string]$RootPath)

    $gamePath = Get-GamePath $Server
    $adminIds = @()
    $modsConfigPath = Join-Path $RootPath "games\$($Server.Game)\configs\mods.json"
    if (Test-Path $modsConfigPath) {
        try {
            $mc = Get-Content $modsConfigPath -Raw | ConvertFrom-Json
            $adminIds = @(Get-SmAdmins -ServerPath $gamePath -GameFolder $mc.GameFolder | ForEach-Object { $_.SteamId })
        } catch { }
    }

    while ($true) {
        Write-Host ""
        Write-Host "  $(Get-Message -Key 'Players_Title'): $($Server.Name)" -ForegroundColor Cyan
        Write-Host ""

        $statusResp = Invoke-ServerRcon -Server $Server -Command "status"
        if ($null -eq $statusResp) {
            Write-Host "  $(Get-Message -Key 'Players_RconUnavailable')`n" -ForegroundColor Yellow
            Read-Host (Get-Message -Key "Common_PressEnter")
            return
        }

        $humanRx = [regex]'#\s+\d+\s+(?:\d+\s+)?"([^"]+)"\s+(STEAM_[0-9]:[0-9]:\d+)\s+\S+\s+(\d+)'
        $botRx   = [regex]'#\s*(\d+)\s+"([^"]+)"\s+BOT\s+active'
        $connected = @()
        foreach ($m in $humanRx.Matches($statusResp)) {
            $connected += [PSCustomObject]@{
                Name    = $m.Groups[1].Value
                SteamId = $m.Groups[2].Value
                Ping    = $m.Groups[3].Value
                IsAdmin = $adminIds -contains $m.Groups[2].Value
                IsBot   = $false
            }
        }
        foreach ($m in $botRx.Matches($statusResp)) {
            $connected += [PSCustomObject]@{
                Name    = $m.Groups[2].Value
                SteamId = "BOT"
                Ping    = "-"
                IsAdmin = $false
                IsBot   = $true
            }
        }

        if ($connected.Count -eq 0) {
            Write-Host "  $(Get-Message -Key 'Players_None')`n" -ForegroundColor DarkGray
            Read-Host (Get-Message -Key "Common_PressEnter")
            return
        }

        Write-Host "  $(Get-Message -Key 'Players_Connected' -MsgArgs @($connected.Count)):`n"
        for ($i = 0; $i -lt $connected.Count; $i++) {
            $p = $connected[$i]
            if ($p.IsBot) {
                $tag = "[BOT]"; $color = "DarkGray"
                Write-Host "  $($i+1)) $tag $($p.Name)" -ForegroundColor $color
            } else {
                $tag   = if ($p.IsAdmin) { "[A]  " } else { "     " }
                $color = if ($p.IsAdmin) { "Green" } else { "White" }
                Write-Host "  $($i+1)) $tag $($p.Name)   $($p.SteamId)   ping: $($p.Ping)" -ForegroundColor $color
            }
        }
        Write-Host ""
        Write-Host "  K) $(Get-Message -Key 'Players_Kick')"
        Write-Host "  B) $(Get-Message -Key 'Players_Ban')"
        Write-Host "  S) $(Get-Message -Key 'Players_Slay')"
        Write-Host "  A) $(Get-Message -Key 'Players_AddAdmin')"
        Write-Host "  0) $(Get-Message -Key 'Manage_Back')"
        Write-Host ""

        $action = Read-Host (Get-Message -Key "Common_Select")
        if ($action -eq "0") { return }

        if ($action -notin @("K","k","B","b","S","s","A","a")) {
            Write-Host "`n$(Get-Message -Key 'Common_InvalidOption')`n" -ForegroundColor Yellow
            continue
        }

        Write-Host ""
        for ($i = 0; $i -lt $connected.Count; $i++) {
            Write-Host "  $($i+1)) $($connected[$i].Name)   $($connected[$i].SteamId)"
        }
        Write-Host "  0) $(Get-Message -Key 'Common_Cancel')"
        Write-Host ""
        $sel = Read-Host (Get-Message -Key "Common_Select")
        if ($sel -eq "0" -or [string]::IsNullOrWhiteSpace($sel)) { continue }
        $idx = [int]$sel - 1
        if ($idx -lt 0 -or $idx -ge $connected.Count) {
            Write-Host "`n$(Get-Message -Key 'Common_InvalidSelection')`n" -ForegroundColor Red
            Read-Host (Get-Message -Key "Common_PressEnter")
            continue
        }
        $target = $connected[$idx]

        if ($target.IsBot -and $action -in @("B","b","A","a")) {
            Write-Host "`n  $(Get-Message -Key 'Players_BotNoAction')`n" -ForegroundColor Yellow
            Read-Host (Get-Message -Key "Common_PressEnter")
            continue
        }

        switch -Regex ($action) {
            '^[Kk]$' {
                $reason = Read-Host (Get-Message -Key "Players_KickReason")
                $cmd = if ($reason) { "sm_kick `"$($target.Name)`" $reason" } else { "sm_kick `"$($target.Name)`"" }
                Invoke-ServerRcon -Server $Server -Command $cmd | Out-Null
                Write-Host "`n$(Get-Message -Key 'Players_KickDone' -MsgArgs @($target.Name))`n" -ForegroundColor Green
                Read-Host (Get-Message -Key "Common_PressEnter")
            }
            '^[Bb]$' {
                $reason = Read-Host (Get-Message -Key "Players_BanReason")
                $minutes = Read-Host (Get-Message -Key "Players_BanMinutes")
                if ([string]::IsNullOrWhiteSpace($minutes)) { $minutes = "0" }
                $cmd = "sm_ban `"$($target.Name)`" $minutes $reason"
                Invoke-ServerRcon -Server $Server -Command $cmd | Out-Null
                Write-Host "`n$(Get-Message -Key 'Players_BanDone' -MsgArgs @($target.Name))`n" -ForegroundColor Green
                Read-Host (Get-Message -Key "Common_PressEnter")
            }
            '^[Ss]$' {
                Invoke-ServerRcon -Server $Server -Command "sm_slay `"$($target.Name)`"" | Out-Null
                Write-Host "`n$(Get-Message -Key 'Players_SlayDone' -MsgArgs @($target.Name))`n" -ForegroundColor Green
                Read-Host (Get-Message -Key "Common_PressEnter")
            }
            '^[Aa]$' {
                Show-AdminMenu -Server $Server -RootPath $RootPath -PreselectedSteamId $target.SteamId -PreselectedName $target.Name
            }
        }
    }
}

function Invoke-ManageServer {
    param([string]$RootPath, $Config)

    Show-Header
    Write-Host (Format-SectionTitle (Get-Message -Key "Manage_Title"))
    Write-Host ""

    $servers = @(Get-ServerRegistry)

    if ($servers.Count -eq 0) {
        Write-Host "$(Get-Message -Key 'Common_NoServersRegistered')`n"
        Read-Host (Get-Message -Key "Common_PressEnter")
        return
    }

    if ($servers.Count -eq 1) {
        $selected = $servers[0]
    } else {
        for ($i = 0; $i -lt $servers.Count; $i++) {
            $s = $servers[$i]
            $disk = Get-ServerDiskStatus -Path (Get-GamePath $s)
            $num = $i + 1
            $shortPath = Get-ShortPath -Path $s.Path -RootPath $RootPath
            $namePad = $s.Name.PadRight(16)
            $instFile2 = Join-Path (Get-ManagerPath $s) ".installing"
            $activeDl2 = $false
            if (($s.Status -eq "Installing") -and (Test-Path $instFile2)) {
                try { $d2 = Get-Content $instFile2 -Raw | ConvertFrom-Json; $activeDl2 = $null -ne (Get-Process -Id $d2.InstallerPID -ErrorAction SilentlyContinue) } catch {}
                if (-not $activeDl2) { Remove-Item $instFile2 -Force -ErrorAction SilentlyContinue }
            }

            if ($disk -eq "Installed" -and $s.Status -eq "Installed") {
                $symbol = "[OK]"; $color = "Green";  $tag = Get-Message -Key "ServerList_StatusOK"
            } elseif ($activeDl2) {
                $symbol = "[>>]"; $color = "Cyan";   $tag = Get-Message -Key "ServerList_StatusDownloading"
            } elseif ($s.Status -eq "Installing") {
                $symbol = "[!!]"; $color = "Yellow"; $tag = Get-Message -Key "ServerList_StatusInstalling"
            } elseif ($disk -eq "Missing") {
                $symbol = "[--]"; $color = "Red";    $tag = Get-Message -Key "ServerList_StatusMissing"
            } else {
                $symbol = "[!!]"; $color = "Yellow"; $tag = Get-Message -Key "ServerList_StatusError"
            }

            $line = "$symbol  $namePad $shortPath"
            if (-not [string]::IsNullOrEmpty($tag)) { $line += "  $tag" }
            Write-Host "  $num) " -NoNewline
            Write-Host $line -ForegroundColor $color
        }
        Write-Host ""
        Write-Host "====================================="
        Write-Host ""
        $sel = Read-Host (Get-Message -Key "Manage_SelectServer")
        if ($sel -eq "0" -or [string]::IsNullOrWhiteSpace($sel)) { return }

        $idx = [int]$sel - 1
        if ($idx -lt 0 -or $idx -ge $servers.Count) {
            Write-Host "`n$(Get-Message -Key 'Common_InvalidSelection')`n" -ForegroundColor Red
            Read-Host (Get-Message -Key "Common_PressEnter")
            return
        }

        $selected = $servers[$idx]
    }

    while ($true) {
        Show-Header
        $disk        = Get-ServerDiskStatus -Path (Get-GamePath $selected)
        $shortPath   = Get-ShortPath -Path $selected.Path -RootPath $RootPath
        $managerPath = Get-ManagerPath $selected
        $runningFile    = Join-Path $managerPath ".running"
        $installingFile = Join-Path $managerPath ".installing"
        $isRunning   = $false

        # Check background installer process if .installing exists
        if (Test-Path $installingFile) {
            try {
                $instData = Get-Content $installingFile -Raw | ConvertFrom-Json
                $instProc = Get-Process -Id $instData.InstallerPID -ErrorAction SilentlyContinue
                if (-not $instProc) {
                    # Process gone but status not updated -> crashed or killed
                    $fresh = @(Get-ServerRegistry) | Where-Object { $_.ServerId -eq $selected.ServerId } | Select-Object -First 1
                    if ($fresh -and $fresh.Status -eq "Installing") {
                        Update-ServerStatus -ServerId $selected.ServerId -Status "Error"
                        Write-Log "Installazione interrotta (processo terminato): $($selected.Name)" "WARNING"
                    }
                    Remove-Item $installingFile -Force -ErrorAction SilentlyContinue
                }
            } catch {
                Remove-Item $installingFile -Force -ErrorAction SilentlyContinue
            }
        }

        # Reload selected from registry to pick up status changes
        $refreshed = @(Get-ServerRegistry) | Where-Object { $_.ServerId -eq $selected.ServerId } | Select-Object -First 1
        if ($refreshed) { $selected = $refreshed }

        if (Test-Path $runningFile) {
            try {
                $runningData = Get-Content $runningFile -Raw | ConvertFrom-Json
                $processFound = $false

                if ($runningData.PowerShellPID) {
                    $psProcess = Get-Process -Id $runningData.PowerShellPID -ErrorAction SilentlyContinue
                    if ($psProcess) { $processFound = $true }
                }

                if (-not $processFound -and $runningData.ServerProcessId) {
                    $serverProcess = Get-Process -Id $runningData.ServerProcessId -ErrorAction SilentlyContinue
                    if ($serverProcess) { $processFound = $true }
                }

                if ($processFound) {
                    $isRunning = $true
                } else {
                    Remove-Item $runningFile -Force -ErrorAction SilentlyContinue
                }
            } catch {
                Remove-Item $runningFile -Force -ErrorAction SilentlyContinue
            }
        }

        # A2S_INFO fallback: detect server started outside the tool
        if (-not $isRunning) {
            $fbMeta2 = Get-GameMetadata -Game $selected.Game
            $fbCfg2  = Get-ServerManagerConfig -ManagerPath $managerPath
            $fbPort2 = [int](Resolve-ServerParam -ManagerConfig $fbCfg2 -Field "Port" `
                        -MetadataDefault ($fbMeta2.DefaultGamePort) -HardcodedDefault 27016)
            $fbIP2   = Get-PreferredLocalIP
            if ($fbIP2 -and (Test-SourceQueryReachable -IP $fbIP2 -Port $fbPort2 -TimeoutMs 1000)) {
                $isRunning = $true
            }
        }
        # Server is "not started this session" if running but not launched by current tool instance
        $isExternalStart = $isRunning -and ($script:_StartedThisSession -notcontains $selected.ServerId)

        $isInstalling  = ($selected.Status -eq "Installing") -or ($selected.Status -eq "Error")
        $isDownloading = ($selected.Status -eq "Installing") -and (Test-Path $installingFile)
        $tagND = Get-Message -Key "Tag_ND"

        Write-Host (Format-SectionTitle $selected.Name)
        Write-Host "  $shortPath" -ForegroundColor DarkGray

        Show-ServerStatusBox -server $selected -RootPath $RootPath

        Write-Host "  --- $(Get-Message -Key 'Manage_Section_Server') ---" -ForegroundColor DarkGray
        if ($isInstalling) {
            Write-Host "  1) $(Get-Message -Key 'Manage_Start')  $tagND" -ForegroundColor DarkGray
            Write-Host "  2) $(Get-Message -Key 'Manage_Restart')  $tagND" -ForegroundColor DarkGray
        } elseif ($isRunning) {
            Write-Host "  1) $(Get-Message -Key 'Manage_Stop')"  -ForegroundColor Yellow
            Write-Host "  2) $(Get-Message -Key 'Manage_Restart')" -ForegroundColor Yellow
            if ($isExternalStart) {
                Write-Host "     $(Get-Message -Key 'Manage_ExternalStartWarning')" -ForegroundColor DarkYellow
            }
        } else {
            Write-Host "  1) $(Get-Message -Key 'Manage_Start')"
            Write-Host "  2) $(Get-Message -Key 'Manage_Restart')" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "  --- $(Get-Message -Key 'Manage_Section_Players') ---" -ForegroundColor DarkGray
        if ($isRunning -and -not $isInstalling) {
            Write-Host "  P) $(Get-Message -Key 'Manage_Players')"
        } else {
            Write-Host "  P) $(Get-Message -Key 'Manage_Players')" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "  --- $(Get-Message -Key 'Manage_Section_Configuration') ---" -ForegroundColor DarkGray
        if ($isInstalling) {
            Write-Host "  3) $(Get-Message -Key 'Manage_ChangeSettings')  $tagND" -ForegroundColor DarkGray
            Write-Host "  4) $(Get-Message -Key 'Manage_NetworkFirewall')  $tagND" -ForegroundColor DarkGray
            Write-Host "  5) $(Get-Message -Key 'Manage_Mods')  $tagND" -ForegroundColor DarkGray
            Write-Host "  6) $(Get-Message -Key 'Manage_Admins')  $tagND" -ForegroundColor DarkGray
            Write-Host "  7) $(Get-Message -Key 'Manage_ServerSettings')  $tagND" -ForegroundColor DarkGray
            Write-Host "  8) $(Get-Message -Key 'Manage_Plugins')  $tagND" -ForegroundColor DarkGray
        } else {
            Write-Host "  3) $(Get-Message -Key 'Manage_ChangeSettings')"
            Write-Host "  4) $(Get-Message -Key 'Manage_NetworkFirewall')"
            Write-Host "  5) $(Get-Message -Key 'Manage_Mods')"
            Write-Host "  6) $(Get-Message -Key 'Manage_Admins')"
            Write-Host "  7) $(Get-Message -Key 'Manage_ServerSettings')"
            Write-Host "  8) $(Get-Message -Key 'Manage_Plugins')  $(Get-Message -Key 'Tag_WIP')" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  --- $(Get-Message -Key 'Manage_Section_Management') ---" -ForegroundColor DarkGray
        Write-Host "  9) $(Get-Message -Key 'Manage_Update')"
        Write-Host " 10) $(Get-Message -Key 'Manage_OpenFolder')"
        Write-Host " 11) $(Get-Message -Key 'Manage_Rename')"
        Write-Host " 12) $(Get-Message -Key 'Manage_Move')"
        Write-Host " 13) $(Get-Message -Key 'Manage_Delete')"
        Write-Host ""
        Write-Host "  W) $(Get-Message -Key 'Manage_Wizard')" -ForegroundColor Cyan
        if ($isDownloading) {
            Write-Host ""
            Write-Host "  $(Get-Message -Key 'Install_Downloading')" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  --- $(Get-Message -Key 'Manage_Section_Debug') ---" -ForegroundColor DarkGray
        Write-Host "  D) $(Get-Message -Key 'Manage_Diagnostics')" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  R) $(Get-Message -Key 'Manage_Refresh')" -ForegroundColor DarkGray
        Write-Host "  0) $(Get-Message -Key 'Manage_Back')"
        Write-Host ""
        Show-ScrollHint

        $action = Read-Host (Get-Message -Key "Common_Select")

        # Guard: block actions unavailable in Installing state
        $blockedWhenInstalling = @("1","2","3","4","5","6","7","8","P","p")
        if ($isInstalling -and $action -in $blockedWhenInstalling) {
            Write-Host "`n  $(Get-Message -Key 'Common_OptionUnavailable' -MsgArgs @($selected.Status))`n" -ForegroundColor DarkGray
            Read-Host (Get-Message -Key "Common_PressEnter")
            continue
        }

        switch ($action) {
            "1" {
                $runningFile = Join-Path (Get-ManagerPath $selected) ".running"
                if (Test-Path $runningFile) {
                    $confirm = Read-Host (Get-Message -Key "Common_ConfirmPrompt")
                    if ($confirm -eq (Get-Message -Key "ConfirmYes")) {
                        Stop-ServerMonitoring $selected
                        Read-Host (Get-Message -Key "Common_PressEnter")
                    }
                } else {
                    $result = Invoke-StartServer -server $selected -RootPath $RootPath
                }
            }
            "2" {
                Invoke-RestartServer -server $selected -RootPath $RootPath
            }
            "3" {
                Write-Host "`n$(Get-Message -Key 'Config_ChangingSettings')`n" -ForegroundColor Cyan
                $result = Update-ServerMapAndGameMode -ServerId $selected.ServerId
                if ($result) {
                    Write-Host "`n$(Get-Message -Key 'Config_Done')`n" -ForegroundColor Green
                    $updated = @(Get-ServerRegistry) | Where-Object { $_.ServerId -eq $selected.ServerId }
                    if ($updated) { $selected = $updated }
                } else {
                    Write-Host "`n$(Get-Message -Key 'Config_Failed')`n" -ForegroundColor Red
                }
                Read-Host (Get-Message -Key "Common_PressEnter")
            }
            "4" {
                $netRunFile = Join-Path (Get-ManagerPath $selected) ".running"
                $netRunning = $false
                if (Test-Path $netRunFile) {
                    try {
                        $netRd = Get-Content $netRunFile -Raw | ConvertFrom-Json
                        if ($netRd.ServerProcessId) {
                            $netRunning = $null -ne (Get-Process -Id $netRd.ServerProcessId -ErrorAction SilentlyContinue)
                        }
                        if (-not $netRunning -and $netRd.PowerShellPID) {
                            $netRunning = $null -ne (Get-Process -Id $netRd.PowerShellPID -ErrorAction SilentlyContinue)
                        }
                    } catch {}
                }
                Invoke-NetworkMenu -Selected $selected -IsRunning $netRunning -RootPath $RootPath -Config $Config
            }
            "5" {
                Show-ModMenu -Server $selected -RootPath $RootPath
            }
            "6" {
                Show-AdminMenu -Server $selected -RootPath $RootPath
            }
            "7" {
                Invoke-ServerSettings $selected
            }
            "8" {
                Write-Host "`n  $(Get-Message -Key 'Common_WIP')`n" -ForegroundColor DarkGray
                Read-Host (Get-Message -Key "Common_PressEnter")
            }
            "9" {
                Write-Host "`n$(Get-Message -Key 'Update_Starting' -MsgArgs @($selected.Name))`n" -ForegroundColor Cyan
                Write-Host (Get-Message -Key "Update_Note")
                Write-Host ""
                $confirm = Read-Host (Get-Message -Key "Common_ConfirmPrompt")
                if ($confirm -eq (Get-Message -Key "ConfirmYes")) { Start-ServerInstall -Target $selected -RootPath $RootPath -Config $Config }
            }
            "10" {
                Start-Process explorer.exe -ArgumentList $selected.Path
            }
            "11" {
                $changed = Invoke-RenameServer $selected
                if ($changed) {
                    $updated = @(Get-ServerRegistry) | Where-Object { $_.ServerId -eq $selected.ServerId }
                    if ($updated) { $selected = $updated }
                }
            }
            "12" {
                $changed = Invoke-MoveServer -server $selected -DefaultInstallRoot $Config.DefaultInstallRoot
                if ($changed) {
                    $updated = @(Get-ServerRegistry) | Where-Object { $_.ServerId -eq $selected.ServerId }
                    if ($updated) { $selected = $updated }
                }
            }
            "13" {
                Write-Host "`n$(Get-Message -Key 'Delete_Warning' -MsgArgs @($selected.Name))" -ForegroundColor Yellow
                Write-Host "$(Get-Message -Key 'Delete_DiskNote')`n"
                $confirm = Read-Host (Get-Message -Key "Common_ConfirmPrompt")
                if ($confirm -eq (Get-Message -Key "ConfirmYes")) {
                    Remove-ServerFromRegistry -ServerId $selected.ServerId
                    Write-Log "Server eliminato dal registry: $($selected.Name)" "INFO"
                    Write-Host "`n$(Get-Message -Key 'Delete_Done')`n" -ForegroundColor Green
                    Read-Host (Get-Message -Key "Common_PressEnter")
                    return
                }
            }
            "W" {
                $selected = Invoke-SetupWizard -Server $selected -RootPath $RootPath
            }
            "w" {
                $selected = Invoke-SetupWizard -Server $selected -RootPath $RootPath
            }
            { $_ -in "P","p" } {
                Show-PlayersMenu -Server $selected -RootPath $RootPath
            }
            { $_ -in "D","d" } {
                $dgMgr  = Get-ManagerPath $selected
                $dgGame = Get-GamePath    $selected

                # Helper: print a section header
                function Write-DiagSection { param([string]$Title)
                    Write-Host ""
                    Write-Host "  --- $Title ---" -ForegroundColor Cyan
                    Write-Host ""
                }

                # Helper: print an aligned key:value line
                function Write-DiagLine { param([string]$Key, [string]$Value, [string]$Color = "White")
                    $pad = $Key.PadRight(14)
                    Write-Host "  $pad : " -NoNewline
                    Write-Host $Value -ForegroundColor $Color
                }

                Show-Header
                Write-Host (Format-SectionTitle (Get-Message -Key "Manage_Diagnostics"))

                # -- [1] SERVER --
                Write-DiagSection "[1] SERVER"
                Write-DiagLine "Name"   $selected.Name
                Write-DiagLine "Game"   $selected.Game
                Write-DiagLine "Path"   $selected.Path
                $dgDisk = Get-ServerDiskStatus -Path $dgGame -Game $selected.Game
                $dgDiskColor = if ($dgDisk -eq "Installed") { "Green" } else { "Yellow" }
                Write-DiagLine "Disk"   $dgDisk $dgDiskColor
                $dgRunFile    = Join-Path $dgMgr ".running"
                $dgRunning    = (Test-Path $dgRunFile)
                $dgRunLabel   = if ($dgRunning) { "YES" } else { "NO" }
                $dgRunColor   = if ($dgRunning) { "Green" } else { "DarkGray" }
                Write-DiagLine "Running" $dgRunLabel $dgRunColor

                # -- [2] CONFIG (manager/config.json) --
                Write-DiagSection "[2] CONFIG  (manager/config.json)"
                $dgCfgFile = Join-Path $dgMgr "config.json"
                if (Test-Path $dgCfgFile) {
                    Write-Host "  File            : $dgCfgFile" -ForegroundColor DarkGray
                    try {
                        $dgCfg = Get-Content $dgCfgFile -Raw | ConvertFrom-Json
                        $dgMeta = Get-GameMetadata -Game $selected.Game
                        $dgMap  = Resolve-ServerParam -ManagerConfig $dgCfg -Field "Map"     -MetadataDefault ($dgMeta.DefaultMap)      -HardcodedDefault "?"
                        $dgMode = Resolve-ServerParam -ManagerConfig $dgCfg -Field "GameMode"-MetadataDefault ($dgMeta.DefaultGameMode) -HardcodedDefault "?"
                        $dgPort = Resolve-ServerParam -ManagerConfig $dgCfg -Field "Port"    -MetadataDefault ($dgMeta.DefaultGamePort) -HardcodedDefault 27016
                        $dgIpRaw = if ($dgCfg.LaunchIp) { $dgCfg.LaunchIp } else { "(not set)" }
                        $dgPwdSet = -not [string]::IsNullOrWhiteSpace($dgCfg.RconPassword)
                        $dgExtra = if ($dgCfg.ExtraArgs -and $dgCfg.ExtraArgs.Count -gt 0) { $dgCfg.ExtraArgs -join " " } else { "(none)" }
                        Write-DiagLine "Map"      $dgMap
                        Write-DiagLine "GameMode" $dgMode
                        Write-DiagLine "Port"     "$dgPort"
                        Write-DiagLine "LaunchIp" $dgIpRaw
                        $dgPwdLabel = if ($dgPwdSet) { "SET (len=$($dgCfg.RconPassword.Length))" } else { "EMPTY" }
                        $dgPwdColor = if ($dgPwdSet) { "Green" } else { "Red" }
                        Write-DiagLine "RCON pwd" $dgPwdLabel $dgPwdColor
                        Write-DiagLine "ExtraArgs" $dgExtra
                    } catch {
                        Write-Host "  [ERROR] Cannot parse config.json: $_" -ForegroundColor Red
                    }
                } else {
                    Write-Host "  [--] config.json not found: $dgCfgFile" -ForegroundColor Red
                }

                # -- [3] LAUNCH COMMAND --
                Write-DiagSection "[3] LAUNCH COMMAND"
                if ($dgDisk -eq "Installed") {
                    $dgCmd = Build-ServerLaunchCommand `
                        -InstallPath $dgGame `
                        -ManagerPath $dgMgr `
                        -Game        $selected.Game
                    if ($dgCmd) {
                        Write-Host "  Executable      : $($dgCmd.Executable)" -ForegroundColor DarkGray
                        Write-Host ""
                        Write-Host "  Arguments:" -ForegroundColor DarkGray
                        foreach ($a in $dgCmd.ArgsArray) {
                            Write-Host "    $a" -ForegroundColor White
                        }
                        Write-Host ""
                        Write-Host "  Full command line:" -ForegroundColor DarkGray
                        Write-Host "  `"$($dgCmd.Executable)`" $($dgCmd.Arguments)" -ForegroundColor Yellow
                    } else {
                        Write-Host "  [!!] Could not build launch command (check config and metadata)" -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "  [--] Server not installed -- launch command not available" -ForegroundColor DarkGray
                }

                # -- [4] RCON --
                Write-DiagSection "[4] RCON"
                $dgRconPort  = if ($dgCfg -and $dgCfg.Port) { [int]$dgCfg.Port } else { 27016 }
                $dgAddr      = Find-RconAddress -Port $dgRconPort
                $dgAddrLabel = if ($dgAddr) { "$dgAddr`:$dgRconPort" } else { "NOT FOUND" }
                $dgAddrColor = if ($dgAddr) { "Cyan" } else { "Red" }
                Write-DiagLine "Address" $dgAddrLabel $dgAddrColor
                if ($dgAddr) {
                    try {
                        $dgTcp = New-Object System.Net.Sockets.TcpClient
                        $dgOk  = $dgTcp.ConnectAsync($dgAddr, $dgRconPort).Wait(3000)
                        if ($dgTcp.Connected) {
                            Write-DiagLine "TCP test" "OK" "Green"
                            $dgTcp.Close()
                        } else {
                            Write-DiagLine "TCP test" "FAILED (timeout)" "Red"
                        }
                    } catch {
                        Write-DiagLine "TCP test" "FAILED ($_)" "Red"
                    }
                }

                # -- [5] NETWORK (srcds listening ports) --
                Write-DiagSection "[5] NETWORK  (srcds listening ports)"

                # Read server PID from .running if available
                $dgServerPid = 0
                if (Test-Path $dgRunFile) {
                    try {
                        $dgRunData   = Get-Content $dgRunFile -Raw | ConvertFrom-Json
                        $dgServerPid = if ($dgRunData.ServerProcessId) { [int]$dgRunData.ServerProcessId } else { 0 }
                    } catch { }
                }

                if ($dgServerPid -gt 0) {
                    $dgGamePort   = if ($dgCfg -and $dgCfg.Port) { [int]$dgCfg.Port } else { 27016 }
                    $dgSrcdsMatch = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                        Where-Object { $_.OwningProcess -eq $dgServerPid -and $_.LocalPort -eq $dgGamePort }

                    if ($dgSrcdsMatch) {
                        foreach ($c in $dgSrcdsMatch) {
                            Write-Host ("  {0,-22} PID {1}  [srcds]" -f "$($c.LocalAddress):$($c.LocalPort)", $dgServerPid) -ForegroundColor Green
                        }
                    } else {
                        Write-Host "  srcds running (PID $dgServerPid) but port $dgGamePort not in Listen state" -ForegroundColor Yellow
                        Write-Host "  (server may still be starting up)" -ForegroundColor DarkGray
                    }
                } else {
                    Write-Host "  Server not running -- no ports to show" -ForegroundColor DarkGray
                }

                Write-Host ""
                Read-Host (Get-Message -Key "Common_PressEnter")
            }
            { $_ -in "R","r" } { continue }
            "0" { return }
            default {
                Write-Host "`n$(Get-Message -Key 'Common_InvalidOption')`n" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Invoke-RestartServer {
    param($server, [string]$RootPath)

    $managerPath = Get-ManagerPath $server
    $runningFile = Join-Path $managerPath ".running"

    if (-not (Test-Path $runningFile)) {
        Write-Host "`n$(Get-Message -Key 'Mod_RestartNotRunning')`n" -ForegroundColor DarkGray
        Read-Host (Get-Message -Key "Common_PressEnter")
        return
    }

    $confirm = Read-Host (Get-Message -Key "Common_ConfirmPrompt")
    if ($confirm -ne (Get-Message -Key "ConfirmYes")) { return }

    try {
        $rd = Get-Content $runningFile -Raw | ConvertFrom-Json
        if ($rd.ServerProcessId) { Stop-Process -Id $rd.ServerProcessId -Force -ErrorAction SilentlyContinue }
        if ($rd.PowerShellPID)   { Stop-Process -Id $rd.PowerShellPID   -Force -ErrorAction SilentlyContinue }
        Remove-Item $runningFile -Force -ErrorAction SilentlyContinue
    } catch { }

    Start-Sleep -Seconds 2

    $fresh = @(Get-ServerRegistry) | Where-Object { $_.ServerId -eq $server.ServerId } | Select-Object -First 1
    if (-not $fresh -or [string]::IsNullOrWhiteSpace($fresh.ConfiguredMap) -or [string]::IsNullOrWhiteSpace($fresh.ConfiguredGameMode)) {
        Write-Host "`n$(Get-Message -Key 'Start_NotConfigured')`n" -ForegroundColor Yellow
        Read-Host (Get-Message -Key "Common_PressEnter")
        return
    }

    $gamePath    = Get-GamePath    $server
    $managerPath = Get-ManagerPath $server

    # All launch params come from manager/config.json -> metadata defaults
    $restartCmd = Build-ServerLaunchCommand `
        -InstallPath $gamePath `
        -ManagerPath $managerPath `
        -Game        $server.Game
    $restartArgString = if ($restartCmd) { $restartCmd.Arguments } else { "" }

    Write-Host ""
    Write-Host "$(Get-Message -Key 'Start_SelectMode'):`n"
    Write-Host "  1) $(Get-Message -Key 'Start_NormalMode')"
    Write-Host "  2) $(Get-Message -Key 'Start_AutoRestartMode')"
    Write-Host ""
    $modeChoice = Read-Host (Get-Message -Key "Common_Select")

    if ($modeChoice -eq "1") {
        $newPid = Start-ServerNormal -InstallPath $gamePath -ArgString $restartArgString
        if ($newPid -gt 0) {
            @{
                ServerPath      = $server.Path
                ServerName      = $server.Name
                ServerProcessId = $newPid
                StartedAt       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            } | ConvertTo-Json | Set-Content $runningFile -Encoding UTF8
            $script:_StartedThisSession = @($script:_StartedThisSession) + $server.ServerId
            Write-Host "`n$(Get-Message -Key 'Mod_RestartDone')`n" -ForegroundColor Green
        } else {
            Write-Host "`n$(Get-Message -Key 'Mod_RestartFailed')`n" -ForegroundColor Red
        }
    } elseif ($modeChoice -eq "2") {
        $monitoringScript2 = @"
`$RootPath = '$RootPath'
`$host.ui.RawUI.WindowTitle = 'Monitoring: $($server.Name)'
Import-Module "`$RootPath\modules\server-monitor.psm1" -Force
Import-Module "`$RootPath\modules\logging.psm1" -Force
Start-ServerWithMonitoring -InstallPath '$gamePath' -ManagerPath '$managerPath' -ArgString '$restartArgString'
"@
        $process = Start-Process powershell.exe -ArgumentList "-NoExit", "-Command", $monitoringScript2 -WindowStyle Normal -PassThru
        @{
            ServerPath    = $server.Path
            ServerName    = $server.Name
            PowerShellPID = $process.Id
            StartedAt     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        } | ConvertTo-Json | Set-Content $runningFile -Encoding UTF8
        $script:_StartedThisSession = @($script:_StartedThisSession) + $server.ServerId
        Write-Host "`n$(Get-Message -Key 'Mod_RestartDone')`n" -ForegroundColor Green
    }

    Read-Host (Get-Message -Key "Common_PressEnter")
}


function Invoke-ServerSettings {
    param($server)

    $managerPath = Get-ManagerPath $server
    $configPath  = Join-Path $managerPath "config.json"

    if (-not (Test-Path $managerPath)) {
        New-Item -ItemType Directory -Path $managerPath -Force | Out-Null
    }

    $sc = if (Test-Path $configPath) {
        try { Get-Content $configPath -Raw | ConvertFrom-Json }
        catch { [PSCustomObject]@{} }
    } else { [PSCustomObject]@{} }

    # Helper: save config and regenerate bat
    function Save-ServerConfig {
        $sc | ConvertTo-Json | Set-Content $configPath -Encoding UTF8

        # Regenerate start_server.bat
        $batchPath = Join-Path $managerPath "start_server.bat"
        Get-ServerLaunchBatch `
            -InstallPath (Get-GamePath $server) `
            -ManagerPath $managerPath `
            -Game        $server.Game `
            -OutputPath  $batchPath | Out-Null

        # Regenerate server.cfg if RCON changed
        $srvMeta   = Get-GameMetadata -Game $server.Game
        $srvFolder = if ($srvMeta -and $srvMeta.GameFolder) { $srvMeta.GameFolder } else { $server.Game }
        $cfgFile   = Join-Path (Get-GamePath $server) "$srvFolder\cfg\server.cfg"
        if (Test-Path $cfgFile) {
            Generate-ServerCfg -ServerId $server.ServerId | Out-Null
        }
    }

    while ($true) {
        Show-Header
        Write-Host (Format-SectionTitle (Get-Message -Key "SrvSettings_Title" -MsgArgs @($server.Name)))
        Write-Host ""

        # Display current values with fallback to metadata defaults
        $meta = Get-GameMetadata -Game $server.Game

        $rconDisplay = if ([string]::IsNullOrWhiteSpace($sc.RconPassword)) {
            "[--] $(Get-Message -Key 'SrvSettings_NotSet')" } else { "[OK] ***" }

        $portVal  = Resolve-ServerParam -ManagerConfig $sc -Field "Port" `
            -MetadataDefault ($meta.DefaultGamePort) -HardcodedDefault 27016
        $ipVal    = if ($sc.LaunchIp) { $sc.LaunchIp } else { "($(Get-Message -Key 'SrvSettings_NotSet'))" }
        $extraVal = if ($sc.ExtraArgs -and $sc.ExtraArgs.Count -gt 0) {
            $sc.ExtraArgs -join " " } else { "($(Get-Message -Key 'SrvSettings_NotSet'))" }

        Write-Host "  1) $(Get-Message -Key 'SrvSettings_RconPassword'): $rconDisplay"
        Write-Host "  2) $(Get-Message -Key 'SrvSettings_Port'): $portVal"
        Write-Host "  3) $(Get-Message -Key 'SrvSettings_IpBinding'): $ipVal"
        Write-Host "  4) $(Get-Message -Key 'SrvSettings_ExtraArgs'): $extraVal"
        Write-Host "  0) $(Get-Message -Key 'Manage_Back')"
        Write-Host ""

        $action = Read-Host (Get-Message -Key "Common_Select")

        switch ($action) {

            "1" {
                Write-Host ""
                $pwd = Read-Host (Get-Message -Key "SrvSettings_RconPrompt")
                $sc | Add-Member -NotePropertyName RconPassword -NotePropertyValue $pwd -Force
                Save-ServerConfig
                Write-Host "`n$(Get-Message -Key 'SrvSettings_Saved')`n" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }

            "2" {
                Write-Host ""
                $portInput = Read-Host (Get-Message -Key "SrvSettings_PortPrompt")
                $newPort = 0
                if ([int]::TryParse($portInput, [ref]$newPort) -and $newPort -ge 1024 -and $newPort -le 65535) {
                    $sc | Add-Member -NotePropertyName Port -NotePropertyValue $newPort -Force
                    Save-ServerConfig
                    Write-Host "`n$(Get-Message -Key 'SrvSettings_Saved')`n" -ForegroundColor Green
                } else {
                    Write-Host "`n$(Get-Message -Key 'SrvSettings_PortInvalid')`n" -ForegroundColor Red
                }
                Start-Sleep -Seconds 1
            }

            "3" {
                Write-Host ""
                $newIp = (Read-Host (Get-Message -Key "SrvSettings_IpPrompt")).Trim()
                $sc | Add-Member -NotePropertyName LaunchIp -NotePropertyValue $newIp -Force
                Save-ServerConfig
                Write-Host "`n$(Get-Message -Key 'SrvSettings_Saved')`n" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }

            "4" {
                Write-Host ""
                $curExtra = if ($sc.ExtraArgs -and $sc.ExtraArgs.Count -gt 0) { $sc.ExtraArgs -join " " } else { "" }
                Write-Host "  $(Get-Message -Key 'SrvSettings_ExtraArgsCurrent'): $curExtra" -ForegroundColor DarkGray
                Write-Host ""
                $newExtra = (Read-Host (Get-Message -Key "SrvSettings_ExtraArgsPrompt")).Trim()
                $extraArray = if ([string]::IsNullOrWhiteSpace($newExtra)) { @() } else {
                    $newExtra -split '\s+(?=(?:[^"]*"[^"]*")*[^"]*$)'
                }
                $sc | Add-Member -NotePropertyName ExtraArgs -NotePropertyValue $extraArray -Force
                Save-ServerConfig
                Write-Host "`n$(Get-Message -Key 'SrvSettings_Saved')`n" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }

            "0" { return }

            default {
                Write-Host "`n$(Get-Message -Key 'Common_InvalidOption')`n" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

Export-ModuleMember -Function Get-ShortPath, Find-UnregisteredServers, Register-UnregisteredServers, Invoke-ListServers, Invoke-RenameServer, Invoke-MoveServer, Invoke-StartServer, Stop-ServerMonitoring, Get-CachedPublicIP, Invoke-NetworkMenu, Show-ServerStatusBox, Show-PlayersMenu, Invoke-ManageServer, Invoke-RestartServer, Invoke-ServerSettings
