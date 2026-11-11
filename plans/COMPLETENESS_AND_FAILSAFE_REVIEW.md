# Review: Completeness and Fail-Safe Architecture

**Repository:** `EXORBACforAppManagement`  
**Date:** 2026-11-08  
**Scope:** Architecture completeness, fail-safe operation, defensive design, edge-case resilience, and error handling.

---

## 1. Executive Summary

`EXORBACforAppManagement` is a mature, well-architected PowerShell module designed to manage Exchange Online (EXO) Role-Based Access Control for Entra application service principals.

It effectively solves the known **MSAL/WAM assembly collision** between `Microsoft.Graph` and `ExchangeOnlineManagement` in a single PowerShell process by providing two decoupled paths:
1. **Exchange-Online-Only Operation**: Resolves Entra service principals purely through the EXO pointer (`Get-ServicePrincipal`) via the private helper `Resolve-RBAC4AppServicePrincipal`, avoiding any Graph session requirement for standard administration.
2. **Two-Session Decoupled Workflow**: Generates declarative, sparse YAML/JSON contracts via `New-RBAC4AppConfig` (Graph session) and provisions them via `Invoke-RBAC4AppConfig` (EXO session).

The module has strong defensive measures in place (e.g. teardown guards in `Remove-RBAC4AppEntry`, self-lockout prevention, and OPATH injection escaping). However, this review identified several **fail-safe vulnerabilities, silent error paths, and parameter inconsistencies** that should be resolved.

---

## 2. Completeness Assessment

### 2.1 Lifecycle Coverage Matrix

| Lifecycle Stage | Implementation Functions | Completeness | Assessment |
| :--- | :--- | :---: | :--- |
| **Creation & Provisioning** | `New-RBAC4AppEntry`, `New-RBAC4AppConfig`, `Invoke-RBAC4AppConfig`, `New-RegisteredApp` | **Complete** | Supports single-session bootstrapped creation (`-AppId`, `-SpObjectId`, `-RegisteredAppName`) and two-session Graph/EXO split. |
| **Inspection & Audit** | `Get-RBAC4AppEntry` | **Complete** | Assignment-centric and application-centric (`-ByApplication`) views. Resolves GUID pointers to real SMTP addresses and display names. |
| **Validation & Health** | `Test-RBAC4AppEntry` | **Complete** | Read-only verification of all five architectural tiers: resolvable SP, EXO pointer, scope group, management scope filter, and role assignments. |
| **Reconciliation & Drift Repair** | `Set-RBAC4AppEntry` | **Complete** | Declarative "make-it-so" reconciliation: repairs missing components, tops up membership additively, and migrates bindings (`RecipientGroupScope` $\leftrightarrow$ `ManagementScope`). |
| **Safe Teardown** | `Remove-RBAC4AppEntry` | **Complete** | High-impact guarded teardown checking for foreign assignments and active members before removing any assets. |
| **Legacy Migration** | `Convert-ApplicationAccessPolicyToRBAC` | **Complete** | Migrates legacy Application Access Policies directly into schema 4.2 RBAC configs while preserving existing scope groups. |
| **Component Primitives** | `New-RBAC4AppUnifiedGroup`, `New-RBAC4AppDistributionGroup`, `New-RBAC4AppManagementScope`, `Register-EXOServicePrincipal` | **Complete** | Individual building blocks are exported and callable independently. |

### 2.2 Scoping & Group Type Coverage
- **Scope Kinds**: `Group` (direct or management scope), `Recipients`, `Tag` (`CustomAttribute1..15`), and raw OPATH `Filter` are uniformly supported across the create/test/set/remove pipelines.
- **Group Types**: `DistributionList` (cloud native), `M365Group` (Unified Group), and `MailEnabledSecurityGroup` (hybrid on-premises reference-only) are supported with appropriate branch semantics.

---

## 3. Fail-Safe Work & Defensive Design (Strengths)

The module demonstrates robust defensive engineering in several critical areas:

1. **Foreign Role Assignment Guard**:
   In `Remove-RBAC4AppEntry`, teardown will abort and refuse to delete an Exchange management scope or group if any role assignment belongs to a different service principal.
