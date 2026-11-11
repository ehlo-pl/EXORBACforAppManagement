# Configuration schema 4.3

Schema 4.3 is the version written by `New-RBAC4AppConfig`, `Export-RBAC4AppConfig`, and
`Convert-ApplicationAccessPolicyToRBAC`. `Invoke-RBAC4AppConfig` reads YAML or JSON with this same
structure and accepts only `SchemaVersion: "4.3"` - a file of an earlier version is rejected and must
be re-generated. The file is a handoff, not a credential store: it identifies an
application and describes the Exchange Online RBAC resources to provision.

## Document shape

The document has the following top-level properties:

| Property | Required in generated files | Description |
| --- | --- | --- |
| `SchemaVersion` | Yes | The string `"4.3"`. |
| `Application` | Yes | Application identity; `AppId`, `SpObjectId`, and `DisplayName` are required. |
| `Rbac` | Yes | Desired Exchange Online roles and optional change reference. |
| `RbacScope` | No | Scope, assignment binding, and (for Group) group provisioning settings. |
| `Metadata` | No | Descriptive information; never affects provisioning. Always written in full by the module (empty values as `""`). |
| `ConversionResult` | No | Written only by `Convert-ApplicationAccessPolicyToRBAC`: that function's per-policy result. Never affects provisioning. |
| `Runtime` | No | Generation timestamp, operator username/machine name and errors/warnings collected by the writer while building the file; never affects provisioning. Always written in full by the module (empty lists as `[]`). |

`Application` fields:

| Property | Type | Description |
| --- | --- | --- |
| `AppId` | string | Entra application (client) ID. |
| `SpObjectId` | string | Entra service-principal object ID. |
| `DisplayName` | string | Application display name. |
| `TenantId` | string | Optional. Tenant ID for reference; written only when known, and never used to provision the resources. |

`Rbac` fields:

| Property | Type | Default / behavior |
| --- | --- | --- |
| `Roles` | array of strings | Required. Role names are normalized to `Application <permission>`; short names such as `Mail.Send` are accepted. |
| `ChangeReference` | string | Omitted/empty by default. Carried into the provisioning result and local change-reference record. |

## Scope and assignment

All `RbacScope` properties are optional in the file; omitted properties receive the defaults below.
Properties that do not apply to the selected `ScopeKind` or `AssignmentScope` are ignored by the
provisioner.

| Property | Type | Default / valid values |
| --- | --- | --- |
| `ScopeKind` | string | `Group` by default; `Group`, `Recipients`, `Tag`, or `Filter`. |
| `AssignmentScope` | string | For `Group`, defaults to `RecipientGroupScope` (bind assignments directly to the group). Also accepts `ManagementScope`. Non-Group kinds always use `ManagementScope`; `RecipientGroupScope` is valid only with `Group`. |
| `AccessGroupType` | string | `DistributionList` by default; `DistributionList`, `M365Group`, or `MailEnabledSecurityGroup`. Used only for `Group`. |
| `AccessGroupName` | string | Explicit scope group name. If omitted, the name is generated from `GroupPrefix` and the application display name. Required for `MailEnabledSecurityGroup`. |
| `GroupPrefix` | string | Used to generate the group name when `AccessGroupName` is absent. Defaults by group type to `UDLRAo1P` (DistributionList), `Um365RAo1P` (M365Group), or `USRAo1P` (MailEnabledSecurityGroup). |
| `Members` | array of strings | Defaults to `["GraphAPI-Dummy"]`. An explicit empty array means no members were requested. Only used for `Group`; membership for a mail-enabled security group is managed on-premises and is not changed. |
| `ManagedBy` | array of strings | Defaults to `["GraphAPI-Dummy-owner"]`. Used as group owners where supported. |
| `BootstrapMember` | string | Defaults to `"GraphAPI-Dummy"`. Initial placeholder passed when creating a group. An explicitly empty string disables it. |
| `SeparateScopePerRole` | boolean | Defaults to `false`. When `true`, provisions a separate group per role and, when `AssignmentScope: ManagementScope`, a separate management scope per role; valid only with `ScopeKind: Group`. |
| `ManagementScopeName` | string | Explicit management scope name, used with `AssignmentScope: ManagementScope`; mutually exclusive with `ManagementScopePrefix`. |
| `ManagementScopePrefix` | string | Used to generate the management scope name; defaults to `MSRAo1P`. Ignored with `RecipientGroupScope`. |
| `ScopeRecipients` | array of strings | Required for `ScopeKind: Recipients`. The listed mailbox addresses/UPNs define the scope. |
| `ScopeTagAttribute` | string | For `ScopeKind: Tag`, one of `CustomAttribute1` through `CustomAttribute15`; defaults to `CustomAttribute1`. |
| `ScopeTagValue` | string | For `ScopeKind: Tag`, value matched on the selected attribute. If absent, the generated or explicit management scope name is used. |
| `ScopeFilter` | string | Required for `ScopeKind: Filter`. Raw Exchange OPATH recipient restriction filter. |

