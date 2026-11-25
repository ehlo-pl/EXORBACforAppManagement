function Assert-RBAC4AppExoCommand {
    # Pre-flight check for the role-gated Exchange Online cmdlets this module depends on
    # (Get-ServicePrincipal, New-ServicePrincipal, New-ManagementRoleAssignment, ...).
    #
    # Exchange Online RBAC trims the implicit-remoting session to the cmdlets the signed-in
    # account's roles allow *at connect time*. These cmdlets need Exchange Administrator (or Role
    # Management); when that role is eligible through Entra PIM but not activated, they are simply
    # absent from the session and a call fails with a bare "term is not recognized" error. This
    # helper turns that into an actionable message. Activating the role after connecting is not
    # enough - the session must be re-established.
    #
    # Throws when any named command is missing; returns nothing otherwise.
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name
    )

    $missing = @($Name | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -eq 0) { return }

    $list = $missing -join ', '

    # Distinguish "not connected at all" from "connected without the admin role".
    $connected = $false
    if (Get-Command -Name 'Get-ConnectionInformation' -ErrorAction SilentlyContinue) {
        try {
            $connected = [bool](@(Get-ConnectionInformation -ErrorAction Stop) |
                    Where-Object { $_ -and ([string]$_.State -eq 'Connected') } |
                    Select-Object -First 1)
        }
        catch { $connected = $false }
    }

    if ($connected) {
        throw (("Exchange Online cmdlet(s) not available in this session: {0}. The session is connected, so the " +
                "signed-in account most likely lacks the Exchange Administrator role - if it is eligible through " +
                "Privileged Identity Management (PIM), activate it, then reconnect (Disconnect-ExchangeOnline; " +
                "Connect-ExchangeOnline): Exchange Online only exposes the cmdlets your roles allowed at connect time.") -f $list)
    }
    throw (("Exchange Online cmdlet(s) not available in this session: {0}. Connect with Connect-ExchangeOnline using " +
            "an account with an active Exchange Administrator role (activate it in PIM first if the assignment is eligible).") -f $list)
}
