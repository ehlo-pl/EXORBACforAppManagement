# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`EXORBACforAppManagement` — a PowerShell module for managing Exchange Online (EXO) Role-Based Access
Control for Entra (Azure AD) applications. It packages thirteen public functions plus shared private
helpers, with Pester tests, a build script, and GitHub Actions CI.

Only three functions touch Microsoft Graph at all: `New-RegisteredApp` (creates the Entra app
registration itself), `New-RBAC4AppConfig` (the Graph half of the two-session config workflow, see
below), and `Convert-ApplicationAccessPolicyToRBAC` (reads the app's granted Graph permissions to
derive roles). Every other function — including `New-RBAC4AppEntry` itself — resolves the
application purely through Exchange Online's own service principal pointer
(`Get-ServicePrincipal`, via the private `Resolve-RBAC4AppServicePrincipal`) and needs no Graph
session, working around the MSAL/WAM assembly conflict between `Microsoft.Graph` and
`ExchangeOnlineManagement` in one process.

Public functions (each in its own file under `src/EXORBACforAppManagement/Public`):

- **`New-RBAC4AppEntry`** — the core function. Resolves an Entra service principal (SP), creates
  a scoped Microsoft 365 Unified Group, adds members, ensures the EXO service principal exists, and
  creates EXO management role assignments scoped to that group.
- **`New-RegisteredApp`** — creates an Entra application registration via `New-MgApplication` and
  (by default) its service principal via `New-MgServicePrincipal`. Its output exposes
  `AppId`/`ServicePrincipalId` so it can pipe into `New-RBAC4AppEntry`.
- **`Get-RBAC4AppEntry`** — lists EXO management role assignments for application roles (the
  assignments `New-RBAC4AppEntry` makes). Every row resolves the assignee to its Exchange Online
  service principal pointer (`AppId`/`ServicePrincipalId`, via `Get-ServicePrincipal`) and its
  recipient scope to a real scope group name/type/membership (via the private
  `Resolve-RBAC4AppScope`). `-ByApplication` switches to an app-centric view - one row per
  distinct application instead of one row per assignment - absorbing what used to be the separate
  `Get-RegisteredAppWithPermission` function.
- **`Get-RegisteredAppWithPermission`** — **deprecated**; a thin wrapper around
  `Get-RBAC4AppEntry -ByApplication -ScopeType All` kept for backward compatibility (writes a
  deprecation warning). Update callers to use `Get-RBAC4AppEntry -ByApplication` directly.
- **`New-RBAC4AppUnifiedGroup`** — ensures/creates and configures the scoped Unified Group
  (extracted from `New-RBAC4AppEntry`, which now delegates to it).
- **`New-RBAC4AppDistributionGroup`** — ensures/creates and configures a scoped Exchange-Online-only
  distribution list; the `DistributionList` counterpart to `New-RBAC4AppUnifiedGroup`, returning the
  same summary shape.
- **`Register-EXOServicePrincipal`** — creates the EXO service principal pointer for an Entra app
  (extracted from `New-RBAC4AppEntry`, which now delegates to it).
- **`Convert-ApplicationAccessPolicyToRBAC`** — migrates legacy Application Access Policies to RBAC
  for Applications: reads `Get-ApplicationAccessPolicy` entries, derives roles from the app's granted
  Graph application permissions (mapped via the private `Get-LegacyScopeRoleMap`), copies the scope
  group's members, and delegates to `New-RBAC4AppEntry`.
- **`Test-RBAC4AppEntry`** — read-only validator that checks an application has every component
  `New-RBAC4AppEntry` creates: the resolvable SP, the scoped Unified Group, the EXO service
  principal pointer, and one role assignment per role (by the deterministic name). Mirrors
  `New-RBAC4AppEntry`'s `-Role`/`-GroupPrefix` defaults and optionally verifies `-Members`. Returns
  a `[pscustomobject]` with per-component flags, a `Missing` list, and an overall `IsValid`.
- **`Remove-RBAC4AppEntry`** — safe teardown counterpart to `New-RBAC4AppEntry`. Resolves the
  SP, derives the scoped Unified Group name, and removes this app's EXO role assignments and the
  Unified Group — but only after confirming the group is no longer in use (no foreign role
  assignments scoped to it and no members beyond the `-BootstrapMember` placeholder). Aborts and
  removes nothing on an unsafe condition, returning a `[pscustomobject]` with a `Reason`, the
  offending foreign assignments / real members, and an `IsRemoved` flag. Leaves the shared EXO
  service principal pointer in place; `SupportsShouldProcess` (`ConfirmImpact='High'`).
