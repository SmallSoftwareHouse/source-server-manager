function Send-RconPacket {
    param($stream, $id, $type, $body)
    $bodyBytes = [System.Text.Encoding]::ASCII.GetBytes($body) + [byte]0
    $size = 4 + 4 + $bodyBytes.Length + 1
    $packet = New-Object byte[] (4 + $size)
    [BitConverter]::GetBytes([int32]$size).CopyTo($packet, 0)
    [BitConverter]::GetBytes([int32]$id).CopyTo($packet, 4)
    [BitConverter]::GetBytes([int32]$type).CopyTo($packet, 8)
    $bodyBytes.CopyTo($packet, 12)
    $packet[$packet.Length - 1] = 0
    $stream.Write($packet, 0, $packet.Length)
}

function Read-RconPacket {
    param($stream)
    $buf = New-Object byte[] 4
    $n = $stream.Read($buf, 0, 4)
    if ($n -lt 4) { return $null }
    $size = [BitConverter]::ToInt32($buf, 0)
    if ($size -le 0 -or $size -gt 16384) { return $null }
    $data = New-Object byte[] $size
    $read = 0
    while ($read -lt $size) {
        $r = $stream.Read($data, $read, $size - $read)
        if ($r -le 0) { break }
        $read += $r
    }
    $id      = [BitConverter]::ToInt32($data, 0)
    $type    = [BitConverter]::ToInt32($data, 4)
    $bodyLen = $size - 10
    $body    = if ($bodyLen -gt 0) { [System.Text.Encoding]::ASCII.GetString($data, 8, $bodyLen) } else { "" }
    return @{ Id = $id; Type = $type; Body = $body.Trim("`0").Trim() }
}

function Find-RconAddress {
    param(
        [int]$Port = 27015,
        [int]$ServerPid = 0
    )

    if ($ServerPid -gt 0) {
        $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -OwningProcess $ServerPid `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn) {
            $addr = $conn.LocalAddress
            if ($addr -eq "0.0.0.0" -or $addr -eq "::") { return "127.0.0.1" }
            return $addr
        }
    }

    $conn = Get-NetTCPConnection -State Listen -LocalPort $Port `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) {
        $addr = $conn.LocalAddress
        if ($addr -eq "0.0.0.0" -or $addr -eq "::") { return "127.0.0.1" }
        return $addr
    }

    return $null
}

function Invoke-RconCommand {
    param(
        [string]$Address,
        [int]$Port = 27015,
        [string]$Password,
        [string]$Command,
        [int]$TimeoutMs = 3000
    )

    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($Address, $Port)
        $stream = $tcp.GetStream()
        $stream.ReadTimeout  = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs

        Send-RconPacket $stream 1 3 $Password
        $r1 = Read-RconPacket $stream
        $r2 = Read-RconPacket $stream

        $authOk = ($r2 -and $r2.Id -ne -1) -or ($r1 -and $r1.Id -ne -1 -and $r1.Type -eq 2)
        if (-not $authOk) { return $null }

        Send-RconPacket $stream 2 2 $Command
        Start-Sleep -Milliseconds 300
        $resp = Read-RconPacket $stream
        if ($resp) { return $resp.Body } else { return "" }
    }
    catch {
        Write-Log "RCON command error: $($_.Exception.Message)" "WARNING"
        return $null
    }
    finally { if ($tcp) { $tcp.Close() } }
}

function Invoke-ServerRcon {
    param(
        [object]$Server,
        [string]$Command
    )

    $managerPath = Join-Path $Server.Path "manager"
    $configFile  = Join-Path $managerPath "config.json"
    if (-not (Test-Path $configFile)) { return $null }

    try { $cfg = Get-Content $configFile -Raw | ConvertFrom-Json } catch { return $null }
    if ([string]::IsNullOrWhiteSpace($cfg.RconPassword)) { return $null }

    $port = if ($Server.FirewallPort) { [int]$Server.FirewallPort } else { 27015 }

    $serverPid = 0
    $runningFile = Join-Path $managerPath ".running"
    if (Test-Path $runningFile) {
        try {
            $rd = Get-Content $runningFile -Raw | ConvertFrom-Json
            if ($rd.ServerProcessId) { $serverPid = [int]$rd.ServerProcessId }
        } catch { }
    }

    $address = Find-RconAddress -Port $port -ServerPid $serverPid
    if (-not $address) { return $null }

    return Invoke-RconCommand -Address $address -Port $port -Password $cfg.RconPassword -Command $Command
}

function Test-RconConnectivity {
    param([object]$Server)
    $result = Invoke-ServerRcon -Server $Server -Command "status"
    return ($null -ne $result)
}

Export-ModuleMember -Function Find-RconAddress, Invoke-RconCommand, Invoke-ServerRcon, Test-RconConnectivity
