#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force
    function global:Get-Recipient { [CmdletBinding()] param([string]$Identity) }
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
    Remove-Item 'Function:\global:Get-Recipient' -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-RBAC4AppRecipientFilter' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Get-Recipient {
            switch ($Identity) {
                'UDLRAo1P-Contoso' { [pscustomobject]@{ DistinguishedName = 'CN=UDLRAo1P-Contoso,OU=contoso,DC=prod' } }
                'alice'            { [pscustomobject]@{ PrimarySmtpAddress = 'alice@contoso.com' } }
                'bob@contoso.com'  { [pscustomobject]@{ PrimarySmtpAddress = 'bob@contoso.com' } }
                "o'brien"          { [pscustomobject]@{ PrimarySmtpAddress = "o'brien@contoso.com" } }
            }
        }
    }

    It 'builds a MemberOfGroup filter from a known distinguished name without a lookup' {
        InModuleScope EXORBACforAppManagement {
            ConvertTo-RBAC4AppRecipientFilter -ScopeKind Group -GroupIdentity 'x' -GroupDistinguishedName 'CN=x,DC=prod' |
                Should -Be "MemberOfGroup -eq 'CN=x,DC=prod'"
        }
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Get-Recipient -Times 0
    }

    It 'resolves the group distinguished name through Get-Recipient' {
        InModuleScope EXORBACforAppManagement {
            ConvertTo-RBAC4AppRecipientFilter -ScopeKind Group -GroupIdentity 'UDLRAo1P-Contoso' |
                Should -Be "MemberOfGroup -eq 'CN=UDLRAo1P-Contoso,OU=contoso,DC=prod'"
        }
    }

    It 'throws for an unresolvable group unless -AllowUnresolved' {
        InModuleScope EXORBACforAppManagement {
            { ConvertTo-RBAC4AppRecipientFilter -ScopeKind Group -GroupIdentity 'missing' } | Should -Throw '*distinguished name*'
            ConvertTo-RBAC4AppRecipientFilter -ScopeKind Group -GroupIdentity 'missing' -AllowUnresolved |
                Should -Be "MemberOfGroup -eq 'missing'"
        }
    }

    It 'resolves recipients to sorted, unique PrimarySmtpAddress clauses and escapes quotes' {
        InModuleScope EXORBACforAppManagement {
            ConvertTo-RBAC4AppRecipientFilter -ScopeKind Recipients -Recipients 'bob@contoso.com', 'alice', "o'brien", 'alice' |
                Should -Be "(PrimarySmtpAddress -eq 'alice@contoso.com') -or (PrimarySmtpAddress -eq 'bob@contoso.com') -or (PrimarySmtpAddress -eq 'o''brien@contoso.com')"
        }
    }

    It 'emits a single clause for a single recipient' {
        InModuleScope EXORBACforAppManagement {
            ConvertTo-RBAC4AppRecipientFilter -ScopeKind Recipients -Recipients 'alice' |
                Should -Be "PrimarySmtpAddress -eq 'alice@contoso.com'"
        }
    }

    It 'warns about and skips unresolvable recipients, and refuses an empty result' {
        InModuleScope EXORBACforAppManagement {
            $f = ConvertTo-RBAC4AppRecipientFilter -ScopeKind Recipients -Recipients 'alice', 'ghost' -WarningVariable w -WarningAction SilentlyContinue
            $f | Should -Be "PrimarySmtpAddress -eq 'alice@contoso.com'"
            ($w -join ';') | Should -Match "ghost"
            { ConvertTo-RBAC4AppRecipientFilter -ScopeKind Recipients -Recipients 'ghost' -WarningAction SilentlyContinue } | Should -Throw '*empty management scope filter*'
        }
    }

    It 'builds a CustomAttribute tag filter and validates the attribute' {
        InModuleScope EXORBACforAppManagement {
            ConvertTo-RBAC4AppRecipientFilter -ScopeKind Tag -TagAttribute CustomAttribute12 -TagValue 'App' |
                Should -Be "CustomAttribute12 -eq 'App'"
            { ConvertTo-RBAC4AppRecipientFilter -ScopeKind Tag -TagAttribute CustomAttribute16 -TagValue 'App' } | Should -Throw
            { ConvertTo-RBAC4AppRecipientFilter -ScopeKind Tag -TagAttribute CustomAttribute1 } | Should -Throw '*tag value*'
        }
    }

    It 'passes a raw filter through trimmed' {
        InModuleScope EXORBACforAppManagement {
            ConvertTo-RBAC4AppRecipientFilter -ScopeKind Filter -Filter "  Department -eq 'Sales'  " | Should -Be "Department -eq 'Sales'"
        }
    }
}

