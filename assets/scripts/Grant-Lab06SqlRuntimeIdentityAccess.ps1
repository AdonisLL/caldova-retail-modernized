#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ManagedInstanceName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ManagedInstanceResourceGroup,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RuntimeIdentityName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RuntimeIdentityResourceGroup,

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$Database = 'eshop',

    [string]$SqlServerInstance,

    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $result = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Arguments -join ' ')."
    }
    if (-not $result) {
        throw "Azure CLI returned no result: az $($Arguments -join ' ')."
    }
    return ($result | ConvertFrom-Json)
}

if (-not $Apply) {
    Write-Host 'No changes made. Supply -Apply to grant the SQL Managed Instance Directory Readers and configure the runtime identity in SQL.'
    return
}

$requiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Applications',
    'Microsoft.Graph.Identity.DirectoryManagement',
    'Az.Accounts',
    'SqlServer'
)
if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) {
    throw 'Install-Module is unavailable. Install PowerShellGet, then rerun this script.'
}

foreach ($moduleName in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        Write-Host "Installing missing module '$moduleName' for the current user."
        Install-Module -Name $moduleName -Scope CurrentUser -Repository PSGallery `
            -Force -ErrorAction Stop
    }
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        throw "PowerShell module '$moduleName' was not available after installation."
    }
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Install it and sign in to the target subscription before running this script.'
}

$account = Invoke-AzJson -Arguments @(
    'account', 'show', '--subscription', $SubscriptionId, '--query', '{id:id,tenantId:tenantId}'
)
if ($account.id -ne $SubscriptionId) {
    throw 'Azure CLI resolved a different subscription than requested.'
}

$managedInstance = Invoke-AzJson -Arguments @(
    'sql', 'mi', 'show', '--name', $ManagedInstanceName,
    '--resource-group', $ManagedInstanceResourceGroup,
    '--subscription', $SubscriptionId,
    '--query', '{name:name,principalId:identity.principalId,fullyQualifiedDomainName:properties.fullyQualifiedDomainName}'
)
$managedInstancePrincipalId = [string]$managedInstance.principalId
if ([string]::IsNullOrWhiteSpace($managedInstancePrincipalId)) {
    throw "SQL Managed Instance '$ManagedInstanceName' has no system-assigned identity."
}

$runtimeIdentity = Invoke-AzJson -Arguments @(
    'identity', 'show', '--name', $RuntimeIdentityName,
    '--resource-group', $RuntimeIdentityResourceGroup,
    '--subscription', $SubscriptionId,
    '--query', '{name:name,principalId:principalId}'
)
$runtimePrincipalId = [string]$runtimeIdentity.principalId
if ([string]::IsNullOrWhiteSpace($runtimePrincipalId)) {
    throw "Runtime identity '$RuntimeIdentityName' has no service-principal object ID."
}

if ([string]::IsNullOrWhiteSpace($SqlServerInstance)) {
    $publicHost = [string]$managedInstance.fullyQualifiedDomainName -replace '^([^.]+)\.', '$1.public.'
    $SqlServerInstance = "$publicHost,3342"
}

Write-Host "Subscription: $SubscriptionId"
Write-Host "SQL Managed Instance: $ManagedInstanceName"
Write-Host "SQL MI identity object ID: $managedInstancePrincipalId"
Write-Host "Runtime identity: $RuntimeIdentityName"
Write-Host "Runtime identity object ID: $runtimePrincipalId"
Write-Host "SQL target: $SqlServerInstance / $Database"

Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Applications
Import-Module Microsoft.Graph.Identity.DirectoryManagement
Connect-MgGraph -TenantId $account.tenantId `
    -Scopes @('RoleManagement.ReadWrite.Directory', 'Application.Read.All') -NoWelcome

try {
    $sqlManagedInstanceServicePrincipal = Get-MgServicePrincipal `
        -ServicePrincipalId $managedInstancePrincipalId
    if (-not $sqlManagedInstanceServicePrincipal) {
        throw "Could not resolve SQL Managed Instance service principal '$managedInstancePrincipalId' in Microsoft Entra ID."
    }

    $directoryRoles = @(Get-MgDirectoryRole -Filter "displayName eq 'Directory Readers'")
    if ($directoryRoles.Count -ne 1) {
        throw "The Directory Readers directory role is not active or is ambiguous in this tenant. Activate/resolve it, then rerun."
    }
    $directoryRole = $directoryRoles[0]
    $existingMembers = @(Get-MgDirectoryRoleMember -DirectoryRoleId $directoryRole.Id `
        -Filter "id eq '$managedInstancePrincipalId'" -All)

    if ($existingMembers.Count -eq 0) {
        if (-not $PSCmdlet.ShouldProcess(
            "$ManagedInstanceName ($managedInstancePrincipalId)",
            'Add the SQL Managed Instance identity to Microsoft Entra Directory Readers'
        )) {
            Write-Warning 'Directory Readers was not granted; SQL access changes were skipped.'
            return
        }

        New-MgDirectoryRoleMemberByRef -DirectoryRoleId $directoryRole.Id -BodyParameter @{
            '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$managedInstancePrincipalId"
        } | Out-Null
        Write-Host 'Directory Readers membership added to the SQL Managed Instance identity.'
    }
    else {
        Write-Host 'The SQL Managed Instance identity already has Directory Readers.'
    }

    if (-not $PSCmdlet.ShouldProcess(
        "$SqlServerInstance / $Database",
        "Create the runtime login and grant db_datareader/db_datawriter to '$RuntimeIdentityName'"
    )) {
        Write-Warning 'SQL login and database-role changes were not applied.'
        return
    }

    Import-Module Az.Accounts
    Import-Module SqlServer
    Connect-AzAccount -Tenant $account.tenantId | Out-Null
    $sqlAccessToken = (Get-AzAccessToken -ResourceUrl 'https://database.windows.net/').Token

    $createLoginQuery = @"
IF SUSER_ID(N'$RuntimeIdentityName') IS NULL
BEGIN
    CREATE LOGIN [$RuntimeIdentityName] FROM EXTERNAL PROVIDER;
END;
"@

    try {
        Invoke-Sqlcmd -ServerInstance $SqlServerInstance -Database 'master' `
            -AccessToken $sqlAccessToken -Query $createLoginQuery -AbortOnError | Out-Null
    }
    catch {
        if ($_.Exception.Message -match '37353|Directory Readers|server identity') {
            throw "SQL Managed Instance has not observed its Directory Readers permission yet. Allow Entra propagation, then rerun this script with -Apply. Original error: $($_.Exception.Message)"
        }
        throw
    }

    $configureDatabaseQuery = @"
IF DATABASE_PRINCIPAL_ID(N'$RuntimeIdentityName') IS NULL
BEGIN
    CREATE USER [$RuntimeIdentityName] FROM LOGIN [$RuntimeIdentityName];
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members AS members
    INNER JOIN sys.database_principals AS roles
        ON roles.principal_id = members.role_principal_id
    INNER JOIN sys.database_principals AS principals
        ON principals.principal_id = members.member_principal_id
    WHERE roles.name = N'db_datareader'
      AND principals.name = N'$RuntimeIdentityName'
)
    ALTER ROLE [db_datareader] ADD MEMBER [$RuntimeIdentityName];

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members AS members
    INNER JOIN sys.database_principals AS roles
        ON roles.principal_id = members.role_principal_id
    INNER JOIN sys.database_principals AS principals
        ON principals.principal_id = members.member_principal_id
    WHERE roles.name = N'db_datawriter'
      AND principals.name = N'$RuntimeIdentityName'
)
    ALTER ROLE [db_datawriter] ADD MEMBER [$RuntimeIdentityName];
"@

    Invoke-Sqlcmd -ServerInstance $SqlServerInstance -Database $Database `
        -AccessToken $sqlAccessToken -Query $configureDatabaseQuery -AbortOnError | Out-Null

    Write-Host "Configured '$RuntimeIdentityName' for '$Database' with db_datareader and db_datawriter."
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}