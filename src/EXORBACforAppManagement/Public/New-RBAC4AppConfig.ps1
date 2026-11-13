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

The config uses schema version 4.4: an optional Metadata section carries descriptive application
details (contacts, PCode, CMDB ID, description, network access) that never affect provisioning. On
top of the 3.0 group settings, RbacScope carries the
scope settings (ScopeKind, AssignmentScope, ManagementScopeName/ManagementScopePrefix,
ScopeRecipients, ScopeTagAttribute, ScopeTagValue, ScopeFilter) that Invoke-RBAC4AppConfig uses to
bind the role assignments. By default (-ScopeKind Group, -AssignmentScope RecipientGroupScope) the
role assignments are bound directly to the scope group (New-ManagementRoleAssignment
-RecipientGroupScope) and no management scope is created. Use -AssignmentScope ManagementScope to
bind them to an Exchange Online management scope over the group's members instead, like
New-RBAC4AppEntry; the Recipients, Tag, and Filter kinds always use a management scope.

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
Kind of scope group: CloudMailEnabledSecurityGroup (default; EXO-mastered mail-enabled security
group), DistributionList, M365Group, or HybridMailEnabledSecurityGroup (existing on-prem/synced group,
reference-only). The pre-0.9.0 name MailEnabledSecurityGroup is still accepted for HybridMailEnabledSecurityGroup. For a type the module creates, a warning is
recorded when -ManagedBy is left at the default owner GraphAPI-Dummy-owner: that recipient must exist
in Exchange Online, or Invoke-RBAC4AppConfig creates the group without the send restriction.

.PARAMETER GroupPrefix
Prefix used when generating the scope group name. When omitted, defaults to 'USRACo1P'
(CloudMailEnabledSecurityGroup), 'UDLRAo1P' (DistributionList), 'Um365RAo1P' (M365Group), or 'USRAHo1P'
(HybridMailEnabledSecurityGroup) based on -AccessGroupType.

.PARAMETER AccessGroupName
Explicit scope group name. Required when -AccessGroupType is HybridMailEnabledSecurityGroup.
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

