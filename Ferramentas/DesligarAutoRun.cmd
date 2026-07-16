@echo off
reg query "HKCU\Software\Microsoft\Command Processor" /v AutoRun >nul 2>&1
if errorlevel 1 (
    echo AutoRun do CMD ja estava desligado.
) else (
    reg delete "HKCU\Software\Microsoft\Command Processor" /v AutoRun /f >nul
    echo AutoRun do CMD removido.
)
