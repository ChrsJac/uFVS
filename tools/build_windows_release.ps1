param(
  [string]$OutDir = "",
  [string]$RHome = "",
  [string]$EngineDir = "",
  [string]$FvsSourceRevision = "",
  [string]$FvsSourceUrl = "",
  [string]$FvsToolchain = "",
  [string]$Compiler = "",
  [switch]$SkipSelfTest
)

# Build a self-contained Windows x86-64 uFVS package.
#
#   uFVS\
#     uFVS.exe              the native launcher, compiled here from
#                           tools\windows\ufvs_launcher.c
#     app\                  the Shiny application, including launch.R
#     runtime\R\            the private R runtime
#     runtime\R-library\    the private package library
#     fvs\                  the FVS engine and every DLL it needs
#     resources\            BUILD_INFO.json, notices, docs
#
# Run this on Windows with a portable Windows R tree and native Windows FVS
# executables built on the same machine; never stage packages copied from macOS
# or Linux. Nothing in the resulting ZIP may depend on anything installed on
# this build machine, and the checks below fail the build if it does.

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Version = "0.1.0"
$PinnedFvsRevision = "a17ee9728fe3273e9526d66e66fb4a79bdba6c10"
$PinnedFvsUrl = "https://github.com/USDAForestService/ForestVegetationSimulator"
if ([string]::IsNullOrWhiteSpace($FvsSourceRevision)) {
  $FvsSourceRevision = if ($env:UFVS_FVS_SOURCE_REVISION) { $env:UFVS_FVS_SOURCE_REVISION } else { $PinnedFvsRevision }
}
if ([string]::IsNullOrWhiteSpace($FvsSourceUrl)) {
  $FvsSourceUrl = if ($env:UFVS_FVS_SOURCE_URL) { $env:UFVS_FVS_SOURCE_URL } else { $PinnedFvsUrl }
}
if ([string]::IsNullOrWhiteSpace($FvsToolchain)) {
  $FvsToolchain = if ($env:UFVS_FVS_TOOLCHAIN) { $env:UFVS_FVS_TOOLCHAIN } else { "Rtools gfortran + GNU make" }
}
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $Root "release" }
if ([string]::IsNullOrWhiteSpace($EngineDir)) { $EngineDir = Join-Path $Root "engine" }

$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ($arch -notin @("AMD64", "x86_64")) {
  throw "This script must run in a 64-bit Windows process; detected $arch."
}
if ([string]::IsNullOrWhiteSpace($RHome)) {
  throw "Supply -RHome with a tested portable Windows R directory."
}
$RHome = (Resolve-Path $RHome).Path
$BuilderRscript = Join-Path $RHome "bin\Rscript.exe"
if (!(Test-Path $BuilderRscript)) { throw "Rscript.exe was not found below $RHome." }

$EngineDir = (Resolve-Path $EngineDir).Path
$engineExe = @(Get-ChildItem -LiteralPath $EngineDir -Filter "FVS*.exe" -File)
if ($engineExe.Count -eq 0) {
  throw "No Windows FVS*.exe was found in $EngineDir."
}

# --- locate the C compiler for the launcher ----------------------------------
# Rtools ships MinGW-w64 gcc, which is the supported way to build uFVS.exe.
function Find-Tool([string]$name, [string]$explicit) {
  if (-not [string]::IsNullOrWhiteSpace($explicit)) {
    if (Test-Path $explicit) { return (Resolve-Path $explicit).Path }
    throw "The compiler '$explicit' does not exist."
  }
  $found = Get-Command $name -ErrorAction SilentlyContinue
  if ($found) { return $found.Source }
  foreach ($candidate in @(
      "C:\rtools45\x86_64-w64-mingw32.static.posix\bin\$name.exe",
      "C:\rtools45\usr\bin\$name.exe",
      "C:\rtools44\x86_64-w64-mingw32.static.posix\bin\$name.exe",
      "C:\rtools44\usr\bin\$name.exe",
      "C:\rtools43\mingw64\bin\$name.exe")) {
    if (Test-Path $candidate) { return $candidate }
  }
  return $null
}

$Gcc = Find-Tool "gcc" $Compiler
if (-not $Gcc) {
  throw ("No C compiler was found. uFVS.exe is a native launcher and has to be " +
         "compiled. Install Rtools (which provides MinGW-w64 gcc), put it on PATH, " +
         "or pass -Compiler with the full path to gcc.exe.")
}
$Objdump = Find-Tool "objdump" ""

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("ufvs-windows-release-" + [guid]::NewGuid().ToString("N"))
$Stage = Join-Path $TempRoot ("uFVS-" + $Version + "-Windows-x64")

