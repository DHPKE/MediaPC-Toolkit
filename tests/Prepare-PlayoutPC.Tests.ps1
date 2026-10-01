# Pester 5 tests. They run on Windows PowerShell 5.1 or PowerShell 7 (also on Linux/macOS): the script is
# never executed; selected functions are extracted from its AST and tested with mocks.
BeforeAll {
    $root    = Split-Path -Parent $PSScriptRoot
    $script:MainPath    = Join-Path (Join-Path $root 'profiles') 'Prepare-PlayoutPC.ps1'
    $script:WrapperPath = Join-Path (Join-Path $root 'profiles') 'Prepare-PlayoutPC_vvvv.ps1'
    $script:MainText    = Get-Content -Path $script:MainPath -Raw
    $tokens = $null; $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:MainPath, [ref]$tokens, [ref]$errors)

    # Extract function definitions from the script (dot-sourced here so they exist in this scope).
    foreach ($name in 'Invoke-Native', 'Test-DotNetPresent', 'Test-VcRedist', 'Test-PrerequisitesMet') {
        $def = $script:Ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name }, $true)
        . ([scriptblock]::Create($def.Extent.Text))
    }
    function Get-DotNetState { }
    function Get-VcRedistVersion { }

    function Get-FunctionText([string]$Name) {
        ($script:Ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Name }, $true)).Extent.Text
    }
}

