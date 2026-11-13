# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.0] - Unreleased

`Get-RBAC4AppEntry` is split into three single-purpose functions (plan:
`plans/GET-RBAC4APPENTRY_REBUILD_PLAN.md`, findings F1-F10 in `plans/GET-RBAC4APPENTRY_ANALYSIS.md`).
No version had been published, so this is a clean break without deprecation shims.

### Added
- `-Format M365DSC` on `New-RBAC4AppConfig`, `Export-RBAC4AppConfig` and
  `Convert-ApplicationAccessPolicyToRBAC`: writes the YAML config plus a Microsoft365DSC
  configuration script (`.ps1`, same name) with `EXOServicePrincipal`, `EXODistributionGroup`
  (cloud security group / distribution list; other group types are only referenced),
  `EXOManagementScope` and `EXOManagementRoleAssignment` resources. The script authenticates with a
  managed identity, or with `-DscAuthentication Certificate` through `ApplicationId` /
  `CertificateThumbprint` parameters (no secret is written either way), always binds through a management scope (the DSC resource has no
  `RecipientGroupScope`), and takes the scope group's distinguished name as a Configuration
  parameter (pre-filled by `Export-RBAC4AppConfig` when known). `New-RBAC4AppConfig` returns both
  paths; `Export-RBAC4AppConfig -PassThru` and the `Convert-` result gain `DscPath`. The config
  schema is unchanged (4.4).
- `-AccessGroupType CloudMailEnabledSecurityGroup`: an Exchange-Online-only mail-enabled security
  group created by `New-DistributionGroup -Type Security` (default prefix `USRACo1P`). Accepted by
  `New-`/`Set-`/`Test-`/`Remove-RBAC4AppEntry`, `New-RBAC4AppConfig`, and `Invoke-RBAC4AppConfig`.
  `New-RBAC4AppDistributionGroup` gains `-GroupType Security|Distribution` (default `Security`) and
  throws when an existing group of the requested name has a different recipient type.
- Scope groups the module creates (cloud security group, distribution list, Microsoft 365 group) are
  send-restricted: `RequireSenderAuthenticationEnabled $true` and
  `AcceptMessagesOnlyFromSendersOrMembers` = the resolved owners (`-ManagedBy`, default
  `GraphAPI-Dummy-owner`). With no resolvable owner the group is still created, only sender
  authentication is enforced, and a warning is added. Summaries gain `SendRestricted`;
  `Set-RBAC4AppEntry` restricts an existing unrestricted group (`SendRestrictionApplied`);
  `Test-RBAC4AppEntry` reports `SendRestricted` `$false` as a warning (not invalid);
  `New-RBAC4AppEntry`/`Invoke-RBAC4AppConfig` warn on an existing unrestricted group. A hybrid group
  is never changed.
- `New-RBAC4AppConfig` warns (and records in `Runtime.CollectedWarnings`) when a group the module
  will create keeps the default owner, since the send restriction is skipped if that recipient does
  not exist.
- `Get-RBAC4AppApplication`: one `RBAC4App.Application` row per assignee (grouped by
  `RoleAssigneeType` + `RoleAssigneeName`), from piped `Get-RBAC4AppEntry` rows or fetched itself
  with the same parameters. Adds `RoleAssigneeType` and `Warnings`, and warns when an assignee's rows
  disagree on `ServicePrincipalId`. Replaces `Get-RBAC4AppEntry -ByApplication`.
- `Export-RBAC4AppConfig`: writes piped `Get-RBAC4AppEntry` rows as schema-4.4 configs for
  `Invoke-RBAC4AppConfig` (`-Path`, `-Format`, `-PerApplication`, `-PassThru`, `-Force`;
  `-WhatIf`/`-Confirm`). Replaces `Get-RBAC4AppEntry -ExportConfig`/`-ExportPath`/`-ExportFormat`.
  The module now exports 15 functions.
