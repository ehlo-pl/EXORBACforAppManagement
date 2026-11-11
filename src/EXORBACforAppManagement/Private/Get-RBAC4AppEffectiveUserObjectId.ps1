function Get-RBAC4AppEffectiveUserObjectId {
    # Fallback source for a service principal object id when the resolved identity has none (an
    # empty ObjectId/Id usually means a broken or partial Connect-MgGraph / directory read, which is
    # not always visible as $null from Get-MgContext). Exchange Online can carry the assignee's object
    # id in a role assignment's EffectiveUserName, so the first GUID found in any of the supplied
    # values is returned. Values without a GUID (e.g. the "NT AUTHORITY\SYSTEM (<name>_SP)"
    # placeholder) are ignored, so a non-GUID never ends up in an SpObjectId field. Returns $null
    # when no value carries a GUID.
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $EffectiveUserName
    )

    foreach ($value in @($EffectiveUserName)) {
        $text = [string]$value
        if ($text -match '[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}') {
            return $Matches[0]
        }
    }
    return $null
}
