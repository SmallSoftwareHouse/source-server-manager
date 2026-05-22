function Show-Header {
    Clear-Host
    Write-Host "====================================="
    Write-Host " L4D2 Dedicated Server Manager"
    Write-Host "====================================="
    Write-Host ""
}

function Show-ScrollHint {
    try {
        $cursorRow  = [Console]::CursorTop
        $windowRows = [Console]::WindowHeight
        if ($cursorRow -ge ($windowRows - 4)) {
            Write-Host ""
            Write-Host "  ^ $(Get-Message -Key 'Common_ScrollHint')" -ForegroundColor DarkYellow
        }
    } catch { }
}

function Format-SectionTitle {
    param([string]$Title)
    $width = 37
    $inner = " $Title "
    $remaining = $width - $inner.Length
    if ($remaining -lt 0) { $remaining = 0 }
    $left  = [Math]::Floor($remaining / 2)
    $right = $remaining - $left
    return ("=" * $left) + $inner + ("=" * $right)
}

function Get-DriveFreeGB {
    param([string]$DriveLetter)
    try {
        $wmi = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='${DriveLetter}:'" -ErrorAction SilentlyContinue
        if ($wmi) { return [math]::Round($wmi.FreeSpace / 1GB, 1) }
    } catch { }
    return -1
}

function Get-PathFreeGB {
    param([string]$Path)
    try {
        $letter = ($Path -replace '^([A-Za-z]):.*', '$1')
        return Get-DriveFreeGB -DriveLetter $letter
    } catch { }
    return -1
}

function Write-SpaceIndicator {
    param([double]$GB)
    if ($GB -lt 0) { return }
    if ($GB -lt 10) {
        Write-Host "  [$(Get-Message -Key 'Browse_Insufficient')  ${GB}GB]" -ForegroundColor Red
    } elseif ($GB -lt 20) {
        Write-Host "  [$(Get-Message -Key 'Browse_Warning')  ${GB}GB]" -ForegroundColor Yellow
    } else {
        Write-Host "  [$(Get-Message -Key 'Browse_Recommended')  ${GB}GB]" -ForegroundColor Green
    }
}

function Get-SpaceColor {
    param([double]$GB)
    if ($GB -lt 0)  { return "Gray" }
    if ($GB -lt 10) { return "Red" }
    if ($GB -lt 20) { return "Yellow" }
    return "Green"
}

function Get-SpaceSuffix {
    param([double]$GB)
    if ($GB -lt 0)  { return "" }
    if ($GB -lt 10) { return "  [$(Get-Message -Key 'Browse_Insufficient')  ${GB}GB]" }
    if ($GB -lt 20) { return "  [$(Get-Message -Key 'Browse_Warning')  ${GB}GB]" }
    return "  [$(Get-Message -Key 'Browse_Recommended')  ${GB}GB]"
}

Export-ModuleMember -Function Show-Header, Show-ScrollHint, Format-SectionTitle, Get-DriveFreeGB, Get-PathFreeGB, Write-SpaceIndicator, Get-SpaceColor, Get-SpaceSuffix
