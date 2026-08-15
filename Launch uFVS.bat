@echo off
setlocal EnableExtensions
rem ------------------------------------------------------------------------------
rem Start uFVS on Windows. Double-click this file from the unpacked uFVS folder.
rem R and the required R packages are the only prerequisites for inventory work.
rem An official Windows FVS executable is additionally required for projections.
rem ------------------------------------------------------------------------------

cd /d "%~dp0"

set "RSCRIPT="
set "PF86=%ProgramFiles(x86)%"
for /f "delims=" %%I in ('where Rscript.exe 2^>nul') do if not defined RSCRIPT set "RSCRIPT=%%I"
if not defined RSCRIPT if defined ProgramFiles for /d %%D in ("%ProgramFiles%\R\R-*") do if exist "%%D\bin\Rscript.exe" if not defined RSCRIPT set "RSCRIPT=%%D\bin\Rscript.exe"
if not defined RSCRIPT if defined PF86 for /d %%D in ("%PF86%\R\R-*") do if exist "%%D\bin\Rscript.exe" if not defined RSCRIPT set "RSCRIPT=%%D\bin\Rscript.exe"

if not defined RSCRIPT (
  echo R is not installed, or Rscript.exe is not on PATH.
  echo Install R from https://cran.r-project.org/bin/windows/base/ and try again.
  echo.
  pause
  exit /b 1
)

for /f "delims=" %%M in ('"%RSCRIPT%" tools\launch.R --check 2^>nul') do set "MISSING=%%M"
if defined MISSING (
  echo uFVS needs these R packages: %MISSING%
  set /p "ANSWER=Install them in your user R library now? [y/N] "
  if /i "%ANSWER%"=="y" (
    "%RSCRIPT%" -e "install.packages(strsplit('%MISSING%',' ')[[1]], repos='https://cloud.r-project.org')"
    if errorlevel 1 (
      echo Package installation failed.
      pause
      exit /b 1
    )
  ) else (
    echo Cannot start without the required packages.
    pause
    exit /b 1
  )
)

echo Starting uFVS. Your browser will open shortly.
echo Close this window or press Ctrl+C to stop the application.
echo.
"%RSCRIPT%" tools\launch.R

echo.
pause
