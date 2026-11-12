# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`EXORBACforAppManagement` — a PowerShell module for managing Exchange Online (EXO) Role-Based Access
Control for Entra (Azure AD) applications. It packages fifteen public functions plus shared private
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
  a scope source when needed (distribution list by default, or M365/mail-enabled security group),
  ensures the EXO service principal (and, for `-AssignmentScope ManagementScope`, the management scope)
  exists, and creates EXO management role assignments bound directly to the scope group (default) or
  to that management scope.
- **`New-RegisteredApp`** — creates an Entra application registration via `New-MgApplication` and
  (by default) its service principal via `New-MgServicePrincipal`. Its output exposes
  `AppId`/`ServicePrincipalId` so it can pipe into `New-RBAC4AppEntry`.
- **`Get-RBAC4AppEntry`** — lists EXO management role assignments for application roles (the
  assignments `New-RBAC4AppEntry` makes), one `RBAC4App.Entry` row per assignment. Every row
  resolves the assignee to its Exchange Online service principal pointer
  (`AppId`/`ServicePrincipalId`, via `Get-ServicePrincipal`) and its recipient scope to a real scope
  group name/type/membership (via the private `Resolve-RBAC4AppScope`). A pure read since 0.9.0:
  `-ByApplication`, `-ApplicationAccessPolicy`, `-ExportConfig`/`-ExportPath`/`-ExportFormat`, and
  `SupportsShouldProcess` were removed (see the two functions below).
- **`Get-RBAC4AppApplication`** — app-centric inventory: groups `RBAC4App.Entry` rows (piped, or
  fetched itself with the `Get-RBAC4AppEntry` parameters) into one `RBAC4App.Application` row per
  assignee (`RoleAssigneeType` + `RoleAssigneeName`). Replaces `Get-RBAC4AppEntry -ByApplication`
  (which had absorbed the former `Get-RegisteredAppWithPermission`).
- **`Export-RBAC4AppConfig`** — writes piped `RBAC4App.Entry` rows as schema-4.4 configs for
  `Invoke-RBAC4AppConfig` (per assignment, or `-PerApplication`); never reads EXO. Collects in
  `process`, writes in `end`; `SupportsShouldProcess` (`ConfirmImpact='Low'`), `-PassThru`. Refuses
  guessed data without `-Force`: a `ServicePrincipalIdSource` of `NameHeuristic`, or an unreadable
  scope group (`ScopeGroupResolved` `$false`), which `-Force` exports as a reference-only
  `HybridMailEnabledSecurityGroup` with no members (never a type guessed from the group-name prefix).
  Replaces `Get-RBAC4AppEntry -ExportConfig`.
- **`New-RBAC4AppUnifiedGroup`** — ensures/creates and configures the scoped Unified Group used
  when `-AccessGroupType M365Group` (extracted from `New-RBAC4AppEntry`, which now delegates to it).
- **`New-RBAC4AppDistributionGroup`** — ensures/creates and configures a scoped Exchange-Online-only
  mail-enabled security group (`-GroupType Security`, default - `CloudMailEnabledSecurityGroup`) or
  distribution list (`-GroupType Distribution` - `DistributionList`); the counterpart to `New-RBAC4AppUnifiedGroup`, returning the
  same summary shape.
- **`New-RBAC4AppManagementScope`** — ensures an EXO management scope exists with a given
  `RecipientRestrictionFilter`: creates it, updates it on drift (`Set-ManagementScope`), or leaves an
  equivalent one alone (`-NoUpdate` only warns). Used by every function that binds role assignments.
- **`Register-EXOServicePrincipal`** — creates the EXO service principal pointer for an Entra app
  (extracted from `New-RBAC4AppEntry`, which now delegates to it).
