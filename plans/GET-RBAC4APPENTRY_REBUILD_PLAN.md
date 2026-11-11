# Rebuild Plan: split `Get-RBAC4AppEntry`

**Baseline:** `plans/GET-RBAC4APPENTRY_ANALYSIS.md` (findings F1–F10)
**Branch:** `b0.8.30` (git is read-only per user rules: no commits or pushes by the agent)
**Target version:** `0.9.0`. No version has been published, so this is a **clean break**: the old switches
are removed outright, with no deprecation shims (D1).
**Goal:**
- Replace the 768-line multi-mode function with small single-purpose public functions on top of
  testable private helpers.
- Fix F1–F10.
- Keep the 90% coverage gate green.

---

## 1. Target architecture

### 1.1 Public functions

| Function | Responsibility | Replaces (removed in 0.9.0) |
|---|---|---|
| `Get-RBAC4AppEntry` | Per-assignment enriched rows only. Pure read: no `SupportsShouldProcess`, no file I/O | default mode |
| `Get-RBAC4AppApplication` (new) | Per-application aggregated rows. Takes `RBAC4App.Entry` rows from the pipeline, or fetches them itself with the same identity and filter parameters | `-ByApplication` |
| `Export-RBAC4AppConfig` (new) | Builds and writes `Invoke-RBAC4AppConfig` configs from `RBAC4App.Entry` rows. `SupportsShouldProcess`; collects in `process`, writes in `end` | `-ExportConfig`, `-ExportPath`, `-ExportFormat` |
| *(none)* | Users call `Get-ApplicationAccessPolicy` directly (`Convert-ApplicationAccessPolicyToRBAC` already does) | `-ApplicationAccessPolicy` |

Typical usage after the split:

```powershell
Get-RBAC4AppEntry -AppId $id                                   # assignments
Get-RBAC4AppEntry | Get-RBAC4AppApplication                    # app inventory
Get-RBAC4AppApplication -RegisteredAppName 'Contoso'           # same, self-fetching
Get-RBAC4AppEntry -AppId $id | Export-RBAC4AppConfig -Path .\out -Format Json
Get-RBAC4AppEntry | Export-RBAC4AppConfig -PerApplication -WhatIf
```

### 1.2 Private helpers (new or refactored)

| Helper | Input → Output | Notes |
|---|---|---|
| `Get-RBAC4AppAssignmentSet` | `-Role`, `-Enabled`, `-ScopeType`, `-RoleAssigneeType` → raw assignments | Steps 3–4 of the analysis, minus the app filter. **`-ErrorAction Stop`** (F3). Per-role queries, deduped by `Guid` |
| `Get-RBAC4AppServicePrincipalIndex` | → `{ All; ByObjectId; ByAppId }` | **One** `Get-ServicePrincipal -ErrorAction Stop` per call (F1, F3) |
| `Resolve-RBAC4AppAssignee` | assignment(s) + index → `{ Sp; ServicePrincipalId; Source; Warnings }` | Holds match rules a–d and the EffectiveUserName fallback (removes the `$getSpObjectId` and `$warnOnce` scriptblocks) |
| `Resolve-RBAC4AppServicePrincipal` | gets an optional `-Index` | Reuses the shared directory read instead of a second `Get-ServicePrincipal` call |
| `Resolve-RBAC4AppScope` | refactor: returns `Warnings` (string[]) instead of calling `Write-Warning`; adds `Source` (`ManagementScope` / `Legacy`) | F10: a `CustomRecipientScope` whose scope is unreadable returns `ScopeKind=$null` with a warning instead of falling through to the legacy group lookup |
| `Test-RBAC4AppAssigneeMatch` | assignment + resolved SP → bool | Exact identity match (F2). Optionally adopted later by `Remove-RBAC4AppEntry` |
| `ConvertTo-RBAC4AppEntryRow` | assignment + assignee + scope → `RBAC4App.Entry` row | Single source of the row shape |
| `ConvertTo-RBAC4AppApplicationRow` | group of `RBAC4App.Entry` rows → `RBAC4App.Application` row | Pure function, no EXO calls |
| `ConvertTo-RBAC4AppConfigFromEntry` | rows sharing app + scope → `{ Config; SafeName; Warnings; Error; NeedsForce }` | Today's `$addExport` body, no side effects |
| `Write-RBAC4AppConfigFile` | configs + path + format → files | Today's `$writeExports`. Could later be reused by `New-RBAC4AppConfig` and `Convert-ApplicationAccessPolicyToRBAC` (out of scope) |

