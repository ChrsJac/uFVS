# Self-contained desktop releases

The release artifacts are ordinary ZIP files. They are not installers and do
not use cloud hosting, Docker, Electron, or a package manager at runtime.

A release user installs nothing. No R, no RStudio, no R packages, no FVS, no
compiler, no Rtools, and nothing added to `PATH`. Each package carries its own
R runtime, its own package library, and its own FVS engine, and the launcher
resolves all of them from the package's own location.

## What is inside a package

Both platforms ship the same four payloads, arranged to suit the platform's
conventions.

### Windows

```text
uFVS\
  uFVS.exe                  native launcher (compiled from tools\windows\ufvs_launcher.c)
  app\                      app.R, launch.R, R\, config\, www\
  runtime\
    R\                      the private R runtime, including R\bin\Rscript.exe
    R-library\              the private R package library
  fvs\                      FVS*.exe and every DLL the engine needs
  resources\                BUILD_INFO.json, README.md, NOTICE.md, LICENSE,
                            CITATION.cff, THIRD_PARTY\, docs\
```

### macOS

```text
uFVS.app/Contents/
  MacOS/uFVS                the launcher (tools/macos_launcher.sh)
  Info.plist
  Resources/
    app/                    app.R, launch.R, R/, config/, www/
    R/                      the private R runtime (a copied R.framework)
      Rscript               relocatable wrapper, the only entry point used
    R-library/              the private R package library
    fvs/                    FVS variant executables and their Fortran dylibs
    BUILD_INFO.json, README.md, NOTICE.md, LICENSE, CITATION.cff,
    THIRD_PARTY/, docs/, uFVS.icns
```

The whole `uFVS.app` is portable: it can be copied to `/Applications`, to a
Desktop, or to an external disk, and it does not depend on anything left behind
in the folder it was extracted from.

## How a packaged launcher starts uFVS

Both launchers do the same six things, and neither ever consults `PATH`, the
registry, `R_HOME`, or the caller's working directory:

1. resolve their own location, and every other path relative to it;
2. describe the layout to R through environment variables (`UFVS_APP_DIR`,
   `UFVS_RUNTIME_DIR`, `UFVS_LIBRARY_DIR`, `UFVS_FVS_DIR`,
   `UFVS_RESOURCES_DIR`);
3. run `app/launch.R` with the **bundled** `Rscript`;
4. wait until `http://127.0.0.1:<port>/` actually answers an HTTP request —
   not merely until the port is open;
5. open the default browser at that address; and
6. own the process tree, so R and any FVS worker stop when uFVS does.

`tools/launch.R` is the single entry point on both platforms and in
development. It binds only to `127.0.0.1`, takes the port from `UFVS_PORT` or
asks httpuv for a free one, and writes the port it actually bound to the
session file the launcher polls.

### Windows specifics

`uFVS.exe` is a small GUI-subsystem C program, so a double-click shows no
console window. It:

- picks a free loopback port by binding one briefly and releasing it;
- starts `runtime\R\bin\Rscript.exe` with `CREATE_NO_WINDOW`;
- puts R in a **job object** marked `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so R
  and any FVS worker are terminated even if the launcher is killed from Task
  Manager rather than closed;
- uses a named mutex for single-instance behaviour: a second double-click
  opens a browser window against the copy that is already running;
- writes `%LOCALAPPDATA%\uFVS\logs\launcher.log` and `server.log`; and
- shows a `MessageBox` with the reason and the last of R's output if startup
  fails, rather than vanishing silently.

It is compiled during the Windows build. There is no `.bat` in a release.

### macOS specifics

`uFVS.app/Contents/MacOS/uFVS` is a POSIX shell script. It:

- resolves the bundle from `$0` and never looks at
  `/Library/Frameworks/R.framework`, `/usr/local/bin/R`, or `/opt/homebrew`;
- takes a lock directory under
  `~/Library/Application Support/uFVS/runtime`, so a second launch reopens the
  running copy instead of starting a competing server;
- writes `~/Library/Logs/uFVS/launcher.log` and `server.log`;
- shows an AppleScript dialog if startup fails; and
- traps `EXIT`/`INT`/`TERM`/`HUP` and terminates R and its descendants,
  `TERM` first and then `KILL`, so a wedged FVS run cannot survive the app.

### Closing the application

In a packaged release the launcher sets `UFVS_DESKTOP=1`, and the browser
window is the application window: when the last one closes, uFVS shuts itself
down after a short grace period (`UFVS_IDLE_SECONDS`, default 10 seconds, long
enough that a page reload is not mistaken for a quit). A source checkout never
sets `UFVS_DESKTOP`, so closing a tab during development leaves
`shiny::runApp()` running as usual.

## Native-library portability

Bundling the R scripts is the easy half. A package is only portable if its
compiled parts also resolve inside it.

The **macOS** build rewrites Mach-O load commands so that:

- the copied R executable, modules, and base/recommended packages reference
  `@loader_path`-relative paths inside `Resources/R` instead of the build
  machine's `R.framework`;
- staged package shared objects reference the bundled runtime through
  `@loader_path/../../../R/R.framework/...`; and
- the FVS binaries carry no absolute `LC_RPATH` entries from the compiler
  installation, so they find their Fortran dylibs beside themselves.

The build then **fails** if any staged Mach-O file still names the build
machine's R library, the developer's home directory, `/opt/homebrew`,
`/opt/local`, `/usr/local/lib`, `/usr/local/opt`, or
`/Library/Frameworks/R.framework`.

The **Windows** build walks the FVS engine's import table with `objdump -p`,
copies every non-system DLL it needs into `fvs\` (where Windows looks first),
and repeats this transitively for each DLL it copies. If a required DLL cannot
be found, the build fails rather than producing a package that works only on a
machine with Rtools installed. `uFVS.exe` itself is linked with `-static
-static-libgcc` so it needs no MinGW runtime DLL at all.

## Building

### macOS Apple Silicon

Build on an Apple Silicon Mac with the tested arm64 R installation and the
native arm64 FVS executable already present in `engine/`:

```bash
tools/build_macos_release.sh --out release
```

Explicit inputs, when more than one R installation or engine directory exists:

```bash
tools/build_macos_release.sh \
  --r-home /Library/Frameworks/R.framework/Versions/4.6/Resources \
  --engine-dir "$PWD/engine" \
  --out release
