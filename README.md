# EXORBACforAppManagement

A PowerShell module for governing **Exchange Online (EXO) Role-Based Access Control for Entra
(Azure AD) applications**. It registers applications, assigns resource-scoped EXO *Application*
role permissions (e.g. `Application Mail.Send`) bound either directly to a **scope group** (the
default) or to a named Exchange Online **management scope** (built from a scope group's members, an
explicit mailbox list, a CustomAttribute tag, or a raw OPATH filter), and reads those
assignments back.

The three functions form a **create → assign → read** flow and share the same
`ByName` / `ByAppId` / `BySpObjectId` parameter conventions, so they compose over the pipeline.

| Function | Step | What it does |
| --- | --- | --- |
| [`New-RegisteredApp`](#new-registeredapp) | create | Creates an Entra app registration and (by default) its service principal. NOTE: requires high privileges; intended mainly for testing environments when production app registration is handled by a separate pipeline/team. |
| [`New-RBAC4AppEntry`](#new-rbac4appentry) | assign | Ensures the scope source (group, recipients, tag, or filter), the EXO service principal, and assigns EXO Application roles bound directly to the group (default) or to a management scope (`-AssignmentScope ManagementScope`, and every non-Group kind). |
| `New-RBAC4AppManagementScope` | helper | Ensures an EXO management scope exists with a given `RecipientRestrictionFilter` (creates, updates on drift, or leaves an equivalent one alone; `-NoUpdate` only warns). |
| [`Get-RBAC4AppEntry`](#get-rbac4appentry) | read / inventory | Lists the EXO Application-role assignments, each resolved to its AppId/ServicePrincipalId and scope group name/type/members (one `RBAC4App.Entry` row per assignment). |
| [`Get-RBAC4AppApplication`](#get-rbac4appapplication) | read / inventory | Groups `Get-RBAC4AppEntry` rows into one row per application (assignee), or fetches them itself. |
| [`Export-RBAC4AppConfig`](#export-rbac4appconfig) | export | Writes `Get-RBAC4AppEntry` rows as YAML/JSON configs for `Invoke-RBAC4AppConfig`; refuses guessed data without `-Force`. |
| [`Test-RBAC4AppEntry`](#test-rbac4appentry) | validate | Checks an application has every component `New-RBAC4AppEntry` creates (SP, scope source, management scope when `-AssignmentScope ManagementScope`, EXO service principal, role assignments) and returns an `IsValid` summary. |
| [`Convert-ApplicationAccessPolicyToRBAC`](#convert-applicationaccesspolicytorbac) | migrate / plan | Writes YAML/JSON RBAC configs from legacy Application Access Policies for later provisioning with `Invoke-RBAC4AppConfig`. |
| [`New-RBAC4AppUnifiedGroup`](#new-rbac4appunifiedgroup) | helper | Ensures/creates and configures the scoped Unified Group (used by `New-RBAC4AppEntry` when `-AccessGroupType M365Group`). |
| `New-RBAC4AppDistributionGroup` | helper | Ensures/creates and configures a scoped Exchange-Online-only mail-enabled security group (`-GroupType Security`, default) or distribution list (`-GroupType Distribution`), restricted so only its owners can send to it (used by `New-RBAC4AppEntry` for `-AccessGroupType CloudMailEnabledSecurityGroup` / `DistributionList`). |
| [`Register-EXOServicePrincipal`](#register-exoserviceprincipal) | helper | Creates the EXO service principal pointer for an Entra app (used by `New-RBAC4AppEntry`). |
| [`New-RBAC4AppConfig`](#new-rbac4appconfig) | **Graph session** | Resolves the Entra SP via `Get-MgServicePrincipal` and writes a YAML or JSON config file (`-Format`) for `Invoke-RBAC4AppConfig`. No EXO calls. |
| [`Invoke-RBAC4AppConfig`](#invoke-rbac4appconfig) | **EXO session** | Reads the config (YAML or JSON, auto-detected from the extension) and provisions scope group, EXO service principal, and role assignments. No Graph calls. |

> Background: [Microsoft Learn — Role Based Access Control for Applications in Exchange Online](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac).

## Public functions and parameters

Every exported function with all of its own parameters (the PowerShell common parameters such as
`-Verbose`, `-ErrorAction`, or `-WarningVariable` are accepted everywhere and not listed).
**Bold** parameters are mandatory - in the named parameter set only, when one is given.
`{A|B}` lists the accepted values; switches have no type. Run `Get-Help <Function> -Full` for
descriptions, defaults, and aliases.

| Function | Parameter sets | Parameters | `-WhatIf` / `-Confirm` |
| --- | --- | --- | --- |
| [`Convert-ApplicationAccessPolicyToRBAC`](#convert-applicationaccesspolicytorbac) | All, ByAppId, ByPolicy | `-AppId <string>`<br>`-Policy <object[]>`<br>`-Role <string[]>`<br>`-ManagedBy <string[]>`<br>`-GroupPrefix <string>`<br>`-AccessGroupType {M365Group\|DistributionList}`<br>`-OutputPath <string>`<br>`-Format {Yaml\|Json\|M365DSC}`<br>`-DscAuthentication {ManagedIdentity\|Certificate}` | yes |
| [`Get-RBAC4AppEntry`](#get-rbac4appentry) | All, ByName, ByAppId, BySpObjectId | **`-RegisteredAppName <string>`** (required in ByName)<br>**`-AppId <string>`** (required in ByAppId)<br>**`-SpObjectId <string>`** (required in BySpObjectId)<br>`-Role <string[]>`<br>`-Enabled <bool>`<br>`-RoleAssigneeType {All\|ServicePrincipal\|User\|SecurityGroup\|RoleGroup\|RoleAssignmentPolicy\|ForeignSecurityPrincipal\|LinkedRoleGroup\|Computer}`<br>`-ScopeType <string[]>` (RecipientWriteScope values, or `All`) | yes |
| [`Get-RBAC4AppApplication`](#get-rbac4appapplication) | FromEntry, All, ByName, ByAppId, BySpObjectId | **`-InputObject <RBAC4App.Entry[]>`** (pipeline, FromEntry)<br>plus the `Get-RBAC4AppEntry` identity and filter parameters | yes |
| [`Export-RBAC4AppConfig`](#export-rbac4appconfig) | — | **`-InputObject <RBAC4App.Entry[]>`** (pipeline)<br>`-Path <string>`<br>`-Format {Yaml\|Json\|M365DSC}`<br>`-DscAuthentication {ManagedIdentity\|Certificate}`<br>`-PerApplication`<br>`-PassThru`<br>`-Force` | yes |
| [`Invoke-RBAC4AppConfig`](#invoke-rbac4appconfig) | — | **`-Path <string>`**<br>`-Format {Auto\|Yaml\|Json}` | yes |
| [`New-RBAC4AppConfig`](#new-rbac4appconfig) | ByName, ByAppId, BySpObjectId | **`-RegisteredAppName <string>`** (required in ByName)<br>**`-AppId <string>`** (required in ByAppId)<br>**`-SpObjectId <string>`** (required in BySpObjectId)<br>`-Role <string[]>`<br>`-AccessGroupType {CloudMailEnabledSecurityGroup\|DistributionList\|M365Group\|HybridMailEnabledSecurityGroup}`<br>`-GroupPrefix <string>`<br>`-AccessGroupName <string>`<br>`-Members <string[]>`<br>`-ManagedBy <string[]>`<br>`-BootstrapMember <string>`<br>`-ScopeKind {Group\|Recipients\|Tag\|Filter}`<br>`-AssignmentScope {RecipientGroupScope\|ManagementScope}`<br>`-ManagementScopeName <string>`<br>`-ManagementScopePrefix <string>`<br>`-ScopeRecipients <string[]>`<br>`-ScopeTagAttribute <string>`<br>`-ScopeTagValue <string>`<br>`-ScopeFilter <string>`<br>`-SeparateScopePerRole`<br>`-ChangeReference <string>`<br>`-OwnerUsername <string>`<br>`-OwnerDisplayName <string>`<br>`-TechnicalContactUsername <string>`<br>`-TechnicalContactDisplayName <string>`<br>`-PCode <string>`<br>`-CmdbId <string>`<br>`-Description <string>`<br>`-NetworkAccessIP4Range <string>`<br>`-NetworkAccessIP6Range <string>`<br>`-NetworkAccessLocation <string>`<br>`-Repository <string>`<br>`-OutputPath <string>`<br>`-Format {Yaml\|Json\|M365DSC}`<br>`-DscAuthentication {ManagedIdentity\|Certificate}` | yes |
| `New-RBAC4AppDistributionGroup` | ByAppName, ByName | **`-AppName <string>`** (required in ByAppName)<br>`-Prefix <string>`<br>**`-Name <string>`** (required in ByName)<br>`-DisplayName <string>`<br>`-ManagedBy <string[]>`<br>`-BootstrapMember <string>`<br>`-ChangeReference <string>` | yes |
| [`New-RBAC4AppEntry`](#new-rbac4appentry) | — | `-RegisteredAppName <string>`<br>`-AppId <string>`<br>`-SpObjectId <string>`<br>`-Members <string[]>`<br>`-Role <string[]>`<br>`-ManagedBy <string[]>`<br>`-GroupPrefix <string>`<br>`-AccessGroupName <string>`<br>`-AccessGroupType {CloudMailEnabledSecurityGroup\|DistributionList\|M365Group\|HybridMailEnabledSecurityGroup}`<br>`-BootstrapMember <string>`<br>`-ScopeKind {Group\|Recipients\|Tag\|Filter}`<br>`-AssignmentScope {RecipientGroupScope\|ManagementScope}`<br>`-ManagementScopeName <string>`<br>`-ManagementScopePrefix <string>`<br>`-ScopeRecipients <string[]>`<br>`-ScopeTagAttribute <string>`<br>`-ScopeTagValue <string>`<br>`-ScopeFilter <string>`<br>`-ChangeReference <string>` | yes |
| `New-RBAC4AppManagementScope` | — | **`-Name <string>`**<br>**`-RecipientRestrictionFilter <string>`**<br>`-NoUpdate` | yes |
| [`New-RBAC4AppUnifiedGroup`](#new-rbac4appunifiedgroup) | — | **`-Name <string>`**<br>`-DisplayName <string>`<br>`-ManagedBy <string[]>`<br>`-BootstrapMember <string>`<br>`-ChangeReference <string>` | yes |
| [`New-RegisteredApp`](#new-registeredapp) | — | **`-DisplayName <string>`**<br>`-SignInAudience {AzureADMyOrg\|AzureADMultipleOrgs\|AzureADandPersonalMicrosoftAccount\|PersonalMicrosoftAccount}`<br>`-RedirectUri <string[]>`<br>`-Description <string>`<br>`-RequiredResourceAccess <object[]>`<br>`-SkipServicePrincipal` | yes |
| [`Register-EXOServicePrincipal`](#register-exoserviceprincipal) | — | **`-AppId <string>`**<br>**`-ObjectId <string>`**<br>**`-DisplayName <string>`** | yes |
| `Remove-RBAC4AppEntry` | ByName, ByAppId, BySpObjectId | **`-RegisteredAppName <string>`** (required in ByName)<br>**`-AppId <string>`** (required in ByAppId)<br>**`-SpObjectId <string>`** (required in BySpObjectId)<br>`-GroupPrefix <string>`<br>`-AccessGroupName <string>`<br>`-AccessGroupType {CloudMailEnabledSecurityGroup\|DistributionList\|M365Group\|HybridMailEnabledSecurityGroup}`<br>`-BootstrapMember <string>`<br>`-ScopeKind {Group\|Recipients\|Tag\|Filter}`<br>`-ManagementScopeName <string>`<br>`-ManagementScopePrefix <string>` | yes |
| `Set-RBAC4AppEntry` | — | `-RegisteredAppName <string>`<br>`-AppId <string>`<br>`-SpObjectId <string>`<br>`-Role <string[]>`<br>`-Members <string[]>`<br>`-ManagedBy <string[]>`<br>`-GroupPrefix <string>`<br>`-AccessGroupName <string>`<br>`-AccessGroupType {CloudMailEnabledSecurityGroup\|DistributionList\|M365Group\|HybridMailEnabledSecurityGroup}`<br>`-BootstrapMember <string>`<br>`-NewGroupPrefix <string>`<br>`-NewGroupName <string>`<br>`-ScopeKind {Group\|Recipients\|Tag\|Filter}`<br>`-AssignmentScope {RecipientGroupScope\|ManagementScope}`<br>`-ManagementScopeName <string>`<br>`-ManagementScopePrefix <string>`<br>`-ScopeRecipients <string[]>`<br>`-ScopeTagAttribute <string>`<br>`-ScopeTagValue <string>`<br>`-ScopeFilter <string>`<br>`-ChangeReference <string>` | yes |
| [`Test-RBAC4AppEntry`](#test-rbac4appentry) | ByName, ByAppId, BySpObjectId | **`-RegisteredAppName <string>`** (required in ByName)<br>**`-AppId <string>`** (required in ByAppId)<br>**`-SpObjectId <string>`** (required in BySpObjectId)<br>`-Role <string[]>`<br>`-Members <string[]>`<br>`-GroupPrefix <string>`<br>`-AccessGroupName <string>`<br>`-AccessGroupType {CloudMailEnabledSecurityGroup\|DistributionList\|M365Group\|HybridMailEnabledSecurityGroup}`<br>`-ScopeKind {Group\|Recipients\|Tag\|Filter}`<br>`-AssignmentScope {RecipientGroupScope\|ManagementScope}`<br>`-ManagementScopeName <string>`<br>`-ManagementScopePrefix <string>`<br>`-ScopeRecipients <string[]>`<br>`-ScopeTagAttribute <string>`<br>`-ScopeTagValue <string>`<br>`-ScopeFilter <string>` | — |

`New-RBAC4AppEntry` and `Set-RBAC4AppEntry` take the application as `-RegisteredAppName`, `-AppId`,
or `-SpObjectId` (at least one; all three together bootstrap a new Exchange Online service
principal pointer), so none of the three is mandatory on its own.

## Requirements

- **PowerShell 5.1+** for the module and build script (developed/tested on PowerShell 7).
- The following modules installed and **connected** at runtime (they are intentionally *not*
  declared as `RequiredModules`, so the module imports without them for unit testing):
  - **Microsoft Graph** — `Connect-MgGraph`. Needed by three public functions: `New-RegisteredApp`
    (`New-MgApplication`, `New-MgServicePrincipal`, `Get-MgContext`; needs the
    `Application.ReadWrite.All` scope), `New-RBAC4AppConfig` (`Get-MgServicePrincipal`,
    `Get-MgContext`), and `Convert-ApplicationAccessPolicyToRBAC` (`Get-MgServicePrincipal`,
    `Get-MgServicePrincipalAppRoleAssignment`).
  - **Exchange Online** — `Connect-ExchangeOnline`. Needed by every other function, including
    `New-RBAC4AppEntry` itself: `Get-ServicePrincipal` resolves the application (matching the
    pointer `Register-EXOServicePrincipal` creates — no Graph lookup), `Get-ConnectionInformation`
    reads the tenant id / current user, plus the usual `Get-UnifiedGroup`, `New-UnifiedGroup`,
    `Set-UnifiedGroup`, `Add-UnifiedGroupLinks`, `New-ServicePrincipal`, `Get-Recipient`, `Get-ManagementScope`, `New-ManagementScope`, `Set-ManagementScope`, `Remove-ManagementScope`,
    `New-ManagementRoleAssignment`, `Get-ManagementRoleAssignment`.

### Per-function module requirements

Only three public functions touch Microsoft Graph at all. Every other function — including
`New-RBAC4AppEntry` itself — resolves the application purely through Exchange Online's own service
principal pointer (`Get-ServicePrincipal`, matching what `Register-EXOServicePrincipal` creates) and
needs no Graph session, working around the MSAL/WAM assembly conflict between `Microsoft.Graph` and
`ExchangeOnlineManagement` in one process.

| Function | Microsoft.Graph | ExchangeOnlineManagement |
| --- | --- | --- |
| `New-RegisteredApp` | `New-MgApplication` `New-MgServicePrincipal` `Get-MgContext` | — |
| `New-RBAC4AppConfig` | `Get-MgServicePrincipal` `Get-MgContext` | — |
| `New-RBAC4AppUnifiedGroup` | — | `Get-UnifiedGroup` `New-UnifiedGroup` `Set-UnifiedGroup` `Get-Recipient` `Get-ConnectionInformation` *(debug trace only)* |
| `New-RBAC4AppDistributionGroup` | — | `Get-DistributionGroup` `New-DistributionGroup` `Set-DistributionGroup` `Get-Recipient` |
| `New-RBAC4AppManagementScope` | — | `Get-ManagementScope` `New-ManagementScope` `Set-ManagementScope` |
| `Register-EXOServicePrincipal` | — | `Get-ServicePrincipal` `New-ServicePrincipal` *(skips creation if one already matches by AppId/DisplayName)* |
| `New-RBAC4AppEntry` | — | `Get-ServicePrincipal` `Get-ConnectionInformation` `Get-Recipient` `Add-DistributionGroupMember` `Get-UnifiedGroupLinks`/`Get-DistributionGroupMember` `Get-ManagementScope` `New-ManagementScope` `Set-ManagementScope` `Get-ManagementRoleAssignment` `New-ManagementRoleAssignment` *(resolves the app via `Get-ServicePrincipal`, or bootstraps a never-before-registered pointer when `-AppId`, `-SpObjectId`, and `-RegisteredAppName` are all supplied; skips a role assignment already scoped to the target management scope; + delegates to scope-group helpers and `Register-EXOServicePrincipal`)* |
| `Set-RBAC4AppEntry` | — | `Get-ServicePrincipal` `Get-ConnectionInformation` `Get-UnifiedGroup`/`Get-DistributionGroup`/`Get-Recipient` `Get-UnifiedGroupLinks`/`Get-DistributionGroupMember` `Add-DistributionGroupMember` `Get-ManagementRoleAssignment` `New-ManagementRoleAssignment` `Remove-ManagementRoleAssignment` *(same bootstrap fallback as `New-RBAC4AppEntry` when the pointer doesn't exist yet)* |
| `Test-RBAC4AppEntry` | — | `Get-ServicePrincipal` `Get-ConnectionInformation` `Get-UnifiedGroup`/`Get-DistributionGroup`/`Get-Recipient` `Get-ManagementRoleAssignment` `Get-UnifiedGroupLinks`/`Get-DistributionGroupMember` |
| `Remove-RBAC4AppEntry` | — | `Get-ServicePrincipal` `Get-ConnectionInformation` `Get-UnifiedGroup`/`Get-DistributionGroup`/`Get-Recipient` `Get-ManagementRoleAssignment` `Get-UnifiedGroupLinks`/`Get-DistributionGroupMember` `Remove-ManagementRoleAssignment` `Remove-UnifiedGroup`/`Remove-DistributionGroup` |
| `Get-RBAC4AppEntry` | — | `Get-ServicePrincipal` `Get-ManagementRoleAssignment` `Get-UnifiedGroup`/`Get-DistributionGroup` `Get-UnifiedGroupLinks`/`Get-DistributionGroupMember` `Get-ManagementScope` `Get-Recipient` *(resolves the assignee to AppId/ServicePrincipalId via `Get-ServicePrincipal`, and each management scope to its `ScopeKind`/`ScopeFilter` and members - group membership for Group kind, the listed recipients for Recipients kind, a `Get-Recipient -RecipientPreviewFilter` preview for Tag/Filter kinds; legacy group-direct assignments report `ScopeKind` `GroupDirect`; cached per run)* |
| `Get-RBAC4AppApplication` | — | same as `Get-RBAC4AppEntry` when it fetches the rows itself; none for piped rows |
| `Export-RBAC4AppConfig` | — | — *(works only from piped `Get-RBAC4AppEntry` rows; writes config files)* |
| `Convert-ApplicationAccessPolicyToRBAC` | `Get-MgServicePrincipal` `Get-MgServicePrincipalAppRoleAssignment` `Get-MgContext` | `Get-ApplicationAccessPolicy` *(read-only; writes config files, does not provision RBAC)* |
| `Invoke-RBAC4AppConfig` | — | `Get-ServicePrincipal` `Get-Recipient` `Add-DistributionGroupMember` `Get-UnifiedGroupLinks`/`Get-DistributionGroupMember` `Get-ManagementRoleAssignment` `New-ManagementRoleAssignment` *(+ delegates to scope-group helpers and `Register-EXOServicePrincipal`, same as `New-RBAC4AppEntry`)* |

## Two-session workflow

Microsoft.Graph and ExchangeOnlineManagement share MSAL/WAM identity assemblies that can
conflict when both are loaded in the same PowerShell process — symptoms range from
`RuntimeBroker` / WAM `NullReferenceException` on `Connect-ExchangeOnline` to
`Method not found` on `Connect-MgGraph`. As of the per-function table above, only
`New-RegisteredApp`, `New-RBAC4AppConfig`, and `Convert-ApplicationAccessPolicyToRBAC` ever touch
Graph — every other function, including `New-RBAC4AppEntry` itself, is Exchange-Online-only and
never hits the conflict in the first place. `New-RBAC4AppConfig` / `Invoke-RBAC4AppConfig` remain
useful specifically for provisioning a **brand-new** application (one with no Exchange Online
service principal pointer yet) split cleanly across two sessions.

> **Same-session warning:** even if a particular module combination appears to work in one
> PowerShell process (for example ExchangeOnlineManagement 3.10.1 with Microsoft.Graph 2.41.1),
> treat that as opportunistic rather than supported. The shared identity assemblies can still break
> after module upgrades, authentication mode changes, token refreshes, or load-order changes. For
> repeatable production runs, keep Graph work and Exchange Online work in separate `pwsh` sessions.

### What to do in each session

| | Session 1 — Microsoft Graph | Session 2 — ExchangeOnlineManagement |
| --- | --- | --- |
| **Connect** | `Connect-MgGraph -Scopes 'Application.ReadWrite.All'` | `Connect-ExchangeOnline` |
| **App registration** | `New-RegisteredApp` | — |
| **Plan RBAC config** | `New-RBAC4AppConfig` → writes `.yml` (or `.json` with `-Format Json`) | — |
| **Provision from config** | — | `Invoke-RBAC4AppConfig -Path .\config.yml` (format auto-detected from the extension) |
| **Everything else** | — | `New-RBAC4AppEntry` `Set-RBAC4AppEntry` `Test-RBAC4AppEntry` `Remove-RBAC4AppEntry` `Get-RBAC4AppEntry` `Get-RBAC4AppApplication` `Export-RBAC4AppConfig` `New-RBAC4AppUnifiedGroup` `New-RBAC4AppDistributionGroup` `Register-EXOServicePrincipal` |

For a never-before-registered application, `New-RBAC4AppEntry` and `Set-RBAC4AppEntry` can also
bootstrap the Exchange Online service principal pointer directly in one Exchange-Online-only
session — supply `-AppId`, `-SpObjectId`, and `-RegisteredAppName` together (see
[`New-RBAC4AppEntry`](#new-rbac4appentry)) — as an alternative to the two-session config workflow.
`Convert-ApplicationAccessPolicyToRBAC` still requires Graph and Exchange Online read access to
collect permission grants and policies. It only writes config files (reusing each policy's existing
scope group);
run `Invoke-RBAC4AppConfig` separately in an Exchange-Online-only session to provision RBAC.

### Typical two-session flow

```powershell
# ── Session 1: pwsh window with Microsoft.Graph connected ────────────────────
Connect-MgGraph -Scopes 'Application.ReadWrite.All'

# Optionally register the app (if not already registered):
New-RegisteredApp -DisplayName 'Contoso Mail App' -WhatIf

# Resolve the SP and write the handoff config (YAML by default):
$yml = New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' `
           -Role 'Mail.Send' `
           -Members 'shared@contoso.com' `
           -OutputPath C:\rbac-configs
# → writes C:\rbac-configs\rbac4app-ContosoMailApp-<timestamp>-<id>.yml

# Or write JSON instead:
# $json = New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' -Role 'Mail.Send' `
#            -Members 'shared@contoso.com' -Format Json -OutputPath C:\rbac-configs

# ── Session 2: separate pwsh window with ExchangeOnlineManagement connected ──
Connect-ExchangeOnline

# Preview first:
Invoke-RBAC4AppConfig -Path C:\rbac-configs\rbac4app-ContosoMailApp-*.yml -WhatIf

# Provision:
Invoke-RBAC4AppConfig -Path C:\rbac-configs\rbac4app-ContosoMailApp-*.yml
```

The config file is a plain-text handoff — no secrets, safe to store alongside your runbooks.
`Invoke-RBAC4AppConfig` auto-detects YAML vs. JSON from the file extension (`.yml`/`.yaml` vs
`.json`); pass `-Format` to override that when a file's extension doesn't match its content.

### YAML config schema

The same schema applies verbatim to the JSON format (see
[New-RBAC4AppConfig](#new-rbac4appconfig) for a JSON example) — only the serialization differs.

Generated files contain **only the entries that are actually used**: keys the selected `ScopeKind` /
`AssignmentScope` ignores, empty values, and values equal to their default are left out, and
`Invoke-RBAC4AppConfig` fills every missing key back in from the same defaults. `SchemaVersion`,
`Application`, `Rbac.Roles`, `Metadata`, and `Runtime` (including `GeneratedAt`) are always written. A default
`New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' -Members 'shared@contoso.com'` writes:

```yaml
# RBAC4App configuration — generated by New-RBAC4AppConfig
# Feed to Invoke-RBAC4AppConfig in a session with only ExchangeOnlineManagement connected.
SchemaVersion: "4.4"

Application:
  AppId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  SpObjectId: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
  DisplayName: "Contoso Mail App"
  TenantId: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

Rbac:
  Roles:
    - "Application Mail.Send"

RbacScope:
  AccessGroupName: "UDLRAo1P-ContosoMailApp"
  Members:
    - "shared@contoso.com"
```

Every key and the value it takes when absent:

| Key | Used when | Default when absent |
| --- | --- | --- |
| `Application.TenantId` | always (informational) | `""` |
| `Metadata.ChangeReference` | always | `""` (no change record) |
| `RbacScope.ScopeKind` | always | `Group` (`Recipients` / `Tag` / `Filter`) |
| `RbacScope.AssignmentScope` | `ScopeKind: Group` | `RecipientGroupScope` for schema `4.1` or later; `ManagementScope` for `4.0`/`3.0` and every non-Group kind |
| `RbacScope.AccessGroupType` | `ScopeKind: Group` | `CloudMailEnabledSecurityGroup` (`DistributionList` / `M365Group` / `HybridMailEnabledSecurityGroup`); absent in a pre-4.4 file means `DistributionList` |
| `RbacScope.AccessGroupName` | `ScopeKind: Group` | generated `"{GroupPrefix}-{DisplayName}"`; required for `HybridMailEnabledSecurityGroup` |
| `RbacScope.GroupPrefix` | `ScopeKind: Group` without `AccessGroupName` | `USRACo1P` / `UDLRAo1P` / `Um365RAo1P` / `USRAHo1P` per `AccessGroupType` |
| `RbacScope.Members` | `ScopeKind: Group` | `[GraphAPI-Dummy]` |
| `RbacScope.ManagedBy` | `ScopeKind: Group` | `[GraphAPI-Dummy-owner]` |
| `RbacScope.BootstrapMember` | `ScopeKind: Group` | `GraphAPI-Dummy` |
| `RbacScope.SeparateScopePerRole` | `ScopeKind: Group` | `false` |
| `RbacScope.ManagementScopeName` | `AssignmentScope: ManagementScope` | generated `"{ManagementScopePrefix}-{DisplayName}"` |
| `RbacScope.ManagementScopePrefix` | `AssignmentScope: ManagementScope` without `ManagementScopeName` | `MSRAo1P` |
| `RbacScope.ScopeRecipients` | `ScopeKind: Recipients` (required) | — |
| `RbacScope.ScopeTagAttribute` | `ScopeKind: Tag` | `CustomAttribute1` |
| `RbacScope.ScopeTagValue` | `ScopeKind: Tag` | the management scope name |
| `RbacScope.ScopeFilter` | `ScopeKind: Filter` (required) | — |
| `Metadata.OwnerUsername` | always (informational) | `""` |
| `Metadata.OwnerDisplayName` | always (informational) | `""` |
| `Metadata.TechnicalContactUsername` | always (informational) | `""` |
| `Metadata.TechnicalContactDisplayName` | always (informational) | `""` |
| `Metadata.PCode` | always (informational); `P` + 5 digits | `""` |
| `Metadata.CmdbId` | always (informational); a GUID | `""` |
| `Metadata.Description` | always (informational); single line, may contain links | `""` |
| `Metadata.NetworkAccessIP4Range` | always (informational); IPv4 address or CIDR | `""` |
| `Metadata.NetworkAccessIP6Range` | always (informational); IPv6 address or CIDR | `""` |
| `Metadata.NetworkAccessLocation` | always (informational); a name from `locations.txt` | `""` |
| `ConversionResult.*` | only from `Convert-ApplicationAccessPolicyToRBAC` (informational): `AppId`, `ResolvedDisplay`, `AccessRight`, `ScopeGroup`, `DerivedRoles`, `SkippedPermissions`, `ConfigPath` | not written |
| `Runtime.GeneratedAt` | always (informational); UTC ISO 8601 timestamp - top-level before schema 4.3 | generation time |
| `Runtime.OperatorUsername` | always (informational); session user that generated the file | `""` |
| `Runtime.OperatorMachineName` | always (informational); machine the file was generated on | `""` |
| `Runtime.CollectedErrors` | always (informational) | `[]` |
| `Runtime.CollectedWarnings` | always (informational) | `[]` |

Files with every key written out are still read unchanged, as long as they are schema 4.4.

The `Metadata` section describes the application and carries the optional change reference. Every
generated config contains the full section, with `""` for each field you did not supply, so the
fields are ready to fill in.
Set descriptive fields with the matching `New-RBAC4AppConfig` parameters (`-OwnerUsername`, `-PCode`,
`-NetworkAccessLocation`, ...), and set `ChangeReference` with `-ChangeReference`. It does not affect
Exchange provisioning.

The `Runtime` section records who generated the config (`OperatorUsername`, `OperatorMachineName`)
and the errors (`CollectedErrors`) and warnings
(`CollectedWarnings`) the writer collected while building the config - for example
`Export-RBAC4AppConfig` notes there that `SpObjectId` was taken from a role assignment's
`EffectiveUserName`, or that an unreadable scope group was exported reference-only under `-Force`. Like `Metadata`, it is always written in
full (each list as `[]` when empty) and is never used for provisioning. `GeneratedAt` lives in this
section since schema 4.3 (it used to be a top-level key).

`Convert-ApplicationAccessPolicyToRBAC` also writes a `ConversionResult` section: the full per-policy
result it returns (`AppId`, `ResolvedDisplay`, `AccessRight`, `ScopeGroup`, `DerivedRoles`,
`SkippedPermissions`, `ConfigPath`; its warnings and errors go to `Runtime`). It is informational and
ignored by `Invoke-RBAC4AppConfig`.

Contacts are stored as supplied, without any directory lookup; the two network access fields are
independent of each other. `Invoke-RBAC4AppConfig` re-validates the section, since the file may have
been edited by hand, and returns it as the `Metadata` property of its result. Valid location names are
listed one per line in `locations.txt` at the module root; the shipped list is a placeholder, so edit it
for your organization.

```yaml
Metadata:
  ChangeReference: "CHG123456"
  OwnerUsername: "jdoe"
  OwnerDisplayName: "Jan Doe"
  PCode: "P12345"
  CmdbId: "11111111-2222-3333-4444-555555555555"
  Description: "Runbook: https://wiki.contoso.com/mailapp"
  NetworkAccessIP4Range: "10.0.0.0/24"
  NetworkAccessIP6Range: "2001:db8::/32"
  NetworkAccessLocation: "HeadOffice"
```

### State repository

`New-RBAC4AppConfig -Repository <folder>` builds on a state file you created by hand in that folder,
named `{AppId}.yaml`, `{AppId}.yml` or `{AppId}.json` and using the schema above. Any key can be left
out. Each setting comes from the command line first, then the state file, then the module defaults, so
this keeps the file's values and changes only the PCode:

```powershell
New-RBAC4AppConfig -AppId '11111111-2222-3333-4444-555555555555' -Repository 'C:\RBAC4AppState' -PCode 'P12345'
```

- The application's identity always comes from Graph. If the file has an `Application.AppId`, it must
  match the application.
- The state file is never modified. The new config is written to `-OutputPath` as usual.
- With no matching file, a warning is written and the config is built from the command line and defaults.
- Changing `-ScopeKind` ignores the file's `AssignmentScope` and `SeparateScopePerRole`. Changing
  `-AccessGroupType` ignores its `AccessGroupName` and `GroupPrefix`, which belong to the old type.
- Values from the file are validated like command-line values.

`Invoke-RBAC4AppConfig` accepts only `SchemaVersion: "4.4"`. A config of any earlier version (`"4.3"`, `"4.2"`,
`"4.1"`, `"4.0"`, `"3.0"`, ...) is refused with an error pointing back at `New-RBAC4AppConfig`
(or `Get-RBAC4AppEntry | Export-RBAC4AppConfig` / `Convert-ApplicationAccessPolicyToRBAC`) to regenerate it.
State files read by `New-RBAC4AppConfig -Repository` may still be of version 3.0-4.4 (in a pre-4.4 file an
absent `AccessGroupType` means `DistributionList`, the default of those versions).

## Microsoft365DSC output (`-Format M365DSC`)

`New-RBAC4AppConfig`, `Export-RBAC4AppConfig`, and `Convert-ApplicationAccessPolicyToRBAC` accept
`-Format M365DSC`. They then write the normal YAML config **and**, next to it with the same name, a
[Microsoft365DSC](https://microsoft365dsc.com) configuration script (`.ps1`) declaring the same
desired state, so it can be applied and drift-monitored by DSC. Only the `.yml` can be fed to
`Invoke-RBAC4AppConfig`; the `.ps1` is a second rendering of it.

| Config data | DSC resource |
| --- | --- |
| Application | `EXOServicePrincipal` (`<DisplayName>_SP`, as `Register-EXOServicePrincipal`) |
| Scope group - `CloudMailEnabledSecurityGroup` / `DistributionList` | `EXODistributionGroup` (hidden, closed, sender authentication, send restricted to `ManagedBy`) |
| Scope group - `M365Group` / `HybridMailEnabledSecurityGroup` | none: the group is only referenced and must already exist |
| Management scope | `EXOManagementScope` |
| Each role | `EXOManagementRoleAssignment` (same deterministic name, bound with `CustomResourceScope`) |

What the DSC script does differently from `Invoke-RBAC4AppConfig` (each is also a warning, a `# NOTE`
in the script, and - for `New-RBAC4AppConfig` - an entry in `Runtime.CollectedWarnings`):

- **Always a management scope.** `EXOManagementRoleAssignment` has no `RecipientGroupScope`, so even
  a config with `AssignmentScope: RecipientGroupScope` is bound through
  `MemberOfGroup -eq '<group DN>'`.
- **The group DN is a parameter.** For `ScopeKind: Group` the Configuration takes
  `$ScopeGroupDistinguishedName` (one per role, e.g. `$ScopeGroupDistinguishedNameAppMailSend`, with
  `SeparateScopePerRole`). It is mandatory, except when `Export-RBAC4AppConfig` read the DN from an
  existing management scope and pre-filled it. A group that does not exist yet has no DN, so the
  script cannot be compiled for a brand-new group in one step: create the group first (for example
  with `Invoke-RBAC4AppConfig` on the `.yml`), read its DN
  (`Get-Recipient -Identity <group> | Select-Object DistinguishedName`), then compile with it.
- **`Members` is authoritative.** DSC removes members that are not listed; `Invoke-RBAC4AppConfig`
  only adds. An owner (`ManagedBy`) that does not exist fails the DSC run instead of skipping the
  send restriction.
- **`ScopeRecipients` are written as given**, as `PrimarySmtpAddress` values (no `Get-Recipient`
  lookup happens at generation time): list primary SMTP addresses.
- **Authentication is a managed identity by default** (`ManagedIdentity = $true` and `$TenantId`,
  defaulting to the resolved tenant, on every resource), which only runs on a machine that has one
  (Azure VM, Arc-enabled server, Azure Automation). `-DscAuthentication Certificate` writes
  app-plus-certificate sign-in instead: the Configuration takes mandatory `$ApplicationId` and
  `$CertificateThumbprint` parameters (plus `$TenantId`) and runs on any machine whose certificate
  store holds that app registration's certificate. Either way the identity needs
  `Exchange.ManageAsApp` and an Exchange admin role, and no credential or secret is written (a
  thumbprint is not a secret, and it is a parameter, not a value in the file). For Exchange Online
  pass `-TenantId` as the tenant domain (`contoso.onmicrosoft.com`) when compiling.

```powershell
$yml, $ps1 = New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' -Role 'Mail.Send' `
                 -ManagedBy 'rbac-owner@contoso.com' -Format M365DSC -OutputPath C:\rbac-configs

. $ps1                                      # defines Configuration RBAC4App_Contoso_Mail_App
RBAC4App_Contoso_Mail_App -ScopeGroupDistinguishedName 'CN=USRACo1P-ContosoMailApp,OU=...' -OutputPath C:\rbac-mof
Start-DscConfiguration -Path C:\rbac-mof -Wait -Verbose

# Certificate sign-in instead of a managed identity (workstation, pipeline agent):
$yml, $ps1 = New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' -Format M365DSC -DscAuthentication Certificate
. $ps1
RBAC4App_Contoso_Mail_App -TenantId 'contoso.onmicrosoft.com' -ApplicationId '<DSC app id>' `
    -CertificateThumbprint '<thumbprint>' -ScopeGroupDistinguishedName 'CN=...' -OutputPath C:\rbac-mof

# Existing tenant state as DSC (the DN is pre-filled for management-scope bound assignments):
Get-RBAC4AppEntry | Export-RBAC4AppConfig -PerApplication -Format M365DSC -Path C:\rbac-dsc
```

Application names, group names and filters are written only as single-quoted string literals, so a
value cannot inject script into the generated file. The resource property names follow the
Microsoft365DSC documentation; validate the script against your Microsoft365DSC version
(`Test-DscConfiguration`) before relying on it.

## Install / import

The module is run from source (it is not published to the PowerShell Gallery):

```powershell
git clone https://github.com/ehlo-pl/EXORBACforAppManagement.git
Import-Module .\EXORBACforAppManagement\src\EXORBACforAppManagement\EXORBACforAppManagement.psd1 -Force
```

Then connect your sessions:

```powershell
Connect-MgGraph -Scopes 'Application.ReadWrite.All'
Connect-ExchangeOnline
```

> **Graph/Exchange connection caveat:** Microsoft.Graph and ExchangeOnlineManagement can conflict
> when both authenticate in the same PowerShell process because they load shared MSAL/WAM identity
> assemblies. Symptoms include `RuntimeBroker` / WAM `NullReferenceException` from
> `Connect-ExchangeOnline` after `Connect-MgGraph`, or `Method not found: ...WithLogging(...)` from
> `Connect-MgGraph` after Exchange Online is loaded. Some versions may appear compatible in one
> session (for example ExchangeOnlineManagement 3.10.1 and Microsoft.Graph 2.41.1), but this should
> not be treated as stable or production-safe; prefer separate `pwsh` processes for Graph and
> Exchange work. `Connect-M365Tenant -Workload MicrosoftGraph` and
> `Connect-M365Tenant -Workload ExchangeOnline` from MSCloudLoginAssistant are wrappers around
> `Connect-MgGraph` and `Connect-ExchangeOnline`; they may help in app-only/access-token scenarios,
> but they do **not** isolate the modules or guarantee a fix for interactive WAM/MSAL collisions in a
> single process.
> **Always preview with `-WhatIf` first.** `New-RBAC4AppEntry` (`ConfirmImpact='High'`) and
> `New-RegisteredApp` (`ConfirmImpact='Medium'`) gate every mutating step behind `ShouldProcess`.

## Usage

### End-to-end

```powershell
# 1. Register the app + service principal, then 2. scope EXO RBAC for it (pipeline):
New-RegisteredApp -DisplayName 'Contoso Mail App' |
    New-RBAC4AppEntry -Members 'shared@contoso.com' -Role 'Mail.Send' -WhatIf -Verbose

# 3. Read the resulting assignments:
Get-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App'

# Inventory distinct registered applications that already hold supported EXO app permissions:
Get-RBAC4AppApplication
```

### New-RegisteredApp

Creates an Entra application registration and, unless `-SkipServicePrincipal`, its service
principal. Emits `AppId` / `ServicePrincipalId` so it can pipe into `New-RBAC4AppEntry`.

NOTE: requires high privileges; intended mainly for testing environments when production app registration is handled by a separate pipeline/team.

```powershell
New-RegisteredApp -DisplayName 'Contoso Mail App' -WhatIf -Verbose
```

### New-RBAC4AppEntry

Resolves the application against the Exchange Online service principal pointer already registered
for it (by `-RegisteredAppName`, `-AppId`, or `-SpObjectId` — no Microsoft Graph session needed),
creates a scoped group named `"{GroupPrefix}-{DisplayName}"` (a distribution list by default; see
[Choosing the scope group type](#choosing-the-scope-group-type--accessgrouptype-) below), adds
members, ensures the EXO service principal, and creates one role assignment per role — each bound
directly to that group via `-RecipientGroupScope` (the default `-AssignmentScope RecipientGroupScope`).
With `-AssignmentScope ManagementScope` it instead ensures a management scope (default name
`"MSRAo1P-{DisplayName}"`) whose `RecipientRestrictionFilter` targets that group's members and binds
each assignment to it via `-CustomResourceScope`. See [Choosing the scope kind](#choosing-the-scope-kind--scopekind-) for
scoping to specific mailboxes, a tag, or a raw filter instead of a group. Short role names such as `Mail.Send` are normalized to
`Application Mail.Send`.

```powershell
# By AppId, assigning a single role to a shared mailbox:
New-RBAC4AppEntry -AppId '11111111-2222-3333-4444-555555555555' `
    -Members 'sharedmailbox@contoso.com' -Role 'Mail.Send' -Verbose

# By SP object id, multiple roles, custom group prefix:
New-RBAC4AppEntry -SpObjectId '11111111-2222-3333-4444-555555555555' `
    -Role 'Application Calendars.Read','Application Contacts.Read' -GroupPrefix 'Um365Prod'
```

For an application that has **never been registered in Exchange Online** (no service principal
pointer exists yet), none of `-RegisteredAppName`, `-AppId`, or `-SpObjectId` alone is enough to
create that pointer — AppId and the SP object id can't be derived from each other without Graph.
Supply all three together to bootstrap it in one call, entirely from an Exchange-Online-only
session:

```powershell
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' `
    -AppId '11111111-2222-3333-4444-555555555555' `
    -SpObjectId '66666666-7777-8888-9999-000000000000' `
    -Role 'Mail.Send'
```

This works transparently when piped straight from `New-RegisteredApp` — its output's `DisplayName`
/ `AppId` / `ServicePrincipalId` properties bind to all three by name. Otherwise, use
`New-RBAC4AppConfig` + `Invoke-RBAC4AppConfig` (see [Two-session workflow](#two-session-workflow)).
`Set-RBAC4AppEntry` accepts the same three-identifier bootstrap.

#### Choosing the scope kind (`-ScopeKind`)

With `-ScopeKind Group` (default) and `-AssignmentScope RecipientGroupScope` (default), role
assignments are bound directly to the scope group (`New-ManagementRoleAssignment
-RecipientGroupScope`) and no management scope is created. In every other case they point at a named
management scope (`New-ManagementScope -RecipientRestrictionFilter`, then `New-ManagementRoleAssignment
-CustomResourceScope`), and `-ScopeKind` decides how that scope's filter is built:

| `-ScopeKind` | Filter | Group created? | Extra parameters |
| --- | --- | --- | --- |
| `Group` (default) | none with `-AssignmentScope RecipientGroupScope` (default); `MemberOfGroup -eq '<group DN>'` (direct members only) with `-AssignmentScope ManagementScope` | yes, per `-AccessGroupType` | `-AccessGroupType`, `-AccessGroupName`, `-GroupPrefix`, `-Members`, `-ManagedBy`, `-BootstrapMember`, `-AssignmentScope` |
| `Recipients` | `(PrimarySmtpAddress -eq 'a@x') -or ...` | no | `-ScopeRecipients` (required; each is resolved via `Get-Recipient`) |
| `Tag` | `<CustomAttributeN> -eq '<value>'` | no | `-ScopeTagAttribute` (default `CustomAttribute1`), `-ScopeTagValue` (default: the scope name). The module does **not** stamp the attribute on mailboxes. |
| `Filter` | the raw OPATH you pass | no | `-ScopeFilter` (required) |

The scope name defaults to `"{ManagementScopePrefix}-{DisplayName}"` (prefix `MSRAo1P`); pass
`-ManagementScopeName` (max 64 chars) to override it; both are ignored (with a warning) under
`-AssignmentScope RecipientGroupScope`, and asking for `RecipientGroupScope` with a non-Group kind is
an error. Group-only parameters passed with a non-Group kind are ignored with a warning. An existing scope with an equivalent filter is left alone; a
drifted one is updated via `Set-ManagementScope`.

```powershell
# Specific mailboxes, no group at all:
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -ScopeKind Recipients `
    -ScopeRecipients 'shared1@contoso.com','shared2@contoso.com' -Role 'Mail.Send'

# Every mailbox tagged CustomAttribute7 = ContosoMailApp:
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -ScopeKind Tag `
    -ScopeTagAttribute CustomAttribute7 -ScopeTagValue 'ContosoMailApp' -Role 'Mail.Send'

# Raw OPATH filter with a custom scope name:
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -ScopeKind Filter `
    -ScopeFilter "Department -eq 'Finance'" -ManagementScopeName 'Finance-MailApp' -Role 'Mail.Send'
```

**Switching between the two bindings.** Assignments bound directly to the group are reported by
`Get-RBAC4AppEntry` with `ScopeKind` `GroupDirect` (and exported with `AssignmentScope:
RecipientGroupScope`). `New-RBAC4AppEntry`/`Invoke-RBAC4AppConfig` warn about an assignment bound the
other way than requested but leave it alone; `Set-RBAC4AppEntry` re-binds it in either direction
(`-AssignmentScope ManagementScope` moves group-bound assignments onto the management scope; the
default moves management-scoped ones directly onto the group, leaving the old management scope in
place). `Test-RBAC4AppEntry` reports such assignments as not valid, and `Remove-RBAC4AppEntry` removes
either kind, plus the management scope if one exists and nothing else uses it.

#### Choosing the scope group type (`-AccessGroupType`)

By default the scope is a freshly-created Exchange-Online-only (cloud) mail-enabled security group.
`-AccessGroupType` selects a different group kind — Exchange Online RBAC supports Microsoft 365
groups, mail-enabled security groups, and distribution lists (direct membership only, nested
members are out of scope):

| `-AccessGroupType` | Lifecycle | `-AccessGroupName` | `-Members` / `-ManagedBy` / `-BootstrapMember` |
| --- | --- | --- | --- |
| `CloudMailEnabledSecurityGroup` (default) | Creates/configures an EXO-only mail-enabled security group (`New-DistributionGroup -Type Security`) | optional (generated from `GroupPrefix`) | applied to the group |
| `DistributionList` | Creates/configures an EXO-only distribution list | optional (generated from `GroupPrefix`) | applied to the group |
| `M365Group` | Creates/configures a Unified Group | optional (generated from `GroupPrefix`) | applied to the group |
| `HybridMailEnabledSecurityGroup` | References an **existing** on-prem/hybrid-synced group (never created or modified) | **required** | all ignored, with a warning (membership and ownership are managed on-premises) |

`MailEnabledSecurityGroup` (the pre-0.9.0 name) is still accepted as input and means
`HybridMailEnabledSecurityGroup`; output and generated configs use the new name. When reading an
existing scope group back (`Get-RBAC4AppEntry`), a mail-universal security group with
`IsDirSynced` `$false` is reported as `CloudMailEnabledSecurityGroup`; a synced one, or one whose
sync state cannot be read, as `HybridMailEnabledSecurityGroup`.

**Groups the module creates cannot receive mail from just anyone.** On creation every
`CloudMailEnabledSecurityGroup`, `DistributionList`, and `M365Group` gets
`RequireSenderAuthenticationEnabled $true` and `AcceptMessagesOnlyFromSendersOrMembers` set to its
resolved owners (`-ManagedBy`, default `GraphAPI-Dummy-owner`), so only the owner can send to it. An
owner that does not resolve to a recipient is left out of the allowed senders; if none resolves, the
group is still created, only sender authentication is enforced, and a warning says so (create the
owner recipient, then run `Set-RBAC4AppEntry`). `New-RBAC4AppConfig` warns at generation time when a
group would be created with the default owner. For an **existing** group: `New-RBAC4AppEntry` /
`Invoke-RBAC4AppConfig` warn when it has no restriction, `Set-RBAC4AppEntry` applies it
(`SendRestrictionApplied`), and `Test-RBAC4AppEntry` reports `SendRestricted` `$false` as a warning
(it does not make the entry invalid). A `HybridMailEnabledSecurityGroup` is never changed.

Because the owner is normally not the operator, every `Set-DistributionGroup`,
`Add-DistributionGroupMember`, and `Remove-DistributionGroup` call passes
`-BypassSecurityGroupManagerCheck`, which needs an Exchange admin role (for example Organization
Management). **Apps provisioned before 0.9.0** use a `DistributionList` (`UDLRAo1P-*`): pass
`-AccessGroupType DistributionList` to `Set-`/`Test-`/`Remove-RBAC4AppEntry` for them. Called with
the defaults, `Set-RBAC4AppEntry` refuses to touch such an app (it still has its `UDLRAo1P-*` list
but no `USRACo1P-*` group): it changes nothing and returns an error with the list in
`LegacyGroupName`. To move the app onto a cloud security group, pass
`-AccessGroupType CloudMailEnabledSecurityGroup` explicitly. `Test-RBAC4AppEntry` reports the same case as a
warning, and `Remove-RBAC4AppEntry` refuses and removes nothing; both set `LegacyGroupName`.

When `-AccessGroupName` is omitted, `-GroupPrefix` itself defaults to a value based on
`-AccessGroupType` — `USRACo1P` (CloudMailEnabledSecurityGroup), `UDLRAo1P` (DistributionList),
`Um365RAo1P` (M365Group), or `USRAHo1P` (HybridMailEnabledSecurityGroup; earlier versions used
`USRAo1P`, so pass `-AccessGroupName` or `-GroupPrefix USRAo1P` for such existing groups) — rather
than one fixed string; pass `-GroupPrefix` explicitly to override it.

```powershell
# Default: an EXO-only (cloud) mail-enabled security group as the scope:
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -Members 'shared@contoso.com' -Role 'Mail.Send'

# EXO-only distribution list (the default before 0.9.0):
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -AccessGroupType DistributionList `
    -Members 'shared@contoso.com' -Role 'Mail.Send'

# Microsoft 365 group as the scope instead:
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -AccessGroupType M365Group `
    -Members 'shared@contoso.com' -Role 'Mail.Send'

# Reference an existing on-prem/hybrid-synced mail-enabled security group (not created; members untouched):
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -AccessGroupType HybridMailEnabledSecurityGroup `
    -AccessGroupName 'OnPrem-MailApp-Scope' -Role 'Mail.Send'
```

`Set-`, `Test-`, and `Remove-RBAC4AppEntry` and `New-RBAC4AppConfig` accept the same
`-AccessGroupType` and share the same `-GroupPrefix` naming convention
(`Convert-ApplicationAccessPolicyToRBAC` always reuses the policy's existing group instead). `Remove-RBAC4AppEntry` never deletes a `HybridMailEnabledSecurityGroup`
(it only detaches this app's role assignments) and uses `Remove-DistributionGroup` for a
`CloudMailEnabledSecurityGroup` or `DistributionList`.

Returns a summary `[pscustomobject]` (resolved identity, group name, normalized roles, assignment
names, `Warnings`, `Errors`) and also exports it to `$env:TEMP\<name>_<timestamp>_<8 hex>.clixml`. If that export fails, the summary carries a warning.

#### Automation / CI usage (`-FailOnError`)

`New-`, `Set-`, `Remove-RBAC4AppEntry` and `Invoke-RBAC4AppConfig` report per-item failures in the
summary's `Errors` property and do **not** write to the error stream by default, so `$?` stays
`$true` and `$ErrorActionPreference = 'Stop'` does not stop the script. In automation, either check
the summary or pass `-FailOnError`:

```powershell
# Option 1: inspect the summary
$r = New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -Confirm:$false
if ($r.Errors.Count) { throw ($r.Errors -join '; ') }

# Option 2: -FailOnError - the summary is still emitted, then one error record
# (FullyQualifiedErrorId 'RBAC4AppOperationFailed', TargetObject = the summary) is written;
# with -ErrorAction Stop it terminates the script.
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -Confirm:$false -FailOnError -ErrorAction Stop
```

`Remove-RBAC4AppEntry` fails closed: if the role assignment or group member read that feeds its
safety gate fails, it removes nothing and returns `IsRemoved = $false` with the reason in `Reason`
and `Errors`.

### Get-RBAC4AppEntry

Returns EXO management role assignments for Application roles (`Application *`). With no arguments
it returns all of them; filter by application and/or role, plus optional `-Enabled`,
`-RoleAssigneeType`, and `-ScopeType`. Every row resolves the assignee back to its Exchange Online
service principal pointer (`Get-ServicePrincipal`) to expose `AppId`/`ServicePrincipalId`, and
resolves its recipient scope to the management scope name (`ManagementScope`), its `ScopeKind`
(`Group`/`Recipients`/`Tag`/`Filter`, or `GroupDirect` for a legacy group-bound assignment),
`ScopeFilter`, and - for group kinds - the scope group name, type, and current membership.
The raw `EffectiveUserName`/`App` fields from `Get-ManagementRoleAssignment` are also passed
through as-is - Exchange Online typically leaves both blank/placeholder for application-role
assignments, but they're surfaced for completeness rather than dropped.

```powershell
Get-RBAC4AppEntry                                            # every application-role assignment
Get-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -Role 'Mail.Send'
Get-RBAC4AppEntry -AppId '11111111-2222-3333-4444-555555555555' | Format-Table Name,Role,Scope
Get-RBAC4AppEntry -ScopeType All -RoleAssigneeType All            # every recipient scope/assignee
'Contoso Mail App', 'Fabrikam Archiver' | Get-RBAC4AppEntry       # several apps, one EXO read
```

Each row is an `RBAC4App.Entry` and also says where its data came from:
`ServicePrincipalIdSource` (`ExoPointer`, `EffectiveUserName`, `NameHeuristic`, or `None`),
`ScopeSource` (`ManagementScope`, `Legacy`, or `None`), `ScopeGroupName`, and `ScopeGroupResolved`
(whether the scope group was actually read). `Warnings` lists the warnings that apply to the row.

> `Get-ManagementRoleAssignment` has no `-App` parameter, so role filtering uses native `-Role`
> while the application filter is applied client-side: an assignment is kept when its resolved
> assignee *is* the requested service principal (object id, or AppId when the object id is
> missing) - never by name substring. `-ScopeType` defaults to `Group`/`CustomRecipientScope` (the
> only recipient scopes this module creates); pass `-ScopeType All` to also see e.g.
> Organization-wide assignments.

Exchange Online is read once per call, however many identities are piped in. A failed
`Get-ServicePrincipal` or `Get-ManagementRoleAssignment` read is reported as one error and returns
nothing - it is never mistaken for an empty tenant. Only `-AppId` binds by property name from the
pipeline, so a row, a `New-RegisteredApp` result, or any object with an `AppId` pipes in; names are
piped as plain strings. For legacy Application Access Policies, call `Get-ApplicationAccessPolicy`
directly (or `Convert-ApplicationAccessPolicyToRBAC`).

### Get-RBAC4AppApplication

The app-centric inventory view: one `RBAC4App.Application` row per assignee (grouped by
`RoleAssigneeType` + `RoleAssigneeName`), aggregating its roles, assignment names, management
scopes, scope kinds, scope groups, and in-scope recipients. Pipe `Get-RBAC4AppEntry` rows into it
(no further Exchange Online reads), or let it fetch them with the same parameters. A role group
holding an application role keeps its own row with `RoleAssigneeType` `RoleGroup` and no
`DisplayName`.

```powershell
Get-RBAC4AppApplication
Get-RBAC4AppApplication -Role 'Mail.Send'
Get-RBAC4AppEntry -Enabled $true | Get-RBAC4AppApplication
```

### Export-RBAC4AppConfig

Writes `Get-RBAC4AppEntry` rows as schema 4.4 configs for `Invoke-RBAC4AppConfig` - one per role
assignment, or one per application (and scope) with `-PerApplication`. `-Path` is a directory
(default: the current one; one `rbac4app-<name>.yml|.json` file per config, colliding names
numbered) or a file (several configs become one JSON array). Rows are collected and written once at
the end, `-WhatIf` is honored, and `-PassThru` returns `Path`/`Config` per file.

Guessed data is refused (a non-terminating error naming `-Force`) unless `-Force`:

- an application identity inferred from the generated role assignment name
  (`ServicePrincipalIdSource` `NameHeuristic`);
- a scope group that could not be read (`ScopeGroupResolved` `$false`). With `-Force` it is exported
  as a reference-only `AccessGroupType: HybridMailEnabledSecurityGroup` with no members, which
  `Invoke-RBAC4AppConfig` validates but never creates.

```powershell
Get-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' | Export-RBAC4AppConfig -Path .\configs
Get-RBAC4AppEntry | Export-RBAC4AppConfig -PerApplication -Format Json -Path .\inventory.json
Get-RBAC4AppEntry | Export-RBAC4AppConfig -PerApplication -WhatIf
```

### Test-RBAC4AppEntry

Read-only check that an application has every component `New-RBAC4AppEntry` provisions: the
resolvable service principal, the scope source (a group for `-ScopeKind Group`), the management
scope (only for `-AssignmentScope ManagementScope`), the Exchange Online service principal pointer,
and one role assignment per role (looked up by the deterministic assignment name) bound the way
`-AssignmentScope` expects. It
mirrors `New-RBAC4AppEntry`'s `-Role` / `-GroupPrefix` / `-AssignmentScope` defaults and optionally verifies `-Members`
against the group's membership. Returns a summary `[pscustomobject]` with per-component flags
(`ServicePrincipalExists`, `ScopeGroupExists`, `ExoServicePrincipalExists`), the
expected/found/missing role assignments, a `Missing` list, and an overall `IsValid`.

```powershell
Test-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App'
Test-RBAC4AppEntry -AppId '11111111-2222-3333-4444-555555555555' -Role 'Mail.Send','Calendars.Read' -Members 'shared@contoso.com'
```

### Convert-ApplicationAccessPolicyToRBAC

Generates schema 4.4 configs compatible with `New-RBAC4AppConfig` and `Invoke-RBAC4AppConfig`:
derives roles from the app's granted Microsoft Graph application permissions and binds them
directly to the group the policy uses today. No Exchange Online objects or policies are modified.
`DenyAccess` policies and apps without convertible permissions are skipped.

**The migration keeps the current scope groups.** Each config records the policy's `ScopeName`
verbatim as `AccessGroupName`, with `AccessGroupType: HybridMailEnabledSecurityGroup` (the reference-only
type) and `AssignmentScope: RecipientGroupScope`. `Invoke-RBAC4AppConfig` therefore only checks that
the group exists (`Get-Recipient -Identity <ScopeName>`, failing if it does not) and assigns the roles
straight to it with `-RecipientGroupScope`. It never creates a group, never renames, shortens, or
sanitizes the name, and never changes the group's settings, members, or owners, so the same mailboxes
stay in scope. A policy without a `ScopeName` is reported in `Errors` and no config is written. The
former `-AccessGroupType`, `-GroupPrefix`, and `-ManagedBy` parameters are still accepted but ignored
(with a warning).

```yaml
RbacScope:
  AccessGroupType: "HybridMailEnabledSecurityGroup"
  AccessGroupName: "EvenUsers"          # the policy's ScopeName, unchanged
```

Use `-OutputPath` to select an existing output directory (default: current directory) and
`-Format Json` for JSON instead of the default YAML. Each policy summary exposes `ConfigPath`
instead of the former provisioning `RBACResult`; the same summary is written into the config's
`ConversionResult` section, with its warnings/errors in `Runtime`. Filenames start with `rbac4app-` and include
sanitized application/source-group names, AppId, timestamp, and a unique suffix so multiple
policies and repeated runs do not overwrite one another.

```powershell
Convert-ApplicationAccessPolicyToRBAC -WhatIf -Verbose

# Collect configs with Graph and EXO read access:
$results = Convert-ApplicationAccessPolicyToRBAC -OutputPath C:\rbac-configs -Confirm:$false
$results | Select-Object AppId, ConfigPath, Warnings, Errors

# In a separate Exchange-Online-only session, review and apply each generated file:
Invoke-RBAC4AppConfig -Path 'C:\rbac-configs\<generated-file>.yml' -WhatIf
```

### New-RBAC4AppUnifiedGroup

Ensures the scoped, private/hidden Unified Group exists and is configured (subscription, address
list, connectors disabled). Returns a summary object (`OwnerRequested`, `OwnerAdded`,
`AlreadyExisted`, and the underlying `Group`). `New-RBAC4AppEntry` delegates to it, but it can be
used on its own.

```powershell
New-RBAC4AppUnifiedGroup -Name 'Um365RAo1-ContosoMailApp' -WhatIf -Verbose
```

### Register-EXOServicePrincipal

Creates the Exchange Online service principal pointer that links an Entra application into EXO so it
can receive application RBAC assignments.

```powershell
Register-EXOServicePrincipal -AppId '1111...' -ObjectId '2222...' -DisplayName 'Contoso_SP' -WhatIf
```

### New-RBAC4AppConfig

**Run in the Microsoft Graph session.** Resolves the Entra service principal and writes a config
file (YAML by default, or JSON via `-Format Json`) that captures all parameters needed for
provisioning. No Exchange Online cmdlets are called.

With the default `-ScopeKind Group`, the config defaults to `-AssignmentScope RecipientGroupScope`:
`Invoke-RBAC4AppConfig` binds the role assignments directly to the scope group
(`New-ManagementRoleAssignment -RecipientGroupScope`) and creates no management scope. Pass
`-AssignmentScope ManagementScope` for a management scope over the group's members (the
`New-RBAC4AppEntry` model). The `Recipients`, `Tag`, and `Filter` kinds always use a management scope.

```powershell
# By display name:
$yml = New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' `
           -Role 'Mail.Send' -Members 'shared@contoso.com' -OutputPath C:\rbac-configs

# By AppId, distribution-list scope:
$yml = New-RBAC4AppConfig -AppId '11111111-2222-3333-4444-555555555555' `
           -Role 'Mail.Send','Calendars.Read' `
           -AccessGroupType DistributionList `
           -Members 'shared@contoso.com' -OutputPath C:\rbac-configs

# Bind via a management scope over the group's members instead of directly to the group:
$yml = New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' `
           -Role 'Mail.Send' -AssignmentScope ManagementScope -OutputPath C:\rbac-configs

# Give each configured permission its own scope group:
$yml = New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' `
           -Role 'Mail.Send','Calendars.Read' -SeparateScopePerRole `
           -Members 'shared@contoso.com' -OutputPath C:\rbac-configs

# By SP object id, referencing an existing on-prem group:
$yml = New-RBAC4AppConfig -SpObjectId '11111111-2222-3333-4444-555555555555' `
           -Role 'Mail.Send' -AccessGroupType HybridMailEnabledSecurityGroup `
           -AccessGroupName 'OnPrem-MailApp-Scope' -OutputPath C:\rbac-configs

# Same as the first example, written as JSON instead:
$json = New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' `
           -Role 'Mail.Send' -Members 'shared@contoso.com' -Format Json -OutputPath C:\rbac-configs
```

With `-Format M365DSC` it returns two paths - the `.yml` config, then the `.ps1` Microsoft365DSC
configuration (see [Microsoft365DSC output](#microsoft365dsc-output--format-m365dsc)).

Returns the path to the written config file (`.yml` or `.json`). Pass `-WhatIf` to preview the
output path and content without writing the file. The config schema is identical between formats —
`-Format` only changes serialization and the file extension. `-SeparateScopePerRole` (alias
`-SeparateScopePerPermission`) is available for `-ScopeKind Group`; it creates one uniquely named
scope group and management scope per configured role, using the same members and owners for each.

### Invoke-RBAC4AppConfig

**Run in the ExchangeOnlineManagement session.** Reads the config file produced by
`New-RBAC4AppConfig` — YAML or JSON, auto-detected from the `-Path` extension (`.yml`/`.yaml` vs
`.json`), or forced via `-Format` — and performs all Exchange Online provisioning steps — scope
group creation, member addition, EXO service principal registration, and management role
assignments — without calling any Microsoft Graph cmdlet.

Returns the same summary object shape as `New-RBAC4AppEntry` (`ResolvedDisplay`, `AppId`,
`SpObjectId`, `ScopeGroupName`, `RolesNormalized`, `RoleAssignmentsName`, `MembersAdded`,
`MembersFinal`, `Warnings`, `Errors`).

```powershell
# Preview:
Invoke-RBAC4AppConfig -Path C:\rbac-configs\rbac4app-ContosoMailApp-202609200830.yml -WhatIf

# Provision:
Invoke-RBAC4AppConfig -Path C:\rbac-configs\rbac4app-ContosoMailApp-202609200830.yml

# JSON config (format auto-detected from the .json extension):
Invoke-RBAC4AppConfig -Path C:\rbac-configs\rbac4app-ContosoMailApp-202609200830.json

# Pipeline from a directory of configs (mixed YAML/JSON):
Get-ChildItem C:\rbac-configs\*.yml, C:\rbac-configs\*.json | Invoke-RBAC4AppConfig
```

## Project layout

```powershell
src/EXORBACforAppManagement/
  EXORBACforAppManagement.psd1          # manifest
  EXORBACforAppManagement.psm1          # loader: dot-sources Private + Public, exports Public only
  Public/                        # 15 exported functions (see table above)
  Private/                       # Format-RBAC4AppSafeName, ConvertTo-RBAC4AppRoleName, ConvertTo/From-RBAC4AppYaml,
                                 # ConvertTo/From-RBAC4AppRecipientFilter, Get-RBAC4AppManagementScopeName, ...
tests/                           # Pester v5 tests
build.ps1                        # Init / Clean / Analyze / Test / Build
PSScriptAnalyzerSettings.psd1    # analyzer config (build fails only on Error severity)
.github/workflows/ci.yml         # CI: ./build.ps1 -Task All on ubuntu-latest
.github/workflows/release.yml    # Release on v* tag -> GitHub release with module zip
CHANGELOG.md                     # version history
```

## Build & test

`build.ps1` is the entry point for all quality gates (CI runs `./build.ps1 -Task All`):

```powershell
./build.ps1                 # All: Init, Clean, Analyze, Test, Build
./build.ps1 -Task Test      # run the Pester suite only
./build.ps1 -Task Analyze   # run PSScriptAnalyzer only
```

- **Init** installs Pester (>= 5) and PSScriptAnalyzer if missing.
- **Analyze** runs PSScriptAnalyzer over `src`; fails only on Error-severity findings.
- **Test** runs Pester, writes `testResults.xml` (NUnit) and `coverage.xml` (JaCoCo), and fails below `-CoverageThreshold` percent code coverage (default 90). Run
  `./utils/Show-CoverageGaps.ps1` afterwards to list the files and line numbers the tests miss.
- **Build** assembles the module into `output/<version>/EXORBACforAppManagement` and validates the manifest.

Tests mock the Graph/EXO cmdlets, so the suite runs without those modules installed (this is what
CI does on `ubuntu-latest`).

## Releasing

Bump `ModuleVersion` in the manifest, add a [`CHANGELOG.md`](CHANGELOG.md) entry, then push a
matching tag:

```powershell
git tag v0.2.0
git push origin v0.2.0
```

The `release.yml` workflow builds/tests the module, packages it, and publishes a GitHub release with
the module zip attached.

## Contributing

Work on feature branches and open a PR into `main`; CI must be green. When adding a role, update
both role tables (`$roleMap` in `Private/Get-AppRoleMap.ps1` and `$shortRoleMap` in
`Public/New-RBAC4AppEntry.ps1`). See [`AGENTS.md`](AGENTS.md) for deeper architecture notes.

## License

Licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
