# Supported application roles and permission identifiers

The Exchange Online [Supported Application Roles](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac#supported-application-roles)
table is joined below with the **Application** identifiers from the
[Microsoft Graph permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference).
Verified on 2026-11-08. Permission links use verified section anchors; descriptions are shortened.

| Exchange application role | Protocol (source label) | Permission / reference | Application permission GUID | Description |
|---|---|---|---|---|
| `Application Mail.Read` | MS Graph | [Mail.Read](https://learn.microsoft.com/en-us/graph/permissions-reference#mailread) | `810c84a8-4a9e-49e6-bf7d-12d183f40d01` | Read email. |
| `Application Mail.ReadBasic` | MS Graph | [Mail.ReadBasic](https://learn.microsoft.com/en-us/graph/permissions-reference#mailreadbasic) | `6be147d2-ea4f-4b5a-a3fa-3eab6f3c140a` | Read email excluding bodies, previews, attachments, and extended properties. |
| `Application Mail.ReadWrite` | MS Graph | [Mail.ReadWrite](https://learn.microsoft.com/en-us/graph/permissions-reference#mailreadwrite) | `e2a3a72e-5f79-4c64-b1b1-878b674786c9` | Create, read, update, and delete email; excludes sending. |
| `Application Mail.Send` | MS Graph | [Mail.Send](https://learn.microsoft.com/en-us/graph/permissions-reference#mailsend) | `b633e1c5-b582-4048-a93e-9f11b44c7e96` | Send mail as any user. |
| `Application MailboxSettings.Read` | MS Graph | [MailboxSettings.Read](https://learn.microsoft.com/en-us/graph/permissions-reference#mailboxsettingsread) | `40f97065-369a-49f4-947c-6a255697ae91` | Read mailbox settings. |
| `Application MailboxSettings.ReadWrite` | MS Graph | [MailboxSettings.ReadWrite](https://learn.microsoft.com/en-us/graph/permissions-reference#mailboxsettingsreadwrite) | `6931bccd-447a-43d1-b442-00a195474933` | Create, read, update, and delete mailbox settings. |
| `Application Calendars.Read` | MS Graph | [Calendars.Read](https://learn.microsoft.com/en-us/graph/permissions-reference#calendarsread) | `798ee544-9d2d-430c-a058-570e29e34338` | Read calendar events. |
| `Application Calendars.ReadWrite` | MS Graph | [Calendars.ReadWrite](https://learn.microsoft.com/en-us/graph/permissions-reference#calendarsreadwrite) | `ef54d2bf-783f-4e0f-bca1-3210c0444d99` | Create, read, update, and delete calendar events. |
| `Application Contacts.Read` | MS Graph | [Contacts.Read](https://learn.microsoft.com/en-us/graph/permissions-reference#contactsread) | `089fe4d0-434a-44c5-8827-41ba8a0b17f5` | Read contacts. |
| `Application Contacts.ReadWrite` | MS Graph | [Contacts.ReadWrite](https://learn.microsoft.com/en-us/graph/permissions-reference#contactsreadwrite) | `6918b873-d17a-4dc1-b314-35f528134491` | Create, read, update, and delete contacts. |
| `Application MailboxFolder.Read` | MS Graph | [MailboxFolder.Read.All](https://learn.microsoft.com/en-us/graph/permissions-reference#mailboxfolderreadall) | `99280d24-a782-4793-93cc-0888549957f6` | Read mailbox folders. |
| `Application MailboxFolder.ReadWrite` | MS Graph | [MailboxFolder.ReadWrite.All](https://learn.microsoft.com/en-us/graph/permissions-reference#mailboxfolderreadwriteall) | `fef87b92-8391-4589-9da7-eb93dab7dc8a` | Read and write mailbox folders. |
| `Application MailboxItem.Read` | MS Graph | [MailboxItem.Read.All](https://learn.microsoft.com/en-us/graph/permissions-reference#mailboxitemreadall) | `7d9f353d-a7bd-4fbb-822a-26d5dd39a3ce` | Read mailbox items. |
| `Application MailboxItem.ReadWrite` | MS Graph | [MailboxItem.ReadWrite.All](https://learn.microsoft.com/en-us/graph/permissions-reference#mailboxitemreadwriteall) | `1583d471-fede-4e7c-b062-57e9d60cfb49` | Read, write, and delete mailbox items. |
| `Application MailboxItem.Export` | MS Graph | [MailboxItem.Export.All](https://learn.microsoft.com/en-us/graph/permissions-reference#mailboxitemexportall) | `937550e9-33a3-494b-88ae-d9cd394b1fbb` | Export mailbox items. |
| `Application MailboxItem.ImportExport` | MS Graph | [MailboxItem.ImportExport.All](https://learn.microsoft.com/en-us/graph/permissions-reference#mailboxitemimportexportall) | `76577085-e73d-4f1d-b26a-85fb33892327` | Import and export mailbox items. |
| `Application Mail Full Access` | MS Graph | [Mail.ReadWrite](https://learn.microsoft.com/en-us/graph/permissions-reference#mailreadwrite)<br>[Mail.Send](https://learn.microsoft.com/en-us/graph/permissions-reference#mailsend) | `e2a3a72e-5f79-4c64-b1b1-878b674786c9`<br>`b633e1c5-b582-4048-a93e-9f11b44c7e96` | Manage email and send mail. |
| `Application Exchange Full Access` | MS Graph | [Mail.ReadWrite](https://learn.microsoft.com/en-us/graph/permissions-reference#mailreadwrite)<br>[Mail.Send](https://learn.microsoft.com/en-us/graph/permissions-reference#mailsend)<br>[MailboxSettings.ReadWrite](https://learn.microsoft.com/en-us/graph/permissions-reference#mailboxsettingsreadwrite)<br>[Calendars.ReadWrite](https://learn.microsoft.com/en-us/graph/permissions-reference#calendarsreadwrite)<br>[Contacts.ReadWrite](https://learn.microsoft.com/en-us/graph/permissions-reference#contactsreadwrite) | `e2a3a72e-5f79-4c64-b1b1-878b674786c9`<br>`b633e1c5-b582-4048-a93e-9f11b44c7e96`<br>`6931bccd-447a-43d1-b442-00a195474933`<br>`ef54d2bf-783f-4e0f-bca1-3210c0444d99`<br>`6918b873-d17a-4dc1-b314-35f528134491` | Manage email, mailbox settings, calendars, and contacts; send mail. |
| `Application EWS.AccessAsApp` | EWS | `EWS.AccessAsApp` - not in Graph reference | Not listed | Full mailbox access through EWS. |
| `Application SMTP.SendAsApp` | MS Graph | `SMTP.SendAsApp` - not in Graph reference | Not listed | Submit mail through SMTP Client Submission. |
| `Application MailboxConfigItem.Read` | MS Graph | [MailboxConfigItem.Read](https://learn.microsoft.com/en-us/graph/permissions-reference#mailboxconfigitemread) | `27d9d776-f4d2-426d-80ad-5f22f2b01b0a` | Read UserConfiguration objects. |
| `Application MailboxConfigItem.ReadWrite` | MS Graph | [MailboxConfigItem.ReadWrite](https://learn.microsoft.com/en-us/graph/permissions-reference#mailboxconfigitemreadwrite) | `aa6d92d4-b25a-4640-aefe-3e3231e5e736` | Read, write, update, and delete UserConfiguration objects. |
| `Application MailTips.ReadBasic.All` | MS Graph | [MailTips.ReadBasic.All](https://learn.microsoft.com/en-us/graph/permissions-reference#mailtipsreadbasicall) | `a2c9652d-4d7f-4e4e-9d75-ac32fdc6f413` | Read MailTips metadata without email content. |
| `Application Mail-Advanced.ReadWrite.All` | MS Graph | [Mail-Advanced.ReadWrite.All](https://learn.microsoft.com/en-us/graph/permissions-reference#mail-advancedreadwriteall) | `e118f1da-5c1c-46cf-bff6-8858d786f46f` | Manage all email, including non-draft contents; excludes sending. |

## Interpretation

- Protocol labels are preserved from the Exchange table, including its **MS Graph** label for `SMTP.SendAsApp`; that role's description refers to SMTP Client Submission.
- `EWS.AccessAsApp` and `SMTP.SendAsApp` have no matching entries in the supplied Graph reference. No Graph GUID or fragment URL is asserted for them.
- Composite roles have multiple constituent permission GUIDs, in the same order as their permission links, rather than a single Graph GUID.
- The identifiers are Graph application permission IDs, not delegated permission IDs or Exchange management role IDs.
- These roles permit application access without a signed-in user. Exchange RBAC assignments can restrict access to selected resources.
- Granting the equivalent Graph application permissions in Entra ID is not required for scoped Exchange RBAC access. Entra grants and Exchange RBAC grants are additive; an unscoped Entra grant can defeat the intended restriction of a scoped RBAC assignment.

This is a documentation snapshot, not a declaration that every listed role is supported by this module's role lookup tables.