Describe 'ConvertFrom-RBAC4AppRecipientFilter' {
    It 'classifies a Group filter, tolerating EXO-added parentheses' {
        InModuleScope EXORBACforAppManagement {
            $r = ConvertFrom-RBAC4AppRecipientFilter -Filter "((MemberOfGroup -eq 'CN=o''brien,DC=prod'))"
            $r.ScopeKind | Should -Be 'Group'
            $r.GroupDistinguishedName | Should -Be "CN=o'brien,DC=prod"
        }
    }

    It 'classifies a Recipients filter and returns sorted addresses' {
        InModuleScope EXORBACforAppManagement {
            $r = ConvertFrom-RBAC4AppRecipientFilter -Filter "((PrimarySmtpAddress -eq 'bob@contoso.com') -or (PrimarySmtpAddress -eq 'alice@contoso.com'))"
            $r.ScopeKind | Should -Be 'Recipients'
            $r.Recipients | Should -Be @('alice@contoso.com', 'bob@contoso.com')
        }
    }

    It 'classifies a Tag filter' {
        InModuleScope EXORBACforAppManagement {
            $r = ConvertFrom-RBAC4AppRecipientFilter -Filter "(CustomAttribute5 -eq 'TailspinApp')"
            $r.ScopeKind | Should -Be 'Tag'
            $r.TagAttribute | Should -Be 'CustomAttribute5'
            $r.TagValue | Should -Be 'TailspinApp'
        }
    }

    It 'falls back to Filter for anything else, including mixed address filters' {
        InModuleScope EXORBACforAppManagement {
            (ConvertFrom-RBAC4AppRecipientFilter -Filter "Department -eq 'Sales'").ScopeKind | Should -Be 'Filter'
            (ConvertFrom-RBAC4AppRecipientFilter -Filter "(PrimarySmtpAddress -eq 'a@b.c') -and (Department -eq 'Sales')").ScopeKind | Should -Be 'Filter'
            (ConvertFrom-RBAC4AppRecipientFilter -Filter "(MemberOfGroup -eq 'a') -or (MemberOfGroup -eq 'b')").ScopeKind | Should -Be 'Filter'
        }
    }

    It 'returns a null ScopeKind for an empty filter' {
        InModuleScope EXORBACforAppManagement {
            (ConvertFrom-RBAC4AppRecipientFilter -Filter '').ScopeKind | Should -BeNullOrEmpty
        }
    }

    It 'round-trips every kind produced by ConvertTo-RBAC4AppRecipientFilter' {
        InModuleScope EXORBACforAppManagement {
            $g = ConvertFrom-RBAC4AppRecipientFilter -Filter (ConvertTo-RBAC4AppRecipientFilter -ScopeKind Group -GroupDistinguishedName 'CN=g,DC=prod')
            $g.ScopeKind | Should -Be 'Group'
            $g.GroupDistinguishedName | Should -Be 'CN=g,DC=prod'
            $t = ConvertFrom-RBAC4AppRecipientFilter -Filter (ConvertTo-RBAC4AppRecipientFilter -ScopeKind Tag -TagAttribute CustomAttribute3 -TagValue "it's")
            $t.TagValue | Should -Be "it's"
        }
    }
}

Describe 'Get-RBAC4AppManagementScopeName' {
    It 'builds {Prefix}-{DisplayName} sanitized' {
        InModuleScope EXORBACforAppManagement {
            Get-RBAC4AppManagementScopeName -DisplayName 'Contoso Mail App' -Prefix 'MSRAo1P' | Should -Be 'MSRAo1P-ContosoMailApp'
        }
    }

    It 'caps the generated name at 64 characters' {
        InModuleScope EXORBACforAppManagement {
            (Get-RBAC4AppManagementScopeName -DisplayName ('x' * 100)).Length | Should -BeLessOrEqual 64
        }
    }

    It 'returns an explicit -Name as-is' {
        InModuleScope EXORBACforAppManagement {
            Get-RBAC4AppManagementScopeName -DisplayName 'Contoso' -Name 'My Scope' | Should -Be 'My Scope'
        }
    }
}

