#!/usr/bin/env Rscript
# Start the staged Shiny application with its staged R process and request the
# local page. This is the headless equivalent of opening the launcher in a
# browser; it proves the bundled app can bind locally without system R or RStudio.

args <- commandArgs(trailingOnly = TRUE)
value_for <- function(flag, default = "") {
  i <- match(flag, args)
  if (!is.na(i) && i < length(args)) args[i + 1L] else default
}
root <- value_for("--root")
port <- as.integer(value_for("--port", "18765"))
if (!nzchar(root) || !dir.exists(root)) stop("--root must name the staged release.", call. = FALSE)
if (is.na(port) || port < 1024L || port > 65535L) stop("Invalid --port.", call. = FALSE)
root <- normalizePath(root, mustWork = TRUE)

library_dir <- file.path(root, "library")
if (dir.exists(library_dir)) .libPaths(unique(c(library_dir, .libPaths())))
suppressPackageStartupMessages(library(callr))
data_dir <- file.path(tempdir(), "ufvs-http-smoke-data")
dir.create(data_dir, showWarnings = FALSE, recursive = TRUE)

server <- callr::r_bg(
  func = function(app_root, app_port, app_data) {
    options(ufvs.root = app_root, ufvs.release = TRUE, ufvs.user_dir = app_data)
    Sys.setenv(UFVS_RELEASE = "1", R_LIBS_USER = file.path(app_root, "library"))
    setwd(app_root)
    shiny::runApp(app_root, port = app_port, host = "127.0.0.1", launch.browser = FALSE)
  },
  args = list(app_root = root, app_port = port, app_data = data_dir),
  supervise = TRUE,
  stdout = tempfile("ufvs-http-stdout-"),
  stderr = tempfile("ufvs-http-stderr-"))
on.exit(try(server$kill(), silent = TRUE), add = TRUE)

url <- sprintf("http://127.0.0.1:%d/", port)
page <- NULL
for (i in seq_len(60L)) {
  page <- tryCatch(readLines(url, warn = FALSE), error = function(e) NULL)
  if (length(page)) break
  Sys.sleep(0.5)
}
if (!length(page)) {
  details <- tryCatch(server$read_error_lines(), error = function(e) character(0))
  stop("The staged Shiny app did not answer at ", url, ".\n",
       paste(utils::tail(details, 40L), collapse = "\n"), call. = FALSE)
}
if (!any(grepl("uFVS|shiny", page, ignore.case = TRUE)))
  stop("The local response did not look like the uFVS Shiny page.", call. = FALSE)
cat("Staged local app HTTP smoke test passed at", url, "\n")
