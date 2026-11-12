# Scope group hardening: no-send restriction + cloud security group by default

Status: **implemented 2026-11-12 (approved; together with the config schema bump to 4.4)**. Target: 0.9.0 (unreleased,
breaking changes allowed).

## Request

1. Every scope group the module **creates** must not accept mail: only the standard owner
   (`GraphAPI-Dummy-owner`, the default `-ManagedBy`) is an allowed sender.
2. The default group type for `-ScopeKind Group` changes from an Exchange Online distribution list to an
   Exchange-Online-mastered **mail-enabled security group** (`New-DistributionGroup -Type Security`).

(The request says `-ScopeType Group`; in the provisioning functions that is `-ScopeKind Group`.
`-ScopeType` is the read filter of `Get-RBAC4AppEntry` and is not affected.)

Microsoft Learn confirms RBAC for Applications supports M365 groups, mail-enabled security groups and
distribution lists for `MemberOfGroup` / `-RecipientGroupScope` (direct members only), so the switch
changes no scoping behaviour.

## Target model

| `-AccessGroupType` | Meaning | Created by module | Default prefix |
|---|---|---|---|
| `CloudMailEnabledSecurityGroup` (**new default**) | EXO-mastered mail-enabled security group | yes - `New-DistributionGroup -Type Security` | `USRACo1P` |
| `DistributionList` | EXO distribution list | yes - `-Type Distribution` | `UDLRAo1P` (unchanged) |
| `M365Group` | Unified Group | yes | `Um365RAo1P` (unchanged) |
| `HybridMailEnabledSecurityGroup` (renamed from `MailEnabledSecurityGroup`) | on-prem/hybrid-synced group, **reference-only** (never created, re-membered, or restricted) | no | `USRAHo1P` (was `USRAo1P`) |

Existing `USRAo1P-*` groups are, by definition, hybrid MESGs ("MailEnabledSecurityGroup Hybrid").

## Decisions

| # | Decision |
|---|---|
| S1 | New value `CloudMailEnabledSecurityGroup` (prefix `USRACo1P`), the new default. The reference-only type is renamed `HybridMailEnabledSecurityGroup` (prefix `USRAHo1P`). |
| S1a | `MailEnabledSecurityGroup` stays accepted **as an input alias** of `HybridMailEnabledSecurityGroup` (parameters and config files read); every writer emits the new name. |
| S3 | On create (`CloudMailEnabledSecurityGroup`, `DistributionList`, `M365Group`): always `RequireSenderAuthenticationEnabled = $true`; `AcceptMessagesOnlyFromSendersOrMembers = <resolved -ManagedBy owners>`. If no owner resolves to a recipient, the restriction is **skipped with a warning** (group still created, sender authentication still required). |
| S3a | `New-RBAC4AppConfig` warns at config time when a creatable group type keeps the **default owner** `GraphAPI-Dummy-owner` (it must exist as an EXO recipient, or the send restriction will be skipped). The warning lands in `Runtime.CollectedWarnings`. |
| S4 | Existing groups: `New-RBAC4AppEntry` / `Invoke-RBAC4AppConfig` leave them alone but warn if not send-restricted; `Set-RBAC4AppEntry` applies the restriction when missing; `Test-RBAC4AppEntry` reports a new `SendRestricted` flag (a warning, not `IsValid = $false`). Hybrid groups are never touched or checked. |
| S5 | Default switches from `DistributionList` to `CloudMailEnabledSecurityGroup` in `New-`/`Set-`/`Test-`/`Remove-RBAC4AppEntry`, `New-RBAC4AppConfig`, and `$script:RBAC4AppConfigDefaults` (so a sparse config without `AccessGroupType` now means the cloud security group - called out in the CHANGELOG). |
| S6 | `Resolve-RBAC4AppScope` (read side) maps a `MailUniversalSecurityGroup` with `IsDirSynced = $false` to `CloudMailEnabledSecurityGroup`, a dir-synced one (and `MailNonUniversalGroup`) to `HybridMailEnabledSecurityGroup`; `Export-RBAC4AppConfig` round-trips accordingly. `Export -Force` on an unreadable group and `Convert-ApplicationAccessPolicyToRBAC` write `HybridMailEnabledSecurityGroup` (still reference-only). |

## Implementation

1. **Defaults** (`RBAC4AppDefaults.ps1`): `Get-RBAC4AppDefaultGroupPrefix` gets
   `CloudMailEnabledSecurityGroup -> USRACo1P`, `HybridMailEnabledSecurityGroup -> USRAHo1P`;
   `$script:RBAC4AppConfigDefaults.AccessGroupType = 'CloudMailEnabledSecurityGroup'`; a shared
   `$script:RBAC4AppAccessGroupTypes` list and a small private `ConvertTo-RBAC4AppAccessGroupType`
   that maps the `MailEnabledSecurityGroup` alias to `HybridMailEnabledSecurityGroup`.
