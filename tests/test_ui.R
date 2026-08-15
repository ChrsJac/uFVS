#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# Interface render check.
#
#   Rscript tests/test_ui.R           from the repository root
#
# Every page layout must build, and every server output must render against a
# loaded dataset. This catches the class of mistake that unit tests miss: a
# renderUI body that throws only once there is data in it.
# ------------------------------------------------------------------------------

options(ufvs.root = normalizePath(getwd()))
options(ufvs.user_dir = file.path(tempdir(), "ufvs-ui-user"))
suppressPackageStartupMessages({
  library(shiny); library(ggplot2); library(jsonlite)
  library(DBI); library(RSQLite); library(readxl); library(callr); library(digest)
})
for (f in sort(list.files("R", pattern = "[.]R$", full.names = TRUE))) source(f)

PASS <- 0; FAIL <- 0; MSGS <- character(0)
ok <- function(label, cond, detail = "") {
  if (isTRUE(cond)) { PASS <<- PASS + 1; cat(sprintf("  ok   %s\n", label)) }
  else { FAIL <<- FAIL + 1; MSGS <<- c(MSGS, label)
         cat(sprintf("  FAIL %s%s\n", label, if (nzchar(detail)) paste0(" — ", detail) else "")) }
}

# ------------------------------------------------------------------------------
cat("\nPage layouts\n")

PAGES <- c("project", "data", "keywords", "event", "inventory", "summary",
           "statistics", "management", "volume", "scenarios",
           "runsettings", "standstock", "merch", "tables", "plots", "visualize",
           "compare", "output", "log", "info")

for (p in PAGES) {
  fn <- if (p == "statistics") function() page_statistics(default_stat_settings())
        else get(paste0("page_", p))
  r <- try(as.character(fn()), silent = TRUE)
  ok(p, !inherits(r, "try-error"),
     if (inherits(r, "try-error")) conditionMessage(attr(r, "condition")) else "")
}

ok("every nav entry has a page",
   all(unlist(lapply(UFVS_NAV, function(s) names(s$items))) %in% PAGES))
ok("large numbers display without thousands separators",
   identical(fmt_num(12345.67, 2), "12345.67") &&
   identical(fmt_int(12345), "12345"))

# ------------------------------------------------------------------------------
cat("\nServer outputs against a loaded dataset\n")

# Self-contained fixture; uFVS ships no data.
build_fixture <- function() {
  p <- Sys.getenv("UFVS_TEST_DATA", "")
  if (nzchar(p) && file.exists(p)) return(p)
  set.seed(7)
  n_plots <- 20; n_trees <- 150
  stands <- data.frame(STAND_ID = "T1", VARIANT = "sn", INV_YEAR = 2024L,
                       NUM_PLOTS = n_plots, BASAL_AREA_FACTOR = -10, BRK_DBH = 2,
                       SITE_SPECIES = "LP", SITE_INDEX = 85, stringsAsFactors = FALSE)
  trees <- data.frame(
    STAND_ID = "T1",
    PLOT_ID = as.character(sort(c(seq_len(n_plots),
                                  sample(seq_len(n_plots), n_trees - n_plots, TRUE)))),
    TREE_ID = seq_len(n_trees), HISTORY = 1L,
    SPECIES = sample(c("LP", "SU", "RO"), n_trees, TRUE),
    DIAMETER = round(runif(n_trees, 5, 30), 1),
    HT = round(runif(n_trees, 40, 120)), stringsAsFactors = FALSE)
  f <- file.path(tempdir(), "ufvs_ui_fixture.db"); unlink(f)
  write_fvs_input_db(list(stands = stands, trees = trees, plots = NULL), f)
  f
}

fixture <- build_fixture()
# The importer keys off the file extension, so upload it under its real name.
updir <- file.path(tempdir(), "ufvs_upload"); dir.create(updir, showWarnings = FALSE)
upload <- file.path(updir, paste0("cruise.", tools::file_ext(fixture)))
file.copy(fixture, upload, overwrite = TRUE)

OUTPUTS <- c(
  "topbar_meta", "engine_box", "data_tables", "data_design", "data_issues",
  "project_dataset", "project_repro", "project_issues",
  "inv_tiles", "inv_species", "inv_plots", "inv_trees",
  "summary_body", "summary_stats", "summary_dbh", "stat_preview",
  "mg_scenario_bar", "mg_timeline", "mg_activity_board", "mg_editor", "mg_keyword_preview",
  "tl_count", "tl_list", "tl_detail",
  "merch_products", "merch_source_note", "merch_table", "merch_species_table",
  "ss_controls", "ss_table", "ss_species",
  "kw_file", "kw_catalog_summary", "em_list", "em_reference", "info_versions",
  "eng_hint", "eng_status_detail", "run_status_box", "run_history",
  "out_body", "log_body", "cmp_body", "tb_result", "ch_validation", "ch_plot", "ch_data",
  "vol_forms", "vol_preview", "sc_table", "sc_settings",
  "svs_controls", "svs_body", "svs_about")

