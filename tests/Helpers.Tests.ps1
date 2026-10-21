#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
}

Describe 'Get-SafeName' {
    It 'strips characters that are not letters, digits, or dash' {
        InModuleScope EXORBACforAppManagement {
            Get-SafeName -s 'Um365RAo1-Contoso Mail App!@#' | Should -Be 'Um365RAo1-ContosoMailApp'
        }
    }

    It 'caps the result at the requested length with a deterministic hash suffix' {
        InModuleScope EXORBACforAppManagement {
            $input = 'a' * 100
            $out = Get-SafeName -s $input -max 63
            $out.Length | Should -Be 63
            $out | Should -Be (Get-SafeName -s $input -max 63)
            $out | Should -Match '^[a-z0-9-]+-[a-f0-9]{12}$'
        }
    }

    It 'avoids collisions when long names share a truncated prefix' {
        InModuleScope EXORBACforAppManagement {
            $first = Get-SafeName -s (('a' * 100) + 'first') -max 64
            $second = Get-SafeName -s (('a' * 100) + 'second') -max 64
            $first.Length | Should -Be 64
            $second.Length | Should -Be 64
            $first | Should -Not -Be $second
        }
    }

    It 'defaults to the shared 64-character Exchange object name limit' {
        InModuleScope EXORBACforAppManagement {
            (Get-SafeName -s ('b' * 200)).Length | Should -Be 64
        }
    }
}

Describe 'Get-NormalizeRole' {
    It 'maps a known short name to the Application role' {
        InModuleScope EXORBACforAppManagement {
            Get-NormalizeRole 'Mail.Send' | Should -Be 'Application Mail.Send'
        }
    }

    It 'passes through an already-normalized role unchanged' {
        InModuleScope EXORBACforAppManagement {
            Get-NormalizeRole 'Application Calendars.Read' | Should -Be 'Application Calendars.Read'
        }
    }

    It 'passes through an unknown role unchanged' {
        InModuleScope EXORBACforAppManagement {
            Get-NormalizeRole 'Totally.Unknown' | Should -Be 'Totally.Unknown'
        }
    }
}

Describe 'ConvertTo-AppRole' {
    It 'prefixes a short name with Application' {
        InModuleScope EXORBACforAppManagement {
            ConvertTo-AppRole 'Mail.Send' | Should -Be 'Application Mail.Send'
        }
    }

    It 'leaves an already-prefixed role unchanged' {
        InModuleScope EXORBACforAppManagement {
            ConvertTo-AppRole 'Application Mail.Send' | Should -Be 'Application Mail.Send'
        }
    }
}
