@echo off
rem Demo: this PC referees the match (its window shows it); the first two browser players are husband and wife.
cd /d "%~dp0"
if "%GODOT%"=="" set "GODOT=%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64.exe"
start "" "%GODOT%" --path .. -- --server
node gateway.js --tunnel %*
