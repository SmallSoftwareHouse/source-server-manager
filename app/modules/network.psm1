function Enable-ServerFirewall {
    param(
        [string]$ServerName,
        [int]$Port = 27015
    )

    if ([string]::IsNullOrWhiteSpace($ServerName)) {
        Write-Log "ServerName non puo' essere vuoto" "ERROR"
        return $false
    }

    $ruleName = "L4D2-Server-$ServerName-$Port"

    Write-Log "Abilitazione firewall per server $ServerName sulla porta $Port" "INFO"

    try {
        $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

        if ($existingRule) {
            Write-Log "Regola firewall gia' presente: $ruleName" "WARNING"
            return $true
        }

        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $Port `
            -ErrorAction Stop | Out-Null

        $ruleNameUdp = "$ruleName-UDP"
        New-NetFirewallRule `
            -DisplayName $ruleNameUdp `
            -Direction Inbound `
            -Action Allow `
            -Protocol UDP `
            -LocalPort $Port `
            -ErrorAction Stop | Out-Null

        Write-Log "Regole firewall create: $ruleName (TCP+UDP porta $Port)" "INFO"
        return $true
    }
    catch {
        Write-Log "Errore nella creazione regola firewall: $_" "ERROR"
        return $false
    }
}

function Disable-ServerFirewall {
    param(
        [string]$ServerName,
        [int]$Port = 27015
    )

    if ([string]::IsNullOrWhiteSpace($ServerName)) {
        Write-Log "ServerName non puo' essere vuoto" "ERROR"
        return $false
    }

    $ruleName = "L4D2-Server-$ServerName-$Port"

    Write-Log "Disabilitazione firewall per server $ServerName" "INFO"

    try {
        $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

        if (-not $rule) {
            Write-Log "Regola firewall non trovata: $ruleName" "WARNING"
            return $true
        }

        Remove-NetFirewallRule -DisplayName $ruleName -Confirm:$false -ErrorAction SilentlyContinue

        $ruleNameUdp = "$ruleName-UDP"
        $ruleUdp = Get-NetFirewallRule -DisplayName $ruleNameUdp -ErrorAction SilentlyContinue
        if ($ruleUdp) {
            Remove-NetFirewallRule -DisplayName $ruleNameUdp -Confirm:$false -ErrorAction SilentlyContinue
        }

        Write-Log "Regole firewall rimosse: $ruleName (TCP+UDP)" "INFO"
        return $true
    }
    catch {
        Write-Log "Errore nella rimozione regola firewall: $_" "ERROR"
        return $false
    }
}

function Test-ServerPort {
    param(
        [string]$ComputerName = "localhost",
        [int]$Port = 27015,
        [int]$Timeout = 3000
    )

    Write-Log "Test connessione porta $ComputerName`:$Port" "INFO"

    try {
        $result = Test-NetConnection -ComputerName $ComputerName -Port $Port -WarningAction SilentlyContinue -ErrorAction Stop

        if ($result.TcpTestSucceeded) {
            Write-Log "Porta $Port raggiungibile su $ComputerName" "INFO"
            return $true
        }
        else {
            Write-Log "Porta $Port NON raggiungibile su $ComputerName" "WARNING"
            return $false
        }
    }
    catch {
        Write-Log "Errore nel test della porta: $_" "ERROR"
        return $false
    }
}

function Get-ServerFirewallRule {
    param(
        [string]$ServerName,
        [int]$Port = 0
    )

    if ([string]::IsNullOrWhiteSpace($ServerName)) {
        Write-Log "ServerName non puo' essere vuoto" "ERROR"
        return $null
    }

    Write-Log "Ricerca regole firewall per server $ServerName porta $Port" "INFO"

    try {
        # Search by exact name if port is known, otherwise wildcard
        if ($Port -gt 0) {
            $ruleName = "L4D2-Server-$ServerName-$Port"
            $rules = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        } else {
            $rules = Get-NetFirewallRule -DisplayName "*L4D2-Server-$ServerName*" -ErrorAction SilentlyContinue
        }

        if ($rules) {
            Write-Log "Trovata regola firewall per $ServerName" "INFO"
            return $rules
        }
        else {
            Write-Log "Nessuna regola trovata per $ServerName" "INFO"
            return $null
        }
    }
    catch {
        Write-Log "Errore nella ricerca regole firewall: $_" "ERROR"
        return $null
    }
}

function Test-Administrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PublicIP {
    try {
        $ip = (Invoke-WebRequest -Uri "https://api.ipify.org?format=json" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop | ConvertFrom-Json).ip
        Write-Log "IP pubblico ottenuto: $ip" "INFO"
        return $ip
    }
    catch {
        Write-Log "Errore nel recupero IP pubblico: $_" "WARNING"
        return $null
    }
}

function Test-ExternalPort {
    param(
        [string]$PublicIP,
        [int]$Port = 27015
    )

    if ([string]::IsNullOrWhiteSpace($PublicIP)) {
        Write-Log "IP pubblico non disponibile" "WARNING"
        return $null
    }

    try {
        Write-Log "Test porta esterna: $PublicIP`:$Port" "INFO"
        $url = "https://www.canyouseeme.org/?port=$Port"
        $response = Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop

        if ($response.Content -match "open") {
            Write-Log "Porta $Port raggiungibile da remoto" "INFO"
            return $true
        }
        else {
            Write-Log "Porta $Port NON raggiungibile da remoto" "WARNING"
            return $false
        }
    }
    catch {
        Write-Log "Errore nel test porta remota: $_" "WARNING"
        return $null
    }
}

function Show-FirewallMenu {
    param(
        [string]$ServerName,
        [string]$RootPath,
        [int]$Port = 27015
    )

    # Get local IP once
    $localIP = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "127.*" } | Select-Object -First 1).IPAddress
    if (-not $localIP) { $localIP = "127.0.0.1" }

    # Get public IP once (cached)
    $publicIP = Get-PublicIP

    while ($true) {
        $rule = Get-ServerFirewallRule -ServerName $ServerName -Port $Port

        if ($rule) {
            $messageKey = "Firewall_Open"
            $statusColor = "Green"
            $actionText = "Close port $Port"
        }
        else {
            $messageKey = "Firewall_Closed"
            $statusColor = "Red"
            $actionText = "Open port $Port"
        }

        Write-Host "`n$(Get-Message -Key 'Firewall_Title')`n" -ForegroundColor Cyan
        Write-Host "  $(Get-Message -Key 'Firewall_ThirdPartyWarning')" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Server     : $ServerName" -ForegroundColor DarkGray
        Write-Host "Local IP   : $localIP" -ForegroundColor DarkGray
        if ($publicIP) {
            Write-Host "Public IP  : $publicIP" -ForegroundColor DarkGray
        }
        Write-Host "Port       : $Port" -ForegroundColor DarkGray
        Write-Host "Status     : $(Get-Message -Key $messageKey)" -ForegroundColor $statusColor

        Write-Host ""
        if ($rule) {
            Write-Host "Rule Name  : $($rule.DisplayName)" -ForegroundColor DarkGray
            Write-Host "Action     : $($rule.Action)" -ForegroundColor DarkGray
            Write-Host "Direction  : $($rule.Direction)" -ForegroundColor DarkGray
            Write-Host "Enabled    : $($rule.Enabled)" -ForegroundColor DarkGray
        }
        else {
            Write-Host "Rule Name  : -----" -ForegroundColor DarkGray
            Write-Host "Action     : -----" -ForegroundColor DarkGray
            Write-Host "Direction  : -----" -ForegroundColor DarkGray
            Write-Host "Enabled    : -----" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "  1) $actionText"
        Write-Host -NoNewline "  2) "
        Write-Host -NoNewline "$(Get-Message -Key 'Firewall_TestExt') " -ForegroundColor DarkGray
        Write-Host "[$(Get-Message -Key 'Common_WIP')]" -ForegroundColor DarkYellow
        Write-Host "  0) $(Get-Message -Key 'Manage_Back')`n"

        $fwChoice = Read-Host (Get-Message -Key "Common_Select")

        switch ($fwChoice) {
            "1" {
                if ($rule) {
                    Write-Host "`n$(Get-Message -Key 'Firewall_Disabling')`n"
                    $result = Disable-ServerFirewall -ServerName $ServerName -Port $Port
                    if ($result) {
                        Write-Host "$(Get-Message -Key 'Firewall_Disabled_Success')`n" -ForegroundColor Green
                    }
                    else {
                        Write-Host "$(Get-Message -Key 'Firewall_Disabled_Failed')`n" -ForegroundColor Red
                    }
                }
                else {
                    Write-Host "`n$(Get-Message -Key 'Firewall_Enabling')`n"
                    $result = Enable-ServerFirewall -ServerName $ServerName -Port $Port
                    if ($result) {
                        Write-Host "$(Get-Message -Key 'Firewall_Enabled_Success')`n" -ForegroundColor Green
                    }
                    else {
                        Write-Host "$(Get-Message -Key 'Firewall_Enabled_Failed')`n" -ForegroundColor Red
                    }
                }
                Read-Host (Get-Message -Key "Common_PressEnter") | Out-Null
            }
            "2" {
                Write-Host "`n$(Get-Message -Key 'Firewall_WIP')`n" -ForegroundColor Yellow
                Read-Host (Get-Message -Key "Common_PressEnter") | Out-Null
            }
            "0" {
                return
            }
        }
    }
}

