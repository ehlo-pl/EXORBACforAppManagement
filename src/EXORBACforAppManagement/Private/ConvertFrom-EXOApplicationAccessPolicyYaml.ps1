function ConvertFrom-EXOApplicationAccessPolicyYaml {
    param(
        [Parameter(Mandatory)]
        [string] $Content
    )

    $policies = [System.Collections.Generic.List[object]]::new()
    $current = $null
    $inPermissions = $false

    foreach ($line in ($Content -split '\r?\n')) {
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
        if ($line -eq 'Policies:') { continue }

        if ($line -match '^\s{2}-\s+ScopeName:\s*(.*)$') {
            if ($current) { $policies.Add([pscustomobject]$current) }
            $current = [ordered]@{
                ScopeName     = ConvertFrom-Json -InputObject $Matches[1] -ErrorAction Stop
                ScopeIdentity = ''
                AppId         = ''
                AccessRight   = ''
                Group         = ''
                Permissions   = [System.Collections.Generic.List[string]]::new()
            }
            $inPermissions = $false
            continue
        }

        if (-not $current) { throw 'Invalid Application Access Policy YAML: expected a policy under Policies.' }

        if ($line -match '^\s{6}-\s+(.*)$' -and $inPermissions) {
            $current.Permissions.Add((ConvertFrom-Json -InputObject $Matches[1] -ErrorAction Stop))
            continue
        }

        if ($line -match '^\s{4}(ScopeIdentity|AppId|AccessRight|Group):\s*(.*)$') {
            $current[$Matches[1]] = ConvertFrom-Json -InputObject $Matches[2] -ErrorAction Stop
            $inPermissions = $false
            continue
        }

        if ($line -match '^\s{4}Permissions:\s*(.*)$') {
            $current.Permissions = [System.Collections.Generic.List[string]]::new()
            $inPermissions = -not ($Matches[1].Trim() -eq '[]')
            continue
        }

        throw "Invalid Application Access Policy YAML line: $line"
    }

    if ($current) { $policies.Add([pscustomobject]$current) }
    return [pscustomobject]@{ Policies = @($policies.ToArray()) }
}
