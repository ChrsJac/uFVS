# ------------------------------------------------------------------------------
# FVS keyword generation.
#
# uFVS keeps the project as structured state and renders keywords from it. FVS
# keyword names are never renamed or wrapped in invented terminology: an event
# that thins from below to a residual basal area is a ThinBBA, and the interface
# says so.
#
# Keyword templates, field labels and defaults come from the official fvsOL
# parameter files (see tools/extract_keyword_defs.R and NOTICE.md). The file
# structure follows rFVS::fvsMakeKeyFile.
# ------------------------------------------------------------------------------

# FVS reads a keyword record into CHARACTER*130 and slices 10-column fields
# after the 10-column name, so twelve fields is the hard ceiling.
MAX_KEYWORD_FIELDS <- 12L

keyword_defs <- function() {
  cached("kwdefs", function() read_config_csv("keyword_defs.csv"))
}

keyword_fields_all <- function() {
  cached("kwfields", function() read_config_csv("keyword_fields.csv"))
}

#' Every keyword uFVS knows about, optionally filtered by extension.
list_keywords <- function(extension = NULL, search = NULL) {
  d <- keyword_defs()
  if (!is.null(extension) && length(extension) && !identical(extension, "all")) {
    d <- d[d$extension %in% extension, , drop = FALSE]
  }
  if (!is.null(search) && nzchar(search)) {
    hit <- grepl(search, d$keyword, ignore.case = TRUE) |
           grepl(search, d$description, ignore.case = TRUE)
    d <- d[hit, , drop = FALSE]
  }
  d[order(d$extension, d$keyword), , drop = FALSE]
}

keyword_def <- function(kw) {
  d <- keyword_defs()
  r <- d[tolower(d$keyword) == tolower(kw), , drop = FALSE]
  if (!nrow(r)) return(NULL)
  r[1, ]
}

keyword_fields <- function(kw) {
  f <- keyword_fields_all()
  r <- f[tolower(f$keyword) == tolower(kw), , drop = FALSE]
  r[order(r$field), , drop = FALSE]
}

#' Treatment catalog: the subset of keywords that schedule management, grouped
#' for the Management Plan and Treatments Library pages.
#'
#' Membership is decided by the presence of a scheduleBox field, which is how
#' FVS itself marks a keyword as a scheduled activity, plus a category derived
#' from the keyword name and extension.
treatment_keywords <- function() {
  cached("treatkw", function() {
    f <- keyword_fields_all()
    sched <- unique(f$keyword[f$widget == "scheduleBox"])
    d <- keyword_defs()
    d <- d[d$keyword %in% sched, , drop = FALSE]
    d$category <- vapply(seq_len(nrow(d)), function(i) {
      k <- d$keyword[i]; e <- d$extension[i]
      if (grepl("^Thin", k, ignore.case = TRUE)) "Thinning"
      else if (grepl("^(Salvage|YardLoss|CutEff|SpecPref|MinHarv)", k, ignore.case = TRUE)) "Harvest control"
      else if (e == "fire") "Fire & fuels"
      else if (e == "econ") "Economics"
      else if (e %in% c("estb", "estbstrp") ||
               grepl("^(Plant|Natural)", k, ignore.case = TRUE)) "Regeneration"
      else if (e %in% c("ardwrd3", "armwrd3", "phewrd3", "mist")) "Pest & disease"
      else if (grepl("^(Fertil|Prune)", k, ignore.case = TRUE)) "Silviculture"
      else if (e == "dbs") "Output"
      else "Other"
    }, character(1))
    d[order(d$category, d$keyword), , drop = FALSE]
  })
}

# ------------------------------------------------------------------------------
# Rendering
# ------------------------------------------------------------------------------

#' Format a value into an FVS keyword field of the given width.
#'
#' FVS reads fixed-width numeric fields; blank means "not supplied", which is
#' meaningfully different from zero, so empty values stay blank.
fmt_field <- function(value, width = 10) {
  if (is.null(value) || length(value) == 0L || is.na(value) ||
      (is.character(value) && !nzchar(trimws(value)))) {
    return(formatC("", width = width))
  }
  if (is.numeric(value)) {
    txt <- if (value == round(value) && abs(value) < 1e6) {
      formatC(value, format = "d")
    } else {
      formatC(value, format = "g", digits = 7)
    }
  } else {
    txt <- as.character(value)
  }
  formatC(txt, width = width)
}

