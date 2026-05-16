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

    Write-Host "`n$(Get-Message -Key 'Start_Starting')`n"

    try {
        if ($modeChoice -eq "1") {
            $serverPID = Start-ServerNormal -InstallPath $gamePath -GameMode $gameMode -Map $map -Port 27015

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
Start-ServerWithMonitoring -InstallPath '$gamePath' -ManagerPath '$managerPath' -GameMode '$gameMode' -Map '$map' -Port 27015
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
        $runSymbol = "[--]"; $runColor = "Red"; $runText = "ServerInfo_NotRunning"
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

    $rconSymbol = "[--]"; $rconColor = "DarkGray"; $rconLabel = Get-Message -Key "ServerInfo_RconNoPassword"
    $playersLabel = ""

    if ($rconPasswordSet -and $isRunning) {
        $statusResp = Invoke-ServerRcon -Server $server -Command "status"
        if ($null -ne $statusResp) {
            $rconSymbol = "[OK]"; $rconColor = "Green"; $rconLabel = Get-Message -Key "ServerInfo_RconActive"
            if ($statusResp -match 'players\s*:\s*(\d+)\s+humans.*?\((\d+)\s+max\)') {
                $playersLabel = " — $(Get-Message -Key 'ServerInfo_Players' -MsgArgs @($Matches[1], $Matches[2]))"
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
    } elseif ($rconPasswordSet) {
        $rconLabel = Get-Message -Key "ServerInfo_RconConfigured"
    }

    [Console]::SetCursorPosition(0, $loadingRow)
    Write-Host (" " * ([Console]::WindowWidth - 1)) -NoNewline
    [Console]::SetCursorPosition(0, $loadingRow)

    Write-Host ""
    Write-Host "  $(Get-Message -Key 'ServerInfo_Installation'): $instSymbol $(Get-Message -Key $instText)" -ForegroundColor $instColor
    Write-Host "  $(Get-Message -Key 'ServerInfo_Configuration'): $cfgSymbol $(Get-Message -Key $cfgText)" -ForegroundColor $cfgColor

    if (-not [string]::IsNullOrWhiteSpace($server.ConfiguredMap)) {
        Write-Host "  Map: $($server.ConfiguredMap)" -ForegroundColor DarkGray
    }
    if (-not [string]::IsNullOrWhiteSpace($server.ConfiguredGameMode)) {
        Write-Host "  GameMode: $($server.ConfiguredGameMode)" -ForegroundColor DarkGray
    }

    Write-Host "  $(Get-Message -Key 'ServerInfo_Port' -MsgArgs @('27015')): $fwSymbol $(Get-Message -Key $fwText)" -ForegroundColor $fwColor
    Write-Host "  $(Get-Message -Key 'ServerInfo_MetaMod'):   $mmSymbol $mmLabel" -ForegroundColor $mmColor
    Write-Host "  $(Get-Message -Key 'ServerInfo_SourceMod'): $smSymbol $smLabel" -ForegroundColor $smColor
    Write-Host "  $(Get-Message -Key 'ServerInfo_Status'): $runSymbol $(Get-Message -Key $runText)" -ForegroundColor $runColor
    Write-Host "  RCON: $rconSymbol $rconLabel$playersLabel" -ForegroundColor $rconColor
    Write-Host ""
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

        Write-Host "  1) $(Get-Message -Key 'Manage_Rename')"
        Write-Host "  2) $(Get-Message -Key 'Manage_Move')"
        Write-Host "  3) $(Get-Message -Key 'Manage_Update')"
        Write-Host "  4) $(Get-Message -Key 'Manage_Delete')"
		Write-Host "  5) $(Get-Message -Key 'Manage_Configure')"
		Write-Host "  6) $(Get-Message -Key 'Manage_ChangeSettings')"
		if ($isRunning) {
			Write-Host "  7) $(Get-Message -Key 'Manage_Stop')" -ForegroundColor Yellow
		} else {
			Write-Host "  7) $(Get-Message -Key 'Manage_Start')"
		}
		Write-Host "  8) $(Get-Message -Key 'Manage_Firewall') (admin)"
		Write-Host "  9) $(Get-Message -Key 'Manage_Mods')"
		Write-Host " 10) $(Get-Message -Key 'Manage_ServerSettings')"
		Write-Host " 11) $(Get-Message -Key 'Manage_OpenFolder')"
		if ($isRunning) {
			Write-Host " 12) $(Get-Message -Key 'Manage_Restart')" -ForegroundColor Yellow
		} else {
			Write-Host " 12) $(Get-Message -Key 'Manage_Restart')" -ForegroundColor DarkGray
		}
        Write-Host "  0) $(Get-Message -Key 'Manage_Back')"
        Write-Host ""

        $action = Read-Host (Get-Message -Key "Common_Select")

        switch ($action) {
            "1" {
                $changed = Invoke-RenameServer $selected
                if ($changed) {
                    $updated = @(Get-ServerRegistry) | Where-Object { $_.ServerId -eq $selected.ServerId }
                    if ($updated) { $selected = $updated }
                }
            }
            "2" {
                $changed = Invoke-MoveServer $selected
                if ($changed) {
                    $updated = @(Get-ServerRegistry) | Where-Object { $_.ServerId -eq $selected.ServerId }
                    if ($updated) { $selected = $updated }
                }
            }
            "3" {
                Write-Host "`n$(Get-Message -Key 'Update_Starting' -MsgArgs @($selected.Name))`n" -ForegroundColor Cyan
                Write-Host (Get-Message -Key "Update_Note")
                Write-Host ""
                $confirm = Read-Host (Get-Message -Key "Common_ConfirmPrompt")
                if ($confirm -eq (Get-Message -Key "ConfirmYes")) { Start-ServerInstall $selected }
            }
            "4" {
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
			"5" {
				Write-Host "`n$(Get-Message -Key 'Config_Initializing')`n" -ForegroundColor Cyan

				$result = Initialize-ServerConfiguration -ServerId $selected.ServerId

				if ($result) {
					Write-Host "`n$(Get-Message -Key 'Config_Done')`n" -ForegroundColor Green
					$updated = @(Get-ServerRegistry) | Where-Object { $_.ServerId -eq $selected.ServerId }
					if ($updated) { $selected = $updated }
				}
				else {
					Write-Host "`n$(Get-Message -Key 'Config_Failed')`n" -ForegroundColor Red
				}

				Read-Host (Get-Message -Key "Common_PressEnter")
			}
			"6" {
				Write-Host "`n$(Get-Message -Key 'Config_ChangingSettings')`n" -ForegroundColor Cyan

				$result = Update-ServerMapAndGameMode -ServerId $selected.ServerId

				if ($result) {
					Write-Host "`n$(Get-Message -Key 'Config_Done')`n" -ForegroundColor Green
				}
				else {
					Write-Host "`n$(Get-Message -Key 'Config_Failed')`n" -ForegroundColor Red
				}

				Read-Host (Get-Message -Key "Common_PressEnter")
			}
			"7" {
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
			"8" {
				$fwPort = if ($selected.FirewallPort) { [int]$selected.FirewallPort } else { 27015 }
				Invoke-FirewallManagement -ServerName $selected.Name -RootPath $RootPath -Language $config.Language -Port $fwPort
			}
			"9" {
				Show-ModMenu -Server $selected -RootPath $RootPath
			}
			"10" {
				Invoke-ServerSettings $selected
			}
			"11" {
				Start-Process explorer.exe -ArgumentList $selected.Path
			}
			"12" {
				Invoke-RestartServer $selected
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
    $port     = if ($fresh.FirewallPort) { [int]$fresh.FirewallPort } else { 27015 }

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
