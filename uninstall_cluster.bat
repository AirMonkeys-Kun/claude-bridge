@echo off
cd /d "%~dp0"
echo === Uninstall Claude Bridge Cluster ===
echo.

:: Stop the cluster
echo [1/3] Stopping cluster...
if exist "%~dp0cluster\stop_cluster.bat" call "%~dp0cluster\stop_cluster.bat"

:: Remove Registry Run key
echo [2/3] Removing Registry Run key...
reg delete HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run /v ClaudeBridge /f >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo   OK: Run key removed
) else (
    echo   OK: No Run key found
)

:: Remove firewall rule
echo [3/3] Removing firewall rule...
netsh advfirewall firewall delete rule name="Claude Bridge Cluster" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo   OK: Firewall rule removed
) else (
    echo   OK: No firewall rule found
)

echo.
echo === Uninstall Complete ===
pause
