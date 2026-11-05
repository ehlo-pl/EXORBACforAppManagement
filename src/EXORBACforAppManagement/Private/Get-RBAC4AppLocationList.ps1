function Get-RBAC4AppLocationList {
    # Valid Metadata.NetworkAccessLocation names, read from locations.txt at the module root.
    [OutputType([string[]])]
    param()

    $path = Join-Path $script:RBAC4AppModuleRoot 'locations.txt'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Location list file not found at '$path'. Reinstall or rebuild the module."
    }

    @(Get-Content -LiteralPath $path -Encoding UTF8 |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch '^#' })
}
