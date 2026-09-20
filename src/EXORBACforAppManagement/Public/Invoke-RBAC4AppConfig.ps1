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

Every creation step is idempotent, matching New-RBAC4AppEntry: the scope group, the EXO service
principal, and each role assignment are only created if a matching one does not already exist -
a role assignment that already exists and is scoped to the same group is left alone (a warning
notes it was skipped); requested members are still added to the group regardless.

.PARAMETER Path
Path to the YAML file produced by New-RBAC4AppConfig.

.EXAMPLE
Invoke-RBAC4AppConfig -Path .\rbac4app-ContosoMailApp-202609200830.yml -WhatIf
Invoke-RBAC4AppConfig -Path .\rbac4app-ContosoMailApp-202609200830.yml

.OUTPUTS
PSCustomObject — same summary shape as New-RBAC4AppEntry (ResolvedDisplay, AppId, SpObjectId,
ScopeGroupName, RolesNormalized, RoleAssignmentsName, MembersAdded, MembersFinal, Warnings,
Errors, etc.).
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

        if ($config.SchemaVersion -ne '2.0') {
            Write-Error "Config '$Path' has SchemaVersion '$($config.SchemaVersion)', but this version of Invoke-RBAC4AppConfig requires '2.0' (scope-group settings moved from Rbac: to their own RbacScope: section). Re-generate the config with New-RBAC4AppConfig."
            return
        }
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

        $AccessGroupType = $config.RbacScope.AccessGroupType
        $GroupPrefix     = $config.RbacScope.GroupPrefix
        $AccessGroupName = $config.RbacScope.AccessGroupName
        $Members         = @($config.RbacScope.Members)
        $ManagedBy       = $config.RbacScope.ManagedBy
        $BootstrapMember = $config.RbacScope.BootstrapMember
        $roles           = @($config.Rbac.Roles)

        $result = [ordered]@{
            ParameterSet        = 'ByConfig'
            IdentityInput       = $Path
            ResolvedDisplay     = $spDisplayName
            AppId               = $spAppId
            SpObjectId          = $spId
            TenantId            = $config.TenantId
            AccessGroupType     = $AccessGroupType
            ScopeGroupName      = $null
            OwnerRequested      = $ManagedBy
            OwnerAdded          = $null
            MembersRequested    = @($Members)
            MembersAdded        = @()
            MembersFinal        = @()
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
            $result.ScopeGroupName = $umGroupName

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

            # --- Read the group's current membership once (all types, read-only): seeds MembersFinal
            # below and is reused rather than re-queried after any additions (EXO reads can lag
            # writes, so a fresh post-write read would not reliably reflect what was just added).
            $existingLinks = if ($AccessGroupType -eq 'M365Group') {
                @(Get-UnifiedGroupLinks -Identity $umGroupName -LinkType Members -ErrorAction SilentlyContinue)
            }
            else {
                @(Get-DistributionGroupMember -Identity $umGroupName -ErrorAction SilentlyContinue)
            }
            $existingMemberIdentities = @($existingLinks | ForEach-Object {
                    if ($_.PrimarySmtpAddress) { [string]$_.PrimarySmtpAddress } else { [string]$_.Name }
                } | Where-Object { $_ } | Select-Object -Unique)

            # --- MailEnabledSecurityGroup is on-prem/hybrid-synced: it is never created or modified
            # here, so warn about any group-modifying config value that was ignored.
            if ($AccessGroupType -eq 'MailEnabledSecurityGroup') {
                if ($Members -and ($Members | Where-Object { $_ -and $_ -ne 'GraphAPI-Dummy' })) {
                    $skipMsg = "Membership of MailEnabledSecurityGroup '$umGroupName' is managed on-premises; Members from config was ignored."
                    $result.Warnings += $skipMsg
                    Write-Warning $skipMsg
                }
                if ($ManagedBy -and $ManagedBy -ne 'GraphAPI-Dummy-owner') {
                    $skipOwnerMsg = "Ownership of MailEnabledSecurityGroup '$umGroupName' is managed on-premises; ManagedBy from config was ignored."
                    $result.Warnings += $skipOwnerMsg
                    Write-Warning $skipOwnerMsg
                }
                if ($BootstrapMember -and $BootstrapMember -ne 'GraphAPI-Dummy') {
                    $skipBootstrapMsg = "Initial membership of MailEnabledSecurityGroup '$umGroupName' is managed on-premises; BootstrapMember from config was ignored."
                    $result.Warnings += $skipBootstrapMsg
                    Write-Warning $skipBootstrapMsg
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

            $result.MembersFinal = @($existingMemberIdentities + $result.MembersAdded | Select-Object -Unique)

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

                # --- Skip creation if a role assignment with this deterministic name already
                # exists, so re-running against an already-provisioned app is idempotent. Members
                # were already added above regardless of this check.
                $existingAssignment = Get-ManagementRoleAssignment -Identity $rbacNameBase -ErrorAction SilentlyContinue
                if ($existingAssignment) {
                    $scopedToTarget = ([string]$existingAssignment.RecipientWriteScope -in @('Group', 'CustomRecipientScope')) -and
                        ([string]$existingAssignment.CustomRecipientWriteScope -eq $umGroupName)
                    if ($scopedToTarget) {
                        $existsMsg = "Role assignment '$rbacNameBase' already exists and is scoped to '$umGroupName'; skipping creation."
                    }
                    else {
                        $existsMsg = "Role assignment '$rbacNameBase' already exists but is scoped to '$([string]$existingAssignment.CustomRecipientWriteScope)', not '$umGroupName'; leaving it as-is. Use Set-RBAC4AppEntry to re-scope it."
                    }
                    $result.Warnings += $existsMsg
                    Write-Warning -Message $existsMsg
                    $result.RoleAssignments += $existingAssignment
                    continue
                }

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
                $exportPath = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}_{1}.clixml" -f $rbacNameBase, (Get-Date -Format s).Replace(':', ''))
                [pscustomobject]$result | Export-Clixml $exportPath -Verbose
            }
        }
        catch {
            $result.Errors += $_.Exception.Message
            [pscustomobject]$result
        }
    }
}
