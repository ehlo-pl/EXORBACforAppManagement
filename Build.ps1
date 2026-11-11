<#
.SYNOPSIS
Build script for the EXORBACforAppManagement module.

.DESCRIPTION
Runs the module's quality gates and packaging steps. Tasks:
  Init    - ensure Pester (>=5) and PSScriptAnalyzer are available
  Clean   - remove build output and test results
  Analyze - run PSScriptAnalyzer over src (fails on Error severity)
  Test    - run the Pester suite (emits testResults.xml in NUnit format and coverage.xml in
            JaCoCo format; fails below -CoverageThreshold percent code coverage, default 90)
  Build   - copy the module to ./output and validate the manifest. When the current git
            branch is named b{major}.{minor}.{sub} (e.g. b0.8.20), the manifest's
            ModuleVersion is first set to {major}.{minor}.{sub}; other branches leave it as is.
  All     - Init, Clean, Analyze, Test, Build (default)

Every task runs unattended: Init trusts PSGallery for its installs, and Test suppresses
ShouldProcess confirmation prompts, so the script never waits for an interactive decision.

.EXAMPLE
./build.ps1
Runs the full pipeline.

.EXAMPLE
./build.ps1 -Task Test
Runs only the tests.
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Init', 'Clean', 'Analyze', 'Test', 'Build')]
    [string[]] $Task = 'All',

    # Minimum Pester code coverage (percent of commands in src) the Test task must reach.
    [ValidateRange(0, 100)]
    [int] $CoverageThreshold = 90
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot     = $PSScriptRoot
$ModuleName   = 'EXORBACforAppManagement'
$SrcPath      = Join-Path (Join-Path $RepoRoot 'src') $ModuleName
$ManifestPath = Join-Path $SrcPath "$ModuleName.psd1"
$TestsPath    = Join-Path $RepoRoot 'tests'
$OutputPath   = Join-Path $RepoRoot 'output'
$TestResults  = Join-Path $RepoRoot 'testResults.xml'
$CoverageFile = Join-Path $RepoRoot 'coverage.xml'
$SettingsPath = Join-Path $RepoRoot 'PSScriptAnalyzerSettings.psd1'

function Resolve-TaskList {
    param([string[]] $Requested)
    if ($Requested -contains 'All') {
        return @('Init', 'Clean', 'Analyze', 'Test', 'Build')
    }
    return $Requested
}

function Invoke-Init {
    Write-Host '==> Init' -ForegroundColor Cyan

    $needPester = -not (Get-Module Pester -ListAvailable | Where-Object Version -ge ([version]'5.0.0'))
    $needPSSA   = -not (Get-Module PSScriptAnalyzer -ListAvailable)
    if (-not ($needPester -or $needPSSA)) { return }

    # Prefer PSResourceGet: it talks to PSGallery directly and does NOT need the legacy NuGet
    # package provider, whose bootstrap (Install-PackageProvider) fails on hosts with multiple
    # duplicate PackageManagement/PowerShellGet versions ("Collection was modified ...").
    $resourceGet = Get-Module Microsoft.PowerShell.PSResourceGet -ListAvailable |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($resourceGet) {
        Import-Module $resourceGet -Force
        if ($needPester) {
            Write-Host 'Installing Pester 5 (PSResourceGet)...'
            Install-PSResource Pester -Version '[5.0.0,)' -Repository PSGallery -TrustRepository -Scope CurrentUser
        }
        if ($needPSSA) {
            Write-Host 'Installing PSScriptAnalyzer (PSResourceGet)...'
            Install-PSResource PSScriptAnalyzer -Repository PSGallery -TrustRepository -Scope CurrentUser
        }
        return
    }

    # Fallback for hosts without PSResourceGet: ensure the NuGet provider exists and PSGallery is
    # trusted so Install-Module runs non-interactively (avoids the untrusted-repository prompt).
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Write-Host 'Installing NuGet package provider...'
        Install-PackageProvider -Name NuGet -MinimumVersion '2.8.5.201' -Force -Scope CurrentUser | Out-Null
    }
    $gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if ($gallery -and $gallery.InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }

    if ($needPester) {
        Write-Host 'Installing Pester 5...'
        Install-Module Pester -MinimumVersion 5.0.0 -Force -Scope CurrentUser -SkipPublisherCheck -Repository PSGallery
    }
    if ($needPSSA) {
        Write-Host 'Installing PSScriptAnalyzer...'
        Install-Module PSScriptAnalyzer -Force -Scope CurrentUser -Repository PSGallery
    }
}

