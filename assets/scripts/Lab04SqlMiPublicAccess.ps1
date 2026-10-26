function Test-Lab04AffirmativeResponse {
    param(
        [AllowEmptyString()]
        [string]$Response
    )

    return $Response.Trim() -imatch '^(y|yes)$'
}

function New-Lab04SqlMiParticipantRuleName {
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$AccountName
    )

    $values = @($SubscriptionId, $TenantId, $AccountName)
    if ($values.Where({ [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw 'Subscription, tenant, and signed-in account metadata are required to generate the SQL MI access rule name.'
    }

    $normalizedValues = $values.ForEach({
        $_.Trim().ToLowerInvariant()
    })
    $hashInput = [Text.Encoding]::UTF8.GetBytes($normalizedValues -join '|')
    $hash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($hashInput)
    ).ToLowerInvariant()

    return "AllowSqlMi-$($hash.Substring(0, 32))"
}
