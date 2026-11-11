#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Regression tests for the review findings fixed in 0.9.0 (plans/GET-RBAC4APPENTRY_ANALYSIS.md,
# F1-F10). Written in Phase 0 as skipped "known issue" tests that failed against 0.8.x; un-skipped
# in Phase 2/3 once fixed. F4/F5 (-ApplicationAccessPolicy) were fixed by removing the switch; F9
# (export of a guessed group type) is covered in Export-RBAC4AppConfig.Tests.ps1.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    function global:Get-ServicePrincipal { [CmdletBinding()] param([string]$Identity) }
    function global:Get-ManagementRoleAssignment { [CmdletBinding()] param([string]$Role, [string]$Identity) }
    function global:Get-UnifiedGroup { [CmdletBinding()] param([string]$Identity) }
    function global:Get-UnifiedGroupLinks { [CmdletBinding()] param([string]$Identity, [string]$LinkType) }
    function global:Get-DistributionGroup { [CmdletBinding()] param([string]$Identity) }
    function global:Get-DistributionGroupMember { [CmdletBinding()] param([string]$Identity) }
    function global:Get-ManagementScope { [CmdletBinding()] param([string]$Identity) }
    function global:Get-Recipient { [CmdletBinding()] param([string]$Identity, [string]$RecipientPreviewFilter, [string]$Anr, $ResultSize) }

    $script:KiServicePrincipals = @(
        [pscustomobject]@{ DisplayName = 'Contoso_SP'; AppId = '11111111-1111-1111-1111-111111111111'; ObjectId = '22222222-2222-2222-2222-222222222222' }
        [pscustomobject]@{ DisplayName = 'Fabrikam_SP'; AppId = '33333333-3333-3333-3333-333333333333'; ObjectId = '44444444-4444-4444-4444-444444444444' }
        [pscustomobject]@{ DisplayName = 'Mail_SP'; AppId = '55555555-5555-5555-5555-555555555555'; ObjectId = '66666666-6666-6666-6666-666666666666' }
        [pscustomobject]@{ DisplayName = 'MailArchiver_SP'; AppId = '77777777-7777-7777-7777-777777777777'; ObjectId = '88888888-8888-8888-8888-888888888888' }
    )

    # Legacy group-scoped assignments (no management scope), so scope resolution stays simple.
    $newAssignment = {
        param([string] $Name, [string] $Assignee, [string] $Group, [string] $Type = 'ServicePrincipal')
        [pscustomobject]@{
            Name = $Name; Role = 'Application Mail.Send'; RoleAssigneeName = $Assignee; RoleAssigneeType = $Type
            CustomRecipientWriteScope = $null; CustomResourceScope = "{0}_20d5848c-4d61-4b82-a44f-205adc37321f" -f $Group
            RecipientWriteScope = 'Group'; Enabled = $true; Guid = [guid]::NewGuid(); Identity = $Name
            EffectiveUserName = $null; App = $null
        }
    }
    $script:KiAssignments = @(
        & $newAssignment 'AppMailSend-Contoso' '22222222-2222-2222-2222-222222222222' 'UDLRAo1P-Contoso'
        & $newAssignment 'AppMailSend-Fabrikam' '44444444-4444-4444-4444-444444444444' 'UDLRAo1P-Fabrikam'
        & $newAssignment 'AppMailSend-Mail' '66666666-6666-6666-6666-666666666666' 'UDLRAo1P-Mail'
        & $newAssignment 'AppMailSend-MailArchiver' '88888888-8888-8888-8888-888888888888' 'UDLRAo1P-MailArchiver'
        & $newAssignment 'AppMailSend-Helpdesk' 'Helpdesk' 'UDLRAo1P-Helpdesk' 'RoleGroup'
    )
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-ServicePrincipal', 'Get-ManagementRoleAssignment', 'Get-UnifiedGroup', 'Get-UnifiedGroupLinks', 'Get-DistributionGroup', 'Get-DistributionGroupMember', 'Get-ManagementScope', 'Get-Recipient') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'Get-RBAC4AppEntry regressions (F1-F10)' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment { $script:KiAssignments }
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal { $script:KiServicePrincipals }
        Mock -ModuleName EXORBACforAppManagement Get-UnifiedGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup {
            [pscustomobject]@{ Identity = $Identity; RecipientTypeDetails = 'MailUniversalDistributionGroup' }
        }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroupMember { }
    }

    It 'F1: reads Exchange Online once per call, not once per pipeline item' -Tag 'Regression', 'F1' {
        $null = 'Contoso', 'Fabrikam' | Get-RBAC4AppEntry

        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-ManagementRoleAssignment -Times 1 -Exactly
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-ServicePrincipal -Times 1 -Exactly
    }

    It 'F2: an application filter matches the exact identity, not a substring' -Tag 'Regression', 'F2' {
        # 0.8.x matched the needle 'Mail' against every assignment name (AppMailSend-...).
        $r = @(Get-RBAC4AppEntry -RegisteredAppName 'Mail')

        $r.Name | Should -Be @('AppMailSend-Mail')
    }

    It 'F3: a failed role assignment read is reported, not treated as an empty tenant' -Tag 'Regression', 'F3' {
        # Honor the caller's -ErrorAction the way a real EXO cmdlet does (a plain Write-Error in a
        # mock ignores it), so SilentlyContinue really swallows the error and Stop really throws.
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            $action = if ($PesterBoundParameters.ContainsKey('ErrorAction')) { $PesterBoundParameters['ErrorAction'] } else { 'Continue' }
            Write-Error 'Access denied' -ErrorAction $action
        }

        # -ErrorVariable also collects errors that nested commands suppress, so it cannot tell
        # "reported" from "swallowed"; -ErrorAction Stop only throws for an error the function
        # itself writes (D6: Write-Error once per call).
        { Get-RBAC4AppEntry -ErrorAction Stop } | Should -Throw '*Access denied*'
    }

    It 'F3: a failed service principal directory read is reported' -Tag 'Regression', 'F3' {
        Mock -ModuleName EXORBACforAppManagement Get-ServicePrincipal {
            $action = if ($PesterBoundParameters.ContainsKey('ErrorAction')) { $PesterBoundParameters['ErrorAction'] } else { 'Continue' }
            Write-Error 'Directory read failed' -ErrorAction $action
        }

        { Get-RBAC4AppEntry -ErrorAction Stop -WarningAction SilentlyContinue } | Should -Throw '*Directory read failed*'
    }

    It 'F6: Get-RBAC4AppApplication does not present a role group as an application' -Tag 'Regression', 'F6' {
        $helpdesk = Get-RBAC4AppApplication -RoleAssigneeType All -WarningAction SilentlyContinue | Where-Object ExoServicePrincipal -eq 'Helpdesk'

        $helpdesk.RoleAssigneeType | Should -Be 'RoleGroup'
        $helpdesk.DisplayName | Should -BeNullOrEmpty
    }

    It 'F7: an unknown -ScopeType value is rejected' -Tag 'Regression', 'F7' {
        { Get-RBAC4AppEntry -ScopeType 'Groups' } | Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }

    It 'F8: a row from Get-RBAC4AppEntry pipes back into Get-RBAC4AppEntry' -Tag 'Regression', 'F8' {
        $row = Get-RBAC4AppEntry -AppId '11111111-1111-1111-1111-111111111111'

        $err = @()
        $r = @($row | Get-RBAC4AppEntry -ErrorVariable err -ErrorAction SilentlyContinue)

        $err | Should -BeNullOrEmpty
        $r.Name | Should -Be @('AppMailSend-Contoso')
    }

    It 'F8: New-RegisteredApp output pipes into Get-RBAC4AppEntry' -Tag 'Regression', 'F8' {
        $registered = [pscustomobject]@{ DisplayName = 'Contoso'; AppId = '11111111-1111-1111-1111-111111111111'; ServicePrincipalId = '22222222-2222-2222-2222-222222222222' }

        $err = @()
        $r = @($registered | Get-RBAC4AppEntry -ErrorVariable err -ErrorAction SilentlyContinue)

        $err | Should -BeNullOrEmpty
        $r.Name | Should -Be @('AppMailSend-Contoso')
    }

    It 'F10: an unreadable management scope is not looked up as a group' -Tag 'Regression', 'F10' {
        Mock -ModuleName EXORBACforAppManagement Get-ManagementRoleAssignment {
            [pscustomobject]@{
                Name = 'AppMailSend-Contoso'; Role = 'Application Mail.Send'; RoleAssigneeName = '22222222-2222-2222-2222-222222222222'
                RoleAssigneeType = 'ServicePrincipal'; CustomRecipientWriteScope = 'MSRAo1P-Contoso'; CustomResourceScope = $null
                RecipientWriteScope = 'CustomRecipientScope'; Enabled = $true; Guid = [guid]::NewGuid(); Identity = 'AppMailSend-Contoso'
                EffectiveUserName = $null; App = $null
            }
        }
        Mock -ModuleName EXORBACforAppManagement Get-ManagementScope { throw 'The operation could not be performed because object MSRAo1P-Contoso could not be found.' }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }

        $warnings = @()
        $r = Get-RBAC4AppEntry -WarningVariable warnings -WarningAction SilentlyContinue

        $r.ScopeKind | Should -BeNullOrEmpty
        ($warnings -join ';') | Should -Not -Match 'Could not resolve scope group'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-DistributionGroup -Times 0 -ParameterFilter { $Identity -eq 'MSRAo1P-Contoso' }
    }
}
