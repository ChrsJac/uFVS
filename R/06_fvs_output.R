# ------------------------------------------------------------------------------
# FVS output: the variables FVS produces, and what uFVS is allowed to do with
# them.
#
# uFVS implements no growth, mortality, volume, taper, or biomass mathematics.
# Every volume figure in the application comes from FVS's own output tables,
# which are produced by the National Volume Estimator Library under the control
# of the VOLUME, BFVOLUME and VOLEQNUM keywords.
#
# uFVS does exactly three things with those numbers:
#
#   1. reads them (normalization),
#   2. selects and groups rows of them (products, species, diameter classes),
#   3. summarizes them (totals, and sampling statistics across plots).
#
# Selection and summation are not new equations. Anything that would require a
# new equation - converting cubic feet to green tons, estimating a volume FVS
# did not report, bucking a stem uFVS cannot see - is not done here.
# ------------------------------------------------------------------------------

#' The FVS output tables uFVS reads, and the keyword that produces each.
FVS_OUTPUT_TABLES <- list(
  FVS_Summary2   = list(keyword = "Summary",  grain = "stand-year",
                        label = "Stand summary"),
  FVS_TreeList   = list(keyword = "TreeLiDB", grain = "tree-year",
                        label = "Tree list (live, after treatment)"),
  FVS_CutList    = list(keyword = "CutLiDB",  grain = "tree-year",
                        label = "Cut list (trees removed)"),
  FVS_ATRTList   = list(keyword = "AtrtLiDB", grain = "tree-year",
                        label = "After-treatment tree list"),
  FVS_Compute    = list(keyword = "Computdb", grain = "stand-year",
                        label = "Event Monitor computed variables"),
  FVS_StrClass   = list(keyword = "StrClsDB", grain = "stand-year",
                        label = "Structural classes")
)

#' Volume columns FVS reports on its tree lists, with the meaning of each.
#'
#' These names are FVS's, not uFVS's, and they are shown to the user unchanged.
FVS_TREE_VOLUME_COLS <- list(
  TCuFt = list(label = "Total cubic feet",        unit = "ft3", per = "tree"),
  MCuFt = list(label = "Merchantable cubic feet", unit = "ft3", per = "tree"),
  SCuFt = list(label = "Sawlog cubic feet",       unit = "ft3", per = "tree"),
  BdFt  = list(label = "Board feet",              unit = "bd ft", per = "tree")
)

#' Stand-level volume columns on FVS_Summary2.
FVS_SUMMARY_VOLUME_COLS <- c("TCuFt", "MCuFt", "SCuFt", "BdFt",
                             "RTCuFt", "RMCuFt", "RSCuFt", "RBdFt")

#' Is a per-tree FVS volume column already per acre?
#'
#' No. FVS tree lists report volume PER TREE and carry TPA separately, so a per
#' acre figure is volume * TPA. Getting this backwards inflates every product
#' total by the expansion factor, so it lives in one documented place.
tree_volume_per_acre <- function(tree_rows, col) {
  if (!col %in% names(tree_rows)) return(rep(NA_real_, nrow(tree_rows)))
  safe_num(tree_rows[[col]]) * safe_num(tree_rows$TPA)
}

# ------------------------------------------------------------------------------
# Native FVS volume controls
# ------------------------------------------------------------------------------

#' The FVS keywords that control merchantability, kept under their own names.
#'
#' uFVS presents these as ordinary keyword forms built from the official
#' catalog; it does not wrap them in invented terminology and does not
#' substitute its own arithmetic for them.
volume_control_keywords <- function() {
  kws <- c("Volume", "BFVolume", "VolEqNum", "MCDefect", "BFDefect",
           "MCFDLN", "BFFDLN", "SpLabel")
  d <- keyword_defs()
  d[tolower(d$keyword) %in% tolower(kws), , drop = FALSE]
}

#' Default volume settings: which FVS keyword records uFVS will emit, if any.
#'
#' Empty by default. FVS applies its own variant defaults when uFVS says
#' nothing, which is the correct behavior - uFVS should not quietly change a
#' merchantability standard the user did not set.
default_volume_settings <- function() {
  list(
    use_defaults = TRUE,      # emit no VOLUME/BFVOLUME records
    keywords = list()         # list(keyword=, values=list()) when the user sets them
  )
}

render_volume_keywords <- function(vol_settings) {
  if (isTRUE(vol_settings$use_defaults) || !length(vol_settings$keywords)) return(character(0))
  vapply(vol_settings$keywords, function(k) render_keyword(k$keyword, k$values), character(1))
}

volume_provenance_note <- function(have_run) {
  if (have_run) {
    list(tag = PROV[["FVS"]],
         text = paste("Volumes are FVS output, computed by the National Volume Estimator",
                      "Library under this run's VOLUME / BFVOLUME / VOLEQNUM settings.",
                      "uFVS grouped and totalled them; it did not recompute them."))
  } else {
    list(tag = PROV[["UFVS"]],
         text = paste("No FVS run yet, so no volumes are available. uFVS does not estimate",
                      "volume itself. Trees per acre and basal area shown here are the",
                      "inventory's own expansion and the definition of basal area",
                      "(0.005454 x DBH^2), not modeled quantities."))
  }
}
