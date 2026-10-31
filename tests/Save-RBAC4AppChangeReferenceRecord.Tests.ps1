#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
}

# GetFolderPath('UserProfile') ignores environment overrides on Windows; redirect the directory join instead.
Describe 'Save-RBAC4AppChangeReferenceRecord' {
    BeforeEach {
        Mock -ModuleName EXORBACforAppManagement Join-Path {
            Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath
        }
        Mock -ModuleName EXORBACforAppManagement Join-Path {
            Microsoft.PowerShell.Management\Join-Path -Path $TestDrive -ChildPath '.EXORBACforAppManagement'
        } -ParameterFilter { $ChildPath -eq '.EXORBACforAppManagement' }
    }

    It 'writes a YAML record under the user profile directory and returns its path' {
        $path = InModuleScope EXORBACforAppManagement {
            Save-RBAC4AppChangeReferenceRecord -ChangeReference 'CHG123456' -Source 'New-RBAC4AppUnifiedGroup' `
                -AccessGroupType 'M365Group' -ScopeGroupName 'Um365RAo1-Contoso' -ApplicationName 'Contoso' `
                -AppId '11111111-1111-1111-1111-111111111111' -SpObjectId '22222222-2222-2222-2222-222222222222'
        }

        $path | Should -Be (Join-Path $TestDrive '.EXORBACforAppManagement' 'CHG123456.yaml')
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Join-Path -Times 1 -Exactly -ParameterFilter {
            $Path -eq [Environment]::GetFolderPath('UserProfile') -and $ChildPath -eq '.EXORBACforAppManagement'
        }
        Should -Invoke -ModuleName EXORBACforAppManagement -CommandName Join-Path -Times 1 -Exactly -ParameterFilter {
            $Path -eq (Microsoft.PowerShell.Management\Join-Path -Path $TestDrive -ChildPath '.EXORBACforAppManagement') -and
            $ChildPath -eq 'CHG123456.yaml'
        }
        Test-Path -LiteralPath $path | Should -BeTrue
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match '(?m)^---'
        $text | Should -Match '(?m)^ChangeReference: "CHG123456"'
        $text | Should -Match '(?m)^Source: "New-RBAC4AppUnifiedGroup"'
        $text | Should -Match '(?m)^  DisplayName: "Contoso"'
        $text | Should -Match '(?m)^  AppId: "11111111-1111-1111-1111-111111111111"'
        $text | Should -Match '(?m)^  SpObjectId: "22222222-2222-2222-2222-222222222222"'
        $text | Should -Match '(?m)^  AccessGroupType: "M365Group"'
        $text | Should -Match '(?m)^  GroupName: "Um365RAo1-Contoso"'
        $text | Should -Match '(?m)^RecordedAt: "\d{4}-\d{2}-\d{2}T'
    }

    It 'writes empty quoted scalars for omitted optional values' {
        $path = InModuleScope EXORBACforAppManagement { Save-RBAC4AppChangeReferenceRecord -ChangeReference 'CHG1' }

        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match '(?m)^Source: ""'
        $text | Should -Match '(?m)^  GroupName: ""'
    }

    It 'replaces characters that are invalid in file names with a dash' {
        $path = InModuleScope EXORBACforAppManagement { Save-RBAC4AppChangeReferenceRecord -ChangeReference 'CHG/12:3*?' }

        Split-Path $path -Leaf | Should -Be 'CHG-12-3--.yaml'
    }

    It 'falls back to a default file name when the reference sanitizes to blank' {
        $path = InModuleScope EXORBACforAppManagement { Save-RBAC4AppChangeReferenceRecord -ChangeReference '   ' }

        Split-Path $path -Leaf | Should -Be 'ChangeReference.yaml'
    }

    It 'escapes backslashes and quotes in scalar values' {
        $path = InModuleScope EXORBACforAppManagement {
            Save-RBAC4AppChangeReferenceRecord -ChangeReference 'CHG2' -ApplicationName 'My "App" \ Test'
        }

        (Get-Content -LiteralPath $path -Raw) | Should -Match ([regex]::Escape('DisplayName: "My \"App\" \\ Test"'))
    }

    It 'appends to an existing record instead of overwriting it' {
        $path = InModuleScope EXORBACforAppManagement {
            $null = Save-RBAC4AppChangeReferenceRecord -ChangeReference 'CHG3' -ScopeGroupName 'First'
            Save-RBAC4AppChangeReferenceRecord -ChangeReference 'CHG3' -ScopeGroupName 'Second'
        }

        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match 'GroupName: "First"'
        $text | Should -Match 'GroupName: "Second"'
    }

    It 'rejects a ChangeReference containing CR or LF' {
        InModuleScope EXORBACforAppManagement {
            { Save-RBAC4AppChangeReferenceRecord -ChangeReference "CHG`nINJECT" } | Should -Throw '*CR or LF*'
        }
    }

    It 'rejects metadata values containing CR or LF' {
        InModuleScope EXORBACforAppManagement {
            { Save-RBAC4AppChangeReferenceRecord -ChangeReference 'CHG4' -ApplicationName "App`r`nEvil: x" } | Should -Throw '*CR or LF*'
        }
    }
}
