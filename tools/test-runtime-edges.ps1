[CmdletBinding()]
param(
    [string]$ToolPath,
    [Parameter(Mandatory = $true)][string]$ResultPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Resolve the default in the script body for Windows PowerShell 5.1 -File.
if (-not $PSBoundParameters.ContainsKey('ToolPath')) {
    $ToolPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Claude-Policy-Tool.cmd'
}

# Run only in an isolated Windows test environment. The only real entrypoint run is
# --status with an intentionally wrong SID; no write action or UAC is requested.
$script:results = New-Object 'System.Collections.Generic.List[object]'
$script:ensureCalls = 0
$script:compatibilityCalls = 0
$script:newItemCalls = 0
$script:startProcessCalls = 0
$script:readHostCalls = 0
$script:mockContentCalls = 0
$script:mockContentPath = $null
$script:expectedMockPath = $null
$script:capturedEnvironment = $null
$script:mockPayload = '$script:capturedEnvironment = [pscustomobject]@{ Path = $env:CPT_SELF; Action = $env:CPT_ACTION; Sid = $env:CPT_EXPECTED_SID }'
$testId = [guid]::NewGuid().ToString('N')
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$script:testRoot = [IO.Path]::GetFullPath((Join-Path $tempParent "ClaudePolicyRuntimeEdges-$testId"))
$script:fakeWindows = Join-Path $script:testRoot 'Windows'
$script:BackupRoot = Join-Path $script:testRoot 'Backups'
$script:DataRoot = $script:testRoot
$script:ProductionTargets = @()
$script:RegExe = Join-Path $script:testRoot 'blocked-reg.exe'
$createdRoot = $false
$resultPathValid = $false
$toolFullPath = $null
$resultFullPath = [IO.Path]::GetFullPath($ResultPath)

function Assert-Case {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:results.Add([pscustomobject]@{ name = $Name; passed = $true; detail = '' })
        Write-Host "[PASS] $Name"
    } catch {
        $message = $_.Exception.Message
        $script:results.Add([pscustomobject]@{ name = $Name; passed = $false; detail = $message })
        Write-Host "[FAIL] ${Name}: $message"
    }
}

