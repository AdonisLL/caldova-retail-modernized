Set-StrictMode -Version Latest

$script:Lab04SqlPackageVersion = '170.5.96'
$script:Lab04SqlPackageFeed = 'https://api.nuget.org/v3/index.json'

function Get-Lab04SqlMiImportValues {
    param(
        [string]$SecondaryResourceGroup,
        [string]$ResourceGroupPrefix = 'rg-caldova-lab04-secondary'
    )

    $groups = @(az group list --output json --only-show-errors | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to list resource groups in the selected subscription.'
    }
    if ($SecondaryResourceGroup) {
        $matches = @($groups | Where-Object { $_.name -eq $SecondaryResourceGroup })
    }
    else {
        $matches = @($groups | Where-Object {
            $_.name -eq $ResourceGroupPrefix -or
                $_.name.StartsWith("$ResourceGroupPrefix-", [StringComparison]::OrdinalIgnoreCase)
        })
    }
    if ($matches.Count -ne 1) {
        throw "Expected exactly one secondary resource group; found $($matches.Count). Select the subscription and pass -SecondaryResourceGroup explicitly when multiple labs exist."
    }
    $resourceGroup = [string]$matches[0].name
    $instances = @(az sql mi list --resource-group $resourceGroup `
        --output json --only-show-errors | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list SQL Managed Instances in '$resourceGroup'."
    }
    if ($instances.Count -ne 1) {
        throw "Expected exactly one SQL Managed Instance in '$resourceGroup'; found $($instances.Count)."
    }
    $instance = $instances[0]
    if ($instance.state -ne 'Ready' -or -not $instance.publicDataEndpointEnabled) {
        throw "SQL Managed Instance '$($instance.name)' must be Ready with its public data endpoint enabled before import."
    }
    $fqdn = [string]$instance.fullyQualifiedDomainName
    if (-not $fqdn.StartsWith("$($instance.name).", [StringComparison]::OrdinalIgnoreCase)) {
        throw "SQL Managed Instance '$($instance.name)' returned an unexpected FQDN."
    }
    $subnet = az network vnet subnet show --ids $instance.subnetId `
        --output json --only-show-errors | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to read the SQL Managed Instance subnet.'
    }
    if (-not $subnet.networkSecurityGroup -or
        [string]::IsNullOrWhiteSpace([string]$subnet.networkSecurityGroup.id)) {
        throw "The SQL Managed Instance subnet has no network security group."
    }
    $nsgId = [string]$subnet.networkSecurityGroup.id
    $nsgPattern = '^/subscriptions/[^/]+/resourceGroups/([^/]+)/providers/Microsoft\.Network/networkSecurityGroups/([^/]+)$'
    $nsgMatch = [regex]::Match($nsgId, $nsgPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $nsgMatch.Success -or $nsgMatch.Groups[1].Value -ne $resourceGroup) {
        throw 'The SQL MI subnet NSG must be in the selected secondary resource group for this importer.'
    }
    $apps = @(az containerapp list --resource-group $resourceGroup `
        --output json --only-show-errors | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list Container Apps in '$resourceGroup'."
    }
    if ($apps.Count -ne 1) {
        throw "Expected exactly one retail Container App in '$resourceGroup'; found $($apps.Count)."
    }
    $app = $apps[0]
    $containers = @($app.properties.template.containers)
    if ($containers.Count -ne 1) {
        throw "Expected exactly one retail container in '$($app.name)'."
    }
    $clientIds = @($containers[0].env | Where-Object { $_.name -eq 'AZURE_CLIENT_ID' })
    if ($clientIds.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$clientIds[0].value)) {
        throw "Container App '$($app.name)' must have one literal AZURE_CLIENT_ID setting."
    }
    $clientId = [string]$clientIds[0].value
    $identities = @($app.identity.userAssignedIdentities.PSObject.Properties |
        Where-Object { $_.Value.clientId -eq $clientId })
    if ($identities.Count -ne 1) {
        throw "Container App '$($app.name)' does not have the runtime identity selected by AZURE_CLIENT_ID."
    }

    return @{
        AZURE_ENV_NAME = $resourceGroup
        LAB04_DATABASE_MODE = 'sqlMi'
        LAB04_DATABASE_NAME = 'eshop'
        LAB04_DATABASE_RESOURCE_GROUP = $resourceGroup
        LAB04_DATABASE_SERVER_NAME = [string]$instance.name
        LAB04_DATABASE_FQDN = $fqdn
        LAB04_SECONDARY_RESOURCE_GROUP = $resourceGroup
        LAB04_SQL_MI_NSG_NAME = $nsgMatch.Groups[2].Value
        LAB04_SQL_MI_PUBLIC_ENDPOINT = "$($instance.name).public.$($fqdn.Substring($instance.name.Length + 1)),3342"
        LAB05_RETAIL_DATABASE_NAME = 'eshop'
        LAB06_CONTAINER_APP_NAME = [string]$app.name
        LAB06_RUNTIME_IDENTITY_CLIENT_ID = $clientId
    }
}

function Test-Lab04PublicIPv4Address {
    param([Parameter(Mandatory)][string]$IpAddress)

    $parsedAddress = $null
    return (
        [Net.IPAddress]::TryParse($IpAddress, [ref]$parsedAddress) -and
        $parsedAddress.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
        $parsedAddress.ToString() -eq $IpAddress
    )
}

function New-Lab04DatabaseImportRuleName {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][ValidateSet('azureSql', 'sqlMi')][string]$DatabaseMode
    )

    $value = "$SubscriptionId|$EnvironmentName|$DatabaseMode".ToLowerInvariant()
    $bytes = [Text.Encoding]::UTF8.GetBytes($value)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    $hash = [BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
    return "AllowBacpacImport-$($hash.Substring(0, 24))"
}

function Get-Lab04SqlPackageVersion {
    return $script:Lab04SqlPackageVersion
}

function Get-Lab04SqlPackageFeed {
    return $script:Lab04SqlPackageFeed
}

function Get-Lab04SqlPackageExecutableName {
    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        return 'sqlpackage.exe'
    }

    return 'sqlpackage'
}

function Get-Lab04SqlPackageCachePath {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $azureRoot = Join-Path $ProjectRoot '.azure'
    $toolsRoot = Join-Path $azureRoot 'tools'
    $sqlPackageRoot = Join-Path $toolsRoot 'sqlpackage'
    return Join-Path $sqlPackageRoot $script:Lab04SqlPackageVersion
}

function Assert-Lab04SqlPackageVersion {
    param([Parameter(Mandatory)][string]$ExecutablePath)

    if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
        throw "SqlPackage executable was not found at '$ExecutablePath'."
    }

    $reportedVersion = (& $ExecutablePath /Version).ToString().Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "SqlPackage at '$ExecutablePath' failed its version check with exit code $LASTEXITCODE."
    }
    if ($reportedVersion -notmatch "^$([regex]::Escape($script:Lab04SqlPackageVersion))(?:\.0)?$") {
        throw "SqlPackage at '$ExecutablePath' reported version '$reportedVersion'; expected '$script:Lab04SqlPackageVersion'."
    }
}

function Resolve-Lab04SqlPackage {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $cachePath = Get-Lab04SqlPackageCachePath -ProjectRoot $ProjectRoot
    $executableName = Get-Lab04SqlPackageExecutableName
    $executablePath = Join-Path $cachePath $executableName
    if (Test-Path -LiteralPath $executablePath -PathType Leaf) {
        Assert-Lab04SqlPackageVersion -ExecutablePath $executablePath
        return $executablePath
    }
    if (Test-Path -LiteralPath $cachePath) {
        throw "The SqlPackage cache at '$cachePath' is incomplete. Remove that version directory and rerun the deployment."
    }
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw "Required command 'dotnet' was not found on PATH. Install the .NET SDK and rerun the deployment."
    }

    $toolsRoot = Split-Path -Parent $cachePath
    $null = New-Item -ItemType Directory -Path $toolsRoot -Force
    $temporaryPath = Join-Path `
        $toolsRoot `
        ".install-$([guid]::NewGuid().ToString('N'))"

    try {
        & dotnet tool install Microsoft.SqlPackage `
            --tool-path $temporaryPath `
            --version $script:Lab04SqlPackageVersion `
            --add-source $script:Lab04SqlPackageFeed `
            --ignore-failed-sources `
            --allow-roll-forward | Write-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Installing Microsoft.SqlPackage $script:Lab04SqlPackageVersion failed with exit code $LASTEXITCODE."
        }

        $temporaryExecutablePath = Join-Path $temporaryPath $executableName
        Assert-Lab04SqlPackageVersion `
            -ExecutablePath $temporaryExecutablePath

        if (Test-Path -LiteralPath $cachePath) {
            if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
                throw "Another SqlPackage installation created an incomplete cache at '$cachePath'."
            }
            Assert-Lab04SqlPackageVersion -ExecutablePath $executablePath
            return $executablePath
        }

        try {
            Move-Item -LiteralPath $temporaryPath -Destination $cachePath
        }
        catch {
            if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
                throw
            }
            Assert-Lab04SqlPackageVersion -ExecutablePath $executablePath
            return $executablePath
        }
        Assert-Lab04SqlPackageVersion -ExecutablePath $executablePath
        return $executablePath
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Recurse -Force
        }
    }
}