### 1.3 Data contract

**`RBAC4App.Entry`** (`PSTypeName`). Keeps every current per-assignment property and adds:

- `ServicePrincipalIdSource`: `ExoPointer`, `EffectiveUserName`, `NameHeuristic`, or `None`.
- `ScopeSource`: `ManagementScope`, `Legacy`, or `None`.
- `ScopeGroupName` (separate from `Scope`).
- `ScopeGroupResolved` (bool): whether the scope group was actually read. Used by D4.
- `Warnings` (string[]), `Errors` (string[], reserved).

This row carries everything `Export-RBAC4AppConfig` needs, so export never reads EXO again.

**`RBAC4App.Application`** (`PSTypeName`). Keeps every current `-ByApplication` property and adds:

- `RoleAssigneeType`: rows are grouped by (`RoleAssigneeType`, `RoleAssigneeName`). This fixes F6.
- `Warnings`: the union of the rows' warnings.

**Export input validation:** accept only objects with `PSTypeName` `RBAC4App.Entry` (or
`Deserialized.RBAC4App.Entry`); reject others with a clear error.

---

## 2. Behavior specification (acceptance criteria)

### 2a. `Get-RBAC4AppEntry`

- **Parameter sets:** `All`, `ByName`, `ByAppId`, `BySpObjectId`. Pipeline binding follows **D7**: the
  current sets cannot bind *any* object carrying more than one identity property (verified, see
  analysis F8).
- **Removed parameters (D1):** `-ByApplication`, `-ApplicationAccessPolicy`, `-ExportConfig`,
  `-ExportPath`, `-ExportFormat`. Also removed: `SupportsShouldProcess`.
- **`-ScopeType`:** add a ValidateSet (F7). Confirm the exact `RecipientWriteScopeType` values before
  coding.
- **`begin`/`process`/`end`:**
  - EXO reads (assignment set, SP index) happen **once**, lazily on the first `process` call (F1).
  - The scope cache is shared across pipeline items.
  - `process` resolves the identity for each input and filters with `Test-RBAC4AppAssigneeMatch` (F2).
- **Identity filter rule:** keep an assignment when its *resolved* assignee SP has the requested
  ObjectId. When the ObjectId is empty, the AppId must match instead. Substring matching is gone.
- **Errors (D6):**
  - Unresolved identity: `Write-Error`, then continue with the next pipeline item.
  - EXO read failure: one `Write-Error` per call, never one per item. The failure is remembered, so
    later items emit nothing and do not retry.
  - Ambiguous name: the resolver throws; surface it via `Write-Error`.
- **Warnings:** each distinct message is written once per call, and also attached to the row's `Warnings`.

### 2b. `Resolve-RBAC4AppAssignee`

- **Match order:** ObjectId, then exact DisplayName, then `_SP`-stripped DisplayName, then the
  heuristic (d). Kept, isolated (D2).
- **ServicePrincipalId:** the pointer's ObjectId. Otherwise, for ServicePrincipal assignees only, the
  EffectiveUserName GUID with a warning. Otherwise `$null`, with a warning if a pointer was found.
- **Caching:** per (`RoleAssigneeType`, `RoleAssigneeName`).

### 2c. `Get-RBAC4AppApplication`

- **Pipeline input:** `RBAC4App.Entry` rows (`ParameterSetName='FromEntry'`), collected in `process`
  and grouped in `end`.
