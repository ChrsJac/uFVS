# ------------------------------------------------------------------------------
# Chart builder.
#
# The flexible "pick any variable for any role" chart builder is worth keeping,
# but only if it explains itself when a combination will not work. A blank plot
# is the one failure mode this module exists to prevent: every request is
# checked first, and an impossible request comes back as a sentence describing
# what is wrong and what would work instead.
# ------------------------------------------------------------------------------

#' Variables that can actually be plotted, given the tables a run produced.
#' Source tables a variable can come from. Several FVS columns (Year, StandID,
#' DBH, ...) appear in more than one output table, so this is a set, not a
#' single value.
var_tables <- function(meta_row) {
  trimws(unlist(strsplit(nz(meta_row$source_table, ""), ",")))
}

chart_variables <- function(available_tables = NULL) {
  v <- variable_metadata()
  if (!is.null(available_tables)) {
    keep <- vapply(seq_len(nrow(v)), function(i)
      any(var_tables(v[i, ]) %in% available_tables), logical(1))
    v <- v[keep, , drop = FALSE]
  }
  v
}

vars_for_role <- function(role, available_tables = NULL) {
  v <- chart_variables(available_tables)
  col <- paste0("role_", role)
  if (!col %in% names(v)) return(character(0))
  keep <- as.logical(v[[col]])
  stats::setNames(v$variable[keep %in% TRUE], v$label[keep %in% TRUE])
}

var_meta <- function(name) {
  v <- variable_metadata()
  r <- v[v$variable == name, , drop = FALSE]
  if (!nrow(r)) return(NULL)
  r[1, ]
}

#' A chart request.
default_chart_spec <- function() {
  list(type = "line", x = "Year", y = "BA", group = "None",
       facet_row = "None", facet_col = "None",
       summary = "mean", scales = "fixed", points = TRUE,
       filters = list())
}

is_none <- function(x) is.null(x) || !nzchar(nz(x, "")) || identical(x, "None")

