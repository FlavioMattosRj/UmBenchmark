@echo off
reg delete "HKCU\Software\Microsoft\Command Processor" /v AutoRun /f >nul 2>&1
if errorlevel 1 (
    echo AutoRun do CMD ja estava desligado.
) else (
    echo AutoRun do CMD removido.
)
