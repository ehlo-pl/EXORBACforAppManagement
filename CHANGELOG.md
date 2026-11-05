# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed
- **Breaking:** `Get-RegisteredAppWithPermission` (deprecated wrapper) - use
  `Get-RBAC4AppEntry -ByApplication` (add `-ScopeType All` for its old no-scope-filter behavior).
- **Breaking:** the pre-0.6.0 `*-RBACforApp*` aliases (`New-`/`Get-`/`Set-`/`Test-`/`Remove-RBACforAppEntry`,
  `New-RBACforAppUnifiedGroup`, `New-RBACforAppDistributionGroup`); use the `RBAC4App` names. The module
  now exports no aliases.

### Added
- `New-RBAC4AppConfig -Repository <folder>` builds a new config on top of a manually created state file
  named `{AppId}.yaml`, `.yml` or `.json`: settings not given on the command line come from that file,
  then from the defaults. The state file is never modified.
- `New-RBAC4AppConfig` can record descriptive application details in a new optional `Metadata` config
  section: `-OwnerUsername`/`-OwnerDisplayName`, `-TechnicalContactUsername`/`-TechnicalContactDisplayName`,
  `-PCode`, `-CmdbId`, `-Description`, `-NetworkAccessIPRange`, and `-NetworkAccessLocation` (validated
  against the new `locations.txt` shipped at the module root, which holds placeholder names to edit for
  your organization). `Invoke-RBAC4AppConfig` re-validates the section and returns it as `Metadata` in its
  result; it never affects provisioning. The config schema is now `4.2`; `4.1`, `4.0`, and `3.0` files are
  still read. An older copy of `Invoke-RBAC4AppConfig` refuses `4.2` files, so upgrade the module in both
  sessions.
- `build.ps1 -Task Test` now collects Pester code coverage (`coverage.xml`, JaCoCo) and fails below
  `-CoverageThreshold` (default 90%); CI uploads the file with the test results. `scripts/Show-CoverageGaps.ps1` lists the uncovered lines per file.
- `build.ps1 -Task Test` never stops for a ShouldProcess confirmation prompt (`$ConfirmPreference` is
  `None` for the run), so a test missing `-Confirm:$false` cannot hang an interactive build.
- Tests for parameter-validation throws and failure paths (a throwing Exchange Online / Graph cmdlet
  must surface in `Errors`/`Warnings` or as a written error, not crash) across `New-`/`Set-`/`Test-`/
  `Remove-`/`Get-RBAC4AppEntry`, `Invoke-RBAC4AppConfig`, `Convert-ApplicationAccessPolicyToRBAC`,
  `Resolve-ApplicationAccessPolicy`, `New-RegisteredApp`, and `ConvertTo-RBAC4AppRecipientFilter`.
- Tests for the error/edge paths of `Invoke-MsGraphEntraIDApiPerm`, `New-RBAC4AppConfig`,
  `New-RBAC4AppDistributionGroup`, `New-RBAC4AppUnifiedGroup` and `Save-RBAC4AppChangeReferenceRecord`.

### Fixed
- `New-RBAC4AppEntry` and `Invoke-RBAC4AppConfig` no longer emit a second result, with the export failure
  listed in `Errors`, when writing the summary `.clixml` fails after provisioning succeeded. The failure is
  now a warning in the single result, and file names are `<name>_<timestamp>_<8 hex>.clixml`, so runs in the
  same second no longer share a file.
- `New-RBAC4AppConfig` no longer overwrites a config written earlier in the same minute: file names are now
  `rbac4app-<name>-<yyyyMMddHHmmss>-<8 hex>.<ext>`. Globs such as `rbac4app-<name>-*.yml` still match.

### Changed
- **Breaking:** `New-RBAC4AppConfig` now defaults to binding role assignments directly to the scope group
  (`-AssignmentScope RecipientGroupScope`, i.e. `New-ManagementRoleAssignment -RecipientGroupScope`) instead
  of creating a management scope over the group's members; pass `-AssignmentScope ManagementScope` for the
  previous behaviour. Only `-ScopeKind Group` supports direct binding; the other kinds keep using a management
  scope. The config schema is now `4.1` with a new `RbacScope.AssignmentScope` key, which
  `Invoke-RBAC4AppConfig` honours; `4.0`/`3.0` configs (no key) are still read as `ManagementScope`.
  `Convert-ApplicationAccessPolicyToRBAC` writes `ManagementScope`; `Get-RBAC4AppEntry -ExportConfig`
  writes `RecipientGroupScope` for assignments bound directly to a group and `ManagementScope` otherwise.
