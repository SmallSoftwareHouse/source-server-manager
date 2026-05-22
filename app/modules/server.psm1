function Get-ServerDiskStatus {
    param(
        [string]$Path,
        [string]$Game = ""
    )

    if (-not $Path -or -not (Test-Path $Path)) {
        return "Missing"
    }

    # Determine game folder from metadata if game type is provided
    $gameFolder = "left4dead2"  # safe default
    if ($Game -ne "" -and $global:RootPath) {
        $metaFile = Join-Path $global:RootPath "games\$Game\metadata.json"
        if (Test-Path $metaFile) {
            try {
                $meta = Get-Content $metaFile -Raw | ConvertFrom-Json
                if ($meta.GameFolder) { $gameFolder = $meta.GameFolder }
            } catch { }
        }
    }

    # Critical files that indicate a complete server installation
    $criticalFiles = @(
        "srcds.exe",
        "$gameFolder\gameinfo.txt"
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
        $items = Get-ChildItem $Path -ErrorAction SilentlyContinue
        if (-not $items -or $items.Count -eq 0) {
            return "Empty"
        }
        return "Incomplete"
    }
}

Export-ModuleMember -Function Get-ServerDiskStatus
