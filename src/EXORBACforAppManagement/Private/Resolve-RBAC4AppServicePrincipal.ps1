function Resolve-RBAC4AppServicePrincipal {
    # EXO-only service principal resolution, against the Exchange Online service principal
    # pointers Register-EXOServicePrincipal creates (New-ServicePrincipal -AppId -ObjectId
    # -DisplayName). Replaces the Get-MgServicePrincipal resolution this module used to depend on,
    # so callers need a connected Exchange Online session only - no Microsoft Graph.
    #
    # The EXO pointer's own DisplayName is "<AppName>_SP" (see Register-EXOServicePrincipal), but
    # every deterministic name this module builds (scope group, role assignment, the pointer name
    # itself) is derived from the *application's* display name. So a name lookup matches both the
    # raw value and its "_SP" counterpart, and the DisplayName returned is always normalized back
    # to the app name (the "_SP" suffix stripped) - the same both-forms handling
    # Get-RegisteredAppWithPermission already relies on.
    #
    # Returns $null when nothing matches (the app has not been registered via
    # Register-EXOServicePrincipal / New-RBAC4AppEntry / Invoke-RBAC4AppConfig yet); throws when
    # more than one EXO service principal matches. Never throws on "not found" so callers can
    # decide how to react (error out, or - for New-RBAC4AppEntry - fall back to registering a new
    # one when the caller supplied enough identifiers to do so).
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByName')]
        [ValidateNotNullOrEmpty()]
        [string] $DisplayName,

        [Parameter(Mandatory, ParameterSetName = 'ByAppId')]
        [ValidateNotNullOrEmpty()]
        [string] $AppId,

        [Parameter(Mandatory, ParameterSetName = 'BySpObjectId')]
        [ValidateNotNullOrEmpty()]
        [string] $SpObjectId
    )

    $all = @(Get-ServicePrincipal -ErrorAction SilentlyContinue)

    $matchesRes = @(
        switch ($PSCmdlet.ParameterSetName) {
            'BySpObjectId' {
                $all | Where-Object { $_ -and ([string]$_.ObjectId -eq $SpObjectId) }
            }
            'ByAppId' {
                $all | Where-Object { $_ -and ([string]$_.AppId -eq $AppId) }
            }
            'ByName' {
                $stripped = $DisplayName -replace '_SP$', ''
                $all | Where-Object {
                    $_ -and (
                        ([string]$_.DisplayName -eq $DisplayName) -or
                        ([string]$_.DisplayName -eq $stripped) -or
                        ([string]$_.DisplayName -eq "${stripped}_SP")
                    )
                }
            }
        }
    )

    if ($matchesRes.Count -eq 0) { return $null }
    if ($matchesRes.Count -gt 1) {
        $ids = ($matchesRes | Select-Object -First 10 -ExpandProperty ObjectId) -join ', '
        throw "Ambiguous: $($matchesRes.Count) Exchange Online service principals matched. Re-run with -AppId or -SpObjectId. Example object ids: $ids"
    }

    $m = $matchesRes[0]
    [pscustomobject]@{
        AppId       = [string]$m.AppId
        Id          = [string]$m.ObjectId
        DisplayName = [string]$m.DisplayName -replace '_SP$', ''
    }
}
