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

# Load only top-level function definitions. Never run the CMD payload's initialization,
# entry point, or its exit statements; all mutable targets are supplied below.
$ToolPath = (Resolve-Path -LiteralPath $ToolPath).ProviderPath
$payload = ((Get-Content -LiteralPath $ToolPath -Encoding UTF8 | Select-Object -Skip 12) -join "`n")
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($payload, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) {
    throw ('无法解析工具的 PowerShell payload：' + (($parseErrors | ForEach-Object { $_.Message }) -join '; '))
}
$definitions = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
foreach ($name in @('New-Target', 'Invoke-Reg', 'Test-TargetExists', 'Show-PolicyStatus', 'Invoke-Unlock', 'New-BackupSet')) {
    if (@($definitions | Where-Object { $_.Name -eq $name }).Count -ne 1) { throw "工具缺少唯一的函数定义：$name" }
}
. ([scriptblock]::Create((($definitions | ForEach-Object { $_.Extent.Text }) -join "`n")))

# Supply the variables normally initialized by the payload, but only with test paths.
$ToolId = 'ClaudePolicyTool'
$ToolVersion = 'regression-test'
$SchemaVersion = 1
$ScriptPath = $ToolPath
$ScriptRoot = Split-Path -Parent $ToolPath
$RegExe = Join-Path $env:SystemRoot 'System32\reg.exe'
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$testId = [guid]::NewGuid().ToString('N')
$registryRoot = "Software\ClaudePolicyToolTests\$testId"
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = [IO.Path]::GetFullPath((Join-Path $tempParent "ClaudePolicyToolRegression-$testId"))
$DataRoot = $testRoot
$BackupRoot = Join-Path $testRoot 'UnlockBackups'
$ProductionTargets = @()
$script:allowedRegPaths = @()
$script:leases = New-Object 'System.Collections.Generic.List[object]'
$script:results = New-Object 'System.Collections.Generic.List[object]'
$script:ensureCalls = 0
$script:compatibilityCalls = 0
$script:removeCalls = 0
$script:backupCalls = 0
$script:localScanCalls = 0
$script:allowBackupTest = $false
$script:realInvokeReg = ${function:Invoke-Reg}
$script:realNewBackupSet = ${function:New-BackupSet}

function Assert-Regression {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-RegressionCase {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:results.Add([pscustomobject]@{ name = $Name; passed = $true; detail = '' })
        Write-Host "[通过] $Name" -ForegroundColor Green
    } catch {
        $detail = $_.Exception.Message
        $script:results.Add([pscustomobject]@{ name = $Name; passed = $false; detail = $detail })
        Write-Host "[失败] ${Name}：$detail" -ForegroundColor Red
    }
}

function Get-TestView {
    param([int]$View)
    if ($View -eq 64) { return [Microsoft.Win32.RegistryView]::Registry64 }
    return [Microsoft.Win32.RegistryView]::Registry32
}

function New-IsolatedTarget {
    param([string]$Id, [int]$View, [string]$Leaf)
    $path = "$registryRoot\View$View\$Leaf"
    $target = New-Target $Id 'HKCU' $View "HKCU\$path" "HKEY_CURRENT_USER\$path"
    $script:allowedRegPaths += $target.regPath
    return $target
}

function New-IsolatedKey {
    param($Target)
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, (Get-TestView $Target.view))
    try {
        $key = $base.CreateSubKey($Target.regPath.Substring(5))
        if ($null -eq $key) { throw "无法创建隔离测试键：$($Target.regPath)" }
        $key.Dispose()
    } finally { $base.Dispose() }
}

