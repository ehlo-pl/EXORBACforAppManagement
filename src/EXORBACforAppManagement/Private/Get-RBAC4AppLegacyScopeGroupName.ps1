function Get-RBAC4AppLegacyScopeGroupName {
    # Pre-0.9.0 guard shared by Set-/Test-/Remove-RBAC4AppEntry. Before 0.9.0 the default scope group
    # was a DistributionList ('UDLRAo1P-{DisplayName}'); it is now a CloudMailEnabledSecurityGroup
    # ('USRACo1P-{DisplayName}'). Returns the old list's name when the caller relied on the defaults
    # (no -AccessGroupType, -AccessGroupName, or -GroupPrefix), the list exists, and the cloud group
    # (CurrentGroupName) does not - i.e. an application provisioned before 0.9.0 that the defaults
    # would now point at the wrong group. Returns $null otherwise, including once the cloud group
    # exists (the application was moved deliberately).
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $BoundParameters,

        [Parameter(Mandatory)]
        [string] $AccessGroupType,

        [Parameter(Mandatory)]
        [string] $CurrentGroupName,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $DisplayName,

        [Parameter()]
        [string] $AppId
    )

    foreach ($explicit in 'AccessGroupType', 'AccessGroupName', 'GroupPrefix') {
        if ($BoundParameters.ContainsKey($explicit)) { return $null }
    }
    if ($AccessGroupType -ne 'CloudMailEnabledSecurityGroup') { return $null }

    $legacyGroupName = Get-RBAC4AppScopeGroupName -Prefix (Get-RBAC4AppDefaultGroupPrefix -AccessGroupType 'DistributionList') -DisplayName $DisplayName -AppId $AppId
    if ($legacyGroupName -eq $CurrentGroupName) { return $null }
    if (-not (Get-DistributionGroup -Identity $legacyGroupName -ErrorAction SilentlyContinue)) { return $null }
    if (Get-DistributionGroup -Identity $CurrentGroupName -ErrorAction SilentlyContinue) { return $null }
    $legacyGroupName
}
