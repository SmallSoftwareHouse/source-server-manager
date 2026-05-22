function Start-ServerWithMonitoring {
    param(
        [string]$InstallPath,
        [string]$ManagerPath,
        [string]$ArgString
    )

    $srcdsPath = Join-Path $InstallPath "srcds.exe"

    if (-not (Test-Path $srcdsPath)) {
        Write-Log "srcds.exe not found at: $srcdsPath" "ERROR"
        return $false
    }

    Write-Log "Starting server monitoring: $srcdsPath" "INFO"
    Write-Log "Launch args: $ArgString" "INFO"

    $crashCount = 0
    $maxCrashes = 100

    while ($crashCount -lt $maxCrashes) {
        try {
            $process = Start-Process -FilePath $srcdsPath `
                -ArgumentList $ArgString `
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
        [string]$ArgString
    )

    $srcdsPath = Join-Path $InstallPath "srcds.exe"

    if (-not (Test-Path $srcdsPath)) {
        Write-Log "srcds.exe not found at: $srcdsPath" "ERROR"
        return $false
    }

    Write-Log "Starting server (no monitoring): $srcdsPath" "INFO"
    Write-Log "Launch args: $ArgString" "INFO"

    try {
        $process = Start-Process -FilePath $srcdsPath `
            -ArgumentList $ArgString `
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

function Get-ServerConsoleInfo {
    # Reads console.log to determine last connection type and public IP.
    # Returns hashtable: PublicIP, LastConnectionType ("matchmaking" | "direct" | $null)
    param(
        [string]$ServerPath,
        [string]$GameFolder = "left4dead2"
    )

    $result = @{
        PublicIP           = $null
        LastConnectionType = $null
    }

    $consolePath = Join-Path $ServerPath "server\$GameFolder\console.log"
    if (-not (Test-Path $consolePath)) { return $result }

    $lines = Get-Content $consolePath -Tail 200 -ErrorAction SilentlyContinue
    if (-not $lines -or $lines.Count -eq 0) { return $result }

    # Extract public IP from the most recent udp/ip line (written after Steam connects)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match 'udp/ip\s*:.*\[\s*public\s+(\d+\.\d+\.\d+\.\d+):\d+') {
            $result.PublicIP = $Matches[1]
            break
        }
    }

    # Find index of last Client connected line
    $clientIdx = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match '^Client ".*" connected') {
            $clientIdx = $i
            break
        }
    }

    if ($clientIdx -lt 0) { return $result }

    # Find last "Server is hibernating" BEFORE the client connection
    $hibernateIdx = -1
    for ($i = $clientIdx - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match 'Server is hibernating') {
            $hibernateIdx = $i
            break
        }
    }

    # Search for real reservation cookie between hibernate and client connect
    $searchFrom = if ($hibernateIdx -ge 0) { $hibernateIdx } else { 0 }
    $foundReservation = $false
    for ($i = $searchFrom; $i -lt $clientIdx; $i++) {
        if ($lines[$i] -match '-> Reservation cookie [0-9a-f]+:\s+reason ReplyReservationRequest') {
            $foundReservation = $true
            break
        }
    }

    $result.LastConnectionType = if ($foundReservation) { "matchmaking" } else { "direct" }
    return $result
}

Export-ModuleMember -Function Start-ServerWithMonitoring, Start-ServerNormal, Get-ServerConsoleInfo
