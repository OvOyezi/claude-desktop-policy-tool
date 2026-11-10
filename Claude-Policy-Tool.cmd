@echo off
setlocal EnableExtensions DisableDelayedExpansion
"%SystemRoot%\System32\chcp.com" 65001 >nul 2>&1
set "CPT_SELF=%~f0"
set "CPT_ACTION=%~1"
set "CPT_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%CPT_POWERSHELL%" (echo [无法启动] 未找到 Windows PowerShell 5.1。请在“启用或关闭 Windows 功能”中恢复 Windows PowerShell，或使用受支持的 Windows 10/11 系统。& set /p "CPT_DUMMY=按回车键退出……"& exit /b 10)
"%CPT_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ((Get-Content -Encoding UTF8 -LiteralPath $env:CPT_SELF | Select-Object -Skip 12) -join [Environment]::NewLine)"
set "CPT_RC=%ERRORLEVEL%"
endlocal & exit /b %CPT_RC%
### POWERSHELL PAYLOAD ###

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ToolId = 'ClaudePolicyTool'
$SchemaVersion = 1
$ToolVersion = '1.1.0'
$ScriptPath = [IO.Path]::GetFullPath($env:CPT_SELF)
$ScriptRoot = Split-Path -Parent $ScriptPath
$DataRoot = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    Join-Path $env:USERPROFILE 'AppData\Local\ClaudePolicyTool'
} else {
    Join-Path $env:LOCALAPPDATA 'ClaudePolicyTool'
}
$BackupRoot = Join-Path $DataRoot 'Backups'
$RegExe = Join-Path $env:SystemRoot 'System32\reg.exe'
$Action = [string]$env:CPT_ACTION
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = New-Object Text.UTF8Encoding($false)
$Host.UI.RawUI.WindowTitle = 'Claude Desktop 策略解锁与恢复工具'

function New-Target {
    param(
        [string]$Id,
        [string]$Hive,
        [int]$View,
        [string]$RegPath,
        [string]$FullRoot
    )
    [pscustomobject]@{
        id = $Id
        hive = $Hive
        view = $View
        regPath = $RegPath
        fullRoot = $FullRoot
    }
}

$ProductionTargets = @()
if ([Environment]::Is64BitOperatingSystem) {
    $ProductionTargets += New-Target 'HKLM64' 'HKLM' 64 'HKLM\SOFTWARE\Policies\Claude' 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Claude'
    $ProductionTargets += New-Target 'HKLM32' 'HKLM' 32 'HKLM\SOFTWARE\Policies\Claude' 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Claude'
    $ProductionTargets += New-Target 'HKCU64' 'HKCU' 64 'HKCU\SOFTWARE\Policies\Claude' 'HKEY_CURRENT_USER\SOFTWARE\Policies\Claude'
    $ProductionTargets += New-Target 'HKCU32' 'HKCU' 32 'HKCU\SOFTWARE\Policies\Claude' 'HKEY_CURRENT_USER\SOFTWARE\Policies\Claude'
} else {
    $ProductionTargets += New-Target 'HKLM32' 'HKLM' 32 'HKLM\SOFTWARE\Policies\Claude' 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Claude'
    $ProductionTargets += New-Target 'HKCU32' 'HKCU' 32 'HKCU\SOFTWARE\Policies\Claude' 'HKEY_CURRENT_USER\SOFTWARE\Policies\Claude'
}

function Write-Title {
    Clear-Host
    Write-Host "Claude Desktop 策略解锁与恢复工具  v$ToolVersion" -ForegroundColor Cyan
    Write-Host '============================================' -ForegroundColor Cyan
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "【$Title】" -ForegroundColor Cyan
}

function Pause-Console {
    [void](Read-Host '按回车键继续')
}

function Test-CommandAvailable {
    param([string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-ClaudeInstalled {
    try {
        if (Test-CommandAvailable 'Get-AppxPackage') {
            if (@(Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
        }
    } catch {}
    try {
        if (@(Get-Process -Name 'claude' -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
    } catch {}
    foreach ($path in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'AnthropicClaude'),
        (Join-Path $env:ProgramFiles 'Claude')
    )) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) { return $true }
    }
    return $false
}

function Test-LocalPolicyContainsClaude {
    $policyFiles = @(
        (Join-Path $env:WINDIR 'System32\GroupPolicy\Machine\Registry.pol'),
        (Join-Path $env:WINDIR 'System32\GroupPolicy\User\Registry.pol')
    )
    foreach ($path in $policyFiles) {
        try {
            if (Test-Path -LiteralPath $path) {
                $bytes = [IO.File]::ReadAllBytes($path)
                $unicode = [Text.Encoding]::Unicode.GetString($bytes)
                $ascii = [Text.Encoding]::ASCII.GetString($bytes)
                $pattern = '(?i)Software\\Policies\\Claude(?=\\|\x00|;|$)'
                if ($unicode -match $pattern -or $ascii -match $pattern) {
                    return $true
                }
            }
        } catch {}
    }
    return $false
}

function Get-CompatibilityReport {
    $errors = @()
    $warnings = @()
    $information = @()

    if ($env:OS -ne 'Windows_NT') {
        $errors += '本工具只能在 Windows 上运行。'
    }
    if ([Environment]::OSVersion.Version.Major -lt 10) {
        $errors += '系统版本低于 Windows 10。Claude Desktop 官方要求 Windows 10 或更高版本。'
    }
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        $errors += "Windows PowerShell 版本过低：$($PSVersionTable.PSVersion)。请安装或恢复 Windows PowerShell 5.1。"
    }
    if (-not (Test-Path -LiteralPath $RegExe)) {
        $errors += '未找到系统组件 reg.exe。请使用 DISM/SFC 修复 Windows 系统文件后再试。'
    }
    if (-not (Test-CommandAvailable 'ConvertFrom-Json') -or -not (Test-CommandAvailable 'ConvertTo-Json')) {
        $errors += '缺少 PowerShell JSON 组件。请恢复 Windows PowerShell 5.1 后再试。'
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -and [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $errors += '无法确定当前用户的数据目录，因而无法创建安全备份。'
    }
    try {
        foreach ($path in @($DataRoot, $BackupRoot)) {
            Assert-SafeBackupPath $path -AllowMissing
        }
    } catch {
        $errors += "备份路径检查失败，已拒绝写操作：$($_.Exception.Message)"
    }
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        $warnings += "PowerShell 当前处于 $($ExecutionContext.SessionState.LanguageMode) 模式，组织安全策略可能阻止部分操作。"
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        $warnings += '检测到 32 位 Windows，工具仅检查和处理 32 位注册表视图。此系统尚未经过本项目测试。'
    }
    if (-not (Test-ClaudeInstalled)) {
        $warnings += '未检测到 Claude Desktop 安装。仍可检查和处理注册表策略，请自行确认应用是否已安装。'
    }

    $information += "Windows：$([Environment]::OSVersion.VersionString)"
    $information += "进程架构：$($env:PROCESSOR_ARCHITECTURE)；64 位系统：$(if ([Environment]::Is64BitOperatingSystem) { '是' } else { '否' })"
    $information += "Windows PowerShell：$($PSVersionTable.PSVersion)"
    $information += "管理员权限：$(if (Test-Administrator) { '已获得' } else { '未获得，需要写入策略时会请求 UAC 授权' })"
    $information += "备份目录：$BackupRoot"

    [pscustomobject]@{
        errors = @($errors)
        warnings = @($warnings)
        information = @($information)
        ready = ($errors.Count -eq 0)
    }
}

function Show-CompatibilityReport {
    $report = Get-CompatibilityReport
    Write-Section '运行环境检查'
    $report.information | ForEach-Object { Write-Host "  - $_" }
    if ($report.warnings.Count -gt 0) {
        Write-Host ''
        Write-Host '需要注意：' -ForegroundColor Yellow
        $report.warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }
    if ($report.errors.Count -gt 0) {
        Write-Host ''
        Write-Host '无法安全执行写操作：' -ForegroundColor Red
        $report.errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    } else {
        Write-Host ''
        Write-Host '必要组件检查通过。' -ForegroundColor Green
    }
    $report
}

function Assert-CompatibleForWrite {
    $report = Get-CompatibilityReport
    if (-not $report.ready) {
        throw ("兼容性检查未通过，未修改注册表。请先解决以下问题：`n  - " + ($report.errors -join "`n  - "))
    }
    try {
        [void](New-Item -ItemType Directory -Path $BackupRoot -Force)
        Assert-SafeBackupPath $BackupRoot
        $probe = Join-Path $BackupRoot ('.write-test-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'test', $Utf8NoBom)
        Remove-Item -LiteralPath $probe -Force
    } catch {
        throw "无法写入备份目录，未修改注册表。请检查磁盘空间、文件夹权限或安全软件拦截：$BackupRoot。技术详情：$($_.Exception.Message)"
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-UserContext {
    param([string]$ExpectedSid)
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSid) -and
        $ExpectedSid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
        throw 'UAC 提权使用了另一个 Windows 账户。为避免修改错误账户的 HKCU 策略或使用错误的备份目录，操作已停止，未修改注册表。请由设备管理员在需要处理策略的账户上下文中操作。'
    }
}

function New-ElevationCommand {
    param([string]$Path, [ValidateSet('--unlock', '--restore')][string]$RequestedAction, [string]$ExpectedSid)
    $quotedPath = $Path.Replace("'", "''")
    $quotedSid = $ExpectedSid.Replace("'", "''")
    # Avoid cmd.exe CALL's second expansion of percent signs in the script path.
    $command = @"
`$env:CPT_SELF = '$quotedPath'
`$env:CPT_ACTION = '$RequestedAction'
`$env:CPT_EXPECTED_SID = '$quotedSid'
Invoke-Expression ((Get-Content -Encoding UTF8 -LiteralPath `$env:CPT_SELF | Select-Object -Skip 12) -join [Environment]::NewLine)
"@
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
}

function Ensure-Administrator {
    param([string]$RequestedAction)
    if (Test-Administrator) { return }

    Write-Host '此操作需要管理员权限，正在打开 Windows 用户账户控制确认窗口……' -ForegroundColor Yellow
    try {
        $encoded = New-ElevationCommand $ScriptPath $RequestedAction ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $powershell -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" -WorkingDirectory $ScriptRoot -Verb RunAs | Out-Null
    } catch {
        throw "管理员权限请求被取消或执行失败：$($_.Exception.Message)"
    }
    exit 0
}

function Invoke-Reg {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure
    )
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $RegExe @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "注册表命令执行失败（退出代码 $exitCode）：$($output -join ' ')"
    }
    [pscustomobject]@{ exitCode = $exitCode; output = $output }
}

