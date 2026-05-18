$RootPath = $PSScriptRoot
Set-Location $RootPath

$host.ui.RawUI.WindowTitle = "Source Server Manager"



Import-Module "$RootPath\modules\messages.psm1"   -Force -Global -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\ui.psm1"         -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\logging.psm1"    -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\registry.psm1"   -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\validation.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\server.psm1"     -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\steamcmd.psm1"   -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\splash.psm1"     -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\launcher.psm1"   -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\server-monitor.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\server\server-config.psm1" -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\network.psm1"  -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\modding.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\rcon.psm1"             -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\sourcemod-admin.psm1"  -Force -WarningAction SilentlyContinue

$config = Get-Content "$RootPath\config\default_config.json" -Raw | ConvertFrom-Json

if (-not [System.IO.Path]::IsPathRooted($config.DefaultInstallRoot)) {
    $config.DefaultInstallRoot = Join-Path $RootPath $config.DefaultInstallRoot
}

$HeaderLimit = if ($config.HeaderServerLimit) { [int]$config.HeaderServerLimit } else { 5 }

# -------------------------------------------------------
# Selezione lingua (prima esecuzione o lingua non in config)
# -------------------------------------------------------

function Select-Language {
    param(
        [string]$LocaleDir,
        [string]$CancelLabel = ""
    )

    $files = @(Get-ChildItem "$LocaleDir\*.json" -ErrorAction SilentlyContinue | Sort-Object BaseName)
    if ($files.Count -eq 0) { return "it" }

    $langs = @()
    foreach ($f in $files) {
        try {
            $d = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $name = if ($d.LanguageName) { $d.LanguageName } else { $f.BaseName }
            $langs += [PSCustomObject]@{ Code = $f.BaseName; Name = $name }
        } catch { }
    }

    if ($langs.Count -eq 0) { return "it" }
    if ($langs.Count -eq 1 -and $CancelLabel -eq "") { return $langs[0].Code }

    Clear-Host
    Write-Host "====================================="
    Write-Host " L4D2 Dedicated Server Manager"
    Write-Host "====================================="
    Write-Host ""

    for ($i = 0; $i -lt $langs.Count; $i++) {
        Write-Host "  $($i + 1)) $($langs[$i].Name)"
    }
    if ($CancelLabel -ne "") {
        Write-Host "  0) $CancelLabel"
    }
    Write-Host ""

    while ($true) {
        $raw = Read-Host ">"
        if ($CancelLabel -ne "" -and $raw -eq "0") { return $null }
        if ($raw -match '^\d+$') {
            $idx = [int]$raw - 1
            if ($idx -ge 0 -and $idx -lt $langs.Count) {
                return $langs[$idx].Code
            }
        }
    }
}

function Save-Language {
    param([string]$ConfigPath, [string]$LangCode)
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $cfg.Language = $LangCode
    $cfg | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath -Encoding UTF8
}

if ([string]::IsNullOrWhiteSpace($config.Language)) {
    $chosenLang = Select-Language -LocaleDir "$RootPath\locale"
    Save-Language -ConfigPath "$RootPath\config\default_config.json" -LangCode $chosenLang
    $config.Language = $chosenLang
}

# -------------------------------------------------------
# Caricamento locale
# -------------------------------------------------------

$localeFile = "$RootPath\locale\$($config.Language).json"
if (-not (Test-Path $localeFile)) { $localeFile = "$RootPath\locale\it.json" }
$localeData = Get-Content $localeFile -Raw | ConvertFrom-Json
Set-Messages $localeData

# -------------------------------------------------------
# Splash screen
# -------------------------------------------------------
Show-Splash
Read-Host "Premi INVIO per continuare"

# -------------------------------------------------------
# Avvio
# -------------------------------------------------------

Write-Log "Manager avviato" "INFO"
Validate-ServerRegistry | Out-Null

# --- HELPERS ---

function Format-SectionTitle {
    param([string]$Title)
    $width = 37
    $inner = " $Title "
    $remaining = $width - $inner.Length
    if ($remaining -lt 0) { $remaining = 0 }
    $left  = [Math]::Floor($remaining / 2)
    $right = $remaining - $left
    return ("=" * $left) + $inner + ("=" * $right)
}

function Get-ShortPath {
    param([string]$Path)
    $prefix = $RootPath + "\"
    if ($Path.StartsWith($prefix)) {
        return $Path.Substring($prefix.Length)
    }
    return $Path
}

function Show-ServerSummary {
    $servers = @(Get-ServerRegistry)
    $sep = "====================================="

    Write-Host (Get-Message -Key "Header_ServerLabel")

    if ($servers.Count -eq 0) {
        Write-Host (Get-Message -Key "Header_NoServers") -ForegroundColor DarkGray
        Write-Host $sep
        Write-Host ""
        return $false
    }

    $shown = [Math]::Min($servers.Count, $HeaderLimit)

    for ($i = 0; $i -lt $shown; $i++) {
        $s = $servers[$i]
        $disk = Get-ServerDiskStatus -Path (Join-Path $s.Path "server")

        if ($disk -eq "Installed" -and $s.Status -eq "Installed") {
            $symbol = "[OK]"; $color = "Green"
        } elseif ($s.Status -eq "Installing") {
            $symbol = "[>>]"; $color = "Cyan"
        } elseif ($disk -eq "Missing") {
            $symbol = "[--]"; $color = "Red"
        } else {
            $symbol = "[!!]"; $color = "Yellow"
        }

        $shortPath = Get-ShortPath -Path $s.Path
        $namePad = $s.Name.PadRight(16)
        Write-Host "  $symbol  $namePad $shortPath" -ForegroundColor $color
    }

    $hidden = $servers.Count - $shown
    if ($hidden -gt 0) {
        Write-Host (Get-Message -Key "Header_HiddenServers" -MsgArgs @($hidden)) -ForegroundColor DarkGray
    }

    Write-Host $sep
    Write-Host ""
    return ($hidden -gt 0)
}

# --- MENU ---

