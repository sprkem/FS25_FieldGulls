@echo off
for %%a in ("%~dp0\.") do set "modname=%%~nxa"
rmdir /s /q "%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\%modname%\"
move /y "%modname%.zip" "%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\"