- **`Convert-ApplicationAccessPolicyToRBAC`** — migrates legacy Application Access Policies to RBAC
  for Applications: reads `Get-ApplicationAccessPolicy` entries, derives roles from the app's granted
  Graph application permissions (mapped via the private `Get-LegacyScopeRoleMap`), and writes
  config files for `Invoke-RBAC4AppConfig` (it provisions nothing itself). Every config keeps the
  policy's existing scope group: `AccessGroupName` = the policy's `ScopeName` verbatim,
  `AccessGroupType: HybridMailEnabledSecurityGroup` (reference-only - validated via `Get-Recipient`, never
  created, renamed/sanitized, or re-membered) and `AssignmentScope: RecipientGroupScope`. A policy
  without `ScopeName` is an error. `-AccessGroupType`/`-GroupPrefix`/`-ManagedBy` are deprecated
  no-ops (warning when supplied). The end-to-end test in its test file pins this by feeding the
  generated config to `Invoke-RBAC4AppConfig` and asserting no group cmdlet mutates the group.
- **`Test-RBAC4AppEntry`** — read-only validator that checks an application has every component
  `New-RBAC4AppEntry` creates: the resolvable SP, the scope source, the management scope, the EXO
  service principal pointer, and one role assignment per role (by the deterministic name). Mirrors
  `New-RBAC4AppEntry`'s `-Role`/`-GroupPrefix` defaults and optionally verifies `-Members`. Returns
  a `[pscustomobject]` with per-component flags, a `Missing` list, and an overall `IsValid`.
- **`Remove-RBAC4AppEntry`** — safe teardown counterpart to `New-RBAC4AppEntry`. Resolves the
  SP, derives the scope group and management scope names, and removes this app's EXO role assignments,
  management scope, and scope group — but only after confirming the scope is no longer in use (no foreign role
  assignments scoped to it and no members beyond the `-BootstrapMember` placeholder). Own vs. foreign
  is exact (private `Resolve-RBAC4AppAssignee` + `Test-RBAC4AppAssigneeMatch`, as in
  `Get-RBAC4AppEntry`); an unresolved or name-heuristic assignee counts as foreign. Aborts and
  removes nothing on an unsafe condition, returning a `[pscustomobject]` with a `Reason`, the
  offending foreign assignments / real members, and an `IsRemoved` flag. Leaves the shared EXO
  service principal pointer in place; `SupportsShouldProcess` (`ConfirmImpact='High'`).
- **`Set-RBAC4AppEntry`** — reconcile/"make it so" companion to `Test-`/`New-RBAC4AppEntry`.
  Resolves the SP, then brings each component to the desired state changing only what is needed:
  creates the scope group and EXO SP pointer if missing (delegating to
  `New-RBAC4AppScopeGroup`/`Register-EXOServicePrincipal`), adds requested `-Members` not already
  in the group (additive only), and ensures one role assignment per role scoped to the target management scope
  (creates a missing one; re-scopes one pointing elsewhere by remove+recreate under the same
  deterministic name). An optional `-NewGroupPrefix`/`-NewGroupName` moves the assignments onto a
  different scoping group (created if needed; old group left in place, members not migrated). A
  pre-0.9.0 guard stops a defaults-only run (no `-AccessGroupType`/`-AccessGroupName`/`-GroupPrefix`)
  for an app that still has its `UDLRAo1P-*` distribution list but no `USRACo1P-*` group: no
  change, an error, and `LegacyGroupName` set. Returns
  a `[pscustomobject]` with current/target group names, a `GroupChanged` flag, created-component and
  member add flags, role assignments partitioned into created/re-scoped/unchanged, and an overall
  `IsValid`. `SupportsShouldProcess` (`ConfirmImpact='High'`).
