<#
.SYNOPSIS
Exports Get-RBAC4AppEntry rows as Invoke-RBAC4AppConfig config files (YAML or JSON).

.DESCRIPTION
Export-RBAC4AppConfig turns RBAC4App.Entry rows (from Get-RBAC4AppEntry) into schema-4.3 configs
that Invoke-RBAC4AppConfig can provision from, and writes them to disk. It never reads Exchange
Online: everything it needs is on the rows.

By default one config is built per row (named after the role assignment). With -PerApplication,
one config is built per application holding all of its roles; an application whose assignments
use several distinct scopes gets one config per scope.

Rows are collected while the pipeline runs and written once at the end, so every piped row lands
in the output - several configs written to one file path become one JSON array.

A config that cannot be built (unresolved service principal, unsupported or incomplete scope, a
non-application role) is a non-terminating error; the other configs are still written.

Guessed data is refused unless -Force:
- an application identity inferred from the generated role assignment name
  (ServicePrincipalIdSource NameHeuristic);
- a group scope whose group could not be read (ScopeGroupResolved $false). With -Force it is
  exported as a reference-only AccessGroupType MailEnabledSecurityGroup with no members, which
  Invoke-RBAC4AppConfig validates but never creates.
The reason is recorded in the config's Runtime.CollectedWarnings, together with the rows' own
warnings.

.PARAMETER InputObject
RBAC4App.Entry rows from Get-RBAC4AppEntry. Other objects are rejected with an error.

.PARAMETER Path
Output path. A directory (the default is the current directory) receives one
"rbac4app-<name>.<ext>" file per config; names that collide are numbered. A file path (has an
extension, is not an existing directory) receives the single config, or a JSON array of all of
them when there are several; its extension follows -Format.

.PARAMETER Format
Yaml (default, .yml) or Json (.json).

.PARAMETER PerApplication
Build one config per application (and scope) instead of one per role assignment.

.PARAMETER PassThru
Emit one { Path; Config } object per config written.

.PARAMETER Force
Export guessed data (see DESCRIPTION) instead of refusing it.

.EXAMPLE
Get-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' | Export-RBAC4AppConfig -Path .\configs

Writes one YAML config per role assignment of the application into .\configs.

.EXAMPLE
Get-RBAC4AppEntry | Export-RBAC4AppConfig -PerApplication -Format Json -Path .\inventory.json

Writes one config per application into a single JSON array file.

.EXAMPLE
Get-RBAC4AppEntry | Export-RBAC4AppConfig -PerApplication -WhatIf

Shows which files would be written.

.OUTPUTS
None by default. With -PassThru, one [pscustomobject] per config written: Path, Config.

.NOTES
SupportsShouldProcess (ConfirmImpact Low). Existing files with the same name are overwritten.
#>
function Export-RBAC4AppConfig {
    # ShouldProcess is called per file by the private Write-RBAC4AppConfigFile, which inherits this
    # function's -WhatIf/-Confirm preferences.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is called per file by Write-RBAC4AppConfigFile.')]
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyCollection()]
        [psobject[]] $InputObject,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateSet('Yaml', 'Json')]
        [string] $Format = 'Yaml',

        [Parameter()]
        [switch] $PerApplication,

        [Parameter()]
        [switch] $PassThru,

        [Parameter()]
        [switch] $Force
    )

    begin {
        $rows = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in @($InputObject)) {
            if ($null -eq $item) { continue }
            $typeNames = @($item.PSObject.TypeNames)
            if ($typeNames -notcontains 'RBAC4App.Entry' -and $typeNames -notcontains 'Deserialized.RBAC4App.Entry') {
                Write-Error -Message ("Export-RBAC4AppConfig accepts only Get-RBAC4AppEntry rows (RBAC4App.Entry); got '{0}'." -f $typeNames[0])
                continue
            }
            $rows.Add($item)
        }
    }

    end {
        if ($rows.Count -eq 0) { return }

        # Each unit becomes one config: rows sharing the application and the resolved scope.
        $units = [System.Collections.Generic.List[object]]::new()
        if ($PerApplication) {
            $byApp = $rows | Group-Object -Property { '{0}|{1}' -f $_.RoleAssigneeName, $_.RoleAssigneeType } | Sort-Object Name
            foreach ($app in $byApp) {
                $byScope = @($app.Group | Group-Object -Property { '{0}|{1}|{2}' -f $_.ScopeKind, $_.ManagementScope, $_.Scope })
                foreach ($scope in $byScope) {
                    $first = $scope.Group[0]
                    $baseName = [string]$first.DisplayName
                    if ($byScope.Count -gt 1 -and $first.Scope) { $baseName = '{0}-{1}' -f $baseName, $first.Scope }
                    $units.Add([pscustomobject]@{ Rows = @($scope.Group); BaseName = $baseName })
                }
            }
        }
        else {
            foreach ($row in $rows) { $units.Add([pscustomobject]@{ Rows = @($row); BaseName = [string]$row.Name }) }
        }

        $built = [System.Collections.Generic.List[object]]::new()
        foreach ($unit in $units) {
            $result = ConvertTo-RBAC4AppConfigFromEntry -Entry $unit.Rows -BaseName $unit.BaseName -Force:$Force
            foreach ($warning in $result.Warnings) { Write-Warning -Message $warning }
            if ($result.Error) {
                Write-Error -Message $result.Error
                continue
            }
            $built.Add($result)
        }

        $written = Write-RBAC4AppConfigFile -Export @($built) -Path $Path -Format $Format
        if ($PassThru) { $written }
    }
}
