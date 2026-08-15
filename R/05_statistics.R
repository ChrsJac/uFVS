# ------------------------------------------------------------------------------
# Inventory sampling statistics.
#
# Everything here is computed from the SAMPLING UNIT — the plot or point — never
# from expanded tree records. A 47-point cruise has n = 47 regardless of how many
# trees were tallied; treating the 387 tree records as independent observations
# would shrink the standard error by roughly a factor of three and produce
# confidence intervals that are simply wrong.
#
# These describe sampling uncertainty in the CURRENT inventory. They are not
# confidence intervals around FVS projections, and uFVS never labels them as if
# they were.
# ------------------------------------------------------------------------------

#' The statistics a user can switch on. `id` is the settings key, `col` the
#' column heading, `group` drives the layout of the Statistics page.
STAT_DEFS <- list(
  list(id = "mean",      col = "Estimate",  label = "Mean",                      group = "descriptive", digits = 2),
  list(id = "ci",        col = "CI",        label = "Confidence interval",       group = "precision",   digits = 2),
  list(id = "lcl",       col = "LCL",       label = "Lower confidence limit",    group = "precision",   digits = 2),
  list(id = "ucl",       col = "UCL",       label = "Upper confidence limit",    group = "precision",   digits = 2),
  list(id = "se_pct",    col = "SE%",       label = "Sampling error (%)",        group = "precision",   digits = 1),
  list(id = "se_abs",    col = "SE±",       label = "Sampling error (absolute)", group = "precision",   digits = 2),
  list(id = "se",        col = "SE",        label = "Standard error",            group = "precision",   digits = 3),
  list(id = "cv",        col = "CV%",       label = "Coefficient of variation",  group = "precision",   digits = 1),
  list(id = "sd",        col = "SD",        label = "Standard deviation",        group = "precision",   digits = 3),
  list(id = "variance",  col = "Var",       label = "Variance",                  group = "precision",   digits = 3),
  list(id = "moe",       col = "MOE",       label = "Margin of error",           group = "precision",   digits = 3),
  list(id = "rse",       col = "RSE%",      label = "Relative standard error",   group = "precision",   digits = 2),
  list(id = "var_mean",  col = "Var(mean)", label = "Variance of the mean",      group = "precision",   digits = 4),
  list(id = "median",    col = "Median",    label = "Median",                    group = "descriptive", digits = 2),
  list(id = "min",       col = "Min",       label = "Minimum",                   group = "descriptive", digits = 2),
  list(id = "max",       col = "Max",       label = "Maximum",                   group = "descriptive", digits = 2),
  list(id = "range",     col = "Range",     label = "Range",                     group = "descriptive", digits = 2),
  list(id = "total",     col = "Total",     label = "Sum / tract total",         group = "descriptive", digits = 1),
  list(id = "n_plots",   col = "n",         label = "Number of plots / points",  group = "descriptive", digits = 0),
  list(id = "n_obs",     col = "Trees",     label = "Number of observations",    group = "descriptive", digits = 0),
  list(id = "df",        col = "df",        label = "Degrees of freedom",        group = "detail",      digits = 0),
  list(id = "t",         col = "t",         label = "t critical value",          group = "detail",      digits = 3)
)

stat_def <- function(id) {
  for (d in STAT_DEFS) if (identical(d$id, id)) return(d)
  NULL
}

#' Put a set of statistic ids into the canonical display order, so columns do
#' not reshuffle depending on the order the user ticked the boxes.
stat_order <- function(ids) {
  all_ids <- vapply(STAT_DEFS, function(d) d$id, character(1))
  all_ids[all_ids %in% ids]
}

STAT_PRESETS <- list(
  basic = list(label = "Basic",
               stats = c("mean", "ci", "se_pct")),
  cruise_qc = list(label = "Cruise QC",
                   stats = c("mean", "ci", "se_pct", "cv", "n_plots")),
  full = list(label = "Full statistics",
              stats = c("mean", "sd", "variance", "se", "cv", "lcl", "ucl",
                        "df", "t", "se_pct", "n_plots", "n_obs")))

