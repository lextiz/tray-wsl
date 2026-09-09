#requires -version 5
<#
  tray-wsl - a tiny Windows tray app that KEEPS WSL2 in the state you want.
  Its main job is keeping WSL OFF even when another service keeps waking it.
  This stops all distributions and their running work; it does not configure
  disk compaction or guarantee reclaimed space.

    - Live tray status: green penguin = Awake (a distro is running), grey = Sleeping.
      Tooltip also shows the WSL VM memory when awake.
    - Toggle on/off from the tray menu; the watchdog then enforces that state.
    - Watchdog enforces the desired state with bounded retries and backoff.
        OFF => `wsl --shutdown`.
        ON  => boot the distro.
      It adopts the current state on launch; exit the app to stop enforcing.
    - Autostart: install a logon Scheduled Task (AtLogOn) => starts at login, no UAC.

  Language choice: PowerShell + WinForms. Zero dependencies, no SDK/compiler on a
  locked-down Intune box, single file, and the OS ships everything it needs.
  Runs unelevated: nothing here needs admin.

  Usage:
    tray-wsl.ps1              # run the tray
    tray-wsl.ps1 -SelfCheck   # verify status detection, print Awake/Sleeping, exit
    tray-wsl.ps1 -Install     # register autostart Scheduled Task, exit
    tray-wsl.ps1 -Uninstall   # remove autostart Scheduled Task, exit
#>
param(
    [switch]$SelfCheck,
    [switch]$Install,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$script:Distro     = ''                        # auto-detected if empty (Resolve-Distro)
$script:Desired    = 'off'                     # off | on, set at runtime; adopts current WSL state on launch
$script:ConfigPath = Join-Path $PSScriptRoot 'tray-wsl.config.json'
$script:LogPath    = Join-Path $PSScriptRoot 'tray-wsl.log'
$script:TaskName   = 'tray-wsl'

# ---------------------------------------------------------------- config (just the distro)
function Load-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return }
    try {
        $c = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
        if ($c.Distro) { $script:Distro = [string]$c.Distro }
    } catch {}
}
function Save-Config {
    [pscustomobject]@{ Distro = $script:Distro } | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
}
function Log([string]$m) {
    try { "{0}  {1}" -f (Get-Date -Format s), $m | Add-Content -LiteralPath $script:LogPath } catch {}
}
Load-Config

# ---------------------------------------------------------------- status (THE bug the prototype had)
# Run wsl.exe with CreateNoWindow so polling never flashes a console window, and
# read stdout as UTF-16LE (`wsl --list` prints UTF-16LE; WSL_UTF8 does NOT fix it,
# so a naive `-match 'Ubuntu'` sees a NUL between chars and fails).
function ConvertTo-WslArgument([string]$Value) {
    # WSL parses its switches before unquoting: leave simple arguments bare.
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    # Windows argv quoting: double backslashes before quotes and the closing quote.
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Invoke-Wsl([string[]]$WslArgs, [int]$TimeoutMilliseconds = 10000, [string]$FilePath = 'wsl.exe') {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = ($WslArgs | ForEach-Object { ConvertTo-WslArgument $_ }) -join ' '
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.WorkingDirectory       = $env:SystemRoot   # inherited cwd may be a \\wsl.localhost UNC path, which Process.Start rejects ("directory name is invalid")
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::Unicode
    $psi.StandardErrorEncoding  = [Text.Encoding]::Unicode
    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMilliseconds)) { throw 'WSL command timed out.' }
        $remaining = [Math]::Max(0, $TimeoutMilliseconds - [int]$clock.ElapsedMilliseconds)
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), $remaining)) {
            throw 'WSL output timed out.'
        }
        if ($p.ExitCode -ne 0) {
            throw ('WSL command failed ({0}): {1}' -f $p.ExitCode, ($stderr.Result + $stdout.Result).Trim())
        }
        $stdout.Result
    } finally {
        if (-not $p.HasExited) { $p.Kill() }
        $p.Dispose()
    }
}
function Get-WslDistros([string[]]$ListArgs) {
    ($(Invoke-Wsl $ListArgs) -split "`r?`n") | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ }
}
function Get-RunningDistros { Get-WslDistros @('--list','--running','--quiet') }
function Get-AllDistros     { Get-WslDistros @('--list','--quiet') }
# Awake = a distro is actually running, per `wsl --list --running` (authoritative,
# read-only - does NOT start WSL). Runs via CreateNoWindow (no flashing), only every 5s.
function Test-WslUp { [bool](Get-RunningDistros) }
# WSL VM memory in MB (the vmmemWSL process), 0 when asleep.
function Get-WslRamMB {
    $p = Get-Process -Name 'vmmemWSL','vmmem' -ErrorAction SilentlyContinue
    if ($p) { [int](($p | Measure-Object -Property WorkingSet64 -Sum).Sum / 1MB) } else { 0 }
}