Describe 'Test-RBAC4AppRecipientFilterEqual' {
    It 'ignores parentheses, whitespace and casing' {
        InModuleScope EXORBACforAppManagement {
            Test-RBAC4AppRecipientFilterEqual -Reference "MemberOfGroup -eq 'CN=g'" -Difference "((memberofgroup -eq 'CN=g'))" | Should -BeTrue
        }
    }

    It 'detects a different filter' {
        InModuleScope EXORBACforAppManagement {
            Test-RBAC4AppRecipientFilterEqual -Reference "CustomAttribute1 -eq 'a'" -Difference "CustomAttribute1 -eq 'b'" | Should -BeFalse
            Test-RBAC4AppRecipientFilterEqual -Reference $null -Difference "CustomAttribute1 -eq 'b'" | Should -BeFalse
        }
    }
}

Describe 'Get-RBAC4AppAssignmentScopeState' {
    It 'reports Target for an assignment bound to the management scope' {
        InModuleScope EXORBACforAppManagement {
            $a = [pscustomobject]@{ RecipientWriteScope = 'CustomRecipientScope'; CustomResourceScope = 'MSRAo1P-Contoso' }
            $s = Get-RBAC4AppAssignmentScopeState -Assignment $a -ManagementScopeName 'MSRAo1P-Contoso' -LegacyGroupName 'UDLRAo1P-Contoso'
            $s.State | Should -Be 'Target'
            $s.CurrentScope | Should -Be 'MSRAo1P-Contoso'
        }
    }

    It 'reports LegacyGroup for a -RecipientGroupScope assignment on the app group' {
        InModuleScope EXORBACforAppManagement {
            $a = [pscustomobject]@{ RecipientWriteScope = 'Group'; CustomResourceScope = 'UDLRAo1P-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f' }
            $s = Get-RBAC4AppAssignmentScopeState -Assignment $a -ManagementScopeName 'MSRAo1P-Contoso' -LegacyGroupName 'UDLRAo1P-Contoso'
            $s.State | Should -Be 'LegacyGroup'
            $s.CurrentScope | Should -Be 'UDLRAo1P-Contoso'
        }
    }

    It 'reports Other for anything else, and never LegacyGroup without a group name' {
        InModuleScope EXORBACforAppManagement {
            $a = [pscustomobject]@{ RecipientWriteScope = 'CustomRecipientScope'; CustomResourceScope = 'SomeOtherScope' }
            (Get-RBAC4AppAssignmentScopeState -Assignment $a -ManagementScopeName 'MSRAo1P-Contoso' -LegacyGroupName 'UDLRAo1P-Contoso').State | Should -Be 'Other'
            $legacy = [pscustomobject]@{ RecipientWriteScope = 'Group'; CustomResourceScope = 'UDLRAo1P-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f' }
            (Get-RBAC4AppAssignmentScopeState -Assignment $legacy -ManagementScopeName 'MSRAo1P-Contoso').State | Should -Be 'Other'
        }
    }
}

Describe 'Get-RBAC4AppScopeKindWarning' {
    It 'warns about group parameters used with a non-Group kind' {
        InModuleScope EXORBACforAppManagement {
            $w = @(Get-RBAC4AppScopeKindWarning -ScopeKind Recipients -BoundParameters @{ Members = 'x'; ScopeRecipients = 'y' })
            $w.Count | Should -Be 1
            $w[0] | Should -Match '-Members only applies to -ScopeKind Group'
        }
    }

    It 'warns about kind-specific parameters for other kinds and stays silent when consistent' {
        InModuleScope EXORBACforAppManagement {
            @(Get-RBAC4AppScopeKindWarning -ScopeKind Group -BoundParameters @{ ScopeFilter = 'x'; ScopeTagValue = 'v' }).Count | Should -Be 2
            @(Get-RBAC4AppScopeKindWarning -ScopeKind Tag -BoundParameters @{ ScopeTagValue = 'v' }).Count | Should -Be 0
        }
    }
}