`ScopeKind` chooses the recipient set:

- **Group** — group members. This is the only kind that provisions a scope group and supports
  `RecipientGroupScope`.
- **Recipients** — the explicit `ScopeRecipients` list.
- **Tag** — recipients matching the chosen custom attribute and tag value. The module does not
  stamp the attribute.
- **Filter** — recipients matching `ScopeFilter`.

The last three kinds use an Exchange Online management scope. For Group, choosing
`AssignmentScope: ManagementScope` also creates/uses a management scope; the default direct-group
binding creates no management scope. `AccessGroupName` and `GroupPrefix` are mutually exclusive.
When using `ManagementScopeName`, do not also set `ManagementScopePrefix`.

## Metadata

Every `Metadata` property is optional and descriptive. Values are returned with the provisioning
result; they do not influence application identity, group membership, scopes, or role assignments.

| Property | Type | Validation / meaning |
| --- | --- | --- |
| `OwnerUsername` | string | Application owner contact username; stored as supplied. |
| `OwnerDisplayName` | string | Application owner contact display name; stored as supplied. |
| `TechnicalContactUsername` | string | Technical contact username; stored as supplied. |
| `TechnicalContactDisplayName` | string | Technical contact display name; stored as supplied. |
| `PCode` | string | Uppercase `P` followed by five digits, e.g. `P12345`; the config writer normalizes input to uppercase. |
| `CmdbId` | string | GUID, compact or hyphenated. |
| `Description` | string | Single line; may contain links. |
| `NetworkAccessIP4Range` | string | IPv4 address or IPv4 CIDR range, e.g. `10.0.0.0/24`. Independent of `NetworkAccessIP6Range` and `NetworkAccessLocation`. A `NetworkAccessIPRange` key (the IPv4-only field before the split) is read as `NetworkAccessIP4Range`. |
| `NetworkAccessIP6Range` | string | IPv6 address or IPv6 CIDR range (prefix 0-128, no zone id), e.g. `2001:db8::/32`. Independent of `NetworkAccessIP4Range` and `NetworkAccessLocation`. |
| `NetworkAccessLocation` | string | Name from the module's `locations.txt`, matched case-insensitively. The shipped list is a placeholder for organization-specific values. |

The consumer revalidates metadata because files may be edited after generation. It does not resolve
contact names against a directory.

## ConversionResult

Written only by `Convert-ApplicationAccessPolicyToRBAC`, as the full per-policy result object it
returns (except its `Warnings`/`Errors`, which are in `Runtime.CollectedWarnings`/`CollectedErrors`).
Informational: `Invoke-RBAC4AppConfig` never acts on it. When written, every property is present
(empty values as `""`, empty lists as `[]`).

| Property | Type | Meaning |
| --- | --- | --- |
| `AppId` | string | AppId of the Application Access Policy. |
| `ResolvedDisplay` | string | Display name resolved for the application. |
| `AccessRight` | string | Policy access right (`RestrictAccess` / `DenyAccess`). |
| `ScopeGroup` | string | The policy's `ScopeName` group, kept as `RbacScope.AccessGroupName`. |
| `DerivedRoles` | array of strings | App RBAC roles derived from the app's granted Graph permissions. |
| `SkippedPermissions` | array of strings | Granted permissions with no App RBAC role mapping. |
| `ConfigPath` | string | Path the config file was written to. |

