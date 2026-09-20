<#
.SYNOPSIS
Resolves an Entra service principal and writes a YAML configuration file for use with
Invoke-RBAC4AppConfig in a separate ExchangeOnlineManagement-only session.

.DESCRIPTION
New-RBAC4AppConfig is the Microsoft Graph half of the two-session workflow. It resolves the
Entra service principal (via Get-MgServicePrincipal), captures the RBAC provisioning
parameters, and serialises everything to a YAML file. The resulting file contains no secrets
and can be handed to Invoke-RBAC4AppConfig running in a separate PowerShell session where
only ExchangeOnlineManagement is connected — working around the MSAL/WAM assembly conflict
that prevents both modules from coexisting in a single session.

.PARAMETER RegisteredAppName
Display name of the registered application / service principal (default parameter set).

.PARAMETER AppId
Application (client) ID of the registered application.

.PARAMETER SpObjectId
Object ID of the Entra service principal.

.PARAMETER Role
Exchange Online application roles to include in the config. Short names such as Mail.Send are
normalised to Application Mail.Send. Defaults to @('Application Mail.Send').

.PARAMETER AccessGroupType
Kind of scope group: M365Group (default), DistributionList, or MailEnabledSecurityGroup.

.PARAMETER GroupPrefix
Prefix used when generating the scope group name. When omitted, defaults to
'Um365RAo1P' (M365Group), 'UDLRAo1P' (DistributionList), or 'USRAo1P'
(MailEnabledSecurityGroup) based on -AccessGroupType.

.PARAMETER AccessGroupName
Explicit scope group name. Required when -AccessGroupType is MailEnabledSecurityGroup.
Cannot be combined with -GroupPrefix.

.PARAMETER Members
Recipients to add to the scope group. Defaults to @('GraphAPI-Dummy').

.PARAMETER ManagedBy
Recipient assigned as the scope group owner. Defaults to 'GraphAPI-Dummy-owner'.

.PARAMETER BootstrapMember
Initial placeholder member passed during scope group creation. Defaults to 'GraphAPI-Dummy'.

.PARAMETER OutputPath
Directory to write the YAML file into. Defaults to the current working directory.

.EXAMPLE
$yml = New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' -Role 'Mail.Send' -Members 'shared@contoso.com'
Invoke-RBAC4AppConfig -Path $yml

