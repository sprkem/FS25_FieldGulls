@echo off
for %%a in ("%~dp0\.") do set "modname=%%~nxa"
del "%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\%modname%.zip"
rmdir /s /q "%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\%modname%\"
move /y "%modname%.zip" "%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\"
7z x "%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\%modname%.zip" -o"%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\%modname%\"
del "%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\%modname%.zip"