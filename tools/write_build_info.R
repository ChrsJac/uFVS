#!/usr/bin/env Rscript
# Write portable build metadata. Paths in this file are always relative to the
# release root so moving the extracted folder does not invalidate the record.

args <- commandArgs(trailingOnly = TRUE)
value_for <- function(flag, default = "") {
  i <- match(flag, args)
  if (!is.na(i) && i < length(args)) args[i + 1L] else default
}

root <- value_for("--root")
platform <- value_for("--platform", "unknown")
architecture <- value_for("--architecture", Sys.info()[["machine"]])
engine_dir <- value_for("--engine-dir", file.path(root, "engine"))
if (!nzchar(root) || !dir.exists(root)) stop("--root must name a release directory.", call. = FALSE)

fvs_revision <- value_for("--fvs-source-revision",
                          Sys.getenv("UFVS_FVS_SOURCE_REVISION", unset = "unknown"))
fvs_repository <- value_for("--fvs-source-url",
                            Sys.getenv("UFVS_FVS_SOURCE_URL", unset =
                              "https://github.com/USDAForestService/ForestVegetationSimulator"))
fvs_license_url <- Sys.getenv(
  "UFVS_FVS_LICENSE_URL", unset =
    "https://github.com/USDAForestService/ForestVegetationSimulator/blob/main/license.txt")
fvs_toolchain <- value_for("--fvs-toolchain",
                           Sys.getenv("UFVS_FVS_TOOLCHAIN", unset = "not recorded"))

version_line <- grep("^UFVS_VERSION[[:space:]]*<-", readLines(file.path(root, "R", "01_config.R")),
                     value = TRUE)
version <- if (length(version_line)) sub(".*[\"']([^\"']+)[\"'].*", "\\1", version_line[1]) else "unknown"

hash_file <- function(path) {
  if (!file.exists(path) || dir.exists(path)) return(NA_character_)
  digest::digest(file = path, algo = "sha256")
}

engine_files <- list.files(engine_dir, recursive = TRUE, full.names = TRUE, all.files = TRUE)
engine_files <- engine_files[file.info(engine_files)$isdir %in% FALSE]
engine_records <- lapply(engine_files, function(path) {
  rel <- normalizePath(path, mustWork = FALSE)
  prefix <- paste0(normalizePath(engine_dir, mustWork = FALSE), .Platform$file.sep)
  rel <- if (startsWith(rel, prefix)) substring(rel, nchar(prefix) + 1L) else basename(path)
  list(path = gsub("\\\\", "/", rel),
       bytes = unname(file.info(path)$size), sha256 = hash_file(path))
})
names(engine_records) <- NULL

library_dir <- file.path(root, "library")
pkg_dirs <- if (dir.exists(library_dir)) list.dirs(library_dir, recursive = FALSE, full.names = TRUE) else character(0)
pkg_versions <- list()
for (p in pkg_dirs) {
  dcf <- file.path(p, "DESCRIPTION")
  if (file.exists(dcf)) {
    d <- try(read.dcf(dcf, fields = "Version"), silent = TRUE)
    if (!inherits(d, "try-error") && nrow(d)) pkg_versions[[basename(p)]] <- unname(d[1, "Version"])
  }
}

epoch <- Sys.getenv("SOURCE_DATE_EPOCH", unset = "")
timestamp <- if (grepl("^[0-9]+$", epoch)) {
  format(as.POSIXct(as.numeric(epoch), origin = "1970-01-01", tz = "UTC"),
         "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
} else format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

build_id <- Sys.getenv("UFVS_BUILD_ID", unset = "")
if (!nzchar(build_id)) {
  build_id <- paste0(version, "-", tolower(gsub("[^A-Za-z0-9]+", "-", platform)),
                     "-", tolower(architecture), "-",
                     substr(digest::digest(list(engine_records, pkg_versions,
                                                fvs_revision, fvs_toolchain), algo = "sha256"), 1, 12))
}

r_version_full <- regmatches(R.version$version.string,
                             regexpr("[0-9]+[.]([0-9]+[.][0-9]+)",
                                     R.version$version.string))
if (!length(r_version_full) || !nzchar(r_version_full))
  r_version_full <- paste(R.version$major, R.version$minor, sep = ".")
r_source_url <- if (grepl("^[0-9]+[.][0-9]+[.][0-9]+$", r_version_full)) {
  r_branch <- sub("[.].*", "", r_version_full)
  sprintf("https://cran.r-project.org/src/base/R-%s/R-%s.tar.gz", r_branch, r_version_full)
} else "unknown"

info <- list(
  schema = 1L,
  build_id = build_id,
  uFVS_version = version,
  platform = platform,
  architecture = architecture,
  built_at_utc = timestamp,
  r_version = r_version_full,
  r_platform = R.version$platform,
  package_versions = pkg_versions,
  engine_files = engine_records,
  fvs_source = list(
    repository = fvs_repository,
    revision = fvs_revision,
    license_url = fvs_license_url,
    toolchain = fvs_toolchain
  ),
  r_source = list(
    version = r_version_full,
    source_url = r_source_url,
    license = "GPL-2 | GPL-3",
    license_url = "https://www.r-project.org/Licenses/"
  )
)
jsonlite::write_json(info, file.path(root, "BUILD_INFO.json"), auto_unbox = TRUE,
                     pretty = TRUE, null = "null")
cat("Wrote", file.path(root, "BUILD_INFO.json"), "\n")