- Generated config files (`New-RBAC4AppConfig`, `Convert-ApplicationAccessPolicyToRBAC`,
  `Get-RBAC4AppEntry -ExportConfig`, YAML and JSON) now contain only the entries that are actually used:
  keys the selected `ScopeKind`/`AssignmentScope` ignores, empty values, and defaults are left out. A
  missing key now always means its default (shared table in `Private/RBAC4AppDefaults.ps1`, filled in on
  read by the new private `Complete-RBAC4AppConfig`), including for JSON, where missing keys used to read
  as empty. In a schema `4.1` Group config a missing `AssignmentScope` means `RecipientGroupScope`. The
  YAML reader's default `AccessGroupType` for a missing key changed from `M365Group` to `DistributionList`,
  matching the writers.
- **Breaking:** `New-RBAC4AppEntry`, `Set-RBAC4AppEntry`, and `Test-RBAC4AppEntry` take the same
  `-AssignmentScope` parameter with the same `RecipientGroupScope` default (shared private
  `Resolve-RBAC4AppAssignmentScope`). `New-` binds directly to the group and creates no management scope;
  `Set-` now re-binds management-scoped assignments directly to the group (the old management scope is left
  in place) unless `-AssignmentScope ManagementScope` is passed, and moves direct-bound assignments to the new
  group on `-NewGroupName`/`-NewGroupPrefix`; `Test-` skips the management scope check and reports
  management-scoped assignments in the new `RoleAssignmentsManagementScoped` as not valid. Pass
  `-AssignmentScope ManagementScope` to keep the 0.7–0.8 management-scope behaviour. `Remove-RBAC4AppEntry`
  already handled both bindings and is unchanged apart from its help text.
- `Test-RBAC4AppEntry` and `Remove-RBAC4AppEntry` now throw for invalid parameter combinations
  (`-ManagementScopeName` with `-ManagementScopePrefix`, missing `-ScopeRecipients`/`-ScopeFilter`) like
  `New-`/`Set-RBAC4AppEntry`, instead of returning the message in `Errors`. The error-handling convention
  is documented in `AGENTS.md`.
- **Breaking:** renamed `Get-EXORBACforAppRoleAssignment` -> `Get-RBAC4AppRoleAssignment` and
  `Resolve-EXOapplicationAccessPolicy` -> `Resolve-ApplicationAccessPolicy` (no aliases kept); the private
  `ConvertFrom-`/`ConvertTo-EXOApplicationAccessPolicyYaml` became `...-ApplicationAccessPolicyYaml`.
  The module now exports 16 functions.
- Generated-name derivation is centralized in private helpers (`Get-RBAC4AppScopeGroupName`,
  `Get-RBAC4AppRoleAssignmentName`, `Get-RBAC4AppManagementScopeName`) with per-object-type length
  limits and shared defaults (`Private/RBAC4AppDefaults.ps1`) instead of repeated literals.
- Renamed private helpers: `Get-SafeName` -> `Format-RBAC4AppSafeName` (`-Value`/`-MaxLength`),
  `Get-NormalizeRole` -> `ConvertTo-RBAC4AppRoleName` (`-Role`); `ConvertTo-AppRole` was merged into
  the latter, so `Get-RBAC4AppEntry -Role` now validates against the role map like the other cmdlets.
- Config schema version and the config object are now built in one place (`ConvertTo-RBAC4AppConfig`,
  `$script:RBAC4AppConfigSchemaVersion`); `Convert-ApplicationAccessPolicyToRBAC` configs additionally
  carry the default `ChangeReference` and `SeparateScopePerRole` keys.
- `Invoke-RBAC4AppConfig` caps per-role scope group names at 63 characters (was 64), matching the
  direct New-/Set- path; only affects names that were already truncated.

## [0.8.5] - 2026-10-12

### Added
- `Resolve-EXOapplicationAccessPolicy` writes every Exchange Online Application Access Policy to a
  YAML/JSON file with empty `Permissions`; `Invoke-MsGraphEntraIDApiPerm` (Graph session) enriches that
  file with the app's granted Mail/Calendars/Contacts application permissions.
