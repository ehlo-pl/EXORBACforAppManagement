function Test-RBAC4AppIPRange {
    <#
    .SYNOPSIS
    Tests whether a value is a single IP address or CIDR range of the given address family.

    .DESCRIPTION
    Used to validate Metadata.NetworkAccessIP4Range (-Family IPv4: dotted quad, optional /0-32) and
    Metadata.NetworkAccessIP6Range (-Family IPv6: any IPv6 notation [System.Net.IPAddress] parses,
    without a zone id, optional /0-128). Returns $true or $false; never throws.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Value,

        [Parameter(Mandatory)]
        [ValidateSet('IPv4', 'IPv6')]
        [string] $Family
    )

    if ([string]::IsNullOrEmpty($Value) -or $Value -match '\s') { return $false }

    if ($Family -eq 'IPv4') {
        return $Value -match '^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\/(3[0-2]|[12]?\d))?$'
    }

    $address = $Value
    if ($Value -match '^(?<addr>[^/]+)/(?<prefix>\d{1,3})$') {
        if ([int]$Matches.prefix -gt 128) { return $false }
        $address = $Matches.addr
    }
    elseif ($Value.Contains('/')) { return $false }

    # A zone id (fe80::1%eth0) is not a network range.
    if (-not $address.Contains(':') -or $address.Contains('%')) { return $false }
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($address, [ref]$parsed)) { return $false }
    return $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6
}
