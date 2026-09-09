' Launches tray-wsl with no console window at all (window style 0).
' Use this (double-click or `wscript tray-wsl-hidden.vbs`) instead of
' running the .ps1 directly, to avoid any PowerShell window flashing.
Dim fso, dir, ps1, sh
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = dir & "\tray-wsl.ps1"
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
