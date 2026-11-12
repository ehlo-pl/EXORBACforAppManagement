<#
.SYNOPSIS
Exports a CSV inventory of RBAC4App YAML state files.

.DESCRIPTION
Scans a directory recursively for .yaml and .yml state files and writes one CSV row per file. Every
field defined by config schema 4.4 is a column, named by its full schema path (for example
Application.AppId, RbacScope.ScopeKind, Metadata.PCode, Runtime.OperatorUsername), in schema order -
so every row has the same columns even when a file leaves fields out.

Values are reported exactly as written in each file: a field the file omits is an empty cell (it is
NOT filled with the default Invoke-RBAC4AppConfig would apply). List fields (Rbac.Roles,
RbacScope.Members, RbacScope.ManagedBy, RbacScope.ScopeRecipients, ConversionResult.DerivedRoles,
ConversionResult.SkippedPermissions, Runtime.CollectedErrors, Runtime.CollectedWarnings) are joined
with '; '. A file older than schema 4.3 has its top-level GeneratedAt reported as Runtime.GeneratedAt. An explicitly empty RbacScope.Members list (an
override meaning "no members") is shown as '[]' to tell it apart from an omitted one.

YAML files without a top-level Application section (for example Application Access Policy exports,
exo-application-access-policies-*.yml) are skipped with a warning. The script always loads this
repository's module (Import-Module -Force), replacing any other copy loaded in the session.

Breaking change from earlier versions: columns used to be unqualified (AppId, OwnerUsername, ...) and
covered only the identity and metadata fields.

.PARAMETER Path
Directory to scan for YAML state files.

.PARAMETER OutputPath
CSV report destination. Defaults to RBAC4AppStateReport.csv in the current directory.

.EXAMPLE
./utils/Export-RBAC4AppStateReport.ps1 -Path ./state -OutputPath ./state-report.csv
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $Path,

    [string] $OutputPath = (Join-Path (Get-Location) 'RBAC4AppStateReport.csv')
)

$stateFiles = @(Get-ChildItem -LiteralPath $Path -File -Recurse |
    Where-Object { $_.Extension -in @('.yaml', '.yml') } |
    Sort-Object FullName)
if ($stateFiles.Count -eq 0) {
    throw "No YAML state files found in '$Path'."
}

$modulePath = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'EXORBACforAppManagement'
$modulePath = Join-Path $modulePath 'EXORBACforAppManagement.psd1'
# -Force: always use this repository's module. Without it, an older copy already loaded in the
# session (e.g. one without ConvertFrom-RBAC4AppYaml -Raw) would be reused.
$module = Import-Module -Name $modulePath -PassThru -Force

# Every schema 4.4 field, in schema order (docs/SCHEMA-4.4.md). Top-level fields have no section.
$schemaFields = @(
    'SchemaVersion'
    'Application.AppId'
    'Application.SpObjectId'
    'Application.DisplayName'
    'Application.TenantId'
    'Rbac.Roles'
    'Rbac.ChangeReference'
    'RbacScope.ScopeKind'
    'RbacScope.AssignmentScope'
    'RbacScope.AccessGroupType'
    'RbacScope.AccessGroupName'
    'RbacScope.GroupPrefix'
    'RbacScope.Members'
    'RbacScope.ManagedBy'
    'RbacScope.BootstrapMember'
    'RbacScope.SeparateScopePerRole'
    'RbacScope.ManagementScopeName'
    'RbacScope.ManagementScopePrefix'
    'RbacScope.ScopeRecipients'
    'RbacScope.ScopeTagAttribute'
    'RbacScope.ScopeTagValue'
    'RbacScope.ScopeFilter'
    'Metadata.ChangeReference'
    'Metadata.OwnerUsername'
    'Metadata.OwnerDisplayName'
    'Metadata.TechnicalContactUsername'
    'Metadata.TechnicalContactDisplayName'
    'Metadata.PCode'
    'Metadata.CmdbId'
    'Metadata.Description'
    'Metadata.NetworkAccessIP4Range'
    'Metadata.NetworkAccessIP6Range'
    'Metadata.NetworkAccessLocation'
    'ConversionResult.AppId'
    'ConversionResult.ResolvedDisplay'
    'ConversionResult.AccessRight'
    'ConversionResult.ScopeGroup'
    'ConversionResult.DerivedRoles'
    'ConversionResult.SkippedPermissions'
    'ConversionResult.ConfigPath'
    'Runtime.GeneratedAt'
    'Runtime.OperatorUsername'
    'Runtime.OperatorMachineName'
    'Runtime.CollectedErrors'
    'Runtime.CollectedWarnings'
)

function Get-RBAC4AppReportValue {
    param([psobject] $Config, [string] $FieldPath)

    $node = $Config
    foreach ($part in $FieldPath.Split('.')) {
        if ($null -eq $node) { return '' }
        $property = $node.PSObject.Properties[$part]
        if (-not $property) { return '' }
        $node = $property.Value
    }

    if ($null -eq $node) { return '' }
    if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
        $items = @($node | Where-Object { $null -ne $_ -and [string]$_ -ne '' } | ForEach-Object { [string]$_ })
        if ($items.Count -eq 0) {
            # Present but empty: only Members distinguishes an explicit [] (an override) from absent.
            if ($FieldPath -eq 'RbacScope.Members') { return '[]' }
            return ''
        }
        return $items -join '; '
    }
    return [string]$node
}

$rows = foreach ($file in $stateFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    # Other YAML files may share the folder (e.g. Application Access Policy exports, whose top level
    # is a Policies: list). A state file always has a top-level Application: section.
    if ([string]$content -notmatch '(?m)^Application\s*:') {
        Write-Warning -Message "Skipping '$($file.FullName)': not an RBAC4App state file (no top-level Application section)."
        continue
    }
    try {
        $config = & $module {
            param($Yaml)
            ConvertFrom-RBAC4AppYaml -Content $Yaml -Raw
        } $content
    }
    catch {
        throw "State file '$($file.FullName)' could not be parsed: $($_.Exception.Message)"
    }

    $row = [ordered]@{ File = $file.FullName }
    foreach ($field in $schemaFields) {
        $row[$field] = Get-RBAC4AppReportValue -Config $config -FieldPath $field
    }
    [pscustomobject]$row
}

$rows = @($rows)
if ($rows.Count -eq 0) {
    throw "No RBAC4App state files found in '$Path' (YAML files were found, but none has a top-level Application section)."
}

if ($PSCmdlet.ShouldProcess($OutputPath, 'Write CSV state report')) {
    $rows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Output $OutputPath
}
