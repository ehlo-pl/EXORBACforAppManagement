function ConvertFrom-RBAC4AppYaml {
    param(
        [Parameter(Mandatory)]
        [string] $Content
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
            $value = ConvertFrom-RBAC4AppYamlScalar $Matches[1]
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
            $value = ConvertFrom-RBAC4AppYamlScalar $Matches[2]

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
