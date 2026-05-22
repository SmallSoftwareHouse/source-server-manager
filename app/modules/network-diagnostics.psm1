# network-diagnostics.psm1
# 5-level network diagnostic module

# -------------------------------------------------------
# Private helpers
# -------------------------------------------------------

function Get-ExternalIP {
    # Self-contained public IP lookup (does not depend on network.psm1)
    try {
        $ip = (Invoke-WebRequest -Uri "https://api.ipify.org?format=json" `
                -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop | ConvertFrom-Json).ip
        return $ip
    } catch {
        return $null
    }
}

function Test-TcpConnectWithTimeout {
    param(
        [string]$IP,
        [int]$Port,
        [int]$TimeoutMs = 2000
    )
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $ar     = $tcp.BeginConnect($IP, $Port, $null, $null)
        $waited = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($waited) {
            try { $tcp.EndConnect($ar) } catch { return $false }
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        try { $tcp.Close() } catch {}
    }
}

function Test-SourceQueryReachable {
    # Sends an A2S_INFO UDP query and waits for response
    param(
        [string]$IP,
        [int]$Port,
        [int]$TimeoutMs = 3000
    )
    # A2S_INFO query bytes
    $query = [byte[]](0xFF, 0xFF, 0xFF, 0xFF, 0x54,
                      0x53, 0x6F, 0x75, 0x72, 0x63, 0x65, 0x20,
                      0x45, 0x6E, 0x67, 0x69, 0x6E, 0x65, 0x20,
                      0x51, 0x75, 0x65, 0x72, 0x79, 0x00)
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($IP, $Port)
        $udp.Send($query, $query.Length) | Out-Null
        $ep       = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $response = $udp.Receive([ref]$ep)
        return ($response.Length -gt 4 -and $response[0] -eq 0xFF -and $response[1] -eq 0xFF)
    } catch {
        return $false
    } finally {
        try { $udp.Close() } catch {}
    }
}

# -------------------------------------------------------
# Level 1 - Network interfaces
# -------------------------------------------------------

function Get-NetworkInterfaces {
    $result = @()

    $defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
                    Sort-Object RouteMetric | Select-Object -First 1
    $primaryIdx = if ($defaultRoute) { $defaultRoute.InterfaceIndex } else { -1 }

    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
    foreach ($adapter in $adapters) {
        $ipInfo = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex `
                    -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                  Where-Object { $_.IPAddress -notlike "169.254.*" } |
                  Select-Object -First 1
        if (-not $ipInfo) { continue }

        $desc = $adapter.InterfaceDescription
        $adapterType = "Physical"
        if ($desc -match "VirtualBox|VMware|Hyper-V|Virtual|vEthernet") { $adapterType = "Virtual" }
        if ($adapter.Name -match "^Loopback" -or $desc -match "Loopback") { $adapterType = "Loopback" }

        $result += [PSCustomObject]@{
            Name      = $adapter.Name
            IP        = $ipInfo.IPAddress
            Type      = $adapterType
            IsPrimary = ($adapter.InterfaceIndex -eq $primaryIdx)
        }
    }
    return $result
}

# -------------------------------------------------------
# Level 2 - Routing
# -------------------------------------------------------

function Get-NetworkRouting {
    $defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
                    Sort-Object RouteMetric | Select-Object -First 1
    return [PSCustomObject]@{
        DefaultGateway = if ($defaultRoute) { $defaultRoute.NextHop } else { $null }
        InterfaceIndex = if ($defaultRoute) { $defaultRoute.InterfaceIndex } else { $null }
    }
}

# -------------------------------------------------------
# Level 3 - Loopback filtering
# -------------------------------------------------------

function Test-LoopbackFiltering {
    param([string]$LocalIP)

    $result = [PSCustomObject]@{
        LoopbackFilteringDetected = $null
        ViaLocalhost = $null
        ViaLanIP     = $null
        TestPort     = 0
        Error        = $null
    }

    if ([string]::IsNullOrWhiteSpace($LocalIP)) {
        $result.Error = "No local IP available"
        return $result
    }

    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, 0)
        $listener.Start()
        $result.TestPort = $listener.LocalEndpoint.Port

        # Test via 127.0.0.1 (should always work)
        $result.ViaLocalhost = Test-TcpConnectWithTimeout -IP "127.0.0.1" -Port $result.TestPort -TimeoutMs 1500
        if ($listener.Pending()) { $listener.AcceptTcpClient().Close() }

        # Test via real LAN IP (blocked if loopback filtering is active)
        $result.ViaLanIP = Test-TcpConnectWithTimeout -IP $LocalIP -Port $result.TestPort -TimeoutMs 2000
        if ($listener.Pending()) { $listener.AcceptTcpClient().Close() }

        $result.LoopbackFilteringDetected = ($result.ViaLocalhost -and (-not $result.ViaLanIP))

    } catch {
        $result.Error = $_.Exception.Message
    } finally {
        if ($listener) { try { $listener.Stop() } catch {} }
    }

    return $result
}