- **Self-fetching sets:** `All`, `ByName`, `ByAppId`, `BySpObjectId`, with the same filters as
  `Get-RBAC4AppEntry`. Internally it calls `Get-RBAC4AppEntry` and groups the result.
- **Grouping key:** (`RoleAssigneeType`, `RoleAssigneeName`). `DisplayName` uses the real assignee type
  (F6). If `ServicePrincipalId` disagrees across rows, warn.

### 2d. `Export-RBAC4AppConfig`

- **Parameters:** `-InputObject` (`RBAC4App.Entry[]`, `ValueFromPipeline`), `-Path` (directory or file;
  default current directory), `-Format Yaml|Json`, `-PerApplication`, `-PassThru`
  (`{ Path; Config; Warnings }` per written file), and `-Force` (D2/D4).
- **Lifecycle:** `process` collects; `end` groups, builds, and writes (removes the F1 overwrite).
- **Rules:** identical to section 6 of the analysis, **except for guessed data (D2 + D4), which follows
  one rule:**
  - A config is **refused** (non-terminating `Write-Error` naming `-Force`) when any of its rows has
    `ServicePrincipalIdSource = NameHeuristic`, or `ScopeKind` Group/GroupDirect with
    `ScopeGroupResolved = $false`.
  - With `-Force`, a row with an unresolved group is exported as **`AccessGroupType:
    MailEnabledSecurityGroup`** (reference-only), with the warning in `Runtime.CollectedWarnings`.
    `Invoke-RBAC4AppConfig` then fails validation if the group is missing, instead of creating an empty
    group with the default dummy member and owner.
  - The prefix-based type inference (`Um365` / `USRA` / default DistributionList) is removed.
- **Unchanged:** a per-config failure is a non-terminating `Write-Error`, and the other configs are
  still written.

---

## 3. Action plan (phased)

Each phase ends with `./build.ps1 -Task All` green (Analyze, Test with ≥90% coverage, Build). Run
`./scripts/Show-CoverageGaps.ps1` after each phase that adds code.

### Phase 0: Baseline and characterization (no production change)

1. Run `./build.ps1`; record the pass count and coverage in the Status section.
2. Pin today's per-assignment and per-application row shapes, and the exported YAML/JSON for Group,
   Recipients, Tag, and Filter scopes (golden files under `tests/fixtures/`). They serve as reference
   while refactoring and are updated deliberately where 0.9.0 changes output.
3. Add skipped tests reproducing F1, F2, F3, F6, F7, F10, and the pipeline binding failure (D7).

### Phase 1: Extract private helpers (pure refactor, behavior identical)

1. `Get-RBAC4AppServicePrincipalIndex`, `Resolve-RBAC4AppAssignee` (lines 388–481).
2. `ConvertTo-RBAC4AppEntryRow`, `ConvertTo-RBAC4AppApplicationRow` (lines 708–763).
3. `ConvertTo-RBAC4AppConfigFromEntry`, `Write-RBAC4AppConfigFile` (lines 497–661). The input is still raw
   assignments plus scope in this phase.
4. `Get-RBAC4AppAssignmentSet` (lines 333–362; still SilentlyContinue in this phase).
5. Unit tests per helper (`InModuleScope`): `tests/AssigneeResolution.Tests.ps1`,
   `tests/EntryProjection.Tests.ps1`, `tests/ConfigExportHelpers.Tests.ps1`. Cover every branch of
   heuristic (d).
6. Update AGENTS.md's Private list.

**Exit:** golden tests unchanged and green.

### Phase 2: Fix the core and remove the old modes (`Get-RBAC4AppEntry`)

1. **Remove** `-ByApplication`, `-ApplicationAccessPolicy`, `-ExportConfig`, `-ExportPath`,
   `-ExportFormat`, and `SupportsShouldProcess` (D1). This fixes F4 and F5 by removal.
   - Delete the AAP tests (`Describe 'Get-RBAC4AppEntry -ApplicationAccessPolicy'`).
   - Mark the `-ByApplication` and `-ExportConfig` tests `-Skip` until Phases 3 and 4 move them.
