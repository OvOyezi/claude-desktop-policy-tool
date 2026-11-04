[CmdletBinding()]
param(
    [string]$ToolPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Claude-Policy-Tool.cmd'),
    [string]$ResultPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = New-Object Text.UTF8Encoding($false)
$utf8 = New-Object Text.UTF8Encoding($false)
$testId = [guid]::NewGuid().ToString('N')
$registryRoot = "Software\ClaudePolicyToolTests\$testId"
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = [IO.Path]::GetFullPath((Join-Path $tempParent "ClaudePolicyRestoreBoundary-$testId"))
if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    $ResultPath = Join-Path $tempParent "ClaudePolicyRestoreBoundary-$testId.json"
}
$ResultPath = [IO.Path]::GetFullPath($ResultPath)
$results = New-Object 'System.Collections.Generic.List[object]'
$pathsValidated = $false
$parentExisted = $false
$view = if ([Environment]::Is64BitOperatingSystem) { 64 } else { 32 }
$registryView = if ($view -eq 64) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Registry32 }

function Add-Result {
    param([string]$Name, [string]$Group, [string]$Outcome, [string]$Detail, [System.Collections.IDictionary]$Fields)
    $record = [ordered]@{ name = $Name; group = $Group; outcome = $Outcome; detail = $Detail }
    if ($null -ne $Fields) { foreach ($key in $Fields.Keys) { $record[$key] = $Fields[$key] } }
    $script:results.Add([pscustomobject]$record)
    Write-Host "[$Outcome] $Group / $Name $Detail"
}

function Assert-TestRoots {
    if ($testId -cnotmatch '^[0-9a-f]{32}$' -or $registryRoot -cne "Software\ClaudePolicyToolTests\$testId") {
        throw '隔离注册表根校验失败。'
    }
    $expected = [IO.Path]::GetFullPath((Join-Path $tempParent "ClaudePolicyRestoreBoundary-$testId"))
    if (-not $testRoot.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { throw '隔离临时目录校验失败。' }
}

function Assert-TestFile {
    param([string]$Path)
    Assert-TestRoots
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($testRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '测试文件不在隔离目录中。' }
}

function Get-TestRootKey {
    param([bool]$Create)
    Assert-TestRoots
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $registryView)
    try {
        # Windows creates the necessary parent container if it does not exist.
        if ($Create) { return $base.CreateSubKey($registryRoot) }
        return $base.OpenSubKey($registryRoot, $true)
    } finally { $base.Dispose() }
}

function Reset-TestKeys {
    $root = Get-TestRootKey $false
    if ($null -eq $root) { throw '隔离测试注册表根不存在。' }
    try {
        $root.DeleteSubKeyTree('Allowed', $false)
        foreach ($name in @('Outside', 'Outside]Suffix')) { $root.DeleteSubKeyTree($name, $false) }
        $allowed = $root.CreateSubKey('Allowed')
        try { $allowed.SetValue('Before', 'allowed', [Microsoft.Win32.RegistryValueKind]::String) } finally { $allowed.Dispose() }
        foreach ($name in @('Outside', 'Outside]Suffix')) {
            $outside = $root.CreateSubKey($name)
            try { $outside.SetValue('Marker', 'before', [Microsoft.Win32.RegistryValueKind]::String) } finally { $outside.Dispose() }
        }
    } finally { $root.Dispose() }
}

function Get-OutsideState {
    param([string]$Leaf)
    if ($Leaf -cnotin @('Outside', 'Outside]Suffix')) { throw '不允许的测试兄弟键。' }
    $root = Get-TestRootKey $false
    if ($null -eq $root) { throw '隔离测试注册表根不存在。' }
    try {
        $outside = $root.OpenSubKey($Leaf, $false)
        if ($null -eq $outside) { return [pscustomobject]@{ exists = $false; marker = $null } }
        try { return [pscustomobject]@{ exists = $true; marker = $outside.GetValue('Marker', $null) } } finally { $outside.Dispose() }
    } finally { $root.Dispose() }
}

function Invoke-NativeReg {
    param([string[]]$Arguments)
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $RegExe @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    return [pscustomobject]@{ exitCode = $code; output = ($output -join ' ') }
}

# The payload can call only an export of our single isolated target. Imports below
# are made explicitly, from fixtures we constructed or exports of that same key.
function Invoke-Reg {
    param([string[]]$Arguments, [switch]$AllowFailure)
    if ($Arguments.Count -ne 5 -or $Arguments[0] -cne 'export' -or
        $Arguments[1] -cne $script:target.regPath -or $Arguments[3] -cne '/y' -or
        $Arguments[4] -cne "/reg:$view") { throw 'TEST HARNESS: blocked unexpected registry command.' }
    Assert-TestFile $Arguments[2]
    $result = Invoke-NativeReg $Arguments
    if (-not $AllowFailure -and $result.exitCode -ne 0) { throw "注册表导出失败：$($result.output)" }
    return $result
}

