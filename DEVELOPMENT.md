# Development

Use Windows PowerShell 5.1 and Pester 3.4 or 4.x:

```powershell
$r = Invoke-Pester -Script tests/*.Tests.ps1 -PassThru
if ($r.FailedCount) { throw 'Tests failed' }
./tests/tray-wsl.Smoke.ps1
./tests/install.Smoke.ps1
./tray-wsl.ps1 -SelfCheck
./scripts/package.ps1
```

Tests simulate WSL actions. `-SelfCheck` reads the live running distro list without
changing WSL. The installer smoke test uses a temporary folder and a uniquely
named logon task, tests installation and update, then stops the test tray and
removes the task and files.

Push a `v*` tag to run the Windows GitHub Actions job, test, and publish
`install.ps1`, `tray-wsl.zip`, and `SHA256SUMS`. Pull requests test and package
without publishing. Runtime config, logs, test output, and `dist/` stay out of Git.
An existing tag can also be released manually through **Actions > Test and release > Run workflow**.

`bootstrap.ps1` is published as the release's `install.ps1`. It downloads and
verifies the latest release, then runs the installer inside `tray-wsl.zip`.
The public release works without GitHub authentication or extra tools.

Installation lives in `%LOCALAPPDATA%\tray-wsl`. The installer stops the tray
without changing WSL, copies release files while preserving config, chooses a
distro, registers the current user's logon task, and launches the hidden tray.
It waits for the running tray before reporting success. `-Configure` only selects
a distro; `-Stop` exits the tray; `-Install` and `-Uninstall` manage autostart.

Status is polled every five seconds. Commands time out after ten seconds, so a
slow command can briefly delay the menu. Corrections back off from 15 seconds to
five minutes; five continuous healthy minutes or an explicit toggle reset them.
The app does not configure disk compaction or guarantee reclaimed disk space.
