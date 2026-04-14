@echo off
REM blackjack-video-sync launcher (.cmd backup if .vbs is blocked by AV)
REM Brief console flash, then the GUI opens.
cd /d "%~dp0"
start "" pwsh.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0video_gui_v1.ps1"