function Invoke-Clean {
    Write-Host '==> Clean' -ForegroundColor Cyan
    if (Test-Path $OutputPath)  { Remove-Item $OutputPath -Recurse -Force }
    if (Test-Path $TestResults) { Remove-Item $TestResults -Force }
    if (Test-Path $CoverageFile) { Remove-Item $CoverageFile -Force }
}

function Invoke-Analyze {
    Write-Host '==> Analyze' -ForegroundColor Cyan
    Import-Module PSScriptAnalyzer -Force
    $findings = Invoke-ScriptAnalyzer -Path $SrcPath -Recurse -Settings $SettingsPath
    if ($findings) {
        $findings | Format-Table -AutoSize | Out-String | Write-Host
    }
    $errors = @($findings | Where-Object Severity -eq 'Error')
    if ($errors.Count -gt 0) {
        throw "PSScriptAnalyzer found $($errors.Count) error(s)."
    }
    Write-Host 'Analyze passed (no errors).' -ForegroundColor Green
}

function Invoke-Test {
    Write-Host '==> Test' -ForegroundColor Cyan
    Import-Module Pester -MinimumVersion 5.0.0 -Force
    $config = New-PesterConfiguration
    $config.Run.Path = $TestsPath
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = $TestResults
    $config.CodeCoverage.Enabled = $true
    $config.CodeCoverage.Path = $SrcPath
    $config.CodeCoverage.OutputPath = $CoverageFile
    # Never stop for a ShouldProcess confirmation: a test that forgets -Confirm:$false would
    # otherwise block an interactive run waiting for Y/N. Module functions resolve preference
    # variables from the global scope, not this script's, so set (and restore) it there.
    $originalConfirmPreference = $global:ConfirmPreference
    $global:ConfirmPreference = 'None'
    try {
        $result = Invoke-Pester -Configuration $config
    }
    finally {
        $global:ConfirmPreference = $originalConfirmPreference
    }
    if ($result.FailedCount -gt 0) {
        throw "$($result.FailedCount) test(s) failed."
    }
    Write-Host "Tests passed ($($result.PassedCount))." -ForegroundColor Green

    $coverage = [math]::Round($result.CodeCoverage.CoveragePercent, 1)
    if ($coverage -lt $CoverageThreshold) {
        throw "Code coverage $coverage% is below the required $CoverageThreshold%."
    }
    Write-Host "Code coverage $coverage% (required: $CoverageThreshold%)." -ForegroundColor Green
}

