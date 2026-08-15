# Self-contained desktop releases

The release artifacts are ordinary ZIP files. They are not installers and do
not use cloud hosting, Docker, Electron, or a package manager at runtime.

Each ZIP contains the same uFVS R/Shiny source plus three platform-specific
payloads:

- a tested R runtime;
- the strong dependency closure of the tested R package set; and
- native FVS variant executables and their runtime libraries.

The release launcher resolves everything relative to the extracted folder. It
does not search for system R, use RStudio, install packages, or access the
Internet. User projects, datasets, engine settings, and run folders are stored
under the normal per-user application-data directory instead of beside the
release files.

## macOS Apple Silicon

Build on an Apple Silicon Mac with the tested arm64 R installation and the
native arm64 FVS executable already present in `engine/`:

```bash
tools/build_macos_release.sh --out release
```

The script can take explicit inputs when more than one R installation or engine
directory is available:

```bash
tools/build_macos_release.sh \
  --r-home /Library/Frameworks/R.framework/Versions/4.6/Resources \
  --engine-dir "$PWD/engine" \
  --out release
```

The script stages the complete R framework, copies the tested package closure,
rewrites R and package Mach-O references so they point inside the release,
removes compiler-installation rpaths from FVS, creates `uFVS.app`, writes
`BUILD_INFO.json`, runs the staged-R smoke test, and creates:

```text
release/uFVS-macOS-arm64.zip
```

The resulting app is unsigned and not notarized in this beta pass. macOS may
require Finder → Open the first time.

## Windows x86-64

Build this on a 64-bit Windows machine. The build inputs must be a relocatable
Windows R tree and Windows FVS executables built for the same x86-64 platform;
the macOS engine in this repository cannot be used for this target.

From PowerShell:

```powershell
.\tools\build_windows_release.ps1 `
  -RHome 'C:\path\to\portable-R' `
  -EngineDir 'C:\path\to\FVSbin' `
  -OutDir '.\release'
```

The script stages `runtime\R`, the package closure, the FVS executables and
DLLs, `Start uFVS.bat`, and `BUILD_INFO.json`, then creates:

```text
release\uFVS-Windows-x64.zip
```

The Windows build script is reproducible from those explicit inputs, but it
cannot manufacture a Windows R runtime or Windows FVS executable on macOS.
Those inputs must be obtained and tested on Windows.

The ZIP filenames above are public release asset names and must remain stable
across versions. Keep the release title and the version recorded in
`BUILD_INFO.json` versioned, but publish the assets as
`uFVS-Windows-x64.zip` and `uFVS-macOS-arm64.zip` so README links using
`/releases/latest/download/` continue to work.

## Release checklist

Before uploading either ZIP to GitHub Releases:

1. Run the staged self-test produced by the build script.
2. Test on a clean machine with no R, RStudio, or user R packages installed.
3. Extract into a path containing spaces and launch by double-click.
4. Move the extracted folder and launch again.
5. Disconnect the network and repeat inventory import and one FVS run.
6. Compare a fixed inventory/scenario against a trusted FVS run for the same
   platform and record the engine hash from `BUILD_INFO.json` and `run.json`.

The current development machine has the native arm64 macOS engine but no
Windows build environment or Windows FVS executable, so Windows clean-machine
validation remains a required release step rather than a claim made by this
repository.

## Licensing and notices

Do not remove `NOTICE.md` or the notices shipped with R, its packages, or FVS.
This build process does not select a license for uFVS-authored code. The
upstream component terms remain applicable to the files they cover.
