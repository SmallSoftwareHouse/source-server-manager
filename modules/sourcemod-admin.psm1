function Update-PlayerList {
    param(
        [string]$ServerPath,
        [string]$GameFolder,
        [string]$ManagerPath
    )

    $logsPath    = Join-Path $ServerPath "$GameFolder\addons\sourcemod\logs"
    $playersFile = Join-Path $ManagerPath "players.json"

    if (-not (Test-Path $logsPath)) { return 0 }
    $logFiles = @(Get-ChildItem $logsPath -Filter "L_*.log" -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($logFiles.Count -eq 0) { return 0 }

    $players = @{}
    if (Test-Path $playersFile) {
        try {
            foreach ($p in @(Get-Content $playersFile -Raw | ConvertFrom-Json)) {
                if ($p.SteamId) { $players[$p.SteamId] = $p }
            }
        } catch { }
    }

    $connRx = [regex]'"([^"]+)<\d+><(STEAM_[0-9]:[0-9]:\d+)><[^>]*>" connected'
    $dateRx = [regex]'^L (\d{2}/\d{2}/\d{4}) - (\d{2}:\d{2}:\d{2}):'

    foreach ($file in $logFiles) {
        $lines = Get-Content $file.FullName -ErrorAction SilentlyContinue
        if (-not $lines) { continue }
        foreach ($line in $lines) {
            $cm = $connRx.Match($line)
            if (-not $cm.Success) { continue }
            $name    = $cm.Groups[1].Value
            $steamId = $cm.Groups[2].Value
            $timestamp = ""
            $dm = $dateRx.Match($line)
            if ($dm.Success) {
                $dp = $dm.Groups[1].Value -split '/'
                $timestamp = "$($dp[2])-$($dp[0])-$($dp[1]) $($dm.Groups[2].Value)"
            }
            if ($players.ContainsKey($steamId)) {
                $players[$steamId].Name = $name
                if ($timestamp -and $timestamp -gt $players[$steamId].LastSeen) {
                    $players[$steamId].LastSeen = $timestamp
                }
            } else {
                $players[$steamId] = [PSCustomObject]@{
                    SteamId   = $steamId
                    Name      = $name
                    FirstSeen = $timestamp
                    LastSeen  = $timestamp
                }
            }
        }
    }

    $list = @($players.Values | Sort-Object LastSeen -Descending)
    ConvertTo-Json -InputObject $list | Set-Content $playersFile -Encoding UTF8
    return $list.Count
}

function Get-PlayerList {
    param([string]$ManagerPath)
    $f = Join-Path $ManagerPath "players.json"
    if (-not (Test-Path $f)) { return @() }
    try { return @(Get-Content $f -Raw | ConvertFrom-Json) } catch { return @() }
}

function Get-SmAdmins {
    param([string]$ServerPath, [string]$GameFolder)
    $f = Join-Path $ServerPath "$GameFolder\addons\sourcemod\configs\admins_simple.ini"
    if (-not (Test-Path $f)) { return @() }
    $rx = [regex]'^"([^"]+)"\s+"([^"]+)"'
    $admins = @()
    foreach ($line in (Get-Content $f -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if ($t.StartsWith("//") -or [string]::IsNullOrWhiteSpace($t)) { continue }
        $m = $rx.Match($t)
        if ($m.Success) {
            $admins += [PSCustomObject]@{ SteamId = $m.Groups[1].Value; Flags = $m.Groups[2].Value }
        }
    }
    return $admins
}

function Add-SmAdmin {
    param([string]$ServerPath, [string]$GameFolder, [string]$SteamId, [string]$Flags)
    $f = Join-Path $ServerPath "$GameFolder\addons\sourcemod\configs\admins_simple.ini"
    if (-not (Test-Path $f)) { return $false }
    $newLine = "`"$SteamId`"`t`"$Flags`""
    [System.IO.File]::AppendAllText($f, "`n$newLine", [System.Text.Encoding]::UTF8)
    Write-Log "SM admin added: $SteamId ($Flags)" "INFO"
    return $true
}

function Remove-SmAdmin {
    param([string]$ServerPath, [string]$GameFolder, [string]$SteamId)
    $f = Join-Path $ServerPath "$GameFolder\addons\sourcemod\configs\admins_simple.ini"
    if (-not (Test-Path $f)) { return $false }
    $escaped = [regex]::Escape($SteamId)
    $lines = Get-Content $f -ErrorAction SilentlyContinue
    $filtered = $lines | Where-Object { $_.Trim() -notmatch "^`"$escaped`"" }
    [System.IO.File]::WriteAllLines($f, $filtered, [System.Text.Encoding]::UTF8)
    Write-Log "SM admin removed: $SteamId" "INFO"
    return $true
}

function Show-AdminMenu {
    param(
        [object]$Server,
        [string]$RootPath
    )

    $modsConfigPath = Join-Path $RootPath "games\$($Server.Game)\configs\mods.json"
    if (-not (Test-Path $modsConfigPath)) {
        Write-Host "`n$(Get-Message -Key 'Mod_ConfigNotFound')`n" -ForegroundColor Red
        Read-Host (Get-Message -Key "Common_PressEnter")
        return
    }
    $modConfig   = Get-Content $modsConfigPath -Raw | ConvertFrom-Json
    $gameFolder  = $modConfig.GameFolder
    $gamePath    = Join-Path $Server.Path "server"
    $managerPath = Join-Path $Server.Path "manager"
    $adminsFile  = Join-Path $gamePath "$gameFolder\addons\sourcemod\configs\admins_simple.ini"

    if (-not (Test-Path $adminsFile)) {
        Write-Host "`n$(Get-Message -Key 'Admin_SmNotInstalled')`n" -ForegroundColor Red
        Read-Host (Get-Message -Key "Common_PressEnter")
        return
    }

    while ($true) {
        $admins  = @(Get-SmAdmins -ServerPath $gamePath -GameFolder $gameFolder)
        $players = @(Get-PlayerList -ManagerPath $managerPath)

        Write-Host ""
        Write-Host "  $(Get-Message -Key 'Admin_Title'): $($Server.Name)" -ForegroundColor Cyan
        Write-Host ""

        if ($admins.Count -eq 0) {
            Write-Host "  $(Get-Message -Key 'Admin_NoAdmins')" -ForegroundColor DarkGray
        } else {
            foreach ($a in $admins) {
                $pName = ($players | Where-Object { $_.SteamId -eq $a.SteamId } | Select-Object -First 1).Name
                $display = if ($pName) { "$($a.SteamId)  ($pName)" } else { $a.SteamId }
                Write-Host "  [OK] $display  — [$($a.Flags)]" -ForegroundColor Green
            }
        }

        Write-Host ""
        Write-Host "  1) $(Get-Message -Key 'Admin_AddAdmin')"
        if ($admins.Count -gt 0) {
            Write-Host "  2) $(Get-Message -Key 'Admin_RemoveAdmin')"
        } else {
            Write-Host "  2) $(Get-Message -Key 'Admin_RemoveAdmin')" -ForegroundColor DarkGray
        }
        Write-Host "  3) $(Get-Message -Key 'Admin_ScanLogs') ($($players.Count) $(Get-Message -Key 'Admin_KnownPlayers'))"
        Write-Host "  0) $(Get-Message -Key 'Manage_Back')"
        Write-Host ""

        $choice = Read-Host (Get-Message -Key "Common_Select")

        switch ($choice) {
            "1" {
                $steamId = $null

                Write-Host ""
                Write-Host "  1) $(Get-Message -Key 'Admin_FromPlayerList') ($($players.Count) $(Get-Message -Key 'Admin_KnownPlayers'))"
                Write-Host "  2) $(Get-Message -Key 'Admin_FromConnected')"
                Write-Host "  3) $(Get-Message -Key 'Admin_ManualSteamId')"
                Write-Host "  0) $(Get-Message -Key 'Common_Cancel')"
                Write-Host ""
                $src = Read-Host (Get-Message -Key "Common_Select")

                if ($src -eq "1") {
                    $adminIds = $admins | ForEach-Object { $_.SteamId }
                    $candidates = @($players | Where-Object { $adminIds -notcontains $_.SteamId })
                    if ($candidates.Count -eq 0) {
                        Write-Host "`n$(Get-Message -Key 'Admin_NoPlayers')`n" -ForegroundColor DarkGray
                        Read-Host (Get-Message -Key "Common_PressEnter")
                        break
                    }
                    Write-Host ""
                    for ($i = 0; $i -lt $candidates.Count; $i++) {
                        $p = $candidates[$i]
                        Write-Host "  $($i+1)) $($p.Name)  $($p.SteamId)  $(Get-Message -Key 'Admin_LastSeen'): $($p.LastSeen)"
                    }
                    Write-Host "  0) $(Get-Message -Key 'Common_Cancel')"
                    Write-Host ""
                    $pSel = Read-Host (Get-Message -Key "Common_Select")
                    if ($pSel -eq "0" -or [string]::IsNullOrWhiteSpace($pSel)) { break }
                    $pIdx = [int]$pSel - 1
                    if ($pIdx -lt 0 -or $pIdx -ge $candidates.Count) {
                        Write-Host "`n$(Get-Message -Key 'Common_InvalidSelection')`n" -ForegroundColor Red
                        Read-Host (Get-Message -Key "Common_PressEnter")
                        break
                    }
                    $steamId = $candidates[$pIdx].SteamId
                }
                elseif ($src -eq "2") {
                    $statusResp = Invoke-ServerRcon -Server $Server -Command "status"
                    if ($null -eq $statusResp) {
                        Write-Host "`n$(Get-Message -Key 'Mod_VerifyNoRcon')`n" -ForegroundColor Yellow
                        Read-Host (Get-Message -Key "Common_PressEnter")
                        break
                    }
                    $adminIds = $admins | ForEach-Object { $_.SteamId }
                    $connected = @()
                    $statusRx = [regex]'#\s+\d+\s+"([^"]+)"\s+(STEAM_[0-9]:[0-9]:\d+)'
                    foreach ($m in $statusRx.Matches($statusResp)) {
                        $sid = $m.Groups[2].Value
                        if ($adminIds -notcontains $sid) {
                            $connected += [PSCustomObject]@{ Name = $m.Groups[1].Value; SteamId = $sid }
                        }
                    }
                    if ($connected.Count -eq 0) {
                        Write-Host "`n$(Get-Message -Key 'Admin_NoConnected')`n" -ForegroundColor DarkGray
                        Read-Host (Get-Message -Key "Common_PressEnter")
                        break
                    }
                    Write-Host ""
                    for ($i = 0; $i -lt $connected.Count; $i++) {
                        Write-Host "  $($i+1)) $($connected[$i].Name)  $($connected[$i].SteamId)"
                    }
                    Write-Host "  0) $(Get-Message -Key 'Common_Cancel')"
                    Write-Host ""
                    $cSel = Read-Host (Get-Message -Key "Common_Select")
                    if ($cSel -eq "0" -or [string]::IsNullOrWhiteSpace($cSel)) { break }
                    $cIdx = [int]$cSel - 1
                    if ($cIdx -lt 0 -or $cIdx -ge $connected.Count) {
                        Write-Host "`n$(Get-Message -Key 'Common_InvalidSelection')`n" -ForegroundColor Red
                        Read-Host (Get-Message -Key "Common_PressEnter")
                        break
                    }
                    $steamId = $connected[$cIdx].SteamId
                }
                elseif ($src -eq "3") {
                    Write-Host ""
                    $steamId = (Read-Host (Get-Message -Key "Admin_SteamIdPrompt")).Trim()
                    if ([string]::IsNullOrWhiteSpace($steamId)) { break }
                    if ($steamId -notmatch '^STEAM_[0-9]:[0-9]:\d+$') {
                        Write-Host "`n$(Get-Message -Key 'Admin_InvalidSteamId')`n" -ForegroundColor Red
                        Read-Host (Get-Message -Key "Common_PressEnter")
                        break
                    }
                    if ($admins | Where-Object { $_.SteamId -eq $steamId }) {
                        Write-Host "`n$(Get-Message -Key 'Admin_AlreadyAdmin')`n" -ForegroundColor Yellow
                        Read-Host (Get-Message -Key "Common_PressEnter")
                        break
                    }
                }
                else { break }

                if ($steamId) {
                    Write-Host ""
                    Write-Host "  1) $(Get-Message -Key 'Admin_FlagRoot')"
                    Write-Host "  2) $(Get-Message -Key 'Admin_FlagModerator')"
                    Write-Host "  3) $(Get-Message -Key 'Admin_FlagCustom')"
                    Write-Host "  0) $(Get-Message -Key 'Common_Cancel')"
                    Write-Host ""
                    $fSel = Read-Host (Get-Message -Key "Admin_SelectFlags")
                    $flags = switch ($fSel) {
                        "1" { "z" }
                        "2" { "bcd" }
                        "3" {
                            Write-Host ""
                            (Read-Host (Get-Message -Key "Admin_FlagPrompt")).Trim()
                        }
                        default { $null }
                    }
                    if ($flags) {
                        Add-SmAdmin -ServerPath $gamePath -GameFolder $gameFolder -SteamId $steamId -Flags $flags
                        Write-Host "`n$(Get-Message -Key 'Admin_Added')" -ForegroundColor Green

                        $reloadResp = Invoke-ServerRcon -Server $Server -Command "sm admins rebuild"
                        if ($null -ne $reloadResp) {
                            Write-Host "$(Get-Message -Key 'Admin_ReloadDone')" -ForegroundColor DarkGray
                        } else {
                            Write-Host "$(Get-Message -Key 'Admin_ReloadFailed')" -ForegroundColor DarkGray
                        }
                        Write-Host ""
                        Read-Host (Get-Message -Key "Common_PressEnter")
                    }
                }
            }
            "2" {
                if ($admins.Count -eq 0) { break }
                Write-Host ""
                for ($i = 0; $i -lt $admins.Count; $i++) {
                    $a = $admins[$i]
                    $pName = ($players | Where-Object { $_.SteamId -eq $a.SteamId } | Select-Object -First 1).Name
                    $display = if ($pName) { "$($a.SteamId)  ($pName)" } else { $a.SteamId }
                    Write-Host "  $($i+1)) $display  — [$($a.Flags)]"
                }
                Write-Host "  0) $(Get-Message -Key 'Common_Cancel')"
                Write-Host ""
                $rSel = Read-Host (Get-Message -Key "Admin_SelectAdmin")
                if ($rSel -eq "0" -or [string]::IsNullOrWhiteSpace($rSel)) { break }
                $rIdx = [int]$rSel - 1
                if ($rIdx -lt 0 -or $rIdx -ge $admins.Count) {
                    Write-Host "`n$(Get-Message -Key 'Common_InvalidSelection')`n" -ForegroundColor Red
                    Read-Host (Get-Message -Key "Common_PressEnter")
                    break
                }
                $confirm = Read-Host (Get-Message -Key "Common_ConfirmPrompt")
                if ($confirm -eq (Get-Message -Key "ConfirmYes")) {
                    Remove-SmAdmin -ServerPath $gamePath -GameFolder $gameFolder -SteamId $admins[$rIdx].SteamId
                    Write-Host "`n$(Get-Message -Key 'Admin_Removed')" -ForegroundColor Green

                    $reloadResp = Invoke-ServerRcon -Server $Server -Command "sm admins rebuild"
                    if ($null -ne $reloadResp) {
                        Write-Host "$(Get-Message -Key 'Admin_ReloadDone')" -ForegroundColor DarkGray
                    } else {
                        Write-Host "$(Get-Message -Key 'Admin_ReloadFailed')" -ForegroundColor DarkGray
                    }
                    Write-Host ""
                    Read-Host (Get-Message -Key "Common_PressEnter")
                }
            }
            "3" {
                Write-Host "`n$(Get-Message -Key 'Admin_ScanningLogs')" -ForegroundColor Cyan
                $count = Update-PlayerList -ServerPath $gamePath -GameFolder $gameFolder -ManagerPath $managerPath
                Write-Host (Get-Message -Key "Admin_PlayersUpdated" -MsgArgs @($count)) -ForegroundColor Green
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

Export-ModuleMember -Function Update-PlayerList, Get-PlayerList, Show-AdminMenu
