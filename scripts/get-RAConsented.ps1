# Cache all resource service principals to quickly resolve AppRole IDs to friendly names
Write-Host "Caching resource Service Principals..." -ForegroundColor Cyan
$AllServicePrincipals = Get-MgServicePrincipal -All -Property Id, AppId, DisplayName, AppRoles
$SpLookup = @{}
foreach ($sp in $AllServicePrincipals) {
    $SpLookup[$sp.Id] = $sp
}

# Fetch all App Registrations in the tenant
Write-Host "Retrieving Registered Applications..." -ForegroundColor Cyan
$Apps = Get-MgApplication -All -Property Id, AppId, DisplayName

$Report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($app in $Apps) {
    # Resolve the local Service Principal (Enterprise App) associated with the App Registration
    $clientSp = $AllServicePrincipals | Where-Object { $_.AppId -eq $app.AppId }
    
    if (-not $clientSp) {
        continue
    }

    # Retrieve granted application permissions (AppRoleAssignments where this SP is the principal)
    $assignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $clientSp.Id -All -ErrorAction SilentlyContinue

    foreach ($assignment in $assignments) {
        $resourceSp = $SpLookup[$assignment.ResourceId]
        $roleName = "Unknown/Custom ID: $($assignment.AppRoleId)"

        if ($resourceSp) {
            $matchingRole = $resourceSp.AppRoles | Where-Object { $_.Id -eq $assignment.AppRoleId }
            if ($matchingRole) {
                $roleName = $matchingRole.Value
            }
        }

        $Report.Add([PSCustomObject]@{
            ApplicationName      = $app.DisplayName
            ApplicationId        = $app.AppId
            ServicePrincipalId   = $clientSp.Id
            TargetResourceName   = if ($resourceSp) { $resourceSp.DisplayName } else { "Unknown" }
            TargetResourceAppId  = if ($resourceSp) { $resourceSp.AppId } else { "Unknown" }
            PermissionName       = $roleName
            AssignmentId         = $assignment.Id
            CreatedDateTime      = $assignment.CreatedDateTime
        })
    }
}

# Output to console table
$Report | Format-Table ApplicationName, TargetResourceName, PermissionName -AutoSize

# Export to CSV
$Report | Export-Csv -Path "./EntraID_ApplicationPermissions_Report.csv" -NoTypeInformation
Write-Host "Report exported successfully to EntraID_ApplicationPermissions_Report.csv" -ForegroundColor Green