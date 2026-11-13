function Get-RBAC4AppRepositoryState {
    # Reads the state file {AppId}.yaml, .yml or .json from a repository folder and returns it with
    # every key filled in by Complete-RBAC4AppConfig, or $null when the app has no state file.
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Repository,

        [Parameter(Mandatory)]
        [string] $AppId
    )

    $files = @(Get-ChildItem -LiteralPath $Repository -File |
        Where-Object { $_.BaseName -ieq $AppId -and $_.Extension -in @('.yaml', '.yml', '.json') })
    if ($files.Count -eq 0) { return $null }
    if ($files.Count -gt 1) {
        throw "Repository '$Repository' has more than one state file for AppId '$AppId': $($files.Name -join ', '). Keep only one."
    }

    $path = $files[0].FullName
    $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    try {
        $parsed = if ($files[0].Extension -ieq '.json') {
            $content | ConvertFrom-Json
        }
        else {
            ConvertFrom-RBAC4AppYaml -Content $content
        }
    }
    catch {
        throw "State file '$path' could not be parsed: $($_.Exception.Message)"
    }
    if ($parsed -is [array]) {
        throw "State file '$path' contains a list; a state file describes a single application."
    }

    $state = Complete-RBAC4AppConfig -Config $parsed
    if ($state.SchemaVersion -and $state.SchemaVersion -ne $script:RBAC4AppConfigSchemaVersion) {
        throw "State file '$path' has unsupported SchemaVersion '$($state.SchemaVersion)'; only '$($script:RBAC4AppConfigSchemaVersion)' is supported. Update the file to the current schema (docs/SCHEMA-$($script:RBAC4AppConfigSchemaVersion).md)."
    }
    if ($state.Application.AppId -and $state.Application.AppId -ine $AppId) {
        throw "State file '$path' is for AppId '$($state.Application.AppId)', not '$AppId'."
    }

    Write-Verbose "Loaded state file '$path'."
    $state
}
