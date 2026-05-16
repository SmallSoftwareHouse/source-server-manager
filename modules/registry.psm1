# =========================================================
# SERVER REGISTRY MODULE (FIXED)
# =========================================================

function Get-ServerRegistry {

    $path = Join-Path $RootPath "config\servers_registry.json"

    if (-not (Test-Path $path)) {
        return @()
    }

    try {
        $data = Get-Content $path -Raw | ConvertFrom-Json
    }
    catch {
        return @()
    }

    if (-not $data) {
        return @()
    }

    if ($data -isnot [System.Array]) {
        $data = @($data)
    }

    return $data
}


function Save-ServerRegistry {
    param($data)

    $path = Join-Path $RootPath "config\servers_registry.json"

    $json = ConvertTo-Json -InputObject @($data) -Depth 10
    [System.IO.File]::WriteAllText(
        $path,
        $json,
        [System.Text.Encoding]::UTF8
    )
}


function Add-ServerToRegistry {
    param($server)

    $registry = Get-ServerRegistry

    $exists = $registry | Where-Object {
        $_.ServerId -eq $server.ServerId -or $_.Name -eq $server.Name
    }

    if ($exists) {
        return
    }

    $registry += $server
    Save-ServerRegistry $registry
}


function Update-ServerStatus {
    param(
        [string]$ServerId,
        [string]$Status
    )

    $registry = Get-ServerRegistry

    foreach ($s in $registry) {
        if ($s.ServerId -eq $ServerId) {
            $s.Status = $Status
            $s.LastUpdate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }

    Save-ServerRegistry $registry
}


function Remove-ServerFromRegistry {
    param([string]$ServerId)

    $registry = Get-ServerRegistry
    $filtered = $registry | Where-Object {
        $_.ServerId -ne $ServerId
    }

    Save-ServerRegistry $filtered
}


function Get-ServerByName {
    param([string]$Name)

    $registry = Get-ServerRegistry
    return $registry | Where-Object {
        $_.Name -eq $Name
    }
}

function Get-ServerById {
    param(
        [string]$ServerId
    )

    $servers = @(Get-ServerRegistry)

    foreach ($server in $servers) {
        if ($server.ServerId -eq $ServerId) {
            return $server
        }
    }

    return $null
}

function Validate-ServerRegistry {

    $registry = @(Get-ServerRegistry)
    $rootServers = Join-Path $RootPath "servers"

    foreach ($s in $registry) {

        # tenta risoluzione intelligente (rename/move/fix path)
        $resolved = Resolve-ServerPath `
            -ServerId $s.ServerId `
            -ExpectedPath $s.Path `
            -RootServersPath $rootServers

        if ($resolved) {

            # riallineamento path se cambiato
            if ($resolved -ne $s.Path) {
                Write-Log "Path riallineato: $($s.Name)" "INFO"
                $s.Path = $resolved
                $s.LastUpdate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }

            # se esiste su disco → OK
            if (Test-Path $resolved) {
                continue
            }
        }

        # caso reale di mancanza
        $s.Status = "Missing"
    }

    Save-ServerRegistry $registry
}


function Get-ServerGamePath {
    param([object]$Server)
    return Join-Path $Server.Path "server"
}

function Get-ServerManagerPath {
    param([object]$Server)
    return Join-Path $Server.Path "manager"
}

Export-ModuleMember -Function `
Get-ServerRegistry, `
Save-ServerRegistry, `
Add-ServerToRegistry, `
Update-ServerStatus, `
Remove-ServerFromRegistry, `
Get-ServerByName, `
Validate-ServerRegistry, `
Get-ServerById, `
Get-ServerGamePath, `
Get-ServerManagerPath