function Initialize-RegistryReader {
    if ('ClaudePolicyTool.RegistryReader' -as [type]) { return }
    # Keep the Win32 status: reg.exe collapses failures to 1 and OpenSubKey
    # can return null for errors other than a missing key.
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ClaudePolicyTool {
    public static class RegistryReader {
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern int RegOpenKeyExW(IntPtr root, string path, int options, int access, out IntPtr key);
        [DllImport("advapi32.dll", ExactSpelling = true)]
        private static extern int RegCloseKey(IntPtr key);
        public static int Probe(bool machine, string path, int view) {
            IntPtr root = new IntPtr(machine ? unchecked((int)0x80000002) : unchecked((int)0x80000001));
            IntPtr key = IntPtr.Zero;
            try {
                // KEY_READ plus an explicit WOW64 view. No values are read.
                return RegOpenKeyExW(root, path, 0, 0x20019 | (view == 64 ? 0x0100 : 0x0200), out key);
            } finally {
                if (key != IntPtr.Zero) RegCloseKey(key);
            }
        }
    }
}
'@
}

function Test-TargetExists {
    param($Target)
    try {
        if ($Target.hive -notin @('HKLM', 'HKCU')) { throw '不支持的注册表根。' }
        if ($Target.view -notin @(32, 64)) { throw '不支持的注册表视图。' }
        $prefix = $Target.hive + '\'
        if (-not $Target.regPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            $Target.regPath.Length -le $prefix.Length) {
            throw '注册表路径与目标根不一致。'
        }
        Initialize-RegistryReader
        $code = [ClaudePolicyTool.RegistryReader]::Probe(($Target.hive -eq 'HKLM'), $Target.regPath.Substring($prefix.Length), $Target.view)
        switch ($code) {
            0 { return $true }
            2 { return $false } # ERROR_FILE_NOT_FOUND
            3 { return $false } # ERROR_PATH_NOT_FOUND
            default { throw (New-Object ComponentModel.Win32Exception($code)) }
        }
    } catch {
        throw "无法读取策略目标 $($Target.id)（$($Target.regPath)，$($Target.view) 位），不能判断为未发现策略。请检查注册表读取权限或联系设备管理员。技术详情：$($_.Exception.Message)"
    }
}

function Export-Target {
    param($Target, [string]$FilePath)
    Invoke-Reg -Arguments @('export', $Target.regPath, $FilePath, '/y', "/reg:$($Target.view)") | Out-Null
    if (-not (Test-Path -LiteralPath $FilePath) -or (Get-Item -LiteralPath $FilePath).Length -eq 0) {
        throw "注册表备份文件不存在或内容为空：$FilePath"
    }
}

function Remove-AllTargets {
    param([object[]]$Targets)
    foreach ($target in $Targets) {
        if (Test-TargetExists $target) {
            $result = Invoke-Reg -Arguments @('delete', $target.regPath, '/f', "/reg:$($target.view)") -AllowFailure
            if ($result.exitCode -ne 0 -and (Test-TargetExists $target)) {
                throw "无法删除策略目标 $($target.id)：$($result.output -join ' ')"
            }
        }
    }
    foreach ($target in $Targets) {
        if (Test-TargetExists $target) {
            throw "删除后策略目标仍然存在：$($target.id)"
        }
    }
}

function Import-Target {
    param($Target, [string]$FilePath)
    Invoke-Reg -Arguments @('import', $FilePath, "/reg:$($Target.view)") | Out-Null
}

function Get-Sha256 {
    param([string]$FilePath)
    $stream = [IO.File]::OpenRead($FilePath)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash($stream)
        ([BitConverter]::ToString($bytes)).Replace('-', '').ToUpperInvariant()
    } finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Write-TextUtf8 {
    param([string]$FilePath, [string]$Text)
    [IO.File]::WriteAllText($FilePath, $Text, $Utf8NoBom)
}

function Get-BytesSha256 {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Assert-SafeBackupPath {
    param([string]$Path, [switch]$AllowMissing)
    # Check every existing component, including ancestors and dangling links.
    # Resolve-Path alone is lexical and does not resolve NTFS junction targets.
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(3).Contains(':')) {
        throw "备份路径必须是本地磁盘上的普通路径：$Path"
    }
    $current = [IO.Path]::GetPathRoot($full)
    foreach ($part in @('') + @($full.Substring($current.Length).TrimEnd('\').Split('\'))) {
        if ($part.Length -gt 0) {
            if ($part.EndsWith('.') -or $part.EndsWith(' ')) { throw "备份路径包含不明确的目录名：$Path" }
            $current = Join-Path $current $part
        }
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch {
            $cause = $_.Exception.GetBaseException()
            if ($AllowMissing -and ($cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException])) { return }
            throw "无法检查备份路径属性：$current。$($cause.Message)"
        }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "备份路径包含符号链接、目录联接或其他重解析点：$current"
        }
    }
}

function Remove-SafeScratchDirectory {
    param([string]$Directory)
    Assert-SafeBackupPath $Directory
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Directory)
    while ($pending.Count -gt 0) {
        foreach ($path in [IO.Directory]::GetFileSystemEntries($pending.Pop())) {
            $attributes = [IO.File]::GetAttributes($path)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "拒绝清理包含重解析点的临时目录：$path" }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($path) }
        }
    }
    Remove-Item -LiteralPath $Directory -Recurse
}

function New-BackupSet {
    param(
        [object[]]$Targets,
        [string]$Root,
        [string]$Kind
    )
    Assert-SafeBackupPath $Root -AllowMissing
    [void](New-Item -ItemType Directory -Path $Root -Force)
    Assert-SafeBackupPath $Root
    $safeKind = $Kind -replace '[^A-Za-z0-9_-]', '_'
    $name = '{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $safeKind, ([guid]::NewGuid().ToString('N').Substring(0,8))
    $directory = Join-Path $Root $name
    [void](New-Item -ItemType Directory -Path $directory)
    Assert-SafeBackupPath $directory

    $entries = @()
    try {
        foreach ($target in $Targets) {
            $exists = Test-TargetExists $target
            $fileName = $null
            $hash = $null
            if ($exists) {
                $fileName = "$($target.id).reg"
                $filePath = Join-Path $directory $fileName
                Export-Target $target $filePath
                $hash = Get-Sha256 $filePath
            }
            $entries += [ordered]@{
                id = $target.id
                hive = $target.hive
                view = $target.view
                regPath = $target.regPath
                fullRoot = $target.fullRoot
                existed = [bool]$exists
                backupFile = $fileName
                sha256 = $hash
            }
        }

        $manifest = [ordered]@{
            toolId = $ToolId
            toolVersion = $ToolVersion
            schemaVersion = $SchemaVersion
            kind = $Kind
            createdUtc = [DateTime]::UtcNow.ToString('o')
            computerName = $env:COMPUTERNAME
            userName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            windowsVersion = [Environment]::OSVersion.VersionString
            osArchitecture = $env:PROCESSOR_ARCHITECTURE
            is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem
            mayContainSensitivePolicyData = $true
            scriptSha256 = Get-Sha256 $ScriptPath
            targets = @($entries)
        }
        $manifestPath = Join-Path $directory 'manifest.json'
        Write-TextUtf8 $manifestPath ($manifest | ConvertTo-Json -Depth 8)
        Write-TextUtf8 (Join-Path $directory 'manifest.sha256') (Get-Sha256 $manifestPath)
        return $directory
    } catch {
        try { Remove-SafeScratchDirectory $directory } catch { Write-Warning "未能清理失败的备份目录：$directory。$($_.Exception.Message)" }
        throw
    }
}