2. **Active Member Guard**:
   Teardown refuses to delete the backing group if any active members exist beyond the initial `-BootstrapMember` (`GraphAPI-Dummy`).
3. **Hybrid Security Group Protection**:
   `MailEnabledSecurityGroup` instances are treated strictly as reference-only. They are never created, renamed, or deleted by `New-RBAC4AppScopeGroup` or `Remove-RBAC4AppEntry`.
4. **Self-Lockout Prevention**:
   Both `New-RBAC4AppEntry` and `Set-RBAC4AppEntry` inspect the executing administrator's UPN via `Get-ConnectionInformation` and automatically filter it out from membership lists, preventing accidental restriction of admin access.
5. **OPATH Injection Mitigation**:
   `ConvertTo-RBAC4AppRecipientFilter` strictly escapes single quotes (`$value.Replace("'", "''")`) to prevent filter injection.
6. **Strict Exchange Online Name Truncation**:
   `Format-RBAC4AppSafeName` and `RBAC4AppDefaults.ps1` enforce Exchange's 63-character limit for alias safety and 64-character limit for management scopes.
7. **Idempotent Operations**:
   `New-RBAC4AppEntry`, `Invoke-RBAC4AppConfig`, `New-RBAC4AppManagementScope`, and `Register-EXOServicePrincipal` check existence before creation. Re-running against an already-provisioned application does not duplicate assets or produce transient errors.

---

## 4. Issues & Fail-Safe Vulnerabilities Found

### 4.1 [High] Silent Failure & Leftover Debug Code in `Register-EXOServicePrincipal`
* **File:** `src/EXORBACforAppManagement/Public/Register-EXOServicePrincipal.ps1` (lines 80-84)
* **Code:**
  ```powershell
  if ($PSCmdlet.ShouldProcess("EXO ServicePrincipal for AppId $AppId", "Create/Ensure '$DisplayName'")) {
      $resultNewSP = New-ServicePrincipal -AppId $AppId -ObjectId $ObjectId -DisplayName $DisplayName -ErrorAction 0
      Write-Warning -Message "resultNewSP: $resultNewSP"
      return $resultNewSP
  }
  ```
* **The Issue:**
  1. `-ErrorAction 0` is `-ErrorAction SilentlyContinue`. If `New-ServicePrincipal` fails (e.g. invalid object ID, permission denial, API transient failure), the error is suppressed.
  2. `$resultNewSP` remains `$null`.
  3. `Write-Warning -Message "resultNewSP: $resultNewSP"` outputs a blank debug message to the console.
  4. The function returns `$null` without error.
* **Fail-Safe Impact:** Callers like `New-RBAC4AppEntry` (`$null = Register-EXOServicePrincipal ...`) assume the service principal pointer exists and proceed to call `New-ManagementRoleAssignment -App $sp.Id`, which subsequently fails with confusing downstream errors.
* **Remediation:** Remove `-ErrorAction 0`, wrap in `try/catch` with `New-ServicePrincipal ... -ErrorAction Stop`, remove the debug `Write-Warning`, and ensure any failure is thrown or properly surfaced.

---

### 4.2 [High] Uncaught Exception on Disconnected Graph in `New-RegisteredApp`
* **File:** `src/EXORBACforAppManagement/Public/New-RegisteredApp.ps1` (lines 80-82)
* **Code:**
  ```powershell
  begin {
      $tenantId = Get-MgContext | Select-Object -ExpandProperty TenantId
  }
  ```
* **The Issue:** If Microsoft Graph is not connected, `Get-MgContext` returns `$null`. When running under `Set-StrictMode -Version Latest`, `$null | Select-Object -ExpandProperty TenantId` throws:
  `Property "TenantId" cannot be found in the collection of objects.`
* **Fail-Safe Impact:** Unlike `Convert-ApplicationAccessPolicyToRBAC.ps1` (line 252) and `New-RBAC4AppConfig.ps1` (line 457) which use `try { $tenantId = (Get-MgContext -ErrorAction Stop).TenantId } catch { ... }`, `New-RegisteredApp` crashes during `begin` before entering its `process` block.
* **Remediation:** Guard `Get-MgContext` with `try/catch` or null-checking:
  ```powershell
  begin {
      $tenantId = $null
      try { $tenantId = (Get-MgContext -ErrorAction Stop).TenantId }
      catch { Write-Verbose "TenantId unavailable: $($_.Exception.Message)" }
  }
  ```