2. `begin`/`process`/`end` with a lazy one-time read (F1). `Resolve-RBAC4AppServicePrincipal -Index`.
3. Reads use `-ErrorAction Stop`, with a single `Write-Error` per call (F3, D6). Add
   `Get-RBAC4AppEntry` to AGENTS.md convention 5.
4. `Test-RBAC4AppAssigneeMatch` replaces the needle filter (F2).
5. `-ScopeType` ValidateSet (F7).
6. Pipeline binding per **D7** (F8).
7. `Resolve-RBAC4AppScope`: `Warnings`, `Source`; fix F10.
8. Rows get `PSTypeName`, `ServicePrincipalIdSource`, `ScopeSource`, `ScopeGroupName`,
   `ScopeGroupResolved`, `Warnings`, and `Errors`. Update `.OUTPUTS` help.
9. Un-skip the Phase 0 tests for F1, F2, F3, F7, F8, and F10.

### Phase 3: `Get-RBAC4AppApplication`

1. Create `Public/Get-RBAC4AppApplication.ps1`: help, parameter sets from 2c, `[OutputType]`.
2. Create `tests/Get-RBAC4AppApplication.Tests.ps1`:
   - move the `-ByApplication` tests from `Get-RBAC4AppEntry.Tests.ps1` (lines 241–270 and 711–736);
   - add pipeline input, self-fetch per identity set, the F6 case, the SP-id disagreement warning, and a
     `failure paths` Describe block.

### Phase 4: `Export-RBAC4AppConfig`

1. Change `ConvertTo-RBAC4AppConfigFromEntry` to take `RBAC4App.Entry` rows. Implement the guessed-data rule
   (2d): `NeedsForce`, reference-only MESG under `-Force`, and no prefix inference.
2. Create `Public/Export-RBAC4AppConfig.ps1` (`SupportsShouldProcess`, `ConfirmImpact='Low'`).
3. Create `tests/Export-RBAC4AppConfig.Tests.ps1`:
   - move the ~440 lines of export tests from `Get-RBAC4AppEntry.Tests.ps1` (lines 271–710);
   - update the two heuristic tests (lines 332 and 397) to expect a refusal without `-Force` and an
     export with it;
   - replace the "inferred AccessGroupType" tests with refusal and reference-only cases;
   - add the F1 regression (two piped inputs into one file give an array of two), `-PassThru`, and
     `-WhatIf`;
   - add a round trip: export, then `Invoke-RBAC4AppConfig -WhatIf`, plus a `-Force` unresolved-group
     config that `Invoke-RBAC4AppConfig` must **not** create a group for.

### Phase 5: Packaging and docs (0.9.0)

1. Manifest: add `Get-RBAC4AppApplication` and `Export-RBAC4AppConfig` to `FunctionsToExport`
   (13 → 15); `ModuleVersion = '0.9.0'`. Update `tests/Module.Tests.ps1`.
2. Docs:
   - `README.md`, `docs/HAPPYPATH.md`, `docs/SCHEMA-4.3.md`: replace `-ExportConfig` and
     `-ByApplication` usages.
   - `AGENTS.md`: the public list (15), the private helpers, the Get-RBAC4AppEntry architecture bullet,
     convention 5, and the pipeline-composition claim (D7).
   - `CHANGELOG.md` `[0.9.0]`:
     - Added: 2 functions and the new row properties.
     - Changed: fail-closed reads, exact app filter, pipeline binding, export refuses guessed data.
     - **Removed:** the 5 parameters and `SupportsShouldProcess`.
     - Fixed: F1–F3, F6, F7, F10.
   - `Invoke-RBAC4AppConfig.ps1:150`: point the error-message hint at `Export-RBAC4AppConfig`.
3. Run `./build.ps1 -Task All` and record the results below.

### Optional follow-ups (out of scope)

- Apply D7's binding rule to `New-`, `Set-`, `Test-`, and `Remove-RBAC4AppEntry` (they share the
  parameter-set convention; not yet verified).
