# NOTICE — upstream material and attribution

uFVS is an independent, open-source interface project. It is **not** an official
USDA Forest Service product and is not certified, endorsed, maintained, or
supported by the USDA Forest Service or the FVS development team.

uFVS claims no authorship of the Forest Vegetation Simulator's science. It does
not implement FVS growth, mortality, regeneration, volume, taper, biomass, fire,
or carbon calculations. Those belong to FVS and are produced by FVS.

## Upstream sources used

### 1. Forest Vegetation Simulator (FVS)

- Repository: https://github.com/USDAForestService/ForestVegetationSimulator
- Snapshot used during development: commit `a17ee9728fe3273e9526d66e66fb4a79bdba6c10`
- Official license file: https://github.com/USDAForestService/ForestVegetationSimulator/blob/main/license.txt
- Status: work of U.S. Federal Government employees performed as part of their
  official duties, stated by the project to be in the U.S. public domain and
  released as free and open-source software. FVS distributions may also contain
  third-party components under their own licenses.

uFVS used this source for **structural facts only** — not for equations:

| What uFVS took | From | Used for |
|---|---|---|
| Sampling-design expansion arithmetic | `base/notre.f`, `common/PLOT.F77` | Making uFVS per-acre expansion agree with FVS, including the rule that a negative `BASAL_AREA_FACTOR` means a fixed-area plot, not a prism factor |
| Design defaulting and non-stockable handling | `vbase/initre.f` | Applying the same defaults FVS applies when inventory fields are absent |
| Per-variant `DESIGN` defaults (BAF, FPA, BRK, TFPA) | `<variant>/grinit.f` | `config/variant_design_defaults.csv` |
| Per-variant species lists (alpha, FIA, PLANTS codes and common names) | `<variant>/blkdat.f` | `config/variant_species.csv`, species validation |
| Keyword-file comment convention | `base/keyrdr.f` | Writing `*` comment records rather than a marker FVS would parse as a keyword |
| Command-line interface | `base/cmdline.f` | Invoking an FVS executable with `--keywordfile=` |
| Output table schemas | `dbsqlite/dbstrls.f`, `vdbsqlite/dbssumry.f` | Reading `FVS_TreeList`, `FVS_Summary2` and related output |

Regenerate the transcribed tables with:

```bash
Rscript tools/extract_fvs_config.R /path/to/ForestVegetationSimulator-main
```

