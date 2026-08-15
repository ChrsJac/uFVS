# ------------------------------------------------------------------------------
# Product classes.
#
# A product class in uFVS is a FILTER, not a model. It is a diameter range plus
# an optional species list. uFVS applies it to rows of FVS's own tree list and
# adds up FVS's own volume columns within it.
#
# The point is to answer "how much of what do I have, by class and species"
# without losing anything: FVS's lumped totals stay exactly as FVS reported
# them, and the class breakdown always sums back to them. If a class breakdown
# and the FVS total disagree, that is a bug in uFVS, and reconcile_products()
# exists to catch it.
#
# uFVS does not buck stems, does not estimate volume, and does not convert
# between units FVS did not report.
# ------------------------------------------------------------------------------

#' Starter product classes: pure diameter limits, applying to all species.
#'
#' Users rename these, change the limits, add classes, and restrict any class to
#' particular species. The breaks below are a common southern convention and
#' nothing in the code depends on them.
default_products <- function() {
  list(
    list(id = "pulpwood",  name = "Pulpwood",   species = "*", min_dbh = 5,  max_dbh = 9),
    list(id = "cns",       name = "Chip-n-saw", species = "*", min_dbh = 9,  max_dbh = 12),
    list(id = "sawtimber", name = "Sawtimber",  species = "*", min_dbh = 12, max_dbh = 999)
  )
}

#' Diameter ranges are half-open [min, max) so adjacent classes cannot double
#' count a tree sitting exactly on a break.
product_species <- function(product) {
  sp <- unlist(product$species, use.names = FALSE)
  sp <- trimws(as.character(sp))
  sp <- sp[!is.na(sp) & nzchar(sp)]
  if (!length(sp) || any(sp == "*")) "*" else unique(sp)
}

product_matches <- function(product, species, dbh) {
  wanted <- product_species(product)
  sp_ok <- if (identical(wanted, "*")) {
    rep(TRUE, length(species))
  } else {
    species %in% wanted
  }
  d_ok <- !is.na(dbh) & dbh >= nz(product$min_dbh, -Inf) & dbh < nz(product$max_dbh, Inf)
  sp_ok & d_ok
}

#' Assign every row of a tree list to at most one product class.
#'
#' First matching rule wins, so rule order is the user's tie-breaker. Trees that
#' match nothing are labeled rather than dropped, because a class table that
#' silently loses trees is worse than one that shows an "Unclassified" row.
assign_products <- function(trees, products = default_products(),
                            dbh_col = "DBH", species_col = "SpeciesFVS") {
  if (!nrow(trees)) return(character(0))
  dbh <- safe_num(trees[[dbh_col]])
  sp <- as.character(col_or(trees, species_col, NA))
  out <- rep(NA_character_, nrow(trees))
  # A species-specific rule should be able to override a broad all-species
  # fallback, even when the fallback class was created first.
  specific_first <- order(vapply(products, function(p)
    identical(product_species(p), "*"), logical(1)))
  for (p in products[specific_first]) {
    hit <- is.na(out) & product_matches(p, sp, dbh)
    out[hit] <- p$name
  }
  out[is.na(out)] <- "Unclassified"
  out
}

#' Product summary from an FVS tree list.
#'
#' @param trees rows of FVS_TreeList / FVS_CutList for one scenario
#' @param products product class definitions
#' @param by additional grouping columns present in `trees`, e.g. "SpeciesFVS"
#' @return per-acre totals of FVS's own volume columns within each class
product_summary_fvs <- function(trees, products = default_products(),
                                by = character(0), year = NULL) {
  if (is.null(trees) || !nrow(trees)) return(data.frame())
  if (!is.null(year)) trees <- trees[trees$Year %in% year, , drop = FALSE]
  if (!nrow(trees)) return(data.frame())

  trees$PRODUCT <- assign_products(trees, products)
  group_cols <- c("StandID", "Year", "PRODUCT", by)
  group_cols <- intersect(group_cols, names(trees))
  key <- do.call(paste, c(lapply(group_cols, function(g) trees[[g]]), sep = "\r"))

  vol_cols <- intersect(names(FVS_TREE_VOLUME_COLS), names(trees))
  out <- do.call(rbind, lapply(split(trees, key), function(x) {
    base <- as.data.frame(lapply(group_cols, function(g) x[[g]][1]), stringsAsFactors = FALSE)
    names(base) <- group_cols
    base$TREES <- nrow(x)
    base$TPA <- sum(safe_num(x$TPA), na.rm = TRUE)
    base$BA <- sum(ba_of_dbh(safe_num(x$DBH)) * safe_num(x$TPA), na.rm = TRUE)
    base$QMD <- qmd_from(base$BA, base$TPA)
    for (v in vol_cols) base[[v]] <- sum(tree_volume_per_acre(x, v), na.rm = TRUE)
    if ("BdFt" %in% vol_cols) base$MBF <- base$BdFt / 1000
    base
  }))
  rownames(out) <- NULL
  out[order(out$StandID, out$Year, out$PRODUCT), , drop = FALSE]
}

