#!/usr/bin/env Rscript
# Smoke-test a staged package with the staged R interpreter, in the same
# environment the launcher creates. A broken bundle should fail the build, not
# wait for a user to discover it on a clean computer.
#
# The caller exports UFVS_APP_DIR, UFVS_RUNTIME_DIR, UFVS_LIBRARY_DIR,
# UFVS_FVS_DIR and UFVS_RESOURCES_DIR exactly as uFVS.exe and uFVS.app do, so
# what is tested here is the real packaged configuration and not a
# reconstruction of it.

args <- commandArgs(trailingOnly = TRUE)
value_for <- function(flag, default = "") {
  i <- match(flag, args)
  if (!is.na(i) && i < length(args)) args[i + 1L] else default
}
env_or <- function(name, default) {
  v <- Sys.getenv(name, unset = "")
  if (nzchar(v)) v else default
}

app_dir <- value_for("--app", env_or("UFVS_APP_DIR", ""))
if (!nzchar(app_dir)) stop("Pass --app or export UFVS_APP_DIR.", call. = FALSE)
app_dir <- normalizePath(app_dir, mustWork = TRUE)
setwd(app_dir)

library_dir <- normalizePath(env_or("UFVS_LIBRARY_DIR", file.path(app_dir, "library")),
                             mustWork = FALSE)
runtime_dir <- normalizePath(env_or("UFVS_RUNTIME_DIR", file.path(app_dir, "runtime")),
                             mustWork = FALSE)
resources_dir <- normalizePath(env_or("UFVS_RESOURCES_DIR", app_dir), mustWork = FALSE)

options(ufvs.root = app_dir, ufvs.release = TRUE)
if (dir.exists(library_dir)) .libPaths(unique(c(library_dir, .libPaths())))

required <- c("shiny", "ggplot2", "jsonlite", "DBI", "RSQLite", "readxl", "callr", "digest")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) stop("Missing staged packages: ", paste(missing, collapse = ", "), call. = FALSE)
suppressPackageStartupMessages({
  library(shiny); library(ggplot2); library(jsonlite); library(DBI)
  library(RSQLite); library(readxl); library(callr); library(digest)
})

# The whole point of a packaged release: this must be the bundled interpreter,
# not whatever R the build machine happens to have installed.
r_home <- normalizePath(R.home(), mustWork = FALSE)
if (!startsWith(r_home, runtime_dir)) {
  stop("The staged interpreter did not use the bundled runtime.\n  R.home(): ",
       r_home, "\n  expected below: ", runtime_dir, call. = FALSE)
}

# Every loaded package must come from the private library for the same reason.
foreign <- character(0)
for (pkg in required) {
  where <- normalizePath(dirname(find.package(pkg)), mustWork = FALSE)
  if (!identical(where, library_dir)) foreign <- c(foreign, paste0(pkg, " (", where, ")"))
}
if (length(foreign)) {
  stop("These packages did not resolve to the bundled library: ",
       paste(foreign, collapse = ", "), call. = FALSE)
}

if (!file.exists(file.path(resources_dir, "BUILD_INFO.json"))) {
  stop("BUILD_INFO.json is missing from ", resources_dir, call. = FALSE)
}

sqlite_file <- tempfile("ufvs-release-", fileext = ".db")
con <- DBI::dbConnect(RSQLite::SQLite(), sqlite_file)
invisible(DBI::dbExecute(con, "CREATE TABLE self_test (value INTEGER)"))
invisible(DBI::dbExecute(con, "INSERT INTO self_test VALUES (1)"))
stopifnot(DBI::dbGetQuery(con, "SELECT value FROM self_test")$value[[1]] == 1L)
DBI::dbDisconnect(con)
unlink(sqlite_file, force = TRUE)

module_files <- sort(list.files(file.path(app_dir, "R"), pattern = "[.]R$", full.names = TRUE))
if (!length(module_files)) stop("No application modules below ", app_dir, call. = FALSE)
for (f in module_files) parse(f)
for (f in module_files) source(f)

if (!length(bundled_variants())) {
  stop("No FVS variant was found in ", ufvs_engine_dir(), call. = FALSE)
}
ui_test <- try(as.character(ufvs_ui()), silent = TRUE)
if (inherits(ui_test, "try-error"))
  stop("The application UI could not be constructed: ", conditionMessage(attr(ui_test, "condition")),
       call. = FALSE)

cat("Release self-test passed\n")
cat("R home:     ", r_home, "\n")
cat("Library:    ", library_dir, "\n")
cat("FVS engine: ", ufvs_engine_dir(), "\n")
cat("FVS variants:", paste(toupper(bundled_variants()), collapse = ", "), "\n")
