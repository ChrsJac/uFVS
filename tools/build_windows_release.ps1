param(
  [string]$OutDir = "",
  [string]$RHome = "",
  [string]$EngineDir = "",
  [switch]$SkipSelfTest
)

# Build a self-contained Windows x86-64 release. Run this on Windows with a
# portable Windows R tree and native Windows FVS executables from the same
# machine; never stage packages copied from macOS or Linux.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Version = "0.1.0"
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

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("ufvs-windows-release-" + [guid]::NewGuid().ToString("N"))
$Stage = Join-Path $TempRoot ("uFVS-" + $Version + "-Windows-x64")

function Copy-DirectoryContents([string]$Source, [string]$Destination) {
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

try {
  New-Item -ItemType Directory -Force -Path (Join-Path $Stage "tools") | Out-Null
  Copy-Item (Join-Path $Root "app.R"), (Join-Path $Root "README.md"), (Join-Path $Root "NOTICE.md") -Destination $Stage -Force
  Copy-DirectoryContents (Join-Path $Root "R") (Join-Path $Stage "R")
  Copy-DirectoryContents (Join-Path $Root "config") (Join-Path $Stage "config")
  Copy-DirectoryContents (Join-Path $Root "www") (Join-Path $Stage "www")
  if (Test-Path (Join-Path $Root "docs")) {
    Copy-DirectoryContents (Join-Path $Root "docs") (Join-Path $Stage "docs")
  }
  Copy-Item (Join-Path $Root "tools\launch.R") -Destination (Join-Path $Stage "tools\launch.R") -Force
  Copy-Item (Join-Path $Root "tools\windows_release_launcher.bat") -Destination (Join-Path $Stage "Start uFVS.bat") -Force
  Copy-DirectoryContents $EngineDir (Join-Path $Stage "engine")

  # R for Windows is designed to be relocatable when its complete tree is
  # copied. Its Rscript.exe is invoked directly by the release launcher.
  Copy-DirectoryContents $RHome (Join-Path $Stage "runtime\R")

  & $BuilderRscript (Join-Path $Root "tools\stage_r_packages.R") --target (Join-Path $Stage "library")
  if ($LASTEXITCODE -ne 0) { throw "R package staging failed." }

  & $BuilderRscript (Join-Path $Root "tools\write_build_info.R") `
    --root $Stage --platform "Windows" --architecture "x86_64" --engine-dir (Join-Path $Stage "engine")
  if ($LASTEXITCODE -ne 0) { throw "Build metadata generation failed." }

  if (!$SkipSelfTest) {
    $oldRelease = $env:UFVS_RELEASE
    $oldRHome = $env:R_HOME
    $oldLibs = $env:R_LIBS_USER
    $env:UFVS_RELEASE = "1"
    $env:R_HOME = Join-Path $Stage "runtime\R"
    $env:R_LIBS_USER = Join-Path $Stage "library"
    try {
      $StagedRscript = Join-Path $Stage "runtime\R\bin\Rscript.exe"
      & $StagedRscript (Join-Path $Root "tools\release_self_test.R") --root $Stage
      if ($LASTEXITCODE -ne 0) { throw "Staged Windows release self-test failed." }
    } finally {
      $env:UFVS_RELEASE = $oldRelease
      $env:R_HOME = $oldRHome
      $env:R_LIBS_USER = $oldLibs
    }
  }

  $Zip = Join-Path $OutDir "uFVS-Windows-x64.zip"
  if (Test-Path $Zip) { Remove-Item -LiteralPath $Zip -Force }
  Compress-Archive -Path (Join-Path $Stage "*") -DestinationPath $Zip -CompressionLevel Optimal
  Write-Host "Created $Zip"
} finally {
  if (Test-Path $TempRoot) { Remove-Item -LiteralPath $TempRoot -Recurse -Force }
}