- `Get-RBAC4AppEntry` rows are typed `RBAC4App.Entry` and add `ServicePrincipalIdSource`
  (`ExoPointer`/`EffectiveUserName`/`NameHeuristic`/`None`), `ScopeSource`
  (`ManagementScope`/`Legacy`/`None`), `ScopeGroupName`, `ScopeGroupResolved`, `Warnings`, and
  `Errors` (reserved).
- `Get-RBAC4AppEntry` and `Test-RBAC4AppEntry`: when the service principal object id
  (`ServicePrincipalId` / `SpObjectId`) comes back empty - usually an incomplete `Connect-MgGraph` or
  directory read that is not always visible as `$null` from `Get-MgContext` - it is filled from the
  GUID found in the role assignment's `EffectiveUserName`, with a warning (interactive, in
  `Test-RBAC4AppEntry`'s `Warnings`, and in the exported config's `Runtime.CollectedWarnings`). A
  non-GUID `EffectiveUserName` (e.g. the `NT AUTHORITY\SYSTEM (...)` placeholder) is never used; the
  field stays empty and a warning says so. `-ExportConfig` now exports such assignments instead of
  skipping them.
- New optional top-level `Runtime` config section with `OperatorUsername`, `OperatorMachineName`
  (the session user and machine that generated the file), `CollectedErrors` and `CollectedWarnings`
  (ignored by `Invoke-RBAC4AppConfig`). Written by
  `Get-RBAC4AppEntry -ExportConfig`, `New-RBAC4AppConfig`, and `Convert-ApplicationAccessPolicyToRBAC`;
  like `Metadata` it is always written in full (empty lists as `[]`).
- `-FailOnError` switch on `New-RBAC4AppEntry`, `Set-RBAC4AppEntry`, `Remove-RBAC4AppEntry` and
  `Invoke-RBAC4AppConfig`: when the summary's `Errors` is non-empty, the summary is still emitted and
  one error record (`RBAC4AppOperationFailed`, the summary as `TargetObject`) is written to the error
  stream, so CI/CD scripts can fail with `-ErrorAction Stop`. Default behaviour is unchanged.
- `scripts/Debug-ExportConfig.ps1`: diagnoses a `Get-RBAC4AppEntry -ExportConfig` run that writes no
  files. In a connected Exchange Online session it imports the module from `src`, logs the per-filter
  assignment counts and service principal resolution, runs the export, and writes a transcript with
  skipped assignments, grouped errors, warnings, and the before/after file count.

### Fixed
- **Safety:** `Remove-RBAC4AppEntry` decides which scoped assignments are its own (and so removed)
  by exact identity - the assignee must resolve to this service principal (object id, or AppId when
  no object id) - instead of a name/AppId substring. Before, `-RegisteredAppName 'Mail'` could
  remove `MailArchiver`'s assignments on the same scope group. An unresolved assignee, or one
  matched only by the generated assignment name, now counts as foreign and blocks removal.
- `Get-RBAC4AppEntry` reads Exchange Online once per call instead of once per piped identity (F1),
  and the export no longer keeps only the last piped item's configs when writing to one file path.
- The application filter is exact: an assignment is kept only when its resolved assignee is the
  requested service principal. `-RegisteredAppName 'Mail'` no longer matches every
  `AppMailSend-...` assignment or `MailArchiver` (F2).
- A failed `Get-ManagementRoleAssignment` or `Get-ServicePrincipal` read is an error (once per call)
  instead of an empty result (F3).
- `Get-RBAC4AppApplication` no longer shows a role group as an application with a `DisplayName` (F6).
- `-ScopeType` rejects values that are not `RecipientWriteScopeType` values (or `All`) instead of
  silently returning nothing (F7).
- `Get-RBAC4AppEntry` rows and `New-RegisteredApp` output pipe into `Get-RBAC4AppEntry` again: only
  `-AppId` binds by property name now, so an object with several identity properties no longer
  fails with "Parameter set cannot be resolved" (F8).
- An assignment bound to a custom recipient scope whose management scope cannot be read reports
  `ScopeKind` `$null` with a warning instead of being looked up as a group of the same name (F10).
- Exporting an unreadable scope group no longer guesses its type from the name prefix (which could
  make `Invoke-RBAC4AppConfig` create an empty M365 group or distribution list); see Changed (F9).
