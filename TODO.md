# TODO

[x] convert [ApplicationAccessPolices](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-access-policies) entries into RBAC for application (Convert-ApplicationAccessPolicyToRBAC)

[x] by design get-RBAC4AppEntry should show only RoleAssigneeType -eq 'ServicePrincipal' and (RecipientScope -eq Group) or (RecipientScope -eq CustomRecipientScope))

[x] add to results of  New-RBAC4AppEntry  and New-RBAC4AppUnifiedGroup name of used owner (both requested, and added similarly to member)

[x] rename UnifiedGroupName (and sibling UnifiedGroupExists/UnifiedGroupExisted/UnifiedGroupCreated) to ScopeGroupName/ScopeGroupExists/ScopeGroupExisted/ScopeGroupCreated across New-/Set-/Test-/Remove-RBAC4AppEntry and Invoke-RBAC4AppConfig

[x] warn (and record in Warnings) when -ManagedBy or -BootstrapMember is set to a non-default value for -AccessGroupType MailEnabledSecurityGroup, matching the existing -Members-ignored warning

[x] add MembersFinal (full current group membership, not just what was added) to the results of New-RBAC4AppEntry, Set-RBAC4AppEntry, and Invoke-RBAC4AppConfig
