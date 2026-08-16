#!/usr/bin/env Rscript
# The packaged-application acceptance test, run with the bundled interpreter
# against an extracted package.
#
# It goes through what a user does on their first afternoon with uFVS: open a
# native FVS SQLite database, look at the inventory it contains, run a
# projection through the bundled engine, and read the results. Each step uses
# the application's own functions, so a regression in the packaged layout shows
# up here rather than in front of a user.
#
# Run it exactly as the launcher would run the app:
#
#   macOS    RES="uFVS.app/Contents/Resources"
#            UFVS_RELEASE=1 UFVS_APP_DIR="$RES/app" UFVS_RUNTIME_DIR="$RES/R" \
#            UFVS_LIBRARY_DIR="$RES/R-library" UFVS_FVS_DIR="$RES/fvs" \
#            UFVS_RESOURCES_DIR="$RES" "$RES/R/Rscript" tools/acceptance_test.R
#
#   Windows  set the same variables against app\, runtime\R, runtime\R-library,
#            fvs\ and resources\, then run runtime\R\bin\Rscript.exe.

args <- commandArgs(trailingOnly = TRUE)
value_for <- function(flag, default = "") {
  i <- match(flag, args)
  if (!is.na(i) && i < length(args)) args[i + 1L] else default
}
env_or <- function(name, default) {
  v <- Sys.getenv(name, unset = "")
  if (nzchar(v)) v else default
}
step <- function(...) cat("  [ok] ", ..., "\n", sep = "")

app_dir <- value_for("--app", env_or("UFVS_APP_DIR", ""))
if (!nzchar(app_dir) || !dir.exists(app_dir))
  stop("Pass --app or export UFVS_APP_DIR.", call. = FALSE)
app_dir <- normalizePath(app_dir, mustWork = TRUE)
# Resolve before the working directory moves, so a relative path on the command
# line still means what the caller meant.
sample_db <- value_for("--sample-db", "")
if (nzchar(sample_db)) sample_db <- normalizePath(sample_db, mustWork = FALSE)
runtime_dir <- normalizePath(env_or("UFVS_RUNTIME_DIR", file.path(app_dir, "runtime")),
                             mustWork = FALSE)
library_dir <- normalizePath(env_or("UFVS_LIBRARY_DIR", file.path(app_dir, "library")),
                             mustWork = FALSE)

setwd(app_dir)
options(ufvs.root = app_dir, ufvs.release = TRUE)
if (dir.exists(library_dir)) .libPaths(unique(c(library_dir, .libPaths())))

# Keep the user's real projects, datasets and settings out of a test run.
work_dir <- file.path(tempdir(), "ufvs-acceptance")
unlink(work_dir, recursive = TRUE, force = TRUE)
dir.create(work_dir, showWarnings = FALSE, recursive = TRUE)
options(ufvs.user_dir = work_dir)

suppressPackageStartupMessages({
  library(shiny); library(ggplot2); library(jsonlite); library(DBI)
  library(RSQLite); library(readxl); library(callr); library(digest)
})
for (f in sort(list.files(file.path(app_dir, "R"), pattern = "[.]R$", full.names = TRUE)))
  source(f)

cat("uFVS packaged acceptance test\n")

# --- 1. the bundled runtime is the one in use ---------------------------------
r_home <- normalizePath(R.home(), mustWork = FALSE)
if (!startsWith(r_home, runtime_dir))
  stop("Not running on the bundled R runtime: ", r_home, call. = FALSE)
for (path in .libPaths()) {
  # Base and recommended packages legitimately live inside the bundled runtime.
  if (startsWith(normalizePath(path, mustWork = FALSE), runtime_dir)) next
  if (identical(normalizePath(path, mustWork = FALSE), library_dir)) next
  stop("A library path outside the package is active: ", path, call. = FALSE)
}
step("bundled R runtime in use: ", r_home)
step("private package library:  ", library_dir)

# --- 2. the bundled FVS engine is present -------------------------------------
variants <- bundled_variants()
if (!length(variants)) stop("No FVS variant is bundled.", call. = FALSE)
engine <- load_engine_config()
if (!identical(engine$mode, "bundled"))
  stop("The packaged app did not select its bundled engine; mode was ", engine$mode, call. = FALSE)