results <- new.env(parent = emptyenv())
results$rows <- list()

testServer(ufvs_server, {
  session$setInputs(data_file = data.frame(
    name = basename(upload), datapath = upload,
    size = file.size(upload), type = "", stringsAsFactors = FALSE))

  results$loaded <- !is.null(rv$data) && nrow(rv$data$trees) > 0
  results$stands <- if (is.null(rv$data)) 0 else nrow(rv$data$stands)
  results$trees <- if (is.null(rv$data)) 0 else nrow(rv$data$trees)

  for (o in OUTPUTS) {
    r <- try(output[[o]], silent = TRUE)
    results$rows[[o]] <- if (inherits(r, "try-error"))
      conditionMessage(attr(r, "condition")) else NA_character_
  }

  # Exercise the interactive paths that build UI from state.
  session$setInputs(mg_add = 1)
  results$rows[["mg_editor after add"]] <-
    tryCatch({ invisible(output$mg_editor); NA_character_ },
             error = function(e) conditionMessage(e))
  results$rows[["management cards after add"]] <-
    tryCatch({ invisible(output$mg_activity_board); NA_character_ },
             error = function(e) conditionMessage(e))
  session$setInputs(mg_drop_year = list(index = 1, year = 2030, nonce = 1))
  results$rows[["dragging treatment to timeline year"]] <-
    tryCatch({ invisible(output$mg_activity_board); NA_character_ },
             error = function(e) conditionMessage(e))
  rv$results[["Base"]] <- list(
    StandSummary = data.frame(Age = 0:2, Tpa = c(80, 78, 76),
                               BA = c(110, 115, 120)),
    TreeList = NULL, CutList = NULL)
  session$setInputs(ch_x = "Age", ch_y = "Tpa", ch_group = "None",
                    ch_facet_row = "None", ch_facet_col = "None",
                    ch_type = "line", ch_summary = "mean", ch_scales = "fixed")
  results$rows[["chart validation"]] <-
    tryCatch({ invisible(output$ch_validation); NA_character_ },
             error = function(e) conditionMessage(e))
  results$rows[["chart plot renders"]] <-
    tryCatch({ invisible(output$ch_plot); NA_character_ },
             error = function(e) conditionMessage(e))
  results$rows[["chart data renders"]] <-
    tryCatch({ invisible(output$ch_data); NA_character_ },
             error = function(e) conditionMessage(e))
  session$setInputs(stat_preset = "full")
  results$rows[["stat_preview at full preset"]] <-
    tryCatch({ invisible(output$stat_preview); NA_character_ },
             error = function(e) conditionMessage(e))
  results$rows[["stat preset remains selected"]] <-
    if (identical(input$stat_preset, "full")) NA_character_ else
      paste("selected", input$stat_preset)
  session$setInputs(sum_species = c("LP", "SU"), sum_split = TRUE)
  results$rows[["summary statistics can split selected species"]] <-
    tryCatch({ invisible(output$summary_stats); NA_character_ },
             error = function(e) conditionMessage(e))
  session$setInputs(plots_enable = TRUE, plots_target = 7.5, plots_var = "BA")
  results$rows[["plots_required"]] <-
    tryCatch({ invisible(output$plots_required); NA_character_ },
             error = function(e) conditionMessage(e))
  session$setInputs(merch_add = 1)
  results$rows[["merch_table after add class"]] <-
    tryCatch({ invisible(output$merch_table); NA_character_ },
             error = function(e) conditionMessage(e))
})

ok(sprintf("dataset loaded through the file input (%d stand, %d trees)",
           results$stands, results$trees), isTRUE(results$loaded))
for (nm in names(results$rows)) {
  ok(nm, is.na(results$rows[[nm]]), nz(results$rows[[nm]], ""))
}

# Regression: projects written by older versions can contain JSON "NA" strings
# and a dataset path. Restore must normalize those values before the reactive
# controls test them, or the Statistics / Management pages throw length/type
# errors while opening the project.
restore_project_file <- file.path(tempdir(), "ufvs-restore-project.ufvs.json")
jsonlite::write_json(list(
  version = UFVS_VERSION,
  project = list(name = "Restored", owner = "", acres = "NA"),
  stats = list(enabled = TRUE, preset = "basic", stats = c("mean", "ci", "se_pct"),
               confidence_level = 95, fpc = FALSE, population_plots = "NA",
               tract_acres = "NA", design = "srs"),
  products = default_products(), volume = default_volume_settings(),
  scenarios = list(Base = list(name = "Base", cycles = 3, cycle_length = 5,
                               start_year = "NA", events = list(),
                               raw_keywords = "", computes = list())),
  current = "Base",
  dataset = list(path = upload, paths = upload, names = basename(upload), type = "sqlite",
                 name = basename(upload))),
  restore_project_file, auto_unbox = TRUE, pretty = TRUE, null = "null")
