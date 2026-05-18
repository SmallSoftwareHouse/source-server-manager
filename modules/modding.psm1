function Get-ModStatus {
    param(
        [string]$ServerPath,
        [string]$GameFolder,
        [string]$ManagerPath
    )

    $addonsPath    = Join-Path (Join-Path $ServerPath $GameFolder) "addons"
    $mmFolder      = Join-Path $addonsPath "metamod"
    $mmVdf         = Join-Path $addonsPath "metamod.vdf"
    $mmBin         = Join-Path $mmFolder "bin"
    $smFolder      = Join-Path $addonsPath "sourcemod"
    $smScripting   = Join-Path $smFolder "scripting"
    $versionFile   = Join-Path $ManagerPath ".mods_installed.json"

    $mmOk = (Test-Path $mmFolder) -and (Test-Path $mmVdf) -and (Test-Path $mmBin)
    $smOk = (Test-Path $smFolder) -and (Test-Path $smScripting)

    $mmVersion = $null
    $smVersion = $null

    if (Test-Path $versionFile) {
        try {
            $saved = Get-Content $versionFile -Raw | ConvertFrom-Json
            if ($saved.MetaMod -match '(\d+\.\d+\.\d+)') { $mmVersion = $Matches[1] }
            if ($saved.SourceMod -match '(\d+\.\d+\.\d+)') { $smVersion = $Matches[1] }
        } catch { }
    }

    return @{
        MetaMod          = $mmOk
        MetaModVersion   = $mmVersion
        SourceMod        = $smOk
        SourceModVersion = $smVersion
    }
}

function Get-ModDownloadUrls {
    param(
        [string]$PageUrl,
        [int]$MaxResults = 5
    )

    try {
        $response = Invoke-WebRequest -Uri $PageUrl -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
        $found = [regex]::Matches($response.Content, 'https://[^\s"''<>]+-windows\.zip')
        $urls = @($found | ForEach-Object { $_.Value } | Select-Object -Unique)
        if ($urls.Count -gt $MaxResults) { $urls = $urls[0..($MaxResults - 1)] }
        return $urls
    }
    catch {
        Write-Log "Failed to fetch mod version list from $PageUrl : $_" "WARNING"
        return $null
    }
}

function Save-ModVersions {
    param(
        [string]$ManagerPath,
        [string]$MmFile,
        [string]$SmFile
    )

    $versionFile = Join-Path $ManagerPath ".mods_installed.json"
    $data = @{ MetaMod = $MmFile; SourceMod = $SmFile } | ConvertTo-Json
    $data | Set-Content $versionFile -Encoding UTF8
}

function Install-MetaMod {
    param(
        [string]$ServerPath,
        [string]$GameFolder,
        [string]$DownloadUrl
    )

    $gameRoot   = Join-Path $ServerPath $GameFolder
    $addonsPath = Join-Path $gameRoot "addons"
    $mmVdf      = Join-Path $addonsPath "metamod.vdf"
    $tempZip    = Join-Path ([System.IO.Path]::GetTempPath()) "mm-$([guid]::NewGuid()).zip"
    $zip        = $null

    try {
        Write-Log "Downloading MetaMod from $DownloadUrl" "INFO"
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $tempZip -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
        foreach ($entry in $zip.Entries) {
            $dest = Join-Path $gameRoot $entry.FullName
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            } else {
                $parent = Split-Path $dest -Parent
                if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
            }
        }

        $vdfPluginPath = "../$GameFolder/addons/metamod/bin/server"
        $vdfContent = '"Plugin"' + "`n{`n`t" + '"file"' + "`t" + '"' + $vdfPluginPath + '"' + "`n}"
        [System.IO.File]::WriteAllText($mmVdf, $vdfContent, [System.Text.Encoding]::ASCII)

        Write-Log "MetaMod installed to $(Join-Path $addonsPath 'metamod')" "INFO"
        return $true
    }
    catch {
        Write-Log "MetaMod install failed: $_" "ERROR"
        return $false
    }
    finally {
        if ($zip) { try { $zip.Dispose() } catch { } }
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
    }
}

