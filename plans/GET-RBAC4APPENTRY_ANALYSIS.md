# Analysis: `Get-RBAC4AppEntry` (as of 0.8.27, branch `b0.8.30`)

**Source:** `src/EXORBACforAppManagement/Public/Get-RBAC4AppEntry.ps1` (768 lines)
**Purpose of this document:** an independent description of the current behavior (inputs, outputs,
requirements, algorithm) plus a review, as the baseline for the rebuild in
`plans/GET-RBAC4APPENTRY_REBUILD_PLAN.md`.

---

## 1. What it is

A read-only inventory of Exchange Online **RBAC for Applications** role assignments (roles named
`Application <perm>`). One function currently provides three output modes plus an export side effect:

| Mode | Trigger | Output |
|---|---|---|
| Per-assignment | default | one enriched row per role assignment |
| Per-application | `-ByApplication` | one aggregated row per assignee (`Group-Object RoleAssigneeName`) |
| Legacy AAP | `-ApplicationAccessPolicy` | raw `Get-ApplicationAccessPolicy` objects (pass-through) |
| Export (side effect) | `-ExportConfig` | writes YAML/JSON configs for `Invoke-RBAC4AppConfig`; rows are still emitted |

## 2. Requirements

- **Exchange Online session only**, no Microsoft Graph.
- EXO cmdlets: `Get-ManagementRoleAssignment`, `Get-ServicePrincipal`, `Get-ManagementScope`,
  `Get-Recipient` (`-Identity`, `-Anr`, `-RecipientPreviewFilter`), `Get-UnifiedGroup`,
  `Get-UnifiedGroupLinks`, `Get-DistributionGroup`, `Get-DistributionGroupMember`; AAP mode adds
  `Get-ApplicationAccessPolicy` (checked first with `Get-Command`).
- For the identity filter, the app must already have an **EXO service principal pointer**
  (`New-ServicePrincipal`, via `Register-EXOServicePrincipal` / `New-RBAC4AppEntry` /
  `Invoke-RBAC4AppConfig`).
- Private helpers used: `Resolve-RBAC4AppServicePrincipal`, `ConvertTo-RBAC4AppRoleName`,
  `Get-AppRoleMap`, `Get-RBAC4AppRoleAssignmentName`, `Get-RBAC4AppEffectiveUserObjectId`,
  `Resolve-RBAC4AppScope` (uses `ConvertFrom-RBAC4AppRecipientFilter`, `Resolve-RBAC4AppScopeGroupName`),
  `ConvertTo-RBAC4AppConfig`, `ConvertTo-RBAC4AppYaml`, `Format-RBAC4AppSafeName`,
  `Get-RBAC4AppDefaultGroupPrefix`.

## 3. Inputs

### Identity (mutually exclusive parameter sets; none means set `All`)

| Param | Set | Notes |
|---|---|---|
| `-RegisteredAppName` (pos 0, aliases `DisplayName`,`Name`) | ByName | pipeline by value and by property name; matches raw name or the `_SP` form |
| `-AppId` (aliases `ClientId`,`ApplicationId`) | ByAppId | GUID regex; pipeline by property name |
| `-SpObjectId` (aliases `Id`,`ObjectId`,`ServicePrincipalId`) | BySpObjectId | GUID regex; pipeline by property name |

### Filters

- `-Role string[]`: short names are normalized (`Mail.Send` becomes `Application Mail.Send`). Unknown
  roles throw inside `ConvertTo-RBAC4AppRoleName`.
- `-Enabled [bool]`: three-state (true, false, or not given), deliberately not a switch.
- `-RoleAssigneeType`: ValidateSet, default `ServicePrincipal`; `All` disables the filter.
- `-ScopeType string[]`: matched against `RecipientWriteScope`; default `Group`,`CustomRecipientScope`;
  `All` disables the filter. **No ValidateSet.**

### Mode / export

- `-ByApplication`, `-ApplicationAccessPolicy`, `-ExportConfig`. `-ExportConfig` combined with
  `-ApplicationAccessPolicy` throws.
- `-ExportPath`, `-ExportFormat Yaml|Json` (default `Yaml`).

## 4. Algorithm (everything runs in `process {}`)

1. **Resolve identity** via `Resolve-RBAC4AppServicePrincipal`: reads `Get-ServicePrincipal
   -ErrorAction Stop`, then matches by ObjectId, by AppId, or by name (raw, `_SP`-stripped, or
   `_SP`-suffixed). More than one match throws "Ambiguous". No match returns `$null`, and the caller
   then calls `Write-Error` and `return`.
2. **AAP short-circuit**: calls `Get-ApplicationAccessPolicy`, adding `-AppId` (explicit or resolved)
   when an identity was given, then `return`.
3. **Fetch assignments**: with `-Role`, one `Get-ManagementRoleAssignment -Role X` per role; otherwise
   one unfiltered call, keeping `Role -like 'Application *'`. Both use `-ErrorAction SilentlyContinue`.