- `Remove-RBAC4AppEntry` now fails closed: a failed `Get-ManagementRoleAssignment` or group member
  read (`Get-UnifiedGroupLinks` / `Get-DistributionGroupMember`) aborts the teardown with nothing
  removed. Previously the read error was swallowed, so the foreign-assignment / real-member safety
  gate saw an empty list and could delete a management scope or group that was still in use.
- Exchange Online service principal reads (`Resolve-RBAC4AppServicePrincipal`,
  `Register-EXOServicePrincipal`) now surface a failed `Get-ServicePrincipal` call as an error instead
  of treating it as "not found" (which could send `New-`/`Set-RBAC4AppEntry` down the bootstrap path
  or skip the existence/name-conflict checks).
- `Register-EXOServicePrincipal` throws when `New-ServicePrincipal` fails instead of silently
  returning `$null` (it used `-ErrorAction SilentlyContinue`), and no longer prints a leftover
  `resultNewSP:` debug warning. Callers record the failure in `Errors` and skip the role assignments.
- `New-RegisteredApp` no longer crashes in `begin` when Microsoft Graph is not connected
  (`Get-MgContext` returned `$null` under StrictMode); `TenantId` is then reported empty.
- `-AccessGroupType MailEnabledSecurityGroup` now requires the referenced recipient to be a
  mail-enabled security group (`RecipientTypeDetails` `MailUniversalSecurityGroup` or
  `MailNonUniversalGroup`). A mailbox or plain distribution group is rejected by `New-`/`Set-`/
  `Invoke-` and reported as missing (wrong type) by `Test-RBAC4AppEntry`.
- Generated scope group, management scope and role assignment names no longer collapse to a bare
  prefix (e.g. `UDLRAo1P-`) when the application display name has no Exchange-safe characters (e.g.
  entirely non-ASCII): the AppId without dashes is used instead. Names for display names with at least
  one ASCII letter/digit are unchanged (no transliteration).
- `Get-RBAC4AppEntry -ExportConfig` no longer drops a role assignment whose scope group cannot be
  read (renamed, deleted, or not visible): the config is still written with the group name, an
  `AccessGroupType` inferred from its prefix, and no members, with a warning to review it. Previously
  every such assignment failed with a non-terminating error and no files were written.
- `Resolve-RBAC4AppScope` (used by `Get-RBAC4AppEntry`) falls back to `Get-Recipient -Anr` when
  `Get-UnifiedGroup` and `Get-DistributionGroup` cannot find a scope group by its stored name.

### Changed
- The helper scripts folder `scripts/` is renamed `utils/` (e.g. `./utils/Show-CoverageGaps.ps1`,
  `./utils/Export-RBAC4AppStateReport.ps1`); earlier entries below keep the old paths.
- **Breaking:** config schema is now **4.4**; `Invoke-RBAC4AppConfig` rejects 4.3 (and older)
  files - regenerate them. `New-RBAC4AppConfig -Repository` still reads 3.0-4.4 state files, and in
  a pre-4.4 file an absent `RbacScope.AccessGroupType` keeps meaning `DistributionList`.
- **Breaking:** the default `-AccessGroupType` (and the sparse-config default) is
  `CloudMailEnabledSecurityGroup`, not `DistributionList`; a `DistributionList` group is now written
  explicitly in configs. Pass `-AccessGroupType DistributionList` to keep the old behaviour - and
  **pass it for apps provisioned before 0.9.0**. `Set-RBAC4AppEntry` guards against the silent
  move: with `-AccessGroupType`/`-AccessGroupName`/`-GroupPrefix` all omitted, an app that still has
  its `UDLRAo1P-*` list but no `USRACo1P-*` group is left unchanged, with an error and the list in
  the new `LegacyGroupName` result field (an explicit `-AccessGroupType CloudMailEnabledSecurityGroup`
  performs the move). `Test-RBAC4AppEntry` reports the same case as a warning with
  `LegacyGroupName`, and `Remove-RBAC4AppEntry` refuses (`Reason`, `IsRemoved` `$false`,
  `LegacyGroupName`) and removes nothing - not even the shared management scope.
