function Resolve-RBAC4AppScope {
    # Resolves a Get-ManagementRoleAssignment object's full recipient scope.
    #
    # Management scope model (0.7.0+): when the assignment is bound to a named management scope
    # (CustomResourceScope / CustomRecipientWriteScope holding a plain scope name rather than EXO's
    # hidden "<Group>_<GUID>" group scope), the scope is read via Get-ManagementScope and its
    # RecipientFilter classified with ConvertFrom-RBAC4AppRecipientFilter:
    #
    #   Group      - MemberOfGroup -eq '<DN>': the DN is resolved to the group via Get-Recipient,
    #                then probed for type/membership exactly like a legacy group scope.
    #   Recipients - PrimarySmtpAddress list: the addresses ARE the members (no extra call).
    #   Tag/Filter - members previewed via Get-Recipient -RecipientPreviewFilter, capped at
    #                -PreviewLimit (a warning is written when the cap is hit).
    #
    # Legacy model (fallback): the assignment is scoped directly to a group (-RecipientGroupScope);
    # the group name is recovered via Resolve-RBAC4AppScopeGroupName and ScopeKind is 'GroupDirect'.
    #
    # Group type is determined by probing Get-UnifiedGroup first (M365Group), then
    # Get-DistributionGroup - whose RecipientTypeDetails distinguishes a plain distribution list
    # from a mail-enabled security group ('MailUniversalSecurityGroup').
    #
    # Results are cached per distinct scope / group name in the caller-supplied $Cache hashtable.
    #
    # Returns a [pscustomobject] with ScopeName (the scope group name for Group/GroupDirect kinds,
    # otherwise the management scope name), ScopeGroupName, ScopeGroupType, Members (always an
    # array), ManagementScope, ScopeKind, and ScopeFilter. Never throws; unresolvable pieces
    # produce a warning and empty values.
    param(
        [Parameter(Mandatory)]
        [psobject] $Assignment,

        [Parameter(Mandatory)]
        [hashtable] $Cache,

        [Parameter()]
        [int] $PreviewLimit = 1000
    )

    $guidSuffix = '_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

    function Get-MemberAddress([object[]] $items) {
        @($items | ForEach-Object {
                if ($_.PrimarySmtpAddress) { [string]$_.PrimarySmtpAddress } else { [string]$_.Name }
            } | Where-Object { $_ } | Sort-Object -Unique)
    }

    function Get-GroupInfo([string] $groupName) {
        $key = "group:$groupName"
        if ($Cache.ContainsKey($key)) { return $Cache[$key] }

        $groupType = $null
        $members = @()
        if (Get-UnifiedGroup -Identity $groupName -ErrorAction SilentlyContinue) {
            $groupType = 'M365Group'
            $members = Get-MemberAddress @(Get-UnifiedGroupLinks -Identity $groupName -LinkType Members -ErrorAction SilentlyContinue)
        }
        else {
            $dist = Get-DistributionGroup -Identity $groupName -ErrorAction SilentlyContinue
            if ($dist) {
                $groupType = if ([string]$dist.RecipientTypeDetails -eq 'MailUniversalSecurityGroup') { 'MailEnabledSecurityGroup' } else { 'DistributionList' }
                $members = Get-MemberAddress @(Get-DistributionGroupMember -Identity $groupName -ErrorAction SilentlyContinue)
            }
            else {
                Write-Warning -Message ("Could not resolve scope group '{0}' via Get-UnifiedGroup or Get-DistributionGroup; its type and membership will be omitted." -f $groupName)
            }
        }

        $info = [pscustomobject]@{ ScopeGroupType = $groupType; Members = @($members) }
        $Cache[$key] = $info
        $info
    }

    function ConvertTo-ScopeResult($scopeName, $groupName, $groupType, $members, $managementScope, $kind, $filter) {
        [pscustomobject][ordered]@{
            ScopeName       = $scopeName
            ScopeGroupName  = $groupName
            ScopeGroupType  = $groupType
            Members         = @($members | Where-Object { $_ } | Sort-Object -Unique)
            ManagementScope = $managementScope
            ScopeKind       = $kind
            ScopeFilter     = $filter
        }
    }

    # --- Management scope candidate: a plain (non-GUID-suffixed) scope name.
    $candidate = $null
    $resourceScope = [string]$Assignment.CustomResourceScope
    if ($resourceScope -and $resourceScope -notmatch $guidSuffix) {
        $candidate = $resourceScope
    }
    elseif ([string]$Assignment.RecipientWriteScope -eq 'CustomRecipientScope' -and $Assignment.CustomRecipientWriteScope) {
        $candidate = [string]$Assignment.CustomRecipientWriteScope
    }

    if ($candidate) {
        $key = "scope:$candidate"
        if (-not $Cache.ContainsKey($key)) {
            $scopeObj = $null
            try { $scopeObj = Get-ManagementScope -Identity $candidate -ErrorAction Stop | Select-Object -First 1 }
            catch { Write-Verbose -Message "'$candidate' is not a readable management scope: $($_.Exception.Message)" }

            $resolved = $null
            if ($scopeObj) {
                $filter = [string]$scopeObj.RecipientFilter
                if (-not $filter) { $filter = [string]$scopeObj.RecipientRestrictionFilter }
                $parsed = ConvertFrom-RBAC4AppRecipientFilter -Filter $filter

                switch ($parsed.ScopeKind) {
                    'Group' {
                        $dn = $parsed.GroupDistinguishedName
                        $rec = Get-Recipient -Identity $dn -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($rec) {
                            $groupName = [string]$rec.Name
                            if (-not $groupName) { $groupName = [string]$rec.DisplayName }
                            $info = Get-GroupInfo $groupName
                            $resolved = ConvertTo-ScopeResult $groupName $groupName $info.ScopeGroupType $info.Members $candidate 'Group' $filter
                        }
                        else {
                            Write-Warning -Message ("Could not resolve the group '{0}' referenced by management scope '{1}'; its type and membership will be omitted." -f $dn, $candidate)
                            $resolved = ConvertTo-ScopeResult $dn $dn $null @() $candidate 'Group' $filter
                        }
                    }
                    'Recipients' {
                        $resolved = ConvertTo-ScopeResult $candidate $null $null $parsed.Recipients $candidate 'Recipients' $filter
                    }
                    default {
                        $members = @()
                        if ($filter) {
                            $preview = @(Get-Recipient -RecipientPreviewFilter $filter -ResultSize $PreviewLimit -ErrorAction SilentlyContinue)
                            if ($preview.Count -ge $PreviewLimit) {
                                Write-Warning -Message ("Management scope '{0}' matches at least {1} recipients; ScopeMembers is truncated." -f $candidate, $PreviewLimit)
                            }
                            $members = Get-MemberAddress $preview
                        }
                        $kind = if ($parsed.ScopeKind) { $parsed.ScopeKind } else { 'Filter' }
                        $resolved = ConvertTo-ScopeResult $candidate $null $null $members $candidate $kind $filter
                    }
                }
            }
            $Cache[$key] = $resolved
        }
        if ($Cache[$key]) { return $Cache[$key] }
    }

    # --- Legacy: assignment scoped directly to a group (-RecipientGroupScope).
    $groupName = Resolve-RBAC4AppScopeGroupName -Assignment $Assignment
    if (-not $groupName) {
        return ConvertTo-ScopeResult $null $null $null @() $null $null $null
    }
    $info = Get-GroupInfo $groupName
    ConvertTo-ScopeResult $groupName $groupName $info.ScopeGroupType $info.Members $null 'GroupDirect' $null
}