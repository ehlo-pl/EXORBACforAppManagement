function Save-RBAC4AppChangeReferenceRecord {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ChangeReference,

        [Parameter()]
        [string] $Source,

        [Parameter()]
        [string] $AccessGroupType,

        [Parameter()]
        [string] $ScopeGroupName,

        [Parameter()]
        [string] $ApplicationName,

        [Parameter()]
        [string] $AppId,

        [Parameter()]
        [string] $SpObjectId
    )

    if ($ChangeReference -match "[`r`n]") {
        throw 'ChangeReference cannot contain CR or LF characters.'
    }

    function ConvertTo-RBAC4AppMetadataYamlScalar {
        param(
            [AllowNull()]
            [object] $Value
        )

        $text = if ($null -eq $Value) { '' } else { [string]$Value }
        if ($text -match "[`r`n]") {
            throw 'Metadata scalar values cannot contain CR or LF characters.'
        }

        return '"' + $text.Replace('\', '\\').Replace('"', '\"') + '"'
    }

    $metadataDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.EXORBACforAppManagement'
    if (-not (Test-Path -LiteralPath $metadataDir -PathType Container)) {
        $null = New-Item -Path $metadataDir -ItemType Directory -Force
    }

    $fileName = ($ChangeReference -replace '[\\/:*?"<>|]', '-').Trim()
    if (-not $fileName) { $fileName = 'ChangeReference' }
    $metadataPath = Join-Path $metadataDir ('{0}.yaml' -f $fileName)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('---')
    $lines.Add("RecordedAt: $(ConvertTo-RBAC4AppMetadataYamlScalar ((Get-Date).ToUniversalTime().ToString('o')))")
    $lines.Add("ChangeReference: $(ConvertTo-RBAC4AppMetadataYamlScalar $ChangeReference)")
    $lines.Add("Source: $(ConvertTo-RBAC4AppMetadataYamlScalar $Source)")
    $lines.Add('Application:')
    $lines.Add("  DisplayName: $(ConvertTo-RBAC4AppMetadataYamlScalar $ApplicationName)")
    $lines.Add("  AppId: $(ConvertTo-RBAC4AppMetadataYamlScalar $AppId)")
    $lines.Add("  SpObjectId: $(ConvertTo-RBAC4AppMetadataYamlScalar $SpObjectId)")
    $lines.Add('Scope:')
    $lines.Add("  AccessGroupType: $(ConvertTo-RBAC4AppMetadataYamlScalar $AccessGroupType)")
    $lines.Add("  GroupName: $(ConvertTo-RBAC4AppMetadataYamlScalar $ScopeGroupName)")

    Add-Content -LiteralPath $metadataPath -Value ($lines -join [System.Environment]::NewLine) -Encoding UTF8
    return $metadataPath
}
