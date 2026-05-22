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
# Interactive folder browser
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
    param(
        [string]$DefaultInstallRoot = "",
        [string]$Title = "",
        [string]$CurrentValue = ""
    )

    $allDrives = @(Get-WmiObject Win32_LogicalDisk -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveType -eq 3 -and $_.FileSystem -eq 'NTFS' } |
        Sort-Object DeviceID)
    $sysDrive = $env:SystemDrive

    $singleDrive = ($allDrives.Count -eq 1)
    # Always start at drive selection so the default option is always visible
    $currentPath = ""

    while ($true) {
        Clear-Host
        Write-Host "=====================================" -ForegroundColor Cyan
        $displayTitle = if ([string]::IsNullOrEmpty($Title)) { Get-Message -Key "Setup_ServerFolderTitle" } else { $Title }
        Write-Host "  $displayTitle" -ForegroundColor White
        Write-Host "=====================================" -ForegroundColor Cyan
        Write-Host ""
        if (-not [string]::IsNullOrEmpty($CurrentValue)) {
            Write-Host "  $(Get-Message -Key 'Browse_CurrentDefault')" -NoNewline -ForegroundColor DarkGray
            Write-Host "  $CurrentValue" -ForegroundColor White
            Write-Host ""
        }

        if ($currentPath -eq "") {
            $hasDefault = (-not [string]::IsNullOrEmpty($DefaultInstallRoot)) -and (Test-Path $DefaultInstallRoot)

            Write-Host "  --- $(Get-Message -Key 'Browse_SelectDrive') ---" -ForegroundColor Yellow
            Write-Host ""

            # Build option list: default first (if available), then drives
            $options = @()
            if ($hasDefault) {
                $defDrvLetter = $DefaultInstallRoot.Substring(0,2)
                $defDrv       = $allDrives | Where-Object { $_.DeviceID -eq $defDrvLetter } | Select-Object -First 1
                $defFreeGB    = if ($defDrv) { [math]::Round($defDrv.FreeSpace / 1GB, 1) } else { -1 }
                $defIsSystem  = ($defDrvLetter -eq $sysDrive)
                $defGB        = if ($defFreeGB -ge 0) { "${defFreeGB}GB" } else { "" }
                if ($defIsSystem) {
                    $defLabel = Get-Message -Key "Browse_DefaultSystem"
                    $defColor = "Yellow"
                } elseif ($defFreeGB -ge 0 -and $defFreeGB -lt 15) {
                    $defLabel = Get-Message -Key "Browse_DefaultLow"
                    $defColor = "Red"
                } else {
                    $defLabel = Get-Message -Key "Browse_DefaultOk"
                    $defColor = "Green"
                }
                $isAlreadySet = (-not [string]::IsNullOrEmpty($CurrentValue)) -and ($DefaultInstallRoot.TrimEnd('\') -eq $CurrentValue.TrimEnd('\'))
                $finalColor   = if ($isAlreadySet) { "DarkGray" } else { $defColor }
                $options += [PSCustomObject]@{ Type = "default"; Label = $DefaultInstallRoot; Suffix = "  [$defLabel  $defGB]"; Color = $finalColor }
            }
            foreach ($drv in $allDrives) {
                $letter = $drv.DeviceID
                $freeGB = [math]::Round($drv.FreeSpace / 1GB, 1)
                if ($letter -eq $sysDrive) {
                    $options += [PSCustomObject]@{ Type = "drive"; Label = "$letter\"; Suffix = "  [$(Get-Message -Key 'Browse_SystemDrive')  ${freeGB}GB]"; Color = "Yellow" }
                } else {
                    $suffix = Get-SpaceSuffix -GB $freeGB
                    $color  = Get-SpaceColor  -GB $freeGB
                    $options += [PSCustomObject]@{ Type = "drive"; Label = "$letter\"; Suffix = $suffix; Color = $color }
                }
            }

            for ($i = 0; $i -lt $options.Count; $i++) {
                $o   = $options[$i]
                $num = $i + 1
                Write-Host "  $num) " -NoNewline -ForegroundColor White
                Write-Host "$($o.Label)$($o.Suffix)" -ForegroundColor $o.Color
            }
            Write-Host "  0) $(Get-Message -Key 'Browse_Cancel')" -ForegroundColor White
            Write-Host ""

            $prompt = if ($hasDefault) { Get-Message -Key "Browse_SelectPromptDefault" } else { Get-Message -Key "Browse_SelectPrompt" }
            $choice = (Read-Host "  $prompt").Trim()

            # ENTER = option 1 (default folder) when available
            if ($choice -eq "" -and $hasDefault) { $choice = "1" }
            if ($choice -eq "0") { return $null }
            if ($choice -match '^\d+$') {
                $ci = [int]$choice - 1
                if ($ci -ge 0 -and $ci -lt $options.Count) {
                    $opt = $options[$ci]
                    if ($opt.Type -eq "default") {
                        return $DefaultInstallRoot.TrimEnd('\')
                    }
                    # It's a drive — check space
                    $drvObj = $allDrives | Where-Object { ($_.DeviceID + '\') -eq $opt.Label } | Select-Object -First 1
                    $freeGB = if ($drvObj) { [math]::Round($drvObj.FreeSpace / 1GB, 1) } else { -1 }
                    if ($freeGB -ge 0 -and $freeGB -lt 10) {
                        Write-Host ""
                        Write-Host "  $(Get-Message -Key 'Browse_InsufficientSpace')" -ForegroundColor Red
                        Start-Sleep -Seconds 2
                        continue
                    }
                    $currentPath = $opt.Label
                }
            }
        } else {
            $freeGB = Get-PathFreeGB -Path $currentPath
            $suffix = Get-SpaceSuffix -GB $freeGB
            $color  = Get-SpaceColor -GB $freeGB
            $isAtDriveRoot = ($currentPath -match '^[A-Za-z]:\\?$')

            Write-Host "  $(Get-Message -Key 'Browse_CurrentPath'):" -ForegroundColor Gray
            Write-Host "  $currentPath" -ForegroundColor White
            Write-Host "  $(Get-Message -Key 'Browse_FreeSpace'):" -NoNewline -ForegroundColor DarkGray
            Write-Host $suffix -ForegroundColor $color
            Write-Host ""

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
            $hasDefaultNav = (-not [string]::IsNullOrEmpty($DefaultInstallRoot)) -and (Test-Path $DefaultInstallRoot)
            if ($hasDefaultNav) {
                Write-Host "  D) $(Get-Message -Key 'Browse_GoDefault')" -ForegroundColor Green
            }
            Write-Host "  0) $(Get-Message -Key 'Browse_Back')" -ForegroundColor White
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
            } elseif ($choice -in @("D","d")) {
                if ($hasDefaultNav) { return $DefaultInstallRoot.TrimEnd('\') }
            } elseif ($choice -eq "0") {
                if ($isAtDriveRoot) {
                    $currentPath = ""
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
            continue
        }
        return $chosen
    }
}

# -------------------------------------------------------
# Global settings menu
# -------------------------------------------------------

function Invoke-Settings {
    param(
        $Config,
        [string]$RootPath
    )

    while ($true) {
        Show-Header
        Write-Host (Format-SectionTitle (Get-Message -Key "Settings_Title"))
        Write-Host ""
        Write-Host "  1) $(Get-Message -Key 'Settings_ChangeLang')"
        Write-Host "  2) $(Get-Message -Key 'Settings_ChangeServerRoot'): $($Config.DefaultInstallRoot)"
        Write-Host "  3) $(Get-Message -Key 'Settings_ResetConfig')" -ForegroundColor DarkGray
        Write-Host "  0) $(Get-Message -Key 'Manage_Back')"
        Write-Host ""

        $action = Read-Host (Get-Message -Key "Common_Select")

        switch ($action) {
            "1" {
                $cancelLabel = Get-Message -Key "Common_Cancel"
                $newLang = Select-Language -LocaleDir "$RootPath\locale" -CancelLabel $cancelLabel
                if ($null -ne $newLang -and $newLang -ne $Config.Language) {
                    Save-Language -ConfigPath "$RootPath\config\default_config.json" -LangCode $newLang
                    $Config.Language = $newLang
                    $lf = "$RootPath\locale\$newLang.json"
                    if (-not (Test-Path $lf)) { $lf = "$RootPath\locale\it.json" }
                    Set-Messages (Get-Content $lf -Raw | ConvertFrom-Json)
                    Write-Host ""
                    Write-Host (Get-Message -Key "Settings_LangChanged") -ForegroundColor Green
                    Start-Sleep -Seconds 2
                }
            }
            "2" {
                $newRoot = Select-FolderInteractive -DefaultInstallRoot $Config.DefaultInstallRoot -Title (Get-Message -Key "Settings_ServerFolderTitle") -CurrentValue $Config.DefaultInstallRoot
                if ($null -ne $newRoot) {
                    if ($newRoot.TrimEnd('\') -ne $Config.DefaultInstallRoot.TrimEnd('\')) {
                        Save-DefaultInstallRoot -ConfigPath "$RootPath\config\default_config.json" -Path $newRoot
                        $Config.DefaultInstallRoot = $newRoot
                        Write-Host "`n$(Get-Message -Key 'Settings_ServerRootChanged')`n" -ForegroundColor Green
                    } else {
                        Write-Host "`n$(Get-Message -Key 'Settings_ServerRootUnchanged')`n" -ForegroundColor DarkGray
                    }
                    Read-Host (Get-Message -Key "Common_PressEnter") | Out-Null
                }
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

Export-ModuleMember -Function Select-Language, Save-Language, Save-DefaultInstallRoot, Test-IsSystemFolder, Select-FolderInteractive, Ask-DefaultInstallRoot, Invoke-Settings
