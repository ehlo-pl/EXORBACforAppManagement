function Write-RBAC4AppResult {
    # Emits a public function's [ordered] result as its [pscustomobject] summary and, when the
    # caller passed -FailOnError and the summary carries Errors, ALSO writes one error record to the
    # calling cmdlet's error stream (via $Cmdlet.WriteError, so the record is attributed to the
    # public function and honours the caller's -ErrorAction / $ErrorActionPreference). The summary
    # object is always emitted first, so callers keep the per-item detail even when the error
    # becomes terminating (-ErrorAction Stop). Without -FailOnError behaviour is unchanged: errors
    # live only in the summary's Errors property (module error-handling convention #2).
    #
    # Callers invoke this from a `finally` block after their per-item try/catch, so a terminating
    # error raised here can never be caught by that catch and appended to Errors a second time.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Result,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCmdlet] $Cmdlet,

        [Parameter()]
        [switch] $FailOnError
    )

    $summary = [pscustomobject]$Result
    $summary

    $errors = @($Result['Errors'] | Where-Object { $_ })
    if ($FailOnError -and $errors.Count -gt 0) {
        $identity = @($Result['ResolvedDisplay'], $Result['IdentityInput'], $Result['Path']) |
            Where-Object { $_ } | Select-Object -First 1
        $message = "{0} reported {1} error(s){2}: {3}" -f $Cmdlet.MyInvocation.MyCommand.Name, $errors.Count,
            $(if ($identity) { " for '$identity'" } else { '' }), ($errors -join '; ')
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new($message),
            'RBAC4AppOperationFailed',
            [System.Management.Automation.ErrorCategory]::NotSpecified,
            $summary)
        $Cmdlet.WriteError($record)
    }
}