function Add-ReadDenial {
    param($Target)
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, (Get-TestView $Target.view))
    $key = $null
    $leased = $false
    try {
        $rights = [Security.AccessControl.RegistryRights]::ReadPermissions -bor [Security.AccessControl.RegistryRights]::ChangePermissions
        $key = $base.OpenSubKey($Target.regPath.Substring(5), [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $rights)
        if ($null -eq $key) { throw "无法打开隔离测试键的权限句柄：$($Target.regPath)" }
        # Windows may set DACL_AUTO_INHERITED when an inherited ACL is first saved.
        # Normalize the newly created key before recording the exact test baseline.
        $initial = $key.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
        $normalized = New-Object Security.AccessControl.RegistrySecurity
        $normalized.SetSecurityDescriptorBinaryForm($initial.GetSecurityDescriptorBinaryForm(), [Security.AccessControl.AccessControlSections]::Access)
        $key.SetAccessControl($normalized)
        $original = $key.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
        $originalBytes = $original.GetSecurityDescriptorBinaryForm()
        $originalSddl = $original.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
        # Retain the pre-opened ChangePermissions handle even after the denial is installed.
        $script:leases.Add([pscustomobject]@{ key = $key; bytes = $originalBytes; sddl = $originalSddl; target = $Target })
        $leased = $true
        $changed = New-Object Security.AccessControl.RegistrySecurity
        $changed.SetSecurityDescriptorBinaryForm($originalBytes, [Security.AccessControl.AccessControlSections]::Access)
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $deny = New-Object Security.AccessControl.RegistryAccessRule($sid, [Security.AccessControl.RegistryRights]::ReadKey, [Security.AccessControl.InheritanceFlags]::None, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Deny)
        $changed.AddAccessRule($deny)
        $key.SetAccessControl($changed)
    } finally {
        if ($null -ne $key -and -not $leased) { $key.Dispose() }
        $base.Dispose()
    }
}

