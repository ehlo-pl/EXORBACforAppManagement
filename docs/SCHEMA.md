# Configuration schema

## Assumptions

- Configuration files are a plain-text handoff from `New-RBAC4AppConfig` (a Microsoft Graph
  session) to `Invoke-RBAC4AppConfig` (an Exchange Online session). They contain no credentials.
- YAML (`.yml`/`.yaml`) and JSON (`.json`) use the same data model; only serialization differs.
- The writer emits a sparse document: it omits unused settings, empty values, and values equal to
  defaults. A missing setting means “use the default,” not “leave unset.” Explicit empty
  `RbacScope.Members` and `RbacScope.BootstrapMember` values are preserved as overrides. The
  `Metadata` section is the exception: it is always written with every property, empty as `""`.
- `Metadata` is descriptive only. It is returned to the caller but does not affect provisioning.
- The versioned documents below describe the current schema only. Older versions are mentioned
  only where needed to explain the current reader's compatibility behavior.

## Current version

| Version | Specification |
| --- | --- |
| 4.3 (current) | [SCHEMA-4.3.md](SCHEMA-4.3.md) |

The optional machine-readable [JSON Schema](SCHEMA-4.3.schema.json) is separate from the
documentation. The module does not invoke a JSON Schema validator; `Invoke-RBAC4AppConfig` performs
its own validation, including checks whose valid values depend on the tenant's `locations.txt`.
