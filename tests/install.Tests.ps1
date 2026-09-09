Describe 'Installer' {
    BeforeEach {
        $script:package = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:destination = Join-Path $TestDrive ('installed ' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:package, $script:destination | Out-Null
        $installer = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../install.ps1') -Raw
        $installer = $installer.Replace('Local\tray-wsl-stop-$sid', 'Local\tray-wsl-install-test-$PID')
        Set-Content -LiteralPath (Join-Path $script:package 'install.ps1') -Value $installer
        foreach ($file in 'tray-wsl.ps1','tray-wsl-hidden.vbs','LICENSE') {
            Set-Content -LiteralPath (Join-Path $script:package $file) -Value 'release content'
        }
        $global:TrayWslInstallerTestState = @{ Steps = @(); FailConfigure = $false; Ready = $null }
        Mock powershell.exe {
            $global:TrayWslInstallerTestState.Steps += $args[-1]
            $global:LASTEXITCODE = if ($global:TrayWslInstallerTestState.FailConfigure -and $args[-1] -eq '-Configure') { 1 } else { 0 }
        }
        Mock Start-Process {
            $global:TrayWslInstallerTestState.Steps += 'launch'
            $global:TrayWslInstallerTestState.Ready = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, "Local\tray-wsl-install-test-$PID")
        }
    }
    AfterEach { if ($global:TrayWslInstallerTestState.Ready) { $global:TrayWslInstallerTestState.Ready.Dispose(); $global:TrayWslInstallerTestState.Ready = $null } }
    It 'copies the release, configures autostart and launches in order' {
        & (Join-Path $script:package 'install.ps1') -InstallDirectory $script:destination
        ($global:TrayWslInstallerTestState.Steps -join ',') | Should Be '-Stop,-Configure,-Install,launch'
        Get-Content -LiteralPath (Join-Path $script:destination 'tray-wsl.ps1') | Should Be 'release content'
        Assert-MockCalled Start-Process -Times 1 -Exactly -Scope It -ParameterFilter { $WindowStyle -eq 'Hidden' }
    }
    It 'preserves the selected distro during a repeat install' {
        $config = Join-Path $script:destination 'tray-wsl.config.json'
        Set-Content -LiteralPath $config -Value '{"Distro":"Saved distro"}'
        & (Join-Path $script:package 'install.ps1') -InstallDirectory $script:destination
        Get-Content -LiteralPath $config | Should Be '{"Distro":"Saved distro"}'
    }
    It 'does not launch or register autostart when distro setup fails' {
        $global:TrayWslInstallerTestState.FailConfigure = $true
        { & (Join-Path $script:package 'install.ps1') -InstallDirectory $script:destination } | Should Throw 'Setup cancelled'
        ($global:TrayWslInstallerTestState.Steps -join ',') | Should Be '-Stop,-Configure'
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }
    It 'rejects an incomplete release before changing the install' {
        Remove-Item -LiteralPath (Join-Path $script:package 'LICENSE')
        { & (Join-Path $script:package 'install.ps1') -InstallDirectory $script:destination } | Should Throw 'missing LICENSE'
        $global:TrayWslInstallerTestState.Steps.Count | Should Be 0
    }
}
