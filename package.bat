@echo off
for %%a in ("%~dp0\.") do set "modname=%%~nxa"

del %modname%.zip
7z a -tzip %modname%.zip -w . -x!*.git* -x!*.bat -x!*.vscode* -x!*.md -x!*.kiro* -x!*refs*
