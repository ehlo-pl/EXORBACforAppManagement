function ConvertTo-EXOApplicationAccessPolicyYaml {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Policies
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Policies:')
    foreach ($policy in $Policies) {
        $lines.Add("  - ScopeName: $(ConvertTo-Json -InputObject ([string]$policy.ScopeName) -Compress)")
        $lines.Add("    ScopeIdentity: $(ConvertTo-Json -InputObject ([string]$policy.ScopeIdentity) -Compress)")
        $lines.Add("    AppId: $(ConvertTo-Json -InputObject ([string]$policy.AppId) -Compress)")
        $lines.Add("    AccessRight: $(ConvertTo-Json -InputObject ([string]$policy.AccessRight) -Compress)")
        $lines.Add("    Group: $(ConvertTo-Json -InputObject ([string]$policy.Group) -Compress)")

        $permissions = @($policy.Permissions | Where-Object { $_ })
        if ($permissions.Count -eq 0) {
            $lines.Add('    Permissions: []')
        }
        else {
            $lines.Add('    Permissions:')
            foreach ($permission in $permissions) {
                $lines.Add("      - $(ConvertTo-Json -InputObject ([string]$permission) -Compress)")
            }
        }
    }

    return $lines -join [System.Environment]::NewLine
}
