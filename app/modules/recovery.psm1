function Test-ServerStructure {
    # Returns "managed" if path has manager/+server/ (tool structure)
    # Returns "flat"    if path has srcds.exe directly (external structure)
    # Returns $null     if not a recognizable server
    param([string]$Path)
    $hasManager = Test-Path (Join-Path $Path "manager")
    $hasServer  = Test-Path (Join-Path $Path "server")
    if ($hasManager -and $hasServer) { return "managed" }
    if (Test-Path (Join-Path $Path "srcds.exe")) { return "flat" }
    return $null
}

function Find-ServerCandidates {
    # Given a path, returns all valid server roots (managed or flat structure).
    # Checks the path itself, its parent, and immediate subfolders.
    param([string]$Path)

    $candidates = @()

    # 1. The selected path itself
    if ($null -ne (Test-ServerStructure -Path $Path)) {
        $candidates += $Path
        return $candidates
    }

    # 2. User may have selected a subfolder (server/, manager/, left4dead2/) by mistake
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($parent) -and ($null -ne (Test-ServerStructure -Path $parent))) {
        $candidates += $parent
        return $candidates
    }

    # 3. Scan immediate subfolders of selected path
    $subs = @(Get-ChildItem -Path $Path -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            (-not ($_.Attributes -band [System.IO.FileAttributes]::Hidden)) -and
            (-not ($_.Attributes -band [System.IO.FileAttributes]::System))
        } | Sort-Object Name)

    foreach ($sub in $subs) {
        if ($null -ne (Test-ServerStructure -Path $sub.FullName)) {
            $candidates += $sub.FullName
        }
    }

    return $candidates
}

function Invoke-RecoverSingle {
    # Registers one already-validated server root path.
    # If the server has a flat structure (srcds.exe in root), it is restructured
    # to our format (files moved into server/, manager/ created) before registration.
    # If restructuring fails, the import is cancelled with no side effects.
    param([string]$ServerRootPath)

    Show-Header
    Write-Host (Format-SectionTitle (Get-Message -Key "Recover_Title"))
    Write-Host ""

    # Check not already registered
    $existing = @(Get-ServerRegistry) | Where-Object { $_.Path -eq $ServerRootPath }
    if ($existing) {
        Write-Host "  $(Get-Message -Key 'Recover_AlreadyRegistered')" -ForegroundColor Yellow
        Write-Host ""
        Read-Host (Get-Message -Key "Common_PressEnter") | Out-Null
        return
    }

    $structureType = Test-ServerStructure -Path $ServerRootPath
    $folderName    = Split-Path -Leaf $ServerRootPath
    $gamePath      = Join-Path $ServerRootPath "server"
    $managerPath   = Join-Path $ServerRootPath "manager"

    Write-Host "  $(Get-Message -Key 'Recover_AutoDetected' -MsgArgs @($ServerRootPath))" -ForegroundColor DarkGray
    Write-Host ""

    # --- Flat structure: must restructure before registration ---
    if ($structureType -eq "flat") {
        Write-Host "  $(Get-Message -Key 'Recover_FlatStructure')" -ForegroundColor Yellow
        Write-Host ""
        $confirm = Read-Host (Get-Message -Key "Common_ConfirmPrompt")
        if ($confirm -ne (Get-Message -Key "ConfirmYes")) { return }

        Write-Host ""
        Write-Host "  $(Get-Message -Key 'Recover_Restructuring')" -ForegroundColor Cyan

        try {
            # 1. Create server/ and manager/ subfolders
            New-Item -ItemType Directory -Path $gamePath    -Force -ErrorAction Stop | Out-Null
            New-Item -ItemType Directory -Path $managerPath -Force -ErrorAction Stop | Out-Null

            # 2. Move all existing items (files and folders) into server/
            $items = @(Get-ChildItem -Path $ServerRootPath -ErrorAction Stop |
                Where-Object { $_.Name -ne "server" -and $_.Name -ne "manager" })

            foreach ($item in $items) {
                Move-Item -Path $item.FullName -Destination $gamePath -ErrorAction Stop
            }

            Write-Host "  $(Get-Message -Key 'Recover_RestructureDone')" -ForegroundColor Green
        }
        catch {
            Write-Log "Errore ristrutturazione server: $_" "ERROR"
            Write-Host ""
            Write-Host "  $(Get-Message -Key 'Recover_RestructureFailed' -MsgArgs @($_))" -ForegroundColor Red
            Write-Host "  $(Get-Message -Key 'Recover_ImportCancelled')" -ForegroundColor Red
            Write-Host ""
            # Attempt to clean up partially created folders
            if ((Test-Path $gamePath) -and (Get-ChildItem $gamePath).Count -eq 0) {
                Remove-Item $gamePath -Force -ErrorAction SilentlyContinue
            }
            if ((Test-Path $managerPath) -and (Get-ChildItem $managerPath).Count -eq 0) {
                Remove-Item $managerPath -Force -ErrorAction SilentlyContinue
            }
            Read-Host (Get-Message -Key "Common_PressEnter") | Out-Null
            return
        }
    }

    # --- At this point the structure is always managed (manager/+server/) ---

    # Try to read existing manager config
    $existingConfig = $null
    $configFile = Join-Path $managerPath "config.json"
    if (Test-Path $configFile) {
        try { $existingConfig = Get-Content $configFile -Raw | ConvertFrom-Json } catch { }
    }

    $nameInput  = (Read-Host "  $(Get-Message -Key 'Recover_NamePrompt')").Trim()
    $serverName = if ([string]::IsNullOrWhiteSpace($nameInput)) { $folderName } else { $nameInput }

    $nameError = Test-ServerName -Name $serverName
    if ($nameError) {
        Write-Host "`n$nameError`n" -ForegroundColor Red
        Read-Host (Get-Message -Key "Common_PressEnter") | Out-Null
        return
    }

    $duplicate = Get-ServerByName -Name $serverName
    if ($duplicate) {
        Write-Host "`n$(Get-Message -Key 'Recover_NameExists')`n" -ForegroundColor Red
        Read-Host (Get-Message -Key "Common_PressEnter") | Out-Null
        return
    }

    $diskStatus  = Get-ServerDiskStatus -Path $gamePath
    $regStatus   = if ($diskStatus -eq "Installed") { "Installed" } else { "Installing" }
    $statusLabel = if ($regStatus -eq "Installed") { Get-Message -Key "Recover_StatusInstalled" } else { Get-Message -Key "Recover_StatusIncomplete" }

    Write-Host ""
    Write-Host "  $(Get-Message -Key 'Recover_Confirm' -MsgArgs @($serverName, $ServerRootPath))" -ForegroundColor Cyan
    Write-Host "  $(Get-Message -Key 'ServerInfo_Status'): $statusLabel" -ForegroundColor DarkGray
    Write-Host ""
    $confirm = Read-Host (Get-Message -Key "Common_ConfirmPrompt")
    if ($confirm -ne (Get-Message -Key "ConfirmYes")) { return }

    $server = @{
        ServerId           = [guid]::NewGuid().ToString()
        Name               = $serverName
        Game               = if ($existingConfig -and $existingConfig.Game) { $existingConfig.Game } else { "l4d2" }
        Path               = $ServerRootPath
        Status             = $regStatus
        FirewallPort       = if ($existingConfig -and $existingConfig.FirewallPort) { [int]$existingConfig.FirewallPort } else { Get-NextAvailablePort -BasePort 27016 }
        ConfiguredMap      = if ($existingConfig -and $existingConfig.ConfiguredMap) { $existingConfig.ConfiguredMap } else { $null }
        ConfiguredGameMode = if ($existingConfig -and $existingConfig.ConfiguredGameMode) { $existingConfig.ConfiguredGameMode } else { $null }
        CreatedAt          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        LastUpdate         = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }

    Add-ServerToRegistry $server
    Write-Log "Server recuperato: $serverName -> $ServerRootPath" "INFO"

    Write-Host ""
    Write-Host "  $(Get-Message -Key 'Recover_Done')" -ForegroundColor Green
    Start-Sleep -Seconds 2
}

