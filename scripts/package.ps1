$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$output = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $output -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'bootstrap.ps1') -Destination (Join-Path $output 'install.ps1') -Force
$files = 'tray-wsl.ps1', 'tray-wsl-hidden.vbs', 'install.ps1', 'LICENSE'
Compress-Archive -LiteralPath ($files | ForEach-Object { Join-Path $root $_ }) -DestinationPath (Join-Path $output 'tray-wsl.zip') -Force
Get-FileHash -LiteralPath (Join-Path $output 'tray-wsl.zip') -Algorithm SHA256 | ForEach-Object {
    $_.Hash.ToLowerInvariant() + '  tray-wsl.zip' | Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS') -Encoding ASCII
}
