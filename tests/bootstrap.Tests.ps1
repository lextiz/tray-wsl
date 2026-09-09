Describe 'Release bootstrap' {
    BeforeEach {
        $global:TrayWslBootstrapTestState = @{ Called = $false; Directory = $null; BadHash = $false }
        $script:fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:fixture | Out-Null
        Set-Content -LiteralPath "$script:fixture\install.ps1" -Value "'fixture'"
        Compress-Archive -LiteralPath "$script:fixture\install.ps1" -DestinationPath "$script:fixture\tray-wsl.zip"
        $global:TrayWslBootstrapTestState.Archive = "$script:fixture\tray-wsl.zip"
        Mock Invoke-RestMethod {
            [pscustomobject]@{ assets = @(
                [pscustomobject]@{ name = 'tray-wsl.zip'; browser_download_url = 'https://example.test/tray-wsl.zip' },
                [pscustomobject]@{ name = 'SHA256SUMS'; browser_download_url = 'https://example.test/SHA256SUMS' }
            ) }
        }
        Mock Invoke-WebRequest {
            $global:TrayWslBootstrapTestState.Directory = Split-Path $OutFile
            if ($OutFile.EndsWith('tray-wsl.zip')) {
                Copy-Item -LiteralPath $global:TrayWslBootstrapTestState.Archive -Destination $OutFile
            } else {
                $hash = (Get-FileHash -LiteralPath $global:TrayWslBootstrapTestState.Archive).Hash
                if ($global:TrayWslBootstrapTestState.BadHash) { $hash = '0' * 64 }
                Set-Content -LiteralPath $OutFile -Value "$hash  tray-wsl.zip"
            }
        }
        Mock powershell.exe { $global:TrayWslBootstrapTestState.Called = $true; $global:LASTEXITCODE = 0 }
    }
    It 'downloads, verifies and runs the release installer, then removes temporary files' {
        & (Join-Path $PSScriptRoot '../bootstrap.ps1')
        $global:TrayWslBootstrapTestState.Called | Should Be $true
        Test-Path -LiteralPath $global:TrayWslBootstrapTestState.Directory | Should Be $false
    }
    It 'rejects a checksum mismatch without executing the installer' {
        $global:TrayWslBootstrapTestState.BadHash = $true
        { & (Join-Path $PSScriptRoot '../bootstrap.ps1') } | Should Throw 'checksum mismatch'
        $global:TrayWslBootstrapTestState.Called | Should Be $false
        Test-Path -LiteralPath $global:TrayWslBootstrapTestState.Directory | Should Be $false
    }
    It 'rejects an incomplete release' {
        Mock Invoke-RestMethod { [pscustomobject]@{ assets = @() } }
        { & (Join-Path $PSScriptRoot '../bootstrap.ps1') } | Should Throw 'missing tray-wsl.zip'
        $global:TrayWslBootstrapTestState.Called | Should Be $false
    }
}