Describe 'Syntax' {
    It 'main script parses without errors' {
        $e = $null; $t = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:MainPath, [ref]$t, [ref]$e)
        $e | Should -BeNullOrEmpty
    }
    It 'vvvv wrapper parses without errors and forwards arguments with the vvvv profile' {
        $e = $null; $t = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:WrapperPath, [ref]$t, [ref]$e)
        $e | Should -BeNullOrEmpty
        (Get-Content -Path $script:WrapperPath -Raw) | Should -Match '-PlayoutProfile vvvv @args'
    }
    It 'is ASCII only (Windows PowerShell 5.1 reads BOM-less files as ANSI)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:MainPath)
        ($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

Describe 'Documented invariants (header claims)' {
    It 'does not touch UAC' {
        $script:MainText | Should -Not -Match 'EnableLUA|ConsentPromptBehavior'
    }
    It 'does not disable the firewall' {
        $script:MainText | Should -Not -Match 'Set-NetFirewallProfile|advfirewall'
    }
    It 'contains no GitHub tokens' {
        $script:MainText | Should -Not -Match 'ghp_|github_pat_'
    }
}

Describe 'Invoke-Native' {
    BeforeAll { $script:Pwsh = (Get-Process -Id $PID).Path }
    It 'returns the output of a successful command' {
        Invoke-Native $script:Pwsh @('-NoProfile', '-Command', 'Write-Output hello') | Should -Be 'hello'
    }
    It 'throws with the exit code on failure' {
        { Invoke-Native $script:Pwsh @('-NoProfile', '-Command', 'exit 3') } | Should -Throw '*exit 3*'
    }
}

Describe 'Test-DotNetPresent' {
    BeforeEach { $DotNetMajor = '8' }
    It 'SDK kind: true only when an 8.x SDK is installed' {
        $DotNetKind = 'SDK'
        Mock Get-DotNetState { @{ Sdks = @('8.0.404 [C:\Program Files\dotnet\sdk]'); Runtimes = @() } }
        Test-DotNetPresent | Should -BeTrue
        Mock Get-DotNetState { @{ Sdks = @('6.0.403 [C:\Program Files\dotnet\sdk]'); Runtimes = @() } }
        Test-DotNetPresent | Should -BeFalse
    }
    It 'DesktopRuntime kind: needs the WindowsDesktop runtime or an SDK' {
        $DotNetKind = 'DesktopRuntime'
        Mock Get-DotNetState { @{ Sdks = @(); Runtimes = @('Microsoft.WindowsDesktop.App 8.0.11 [C:\x]') } }
        Test-DotNetPresent | Should -BeTrue
        Mock Get-DotNetState { @{ Sdks = @(); Runtimes = @('Microsoft.NETCore.App 8.0.11 [C:\x]') } }
        Test-DotNetPresent | Should -BeFalse
        Mock Get-DotNetState { @{ Sdks = @('8.0.404 [C:\x]'); Runtimes = @() } }
        Test-DotNetPresent | Should -BeTrue
    }
    It 'Runtime kind: accepts NETCore.App 8.x' {
        $DotNetKind = 'Runtime'
        Mock Get-DotNetState { @{ Sdks = @(); Runtimes = @('Microsoft.NETCore.App 8.0.11 [C:\x]') } }
        Test-DotNetPresent | Should -BeTrue
    }
}

Describe 'VC++ Redistributable check and prerequisite gate' {
    BeforeEach { $VcRedistMinVersion = [version]'14.38' }
    It 'is false when not installed' {
        Mock Get-VcRedistVersion { $null }
        Test-VcRedist | Should -BeFalse
    }
    It 'is false below the minimum version and true at or above it' {
        Mock Get-VcRedistVersion { [version]'14.29.30133' }
        Test-VcRedist | Should -BeFalse
        Mock Get-VcRedistVersion { [version]'14.40.33810' }
        Test-VcRedist | Should -BeTrue
    }
    It 'Test-PrerequisitesMet needs both VC++ and .NET' {
        $DotNetMajor = '8'; $DotNetKind = 'SDK'
        Mock Get-VcRedistVersion { [version]'14.40.33810' }
        Mock Get-DotNetState { @{ Sdks = @(); Runtimes = @() } }
        Test-PrerequisitesMet | Should -BeFalse
        Mock Get-DotNetState { @{ Sdks = @('8.0.404 [C:\x]'); Runtimes = @() } }
        Test-PrerequisitesMet | Should -BeTrue
        Mock Get-VcRedistVersion { $null }
        Test-PrerequisitesMet | Should -BeFalse
    }
}

Describe 'Regression guards for review findings' {
    It 'Invoke-Updates refuses to lock without prerequisites (vvvv profile) unless overridden' {
        $t = Get-FunctionText 'Invoke-Updates'
        $t | Should -Match 'Test-PrerequisitesMet'
        $t | Should -Match 'LockWithoutPrerequisites'
        $t | Should -Match 'Windows Update lock SKIPPED'
    }
    It 'Invoke-Updates verifies the lock' {
        (Get-FunctionText 'Invoke-Updates') | Should -Match 'Test-UpdateLock'
    }
    It 'the SYSTEM update guard lives in a folder restricted to SYSTEM and Administrators' {
        (Get-FunctionText 'Install-UpdateGuard') | Should -Match 'Initialize-StateDir'
        $t = Get-FunctionText 'Initialize-StateDir'
        $t | Should -Match 'icacls'
        $t | Should -Match '/inheritance:r'
        $t | Should -Match 'S-1-5-18'
        $t | Should -Match 'S-1-5-32-544'
    }
    It 'the guard task list is generated from the same list the lock uses' {
        $t = Get-FunctionText 'Install-UpdateGuard'
        $t | Should -Match '\$script:UpdateTaskPaths'
        $t | Should -Match '\$script:UpdateServices'
    }
    It 'auto-logon verifies the result and never passes the credential through Invoke-Native' {
        $t = Get-FunctionText 'Invoke-AutoLogon'
        # one read-back per method (Sysinternals and Registry)
        [regex]::Matches($t, 'Test-AutoLogonConfigured').Count | Should -BeGreaterOrEqual 2
        $t | Should -Not -Match 'Invoke-Native'
    }
    It 'unlock re-enables only tasks recorded by the script' {
        $t = Get-FunctionText 'Invoke-UpdateUnlock'
        $t | Should -Match 'Get-DisabledTaskList'
        $t | Should -Not -Match 'Get-ScheduledTask -TaskPath \$p'
    }
    It 'the app firewall rule defaults to all profiles' {
        $script:MainText | Should -Match "\`$FirewallProfiles = @\('Private','Domain','Public'\)"
    }
    It 'has no empty catch blocks' {
        $script:Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CatchClauseAst] -and $a.Body.Statements.Count -eq 0 }, $true).Count | Should -Be 0
    }
}

Describe 'PSScriptAnalyzer' {
    It 'reports no errors or warnings with the repository settings' -Skip:(-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        $settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
        $r = Invoke-ScriptAnalyzer -Path $script:MainPath -Settings $settings
        ($r | ForEach-Object { "$($_.Line): [$($_.RuleName)] $($_.Message)" }) | Should -BeNullOrEmpty
    }
}