---

### 4.3 [Medium] Missing Group Type Validation in `New-RBAC4AppScopeGroup`
* **File:** `src/EXORBACforAppManagement/Private/New-RBAC4AppScopeGroup.ps1` (lines 54-59)
* **Code:**
  ```powershell
  'MailEnabledSecurityGroup' {
      Write-Verbose -Message ("Validating existing mail-enabled security group '{0}' (reference-only; not created)." -f $Name)
      $existing = Get-Recipient -Identity $Name -ErrorAction SilentlyContinue
      if (-not $existing) {
          throw "MailEnabledSecurityGroup '$Name' was not found. On-prem/hybrid-synced groups must already exist..."
      }
  ```
* **The Issue:** `Get-Recipient` resolves **any** recipient object in Exchange Online (e.g. `UserMailbox`, `SharedMailbox`, plain `DistributionGroup`).
* **Fail-Safe Impact:** If an admin mistakenly supplies a user mailbox or standard distribution group under `-AccessGroupType MailEnabledSecurityGroup`, validation passes. Later, when creating the management scope with `MemberOfGroup -eq '<User DN>'`, Exchange Online either fails to bind or creates an invalid scope filter.
* **Remediation:** Validate that the resolved recipient is actually a security group:
  ```powershell
  if ($existing.RecipientTypeDetails -notin @('MailUniversalSecurityGroup', 'MailNonUniversalGroup')) {
      throw "Recipient '$Name' was found, but is of type '$($existing.RecipientTypeDetails)'. -AccessGroupType MailEnabledSecurityGroup requires a mail-enabled security group."
  }
  ```

---

### 4.4 [Medium] Inconsistent Default Prefix for `New-RBAC4AppDistributionGroup`
* **File:** `src/EXORBACforAppManagement/Public/New-RBAC4AppDistributionGroup.ps1` (lines 24 and 85)
* **Code:**
  ```powershell
  [Parameter(ParameterSetName = 'ByAppName')]
  [ValidateNotNullOrEmpty()]
  [string] $Prefix = 'UDLRAo1',
  ```
* **The Issue:** Everywhere else in the module (`RBAC4AppDefaults.ps1`, `New-RBAC4AppEntry.ps1`, and `New-RBAC4AppConfig.ps1`), the default prefix for `DistributionList` is `'UDLRAo1P'` (with a trailing `P` for Permission/Policy). In `New-RBAC4AppDistributionGroup.ps1`, it defaults to `'UDLRAo1'` without the trailing `P`.
* **Fail-Safe Impact:** Directly calling `New-RBAC4AppDistributionGroup -AppName 'MyApp'` generates `UDLRAo1-MyApp`, whereas calling `New-RBAC4AppEntry -RegisteredAppName 'MyApp'` looks for and creates `UDLRAo1P-MyApp`. This causes mismatch and duplicate group creation across tools.
* **Remediation:** Change the default parameter to `[string] $Prefix = 'UDLRAo1P'`.

---

### 4.5 [Medium] Unbounded Exchange Online Result Capping (`ResultSize 1000`)
* **Files:**
  - `src/EXORBACforAppManagement/Private/Resolve-RBAC4AppServicePrincipal.ps1` (line 35)
  - `src/EXORBACforAppManagement/Public/Remove-RBAC4AppEntry.ps1` (line 258)
  - `src/EXORBACforAppManagement/Public/Get-RBAC4AppEntry.ps1` (line 334)
* **Code:**
  ```powershell
  Get-ServicePrincipal -ErrorAction SilentlyContinue
  Get-ManagementRoleAssignment -ErrorAction SilentlyContinue
  ```
* **The Issue:** In Exchange Online PowerShell, unfiltered `Get-ManagementRoleAssignment` and `Get-ServicePrincipal` default to returning a maximum of 1,000 items (`-ResultSize 1000`).
* **Fail-Safe Impact:** In large enterprise tenants with $>1000$ service principals or role assignments:
  - In `Resolve-RBAC4AppServicePrincipal`, service principals beyond index 1,000 are not found, causing false "not found" errors.
  - In `Remove-RBAC4AppEntry`, if a foreign role assignment exists beyond the first 1,000 results, it will not be detected. The safety check will pass, leading to accidental deletion of a shared management scope.
