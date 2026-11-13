#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'EXORBACforAppManagement' 'EXORBACforAppManagement.psd1') -Force
}

AfterAll {
    Remove-Module EXORBACforAppManagement -Force -ErrorAction SilentlyContinue
}

Describe 'Format-RBAC4AppSafeName' {
    It 'strips characters that are not letters, digits, or dash' {
        InModuleScope EXORBACforAppManagement {
            Format-RBAC4AppSafeName -Value 'Um365RAo1-Contoso Mail App!@#' | Should -Be 'Um365RAo1-ContosoMailApp'
        }
    }

    It 'caps the result at the requested length' {
        InModuleScope EXORBACforAppManagement {
            (Format-RBAC4AppSafeName -Value ('a' * 100) -MaxLength 63).Length | Should -Be 63
        }
    }

    It 'defaults the cap to 63' {
        InModuleScope EXORBACforAppManagement {
            (Format-RBAC4AppSafeName -Value ('b' * 200)).Length | Should -Be 63
        }
    }
}

Describe 'ConvertTo-RBAC4AppRoleName' {
    It 'maps a known short name to the Application role' {
        InModuleScope EXORBACforAppManagement {
            ConvertTo-RBAC4AppRoleName -Role 'Mail.Send' | Should -Be 'Application Mail.Send'
        }
    }

    It 'passes through an already-normalized role unchanged' {
        InModuleScope EXORBACforAppManagement {
            ConvertTo-RBAC4AppRoleName -Role 'Application Calendars.Read' | Should -Be 'Application Calendars.Read'
        }
    }

    It 'passes through an unknown role unchanged' {
        InModuleScope EXORBACforAppManagement {
            ConvertTo-RBAC4AppRoleName -Role 'Totally.Unknown' | Should -Be 'Totally.Unknown'
        }
    }
}

Describe 'Get-RBAC4AppDefaultGroupPrefix' {
    It 'returns the type-specific default prefix' {
        InModuleScope EXORBACforAppManagement {
            Get-RBAC4AppDefaultGroupPrefix -AccessGroupType CloudMailEnabledSecurityGroup | Should -Be 'USRACo1P'
            Get-RBAC4AppDefaultGroupPrefix -AccessGroupType DistributionList | Should -Be 'UDLRAo1P'
            Get-RBAC4AppDefaultGroupPrefix -AccessGroupType HybridMailEnabledSecurityGroup | Should -Be 'USRAHo1P'
            Get-RBAC4AppDefaultGroupPrefix -AccessGroupType MailEnabledSecurityGroup | Should -Be 'USRAHo1P'
            Get-RBAC4AppDefaultGroupPrefix -AccessGroupType M365Group | Should -Be 'Um365RAo1P'
        }
    }
}

Describe 'ConvertTo-RBAC4AppAccessGroupType' {
    It 'maps the legacy MailEnabledSecurityGroup name to HybridMailEnabledSecurityGroup and keeps the rest' {
        InModuleScope EXORBACforAppManagement {
            ConvertTo-RBAC4AppAccessGroupType -AccessGroupType 'MailEnabledSecurityGroup' | Should -Be 'HybridMailEnabledSecurityGroup'
            ConvertTo-RBAC4AppAccessGroupType -AccessGroupType 'cloudmailenabledsecuritygroup' | Should -BeExactly 'CloudMailEnabledSecurityGroup'
            ConvertTo-RBAC4AppAccessGroupType -AccessGroupType 'DistributionList' | Should -Be 'DistributionList'
            ConvertTo-RBAC4AppAccessGroupType -AccessGroupType 'Bogus' | Should -Be 'Bogus'
            ConvertTo-RBAC4AppAccessGroupType -AccessGroupType '' | Should -Be ''
        }
    }
}

Describe 'Generated-name helpers' {
    It 'builds the scope group name with the Group limit, keeping the role suffix' {
        InModuleScope EXORBACforAppManagement {
            Get-RBAC4AppScopeGroupName -Prefix 'UDLRAo1P' -DisplayName 'Contoso Mail App' | Should -Be 'UDLRAo1P-ContosoMailApp'
            $n = Get-RBAC4AppScopeGroupName -Prefix 'P' -DisplayName ('x' * 100) -Suffix '-MailSend'
            $n.Length | Should -Be 63
            $n | Should -BeLike '*-MailSend'
        }
    }

    It 'builds the role assignment name capped at the RoleAssignment limit' {
        InModuleScope EXORBACforAppManagement {
            Get-RBAC4AppRoleAssignmentName -ShortRoleName 'AppMailSend' -DisplayName 'Contoso App' | Should -Be 'AppMailSend-ContosoApp'
            (Get-RBAC4AppRoleAssignmentName -ShortRoleName 'AppMailSend' -DisplayName ('y' * 100)).Length | Should -Be 63
        }
    }

    It 'builds the management scope name with the 64-char limit and keeps the suffix' {
        InModuleScope EXORBACforAppManagement {
            (Get-RBAC4AppManagementScopeName -DisplayName ('z' * 100) -Suffix '-MailSend').Length | Should -Be 64
            Get-RBAC4AppManagementScopeName -DisplayName 'Contoso' -Name 'Explicit_Scope' | Should -Be 'Explicit_Scope'
        }
    }

    It 'keeps mixed ASCII/non-ASCII names unchanged (no transliteration)' {
        InModuleScope EXORBACforAppManagement {
            $appId = '11111111-2222-3333-4444-555555555555'
            Get-RBAC4AppScopeGroupName -Prefix 'UDLRAo1P' -DisplayName "Z$([char]0x0105)b App" -AppId $appId | Should -Be 'UDLRAo1P-ZbApp'
            Get-RBAC4AppRoleAssignmentName -ShortRoleName 'AppMailSend' -DisplayName "Z$([char]0x0105)b App" -AppId $appId | Should -Be 'AppMailSend-ZbApp'
        }
    }

    It 'falls back to the dash-less AppId when the display name has no Exchange-safe characters' {
        InModuleScope EXORBACforAppManagement {
            $appId = '11111111-2222-3333-4444-555555555555'
            $nonAscii = -join ([char[]](0x0105, 0x0119, 0x0142, 0x65E5, 0x672C))   # Polish diacritics + Kanji
            Get-RBAC4AppScopeGroupName -Prefix 'UDLRAo1P' -DisplayName $nonAscii -AppId $appId |
                Should -Be 'UDLRAo1P-11111111222233334444555555555555'
            Get-RBAC4AppManagementScopeName -DisplayName $nonAscii -AppId $appId |
                Should -Be 'MSRAo1P-11111111222233334444555555555555'
            Get-RBAC4AppRoleAssignmentName -ShortRoleName 'AppMailSend' -DisplayName $nonAscii -AppId $appId |
                Should -Be 'AppMailSend-11111111222233334444555555555555'
            # An explicit management scope name is still honoured.
            Get-RBAC4AppManagementScopeName -DisplayName $nonAscii -Name 'Explicit' | Should -Be 'Explicit'
        }
    }

    It 'throws a descriptive error when the display name has no Exchange-safe characters and no AppId is given' {
        InModuleScope EXORBACforAppManagement {
            $nonAscii = -join ([char[]](0x65E5, 0x672C))
            { Get-RBAC4AppScopeGroupName -Prefix 'UDLRAo1P' -DisplayName $nonAscii } | Should -Throw '*no characters usable*-AccessGroupName*'
            { Get-RBAC4AppManagementScopeName -DisplayName $nonAscii } | Should -Throw '*no characters usable*-ManagementScopeName*'
            { Get-RBAC4AppRoleAssignmentName -ShortRoleName 'AppMailSend' -DisplayName $nonAscii } | Should -Throw '*no characters usable*'
        }
    }
}

