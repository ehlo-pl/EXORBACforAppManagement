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
Prefix for generated application display names. A timestamp, unique run token, and sequence number are appended.

.PARAMETER Count
Number of applications to create. Must be divisible by four. Defaults to 140.

.EXAMPLE
Connect-MgGraph -Scopes 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All'
./scripts/New-SampleRegisteredApps.ps1 -WhatIf

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

$context = Get-MgContext
if (-not $context -or -not $context.TenantId) {
    throw "Connect to Microsoft Graph before running this script (for example, Connect-MgGraph -Scopes 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All')."
}

$graphAppId = '00000003-0000-0000-c000-000000000000'
$graphServicePrincipal = @(
    Get-MgServicePrincipal -Filter "appId eq '$graphAppId'" -Property Id, AppRoles -ErrorAction Stop
) | Select-Object -First 1
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
if (-not $PSCmdlet.ShouldProcess(
    "tenant '$($context.TenantId)'",
    "Create $Count sample app registrations, service principals, and their configured application permission grants"
)) {
    return
}

for ($index = 1; $index -le $Count; $index++) {
    $permissionProfile = $permissionProfiles[[math]::Floor(($index - 1) / $perProfile)]
    $displayName = '{0}-{1}-{2:D3}' -f $NamePrefix, $runId, $index

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
