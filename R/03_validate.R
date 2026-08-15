# ------------------------------------------------------------------------------
# Input validation.
#
# The goal is to tell the user what FVS will do with their data *before* they
# run it, and to catch the conditions that make FVS stop or silently produce
# per-acre values the cruiser did not intend.
# ------------------------------------------------------------------------------

new_issues <- function() {
  data.frame(severity = character(0), scope = character(0), stand = character(0),
             message = character(0), detail = character(0), stringsAsFactors = FALSE)
}

add_issue <- function(issues, severity, scope, stand, message, detail = "") {
  rbind(issues, data.frame(severity = severity, scope = scope, stand = as.character(stand),
                           message = message, detail = detail, stringsAsFactors = FALSE))
}

issue_counts <- function(issues) {
  c(error = sum(issues$severity == "error"),
    warning = sum(issues$severity == "warning"),
    note = sum(issues$severity == "note"))
}

# ------------------------------------------------------------------------------
# Stage A: structural / schema validation
#
# Everything downstream assumes certain tables and columns exist. When they do
# not, the failure used to surface as an R subscript error from deep inside the
# expansion code, which tells the user nothing. These checks run first and say
# what is missing in terms of the FVS input schema.
# ------------------------------------------------------------------------------

#' Columns uFVS cannot proceed without.
SCHEMA_REQUIRED <- list(
  stands = c("STAND_ID"),
  trees  = c("STAND_ID", "DIAMETER"))

#' Columns that are not fatal but change what FVS does when absent.
SCHEMA_EXPECTED <- list(
  stands = c("VARIANT", "INV_YEAR"),
  trees  = c("SPECIES"))