step("bundled FVS engine: ", engine$path, " (", paste(toupper(variants), collapse = ", "), ")")

# --- 3. a native FVS SQLite database opens ------------------------------------
# Written in the native FVS input schema, with all three initialisation tables,
# because that is what uFVS has to accept from an FVS user.
fixture_db <- file.path(work_dir, "Acceptance Data.db")   # a space, deliberately
stands <- data.frame(
  STAND_ID = "ACC1", VARIANT = "sn", INV_YEAR = 2024L, NUM_PLOTS = 2L,
  BASAL_AREA_FACTOR = -10, INV_PLOT_SIZE = NA_real_, BRK_DBH = 2,
  NONSTK_PLOTS = 0, SITE_SPECIES = "LP", SITE_INDEX = 85,
  stringsAsFactors = FALSE)
plots <- data.frame(
  STAND_ID = "ACC1", PLOT_ID = c("1", "2"), SLOPE = c(5, 10),
  ASPECT = c(0, 180), ELEVATION = c(8, 8), stringsAsFactors = FALSE)
trees <- data.frame(
  STAND_ID = "ACC1", PLOT_ID = rep(c("1", "2"), each = 5),
  TREE_ID = 1:10, TREE_COUNT = NA_real_, HISTORY = 1L,
  SPECIES = rep(c("LP", "SU", "RO", "WO", "SP"), 2),
  DIAMETER = c(8, 11, 14, 17, 20, 9, 12, 15, 18, 21),
  HT = c(50, 62, 74, 84, 92, 54, 66, 76, 86, 95),
  stringsAsFactors = FALSE)
con <- DBI::dbConnect(RSQLite::SQLite(), fixture_db)
DBI::dbWriteTable(con, "FVS_StandInit", stands, overwrite = TRUE)
DBI::dbWriteTable(con, "FVS_PlotInit", plots, overwrite = TRUE)
DBI::dbWriteTable(con, "FVS_TreeInit", trees, overwrite = TRUE)
DBI::dbDisconnect(con)

present <- DBI::dbListTables(DBI::dbConnect(RSQLite::SQLite(), fixture_db))
for (table in c("FVS_StandInit", "FVS_PlotInit", "FVS_TreeInit")) {
  if (!table %in% present) stop("Fixture is missing ", table, call. = FALSE)
}

data <- import_fvs_data(fixture_db)
if (is.null(data$stands) || !nrow(data$stands)) stop("FVS_StandInit did not import.", call. = FALSE)
if (is.null(data$trees) || !nrow(data$trees)) stop("FVS_TreeInit did not import.", call. = FALSE)
if (is.null(data$plots) || !nrow(data$plots)) stop("FVS_PlotInit did not import.", call. = FALSE)
step("opened a native FVS database from a path containing a space")
step("read FVS_StandInit (", nrow(data$stands), "), FVS_PlotInit (", nrow(data$plots),
     "), FVS_TreeInit (", nrow(data$trees), ")")

# Also open one of the real user databases when the caller supplies one.
if (nzchar(sample_db) && file.exists(sample_db)) {
  sample <- import_fvs_data(normalizePath(sample_db))
  if (is.null(sample$trees) || !nrow(sample$trees))
    stop("The supplied sample database imported no trees.", call. = FALSE)
  step("opened the supplied sample database: ", basename(sample_db), " (",
       nrow(sample$trees), " trees)")
}

# --- 4. the inventory summarises before anything is run -----------------------
expanded <- expand_inventory(data)
if (is.null(expanded$trees) || !nrow(expanded$trees))
  stop("Inventory expansion produced no tree records.", call. = FALSE)
if (!all(c("TPA_PLOT", "TPA_STAND", "BA_STAND") %in% names(expanded$trees)))
  stop("Inventory expansion did not add the per-acre columns.", call. = FALSE)
step("expanded the inventory to ", nrow(expanded$trees), " records across ",
     length(expanded$designs), " stand design(s)")

