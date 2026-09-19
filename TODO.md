# TODO

[x] convert [ApplicationAccessPolices](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-access-policies) entries into RBAC for application (Convert-ApplicationAccessPolicyToRBAC)

[x] by design get-RBAC4AppEntry should show only RoleAssigneeType -eq 'ServicePrincipal' and (RecipientScope -eq Group) or (RecipientScope -eq CustomRecipientScope))

[x] add to results of  New-RBAC4AppEntry  and New-RBAC4AppUnifiedGroup name of used owner (both requested, and added similarly to member)
