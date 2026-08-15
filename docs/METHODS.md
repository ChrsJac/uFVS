# Methods

Every number uFVS produces, and where it comes from. If a quantity is not listed
here, uFVS did not compute it — it came from FVS.

The rule uFVS follows: **no FVS equation is reimplemented, modified, or
approximated.** uFVS reads FVS output, selects rows of it, adds it up, and
computes ordinary survey-sampling statistics over plots.

---

## 1. Inventory expansion

**What it is.** Trees per acre represented by each tally tree.

**Where it comes from.** Transcribed from FVS `base/notre.f`, which is the
routine FVS itself uses. uFVS applies the same arithmetic so that its per-acre
figures agree with the engine's rather than quietly differing.

Let `n` be the number of points inventoried (`PI` in FVS, `IPTINV` /
`NUM_PLOTS`), and for each tree let `P` be `TREE_COUNT` (a value of zero or less
becomes 1, as in FVS).

```
FP  = FPA / n                      small-tree fixed plot   (1/TFPA if TFPA > 0)
VP  = BAF × 183.3465 / n           variable-radius plot
FP2 = −BAF / n                     large-tree fixed plot, when BAF ≤ 0

DBH <  BRK :  TPA = P × FP
DBH >= BRK :  TPA = P × VP / DBH² + P × FP2

TPA = TPA × GROSPC                 non-stockable adjustment
```

**The sign of `BASAL_AREA_FACTOR` matters.** A negative value is *not* a prism
factor. FVS reads it as the inverse of the fixed-plot area on which large trees
were tallied — `−10` means 1/10-acre fixed plots. The comment block at the head
of `notre.f` states this explicitly. Reading it as a BAF instead changes every
per-acre number in the project, so uFVS says which interpretation it applied on
the Data Manager page.

**Defaults.** When the inventory omits `BASAL_AREA_FACTOR`, `INV_PLOT_SIZE` or
`BRK_DBH`, FVS substitutes per-variant defaults from `<variant>/grinit.f`. uFVS
uses the same table (`config/variant_design_defaults.csv`) and marks every
defaulted value in the interface, because a defaulted design is a silent source
of wrong per-acre values.

**Non-stockable plots.** `GROSPC` is `(n − NONSTK) / n`, capped at 1, and FVS
inverts it before use, so densities are expressed per acre of stockable area.
uFVS follows the same order of operations.

**Two expansion columns.** uFVS carries both:

- `TPA_PLOT` — what the tree represents *on its own plot*. This is the sampling
  observation, and it is what statistics are computed from.
- `TPA_STAND` — the tree's contribution to the stand mean (`TPA_PLOT / n`).

Keeping them separate is what prevents the statistics from being computed on
already-averaged values.

## 2. Basal area

```
BA per tree (ft²) = 0.005454154 × DBH²
```

This is the definition of the area of a circle in square feet from a diameter in
inches (`π / (4 × 144)`), not a model. Per-acre basal area is this multiplied by
the expansion factor and summed.

Quadratic mean diameter is inverted from the same definition:
`QMD = √(BA / TPA / 0.005454154)`.

Stand density index is reported in the classic Reineke QMD form,
`SDI = TPA × (QMD/10)^1.605`, and is labeled as such. FVS reports its own SDI
values (including Zeide and Reineke forms) in `FVS_Summary2`; where a run
exists, prefer those.

## 3. Sampling statistics

**Computed across sampling units — plots or points — never across expanded tree
records.** A 47-point cruise has n = 47 no matter how many trees were tallied.
Treating 387 tree records as independent observations would shrink the standard
error by roughly a factor of three and produce confidence intervals that are
simply wrong.

For a per-plot value `x` with `n` plots:

| Statistic | Formula |
|---|---|
| Mean | `x̄ = Σx / n` |
| Variance | `s² = Σ(x − x̄)² / (n − 1)` |
| Standard deviation | `s` |
| Standard error | `SE = s / √n`, × `√(1 − n/N)` when the finite population correction is on |
| Variance of the mean | `SE²` |
| Degrees of freedom | `n − 1` |
| t critical value | `t(1 − α/2, n − 1)` |
| Margin of error | `t × SE` |
| Confidence limits | `x̄ ± t × SE` |
| Coefficient of variation | `100 s / x̄` |
| Relative standard error | `100 SE / x̄` |
| Sampling error (%) | `100 × t × SE / \|x̄\|` |
| Sampling error (absolute) | `t × SE` |

