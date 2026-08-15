# ------------------------------------------------------------------------------
# Application shell: top project bar, dark left navigation, working canvas.
# ------------------------------------------------------------------------------

UFVS_NAV <- list(
  list(section = "PROJECT", items = c(
    project = "Project", data = "Data",
    keywords = "Keywords", event = "Event Monitor")),
  list(section = "INVENTORY", items = c(
    inventory = "Inventory", summary = "Stand Summary", statistics = "Statistics")),
  list(section = "MANAGEMENT", items = c(
    management = "Management Plan", volume = "Volume")),
  list(section = "SIMULATION", items = c(
    scenarios = "Scenarios", runsettings = "Run")),
  list(section = "RESULTS", items = c(
    standstock = "Stand & Stock", merch = "Merchandising", tables = "Tables",
    plots = "Charts", visualize = "Visualize", compare = "Compare")),
  list(section = "ADVANCED", items = c(
    output = "FVS Output", log = "Log")),
  list(section = "ABOUT", items = c(info = "Information"))
)

nav_button <- function(id, label) {
  tags$button(id = paste0("nav_", id), type = "button",
              class = "nav-btn action-button", label)
}

ufvs_ui <- function() {
  tagList(
    tags$head(
      tags$title("uFVS"),
      tags$link(rel = "icon", type = "image/png", href = "favicon.png"),
      # Cache-bust on the stylesheet's own timestamp. Browsers hold onto
      # www/ufvs.css aggressively, so without this a user can run a new build
      # and still see the previous layout.
      tags$link(rel = "stylesheet", href = ufvs_asset("ufvs.css")),
      tags$style(HTML("
        .shiny-notification{font-size:12.5px}
        .shiny-output-error{color:#8f1f19;font-size:12.5px}
        .shiny-output-error:before{content:'Something went wrong on this page: '}
      "))
    ),
    div(class = "ufvs-app",

      # ---- top project bar ----
      div(class = "topbar",
        div(class = "brand",
            tags$img(src = "ufvs-logo-bar.png", alt = "uFVS", class = "brand-logo")),
        div(class = "topmeta", uiOutput("topbar_meta", inline = TRUE)),
        div(class = "top-actions",
          actionButton("save_project", "Save", class = "btn"),
          actionButton("run_project", "Run", class = "btn btn-run"))
      ),

      # ---- body ----
      div(class = "body-shell",
        div(class = "sidebar",
          lapply(UFVS_NAV, function(sec) {
            div(class = "nav-section",
                h4(sec$section),
                lapply(names(sec$items), function(k) nav_button(k, sec$items[[k]])))
          }),
          div(class = "engine-box", uiOutput("engine_box"))
        ),
        div(class = "main", uiOutput("page_body"))
      ),

      # ---- status bar ----
      div(class = "statusbar",
        span(paste0("uFVS ", UFVS_VERSION)),
        span(textOutput("status_engine", inline = TRUE)),
        span(textOutput("status_data", inline = TRUE)),
        span(class = "muted status-right", "Not a USDA Forest Service product")
      )
    ),
    tags$script(HTML("
      // Keep the active navigation item highlighted.
      Shiny.addCustomMessageHandler('ufvs-page', function(page){
        document.querySelectorAll('.nav-btn').forEach(function(b){
          b.classList.toggle('active', b.id === 'nav_' + page);
        });
      });

      // Management plan cards can be reordered or dropped onto a timeline year.
      (function(){
        var lastDragAt = 0;
        function clearDropTargets(){
          document.querySelectorAll('.tl-cell.drop-target, .mg-treatment-card.drop-target')
            .forEach(function(el){ el.classList.remove('drop-target'); });
        }
        function setInput(name, value){
          if (window.Shiny) Shiny.setInputValue(name, value, {priority:'event'});
        }
        function cardIndex(card){
          return parseInt(card.getAttribute('data-event-index'), 10);
        }

        document.addEventListener('dragstart', function(event){
          var card = event.target.closest && event.target.closest('.mg-treatment-card');
          if (!card) return;
          event.dataTransfer.effectAllowed = 'move';
          event.dataTransfer.setData('text/plain', String(cardIndex(card)));
          card.classList.add('dragging');
        });

        document.addEventListener('dragend', function(event){
          var card = event.target.closest && event.target.closest('.mg-treatment-card');
          if (card) card.classList.remove('dragging');
          lastDragAt = Date.now();
          clearDropTargets();
        });

        // Browsers may emit a click immediately after a drag. Do not let that
        // stale click select the card's old index after the board is reordered.
        document.addEventListener('click', function(event){
          if (Date.now() - lastDragAt >= 500) return;
          var card = event.target.closest && event.target.closest('.mg-treatment-card');
          if (card) {
            event.preventDefault();
            event.stopPropagation();
          }
        }, true);

        document.addEventListener('dragover', function(event){
          var cell = event.target.closest && event.target.closest('.tl-cell');
          var board = event.target.closest && event.target.closest('.mg-activity-board');
          if (!cell && !board) return;
          event.preventDefault();
          if (event.dataTransfer) event.dataTransfer.dropEffect = 'move';
          clearDropTargets();
          if (cell) cell.classList.add('drop-target');
          else if (event.target.closest('.mg-treatment-card'))
            event.target.closest('.mg-treatment-card').classList.add('drop-target');
        });

        document.addEventListener('drop', function(event){
          var cell = event.target.closest && event.target.closest('.tl-cell');
          var board = event.target.closest && event.target.closest('.mg-activity-board');
          if (!cell && !board) return;
          event.preventDefault();
          clearDropTargets();
          var index = parseInt(event.dataTransfer.getData('text/plain'), 10);
          if (!Number.isFinite(index)) return;

          if (cell) {
            var year = parseInt(cell.getAttribute('data-timeline-year'), 10);
            if (Number.isFinite(year))
              setInput('mg_drop_year', {index:index, year:year, nonce:Date.now()});
            return;
          }

          var dragged = Array.from(board.querySelectorAll('.mg-treatment-card'))
            .find(function(card){ return cardIndex(card) === index; });
          var target = event.target.closest && event.target.closest('.mg-treatment-card');
          if (!dragged || !target || dragged === target) return;
          var rect = target.getBoundingClientRect();
          if (event.clientY < rect.top + rect.height / 2)
            target.parentNode.insertBefore(dragged, target);
          else
            target.parentNode.insertBefore(dragged, target.nextSibling);
          var order = Array.from(board.querySelectorAll('.mg-treatment-card'))
            .map(cardIndex);
          setInput('mg_reorder', {order:order, nonce:Date.now()});
        });
      }());
    "))
  )
}

# ------------------------------------------------------------------------------
# Small presentation helpers shared by the pages
# ------------------------------------------------------------------------------

page_head <- function(title, blurb = NULL, aside = NULL) {
  div(class = "page-head",
      div(h1(title), if (!is.null(blurb)) p(blurb)),
      if (!is.null(aside)) div(class = "head-actions", aside))
}

card <- function(title = NULL, ..., sub = NULL, class = "") {
  div(class = paste("card", class),
      if (!is.null(title)) h3(title, if (!is.null(sub)) span(class = "sub", sub)),
      ...)
}

msg_box <- function(type, ...) div(class = paste0("msg msg-", type), ...)

tile <- function(label, value, note = NULL) {
  div(class = "tile",
      div(class = "label", label),
      div(class = "value", value),
      if (!is.null(note)) div(class = "note", note))
}

empty_state <- function(headline, detail) {
  div(class = "empty-state", div(class = "big", headline), div(detail))
}

#' Render a data.frame as a clean HTML table.
#'
#' Deliberately plain: uFVS tables are read and copied out, so they need to be
#' legible and stable rather than interactive.
#' Sensible display precision for the FVS output columns, so tables do not show
#' cubic feet to two decimals or trees per acre to none.
UFVS_COL_DIGITS <- list(
  Tpa = 1, TPA = 1, BA = 1, QMD = 1, GMD = 1, TopHt = 0, Age = 0, Year = 0,
  SDI = 0, ZeideSDI = 0, ReinekeSDI = 0, SDIMax = 0, RDSDI = 2, CCF = 0,
  TCuFt = 0, MCuFt = 0, SCuFt = 0, BdFt = 0, MBF = 2,
  TPrdTpa = 1, TPrdTCuFt = 0, TPrdMCuFt = 0, TPrdSCuFt = 0, TPrdBdFt = 0,
  RTpa = 1, RTCuFt = 0, RMCuFt = 0, RSCuFt = 0, RBdFt = 0,
  Acc = 1, Mort = 1, MAI = 1, PrdLen = 0, TREES = 0, Trees = 0)

ufvs_table <- function(df, digits = NULL, total_row = NULL, align_left = 1) {
  # Explicit digits win; otherwise fall back to the known column precision.
  digits <- utils::modifyList(UFVS_COL_DIGITS, as.list(nz(digits, list())))
  if (is.null(df) || !nrow(df)) return(div(class = "muted small", "No rows."))
  fmt_col <- function(x, nm) {
    if (is.numeric(x)) {
      d <- if (!is.null(digits) && nm %in% names(digits)) digits[[nm]] else
        if (all(is.na(x)) || all(x == round(x), na.rm = TRUE)) 0 else 2
      fmt_num(x, d)
    } else {
      ifelse(is.na(x), "—", as.character(x))
    }
  }
  body <- lapply(seq_len(nrow(df)), function(i) {
    cls <- if (!is.null(total_row) && i %in% total_row) "total-row" else NULL
    tags$tr(class = cls, lapply(seq_along(df), function(j) {
      tags$td(fmt_col(df[[j]], names(df)[j])[i])
    }))
  })
  div(class = "table-scroll",
      tags$table(class = "ufvs",
        tags$thead(tags$tr(lapply(names(df), function(n) tags$th(n)))),
        tags$tbody(body)))
}

#' Validation issues rendered as a readable list.
issues_list <- function(issues, limit = 40) {
  if (is.null(issues)) {
    return(div(class = "muted small", "Load an inventory to see validation results."))
  }
  if (!nrow(issues)) {
    return(msg_box("ok", "No validation problems found."))
  }
  ord <- order(match(issues$severity, c("error", "warning", "note")))
  issues <- issues[ord, , drop = FALSE]
  shown <- utils::head(issues, limit)
  tagList(
    lapply(seq_len(nrow(shown)), function(i) {
      r <- shown[i, ]
      div(class = "issue-row",
          div(class = paste0("sev sev-", r$severity), r$severity),
          div(strong(r$message),
              if (nzchar(nz(r$detail, ""))) div(class = "issue-detail", r$detail),
              if (!identical(r$stand, "*")) div(class = "issue-detail small",
                                                paste("Stand", r$stand))))
    }),
    if (nrow(issues) > limit)
      div(class = "muted small", sprintf("...and %d more.", nrow(issues) - limit))
  )
}

method_note <- function(...) div(class = "method-note", ...)

#' A scenario picker used by every results page.
#'
#' Results pages default to every scenario that has been run, so comparing them
#' is the normal case rather than something to be set up each time.
scenario_picker <- function(id, choices, selected, multiple = TRUE,
                            label = "Scenarios") {
  if (!length(choices)) {
    return(div(class = "muted small", "No scenario has been run yet."))
  }
  if (length(choices) == 1 && multiple) {
    return(div(class = "muted small",
               sprintf("Showing %s. Run another scenario to compare.", choices[1])))
  }
  selectInput(id, label, choices = choices, selected = selected,
              multiple = multiple)
}

#' A year picker driven by the years actually present in the results.
year_picker <- function(id, years, selected, label = "Year", multiple = FALSE) {
  years <- sort(unique(years[!is.na(years)]))
  if (!length(years)) return(NULL)
  selectInput(id, label, choices = years,
              selected = if (is.null(selected) || !selected %in% years) years[1] else selected,
              multiple = multiple)
}