function Show-Menu {
    param(
        [bool]$ShowListOption = $false,
        [bool]$HasIncomplete  = $false
    )

    Write-Host "  1) $(Get-Message -Key 'Menu_CreateServer')"
    if ($ShowListOption) {
        Write-Host "  2) $(Get-Message -Key 'Menu_ListServers')"
        Write-Host "  3) $(Get-Message -Key 'Menu_ManageServer')"
        if ($HasIncomplete) {
            Write-Host "  4) $(Get-Message -Key 'Menu_ResumeInstall')"
        } else {
            Write-Host "  4) $(Get-Message -Key 'Menu_ResumeInstall')" -ForegroundColor DarkGray
        }
        Write-Host "  5) $(Get-Message -Key 'Menu_Settings')"
        Write-Host "  6) $(Get-Message -Key 'Menu_Exit')"
    } else {
        Write-Host "  2) $(Get-Message -Key 'Menu_ManageServer')"
        if ($HasIncomplete) {
            Write-Host "  3) $(Get-Message -Key 'Menu_ResumeInstall')"
        } else {
            Write-Host "  3) $(Get-Message -Key 'Menu_ResumeInstall')" -ForegroundColor DarkGray
        }
        Write-Host "  4) $(Get-Message -Key 'Menu_Settings')"
        Write-Host "  5) $(Get-Message -Key 'Menu_Exit')"
    }
    Write-Host ""
}

# --- INSTALLAZIONE ---

function Start-ServerInstall {
    param($target)

    $gamePath    = Join-Path $target.Path "server"
    $managerPath = Join-Path $target.Path "manager"

    if (-not (Test-Path $target.Path)) {
        New-Item -ItemType Directory -Path $target.Path -Force | Out-Null
    }
    if (-not (Test-Path $gamePath)) {
        New-Item -ItemType Directory -Path $gamePath -Force | Out-Null
    }
    if (-not (Test-Path $managerPath)) {
        New-Item -ItemType Directory -Path $managerPath -Force | Out-Null
    }

    $managerConfig = Join-Path $managerPath "config.json"
    if (-not (Test-Path $managerConfig)) {
        @{ RconPassword = ""; Notes = "" } | ConvertTo-Json | Set-Content $managerConfig -Encoding UTF8
    }

    $steamDir = Join-Path $RootPath "downloads\steamcmd"
    if (-not (Test-Path $steamDir)) {
        New-Item -ItemType Directory -Path $steamDir -Force | Out-Null
    }

    Write-Host "`n$(Get-Message -Key 'Install_Starting' -MsgArgs @($target.Name))`n" -ForegroundColor Cyan
    Write-Host (Get-Message -Key "Install_SteamCmdNote")
    Write-Host ""

    Update-ServerStatus -ServerId $target.ServerId -Status "Installing"

    try {
        $exe = Install-SteamCMD -Path $steamDir
        Install-L4D2Server -SteamCmdPath $exe -InstallDir $gamePath -SteamCmdDir $steamDir
        Update-ServerStatus -ServerId $target.ServerId -Status "Installed"
        Write-Log "Installazione completata: $($target.Path)" "INFO"
        Write-Host "`n$(Get-Message -Key 'Install_Done')`n" -ForegroundColor Green
    }
    catch {
        Update-ServerStatus -ServerId $target.ServerId -Status "Error"
        Write-Log "Errore installazione: $_" "ERROR"
        Write-Host "`n$(Get-Message -Key 'Install_Failed' -MsgArgs @($_))`n" -ForegroundColor Red
    }

    Read-Host (Get-Message -Key "Common_PressEnter")
}

# --- AZIONI MENU PRINCIPALE ---

function Invoke-CreateServer {
    Show-Header
    Write-Host (Format-SectionTitle (Get-Message -Key "Create_Title"))
    Write-Host ""

    $serverName = Read-Host (Get-Message -Key "Create_NamePrompt")

    $nameError = Test-ServerName -Name $serverName
    if ($nameError) {
        Write-Host "`n$nameError`n" -ForegroundColor Red
        Read-Host (Get-Message -Key "Common_PressEnter")
        return
    }

    $existing = Get-ServerByName -Name $serverName
    if ($existing) {
        Write-Host "`n$(Get-Message -Key 'Create_NameExists')`n" -ForegroundColor Red
        Read-Host (Get-Message -Key "Common_PressEnter")
        return
    }

    $defaultPath = Join-Path $config.DefaultInstallRoot $serverName
    Write-Host (Get-Message -Key "Create_PathDefault" -MsgArgs @($defaultPath))
    $pathInput = Read-Host (Get-Message -Key "Create_PathPrompt")

    $finalPath = if ([string]::IsNullOrWhiteSpace($pathInput)) { $defaultPath } else { $pathInput.Trim() }

    $pathError = Test-ServerPath -Path $finalPath
    if ($pathError -and $pathError.StartsWith("WARN:")) {
        $warnMsg = $pathError.Substring(5)
        Write-Host "`n[!!] $warnMsg`n" -ForegroundColor Yellow
        $go = Read-Host (Get-Message -Key "Common_ContinueAnyway")
        if ($go -ne (Get-Message -Key "ConfirmYes")) { return }
    }
    elseif ($pathError) {
        Write-Host "`n$pathError`n" -ForegroundColor Red
        Read-Host (Get-Message -Key "Common_PressEnter")
        return
    }

    if (-not (Test-Path $finalPath)) {
        New-Item -ItemType Directory -Path $finalPath -Force | Out-Null
    }
    $gameSubPath    = Join-Path $finalPath "server"
    $managerSubPath = Join-Path $finalPath "manager"
    if (-not (Test-Path $gameSubPath))    { New-Item -ItemType Directory -Path $gameSubPath    -Force | Out-Null }
    if (-not (Test-Path $managerSubPath)) { New-Item -ItemType Directory -Path $managerSubPath -Force | Out-Null }

    $server = @{
        ServerId   = [guid]::NewGuid().ToString()
        Name       = $serverName
        Game       = "l4d2"
        Path       = $finalPath
        Status     = "Installing"
        CreatedAt  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        LastUpdate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }

    Add-ServerToRegistry $server
    Write-Log "Server registrato: $serverName -> $finalPath" "INFO"

    Start-ServerInstall $server

    $fresh = @(Get-ServerRegistry) | Where-Object { $_.ServerId -eq $server.ServerId } | Select-Object -First 1
    if ($fresh -and (Get-ServerDiskStatus -Path (Join-Path $fresh.Path "server")) -eq "Installed") {
        Write-Host ""
        $runWizard = Read-Host (Get-Message -Key "Wizard_LaunchPrompt")
        if ($runWizard -eq (Get-Message -Key "ConfirmYes")) {
            Invoke-SetupWizard -Server $fresh -RootPath $RootPath | Out-Null
        }
    }
}

