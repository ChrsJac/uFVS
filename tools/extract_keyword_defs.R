#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# Extract the FVS keyword catalog from the official fvsOL interface package.
#
# fvsOL (USDA Forest Service, MIT licensed) stores the definition of every FVS
# keyword it supports in parms/*.kwd: the description, each field's widget type,
# label and default, and the template that renders the keyword record. That is
# precisely the information uFVS needs to present the full keyword set with the
# real field meanings instead of a hand-written subset.
#
# uFVS transcribes those definitions into two CSVs. The FVS keywords, their
# semantics, and these descriptions are USDA Forest Service work; see NOTICE.md.
#
# Usage:
#   Rscript tools/extract_keyword_defs.R /path/to/ForestVegetationSimulator-Interface-main
# ------------------------------------------------------------------------------

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0L) y else x
nz_chr <- function(x) if (is.null(x) || length(x) == 0L || is.na(x[1])) "" else as.character(x[1])

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("usage: extract_keyword_defs.R <interface repo root> [outdir]")
root <- normalizePath(args[1], mustWork = TRUE)
outdir <- if (length(args) >= 2) args[2] else file.path(getwd(), "config")
dir.create(outdir, showWarnings = FALSE, recursive = TRUE)

parms <- file.path(root, "fvsOL", "parms")
if (!dir.exists(parms)) stop("no fvsOL/parms directory under ", root)
files <- list.files(parms, pattern = "\\.kwd$", full.names = TRUE)

# Pull the text between { and its matching }, starting at a given line.
read_braced <- function(lines, i) {
  txt <- lines[i]
  open <- 0L
  chars <- strsplit(txt, "")[[1]]
  start <- which(chars == "{")[1]
  if (is.na(start)) return(list(text = "", next_i = i + 1L))
  buf <- character(0)
  cur <- substring(txt, start)
  repeat {
    ch <- strsplit(cur, "")[[1]]
    for (k in seq_along(ch)) {
      if (ch[k] == "{") open <- open + 1L
      else if (ch[k] == "}") {
        open <- open - 1L
        if (open == 0L) {
          buf <- c(buf, substring(cur, 1, k - 1))
          return(list(text = sub("^\\{", "", paste(buf, collapse = "\n")), next_i = i + 1L))
        }
      }
    }
    buf <- c(buf, cur)
    i <- i + 1L
    if (i > length(lines)) return(list(text = sub("^\\{", "", paste(buf, collapse = "\n")), next_i = i))
    cur <- lines[i]
  }
}

defs <- list(); fields <- list()