function Install-SourceMod {
    param(
        [string]$ServerPath,
        [string]$GameFolder,
        [string]$DownloadUrl
    )

    $gameRoot   = Join-Path $ServerPath $GameFolder
    $addonsPath = Join-Path $gameRoot "addons"
    $tempZip    = Join-Path ([System.IO.Path]::GetTempPath()) "sm-$([guid]::NewGuid()).zip"
    $zip        = $null

    try {
        Write-Log "Downloading SourceMod from $DownloadUrl" "INFO"
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $tempZip -TimeoutSec 120 -UseBasicParsing -ErrorAction Stop

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
        foreach ($entry in $zip.Entries) {
            $dest = Join-Path $gameRoot $entry.FullName
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            } else {
                $parent = Split-Path $dest -Parent
                if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
            }
        }

        Write-Log "SourceMod installed to $(Join-Path $addonsPath 'sourcemod')" "INFO"
        return $true
    }
    catch {
        Write-Log "SourceMod install failed: $_" "ERROR"
        return $false
    }
    finally {
        if ($zip) { try { $zip.Dispose() } catch { } }
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
    }
}

function Remove-Mods {
    param(
        [string]$ServerPath,
        [string]$GameFolder,
        [string]$ManagerPath
    )

    $gameRoot   = Join-Path $ServerPath $GameFolder
    $addonsPath = Join-Path $gameRoot "addons"

    try {
        $smFolder    = Join-Path $addonsPath "sourcemod"
        $mmFolder    = Join-Path $addonsPath "metamod"
        $mmVdf       = Join-Path $addonsPath "metamod.vdf"
        $smVdf       = Join-Path $mmFolder "sourcemod.vdf"
        $versionFile = Join-Path $ManagerPath ".mods_installed.json"

        if (Test-Path $smFolder)    { Remove-Item $smFolder    -Recurse -Force }
        if (Test-Path $smVdf)       { Remove-Item $smVdf       -Force }
        if (Test-Path $mmFolder)    { Remove-Item $mmFolder    -Recurse -Force }
        if (Test-Path $mmVdf)       { Remove-Item $mmVdf       -Force }
        if (Test-Path $versionFile) { Remove-Item $versionFile -Force }

        Write-Log "Mods removed from $ServerPath" "INFO"
        return $true
    }
    catch {
        Write-Log "Mod removal failed: $_" "ERROR"
        return $false
    }
}

