<#
.SYNOPSIS
Creates sample Entra app registrations with a selection of Microsoft Graph application permissions.

.DESCRIPTION
Creates 140 application registrations and service principals using the Microsoft Graph PowerShell
SDK. The applications are split evenly across four permission profiles: Mail.Send; Mail.Send and
Mail.ReadWrite; Calendars.ReadWrite; and no Microsoft Graph application permissions.

Each granted permission is added to RequiredResourceAccess and receives tenant admin consent through
New-MgServicePrincipalAppRoleAssignment. Requires a connected Graph session with
Application.ReadWrite.All and AppRoleAssignment.ReadWrite.All.

.PARAMETER NamePrefix
Text included in generated application display names. Each name starts with a unique random token,
followed by this prefix, a timestamp, a run token, and a sequence number.

.PARAMETER Count
Number of applications to create. Must be divisible by four. Defaults to 140.

.EXAMPLE
Connect-MgGraph -Scopes 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All'
./utils/New-SampleRegisteredApps.ps1 -WhatIf

Shows the planned batch without creating applications or granting permissions.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateNotNullOrEmpty()]
    [string] $NamePrefix = 'EXORBAC-Sample',

    [ValidateRange(4, 1000)]
    [int] $Count = 140
)

$ErrorActionPreference = 'Stop'

if (($Count % 4) -ne 0) {
    throw 'Count must be divisible by four so each permission profile has the same number of applications.'
}

$connectHint = "Connect to Microsoft Graph before running this script (for example, Connect-MgGraph -Scopes 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All')."

# Get-MgContext is informational only: after a WAM sign-in it can come back without a TenantId (or
# empty) even though the session works. The real connectivity check is the Graph call below.
$context = $null
try { $context = Get-MgContext -ErrorAction Stop }
catch { Write-Verbose "Get-MgContext failed: $($_.Exception.Message)" }

$graphAppId = '00000003-0000-0000-c000-000000000000'
try {
    $graphServicePrincipal = @(
        Get-MgServicePrincipal -Filter "appId eq '$graphAppId'" -Property Id, AppRoles -ErrorAction Stop
    ) | Select-Object -First 1
}
catch {
    throw "$connectHint Microsoft Graph call failed: $($_.Exception.Message)"
}

$tenantId = if ($context) { [string]$context.TenantId } else { '' }
if (-not $tenantId) {
    try { $tenantId = [string](@(Get-MgOrganization -Property Id -ErrorAction Stop) | Select-Object -First 1).Id }
    catch { Write-Verbose "Get-MgOrganization failed: $($_.Exception.Message)" }
}
if (-not $tenantId) {
    Write-Warning 'The tenant id could not be read from Get-MgContext or Get-MgOrganization; continuing with the connected Graph session.'
    $tenantId = 'connected tenant'
}

$grantedScopes = @()
if ($context) { $grantedScopes = @($context.Scopes) }
if ($grantedScopes.Count -gt 0) {
    foreach ($scope in @('Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All')) {
        if ($grantedScopes -notcontains $scope) {
            Write-Warning "The Graph session does not list the '$scope' scope; creating applications or granting permissions may fail."
        }
    }
}
if (-not $graphServicePrincipal) {
    throw 'The Microsoft Graph service principal could not be found in this tenant.'
}

$permissionProfiles = @(
    [pscustomobject]@{ Name = 'Mail.Send'; Permissions = @('Mail.Send') }
    [pscustomobject]@{ Name = 'Mail.Send and Mail.ReadWrite'; Permissions = @('Mail.Send', 'Mail.ReadWrite') }
    [pscustomobject]@{ Name = 'Calendars.ReadWrite'; Permissions = @('Calendars.ReadWrite') }
    [pscustomobject]@{ Name = 'No Microsoft Graph application permissions'; Permissions = @() }
)

$roleIds = @{}
foreach ($permission in @('Mail.Send', 'Mail.ReadWrite', 'Calendars.ReadWrite')) {
    $role = @($graphServicePrincipal.AppRoles | Where-Object {
        $_.Value -ceq $permission -and $_.IsEnabled -and $_.AllowedMemberTypes -contains 'Application'
    }) | Select-Object -First 1
    if (-not $role) {
        throw "The enabled Microsoft Graph application role '$permission' could not be found."
    }
    $roleIds[$permission] = $role.Id
}

$runId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
$perProfile = $Count / 4
$usedNamePrefixes = @{}
if (-not $PSCmdlet.ShouldProcess(
    "tenant '$tenantId'",
    "Create $Count sample app registrations, service principals, and their configured application permission grants"
)) {
    return
}

for ($index = 1; $index -le $Count; $index++) {
    $permissionProfile = $permissionProfiles[[math]::Floor(($index - 1) / $perProfile)]
    do {
        $namePrefixToken = [guid]::NewGuid().ToString('N').Substring(0, 8)
    } while ($usedNamePrefixes.ContainsKey($namePrefixToken))
    $usedNamePrefixes[$namePrefixToken] = $true
    $displayName = '{0}-{1}-{2}-{3:D3}' -f $namePrefixToken, $NamePrefix, $runId, $index

    $requiredResourceAccess = @()
    if ($permissionProfile.Permissions.Count -gt 0) {
        $requiredResourceAccess = @(
            @{
                ResourceAppId = $graphAppId
                ResourceAccess = @(
                    foreach ($permission in $permissionProfile.Permissions) {
                        @{ Id = $roleIds[$permission]; Type = 'Role' }
                    }
                )
            }
        )
    }

    Write-Verbose "Creating application $index of $Count ('$displayName'): $($permissionProfile.Name)."
    $application = New-MgApplication -DisplayName $displayName `
        -SignInAudience 'AzureADMyOrg' `
        -RequiredResourceAccess $requiredResourceAccess `
        -ErrorAction Stop
    $servicePrincipal = New-MgServicePrincipal -AppId $application.AppId -ErrorAction Stop

    foreach ($permission in $permissionProfile.Permissions) {
        New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $servicePrincipal.Id `
            -PrincipalId $servicePrincipal.Id `
            -ResourceId $graphServicePrincipal.Id `
            -AppRoleId $roleIds[$permission] `
            -ErrorAction Stop | Out-Null
    }

    [pscustomobject]@{
        DisplayName        = $displayName
        AppId              = $application.AppId
        AppObjectId        = $application.Id
        ServicePrincipalId = $servicePrincipal.Id
        PermissionProfile  = $permissionProfile.Name
        Permissions        = @($permissionProfile.Permissions)
    }
}
