# Download one complete release, verify it, then run the packaged installer.
& {
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir = Join-Path $env:TEMP ('tray-wsl-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    Write-Host 'Downloading tray-wsl...'
    $release = Invoke-RestMethod 'https://api.github.com/repos/lextiz/tray-wsl/releases/latest'
    foreach ($name in 'tray-wsl.zip', 'SHA256SUMS') {
        $asset = @($release.assets | Where-Object { $_.name -eq $name })
        if ($asset.Count -ne 1) { throw "Release is missing $name." }
        Invoke-WebRequest $asset[0].browser_download_url -UseBasicParsing -OutFile (Join-Path $dir $name)
    }
    $expected = ((Get-Content -LiteralPath "$dir\SHA256SUMS" -Raw).Trim() -split '\s+')[0]
    if ($expected -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath "$dir\tray-wsl.zip").Hash -ne $expected) {
        throw 'Release checksum mismatch.'
    }
    Expand-Archive -LiteralPath "$dir\tray-wsl.zip" -DestinationPath "$dir\app"
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "$dir\app\install.ps1"
    if ($LASTEXITCODE) { throw 'Installation failed.' }
} finally {
    $root = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ([IO.Path]::GetFullPath($dir).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}
}
