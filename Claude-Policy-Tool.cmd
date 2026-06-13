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
$ToolVersion = '1.0.0'
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
                if ($unicode -match '(?i)Software\\Policies\\Claude' -or $ascii -match '(?i)Software\\Policies\\Claude') {
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
            if (Test-Path -LiteralPath $path) {
                $item = Get-Item -LiteralPath $path -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $errors += "备份路径是符号链接或目录联接，为防止备份被重定向，已拒绝写操作：$path"
                }
            }
        }
    } catch {
        $warnings += "无法完整检查备份路径属性：$($_.Exception.Message)"
    }
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        $warnings += "PowerShell 当前处于 $($ExecutionContext.SessionState.LanguageMode) 模式，组织安全策略可能阻止部分操作。"
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        $warnings += '检测到 32 位 Windows。工具会仅处理 32 位注册表视图；当前 Claude Desktop 通常使用 64 位 Windows。'
    }
    if (-not (Test-ClaudeInstalled)) {
        $warnings += '未检测到 Claude Desktop。工具仍可检查或清理策略，但不会立即看到界面变化。'
    }

    $information += "Windows：$([Environment]::OSVersion.VersionString)"
    $information += "系统架构：$($env:PROCESSOR_ARCHITECTURE)；64 位系统：$(if ([Environment]::Is64BitOperatingSystem) { '是' } else { '否' })"
    $information += "Windows PowerShell：$($PSVersionTable.PSVersion)"
    $information += "管理员权限：$(if (Test-Administrator) { '已获得' } else { '当前未获得，执行解锁或恢复时会请求 UAC 授权' })"
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

