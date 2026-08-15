# ------------------------------------------------------------------------------
# Small shared helpers.
# ------------------------------------------------------------------------------

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0L) y else x

# NA-safe default
nz <- function(x, y) {
  if (is.null(x) || length(x) == 0L) return(y)
  if (length(x) == 1L && is.na(x)) return(y)
  x
}

is_blank <- function(x) is.null(x) || length(x) == 0L || all(is.na(x)) ||
  (is.character(x) && all(!nzchar(trimws(x))))

# Round for display without turning integers into "5.00"
fmt_num <- function(x, digits = 1) {
  ifelse(is.na(x), "—", formatC(x, format = "f", digits = digits, big.mark = ""))
}

fmt_int <- function(x) ifelse(is.na(x), "—", formatC(round(x), format = "d", big.mark = ""))

fmt_money <- function(x, digits = 2) {
  ifelse(is.na(x), "—", paste0("$", formatC(x, format = "f", digits = digits, big.mark = "")))
}

# Basal area of a single stem, ft2, from DBH in inches (the standard forestry
# constant pi/(4*144) = 0.005454154).
FT2_PER_IN2 <- 0.005454154

ba_of_dbh <- function(dbh_in) FT2_PER_IN2 * dbh_in^2

# Quadratic mean diameter from basal area per acre and trees per acre.
qmd_from <- function(ba_ac, tpa) {
  ifelse(is.na(tpa) | tpa <= 0, NA_real_, sqrt(ba_ac / tpa / FT2_PER_IN2))
}

# Reineke stand density index, summation form is not available from summary
# statistics alone; this is the classic QMD form and is labeled as such wherever
# it is displayed.
sdi_reineke <- function(tpa, qmd) {
  ifelse(is.na(qmd) | qmd <= 0, NA_real_, tpa * (qmd / 10)^1.605)
}

safe_num <- function(x) {
  if (is.numeric(x)) return(x)
  suppressWarnings(as.numeric(as.character(x)))
}

# Read a CSV shipped in config/ with all-character FIA-style codes preserved.
read_config_csv <- function(name, char_cols = character(0)) {
  path <- file.path(ufvs_config_dir(), name)
  if (!file.exists(path)) stop("missing config file: ", name)
  d <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE,
                       colClasses = if (length(char_cols)) {
                         stats::setNames(rep("character", length(char_cols)), char_cols)
                       } else NA)
  d
}

# Coalesce a data.frame column that may be absent.
col_or <- function(df, name, default = NA) {
  if (!is.null(df) && name %in% names(df)) df[[name]] else rep(default, if (is.null(df)) 0L else nrow(df))
}

# ------------------------------------------------------------------------------
# Provenance hashing
#
# Reproducibility depends on being able to say exactly what went into a run.
# The earlier implementation hashed the text of str(x, max.level = 3,
# list.len = 50), which truncates: two inventories differing only past the
# fiftieth record, or below the third nesting level, produced the same hash and
# looked identical in the run record. That is worse than no hash.
#
# These use SHA-256 over a canonical serialization instead.
# ------------------------------------------------------------------------------

UFVS_PROVENANCE_SCHEMA <- 2L   # bumped when the hashing method changes

#' SHA-256 of an arbitrary R object, over a canonical serialization.
#'
#' Data frames are canonicalized first (column order, row order, types) so that
#' the same content hashes the same regardless of how it was read in.
sha256_of <- function(x) {
  raw_bytes <- serialize(x, connection = NULL, version = 3, xdr = TRUE)
  digest::digest(raw_bytes, algo = "sha256", serialize = FALSE)
}

#' Canonical form of a data frame for hashing.
#'
#' Sorting rows and columns means a reordered but otherwise identical table
#' hashes identically, which is what "same inventory" should mean.
canonical_df <- function(d) {
  if (is.null(d) || !is.data.frame(d) || !nrow(d)) return(NULL)
  d <- d[, order(names(d)), drop = FALSE]
  ord <- do.call(order, c(lapply(d, function(col) as.character(col)),
                          list(method = "radix")))
  d <- d[ord, , drop = FALSE]
  rownames(d) <- NULL
  # Numeric columns are rounded to a fixed precision so that a value which only
  # differs in floating-point noise does not read as a different inventory.
  for (n in names(d)) if (is.numeric(d[[n]])) d[[n]] <- round(d[[n]], 9)
  lapply(d, function(col) if (is.factor(col)) as.character(col) else col)
}