#' Check a chart request before drawing anything.
#'
#' @return list(ok, message, suggestions, plan)
validate_chart <- function(spec, data_tables, available_tables = names(data_tables)) {
  msgs <- character(0); sugg <- character(0)

  # An unset axis is a normal state (nothing run yet, or the menus have not been
  # populated), not an error to crash on.
  if (is_none(spec$x) || is_none(spec$y)) {
    return(list(ok = FALSE,
                message = "Choose an X and a Y variable.",
                suggestions = if (!length(available_tables))
                  "Run a scenario first; the variable lists come from its output."
                else character(0),
                plan = NULL))
  }

  need <- c(spec$x, spec$y,
            if (!is_none(spec$group)) spec$group,
            if (!is_none(spec$facet_row)) spec$facet_row,
            if (!is_none(spec$facet_col)) spec$facet_col)
  need <- need[!is.na(need) & nzchar(need)]
  if (!length(need)) {
    return(list(ok = FALSE, message = "Choose an X and a Y variable.",
                suggestions = character(0), plan = NULL))
  }

  metas <- lapply(need, var_meta)
  unknown <- need[vapply(metas, is.null, logical(1))]
  if (length(unknown)) {
    return(list(ok = FALSE,
                message = sprintf("uFVS does not know the variable%s %s.",
                                  if (length(unknown) > 1) "s" else "",
                                  paste(unknown, collapse = ", ")),
                suggestions = "Pick a variable from the lists; they are limited to what this run produced.",
                plan = NULL))
  }
  metas <- do.call(rbind, metas)

  # 1. Is any source table for each variable present in this run?
  cand <- lapply(seq_len(nrow(metas)), function(i) var_tables(metas[i, ]))
  present <- lapply(cand, function(x) intersect(x, available_tables))
  empty <- which(lengths(present) == 0)
  if (length(empty)) {
    which_vars <- metas$variable[empty]
    want <- unique(unlist(cand[empty]))
    return(list(ok = FALSE,
                message = sprintf("%s come%s from %s, which this run did not produce.",
                                  paste(which_vars, collapse = ", "),
                                  if (length(which_vars) > 1) "" else "s",
                                  paste(want, collapse = " or ")),
                suggestions = paste(missing_table_advice(intersect(want, names(FVS_OUTPUT_TABLES))),
                                    collapse = " "),
                plan = NULL))
  }

  # 2. Can all of them be served from one table? Variables that appear in
  # several FVS tables are resolved to whichever table serves the whole chart,
  # so uFVS never has to invent a join between two levels of detail.
  common <- Reduce(intersect, present)
  if (!length(common)) {
    levs <- unique(metas$level)
    return(list(ok = FALSE,
                message = sprintf("These variables live at different levels of detail (%s), so uFVS cannot put them on one chart without inventing a join.",
                                  paste(levs, collapse = " and ")),
                suggestions = sprintf("Choose variables from one level. %s are %s-level; %s are %s-level.",
                                      paste(metas$variable[metas$level == levs[1]], collapse = ", "), levs[1],
                                      paste(metas$variable[metas$level == levs[length(levs)]], collapse = ", "),
                                      levs[length(levs)]),
                plan = NULL))
  }
  # Prefer the table that actually has rows.
  nonempty <- common[vapply(common, function(t) {
    x <- data_tables[[t]]; !is.null(x) && nrow(x) > 0 }, logical(1))]
  tbl <- if (length(nonempty)) nonempty[1] else common[1]
  d <- data_tables[[tbl]]
  if (is.null(d) || !nrow(d)) {
    return(list(ok = FALSE, message = sprintf("%s is present but empty.", tbl),
                suggestions = "Run a scenario that produces this output, then plot it.", plan = NULL))
  }

  # 3. Are the columns actually in the data?
  absent <- setdiff(need, names(d))
  if (length(absent)) {
    return(list(ok = FALSE,
                message = sprintf("%s is not a column in %s for this run.",
                                  paste(absent, collapse = ", "), tbl),
                suggestions = sprintf("Available: %s", paste(utils::head(names(d), 15), collapse = ", ")),
                plan = NULL))
  }

  # 4. Role sanity: a continuous y, a usable x.
  ymeta <- var_meta(spec$y)
  if (identical(ymeta$type, "categorical")) {
    return(list(ok = FALSE,
                message = sprintf("%s is a label, not a measurement, so it cannot be the Y axis.", spec$y),
                suggestions = sprintf("Use %s for color or facets instead, and pick a numeric Y such as %s.",
                                      spec$y, paste(utils::head(names(vars_for_role("y", available_tables)), 3), collapse = ", ")),
                plan = NULL))
  }

  # 5. Facet cardinality: a facet on a near-unique variable produces confetti.
  for (role in c("facet_row", "facet_col")) {
    fv <- spec[[role]]
    if (is_none(fv)) next
    n <- length(unique(d[[fv]]))
    if (n > 30) {
      return(list(ok = FALSE,
                  message = sprintf("Faceting by %s would draw %d panels.", fv, n),
                  suggestions = sprintf("Use %s as color instead, or filter to fewer values first.", fv),
                  plan = NULL))
    }
  }

  # 6. Several scenarios on one chart must be separated by something, or the
  # aggregation step would average them together and quietly show a curve that
  # belongs to no scenario at all.
  if ("SCENARIO" %in% names(d)) {
    n_scen <- length(unique(d$SCENARIO))
    used <- c(spec$group, spec$facet_row, spec$facet_col)
    if (n_scen > 1 && !("SCENARIO" %in% used)) {
      return(list(ok = FALSE,
                  message = sprintf("%d scenarios are selected but nothing separates them, so they would be averaged into one line.",
                                    n_scen),
                  suggestions = "Set Color or Facet wrap to Scenario, or select a single scenario.",
                  plan = NULL))
    }
  }

  # 7. Does aggregation change what is being shown?
  grain_note <- ""
  # The same variable can legitimately drive color and facets at once; counting
  # it twice duplicates the column in the plotted data and reads badly in the
  # summary message.
  gcols <- unique(c(spec$x, if (!is_none(spec$group)) spec$group,
                    if (!is_none(spec$facet_row)) spec$facet_row,
                    if (!is_none(spec$facet_col)) spec$facet_col))
  gcols <- gcols[!vapply(gcols, is_none, logical(1))]
  dup <- anyDuplicated(d[, gcols, drop = FALSE]) > 0
  if (dup) {
    grain_note <- sprintf("Several rows share the same %s, so %s is summarized by %s.",
                          paste(gcols, collapse = " + "), spec$y, nz(spec$summary, "mean"))
  }

  list(ok = TRUE,
       message = sprintf("Plotting %s by %s from %s (%d rows).%s",
                         nz(ymeta$label, spec$y), nz(var_meta(spec$x)$label, spec$x),
                         tbl, nrow(d), if (nzchar(grain_note)) paste0(" ", grain_note) else ""),
       suggestions = character(0),
       plan = list(table = tbl, need = need, aggregate = dup, group_cols = gcols))
}