- **`New-RBAC4AppConfig`** / **`Invoke-RBAC4AppConfig`** — a two-session alternative to
  `New-RBAC4AppEntry` for provisioning a brand-new (never-before-registered) application across two
  separate PowerShell sessions. `New-RBAC4AppConfig` is the Graph half: resolves the Entra SP and
  writes a config file (schema version `4.4` - `Invoke-RBAC4AppConfig` accepts only `4.4`; `New-RBAC4AppConfig -Repository` state files may still be 3.0-4.4, and in a pre-4.4 file an absent `AccessGroupType` means `DistributionList`; top-level `Rbac:`/`RbacScope:` sections, a `Metadata:` section for descriptive fields and `ChangeReference`, `TenantId` inside `Application:` (informational; a legacy top-level key is still read), a `Runtime:` section holding `GeneratedAt` (top-level before 4.3), and - from `Convert-ApplicationAccessPolicyToRBAC` only - a `ConversionResult:` section) in
  either format via `-Format` - YAML (default, `.yml`) or JSON (`.json`), same schema either way.
  `Invoke-RBAC4AppConfig` is the EXO half: reads that file in an Exchange-Online-only session
  (auto-detecting YAML vs. JSON from the `-Path` extension, or forced via its own `-Format`) and
  provisions everything (scope group, EXO SP pointer, role assignments), calling no Graph cmdlet at
  all. Both mirror `New-RBAC4AppEntry`'s idempotency and output shape.

Three former public functions are now **private** (in `Private/`, not exported, called by no other
function; their tests reach them through a module-scoped command reference -
`& (Get-Module EXORBACforAppManagement) { Get-Command -Name <Function> -CommandType Function }` -
so `Mock -ModuleName`, pipeline input, and `-WhatIf`/`-ErrorVariable` work unchanged):

- **`Get-RBAC4AppRoleAssignment`** — read-only EXO-only listing of every `Application *` role
  assignment held by a service principal; resolves `App`/`RoleAssigneeName` to the application display
  name and `CustomResourceScope` to the in-scope recipients' primary SMTP addresses.
- **`Resolve-ApplicationAccessPolicy`** / **`Invoke-MsGraphEntraIDApiPerm`** — the two halves of
  the policy-export workflow. The former (EXO session) writes every Application Access Policy to a
  YAML/JSON file with empty `Permissions`; the latter (Graph session) reads that file and fills
  `Permissions` with the app's granted Mail/Calendars/Contacts application permissions
  (`SupportsShouldProcess`).

Together the first three form a create → assign → read flow:
`New-RegisteredApp` → `New-RBAC4AppEntry` → `Get-RBAC4AppEntry`, all sharing the same
`ByName`/`ByAppId`/`BySpObjectId` parameter sets. Pipeline binding: in `Get-RBAC4AppEntry` only
`-AppId` binds by property name (a name binds from a plain string, the SP object id only
explicitly), because an object carrying several identity properties - a `New-RegisteredApp` result
or an `RBAC4App.Entry` row - cannot otherwise resolve a parameter set (D7 of
`plans/GET-RBAC4APPENTRY_REBUILD_PLAN.md`; `New-`/`Set-`/`Test-`/`Remove-RBAC4AppEntry` still use
the older all-by-property-name binding). Reads then flow on:
`Get-RBAC4AppEntry | Get-RBAC4AppApplication` and `Get-RBAC4AppEntry | Export-RBAC4AppConfig`.

## Repository layout

