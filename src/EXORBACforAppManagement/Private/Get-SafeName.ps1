function Get-SafeName {
    # Strip everything except letters, digits, and dash. Add a deterministic hash when
    # truncating so distinct long names do not collapse to the same Exchange object name.
    param(
        [string] $s,
        [int] $max = 64
    )

    $clean = ($s -replace '[^A-Za-z0-9\-]', '')
    if ($clean.Length -le $max) { return $clean }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = [System.BitConverter]::ToString(
            $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))
        ).Replace('-', '').Substring(0, 12).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }

    $suffix = "-$hash"
    $prefixLength = $max - $suffix.Length
    if ($prefixLength -le 0) { return $hash.Substring(0, $max) }
    $clean.Substring(0, $prefixLength) + $suffix
}