#' Apply the user's filters to a table.
apply_chart_filters <- function(d, filters) {
  if (!length(filters)) return(d)
  for (nm in names(filters)) {
    v <- filters[[nm]]
    if (is.null(v) || !length(v) || !nm %in% names(d)) next
    if (identical(v, "All") || (length(v) == 1 && identical(v, ""))) next
    d <- d[as.character(d[[nm]]) %in% as.character(v), , drop = FALSE]
  }
  d
}

#' Aggregate to the plotted grain.
aggregate_for_chart <- function(d, spec, plan) {
  if (!plan$aggregate) return(d)
  fn <- switch(nz(spec$summary, "mean"),
               mean = function(z) mean(z, na.rm = TRUE),
               sum = function(z) sum(z, na.rm = TRUE),
               median = function(z) stats::median(z, na.rm = TRUE),
               max = function(z) max(z, na.rm = TRUE),
               min = function(z) min(z, na.rm = TRUE),
               function(z) mean(z, na.rm = TRUE))
  key <- do.call(paste, c(lapply(plan$group_cols, function(g) d[[g]]), sep = "\r"))
  do.call(rbind, lapply(split(d, key), function(x) {
    row <- x[1, plan$group_cols, drop = FALSE]
    row[[spec$y]] <- fn(safe_num(x[[spec$y]]))
    row
  }))
}