- `Remove-RBAC4AppEntry` (line 286): use `Test-RBAC4AppAssigneeMatch`. This is safety-relevant and needs
  its own review.
- Reuse `Write-RBAC4AppConfigFile` in `New-RBAC4AppConfig` and `Convert-ApplicationAccessPolicyToRBAC`.
- Server-side narrowing via `Get-ManagementRoleAssignment -RoleAssignee <ObjectId>`, if EXO accepts an
  SP object id there.
- D5: a `Format.ps1xml` default view (needs `FormatsToProcess` in the manifest).

---

## 4. Decisions

| ID | Question | Status | Decision |
|---|---|---|---|
| D1 | Deprecation shims or hard break? | **Decided 2026-11-11** | **Hard break in 0.9.0.** No version was ever published, so the five parameters are removed outright. The former Phases 5 (AAP shim) and 7 (removal release) are gone |
| D2 | Keep the name-based SP resolution heuristic? | **Decided 2026-11-11** | Keep, isolated, flagged `NameHeuristic`; export refuses such rows without `-Force` (same rule as D4) |
| D3 | Names `Get-RBAC4AppApplication` / `Export-RBAC4AppConfig`? | **Decided 2026-11-11** | Keep: approved verbs, consistent with `scripts/Export-RBAC4AppStateReport.ps1` |
| D4 | Exports whose scope group could not be read? | **Decided 2026-11-11** | Refuse without `-Force`. With `-Force`, export as reference-only `MailEnabledSecurityGroup`. The old prefix inference could make `Invoke-RBAC4AppConfig` **create** an empty DL/M365 group with the dummy member and owner |
| D5 | Default `Format.ps1xml` view? | **Decided 2026-11-11** | Defer until after 0.9.0 (new manifest entry; hides columns users see today) |
| D6 | Behavior on an EXO read failure? | **Decided 2026-11-11** | `Write-Error` and return (convention 3), **once per call**, not per pipeline item |
| D7 | How should piped objects bind to the identity parameters? | **Decided 2026-11-11** | **Option A:** only `-AppId` binds by property name; name and SP object id bind from strings or explicit arguments. Alternatives: B, an `-InputObject` set resolved internally; C, leave as is and correct AGENTS.md |

## 5. Risks

- **Clean break (D1):** scripts using the removed parameters fail at parameter binding. Accepted, since
  nothing was published; list every removal in CHANGELOG.
- **Fail-closed reads:** some "empty result" situations become errors. Intended; document it.
- **Moving ~470 lines of tests** (export plus `-ByApplication`) can lose coverage. Compare
  `Show-CoverageGaps` output before and after Phases 3–4.
- **Exact identity matching** may drop rows the substring filter used to include. A characterization
  test lists the rows that differ, for review before merge.
- **D4 refusal** changes the default outcome for deleted or renamed scope groups from "exported with a
  warning" to "not exported". Intended, because the old output could create groups.

## Status

All decisions D1–D7 taken 2026-11-11 (D5 = deferred). Fill in per phase: date, build result (passed/failed/coverage), decisions taken.

| Phase | Status | Build (`./build.ps1 -Task All`) |
|---|---|---|
| Baseline (after the `Application.TenantId` move) | 2026-11-11 | 560 passed, 0 failed, coverage 96.3% |
| P0 | **Done 2026-11-11** | 565 passed, 0 failed, 9 skipped, coverage 96.4% |
| P1–P4 | **Done 2026-11-11** (one checkpoint, see notes) | — |
| P5 | **Done 2026-11-11** | **596 passed, 0 failed, 0 skipped, coverage 96.7%**; Analyze clean; Build OK (0.9.0, 15 exports) |

### P0 notes

