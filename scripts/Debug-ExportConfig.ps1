<#
.SYNOPSIS
Diagnoses why Get-RBAC4AppEntry | Export-RBAC4AppConfig does not write the expected rbac4app-*.yml/.json files.

.DESCRIPTION
Run in a connected Exchange Online session (Connect-ExchangeOnline). The script imports the module
from this repository's src folder (removing any copy already loaded first, so an older installed
version cannot shadow it), then logs every point where an export can silently produce no files:

  1. which module copy is loaded, the working folder, and $WhatIfPreference / $ConfirmPreference
  2. how many role assignments survive each default filter (Application * role,
     ScopeType Group/CustomRecipientScope, RoleAssigneeType ServicePrincipal)
  3. whether each assignee resolves to an Exchange Online service principal
  4. the export itself: rows returned, warnings, verbose output, errors (grouped), and the number
     of rbac4app-* files in the export folder before and after

The export is the only write this script makes; nothing in Exchange Online is changed. Everything
is written to a transcript log. Note that the error list also contains errors the module handled
on purpose (e.g. Get-ManagementScope / Get-UnifiedGroup "couldn't be found" probes); only
"Cannot export ..." errors mean an assignment was skipped.

.PARAMETER ExportPath
Folder (or file) passed to Get-RBAC4AppEntry -ExportPath. Defaults to the current folder.

.PARAMETER LogPath
Transcript log to write. Defaults to Debug-ExportConfig-<timestamp>.log in the current folder.

.PARAMETER ModulePath
Module manifest to import. Defaults to src/EXORBACforAppManagement in this repository.

.PARAMETER ExportFormat
Yaml (default) or Json, passed through to Get-RBAC4AppEntry.

.PARAMETER ByApplication
Also pass -PerApplication to Export-RBAC4AppConfig (one config per application instead of one per assignment).

.EXAMPLE
Connect-ExchangeOnline; ./scripts/Debug-ExportConfig.ps1

