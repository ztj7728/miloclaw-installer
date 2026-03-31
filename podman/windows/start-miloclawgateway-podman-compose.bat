@echo off
setlocal

set MACHINE=podman-machine-default
set COMPOSE_FILE=%USERPROFILE%\miloclaw\compose.yml
set LOG=%USERPROFILE%\start-podman.log

echo.>>"%LOG%"
echo [%date% %time%] ===== Start Podman Machine + Compose =====>>"%LOG%"

timeout /t 10 /nobreak >nul

podman machine start %MACHINE% >>"%LOG%" 2>&1

timeout /t 8 /nobreak >nul

podman compose -f "%COMPOSE_FILE%" up -d openclaw-gateway >>"%LOG%" 2>&1

echo [%date% %time%] Done.>>"%LOG%"

endlocal