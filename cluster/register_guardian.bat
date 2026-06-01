@echo off
set TASK_NAME=BridgeGuardian-V4
set SCRIPT=%~dp0scheduled_guardian_v4.bat
:: Remove old task if exists
schtasks /Delete /TN %TASK_NAME% /F 2>nul
:: Register new task - every 5 minutes, SYSTEM, highest
schtasks /Create /TN %TASK_NAME% /TR "%SCRIPT%" /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /F
:: Show result
echo.
schtasks /Query /FO LIST /V /TN %TASK_NAME%
:: Test run
echo.
schtasks /Run /TN %TASK_NAME% /I
echo Guardian task registered and triggered.