- Every `Set-DistributionGroup`, `Add-DistributionGroupMember` and `Remove-DistributionGroup` call
  passes `-BypassSecurityGroupManagerCheck`: the group's owner (`ManagedBy`, default
  `GraphAPI-Dummy-owner`) is not the operator, and Exchange Online otherwise refuses changes with
  "only a manager of the group". The operator needs an Exchange admin role (e.g. Organization
  Management or Security Group Creation and Membership).
- **Breaking:** `MailEnabledSecurityGroup` is renamed `HybridMailEnabledSecurityGroup` (reference-only,
  on-premises/synced) with default prefix `USRAHo1P` (was `USRAo1P`). The old name is still accepted
  as input; output, generated configs, `Convert-ApplicationAccessPolicyToRBAC`, and the forced
  `Export-RBAC4AppConfig` fallback use the new name. Existing `USRAo1P-*` groups need an explicit
  `-AccessGroupName` or `-GroupPrefix USRAo1P`.
- `Get-RBAC4AppEntry` reports a `MailUniversalSecurityGroup` scope group as
  `CloudMailEnabledSecurityGroup` when `IsDirSynced` is `$false`, otherwise (synced or unknown) as
  `HybridMailEnabledSecurityGroup`.
- **Breaking:** `Export-RBAC4AppConfig` refuses guessed data without `-Force`: an application
  identity inferred from the generated role assignment name, and a scope group that could not be
  read. With `-Force` the latter is exported as a reference-only
  `AccessGroupType: HybridMailEnabledSecurityGroup` with no members, which `Invoke-RBAC4AppConfig`
  validates but never creates. The reason is recorded in `Runtime.CollectedWarnings` together with
  the rows' own warnings.
- `Get-RBAC4AppEntry` is a pure read (no `SupportsShouldProcess`), writes each distinct warning once
  per call, and keeps it on the affected rows. Unresolvable piped identities are reported per item
  without stopping the pipeline.
- `Invoke-RBAC4AppConfig`'s schema-version error now points at `Get-RBAC4AppEntry | Export-RBAC4AppConfig`.
- Assignments whose assignee cannot be resolved to a service principal are no longer returned by an
  identity-filtered query (`-AppId`/`-RegisteredAppName`/`-SpObjectId`); they still appear in the
  unfiltered listing with a warning.
- `Get-RBAC4AppEntry`/`Get-RBAC4AppApplication` `-ScopeType` also accepts `ExclusiveRecipientScope`.
- Config schema 4.3: `TenantId` moved from the top level into the `Application` section
  (`Application.TenantId`; still informational, written only when known). The schema version is
  unchanged because 4.3 was never published. Readers still accept a top-level `TenantId` from
  earlier pre-release files and map it to `Application.TenantId`; `Invoke-RBAC4AppConfig`'s result
  `TenantId` and `scripts/Export-RBAC4AppStateReport.ps1`'s column (`Application.TenantId`) follow.
- **Breaking:** `Metadata.NetworkAccessIPRange` is split into `NetworkAccessIP4Range` (IPv4 address
  or CIDR) and `NetworkAccessIP6Range` (IPv6 address or CIDR, prefix 0-128), so IPv4 and IPv6 ranges
  are managed separately; `New-RBAC4AppConfig -NetworkAccessIPRange` is replaced by
  `-NetworkAccessIP4Range`/`-NetworkAccessIP6Range`. A `NetworkAccessIPRange` key in an existing
  file (always IPv4) is read as `NetworkAccessIP4Range`.
- **Breaking:** config schema bumped to `4.3`. `GeneratedAt` moved from the top level into the
  `Runtime` section (a legacy top-level value is still read into `Runtime.GeneratedAt`).
  `Convert-ApplicationAccessPolicyToRBAC` writes its full per-policy result into a new
  `ConversionResult` section (`AppId`, `ResolvedDisplay`, `AccessRight`, `ScopeGroup`, `DerivedRoles`,
  `SkippedPermissions`, `ConfigPath`; warnings/errors in `Runtime`). `Invoke-RBAC4AppConfig` now
  accepts only schema `4.3` and rejects `4.2`/`4.1`/`4.0`/`3.0` files - re-generate them.
  `docs/SCHEMA-4.2.*` were replaced by `docs/SCHEMA-4.3.*`.