#' Check that the product breakdown reproduces FVS's lumped totals.
#'
#' Selecting and summing should be lossless. This compares the sum over product
#' classes against FVS_Summary2 for the same stand and year and reports any
#' difference, so a filtering mistake surfaces as a number rather than as a
#' quietly wrong report.
reconcile_products <- function(product_tbl, summary_tbl, tol = 0.01) {
  if (!nrow(product_tbl) || is.null(summary_tbl) || !nrow(summary_tbl)) return(data.frame())
  cols <- intersect(c("TPA", "TCuFt", "MCuFt", "SCuFt", "BdFt"), names(product_tbl))
  cols <- intersect(cols, names(summary_tbl))
  key <- paste(product_tbl$StandID, product_tbl$Year, sep = "\r")
  agg <- do.call(rbind, lapply(split(product_tbl, key), function(x) {
    d <- data.frame(StandID = x$StandID[1], Year = x$Year[1], stringsAsFactors = FALSE)
    for (v in cols) d[[v]] <- sum(x[[v]], na.rm = TRUE)
    d
  }))
  skey <- paste(summary_tbl$StandID, summary_tbl$Year, sep = "\r")
  m <- match(paste(agg$StandID, agg$Year, sep = "\r"), skey)

  rows <- list()
  for (v in cols) {
    fvs_val <- safe_num(summary_tbl[[v]])[m]
    diff <- agg[[v]] - fvs_val
    bad <- which(!is.na(diff) & abs(diff) > pmax(tol, tol * abs(fvs_val)))
    for (i in bad) {
      rows[[length(rows) + 1]] <- data.frame(
        StandID = agg$StandID[i], Year = agg$Year[i], variable = v,
        product_total = agg[[v]][i], fvs_total = fvs_val[i], difference = diff[i],
        stringsAsFactors = FALSE)
    }
  }
  if (!length(rows)) return(data.frame())
  do.call(rbind, rows)
}

# ------------------------------------------------------------------------------
# Pre-run view
# ------------------------------------------------------------------------------

#' Product classes applied to the raw inventory, before any FVS run.
#'
#' Only trees per acre and basal area are reported. Basal area is the definition
#' 0.005454 * DBH^2, not a model. Volume is deliberately absent: producing it
#' would mean inventing equations FVS already owns.
product_summary_inventory <- function(expanded, products = default_products(),
                                      by = character(0)) {
  tr <- expanded$trees
  tr <- tr[tr$IS_LIVE %in% TRUE, , drop = FALSE]
  if (!nrow(tr)) return(data.frame())
  tr$PRODUCT <- assign_products(tr, products, dbh_col = "DIAMETER", species_col = "SPECIES")

  group_cols <- intersect(c("STAND_ID", "PRODUCT", by), names(tr))
  key <- do.call(paste, c(lapply(group_cols, function(g) tr[[g]]), sep = "\r"))
  out <- do.call(rbind, lapply(split(tr, key), function(x) {
    base <- as.data.frame(lapply(group_cols, function(g) x[[g]][1]), stringsAsFactors = FALSE)
    names(base) <- group_cols
    base$TREES <- nrow(x)
    base$TPA <- sum(x$TPA_STAND, na.rm = TRUE)
    base$BA <- sum(x$BA_STAND, na.rm = TRUE)
    base$QMD <- qmd_from(base$BA, base$TPA)
    base
  }))
  rownames(out) <- NULL
  out[order(out$STAND_ID, out$PRODUCT), , drop = FALSE]
}

#' Product-class definitions rendered as readable rules, for the methods panel.
describe_products <- function(products) {
  vapply(products, function(p) {
    wanted <- product_species(p)
    sp <- if (identical(wanted, "*")) "all species" else
      paste("species", paste(wanted, collapse = ", "))
    sprintf("%s: DBH %s to under %s in, %s",
            p$name, fmt_num(p$min_dbh, 1), fmt_num(p$max_dbh, 1), sp)
  }, character(1))
}
