#!/usr/bin/env Rscript
# Cross-platform launcher used by the macOS and Windows start files.

args <- commandArgs(trailingOnly = TRUE)
script_args <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", script_args, value = TRUE)
script_path <- if (length(file_arg)) sub("^--file=", "", file_arg[1]) else "tools/launch.R"
root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
setwd(root)

required <- c("shiny", "ggplot2", "jsonlite", "DBI", "RSQLite", "readxl", "callr")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]

if ("--check" %in% args) {
  if (length(missing)) cat(paste(missing, collapse = " "))
  quit(status = 0L)
}

if (length(missing)) {
  stop(paste("Missing R packages:", paste(missing, collapse = ", "),
             ". Run the launcher again and allow installation, or install them with install.packages()."),
       call. = FALSE)
}

options(ufvs.root = normalizePath(root, mustWork = TRUE))
shiny::runApp(root, launch.browser = TRUE, host = "127.0.0.1")
