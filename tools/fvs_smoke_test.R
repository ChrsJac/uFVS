#!/usr/bin/env Rscript
# Run a small real FVS projection from a staged release tree. This test is
# intentionally independent of the Shiny server: it proves the bundled R,
# package library, engine, input database, keyword file, and SQLite output work
# together after the release has been moved to its final extracted location.

args <- commandArgs(trailingOnly = TRUE)
value_for <- function(flag, default = "") {
  i <- match(flag, args)
  if (!is.na(i) && i < length(args)) args[i + 1L] else default
}

root <- value_for("--root")
engine <- value_for("--engine", file.path(root, "engine", "FVSsn"))
if (!nzchar(root) || !dir.exists(root)) stop("--root must name the staged release.", call. = FALSE)
root <- normalizePath(root, mustWork = TRUE)
engine <- normalizePath(engine, mustWork = TRUE)
root_prefix <- paste0(root, .Platform$file.sep)
if (!startsWith(engine, root_prefix)) stop("Smoke engine is outside the staged release.", call. = FALSE)

setwd(root)
options(ufvs.root = root, ufvs.release = TRUE)
library_dir <- file.path(root, "library")
if (dir.exists(library_dir)) .libPaths(unique(c(library_dir, .libPaths())))
suppressPackageStartupMessages({
  library(shiny); library(ggplot2); library(jsonlite); library(DBI)
  library(RSQLite); library(readxl); library(callr); library(digest)
})
for (f in sort(list.files(file.path(root, "R"), pattern = "[.]R$", full.names = TRUE)))
  source(f)

runtime_root <- normalizePath(file.path(root, "runtime"), mustWork = FALSE)
if (!startsWith(normalizePath(R.home(), mustWork = FALSE), paste0(runtime_root, .Platform$file.sep)))
  stop("The smoke test is not using the staged R runtime: ", R.home(), call. = FALSE)

stands <- data.frame(
  STAND_ID = "T1", VARIANT = "sn", INV_YEAR = 2024L, NUM_PLOTS = 1L,
  BASAL_AREA_FACTOR = -10, INV_PLOT_SIZE = NA_real_, BRK_DBH = 2,
  NONSTK_PLOTS = NA_real_, SITE_SPECIES = "LP", SITE_INDEX = 85,
  stringsAsFactors = FALSE)
trees <- data.frame(
  STAND_ID = "T1", PLOT_ID = "1", TREE_ID = 1:3, TREE_COUNT = NA_real_,
  HISTORY = 1L, SPECIES = c("LP", "SU", "RO"),
  DIAMETER = c(10, 14, 18), HT = c(60, 75, 90), stringsAsFactors = FALSE)

fixture <- function(path) {
  unlink(path, force = TRUE)
  write_fvs_input_db(list(stands = stands, trees = trees, plots = NULL), path)
}

scenario_base <- list(name = "Base", cycles = 2L, cycle_length = 5L,
                      start_year = 2024L, events = list(), raw_keywords = "",
                      computes = list(), volume = default_volume_settings(), svs = FALSE)
scenario_thin <- list(
  name = "Thin", cycles = 2L, cycle_length = 5L, start_year = 2024L,
  events = list(list(keyword = "ThinBBA", year = 2029L,
                     values = list("2" = 10, "3" = 1, "4" = 5,
                                   "5" = 999, "6" = 0, "7" = 999))),
  raw_keywords = "", computes = list(), volume = default_volume_settings(), svs = FALSE)