4. **Client-side filters**, in order: Enabled, ScopeType, RoleAssigneeType, then app. The app filter
   keeps an assignment when any of `DisplayName`, `DisplayName_SP`, `AppId`, or `Id` is a substring
   (`-like "*$n*"`, *not* wildcard-escaped) of `RoleAssigneeName` or `Name`.
5. **Assignee to SP enrichment**: one more `Get-ServicePrincipal` read (SilentlyContinue), an index
   by ObjectId, cached per distinct `RoleAssigneeName`. Matching order:
   - a. ObjectId equals the assignee (this module binds with `-App <ObjectId>`, so the assignee is a GUID)
   - b. exact DisplayName
   - c. DisplayName with `_SP` stripped
   - d. **heuristic**, used only when all of these hold:
     - the assignee is a GUID;
     - exactly one SP whose **ObjectId is empty** has a generated assignment name
       (`<shortRole>-<SafeDisplayName>`) equal to an assignment's `Name`;
     - that assignment's `EffectiveUserName` GUID equals the assignee;
     - no assignment for the same assignee conflicts with that GUID.

     When this branch is used, it writes a warning.
6. **ServicePrincipalId fallback** (`$getSpObjectId`): if the resolved SP has no ObjectId, the first
   GUID found in `EffectiveUserName` is used, with a warning.
7. **Scope resolution** (`Resolve-RBAC4AppScope`, cached per scope and per group):
   - **Management-scope path**: used when `CustomResourceScope` is a plain name (not
     `<name>_<GUID>`), or when `RecipientWriteScope=CustomRecipientScope`. It calls
     `Get-ManagementScope` and parses `RecipientFilter`:
     - `Group` (`MemberOfGroup -eq 'DN'`): DN resolved via `Get-Recipient`, then group type and members.
     - `Recipients` (`PrimarySmtpAddress -eq` joined by `-or`): the addresses are the members.
     - `Tag` (`CustomAttributeN -eq 'v'`) or `Filter` (anything else): members previewed via
       `Get-Recipient -RecipientPreviewFilter`, capped at 1000, with a warning when the cap is hit.
   - **Legacy path** (`-RecipientGroupScope`): group name = `CustomResourceScope` with the
     `_<GUID>` suffix stripped; `ScopeKind=GroupDirect`.
   - **Group type probe**, in order:
     1. `Get-UnifiedGroup` gives M365Group.
     2. `Get-DistributionGroup` gives MailEnabledSecurityGroup if `RecipientTypeDetails` is
        `MailUniversalSecurityGroup`, otherwise DistributionList.
     3. `Get-Recipient -Anr`: an exact Name, DisplayName, or Alias match, or a single group hit.
     4. Otherwise a warning, and type and members are left empty.
   - Never throws.
8. **Emit rows** in per-assignment or per-application form (see 5).
9. **Export (optional)**: one config per assignment (default mode), or one per application per
   distinct scope (`-ByApplication`). Configs are queued, then written at the end of `process` (see 6).

## 5. Outputs

### Per-assignment row

- **From the assignment:** `Name`, `RoleAssignmentName` (same value as `Name`), `Role`,
  `RoleAssigneeName`, `RoleAssigneeType`, and the raw EXO fields `EffectiveUserName` and `App`.
- **From SP resolution:** `DisplayName` (`_SP` stripped), `AppId`, `ServicePrincipalId`.
- **From scope resolution:**
  - `Scope`: the group name for Group/GroupDirect, otherwise the management scope name.
  - `ManagementScope`, `ScopeKind`, `ScopeFilter`, `ScopeGroupType`, `ScopeMembers`.
- **Raw fields:** `RecipientScope`, `Enabled`, `Guid`, `Identity`.

### Per-application row (`-ByApplication`)

- **Identity:** `DisplayName`, `AppId`, `ServicePrincipalId`, `ExoServicePrincipal` (the raw assignee).
- **Scope aggregates:** `ManagementScopeNames`, `ScopeKinds`, `ScopeGroupNames`, `ScopeGroupMembers`.
- **Assignment aggregates:** `Roles`, `RoleAssignmentNames`, `EffectiveUserNames`, `Apps`.
- **Counts:** `AssignmentCount`, `EnabledAssignmentCount`, `DisabledAssignmentCount`.
- All arrays are sorted and unique.

### Streams

- **Warnings:** unresolved assignee, SP id fallback, name-based heuristic, unresolved group, preview
  truncated, inferred group type.
- **Non-terminating errors:** identity not found, AAP read failure, unexportable config.

## 6. Export rules

- **Exportable when all of these hold:**
  - the SP has an AppId and an object id (the `EffectiveUserName` fallback is allowed);
  - every role is `Application *`;
  - the scope kind is Group, Recipients, Tag, or Filter;
  - a Recipients scope has members, and a Filter scope has a filter.

  Otherwise `Write-Error` for that config; the remaining configs are still written.
- **Best effort when the group can't be read**: the type is inferred from the name prefix (`Um365`
  gives M365Group, `USRA` gives MailEnabledSecurityGroup, anything else DistributionList), with no
  members. A warning is also written into `Runtime.CollectedWarnings`.
