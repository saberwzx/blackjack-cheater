@echo off
cd /d "%~dp0"
python tools\build.py
if errorlevel 1 pause