#' Render one keyword record from its template and a list of field values.
#'
#' Placeholders are `!n!`, `!n,width!` or `!n,width,tag!`, where n is the field
#' number. Anything not supplied renders blank, exactly as FVS expects.
render_keyword <- function(kw, values = list(), width = 10L) {
  d <- keyword_def(kw)
  if (is.null(d)) {
    # Unknown to the catalog: emit a fixed-column record anyway so nothing is
    # unreachable, and so it still parses the way FVS expects.
    return(fixed_field_record(kw, values, n_fields = length(values), width = width))
  }

  # An answerForm is already a fixed-column layout, so it can be filled in
  # directly. Everything else is rendered as fixed columns from the field
  # catalog rather than through the Parms() form. See fixed_field_record().
  if (nzchar(nz(d$answer_form, ""))) {
    return(fill_template(d$answer_form, values, width))
  }

  n <- nrow(keyword_fields(kw))
  if (!n) n <- length(values)
  fixed_field_record(kw, values, n_fields = n, width = width)
}

#' Render a keyword as the fixed-column record FVS actually parses.
#'
#' FVS reads a keyword record as a name in columns 1-10 followed by 10-column
#' fields: `KARD(I) = RECORD(J:J+9)` in base/keyrdr.f, with RECORD declared
#' CHARACTER*130. That allows the name plus twelve fields.
#'
#' uFVS used to emit the `Parms(...)` form carried in the fvsOL templates. That
#' is a free-form Event Monitor expression, and with six arguments it runs past
#' the width FVS will read: the closing parenthesis was cut off, FVS reported
#' "MISMATCHED OR OTHER MISUSE OF PARENTHESIS", and the whole treatment was
#' silently ignored while the run still reported success. Fixed columns are the
#' canonical form and cannot overflow for a normal treatment.
fixed_field_record <- function(kw, values = list(), n_fields = 7L, width = 10L) {
  n_fields <- max(0L, min(as.integer(n_fields), MAX_KEYWORD_FIELDS))
  out <- formatC(kw, width = -width)          # name, left justified
  for (i in seq_len(n_fields)) {
    key <- as.character(i)
    val <- if (!is.null(names(values))) values[[key]]
           else if (i <= length(values)) values[[i]]
           else NULL
    out <- paste0(out, fmt_field(val, width))
  }
  sub("\\s+$", "", out)
}

#' Fill an fvsOL template that is already laid out in fixed columns.
fill_template <- function(tmpl, values, width = 10L) {
  out <- tmpl
  # Longest-first so !10,10! is not eaten by the !1 pattern.
  for (n in rev(seq_len(30))) {
    pat <- sprintf("!%d(,[^!]*)?!", n)
    m <- regexpr(pat, out)
    while (m > 0) {
      spec <- gsub("^!|!$", "", regmatches(out, m))
      bits <- strsplit(spec, ",")[[1]]
      w <- if (length(bits) >= 2) suppressWarnings(as.integer(bits[2])) else NA_integer_
      if (is.na(w)) w <- width
      key <- as.character(n)
      val <- if (!is.null(names(values))) values[[key]]
             else if (n <= length(values)) values[[n]]
             else NULL
      regmatches(out, m) <- fmt_field(val, w)
      m <- regexpr(pat, out)
    }
  }
  lines <- strsplit(out, "\n")[[1]]
  lines <- sub("\\s+$", "", lines)
  paste(lines[nzchar(lines)], collapse = "\n")
}

#' Default field values for a keyword, from the catalog.
keyword_defaults <- function(kw) {
  f <- keyword_fields(kw)
  if (!nrow(f)) return(list())
  out <- list()
  for (i in seq_len(nrow(f))) {
    v <- f$default[i]
    num <- suppressWarnings(as.numeric(v))
    out[[as.character(f$field[i])]] <- if (!is.na(num)) num else v
  }
  out
}

# ------------------------------------------------------------------------------
# Whole keyword files
# ------------------------------------------------------------------------------