2. **ValidateSets**: every `-AccessGroupType` set (New-/Set-/Test-/Remove-RBAC4AppEntry, New-RBAC4AppConfig,
   New-RBAC4AppScopeGroup) lists the four values plus the alias; each function normalizes the alias at
   the top of `begin`/`process`. Config reading (`Complete-RBAC4AppConfig`, `Invoke-RBAC4AppConfig`
   validation) normalizes the same way.
3. **`New-RBAC4AppDistributionGroup`**: new `-GroupType Distribution|Security` (default `Security`);
   `New-DistributionGroup -Type $GroupType`; existing-group check verifies `RecipientTypeDetails` matches
   the requested kind (a DL found where a security group is expected is a type-mismatch error, not
   silently used). Summary gains `GroupType`, `SendRestricted`.
4. **New private `Set-RBAC4AppScopeGroupSendRestriction`** (used by both create helpers and
   `Set-RBAC4AppEntry`): resolves owners via `Get-Recipient`, calls `Set-DistributionGroup` /
   `Set-UnifiedGroup` with `RequireSenderAuthenticationEnabled $true` and, when at least one owner
   resolved, `AcceptMessagesOnlyFromSendersOrMembers`; returns `{ SendRestricted; Warnings }`. Gated by
   `ShouldProcess` in the callers. A companion read `Test-RBAC4AppScopeGroupSendRestriction` returns
   whether a group's `AcceptMessagesOnlyFromSendersOrMembers` is non-empty.
5. **`New-RBAC4AppUnifiedGroup`**: post-create calls the helper; summary gains `SendRestricted`.
6. **`New-RBAC4AppScopeGroup`** dispatcher: `CloudMailEnabledSecurityGroup` -> `New-RBAC4AppDistributionGroup
   -GroupType Security`; `DistributionList` -> `-GroupType Distribution`; `HybridMailEnabledSecurityGroup`
   -> today's reference-only branch.
7. **Type branches** in New-/Set-/Test-/Remove-RBAC4AppEntry and Invoke-RBAC4AppConfig: the cloud type
   follows the `DistributionList` path (`Get-DistributionGroup`, `Add-/Get-DistributionGroupMember`,
   `Remove-DistributionGroup`); every `MailEnabledSecurityGroup` comparison becomes
   `HybridMailEnabledSecurityGroup`.
8. **S4**: New-/Invoke warn on an existing unrestricted group; Set- applies the helper; Test- adds
   `SendRestricted` + warning.
9. **S3a**: `New-RBAC4AppConfig` warning when the effective `ManagedBy` is the default and the type is
   creatable.
10. **S6**: `Resolve-RBAC4AppScope` mapping via `IsDirSynced`; `ConvertTo-RBAC4AppConfigFromEntry` /
    `Convert-ApplicationAccessPolicyToRBAC` write `HybridMailEnabledSecurityGroup`.
11. **Tests**: stubs gain `-Type`, `-AcceptMessagesOnlyFromSendersOrMembers`,
    `-RequireSenderAuthenticationEnabled`, `IsDirSynced`. New cases per created type: restriction set;
    unresolvable owner -> warning, sender auth still set; `-WhatIf` makes no `Set-*` call; existing
    unrestricted group -> warn (New/Invoke) / fixed (Set) / flagged (Test); type mismatch; default is
    now the cloud security group; Remove of a cloud security group; alias accepted on input and
    written as the new name; S3a warning; S6 mapping. Existing tests updated for the rename; golden
    files regenerated with diffs reviewed.
12. **Docs**: README (types table, defaults, prefixes, hardening), AGENTS.md (scope-group and `-GroupPrefix`
    bullets), `docs/SCHEMA-4.3.md` (`AccessGroupType` values/default/alias), CHANGELOG (Added/Changed,
    breaking default and rename).
13. `./build.ps1 -Task All` green (>= 90% coverage). Nothing committed.

## Risks / to verify live
- `AcceptMessagesOnlyFromSendersOrMembers` needs a resolvable recipient; until `GraphAPI-Dummy-owner`
  exists in a tenant, every create warns and the group is only sender-authentication-restricted.
- Creating mail-enabled security groups uses the same EXO role as distribution groups - verify once live.
- `IsDirSynced` on `Get-DistributionGroup` output is assumed for S6; verify the property name live.
