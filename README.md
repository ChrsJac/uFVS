# uFVS

An accessible interface for the USDA Forest Service Forest Vegetation Simulator.

## Download

### Windows

[Download uFVS for Windows](https://github.com/ChrsJac/uFVS/releases/latest/download/uFVS-Windows-x64.zip)

### macOS

[Download uFVS for macOS (Apple Silicon)](https://github.com/ChrsJac/uFVS/releases/latest/download/uFVS-macOS-arm64.zip)

## For users

**Windows**

1. Download the Windows ZIP.
2. Extract it. (Extract it properly — running `uFVS.exe` from inside the ZIP
   viewer does not work.)
3. Double-click `uFVS.exe`.

**macOS**

1. Download the macOS ZIP.
2. Open it, and drag `uFVS.app` wherever you keep applications.
3. Double-click `uFVS.app`.

uFVS opens in your default browser and runs entirely on your own computer.

You do **not** need to install any of the following, on either platform:

- R
- RStudio
- R packages
- FVS
- a compiler, Rtools, or any other development tool
- anything added to `PATH`

Each download carries its own R runtime, its own R package library, and its own
FVS engine. No Internet connection is required after downloading. Closing the
browser window closes uFVS, including the FVS processes it started.

Your projects, datasets, engine settings, and run folders are kept in your
normal per-user application-data folder, not inside the application, so the
downloaded package can live in a read-only location.

The public release ZIPs keep these asset names stable across versions, so the
links above always point to the newest release:

- `uFVS-Windows-x64.zip`
- `uFVS-macOS-arm64.zip`

If uFVS fails to start it says so in a dialog and writes a log:

- Windows — `%LOCALAPPDATA%\uFVS\logs\launcher.log`
- macOS — `~/Library/Logs/uFVS/launcher.log`

uFVS is an independent interface project. It is not an official USDA Forest
Service product and is not certified, endorsed, maintained, or supported by
the USDA Forest Service or the FVS development team. FVS itself performs the
growth, mortality, volume, biomass, carbon, regeneration, and other FVS
simulations; uFVS provides the interface and workflow around the engine.

## What uFVS does

- Imports FVS SQLite databases, Excel workbooks, and matching CSV input tables.
- Shows inventory design assumptions, validation issues, statistics, and
  species-level summaries before a projection is run.
- Builds visible, editable management plans from FVS keywords.
- Runs the selected FVS engine in an isolated work directory and keeps the
  output tables and logs available for review.
- Compares scenarios with configurable tables, charts, and stand views.
- Supports user-defined product classes, including species-specific classes.

uFVS does not reimplement FVS or calculate growth, mortality, regeneration,
volume, taper, biomass, fire behavior, or carbon. Those calculations come from
FVS.

## Screenshots

The application includes pages for inventory review, management planning,
projection results, charts, tables, and stand visualization. Screenshots will
be added here as release examples become available.

## Documentation

- [NOTICE.md](NOTICE.md) — upstream sources, attribution, and licensing
- [docs/METHODS.md](docs/METHODS.md) — quantities uFVS computes and how
- [docs/ENGINE_SETUP.md](docs/ENGINE_SETUP.md) — engine setup for source checkouts
- [docs/RELEASE_BUILD.md](docs/RELEASE_BUILD.md) — self-contained desktop releases

## For developers

There are two clearly separated ways to run uFVS, and they do not interfere
with each other.

| | Development mode | Packaged mode |
| --- | --- | --- |
| Runs | the source checkout | a downloaded release |
| R | your installed R | the private R inside the package |
| Packages | your own R library | the private library inside the package |
| FVS | `engine/`, or an installed FVS | the engine inside the package |
| Started by | `shiny::runApp()`, `Launch uFVS.*` | `uFVS.exe` / `uFVS.app` |
| Closing a browser tab | leaves the app running | quits the application |

Packaged mode is selected entirely by environment variables that the release
launchers set. A source checkout sets none of them, so nothing about
development changes.

### Running from source

Requires R 4.1 or newer and these packages:

```r
install.packages(c("shiny", "ggplot2", "jsonlite", "DBI", "RSQLite",
                   "readxl", "callr", "digest"))
install.packages("rgl")   # optional, for the 3D stand view
```

Then, from the repository root:

```bash
Rscript -e "shiny::runApp('.', launch.browser = TRUE)"
```

`tools/launch.R` is the same entry point the packaged launchers use, and works
from source too:

```bash
Rscript tools/launch.R
```

On macOS you can double-click `Launch uFVS.command`; on Windows, `Launch
uFVS.bat`. Both are development launchers that use your installed R.

The source checkout can use the native engine in `engine/` on the matching
platform. Inventory analysis works without any engine; projection needs one.
See [docs/ENGINE_SETUP.md](docs/ENGINE_SETUP.md).

### Tests

```bash
Rscript tests/test_all.R
Rscript tests/test_ui.R
```

### Building the packaged releases

See [docs/RELEASE_BUILD.md](docs/RELEASE_BUILD.md) for the package layout, the
launcher behaviour, the native-library portability rules, and the build
commands. In short:

```bash
tools/build_macos_release.sh --out release
```

```powershell
.\tools\build_windows_release.ps1 -RHome 'C:\path\to\portable-R' -OutDir '.\release'
```

The Windows package is normally built by
`.github/workflows/build-windows-release.yml` on a clean Windows runner, which
also compiles the FVS engine and `uFVS.exe`.

## Technical architecture

Source checkout:

```text
app.R                     application entry point
R/                        modules, numbered in load order
config/                   reference tables transcribed from FVS source
engine/                   FVS binaries for development on this platform
tools/                    launcher, release, and source-data tooling
tools/windows/            C source for the native Windows launcher
tests/                    regression checks and FVS-semantic fixtures
www/                      application styles and image assets
docs/                     methods, engine setup, release, and architecture notes
```

At runtime uFVS is a local desktop application with a Shiny server behind it:

```text
uFVS launcher (uFVS.exe / uFVS.app)
  -> bundled private R runtime
     -> Shiny / uFVS interface
        -> isolated worker process (callr)
           -> bundled FVS engine
```

FVS is never loaded into the interface process. Every run happens in a separate
OS process, in its own directory, with its own inputs, outputs, and logs, so a
fault inside the engine cannot take the interface down or lose unsaved work.

The downloadable releases are self-contained: each carries a tested R runtime,
the required package library, and a platform-specific FVS engine, and resolves
all of them from its own install location. Runtime settings, projects,
datasets, and run logs are stored in a user-writable application-data directory
rather than beside the source or release files. The packaged directory and
bundle layouts are documented in
[docs/RELEASE_BUILD.md](docs/RELEASE_BUILD.md).

## Licensing

Original uFVS-authored code is released under the [MIT License](LICENSE).
Third-party software, source material, data, and incorporated upstream code
retain their respective licenses and terms. See [NOTICE.md](NOTICE.md) and the
third-party notices distributed with uFVS. The MIT license does not relicense
FVS, `rFVS`, `fvsOL`, R, R packages, or any other third-party component.
