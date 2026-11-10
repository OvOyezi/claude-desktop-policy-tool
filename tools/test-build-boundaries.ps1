[CmdletBinding()]
param(
    [string]$BuilderPath,
    [Parameter(Mandatory = $true)][string]$ResultPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Resolve the default in the script body for Windows PowerShell 5.1 -File.
if (-not $PSBoundParameters.ContainsKey('BuilderPath')) {
    $BuilderPath = Join-Path $PSScriptRoot 'build-release.ps1'
}

$script:results = New-Object 'System.Collections.Generic.List[object]'
$script:links = New-Object 'System.Collections.Generic.List[object]'
$testId = [guid]::NewGuid().ToString('N')
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = [IO.Path]::GetFullPath((Join-Path $tempParent "ClaudeBuildBoundaries-$testId"))
$outsideRoot = Join-Path $testRoot 'OutsideStore'
$pathsValidated = $false
$previousTemp = $env:TEMP; $previousTmp = $env:TMP
$names = @('normal_build', 'special_character_path', 'valid_prerelease', 'dist_junction',
    'nested_dist_junction', 'dist_file_symlink', 'repo_ancestor_junction', 'tool_symlink', 'source_symlink',
    'invalid_versions', 'selftest_failure')
$utf8 = New-Object Text.UTF8Encoding($false)
$packageFiles = @('Claude-Policy-Tool.cmd', 'README.md', 'LICENSE', 'SECURITY.md', 'CHANGELOG.md', 'RELEASE_NOTES.md')
$childCommand = @'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
try {
    & $env:CPT_TEST_BUILDER -Version $env:CPT_TEST_VERSION
    if ($env:CPT_SELF -cne 'build-test-prior-self' -or $env:CPT_ACTION -cne 'build-test-prior-action') {
        throw 'ENV_RESTORE_FAILED'
    }
    exit 0
} catch {
    if ($env:CPT_SELF -cne 'build-test-prior-self' -or $env:CPT_ACTION -cne 'build-test-prior-action') {
        [Console]::Error.WriteLine('ENV_RESTORE_FAILED')
        exit 96
    }
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))

function Test-TestPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $full.Equals($testRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($testRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-SafeTree {
    param([string]$Root)
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $items = New-Object 'System.Collections.Generic.List[string]'
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        foreach ($item in [IO.Directory]::GetFileSystemEntries($pending.Pop())) {
            $attributes = [IO.File]::GetAttributes($item)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Unexpected reparse point: $item" }
            $items.Add($item)
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($item) }
        }
    }
    return $items.ToArray()
}

function Get-TestHash {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Get-OutsideSnapshot {
    $entries = @()
    foreach ($item in @(Get-SafeTree $outsideRoot | Sort-Object)) {
        $relative = $item.Substring($outsideRoot.Length)
        if ([IO.Directory]::Exists($item)) { $entries += "D:$relative" }
        else { $entries += "F:${relative}:$(Get-TestHash $item)" }
    }
    return $entries -join "`n"
}

function New-TestLink {
    param([string]$Path, [string]$Target, [ValidateSet('Junction', 'SymbolicLink')][string]$Type)
    if (-not (Test-TestPath $Path) -or -not (Test-TestPath $Target)) { throw 'TEST HARNESS: link outside isolated root.' }
    $script:links.Add([pscustomobject]@{ path = $Path })
    try { [void](New-Item -ItemType $Type -Path $Path -Target $Target -ErrorAction Stop) }
    catch {
        $cause = $_.Exception; $unsupported = $false
        while ($null -ne $cause) {
            if ($cause.HResult -in @(-2147023582, -2147024891, -2147024846, -2147024895, -2147024879) -or
                $cause.Message -match '(?i)privilege|requires elevation|access.*denied|not supported|does not support|特权|权限|拒绝访问|不支持|提升') { $unsupported = $true }
            $cause = $cause.InnerException
        }
        if ($unsupported) { throw "SKIP_LINK: $Type unavailable: $($_.Exception.Message)" }
        throw "TEST HARNESS: $Type creation failed unexpectedly: $($_.Exception.Message)"
    }
    if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -eq 0) { throw 'TEST HARNESS: created item is not a reparse point.' }
}

