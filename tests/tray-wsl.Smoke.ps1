# Exercise the complete Windows tray lifecycle with simulated WSL and autostart.
$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot '../tray-wsl.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $sourcePath), [ref]$tokens, [ref]$errors)
if ($errors) { throw ($errors.Message -join "`n") }
$replacements = @{
    'Get-AllDistros' = "function Get-AllDistros { 'Fixture' }"
    'Get-RunningDistros' = "function Get-RunningDistros { if (`$script:SmokeUp) { 'Fixture' } }"
    'Start-Wsl' = 'function Start-Wsl { $script:SmokeUp = $true; $script:SmokeActions++ }'
    'Stop-Wsl' = 'function Stop-Wsl { $script:SmokeUp = $false; $script:SmokeActions++ }'
    'Test-Autostart' = 'function Test-Autostart { $false }'
}
foreach ($function in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($replacements.ContainsKey($function.Name)) {
        $source = $source.Replace($function.Extent.Text, $replacements[$function.Name])
    }
}
# Give the smoke test its own mutex so it never interacts with an installed tray.
$source = $source.Replace('Local\tray-wsl-$sid', 'Local\tray-wsl-smoke-$sid-$PID')
$source = $source.Replace('Local\tray-wsl-stop-$sid', 'Local\tray-wsl-smoke-stop-$sid-$PID')
$source = $source.Replace('[System.Windows.Forms.Application]::Run()', @'
if (-not $ni.Visible -or $null -eq $ni.Icon) { throw 'Tray failed to initialize' }
$miSwitch.PerformClick()
if (-not $script:SmokeUp -or $script:Desired -ne 'on' -or $script:SmokeActions -ne 1) {
    throw 'Switch on failed'
}
$miSwitch.PerformClick()
if ($script:SmokeUp -or $script:Desired -ne 'off' -or $script:SmokeActions -ne 2) {
    throw 'Switch off failed'
}
$smokeTimer = New-Object System.Windows.Forms.Timer
$smokeTimer.Interval = 100
$smokeTimer.add_Tick({ $miExit.PerformClick() })
$smokeTimer.Start()
try { [System.Windows.Forms.Application]::Run() }
finally { $smokeTimer.Dispose() }
'@)
$source += "`r`nif (`$ni.Visible) { throw 'Tray was not disposed' }; 'Tray smoke test passed.'"
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('tray-wsl-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
try {
    $testScript = Join-Path $sandbox 'tray-wsl.ps1'
    Set-Content -LiteralPath $testScript -Value $source -Encoding UTF8
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $testScript
    if ($LASTEXITCODE -ne 0) { throw 'Tray smoke test failed' }
} finally {
    $resolved = [IO.Path]::GetFullPath($sandbox)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved).StartsWith('tray-wsl-smoke-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
