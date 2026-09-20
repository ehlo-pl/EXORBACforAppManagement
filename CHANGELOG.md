# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `New-RBAC4AppEntry`, `Set-RBAC4AppEntry`, and `Invoke-RBAC4AppConfig` now return `MembersFinal`:
  the scope group's complete membership (pre-existing members plus any added this run), alongside
  the existing `MembersAdded`/`MembersRequested`. Populated for all `-AccessGroupType` values,
  including `MailEnabledSecurityGroup` (read-only, informational).
- `Get-RegisteredAppWithPermission` now returns `ScopeGroupNames` (the recipient scope group each
  app's assignments are bound to) and `ScopeGroupMembers` (that group's resolved membership).
  Resolution tries `Get-UnifiedGroup`/`Get-UnifiedGroupLinks` first (M365Group), then
  `Get-DistributionGroup`/`Get-DistributionGroupMember` (DistributionList or
  MailEnabledSecurityGroup); an unresolvable scope group is skipped with a warning. Scope groups
  are cached per call, so one shared by multiple applications is only read once.

### Fixed
- `Get-RegisteredAppWithPermission` no longer fails with "Authentication needed. Please call
  Connect-MgGraph." when run in an Exchange-Online-only session. Microsoft Graph is now optional:
  without a connected session (or if connectivity is lost partway through), the function writes a
  warning and returns Exchange-Online-only details (`DisplayName`/`AppId`/`ServicePrincipalId`
  unresolved) for the affected applications instead of throwing.
- `Register-EXOServicePrincipal` now checks whether a matching EXO service principal already
  exists (by AppId, then DisplayName) before calling `New-ServicePrincipal`, skipping creation and
  returning the existing object with a warning when one is found. It is now safe to call
  unconditionally, matching how `New-RBAC4AppUnifiedGroup`/`New-RBAC4AppDistributionGroup` already
  check before creating; previously it always attempted creation and relied on its callers to check
  first.
- `New-RBAC4AppEntry` and `Invoke-RBAC4AppConfig` now check whether a role assignment with the
  deterministic name already exists (via `Get-ManagementRoleAssignment`) before calling
  `New-ManagementRoleAssignment`, so re-running against an already-provisioned application no
  longer throws. An assignment already scoped to the target group is left alone (a warning notes
  it was skipped); one scoped to a different group is also left alone, with a warning pointing at
  `Set-RBAC4AppEntry` to re-scope it. Requested members are still added to the group either way.

## [0.6.4] - 2026-09-20

### Changed
- Renamed output properties across `New-RBAC4AppEntry`, `Remove-RBAC4AppEntry`,
  `Test-RBAC4AppEntry`, `Set-RBAC4AppEntry`, and `Invoke-RBAC4AppConfig` for consistency with the
  generalized `-AccessGroupType` (a scope group is not always an M365 Unified Group):
  `UnifiedGroupName` → `ScopeGroupName`, `UnifiedGroupExists`/`UnifiedGroupExisted` →
  `ScopeGroupExists`/`ScopeGroupExisted`, `UnifiedGroupCreated` → `ScopeGroupCreated`. **Breaking
  change** for any script consuming these result objects by the old property names.
- `New-RBAC4AppEntry`, `Set-RBAC4AppEntry`, and `Invoke-RBAC4AppConfig` now warn (and record the
  warning in `Warnings`) whenever `-ManagedBy` or `-BootstrapMember` is set to a non-default value
  for a `MailEnabledSecurityGroup` scope, matching the existing `-Members`-ignored warning — since
  on-prem/hybrid-synced groups are never created or modified by this module, all three
  group-modifying parameters are silently ignored otherwise.

## [0.6.1] - 2026-09-20

### Added
- **Two-session workflow** — workaround for the MSAL/WAM assembly conflict that prevents
  `Microsoft.Graph` and `ExchangeOnlineManagement` from coexisting in a single PowerShell process.
  - `New-RBAC4AppConfig` — Graph-session function. Resolves the Entra service principal
    (`Get-MgServicePrincipal`) and writes a plain-text YAML handoff file containing the resolved
    identity and all RBAC provisioning parameters. Accepts the same `ByName`/`ByAppId`/`BySpObjectId`
    parameter sets as `New-RBAC4AppEntry`. Calls no EXO cmdlets.
  - `Invoke-RBAC4AppConfig` — EXO-session function. Reads the YAML file produced by
    `New-RBAC4AppConfig` and provisions scope group, EXO service principal, and role assignments
    using only `ExchangeOnlineManagement` cmdlets. Returns the same summary object shape as
    `New-RBAC4AppEntry`. Calls no Graph cmdlets.
  - Private helpers `ConvertTo-RBAC4AppYaml` / `ConvertFrom-RBAC4AppYaml` — dependency-free
    YAML serialiser/deserialiser for the fixed config schema (no `powershell-yaml` required).

