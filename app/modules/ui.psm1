function Show-Header {
    Clear-Host
    Write-Host "====================================="
    Write-Host " L4D2 Dedicated Server Manager"
    Write-Host "====================================="
    Write-Host ""
}

function Show-ScrollHint {
    # Show a warning if the cursor is near the bottom of the visible window,
    # meaning the content above has scrolled out of view.
    try {
        $cursorRow  = [Console]::CursorTop
        $windowRows = [Console]::WindowHeight
        # If we are within 4 lines of the bottom, content likely scrolled off
        if ($cursorRow -ge ($windowRows - 4)) {
            Write-Host ""
            Write-Host "  ^ $(Get-Message -Key 'Common_ScrollHint')" -ForegroundColor DarkYellow
        }
    } catch { }
}

Export-ModuleMember -Function Show-Header, Show-ScrollHint