- **`Set-RBAC4AppEntry`** — reconcile/"make it so" companion to `Test-`/`New-RBAC4AppEntry`.
  Resolves the SP, then brings each component to the desired state changing only what is needed:
  creates the scoped Unified Group and EXO SP pointer if missing (delegating to
  `New-RBAC4AppUnifiedGroup`/`Register-EXOServicePrincipal`), adds requested `-Members` not already
  in the group (additive only), and ensures one role assignment per role scoped to the target group
  (creates a missing one; re-scopes one pointing elsewhere by remove+recreate under the same
  deterministic name). An optional `-NewGroupPrefix`/`-NewGroupName` moves the assignments onto a
  different scoping group (created if needed; old group left in place, members not migrated). Returns
  a `[pscustomobject]` with current/target group names, a `GroupChanged` flag, created-component and
  member add flags, role assignments partitioned into created/re-scoped/unchanged, and an overall
  `IsValid`. `SupportsShouldProcess` (`ConfirmImpact='High'`).
- **`New-RBAC4AppConfig`** / **`Invoke-RBAC4AppConfig`** — a two-session alternative to
  `New-RBAC4AppEntry` for provisioning a brand-new (never-before-registered) application across two
  separate PowerShell sessions. `New-RBAC4AppConfig` is the Graph half: resolves the Entra SP and
  writes a config file (schema version `3.0`, with top-level `Rbac:`/`RbacScope:` sections) in
  either format via `-Format` - YAML (default, `.yml`) or JSON (`.json`), same schema either way.
  `Invoke-RBAC4AppConfig` is the EXO half: reads that file in an Exchange-Online-only session
  (auto-detecting YAML vs. JSON from the `-Path` extension, or forced via its own `-Format`) and
  provisions everything (scope group, EXO SP pointer, role assignments), calling no Graph cmdlet at
  all. Both mirror `New-RBAC4AppEntry`'s idempotency and output shape.

Together the first three form a create → assign → read flow:
`New-RegisteredApp` → `New-RBAC4AppEntry` → `Get-RBAC4AppEntry`, all sharing the same
`ByName`/`ByAppId`/`BySpObjectId` parameter-set conventions so they compose over the pipeline.

## Repository layout

```
src/EXORBACforAppManagement/
  EXORBACforAppManagement.psd1          # manifest (RootModule -> .psm1, FunctionsToExport = 13 public)
  EXORBACforAppManagement.psm1          # loader: dot-sources Private + Public, exports Public only
  Public/                        # New-RBAC4AppEntry, New-RegisteredApp, Get-RBAC4AppEntry,
                                 # Get-RegisteredAppWithPermission, New-RBAC4AppUnifiedGroup,
                                 # New-RBAC4AppDistributionGroup, Register-EXOServicePrincipal,
                                 # Convert-ApplicationAccessPolicyToRBAC, Test-RBAC4AppEntry,
                                 # Remove-RBAC4AppEntry, Set-RBAC4AppEntry, New-RBAC4AppConfig,
                                 # Invoke-RBAC4AppConfig
  Private/                       # Get-SafeName, Get-NormalizeRole, ConvertTo-AppRole,
                                 # Get-AppRoleMap, Get-LegacyScopeRoleMap,
                                 # Resolve-AppRolePermissionValue, Resolve-RBAC4AppServicePrincipal,
                                 # Resolve-RBAC4AppScopeGroupName, Resolve-RBAC4AppScope,
                                 # New-RBAC4AppScopeGroup, ConvertTo-RBAC4AppYaml,
                                 # ConvertFrom-RBAC4AppYaml
tests/                           # Pester v5 tests (one *.Tests.ps1 per area)
build.ps1                        # Init / Clean / Analyze / Test / Build tasks
PSScriptAnalyzerSettings.psd1    # analyzer config (build fails only on Error severity)
.github/workflows/ci.yml         # CI: ./build.ps1 -Task All on ubuntu-latest (pwsh)
.github/workflows/release.yml    # Release: on v* tag -> build + GitHub release with module zip
CHANGELOG.md                     # Keep a Changelog history
```

Build artifacts (`output/`, `testResults.xml`) are git-ignored.

## Releasing

