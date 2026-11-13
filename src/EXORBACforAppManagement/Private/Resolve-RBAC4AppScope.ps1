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
    # from a mail-enabled security group ('MailUniversalSecurityGroup') - and, when neither finds
    # it, Get-Recipient -Anr (exact Name/DisplayName/Alias match, or a single group hit), typed by
    # RecipientTypeDetails (GroupMailbox = M365Group). A mail-enabled security group is
    # CloudMailEnabledSecurityGroup only when it reports IsDirSynced = $false (Exchange-Online
    # mastered, so Invoke-RBAC4AppConfig may manage it); a synced one - or one whose IsDirSynced is
    # unknown - is HybridMailEnabledSecurityGroup (reference-only), the safe default.
    #
    # Results are cached per distinct scope / group name in the caller-supplied $Cache hashtable.
    #
    # Returns a [pscustomobject] with ScopeName (the scope group name for Group/GroupDirect kinds,
    # otherwise the management scope name), ScopeGroupName, ScopeGroupType, Members (always an
    # array), ManagementScope, ScopeKind, ScopeFilter, Source (ManagementScope, Legacy, or None),
    # GroupResolved (whether a Group/GroupDirect scope group was actually read), and Warnings
    # (string[]). Never throws and never writes warnings itself: unresolvable pieces produce empty
    # values plus a message in Warnings, and the caller decides how to surface it.
    #
    # An assignment bound to a custom recipient scope (RecipientWriteScope CustomRecipientScope)
    # whose management scope cannot be read returns ScopeKind $null with a warning; it is never
    # looked up as a legacy group, because that name is a scope name, not a group name.
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

    # Mail-enabled security group -> Cloud (IsDirSynced reported $false) or Hybrid (synced/unknown).
    $securityGroupType = {
        param($group)
        $dirSynced = $group.PSObject.Properties['IsDirSynced']
        if ($dirSynced -and $null -ne $dirSynced.Value -and -not [bool]$dirSynced.Value) { 'CloudMailEnabledSecurityGroup' }
        else { 'HybridMailEnabledSecurityGroup' }
    }

    function Get-GroupInfo([string] $groupName) {
        $key = "group:$groupName"
        if ($Cache.ContainsKey($key)) { return $Cache[$key] }

        $groupType = $null
        $members = @()
        $groupWarnings = @()
        if (Get-UnifiedGroup -Identity $groupName -ErrorAction SilentlyContinue) {
            $groupType = 'M365Group'
            $members = Get-MemberAddress @(Get-UnifiedGroupLinks -Identity $groupName -LinkType Members -ErrorAction SilentlyContinue)
        }
        else {
            $dist = Get-DistributionGroup -Identity $groupName -ErrorAction SilentlyContinue
            if ($dist) {
                $groupType = if ([string]$dist.RecipientTypeDetails -eq 'MailUniversalSecurityGroup') { & $securityGroupType $dist } else { 'DistributionList' }
                $members = Get-MemberAddress @(Get-DistributionGroupMember -Identity $groupName -ErrorAction SilentlyContinue)
            }
            else {
                # Last resort: ambiguous name resolution. The stored name may be a display name, an
                # alias, or otherwise not a valid -Identity (e.g. renamed group), which ANR still
                # finds. Prefer an exact Name/DisplayName/Alias match; accept a lone group hit.
                $anrHit = $null
                try {
                    $candidates = @(Get-Recipient -Anr $groupName -ResultSize 50 -ErrorAction Stop |
                            Where-Object { [string]$_.RecipientTypeDetails -in @('GroupMailbox', 'MailUniversalDistributionGroup', 'MailNonUniversalGroup', 'MailUniversalSecurityGroup') })
                    $anrHit = $candidates | Where-Object {
                        $groupName -in @([string]$_.Name, [string]$_.DisplayName, [string]$_.Alias)
                    } | Select-Object -First 1
                    if (-not $anrHit -and $candidates.Count -eq 1) { $anrHit = $candidates[0] }
                }
                catch {
                    Write-Verbose ("Get-Recipient -Anr '{0}' failed: {1}" -f $groupName, $_.Exception.Message)
                }

                if ($anrHit) {
                    $anrIdentity = if ($anrHit.Guid) { [string]$anrHit.Guid } elseif ($anrHit.Identity) { [string]$anrHit.Identity } else { [string]$anrHit.Name }
                    switch ([string]$anrHit.RecipientTypeDetails) {
                        'GroupMailbox' {
                            $groupType = 'M365Group'
                            $members = Get-MemberAddress @(Get-UnifiedGroupLinks -Identity $anrIdentity -LinkType Members -ErrorAction SilentlyContinue)
                        }
                        'MailUniversalSecurityGroup' {
                            $groupType = & $securityGroupType $anrHit
                            $members = Get-MemberAddress @(Get-DistributionGroupMember -Identity $anrIdentity -ErrorAction SilentlyContinue)
                        }
                        default {
                            $groupType = 'DistributionList'
                            $members = Get-MemberAddress @(Get-DistributionGroupMember -Identity $anrIdentity -ErrorAction SilentlyContinue)
                        }
                    }
                    Write-Verbose ("Scope group '{0}' resolved via Get-Recipient -Anr to '{1}' ({2})." -f $groupName, $anrHit.Name, $groupType)
                }
                else {
                    $groupWarnings += "Could not resolve scope group '{0}' via Get-UnifiedGroup, Get-DistributionGroup, or Get-Recipient -Anr; its type and membership will be omitted." -f $groupName
                }
            }
        }

        $info = [pscustomobject]@{ ScopeGroupType = $groupType; Members = @($members); Warnings = @($groupWarnings) }
        $Cache[$key] = $info
        $info
    }

    function ConvertTo-ScopeResult($scopeName, $groupName, $groupType, $members, $managementScope, $kind, $filter, $source, $warnings) {
        [pscustomobject][ordered]@{
            ScopeName       = $scopeName
            ScopeGroupName  = $groupName
            ScopeGroupType  = $groupType
            Members         = @($members | Where-Object { $_ } | Sort-Object -Unique)
            ManagementScope = $managementScope
            ScopeKind       = $kind
            ScopeFilter     = $filter
            Source          = $source
            GroupResolved   = [bool]($kind -in @('Group', 'GroupDirect') -and $groupType)
            Warnings        = @($warnings | Where-Object { $_ })
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
    $isCustomRecipientScope = [string]$Assignment.RecipientWriteScope -eq 'CustomRecipientScope'

    if ($candidate) {
        $key = "scope:$candidate"
        if (-not $Cache.ContainsKey($key)) {
            $scopeObj = $null
            $readError = $null
            try { $scopeObj = Get-ManagementScope -Identity $candidate -ErrorAction Stop | Select-Object -First 1 }
            catch {
                $readError = $_.Exception.Message
                Write-Verbose -Message "'$candidate' is not a readable management scope: $readError"
            }

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
                            $resolved = ConvertTo-ScopeResult $groupName $groupName $info.ScopeGroupType $info.Members $candidate 'Group' $filter 'ManagementScope' $info.Warnings
                        }
                        else {
                            $msg = "Could not resolve the group '{0}' referenced by management scope '{1}'; its type and membership will be omitted." -f $dn, $candidate
                            $resolved = ConvertTo-ScopeResult $dn $dn $null @() $candidate 'Group' $filter 'ManagementScope' @($msg)
                        }
                    }
                    'Recipients' {
                        $resolved = ConvertTo-ScopeResult $candidate $null $null $parsed.Recipients $candidate 'Recipients' $filter 'ManagementScope' @()
                    }
                    default {
                        $members = @()
                        $previewWarnings = @()
                        if ($filter) {
                            $preview = @(Get-Recipient -RecipientPreviewFilter $filter -ResultSize $PreviewLimit -ErrorAction SilentlyContinue)
                            if ($preview.Count -ge $PreviewLimit) {
                                $previewWarnings += "Management scope '{0}' matches at least {1} recipients; ScopeMembers is truncated." -f $candidate, $PreviewLimit
                            }
                            $members = Get-MemberAddress $preview
                        }
                        $kind = if ($parsed.ScopeKind) { $parsed.ScopeKind } else { 'Filter' }
                        $resolved = ConvertTo-ScopeResult $candidate $null $null $members $candidate $kind $filter 'ManagementScope' $previewWarnings
                    }
                }
            }
            elseif ($isCustomRecipientScope) {
                # F10: a custom recipient scope names a management scope, never a group - report it
                # unreadable rather than probing the group cmdlets with a scope name.
                $reason = if ($readError) { $readError } else { 'not found' }
                $msg = "Could not read management scope '{0}' ({1}); its kind, filter, and members will be omitted." -f $candidate, $reason
                $resolved = ConvertTo-ScopeResult $candidate $null $null @() $candidate $null $null 'ManagementScope' @($msg)
            }
            $Cache[$key] = $resolved
        }
        if ($Cache[$key]) { return $Cache[$key] }
    }

    # --- Legacy: assignment scoped directly to a group (-RecipientGroupScope).
    $groupName = Resolve-RBAC4AppScopeGroupName -Assignment $Assignment
    if (-not $groupName) {
        return ConvertTo-ScopeResult $null $null $null @() $null $null $null 'None' @()
    }
    $info = Get-GroupInfo $groupName
    ConvertTo-ScopeResult $groupName $groupName $info.ScopeGroupType $info.Members $null 'GroupDirect' $null 'Legacy' $info.Warnings
}