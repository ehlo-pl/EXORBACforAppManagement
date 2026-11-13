#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force

    # Global stubs so the module scope can resolve them and Pester can mock them on CI.
    function global:Get-DistributionGroup { }
    function global:New-DistributionGroup { param($Name, $DisplayName, $Alias, $Type, [string[]]$ManagedBy, $Members) }
    function global:Set-DistributionGroup { param($Identity, $HiddenFromAddressListsEnabled, $RequireSenderAuthenticationEnabled, $MemberJoinRestriction, $MemberDepartRestriction, [string[]]$AcceptMessagesOnlyFromSendersOrMembers, [switch]$BypassSecurityGroupManagerCheck) }
    function global:Get-Recipient { }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    foreach ($n in 'Get-DistributionGroup','New-DistributionGroup','Set-DistributionGroup','Get-Recipient') {
        Remove-Item "Function:\global:$n" -ErrorAction SilentlyContinue
    }
}

Describe 'New-RBAC4AppDistributionGroup' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Set-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { [pscustomobject]@{ PrimarySmtpAddress = 'owner@contoso.com' } }
        Mock -ModuleName EXORBACforAppManagement Save-RBAC4AppChangeReferenceRecord { Join-Path $TestDrive "$ChangeReference.yaml" }
    }

    It 'creates and configures the list when it does not exist' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { } # not found, then configured lookup
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }

        $res = New-RBAC4AppDistributionGroup -GroupType Distribution -Name 'Um365RAo1-Contoso' -ManagedBy 'owner@contoso.com' -Confirm:$false
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 1
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-DistributionGroup -Times 1
        $res.AlreadyExisted | Should -BeFalse
        $res.OwnerRequested | Should -Be @('owner@contoso.com')
        $res.OwnerAdded     | Should -Be @('owner@contoso.com')
    }

    It 'creates the list with multiple owners, each resolved independently' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient {
            param($Identity)
            [pscustomobject]@{ PrimarySmtpAddress = $Identity }
        }

        $res = New-RBAC4AppDistributionGroup -GroupType Distribution -Name 'Um365RAo1-Contoso' -ManagedBy 'owner1@contoso.com', 'owner2@contoso.com' -Confirm:$false

        $res.OwnerRequested | Should -Be @('owner1@contoso.com', 'owner2@contoso.com')
        $res.OwnerAdded     | Should -Be @('owner1@contoso.com', 'owner2@contoso.com')
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 1 -ParameterFilter {
            (Compare-Object $ManagedBy @('owner1@contoso.com', 'owner2@contoso.com')).Count -eq 0
        }
    }

    It 'warns and does not create when the list already exists' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Identity = 'g'; ManagedBy = @('existing@contoso.com') } }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { }

        $warn = $null
        $res = New-RBAC4AppDistributionGroup -GroupType Distribution -Name 'Um365RAo1-Contoso' -ManagedBy 'owner@contoso.com' -Confirm:$false -WarningVariable warn
        ($warn.Message -join ';') | Should -Match 'already exists'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 0
        $res.AlreadyExisted | Should -BeTrue
        $res.OwnerRequested | Should -Be @('owner@contoso.com')
        $res.OwnerAdded     | Should -Be @('existing@contoso.com')
    }

    It 'stores ChangeReference in a local metadata file when creating the list' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }

        $res = New-RBAC4AppDistributionGroup -GroupType Distribution -Name 'UDLRAo1-Contoso' -ManagedBy 'owner@contoso.com' -ChangeReference 'CHG123456' -Confirm:$false

        $res.ChangeReference | Should -Be 'CHG123456'
        $res.ChangeReferencePath | Should -Be (Join-Path $TestDrive 'CHG123456.yaml')
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Save-RBAC4AppChangeReferenceRecord -Times 1 -ParameterFilter {
            $ChangeReference -eq 'CHG123456' -and $AccessGroupType -eq 'DistributionList' -and $ScopeGroupName -eq 'UDLRAo1-Contoso'
        }
    }

    It 'stores ChangeReference in a local metadata file when the list already exists' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup {
            [pscustomobject]@{
                DisplayName = 'g'
                Identity    = 'g'
                ManagedBy   = @('existing@contoso.com')
            }
        }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { }

        $res = New-RBAC4AppDistributionGroup -GroupType Distribution -Name 'UDLRAo1-Contoso' -ManagedBy 'owner@contoso.com' -ChangeReference 'INC987654' -Confirm:$false

        $res.ChangeReferencePath | Should -Be (Join-Path $TestDrive 'INC987654.yaml')
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 0
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Save-RBAC4AppChangeReferenceRecord -Times 1 -ParameterFilter {
            $ChangeReference -eq 'INC987654' -and $AccessGroupType -eq 'DistributionList' -and $ScopeGroupName -eq 'UDLRAo1-Contoso'
        }
    }

    It 'returns the re-read list and applies the hardening settings after creation' {
        $script:lookups = 0
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup {
            $script:lookups++
            if ($script:lookups -gt 1) { [pscustomobject]@{ DisplayName = 'configured'; Identity = 'g'; HiddenFromAddressListsEnabled = $true } }
        }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'created'; Alias = 'g' } }

        $res = New-RBAC4AppDistributionGroup -GroupType Distribution -Name 'UDLRAo1-Contoso' -ManagedBy 'owner@contoso.com' -Confirm:$false

        $res.AlreadyExisted | Should -BeFalse
        $res.DisplayName | Should -Be 'configured'
        $res.OwnerAdded | Should -Be @('owner@contoso.com')
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-DistributionGroup -Times 1 -ParameterFilter {
            $Identity -eq 'UDLRAo1-Contoso' -and $HiddenFromAddressListsEnabled -eq $true -and
            $RequireSenderAuthenticationEnabled -eq $true -and $MemberJoinRestriction -eq 'Closed' -and $MemberDepartRestriction -eq 'Closed'
        }
    }

    It 'falls back to the created object when the post-create lookup finds nothing' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'created'; Alias = 'g' } }

        $res = New-RBAC4AppDistributionGroup -GroupType Distribution -Name 'UDLRAo1-Contoso' -ManagedBy 'owner@contoso.com' -Confirm:$false

        $res.DisplayName | Should -Be 'created'
        $res.Group.Alias | Should -Be 'g'
        $res.AlreadyExisted | Should -BeFalse
    }

    It 'falls back to the raw value for an owner that cannot be resolved, with a warning' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient {
            param($Identity)
            if ($Identity -eq 'owner1@contoso.com') { [pscustomobject]@{ PrimarySmtpAddress = $Identity } }
        }

        $warn = $null
        $res = New-RBAC4AppDistributionGroup -GroupType Distribution -Name 'UDLRAo1-Contoso' -ManagedBy 'owner1@contoso.com', 'missing@contoso.com' `
            -Confirm:$false -WarningVariable warn -WarningAction SilentlyContinue

        $res.OwnerAdded | Should -Be @('owner1@contoso.com', 'missing@contoso.com')
        ($warn.Message -join ';') | Should -Match "could not be resolved"
    }

    It 'rethrows when New-DistributionGroup fails and does not configure the list' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { throw 'boom from EXO' }

        { New-RBAC4AppDistributionGroup -GroupType Distribution -Name 'UDLRAo1-Contoso' -ManagedBy 'owner@contoso.com' -Confirm:$false } | Should -Throw '*boom from EXO*'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-DistributionGroup -Times 0
    }

    It 'creates with the bootstrap member and the default display name' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }

        $null = New-RBAC4AppDistributionGroup -GroupType Distribution -Name 'UDLRAo1-Contoso' -ManagedBy 'owner@contoso.com' -Confirm:$false

        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 1 -ParameterFilter {
            $Type -eq 'Distribution' -and $Members -contains 'GraphAPI-Dummy'
        }
    }

    It 'does not create under -WhatIf' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { }

        $null = New-RBAC4AppDistributionGroup -GroupType Distribution -Name 'Um365RAo1-Contoso' -WhatIf
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 0
    }

    It 'derives name from -AppName using the module-wide default prefix UDLRAo1P' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }

        $res = New-RBAC4AppDistributionGroup -GroupType Distribution -AppName 'Contoso' -ManagedBy 'owner@contoso.com' -Confirm:$false
        $res.Name | Should -Be 'UDLRAo1P-Contoso'
        $res.AlreadyExisted | Should -BeFalse
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 1
    }

    It 'derives name from -AppName and explicit -Prefix' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }

        $res = New-RBAC4AppDistributionGroup -GroupType Distribution -AppName 'Contoso' -Prefix 'MYORG' -ManagedBy 'owner@contoso.com' -Confirm:$false
        $res.Name | Should -Be 'MYORG-Contoso'
        $res.AlreadyExisted | Should -BeFalse
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 1
    }

    It 'strips spaces and other Alias-unsafe characters from a name derived via -AppName' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }

        $res = New-RBAC4AppDistributionGroup -GroupType Distribution -AppName 'Contoso Mail App 1642232032' -ManagedBy 'owner@contoso.com' -Confirm:$false

        $res.Name | Should -Be 'UDLRAo1P-ContosoMailApp1642232032'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 1 -ParameterFilter {
            $Name -eq 'UDLRAo1P-ContosoMailApp1642232032' -and $Alias -eq 'UDLRAo1P-ContosoMailApp1642232032'
        }
    }

    It 'strips spaces and other Alias-unsafe characters from an explicit -Name too' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }

        $res = New-RBAC4AppDistributionGroup -GroupType Distribution -Name 'UDLRAo1-Contoso, Mail; App' -ManagedBy 'owner@contoso.com' -Confirm:$false

        $res.Name | Should -Be 'UDLRAo1-ContosoMailApp'
    }
}

Describe 'New-RBAC4AppDistributionGroup security group default and send restriction' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Set-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { param($Identity) [pscustomobject]@{ PrimarySmtpAddress = "$Identity@contoso.com" } }
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { }
        Mock -ModuleName EXORBACforAppManagement New-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; Alias = 'g' } }
    }

    It 'creates a mail-enabled security group with the USRACo1P prefix by default' {
        $res = New-RBAC4AppDistributionGroup -AppName 'Contoso' -Confirm:$false

        $res.Name | Should -Be 'USRACo1P-Contoso'
        $res.GroupType | Should -Be 'Security'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName New-DistributionGroup -Times 1 -Exactly -ParameterFilter { $Type -eq 'Security' }
    }

    It 'allows only the resolved owner to send and requires sender authentication' {
        $res = New-RBAC4AppDistributionGroup -Name 'USRACo1P-Contoso' -Confirm:$false

        $res.SendRestricted | Should -BeTrue
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-DistributionGroup -Times 1 -Exactly -ParameterFilter {
            $Identity -eq 'USRACo1P-Contoso' -and $RequireSenderAuthenticationEnabled -eq $true -and
            (@($AcceptMessagesOnlyFromSendersOrMembers) -join ',') -eq 'GraphAPI-Dummy-owner@contoso.com'
        }
    }

    It 'skips the allowed-senders list with a warning when no owner resolves, but still requires sender authentication' {
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { }
        $warn = $null
        $res = New-RBAC4AppDistributionGroup -Name 'USRACo1P-Contoso' -Confirm:$false -WarningVariable warn -WarningAction SilentlyContinue

        $res.SendRestricted | Should -BeFalse
        ($warn.Message -join ';') | Should -Match 'send restriction skipped'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-DistributionGroup -Times 1 -Exactly -ParameterFilter {
            $RequireSenderAuthenticationEnabled -eq $true -and -not $MemberJoinRestriction -and -not $AcceptMessagesOnlyFromSendersOrMembers
        }
    }

    It 'leaves an unresolvable owner out of the allowed senders when another owner resolves' {
        Mock -ModuleName EXORBACforAppManagement Get-Recipient { param($Identity) if ($Identity -eq 'good') { [pscustomobject]@{ PrimarySmtpAddress = 'good@contoso.com' } } }
        $warn = $null
        $res = New-RBAC4AppDistributionGroup -Name 'USRACo1P-Contoso' -ManagedBy 'good', 'gone' -Confirm:$false -WarningVariable warn -WarningAction SilentlyContinue

        $res.SendRestricted | Should -BeTrue
        ($warn.Message -join ';') | Should -Match 'gone could not be resolved'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-DistributionGroup -Times 1 -Exactly -ParameterFilter {
            (@($AcceptMessagesOnlyFromSendersOrMembers) -join ',') -eq 'good@contoso.com'
        }
    }

    It 'makes no Set-DistributionGroup call under -WhatIf' {
        $null = New-RBAC4AppDistributionGroup -Name 'USRACo1P-Contoso' -WhatIf
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-DistributionGroup -Times 0
    }

    It 'refuses an existing distribution list where a security group is expected' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; RecipientTypeDetails = 'MailUniversalDistributionGroup'; ManagedBy = @() } }
        { New-RBAC4AppDistributionGroup -Name 'USRACo1P-Contoso' -Confirm:$false } | Should -Throw "*already exists as 'MailUniversalDistributionGroup'*CloudMailEnabledSecurityGroup*"
    }

    It 'warns about an existing group without a send restriction' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; RecipientTypeDetails = 'MailUniversalSecurityGroup'; ManagedBy = @('o'); AcceptMessagesOnlyFromSendersOrMembers = @() } }
        $warn = $null
        $res = New-RBAC4AppDistributionGroup -Name 'USRACo1P-Contoso' -Confirm:$false -WarningVariable warn -WarningAction SilentlyContinue

        $res.AlreadyExisted | Should -BeTrue
        $res.SendRestricted | Should -BeFalse
        ($warn.Message -join ';') | Should -Match 'has no send restriction'
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Set-DistributionGroup -Times 0
    }

    It 'reports an existing restricted group as send-restricted without a warning' {
        Mock -ModuleName EXORBACforAppManagement Get-DistributionGroup { [pscustomobject]@{ DisplayName = 'g'; RecipientTypeDetails = 'MailUniversalSecurityGroup'; ManagedBy = @('o'); AcceptMessagesOnlyFromSendersOrMembers = @('GraphAPI-Dummy-owner') } }
        $warn = $null
        $res = New-RBAC4AppDistributionGroup -Name 'USRACo1P-Contoso' -Confirm:$false -WarningVariable warn -WarningAction SilentlyContinue

        $res.SendRestricted | Should -BeTrue
        ($warn.Message -join ';') | Should -Not -Match 'send restriction'
    }
}
