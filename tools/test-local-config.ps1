[CmdletBinding()]
param(
    [string]$ToolPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Resolve the default in the script body for Windows PowerShell 5.1 -File.
if (-not $PSBoundParameters.ContainsKey('ToolPath')) {
    $ToolPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Claude-Policy-Tool.cmd'
}

[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = New-Object Text.UTF8Encoding($false)
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$utf8Bom = New-Object Text.UTF8Encoding($true)
$testId = [guid]::NewGuid().ToString('N')
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = [IO.Path]::GetFullPath((Join-Path $tempParent "ClaudePolicyToolLocalConfig-$testId"))
$results = New-Object 'System.Collections.Generic.List[object]'
$rootCreated = $false
$managedProfileJson = @'
{
  "bootstrapUrl": "https://bootstrap.example.invalid/config?token=fixture-url-secret",
  "bootstrapHeaders": {"Authorization": "Bearer fixture-header-secret"},
  "inferenceProvider": "gateway",
  "inferenceGatewayBaseUrl": "https://gateway.example.invalid",
  "inferenceGatewayApiKey": "encrypted:fixture-key-secret",
  "inferenceModels": [{"id": "配置\\模型", "label": "示例模型"}],
  "settings": {"largeInteger": 4503599627370496, "fraction": 0.375, "enabled": true, "nullable": null}
}
'@
$ordinaryProfileJson = '{"inferenceProvider":"gateway","inferenceGatewayBaseUrl":"https://local.example.invalid","inferenceModels":[{"id":"local"}]}'

function Assert-Case {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Rejected {
    param([scriptblock]$Operation, [string]$ExpectedError)
    try { $null = & $Operation } catch {
        if ($_.Exception.Message -notmatch $ExpectedError) { throw "Unexpected rejection: $($_.Exception.Message)" }
        return
    }
    throw "Expected rejection matching $ExpectedError."
}

function Get-TestFileBytes {
    param([string]$Path)
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
}

function New-ProfileFixture {
    param([int]$RootIndex = 0, [string]$Json = $managedProfileJson, [switch]$Unapplied)
    $root = $script:configRoots[$RootIndex]
    $library = Join-Path $root 'configLibrary'
    [void][IO.Directory]::CreateDirectory($library)
    $id = [guid]::NewGuid().ToString('D')
    $metaPath = Join-Path $library '_meta.json'
    $path = Join-Path $library "$id.json"
    [IO.File]::WriteAllText($path, ($Json -replace '\r?\n', "`r`n") + "`r`n", $utf8Bom)
    if (-not $Unapplied) {
        [IO.File]::WriteAllText($metaPath, (@{ appliedId = $id } | ConvertTo-Json), $Utf8NoBom)
    }
    [pscustomobject]@{ id = $id; path = $path; metaPath = $metaPath; original = (Get-TestFileBytes $path) }
}

function New-DisabledFixture {
    $profile = New-ProfileFixture
    $backup = Disable-LocalBootstrap (@(Get-ClaudeLocalConfigs)[0])
    [pscustomobject]@{ profile = $profile; backup = $backup; disabled = (Get-TestFileBytes $profile.path) }
}

function Edit-TestManifest {
    param([string]$Directory, [scriptblock]$Edit, [switch]$UpdateChecksum)
    $path = Join-Path $Directory 'manifest.json'
    $manifest = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    & $Edit $manifest
    [IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json), $Utf8NoBom)
    if ($UpdateChecksum) {
        [IO.File]::WriteAllText((Join-Path $Directory 'manifest.sha256'), (Get-Sha256 $path), $Utf8NoBom)
    }
}

function Set-TestAnswers {
    param([string[]]$Answers)
    foreach ($answer in $Answers) { $script:answers.Enqueue($answer) }
}

function Set-DesktopRunning {
    $script:runtime.processes = @([pscustomobject]@{ ProcessId = 12345 })
}

function New-TestDesktopProcess {
    param([int]$Id, [string]$Path, [string]$OwnerSid)
    [pscustomobject]@{
        ProcessId = $Id
        ExecutablePath = $Path
        SessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        mockOwnerSid = $OwnerSid
    }
}

function Invoke-DesktopRuntimeFixture {
    param([object[]]$FixtureProcesses = @(), [object[]]$FixturePackages = @())
    function Get-AppxPackage {
        param([string]$Name)
        Assert-Case ($Name -ceq 'Claude') 'Unexpected package lookup.'
        return $FixturePackages
    }
    function Get-AppxPackageManifest {
        param([string]$Package)
        Assert-Case ($Package -cin $FixturePackages.PackageFullName) 'Unexpected package manifest lookup.'
        @{ Package = @{ Applications = @{ Application = @{ Executable = 'app\Claude.exe'; Id = 'Claude' } } } }
    }
    function Get-CimInstance {
        param([string]$ClassName, [string]$Filter)
        Assert-Case ($ClassName -ceq 'Win32_Process' -and $Filter -ceq "Name = 'claude.exe'") 'Unexpected process query.'
        return $FixtureProcesses
    }
    function Invoke-CimMethod {
        param($InputObject, [string]$MethodName)
        Assert-Case ($MethodName -ceq 'GetOwnerSid' -and $InputObject.mockOwnerSid) 'An unrelated process reached the owner check.'
        [pscustomobject]@{ ReturnValue = 0; Sid = $InputObject.mockOwnerSid }
    }

    $oldLocal = $env:LOCALAPPDATA
    $oldProgramFiles = $env:ProgramFiles
    $oldProgramFiles64 = $env:ProgramW6432
    try {
        $env:LOCALAPPDATA = $localBase
        $env:ProgramFiles = Join-Path $caseRoot 'Program Files (x86)'
        $env:ProgramW6432 = Join-Path $caseRoot 'Program Files'
        & $realGetClaudeDesktopRuntime
    } finally {
        $env:LOCALAPPDATA = $oldLocal
        $env:ProgramFiles = $oldProgramFiles
        $env:ProgramW6432 = $oldProgramFiles64
    }
}

function Assert-RuntimeEvents {
    param([string]$Expected = '')
    $actual = ($script:runtimeEvents | ForEach-Object { $_.action }) -join ','
    Assert-Case ($actual -ceq $Expected) "Unexpected Desktop lifecycle events. Expected '$Expected', got '$actual'."
}

function Add-RuntimeEvent {
    param([string]$Action)
    $bytes = if ($script:watchedProfile) { Get-TestFileBytes $script:watchedProfile } else { '' }
    $script:runtimeEvents.Add([pscustomobject]@{ action = $Action; bytes = $bytes })
}

function Assert-NoNewBackup {
    Assert-Case (-not (Test-Path -LiteralPath (Get-LocalConfigBackupRoot))) 'An unexpected local backup was created.'
    Assert-Case (-not (Test-Path -LiteralPath $BackupRoot)) 'An unexpected registry backup was created.'
}

function Invoke-LocalConfigCase {
    param([string]$Name, [scriptblock]$Body)
    try {
        $caseRoot = Join-Path $testRoot "case-$($results.Count)"
        $localBase = Join-Path $caseRoot 'LocalAppData'
        $roamingBase = Join-Path $caseRoot 'AppData'
        $script:configRoots = @(
            (Join-Path $localBase 'Claude-3p'),
            (Join-Path $localBase 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p'),
            (Join-Path $roamingBase 'Claude-3p'),
            (Join-Path $localBase 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude-3p')
        )
        $script:DataRoot = Join-Path $caseRoot 'ToolData'
        $script:BackupRoot = Join-Path $script:DataRoot 'RegistryBackups'
        $script:runtime = [pscustomobject]@{ processes = @(); otherUsers = @(); launch = $null }
        $script:runtimeEvents = New-Object 'System.Collections.Generic.List[object]'
        $script:answers = New-Object 'System.Collections.Generic.Queue[string]'
        $script:watchedProfile = ''
        & $Body
        Assert-Case ($script:answers.Count -eq 0) 'The tool did not consume the expected confirmation input.'
        $results.Add([pscustomobject]@{ name = $Name; passed = $true; detail = '' })
    } catch {
        $results.Add([pscustomobject]@{ name = $Name; passed = $false; detail = $_.Exception.Message })
    }
}

try {
    # Import definitions only. The hybrid CMD initialization and entry point never run.
    $payload = (Get-Content -LiteralPath $ToolPath -Encoding UTF8 | Select-Object -Skip 12) -join "`n"
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($payload, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ($parseErrors[0].Message) }
    $definitions = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] }
    . ([scriptblock]::Create((($definitions | ForEach-Object { $_.Extent.Text }) -join "`n")))

    $realGetClaudeConfigRoots = ${function:Get-ClaudeConfigRoots}
    $realGetClaudeDesktopRuntime = ${function:Get-ClaudeDesktopRuntime}
    $realStartClaudeDesktop = ${function:Start-ClaudeDesktop}
    $ProductionTargets = @([pscustomobject]@{ hive = 'HKCU'; view = 64; regPath = 'TEST-REGISTRY-MOCK' })
    function Get-ClaudeConfigRoots { return $script:configRoots }
    function Get-ClaudeDesktopRuntime { return $script:runtime }
    function Stop-ClaudeDesktop { Add-RuntimeEvent 'stop' }
    function Start-ClaudeDesktop { Add-RuntimeEvent 'start' }
    function Test-TargetExists { return $false }
    function Get-ManagementState { return @() }
    function Write-Title { }
    function Ensure-Administrator { throw 'TEST HARNESS: elevation attempted' }
    function Assert-CompatibleForWrite { throw 'TEST HARNESS: registry write preflight attempted' }
    function Initialize-RegistryReader { throw 'TEST HARNESS: registry reader initialized' }
    function Invoke-Reg { throw 'TEST HARNESS: registry command attempted' }
    function New-BackupSet { throw 'TEST HARNESS: registry backup attempted' }
    function Remove-AllTargets { throw 'TEST HARNESS: registry write attempted' }
    function Start-Process { throw 'TEST HARNESS: process launch attempted' }
    function Stop-Process { throw 'TEST HARNESS: process termination attempted' }
    function Get-CimInstance { throw 'TEST HARNESS: live process lookup attempted' }
    function Invoke-CimMethod { throw 'TEST HARNESS: live process owner lookup attempted' }
    function Get-AppxPackage { throw 'TEST HARNESS: live package lookup attempted' }
    function Get-AppxPackageManifest { throw 'TEST HARNESS: live package manifest lookup attempted' }
    function Read-Host {
        param([string]$Prompt)
        if ($script:answers.Count -eq 0) { throw "TEST HARNESS: unexpected prompt '$Prompt'" }
        return $script:answers.Dequeue()
    }

    Assert-SafeBackupPath $testRoot -AllowMissing
    if (Test-Path -LiteralPath $testRoot) { throw 'The isolated temporary root already exists.' }
    [void][IO.Directory]::CreateDirectory($testRoot)
    $rootCreated = $true

    Invoke-LocalConfigCase 'four_config_roots' {
        $oldLocal = $env:LOCALAPPDATA
        $oldRoaming = $env:APPDATA
        try {
            $env:LOCALAPPDATA = $localBase
            $env:APPDATA = $roamingBase
            $resolved = @(& $realGetClaudeConfigRoots)
        } finally {
            $env:LOCALAPPDATA = $oldLocal
            $env:APPDATA = $oldRoaming
        }
        Assert-Case (($resolved -join '|') -ceq ($script:configRoots -join '|')) 'The four app configuration paths did not resolve as expected.'
        $fixtures = @(for ($i = 0; $i -lt $resolved.Count; $i++) { New-ProfileFixture -RootIndex $i })
        $configs = @(Get-ClaudeLocalConfigs)
        Assert-Case (($configs.path -join '|') -ceq ($fixtures.path -join '|')) 'Discovery did not find the applied profile in every candidate root.'
    }

    Invoke-LocalConfigCase 'applied_profile_only' {
        $ignored = New-ProfileFixture -Unapplied
        $applied = New-ProfileFixture -Json $ordinaryProfileJson
        $configs = @(Get-ClaudeLocalConfigs)
        Assert-Case ($configs.Count -eq 1 -and $configs[0].id -ceq $applied.id -and -not $configs[0].bootstrapActive) 'Discovery did not respect _meta.appliedId.'
        $null = Invoke-LocalConfigUnlock 6>&1
        Assert-Case ((Get-TestFileBytes $ignored.path) -ceq $ignored.original) 'An unapplied profile was changed.'
        Assert-NoNewBackup
    }

    Invoke-LocalConfigCase 'no_applied_profile' {
        $unapplied = New-ProfileFixture -Unapplied
        Assert-Case (@(Get-ClaudeLocalConfigs).Count -eq 0) 'A profile with no metadata was reported as applied.'
        [IO.File]::WriteAllText($unapplied.metaPath, '{"appliedId":null}', $Utf8NoBom)
        Assert-Case (@(Get-ClaudeLocalConfigs).Count -eq 0) 'A null appliedId selected a profile.'
    }

    Invoke-LocalConfigCase 'bootstrap_defaults_to_enabled' {
        $null = New-ProfileFixture
        $config = @(Get-ClaudeLocalConfigs)[0]
        Assert-Case $config.bootstrapActive 'A nonempty bootstrap URL with no enabled flag should be active.'
    }

    Invoke-LocalConfigCase 'explicit_bootstrap_flag' {
        $null = New-ProfileFixture -Json '{"bootstrapUrl":"https://fixture.invalid","bootstrapEnabled":false}'
        $null = New-ProfileFixture -RootIndex 1 -Json '{"bootstrapUrl":"https://fixture.invalid","bootstrapEnabled":true}'
        $configs = @(Get-ClaudeLocalConfigs)
        Assert-Case (-not $configs[0].bootstrapActive -and $configs[1].bootstrapActive) 'Explicit Boolean bootstrap settings were not respected.'
    }

    Invoke-LocalConfigCase 'blank_bootstrap_url' {
        $null = New-ProfileFixture -Json '{"bootstrapUrl":"  ","bootstrapEnabled":true}'
        Assert-Case (-not (@(Get-ClaudeLocalConfigs)[0].bootstrapActive)) 'A blank bootstrap URL should be inactive.'
    }

    Invoke-LocalConfigCase 'status_does_not_expose_secrets' {
        $null = New-ProfileFixture
        foreach ($detailed in @($false, $true)) {
            $output = (& { $null = Show-LocalConfigStatus -Detailed:$detailed } 6>&1) -join "`n"
            Assert-Case ($output -match '远程配置|远程服务') 'The status omitted the remote configuration source.'
            Assert-Case ($output -notmatch 'bootstrap\.example\.invalid|fixture-(url|header|key)-secret') 'The status exposed a URL or credential.'
        }
    }

    Invoke-LocalConfigCase 'disable_preserves_settings' {
        $profile = New-ProfileFixture
        $config = @(Get-ClaudeLocalConfigs)[0]
        $null = Disable-LocalBootstrap $config
        $after = [IO.File]::ReadAllText($profile.path) | ConvertFrom-Json
        Assert-Case ($after.bootstrapEnabled -is [bool] -and -not $after.bootstrapEnabled) 'The tool did not write a Boolean false flag.'
        $after.PSObject.Properties.Remove('bootstrapEnabled')
        $expected = ($managedProfileJson | ConvertFrom-Json | ConvertTo-Json -Depth 100 -Compress)
        Assert-Case (($after | ConvertTo-Json -Depth 100 -Compress) -ceq $expected) 'A setting other than bootstrapEnabled changed.'
        Assert-Case (-not (@(Get-ClaudeLocalConfigs)[0].bootstrapActive)) 'The modified profile still reports active bootstrap.'
    }

    Invoke-LocalConfigCase 'backup_preserves_original_bytes' {
        $fixture = New-DisabledFixture
        $backup = Read-LocalConfigBackup $fixture.backup
        Assert-Case ((Get-TestFileBytes (Join-Path $fixture.backup 'config.json')) -ceq $fixture.profile.original) 'The stored snapshot differs from the original bytes.'
        Assert-Case (([Convert]::ToBase64String($backup.bytes)) -ceq $fixture.profile.original) 'The validated snapshot changed the original encoding or bytes.'
    }

    Invoke-LocalConfigCase 'restore_preserves_original_bytes' {
        $fixture = New-DisabledFixture
        Set-DesktopRunning
        $script:watchedProfile = $fixture.profile.path
        Set-TestAnswers @('1', '确认恢复')
        $null = Invoke-LocalConfigRestore 6>&1
        Assert-Case ((Get-TestFileBytes $fixture.profile.path) -ceq $fixture.profile.original) 'Restore did not recover the original BOM, line endings, and contents.'
        $previous = @(Get-LocalConfigBackupCandidates | Where-Object { $_.FullName -ine $fixture.backup })
        Assert-Case ($previous.Count -eq 1 -and (Get-TestFileBytes (Join-Path $previous[0].FullName 'config.json')) -ceq $fixture.disabled) 'Restore did not back up the current profile.'
        Assert-RuntimeEvents 'stop,start'
        Assert-Case ($script:runtimeEvents[0].bytes -ceq $fixture.disabled -and $script:runtimeEvents[1].bytes -ceq $fixture.profile.original) 'Restore did not write between stopping and starting Desktop.'
    }

    Invoke-LocalConfigCase 'malformed_metadata' {
        $profile = New-ProfileFixture
        [IO.File]::WriteAllText($profile.metaPath, '{"appliedId":', $Utf8NoBom)
        Assert-Rejected { Get-ClaudeLocalConfigs } '有效的 JSON 对象'
        Assert-Case ((Get-TestFileBytes $profile.path) -ceq $profile.original) 'The profile changed after malformed metadata was rejected.'
        Assert-NoNewBackup
    }

    Invoke-LocalConfigCase 'malformed_profile' {
        $profile = New-ProfileFixture -Json '{"bootstrapUrl":['
        Assert-Rejected { Invoke-LocalConfigUnlock 6>&1 } '有效的 JSON 对象'
        Assert-Case ((Get-TestFileBytes $profile.path) -ceq $profile.original) 'The malformed profile changed.'
        Assert-NoNewBackup
        Assert-RuntimeEvents
    }

    Invoke-LocalConfigCase 'array_profile_is_not_an_object' {
        $null = New-ProfileFixture -Json '[{"bootstrapUrl":"https://fixture.invalid"}]'
        Assert-Rejected { Get-ClaudeLocalConfigs } '有效的 JSON 对象'
    }

    Invoke-LocalConfigCase 'missing_applied_profile' {
        $ignored = New-ProfileFixture -Unapplied
        $applied = New-ProfileFixture
        Remove-Item -LiteralPath $applied.path
        Assert-Rejected { Invoke-LocalConfigUnlock 6>&1 } ([regex]::Escape($applied.path))
        Assert-Case ((Get-TestFileBytes $ignored.path) -ceq $ignored.original) 'A missing applied profile caused another profile to change.'
        Assert-NoNewBackup
        Assert-RuntimeEvents
    }

    Invoke-LocalConfigCase 'applied_id_cannot_be_a_path' {
        $profile = New-ProfileFixture
        [IO.File]::WriteAllText($profile.metaPath, '{"appliedId":"..\\outside"}', $Utf8NoBom)
        Assert-Rejected { Get-ClaudeLocalConfigs } '已应用编号无效'
    }

    Invoke-LocalConfigCase 'metadata_change_rejects_stale_write' {
        $applied = New-ProfileFixture
        $snapshot = @(Get-ClaudeLocalConfigs)[0]
        $newApplied = New-ProfileFixture
        Assert-Rejected { Disable-LocalBootstrap $snapshot } '配置发生变化'
        Assert-Case ((Get-TestFileBytes $applied.path) -ceq $applied.original -and (Get-TestFileBytes $newApplied.path) -ceq $newApplied.original) 'Changing appliedId did not preserve both profiles.'
    }

    Invoke-LocalConfigCase 'profile_change_rejects_stale_write' {
        $profile = New-ProfileFixture
        $snapshot = @(Get-ClaudeLocalConfigs)[0]
        [IO.File]::WriteAllText($profile.path, $ordinaryProfileJson, $Utf8NoBom)
        $latest = Get-TestFileBytes $profile.path
        Assert-Rejected { Disable-LocalBootstrap $snapshot } '配置发生变化'
        Assert-Case ((Get-TestFileBytes $profile.path) -ceq $latest) 'A stale snapshot overwrote a newer profile.'
    }

    Invoke-LocalConfigCase 'cancel_unlock_leaves_profile_and_process_untouched' {
        $profile = New-ProfileFixture
        Set-DesktopRunning
        Set-TestAnswers @('')
        $null = Invoke-Unlock 6>&1
        Assert-Case ((Get-TestFileBytes $profile.path) -ceq $profile.original) 'Cancelling unlock changed the applied profile.'
        Assert-NoNewBackup
        Assert-RuntimeEvents
    }

    Invoke-LocalConfigCase 'unlock_only_the_selected_root' {
        $first = New-ProfileFixture
        $second = New-ProfileFixture -RootIndex 1
        $script:watchedProfile = $second.path
        Set-DesktopRunning
        Set-TestAnswers @('2', '确认解锁')
        $null = Invoke-Unlock 6>&1
        $configs = @(Get-ClaudeLocalConfigs)
        Assert-Case ((Get-TestFileBytes $first.path) -ceq $first.original -and $configs[0].bootstrapActive) 'The unselected root changed.'
        Assert-Case (-not $configs[1].bootstrapActive -and @(Get-LocalConfigBackupCandidates).Count -eq 1) 'The selected root was not disabled and backed up.'
        Assert-RuntimeEvents 'stop,start'
        Assert-Case ($script:runtimeEvents[0].bytes -ceq $second.original -and $script:runtimeEvents[1].bytes -ceq (Get-TestFileBytes $second.path)) 'Unlock did not write between stopping and starting Desktop.'
    }

    Invoke-LocalConfigCase 'invalid_root_selection' {
        $first = New-ProfileFixture
        $second = New-ProfileFixture -RootIndex 1
        Set-DesktopRunning
        Set-TestAnswers @('3')
        $null = Invoke-LocalConfigUnlock 6>&1
        Assert-Case ((Get-TestFileBytes $first.path) -ceq $first.original -and (Get-TestFileBytes $second.path) -ceq $second.original) 'An invalid selection changed a profile.'
        Assert-NoNewBackup
        Assert-RuntimeEvents
    }

    Invoke-LocalConfigCase 'ordinary_local_profile_survives_confirmed_restart' {
        $profile = New-ProfileFixture -Json $ordinaryProfileJson
        Set-DesktopRunning
        Set-TestAnswers @('确认重启')
        $null = Invoke-Unlock 6>&1
        Assert-Case ((Get-TestFileBytes $profile.path) -ceq $profile.original) 'Restart changed an ordinary local profile.'
        Assert-NoNewBackup
        Assert-RuntimeEvents 'stop,start'
    }

    Invoke-LocalConfigCase 'mixed_roots_respect_the_ordinary_selection' {
        $ordinary = New-ProfileFixture -Json $ordinaryProfileJson
        $remote = New-ProfileFixture -RootIndex 1
        Set-DesktopRunning
        Set-TestAnswers @('1', '确认重启')
        $null = Invoke-Unlock 6>&1
        Assert-Case ((Get-TestFileBytes $ordinary.path) -ceq $ordinary.original -and (Get-TestFileBytes $remote.path) -ceq $remote.original) 'Selecting the ordinary profile modified a configuration.'
        Assert-NoNewBackup
        Assert-RuntimeEvents 'stop,start'
    }

    Invoke-LocalConfigCase 'desktop_running_under_other_account' {
        $profile = New-ProfileFixture
        $script:runtime.otherUsers = @('S-1-5-0')
        Assert-Rejected { Invoke-LocalConfigUnlock 6>&1 } '另一个 Windows 账户'
        Assert-Case ((Get-TestFileBytes $profile.path) -ceq $profile.original) 'The profile changed with Desktop running under another account.'
        Assert-NoNewBackup
        Assert-RuntimeEvents
    }

    Invoke-LocalConfigCase 'detect_foreign_desktop_without_current_package_registration' {
        $msixPath = Join-Path $caseRoot 'Program Files\WindowsApps\Claude_4.23118.1.0_x64__pzs8sxrjxfjjc\app\Claude.exe'
        $legacyPath = Join-Path $caseRoot 'Other\AppData\Local\AnthropicClaude\app-1.0\Claude.exe'
        $codePath = Join-Path $caseRoot 'Other\.local\bin\claude.exe'
        $mockProcesses = @(
            (New-TestDesktopProcess 3001 $msixPath 'S-1-5-21-101-101-101-1001'),
            (New-TestDesktopProcess 3002 $legacyPath 'S-1-5-21-101-101-101-1002'),
            (New-TestDesktopProcess 3003 $codePath)
        )
        $runtime = Invoke-DesktopRuntimeFixture -FixtureProcesses $mockProcesses
        Assert-Case ($runtime.otherUsers.Count -eq 2 -and $runtime.otherUsers -contains $mockProcesses[0].mockOwnerSid -and $runtime.otherUsers -contains $mockProcesses[1].mockOwnerSid) 'Foreign MSIX or Squirrel Desktop owner was missed.'
        Assert-Case ($runtime.processes.Count -eq 0 -and $null -eq $runtime.launch) 'A foreign process became eligible for restart.'
        Assert-Rejected { Assert-ClaudeDesktopAccount $runtime } '另一个 Windows 账户'
    }

    Invoke-LocalConfigCase 'restart_uses_the_running_squirrel_executable' {
        $legacyPath = Join-Path $localBase 'AnthropicClaude\app-1.0\Claude.exe'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $legacyPath))
        [IO.File]::WriteAllBytes($legacyPath, [byte[]]@(0))
        $package = [pscustomobject]@{
            InstallLocation = Join-Path $caseRoot 'Program Files\WindowsApps\Claude_4.23118.1.0_x64__pzs8sxrjxfjjc'
            PackageFullName = 'Claude_4.23118.1.0_x64__pzs8sxrjxfjjc'
            PackageFamilyName = 'Claude_pzs8sxrjxfjjc'
        }
        $idleRuntime = Invoke-DesktopRuntimeFixture -FixturePackages @($package)
        Assert-Case ($idleRuntime.launch.argument -ceq 'shell:AppsFolder\Claude_pzs8sxrjxfjjc!Claude') 'The competing MSIX launcher was not available.'
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $legacy = New-TestDesktopProcess 3001 $legacyPath $sid
        $runtime = Invoke-DesktopRuntimeFixture -FixtureProcesses @($legacy) -FixturePackages @($package)
        Assert-Case ($runtime.processes.Count -eq 1 -and $runtime.processes[0].ProcessId -eq $legacy.ProcessId) 'The running Squirrel process was missed.'
        $launches = New-Object 'System.Collections.Generic.List[object]'
        function Start-Process {
            param([string]$FilePath, [string]$ArgumentList)
            $launches.Add([pscustomobject]@{ file = $FilePath; argument = $ArgumentList })
        }
        $null = & $realStartClaudeDesktop $runtime 6>&1
        Assert-Case ($launches.Count -eq 1 -and $launches[0].file -ceq $legacyPath -and -not $launches[0].argument) 'Restart did not target the running Squirrel executable.'
    }

    Invoke-LocalConfigCase 'tampered_backup_content' {
        $fixture = New-DisabledFixture
        [IO.File]::WriteAllText((Join-Path $fixture.backup 'config.json'), $ordinaryProfileJson, $Utf8NoBom)
        Assert-Rejected { Read-LocalConfigBackup $fixture.backup } '完整性校验失败'
    }

    Invoke-LocalConfigCase 'tampered_manifest_cannot_redirect_to_an_allowed_profile' {
        $fixture = New-DisabledFixture
        $other = New-ProfileFixture -RootIndex 1
        Edit-TestManifest $fixture.backup {
            param($Manifest)
            $Manifest.dataRoot = $script:configRoots[1]
            $Manifest.profileId = $other.id
        }
        Assert-Rejected { Read-LocalConfigBackup $fixture.backup } '校验失败'
        Assert-Case ((Get-TestFileBytes $other.path) -ceq $other.original) 'The other profile changed.'
    }

    Invoke-LocalConfigCase 'backup_target_must_be_an_approved_root' {
        $fixture = New-DisabledFixture
        Edit-TestManifest $fixture.backup -UpdateChecksum {
            param($Manifest)
            $Manifest.dataRoot = Join-Path $caseRoot 'UnapprovedRoot'
        }
        Assert-Rejected { Read-LocalConfigBackup $fixture.backup } '目标目录无效'
    }

    Invoke-LocalConfigCase 'backup_sid_must_match_current_account' {
        $fixture = New-DisabledFixture
        Edit-TestManifest $fixture.backup -UpdateChecksum {
            param($Manifest)
            $Manifest.userSid = 'S-1-5-0'
        }
        Assert-Rejected { Read-LocalConfigBackup $fixture.backup } '不属于当前电脑和 Windows 账户'
    }

    Invoke-LocalConfigCase 'restore_requires_the_backed_up_profile_to_be_applied' {
        $fixture = New-DisabledFixture
        $other = New-ProfileFixture -Json $ordinaryProfileJson
        Set-DesktopRunning
        Set-TestAnswers @('1')
        Assert-Rejected { Invoke-LocalConfigRestore 6>&1 } '当前未应用'
        Assert-Case ((Get-TestFileBytes $other.path) -ceq $other.original -and (Get-TestFileBytes $fixture.profile.path) -ceq $fixture.disabled) 'Restore modified a profile after the applied ID changed.'
        Assert-RuntimeEvents
    }

    Invoke-LocalConfigCase 'cancel_restore_leaves_profile_and_process_untouched' {
        $fixture = New-DisabledFixture
        Set-DesktopRunning
        Set-TestAnswers @('1', '')
        $null = Invoke-LocalConfigRestore 6>&1
        Assert-Case ((Get-TestFileBytes $fixture.profile.path) -ceq $fixture.disabled -and @(Get-LocalConfigBackupCandidates).Count -eq 1) 'Cancelling restore changed the profile or created a backup.'
        Assert-RuntimeEvents
    }

    Invoke-LocalConfigCase 'cancel_desktop_restart' {
        Set-DesktopRunning
        Set-TestAnswers @('')
        $null = Invoke-ClaudeRefresh 6>&1
        Assert-RuntimeEvents
    }

    Invoke-LocalConfigCase 'confirm_desktop_restart' {
        Set-DesktopRunning
        Set-TestAnswers @('确认重启')
        $null = Invoke-ClaudeRefresh 6>&1
        Assert-RuntimeEvents 'stop,start'
    }
} catch {
    $results.Add([pscustomobject]@{ name = 'setup'; passed = $false; detail = $_.Exception.Message })
} finally {
    if ($rootCreated) {
        try {
            $expected = [IO.Path]::GetFullPath((Join-Path $tempParent "ClaudePolicyToolLocalConfig-$testId"))
            Assert-Case ($testId -match '^[0-9a-f]{32}$' -and $testRoot -ceq $expected) 'Temporary directory cleanup failed path validation.'
            Remove-SafeScratchDirectory -Directory $testRoot
        } catch {
            $results.Add([pscustomobject]@{ name = 'cleanup'; passed = $false; detail = $_.Exception.Message })
        }
    }
}

$failed = @($results | Where-Object { -not $_.passed }).Count
$report = [ordered]@{
    passed = $results.Count - $failed
    failed = $failed
    count = $results.Count
    cases = $results.ToArray()
}
$report | ConvertTo-Json -Depth 5 -Compress
if ($failed -gt 0 -or $results.Count -eq 0) { exit 1 }
exit 0