#' Structural validation of an imported dataset.
#'
#' Returns the same issue frame as the semantic checks. Any "error" here means
#' the dataset is not safe to expand, and callers should stop before doing so.
validate_schema <- function(data) {
  iss <- new_issues()

  if (is.null(data) || !is.list(data)) {
    return(add_issue(iss, "error", "schema", "*", "No dataset was read",
                     "The file produced nothing uFVS could interpret."))
  }

  # --- required tables -------------------------------------------------------
  for (tbl in c("stands", "trees")) {
    d <- data[[tbl]]
    fvs_name <- FVS_TABLES[[tbl]]
    if (is.null(d) || !is.data.frame(d)) {
      iss <- add_issue(iss, "error", "schema", "*",
                       sprintf("%s is missing", fvs_name),
                       sprintf("uFVS needs a %s table. Excel workbooks need a sheet with that name; a database needs that table.", fvs_name))
      next
    }
    if (!nrow(d)) {
      iss <- add_issue(iss, "error", "schema", "*",
                       sprintf("%s has no rows", fvs_name), "")
      next
    }
    # --- required columns ----------------------------------------------------
    for (col in SCHEMA_REQUIRED[[tbl]]) {
      if (!col %in% names(d)) {
        iss <- add_issue(iss, "error", "schema", "*",
                         sprintf("%s has no %s column", fvs_name, col),
                         sprintf("Columns found: %s", paste(utils::head(names(d), 12), collapse = ", ")))
      }
    }
    for (col in SCHEMA_EXPECTED[[tbl]]) {
      if (!col %in% names(d)) {
        iss <- add_issue(iss, "warning", "schema", "*",
                         sprintf("%s has no %s column", fvs_name, col),
                         "FVS will fall back to its own defaults for this field.")
      }
    }
  }
  if (any(iss$severity == "error")) return(iss)   # nothing below is safe yet

  stands <- data$stands; trees <- data$trees

  # --- keys are usable -------------------------------------------------------
  blank_stand <- sum(!nzchar(trimws(as.character(nz(stands$STAND_ID, "")))))
  if (blank_stand) {
    iss <- add_issue(iss, "error", "schema", "*",
                     sprintf("%d stand record(s) have a blank STAND_ID", blank_stand),
                     "Every stand needs an identifier that its tree records can refer to.")
  }
  dup <- stands$STAND_ID[duplicated(stands$STAND_ID)]
  if (length(dup)) {
    iss <- add_issue(iss, "error", "schema", paste(unique(dup), collapse = ", "),
                     sprintf("%d duplicated STAND_ID value(s) in %s",
                             length(unique(dup)), FVS_TABLES[["stands"]]),
                     "Stand identifiers must be unique; uFVS cannot tell the records apart.")
  }

  blank_tree_stand <- sum(!nzchar(trimws(as.character(nz(trees$STAND_ID, "")))))
  if (blank_tree_stand) {
    iss <- add_issue(iss, "error", "schema", "*",
                     sprintf("%d tree record(s) have a blank STAND_ID", blank_tree_stand), "")
  }

  # --- numeric fields really are numeric -------------------------------------
  dbh <- suppressWarnings(as.numeric(as.character(trees$DIAMETER)))
  unparsable <- sum(!is.na(trees$DIAMETER) & is.na(dbh))
  if (unparsable) {
    iss <- add_issue(iss, "error", "schema", "*",
                     sprintf("%d DIAMETER value(s) are not numbers", unparsable),
                     "Check for text, units or stray characters in the diameter column.")
  }

  # --- relationships ---------------------------------------------------------
  orphan <- setdiff(unique(as.character(trees$STAND_ID)), as.character(stands$STAND_ID))
  if (length(orphan)) {
    iss <- add_issue(iss, "error", "schema", paste(utils::head(orphan, 5), collapse = ", "),
                     sprintf("%d stand id(s) in %s have no matching stand record",
                             length(orphan), FVS_TABLES[["trees"]]),
                     "Every tree must belong to a stand listed in FVS_StandInit.")
  }
  no_trees <- setdiff(as.character(stands$STAND_ID), unique(as.character(trees$STAND_ID)))
  if (length(no_trees)) {
    iss <- add_issue(iss, "warning", "schema", paste(utils::head(no_trees, 5), collapse = ", "),
                     sprintf("%d stand(s) have no tree records", length(no_trees)), "")
  }

  # --- plots, when supplied --------------------------------------------------
  if (!is.null(data$plots) && is.data.frame(data$plots) && nrow(data$plots)) {
    if (!"STAND_ID" %in% names(data$plots)) {
      iss <- add_issue(iss, "error", "schema", "*",
                       sprintf("%s has no STAND_ID column", FVS_TABLES[["plots"]]), "")
    } else {
      po <- setdiff(unique(as.character(data$plots$STAND_ID)), as.character(stands$STAND_ID))
      if (length(po)) {
        iss <- add_issue(iss, "error", "schema", paste(utils::head(po, 5), collapse = ", "),
                         sprintf("%d stand id(s) in %s have no matching stand record",
                                 length(po), FVS_TABLES[["plots"]]), "")
      }
      if ("PLOT_ID" %in% names(data$plots)) {
        key <- paste(data$plots$STAND_ID, data$plots$PLOT_ID)
        if (anyDuplicated(key)) {
          iss <- add_issue(iss, "error", "schema", "*",
                           sprintf("%d duplicated stand/plot pair(s) in %s",
                                   sum(duplicated(key)), FVS_TABLES[["plots"]]),
                           "Each plot may appear once per stand.")
        }
      }
    }
  }

  rownames(iss) <- NULL
  iss
}

#' Does this issue set block expansion?
schema_blocks <- function(issues) {
  !is.null(issues) && nrow(issues) &&
    any(issues$severity == "error" & issues$scope == "schema")
}

