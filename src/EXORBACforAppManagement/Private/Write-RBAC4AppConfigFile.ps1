function Write-RBAC4AppConfigFile {
    # Writes built configs (ConvertTo-RBAC4AppConfigFromEntry results: { Config; SafeName }) to disk.
    #
    # -Path is a file when it has an extension, is not an existing directory, and does not end in a
    # separator: one config is written as-is, several as one JSON array (JSON is a YAML subset, so
    # the payload is valid either way); the extension follows -Format. Otherwise -Path (default: the
    # current directory) is a directory receiving one "rbac4app-<SafeName>.<ext>" file per config;
    # names that collide (case-insensitively) within the call are numbered instead of overwritten.
    #
    # -Format M365DSC writes the YAML config as above plus a Microsoft365DSC configuration script
    # (same name, .ps1) rendered by ConvertTo-RBAC4AppM365Dsc; a single-file -Path holding several
    # configs gets one .ps1 with one uniquely named Configuration per config.
    #
    # Honors -WhatIf/-Confirm (inherited from the calling public function's preferences). Returns
    # one { Path; Config; DscPath } per config written (DscPath $null unless -Format M365DSC).
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Export,

        [Parameter()]
        [string] $Path,

        [Parameter()]
        [ValidateSet('Yaml', 'Json', 'M365DSC')]
        [string] $Format = 'Yaml',

        [Parameter()]
        [ValidateSet('ManagedIdentity', 'Certificate')]
        [string] $DscAuthentication = 'ManagedIdentity'
    )

    $items = @($Export | Where-Object { $_ -and $_.Config })
    if ($items.Count -eq 0) { return }

    # Renders the DSC script(s) for the given items; returns $null when a config cannot be rendered.
    $usedConfigurationNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $dscWarnings = [System.Collections.Generic.HashSet[string]]::new()
    $renderDsc = {
        param([object[]] $RenderItems)
        $scripts = foreach ($renderItem in $RenderItems) {
            $dn = if ($renderItem.PSObject.Properties['ScopeGroupDistinguishedName']) { [string]$renderItem.ScopeGroupDistinguishedName } else { '' }
            try {
                $rendered = ConvertTo-RBAC4AppM365Dsc -Config $renderItem.Config -ScopeGroupDistinguishedName $dn -Authentication $DscAuthentication
                $configurationName = $rendered.ConfigurationName
                $suffix = 1
                while (-not $usedConfigurationNames.Add($configurationName)) {
                    $suffix++
                    $configurationName = '{0}_{1}' -f $rendered.ConfigurationName, $suffix
                }
                if ($configurationName -ne $rendered.ConfigurationName) {
                    $rendered = ConvertTo-RBAC4AppM365Dsc -Config $renderItem.Config -ScopeGroupDistinguishedName $dn -ConfigurationName $configurationName -Authentication $DscAuthentication
                }
                foreach ($dscWarning in $rendered.Warnings) {
                    if ($dscWarnings.Add($dscWarning)) { Write-Warning -Message $dscWarning }
                }
                $rendered.Script
            }
            catch {
                Write-Error -Message ("Could not render the Microsoft365DSC configuration for '{0}': {1}" -f $renderItem.SafeName, $_.Exception.Message)
            }
        }
        $scripts = @($scripts)
        if ($scripts.Count -eq 0) { return $null }
        $scripts -join "`r`n"
    }

    $extension = if ($Format -eq 'Json') { '.json' } else { '.yml' }
    $serialize = {
        param($Config)
        if ($Format -eq 'Json') { $Config | ConvertTo-Json -Depth 6 } else { ConvertTo-RBAC4AppYaml -Config $Config }
    }
    $configFormat = if ($Format -eq 'Json') { 'Json' } else { 'Yaml' }
    $writeFile = {
        param([string] $TargetPath, [string] $Serialized, [int] $Count, [string] $Kind = $configFormat)
        $what = if ($Kind -eq 'M365DSC') { 'Write Microsoft365DSC configuration' }
        elseif ($Count -gt 1) { "Write $Count RBAC4App configs ($Kind)" } else { "Write RBAC4App config ($Kind)" }
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
            $dscPath = $null
            if ($Format -eq 'M365DSC') {
                $dscScript = & $renderDsc $items
                $dscTarget = [System.IO.Path]::ChangeExtension($Path, '.ps1')
                if ($dscScript -and (& $writeFile $dscTarget $dscScript $items.Count 'M365DSC')) { $dscPath = $dscTarget }
            }
            foreach ($item in $items) { [pscustomobject]@{ Path = $targetPath; Config = $item.Config; DscPath = $dscPath } }
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
            $dscPath = $null
            if ($Format -eq 'M365DSC') {
                $dscScript = & $renderDsc @($item)
                $dscTarget = Join-Path $directory "rbac4app-$name.ps1"
                if ($dscScript -and (& $writeFile $dscTarget $dscScript 1 'M365DSC')) { $dscPath = $dscTarget }
            }
            [pscustomobject]@{ Path = $targetPath; Config = $item.Config; DscPath = $dscPath }
        }
    }
}