.PARAMETER AssignmentScope
How the role assignments are bound for -ScopeKind Group: RecipientGroupScope (default; directly to
the scope group, no management scope) or ManagementScope (a management scope whose filter selects
the group's members). Other scope kinds always use ManagementScope; requesting RecipientGroupScope
with them is an error.

.PARAMETER SeparateScopePerRole
Create a separate scope group and management scope for each configured role/permission. Applies
only to -ScopeKind Group.

.PARAMETER ManagementScopeName
Explicit management scope name. Cannot be combined with -ManagementScopePrefix. Ignored with
-AssignmentScope RecipientGroupScope.

.PARAMETER ManagementScopePrefix
Prefix of the generated management scope name ("{Prefix}-{DisplayName}"). Default 'MSRAo1P'.
Ignored with -AssignmentScope RecipientGroupScope.

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

.PARAMETER OwnerUsername
Username of the application owner contact. Stored as supplied; not resolved against any directory.

.PARAMETER OwnerDisplayName
Display name of the application owner contact. Stored as supplied.

.PARAMETER TechnicalContactUsername
Username of the technical contact. Stored as supplied; not resolved against any directory.

.PARAMETER TechnicalContactDisplayName
Display name of the technical contact. Stored as supplied.

.PARAMETER PCode
Application PCode: 'P' followed by 5 digits, e.g. P12345. Stored in uppercase.

.PARAMETER CmdbId
CMDB identifier of the application (a GUID).

.PARAMETER Description
Single-line application description; may contain links. Line breaks are rejected.

.PARAMETER NetworkAccessIP4Range
IPv4 network the application connects from: an IPv4 address or IPv4 CIDR range, e.g. 10.0.0.0/24.
Independent of -NetworkAccessIP6Range and -NetworkAccessLocation.

.PARAMETER NetworkAccessIP6Range
IPv6 network the application connects from: an IPv6 address or IPv6 CIDR range, e.g.
2001:db8::/32. Independent of -NetworkAccessIP4Range and -NetworkAccessLocation.

.PARAMETER NetworkAccessLocation
Name of the location the application connects from; must be listed in the module's locations.txt
(matched case-insensitively, stored with the file's casing). Independent of -NetworkAccessIP4Range/-NetworkAccessIP6Range.

.PARAMETER Repository
Folder of manually created state files named {AppId}.yaml, {AppId}.yml or {AppId}.json. The file
matching the resolved application supplies every setting not given on the command line (command line,
then state file, then module defaults). The state file is never modified; the new config goes to
-OutputPath. Without a matching file a warning is written and the config is built as usual. Changing
-ScopeKind ignores the state file's AssignmentScope and SeparateScopePerRole; changing -AccessGroupType
ignores its AccessGroupName and GroupPrefix.

.PARAMETER OutputPath
Directory to write the config file into. Defaults to the current working directory.

.PARAMETER Format
Config file format to write: Yaml (default) or Json. Only changes serialisation and the output
file extension (.yml vs .json); the config schema and every other parameter are identical.
M365DSC writes the YAML config plus a Microsoft365DSC configuration script (.ps1, same name) that
declares the same desired state as EXOServicePrincipal, EXODistributionGroup (cloud security group
or distribution list only), EXOManagementScope and EXOManagementRoleAssignment resources. The script
authenticates with a managed identity (no secret is written), always binds through a management
scope (EXOManagementRoleAssignment has no RecipientGroupScope), and for -ScopeKind Group takes the
scope group's distinguished name as a mandatory Configuration parameter. Only the .yml can be fed to
Invoke-RBAC4AppConfig.

.PARAMETER DscAuthentication
How the Microsoft365DSC script written by -Format M365DSC signs in to Exchange Online:
ManagedIdentity (default; ManagedIdentity + TenantId on every resource - runs only on a machine with
a managed identity) or Certificate (ApplicationId + TenantId + CertificateThumbprint Configuration
parameters - runs on any machine holding the app's certificate). No secret is written either way.
Only valid with -Format M365DSC.

.EXAMPLE
$yml = New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' -Role 'Mail.Send' -Members 'shared@contoso.com'
Invoke-RBAC4AppConfig -Path $yml

.EXAMPLE
$json = New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' -Role 'Mail.Send' -Format Json
Invoke-RBAC4AppConfig -Path $json

.EXAMPLE
New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' -Role 'Mail.Send' -AssignmentScope ManagementScope

Binds the role assignments to a management scope over the scope group's members instead of
directly to the group.

.EXAMPLE
New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' -ScopeKind Recipients -ScopeRecipients 'alice@contoso.com','bob@contoso.com'

.EXAMPLE
New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' -OwnerUsername 'jdoe' -OwnerDisplayName 'Jan Doe' -PCode 'P12345' -CmdbId '11111111-2222-3333-4444-555555555555' -Description 'Runbook: https://wiki.contoso.com/mailapp' -NetworkAccessIP4Range '10.0.0.0/24' -NetworkAccessIP6Range '2001:db8::/32'

Records descriptive application metadata in the config's Metadata section.

.EXAMPLE
New-RBAC4AppConfig -AppId '11111111-2222-3333-4444-555555555555' -Repository 'C:\RBAC4AppState' -PCode 'P12345'

Builds a new config from C:\RBAC4AppState\11111111-2222-3333-4444-555555555555.yaml, overriding only
the PCode.

.OUTPUTS
System.String — the full path of the written config file (.yml or .json, depending on -Format).
With -Format M365DSC two paths: the .yml config, then the .ps1 Microsoft365DSC configuration.
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
        [ValidateSet('CloudMailEnabledSecurityGroup', 'DistributionList', 'M365Group', 'HybridMailEnabledSecurityGroup', 'MailEnabledSecurityGroup')]
        [string] $AccessGroupType = 'CloudMailEnabledSecurityGroup',

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
        [ValidateSet('RecipientGroupScope', 'ManagementScope')]
        [string] $AssignmentScope = 'RecipientGroupScope',

        [Parameter()]
        [ValidateLength(1, 64)]
        [string] $ManagementScopeName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ManagementScopePrefix = $script:RBAC4AppDefaultManagementScopePrefix,

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
        [Alias('SeparateScopePerPermission')]
        [switch] $SeparateScopePerRole,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ChangeReference,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $OwnerUsername,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $OwnerDisplayName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $TechnicalContactUsername,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $TechnicalContactDisplayName,

        [Parameter()]
        [ValidatePattern('^P[0-9]{5}$')]
        [string] $PCode,

        [Parameter()]
        [ValidatePattern('^[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}$')]
        [string] $CmdbId,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        # Not an anchored ValidatePattern: '$' also matches before a trailing newline.
        [ValidateScript({ $_ -notmatch '[\r\n]' })]
        [string] $Description,

        [Parameter()]
        [ValidateScript({ Test-RBAC4AppIPRange -Value $_ -Family IPv4 })]
        [string] $NetworkAccessIP4Range,

        [Parameter()]
        [ValidateScript({ Test-RBAC4AppIPRange -Value $_ -Family IPv6 })]
        [string] $NetworkAccessIP6Range,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $NetworkAccessLocation,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Repository,

        [Parameter()]
        [string] $OutputPath,

        [Parameter()]
        [ValidateSet('Yaml', 'Json', 'M365DSC')]
        [string] $Format = 'Yaml',

        [Parameter()]
        [ValidateSet('ManagedIdentity', 'Certificate')]
        [string] $DscAuthentication = 'ManagedIdentity'
    )

    process {
        if ($PSBoundParameters.ContainsKey('DscAuthentication') -and $Format -ne 'M365DSC') {
            throw '-DscAuthentication can only be used with -Format M365DSC.'
        }
        if ($PSBoundParameters.ContainsKey('AccessGroupName') -and $PSBoundParameters.ContainsKey('GroupPrefix')) {
            throw 'Parameters -AccessGroupName and -GroupPrefix cannot be used together.'
        }
        if ($PSBoundParameters.ContainsKey('ManagementScopeName') -and $PSBoundParameters.ContainsKey('ManagementScopePrefix')) {
            throw 'Parameters -ManagementScopeName and -ManagementScopePrefix cannot be used together.'
        }
        if ($Repository -and -not (Test-Path -LiteralPath $Repository -PathType Container)) {
            throw "-Repository folder '$Repository' does not exist."
        }

        # Warnings raised while building the config, also written to its Runtime.CollectedWarnings.
        $collectedWarnings = [System.Collections.Generic.List[string]]::new()

        # Dot-sourced so its normalized values stay in this scope. With -Repository it has to wait for
        # the state file, whose name depends on the resolved application.
        $boundParameters = $PSBoundParameters
        $validateSettings = {
            if ($ScopeKind -eq 'Recipients' -and -not $ScopeRecipients) {
                throw '-ScopeRecipients is required when -ScopeKind is Recipients.'
            }
            if ($ScopeKind -eq 'Filter' -and -not $ScopeFilter) {
                throw '-ScopeFilter is required when -ScopeKind is Filter.'
            }
            if ($SeparateScopePerRole -and $ScopeKind -ne 'Group') {
                throw '-SeparateScopePerRole can only be used with -ScopeKind Group.'
            }
            if ($PCode) { $PCode = $PCode.ToUpperInvariant() }
            if ($NetworkAccessLocation) {
                $validLocations = Get-RBAC4AppLocationList
                $matchedLocation = $validLocations | Where-Object { $_ -ieq $NetworkAccessLocation } | Select-Object -First 1
                if (-not $matchedLocation) {
                    throw "Invalid -NetworkAccessLocation '$NetworkAccessLocation'. Valid locations: $($validLocations -join ', ')"
                }
                $NetworkAccessLocation = $matchedLocation
            }
            $assignmentScopeInfo = Resolve-RBAC4AppAssignmentScope -ScopeKind $ScopeKind -AssignmentScope $AssignmentScope -BoundParameters $boundParameters
            $AssignmentScope = $assignmentScopeInfo.AssignmentScope
            foreach ($ignoredMsg in @($assignmentScopeInfo.Warnings)) {
                Write-Warning -Message $ignoredMsg
                $collectedWarnings.Add([string]$ignoredMsg)
            }
            foreach ($ignoredMsg in @(Get-RBAC4AppScopeKindWarning -ScopeKind $ScopeKind -BoundParameters $boundParameters)) {
                Write-Warning -Message $ignoredMsg
                $collectedWarnings.Add([string]$ignoredMsg)
            }

            $AccessGroupType = ConvertTo-RBAC4AppAccessGroupType -AccessGroupType $AccessGroupType
            if (-not $boundParameters.ContainsKey('GroupPrefix') -and -not $GroupPrefix) {
                $GroupPrefix = Get-RBAC4AppDefaultGroupPrefix -AccessGroupType $AccessGroupType
            }

            # --- Send restriction pre-check (Graph session: the owner cannot be resolved in Exchange
            # here). A group Invoke-RBAC4AppConfig will create is restricted to its -ManagedBy owner(s);
            # with the default placeholder owner that only works if it exists as an EXO recipient.
            $effectiveOwners = @($ManagedBy | Where-Object { $_ })
            if ($ScopeKind -eq 'Group' -and $AccessGroupType -in $script:RBAC4AppCreatableGroupTypes -and
                ($effectiveOwners.Count -eq 0 -or @($effectiveOwners | Where-Object { $_ -ne $script:RBAC4AppDefaultOwner }).Count -eq 0)) {
                $ownerMsg = "ManagedBy is the default owner '$($script:RBAC4AppDefaultOwner)'. Invoke-RBAC4AppConfig restricts the $AccessGroupType it creates so only the owner can send to it; if '$($script:RBAC4AppDefaultOwner)' does not exist as an Exchange Online recipient, the send restriction is skipped (only sender authentication is required). Create that recipient or pass -ManagedBy."
                Write-Warning -Message $ownerMsg
                $collectedWarnings.Add($ownerMsg)
            }
        }
        if (-not $Repository) { . $validateSettings }

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

        # --- Fill settings not given on the command line from the application's state file
        $state = $null
        if ($Repository) {
            try {
                $state = Get-RBAC4AppRepositoryState -Repository $Repository -AppId ([string]$sp.AppId)
                if ($state) {
                    $scopeKindChanged = $PSBoundParameters.ContainsKey('ScopeKind') -and $ScopeKind -ne $state.RbacScope.ScopeKind
                    $groupTypeChanged = $PSBoundParameters.ContainsKey('AccessGroupType') -and $AccessGroupType -ne $state.RbacScope.AccessGroupType
                    $stateScope = $state.RbacScope
                    $stateMetadata = $state.Metadata

                    $stateValues = @{
                        Role                        = @($state.Rbac.Roles)
                        ChangeReference             = $state.Metadata.ChangeReference
                        AccessGroupType             = $stateScope.AccessGroupType
                        ManagedBy                   = @($stateScope.ManagedBy)
                        ScopeKind                   = $stateScope.ScopeKind
                        ScopeRecipients             = @($stateScope.ScopeRecipients)
                        ScopeTagAttribute           = $stateScope.ScopeTagAttribute
                        ScopeTagValue               = $stateScope.ScopeTagValue
                        ScopeFilter                 = $stateScope.ScopeFilter
                        OwnerUsername               = $stateMetadata.OwnerUsername
                        OwnerDisplayName            = $stateMetadata.OwnerDisplayName
                        TechnicalContactUsername    = $stateMetadata.TechnicalContactUsername
                        TechnicalContactDisplayName = $stateMetadata.TechnicalContactDisplayName
                        PCode                       = $stateMetadata.PCode
                        CmdbId                      = $stateMetadata.CmdbId
                        Description                 = $stateMetadata.Description
                        NetworkAccessIP4Range       = $stateMetadata.NetworkAccessIP4Range
                        NetworkAccessIP6Range       = $stateMetadata.NetworkAccessIP6Range
                        NetworkAccessLocation       = $stateMetadata.NetworkAccessLocation
                    }
                    if (-not $scopeKindChanged) { $stateValues.AssignmentScope = $stateScope.AssignmentScope }
                    if (-not $groupTypeChanged) {
                        if (-not $PSBoundParameters.ContainsKey('GroupPrefix')) { $stateValues.AccessGroupName = $stateScope.AccessGroupName }
                        if (-not $PSBoundParameters.ContainsKey('AccessGroupName')) { $stateValues.GroupPrefix = $stateScope.GroupPrefix }
                    }
                    if (-not $PSBoundParameters.ContainsKey('ManagementScopePrefix')) { $stateValues.ManagementScopeName = $stateScope.ManagementScopeName }
                    if (-not $PSBoundParameters.ContainsKey('ManagementScopeName')) { $stateValues.ManagementScopePrefix = $stateScope.ManagementScopePrefix }

                    # Assigning re-runs each parameter's validation attributes, so a hand-edited bad
                    # value fails here. Empty values are skipped: they mean "not in the state file".
                    foreach ($name in $stateValues.Keys) {
                        if (-not $PSBoundParameters.ContainsKey($name) -and $stateValues[$name]) {
                            Set-Variable -Name $name -Value $stateValues[$name]
                        }
                    }
                    # An empty Members list or BootstrapMember in a state file is an explicit override.
                    if (-not $PSBoundParameters.ContainsKey('Members')) { $Members = @($stateScope.Members) }
                    if (-not $PSBoundParameters.ContainsKey('BootstrapMember')) { $BootstrapMember = $stateScope.BootstrapMember }
                    if (-not $PSBoundParameters.ContainsKey('SeparateScopePerRole') -and -not $scopeKindChanged -and $stateScope.SeparateScopePerRole) {
                        $SeparateScopePerRole = [switch]$true
                    }
                }
                else {
                    $noStateMsg = "No state file for AppId '$($sp.AppId)' in repository '$Repository'; using command line values and defaults."
                    Write-Warning -Message $noStateMsg
                    $collectedWarnings.Add($noStateMsg)
                }
            }
            catch {
                Write-Error "Could not use the state file for AppId '$($sp.AppId)' in repository '$Repository': $($_.Exception.Message)"
                return
            }
            . $validateSettings
        }

        # --- Tenant context (informational; graceful if Graph connection lacks permissions)
        $tenantId = ''
        try { $tenantId = (Get-MgContext -ErrorAction Stop).TenantId } catch { Write-Verbose "TenantId unavailable: $($_.Exception.Message)" }

        # --- Normalise roles
        $normalizedRoles = @(foreach ($r in @($Role)) { ConvertTo-RBAC4AppRoleName -Role $r })

        # --- Build config object
        $accessGroupNameValue = if ($AccessGroupName) {
            $AccessGroupName
        }
        elseif ($AccessGroupType -eq 'HybridMailEnabledSecurityGroup') {
            ''
        }
        else {
            Get-RBAC4AppScopeGroupName -Prefix $GroupPrefix -DisplayName $sp.DisplayName -AppId $sp.AppId
        }

        $config = ConvertTo-RBAC4AppConfig `
            -TenantId $tenantId `
            -AppId ([string]$sp.AppId) -SpObjectId ([string]$sp.Id) -DisplayName ([string]$sp.DisplayName) `
            -Roles $normalizedRoles `
            -ChangeReference $ChangeReference `
            -AccessGroupType $AccessGroupType -GroupPrefix $GroupPrefix -AccessGroupName $accessGroupNameValue `
            -Members $Members -MembersExplicit ($PSBoundParameters.ContainsKey('Members') -or [bool]$state) `
            -ManagedBy $ManagedBy -BootstrapMember $BootstrapMember `
            -BootstrapMemberExplicit ($PSBoundParameters.ContainsKey('BootstrapMember') -or [bool]$state) `
            -ScopeKind $ScopeKind -AssignmentScope $AssignmentScope `
            -ManagementScopeName $ManagementScopeName `
            -ManagementScopePrefix $ManagementScopePrefix `
            -ScopeRecipients $ScopeRecipients -ScopeTagAttribute $ScopeTagAttribute `
            -ScopeTagValue $(if ($ScopeTagValue) { $ScopeTagValue } else { '' }) `
            -ScopeFilter $(if ($ScopeFilter) { $ScopeFilter } else { '' }) `
            -SeparateScopePerRole ([bool]$SeparateScopePerRole) `
            -OwnerUsername $OwnerUsername -OwnerDisplayName $OwnerDisplayName `
            -TechnicalContactUsername $TechnicalContactUsername -TechnicalContactDisplayName $TechnicalContactDisplayName `
            -PCode $PCode -CmdbId $CmdbId -Description $Description `
            -NetworkAccessIP4Range $NetworkAccessIP4Range -NetworkAccessIP6Range $NetworkAccessIP6Range `
            -NetworkAccessLocation $NetworkAccessLocation `
            -CollectedWarnings @($collectedWarnings)

        # --- Microsoft365DSC rendering (-Format M365DSC): written next to the YAML config. Its notes
        # (what DSC does differently from Invoke-RBAC4AppConfig) also go into the config's warnings.
        $dscScript = $null
        if ($Format -eq 'M365DSC') {
            try { $dsc = ConvertTo-RBAC4AppM365Dsc -Config $config -Authentication $DscAuthentication }
            catch {
                Write-Error "Could not render the Microsoft365DSC configuration: $($_.Exception.Message)"
                return
            }
            foreach ($dscWarning in $dsc.Warnings) {
                Write-Warning -Message $dscWarning
                $collectedWarnings.Add([string]$dscWarning)
            }
            $config.Runtime.CollectedWarnings = @($collectedWarnings)
            $dscScript = $dsc.Script
        }

        # --- Write config file (YAML or JSON, per -Format; YAML for M365DSC)
        $extension = if ($Format -eq 'Json') { 'json' } else { 'yml' }
        $safeName  = Format-RBAC4AppSafeName -Value $sp.DisplayName -MaxLength 40
        # Seconds plus a short random id keep two configs for the same app from overwriting each other.
        $timestamp = (Get-Date).ToString('yyyyMMddHHmmss')
        $uniqueId  = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $fileName  = "rbac4app-$safeName-$timestamp-$uniqueId.$extension"
        $outFile   = Join-Path $OutputPath $fileName

        $serialized = if ($Format -eq 'Json') { $config | ConvertTo-Json -Depth 6 } else { ConvertTo-RBAC4AppYaml -Config $config }
        Write-Verbose ("Config {0}:`n{1}" -f $Format, $serialized)

        if ($PSCmdlet.ShouldProcess($outFile, "Write RBAC4App config ($Format)")) {
            [System.IO.File]::WriteAllText($outFile, $serialized, [System.Text.Encoding]::UTF8)
            Write-Verbose "Config written to '$outFile'."
            $outFile
            if ($dscScript) {
                $dscFile = [System.IO.Path]::ChangeExtension($outFile, '.ps1')
                [System.IO.File]::WriteAllText($dscFile, $dscScript, [System.Text.Encoding]::UTF8)
                Write-Verbose "Microsoft365DSC configuration written to '$dscFile'."
                $dscFile
            }
        }
    }
}
