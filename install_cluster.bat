@echo off
cd /d "%~dp0"
echo === Claude Bridge Cluster Installation ===
echo.

:: Check admin rights
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Administrator rights required.
    echo Right-click this batch file and select "Run as administrator".
    pause
    exit /b 1
)

:: ── Add Registry Run key (HKLM for SYSTEM context) ──
echo [1/3] Adding Registry Run key...
set BOOT_SCRIPT=%~dp0start_cluster_boot.bat
reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run /v ClaudeBridge /t REG_SZ /d "%BOOT_SCRIPT%" /f
if %ERRORLEVEL% EQU 0 (
    echo   OK: Run key added
    reg query HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run /v ClaudeBridge
) else (
    echo   WARNING: Could not add Run key — try running as Administrator
)

:: ── Add firewall rule for named pipe IPC ──
echo [2/3] Adding firewall rule (named pipe IPC)...
netsh advfirewall firewall add rule name="Claude Bridge Cluster" dir=in action=allow program="%%SystemRoot%%\system32\WindowsPowerShell\v1.0\powershell.exe" enable=yes profile=any description="Named pipe IPC for Claude Bridge workers" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo   OK: Firewall rule added
) else (
    echo   Note: Firewall rule may already exist or not needed for loopback IPC
)

:: ── Test launch ──
echo [3/3] Testing cluster launch...
call "%~dp0cluster\launch_workers.bat"

echo.
echo === Installation Complete ===
echo.
echo Claude Bridge cluster will auto-start on next boot.
echo To start now, use: launch_workers.bat  (in the cluster folder)
echo To uninstall, run:  uninstall_cluster.bat
echo.
pause