#' Validate an imported dataset together with its resolved sampling designs.
validate_project <- function(data, expanded = NULL) {
  # Structural problems come first: the checks below index columns that the
  # schema pass is the one guaranteeing exist.
  schema <- validate_schema(data)
  if (schema_blocks(schema)) return(schema)

  iss <- schema
  stands <- data$stands
  trees <- data$trees

  # ---- stand-level -----------------------------------------------------------
  if (!"VARIANT" %in% names(stands)) {
    iss <- add_issue(iss, "error", "stand", "*", "No VARIANT column",
                     "FVS_StandInit must name the geographic variant for every stand.")
  }
  kv <- known_variants()

  for (i in seq_len(nrow(stands))) {
    sid <- stands$STAND_ID[i]
    v <- tolower(nz(stands$VARIANT[i], ""))
    if (!nzchar(v)) {
      iss <- add_issue(iss, "error", "stand", sid, "Variant is blank",
                       "Set VARIANT (for example 'sn') so FVS knows which growth model to use.")
    } else if (!v %in% kv) {
      iss <- add_issue(iss, "error", "stand", sid, paste0("Unknown variant '", v, "'"),
                       paste0("Known variants: ", paste(kv, collapse = ", ")))
    }

    # FVS shuts its MAI calculation off when the stand starts at age 0 with
    # trees already on it (vbase/evtstv.f: "MAIFLG IS 1 WHEN: 1) INITIAL STAND
    # AGE IS 0 AND INITIAL TPA IS NOT 0 ... THE MAI CALCULATION IS SHUT OFF").
    # Without this note a missing AGE looks like a broken MAI column.
    age <- if ("AGE" %in% names(stands)) safe_num(stands$AGE[i]) else NA_real_
    if (is.na(age) || age <= 0) {
      iss <- add_issue(iss, "warning", "stand", sid, "Stand AGE is missing",
                       paste("FVS will report MAI as 0 for every cycle: it switches the mean annual",
                             "increment calculation off when a stand starts at age 0 with trees",
                             "already present. Everything else projects normally. Set AGE in",
                             "FVS_StandInit to get MAI."))
    }

    yr <- safe_num(nz(stands$INV_YEAR[i], NA))
    if (is.na(yr)) {
      iss <- add_issue(iss, "error", "stand", sid, "INV_YEAR is missing",
                       "The inventory year sets the start of the projection.")
    } else if (yr < 1900 || yr > 2200) {
      iss <- add_issue(iss, "warning", "stand", sid, paste0("INV_YEAR ", yr, " looks wrong"), "")
    }

    tr <- trees[trees$STAND_ID == sid, , drop = FALSE]
    if (!nrow(tr)) {
      iss <- add_issue(iss, "warning", "stand", sid, "Stand has no tree records", "")
      next
    }

    des <- if (!is.null(expanded)) expanded$designs[[sid]] else
      stand_design(stands[i, , drop = FALSE], tr,
                   if (!is.null(data$plots)) data$plots[data$plots$STAND_ID == sid, , drop = FALSE] else NULL)

    observed <- des$observed_plots
    declared <- safe_num(nz(stands$NUM_PLOTS[i], NA))

    # FVS terminates when more plot ids are tallied than NUM_PLOTS declares.
    if (!is.na(declared) && declared > 1 && observed > declared) {
      iss <- add_issue(iss, "error", "design", sid,
                       sprintf("More plots tallied (%d) than NUM_PLOTS declares (%d)", observed, declared),
                       "FVS stops the run in this case because trees-per-acre cannot be computed correctly.")
    }
    if (!is.na(declared) && declared > observed) {
      iss <- add_issue(iss, "note", "design", sid,
                       sprintf("%d of %d plots carry no tally", declared - observed, declared),
                       paste("FVS treats the balance as non-stocked points. uFVS keeps them in the sample",
                             "as zero observations, which is what an unbiased plot mean requires."))
    }
    if (is.na(declared)) {
      iss <- add_issue(iss, "warning", "design", sid, "NUM_PLOTS is missing",
                       sprintf("uFVS and FVS both fall back to the %d distinct plot ids found in the tree data.", observed))
    }

    if (identical(des$source$baf, "variant default")) {
      iss <- add_issue(iss, "warning", "design", sid,
                       sprintf("BASAL_AREA_FACTOR missing — using %s variant default (%s)", des$variant, fmt_num(des$baf, 1)),
                       "Every per-acre value depends on this. Set it in the inventory if the default is wrong.")
    } else if (des$baf < 0) {
      iss <- add_issue(iss, "note", "design", sid,
                       sprintf("BASAL_AREA_FACTOR %s means fixed 1/%s acre plots, not a prism factor",
                               fmt_num(des$baf, 1), fmt_num(-des$baf, 0)),
                       "This is the FVS convention for a negative value (base/notre.f).")
    }
    if (identical(des$source$fpa, "variant default")) {
      small <- sum(tr$DIAMETER < des$brk, na.rm = TRUE)
      sev <- if (small > 0) "warning" else "note"
      iss <- add_issue(iss, sev, "design", sid,
                       sprintf("INV_PLOT_SIZE missing — using %s variant default (1/%s acre) below %s in DBH",
                               des$variant, fmt_num(des$fpa, 0), fmt_num(des$brk, 1)),
                       sprintf("%d tree record(s) fall below the break diameter and are expanded on that plot size.", small))
    }

    # ---- tree-level ----------------------------------------------------------
    nd <- sum(is.na(tr$DIAMETER) | tr$DIAMETER <= 0)
    if (nd) iss <- add_issue(iss, "error", "tree", sid,
                             sprintf("%d tree record(s) have no usable DIAMETER", nd),
                             "FVS cannot expand a record without a diameter.")

    if ("HT" %in% names(tr)) {
      nh <- sum(is.na(tr$HT) | tr$HT <= 0)
      if (nh) iss <- add_issue(iss, "note", "tree", sid,
                               sprintf("%d of %d trees have no height", nh, nrow(tr)),
                               paste("FVS estimates missing heights from its variant height-diameter",
                                     "equations. uFVS does not dub heights and does not need them:",
                                     "trees per acre and basal area come from DBH alone."))
    }

    if ("CRRATIO" %in% names(tr)) {
      nc <- sum(is.na(tr$CRRATIO))
      if (nc == nrow(tr)) iss <- add_issue(iss, "note", "tree", sid, "No crown ratios supplied",
                                           "FVS estimates crown ratio when it is absent.")
    }

    if (nzchar(v) && v %in% kv) {
      sp_ok <- species_for_variant(v)$species_code
      bad <- setdiff(unique(tr$SPECIES), c(sp_ok, NA))
      if (length(bad)) {
        iss <- add_issue(iss, "error", "tree", sid,
                         sprintf("Species code(s) not in variant %s: %s", toupper(v), paste(bad, collapse = ", ")),
                         paste0("Variant ", toupper(v), " accepts ", length(sp_ok), " codes. ",
                                "Check the FVS species crosswalk for this variant."))
      }
    }

    tc <- col_or(tr, "TREE_COUNT", NA_real_)
    if (any(!is.na(tc) & tc <= 0)) {
      iss <- add_issue(iss, "note", "tree", sid,
                       sprintf("%d record(s) have TREE_COUNT <= 0", sum(!is.na(tc) & tc <= 0)),
                       "FVS treats these as a count of 1.")
    }
  }

  # ---- project-level ---------------------------------------------------------
  if (length(unique(tolower(nz(stands$VARIANT, "")))) > 1) {
    iss <- add_issue(iss, "note", "project", "*", "Project mixes FVS variants",
                     "Each stand runs under its own variant. Comparisons across variants should say so.")
  }
  orphan <- setdiff(unique(trees$STAND_ID), stands$STAND_ID)
  if (length(orphan)) {
    iss <- add_issue(iss, "error", "project", paste(orphan, collapse = ", "),
                     sprintf("%d stand id(s) in FVS_TreeInit have no FVS_StandInit record", length(orphan)), "")
  }

  rownames(iss) <- NULL
  iss
}
