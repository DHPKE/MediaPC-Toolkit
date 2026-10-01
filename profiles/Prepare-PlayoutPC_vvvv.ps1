#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    vvvv entry point: runs Prepare-PlayoutPC.ps1 with -PlayoutProfile vvvv.

.DESCRIPTION
    The vvvv profile adds the prerequisite step (Visual C++ Redistributable + .NET for exported vvvv gamma
    apps) that runs BEFORE Windows Update is blocked, and refuses to lock Windows Update while they are
    missing. All parameters are passed through unchanged, see Get-Help .\Prepare-PlayoutPC.ps1 -Full.
    This file must stay in the same folder as Prepare-PlayoutPC.ps1.

.EXAMPLE
    .\Prepare-PlayoutPC_vvvv.ps1 -WhatIf -AppPath "C:\Playout\Show\Show.exe" -KioskUser playout

.EXAMPLE
    .\Prepare-PlayoutPC_vvvv.ps1 -Unattended -InstallPrerequisites -AppPath "C:\Playout\Show\Show.exe" -KioskUser playout
#>
$main = Join-Path $PSScriptRoot 'Prepare-PlayoutPC.ps1'
if (-not (Test-Path $main)) {
    Write-Error "Prepare-PlayoutPC.ps1 must be in the same folder as this file ($PSScriptRoot)."
    exit 1
}
& $main -PlayoutProfile vvvv @args
if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
