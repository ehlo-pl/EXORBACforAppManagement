<#
.SYNOPSIS
Provisions Exchange Online RBAC from a YAML config file written by New-RBAC4AppConfig.

.DESCRIPTION
Invoke-RBAC4AppConfig is the ExchangeOnlineManagement half of the two-session workflow.
It reads a YAML config file produced by New-RBAC4AppConfig (which runs in a Microsoft Graph
session) and provisions every Exchange Online resource — scope group creation, member addition,
EXO service principal registration, and management role assignment — without calling any
Microsoft Graph cmdlets.

This separates the two modules into distinct PowerShell sessions, avoiding the MSAL/WAM
assembly conflict that can occur when both Microsoft.Graph and ExchangeOnlineManagement are
loaded in the same process.

.PARAMETER Path
Path to the YAML file produced by New-RBAC4AppConfig.

.EXAMPLE
Invoke-RBAC4AppConfig -Path .\rbac4app-ContosoMailApp-202609200830.yml -WhatIf
Invoke-RBAC4AppConfig -Path .\rbac4app-ContosoMailApp-202609200830.yml

.OUTPUTS
PSCustomObject — same summary shape as New-RBAC4AppEntry (ResolvedDisplay, AppId, SpObjectId,
UnifiedGroupName, RolesNormalized, RoleAssignmentsName, MembersAdded, Warnings, Errors, etc.).
#>
function Invoke-RBAC4AppConfig {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    begin {
        $shortRoleMap = Get-AppRoleMap
    }

    process {
        # --- Read and validate the config file
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Write-Error "Config file not found: '$Path'"
            return
        }

        $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $config  = ConvertFrom-RBAC4AppYaml -Content $content

        if (-not $config.Application.SpObjectId) {
            Write-Error "Config '$Path' is missing Application.SpObjectId. Re-generate with New-RBAC4AppConfig."
            return
        }
        if (-not $config.Application.AppId) {
            Write-Error "Config '$Path' is missing Application.AppId. Re-generate with New-RBAC4AppConfig."
            return
        }
        if (-not $config.Application.DisplayName) {
            Write-Error "Config '$Path' is missing Application.DisplayName. Re-generate with New-RBAC4AppConfig."
            return
        }

        $spId          = $config.Application.SpObjectId
        $spAppId       = $config.Application.AppId
        $spDisplayName = $config.Application.DisplayName

        $AccessGroupType = $config.Rbac.AccessGroupType
        $GroupPrefix     = $config.Rbac.GroupPrefix
        $AccessGroupName = $config.Rbac.AccessGroupName
        $Members         = @($config.Rbac.Members)
        $ManagedBy       = $config.Rbac.ManagedBy
        $BootstrapMember = $config.Rbac.BootstrapMember
        $roles           = @($config.Rbac.Roles)

        $result = [ordered]@{
            ParameterSet        = 'ByConfig'
            IdentityInput       = $Path
            ResolvedDisplay     = $spDisplayName
            AppId               = $spAppId
            SpObjectId          = $spId
            TenantId            = $config.TenantId
            AccessGroupType     = $AccessGroupType
            UnifiedGroupName    = $null
            OwnerRequested      = $ManagedBy
            OwnerAdded          = $null
            MembersRequested    = @($Members)
            MembersAdded        = @()
            FilteredMembers     = @()
            RolesNormalized     = @()
            RoleAssignments     = @()
            RoleAssignmentsName = @()
            Warnings            = @()
            Errors              = @()
        }

        try {
            # --- Derive scope group name
            if ($AccessGroupName) {
                $umGroupName = $AccessGroupName
            }
            elseif ($AccessGroupType -eq 'MailEnabledSecurityGroup') {
                throw "-AccessGroupName is required when AccessGroupType is MailEnabledSecurityGroup. Re-generate the config with -AccessGroupName set."
            }
            else {
                $umGroupName = Get-SafeName -s ('{0}-{1}' -f $GroupPrefix, $spDisplayName)
            }
            $result.UnifiedGroupName = $umGroupName

            # --- Ensure scope group
            Write-Verbose ("Checking {0} '{1}' for service principal '{2}' ({3})." -f $AccessGroupType, $umGroupName, $spDisplayName, $spId)
            $ugResult = New-RBAC4AppScopeGroup -AccessGroupType $AccessGroupType -Name $umGroupName -ManagedBy $ManagedBy -BootstrapMember $BootstrapMember -WarningVariable ugWarnings
            foreach ($w in $ugWarnings) {
                if ([string]$w.Message -like '*already exists*') { $result.Warnings += [string]$w.Message }
            }
            if ($ugResult) {
                $result.OwnerRequested = $ugResult.OwnerRequested
                $result.OwnerAdded     = $ugResult.OwnerAdded
            }

            # --- Add members (MailEnabledSecurityGroup membership is on-prem only)
            if ($AccessGroupType -eq 'MailEnabledSecurityGroup') {
                if ($Members -and ($Members | Where-Object { $_ -and $_ -ne 'GraphAPI-Dummy' })) {
                    $skipMsg = "Membership of MailEnabledSecurityGroup '$umGroupName' is managed on-premises; Members from config was ignored."
                    $result.Warnings += $skipMsg
                    Write-Warning $skipMsg
                }
            }
            else {
                foreach ($member in $Members) {
                    if (-not $member) { continue }
                    $rec = Get-Recipient -Identity $member -ErrorAction SilentlyContinue
                    if (-not $rec) {
                        $result.Warnings += "Recipient not found for '$member' (skipped)."
                        continue
                    }
                    if ($PSCmdlet.ShouldProcess("$AccessGroupType $umGroupName", "Add member $($rec.PrimarySmtpAddress)")) {
                        if ($AccessGroupType -eq 'DistributionList') {
                            Add-DistributionGroupMember -Identity $umGroupName -Member $rec.PrimarySmtpAddress -ErrorAction Stop
                        }
                        else {
                            Add-UnifiedGroupLinks -Identity $umGroupName -LinkType Members -Links $rec.PrimarySmtpAddress -ErrorAction Stop
                        }
                    }
                    $result.MembersAdded += [string]$rec.PrimarySmtpAddress
                }
            }

            # --- Register EXO service principal
            $exoSpDisplay = '{0}_SP' -f $spDisplayName
            $null = Register-EXOServicePrincipal -AppId $spAppId -ObjectId $spId -DisplayName $exoSpDisplay

            # --- Role assignments
            $rolesNormalized = @(foreach ($r in $roles) { Get-NormalizeRole $r })
            $result.RolesNormalized = @($rolesNormalized)

            $rbacNameBase = $null
            foreach ($roleItem in $rolesNormalized) {
                $shortName    = $shortRoleMap[$roleItem]
                $rbacNameBase = Get-SafeName -s ('{0}-{1}' -f $shortName, $spDisplayName) -max 63
                $result.RoleAssignmentsName += $rbacNameBase

                if ($PSCmdlet.ShouldProcess('RBAC role assignment', "Assign '$roleItem' to App '$spDisplayName' scoped to '$umGroupName'")) {
                    $assignment = New-ManagementRoleAssignment `
                        -App $spId `
                        -Role $roleItem `
                        -RecipientGroupScope $umGroupName `
                        -Name $rbacNameBase `
                        -ErrorAction Stop
                    $result.RoleAssignments += $assignment
                }
            }

            [pscustomobject]$result
            if ($rbacNameBase) {
                [pscustomobject]$result | Export-Clixml ('{0}/{1}_{2}.clixml' -f $env:TEMP, $rbacNameBase, (Get-Date -Format s).Replace(':', '')) -Verbose
            }
        }
        catch {
            $result.Errors += $_.Exception.Message
            [pscustomobject]$result
        }
    }
}
