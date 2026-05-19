$script:Messages = $null

function Set-Messages {
    param([object]$MessagesObject)
    $script:Messages = $MessagesObject
}

function Get-Message {
    param(
        [string]$Key,
        [object[]]$MsgArgs = @()
    )

    if ($null -eq $script:Messages) {
        return "[NO LOCALE] $Key"
    }

    $value = $null

    if ($script:Messages -is [hashtable]) {
        if ($script:Messages.ContainsKey($Key)) {
            $value = $script:Messages[$Key]
        }
    } else {
        $prop = $script:Messages.PSObject.Properties[$Key]
        if ($prop) {
            $value = $prop.Value
        }
    }

    if ($null -eq $value) {
        return "[MISSING KEY] $Key"
    }

    if ($MsgArgs.Count -gt 0) {
        return ($value -f $MsgArgs)
    }

    return $value
}

Export-ModuleMember -Function Set-Messages, Get-Message
