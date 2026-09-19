# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`EXORBACforAppManagement` — a PowerShell module for managing Exchange Online (EXO) Role-Based Access
Control for Entra (Azure AD) applications. It packages ten public functions plus shared private
helpers, with Pester tests, a build script, and GitHub Actions CI.

Public functions (each in its own file under `src/EXORBACforAppManagement/Public`):

- **`New-RBAC4AppEntry`** — the core function. Resolves an Entra service principal (SP), creates
  a scoped Microsoft 365 Unified Group, adds members, ensures the EXO service principal exists, and
  creates EXO management role assignments scoped to that group.
- **`New-RegisteredApp`** — creates an Entra application registration via `New-MgApplication` and
  (by default) its service principal via `New-MgServicePrincipal`. Its output exposes
  `AppId`/`ServicePrincipalId` so it can pipe into `New-RBAC4AppEntry`.
- **`Get-RBAC4AppEntry`** — lists EXO management role assignments for application roles (the
  assignments `New-RBAC4AppEntry` makes).
- **`Get-RegisteredAppWithPermission`** — lists distinct registered applications that currently
  hold supported EXO application-role assignments, grouped by app.
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

Together the first three form a create → assign → read flow:
`New-RegisteredApp` → `New-RBAC4AppEntry` → `Get-RBAC4AppEntry`, all sharing the same
`ByName`/`ByAppId`/`BySpObjectId` parameter-set conventions so they compose over the pipeline.

## Repository layout

```
src/EXORBACforAppManagement/
  EXORBACforAppManagement.psd1          # manifest (RootModule -> .psm1, FunctionsToExport = 10 public)
  EXORBACforAppManagement.psm1          # loader: dot-sources Private + Public, exports Public only
  Public/                        # New-RBAC4AppEntry, New-RegisteredApp, Get-RBAC4AppEntry,
                                 # Get-RegisteredAppWithPermission, New-RBAC4AppUnifiedGroup,
                                 # Register-EXOServicePrincipal, Convert-ApplicationAccessPolicyToRBAC,
                                 # Test-RBAC4AppEntry, Remove-RBAC4AppEntry, Set-RBAC4AppEntry
  Private/                       # Get-SafeName, Get-NormalizeRole, ConvertTo-AppRole,
                                 # Get-AppRoleMap, Get-LegacyScopeRoleMap,
                                 # Resolve-AppRolePermissionValue
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
- **Microsoft Graph** (`Connect-MgGraph`) — `Get-MgServicePrincipal` / `Get-MgContext` (all three
  functions; `Get-RBAC4AppEntry` needs Graph only when an app filter is supplied), and
  `New-MgApplication` / `New-MgServicePrincipal` in `New-RegisteredApp` (needs
  `Application.ReadWrite.All`).
- **Exchange Online** (`Connect-ExchangeOnline`) — `New-RBAC4AppEntry` (`Get-UnifiedGroup`,
  `New-UnifiedGroup`, `Set-UnifiedGroup`, `Add-UnifiedGroupLinks`, `New-ServicePrincipal`,
  `Get-Recipient`, `New-ManagementRoleAssignment`) and `Get-RBAC4AppEntry`
  (`Get-ManagementRoleAssignment`).

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

- **SP resolution parameter sets** (`ByName` / `ByAppId` / `BySpObjectId`) are shared by
  `New-RBAC4AppEntry` and `Get-RBAC4AppEntry`; `New-RegisteredApp` takes a `DisplayName`
  (aliased `Name`/`RegisteredAppName`). Ambiguous name matches error out and tell the caller to use
  `-AppId`/`-SpObjectId`. AppId/SpObjectId are GUID-validated via `[ValidatePattern]`.

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

- **Scope group type (`-AccessGroupType`):** `New-`/`Set-`/`Test-`/`Remove-RBAC4AppEntry` and
  `Convert-ApplicationAccessPolicyToRBAC` take `-AccessGroupType` (`M365Group` default,
  `DistributionList`, `MailEnabledSecurityGroup`). The EXO `-RecipientGroupScope` role-assignment step
  is identical for all three (it accepts any group id); only provisioning/read/membership/teardown
  differ. The private `New-RBAC4AppScopeGroup` dispatcher routes creation to
  `New-RBAC4AppUnifiedGroup` (M365Group) or `New-RBAC4AppDistributionGroup` (DistributionList), or
  validates existence only for `MailEnabledSecurityGroup` (on-prem/hybrid-synced: never created,
  `-AccessGroupName` required, membership left on-premises). `Remove-RBAC4AppEntry` never deletes a
  `MailEnabledSecurityGroup` and uses `Remove-DistributionGroup` for a `DistributionList`.

- **`New-RBAC4AppUnifiedGroup` / `Register-EXOServicePrincipal`** are standalone public functions
  (each `SupportsShouldProcess`, `ConfirmImpact='High'`). They hold the Unified Group ensure/create/
  configure logic and the `New-ServicePrincipal` step respectively, so `-WhatIf` propagates into them
  from the orchestrator. `New-RBAC4AppUnifiedGroup` returns a summary `[pscustomobject]`
  (`OwnerRequested`/`OwnerAdded`/`AlreadyExisted`/`Group`); it resolves the `-ManagedBy` owner via
  `Get-Recipient` (like members) for the created group, or reports the existing group's owner when the
  group already exists.

- **Three role lookup tables, kept consistent:** the private `Get-NormalizeRole` normalizes short
  names → `Application <perm>` (validated against `Get-AppRoleMap`); the private `Get-AppRoleMap`
  owns the normalized role → short assignment-name token map used by `New-RBAC4AppEntry` and
  `Get-RegisteredAppWithPermission`; the private `Get-LegacyScopeRoleMap` maps each legacy
  Application Access Policy permission scope (e.g. `Mail.Read`, EWS `full_access_as_app`) to its App
  RBAC role name (a `Get-AppRoleMap` key), and is used by `Convert-ApplicationAccessPolicyToRBAC`
  together with the private `Resolve-AppRolePermissionValue` (resolves a Graph app-role grant's
  `AppRoleId` to its permission value). Update the shared private helpers when adding a role.

- **`Get-RBAC4AppEntry`** filters to `Application *` roles. `Get-ManagementRoleAssignment` has no
  `-App` parameter, so role filtering uses native `-Role` and the app filter is client-side
  (matching the resolved SP's `DisplayName`/`<DisplayName>_SP`/`AppId`/`Id` against each
  assignment's `RoleAssigneeName`/`Name`). The private `ConvertTo-AppRole` normalizes role names by
  prefixing `Application `.

## Conventions

- Pure PowerShell; depends on the Microsoft.Graph and ExchangeOnlineManagement modules being
  installed and connected at runtime (documented, not declared as `RequiredModules`).
- Public functions: comment-based help, the `ByName`/`ByAppId`/`BySpObjectId` parameter sets with
  GUID `[ValidatePattern]`, `[pscustomobject]` output with `Warnings`/`Errors` captured. Keep
  mutating operations wrapped in `$PSCmdlet.ShouldProcess(...)`.
- File name matches function name; Public is exported, Private is not.
- Work is done on feature branches merged via PR into `main` (see git history).
