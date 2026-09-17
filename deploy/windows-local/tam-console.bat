@echo off
rem TAM control console launcher: ensure server running, then open browser
cd /d E:\tam\run
netstat -ano | findstr LISTENING | findstr :8127 >nul 2>&1
if errorlevel 1 (
  start "TAM-console" /min node control-center.mjs
  timeout /t 2 /nobreak >nul
)
start "" http://127.0.0.1:8127
exit
