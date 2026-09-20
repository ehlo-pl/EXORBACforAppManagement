# EXORBACforAppManagement

A PowerShell module for governing **Exchange Online (EXO) Role-Based Access Control for Entra
(Azure AD) applications**. It registers applications, assigns resource-scoped EXO *Application*
role permissions (e.g. `Application Mail.Send`) scoped to a Microsoft 365 group, and reads those
assignments back.

The three functions form a **create → assign → read** flow and share the same
`ByName` / `ByAppId` / `BySpObjectId` parameter conventions, so they compose over the pipeline.

| Function | Step | What it does |
| --- | --- | --- |
| [`New-RegisteredApp`](#new-registeredapp) | create | Creates an Entra app registration and (by default) its service principal. NOTE: required high privledges, I use it only in testing environment - as on production it's covered by separation of duty and done by 3rd party to my team pipeline |
| [`New-RBAC4AppEntry`](#new-rbac4appentry) | assign | Creates a scoped Unified Group, ensures the EXO service principal, and assigns EXO Application roles scoped to that group. |
| [`Get-RBAC4AppEntry`](#get-rbac4appentry) | read | Lists the EXO Application-role assignments. |
| [`Get-RegisteredAppWithPermission`](#get-registeredappwithpermission) | inventory | Lists distinct registered applications that currently hold supported EXO Application roles. |
| [`Test-RBAC4AppEntry`](#test-rbac4appentry) | validate | Checks an application has every component `New-RBAC4AppEntry` creates (SP, Unified Group, EXO service principal, role assignments) and returns an `IsValid` summary. |
| [`Convert-ApplicationAccessPolicyToRBAC`](#convert-applicationaccesspolicytorbac) | migrate | Migrates legacy Application Access Policies to RBAC for Applications, delegating to `New-RBAC4AppEntry`. |
| [`New-RBAC4AppUnifiedGroup`](#new-rbac4appunifiedgroup) | helper | Ensures/creates and configures the scoped Unified Group (used by `New-RBAC4AppEntry`). |
| `New-RBAC4AppDistributionGroup` | helper | Ensures/creates and configures a scoped Exchange-Online-only distribution list (used by `New-RBAC4AppEntry` when `-AccessGroupType DistributionList`). |
| [`Register-EXOServicePrincipal`](#register-exoserviceprincipal) | helper | Creates the EXO service principal pointer for an Entra app (used by `New-RBAC4AppEntry`). |
| [`New-RBAC4AppConfig`](#new-rbac4appconfig) | **Graph session** | Resolves the Entra SP via `Get-MgServicePrincipal` and writes a YAML or JSON config file (`-Format`) for `Invoke-RBAC4AppConfig`. No EXO calls. |
| [`Invoke-RBAC4AppConfig`](#invoke-rbac4appconfig) | **EXO session** | Reads the config (YAML or JSON, auto-detected from the extension) and provisions scope group, EXO service principal, and role assignments. No Graph calls. |

> Background: [Microsoft Learn — Role Based Access Control for Applications in Exchange Online](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac).

## Requirements

- **PowerShell 5.1+** (developed/tested on PowerShell 7).
- The following modules installed and **connected** at runtime (they are intentionally *not*
  declared as `RequiredModules`, so the module imports without them for unit testing):
  - **Microsoft Graph** — `Connect-MgGraph`. Needed by only three functions: `New-RegisteredApp`
    (`New-MgApplication`, `New-MgServicePrincipal`, `Get-MgContext`; needs the
    `Application.ReadWrite.All` scope), `New-RBAC4AppConfig` (`Get-MgServicePrincipal`,
    `Get-MgContext`), and `Convert-ApplicationAccessPolicyToRBAC` (`Get-MgServicePrincipal`,
    `Get-MgServicePrincipalAppRoleAssignment`).
  - **Exchange Online** — `Connect-ExchangeOnline`. Needed by every other function, including
    `New-RBAC4AppEntry` itself: `Get-ServicePrincipal` resolves the application (matching the
    pointer `Register-EXOServicePrincipal` creates — no Graph lookup), `Get-ConnectionInformation`
    reads the tenant id / current user, plus the usual `Get-UnifiedGroup`, `New-UnifiedGroup`,
    `Set-UnifiedGroup`, `Add-UnifiedGroupLinks`, `New-ServicePrincipal`, `Get-Recipient`,
    `New-ManagementRoleAssignment`, `Get-ManagementRoleAssignment`.

### Per-function module requirements

Only three functions touch Microsoft Graph at all. Every other function — including
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
| `Register-EXOServicePrincipal` | — | `Get-ServicePrincipal` `New-ServicePrincipal` *(skips creation if one already matches by AppId/DisplayName)* |
| `New-RBAC4AppEntry` | — | `Get-ServicePrincipal` `Get-ConnectionInformation` `Get-Recipient` `Add-DistributionGroupMember` `Get-UnifiedGroupLinks`/`Get-DistributionGroupMember` `Get-ManagementRoleAssignment` `New-ManagementRoleAssignment` *(resolves the app via `Get-ServicePrincipal`, or bootstraps a never-before-registered pointer when `-AppId`, `-SpObjectId`, and `-RegisteredAppName` are all supplied; skips a role assignment already scoped to the target group; + delegates to scope-group helpers and `Register-EXOServicePrincipal`)* |
| `Set-RBAC4AppEntry` | — | `Get-ServicePrincipal` `Get-ConnectionInformation` `Get-UnifiedGroup`/`Get-DistributionGroup`/`Get-Recipient` `Get-UnifiedGroupLinks`/`Get-DistributionGroupMember` `Add-DistributionGroupMember` `Get-ManagementRoleAssignment` `New-ManagementRoleAssignment` `Remove-ManagementRoleAssignment` *(same bootstrap fallback as `New-RBAC4AppEntry` when the pointer doesn't exist yet)* |
| `Test-RBAC4AppEntry` | — | `Get-ServicePrincipal` `Get-ConnectionInformation` `Get-UnifiedGroup`/`Get-DistributionGroup`/`Get-Recipient` `Get-ManagementRoleAssignment` `Get-UnifiedGroupLinks`/`Get-DistributionGroupMember` |
| `Remove-RBAC4AppEntry` | — | `Get-ServicePrincipal` `Get-ConnectionInformation` `Get-UnifiedGroup`/`Get-DistributionGroup`/`Get-Recipient` `Get-ManagementRoleAssignment` `Get-UnifiedGroupLinks`/`Get-DistributionGroupMember` `Remove-ManagementRoleAssignment` `Remove-UnifiedGroup`/`Remove-DistributionGroup` |
| `Get-RBAC4AppEntry` | — | `Get-ServicePrincipal` *(only when an app filter is supplied)* `Get-ManagementRoleAssignment` |
| `Get-RegisteredAppWithPermission` | — | `Get-ServicePrincipal` `Get-ManagementRoleAssignment` `Get-UnifiedGroup`/`Get-DistributionGroup` `Get-UnifiedGroupLinks`/`Get-DistributionGroupMember` *(resolves each scope group's name from CustomResourceScope, then its membership, cached per run)* |
| `Convert-ApplicationAccessPolicyToRBAC` | `Get-MgServicePrincipal` `Get-MgServicePrincipalAppRoleAssignment` | `Get-ApplicationAccessPolicy` `Get-DistributionGroupMember` *(+ all EXO cmdlets used by `New-RBAC4AppEntry`, which it calls with the SP identity it already resolved via Graph)* |
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

### What to do in each session

| | Session 1 — Microsoft Graph | Session 2 — ExchangeOnlineManagement |
| --- | --- | --- |
| **Connect** | `Connect-MgGraph -Scopes 'Application.ReadWrite.All'` | `Connect-ExchangeOnline` |
| **App registration** | `New-RegisteredApp` | — |
| **Plan RBAC config** | `New-RBAC4AppConfig` → writes `.yml` (or `.json` with `-Format Json`) | — |
| **Provision from config** | — | `Invoke-RBAC4AppConfig -Path .\config.yml` (format auto-detected from the extension) |
| **Everything else** | — | `New-RBAC4AppEntry` `Set-RBAC4AppEntry` `Test-RBAC4AppEntry` `Remove-RBAC4AppEntry` `Get-RBAC4AppEntry` `Get-RegisteredAppWithPermission` `New-RBAC4AppUnifiedGroup` `New-RBAC4AppDistributionGroup` `Register-EXOServicePrincipal` |

For a never-before-registered application, `New-RBAC4AppEntry` and `Set-RBAC4AppEntry` can also
bootstrap the Exchange Online service principal pointer directly in one Exchange-Online-only
session — supply `-AppId`, `-SpObjectId`, and `-RegisteredAppName` together (see
[`New-RBAC4AppEntry`](#new-rbac4appentry)) — as an alternative to the two-session config workflow.
`Convert-ApplicationAccessPolicyToRBAC` is the one remaining function that genuinely needs both
modules together in the same session, since it reads the app's Graph permission grants and then
provisions RBAC in the same call.

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
# → writes C:\rbac-configs\rbac4app-ContosoMailApp-<timestamp>.yml

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
[New-RBAC4AppConfig](#new-rbac4appconfig) for a JSON example) — only the serialisation differs.

```yaml
# RBAC4App configuration — generated by New-RBAC4AppConfig
# Feed to Invoke-RBAC4AppConfig in a session with only ExchangeOnlineManagement connected.
SchemaVersion: "3.0"
GeneratedAt: "2026-09-20T10:30:00Z"
TenantId: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

Application:
  AppId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  SpObjectId: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
  DisplayName: "Contoso Mail App"

Rbac:
  Roles:
    - Application Mail.Send

RbacScope:
  AccessGroupType: DistributionList   # DistributionList (default) | M365Group | MailEnabledSecurityGroup
  GroupPrefix: UDLRAo1P               # omit to default per -AccessGroupType: UDLRAo1P / USRAo1P / Um365RAo1P
  AccessGroupName: ""                 # required (and used instead of GroupPrefix) for MailEnabledSecurityGroup
  Members:
    - shared@contoso.com
  ManagedBy:
    - GraphAPI-Dummy-owner
  BootstrapMember: GraphAPI-Dummy
```

`SchemaVersion` must be `"3.0"`: `Invoke-RBAC4AppConfig` refuses an older config (e.g. a `"2.0"` file
where `RbacScope.ManagedBy` is still a single scalar value rather than a list) with an error pointing
back at `New-RBAC4AppConfig` to regenerate it.

## Install / import

The module is run from source (it is not published to the PowerShell Gallery):

```powershell
git clone https://github.com/ziembor/new-RBACforAppEntry.git
Import-Module ./new-RBACforAppEntry/src/EXORBACforAppManagement/EXORBACforAppManagement.psd1 -Force
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
> `Connect-MgGraph` after Exchange Online is loaded. If this happens, use separate `pwsh` processes
> for Graph and Exchange work. `Connect-M365Tenant -Workload MicrosoftGraph` and
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
Get-RegisteredAppWithPermission
```

### New-RegisteredApp

Creates an Entra application registration and, unless `-SkipServicePrincipal`, its service
principal. Emits `AppId` / `ServicePrincipalId` so it can pipe into `New-RBAC4AppEntry`.

NOTE: required high privledges, I use it only in testing environment - as on production it's covered by separation of duty and done by 3rd party to my team pipeline

```powershell
New-RegisteredApp -DisplayName 'Contoso Mail App' -WhatIf -Verbose
```

### New-RBAC4AppEntry

Resolves the application against the Exchange Online service principal pointer already registered
for it (by `-RegisteredAppName`, `-AppId`, or `-SpObjectId` — no Microsoft Graph session needed),
creates a scoped group named `"{GroupPrefix}-{DisplayName}"` (a distribution list by default; see
[Choosing the scope group type](#choosing-the-scope-group-type--accessgrouptype-) below), adds
members, ensures the EXO service principal, and creates one role assignment per role — each scoped
to the group via `-RecipientGroupScope`. Short role names such as `Mail.Send` are normalized to
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

#### Choosing the scope group type (`-AccessGroupType`)

By default the scope is a freshly-created Exchange-Online-only distribution list.
`-AccessGroupType` selects a different group kind — Exchange Online RBAC supports Microsoft 365
groups, mail-enabled security groups, and distribution lists (direct membership only, nested
members are out of scope):

| `-AccessGroupType` | Lifecycle | `-AccessGroupName` | `-Members` / `-ManagedBy` / `-BootstrapMember` |
| --- | --- | --- | --- |
| `DistributionList` (default) | Creates/configures an EXO-only distribution list | optional (generated from `GroupPrefix`) | applied to the group |
| `M365Group` | Creates/configures a Unified Group | optional (generated from `GroupPrefix`) | applied to the group |
| `MailEnabledSecurityGroup` | References an **existing** on-prem/hybrid-synced group (never created or modified) | **required** | all ignored, with a warning (membership and ownership are managed on-premises) |

When `-AccessGroupName` is omitted, `-GroupPrefix` itself defaults to a value based on
`-AccessGroupType` — `UDLRAo1P` (DistributionList), `USRAo1P` (MailEnabledSecurityGroup), or
`Um365RAo1P` (M365Group) — rather than one fixed string; pass `-GroupPrefix` explicitly to
override it.

```powershell
# Default: an EXO-only distribution list as the scope:
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -Members 'shared@contoso.com' -Role 'Mail.Send'

# Microsoft 365 group as the scope instead:
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -AccessGroupType M365Group `
    -Members 'shared@contoso.com' -Role 'Mail.Send'

# Reference an existing on-prem/hybrid-synced mail-enabled security group (not created; members untouched):
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -AccessGroupType MailEnabledSecurityGroup `
    -AccessGroupName 'OnPrem-MailApp-Scope' -Role 'Mail.Send'
```

`Set-`, `Test-`, and `Remove-RBAC4AppEntry`, `New-RBAC4AppConfig`, and
`Convert-ApplicationAccessPolicyToRBAC` accept the same `-AccessGroupType` and share the same
`-GroupPrefix` naming convention. `Remove-RBAC4AppEntry` never deletes a `MailEnabledSecurityGroup`
(it only detaches this app's role assignments) and uses `Remove-DistributionGroup` for a
`DistributionList`.

Returns a summary `[pscustomobject]` (resolved identity, group name, normalized roles, assignment
names, `Warnings`, `Errors`) and also exports it to `$env:TEMP\<name>_<timestamp>.clixml`.

### Get-RBAC4AppEntry

Returns EXO management role assignments for Application roles (`Application *`). With no arguments
it returns all of them; filter by application and/or role, plus optional `-Enabled`.

```powershell
Get-RBAC4AppEntry                                            # every application-role assignment
Get-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -Role 'Mail.Send'
Get-RBAC4AppEntry -AppId '11111111-2222-3333-4444-555555555555' | Format-Table Name,Role,Scope
```

> `Get-ManagementRoleAssignment` has no `-App` parameter, so role filtering uses native `-Role`
> while the application filter is applied client-side against each assignment's `RoleAssigneeName`
> and `Name`.

### Get-RegisteredAppWithPermission

Returns one row per distinct registered application that already holds one or more Exchange Online
Application-role assignments. By default it inventories the full set of roles supported by
`New-RBAC4AppEntry`; you can narrow it with `-Role`.

```powershell
Get-RegisteredAppWithPermission
Get-RegisteredAppWithPermission -Role 'Mail.Send'
```

### Test-RBAC4AppEntry

Read-only check that an application has every component `New-RBAC4AppEntry` provisions: the
resolvable service principal, the scoped Unified Group, the Exchange Online service principal
pointer, and one role assignment per role (looked up by the deterministic assignment name). It
mirrors `New-RBAC4AppEntry`'s `-Role` / `-GroupPrefix` defaults and optionally verifies `-Members`
against the group's membership. Returns a summary `[pscustomobject]` with per-component flags
(`ServicePrincipalExists`, `ScopeGroupExists`, `ExoServicePrincipalExists`), the
expected/found/missing role assignments, a `Missing` list, and an overall `IsValid`.

```powershell
Test-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App'
Test-RBAC4AppEntry -AppId '11111111-2222-3333-4444-555555555555' -Role 'Mail.Send','Calendars.Read' -Members 'shared@contoso.com'
```

### Convert-ApplicationAccessPolicyToRBAC

Migrates legacy Exchange Online Application Access Policies to RBAC for Applications: derives the
roles from the app's granted Microsoft Graph application permissions, copies the original scope
group's members, and delegates to `New-RBAC4AppEntry`. `DenyAccess` policies are skipped.

```powershell
Convert-ApplicationAccessPolicyToRBAC -WhatIf -Verbose
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

```powershell
# By display name:
$yml = New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' `
           -Role 'Mail.Send' -Members 'shared@contoso.com' -OutputPath C:\rbac-configs

# By AppId, distribution-list scope:
$yml = New-RBAC4AppConfig -AppId '11111111-2222-3333-4444-555555555555' `
           -Role 'Mail.Send','Calendars.Read' `
           -AccessGroupType DistributionList `
           -Members 'shared@contoso.com' -OutputPath C:\rbac-configs

# By SP object id, referencing an existing on-prem group:
$yml = New-RBAC4AppConfig -SpObjectId '11111111-2222-3333-4444-555555555555' `
           -Role 'Mail.Send' -AccessGroupType MailEnabledSecurityGroup `
           -AccessGroupName 'OnPrem-MailApp-Scope' -OutputPath C:\rbac-configs

# Same as the first example, written as JSON instead:
$json = New-RBAC4AppConfig -RegisteredAppName 'Contoso Mail App' `
           -Role 'Mail.Send' -Members 'shared@contoso.com' -Format Json -OutputPath C:\rbac-configs
```

Returns the path to the written config file (`.yml` or `.json`). Pass `-WhatIf` to preview the
output path and content without writing the file. The config schema is identical between formats —
`-Format` only changes serialisation and the file extension.

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

```
src/EXORBACforAppManagement/
  EXORBACforAppManagement.psd1          # manifest
  EXORBACforAppManagement.psm1          # loader: dot-sources Private + Public, exports Public only
  Public/                        # 13 exported functions (see table above)
  Private/                       # Get-SafeName, Get-NormalizeRole, ConvertTo-AppRole, ConvertTo/From-RBAC4AppYaml
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
- **Test** runs Pester and writes `testResults.xml` (NUnit).
- **Build** assembles the module into `output/EXORBACforAppManagement` and validates the manifest.

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
both role tables (`$roleMap` in `Private/Get-NormalizeRole.ps1` and `$shortRoleMap` in
`Public/New-RBAC4AppEntry.ps1`). See [`AGENTS.md`](AGENTS.md) for deeper architecture notes.

## License

Licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
