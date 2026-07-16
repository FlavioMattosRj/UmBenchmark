@echo off
set "LOCKDIR=%~dp0.varamb.lock"

:AcquireLock
mkdir "%LOCKDIR%" 2>nul
if errorlevel 1 (
    ping -n 1 -w 50 127.0.0.1 >nul
    goto AcquireLock
)

echo %CMDCMDLINE%>>"%~dp0CmdCmdLines.log"
set >> "%~dp0VarAmb.txt"

rmdir "%LOCKDIR%"
