# ------------------------------------------------------------------------------
# Server logic.
# ------------------------------------------------------------------------------

ufvs_server <- function(input, output, session) {

  rv <- reactiveValues(
    page = "data",
    data = NULL, expanded = NULL, issues = NULL, merch_trees = NULL,
    stats = default_stat_settings(),
    products = default_products(),
    volume = default_volume_settings(),
    scenarios = list(Base = list(name = "Base", cycles = 10, cycle_length = 5,
                                 start_year = NA_integer_, events = list(),
                                 raw_keywords = "", computes = list())),
    current = "Base",
    selected_event = NULL,
    engine = load_engine_config(),
    job = NULL, batch_results = list(), run_state = NULL,
    results = list(),
    project = list(name = "Untitled project", owner = "", acres = NA_real_),
    project_file = ufvs_project_path()
  )

  # ---- navigation ------------------------------------------------------------
  nav_ids <- unlist(lapply(UFVS_NAV, function(s) names(s$items)))
  lapply(nav_ids, function(k) {
    observeEvent(input[[paste0("nav_", k)]], {
      rv$page <- k
      session$sendCustomMessage("ufvs-page", k)
    }, ignoreInit = TRUE)
  })
  observe({ session$sendCustomMessage("ufvs-page", rv$page) })

  scenario <- reactive(rv$scenarios[[rv$current]])

  # ---- top bar and status ----------------------------------------------------
  # Only what is actually set, without labeling every field.
  output$topbar_meta <- renderUI({
    bits <- list(tags$b(nz(rv$project$name, "Untitled")))
    if (!is.null(rv$data)) {
      bits <- c(bits, list(
        span(rv$data$source$name),
        span(paste(unique(toupper(nz(rv$data$stands$VARIANT, "?"))), collapse = ", "))))
    }
    bits <- c(bits, list(span(rv$current)))
    tagList(lapply(seq_along(bits), function(i)
      tagList(if (i > 1) span(class = "sep", "\u00b7"), bits[[i]])))
  })

  output$engine_box <- renderUI({
    es <- engine_status(rv$engine)
    cls <- switch(es$level, ready = "dot-ready", error = "dot-error", "dot-none")
    tagList(span(class = paste("dot", cls)), tags$strong(es$label),
            if (nzchar(nz(es$detail, ""))) div(class = "small", style = "margin-top:2px",
                                               basename(nz(es$detail, ""))))
  })

  output$status_engine <- renderText({
    es <- engine_status(rv$engine)
    if (es$ok) paste("Engine:", es$label) else "No engine"
  })
  output$status_data <- renderText({
    if (is.null(rv$data)) "No data" else
      sprintf("%d stands \u00b7 %d trees", nrow(rv$data$stands), nrow(rv$data$trees))
  })

  # ---- page router -----------------------------------------------------------
  output$page_body <- renderUI({
    switch(rv$page,
      project = page_project(), data = page_data(), keywords = page_keywords(),
      event = page_event(), inventory = page_inventory(), summary = page_summary(),
      statistics = page_statistics(rv$stats), management = page_management(),
      volume = page_volume(),
      scenarios = page_scenarios(), runsettings = page_runsettings(),
      standstock = page_standstock(), merch = page_merch(), tables = page_tables(),
      plots = page_plots(), visualize = page_visualize(), compare = page_compare(), output = page_output(),
      log = page_log(), info = page_info(),
      page_data())
  })

  # ============================================================================
  # Data
  # ============================================================================
  persist_dataset <- function(path) {
    if (is.null(path) || !file.exists(path)) return(path)
    d <- file.path(ufvs_user_data_dir(), "datasets")
    dir.create(d, showWarnings = FALSE, recursive = TRUE)
    nm <- gsub("[^A-Za-z0-9._-]+", "_", basename(path))
    dst <- file.path(d, nm)
    same <- tryCatch(identical(normalizePath(path, mustWork = FALSE),
                               normalizePath(dst, mustWork = FALSE)),
                     error = function(e) FALSE)
    if (!same) file.copy(path, dst, overwrite = TRUE)
    if (file.exists(dst)) normalizePath(dst, mustWork = FALSE) else path
  }

  #' Take an imported dataset into the session.
  #'
  #' Structural validation runs first: when the schema is broken uFVS reports
  #' that and does not expand, because expansion assumes those columns exist.
  #' This is what turns a malformed file into a readable message instead of an
  #' R subscript error from inside the expansion code.
  adopt_dataset <- function(out) {
    schema <- validate_schema(out)
    if (schema_blocks(schema)) {
      rv$data <- NULL; rv$expanded <- NULL; rv$issues <- schema; rv$results <- list()
      showNotification(sprintf("That inventory cannot be used: %s",
                               paste(utils::head(schema$message[schema$severity == "error"], 2),
                                     collapse = "; ")),
                       type = "error", duration = 14)
      rv$page <- "data"; session$sendCustomMessage("ufvs-page", "data")
      return(invisible(NULL))
    }
    out$source$path <- persist_dataset(out$source$path)
    rv$data <- out
    rv$expanded <- expand_inventory(out)
    rv$issues <- validate_project(out, rv$expanded)
    rv$merch_trees <- NULL
    rv$results <- list()
    n <- issue_counts(rv$issues)
    showNotification(sprintf("Loaded %d stand(s) and %d tree records. %d error(s), %d warning(s).",
                             nrow(out$stands), nrow(out$trees), n[["error"]], n[["warning"]]),
                     type = if (n[["error"]] > 0) "warning" else "message", duration = 8)
    invisible(out)
  }

  load_dataset <- function(path) {
    out <- try(import_fvs_data(path), silent = TRUE)
    if (inherits(out, "try-error")) {
      showNotification(paste("Could not read that file.", conditionMessage(attr(out, "condition"))),
                       type = "error", duration = 12)
      return(invisible(NULL))
    }
    adopt_dataset(out)
  }

  observeEvent(input$data_file, {
    req(input$data_file)
    up <- input$data_file
    # The CSV route needs several files; Shiny stores each under a random name,
    # so the originals are restored before the importer matches them by table.
    if (nrow(up) > 1) {
      paths <- vapply(seq_len(nrow(up)), function(i) {
        p <- file.path(dirname(up$datapath[i]), up$name[i])
        if (!identical(normalizePath(up$datapath[i], mustWork = FALSE),
                       normalizePath(p, mustWork = FALSE))) {
          if (!file.copy(up$datapath[i], p, overwrite = TRUE)) p <- up$datapath[i]
        }
        p
      }, character(1))
      out <- try(import_fvs_data(paths, names = up$name), silent = TRUE)
      if (inherits(out, "try-error")) {
        showNotification(conditionMessage(attr(out, "condition")), type = "error", duration = 14)
        return()
      }
      adopt_dataset(out)
      return()
    }
    # Shiny stores uploads under a random name, so restore the original
    # extension: the importer recognizes the format from it.
    src <- input$data_file$datapath
    p <- file.path(dirname(src), input$data_file$name)
    if (!identical(normalizePath(src, mustWork = FALSE),
                   normalizePath(p, mustWork = FALSE))) {
      ok <- file.copy(src, p, overwrite = TRUE)
      if (!ok) p <- src
    }
    load_dataset(p)
  })

  output$data_tables <- renderUI({
    if (is.null(rv$data)) return(empty_state("No inventory loaded",
      "Import an FVS input database or workbook."))
    d <- rv$data
    rows <- data.frame(
      Table = c("FVS_StandInit", "FVS_PlotInit", "FVS_TreeInit"),
      Rows = c(nrow(d$stands), if (is.null(d$plots)) 0 else nrow(d$plots), nrow(d$trees)),
      Columns = c(ncol(d$stands), if (is.null(d$plots)) 0 else ncol(d$plots), ncol(d$trees)),
      stringsAsFactors = FALSE)
    tagList(ufvs_table(rows),
            method_note(sprintf("Read from %s (%s) at %s.", d$source$name, d$source$type,
                                format(d$source$imported_at, "%H:%M:%S"))))
  })

  output$data_design <- renderUI({
    if (is.null(rv$expanded)) return(div(class = "muted small", "Load an inventory first."))
    des <- rv$expanded$designs
    tagList(lapply(names(des), function(sid) {
      d <- des[[sid]]
      div(style = "margin-bottom:12px",
        div(style = "font-weight:650", paste("Stand", sid)),
        div(class = "small", d$method),
        tags$dl(class = "kv", style = "margin-top:6px",
          tags$dt("Plots"), tags$dd(sprintf("%s (%s)", fmt_int(d$nplots), d$source$nplots)),
          tags$dt("Non-stocked"), tags$dd(fmt_int(d$nonstk)),
          tags$dt("BAF"), tags$dd(sprintf("%s (%s)", fmt_num(d$baf, 1), d$source$baf)),
          tags$dt("Plot size"), tags$dd(sprintf("1/%s ac (%s)", fmt_num(d$fpa, 0), d$source$fpa)),
          tags$dt("Break DBH"), tags$dd(sprintf("%s in (%s)", fmt_num(d$brk, 1), d$source$brk))))
    }),
    method_note("\"variant default\" means the inventory did not supply the value; FVS applies the same default."))
  })

  output$data_issues <- renderUI(issues_list(rv$issues))
  output$project_issues <- renderUI(issues_list(rv$issues))

  # ============================================================================
  # Project
  # ============================================================================
  output$proj_details <- renderUI({
    tagList(
      textInput("proj_name", "Name", value = nz(rv$project$name, "Untitled project")),
      textInput("proj_owner", "Prepared by", value = nz(rv$project$owner, "")),
      numericInput("proj_acres", "Tract acres (optional)",
                   value = safe_num(nz(rv$project$acres, NA)), min = 0))
  })

  observeEvent(input$proj_name, rv$project$name <- input$proj_name, ignoreInit = TRUE)
  observeEvent(input$proj_owner, rv$project$owner <- input$proj_owner, ignoreInit = TRUE)
  observeEvent(input$proj_acres, {
    rv$project$acres <- input$proj_acres
    rv$stats$tract_acres <- input$proj_acres
  }, ignoreInit = TRUE)

  output$project_dataset <- renderUI({
    if (is.null(rv$data)) return(div(class = "muted small", "No inventory loaded."))
    s <- rv$data$stands
    tagList(tags$dl(class = "kv",
      tags$dt("File"), tags$dd(rv$data$source$name),
      tags$dt("Format"), tags$dd(rv$data$source$type),
      tags$dt("Stands"), tags$dd(nrow(s)),
      tags$dt("Tree records"), tags$dd(nrow(rv$data$trees)),
      tags$dt("Variants"), tags$dd(paste(unique(toupper(nz(s$VARIANT, "?"))), collapse = ", ")),
      tags$dt("Inventory year"), tags$dd(paste(unique(s$INV_YEAR), collapse = ", "))))
  })

  output$proj_save_note <- renderUI({
    p <- nz(rv$project_file, ufvs_project_path())
    if (file.exists(p)) {
      paste("Saved locally at", p)
    } else {
      "Save locally for this computer, or download a JSON copy to share."
    }
  })

  output$proj_recent <- renderUI({
    p <- ufvs_project_path()
    if (!file.exists(p)) return(div(class = "muted small", "No local project saved yet."))
    div(class = "muted small", "Local project available:",
        div(class = "mono", p))
  })

  output$project_repro <- renderUI({
    es <- engine_status(rv$engine)
    tagList(tags$dl(class = "kv",
      tags$dt("uFVS version"), tags$dd(UFVS_VERSION),
      tags$dt("R version"), tags$dd(paste(R.version$major, R.version$minor, sep = ".")),
      tags$dt("Platform"), tags$dd(R.version$platform),
      tags$dt("FVS engine"), tags$dd(paste(rv$engine$mode, "—", es$label)),
      tags$dt("Engine path"), tags$dd(span(class = "mono", nz(rv$engine$path, "—"))),
      tags$dt("Reference tables"), tags$dd(sprintf("%d variants, %d species rows, %d keywords",
        length(known_variants()), nrow(variant_species()), nrow(keyword_defs())))),
      method_note("Each run records its own hashes and engine path in run.json."))
  })

  # ============================================================================
  # Inventory
  # ============================================================================
  output$inv_tiles <- renderUI({
    if (is.null(rv$expanded)) return(NULL)
    ss <- stand_summary(rv$expanded, rv$data)
    div(class = "stat-tiles",
      tile("Stands", fmt_int(nrow(ss))),
      tile("Plots", fmt_int(sum(ss$PLOTS)), "sampling units"),
      tile("Tree records", fmt_int(sum(ss$TREES))),
      tile("Trees / acre", fmt_num(stats::weighted.mean(ss$TPA, nz(ss$PLOTS, 1)), 1)),
      tile("Basal area", fmt_num(stats::weighted.mean(ss$BA, nz(ss$PLOTS, 1)), 1), "ft2/ac"),
      tile("QMD", fmt_num(stats::weighted.mean(ss$QMD, nz(ss$PLOTS, 1)), 1), "in"))
  })

  output$inv_species <- renderUI({
    if (is.null(rv$expanded)) return(div(class = "muted small", "Load an inventory first."))
    sp <- species_summary(rv$expanded, rv$data)
    if (!nrow(sp)) return(div(class = "muted small", "No live trees."))
    sp <- sp[, c("SPECIES", "TREES", "TPA", "BA", "QMD", "BA_PCT")]
    names(sp) <- c("Species", "Trees", "TPA", "BA/ac", "QMD", "% BA")
    ufvs_table(sp, digits = list(TPA = 1, `BA/ac` = 1, QMD = 1, `% BA` = 1))
  })

  output$inv_dbh_plot <- renderPlot({
    req(rv$expanded)
    by_sp <- isTRUE(input$dbh_by_species)
    separate <- isTRUE(input$dbh_separate)
    d <- dbh_class_summary(rv$expanded, rv$data, class_width = 2, by_species = by_sp)
    if (!nrow(d)) return(NULL)

    if (!by_sp) {
      p <- ggplot2::ggplot(d, ggplot2::aes(x = DBH_CLASS, y = TPA)) +
        ggplot2::geom_col(fill = UFVS_PALETTE[1], width = 1.7)
    } else {
      # Order species by total trees so the legend reads largest-first.
      tot <- tapply(d$TPA, d$SPECIES, sum)
      d$SPECIES <- factor(d$SPECIES, levels = names(sort(tot, decreasing = TRUE)))
      p <- ggplot2::ggplot(d, ggplot2::aes(x = DBH_CLASS, y = TPA, fill = SPECIES)) +
        ggplot2::geom_col(width = 1.7, position = "identity", alpha = 0.62) +
        ggplot2::scale_fill_manual(values = rep(UFVS_PALETTE, 9), name = "Species code")
      if (separate) {
        p <- p + ggplot2::facet_wrap(~ SPECIES, scales = "free_y") +
          ggplot2::guides(fill = "none")
      }
    }
    p + ggplot2::labs(x = "DBH class (in)", y = "Trees per acre") + ufvs_axis_theme()
  })

  output$inv_plots <- renderUI({
    if (is.null(rv$expanded)) return(div(class = "muted small", "Load an inventory first."))
    pt <- plot_table(rv$expanded, rv$data)
    names(pt) <- c("Stand", "Plot", "Trees", "TPA", "BA/ac", "QMD")
    ufvs_table(utils::head(pt, 200), digits = list(TPA = 1, `BA/ac` = 1, QMD = 1))
  })

  output$inv_trees <- renderUI({
    if (is.null(rv$expanded)) return(div(class = "muted small", "Load an inventory first."))
    tr <- rv$expanded$trees
    keep <- intersect(c("STAND_ID", "PLOT_ID", "TREE_ID", "SPECIES", "DIAMETER", "HT",
                        "TPA_PLOT", "TPA_STAND", "BA_TREE"), names(tr))
    d <- tr[, keep, drop = FALSE]
    names(d) <- c("Stand", "Plot", "Tree", "Species", "DBH", "Height",
                  "TPA (own plot)", "TPA (stand)", "BA/tree")[seq_along(keep)]
    tagList(ufvs_table(utils::head(d, 200), digits = list(DBH = 1, Height = 0,
              `TPA (own plot)` = 2, `TPA (stand)` = 3, `BA/tree` = 3)),
      if (nrow(tr) > 200) div(class = "muted small", sprintf("Showing 200 of %d records.", nrow(tr))),
      method_note("TPA (own plot) is the sampling observation; TPA (stand) divides it by the point count."))
  })

  output$summary_body <- renderUI({
    if (is.null(rv$expanded)) return(empty_state("No inventory", "Import data first."))
    ss <- stand_summary(rv$expanded, rv$data)
    show <- ss[, c("STAND_ID", "VARIANT", "INV_YEAR", "PLOTS", "TREES", "TPA", "BA", "QMD", "SDI", "MEAN_HT")]
    names(show) <- c("Stand", "Variant", "Year", "Plots", "Trees", "TPA", "BA/ac", "QMD", "SDI", "Mean ht")
    tagList(
      card("Stands", ufvs_table(show, digits = list(TPA = 1, `BA/ac` = 1, QMD = 1, SDI = 0, `Mean ht` = 0))),
      uiOutput("summary_stats"),
      card("Diameter classes",
        div(class = "inline-checks",
          checkboxInput("sum_dbh_by_species", "Break out by species", FALSE)),
        uiOutput("summary_dbh")))
  })

  all_species <- reactive({
    if (is.null(rv$expanded)) return(character(0))
    tr <- rv$expanded$trees[rv$expanded$trees$IS_LIVE %in% TRUE, , drop = FALSE]
    sp <- sort(unique(tr$SPECIES))
    sp[!is.na(sp)]
  })

  output$summary_species_picker <- renderUI({
    sp <- all_species()
    if (!length(sp)) return(div(class = "muted small", "Import an inventory first."))
    lbl <- species_choices()
    named <- stats::setNames(sp, vapply(sp, function(x) nz(names(lbl)[match(x, lbl)], x), character(1)))
    tagList(
      div(class = "bar-row",
        div(style = "flex:1;min-width:260px",
          selectInput("sum_species", "Species (optional; blank = all)", choices = named,
                      multiple = TRUE, selected = NULL)),
        div(class = "inline-checks",
          checkboxInput("sum_split", "Separate selected species", FALSE))),
      div(class = "muted small",
          "Statistics are computed over all plots, so a species absent from a plot counts as zero there."))
  })

  #' Per-plot values restricted to the chosen species.
  species_stat_block <- function(vars = c("TPA", "BA")) {
    if (is.null(rv$expanded)) return(div(class = "muted small", "Import an inventory first."))
    pt <- plot_table(rv$expanded, rv$data)
    if (!nrow(pt)) return(div(class = "muted small", "No sampling units."))
    tr <- rv$expanded$trees[rv$expanded$trees$IS_LIVE %in% TRUE, , drop = FALSE]
    sel <- input$sum_species
    if (!is.null(sel) && length(sel)) tr <- tr[tr$SPECIES %in% sel, , drop = FALSE]
    if (!nrow(tr)) return(div(class = "muted small", "No trees in that selection."))

    col_for <- c(TPA = "TPA_PLOT", BA = "BA_PLOT")
    labels <- c(TPA = "Trees per acre", BA = "Basal area (ft2/ac)")

    blocks <- lapply(vars, function(v) {
      vcol <- col_for[[v]]
      if (isTRUE(input$sum_split)) {
        g <- plot_group_values(tr, pt, vcol, "SPECIES")
        n_obs <- vapply(names(g), function(sp) sum(tr$SPECIES == sp), numeric(1))
        # A combined row so the parts can be read against the whole.
        g[["All selected"]] <- Reduce(`+`, g)
        n_obs[["All selected"]] <- nrow(tr)
        tbl <- stat_table(g, rv$stats, n_obs = n_obs, label_col = "Species")
      } else {
        g <- plot_group_values(tr, pt, vcol, NULL)
        names(g) <- if (is.null(sel) || !length(sel)) "All species" else paste(sel, collapse = ", ")
        tbl <- stat_table(g, rv$stats, n_obs = stats::setNames(nrow(tr), names(g)),
                          label_col = "Selection")
      }
      card(labels[[v]], ufvs_table(tbl))
    })
    tagList(blocks,
      method_note(sprintf("n = %d plots \u00b7 %d tree records \u00b7 confidence %s%%",
                          nrow(pt), nrow(tr), fmt_num(rv$stats$confidence_level, 1))))
  }

  output$summary_stats <- renderUI(species_stat_block(c("TPA", "BA")))
  output$summary_dbh <- renderUI({
    req(rv$expanded)
    by_sp <- isTRUE(input$sum_dbh_by_species)
    d <- dbh_class_summary(rv$expanded, rv$data, class_width = 2, by_species = by_sp)
    if (!nrow(d)) return(div(class = "muted small", "No live trees."))

    if (by_sp) {
      # One column per species keeps a diameter distribution readable; a long
      # class-by-species list does not.
      wide <- reshape(d[, c("DBH_CLASS", "SPECIES", "TPA")],
                      idvar = "DBH_CLASS", timevar = "SPECIES", direction = "wide")
      names(wide) <- sub("^TPA\\.", "", names(wide))
      wide[is.na(wide)] <- 0
      wide <- wide[order(wide$DBH_CLASS), , drop = FALSE]
      sp_cols <- setdiff(names(wide), "DBH_CLASS")
      wide$Total <- rowSums(wide[, sp_cols, drop = FALSE])

      # The class label has to be text while every other column stays numeric.
      # Writing "Total" across a whole row coerces the numbers to strings, and
      # the table formatter then prints them at full precision.
      out <- data.frame(`DBH class` = c(sprintf("%.1f", wide$DBH_CLASS), "Total"),
                        check.names = FALSE, stringsAsFactors = FALSE)
      for (cc in c(sp_cols, "Total")) {
        out[[cc]] <- c(wide[[cc]], sum(wide[[cc]]))
      }
      dg <- stats::setNames(rep(list(1), length(c(sp_cols, "Total"))), c(sp_cols, "Total"))
      return(tagList(
        ufvs_table(out, digits = dg, total_row = nrow(out)),
        method_note("Trees per acre by species within each 2-inch class.")))
    }

    d <- d[, c("DBH_CLASS", "TREES", "TPA", "BA", "MEAN_HT")]
    names(d) <- c("DBH class", "Trees", "TPA", "BA/ac", "Mean ht")
    tot <- data.frame(`DBH class` = "Total", Trees = sum(d$Trees), TPA = sum(d$TPA),
                      `BA/ac` = sum(d$`BA/ac`), `Mean ht` = NA_real_, check.names = FALSE)
    all <- rbind(d, tot)
    ufvs_table(all, digits = list(TPA = 1, `BA/ac` = 1, `Mean ht` = 0),
               total_row = nrow(all))
  })

  # ============================================================================
  # Statistics
  # ============================================================================
  # Applying a preset writes to three separate checkbox groups, and their
  # updates arrive one at a time. Each intermediate state matches no preset, so
  # without a guard the checkbox observer would flip the selector to Custom
  # mid-flight and retrigger the preset observer — the selector appears to cycle
  # through presets on a single click. `applying` holds the target set until the
  # boxes have finished settling on it.
  applying <- reactiveVal(NULL)

  observeEvent(input$stat_preset, {
    p <- input$stat_preset
    if (identical(p, "custom") || is.null(STAT_PRESETS[[p]])) return()
    target <- STAT_PRESETS[[p]]$stats
    applying(target)
    rv$stats$preset <- p
    rv$stats$stats <- stat_order(target)
    for (g in c("precision", "descriptive", "detail")) {
      ids <- vapply(Filter(function(d) d$group == g, STAT_DEFS), function(d) d$id, character(1))
      # Shiny otherwise reports the three checkbox groups one at a time. Freeze
      # each input for this update so the custom-preset observer cannot see a
      # transient partial selection and change the preset mid-click.
      freezeReactiveValue(input, paste0("stat_", g))
      updateCheckboxGroupInput(session, paste0("stat_", g),
                               selected = intersect(ids, target))
    }
  }, ignoreInit = TRUE)

  observe({
    sel <- c(input$stat_precision, input$stat_descriptive, input$stat_detail)
    if (is.null(input$stat_precision) && is.null(input$stat_descriptive) &&
        is.null(input$stat_detail)) return()
    sel <- stat_order(sel)

    target <- applying()
    if (!is.null(target)) {
      # Mid-apply: swallow every intermediate state, and stop swallowing once
      # the boxes agree with what the preset asked for.
      if (setequal(sel, target)) applying(NULL)
      return()
    }

    if (!identical(sel, rv$stats$stats)) {
      rv$stats$stats <- sel
      known <- vapply(STAT_PRESETS, function(p) setequal(p$stats, sel), logical(1))
      rv$stats$preset <- if (any(known)) names(STAT_PRESETS)[which(known)[1]] else "custom"
      if (!identical(input$stat_preset, rv$stats$preset)) {
        updateSelectInput(session, "stat_preset", selected = rv$stats$preset)
      }
    }
  })

  observeEvent(input$stat_conf, {
    v <- input$stat_conf
    if (!is.null(v) && !is.na(v) && v > 0 && v < 100) rv$stats$confidence_level <- v
  }, ignoreInit = TRUE)
  observeEvent(input$stat_fpc, rv$stats$fpc <- isTRUE(input$stat_fpc), ignoreInit = TRUE)
  observeEvent(input$stat_pop, rv$stats$population_plots <- input$stat_pop, ignoreInit = TRUE)

  #' Statistics for the standard inventory variables, as a table.
  stat_block <- function(vars = c("TPA", "BA")) {
    if (is.null(rv$expanded)) return(div(class = "muted small", "Load an inventory to see statistics."))
    pt <- plot_table(rv$expanded, rv$data)
    if (!nrow(pt)) return(div(class = "muted small", "No sampling units."))
    groups <- list()
    labels <- c(TPA = "Trees per acre", BA = "Basal area (ft2/ac)", QMD = "QMD (in)")
    for (v in vars) if (v %in% names(pt)) groups[[nz(labels[[v]], v)]] <- pt[[v]]
    n_obs <- stats::setNames(rep(sum(pt$TREES), length(groups)), names(groups))
    tbl <- stat_table(groups, rv$stats, n_obs = n_obs, label_col = "Variable")
    tagList(ufvs_table(tbl),
      method_note(sprintf("n = %d plots. Confidence %s%%.", nrow(pt),
                          fmt_num(rv$stats$confidence_level, 1)),
        if (isTRUE(rv$stats$fpc)) " FPC applied."))
  }

  output$stat_preview <- renderUI(stat_block(c("TPA", "BA", "QMD")))

  output$plots_required <- renderUI({
    req(rv$expanded, input$plots_enable)
    pt <- plot_table(rv$expanded, rv$data)
    v <- nz(input$plots_var, "BA")
    if (!v %in% names(pt) || nrow(pt) < 2) return(div(class = "muted small", "Not enough plots."))
    st <- sampling_stats(pt[[v]], rv$stats$confidence_level)
    target <- nz(input$plots_target, 7.5)
    rq <- required_plots(st$cv, target, rv$stats$confidence_level,
                         population_plots = if (isTRUE(rv$stats$fpc)) rv$stats$population_plots else NA_real_,
                         pilot_n = nrow(pt))
    tagList(
      tags$dl(class = "kv", style = "margin-top:10px",
        tags$dt("Pilot plots"), tags$dd(fmt_int(nrow(pt))),
        tags$dt("Observed CV"), tags$dd(paste0(fmt_num(st$cv, 1), "%")),
        tags$dt("Current sampling error"), tags$dd(paste0(fmt_num(st$se_pct, 1), "%")),
        tags$dt("Target sampling error"), tags$dd(paste0(fmt_num(target, 1), "%")),
        tags$dt("Plots required"), tags$dd(strong(fmt_int(rq$n))),
        tags$dt("Additional needed"), tags$dd(strong(fmt_int(rq$additional)))),
      method_note("n = t\u00b2 CV\u00b2 / E\u00b2, iterated. Assumes new plots behave like the pilot plots."))
  })

  # ============================================================================
  # Management
  # ============================================================================
  output$mg_scenario_bar <- renderUI({
    div(class = "card card-tight",
      div(class = "bar-row",
        div(style = "min-width:190px",
          selectInput("mg_scenario", "Scenario", choices = names(rv$scenarios), selected = rv$current)),
        div(style = "width:125px",
          numericInput("mg_start_year", "Timeline start year", value = start_year(), step = 1)),
        div(style = "width:150px",
          numericInput("mg_stand_age", "Stand age", value = stand_age_override(),
                       min = 0, step = 1),
          div(class = "field-hint",
              if (stand_age_is_override()) "your entry"
              else if (!is.na(stand_age_override())) "from the inventory"
              else "not set \u2014 MAI will be 0")),
        div(style = "width:90px",
          numericInput("mg_cycles", "Cycles", value = nz(scenario()$cycles, 10), min = 1, max = 40)),
        div(style = "width:110px",
          numericInput("mg_cyclelen", "Cycle (yrs)", value = nz(scenario()$cycle_length, 5), min = 1, max = 20)),
        div(class = "muted small",
            sprintf("%d activities \u00b7 through %d",
                    length(scenario()$events), max(timeline_years())))))
  })

  observeEvent(input$mg_cycles, {
    if (!is.null(input$mg_cycles) && !is.na(input$mg_cycles))
      rv$scenarios[[rv$current]]$cycles <- input$mg_cycles
  }, ignoreInit = TRUE)
  observeEvent(input$mg_cyclelen, {
    if (!is.null(input$mg_cyclelen) && !is.na(input$mg_cyclelen))
      rv$scenarios[[rv$current]]$cycle_length <- input$mg_cyclelen
  }, ignoreInit = TRUE)
  observeEvent(input$mg_scenario, {
    if (!is.null(input$mg_scenario) && input$mg_scenario %in% names(rv$scenarios))
      rv$current <- input$mg_scenario
  }, ignoreInit = TRUE)

  #' The year the timeline starts from. Defaults to the inventory year but the
  #' user can set any year, which is what a plan written years after the cruise
  #' needs.
  default_start_year <- reactive({
    if (is.null(rv$data)) return(as.integer(format(Sys.Date(), "%Y")))
    y <- suppressWarnings(min(safe_num(rv$data$stands$INV_YEAR), na.rm = TRUE))
    if (!is.finite(y)) as.integer(format(Sys.Date(), "%Y")) else as.integer(y)
  })

  start_year <- reactive({
    y <- nz(scenario()$start_year, NA)
    if (is.na(y)) default_start_year() else as.integer(y)
  })

  timeline_years <- reactive({
    sc <- scenario()
    start_year() + seq(0, nz(sc$cycles, 10) * nz(sc$cycle_length, 5),
                       by = nz(sc$cycle_length, 5))
  })

  #' Stand age the run should use. FVS needs a non-zero age or it switches its
  #' MAI calculation off (vbase/evtstv.f), and many inventories arrive with AGE
  #' empty. Blank here means "use whatever the inventory says".
  stand_age_override <- reactive({
    v <- rv$project$stand_age
    if (!is.null(v) && !is.na(v)) return(as.integer(v))
    if (is.null(rv$data) || !"AGE" %in% names(rv$data$stands)) return(NA_integer_)
    a <- suppressWarnings(min(safe_num(rv$data$stands$AGE), na.rm = TRUE))
    if (!is.finite(a)) NA_integer_ else as.integer(a)
  })

  observeEvent(input$mg_stand_age, {
    v <- suppressWarnings(as.integer(input$mg_stand_age))
    rv$project$stand_age <- if (length(v) != 1 || is.na(v) || v < 0) NA_integer_ else v
  }, ignoreInit = TRUE)

  #' Did the user type an age, as opposed to the box simply echoing the sheet?
  stand_age_is_override <- reactive({
    v <- rv$project$stand_age
    !is.null(v) && !is.na(v) && v > 0
  })

  #' The inventory as handed to FVS. The user's own file is never modified.
  #'
  #' The age is only written when the user actually supplied one. Writing the
  #' echoed value back would overwrite a per-stand AGE column with a single
  #' number, which would be wrong for any project with more than one stand.
  run_data <- reactive({
    d <- rv$data
    if (!is.null(d) && stand_age_is_override()) {
      d$stands$AGE <- as.integer(rv$project$stand_age)
    }
    d
  })

  observeEvent(input$mg_start_year, {
    v <- suppressWarnings(as.integer(input$mg_start_year))
    if (length(v) && is.finite(v))
      rv$scenarios[[rv$current]]$start_year <- v
  }, ignoreInit = TRUE)

  output$mg_timeline <- renderUI({
    yrs <- timeline_years()
    ev <- scenario()$events
    sel <- rv$selected_event
    div(class = "timeline",
      lapply(seq_along(yrs), function(i) {
        y <- yrs[i]
        here <- Filter(function(e) !is.na(safe_num(e$year)) &&
                         abs(safe_num(e$year) - y) < nz(scenario()$cycle_length, 5) / 2, ev)
        idx <- if (length(here)) which(vapply(ev, function(e) identical(e$uid, here[[1]]$uid), logical(1)))[1] else NA
        div(class = paste("tl-cell", if (!is.na(idx) && identical(idx, sel)) "sel" else ""),
            `data-timeline-year` = as.character(y),
            onclick = if (!is.na(idx)) sprintf("Shiny.setInputValue('mg_pick', %d, {priority:'event'})", idx) else NULL,
            div(class = "tl-year", y),
            if (length(here)) {
              tagList(div(class = "tl-kw", here[[1]]$keyword),
                      div(class = "tl-desc",
                          if (length(here) > 1) sprintf("+%d more", length(here) - 1) else ""))
            } else div(class = "tl-empty", "—"))
      }))
  })

  output$mg_activity_board <- renderUI({
    ev <- scenario()$events
    if (!length(ev)) {
      return(div(class = "mg-activity-empty",
                 strong("No treatments scheduled"),
                 div("Use Add or choose a treatment in the Treatments page.")))
    }

    div(class = "mg-activity-board",
      lapply(seq_along(ev), function(i) {
        e <- ev[[i]]
        d <- keyword_def(e$keyword)
        desc <- if (is.null(d)) "Custom or unrecognized FVS keyword." else
          nz(d$description, "No description available.")
        y <- safe_num(e$year)[1]
        year_label <- if (length(y) && is.finite(y)) paste("Year", fmt_int(y)) else "Unscheduled"
        div(class = paste("mg-treatment-card",
                          if (!is.null(rv$selected_event) && identical(i, rv$selected_event)) "sel" else ""),
            draggable = "true",
            `data-event-index` = as.character(i),
            onclick = sprintf("Shiny.setInputValue('mg_pick', %d, {priority:'event'})", i),
            div(class = "mg-treatment-card-head",
                span(class = "mg-drag-handle", "⋮⋮"),
                strong(e$keyword),
                span(class = "mg-treatment-year", year_label)),
            div(class = "mg-treatment-card-desc", desc),
            div(class = "mg-treatment-card-foot",
                span(class = "muted small", paste("Treatment", i)),
                span(class = "muted small", "Click to edit")))
      }))
  })

  observeEvent(input$mg_pick, rv$selected_event <- input$mg_pick, ignoreInit = TRUE)

  decode_drag_payload <- function(x) {
    if (is.null(x)) return(NULL)
    if (is.character(x) && length(x) == 1L) {
      parsed <- tryCatch(jsonlite::fromJSON(x, simplifyVector = TRUE),
                         error = function(e) NULL)
      if (!is.null(parsed)) return(parsed)
    }
    x
  }

  observeEvent(input$mg_drop_year, {
    p <- decode_drag_payload(input$mg_drop_year)
    if (!is.list(p)) return()
    i <- suppressWarnings(as.integer(p$index))[1]
    y <- suppressWarnings(as.integer(p$year))[1]
    sc <- rv$scenarios[[rv$current]]
    if (!length(i) || is.na(i) || i < 1L || i > length(sc$events) ||
        !length(y) || is.na(y)) return()
    sc$events[[i]]$year <- y
    rv$scenarios[[rv$current]] <- sc
    rv$selected_event <- i
  }, ignoreInit = TRUE)

  observeEvent(input$mg_reorder, {
    p <- decode_drag_payload(input$mg_reorder)
    if (!is.list(p)) return()
    ord <- suppressWarnings(as.integer(unlist(p$order, use.names = FALSE)))
    sc <- rv$scenarios[[rv$current]]
    n <- length(sc$events)
    if (!n || length(ord) != n || anyNA(ord) || !all(sort(ord) == seq_len(n))) return()

    old_i <- suppressWarnings(as.integer(rv$selected_event))[1]
    old_uid <- if (length(old_i) && !is.na(old_i) && old_i >= 1L && old_i <= n)
      sc$events[[old_i]]$uid %||% NULL else NULL
    sc$events <- sc$events[ord]
    rv$scenarios[[rv$current]] <- sc

    if (!is.null(old_uid) && length(old_uid)) {
      hit <- which(vapply(sc$events, function(e)
        identical(as.character(e$uid %||% ""), as.character(old_uid)), logical(1)))
      rv$selected_event <- if (length(hit)) hit[1] else NULL
    } else if (length(old_i) && !is.na(old_i)) {
      rv$selected_event <- match(old_i, ord)
    }
  }, ignoreInit = TRUE)

  observeEvent(input$mg_add, {
    sc <- rv$scenarios[[rv$current]]
    yrs <- timeline_years()
    new <- list(uid = paste0("e", as.integer(runif(1, 1e6, 9e6))),
                keyword = "ThinBBA", year = yrs[min(2, length(yrs))],
                values = keyword_defaults("ThinBBA"))
    sc$events <- c(sc$events, list(new))
    rv$scenarios[[rv$current]] <- sc
    rv$selected_event <- length(sc$events)
  })

  observeEvent(input$mg_delete, {
    sc <- rv$scenarios[[rv$current]]
    i <- rv$selected_event
    if (!is.null(i) && !is.na(i) && i >= 1 && i <= length(sc$events)) {
      sc$events <- sc$events[-i]
      rv$scenarios[[rv$current]] <- sc
      rv$selected_event <- NULL
    }
  })

  output$mg_editor <- renderUI({
    sc <- scenario()
    i <- rv$selected_event
    if (is.null(i) || is.na(i) || i > length(sc$events)) {
      return(empty_state("No activity selected", "Add one, or pick it on the timeline."))
    }
    ev <- sc$events[[i]]
    tk <- treatment_keywords()
    fields <- keyword_fields(ev$keyword)
    def <- keyword_def(ev$keyword)

    # Field 1 is the schedule on every treatment keyword; it gets its own control.
    body <- lapply(seq_len(nrow(fields)), function(r) {
      f <- fields[r, ]
      if (f$field == 1 && f$widget == "scheduleBox") return(NULL)
      id <- paste0("evf_", f$field)
      cur <- nz(ev$values[[as.character(f$field)]], f$default)
      lbl <- if (nzchar(nz(f$label, ""))) f$label else paste("Field", f$field)
      ctl <- switch(f$widget,
        numberBox = numericInput(id, lbl, value = suppressWarnings(as.numeric(cur))),
        intNumberBox = numericInput(id, lbl, value = suppressWarnings(as.numeric(cur)), step = 1),
        sliderBox = numericInput(id, lbl, value = suppressWarnings(as.numeric(cur)),
                                 min = f$min, max = f$max),
        intSliderBox = numericInput(id, lbl, value = suppressWarnings(as.numeric(cur)),
                                    min = f$min, max = f$max, step = 1),
        listButton = selectInput(id, lbl, choices = strsplit(nz(f$options, ""), "\\|")[[1]],
                                 selected = cur),
        longListButton = selectInput(id, lbl, choices = strsplit(nz(f$options, ""), "\\|")[[1]],
                                     selected = cur),
        speciesSelection = selectInput(id, lbl,
          choices = c("All species" = "", species_choices()), selected = cur),
        textEdit = textInput(id, lbl, value = as.character(cur)),
        longTextEdit = textAreaInput(id, lbl, value = as.character(cur), rows = 3),
        noInput = div(class = "muted small", lbl),
        textInput(id, lbl, value = as.character(cur)))
      list(field = f$field, ctl = ctl, advanced = f$field > 3)
    })
    body <- Filter(Negate(is.null), body)
    basic <- Filter(function(x) !x$advanced, body)
    adv <- Filter(function(x) x$advanced, body)

    tagList(
      selectInput("ev_keyword", "FVS keyword",
        choices = stats::setNames(tk$keyword, paste0(tk$keyword, " — ", substr(tk$description, 1, 60))),
        selected = ev$keyword),
      div(class = "muted small", style = "margin:-4px 0 10px", nz(def$description, "")),
      numericInput("ev_year", "Year", value = safe_num(ev$year), step = 1),
      lapply(basic, function(x) x$ctl),
      if (length(adv))
        tags$details(tags$summary(class = "muted small",
                                  sprintf("Advanced (%d more field%s)", length(adv),
                                          if (length(adv) == 1) "" else "s")),
                     div(style = "padding-top:9px", lapply(adv, function(x) x$ctl))))
  })

  species_choices <- function() {
    if (is.null(rv$data)) return(character(0))
    v <- tolower(nz(rv$data$stands$VARIANT[1], ""))
    sp <- species_for_variant(v)
    if (!nrow(sp)) return(character(0))
    stats::setNames(sp$species_code, paste0(sp$species_code, " — ", nz(sp$common_name, "")))
  }

  observeEvent(input$ev_keyword, {
    i <- rv$selected_event; req(i)
    sc <- rv$scenarios[[rv$current]]
    if (i > length(sc$events)) return()
    if (!identical(sc$events[[i]]$keyword, input$ev_keyword)) {
      sc$events[[i]]$keyword <- input$ev_keyword
      sc$events[[i]]$values <- keyword_defaults(input$ev_keyword)
      rv$scenarios[[rv$current]] <- sc
    }
  }, ignoreInit = TRUE)

  observeEvent(input$ev_year, {
    i <- rv$selected_event; req(i)
    sc <- rv$scenarios[[rv$current]]
    if (i <= length(sc$events)) {
      sc$events[[i]]$year <- input$ev_year
      rv$scenarios[[rv$current]] <- sc
    }
  }, ignoreInit = TRUE)

  observe({
    i <- rv$selected_event; req(i)
    sc <- rv$scenarios[[rv$current]]
    if (i > length(sc$events)) return()
    fields <- keyword_fields(sc$events[[i]]$keyword)
    changed <- FALSE
    for (r in seq_len(nrow(fields))) {
      fnum <- fields$field[r]
      id <- paste0("evf_", fnum)
      val <- input[[id]]
      if (is.null(val)) next
      if (!identical(as.character(nz(sc$events[[i]]$values[[as.character(fnum)]], "")), as.character(val))) {
        sc$events[[i]]$values[[as.character(fnum)]] <- val
        changed <- TRUE
      }
    }
    if (changed) rv$scenarios[[rv$current]] <- sc
  })

  observeEvent(input$mg_raw, {
    rv$scenarios[[rv$current]]$raw_keywords <- input$mg_raw
  }, ignoreInit = TRUE)

  output$mg_keyword_preview <- renderUI({
    sc <- scenario()
    i <- rv$selected_event
    txt <- if (!is.null(i) && !is.na(i) && i <= length(sc$events)) {
      ev <- sc$events[[i]]
      vals <- ev$values; vals[["1"]] <- ev$year
      render_keyword(ev$keyword, vals)
    } else {
      paste(render_events(sc$events), collapse = "\n")
    }
    if (!nzchar(nz(txt, ""))) txt <- "(no activities scheduled)"
    div(class = "kw-preview", txt)
  })

  # ============================================================================
  # Treatments library
  # ============================================================================
  tl_filtered <- reactive({
    tk <- treatment_keywords()
    s <- nz(input$tl_search, "")
    if (nzchar(s)) {
      tk <- tk[grepl(s, tk$keyword, ignore.case = TRUE) |
               grepl(s, tk$description, ignore.case = TRUE), , drop = FALSE]
    }
    tk
  })

  output$tl_count <- renderUI({
    tk <- tl_filtered()
    all <- treatment_keywords()
    HTML(sprintf("%d of %d scheduled keywords. uFVS knows %d keywords in total across %d extensions.",
                 nrow(tk), nrow(all), nrow(keyword_defs()), length(unique(keyword_defs()$extension))))
  })

  output$tl_list <- renderUI({
    tk <- tl_filtered()
    if (!nrow(tk)) return(div(class = "muted small", style = "padding:12px", "Nothing matches."))
    sel <- isolate(nz(input$tl_pick, ""))
    item <- function(i, d = tk) {
      r <- d[i, ]
      div(class = paste("kw-item", if (identical(sel, r$keyword)) "sel" else ""),
          onclick = sprintf("Shiny.setInputValue('tl_pick', '%s', {priority:'event'})", r$keyword),
          div(class = "kw-item-row",
            div(span(class = "name", r$keyword), span(class = "ext", r$extension)),
            tags$button(class = "kw-add", title = "Add to the plan",
                        onclick = sprintf(
                          "event.stopPropagation();Shiny.setInputValue('tl_add_kw', {kw:'%s', nonce:Date.now()}, {priority:'event'})",
                          r$keyword), "+")),
          div(class = "desc", r$description))
    }
    # The unfiltered library is easier to scan as collapsible category groups;
    # search results stay as a compact flat list.
    if (!nzchar(nz(input$tl_search, ""))) {
      groups <- split(tk, tk$category)
      return(div(class = "treatment-groups",
        lapply(names(groups), function(cat) {
          d <- groups[[cat]]
          tags$details(
            tags$summary(sprintf("%s (%d)", cat, nrow(d))),
            lapply(seq_len(nrow(d)), function(i) item(i, d)))
        })))
    }
    lapply(seq_len(nrow(tk)), item)
  })

  output$tl_detail <- renderUI({
    kw <- nz(input$tl_pick, "")
    if (!nzchar(kw)) return(div(class = "muted small", "Select a keyword."))
    d <- keyword_def(kw); f <- keyword_fields(kw)
    if (is.null(d)) return(div(class = "muted small", "Unknown keyword."))
    ft <- if (nrow(f)) {
      x <- f[, c("field", "widget", "label", "default")]
      names(x) <- c("#", "Input", "Meaning", "Default")
      ufvs_table(x)
    } else div(class = "muted small", "No fields.")
    tagList(
      h3(kw, span(class = "sub", d$extension)),
      p(d$description),
      h3("Fields"), ft,
      h3("Record written"),
      div(class = "kw-preview", render_keyword(kw, keyword_defaults(kw))),
      actionButton("tl_add_to_plan", "Add to management plan", class = "btn-default"),
      method_note("Fields from the official fvsOL definitions. See the FVS Keyword Reference Guide."))
  })

  #' Schedule a treatment in the active scenario.
  add_treatment <- function(kw) {
    if (!nzchar(nz(kw, ""))) return(invisible(NULL))
    sc <- rv$scenarios[[rv$current]]
    yrs <- timeline_years()
    sc$events <- c(sc$events, list(list(
      uid = paste0("e", as.integer(stats::runif(1, 1e6, 9e6))),
      keyword = kw, year = yrs[min(2, length(yrs))], values = keyword_defaults(kw))))
    rv$scenarios[[rv$current]] <- sc
    rv$selected_event <- length(sc$events)
    rv$tl_pick_shown <- kw
    showNotification(sprintf("Added %s at %s. Drag it to another year if needed.",
                             kw, yrs[min(2, length(yrs))]), duration = 4)
    invisible(TRUE)
  }

  observeEvent(input$tl_add_kw, {
    add_treatment(nz(input$tl_add_kw$kw, ""))
  }, ignoreInit = TRUE)

  observeEvent(input$tl_add_to_plan, add_treatment(nz(input$tl_pick, "")))

  # ============================================================================
  # Volume keywords
  # ============================================================================
  output$vol_picker <- renderUI({
    vk <- volume_control_keywords()
    selectInput("vol_keyword", "Add keyword",
      choices = stats::setNames(vk$keyword,
                                paste0(vk$keyword, " — ", substr(vk$description, 1, 55))),
      selected = input$vol_keyword)
  })
  observeEvent(input$vol_defaults, rv$volume$use_defaults <- isTRUE(input$vol_defaults), ignoreInit = TRUE)
  observeEvent(input$vol_add, {
    kw <- input$vol_keyword; req(kw)
    rv$volume$keywords <- c(rv$volume$keywords,
                            list(list(keyword = kw, values = keyword_defaults(kw))))
  })

  output$vol_forms <- renderUI({
    if (isTRUE(rv$volume$use_defaults) || !length(rv$volume$keywords))
      return(div(class = "muted small",
                 "No volume keywords set. FVS will apply the variant defaults for merchantability."))
    tagList(lapply(seq_along(rv$volume$keywords), function(i) {
      k <- rv$volume$keywords[[i]]
      d <- keyword_def(k$keyword)
      f <- keyword_fields(k$keyword)
      div(class = "vol-keyword",
        div(class = "bar-row", style = "justify-content:space-between",
          h3(k$keyword, class = "vol-kw-name"),
          actionButton(paste0("vol_rm_", i), "Remove", class = "btn-default")),
        div(class = "muted small", nz(d$description, "")),
        # Editable fields, so the record written is the record the user set.
        # Without these the page could add a keyword but never change it.
        if (nrow(f)) div(class = "form-grid",
          lapply(seq_len(nrow(f)), function(r) {
            fd <- f[r, ]
            id <- sprintf("volf_%d_%d", i, fd$field)
            cur <- nz(k$values[[as.character(fd$field)]], fd$default)
            lbl <- if (nzchar(nz(fd$label, ""))) fd$label else paste("Field", fd$field)
            switch(fd$widget,
              numberBox = numericInput(id, lbl, value = suppressWarnings(as.numeric(cur))),
              intNumberBox = numericInput(id, lbl, value = suppressWarnings(as.numeric(cur)), step = 1),
              sliderBox = numericInput(id, lbl, value = suppressWarnings(as.numeric(cur)),
                                       min = fd$min, max = fd$max),
              intSliderBox = numericInput(id, lbl, value = suppressWarnings(as.numeric(cur)),
                                          min = fd$min, max = fd$max, step = 1),
              listButton = selectInput(id, lbl, choices = strsplit(nz(fd$options, ""), "\\|")[[1]],
                                       selected = cur),
              longListButton = selectInput(id, lbl, choices = strsplit(nz(fd$options, ""), "\\|")[[1]],
                                           selected = cur),
              speciesSelection = selectInput(id, lbl,
                choices = c("All species" = "", species_choices()), selected = cur),
              noInput = div(class = "muted small", lbl),
              textInput(id, lbl, value = as.character(cur)))
          }))
        else div(class = "muted small", "This keyword takes no fields."))
    }))
  })

  # Field edits flow back into the stored settings, which is what the keyword
  # writer reads when a run is prepared.
  observe({
    kws <- rv$volume$keywords
    if (!length(kws)) return()
    changed <- FALSE
    for (i in seq_along(kws)) {
      f <- keyword_fields(kws[[i]]$keyword)
      for (r in seq_len(nrow(f))) {
        fnum <- f$field[r]
        v <- input[[sprintf("volf_%d_%d", i, fnum)]]
        if (is.null(v)) next
        key <- as.character(fnum)
        if (!identical(as.character(nz(kws[[i]]$values[[key]], "")), as.character(v))) {
          kws[[i]]$values[[key]] <- v
          changed <- TRUE
        }
      }
    }
    if (changed) rv$volume$keywords <- kws
  })

  observe({
    for (i in seq_along(rv$volume$keywords)) {
      local({
        idx <- i
        observeEvent(input[[paste0("vol_rm_", idx)]], {
          k <- rv$volume$keywords
          if (idx <= length(k)) rv$volume$keywords <- k[-idx]
        }, ignoreInit = TRUE, once = TRUE)
      })
    }
  })

  output$vol_preview <- renderUI({
    recs <- render_volume_keywords(rv$volume)
    div(class = "kw-preview",
        if (length(recs)) paste(recs, collapse = "\n") else
          "* no volume keywords; FVS variant defaults apply")
  })

  # ============================================================================
  # Scenarios and running
  # ============================================================================
  #' A name that is unique among the existing scenarios.
  unique_scenario_name <- function(base) {
    base <- trimws(nz(base, "Scenario"))
    if (!nzchar(base)) base <- "Scenario"
    if (!base %in% names(rv$scenarios)) return(base)
    i <- 2
    repeat {
      cand <- paste0(base, " ", i)
      if (!cand %in% names(rv$scenarios)) return(cand)
      i <- i + 1
    }
  }

  observeEvent(input$sc_new, {
    n <- unique_scenario_name(paste0("Scenario ", length(rv$scenarios) + 1))
    rv$scenarios[[n]] <- list(name = n, cycles = nz(scenario()$cycles, 10),
                              cycle_length = nz(scenario()$cycle_length, 5),
                              start_year = start_year(), events = list(),
                              raw_keywords = "", computes = list())
    rv$current <- n
  })

  observeEvent(input$sc_copy, {
    src <- rv$scenarios[[rv$current]]
    n <- unique_scenario_name(paste0(rv$current, " copy"))
    src$name <- n
    rv$scenarios[[n]] <- src
    rv$current <- n
  })

  observeEvent(input$sc_delete, {
    if (length(rv$scenarios) <= 1) {
      showNotification("A project needs at least one scenario.", type = "warning")
      return()
    }
    gone <- rv$current
    keep <- setdiff(names(rv$scenarios), gone)
    rv$scenarios[[gone]] <- NULL
    rv$results[[gone]] <- NULL
    rv$current <- keep[1]
    showNotification(paste0("Deleted scenario \u201c", gone, "\u201d."), duration = 4)
  })

  #' Renaming has to move the scenario and any results it already has, and keep
  #' the list order stable so the table does not jump around.
  observeEvent(input$sc_rename, {
    new_name <- trimws(nz(input$sc_rename, ""))
    old_name <- rv$current
    if (!nzchar(new_name) || identical(new_name, old_name)) return()
    if (new_name %in% names(rv$scenarios)) {
      showNotification("Another scenario already has that name.", type = "warning")
      return()
    }
    ord <- names(rv$scenarios)
    sc <- rv$scenarios[[old_name]]
    sc$name <- new_name

    scenarios <- rv$scenarios
    scenarios[[old_name]] <- NULL
    scenarios[[new_name]] <- sc
    rv$scenarios <- scenarios[c(replace(ord, ord == old_name, new_name))]

    if (!is.null(rv$results[[old_name]])) {
      res <- rv$results
      moved <- res[[old_name]]
      moved$scenario <- new_name
      # The scenario label travels with the rows, or charts would color by a
      # name that no longer exists.
      for (tbl in c("StandSummary", "TreeList", "CutList", "ATRTList", "Compute")) {
        if (!is.null(moved[[tbl]]) && "SCENARIO" %in% names(moved[[tbl]]))
          moved[[tbl]]$SCENARIO <- new_name
      }
      res[[old_name]] <- NULL
      res[[new_name]] <- moved
      rv$results <- res
    }
    rv$current <- new_name
  }, ignoreInit = TRUE)

  output$sc_table <- renderUI({
    d <- do.call(rbind, lapply(names(rv$scenarios), function(n) {
      s <- rv$scenarios[[n]]
      ev <- s$events %||% list()
      kw <- if (length(ev))
        paste(unique(vapply(ev, function(e) nz(e$keyword, "?"), character(1))), collapse = ", ")
      else "—"
      data.frame(Scenario = if (identical(n, rv$current)) paste0(n, "  (active)") else n,
                 Treatments = length(ev),
                 Keywords = kw,
                 Cycles = nz(s$cycles, 10),
                 `Cycle length` = nz(s$cycle_length, 5),
                 Results = if (n %in% scenarios_with_results()) "yes" else "—",
                 check.names = FALSE, stringsAsFactors = FALSE)
    }))
    ufvs_table(d)
  })

  output$sc_settings <- renderUI({
    s <- scenario()
    tagList(
      selectInput("sc_pick", "Active scenario", choices = names(rv$scenarios),
                  selected = rv$current),
      textInput("sc_rename", "Name", value = rv$current),
      div(class = "muted small", style = "margin:-4px 0 10px",
          "Edit the name and press Enter or click away to rename."),
      div(class = "form-grid",
        numericInput("sc_cycles", "Cycles", nz(s$cycles, 10), min = 1, max = 40),
        numericInput("sc_len", "Cycle length (years)", nz(s$cycle_length, 5), min = 1, max = 20)),
      div(class = "muted small",
          sprintf("%d treatment(s) scheduled. Edit them on the Management Plan page.",
                  length(s$events %||% list()))))
  })

  observeEvent(input$sc_pick, if (input$sc_pick %in% names(rv$scenarios)) rv$current <- input$sc_pick,
               ignoreInit = TRUE)
  observeEvent(input$sc_cycles, rv$scenarios[[rv$current]]$cycles <- input$sc_cycles, ignoreInit = TRUE)
  observeEvent(input$sc_len, rv$scenarios[[rv$current]]$cycle_length <- input$sc_len, ignoreInit = TRUE)

  output$sc_run_status <- renderUI({
    done <- scenarios_with_results()
    pending <- setdiff(names(rv$scenarios), done)
    tagList(
      if (length(done))
        div(class = "msg msg-ok", sprintf("Results loaded for: %s", paste(done, collapse = ", ")))
      else div(class = "muted small", "No scenario has been run yet."),
      if (length(pending))
        div(class = "muted small", sprintf("Not yet run: %s", paste(pending, collapse = ", "))),
      uiOutput("run_status_box"))
  })

  output$eng_controls <- renderUI({
    cfg <- rv$engine
    modes <- c("Not configured" = "none",
               "Bundled / auto-detected" = "bundled",
               "FVS executable" = "executable",
               "FVS shared libraries" = "library")
    tagList(
      selectInput("eng_mode", NULL, choices = modes, selected = nz(cfg$mode, "none")),
      conditionalPanel("input.eng_mode == 'executable' || input.eng_mode == 'library'",
        textInput("eng_path", "Path", value = nz(cfg$path, ""))))
  })

  output$eng_hint <- renderUI({
    mode <- nz(input$eng_mode, rv$engine$mode)
    if (identical(mode, "bundled")) {
      HTML(sprintf("uFVS will use variant files in <span class='mono'>%s</span>.",
                   nz(rv$engine$path, ufvs_engine_dir())))
    } else if (identical(mode, "executable")) {
      example <- if (.Platform$OS.type == "windows") "C:/FVS/FVSsn.exe"
                 else "/usr/local/FVSbin/FVSsn"
      HTML(sprintf("Full path to an FVS executable, for example <span class='mono'>%s</span>.",
                   example))
    } else if (identical(mode, "library")) {
      HTML(sprintf("Directory holding FVS shared libraries, for example <span class='mono'>FVS%s</span> files.",
                   .Platform$dynlib.ext))
    } else {
      "Inventory analysis works without an FVS engine; projection needs one."
    }
  })

  observeEvent(input$eng_save, {
    mode <- nz(input$eng_mode, "none")
    path <- if (identical(mode, "bundled")) {
      nz(rv$engine$path, ufvs_engine_dir())
    } else nz(input$eng_path, "")
    cfg <- list(mode = mode, path = path)
    rv$engine <- save_engine_config(utils::modifyList(load_engine_config(), cfg))
    es <- engine_status(rv$engine)
    showNotification(paste("Engine:", es$label, "-", es$detail),
                     type = if (es$ok) "message" else "warning", duration = 8)
  })

  output$eng_status_detail <- renderUI({
    es <- engine_status(rv$engine)
    tagList(
      msg_box(if (es$ok) "ok" else if (es$level == "error") "error" else "info",
              strong(es$label), " — ", es$detail),
      if (length(es$variants))
        div(class = "muted small", paste("Variants available:", paste(toupper(es$variants), collapse = ", "))),
      if (!es$ok) method_note(
        "Inventory, statistics, classes and keywords work without an engine. Projection needs one."))
  })

  observeEvent(input$run_start, start_run())
  observeEvent(input$run_project, start_run())
  observeEvent(input$sc_run_all, {
    start_run(names(rv$scenarios))
    showNotification(sprintf("Queued %d scenario(s).", length(rv$scenarios)), duration = 5)
  })

  #' Queue one or more scenarios and start the first.
  #'
  #' Results are filed under the scenario that was running, not under whichever
  #' scenario happens to be selected when the worker finishes, so switching
  #' pages mid-run cannot misfile them.
  start_run <- function(scenario_names = NULL) {
    if (is.null(rv$data)) {
      showNotification("Load an inventory first.", type = "warning"); return()
    }
    errs <- sum(nz(rv$issues$severity, "") == "error")
    if (errs > 0) {
      showNotification(sprintf("%d validation error(s) must be fixed before running.", errs),
                       type = "error", duration = 10)
      rv$page <- "data"; session$sendCustomMessage("ufvs-page", "data"); return()
    }
    if (!is.null(rv$job)) {
      showNotification("A run is already in progress.", type = "warning"); return()
    }
    names_to_run <- nz(scenario_names, rv$current)
    names_to_run <- intersect(names_to_run, names(rv$scenarios))
    if (!length(names_to_run)) return()
    rv$run_queue <- names_to_run
    start_next_scenario()
  }

  start_next_scenario <- function() {
    if (!length(rv$run_queue)) return()
    nm <- rv$run_queue[1]
    rv$run_queue <- rv$run_queue[-1]
    rv$running_scenario <- nm
    launch_scenario(nm)
  }

  launch_scenario <- function(nm) {
    sc <- rv$scenarios[[nm]]
    if (is.null(sc)) return()
    sc$cycles <- nz(sc$cycles, nz(input$run_cycles, 10))
    sc$cycle_length <- nz(sc$cycle_length, nz(input$run_cyclelen, 5))
    sc$start_year <- nz(sc$start_year, default_start_year())
    # Default on: the SVS files are small and the Visualize page needs them.
    sc$svs <- !identical(input$run_svs, FALSE)
    # Volume settings live on the project, not the scenario, so attach them to
    # the scenario handed to the keyword writer. Without this the Volume page
    # could show records that never reached the run.
    sc$volume <- rv$volume

    # Refuse to launch on a Compute definition uFVS cannot render, rather than
    # dropping it quietly and producing a run that ignores it.
    bad <- invalid_computes(sc$computes)
    if (nrow(bad)) {
      showNotification(sprintf("Fix %d Event Monitor expression(s) first: %s",
                               nrow(bad),
                               paste(sprintf("%s (%s)", nz(bad$name, "unnamed"), bad$problem),
                                     collapse = "; ")),
                       type = "error", duration = 12)
      rv$page <- "event"; session$sendCustomMessage("ufvs-page", "event")
      return(invisible(NULL))
    }
    stands <- run_data()$stands$STAND_ID

    # Every stand must reach the executable for its own variant. Checking here
    # means a mismatch is reported before any process starts.
    disp <- check_variant_dispatch(run_data(), stands, rv$engine)
    if (nrow(disp) && any(!disp$ok)) {
      bad <- disp[!disp$ok, , drop = FALSE]
      showNotification(paste(sprintf("Stand(s) %s require FVS variant %s. %s",
                                     bad$stands, toupper(bad$variant), nz(bad$reason, "")),
                             collapse = " "),
                       type = "error", duration = 14)
      rv$run_state <- list(state = "failed", stage = "engine", scenario = nm,
                           message = paste(nz(bad$reason, ""), collapse = " "))
      rv$run_queue <- character(0); rv$running_scenario <- NULL
      rv$page <- "runsettings"; session$sendCustomMessage("ufvs-page", "runsettings")
      return(invisible(NULL))
    }

    # More than one variant always splits, regardless of the batch preference.
    if (nrow(disp) > 1) {
      jobs <- try(launch_by_variant(run_data(), sc, stands, rv$engine,
                                    title = paste(nz(rv$project$name, "uFVS"), nm),
                                    dataset_hash = dataset_hash()), silent = TRUE)
      if (inherits(jobs, "try-error")) {
        showNotification(paste("Could not start the run:", conditionMessage(attr(jobs, "condition"))),
                         type = "error", duration = 12)
        return(invisible(NULL))
      }
      rv$job <- jobs
      rv$batch_results <- list()
      rv$run_state <- list(state = "running", batch = TRUE, scenario = nm,
                           total = length(jobs), completed = 0L)
      showNotification(sprintf("Running %d variant group(s): %s.", nrow(disp),
                               paste(toupper(disp$variant), collapse = ", ")), duration = 6)
      rv$page <- "runsettings"; session$sendCustomMessage("ufvs-page", "runsettings")
      return(invisible(NULL))
    }

    if (isTRUE(input$run_batch) && length(stands) > 1) {
      jobs <- try(launch_batch(run_data(), sc, stands, rv$engine,
                               title = paste(nz(rv$project$name, "uFVS"), nm),
                               dataset_hash = dataset_hash()), silent = TRUE)
      if (inherits(jobs, "try-error")) {
        showNotification(paste("Could not start the batch:", conditionMessage(attr(jobs, "condition"))),
                         type = "error", duration = 12)
        return()
      }
      rv$job <- jobs
      rv$batch_results <- list()
      rv$run_state <- list(state = "running", batch = TRUE, scenario = nm,
                           total = length(jobs), completed = 0L)
      showNotification(sprintf("Started %d independent stand jobs.", length(jobs)), duration = 5)
    } else {
      prep <- try(prepare_run(run_data(), sc, stands, rv$engine,
                              title = paste(nz(rv$project$name, "uFVS"), nm),
                              dataset_hash = dataset_hash()), silent = TRUE)
      if (inherits(prep, "try-error")) {
        showNotification(paste("Could not prepare the run:", conditionMessage(attr(prep, "condition"))),
                         type = "error", duration = 12); return()
      }
      rv$job <- launch_run(prep, rv$engine)
      rv$batch_results <- list()
      rv$run_state <- list(state = "running", scenario = nm,
                           run_id = prep$run_id, dir = prep$dir)
      showNotification(sprintf("Running scenario \u201c%s\u201d.", nm), duration = 5)
    }
    rv$page <- "runsettings"; session$sendCustomMessage("ufvs-page", "runsettings")
  }

  #' The scenario a finishing run belongs to. Falls back to the active one for
  #' runs started before the queue existed.
  run_target <- function() nz(rv$running_scenario, rv$current)

  combine_batch_results <- function(parts, scenario_name) {
    if (!length(parts)) return(NULL)
    out <- list(scenario = scenario_name)
    names_to_bind <- setdiff(unique(unlist(lapply(parts, names))),
                             c("tables", "missing", "scenario", "error"))
    for (nm in names_to_bind) {
      ds <- lapply(parts, function(x) x[[nm]])
      ds <- ds[!vapply(ds, is.null, logical(1))]
      if (!length(ds)) {
        out[[nm]] <- NULL
      } else {
        common <- Reduce(intersect, lapply(ds, names))
        out[[nm]] <- if (length(common)) {
          do.call(rbind, lapply(ds, function(d) d[, common, drop = FALSE]))
        } else NULL
      }
    }
    out$tables <- unique(unlist(lapply(parts, function(x) x$tables)))
    out$missing <- unique(unlist(lapply(parts, function(x) x$missing)))
    out
  }

  # Poll the worker. Nothing here is allowed to throw into the session.
  observe({
    invalidateLater(1200, session)
    job <- rv$job
    if (is.null(job)) return()

    is_batch <- is.list(job) && length(job) > 0 &&
      all(vapply(job, function(x) is.list(x) && !is.null(x$handle) && !is.null(x$prep),
                 logical(1)))
    if (is_batch) {
      statuses <- lapply(job, function(j) tryCatch(run_status(j), error = function(e)
        list(state = "failed", message = conditionMessage(e), dir = j$prep$dir)))
      done <- !vapply(statuses, function(x) identical(x$state, "running"), logical(1))
      if (any(done)) rv$batch_results <- c(rv$batch_results, statuses[done])
      rv$job <- job[!done]
      total <- length(job) + length(rv$batch_results)
      completed <- length(rv$batch_results)

      if (length(rv$job)) {
        rv$run_state <- list(state = "running", batch = TRUE, total = total,
                             completed = completed)
        return()
      }

      successes <- Filter(function(x) identical(x$state, "success"), rv$batch_results)
      failures <- Filter(function(x) !identical(x$state, "success"), rv$batch_results)
      if (length(successes)) {
        parts <- lapply(successes, function(x) {
          fvs <- read_fvs_output(file.path(x$dir, "FVSOut.db"))
          normalize_fvs_output(fvs, run_target())
        })
        rv$results[[run_target()]] <- combine_batch_results(parts, run_target())
      }
      rv$job <- NULL
      if (length(rv$run_queue)) start_next_scenario() else rv$running_scenario <- NULL
      if (length(failures)) {
        rv$run_state <- list(state = "failed", batch = TRUE, total = total,
                             completed = completed, succeeded = length(successes),
                             failed = length(failures),
                             message = sprintf("%d of %d stand jobs failed; successful outputs were retained.",
                                               length(failures), total),
                             dirs = vapply(rv$batch_results, function(x) nz(x$dir, ""), character(1)))
        showNotification(rv$run_state$message, type = "warning", duration = 10)
      } else {
        rv$run_state <- list(state = "success", batch = TRUE, total = total,
                             completed = completed, succeeded = length(successes))
        showNotification("All stand jobs finished. Results loaded.", type = "message", duration = 6)
      }
      return()
    }

    st <- tryCatch(run_status(job), error = function(e)
      list(state = "failed", message = conditionMessage(e), dir = job$prep$dir))
    if (!identical(st$state, "running")) {
      rv$job <- NULL
      st$scenario <- run_target()
      rv$run_state <- st
      target <- run_target()
      if (identical(st$state, "success")) {
        fvs <- read_fvs_output(file.path(st$dir, "FVSOut.db"))
        rv$results[[target]] <- normalize_fvs_output(fvs, target)
        showNotification(sprintf("Scenario \u201c%s\u201d finished.", target),
                         type = "message", duration = 5)
      } else {
        showNotification(sprintf("Scenario \u201c%s\u201d failed. uFVS is unaffected — see Run for details.",
                                 target), type = "error", duration = 10)
      }
      # Keep going through a queued "Run all" even if one scenario failed.
      if (length(rv$run_queue)) start_next_scenario() else rv$running_scenario <- NULL
    } else {
      rv$run_state <- st
    }
  })

  output$run_status_box <- renderUI({
    st <- rv$run_state
    if (is.null(st)) return(div(class = "muted small", "No run has been started in this session."))
    if (identical(st$state, "running"))
      return(if (isTRUE(st$batch))
        msg_box("info", strong("Running. "),
                sprintf("%d of %d stand jobs complete.", st$completed, st$total))
        else msg_box("info", strong("Running. "), st$run_id))
    if (identical(st$state, "success"))
      return(if (isTRUE(st$batch))
        msg_box("ok", strong("Finished. "),
                sprintf("All %d stand jobs completed successfully.", st$succeeded))
        else msg_box("ok", strong("Finished. "),
                     sprintf("Run %s completed successfully.", nz(st$run_id, ""))))
    diag <- tryCatch(diagnose_failure(st$dir), error = function(e) NULL)
    tagList(
      msg_box("error", strong("The run failed. "), nz(st$message, "No further detail.")),
      tags$dl(class = "kv",
        tags$dt("Stage"), tags$dd(nz(st$stage, "unknown")),
        tags$dt("Exit status"), tags$dd(nz(st$exit_status, "—")),
        tags$dt("Run folder"), tags$dd(span(class = "mono", nz(st$dir, "—")))),
      if (!is.null(diag) && length(diag$lines))
        tagList(h3("Engine messages"), div(class = "kw-preview", paste(diag$lines, collapse = "\n"))),
      div(style = "margin-top:10px",
        actionButton("run_retry", "Retry", class = "btn-default"),
        actionButton("run_open_log", "View full log", class = "btn-default")),
      method_note("FVS runs in a separate process; your project is untouched."))
  })

  observeEvent(input$run_retry, start_run())
  observeEvent(input$run_open_log, {
    rv$page <- "log"; session$sendCustomMessage("ufvs-page", "log")
  })

  output$run_history <- renderUI({
    r <- list_runs()
    if (!nrow(r)) return(div(class = "muted small", "No runs recorded yet."))
    d <- r[, c("run_id", "created", "scenario", "stands", "status")]
    names(d) <- c("Run", "Created", "Scenario", "Stands", "Status")
    ufvs_table(utils::head(d, 25))
  })

  # ============================================================================
  # Results
  # ============================================================================
  current_results <- reactive(results_for(rv$current))

  output$merch_source_note <- renderUI({
    have <- !is.null(current_results()$TreeList)
    n <- volume_provenance_note(have)
    msg_box(if (have) "ok" else "info", prov_badge(n$tag), " ", n$text)
  })

  output$merch_products <- renderUI({
    tagList(
      div(class = "muted small merch-help",
          "Use one class per species when utilization limits differ. Species-specific classes take precedence; leave Species blank for all-species fallbacks."),
      lapply(seq_along(rv$products), function(i) {
      p <- rv$products[[i]]
      selected_species <- product_species(p)
      div(class = "merch-class-row",
        div(class = "merch-class-name",
          textInput(paste0("pr_name_", i), "Class", p$name)),
        div(class = "merch-class-min",
          numericInput(paste0("pr_min_", i), "Min DBH", p$min_dbh, step = 0.5)),
        div(class = "merch-class-max",
          numericInput(paste0("pr_max_", i), "Max DBH", p$max_dbh, step = 0.5)),
        div(class = "merch-class-species",
          selectInput(paste0("pr_sp_", i), "Species", multiple = TRUE,
                      choices = species_choices(),
                      selected = if (identical(selected_species, "*")) NULL else selected_species,
                      selectize = TRUE)),
        div(class = "merch-class-copy",
          actionButton(paste0("merch_copy_", i), "Duplicate", class = "btn-default")))
    })
    )
  })

  observe({
    n <- length(rv$products)
    changed <- FALSE
    ps <- rv$products
    for (i in seq_len(n)) {
      nm <- input[[paste0("pr_name_", i)]]; mn <- input[[paste0("pr_min_", i)]]
      mx <- input[[paste0("pr_max_", i)]]; sp <- input[[paste0("pr_sp_", i)]]
      if (!is.null(nm) && !identical(nm, ps[[i]]$name)) { ps[[i]]$name <- nm; changed <- TRUE }
      if (!is.null(mn) && !identical(mn, ps[[i]]$min_dbh)) { ps[[i]]$min_dbh <- mn; changed <- TRUE }
      if (!is.null(mx) && !identical(mx, ps[[i]]$max_dbh)) { ps[[i]]$max_dbh <- mx; changed <- TRUE }
      newsp <- if (is.null(sp) || !length(sp)) "*" else sp
      if (!identical(newsp, ps[[i]]$species)) { ps[[i]]$species <- newsp; changed <- TRUE }
    }
    if (changed) rv$products <- ps
  })

  merch_copy_seen <- reactiveValues()
  observe({
    n <- length(rv$products)
    for (i in seq_len(n)) {
      id <- paste0("merch_copy_", i)
      val <- input[[id]]
      if (is.null(val) || is.na(val) || val < 1) next
      last <- merch_copy_seen[[id]]
      if (!is.null(last) && val <= last) next
      merch_copy_seen[[id]] <- val
      p <- rv$products[[i]]
      p$id <- paste0("class", n + 1)
      p$name <- paste(nz(p$name, paste("Class", i)), "copy")
      rv$products <- c(rv$products, list(p))
      break
    }
  })

  observeEvent(input$merch_add, {
    i <- length(rv$products) + 1
    rv$products <- c(rv$products, list(list(
      id = paste0("class", i), name = paste("Class", i), species = "*",
      min_dbh = 0, max_dbh = 999)))
  })

  output$merch_table <- renderUI({
    res <- current_results()
    if (is.null(res$TreeList)) {
      if (is.null(rv$expanded))
        return(empty_state("No inventory", "Import data first."))
      d <- product_summary_inventory(rv$expanded, rv$products)
      names(d)[names(d) == "STAND_ID"] <- "Stand"
      names(d)[names(d) == "PRODUCT"] <- "Product"
      return(tagList(
        ufvs_table(d, digits = list(TPA = 1, BA = 1, QMD = 1)),
        method_note("Trees per acre and basal area only. Volume comes from FVS.")))
    }
    yrs <- sort(unique(res$TreeList$Year))
    d <- product_summary_fvs(res$TreeList, rv$products, year = yrs[1])
    ufvs_table(d, digits = list(TPA = 1, BA = 1, QMD = 1, TCuFt = 0, MCuFt = 0, SCuFt = 0,
                                BdFt = 0, MBF = 2))
  })

  output$merch_species_table <- renderUI({
    res <- current_results()
    if (is.null(res$TreeList)) {
      if (is.null(rv$expanded)) return(div(class = "muted small", "No data."))
      d <- product_summary_inventory(rv$expanded, rv$products, by = "SPECIES")
      return(ufvs_table(d, digits = list(TPA = 1, BA = 1, QMD = 1)))
    }
    yrs <- sort(unique(res$TreeList$Year))
    d <- product_summary_fvs(res$TreeList, rv$products, by = "SpeciesFVS", year = yrs[1])
    ufvs_table(d, digits = list(TPA = 1, BA = 1, QMD = 1, MCuFt = 0, BdFt = 0, MBF = 2))
  })

  output$merch_reconcile <- renderUI({
    res <- current_results()
    if (is.null(res$TreeList) || is.null(res$StandSummary)) return(NULL)
    yrs <- sort(unique(res$TreeList$Year))
    d <- product_summary_fvs(res$TreeList, rv$products, year = yrs[1])
    rec <- reconcile_products(d, res$StandSummary)
    if (!nrow(rec))
      return(msg_box("ok", "Class subtotals reconcile with FVS totals."))
    card("Reconciliation", msg_box("warn", strong("Class subtotals do not match FVS totals. "),
      "Trust the FVS totals."), ufvs_table(rec))
  })

  #' Years available across the selected scenarios.
  ss_years <- reactive({
    tabs <- results_tables(nz(input$ss_scenarios, scenarios_with_results()))
    d <- tabs$StandSummary
    if (is.null(d) || !nrow(d)) return(numeric(0))
    sort(unique(safe_num(d$Year)))
  })

  output$ss_controls <- renderUI({
    have <- scenarios_with_results()
    yrs <- isolate(ss_years())
    tagList(
      div(class = "bar-row",
        div(style = "min-width:260px;flex:1",
          scenario_picker("ss_scenarios", have,
                          isolate(intersect(nz(input$ss_scenarios, have), have)))),
        if (length(yrs))
          div(style = "width:130px",
            year_picker("ss_year", yrs, isolate(input$ss_year)))),
      div(class = "muted small",
          sprintf("Statistics shown: %s at %s%%. Change them on the Statistics page.",
                  paste(stat_column_names(rv$stats), collapse = " \u00b7 "),
                  fmt_num(rv$stats$confidence_level, 1))))
  })

  #' Projected stand table for the chosen year, one row per scenario, so the
  #' alternatives can be read against each other directly.
  output$ss_projected <- renderUI({
    picks <- nz(input$ss_scenarios, scenarios_with_results())
    tabs <- results_tables(picks)
    d <- tabs$StandSummary
    if (is.null(d) || !nrow(d)) return(NULL)
    yr <- suppressWarnings(as.numeric(nz(input$ss_year, NA)))
    if (is.na(yr)) yr <- min(safe_num(d$Year), na.rm = TRUE)
    d <- d[safe_num(d$Year) == yr, , drop = FALSE]
    if (!nrow(d)) return(NULL)

    keep <- intersect(c("SCENARIO", "StandID", "Age", "Tpa", "BA", "QMD", "TopHt",
                        "SDI", "TCuFt", "MCuFt", "BdFt", "RTpa", "RMCuFt", "MAI"),
                      names(d))
    out <- d[, keep, drop = FALSE]
    names(out)[names(out) == "SCENARIO"] <- "Scenario"
    names(out)[names(out) == "StandID"] <- "Stand"
    card(sprintf("Projected stand, year %s", fmt_num(yr, 0)),
      ufvs_table(out, digits = list(Tpa = 1, BA = 1, QMD = 1, TopHt = 0, SDI = 0,
                                    TCuFt = 0, MCuFt = 0, BdFt = 0, RTpa = 1,
                                    RMCuFt = 0, MAI = 1)),
      method_note("FVS output for the selected year. Volumes are FVS's own."))
  })

  output$ss_body <- renderUI({
    tagList(
      uiOutput("ss_projected"),
      card("Inventory statistics", sub = "the cruise, not a projection",
           uiOutput("ss_table")),
      card("By species", uiOutput("ss_species")))
  })

  output$ss_table <- renderUI(stat_block(c("TPA", "BA", "QMD")))

  output$ss_species <- renderUI({
    if (is.null(rv$expanded)) return(div(class = "muted small", "Load an inventory."))
    pt <- plot_table(rv$expanded, rv$data)
    tr <- rv$expanded$trees[rv$expanded$trees$IS_LIVE %in% TRUE, , drop = FALSE]
    g <- plot_group_values(tr, pt, "BA_PLOT", "SPECIES")
    n_obs <- vapply(names(g), function(s) sum(tr$SPECIES == s), numeric(1))
    tbl <- stat_table(g, rv$stats, n_obs = n_obs, label_col = "Species")
    tagList(ufvs_table(tbl),
      method_note("Plots without a species contribute zero, not a missing value."))
  })

  # ---- charts ----------------------------------------------------------------
  #' Results recovered from the run directories on disk.
  #'
  #' A run writes its output next to its keyword file and records the scenario
  #' in run.json, so results survive a reload. Without this, reopening the app
  #' left every results page empty while the runs sat on disk.
  #' Hash of the inventory currently loaded, used to match past runs to it.
  dataset_hash <- reactive({
    if (is.null(rv$data)) return(NA_character_)
    inventory_hash(rv$data)
  })

  disk_results <- reactive({
    rv$results          # re-read once a new run lands
    dh <- dataset_hash()
    if (is.na(dh)) return(list())
    runs <- list_runs()
    runs <- runs[runs$status == "success", , drop = FALSE]
    # Results from a different inventory would be misleading, and runs written
    # before uFVS recorded the dataset cannot be matched at all.
    runs <- runs[nz(runs$dataset_hash, "") == dh, , drop = FALSE]
    out <- list()
    for (i in seq_len(nrow(runs))) {
      nm <- runs$scenario[i]
      if (!nzchar(nz(nm, "")) || !is.null(out[[nm]])) next   # newest wins
      db <- file.path(runs$dir[i], "FVSOut.db")
      if (!file.exists(db)) next
      key <- paste0("res:", runs$run_id[i])
      out[[nm]] <- cached(key, function() {
        normalize_fvs_output(read_fvs_output(db), nm)
      })
    }
    out
  })

  #' Results for one scenario: whatever is in memory, else what is on disk.
  results_for <- function(nm) {
    r <- rv$results[[nm]]
    if (!is.null(r)) return(r)
    disk_results()[[nm]]
  }

  #' Scenarios with results, in the order they appear in the project.
  scenarios_with_results <- reactive({
    have <- union(names(rv$results), names(disk_results()))
    # Keep project order, then any scenario that only exists as a past run.
    c(intersect(names(rv$scenarios), have), setdiff(have, names(rv$scenarios)))
  })

  #' Which scenarios the charts should draw. Defaults to every scenario that has
  #' been run, so comparing them is the normal case rather than a separate page.
  chart_scenarios <- reactive({
    have <- scenarios_with_results()
    pick <- intersect(nz(input$ch_scenarios, character(0)), have)
    if (!length(pick)) have else pick
  })

  #' Output tables stacked across the selected scenarios.
  #'
  #' normalize_fvs_output() tags every row with SCENARIO, so binding them gives
  #' one frame that can be colored or faceted by scenario.
  #' Output tables stacked across the named scenarios.
  #'
  #' normalize_fvs_output() tags every row with SCENARIO, so binding them gives
  #' one frame that can be split, colored or faceted by scenario.
  results_tables <- function(picks) {
    picks <- intersect(picks, scenarios_with_results())
    if (!length(picks)) return(list())
    out <- list()
    for (tbl in c("StandSummary", "TreeList", "CutList")) {
      parts <- lapply(picks, function(nm) {
        d <- results_for(nm)[[tbl]]
        if (is.null(d) || !nrow(d)) return(NULL)
        if (!"SCENARIO" %in% names(d)) d$SCENARIO <- nm
        d
      })
      parts <- parts[!vapply(parts, is.null, logical(1))]
      if (!length(parts)) next
      common <- Reduce(intersect, lapply(parts, names))
      if (!length(common)) next
      out[[tbl]] <- do.call(rbind, lapply(parts, function(d) d[, common, drop = FALSE]))
    }
    out
  }

  chart_tables <- reactive(results_tables(chart_scenarios()))

  # The chart controls are rendered rather than updated. updateSelectInput only
  # reaches inputs that exist in the browser right now, so choices computed while
  # another page was showing were being dropped, leaving empty menus.
  output$ch_controls <- renderUI({
    tabs <- chart_tables()
    av <- names(tabs)
    xs <- vars_for_role("x", av)
    ys <- vars_for_role("y", av)
    grp <- c("None", vars_for_role("group", av))
    fac <- c("None", vars_for_role("facet", av))
    have <- scenarios_with_results()

    if (!length(xs) || !length(ys)) {
      return(tagList(
        selectInput("ch_type", "Type",
                    c("Line" = "line", "Bar" = "bar", "Points" = "point", "Area" = "area"),
                    selected = isolate(nz(input$ch_type, "line"))),
        div(class = "muted small",
            "No FVS output to plot yet. Run a scenario, then pick variables here.")))
    }

    # Keep the user's choice when it is still valid; otherwise fall back to a
    # sensible default rather than leaving the control blank.
    # Current selections are read without a reactive dependency, so choosing a
    # variable does not rebuild every control underneath the user.
    cur <- isolate(list(type = input$ch_type, x = input$ch_x, y = input$ch_y,
                        group = input$ch_group, facet = input$ch_facet,
                        facet_col = input$ch_facet_col, summary = input$ch_summary,
                        scales = input$ch_scales, scenarios = input$ch_scenarios))
    keep <- function(v, opts, default) {
      if (!is.null(v) && v %in% opts) v else
        if (default %in% opts) default else opts[[1]]
    }
    # With more than one scenario run, coloring by scenario is what you want.
    default_group <- if (length(have) > 1) "SCENARIO" else "None"

    tagList(
      if (length(have) > 1)
        selectInput("ch_scenarios", "Scenarios", choices = have, multiple = TRUE,
                    selected = intersect(nz(cur$scenarios, have), have)),
      selectInput("ch_type", "Type",
                  c("Line" = "line", "Bar" = "bar", "Points" = "point", "Area" = "area"),
                  selected = nz(cur$type, "line")),
      selectInput("ch_x", "X", choices = xs, selected = keep(cur$x, xs, "Year")),
      selectInput("ch_y", "Y", choices = ys, selected = keep(cur$y, ys, "BA")),
      selectInput("ch_group", "Color", choices = grp,
                  selected = keep(cur$group, grp, default_group)),
      selectInput("ch_facet", "Facet wrap", choices = fac,
                  selected = keep(cur$facet, fac, "None")),
      tags$details(tags$summary(class = "muted small", "More"),
        div(style = "padding-top:8px",
          selectInput("ch_facet_col", "Second facet (grid)", choices = fac,
                      selected = keep(cur$facet_col, fac, "None")),
          selectInput("ch_summary", "Summarize by",
                      c("Mean" = "mean", "Sum" = "sum", "Median" = "median",
                        "Max" = "max", "Min" = "min"),
                      selected = nz(cur$summary, "mean")),
          selectInput("ch_scales", "Facet scales",
                      c("Same" = "fixed", "Free y" = "free_y", "Free" = "free"),
                      selected = nz(cur$scales, "fixed")))))
  })

  chart_spec <- reactive({
    # No fabricated axis defaults: if the control is unset, say so rather than
    # silently validating a variable the user never picked.
    list(type = nz(input$ch_type, "line"), x = nz(input$ch_x, ""), y = nz(input$ch_y, ""),
         group = nz(input$ch_group, "None"),
         facet_row = nz(input$ch_facet, "None"),
         facet_col = nz(input$ch_facet_col, "None"),
         summary = nz(input$ch_summary, "mean"),
         scales = nz(input$ch_scales, "fixed"), points = TRUE, filters = list())
  })

  chart_check <- reactive({
    tabs <- chart_tables()
    if (!length(tabs)) return(list(ok = FALSE,
      message = "No FVS output to plot yet.",
      suggestions = "Run a scenario first.", plan = NULL))
    tryCatch(validate_chart(chart_spec(), tabs, names(tabs)),
             error = function(e) list(ok = FALSE,
               message = paste("The chart could not be prepared:", conditionMessage(e)),
               suggestions = "Choose the chart variables again.", plan = NULL))
  })

  output$ch_validation <- renderUI({
    v <- chart_check()
    ok <- is.list(v) && isTRUE(v$ok)
    message <- if (is.list(v)) nz(v$message, "This chart cannot be drawn.") else
      "This chart cannot be drawn."
    suggestions <- if (is.list(v)) v$suggestions else character(0)
    if (ok) return(msg_box("ok", message))
    tagList(msg_box("warn", strong("This chart cannot be drawn. "), message),
            if (length(suggestions) && nzchar(suggestions[1]))
              div(class = "muted small", suggestions))
  })

  output$ch_plot <- renderPlot({
    v <- chart_check()
    if (!is.list(v) || !isTRUE(v$ok)) {
      plot.new()
      message <- if (is.list(v)) nz(v$message, "Nothing to plot.") else "Nothing to plot."
      text(0.5, 0.5, message, col = "#6e777d")
      return(invisible(NULL))
    }
    b <- build_chart(chart_spec(), chart_tables(), v)
    if (is.null(b$plot)) {
      plot.new()
      text(0.5, 0.5, nz(b$message, "Nothing to plot."), col = "#6e777d")
      return(invisible(NULL))
    }
    b$plot + ggplot2::scale_color_manual(values = rep(UFVS_PALETTE, 9)) +
      ggplot2::scale_fill_manual(values = rep(UFVS_PALETTE, 9))
  })

  output$ch_data <- renderUI({
    v <- chart_check()
    if (!is.list(v) || !isTRUE(v$ok)) return(div(class = "muted small", "Nothing plotted."))
    b <- build_chart(chart_spec(), chart_tables(), v)
    if (is.null(b$data)) return(div(class = "muted small", nz(b$message, "Nothing plotted.")))
    ufvs_table(utils::head(b$data, 60))
  })

  # ---- tables ----------------------------------------------------------------
  # One place decides what the table builder is showing. Both the controls and
  # the result read it, so the table appears immediately instead of waiting for
  # the browser to echo the default selections back to the server.
  table_plan <- reactive({
    tabs <- results_tables(nz(input$tb_scenarios, scenarios_with_results()))
    if (!length(tabs)) return(NULL)
    src <- if (!is.null(input$tb_source) && input$tb_source %in% names(tabs))
      input$tb_source else names(tabs)[1]
    d <- tabs[[src]]

    num <- names(d)[vapply(d, is.numeric, logical(1))]
    # Year, Age and code columns are stored as numbers but are what a forester
    # actually groups by, so anything with few distinct values counts as a
    # grouping column as well as a total.
    groupable <- names(d)[vapply(names(d), function(n) {
      col <- d[[n]]
      if (!is.numeric(col)) return(TRUE)
      vals <- unique(col[!is.na(col)])
      length(vals) <= 50 && all(vals == round(vals))
    }, logical(1))]
    # Identifiers total to nonsense.
    totalable <- setdiff(num, c("CaseID", "StandID", "Year", "RmvCode"))

    group <- intersect(nz(input$tb_group, character(0)), groupable)
    if (!length(group)) {
      # With several scenarios loaded, splitting by scenario is what makes the
      # table readable; totalling across them would be meaningless.
      default_group <- if (length(unique(nz(d$SCENARIO, "")))> 1)
        c("SCENARIO", "Year") else c("Year", "StandID")
      group <- intersect(default_group, groupable)
    }
    group <- group[!is.na(group)]
    values <- intersect(nz(input$tb_values, character(0)), totalable)
    if (!length(values))
      values <- intersect(c("Tpa", "BA", "MCuFt", "BdFt", "TPA", "TCuFt"), totalable)

    list(tabs = tabs, source = src, data = d, groupable = groupable,
         totalable = totalable, group = group, values = values)
  })

  output$tb_controls <- renderUI({
    p <- table_plan()
    if (is.null(p)) {
      return(div(class = "muted small",
                 "No FVS output yet. Run a scenario, then build a table from it."))
    }
    have <- scenarios_with_results()
    tagList(
      scenario_picker("tb_scenarios", have,
                      isolate(intersect(nz(input$tb_scenarios, have), have))),
      selectInput("tb_source", "Source", choices = names(p$tabs), selected = p$source),
      selectInput("tb_group", "Group by", choices = p$groupable, multiple = TRUE,
                  selected = p$group),
      selectInput("tb_values", "Total", choices = p$totalable, multiple = TRUE,
                  selected = p$values))
  })

  output$tb_result <- renderUI({
    p <- table_plan()
    if (is.null(p))
      return(empty_state("No output tables", "Run a scenario first."))
    if (!length(p$group) || !length(p$values))
      return(div(class = "muted small", "Choose a grouping column and a column to total."))

    d <- p$data
    key <- do.call(paste, c(lapply(p$group, function(k) d[[k]]), sep = "\r"))
    out <- do.call(rbind, lapply(split(d, key), function(x) {
      row <- x[1, p$group, drop = FALSE]
      for (k in p$values) row[[k]] <- sum(safe_num(x[[k]]), na.rm = TRUE)
      row
    }))
    rownames(out) <- NULL
    # Keep the natural reading order of the grouping columns.
    ord <- do.call(order, lapply(p$group, function(k) out[[k]]))
    ufvs_table(out[ord, , drop = FALSE])
  })

  # ---- compare ---------------------------------------------------------------
  output$cmp_body <- renderUI({
    done <- names(rv$results)
    if (length(done) < 2)
      return(empty_state("Nothing to compare", "Run at least two scenarios."))
    comb <- combine_scenarios(rv$results)
    if (is.null(comb$StandSummary)) return(div(class = "muted small", "No stand summaries to compare."))
    tagList(card("Stand summary by scenario", plotOutput("cmp_plot", height = "360px")),
            card("Values", ufvs_table(utils::head(comb$StandSummary, 60))))
  })

  output$cmp_plot <- renderPlot({
    comb <- combine_scenarios(rv$results)
    d <- comb$StandSummary
    validate(need(!is.null(d) && "BA" %in% names(d), "No basal area column to compare."))
    ggplot2::ggplot(d, ggplot2::aes(x = Year, y = BA, color = SCENARIO)) +
      ggplot2::geom_line(linewidth = 0.9) + ggplot2::geom_point(size = 1.7) +
      ggplot2::scale_color_manual(values = rep(UFVS_PALETTE, 9)) +
      ggplot2::labs(x = "Year", y = "Basal area (ft2/ac)", color = "Scenario") +
      ufvs_axis_theme()
  })

  # ---- stand visualization ---------------------------------------------------
  #' SVS files live beside the run that produced them, so the index is found
  #' from the run directory recorded for the scenario being viewed.
  #' Run directories that hold SVS output, keyed by the scenario that produced
  #' them. run.json records the scenario, so each panel can find its own files.
  svs_dirs_by_scenario <- reactive({
    rv$results   # recompute once new results land
    runs <- list_runs()
    out <- list()
    for (i in seq_len(nrow(runs))) {
      d <- runs$dir[i]
      if (!nrow(read_svs_index(d))) next
      nm <- runs$scenario[i]
      if (!nzchar(nz(nm, ""))) nm <- runs$run_id[i]
      # Newest first, so the first hit for a scenario is its latest run.
      if (is.null(out[[nm]])) out[[nm]] <- d
    }
    out
  })

  svs_scenarios <- reactive(names(svs_dirs_by_scenario()))

  #' The scenarios being shown, defaulting to the first one available.
  svs_picked <- reactive({
    have <- svs_scenarios()
    pick <- intersect(nz(input$svs_scenarios, character(0)), have)
    if (!length(pick)) pick <- utils::head(have, 1)
    utils::head(pick, SVS_MAX_PANELS)
  })

  svs_index_for <- function(scenario) {
    d <- svs_dirs_by_scenario()[[scenario]]
    if (is.null(d)) return(read_svs_index(NULL))
    read_svs_index(d)
  }

  # Kept for the single-panel helpers below.
  svs_index <- reactive({
    p <- svs_picked()
    if (!length(p)) return(read_svs_index(NULL))
    svs_index_for(p[1])
  })

  output$svs_controls <- renderUI({
    have <- svs_scenarios()
    if (!length(have)) return(NULL)
    picks <- isolate(svs_picked())
    cur_view <- isolate(nz(input$svs_view, if (svs_3d_available()) "three" else "profile"))
    cur_down <- isolate(!identical(input$svs_down, FALSE))

    div(class = "card card-tight",
      div(class = "bar-row",
        div(style = "min-width:260px;flex:1",
          scenario_picker("svs_scenarios", have, picks)),
        div(class = "inline-checks",
          radioButtons("svs_view", NULL, inline = TRUE,
                       c(c("3D" = "three")[svs_3d_available()],
                         "Profile" = "profile", "From above" = "plan"),
                       selected = cur_view),
          conditionalPanel("input.svs_view == 'three'",
            checkboxInput("svs_down", "Include fallen trees", cur_down)))),
      if (length(have) > SVS_MAX_PANELS)
        div(class = "muted small",
            sprintf("Up to %d scenarios can be shown side by side.", SVS_MAX_PANELS)))
  })

  #' The SVS file selected for one scenario panel.
  svs_file_for <- function(scenario) {
    idx <- svs_index_for(scenario)
    if (!nrow(idx)) return(NULL)
    yr <- suppressWarnings(as.numeric(input[[paste0("svs_year_", make.names(scenario))]]))
    row <- if (!is.na(yr) && any(idx$year == yr)) idx[idx$year == yr, ][1, ] else idx[1, ]
    read_svs_file(row$path)
  }

  svs_current <- reactive({
    p <- svs_picked()
    if (!length(p)) return(NULL)
    svs_file_for(p[1])
  })

  output$svs_body <- renderUI({
    picks <- svs_picked()
    if (!length(picks)) {
      return(empty_state("No stand visualization yet",
        "Turn on \u201cWrite stand visualization files\u201d on the Run page, then run a scenario."))
    }
    three <- identical(nz(input$svs_view, ""), "three") && svs_3d_available()
    # Each panel owns its scenario, its year and its picture, so the columns
    # stay together however many are shown.
    tagList(
      div(class = "svs-grid",
        lapply(picks, function(nm) {
          id <- make.names(nm)
          idx <- svs_index_for(nm)
          div(class = "card svs-panel",
            div(class = "svs-panel-head",
              div(class = "svs-panel-title", nm),
              if (nrow(idx))
                year_picker(paste0("svs_year_", id), idx$year,
                            isolate(input[[paste0("svs_year_", id)]]))
              else div(class = "muted small", "No visualization files.")),
            if (three) rgl::rglwidgetOutput(paste0("svs3d_", id), width = "100%", height = "380px")
            else plotOutput(paste0("svsplot_", id), height = "360px"),
            uiOutput(paste0("svsinfo_", id)))
        })),
      card("How to read this", uiOutput("svs_about")))
  })

  # One set of outputs per scenario panel, created once for every scenario that
  # has ever produced visualization files.
  observe({
    for (nm in svs_scenarios()) {
      local({
        scen <- nm
        id <- make.names(scen)
        if (!is.null(rv$svs_bound[[id]])) return()
        rv$svs_bound[[id]] <- TRUE

        output[[paste0("svsplot_", id)]] <- renderPlot({
          s <- svs_file_for(scen)
          if (is.null(s) || is.null(s$trees) || !nrow(s$trees)) {
            graphics::par(mar = c(0, 0, 0, 0)); graphics::plot.new()
            graphics::text(0.5, 0.5, "No trees to draw.", col = "#6e777d")
            return(invisible(NULL))
          }
          if (identical(nz(input$svs_view, "profile"), "plan")) plot_svs_plan(s)
          else plot_svs_profile(s)
          invisible(NULL)
        })

        if (svs_3d_available()) {
          output[[paste0("svs3d_", id)]] <- rgl::renderRglwidget({
            s <- svs_file_for(scen)
            req(!is.null(s), nrow(nz(s$trees, data.frame())) > 0)
            w <- svs_scene3d(s, max_trees = SVS_MAX_3D_TREES,
                             down_trees = !identical(input$svs_down, FALSE))
            req(!is.null(w))
            w
          })
        }

        output[[paste0("svsinfo_", id)]] <- renderUI({
          s <- svs_file_for(scen)
          if (is.null(s)) return(NULL)
          lg <- svs_legend(s)
          tagList(
            div(class = "muted small", style = "margin-top:6px",
                sprintf("%s \u00b7 %s trees drawn", nz(s$title, scen), fmt_int(nrow(s$trees)))),
            div(style = "margin-top:6px",
              lapply(seq_len(nrow(lg)), function(i) {
                span(style = "display:inline-flex;align-items:center;gap:5px;margin:0 10px 4px 0",
                  span(style = sprintf("width:10px;height:10px;border-radius:2px;background:%s;display:inline-block",
                                       lg$color[i])),
                  span(class = "small", sprintf("%s (%d)", lg$species[i], lg$trees[i])))
              })))
        })
      })
    }
  })

  output$svs_about <- renderUI({
    s <- svs_current()
    if (is.null(s)) return(NULL)
    tagList(
      tags$dl(class = "kv",
        tags$dt("Display plot"), tags$dd(sprintf("%s x %s ft",
                                                 fmt_num(s$plot_size[1], 0),
                                                 fmt_num(s$plot_size[2], 0))),
        tags$dt("Tree forms"), tags$dd(toupper(nz(s$treeform, "\u2014")))),
      if (identical(nz(input$svs_view, ""), "three") && nrow(s$trees) > SVS_MAX_3D_TREES)
        div(class = "muted small",
            sprintf("Showing the first %d of %d trees in 3D to keep the scene responsive. ",
                    SVS_MAX_3D_TREES, nrow(s$trees)),
            "The 2D views draw them all."),
      method_note("Tree positions, crown radii and crown ratios are FVS's own SVS output. ",
                  "Crown shapes and colors come from the official SVS tree-form definitions. ",
                  if (identical(nz(input$svs_view, ""), "three"))
                    "The 3D view uses the same renderer as the official fvsOL interface."
                  else "uFVS draws the 2D views."))
  })

  # ---- raw output and logs ---------------------------------------------------
  output$out_body <- renderUI({
    res <- current_results()
    if (is.null(res)) return(empty_state("No output", "Run a scenario first."))
    tabs <- Filter(function(x) !is.null(x) && nrow(x) > 0,
                   res[setdiff(names(res), c("tables", "missing", "scenario"))])
    tagList(
      card("Tables produced",
        ufvs_table(data.frame(Table = names(tabs),
                              Rows = vapply(tabs, nrow, numeric(1)),
                              Columns = vapply(tabs, ncol, numeric(1)),
                              stringsAsFactors = FALSE))),
      if (length(res$missing))
        card("Not produced",
          tags$ul(lapply(missing_table_advice(res$missing), tags$li))),
      lapply(names(tabs), function(n)
        card(n, ufvs_table(utils::head(tabs[[n]], 25)),
             method_note(sprintf("%d rows.", nrow(tabs[[n]]))))))
  })

  output$log_body <- renderUI({
    st <- rv$run_state
    if (is.null(st) || is.null(st$dir))
      return(empty_state("No run selected", "Start a run first."))
    logs <- run_logs(st$dir)
    if (!length(logs)) return(div(class = "muted small", "No log files in this run folder."))
    tagList(lapply(names(logs), function(n) {
      txt <- logs[[n]]
      card(n, div(class = "kw-preview",
                  paste(utils::head(txt, 300), collapse = "\n")),
           if (length(txt) > 300)
             method_note(sprintf("First 300 of %d lines.", length(txt))))
    }))
  })

  # ---- keyword file ----------------------------------------------------------
  output$kw_file <- renderUI({
    if (is.null(rv$data)) return(div(class = "muted small", "Load an inventory to generate keywords."))
    sc <- scenario()
    inv <- stats::setNames(as.list(rv$data$stands$INV_YEAR), rv$data$stands$STAND_ID)
    txt <- build_keyword_file(rv$data$stands$STAND_ID, sc, title = nz(rv$project$name, "uFVS run"),
                              inv_years = inv)
    tagList(div(class = "kw-preview", txt),
      method_note("Written to the run directory. Structure follows rFVS::fvsMakeKeyFile."))
  })

  output$kw_catalog_summary <- renderUI({
    d <- keyword_defs()
    t <- as.data.frame(table(d$extension), stringsAsFactors = FALSE)
    names(t) <- c("Extension", "Keywords")
    tagList(ufvs_table(t),
      method_note(sprintf("%d keywords, %d fields, from the official fvsOL definitions. Anything without a form can be typed into the raw keyword box.",
                          nrow(d), nrow(keyword_fields_all()))))
  })

  # ---- event monitor ---------------------------------------------------------
  observeEvent(input$em_add, {
    req(nzchar(nz(input$em_name, "")))
    sc <- rv$scenarios[[rv$current]]
    sc$computes <- c(sc$computes, list(list(name = toupper(input$em_name),
                                            expr = input$em_expr, when = input$em_when)))
    rv$scenarios[[rv$current]] <- sc
    updateTextInput(session, "em_name", value = "")
    updateTextAreaInput(session, "em_expr", value = "")
  })

  output$em_list <- renderUI({
    cs <- scenario()$computes
    if (!length(cs)) return(div(class = "muted small", "No Event Monitor expressions defined."))
    d <- do.call(rbind, lapply(cs, function(c)
      data.frame(Variable = c$name, Expression = c$expr, When = c$when, stringsAsFactors = FALSE)))
    tagList(ufvs_table(d),
      h3("Records written"),
      div(class = "kw-preview",
          paste(c("Compute", vapply(cs, function(c) sprintf("%-10s= %s", c$name, c$expr), character(1)),
                  "End"), collapse = "\n")))
  })

  output$em_reference <- renderUI({
    d <- keyword_defs()
    em <- d[grepl("^(Compute|If|Then|EndIf|Else)$", d$keyword, ignore.case = TRUE), , drop = FALSE]
    tagList(
      if (nrow(em)) tagList(lapply(seq_len(nrow(em)), function(i)
        div(style = "margin-bottom:10px", strong(em$keyword[i]),
            div(class = "muted small", em$description[i])))),
      method_note("These appear in FVS_Compute output and can be plotted."))
  })

  # ---- info ------------------------------------------------------------------
  output$info_versions <- renderUI({
    div(class = "muted small", paste("uFVS version", UFVS_VERSION))
  })

  # ---- save/load -------------------------------------------------------------
  project_state <- function() {
    dataset <- if (is.null(rv$data)) NULL else list(
      path = rv$data$source$path,
      name = rv$data$source$name,
      type = rv$data$source$type)
    list(version = UFVS_VERSION,
         saved_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
         project = rv$project, stats = rv$stats,
         products = rv$products, volume = rv$volume,
         scenarios = rv$scenarios, current = rv$current,
         dataset = dataset)
  }

  save_project_file <- function(path) {
    dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
    jsonlite::write_json(project_state(), path, auto_unbox = TRUE,
                         pretty = TRUE, null = "null")
    rv$project_file <- path
    invisible(path)
  }

  project_dataset_path <- function(state, project_path) {
    d <- state$dataset
    if (is.list(d)) d <- d$path
    if (is.null(d) || !length(d) || is.na(d) || !nzchar(as.character(d))) return(NA_character_)
    d <- as.character(d)[1]
    absolute <- grepl("^(/|[A-Za-z]:[\\\\/]|\\\\\\\\)", d)
    candidates <- if (absolute) d else c(
      file.path(dirname(project_path), d),
      file.path(ufvs_root(), d),
      d)
    hit <- candidates[file.exists(candidates) | dir.exists(candidates)]
    if (length(hit)) normalizePath(hit[1], mustWork = FALSE) else NA_character_
  }

  restore_project <- function(path) {
    state <- try(jsonlite::fromJSON(path, simplifyVector = FALSE), silent = TRUE)
    if (inherits(state, "try-error") || !is.list(state)) {
      showNotification("That project file is not valid JSON.", type = "error", duration = 8)
      return(invisible(FALSE))
    }

    if (is.list(state$project)) {
      pj <- utils::modifyList(rv$project, state$project)
      pj$acres <- as_scalar_num(pj$acres)
      pj$stand_age <- as_scalar_num(pj$stand_age)
      rv$project <- pj
    }
    # modifyList DROPS any key whose incoming value is null, so a project saved
    # with an empty confidence level or tract area came back missing the field
    # entirely, and the statistics pages then failed on a zero-length if().
    # Rebuild the settings explicitly instead.
    if (is.list(state$stats)) rv$stats <- restore_stat_settings(state$stats)
    if (is.list(state$products)) rv$products <- state$products
    if (is.list(state$volume)) {
      rv$volume <- utils::modifyList(default_volume_settings(), state$volume)
    }
    if (is.list(state$scenarios) && length(state$scenarios)) {
      # JSON represents multi-value fields as lists. Keep those lists because
      # keyword rendering and the management editor use named field values.
      rv$scenarios <- state$scenarios
      if (is.null(names(rv$scenarios))) {
        names(rv$scenarios) <- paste0("Scenario ", seq_along(rv$scenarios))
      }
    }
    if (!is.null(state$current) && as.character(state$current) %in% names(rv$scenarios))
      rv$current <- as.character(state$current)[1]

    rv$project_file <- path

    data_path <- project_dataset_path(state, path)
    if (!is.na(data_path)) {
      load_dataset(data_path)
      showNotification("Project settings and its inventory were loaded.",
                       type = "message", duration = 6)
    } else {
      rv$data <- NULL; rv$expanded <- NULL; rv$issues <- NULL
      showNotification("Project settings loaded. Re-import the inventory on this computer.",
                       type = "warning", duration = 8)
    }
    invisible(TRUE)
  }

  output$proj_download <- downloadHandler(
    filename = function() {
      stem <- gsub("[^A-Za-z0-9._-]+", "_", nz(rv$project$name, "uFVS_project"))
      paste0(if (nzchar(stem)) stem else "uFVS_project", ".ufvs.json")
    },
    content = function(file) save_project_file(file))

  open_local_project <- function() {
    p <- ufvs_project_path()
    if (!file.exists(p)) {
      showNotification("No saved project was found on this computer.",
                       type = "warning", duration = 6)
      return(invisible(FALSE))
    }
    restore_project(p)
  }

  save_project_now <- function() {
    p <- ufvs_project_path()
    ok <- try(save_project_file(p), silent = TRUE)
    showNotification(if (inherits(ok, "try-error")) "Could not save the project."
                     else paste("Project saved locally at", p),
                     type = if (inherits(ok, "try-error")) "error" else "message", duration = 6)
  }

  observeEvent(input$save_project, save_project_now(), ignoreInit = TRUE)
  observeEvent(input$proj_save, save_project_now(), ignoreInit = TRUE)

  #' Keep the project on disk without the user having to remember to save.
  #'
  #' Writes to projects/<name>.ufvs.json whenever the project meaningfully
  #' changes, debounced so typing a name does not write a file per keystroke.
  autosave_state <- reactive({
    list(project = rv$project, stats = rv$stats, products = rv$products,
         volume = rv$volume, scenarios = rv$scenarios, current = rv$current,
         dataset = if (is.null(rv$data)) NULL else rv$data$source$path)
  })

  observe({
    state <- autosave_state()
    # Nothing to save until an inventory or a real project name exists.
    if (is.null(rv$data) && identical(nz(rv$project$name, ""), "Untitled project")) return()
    isolate({
      path <- project_file_for(rv$project$name)
      ok <- try(save_project_file(path), silent = TRUE)
      if (!inherits(ok, "try-error")) rv$autosaved_at <- format(Sys.time(), "%H:%M:%S")
    })
  }) |> shiny::bindEvent(autosave_state(), ignoreInit = TRUE)

  observeEvent(input$proj_load_file, {
    req(input$proj_load_file)
    path <- input$proj_load_file$datapath
    restore_project(path)
  }, ignoreInit = TRUE)

  observeEvent(input$proj_load_local, open_local_project(), ignoreInit = TRUE)
  observeEvent(input$inventory_load_local, open_local_project(), ignoreInit = TRUE)

  observeEvent(input$inventory_project_load_file, {
    req(input$inventory_project_load_file)
    restore_project(input$inventory_project_load_file$datapath)
  }, ignoreInit = TRUE)
}
