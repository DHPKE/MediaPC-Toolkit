# Runs the Pester tests (installs Pester 5 / PSScriptAnalyzer for the current user if missing).
#   powershell.exe -File .\tests\Invoke-Tests.ps1      (or pwsh -File ...)
foreach ($m in 'Pester', 'PSScriptAnalyzer') {
    if (-not (Get-Module -ListAvailable $m | Where-Object { $m -ne 'Pester' -or $_.Version.Major -ge 5 })) {
        Install-Module $m -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion $(if ($m -eq 'Pester') { '5.0.0' } else { '1.0.0' })
    }
}
Import-Module Pester -MinimumVersion 5.0.0
$result = Invoke-Pester -Path (Join-Path $PSScriptRoot 'Prepare-PlayoutPC.Tests.ps1') -Output Detailed -PassThru
exit $result.FailedCount
