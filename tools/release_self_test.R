#!/usr/bin/env Rscript
# Smoke-test a staged release with the staged R interpreter. This is deliberately
# separate from the application UI: a broken bundle should fail the build, not
# wait for a user to discover it on a clean computer.

args <- commandArgs(trailingOnly = TRUE)
value_for <- function(flag, default = "") {
  i <- match(flag, args)
  if (!is.na(i) && i < length(args)) args[i + 1L] else default
}
root <- normalizePath(value_for("--root"), mustWork = TRUE)
setwd(root)
options(ufvs.root = root, ufvs.release = TRUE)
library_dir <- file.path(root, "library")
if (dir.exists(library_dir)) .libPaths(unique(c(library_dir, .libPaths())))

required <- c("shiny", "ggplot2", "jsonlite", "DBI", "RSQLite", "readxl", "callr", "digest")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) stop("Missing staged packages: ", paste(missing, collapse = ", "), call. = FALSE)
suppressPackageStartupMessages({
  library(shiny); library(ggplot2); library(jsonlite); library(DBI)
  library(RSQLite); library(readxl); library(callr); library(digest)
})

runtime_root <- normalizePath(file.path(root, "runtime"), mustWork = FALSE)
runtime_ok <- grepl(normalizePath(runtime_root, mustWork = FALSE), normalizePath(R.home(), mustWork = FALSE),
                    fixed = TRUE)
if (!runtime_ok) stop("The staged interpreter did not use the bundled runtime: ", R.home(), call. = FALSE)

sqlite_file <- tempfile("ufvs-release-", fileext = ".db")
con <- DBI::dbConnect(RSQLite::SQLite(), sqlite_file)
invisible(DBI::dbExecute(con, "CREATE TABLE self_test (value INTEGER)"))
invisible(DBI::dbExecute(con, "INSERT INTO self_test VALUES (1)"))
stopifnot(DBI::dbGetQuery(con, "SELECT value FROM self_test")$value[[1]] == 1L)
DBI::dbDisconnect(con)
unlink(sqlite_file, force = TRUE)

for (f in sort(list.files(file.path(root, "R"), pattern = "[.]R$", full.names = TRUE))) parse(f)
for (f in sort(list.files(file.path(root, "R"), pattern = "[.]R$", full.names = TRUE))) source(f)
stopifnot(length(bundled_variants()) > 0L)
ui_test <- try(as.character(ufvs_ui()), silent = TRUE)
if (inherits(ui_test, "try-error"))
  stop("The application UI could not be constructed: ", conditionMessage(attr(ui_test, "condition")),
       call. = FALSE)

cat("Release self-test passed\n")
cat("R home:", R.home(), "\n")
cat("FVS variants:", paste(toupper(bundled_variants()), collapse = ", "), "\n")