function Copy-DirectoryContents([string]$Source, [string]$Destination) {
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

try {
  $AppDir = Join-Path $Stage "app"
  $RuntimeDir = Join-Path $Stage "runtime"
  $LibraryDir = Join-Path $RuntimeDir "R-library"
  $FvsDir = Join-Path $Stage "fvs"
  $ResourcesDir = Join-Path $Stage "resources"
  New-Item -ItemType Directory -Force -Path $AppDir, $RuntimeDir, $FvsDir, $ResourcesDir,
    (Join-Path $ResourcesDir "THIRD_PARTY") | Out-Null

  # --- the application --------------------------------------------------------
  Copy-Item (Join-Path $Root "app.R") -Destination (Join-Path $AppDir "app.R") -Force
  Copy-Item (Join-Path $Root "tools\launch.R") -Destination (Join-Path $AppDir "launch.R") -Force
  Copy-DirectoryContents (Join-Path $Root "R") (Join-Path $AppDir "R")
  Copy-DirectoryContents (Join-Path $Root "config") (Join-Path $AppDir "config")
  Copy-DirectoryContents (Join-Path $Root "www") (Join-Path $AppDir "www")

  # --- read-only resources ----------------------------------------------------
  Copy-Item (Join-Path $Root "README.md"), (Join-Path $Root "NOTICE.md"),
            (Join-Path $Root "LICENSE"), (Join-Path $Root "CITATION.cff") `
            -Destination $ResourcesDir -Force
  Copy-DirectoryContents (Join-Path $Root "THIRD_PARTY") (Join-Path $ResourcesDir "THIRD_PARTY")
  if (Test-Path (Join-Path $Root "docs")) {
    Copy-DirectoryContents (Join-Path $Root "docs") (Join-Path $ResourcesDir "docs")
  }

  # --- the FVS engine ---------------------------------------------------------
  Copy-DirectoryContents $EngineDir $FvsDir
  # The source checkout keeps a macOS engine and a note about it in engine\;
  # neither belongs in a Windows package.
  Get-ChildItem -LiteralPath $FvsDir -File |
    Where-Object { $_.Name -eq "README-WINDOWS.txt" -or $_.Extension -eq ".dylib" -or
                   ($_.Extension -eq "" -and $_.Name -like "FVS*") } |
    Remove-Item -Force -ErrorAction SilentlyContinue

  # --- the private R runtime --------------------------------------------------
  # R for Windows is relocatable when its complete tree is copied, and its
  # Rscript.exe resolves R_HOME from its own location.
  Copy-DirectoryContents $RHome (Join-Path $RuntimeDir "R")

  & $BuilderRscript (Join-Path $Root "tools\stage_r_packages.R") --target $LibraryDir
  if ($LASTEXITCODE -ne 0) { throw "R package staging failed." }

  & $BuilderRscript (Join-Path $Root "tools\write_third_party_inventory.R") `
    --library $LibraryDir --target (Join-Path $ResourcesDir "THIRD_PARTY")
  if ($LASTEXITCODE -ne 0) { throw "Third-party inventory generation failed." }

  # --- compile the launcher ---------------------------------------------------
  # Static linking so uFVS.exe itself needs no MinGW runtime DLLs beside it.
  $LauncherExe = Join-Path $Stage "uFVS.exe"
  $LauncherSource = Join-Path $Root "tools\windows\ufvs_launcher.c"
  Write-Host "Compiling uFVS.exe with $Gcc"
  & $Gcc -O2 -municode -mwindows -static -static-libgcc `
    -o $LauncherExe $LauncherSource -lws2_32
  if ($LASTEXITCODE -ne 0 -or !(Test-Path $LauncherExe)) {
    throw "Compiling the uFVS.exe launcher failed."
  }

  # --- native dependency audit ------------------------------------------------
  # A packaged FVS engine that resolves libgfortran from the build machine's
  # Rtools installation works here and fails on a user's computer. Copy every
  # non-system DLL the engine needs into fvs\, where Windows looks first.
  if ($Objdump) {
    $systemDlls = @(
      "kernel32.dll", "user32.dll", "gdi32.dll", "advapi32.dll", "shell32.dll",
      "ole32.dll", "oleaut32.dll", "msvcrt.dll", "ws2_32.dll", "comdlg32.dll",
      "comctl32.dll", "shlwapi.dll", "version.dll", "winmm.dll", "wsock32.dll",
      "crypt32.dll", "bcrypt.dll", "ntdll.dll", "rpcrt4.dll", "secur32.dll",
      "iphlpapi.dll", "netapi32.dll", "userenv.dll", "psapi.dll", "dbghelp.dll",
      "imm32.dll", "setupapi.dll", "uxtheme.dll", "api-ms-win-crt-runtime-l1-1-0.dll"
    )
    $compilerBin = Split-Path -Parent $Gcc
    $searchDirs = @($compilerBin, (Join-Path $RHome "bin\x64"), (Join-Path $RHome "bin"), $FvsDir)

    $pending = New-Object System.Collections.Queue
    Get-ChildItem -LiteralPath $FvsDir -File |
      Where-Object { $_.Extension -in @(".exe", ".dll") } |
      ForEach-Object { $pending.Enqueue($_.FullName) }

    $inspected = @{}
    $copied = @()
    while ($pending.Count -gt 0) {
      $target = $pending.Dequeue()
      if ($inspected.ContainsKey($target.ToLower())) { continue }
      $inspected[$target.ToLower()] = $true

      $dumped = & $Objdump -p $target 2>$null
      $needed = $dumped |
        Select-String -Pattern '^\s*DLL Name:\s*(.+)$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }

      foreach ($dll in $needed) {
        if ($systemDlls -contains $dll.ToLower()) { continue }
        if ($dll.ToLower().StartsWith("api-ms-win")) { continue }
        $destination = Join-Path $FvsDir $dll
        if (Test-Path $destination) {
          $pending.Enqueue($destination)
          continue
        }
        $source = $null
        foreach ($dir in $searchDirs) {
          $candidate = Join-Path $dir $dll
          if (Test-Path $candidate) { $source = $candidate; break }
        }
        if ($source) {
          Copy-Item -LiteralPath $source -Destination $destination -Force
          $copied += $dll
          $pending.Enqueue($destination)
        } else {
          throw ("The FVS engine needs $dll, which was not found in the compiler " +
                 "or R directories. The package would not run on a computer " +
                 "without the build machine's toolchain.")
        }
      }
    }
    if ($copied.Count -gt 0) {
      Write-Host ("Bundled engine DLLs: " + ($copied -join ", "))
    } else {
      Write-Host "The FVS engine needs no non-system DLLs."
    }
  } else {
    Write-Warning ("objdump was not found, so the FVS engine's DLL dependencies " +
                   "could not be audited. Install Rtools to enable this check.")
  }

  & $BuilderRscript (Join-Path $Root "tools\write_build_info.R") `
    --root $ResourcesDir --app $AppDir --library $LibraryDir `
    --platform "Windows" --architecture "x86_64" --engine-dir $FvsDir `
    --fvs-source-revision $FvsSourceRevision --fvs-source-url $FvsSourceUrl `
    --fvs-toolchain $FvsToolchain
  if ($LASTEXITCODE -ne 0) { throw "Build metadata generation failed." }

  # --- test the package, in the launcher's own environment --------------------
  if (!$SkipSelfTest) {
    $saved = @{}
    foreach ($name in @("UFVS_RELEASE", "UFVS_APP_DIR", "UFVS_RUNTIME_DIR",
                        "UFVS_LIBRARY_DIR", "UFVS_FVS_DIR", "UFVS_RESOURCES_DIR",
                        "R_HOME", "R_LIBS_USER")) {
      $saved[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $env:UFVS_RELEASE = "1"
    $env:UFVS_APP_DIR = $AppDir
    $env:UFVS_RUNTIME_DIR = $RuntimeDir
    $env:UFVS_LIBRARY_DIR = $LibraryDir
    $env:UFVS_FVS_DIR = $FvsDir
    $env:UFVS_RESOURCES_DIR = $ResourcesDir
    $env:R_HOME = $null
    $env:R_LIBS_USER = $LibraryDir
    try {
      $StagedRscript = Join-Path $RuntimeDir "R\bin\Rscript.exe"
      & $StagedRscript (Join-Path $Root "tools\release_self_test.R")
      if ($LASTEXITCODE -ne 0) { throw "Staged Windows release self-test failed." }

      & $StagedRscript (Join-Path $Root "tools\fvs_smoke_test.R") `
        --bundle $Stage --engine (Join-Path $FvsDir "FVSsn.exe")
      if ($LASTEXITCODE -ne 0) { throw "Staged Windows FVS smoke test failed." }

      # Drive the real uFVS.exe, exactly as a double-click does.
      & $StagedRscript (Join-Path $Root "tools\release_http_smoke_test.R") `
        --launcher $LauncherExe
      if ($LASTEXITCODE -ne 0) { throw "Staged Windows launcher smoke test failed." }

      & $StagedRscript (Join-Path $Root "tools\acceptance_test.R")
      if ($LASTEXITCODE -ne 0) { throw "Staged Windows acceptance test failed." }
    } finally {
      foreach ($name in $saved.Keys) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name])
      }
    }
  }

  $Zip = Join-Path $OutDir "uFVS-Windows-x64.zip"
  if (Test-Path $Zip) { Remove-Item -LiteralPath $Zip -Force }
  # -Path $Stage (not $Stage\*) so the ZIP expands to a single uFVS folder.
  Compress-Archive -Path $Stage -DestinationPath $Zip -CompressionLevel Optimal
  Write-Host "Created $Zip"
} finally {
  if (Test-Path $TempRoot) { Remove-Item -LiteralPath $TempRoot -Recurse -Force }
}
