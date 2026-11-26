@echo off
rem Double-click to tidy the desktop. Extra switches pass through, e.g. Arrange-Desktop.cmd -DryRun
"%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "exit" >nul 2>&1
if %errorlevel%==0 (set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe") else (set "PS=powershell.exe")
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Arrange-Desktop.ps1" %*
if errorlevel 1 pause
