# Full install/update lifecycle with a test-only task, mutex, and simulated WSL.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$id = [guid]::NewGuid().ToString('N')
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "tray-wsl-install-$id"
$package = Join-Path $sandbox 'package'
$destination = Join-Path $sandbox 'installed app'
$taskName = "tray-wsl-test-$id"
New-Item -ItemType Directory -Path $package | Out-Null
try {
    foreach ($file in 'tray-wsl.ps1','tray-wsl-hidden.vbs','install.ps1','LICENSE') {
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination $package
    }
    $app = Join-Path $package 'tray-wsl.ps1'
    $source = Get-Content -LiteralPath $app -Raw
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($app, [ref]$tokens, [ref]$errors)
    $invoke = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Wsl' }, $true)
    $source = $source.Replace($invoke.Extent.Text, "function Invoke-Wsl([string[]]`$WslArgs) { if (`$WslArgs[0] -ne '--list') { throw 'Unexpected WSL action in test' }; 'Fixture' }")
    $source = $source.Replace("'tray-wsl'", "'$taskName'")
    $source = $source.Replace('Local\tray-wsl-$sid', ('Local\tray-wsl-$sid-' + $id))
    $source = $source.Replace('Local\tray-wsl-stop-$sid', ('Local\tray-wsl-stop-$sid-' + $id))
    Set-Content -LiteralPath $app -Value $source -Encoding UTF8
    $installer = Join-Path $package 'install.ps1'
    $source = (Get-Content -LiteralPath $installer -Raw).Replace('Local\tray-wsl-stop-$sid', ('Local\tray-wsl-stop-$sid-' + $id))
    Set-Content -LiteralPath $installer -Value $source -Encoding UTF8

    foreach ($attempt in 1..2) {
        & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $installer -InstallDirectory $destination
        if ($LASTEXITCODE) { throw "Install attempt $attempt failed" }
        $config = Get-Content -LiteralPath (Join-Path $destination 'tray-wsl.config.json') -Raw | ConvertFrom-Json
        if ($config.Distro -ne 'Fixture') { throw 'Distro configuration was not preserved' }
        $task = Get-ScheduledTask -TaskName $taskName
        if (-not $task.Actions.Arguments.Contains((Join-Path $destination 'tray-wsl.ps1'))) {
            throw 'Autostart points to the wrong installation'
        }
    }
    Write-Host 'Installer smoke test passed (install, autostart, launch, update, config preservation).'
} finally {
    if (Test-Path -LiteralPath (Join-Path $package 'tray-wsl.ps1')) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'tray-wsl.ps1') -Stop
        if ($LASTEXITCODE) { throw "Test tray did not stop; retained $sandbox for inspection." }
    }
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    $resolved = [IO.Path]::GetFullPath($sandbox)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -eq "tray-wsl-install-$id") {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
