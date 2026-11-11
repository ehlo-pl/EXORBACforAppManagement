param(
    [string]$CsvPath = './EntraID_Permissions_vs_ExoPolicies.csv'
)

# ==============================================================================
# 0. VERIFY REQUIRED SESSIONS
# ==============================================================================
if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue)) {
    Write-Error "No active Exchange Online session found. Connect first with Connect-ExchangeOnline."
    return
}
if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
    Write-Error "No active Microsoft Graph session found. Connect first with Connect-MgGraph (Application.Read.All scope)."
    return
}

# ==============================================================================
# 1. RETRIEVE EXCHANGE ONLINE APPLICATION ACCESS POLICIES
# ==============================================================================
Write-Host "Querying Exchange Online Application Access Policies..." -ForegroundColor Cyan

$PolicyLookup = @{}
try {
    # Attempt to retrieve all existing policies
    $exoPolicies = Get-ApplicationAccessPolicy -ErrorAction Stop
    
    foreach ($policy in $exoPolicies) {
        $appKey = $policy.AppId.ToString()
        if (-not $PolicyLookup.ContainsKey($appKey)) {
            $PolicyLookup[$appKey] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }
        $PolicyLookup[$appKey].Add($policy)
    }
    Write-Host "Found $($exoPolicies.Count) Application Access Policy/Policies." -ForegroundColor Green
}
catch {
    # Catch the specific 'Object couldn't be found' error representing 0 policies
    if ($_.Exception.Message -match "couldn't be found on" -or 
        $_.Exception.GetType().FullName -eq "Microsoft.Exchange.Configuration.Tasks.ManagementObjectNotFoundException") {
        Write-Warning "No Application Access Policies currently exist in this tenant. Treating policy list as empty."
    }
    else {
        Write-Error "Unexpected error querying Exchange Online: $($_.Exception.Message)"
        return
    }
}

# ==============================================================================
# 2. CACHE SERVICE PRINCIPALS & RESOLVE PERMISSIONS
# ==============================================================================
Write-Host "Caching Entra ID Service Principals for ID resolution..." -ForegroundColor Cyan
$AllServicePrincipals = Get-MgServicePrincipal -All -Property Id, AppId, DisplayName, AppRoles
$SpLookup = @{}
$SpByAppId = @{}
foreach ($sp in $AllServicePrincipals) {
    $SpLookup[$sp.Id] = $sp
    if (-not $SpByAppId.ContainsKey($sp.AppId)) {
        $SpByAppId[$sp.AppId] = $sp
    }
}

Write-Host "Retrieving registered applications..." -ForegroundColor Cyan
$Apps = Get-MgApplication -All -Property Id, AppId, DisplayName

# Permissions that allow tenant-wide mailbox/calendar access if unscoped
$ExchangeRelevantPermissions = @(
    "Mail.Read", "Mail.ReadWrite", "Mail.Send", "Mail.ReadBasic.All",
    "Calendars.Read", "Calendars.ReadWrite",
    "Contacts.Read", "Contacts.ReadWrite",
    "full_access_as_app"
)

# Known Resource App IDs for Graph and Exchange Online
$GraphAppId = "00000003-0000-0000-c000-000000000001"
$ExoAppId   = "00000002-0000-0ff1-ce00-000000000000"

