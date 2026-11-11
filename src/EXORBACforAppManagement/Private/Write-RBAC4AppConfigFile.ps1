function Write-RBAC4AppConfigFile {
    # Writes built configs (ConvertTo-RBAC4AppConfigFromEntry results: { Config; SafeName }) to disk.
    #
    # -Path is a file when it has an extension, is not an existing directory, and does not end in a
    # separator: one config is written as-is, several as one JSON array (JSON is a YAML subset, so
    # the payload is valid either way); the extension follows -Format. Otherwise -Path (default: the
    # current directory) is a directory receiving one "rbac4app-<SafeName>.<ext>" file per config;
    # names that collide (case-insensitively) within the call are numbered instead of overwritten.
    #
    # Honors -WhatIf/-Confirm (inherited from the calling public function's preferences). Returns
    # one { Path; Config } per config written.
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Export,

        [Parameter()]
        [string] $Path,

        [Parameter()]
        [ValidateSet('Yaml', 'Json')]
        [string] $Format = 'Yaml'
    )

    $items = @($Export | Where-Object { $_ -and $_.Config })
    if ($items.Count -eq 0) { return }

    $extension = if ($Format -eq 'Json') { '.json' } else { '.yml' }
    $serialize = {
        param($Config)
        if ($Format -eq 'Json') { $Config | ConvertTo-Json -Depth 6 } else { ConvertTo-RBAC4AppYaml -Config $Config }
    }
    $writeFile = {
        param([string] $TargetPath, [string] $Serialized, [int] $Count)
        $what = if ($Count -gt 1) { "Write $Count RBAC4App configs ($Format)" } else { "Write RBAC4App config ($Format)" }
        if (-not $PSCmdlet.ShouldProcess($TargetPath, $what)) { return $false }
        $parent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($TargetPath))
        if (-not [System.IO.Directory]::Exists($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
        [System.IO.File]::WriteAllText($TargetPath, $Serialized, [System.Text.Encoding]::UTF8)
        Write-Verbose "Config written to '$TargetPath'."
        return $true
    }

    $pathIsFile = [bool](
        $Path -and
        -not (Test-Path -LiteralPath $Path -PathType Container) -and
        $Path -notmatch '[\\/]$' -and
        [System.IO.Path]::GetExtension($Path)
    )

    if ($pathIsFile) {
        $targetPath = [System.IO.Path]::ChangeExtension($Path, $extension)
        $serialized = if ($items.Count -gt 1) {
            ConvertTo-Json -InputObject @($items | ForEach-Object { $_.Config }) -Depth 6
        }
        else { & $serialize $items[0].Config }
        if (& $writeFile $targetPath $serialized $items.Count) {
            foreach ($item in $items) { [pscustomobject]@{ Path = $targetPath; Config = $item.Config } }
        }
        return
    }

    $directory = if ($Path) { $Path } else { (Get-Location).Path }
    $usedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items) {
        $name = $item.SafeName
        $suffix = 1
        while (-not $usedNames.Add($name)) {
            $suffix++
            $name = "{0}-{1}" -f $item.SafeName, $suffix
        }
        $targetPath = Join-Path $directory "rbac4app-$name$extension"
        if (& $writeFile $targetPath (& $serialize $item.Config) 1) {
            [pscustomobject]@{ Path = $targetPath; Config = $item.Config }
        }
    }
}