run_one <- function(name, scenario) {
  dir <- file.path(tempdir(), paste0("ufvs-fvs-smoke-", tolower(name)))
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  input <- file.path(dir, "FVS_Data.db")
  fixture(input)
  key <- build_keyword_file("T1", scenario, input_db = "FVS_Data.db",
                            output_db = "FVSOut.db", title = paste("uFVS", name),
                            inv_years = list(T1 = 2024L))
  key_path <- file.path(dir, "run.key")
  writeLines(key, key_path)
  stdout <- file.path(dir, "fvs_stdout.log")
  stderr <- file.path(dir, "fvs_stderr.log")
  old_wd <- getwd()
  setwd(dir)
  on.exit(setwd(old_wd), add = TRUE)
  status <- tryCatch(system2(engine, args = paste0("--keywordfile=", basename(key_path)),
                              stdout = stdout, stderr = stderr, wait = TRUE),
                     error = function(e) structure(-1L, message = conditionMessage(e)))
  status <- as.integer(status[[1L]])
  # This FVS build uses STOP 10 after completing output when a nonfatal IEEE
  # underflow flag is raised. The uFVS runner treats that status as a completed
  # run; require the output database below rather than mistaking it for a hard
  # failure. Any other nonzero status is an engine failure.
  if (!status %in% c(0L, 10L)) {
    diagnostics <- c(if (file.exists(stdout)) readLines(stdout, warn = FALSE),
                     if (file.exists(stderr)) readLines(stderr, warn = FALSE))
    stop(name, " FVS smoke run exited with status ", status, ":\n",
         paste(utils::tail(diagnostics, 40L), collapse = "\n"), call. = FALSE)
  }
  output <- file.path(dir, "FVSOut.db")
  if (!file.exists(output) || is.na(file.info(output)$size) || file.info(output)$size == 0) {
    diagnostics <- c(if (file.exists(stdout)) readLines(stdout, warn = FALSE),
                     if (file.exists(stderr)) readLines(stderr, warn = FALSE))
    stop(name, " FVS smoke run did not create a nonempty FVSOut.db.\n",
         paste(utils::tail(diagnostics, 40L), collapse = "\n"), call. = FALSE)
  }
  fvs <- read_fvs_output(output)
  summary <- fvs$FVS_Summary2 %||% fvs$FVS_Summary
  if (is.null(summary) || !nrow(summary))
    stop(name, " FVS output has no stand summary.", call. = FALSE)
  find_col <- function(names, candidates) {
    hit <- candidates[tolower(candidates) %in% tolower(names)]
    if (length(hit)) names[match(tolower(hit[[1L]]), tolower(names))] else NA_character_
  }
  year_col <- find_col(names(summary), c("Year"))
  ba_col <- find_col(names(summary), c("BA"))
  tpa_col <- find_col(names(summary), c("Tpa", "TPA"))
  qmd_col <- find_col(names(summary), c("QMD"))
  if (is.na(year_col) || is.na(ba_col) || is.na(tpa_col) || is.na(qmd_col))
    stop(name, " stand summary is missing Year, BA, TPA, or QMD.", call. = FALSE)
  years <- safe_num(summary[[year_col]])
  if (!any(years == 2024) || !any(years == 2029))
    stop(name, " stand summary did not contain inventory year 2024 and projection year 2029.", call. = FALSE)
  for (col in c(ba_col, tpa_col, qmd_col)) {
    values <- safe_num(summary[[col]])
    if (!any(is.finite(values))) stop(name, " stand summary has no finite ", col, ".", call. = FALSE)
  }
  volume_col <- find_col(names(summary), c("TCuFt", "MCuFt", "SCuFt", "BdFt"))
  if (!is.na(volume_col) && !any(is.finite(safe_num(summary[[volume_col]]))))
    stop(name, " reported volume column ", volume_col, " without finite values.", call. = FALSE)
  list(dir = dir, summary = summary, fvs = fvs, years = years, ba_col = ba_col)
}

base <- run_one("base", scenario_base)
thin <- run_one("thin", scenario_thin)
base_2029 <- base$summary[base$years == 2029, , drop = FALSE]
thin_2029 <- thin$summary[thin$years == 2029, , drop = FALSE]
if (!nrow(base_2029) || !nrow(thin_2029)) stop("Treatment-year smoke rows were not produced.", call. = FALSE)
if (safe_num(thin_2029[[thin$ba_col]][[1L]]) > safe_num(base_2029[[base$ba_col]][[1L]]) + 1e-6)
  stop("Thin scenario increased basal area at the treatment year.", call. = FALSE)

cat("FVS smoke test passed\n")
cat("R home:", R.home(), "\n")
cat("Engine:", engine, "\n")
cat("Base tables:", paste(base$fvs$tables, collapse = ", "), "\n")
cat("Thin treatment-year BA:", safe_num(thin_2029[[thin$ba_col]][[1L]]), "\n")
