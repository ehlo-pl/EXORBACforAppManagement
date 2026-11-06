# Configuration schema 4.2

Schema 4.2 is the version written by `New-RBAC4AppConfig`. `Invoke-RBAC4AppConfig` reads YAML or
JSON with this same structure. The file is a handoff, not a credential store: it identifies an
application and describes the Exchange Online RBAC resources to provision.

## Document shape

The document has the following top-level properties:

| Property | Required in generated files | Description |
| --- | --- | --- |
| `SchemaVersion` | Yes | The string `"4.2"`. |
| `GeneratedAt` | Yes | UTC timestamp in ISO 8601 / RFC 3339 form. |
| `TenantId` | No | Tenant ID for reference; defaults to an empty value and is not used to provision the resources. |
| `Application` | Yes | Application identity; all three fields below are required. |
| `Rbac` | Yes | Desired Exchange Online roles and optional change reference. |
| `RbacScope` | No | Scope, assignment binding, and (for Group) group provisioning settings. |
| `Metadata` | No | Optional descriptive information; never affects provisioning. |

`Application` fields:

| Property | Type | Description |
| --- | --- | --- |
| `AppId` | string | Entra application (client) ID. |
| `SpObjectId` | string | Entra service-principal object ID. |
| `DisplayName` | string | Application display name. |

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
| `NetworkAccessIPRange` | string | IPv4 address or IPv4 CIDR range. Independent of `NetworkAccessLocation`. |
| `NetworkAccessLocation` | string | Name from the module's `locations.txt`, matched case-insensitively. The shipped list is a placeholder for organization-specific values. |

The consumer revalidates metadata because files may be edited after generation. It does not resolve
contact names against a directory.

## Defaults and sparse documents

The writer omits settings that are not used by the selected scope kind or assignment binding, as
well as ordinary empty values and values equal to defaults. The consumer restores missing settings
to the defaults above. Two explicit-empty overrides are significant: `Members: []` prevents the
default placeholder member from being used, and `BootstrapMember: ""` disables the bootstrap
member. These are different from omitting the keys.

`GeneratedAt`, `Application`, and `Rbac.Roles` are always emitted by the writer; an absent
`RbacScope` is interpreted using the defaults above.

## Examples

Minimal YAML for a direct group assignment:

```yaml
SchemaVersion: "4.2"
GeneratedAt: "2026-09-20T10:30:00Z"
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

See [SCHEMA-4.2.schema.json](SCHEMA-4.2.schema.json) for the corresponding JSON Schema Draft 2020-12
description. It is provided for tooling and documentation; `Invoke-RBAC4AppConfig` does not use it
as its validator. In particular, valid `NetworkAccessLocation` values are tenant/module-specific
and are checked against `locations.txt` at runtime.