```

The script stages the framework and package closure, rewrites the Mach-O
references, generates the bundle icon from `www/ufvs-mark.png`, assembles
`uFVS.app`, writes `BUILD_INFO.json`, ad-hoc signs the bundle, runs the tests
described below, and creates `release/uFVS-macOS-arm64.zip`, which expands
directly to `uFVS.app`.

The bundle is ad-hoc signed but not notarized, so macOS may require
Finder → Open the first time. The historical checked-in macOS engine is not
independently tied to a recorded upstream commit; confirm that provenance
before publishing a binary, and set `UFVS_FVS_SOURCE_REVISION` to the exact
source revision used for the engine.

### Windows x86-64 — GitHub Actions

The canonical Windows build runs on a clean GitHub-hosted `windows-latest`
runner, because a Windows package must be built with Windows R, a Windows FVS
build, and a Windows compiler. The workflow
`.github/workflows/build-windows-release.yml`:

1. checks out uFVS;
2. checks out the pinned USDA FVS revision
   `a17ee9728fe3273e9526d66e66fb4a79bdba6c10`;
3. installs Windows R 4.6 and its Rtools toolchain;
4. compiles the official `FVSsn.exe` with the FVS source makefile;
5. runs `tools\build_windows_release.ps1`, which compiles `uFVS.exe`, stages
   the runtime, package closure and engine, and audits the engine's DLLs;
6. re-extracts the ZIP into a path containing spaces and runs the full test
   set against the extracted package; and
7. uploads `uFVS-Windows-x64.zip` as a workflow artifact.

A local Windows build uses the same script directly:

```powershell
.\tools\build_windows_release.ps1 `
  -RHome 'C:\path\to\portable-R' `
  -EngineDir 'C:\path\to\FVSbin' `
  -OutDir '.\release'
```

It needs a C compiler for the launcher; Rtools' MinGW-w64 gcc is the supported
one, and `-Compiler` names it explicitly if it is not on `PATH`. This script
cannot be run from macOS to manufacture Windows binaries.

## Tests the build runs

Every build runs these against the staged package, using the bundled
interpreter and the same environment the launcher creates:

| Script | What it proves |
| --- | --- |
| `tools/release_self_test.R` | The bundled runtime is in use, every required package resolves to the private library, and the UI builds. |
| `tools/fvs_smoke_test.R` | A real FVS projection runs from the bundled engine, and a thinning reduces basal area at the treatment year. |
| `tools/release_http_smoke_test.R` | The **real launcher** serves on `127.0.0.1`, and closing it leaves no orphan R or FVS process. |
| `tools/acceptance_test.R` | A native FVS SQLite database opens; `FVS_StandInit`, `FVS_PlotInit` and `FVS_TreeInit` are read; a projection runs in an isolated worker; and results normalize and render to a chart. |

The acceptance test can be pointed at a real database with `--sample-db`.

## Release checklist

Before uploading either ZIP to GitHub Releases:

1. Run the build; it fails on its own if any of the tests above fail.
2. Test on a clean machine with no R, RStudio, or user R packages installed.
3. Extract into a path containing spaces and launch by double-click.
4. Move the extracted package or `uFVS.app` and launch again.
5. Disconnect the network and repeat inventory import and one FVS run.
6. Close the application and confirm no R or FVS process is left running.
7. Compare a fixed inventory/scenario against a trusted FVS run for the same
   platform and record the engine hash from `BUILD_INFO.json` and `run.json`.
8. Review `THIRD_PARTY/components.csv`, package notice files, and the source
   archive manifest before publication.

The ZIP filenames are public release asset names and must remain stable across
versions, so README links using `/releases/latest/download/` keep working:

```text
uFVS-Windows-x64.zip
uFVS-macOS-arm64.zip
```

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
