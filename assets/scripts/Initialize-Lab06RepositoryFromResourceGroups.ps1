[CmdletBinding(DefaultParameterSetName = 'Protected')]
param(
    [string]$SubscriptionId,

    [string]$Repository,

    [ValidateNotNullOrEmpty()]
    [string]$BootstrapResourceGroup,

    [ValidateNotNullOrEmpty()]
    [string]$PrimaryResourceGroup,

    [ValidateNotNullOrEmpty()]
    [string]$SecondaryResourceGroup,

    [ValidateNotNullOrEmpty()]
    [string]$GlobalResourceGroup,

    [ValidateLength(1, 64)]
    [ValidatePattern('^[a-zA-Z0-9._()\-]+$')]
    [string]$BootstrapDeploymentName,

    [ValidateLength(1, 64)]
    [ValidatePattern('^[a-zA-Z0-9._()\-]+$')]
    [string]$PrimaryDeploymentName,

    [ValidateLength(1, 64)]
    [ValidatePattern('^[a-zA-Z0-9._()\-]+$')]
    [string]$SecondaryDeploymentName,

    [ValidateLength(1, 64)]
    [ValidatePattern('^[a-zA-Z0-9._()\-]+$')]
    [string]$GlobalDeploymentName,

    [Parameter(Mandatory, ParameterSetName = 'Protected')]
    [ValidateNotNullOrEmpty()]
    [string]$RequiredReviewer,

    [Parameter(Mandatory, ParameterSetName = 'Unprotected')]
    [switch]$AllowDeploymentWithoutRequiredReviewer,

    [ValidateNotNullOrEmpty()]
    [string]$DeploymentBranch = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$buildEnvironment = 'lab06'
$deployEnvironment = 'lab06-deploy'
$resourceGroupPrefixes = [ordered]@{
    Bootstrap = 'rg-caldova-lab04-bootstrap-'
    Primary = 'rg-caldova-lab04-primary-'
    Secondary = 'rg-caldova-lab04-secondary-'
    Global = 'rg-caldova-lab04-global-'
}
$deploymentOutputContracts = @{
    Bootstrap = @(
        'codeBuildIdentityName',
        'codeBuildClientId',
        'codeBuildPrincipalId',
        'codeDeploymentIdentityName',
        'codeDeploymentClientId',
        'codeDeploymentPrincipalId',
        'runtimeIdentityName',
        'runtimeIdentityId',
        'runtimeIdentityClientId',
        'runtimeIdentityPrincipalId'
    )
    Primary = @('containerRegistryName')
    Secondary = @(
        'containerAppName',
        'containerAppsEnvironmentId',
        'retailDatabaseName'
    )
    Global = @('frontDoorProfileId')
}

function Resolve-Lab04ResourceGroups {
    param(
        [string]$Bootstrap,
        [string]$Primary,
        [string]$Secondary,
        [string]$Global
    )

    $provided = [ordered]@{
        Bootstrap = $Bootstrap
        Primary = $Primary
        Secondary = $Secondary
        Global = $Global
    }
    $resourceGroupNames = @(
        az group list `
            --subscription $SubscriptionId `
            --query '[].name' `
            --output tsv
    )
    $resolved = [ordered]@{}
    foreach ($entry in $resourceGroupPrefixes.GetEnumerator()) {
        $override = $provided[$entry.Key]
        if (-not [string]::IsNullOrWhiteSpace($override)) {
            if (-not $override.StartsWith($entry.Value, [StringComparison]::OrdinalIgnoreCase)) {
                throw "$($entry.Key) resource group '$override' must start with '$($entry.Value)'."
            }
            if ($override -notin $resourceGroupNames) {
                throw "$($entry.Key) resource-group override '$override' was not found in subscription '$SubscriptionId'."
            }
            $resolved[$entry.Key] = $override
            continue
        }

        $matches = @(
            $resourceGroupNames |
                Where-Object {
                    $_.StartsWith($entry.Value, [StringComparison]::OrdinalIgnoreCase)
                }
        )
        if ($matches.Count -eq 0) {
            throw "No $($entry.Key) resource group starts with '$($entry.Value)' in subscription '$SubscriptionId'."
        }
        if ($matches.Count -gt 1) {
            throw "Multiple $($entry.Key) resource groups start with '$($entry.Value)': $($matches -join ', '). Supply -$($entry.Key)ResourceGroup to select one."
        }
        $resolved[$entry.Key] = $matches[0]
    }
    return [pscustomobject]$resolved
}

foreach ($command in @('az', 'gh')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found on PATH."
    }
}

function ConvertFrom-DeploymentOutputs {
    param(
        [Parameter(Mandatory)]
        [object]$Outputs
    )

    $values = @{}
    foreach ($output in $Outputs.PSObject.Properties) {
        $values[$output.Name] = $output.Value.value
    }
    return $values
}

function Test-RequiredOutputs {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Outputs,

        [Parameter(Mandatory)]
        [string[]]$RequiredOutputs
    )

    if ($null -eq $Outputs) {
        return $false
    }
    foreach ($name in $RequiredOutputs) {
        $property = $Outputs.PSObject.Properties[$name]
        if (
            $null -eq $property -or
            [string]::IsNullOrWhiteSpace("$($property.Value.value)")
        ) {
            return $false
        }
    }
    return $true
}

function Get-ResourceGroupDeployment {
    param(
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string[]]$RequiredOutputs,
        [string]$DeploymentName
    )

    if (-not [string]::IsNullOrWhiteSpace($DeploymentName)) {
        $deployment = az deployment group show `
            --resource-group $ResourceGroup `
            --name $DeploymentName `
            --output json | ConvertFrom-Json
        if ($deployment.properties.provisioningState -ne 'Succeeded') {
            throw "$Role deployment '$DeploymentName' in resource group '$ResourceGroup' is not in Succeeded state."
        }
        if (
            -not (Test-RequiredOutputs `
                -Outputs $deployment.properties.outputs `
                -RequiredOutputs $RequiredOutputs)
        ) {
            throw "$Role deployment '$DeploymentName' in resource group '$ResourceGroup' does not contain the required outputs: $($RequiredOutputs -join ', ')."
        }
        return $deployment
    }

    $deploymentSummaries = @(
        az deployment group list `
            --resource-group $ResourceGroup `
            --query "[?properties.provisioningState=='Succeeded']" `
            --output json | ConvertFrom-Json
    )
    $matches = @()
    foreach ($summary in $deploymentSummaries) {
        $candidate = az deployment group show `
            --resource-group $ResourceGroup `
            --name $summary.name `
            --output json | ConvertFrom-Json
        if (
            $null -ne $candidate.properties.outputs -and
            (Test-RequiredOutputs `
                -Outputs $candidate.properties.outputs `
                -RequiredOutputs $RequiredOutputs)
        ) {
            $matches += $candidate
        }
    }
    if ($matches.Count -eq 0) {
        throw "No successful $Role deployment in resource group '$ResourceGroup' contains the required outputs: $($RequiredOutputs -join ', ')."
    }

    $selected = @(
        $matches |
            Sort-Object `
                @{ Expression = { [datetime]$_.properties.timestamp }; Descending = $true },
                @{ Expression = { $_.name }; Descending = $true }
    )[0]
    Write-Host "Selected $Role deployment '$($selected.name)' from resource group '$ResourceGroup'."
    return $selected
}

function Get-RequiredDeploymentParameter {
    param(
        [Parameter(Mandatory)][object]$Deployment,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Role
    )

    $parameters = $Deployment.properties.parameters
    $property = if ($null -ne $parameters) {
        $parameters.PSObject.Properties[$Name]
    }
    else {
        $null
    }
    $value = if ($property) {
        $property.Value.value
    }
    else {
        $null
    }
    if ([string]::IsNullOrWhiteSpace("$value")) {
        throw "$Role deployment '$($Deployment.name)' does not contain required parameter '$Name'."
    }
    return [string]$value
}

function Assert-Identity {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [string]$ResourceId
    )

    $identity = az identity show `
        --name $Name `
        --resource-group $ResourceGroup `
        --output json | ConvertFrom-Json
    if (
        $identity.clientId -ne $ClientId -or
        $identity.principalId -ne $PrincipalId -or
        (
            -not [string]::IsNullOrWhiteSpace($ResourceId) -and
            $identity.id -ne $ResourceId
        )
    ) {
        throw "Managed identity '$Name' does not match the IDs persisted by the Lab 04 deployment."
    }
}

function Assert-RoleAssignment {
    param(
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Scope
    )

    $assignments = @(
        az role assignment list `
            --scope $Scope `
            --output json | ConvertFrom-Json
    )
    $matchingAssignments = @(
        $assignments | Where-Object {
            $_.principalId -eq $PrincipalId -and
            $_.roleDefinitionName -eq $Role -and
            $_.scope -eq $Scope
        }
    )
    if ($matchingAssignments.Count -ne 1) {
        throw "Expected exactly one '$Role' assignment for principal '$PrincipalId' at '$Scope', but found $($matchingAssignments.Count). Ask the instructor to repair the preprovisioned Lab 04 RBAC."
    }
}

function Set-FederatedCredential {
    param(
        [Parameter(Mandatory)][string]$IdentityName,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$ResourceGroup
    )

    $credentialName = "github-$EnvironmentName"
    $issuer = 'https://token.actions.githubusercontent.com'
    $subject = "$federatedSubjectPrefix`:environment:$EnvironmentName"
    $audience = 'api://AzureADTokenExchange'
    $existing = @(
        @(
            az identity federated-credential list `
                --identity-name $IdentityName `
                --resource-group $ResourceGroup `
                --output json | ConvertFrom-Json
        ) | Where-Object name -EQ $credentialName
    )

    if ($existing.Count -eq 0) {
        az identity federated-credential create `
            --name $credentialName `
            --identity-name $IdentityName `
            --resource-group $ResourceGroup `
            --issuer $issuer `
            --subject $subject `
            --audiences $audience `
            --output none
    }
    elseif ($existing.Count -eq 1) {
        az identity federated-credential update `
            --name $credentialName `
            --identity-name $IdentityName `
            --resource-group $ResourceGroup `
            --issuer $issuer `
            --subject $subject `
            --audiences $audience `
            --output none
    }
    else {
        throw "Managed identity '$IdentityName' has duplicate '$credentialName' federated credentials."
    }

    $verified = az identity federated-credential show `
        --name $credentialName `
        --identity-name $IdentityName `
        --resource-group $ResourceGroup `
        --output json | ConvertFrom-Json
    if (
        $verified.issuer -ne $issuer -or
        $verified.subject -ne $subject -or
        $verified.audiences.Count -ne 1 -or
        $verified.audiences[0] -ne $audience
    ) {
        throw "Federated credential verification failed for '$IdentityName/$credentialName'."
    }
}

function Invoke-GhApiWithInput {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Payload
    )

    $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $output = @(
            $Payload |
                gh api `
                    --method $Method `
                    $Path `
                    --input - `
                    --silent 2>&1
        )
        $exitCode = $LASTEXITCODE
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
    }
    if ($exitCode -ne 0) {
        $details = ($output | ForEach-Object { $_.ToString() }) -join "`n"
        throw "GitHub API $Method '$Path' failed with exit code $exitCode. $details"
    }
}

function Set-DeploymentEnvironment {
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$BranchName,
        [long]$ReviewerId,
        [switch]$WithoutRequiredReviewer
    )

    $encodedEnvironment = [Uri]::EscapeDataString($EnvironmentName)
    $environmentPath = "repos/$Repository/environments/$encodedEnvironment"
    $payloadData = @{
        deployment_branch_policy = @{
            protected_branches = $false
            custom_branch_policies = $true
        }
    }
    if (-not $WithoutRequiredReviewer) {
        $payloadData.prevent_self_review = $true
        $payloadData.reviewers = @(
            @{
                type = 'User'
                id = $ReviewerId
            }
        )
    }
    $payload = $payloadData | ConvertTo-Json -Depth 5 -Compress
    try {
        Invoke-GhApiWithInput `
            -Method PUT `
            -Path $environmentPath `
            -Payload $payload
    }
    catch {
        $guidance = if ($WithoutRequiredReviewer) {
            'Confirm that environments and deployment branch policies are supported by the repository plan and that the authenticated account has repository ADMIN permission.'
        }
        else {
            'Confirm that required reviewers are supported by the repository visibility and plan, that the reviewer has repository access, and that the authenticated account has repository ADMIN permission. For a lab repository on a plan without private-repository required reviewers, rerun with -AllowDeploymentWithoutRequiredReviewer.'
        }
        throw "Failed to configure GitHub environment '$EnvironmentName' in '$Repository'. $guidance $($_.Exception.Message)"
    }

    $policiesPath = "$environmentPath/deployment-branch-policies"
    $policies = gh api $policiesPath | ConvertFrom-Json
    foreach ($policy in $policies.branch_policies) {
        if ($policy.name -ne $BranchName) {
            gh api --method DELETE "$policiesPath/$($policy.id)" --silent
        }
    }
    if (-not ($policies.branch_policies | Where-Object name -EQ $BranchName)) {
        gh api --method POST $policiesPath -f "name=$BranchName" --silent
    }

    $verified = gh api $environmentPath | ConvertFrom-Json
    $verifiedPolicies = gh api $policiesPath | ConvertFrom-Json
    $branchConfigured = $verifiedPolicies.branch_policies |
        Where-Object name -EQ $BranchName
    $baseConfigurationValid = (
        $verified.deployment_branch_policy.custom_branch_policies -and
        $branchConfigured -and
        $verifiedPolicies.total_count -eq 1
    )
    if ($WithoutRequiredReviewer) {
        $reviewerRule = $verified.protection_rules |
            Where-Object type -EQ 'required_reviewers'
        if (-not $baseConfigurationValid -or $reviewerRule) {
            throw "GitHub environment protection verification failed for '$EnvironmentName'."
        }
        return
    }

    $reviewerRule = $verified.protection_rules |
        Where-Object type -EQ 'required_reviewers'
    $reviewerConfigured = $reviewerRule.reviewers |
        Where-Object { $_.reviewer.id -eq $ReviewerId -and $_.type -eq 'User' }
    if (
        -not $baseConfigurationValid -or
        -not $reviewerRule.prevent_self_review -or
        -not $reviewerConfigured
    ) {
        throw "GitHub environment protection verification failed for '$EnvironmentName'."
    }
}

function Set-AndVerifyVariables {
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Variables
    )

    foreach ($entry in $Variables.GetEnumerator()) {
        gh variable set $entry.Key `
            --env $EnvironmentName `
            --repo $Repository `
            --body $entry.Value
    }

    $encodedEnvironment = [Uri]::EscapeDataString($EnvironmentName)
    $response = gh api `
        "repos/$Repository/environments/$encodedEnvironment/variables?per_page=100" |
        ConvertFrom-Json
    foreach ($entry in $Variables.GetEnumerator()) {
        $matchingVariable = @(
            $response.variables | Where-Object name -EQ $entry.Key
        )
        if (
            $matchingVariable.Count -ne 1 -or
            $matchingVariable[0].value -ne "$($entry.Value)"
        ) {
            throw "GitHub variable '$($entry.Key)' verification failed in environment '$EnvironmentName'."
        }
    }
}

# A nonblank subscription wins; otherwise use the current Azure CLI account.
if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = az account show --query id --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        throw 'Failed to resolve the active Azure subscription. Sign in with az login or supply -SubscriptionId.'
    }
}

az account set --subscription $SubscriptionId
$account = az account show --output json | ConvertFrom-Json
if ($account.id -ne $SubscriptionId) {
    throw "Azure CLI selected subscription '$($account.id)' instead of '$SubscriptionId'."
}
$tenantId = [string]$account.tenantId
$resolvedResourceGroups = Resolve-Lab04ResourceGroups `
    -Bootstrap $BootstrapResourceGroup `
    -Primary $PrimaryResourceGroup `
    -Secondary $SecondaryResourceGroup `
    -Global $GlobalResourceGroup
$BootstrapResourceGroup = $resolvedResourceGroups.Bootstrap
$PrimaryResourceGroup = $resolvedResourceGroups.Primary
$SecondaryResourceGroup = $resolvedResourceGroups.Secondary
$GlobalResourceGroup = $resolvedResourceGroups.Global
Write-Host "Selected Lab 04 resource-group boundary: $BootstrapResourceGroup, $PrimaryResourceGroup, $SecondaryResourceGroup, $GlobalResourceGroup"

gh auth status
if (
    -not [string]::IsNullOrWhiteSpace($Repository) -and
    $Repository -notmatch '^[^/]+/[^/]+$'
) {
    throw "Repository must use the 'owner/name' format. Received '$Repository'."
}
$repositoryInfo = if ([string]::IsNullOrWhiteSpace($Repository)) {
    gh repo view --json nameWithOwner,viewerPermission | ConvertFrom-Json
}
else {
    gh repo view $Repository --json nameWithOwner,viewerPermission |
        ConvertFrom-Json
}
$Repository = [string]$repositoryInfo.nameWithOwner
if ($repositoryInfo.viewerPermission -ne 'ADMIN') {
    throw "GitHub environment configuration requires ADMIN permission on '$Repository'. The authenticated account has '$($repositoryInfo.viewerPermission)' permission."
}

$oidcConfiguration = gh api `
    --header 'X-GitHub-Api-Version: 2026-03-10' `
    "repos/$Repository/actions/oidc/customization/sub" |
    ConvertFrom-Json
if (-not $oidcConfiguration.use_default) {
    throw "Repository '$Repository' uses a custom GitHub OIDC subject template. Lab 06 requires the default environment-scoped subject template."
}
$federatedSubjectPrefix = [string]$oidcConfiguration.sub_claim_prefix
if (
    [string]::IsNullOrWhiteSpace($federatedSubjectPrefix) -or
    -not $federatedSubjectPrefix.StartsWith('repo:')
) {
    throw "GitHub did not return a valid OIDC subject prefix for '$Repository'."
}

$withoutRequiredReviewer = $PSCmdlet.ParameterSetName -eq 'Unprotected'
$reviewerId = if ($withoutRequiredReviewer) {
    Write-Warning 'lab06-deploy will not require manual approval because -AllowDeploymentWithoutRequiredReviewer was specified.'
    $null
}
else {
    $resolvedReviewerId = gh api "users/$RequiredReviewer" --jq '.id'
    if (-not $resolvedReviewerId) {
        throw "Unable to resolve GitHub reviewer '$RequiredReviewer'. Supply an individual GitHub login with repository access."
    }
    [long]$resolvedReviewerId
}

$bootstrapDeployment = Get-ResourceGroupDeployment `
    -Role Bootstrap `
    -ResourceGroup $BootstrapResourceGroup `
    -RequiredOutputs $deploymentOutputContracts.Bootstrap `
    -DeploymentName $BootstrapDeploymentName
$primaryDeployment = Get-ResourceGroupDeployment `
    -Role Primary `
    -ResourceGroup $PrimaryResourceGroup `
    -RequiredOutputs $deploymentOutputContracts.Primary `
    -DeploymentName $PrimaryDeploymentName
$secondaryDeployment = Get-ResourceGroupDeployment `
    -Role Secondary `
    -ResourceGroup $SecondaryResourceGroup `
    -RequiredOutputs $deploymentOutputContracts.Secondary `
    -DeploymentName $SecondaryDeploymentName
$globalDeployment = Get-ResourceGroupDeployment `
    -Role Global `
    -ResourceGroup $GlobalResourceGroup `
    -RequiredOutputs $deploymentOutputContracts.Global `
    -DeploymentName $GlobalDeploymentName

$selectedDeployments = [ordered]@{
    Bootstrap = $bootstrapDeployment
    Primary = $primaryDeployment
    Secondary = $secondaryDeployment
    Global = $globalDeployment
}
$prefixes = @{}
$suffixes = @{}
foreach ($entry in $selectedDeployments.GetEnumerator()) {
    $prefixes[$entry.Key] = Get-RequiredDeploymentParameter `
        -Deployment $entry.Value `
        -Name prefix `
        -Role $entry.Key
    $suffixes[$entry.Key] = Get-RequiredDeploymentParameter `
        -Deployment $entry.Value `
        -Name suffix `
        -Role $entry.Key
}
$distinctPrefixes = @($prefixes.Values | Sort-Object -Unique)
$distinctSuffixes = @($suffixes.Values | Sort-Object -Unique)
if ($distinctPrefixes.Count -ne 1 -or $distinctSuffixes.Count -ne 1) {
    $selection = $selectedDeployments.GetEnumerator() | ForEach-Object {
        "$($_.Key)=$($_.Value.name) (prefix=$($prefixes[$_.Key]), suffix=$($suffixes[$_.Key]))"
    }
    throw "Selected deployments do not belong to one Lab 04 boundary: $($selection -join '; '). Use the per-role deployment-name overrides to select a consistent set."
}

$bootstrapOutputs = ConvertFrom-DeploymentOutputs `
    -Outputs $bootstrapDeployment.properties.outputs
$primaryOutputs = ConvertFrom-DeploymentOutputs `
    -Outputs $primaryDeployment.properties.outputs
$secondaryOutputs = ConvertFrom-DeploymentOutputs `
    -Outputs $secondaryDeployment.properties.outputs
$globalOutputs = ConvertFrom-DeploymentOutputs `
    -Outputs $globalDeployment.properties.outputs
$values = @{
    LAB04_BOOTSTRAP_RESOURCE_GROUP = $BootstrapResourceGroup
    LAB04_PRIMARY_RESOURCE_GROUP = $PrimaryResourceGroup
    LAB04_SECONDARY_RESOURCE_GROUP = $SecondaryResourceGroup
    LAB04_GLOBAL_RESOURCE_GROUP = $GlobalResourceGroup
    LAB04_PREFIX = $distinctPrefixes[0]
    LAB04_SUFFIX = $distinctSuffixes[0]
    LAB06_BUILD_AZURE_CLIENT_ID = $bootstrapOutputs.codeBuildClientId
    LAB06_BUILD_AZURE_PRINCIPAL_ID = $bootstrapOutputs.codeBuildPrincipalId
    LAB06_BUILD_IDENTITY_NAME = $bootstrapOutputs.codeBuildIdentityName
    LAB06_DEPLOY_AZURE_CLIENT_ID = $bootstrapOutputs.codeDeploymentClientId
    LAB06_DEPLOY_AZURE_PRINCIPAL_ID = $bootstrapOutputs.codeDeploymentPrincipalId
    LAB06_DEPLOYMENT_IDENTITY_NAME = $bootstrapOutputs.codeDeploymentIdentityName
    LAB06_RUNTIME_IDENTITY_NAME = $bootstrapOutputs.runtimeIdentityName
    LAB06_RUNTIME_IDENTITY_RESOURCE_ID = $bootstrapOutputs.runtimeIdentityId
    LAB06_RUNTIME_IDENTITY_CLIENT_ID = $bootstrapOutputs.runtimeIdentityClientId
    LAB06_RUNTIME_IDENTITY_PRINCIPAL_ID = $bootstrapOutputs.runtimeIdentityPrincipalId
    LAB06_CONTAINER_REGISTRY_NAME = $primaryOutputs.containerRegistryName
    LAB06_CONTAINER_APP_NAME = $secondaryOutputs.containerAppName
    FRONT_DOOR_PROFILE_ID = $globalOutputs.frontDoorProfileId
}
$bootstrapResourceGroup = [string]$values.LAB04_BOOTSTRAP_RESOURCE_GROUP

Assert-Identity `
    -Name $values.LAB06_BUILD_IDENTITY_NAME `
    -ClientId $values.LAB06_BUILD_AZURE_CLIENT_ID `
    -PrincipalId $values.LAB06_BUILD_AZURE_PRINCIPAL_ID `
    -ResourceGroup $bootstrapResourceGroup
Assert-Identity `
    -Name $values.LAB06_DEPLOYMENT_IDENTITY_NAME `
    -ClientId $values.LAB06_DEPLOY_AZURE_CLIENT_ID `
    -PrincipalId $values.LAB06_DEPLOY_AZURE_PRINCIPAL_ID `
    -ResourceGroup $bootstrapResourceGroup
Assert-Identity `
    -Name $values.LAB06_RUNTIME_IDENTITY_NAME `
    -ClientId $values.LAB06_RUNTIME_IDENTITY_CLIENT_ID `
    -PrincipalId $values.LAB06_RUNTIME_IDENTITY_PRINCIPAL_ID `
    -ResourceGroup $bootstrapResourceGroup `
    -ResourceId $values.LAB06_RUNTIME_IDENTITY_RESOURCE_ID

$registryId = az acr show `
    --name $values.LAB06_CONTAINER_REGISTRY_NAME `
    --resource-group $values.LAB04_PRIMARY_RESOURCE_GROUP `
    --query id `
    --output tsv
$containerAppId = az containerapp show `
    --name $values.LAB06_CONTAINER_APP_NAME `
    --resource-group $values.LAB04_SECONDARY_RESOURCE_GROUP `
    --query id `
    --output tsv
$frontDoorProfileId = az resource show `
    --ids $values.FRONT_DOOR_PROFILE_ID `
    --api-version 2024-02-01 `
    --query id `
    --output tsv
if ([string]::IsNullOrWhiteSpace($registryId)) {
    throw "Container registry '$($values.LAB06_CONTAINER_REGISTRY_NAME)' was not found."
}
if ([string]::IsNullOrWhiteSpace($containerAppId)) {
    throw "Container App '$($values.LAB06_CONTAINER_APP_NAME)' was not found."
}
if (
    [string]::IsNullOrWhiteSpace($frontDoorProfileId) -or
    $frontDoorProfileId -ne $values.FRONT_DOOR_PROFILE_ID
) {
    throw "Front Door profile '$($values.FRONT_DOOR_PROFILE_ID)' was not found."
}

Assert-RoleAssignment `
    -PrincipalId $values.LAB06_BUILD_AZURE_PRINCIPAL_ID `
    -Role AcrPush `
    -Scope $registryId
Assert-RoleAssignment `
    -PrincipalId $values.LAB06_DEPLOY_AZURE_PRINCIPAL_ID `
    -Role 'Container Apps Contributor' `
    -Scope $containerAppId
Assert-RoleAssignment `
    -PrincipalId $values.LAB06_DEPLOY_AZURE_PRINCIPAL_ID `
    -Role Reader `
    -Scope $values.FRONT_DOOR_PROFILE_ID

$buildPrincipalId = [string]$values.LAB06_BUILD_AZURE_PRINCIPAL_ID
if ([string]::IsNullOrWhiteSpace($buildPrincipalId)) {
    throw 'The build identity principal ID is missing.'
}

# AcrPush covers image data; Reader allows the workflow to inspect registry metadata.
$readerAssignments = az role assignment list `
    --subscription $SubscriptionId `
    --assignee-object-id $buildPrincipalId `
    --scope $registryId `
    --include-inherited `
    --role Reader `
    --output json `
    --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to inspect the build identity registry Reader assignments.'
}

if (@($readerAssignments | ConvertFrom-Json -ErrorAction Stop).Count -eq 0) {
    az role assignment create `
        --subscription $SubscriptionId `
        --assignee-object-id $buildPrincipalId `
        --assignee-principal-type ServicePrincipal `
        --role Reader `
        --scope $registryId `
        --output none `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to grant the build identity Reader on the container registry.'
    }
}

try {
    gh api `
        --method PUT `
        "repos/$Repository/environments/$buildEnvironment" `
        --silent
}
catch {
    throw "Failed to create GitHub environment '$buildEnvironment' in '$Repository'. Confirm that environments are supported by the repository plan and that the authenticated account has repository ADMIN permission. $($_.Exception.Message)"
}
Set-DeploymentEnvironment `
    -EnvironmentName $deployEnvironment `
    -ReviewerId $reviewerId `
    -BranchName $DeploymentBranch `
    -WithoutRequiredReviewer:$withoutRequiredReviewer

Set-FederatedCredential `
    -IdentityName $values.LAB06_BUILD_IDENTITY_NAME `
    -EnvironmentName $buildEnvironment `
    -ResourceGroup $bootstrapResourceGroup
Set-FederatedCredential `
    -IdentityName $values.LAB06_DEPLOYMENT_IDENTITY_NAME `
    -EnvironmentName $deployEnvironment `
    -ResourceGroup $bootstrapResourceGroup

$commonVariables = [ordered]@{
    AZURE_TENANT_ID = $tenantId
    AZURE_SUBSCRIPTION_ID = $SubscriptionId
    LAB06_CONTAINER_REGISTRY_NAME = $values.LAB06_CONTAINER_REGISTRY_NAME
    LAB06_CONTAINER_APP_NAME = $values.LAB06_CONTAINER_APP_NAME
    LAB06_RUNTIME_IDENTITY_RESOURCE_ID = $values.LAB06_RUNTIME_IDENTITY_RESOURCE_ID
    LAB06_RUNTIME_IDENTITY_CLIENT_ID = $values.LAB06_RUNTIME_IDENTITY_CLIENT_ID
    LAB04_PRIMARY_RESOURCE_GROUP = $values.LAB04_PRIMARY_RESOURCE_GROUP
    LAB04_SECONDARY_RESOURCE_GROUP = $values.LAB04_SECONDARY_RESOURCE_GROUP
    LAB04_GLOBAL_RESOURCE_GROUP = $values.LAB04_GLOBAL_RESOURCE_GROUP
    LAB04_PREFIX = $values.LAB04_PREFIX
    LAB04_SUFFIX = $values.LAB04_SUFFIX
}
$buildVariables = [ordered]@{ AZURE_CLIENT_ID = $values.LAB06_BUILD_AZURE_CLIENT_ID }
$deployVariables = [ordered]@{ AZURE_CLIENT_ID = $values.LAB06_DEPLOY_AZURE_CLIENT_ID }
foreach ($entry in $commonVariables.GetEnumerator()) {
    $buildVariables[$entry.Key] = $entry.Value
    $deployVariables[$entry.Key] = $entry.Value
}

Set-AndVerifyVariables `
    -EnvironmentName $buildEnvironment `
    -Variables $buildVariables
Set-AndVerifyVariables `
    -EnvironmentName $deployEnvironment `
    -Variables $deployVariables

Write-Host ''
Write-Host 'Lab 06 GitHub OIDC bootstrap completed.'
Write-Host "Repository: $Repository"
Write-Host "OIDC subject prefix: $federatedSubjectPrefix"
Write-Host "Bootstrap deployment: $($bootstrapDeployment.name) ($BootstrapResourceGroup)"
Write-Host "Primary deployment: $($primaryDeployment.name) ($PrimaryResourceGroup)"
Write-Host "Secondary deployment: $($secondaryDeployment.name) ($SecondaryResourceGroup)"
Write-Host "Global deployment: $($globalDeployment.name) ($GlobalResourceGroup)"
Write-Host "Build environment and identity: $buildEnvironment / $($values.LAB06_BUILD_IDENTITY_NAME)"
Write-Host "Deployment environment and identity: $deployEnvironment / $($values.LAB06_DEPLOYMENT_IDENTITY_NAME)"
if ($withoutRequiredReviewer) {
    Write-Warning 'Deployment protection mode: branch restriction only; no required reviewer is configured.'
}
else {
    Write-Host "Required reviewer: $RequiredReviewer"
}
Write-Host "Deployment branch: $DeploymentBranch"