- **Golden files:** `tests/Get-RBAC4AppEntry.Characterization.Tests.ps1` compares against
  `tests/fixtures/Get-RBAC4AppEntry/` (12 files).
  - **Inputs:** one assignment per scope kind (Group management scope, Recipients, Tag, Filter,
    legacy GroupDirect to a mail-enabled security group), a two-role application, and one legacy
    group that can't be read (`AppMailSend-Adatum`).
  - **Pinned output:** per-assignment rows, `-ByApplication` rows, warnings, the per-assignment
    YAML exports, and a `-ByApplication` JSON export to a file path.
  - **Normalization:** line endings become LF, and the Runtime `GeneratedAt`, `OperatorUsername`
    and `OperatorMachineName` values are masked.
  - **Regenerating:** set `$env:RBAC4APP_UPDATE_GOLDEN = '1'`, run the file, then review the diff.
    `export-rbac4app-AppMailSend-Adatum.yml` pins F9 (a guessed `M365Group` with no members) until
    Phase 4 replaces it.
- **Known issues:** `tests/Get-RBAC4AppEntry.KnownIssues.Tests.ps1` has 9 tests (F1, F2, F3 ×2, F6,
  F7, F8 ×2, F10).
  - Each is tagged with its finding and fixing phase, and skipped unless
    `$env:RBAC4APP_RUN_KNOWN_ISSUES = '1'`.
  - Verified: all 9 fail against the current code. Un-skip each one in the phase that fixes it
    (remove `-Skip:$SkipKnownIssues`).
  - F4 and F5 have no test (the parameter is removed in P2). F9 is pinned by the golden file.
- **Testing lessons for later phases:**
  - A Pester mock's `Write-Error` ignores the caller's `-ErrorAction`. Mocks that simulate EXO
    failures must pass `-ErrorAction $PesterBoundParameters['ErrorAction']`.
  - `-ErrorVariable` also collects errors that nested commands suppress, so "the function reported
    it" is asserted with `-ErrorAction Stop` + `Should -Throw`.
  - Mocks must read optional parameters through `$PesterBoundParameters`, not the bare variable,
    because the build runs under `Set-StrictMode -Version Latest`.
- **Found while reading the tests (relevant to P3/P4):** in `tests/Get-RBAC4AppEntry.Tests.ps1`,
  `Describe 'Get-RBAC4AppEntry -ExportConfig'` (line 271) is nested inside
  `Describe 'Get-RBAC4AppEntry -ByApplication'` (line 241), so it inherits that block's
  `BeforeEach` mocks. Separate them when the export tests move.

### P1–P5 notes

- **One checkpoint instead of four.** P1 ("pure refactor of the old function") would have been
  thrown away by P2's rewrite, and the `-ByApplication`/`-ExportConfig` tests cannot stay green once
  P2 removes the switches, so P1–P4 landed together. The P0 regression tests and golden files
  were the safety net:
  - every known-issue test passes;
  - every golden-file diff was reviewed and is one of the intended changes below.
- **Private helpers (all new except where noted):**
  - `Get-RBAC4AppAssignmentSet`
  - `Get-RBAC4AppServicePrincipalIndex` (planned as `New-...`; renamed because the analyzer flags
    `New-` without ShouldProcess)
  - `Resolve-RBAC4AppAssignee`
  - `Test-RBAC4AppAssigneeMatch`
  - `ConvertTo-RBAC4AppEntryRow`
  - `ConvertTo-RBAC4AppApplicationRow`
  - `ConvertTo-RBAC4AppConfigFromEntry` (planned as `New-...`; same reason)
  - `Write-RBAC4AppConfigFile`
  - `Resolve-RBAC4AppServicePrincipal -Directory` (changed)
  - `Resolve-RBAC4AppScope` (changed): returns `Source`, `GroupResolved` and `Warnings`; fixes F10.
    `Get-RBAC4AppRoleAssignment` now writes those warnings itself (deduplicated).