#' Default Statistics-tab settings.
default_stat_settings <- function() {
  list(
    enabled = TRUE,
    preset = "basic",
    stats = STAT_PRESETS$basic$stats,
    confidence_level = 95,
    fpc = FALSE,
    population_plots = NA_real_,   # N for the finite population correction
    tract_acres = NA_real_,        # enables tract totals
    design = "srs"                 # documented estimator; see estimator_label()
  )
}

estimator_label <- function(settings) {
  switch(nz(settings$design, "srs"),
    srs = "Simple random / systematic sample of points, plot-level estimator",
    stratified = "Stratified sample (per-stratum estimator, weighted combination)",
    "Simple random / systematic sample of points, plot-level estimator")
}

#' Core estimator. `x` is one value per sampling unit.
#'
#' @param x numeric vector of per-plot values (zeros included).
#' @param conf_level confidence level in percent, any value in (0, 100).
#' @param n_obs optional count of tree records behind the estimate.
#' @param population_plots optional N for the finite population correction.
#' @param tract_acres optional area for expanding the per-acre mean to a total.
sampling_stats <- function(x, conf_level = 95, n_obs = NA_integer_,
                           population_plots = NA_real_, tract_acres = NA_real_) {
  conf_level <- as_scalar_num(conf_level)
  if (is.na(conf_level) || conf_level <= 0 || conf_level >= 100) conf_level <- 95
  x <- as.numeric(x)
  x <- x[!is.na(x)]
  n <- length(x)
  out <- list(n_plots = n, n_obs = n_obs)

  if (n == 0) return(c(out, list(mean = NA_real_, sd = NA_real_, variance = NA_real_,
                                 se = NA_real_, cv = NA_real_, df = NA_real_, t = NA_real_,
                                 moe = NA_real_, lcl = NA_real_, ucl = NA_real_,
                                 se_pct = NA_real_, se_abs = NA_real_, rse = NA_real_,
                                 var_mean = NA_real_, median = NA_real_, min = NA_real_,
                                 max = NA_real_, range = NA_real_, total = NA_real_)))

  m <- mean(x)
  out$mean <- m
  out$median <- stats::median(x)
  out$min <- min(x); out$max <- max(x); out$range <- max(x) - min(x)

  if (n == 1) {
    out <- c(out, list(sd = NA_real_, variance = NA_real_, se = NA_real_, cv = NA_real_,
                       df = 0, t = NA_real_, moe = NA_real_, lcl = NA_real_, ucl = NA_real_,
                       se_pct = NA_real_, se_abs = NA_real_, rse = NA_real_, var_mean = NA_real_))
    tract_acres <- as_scalar_num(tract_acres)
  out$total <- if (!is.na(tract_acres)) m * tract_acres else NA_real_
    return(out)
  }

  v <- stats::var(x)
  s <- sqrt(v)
  fpc_factor <- 1
  # A saved project can come back with these unset, so treat anything that is
  # not a single usable number as "not supplied" rather than testing it in an
  # if() that would fail on a zero-length or NULL value.
  population_plots <- as_scalar_num(population_plots)
  if (!is.na(population_plots) && population_plots > n) {
    fpc_factor <- sqrt(1 - n / population_plots)
  }
  se <- s / sqrt(n) * fpc_factor
  df <- n - 1
  alpha <- 1 - conf_level / 100
  tval <- stats::qt(1 - alpha / 2, df)
  moe <- tval * se

  out$sd <- s
  out$variance <- v
  out$se <- se
  out$var_mean <- se^2
  out$df <- df
  out$t <- tval
  out$moe <- moe
  out$lcl <- m - moe
  out$ucl <- m + moe
  out$cv <- if (m != 0) 100 * s / m else NA_real_
  out$rse <- if (m != 0) 100 * se / m else NA_real_
  # Sampling error in the cruising sense: the half-width of the interval as a
  # percent of the estimate at the chosen confidence level.
  out$se_pct <- if (m != 0) 100 * moe / abs(m) else NA_real_
  out$se_abs <- moe
  tract_acres <- as_scalar_num(tract_acres)
  out$total <- if (!is.na(tract_acres)) m * tract_acres else NA_real_
  out
}