Bump `ModuleVersion` in the manifest and add a `CHANGELOG.md` entry, then push a matching `v*` tag
to `main` (e.g. `git tag v0.2.0; git push origin v0.2.0`). `release.yml` builds/tests the module,
packages `output/EXORBACforAppManagement` into a zip, and creates the GitHub release with generated notes.

## Running / developing

Import the module from source, then call the functions:

```powershell
Import-Module ./src/EXORBACforAppManagement/EXORBACforAppManagement.psd1 -Force

New-RegisteredApp -DisplayName 'Contoso Mail App' -WhatIf -Verbose
New-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App' -WhatIf -Verbose
Get-RBAC4AppEntry -RegisteredAppName 'Contoso Mail App'
```

Prerequisites — live, authenticated sessions must already exist in the shell (the module does NOT
declare these as `RequiredModules`, so it imports without them for unit testing):

- **Microsoft Graph** (`Connect-MgGraph`) — needed by only three functions: `New-RegisteredApp`
  (`New-MgApplication` / `New-MgServicePrincipal`, needs `Application.ReadWrite.All`),
  `New-RBAC4AppConfig` (`Get-MgServicePrincipal` / `Get-MgContext`, to resolve the SP and write the
  config, YAML or JSON), and `Convert-ApplicationAccessPolicyToRBAC` (`Get-MgServicePrincipal` /
  `Get-MgServicePrincipalAppRoleAssignment`, to derive roles from the app's Graph permission
  grants).
- **Exchange Online** (`Connect-ExchangeOnline`) — needed by every other function, including
  `New-RBAC4AppEntry` itself: `Get-ServicePrincipal` resolves the application (via the private
  `Resolve-RBAC4AppServicePrincipal`, matching the pointer `Register-EXOServicePrincipal` creates -
  no Graph lookup), `Get-ConnectionInformation` replaces the tenant-id/current-user reads that used
  to go through `Get-MgContext`, plus the usual `Get-UnifiedGroup`, `New-UnifiedGroup`,
  `Set-UnifiedGroup`, `Add-UnifiedGroupLinks`, `New-ServicePrincipal`, `Get-Recipient`,
  `Get-ManagementRoleAssignment`, and `New-ManagementRoleAssignment`. `Invoke-RBAC4AppConfig` (the
  EXO half of the two-session config workflow) calls no Graph cmdlet at all.

Bootstrapping a never-before-registered application (no EXO service principal pointer exists yet)
without Graph: `New-RBAC4AppEntry` and `Set-RBAC4AppEntry` accept `-AppId`, `-SpObjectId`, and
`-RegisteredAppName` together to register the pointer from explicit identifiers (neither AppId nor
the SP object id can be derived from the other without Graph); otherwise use `New-RBAC4AppConfig` +
`Invoke-RBAC4AppConfig` in two separate sessions. `Test-`/`Remove-RBAC4AppEntry` and
`Get-RBAC4AppEntry`'s application filter have no create path, so they require the pointer to
already exist.

Always validate mutating changes with `-WhatIf` first. `New-RBAC4AppEntry`
(`ConfirmImpact='High'`) and `New-RegisteredApp` (`ConfirmImpact='Medium'`) use
`SupportsShouldProcess`; `Get-RBAC4AppEntry` is read-only. Use `-Verbose` for high-level flow and
`-Debug` for the detailed `New-UnifiedGroup` pre/post-call snapshots in `New-RBAC4AppEntry`.

## Build & test

`build.ps1` is the entry point for all quality gates (CI runs `./build.ps1 -Task All`):

```powershell
./build.ps1                 # All: Init, Clean, Analyze, Test, Build
./build.ps1 -Task Test      # just run the Pester suite
./build.ps1 -Task Analyze   # just run PSScriptAnalyzer
```

- **Init** installs Pester (>=5) and PSScriptAnalyzer if missing (trusts PSGallery first).
- **Analyze** runs PSScriptAnalyzer over `src` using `PSScriptAnalyzerSettings.psd1`; it fails only
  on Error-severity findings (warnings are reported but non-blocking).
- **Test** runs the Pester suite and writes `testResults.xml` (NUnit) for the CI artifact.
- **Build** copies the module to `output/EXORBACforAppManagement` and validates the manifest.

### Test approach

Tests are Pester v5. Helper tests use `InModuleScope EXORBACforAppManagement` to reach the Private
functions. Public-function tests mock the external Graph/EXO cmdlets: because those modules are not
installed in CI, each test defines **global** stub functions for the cmdlets it needs (declaring the
parameters it filters on, e.g. `-Role`) so `Mock -ModuleName EXORBACforAppManagement` can bind and
intercept them. Add new stubs the same way when a function starts calling a new external cmdlet.

