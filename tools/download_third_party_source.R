#!/usr/bin/env Rscript
# Download source archives named by a release's generated third-party inventory.
# This is intentionally conservative: an unavailable exact archive is an error,
# not a reason to substitute a newer package or silently omit the source.

args <- commandArgs(trailingOnly = TRUE)
value_for <- function(flag, default = "") {
  i <- match(flag, args)
  if (!is.na(i) && i < length(args)) args[i + 1L] else default
}

inventory_path <- value_for("--inventory")
out <- value_for("--out")
notices <- value_for("--notices")
if (!nzchar(inventory_path) || !file.exists(inventory_path))
  stop("--inventory must name a generated components.csv.", call. = FALSE)
if (!nzchar(out)) stop("--out is required.", call. = FALSE)

inventory <- utils::read.csv(inventory_path, stringsAsFactors = FALSE, check.names = FALSE,
                             na.strings = c("", "NA"))
required <- c("Component", "Type", "Version", "Source archive URL")
missing <- setdiff(required, names(inventory))
if (length(missing)) stop("Inventory lacks: ", paste(missing, collapse = ", "), call. = FALSE)

dir.create(out, showWarnings = FALSE, recursive = TRUE)
package_out <- file.path(out, "source-archives")
dir.create(package_out, showWarnings = FALSE, recursive = TRUE)

copy_tree <- function(source, destination) {
  if (!dir.exists(source)) return(invisible(FALSE))
  dir.create(destination, showWarnings = FALSE, recursive = TRUE)
  members <- list.files(source, all.files = TRUE, no.. = TRUE, full.names = TRUE)
  for (member in members) {
    target <- file.path(destination, basename(member))
    if (dir.exists(member)) copy_tree(member, target)
    else if (!file.copy(member, target, overwrite = TRUE))
      stop("Could not copy notice file ", member, ".", call. = FALSE)
  }
  invisible(TRUE)
}

if (nzchar(notices)) copy_tree(notices, file.path(out, "THIRD_PARTY"))

download_one <- function(urls, destination) {
  for (url in unique(urls[nzchar(urls)])) {
    temporary <- tempfile("ufvs-source-")
    ok <- tryCatch(utils::download.file(url, temporary, mode = "wb", quiet = TRUE,
                                        method = "libcurl") == 0L,
                   error = function(e) FALSE)
    if (ok && file.exists(temporary) && isTRUE(file.info(temporary)$size > 0)) {
      if (!file.copy(temporary, destination, overwrite = TRUE))
        stop("Could not save downloaded source archive to ", destination, ".", call. = FALSE)
      unlink(temporary, force = TRUE)
      return(url)
    }
    unlink(temporary, force = TRUE)
  }
  NA_character_
}

rows <- inventory[inventory$Type %in% c("R package", "R"), , drop = FALSE]
if (!nrow(rows)) stop("No R or R package rows were found in the inventory.", call. = FALSE)
manifest <- vector("list", nrow(rows))
for (i in seq_len(nrow(rows))) {
  component <- rows$Component[[i]]
  version <- rows$Version[[i]]
  url <- rows[["Source archive URL"]][[i]]
  if (is.na(url) || !nzchar(url))
    stop("No exact source archive URL is recorded for ", component, ".", call. = FALSE)
  safe_name <- gsub("[^A-Za-z0-9._-]+", "_", paste0(component, "_", version, ".tar.gz"))
  destination <- file.path(package_out, safe_name)
  fallback <- if (identical(rows$Type[[i]], "R package"))
    sprintf("https://cran.r-project.org/src/contrib/Archive/%s/%s_%s.tar.gz",
            component, component, version) else character(0)
  actual <- download_one(c(url, fallback), destination)
  if (is.na(actual))
    stop("Exact source archive unavailable for ", component, " ", version,
         ". Tried: ", paste(c(url, fallback), collapse = ", "), call. = FALSE)
  manifest[[i]] <- data.frame(Component = component, Version = version,
                               URL = actual, File = file.path("source-archives", safe_name),
                               Bytes = unname(file.info(destination)$size),
                               MD5 = unname(tools::md5sum(destination)),
                               stringsAsFactors = FALSE)
}
manifest <- do.call(rbind, manifest)
utils::write.csv(manifest, file.path(out, "SOURCE_MANIFEST.csv"), row.names = FALSE)
writeLines(c(
  "This bundle contains source archives selected from the exact release inventory.",
  "It is provided for release review and source-availability analysis; each component's own terms control.",
  paste0("Inventory: ", normalizePath(inventory_path, mustWork = FALSE))
), file.path(out, "README.txt"))
cat(sprintf("Downloaded %d source archives to %s\n", nrow(manifest), normalizePath(out, mustWork = FALSE)))
