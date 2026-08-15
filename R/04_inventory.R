# ------------------------------------------------------------------------------
# Inventory expansion.
#
# This module reproduces the sampling-design arithmetic FVS applies in
# base/notre.f so that uFVS per-acre values agree with the engine's. It is a
# transcription of FVS behavior, not a new estimator:
#
#   PI     number of points inventoried            (PLOT.F77: "NUMBER OF POINTS
#                                                    INVENTORIED. SET IN INITRE")
#   FP     = FPA / PI          (1/TFPA if TFPA > 0)  small-tree fixed plot
#   VP     = BAF * 183.3465 / PI                     variable-radius plot
#   FP2    = -BAF / PI  when BAF <= 0                large-tree fixed plot
#   tree   P = TREE_COUNT; P*FP if DBH < BRK, else P*VP/DBH^2 + P*FP2
#   PROB   = P * GROSPC                              non-stockable adjustment
#
# A negative BASAL_AREA_FACTOR is not a prism factor: FVS reads it as the
# inverse of the fixed-plot area on which the large trees were tallied. The
# comment block at the head of notre.f states this explicitly, and getting it
# backwards silently changes every per-acre number in the project.
# ------------------------------------------------------------------------------

VAR_RADIUS_CONST <- 183.3465   # BAF * this / DBH^2 = trees per acre per tally tree

#' Resolve the sampling design for one stand, recording where each value came
#' from so the interface can show the user what FVS will actually assume.
stand_design <- function(stand_row, trees_for_stand, plots_for_stand = NULL) {
  variant <- tolower(nz(stand_row$VARIANT, ""))
  def <- design_defaults_for(variant)

  src <- list()
  take <- function(field, default, label) {
    v <- if (field %in% names(stand_row)) safe_num(stand_row[[field]]) else NA_real_
    if (length(v) != 1 || is.na(v)) {
      src[[label]] <<- "variant default"
      default
    } else {
      src[[label]] <<- "inventory"
      v
    }
  }

  baf  <- take("BASAL_AREA_FACTOR", def$baf, "baf")
  fpa  <- take("INV_PLOT_SIZE",     def$fpa, "fpa")
  brk  <- take("BRK_DBH",           def$brk, "brk")
  tfpa <- def$tfpa

  observed_plots <- length(unique(trees_for_stand$PLOT_ID))
  declared <- if ("NUM_PLOTS" %in% names(stand_row)) safe_num(stand_row$NUM_PLOTS) else NA_real_
  listed_plots <- if (!is.null(plots_for_stand) && nrow(plots_for_stand)) {
    length(unique(as.character(plots_for_stand$PLOT_ID)))
  } else NA_integer_

  # FVS: IPTINV defaults to the counted plot ids; <= 0 becomes 1.
  nplots <- if (!is.na(declared) && declared > 0) declared else max(observed_plots, 1L)
  src$nplots <- if (!is.na(declared) && declared > 0) "inventory (NUM_PLOTS)" else "counted plot ids"

  nonstk_declared <- if ("NONSTK_PLOTS" %in% names(stand_row)) safe_num(stand_row$NONSTK_PLOTS) else NA_real_
  nonstk <- if (!is.na(nonstk_declared)) nonstk_declared else max(0, nplots - observed_plots)
  src$nonstk <- if (!is.na(nonstk_declared)) "inventory (NONSTK_PLOTS)" else "derived (plots with no tally)"

  stockable <- if (nplots - nonstk > 0) min(1, (nplots - nonstk) / nplots) else 1
  grospc_mult <- 1 / stockable    # FVS inverts GROSPC before NOTRE uses it

  method <- if (baf > 0) {
    sprintf("Variable-radius (prism) BAF %s for DBH >= %s in; fixed 1/%s acre below",
            fmt_num(baf, 1), fmt_num(brk, 1), fmt_num(fpa, 0))
  } else if (baf < 0) {
    sprintf("Fixed 1/%s acre for DBH >= %s in; fixed 1/%s acre below",
            fmt_num(-baf, 0), fmt_num(brk, 1), fmt_num(fpa, 0))
  } else {
    sprintf("Fixed 1/%s acre (all sizes)", fmt_num(fpa, 0))
  }

  list(baf = baf, fpa = fpa, brk = brk, tfpa = tfpa,
       nplots = nplots, nonstk = nonstk, observed_plots = observed_plots,
       listed_plots = listed_plots,
       stockable = stockable, grospc_mult = grospc_mult,
       variant = variant, method = method, source = src)
}

