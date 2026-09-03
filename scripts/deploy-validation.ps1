function Test-PublicIPv4Address {
    param([string]$Address)

    $parsedAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsedAddress) -or
        $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $parsedAddress.IPAddressToString -ne $Address) {
        return $false
    }

    $octets = $parsedAddress.GetAddressBytes()
    return -not (
        $octets[0] -eq 0 -or
        $octets[0] -eq 10 -or
        $octets[0] -eq 127 -or
        ($octets[0] -eq 100 -and $octets[1] -ge 64 -and $octets[1] -le 127) -or
        ($octets[0] -eq 169 -and $octets[1] -eq 254) -or
        ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 0 -and ($octets[2] -eq 0 -or $octets[2] -eq 2)) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 88 -and $octets[2] -eq 99) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 168) -or
        ($octets[0] -eq 198 -and ($octets[1] -eq 18 -or $octets[1] -eq 19)) -or
        ($octets[0] -eq 198 -and $octets[1] -eq 51 -and $octets[2] -eq 100) -or
        ($octets[0] -eq 203 -and $octets[1] -eq 0 -and $octets[2] -eq 113) -or
        $octets[0] -ge 224
    )
}
