# Requires connected Microsoft Graph and Exchange Online sessions.
# Excel export requires the ImportExcel module.

$mm = @(
    Get-ManagementRoleAssignment -ErrorAction Stop |
        Where-Object {
            $_.Role -imatch '^Application' -and
            $_.RoleAssigneeType -imatch 'ServicePrincipal'
        } |
        Select-Object Name, Role, RoleAssigneeName, RoleAssigneeType,
            AssignmentMethod, EffectiveUserName, App,
            CustomResourceScope, Recipient*
)

$applicationAccessPolicy = @(
    Get-ApplicationAccessPolicy -ErrorAction Stop
)

function Resolve-ReportServicePrincipal {
    param(
        [string]$ServicePrincipalId,
        [string]$AppId
    )

    try {
        if ($AppId) {
            $appGuid = [guid]::Parse($AppId)

            $principals = @(
                Get-MgServicePrincipal -Filter "appId eq '$appGuid'" `
                    -All -ErrorAction Stop
            )
        } else {
            if ([string]::IsNullOrWhiteSpace($ServicePrincipalId)) {
                throw 'EffectiveUserName contains no service-principal ID.'
            }

            $principals = @(
                Get-MgServicePrincipal -ServicePrincipalId $ServicePrincipalId `
                    -ErrorAction Stop
            )
        }

        if ($principals.Count -ne 1) {
            throw "Expected one service principal; found $($principals.Count)."
        }

        [pscustomobject]@{
            Principal = $principals[0]
            Error     = $null
        }
    } catch {
        $identity = if ($AppId) { $AppId } else { $ServicePrincipalId }
        $message = "Service-principal lookup failed for '$identity': $($_.Exception.Message)"
        Write-Warning $message

        [pscustomobject]@{
            Principal = $null
            Error     = $message
        }
    }
}

function New-JoinedReportRow {
    param(
        $Assignment,
        $ServicePrincipal,
        $Policy,
        $ScopeAddress,
        $ScopeType,
        [string[]]$Errors = @()
    )

    $pCode = $null
    $displayName = $null
    $appId = $null
    $spType = $null
    $createdDateTime = $null

    if ($ServicePrincipal) {
        $displayName = $ServicePrincipal.DisplayName
        $appId = $ServicePrincipal.AppId
        $spType = $ServicePrincipal.ServicePrincipalType

        if ($ServicePrincipal.AdditionalProperties) {
            $createdDateTime = $ServicePrincipal.AdditionalProperties['createdDateTime']
        }

        if ($displayName -match '(?i)\bP\d+') {
            $pCode = $Matches[0].ToUpperInvariant()
        }
    } elseif ($Policy) {
        # Retain the known AppId even when Graph resolution fails.
        $appId = $Policy.AppId
    }

    $rowType = if ($Assignment -and $Policy) {
        'RBAC + Policy'
    } elseif ($Assignment -and -not $ServicePrincipal) {
        'RBAC unresolved'
    } elseif ($Assignment) {
        'RBAC only'
    } else {
        'Policy only'
    }

    $errorMessages = @($Errors | Where-Object { $_ })

    [pscustomobject]@{
        RowType                 = $rowType
        LookupStatus            = if ($errorMessages.Count) { 'Failed' } else { 'OK' }
        Errors                  = $errorMessages -join ' | '
        Name                    = $Assignment.Name
        Role                    = $Assignment.Role
        RoleAssigneeName        = $Assignment.RoleAssigneeName
        RoleAssigneeType        = $Assignment.RoleAssigneeType
        AssignmentMethod        = $Assignment.AssignmentMethod
        EffectiveUserName       = $Assignment.EffectiveUserName
        App                     = $Assignment.App
        CustomResourceScope     = $Assignment.CustomResourceScope
        EffectiveScopeAddress   = $ScopeAddress
        EffectiveScopeType      = $ScopeType
        RecipientWriteScope     = $Assignment.RecipientWriteScope
        RADisplayName           = $displayName
        RAAppID                 = $appId
        SPType                  = $spType
        PCode                   = $pCode
        ExistingPolicy          = $Policy.ScopeName
        PolicyAppId             = $Policy.AppId
        PolicyIdentity          = $Policy.Identity
        PolicyScopeIdentity     = $Policy.ScopeIdentity
        PolicyAccessRight       = $Policy.AccessRight
        CreatedDateTime         = $createdDateTime
    }
}