## Architecture / key concepts

- **SP resolution is Exchange-Online-only**, via the private `Resolve-RBAC4AppServicePrincipal`
  (used by `New-`/`Set-`/`Test-`/`Remove-`/`Get-RBAC4AppEntry`): it reads `Get-ServicePrincipal`
  (the pointer `Register-EXOServicePrincipal` creates) and matches by `-RegisteredAppName`,
  `-AppId`, or `-SpObjectId` - no Microsoft Graph call. Because the pointer's own `DisplayName`
  carries a `"_SP"` suffix (e.g. `"Contoso_SP"`) while every name this module derives (scope group,
  role assignment) is built from the *application's* name, a by-name lookup matches both the raw
  and `"_SP"`-suffixed forms, and the returned `DisplayName` always has the suffix stripped.
  Ambiguous matches throw and tell the caller to use `-AppId`/`-SpObjectId`; no match returns
  `$null` rather than throwing, so callers can react differently - `Get-`/`Test-`/`Remove-`
  `RBAC4AppEntry` error out (the pointer must already exist), while `New-`/`Set-RBAC4AppEntry` fall
  back to bootstrapping a brand-new pointer when the caller supplied `-AppId`, `-SpObjectId`, and
  `-RegisteredAppName` all together (neither identifier can be derived from the other without
  Graph). `New-RegisteredApp` separately takes a `DisplayName` (aliased `Name`/`RegisteredAppName`)
  for its own Graph-based app creation. AppId/SpObjectId are GUID-validated via `[ValidatePattern]`.

- **`New-RBAC4AppEntry` workflow:** resolve SP → ensure Unified Group (delegated to
  `New-RBAC4AppUnifiedGroup`) → add members → ensure EXO service principal (delegated to
  `Register-EXOServicePrincipal`) → one `New-ManagementRoleAssignment` per role (scoped to the
  Unified Group via `-RecipientGroupScope`). Unified Group name is `"{GroupPrefix}-{SP.DisplayName}"`
  sanitized by the private `Get-SafeName`. Output is one `[pscustomobject]` summary, also exported to
  `$env:TEMP\<name>_<timestamp>.clixml`; per-item errors are surfaced in `Errors`, not thrown. The
  summary reports the owner as `OwnerRequested`/`OwnerAdded` (read from the
  `New-RBAC4AppUnifiedGroup` result) alongside `MembersRequested`/`MembersAdded`. The orchestrator
  captures the delegated functions' warnings via `-WarningVariable` to keep the summary `Warnings`
  (e.g. the group "already exists" note).

- **Scope group type (`-AccessGroupType`):** `New-`/`Set-`/`Test-`/`Remove-RBAC4AppEntry`,
  `New-RBAC4AppConfig`, and `Convert-ApplicationAccessPolicyToRBAC` take `-AccessGroupType`
  (`DistributionList` default, `M365Group`, `MailEnabledSecurityGroup`). The EXO
  `-RecipientGroupScope` role-assignment step is identical for all three (it accepts any group id);
  only provisioning/read/membership/teardown differ. The private `New-RBAC4AppScopeGroup` dispatcher
  routes creation to `New-RBAC4AppUnifiedGroup` (M365Group) or `New-RBAC4AppDistributionGroup`
  (DistributionList), or validates existence only for `MailEnabledSecurityGroup`
  (on-prem/hybrid-synced: never created, `-AccessGroupName` required, membership left
  on-premises). `Remove-RBAC4AppEntry` never deletes a `MailEnabledSecurityGroup` and uses
  `Remove-DistributionGroup` for a `DistributionList`.

- **`-GroupPrefix` naming convention:** when `-AccessGroupName` is not supplied, `-GroupPrefix`
  itself defaults to a type-dependent value rather than a fixed string - `'UDLRAo1P'`
  (DistributionList), `'USRAo1P'` (MailEnabledSecurityGroup), or `'Um365RAo1P'` (M365Group) -
  computed at the top of each function's `process`/`begin` block via
  `if (-not $PSBoundParameters.ContainsKey('GroupPrefix')) { $GroupPrefix = switch ($AccessGroupType) {...} }`.
  This is shared verbatim (originally introduced in `New-RBAC4AppConfig`) by `New-`/`Set-`/
  `Test-`/`Remove-RBAC4AppEntry` and `Convert-ApplicationAccessPolicyToRBAC` (2-way switch there,
  since it has no `MailEnabledSecurityGroup` option). An explicit `-GroupPrefix` always wins.

