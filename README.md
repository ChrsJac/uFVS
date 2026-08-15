# uFVS

An independent, open-source interface for the USDA Forest Service **Forest
Vegetation Simulator**.

uFVS is not FVS and does not reimplement it. It is the layer around FVS: reading
inventories the way FVS reads them, showing what FVS will assume before you run,
building keyword files from a management plan you can see, running the engine
where it cannot take the interface down with it, and reporting the results with
the inventory statistics a cruiser actually asks for.

> uFVS is **not** an official USDA Forest Service product and is not endorsed by
> the USDA Forest Service. See [NOTICE.md](NOTICE.md).

## What it does

**Inventory**
- Reads FVS input databases (SQLite), Excel workbooks with `FVS_StandInit` /
  `FVS_PlotInit` / `FVS_TreeInit` sheets, or CSVs using those table names.
- Resolves the sampling design exactly as FVS does, including per-variant
  defaults, and *tells you which values it had to default*.
- Validates before you run: unknown species for the variant, plot counts that
  will stop FVS, missing design fields, missing heights.

**Statistics**
- Confidence intervals, sampling error, CV, SD, variance, standard error,
  margin of error, RSE, df, t, and descriptive statistics — as checkboxes that
  add columns to the tables you are already looking at.
- Confidence level is any number between 0 and 100, not a fixed list.
- Required-plot calculation for a target sampling error.
- Everything is computed **across sampling units**, never by treating expanded
  tree records as independent observations.

**Management**
- A timeline of scheduled activities, each one a real FVS keyword.
- 328 keywords across 13 extensions with their official fields, descriptions and
  defaults; advanced fields are collapsed, never removed.
- The keyword record uFVS will write is always visible, and a raw keyword editor
  is always available.

**Products**
- User-defined product classes: a diameter range and an optional species list.
- Applied to FVS's own output, so you can see how much of each class you have,
  by species, without losing FVS's lumped totals.
- uFVS checks that class subtotals reconcile with FVS's totals and says so if
  they do not.

**Running**
- FVS runs in a separate OS process, in its own directory, with its own inputs,
  outputs and logs. An engine crash ends the worker and nothing else.
- Every run records its engine path, input hash, keyword hash and platform.

**Stand visualization**
- FVS writes Stand Visualization System files; uFVS reads them and draws the
  stand at each cycle in 3D, in profile, or from above.
- Tree positions, crown radii and crown ratios are FVS's own. The 3D view uses
  the same renderer as the official fvsOL interface.

**Results**
- Charts that validate the combination before drawing and explain what is wrong
  when they cannot.
- Configurable tables, scenario comparison, and the raw FVS output tables under
  FVS's own column names.

## What it does not do

uFVS computes no growth, mortality, regeneration, volume, taper, biomass, fire
behavior, or carbon. Those come from FVS. Without a configured FVS engine, the
inventory side works fully and there are no volumes — uFVS will not estimate one.

## Requirements

- R 4.1 or newer
- Packages: `shiny`, `ggplot2`, `jsonlite`, `DBI`, `RSQLite`, `readxl`, `callr`
- Optional: `rgl` for the 3D stand view. Without it the Visualize page still
  draws its 2D profile and plan views.

```r
install.packages(c("shiny","ggplot2","jsonlite","DBI","RSQLite","readxl","callr"))
install.packages("rgl")   # optional, for the 3D stand view
```

An FVS engine is optional for inventory work and required for projection. See
[docs/ENGINE_SETUP.md](docs/ENGINE_SETUP.md).

## Running it

### Windows

Unzip the folder, install R from [CRAN](https://cran.r-project.org/bin/windows/base/),
and double-click **Launch uFVS.bat**. The launcher finds `Rscript.exe`, offers to
install the required packages into the user's R library, and opens uFVS in the
browser. It does not require administrator privileges for the app itself.

The copy in this repository contains a macOS FVS engine, so it is intentionally
ignored on Windows. Inventory analysis works immediately; projection requires
an official Windows FVS executable such as `FVSsn.exe`. See
[docs/ENGINE_SETUP.md](docs/ENGINE_SETUP.md).

**Double-click `uFVS.app`** (in the folder above this one). It finds R, checks
the packages — offering to install any that are missing — starts the server on a
free port and opens your browser. Anything it does is logged to
`~/Library/Logs/uFVS.log`.

To quit: right-click uFVS in the Dock and choose Quit, or close the browser tab
and quit the app from the Dock.

**Or double-click `Launch uFVS.command`** to run it in a Terminal window instead.
Same thing, but you can watch the output and stop it with Ctrl-C. Use this one
when something goes wrong and you need to see the error.

**Or from a terminal:**

```bash
Rscript -e "shiny::runApp('.', launch.browser = TRUE)"
```

Then import your inventory from the Data page. uFVS ships no data of its own.

Runtime settings, project state, and run logs are stored in a user-writable
data directory, not beside the application. This allows the same unpacked copy
to run from a protected or read-only folder.

### If the app will not open

macOS may block a downloaded or unsigned app the first time. Right-click
`uFVS.app` → **Open** → **Open**, and it will be trusted from then on. If it
still does nothing, run `Launch uFVS.command` to see the actual error.

`uFVS.app` expects to sit next to the `uFVS` project folder. If you move one,
move both.

## Layout

```
app.R                     launcher
R/                        modules, numbered in load order
  00_utils    01_config   02_import    03_validate
  04_inventory            05_statistics
  06_fvs_output           07_merch     08_keywords
  09_runner   10_normalize             11_charts
  12_svs      13_svsTree_upstream (vendored from fvsOL)
  20_ui       21_pages    22_info      30_server
config/                   reference tables transcribed from the FVS source
tools/                    scripts that regenerate config/ from upstream
tests/                    verification against the FVS source semantics
                          (builds its own fixture; set UFVS_TEST_DATA to use
                          a real inventory instead)
runs/                     one directory per FVS run
docs/                     methods, engine setup, architecture
```

## Documentation

- [NOTICE.md](NOTICE.md) — upstream sources, attribution, licensing
- [docs/METHODS.md](docs/METHODS.md) — every number uFVS computes and how
- [docs/ENGINE_SETUP.md](docs/ENGINE_SETUP.md) — building or installing FVS
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the pieces fit

## License

No license has been applied to uFVS-authored code. Upstream notices and the
terms of the material uFVS builds on are recorded in [NOTICE.md](NOTICE.md).
