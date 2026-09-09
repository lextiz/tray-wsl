# tray-wsl

A little penguin in your Windows tray to switch WSL on or off and keep it that way.
Green means awake; grey means sleeping.

## Install

Open **PowerShell**, paste this line, and press Enter:

```powershell
irm https://github.com/lextiz/tray-wsl/releases/latest/download/install.ps1 | iex
```

Everything installs and starts automatically, including autostart. If you have
several WSL distributions, choose one when asked. Run the same line to update.
Requires Windows with WSL already installed. No administrator window needed.

## Use

Right-click the penguin to switch WSL, change **Start with Windows**, or **Exit**.
**Switching off stops all WSL distributions and their running work.** Exiting
leaves WSL as it is.

Files and logs: `%LOCALAPPDATA%\tray-wsl`.
[Releases](https://github.com/lextiz/tray-wsl/releases) · [Development](DEVELOPMENT.md) · [MIT](LICENSE)