- **Tag that doesn't parse** as `CustomAttributeN -eq 'v'` is downgraded to `Filter`.
- **`ManagedBy` is hard-coded** to `'GraphAPI-Dummy-owner'`.
- **Target path**:
  - **File path** (has an extension, not an existing directory): the extension is replaced to match
    `-ExportFormat`. A single config is written as-is. Several configs become a **JSON array, even in
    Yaml mode**. `Invoke-RBAC4AppConfig` accepts arrays (`Invoke-RBAC4AppConfig.ps1:112`), so this is
    consistent, if surprising.
  - **Otherwise**: `<dir>/rbac4app-<safeName>.<ext>`, with `-2`, `-3`, ... added on name collisions.
- **Writes are gated by `ShouldProcess`**, which is why a Get- function has `SupportsShouldProcess`.

## 7. Review findings

### Bugs / functional gaps

| # | Finding | Impact |
|---|---|---|
| F1 | All work runs in `process {}`: piping N apps repeats the full `Get-ManagementRoleAssignment` and `Get-ServicePrincipal` reads, scope caches do not carry over between items, and with a **file** `-ExportPath` each pipeline item **overwrites the same file** (last one wins) | data loss in export, N× EXO reads |
| F2 | App filter is a substring `-like` without wildcard escaping: app `Mail` also matches `MailArchiver_SP`; `[` in a display name breaks the match. `Remove-RBAC4AppEntry` (line 286) uses the same needles but *does* escape | false positives in filtered results and exports |
| F3 | `Get-ManagementRoleAssignment -ErrorAction SilentlyContinue` treats a permission or session failure as an empty tenant; the enrichment `Get-ServicePrincipal` is SilentlyContinue while the identity resolver's is `Stop` (two reads with different error semantics) | silent wrong answers; violates the repo's fail-closed convention |
| F4 | `-ApplicationAccessPolicy -RegisteredAppName X` requires X to have an EXO pointer, but AAP-only legacy apps (the migration candidates) often don't. Even with `-AppId`, the SP is still resolved first | AAP mode fails exactly where it is most useful |
| F5 | `-ByApplication` with `-ApplicationAccessPolicy` is silently ignored, and so are `-Role`, `-Enabled`, `-ScopeType`, and `-RoleAssigneeType` in AAP mode | confusing UX |
| F6 | `-ByApplication` groups by `RoleAssigneeName` and always calls `Get-DisplayNameFor … 'ServicePrincipal'`; with `-RoleAssigneeType All`, a RoleGroup assignee looks like an app; the SP-id fallback takes the assignee type from the first assignment of the group only | wrong data in the app view |
| F7 | `-ScopeType` has no ValidateSet, so a typo (`Groups`) returns nothing, silently | silent empty results |
| F8 | **Verified 2026-11-11 (corrected):** any piped object carrying more than one identity property fails with "Parameter set cannot be resolved". This includes a `Get-RBAC4AppEntry` row, a `-ByApplication` row, `New-RegisteredApp` output (`DisplayName`/`AppId`/`ServicePrincipalId`), and any `{Name; Id}` object. Only plain strings bind. Removing the `Name`/`Id` aliases would not fix it (`DisplayName`/`AppId`/`ServicePrincipalId` still collide). See decision D7 in the rebuild plan | pipeline composition does not work; AGENTS.md claims it does |
| F9 | `ManagedBy = 'GraphAPI-Dummy-owner'` and the prefix-inferred group type produce configs that look valid but are not. **Worse than first stated:** with an inferred DistributionList/M365Group and no members, the config falls back to the default dummy member and owner, so `Invoke-RBAC4AppConfig` would **create** an empty group with the old name and bind the app's roles to it | can create groups |
| F10 | A `CustomRecipientScope` whose management scope is unreadable falls through to the legacy path, which then treats the scope name as a group name (spurious "could not resolve scope group" warning) | misleading warning |

### Design observations

- **One function does too much.** It has three output shapes and also performs file I/O, which
  forces `SupportsShouldProcess` onto a Get- verb.
- **`-ByApplication` is already a pure projection** of the per-assignment rows.
- **AAP mode adds almost nothing** over calling `Get-ApplicationAccessPolicy` directly.
- **SP resolution is spread out.** It lives across inline loops and scriptblocks (`$getSpObjectId`,
  `$warnOnce`, the heuristic). Heuristic 5d is the most complex code in the file and serves a narrow
  edge case (a pointer with an empty ObjectId).
- **Warnings are written directly** by `Resolve-RBAC4AppScope`, so the export has to re-collect them
  through extra plumbing (`$configWarnings`, `$warnOnce`).
- **Performance is acceptable**:
  - the only unbounded cost is the Tag/Filter preview, which is capped at 1000;
  - scope resolution runs twice per assignment with `-ByApplication` and `-ExportConfig` (lines 679
    and 692), but the cache absorbs most of it.