# Stop tests immediately if a buggy unlock implementation attempts a write or elevation.
# The original v1.0.0 existence check still needs a read-only reg query.
function Invoke-Reg {
    param([string[]]$Arguments, [switch]$AllowFailure)
    if ($Arguments.Count -ne 3 -or $Arguments[0] -ne 'query' -or
        $script:allowedRegPaths -notcontains $Arguments[1] -or $Arguments[2] -notmatch '^/reg:(32|64)$') {
        throw 'TEST HARNESS: blocked a registry operation outside an approved read-only test query.'
    }
    & $script:realInvokeReg -Arguments $Arguments -AllowFailure:$AllowFailure
}
function Ensure-Administrator { $script:ensureCalls++; throw 'TEST HARNESS: elevation called' }
function Assert-CompatibleForWrite { $script:compatibilityCalls++; throw 'TEST HARNESS: write compatibility called' }
function Remove-AllTargets { $script:removeCalls++; throw 'TEST HARNESS: registry write called' }
function Get-ManagementState { return @() }
function Get-ClaudeConfigRoots {
    $script:localScanCalls++
    return (Join-Path $testRoot 'LocalConfigFixture')
}
function Get-ClaudeDesktopRuntime { return [pscustomobject]@{ processes = @(); otherUsers = @(); launch = $null } }
function Stop-ClaudeDesktop { throw 'TEST HARNESS: process termination called' }
function Start-ClaudeDesktop { throw 'TEST HARNESS: process launch called' }
function Write-Title { Write-Host 'Claude Policy Tool regression test' }
function Read-Host { throw 'TEST HARNESS: interactive input called' }
function New-BackupSet {
    param([object[]]$Targets, [string]$Root, [string]$Kind)
    $script:backupCalls++
    $approved = [IO.Path]::GetFullPath((Join-Path $testRoot 'BackupCase'))
    if (-not $script:allowBackupTest -or -not [IO.Path]::GetFullPath($Root).Equals($approved, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'TEST HARNESS: unexpected backup attempt.'
    }
    foreach ($target in $Targets) {
        if ($script:allowedRegPaths -notcontains $target.regPath) { throw 'TEST HARNESS: unexpected backup target.' }
    }
    & $script:realNewBackupSet -Targets $Targets -Root $Root -Kind $Kind
}

function Reset-GuardCounts {
    $script:ensureCalls = 0
    $script:compatibilityCalls = 0
    $script:removeCalls = 0
    $script:backupCalls = 0
    $script:localScanCalls = 0
}

$views = if ([Environment]::Is64BitOperatingSystem) { @(64, 32) } else { @(32) }
$fixtures = @()
$pathsValidated = $false
try {
    if ($testId -notmatch '^[0-9a-f]{32}$' -or $registryRoot -cne "Software\ClaudePolicyToolTests\$testId" -or
        -not $testRoot.Equals((Join-Path $tempParent "ClaudePolicyToolRegression-$testId"), [StringComparison]::OrdinalIgnoreCase)) {
        throw '测试路径校验失败。'
    }
    if (Test-Path -LiteralPath $testRoot) { throw '随机临时目录已存在，拒绝使用。' }
    foreach ($view in $views) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, (Get-TestView $view))
        try {
            $existing = $base.OpenSubKey($registryRoot, $false)
            if ($null -ne $existing) {
                $existing.Dispose()
                throw '随机注册表测试根已存在，拒绝使用。'
            }
        } finally { $base.Dispose() }
    }
    $pathsValidated = $true
    foreach ($view in $views) {
        $present = New-IsolatedTarget "Present$view" $view 'Present'
        $missing = New-IsolatedTarget "Missing$view" $view 'Missing'
        $sibling = New-IsolatedTarget "Sibling$view" $view 'MissingExtra'
        $denied = New-IsolatedTarget "Denied$view" $view 'Denied'
        New-IsolatedKey $present
        New-IsolatedKey $sibling
        New-IsolatedKey $denied
        Add-ReadDenial $denied
        $fixtures += [pscustomobject]@{ present = $present; missing = $missing; sibling = $sibling; denied = $denied }
    }

    Invoke-RegressionCase '准确区分存在、缺失与同名前缀兄弟键' {
        foreach ($f in $fixtures) {
            Assert-Regression ((Test-TargetExists $f.present) -eq $true) "应识别存在的键：$($f.present.id)"
            Assert-Regression ((Test-TargetExists $f.sibling) -eq $true) "应识别兄弟键：$($f.sibling.id)"
            Assert-Regression ((Test-TargetExists $f.missing) -eq $false) "缺失键不能因同名前缀兄弟键而被误判：$($f.missing.id)"
        }
    }

    Invoke-RegressionCase '真实 ACL 拒绝读取时存在性检查抛错' {
        foreach ($f in $fixtures) {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, (Get-TestView $f.denied.view))
            $nativeDenied = $false
            $nativeKey = $null
            try {
                try { $nativeKey = $base.OpenSubKey($f.denied.regPath.Substring(5), $false) } catch {
                    $exception = $_.Exception
                    while ($null -ne $exception) {
                        if ($exception -is [UnauthorizedAccessException] -or $exception -is [Security.SecurityException]) { $nativeDenied = $true }
                        $exception = $exception.InnerException
                    }
                }
            } finally {
                if ($null -ne $nativeKey) { $nativeKey.Dispose() }
                $base.Dispose()
            }
            Assert-Regression $nativeDenied "测试 ACL 未真实拒绝读取：$($f.denied.id)"
            $threw = $false
            try { $null = Test-TargetExists $f.denied } catch { $threw = $true }
            Assert-Regression $threw "拒绝读取不能被当作不存在：$($f.denied.id)"
        }
    }

    Invoke-RegressionCase '无注册表策略时不承诺配置可编辑或无需解锁' {
        $output = @(Show-PolicyStatus -Targets @($fixtures[0].missing) 6>&1)
        $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
        Assert-Regression ($output[-1] -is [int] -and $output[-1] -eq 0) '未准确返回注册表策略数量。'
        Assert-Regression ($text -notmatch '应当可以编辑|可以直接编辑|无需解锁|没有需要解锁') '无策略时不能推断配置可编辑或无需解锁。'
    }

    Invoke-RegressionCase '无注册表策略、已应用配置和运行实例时不提权或创建备份' {
        Reset-GuardCounts
        $script:ProductionTargets = @($fixtures[0].missing)
        Assert-Regression (-not (Test-Path -LiteralPath $BackupRoot)) '测试前备份目录不应存在。'
        $output = @(Invoke-Unlock 6>&1)
        $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
        Assert-Regression ($script:ensureCalls -eq 0 -and $script:compatibilityCalls -eq 0 -and $script:removeCalls -eq 0 -and $script:backupCalls -eq 0) '无策略时调用了提权或写入路径。'
        Assert-Regression (-not (Test-Path -LiteralPath $BackupRoot) -and -not (Test-Path -LiteralPath (Get-LocalConfigBackupRoot))) '无可处理的策略或配置时创建了备份目录。'
        Assert-Regression ($script:localScanCalls -gt 0) '无注册表策略时未检查本地配置。'
        Assert-Regression ($text -notmatch '应当可以编辑|可以直接编辑|无需解锁|没有需要解锁') '检查完成后给出了无法确认的可编辑结论。'
    }

    Invoke-RegressionCase '混合存在和拒绝读取时状态展示失败并抛错' {
        $f = $fixtures[0]
        $records = New-Object 'System.Collections.Generic.List[object]'
        $threw = $false
        try { Show-PolicyStatus -Targets @($f.present, $f.denied) -Detailed 6>&1 | ForEach-Object { $records.Add($_) } } catch { $threw = $true }
        $text = ($records | ForEach-Object { $_.ToString() }) -join "`n"
        $presentPath = [regex]::Escape($f.present.regPath)
        $deniedPath = [regex]::Escape($f.denied.regPath)
        Assert-Regression $threw '状态检查不完整时应抛错。'
        Assert-Regression ($text -match "(?s)存在策略.*?$presentPath") '未报告存在的目标。'
        Assert-Regression ($text -match "(?s)读取失败.*?$deniedPath") '未明确报告读取失败的目标。'
        Assert-Regression ($text -notmatch "(?s)未发现策略\s*\r?\n\s*$deniedPath") '读取失败的目标被误报为未发现。'
    }

    Invoke-RegressionCase '混合存在和拒绝读取时解锁停止且不提权或写入' {
        Reset-GuardCounts
        $script:ProductionTargets = @($fixtures[0].present, $fixtures[0].denied)
        $threw = $false
        $errorText = ''
        try { $null = Invoke-Unlock 6>&1 } catch { $threw = $true; $errorText = $_.Exception.Message }
        Assert-Regression $threw '读取失败时解锁应停止并抛错。'
        Assert-Regression ($errorText -notmatch 'TEST HARNESS') '解锁在读取失败前调用了提权或写入路径。'
        Assert-Regression ($errorText -match '读取失败') '解锁未明确报告读取失败。'
        Assert-Regression ($script:ensureCalls -eq 0 -and $script:compatibilityCalls -eq 0 -and $script:removeCalls -eq 0 -and $script:backupCalls -eq 0) '读取失败后仍调用了提权或写入路径。'
        Assert-Regression (-not (Test-Path -LiteralPath $BackupRoot)) '读取失败时创建了备份目录。'
    }

    Invoke-RegressionCase '存在策略时先请求管理员权限再检查写入' {
        Reset-GuardCounts
        $script:ProductionTargets = @($fixtures[0].present)
        $errorText = ''
        try { $null = @(Invoke-Unlock 6>&1) } catch { $errorText = $_.Exception.Message }
        Assert-Regression ($errorText -match 'TEST HARNESS: elevation called') '存在策略时应先请求管理员权限。'
        Assert-Regression ($script:ensureCalls -eq 1 -and $script:compatibilityCalls -eq 0 -and $script:removeCalls -eq 0 -and $script:backupCalls -eq 0) '提权与写入检查顺序不正确。'
        Assert-Regression (-not (Test-Path -LiteralPath $BackupRoot)) '提权前创建了备份目录。'
    }

    Invoke-RegressionCase '备份遇到拒绝读取的目标必须失败' {
        $backupCaseRoot = Join-Path $testRoot 'BackupCase'
        $denied = $fixtures[0].denied
        $threw = $false
        $errorText = ''
        $script:allowBackupTest = $true
        try {
            try { $null = New-BackupSet -Targets @($denied) -Root $backupCaseRoot -Kind 'ReadDenied' } catch { $threw = $true; $errorText = $_.Exception.Message }
        } finally { $script:allowBackupTest = $false }
        if (Test-Path -LiteralPath $backupCaseRoot) {
            foreach ($manifest in @(Get-ChildItem -LiteralPath $backupCaseRoot -Filter 'manifest.json' -File -Recurse)) {
                $data = Get-Content -LiteralPath $manifest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($entry in @($data.targets)) {
                    Assert-Regression (-not ($entry.id -eq $denied.id -and -not $entry.existed)) '备份清单错误地将无法读取的目标记录为不存在。'
                }
            }
        }
        Assert-Regression $threw '拒绝读取时备份必须失败。'
        Assert-Regression ($errorText -notmatch 'TEST HARNESS' -and $errorText -match '(无法读取|读取失败|拒绝访问|权限|access|denied|unauthorized)') '备份失败原因不是目标读取失败。'
    }
} catch {
    $detail = $_.Exception.Message
    $script:results.Add([pscustomobject]@{ name = '测试准备'; passed = $false; detail = $detail })
    Write-Host "[失败] 测试准备：$detail" -ForegroundColor Red
} finally {
    $cleanupErrors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($lease in $script:leases) {
        try {
            $restored = New-Object Security.AccessControl.RegistrySecurity
            $restored.SetSecurityDescriptorBinaryForm($lease.bytes, [Security.AccessControl.AccessControlSections]::Access)
            $lease.key.SetAccessControl($restored)
            $after = $lease.key.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
            $afterSddl = $after.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
            if ($lease.sddl -cne $afterSddl) { throw "恢复后的 ACL 与原始 ACL 不一致。原始 SDDL：$($lease.sddl)；恢复后 SDDL：$afterSddl" }
            $probeBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, (Get-TestView $lease.target.view))
            $probe = $null
            try {
                $probe = $probeBase.OpenSubKey($lease.target.regPath.Substring(5), $false)
                if ($null -eq $probe) { throw '恢复权限后无法重新打开测试键。' }
            } finally {
                if ($null -ne $probe) { $probe.Dispose() }
                $probeBase.Dispose()
            }
        } catch { $cleanupErrors.Add("ACL $($lease.target.regPath)：$($_.Exception.Message)") }
        finally { $lease.key.Dispose() }
    }
    if ($pathsValidated) {
        try {
            if ($testId -notmatch '^[0-9a-f]{32}$' -or $registryRoot -cne "Software\ClaudePolicyToolTests\$testId") { throw '注册表清理路径校验失败。' }
            foreach ($view in $views) {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, (Get-TestView $view))
                try {
                    $parent = $base.OpenSubKey('Software\ClaudePolicyToolTests', $true)
                    if ($null -ne $parent) {
                        try { $parent.DeleteSubKeyTree($testId, $false) } finally { $parent.Dispose() }
                    }
                } finally { $base.Dispose() }
            }
        } catch { $cleanupErrors.Add("注册表清理：$($_.Exception.Message)") }
        try {
            $expected = [IO.Path]::GetFullPath((Join-Path $tempParent "ClaudePolicyToolRegression-$testId"))
            if ($testId -notmatch '^[0-9a-f]{32}$' -or -not $testRoot.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { throw '临时目录清理路径校验失败。' }
            if (Test-Path -LiteralPath $testRoot) {
                $items = @((Get-Item -LiteralPath $testRoot)) + @(Get-ChildItem -LiteralPath $testRoot -Recurse)
                if (@($items | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) { throw '测试目录含重解析点，拒绝递归删除。' }
                Remove-Item -LiteralPath $testRoot -Recurse
            }
        } catch { $cleanupErrors.Add("临时目录清理：$($_.Exception.Message)") }
    }
    if ($cleanupErrors.Count -gt 0) {
        $detail = $cleanupErrors -join '; '
        $script:results.Add([pscustomobject]@{ name = '清理'; passed = $false; detail = $detail })
        Write-Host "[失败] 清理：$detail" -ForegroundColor Red
    }
}

$passed = @($script:results | Where-Object { $_.passed }).Count
$failed = @($script:results | Where-Object { -not $_.passed }).Count
Write-Host "回归测试：$passed 组通过，$failed 组失败。"
if ($failed -gt 0 -or $passed -ne 8) { exit 1 }
exit 0
