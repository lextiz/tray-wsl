param([string]$Source = (Join-Path $PSScriptRoot '../tray-wsl.ps1'))

# Load only function definitions: tests never start the tray or change real WSL.
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $Source), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors.Message -join "`n") }
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}

Describe 'Watchdog backoff' {
    BeforeEach {
        $script:Desired = 'off'
        $script:LastAct = [datetime]::MinValue
        $script:Strikes = 0
        $script:StableSince = $null
        $script:Now = [datetime]'2026-01-01'
        $script:Up = $true
        $script:Calls = 0
        $WdBaseSec = 15; $WdCapSec = 300
        Mock Get-Date { $script:Now }
        Mock Test-WslUp { $script:Up }
        Mock Stop-Wsl { $script:Calls++ }
        Mock Start-Wsl { $script:Calls++ }
        Mock Log {}
    }
    It 'retains backoff across brief healthy polls and starts at 15 seconds' {
        Enforce-Desired
        $script:Calls | Should Be 1
        $script:Up = $false; $script:Now = $script:Now.AddSeconds(5)
        Enforce-Desired
        $script:Up = $true; $script:Now = $script:Now.AddSeconds(5)
        Enforce-Desired
        $script:Calls | Should Be 1
        $script:Now = $script:Now.AddSeconds(5)
        Enforce-Desired
        $script:Calls | Should Be 2
        $script:Up = $false; $script:Now = $script:Now.AddSeconds(5)
        Enforce-Desired
        $script:Up = $true
        $script:Now = $script:Now.AddSeconds(15)
        Enforce-Desired
        $script:Calls | Should Be 2
    }
    It 'backs off failed corrections too' {
        Mock Stop-Wsl { $script:Calls++; throw 'failed' }
        { Enforce-Desired } | Should Throw
        $script:Now = $script:Now.AddSeconds(5)
        Enforce-Desired
        $script:Calls | Should Be 1
    }
    It 'resets only after five minutes of continuous healthy observations' {
        Enforce-Desired
        $script:Up = $false; $script:Now = $script:Now.AddSeconds(5)
        Enforce-Desired
        $script:Strikes | Should Be 1
        $script:Now = $script:Now.AddSeconds(300)
        Enforce-Desired
        $script:Strikes | Should Be 0
    }
    It 'never corrects when the status query fails' {
        Mock Test-WslUp { throw 'query failed' }
        { Enforce-Desired } | Should Throw
        $script:Calls | Should Be 0
    }
}

Describe 'Distro selection' {
    BeforeEach {
        $script:Distro = 'Removed distro'
        Mock Get-AllDistros { 'Current distro' }
        Mock Save-Config {}
    }
    It 'replaces a saved distro that is no longer installed' {
        Resolve-Distro
        $script:Distro | Should Be 'Current distro'
    }
    It 'keeps an installed configured distro' {
        $script:Distro = 'Current distro'
        Resolve-Distro
        Assert-MockCalled Save-Config -Times 0 -Exactly -Scope It
    }
    It 'does not save a cancelled selection' {
        Mock Get-AllDistros { 'One'; 'Two' }
        Mock Select-Distro { $null }
        { Resolve-Distro } | Should Throw 'cancelled'
        Assert-MockCalled Save-Config -Times 0 -Exactly -Scope It
    }
    It 'reports no installed distributions' {
        Mock Get-AllDistros {}
        { Resolve-Distro } | Should Throw 'No WSL distro'
    }
}

Describe 'Native WSL command handling' {
    $fixture = Join-Path $TestDrive 'wsl-fixture.exe'
    Add-Type -OutputAssembly $fixture -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.Text;
using System.Threading;
public class WslFixture {
    public static int Main(string[] args) {
        Console.OutputEncoding = Encoding.Unicode;
        switch (args[0]) {
            case "hang": Thread.Sleep(30000); return 0;
            case "fail": Console.Error.Write("fixture failure"); return 42;
            case "flood": Console.Error.Write(new string('x', 100000)); Console.Write("done"); return 0;
            default:
                for (int i = 1; i < args.Length; i++)
                    Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(args[i])));
                return 0;
        }
    }
}
'@
    It 'round trips spaces, quotes, Unicode, empty strings and trailing backslashes' {
        $values = @('Ubuntu Custom', 'a"b', 'a\"b', 'C:\some path\', '', ([string][char]0x00fc))
        $result = Invoke-Wsl -WslArgs (@('echo') + $values) -FilePath $fixture
        $actual = $result -split "`r?`n"
        for ($i = 0; $i -lt $values.Count; $i++) {
            [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($actual[$i])) | Should Be $values[$i]
        }
    }
    It 'reports a nonzero exit code and stderr' {
        { Invoke-Wsl -WslArgs @('fail') -FilePath $fixture } | Should Throw 'fixture failure'
    }
    It 'drains stdout and stderr concurrently without a pipe deadlock' {
        Invoke-Wsl -WslArgs @('flood') -FilePath $fixture | Should Be 'done'
    }
    It 'terminates only the timed out command process' {
        $elapsed = [Diagnostics.Stopwatch]::StartNew()
        { Invoke-Wsl -WslArgs @('hang') -FilePath $fixture -TimeoutMilliseconds 200 } | Should Throw 'timed out'
        ($elapsed.Elapsed.TotalSeconds -lt 5) | Should Be $true
        @(Get-Process 'wsl-fixture' -ErrorAction SilentlyContinue).Count | Should Be 0
    }
}

Describe 'Status decoding and UI' {
    BeforeEach { Mock Invoke-Wsl { "Ubuntu`0`r`nDebian`r`n`r`n" } }
    It 'returns clean nonempty distro names' {
        (Get-RunningDistros) -join ',' | Should Be 'Ubuntu,Debian'
    }
    It 'reports command errors instead of a sleeping status' {
        Mock Invoke-Wsl { throw 'query failed' }
        { Test-WslUp } | Should Throw 'query failed'
    }
    It 'renders a bounded tooltip even with a very long configured distro name' {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $miSwitch = New-Object System.Windows.Forms.ToolStripMenuItem
        $miAuto = New-Object System.Windows.Forms.ToolStripMenuItem
        $script:IconAwake = [Drawing.SystemIcons]::Application
        $script:IconSleep = [Drawing.SystemIcons]::Information
        $script:Distro = 'x' * 100
        Mock Get-WslRamMB { 1234 }
        try {
            Refresh-Ui
            $ni.Text | Should Be 'WSL: Awake - 1234 MB'
            $miSwitch.Text | Should Be 'Switch WSL off'
        } finally { $ni.Dispose(); $miSwitch.Dispose(); $miAuto.Dispose() }
    }
}
