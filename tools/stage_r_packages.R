#!/usr/bin/env Rscript
# Stage the exact strong dependency closure of uFVS into a private library.
# Run this with the R installation whose packages are being released; do not
# use a package library compiled for a different operating system or CPU.

args <- commandArgs(trailingOnly = TRUE)
value_for <- function(flag, default = "") {
  i <- match(flag, args)
  if (!is.na(i) && i < length(args)) args[i + 1L] else default
}

target <- value_for("--target")
if (!nzchar(target)) stop("usage: stage_r_packages.R --target <directory>", call. = FALSE)
dir.create(target, showWarnings = FALSE, recursive = TRUE)

required <- c("shiny", "ggplot2", "jsonlite", "DBI", "RSQLite", "readxl", "callr", "digest")
ip <- installed.packages()
missing <- required[!required %in% rownames(ip)]
if (length(missing)) {
  stop("The builder R is missing: ", paste(missing, collapse = ", "), call. = FALSE)
}

# `strong` follows Depends, Imports, and LinkingTo. Suggested packages are not
# loaded by uFVS and would make a release needlessly large and less auditable.
deps <- tools::package_dependencies(required, db = ip, which = "strong", recursive = TRUE)
packages <- sort(unique(c(required, unlist(deps, use.names = FALSE))))
base <- unique(c(rownames(installed.packages(priority = "base")),
                 rownames(installed.packages(priority = "recommended"))))
packages <- setdiff(packages, base)

copied <- character(0)
for (pkg in packages) {
  source <- find.package(pkg, quiet = TRUE)
  if (!length(source) || !dir.exists(source))
    stop("Cannot locate installed package ", pkg, ".", call. = FALSE)
  destination <- file.path(target, pkg)
  if (dir.exists(destination)) unlink(destination, recursive = TRUE, force = TRUE)
  dir.create(destination, showWarnings = FALSE, recursive = TRUE)
  members <- list.files(source, all.files = TRUE, no.. = TRUE, full.names = TRUE)
  ok <- if (length(members)) file.copy(members, destination, recursive = TRUE) else FALSE
  if (length(members) && !all(ok)) stop("Could not copy package ", pkg, ".", call. = FALSE)
  copied <- c(copied, pkg)
}

cat(sprintf("Staged %d packages in %s\n", length(copied), normalizePath(target, mustWork = FALSE)))
cat(paste(copied, collapse = "\n"), "\n", sep = "")