#' Management identifier for a scenario.
#'
#' FVS stores the management id as four characters (A4), so uFVS emits exactly
#' what FVS will keep rather than a longer name that is silently truncated.
mgmt_id <- function(name) {
  id <- gsub("[^A-Za-z0-9]", "", nz(name, ""))
  if (!nzchar(id)) id <- "BASE"
  toupper(substr(id, 1, 4))
}

#' Validate and render Event Monitor Compute definitions.
#'
#' The expressions are FVS's, not R's: uFVS checks that a definition is
#' structurally usable and passes it through unchanged. It never evaluates or
#' rewrites an expression, because a silently "corrected" expression would make
#' FVS compute something the user did not ask for.
#'
#' @return character vector of keyword records, or character(0).
render_compute_block <- function(computes) {
  ok <- valid_computes(computes)
  if (!length(ok)) return(character(0))
  # Compute takes an optional field 1: 0 = every cycle (the default),
  # 1 = before treatment, 2 = after treatment. Definitions are grouped by that
  # so each block carries the timing the user chose.
  out <- character(0)
  for (w in unique(vapply(ok, function(c) as.character(nz(c$when, "0")), character(1)))) {
    grp <- Filter(function(c) identical(as.character(nz(c$when, "0")), w), ok)
    head_rec <- if (identical(w, "0")) "Compute" else
      sprintf("%-10s%10s", "Compute", w)
    out <- c(out, head_rec,
             vapply(grp, function(c) sprintf("%s = %s", c$name, c$expr), character(1)),
             "End")
  }
  out
}

#' Compute definitions that are usable as written.
valid_computes <- function(computes) {
  if (!length(computes)) return(list())
  Filter(function(c) {
    nm <- trimws(nz(c$name, "")); ex <- trimws(nz(c$expr, ""))
    nzchar(nm) && nzchar(ex) &&
      grepl("^[A-Za-z][A-Za-z0-9_]*$", nm) &&
      # An unbalanced expression makes FVS reject the whole Compute block.
      lengths(regmatches(ex, gregexpr("\\(", ex))) ==
      lengths(regmatches(ex, gregexpr("\\)", ex)))
  }, computes)
}

