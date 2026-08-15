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
removes compiler-installation rpaths from FVS, creates `uFVS.app`, copies the
license and third-party notices, writes `BUILD_INFO.json`, runs the staged-R
self-test, and creates:

```text
release/uFVS-macOS-arm64.zip
```

The resulting app is unsigned and not notarized in this beta pass. macOS may
require Finder → Open the first time. The historical checked-in macOS engine is
not independently tied to a recorded upstream commit; confirm that provenance
before publishing a binary. A rebuild should set `UFVS_FVS_SOURCE_REVISION` to
the exact source revision used for the engine.

## Windows x86-64 — GitHub Actions

The canonical Windows release build runs on a clean GitHub-hosted
`windows-latest` runner. The workflow
`.github/workflows/build-windows-release.yml`:

1. checks out uFVS;
2. checks out the pinned USDA FVS revision
   `a17ee9728fe3273e9526d66e66fb4a79bdba6c10`;
3. installs Windows R 4.6 and its Rtools toolchain;
4. compiles the official `FVSsn.exe` with the FVS source makefile;
5. stages Windows R, the transitive uFVS package closure, the engine, and
   required runtime files;
6. runs the staged release self-test and a real FVS smoke projection; and
7. uploads `uFVS-Windows-x64.zip` as a workflow artifact.

The exact R version, package versions, FVS source revision, engine hashes, and
license metadata are written into the staged `BUILD_INFO.json` and
`THIRD_PARTY/` inventory. The workflow does not use the Mac checkout's R tree
or engine binary.

For a local Windows build, the PowerShell script remains available as a manual
fallback when tested Windows R and FVS inputs are already available:

From PowerShell:

```powershell
.\tools\build_windows_release.ps1 `
  -RHome 'C:\path\to\portable-R' `
  -EngineDir 'C:\path\to\FVSbin' `
  -OutDir '.\release'
```

The script stages `runtime\R`, the package closure, the FVS executables and
DLLs, `Start uFVS.bat`, the license/third-party notices, and `BUILD_INFO.json`,
then creates:

```text
release\uFVS-Windows-x64.zip
```

That fallback is not required for the GitHub Actions release and cannot be used
from macOS to manufacture Windows binaries.

The ZIP filenames above are public release asset names and must remain stable
across versions. Keep the release title and the version recorded in
`BUILD_INFO.json` versioned, but publish the assets as
`uFVS-Windows-x64.zip` and `uFVS-macOS-arm64.zip` so README links using
`/releases/latest/download/` continue to work. The current workflow uploads an
Actions artifact; attaching the validated artifact to a public GitHub Release
is a separate, explicit release step.

## Release checklist

Before uploading either ZIP to GitHub Releases:

1. Run the staged self-test produced by the build script.
2. Confirm the real FVS smoke projection used the staged R and staged engine.
3. Test on a clean machine with no R, RStudio, or user R packages installed.
4. Extract into a path containing spaces and launch by double-click.
5. Move the extracted folder and launch again.
6. Disconnect the network and repeat inventory import and one FVS run.
7. Compare a fixed inventory/scenario against a trusted FVS run for the same
   platform and record the engine hash from `BUILD_INFO.json` and `run.json`.
8. Review `THIRD_PARTY/components.csv`, package notice files, and the source
   archive manifest before publication.

## Licensing and notices

Original uFVS-authored code is MIT-licensed by the root `LICENSE` file. Do not
remove `NOTICE.md`, `THIRD_PARTY/`, the notices shipped with R, the notices
shipped with its packages, or the official FVS license. These terms apply to
the components they cover and are not replaced by the uFVS MIT license.

For exact package source handling, use
`tools/download_third_party_source.R` against the release inventory. The script
records the archive URL actually used and stops when an exact source archive is
not available; a human release review is required for any package-specific
source-availability obligation.