```
src/EXORBACforAppManagement/
  EXORBACforAppManagement.psd1          # manifest (RootModule -> .psm1, FunctionsToExport = 15 public)
  EXORBACforAppManagement.psm1          # loader: dot-sources Private + Public, exports Public only
  locations.txt                  # valid Metadata.NetworkAccessLocation names (read by Get-RBAC4AppLocationList)
  Public/                        # New-RBAC4AppEntry, New-RegisteredApp, Get-RBAC4AppEntry,
                                 # Get-RBAC4AppApplication, Export-RBAC4AppConfig,
                                 # New-RBAC4AppUnifiedGroup,
                                 # New-RBAC4AppDistributionGroup, Register-EXOServicePrincipal,
                                 # Convert-ApplicationAccessPolicyToRBAC, Test-RBAC4AppEntry,
                                 # Remove-RBAC4AppEntry, Set-RBAC4AppEntry, New-RBAC4AppConfig,
                                 # Invoke-RBAC4AppConfig, New-RBAC4AppManagementScope
  Private/                       # Format-RBAC4AppSafeName, Get-RBAC4AppSafeDisplayName (AppId fallback
                                 # for names with no Exchange-safe chars), Write-RBAC4AppResult (-FailOnError),
                                 # ConvertTo-RBAC4AppRoleName,
                                 # Get-RBAC4AppScopeGroupName, Get-RBAC4AppRoleAssignmentName,
                                 # RBAC4AppDefaults (shared defaults + name-length limits),
                                 # Get-AppRoleMap, Get-LegacyScopeRoleMap,
                                 # Resolve-AppRolePermissionValue, Resolve-RBAC4AppServicePrincipal,
                                 # Resolve-RBAC4AppScopeGroupName, Resolve-RBAC4AppScope,
                                 # New-RBAC4AppScopeGroup, ConvertTo-RBAC4AppYaml,
                                 # ConvertFrom-RBAC4AppYaml, ConvertTo-/ConvertFrom-RBAC4AppRecipientFilter,
                                 # Get-RBAC4AppManagementScopeName, Test-RBAC4AppRecipientFilterEqual,
                                 # Get-RBAC4AppAssignmentScopeState, Get-RBAC4AppScopeKindWarning,
                                 # Resolve-RBAC4AppAssignmentScope, Complete-RBAC4AppConfig,
                                 # Get-RBAC4AppRoleAssignment, Resolve-ApplicationAccessPolicy,
                                 # Invoke-MsGraphEntraIDApiPerm (formerly public),
                                 # Get-RBAC4AppEffectiveUserObjectId (GUID from EffectiveUserName),
                                 # Test-RBAC4AppIPRange (Metadata.NetworkAccessIP4Range/IP6Range),
                                 # ConvertTo-RBAC4AppAccessGroupType, Set-/Test-RBAC4AppScopeGroupSendRestriction,
                                 # Get-RBAC4AppSendRestrictionWarning (scope group send restriction),
                                 # Get-RBAC4AppEntry pipeline: Get-RBAC4AppAssignmentSet,
                                 # Get-RBAC4AppServicePrincipalIndex, Resolve-RBAC4AppAssignee,
                                 # Test-RBAC4AppAssigneeMatch, ConvertTo-RBAC4AppEntryRow,
                                 # ConvertTo-RBAC4AppApplicationRow,
                                 # ConvertTo-RBAC4AppConfigFromEntry, Write-RBAC4AppConfigFile
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
packages `output/<version>/EXORBACforAppManagement` into a zip, and creates the GitHub release with generated notes.

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
- **Build** copies the module to `output/<version>/EXORBACforAppManagement` and validates the manifest.

### Test approach

Tests are Pester v5. Helper tests use `InModuleScope EXORBACforAppManagement` to reach the Private
functions. Public-function tests mock the external Graph/EXO cmdlets: because those modules are not
installed in CI, each test defines **global** stub functions for the cmdlets it needs (declaring the
parameters it filters on, e.g. `-Role`) so `Mock -ModuleName EXORBACforAppManagement` can bind and
intercept them. Add new stubs the same way when a function starts calling a new external cmdlet.

Coverage gate: `./build.ps1 -Task Test` fails below `-CoverageThreshold` (default 90%). After a run,
`./utils/Show-CoverageGaps.ps1 [-Top N]` lists each file's missed line numbers from `coverage.xml`.
Validation throws and failure paths of each public function live in a
`Describe '<Function> ... failure paths'` block at the end of its test file, reusing that file's
main `BeforeEach` fixture.

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

- **`New-RBAC4AppEntry` workflow:** resolve SP → ensure scope group when `-ScopeKind Group`
  (delegated to `New-RBAC4AppScopeGroup`) → add members → ensure EXO service principal (delegated to
  `Register-EXOServicePrincipal`) → for `-AssignmentScope ManagementScope`, ensure the management scope
  (delegated to `New-RBAC4AppManagementScope`) → one `New-ManagementRoleAssignment` per role bound
  directly to the group via `-RecipientGroupScope` (default) or to the scope via `-CustomResourceScope`.
  The group steps run only for `-ScopeKind Group`. The scope group name is
  `"{GroupPrefix}-{SP.DisplayName}"` sanitized by the private `Get-RBAC4AppScopeGroupName` (via `Format-RBAC4AppSafeName`). Output is one `[pscustomobject]` summary, also exported to
  `$env:TEMP\<name>_<timestamp>_<8 hex>.clixml` (an export failure is a summary warning); per-item errors are surfaced in `Errors`, not thrown. The
  summary reports the owner as `OwnerRequested`/`OwnerAdded` (read from the
  scope group result) alongside `MembersRequested`/`MembersAdded`. The orchestrator
  captures the delegated functions' warnings via `-WarningVariable` to keep the summary `Warnings`
  (e.g. the group "already exists" note).

- **Config files are sparse:** the private `ConvertTo-RBAC4AppConfig` (every config writer goes
  through it) writes only used, non-empty, non-default entries - except `Metadata`, which is always
  written in full (all eleven keys, `""` when empty; `ConvertTo-RBAC4AppYaml` keeps them via
  `-KeepEmpty`). The `Runtime` section (`OperatorUsername`/`OperatorMachineName` from `[Environment]`, plus
  `CollectedErrors`/`CollectedWarnings` passed via `-CollectedErrors`/`-CollectedWarnings`) is
  likewise always written (empty lists as `[]`) and never used for provisioning. `Complete-RBAC4AppConfig` (called by
  `ConvertFrom-RBAC4AppYaml` and `Invoke-RBAC4AppConfig`) restores the full shape. Both read the
  `$script:RBAC4AppConfigDefaults` table in `RBAC4AppDefaults.ps1` - change a default there, never
  in only one of them. Tests asserting an omitted key use `PSObject.Properties.Name | Should -Not
  -Contain`.

- **State repository:** `New-RBAC4AppConfig -Repository <folder>` reads a manually created
  `{AppId}.yaml`/`.yml`/`.json` via the private `Get-RBAC4AppRepositoryState` and fills every parameter
  not bound on the command line from it (command line, then state file, then defaults). It runs after SP
  resolution, so with `-Repository` the settings validation also runs after the Graph call. The file is
  never written.

- **Assignment binding (`-AssignmentScope`):** `New-`/`Set-`/`Test-RBAC4AppEntry` and
  `New-RBAC4AppConfig` (config key `RbacScope.AssignmentScope`, read by `Invoke-RBAC4AppConfig`) take
  `-AssignmentScope RecipientGroupScope` (default; bound directly to the scope group, no management
  scope; `-ScopeKind Group` only) or `ManagementScope`. The private `Resolve-RBAC4AppAssignmentScope`
  resolves the effective value (non-Group kinds force `ManagementScope`; explicitly asking for
  `RecipientGroupScope` with them throws) and warns when management scope naming is ignored. With
  `RecipientGroupScope`, the `LegacyGroup` state of `Get-RBAC4AppAssignmentScopeState` is the desired
  state and `Target` is the mismatch.

- **Management scopes (`-ScopeKind`):** `New-`/`Set-`/`Test-`/`Remove-RBAC4AppEntry` and both config
  functions take `-ScopeKind` - `Group` (default; filter `MemberOfGroup -eq '<group DN>'`, direct
  members only), `Recipients` (`-ScopeRecipients` → `PrimarySmtpAddress -eq ...` joined by `-or`),
  `Tag` (`-ScopeTagAttribute` default `CustomAttribute1`, `-ScopeTagValue` default the scope name;
  the module never stamps the attribute), or `Filter` (raw `-ScopeFilter` OPATH). The scope name is
  `-ManagementScopeName` or `"{ManagementScopePrefix}-{DisplayName}"` (prefix `MSRAo1P`, via the
  private `Get-RBAC4AppManagementScopeName`, max 64 chars). The private
  `ConvertTo-RBAC4AppRecipientFilter` builds the filter, `ConvertFrom-RBAC4AppRecipientFilter`
  parses it back into a kind (used by `Get-`), `Test-RBAC4AppRecipientFilterEqual` compares filters
  loosely (case/whitespace/parentheses), and `Get-RBAC4AppAssignmentScopeState` classifies an
  existing assignment as `Target`, `LegacyGroup` (bound to a group via `RecipientWriteScope=Group`),
  or `Other`. Under `-AssignmentScope ManagementScope`, `New-RBAC4AppEntry`/`Invoke-RBAC4AppConfig` warn on
  `LegacyGroup` and leave it; `Set-RBAC4AppEntry` re-binds it (in either direction, per
  `-AssignmentScope`); `Test-` reports a mismatch invalid; `Remove-` removes both kinds and the
  management scope (if any) when no other assignment references it.

- **Scope group type (`-AccessGroupType`):** `New-`/`Set-`/`Test-`/`Remove-RBAC4AppEntry`,
  and `New-RBAC4AppConfig` take `-AccessGroupType`
  (`CloudMailEnabledSecurityGroup` default, `DistributionList`, `M365Group`,
  `HybridMailEnabledSecurityGroup`; the legacy name `MailEnabledSecurityGroup` is accepted on input and
  normalized to Hybrid by the private `ConvertTo-RBAC4AppAccessGroupType`; type lists live in
  `RBAC4AppDefaults.ps1` as `$script:RBAC4AppAccessGroupTypes`/`...DistributionGroupTypes`/
  `...CreatableGroupTypes`). The
  management-scope `MemberOfGroup` filter and role-assignment step are identical for all three;
  only provisioning/read/membership/teardown differ. The private `New-RBAC4AppScopeGroup` dispatcher
  routes creation to `New-RBAC4AppUnifiedGroup` (M365Group) or `New-RBAC4AppDistributionGroup`
  (Cloud with `-GroupType Security`, DistributionList with `-GroupType Distribution`), or validates
  existence only for `HybridMailEnabledSecurityGroup`
  (on-prem/hybrid-synced: never created, `-AccessGroupName` required, membership left
  on-premises). `Remove-RBAC4AppEntry` never deletes a `HybridMailEnabledSecurityGroup` and uses
  `Remove-DistributionGroup` for a `CloudMailEnabledSecurityGroup`/`DistributionList`.
  Every group the module creates is send-restricted by the private
  `Set-RBAC4AppScopeGroupSendRestriction` (`RequireSenderAuthenticationEnabled` +
  `AcceptMessagesOnlyFromSendersOrMembers` = resolved owners; no resolvable owner → restriction
  skipped, authentication still required, warning). Existing groups: `Test-RBAC4AppScopeGroupSendRestriction`
  reads the state, `Get-RBAC4AppSendRestrictionWarning` words the warning; New-/Invoke- warn, Set-
  applies (`SendRestrictionApplied`), Test- reports `SendRestricted` (warning only, not `IsValid`).
  Hybrid groups are never touched. On read, `Resolve-RBAC4AppScope` maps a
  `MailUniversalSecurityGroup` to Cloud only when `IsDirSynced` is `$false`, else Hybrid.

- **`-GroupPrefix` naming convention:** when `-AccessGroupName` is not supplied, `-GroupPrefix`
  itself defaults to a type-dependent value rather than a fixed string - `'UDLRAo1P'`
  (DistributionList), `'USRACo1P'` (CloudMailEnabledSecurityGroup), `'USRAHo1P'`
  (HybridMailEnabledSecurityGroup; was `'USRAo1P'`), or `'Um365RAo1P'` (M365Group), via the private
  `Get-RBAC4AppDefaultGroupPrefix` -
  computed at the top of each function's `process`/`begin` block via
  `if (-not $PSBoundParameters.ContainsKey('GroupPrefix')) { $GroupPrefix = switch ($AccessGroupType) {...} }`.
  This is shared verbatim (originally introduced in `New-RBAC4AppConfig`) by `New-`/`Set-`/
  `Test-`/`Remove-RBAC4AppEntry`. An explicit `-GroupPrefix` always wins.
  (`Convert-ApplicationAccessPolicyToRBAC` no longer derives group names - it always keeps the
  policy's `ScopeName` group.)

- **`New-RBAC4AppUnifiedGroup` / `Register-EXOServicePrincipal`** are standalone public functions
  (each `SupportsShouldProcess`, `ConfirmImpact='High'`). They hold the Unified Group ensure/create/
  configure logic and the `New-ServicePrincipal` step respectively, so `-WhatIf` propagates into them
  from the orchestrator. `New-RBAC4AppUnifiedGroup` returns a summary `[pscustomobject]`
  (`OwnerRequested`/`OwnerAdded`/`AlreadyExisted`/`Group`, both `Owner*` fields arrays); `-ManagedBy`
  accepts one or more owners, each resolved independently via `Get-Recipient` (like members) for the
  created group, or reports the existing group's owners when the group already exists. An owner that
  cannot be resolved is still passed through as-is (unlike a member, an owner cannot be skipped - the
  group must be created with at least one `ManagedBy` value).

- **Three role lookup tables, kept consistent:** the private `ConvertTo-RBAC4AppRoleName` normalizes short
  names → `Application <perm>` (validated against `Get-AppRoleMap`); the private `Get-AppRoleMap`
  owns the normalized role → short assignment-name token map used by `New-RBAC4AppEntry`.
  `Get-RBAC4AppEntry` normalizes `-Role` with the same `ConvertTo-RBAC4AppRoleName` and, when `-Role` is omitted, queries every
  `Application *` role rather than only the ones `Get-AppRoleMap` knows; the
  private `Get-LegacyScopeRoleMap` maps each legacy
  Application Access Policy permission scope (e.g. `Mail.Read`, EWS `full_access_as_app`) to its App
  RBAC role name (a `Get-AppRoleMap` key), and is used by `Convert-ApplicationAccessPolicyToRBAC`
  together with the private `Resolve-AppRolePermissionValue` (resolves a Graph app-role grant's
  `AppRoleId` to its permission value). Update the shared private helpers when adding a role.

- **`Get-RBAC4AppEntry`** filters to `Application *` roles (private `Get-RBAC4AppAssignmentSet`).
  `Get-ManagementRoleAssignment` has no `-App` parameter, so role filtering uses native `-Role` and
  the app filter is client-side and exact (private `Test-RBAC4AppAssigneeMatch`: the assignment's
  *resolved* assignee must be the requested SP - object id, or AppId when an object id is missing;
  never a name substring). The private `ConvertTo-RBAC4AppRoleName` normalizes role names.
  `-ScopeType` (ValidateSet of `RecipientWriteScopeType` values plus `All`; default
  `Group`,`CustomRecipientScope`). `begin`/`process`/`end`: EXO is read lazily, once per call (one
  `Get-ServicePrincipal` via `Get-RBAC4AppServicePrincipalIndex`, shared with
  `Resolve-RBAC4AppServicePrincipal -Directory`; one assignment read), however many identities are
  piped; an unresolvable identity is a `Write-Error` per item, a failed read one `Write-Error` per
  call (later items skipped, no retry). Each assignee is resolved by the private
  `Resolve-RBAC4AppAssignee` (object id, exact name, `_SP`-stripped name, then the name heuristic -
  reported as `ServicePrincipalIdSource` `NameHeuristic`), each scope by `Resolve-RBAC4AppScope`
  (reads the management scope via `Get-ManagementScope`, parses its filter into
  `ScopeKind`/`ScopeFilter`, and resolves members - the group's membership for Group kind, the
  listed recipients for Recipients kind, a `Get-Recipient -RecipientPreviewFilter` preview for
  Tag/Filter; a legacy group-bound assignment reports `ScopeKind` `GroupDirect`; an unreadable
  custom recipient scope reports `ScopeKind` `$null` and is never probed as a group; cached per
  distinct scope name for the call; returns its warnings instead of writing them). The private
  `ConvertTo-RBAC4AppEntryRow` is the single source of the row shape (`PSTypeName`
  `RBAC4App.Entry`; adds `ServicePrincipalIdSource`, `ScopeSource`, `ScopeGroupName`,
  `ScopeGroupResolved`, `Warnings`, `Errors`); each distinct warning is written once per call and
  kept on the rows it applies to. `Get-RBAC4AppApplication` (private
  `ConvertTo-RBAC4AppApplicationRow`) and `Export-RBAC4AppConfig` (private
  `ConvertTo-RBAC4AppConfigFromEntry` + `Write-RBAC4AppConfigFile`) work only from those rows. Each
  row also carries `EffectiveUserName`/`App` straight from the raw `Get-ManagementRoleAssignment`
  object (Exchange Online typically leaves both blank/placeholder for application-role
  assignments); `Get-RBAC4AppApplication` aggregates them per application as
  `EffectiveUserNames`/`Apps` (sorted, unique, non-blank). When the resolved `ServicePrincipalId` is empty (typically an incomplete
  `Connect-MgGraph`/directory read), it - and `Test-RBAC4AppEntry`'s `SpObjectId`, and the exported
  config's `Application.SpObjectId` - falls back to the GUID found in `EffectiveUserName` (private
  `Get-RBAC4AppEffectiveUserObjectId`; non-GUID values are never used), with a warning that also lands
  in `Test-`'s `Warnings` / the config's `Runtime.CollectedWarnings`.

## Conventions

- **Error handling (one convention for every public function):**
  1. *Invalid parameters* - a bad combination or a missing required companion (e.g.
     `-ManagementScopeName` with `-ManagementScopePrefix`, `-ScopeKind Recipients` without
     `-ScopeRecipients`) is a terminating `throw` before any work, in `begin`/at the top of `process`
     (New-/Set-/Test-/Remove-RBAC4AppEntry, New-RBAC4AppConfig all behave the same).
  2. *Per-item failures in a function that emits a result object* (New-/Set-/Test-/Remove-RBAC4AppEntry,
     Invoke-RBAC4AppConfig processing, Convert-ApplicationAccessPolicyToRBAC, Invoke-MsGraphEntraIDApiPerm) -
     catch, append the message to `$result.Errors` and still emit the object, so one bad item does not
     stop a pipeline and the caller can inspect what was done.
  3. *Failures before a result object exists* (unreadable/invalid config or policy file, unresolvable
     identity in the read-only `Get-*`/`New-RBAC4AppConfig` functions) - non-terminating `Write-Error`
     followed by `return`.
  Never mix `throw` and `Write-Error` for the same kind of failure within one function.
  4. *`-FailOnError`* (New-/Set-/Remove-RBAC4AppEntry, Invoke-RBAC4AppConfig) - the summary is emitted
     through the private `Write-RBAC4AppResult` from a `finally` block after the per-item try/catch;
     with the switch it also writes one `RBAC4AppOperationFailed` error record when `Errors` is
     non-empty (emitting from `finally` keeps a terminating error from being re-caught into `Errors`).
  5. *Fail closed on safety reads* - an EXO read whose result gates a destructive or create decision
     (Remove's foreign-assignment and member reads, `Get-ServicePrincipal` in
     `Resolve-RBAC4AppServicePrincipal`/`Register-EXOServicePrincipal`, and `Get-RBAC4AppEntry`'s
     `Get-ServicePrincipal`/`Get-ManagementRoleAssignment` reads, whose output feeds exported configs)
     uses `-ErrorAction Stop`; never
     let `SilentlyContinue` turn a read failure into "nothing found". Note: EXO
     `Get-ManagementRoleAssignment` and `Get-ServicePrincipal` have no `-ResultSize` parameter.

- Pure PowerShell; depends on the Microsoft.Graph and ExchangeOnlineManagement modules being
  installed and connected at runtime (documented, not declared as `RequiredModules`).
- Public functions: comment-based help, the `ByName`/`ByAppId`/`BySpObjectId` parameter sets with
  GUID `[ValidatePattern]`, `[pscustomobject]` output with `Warnings`/`Errors` captured. Keep
  mutating operations wrapped in `$PSCmdlet.ShouldProcess(...)`.
- File name matches function name; Public is exported, Private is not.
- Work is done on feature branches merged via PR into `main` (see git history).