function Invoke-InstallFlow {
    param(
        [object]$Server,
        [string]$GameFolder,
        [string]$MmUrl,
        [string]$SmUrl
    )

    $gamePath    = Join-Path $Server.Path "server"
    $managerPath = Join-Path $Server.Path "manager"

    Write-Host ""
    Write-Host "  MetaMod  : $(Split-Path $MmUrl -Leaf)" -ForegroundColor DarkGray
    Write-Host "  SourceMod: $(Split-Path $SmUrl -Leaf)" -ForegroundColor DarkGray
    Write-Host ""

    $confirm = Read-Host (Get-Message -Key "Common_ConfirmPrompt")
    if ($confirm -ne (Get-Message -Key "ConfirmYes")) { return }

    Write-Host "`n$(Get-Message -Key 'Mod_InstallingMM')" -ForegroundColor Cyan
    $mmOk = Install-MetaMod -ServerPath $gamePath -GameFolder $GameFolder -DownloadUrl $MmUrl
    if (-not $mmOk) {
        Write-Host "`n$(Get-Message -Key 'Mod_InstallFailed')`n" -ForegroundColor Red
        Read-Host (Get-Message -Key "Common_PressEnter")
        return
    }
    Write-Host "$(Get-Message -Key 'Mod_MMDone')" -ForegroundColor Green

    Write-Host "`n$(Get-Message -Key 'Mod_InstallingSM')" -ForegroundColor Cyan
    $smOk = Install-SourceMod -ServerPath $gamePath -GameFolder $GameFolder -DownloadUrl $SmUrl
    if (-not $smOk) {
        Write-Host "`n$(Get-Message -Key 'Mod_InstallFailed')`n" -ForegroundColor Red
        Read-Host (Get-Message -Key "Common_PressEnter")
        return
    }
    Write-Host "$(Get-Message -Key 'Mod_SMDone')" -ForegroundColor Green

    Save-ModVersions -ManagerPath $managerPath `
        -MmFile (Split-Path $MmUrl -Leaf) -SmFile (Split-Path $SmUrl -Leaf)

    Write-Host "`n$(Get-Message -Key 'Mod_InstallComplete')" -ForegroundColor Green
    Write-Host ""

    $runningFile = Join-Path $managerPath ".running"
    $serverRunning = $false
    $runningData = $null
    if (Test-Path $runningFile) {
        try {
            $runningData = Get-Content $runningFile -Raw | ConvertFrom-Json
            $pidToCheck = if ($runningData.ServerProcessId) { [int]$runningData.ServerProcessId } else { 0 }
            if ($pidToCheck -gt 0 -and (Get-Process -Id $pidToCheck -ErrorAction SilentlyContinue)) {
                $serverRunning = $true
            }
        } catch { }
    }

    if ($serverRunning) {
        Write-Host (Get-Message -Key "Mod_RestartRequired") -ForegroundColor Yellow
        $restartChoice = Read-Host (Get-Message -Key "Mod_RestartNow")
        if ($restartChoice -eq (Get-Message -Key "ConfirmYes")) {
            if ($runningData.ServerProcessId) {
                Stop-Process -Id $runningData.ServerProcessId -Force -ErrorAction SilentlyContinue
            }
            if ($runningData.PowerShellPID) {
                Stop-Process -Id $runningData.PowerShellPID -Force -ErrorAction SilentlyContinue
            }
            Remove-Item $runningFile -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2

            $fresh = @(Get-ServerRegistry) | Where-Object { $_.ServerId -eq $Server.ServerId } | Select-Object -First 1
            if ($fresh -and $fresh.ConfiguredMap -and $fresh.ConfiguredGameMode) {
                $port = if ($fresh.FirewallPort) { [int]$fresh.FirewallPort } else { 27016 }
                $newPid = Start-ServerNormal -InstallPath $gamePath -GameMode $fresh.ConfiguredGameMode -Map $fresh.ConfiguredMap -Port $port
                if ($newPid -gt 0) {
                    @{
                        ServerPath      = $Server.Path
                        ServerName      = $Server.Name
                        ServerProcessId = $newPid
                        StartedAt       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    } | ConvertTo-Json | Set-Content $runningFile -Encoding UTF8
                    Write-Host (Get-Message -Key "Mod_RestartDone") -ForegroundColor Green
                } else {
                    Write-Host (Get-Message -Key "Mod_RestartFailed") -ForegroundColor Red
                }
            } else {
                Write-Host (Get-Message -Key "Start_NotConfigured") -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host (Get-Message -Key "Mod_RestartNotRunning") -ForegroundColor DarkGray
    }

    Write-Host ""
    Read-Host (Get-Message -Key "Common_PressEnter")
}

function Show-ModMenu {
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

    while ($true) {
        $status  = Get-ModStatus -ServerPath $gamePath -GameFolder $gameFolder -ManagerPath $managerPath
        $hasMods = $status.MetaMod -or $status.SourceMod

        $mmSymbol = if ($status.MetaMod)   { "[OK]" } else { "[--]" }
        $mmColor  = if ($status.MetaMod)   { "Green" } else { "Red" }
        $mmLabel  = if ($status.MetaMod -and $status.MetaModVersion) {
            "$(Get-Message -Key 'Mod_Installed') v$($status.MetaModVersion)"
        } elseif ($status.MetaMod) {
            Get-Message -Key "Mod_Installed"
        } else {
            Get-Message -Key "Mod_NotInstalled"
        }

        $smSymbol = if ($status.SourceMod) { "[OK]" } else { "[--]" }
        $smColor  = if ($status.SourceMod) { "Green" } else { "Red" }
        $smLabel  = if ($status.SourceMod -and $status.SourceModVersion) {
            "$(Get-Message -Key 'Mod_Installed') v$($status.SourceModVersion)"
        } elseif ($status.SourceMod) {
            Get-Message -Key "Mod_Installed"
        } else {
            Get-Message -Key "Mod_NotInstalled"
        }

        Write-Host ""
        Write-Host "  $(Get-Message -Key 'Mod_TitleLabel'): $($Server.Name)" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  MetaMod:Source : $mmSymbol $mmLabel" -ForegroundColor $mmColor
        Write-Host "  SourceMod      : $smSymbol $smLabel" -ForegroundColor $smColor
        Write-Host ""
        Write-Host "  1) $(Get-Message -Key 'Mod_InstallRecommended')"
        Write-Host "  2) $(Get-Message -Key 'Mod_InstallCustom')"
        if ($hasMods) {
            Write-Host "  3) $(Get-Message -Key 'Mod_Remove')" -ForegroundColor Yellow
        } else {
            Write-Host "  3) $(Get-Message -Key 'Mod_Remove')" -ForegroundColor DarkGray
        }
        Write-Host "  4) $(Get-Message -Key 'Mod_Verify')"
        Write-Host "  5) $(Get-Message -Key 'Manage_Admins')"
        Write-Host "  0) $(Get-Message -Key 'Manage_Back')`n"

        $choice = Read-Host (Get-Message -Key "Common_Select")

        switch ($choice) {
            "1" {
                Write-Host "`n$(Get-Message -Key 'Mod_FetchingLatest')" -ForegroundColor Cyan
                Write-Host "  $(Get-Message -Key 'Mod_FetchingMM')..."
                $mmUrls = Get-ModDownloadUrls -PageUrl $modConfig.MetaMod.DownloadPage
                Write-Host "  $(Get-Message -Key 'Mod_FetchingSM')..."
                $smUrls = Get-ModDownloadUrls -PageUrl $modConfig.SourceMod.DownloadPage

                if (-not $mmUrls -or $mmUrls.Count -eq 0 -or -not $smUrls -or $smUrls.Count -eq 0) {
                    Write-Host "`n$(Get-Message -Key 'Mod_FetchFailed')`n" -ForegroundColor Red
                    Read-Host (Get-Message -Key "Common_PressEnter")
                } else {
                    Invoke-InstallFlow -Server $Server -GameFolder $gameFolder -MmUrl $mmUrls[0] -SmUrl $smUrls[0]
                }
            }
            "2" {
                Write-Host "`n$(Get-Message -Key 'Mod_FetchingVersions')" -ForegroundColor Cyan
                $mmUrls = Get-ModDownloadUrls -PageUrl $modConfig.MetaMod.DownloadPage -MaxResults 5
                $smUrls = Get-ModDownloadUrls -PageUrl $modConfig.SourceMod.DownloadPage -MaxResults 5

                if (-not $mmUrls -or $mmUrls.Count -eq 0 -or -not $smUrls -or $smUrls.Count -eq 0) {
                    Write-Host "`n$(Get-Message -Key 'Mod_FetchFailed')`n" -ForegroundColor Red
                    Read-Host (Get-Message -Key "Common_PressEnter")
                } else {
                    Write-Host "`n$(Get-Message -Key 'Mod_SelectMM')`n"
                    for ($i = 0; $i -lt $mmUrls.Count; $i++) {
                        Write-Host "  $($i+1)) $(Split-Path $mmUrls[$i] -Leaf)"
                    }
                    Write-Host "  0) $(Get-Message -Key 'Common_Cancel')`n"
                    $mmSel = Read-Host (Get-Message -Key "Common_Select")

                    if ($mmSel -ne "0" -and -not [string]::IsNullOrWhiteSpace($mmSel)) {
                        $mmIdx = [int]$mmSel - 1
                        if ($mmIdx -ge 0 -and $mmIdx -lt $mmUrls.Count) {

                            Write-Host "`n$(Get-Message -Key 'Mod_SelectSM')`n"
                            for ($i = 0; $i -lt $smUrls.Count; $i++) {
                                Write-Host "  $($i+1)) $(Split-Path $smUrls[$i] -Leaf)"
                            }
                            Write-Host "  0) $(Get-Message -Key 'Common_Cancel')`n"
                            $smSel = Read-Host (Get-Message -Key "Common_Select")

                            if ($smSel -ne "0" -and -not [string]::IsNullOrWhiteSpace($smSel)) {
                                $smIdx = [int]$smSel - 1
                                if ($smIdx -ge 0 -and $smIdx -lt $smUrls.Count) {
                                    Invoke-InstallFlow -Server $Server -GameFolder $gameFolder `
                                        -MmUrl $mmUrls[$mmIdx] -SmUrl $smUrls[$smIdx]
                                }
                            }
                        }
                    }
                }
            }
            "3" {
                if ($hasMods) {
                    $confirm = Read-Host (Get-Message -Key "Common_ConfirmPrompt")
                    if ($confirm -eq (Get-Message -Key "ConfirmYes")) {
                        $result = Remove-Mods -ServerPath $gamePath -GameFolder $gameFolder -ManagerPath $managerPath
                        if ($result) {
                            Write-Host "`n$(Get-Message -Key 'Mod_RemoveDone')`n" -ForegroundColor Green
                        } else {
                            Write-Host "`n$(Get-Message -Key 'Mod_RemoveFailed')`n" -ForegroundColor Red
                        }
                        Read-Host (Get-Message -Key "Common_PressEnter")
                    }
                }
            }
            "4" {
                Write-Host ""
                $mmResp = Invoke-ServerRcon -Server $Server -Command "meta version"
                $smResp = Invoke-ServerRcon -Server $Server -Command "sm version"

                if ($null -eq $mmResp -and $null -eq $smResp) {
                    Write-Host (Get-Message -Key "Mod_VerifyNoRcon") -ForegroundColor Yellow
                } else {
                    Write-Host (Get-Message -Key "Mod_VerifyNote2") -ForegroundColor DarkGray
                    Write-Host ""

                    if ($null -ne $mmResp -and $mmResp -match "Metamod") {
                        Write-Host (Get-Message -Key "Mod_VerifyMMOk") -ForegroundColor Green
                    } else {
                        Write-Host (Get-Message -Key "Mod_VerifyMMFail") -ForegroundColor Red
                    }

                    if ($null -ne $smResp -and $smResp -match "SourceMod") {
                        Write-Host (Get-Message -Key "Mod_VerifySMOk") -ForegroundColor Green
                    } else {
                        Write-Host (Get-Message -Key "Mod_VerifySMFail") -ForegroundColor Red
                    }

                    if ($null -ne $mmResp) {
                        Write-Host ""
                        Write-Host "  meta version:" -ForegroundColor DarkGray
                        Write-Host $mmResp -ForegroundColor DarkGray
                    }
                    if ($null -ne $smResp) {
                        Write-Host ""
                        Write-Host "  sm version:" -ForegroundColor DarkGray
                        Write-Host $smResp -ForegroundColor DarkGray
                    }
                }
                Write-Host ""
                Read-Host (Get-Message -Key "Common_PressEnter")
            }
            "5" {
                Show-AdminMenu -Server $Server -RootPath $RootPath
            }
            "0" { return }
            default {
                Write-Host "`n$(Get-Message -Key 'Common_InvalidOption')`n" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

Export-ModuleMember -Function Get-ModStatus, Install-MetaMod, Install-SourceMod, Remove-Mods, Show-ModMenu
