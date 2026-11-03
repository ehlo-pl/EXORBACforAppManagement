#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:syncScriptPath = Join-Path $PSScriptRoot '..' 'scripts' 'Sync-ADGroupMembers.ps1'
}

function global:Get-ADGroup {
    param($Identity, $Properties, $ErrorAction)
}

function global:Get-ADGroupMember {
    param($Identity, $Recursive, $ErrorAction)
}

function global:Add-ADGroupMember {
    param($Identity, $Members, $Confirm, $ErrorAction)
}

function global:Remove-ADGroupMember {
    param($Identity, $Members, $Confirm, $ErrorAction)
}

Describe 'Sync-ADGroupMembers verbose progress' {
    BeforeEach {
        Mock Import-Module {}
        Mock Get-ADGroup {
            if ($Identity -eq 'Destination') {
                [pscustomobject]@{
                    Name = 'Destination'
                    DistinguishedName = 'CN=Destination'
                    GroupScope = 'Universal'
                    GroupCategory = 'Security'
                    SID = [pscustomobject]@{ Value = 'S-1-DESTINATION' }
                }
            }
            else {
                [pscustomobject]@{
                    Name = 'Source'
                    DistinguishedName = 'CN=Source'
                    SID = [pscustomobject]@{ Value = 'S-1-SOURCE' }
                }
            }
        }
        Mock Get-ADGroupMember {
            if ($Identity -eq 'CN=Source') {
                @(
                    [pscustomobject]@{
                        objectClass = 'user'
                        SID = [pscustomobject]@{ Value = 'S-1-USER-1' }
                        SamAccountName = 'User1'
                        DistinguishedName = 'CN=User1'
                    }
                    [pscustomobject]@{
                        objectClass = 'user'
                        SID = [pscustomobject]@{ Value = 'S-1-USER-2' }
                        SamAccountName = 'User2'
                        DistinguishedName = 'CN=User2'
                    }
                )
            }
            else {
                [pscustomobject]@{
                    objectClass = 'user'
                    SID = [pscustomobject]@{ Value = 'S-1-STALE' }
                    SamAccountName = 'StaleUser'
                    DistinguishedName = 'CN=StaleUser'
                }
            }
        }
        Mock Add-ADGroupMember {}
        Mock Remove-ADGroupMember {}
    }

    It 'reports initial data collection and numbers each planned addition and removal' {
        $output = & $script:syncScriptPath -SourceGroup Source -DestinationGroup Destination -Verbose 4>&1
        $messages = @(
            $output |
                Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } |
                ForEach-Object Message |
                Where-Object { $_ -match '^(Starting initial|Finished initial|Adding user|Removing user)' }
        )

        $expected = @(
            'Starting initial data collection.'
            'Finished initial data collection. Planned additions: 2; planned removals: 1.'
            "Adding user 1 of 2: 'User1'."
            "Adding user 2 of 2: 'User2'."
            "Removing user 1 of 1: 'StaleUser'."
        ) -join "`n"
        ($messages -join "`n") | Should -Be $expected
    }
}
