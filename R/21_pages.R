# ------------------------------------------------------------------------------
# Page layouts.
#
# Pages describe structure; the server fills the data-dependent parts.
# Keep copy short. The interface should show numbers, not explain itself.
# ------------------------------------------------------------------------------

page_project <- function() {
  tagList(
    page_head("Project"),
    div(class = "grid-2",
      card("Details", uiOutput("proj_details")),
      card("Dataset", uiOutput("project_dataset"))),
    div(class = "grid-2",
      card("Save",
        actionButton("proj_save", "Save project", class = "btn-default"),
        downloadButton("proj_download", "Download project", class = "btn-default"),
        div(class = "muted small", style = "margin-top:6px", uiOutput("proj_save_note"))),
      card("Open",
        actionButton("proj_load_local", "Open saved project", class = "btn-default"),
        fileInput("proj_load_file", NULL, accept = c(".json", ".ufvs.json"),
                  buttonLabel = "Browse", placeholder = "No file selected"),
        uiOutput("proj_recent"))),
    card("Build", uiOutput("project_repro")),
    card("Validation", uiOutput("project_issues"))
  )
}

page_data <- function() {
  tagList(
    page_head("Data"),
    div(class = "grid-side",
      div(class = "col",
        card("Import",
          # multiple = TRUE because the CSV route needs both FVS tables. A
          # single ordinary CSV is not an FVS inventory, and the control used
          # to imply otherwise.
          fileInput("data_file", NULL, multiple = TRUE,
                    accept = c(".xlsx", ".xls", ".db", ".sqlite", ".sqlite3", ".csv"),
                    buttonLabel = "Browse", placeholder = "No file selected"),
          div(class = "muted small",
              "One FVS input database (.db) or workbook (.xlsx) with FVS_StandInit ",
              "and FVS_TreeInit. For CSVs, select the FVS_StandInit and FVS_TreeInit ",
              "files together (FVS_PlotInit optional); uFVS matches them by name.")),
        card("Design", uiOutput("data_design"))),
      div(class = "col",
        card("Tables", uiOutput("data_tables")),
        card("Validation", uiOutput("data_issues"))))
  )
}

page_inventory <- function() {
  tagList(
    page_head("Inventory"),
    card("Project",
      actionButton("inventory_load_local", "Open saved project", class = "btn-default"),
      fileInput("inventory_project_load_file", NULL,
                accept = c(".json", ".ufvs.json"),
                buttonLabel = "Browse", placeholder = "Open a project file"),
      div(class = "muted small", "Open a project saved on this computer or a downloaded .ufvs.json file.")),
    uiOutput("inv_tiles"),
    div(class = "grid-2",
      card("Species", uiOutput("inv_species")),
      card("Diameter distribution",
        div(class = "inline-checks",
          checkboxInput("dbh_by_species", "Show species", FALSE),
          conditionalPanel("input.dbh_by_species == true",
            checkboxInput("dbh_separate", "Separate species panels", FALSE))),
        plotOutput("inv_dbh_plot", height = "290px"))),
    card("Plots", uiOutput("inv_plots")),
    card("Trees", uiOutput("inv_trees"))
  )
}

page_summary <- function() {
  tagList(
    page_head("Stand Summary"),
    card("Species", uiOutput("summary_species_picker")),
    uiOutput("summary_body"))
}

# ------------------------------------------------------------------------------
# Statistics
# ------------------------------------------------------------------------------

stat_checkbox_group <- function(group_id, title, ids, selected) {
  defs <- Filter(function(d) d$group == group_id, STAT_DEFS)
  div(class = "stat-group",
      h4(title),
      checkboxGroupInput(ids, NULL,
        choices = stats::setNames(vapply(defs, function(d) d$id, character(1)),
                                  vapply(defs, function(d) d$label, character(1))),
        selected = intersect(vapply(defs, function(d) d$id, character(1)), selected)))
}