function Invoke-RecoverServer {
    Show-Header
    Write-Host (Format-SectionTitle (Get-Message -Key "Recover_Title"))
    Write-Host ""
    Write-Host "  $(Get-Message -Key 'Recover_Desc')" -ForegroundColor Cyan
    Write-Host ""
    Read-Host (Get-Message -Key "Common_PressEnter") | Out-Null

    $chosenPath = Select-FolderInteractive
    if ($null -eq $chosenPath) { return }

    # Auto-detect: handles wrong subfolder, parent folder, or container folder
    $candidates = @(Find-ServerCandidates -Path $chosenPath)

    if ($candidates.Count -eq 0) {
        Show-Header
        Write-Host ""
        Write-Host "  $(Get-Message -Key 'Recover_InvalidStructure')" -ForegroundColor Red
        Write-Host ""
        Read-Host (Get-Message -Key "Common_PressEnter") | Out-Null
        return
    }

    if ($candidates.Count -eq 1) {
        Invoke-RecoverSingle -ServerRootPath $candidates[0]
        return
    }

    # Multiple candidates - let user pick
    Show-Header
    Write-Host (Format-SectionTitle (Get-Message -Key "Recover_Title"))
    Write-Host ""
    Write-Host "  $(Get-Message -Key 'Recover_MultipleFound' -MsgArgs @($candidates.Count))" -ForegroundColor Cyan
    Write-Host ""
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host "  $($i + 1)) $($candidates[$i])"
    }
    Write-Host "  0) $(Get-Message -Key 'Common_Cancel')"
    Write-Host ""

    $sel = (Read-Host (Get-Message -Key "Common_Select")).Trim()
    if ($sel -eq "0" -or [string]::IsNullOrWhiteSpace($sel)) { return }

    if ($sel -match '^\d+$') {
        $idx = [int]$sel - 1
        if ($idx -ge 0 -and $idx -lt $candidates.Count) {
            Invoke-RecoverSingle -ServerRootPath $candidates[$idx]
            return
        }
    }

    Write-Host "`n$(Get-Message -Key 'Common_InvalidSelection')`n" -ForegroundColor Red
    Read-Host (Get-Message -Key "Common_PressEnter") | Out-Null
}

Export-ModuleMember -Function Test-ServerStructure, Find-ServerCandidates, Invoke-RecoverSingle, Invoke-RecoverServer