function Invoke-ListServers {
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
            $disk = Get-ServerDiskStatus -Path (Join-Path $s.Path "server")
            Write-Host (Get-Message -Key "List_Name"     -MsgArgs @($s.Name))
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

function Invoke-ResumeInstallation {
    Show-Header
    Write-Host (Format-SectionTitle (Get-Message -Key "Resume_Title"))
    Write-Host ""

    $candidates = @(Get-ServerRegistry | Where-Object {
        $_.Status -ne "Installed" -or (Get-ServerDiskStatus -Path (Join-Path $_.Path "server")) -ne "Installed"
    })

    if ($candidates.Count -eq 0) {
        Write-Host "$(Get-Message -Key 'Resume_AllInstalled')`n"
        Read-Host (Get-Message -Key "Common_PressEnter")
        return
    }

    if ($candidates.Count -eq 1) {
        $target = $candidates[0]
		
        $disk = Get-ServerDiskStatus -Path (Join-Path $target.Path "server")
        Write-Host (Get-Message -Key "Resume_Server" -MsgArgs @($target.Name))
        Write-Host (Get-Message -Key "Resume_Path"   -MsgArgs @($target.Path))
        Write-Host (Get-Message -Key "Resume_Disk"   -MsgArgs @($disk))
        Write-Host ""
        $confirm = Read-Host (Get-Message -Key "Resume_ConfirmPrompt")
        if ($confirm -ne (Get-Message -Key "ConfirmYes")) { return }
		
        Start-ServerInstall $target
		
        return
    }

    $diskLabel = Get-Message -Key "Resume_DiskLabel"
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $disk = Get-ServerDiskStatus -Path (Join-Path $candidates[$i].Path "server")
        $num = $i + 1
        Write-Host "  $num) $($candidates[$i].Name)  [$($diskLabel): $disk]  $($candidates[$i].Path)"
    }
    Write-Host ""
    $sel = Read-Host (Get-Message -Key "Common_SelectNumber")
    if ($sel -eq "0" -or [string]::IsNullOrWhiteSpace($sel)) { return }

    $idx = [int]$sel - 1
    if ($idx -lt 0 -or $idx -ge $candidates.Count) {
        Write-Host "`n$(Get-Message -Key 'Common_InvalidSelection')`n" -ForegroundColor Red
        Read-Host (Get-Message -Key "Common_PressEnter")
        return
    }

    Start-ServerInstall $candidates[$idx]
}

