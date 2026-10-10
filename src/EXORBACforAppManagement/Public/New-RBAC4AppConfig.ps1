<#
.SYNOPSIS
Resolves an Entra service principal and writes a YAML or JSON configuration file for use with
Invoke-RBAC4AppConfig in a separate ExchangeOnlineManagement-only session.

.DESCRIPTION
New-RBAC4AppConfig is the Microsoft Graph half of the two-session workflow. It resolves the
Entra service principal (via Get-MgServicePrincipal), captures the RBAC provisioning
parameters, and serialises everything to a config file - YAML (default) or JSON, selected via
-Format. The resulting file contains no secrets and can be handed to Invoke-RBAC4AppConfig
running in a separate PowerShell session where only ExchangeOnlineManagement is connected -
working around the MSAL/WAM assembly conflict that prevents both modules from coexisting in a
single session. Invoke-RBAC4AppConfig auto-detects the format from the file extension
(.json vs .yml/.yaml).

The config uses schema version 4.0: on top of the 3.0 group settings, RbacScope carries the
management scope settings (ScopeKind, ManagementScopeName/ManagementScopePrefix, ScopeRecipients,
ScopeTagAttribute, ScopeTagValue, ScopeFilter) that Invoke-RBAC4AppConfig uses to bind the role
assignments to an Exchange Online management scope, exactly like New-RBAC4AppEntry.

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
Kind of scope group: DistributionList (default), M365Group, or MailEnabledSecurityGroup.

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
One or more recipients assigned as the scope group's owners. Defaults to 'GraphAPI-Dummy-owner'.

.PARAMETER BootstrapMember
Initial placeholder member passed during scope group creation. Defaults to 'GraphAPI-Dummy'.

.PARAMETER ScopeKind
How the management scope selects recipients: Group (default; members of the scope group),
Recipients (-ScopeRecipients), Tag (-ScopeTagAttribute/-ScopeTagValue), or Filter (-ScopeFilter).
Group settings (AccessGroupType, GroupPrefix, Members, ...) only apply to the Group kind.

.PARAMETER ManagementScopeName
Explicit management scope name. Cannot be combined with -ManagementScopePrefix.

.PARAMETER ManagementScopePrefix
Prefix of the generated management scope name ("{Prefix}-{DisplayName}"). Default 'MSRAo1P'.

.PARAMETER ScopeRecipients
Mailboxes/UPNs/SMTP addresses for -ScopeKind Recipients.

.PARAMETER ScopeTagAttribute
CustomAttribute1..CustomAttribute15 for -ScopeKind Tag. Default CustomAttribute1.

.PARAMETER ScopeTagValue
Value for -ScopeKind Tag. When omitted, Invoke-RBAC4AppConfig uses the management scope name.

.PARAMETER ScopeFilter
Raw OPATH recipient restriction filter for -ScopeKind Filter.

.PARAMETER ChangeReference
Optional change or incident reference to carry into the config file so Invoke-RBAC4AppConfig can
persist it in the local metadata store when provisioning the scope group.

.PARAMETER OutputPath
Directory to write the config file into. Defaults to the current working directory.

.PARAMETER Format
Config file format to write: Yaml (default) or Json. Only changes serialisation and the output
file extension (.yml vs .json); the config schema and every other parameter are identical.

.EXAMPLE
$yml = New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' -Role 'Mail.Send' -Members 'shared@contoso.com'
Invoke-RBAC4AppConfig -Path $yml

.EXAMPLE
$json = New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' -Role 'Mail.Send' -Format Json
Invoke-RBAC4AppConfig -Path $json

.EXAMPLE
New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' -ScopeKind Recipients -ScopeRecipients 'alice@contoso.com','bob@contoso.com'