.OUTPUTS
System.String — the full path of the written YAML file.
#>
function New-RBAC4AppConfig {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low', DefaultParameterSetName = 'ByName')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, ParameterSetName = 'ByName')]
        [Alias('DisplayName', 'Name')]
        [ValidateNotNullOrEmpty()]
        [string] $RegisteredAppName,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'ByAppId')]
        [Alias('ClientId', 'ApplicationId')]
        [ValidatePattern('^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$')]
        [string] $AppId,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'BySpObjectId')]
        [Alias('Id', 'ObjectId', 'ServicePrincipalId')]
        [ValidatePattern('^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$')]
        [string] $SpObjectId,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Role = @('Application Mail.Send'),

        [Parameter()]
        [ValidateSet('M365Group', 'DistributionList', 'MailEnabledSecurityGroup')]
        [string] $AccessGroupType = 'M365Group',

        [Parameter()]
        [string] $GroupPrefix = $null,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $AccessGroupName,

        [Parameter()]
        [string[]] $Members = @('GraphAPI-Dummy'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ManagedBy = 'GraphAPI-Dummy-owner',

        [Parameter()]
        [string] $BootstrapMember = 'GraphAPI-Dummy',

        [Parameter()]
        [string] $OutputPath
    )

    process {
        if ($PSBoundParameters.ContainsKey('AccessGroupName') -and $PSBoundParameters.ContainsKey('GroupPrefix')) {
            throw 'Parameters -AccessGroupName and -GroupPrefix cannot be used together.'
        }

        if (-not $PSBoundParameters.ContainsKey('GroupPrefix')) {
            $GroupPrefix = switch ($AccessGroupType) {
                'DistributionList'         { 'UDLRAo1P' }
                'MailEnabledSecurityGroup' { 'USRAo1P' }
                default                    { 'Um365RAo1P' }
            }
        }

        if (-not $OutputPath) { $OutputPath = (Get-Location).Path }

        # --- Resolve service principal via Microsoft Graph
        $sp = $null
        try {
            switch ($PSCmdlet.ParameterSetName) {
                'BySpObjectId' {
                    Write-Verbose "Resolving service principal by object id '$SpObjectId'."
                    $sp = Get-MgServicePrincipal -ServicePrincipalId $SpObjectId -ErrorAction Stop
                }
                'ByAppId' {
                    Write-Verbose "Resolving service principal by appId '$AppId'."
                    $matchesRes = @(Get-MgServicePrincipal -Filter "appId eq '$AppId'" -ErrorAction Stop)
                    if ($matchesRes.Count -eq 0) { throw "No service principal found for AppId '$AppId'." }
                    if ($matchesRes.Count -gt 1) { throw "Ambiguous: $($matchesRes.Count) service principals match AppId '$AppId'." }
                    $sp = $matchesRes[0]
                }
                'ByName' {
                    Write-Verbose "Resolving service principal by display name '$RegisteredAppName'."
                    $matchesRes = @(Get-MgServicePrincipal -Filter "displayName eq '$RegisteredAppName'" -ErrorAction Stop)
                    if ($matchesRes.Count -eq 0) { throw "No service principal found for displayName '$RegisteredAppName'." }
                    if ($matchesRes.Count -gt 1) {
                        $ids = ($matchesRes | Select-Object -First 5 -ExpandProperty Id) -join ', '
                        throw "Ambiguous displayName '$RegisteredAppName' matched $($matchesRes.Count) SPs. Use -AppId or -SpObjectId. Examples: $ids"
                    }
                    $sp = $matchesRes[0]
                }
            }
        }
        catch {
            Write-Error "Service principal resolution failed: $_"
            return
        }

        # --- Tenant context (informational; graceful if Graph connection lacks permissions)
        $tenantId = ''
        try { $tenantId = (Get-MgContext -ErrorAction Stop).TenantId } catch { Write-Verbose "TenantId unavailable: $($_.Exception.Message)" }

        # --- Normalise roles
        $normalizedRoles = @(foreach ($r in @($Role)) { Get-NormalizeRole $r })

        # --- Build config object
        $accessGroupNameValue = if ($PSBoundParameters.ContainsKey('AccessGroupName')) { $AccessGroupName } else { '' }

        $config = [pscustomobject]@{
            SchemaVersion = '1.0'
            GeneratedAt   = (Get-Date).ToUniversalTime().ToString('o')
            TenantId      = $tenantId
            Application   = [pscustomobject]@{
                AppId       = [string]$sp.AppId
                SpObjectId  = [string]$sp.Id
                DisplayName = [string]$sp.DisplayName
            }
            Rbac          = [pscustomobject]@{
                Roles           = $normalizedRoles
                AccessGroupType = $AccessGroupType
                GroupPrefix     = $GroupPrefix
                AccessGroupName = $accessGroupNameValue
                Members         = $Members
                ManagedBy       = $ManagedBy
                BootstrapMember = $BootstrapMember
            }
        }

        # --- Write YAML file
        $safeName  = Get-SafeName -s $sp.DisplayName -max 40
        $timestamp = (Get-Date).ToString('yyyyMMddHHmm')
        $fileName  = "rbac4app-$safeName-$timestamp.yml"
        $outFile   = Join-Path $OutputPath $fileName

        $yaml = ConvertTo-RBAC4AppYaml -Config $config
        Write-Verbose ("Config YAML:`n{0}" -f $yaml)

        if ($PSCmdlet.ShouldProcess($outFile, 'Write RBAC4App config')) {
            [System.IO.File]::WriteAllText($outFile, $yaml, [System.Text.Encoding]::UTF8)
            Write-Verbose "Config written to '$outFile'."
            return $outFile
        }
    }
}