* **Remediation:** Add `-ResultSize Unlimited` to all unfiltered retrieval cmdlets.
* **Correction (2026-11-08):** this remediation is **invalid** - per Microsoft Learn, neither EXO
  `Get-ManagementRoleAssignment` nor `Get-ServicePrincipal` has a `-ResultSize` parameter (adding it
  fails parameter binding). The real fail-open defect was `-ErrorAction SilentlyContinue` on these
  safety-gating reads; fixed instead by failing closed. See `plans/FAILSAFE_REMEDIATION_PLAN.md` (P1/P2).

---

### 4.6 [Low] Error Pipeline Masking in Public Entry Points
* **Files:** `New-RBAC4AppEntry.ps1`, `Invoke-RBAC4AppConfig.ps1`, `Set-RBAC4AppEntry.ps1`, `Remove-RBAC4AppEntry.ps1`
* **The Issue:** Top-level `catch` blocks intercept all exceptions and append `$_.Exception.Message` to `$result.Errors`, returning the summary object.
* **Fail-Safe Impact:** No record is emitted to the PowerShell Error Stream (`$Error`). In CI/CD pipelines or scripts running with `$ErrorActionPreference = 'Stop'`, the script will not fail on error, and `$?` remains `$true`.
* **Remediation:** Ensure documentation clearly instructs callers in automation to check `$result.Errors.Count -eq 0` or `$result.IsValid`, or consider providing a switch / emitting a non-terminating error before returning.

---

### 4.7 [Low] Non-ASCII Display Name Collapse in `Format-RBAC4AppSafeName`
* **File:** `src/EXORBACforAppManagement/Private/Format-RBAC4AppSafeName.ps1` (line 15)
* **Code:**
  ```powershell
  $clean = ($Value -replace '[^A-Za-z0-9\-]', '')
  ```
* **The Issue:** If an application display name consists solely of non-ASCII characters (e.g. Polish diacritics, German umlauts, Kanji), `$clean` collapses to an empty string.
* **Fail-Safe Impact:** Object names become invalid bare prefixes (e.g. `MSRAo1P-` or `UDLRAo1P-`), resulting in Exchange creation errors.
* **Remediation:** Add validation to ensure `$clean` is not empty, falling back to a sanitized `AppId` or throwing a descriptive error prompting the user to supply `-AccessGroupName`.

---

## 5. Action Items & Remediation Checklist

- [ ] **Fix `Register-EXOServicePrincipal` error handling**:
  - Remove `-ErrorAction 0`.
  - Wrap in `try/catch` with `-ErrorAction Stop`.
  - Remove leftover `Write-Warning -Message "resultNewSP: $resultNewSP"`.
- [ ] **Harden `New-RegisteredApp` against disconnected Graph session**:
  - Wrap `Get-MgContext` in `begin` with `try/catch`.
- [ ] **Correct default prefix in `New-RBAC4AppDistributionGroup`**:
  - Update `$Prefix` default from `'UDLRAo1'` to `'UDLRAo1P'`.
- [ ] **Add security group recipient type check in `New-RBAC4AppScopeGroup`**:
  - Assert `$existing.RecipientTypeDetails -in @('MailUniversalSecurityGroup', 'MailNonUniversalGroup')`.
- [ ] **Add `-ResultSize Unlimited` to Exchange Online queries**:
  - Add to `Get-ServicePrincipal` in `Resolve-RBAC4AppServicePrincipal.ps1`.
  - Add to `Get-ManagementRoleAssignment` in `Remove-RBAC4AppEntry.ps1` and `Get-RBAC4AppEntry.ps1`.
- [ ] **Update Pester test stubs and test cases**:
  - Update `Get-ServicePrincipal` and `Get-ManagementRoleAssignment` stubs to accept `-ResultSize`.
  - Add unit test asserting `Register-EXOServicePrincipal` throws on creation failure.
  - Add unit test asserting `New-RBAC4AppScopeGroup` rejects non-security group recipients for `MailEnabledSecurityGroup`.

