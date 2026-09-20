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
            Roles           = [System.Collections.Generic.List[string]]::new()
            AccessGroupType = 'M365Group'
            GroupPrefix     = 'Um365RAo1'
            AccessGroupName = ''
            Members         = [System.Collections.Generic.List[string]]::new()
            ManagedBy       = 'GraphAPI-Dummy-owner'
            BootstrapMember = 'GraphAPI-Dummy'
        }
    }

    $section = $null
    $listKey = $null

    foreach ($line in ($Content -split '\r?\n')) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }

        if ($line -match '^(Application|Rbac)\s*:') {
            $section = $Matches[1]
            $listKey = $null
            continue
        }

        if ($line -match '^\s+-\s+(.+)') {
            $value = $Matches[1].Trim().Trim('"').Trim("'")
            if ($section -eq 'Rbac' -and $listKey -eq 'Roles') {
                $config.Rbac.Roles.Add($value)
            } elseif ($section -eq 'Rbac' -and $listKey -eq 'Members') {
                $config.Rbac.Members.Add($value)
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
                    'Roles'           { $listKey = 'Roles' }
                    'Members'         { $listKey = 'Members' }
                    'AccessGroupType' { $config.Rbac.AccessGroupType = $value; $listKey = $null }
                    'GroupPrefix'     { $config.Rbac.GroupPrefix     = $value; $listKey = $null }
                    'AccessGroupName' { $config.Rbac.AccessGroupName = $value; $listKey = $null }
                    'ManagedBy'       { $config.Rbac.ManagedBy       = $value; $listKey = $null }
                    'BootstrapMember' { $config.Rbac.BootstrapMember = $value; $listKey = $null }
                }
            }
        }
    }

    return $config
}
