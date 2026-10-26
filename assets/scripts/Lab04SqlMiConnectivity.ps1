function ConvertTo-Lab04SqlMiPublicEndpoint {
    param(
        [Parameter(Mandatory)]
        [string]$Endpoint
    )

    $parts = @($Endpoint.Trim().Split(','))
    if ($parts.Count -ne 2) {
        throw "SQL MI public endpoint '$Endpoint' must use the format '<hostname>,3342'."
    }

    $hostName = $parts[0].Trim()
    $port = 0
    if (
        [Uri]::CheckHostName($hostName) -ne [UriHostNameType]::Dns -or
        -not [int]::TryParse($parts[1].Trim(), [ref]$port) -or
        $port -ne 3342
    ) {
        throw "SQL MI public endpoint '$Endpoint' must contain a valid DNS hostname and TCP port 3342."
    }

    return [pscustomobject]@{
        HostName = $hostName
        Port = $port
        DisplayName = "$hostName,$port"
    }
}

function Wait-Lab04SqlMiPublicEndpoint {
    param(
        [Parameter(Mandatory)]
        [string]$HostName,

        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int]$Port,

        [ValidateRange(1, 60)]
        [int]$RetryCount = 12,

        [ValidateRange(0, 60)]
        [int]$RetryDelaySeconds = 10,

        [ValidateRange(1, 60)]
        [int]$ConnectionTimeoutSeconds = 5
    )

    $lastFailure = 'No connection attempt was made.'
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            $addresses = @([Net.Dns]::GetHostAddresses($HostName))
            if ($addresses.Count -eq 0) {
                throw "No addresses were returned for '$HostName'."
            }
        }
        catch {
            $lastFailure = "DNS resolution failed: $($_.Exception.Message)"
            if ($attempt -lt $RetryCount -and $RetryDelaySeconds -gt 0) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
            continue
        }

        $client = [Net.Sockets.TcpClient]::new()
        try {
            $connectTask = $client.ConnectAsync($HostName, $Port)
            if (-not $connectTask.Wait($ConnectionTimeoutSeconds * 1000)) {
                $lastFailure = "TCP connection timed out after $ConnectionTimeoutSeconds seconds."
            }
            elseif ($client.Connected) {
                return
            }
            else {
                $lastFailure = 'TCP connection completed without establishing a connection.'
            }
        }
        catch {
            $lastFailure = "TCP connection failed: $($_.Exception.GetBaseException().Message)"
        }
        finally {
            $client.Dispose()
        }

        if ($attempt -lt $RetryCount -and $RetryDelaySeconds -gt 0) {
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    throw "SQL MI public endpoint '$HostName,$Port' was not reachable after $RetryCount attempt(s). $lastFailure"
}
