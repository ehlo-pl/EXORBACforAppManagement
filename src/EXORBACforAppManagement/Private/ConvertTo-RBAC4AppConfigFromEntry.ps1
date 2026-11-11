function ConvertTo-RBAC4AppConfigFromEntry {
    # Builds one Invoke-RBAC4AppConfig config from one or more RBAC4App.Entry rows that share the
    # same application and the same resolved recipient scope (all their roles go into Rbac.Roles).
    # No side effects: returns { Config; SafeName; Warnings; Error; NeedsForce } and leaves writing,
    # warnings, and errors to the caller (Export-RBAC4AppConfig).
    #
    # Guessed data is refused unless -Force:
    #   - a row whose service principal was resolved by the name heuristic
    #     (ServicePrincipalIdSource 'NameHeuristic');
    #   - a Group/GroupDirect scope whose group could not be read (ScopeGroupResolved $false). With
    #     -Force it is exported as a reference-only MailEnabledSecurityGroup with no members, so
    #     Invoke-RBAC4AppConfig validates the group instead of creating an empty one.
    # Either way the reason lands in the config's Runtime.CollectedWarnings.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object[]] $Entry,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $BaseName,

        [Parameter()]
        [switch] $Force
    )

    $rows = @($Entry | Where-Object { $_ })
    $label = ($rows | ForEach-Object { [string]$_.Name }) -join "', '"
    $configWarnings = [System.Collections.Generic.List[string]]::new()
    $newWarnings = [System.Collections.Generic.List[string]]::new()
    foreach ($w in @($rows | ForEach-Object { $_.Warnings } | Where-Object { $_ } | Select-Object -Unique)) { $configWarnings.Add([string]$w) }

    $result = [pscustomobject]@{ Config = $null; SafeName = $null; Warnings = @(); Error = $null; NeedsForce = $false }
    $fail = {
        param([string] $Message, [bool] $NeedsForce = $false)
        $result.Error = $Message
        $result.NeedsForce = $NeedsForce
        $result.Warnings = @($newWarnings)
        $result
    }

    $first = $rows[0]
    $appId = [string]$first.AppId
    $spObjectId = [string](@($rows | Where-Object { $_.ServicePrincipalId } | ForEach-Object { $_.ServicePrincipalId }) | Select-Object -First 1)
    $displayName = [string]$first.DisplayName
    if (-not $appId -or -not $spObjectId) {
        return & $fail ("Cannot export role assignment '{0}' because its service principal AppId and object id could not be resolved." -f $label)
    }

    if (@($rows | Where-Object { $_.ServicePrincipalIdSource -eq 'NameHeuristic' }).Count -gt 0) {
        $msg = "Role assignment '{0}': the application identity was inferred from the generated role assignment name, not read from Exchange Online." -f $label
        if (-not $Force) {
            return & $fail ("Cannot export role assignment '{0}' without -Force because its application identity was inferred from the role assignment name; verify AppId '{1}' and SpObjectId '{2}', then re-run with -Force." -f $label, $appId, $spObjectId) $true
        }
        $configWarnings.Add($msg)
    }

    $nonAppRole = $rows | Where-Object { [string]$_.Role -notlike 'Application *' } | Select-Object -First 1
    if ($nonAppRole) {
        return & $fail ("Cannot export role assignment '{0}' because '{1}' is not an application role." -f $nonAppRole.Name, $nonAppRole.Role)
    }

    $isGroupDirect = [string]$first.ScopeKind -eq 'GroupDirect'
    $scopeKind = if ($isGroupDirect) { 'Group' } else { [string]$first.ScopeKind }
    if ($scopeKind -notin @('Group', 'Recipients', 'Tag', 'Filter')) {
        return & $fail ("Cannot export role assignment '{0}' because its recipient scope could not be resolved to a supported config scope." -f $label)
    }

    $groupName = if ($first.ScopeGroupName) { [string]$first.ScopeGroupName } else { [string]$first.Scope }
    $accessGroupType = 'DistributionList'
    $members = @()
    if ($scopeKind -eq 'Group') {
        if (-not $groupName) {
            return & $fail ("Cannot export role assignment '{0}' because its scope group name could not be resolved." -f $label)
        }
        if ($first.ScopeGroupResolved -and $first.ScopeGroupType -in @('M365Group', 'DistributionList', 'MailEnabledSecurityGroup')) {
            $accessGroupType = [string]$first.ScopeGroupType
            $members = @($first.ScopeMembers | Where-Object { $_ })
        }
        elseif (-not $Force) {
            return & $fail ("Cannot export role assignment '{0}' without -Force because its scope group '{1}' could not be read (deleted, renamed, or not visible to this session). -Force exports it as a reference-only MailEnabledSecurityGroup that Invoke-RBAC4AppConfig validates but never creates." -f $label, $groupName) $true
        }
        else {
            $accessGroupType = 'MailEnabledSecurityGroup'
            $msg = "Role assignment '{0}': scope group '{1}' could not be read; exported as reference-only AccessGroupType 'MailEnabledSecurityGroup' with no members - review the config before using it." -f $label, $groupName
            $configWarnings.Add($msg)
            $newWarnings.Add($msg)
        }
    }

    $scopeTagAttribute = 'CustomAttribute1'
    $scopeTagValue = ''
    $scopeFilter = ''
    if ($scopeKind -eq 'Tag' -and [string]$first.ScopeFilter -match "(?i)^\s*(CustomAttribute(?:[1-9]|1[0-5]))\s+-eq\s+'((?:''|[^'])*)'\s*$") {
        $scopeTagAttribute = $Matches[1]
        $scopeTagValue = $Matches[2].Replace("''", "'")
    }
    elseif ($scopeKind -eq 'Tag') {
        $scopeKind = 'Filter'
        $scopeFilter = [string]$first.ScopeFilter
    }
    elseif ($scopeKind -eq 'Filter') {
        $scopeFilter = [string]$first.ScopeFilter
    }

    $scopeRecipients = if ($scopeKind -eq 'Recipients') { @($first.ScopeMembers | Where-Object { $_ }) } else { @() }
    if (($scopeKind -eq 'Recipients' -and $scopeRecipients.Count -eq 0) -or ($scopeKind -eq 'Filter' -and -not $scopeFilter)) {
        return & $fail ("Cannot export role assignment '{0}' because its {1} scope data is incomplete." -f $label, $scopeKind)
    }

    $roles = @($rows | ForEach-Object { [string]$_.Role } | Sort-Object -Unique)
    $result.Config = ConvertTo-RBAC4AppConfig `
        -AppId $appId `
        -SpObjectId $spObjectId `
        -DisplayName $displayName `
        -Roles $roles `
        -AccessGroupType $accessGroupType `
        -GroupPrefix (Get-RBAC4AppDefaultGroupPrefix -AccessGroupType $accessGroupType) `
        -AccessGroupName $(if ($scopeKind -eq 'Group') { $groupName } else { '' }) `
        -Members $members `
        -ManagedBy @('GraphAPI-Dummy-owner') `
        -ScopeKind $scopeKind `
        -AssignmentScope $(if ($isGroupDirect) { 'RecipientGroupScope' } else { 'ManagementScope' }) `
        -ManagementScopeName $(if ($first.ManagementScope) { [string]$first.ManagementScope } else { '' }) `
        -ManagementScopePrefix $script:RBAC4AppDefaultManagementScopePrefix `
        -ScopeRecipients $scopeRecipients `
        -ScopeTagAttribute $scopeTagAttribute `
        -ScopeTagValue $scopeTagValue `
        -ScopeFilter $scopeFilter `
        -CollectedWarnings @($configWarnings)

    $safeName = Format-RBAC4AppSafeName -Value $BaseName -MaxLength 120
    if (-not $safeName) {
        $safeName = Format-RBAC4AppSafeName -Value ("{0}-{1}" -f $displayName, ($roles -join '-')) -MaxLength 120
    }
    $result.SafeName = $safeName
    $result.Warnings = @($newWarnings)
    $result
}
