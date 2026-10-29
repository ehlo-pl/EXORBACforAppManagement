<#
.SYNOPSIS
Exports Exchange Online Application Access Policies to YAML or JSON.

.DESCRIPTION
Reads Application Access Policies from Exchange Online and writes one file containing
ScopeName, ScopeIdentity, AppId, AccessRight, Group, and an empty Permissions array for
each policy. The file can be enriched later by Invoke-MsGraphEntraIDApiPerm in a separate
Microsoft Graph-connected session.

.PARAMETER AppId
Limit the export to one application (client) id.

.PARAMETER Policy
Application Access Policy objects to export, for example from Get-ApplicationAccessPolicy.

.PARAMETER OutputPath
Directory to write the export into. Defaults to the current directory.

.PARAMETER Format
Output format: Yaml (default) or Json.

.EXAMPLE
Resolve-ApplicationAccessPolicy -Format Json -OutputPath ./policies

Exports all Exchange Online Application Access Policies as JSON.
#>
function Resolve-ApplicationAccessPolicy {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter()]
        [ValidatePattern('^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$')]
        [string] $AppId,

        [Parameter(ValueFromPipeline)]
        [object[]] $Policy,

        [Parameter()]
        [string] $OutputPath,

        [Parameter()]
        [ValidateSet('Yaml', 'Json')]
        [string] $Format = 'Yaml'
    )

    begin {
        if (-not $OutputPath) { $OutputPath = (Get-Location).Path }
        $OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
        $pipedPolicies = [System.Collections.Generic.List[object]]::new()
        $receivedPolicies = $false
    }

    process {
        if ($PSBoundParameters.ContainsKey('Policy')) { $receivedPolicies = $true }
        foreach ($item in @($Policy)) {
            if ($null -ne $item) { $pipedPolicies.Add($item) }
        }
    }

    end {
        try {
            $policies = if ($receivedPolicies) {
                @($pipedPolicies.ToArray())
            }
            elseif ($PSBoundParameters.ContainsKey('AppId')) {
                @(Get-ApplicationAccessPolicy -AppId $AppId -ErrorAction Stop)
            }
            else {
                @(Get-ApplicationAccessPolicy -ErrorAction Stop)
            }
        }
        catch {
            Write-Error -Message ("Failed to read Application Access Policies: {0}" -f $_.Exception.Message)
            return
        }

        $records = @(
            foreach ($item in $policies) {
                $group = if ($item.PSObject.Properties['Group']) { $item.Group } else { $item.ScopeName }
                [pscustomobject]@{
                    ScopeName     = [string]$item.ScopeName
                    ScopeIdentity = [string]$item.ScopeIdentity
                    AppId         = [string]$item.AppId
                    AccessRight   = [string]$item.AccessRight
                    Group         = [string]$group
                    Permissions   = @()
                }
            }
        )

        $extension = if ($Format -eq 'Json') { 'json' } else { 'yml' }
        $timestamp = (Get-Date).ToString('yyyyMMddHHmmss')
        $fileName = "exo-application-access-policies-$timestamp-$([guid]::NewGuid().ToString('N')).$extension"
        $filePath = Join-Path $OutputPath $fileName
        $serialized = if ($Format -eq 'Json') {
            ([pscustomobject]@{ Policies = $records } | ConvertTo-Json -Depth 6)
        }
        else {
            ConvertTo-ApplicationAccessPolicyYaml -Policies $records
        }

        $result = [ordered]@{
            ConfigPath = $null
            Format     = $Format
            Policies   = $records
            Errors     = @()
        }
        if ($PSCmdlet.ShouldProcess($filePath, "Write Application Access Policy export ($Format)")) {
            try {
                [System.IO.File]::WriteAllText($filePath, $serialized, [System.Text.Encoding]::UTF8)
                $result.ConfigPath = $filePath
            }
            catch {
                $result.Errors += $_.Exception.Message
            }
        }

        [pscustomobject]$result
    }
}
