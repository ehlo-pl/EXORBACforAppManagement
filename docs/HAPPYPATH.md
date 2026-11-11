# Happy path: enable three roles for an app, scoped to an Exchange Online distribution group

This walkthrough gives one Entra application these Exchange Online application roles, limited to the
mailboxes that are members of one distribution list:

- `Application Mail.Send`
- `Application Mail.ReadWrite`
- `Application Calendars.ReadWrite`

The role assignments are bound **directly to the distribution group** (`-RecipientGroupScope`),
**without a management scope**. Everything uses plain Exchange Online cmdlets, so no
EXORBACforAppManagement function is needed to follow it.

> **This is not what the module's own functions do.** Since 0.8.0 `New-RBAC4AppEntry` (and the other
> module functions) always create a named management scope and bind role assignments to it with
> `-CustomResourceScope`. Assignments made as shown here are what the module calls *legacy
> group-direct* assignments: `Get-RBAC4AppEntry` reports them with `ScopeKind` `GroupDirect`,
> `Test-RBAC4AppEntry` treats them as not valid, and `Set-RBAC4AppEntry` re-binds them to a management
> scope. See [Moving to the module later](#moving-to-the-module-later).

## What you need

- An Entra application registration **and its service principal** already exist. You need the
  application (client) id, the service principal's object id, and its display name.
- Exchange Online PowerShell (`ExchangeOnlineManagement`) and the **Organization Management** role
  group (or equivalent) to create groups and assign application roles.
- The application must **not** also hold the same permissions unscoped in Entra ID. Entra grants and
  Exchange RBAC grants are unioned, so an unscoped `Mail.ReadWrite` consent in Entra defeats the
  scoping below. Remove those consents before relying on the scope.

## 1. Connect and set variables

```powershell
Connect-ExchangeOnline

$appId      = '11111111-2222-3333-4444-555555555555'   # application (client) id
$spObjectId = '66666666-7777-8888-9999-000000000000'   # service principal (enterprise app) object id
$appName    = 'Contoso Mail App'

$groupName  = 'UDLRAo1P-ContosoMailApp'                # letters, digits and dash only
$owner      = 'admin@contoso.com'                      # a real recipient; the list must have an owner
$mailboxes  = 'shared1@contoso.com', 'shared2@contoso.com'

$roles = 'Application Mail.Send', 'Application Mail.ReadWrite', 'Application Calendars.ReadWrite'
```

## 2. Create the distribution group

```powershell
New-DistributionGroup -Name $groupName -DisplayName "$groupName - RBAC for APP" `
    -Alias $groupName -Type Distribution -ManagedBy $owner -Members $mailboxes

# Keep the scope list out of the address book and closed to self-service joins:
Set-DistributionGroup -Identity $groupName `
    -HiddenFromAddressListsEnabled $true `
    -RequireSenderAuthenticationEnabled $true `
    -MemberJoinRestriction Closed -MemberDepartRestriction Closed
```

Only **direct** members of the group are in scope. Nested groups are not expanded.

## 3. Create the Exchange Online service principal pointer

Exchange needs its own pointer to the Entra service principal before it can receive role assignments.
Skip this step if it already exists.

```powershell
if (-not (Get-ServicePrincipal | Where-Object AppId -eq $appId)) {
    New-ServicePrincipal -AppId $appId -ObjectId $spObjectId -DisplayName $appName
}
$sp = Get-ServicePrincipal | Where-Object AppId -eq $appId
```

## 4. Assign the three roles, scoped to the group

```powershell
# Preview first:
foreach ($role in $roles) {
    New-ManagementRoleAssignment -App $sp.Id -Role $role -RecipientGroupScope $groupName -WhatIf
}

# Then for real. Names make the assignments easy to find (and match the module's naming):
$names = @{
    'Application Mail.Send'            = 'AppMailSend-ContosoMailApp'
    'Application Mail.ReadWrite'       = 'AppMailRW-ContosoMailApp'
    'Application Calendars.ReadWrite'  = 'AppCldRW-ContosoMailApp'
}
foreach ($role in $roles) {
    New-ManagementRoleAssignment -App $sp.Id -Role $role -RecipientGroupScope $groupName -Name $names[$role]
}
```

## 5. Verify

```powershell
# The three assignments, scoped to the group:
Get-ManagementRoleAssignment -RoleAssignee $sp.Id |
    Format-Table Name, Role, RecipientWriteScope, CustomResourceScope -AutoSize

# What the app can actually do against a mailbox:
Test-ServicePrincipalAuthorization -Identity $appId -Resource shared1@contoso.com
Test-ServicePrincipalAuthorization -Identity $appId -Resource someone.else@contoso.com   # expect no access
```

For group-scoped assignments Exchange reports `RecipientWriteScope` as `Group` and stores the group
as an automatically created scope object named `<GroupName>_<GUID>` in `CustomResourceScope`
(`CustomRecipientWriteScope` stays empty).

Permission changes are not instant; if the first call from the app is denied, wait and retry before
troubleshooting.

## Day-2 operations

```powershell
# Grant the app access to another mailbox / take it away:
Add-DistributionGroupMember    -Identity $groupName -Member newmailbox@contoso.com
Remove-DistributionGroupMember -Identity $groupName -Member shared2@contoso.com -Confirm:$false

# Remove one role:
Remove-ManagementRoleAssignment -Identity 'AppCldRW-ContosoMailApp' -Confirm:$false
```

## Tear down

```powershell
foreach ($n in $names.Values) { Remove-ManagementRoleAssignment -Identity $n -Confirm:$false }
Remove-DistributionGroup -Identity $groupName -Confirm:$false
# The service principal pointer is shared by all of the app's assignments; remove it only if nothing else uses it:
# Remove-ServicePrincipal -Identity $sp.Id
```

## Moving to the module later

The module's supported path creates the same group but binds the roles through a management scope
(`MSRAo1P-<DisplayName>`, filter `MemberOfGroup -eq '<group DN>'`):

```powershell
New-RBAC4AppEntry -RegisteredAppName $appName `
    -Role 'Mail.Send', 'Mail.ReadWrite', 'Calendars.ReadWrite' `
    -AccessGroupType DistributionList -Members $mailboxes -ManagedBy $owner -WhatIf
```

To convert assignments created with this walkthrough, run `Set-RBAC4AppEntry` with the same identity and
roles: it re-binds legacy group-direct assignments to the management scope. Use
`Get-RBAC4AppEntry -RegisteredAppName $appName` to see what is bound where, and `Test-RBAC4AppEntry` to
validate the result.