- **Breaking:** `scripts/Export-RBAC4AppStateReport.ps1` now writes one column per schema 4.3 field,
  named by its full path (`Application.AppId`, `Rbac.Roles`, `RbacScope.ScopeKind`,
  `Metadata.PCode`, `Runtime.OperatorUsername`, ...) in schema order, so every row has the same
  columns. Values are reported as written in each file - an omitted field is an empty cell, not its
  default; lists are joined with `; `, and an explicit empty `RbacScope.Members` shows as `[]`. The
  old unqualified columns (`AppId`, `OwnerUsername`, ...) are gone. The private
  `ConvertFrom-RBAC4AppYaml` gains a `-Raw` switch (skips default completion) for this.
- **Breaking:** `New-RBAC4AppDistributionGroup -AppName` now defaults `-Prefix` to `UDLRAo1P`, the
  same DistributionList prefix every other function uses (was `UDLRAo1`, which produced a different
  group name than `New-RBAC4AppEntry`). Pass `-Prefix 'UDLRAo1'` to keep the old name.
- `Convert-ApplicationAccessPolicyToRBAC` now guarantees the migration keeps each policy's current
  scope group: configs record the `ScopeName` verbatim as `AccessGroupName` with
  `AccessGroupType: HybridMailEnabledSecurityGroup` (reference-only), so `Invoke-RBAC4AppConfig` only
  validates the group and binds the roles to it - it never creates a group, sanitizes or shortens the
  name, or changes members/owners. Previously the default `DistributionList` type made
  `Invoke-RBAC4AppConfig` sanitize the name (e.g. `Even Users` -> `EvenUsers`), create a new
  distribution list when that name did not match, and add the `GraphAPI-Dummy` placeholder member. A
  policy without `ScopeName` is now an error. `-AccessGroupType`, `-GroupPrefix`, and `-ManagedBy` are
  deprecated and ignored with a warning.
- Every generated schema 4.2 config (YAML or JSON, from `New-RBAC4AppConfig`,
  `Get-RBAC4AppEntry -ExportConfig`, and `Convert-ApplicationAccessPolicyToRBAC`) now always contains
  the full `Metadata` section with all ten properties, written as `""` when not supplied, instead of
  omitting it. Readers are unchanged; files without the section are still accepted. The JSON schema
  now accepts an empty `PCode` and `CmdbId`.
- `ChangeReference` is now written under `Metadata` instead of `Rbac`, without changing schema version
  `4.2`. Readers continue to accept existing configs with `Rbac.ChangeReference`.

### Removed
- **Breaking:** `Get-RBAC4AppEntry -ByApplication` (use `Get-RBAC4AppApplication`),
  `-ExportConfig`/`-ExportPath`/`-ExportFormat` (use `Get-RBAC4AppEntry | Export-RBAC4AppConfig`),
  `-ApplicationAccessPolicy` (call `Get-ApplicationAccessPolicy` directly), and its
  `SupportsShouldProcess` (`-WhatIf`/`-Confirm`). `-RegisteredAppName` and `-SpObjectId` no longer
  bind by property name from the pipeline.
- **Breaking:** `Get-RBAC4AppRoleAssignment`, `Resolve-ApplicationAccessPolicy`, and
  `Invoke-MsGraphEntraIDApiPerm` are no longer exported; they moved to `Private/`. For the
  role-assignment listing use `Get-RBAC4AppEntry`, and for raw Application Access Policies
  `Get-ApplicationAccessPolicy`.
- **Breaking:** `Get-RegisteredAppWithPermission` (deprecated wrapper) - use
  `Get-RBAC4AppApplication` (add `-ScopeType All` for its old no-scope-filter behavior).
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
