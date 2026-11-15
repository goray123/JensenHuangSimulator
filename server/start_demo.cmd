@echo off
rem Demo: this PC hosts as the husband over WebSocket; browser guests join through the tunnel QR.
cd /d "%~dp0"
if "%GODOT%"=="" set "GODOT=%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64.exe"
start "" "%GODOT%" --path .. -- --web-host
node gateway.js --tunnel %*