# -------------------------------------------------------
# Level 4 - NAT loopback (hairpin NAT)
# -------------------------------------------------------

function Test-NatLoopback {
    param(
        [string]$PublicIP,
        [int]$Port,
        [int]$TimeoutMs = 3000
    )

    $result = [PSCustomObject]@{
        NatLoopbackSupported = $null
        Method   = $null
        PublicIP = $PublicIP
        Port     = $Port
        Error    = $null
    }

    if ([string]::IsNullOrWhiteSpace($PublicIP)) {
        $result.Error = "Public IP not available"
        $result.NatLoopbackSupported = $false
        return $result
    }

    # Try UDP Source query first (most accurate — uses the actual game protocol)
    $udpOk = Test-SourceQueryReachable -IP $PublicIP -Port $Port -TimeoutMs $TimeoutMs
    if ($udpOk) {
        $result.Method = "UDP"
        $result.NatLoopbackSupported = $true
        return $result
    }

    # Fallback: TCP connect (RCON port)
    $tcpOk = Test-TcpConnectWithTimeout -IP $PublicIP -Port $Port -TimeoutMs $TimeoutMs
    $result.Method = "TCP"
    $result.NatLoopbackSupported = $tcpOk
    return $result
}

# -------------------------------------------------------
# Orchestrator - displays full report
# -------------------------------------------------------

function Wait-ServerReady {
    param(
        [string]$IP,
        [int]$Port,
        [int]$MaxSeconds = 60,
        [int]$PollSeconds = 2
    )
    $elapsed = 0
    while ($elapsed -lt $MaxSeconds) {
        if (Test-SourceQueryReachable -IP $IP -Port $Port -TimeoutMs 1000) { return $true }
        Write-Host "." -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds $PollSeconds
        $elapsed += $PollSeconds
    }
    return $false
}