The pinned FVS source also declares `volume/NVEL` as a Git submodule from
[`FMSC-Measurements/VolumeLibrary`](https://github.com/FMSC-Measurements/VolumeLibrary)
at submodule commit `4fa39a007973e8fb6a64b3f0c77b03000145fad3`. That pinned
checkout contains a `readme.txt` but no license file or explicit license
statement was identified during this audit. It is therefore recorded as an
unresolved release-review item in `THIRD_PARTY/FVS/NVEL-source-reference.txt`,
and the workflow initializes it rather than silently omitting the volume source.

### 2. FVS Interface (`rFVS`, `fvsOL`)

- Repository: https://github.com/USDAForestService/ForestVegetationSimulator-Interface
- Snapshot used during development: commit `7b608f8265770e70065c5d03fe4cd061699fe479`
- License: MIT, as identified in the package metadata at
  [`rFVS/DESCRIPTION`](https://github.com/USDAForestService/ForestVegetationSimulator-Interface/blob/main/rFVS/DESCRIPTION)
  and [`fvsOL/DESCRIPTION`](https://github.com/USDAForestService/ForestVegetationSimulator-Interface/blob/main/fvsOL/DESCRIPTION).

uFVS used this source for:

| What uFVS took | From | Used for |
|---|---|---|
| The FVS keyword catalog — descriptions, field widgets, labels, defaults, and record templates for 328 keywords across 13 extensions | `fvsOL/parms/*.kwd` | `config/keyword_defs.csv`, `config/keyword_fields.csv`, the Treatments Library, and keyword rendering |
| Keyword-file structure | `rFVS/R/fvsMakeKeyFile.R` | `build_keyword_file()` |
| SVS tree renderer, reproduced verbatim | `fvsOL/R/svsTree.R` | `R/13_svsTree_upstream.R` — the 3D stand view |
| SVS tree-form definitions (crown taper, colors, per species and tree class) | `fvsOL/data/treeforms.RData` | `config/treeforms.RData` — both 2D and 3D views |
| Shared-library loading convention | `rFVS/R/fvsLoad.R` | The library-mode engine adapter |

The keyword descriptions displayed in uFVS are USDA Forest Service text
reproduced for interface purposes. The FVS Keyword Reference Guide remains the
authoritative description of every keyword.

Regenerate the keyword tables with:

```bash
Rscript tools/extract_keyword_defs.R /path/to/ForestVegetationSimulator-Interface-main
```

### Stand visualization

The stand pictures are FVS's own. Adding the `SVS` keyword makes FVS write
Stand Visualization System files carrying, per tree, the species, tree and crown
class, DBH, height, crown radius and crown ratio in four directions, lean and
fall angles, and an (x, y) position that **FVS assigns itself** (`base/svstart.f`,
`svgtpl.f`). uFVS reads those files and draws them.

The 3D view uses `svsTree()` and `displayTrees()` reproduced verbatim from
fvsOL, so trees are drawn the way the official interface draws them. The 2D
profile and plan views are uFVS's own drawing code, using the same official
tree-form parameters for crown shape and color.

The directly reproduced renderer carries its upstream project, file, commit,
and MIT attribution in `R/13_svsTree_upstream.R`. The generated keyword and
tree-form files remain identified above and in `THIRD_PARTY/`.

## What uFVS itself contributes

Interface, validation, workflow, run isolation, table and chart construction,
and these three pieces of arithmetic:

1. **Inventory expansion** following FVS's own sampling-design rules, plus basal
   area from its definition (`0.005454 × DBH²`).
2. **Survey-sampling statistics** across plots — mean, variance, standard error,
   confidence intervals, coefficient of variation, sampling error, required plot
   count. Standard statistical formulae, applied to sampling units.
3. **Selection and summation** — product classes, species breakdowns and
   diameter classes are filters over rows FVS produced, then totalled. uFVS
   checks that class subtotals reconcile against FVS's own totals.

No FVS equation has been reimplemented, modified, or approximated.

## License for uFVS

Original uFVS-authored code is released under the MIT License in the root
`LICENSE` file. The copyright holder named by that license is J. Christopher
Jacobson.

That license applies only to original uFVS-authored material, except where an
individual file identifies another origin or license. It does not relicense the
USDA Forest Vegetation Simulator, `rFVS`, `fvsOL`, R, R packages, copied
upstream source, bundled libraries, generated upstream-derived tables, or any
other third-party component. Those materials retain their own terms.

Standalone releases include `THIRD_PARTY/`, which contains the pinned upstream
references, the R metadata, and a generated inventory of the exact transitive
R package closure and its declared license expressions. The release build also
retains license and notice files found in those packages.

## R and package redistribution

The R runtime bundled in a standalone release remains under the R Project's
`GPL-2 | GPL-3` terms. The official licensing page is
https://www.r-project.org/Licenses/. The exact R version, source URL, package
versions, and FVS engine files are recorded in that release's
`BUILD_INFO.json`. R's own license and copyright files remain inside the
bundled runtime.

Package licenses are not inferred or normalized here. The release inventory is
generated from each package's `DESCRIPTION` file, including transitive
dependencies, and preserves package-specific license/notice files where found.

## Items requiring release review

Before publishing a binary release, review the generated package inventory and
the corresponding source-archive manifest against the exact terms of each
redistributed package. The repository does not make a blanket legal conclusion
about source-availability obligations. Also, the checked-in macOS engine does
not contain a machine-readable upstream commit record; a release's
`BUILD_INFO.json` records the revision selected by its build, but the binary's
historical provenance still requires confirmation when preparing a public
release.

## Branding

The uFVS logo in `www/` is the project owner's own artwork. No USDA Forest
Service mark, seal, or branding is used anywhere in uFVS, and none may be added.
