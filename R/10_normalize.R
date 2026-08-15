# ------------------------------------------------------------------------------
# Reading FVS output into a stable internal shape.
#
# FVS writes a SQLite database whose tables depend on which output keywords were
# active and which extensions are compiled into the variant. uFVS reads what is
# there, renames nothing, and presents a consistent set of logical tables to the
# rest of the application.
#
# Column names stay as FVS wrote them. A forester who knows FVS should recognize
# every column, and a value that came from FVS should be traceable back to the
# table and column it came from.
# ------------------------------------------------------------------------------

#' Read an FVS output database.
#'
#' @return list of data.frames keyed by FVS table name, plus `tables` (what was
#'   found) and `missing` (what was expected but absent).
read_fvs_output <- function(db_path) {
  if (!file.exists(db_path)) {
    return(list(tables = character(0), missing = names(FVS_OUTPUT_TABLES),
                error = paste0("No output database at ", db_path)))
  }
  con <- tryCatch(DBI::dbConnect(RSQLite::SQLite(), db_path), error = function(e) NULL)
  if (is.null(con)) {
    return(list(tables = character(0), missing = names(FVS_OUTPUT_TABLES),
                error = paste0("Could not open ", db_path)))
  }
  on.exit(DBI::dbDisconnect(con), add = TRUE)

  have <- DBI::dbListTables(con)
  out <- list()
  for (t in have) {
    d <- tryCatch(DBI::dbReadTable(con, t), error = function(e) NULL)
    if (!is.null(d)) out[[t]] <- d
  }
  out$tables <- have
  out$missing <- setdiff(names(FVS_OUTPUT_TABLES), have)
  out
}

#' Standard logical tables built from an FVS output database.
#'
#' Nothing is computed here beyond selecting rows and attaching the scenario
#' label. Where FVS did not produce a table, the entry is NULL and the interface
#' explains which output keyword would have produced it.
normalize_fvs_output <- function(fvs, scenario = "Base") {
  tag <- function(d) {
    if (is.null(d) || !nrow(d)) return(NULL)
    d$SCENARIO <- scenario
    d
  }
  list(
    StandSummary = tag(fvs$FVS_Summary2 %||% fvs$FVS_Summary),
    TreeList     = tag(fvs$FVS_TreeList),
    CutList      = tag(fvs$FVS_CutList),
    ATRTList     = tag(fvs$FVS_ATRTList),
    Compute      = tag(fvs$FVS_Compute),
    StrClass     = tag(fvs$FVS_StrClass),
    Carbon       = tag(fvs$FVS_Carbon),
    Fuels        = tag(fvs$FVS_Fuels),
    PotFire      = tag(fvs$FVS_PotFire),
    Mortality    = tag(fvs$FVS_Mortality),
    Economics    = tag(fvs$FVS_EconSummary %||% fvs$FVS_EconHarvestValue),
    tables       = fvs$tables,
    missing      = fvs$missing,
    scenario     = scenario
  )
}

#' Which output keyword produces a table that is missing.
missing_table_advice <- function(missing) {
  if (!length(missing)) return(character(0))
  vapply(missing, function(t) {
    info <- FVS_OUTPUT_TABLES[[t]]
    if (is.null(info)) return(paste0(t, " was not produced."))
    sprintf("%s (%s) is absent. Add the %s output keyword to the run.",
            t, info$label, info$keyword)
  }, character(1))
}

#' Combine several runs into one comparison set.
combine_scenarios <- function(normalized_list) {
  nm <- c("StandSummary", "TreeList", "CutList", "Compute")
  out <- list()
  for (n in nm) {
    parts <- lapply(normalized_list, function(x) x[[n]])
    parts <- parts[!vapply(parts, is.null, logical(1))]
    if (!length(parts)) { out[[n]] <- NULL; next }
    common <- Reduce(intersect, lapply(parts, names))
    out[[n]] <- do.call(rbind, lapply(parts, function(p) p[, common, drop = FALSE]))
  }
  out
}

# ------------------------------------------------------------------------------
# Statistics on FVS output
# ------------------------------------------------------------------------------

#' Per-plot values of an FVS tree-list column, for sampling statistics.
#'
#' FVS_TreeList carries PtIndex, the plot the record came from, so plot-level
#' statistics can be formed on FVS output exactly as on the raw inventory.
#'
#' Read the result carefully. This is the sampling variability of an estimate
#' across the plots that were cruised. It is NOT a confidence interval around
#' FVS's biological prediction: it contains no model uncertainty at all, and
#' uFVS never labels it as though it did.
fvs_plot_values <- function(tree_list, column, year, stand_id = NULL,
                            n_plots = NULL, products = NULL) {
  if (is.null(tree_list) || !nrow(tree_list)) return(list())
  d <- tree_list[tree_list$Year %in% year, , drop = FALSE]
  if (!is.null(stand_id)) d <- d[d$StandID %in% stand_id, , drop = FALSE]
  if (!nrow(d) || !"PtIndex" %in% names(d)) return(list())

  d$VALUE <- if (column %in% names(FVS_TREE_VOLUME_COLS)) {
    tree_volume_per_acre(d, column)
  } else if (identical(column, "TPA")) {
    safe_num(d$TPA)
  } else if (identical(column, "BA")) {
    ba_of_dbh(safe_num(d$DBH)) * safe_num(d$TPA)
  } else {
    safe_num(col_or(d, column, NA))
  }

  # Every cruised plot must appear, including those with nothing in the class.
  pts <- sort(unique(safe_num(d$PtIndex)))
  if (!is.null(n_plots) && n_plots > length(pts)) {
    pts <- c(pts, seq(max(pts, 0) + 1, length.out = n_plots - length(pts)))
  }
  all_plots <- data.frame(STAND_ID = nz(stand_id, d$StandID[1]),
                          PLOT_ID = as.character(pts), stringsAsFactors = FALSE)
  d$STAND_ID <- d$StandID
  d$PLOT_ID <- as.character(safe_num(d$PtIndex))

  if (!is.null(products)) {
    d$PRODUCT <- assign_products(d, products)
    plot_group_values(d, all_plots, "VALUE", "PRODUCT")
  } else {
    plot_group_values(d, all_plots, "VALUE", NULL)
  }
}
