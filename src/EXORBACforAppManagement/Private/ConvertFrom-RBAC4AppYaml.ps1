function ConvertFrom-RBAC4AppYaml {
    param(
        [Parameter(Mandatory)]
        [string] $Content
    )

    $config = [pscustomobject]@{
        SchemaVersion = ''
        GeneratedAt   = ''
        TenantId      = ''
        Application   = [pscustomobject]@{
            AppId       = ''
            SpObjectId  = ''
            DisplayName = ''
        }
        Rbac          = [pscustomobject]@{
            Roles = [System.Collections.Generic.List[string]]::new()
        }
        RbacScope     = [pscustomobject]@{
            AccessGroupType = 'M365Group'
            GroupPrefix     = 'Um365RAo1'
            AccessGroupName = ''
            Members         = [System.Collections.Generic.List[string]]::new()
            ManagedBy       = [System.Collections.Generic.List[string]]::new()
            BootstrapMember = 'GraphAPI-Dummy'
        }
    }

    $section = $null
    $listKey = $null

    foreach ($line in ($Content -split '\r?\n')) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }

        if ($line -match '^(Application|Rbac|RbacScope)\s*:') {
            $section = $Matches[1]
            $listKey = $null
            continue
        }

        if ($line -match '^\s+-\s+(.+)') {
            $value = $Matches[1].Trim().Trim('"').Trim("'")
            if ($section -eq 'Rbac' -and $listKey -eq 'Roles') {
                $config.Rbac.Roles.Add($value)
            } elseif ($section -eq 'RbacScope' -and $listKey -eq 'Members') {
                $config.RbacScope.Members.Add($value)
            } elseif ($section -eq 'RbacScope' -and $listKey -eq 'ManagedBy') {
                $config.RbacScope.ManagedBy.Add($value)
            }
            continue
        }

        if ($line -match '^\s*(\w+)\s*:\s*(.*)$') {
            $key   = $Matches[1]
            $value = $Matches[2].Trim().Trim('"').Trim("'")

            if ($null -eq $section) {
                switch ($key) {
                    'SchemaVersion' { $config.SchemaVersion = $value }
                    'GeneratedAt'   { $config.GeneratedAt   = $value }
                    'TenantId'      { $config.TenantId      = $value }
                }
            }
            elseif ($section -eq 'Application') {
                $listKey = $null
                switch ($key) {
                    'AppId'       { $config.Application.AppId       = $value }
                    'SpObjectId'  { $config.Application.SpObjectId  = $value }
                    'DisplayName' { $config.Application.DisplayName = $value }
                }
            }
            elseif ($section -eq 'Rbac') {
                switch ($key) {
                    'Roles' { $listKey = 'Roles' }
                }
            }
            elseif ($section -eq 'RbacScope') {
                switch ($key) {
                    'Members'         { $listKey = 'Members' }
                    'ManagedBy'       { $listKey = 'ManagedBy' }
                    'AccessGroupType' { $config.RbacScope.AccessGroupType = $value; $listKey = $null }
                    'GroupPrefix'     { $config.RbacScope.GroupPrefix     = $value; $listKey = $null }
                    'AccessGroupName' { $config.RbacScope.AccessGroupName = $value; $listKey = $null }
                    'BootstrapMember' { $config.RbacScope.BootstrapMember = $value; $listKey = $null }
                }
            }
        }
    }

    return $config
}
