$RootPath = $PSScriptRoot
Set-Location $RootPath

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
Import-Module "$RootPath\modules\server.psm1"     -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\steamcmd.psm1"   -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\splash.psm1"     -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\launcher.psm1"   -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\server-monitor.psm1" -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\server\server-config.psm1" -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\network.psm1"             -Force -WarningAction SilentlyContinue
Import-Module "$RootPath\modules\network-diagnostics.psm1" -Force -WarningAction SilentlyContinue
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

function Save-DefaultInstallRoot {
    param([string]$ConfigPath, [string]$Path)
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $cfg.DefaultInstallRoot = $Path
    $cfg | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath -Encoding UTF8
}

# -------------------------------------------------------
# Interactive folder browser helpers
# -------------------------------------------------------


function Test-IsSystemFolder {
    param([string]$Path)
    $blocked = @(
        $env:SystemRoot,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        (Split-Path -Parent $env:USERPROFILE)
    ) | Where-Object { -not [string]::IsNullOrEmpty($_) }

    $extra = @(
        "$env:SystemDrive\Recovery",
        "$env:SystemDrive\Boot",
        "$env:SystemDrive\System Volume Information",
        "$env:SystemDrive\PerfLogs"
    )

    $norm = $Path.TrimEnd('\').ToLower()
    foreach ($root in ($blocked + $extra)) {
        $r = $root.TrimEnd('\').ToLower()
        if ($norm -eq $r -or $norm.StartsWith($r + '\')) { return $true }
    }

    $leaf = (Split-Path -Leaf $Path).ToLower()
    $sysNames = @('$recycle.bin', 'system volume information', 'recovery', 'boot', 'perflogs', 'msocache')
    if ($sysNames -contains $leaf) { return $true }

    return $false
}

function Select-FolderInteractive {
    # Returns selected absolute path, or $null if cancelled.
    # Only fixed local NTFS disks (FAT32/cloud drives excluded, server install requires NTFS)
    $allDrives = @(Get-WmiObject Win32_LogicalDisk -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveType -eq 3 -and $_.FileSystem -eq 'NTFS' } |
        Sort-Object DeviceID)
    $sysDrive = $env:SystemDrive  # e.g. "C:"

    # Single-drive: skip drive selection, start at root
    $singleDrive = ($allDrives.Count -eq 1)
    $currentPath = if ($singleDrive) { $allDrives[0].DeviceID + '\' } else { "" }

    while ($true) {
        Clear-Host
        Write-Host "=====================================" -ForegroundColor Cyan
        Write-Host "  $(Get-Message -Key 'Setup_ServerFolderTitle')" -ForegroundColor White
        Write-Host "=====================================" -ForegroundColor Cyan
        Write-Host ""

        if ($currentPath -eq "") {
            # Drive selection screen
            Write-Host "  --- $(Get-Message -Key 'Browse_SelectDrive') ---" -ForegroundColor Yellow
            Write-Host ""

            $idx = 1
            foreach ($drv in $allDrives) {
                $letter = $drv.DeviceID
                $freeGB = [math]::Round($drv.FreeSpace / 1GB, 1)
                $isSystem = ($letter -eq $sysDrive)
                if ($isSystem) {
                    $suffix = "  [$(Get-Message -Key 'Browse_SystemDrive')  ${freeGB}GB]"
                    $color  = "Yellow"
                } else {
                    $suffix = Get-SpaceSuffix -GB $freeGB
                    $color  = Get-SpaceColor -GB $freeGB
                }
                Write-Host "  $idx) $letter\" -NoNewline -ForegroundColor White
                Write-Host $suffix -ForegroundColor $color
                $idx++
            }
            Write-Host ""
            Write-Host "  0) $(Get-Message -Key 'Browse_Cancel')" -ForegroundColor White
            Write-Host ""

            $choice = (Read-Host "  >").Trim()
            if ($choice -eq "0") { return $null }
            if ($choice -match '^\d+$') {
                $ci = [int]$choice - 1
                if ($ci -ge 0 -and $ci -lt $allDrives.Count) {
                    $freeGB = [math]::Round($allDrives[$ci].FreeSpace / 1GB, 1)
                    if ($freeGB -ge 0 -and $freeGB -lt 10) {
                        Write-Host ""
                        Write-Host "  $(Get-Message -Key 'Browse_InsufficientSpace')" -ForegroundColor Red
                        Start-Sleep -Seconds 2
                        continue
                    }
                    $currentPath = $allDrives[$ci].DeviceID + '\'
                }
            }
        } else {
            # Folder navigation screen
            $freeGB = Get-PathFreeGB -Path $currentPath
            $suffix = Get-SpaceSuffix -GB $freeGB
            $color  = Get-SpaceColor -GB $freeGB
            $isAtDriveRoot = ($currentPath -match '^[A-Za-z]:\\?$')

            # Current path + space
            Write-Host "  $(Get-Message -Key 'Browse_CurrentPath'):" -ForegroundColor Gray
            Write-Host "  $currentPath" -ForegroundColor White
            Write-Host "  $(Get-Message -Key 'Browse_FreeSpace'):" -NoNewline -ForegroundColor DarkGray
            Write-Host $suffix -ForegroundColor $color
            Write-Host ""

            # List non-hidden, non-system subfolders
            $subFolders = @()
            try {
                $subFolders = @(Get-ChildItem -Path $currentPath -Directory -ErrorAction SilentlyContinue |
                    Where-Object {
                        (-not ($_.Attributes -band [System.IO.FileAttributes]::Hidden)) -and
                        (-not ($_.Attributes -band [System.IO.FileAttributes]::System)) -and
                        (-not (Test-IsSystemFolder -Path $_.FullName))
                    } | Sort-Object Name)
            } catch { }

            Write-Host "  --- $(Get-Message -Key 'Browse_Subfolders') ---" -ForegroundColor DarkCyan
            Write-Host ""
            if ($subFolders.Count -gt 0) {
                for ($i = 0; $i -lt $subFolders.Count; $i++) {
                    Write-Host "  $($i + 1)) $($subFolders[$i].Name)"
                }
            } else {
                Write-Host "  $(Get-Message -Key 'Browse_NoSubfolders')" -ForegroundColor DarkGray
            }

            Write-Host ""
            Write-Host "  --- $(Get-Message -Key 'Common_Select') ---" -ForegroundColor DarkCyan
            Write-Host ""
            Write-Host "  S) $(Get-Message -Key 'Browse_SelectHere')" -ForegroundColor Green
            Write-Host "  N) $(Get-Message -Key 'Browse_NewFolder')" -ForegroundColor Cyan
            if (-not ($singleDrive -and $isAtDriveRoot)) {
                Write-Host "  0) $(Get-Message -Key 'Browse_Back')" -ForegroundColor White
            }
            Write-Host ""
            Write-Host "  $(Get-Message -Key 'Browse_InputHint')" -ForegroundColor DarkGray
            Write-Host ""

            $choice = (Read-Host "  >").Trim()

            if ($choice -in @("S","s")) {
                if ($freeGB -ge 0 -and $freeGB -lt 10) {
                    Write-Host ""
                    Write-Host "  $(Get-Message -Key 'Browse_InsufficientSpace')" -ForegroundColor Red
                    Start-Sleep -Seconds 2
                    continue
                }
                if ($freeGB -ge 0 -and $freeGB -lt 20) {
                    Write-Host ""
                    $warn = Read-Host "  $(Get-Message -Key 'Browse_ContinueWarning')"
                    if ($warn -ne (Get-Message -Key "ConfirmYes")) { continue }
                }
                return $currentPath.TrimEnd('\')
            } elseif ($choice -in @("N","n")) {
                Write-Host ""
                $newName = (Read-Host "  $(Get-Message -Key 'Browse_NewFolderName')").Trim()
                if (-not [string]::IsNullOrWhiteSpace($newName) -and $newName -notmatch '[\\/:*?"<>|]') {
                    $newPath = Join-Path $currentPath $newName
                    if (-not (Test-Path $newPath)) {
                        New-Item -ItemType Directory -Path $newPath -Force -ErrorAction SilentlyContinue | Out-Null
                    }
                    if (Test-Path $newPath) { $currentPath = $newPath }
                }
            } elseif ($choice -eq "0") {
                if ($singleDrive -and $isAtDriveRoot) {
                    # Cannot go back
                } elseif ($isAtDriveRoot) {
                    $currentPath = ""  # Back to drive list
                } else {
                    $parent = Split-Path -Parent $currentPath
                    if ([string]::IsNullOrEmpty($parent)) { $currentPath = "" } else { $currentPath = $parent }
                }
            } elseif ($choice -match '^\d+$') {
                $ci = [int]$choice - 1
                if ($ci -ge 0 -and $ci -lt $subFolders.Count) {
                    $target = $subFolders[$ci].FullName
                    if (Test-IsSystemFolder -Path $target) {
                        Write-Host ""
                        Write-Host "  $(Get-Message -Key 'Browse_SystemFolder')" -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    } else {
                        $currentPath = $target
                    }
                }
            }
        }
    }
}

function Ask-DefaultInstallRoot {
    param([switch]$AllowCancel)

    Clear-Host
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "  L4D2 Dedicated Server Manager" -ForegroundColor White
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  *** $(Get-Message -Key 'Setup_ServerFolderTitle') ***" -ForegroundColor Yellow
    Write-Host ""
    Write-Host (Get-Message -Key "Setup_ServerFolderDesc") -ForegroundColor Cyan
    Write-Host ""
    Write-Host (Get-Message -Key "Setup_ServerFolderTip1") -ForegroundColor DarkGray
    Write-Host (Get-Message -Key "Setup_ServerFolderTip2") -ForegroundColor DarkGray
    Write-Host (Get-Message -Key "Setup_ServerFolderTip3") -ForegroundColor DarkGray
    Write-Host ""
    Read-Host (Get-Message -Key "Common_PressEnter") | Out-Null

    while ($true) {
        $chosen = Select-FolderInteractive
        if ($null -eq $chosen) {
            if ($AllowCancel) { return $null }
            # First run: cannot cancel
            continue
        }
        return $chosen
    }
}

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

function Get-GamePath {
    param($server)
    return Join-Path $server.Path "server"
}

function Get-ManagerPath {
    param($server)
    return Join-Path $server.Path "manager"
}

function Get-NextAvailablePort {
    param([int]$BasePort = 27015)
    $usedPorts = @(Get-ServerRegistry | Where-Object { $_.FirewallPort } | ForEach-Object { [int]$_.FirewallPort })
    $port = $BasePort
    while ($usedPorts -contains $port) { $port++ }
    return $port
}


function Get-ShortPath {
    param([string]$Path)
    $prefix = $RootPath + "\"
    if ($Path.StartsWith($prefix)) {
        return $Path.Substring($prefix.Length)
    }
    return $Path
}

function Show-SettingsSummary {
    $sep = "====================================="

    $freeGB = Get-PathFreeGB -Path $config.DefaultInstallRoot
    $spaceSuffix = Get-SpaceSuffix -GB $freeGB
    $spaceColor  = Get-SpaceColor  -GB $freeGB

    $shortRoot = Get-ShortPath -Path $config.DefaultInstallRoot

    $langDisplay = ""
    try {
        $lf = "$RootPath\locale\$($config.Language).json"
        if (Test-Path $lf) {
            $ld = Get-Content $lf -Raw | ConvertFrom-Json
            if ($ld.LanguageName) { $langDisplay = $ld.LanguageName }
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($langDisplay)) { $langDisplay = $config.Language }

    Write-Host (Get-Message -Key "Home_SettingsLabel")
    Write-Host "$(Get-Message -Key 'Home_DefaultFolder') : " -NoNewline -ForegroundColor DarkGray
    Write-Host "$shortRoot" -NoNewline -ForegroundColor White
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

        $shortPath = Get-ShortPath -Path $s.Path
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
        Write-Host "  5) $(Get-Message -Key 'Menu_RecoverServer')"
        Write-Host "  6) $(Get-Message -Key 'Menu_Settings')"
        Write-Host "  7) $(Get-Message -Key 'Menu_Exit')"
    } else {
        Write-Host "  2) $(Get-Message -Key 'Menu_ManageServer')"
        if ($HasIncomplete) {
            Write-Host "  3) $(Get-Message -Key 'Menu_ResumeInstall')"
        } else {
            Write-Host "  3) $(Get-Message -Key 'Menu_ResumeInstall')" -ForegroundColor DarkGray
        }
        Write-Host "  4) $(Get-Message -Key 'Menu_RecoverServer')"
        Write-Host "  5) $(Get-Message -Key 'Menu_Settings')"
        Write-Host "  6) $(Get-Message -Key 'Menu_Exit')"
    }
    Write-Host ""
}

# --- INSTALLAZIONE ---

function Start-ServerInstall {
    param($target)

    $gamePath    = Get-GamePath    $target
    $managerPath = Get-ManagerPath $target

    if (-not (Test-Path $target.Path))    { New-Item -ItemType Directory -Path $target.Path    -Force | Out-Null }
    if (-not (Test-Path $gamePath))       { New-Item -ItemType Directory -Path $gamePath       -Force | Out-Null }
    if (-not (Test-Path $managerPath))    { New-Item -ItemType Directory -Path $managerPath    -Force | Out-Null }

    $managerConfigFile = Join-Path $managerPath "config.json"
    if (-not (Test-Path $managerConfigFile)) {
        # Auto-assign first available port starting from 27016
        $assignedPort = Get-NextServerPort -BasePort 27016

        # Read game metadata defaults for map/gamemode
        $initMetaFile = Join-Path $RootPath "games\$($target.Game)\metadata.json"
        $initDefaultMap     = "c1m4_atrium"
        $initDefaultMode    = "coop"
        if (Test-Path $initMetaFile) {
            try {
                $initMeta = Get-Content $initMetaFile -Raw | ConvertFrom-Json
                if ($initMeta.DefaultMap)      { $initDefaultMap  = $initMeta.DefaultMap }
                if ($initMeta.DefaultGameMode) { $initDefaultMode = $initMeta.DefaultGameMode }
            } catch { }
        }

        @{
            RconPassword = ""
            Notes        = ""
            Port         = $assignedPort
            Map          = $initDefaultMap
            GameMode     = $initDefaultMode
            LaunchIp     = "auto"
            ExtraArgs    = @()
        } | ConvertTo-Json | Set-Content $managerConfigFile -Encoding UTF8

        Write-Log "Created manager config for $($target.Name) - Port: $assignedPort" "INFO"
    }

    $steamDir = Join-Path $RootPath "downloads\steamcmd"
    if (-not (Test-Path $steamDir)) { New-Item -ItemType Directory -Path $steamDir -Force | Out-Null }

    # Read AppId from game metadata (no hardcoded values)
    $gameMetaFile = Join-Path $RootPath "games\$($target.Game)\metadata.json"
    $targetAppId  = "0"
    if (Test-Path $gameMetaFile) {
        try {
            $gameMeta    = Get-Content $gameMetaFile -Raw | ConvertFrom-Json
            $targetAppId = [string]$gameMeta.SteamAppId
        } catch { }
    }

    Write-Host "`n$(Get-Message -Key 'Install_Starting' -MsgArgs @($target.Name))`n" -ForegroundColor Cyan
    Write-Host (Get-Message -Key "Install_SteamCmdNote")
    Write-Host ""

    Update-ServerStatus -ServerId $target.ServerId -Status "Installing"

    # Build background installer script
    $registryModule = Join-Path $RootPath "modules\registry.psm1"
    $steamModule    = Join-Path $RootPath "modules\steamcmd.psm1"
    $loggingModule  = Join-Path $RootPath "modules\logging.psm1"
    $messagesModule = Join-Path $RootPath "modules\messages.psm1"
    $localeFile     = Join-Path $RootPath "locale\$($config.Language).json"
    $installingFile = Join-Path $managerPath ".installing"

    $bgScript = @"
`$ErrorActionPreference = 'Stop'
`$global:RootPath = '$RootPath'
Import-Module '$registryModule' -Force -WarningAction SilentlyContinue
Import-Module '$steamModule'    -Force -WarningAction SilentlyContinue
Import-Module '$loggingModule'  -Force -WarningAction SilentlyContinue
Import-Module '$messagesModule' -Force -Global -WarningAction SilentlyContinue
`$localeData = Get-Content '$localeFile' -Raw | ConvertFrom-Json
Set-Messages `$localeData

`$host.ui.RawUI.WindowTitle = 'Installing: $($target.Name)'
Write-Host 'Installing: $($target.Name)' -ForegroundColor Cyan
Write-Host ''

try {
    `$exe = Install-SteamCMD -Path '$steamDir'
    Install-GameServer -SteamCmdPath `$exe -AppId '$targetAppId' -InstallDir '$gamePath' -SteamCmdDir '$steamDir' -ScriptId '$($target.ServerId)'
    Update-ServerStatus -ServerId '$($target.ServerId)' -Status 'Installed'
    Write-Host ''
    Write-Host 'Installazione completata con successo.' -ForegroundColor Green
    Write-Log 'Installazione completata: $($target.Path)' 'INFO'
}
catch {
    Update-ServerStatus -ServerId '$($target.ServerId)' -Status 'Error'
    Write-Log "Errore installazione: `$_" 'ERROR'
    Write-Host ''
    Write-Host "[ERRORE] `$_" -ForegroundColor Red
}
finally {
    Remove-Item '$installingFile' -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Read-Host 'Premi INVIO per chiudere'
"@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bgScript))
    $proc = Start-Process powershell -ArgumentList "-NoExit -EncodedCommand $encoded" -PassThru

    # Save PID so the menu can monitor the process
    @{ InstallerPID = $proc.Id; StartedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") } |
        ConvertTo-Json | Set-Content $installingFile -Encoding UTF8

    Write-Host (Get-Message -Key "Install_Launched") -ForegroundColor Green
    Write-Host ""
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

    # Folder selection via interactive browser
    Write-Host ""
    Write-Host "  $(Get-Message -Key 'Create_ChooseFolder')" -ForegroundColor Cyan
    Write-Host ""
    Read-Host (Get-Message -Key "Common_PressEnter") | Out-Null

    $chosenBase = Select-FolderInteractive
    if ($null -eq $chosenBase) { return }

    # Append server name as subfolder
    $finalPath = Join-Path $chosenBase $serverName

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

    $assignedPort = Get-NextAvailablePort -BasePort 27016

    $server = @{
        ServerId     = [guid]::NewGuid().ToString()
        Name         = $serverName
        Game         = "l4d2"
        Path         = $finalPath
        Status       = "Installing"
        FirewallPort = $assignedPort
        CreatedAt    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        LastUpdate   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }

    Add-ServerToRegistry $server
    Write-Log "Server registrato: $serverName -> $finalPath (porta $assignedPort)" "INFO"

    Start-ServerInstall $server

    $fresh = @(Get-ServerRegistry) | Where-Object { $_.ServerId -eq $server.ServerId } | Select-Object -First 1
    if ($fresh -and (Get-ServerDiskStatus -Path (Get-GamePath $fresh)) -eq "Installed") {
        Write-Host ""
        $runWizard = Read-Host (Get-Message -Key "Wizard_LaunchPrompt")
        if ($runWizard -eq (Get-Message -Key "ConfirmYes")) {
            Invoke-SetupWizard -Server $fresh -RootPath $RootPath | Out-Null
        }
    }
}

function Find-UnregisteredServers {
    # Scans DefaultInstallRoot for server folders (managed or flat) not in registry.
    $basePath = $config.DefaultInstallRoot
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

    # --- Scan for unregistered servers in default folder ---
    $orphans = @(Find-UnregisteredServers)

    Write-Host "====================================="
    Write-Host (Get-Message -Key "Scan_SectionTitle") -ForegroundColor Yellow
    Write-Host ""

    if ($orphans.Count -eq 0) {
        Write-Host (Get-Message -Key "Scan_None") -ForegroundColor DarkGray
        Write-Host ""
        Read-Host (Get-Message -Key "Common_PressEnter")
        return
    }

    foreach ($o in $orphans) {
        $folderName = Split-Path -Leaf $o.Path
        $gamePath   = if ($o.Type -eq "flat") { $o.Path } else { Join-Path $o.Path "server" }
        $disk       = Get-ServerDiskStatus -Path $gamePath
        $typeTag    = if ($o.Type -eq "flat") { " [ext]" } else { "" }
        Write-Host (Get-Message -Key "Scan_Item" -MsgArgs @("$folderName$typeTag", $disk)) -ForegroundColor Yellow
    }
    Write-Host ""

    $ans = Read-Host (Get-Message -Key "Scan_RegisterPrompt")
    if ($ans -ne (Get-Message -Key "ConfirmYes")) {
        Read-Host (Get-Message -Key "Common_PressEnter")
        return
    }

    Write-Host ""
    Write-Host (Get-Message -Key "Scan_Registering") -ForegroundColor Cyan
    $count = 0
    foreach ($o in $orphans) {
        $folderName  = Split-Path -Leaf $o.Path
        $isFlat      = ($o.Type -eq "flat")
        $gamePath    = Join-Path $o.Path "server"
        $managerPath = Join-Path $o.Path "manager"

        # Skip if name already taken
        if (Get-ServerByName -Name $folderName) {
            Write-Host "  [SKIP] $folderName — $(Get-Message -Key 'Recover_NameExists')" -ForegroundColor DarkGray
            continue
        }

        # Flat servers: restructure first (move files into server/, create manager/)
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
                Write-Host "  [FAIL] $folderName — $(Get-Message -Key 'Recover_RestructureFailed' -MsgArgs @($_))" -ForegroundColor Red
                # Cleanup empty dirs
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

function Invoke-ResumeInstallation {
    Show-Header
    Write-Host (Format-SectionTitle (Get-Message -Key "Resume_Title"))
    Write-Host ""

    $candidates = @(Get-ServerRegistry | Where-Object {
        $_.Status -ne "Installed" -or (Get-ServerDiskStatus -Path (Get-GamePath $_)) -ne "Installed"
    })

    if ($candidates.Count -eq 0) {
        Write-Host "$(Get-Message -Key 'Resume_AllInstalled')`n"
        Read-Host (Get-Message -Key "Common_PressEnter")
        return
    }

    if ($candidates.Count -eq 1) {
        $target = $candidates[0]
		
        $disk = Get-ServerDiskStatus -Path (Get-GamePath $target)
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
    Write-Host ""

    # Offer default folder as quick option
    $defaultBase    = $config.DefaultInstallRoot
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

# Session-level public IP cache (avoids repeated HTTP calls)
$script:_PubIPCache    = $null
$script:_PubIPCacheAge = $null

# Track servers started in this tool session (by ServerId)
$script:_StartedThisSession = @()

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
        [bool]$IsRunning = $false
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
        # This handles servers started outside the tool or after a crash recovery
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
                    -RootPath $RootPath -Language $config.Language -Port $fwPort
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
    param($server)

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
                # Stale .running file — remove it
                Remove-Item $runningFile -Force -ErrorAction SilentlyContinue
                Write-Log "Removed stale .running file for server: $($server.Name)" "INFO"
            }
        } catch { }
    }

    # Fallback: if no .running file or stale, check via A2S_INFO query
    # Handles servers started outside the tool or after tool restart
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
    param([object]$Server)

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
            $shortPath = Get-ShortPath -Path $s.Path
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
        $shortPath   = Get-ShortPath -Path $selected.Path
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
                    # Process gone but status not updated → crashed or killed
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

        # Reload selected from registry to pick up status changes (install done, error, etc.)
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

        Show-ServerStatusBox -server $selected

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
                Invoke-NetworkMenu -Selected $selected -IsRunning $netRunning
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

                # ── [1] SERVER INFO ──────────────────────────────────────────
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

                # ── [2] CONFIG (manager/config.json) ─────────────────────────
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

                # ── [3] LAUNCH COMMAND ───────────────────────────────────────
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
                    Write-Host "  [--] Server not installed — launch command not available" -ForegroundColor DarkGray
                }

                # ── [4] RCON ─────────────────────────────────────────────────
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

                # ── [5] NETWORK ──────────────────────────────────────────────
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
                    # Show only the configured game port owned by srcds
                    # (srcds also opens internal ephemeral ports on loopback — we ignore those)
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
                    Write-Host "  Server not running — no ports to show" -ForegroundColor DarkGray
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

# --- RIAVVIO SERVER ---

function Invoke-RestartServer {
    param($server)

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

    $managerPath = Get-ManagerPath $Server
    $configPath  = Join-Path $managerPath "config.json"
    $serverConfig = if (Test-Path $configPath) {
        Get-Content $configPath -Raw | ConvertFrom-Json
    } else {
        [PSCustomObject]@{ RconPassword = ""; Notes = "" }
    }

    $wizGameMeta  = Get-GameMetadata -Game $Server.Game
    $wizGameFolder = if ($wizGameMeta -and $wizGameMeta.GameFolder) { $wizGameMeta.GameFolder } else { $Server.Game }
    $cfgFile = Join-Path (Get-GamePath $Server) "$wizGameFolder\cfg\server.cfg"
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
        $adminFile = Join-Path (Get-GamePath $Server) "$($modConfig.GameFolder)\addons\sourcemod\configs\admins_simple.ini"
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

# --- IMPOSTAZIONI ---

function Invoke-Settings {
    while ($true) {
        Show-Header
        Write-Host (Format-SectionTitle (Get-Message -Key "Settings_Title"))
        Write-Host ""
        Write-Host "  1) $(Get-Message -Key 'Settings_ChangeLang')"
        Write-Host "  2) $(Get-Message -Key 'Settings_ChangeServerRoot'): $($config.DefaultInstallRoot)"
        Write-Host "  3) $(Get-Message -Key 'Settings_ResetConfig')" -ForegroundColor DarkGray
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
            "2" {
                $newRoot = Ask-DefaultInstallRoot -AllowCancel
                if ($null -ne $newRoot) {
                    Save-DefaultInstallRoot -ConfigPath "$RootPath\config\default_config.json" -Path $newRoot
                    $config.DefaultInstallRoot = $newRoot
                    Write-Host "`n$(Get-Message -Key 'Settings_ServerRootChanged')`n" -ForegroundColor Green
                }
                Start-Sleep -Seconds 2
            }
            "3" {
                Write-Host "`n$(Get-Message -Key 'Settings_ResetConfirm')" -ForegroundColor Yellow
                $confirm = Read-Host (Get-Message -Key "Common_ConfirmPrompt")
                if ($confirm -eq (Get-Message -Key "ConfirmYes")) {
                    $cfg = Get-Content "$RootPath\config\default_config.json" -Raw | ConvertFrom-Json
                    $cfg.Language = ""
                    $cfg.DefaultInstallRoot = "servers"
                    $cfg | ConvertTo-Json -Depth 5 | Set-Content "$RootPath\config\default_config.json" -Encoding UTF8
                    Write-Host (Get-Message -Key "Settings_ResetDone") -ForegroundColor Green
                    Start-Sleep -Seconds 2
                    return
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

# --- RECUPERO SERVER ---

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

    # Multiple candidates — let user pick
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
        if ($resume -eq (Get-Message -Key "ConfirmYes")) { Start-ServerInstall $s }
    }
    else {
        Write-Host "$(Get-Message -Key 'Startup_IncompleteMany' -MsgArgs @($incomplete.Count))`n" -ForegroundColor Yellow
        foreach ($s in $incomplete) {
            $disk = Get-ServerDiskStatus -Path (Get-GamePath $s)
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
    Show-SettingsSummary

    $hasIncomplete = (@(Get-ServerRegistry | Where-Object {
        $_.Status -ne "Installed" -or (Get-ServerDiskStatus -Path (Get-GamePath $_)) -ne "Installed"
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
            "5" { Invoke-RecoverServer }
            "6" { Invoke-Settings }
            "7" { Write-Log "Manager chiuso" "INFO"; exit }
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
            "4" { Invoke-RecoverServer }
            "5" { Invoke-Settings }
            "6" { Write-Log "Manager chiuso" "INFO"; exit }
            default {
                Write-Host "`n$(Get-Message -Key 'Common_InvalidOption')`n" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}
