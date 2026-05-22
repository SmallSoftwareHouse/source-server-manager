$RootPath = $PSScriptRoot
Set-Location $RootPath

# --- SESSION TRANSCRIPT ---
$_transcriptDir = Join-Path $RootPath "logs\transcripts"
if (-not (Test-Path $_transcriptDir)) {
    New-Item -ItemType Directory -Path $_transcriptDir -Force | Out-Null
}
$_transcriptFile = Join-Path $_transcriptDir ("session_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
Start-Transcript -Path $_transcriptFile -NoClobber | Out-Null

# Keep only the 10 most recent transcript files
$_transcripts = @(Get-ChildItem -Path $_transcriptDir -Filter "session_*.log" | Sort-Object Name -Descending)
if ($_transcripts.Count -gt 10) {
    $_transcripts | Select-Object -Skip 10 | ForEach-Object { Remove-Item $_.FullName -Force }
}

# Single-instance lock via named mutex
$_mutexName = "Global\SourceServerManager_SingleInstance"
$_mutex = New-Object System.Threading.Mutex($false, $_mutexName)
if (-not $_mutex.WaitOne(0)) {
    Write-Host ""
    Write-Host "  [!!] The tool is already running in another window." -ForegroundColor Red
    Write-Host "       Close the other instance before opening a new one." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    Stop-Process -Id $PID -Force
}

$host.ui.RawUI.WindowTitle = "Source Server Manager"



Import-Module "$RootPath\modules\messages.psm1"   -Force -Global -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\ui.psm1"         -Force -Global -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\logging.psm1"    -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\registry.psm1"   -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\validation.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\server.psm1"     -Force -Global -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\steamcmd.psm1"   -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\settings.psm1"   -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\setup.psm1"      -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\recovery.psm1"   -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\splash.psm1"     -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\launcher.psm1"   -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\server-monitor.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\server\server-config.psm1" -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\network.psm1"             -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\network-diagnostics.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\modding.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\rcon.psm1"             -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\sourcemod-admin.psm1"  -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\server-management.psm1" -Force -Global -WarningAction SilentlyContinue

$config = Get-Content "$RootPath\config\default_config.json" -Raw | ConvertFrom-Json

if (-not [System.IO.Path]::IsPathRooted($config.DefaultInstallRoot)) {
    $config.DefaultInstallRoot = Join-Path $RootPath $config.DefaultInstallRoot
}

$HeaderLimit = if ($config.HeaderServerLimit) { [int]$config.HeaderServerLimit } else { 5 }

# -------------------------------------------------------
# Selezione lingua (prima esecuzione o lingua non in config)
# -------------------------------------------------------

# -------------------------------------------------------
# Interactive folder browser helpers
# -------------------------------------------------------



if ([string]::IsNullOrWhiteSpace($config.Language)) {
    $chosenLang = Select-Language -LocaleDir "$RootPath\locale"
    Save-Language -ConfigPath "$RootPath\config\default_config.json" -LangCode $chosenLang
    $config.Language = $chosenLang
}

$configFilePath = "$RootPath\config\default_config.json"

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

# First run: ask for default server folder (skippable)
$rawConfig = Get-Content $configFilePath -Raw | ConvertFrom-Json
if ($rawConfig.DefaultInstallRoot -eq "servers") {
    $chosenRoot = Ask-DefaultInstallRoot -AllowCancel
    if ($null -ne $chosenRoot) {
        Save-DefaultInstallRoot -ConfigPath $configFilePath -Path $chosenRoot
        $config.DefaultInstallRoot = $chosenRoot
        Write-Host ""
        Write-Host "  $(Get-Message -Key 'Settings_ServerRootChanged')" -ForegroundColor Green
        Write-Host "  $chosenRoot" -ForegroundColor White
        Start-Sleep -Seconds 2
    }
}

# -------------------------------------------------------
# Avvio
# -------------------------------------------------------

Write-Log "Manager avviato" "INFO"
Validate-ServerRegistry | Out-Null

# Disk space check on startup
$_diskCheckGB = Get-PathFreeGB -Path $config.DefaultInstallRoot
if ($_diskCheckGB -lt 0) {
    # Cannot determine space — skip silently
} elseif ($_diskCheckGB -lt 10) {
    Write-Host (Get-Message -Key "Startup_DiskCheckCrit" -MsgArgs @($_diskCheckGB)) -ForegroundColor Red
    Start-Sleep -Seconds 2
} elseif ($_diskCheckGB -lt 20) {
    Write-Host (Get-Message -Key "Startup_DiskCheckWarn" -MsgArgs @($_diskCheckGB)) -ForegroundColor Yellow
    Start-Sleep -Milliseconds 1200
} else {
    Write-Host (Get-Message -Key "Startup_DiskCheckOk") -ForegroundColor Green
    Start-Sleep -Milliseconds 600
}

# --- HELPERS ---

function Get-NextAvailablePort {
    param([int]$BasePort = 27015)
    $usedPorts = @(Get-ServerRegistry | Where-Object { $_.FirewallPort } | ForEach-Object { [int]$_.FirewallPort })
    $port = $BasePort
    while ($usedPorts -contains $port) { $port++ }
    return $port
}


function Show-SettingsSummary {
    $sep = "====================================="

    $freeGB = Get-PathFreeGB -Path $config.DefaultInstallRoot
    $spaceSuffix = Get-SpaceSuffix -GB $freeGB
    $spaceColor  = Get-SpaceColor  -GB $freeGB

    $shortRoot = Get-ShortPath -Path $config.DefaultInstallRoot -RootPath $RootPath

    $langDisplay = ""
    try {
        $lf = "$RootPath\locale\$($config.Language).json"
        if (Test-Path $lf) {
            $ld = Get-Content $lf -Raw | ConvertFrom-Json
            if ($ld.LanguageName) { $langDisplay = $ld.LanguageName }
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($langDisplay)) { $langDisplay = $config.Language }

    # Truncate path from the left if it would overflow the console width
    $folderLabel    = "$(Get-Message -Key 'Home_DefaultFolder') : "
    $suffixText     = if ($freeGB -ge 0) { $spaceSuffix } else { "" }
    $availableWidth = [Console]::WindowWidth - $folderLabel.Length - $suffixText.Length - 1
    $displayRoot    = $shortRoot
    if ($displayRoot.Length -gt $availableWidth) {
        $keep = $availableWidth - 3
        if ($keep -gt 0) {
            $displayRoot = "..." + $displayRoot.Substring($displayRoot.Length - $keep)
        } else {
            $displayRoot = $displayRoot.Substring($displayRoot.Length - $availableWidth)
        }
    }

    Write-Host (Get-Message -Key "Home_SettingsLabel")
    Write-Host $folderLabel -NoNewline -ForegroundColor DarkGray
    Write-Host $displayRoot -NoNewline -ForegroundColor White
    if ($freeGB -ge 0) {
        Write-Host $spaceSuffix -ForegroundColor $spaceColor
    } else {
        Write-Host ""
    }
    Write-Host "$(Get-Message -Key 'Home_Language')         : $langDisplay" -ForegroundColor DarkGray
    Write-Host $sep
    Write-Host ""
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
        $disk = Get-ServerDiskStatus -Path (Get-GamePath $s)

        $installingFile = Join-Path (Get-ManagerPath $s) ".installing"
        $isActiveDownload = $false
        if (($s.Status -eq "Installing") -and (Test-Path $installingFile)) {
            try {
                $instData = Get-Content $installingFile -Raw | ConvertFrom-Json
                $isActiveDownload = $null -ne (Get-Process -Id $instData.InstallerPID -ErrorAction SilentlyContinue)
            } catch {}
            if (-not $isActiveDownload) { Remove-Item $installingFile -Force -ErrorAction SilentlyContinue }
        }

        if ($disk -eq "Installed" -and $s.Status -eq "Installed") {
            $symbol = "[OK]"; $color = "Green"; $tag = Get-Message -Key "ServerList_StatusOK"
        } elseif ($isActiveDownload) {
            $symbol = "[>>]"; $color = "Cyan";  $tag = Get-Message -Key "ServerList_StatusDownloading"
        } elseif ($s.Status -eq "Installing") {
            $symbol = "[!!]"; $color = "Yellow"; $tag = Get-Message -Key "ServerList_StatusInstalling"
        } elseif ($disk -eq "Missing") {
            $symbol = "[--]"; $color = "Red";   $tag = Get-Message -Key "ServerList_StatusMissing"
        } else {
            $symbol = "[!!]"; $color = "Yellow"; $tag = Get-Message -Key "ServerList_StatusError"
        }

        $shortPath = Get-ShortPath -Path $s.Path -RootPath $RootPath
        $namePad = $s.Name.PadRight(16)
        $line = "  $symbol  $namePad $shortPath"
        if (-not [string]::IsNullOrEmpty($tag)) { $line += "  $tag" }
        Write-Host $line -ForegroundColor $color
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
        [bool]$HasServers    = $false,
        [bool]$HasIncomplete = $false
    )

    Write-Host "  1) $(Get-Message -Key 'Menu_CreateServer')"
    if ($HasServers) {
        Write-Host "  2) $(Get-Message -Key 'Menu_ListServers')"
        Write-Host "  3) $(Get-Message -Key 'Menu_ManageServer')"
    } else {
        Write-Host "  2) $(Get-Message -Key 'Menu_ListServers')" -ForegroundColor DarkGray
        Write-Host "  3) $(Get-Message -Key 'Menu_ManageServer')" -ForegroundColor DarkGray
    }
    if ($HasIncomplete) {
        Write-Host "  4) $(Get-Message -Key 'Menu_ResumeInstall')"
    } else {
        Write-Host "  4) $(Get-Message -Key 'Menu_ResumeInstall')" -ForegroundColor DarkGray
    }
    Write-Host "  5) $(Get-Message -Key 'Menu_RecoverServer')"
    if ($HasServers) {
        Write-Host "  8) $(Get-Message -Key 'Menu_DeleteServers')" -ForegroundColor Red
    } else {
        Write-Host "  8) $(Get-Message -Key 'Menu_DeleteServers')" -ForegroundColor DarkGray
    }
    Write-Host "  6) $(Get-Message -Key 'Menu_Settings')"
    Write-Host "  7) $(Get-Message -Key 'Menu_Exit')"
    Write-Host ""
}

# Functions moved to modules/server-management.psm1:
# Invoke-ListServers, Invoke-RenameServer, Invoke-MoveServer, Invoke-StartServer,
# Stop-ServerMonitoring, Get-CachedPublicIP, Invoke-NetworkMenu, Show-ServerStatusBox,
# Show-PlayersMenu, Invoke-ManageServer, Invoke-RestartServer, Invoke-ServerSettings,
# Find-UnregisteredServers, Get-ShortPath

# --- LOOP PRINCIPALE ---

# Controlla installazioni incomplete all'avvio
$allIncomplete = @(Get-ServerRegistry | Where-Object {
    $_.Status -ne "Installed" -or (Get-ServerDiskStatus -Path (Get-GamePath $_)) -ne "Installed"
})

# Separate active downloads (already running in background) from truly incomplete
$activeDownloads = @($allIncomplete | Where-Object {
    $instFile = Join-Path (Get-ManagerPath $_) ".installing"
    if (-not (Test-Path $instFile)) { return $false }
    try {
        $instData = Get-Content $instFile -Raw | ConvertFrom-Json
        $null -ne (Get-Process -Id $instData.InstallerPID -ErrorAction SilentlyContinue)
    } catch { $false }
})
$incomplete = @($allIncomplete | Where-Object {
    $serverId = $_.ServerId
    -not ($activeDownloads | Where-Object { $_.ServerId -eq $serverId })
})

if ($activeDownloads.Count -gt 0) {
    Show-Header
    Write-Host "$(Get-Message -Key 'Startup_DownloadActive')`n" -ForegroundColor Cyan
    foreach ($s in $activeDownloads) {
        Write-Host "  [>>]  $($s.Name)" -ForegroundColor Cyan
    }
    Write-Host ""
    Read-Host (Get-Message -Key "Common_PressEnter") | Out-Null
}

if ($incomplete.Count -gt 0) {
    Show-Header
    $diskLabel = Get-Message -Key "Resume_DiskLabel"
    if ($incomplete.Count -eq 1) {
        $s = $incomplete[0]
        $disk = Get-ServerDiskStatus -Path (Get-GamePath $s)
        Write-Host "$(Get-Message -Key 'Startup_IncompleteOne')`n" -ForegroundColor Yellow
        Write-Host "  $($s.Name)  [$($diskLabel): $disk]"
        Write-Host ""
        $resume = Read-Host (Get-Message -Key "Startup_ResumePrompt")
        if ($resume -eq (Get-Message -Key "ConfirmYes")) { Start-ServerInstall -Target $s -RootPath $RootPath -Config $config }
    }
    else {
        Write-Host "$(Get-Message -Key 'Startup_IncompleteMany' -MsgArgs @($incomplete.Count))`n" -ForegroundColor Yellow
        foreach ($s in $incomplete) {
            $disk = Get-ServerDiskStatus -Path (Get-GamePath $s)
            Write-Host "  - $($s.Name)  [$($diskLabel): $disk]"
        }
        Write-Host ""
        $resume = Read-Host (Get-Message -Key "Startup_ResumePrompt")
        if ($resume -eq (Get-Message -Key "ConfirmYes")) { Invoke-ResumeInstallation -RootPath $RootPath -Config $config }
    }
}

# Scan for unregistered servers in the default folder
$unregistered = @(Find-UnregisteredServers -DefaultInstallRoot $config.DefaultInstallRoot)
if ($unregistered.Count -gt 0) {
    Show-Header
    if ($unregistered.Count -eq 1) {
        Write-Host "$(Get-Message -Key 'Startup_UnregOne')`n" -ForegroundColor Cyan
        Write-Host "  $($unregistered[0].Path)"
    } else {
        Write-Host "$(Get-Message -Key 'Startup_UnregMany' -MsgArgs @($unregistered.Count))`n" -ForegroundColor Cyan
        foreach ($u in $unregistered) {
            Write-Host "  $($u.Path)"
        }
    }
    Write-Host ""
    $regNow = Read-Host (Get-Message -Key "Startup_UnregPrompt")
    if ($regNow -eq (Get-Message -Key "ConfirmYes")) {
        Register-UnregisteredServers -Orphans $unregistered
    }
}

while ($true) {
    Show-Header
    Show-ServerSummary | Out-Null
    Show-SettingsSummary

    $hasServers = (@(Get-ServerRegistry).Count -gt 0)
    $hasIncomplete = (@(Get-ServerRegistry | Where-Object {
        $_.Status -ne "Installed" -or (Get-ServerDiskStatus -Path (Get-GamePath $_)) -ne "Installed"
    }).Count -gt 0)

    Show-Menu -HasServers $hasServers -HasIncomplete $hasIncomplete

    $choice = Read-Host (Get-Message -Key "Common_Select")

    switch ($choice) {
        "1" { Invoke-CreateServer -RootPath $RootPath -Config $config }
        "2" {
            if ($hasServers) { Invoke-ListServers -DefaultInstallRoot $config.DefaultInstallRoot }
            else {
                Write-Host "`n$(Get-Message -Key 'Common_OptionUnavailable' -MsgArgs @(''))`n" -ForegroundColor DarkGray
                Start-Sleep -Seconds 1
            }
        }
        "3" {
            if ($hasServers) { Invoke-ManageServer -RootPath $RootPath -Config $config }
            else {
                Write-Host "`n$(Get-Message -Key 'Common_OptionUnavailable' -MsgArgs @(''))`n" -ForegroundColor DarkGray
                Start-Sleep -Seconds 1
            }
        }
        "4" {
            if ($hasIncomplete) { Invoke-ResumeInstallation -RootPath $RootPath -Config $config }
            else {
                Write-Host "`n$(Get-Message -Key 'Resume_NoneIncomplete')`n" -ForegroundColor DarkGray
                Start-Sleep -Seconds 1
            }
        }
        "5" { Invoke-RecoverServer }
        "8" {
            if ($hasServers) { Invoke-DeleteServers -RootPath $RootPath }
            else {
                Write-Host "`n$(Get-Message -Key 'Common_NoServersRegistered')`n" -ForegroundColor DarkGray
                Start-Sleep -Seconds 1
            }
        }
        "6" { Invoke-Settings -Config $config -RootPath $RootPath }
        "7" { Write-Log "Manager chiuso" "INFO"; Stop-Transcript | Out-Null; exit }
        default {
            Write-Host "`n$(Get-Message -Key 'Common_InvalidOption')`n" -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}
