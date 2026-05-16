function Start-ServerWithMonitoring {
    param(
        [string]$InstallPath,
        [string]$ManagerPath,
        [string]$GameMode,
        [string]$Map,
        [int]$Port = 27015
    )

    $srcdsPath = Join-Path $InstallPath "srcds.exe"

    if (-not (Test-Path $srcdsPath)) {
        Write-Log "srcds.exe not found at: $srcdsPath" "ERROR"
        return $false
    }

    $cmdArgs = @(
        "-console",
        "-game left4dead2",
        "-server",
        "-nohltv",
        "+sv_lan 0",
        "+sv_pure 1",
        "+exec server.cfg",
        "+map $Map"
    )

    if ($GameMode) {
        $cmdArgs += "+mp_gamemode $GameMode"
    }

    if ($Port -gt 0) {
        $cmdArgs += "-port $Port"
    }

    $argString = $cmdArgs -join " "

    Write-Log "Starting server monitoring: $srcdsPath" "INFO"

    $crashCount = 0
    $maxCrashes = 100

    while ($crashCount -lt $maxCrashes) {
        try {
            $process = Start-Process -FilePath $srcdsPath `
                -ArgumentList $argString `
                -WorkingDirectory $InstallPath `
                -PassThru `
                -WindowStyle Hidden

            Write-Log "Server process started with PID: $($process.Id)" "INFO"

            $runningFile = Join-Path $ManagerPath ".running"
            if (Test-Path $runningFile) {
                $runningData = Get-Content $runningFile -Raw | ConvertFrom-Json
                $runningData | Add-Member -NotePropertyName ServerProcessId -NotePropertyValue $process.Id -Force
                $runningData | ConvertTo-Json | Set-Content $runningFile -Encoding UTF8
            }

            $process.WaitForExit()

            $exitCode = $process.ExitCode
            $crashCount++

            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Write-Log "Server crashed with exit code $exitCode (Crash #$crashCount) at $timestamp" "WARNING"

            Write-Host "`n[!] Server crashed. Restarting in 5 seconds... (Crash #$crashCount)`n" -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
        catch {
            Write-Log "Error starting server: $_" "ERROR"
            return $false
        }
    }

    Write-Log "Server monitoring stopped after $crashCount crashes (max reached)" "WARNING"
    return $false
}

function Start-ServerNormal {
    param(
        [string]$InstallPath,
        [string]$GameMode,
        [string]$Map,
        [int]$Port = 27015
    )

    $srcdsPath = Join-Path $InstallPath "srcds.exe"

    if (-not (Test-Path $srcdsPath)) {
        Write-Log "srcds.exe not found at: $srcdsPath" "ERROR"
        return $false
    }

    $cmdArgs = @(
        "-console",
        "-game left4dead2",
        "-server",
        "-nohltv",
        "+sv_lan 0",
        "+sv_pure 1",
        "+exec server.cfg",
        "+map $Map"
    )

    if ($GameMode) {
        $cmdArgs += "+mp_gamemode $GameMode"
    }

    if ($Port -gt 0) {
        $cmdArgs += "-port $Port"
    }

    $argString = $cmdArgs -join " "

    Write-Log "Starting server (no monitoring): $srcdsPath" "INFO"

    try {
        $process = Start-Process -FilePath $srcdsPath `
            -ArgumentList $argString `
            -WorkingDirectory $InstallPath `
            -WindowStyle Hidden `
            -PassThru

        Write-Log "Server process started with PID: $($process.Id)" "INFO"
        return $process.Id
    }
    catch {
        Write-Log "Error starting server: $_" "ERROR"
        return $false
    }
}

Export-ModuleMember -Function Start-ServerWithMonitoring, Start-ServerNormal
