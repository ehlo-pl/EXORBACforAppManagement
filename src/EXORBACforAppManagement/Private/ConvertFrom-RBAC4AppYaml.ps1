function ConvertFrom-RBAC4AppYaml {
    param(
        [Parameter(Mandatory)]
        [string] $Content,

        # Return the values exactly as written in the file (absent keys stay '' / empty lists, and
        # Members/BootstrapMember are only present when the file has them) instead of completing
        # them with defaults. Used by utils/Export-RBAC4AppStateReport.ps1.
        [switch] $Raw
    )

    function ConvertFrom-RBAC4AppYamlScalar {
        param(
            [AllowNull()]
            [string] $Value
        )

        $text = if ($null -eq $Value) { '' } else { $Value.Trim() }
        if ($text.Length -ge 2 -and $text[0] -eq '"' -and $text[$text.Length - 1] -eq '"') {
            $inner = $text.Substring(1, $text.Length - 2)
            $builder = [System.Text.StringBuilder]::new()
            for ($i = 0; $i -lt $inner.Length; $i++) {
                $ch = $inner[$i]
                if ($ch -eq '\' -and ($i + 1) -lt $inner.Length) {
                    $i++
                    $next = $inner[$i]
                    switch ($next) {
                        '"'  { [void]$builder.Append('"') }
                        '\'  { [void]$builder.Append('\') }
                        'n'  { [void]$builder.Append("`n") }
                        'r'  { [void]$builder.Append("`r") }
                        't'  { [void]$builder.Append("`t") }
                        default { [void]$builder.Append($next) }
                    }
                }
                else {
                    [void]$builder.Append($ch)
                }
            }
            return $builder.ToString()
        }

        return $text.Trim('"').Trim("'")
    }

    $config = [pscustomobject]@{
        SchemaVersion = ''
        Application   = [pscustomobject]@{
            AppId       = ''
            SpObjectId  = ''
            DisplayName = ''
            TenantId    = ''
        }
        Rbac          = [pscustomobject]@{
            Roles           = [System.Collections.Generic.List[string]]::new()
            ChangeReference = ''
        }
        RbacScope     = [pscustomobject]@{
            AccessGroupType = ''
            GroupPrefix     = ''
            AccessGroupName = ''
            ManagedBy       = [System.Collections.Generic.List[string]]::new()
            ScopeKind             = ''
            AssignmentScope       = ''
            ManagementScopeName   = ''
            ManagementScopePrefix = ''
            ScopeRecipients       = [System.Collections.Generic.List[string]]::new()
            ScopeTagAttribute     = ''
            ScopeTagValue         = ''
            ScopeFilter           = ''
            SeparateScopePerRole  = ''
        }
        Metadata      = [pscustomobject]@{
            ChangeReference             = ''
            OwnerUsername               = ''
            OwnerDisplayName            = ''
            TechnicalContactUsername    = ''
            TechnicalContactDisplayName = ''
            PCode                       = ''
            CmdbId                      = ''
            Description                 = ''
            NetworkAccessIP4Range       = ''
            NetworkAccessIP6Range       = ''
            NetworkAccessLocation       = ''
        }
        ConversionResult = [pscustomobject]@{
            AppId              = ''
            ResolvedDisplay    = ''
            AccessRight        = ''
            ScopeGroup         = ''
            DerivedRoles       = [System.Collections.Generic.List[string]]::new()
            SkippedPermissions = [System.Collections.Generic.List[string]]::new()
            ConfigPath         = ''
        }
        Runtime       = [pscustomobject]@{
            GeneratedAt         = ''
            OperatorUsername    = ''
            OperatorMachineName = ''
            CollectedErrors  = [System.Collections.Generic.List[string]]::new()
            CollectedWarnings = [System.Collections.Generic.List[string]]::new()
        }
    }

    $section = $null
    $listKey = $null
    # Before schema 4.3 GeneratedAt was a top-level key; it is read into Runtime.GeneratedAt.
    $legacyGeneratedAt = ''
    # Older pre-release files carried TenantId as a top-level key; it is read into Application.TenantId.
    $legacyTenantId = ''

    foreach ($line in ($Content -split '\r?\n')) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }

        if ($line -match '^(Application|Rbac|RbacScope|Metadata|ConversionResult|Runtime)\s*:') {
            $section = $Matches[1]
            $listKey = $null
            continue
        }

        if ($line -match '^\s+-\s+(.+)') {
            $value = ConvertFrom-RBAC4AppYamlScalar $Matches[1]
            if ($section -eq 'Rbac' -and $listKey -eq 'Roles') {
                $config.Rbac.Roles.Add($value)
            } elseif ($section -eq 'RbacScope' -and $listKey -eq 'Members') {
                $config.RbacScope.Members.Add($value)
            } elseif ($section -eq 'RbacScope' -and $listKey -eq 'ManagedBy') {
                $config.RbacScope.ManagedBy.Add($value)
            } elseif ($section -eq 'RbacScope' -and $listKey -eq 'ScopeRecipients') {
                $config.RbacScope.ScopeRecipients.Add($value)
            } elseif ($section -eq 'Runtime' -and $listKey -in @('CollectedErrors', 'CollectedWarnings')) {
                $config.Runtime.$listKey.Add($value)
            } elseif ($section -eq 'ConversionResult' -and $listKey -in @('DerivedRoles', 'SkippedPermissions')) {
                $config.ConversionResult.$listKey.Add($value)
            }
            continue
        }

        if ($line -match '^\s*(\w+)\s*:\s*(.*)$') {
            $key   = $Matches[1]
            $rawValue = $Matches[2]
            $value = ConvertFrom-RBAC4AppYamlScalar $rawValue

            if ($null -eq $section) {
                switch ($key) {
                    'SchemaVersion' { $config.SchemaVersion = $value }
                    'GeneratedAt'   { $legacyGeneratedAt    = $value }
                    'TenantId'      { $legacyTenantId       = $value }
                }
            }
            elseif ($section -eq 'Application') {
                $listKey = $null
                switch ($key) {
                    'AppId'       { $config.Application.AppId       = $value }
                    'SpObjectId'  { $config.Application.SpObjectId  = $value }
                    'DisplayName' { $config.Application.DisplayName = $value }
                    'TenantId'    { $config.Application.TenantId    = $value }
                }
            }
            elseif ($section -eq 'Rbac') {
                switch ($key) {
                    'Roles'           { $listKey = 'Roles' }
                    'ChangeReference' { $config.Rbac.ChangeReference = $value; $listKey = $null }
                }
            }
            elseif ($section -eq 'RbacScope') {
                switch ($key) {
                    'Members' {
                        $config.RbacScope | Add-Member -NotePropertyName Members -NotePropertyValue ([System.Collections.Generic.List[string]]::new()) -Force
                        if ($rawValue.Trim() -eq '[]') {
                            $listKey = $null
                        } else {
                            $listKey = 'Members'
                        }
                    }
                    'ManagedBy'       { $listKey = 'ManagedBy' }
                    'AccessGroupType' { $config.RbacScope.AccessGroupType = $value; $listKey = $null }
                    'GroupPrefix'     { $config.RbacScope.GroupPrefix     = $value; $listKey = $null }
                    'AccessGroupName' { $config.RbacScope.AccessGroupName = $value; $listKey = $null }
                    'BootstrapMember' { $config.RbacScope | Add-Member -NotePropertyName BootstrapMember -NotePropertyValue $value -Force; $listKey = $null }
                    'ScopeRecipients'       { $listKey = 'ScopeRecipients' }
                    'ScopeKind'             { if ($value) { $config.RbacScope.ScopeKind = $value }; $listKey = $null }
                    'AssignmentScope'       { $config.RbacScope.AssignmentScope       = $value; $listKey = $null }
                    'ManagementScopeName'   { $config.RbacScope.ManagementScopeName   = $value; $listKey = $null }
                    'ManagementScopePrefix' { $config.RbacScope.ManagementScopePrefix = $value; $listKey = $null }
                    'ScopeTagAttribute'     { $config.RbacScope.ScopeTagAttribute     = $value; $listKey = $null }
                    'ScopeTagValue'         { $config.RbacScope.ScopeTagValue         = $value; $listKey = $null }
                    'ScopeFilter'           { $config.RbacScope.ScopeFilter           = $value; $listKey = $null }
                    'SeparateScopePerRole'  { $config.RbacScope.SeparateScopePerRole  = $value; $listKey = $null }
                }
            }
            elseif ($section -eq 'Metadata') {
                $listKey = $null
                switch ($key) {
                    'ChangeReference'             { $config.Metadata.ChangeReference             = $value }
                    'OwnerUsername'               { $config.Metadata.OwnerUsername               = $value }
                    'OwnerDisplayName'            { $config.Metadata.OwnerDisplayName            = $value }
                    'TechnicalContactUsername'    { $config.Metadata.TechnicalContactUsername    = $value }
                    'TechnicalContactDisplayName' { $config.Metadata.TechnicalContactDisplayName = $value }
                    'PCode'                       { $config.Metadata.PCode                       = $value }
                    'CmdbId'                      { $config.Metadata.CmdbId                      = $value }
                    'Description'                 { $config.Metadata.Description                 = $value }
                    'NetworkAccessIP4Range'       { $config.Metadata.NetworkAccessIP4Range       = $value }
                    'NetworkAccessIP6Range'       { $config.Metadata.NetworkAccessIP6Range       = $value }
                    # Before the IPv4/IPv6 split: an IPv4-only field, kept unless IP4Range is also set.
                    'NetworkAccessIPRange'        { if (-not $config.Metadata.NetworkAccessIP4Range) { $config.Metadata.NetworkAccessIP4Range = $value } }
                    'NetworkAccessLocation'       { $config.Metadata.NetworkAccessLocation       = $value }
                }
            }
            elseif ($section -eq 'ConversionResult') {
                switch ($key) {
                    'AppId'           { $config.ConversionResult.AppId           = $value }
                    'ResolvedDisplay' { $config.ConversionResult.ResolvedDisplay = $value }
                    'AccessRight'     { $config.ConversionResult.AccessRight     = $value }
                    'ScopeGroup'      { $config.ConversionResult.ScopeGroup      = $value }
                    'ConfigPath'      { $config.ConversionResult.ConfigPath      = $value }
                }
                $listKey = if ($key -in @('DerivedRoles', 'SkippedPermissions') -and $rawValue.Trim() -ne '[]') { $key } else { $null }
            }
            elseif ($section -eq 'Runtime') {
                switch ($key) {
                    'GeneratedAt'         { $config.Runtime.GeneratedAt         = $value }
                    'OperatorUsername'    { $config.Runtime.OperatorUsername    = $value }
                    'OperatorMachineName' { $config.Runtime.OperatorMachineName = $value }
                }
                $listKey = if ($key -in @('CollectedErrors', 'CollectedWarnings') -and $rawValue.Trim() -ne '[]') { $key } else { $null }
            }
        }
    }

    if ($legacyGeneratedAt -and -not $config.Runtime.GeneratedAt) { $config.Runtime.GeneratedAt = $legacyGeneratedAt }
    if ($legacyTenantId -and -not $config.Application.TenantId) { $config.Application.TenantId = $legacyTenantId }

    if ($Raw) { return $config }

    # Keys absent from the file take their defaults.
    return Complete-RBAC4AppConfig -Config $config
}
