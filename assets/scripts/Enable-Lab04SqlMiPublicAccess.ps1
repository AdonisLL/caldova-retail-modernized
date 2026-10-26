[CmdletBinding()]
param(
    [string]$SubscriptionId,

    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')]
    [string]$IpAddress,

    [string]$ResourceGroupName,

    [string]$NetworkSecurityGroupName,

    [string]$PublicEndpoint,

    [string]$RuleName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot 'Lab04SqlMiConnectivity.ps1')
. (Join-Path $PSScriptRoot 'Lab04SqlMiPublicAccess.ps1')

function Test-PublicIpv4Address {
    param([Parameter(Mandatory)][string]$Address)

    $parsedAddress = [Net.IPAddress]::None
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsedAddress)) {
        return $false
    }

    if ($parsedAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }

    $bytes = $parsedAddress.GetAddressBytes()
    return -not (
        $bytes[0] -eq 10 -or
        $bytes[0] -eq 127 -or
        ($bytes[0] -eq 169 -and $bytes[1] -eq 254) -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or
        $bytes[0] -ge 224
    )
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI 'az' was not found on PATH."
}

az account show --output none
if ($LASTEXITCODE -ne 0) {
    throw "Sign in with 'az login' before running this script."
}

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to select Azure subscription '$SubscriptionId'."
    }
}

if (-not $IpAddress) {
    $consent = Read-Host 'Detect your public IPv4 address using api.ipify.org? Type Y or YES to continue'
    if (-not (Test-Lab04AffirmativeResponse -Response $consent)) {
        throw 'Public IP discovery was not approved. Rerun with -IpAddress <your-public-ipv4>.'
    }

    $IpAddress = (
        Invoke-RestMethod -Uri 'https://api.ipify.org' -Method Get -TimeoutSec 15
    ).ToString().Trim()
}

if (-not (Test-PublicIpv4Address -Address $IpAddress)) {
    throw "'$IpAddress' is not a valid public IPv4 address."
}

if (-not $RuleName) {
    $account = az account show `
        --query '{subscriptionId:id,tenantId:tenantId,accountName:user.name}' `
        --output json |
        ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $null -eq $account) {
        throw 'Unable to read the signed-in Azure account metadata used to generate the SQL MI access rule name.'
    }

    $RuleName = New-Lab04SqlMiParticipantRuleName `
        -SubscriptionId ([string]$account.subscriptionId) `
        -TenantId ([string]$account.tenantId) `
        -AccountName ([string]$account.accountName)
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName) -xor [string]::IsNullOrWhiteSpace($NetworkSecurityGroupName)) {
    throw 'Specify both -ResourceGroupName and -NetworkSecurityGroupName, or neither.'
}

if (-not $ResourceGroupName) {
    $matches = @(
        az network nsg list `
            --query "[?contains(name, '-sqlmi-')].{name:name,resourceGroup:resourceGroup}" `
            --output json |
            ConvertFrom-Json
    )
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to discover the Lab 04 SQL MI network security group.'
    }
    if ($matches.Count -ne 1) {
        throw "Expected one SQL MI network security group but found $($matches.Count). Specify -ResourceGroupName and -NetworkSecurityGroupName."
    }

    $ResourceGroupName = [string]$matches[0].resourceGroup
    $NetworkSecurityGroupName = [string]$matches[0].name
}

if (-not $PublicEndpoint) {
    $managedInstances = @(
        az sql mi list `
            --resource-group $ResourceGroupName `
            --query "[?publicDataEndpointEnabled].{name:name,fqdn:fullyQualifiedDomainName}" `
            --output json |
            ConvertFrom-Json
    )
    if ($LASTEXITCODE -ne 0 -or $managedInstances.Count -ne 1) {
        throw "Exactly one public SQL managed instance could not be resolved in '$ResourceGroupName'. Supply -PublicEndpoint when your account has access only to the NSG."
    }

    $managedInstance = $managedInstances[0]
    $publicFqdn = ([string]$managedInstance.fqdn).Replace(
        "$($managedInstance.name).",
        "$($managedInstance.name).public."
    )
    $PublicEndpoint = "$publicFqdn,3342"
}

$parsedPublicEndpoint = ConvertTo-Lab04SqlMiPublicEndpoint -Endpoint $PublicEndpoint

az network nsg rule create `
    --resource-group $ResourceGroupName `
    --nsg-name $NetworkSecurityGroupName `
    --name $RuleName `
    --priority 1300 `
    --access Allow `
    --direction Inbound `
    --protocol Tcp `
    --source-address-prefixes "$IpAddress/32" `
    --source-port-ranges '*' `
    --destination-address-prefixes '*' `
    --destination-port-ranges 3342 `
    --description 'Participant SQL MI public endpoint access' `
    --output none
if ($LASTEXITCODE -ne 0) {
    throw "Unable to update NSG '$NetworkSecurityGroupName'. Confirm that your account can write security rules on this NSG."
}

Write-Host "Allowed $IpAddress/32 to reach SQL MI on TCP 3342."
Write-Host "Waiting for $($parsedPublicEndpoint.DisplayName) to become reachable..."
Wait-Lab04SqlMiPublicEndpoint `
    -HostName $parsedPublicEndpoint.HostName `
    -Port $parsedPublicEndpoint.Port
Write-Host "Verified DNS resolution and TCP connectivity to $($parsedPublicEndpoint.DisplayName)."
Write-Host "Connect with Microsoft Entra authentication: $($parsedPublicEndpoint.DisplayName)"