page_statistics <- function(settings) {
  tagList(
    page_head("Statistics", "Adds columns to the inventory, stand & stock, and merchandising tables."),
    div(class = "grid-side",
      div(class = "col",
        card("Preset",
          selectInput("stat_preset", NULL,
            choices = c("Basic" = "basic", "Cruise QC" = "cruise_qc",
                        "Full" = "full", "Custom" = "custom"),
            selected = nz(settings$preset, "basic"))),
        card("Confidence",
          numericInput("stat_conf", "Level (%)",
                       value = nz(settings$confidence_level, 95), min = 0.01, max = 99.99, step = 0.5),
          checkboxInput("stat_fpc", "Finite population correction", value = isTRUE(settings$fpc)),
          conditionalPanel("input.stat_fpc == true",
            numericInput("stat_pop", "Population plots (N)",
                         value = settings$population_plots, min = 1))),
        card("Plots required",
          checkboxInput("plots_enable", "Estimate plots required", FALSE),
          conditionalPanel("input.plots_enable == true",
            numericInput("plots_target", "Target sampling error (%)", 7.5, min = 0.1, step = 0.5),
            selectInput("plots_var", "Design variable",
                        choices = c("Basal area" = "BA", "Trees per acre" = "TPA")),
            uiOutput("plots_required")))),
      div(class = "col",
        card("Show",
          div(class = "grid-3",
            stat_checkbox_group("precision", "Precision", "stat_precision", settings$stats),
            stat_checkbox_group("descriptive", "Descriptive", "stat_descriptive", settings$stats),
            stat_checkbox_group("detail", "Detail", "stat_detail", settings$stats))),
        card("Preview", uiOutput("stat_preview"))))
  )
}

# ------------------------------------------------------------------------------
# Management
# ------------------------------------------------------------------------------

page_management <- function() {
  tagList(
    page_head("Management Plan",
              "Pick a treatment on the left, drop it on a year, then set its fields.",
              aside = tagList(
                actionButton("mg_delete", "Remove selected", class = "btn-default"))),
    uiOutput("mg_scenario_bar"),
    card("Timeline", uiOutput("mg_timeline")),
    div(class = "grid-side",
      # The treatment catalog now lives beside the plan, so choosing a
      # treatment and scheduling it happen in one place.
      card("Treatments", sub = "click to add to the plan",
        textInput("tl_search", "Search", placeholder = "thin, fire, fertil..."),
        uiOutput("tl_list"),
        div(class = "muted small", uiOutput("tl_count", inline = TRUE))),
      div(class = "col",
        card("Scheduled", uiOutput("mg_activity_board"),
             sub = "click to edit \u00b7 drag to reorder or move to a year"),
        div(class = "grid-side-r",
          card("Edit selected treatment", uiOutput("mg_editor")),
          div(class = "col",
            card("Keyword", uiOutput("mg_keyword_preview")),
            card("Treatment reference", uiOutput("tl_detail")),
            card("Raw keywords",
              textAreaInput("mg_raw", NULL, "", rows = 6,
                            placeholder = "Appended to this scenario verbatim.")))))))
}

page_volume <- function() {
  tagList(
    page_head("Volume & Merchantability", "Volume is computed by FVS. These are the FVS keywords that control it."),
    div(class = "grid-side",
      card("Controls",
        checkboxInput("vol_defaults", "Use variant defaults", TRUE),
        conditionalPanel("input.vol_defaults == false",
          uiOutput("vol_picker"),
          actionButton("vol_add", "Add", class = "btn-default"))),
      div(class = "col",
        card("Keywords", uiOutput("vol_forms")),
        card("Records", uiOutput("vol_preview"))))
  )
}

# ------------------------------------------------------------------------------
# Simulation
# ------------------------------------------------------------------------------

page_scenarios <- function() {
  tagList(
    page_head("Scenarios", aside = tagList(
      actionButton("sc_new", "New", class = "btn-default"),
      actionButton("sc_copy", "Duplicate", class = "btn-default"),
      actionButton("sc_delete", "Delete", class = "btn-default"),
      actionButton("sc_run_all", "Run all", class = "btn-go"))),
    card("Scenarios", uiOutput("sc_table")),
    div(class = "grid-2",
      card("Selected scenario", uiOutput("sc_settings")),
      card("Status", uiOutput("sc_run_status")))
  )
}

