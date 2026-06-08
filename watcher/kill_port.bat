@echo off
setlocal
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":19850" ^| findstr "LISTENING"') do (
    echo killing PID %%a
    taskkill /F /PID %%a 2>nul
)
timeout /t 2 /nobreak >nul
echo ===REMAINING===
netstat -ano | findstr ":19850" | findstr "LISTENING"