- **`New-RBAC4AppUnifiedGroup` / `Register-EXOServicePrincipal`** are standalone public functions
  (each `SupportsShouldProcess`, `ConfirmImpact='High'`). They hold the Unified Group ensure/create/
  configure logic and the `New-ServicePrincipal` step respectively, so `-WhatIf` propagates into them
  from the orchestrator. `New-RBAC4AppUnifiedGroup` returns a summary `[pscustomobject]`
  (`OwnerRequested`/`OwnerAdded`/`AlreadyExisted`/`Group`, both `Owner*` fields arrays); `-ManagedBy`
  accepts one or more owners, each resolved independently via `Get-Recipient` (like members) for the
  created group, or reports the existing group's owners when the group already exists. An owner that
  cannot be resolved is still passed through as-is (unlike a member, an owner cannot be skipped - the
  group must be created with at least one `ManagedBy` value).

- **Three role lookup tables, kept consistent:** the private `Get-NormalizeRole` normalizes short
  names → `Application <perm>` (validated against `Get-AppRoleMap`); the private `Get-AppRoleMap`
  owns the normalized role → short assignment-name token map used by `New-RBAC4AppEntry`.
  `Get-RBAC4AppEntry` normalizes `-Role` via the simpler private `ConvertTo-AppRole` (prefixes
  `Application ` without validating against the map) and, when `-Role` is omitted, queries every
  `Application *` role rather than only the ones `Get-AppRoleMap` knows; the
  private `Get-LegacyScopeRoleMap` maps each legacy
  Application Access Policy permission scope (e.g. `Mail.Read`, EWS `full_access_as_app`) to its App
  RBAC role name (a `Get-AppRoleMap` key), and is used by `Convert-ApplicationAccessPolicyToRBAC`
  together with the private `Resolve-AppRolePermissionValue` (resolves a Graph app-role grant's
  `AppRoleId` to its permission value). Update the shared private helpers when adding a role.

- **`Get-RBAC4AppEntry`** filters to `Application *` roles. `Get-ManagementRoleAssignment` has no
  `-App` parameter, so role filtering uses native `-Role` and the app filter is client-side
  (matching the resolved SP's `DisplayName`/`<DisplayName>_SP`/`AppId`/`Id` against each
  assignment's `RoleAssigneeName`/`Name`). The private `ConvertTo-AppRole` normalizes role names by
  prefixing `Application`. `-ScopeType` (default `Group`,`CustomRecipientScope`; pass `All` for
  every recipient scope) replaces what used to be a hard-coded scope filter. Every returned row
  (per-assignment or, with `-ByApplication`, per-application) is enriched via a single
  `Get-ServicePrincipal` directory read (`DisplayName`/`AppId`/`ServicePrincipalId`, matched by
  exact assignee name - the same both-forms `_SP` rule `Resolve-RBAC4AppServicePrincipal` uses) and
  via the private `Resolve-RBAC4AppScope` (wraps `Resolve-RBAC4AppScopeGroupName`, adds a
  `Get-UnifiedGroup`/`Get-DistributionGroup` group-type probe and membership read, cached per
  distinct scope name for the call). `-ByApplication` groups the enriched per-assignment rows by
  assignee - this is the former standalone `Get-RegisteredAppWithPermission` function, now a
  deprecated wrapper (`Get-RBAC4AppEntry -ByApplication -ScopeType All`) around this switch. Each
  row also carries `EffectiveUserName`/`App` straight from the raw `Get-ManagementRoleAssignment`
  object (Exchange Online typically leaves both blank/placeholder for application-role
  assignments); `-ByApplication` aggregates them per application as `EffectiveUserNames`/`Apps`
  (sorted, unique, non-blank).

## Conventions

- Pure PowerShell; depends on the Microsoft.Graph and ExchangeOnlineManagement modules being
  installed and connected at runtime (documented, not declared as `RequiredModules`).
- Public functions: comment-based help, the `ByName`/`ByAppId`/`BySpObjectId` parameter sets with
  GUID `[ValidatePattern]`, `[pscustomobject]` output with `Warnings`/`Errors` captured. Keep
  mutating operations wrapped in `$PSCmdlet.ShouldProcess(...)`.
- File name matches function name; Public is exported, Private is not.
- Work is done on feature branches merged via PR into `main` (see git history).