restore <- new.env(parent = emptyenv())
testServer(ufvs_server, {
  session$setInputs(proj_load_file = NULL)
  session$setInputs(proj_load_file = data.frame(
    name = basename(restore_project_file), datapath = restore_project_file,
    size = file.size(restore_project_file), type = "application/json",
    stringsAsFactors = FALSE))
  restore$summary <- tryCatch({ invisible(output$summary_body); TRUE }, error = function(e) FALSE)
  restore$timeline <- tryCatch({ invisible(output$mg_scenario_bar); TRUE }, error = function(e) FALSE)
  restore$stats <- tryCatch({ invisible(output$stat_preview); TRUE }, error = function(e) FALSE)
  restore$loaded <- !is.null(rv$data) && identical(rv$project$name, "Restored")
})
ok("a saved project reloads its inventory", isTRUE(restore$loaded))
ok("restored project settings do not break Stand Summary", isTRUE(restore$summary))
ok("restored JSON NA values do not break the timeline", isTRUE(restore$timeline))
ok("restored JSON NA values do not break Statistics", isTRUE(restore$stats))

# ------------------------------------------------------------------------------
cat("\nResult controls are populated once a run exists\n")

# Regression: the chart and table pickers used to be filled with
# updateSelectInput from an observer. That only reaches inputs the browser is
# currently showing, so choices computed while another page was open were
# dropped and the menus stayed empty after a run. They are rendered now, and
# these checks fail if anyone pushes them back into an observer.

has_option <- function(html, value) {
  grepl(sprintf('value="%s"', value), html, fixed = TRUE)
}

fake_results <- list(
  StandSummary = data.frame(
    CaseID = "c1", StandID = "T1", Year = c(2024, 2029, 2034),
    Tpa = c(80, 78, 76), BA = c(110, 118, 126), QMD = c(15.9, 16.6, 17.4),
    MCuFt = c(3100, 3400, 3700), BdFt = c(16000, 18000, 20000),
    SCENARIO = "Base", stringsAsFactors = FALSE),
  TreeList = data.frame(
    CaseID = "c1", StandID = "T1", Year = 2024,
    TreeId = 1:6, SpeciesFVS = c("LP", "LP", "SU", "RO", "LP", "SU"),
    DBH = c(7, 10, 13, 16, 21, 26), Ht = c(45, 60, 72, 80, 92, 99),
    TPA = rep(2, 6), PtIndex = c(1, 2, 3, 4, 5, 6),
    TCuFt = c(5, 12, 22, 35, 60, 90), MCuFt = c(4, 11, 21, 34, 58, 88),
    SCuFt = c(0, 0, 15, 28, 50, 78), BdFt = c(0, 0, 60, 140, 300, 480),
    SCENARIO = "Base", stringsAsFactors = FALSE))

variant_results <- function(x, scenario, variant, scale = 1) {
  lapply(x, function(d) {
    if (is.null(d)) return(NULL)
    d$SCENARIO <- scenario
    d$VARIANT <- variant
    for (nm in intersect(c("Tpa", "TPA", "BA", "TCuFt", "MCuFt", "SCuFt", "BdFt"), names(d)))
      d[[nm]] <- d[[nm]] * scale
    d
  })
}

ctrl <- new.env(parent = emptyenv())
testServer(ufvs_server, {
  # Deliberately no dataset upload here. Loading one clears rv$results, and the
  # upload observer flushes on first output access, which would wipe the stand-in
  # results before they could be read. These checks only need the results.
  rv$results[[rv$current]] <- fake_results

  ctrl$chart <- paste(as.character(output$ch_controls), collapse = "")
  ctrl$table <- paste(as.character(output$tb_controls), collapse = "")
  ctrl$standstock <- paste(as.character(output$ss_controls), collapse = "")

  session$setInputs(ch_x = "Year", ch_y = "BA", ch_group = "None",
                    ch_facet_row = "None", ch_facet_col = "None",
                    ch_type = "line", ch_summary = "mean", ch_scales = "fixed")
  ctrl$valid <- paste(as.character(output$ch_validation), collapse = "")
  ctrl$plot_ok <- tryCatch({ invisible(output$ch_plot); TRUE }, error = function(e) FALSE)
  ctrl$table_result <- paste(as.character(output$tb_result), collapse = "")
})

