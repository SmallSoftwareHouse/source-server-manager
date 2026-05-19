$Port = 25565

$PublicIP = (Invoke-RestMethod "https://ifconfig.me/ip").Trim()

$Body = @{
    remoteAddress = $PublicIP
    portNumber    = $Port
}

$response = Invoke-RestMethod `
    -Uri "https://ports.yougetsignal.com/check-port.php" `
    -Method Post `
    -Body $Body

Write-Host "IP Pubblico: $PublicIP"
Write-Host "Porta: $Port"
Write-Host "Status: $($response.status)"

if ($response.status -eq "open") {
    Write-Host "PORTA APERTA E RAGGIUNGIBILE"
}
else {
    Write-Host "PORTA CHIUSA O NON RAGGIUNGIBILE"
}