# ---------------------------------------------------------------- self-check verification
# Verifies the #1 gotcha: `wsl --list --running` is UTF-16LE and must decode to clean
# distro names (not NUL-laced garbage). Prints the resulting status.
function Invoke-SelfCheck {
    $running = @(Get-RunningDistros)
    if ($running) {
        Write-Host ("Running distros: {0}" -f ($running -join ', '))
        foreach ($d in $running) {
            if ($d -match '[\x00-\x1F]') {
                Write-Host "FAIL: garbled name - UTF-16 decode regressed" -ForegroundColor Red; exit 1
            }
        }
        Write-Host "Status: Awake" -ForegroundColor Green
    } else {
        Write-Host "Status: Sleeping" -ForegroundColor DarkGray
    }
    exit 0
}
if ($SelfCheck) { Invoke-SelfCheck }

# ---------------------------------------------------------------- autostart (logon Scheduled Task, no UAC, unelevated)
function Install-Autostart {
    $ps  = (Get-Command powershell.exe).Source
    $act = New-ScheduledTaskAction -Execute $ps -Argument (
        "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"")
    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $trg = New-ScheduledTaskTrigger  -AtLogOn -User $userId
    $prn = New-ScheduledTaskPrincipal -UserId $userId -RunLevel Limited -LogonType Interactive
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
             -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $script:TaskName -Action $act -Trigger $trg `
        -Principal $prn -Settings $set -Force | Out-Null
    Log "autostart installed"
}
function Remove-Autostart {
    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
        Log "autostart removed"
    }
}
function Test-Autostart {
    [bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue)
}
if ($Install)   { Install-Autostart; Write-Host "Autostart installed (starts at login, no UAC)."; exit 0 }
if ($Uninstall) { Remove-Autostart;  Write-Host "Autostart removed."; exit 0 }

$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$instance = New-Object Threading.Mutex($false, "Local\tray-wsl-$sid")
$ownsInstance = $false
try {
    try { $ownsInstance = $instance.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsInstance = $true }
    if (-not $ownsInstance) { return }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TrayWslNative {
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
}
'@

# Swallow stray UI-thread exceptions to a log instead of popping the .NET crash dialog.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ param($s,$e) Log "thread exception: $($e.Exception.Message)" })

# ---------------------------------------------------------------- distro (auto-detect; dropdown if several)
function Select-Distro([string[]]$distros) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'tray-wsl - choose distro'; $f.ClientSize = New-Object System.Drawing.Size(300,100)
    $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'; $f.TopMost = $true
    $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.DropDownStyle = 'DropDownList'; $cb.Location = '20,20'; $cb.Width = 260
    $cb.Items.AddRange($distros); $cb.SelectedIndex = 0
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'OK'; $ok.DialogResult = 'OK'; $ok.Location = '205,55'
    $f.Controls.AddRange(@($cb,$ok)); $f.AcceptButton = $ok
    try {
        if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [string]$cb.SelectedItem }
    } finally { $f.Dispose() }
}
function Resolve-Distro {
    $all = @(Get-AllDistros)
    if ($script:Distro -and $all -contains $script:Distro) { return }
    if     ($all.Count -eq 0) { throw 'No WSL distro installed.' }
    elseif ($all.Count -eq 1) { $script:Distro = $all[0] }
    else                      { $script:Distro = Select-Distro $all }
    if (-not $script:Distro) { throw 'Distro selection cancelled.' }
    Save-Config
}
Resolve-Distro

# ---------------------------------------------------------------- WSL actions
function Stop-Wsl  { Invoke-Wsl @('--shutdown') | Out-Null; Log 'wsl --shutdown' }
function Start-Wsl { Invoke-Wsl @('-d', $script:Distro, '-e', 'true') | Out-Null; Log "booted $script:Distro" }

# ---------------------------------------------------------------- icons (rendered, no asset files)
function New-PenguinIcon([bool]$awake) {
    $bmp = New-Object System.Drawing.Bitmap 32,32
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $bg = if ($awake) { [System.Drawing.Color]::FromArgb(46,204,113) }
          else        { [System.Drawing.Color]::FromArgb(127,140,141) }
    $brush = New-Object System.Drawing.SolidBrush $bg
    $g.FillEllipse($brush, 1,1,30,30)
    $font = New-Object System.Drawing.Font('Segoe UI Emoji',17,[System.Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object System.Drawing.StringFormat; $sf.Alignment='Center'; $sf.LineAlignment='Center'
    $g.DrawString([char]::ConvertFromUtf32(0x1F427), $font, [System.Drawing.Brushes]::White,
        (New-Object System.Drawing.RectangleF(0,0,32,32)), $sf)
    if (-not $awake) {
        $zf = New-Object System.Drawing.Font('Segoe UI',13,[System.Drawing.FontStyle]::Bold,[System.Drawing.GraphicsUnit]::Pixel)
        $g.DrawString('z', $zf, [System.Drawing.Brushes]::White, 17,-3)
        $zf.Dispose()
    }
    $g.Dispose(); $brush.Dispose(); $font.Dispose(); $sf.Dispose()
    $handle = $bmp.GetHicon()
    try { [System.Drawing.Icon]::FromHandle($handle).Clone() }
    finally { [void][TrayWslNative]::DestroyIcon($handle); $bmp.Dispose() }
}
$script:IconAwake = New-PenguinIcon $true
$script:IconSleep = New-PenguinIcon $false

# ---------------------------------------------------------------- tray
$ni   = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miSwitch = $menu.Items.Add('Switch WSL on')      # text set dynamically in Refresh-Ui
$menu.Items.Add('-') | Out-Null
$miAuto   = $menu.Items.Add('Start with Windows')
$menu.Items.Add('-') | Out-Null
$miExit   = $menu.Items.Add('Exit')
$ni.ContextMenuStrip = $menu
$ni.Visible = $true

$script:AutoOn = Test-Autostart   # cached; refreshing via Get-ScheduledTask every tick is slow

function Refresh-Ui {
    $up = Test-WslUp
    $ni.Icon = if ($up) { $script:IconAwake } else { $script:IconSleep }
    $state = if ($up) { $mb = Get-WslRamMB; if ($mb) { "Awake - ${mb} MB" } else { 'Awake' } } else { 'Sleeping' }
    $ni.Text = "WSL: $state"
    $miSwitch.Text  = if ($up) { 'Switch WSL off' } else { 'Switch WSL on' }
    $miAuto.Checked = $script:AutoOn
}

# Each correction that doesn't stick widens the cooldown (15s -> 30 -> 60 ...
# capped 5m). Five continuous healthy minutes reset it, not a single healthy poll.
$script:LastAct   = [datetime]::MinValue
$script:Strikes   = 0
$script:StableSince = $null
$WdBaseSec = 15; $WdCapSec = 300

function Set-Desired([string]$state) {
    $script:Desired = $state
    $script:Strikes = 0
    $script:LastAct = [datetime]::MinValue
    $script:StableSince = $null
    Enforce-Desired -Immediate
    Refresh-Ui
}
function Enforce-Desired([switch]$Immediate) {
    $up = Test-WslUp
    $wrong = (($script:Desired -eq 'off' -and $up) -or ($script:Desired -eq 'on' -and -not $up))
    $now = Get-Date
    if (-not $wrong) {
        if ($null -eq $script:StableSince) { $script:StableSince = $now }
        if (($now - $script:StableSince).TotalSeconds -ge $WdCapSec) { $script:Strikes = 0 }
        return
    }
    $script:StableSince = $null
    $cool = [Math]::Min($WdBaseSec * [Math]::Pow(2, [Math]::Max(0, $script:Strikes - 1)), $WdCapSec)
    if (-not $Immediate -and ($now - $script:LastAct).TotalSeconds -lt $cool) { return }
    # Count attempts before invoking WSL, so failures also receive backoff.
    $script:LastAct = $now
    $script:Strikes = [Math]::Min($script:Strikes + 1, 6)
    if ($script:Desired -eq 'off') { Stop-Wsl } else { Start-Wsl }
    Log ("enforce {0}: correction #{1}" -f $script:Desired, $script:Strikes)
}

$doToggle = {
    try { if (Test-WslUp) { Set-Desired 'off' } else { Set-Desired 'on' } }
    catch {
        Log "toggle error: $($_.Exception.Message)"
        $ni.Text = 'WSL: action failed - see tray-wsl.log'
        $ni.ShowBalloonTip(5000, 'tray-wsl', $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
    }
}
$miSwitch.add_Click($doToggle)

$miAuto.add_Click({
    try {
        if ($script:AutoOn) {
            Remove-Autostart; $script:AutoOn = $false
            [System.Windows.Forms.MessageBox]::Show('Autostart removed.','Start with Windows') | Out-Null
        } else {
            Install-Autostart; $script:AutoOn = $true
            [System.Windows.Forms.MessageBox]::Show(
                'Added: starts at login and adopts the current WSL state, no UAC.',
                'Start with Windows') | Out-Null
        }
        Refresh-Ui
    } catch {
        Log "autostart error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Autostart failed') | Out-Null
    }
})

$miExit.add_Click({ [System.Windows.Forms.Application]::Exit() })

# Single timer: refresh icon + run the watchdog every 5s so status stays truthful
# and the desired state is re-enforced even when a service wakes WSL behind our back.
# The watchdog always enforces while the app runs; exit the app to stop enforcing.
# First run (no persisted off/on): adopt the current state so launch never flips WSL.
# No persisted desired state: adopt the current WSL state on launch, so starting the
# app never flips WSL - only your toggle does. Exit the app to stop the watchdog.
$script:Desired = if (Test-WslUp) { 'on' } else { 'off' }
Refresh-Ui
Enforce-Desired -Immediate
$tick = New-Object System.Windows.Forms.Timer
$tick.Interval = 5000
$tick.add_Tick({
    try { Enforce-Desired; Refresh-Ui }
    catch { Log "tick error: $($_.Exception.Message)"; $ni.Text = 'WSL: status/action failed - see tray-wsl.log' }
})
$tick.Start()

[System.Windows.Forms.Application]::Run()
} catch {
    Log "startup error: $($_.Exception.Message)"
    throw
} finally {
    if ($tick) { $tick.Stop(); $tick.Dispose() }
    if ($ni) { $ni.Visible = $false; $ni.Dispose() }
    if ($menu) { $menu.Dispose() }
    if ($script:IconAwake) { $script:IconAwake.Dispose() }
    if ($script:IconSleep) { $script:IconSleep.Dispose() }
    if ($ownsInstance) { $instance.ReleaseMutex() }
    $instance.Dispose()
}
