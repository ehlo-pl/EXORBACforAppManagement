<#
.SYNOPSIS
Adds Microsoft Graph application permissions to an Application Access Policy export.

.DESCRIPTION
Reads the YAML or JSON file created by Resolve-ApplicationAccessPolicy, then uses
Microsoft Graph application-role assignments to populate Permissions with granted
Mail.*, Calendars.*, and Contacts.* application permissions. Run this command in a
separate session connected to Microsoft Graph.

.PARAMETER Path
Path to the exported YAML or JSON file. The ConfigPath property from
Resolve-ApplicationAccessPolicy can be piped directly.

.PARAMETER OutputPath
Path for the enriched file. Defaults to a new sibling file, leaving the input unchanged.

.EXAMPLE
$export = Resolve-ApplicationAccessPolicy
$export | Invoke-MsGraphEntraIDApiPerm

Reads the exported policy file and writes an enriched copy containing Graph permissions.
#>
function Invoke-MsGraphEntraIDApiPerm {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('ConfigPath')]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath
    )

    process {
        $inputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $extension = [System.IO.Path]::GetExtension($inputPath).ToLowerInvariant()
        try {
            $content = [System.IO.File]::ReadAllText($inputPath)
            if ($extension -eq '.json') {
                $document = $content | ConvertFrom-Json -ErrorAction Stop
                $policies = @($document.Policies)
            }
            elseif ($extension -in @('.yml', '.yaml')) {
                $document = ConvertFrom-ApplicationAccessPolicyYaml -Content $content
                $policies = @($document.Policies)
            }
            else {
                throw "Unsupported policy file extension '$extension'. Use .yml, .yaml, or .json."
            }
        }
        catch {
            Write-Error -Message ("Failed to read Application Access Policy export: {0}" -f $_.Exception.Message)
            return
        }

        $result = [ordered]@{
            InputPath  = $inputPath
            OutputPath = $null
            Policies   = @()
            Errors     = @()
        }

        try {
            $graphMatches = @(Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'" -ErrorAction Stop)
            if ($graphMatches.Count -ne 1) {
                throw "Expected one Microsoft Graph service principal but found $($graphMatches.Count)."
            }
            $graphSp = $graphMatches[0]
        }
        catch {
            $result.Errors += $_.Exception.Message
            [pscustomobject]$result
            return
        }

        $appSpCache = @{}
        foreach ($policy in $policies) {
            $appId = [string]$policy.AppId
            if ($appId -notmatch '^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$') {
                $result.Errors += "Invalid AppId '$appId' in the policy export."
                $policy.Permissions = @()
                $result.Policies += $policy
                continue
            }
            if (-not $appSpCache.ContainsKey($appId)) {
                try {
                    $appMatches = @(Get-MgServicePrincipal -Filter "appId eq '$appId'" -ErrorAction Stop)
                    if ($appMatches.Count -ne 1) {
                        throw "Expected one service principal for AppId '$appId' but found $($appMatches.Count)."
                    }
                    $appSpCache[$appId] = $appMatches[0]
                }
                catch {
                    $appSpCache[$appId] = $null
                    $result.Errors += $_.Exception.Message
                }
            }

            $permissions = @()
            $appSp = $appSpCache[$appId]
            if ($appSp) {
                try {
                    $grants = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $appSp.Id -ErrorAction Stop)
                    foreach ($grant in $grants) {
                        if ([string]$grant.ResourceId -ne [string]$graphSp.Id -or -not $grant.AppRoleId) { continue }
                        $role = @($graphSp.AppRoles) |
                            Where-Object { [string]$_.Id -eq [string]$grant.AppRoleId } |
                            Select-Object -First 1
                        if ($role -and [string]$role.Value -match '^(Mail|Calendars|Contacts)\.') {
                            $permissions += [string]$role.Value
                        }
                    }
                }
                catch {
                    $result.Errors += "Failed to read Graph permissions for AppId '$appId': $($_.Exception.Message)"
                }
            }

            $policy.Permissions = @($permissions | Sort-Object -Unique)
            $result.Policies += $policy
        }

        if ($OutputPath) {
            $outputFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
        }
        else {
            $directory = [System.IO.Path]::GetDirectoryName($inputPath)
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputPath)
            $outputFile = Join-Path $directory "$baseName-with-api-permissions$extension"
        }

        $serialized = if ($extension -eq '.json') {
            ([pscustomobject]@{ Policies = @($result.Policies) } | ConvertTo-Json -Depth 6)
        }
        else {
            ConvertTo-ApplicationAccessPolicyYaml -Policies @($result.Policies)
        }

        if ($PSCmdlet.ShouldProcess($outputFile, 'Write Application Access Policy permissions')) {
            try {
                [System.IO.File]::WriteAllText($outputFile, $serialized, [System.Text.Encoding]::UTF8)
                $result.OutputPath = $outputFile
            }
            catch {
                $result.Errors += $_.Exception.Message
            }
        }

        [pscustomobject]$result
    }
}