# --- 5. a real FVS projection runs in an isolated worker ----------------------
scenario <- list(name = "Acceptance", cycles = 3L, cycle_length = 5L,
                 start_year = 2024L, events = list(), raw_keywords = "",
                 computes = list(), volume = default_volume_settings(), svs = FALSE)

dispatch <- check_variant_dispatch(data, "ACC1", engine)
if (!all(dispatch$ok))
  stop("Variant dispatch refused the run: ", paste(dispatch$reason, collapse = "; "), call. = FALSE)

prep <- prepare_run(data, scenario, "ACC1", engine = engine, title = "uFVS acceptance",
                    runs_dir = file.path(work_dir, "runs"))
job <- launch_run(prep, engine = engine)
deadline <- Sys.time() + 300
state <- NULL
repeat {
  state <- run_status(job)
  if (!identical(state$state, "running")) break
  if (Sys.time() > deadline) stop("The FVS run did not finish within five minutes.", call. = FALSE)
  Sys.sleep(1)
}
if (!identical(state$state, "success")) {
  logs <- run_logs(prep$dir)
  detail <- unlist(logs[intersect(names(logs), c("fvs_stdout.log", "fvs_stderr.log",
                                                 "worker_stderr.log"))])
  stop("The FVS run failed at stage ", nz(state$stage, "unknown"), ": ",
       nz(state$message, ""), "\n", paste(utils::tail(detail, 25L), collapse = "\n"),
       call. = FALSE)
}
step("ran FVS in an isolated worker process: ", basename(prep$dir))

# --- 6. results are readable and renderable -----------------------------------
output_db <- file.path(prep$dir, "FVSOut.db")
if (!file.exists(output_db)) stop("The run produced no FVSOut.db.", call. = FALSE)
fvs <- read_fvs_output(output_db)
summary_table <- fvs$FVS_Summary2 %||% fvs$FVS_Summary
if (is.null(summary_table) || !nrow(summary_table))
  stop("The run produced no stand summary.", call. = FALSE)

years <- safe_num(summary_table[[grep("^year$", names(summary_table), ignore.case = TRUE)[1]]])
if (!any(years == 2024) || !any(years > 2024))
  stop("The summary does not span the inventory year and a projection year.", call. = FALSE)
step("read FVS output tables: ", paste(fvs$tables, collapse = ", "))
step("summary covers years ", min(years, na.rm = TRUE), "-", max(years, na.rm = TRUE))

# Rendering is what the user sees, so build a real chart from the real output
# rather than trusting that the numbers alone imply a working results page.
# The results pages work from the normalized logical tables, not from the raw
# FVS table names, so the chart has to be built the same way.
normalized <- normalize_fvs_output(fvs, scenario = "Acceptance")
tables <- Filter(is.data.frame, normalized)
if (is.null(tables$StandSummary) || !nrow(tables$StandSummary))
  stop("Normalizing the FVS output produced no StandSummary.", call. = FALSE)
step("normalized output to logical tables: ", paste(names(tables), collapse = ", "))

spec <- default_chart_spec()      # Year against basal area, the default view
validation <- validate_chart(spec, tables)
if (!isTRUE(validation$ok))
  stop("The default results chart was rejected: ", nz(validation$message, ""), call. = FALSE)
chart <- try(build_chart(spec, tables, validation), silent = TRUE)
if (inherits(chart, "try-error") || is.null(chart$plot))
  stop("A results chart could not be built from the run output: ",
       if (inherits(chart, "try-error")) conditionMessage(attr(chart, "condition"))
       else nz(chart$message, ""), call. = FALSE)

png_file <- file.path(work_dir, "acceptance-chart.png")
ok <- try(ggplot2::ggsave(png_file, chart$plot, width = 6, height = 4, dpi = 96),
          silent = TRUE)
if (inherits(ok, "try-error") || !file.exists(png_file) || file.info(png_file)$size == 0)
  stop("The results chart did not render to an image.", call. = FALSE)
step("rendered a results chart (", file.info(png_file)$size, " bytes)")

# The UI itself has to build with real results loaded.
ui <- try(as.character(ufvs_ui()), silent = TRUE)
if (inherits(ui, "try-error")) stop("The application UI could not be built.", call. = FALSE)
step("built the application interface")

cat("\nAcceptance test passed.\n")