#' Number of plots needed to hit a target sampling error.
#'
#' n = (t^2 * CV^2) / E^2, iterated because t depends on the degrees of freedom
#' of the very sample being solved for. Optional finite population correction.
required_plots <- function(cv_pct, target_error_pct, conf_level = 95,
                           population_plots = NA_real_, pilot_n = NA_integer_,
                           max_iter = 100) {
  if (is.na(cv_pct) || is.na(target_error_pct) || target_error_pct <= 0 || cv_pct <= 0) {
    return(list(n = NA_real_, iterations = 0, converged = FALSE, t = NA_real_))
  }
  n <- 2
  tval <- NA_real_
  converged <- FALSE
  for (i in seq_len(max_iter)) {
    df <- max(1, n - 1)
    tval <- stats::qt(1 - (1 - conf_level / 100) / 2, df)
    n_new <- (tval^2 * cv_pct^2) / (target_error_pct^2)
    if (!is.na(population_plots) && population_plots > 0) {
      # FPC form: n = n0 / (1 + n0/N)
      n_new <- n_new / (1 + n_new / population_plots)
    }
    n_new <- ceiling(n_new)
    if (n_new == n) { converged <- TRUE; break }
    n <- max(2, n_new)
  }
  list(n = n, iterations = i, converged = converged, t = tval,
       additional = if (!is.na(pilot_n)) max(0, n - pilot_n) else NA_real_)
}

# ------------------------------------------------------------------------------
# Applying statistics to result tables
# ------------------------------------------------------------------------------

#' Build a complete plot x group grid of per-acre values.
#'
#' Plots where a group is absent must contribute zero, not be dropped — that is
#' the difference between the mean per acre across the tract and the mean across
#' the plots that happened to contain the group.
#'
#' @param tr tree-level data carrying PLOT_ID and a per-plot per-acre value column
#' @param all_plots data.frame of every sampling unit (STAND_ID, PLOT_ID)
#' @param value_col name of the per-acre-on-own-plot column to total
#' @param group_col optional grouping column in `tr`; NULL totals everything
plot_group_values <- function(tr, all_plots, value_col, group_col = NULL) {
  if (is.null(group_col)) {
    key <- paste(all_plots$STAND_ID, all_plots$PLOT_ID, sep = "\r")
    tk <- paste(tr$STAND_ID, tr$PLOT_ID, sep = "\r")
    s <- tapply(tr[[value_col]], tk, function(z) sum(z, na.rm = TRUE))
    v <- as.numeric(s[key]); v[is.na(v)] <- 0
    return(list(`All` = v))
  }
  groups <- sort(unique(as.character(tr[[group_col]])))
  key <- paste(all_plots$STAND_ID, all_plots$PLOT_ID, sep = "\r")
  out <- lapply(groups, function(g) {
    sub <- tr[as.character(tr[[group_col]]) == g, , drop = FALSE]
    tk <- paste(sub$STAND_ID, sub$PLOT_ID, sep = "\r")
    s <- tapply(sub[[value_col]], tk, function(z) sum(z, na.rm = TRUE))
    v <- as.numeric(s[key]); v[is.na(v)] <- 0
    v
  })
  stats::setNames(out, groups)
}

#' Format one statistic for display.
format_stat <- function(id, values, digits = NULL) {
  d <- stat_def(id)
  dg <- nz(digits, if (is.null(d)) 2 else d$digits)
  if (id == "ci") return(NA)  # handled by stat_row_values
  fmt_num(values[[id]], dg)
}