#' Hash of a complete normalized inventory: stands, plots and trees.
#'
#' All three tables are included. Omitting plots would let a change in the plot
#' table pass unnoticed, which matters because the sampling design lives there.
inventory_hash <- function(data) {
  if (is.null(data)) return(NA_character_)
  parts <- list(schema = UFVS_PROVENANCE_SCHEMA,
                stands = canonical_df(data$stands),
                plots  = canonical_df(data$plots),
                trees  = canonical_df(data$trees))
  sha256_of(parts)
}

#' Hash of a file's bytes, or NA when it cannot be read.
#'
#' Returning NA is deliberate: claiming a hash for something unreadable would
#' make the run record assert more than it knows.
file_hash <- function(path) {
  if (is.null(path) || length(path) != 1L || is.na(path) || !nzchar(path)) return(NA_character_)
  if (!file.exists(path) || dir.exists(path)) return(NA_character_)
  out <- try(digest::digest(file = path, algo = "sha256"), silent = TRUE)
  if (inherits(out, "try-error")) NA_character_ else out
}

#' Hash of a character vector treated as file content.
text_hash <- function(txt) {
  if (is.null(txt)) return(NA_character_)
  sha256_of(paste(txt, collapse = "\n"))
}

#' Hash of the reference tables uFVS used to build a run.
#'
#' A change to the variant defaults or the keyword catalog changes what uFVS
#' generates, so it belongs in the provenance record alongside the inventory.
config_hash <- function() {
  files <- sort(list.files(ufvs_config_dir(), pattern = "\\.csv$", full.names = TRUE))
  if (!length(files)) return(NA_character_)
  h <- vapply(files, file_hash, character(1))
  if (all(is.na(h))) return(NA_character_)
  sha256_of(list(files = basename(files), hashes = unname(h)))
}

#' Short display form of a hash. Never used for comparison, only for labels.
short_hash <- function(x) {
  h <- if (is.character(x) && length(x) == 1L && grepl("^[0-9a-f]{64}$", x)) x else sha256_of(x)
  substr(h, 1, 12)
}

# Named list -> data.frame of one row, dropping NULLs
row_df <- function(...) {
  args <- list(...)
  args <- args[!vapply(args, is.null, logical(1))]
  as.data.frame(args, stringsAsFactors = FALSE)
}

# Provenance tags used across every calculated output in uFVS.
PROV <- c(
  FVS       = "FVS",
  UFVS      = "uFVS calculated",
  CONVERTED = "converted",
  USER      = "user supplied"
)

# Build a small provenance badge for UI use.
prov_badge <- function(tag) {
  cls <- switch(tag,
    "FVS" = "prov prov-fvs",
    "uFVS calculated" = "prov prov-ufvs",
    "converted" = "prov prov-conv",
    "user supplied" = "prov prov-user",
    "prov")
  shiny::tags$span(class = cls, tag)
}


#' A static asset URL carrying the file's modification time, so a changed file
#' is never served from a stale browser cache.
ufvs_asset <- function(file) {
  p <- file.path(ufvs_root(), "www", file)
  if (!file.exists(p)) return(file)
  paste0(file, "?v=", as.integer(as.numeric(file.info(p)$mtime)))
}


#' Coerce a setting to a single number, or NA.
#'
#' Settings arrive from JSON, from Shiny inputs and from defaults, so they can
#' be NULL, a length-zero vector, a one-element list, or the string "NA". Every
#' one of those breaks a bare if(!is.na(x)) test, which is how a restored
#' project used to crash the statistics pages.
as_scalar_num <- function(x) {
  if (is.null(x) || length(x) == 0L) return(NA_real_)
  if (is.list(x)) x <- unlist(x, use.names = FALSE)
  if (!length(x)) return(NA_real_)
  x <- x[[1]]
  if (is.character(x) && (!nzchar(trimws(x)) || toupper(trimws(x)) %in% c("NA", "NULL", "NAN")))
    return(NA_real_)
  out <- suppressWarnings(as.numeric(x))
  if (length(out) != 1L || !is.finite(out)) NA_real_ else out
}

#' Coerce a setting to a character vector, dropping JSON list nesting.
as_chr_vec <- function(x) {
  if (is.null(x) || length(x) == 0L) return(character(0))
  out <- unlist(x, use.names = FALSE)
  out <- as.character(out)
  out[!is.na(out) & nzchar(out)]
}
