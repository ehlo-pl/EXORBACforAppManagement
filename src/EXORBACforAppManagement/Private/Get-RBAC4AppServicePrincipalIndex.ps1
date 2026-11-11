function Get-RBAC4AppServicePrincipalIndex {
    # Indexes an Exchange Online service principal directory (the Get-ServicePrincipal result) for
    # Resolve-RBAC4AppAssignee. Pass -Directory to index an already-read result; otherwise the
    # directory is read here, failing closed (-ErrorAction Stop) so a failed read is never mistaken
    # for "no service principals".
    #
    # Returns { All = object[]; ByObjectId = hashtable (ObjectId -> pointer) }.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Directory
    )

    $all = if ($PSBoundParameters.ContainsKey('Directory')) { @($Directory | Where-Object { $_ }) } else { @(Get-ServicePrincipal -ErrorAction Stop | Where-Object { $_ }) }
    $byObjectId = @{}
    foreach ($sp in $all) {
        if ($sp.ObjectId) { $byObjectId[[string]$sp.ObjectId] = $sp }
    }
    [pscustomobject]@{ All = $all; ByObjectId = $byObjectId }
}
