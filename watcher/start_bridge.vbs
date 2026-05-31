' Claude Bridge v11 — Silent Launcher
' This script starts the bridge watcher silently (no window)
' Place in Startup folder to auto-start on login

Set WshShell = CreateObject("WScript.Shell")
bridgeDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)

' Kill existing watchers first
WshShell.Run "powershell -NoProfile -Command ""Get-CimInstance Win32_Process -Filter 'Name=powershell.exe' | Where-Object { $_.CommandLine -like '*watcher*ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }""", 0, True

' Start watcher (0 = hidden window)
WshShell.Run "powershell -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File """ & bridgeDir & "\watcher.ps1""", 0, False