function Write-PolicyFixture {
    param([string]$Key, [ValidateSet('Machine', 'User')][string]$Scope)
    $machineFile = Join-Path $script:fakeWindows 'System32\GroupPolicy\Machine\Registry.pol'
    $userFile = Join-Path $script:fakeWindows 'System32\GroupPolicy\User\Registry.pol'
    foreach ($file in @($machineFile, $userFile)) {
        if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
    }
    if ([string]::IsNullOrEmpty($Key)) { return }

    $file = if ($Scope -eq 'Machine') { $machineFile } else { $userFile }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
    $stream = [IO.File]::Open($file, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = New-Object IO.BinaryWriter($stream)
    try {
        # Registry.pol header and one synthetic REG_SZ record. Key/value strings
        # are NUL-terminated UTF-16LE; type and size are little-endian DWORDs.
        $writer.Write([Text.Encoding]::ASCII.GetBytes('PReg'))
        $writer.Write([uint32]1)
        $writer.Write([Text.Encoding]::Unicode.GetBytes(('[' + $Key + [char]0 + ';Marker' + [char]0 + ';')))
        $writer.Write([uint32]1)
        $writer.Write([Text.Encoding]::Unicode.GetBytes(';'))
        $data = [Text.Encoding]::Unicode.GetBytes(('value' + [char]0))
        $writer.Write([uint32]$data.Length)
        $writer.Write([Text.Encoding]::Unicode.GetBytes(';'))
        $writer.Write($data)
        $writer.Write([Text.Encoding]::Unicode.GetBytes(']'))
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function Assert-PolicyFixture {
    param([string]$Key, [string]$Scope, [bool]$Expected)
    $previousWindir = [Environment]::GetEnvironmentVariable('WINDIR', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('WINDIR', $script:fakeWindows, 'Process')
        Write-PolicyFixture -Key $Key -Scope $Scope
        $actual = Test-LocalPolicyContainsClaude
        Assert-Case ($actual -is [bool] -and $actual -eq $Expected) "Expected $Expected for key '$Key' in $Scope; received '$actual'."
    } finally {
        [Environment]::SetEnvironmentVariable('WINDIR', $previousWindir, 'Process')
    }
}

function Assert-SafeEncodedCommand {
    param([string]$Decoded, [string]$ExpectedPath, [string]$ExpectedAction, [string]$ExpectedSid)
    $tokens = $null
    $parseErrors = $null
    $commandAst = [System.Management.Automation.Language.Parser]::ParseInput($Decoded, [ref]$tokens, [ref]$parseErrors)
    Assert-Case (@($parseErrors).Count -eq 0) 'Encoded elevation command did not parse.'
    $statements = @($commandAst.EndBlock.Statements)
    Assert-Case ($statements.Count -eq 4) 'TEST HARNESS: unexpected elevation command shape; execution blocked.'
    $names = @('env:CPT_SELF', 'env:CPT_ACTION', 'env:CPT_EXPECTED_SID')
    $values = @($ExpectedPath, $ExpectedAction, $ExpectedSid)
    for ($i = 0; $i -lt 3; $i++) {
        $assignment = $statements[$i]
        Assert-Case ($assignment -is [System.Management.Automation.Language.AssignmentStatementAst]) 'TEST HARNESS: expected a literal assignment.'
        Assert-Case ($assignment.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals -and
            $assignment.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $assignment.Left.VariablePath.UserPath -ceq $names[$i]) 'TEST HARNESS: unexpected assignment target.'
        Assert-Case ($assignment.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and
            @($assignment.Right.Redirections).Count -eq 0 -and
            $assignment.Right.Expression -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $assignment.Right.Expression.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::SingleQuoted) 'TEST HARNESS: assignment is not a single-quoted literal.'
        Assert-Case ($assignment.Right.Expression.Value -ceq $values[$i]) 'Generated command changed an assigned value.'
    }
    # Restrict evaluation to the known loader. Get-Content is replaced below by
    # a mock which supplies only twelve empty lines and a harmless capture payload.
    $expectedLoader = 'Invoke-Expression ((Get-Content -Encoding UTF8 -LiteralPath $env:CPT_SELF | Select-Object -Skip 12) -join [Environment]::NewLine)'
    $actualLoader = [regex]::Replace($statements[3].Extent.Text.Trim(), '\s+', ' ')
    Assert-Case ($actualLoader -ceq $expectedLoader) 'TEST HARNESS: unexpected loader; execution blocked.'
}

function Assert-ElevationRoundTrip {
    param([string]$Action, [string]$Sid)
    $names = @('CPT_SELF', 'CPT_ACTION', 'CPT_EXPECTED_SID', 'CPT_EDGE_TOKEN')
    $previous = @{}
    foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        [Environment]::SetEnvironmentVariable('CPT_EDGE_TOKEN', 'EXPANSION_MUST_NOT_OCCUR', 'Process')
        $specialPath = Join-Path $script:testRoot "路径 space O'Brien %CPT_EDGE_TOKEN% & (parentheses)^!\Claude tool.cmd"
        $script:expectedMockPath = $specialPath
        $script:mockContentPath = $null
        $script:mockContentCalls = 0
        $script:capturedEnvironment = $null
        $encoded = New-ElevationCommand -Path $specialPath -RequestedAction $Action -ExpectedSid $Sid
        $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        Assert-SafeEncodedCommand -Decoded $decoded -ExpectedPath $specialPath -ExpectedAction $Action -ExpectedSid $Sid
        $null = & ([scriptblock]::Create($decoded))
        Assert-Case ($script:mockContentCalls -eq 1 -and $script:mockContentPath -ceq $specialPath) 'Mock loader did not receive the literal path exactly once.'
        Assert-Case ($null -ne $script:capturedEnvironment) 'Harmless payload did not run.'
        Assert-Case ($script:capturedEnvironment.Path -ceq $specialPath) 'The payload observed a changed script path.'
        Assert-Case ($script:capturedEnvironment.Action -ceq $Action) 'The payload observed a changed action.'
        Assert-Case ($script:capturedEnvironment.Sid -ceq $Sid) 'The payload observed a changed SID.'
        Assert-Case ($script:capturedEnvironment.Path.Contains('%CPT_EDGE_TOKEN%') -and
            -not $script:capturedEnvironment.Path.Contains('EXPANSION_MUST_NOT_OCCUR')) 'The percent token was expanded.'
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
        $script:expectedMockPath = $null
    }
}

function Stop-TestProcessTree {
    param([Diagnostics.Process]$Process)
    if ($Process.HasExited) { return }
    $killInfo = New-Object Diagnostics.ProcessStartInfo
    $killInfo.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    $killInfo.Arguments = '/PID {0} /T /F' -f $Process.Id
    $killInfo.UseShellExecute = $false
    $killInfo.CreateNoWindow = $true
    $killInfo.RedirectStandardOutput = $true
    $killInfo.RedirectStandardError = $true
    $killer = $null
    try {
        $killer = [Diagnostics.Process]::Start($killInfo)
        if (-not $killer.WaitForExit(3000)) {
            $killer.Kill()
            $null = $killer.WaitForExit(3000)
        }
    } finally {
        if ($null -ne $killer) { $killer.Dispose() }
        if (-not $Process.HasExited) {
            $Process.Kill()
            $null = $Process.WaitForExit(3000)
        }
    }
}

function Assert-EntrypointRejectsDifferentUser {
    param([string]$OtherSid)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    # The environment variable is expanded once; the path is never interpolated
    # into cmd source and CALL's second percent expansion is not used.
    $start.Arguments = '/d /v:off /s /c ""%CPT_RUNTIME_TEST_TOOL%" --status"'
    $start.WorkingDirectory = $script:testRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $start.EnvironmentVariables['CPT_RUNTIME_TEST_TOOL'] = $toolFullPath
    $start.EnvironmentVariables['CPT_EXPECTED_SID'] = $OtherSid
    $start.EnvironmentVariables['LOCALAPPDATA'] = $script:testRoot
    $start.EnvironmentVariables['TEMP'] = $script:testRoot
    $start.EnvironmentVariables['TMP'] = $script:testRoot
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Failed to start the status test process.' }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { throw 'Status process exceeded 30 seconds and will be terminated.' }
        $remaining = [Math]::Max(0, 30000 - [int]$timer.ElapsedMilliseconds)
        if (-not $outputTask.Wait($remaining)) { throw 'Status output did not close within 30 seconds.' }
        $remaining = [Math]::Max(0, 30000 - [int]$timer.ElapsedMilliseconds)
        if (-not $errorTask.Wait($remaining)) { throw 'Status error output did not close within 30 seconds.' }
        $output = $outputTask.Result + "`n" + $errorTask.Result
        Assert-Case ($process.ExitCode -eq 1) "Expected status exit code 1, received $($process.ExitCode)."
        Assert-Case ($output -match '另一个 Windows 账户') 'Status output did not report that the Windows account changed.'
        Assert-Case ($output -notmatch '(?i)HKLM(?:32|64)|HKLM\\SOFTWARE\\Policies\\Claude|Claude Desktop 策略状态|\[\s*整台电脑\s*/\s*(?:32|64)\s*位\]') 'Policy status output appeared before the SID rejection.'
    } finally {
        if ($started -and -not $process.HasExited) { Stop-TestProcessTree -Process $process }
        $process.Dispose()
    }
}

try {
    $toolFullPath = (Resolve-Path -LiteralPath $ToolPath).ProviderPath
    $scriptFullPath = [IO.Path]::GetFullPath($PSCommandPath)
    if ($resultFullPath.Equals($toolFullPath, [StringComparison]::OrdinalIgnoreCase) -or
        $resultFullPath.Equals($scriptFullPath, [StringComparison]::OrdinalIgnoreCase) -or
        $resultFullPath.StartsWith($script:testRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ResultPath must not overwrite the tool, this test, or a temporary fixture.'
    }
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($resultFullPath))) {
        throw 'The ResultPath parent directory must already exist.'
    }
    $resultPathValid = $true
    if ([IO.Directory]::Exists($script:testRoot) -or [IO.File]::Exists($script:testRoot)) { throw 'Random test directory already exists.' }
    [void][IO.Directory]::CreateDirectory($script:testRoot)
    $createdRoot = $true

    # Parse the portion after the twelve-line CMD preamble and load only four
    # top-level function definitions, never top-level initialization or entrypoint.
    $source = [IO.File]::ReadAllLines($toolFullPath, [Text.Encoding]::UTF8)
    if ($source.Length -le 12) { throw 'Tool does not contain a PowerShell payload after the first 12 lines.' }
    $payload = ($source[12..($source.Length - 1)] -join "`n")
    $tokens = $null
    $parseErrors = $null
    $payloadAst = [System.Management.Automation.Language.Parser]::ParseInput($payload, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -ne 0) { throw ('Tool payload parse failed: ' + (($parseErrors | ForEach-Object { $_.Message }) -join '; ')) }
    $definitions = @($payloadAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
    $selected = @()
    foreach ($name in @('Assert-UserContext', 'New-ElevationCommand', 'Invoke-RestoreInteractive', 'Test-LocalPolicyContainsClaude')) {
        $matches = @($definitions | Where-Object { $_.Name -ceq $name })
        if ($matches.Count -ne 1) { throw "Expected exactly one top-level function named $name." }
        $selected += $matches[0].Extent.Text
    }
    . ([scriptblock]::Create(($selected -join "`n")))

    # Stop unexpected elevation, prompting, directory creation, or reg.exe use.
    # Mocks are deliberately defined only after the tool has been parsed.
    function Get-Content {
        param([string]$Encoding, [string]$LiteralPath)
        $script:mockContentCalls++
        $script:mockContentPath = $LiteralPath
        if ($Encoding -cne 'UTF8' -or $LiteralPath -cne $script:expectedMockPath) { throw 'TEST HARNESS: unexpected Get-Content request.' }
        for ($i = 0; $i -lt 12; $i++) { Write-Output '' }
        Write-Output $script:mockPayload
    }
    function Write-Title {}
    function Get-BackupCandidates { return @() }
    function Ensure-Administrator { $script:ensureCalls++; throw 'TEST HARNESS: blocked elevation.' }
    function Assert-CompatibleForWrite { $script:compatibilityCalls++; throw 'TEST HARNESS: blocked write compatibility check.' }
    function New-Item { $script:newItemCalls++; throw 'TEST HARNESS: blocked item creation.' }
    function Start-Process { $script:startProcessCalls++; throw 'TEST HARNESS: blocked process launch.' }
    function Read-Host { $script:readHostCalls++; throw 'TEST HARNESS: blocked interactive prompt.' }
    function Invoke-Reg { throw 'TEST HARNESS: blocked registry command.' }

    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $otherSid = if ($currentSid -ceq 'S-1-5-18') { 'S-1-5-19' } else { 'S-1-5-18' }
    $null = New-Object Security.Principal.SecurityIdentifier($otherSid)

    Invoke-Case 'current_user_sid_accepted' {
        $null = Assert-UserContext -ExpectedSid $currentSid
    }
    Invoke-Case 'different_valid_sid_rejected' {
        $threw = $false
        try { $null = Assert-UserContext -ExpectedSid $otherSid } catch { $threw = $true }
        Assert-Case $threw 'A different valid Windows SID was accepted.'
    }
    Invoke-Case 'elevation_unlock_literal_round_trip' { Assert-ElevationRoundTrip -Action '--unlock' -Sid $currentSid }
    Invoke-Case 'elevation_restore_literal_round_trip' { Assert-ElevationRoundTrip -Action '--restore' -Sid $currentSid }
    Invoke-Case 'restore_without_candidates_has_no_side_effects' {
        $script:ensureCalls = 0
        $script:compatibilityCalls = 0
        $script:newItemCalls = 0
        $script:startProcessCalls = 0
        $script:readHostCalls = 0
        Assert-Case (-not [IO.Directory]::Exists($script:BackupRoot)) 'Backup directory existed before the test.'
        $null = @(Invoke-RestoreInteractive 6>&1)
        Assert-Case ($script:ensureCalls -eq 0 -and $script:compatibilityCalls -eq 0 -and
            $script:newItemCalls -eq 0 -and $script:startProcessCalls -eq 0 -and $script:readHostCalls -eq 0) 'Restore called an elevation, write, or prompt path without a backup.'
        Assert-Case (-not [IO.Directory]::Exists($script:BackupRoot)) 'Restore created the backup directory without a backup.'
    }
    Invoke-Case 'local_policy_absent' { Assert-PolicyFixture -Key '' -Scope 'Machine' -Expected $false }
    Invoke-Case 'local_policy_exact_claude_machine' { Assert-PolicyFixture -Key 'Software\Policies\Claude' -Scope 'Machine' -Expected $true }
    Invoke-Case 'local_policy_claude_subkey_user' { Assert-PolicyFixture -Key 'Software\Policies\Claude\Nested' -Scope 'User' -Expected $true }
    Invoke-Case 'local_policy_claudecode_prefix_is_not_claude' { Assert-PolicyFixture -Key 'Software\Policies\ClaudeCode' -Scope 'Machine' -Expected $false }
    Invoke-Case 'local_policy_claudeextra_prefix_is_not_claude' { Assert-PolicyFixture -Key 'Software\Policies\ClaudeExtra' -Scope 'User' -Expected $false }
    Invoke-Case 'entrypoint_rejects_different_user_before_status' { Assert-EntrypointRejectsDifferentUser -OtherSid $otherSid }
} catch {
    $message = $_.Exception.Message
    $script:results.Add([pscustomobject]@{ name = 'setup'; passed = $false; detail = $message })
    Write-Host "[FAIL] setup: $message"
} finally {
    if ($createdRoot) {
        try {
            $expectedRoot = [IO.Path]::GetFullPath((Join-Path $tempParent "ClaudePolicyRuntimeEdges-$testId"))
            if ($testId -notmatch '^[0-9a-f]{32}$' -or -not $script:testRoot.Equals($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Temporary cleanup path validation failed.'
            }
            if ([IO.Directory]::Exists($script:testRoot)) {
                $items = @((Get-Item -LiteralPath $script:testRoot)) + @(Get-ChildItem -LiteralPath $script:testRoot -Recurse)
                if (@($items | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) { throw 'Unexpected reparse point; temporary cleanup refused.' }
                Remove-Item -LiteralPath $script:testRoot -Recurse
            }
        } catch {
            $message = $_.Exception.Message
            $script:results.Add([pscustomobject]@{ name = 'cleanup'; passed = $false; detail = $message })
            Write-Host "[FAIL] cleanup: $message"
        }
    }
}

$expectedCaseCount = 11
$failed = @($script:results | Where-Object { -not $_.passed }).Count
$passed = @($script:results | Where-Object { $_.passed }).Count
$report = [ordered]@{
    toolPath = $toolFullPath
    powershellVersion = $PSVersionTable.PSVersion.ToString()
    generatedUtc = [DateTime]::UtcNow.ToString('o')
    expectedCases = $expectedCaseCount
    passed = $passed
    failed = $failed
    cases = @($script:results.ToArray())
}
try {
    if (-not $resultPathValid) { throw 'ResultPath did not pass safety validation.' }
    [IO.File]::WriteAllText($resultFullPath, ($report | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
} catch {
    Write-Host "[FAIL] writing result: $($_.Exception.Message)"
    exit 1
}
Write-Host "Runtime edge cases: $passed passed, $failed failed."
if ($failed -ne 0 -or $passed -ne $expectedCaseCount) { exit 1 }
exit 0