### Changed
- `New-RBAC4AppDistributionGroup` — added `-AppName` (mandatory, new `ByAppName` default parameter
  set) and `-Prefix` (default `UDLRAo1`) as an alternative to the existing `-Name` parameter. The
  group name is derived as `"$Prefix-$AppName"`. The `-Name` parameter set (`ByName`) is unchanged
  and is still used by the internal `New-RBAC4AppScopeGroup` dispatcher.
- `build.ps1` — output directory now follows `output/<version>/<ModuleName>` (e.g.
  `output/0.6.1/EXORBACforAppManagement`); version is read from the module manifest at build time
  via `Import-PowerShellDataFile`. `Invoke-Publish` updated to match.

## [0.6.0] - 2026-09-19

### Changed
- Renamed the RBAC-for-App functions from the `RBACforApp` form to `RBAC4App`:
  `New-RBAC4AppEntry`, `Get-RBAC4AppEntry`, `Set-RBAC4AppEntry`, `Test-RBAC4AppEntry`,
  `Remove-RBAC4AppEntry`, `New-RBAC4AppUnifiedGroup`, and `New-RBAC4AppDistributionGroup`
  (and the private helper `New-RBAC4AppScopeGroup`). The previous `RBACforApp` names remain
  exported as **aliases**, so existing scripts and pipelines keep working. The module name
  (`EXORBACforAppManagement`) is unchanged. Functions without `RBACforApp` in their name
  (`New-RegisteredApp`, `Get-RegisteredAppWithPermission`, `Register-EXOServicePrincipal`,
  `Convert-ApplicationAccessPolicyToRBAC`) are unchanged.

