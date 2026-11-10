param(
    [string]$Version = '1.1.0'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ProgressPreference = 'SilentlyContinue'
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$tool = Join-Path $root 'Claude-Policy-Tool.cmd'
$dist = Join-Path $root 'dist'
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$files = @('Claude-Policy-Tool.cmd', 'README.md', 'LICENSE', 'SECURITY.md', 'CHANGELOG.md', 'RELEASE_NOTES.md')

function Assert-PlainPath {
    param([string]$Path, [switch]$AllowMissing)
    $full = [IO.Path]::GetFullPath($Path)
    $current = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($current)) { throw "无法确定发布路径的根目录：$Path" }
    $parts = @('') + @($full.Substring($current.Length).TrimEnd('\').Split('\'))
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i].Length -gt 0) { $current = Join-Path $current $parts[$i] }
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch {
            $cause = $_.Exception.GetBaseException()
            if ($AllowMissing -and ($cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException])) { return }
            throw "无法检查发布路径属性：$current。$($cause.Message)"
        }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "发布路径包含符号链接、目录联接或其他重解析点：$current"
        }
        if ($i -lt $parts.Count - 1 -and ($attributes -band [IO.FileAttributes]::Directory) -eq 0) {
            throw "发布路径的祖先不是目录：$current"
        }
    }
}

function Assert-PlainDirectoryTree {
    param([string]$Directory)
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Directory)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        Assert-PlainPath $current
        foreach ($item in [IO.Directory]::GetFileSystemEntries($current)) {
            try { $attributes = [IO.File]::GetAttributes($item) }
            catch { throw "无法检查发布目录内容：$item。$($_.Exception.GetBaseException().Message)" }
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "发布目录包含符号链接、目录联接或其他重解析点：$item"
            }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($item) }
        }
    }
}

function Assert-BuildPaths {
    Assert-PlainPath $PSCommandPath
    Assert-PlainPath $root
    foreach ($name in $files) {
        $source = Join-Path $root $name
        Assert-PlainPath $source
        if (-not [IO.File]::Exists($source)) { throw "找不到发布所需文件：$source" }
    }
    foreach ($path in @($dist, $stage, $zip, $checksums)) { Assert-PlainPath $path -AllowMissing }
    if ([IO.File]::Exists($dist)) { throw "发布目录路径不是目录：$dist" }
    if ([IO.Directory]::Exists($dist)) { Assert-PlainDirectoryTree $dist }
}

function Get-Sha256 {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}

# Accept SemVer core and an optional prerelease only; no filename separators or build metadata.
$identifier = '(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)'
if ($Version -cnotmatch "^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-$identifier(?:\.$identifier)*)?$") {
    throw "发布版本必须是三段数字，可选 SemVer 预发布标识：$Version"
}
$packageName = "Claude-Desktop-Policy-Tool-v$Version"
$stage = Join-Path $dist $packageName
$zip = Join-Path $dist "$packageName.zip"
$checksums = Join-Path $dist 'SHA256SUMS.txt'

# Complete path and tree checks before normalizing the tool or starting self-test.
Assert-BuildPaths

# CMD requires Windows CRLF line endings for reliable parsing across systems.
$toolText = [IO.File]::ReadAllText($tool)
$toolText = [regex]::Replace($toolText, '\r?\n', "`r`n")
[IO.File]::WriteAllText($tool, $toolText, $utf8NoBom)

Write-Host '正在运行隔离自检……' -ForegroundColor Cyan
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not [IO.File]::Exists($powershellExe)) { throw "找不到 Windows PowerShell：$powershellExe" }
$previousSelf = [Environment]::GetEnvironmentVariable('CPT_SELF', 'Process')
$previousAction = [Environment]::GetEnvironmentVariable('CPT_ACTION', 'Process')
$childCommand = @'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
try {
    $payload = (Get-Content -LiteralPath $env:CPT_SELF -Encoding UTF8 | Select-Object -Skip 12) -join [Environment]::NewLine
    Invoke-Expression $payload
    if (-not $?) { exit 1 }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
try {
    [Environment]::SetEnvironmentVariable('CPT_SELF', $tool, 'Process')
    [Environment]::SetEnvironmentVariable('CPT_ACTION', '--self-test', 'Process')
    & $powershellExe -NoLogo -NoProfile -NonInteractive -InputFormat Text -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand $encodedCommand
    $selfTestExitCode = $LASTEXITCODE
} finally {
    [Environment]::SetEnvironmentVariable('CPT_SELF', $previousSelf, 'Process')
    [Environment]::SetEnvironmentVariable('CPT_ACTION', $previousAction, 'Process')
}
if ($selfTestExitCode -ne 0) { throw "隔离自检失败，退出代码：$selfTestExitCode" }

# The self-test can take time, so recheck the tree immediately before removal.
Assert-BuildPaths
if ([IO.Directory]::Exists($dist)) { Remove-Item -LiteralPath $dist -Recurse }
[void][IO.Directory]::CreateDirectory($stage)
Assert-PlainPath $stage

foreach ($name in $files) {
    $source = Join-Path $root $name
    $destination = Join-Path $stage $name
    Assert-PlainPath $source
    Assert-PlainPath $destination -AllowMissing
    [IO.File]::Copy($source, $destination, $false)
}

Assert-PlainPath $zip -AllowMissing
Compress-Archive -LiteralPath $stage -DestinationPath $zip -CompressionLevel Optimal
Assert-PlainPath $checksums -AllowMissing
$lines = @(
    "$(Get-Sha256 $tool)  Claude-Policy-Tool.cmd",
    "$(Get-Sha256 $zip)  $([IO.Path]::GetFileName($zip))"
)
[IO.File]::WriteAllText($checksums, ($lines -join "`r`n") + "`r`n", $utf8NoBom)

Write-Host ''
Write-Host '发布包构建完成：' -ForegroundColor Green
Write-Host "  ZIP：$zip"
Write-Host "  校验：$checksums"
