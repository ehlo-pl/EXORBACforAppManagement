function Resolve-RBAC4AppAssignee {
    # Resolves one management role assignment's assignee to its Exchange Online service principal
    # pointer and works out the service principal object id to report for that assignment.
    #
    # Pointer match order (cached per RoleAssigneeType + RoleAssigneeName in -Cache):
    #   a. ObjectId equals RoleAssigneeName - how this module's own assignments are bound
    #      (New-ManagementRoleAssignment -App <ObjectId>).
    #   b. Exact DisplayName.
    #   c. DisplayName with the "_SP" suffix stripped on both sides.
    #   d. Name heuristic (ServicePrincipal assignee whose name is a GUID, no pointer carries that
    #      ObjectId): accepted only when exactly one pointer - itself without an ObjectId - would
    #      have generated the assignment's name (Get-RBAC4AppRoleAssignmentName) for an assignment
    #      whose EffectiveUserName GUID equals the assignee, and no assignment for that assignee
    #      carries a different EffectiveUserName GUID. Assignment names are not authoritative, so
    #      this always warns and reports ServicePrincipalIdSource 'NameHeuristic'.
    #
    # ServicePrincipalId: the pointer's ObjectId ('ExoPointer'); otherwise, for ServicePrincipal
    # assignees only, the GUID in this assignment's EffectiveUserName ('EffectiveUserName', with a
    # warning; 'NameHeuristic' when the pointer came from rule d); otherwise $null ('None', with a
    # warning when a pointer was found).
    #
    # Never writes warnings itself; they are returned in Warnings for the caller to surface.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [psobject] $Assignment,

        # From Get-RBAC4AppServicePrincipalIndex.
        [Parameter(Mandatory)]
        [psobject] $Index,

        # Every assignment of the current read, used to corroborate (or contradict) rule d.
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]] $AllAssignments = @(),

        [Parameter(Mandatory)]
        [hashtable] $Cache
    )

    $guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $assigneeName = [string]$Assignment.RoleAssigneeName
    $assigneeType = [string]$Assignment.RoleAssigneeType
    $key = '{0}|{1}' -f $assigneeType, $assigneeName

    if (-not $Cache.ContainsKey($key)) {
        $resolved = $null
        $heuristic = $false
        $pointerWarnings = @()

        if ($assigneeName) { $resolved = $Index.ByObjectId[$assigneeName] }
        if (-not $resolved) {
            $resolved = $Index.All | Where-Object { [string]$_.DisplayName -eq $assigneeName } | Select-Object -First 1
        }
        if (-not $resolved -and $assigneeName) {
            $normalized = $assigneeName -replace '_SP$', ''
            $resolved = $Index.All | Where-Object { ([string]$_.DisplayName -replace '_SP$', '') -eq $normalized } | Select-Object -First 1
        }
        if (-not $resolved -and $assigneeType -eq 'ServicePrincipal' -and $assigneeName -match $guidPattern) {
            $sameAssignee = @($AllAssignments | Where-Object {
                    $_ -and [string]$_.RoleAssigneeType -eq 'ServicePrincipal' -and [string]$_.RoleAssigneeName -eq $assigneeName
                })
            if ($sameAssignee.Count -eq 0) { $sameAssignee = @($Assignment) }
            $corroborated = @($sameAssignee | Where-Object {
                    (Get-RBAC4AppEffectiveUserObjectId -EffectiveUserName @($_.EffectiveUserName)) -eq $assigneeName
                })
            $conflicting = @($sameAssignee | Where-Object {
                    $effectiveId = Get-RBAC4AppEffectiveUserObjectId -EffectiveUserName @($_.EffectiveUserName)
                    $effectiveId -and $effectiveId -ne $assigneeName
                })
            $roleMap = Get-AppRoleMap
            $nameMatches = @($Index.All | Where-Object {
                    $candidate = $_
                    if (-not $candidate.AppId -or -not $candidate.DisplayName) { return $false }
                    $candidateName = [string]$candidate.DisplayName -replace '_SP$', ''
                    if (-not $candidateName) { return $false }
                    foreach ($a in $corroborated) {
                        $shortRole = $roleMap[[string]$a.Role]
                        if ($shortRole -and [string]$a.Name -eq (Get-RBAC4AppRoleAssignmentName -ShortRoleName $shortRole -DisplayName $candidateName -AppId ([string]$candidate.AppId))) {
                            return $true
                        }
                    }
                    return $false
                })
            if ($nameMatches.Count -eq 1 -and -not $nameMatches[0].ObjectId -and $conflicting.Count -eq 0) {
                $resolved = $nameMatches[0]
                $heuristic = $true
                $pointerWarnings += "Resolved EXO assignee '{0}' from a generated role assignment name because the pointer's object id is missing; verify the application identity before using an exported config." -f $assigneeName
            }
        }

        if (-not $resolved -and $assigneeType -eq 'ServicePrincipal') {
            $pointerWarnings += "Could not resolve EXO assignee '{0}' to an Exchange Online service principal; AppId will be empty, and ServicePrincipalId too unless EffectiveUserName carries an object id." -f $assigneeName
        }

        $Cache[$key] = [pscustomobject]@{ Sp = $resolved; Heuristic = $heuristic; Warnings = @($pointerWarnings) }
    }

    $pointer = $Cache[$key]
    $sp = $pointer.Sp
    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($w in @($pointer.Warnings)) { $warnings.Add([string]$w) }

    $displayName = if ($sp) { [string]$sp.DisplayName -replace '_SP$', '' }
    elseif ($assigneeType -eq 'ServicePrincipal') { $assigneeName -replace '_SP$', '' }
    else { $null }

    $spId = if ($sp) { [string]$sp.ObjectId } else { '' }
    $source = 'None'
    if ($spId) {
        $source = 'ExoPointer'
    }
    elseif ($assigneeType -eq 'ServicePrincipal') {
        $fallback = Get-RBAC4AppEffectiveUserObjectId -EffectiveUserName @($Assignment.EffectiveUserName)
        if ($fallback) {
            $spId = $fallback
            $source = if ($pointer.Heuristic) { 'NameHeuristic' } else { 'EffectiveUserName' }
            $warnings.Add(("ServicePrincipalId/SpObjectId for '{0}' was returned empty (often a sign of an incomplete Connect-MgGraph or directory read); using '{1}' from EffectiveUserName instead." -f $displayName, $fallback))
        }
        elseif ($sp) {
            $warnings.Add(("ServicePrincipalId/SpObjectId for '{0}' was returned empty and EffectiveUserName holds no object id (GUID); the field is left empty." -f $displayName))
        }
    }

    [pscustomobject]@{
        Sp                       = $sp
        DisplayName              = $displayName
        AppId                    = if ($sp) { [string]$sp.AppId } else { $null }
        ServicePrincipalId       = if ($spId) { $spId } else { $null }
        ServicePrincipalIdSource = $source
        Warnings                 = @($warnings)
    }
}