### Added
- `-AccessGroupType` scope selector on `New-`/`Set-`/`Test-`/`Remove-RBAC4AppEntry` and
  `Convert-ApplicationAccessPolicyToRBAC`: `M365Group` (default, unchanged behavior), `DistributionList`
  (an Exchange-Online-only distribution list), or `MailEnabledSecurityGroup` (references an existing
  on-prem/hybrid-synced group — never created, `-AccessGroupName` required, membership left
  on-premises). The EXO role-assignment step is identical for all three; only group
  provisioning/read/membership/teardown differ. `Remove-RBAC4AppEntry` never deletes a
  `MailEnabledSecurityGroup` (it only detaches this app's role assignments) and uses
  `Remove-DistributionGroup` for a `DistributionList`.
- `New-RBAC4AppDistributionGroup` — public helper that ensures/creates and configures the scoped
  Exchange-Online-only distribution list (the `DistributionList` counterpart to
  `New-RBAC4AppUnifiedGroup`), routed to by the private `New-RBAC4AppScopeGroup` dispatcher.
- `Set-RBAC4AppEntry` — reconcile/"make it so" companion to `Test-RBAC4AppEntry` and
  `New-RBAC4AppEntry`. Resolves the application and brings its Exchange Online RBAC components to the
  desired state, changing only what is needed: creates the scoped Unified Group and the Exchange
  Online service principal pointer if missing, adds any requested `-Members` not already in the group
  (additive — never removes members), and ensures one role assignment per role scoped to the target
  group (creating a missing one, or re-scoping one that points elsewhere). An optional
  `-NewGroupPrefix`/`-NewGroupName` moves the role assignments onto a different scoping group (created
  if needed; the old group is left in place). Each change is gated by `SupportsShouldProcess`
  (`ConfirmImpact='High'`) so it is confirmed interactively; under `-WhatIf` nothing is changed.
  Returns a `[pscustomobject]` with the current/target group names, a `GroupChanged` flag, which
  components were created, members added/already-present, role assignments created/re-scoped/unchanged,
  and an overall `IsValid` flag.
- `Remove-RBAC4AppEntry` — safe teardown counterpart to `New-RBAC4AppEntry`. Resolves the
  application, derives the scoped Unified Group name, and removes this app's Exchange Online role
  assignments and the Unified Group — but only after confirming the group is no longer in use (no
  foreign role assignments scoped to it and no members beyond the `-BootstrapMember` placeholder). On
  an unsafe condition it aborts and removes nothing, returning a `[pscustomobject]` summary with a
  `Reason`, the offending foreign assignments / real members, and an `IsRemoved` flag. Leaves the
  shared Exchange Online service principal pointer in place and supports `-WhatIf`/`-Confirm`.
- `Test-RBAC4AppEntry` — read-only validator that confirms a registered application has every
  component `New-RBAC4AppEntry` creates: the resolvable service principal, the scoped Unified
  Group, the Exchange Online service principal pointer, and one role assignment per role (matched by
  the deterministic assignment name). Mirrors `New-RBAC4AppEntry`'s `-Role`/`-GroupPrefix` defaults
  and optionally verifies `-Members` against the group. Returns a `[pscustomobject]` with
  per-component flags, a `Missing` list, and an overall `IsValid`.

## [0.4.1] - 2026-06-07

### Added
- `New-RBACforAppEntry` and `New-RBACforAppUnifiedGroup` now report the Unified Group owner as
  `OwnerRequested` (the `-ManagedBy` input) and `OwnerAdded` (the owner actually applied/in place),
  mirroring the existing `MembersRequested`/`MembersAdded` reporting. The owner is resolved via
  `Get-Recipient` (like members); if it cannot be resolved the requested value is used as-is and a
  warning is emitted.

### Changed
- Renamed the module from `RBACforAppGovern` to **`EXORBACforAppManagement`**. This is a module
  identity rename only (directory, manifest/loader files, and all `-ModuleName` / `Import-Module` /
  `InModuleScope` references); the public function names and the manifest `GUID` are unchanged.
- `New-RBACforAppUnifiedGroup` now returns a summary `[pscustomobject]`
  (`Name`, `DisplayName`, `OwnerRequested`, `OwnerAdded`, `AlreadyExisted`, `Group`) instead of the
  raw Exchange Online group object. The underlying group object remains available via `.Group`.
- `New-RBACforAppUnifiedGroup` now creates the Unified Group with the smallest set of essential
  attributes (DisplayName/Name/Alias, AccessType Private, the creation-only HiddenGroupMembershipEnabled,
  owner, and bootstrap member), then applies the remaining settings (member edit, auto-subscribe,
  calendar subscribe, language, subscription, address-list visibility, connectors) via a single
  follow-up `Set-UnifiedGroup` call.

## [0.4.0] - 2026-06-07

### Added
- `Convert-ApplicationAccessPolicyToRBAC` — migrates legacy Exchange Online Application Access
  Policies to RBAC for Applications. For each `RestrictAccess` policy it resolves the service
  principal, derives the application roles from the app's granted Microsoft Graph application
  permissions (the set Application Access Policies supported, mapped to their App RBAC role names),
  copies the original scope group's members, and delegates to `New-RBACforAppEntry`. `-Role`
  overrides the auto-derived roles; `DenyAccess` policies are skipped (no additive RBAC equivalent).
- Private helper `Get-LegacyScopeRoleMap` — maps each legacy Application Access Policy permission
  scope (e.g. `Mail.Read`, EWS `full_access_as_app`) to its App RBAC role name.

## [0.3.0] - 2026-06-07

### Added
- `Get-RBACforAppEntry -RoleAssigneeType` — filters by the assignment's assignee type. Defaults to
  `ServicePrincipal` so only application (service-principal) assignments are returned; pass `All` for
  every type, or a specific type (`User`, `RoleGroup`, etc.) to narrow.
- `Get-RegisteredAppWithPermission` — inventories distinct registered applications that currently
  hold supported Exchange Online application-role assignments, with optional `-Role` and `-Enabled`
  filtering.

## [0.2.1] - 2026-06-07

### Changed

- `-ManagedBy` now defaults to `GraphAPI-Dummy-owner` (in `New-RBACforAppEntry` and
  `New-RBACforAppUnifiedGroup`). A Unified Group owner must be a valid owner account, distinct from a
  plain member, so the previous `GraphAPI-Dummy` owner default caused `New-UnifiedGroup` to fail.
  `Members` / `BootstrapMember` still default to `GraphAPI-Dummy`.

## [0.2.0] - 2026-06-07

### Added

- `New-RBACforAppUnifiedGroup` — public function that ensures/creates and configures the scoped
  Microsoft 365 Unified Group (extracted from `New-RBACforAppEntry`).
- `Register-EXOServicePrincipal` — public function that creates the Exchange Online service
  principal pointer for an Entra application (extracted from `New-RBACforAppEntry`).
- `.github/workflows/release.yml` — builds, tests, and publishes a GitHub release (with the packaged
  module zip) when a `v*` tag is pushed.

### Changed

- `New-RBACforAppEntry` now delegates Unified Group creation and EXO service principal registration
  to the two new functions instead of inlining that logic. Observable behavior is unchanged.

## [0.1.0] - 2026-06-07

### Added

- Initial `EXORBACforAppManagement` module packaging the `New-RBACforAppEntry`, `New-RegisteredApp`, and
  `Get-RBACforAppEntry` functions, with Pester tests, a `build.ps1` pipeline, and CI.