## Runtime

`Runtime` records what happened while the file was generated. It is informational:
`Invoke-RBAC4AppConfig` reads it but never acts on it, and hand-written files may omit it.

| Property | Type | Meaning |
| --- | --- | --- |
| `GeneratedAt` | string | UTC timestamp in ISO 8601 / RFC 3339 form. Before schema 4.3 this was a top-level property; a legacy top-level value is still read into `Runtime.GeneratedAt` by the module's readers (but `Invoke-RBAC4AppConfig` rejects pre-4.3 files). |
| `OperatorUsername` | string | Username of the session that generated the file (`DOMAIN\user` when the account belongs to a domain other than the machine). |
| `OperatorMachineName` | string | Name of the machine the file was generated on. |
| `CollectedErrors` | array of strings | Errors the writer collected for this application (e.g. from `Convert-ApplicationAccessPolicyToRBAC`). |
| `CollectedWarnings` | array of strings | Warnings the writer collected - for example that `Application.SpObjectId` was taken from a role assignment's `EffectiveUserName` because the service principal object id came back empty, or that a scope group type was inferred. |

Like `Metadata`, the writer always emits the whole section with every property, writing `[]` for an
empty list. Hand-written files may omit the section or any property; a missing list reads as empty
and a missing operator field as `""`.

```yaml
Runtime:
  GeneratedAt: "2026-09-20T10:30:00Z"
  OperatorUsername: "CONTOSO\\jdoe"
  OperatorMachineName: "ADMIN-WS01"
  CollectedErrors: []
  CollectedWarnings:
    - "ServicePrincipalId/SpObjectId for 'Contoso Mail App' was returned empty (...); using 'bbbbbbbb-...' from EffectiveUserName instead."
```

## Defaults and sparse documents

The writer omits settings that are not used by the selected scope kind or assignment binding, as
well as ordinary empty values and values equal to defaults. The consumer restores missing settings
to the defaults above. Two explicit-empty overrides are significant: `Members: []` prevents the
default placeholder member from being used, and `BootstrapMember: ""` disables the bootstrap
member. These are different from omitting the keys.

`SchemaVersion`, `Application`, `Rbac.Roles`, and `Runtime` (with `GeneratedAt`) are always emitted by the writer; an absent
`RbacScope` is interpreted using the defaults above.

`Metadata` is the exception to sparseness: the writer always emits the whole section with every
property, using `""` for values that were not supplied, so a generated file lists every descriptive
field to fill in. An empty value means "not set" and is not validated. Hand-written files may still
omit the section or any of its properties.

## Examples

Minimal YAML for a direct group assignment:

```yaml
SchemaVersion: "4.3"
Application:
  AppId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  SpObjectId: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
  DisplayName: "Contoso Mail App"
Rbac:
  Roles:
    - "Application Mail.Send"
RbacScope:
  Members:
    - "shared@contoso.com"
```

Non-Group scopes and Group assignments using a management scope:

```yaml
RbacScope:
  ScopeKind: "Recipients"
  ScopeRecipients:
    - "shared@contoso.com"
  ManagementScopeName: "Contoso-Mail-Scope"
```

```yaml
RbacScope:
  AssignmentScope: "ManagementScope"
  ManagementScopePrefix: "MSRAo1P"
  AccessGroupName: "UDLRAo1P-ContosoMailApp"
  Members:
    - "shared@contoso.com"
```

The equivalent JSON document uses the same property names, nesting, values, and omission/default
rules.

## Machine-readable schema

See [SCHEMA-4.3.schema.json](SCHEMA-4.3.schema.json) for the corresponding JSON Schema Draft 2020-12
description. It is provided for tooling and documentation; `Invoke-RBAC4AppConfig` does not use it
as its validator. In particular, valid `NetworkAccessLocation` values are tenant/module-specific
and are checked against `locations.txt` at runtime.