# ==============================================================================
# 3. CORRELATE PERMISSIONS WITH APPLICATION ACCESS POLICIES
# ==============================================================================
$Report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($app in $Apps) {
    $clientSp = $SpByAppId[$app.AppId]
    if (-not $clientSp) { continue }

    # Retrieve granted AppRole assignments (App-only permissions)
    $assignmentErrors = $null
    $assignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $clientSp.Id -All -ErrorAction SilentlyContinue -ErrorVariable assignmentErrors
    if ($assignmentErrors) {
        Write-Warning "Failed to retrieve app role assignments for '$($app.DisplayName)' ($($app.AppId)): $($assignmentErrors[0].Exception.Message)"
    }

    # Check if this app has any EXO policies associated
    $appPolicies = if ($PolicyLookup.ContainsKey($app.AppId)) { $PolicyLookup[$app.AppId] } else { @() }
    $hasPolicy   = ($appPolicies.Count -gt 0)
    $scopeNames  = if ($hasPolicy) { ($appPolicies.ScopeName | Where-Object { $_ } | Select-Object -Unique) -join "; " } else { $null }

    foreach ($assignment in $assignments) {
        $resourceSp = $SpLookup[$assignment.ResourceId]
        $roleName   = "Unknown/Custom ID: $($assignment.AppRoleId)"

        if ($resourceSp) {
            $matchingRole = $resourceSp.AppRoles | Where-Object { $_.Id -eq $assignment.AppRoleId }
            if ($matchingRole) {
                $roleName = $matchingRole.Value
            }
        }

        # Determine if this permission interacts with mailboxes
        $isMailRelated = ($resourceSp.AppId -in @($GraphAppId, $ExoAppId)) -and ($roleName -in $ExchangeRelevantPermissions)

        # Evaluate risk/scoping status
        $mailboxScopeStatus = "N/A (Non-Mailbox Permission)"
        if ($isMailRelated) {
            if ($hasPolicy) {
                $policyActions = ($appPolicies | ForEach-Object { "$($_.AccessRight) -> $($_.PolicyScopeGroupId)" }) -join "; "
                $mailboxScopeStatus = "Scoped via Policy: [$policyActions]"
            }
            else {
                $mailboxScopeStatus = "HIGH RISK: Unrestricted Tenant-Wide Access (No Policy)"
            }
        }

        $Report.Add([PSCustomObject]@{
            ApplicationName        = $app.DisplayName
            ApplicationId          = $app.AppId
            TargetResourceName     = if ($resourceSp) { $resourceSp.DisplayName } else { "Unknown" }
            PermissionGranted      = $roleName
            IsMailboxRelated       = $isMailRelated
            HasAccessPolicy        = $hasPolicy
            PolicyCount            = $appPolicies.Count
            ScopeName              = $scopeNames
            MailboxScopeStatus     = $mailboxScopeStatus
            PolicyDetails          = if ($hasPolicy) { ($appPolicies.Description -join " | ") } else { "None" }
        })
    }
}

# ==============================================================================
# 4. DISPLAY SUMMARY AND EXPORT
# ==============================================================================
# Filter out high-risk apps to display immediately on console
$UnscopedMailApps = $Report | Where-Object { $_.MailboxScopeStatus -like "HIGH RISK*" }

if ($UnscopedMailApps) {
    Write-Host "`n[!] FOUND APPS WITH UNRESTRICTED TENANT-WIDE MAILBOX PERMISSIONS:" -ForegroundColor Yellow
    $UnscopedMailApps | Select-Object ApplicationName, PermissionGranted, MailboxScopeStatus | Format-Table -AutoSize
} else {
    Write-Host "`nNo applications found with unrestricted tenant-wide mailbox permissions." -ForegroundColor Green
}

# Export full report
if (Test-Path -LiteralPath $CsvPath) {
    $directory = Split-Path -Path $CsvPath -Parent
    $baseName  = [System.IO.Path]::GetFileNameWithoutExtension($CsvPath)
    $extension = [System.IO.Path]::GetExtension($CsvPath)
    $suffix    = ('_{0:00000}_{1:yyyy-MM-dd}_{1:mm-hh-ss}' -f (Get-Random), (Get-Date))
    $CsvPath   = Join-Path -Path $directory -ChildPath "$baseName$suffix$extension"
    Write-Warning "Output file already exists. Writing to '$CsvPath' instead."
}
$Report | Export-Csv -Path $CsvPath -NoTypeInformation
Write-Host "`nFull comparison report exported to: $CsvPath" -ForegroundColor Green