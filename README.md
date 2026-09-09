# tray-wsl

A tiny Windows tray app to manage WSL2 conveniently:

- **Toggle WSL on/off** from the tray menu.
- **Watchdog** enforces that state with bounded retries and backoff. It
  adopts the current state on launch; exit the app to stop enforcing.
- **Live status**: green penguin = awake, grey = sleeping. Tooltip shows the WSL
  VM memory when awake.
- **Start on boot** (per-user logon task, no UAC).

Single PowerShell file + a `.vbs` launcher (runs with no console window). Zero
dependencies, unelevated, nothing to compile.

Requires Windows PowerShell 5.1, an installed WSL distribution, and Windows
Script Host for the optional hidden launcher. Keep the files in a writable
Windows folder. Only one tray instance runs per user in each Windows session.

## Install

From the folder where you want it to live (autostart points here), run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tray-wsl.ps1 -Install
if ($LASTEXITCODE -eq 0) {
    $launcher = (Resolve-Path .\tray-wsl-hidden.vbs).Path
    Start-Process wscript.exe -ArgumentList ('"{0}"' -f $launcher) -WindowStyle Hidden
}
```

This registers autostart and launches the tray. The distro is auto-detected; if
you have several installed, a dropdown asks which one (saved to config).

Run without autostart: double-click `tray-wsl-hidden.vbs`.

Remove autostart:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tray-wsl.ps1 -Uninstall
```

Autostart uses a limited, interactive logon task for the current Windows account.
Organizational policy may prevent task registration; failures are reported.

## Use

Right-click the tray penguin: **Switch WSL on/off**, **Start with Windows**,
**Exit**. Switching off runs `wsl --shutdown`, which stops **all distributions
and their running work**, and keeps attempting shutdown while the tray runs.
See [Microsoft's shutdown documentation](https://learn.microsoft.com/en-us/windows/wsl/basic-commands#shutdown).

Awake means any distribution is running. Switching on boots the configured
distribution when none are running. The app adopts the live state on every
launch; it does not restore an on/off preference from a previous login. Exiting
stops enforcement without changing WSL's current state. This app does not
configure disk compaction or guarantee reclaimed disk space.

Status is polled every five seconds. Individual WSL commands time out after ten
seconds; a slow command can briefly delay the menu. Failed or repeated corrections
wait 15, 30, 60, 120, 240, then 300 seconds. Backoff resets after five continuous
minutes in the desired state, or an explicit toggle. Errors appear in the log
and tray tooltip; user-initiated action failures also show a notification.

## Config

`tray-wsl.config.json` (next to the script) holds only the distro:

```json
{ "Distro": "Ubuntu" }
```

Delete it to re-run auto-detection. A saved distro that was removed is detected
again. Cancelling the selector exits without saving. Logs: `tray-wsl.log`.
Config and logs are ignored by Git.

## Verify

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tray-wsl.ps1 -SelfCheck
```

Confirms `wsl --list --running` decodes correctly (UTF-16LE) and prints
`Status: Awake` / `Sleeping`.

Regression tests use Pester 3.4 or 4.x in Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command 'Import-Module Pester -MaximumVersion 4.99; $r = Invoke-Pester -Script ./tests/tray-wsl.Tests.ps1 -PassThru; if ($r.FailedCount) { exit 1 }'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\tray-wsl.Smoke.ps1
```

Tests simulate WSL actions and do not shut down WSL or install autostart. The
smoke test briefly creates a test tray icon and exercises on/off and exit.

Verified on Windows PowerShell 5.1: 15 regression tests, the complete tray smoke
test, and a live read-only WSL self-check. Real shutdown/restart and logon task
registration were not exercised against the developer's running environment.

## License

MIT. See [LICENSE](LICENSE).
