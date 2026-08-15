#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# Extract reference tables from an official FVS source tree.
#
# uFVS does not re-implement FVS science. It does need to know a few structural
# facts about FVS in order to read inventory data the same way FVS does and to
# validate user input before a run:
#
#   * per-variant DESIGN defaults (BAF, FPA, BRK, TFPA) from <variant>/grinit.f
#   * per-variant species lists (alpha code, FIA code, PLANTS symbol) from
#     <variant>/blkdat.f
#
# Everything written by this script is a mechanical transcription of the
# official source. It carries no uFVS-authored modeling content.
#
# Usage:
#   Rscript tools/extract_fvs_config.R /path/to/ForestVegetationSimulator-main
# ------------------------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("usage: extract_fvs_config.R <FVS source root> [outdir]")
src <- normalizePath(args[1], mustWork = TRUE)
outdir <- if (length(args) >= 2) args[2] else file.path(getwd(), "config")
dir.create(outdir, showWarnings = FALSE, recursive = TRUE)

# --- locate variant directories: any dir holding grinit.f --------------------
grinits <- list.files(src, pattern = "^grinit\\.f$", recursive = TRUE, full.names = TRUE)
# exclude archived / metric / working copies
grinits <- grinits[!grepl("/archive/|/working/|/metric/", grinits)]

num <- function(x) {
  x <- sub("^\\s*", "", sub("\\s*$", "", x))
  suppressWarnings(as.numeric(sub("\\.$", "", x)))
}

grab <- function(lines, var) {
  hit <- grep(paste0("^\\s{6,}", var, "\\s*=\\s*[-0-9.]"), lines, value = TRUE)
  if (!length(hit)) return(NA_real_)
  num(sub(".*=\\s*", "", hit[1]))
}

design <- do.call(rbind, lapply(grinits, function(f) {
  lines <- readLines(f, warn = FALSE)
  data.frame(
    variant = basename(dirname(f)),
    baf     = grab(lines, "BAF"),
    fpa     = grab(lines, "FPA"),
    brk     = grab(lines, "BRK"),
    tfpa    = grab(lines, "TFPA"),
    source  = sub(paste0("^", src, "/"), "", f),
    stringsAsFactors = FALSE
  )
}))
design <- design[!is.na(design$baf), ]
design <- design[order(design$variant), ]
write.csv(design, file.path(outdir, "variant_design_defaults.csv"), row.names = FALSE)
cat("wrote variant_design_defaults.csv:", nrow(design), "variants\n")

# --- species tables ----------------------------------------------------------
# blkdat.f holds parallel DATA arrays: JSP (alpha), FIAJSP (FIA), PLNJSP (PLANTS).
# Common names appear in a comment block of the form "   13 = LOBLOLLY PINE (LP)".
read_data_array <- function(lines, name) {
  start <- grep(paste0("^\\s+DATA\\s+", name, "\\s*/"), lines)
  if (!length(start)) return(character(0))
  start <- start[1]
  out <- character(0)
  i <- start
  repeat {
    ln <- lines[i]
    body <- sub(paste0("^\\s+DATA\\s+", name, "\\s*/"), "", ln)
    body <- sub("^\\s{5}[&*+.$]", "", body)
    done <- grepl("/", body)
    body <- sub("/.*$", "", body)
    out <- c(out, regmatches(body, gregexpr("'[^']*'", body))[[1]])
    if (done || i >= length(lines)) break
    i <- i + 1
    if (i - start > 200) break
  }
  trimws(gsub("'", "", out))
}

common_names <- function(lines) {
  # "C    13 = LOBLOLLY PINE (LP)           PINUS TAEDA"
  hits <- grep("^C\\s+[0-9]{1,3}\\s*=\\s*.*\\([A-Z0-9]{2,3}\\s*\\)", lines, value = TRUE)
  if (!length(hits)) return(NULL)
  code <- toupper(trimws(sub(".*\\(([A-Z0-9 ]{2,3})\\).*", "\\1", hits)))
  nm   <- trimws(sub("\\s*\\(.*$", "", sub("^C\\s+[0-9]{1,3}\\s*=\\s*", "", hits)))
  d <- data.frame(code = code, common_name = nm, stringsAsFactors = FALSE)
  d[!duplicated(d$code), ]
}

sp_all <- list()
for (f in grinits) {
  v <- basename(dirname(f))
  bd <- file.path(dirname(f), "blkdat.f")
  if (!file.exists(bd)) next
  lines <- readLines(bd, warn = FALSE)
  jsp <- read_data_array(lines, "JSP")
  if (!length(jsp)) next
  fia <- read_data_array(lines, "FIAJSP")
  pln <- read_data_array(lines, "PLNJSP")
  n <- length(jsp)
  d <- data.frame(
    variant       = v,
    index         = seq_len(n),
    species_code  = trimws(jsp),
    fia_code      = if (length(fia) == n) trimws(fia) else NA_character_,
    plants_symbol = if (length(pln) == n) trimws(pln) else NA_character_,
    stringsAsFactors = FALSE
  )
  cn <- common_names(lines)
  d$common_name <- if (!is.null(cn)) cn$common_name[match(d$species_code, cn$code)] else NA_character_
  sp_all[[v]] <- d
}
species <- do.call(rbind, sp_all)
write.csv(species, file.path(outdir, "variant_species.csv"), row.names = FALSE)
cat("wrote variant_species.csv:", nrow(species), "rows across",
    length(unique(species$variant)), "variants\n")

# --- provenance stamp --------------------------------------------------------
writeLines(c(
  "# Generated reference tables",
  "",
  "These CSVs are mechanically transcribed from the official FVS source tree by",
  "`tools/extract_fvs_config.R`. They contain no uFVS-authored modeling content.",
  "",
  paste0("Source tree: ", src),
  paste0("Generated:   ", format(Sys.Date())),
  paste0("Variants:    ", nrow(design)),
  paste0("Species rows:", nrow(species)),
  "",
  "Regenerate with:",
  "",
  "    Rscript tools/extract_fvs_config.R /path/to/ForestVegetationSimulator-main",
  ""
), file.path(outdir, "GENERATED.md"))
cat("done\n")
