function Start-ServerInstall {
    param(
        $Target,
        [string]$RootPath,
        $Config
    )

    $gamePath    = Get-GamePath    $Target
    $managerPath = Get-ManagerPath $Target

    if (-not (Test-Path $Target.Path))  { New-Item -ItemType Directory -Path $Target.Path    -Force | Out-Null }
    if (-not (Test-Path $gamePath))     { New-Item -ItemType Directory -Path $gamePath       -Force | Out-Null }
    if (-not (Test-Path $managerPath))  { New-Item -ItemType Directory -Path $managerPath    -Force | Out-Null }

    $managerConfigFile = Join-Path $managerPath "config.json"
    if (-not (Test-Path $managerConfigFile)) {
        $assignedPort = Get-NextServerPort -BasePort 27016

        $initMetaFile = Join-Path $RootPath "games\$($Target.Game)\metadata.json"
        $initDefaultMap  = "c1m4_atrium"
        $initDefaultMode = "coop"
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

        Write-Log "Created manager config for $($Target.Name) - Port: $assignedPort" "INFO"
    }

    $steamDir = Join-Path $RootPath "downloads\steamcmd"
    if (-not (Test-Path $steamDir)) { New-Item -ItemType Directory -Path $steamDir -Force | Out-Null }

    $gameMetaFile = Join-Path $RootPath "games\$($Target.Game)\metadata.json"
    $targetAppId  = "0"
    if (Test-Path $gameMetaFile) {
        try {
            $gameMeta    = Get-Content $gameMetaFile -Raw | ConvertFrom-Json
            $targetAppId = [string]$gameMeta.SteamAppId
        } catch { }
    }

    Write-Host "`n$(Get-Message -Key 'Install_Starting' -MsgArgs @($Target.Name))`n" -ForegroundColor Cyan
    Write-Host (Get-Message -Key "Install_SteamCmdNote")
    Write-Host ""

    Update-ServerStatus -ServerId $Target.ServerId -Status "Installing"

    $registryModule = Join-Path $RootPath "modules\registry.psm1"
    $steamModule    = Join-Path $RootPath "modules\steamcmd.psm1"
    $loggingModule  = Join-Path $RootPath "modules\logging.psm1"
    $messagesModule = Join-Path $RootPath "modules\messages.psm1"
    $localeFile     = Join-Path $RootPath "locale\$($Config.Language).json"
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

`$host.ui.RawUI.WindowTitle = 'Installing: $($Target.Name)'
Write-Host 'Installing: $($Target.Name)' -ForegroundColor Cyan
Write-Host ''

try {
    `$exe = Install-SteamCMD -Path '$steamDir'
    Install-GameServer -SteamCmdPath `$exe -AppId '$targetAppId' -InstallDir '$gamePath' -SteamCmdDir '$steamDir' -ScriptId '$($Target.ServerId)'
    Update-ServerStatus -ServerId '$($Target.ServerId)' -Status 'Installed'
    Write-Host ''
    Write-Host 'Installazione completata con successo.' -ForegroundColor Green
    Write-Log 'Installazione completata: $($Target.Path)' 'INFO'
}
catch {
    Update-ServerStatus -ServerId '$($Target.ServerId)' -Status 'Error'
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

    @{ InstallerPID = $proc.Id; StartedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") } |
        ConvertTo-Json | Set-Content $installingFile -Encoding UTF8

    Write-Host (Get-Message -Key "Install_Launched") -ForegroundColor Green
    Write-Host ""
    Read-Host (Get-Message -Key "Common_PressEnter")
}

function Invoke-CreateServer {
    param(
        [string]$RootPath,
        $Config
    )

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

    Write-Host ""
    Write-Host "  $(Get-Message -Key 'Create_ChooseFolder')" -ForegroundColor Cyan
    Write-Host ""
    Read-Host (Get-Message -Key "Common_PressEnter") | Out-Null

    $chosenBase = Select-FolderInteractive
    if ($null -eq $chosenBase) { return }

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

    $assignedPort = Get-NextServerPort -BasePort 27016

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

    Start-ServerInstall -Target $server -RootPath $RootPath -Config $Config

    $fresh = @(Get-ServerRegistry) | Where-Object { $_.ServerId -eq $server.ServerId } | Select-Object -First 1
    if ($fresh -and (Get-ServerDiskStatus -Path (Get-GamePath $fresh)) -eq "Installed") {
        Write-Host ""
        $runWizard = Read-Host (Get-Message -Key "Wizard_LaunchPrompt")
        if ($runWizard -eq (Get-Message -Key "ConfirmYes")) {
            Invoke-SetupWizard -Server $fresh -RootPath $RootPath | Out-Null
        }
    }
}

function Invoke-ResumeInstallation {
    param(
        [string]$RootPath,
        $Config
    )

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
        Start-ServerInstall -Target $target -RootPath $RootPath -Config $Config
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

    Start-ServerInstall -Target $candidates[$idx] -RootPath $RootPath -Config $Config
}

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

    # --- STEP 1: Server info ---
    Write-WizardStep 1 (Get-Message -Key "Wizard_Step1_Title")

    $managerPath = Get-ManagerPath $Server
    $configPath  = Join-Path $managerPath "config.json"
    $serverConfig = if (Test-Path $configPath) {
        Get-Content $configPath -Raw | ConvertFrom-Json
    } else {
        [PSCustomObject]@{ RconPassword = ""; Notes = "" }
    }

    $wizGameMeta   = Get-GameMetadata -Game $Server.Game
    $wizGameFolder = if ($wizGameMeta -and $wizGameMeta.GameFolder) { $wizGameMeta.GameFolder } else { $Server.Game }
    $cfgFile = Join-Path (Get-GamePath $Server) "$wizGameFolder\cfg\server.cfg"
    $currentHostname   = ""
    $currentSteamGroup = ""
    if (Test-Path $cfgFile) {
        $cfgContent = Get-Content $cfgFile -Raw
        if ($cfgContent -match '(?m)^hostname\s+"?([^"\r\n]+)"?')    { $currentHostname   = $matches[1].Trim() }
        if ($cfgContent -match '(?m)^sv_steamgroup\s+"?([^"\r\n]+)"?') { $currentSteamGroup = $matches[1].Trim() }
    }

    $hasRcon     = -not [string]::IsNullOrWhiteSpace($serverConfig.RconPassword)
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
    $fwRule = Get-ServerFirewallRule -ServerName $Server.Name -Port $fwPort

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

Export-ModuleMember -Function Start-ServerInstall, Invoke-CreateServer, Invoke-ResumeInstallation, Invoke-SetupWizard