function Invoke-ElevatedFirewall {
    param(
        [string]$ServerName,
        [string]$RootPath,
        [string]$Language = "it",
        [int]$Port = 27015
    )

    $scriptContent = @"
`$RootPath = '$RootPath'
`$Language = '$Language'
`$ServerName = '$ServerName'
`$Port = $Port
`$host.ui.RawUI.WindowTitle = 'Firewall Manager'
`$modulePath = Join-Path `$RootPath "modules"
Import-Module (Join-Path `$modulePath "network.psm1") -Force
Import-Module (Join-Path `$modulePath "messages.psm1") -Force
Import-Module (Join-Path `$modulePath "logging.psm1") -Force

`$localeDir = Join-Path `$RootPath "locale"
`$langFile = Join-Path `$localeDir "`$Language.json"
`$locale = Get-Content `$langFile -Raw | ConvertFrom-Json
Set-Messages `$locale

Show-FirewallMenu -ServerName `$ServerName -RootPath `$RootPath -Port `$Port
"@

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "firewall-$([guid]::NewGuid()).ps1"
    $scriptContent | Set-Content $tempScript -Encoding UTF8

    Start-Process powershell.exe -Verb RunAs -ArgumentList "-File", "`"$tempScript`"" -WindowStyle Normal -Wait
    Write-Log "Finestra firewall lanciata in background" "INFO"
}

function Show-ExternalFirewallGuide {
    param(
        [string]$FirewallName,
        [int]$Port = 27016
    )

    Write-Host ""
    Write-Host "  $(Get-Message -Key 'Firewall_ExtTitle')" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  $(Get-Message -Key 'Firewall_ExtDetected') " -NoNewline
    Write-Host $FirewallName -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  $(Get-Message -Key 'Firewall_ExtInfo1')" -ForegroundColor DarkGray
    Write-Host "  $(Get-Message -Key 'Firewall_ExtInfo2')"
    Write-Host ""
    Write-Host "  $(Get-Message -Key 'Firewall_ExtPortLabel')" -ForegroundColor White
    Write-Host "    $(Get-Message -Key 'Firewall_ExtPort')      : $Port"
    Write-Host "    $(Get-Message -Key 'Firewall_ExtProtocol')  : $(Get-Message -Key 'Firewall_ExtProtocolValue')"
    Write-Host "    $(Get-Message -Key 'Firewall_ExtDirection') : $(Get-Message -Key 'Firewall_ExtDirectionValue')"
    Write-Host ""
    Write-Host "  $(Get-Message -Key 'Firewall_ExtNote')" -ForegroundColor DarkGray
    Write-Host ""
    Read-Host (Get-Message -Key "Firewall_PressEnter") | Out-Null
}

function Invoke-FirewallManagement {
    param(
        [string]$ServerName,
        [string]$RootPath,
        [string]$Language = "it",
        [int]$Port = 27015
    )

    # Detect third-party firewall
    $tpFwName = $null
    try {
        $fwProducts = @(Get-CimInstance -Namespace "root/SecurityCenter2" -ClassName "FirewallProduct" -ErrorAction SilentlyContinue)
        foreach ($fp in $fwProducts) {
            if ($fp.displayName -notmatch "Windows") {
                $tpFwName = $fp.displayName
                break
            }
        }
    } catch { }

    if ($tpFwName) {
        Show-ExternalFirewallGuide -FirewallName $tpFwName -Port $Port
    } elseif (-not (Test-Administrator)) {
        Invoke-ElevatedFirewall -ServerName $ServerName -RootPath $RootPath -Language $Language -Port $Port
    } else {
        Show-FirewallMenu -ServerName $ServerName -RootPath $RootPath -Port $Port
    }
}

Export-ModuleMember -Function Enable-ServerFirewall, Disable-ServerFirewall, Test-ServerPort, Get-ServerFirewallRule, Test-Administrator, Show-FirewallMenu, Invoke-ElevatedFirewall, Show-ExternalFirewallGuide, Invoke-FirewallManagement
