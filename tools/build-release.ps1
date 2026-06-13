param(
    [string]$Version = '1.0.0'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $root 'Claude-Policy-Tool.cmd'
$dist = Join-Path $root 'dist'
$packageName = "Claude-Desktop-Policy-Tool-v$Version"
$stage = Join-Path $dist $packageName
$zip = Join-Path $dist "$packageName.zip"
$checksums = Join-Path $dist 'SHA256SUMS.txt'
$utf8NoBom = New-Object Text.UTF8Encoding($false)

function Get-Sha256 {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $tool)) {
    throw "找不到工具文件：$tool"
}

# CMD requires Windows CRLF line endings for reliable parsing across systems.
$toolText = [IO.File]::ReadAllText($tool)
$toolText = [regex]::Replace($toolText, '\r?\n', "`r`n")
[IO.File]::WriteAllText($tool, $toolText, $utf8NoBom)

Write-Host '正在运行隔离自检……' -ForegroundColor Cyan
$process = Start-Process -FilePath $env:ComSpec -ArgumentList "/d /c call `"$tool`" --self-test" -WorkingDirectory $root -Wait -PassThru -NoNewWindow
if ($process.ExitCode -ne 0) {
    throw "隔离自检失败，退出代码：$($process.ExitCode)"
}

if (Test-Path -LiteralPath $dist) {
    Remove-Item -LiteralPath $dist -Recurse -Force
}
[void](New-Item -ItemType Directory -Path $stage -Force)

foreach ($name in @('Claude-Policy-Tool.cmd', 'README.md', 'LICENSE', 'SECURITY.md', 'CHANGELOG.md', 'RELEASE_NOTES.md')) {
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $stage $name)
}

Compress-Archive -LiteralPath $stage -DestinationPath $zip -CompressionLevel Optimal

$lines = @(
    "$(Get-Sha256 $tool)  Claude-Policy-Tool.cmd",
    "$(Get-Sha256 $zip)  $([IO.Path]::GetFileName($zip))"
)
[IO.File]::WriteAllText($checksums, ($lines -join "`r`n") + "`r`n", $utf8NoBom)

Write-Host ''
Write-Host '发布包构建完成：' -ForegroundColor Green
Write-Host "  ZIP：$zip"
Write-Host "  校验：$checksums"