# --- SOTTOMENU GESTISCI SERVER ---

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
    param($server)

    Write-Host "`n$(Get-Message -Key 'Move_Title')`n"
    Write-Host (Get-Message -Key "Move_CurrentPath" -MsgArgs @($server.Path))
    $newPath = Read-Host (Get-Message -Key "Move_NewPathPrompt")
    if ([string]::IsNullOrWhiteSpace($newPath) -or $newPath.Trim() -eq $server.Path) { return $false }
    $newPath = $newPath.Trim()

    if (Test-Path $newPath) {
        Write-Host "`n$(Get-Message -Key 'Move_DestExists')`n" -ForegroundColor Red
        Read-Host (Get-Message -Key "Common_PressEnter")
        return $false
    }

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
    param($server)

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

    $gamePath    = Join-Path $server.Path "server"
    $managerPath = Join-Path $server.Path "manager"
    $map         = $server.ConfiguredMap
    $gameMode    = $server.ConfiguredGameMode
    $port        = if ($server.FirewallPort) { [int]$server.FirewallPort } else { 27016 }

    Write-Host "`n$(Get-Message -Key 'Start_Starting')`n"

    try {
        if ($modeChoice -eq "1") {
            $serverPID = Start-ServerNormal -InstallPath $gamePath -GameMode $gameMode -Map $map -Port $port

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
Start-ServerWithMonitoring -InstallPath '$gamePath' -ManagerPath '$managerPath' -GameMode '$gameMode' -Map '$map' -Port $port
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

    $runningFile = Join-Path (Join-Path $server.Path "manager") ".running"
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

function Show-ServerStatusBox {
    param($server)

    $gamePath    = Join-Path $server.Path "server"
    $managerPath = Join-Path $server.Path "manager"

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
                $psProcess = Get-Process -Id $runningData.PowerShellPID -ErrorAction SilentlyContinue
                if ($psProcess) { $processFound = $true }
            }

            if (-not $processFound -and $runningData.ServerProcessId) {
                $serverProcess = Get-Process -Id $runningData.ServerProcessId -ErrorAction SilentlyContinue
                if ($serverProcess) { $processFound = $true }
            }

            if ($processFound) {
                $isRunning = $true
            }
        } catch { }
    }

    # Installation Status
    if ($disk -eq "Installed" -and $server.Status -eq "Installed") {
        $instSymbol = "[OK]"; $instColor = "Green"; $instText = "ServerInfo_Installed"
    } elseif ($server.Status -eq "Installing") {
        $instSymbol = "[>>]"; $instColor = "Cyan"; $instText = "ServerInfo_Installing"
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

    # Firewall Status
    $fwPort = if ($server.FirewallPort) { [int]$server.FirewallPort } else { 27016 }
    $rule = Get-ServerFirewallRule -ServerName $server.Name
    if ($rule) {
        $fwSymbol = "[OK]"; $fwColor = "Green"; $fwText = "ServerInfo_FirewallOpen"
    } else {
        $fwSymbol = "[CLOSED]"; $fwColor = "Red"; $fwText = "ServerInfo_FirewallClosed"
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

    $playersLabel = ""

    if ($rconPasswordSet -and $isRunning) {
        $statusResp = Invoke-ServerRcon -Server $server -Command "status"
        if ($null -ne $statusResp) {
            $rconLabel = Get-Message -Key "ServerInfo_RconActive"
            if ($statusResp -match 'players\s*:\s*(\d+)\s+humans.*?\((\d+)\s+max\)') {
                $playersLabel = "  -  $(Get-Message -Key 'ServerInfo_Players' -MsgArgs @($Matches[1], $Matches[2]))"
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

    [Console]::SetCursorPosition(0, $loadingRow)
    Write-Host (" " * ([Console]::WindowWidth - 1)) -NoNewline
    [Console]::SetCursorPosition(0, $loadingRow)

    Write-Host ""
    Write-Host "  $(Get-Message -Key 'ServerInfo_Installation'): $instSymbol $(Get-Message -Key $instText)" -ForegroundColor $instColor
    Write-Host "  $(Get-Message -Key 'ServerInfo_Configuration'): $cfgSymbol $(Get-Message -Key $cfgText)" -ForegroundColor $cfgColor

    if (-not [string]::IsNullOrWhiteSpace($server.ConfiguredMap)) {
        Write-Host "  Map: $($server.ConfiguredMap)"
    }
    if (-not [string]::IsNullOrWhiteSpace($server.ConfiguredGameMode)) {
        Write-Host "  GameMode: $($server.ConfiguredGameMode)"
    }

    Write-Host "  $(Get-Message -Key 'ServerInfo_Port' -MsgArgs @($fwPort)): $fwSymbol $(Get-Message -Key $fwText)" -ForegroundColor $fwColor
    Write-Host "  $(Get-Message -Key 'ServerInfo_MetaMod'):   $mmSymbol $mmLabel" -ForegroundColor $mmColor
    Write-Host "  $(Get-Message -Key 'ServerInfo_SourceMod'): $smSymbol $smLabel" -ForegroundColor $smColor
    Write-Host "  $(Get-Message -Key 'ServerInfo_Status'): $runSymbol $(Get-Message -Key $runText)" -ForegroundColor $runColor
    Write-Host "  RCON: $rconSymbol $rconLabel$playersLabel" -ForegroundColor $rconColor
    Write-Host ""
}

function Show-PlayersMenu {
    param([object]$Server)

    $gamePath = Join-Path $Server.Path "server"
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
            $disk = Get-ServerDiskStatus -Path (Join-Path $s.Path "server")
            $num = $i + 1
            $shortPath = Get-ShortPath -Path $s.Path
            $namePad = $s.Name.PadRight(16)

            if ($disk -eq "Installed" -and $s.Status -eq "Installed") {
                $symbol = "[OK]"; $color = "Green"
            } elseif ($s.Status -eq "Installing") {
                $symbol = "[>>]"; $color = "Cyan"
            } elseif ($disk -eq "Missing") {
                $symbol = "[--]"; $color = "Red"
            } else {
                $symbol = "[!!]"; $color = "Yellow"
            }

            Write-Host "  $num) " -NoNewline
            Write-Host "$symbol  $namePad $shortPath" -ForegroundColor $color
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
        $disk        = Get-ServerDiskStatus -Path (Join-Path $selected.Path "server")
        $shortPath   = Get-ShortPath -Path $selected.Path
        $managerPath = Join-Path $selected.Path "manager"
        $runningFile = Join-Path $managerPath ".running"
        $isRunning   = $false

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

        Write-Host (Format-SectionTitle $selected.Name)
        Write-Host "  $shortPath" -ForegroundColor DarkGray

        Show-ServerStatusBox -server $selected

        Write-Host "  --- SERVER ---" -ForegroundColor DarkGray
        if ($isRunning) {
            Write-Host "  1) $(Get-Message -Key 'Manage_Stop')"  -ForegroundColor Yellow
            Write-Host "  2) $(Get-Message -Key 'Manage_Restart')" -ForegroundColor Yellow
        } else {
            Write-Host "  1) $(Get-Message -Key 'Manage_Start')"
            Write-Host "  2) $(Get-Message -Key 'Manage_Restart')" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "  --- PLAYERS ---" -ForegroundColor DarkGray
        if ($isRunning) {
            Write-Host "  P) $(Get-Message -Key 'Manage_Players')"
        } else {
            Write-Host "  P) $(Get-Message -Key 'Manage_Players')" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "  --- CONFIGURATION ---" -ForegroundColor DarkGray
        Write-Host "  3) $(Get-Message -Key 'Manage_ChangeSettings')"
        Write-Host "  4) $(Get-Message -Key 'Manage_Firewall') (admin)"
        Write-Host "  5) $(Get-Message -Key 'Manage_Mods')"
        Write-Host "  6) $(Get-Message -Key 'Manage_Admins')"
        Write-Host "  7) $(Get-Message -Key 'Manage_ServerSettings')"
        Write-Host "  8) $(Get-Message -Key 'Manage_Plugins')" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  --- MANAGEMENT ---" -ForegroundColor DarkGray
        Write-Host "  9) $(Get-Message -Key 'Manage_Update')"
        Write-Host " 10) $(Get-Message -Key 'Manage_OpenFolder')"
        Write-Host " 11) $(Get-Message -Key 'Manage_Rename')"
        Write-Host " 12) $(Get-Message -Key 'Manage_Move')"
        Write-Host " 13) $(Get-Message -Key 'Manage_Delete')"
        Write-Host ""
        Write-Host "  W) $(Get-Message -Key 'Manage_Wizard')" -ForegroundColor Cyan
        Write-Host "  D) RCON Diagnostics [DEBUG]" -ForegroundColor DarkGray
        Write-Host "  0) $(Get-Message -Key 'Manage_Back')"
        Write-Host ""

        $action = Read-Host (Get-Message -Key "Common_Select")

        switch ($action) {
            "1" {
                $runningFile = Join-Path (Join-Path $selected.Path "manager") ".running"
                if (Test-Path $runningFile) {
                    $confirm = Read-Host (Get-Message -Key "Common_ConfirmPrompt")
                    if ($confirm -eq (Get-Message -Key "ConfirmYes")) {
                        Stop-ServerMonitoring $selected
                        Read-Host (Get-Message -Key "Common_PressEnter")
                    }
                } else {
                    $result = Invoke-StartServer $selected
                }
            }
            "2" {
                Invoke-RestartServer $selected
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
                $fwPort = if ($selected.FirewallPort) { [int]$selected.FirewallPort } else { 27016 }
                Invoke-FirewallManagement -ServerName $selected.Name -RootPath $RootPath -Language $config.Language -Port $fwPort
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
                if ($confirm -eq (Get-Message -Key "ConfirmYes")) { Start-ServerInstall $selected }
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
                $changed = Invoke-MoveServer $selected
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
                Show-PlayersMenu -Server $selected
            }
            { $_ -in "D","d" } {
                Write-Host ""
                Write-Host "  === RCON DIAGNOSTICS ===" -ForegroundColor Cyan
                $dbgPort = if ($selected.FirewallPort) { [int]$selected.FirewallPort } else { 27016 }
                Write-Host "  Server.Path     : $($selected.Path)"
                Write-Host "  Server.FwPort   : $($selected.FirewallPort) -> using $dbgPort"
                $dbgCfgFile = Join-Path (Join-Path $selected.Path "manager") "config.json"
                Write-Host "  Config file     : $dbgCfgFile"
                if (Test-Path $dbgCfgFile) {
                    Write-Host "  Config exists   : YES" -ForegroundColor Green
                    try {
                        $dbgCfg = Get-Content $dbgCfgFile -Raw | ConvertFrom-Json
                        $pwdSet = -not [string]::IsNullOrWhiteSpace($dbgCfg.RconPassword)
                        Write-Host "  RconPassword    : $(if ($pwdSet) { "SET (len=$($dbgCfg.RconPassword.Length))" } else { "EMPTY" })" -ForegroundColor $(if ($pwdSet) {"Green"} else {"Red"})
                    } catch { Write-Host "  Config parse err: $_" -ForegroundColor Red }
                } else {
                    Write-Host "  Config exists   : NO" -ForegroundColor Red
                }
                Write-Host ""
                $dbgAddr = Find-RconAddress -Port $dbgPort
                Write-Host "  RCON address    : $(if ($dbgAddr) { $dbgAddr } else { 'NOT FOUND' })" -ForegroundColor $(if ($dbgAddr) {"Cyan"} else {"Red"})
                if ($dbgAddr) {
                    Write-Host "  TCP connect test to ${dbgAddr}:$dbgPort ..." -ForegroundColor DarkGray
                    try {
                        $dbgTcp = New-Object System.Net.Sockets.TcpClient
                        $ok = $dbgTcp.ConnectAsync($dbgAddr, $dbgPort).Wait(3000)
                        if ($dbgTcp.Connected) {
                            Write-Host "  TCP connect     : OK" -ForegroundColor Green
                            $dbgTcp.Close()
                        } else {
                            Write-Host "  TCP connect     : FAILED (timeout)" -ForegroundColor Red
                        }
                    } catch {
                        Write-Host "  TCP connect     : FAILED ($_)" -ForegroundColor Red
                    }
                }
                Write-Host ""
                Write-Host "  Checking listening ports for srcds..." -ForegroundColor DarkGray
                $tcpConns = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -gt 27000 -and $_.LocalPort -lt 27100 }
                if ($tcpConns) {
                    foreach ($c in $tcpConns) { Write-Host "  TCP Listen      : $($c.LocalAddress):$($c.LocalPort) (PID $($c.OwningProcess))" -ForegroundColor Cyan }
                } else {
                    Write-Host "  TCP Listen      : no ports 27000-27100 found" -ForegroundColor Yellow
                }
                Write-Host ""
                Read-Host (Get-Message -Key "Common_PressEnter")
            }
            "0" { return }
            default {
                Write-Host "`n$(Get-Message -Key 'Common_InvalidOption')`n" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

# --- RIAVVIO SERVER ---

function Invoke-RestartServer {
    param($server)

    $managerPath = Join-Path $server.Path "manager"
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

    $gamePath = Join-Path $server.Path "server"
    $port     = if ($server.FirewallPort) { [int]$server.FirewallPort } else { 27016 }

    Write-Host ""
    Write-Host "$(Get-Message -Key 'Start_SelectMode'):`n"
    Write-Host "  1) $(Get-Message -Key 'Start_NormalMode')"
    Write-Host "  2) $(Get-Message -Key 'Start_AutoRestartMode')"
    Write-Host ""
    $modeChoice = Read-Host (Get-Message -Key "Common_Select")

    if ($modeChoice -eq "1") {
        $newPid = Start-ServerNormal -InstallPath $gamePath -GameMode $fresh.ConfiguredGameMode -Map $fresh.ConfiguredMap -Port $port
        if ($newPid -gt 0) {
            @{
                ServerPath      = $server.Path
                ServerName      = $server.Name
                ServerProcessId = $newPid
                StartedAt       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            } | ConvertTo-Json | Set-Content $runningFile -Encoding UTF8
            Write-Host "`n$(Get-Message -Key 'Mod_RestartDone')`n" -ForegroundColor Green
        } else {
            Write-Host "`n$(Get-Message -Key 'Mod_RestartFailed')`n" -ForegroundColor Red
        }
    } elseif ($modeChoice -eq "2") {
        $monitoringScript = @"
`$RootPath = '$RootPath'
`$host.ui.RawUI.WindowTitle = 'Monitoring: $($server.Name)'
Import-Module "`$RootPath\modules\server-monitor.psm1" -Force
Import-Module "`$RootPath\modules\logging.psm1" -Force
Start-ServerWithMonitoring -InstallPath '$gamePath' -ManagerPath '$managerPath' -GameMode '$($fresh.ConfiguredGameMode)' -Map '$($fresh.ConfiguredMap)' -Port $port
"@
        $process = Start-Process powershell.exe -ArgumentList "-NoExit", "-Command", $monitoringScript -WindowStyle Normal -PassThru
        @{
            ServerPath    = $server.Path
            ServerName    = $server.Name
            PowerShellPID = $process.Id
            StartedAt     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        } | ConvertTo-Json | Set-Content $runningFile -Encoding UTF8
        Write-Host "`n$(Get-Message -Key 'Mod_RestartDone')`n" -ForegroundColor Green
    }

    Read-Host (Get-Message -Key "Common_PressEnter")
}

# --- SETUP WIZARD ---

function Invoke-SetupWizard {
    param(
        [object]$Server,
        [string]$RootPath
    )

    $totalSteps = 6

    function Write-WizardStep {
        param([int]$n, [string]$title)
        Write-Host ""
        Write-Host "  $(Get-Message -Key 'Wizard_Step' -MsgArgs @($n, $totalSteps)) - $title" -ForegroundColor Cyan
        Write-Host "  $('-' * 50)" -ForegroundColor DarkGray
    }

    function Read-WizardReconfigure {
        $ans = Read-Host (Get-Message -Key "Wizard_Reconfigure")
        return ($ans -eq (Get-Message -Key "ConfirmYes"))
    }

    Show-Header
    Write-Host (Format-SectionTitle (Get-Message -Key "Wizard_Title"))
    Write-Host ""
    Write-Host "  $(Get-Message -Key 'Wizard_Intro')" -ForegroundColor DarkGray
    Write-Host ""
    Read-Host (Get-Message -Key "Common_PressEnter")

    # --- STEP 1: Server info (hostname, rcon_password, sv_steamgroup) ---
    Write-WizardStep 1 (Get-Message -Key "Wizard_Step1_Title")

    $managerPath = Join-Path $Server.Path "manager"
    $configPath  = Join-Path $managerPath "config.json"
    $serverConfig = if (Test-Path $configPath) {
        Get-Content $configPath -Raw | ConvertFrom-Json
    } else {
        [PSCustomObject]@{ RconPassword = ""; Notes = "" }
    }

    $cfgFile = Join-Path (Join-Path $Server.Path "server") "left4dead2\cfg\server.cfg"
    $currentHostname = ""
    $currentSteamGroup = ""
    if (Test-Path $cfgFile) {
        $cfgContent = Get-Content $cfgFile -Raw
        if ($cfgContent -match '(?m)^hostname\s+"?([^"\r\n]+)"?') { $currentHostname = $matches[1].Trim() }
        if ($cfgContent -match '(?m)^sv_steamgroup\s+"?([^"\r\n]+)"?') { $currentSteamGroup = $matches[1].Trim() }
    }

    $hasRcon = -not [string]::IsNullOrWhiteSpace($serverConfig.RconPassword)
    $hasHostname = -not [string]::IsNullOrWhiteSpace($currentHostname)

    $doStep1 = $true
    if ($hasRcon -and $hasHostname) {
        Write-Host "  $(Get-Message -Key 'Wizard_AlreadyDone')" -ForegroundColor Green
        Write-Host "  $(Get-Message -Key 'Wizard_Step1_HostnameSet' -MsgArgs @($currentHostname))" -ForegroundColor DarkGray
        Write-Host "  $(Get-Message -Key 'Wizard_Step1_RconSet')" -ForegroundColor DarkGray
        if (-not [string]::IsNullOrWhiteSpace($currentSteamGroup)) {
            Write-Host "  $(Get-Message -Key 'Wizard_Step1_SteamGroupSet' -MsgArgs @($currentSteamGroup))" -ForegroundColor DarkGray
        }
        Write-Host ""
        $doStep1 = Read-WizardReconfigure
    }

    if ($doStep1) {
        Write-Host ""
        $hostname = (Read-Host (Get-Message -Key "Wizard_Step1_Hostname")).Trim()
        if ([string]::IsNullOrWhiteSpace($hostname)) { $hostname = $currentHostname }

        $rconPwd = (Read-Host (Get-Message -Key "SrvSettings_RconPrompt")).Trim()
        if ([string]::IsNullOrWhiteSpace($rconPwd)) { $rconPwd = $serverConfig.RconPassword }

        $steamGroup = (Read-Host (Get-Message -Key "Wizard_Step1_SteamGroup")).Trim()
        if ([string]::IsNullOrWhiteSpace($steamGroup)) { $steamGroup = $currentSteamGroup }

        $serverConfig | Add-Member -NotePropertyName RconPassword -NotePropertyValue $rconPwd -Force
        if (-not (Test-Path $managerPath)) { New-Item -ItemType Directory -Path $managerPath -Force | Out-Null }
        $serverConfig | ConvertTo-Json | Set-Content $configPath -Encoding UTF8

        if (Test-Path $cfgFile) {
            $cfgContent = Get-Content $cfgFile -Raw
            if (-not [string]::IsNullOrWhiteSpace($hostname)) {
                $cfgContent = $cfgContent -replace '(?m)^hostname\s+.*', "hostname `"$hostname`""
                if ($cfgContent -notmatch '(?m)^hostname\s+') { $cfgContent = "hostname `"$hostname`"`n" + $cfgContent }
            }
            if (-not [string]::IsNullOrWhiteSpace($steamGroup)) {
                $cfgContent = $cfgContent -replace '(?m)^sv_steamgroup\s+.*', "sv_steamgroup `"$steamGroup`""
                if ($cfgContent -notmatch '(?m)^sv_steamgroup\s+') { $cfgContent += "`nsv_steamgroup `"$steamGroup`"" }
            }
            if (-not [string]::IsNullOrWhiteSpace($rconPwd)) {
                $cfgContent = $cfgContent -replace '(?m)^rcon_password\s+.*', "rcon_password `"$rconPwd`""
                if ($cfgContent -notmatch '(?m)^rcon_password\s+') { $cfgContent += "`nrcon_password `"$rconPwd`"" }
            }
            $utf8Bom = New-Object System.Text.UTF8Encoding $true
            [System.IO.File]::WriteAllText($cfgFile, $cfgContent, $utf8Bom)
        }
        Write-Host "`n  $(Get-Message -Key 'Config_Done')" -ForegroundColor Green
    }

    # --- STEP 2: Map & Gamemode ---
    Write-WizardStep 2 (Get-Message -Key "Wizard_Step2_Title")

    $Server = @(Get-ServerRegistry) | Where-Object { $_.ServerId -eq $Server.ServerId } | Select-Object -First 1
    $hasMap = -not [string]::IsNullOrWhiteSpace($Server.ConfiguredMap) -and -not [string]::IsNullOrWhiteSpace($Server.ConfiguredGameMode)

    $doStep2 = $true
    if ($hasMap) {
        Write-Host "  $(Get-Message -Key 'Wizard_AlreadyDone'): $($Server.ConfiguredMap) / $($Server.ConfiguredGameMode)" -ForegroundColor Green
        Write-Host ""
        $doStep2 = Read-WizardReconfigure
    }

    if ($doStep2) {
        Write-Host ""
        $result = Update-ServerMapAndGameMode -ServerId $Server.ServerId
        if ($result) {
            $Server = @(Get-ServerRegistry) | Where-Object { $_.ServerId -eq $Server.ServerId } | Select-Object -First 1
            Write-Host "`n  $(Get-Message -Key 'Config_Done')" -ForegroundColor Green
        }
    }

    # --- STEP 3: Networking & Firewall ---
    Write-WizardStep 3 (Get-Message -Key "Wizard_Step3_Title")
    Write-Host "  $(Get-Message -Key 'Wizard_Step3_Info')" -ForegroundColor DarkGray
    Write-Host ""

    $fwPort = if ($Server.FirewallPort) { [int]$Server.FirewallPort } else { 27016 }
    $fwRule  = Get-ServerFirewallRule -ServerName $Server.Name -Port $fwPort

    if ($fwRule) {
        Write-Host "  $(Get-Message -Key 'Wizard_Step3_FirewallDone')" -ForegroundColor Green
        Write-Host ""
        $doFw = Read-WizardReconfigure
        if ($doFw) {
            Enable-ServerFirewall -ServerName $Server.Name -Port $fwPort | Out-Null
        }
    } else {
        $openFw = Read-Host (Get-Message -Key "Wizard_Step3_OpenNow")
        if ($openFw -eq (Get-Message -Key "ConfirmYes")) {
            Enable-ServerFirewall -ServerName $Server.Name -Port $fwPort | Out-Null
            Write-Host "  $(Get-Message -Key 'Firewall_Enabled_Success')" -ForegroundColor Green
        }
    }
    Write-Host ""
    Write-Host "  $(Get-Message -Key 'Wizard_Step3_RouterNote')" -ForegroundColor Yellow
    Write-Host ""
    Read-Host (Get-Message -Key "Common_PressEnter")

    # --- STEP 4: MetaMod ---
    Write-WizardStep 4 (Get-Message -Key "Wizard_Step4_Title")

    $modsInstalledPath = Join-Path $managerPath ".mods_installed.json"
    $modsInstalled = if (Test-Path $modsInstalledPath) { Get-Content $modsInstalledPath -Raw | ConvertFrom-Json } else { $null }
    $hasMM = $modsInstalled -and -not [string]::IsNullOrWhiteSpace($modsInstalled.MetaMod)

    $doStep4 = $true
    if ($hasMM) {
        Write-Host "  $(Get-Message -Key 'Wizard_AlreadyDone'): MetaMod $($modsInstalled.MetaMod)" -ForegroundColor Green
        Write-Host ""
        $doStep4 = Read-WizardReconfigure
    }

    if ($doStep4) {
        Show-ModMenu -Server $Server -RootPath $RootPath
    }

    # --- STEP 5: SourceMod ---
    Write-WizardStep 5 (Get-Message -Key "Wizard_Step5_Title")

    $modsInstalled = if (Test-Path $modsInstalledPath) { Get-Content $modsInstalledPath -Raw | ConvertFrom-Json } else { $null }
    $hasSM = $modsInstalled -and -not [string]::IsNullOrWhiteSpace($modsInstalled.SourceMod)

    $doStep5 = $true
    if ($hasSM) {
        Write-Host "  $(Get-Message -Key 'Wizard_AlreadyDone'): SourceMod $($modsInstalled.SourceMod)" -ForegroundColor Green
        Write-Host ""
        $doStep5 = Read-WizardReconfigure
    }

    if ($doStep5) {
        Show-ModMenu -Server $Server -RootPath $RootPath
    }

    # --- STEP 6: Admin SourceMod ---
    Write-WizardStep 6 (Get-Message -Key "Wizard_Step6_Title")

    $modsConfigPath = Join-Path $RootPath "games\$($Server.Game)\configs\mods.json"
    $adminFile = $null
    if (Test-Path $modsConfigPath) {
        $modConfig = Get-Content $modsConfigPath -Raw | ConvertFrom-Json
        $adminFile = Join-Path (Join-Path $Server.Path "server") "$($modConfig.GameFolder)\addons\sourcemod\configs\admins_simple.ini"
    }

    $hasAdmins = $false
    if ($adminFile -and (Test-Path $adminFile)) {
        $adminLines = Get-Content $adminFile | Where-Object { $_ -match 'STEAM_' }
        $hasAdmins = $adminLines.Count -gt 0
    }

    $doStep6 = $true
    if ($hasAdmins) {
        Write-Host "  $(Get-Message -Key 'Wizard_AlreadyDone'): $($adminLines.Count) admin" -ForegroundColor Green
        Write-Host ""
        $doStep6 = Read-WizardReconfigure
    } else {
        Write-Host "  $(Get-Message -Key 'Wizard_Step6_SkipNote')" -ForegroundColor DarkGray
        Write-Host ""
    }

    if ($doStep6) {
        if ($adminFile -and (Test-Path $adminFile)) {
            Show-AdminMenu -Server $Server -RootPath $RootPath
        } else {
            Write-Host "  $(Get-Message -Key 'Admin_SmNotInstalled')" -ForegroundColor DarkGray
            Write-Host ""
            Read-Host (Get-Message -Key "Common_PressEnter")
        }
    }

    # --- DONE ---
    Show-Header
    Write-Host (Format-SectionTitle (Get-Message -Key "Wizard_Title"))
    Write-Host ""
    Write-Host "  $(Get-Message -Key 'Wizard_Done')" -ForegroundColor Green
    Write-Host ""
    Read-Host (Get-Message -Key "Common_PressEnter")

    return (@(Get-ServerRegistry) | Where-Object { $_.ServerId -eq $Server.ServerId } | Select-Object -First 1)
}

# --- IMPOSTAZIONI SERVER (per-server) ---

function Invoke-ServerSettings {
    param($server)

    $managerPath = Join-Path $server.Path "manager"
    $configPath  = Join-Path $managerPath "config.json"

    if (-not (Test-Path $managerPath)) {
        New-Item -ItemType Directory -Path $managerPath -Force | Out-Null
    }

    $serverConfig = if (Test-Path $configPath) {
        Get-Content $configPath -Raw | ConvertFrom-Json
    } else {
        [PSCustomObject]@{ RconPassword = ""; Notes = "" }
    }

    while ($true) {
        Show-Header
        Write-Host (Format-SectionTitle (Get-Message -Key "SrvSettings_Title" -MsgArgs @($server.Name)))
        Write-Host ""

        $rconDisplay = if ([string]::IsNullOrWhiteSpace($serverConfig.RconPassword)) {
            "[--] $(Get-Message -Key 'SrvSettings_NotSet')"
        } else {
            "[OK] ***"
        }

        Write-Host "  1) $(Get-Message -Key 'SrvSettings_RconPassword'): $rconDisplay"
        Write-Host "  0) $(Get-Message -Key 'Manage_Back')"
        Write-Host ""

        $action = Read-Host (Get-Message -Key "Common_Select")

        switch ($action) {
            "1" {
                Write-Host ""
                $pwd = Read-Host (Get-Message -Key "SrvSettings_RconPrompt")
                $serverConfig | Add-Member -NotePropertyName RconPassword -NotePropertyValue $pwd -Force
                $serverConfig | ConvertTo-Json | Set-Content $configPath -Encoding UTF8

                $cfgFile = Join-Path (Join-Path $server.Path "server") "left4dead2\cfg\server.cfg"
                if (Test-Path $cfgFile) {
                    Generate-ServerCfg -ServerId $server.ServerId | Out-Null
                }

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

# --- IMPOSTAZIONI ---

function Invoke-Settings {
    while ($true) {
        Show-Header
        Write-Host (Format-SectionTitle (Get-Message -Key "Settings_Title"))
        Write-Host ""
        Write-Host "  1) $(Get-Message -Key 'Settings_ChangeLang')"
        Write-Host "  0) $(Get-Message -Key 'Manage_Back')"
        Write-Host ""

        $action = Read-Host (Get-Message -Key "Common_Select")

        switch ($action) {
            "1" {
                $cancelLabel = Get-Message -Key "Common_Cancel"
                $newLang = Select-Language -LocaleDir "$RootPath\locale" -CancelLabel $cancelLabel
                if ($null -ne $newLang -and $newLang -ne $config.Language) {
                    Save-Language -ConfigPath "$RootPath\config\default_config.json" -LangCode $newLang
                    $config.Language = $newLang
                    $lf = "$RootPath\locale\$newLang.json"
                    if (-not (Test-Path $lf)) { $lf = "$RootPath\locale\it.json" }
                    Set-Messages (Get-Content $lf -Raw | ConvertFrom-Json)
                    Write-Host ""
                    Write-Host (Get-Message -Key "Settings_LangChanged") -ForegroundColor Green
                    Start-Sleep -Seconds 2
                }
            }
            "0" { return }
            default {
                Write-Host "`n$(Get-Message -Key 'Common_InvalidOption')`n" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

# --- LOOP PRINCIPALE ---

# Controlla installazioni incomplete all'avvio
$incomplete = @(Get-ServerRegistry | Where-Object {
    $_.Status -ne "Installed" -or (Get-ServerDiskStatus -Path (Join-Path $_.Path "server")) -ne "Installed"
})
if ($incomplete.Count -gt 0) {
    Show-Header
    $diskLabel = Get-Message -Key "Resume_DiskLabel"
    if ($incomplete.Count -eq 1) {
        $s = $incomplete[0]
        $disk = Get-ServerDiskStatus -Path (Join-Path $s.Path "server")
        Write-Host "$(Get-Message -Key 'Startup_IncompleteOne')`n" -ForegroundColor Yellow
        Write-Host "  $($s.Name)  [$($diskLabel): $disk]"
        Write-Host ""
        $resume = Read-Host (Get-Message -Key "Startup_ResumePrompt")
        if ($resume -eq (Get-Message -Key "ConfirmYes")) { Start-ServerInstall $s }
    }
    else {
        Write-Host "$(Get-Message -Key 'Startup_IncompleteMany' -MsgArgs @($incomplete.Count))`n" -ForegroundColor Yellow
        foreach ($s in $incomplete) {
            $disk = Get-ServerDiskStatus -Path (Join-Path $s.Path "server")
            Write-Host "  - $($s.Name)  [$($diskLabel): $disk]"
        }
        Write-Host ""
        $resume = Read-Host (Get-Message -Key "Startup_ResumePrompt")
        if ($resume -eq (Get-Message -Key "ConfirmYes")) { Invoke-ResumeInstallation }
    }
}

while ($true) {
    Show-Header
    $hasHidden = Show-ServerSummary

    $hasIncomplete = (@(Get-ServerRegistry | Where-Object {
        $_.Status -ne "Installed" -or (Get-ServerDiskStatus -Path (Join-Path $_.Path "server")) -ne "Installed"
    }).Count -gt 0)

    Show-Menu -ShowListOption $hasHidden -HasIncomplete $hasIncomplete

    $choice = Read-Host (Get-Message -Key "Common_Select")

    if ($hasHidden) {
        switch ($choice) {
            "1" { Invoke-CreateServer }
            "2" { Invoke-ListServers }
            "3" { Invoke-ManageServer }
            "4" {
                if ($hasIncomplete) { Invoke-ResumeInstallation }
                else {
                    Write-Host "`n$(Get-Message -Key 'Resume_NoneIncomplete')`n" -ForegroundColor DarkGray
                    Start-Sleep -Seconds 1
                }
            }
            "5" { Invoke-Settings }
            "6" { Write-Log "Manager chiuso" "INFO"; exit }
            default {
                Write-Host "`n$(Get-Message -Key 'Common_InvalidOption')`n" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
    else {
        switch ($choice) {
            "1" { Invoke-CreateServer }
            "2" { Invoke-ManageServer }
            "3" {
                if ($hasIncomplete) { Invoke-ResumeInstallation }
                else {
                    Write-Host "`n$(Get-Message -Key 'Resume_NoneIncomplete')`n" -ForegroundColor DarkGray
                    Start-Sleep -Seconds 1
                }
            }
            "4" { Invoke-Settings }
            "5" { Write-Log "Manager chiuso" "INFO"; exit }
            default {
                Write-Host "`n$(Get-Message -Key 'Common_InvalidOption')`n" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}