.EXAMPLE
./scripts/Debug-ExportConfig.ps1 -ExportPath C:\Temp\export -ByApplication -LogPath C:\Temp\debug.log
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $ExportPath = (Get-Location).Path,

    [ValidateNotNullOrEmpty()]
    [string] $LogPath = (Join-Path (Get-Location).Path ('Debug-ExportConfig-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),

    [ValidateNotNullOrEmpty()]
    [string] $ModulePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/EXORBACforAppManagement/EXORBACforAppManagement.psd1'),

    [ValidateSet('Yaml', 'Json')]
    [string] $ExportFormat = 'Yaml',

    [switch] $ByApplication
)

Start-Transcript -Path $LogPath -Force | Out-Null
try {
    if (-not (Get-Command Get-ManagementRoleAssignment -ErrorAction SilentlyContinue)) {
        throw 'Get-ManagementRoleAssignment is not available. Run Connect-ExchangeOnline first.'
    }
    $connection = @(Get-ConnectionInformation -ErrorAction SilentlyContinue)
    "== EXO connections: $($connection.Count)"
    $connection | ForEach-Object { "   State=$($_.State) TokenStatus=$($_.TokenStatus) User=$($_.UserPrincipalName) Tenant=$($_.TenantID)" }

    Get-Module EXORBACforAppManagement | Remove-Module -Force
    Import-Module $ModulePath -Force -ErrorAction Stop
    $cmd = Get-Command Get-RBAC4AppEntry
    "== Loaded module: $($cmd.Module.Path) v$($cmd.Module.Version) (copies loaded: $(@(Get-Module EXORBACforAppManagement).Count))"
    "== cwd: $((Get-Location).Path)  provider: $((Get-Location).Provider.Name)"
    "== ExportPath: $ExportPath (existing folder: $(Test-Path -LiteralPath $ExportPath -PathType Container))"
    "== WhatIfPreference=$WhatIfPreference ConfirmPreference=$ConfirmPreference"

    # --- Stage-by-stage filter counts (mirrors Get-RBAC4AppEntry's defaults).
    $all = @(Get-ManagementRoleAssignment -ErrorAction Continue | Where-Object { [string]$_.Role -like 'Application *' })
    "== Application * assignments: $($all.Count)"
    $all | Group-Object { "$($_.RoleAssigneeType) / $($_.RecipientWriteScope)" } | ForEach-Object { "   $($_.Name): $($_.Count)" }
    $kept = @($all | Where-Object { [string]$_.RecipientWriteScope -in 'Group', 'CustomRecipientScope' -and [string]$_.RoleAssigneeType -eq 'ServicePrincipal' })
    "== After default ScopeType/RoleAssigneeType filters: $($kept.Count)"
    $kept | Select-Object -First 10 Name, Role, RoleAssigneeName, RecipientWriteScope, CustomRecipientWriteScope, CustomResourceScope |
        Format-Table -AutoSize | Out-String -Width 300

    # --- Assignee -> EXO service principal (object id, then DisplayName with/without "_SP").
    $sps = @(Get-ServicePrincipal -ErrorAction Continue)
    "== EXO service principals: $($sps.Count)"
    $unresolved = 0
    foreach ($n in ($kept.RoleAssigneeName | Sort-Object -Unique)) {
        $hit = $sps | Where-Object {
            [string]$_.ObjectId -eq $n -or [string]$_.DisplayName -eq $n -or
            ([string]$_.DisplayName -replace '_SP$', '') -eq ($n -replace '_SP$', '')
        } | Select-Object -First 1
        if (-not $hit) { $unresolved++ }
        "   assignee '$n' -> " + $(if ($hit) { "$($hit.DisplayName) AppId=$($hit.AppId) ObjectId=$($hit.ObjectId)" } else { 'NOT RESOLVED' })
    }
    "== Unresolved assignees: $unresolved"

    # --- The export itself.
    $exportFolder = if (Test-Path -LiteralPath $ExportPath -PathType Container) { $ExportPath } else { Split-Path -Path $ExportPath -Parent }
    if (-not $exportFolder) { $exportFolder = (Get-Location).Path }
    $before = @(Get-ChildItem -LiteralPath $exportFolder -Filter 'rbac4app-*' -ErrorAction SilentlyContinue)

    $exportParameters = @{ Path = $ExportPath; Format = $ExportFormat; PerApplication = $ByApplication; Verbose = $true }
    "== Running: Get-RBAC4AppEntry | Export-RBAC4AppConfig $(($exportParameters.GetEnumerator() | ForEach-Object { "-$($_.Key):$($_.Value)" }) -join ' ')"
    $ev = $null; $wv = $null
    $rows = @(Get-RBAC4AppEntry -ErrorVariable ev -WarningVariable wv)
    $output = $rows | Export-RBAC4AppConfig @exportParameters -ErrorVariable +ev -WarningVariable +wv 4>&1
    $verbose = @($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })

    "== Rows returned: $($rows.Count)"
    $rows | Select-Object -First 10 Name, DisplayName, AppId, ScopeKind, Scope, ManagementScope, ScopeGroupType |
        Format-Table -AutoSize | Out-String -Width 300

    $skipped = @($ev | Where-Object { "$_" -like 'Cannot export*' })
    "== Skipped assignments (Cannot export ...): $($skipped.Count)"
    $skipped | ForEach-Object { "   $_" }
    "== All errors, grouped (includes handled 'couldn't be found' probes): $(@($ev).Count)"
    $ev | ForEach-Object { (("$_" -split "`n")[0] -replace "'[^']*'", "'...'").Trim() } |
        Group-Object | Sort-Object Count -Descending | ForEach-Object { '   {0,5} x {1}' -f $_.Count, $_.Name }
    "== Warnings ($(@($wv).Count)):"; $wv | ForEach-Object { "   $_" }
    "== Verbose ($($verbose.Count)):"; $verbose | ForEach-Object { "   $($_.Message)" }

    $after = @(Get-ChildItem -LiteralPath $exportFolder -Filter 'rbac4app-*' -ErrorAction SilentlyContinue)
    "== rbac4app-* files in '$exportFolder' before: $($before.Count)  after: $($after.Count)"
    $after | Sort-Object LastWriteTime -Descending | Select-Object -First 20 Name, Length, LastWriteTime | Format-Table -AutoSize | Out-String
}
catch {
    "== TERMINATING: $($_ | Out-String)"
}
finally {
    Stop-Transcript | Out-Null
    "Log: $LogPath"
}