**Sampling error vs relative standard error.** Both are offered because they are
different things. Sampling error in the cruising sense is the half-width of the
confidence interval as a percent of the estimate, at the chosen confidence
level. Relative standard error is the standard error as a percent of the
estimate, with no `t` multiplier. Reporting one under the other's name is a
common way to make a cruise look more precise than it is.

**Empty plots are observations.** When a species or product class is absent from
a plot, that plot contributes a zero, not a missing value. Dropping it would
change the estimate from "mean per acre across the tract" to "mean per acre
across the plots that happened to contain it".

**Plots that were cruised but tallied nothing** are kept in the sample. Where
`NUM_PLOTS` exceeds the number of distinct plot ids in the tree data, FVS treats
the balance as non-stocked points; uFVS enters them as zero observations and
says so in validation.

### Required plots

```
n = t² × CV² / E²
```

iterated, because `t` depends on the degrees of freedom of the sample being
solved for. With a finite population correction, `n = n₀ / (1 + n₀/N)`.

This assumes the additional plots behave like the pilot plots and uses the
observed CV of the chosen design variable. Both assumptions are stated in the
interface next to the result.

### What these intervals are not

They describe how precisely the cruise measured the **current** stand. They are
not confidence intervals around an FVS projection: they contain no model
uncertainty, no parameter uncertainty, and no uncertainty about future
conditions. uFVS does not present them as though they did, and will not label a
projected value with an inventory sampling interval without saying which is
which.

## 4. Volume, weight, and everything else

**uFVS computes none of it.**

Volume comes from FVS, produced by the National Volume Estimator Library under
the control of the `VOLUME`, `BFVOLUME` and `VOLEQNUM` keywords. uFVS exposes
those keywords under their own names and writes nothing unless you set them, so
that FVS applies its own variant defaults rather than a uFVS opinion.

FVS reports per-tree volumes on its tree lists — `TCuFt`, `MCuFt`, `SCuFt`,
`BdFt` — alongside `TPA`. Per-acre volume is `volume × TPA`, summed. That
multiplication is the only arithmetic uFVS performs on a volume, and it lives in
one documented function (`tree_volume_per_acre`).

Green tons, dry tons, cords, and any other unit FVS did not report are **not
offered**, because producing them would require a conversion factor uFVS would
have to invent.

Earlier development versions of uFVS contained a form-class taper model, log
rules and green-weight factors. All of it has been removed.

## 5. Product classes

A product class is a **filter**: a diameter range plus an optional species list.
It is applied to rows of FVS's tree list, and FVS's own volume columns are
totalled within it.

- Ranges are half-open, `[min, max)`, so a tree exactly on a break cannot be
  counted in two classes.
- Rules are evaluated in order; the first match wins.
- Trees matching no class appear as `Unclassified` rather than disappearing.
- FVS's lumped totals are retained unchanged.

**Reconciliation.** Selecting and summing should be lossless, so uFVS compares
the sum over product classes against `FVS_Summary2` for the same stand and year
and reports any difference. If the two disagree, uFVS grouped something wrong
and the FVS totals are the ones to trust.

Multi-product bucking within a single stem is **not** implemented. Splitting one
tree into a sawlog butt and a pulpwood top requires a taper system, and uFVS
does not have one it could defend.

## 6. Missing heights

uFVS does not estimate heights. It does not need them: trees per acre and basal
area come from DBH and the sampling design alone. FVS estimates missing heights
using its own variant height–diameter equations when it runs.

Validation reports how many heights are missing so the cruiser knows how much of
the eventual FVS volume rests on dubbed heights.

## 7. Provenance labeling

Every calculated quantity carries one of four tags:

| Tag | Meaning |
|---|---|
| `FVS` | Direct FVS output |
| `uFVS calculated` | Aggregation, classification, or a statistic built from FVS output or the inventory |
| `converted` | Derived using a named equation or factor |
| `user supplied` | A price, specification, or other assumption the user entered |

In the current build nothing is tagged `converted`, because uFVS applies no
conversions.