function Sync-ModuleVersionFromBranch {
    # When the current git branch is named b{major}.{minor}.{sub} (e.g. b0.8.20), set the
    # manifest's ModuleVersion to {major}.{minor}.{sub}. Any other branch name (or no git /
    # detached HEAD) leaves ModuleVersion untouched.
    $branch = $null
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $output = @(& git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $output.Count -gt 0) { $branch = "$($output[0])".Trim() }
    }
    if (-not $branch -or $branch -notmatch '^b(\d+)\.(\d+)\.(\d+)$') {
        Write-Host "Branch '$branch' does not match b{major}.{minor}.{sub}; ModuleVersion left unchanged."
        return
    }
    $branchVersion = '{0}.{1}.{2}' -f [int]$Matches[1], [int]$Matches[2], [int]$Matches[3]

    $content = [System.IO.File]::ReadAllText($ManifestPath)
    $pattern = "(?m)^(\s*ModuleVersion\s*=\s*)'([^']*)'"
    $current = [regex]::Match($content, $pattern)
    if (-not $current.Success) {
        throw "ModuleVersion entry not found in $ManifestPath."
    }
    if ($current.Groups[2].Value -eq $branchVersion) {
        Write-Host "ModuleVersion already $branchVersion (branch $branch)."
        return
    }
    $updated = ([regex]$pattern).Replace($content, "`${1}'$branchVersion'", 1)
    [System.IO.File]::WriteAllText($ManifestPath, $updated, [System.Text.UTF8Encoding]::new($false))
    Write-Host "ModuleVersion updated $($current.Groups[2].Value) -> $branchVersion (branch $branch)." -ForegroundColor Yellow
}

function Invoke-Build {
    Write-Host '==> Build' -ForegroundColor Cyan
    Sync-ModuleVersionFromBranch
    $version =(Import-PowerShellDataFile $ManifestPath).ModuleVersion
    $dest    = Join-Path (Join-Path $OutputPath $version) $ModuleName
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -Path (Join-Path $SrcPath '*') -Destination $dest -Recurse -Force
    $null = Test-ModuleManifest -Path (Join-Path $dest "$ModuleName.psd1")
    Write-Host "Built module at $dest" -ForegroundColor Green
}
function Invoke-Publish {
    Write-Host '==> Publish' -ForegroundColor Cyan

    if (-not $NuGetApiKey) {
        throw "No API key supplied. Pass -NuGetApiKey or set `$env:PSGALLERY_API_KEY (https://www.powershellgallery.com/account/apikeys)."
    }

    $version = (Import-PowerShellDataFile $ManifestPath).ModuleVersion
    $dest    = Join-Path (Join-Path $OutputPath $version) $ModuleName
    if (-not (Test-Path (Join-Path $dest "$ModuleName.psd1"))) {
        throw "Built module not found at $dest. Run './build.ps1 -Task Build' (or -Task All) first."
    }
    $manifest = Test-ModuleManifest -Path (Join-Path $dest "$ModuleName.psd1")

    Write-Host "About to publish $ModuleName $($manifest.Version) from $dest to the PowerShell Gallery." -ForegroundColor Yellow
    Write-Host 'This is effectively irreversible: a published version can be unlisted but not deleted.' -ForegroundColor Yellow
    if (-not $Force) {
        $answer = Read-Host "Type the version ($($manifest.Version)) to confirm, or anything else to abort"
        if ($answer -ne [string]$manifest.Version) {
            Write-Host 'Publish aborted (confirmation did not match).' -ForegroundColor Yellow
            return
        }
    }

    # Prefer PSResourceGet (same rationale as Invoke-Init: talks to PSGallery directly, no legacy
    # NuGet provider bootstrap), falling back to the legacy PowerShellGet Publish-Module.
    $resourceGet = Get-Module Microsoft.PowerShell.PSResourceGet -ListAvailable |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($resourceGet) {
        Import-Module $resourceGet -Force
        Publish-PSResource -Path $dest -ApiKey $NuGetApiKey -Repository PSGallery
    }
    else {
        Publish-Module -Path $dest -NuGetApiKey $NuGetApiKey -Repository PSGallery
    }

    Write-Host "Published $ModuleName $($manifest.Version) to PSGallery." -ForegroundColor Green
}

foreach ($t in (Resolve-TaskList -Requested $Task)) {
    switch ($t) {
        'Init'    { Invoke-Init }
        'Clean'   { Invoke-Clean }
        'Analyze' { Invoke-Analyze }
        'Test'    { Invoke-Test }
        'Build'   { Invoke-Build }
    }
}

Write-Host 'Done.' -ForegroundColor Green