function New-Fixture {
    param([string]$Name, [int]$SelftestExit = 0)
    $repo = Join-Path $testRoot $Name
    if (-not (Test-TestPath $repo)) { throw 'TEST HARNESS: fixture outside isolated root.' }
    [void][IO.Directory]::CreateDirectory((Join-Path $repo 'tools'))
    $builder = Join-Path $repo 'tools\build-release.ps1'
    [IO.File]::Copy($BuilderPath, $builder)
    $tool = Join-Path $repo 'Claude-Policy-Tool.cmd'
    $header = ((1..12 | ForEach-Object { 'rem isolated fixture line ' + $_ }) -join "`n")
    $payload = @'
if ($env:CPT_ACTION -cne '--self-test') { exit 41 }
if (-not [IO.File]::Exists($env:CPT_SELF)) { exit 42 }
$root = Split-Path -Parent $env:CPT_SELF
$marker = Join-Path $root 'selftest-ran.flag'
[IO.File]::WriteAllText($marker, ($env:CPT_SELF + "`n" + $env:CPT_ACTION), (New-Object Text.UTF8Encoding($false)))
exit __FIXTURE_EXIT__
'@
    $payload = $payload.Replace('__FIXTURE_EXIT__', [string]$SelftestExit)
    [IO.File]::WriteAllText($tool, ($header + "`n" + $payload), $utf8)
    foreach ($name in @($packageFiles | Where-Object { $_ -ne 'Claude-Policy-Tool.cmd' })) {
        [IO.File]::WriteAllText((Join-Path $repo $name), "fixture $name`n", $utf8)
    }
    [pscustomobject]@{ repo = $repo; builder = $builder; tool = $tool; dist = (Join-Path $repo 'dist'); marker = (Join-Path $repo 'selftest-ran.flag') }
}