- **`-ScopeType` ValidateSet:** `All` plus the `RecipientWriteScopeType` values: `None`,
  `NotApplicable`, `Organization`, `MyGAL`, `Self`, `MyDirectReports`, `OU`, `CustomRecipientScope`,
  `MyDistributionGroups`, `MyExecutive`, `ExcludedRecipients`, `ExclusiveRecipientScope`, `MailboxICanDelegate`, `Group`,
  `AdministrativeUnit`.
  - Partly checked against Microsoft Learn (`New-ManagementRoleAssignment -RecipientRelativeWriteScope`
    lists None, Organization, MyGAL, Self, MyDistributionGroups, NotApplicable, OU, MyDirectReports,
    CustomRecipientScope, MyExecutive, MailboxICanDelegate, ExclusiveRecipientScope); that check
    added `ExclusiveRecipientScope`. `Group`, `AdministrativeUnit`, and `ExcludedRecipients` are not
    on that page (the first two come from EXO-only scoping and fixtures).
  - **Verify it** in a live session: `[enum]::GetNames(...)`, or tab completion on
    `Get-ManagementRoleAssignment -RecipientWriteScope`.
- **Exact-match mitigation (section 5) replaced by a CHANGELOG note:** no check was added for rows
  the old substring filter kept and exact matching now drops. The affected case is an assignee
  whose pointer has no object id and where the name heuristic fails. Such a row still appears in
  the unfiltered listing with a warning, but no longer under `-AppId`/`-RegisteredAppName`.
- **`Remove-RBAC4AppEntry` exact match (done after P5, on request):** the own/foreign partition
  uses `Resolve-RBAC4AppAssignee` + `Test-RBAC4AppAssigneeMatch` over one shared
  `Get-RBAC4AppServicePrincipalIndex` read. An unresolved assignee, or one matched only by the name
  heuristic, counts as foreign, so it blocks removal and is never deleted. Three new tests.
- **Tests:**
  - `tests/Get-RBAC4AppEntry.Tests.ps1` holds only the per-assignment tests, plus new tests for:
    - the provenance properties;
    - F10 on a row;
    - per-item identity errors;
    - an ambiguous name;
    - one error per call on a failed read, with no retry.
  - New: `tests/Get-RBAC4AppApplication.Tests.ps1` and `tests/Export-RBAC4AppConfig.Tests.ps1`.
    These include:
    - the heuristic and unreadable-group cases, refused without `-Force` and exported with it;
    - an F1 piped-file regression;
    - `-PassThru`, `-WhatIf`, and the default path;
    - Tag/Filter exports;
    - a round trip in which `Invoke-RBAC4AppConfig` does not create a forced reference-only group.
  - `KnownIssues.Tests.ps1` was renamed to `tests/Get-RBAC4AppEntry.Regression.Tests.ps1`, with
    everything un-skipped. F6 now targets `Get-RBAC4AppApplication`.
- **Golden-file changes (reviewed):**
  - `rows.json`: 6 added properties per row.
  - `byapplication.json`: `RoleAssigneeType` and `Warnings` added.
  - `export-rbac4app-AppMailSend-Adatum.yml`: written with `-Force`; `AccessGroupType`
    `MailEnabledSecurityGroup` instead of the guessed `M365Group`; `CollectedWarnings` now holds the
    row's scope warning plus the reference-only note.
  - A new golden test asserts that, without `-Force`, only Adatum is refused (6 of 7 written).
  - All other golden files are unchanged.
- **Docs:** README (function and parameter tables, cmdlet matrix, `Get-RBAC4AppEntry` section, new
  `Get-RBAC4AppApplication` / `Export-RBAC4AppConfig` sections), AGENTS.md, `docs/SCHEMA-4.3.md`,
  CHANGELOG `[0.9.0] - Unreleased`, the `Invoke-RBAC4AppConfig` schema hint, and
  `scripts/Debug-ExportConfig.ps1` were all updated. The debug script now runs
  `Get-RBAC4AppEntry | Export-RBAC4AppConfig`; its own `-ByApplication` switch maps to
  `-PerApplication`.
- **Still open (out of scope, see "Optional follow-ups"):**
  - D7 binding for `New-`/`Set-`/`Test-`/`Remove-RBAC4AppEntry`.
  - D5 (`Format.ps1xml`).
  - Not tagged or released; git is read-only for the agent.
