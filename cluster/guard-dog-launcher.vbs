Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""D:\zebbingo\tools\claude-bridge\cluster\guard-dog.ps1""", 0, False
