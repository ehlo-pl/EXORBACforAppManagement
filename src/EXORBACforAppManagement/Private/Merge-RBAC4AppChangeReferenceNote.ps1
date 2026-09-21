function Merge-RBAC4AppChangeReferenceNote {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [string] $ExistingNotes,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ChangeReference
    )

    if ($ChangeReference -match "[`r`n]") {
        throw 'ChangeReference cannot contain CR or LF characters.'
    }

    $markerPrefix = 'RBAC4App-ChangeReference:'
    $markerLine   = '{0} {1}' -f $markerPrefix, $ChangeReference
    $preserved = @()
    if ($ExistingNotes) {
        $preserved = @($ExistingNotes -split '\r?\n' | Where-Object {
                $_ -and ($_ -notmatch ('^{0}\s*' -f [regex]::Escape($markerPrefix)))
            })
    }

    return @($preserved + $markerLine) -join [System.Environment]::NewLine
}
