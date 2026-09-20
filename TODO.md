# TODO

[x] convert [ApplicationAccessPolices](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-access-policies) entries into RBAC for application (Convert-ApplicationAccessPolicyToRBAC)

[x] by design get-RBAC4AppEntry should show only RoleAssigneeType -eq 'ServicePrincipal' and (RecipientScope -eq Group) or (RecipientScope -eq CustomRecipientScope))

[x] add to results of  New-RBAC4AppEntry  and New-RBAC4AppUnifiedGroup name of used owner (both requested, and added similarly to member)

[x] rename UnifiedGroupName (and sibling UnifiedGroupExists/UnifiedGroupExisted/UnifiedGroupCreated) to ScopeGroupName/ScopeGroupExists/ScopeGroupExisted/ScopeGroupCreated across New-/Set-/Test-/Remove-RBAC4AppEntry and Invoke-RBAC4AppConfig

[x] warn (and record in Warnings) when -ManagedBy or -BootstrapMember is set to a non-default value for -AccessGroupType MailEnabledSecurityGroup, matching the existing -Members-ignored warning

[x] add MembersFinal (full current group membership, not just what was added) to the results of New-RBAC4AppEntry, Set-RBAC4AppEntry, and Invoke-RBAC4AppConfig

[x] verify that every creation path checks whether the target object (Exchange Online service principal, scope group) already exists and skips creation when it does - New-RBAC4AppUnifiedGroup/New-RBAC4AppDistributionGroup already check before creating, but Register-EXOServicePrincipal calls New-ServicePrincipal unconditionally and relies on its callers (New-/Set-RBAC4AppEntry) to check first

[x] mitigate "Authentication needed. Please call Connect-MgGraph." terminating error from Get-RegisteredAppWithPermission when run in an EXO-only session - it unconditionally calls Get-MgServicePrincipal -ErrorAction Stop with no try/catch to reverse-resolve each EXO assignee, unlike Get-RBAC4AppEntry (Graph is optional there, wrapped in try/catch); should degrade gracefully to EXO-only details + warning instead of throwing, e.g. check Get-MgContext up front or catch the Graph error per assignee

[x] verify if the specific object (ManagementRoleAssignment for the given AppId/ServicePrincipal, or the proposed deterministic assignment name) already exists before creating it - New-RBAC4AppEntry's role-assignment loop calls New-ManagementRoleAssignment -ErrorAction Stop unconditionally with no existence check, unlike Set-RBAC4AppEntry (which checks via Get-ManagementRoleAssignment first and only creates/re-scopes what's missing); if a matching assignment already exists, consider skipping its creation and instead just adding the requested member(s) to the scope group

[x] extend Get-RegisteredAppWithPermission to also report the scope object name and the scope object content (e.g. list of mailboxes/members in the scoping group) - it currently only surfaces DisplayName/AppId/ServicePrincipalId/ExoServicePrincipal/Roles/RoleAssignmentNames/AssignmentCount, none of which expose the recipient scope. The scope group name is already on each raw assignment (RecipientWriteScope/CustomRecipientWriteScope, same fields Set-/Test-/Remove-RBAC4AppEntry already read); the membership would need a per-type lookup (Get-UnifiedGroupLinks/Get-DistributionGroupMember/Get-Recipient) similar to Test-RBAC4AppEntry's dispatch, since the group type isn't known from the assignment alone