function Invoke-NetworkDiagnostics {
    param(
        [object]$Server,
        [bool]$IsRunning = $false
    )

    $managerPath = Join-Path $Server.Path "manager"
    $meta = Get-GameMetadata -Game $Server.Game
    $cfg  = Get-ServerManagerConfig -ManagerPath $managerPath
    $port = [int](Resolve-ServerParam -ManagerConfig $cfg -Field "Port" `
                  -MetadataDefault ($meta.DefaultGamePort) -HardcodedDefault 27016)

    # Collect all data first (show loading indicator)
    $collectRow = [Console]::CursorTop
    Write-Host "  $(Get-Message -Key 'NetDiag_Collecting')..." -ForegroundColor DarkGray

    $interfaces     = Get-NetworkInterfaces
    $routing        = Get-NetworkRouting
    $primaryIface   = $interfaces | Where-Object { $_.IsPrimary } | Select-Object -First 1
    $localIP        = if ($primaryIface) { $primaryIface.IP } else { "" }
    $publicIP       = Get-ExternalIP
    $loopbackResult = Test-LoopbackFiltering -LocalIP $localIP
    $natResult      = $null
    if ($IsRunning -and $publicIP) {
        $natResult = Test-NatLoopback -PublicIP $publicIP -Port $port
    }

    # Clear loading line
    [Console]::SetCursorPosition(0, $collectRow)
    Write-Host (" " * ([Console]::WindowWidth - 1))
    [Console]::SetCursorPosition(0, $collectRow)

    $divider     = "  " + ("=" * 50)
    $sectionLine = "  " + ("-" * 50)

    Write-Host ""
    Write-Host "  $(Get-Message -Key 'NetDiag_Title')" -ForegroundColor Cyan
    Write-Host $divider -ForegroundColor DarkGray

    # --- [1] Interfaces ---
    Write-Host ""
    Write-Host "  [1] $(Get-Message -Key 'NetDiag_Section_Interfaces')" -ForegroundColor White
    Write-Host $sectionLine -ForegroundColor DarkGray

    if (-not $interfaces -or $interfaces.Count -eq 0) {
        Write-Host "    $(Get-Message -Key 'NetDiag_NoInterfaces')" -ForegroundColor Yellow
    } else {
        # Dynamic column width based on longest name
        $maxNameLen = 10
        foreach ($iface in $interfaces) {
            if ($iface.Name.Length -gt $maxNameLen) { $maxNameLen = $iface.Name.Length }
        }
        foreach ($iface in $interfaces) {
            $typeKey = "NetDiag_Loopback"
            if ($iface.Type -eq "Physical") { $typeKey = "NetDiag_Physical" }
            if ($iface.Type -eq "Virtual")  { $typeKey = "NetDiag_Virtual" }
            $typeLabel  = Get-Message -Key $typeKey
            $primaryTag = if ($iface.IsPrimary) { "  [$(Get-Message -Key 'NetDiag_Primary')]" } else { "" }
            $nameCol    = $iface.Name.PadRight($maxNameLen + 2)
            $ipCol      = $iface.IP.PadRight(16)
            $lineColor  = "White"
            if ($iface.Type -eq "Virtual")  { $lineColor = "DarkGray" }
            if ($iface.IsPrimary)           { $lineColor = "Green" }
            Write-Host "    $nameCol  $ipCol  $typeLabel$primaryTag" -ForegroundColor $lineColor
        }
    }

    # --- [2] Routing ---
    Write-Host ""
    Write-Host "  [2] $(Get-Message -Key 'NetDiag_Section_Routing')" -ForegroundColor White
    Write-Host $sectionLine -ForegroundColor DarkGray

    $gwLabel  = Get-Message -Key "NetDiag_Gateway"
    $lipLabel = Get-Message -Key "NetDiag_LocalIP"
    $pubLabel = Get-Message -Key "NetDiag_PublicIP"
    $colW2    = (@($gwLabel, $lipLabel, $pubLabel) | Measure-Object -Maximum -Property Length).Maximum

    $gwVal  = if ($routing.DefaultGateway) { $routing.DefaultGateway } else { "?" }
    $lipVal = if ($localIP) { $localIP } else { "?" }
    $pubVal = if ($publicIP) { $publicIP } else { Get-Message -Key "NetDiag_PublicIPUnavailable" }
    $pubCol = if ($publicIP) { "White" } else { "Yellow" }

    Write-Host "    $($gwLabel.PadRight($colW2))  : $gwVal"
    Write-Host "    $($lipLabel.PadRight($colW2))  : $lipVal"
    Write-Host "    $($pubLabel.PadRight($colW2))  : " -NoNewline
    Write-Host $pubVal -ForegroundColor $pubCol

    # --- [3] Loopback filtering ---
    Write-Host ""
    Write-Host "  [3] $(Get-Message -Key 'NetDiag_Section_LoopbackFilter')" -ForegroundColor White
    Write-Host $sectionLine -ForegroundColor DarkGray

    if ($loopbackResult.Error) {
        Write-Host "    [!!] $($loopbackResult.Error)" -ForegroundColor Red
    } else {
        $lhLabel  = "$(Get-Message -Key 'NetDiag_ViaLocalhost') (127.0.0.1)"
        $lanLabel = "$(Get-Message -Key 'NetDiag_ViaLanIP') ($localIP)"
        $lfLabel  = Get-Message -Key "NetDiag_LoopbackFilter"
        $colW3    = (@($lhLabel, $lanLabel, $lfLabel) | Measure-Object -Maximum -Property Length).Maximum

        $lhOk  = if ($loopbackResult.ViaLocalhost) { "[OK]" } else { "[!!]" }
        $lhCol = if ($loopbackResult.ViaLocalhost) { "Green" } else { "Red" }
        $lhVal = if ($loopbackResult.ViaLocalhost) { Get-Message -Key "NetDiag_Reachable" } else { Get-Message -Key "NetDiag_Unreachable" }

        $lanOk  = if ($loopbackResult.ViaLanIP) { "[OK]" } else { "[!!]" }
        $lanCol = if ($loopbackResult.ViaLanIP) { "Green" } else { "Yellow" }
        $lanVal = if ($loopbackResult.ViaLanIP) { Get-Message -Key "NetDiag_Reachable" } else { Get-Message -Key "NetDiag_Unreachable" }

        $lfDetected = $loopbackResult.LoopbackFilteringDetected
        $lfOk  = if (-not $lfDetected) { "[OK]" } else { "[!!]" }
        $lfCol = if (-not $lfDetected) { "Green" } else { "Yellow" }
        $lfVal = if ($lfDetected) { Get-Message -Key "NetDiag_LoopbackFilterDetected" } else { Get-Message -Key "NetDiag_LoopbackFilterNone" }

        Write-Host "    $($lhLabel.PadRight($colW3))  : " -NoNewline
        Write-Host "$lhOk $lhVal" -ForegroundColor $lhCol

        Write-Host "    $($lanLabel.PadRight($colW3))  : " -NoNewline
        Write-Host "$lanOk $lanVal" -ForegroundColor $lanCol

        Write-Host "    $($lfLabel.PadRight($colW3))  : " -NoNewline
        Write-Host "$lfOk $lfVal" -ForegroundColor $lfCol

        if ($lfDetected) {
            Write-Host ""
            Write-Host "    $(Get-Message -Key 'NetDiag_LoopbackFilterHint')" -ForegroundColor DarkGray
        }
    }

    # --- [4] NAT loopback ---
    Write-Host ""
    Write-Host "  [4] $(Get-Message -Key 'NetDiag_Section_NatLoopback')" -ForegroundColor White
    Write-Host $sectionLine -ForegroundColor DarkGray

    if (-not $IsRunning) {
        Write-Host "    $(Get-Message -Key 'NetDiag_ServerNotRunning')" -ForegroundColor DarkGray
    } elseif (-not $publicIP) {
        Write-Host "    $(Get-Message -Key 'NetDiag_PublicIPUnavailable')" -ForegroundColor Yellow
    } else {
        $natLabel    = Get-Message -Key "NetDiag_NatLoopback"
        $targetLabel = Get-Message -Key "NetDiag_TestTarget"
        $colW4       = (@($natLabel, $targetLabel) | Measure-Object -Maximum -Property Length).Maximum

        Write-Host "    $($targetLabel.PadRight($colW4))  : $publicIP`:$port"

        if ($natResult) {
            $natOk  = if ($natResult.NatLoopbackSupported) { "[OK]" } else { "[!!]" }
            $natCol = if ($natResult.NatLoopbackSupported) { "Green" } else { "Yellow" }
            $natVal = if ($natResult.NatLoopbackSupported) { Get-Message -Key "NetDiag_NatLoopbackYes" } else { Get-Message -Key "NetDiag_NatLoopbackNo" }
            Write-Host "    $($natLabel.PadRight($colW4))  : " -NoNewline
            Write-Host "$natOk $natVal" -ForegroundColor $natCol

            if (-not $natResult.NatLoopbackSupported) {
                Write-Host ""
                Write-Host "    $(Get-Message -Key 'NetDiag_NatLoopbackHint')" -ForegroundColor DarkGray
            }
        }
    }

    # --- [5] Connection commands ---
    Write-Host ""
    Write-Host "  [5] $(Get-Message -Key 'NetDiag_Section_ConnectCmds')" -ForegroundColor White
    Write-Host $sectionLine -ForegroundColor DarkGray

    if (-not $IsRunning) {
        Write-Host "    $(Get-Message -Key 'NetDiag_ServerNotRunning')" -ForegroundColor DarkGray
    } else {
        $lanLabel = Get-Message -Key "NetDiag_ConnectFromLan"
        $extLabel = Get-Message -Key "NetDiag_ConnectFromExt"
        $colW5    = (@($lanLabel, $extLabel) | Measure-Object -Maximum -Property Length).Maximum

        # Open server block (via matchmaking lobby)
        Write-Host ""
        Write-Host "    [$(Get-Message -Key 'NetDiag_ConnectOpen')]" -ForegroundColor DarkYellow
        Write-Host ""
        Write-Host "    $($lanLabel.PadRight($colW5))  :  " -NoNewline
        Write-Host "mm_dedicated_force_servers `"$localIP`:$port`"" -ForegroundColor Cyan
        if ($publicIP) {
            Write-Host "    $($extLabel.PadRight($colW5))  :  " -NoNewline
            Write-Host "mm_dedicated_force_servers `"$publicIP`:$port`"" -ForegroundColor Cyan
        } else {
            Write-Host "    $($extLabel.PadRight($colW5))  :  " -NoNewline
            Write-Host "$(Get-Message -Key 'NetDiag_ConnectNoPublicIP')" -ForegroundColor DarkGray
        }

        # Closed server block (direct connect only)
        Write-Host ""
        Write-Host "    [$(Get-Message -Key 'NetDiag_ConnectClosed')]" -ForegroundColor DarkYellow
        Write-Host ""
        Write-Host "    $($lanLabel.PadRight($colW5))  :  " -NoNewline
        Write-Host "connect $localIP`:$port" -ForegroundColor Cyan
        if ($publicIP) {
            Write-Host "    $($extLabel.PadRight($colW5))  :  " -NoNewline
            Write-Host "connect $publicIP`:$port" -ForegroundColor Cyan
        } else {
            Write-Host "    $($extLabel.PadRight($colW5))  :  " -NoNewline
            Write-Host "$(Get-Message -Key 'NetDiag_ConnectNoPublicIP')" -ForegroundColor DarkGray
        }
    }

    # --- [6] Windows Firewall ---
    Write-Host ""
    Write-Host "  [6] $(Get-Message -Key 'NetDiag_Section_WinFirewall')" -ForegroundColor White
    Write-Host $sectionLine -ForegroundColor DarkGray

    $fwRuleLabel  = Get-Message -Key "NetDiag_FwRule"
    $fwStatusLabel = Get-Message -Key "NetDiag_FwStatus"
    $colW6 = (@($fwRuleLabel, $fwStatusLabel) | Measure-Object -Maximum -Property Length).Maximum

    try {
        # Check Windows Firewall profile state
        $fwProfiles = Get-NetFirewallProfile -ErrorAction Stop
        $fwEnabled = $fwProfiles | Where-Object { $_.Enabled -eq $true }
        $fwDisabled = $fwProfiles | Where-Object { $_.Enabled -eq $false }

        if ($fwDisabled -and -not $fwEnabled) {
            Write-Host "    $($fwStatusLabel.PadRight($colW6))  : " -NoNewline
            Write-Host "[--] $(Get-Message -Key 'NetDiag_FwDisabled')" -ForegroundColor DarkGray
        } else {
            $profileNames = ($fwEnabled | ForEach-Object { $_.Name }) -join ", "
            Write-Host "    $($fwStatusLabel.PadRight($colW6))  : " -NoNewline
            Write-Host "[OK] $(Get-Message -Key 'NetDiag_FwEnabled') ($profileNames)" -ForegroundColor Green

            # Check for UDP rule on game port
            $udpRules = Get-NetFirewallRule -ErrorAction SilentlyContinue |
                Where-Object { $_.Direction -eq "Inbound" -and $_.Enabled -eq "True" -and $_.Action -eq "Allow" } |
                ForEach-Object {
                    $portFilter = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
                    if ($portFilter -and ($portFilter.Protocol -eq "UDP" -or $portFilter.Protocol -eq "Any") -and
                        ($portFilter.LocalPort -eq $port -or $portFilter.LocalPort -eq "Any")) { $_ }
                } | Select-Object -First 1

            if ($udpRules) {
                Write-Host "    $($fwRuleLabel.PadRight($colW6))  : " -NoNewline
                Write-Host "[OK] $(Get-Message -Key 'NetDiag_FwRuleFound') ($($udpRules.DisplayName))" -ForegroundColor Green
            } else {
                Write-Host "    $($fwRuleLabel.PadRight($colW6))  : " -NoNewline
                Write-Host "[!!] $(Get-Message -Key 'NetDiag_FwRuleNotFound' -MsgArgs @($port))" -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "    [!!] $(Get-Message -Key 'NetDiag_FwError')" -ForegroundColor Yellow
    }

    # --- [7] Server reachability ---
    Write-Host ""
    Write-Host "  [7] $(Get-Message -Key 'NetDiag_Section_Reachability')" -ForegroundColor White
    Write-Host $sectionLine -ForegroundColor DarkGray

    $lanReachLabel = "$(Get-Message -Key 'NetDiag_ReachLan') ($localIP`:$port)"
    $pubReachLabel = "$(Get-Message -Key 'NetDiag_ReachPublic') ($publicIP`:$port)"
    $colW7 = (@($lanReachLabel, $pubReachLabel) | Measure-Object -Maximum -Property Length).Maximum

    if (-not $IsRunning) {
        Write-Host "    $(Get-Message -Key 'NetDiag_ServerNotRunning')" -ForegroundColor DarkGray
    } else {
        # LAN reachability
        $lanReach = Test-SourceQueryReachable -IP $localIP -Port $port -TimeoutMs 2000
        $lanROk  = if ($lanReach) { "[OK]" } else { "[!!]" }
        $lanRCol = if ($lanReach) { "Green" } else { "Red" }
        $lanRVal = if ($lanReach) { Get-Message -Key "NetDiag_Reachable" } else { Get-Message -Key "NetDiag_Unreachable" }
        Write-Host "    $($lanReachLabel.PadRight($colW7))  : " -NoNewline
        Write-Host "$lanROk $lanRVal" -ForegroundColor $lanRCol

        # Public reachability (hairpin / external)
        if ($publicIP) {
            $pubReach = Test-SourceQueryReachable -IP $publicIP -Port $port -TimeoutMs 2000
            $pubROk  = if ($pubReach) { "[OK]" } else { "[!!]" }
            $pubRCol = if ($pubReach) { "Green" } else { "Yellow" }
            $pubRVal = if ($pubReach) { Get-Message -Key "NetDiag_Reachable" } else { Get-Message -Key "NetDiag_Unreachable" }
            Write-Host "    $($pubReachLabel.PadRight($colW7))  : " -NoNewline
            Write-Host "$pubROk $pubRVal" -ForegroundColor $pubRCol
            if (-not $pubReach) {
                Write-Host ""
                Write-Host "    $(Get-Message -Key 'NetDiag_ReachPublicHint')" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "    $(Get-Message -Key 'NetDiag_PublicIPUnavailable')" -ForegroundColor DarkGray
        }
    }

    # --- [8] Port forwarding esterno ---
    Write-Host ""
    Write-Host "  [8] $(Get-Message -Key 'NetDiag_Section_PortForward')" -ForegroundColor White
    Write-Host $sectionLine -ForegroundColor DarkGray
    Write-Host "    $(Get-Message -Key 'NetDiag_PortForwardPlaceholder')" -ForegroundColor DarkGray

    Write-Host ""
    Write-Host $divider -ForegroundColor DarkGray
    Write-Host ""
    Read-Host (Get-Message -Key "Common_PressEnter") | Out-Null
}

Export-ModuleMember -Function Get-NetworkInterfaces, Get-NetworkRouting, Test-LoopbackFiltering, Test-NatLoopback, Wait-ServerReady, Invoke-NetworkDiagnostics, Test-SourceQueryReachable