function Ensure-Administrator {
    param([string]$RequestedAction)
    if (Test-Administrator) { return }

    Write-Host '此操作需要管理员权限，正在打开 Windows 用户账户控制确认窗口……' -ForegroundColor Yellow
    try {
        $arguments = "/d /c call `"$ScriptPath`" $RequestedAction"
        Start-Process -FilePath $env:ComSpec -ArgumentList $arguments -WorkingDirectory $ScriptRoot -Verb RunAs | Out-Null
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

function Test-TargetExists {
    param($Target)
    $result = Invoke-Reg -Arguments @('query', $Target.regPath, "/reg:$($Target.view)") -AllowFailure
    $result.exitCode -eq 0
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

function New-BackupSet {
    param(
        [object[]]$Targets,
        [string]$Root,
        [string]$Kind
    )
    [void](New-Item -ItemType Directory -Path $Root -Force)
    $safeKind = $Kind -replace '[^A-Za-z0-9_-]', '_'
    $name = '{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $safeKind, ([guid]::NewGuid().ToString('N').Substring(0,8))
    $directory = Join-Path $Root $name
    [void](New-Item -ItemType Directory -Path $directory)

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
        Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Assert-DirectoryInsideRoot {
    param([string]$Directory, [string]$Root)
    $resolvedDirectory = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Directory).Path).TrimEnd('\')
    $resolvedRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Root).Path).TrimEnd('\')
    if (-not $resolvedDirectory.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw '备份目录不在本工具允许的备份根目录中。'
    }
}

function Assert-RegFileScope {
    param([string]$FilePath, $Target)
    $text = [IO.File]::ReadAllText($FilePath)
    $matches = [regex]::Matches($text, '(?m)^\[([^\]]+)\]\s*$')
    if ($matches.Count -eq 0) {
        throw "备份文件中没有找到注册表键：$FilePath"
    }
    foreach ($match in $matches) {
        $key = $match.Groups[1].Value
        if ($key.StartsWith('-', [StringComparison]::Ordinal)) {
            throw "备份文件中不允许包含注册表删除指令：$FilePath"
        }
        $allowed = $key.Equals($Target.fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
                   $key.StartsWith($Target.fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)
        if (-not $allowed) {
            throw "备份中发现超出允许范围的注册表键：$key"
        }
    }
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
    if (-not (Test-Path -LiteralPath $manifestPath) -or -not (Test-Path -LiteralPath $checksumPath)) {
        throw '备份清单或校验文件缺失。'
    }
    $expectedManifestHash = ([IO.File]::ReadAllText($checksumPath)).Trim().ToUpperInvariant()
    if ($expectedManifestHash -notmatch '^[0-9A-F]{64}$' -or (Get-Sha256 $manifestPath) -ne $expectedManifestHash) {
        throw '备份清单的完整性校验失败。'
    }

    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($manifest.toolId -ne $ToolId -or [int]$manifest.schemaVersion -ne $SchemaVersion) {
        throw '此备份不是由本工具的兼容版本生成，已拒绝恢复。'
    }

    $entries = @($manifest.targets)
    if ($entries.Count -ne $ExpectedTargets.Count) {
        throw '备份目标数量与允许的目标列表不一致。'
    }

    foreach ($target in $ExpectedTargets) {
        $matching = @($entries | Where-Object { $_.id -eq $target.id })
        if ($matching.Count -ne 1) {
            throw "备份目标缺失或重复：$($target.id)"
        }
        $entry = $matching[0]
        if ($entry.hive -ne $target.hive -or [int]$entry.view -ne $target.view -or
            $entry.regPath -ne $target.regPath -or $entry.fullRoot -ne $target.fullRoot) {
            throw "备份目标元数据已被修改：$($target.id)"
        }
        if ([bool]$entry.existed) {
            $expectedName = "$($target.id).reg"
            if ($entry.backupFile -ne $expectedName -or [string]::IsNullOrWhiteSpace([string]$entry.sha256)) {
                throw "备份文件元数据无效：$($target.id)"
            }
            $filePath = Join-Path $Directory $expectedName
            if (-not (Test-Path -LiteralPath $filePath)) {
                throw "备份文件缺失：$expectedName"
            }
            if ((Get-Sha256 $filePath) -ne ([string]$entry.sha256).ToUpperInvariant()) {
                throw "备份文件完整性校验失败：$expectedName"
            }
            Assert-RegFileScope $filePath $target
        } else {
            if ($null -ne $entry.backupFile -or $null -ne $entry.sha256) {
                throw "原本不存在的目标包含异常备份元数据：$($target.id)"
            }
        }
    }

    [pscustomobject]@{
        directory = [IO.Path]::GetFullPath($Directory)
        manifest = $manifest
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
    Remove-AllTargets $Targets
    foreach ($target in $Targets) {
        $entry = Get-ManifestEntry $ValidatedBackup $target
        if ([bool]$entry.existed) {
            Import-Target $target (Join-Path $ValidatedBackup.directory $entry.backupFile)
        }
    }
    Assert-StateMatchesBackup $ValidatedBackup $Targets
}

function Restore-BackupTransaction {
    param(
        [string]$Directory,
        [object[]]$Targets,
        [string]$Root
    )
    $requested = Read-ValidatedBackup $Directory $Targets $Root
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

function Show-PolicyStatus {
    param([object[]]$Targets = $ProductionTargets)
    Write-Section 'Claude 策略状态'
    $present = 0
    foreach ($target in $Targets) {
        $exists = Test-TargetExists $target
        if ($exists) { $present++ }
        $color = if ($exists) { 'Yellow' } else { 'Green' }
        $scope = if ($target.hive -eq 'HKLM') { '整台电脑' } else { '当前用户' }
        Write-Host ('  [{0} / {1} 位]  {2}' -f $scope, $target.view, $(if ($exists) { '存在策略' } else { '未发现策略' })) -ForegroundColor $color
        Write-Host "      $($target.regPath)" -ForegroundColor DarkGray
    }
    Write-Host ''
    if ($present -gt 0) {
        Write-Host '检测到 Claude Desktop 管理策略，第三方推理配置窗口可能处于只读状态。' -ForegroundColor Yellow
    } else {
        Write-Host '未检测到 Claude Desktop 策略键，第三方推理配置窗口应当可以编辑。' -ForegroundColor Green
    }
    $management = @(Get-ManagementState)
    if ($management.Count -gt 0) {
        Write-Host ''
        Write-Host '警告：此设备可能受到组织管理，策略可能会被管理员重新下发：' -ForegroundColor Yellow
        $management | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }
}

function Show-RestartInstructions {
    Write-Host ''
    Write-Host '为避免丢失正在进行的会话，本工具不会强制结束 Claude 进程。' -ForegroundColor Yellow
    Write-Host '请保存当前工作，完全退出 Claude Desktop（包括系统托盘），然后手动重新打开。' -ForegroundColor Yellow
}

function Show-Diagnostics {
    $report = Show-CompatibilityReport
    Show-PolicyStatus
    Write-Section '诊断结论'
    if (-not $report.ready) {
        Write-Host '当前环境不适合执行解锁或恢复。请先处理上方红色问题。' -ForegroundColor Red
    } else {
        Write-Host '当前环境具备运行条件。实际写操作仍会先备份、校验并再次确认。' -ForegroundColor Green
    }
}

function Show-Help {
    Write-Section '这个工具会做什么'
    Write-Host '  - 检查并备份 Claude Desktop 的 HKLM/HKCU 管理策略。'
    Write-Host '  - 在明确确认后，仅删除 SOFTWARE\Policies\Claude 策略键。'
    Write-Host '  - 可以从本工具创建的备份中完整恢复策略。'
    Write-Host ''
    Write-Host '这个工具不会做什么：' -ForegroundColor Yellow
    Write-Host '  - 不会修改 ClaudeCode 策略、Claude API 配置或其他软件策略。'
    Write-Host '  - 不会上传备份、API 密钥或任何本机数据。'
    Write-Host '  - 不会强制关闭 Claude Desktop。'
    Write-Host ''
    Write-Host '建议流程：先选 1 诊断，再选 2 解锁；需要回滚时选 3 恢复。' -ForegroundColor Green
    Write-Host "备份保存在：$BackupRoot" -ForegroundColor Green
}

function Invoke-Unlock {
    Assert-CompatibleForWrite
    Ensure-Administrator '--unlock'
    Write-Title
    Show-PolicyStatus
    $existing = @($ProductionTargets | Where-Object { Test-TargetExists $_ })
    if ($existing.Count -eq 0) {
        Write-Host ''
        Write-Host '当前没有需要解锁的策略，未修改注册表。' -ForegroundColor Green
        return
    }

    Write-Host ''
    Write-Host '接下来会先完整备份，然后只删除上方列出的 Claude 策略键。' -ForegroundColor White
    Write-Host '注意：备份可能包含管理员配置的 URL、请求头或凭据，请勿上传或分享备份目录。' -ForegroundColor Yellow
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
    Write-Host "备份已完成并通过完整性校验：$backupDirectory" -ForegroundColor Green

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
    Write-Host '操作成功：Claude Desktop 策略已解锁。' -ForegroundColor Green
    Write-Host "用于恢复的原始备份：$backupDirectory" -ForegroundColor Green
    Show-RestartInstructions
}

function Get-BackupCandidates {
    if (-not (Test-Path -LiteralPath $BackupRoot)) { return @() }
    @(Get-ChildItem -LiteralPath $BackupRoot -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json')
    } | Sort-Object LastWriteTime -Descending)
}

function Invoke-RestoreInteractive {
    Assert-CompatibleForWrite
    Ensure-Administrator '--restore'
    Write-Title
    $candidates = @(Get-BackupCandidates)
    if ($candidates.Count -eq 0) {
        Write-Host '没有找到由本工具创建的策略备份。' -ForegroundColor Yellow
        return
    }

    Write-Host '可用的策略备份：' -ForegroundColor Cyan
    $max = [Math]::Min($candidates.Count, 20)
    for ($i = 0; $i -lt $max; $i++) {
        $manifestPath = Join-Path $candidates[$i].FullName 'manifest.json'
        try {
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

    $result = Restore-BackupTransaction $validated.directory $ProductionTargets $BackupRoot
    Write-Host ''
    Write-Host '操作成功：注册表策略内容已完整恢复，并通过精确校验。' -ForegroundColor Green
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

        $brokenDirectory = Join-Path $testRoot ('Broken-' + [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $baselineDirectory -Destination $brokenDirectory -Recurse
        $brokenFile = Join-Path $brokenDirectory "$($primaryTarget.id).reg"
        $brokenContent = "Windows Registry Editor Version 5.00`r`n`r`n[$($primaryTarget.fullRoot)]`r`n`"Broken`"=hex:GG`r`n"
        [IO.File]::WriteAllText($brokenFile, $brokenContent, [Text.Encoding]::Unicode)
        $brokenManifestPath = Join-Path $brokenDirectory 'manifest.json'
        $brokenManifest = [IO.File]::ReadAllText($brokenManifestPath) | ConvertFrom-Json
        (@($brokenManifest.targets | Where-Object { $_.id -eq $primaryTarget.id })[0]).sha256 = Get-Sha256 $brokenFile
        Write-TextUtf8 $brokenManifestPath ($brokenManifest | ConvertTo-Json -Depth 8)
        Rewrite-ManifestChecksum $brokenDirectory
        $rollbackTriggered = $false
        try { Restore-BackupTransaction $brokenDirectory $testTargets $testRoot | Out-Null } catch { $rollbackTriggered = $true }
        if (-not $rollbackTriggered) { throw '损坏的恢复流程没有触发事务回滚。' }
        Assert-StateMatchesBackup $baseline $testTargets
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
        Write-Host '1. 运行环境与策略诊断（只读，建议先运行）'
        Write-Host '2. 解锁 Claude Desktop 第三方推理设置'
        Write-Host '3. 恢复经过校验的策略备份'
        Write-Host '4. 运行安全性隔离自检（不触碰真实策略）'
        Write-Host '5. 查看使用说明与安全须知'
        Write-Host '6. 退出'
        Write-Host ''
        switch ((Read-Host '请输入选项编号').Trim()) {
            '1' { Write-Title; Show-Diagnostics; Pause-Console }
            '2' { Invoke-Unlock; Pause-Console }
            '3' { Invoke-RestoreInteractive; Pause-Console }
            '4' { Invoke-SelfTest; Pause-Console }
            '5' { Write-Title; Show-Help; Pause-Console }
            '6' { return }
            default { Write-Host '选项无效，请重新输入。' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
}

try {
    switch ($Action.ToLowerInvariant()) {
        '--status' { Write-Title; Show-PolicyStatus }
        '--diagnose' { Write-Title; Show-Diagnostics }
        '--unlock' { Invoke-Unlock; Pause-Console }
        '--restore' { Invoke-RestoreInteractive; Pause-Console }
        '--self-test' { Invoke-SelfTest }
        '--help' { Write-Title; Show-Help }
        default { Show-Menu }
    }
    exit 0
} catch {
    Write-Host ''
    Write-Host '发生错误：' -ForegroundColor Red
    Write-Host '技术详情（供排查，可能包含系统原始文本）：' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($Action -notin @('--status', '--self-test')) { Pause-Console }
    exit 1
}
