<#
.SYNOPSIS
Lists the source files and line numbers the Pester suite does not cover.

.DESCRIPTION
Reads the JaCoCo coverage file written by './build.ps1 -Task Test' (coverage.xml at the repo root
by default) and prints one row per source file with missed commands - most missed first - with
the file's coverage percentage and the line numbers that ran no command at all.

.PARAMETER Path
JaCoCo coverage XML to read. Defaults to coverage.xml at the repository root.

.PARAMETER Top
Only show the N files with the most missed commands. Default: all files with any miss.

.EXAMPLE
./build.ps1 -Task Test; ./scripts/Show-CoverageGaps.ps1 -Top 5
#>
[CmdletBinding()]
param(
    [string] $Path = (Join-Path (Split-Path $PSScriptRoot -Parent) 'coverage.xml'),

    [ValidateRange(1, [int]::MaxValue)]
    [int] $Top = [int]::MaxValue
)

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Coverage file '$Path' not found. Run './build.ps1 -Task Test' first."
}

[xml] $report = Get-Content -LiteralPath $Path -Raw
$rows = foreach ($package in $report.report.package) {
    foreach ($file in @($package.sourcefile)) {
        $counter = @($file.counter) | Where-Object { $_.type -eq 'INSTRUCTION' } | Select-Object -First 1
        if (-not $counter -or [int]$counter.missed -eq 0) { continue }
        $missed = [int]$counter.missed
        $covered = [int]$counter.covered
        $lines = @($file.line | Where-Object { [int]$_.mi -gt 0 -and [int]$_.ci -eq 0 } | ForEach-Object { [int]$_.nr })
        [pscustomobject]@{
            Missed   = $missed
            Coverage = [math]::Round(100 * $covered / ($missed + $covered), 1)
            File     = '{0}/{1}' -f (Split-Path $package.name -Leaf), $file.name
            Lines    = $lines -join ','
        }
    }
}

$total = @($report.report.counter) | Where-Object { $_.type -eq 'INSTRUCTION' } | Select-Object -First 1
if ($total) {
    $percent = [math]::Round(100 * [int]$total.covered / ([int]$total.missed + [int]$total.covered), 1)
    Write-Host ("Total: {0}% ({1} of {2} commands missed)" -f $percent, $total.missed, ([int]$total.missed + [int]$total.covered))
}
$rows | Sort-Object Missed -Descending | Select-Object -First $Top | Format-Table -AutoSize -Wrap
