<#
.SYNOPSIS
Exports a CSV inventory of RBAC4App YAML state files.

.DESCRIPTION
Scans a directory recursively for .yaml and .yml state files and writes one CSV row per file,
including the schema version, application identity, and metadata fields.

.PARAMETER Path
Directory to scan for YAML state files.

.PARAMETER OutputPath
CSV report destination. Defaults to RBAC4AppStateReport.csv in the current directory.

.EXAMPLE
./scripts/Export-RBAC4AppStateReport.ps1 -Path ./state -OutputPath ./state-report.csv
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
$module = Import-Module -Name $modulePath -PassThru

$metadataFields = @(
    'OwnerUsername',
    'OwnerDisplayName',
    'TechnicalContactUsername',
    'TechnicalContactDisplayName',
    'PCode',
    'CmdbId',
    'Description',
    'NetworkAccessIPRange',
    'NetworkAccessLocation'
)
$rows = foreach ($file in $stateFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    try {
        $config = & $module {
            param($Yaml)
            ConvertFrom-RBAC4AppYaml -Content $Yaml
        } $content
    }
    catch {
        throw "State file '$($file.FullName)' could not be parsed: $($_.Exception.Message)"
    }

    $row = [ordered]@{
        File         = $file.FullName
        SchemaVersion = $config.SchemaVersion
        AppId        = $config.Application.AppId
        SpObjectId   = $config.Application.SpObjectId
        DisplayName  = $config.Application.DisplayName
        GeneratedAt  = $config.GeneratedAt
        TenantId     = $config.TenantId
    }
    foreach ($field in $metadataFields) {
        $row[$field] = $config.Metadata.$field
    }
    [pscustomobject]$row
}

if ($PSCmdlet.ShouldProcess($OutputPath, 'Write CSV state report')) {
    $rows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Output $OutputPath
}