#' Build the chart. Only called after validate_chart() returns ok.
build_chart <- function(spec, data_tables, validation) {
  if (!is.list(validation) || !isTRUE(validation$ok) ||
      !is.list(validation$plan) || !nzchar(nz(validation$plan$table, ""))) {
    return(list(plot = NULL, data = NULL,
                message = nz(validation$message, "This chart is not ready to draw.")))
  }
  plan <- validation$plan
  d <- data_tables[[plan$table]]
  if (is.null(d) || !is.data.frame(d)) {
    return(list(plot = NULL, data = NULL,
                message = sprintf("The output table %s is not available.", plan$table)))
  }
  d <- apply_chart_filters(d, spec$filters)
  if (!nrow(d)) {
    return(list(plot = NULL, data = d,
                message = "Every row was removed by the filters. Widen them to see a chart."))
  }
  d <- aggregate_for_chart(d, spec, plan)

  xm <- var_meta(spec$x); ym <- var_meta(spec$y)
  for (nm in c(spec$x, spec$y)) {
    meta <- var_meta(nm)
    if (nm %in% names(d) && !is.null(meta) && meta$type %in% c("numeric", "integer"))
      d[[nm]] <- safe_num(d[[nm]])
  }
  aes_args <- list(x = as.name(spec$x), y = as.name(spec$y))
  if (!is_none(spec$group)) {
    aes_args$color <- as.name(spec$group)
    aes_args$group <- as.name(spec$group)
  }

  p <- ggplot2::ggplot(d, do.call(ggplot2::aes, aes_args))
  p <- switch(nz(spec$type, "line"),
    line = p + ggplot2::geom_line(linewidth = 0.8),
    bar  = p + ggplot2::geom_col(position = "dodge",
                                 ggplot2::aes(fill = if (!is_none(spec$group)) .data[[spec$group]] else NULL)),
    point = p + ggplot2::geom_point(size = 2),
    area = p + ggplot2::geom_area(position = "stack",
                                  ggplot2::aes(fill = if (!is_none(spec$group)) .data[[spec$group]] else NULL)),
    p + ggplot2::geom_line(linewidth = 0.8))
  if (isTRUE(spec$points) && identical(nz(spec$type, "line"), "line")) {
    p <- p + ggplot2::geom_point(size = 1.6)
  }

  # One facet variable wraps, which reads far better than a single row or
  # column of panels; two fall back to a grid.
  if (!is_none(spec$facet_row) && !is_none(spec$facet_col)) {
    p <- p + ggplot2::facet_grid(
      stats::as.formula(paste(spec$facet_row, "~", spec$facet_col)),
      scales = nz(spec$scales, "fixed"))
  } else {
    one <- if (!is_none(spec$facet_row)) spec$facet_row else
           if (!is_none(spec$facet_col)) spec$facet_col else NULL
    if (!is.null(one)) {
      p <- p + ggplot2::facet_wrap(stats::as.formula(paste("~", one)),
                                   scales = nz(spec$scales, "fixed"))
    }
  }

  lab <- function(m, v) if (is.null(m)) v else
    paste0(m$label, if (nzchar(nz(m$units, ""))) paste0(" (", m$units, ")") else "")

  p <- p +
    ggplot2::labs(x = lab(xm, spec$x), y = lab(ym, spec$y),
                  color = if (!is_none(spec$group)) nz(var_meta(spec$group)$label, spec$group) else NULL,
                  fill = if (!is_none(spec$group)) nz(var_meta(spec$group)$label, spec$group) else NULL) +
    ufvs_axis_theme()

  list(plot = p, data = d, message = validation$message)
}

#' Axis-forward styling: no gridlines, and the axes themselves drawn heavy so
#' the bars are read against the axis rather than against a grid.
ufvs_axis_theme <- function() {
  ggplot2::theme_minimal(base_size = 12) +
    ggplot2::theme(
      panel.grid = ggplot2::element_blank(),
      axis.line = ggplot2::element_line(color = "#171a1d", linewidth = 0.9),
      axis.ticks = ggplot2::element_line(color = "#171a1d", linewidth = 0.7),
      axis.ticks.length = ggplot2::unit(4, "pt"),
      axis.title = ggplot2::element_text(color = "#171a1d", face = "bold"),
      axis.text = ggplot2::element_text(color = "#4a5257"),
      strip.text = ggplot2::element_text(color = "#171a1d", face = "bold"),
      legend.position = "bottom",
      legend.key.size = ggplot2::unit(11, "pt"),
      plot.margin = ggplot2::margin(8, 12, 8, 8))
}

#' Kept as an alias so older callers still resolve; every chart uses the
#' axis-forward styling.
ufvs_theme <- function() ufvs_axis_theme()

#' Deprecated gridded styling, retained only for reference.
ufvs_theme_gridded <- function() {
  ggplot2::theme_minimal(base_size = 12) +
    ggplot2::theme(
      panel.grid.minor = ggplot2::element_blank(),
      panel.grid.major = ggplot2::element_line(color = "#e6eaed"),
      axis.title = ggplot2::element_text(color = "#4a5257"),
      axis.text = ggplot2::element_text(color = "#6e777d"),
      strip.text = ggplot2::element_text(color = "#171a1d", face = "bold"),
      legend.position = "bottom",
      plot.margin = ggplot2::margin(8, 12, 8, 8))
}

UFVS_PALETTE <- c("#2868c7", "#238b45", "#c7742b", "#8a4fbf", "#c04a4a",
                  "#2b9aa8", "#7a8b1f", "#a8527d")
