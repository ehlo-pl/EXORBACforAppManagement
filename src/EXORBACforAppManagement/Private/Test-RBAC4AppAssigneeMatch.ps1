function Test-RBAC4AppAssigneeMatch {
    # Exact application filter for Get-RBAC4AppEntry: does an assignment's resolved assignee (from
    # Resolve-RBAC4AppAssignee) belong to the requested application (from
    # Resolve-RBAC4AppServicePrincipal)? Compares service principal object ids when both sides have
    # one, otherwise AppIds. Never matches on a substring of a name, so "Mail" does not match
    # "MailArchiver" or every "AppMailSend-..." assignment.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [psobject] $Assignee,

        [Parameter(Mandatory)]
        [psobject] $Application
    )

    if (-not $Assignee -or -not $Assignee.Sp) { return $false }
    $assigneeObjectId = [string]$Assignee.Sp.ObjectId
    $requestedObjectId = [string]$Application.Id
    if ($assigneeObjectId -and $requestedObjectId) {
        return ($assigneeObjectId -eq $requestedObjectId)
    }
    $assigneeAppId = [string]$Assignee.Sp.AppId
    $requestedAppId = [string]$Application.AppId
    return [bool]($assigneeAppId -and $requestedAppId -and $assigneeAppId -eq $requestedAppId)
}