- `Get-EXORBACforAppRoleAssignment`: EXO-only inventory of `Application *` role assignments held by
  service principals, with app name and in-scope recipients resolved.
- `Get-RBAC4AppEntry -ApplicationAccessPolicy` returns the raw `Get-ApplicationAccessPolicy` objects
  (honors `-AppId`) instead of RBAC role assignments.
- `-SeparateScopePerRole` (alias `-SeparateScopePerPermission`) on `New-RBAC4AppConfig` and the
  matching `RbacScope.SeparateScopePerRole` config key: `Invoke-RBAC4AppConfig` creates one scope
  group and management scope per role (`ScopeKind Group` only).

### Fixed
- `New-RBAC4AppConfig` now writes the generated `AccessGroupName` into the config instead of leaving
  it blank, so the config no longer differs from what the direct path would create.
- Windows PowerShell 5.1 path handling in `build.ps1`.

### Changed
- Bumped the module version for the 0.8.5 release.

## [0.8.4] - 2026-10-10

### Changed
- Bumped the module version for the 0.8.4 release.
- Refreshed README and comment-based help to emphasize the management-scope assignment flow.
- Clarified that Microsoft.Graph and ExchangeOnlineManagement should still run in separate
  PowerShell sessions even when specific versions appear to coexist.

## [0.8.3] - 2026-10-10

### Changed
- Bumped the module version for the 0.8.3 release.
- Cleaned up analyzer warnings in RBAC scope resolution and config invocation help.

## [0.8.2] - 2026-10-10

### Changed
- Bumped the module version for the 0.8.2 release.

## [0.8.0] - 2026-10-10

### Added
- **Management-scope based assignments.** Role assignments are now bound to a named Exchange Online
  management scope (`New-ManagementScope -RecipientRestrictionFilter` + `New-ManagementRoleAssignment
  -CustomResourceScope`) instead of directly to the scope group (`-RecipientGroupScope`).
  `New-`/`Set-`/`Test-`/`Remove-RBAC4AppEntry`, `New-RBAC4AppConfig`, and `Invoke-RBAC4AppConfig`
  gained `-ScopeKind` (`Group` default, `Recipients`, `Tag`, `Filter`), `-ManagementScopeName`,
  `-ManagementScopePrefix` (default `MSRAo1P`), `-ScopeRecipients`, `-ScopeTagAttribute` (default
  `CustomAttribute1`), `-ScopeTagValue`, and `-ScopeFilter`, so an app can be scoped to a group's
  members, specific mailboxes/UPNs, a CustomAttribute tag, or a raw OPATH filter.
- New public `New-RBAC4AppManagementScope` (ensure/create/update a management scope; `-NoUpdate`
  only warns on drift) and private helpers `ConvertTo-`/`ConvertFrom-RBAC4AppRecipientFilter`,
  `Get-RBAC4AppManagementScopeName`, `Test-RBAC4AppRecipientFilterEqual`,
  `Get-RBAC4AppAssignmentScopeState`, `Get-RBAC4AppScopeKindWarning`.
- Config schema `4.0` (`RbacScope` gains `ScopeKind`, `ManagementScopeName`,
  `ManagementScopePrefix`, `ScopeRecipients`, `ScopeTagAttribute`, `ScopeTagValue`, `ScopeFilter`).
  `Invoke-RBAC4AppConfig` still accepts `3.0` files, treating them as `ScopeKind: Group`.
- `Get-RBAC4AppEntry`'s per-assignment output gained `EffectiveUserName` and `App` - the raw
  `Get-ManagementRoleAssignment` fields of the same name, passed through as-is. Exchange Online
  leaves both blank/placeholder for application-role assignments in practice, but they are now
  surfaced for completeness rather than silently dropped. `-ByApplication` aggregates them per
  application as sorted, unique, non-blank `EffectiveUserNames`/`Apps` arrays.

### Changed
- **Breaking:** `Get-RBAC4AppEntry` rows gained `ManagementScope`, `ScopeKind`, `ScopeFilter`
  (`-ByApplication`: `ManagementScopeNames`, `ScopeKinds`); legacy group-bound assignments report
  `ScopeKind` `GroupDirect`. `Test-RBAC4AppEntry` treats legacy group-bound assignments as not
  valid; `Set-RBAC4AppEntry` re-binds them to the management scope (the migration path);
  `Remove-RBAC4AppEntry` also removes the management scope when nothing else references it.
  `New-RBAC4AppEntry`/`Invoke-RBAC4AppConfig` warn about, but do not touch, legacy assignments.