#' Turn a stats list into the display columns the user asked for.
#'
#' Returns a named character vector, in the order given by `settings$stats`.
stat_row_values <- function(st, settings) {
  cl <- nz(settings$confidence_level, 95)
  out <- character(0)
  for (id in settings$stats) {
    d <- stat_def(id)
    if (is.null(d)) next
    if (id == "ci") {
      nm <- paste0(fmt_num(cl, if (cl %% 1 == 0) 0 else 1), "% CI")
      val <- if (is.na(st$lcl) || is.na(st$ucl)) "—" else
        paste0(fmt_num(st$lcl, d$digits), "–", fmt_num(st$ucl, d$digits))
    } else {
      nm <- d$col
      val <- if (id %in% c("n_plots", "n_obs", "df")) fmt_int(st[[id]]) else fmt_num(st[[id]], d$digits)
    }
    out[nm] <- val
  }
  out
}

#' Column headings implied by the current settings, in display order.
stat_column_names <- function(settings) {
  cl <- nz(settings$confidence_level, 95)
  vapply(settings$stats, function(id) {
    if (id == "ci") paste0(fmt_num(cl, if (cl %% 1 == 0) 0 else 1), "% CI")
    else nz(stat_def(id)$col, id)
  }, character(1), USE.NAMES = FALSE)
}

#' Build a statistics table for a set of named per-plot value vectors.
#'
#' @param groups named list of numeric vectors, one entry per reported row
#' @param n_obs named numeric vector of tree counts, optional
#' @param label_col heading for the first column
stat_table <- function(groups, settings, n_obs = NULL, label_col = "Variable",
                       units = NULL) {
  if (!length(groups)) return(data.frame())
  rows <- lapply(names(groups), function(g) {
    st <- sampling_stats(groups[[g]],
                         conf_level = nz(settings$confidence_level, 95),
                         n_obs = if (!is.null(n_obs)) nz(n_obs[[g]], NA) else NA,
                         population_plots = if (isTRUE(settings$fpc)) settings$population_plots else NA_real_,
                         tract_acres = settings$tract_acres)
    vals <- stat_row_values(st, settings)
    d <- as.data.frame(as.list(vals), stringsAsFactors = FALSE, check.names = FALSE)
    cbind(stats::setNames(data.frame(g, stringsAsFactors = FALSE), label_col), d)
  })
  out <- do.call(rbind, rows)
  if (!is.null(units)) {
    out <- cbind(out[1], Units = unname(units[out[[1]]]), out[-1])
  }
  rownames(out) <- NULL
  out
}


#' Rebuild statistics settings from a saved project.
#'
#' Every field is coerced back to the type the estimators expect. Values that
#' were saved as null, "NA" or a JSON list are restored as the documented
#' default rather than being dropped, which is what previously left the
#' settings object missing keys and crashed the statistics pages.
restore_stat_settings <- function(saved) {
  d <- default_stat_settings()
  if (!is.list(saved)) return(d)

  out <- d
  out$preset <- if (is.character(nz(saved$preset, NULL))) as.character(saved$preset)[1] else d$preset
  stats_sel <- stat_order(as_chr_vec(saved$stats))
  out$stats <- if (length(stats_sel)) stats_sel else d$stats

  cl <- as_scalar_num(saved$confidence_level)
  out$confidence_level <- if (!is.na(cl) && cl > 0 && cl < 100) cl else d$confidence_level

  out$fpc <- isTRUE(as.logical(nz(unlist(saved$fpc)[1], FALSE)))
  out$population_plots <- as_scalar_num(saved$population_plots)
  out$tract_acres <- as_scalar_num(saved$tract_acres)
  out$design <- if (nzchar(nz(unlist(saved$design)[1], ""))) as.character(saved$design)[1] else d$design
  out$enabled <- isTRUE(as.logical(nz(unlist(saved$enabled)[1], TRUE)))
  out
}
