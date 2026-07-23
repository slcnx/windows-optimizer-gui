[CmdletBinding()]
param(
    [string]$OutputFile = (Join-Path $PSScriptRoot "release\WindowsOptimizerGUI.exe")
)

$ErrorActionPreference = "Stop"
$sourceFile = Join-Path $PSScriptRoot "WindowsOptimizerGUI.ps1"
$vendorRoot = Join-Path $PSScriptRoot "vendor\Win11Debloat"
$licenseFile = Join-Path $vendorRoot "LICENSE"

if (-not (Test-Path -LiteralPath $sourceFile)) {
    throw "找不到主程序：$sourceFile"
}
if (-not (Test-Path -LiteralPath (Join-Path $vendorRoot "Win11Debloat.ps1"))) {
    throw "找不到内嵌的 Win11Debloat 源码：$vendorRoot"
}
if (-not (Test-Path -LiteralPath $licenseFile)) {
    throw "Win11Debloat 的 MIT LICENSE 缺失，拒绝构建。"
}
if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
    $installedModule = Get-InstalledModule -Name ps2exe -ErrorAction SilentlyContinue
    if ($installedModule) {
        $moduleManifest = Join-Path $installedModule.InstalledLocation "ps2exe.psd1"
        Import-Module $moduleManifest -Force
    }
}
if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
    throw "未安装 PS2EXE。请先执行：Install-Module ps2exe -Scope CurrentUser"
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("windows-optimizer-build-" + [guid]::NewGuid().ToString("N"))
$zipFile = Join-Path $temporaryRoot "Win11Debloat.zip"
$combinedScript = Join-Path $temporaryRoot "WindowsOptimizerGUI.embedded.ps1"

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $vendorRoot,
        $zipFile,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    $payloadRaw = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($zipFile))
    $payloadLines = for ($offset = 0; $offset -lt $payloadRaw.Length; $offset += 120) {
        $length = [Math]::Min(120, $payloadRaw.Length - $offset)
        $payloadRaw.Substring($offset, $length)
    }
    $payload = $payloadLines -join "`r`n"
    $source = [System.IO.File]::ReadAllText($sourceFile, [System.Text.Encoding]::UTF8)
    $marker = '$script:EmbeddedWin11DebloatZipBase64 = "" # BUILD_EMBED_MARKER'
    if (-not $source.Contains($marker)) {
        throw "主程序中的 BUILD_EMBED_MARKER 缺失，无法注入离线资源。"
    }
    $replacement = "`$script:EmbeddedWin11DebloatZipBase64 = @'`r`n$payload`r`n'@ # BUILD_EMBED_MARKER"
    $source = $source.Replace($marker, $replacement)
    [System.IO.File]::WriteAllText($combinedScript, $source, [System.Text.UTF8Encoding]::new($true))

    $outputDirectory = Split-Path -Parent $OutputFile
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $iconFile = Join-Path $PSScriptRoot "WindowsOptimizer.ico"

    Invoke-ps2exe -InputFile $combinedScript -OutputFile $OutputFile `
        -NoConsole -RequireAdmin -IconFile $iconFile `
        -Title "Windows Optimizer GUI" `
        -Description "离线内嵌 Win11Debloat 的 Windows 性能优化工具" `
        -Version "3.0.0.0"

    Write-Host "构建完成：$OutputFile" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
