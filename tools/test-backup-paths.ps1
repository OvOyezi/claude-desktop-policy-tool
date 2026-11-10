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

$script:results = New-Object 'System.Collections.Generic.List[object]'
$script:links = New-Object 'System.Collections.Generic.List[object]'
$testId = [guid]::NewGuid().ToString('N')
$registryRoot = "Software\ClaudePolicyToolTests\$testId"
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = [IO.Path]::GetFullPath((Join-Path $tempParent "ClaudePolicyBackupPaths-$testId"))
$outsideRoot = Join-Path $testRoot 'OutsideStore'
$approvedRoot = Join-Path $testRoot 'Approved'
$previousTemp = $env:TEMP
$previousTmp = $env:TMP
$pathsValidated = $false
$testParentCreated = $false
$testParentRemoved = $false
$caseNames = @('normal_backup_and_read', 'fixture_control', 'selected_directory_junction', 'approved_root_junction',
    'ancestor_junction', 'manifest_symlink', 'checksum_symlink', 'reg_symlink',
    'dangling_checksum_symlink', 'dangling_reg_symlink', 'dangling_directory_symlink', 'new_backup_root_junction',
    'new_backup_ancestor_junction', 'compatibility_root_junction', 'compatibility_ancestor_junction',
    'reg_hardlink_observation', 'changed_reg_after_validation', 'changed_checksum_after_validation',
    'coordinated_changes_after_validation')

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
        $directory = $pending.Pop()
        foreach ($item in [IO.Directory]::GetFileSystemEntries($directory)) {
            $attributes = [IO.File]::GetAttributes($item)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Unexpected reparse point in inspected tree: $item" }
            $items.Add($item)
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($item) }
        }
    }
    return $items.ToArray()
}

