@echo off
rem Lance le serveur Cockpit PC (silencieux) et ouvre le navigateur.
rem Fonctionne sur n'importe quel Windows avec PowerShell 5+.
setlocal
set "DIR=%~dp0"
set "PORT=8219"

rem Verifie si un serveur tourne deja sur ce port.
netstat -ano -p tcp | findstr /r ":8219 .*LISTENING" >nul 2>&1
if not errorlevel 1 (
    echo Le serveur Cockpit PC tourne deja. Ouverture du navigateur...
) else (
    rem Lance le serveur en arriere-plan, sans fenetre.
    start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%DIR%serveur.ps1"
    rem Laisse-lui une seconde pour demarrer.
    timeout /t 1 /nobreak >nul
)

start "" "http://127.0.0.1:%PORT%/"
endlocal
