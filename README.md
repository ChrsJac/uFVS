# uFVS

An accessible interface for the USDA Forest Service Forest Vegetation Simulator.

## Download

### Windows

[Download uFVS for Windows](https://github.com/ChrsJac/uFVS/releases/latest/download/uFVS-Windows-x64.zip)

### macOS

[Download uFVS for macOS (Apple Silicon)](https://github.com/ChrsJac/uFVS/releases/latest/download/uFVS-macOS-arm64.zip)

## How to run

**Windows**

1. Download the Windows ZIP.
2. Extract it.
3. Double-click `Start uFVS.bat`.

**macOS**

1. Download the macOS ZIP.
2. Extract it.
3. Double-click `uFVS.app`.

No R, RStudio, FVS installation, or Internet connection is required after
download. The public release ZIPs must keep these asset names stable across
versions so the links above always point to the newest release:

- `uFVS-Windows-x64.zip`
- `uFVS-macOS-arm64.zip`

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

## Development / Run from source

The source checkout is for development and testing. It requires R 4.1 or
newer and these packages:

```r
install.packages(c("shiny", "ggplot2", "jsonlite", "DBI", "RSQLite",
                   "readxl", "callr", "digest"))
install.packages("rgl")   # optional, for the 3D stand view
```

### macOS

Double-click `Launch uFVS.command`, or run:

```bash
Rscript -e "shiny::runApp('.', launch.browser = TRUE)"
```

The development `uFVS.app` expects to sit next to the `uFVS` project folder.
The source checkout can use the native engine in `engine/` on the matching
platform. See [docs/ENGINE_SETUP.md](docs/ENGINE_SETUP.md) for details.

### Windows

Double-click `Launch uFVS.bat` after installing R, or run the application from
an R terminal. Inventory analysis works without an engine; projection in a
source checkout requires a native Windows FVS executable such as `FVSsn.exe`.

## Technical architecture

```text
app.R                     application entry point
R/                        modules, numbered in load order
config/                   reference tables transcribed from FVS source
tools/                    release and source-data tooling
tests/                    regression checks and FVS-semantic fixtures
www/                      application styles and image assets
docs/                     methods, engine setup, release, and architecture notes
```

The downloadable releases are self-contained. They carry a tested R runtime,
the required package library, and a platform-specific FVS engine. Runtime
settings, projects, datasets, and run logs are stored in a user-writable
application-data directory rather than beside the source or release files.

## Licensing

Original uFVS-authored code is released under the [MIT License](LICENSE).
Third-party software, source material, data, and incorporated upstream code
retain their respective licenses and terms. See [NOTICE.md](NOTICE.md) and the
third-party notices distributed with uFVS. The MIT license does not relicense
FVS, `rFVS`, `fvsOL`, R, R packages, or any other third-party component.
