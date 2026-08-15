@echo off
setlocal EnableExtensions
rem Self-contained uFVS release launcher. Do not replace this with a PATH lookup.
cd /d "%~dp0"
set "UFVS_RELEASE=1"
set "R_HOME=%~dp0runtime\R"
set "R_LIBS_USER=%~dp0library"
if not defined UFVS_PORT set "UFVS_PORT=0"
if not exist "%~dp0runtime\R\bin\Rscript.exe" (
  echo The uFVS bundled R runtime is missing. Re-extract the downloaded ZIP.
  pause
  exit /b 1
)
"%~dp0runtime\R\bin\Rscript.exe" "%~dp0tools\launch.R"
if errorlevel 1 (
  echo.
  echo uFVS stopped with an error. The window is being kept open so you can read it.
  if /I not "%UFVS_NO_PAUSE%"=="1" pause
)