ok("chart X menu offers Year once a run exists", has_option(ctrl$chart, "Year"))
ok("chart Y menu offers a measured variable", has_option(ctrl$chart, "BA"))
ok("chart color menu offers a grouping variable", has_option(ctrl$chart, "SpeciesFVS"))
ok("table source menu offers the output tables",
   has_option(ctrl$table, "StandSummary") && has_option(ctrl$table, "TreeList"))
ok("single-scenario Stand & Stock keeps its scenario picker visible",
   grepl('id="ss_scenarios"', ctrl$standstock, fixed = TRUE))
ok("single-scenario Tables keeps its scenario picker visible",
   grepl('id="tb_scenarios"', ctrl$table, fixed = TRUE))
ok("Year is offered as a grouping column, not only as a total",
   has_option(ctrl$table, "Year"))
ok("a valid chart validates", grepl("msg-ok", ctrl$valid))
ok("the chart renders", isTRUE(ctrl$plot_ok))
ok("the table builder produces rows", grepl("<table", ctrl$table_result))

# An unset chart must explain itself rather than crash. This previously threw
# "argument must be coercible to non-negative integer" from seq_len(NULL).
blank <- list(type = "line", x = "", y = "", group = "None", facet_row = "None",
              facet_col = "None", summary = "mean", scales = "fixed",
              points = TRUE, filters = list())
v <- tryCatch(validate_chart(blank, fake_results, names(fake_results)),
              error = function(e) list(ok = NA, message = conditionMessage(e)))
ok("an unset chart is refused, not an error", identical(v$ok, FALSE))
ok("and it says what to do", grepl("Choose", nz(v$message, "")))

v2 <- tryCatch(validate_chart(blank, list(), character(0)),
               error = function(e) list(ok = NA, message = conditionMessage(e)))
ok("an unset chart with no run at all is also handled", identical(v2$ok, FALSE))

# Results pages keep scenario, variant, year, and species selections together.
# This catches regressions where a multiple-scenario picker renders but the
# underlying output silently falls back to the first result.
multi <- new.env(parent = emptyenv())
testServer(ufvs_server, {
  rv$results <- list(
    Base = variant_results(fake_results, "Base", "SN"),
    Thin = variant_results(fake_results, "Thin", "NE", scale = 1.1))

  session$setInputs(ch_scenarios = c("Base", "Thin"), ch_x = "Year", ch_y = "TPA",
                    ch_group = "SCENARIO", ch_facet = "SpeciesFVS",
                    ch_facet_col = "None", ch_summary = "mean", ch_scales = "fixed")
  multi$chart_controls <- paste(as.character(output$ch_controls), collapse = "")
  multi$chart_valid <- paste(as.character(output$ch_validation), collapse = "")
  multi$chart_plot <- tryCatch({ invisible(output$ch_plot); TRUE }, error = function(e) FALSE)

  session$setInputs(tb_scenarios = c("Base", "Thin"), tb_layout = "separate",
                    tb_source = "StandSummary", tb_group = "Year", tb_values = "BA")
  multi$table_result <- paste(as.character(output$tb_result), collapse = "")

  session$setInputs(ss_scenarios = c("Base", "Thin"), ss_variant = "NE", ss_year = 2024)
  multi$ss_controls <- paste(as.character(output$ss_controls), collapse = "")
  multi$ss_table <- paste(as.character(output$ss_table), collapse = "")
  multi$ss_species <- paste(as.character(output$ss_species), collapse = "")
})

ok("chart scenario picker keeps multiple scenarios",
   has_option(multi$chart_controls, "Base") && has_option(multi$chart_controls, "Thin"))
ok("chart facet menu includes species", has_option(multi$chart_controls, "SpeciesFVS"))
ok("multiple-scenario species chart validates", grepl("msg-ok", multi$chart_valid))
ok("multiple-scenario species chart renders", isTRUE(multi$chart_plot))
ok("separate scenario tables render on one page",
   length(unlist(regmatches(multi$table_result, gregexpr("<table", multi$table_result, fixed = TRUE)))) >= 2)
ok("Stand & Stock offers the selected variant", has_option(multi$ss_controls, "NE"))
ok("Stand & Stock uses the selected projection year", grepl("2024", multi$ss_table))
ok("projected species values use the selected variant", grepl("NE", multi$ss_species))

# ------------------------------------------------------------------------------
cat(sprintf("\n%s\n%d passed, %d failed\n", strrep("-", 60), PASS, FAIL))
if (FAIL > 0) {
  cat("Failures:\n"); cat(paste0("  - ", MSGS, collapse = "\n"), "\n")
  quit(status = 1)
}
