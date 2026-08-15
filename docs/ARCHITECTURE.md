# Architecture

```
                    ┌─────────────────────────────┐
                    │   Shiny interface (R/2x, 3x)│
                    │   nav · pages · server      │
                    └──────────────┬──────────────┘
                                   │  structured project state
                    ┌──────────────▼──────────────┐
   inventory ──────▶│  import → validate → expand │──▶ statistics
   (xlsx/db/csv)    │  (02, 03, 04)               │    (05)
                    └──────────────┬──────────────┘
                                   │  keywords + input database
                    ┌──────────────▼──────────────┐
                    │  runner (09)                │
                    │  callr worker, own directory│
                    └──────────────┬──────────────┘
                                   │  isolated OS process
                    ┌──────────────▼──────────────┐
                    │  official FVS engine        │   ← not shipped by uFVS
                    │  executable or shared lib   │
                    └──────────────┬──────────────┘
                                   │  FVSOut.db + logs
                    ┌──────────────▼──────────────┐
                    │  normalize (10)             │
                    └──────────────┬──────────────┘
                                   │  standard tables
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                    ▼
       products (07)        charts (11)          tables · compare
```

## Load order

Files in `R/` are numbered and sourced in order. Later modules may use earlier
ones; the reverse is never true.

| File | Responsibility |
|---|---|
| `00_utils` | Shared helpers, formatting, the basal-area constant, provenance tags |
| `01_config` | Paths, versions, reference-table loading, engine configuration and probing |
| `02_import` | Reading FVS input formats; writing the SQLite input database for a run |
| `03_validate` | Everything uFVS can tell the user before they run |
| `04_inventory` | Sampling design resolution and expansion (transcribed from `notre.f`) |
| `05_statistics` | Survey-sampling estimators over plots |
| `06_fvs_output` | FVS output schema knowledge; native volume-control keywords |
| `07_merch` | Product classes as filters over FVS output, plus reconciliation |
| `08_keywords` | The keyword catalog, record rendering, whole keyword files |
| `09_runner` | Run directories, the isolated worker, status, logs, diagnosis |
| `10_normalize` | FVS output database → stable logical tables |
| `11_charts` | Variable metadata, pre-plot validation, chart construction |
| `20_ui` | Shell, navigation, shared presentation helpers |
| `21_pages` | Page layouts |
| `22_info` | Attribution page |
| `30_server` | Reactive wiring |

## Two rules the code is organized around

**1. uFVS does not do FVS's arithmetic.** Growth, mortality, volume, taper,
biomass, fire and carbon come from the engine. uFVS reads, filters, sums, and
computes sampling statistics. `docs/METHODS.md` lists every exception, and there
are only three: expansion (transcribed from FVS itself), basal area (a
definition), and survey-sampling formulae.

**2. FVS never runs in the interface process.** `09_runner` creates a run
directory, writes the inputs, and hands the job to a `callr` worker. A crash in
the engine produces a structured failure value, not an exception in the Shiny
session. This is verified by `tests/test_all.R`, which runs an engine that
segfaults on purpose.

## Project state

The interface keeps structured state, and keywords are rendered from it rather
than being the state itself:

- project metadata, dataset, resolved sampling designs
- statistics display settings (which columns, which confidence level)
- product class definitions
- scenarios, each with an ordered activity list of FVS keywords plus raw
  keyword text
- volume-control keyword settings
- engine configuration
- results, keyed by scenario

Raw keyword text is appended verbatim, so anything uFVS has no form for is still
reachable.

## Reference tables

`config/` holds tables transcribed mechanically from the official sources by the
scripts in `tools/`. They contain no uFVS modeling content and can be
regenerated at any time:

| File | Source | Contents |
|---|---|---|
| `variant_design_defaults.csv` | `<variant>/grinit.f` | 25 variants |
| `variant_species.csv` | `<variant>/blkdat.f` | 1,087 species rows |
| `keyword_defs.csv` | `fvsOL/parms/*.kwd` | 328 keywords, 13 extensions |
| `keyword_fields.csv` | `fvsOL/parms/*.kwd` | 1,919 field definitions |
| `variable_metadata.csv` | hand-written | plottable variables and their roles |

See [NOTICE.md](../NOTICE.md) for attribution.

## Extending it

- **A new statistic**: add an entry to `STAT_DEFS` and a field in
  `sampling_stats()`. It appears as a checkbox and propagates to every table.
- **A new page**: add to `UFVS_NAV`, write a `page_*()` layout, add a branch in
  the router, and add its outputs to the server.
- **A new output table**: add it to `FVS_OUTPUT_TABLES` and `normalize_fvs_output()`,
  then describe its columns in `variable_metadata.csv` to make them plottable.
- **Upstream changed**: re-run the scripts in `tools/` against the new source.