#' Compute definitions uFVS will not send, with the reason.
invalid_computes <- function(computes) {
  if (!length(computes)) return(data.frame())
  bad <- setdiff(seq_along(computes), which(computes %in% valid_computes(computes)))
  rows <- lapply(computes, function(c) {
    nm <- trimws(nz(c$name, "")); ex <- trimws(nz(c$expr, ""))
    why <- if (!nzchar(nm)) "no variable name"
           else if (!grepl("^[A-Za-z][A-Za-z0-9_]*$", nm))
             "variable name must start with a letter and use letters, digits or underscore"
           else if (!nzchar(ex)) "no expression"
           else if (lengths(regmatches(ex, gregexpr("\\(", ex))) !=
                    lengths(regmatches(ex, gregexpr("\\)", ex)))) "unbalanced parentheses"
           else NA_character_
    data.frame(name = nm, expr = ex, problem = why, stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, rows)
  out[!is.na(out$problem), , drop = FALSE]
}

#' Render the management events of one scenario, in year order.
render_events <- function(events) {
  if (!length(events)) return(character(0))
  ord <- order(vapply(events, function(e) nz(safe_num(e$year), Inf), numeric(1)))
  vapply(events[ord], function(e) {
    vals <- e$values %||% list()
    vals[["1"]] <- e$year          # field 1 is the scheduleBox on every treatment
    render_keyword(e$keyword, vals)
  }, character(1))
}

#' Build a complete keyword file for a set of stands and one scenario.
#'
#' @param stand_ids character vector of stand ids to run
#' @param scenario list(name, events, cycles, cycle_length, raw_keywords)
#' @param input_db name of the FVS input database, as seen from the run directory
#' @param output_db name of the FVS output database
build_keyword_file <- function(stand_ids, scenario, input_db = "FVS_Data.db",
                               output_db = "FVSOut.db", title = "uFVS run",
                               inv_years = NULL) {
  # FVS treats a record starting with '*' (or a blank record) as a comment;
  # see base/keyrdr.f. Anything else is parsed as a keyword, so headers must
  # use '*' and not some other comment marker.
  L <- c(
    sprintf("* uFVS %s keyword file", UFVS_VERSION),
    sprintf("* title: %s", title),
    sprintf("* scenario: %s", nz(scenario$name, "Base")),
    sprintf("* built: %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
    "")

  for (sid in stand_ids) {
    L <- c(L,
      "StdIdent",
      sprintf("%-26s%s", sid, paste(title, nz(scenario$name, ""))),
      # MGMTID reads its value from the NEXT record with an A4 format:
      #   READ (IREAD,7105,END=80) MGMID
      #   7105 FORMAT (A4)
      # (vbase/initre.f, option 69). Putting the id on the MgmtId line itself
      # made FVS consume the following keyword instead, so every run was
      # labelled "InvY" from the InvYear record beneath it.
      "MgmtId",
      mgmt_id(scenario$name))

    if (!is.null(inv_years) && !is.na(nz(inv_years[[sid]], NA))) {
      L <- c(L, sprintf("%-10s%10s", "InvYear", format(inv_years[[sid]])))
    }
    L <- c(L,
      sprintf("%-10s%10s", "NumCycle", format(nz(scenario$cycles, 10))))
    if (!is.null(scenario$cycle_length) && !is.na(scenario$cycle_length)) {
      # Field 1 is the cycle number and field 2 the length; leaving field 1
      # blank applies the length to every cycle. Putting the length in field 1
      # sets the length of *one* cycle and leaves the rest at the default.
      L <- c(L, sprintf("%-10s%10s%10s", "TimeInt", "", format(scenario$cycle_length)))
    }

    # One DataBase block carrying both the input queries and the output tables.
    # FVS rejects a second DataBase block opened after the first has been closed
    # ("KEYWORD ENTERED IS USED IN WRONG CONTEXT"), and silently drops the
    # output settings inside it, so everything goes in together.
    L <- c(L,
      "DataBase",
      "DSNIn",
      input_db,
      "StandSQL",
      "SELECT * FROM FVS_StandInit WHERE Stand_ID = '%StandID%'",
      "EndSQL",
      "TreeSQL",
      "SELECT * FROM FVS_TreeInit WHERE Stand_ID = '%StandID%'",
      "EndSQL",
      sprintf("%-10s%10s", "Summary", "2"),
      sprintf("%-10s%10s%10s", "ComputDB", "0", "1"),
      sprintf("%-10s%10s", "TreeLiDB", "2"),
      sprintf("%-10s%10s", "CutLiDB", "2"),
      sprintf("%-10s%10s", "ATRTLiDB", "2"),
      "End")

    # Volume and merchantability. Emitted only when the user has overridden the
    # variant defaults, so an untouched project keeps FVS's own standards.
    vol <- render_volume_keywords(scenario$volume)
    if (length(vol)) L <- c(L, vol)

    # Event Monitor. Compute blocks must precede the activities that reference
    # them, so they are written before the treatment records.
    cmp <- render_compute_block(scenario$computes)
    if (length(cmp)) L <- c(L, cmp)

    # Stand visualization. The SVS keyword makes FVS write one .svs file per
    # cycle plus an index, carrying tree positions, crown radii and crown
    # ratios. Field 1 is the plot geometry (1 = subdivided square) and field 2
    # the ground-file grid, left at 0 because uFVS draws no ground surface.
    if (isTRUE(scenario$svs)) {
      L <- c(L, sprintf("%-10s%10s%10s", "SVS", "1", "0"))
    }

    # TreeLiDB only writes what the run actually generates, so ask for the
    # tree and cut lists in every cycle.
    L <- c(L,
      sprintf("%-10s%10s", "TreeList", "0"),
      sprintf("%-10s%10s", "CutList", "0"),
      sprintf("%-10s%10s", "ATRTList", "0"))

    ev <- render_events(scenario$events)
    if (length(ev)) L <- c(L, "", ev)

    if (!is_blank(scenario$raw_keywords)) {
      L <- c(L, "", "* raw keywords supplied by the user",
             strsplit(scenario$raw_keywords, "\n")[[1]])
    }

    L <- c(L, "PROCESS", "")
  }
  L <- c(L, "STOP", "")
  paste(L, collapse = "\n")
}