for (f in files) {
  lines <- readLines(f, warn = FALSE)
  starts <- grep("^//start ", lines)
  for (si in seq_along(starts)) {
    i0 <- starts[si]
    i1 <- if (si < length(starts)) starts[si + 1] - 1L else length(lines)
    blk <- lines[i0:i1]
    hdr <- sub("^//start\\s+", "", blk[1])
    parts <- strsplit(hdr, ".", fixed = TRUE)[[1]]
    if (length(parts) < 3) next
    ext <- parts[2]; kw <- paste(parts[-c(1, 2)], collapse = ".")

    desc <- ""; parms_form <- ""; answer_form <- ""
    fmap <- list()

    j <- 1L
    while (j <= length(blk)) {
      ln <- blk[j]
      if (grepl("^description:", ln)) {
        # body starts on this line or the next
        k <- if (grepl("\\{", ln)) j else j + 1L
        r <- read_braced(blk, k); desc <- r$text; j <- r$next_i; next
      }
      if (grepl("^parmsForm:", ln)) {
        k <- if (grepl("\\{", ln)) j else j + 1L
        r <- read_braced(blk, k); parms_form <- r$text; j <- r$next_i; next
      }
      if (grepl("^answerForm:", ln)) {
        k <- if (grepl("\\{", ln)) j else j + 1L
        r <- read_braced(blk, k); answer_form <- r$text; j <- r$next_i; next
      }
      # field label:  f3:{numberBox Some label}
      # Some fields are variant-qualified: f3{ls ne}:{numberBox Some label}
      m <- regmatches(ln, regexec("^f([0-9]+)(\\{[^}]*\\})?:\\s*\\{([a-zA-Z]+)\\s*(.*)$", ln))[[1]]
      if (length(m) == 5) {
        r <- read_braced(blk, j)
        body <- r$text
        widget <- sub("^\\s*([a-zA-Z]+).*$", "\\1", body)
        label <- trimws(sub("^\\s*[a-zA-Z]+\\s*", "", body))
        idx <- as.integer(m[2])
        key <- as.character(idx)
        fmap[[key]] <- utils::modifyList(fmap[[key]] %||% list(),
                                         list(field = idx, widget = widget, label = label))
        j <- r$next_i; next
      }
      # field default: f3v:{...}  or variant-qualified f3v{ls ne}:{...}
      m <- regmatches(ln, regexec("^f([0-9]+)v(\\{[^}]*\\})?:", ln))[[1]]
      if (length(m) >= 2) {
        r <- read_braced(blk, j)
        idx <- as.integer(m[2])
        key <- as.character(idx)
        variants <- if (length(m) >= 3 && nzchar(m[3])) gsub("[{}]", "", m[3]) else ""
        prev <- fmap[[key]] %||% list(field = idx)
        # Only the unqualified default becomes the shipped default; the
        # variant-qualified ones are recorded so the interface can note them.
        if (!nzchar(variants)) prev$default <- r$text
        else prev$variant_defaults <- paste(c(prev$variant_defaults,
                                              paste0(variants, "=", gsub("\n", " | ", r$text))),
                                            collapse = " ;; ")
        fmap[[key]] <- prev
        j <- r$next_i; next
      }
      j <- j + 1L
    }

    # A leading backslash is a line-continuation marker in the source format.
    clean_form <- function(x) trimws(sub("^\\\\\\s*\n?", "", x))
    parms_form <- clean_form(parms_form); answer_form <- clean_form(answer_form)
    if (!nzchar(parms_form) && !nzchar(answer_form)) next

    defs[[length(defs) + 1L]] <- data.frame(
      extension = ext, keyword = kw,
      description = gsub("\\s*\n\\s*", " ", trimws(desc)),
      parms_form = parms_form,
      answer_form = answer_form,
      n_fields = length(fmap),
      stringsAsFactors = FALSE)

    for (key in names(fmap)) {
      fd <- fmap[[key]]
      dflt <- trimws(nz_chr(fd$default))
      widget <- nz_chr(fd$widget)
      options <- ""; default_value <- dflt; vmin <- NA_real_; vmax <- NA_real_
      if (widget %in% c("sliderBox", "intSliderBox")) {
        nums <- suppressWarnings(as.numeric(strsplit(dflt, "\\s+")[[1]]))
        nums <- nums[!is.na(nums)]
        if (length(nums) >= 3) { default_value <- nums[1]; vmin <- nums[2]; vmax <- nums[3] }
      } else if (grepl("listButton", widget, ignore.case = TRUE)) {
        opts <- unlist(strsplit(dflt, "\n|\\\\n"))
        opts <- trimws(opts); opts <- opts[nzchar(opts)]
        marked <- grepl("^>", opts)
        opts <- sub("^>", "", opts)
        default_value <- if (any(marked)) opts[which(marked)[1]] else if (length(opts)) opts[1] else ""
        options <- paste(opts, collapse = "|")
      }
      fields[[length(fields) + 1L]] <- data.frame(
        extension = ext, keyword = kw, field = fd$field,
        widget = widget, label = nz_chr(fd$label),
        default = as.character(default_value),
        min = vmin, max = vmax,
        options = options,
        variant_defaults = nz_chr(fd$variant_defaults),
        stringsAsFactors = FALSE)
    }
  }
}

D <- do.call(rbind, defs)
F <- do.call(rbind, fields)
F <- F[order(F$extension, F$keyword, F$field), ]

write.csv(D, file.path(outdir, "keyword_defs.csv"), row.names = FALSE)
write.csv(F, file.path(outdir, "keyword_fields.csv"), row.names = FALSE)
cat("wrote keyword_defs.csv:", nrow(D), "keywords across",
    length(unique(D$extension)), "extensions\n")
cat("wrote keyword_fields.csv:", nrow(F), "fields\n")