function Invoke-FixtureBuild {
    param($Fixture, [string]$Version)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $script:powershellExe
    $start.Arguments = "-NoLogo -NoProfile -NonInteractive -InputFormat Text -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
    $start.WorkingDirectory = $Fixture.repo
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $start.EnvironmentVariables['CPT_TEST_BUILDER'] = $Fixture.builder
    $start.EnvironmentVariables['CPT_TEST_VERSION'] = $Version
    $start.EnvironmentVariables['CPT_SELF'] = 'build-test-prior-self'
    $start.EnvironmentVariables['CPT_ACTION'] = 'build-test-prior-action'
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $code = $null; $timedOut = $false; $outputText = ''; $errorText = ''; $detail = ''
    try {
        if (-not $process.Start()) { throw 'Could not start isolated build process.' }
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $timedOut = $true
            $detail = 'BUILD_PROCESS_TIMEOUT: process exceeded 30 seconds.'
            # Terminate the isolated process tree, then bound the wait for its exit.
            $killer = New-Object Diagnostics.Process
            $killer.StartInfo = New-Object Diagnostics.ProcessStartInfo
            $killer.StartInfo.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            $killer.StartInfo.Arguments = "/PID $($process.Id) /T /F"
            $killer.StartInfo.UseShellExecute = $false
            $killer.StartInfo.CreateNoWindow = $true
            try {
                [void]$killer.Start()
                if (-not $killer.WaitForExit(5000)) { $killer.Kill() }
            } finally { $killer.Dispose() }
            if (-not $process.HasExited) { try { $process.Kill() } catch {} }
            [void]$process.WaitForExit(5000)
        }
        if ($process.HasExited) { $code = $process.ExitCode }
        $streams = [Threading.Tasks.Task[]]@($stdout, $stderr)
        if (-not [Threading.Tasks.Task]::WaitAll($streams, 5000)) {
            $timedOut = $true
            $detail += ' OUTPUT_STREAM_TIMEOUT: output did not close; complete output is unavailable.'
        }
        if ($stdout.IsCompleted -and -not $stdout.IsFaulted -and -not $stdout.IsCanceled) { $outputText = $stdout.Result }
        if ($stderr.IsCompleted -and -not $stderr.IsFaulted -and -not $stderr.IsCanceled) { $errorText = $stderr.Result }
    } finally { $process.Dispose() }
    [pscustomobject]@{ accepted = ($code -eq 0 -and -not $timedOut); exitCode = $code; timedOut = $timedOut
        output = (@($outputText, $errorText, $detail) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n" }
}

function New-CaseResult {
    param([string]$Name, [bool]$Passed, [bool]$Skipped, $Accepted, [bool]$OutsideModified, [string]$ErrorText, [string]$Note = '')
    [pscustomobject]@{ name = $Name; passed = $Passed; skipped = $Skipped; accepted = $Accepted
        outsideModified = $OutsideModified; error = $ErrorText; note = $Note }
}

function Invoke-TestCase {
    param([string]$Name, [scriptblock]$Body)
    try { $record = & $Body }
    catch {
        $message = $_.Exception.Message; $skip = $message -match '^SKIP_LINK:'
        $record = New-CaseResult $Name $skip $skip $null $false $message
    }
    $script:results.Add($record)
    $state = if ($record.skipped) { 'SKIP' } elseif ($record.passed) { 'PASS' } else { 'FAIL' }
    Write-Host "[$state] $Name $($record.error)"
}

function Assert-Package {
    param($Fixture, [string]$Version)
    $packageName = "Claude-Desktop-Policy-Tool-v$Version"
    $zip = Join-Path $Fixture.dist "$packageName.zip"
    $sums = Join-Path $Fixture.dist 'SHA256SUMS.txt'
    if (-not [IO.File]::Exists($Fixture.marker) -or -not [IO.File]::Exists($zip) -or -not [IO.File]::Exists($sums)) { throw 'Self-test marker or package output is missing.' }
    $marker = [IO.File]::ReadAllText($Fixture.marker)
    if ($marker -cne ($Fixture.tool + "`n--self-test")) { throw 'Self-test did not receive the exact tool path and action.' }
    $lines = @([IO.File]::ReadAllLines($sums))
    if ($lines -cnotcontains "$(Get-TestHash $Fixture.tool)  Claude-Policy-Tool.cmd" -or
        $lines -cnotcontains "$(Get-TestHash $zip)  $packageName.zip") { throw 'Package checksums do not match.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $archiveNames = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        foreach ($name in $packageFiles) {
            if (@($archiveNames | Where-Object { $_ -eq $name -or $_.EndsWith('/' + $name, [StringComparison]::Ordinal) }).Count -ne 1) {
                throw "Package file missing or duplicated: $name"
            }
        }
    } finally { $archive.Dispose() }
}

function New-OutsideFixture {
    param([string]$Name)
    $directory = Join-Path $outsideRoot $Name
    [void][IO.Directory]::CreateDirectory($directory)
    [IO.File]::WriteAllText((Join-Path $directory 'sentinel.txt'), 'outside sentinel', $utf8)
    return $directory
}

function Invoke-RejectedPathCase {
    param([string]$Name, $Fixture)
    $beforeOutside = Get-OutsideSnapshot
    $beforeTool = Get-TestHash $Fixture.tool
    $result = Invoke-FixtureBuild $Fixture '1.2.3'
    $modified = $beforeOutside -cne (Get-OutsideSnapshot)
    $passed = -not $result.accepted -and -not $modified -and $beforeTool -ceq (Get-TestHash $Fixture.tool) -and
        -not [IO.File]::Exists($Fixture.marker) -and $result.output -match '(?i)reparse|symbolic|symlink|junction|重解析|符号链接|联接'
    New-CaseResult $Name $passed $false $result.accepted $modified $(if ($passed) { '' } else { $result.output }) 'Reject before source normalization, self-test, or external writes.'
}

