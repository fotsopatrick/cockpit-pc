@echo off
rem Arrete le serveur Cockpit PC.
set "DIR=%~dp0"
for /f "tokens=1" %%p in ('type "%DIR%logs\serveur.pid" 2^>nul') do set "PID=%%p"
if defined PID (
    taskkill /PID %PID% /F >nul 2>&1
    echo Serveur arrete.
) else (
    echo Aucun pid enregistre - serveur peut-etre deja arrete.
)
timeout /t 2 /nobreak >nul
endlocal