function Invoke-TestImport {
    param([string]$FilePath)
    Assert-TestFile $FilePath
    Invoke-NativeReg @('import', $FilePath, "/reg:$view")
}

function Test-HarnessValueKind {
    param($Key, [string]$Name, [Microsoft.Win32.RegistryValueKind]$Kind)
    try { return ($Key.GetValueKind($Name) -eq $Kind) } catch { return $false }
}

try {
    # Parse only top-level functions; never execute the CMD bootstrap or entry point.
    $ToolPath = (Resolve-Path -LiteralPath $ToolPath).ProviderPath
    $payload = ((Get-Content -LiteralPath $ToolPath -Encoding UTF8 | Select-Object -Skip 12) -join "`n")
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($payload, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -ne 0) { throw ('无法解析 PowerShell payload：' + (($parseErrors | ForEach-Object { $_.Message }) -join '; ')) }
    $definitions = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })
    foreach ($name in @('New-Target', 'New-BackupSet', 'Assert-RegFileScope', 'Read-ValidatedBackup')) {
        if (@($definitions | Where-Object { $_.Name -eq $name }).Count -ne 1) { throw "工具缺少唯一的函数定义：$name" }
    }
    # Exclude Invoke-Reg so the test guard above remains in effect.
    . ([scriptblock]::Create((($definitions | Where-Object { $_.Name -ne 'Invoke-Reg' } | ForEach-Object { $_.Extent.Text }) -join "`n")))

    $ToolId = 'ClaudePolicyTool'
    $ToolVersion = 'restore-boundary-test'
    $SchemaVersion = 1
    $ScriptPath = $ToolPath
    $ScriptRoot = Split-Path -Parent $ToolPath
    $DataRoot = $testRoot
    $BackupRoot = Join-Path $testRoot 'Backups'
    $RegExe = Join-Path $env:SystemRoot 'System32\reg.exe'
    $Utf8NoBom = $utf8
    $ProductionTargets = @()
    Assert-TestRoots
    if (Test-Path -LiteralPath $testRoot) { throw '随机临时目录已存在，拒绝使用。' }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $registryView)
    try {
        $parent = $base.OpenSubKey('Software\ClaudePolicyToolTests', $false)
        $parentExisted = ($null -ne $parent)
        if ($parentExisted) { $parent.Dispose() }
        $existing = $base.OpenSubKey($registryRoot, $false)
        if ($null -ne $existing) { $existing.Dispose(); throw '随机注册表测试根已存在，拒绝使用。' }
    } finally { $base.Dispose() }
    $pathsValidated = $true
    [void](New-Item -ItemType Directory -Path $testRoot)
    $root = Get-TestRootKey $true
    if ($null -eq $root) { throw '无法创建隔离注册表根。' }
    $root.Dispose()
    $target = New-Target 'Allowed' 'HKCU' $view "HKCU\$registryRoot\Allowed" "HKEY_CURRENT_USER\$registryRoot\Allowed"
    $outside = "HKEY_CURRENT_USER\$registryRoot\Outside"

    $cases = @(
        @{ name = 'outside_standard'; header = "[$outside]"; newline = "`r`n"; delete = $false },
        @{ name = 'outside_leading_space'; header = " [$outside]"; newline = "`r`n"; delete = $false },
        @{ name = 'outside_leading_tab'; header = "`t[$outside]"; newline = "`r`n"; delete = $false },
        @{ name = 'outside_semicolon_comment'; header = "[$outside] ; comment"; newline = "`r`n"; delete = $false },
        @{ name = 'outside_semicolon_adjacent'; header = "[$outside];comment"; newline = "`r`n"; delete = $false },
        @{ name = 'outside_trailing_text'; header = "[$outside] extra"; newline = "`r`n"; delete = $false },
        @{ name = 'outside_header_bom'; header = "$([char]0xFEFF)[$outside]"; newline = "`r`n"; delete = $false },
        @{ name = 'outside_lf_only'; header = "[$outside]"; newline = "`n"; delete = $false },
        @{ name = 'outside_cr_only'; header = "[$outside]"; newline = "`r"; delete = $false },
        @{ name = 'outside_mixed_cr_before_header'; header = "[$outside]"; newline = "`r`n"; separator = "`r"; delete = $false },
        @{ name = 'outside_mixed_crlf_cr_before_header'; header = "[$outside]"; newline = "`r`n"; separator = "`r`n`r"; delete = $false },
        @{ name = 'outside_mixed_lf_cr_before_header'; header = "[$outside]"; newline = "`r`n"; separator = "`n`r"; delete = $false },
        @{ name = 'outside_after_hex_continuation'; header = "[$outside]"; newline = "`r`n"; separator = ("`r`n" + '"Data"=hex:00,\' + "`r`n"); delete = $false },
        @{ name = 'outside_after_hex_continuation_cr'; header = "[$outside]"; newline = "`r`n"; separator = ("`r`n" + '"Data"=hex:00,\' + "`r"); delete = $false },
        @{ name = 'outside_delete'; header = "[-$outside]"; newline = "`r`n"; delete = $true },
        @{ name = 'outside_delete_leading_space'; header = " [-$outside]"; newline = "`r`n"; delete = $true },
        @{ name = 'outside_delete_internal_space'; header = "[- $outside]"; newline = "`r`n"; delete = $true },
        @{ name = 'outside_delete_trailing_comment'; header = "[-$outside] ; comment"; newline = "`r`n"; delete = $true },
        @{ name = 'outside_repeated_slash'; header = "[HKEY_CURRENT_USER\$registryRoot\\Outside]"; newline = "`r`n"; delete = $false },
        @{ name = 'outside_closing_bracket'; header = "[${outside}]Suffix]"; newline = "`r`n"; delete = $false; leaf = 'Outside]Suffix' }
    )
    foreach ($case in $cases) {
        try {
            Reset-TestKeys
            $nl = $case.newline
            $separator = if ($case.ContainsKey('separator')) { $case.separator } else { $nl + $nl }
            $text = 'Windows Registry Editor Version 5.00' + $nl + $nl + "[$($target.fullRoot)]" + $nl + '"Control"="allowed"' + $separator + $case.header + $nl
            if (-not $case.delete) { $text += '"Marker"="after"' + $nl }
            $file = Join-Path $testRoot ($case.name + '.reg')
            Assert-TestFile $file
            [IO.File]::WriteAllText($file, $text, [Text.Encoding]::Unicode)
            $checkerAccepted = $false
            $checkerError = ''
            try { Assert-RegFileScope $file $target; $checkerAccepted = $true } catch { $checkerError = $_.Exception.Message }
            # Run even when the checker rejects, to determine what reg.exe actually does.
            $native = Invoke-TestImport $file
            $leaf = if ($case.ContainsKey('leaf')) { $case.leaf } else { 'Outside' }
            $state = Get-OutsideState $leaf
            $changed = (-not $state.exists -or $state.marker -cne 'before')
            $outcome = if ($checkerAccepted -and $changed) { 'fail' } elseif ($checkerAccepted) { 'unproven' } else { 'pass' }
            $detail = if ($checkerAccepted -and $changed) { '校验接受且隔离范围外的兄弟键发生变化。' } elseif ($checkerAccepted -and $native.exitCode -ne 0) { '原生命令拒绝；未证实越界。' } elseif ($checkerAccepted) { '原生命令未改变兄弟键；未证实越界。' } else { '范围校验已拒绝。' }
            Add-Result $case.name 'scope' $outcome $detail ([ordered]@{ checkerAccepted = $checkerAccepted; nativeExit = $native.exitCode; outsideChanged = $changed; nativeOutput = $native.output; checkerError = $checkerError })
        } catch { Add-Result $case.name 'scope' 'error' $_.Exception.Message $null }
    }

    # The production contract accepts exportable lines only. These inputs remain
    # entirely within Allowed even if reg.exe ignores or partially accepts them.
    $grammarCases = @(
        @{ name = 'unrecognized_line'; body = 'not a registry value' },
        @{ name = 'comment_line'; body = '; comment not generated by export' },
        @{ name = 'value_leading_space'; body = ' "Value"="data"' },
        @{ name = 'value_unterminated_string'; body = '"Value"="unterminated' },
        @{ name = 'value_trailing_comment'; body = '"Value"="data" ; comment' },
        @{ name = 'unsupported_value_type'; body = '"Value"=unknown:00' },
        @{ name = 'invalid_hex_digit'; body = '"Value"=hex:00,GG' },
        @{ name = 'invalid_dword'; body = '"Value"=dword:0000000z' },
        @{ name = 'delete_value'; body = '"Value"=-' },
        @{ name = 'dangling_hex_continuation'; body = '"Value"=hex:00,\' },
        @{ name = 'invalid_hex_continuation'; body = ('"Value"=hex:00,\' + "`r`n" + '  01,GG') },
        @{ name = 'malformed_key_header'; body = "[$($target.fullRoot)] extra" },
        @{ name = 'delete_allowed_key'; body = "[-$($target.fullRoot)\Child]" },
        @{ name = 'value_before_first_section'; before = '"Orphan"="data"'; body = '"Value"="data"' }
    )
    foreach ($case in $grammarCases) {
        try {
            Reset-TestKeys
            $text = "Windows Registry Editor Version 5.00`r`n`r`n"
            if ($case.ContainsKey('before')) { $text += $case.before + "`r`n" }
            $text += "[$($target.fullRoot)]`r`n" + $case.body + "`r`n"
            $file = Join-Path $testRoot ('grammar-' + $case.name + '.reg')
            Assert-TestFile $file
            [IO.File]::WriteAllText($file, $text, [Text.Encoding]::Unicode)
            $checkerAccepted = $false
            $checkerError = ''
            try { Assert-RegFileScope $file $target; $checkerAccepted = $true } catch { $checkerError = $_.Exception.Message }
            $native = Invoke-TestImport $file
            $outcome = if ($checkerAccepted) { 'fail' } else { 'pass' }
            $detail = if ($checkerAccepted) { '验证器接受了不受支持的行格式。' } else { '验证器拒绝了不受支持的行格式。' }
            Add-Result $case.name 'grammar' $outcome $detail ([ordered]@{ checkerAccepted = $checkerAccepted; nativeExit = $native.exitCode; nativeOutput = $native.output; checkerError = $checkerError })
        } catch { Add-Result $case.name 'grammar' 'error' $_.Exception.Message $null }
    }

    try {
        Reset-TestKeys
        $nl = "`r`n"
        $text = 'Windows Registry Editor Version 5.00' + $nl + $nl + "[$($target.fullRoot)]" + $nl + '"Hex"=hex:00,01,02,03,04,05,\' + $nl + '  06,07,08,ff' + $nl
        $file = Join-Path $testRoot 'valid-multiline-hex.reg'
        [IO.File]::WriteAllText($file, $text, [Text.Encoding]::Unicode)
        $checkerAccepted = $false
        $checkerError = ''
        try { Assert-RegFileScope $file $target; $checkerAccepted = $true } catch { $checkerError = $_.Exception.Message }
        $native = Invoke-TestImport $file
        $root = Get-TestRootKey $false
        try {
            $allowed = $root.OpenSubKey('Allowed', $false)
            try { $value = $allowed.GetValue('Hex', $null) } finally { $allowed.Dispose() }
        } finally { $root.Dispose() }
        $bytesMatch = $value -is [byte[]] -and [BitConverter]::ToString($value) -ceq '00-01-02-03-04-05-06-07-08-FF'
        $outcome = if ($native.exitCode -ne 0 -or -not $bytesMatch) { 'error' } elseif (-not $checkerAccepted) { 'fail' } else { 'pass' }
        Add-Result 'valid_multiline_hex' 'control' $outcome $checkerError ([ordered]@{ checkerAccepted = $checkerAccepted; nativeExit = $native.exitCode; bytesMatch = $bytesMatch; nativeOutput = $native.output })
    } catch { Add-Result 'valid_multiline_hex' 'control' 'error' $_.Exception.Message $null }

    try {
        Reset-TestKeys
        $root = Get-TestRootKey $false
        try {
            $child = $root.CreateSubKey('Allowed\Child]Suffix')
            try { $child.SetValue('BracketMarker', 'exported', [Microsoft.Win32.RegistryValueKind]::String) } finally { $child.Dispose() }
        } finally { $root.Dispose() }
        $file = Join-Path $testRoot 'actual-bracket-export.reg'
        $nativeExport = Invoke-NativeReg @('export', $target.regPath, $file, '/y', "/reg:$view")
        if ($nativeExport.exitCode -ne 0 -or -not (Test-Path -LiteralPath $file)) { throw "原生导出失败：$($nativeExport.output)" }
        $actualText = [IO.File]::ReadAllText($file)
        if (-not $actualText.Contains($target.fullRoot + '\Child]Suffix')) { throw '原生导出不包含预期的 ] 子键，无法验证样本。' }
        $checkerAccepted = $false
        $checkerError = ''
        try { Assert-RegFileScope $file $target; $checkerAccepted = $true } catch { $checkerError = $_.Exception.Message }
        $root = Get-TestRootKey $false
        try { $root.DeleteSubKeyTree('Allowed', $false) } finally { $root.Dispose() }
        $nativeImport = Invoke-TestImport $file
        $root = Get-TestRootKey $false
        try {
            $child = $root.OpenSubKey('Allowed\Child]Suffix', $false)
            try { $restored = ($null -ne $child -and $child.GetValue('BracketMarker', $null) -ceq 'exported') } finally { if ($null -ne $child) { $child.Dispose() } }
        } finally { $root.Dispose() }
        $outcome = if ($nativeImport.exitCode -ne 0 -or -not $restored) { 'error' } elseif (-not $checkerAccepted) { 'fail' } else { 'pass' }
        Add-Result 'native_export_import_bracket_key' 'control' $outcome $checkerError ([ordered]@{ checkerAccepted = $checkerAccepted; nativeExportExit = $nativeExport.exitCode; nativeExit = $nativeImport.exitCode; restored = $restored; nativeOutput = $nativeImport.output })
    } catch { Add-Result 'native_export_import_bracket_key' 'control' 'error' $_.Exception.Message $null }

    $allTypesExportText = $null
    try {
        # All strings, values and keys in this export are synthetic test data.
        Reset-TestKeys
        $expectedText = 'quoted "value", slash C:\Test\path\file 中文'
        $expectedName = 'Name"With\Slash'
        $expectedMulti = [string[]]@('one', 'two "quoted"', 'C:\Test\multi', '中文')
        $expectedExpand = '%TEMP%\ClaudePolicyToolTest\"quoted"'
        $expectedBinary = [byte[]]@((0..255) + (0..255))
        $expectedDword = [int]::MinValue
        $expectedQword = [long]987654321987654321
        $root = Get-TestRootKey $false
        try {
            $allowed = $root.OpenSubKey('Allowed', $true)
            try {
                $allowed.SetValue('', '', [Microsoft.Win32.RegistryValueKind]::String)
                $allowed.SetValue('EmptyString', '', [Microsoft.Win32.RegistryValueKind]::String)
                $allowed.SetValue('EmptyBinary', [byte[]]@(), [Microsoft.Win32.RegistryValueKind]::Binary)
                $allowed.SetValue('EmptyExpand', '', [Microsoft.Win32.RegistryValueKind]::ExpandString)
                $allowed.SetValue($expectedName, $expectedText, [Microsoft.Win32.RegistryValueKind]::String)
                $allowed.SetValue('MultiValue', $expectedMulti, [Microsoft.Win32.RegistryValueKind]::MultiString)
                $allowed.SetValue('ExpandValue', $expectedExpand, [Microsoft.Win32.RegistryValueKind]::ExpandString)
                $allowed.SetValue('LongBinary', $expectedBinary, [Microsoft.Win32.RegistryValueKind]::Binary)
                $allowed.SetValue('DwordValue', $expectedDword, [Microsoft.Win32.RegistryValueKind]::DWord)
                $allowed.SetValue('QwordValue', $expectedQword, [Microsoft.Win32.RegistryValueKind]::QWord)
            } finally { $allowed.Dispose() }
            $child = $root.CreateSubKey('Allowed\Part[Middle]Tail]')
            try { $child.SetValue('ChildMarker', 'brackets', [Microsoft.Win32.RegistryValueKind]::String) } finally { $child.Dispose() }
        } finally { $root.Dispose() }
        $file = Join-Path $testRoot 'actual-all-types-export.reg'
        $nativeExport = Invoke-NativeReg @('export', $target.regPath, $file, '/y', "/reg:$view")
        if ($nativeExport.exitCode -ne 0 -or -not (Test-Path -LiteralPath $file)) { throw "原生导出失败：$($nativeExport.output)" }
        $allTypesExportText = [IO.File]::ReadAllText($file)
        $hasContinuation = [regex]::IsMatch($allTypesExportText, '(?im)\\\r?\n[ \t]+[0-9a-f]{2}(?:,|$)')
        $checkerAccepted = $false
        $checkerError = ''
        try { Assert-RegFileScope $file $target; $checkerAccepted = $true } catch { $checkerError = $_.Exception.Message }
        $root = Get-TestRootKey $false
        try { $root.DeleteSubKeyTree('Allowed', $false) } finally { $root.Dispose() }
        $nativeImport = Invoke-TestImport $file
        $checks = [ordered]@{}
        $root = Get-TestRootKey $false
        try {
            $allowed = $root.OpenSubKey('Allowed', $false)
            $checks['allowedKey'] = ($null -ne $allowed)
            if ($null -ne $allowed) {
                try {
                    $raw = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                    $checks['emptyDefault'] = (Test-HarnessValueKind $allowed '' ([Microsoft.Win32.RegistryValueKind]::String)) -and ($allowed.GetValue('', $null, $raw) -ceq '')
                    $checks['emptyString'] = (Test-HarnessValueKind $allowed 'EmptyString' ([Microsoft.Win32.RegistryValueKind]::String)) -and ($allowed.GetValue('EmptyString', $null, $raw) -ceq '')
                    $emptyBinary = $allowed.GetValue('EmptyBinary', $null, $raw)
                    $checks['emptyBinary'] = (Test-HarnessValueKind $allowed 'EmptyBinary' ([Microsoft.Win32.RegistryValueKind]::Binary)) -and ($emptyBinary -is [byte[]]) -and ($emptyBinary.Length -eq 0)
                    $checks['emptyExpand'] = (Test-HarnessValueKind $allowed 'EmptyExpand' ([Microsoft.Win32.RegistryValueKind]::ExpandString)) -and ($allowed.GetValue('EmptyExpand', $null, $raw) -ceq '')
                    $checks['quotedNameAndString'] = (Test-HarnessValueKind $allowed $expectedName ([Microsoft.Win32.RegistryValueKind]::String)) -and ($allowed.GetValue($expectedName, $null, $raw) -ceq $expectedText)
                    $multi = $allowed.GetValue('MultiValue', $null, $raw)
                    $multiMatches = ($multi -is [string[]]) -and ($multi.Length -eq $expectedMulti.Length)
                    if ($multiMatches) { for ($i = 0; $i -lt $expectedMulti.Length; $i++) { if ($multi[$i] -cne $expectedMulti[$i]) { $multiMatches = $false } } }
                    $checks['multiString'] = (Test-HarnessValueKind $allowed 'MultiValue' ([Microsoft.Win32.RegistryValueKind]::MultiString)) -and $multiMatches
                    $checks['expandString'] = (Test-HarnessValueKind $allowed 'ExpandValue' ([Microsoft.Win32.RegistryValueKind]::ExpandString)) -and ($allowed.GetValue('ExpandValue', $null, $raw) -ceq $expectedExpand)
                    $binary = $allowed.GetValue('LongBinary', $null, $raw)
                    $checks['longBinary'] = (Test-HarnessValueKind $allowed 'LongBinary' ([Microsoft.Win32.RegistryValueKind]::Binary)) -and ($binary -is [byte[]]) -and ([BitConverter]::ToString($binary) -ceq [BitConverter]::ToString($expectedBinary))
                    $checks['dword'] = (Test-HarnessValueKind $allowed 'DwordValue' ([Microsoft.Win32.RegistryValueKind]::DWord)) -and ($allowed.GetValue('DwordValue', $null, $raw) -eq $expectedDword)
                    $checks['qword'] = (Test-HarnessValueKind $allowed 'QwordValue' ([Microsoft.Win32.RegistryValueKind]::QWord)) -and ($allowed.GetValue('QwordValue', $null, $raw) -eq $expectedQword)
                } finally { $allowed.Dispose() }
            }
            $child = $root.OpenSubKey('Allowed\Part[Middle]Tail]', $false)
            try { $checks['bracketKey'] = ($null -ne $child -and $child.GetValue('ChildMarker', $null) -ceq 'brackets') } finally { if ($null -ne $child) { $child.Dispose() } }
        } finally { $root.Dispose() }
        $missing = @($checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
        if (-not $hasContinuation) { $outcome = 'error'; $detail = '原生导出未生成预期的长十六进制续行。' }
        elseif ($nativeImport.exitCode -ne 0 -or $missing.Count -gt 0) { $outcome = 'native_limitation'; $detail = '原生导出再导入无法完整还原测试数据。' }
        elseif (-not $checkerAccepted) { $outcome = 'fail'; $detail = '拒绝了可原生完整往返的导出。' }
        else { $outcome = 'pass'; $detail = '' }
        Add-Result 'native_export_import_all_types' 'control' $outcome $detail ([ordered]@{ checkerAccepted = $checkerAccepted; checkerError = $checkerError; nativeExportExit = $nativeExport.exitCode; nativeExit = $nativeImport.exitCode; continuationPresent = $hasContinuation; valueChecks = $checks; missingChecks = $missing; nativeExportText = $allTypesExportText; nativeOutput = $nativeImport.output })
    } catch { Add-Result 'native_export_import_all_types' 'control' 'error' $_.Exception.Message ([ordered]@{ nativeExportText = $allTypesExportText }) }

    $multilineExportText = $null
    try {
        # A real export of an embedded CRLF can be lossy on native re-import.
        # Require rejection before any restore, and report the native behavior.
        Reset-TestKeys
        $expectedMultiline = "first line with `"quotes`" and C:\Test\path`r`nsecond line"
        $root = Get-TestRootKey $false
        try {
            $allowed = $root.OpenSubKey('Allowed', $true)
            try { $allowed.SetValue('Multiline', $expectedMultiline, [Microsoft.Win32.RegistryValueKind]::String) } finally { $allowed.Dispose() }
        } finally { $root.Dispose() }
        $file = Join-Path $testRoot 'actual-multiline-string-export.reg'
        $nativeExport = Invoke-NativeReg @('export', $target.regPath, $file, '/y', "/reg:$view")
        if ($nativeExport.exitCode -ne 0 -or -not (Test-Path -LiteralPath $file)) { throw "原生导出失败：$($nativeExport.output)" }
        $multilineExportText = [IO.File]::ReadAllText($file)
        $checkerAccepted = $false
        $checkerError = ''
        try { Assert-RegFileScope $file $target; $checkerAccepted = $true } catch { $checkerError = $_.Exception.Message }
        $root = Get-TestRootKey $false
        try { $root.DeleteSubKeyTree('Allowed', $false) } finally { $root.Dispose() }
        $nativeImport = Invoke-TestImport $file
        $actualMultiline = $null
        $kindMatches = $false
        $root = Get-TestRootKey $false
        try {
            $allowed = $root.OpenSubKey('Allowed', $false)
            if ($null -ne $allowed) {
                try {
                    $kindMatches = Test-HarnessValueKind $allowed 'Multiline' ([Microsoft.Win32.RegistryValueKind]::String)
                    $actualMultiline = $allowed.GetValue('Multiline', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                } finally { $allowed.Dispose() }
            }
        } finally { $root.Dispose() }
        $nativeRoundTrip = ($nativeImport.exitCode -eq 0 -and $kindMatches -and $actualMultiline -ceq $expectedMultiline)
        $outcome = if ($checkerAccepted) { 'fail' } else { 'pass' }
        $detail = if ($checkerAccepted) { '校验器接受了含原始 CRLF 的多行字符串导出。' } else { '校验器拒绝了含原始 CRLF 的多行字符串导出。' }
        Add-Result 'native_multiline_string' 'control' $outcome $detail ([ordered]@{ checkerAccepted = $checkerAccepted; checkerError = $checkerError; nativeExportExit = $nativeExport.exitCode; nativeExit = $nativeImport.exitCode; nativeRoundTrip = $nativeRoundTrip; expectedValue = $expectedMultiline; actualValue = $actualMultiline; actualKindMatches = $kindMatches; nativeExportText = $multilineExportText; nativeOutput = $nativeImport.output })
    } catch { Add-Result 'native_multiline_string' 'control' 'error' $_.Exception.Message ([ordered]@{ nativeExportText = $multilineExportText }) }

    # The baseline is made by the tool itself from the isolated target. Manifest
    # checksums are recomputed after each type mutation so only schema is tested.
    try {
        Reset-TestKeys
        $baseline = New-BackupSet -Targets @($target) -Root $BackupRoot -Kind 'Boundary'
        $null = Read-ValidatedBackup -Directory $baseline -ExpectedTargets @($target) -ApprovedRoot $BackupRoot
        Add-Result 'valid_backup' 'schema' 'pass' '' $null
        $schemaCases = @(
            @{ name = 'existed_null'; mutation = 'existed_null' },
            @{ name = 'existed_number_zero'; mutation = 'existed_zero' },
            @{ name = 'existed_string_false'; mutation = 'existed_false_string' },
            @{ name = 'existed_array'; mutation = 'existed_array' },
            @{ name = 'schema_version_string'; mutation = 'schema_string' },
            @{ name = 'schema_version_array'; mutation = 'schema_array' },
            @{ name = 'view_string'; mutation = 'view_string' },
            @{ name = 'view_fraction'; mutation = 'view_fraction' },
            @{ name = 'targets_object'; mutation = 'targets_object' },
            @{ name = 'targets_string'; mutation = 'targets_string' },
            @{ name = 'target_id_array'; mutation = 'id_array' },
            @{ name = 'target_hive_array'; mutation = 'hive_array' },
            @{ name = 'target_regpath_array'; mutation = 'regpath_array' },
            @{ name = 'target_fullroot_array'; mutation = 'fullroot_array' },
            @{ name = 'backupfile_array'; mutation = 'backupfile_array' },
            @{ name = 'sha_invalid_characters'; mutation = 'sha_chars' },
            @{ name = 'sha_wrong_length'; mutation = 'sha_short' },
            @{ name = 'sha_null'; mutation = 'sha_null' },
            @{ name = 'sha_array'; mutation = 'sha_array' }
        )
        foreach ($case in $schemaCases) {
            try {
                $directory = Join-Path $BackupRoot $case.name
                Copy-Item -LiteralPath $baseline -Destination $directory -Recurse
                $manifestPath = Join-Path $directory 'manifest.json'
                $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
                $entry = @($manifest.targets)[0]
                switch ($case.mutation) {
                    'existed_null' { $entry.existed = $null; $entry.backupFile = $null; $entry.sha256 = $null }
                    'existed_zero' { $entry.existed = 0; $entry.backupFile = $null; $entry.sha256 = $null }
                    'existed_false_string' { $entry.existed = 'false' }
                    'existed_array' { $entry.existed = @($true) }
                    'schema_string' { $manifest.schemaVersion = '1' }
                    'schema_array' { $manifest.schemaVersion = @(1) }
                    'view_string' { $entry.view = [string]$view }
                    'view_fraction' { $entry.view = $view - 0.4 }
                    'targets_object' { $manifest.targets = $entry }
                    'targets_string' { $manifest.targets = [string]$entry.id }
                    'id_array' { $entry.id = @([string]$entry.id) }
                    'hive_array' { $entry.hive = @([string]$entry.hive) }
                    'regpath_array' { $entry.regPath = @([string]$entry.regPath) }
                    'fullroot_array' { $entry.fullRoot = @([string]$entry.fullRoot) }
                    'backupfile_array' { $entry.backupFile = @([string]$entry.backupFile) }
                    'sha_chars' { $entry.sha256 = ('Z' * 64) }
                    'sha_short' { $entry.sha256 = ([string]$entry.sha256).Substring(0, 63) }
                    'sha_null' { $entry.sha256 = $null }
                    'sha_array' { $entry.sha256 = @([string]$entry.sha256) }
                }
                [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), $utf8)
                [IO.File]::WriteAllText((Join-Path $directory 'manifest.sha256'), (Get-Sha256 $manifestPath), $utf8)
                $accepted = $false
                $checkerError = ''
                try { $null = Read-ValidatedBackup -Directory $directory -ExpectedTargets @($target) -ApprovedRoot $BackupRoot; $accepted = $true } catch { $checkerError = $_.Exception.Message }
                $outcome = if ($accepted) { 'fail' } else { 'pass' }
                Add-Result $case.name 'schema' $outcome $checkerError ([ordered]@{ checkerAccepted = $accepted; manifestChecksumRecomputed = $true })
            } catch { Add-Result $case.name 'schema' 'error' $_.Exception.Message $null }
        }
    } catch { Add-Result 'valid_backup' 'schema' 'error' $_.Exception.Message $null }
} catch {
    Add-Result 'setup' 'harness' 'error' $_.Exception.Message $null
} finally {
    if ($pathsValidated) {
        try {
            Assert-TestRoots
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $registryView)
            try {
                $parent = $base.OpenSubKey('Software\ClaudePolicyToolTests', $true)
                if ($null -ne $parent) {
                    try { $parent.DeleteSubKeyTree($testId, $false) } finally { $parent.Dispose() }
                }
                $remaining = $base.OpenSubKey($registryRoot, $false)
                if ($null -ne $remaining) { $remaining.Dispose(); throw '隔离注册表根清理后仍然存在。' }
                # Remove a container we created only if it remains completely empty.
                if (-not $parentExisted) {
                    $parent = $base.OpenSubKey('Software\ClaudePolicyToolTests', $false)
                    $empty = $false
                    if ($null -ne $parent) {
                        try { $empty = ($parent.GetSubKeyNames().Count -eq 0 -and $parent.GetValueNames().Count -eq 0) } finally { $parent.Dispose() }
                    }
                    if ($empty) { $base.DeleteSubKey('Software\ClaudePolicyToolTests', $false) }
                }
            } finally { $base.Dispose() }
        } catch { Add-Result 'registry_cleanup' 'harness' 'error' $_.Exception.Message $null }
        try {
            Assert-TestRoots
            if (Test-Path -LiteralPath $testRoot) {
                $items = @((Get-Item -LiteralPath $testRoot)) + @(Get-ChildItem -LiteralPath $testRoot -Recurse)
                if (@($items | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) { throw '测试目录含重解析点，拒绝递归删除。' }
                Remove-Item -LiteralPath $testRoot -Recurse
            }
        } catch { Add-Result 'file_cleanup' 'harness' 'error' $_.Exception.Message $null }
    }
}

$fails = @($results | Where-Object { $_.outcome -eq 'fail' }).Count
$errors = @($results | Where-Object { $_.outcome -eq 'error' }).Count
$nativeLimitations = @($results | Where-Object { $_.outcome -eq 'native_limitation' }).Count
$exitCode = if ($errors -gt 0 -or $nativeLimitations -gt 0) { 2 } elseif ($fails -gt 0) { 1 } else { 0 }
$report = [ordered]@{
    toolPath = $ToolPath
    registryRoot = "HKCU\$registryRoot"
    registryView = $view
    passed = @($results | Where-Object { $_.outcome -eq 'pass' }).Count
    failed = $fails
    unproven = @($results | Where-Object { $_.outcome -eq 'unproven' }).Count
    nativeLimitations = $nativeLimitations
    errors = $errors
    exitCode = $exitCode
    results = @($results.ToArray())
}
try {
    $resultParent = Split-Path -Parent $ResultPath
    if (-not (Test-Path -LiteralPath $resultParent)) { [void](New-Item -ItemType Directory -Path $resultParent -Force) }
    [IO.File]::WriteAllText($ResultPath, ($report | ConvertTo-Json -Depth 10), $utf8)
    Write-Host "结果：$ResultPath；失败 $fails；未证实 $($report.unproven)；原生往返限制 $nativeLimitations；环境错误 $errors。"
} catch {
    Write-Error "无法写入测试结果：$($_.Exception.Message)" -ErrorAction Continue
    exit 2
}
exit $exitCode
