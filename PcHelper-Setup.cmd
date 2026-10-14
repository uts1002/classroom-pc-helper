@echo off
rem PC helper installer: downloads the latest release from GitHub and installs it for this user.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; $f = Join-Path $env:TEMP 'ClassroomPcHelper-install.ps1'; Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/uts1002/classroom-pc-helper/releases/latest/download/install.ps1' -OutFile $f; & $f"
pause