Describe 'ConvertTo-RBAC4AppConfig' {
    It 'stamps the module schema version, which Invoke-RBAC4AppConfig accepts' {
        InModuleScope EXORBACforAppManagement {
            $cfg = ConvertTo-RBAC4AppConfig -AppId 'a' -SpObjectId 's' -DisplayName 'Contoso' -Roles 'Application Mail.Send' `
                -AccessGroupType DistributionList -GroupPrefix 'UDLRAo1P'

            $cfg.SchemaVersion | Should -Be $script:RBAC4AppConfigSchemaVersion
        }
    }

    It 'writes TenantId inside Application, and only when supplied' {
        InModuleScope EXORBACforAppManagement {
            $with = ConvertTo-RBAC4AppConfig -TenantId 't-1' -AppId 'a' -SpObjectId 's' -DisplayName 'Contoso' `
                -Roles 'Application Mail.Send' -AccessGroupType DistributionList -GroupPrefix 'UDLRAo1P'
            $with.Application.TenantId | Should -Be 't-1'
            $with.PSObject.Properties.Name | Should -Not -Contain 'TenantId'
            @($with.Application.PSObject.Properties.Name) | Should -Be @('AppId', 'SpObjectId', 'DisplayName', 'TenantId')

            $yaml = ConvertTo-RBAC4AppYaml -Config $with
            $yaml | Should -Match '(?m)^  TenantId: "t-1"'
            $yaml | Should -Not -Match '(?m)^TenantId:'

            $without = ConvertTo-RBAC4AppConfig -AppId 'a' -SpObjectId 's' -DisplayName 'Contoso' `
                -Roles 'Application Mail.Send' -AccessGroupType DistributionList -GroupPrefix 'UDLRAo1P'
            $without.Application.PSObject.Properties.Name | Should -Not -Contain 'TenantId'
        }
    }

    It 'produces a config that survives a YAML round trip through the reader' {
        InModuleScope EXORBACforAppManagement {
            $cfg = ConvertTo-RBAC4AppConfig -TenantId 't' -AppId 'a' -SpObjectId 's' -DisplayName 'Contoso' `
                -Roles 'Application Mail.Send', 'Application Calendars.Read' -AccessGroupType M365Group -GroupPrefix 'Um365RAo1P' `
                -Members 'm@contoso.com' -ManagedBy 'o@contoso.com' -SeparateScopePerRole $true

            $parsed = ConvertFrom-RBAC4AppYaml -Content (ConvertTo-RBAC4AppYaml -Config $cfg)

            $parsed.SchemaVersion | Should -Be $script:RBAC4AppConfigSchemaVersion
            @($parsed.Rbac.Roles) | Should -Be @('Application Mail.Send', 'Application Calendars.Read')
            $parsed.RbacScope.AccessGroupType | Should -Be 'M365Group'
            $parsed.RbacScope.ScopeKind | Should -Be 'Group'
            @($parsed.RbacScope.Members) | Should -Be @('m@contoso.com')
            $parsed.RbacScope.SeparateScopePerRole | Should -BeTrue
        }
    }

    It 'serializes single-item schema lists as YAML sequences' {
        InModuleScope EXORBACforAppManagement {
            $config = [pscustomobject]@{
                SchemaVersion = '4.4'
                Application   = [pscustomobject]@{ AppId = 'a'; SpObjectId = 's'; DisplayName = 'Contoso' }
                Rbac          = [pscustomobject]@{ Roles = @('Application Mail.Send'); ChangeReference = '' }
                RbacScope     = [pscustomobject]@{
                    Members         = @('member@contoso.com')
                    ManagedBy       = @('owner@contoso.com')
                    ScopeRecipients = @('recipient@contoso.com')
                }
            }
            $config = Complete-RBAC4AppConfig -Config $config
            $yaml = ConvertTo-RBAC4AppYaml -Config $config
            $parsed = ConvertFrom-RBAC4AppYaml -Content $yaml

            $yaml | Should -Match 'Roles:\r?\n\s+- "Application Mail\.Send"'
            $yaml | Should -Match 'Members:\r?\n\s+- "member@contoso\.com"'
            $yaml | Should -Match 'ManagedBy:\r?\n\s+- "owner@contoso\.com"'
            $yaml | Should -Match 'ScopeRecipients:\r?\n\s+- "recipient@contoso\.com"'
            @($parsed.Rbac.Roles) | Should -Be @('Application Mail.Send')
            @($parsed.RbacScope.Members) | Should -Be @('member@contoso.com')
            @($parsed.RbacScope.ManagedBy) | Should -Be @('owner@contoso.com')
            @($parsed.RbacScope.ScopeRecipients) | Should -Be @('recipient@contoso.com')
        }
    }

    Context 'Runtime section' {
        It 'is always written, with empty lists, when nothing was collected' {
            InModuleScope EXORBACforAppManagement {
                $cfg = ConvertTo-RBAC4AppConfig -AppId 'a' -SpObjectId 's' -DisplayName 'C' -Roles 'Application Mail.Send' `
                    -AccessGroupType DistributionList -GroupPrefix 'UDLRAo1P' -CollectedWarnings @('', $null)

                @($cfg.Runtime.PSObject.Properties.Name) | Should -Be @('GeneratedAt', 'OperatorUsername', 'OperatorMachineName', 'CollectedErrors', 'CollectedWarnings')
                $cfg.Runtime.OperatorUsername | Should -Match ([regex]::Escape([System.Environment]::UserName) + '$')
                $cfg.Runtime.OperatorMachineName | Should -Be ([System.Environment]::MachineName)
                @($cfg.Runtime.CollectedErrors).Count | Should -Be 0
                @($cfg.Runtime.CollectedWarnings).Count | Should -Be 0

                $yaml = ConvertTo-RBAC4AppYaml -Config $cfg
                $yaml | Should -Match '(?m)^Runtime:\s*$'
                $yaml | Should -Match '(?m)^  CollectedErrors: \[\]\s*$'
                $yaml | Should -Match '(?m)^  CollectedWarnings: \[\]\s*$'

                $yaml | Should -Match '(?m)^  OperatorUsername: ".+"\s*$'
                $yaml | Should -Match '(?m)^  OperatorMachineName: ".+"\s*$'

                $json = $cfg | ConvertTo-Json -Depth 6 | ConvertFrom-Json
                $json.Runtime.PSObject.Properties.Name | Should -Be @('GeneratedAt', 'OperatorUsername', 'OperatorMachineName', 'CollectedErrors', 'CollectedWarnings')

                $parsed = ConvertFrom-RBAC4AppYaml -Content $yaml
                $parsed.Runtime.OperatorUsername | Should -Be $cfg.Runtime.OperatorUsername
                $parsed.Runtime.OperatorMachineName | Should -Be $cfg.Runtime.OperatorMachineName
                @($parsed.Runtime.CollectedErrors).Count | Should -Be 0
                @($parsed.Runtime.CollectedWarnings).Count | Should -Be 0
            }
        }

        It 'writes both lists when only one has entries' {
            InModuleScope EXORBACforAppManagement {
                $cfg = ConvertTo-RBAC4AppConfig -AppId 'a' -SpObjectId 's' -DisplayName 'C' -Roles 'Application Mail.Send' `
                    -AccessGroupType DistributionList -GroupPrefix 'UDLRAo1P' -CollectedWarnings 'w1'

                $yaml = ConvertTo-RBAC4AppYaml -Config $cfg
                $yaml | Should -Match '(?m)^  CollectedErrors: \[\]\s*$'
                $yaml | Should -Match 'CollectedWarnings:\r?\n\s+- "w1"'
            }
        }

        It 'restores empty lists for a config without the section' {
            InModuleScope EXORBACforAppManagement {
                $completed = Complete-RBAC4AppConfig -Config ([pscustomobject]@{
                        SchemaVersion = '4.4'
                        Application   = [pscustomobject]@{ AppId = 'a'; SpObjectId = 's'; DisplayName = 'C' }
                        Rbac          = [pscustomobject]@{ Roles = @('Application Mail.Send') }
                    })
                @($completed.Runtime.CollectedErrors).Count | Should -Be 0
                @($completed.Runtime.CollectedWarnings).Count | Should -Be 0
                $completed.Runtime.OperatorUsername | Should -BeExactly ''
                $completed.Runtime.OperatorMachineName | Should -BeExactly ''
            }
        }

        It 'round-trips a domain-qualified operator username through YAML' {
            InModuleScope EXORBACforAppManagement {
                $yaml = "SchemaVersion: `"4.4`"`nApplication:`n  AppId: `"a`"`nRuntime:`n  OperatorUsername: `"CONTOSO\\jdoe`"`n  OperatorMachineName: `"WS01`"`n  CollectedErrors: []`n  CollectedWarnings:`n    - `"w1`""
                $parsed = ConvertFrom-RBAC4AppYaml -Content $yaml
                $parsed.Runtime.OperatorUsername | Should -Be 'CONTOSO\jdoe'
                $parsed.Runtime.OperatorMachineName | Should -Be 'WS01'
                @($parsed.Runtime.CollectedWarnings) | Should -Be @('w1')
            }
        }

        It 'survives a <Format> round trip' -TestCases @(@{ Format = 'YAML' }, @{ Format = 'JSON' }) {
            param($Format)
            InModuleScope EXORBACforAppManagement -Parameters @{ Format = $Format } {
                param($Format)
                $cfg = ConvertTo-RBAC4AppConfig -AppId 'a' -SpObjectId 's' -DisplayName 'C' -Roles 'Application Mail.Send' `
                    -AccessGroupType DistributionList -GroupPrefix 'UDLRAo1P' `
                    -CollectedErrors @('Failed: "x"') -CollectedWarnings @('w1', 'w2 C:\path')

                $parsed = if ($Format -eq 'YAML') {
                    $yaml = ConvertTo-RBAC4AppYaml -Config $cfg
                    $yaml | Should -Match '(?m)^Runtime:\s*$'
                    ConvertFrom-RBAC4AppYaml -Content $yaml
                }
                else {
                    Complete-RBAC4AppConfig -Config ($cfg | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
                }

                @($parsed.Runtime.CollectedErrors) | Should -Be @('Failed: "x"')
                @($parsed.Runtime.CollectedWarnings) | Should -Be @('w1', 'w2 C:\path')
                # Runtime does not leak into the Metadata section.
                $parsed.Metadata.Description | Should -BeExactly ''
            }
        }

        It 'carries GeneratedAt in Runtime, not at the top level' {
            InModuleScope EXORBACforAppManagement {
                $cfg = ConvertTo-RBAC4AppConfig -AppId 'a' -SpObjectId 's' -DisplayName 'C' -Roles 'Application Mail.Send' `
                    -AccessGroupType DistributionList -GroupPrefix 'UDLRAo1P'

                $cfg.SchemaVersion | Should -Be '4.4'
                $cfg.PSObject.Properties.Name | Should -Not -Contain 'GeneratedAt'
                [datetime]::Parse($cfg.Runtime.GeneratedAt) | Should -BeOfType [datetime]
                $yaml = ConvertTo-RBAC4AppYaml -Config $cfg
                $yaml | Should -Not -Match '(?m)^GeneratedAt:'
                $yaml | Should -Match '(?m)^  GeneratedAt: ".+"\s*$'
                (ConvertFrom-RBAC4AppYaml -Content $yaml).Runtime.GeneratedAt | Should -Be $cfg.Runtime.GeneratedAt
            }
        }

        It 'reads only the current layout: no legacy keys and no version-dependent defaults' {
            InModuleScope EXORBACforAppManagement {
                # Keys older schemas used (top-level GeneratedAt/TenantId, Metadata.NetworkAccessIPRange) are ignored.
                $yaml = "SchemaVersion: `"4.4`"`nGeneratedAt: `"2026-01-01T00:00:00Z`"`nTenantId: `"legacy-t`"`nApplication:`n  AppId: `"a`"`nMetadata:`n  NetworkAccessIPRange: `"10.0.0.0/24`"`n"
                $parsed = ConvertFrom-RBAC4AppYaml -Content $yaml
                $parsed.Runtime.GeneratedAt | Should -BeExactly ''
                $parsed.Application.TenantId | Should -BeExactly ''
                $parsed.Metadata.NetworkAccessIP4Range | Should -BeExactly ''

                $json = Complete-RBAC4AppConfig -Config ([pscustomobject]@{ SchemaVersion = '4.4'; GeneratedAt = 'x'; TenantId = 'legacy-t'; Metadata = [pscustomobject]@{ NetworkAccessIPRange = '10.0.0.0/24' } })
                $json.Runtime.GeneratedAt | Should -BeExactly ''
                $json.Application.TenantId | Should -BeExactly ''
                $json.Metadata.NetworkAccessIP4Range | Should -BeExactly ''

                # Defaults no longer depend on the version a file names.
                foreach ($v in @('3.0', '4.0', '4.3', '4.4', '')) {
                    $full = Complete-RBAC4AppConfig -Config ([pscustomobject]@{ SchemaVersion = $v })
                    $full.RbacScope.AccessGroupType | Should -Be 'CloudMailEnabledSecurityGroup'
                    $full.RbacScope.AssignmentScope | Should -Be 'RecipientGroupScope'
                }
            }
        }
    }

    Context 'ConversionResult section' {
        It 'is omitted unless supplied' {
            InModuleScope EXORBACforAppManagement {
                $cfg = ConvertTo-RBAC4AppConfig -AppId 'a' -SpObjectId 's' -DisplayName 'C' -Roles 'Application Mail.Send' `
                    -AccessGroupType DistributionList -GroupPrefix 'UDLRAo1P'
                $cfg.PSObject.Properties.Name | Should -Not -Contain 'ConversionResult'
                (ConvertTo-RBAC4AppYaml -Config $cfg) | Should -Not -Match '(?m)^ConversionResult:'
            }
        }

        It 'is written in full and survives a <Format> round trip' -TestCases @(@{ Format = 'YAML' }, @{ Format = 'JSON' }) {
            param($Format)
            InModuleScope EXORBACforAppManagement -Parameters @{ Format = $Format } {
                param($Format)
                $result = [pscustomobject]@{
                    AppId = 'app'; ResolvedDisplay = ''; AccessRight = 'RestrictAccess'; ScopeGroup = 'EvenUsers'
                    DerivedRoles = @('Application Mail.Read'); SkippedPermissions = @(); ConfigPath = 'C:\out\x.yml'
                    Warnings = @('ignored here'); Errors = @()
                }
                $cfg = ConvertTo-RBAC4AppConfig -AppId 'a' -SpObjectId 's' -DisplayName 'C' -Roles 'Application Mail.Read' `
                    -AccessGroupType DistributionList -GroupPrefix 'UDLRAo1P' -ConversionResult $result

                @($cfg.ConversionResult.PSObject.Properties.Name) |
                    Should -Be @('AppId', 'ResolvedDisplay', 'AccessRight', 'ScopeGroup', 'DerivedRoles', 'SkippedPermissions', 'ConfigPath')

                $parsed = if ($Format -eq 'YAML') {
                    $yaml = ConvertTo-RBAC4AppYaml -Config $cfg
                    $yaml | Should -Match '(?m)^  ResolvedDisplay: ""\s*$'
                    $yaml | Should -Match '(?m)^  SkippedPermissions: \[\]\s*$'
                    ConvertFrom-RBAC4AppYaml -Content $yaml
                }
                else {
                    Complete-RBAC4AppConfig -Config ($cfg | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
                }

                $parsed.ConversionResult.AppId | Should -Be 'app'
                $parsed.ConversionResult.AccessRight | Should -Be 'RestrictAccess'
                $parsed.ConversionResult.ScopeGroup | Should -Be 'EvenUsers'
                @($parsed.ConversionResult.DerivedRoles) | Should -Be @('Application Mail.Read')
                @($parsed.ConversionResult.SkippedPermissions).Count | Should -Be 0
                $parsed.ConversionResult.ConfigPath | Should -Be 'C:\out\x.yml'
            }
        }
    }

    Context 'Get-RBAC4AppEffectiveUserObjectId' {
        It 'returns the first GUID found, ignoring values without one' {
            InModuleScope EXORBACforAppManagement {
                Get-RBAC4AppEffectiveUserObjectId -EffectiveUserName @($null, 'NT AUTHORITY\SYSTEM (C_SP)', 'x (abcdef01-2345-6789-abcd-ef0123456789)') |
                    Should -Be 'abcdef01-2345-6789-abcd-ef0123456789'
                Get-RBAC4AppEffectiveUserObjectId -EffectiveUserName @('NT AUTHORITY\SYSTEM (C_SP)') | Should -BeNullOrEmpty
                Get-RBAC4AppEffectiveUserObjectId -EffectiveUserName @() | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Metadata section' {
        BeforeAll {
            $script:metadataFields = @{
                OwnerUsername               = 'jdoe'
                OwnerDisplayName            = 'Jan "JD" Doe'
                TechnicalContactUsername    = 'asmith'
                TechnicalContactDisplayName = 'Anna Smith'
                PCode                       = 'P12345'
                CmdbId                      = '11111111-2222-3333-4444-555555555555'
                Description                 = 'Runbook: https://wiki.contoso.com/app#ops, see C:\docs'
                NetworkAccessIP4Range       = '10.0.0.0/24'
                NetworkAccessIP6Range       = '2001:db8::/32'
                NetworkAccessLocation       = 'HeadOffice'
            }
        }

        It 'always writes the full section, with empty values, when no metadata is supplied' {
            InModuleScope EXORBACforAppManagement {
                $cfg = ConvertTo-RBAC4AppConfig -AppId 'a' -SpObjectId 's' -DisplayName 'C' -Roles 'Application Mail.Send' `
                    -AccessGroupType DistributionList -GroupPrefix 'UDLRAo1P'

                $expected = @('ChangeReference', 'OwnerUsername', 'OwnerDisplayName', 'TechnicalContactUsername',
                    'TechnicalContactDisplayName', 'PCode', 'CmdbId', 'Description', 'NetworkAccessIP4Range', 'NetworkAccessIP6Range', 'NetworkAccessLocation')
                @($cfg.Metadata.PSObject.Properties.Name) | Should -Be $expected
                foreach ($property in $cfg.Metadata.PSObject.Properties) { $property.Value | Should -BeExactly '' }

                $yaml = ConvertTo-RBAC4AppYaml -Config $cfg
                $yaml | Should -Match '(?m)^Metadata:\s*$'
                foreach ($name in $expected) { $yaml | Should -Match "(?m)^  $($name): `"`"\s*$" }
                ($cfg | ConvertTo-Json -Depth 6 | ConvertFrom-Json).Metadata.PSObject.Properties.Name | Should -Be $expected

                $roundTrip = ConvertFrom-RBAC4AppYaml -Content $yaml
                foreach ($property in $roundTrip.Metadata.PSObject.Properties) { $property.Value | Should -BeExactly '' }
            }
        }

        It 'writes the supplied fields and leaves the others empty' {
            InModuleScope EXORBACforAppManagement {
                $cfg = ConvertTo-RBAC4AppConfig -AppId 'a' -SpObjectId 's' -DisplayName 'C' -Roles 'Application Mail.Send' `
                    -AccessGroupType DistributionList -GroupPrefix 'UDLRAo1P' -PCode 'P12345'

                @($cfg.Metadata.PSObject.Properties).Count | Should -Be 11
                $cfg.Metadata.PCode | Should -Be 'P12345'
                @($cfg.Metadata.PSObject.Properties | Where-Object { $_.Value -ne '' }).Name | Should -Be @('PCode')
            }
        }

        It 'survives a <Format> round trip' -TestCases @(@{ Format = 'YAML' }, @{ Format = 'JSON' }) {
            param($Format)
            InModuleScope EXORBACforAppManagement -Parameters @{ Format = $Format; Fields = $script:metadataFields } {
                param($Format, $Fields)
                $cfg = ConvertTo-RBAC4AppConfig -AppId 'a' -SpObjectId 's' -DisplayName 'C' -Roles 'Application Mail.Send' `
                    -AccessGroupType DistributionList -GroupPrefix 'UDLRAo1P' @Fields

                $parsed = if ($Format -eq 'YAML') {
                    ConvertFrom-RBAC4AppYaml -Content (ConvertTo-RBAC4AppYaml -Config $cfg)
                }
                else {
                    Complete-RBAC4AppConfig -Config ($cfg | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
                }

                foreach ($name in $Fields.Keys) {
                    $parsed.Metadata.$name | Should -Be $Fields[$name]
                }
            }
        }

        It 'restores every field as empty for a config without the section' {
            InModuleScope EXORBACforAppManagement {
                $completed = Complete-RBAC4AppConfig -Config ([pscustomobject]@{
                        SchemaVersion = '4.4'
                        Application   = [pscustomobject]@{ AppId = 'a'; SpObjectId = 's'; DisplayName = 'C' }
                        Rbac          = [pscustomobject]@{ Roles = @('Application Mail.Send') }
                    })

                @($completed.Metadata.PSObject.Properties).Count | Should -Be 11
                foreach ($property in $completed.Metadata.PSObject.Properties) {
                    $property.Value | Should -BeExactly ''
                }
            }
        }

    }

    Context 'Test-RBAC4AppIPRange' {
        It 'returns <Expected> for <Family> value ''<Value>''' -TestCases @(
            @{ Family = 'IPv4'; Value = '10.0.0.1';          Expected = $true }
            @{ Family = 'IPv4'; Value = '10.0.0.0/24';       Expected = $true }
            @{ Family = 'IPv4'; Value = '0.0.0.0/0';         Expected = $true }
            @{ Family = 'IPv4'; Value = '256.0.0.1';         Expected = $false }
            @{ Family = 'IPv4'; Value = '10.0.0.0/33';       Expected = $false }
            @{ Family = 'IPv4'; Value = '2001:db8::1';       Expected = $false }
            @{ Family = 'IPv4'; Value = '';                  Expected = $false }
            @{ Family = 'IPv6'; Value = '2001:db8::1';       Expected = $true }
            @{ Family = 'IPv6'; Value = '2001:db8::/32';     Expected = $true }
            @{ Family = 'IPv6'; Value = '::/0';              Expected = $true }
            @{ Family = 'IPv6'; Value = '::ffff:10.0.0.1';   Expected = $true }
            @{ Family = 'IPv6'; Value = 'fd00::/128';        Expected = $true }
            @{ Family = 'IPv6'; Value = 'fd00::/129';        Expected = $false }
            @{ Family = 'IPv6'; Value = 'fd00::/x';          Expected = $false }
            @{ Family = 'IPv6'; Value = 'fd00::/8/8';        Expected = $false }
            @{ Family = 'IPv6'; Value = 'fe80::1%eth0';      Expected = $false }
            @{ Family = 'IPv6'; Value = '10.0.0.1';          Expected = $false }
            @{ Family = 'IPv6'; Value = '2001:db8::zz';      Expected = $false }
            @{ Family = 'IPv6'; Value = '2001:db8:: /32';    Expected = $false }
            @{ Family = 'IPv6'; Value = $null;               Expected = $false }
        ) {
            param($Family, $Value, $Expected)
            InModuleScope EXORBACforAppManagement -Parameters @{ Family = $Family; Value = $Value; Expected = $Expected } {
                param($Family, $Value, $Expected)
                Test-RBAC4AppIPRange -Value $Value -Family $Family | Should -Be $Expected
            }
        }
    }
}

Describe 'Get-RBAC4AppLocationList' {
    It 'loads a non-empty list from the locations.txt shipped with the module' {
        InModuleScope EXORBACforAppManagement {
            @(Get-RBAC4AppLocationList).Count | Should -BeGreaterThan 0
        }
    }

    Context 'with a substitute module root' {
        BeforeAll {
            $script:originalRoot = InModuleScope EXORBACforAppManagement { $script:RBAC4AppModuleRoot }
        }

        AfterEach {
            InModuleScope EXORBACforAppManagement -Parameters @{ Root = $script:originalRoot } {
                param($Root)
                $script:RBAC4AppModuleRoot = $Root
            }
        }

        It 'returns trimmed entries, skipping blank and comment lines' {
            $root = Join-Path $TestDrive 'with-list'
            New-Item -ItemType Directory -Path $root | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'locations.txt') -Encoding UTF8 -Value @('# header', '', '  Warszawa  ', '   # indented comment', 'Kraków')

            InModuleScope EXORBACforAppManagement -Parameters @{ Root = $root } {
                param($Root)
                $script:RBAC4AppModuleRoot = $Root
                @(Get-RBAC4AppLocationList) | Should -Be @('Warszawa', 'Kraków')
            }
        }

        It 'throws when the file is missing' {
            $root = Join-Path $TestDrive 'without-list'
            New-Item -ItemType Directory -Path $root | Out-Null

            InModuleScope EXORBACforAppManagement -Parameters @{ Root = $root } {
                param($Root)
                $script:RBAC4AppModuleRoot = $Root
                { Get-RBAC4AppLocationList } | Should -Throw '*Location list file not found*'
            }
        }
    }
}

Describe 'Resolve-RBAC4AppScope security group type (IsDirSynced)' {
    BeforeAll {
        function global:Get-UnifiedGroup { param([string]$Identity) }
        function global:Get-DistributionGroup { param([string]$Identity) }
        function global:Get-DistributionGroupMember { param([string]$Identity) }
        function global:Get-ManagementScope { param([string]$Identity) }
    }

    It 'types a MailUniversalSecurityGroup with IsDirSynced <Synced> as <Expected>' -TestCases @(
        @{ Synced = '$false'; Expected = 'CloudMailEnabledSecurityGroup' }
        @{ Synced = '$true'; Expected = 'HybridMailEnabledSecurityGroup' }
        @{ Synced = 'missing'; Expected = 'HybridMailEnabledSecurityGroup' }
    ) {
        param($Synced, $Expected)
        InModuleScope EXORBACforAppManagement -Parameters @{ Synced = $Synced; Expected = $Expected } {
            param($Synced, $Expected)
            Mock Get-UnifiedGroup { $null }
            Mock Get-DistributionGroupMember { @() }
            Mock Get-DistributionGroup {
                $g = [pscustomobject]@{ Identity = $Identity; RecipientTypeDetails = 'MailUniversalSecurityGroup' }
                switch ($Synced) {
                    '$false' { $g | Add-Member -NotePropertyName IsDirSynced -NotePropertyValue $false }
                    '$true'  { $g | Add-Member -NotePropertyName IsDirSynced -NotePropertyValue $true }
                }
                $g
            }.GetNewClosure()

            $assignment = [pscustomobject]@{
                RecipientWriteScope       = 'Group'
                CustomRecipientWriteScope = $null
                CustomResourceScope       = 'USRACo1P-Contoso_20d5848c-4d61-4b82-a44f-205adc37321f'
            }
            $r = Resolve-RBAC4AppScope -Assignment $assignment -Cache @{}

            $r.ScopeGroupName | Should -Be 'USRACo1P-Contoso'
            $r.ScopeGroupType | Should -Be $Expected
        }
    }
}

Describe 'Get-RBAC4AppLegacyScopeGroupName (pre-0.9.0 guard)' {
    BeforeAll {
        function global:Get-DistributionGroup { param([string]$Identity) }
    }

    It 'returns the UDLRAo1P name only for defaults, an existing list, and a missing cloud group' {
        InModuleScope EXORBACforAppManagement {
            Mock Get-DistributionGroup { if ($Identity -eq 'UDLRAo1P-Contoso') { [pscustomobject]@{ Name = $Identity } } }
            $common = @{ AccessGroupType = 'CloudMailEnabledSecurityGroup'; CurrentGroupName = 'USRACo1P-Contoso'; DisplayName = 'Contoso'; AppId = 'a' }

            Get-RBAC4AppLegacyScopeGroupName -BoundParameters @{} @common | Should -Be 'UDLRAo1P-Contoso'
            foreach ($explicit in 'AccessGroupType', 'AccessGroupName', 'GroupPrefix') {
                Get-RBAC4AppLegacyScopeGroupName -BoundParameters @{ $explicit = 'x' } @common | Should -BeNullOrEmpty
            }
            Get-RBAC4AppLegacyScopeGroupName -BoundParameters @{} -AccessGroupType M365Group -CurrentGroupName 'Um365RAo1P-Contoso' -DisplayName 'Contoso' -AppId 'a' | Should -BeNullOrEmpty

            Mock Get-DistributionGroup { [pscustomobject]@{ Name = $Identity } }
            Get-RBAC4AppLegacyScopeGroupName -BoundParameters @{} @common | Should -BeNullOrEmpty

            Mock Get-DistributionGroup { }
            Get-RBAC4AppLegacyScopeGroupName -BoundParameters @{} @common | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-RBAC4AppM365Dsc (Microsoft365DSC rendering)' {
    BeforeAll {
        $script:newDscConfig = {
            param([hashtable] $Scope = @{}, [string] $DisplayName = 'Contoso', [string[]] $Roles = @('Application Mail.Send'))
            $config = [ordered]@{
                SchemaVersion = '4.4'
                Application   = [pscustomobject]@{ AppId = '11111111-1111-1111-1111-111111111111'; SpObjectId = '22222222-2222-2222-2222-222222222222'; DisplayName = $DisplayName; TenantId = 'tenant-1' }
                Rbac          = [pscustomobject]@{ Roles = $Roles }
            }
            if ($Scope.Count -gt 0) { $config.RbacScope = [pscustomobject]$Scope }
            [pscustomobject]$config
        }
        # Tokens and string literal values of a generated script; the DSC module itself is not needed.
        # 'Configuration' is a DSC keyword only on Windows PowerShell hosts with DSC available, so
        # the script is parsed as a plain function instead: on every platform the resource and
        # property names then tokenize as command names, and anything outside the known DSC
        # vocabulary (UnexpectedCommands) would be injected code.
        $script:dscVocabulary = @(
            'Import-DscResource', 'Node',
            'EXOServicePrincipal', 'EXODistributionGroup', 'EXOManagementScope', 'EXOManagementRoleAssignment',
            'AppName', 'DisplayName', 'AppId', 'Identity', 'Ensure', 'ManagedIdentity', 'TenantId',
            'ApplicationId', 'CertificateThumbprint', 'Name', 'Alias', 'Type', 'ManagedBy', 'Members',
            'HiddenFromAddressListsEnabled', 'RequireSenderAuthenticationEnabled',
            'AcceptMessagesOnlyFromSendersOrMembers', 'MemberJoinRestriction', 'MemberDepartRestriction',
            'RecipientRestrictionFilter', 'DependsOn', 'Role', 'App', 'CustomResourceScope'
        )
        $script:readDsc = {
            param([string] $Script)
            $tokens = $null; $errors = $null
            $plain = $Script -replace '(?m)^Configuration (?=RBAC4App_)', 'function '
            $null = [System.Management.Automation.Language.Parser]::ParseInput($plain, [ref]$tokens, [ref]$errors)
            $commands = @($tokens | Where-Object { $_.TokenFlags -band [System.Management.Automation.Language.TokenFlags]::CommandName } | ForEach-Object { $_.Text } | Sort-Object -Unique)
            [pscustomobject]@{
                ParseErrors        = @($errors | ForEach-Object { $_.Message })
                Commands           = $commands
                UnexpectedCommands = @($commands | Where-Object { $_ -notin $script:dscVocabulary })
                Strings        = @($tokens | Where-Object { $_ -is [System.Management.Automation.Language.StringToken] } | ForEach-Object { $_.Value })
                SubExpressions = @($tokens | Where-Object { $_.Kind -eq 'DollarParen' })
            }
        }
    }

    It 'renders the default group config: SP, security group, management scope over a DN parameter, assignment' {
        $r = InModuleScope EXORBACforAppManagement -Parameters @{ Config = (& $script:newDscConfig) } { param($Config) ConvertTo-RBAC4AppM365Dsc -Config $Config }

        $r.ConfigurationName | Should -Be 'RBAC4App_Contoso'
        $r.Script | Should -Match 'Configuration RBAC4App_Contoso'
        $r.Script | Should -Match "EXOServicePrincipal 'SP-Contoso-"
        $r.Script | Should -Match "AppName\s+= 'Contoso_SP'"
        $r.Script | Should -Match "EXODistributionGroup 'Group-USRACo1P-Contoso'"
        $r.Script | Should -Match "Type\s+= 'Security'"
        $r.Script | Should -Match "AcceptMessagesOnlyFromSendersOrMembers = @\('GraphAPI-Dummy-owner'\)"
        $r.Script | Should -Match '\[Parameter\(Mandatory = \$true\)\]\s+\[System\.String\]\s+\$ScopeGroupDistinguishedName'
        $r.Script | Should -Match ([regex]::Escape('RecipientRestrictionFilter = ("MemberOfGroup -eq ''{0}''" -f $ScopeGroupDistinguishedName.Replace("''", "''''"))'))
        $r.Script | Should -Match "EXOManagementRoleAssignment 'Assignment-AppMailSend-Contoso'"
        $r.Script | Should -Match "CustomResourceScope = 'MSRAo1P-Contoso'"
        $r.Script | Should -Match "App\s+= '22222222-2222-2222-2222-222222222222'"
        $r.Script | Should -Match '\$TenantId = ''tenant-1'''
        ([regex]::Matches($r.Script, 'ManagedIdentity = \$true')).Count | Should -Be 4
        $r.Script | Should -Not -Match 'Credential|CertificateThumbprint|RecipientGroupScope ='
        ($r.Warnings -join ';') | Should -Match 'has no RecipientGroupScope'
        ($r.Warnings -join ';') | Should -Match 'Members is authoritative'
        $parsed = & $script:readDsc $r.Script
        $parsed.ParseErrors | Should -BeNullOrEmpty
        $parsed.UnexpectedCommands | Should -BeNullOrEmpty
        $parsed.Commands | Should -Contain 'Import-DscResource'
    }

    It 'renders certificate sign-in with -Authentication Certificate (no managed identity, no secret)' {
        $r = InModuleScope EXORBACforAppManagement -Parameters @{ Config = (& $script:newDscConfig) } { param($Config) ConvertTo-RBAC4AppM365Dsc -Config $Config -Authentication Certificate }

        $r.Script | Should -Not -Match 'ManagedIdentity'
        $r.Script | Should -Match '\[Parameter\(Mandatory = \$true\)\]\s+\[System\.String\]\s+\$ApplicationId'
        $r.Script | Should -Match '\[Parameter\(Mandatory = \$true\)\]\s+\[System\.String\]\s+\$CertificateThumbprint'
        ([regex]::Matches($r.Script, 'ApplicationId         = \$ApplicationId')).Count | Should -Be 4
        ([regex]::Matches($r.Script, 'CertificateThumbprint = \$CertificateThumbprint')).Count | Should -Be 4
        ([regex]::Matches($r.Script, 'TenantId              = \$TenantId')).Count | Should -Be 4
        $r.Script | Should -Not -Match 'Credential|CertificatePassword|CertificatePath'
        $parsed = & $script:readDsc $r.Script
        $parsed.ParseErrors | Should -BeNullOrEmpty
        $parsed.UnexpectedCommands | Should -BeNullOrEmpty
    }

    It 'pre-fills a known group DN, and declares a distribution list as Type Distribution' {
        $config = & $script:newDscConfig @{ AccessGroupType = 'DistributionList'; AssignmentScope = 'ManagementScope'; Members = @('a@contoso.com') }
        $r = InModuleScope EXORBACforAppManagement -Parameters @{ Config = $config } { param($Config) ConvertTo-RBAC4AppM365Dsc -Config $Config -ScopeGroupDistinguishedName "CN=O'Brien,DC=prod" }

        $r.Script | Should -Match ([regex]::Escape('$ScopeGroupDistinguishedName = ''CN=O''''Brien,DC=prod'''))
        $r.Script | Should -Match "Type\s+= 'Distribution'"
        $r.Script | Should -Match "Members\s+= @\('GraphAPI-Dummy', 'a@contoso.com'\)"
        ($r.Warnings -join ';') | Should -Not -Match 'has no RecipientGroupScope'
    }

    It 'only references a <Type> group (no EXODistributionGroup resource)' -TestCases @(
        @{ Type = 'HybridMailEnabledSecurityGroup'; Name = 'OnPrem-Scope' }
        @{ Type = 'M365Group'; Name = '' }
    ) {
        param($Type, $Name)
        $scope = @{ AccessGroupType = $Type }
        if ($Name) { $scope.AccessGroupName = $Name }
        $r = InModuleScope EXORBACforAppManagement -Parameters @{ Config = (& $script:newDscConfig $scope) } { param($Config) ConvertTo-RBAC4AppM365Dsc -Config $Config }

        $r.Script | Should -Not -Match 'EXODistributionGroup'
        $r.Script | Should -Match 'EXOManagementScope'
        ($r.Warnings -join ';') | Should -Match "$Type scope group is only referenced"
    }

    It 'renders Recipients, Tag and Filter scopes as literal filters without a DN parameter' {
        $cases = @(
            @{ Scope = @{ ScopeKind = 'Recipients'; ScopeRecipients = @('b@contoso.com', "o'x@contoso.com") }; Filter = "(PrimarySmtpAddress -eq 'b@contoso.com') -or (PrimarySmtpAddress -eq 'o''x@contoso.com')" }
            @{ Scope = @{ ScopeKind = 'Tag'; ScopeTagAttribute = 'CustomAttribute3' }; Filter = "CustomAttribute3 -eq 'MSRAo1P-Contoso'" }
            @{ Scope = @{ ScopeKind = 'Filter'; ScopeFilter = "Department -eq 'Sales'" }; Filter = "Department -eq 'Sales'" }
        )
        foreach ($case in $cases) {
            $r = InModuleScope EXORBACforAppManagement -Parameters @{ Config = (& $script:newDscConfig $case.Scope) } { param($Config) ConvertTo-RBAC4AppM365Dsc -Config $Config }
            $r.Script | Should -Not -Match 'ScopeGroupDistinguishedName'
            $r.Script | Should -Not -Match 'EXODistributionGroup'
            (& $script:readDsc $r.Script).Strings | Should -Contain $case.Filter
        }
    }

    It 'gives every role its own group, scope and DN parameter with SeparateScopePerRole' {
        $config = & $script:newDscConfig @{ SeparateScopePerRole = $true } 'Contoso' @('Application Mail.Send', 'Application Calendars.Read')
        $r = InModuleScope EXORBACforAppManagement -Parameters @{ Config = $config } { param($Config) ConvertTo-RBAC4AppM365Dsc -Config $Config }

        $r.Script | Should -Match '\$ScopeGroupDistinguishedNameAppMailSend'
        $r.Script | Should -Match '\$ScopeGroupDistinguishedNameAppCldR'
        $r.Script | Should -Match "EXODistributionGroup 'Group-USRACo1P-Contoso-AppMailSend'"
        $r.Script | Should -Match "EXOManagementScope 'Scope-MSRAo1P-Contoso-AppCldR'"
        $r.Script | Should -Match "Name\s+= 'AppCldR-Contoso'[\s\S]*?CustomResourceScope = 'MSRAo1P-Contoso-AppCldR'"
    }

    It 'keeps a hostile display name inert (one string literal, no command, no subexpression)' {
        $hostile = "Con'toso `$(Remove-Item x) `"; Stop-Process -Id 1 #`r`nInvoke-Expression 'x' " + [char]0x2019 + '; calc'
        $r = InModuleScope EXORBACforAppManagement -Parameters @{ Config = (& $script:newDscConfig @{} $hostile) } { param($Config) ConvertTo-RBAC4AppM365Dsc -Config $Config }

        $parsed = & $script:readDsc $r.Script
        $parsed.ParseErrors | Should -BeNullOrEmpty
        $parsed.UnexpectedCommands | Should -BeNullOrEmpty
        $parsed.SubExpressions | Should -BeNullOrEmpty
        $parsed.Strings | Should -Contain ($hostile + '_SP')
        $r.ConfigurationName | Should -Match '^RBAC4App_[A-Za-z0-9_]+$'
    }

    It 'refuses a config without roles, with an unknown role, or with an invalid configuration name' {
        InModuleScope EXORBACforAppManagement -Parameters @{ New = $script:newDscConfig } {
            param($New)
            { ConvertTo-RBAC4AppM365Dsc -Config (& $New @{} 'Contoso' @()) } | Should -Throw '*no Rbac.Roles*'
            { ConvertTo-RBAC4AppM365Dsc -Config (& $New @{} 'Contoso' @('Application Bogus')) } | Should -Throw '*not a known application role*'
            { ConvertTo-RBAC4AppM365Dsc -Config (& $New) -ConfigurationName 'bad name;x' } | Should -Throw '*Invalid -ConfigurationName*'
            { ConvertTo-RBAC4AppM365Dsc -Config (& $New @{ AccessGroupType = 'HybridMailEnabledSecurityGroup' }) } | Should -Throw '*AccessGroupName is required*'
            (ConvertTo-RBAC4AppM365Dsc -Config (& $New @{} '!!!')).ConfigurationName | Should -Be 'RBAC4App_11111111111111111111111111111111'
            ConvertTo-RBAC4AppDscLiteral -Value $true | Should -Be '$true'
            ConvertTo-RBAC4AppDscLiteral -Value $false | Should -Be '$false'
        }
    }
}