#' Per-tally-tree expansion factor, before dividing by the number of points.
#'
#' Returns trees per acre represented by one tally tree *on the plot where it was
#' measured*.
tree_expansion_factor <- function(dbh, design) {
  small <- !is.na(dbh) & dbh < design$brk
  fp <- if (!is.na(design$tfpa) && design$tfpa > 0) 1 / design$tfpa else design$fpa
  large <- if (design$baf > 0) {
    VAR_RADIUS_CONST * design$baf / (dbh^2)
  } else {
    rep(-design$baf, length(dbh))
  }
  out <- ifelse(small, fp, large)
  out[is.na(dbh)] <- NA_real_
  out
}

#' Expand every tree record in the project.
#'
#' Adds two columns that the rest of uFVS depends on:
#'   TPA_PLOT   trees/acre this record represents on its own plot   (sampling unit)
#'   TPA_STAND  trees/acre this record contributes to the stand mean
#' Statistics are computed from plot-level aggregates of TPA_PLOT. Stand totals
#' use TPA_STAND. Treating expanded tree records as independent observations
#' would understate the variance badly, so the two are kept distinct throughout.
expand_inventory <- function(data) {
  stands <- data$stands
  trees <- data$trees
  designs <- list()
  out <- vector("list", nrow(stands))

  for (i in seq_len(nrow(stands))) {
    sid <- stands$STAND_ID[i]
    tr <- trees[trees$STAND_ID == sid, , drop = FALSE]
    pl <- if (!is.null(data$plots)) data$plots[data$plots$STAND_ID == sid, , drop = FALSE] else NULL
    des <- stand_design(stands[i, , drop = FALSE], tr, pl)
    designs[[sid]] <- des
    if (!nrow(tr)) { out[[i]] <- tr; next }

    cnt <- col_or(tr, "TREE_COUNT", NA_real_)
    cnt <- ifelse(is.na(cnt) | cnt <= 0, 1, cnt)          # FVS: P <= 0 becomes 1
    ef <- tree_expansion_factor(tr$DIAMETER, des)

    tr$EXPANSION <- ef
    tr$TPA_PLOT  <- cnt * ef * des$grospc_mult
    tr$TPA_STAND <- tr$TPA_PLOT / des$nplots
    tr$BA_TREE   <- ba_of_dbh(tr$DIAMETER)
    tr$BA_PLOT   <- tr$BA_TREE * tr$TPA_PLOT
    tr$BA_STAND  <- tr$BA_TREE * tr$TPA_STAND
    # Live tally only for current-condition summaries. HISTORY 1/2 are live in
    # the FVS tree-record convention; 6-9 are dead/removed.
    hist <- safe_num(col_or(tr, "HISTORY", 1))
    tr$IS_LIVE <- is.na(hist) | hist <= 5
    out[[i]] <- tr
  }

  trees_out <- do.call(rbind, out[!vapply(out, is.null, logical(1))])
  list(trees = trees_out, designs = designs)
}