.OUTPUTS
System.String — the full path of the written config file (.yml or .json, depending on -Format).
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
        [string] $AccessGroupType = 'DistributionList',

        [Parameter()]
        [string] $GroupPrefix = $null,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $AccessGroupName,

        [Parameter()]
        [string[]] $Members = @('GraphAPI-Dummy'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $ManagedBy = @('GraphAPI-Dummy-owner'),

        [Parameter()]
        [string] $BootstrapMember = 'GraphAPI-Dummy',

        [Parameter()]
        [ValidateSet('Group', 'Recipients', 'Tag', 'Filter')]
        [string] $ScopeKind = 'Group',

        [Parameter()]
        [ValidateLength(1, 64)]
        [string] $ManagementScopeName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ManagementScopePrefix = 'MSRAo1P',

        [Parameter()]
        [string[]] $ScopeRecipients,

        [Parameter()]
        [ValidatePattern('^CustomAttribute([1-9]|1[0-5])$')]
        [string] $ScopeTagAttribute = 'CustomAttribute1',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ScopeTagValue,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ScopeFilter,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ChangeReference,

        [Parameter()]
        [string] $OutputPath,

        [Parameter()]
        [ValidateSet('Yaml', 'Json')]
        [string] $Format = 'Yaml'
    )

    process {
        if ($PSBoundParameters.ContainsKey('AccessGroupName') -and $PSBoundParameters.ContainsKey('GroupPrefix')) {
            throw 'Parameters -AccessGroupName and -GroupPrefix cannot be used together.'
        }
        if ($PSBoundParameters.ContainsKey('ManagementScopeName') -and $PSBoundParameters.ContainsKey('ManagementScopePrefix')) {
            throw 'Parameters -ManagementScopeName and -ManagementScopePrefix cannot be used together.'
        }
        if ($ScopeKind -eq 'Recipients' -and -not $ScopeRecipients) {
            throw '-ScopeRecipients is required when -ScopeKind is Recipients.'
        }
        if ($ScopeKind -eq 'Filter' -and -not $ScopeFilter) {
            throw '-ScopeFilter is required when -ScopeKind is Filter.'
        }
        foreach ($ignoredMsg in @(Get-RBAC4AppScopeKindWarning -ScopeKind $ScopeKind -BoundParameters $PSBoundParameters)) {
            Write-Warning -Message $ignoredMsg
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
                    $escapedName = $RegisteredAppName.Replace("'", "''")
                    $matchesRes = @(Get-MgServicePrincipal -Filter "displayName eq '$escapedName'" -ErrorAction Stop)
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
            SchemaVersion = '4.0'
            GeneratedAt   = (Get-Date).ToUniversalTime().ToString('o')
            TenantId      = $tenantId
            Application   = [pscustomobject]@{
                AppId       = [string]$sp.AppId
                SpObjectId  = [string]$sp.Id
                DisplayName = [string]$sp.DisplayName
            }
            Rbac          = [pscustomobject]@{
                Roles           = $normalizedRoles
                ChangeReference = if ($PSBoundParameters.ContainsKey('ChangeReference')) { $ChangeReference } else { '' }
            }
            RbacScope     = [pscustomobject]@{
                AccessGroupType = $AccessGroupType
                GroupPrefix     = $GroupPrefix
                AccessGroupName = $accessGroupNameValue
                Members         = $Members
                ManagedBy       = $ManagedBy
                BootstrapMember = $BootstrapMember
                ScopeKind             = $ScopeKind
                ManagementScopeName   = if ($PSBoundParameters.ContainsKey('ManagementScopeName')) { $ManagementScopeName } else { '' }
                ManagementScopePrefix = $ManagementScopePrefix
                ScopeRecipients       = @($ScopeRecipients | Where-Object { $_ })
                ScopeTagAttribute     = $ScopeTagAttribute
                ScopeTagValue         = if ($ScopeTagValue) { $ScopeTagValue } else { '' }
                ScopeFilter           = if ($ScopeFilter) { $ScopeFilter } else { '' }
            }
        }

        # --- Write config file (YAML or JSON, per -Format)
        $extension = if ($Format -eq 'Json') { 'json' } else { 'yml' }
        $safeName  = Get-SafeName -s $sp.DisplayName -max 40
        $timestamp = (Get-Date).ToString('yyyyMMddHHmm')
        $fileName  = "rbac4app-$safeName-$timestamp.$extension"
        $outFile   = Join-Path $OutputPath $fileName

        $serialized = if ($Format -eq 'Json') { $config | ConvertTo-Json -Depth 6 } else { ConvertTo-RBAC4AppYaml -Config $config }
        Write-Verbose ("Config {0}:`n{1}" -f $Format, $serialized)

        if ($PSCmdlet.ShouldProcess($outFile, "Write RBAC4App config ($Format)")) {
            [System.IO.File]::WriteAllText($outFile, $serialized, [System.Text.Encoding]::UTF8)
            Write-Verbose "Config written to '$outFile'."
            return $outFile
        }
    }
}
