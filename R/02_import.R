# ------------------------------------------------------------------------------
# Reading FVS-format inventory data.
#
# uFVS V1 reads the formats FVS already supports rather than inventing a new
# cruise format: the FVS input database schema (FVS_StandInit, FVS_PlotInit,
# FVS_TreeInit) delivered as an Excel workbook, a set of CSVs, or a SQLite
# database.
# ------------------------------------------------------------------------------

FVS_TABLES <- c(stands = "FVS_StandInit", plots = "FVS_PlotInit", trees = "FVS_TreeInit")

# Columns uFVS relies on. Anything else in the source is carried through intact.
STAND_KEY_COLS <- c("STAND_ID", "VARIANT", "INV_YEAR", "NUM_PLOTS", "NONSTK_PLOTS",
                    "BASAL_AREA_FACTOR", "INV_PLOT_SIZE", "BRK_DBH", "SAM_WT",
                    "SITE_SPECIES", "SITE_INDEX", "AGE", "GROUPS", "STAND_CN",
                    "LATITUDE", "LONGITUDE", "SLOPE", "ASPECT", "ELEVATION")
TREE_KEY_COLS  <- c("STAND_ID", "PLOT_ID", "TREE_ID", "TREE_COUNT", "HISTORY",
                    "SPECIES", "DIAMETER", "HT", "CRRATIO", "DEFECT_CUBIC",
                    "DEFECT_BOARD", "PRESCRIPTION")

upcase_names <- function(df) {
  if (is.null(df)) return(NULL)
  names(df) <- toupper(trimws(names(df)))
  df
}

#' Detect the kind of file the user picked.
detect_source_type <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (ext %in% c("xlsx", "xlsm", "xls")) return("excel")
  if (ext %in% c("db", "sqlite", "sqlite3", "fvsdb")) return("sqlite")
  if (ext == "csv") return("csv")
  if (dir.exists(path)) return("csvdir")
  "unknown"
}

#' Import an FVS input dataset.
#'
#' @return list(stands, plots, trees, source) or stops with a readable message.
#' @param path one file, a directory, or several files for the CSV route
#' @param names display names matching `path`, when uploads are renamed
import_fvs_data <- function(path, tree_csv = NULL, names = NULL) {
  path <- as.character(path)
  if (!length(path)) {
    stop("No input file was selected.", call. = FALSE)
  }

  # Keep the old two-file calling convention usable, but route it through the
  # same named CSV-set path as the multi-file upload. This is also important for
  # project reloads: the complete set of source files must remain identifiable.
  if (!is.null(tree_csv)) path <- c(path, as.character(tree_csv))
  labels <- if (is.null(names)) basename(path) else as.character(names)
  if (length(labels) != length(path)) labels <- basename(path)

  # Several files can only mean the CSV route.
  if (length(path) > 1) {
    out <- import_csv_set(path, labels)
    out$stands <- upcase_names(out$stands); out$plots <- upcase_names(out$plots)
    out$trees <- upcase_names(out$trees)
    return(finalize_import(out, list(path = path[1], paths = path, names = labels,
                                     type = "csv",
                                     name = paste(labels, collapse = " + "),
                                     imported_at = Sys.time())))
  }
  type <- detect_source_type(path)
  out <- switch(type,
    excel  = import_excel(path),
    sqlite = import_sqlite(path),
    csv    = import_csv_set(path, tree_csv),
    csvdir = import_csv_dir(path),
    stop("Unrecognised input '", basename(path), "'. uFVS reads an FVS input ",
         "database (.db/.sqlite), an Excel workbook with FVS_StandInit / ",
         "FVS_TreeInit sheets, or CSVs using those table names.")
  )

  finalize_import(out, list(path = path, paths = path, names = basename(path),
                            type = type, name = basename(path),
                            imported_at = Sys.time()))
}

