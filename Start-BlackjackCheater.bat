@echo off
cd /d "%~dp0"
if not exist "runtime\love-11.5-win64\love.exe" (
  echo Missing LOVE runtime. See README.md.
  pause
  exit /b 1
)
start "Blackjack Cheater" "runtime\love-11.5-win64\love.exe" "%~dp0."
