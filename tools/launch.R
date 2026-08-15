#!/usr/bin/env Rscript
# Cross-platform launcher used by the macOS and Windows start files.

args <- commandArgs(trailingOnly = TRUE)
script_args <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", script_args, value = TRUE)
script_path <- if (length(file_arg)) sub("^--file=", "", file_arg[1]) else "tools/launch.R"
root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
setwd(root)
options(ufvs.root = root)

bundled_library <- file.path(root, "library")
release <- tolower(Sys.getenv("UFVS_RELEASE", unset = "")) %in%
  c("1", "true", "yes", "y") ||
  (file.exists(file.path(root, "BUILD_INFO.json")) &&
   dir.exists(file.path(root, "runtime")))
if (dir.exists(bundled_library)) {
  .libPaths(unique(c(bundled_library, .libPaths())))
  if (release) Sys.setenv(R_LIBS_USER = bundled_library)
}

required <- c("shiny", "ggplot2", "jsonlite", "DBI", "RSQLite", "readxl", "callr", "digest")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]

if ("--check" %in% args) {
  if (length(missing)) cat(paste(missing, collapse = " "))
  quit(status = 0L)
}

if (length(missing)) {
  if (release) {
    stop(paste("This uFVS release is incomplete; its bundled package library is missing:",
               paste(missing, collapse = ", "), "."), call. = FALSE)
  }
  stop(paste("Missing R packages:", paste(missing, collapse = ", "),
             ". Install them with install.packages()."), call. = FALSE)
}

chosen_port <- suppressWarnings(as.integer(Sys.getenv("UFVS_PORT", unset = "0")))
if (is.na(chosen_port) || chosen_port <= 0L) chosen_port <- shiny::randomPort()
shiny::runApp(root, port = chosen_port, launch.browser = TRUE, host = "127.0.0.1")
