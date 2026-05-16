function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"

    Write-Host $line
    Add-Content -Path ".\logs\manager.log" -Value $line
}

Export-ModuleMember -Function Write-Log