try {
    $BuilderPath = (Resolve-Path -LiteralPath $BuilderPath).ProviderPath
    $script:powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not [IO.File]::Exists($script:powershellExe)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $expected = [IO.Path]::GetFullPath((Join-Path $tempParent "ClaudeBuildBoundaries-$testId"))
    if ($testId -notmatch '^[0-9a-f]{32}$' -or -not $testRoot.Equals($expected, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $testRoot)) {
        throw 'Test root validation failed.'
    }
    $pathsValidated = $true
    [void][IO.Directory]::CreateDirectory($outsideRoot)
    $env:TEMP = Join-Path $testRoot 'Temp'; $env:TMP = $env:TEMP
    [void][IO.Directory]::CreateDirectory($env:TEMP)
    # Check and unlink the reparse point itself, including when its target was removed.
    if (-not ('ClaudeBuildBoundaries.LinkCleanup' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace ClaudeBuildBoundaries {
    public static class LinkCleanup {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        private static extern uint GetFileAttributesW(string path);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        private static extern bool DeleteFileW(string path);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        private static extern bool RemoveDirectoryW(string path);
        public static void Remove(string path) {
            uint attributes = GetFileAttributesW(path);
            if (attributes == 0xFFFFFFFF) {
                int error = Marshal.GetLastWin32Error();
                if (error == 2 || error == 3) return;
                throw new Win32Exception(error);
            }
            if ((attributes & 0x400) == 0) throw new InvalidOperationException("Refusing to remove a non-link.");
            bool removed = (attributes & 0x10) != 0 ? RemoveDirectoryW(path) : DeleteFileW(path);
            if (!removed) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@
    }

    Invoke-TestCase 'normal_build' {
        $f = New-Fixture 'Normal'; [void][IO.Directory]::CreateDirectory($f.dist)
        [IO.File]::WriteAllText((Join-Path $f.dist 'old.txt'), 'old', $utf8)
        $before = Get-OutsideSnapshot; $r = Invoke-FixtureBuild $f '1.2.3'
        if (-not $r.accepted) { throw $r.output }
        Assert-Package $f '1.2.3'
        if ([IO.File]::Exists((Join-Path $f.dist 'old.txt'))) { throw 'The ordinary prior dist tree was not cleaned.' }
        $modified = $before -cne (Get-OutsideSnapshot)
        New-CaseResult 'normal_build' (-not $modified) $false $r.accepted $modified ''
    }
    Invoke-TestCase 'special_character_path' {
        $f = New-Fixture "Space 中文 %CPT_BUILD_TEST_VARIABLE% & 'quote'"
        $prior = [Environment]::GetEnvironmentVariable('CPT_BUILD_TEST_VARIABLE', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('CPT_BUILD_TEST_VARIABLE', 'EXPANDED_UNEXPECTEDLY', 'Process')
            $before = Get-OutsideSnapshot; $r = Invoke-FixtureBuild $f '1.2.3'
        } finally { [Environment]::SetEnvironmentVariable('CPT_BUILD_TEST_VARIABLE', $prior, 'Process') }
        if (-not $r.accepted) { throw $r.output }
        Assert-Package $f '1.2.3'
        $modified = $before -cne (Get-OutsideSnapshot)
        New-CaseResult 'special_character_path' (-not $modified) $false $r.accepted $modified '' 'Contains spaces, Chinese, percent expansion syntax, ampersand, and an apostrophe.'
    }
    Invoke-TestCase 'valid_prerelease' {
        $f = New-Fixture 'Prerelease'; $before = Get-OutsideSnapshot; $r = Invoke-FixtureBuild $f '1.2.3-rc.1'
        if (-not $r.accepted) { throw $r.output }
        Assert-Package $f '1.2.3-rc.1'
        $modified = $before -cne (Get-OutsideSnapshot)
        New-CaseResult 'valid_prerelease' (-not $modified) $false $r.accepted $modified ''
    }
    Invoke-TestCase 'dist_junction' {
        $f = New-Fixture 'DistJunction'; $outside = New-OutsideFixture 'DistJunction'
        New-TestLink $f.dist $outside 'Junction'
        Invoke-RejectedPathCase 'dist_junction' $f
    }
    Invoke-TestCase 'nested_dist_junction' {
        $f = New-Fixture 'NestedDist'; $outside = New-OutsideFixture 'NestedDist'
        $nested = Join-Path $f.dist 'nested'; [void][IO.Directory]::CreateDirectory($nested)
        $untouched = Join-Path $f.dist 'untouched.txt'; [IO.File]::WriteAllText($untouched, 'keep', $utf8)
        New-TestLink (Join-Path $nested 'redirect') $outside 'Junction'
        $record = Invoke-RejectedPathCase 'nested_dist_junction' $f
        if (-not [IO.File]::Exists($untouched) -or [IO.File]::ReadAllText($untouched) -cne 'keep') { $record.passed = $false; $record.error = 'Ordinary dist content was altered before rejection.' }
        $record
    }
    Invoke-TestCase 'dist_file_symlink' {
        $f = New-Fixture 'DistFileLink'; $outside = New-OutsideFixture 'DistFileLink'
        [void][IO.Directory]::CreateDirectory($f.dist)
        New-TestLink (Join-Path $f.dist 'SHA256SUMS.txt') (Join-Path $outside 'sentinel.txt') 'SymbolicLink'
        Invoke-RejectedPathCase 'dist_file_symlink' $f
    }
    Invoke-TestCase 'repo_ancestor_junction' {
        $physical = New-Fixture 'PhysicalRepo'; $alias = Join-Path $testRoot 'RepoAlias'
        New-TestLink $alias $physical.repo 'Junction'
        $f = [pscustomobject]@{ repo = $alias; builder = (Join-Path $alias 'tools\build-release.ps1')
            tool = (Join-Path $alias 'Claude-Policy-Tool.cmd'); dist = (Join-Path $alias 'dist'); marker = (Join-Path $alias 'selftest-ran.flag') }
        Invoke-RejectedPathCase 'repo_ancestor_junction' $f
    }
    Invoke-TestCase 'tool_symlink' {
        $f = New-Fixture 'ToolLink'; $outside = New-OutsideFixture 'ToolLink'; $target = Join-Path $outside 'tool.cmd'
        [IO.File]::Copy($f.tool, $target); [IO.File]::Delete($f.tool); New-TestLink $f.tool $target 'SymbolicLink'
        Invoke-RejectedPathCase 'tool_symlink' $f
    }
    Invoke-TestCase 'source_symlink' {
        $f = New-Fixture 'SourceLink'; $outside = New-OutsideFixture 'SourceLink'
        $source = Join-Path $f.repo 'README.md'; $target = Join-Path $outside 'readme.md'
        [IO.File]::Copy($source, $target); [IO.File]::Delete($source); New-TestLink $source $target 'SymbolicLink'
        Invoke-RejectedPathCase 'source_symlink' $f
    }
    Invoke-TestCase 'invalid_versions' {
        $f = New-Fixture 'InvalidVersions'; [void][IO.Directory]::CreateDirectory($f.dist)
        $untouched = Join-Path $f.dist 'untouched.txt'; [IO.File]::WriteAllText($untouched, 'keep', $utf8)
        $before = Get-OutsideSnapshot; $beforeTool = Get-TestHash $f.tool; $failures = @()
        foreach ($version in @('..\escape', '1.2.3.4', '1.2.3-01', '1.2.3+build', '1.2.3/../../escape', '1.2.3 ')) {
            $r = Invoke-FixtureBuild $f $version
            if ($r.accepted -or $r.output -notmatch '(?i)SemVer|version|版本') { $failures += "${version}: $($r.output)" }
        }
        $modified = $before -cne (Get-OutsideSnapshot)
        $untouchedOk = [IO.File]::Exists($untouched) -and [IO.File]::ReadAllText($untouched) -ceq 'keep'
        $passed = $failures.Count -eq 0 -and -not $modified -and $untouchedOk -and $beforeTool -ceq (Get-TestHash $f.tool) -and -not [IO.File]::Exists($f.marker)
        New-CaseResult 'invalid_versions' $passed $false ($failures.Count -gt 0) $modified ($failures -join '; ') 'Invalid input must be rejected before source normalization or any dist cleanup.'
    }
    Invoke-TestCase 'selftest_failure' {
        $f = New-Fixture 'SelftestFailure' 23; [void][IO.Directory]::CreateDirectory($f.dist)
        $untouched = Join-Path $f.dist 'untouched.txt'; [IO.File]::WriteAllText($untouched, 'keep', $utf8)
        $before = Get-OutsideSnapshot; $r = Invoke-FixtureBuild $f '1.2.3'; $modified = $before -cne (Get-OutsideSnapshot)
        $untouchedOk = [IO.File]::Exists($untouched) -and [IO.File]::ReadAllText($untouched) -ceq 'keep'
        $passed = -not $r.accepted -and $r.output -match '23' -and [IO.File]::Exists($f.marker) -and $untouchedOk -and -not $modified
        New-CaseResult 'selftest_failure' $passed $false $r.accepted $modified $(if ($passed) { '' } else { $r.output }) 'A nonzero self-test must prevent dist cleanup.'
    }
} catch {
    $script:results.Add((New-CaseResult 'test_setup' $false $false $null $false $_.Exception.Message))
} finally {
    $env:TEMP = $previousTemp; $env:TMP = $previousTmp
    $cleanupErrors = New-Object 'System.Collections.Generic.List[string]'
    if ($pathsValidated) {
        foreach ($link in @($script:links.ToArray())) {
            try {
                if (-not (Test-TestPath $link.path)) { throw 'Link cleanup path validation failed.' }
                [ClaudeBuildBoundaries.LinkCleanup]::Remove($link.path)
            } catch { $cleanupErrors.Add("Link $($link.path): $($_.Exception.Message)") }
        }
        try {
            $expected = [IO.Path]::GetFullPath((Join-Path $tempParent "ClaudeBuildBoundaries-$testId"))
            if ($testId -notmatch '^[0-9a-f]{32}$' -or -not $testRoot.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { throw 'Directory cleanup validation failed.' }
            if ([IO.Directory]::Exists($testRoot)) {
                if (([IO.File]::GetAttributes($testRoot) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Test root is a reparse point.' }
                $null = @(Get-SafeTree $testRoot)
                Remove-Item -LiteralPath $testRoot -Recurse
            }
        } catch { $cleanupErrors.Add("Directory: $($_.Exception.Message)") }
    }
    if ($cleanupErrors.Count -gt 0) { $script:results.Add((New-CaseResult 'cleanup' $false $false $null $false ($cleanupErrors -join '; '))) }
}

foreach ($name in $names) {
    if (@($script:results | Where-Object { $_.name -eq $name }).Count -eq 0) {
        $script:results.Add((New-CaseResult $name $false $false $null $false 'Test setup failed or case was not executed.'))
    }
}
$failed = @($script:results | Where-Object { -not $_.passed -and -not $_.skipped }).Count
$skipped = @($script:results | Where-Object { $_.skipped }).Count
$result = [pscustomobject]@{ builderPath = $BuilderPath; testId = $testId; failed = $failed; skipped = $skipped; cases = @($script:results.ToArray()) }
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath), ($result | ConvertTo-Json -Depth 8), $utf8)
Write-Host "Build boundary tests: $failed failed, $skipped skipped. Results: $ResultPath"
if ($failed -gt 0) { exit 1 }
exit 0
