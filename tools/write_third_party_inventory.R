#!/usr/bin/env Rscript
# Generate the third-party inventory for one exact staged release library.
# The input is the library copied into the release, not the builder's full
# library, so the result records the dependency closure actually redistributed.

args <- commandArgs(trailingOnly = TRUE)
value_for <- function(flag, default = "") {
  i <- match(flag, args)
  if (!is.na(i) && i < length(args)) args[i + 1L] else default
}

library_dir <- value_for("--library")
target <- value_for("--target")
if (!nzchar(library_dir) || !dir.exists(library_dir))
  stop("--library must name the staged R package library.", call. = FALSE)
if (!nzchar(target)) stop("--target is required.", call. = FALSE)
dir.create(target, showWarnings = FALSE, recursive = TRUE)

clean_field <- function(x) {
  if (length(x) == 0L || is.na(x[[1L]])) return("")
  gsub("[[:space:]]+", " ", trimws(as.character(x[[1L]])))
}

read_field <- function(d, name) {
  if (is.null(d) || !name %in% colnames(d)) return("")
  clean_field(d[1L, name])
}

version_from_r <- function() {
  hit <- regmatches(R.version$version.string,
                    regexpr("[0-9]+[.]([0-9]+[.][0-9]+)", R.version$version.string))
  if (length(hit) && nzchar(hit)) hit else paste(R.version$major, R.version$minor, sep = ".")
}

r_version <- value_for("--r-version", version_from_r())
r_source_url <- value_for(
  "--r-source-url",
  if (grepl("^[0-9]+[.][0-9]+[.][0-9]+$", r_version))
    sprintf("https://cran.r-project.org/src/base/R-%s/R-%s.tar.gz",
            sub("[.].*", "", r_version), r_version)
  else "")

package_dirs <- list.dirs(library_dir, recursive = FALSE, full.names = TRUE)
package_dirs <- package_dirs[file.exists(file.path(package_dirs, "DESCRIPTION"))]
package_dirs <- package_dirs[order(tolower(basename(package_dirs)))]

package_target <- file.path(target, "packages")
if (dir.exists(package_target)) unlink(package_target, recursive = TRUE, force = TRUE)
dir.create(package_target, showWarnings = FALSE, recursive = TRUE)

package_rows <- vector("list", length(package_dirs))
for (i in seq_along(package_dirs)) {
  package_dir <- package_dirs[[i]]
  package <- basename(package_dir)
  desc <- tryCatch(read.dcf(file.path(package_dir, "DESCRIPTION")),
                   error = function(e) stop("Could not read ", package, ": ", conditionMessage(e),
                                            call. = FALSE))
  version <- read_field(desc, "Version")
  license <- read_field(desc, "License")
  url <- read_field(desc, "URL")
  copyright <- read_field(desc, "Copyright")
  authors <- read_field(desc, "Authors@R")
  if (!nzchar(authors)) authors <- read_field(desc, "Author")
  if (!nzchar(authors)) authors <- read_field(desc, "Maintainer")
  copyright_authors <- paste(copyright, authors, sep = if (nzchar(copyright) && nzchar(authors)) "; " else "")
  source_url <- if (nzchar(version))
    sprintf("https://cran.r-project.org/src/contrib/%s_%s.tar.gz", package, version) else ""

  destination <- file.path(package_target, package)
  dir.create(destination, showWarnings = FALSE, recursive = TRUE)
  top_level <- list.files(package_dir, all.files = FALSE, full.names = FALSE)
  top_level <- top_level[!file.info(file.path(package_dir, top_level))$isdir]
  notice_files <- top_level[grepl("^(LICENSE|COPYING|COPYRIGHTS?|NOTICE)([.]|$)",
                                  top_level, ignore.case = TRUE)]
  if (length(notice_files)) {
    ok <- file.copy(file.path(package_dir, notice_files), destination, overwrite = TRUE)
    if (!all(ok)) stop("Could not copy package notice files for ", package, ".", call. = FALSE)
  }

  metadata <- c(
    paste0("Package: ", package),
    paste0("Version: ", version),
    paste0("License: ", if (nzchar(license)) license else "(not declared in DESCRIPTION)"),
    paste0("Upstream URL: ", if (nzchar(url)) url else "(not supplied in DESCRIPTION)"),
    paste0("Copyright: ", if (nzchar(copyright)) copyright else "(not supplied in DESCRIPTION)"),
    paste0("Authors: ", if (nzchar(authors)) authors else "(not supplied in DESCRIPTION)"),
    paste0("Source archive URL: ", if (nzchar(source_url)) source_url else "(not available)"),
    paste0("Bundled license/notice files: ",
           if (length(notice_files)) paste(notice_files, collapse = ", ") else "none found at package top level")
  )
  writeLines(metadata, file.path(destination, "metadata.txt"))

  package_rows[[i]] <- data.frame(
    Component = package,
    Type = "R package",
    Version = version,
    License = license,
    `Upstream URL` = url,
    `Copyright/Authors` = copyright_authors,
    `License files` = paste(notice_files, collapse = "; "),
    `Source archive URL` = source_url,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

fixed_rows <- data.frame(
  Component = c("uFVS-authored source", "USDA Forest Vegetation Simulator",
                "FVS Interface rFVS/fvsOL", "R runtime"),
  Type = c("Original", "FVS", "FVS Interface", "R"),
  Version = c("0.1.0", "a17ee9728fe3273e9526d66e66fb4a79bdba6c10",
              "7b608f8265770e70065c5d03fe4cd061699fe479", r_version),
  License = c("MIT", "See THIRD_PARTY/FVS/license.txt", "MIT", "GPL-2 | GPL-3"),
  `Upstream URL` = c("https://github.com/ChrsJac/uFVS",
                     "https://github.com/USDAForestService/ForestVegetationSimulator",
                     "https://github.com/USDAForestService/ForestVegetationSimulator-Interface",
                     "https://www.r-project.org/"),
  `Copyright/Authors` = c("J. Christopher Jacobson", "United States Federal Government materials",
                          "USDA Forest Service", "R Core Team"),
  `License files` = c("LICENSE", "FVS/license.txt", "FVS-Interface/source-reference.txt",
                      "runtime/R/COPYING and runtime license files"),
  `Source archive URL` = c("", "", "", r_source_url),
  stringsAsFactors = FALSE,
  check.names = FALSE
)
rows <- c(list(fixed_rows), package_rows)
inventory <- do.call(rbind, rows)
utils::write.csv(inventory, file.path(target, "components.csv"), row.names = FALSE, na = "")

r_target <- file.path(target, "R")
dir.create(r_target, showWarnings = FALSE, recursive = TRUE)
writeLines(c(
  paste0("R version: ", r_version),
  paste0("R source archive URL: ", if (nzchar(r_source_url)) r_source_url else "(not available)"),
  "R license: GPL-2 | GPL-3",
  "R licensing source: https://www.r-project.org/Licenses/",
  "The complete R distribution is retained under the release runtime/R tree."
), file.path(r_target, "metadata.txt"))

cat(sprintf("Wrote %d package records to %s\n", length(package_dirs),
            file.path(target, "components.csv")))