- Module version bumped to `0.7.0`; 14 exported functions.
- **`Get-RegisteredAppWithPermission` merged into `Get-RBAC4AppEntry`.** `Get-RBAC4AppEntry` gained
  a `-ByApplication` switch that returns the former app-centric inventory view (one row per
  distinct registered application) instead of the default one-row-per-assignment view.
  `Get-RegisteredAppWithPermission` is now a **deprecated** thin wrapper - `Get-RBAC4AppEntry
  -ByApplication -ScopeType All` - that writes a deprecation warning and will be removed in a
  future release; update scripts to call `Get-RBAC4AppEntry -ByApplication` directly.
- **`Get-RBAC4AppEntry`'s per-assignment output gained `DisplayName`, `AppId`,
  `ServicePrincipalId`, `ScopeGroupType`, and `ScopeMembers`.** Every assignment is now resolved
  back to its Exchange Online service principal pointer (`Get-ServicePrincipal`, one directory read
  per call - no Microsoft Graph session needed) for `AppId`/`ServicePrincipalId`, and its recipient
  scope is resolved via the new private `Resolve-RBAC4AppScope` helper to the real scope group's
  type (`M365Group`/`DistributionList`/`MailEnabledSecurityGroup`) and current membership, not just
  the raw `RecipientWriteScope`/`Scope` fields. **Breaking change** for any script consuming
  `Get-RBAC4AppEntry`'s output positionally or relying on its exact former property list.
- **`Get-RBAC4AppEntry` gained `-ScopeType`**, replacing its previous hard-coded
  `Group`/`CustomRecipientScope` recipient-scope filter (still the default). Pass `-ScopeType All`
  to see every recipient scope, including e.g. Organization-wide application assignments this
  module never creates but a tenant may still have.
- **`Get-RBAC4AppEntry`'s default (no `-Role`) query now covers every `Application *` role**, not
  only the roles known to the private `Get-AppRoleMap` table - matching its own prior default
  behavior, and now also the default for `-ByApplication` (previously
  `Get-RegisteredAppWithPermission` only inventoried the `Get-AppRoleMap` roles by default).
  **Breaking change** if a script relied on the narrower inventory-only default.
- **RBAC4App YAML config schema bumped to `SchemaVersion: "2.0"`.** Scope-group settings
  (`AccessGroupType`, `GroupPrefix`, `AccessGroupName`, `Members`, `ManagedBy`, `BootstrapMember`)
  moved out of `Rbac:` into their own `RbacScope:` section; `Rbac:` now holds only `Roles`. `New-`/
  `Invoke-RBAC4AppConfig` and the private `ConvertTo-`/`ConvertFrom-RBAC4AppYaml` helpers were
  updated accordingly. **Breaking change:** `Invoke-RBAC4AppConfig` now refuses a config whose
  `SchemaVersion` isn't `"2.0"` (including old `"1.0"` files) with an error pointing back at
  `New-RBAC4AppConfig` to regenerate it, rather than silently reading stale/misplaced values.

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
- `Get-RegisteredAppWithPermission`'s `ScopeGroupNames`/`ScopeGroupMembers` (added above) were
  coming back empty on a real tenant: for the `Group` recipient write-scope (what
  `-RecipientGroupScope` actually produces, i.e. every assignment this module creates),
  `CustomRecipientWriteScope` is empty - the scope group name has to be recovered from
  `CustomResourceScope` instead, the name of an auto-created `ManagementScope` object that follows
  the pattern `"<GroupName>_<GUID>"` (confirmed against a real tenant). Added the shared private
  helper `Resolve-RBAC4AppScopeGroupName`, which strips the GUID suffix to recover the group name
  directly (no extra EXO call needed), and wired it into `Get-RegisteredAppWithPermission`,
  `New-RBAC4AppEntry`, and `Invoke-RBAC4AppConfig`.
  **Note:** the remaining direct wrong-field reads (`CustomRecipientWriteScope` for a
  `Group`-scoped assignment) are `Get-RBAC4AppEntry`'s `Scope` column plus the scope-matching
  logic of `Set-`/`Remove-RBAC4AppEntry`; see `TODO.md`.
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
