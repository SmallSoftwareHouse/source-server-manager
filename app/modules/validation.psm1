# =========================================================
# VALIDATION MODULE
# =========================================================

function Test-ServerName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return Get-Message -Key "Val_NameEmpty"
    }

    if ($Name.Length -lt 2) {
        return Get-Message -Key "Val_NameTooShort"
    }

    if ($Name.Length -gt 64) {
        return Get-Message -Key "Val_NameTooLong"
    }

    # vietati caratteri Windows + spazi (regola tuo sistema)
    if ($Name -match '[\\/:*?"<>|\s]') {
        return Get-Message -Key "Val_NameInvalidChars"
    }

    return $null
}


function Test-ServerPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return Get-Message -Key "Val_PathEmpty"
    }

    try {
        [void][System.IO.Path]::GetFullPath($Path)
    }
    catch {
        return Get-Message -Key "Val_PathInvalid" -MsgArgs @($Path)
    }

    if (Test-Path $Path) {

        if (-not (Test-Path $Path -PathType Container)) {
            return Get-Message -Key "Val_PathNotDirectory"
        }

        $items = Get-ChildItem -Path $Path -ErrorAction SilentlyContinue

        # warning: cartella non vuota (non errore)
        if ($items -and $items.Count -gt 0) {
            return "WARN:" + (Get-Message -Key "Val_PathNonEmpty")
        }
    }

    return $null
}


function Resolve-ServerPath {
    param(
        [Parameter(Mandatory)]
        [string]$ServerId,

        [Parameter(Mandatory)]
        [string]$ExpectedPath,

        [Parameter(Mandatory)]
        [string]$RootServersPath
    )

    # =====================================================
    # 1. CASO NORMALE (path corretto)
    # =====================================================
    if (Test-Path $ExpectedPath) {
        return $ExpectedPath
    }

    # =====================================================
    # 2. FALLBACK: ricerca server rinominato/spostato
    # =====================================================
    $candidates = Get-ChildItem -Path $RootServersPath -Directory -ErrorAction SilentlyContinue

    foreach ($dir in $candidates) {

        # ignora path atteso (anche se rotto)
        if ($dir.FullName -eq $ExpectedPath) {
            continue
        }

        # -------------------------------------------------
        # MATCH FORTEMENTE CONSISTENTE (IDENTITA SERVER)
        # -------------------------------------------------
        $marker = Join-Path $dir.FullName "server_id.txt"

        if (Test-Path $marker) {
            $id = Get-Content $marker -ErrorAction SilentlyContinue

            if ($id -and $id.Trim() -eq $ServerId) {
                return $dir.FullName
            }
        }
    }

    # =====================================================
    # 3. FALLBACK ESTREMO: nessun match
    # =====================================================
    return $null
}


function Resolve-ServerRegistryEntry {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Server,

        [Parameter(Mandatory)]
        [string]$RootServersPath
    )

    # tenta recupero path reale
    $resolved = Resolve-ServerPath `
        -ServerId $Server.ServerId `
        -ExpectedPath $Server.Path `
        -RootServersPath $RootServersPath

    if ($null -eq $resolved) {
        return $null
    }

    # ritorna oggetto aggiornato
    $Server.Path = $resolved
    return $Server
}


Export-ModuleMember -Function `
    Test-ServerName, `
    Test-ServerPath, `
    Resolve-ServerPath, `
    Resolve-ServerRegistryEntry