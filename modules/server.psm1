function Get-ServerDiskStatus {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path $Path)) {
        return "Missing"
    }

    # File critici che indicano un'installazione L4D2 completata
    $criticalFiles = @(
        "srcds.exe",
        "left4dead2\gameinfo.txt"
    )

    $found = 0
    foreach ($file in $criticalFiles) {
        if (Test-Path (Join-Path $Path $file)) {
            $found++
        }
    }

    if ($found -eq $criticalFiles.Count) {
        return "Installed"
    }
    elseif ($found -gt 0) {
        return "Incomplete"
    }
    else {
        # La cartella esiste ma non ha nessun file del server
        $items = Get-ChildItem $Path -ErrorAction SilentlyContinue
        if (-not $items -or $items.Count -eq 0) {
            return "Empty"
        }
        return "Incomplete"
    }
}

Export-ModuleMember -Function Get-ServerDiskStatus
