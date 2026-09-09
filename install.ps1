#requires -version 5.1
param([string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'tray-wsl'))

$ErrorActionPreference = 'Stop'
$files = @('tray-wsl.ps1', 'tray-wsl-hidden.vbs', 'LICENSE')
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file) -PathType Leaf)) {
        throw "Release is missing $file. Download tray-wsl.zip and try again."
    }
}
$destination = [IO.Path]::GetFullPath($InstallDirectory)
if ($destination.TrimEnd('\') -eq $PSScriptRoot.TrimEnd('\')) {
    throw 'Run the installer from the extracted download, not the installation folder.'
}
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$app = Join-Path $destination 'tray-wsl.ps1'
# The downloaded version understands -Stop even when this is a first install.
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'tray-wsl.ps1') -Stop
if ($LASTEXITCODE -ne 0) { throw 'Could not stop the existing tray.' }
foreach ($file in $files) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $destination $file) -Force
}

Write-Host 'Choosing your WSL distribution...'
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $app -Configure
if ($LASTEXITCODE -ne 0) { throw 'Setup cancelled or no WSL distribution is installed.' }
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $app -Install
if ($LASTEXITCODE -ne 0) { throw 'Windows did not allow autostart setup.' }

$launcher = Join-Path $destination 'tray-wsl-hidden.vbs'
Start-Process wscript.exe -ArgumentList ('"{0}"' -f $launcher) -WindowStyle Hidden
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$clock = [Diagnostics.Stopwatch]::StartNew()
do {
    try { $ready = [Threading.EventWaitHandle]::OpenExisting("Local\tray-wsl-stop-$sid") }
    catch [Threading.WaitHandleCannotBeOpenedException] { Start-Sleep -Milliseconds 200 }
} while (-not $ready -and $clock.Elapsed.TotalSeconds -lt 30)
if (-not $ready) { throw "The tray did not start. See $destination\tray-wsl.log." }
$ready.Dispose()
Write-Host 'Installed! Look for the penguin in the system tray (or its overflow menu).'