function Assert-DirectoryInsideRoot {
    param([string]$Directory, [string]$Root)
    Assert-SafeBackupPath $Root
    Assert-SafeBackupPath $Directory
    $resolvedDirectory = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Directory).Path).TrimEnd('\')
    $resolvedRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path).TrimEnd('\')
    if (-not $resolvedDirectory.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw '备份目录不在本工具允许的备份根目录中。'
    }
}

function Assert-RegFileScope {
    param([string]$FilePath, $Target, [byte[]]$Bytes)
    if ($null -eq $Bytes) { $Bytes = [IO.File]::ReadAllBytes($FilePath) }
    # reg.exe export writes UTF-16LE with a BOM. Parse every line of that format;
    # never ignore a line just because a section-header regex did not match it.
    if ($Bytes.Length -lt 2 -or $Bytes[0] -ne 255 -or $Bytes[1] -ne 254 -or $Bytes.Length % 2 -ne 0) {
        throw '备份注册表文件不是 reg.exe 导出的 UTF-16LE 格式。'
    }
    $encoding = New-Object Text.UnicodeEncoding($false, $true, $true)
    $text = $encoding.GetString($Bytes, 2, $Bytes.Length - 2)
    if ($text.Contains([string][char]0)) { throw '备份注册表文件包含无效的空字符。' }
    $lines = [regex]::Split($text, '\r\n|\n|\r')
    if ($lines[0] -cne 'Windows Registry Editor Version 5.00') { throw '备份注册表文件头无效。' }
    $sections = 0
    $continuation = $false
    $quoted = '"(?:[^"\\]|\\["\\])*"'
    for ($index = 1; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($continuation) {
            if ($line -notmatch '^  (?:[0-9a-fA-F]{2},)*[0-9a-fA-F]{2}(?:,\\)?$') { throw "备份注册表文件的十六进制续行无效（行 $($index + 1)）。" }
            $continuation = $line.EndsWith('\')
            continue
        }
        if ($line.Length -eq 0) { continue }
        # Use the final closing bracket: ']' is legal inside a registry key name.
        $section = [regex]::Match($line, '^\[(.+)\]$')
        if ($section.Success) {
            $key = $section.Groups[1].Value
            if ($key.StartsWith('-')) { throw '备份文件中不允许包含注册表删除指令。' }
            if (-not ($key.Equals($Target.fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
                $key.StartsWith($Target.fullRoot + '\', [StringComparison]::OrdinalIgnoreCase))) {
                throw "备份中发现超出允许范围的注册表键：$key"
            }
            $sections++
            continue
        }
        if ($sections -eq 0) { throw '备份注册表值出现在注册表键之前。' }
        $value = [regex]::Match($line, ('^(?:@|' + $quoted + ')=(.*)$'))
        if (-not $value.Success) { throw "备份注册表文件包含不支持或不安全的内容（行 $($index + 1)）。" }
        $data = $value.Groups[1].Value
        if ($data -cmatch ('^' + $quoted + '$') -or $data -match '^dword:[0-9a-fA-F]{8}$') { continue }
        $hex = [regex]::Match($data, '^hex(?:\([0-9a-fA-F]+\))?:(.*)$')
        if (-not $hex.Success -or $hex.Groups[1].Value -notmatch '^(?:(?:[0-9a-fA-F]{2},)*[0-9a-fA-F]{2}(?:,\\)?)?$') {
            throw "备份注册表值的格式无效（行 $($index + 1)）。"
        }
        $continuation = $data.EndsWith('\')
    }
    if ($sections -eq 0 -or $continuation) { throw '备份注册表文件缺少键或续行不完整。' }
}

function Read-ValidatedBackup {
    param(
        [string]$Directory,
        [object[]]$ExpectedTargets,
        [string]$ApprovedRoot
    )
    if (-not (Test-Path -LiteralPath $ApprovedRoot)) {
        throw "备份根目录不存在：$ApprovedRoot"
    }
    Assert-DirectoryInsideRoot $Directory $ApprovedRoot

    $manifestPath = Join-Path $Directory 'manifest.json'
    $checksumPath = Join-Path $Directory 'manifest.sha256'
    Assert-SafeBackupPath $manifestPath
    Assert-SafeBackupPath $checksumPath
    if (-not (Test-Path -LiteralPath $manifestPath) -or -not (Test-Path -LiteralPath $checksumPath)) {
        throw '备份清单或校验文件缺失。'
    }
    $expectedManifestHash = ([IO.File]::ReadAllText($checksumPath)).Trim().ToUpperInvariant()
    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    if ($expectedManifestHash -notmatch '^[0-9A-F]{64}$' -or (Get-BytesSha256 $manifestBytes) -ne $expectedManifestHash) {
        throw '备份清单的完整性校验失败。'
    }

    $manifest = ([Text.Encoding]::UTF8.GetString($manifestBytes)).TrimStart([char]0xFEFF) | ConvertFrom-Json
    if ($manifest.toolId -isnot [string] -or $manifest.toolId -cne $ToolId -or
        ($manifest.schemaVersion -isnot [int] -and $manifest.schemaVersion -isnot [long]) -or $manifest.schemaVersion -ne $SchemaVersion) {
        throw '此备份不是由本工具的兼容版本生成，已拒绝恢复。'
    }

    if ($manifest.targets -isnot [array]) { throw '备份目标列表必须是 JSON 数组。' }
    $entries = @($manifest.targets)
    if ($entries.Count -ne $ExpectedTargets.Count) {
        throw '备份目标数量与允许的目标列表不一致。'
    }

    $snapshots = @{}
    foreach ($target in $ExpectedTargets) {
        $matching = @($entries | Where-Object { $_.id -eq $target.id })
        if ($matching.Count -ne 1) {
            throw "备份目标缺失或重复：$($target.id)"
        }
        $entry = $matching[0]
        if ($entry.id -isnot [string] -or $entry.hive -isnot [string] -or $entry.hive -cne $target.hive -or
            ($entry.view -isnot [int] -and $entry.view -isnot [long]) -or $entry.view -ne $target.view -or
            $entry.regPath -isnot [string] -or $entry.regPath -ine $target.regPath -or
            $entry.fullRoot -isnot [string] -or $entry.fullRoot -ine $target.fullRoot -or $entry.existed -isnot [bool]) {
            throw "备份目标元数据与允许的目标不一致：$($target.id)"
        }
        if ($entry.existed) {
            $expectedName = "$($target.id).reg"
            if ($entry.backupFile -isnot [string] -or $entry.backupFile -cne $expectedName -or
                $entry.sha256 -isnot [string] -or $entry.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
                throw "备份文件元数据无效：$($target.id)"
            }
            $filePath = Join-Path $Directory $expectedName
            Assert-SafeBackupPath $filePath
            if (-not (Test-Path -LiteralPath $filePath)) {
                throw "备份文件缺失：$expectedName"
            }
            $bytes = [IO.File]::ReadAllBytes($filePath)
            if ((Get-BytesSha256 $bytes) -ne $entry.sha256.ToUpperInvariant()) {
                throw "备份文件完整性校验失败：$expectedName"
            }
            Assert-RegFileScope $filePath $target -Bytes $bytes
            $snapshots[$target.id] = $bytes
        } else {
            if ($null -ne $entry.backupFile -or $null -ne $entry.sha256) {
                throw "原本不存在的目标包含异常备份元数据：$($target.id)"
            }
        }
    }

    [pscustomobject]@{
        directory = [IO.Path]::GetFullPath($Directory)
        manifest = $manifest
        snapshots = $snapshots
    }
}

function Get-ManifestEntry {
    param($ValidatedBackup, $Target)
    @($ValidatedBackup.manifest.targets | Where-Object { $_.id -eq $Target.id })[0]
}

function Assert-StateMatchesBackup {
    param($ValidatedBackup, [object[]]$Targets)
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ClaudePolicyVerify-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tempRoot)
    try {
        foreach ($target in $Targets) {
            $entry = Get-ManifestEntry $ValidatedBackup $target
            $exists = Test-TargetExists $target
            if ([bool]$entry.existed -ne $exists) {
                throw "恢复后的存在状态与备份不一致：$($target.id)"
            }
            if ($exists) {
                $verifyFile = Join-Path $tempRoot "$($target.id).reg"
                Export-Target $target $verifyFile
                if ((Get-Sha256 $verifyFile) -ne ([string]$entry.sha256).ToUpperInvariant()) {
                    throw "恢复后的注册表内容与备份不完全一致：$($target.id)"
                }
            }
        }
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Apply-ValidatedBackupUnsafe {
    param($ValidatedBackup, [object[]]$Targets)
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('ClaudePolicyImport-' + [guid]::NewGuid().ToString('N'))
    Assert-SafeBackupPath $stage -AllowMissing
    [void](New-Item -ItemType Directory -Path $stage)
    $leases = New-Object 'System.Collections.Generic.List[System.IO.FileStream]'
    try {
        # Prepare all imports before deleting anything. Import only the bytes that
        # passed both the hash and scope checks, never reopen the mutable source.
        foreach ($target in $Targets) {
            $entry = Get-ManifestEntry $ValidatedBackup $target
            if ($entry.existed) {
                [byte[]]$bytes = $ValidatedBackup.snapshots[$target.id]
                if ((Get-BytesSha256 $bytes) -ne $entry.sha256.ToUpperInvariant()) { throw '备份快照完整性校验失败。' }
                $file = Join-Path $stage $entry.backupFile
                Assert-RegFileScope $file $target -Bytes $bytes
                [IO.File]::WriteAllBytes($file, $bytes)
                $leases.Add([IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
                if ((Get-Sha256 $file) -ne $entry.sha256.ToUpperInvariant()) { throw '导入暂存文件完整性校验失败。' }
            }
        }
        Remove-AllTargets $Targets
        foreach ($target in $Targets) {
            $entry = Get-ManifestEntry $ValidatedBackup $target
            if ($entry.existed) { Import-Target $target (Join-Path $stage $entry.backupFile) }
        }
        Assert-StateMatchesBackup $ValidatedBackup $Targets
    } finally {
        foreach ($lease in $leases) { $lease.Dispose() }
        Remove-SafeScratchDirectory $stage
    }
}

function Restore-BackupTransaction {
    param(
        [string]$Directory,
        [object[]]$Targets,
        [string]$Root,
        $ValidatedBackup = $null
    )
    $requested = if ($null -eq $ValidatedBackup) { Read-ValidatedBackup $Directory $Targets $Root } else { $ValidatedBackup }
    $rollbackDirectory = New-BackupSet $Targets $Root 'BeforeRestore'
    $rollback = Read-ValidatedBackup $rollbackDirectory $Targets $Root
    try {
        Apply-ValidatedBackupUnsafe $requested $Targets
        [pscustomobject]@{ rollbackDirectory = $rollbackDirectory; restoredDirectory = $requested.directory }
    } catch {
        $originalError = $_.Exception.Message
        try {
            Apply-ValidatedBackupUnsafe $rollback $Targets
        } catch {
            throw "严重错误：恢复失败，并且自动回滚也失败。恢复错误：$originalError；回滚错误：$($_.Exception.Message)；安全备份位置：$rollbackDirectory"
        }
        throw "恢复失败，但已成功自动还原到恢复前状态。错误详情：$originalError"
    }
}

function Get-ManagementState {
    $signals = @()
    try {
        if (Test-CommandAvailable 'Get-CimInstance') {
            $computer = Get-CimInstance Win32_ComputerSystem
            if ($computer.PartOfDomain) { $signals += "已加入域：$($computer.Domain)" }
        }
    } catch {}
    try {
        if (Test-CommandAvailable 'dsregcmd.exe') {
            $status = @(& dsregcmd.exe /status 2>$null)
            foreach ($name in @('AzureAdJoined', 'EnterpriseJoined', 'WorkplaceJoined')) {
                $line = @($status | Where-Object { $_ -match "^\s*$name\s*:\s*YES\s*$" })
                if ($line.Count -gt 0) {
                    $displayName = switch ($name) {
                        'AzureAdJoined' { '已加入 Microsoft Entra ID' }
                        'EnterpriseJoined' { '已加入企业设备管理' }
                        'WorkplaceJoined' { '已连接工作或学校账户' }
                    }
                    $signals += $displayName
                }
            }
            $mdm = @($status | Where-Object { $_ -match '^\s*MdmUrl\s*:\s*\S+' })
            if ($mdm.Count -gt 0) { $signals += '已配置 MDM 设备管理注册地址' }
        }
    } catch {}
    if (Test-LocalPolicyContainsClaude) {
        $signals += '本地组策略 Registry.pol 中包含 Claude 策略，刷新组策略或重启后可能恢复'
    }
    @($signals)
}

function Get-ClaudeConfigRoots {
    @(
        (Join-Path $env:LOCALAPPDATA 'Claude-3p'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p'),
        (Join-Path $env:APPDATA 'Claude-3p'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude-3p')
    ) | Select-Object -Unique
}

function Read-ConfigJson {
    param([byte[]]$Bytes)
    try {
        $text = [Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xFEFF)
        if (-not $text.TrimStart().StartsWith('{')) { throw 'Expected an object.' }
        $value = $text | ConvertFrom-Json
        if ($null -eq $value -or $value -isnot [pscustomobject]) { throw 'Expected an object.' }
        return $value
    } catch { throw '配置不是有效的 JSON 对象。原文件未修改。' }
}

function Get-ConfigProperty {
    param($Object, [string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
}

function Get-ClaudeLocalConfigs {
    foreach ($root in @(Get-ClaudeConfigRoots)) {
        $library = Join-Path $root 'configLibrary'
        $metaPath = Join-Path $library '_meta.json'
        if (-not (Test-Path -LiteralPath $metaPath)) { continue }
        Assert-SafeBackupPath $metaPath
        $metaBytes = [IO.File]::ReadAllBytes($metaPath)
        $meta = Read-ConfigJson $metaBytes
        $id = [string](Get-ConfigProperty $meta 'appliedId')
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $guid = [guid]::Empty
        if (-not [guid]::TryParseExact($id, 'D', [ref]$guid)) { throw "本地配置的已应用编号无效：$metaPath" }
        $path = Join-Path $library ($id + '.json')
        Assert-SafeBackupPath $path
        $bytes = [IO.File]::ReadAllBytes($path)
        $data = Read-ConfigJson $bytes
        $url = Get-ConfigProperty $data 'bootstrapUrl'
        $enabled = Get-ConfigProperty $data 'bootstrapEnabled'
        $active = $url -is [string] -and -not [string]::IsNullOrWhiteSpace($url) -and -not ($enabled -is [bool] -and -not $enabled)
        [pscustomobject]@{
            root = $root; id = $id; path = $path; metaPath = $metaPath
            metaHash = (Get-BytesSha256 $metaBytes); hash = (Get-BytesSha256 $bytes)
            bytes = $bytes; data = $data; bootstrapActive = $active
        }
    }
}

function Get-ClaudeDesktopRuntime {
    $locations = @()
    $launchers = @{}
    $launch = $null
    if (Test-CommandAvailable 'Get-AppxPackage') {
        foreach ($package in @(Get-AppxPackage -Name 'Claude' -ErrorAction Stop)) {
            $manifest = Get-AppxPackageManifest -Package $package.PackageFullName -ErrorAction Stop
            foreach ($application in @($manifest.Package.Applications.Application)) {
                if ([string]$application.Executable -notmatch '(?i)(^|\\)claude\.exe$') { continue }
                $path = Join-Path $package.InstallLocation ([string]$application.Executable)
                $locations += $path
                $launchers[$path] = [pscustomobject]@{ file = (Join-Path $env:WINDIR 'explorer.exe'); argument = ('shell:AppsFolder\' + $package.PackageFamilyName + '!' + $application.Id) }
                if ($null -eq $launch) {
                    $launch = $launchers[$path]
                }
            }
        }
    }
    $legacy = Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe'
    if ([IO.File]::Exists($legacy)) {
        $locations += $legacy
        if ($null -eq $launch) { $launch = [pscustomobject]@{ file = $legacy; argument = '' } }
    }
    $squirrelRoot = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
    if ([IO.Directory]::Exists($squirrelRoot)) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $squirrelRoot -Directory -Filter 'app-*' | Sort-Object LastWriteTime -Descending)) {
            $path = Join-Path $directory.FullName 'Claude.exe'
            if (-not [IO.File]::Exists($path)) { continue }
            $locations += $path
            if ($null -eq $launch) { $launch = [pscustomobject]@{ file = $path; argument = '' } }
        }
    }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $processes = @()
    $otherUsers = @()
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'claude.exe'" -ErrorAction Stop)) {
        # Claude Code also uses claude.exe. Only the installed Desktop executable is eligible.
        $path = [string]$process.ExecutablePath
        $isPackage = $false
        foreach ($programs in @($env:ProgramFiles, $env:ProgramW6432) | Select-Object -Unique) {
            if ([string]::IsNullOrWhiteSpace($programs)) { continue }
            $pattern = '^' + [regex]::Escape((Join-Path $programs 'WindowsApps\Claude_')) + '[0-9.]+_(x64|x86|arm64)__pzs8sxrjxfjjc\\(?:app\\)?claude\.exe$'
            if ($path -imatch $pattern) { $isPackage = $true }
        }
        # An elevated tool may not have the running user's MSIX registration.
        # Recognize the Desktop installation layout before comparing its owner.
        $isLegacy = $path -imatch '^[a-z]:\\.+\\AppData\\Local\\(?:Programs\\Claude\\Claude\.exe|AnthropicClaude\\app-[^\\]+\\Claude\.exe)$'
        if ($path -notin $locations -and -not $isPackage -and -not $isLegacy) { continue }
        $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop
        if ($owner.ReturnValue -ne 0) { throw '无法确认 Claude Desktop 的运行账户，请从运行 Claude 的 Windows 账户启动本工具。' }
        if ($owner.Sid -ne $sid) { $otherUsers += [string]$owner.Sid; continue }
        if ($process.SessionId -eq $session) {
            $processes += $process
            if (-not $isPackage -and -not $launchers.ContainsKey($path)) { $launchers[$path] = [pscustomobject]@{ file = $path; argument = '' } }
        }
    }
    $runningPaths = @($processes | ForEach-Object { [string]$_.ExecutablePath } | Select-Object -Unique)
    if ($runningPaths.Count -eq 1) { $launch = $launchers[$runningPaths[0]] }
    elseif ($runningPaths.Count -gt 1) { throw '检测到多个版本的 Claude Desktop 正在运行，请先退出多余版本。' }
    [pscustomobject]@{ processes = @($processes); otherUsers = @($otherUsers | Select-Object -Unique); launch = $launch }
}

function Assert-ClaudeDesktopAccount {
    param($Runtime)
    if ($Runtime.otherUsers.Count -gt 0) {
        throw '检测到 Claude Desktop 正在另一个 Windows 账户中运行。请在该账户中直接双击本工具；不要使用其他管理员账户启动。该账户的用户策略不属于当前 HKCU。'
    }
}

function Stop-ClaudeDesktop {
    param($Runtime)
    Assert-ClaudeDesktopAccount $Runtime
    # Recheck PID identity after the user has confirmed, before ending any process.
    $current = Get-ClaudeDesktopRuntime
    Assert-ClaudeDesktopAccount $current
    foreach ($process in $current.processes) {
        $live = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $process.ProcessId) -ErrorAction Stop
        # Electron children can exit as soon as the main process stops. WMI may
        # briefly retain that PID with an empty executable path while it exits.
        if ($null -eq $live -or [string]::IsNullOrWhiteSpace([string]$live.ExecutablePath)) { continue }
        if ($live.CreationDate -ne $process.CreationDate -or $live.ExecutablePath -ne $process.ExecutablePath) { throw 'Claude 进程已经变化，请重新运行操作。' }
        try { Stop-Process -Id $process.ProcessId -ErrorAction Stop }
        catch {
            if ($null -ne (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue)) { throw }
        }
    }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $remaining = Get-ClaudeDesktopRuntime
        Assert-ClaudeDesktopAccount $remaining
        if ($remaining.processes.Count -eq 0) { return }
        Start-Sleep -Milliseconds 250
    }
    throw 'Claude Desktop 尚未完全退出，未修改本地配置。'
}

function Start-ClaudeDesktop {
    param($Runtime)
    if ($null -eq $Runtime.launch) { Write-Host '请重新打开 Claude Desktop。' -ForegroundColor Yellow; return }
    if ([string]::IsNullOrEmpty($Runtime.launch.argument)) { Start-Process -FilePath $Runtime.launch.file }
    else { Start-Process -FilePath $Runtime.launch.file -ArgumentList $Runtime.launch.argument }
}

function Invoke-ClaudeRefresh {
    $runtime = Get-ClaudeDesktopRuntime
    Assert-ClaudeDesktopAccount $runtime
    if ($runtime.processes.Count -eq 0) { return }
    Write-Host 'Claude Desktop 仍在运行，可能还在使用退出前的配置。' -ForegroundColor Yellow
    Write-Host '保存 Claude 中的工作后，输入“确认重启”以完全退出并重新打开；直接回车跳过：'
    if ((Read-Host).Trim() -cne '确认重启') { return }
    Stop-ClaudeDesktop $runtime
    Start-ClaudeDesktop $runtime
    Write-Host '已重新启动 Claude Desktop，请检查设置。' -ForegroundColor Green
}

function Show-LocalConfigStatus {
    param([switch]$Detailed)
    Write-Section '应用设置'
    $runtime = Get-ClaudeDesktopRuntime
    Assert-ClaudeDesktopAccount $runtime
    $configs = @(Get-ClaudeLocalConfigs)
    if ($configs.Count -eq 0) { Write-Host '尚未设置本地连接配置。' }
    foreach ($config in $configs) {
        $state = if ($config.bootstrapActive) { '远程配置已开启，服务提供的设置会锁定。' } else { '使用本地配置，未开启远程限制。' }
        Write-Host "  $state"
        if ($Detailed) { Write-Host "  $($config.path)" -ForegroundColor DarkGray }
    }
    if ($runtime.processes.Count -gt 0) { Write-Host 'Claude 正在运行，配置变更需重启后生效。' -ForegroundColor Yellow }
    return $configs
}

function Get-LocalConfigBackupRoot { Join-Path $DataRoot 'LocalConfigBackups' }

function New-LocalConfigBackup {
    param($Config)
    $root = Get-LocalConfigBackupRoot
    Assert-SafeBackupPath $root -AllowMissing
    [void][IO.Directory]::CreateDirectory($root)
    $directory = Join-Path $root ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    $manifest = [ordered]@{
        tool = 'ClaudePolicyTool'; schema = 1; kind = 'LocalBootstrap'; createdUtc = [DateTime]::UtcNow.ToString('o')
        userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; computerName = $env:COMPUTERNAME
        dataRoot = $Config.root; profileId = $Config.id; sha256 = $Config.hash
    }
    [IO.File]::WriteAllBytes((Join-Path $directory 'config.json'), $Config.bytes)
    Write-TextUtf8 (Join-Path $directory 'manifest.json') ($manifest | ConvertTo-Json -Depth 10)
    Write-TextUtf8 (Join-Path $directory 'manifest.sha256') (Get-Sha256 (Join-Path $directory 'manifest.json'))
    $null = Read-LocalConfigBackup $directory
    return $directory
}

function Read-LocalConfigBackup {
    param([string]$Directory)
    $root = [IO.Path]::GetFullPath((Get-LocalConfigBackupRoot)).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($full) -ine $root) { throw '本地配置备份必须位于工具的备份目录中。' }
    $manifestPath = Join-Path $full 'manifest.json'
    $filePath = Join-Path $full 'config.json'
    $hashPath = Join-Path $full 'manifest.sha256'
    Assert-SafeBackupPath $manifestPath
    Assert-SafeBackupPath $filePath
    Assert-SafeBackupPath $hashPath
    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    if ((Get-BytesSha256 $manifestBytes) -cne [IO.File]::ReadAllText($hashPath).Trim()) { throw '本地配置备份清单的完整性校验失败。' }
    $manifest = Read-ConfigJson $manifestBytes
    if ($manifest.tool -cne 'ClaudePolicyTool' -or $manifest.schema -ne 1 -or $manifest.kind -cne 'LocalBootstrap') { throw '本地配置备份格式不受支持。' }
    if ($manifest.userSid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $manifest.computerName -ine $env:COMPUTERNAME) { throw '此备份不属于当前电脑和 Windows 账户。' }
    if ([string]$manifest.dataRoot -notin @(Get-ClaudeConfigRoots)) { throw '本地配置备份的目标目录无效。' }
    $guid = [guid]::Empty
    if (-not [guid]::TryParseExact([string]$manifest.profileId, 'D', [ref]$guid)) { throw '本地配置备份的配置编号无效。' }
    $bytes = [IO.File]::ReadAllBytes($filePath)
    if ((Get-BytesSha256 $bytes) -cne $manifest.sha256) { throw '本地配置备份的完整性校验失败。' }
    $null = Read-ConfigJson $bytes
    [pscustomobject]@{ directory = $full; root = [string]$manifest.dataRoot; id = [string]$manifest.profileId; bytes = $bytes }
}

function Write-LocalConfigSnapshot {
    param($Config, [byte[]]$Bytes)
    Assert-SafeBackupPath $Config.path
    Assert-SafeBackupPath $Config.metaPath
    if ((Get-Sha256 $Config.path) -cne $Config.hash -or (Get-Sha256 $Config.metaPath) -cne $Config.metaHash) { throw '已应用的配置发生变化，请重新运行操作。' }
    $null = Read-ConfigJson $Bytes
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($Config.path)) ([guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Replace($temporary, $Config.path, [Management.Automation.Language.NullString]::Value)
        if ((Get-Sha256 $Config.path) -cne (Get-BytesSha256 $Bytes)) { throw '本地配置写入校验失败。原文件已保存到备份目录。' }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Disable-LocalBootstrap {
    param($Config)
    if (-not $Config.bootstrapActive) { throw '此配置未启用远程配置。' }
    $data = Read-ConfigJson $Config.bytes
    $data | Add-Member -MemberType NoteProperty -Name bootstrapEnabled -Value $false -Force
    $bytes = $Utf8NoBom.GetBytes(($data | ConvertTo-Json -Depth 100))
    $backup = New-LocalConfigBackup $Config
    Write-LocalConfigSnapshot $Config $bytes
    return $backup
}

function Invoke-LocalConfigUnlock {
    $runtime = Get-ClaudeDesktopRuntime
    Assert-ClaudeDesktopAccount $runtime
    $configs = @(Show-LocalConfigStatus)
    if ($configs.Count -eq 0) { Invoke-ClaudeRefresh; return }
    $index = 0
    if ($configs.Count -gt 1) {
        Write-Host '发现多个安装位置的配置，请选择要处理的一项：'
        for ($i = 0; $i -lt $configs.Count; $i++) {
            $source = if ($configs[$i].bootstrapActive) { '远程配置' } else { '本地配置' }
            Write-Host (('{0}. {1}：{2}' -f ($i + 1), $source, $configs[$i].path))
        }
        $selection = 0
        if (-not [int]::TryParse((Read-Host '选择需要解除限制的配置编号，回车取消'), [ref]$selection) -or $selection -lt 1 -or $selection -gt $configs.Count) { return }
        $index = $selection - 1
    }
    if (-not $configs[$index].bootstrapActive) { Invoke-ClaudeRefresh; return }
    Write-Host '将备份并关闭远程配置，保留已保存的本地设置。' -ForegroundColor Yellow
    Write-Host '远程提供的 API 设置将不再加载，之后需填写自己的连接信息。'
    Write-Host '请保存 Claude 中的工作。输入“确认解锁”继续，完成后会重启 Claude：'
    if ((Read-Host).Trim() -cne '确认解锁') { return }
    Stop-ClaudeDesktop $runtime
    try {
        $backup = Disable-LocalBootstrap $configs[$index]
        Write-Host '远程配置已关闭，设置可在重启后修改。' -ForegroundColor Green
        Write-Host "备份：$backup" -ForegroundColor DarkGray
    } finally { Start-ClaudeDesktop $runtime }
}

function Get-LocalConfigBackupCandidates {
    $root = Get-LocalConfigBackupRoot
    if (-not (Test-Path -LiteralPath $root)) { return }
    Assert-SafeBackupPath $root
    Get-ChildItem -LiteralPath $root -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } | Sort-Object Name -Descending
}

function Invoke-LocalConfigRestore {
    $candidates = @(Get-LocalConfigBackupCandidates)
    if ($candidates.Count -eq 0) { Write-Host '没有本地配置备份。'; return }
    for ($i = 0; $i -lt $candidates.Count; $i++) { Write-Host ('{0}. {1}' -f ($i + 1), $candidates[$i].Name) }
    $selection = 0
    if (-not [int]::TryParse((Read-Host '选择本地配置备份编号，回车取消'), [ref]$selection) -or $selection -lt 1 -or $selection -gt $candidates.Count) { return }
    $backup = Read-LocalConfigBackup $candidates[$selection - 1].FullName
    $configs = @(Get-ClaudeLocalConfigs | Where-Object { $_.root -ieq $backup.root -and $_.id -ceq $backup.id })
    if ($configs.Count -ne 1) { throw '备份对应的配置当前未应用。请先在 Claude 中切换到该配置，再恢复备份。' }
    $runtime = Get-ClaudeDesktopRuntime
    Assert-ClaudeDesktopAccount $runtime
    Write-Host '请保存 Claude 中的工作。输入“确认恢复”继续，完成后会重启 Claude：'
    if ((Read-Host).Trim() -cne '确认恢复') { return }
    Stop-ClaudeDesktop $runtime
    try {
        $currentBackup = New-LocalConfigBackup $configs[0]
        Write-LocalConfigSnapshot $configs[0] $backup.bytes
        Write-Host "本地配置已恢复。恢复前备份：$currentBackup" -ForegroundColor Green
    } finally { Start-ClaudeDesktop $runtime }
}

function Invoke-RestoreMenu {
    if (@(Get-LocalConfigBackupCandidates).Count -eq 0) { Invoke-RestoreInteractive; return }
    Write-Host '1. 恢复注册表策略备份'
    Write-Host '2. 恢复本地配置备份'
    switch ((Read-Host '选择备份类型，回车取消').Trim()) {
        '1' { Invoke-RestoreInteractive }
        '2' { Invoke-LocalConfigRestore }
    }
}

function Show-PolicyStatus {
    param([object[]]$Targets = $ProductionTargets, [switch]$Detailed)
    Write-Section '管理策略'
    $present = 0
    $scopes = @()
    $readErrors = @()
    foreach ($target in $Targets) {
        $scope = if ($target.hive -eq 'HKLM') { '整台电脑' } else { '当前用户' }
        try {
            $exists = Test-TargetExists $target
            if ($exists) { $present++; $scopes += $scope }
            $color = if ($exists) { 'Yellow' } else { 'Green' }
            $state = if ($exists) { '存在策略' } else { '未发现策略' }
        } catch {
            $readErrors += $_.Exception.Message
            $color = 'Red'
            $state = '读取失败，状态未知'
        }
        if ($Detailed) {
            Write-Host ('  [{0} / {1} 位]  {2}' -f $scope, $target.view, $state) -ForegroundColor $color
            Write-Host "      $($target.regPath)" -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    if ($readErrors.Count -gt 0) {
        throw ("策略检查不完整，已停止操作。读取失败不等于没有策略：`n  - " + ($readErrors -join "`n  - "))
    }
    if ($present -gt 0) {
        Write-Host ('发现管理策略：' + ((@($scopes | Select-Object -Unique)) -join '、') + '。') -ForegroundColor Yellow
    } else {
        Write-Host '注册表中没有管理策略。'
    }
    $management = @(Get-ManagementState)
    if ($management.Count -gt 0) {
        Write-Host ''
        Write-Host '这台电脑有组织管理设置，限制可能会重新生效。' -ForegroundColor Yellow
        if ($Detailed) { $management | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow } }
    }
    return $present
}

function Show-RestartInstructions {
    Write-Host ''
    Write-Host '请保存当前工作，完全退出 Claude Desktop（包括系统托盘）后重新打开。' -ForegroundColor Yellow
}

function Show-Diagnostics {
    param([switch]$Detailed)
    $report = if ($Detailed) { Show-CompatibilityReport } else { Get-CompatibilityReport }
    $null = Show-PolicyStatus -Detailed:$Detailed
    $null = Show-LocalConfigStatus -Detailed:$Detailed
    Write-Section '检查结果'
    if (-not $report.ready) {
        if (-not $Detailed) { $report.errors | ForEach-Object { Write-Host $_ -ForegroundColor Red } }
        Write-Host '请先处理上述问题，再进行解锁或恢复。' -ForegroundColor Red
    } else {
        Write-Host '检查完成。设置仍受限时，可选择“解除限制”继续。' -ForegroundColor Green
    }
}

function Show-Help {
    Write-Section '使用说明'
    Write-Host '先检查设置，再选择“解除限制”。每次修改前会自动备份，可在“恢复备份”中撤销。'
    Write-Host '解除管理配置后，可能需要填写自己的 API 连接信息。'
    Write-Host '关闭或重启 Claude 前，请先保存工作。公司或学校的电脑请先取得管理员同意。'
    Write-Host '备份可能包含密钥，请妥善保管。'
    Write-Host "备份目录：$DataRoot" -ForegroundColor DarkGray
}

function Invoke-Unlock {
    Write-Title
    $present = Show-PolicyStatus
    if ($present -eq 0) {
        Invoke-LocalConfigUnlock
        return
    }
    Ensure-Administrator '--unlock'
    Assert-CompatibleForWrite

    Write-Host ''
    Write-Host '将备份并移除管理策略，可通过“恢复备份”撤销。'
    Write-Host '策略中的 API 地址和密钥也会移除，之后可能需要重新填写。' -ForegroundColor Yellow
    $management = @(Get-ManagementState)
    if ($management.Count -gt 0) {
        Write-Host ''
        Write-Host '检测到组织管理或组策略信号：' -ForegroundColor Yellow
        $management | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        Write-Host '只有在你拥有这台设备的管理授权时才能继续。请输入“我已获得管理员授权”确认：' -ForegroundColor Yellow
        if ((Read-Host).Trim() -cne '我已获得管理员授权') {
            Write-Host '授权确认未通过，未修改注册表。' -ForegroundColor Yellow
            return
        }
    }
    Write-Host '请输入“确认解锁”并按回车键继续：' -ForegroundColor Yellow
    if ((Read-Host).Trim() -cne '确认解锁') {
        Write-Host '操作已取消，未修改注册表。' -ForegroundColor Yellow
        return
    }

    $backupDirectory = New-BackupSet $ProductionTargets $BackupRoot 'BeforeUnlock'
    $validated = Read-ValidatedBackup $backupDirectory $ProductionTargets $BackupRoot
    Write-Host "备份：$backupDirectory" -ForegroundColor DarkGray

    try {
        Remove-AllTargets $ProductionTargets
    } catch {
        $removeError = $_.Exception.Message
        try {
            Apply-ValidatedBackupUnsafe $validated $ProductionTargets
        } catch {
            throw "严重错误：解锁失败，并且自动回滚也失败。解锁错误：$removeError；回滚错误：$($_.Exception.Message)；原始备份位置：$backupDirectory"
        }
        throw "解锁失败，但原策略已成功自动恢复。错误详情：$removeError"
    }

    Write-Host ''
    Write-Host 'Claude Desktop 管理策略已移除。请重新打开应用检查设置。' -ForegroundColor Green
    Write-Host "用于恢复的原始备份：$backupDirectory" -ForegroundColor Green
    Show-RestartInstructions
    Invoke-ClaudeRefresh
}

function Get-BackupCandidates {
    if (-not (Test-Path -LiteralPath $BackupRoot)) { return @() }
    Assert-SafeBackupPath $BackupRoot
    @(Get-ChildItem -LiteralPath $BackupRoot -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json')
    } | Sort-Object LastWriteTime -Descending)
}

function Invoke-RestoreInteractive {
    Write-Title
    $candidates = @(Get-BackupCandidates)
    if ($candidates.Count -eq 0) {
        Write-Host '没有找到由本工具创建的策略备份。' -ForegroundColor Yellow
        return
    }
    Ensure-Administrator '--restore'
    Assert-CompatibleForWrite

    Write-Host '可用的策略备份：' -ForegroundColor Cyan
    $max = [Math]::Min($candidates.Count, 20)
    for ($i = 0; $i -lt $max; $i++) {
        $manifestPath = Join-Path $candidates[$i].FullName 'manifest.json'
        try {
            Assert-SafeBackupPath $manifestPath
            $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
            $kindLabel = switch ([string]$manifest.kind) {
                'BeforeUnlock' { '解锁前备份' }
                'BeforeRestore' { '恢复前安全备份' }
                default { '工具内部备份' }
            }
            $label = "$kindLabel，创建时间：$($manifest.createdUtc)，计算机：$($manifest.computerName)"
        } catch {
            $label = '备份清单无效'
        }
        Write-Host ('{0,2}. {1} [{2}]' -f ($i + 1), $candidates[$i].Name, $label)
    }
    Write-Host ''
    $selectionText = (Read-Host '请输入要恢复的备份编号，直接按回车键取消').Trim()
    if ([string]::IsNullOrWhiteSpace($selectionText)) { return }
    $selection = 0
    if (-not [int]::TryParse($selectionText, [ref]$selection) -or $selection -lt 1 -or $selection -gt $max) {
        throw '选择的备份编号无效。'
    }
    $directory = $candidates[$selection - 1].FullName
    $validated = Read-ValidatedBackup $directory $ProductionTargets $BackupRoot

    Write-Host ''
    Write-Host "备份已通过完整性与范围校验：$directory" -ForegroundColor Green
    if (-not [string]::IsNullOrWhiteSpace([string]$validated.manifest.computerName) -and
        $validated.manifest.computerName -ne $env:COMPUTERNAME) {
        Write-Host "警告：此备份来自另一台电脑：$($validated.manifest.computerName)" -ForegroundColor Yellow
        Write-Host '跨设备恢复可能覆盖本机策略。请输入“确认跨设备恢复”继续：' -ForegroundColor Yellow
        if ((Read-Host).Trim() -cne '确认跨设备恢复') {
            Write-Host '操作已取消，未修改注册表。' -ForegroundColor Yellow
            return
        }
    }
    Write-Host '恢复之前，工具会额外保存一次当前 Claude 策略状态。' -ForegroundColor White
    Write-Host '请输入“确认恢复”并按回车键继续：' -ForegroundColor Yellow
    if ((Read-Host).Trim() -cne '确认恢复') {
        Write-Host '操作已取消，未修改注册表。' -ForegroundColor Yellow
        return
    }

    $result = Restore-BackupTransaction $validated.directory $ProductionTargets $BackupRoot -ValidatedBackup $validated
    Write-Host ''
    Write-Host '策略已恢复，重新导出的内容与备份一致。' -ForegroundColor Green
    Write-Host "恢复前安全备份：$($result.rollbackDirectory)" -ForegroundColor Green
    Show-RestartInstructions
}

function Get-RegistryKeyForTest {
    param($Target, [switch]$Create)
    $hive = if ($Target.hive -eq 'HKCU') {
        [Microsoft.Win32.RegistryHive]::CurrentUser
    } else {
        [Microsoft.Win32.RegistryHive]::LocalMachine
    }
    $view = if ($Target.view -eq 64) {
        [Microsoft.Win32.RegistryView]::Registry64
    } else {
        [Microsoft.Win32.RegistryView]::Registry32
    }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
    $subPath = $Target.regPath.Substring($Target.regPath.IndexOf('\') + 1)
    if ($Create) {
        $key = $base.CreateSubKey($subPath)
    } else {
        $key = $base.OpenSubKey($subPath, $true)
    }
    $base.Dispose()
    $key
}

function Seed-TestTarget {
    param($Target, [int]$Number)
    $key = Get-RegistryKeyForTest $Target -Create
    try {
        $key.SetValue('StringValue', "alpha-$Number", [Microsoft.Win32.RegistryValueKind]::String)
        $key.SetValue('DwordValue', 1000 + $Number, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue('ExpandValue', '%TEMP%\ClaudePolicyTool', [Microsoft.Win32.RegistryValueKind]::ExpandString)
        $key.SetValue('MultiValue', [string[]]@('one', 'two', "n$Number"), [Microsoft.Win32.RegistryValueKind]::MultiString)
        $key.SetValue('BinaryValue', [byte[]]@(0, 1, 2, 127, 128, 255), [Microsoft.Win32.RegistryValueKind]::Binary)
        $child = $key.CreateSubKey('Nested')
        try { $child.SetValue('ChildValue', "nested-$Number", [Microsoft.Win32.RegistryValueKind]::String) } finally { $child.Dispose() }
    } finally {
        $key.Dispose()
    }
}

function Rewrite-ManifestChecksum {
    param([string]$Directory)
    $manifestPath = Join-Path $Directory 'manifest.json'
    Write-TextUtf8 (Join-Path $Directory 'manifest.sha256') (Get-Sha256 $manifestPath)
}

function Remove-EmptyTestParent {
    param([int]$View)
    $registryView = if ($View -eq 64) {
        [Microsoft.Win32.RegistryView]::Registry64
    } else {
        [Microsoft.Win32.RegistryView]::Registry32
    }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $registryView)
    try {
        $parent = $base.OpenSubKey('Software\ClaudePolicyToolTests', $true)
        if ($null -ne $parent) {
            try {
                if ($parent.GetSubKeyNames().Count -eq 0 -and $parent.GetValueNames().Count -eq 0) {
                    $parent.Dispose()
                    $parent = $null
                    $base.DeleteSubKey('Software\ClaudePolicyToolTests', $false)
                }
            } finally {
                if ($null -ne $parent) { $parent.Dispose() }
            }
        }
    } finally {
        $base.Dispose()
    }
}

function Invoke-SelfTest {
    Write-Title
    Write-Host '正在隔离注册表路径 HKCU\Software\ClaudePolicyToolTests 下运行自检……' -ForegroundColor Cyan
    $testId = [guid]::NewGuid().ToString('N')
    $testBase = "Software\ClaudePolicyToolTests\$testId"
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ClaudePolicyToolTest-$testId")
    $testTargets = @()
    $sharedTargets = @()
    if ([Environment]::Is64BitOperatingSystem) {
        $testTargets += New-Target 'Test64' 'HKCU' 64 "HKCU\$testBase\View64" "HKEY_CURRENT_USER\$testBase\View64"
        $testTargets += New-Target 'Test32' 'HKCU' 32 "HKCU\$testBase\View32" "HKEY_CURRENT_USER\$testBase\View32"
        $sharedTargets += New-Target 'Shared64' 'HKCU' 64 "HKCU\$testBase\Shared" "HKEY_CURRENT_USER\$testBase\Shared"
        $sharedTargets += New-Target 'Shared32' 'HKCU' 32 "HKCU\$testBase\Shared" "HKEY_CURRENT_USER\$testBase\Shared"
    } else {
        $testTargets += New-Target 'Test32' 'HKCU' 32 "HKCU\$testBase\View32" "HKEY_CURRENT_USER\$testBase\View32"
    }
    $primaryTarget = $testTargets[0]
    $passed = 0
    try {
        foreach ($target in $testTargets) { Seed-TestTarget $target $target.view }
        $baselineDirectory = New-BackupSet $testTargets $testRoot 'Baseline'
        $baseline = Read-ValidatedBackup $baselineDirectory $testTargets $testRoot
        $passed++; Write-Host '[通过] 备份创建、清单、哈希值与允许范围校验' -ForegroundColor Green

        Remove-AllTargets $testTargets
        if (@($testTargets | Where-Object { Test-TargetExists $_ }).Count -ne 0) { throw '测试解锁未删除全部隔离目标。' }
        $passed++; Write-Host '[通过] 解锁会删除全部隔离策略目标' -ForegroundColor Green

        Apply-ValidatedBackupUnsafe $baseline $testTargets
        Assert-StateMatchesBackup $baseline $testTargets
        $passed++; Write-Host '[通过] 恢复可精确还原注册表值、值类型和子项' -ForegroundColor Green

        if ($sharedTargets.Count -gt 0) {
            Seed-TestTarget $sharedTargets[0] 164
            Seed-TestTarget $sharedTargets[1] 132
            $sharedDirectory = New-BackupSet $sharedTargets $testRoot 'SharedViewBaseline'
            $sharedBaseline = Read-ValidatedBackup $sharedDirectory $sharedTargets $testRoot
            Remove-AllTargets $sharedTargets
            Apply-ValidatedBackupUnsafe $sharedBaseline $sharedTargets
            Assert-StateMatchesBackup $sharedBaseline $sharedTargets
            $passed++; Write-Host '[通过] 32 位与 64 位共享路径可正确备份和恢复' -ForegroundColor Green
        } else {
            Write-Host '[跳过] 当前为 32 位系统，不存在双注册表视图' -ForegroundColor Yellow
        }

        $key = Get-RegistryKeyForTest $primaryTarget
        try { $key.SetValue('StringValue', 'mutated', [Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Dispose() }
        $transaction = Restore-BackupTransaction $baselineDirectory $testTargets $testRoot
        Assert-StateMatchesBackup $baseline $testTargets
        if (-not (Test-Path -LiteralPath $transaction.rollbackDirectory)) { throw '未创建恢复前安全备份。' }
        $passed++; Write-Host '[通过] 事务恢复会创建安全备份并验证结果' -ForegroundColor Green

        $tamperDirectory = Join-Path $testRoot ('Tamper-' + [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $baselineDirectory -Destination $tamperDirectory -Recurse
        $tamperFile = Join-Path $tamperDirectory "$($primaryTarget.id).reg"
        [IO.File]::AppendAllText($tamperFile, 'tamper')
        $rejected = $false
        try { Read-ValidatedBackup $tamperDirectory $testTargets $testRoot | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw '被篡改的备份没有被拒绝。' }
        $passed++; Write-Host '[通过] 导入前会拒绝被篡改的备份内容' -ForegroundColor Green

        $key = Get-RegistryKeyForTest $primaryTarget
        try { $key.SetValue('StringValue', 'before-failed-restore', [Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Dispose() }
        $beforeFailureDirectory = New-BackupSet $testTargets $testRoot 'RollbackControl'
        $beforeFailure = Read-ValidatedBackup $beforeFailureDirectory $testTargets $testRoot
        $originalImport = ${function:Import-Target}
        $importFault = @{ remaining = 1; observedAbsent = $false }
        function Import-Target {
            param($Target, [string]$FilePath)
            if ($importFault.remaining -gt 0) {
                $importFault.remaining--
                $importFault.observedAbsent = -not (Test-TargetExists $Target)
                throw 'Self-test injected an import failure after target deletion.'
            }
            & $originalImport $Target $FilePath
        }
        $rollbackTriggered = $false
        try { Restore-BackupTransaction $baselineDirectory $testTargets $testRoot | Out-Null }
        catch { $rollbackTriggered = $_.Exception.Message -like '*已成功自动还原到恢复前状态*' }
        finally { Set-Item -LiteralPath Function:Import-Target -Value $originalImport }
        if (-not $rollbackTriggered -or -not $importFault.observedAbsent) { throw '删除后的导入失败没有触发事务回滚。' }
        Assert-StateMatchesBackup $beforeFailure $testTargets
        Apply-ValidatedBackupUnsafe $baseline $testTargets
        $passed++; Write-Host '[通过] 恢复中途失败会精确回滚到原始状态' -ForegroundColor Green

        $scopeDirectory = Join-Path $testRoot ('Scope-' + [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $baselineDirectory -Destination $scopeDirectory -Recurse
        $scopeFile = Join-Path $scopeDirectory "$($primaryTarget.id).reg"
        $scopeText = [IO.File]::ReadAllText($scopeFile) + "`r`n[HKEY_CURRENT_USER\Software\ClaudePolicyToolForbidden]`r`n`"Value`"=`"blocked`"`r`n"
        [IO.File]::WriteAllText($scopeFile, $scopeText, [Text.Encoding]::Unicode)
        $scopeManifestPath = Join-Path $scopeDirectory 'manifest.json'
        $scopeManifest = [IO.File]::ReadAllText($scopeManifestPath) | ConvertFrom-Json
        (@($scopeManifest.targets | Where-Object { $_.id -eq $primaryTarget.id })[0]).sha256 = Get-Sha256 $scopeFile
        Write-TextUtf8 $scopeManifestPath ($scopeManifest | ConvertTo-Json -Depth 8)
        Rewrite-ManifestChecksum $scopeDirectory
        $scopeRejected = $false
        try { Read-ValidatedBackup $scopeDirectory $testTargets $testRoot | Out-Null } catch { $scopeRejected = $true }
        if (-not $scopeRejected) { throw '超出允许范围的注册表内容没有被拒绝。' }
        $passed++; Write-Host '[通过] 即使哈希值有效，也会拒绝越界注册表路径' -ForegroundColor Green

        Write-Host ''
        Write-Host "自检成功：共 $passed 项测试全部通过，未触碰真实的 Claude 策略键。" -ForegroundColor Green
    } finally {
        foreach ($target in @($testTargets + $sharedTargets)) {
            if (Test-TargetExists $target) {
                Invoke-Reg -Arguments @('delete', $target.regPath, '/f', "/reg:$($target.view)") -AllowFailure | Out-Null
            }
        }
        foreach ($view in @($testTargets.view + $sharedTargets.view | Select-Object -Unique)) {
            Invoke-Reg -Arguments @('delete', "HKCU\Software\ClaudePolicyToolTests\$testId", '/f', "/reg:$view") -AllowFailure | Out-Null
            Remove-EmptyTestParent $view
        }
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Show-Menu {
    while ($true) {
        Write-Title
        Write-Host '1. 检查设置'
        Write-Host '2. 解除限制'
        Write-Host '3. 恢复备份'
        Write-Host '4. 使用说明'
        Write-Host '0. 退出'
        Write-Host ''
        switch ((Read-Host '请输入选项编号').Trim()) {
            '1' { Write-Title; Show-Diagnostics; Pause-Console }
            '2' { Invoke-Unlock; Pause-Console }
            '3' { Invoke-RestoreMenu; Pause-Console }
            '4' { Write-Title; Show-Help; Pause-Console }
            '0' { return }
            default { Write-Host '选项无效，请重新输入。' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
}

try {
    Assert-UserContext $env:CPT_EXPECTED_SID
    switch ($Action.ToLowerInvariant()) {
        '--status' { Write-Title; $null = Show-PolicyStatus; $null = Show-LocalConfigStatus }
        '--diagnose' { Write-Title; Show-Diagnostics -Detailed }
        '--unlock' { Invoke-Unlock; Pause-Console }
        '--restore' { Invoke-RestoreMenu; Pause-Console }
        '--self-test' { Invoke-SelfTest }
        '--help' { Write-Title; Show-Help }
        default { Show-Menu }
    }
    exit 0
} catch {
    Write-Host ''
    Write-Host '操作失败，详情如下：' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($Action -notin @('--status', '--diagnose', '--self-test')) { Pause-Console }
    exit 1
}