function Get-FileHashText {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Get-OutsideSnapshot {
    $parts = @()
    foreach ($item in @(Get-SafeTree $outsideRoot | Sort-Object)) {
        $relative = $item.Substring($outsideRoot.Length)
        if ([IO.Directory]::Exists($item)) { $parts += "D:$relative" }
        else { $parts += "F:${relative}:$(Get-FileHashText $item)" }
    }
    return $parts -join "`n"
}

function New-TestLink {
    param([string]$Path, [string]$Target, [ValidateSet('Junction', 'SymbolicLink', 'HardLink')][string]$Type)
    if (-not (Test-TestPath $Path) -or -not (Test-TestPath $Target)) { throw 'TEST HARNESS: link path outside test root.' }
    if ($Type -ne 'HardLink') { $script:links.Add([pscustomobject]@{ path = $Path; type = $Type }) }
    try {
        [void](New-Item -ItemType $Type -Path $Path -Target $Target -ErrorAction Stop)
    } catch {
        $cause = $_.Exception; $capabilityFailure = $false
        while ($null -ne $cause) {
            if ($cause.HResult -in @(-2147023582, -2147024891, -2147024846, -2147024895, -2147024879) -or
                $cause.Message -match '(?i)privilege|requires elevation|access.*denied|not supported|does not support|特权|权限|拒绝访问|不支持|提升') {
                $capabilityFailure = $true
            }
            $cause = $cause.InnerException
        }
        if ($capabilityFailure) { throw "SKIP_LINK: $Type unavailable: $($_.Exception.Message)" }
        throw "TEST HARNESS: $Type creation failed unexpectedly: $($_.Exception.Message)"
    }
    if ($Type -ne 'HardLink' -and (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
        throw 'TEST HARNESS: created item is not a reparse point.'
    }
}

function New-BackupFixture {
    param([string]$Directory)
    if (-not (Test-TestPath $Directory)) { throw 'TEST HARNESS: fixture outside test root.' }
    [void][IO.Directory]::CreateDirectory($Directory)
    $regFile = Join-Path $Directory "$($script:target.id).reg"
    $text = "Windows Registry Editor Version 5.00`r`n`r`n[$($script:target.fullRoot)]`r`n`"Marker`"=`"original`"`r`n`r`n"
    [IO.File]::WriteAllText($regFile, $text, [Text.Encoding]::Unicode)
    $manifest = [ordered]@{
        toolId = $ToolId; toolVersion = $ToolVersion; schemaVersion = $SchemaVersion; kind = 'PathTest'
        createdUtc = [DateTime]::UtcNow.ToString('o'); computerName = $env:COMPUTERNAME
        userName = 'isolated-test'; windowsVersion = [Environment]::OSVersion.VersionString
        osArchitecture = $env:PROCESSOR_ARCHITECTURE; is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem
        mayContainSensitivePolicyData = $true; scriptSha256 = (Get-FileHashText $ScriptPath)
        targets = @([ordered]@{ id = $script:target.id; hive = 'HKCU'; view = $script:target.view
            regPath = $script:target.regPath; fullRoot = $script:target.fullRoot; existed = $true
            backupFile = "$($script:target.id).reg"; sha256 = (Get-FileHashText $regFile) })
    }
    $manifestPath = Join-Path $Directory 'manifest.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), $Utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $Directory 'manifest.sha256'), (Get-FileHashText $manifestPath), $Utf8NoBom)
}

function Test-PathRejection {
    param([string]$Message)
    return $Message -match '(?i)reparse|symbolic|symlink|junction|hard.?link|unsafe.*path|outside.*root|不在.*允许|重解析|符号链接|链接|联接|备份.*路径|路径.*不安全'
}

function Test-ReparseRejection {
    param([string]$Message)
    return $Message -match '(?i)reparse|symbolic|symlink|junction|重解析|符号链接|链接|联接|重定向'
}

function Test-ChangedContentRejection {
    param([string]$Message)
    return $Message -match '(?i)integrity|hash|checksum|changed|tamper|scope|unsafe|校验|完整性|篡改|变更|变化|已修改|越界|范围|禁止|不允许'
}

function Test-SharingViolation {
    param($Exception)
    while ($null -ne $Exception) {
        if ($Exception.HResult -eq -2147024864 -or $Exception.Message -match '(?i)sharing violation|being used by another process|used by another process|共享冲突|另一进程|另一个程序') { return $true }
        $Exception = $Exception.InnerException
    }
    return $false
}

function New-CaseResult {
    param([string]$Name, [string]$Expected, $Accepted, [bool]$OutsideModified, $OutsideReadObserved,
        [bool]$Passed, [bool]$Skipped, [string]$ErrorText, [string]$ProbeError = '', [string]$Note = '')
    [pscustomobject]@{ name = $Name; expected = $Expected; accepted = $Accepted; outsideModified = $OutsideModified
        outsideReadObserved = $OutsideReadObserved; passed = $Passed; skipped = $Skipped; error = $ErrorText
        probeError = $ProbeError; note = $Note }
}

function Invoke-TestCase {
    param([string]$Name, [scriptblock]$Body)
    try { $record = & $Body }
    catch {
        $message = $_.Exception.Message
        $skip = $message -match '^SKIP_LINK:'
        $record = New-CaseResult $Name 'setup' $null $false $null $skip $skip $message
    }
    $script:results.Add($record)
    $state = if ($record.skipped) { 'SKIP' } elseif ($record.passed) { 'PASS' } else { 'FAIL' }
    Write-Host "[$state] $Name $($record.error)"
}

function Invoke-ReadPathCase {
    param([string]$Name, [string]$Directory, [string]$Root, [string]$OutsideFile)
    $before = Get-OutsideSnapshot
    $accepted = $false; $failure = ''
    try { $null = Read-ValidatedBackup -Directory $Directory -ExpectedTargets @($script:target) -ApprovedRoot $Root; $accepted = $true }
    catch { $failure = $_.Exception.Message }
    $modified = $before -cne (Get-OutsideSnapshot)

    # Lock only after the unmodified attempt. A sharing violation demonstrates an attempted
    # outside content read; an arbitrary exception is not treated as proof of path protection.
    $readObserved = $false; $probeError = ''; $lockAvailable = $false; $probeAccepted = $false
    $stream = $null
    try {
        $stream = [IO.File]::Open($OutsideFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        $lockAvailable = $true
        try { $null = Read-ValidatedBackup -Directory $Directory -ExpectedTargets @($script:target) -ApprovedRoot $Root; $probeAccepted = $true }
        catch { $probeError = $_.Exception.Message; $readObserved = Test-SharingViolation $_.Exception }
    } catch { $probeError = "Lock probe unavailable: $($_.Exception.Message)" }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
    $passed = -not $accepted -and -not $modified -and -not $readObserved -and $lockAvailable -and -not $probeAccepted -and (Test-PathRejection $failure) -and (Test-PathRejection $probeError)
    New-CaseResult $Name 'reject_path_before_outside_read' $accepted $modified $readObserved $passed $false $failure $probeError 'Lock probe observes sharing violations; it cannot prove that every possible read is absent.'
}

function Invoke-NewPathCase {
    param([string]$Name, [string]$Root)
    $before = Get-OutsideSnapshot
    $accepted = $false; $failure = ''
    try { $null = New-BackupSet -Targets @($script:target) -Root $Root -Kind 'PathTest'; $accepted = $true }
    catch { $failure = $_.Exception.Message }
    $modified = $before -cne (Get-OutsideSnapshot)
    New-CaseResult $Name 'reject_path_before_outside_write' $accepted $modified $null (-not $accepted -and -not $modified -and (Test-PathRejection $failure)) $false $failure
}

function Invoke-DanglingPathCase {
    param([string]$Name, [string]$Directory, [string]$Root)
    $before = Get-OutsideSnapshot
    $accepted = $false; $failure = ''
    try { $null = Read-ValidatedBackup -Directory $Directory -ExpectedTargets @($script:target) -ApprovedRoot $Root; $accepted = $true }
    catch { $failure = $_.Exception.Message }
    $modified = $before -cne (Get-OutsideSnapshot)
    $passed = -not $accepted -and -not $modified -and (Test-ReparseRejection $failure)
    New-CaseResult $Name 'reject_dangling_reparse_point' $accepted $modified $null $passed $false $failure '' 'Target is absent; no outside-content read probe is possible.'
}

function Invoke-CompatibilityPathCase {
    param([string]$Name, [string]$Data, [string]$Backup)
    $script:DataRoot = Join-Path $testRoot 'SafeData'
    $script:BackupRoot = Join-Path $script:DataRoot 'Backups'
    $control = Get-CompatibilityReport
    $before = Get-OutsideSnapshot
    $script:DataRoot = $Data; $script:BackupRoot = $Backup
    $report = Get-CompatibilityReport
    $errorText = @($report.errors) -join '; '
    $modified = $before -cne (Get-OutsideSnapshot)
    $passed = $control.ready -and -not $report.ready -and -not $modified -and (Test-PathRejection $errorText)
    New-CaseResult $Name 'compatibility_rejects_path' ([bool]$report.ready) $modified $null $passed $false $errorText '' ("Control ready: $($control.ready); control errors: " + (@($control.errors) -join '; '))
}

function Get-TestMarker {
    param([ValidateSet('Allowed', 'SiblingOutside')][string]$Leaf)
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $regView)
    try {
        $key = $base.OpenSubKey("$registryRoot\$Leaf", $false)
        if ($null -eq $key) { throw "Missing isolated test key: $Leaf" }
        try { return [string]$key.GetValue('Marker') } finally { $key.Dispose() }
    } finally { $base.Dispose() }
}

function Set-TestMarker {
    param([ValidateSet('Allowed', 'SiblingOutside')][string]$Leaf, [string]$Value)
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $regView)
    try {
        $key = $base.OpenSubKey("$registryRoot\$Leaf", $true)
        if ($null -eq $key) { throw "Missing isolated test key: $Leaf" }
        try { $key.SetValue('Marker', $Value) } finally { $key.Dispose() }
    } finally { $base.Dispose() }
}

function Invoke-ChangedRegCase {
    param([string]$Name, [bool]$Coordinated)
    Set-TestMarker 'Allowed' 'original'
    $root = Join-Path $testRoot $Name; [void][IO.Directory]::CreateDirectory($root)
    $saved = New-BackupSet -Targets @($script:target) -Root $root -Kind 'ChangedContent'
    $control = Read-ValidatedBackup $saved @($script:target) $root
    $null = Apply-ValidatedBackupUnsafe $control @($script:target)
    $sibling = "HKEY_CURRENT_USER\$registryRoot\SiblingOutside"
    $text = "Windows Registry Editor Version 5.00`r`n`r`n[$($script:target.fullRoot)]`r`n`"Marker`"=`"injected`"`r`n`r`n[$sibling]`r`n`"Marker`"=`"changed`"`r`n`r`n"
    # This isolated positive control proves that the altered .reg really changes the sibling.
    $proof = Join-Path $env:TEMP "$Name-proof.reg"
    [IO.File]::WriteAllText($proof, $text, [Text.Encoding]::Unicode)
    $null = Invoke-Reg -Arguments @('import', $proof, "/reg:$view")
    if ((Get-TestMarker 'SiblingOutside') -cne 'changed' -or (Get-TestMarker 'Allowed') -cne 'injected') { throw 'Import positive control failed.' }
    Set-TestMarker 'SiblingOutside' 'sentinel'
    Set-TestMarker 'Allowed' 'original'
    $before = Get-TestMarker 'SiblingOutside'
    $validated = Read-ValidatedBackup $saved @($script:target) $root
    $file = Join-Path $saved "$($script:target.id).reg"
    [IO.File]::WriteAllText($file, $text, [Text.Encoding]::Unicode)
    if ($Coordinated) {
        # Rewrite the manifest and its checksum consistently, after obtaining the validated object.
        $manifestPath = Join-Path $saved 'manifest.json'
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        $entries = @($manifest.targets | Where-Object { $_.id -eq $script:target.id })
        if ($entries.Count -ne 1) { throw 'Expected one manifest entry for the isolated target.' }
        $entries[0].sha256 = Get-FileHashText $file
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), $Utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $saved 'manifest.sha256'), (Get-FileHashText $manifestPath), $Utf8NoBom)
        if ($entries[0].sha256 -cne (Get-FileHashText $file) -or
            ([IO.File]::ReadAllText((Join-Path $saved 'manifest.sha256'))) -cne (Get-FileHashText $manifestPath)) {
            throw 'Coordinated fixture hashes do not match.'
        }
    }
    $accepted = $false; $failure = ''
    try { $null = Apply-ValidatedBackupUnsafe $validated @($script:target); $accepted = $true } catch { $failure = $_.Exception.Message }
    $modified = $before -cne (Get-TestMarker 'SiblingOutside')
    $allowedCorrect = -not $accepted -or (Get-TestMarker 'Allowed') -ceq 'original'
    $passed = -not $modified -and $allowedCorrect -and ($accepted -or (Test-ChangedContentRejection $failure)) -and $failure -notmatch 'TEST HARNESS'
    New-CaseResult $Name 'outside_registry_unchanged' $accepted $modified $null $passed $false $failure '' 'Positive-control import proves the payload works; the sibling is inside the isolated GUID. The source files change after validation.'
}

try {
    $ToolPath = (Resolve-Path -LiteralPath $ToolPath).ProviderPath
    $payload = ((Get-Content -LiteralPath $ToolPath -Encoding UTF8 | Select-Object -Skip 12) -join "`n")
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($payload, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw ('Payload parse failed: ' + (($parseErrors | ForEach-Object { $_.Message }) -join '; ')) }
    $definitions = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })
    foreach ($name in @('New-Target', 'Invoke-Reg', 'New-BackupSet', 'Read-ValidatedBackup', 'Apply-ValidatedBackupUnsafe', 'Get-CompatibilityReport')) {
        if (@($definitions | Where-Object { $_.Name -eq $name }).Count -ne 1) { throw "Missing unique function: $name" }
    }
    . ([scriptblock]::Create((($definitions | ForEach-Object { $_.Extent.Text }) -join "`n")))
    $ToolId = 'ClaudePolicyTool'; $ToolVersion = 'path-test'; $SchemaVersion = 1
    $ScriptPath = $ToolPath; $ScriptRoot = Split-Path -Parent $ToolPath
    $RegExe = Join-Path $env:SystemRoot 'System32\reg.exe'
    $Utf8NoBom = New-Object Text.UTF8Encoding($false)
    $view = if ([Environment]::Is64BitOperatingSystem) { 64 } else { 32 }
    $regView = if ($view -eq 64) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Registry32 }
    $script:target = New-Target 'Isolated' 'HKCU' $view "HKCU\$registryRoot\Allowed" "HKEY_CURRENT_USER\$registryRoot\Allowed"
    $script:realInvokeReg = ${function:Invoke-Reg}

    if ($testId -notmatch '^[0-9a-f]{32}$' -or $registryRoot -cne "Software\ClaudePolicyToolTests\$testId" -or
        -not $testRoot.Equals([IO.Path]::GetFullPath((Join-Path $tempParent "ClaudePolicyBackupPaths-$testId")), [StringComparison]::OrdinalIgnoreCase) -or
        (Test-Path -LiteralPath $testRoot)) { throw 'Test root validation failed.' }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $regView)
    try {
        $existing = $base.OpenSubKey($registryRoot, $false)
        if ($null -ne $existing) { $existing.Dispose(); throw 'Random registry test root already exists.' }
    } finally { $base.Dispose() }
    $pathsValidated = $true
    [void][IO.Directory]::CreateDirectory($outsideRoot)
    [void][IO.Directory]::CreateDirectory($approvedRoot)
    $env:TEMP = Join-Path $testRoot 'Temp'; $env:TMP = $env:TEMP
    [void][IO.Directory]::CreateDirectory($env:TEMP)
    # RegCreateKeyEx reports atomically whether this run created the shared test parent.
    if (-not ('ClaudePolicyPathTests.RegistryParent' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace ClaudePolicyPathTests {
    public static class RegistryParent {
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern int RegCreateKeyExW(IntPtr key, string subkey, int reserved, string keyClass,
            int options, int access, IntPtr security, out IntPtr result, out int disposition);
        [DllImport("advapi32.dll", ExactSpelling = true)]
        private static extern int RegCloseKey(IntPtr key);
        public static bool Ensure(int view) {
            IntPtr result = IntPtr.Zero;
            int disposition;
            int access = 0x20019 | 0x20006 | (view == 64 ? 0x0100 : 0x0200);
            int status = RegCreateKeyExW(new IntPtr(unchecked((int)0x80000001)),
                @"Software\ClaudePolicyToolTests", 0, null, 0, access, IntPtr.Zero, out result, out disposition);
            try {
                if (status != 0) throw new Win32Exception(status);
                return disposition == 1;
            } finally { if (result != IntPtr.Zero) RegCloseKey(result); }
        }
    }
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
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $regView)
    try {
        $software = $base.OpenSubKey('Software', $false)
        if ($null -eq $software) { throw 'Expected HKCU Software key is missing.' }
        $software.Dispose()
        $testParentCreated = [ClaudePolicyPathTests.RegistryParent]::Ensure($view)
        foreach ($leaf in @('Allowed', 'SiblingOutside')) {
            $key = $base.CreateSubKey("$registryRoot\$leaf")
            try { $key.SetValue('Marker', $(if ($leaf -eq 'Allowed') { 'original' } else { 'sentinel' })) } finally { $key.Dispose() }
        }
    } finally { $base.Dispose() }

    # Restrict native reg.exe calls even if the function under test regresses.
    function Invoke-Reg {
        param([string[]]$Arguments, [switch]$AllowFailure)
        if ($Arguments.Count -lt 3 -or $Arguments[-1] -cne "/reg:$view") { throw 'TEST HARNESS: blocked registry command.' }
        switch ($Arguments[0]) {
            'query' {
                if ($Arguments.Count -ne 3 -or $Arguments[1] -cne $script:target.regPath) { throw 'TEST HARNESS: blocked registry query.' }
            }
            'export' {
                if ($Arguments.Count -ne 5 -or $Arguments[1] -cne $script:target.regPath -or $Arguments[3] -ne '/y' -or -not (Test-TestPath $Arguments[2])) { throw 'TEST HARNESS: blocked registry export.' }
            }
            'delete' {
                if ($Arguments.Count -ne 4 -or $Arguments[1] -cne $script:target.regPath -or $Arguments[2] -ne '/f') { throw 'TEST HARNESS: blocked registry delete.' }
            }
            'import' {
                if ($Arguments.Count -ne 3 -or -not (Test-TestPath $Arguments[1])) { throw 'TEST HARNESS: blocked registry import path.' }
                $text = [IO.File]::ReadAllText($Arguments[1])
                $heads = [regex]::Matches($text, '(?m)^\[([^\]]+)\]\s*$')
                if ($heads.Count -eq 0) { throw 'TEST HARNESS: import has no registry keys.' }
                $safeRoot = "HKEY_CURRENT_USER\$registryRoot"
                foreach ($head in $heads) {
                    $name = $head.Groups[1].Value
                    if (-not ($name.Equals($safeRoot, [StringComparison]::OrdinalIgnoreCase) -or $name.StartsWith($safeRoot + '\', [StringComparison]::OrdinalIgnoreCase))) { throw 'TEST HARNESS: blocked import outside isolated test registry root.' }
                }
            }
            default { throw 'TEST HARNESS: blocked unexpected registry command.' }
        }
        & $script:realInvokeReg -Arguments $Arguments -AllowFailure:$AllowFailure
    }
    function Test-ClaudeInstalled { return $true }

    Invoke-TestCase 'normal_backup_and_read' {
        $root = Join-Path $testRoot 'Normal'; [void][IO.Directory]::CreateDirectory($root)
        $before = Get-OutsideSnapshot; $accepted = $false; $failure = ''
        try { $directory = New-BackupSet -Targets @($script:target) -Root $root -Kind 'Normal'; $null = Read-ValidatedBackup $directory @($script:target) $root; $accepted = $true } catch { $failure = $_.Exception.Message }
        $modified = $before -cne (Get-OutsideSnapshot)
        New-CaseResult 'normal_backup_and_read' 'accept' $accepted $modified $false ($accepted -and -not $modified) $false $failure
    }
    Invoke-TestCase 'fixture_control' {
        $saved = Join-Path $approvedRoot 'FixtureControl'; New-BackupFixture $saved
        $before = Get-OutsideSnapshot; $accepted = $false; $failure = ''
        try { $null = Read-ValidatedBackup $saved @($script:target) $approvedRoot; $accepted = $true } catch { $failure = $_.Exception.Message }
        $modified = $before -cne (Get-OutsideSnapshot)
        New-CaseResult 'fixture_control' 'accept' $accepted $modified $false ($accepted -and -not $modified) $false $failure
    }
    Invoke-TestCase 'selected_directory_junction' {
        $physical = Join-Path $outsideRoot 'Selected'; New-BackupFixture $physical
        $link = Join-Path $approvedRoot 'SelectedLink'; New-TestLink $link $physical 'Junction'
        Invoke-ReadPathCase 'selected_directory_junction' $link $approvedRoot (Join-Path $physical 'manifest.sha256')
    }
    Invoke-TestCase 'approved_root_junction' {
        $physical = Join-Path $outsideRoot 'Root'; $saved = Join-Path $physical 'Saved'; New-BackupFixture $saved
        $link = Join-Path $testRoot 'RootLink'; New-TestLink $link $physical 'Junction'
        Invoke-ReadPathCase 'approved_root_junction' (Join-Path $link 'Saved') $link (Join-Path $saved 'manifest.sha256')
    }
    Invoke-TestCase 'ancestor_junction' {
        $physical = Join-Path $outsideRoot 'Ancestor'; $saved = Join-Path $physical 'Data\Backups\Saved'; New-BackupFixture $saved
        $link = Join-Path $testRoot 'AncestorLink'; New-TestLink $link $physical 'Junction'
        Invoke-ReadPathCase 'ancestor_junction' (Join-Path $link 'Data\Backups\Saved') (Join-Path $link 'Data\Backups') (Join-Path $saved 'manifest.sha256')
    }
    Invoke-TestCase 'manifest_symlink' {
        $saved = Join-Path $approvedRoot 'ManifestLink'; New-BackupFixture $saved
        $file = Join-Path $saved 'manifest.json'; $outside = Join-Path $outsideRoot 'manifest.json'
        [IO.File]::Copy($file, $outside); [IO.File]::Delete($file); New-TestLink $file $outside 'SymbolicLink'
        Invoke-ReadPathCase 'manifest_symlink' $saved $approvedRoot $outside
    }
    Invoke-TestCase 'checksum_symlink' {
        $saved = Join-Path $approvedRoot 'ChecksumLink'; New-BackupFixture $saved
        $file = Join-Path $saved 'manifest.sha256'; $outside = Join-Path $outsideRoot 'linked.sha256'
        [IO.File]::Copy($file, $outside); [IO.File]::Delete($file); New-TestLink $file $outside 'SymbolicLink'
        Invoke-ReadPathCase 'checksum_symlink' $saved $approvedRoot $outside
    }
    Invoke-TestCase 'reg_symlink' {
        $saved = Join-Path $approvedRoot 'RegLink'; New-BackupFixture $saved
        $file = Join-Path $saved "$($script:target.id).reg"; $outside = Join-Path $outsideRoot 'linked.reg'
        [IO.File]::Copy($file, $outside); [IO.File]::Delete($file); New-TestLink $file $outside 'SymbolicLink'
        Invoke-ReadPathCase 'reg_symlink' $saved $approvedRoot $outside
    }
    Invoke-TestCase 'dangling_checksum_symlink' {
        $saved = Join-Path $approvedRoot 'DanglingChecksum'; New-BackupFixture $saved
        $file = Join-Path $saved 'manifest.sha256'; $outside = Join-Path $outsideRoot 'dangling.sha256'
        [IO.File]::Copy($file, $outside); [IO.File]::Delete($file); New-TestLink $file $outside 'SymbolicLink'
        [IO.File]::Delete($outside)
        Invoke-DanglingPathCase 'dangling_checksum_symlink' $saved $approvedRoot
    }
    Invoke-TestCase 'dangling_reg_symlink' {
        $saved = Join-Path $approvedRoot 'DanglingReg'; New-BackupFixture $saved
        $file = Join-Path $saved "$($script:target.id).reg"; $outside = Join-Path $outsideRoot 'dangling.reg'
        [IO.File]::Copy($file, $outside); [IO.File]::Delete($file); New-TestLink $file $outside 'SymbolicLink'
        [IO.File]::Delete($outside)
        Invoke-DanglingPathCase 'dangling_reg_symlink' $saved $approvedRoot
    }
    Invoke-TestCase 'dangling_directory_symlink' {
        $outside = Join-Path $outsideRoot 'DanglingDirectory'; [void][IO.Directory]::CreateDirectory($outside)
        $link = Join-Path $approvedRoot 'DanglingDirectoryLink'; New-TestLink $link $outside 'SymbolicLink'
        [IO.Directory]::Delete($outside, $false)
        Invoke-DanglingPathCase 'dangling_directory_symlink' $link $approvedRoot
    }
    Invoke-TestCase 'new_backup_root_junction' {
        $physical = Join-Path $outsideRoot 'NewRoot'; [void][IO.Directory]::CreateDirectory($physical)
        $link = Join-Path $testRoot 'NewRootLink'; New-TestLink $link $physical 'Junction'
        Invoke-NewPathCase 'new_backup_root_junction' $link
    }
    Invoke-TestCase 'new_backup_ancestor_junction' {
        $physical = Join-Path $outsideRoot 'NewAncestor'; [void][IO.Directory]::CreateDirectory((Join-Path $physical 'Data\Backups'))
        $link = Join-Path $testRoot 'NewAncestorLink'; New-TestLink $link $physical 'Junction'
        Invoke-NewPathCase 'new_backup_ancestor_junction' (Join-Path $link 'Data\Backups')
    }
    Invoke-TestCase 'compatibility_root_junction' {
        $physical = Join-Path $outsideRoot 'CompatibilityRoot'; [void][IO.Directory]::CreateDirectory($physical)
        $link = Join-Path $testRoot 'CompatibilityRootLink'; New-TestLink $link $physical 'Junction'
        Invoke-CompatibilityPathCase 'compatibility_root_junction' $testRoot $link
    }
    Invoke-TestCase 'compatibility_ancestor_junction' {
        $physical = Join-Path $outsideRoot 'CompatibilityAncestor'; [void][IO.Directory]::CreateDirectory((Join-Path $physical 'Data\Backups'))
        $link = Join-Path $testRoot 'CompatibilityAncestorLink'; New-TestLink $link $physical 'Junction'
        Invoke-CompatibilityPathCase 'compatibility_ancestor_junction' (Join-Path $link 'Data') (Join-Path $link 'Data\Backups')
    }
    Invoke-TestCase 'reg_hardlink_observation' {
        $saved = Join-Path $approvedRoot 'RegHardLink'; New-BackupFixture $saved
        $file = Join-Path $saved "$($script:target.id).reg"; $outside = Join-Path $outsideRoot 'hardlinked.reg'
        [IO.File]::Copy($file, $outside); [IO.File]::Delete($file); New-TestLink $file $outside 'HardLink'
        $before = Get-OutsideSnapshot; $accepted = $false; $failure = ''
        try { $null = Read-ValidatedBackup $saved @($script:target) $approvedRoot; $accepted = $true } catch { $failure = $_.Exception.Message }
        $modified = $before -cne (Get-OutsideSnapshot)
        New-CaseResult 'reg_hardlink_observation' 'observe_only' $accepted $modified $null (-not $modified) $false $failure '' 'Hard-link support and behavior only; acceptance is not asserted.'
    }
    Invoke-TestCase 'changed_reg_after_validation' {
        Invoke-ChangedRegCase 'changed_reg_after_validation' $false
    }
    Invoke-TestCase 'changed_checksum_after_validation' {
        Set-TestMarker 'Allowed' 'original'; Set-TestMarker 'SiblingOutside' 'sentinel'
        $root = Join-Path $testRoot 'ChangedChecksum'; [void][IO.Directory]::CreateDirectory($root)
        $saved = New-BackupSet -Targets @($script:target) -Root $root -Kind 'ChangedChecksum'
        $validated = Read-ValidatedBackup $saved @($script:target) $root
        $checksum = Join-Path $saved 'manifest.sha256'
        $oldHash = [IO.File]::ReadAllText($checksum).Trim()
        $newHash = if ($oldHash -ceq ('0' * 64)) { '1' * 64 } else { '0' * 64 }
        [IO.File]::WriteAllText($checksum, $newHash, $Utf8NoBom)
        if ([IO.File]::ReadAllText($checksum).Trim() -ceq $oldHash) { throw 'Checksum mutation failed.' }
        $accepted = $false; $failure = ''
        try { $null = Apply-ValidatedBackupUnsafe $validated @($script:target); $accepted = $true } catch { $failure = $_.Exception.Message }
        $modified = (Get-TestMarker 'SiblingOutside') -cne 'sentinel'
        $allowedCorrect = -not $accepted -or (Get-TestMarker 'Allowed') -ceq 'original'
        $passed = -not $modified -and $allowedCorrect -and ($accepted -or (Test-ChangedContentRejection $failure)) -and $failure -notmatch 'TEST HARNESS'
        New-CaseResult 'changed_checksum_after_validation' 'safe_apply_or_reject' $accepted $modified $null $passed $false $failure '' 'Only the on-disk manifest checksum changes after validation.'
    }
    Invoke-TestCase 'coordinated_changes_after_validation' {
        Invoke-ChangedRegCase 'coordinated_changes_after_validation' $true
    }
} catch {
    $script:results.Add((New-CaseResult 'test_setup' 'complete_setup' $false $false $null $false $false $_.Exception.Message))
} finally {
    $env:TEMP = $previousTemp; $env:TMP = $previousTmp
    $cleanupErrors = New-Object 'System.Collections.Generic.List[string]'
    if ($pathsValidated) {
        foreach ($link in @($script:links.ToArray())) {
            try {
                if (-not (Test-TestPath $link.path)) { throw 'Link path validation failed.' }
                [ClaudePolicyPathTests.LinkCleanup]::Remove($link.path)
            } catch { $cleanupErrors.Add("Link $($link.path): $($_.Exception.Message)") }
        }
        try {
            if ($testId -notmatch '^[0-9a-f]{32}$' -or $registryRoot -cne "Software\ClaudePolicyToolTests\$testId") { throw 'Registry cleanup path validation failed.' }
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $regView)
            try {
                $parent = $base.OpenSubKey('Software\ClaudePolicyToolTests', $true)
                $removeParent = $false
                if ($null -ne $parent) {
                    try {
                        $parent.DeleteSubKeyTree($testId, $false)
                        $removeParent = $testParentCreated -and $parent.SubKeyCount -eq 0 -and $parent.ValueCount -eq 0
                    } finally { $parent.Dispose() }
                }
                if ($removeParent) {
                    $software = $base.OpenSubKey('Software', $true)
                    if ($null -eq $software) { throw 'Expected HKCU Software key is missing during cleanup.' }
                    try { $software.DeleteSubKey('ClaudePolicyToolTests', $false); $testParentRemoved = $true }
                    finally { $software.Dispose() }
                }
            } finally { $base.Dispose() }
        } catch { $cleanupErrors.Add("Registry: $($_.Exception.Message)") }
        try {
            $expected = [IO.Path]::GetFullPath((Join-Path $tempParent "ClaudePolicyBackupPaths-$testId"))
            if ($testId -notmatch '^[0-9a-f]{32}$' -or -not $testRoot.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { throw 'Directory cleanup path validation failed.' }
            if ([IO.Directory]::Exists($testRoot)) {
                if (([IO.File]::GetAttributes($testRoot) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Test root is a reparse point.' }
                $null = @(Get-SafeTree $testRoot)
                Remove-Item -LiteralPath $testRoot -Recurse
            }
        } catch { $cleanupErrors.Add("Directory: $($_.Exception.Message)") }
    }
    if ($cleanupErrors.Count -gt 0) { $script:results.Add((New-CaseResult 'cleanup' 'clean' $false $false $null $false $false ($cleanupErrors -join '; '))) }
}

foreach ($name in $caseNames) {
    if (@($script:results | Where-Object { $_.name -eq $name }).Count -eq 0) {
        $script:results.Add((New-CaseResult $name 'not_run' $null $false $null $false $false 'Test setup failed or case was not executed.'))
    }
}
$failed = @($script:results | Where-Object { -not $_.passed -and -not $_.skipped }).Count
$skipped = @($script:results | Where-Object { $_.skipped }).Count
$result = [pscustomobject]@{ toolPath = $ToolPath; testId = $testId; testParentCreated = $testParentCreated; testParentRemoved = $testParentRemoved
    failed = $failed; skipped = $skipped; cases = @($script:results.ToArray()) }
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath), ($result | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
Write-Host "Backup path tests: $failed failed, $skipped skipped. Results: $ResultPath"
if ($failed -gt 0) { exit 1 }
exit 0
