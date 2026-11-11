# Remediation Plan: Completeness & Fail-Safe Review

**Source:** `plans/COMPLETENESS_AND_FAILSAFE_REVIEW.md` (2026-11-08)
**Branch:** `b0.8.20` (no commits made; git is read-only per user rules)
**Goal:** Fix every verified finding, correct the finding whose suggested fix is wrong (4.5), and close
fail-open paths the review missed. Keep the 90% coverage gate green.

## Status (2026-11-08): implemented, not committed

Decisions: P4 = AppId fallback (applied to all three name helpers; throws only when no AppId is available),
P5 = accept `MailUniversalSecurityGroup` and `MailNonUniversalGroup`, P1 step 2 (server-side narrowing) =
deferred, P8 = docs + `-FailOnError` switch.

| Item | Status |
|---|---|
| P1 Remove fail-closed reads | Done + tests |
| P2 SP read fail-closed | Done + tests |
| P3 Register-EXOServicePrincipal | Done + tests |
| P4 Empty-name fallback (`Private/Get-RBAC4AppSafeDisplayName.ps1`) | Done + tests |
| P5 MESG recipient type (`$script:RBAC4AppSecurityGroupRecipientTypes`) | Done (New/Set/Test/Invoke) + tests, mocks updated |
| P6 New-RegisteredApp Graph-disconnected | Done + tests |
| P7 DistributionGroup prefix `UDLRAo1P` | Done (breaking, in CHANGELOG) |
| P8 `-FailOnError` (`Private/Write-RBAC4AppResult.ps1`) + README/AGENTS docs | Done + tests |
| P9 sweep | Reviewed; remaining `SilentlyContinue` reads are read-only, or a failure only leads to a create that EXO rejects as a duplicate. No change. |
| P1 step 2 server-side narrowing | Deferred |

`./build.ps1` (Analyze + Test + Build): 482 passed, 0 failed, coverage 95.7%.

---

## 0. Verification of the review against the code