$rbacAppIds = @{}
$spCache = @{}
$policySpCache = @{}

$res = @(
    foreach ($m in $mm) {
        $itemErrors = [System.Collections.Generic.List[string]]::new()

        $spId = [string]$m.EffectiveUserName
        if (-not $spCache.ContainsKey($spId)) {
            $spCache[$spId] = Resolve-ReportServicePrincipal `
                -ServicePrincipalId $spId
        }

        $lookup = $spCache[$spId]
        $rex = $lookup.Principal

        if ($lookup.Error) {
            $itemErrors.Add($lookup.Error)
        }

        $scopeType = $null
        $scopeAddress = $null

        # Scope resolution is independent of Graph resolution.
        try {
            switch ($m.RecipientWriteScope) {
                'CustomRecipientScope' {
                    $scopeType = 'RecipientFilter'
                    $scopeAddress = (
                        Get-ManagementScope -Identity $m.CustomResourceScope `
                            -ErrorAction Stop
                    ).RecipientFilter
                }
                'Group' {
                    $group = Get-Recipient -Identity $m.CustomResourceScope `
                        -ErrorAction Stop

                    $scopeType = $group.RecipientTypeDetails
                    $scopeAddress = [string]$group.PrimarySmtpAddress
                }
                default {
                    $scopeType = [string]$m.RecipientWriteScope
                }
            }
        } catch {
            $message = "Scope lookup failed for assignment '$($m.Name)' (scope '$($m.CustomResourceScope)'): $($_.Exception.Message)"
            Write-Warning $message
            $itemErrors.Add($message)
        }

        $policies = @()

        if ($rex) {
            $rbacAppIds[[string]$rex.AppId] = $true

            $policies = @(
                $applicationAccessPolicy |
                    Where-Object { $_.AppId -eq $rex.AppId }
            )
        }

        $rowParameters = @{
            Assignment       = $m
            ServicePrincipal = $rex
            ScopeAddress     = $scopeAddress
            ScopeType        = $scopeType
            Errors           = $itemErrors.ToArray()
        }

        if ($policies.Count -eq 0) {
            New-JoinedReportRow @rowParameters
        } else {
            foreach ($policy in $policies) {
                New-JoinedReportRow @rowParameters -Policy $policy
            }
        }
    }

    # Retain every policy not matched to a successfully resolved RBAC app.
    foreach ($policy in $applicationAccessPolicy) {
        $appId = [string]$policy.AppId

        if ($rbacAppIds.ContainsKey($appId)) {
            continue
        }

        if (-not $policySpCache.ContainsKey($appId)) {
            if ([string]::IsNullOrWhiteSpace($appId)) {
                $message = "Policy '$($policy.Identity)' has no AppId."
                Write-Warning $message

                $policySpCache[$appId] = [pscustomobject]@{
                    Principal = $null
                    Error     = $message
                }
            } else {
                $policySpCache[$appId] = Resolve-ReportServicePrincipal -AppId $appId
            }
        }

        $lookup = $policySpCache[$appId]

        New-JoinedReportRow -ServicePrincipal $lookup.Principal `
            -Policy $policy -Errors @($lookup.Error)
    }
)

$res | Select-Object *

$filename = '_RBACforApps_{0}.xlsx' -f (Get-Date -Format 'yyyyMMdd_HHmmss')

if ($res.Count -gt 0) {
    $res | Export-Excel -Path $filename -Verbose -Title RBACforApps `
        -TableName RBACforAppsTBL -WorksheetName RbacforApps `
        -ErrorAction Stop
} else {
    Write-Warning 'No RBAC assignments or Application Access Policies were found; no workbook was exported.'
}