page_runsettings <- function() {
  tagList(
    page_head("Run"),
    div(class = "grid-2",
      card("Engine",
        uiOutput("eng_controls"),
        div(class = "muted small", uiOutput("eng_hint", inline = TRUE)),
        actionButton("eng_save", "Save", class = "btn-default"),
        div(class = "spacer"),
        uiOutput("eng_status_detail")),
      card("Projection",
        numericInput("run_cycles", "Cycles", 10, min = 1, max = 40),
        numericInput("run_cyclelen", "Cycle length (years)", 5, min = 1, max = 20),
        checkboxInput("run_batch", "One job per stand", TRUE),
        checkboxInput("run_svs", "Write stand visualization files", TRUE),
        div(class = "spacer"),
        actionButton("run_start", "Run FVS", class = "btn-go"))),
    card("Status", uiOutput("run_status_box")),
    card("History", uiOutput("run_history"))
  )
}

# ------------------------------------------------------------------------------
# Results
# ------------------------------------------------------------------------------

page_standstock <- function() {
  tagList(
    page_head("Stand & Stock",
              "Projected stand and species values by scenario, variant, and year."),
    card("Show", uiOutput("ss_controls")),
    uiOutput("ss_body")
  )
}

page_merch <- function() {
  tagList(
    page_head("Merchandising", aside = tagList(
      actionButton("merch_add", "Add class", class = "btn-default"))),
    card("Product classes", uiOutput("merch_products")),
    uiOutput("merch_source_note"),
    card("By class", uiOutput("merch_table")),
    card("By class and species", uiOutput("merch_species_table")),
    uiOutput("merch_reconcile")
  )
}

page_tables <- function() {
  tagList(
    page_head("Tables", "Build one table or separate tables for the scenarios you select."),
    div(class = "grid-side",
      card("Build", uiOutput("tb_controls")),
      card("Result", uiOutput("tb_result")))
  )
}

page_plots <- function() {
  tagList(
    page_head("Plots & Charts"),
    div(class = "grid-side",
      # Built server-side so the variable lists always reflect the run that is
      # loaded. Pushing choices with updateSelectInput fails silently whenever
      # this page is not the one currently rendered.
      card("Chart", uiOutput("ch_controls")),
      div(class = "col",
        uiOutput("ch_validation"),
        card(NULL, plotOutput("ch_plot", height = "420px")),
        card("Data", uiOutput("ch_data"))))
  )
}

page_visualize <- function() {
  tagList(
    page_head("Visualize", "Stand pictures drawn from the SVS files FVS writes."),
    uiOutput("svs_controls"),
    uiOutput("svs_body")
  )
}

page_compare <- function() {
  tagList(page_head("Compare"), uiOutput("cmp_body"))
}

page_output <- function() {
  tagList(page_head("FVS Output"), uiOutput("out_body"))
}

page_log <- function() {
  tagList(page_head("Log"), uiOutput("log_body"))
}

page_keywords <- function() {
  tagList(
    page_head("Keywords"),
    div(class = "grid-side-r",
      card("Keyword file", uiOutput("kw_file")),
      card("Catalog", uiOutput("kw_catalog_summary")))
  )
}

page_event <- function() {
  tagList(
    page_head("Event Monitor"),
    div(class = "grid-side",
      card("Add",
        textInput("em_name", "Variable", placeholder = "BAREMOVED"),
        textAreaInput("em_expr", "Expression", rows = 3, placeholder = "BBA - ABA"),
        selectInput("em_when", "Evaluate", c("Every cycle" = "0", "Before treatment" = "1",
                                             "After treatment" = "2")),
        actionButton("em_add", "Add", class = "btn-default")),
      div(class = "col",
        card("Expressions", uiOutput("em_list")),
        card("Reference", uiOutput("em_reference"))))
  )
}