| # | Finding | Verified? | Notes |
|---|---|---|---|
| 4.1 | `Register-EXOServicePrincipal` silent failure + debug warning | **Yes** (`Public/Register-EXOServicePrincipal.ps1:80-82`) | Callers `New-RBAC4AppEntry.ps1:503` and `Invoke-RBAC4AppConfig.ps1:285` sit inside their outer `try` (347..621 / 277..524), so a `throw` lands in `$result.Errors` (convention #2). |
| 4.2 | `New-RegisteredApp` crashes when Graph is disconnected | **Yes** (`Public/New-RegisteredApp.ps1:81`) | `$tenantId` is used only for the `TenantId` output field (line 91), so it's cosmetic. Swallowing the error with a verbose message is correct. |
| 4.3 | `MailEnabledSecurityGroup` accepts any recipient | **Yes** (`Private/New-RBAC4AppScopeGroup.ps1:54-59`) | The same unchecked `Get-Recipient` appears in `Remove-` :241, `Test-` :310, and `Set-` :428. |
| 4.4 | `New-RBAC4AppDistributionGroup` default prefix `UDLRAo1` | **Yes** (lines 24 help, 85 param) | |
| 4.5 | Add `-ResultSize Unlimited` | **Remediation is WRONG** | Microsoft Learn: neither `Get-ManagementRoleAssignment` nor `Get-ServicePrincipal` (EXO) has a `-ResultSize` parameter. Adding it would break every call with a parameter-binding error. I haven't verified whether a 1000-item cap exists. The real defect is **fail-open on read errors** (see P1). |
| 4.6 | Errors not on the error stream | Yes, but **by design** (AGENTS.md convention #2) | Plan: documentation only. Changing behavior is a user decision. |
| 4.7 | Empty sanitized name for non-ASCII display names | **Yes** | Worse than the review says: an empty/`$null` `-Identity` on EXO `Get-*` cmdlets returns **all** objects (documented caution). |

---

## 1. Work items (ordered by real severity)

### P1 [Critical] Teardown guard fails OPEN on read errors (`Remove-RBAC4AppEntry`): new finding replacing 4.5
**File:** `src/EXORBACforAppManagement/Public/Remove-RBAC4AppEntry.ps1`
- **:258** `Get-ManagementRoleAssignment -ErrorAction SilentlyContinue`: if the read fails (throttling,
  transient, or a permission error), `$scoped` is empty → no foreign assignments → **the management scope is deleted**.
- **~:285-289** `Get-UnifiedGroupLinks` / `Get-DistributionGroupMember -ErrorAction SilentlyContinue`:
  if the read fails, `$realMembers` is empty → **the group is deleted**.

**Change:**
1. Switch both reads to `-ErrorAction Stop` inside a `try`. On a catch, set `Reason` (e.g.
   `"Safety check could not be completed: <msg>"`), append to `Errors`, set `IsRemoved = $false`, and
   return the result **before any `Remove-*` call**. (Same shape as the existing unsafe-abort path.)
2. *(Optional, separate step)* Narrow the assignment read on the server side:
   `-CustomRecipientWriteScope $scopeName` plus a second call `-RecipientGroupScope $umGroupName` (both
   documented for EXO). Keep the client-side `Get-RBAC4AppAssignmentScopeState` classification. This needs
   test-stub updates (`param($CustomRecipientWriteScope, $RecipientGroupScope)`), so do it only if desired.

**Tests** (`tests/Remove-RBAC4AppEntry.Tests.ps1`, failure-paths `Describe`):
- `Get-ManagementRoleAssignment` mock throws → `IsRemoved -eq $false`, `Reason` set, and
  `Remove-ManagementScope`/`Remove-DistributionGroup`/`Remove-UnifiedGroup`/`Remove-ManagementRoleAssignment` invoked **0** times.
- Member read throws → same assertions.

**Compat:** Behavior changes only on read failure (from destructive to abort).

---

### P2 [High] SP-pointer reads treat errors as "not found"
**Files:**
- `Private/Resolve-RBAC4AppServicePrincipal.ps1:35`: `Get-ServicePrincipal -ErrorAction SilentlyContinue`.
  On failure it returns `$null`, so `New-`/`Set-RBAC4AppEntry` with `-AppId/-SpObjectId/-RegisteredAppName`
  go down the **bootstrap** path against a directory they couldn't read.
- `Public/Register-EXOServicePrincipal.ps1:63`: same. On failure it skips the existence and name-conflict checks
  and attempts creation.

**Change:** `-ErrorAction Stop`; let the exception propagate. Callers already route it: `Get-` and
`New-RBAC4AppConfig` use `Write-Error`+return, and the result-object functions catch it into `Errors`. Check each
caller (`New-`, `Set-`, `Test-`, `Remove-`, `Get-RBAC4AppEntry`, `Invoke-RBAC4AppConfig`) to confirm the
resolve call is inside its outer `try`.

**Tests:** in `tests/` for the private helper (InModuleScope): mock `Get-ServicePrincipal { throw }` → the helper throws
(it doesn't return `$null`). One orchestrator test (`New-RBAC4AppEntry` bootstrap params) → `Errors` non-empty and
`New-ServicePrincipal` invoked 0 times.

---

### P3 [High] 4.1 `Register-EXOServicePrincipal` silent failure
**File:** `Public/Register-EXOServicePrincipal.ps1:79-83`
**Change:**
```powershell
if ($PSCmdlet.ShouldProcess("EXO ServicePrincipal for AppId $AppId", "Create/Ensure '$DisplayName'")) {
    try {
        return New-ServicePrincipal -AppId $AppId -ObjectId $ObjectId -DisplayName $DisplayName -ErrorAction Stop
    }
    catch {
        throw "Failed to create Exchange Online service principal '$DisplayName' (AppId '$AppId'): $($_.Exception.Message)"
    }
}
```
Remove the debug `Write-Warning "resultNewSP: ..."`.
- `-WhatIf`: ShouldProcess is false, so nothing is returned. Callers use `$null = ...`, so nothing changes.
- Callers abort the remaining steps (role assignments) for that item. This is the desired behavior, recorded in `Errors`.

**Tests** (`tests/Register-EXOServicePrincipal.Tests.ps1` or the existing file covering it):
- `New-ServicePrincipal` mock throws → the function throws with the AppId in the message.
- Success path no longer emits the `resultNewSP` warning (`-WarningVariable` empty).
- `New-RBAC4AppEntry`: `New-ServicePrincipal` throws → `Errors` contains the message, and `New-ManagementRoleAssignment` is invoked 0 times.

---

### P4 [Medium] 4.7 Empty sanitized names (non-ASCII display names)
**Files (guard goes in the name helpers, NOT in `Format-RBAC4AppSafeName`, which accepts empty input on purpose):**
- `Private/Get-RBAC4AppScopeGroupName.ps1:17`
- `Private/Get-RBAC4AppManagementScopeName.ps1:24` (only on the derived-name path, not an explicit `-Name`)
- `Private/Get-RBAC4AppRoleAssignmentName.ps1:12`

**Change:** sanitize `DisplayName` alone first. If the result is empty, throw
`"Application display name '<x>' contains no characters usable in an Exchange object name; supply -AccessGroupName / -ManagementScopeName explicitly."`
(The role-assignment helper has no override, so its message should say so. Note: if the role-assignment name
helper throws, apps with fully non-ASCII names can't be handled at all. **Decision for you:** throw, or fall back
to the AppId GUID without dashes, e.g. `MailRead-<appid32>`. Fallback is recommended for the role-assignment name only.)

**Do NOT** transliterate diacritics (e.g. `Zażółć`→`Zazolc`). That would change names for already-provisioned apps,
and `Set-`/`Test-`/`Remove-` would stop finding them.

**Tests:** `InModuleScope` helper tests: `DisplayName 'ąęł'` → throws (or falls back). Mixed `'Ząb App'` → still `ZbApp` (unchanged).

---

### P5 [Medium] 4.3 `MailEnabledSecurityGroup` type validation
**Files:** `Private/New-RBAC4AppScopeGroup.ps1:56`. Also consider read-side reporting in `Test-` :310,
`Set-` :428, and `Remove-` :241.
**Change:** after `Get-Recipient`, require
`$existing.RecipientTypeDetails -eq 'MailUniversalSecurityGroup'`, else throw
`"Recipient '<Name>' is of type '<type>'; -AccessGroupType MailEnabledSecurityGroup requires a mail-enabled security group."`
(The review's `MailNonUniversalGroup` is **not** a reliable security-group indicator. Leave it out unless you
have hybrid tenants that rely on it.)
- `Test-RBAC4AppEntry`: treat a wrong type as missing scope group (`Missing += 'ScopeGroup (wrong type)'`).
- `Remove-`: never deletes MESG anyway, so no change needed.

**Tests:**
- New: `Get-Recipient` returns `RecipientTypeDetails='UserMailbox'` → throws.
- **Update existing mocks** that return a MESG without `RecipientTypeDetails`, or the end-to-end tests will break:
  `tests/Convert-ApplicationAccessPolicyToRBAC.Tests.ps1` (end-to-end with `Invoke-RBAC4AppConfig`),
  `tests/Invoke-RBAC4AppConfig.Tests.ps1`, `tests/New-RBAC4AppEntry.Tests.ps1`, `tests/Set-`/`Test-` files.
  Grep: `Mock .* Get-Recipient` and add `RecipientTypeDetails = 'MailUniversalSecurityGroup'`.

**Compat:** Rejects configs that pointed at a non-security group. These were already broken at the scope/assignment step.

---

### P6 [Medium] 4.2 `New-RegisteredApp` with Graph disconnected
**File:** `Public/New-RegisteredApp.ps1:80-82`
**Change:**
```powershell
begin {
    $tenantId = $null
    try { $tenantId = (Get-MgContext -ErrorAction Stop).TenantId }
    catch { Write-Verbose -Message "TenantId unavailable: $($_.Exception.Message)" }
}
```
(`$null.TenantId` is safe under StrictMode for property access on `$null`. The crash comes from `Select-Object -ExpandProperty`.)
The later `New-MgApplication` call still fails in a clear way when Graph isn't connected.

**Tests:** `Get-MgContext` mock returns `$null`, and another that throws → the function proceeds to `New-MgApplication` and the output `TenantId` is `$null`.

---

### P7 [Medium] 4.4 DistributionGroup default prefix
**File:** `Public/New-RBAC4AppDistributionGroup.ps1:24` (help), `:85` (param)
**Change:** `'UDLRAo1'` → `'UDLRAo1P'`. Better: reference the shared default from `RBAC4AppDefaults.ps1` if a
variable for it exists, so the value lives in one place.
**Tests:** `-AppName 'MyApp' -WhatIf` → name `UDLRAo1P-MyApp`. Update any existing test asserting `UDLRAo1-`.
**Compat:** **Breaking** for direct callers relying on the default. Add a CHANGELOG `### Changed` entry.

---

### P8 [Low] 4.6 Result-object error model: documentation only
Per AGENTS.md convention #2, per-item failures go in `Errors` and are not thrown. Changing that is a design decision.
**Change:** add an "Automation / CI usage" note to the README and to `.NOTES` of `New-`/`Set-`/`Remove-RBAC4AppEntry`
and `Invoke-RBAC4AppConfig`:
```powershell
$r = New-RBAC4AppEntry ...; if ($r.Errors.Count) { throw ($r.Errors -join '; ') }
```
**Optional (your call):** a `-FailOnError` switch that `Write-Error`s the joined `Errors` after emitting the object.

---

### P9 [Low] Sweep for other `SilentlyContinue` reads that feed safety decisions
Quick audit (no fix unless it leads to a mutation):
- `Set-RBAC4AppEntry.ps1:468`, `:620` and `Test-RBAC4AppEntry.ps1:325`, `:394`: read-only/`Test-` false-negatives
  are acceptable. `Set-` :620 (`existing assignment` read failure → recreate attempt) gets a fail-closed check.
- `New-RBAC4AppEntry.ps1:546` and `Invoke-RBAC4AppConfig.ps1:449`: a failure means a duplicate-create attempt, which EXO rejects. Low risk.
- `Private/Get-RBAC4AppRoleAssignment.ps1:23,28`: read-only.

---

## 2. Execution order & verification
1. P1 → P2 → P3 (the fail-safe core). Run `./build.ps1 -Task Test` after each.
2. P5 (mock updates touch many test files), then P4, P6, P7.
3. P8 docs, P9 sweep.
4. `./build.ps1` (Analyze + Test + Build); coverage ≥ 90% (`./scripts/Show-CoverageGaps.ps1` for gaps).
5. `CHANGELOG.md` `[Unreleased]`: Fixed (P1-P6), Changed (P7 breaking), Docs (P8).
6. Update `plans/COMPLETENESS_AND_FAILSAFE_REVIEW.md` §4.5 with the correction (no `-ResultSize` on these cmdlets).

## 3. Decisions needed from you
1. **P4:** throw vs. AppId-based fallback for the role-assignment name when the display name sanitizes to empty.
2. **P5:** accept only `MailUniversalSecurityGroup`, or also `MailNonUniversalGroup`?
3. **P1 step 2:** do the server-side `-CustomRecipientWriteScope`/`-RecipientGroupScope` narrowing now, or later?
4. **P8:** docs only, or also add a `-FailOnError` switch?