#' One row per sampling unit (plot/point). Plots with no tally are retained as
#' genuine zero observations, because dropping them biases both the mean and the
#' variance upward.
plot_table <- function(expanded, data, stand_id = NULL) {
  tr <- expanded$trees
  if (!is.null(stand_id)) tr <- tr[tr$STAND_ID %in% stand_id, , drop = FALSE]
  tr <- tr[tr$IS_LIVE %in% TRUE, , drop = FALSE]

  sids <- if (!is.null(stand_id)) stand_id else unique(data$stands$STAND_ID)
  res <- list()
  for (sid in sids) {
    des <- expanded$designs[[sid]]
    if (is.null(des)) next
    t_s <- tr[tr$STAND_ID == sid, , drop = FALSE]

    ids <- unique(t_s$PLOT_ID)
    if (!is.null(data$plots) && nrow(data$plots)) {
      pl <- data$plots[data$plots$STAND_ID == sid, , drop = FALSE]
      if (nrow(pl)) ids <- union(ids, as.character(pl$PLOT_ID))
    }
    # Declared plot count larger than what we can see: FVS assumes the balance
    # were non-stocked points, so they enter the sample as zeros.
    if (des$nplots > length(ids)) {
      ids <- c(ids, paste0("(empty ", seq_len(des$nplots - length(ids)), ")"))
    }

    agg <- function(f) vapply(ids, function(p) {
      x <- t_s[t_s$PLOT_ID == p, , drop = FALSE]
      if (!nrow(x)) 0 else f(x)
    }, numeric(1))

    d <- data.frame(
      STAND_ID = sid,
      PLOT_ID  = ids,
      TREES    = vapply(ids, function(p) sum(t_s$PLOT_ID == p), numeric(1)),
      TPA      = agg(function(x) sum(x$TPA_PLOT, na.rm = TRUE)),
      BA       = agg(function(x) sum(x$BA_PLOT, na.rm = TRUE)),
      stringsAsFactors = FALSE
    )
    d$QMD <- qmd_from(d$BA, d$TPA)
    res[[sid]] <- d
  }
  out <- do.call(rbind, res)
  if (is.null(out)) {
    out <- data.frame(STAND_ID = character(0), PLOT_ID = character(0),
                      TREES = numeric(0), TPA = numeric(0), BA = numeric(0),
                      QMD = numeric(0), stringsAsFactors = FALSE)
  }
  rownames(out) <- NULL
  out
}

#' Plot-level totals for an arbitrary per-tree quantity (volume, tons, value).
#'
#' `value_col` must already be expressed per acre on the tree's own plot, i.e.
#' multiplied by TPA_PLOT. Used by the statistics engine so that product and
#' species subsets get sampling error computed at the plot level too.
plot_totals_of <- function(expanded, data, value_col, stand_id = NULL,
                           subset_rows = NULL) {
  tr <- expanded$trees
  if (!is.null(stand_id)) tr <- tr[tr$STAND_ID %in% stand_id, , drop = FALSE]
  tr <- tr[tr$IS_LIVE %in% TRUE, , drop = FALSE]
  if (!is.null(subset_rows)) tr <- tr[subset_rows[rownames(tr)] %in% TRUE, , drop = FALSE]

  base <- plot_table(expanded, data, stand_id)[, c("STAND_ID", "PLOT_ID")]
  if (!value_col %in% names(tr)) {
    base[[value_col]] <- 0
    return(base)
  }
  key <- paste(tr$STAND_ID, tr$PLOT_ID, sep = "\r")
  sums <- tapply(tr[[value_col]], key, function(z) sum(z, na.rm = TRUE))
  base[[value_col]] <- as.numeric(nz(sums[paste(base$STAND_ID, base$PLOT_ID, sep = "\r")], 0))
  base[[value_col]][is.na(base[[value_col]])] <- 0
  base
}

