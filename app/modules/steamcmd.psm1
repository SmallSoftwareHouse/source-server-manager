function Install-SteamCMD {
    param(
        [string]$Path
    )

    $steamCmdExe = Join-Path $Path "steamcmd.exe"

    if (Test-Path $steamCmdExe) {
        return $steamCmdExe
    }

    $steamCmdZip = Join-Path $Path "steamcmd.zip"

    Write-Host (Get-Message -Key "Steam_Downloading")

    try {
        Invoke-WebRequest `
            -Uri "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip" `
            -OutFile $steamCmdZip `
            -UseBasicParsing `
            -ErrorAction Stop
    }
    catch {
        throw (Get-Message -Key "Steam_DownloadFailed" -MsgArgs @($_))
    }

    if (-not (Test-Path $steamCmdZip)) {
        throw (Get-Message -Key "Steam_ZipNotFound" -MsgArgs @($steamCmdZip))
    }

    Write-Host (Get-Message -Key "Steam_Extracting")

    try {
        Expand-Archive -Path $steamCmdZip -DestinationPath $Path -Force -ErrorAction Stop
    }
    catch {
        throw (Get-Message -Key "Steam_ExtractFailed" -MsgArgs @($_))
    }

    Remove-Item $steamCmdZip -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $steamCmdExe)) {
        throw (Get-Message -Key "Steam_ExeNotFound" -MsgArgs @($Path))
    }

    Write-Host (Get-Message -Key "Steam_Ready")
    return $steamCmdExe
}

function Install-GameServer {
    param(
        [string]$SteamCmdPath,
        [string]$AppId,
        [string]$InstallDir,
        [string]$SteamCmdDir,
        [string]$ScriptId = "default"
    )

    Write-Host (Get-Message -Key "Steam_InstallingL4D2")
    Write-Host (Get-Message -Key "Steam_Destination" -MsgArgs @($InstallDir))

    # Unique script per server to allow parallel installs
    $scriptPath = Join-Path $SteamCmdDir "install_script_$ScriptId.txt"

    $commands = @(
        "force_install_dir `"$InstallDir`"",
        "login anonymous",
        "app_update $AppId validate",
        "quit"
    )

    try {
        $commands | Set-Content -Path $scriptPath -Encoding ASCII -ErrorAction Stop
    }
    catch {
        throw (Get-Message -Key "Steam_ScriptFailed" -MsgArgs @($_))
    }

    Write-Host (Get-Message -Key "Steam_Launching")

    try {
        $process = Start-Process `
            -FilePath $SteamCmdPath `
            -ArgumentList "+runscript `"$scriptPath`"" `
            -Wait `
            -NoNewWindow `
            -PassThru `
            -ErrorAction Stop

        if ($process.ExitCode -ne 0) {
            throw (Get-Message -Key "Steam_ExitCode" -MsgArgs @($process.ExitCode))
        }
    }
    catch {
        throw (Get-Message -Key "Steam_ExecFailed" -MsgArgs @($_))
    }

    Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue
    Write-Host (Get-Message -Key "Steam_InstallComplete")
}

Export-ModuleMember -Function Install-SteamCMD, Install-GameServer