#' Normalize an imported dataset and attach its source record.
#'
#' Shared by every import route so the CSV, Excel and database paths produce
#' identical structures. Structural problems are reported by validate_schema();
#' this only guarantees types and keys for the tables that are present.
finalize_import <- function(out, source) {
  out$stands <- upcase_names(out$stands)
  out$plots  <- upcase_names(out$plots)
  out$trees  <- upcase_names(out$trees)

  if (is.null(out$stands) || !nrow(out$stands))
    stop("No FVS_StandInit records found in ", nz(source$name, "the input"), ".", call. = FALSE)
  if (is.null(out$trees) || !nrow(out$trees))
    stop("No FVS_TreeInit records found in ", nz(source$name, "the input"), ".", call. = FALSE)
  if (!"STAND_ID" %in% names(out$stands))
    stop("FVS_StandInit has no STAND_ID column.", call. = FALSE)
  if (!"STAND_ID" %in% names(out$trees))
    stop("FVS_TreeInit has no STAND_ID column.", call. = FALSE)

  # Keys as character so joins never depend on numeric formatting.
  out$stands$STAND_ID <- as.character(out$stands$STAND_ID)
  out$trees$STAND_ID  <- as.character(out$trees$STAND_ID)
  if (!is.null(out$plots) && nrow(out$plots) && "STAND_ID" %in% names(out$plots))
    out$plots$STAND_ID <- as.character(out$plots$STAND_ID)

  if (!"PLOT_ID" %in% names(out$trees)) out$trees$PLOT_ID <- 1L
  out$trees$PLOT_ID <- as.character(nz(out$trees$PLOT_ID, "1"))
  out$trees$PLOT_ID[is.na(out$trees$PLOT_ID)] <- "1"

  for (cc in c("DIAMETER", "HT", "TREE_COUNT", "CRRATIO", "DEFECT_CUBIC", "DEFECT_BOARD")) {
    if (cc %in% names(out$trees)) out$trees[[cc]] <- safe_num(out$trees[[cc]])
  }
  for (cc in c("NUM_PLOTS", "NONSTK_PLOTS", "BASAL_AREA_FACTOR", "INV_PLOT_SIZE",
               "BRK_DBH", "SAM_WT", "INV_YEAR", "SITE_INDEX", "AGE")) {
    if (cc %in% names(out$stands)) out$stands[[cc]] <- safe_num(out$stands[[cc]])
  }
  if ("SPECIES" %in% names(out$trees))
    out$trees$SPECIES <- toupper(trimws(as.character(out$trees$SPECIES)))
  if ("VARIANT" %in% names(out$stands))
    out$stands$VARIANT <- tolower(trimws(as.character(out$stands$VARIANT)))

  out$source <- source
  out
}

import_excel <- function(path) {
  sheets <- readxl::excel_sheets(path)
  pick <- function(want) {
    hit <- sheets[toupper(sheets) == toupper(want)]
    if (!length(hit)) return(NULL)
    as.data.frame(suppressWarnings(readxl::read_excel(path, sheet = hit[1], guess_max = 100000)))
  }
  list(stands = pick(FVS_TABLES[["stands"]]),
       plots  = pick(FVS_TABLES[["plots"]]),
       trees  = pick(FVS_TABLES[["trees"]]))
}

import_sqlite <- function(path) {
  con <- DBI::dbConnect(RSQLite::SQLite(), path)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  have <- DBI::dbListTables(con)
  pick <- function(want) {
    hit <- have[toupper(have) == toupper(want)]
    if (!length(hit)) return(NULL)
    DBI::dbReadTable(con, hit[1])
  }
  list(stands = pick(FVS_TABLES[["stands"]]),
       plots  = pick(FVS_TABLES[["plots"]]),
       trees  = pick(FVS_TABLES[["trees"]]))
}

#' Assign a set of CSV files to FVS tables by their names.
#'
#' A single CSV cannot be an FVS inventory: the stand and tree tables are
#' separate files. This matches whatever the user selected against the FVS
#' table names and says exactly what is missing when something is.
#'
#' @param paths file paths on disk
#' @param names optional display names, when the upload path is randomized
import_csv_set <- function(paths, names = NULL) {
  paths <- as.character(paths)
  labels <- if (is.null(names)) basename(paths) else as.character(names)
  if (length(labels) != length(paths)) labels <- basename(paths)
  find_one <- function(want) {
    hit <- which(grepl(want, labels, ignore.case = TRUE))
    if (!length(hit)) return(NULL)
    utils::read.csv(paths[hit[1]], stringsAsFactors = FALSE)
  }
  stands <- find_one("StandInit")
  trees <- find_one("TreeInit")
  plots <- find_one("PlotInit")

  missing <- c(if (is.null(stands)) "FVS_StandInit", if (is.null(trees)) "FVS_TreeInit")
  if (length(missing)) {
    stop("CSV import needs one file per FVS table, matched by file name. ",
         "Missing: ", paste(missing, collapse = " and "), ". ",
         "Selected: ", paste(labels, collapse = ", "),
         ". Rename the files so each contains its table name, and select them together.",
         call. = FALSE)
  }
  list(stands = stands, plots = plots, trees = trees)
}

import_csv_dir <- function(dir) {
  files <- list.files(dir, pattern = "\\.csv$", full.names = TRUE, ignore.case = TRUE)
  find_one <- function(want) {
    hit <- files[grepl(want, basename(files), ignore.case = TRUE)]
    if (!length(hit)) return(NULL)
    utils::read.csv(hit[1], stringsAsFactors = FALSE)
  }
  list(stands = find_one("StandInit"),
       plots  = find_one("PlotInit"),
       trees  = find_one("TreeInit"))
}

#' Write an imported dataset back out as an FVS input SQLite database.
#'
#' The FVS Database extension reads this directly, so it is what the runner
#' hands to the engine.
write_fvs_input_db <- function(data, path) {
  con <- DBI::dbConnect(RSQLite::SQLite(), path)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  DBI::dbWriteTable(con, "FVS_StandInit", data$stands, overwrite = TRUE)
  if (!is.null(data$plots) && nrow(data$plots))
    DBI::dbWriteTable(con, "FVS_PlotInit", data$plots, overwrite = TRUE)
  DBI::dbWriteTable(con, "FVS_TreeInit", data$trees, overwrite = TRUE)
  invisible(path)
}
