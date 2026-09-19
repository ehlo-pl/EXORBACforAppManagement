#requires -Version 5.1

# Module loader: dot-source every Private helper, then every Public function, and
# export only the Public functions. File names are expected to match function names.

$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)
$public  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public')  -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in @($private + $public)) {
    try {
        . $file.FullName
    }
    catch {
        throw "Failed to import function file '$($file.FullName)': $($_.Exception.Message)"
    }
}

# Backward-compatible aliases: the pre-0.6.0 RBACforApp names map to the RBAC4App functions.
$aliasMap = [ordered]@{
    'New-RBACforAppEntry'             = 'New-RBAC4AppEntry'
    'Get-RBACforAppEntry'             = 'Get-RBAC4AppEntry'
    'Set-RBACforAppEntry'             = 'Set-RBAC4AppEntry'
    'Test-RBACforAppEntry'            = 'Test-RBAC4AppEntry'
    'Remove-RBACforAppEntry'          = 'Remove-RBAC4AppEntry'
    'New-RBACforAppUnifiedGroup'      = 'New-RBAC4AppUnifiedGroup'
    'New-RBACforAppDistributionGroup' = 'New-RBAC4AppDistributionGroup'
}
foreach ($aliasName in $aliasMap.Keys) {
    Set-Alias -Name $aliasName -Value $aliasMap[$aliasName]
}

Export-ModuleMember -Function $public.BaseName -Alias @($aliasMap.Keys)