#' Current-condition stand summary (uFVS calculated from the inventory, not an
#' FVS projection).
stand_summary <- function(expanded, data) {
  tr <- expanded$trees[expanded$trees$IS_LIVE %in% TRUE, , drop = FALSE]
  sids <- data$stands$STAND_ID
  do.call(rbind, lapply(sids, function(sid) {
    des <- expanded$designs[[sid]]
    x <- tr[tr$STAND_ID == sid, , drop = FALSE]
    tpa <- sum(x$TPA_STAND, na.rm = TRUE)
    ba  <- sum(x$BA_STAND, na.rm = TRUE)
    qmd <- qmd_from(ba, tpa)
    # Basal-area-weighted mean height of trees with a measured height.
    ht_ok <- !is.na(x$HT) & x$HT > 0
    data.frame(
      STAND_ID = sid,
      VARIANT  = nz(des$variant, ""),
      INV_YEAR = nz(safe_num(data$stands$INV_YEAR[data$stands$STAND_ID == sid])[1], NA_real_),
      PLOTS    = nz(des$nplots, NA_real_),
      TREES    = nrow(x),
      TPA      = tpa,
      BA       = ba,
      QMD      = qmd,
      SDI      = sdi_reineke(tpa, qmd),
      MEAN_HT  = if (any(ht_ok)) stats::weighted.mean(x$HT[ht_ok], x$BA_STAND[ht_ok]) else NA_real_,
      HT_MEASURED = sum(ht_ok),
      stringsAsFactors = FALSE
    )
  }))
}

#' Species composition for a stand (stand-level per-acre values).
species_summary <- function(expanded, data, stand_id = NULL) {
  tr <- expanded$trees[expanded$trees$IS_LIVE %in% TRUE, , drop = FALSE]
  if (!is.null(stand_id)) tr <- tr[tr$STAND_ID %in% stand_id, , drop = FALSE]
  if (!nrow(tr)) return(data.frame())
  key <- paste(tr$STAND_ID, tr$SPECIES, sep = "\r")
  sp <- do.call(rbind, lapply(split(tr, key), function(x) {
    tpa <- sum(x$TPA_STAND, na.rm = TRUE); ba <- sum(x$BA_STAND, na.rm = TRUE)
    data.frame(STAND_ID = x$STAND_ID[1], SPECIES = x$SPECIES[1],
               TREES = nrow(x), TPA = tpa, BA = ba, QMD = qmd_from(ba, tpa),
               stringsAsFactors = FALSE)
  }))
  sp <- sp[order(sp$STAND_ID, -sp$BA), ]
  tot <- tapply(sp$BA, sp$STAND_ID, sum)
  sp$BA_PCT <- 100 * sp$BA / as.numeric(tot[sp$STAND_ID])
  rownames(sp) <- NULL
  sp
}

#' Diameter-class (stand and stock) table.
dbh_class_summary <- function(expanded, data, stand_id = NULL, class_width = 2,
                              by_species = FALSE) {
  tr <- expanded$trees[expanded$trees$IS_LIVE %in% TRUE, , drop = FALSE]
  if (!is.null(stand_id)) tr <- tr[tr$STAND_ID %in% stand_id, , drop = FALSE]
  if (!nrow(tr)) return(data.frame())
  cls <- floor(tr$DIAMETER / class_width) * class_width + class_width / 2
  tr$DBH_CLASS <- cls
  keys <- if (by_species) list(tr$STAND_ID, tr$DBH_CLASS, tr$SPECIES) else list(tr$STAND_ID, tr$DBH_CLASS)
  key <- do.call(paste, c(keys, sep = "\r"))
  out <- do.call(rbind, lapply(split(tr, key), function(x) {
    tpa <- sum(x$TPA_STAND, na.rm = TRUE); ba <- sum(x$BA_STAND, na.rm = TRUE)
    data.frame(STAND_ID = x$STAND_ID[1],
               DBH_CLASS = x$DBH_CLASS[1],
               SPECIES = if (by_species) x$SPECIES[1] else "All",
               TREES = nrow(x), TPA = tpa, BA = ba,
               MEAN_HT = if (any(!is.na(x$HT))) stats::weighted.mean(x$HT, x$TPA_STAND, na.rm = TRUE) else NA_real_,
               stringsAsFactors = FALSE)
  }))
  out <- out[order(out$STAND_ID, out$SPECIES, out$DBH_CLASS), ]
  rownames(out) <- NULL
  out
}
