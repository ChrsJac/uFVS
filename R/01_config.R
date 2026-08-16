# ------------------------------------------------------------------------------
# Application constants, paths, and reference-table loading.
# ------------------------------------------------------------------------------

UFVS_VERSION <- "0.1.0"

# Root of the installed app. app.R sets this; fall back to the working directory
# so the modules can also be sourced directly in a console session.
ufvs_root <- function() getOption("ufvs.root", getwd())
ufvs_config_dir <- function() file.path(ufvs_root(), "config")

# Packaged mode moves the runtime, the private package library, the FVS engine,
# and the read-only resources out of the application directory: on Windows they
# sit beside uFVS.exe, on macOS they sit inside uFVS.app/Contents/Resources. The
# launcher is the only thing that knows the packaged shape, and it says so
# through these variables. A source checkout sets none of them and keeps using
# the directories beside app.R, so development mode is unaffected.
ufvs_layout_dir <- function(variable, default) {
  value <- Sys.getenv(variable, unset = "")
  if (!nzchar(value)) return(default)
  normalizePath(value, mustWork = FALSE)
}

# Read-only material shipped with a release: BUILD_INFO.json, notices, docs.
ufvs_resources_dir <- function() ufvs_layout_dir("UFVS_RESOURCES_DIR", ufvs_root())

# A release has its own R runtime, package library, and platform-specific FVS
# engine. Keep this test in one place so the launcher, app, and data paths
# cannot accidentally disagree about whether the app is portable.
ufvs_is_release <- function() {
  override <- getOption("ufvs.release", NULL)
  if (!is.null(override)) return(isTRUE(override))
  env <- tolower(Sys.getenv("UFVS_RELEASE", unset = ""))
  if (env %in% c("1", "true", "yes", "y")) return(TRUE)
  file.exists(file.path(ufvs_resources_dir(), "BUILD_INFO.json")) &&
    dir.exists(ufvs_runtime_dir())
}

ufvs_release_info_path <- function() file.path(ufvs_resources_dir(), "BUILD_INFO.json")

# --- desktop lifecycle ---------------------------------------------------------
# In a packaged release the browser window *is* the application window. When the
# user closes it, uFVS has to exit: otherwise a headless R process and any FVS
# workers it started would keep running with nothing to show for them. The
# launchers export UFVS_DESKTOP to ask for that behaviour. A developer running
# shiny::runApp() from an R session never sets it, so closing a tab during
# development still leaves the app running.
ufvs_desktop_mode <- function() {
  tolower(Sys.getenv("UFVS_DESKTOP", unset = "")) %in% c("1", "true", "yes", "y")
}

#' Grace period before an empty application quits.
#'
#' A page reload ends one session and starts another a moment later, so quitting
#' the instant the count reaches zero would kill the app whenever the user hits
#' refresh. The wait is what distinguishes a reload from a close.
ufvs_idle_shutdown_seconds <- function() {
  v <- suppressWarnings(as.numeric(Sys.getenv("UFVS_IDLE_SECONDS", unset = "")))
  if (length(v) != 1L || is.na(v) || v < 1) 10 else v
}

.ufvs_lifecycle <- new.env(parent = emptyenv())
.ufvs_lifecycle$sessions <- 0L

#' Tie the lifetime of a packaged uFVS process to its browser windows.
ufvs_register_desktop_lifecycle <- function(session) {
  if (!ufvs_desktop_mode()) return(invisible(FALSE))
  .ufvs_lifecycle$sessions <- .ufvs_lifecycle$sessions + 1L

  quit_now <- function() {
    if (.ufvs_lifecycle$sessions > 0L) return(invisible(NULL))
    message("uFVS: last browser window closed; shutting down.")
    # stopApp() unwinds runApp() so its own cleanup runs. If it is ever called
    # from outside an app context it raises, and the process must still exit,
    # or closing the window would leave uFVS running invisibly forever.
    ok <- tryCatch({ shiny::stopApp(); TRUE }, error = function(e) FALSE)
    if (!ok) quit(save = "no", status = 0L, runLast = FALSE)
    invisible(NULL)
  }

  session$onSessionEnded(function() {
    .ufvs_lifecycle$sessions <- max(0L, .ufvs_lifecycle$sessions - 1L)
    if (.ufvs_lifecycle$sessions > 0L) return(invisible(NULL))
    if (requireNamespace("later", quietly = TRUE)) {
      later::later(quit_now, delay = ufvs_idle_shutdown_seconds())
    } else {
      quit_now()
    }
  })
  invisible(TRUE)
}

ufvs_release_info <- function() {
  p <- ufvs_release_info_path()
  if (!file.exists(p) || !requireNamespace("jsonlite", quietly = TRUE)) return(NULL)
  out <- try(jsonlite::fromJSON(p, simplifyVector = FALSE), silent = TRUE)
  if (inherits(out, "try-error") || !is.list(out)) NULL else out
}

ufvs_runtime_dir <- function() {
  ufvs_layout_dir("UFVS_RUNTIME_DIR", file.path(ufvs_root(), "runtime"))
}
ufvs_bundled_library <- function() {
  ufvs_layout_dir("UFVS_LIBRARY_DIR", file.path(ufvs_root(), "library"))
}

# This is the path callr workers should inherit in a release.  The macOS build
# supplies a relocatable wrapper; Windows uses the bundled Rscript.exe.
ufvs_bundled_rscript <- function() {
  if (.Platform$OS.type == "windows") {
    file.path(ufvs_runtime_dir(), "R", "bin", "Rscript.exe")
  } else {
    direct <- file.path(ufvs_runtime_dir(), "Rscript")
    if (file.exists(direct)) direct else {
      f <- list.files(ufvs_runtime_dir(), pattern = "^Rscript$", recursive = TRUE,
                      full.names = TRUE)
      if (length(f)) f[1] else direct
    }
  }
}

# Runtime state must not require write access to the directory containing the
# application. This matters on Windows when uFVS is unpacked below a protected
# directory, and it makes a read-only copy of the app portable.
ufvs_user_data_dir <- function() {
  override <- getOption("ufvs.user_dir", "")
  if (nzchar(override)) {
    dir.create(override, showWarnings = FALSE, recursive = TRUE)
    return(normalizePath(override, mustWork = FALSE))
  }

  # Extracted release folders may be read-only (Program Files, a mounted disk,
  # or a user's Downloads quarantine). Never put mutable state beside them.
  if (ufvs_is_release()) {
    home <- path.expand("~")
    base <- if (.Platform$OS.type == "windows") {
      x <- Sys.getenv("LOCALAPPDATA", unset = "")
      if (is_blank(x)) x <- Sys.getenv("APPDATA", unset = "")
      if (is_blank(x)) home else x
    } else if (identical(Sys.info()[["sysname"]], "Darwin")) {
      file.path(home, "Library", "Application Support")
    } else {
      x <- Sys.getenv("XDG_DATA_HOME", unset = "")
      if (is_blank(x)) file.path(home, ".local", "share") else x
    }
    out <- file.path(base, "uFVS")
    dir.create(out, showWarnings = FALSE, recursive = TRUE)
    return(normalizePath(out, mustWork = FALSE))
  }

  local <- file.path(ufvs_root(), ".ufvs-data")
  if (!dir.exists(local)) dir.create(local, showWarnings = FALSE, recursive = TRUE)
  if (dir.exists(local) && file.access(local, mode = 2) == 0) return(local)

  home <- path.expand("~")
  base <- if (.Platform$OS.type == "windows") {
    x <- Sys.getenv("LOCALAPPDATA", unset = "")
    if (is_blank(x)) x <- Sys.getenv("APPDATA", unset = "")
    if (is_blank(x)) home else x
  } else if (identical(Sys.info()[["sysname"]], "Darwin")) {
    file.path(home, "Library", "Application Support")
  } else {
    x <- Sys.getenv("XDG_DATA_HOME", unset = "")
    if (is_blank(x)) file.path(home, ".local", "share") else x
  }
  out <- file.path(base, "uFVS")
  dir.create(out, showWarnings = FALSE, recursive = TRUE)
  out
}

ufvs_runs_dir <- function() {
  d <- getOption("ufvs.runs_dir", file.path(ufvs_user_data_dir(), "runs"))
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  d
}
ufvs_project_path <- function() file.path(ufvs_user_data_dir(), "project.json")

#' Folder holding saved projects, one file each.
#'
#' Lives beside the application when that is writable so projects are easy to
#' find, and falls back to the user data directory otherwise.
ufvs_projects_dir <- function() {
  if (ufvs_is_release()) {
    d <- file.path(ufvs_user_data_dir(), "projects")
    dir.create(d, showWarnings = FALSE, recursive = TRUE)
    return(d)
  }
  local <- file.path(ufvs_root(), "projects")
  if (!dir.exists(local)) dir.create(local, showWarnings = FALSE, recursive = TRUE)
  if (dir.exists(local) && file.access(local, mode = 2) == 0) return(local)
  d <- file.path(ufvs_user_data_dir(), "projects")
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  d
}

#' A filesystem-safe file name for a project.
project_file_for <- function(name, dir = ufvs_projects_dir()) {
  stem <- gsub("[^A-Za-z0-9._-]+", "_", nz(name, "Untitled project"))
  stem <- sub("^_+|_+$", "", stem)
  if (!nzchar(stem)) stem <- "Untitled_project"
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  file.path(dir, paste0(stem, ".ufvs.json"))
}

#' Saved projects, newest first.
list_projects <- function(dir = ufvs_projects_dir()) {
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  f <- list.files(dir, pattern = "\\.json$", full.names = TRUE)
  if (!length(f)) {
    return(data.frame(name = character(0), path = character(0),
                      modified = character(0), stringsAsFactors = FALSE))
  }
  info <- file.info(f)
  out <- data.frame(
    name = sub("\\.ufvs\\.json$|\\.json$", "", basename(f)),
    path = f,
    modified = format(info$mtime, "%Y-%m-%d %H:%M"),
    stringsAsFactors = FALSE)
  out[order(info$mtime, decreasing = TRUE), , drop = FALSE]
}

# --- reference tables (cached) -------------------------------------------------
.ufvs_cache <- new.env(parent = emptyenv())

cached <- function(key, fn) {
  if (is.null(.ufvs_cache[[key]])) .ufvs_cache[[key]] <- fn()
  .ufvs_cache[[key]]
}

#' Per-variant DESIGN defaults transcribed from <variant>/grinit.f.
#'
#' FVS applies these when the corresponding inventory field is absent. uFVS must
#' apply the same defaults or its per-acre expansion will disagree with FVS.
variant_design_defaults <- function() {
  cached("design", function() read_config_csv("variant_design_defaults.csv"))
}

variant_species <- function() {
  cached("species", function() {
    read_config_csv("variant_species.csv", char_cols = c("fia_code", "plants_symbol", "species_code"))
  })
}

known_variants <- function() sort(unique(variant_design_defaults()$variant))

#' DESIGN defaults for one variant, falling back to the FVS common default set.
design_defaults_for <- function(variant) {
  d <- variant_design_defaults()
  row <- d[tolower(d$variant) == tolower(variant %||% ""), , drop = FALSE]
  if (!nrow(row)) row <- data.frame(baf = 40, fpa = 300, brk = 5, tfpa = 0)
  list(baf = row$baf[1], fpa = row$fpa[1], brk = row$brk[1], tfpa = row$tfpa[1])
}

species_for_variant <- function(variant) {
  s <- variant_species()
  s[tolower(s$variant) == tolower(variant %||% ""), , drop = FALSE]
}

treatment_catalog <- function() {
  cached("treatments", function() read_config_csv("treatment_catalog.csv"))
}

treatment_fields <- function() {
  cached("treatment_fields", function() read_config_csv("treatment_fields.csv"))
}

variable_metadata <- function() {
  cached("varmeta", function() read_config_csv("variable_metadata.csv"))
}

species_green_weight <- function() {
  cached("greenwt", function() read_config_csv("species_green_weight.csv"))
}

# --- engine configuration ------------------------------------------------------
# The engine setting is machine-specific, so keep it beside the user's runtime
# data rather than inside the application folder. uFVS still reads reference
# tables from config/; only the mutable setting moves out of the distribution.
ufvs_engine_config_path <- function() file.path(ufvs_user_data_dir(), "engine.json")

#' Directory holding FVS binaries: engine/ in a source checkout, and the
#' packaged fvs/ directory when a release launcher names it.
ufvs_engine_dir <- function() {
  ufvs_layout_dir("UFVS_FVS_DIR", file.path(ufvs_root(), "engine"))
}

#' Whether a file can be launched on this platform.
engine_is_executable <- function(path) {
  if (!file.exists(path)) return(FALSE)
  # Windows does not expose Unix execute bits in the same way. The .exe suffix
  # is the relevant check there; file.access(..., 1) can be false for a valid
  # executable copied from another machine.
  if (.Platform$OS.type == "windows") TRUE else file.access(path, mode = 1) == 0
}

#' Executable variant names in one directory.
engine_variants_in_dir <- function(dir) {
  if (!dir.exists(dir)) return(character(0))
  pat <- if (.Platform$OS.type == "windows") "^FVS[a-z]{2,3}[.]exe$"
         else "^FVS[a-z]{2,3}$"
  f <- list.files(dir, pattern = pat, ignore.case = TRUE)
  f <- f[engine_is_executable(file.path(dir, f))]
  sort(unique(tolower(sub("^FVS", "", sub("[.]exe$", "", f, ignore.case = TRUE),
                               ignore.case = TRUE))))
}

#' Candidate directories containing an already-installed official FVS build.
engine_directory_candidates <- function() {
  out <- ufvs_engine_dir()
  if (ufvs_is_release()) return(out)
  if (.Platform$OS.type == "windows") {
    pf <- Sys.getenv("ProgramFiles", unset = "")
    pf32 <- Sys.getenv("ProgramFiles(x86)", unset = "")
    out <- c(out,
             file.path(path.expand("~"), "FVS"),
             "C:/FVS",
             "C:/FVS/FVSbin",
             "C:/FVS/bin",
             if (nzchar(pf)) file.path(pf, "FVS") else character(0),
             if (nzchar(pf)) file.path(pf, "FVS", "bin") else character(0),
             if (nzchar(pf32)) file.path(pf32, "FVS") else character(0),
             if (nzchar(pf32)) file.path(pf32, "FVS", "bin") else character(0))
  }
  unique(out[!is.na(out) & nzchar(out)])
}

#' FVS variants that ship with this copy of uFVS.
bundled_variants <- function() engine_variants_in_dir(ufvs_engine_dir())

#' First directory containing one or more usable variant executables.
discover_engine_dir <- function() {
  dirs <- engine_directory_candidates()
  hit <- vapply(dirs, function(d) length(engine_variants_in_dir(d)) > 0, logical(1))
  if (any(hit)) dirs[which(hit)[1]] else NA_character_
}

#' Path to the bundled executable for a variant, if one was built.
bundled_engine_path <- function(variant) {
  d <- ufvs_engine_dir()
  if (!dir.exists(d)) return(NA_character_)
  candidates <- if (.Platform$OS.type == "windows") {
    file.path(d, c(paste0("FVS", tolower(variant), ".exe"),
                  paste0("FVS", toupper(variant), ".EXE")))
  } else {
    file.path(d, paste0("FVS", tolower(variant)))
  }
  hit <- candidates[engine_is_executable(candidates)]
  if (length(hit)) hit[1] else NA_character_
}

default_engine_config <- function() {
  # Prefer whatever was built into engine/; on Windows also recognize the
  # standard directory used by the official FVS installer.
  d <- discover_engine_dir()
  if (!is.na(d)) {
    note <- if (normalizePath(d, mustWork = FALSE) ==
                normalizePath(ufvs_engine_dir(), mustWork = FALSE)) {
      "Using the FVS build shipped with this copy of uFVS."
    } else {
      "Using the FVS build found in the standard installation directory."
    }
    return(list(mode = "bundled", path = d, note = note))
  }
  list(
    mode = "none",          # "none" | "bundled" | "executable" | "library"
    path = "",
    note = "No FVS engine configured. Inventory analysis is available; projection requires an official FVS build."
  )
}

load_engine_config <- function() {
  # A release is intentionally self-contained. Ignore a stale developer
  # setting in the user's data directory so it cannot redirect a release to a
  # different binary or make a clean-machine run depend on an installation.
  if (ufvs_is_release()) return(default_engine_config())
  p <- ufvs_engine_config_path()
  if (!file.exists(p)) return(default_engine_config())
  out <- try(jsonlite::fromJSON(p, simplifyVector = TRUE), silent = TRUE)
  if (inherits(out, "try-error") || !is.list(out)) return(default_engine_config())
  cfg <- utils::modifyList(default_engine_config(), out)
  usable <- switch(nz(cfg$mode, "none"),
    bundled = length(engine_variants_in_dir(nz(cfg$path, ""))) > 0,
    executable = engine_is_executable(nz(cfg$path, "")),
    library = dir.exists(nz(cfg$path, "")),
    FALSE)
  # A stale saved setting should not mask an engine that has since been built.
  if (!usable && !is.na(discover_engine_dir())) return(default_engine_config())
  cfg
}

save_engine_config <- function(cfg) {
  dir.create(dirname(ufvs_engine_config_path()), showWarnings = FALSE, recursive = TRUE)
  jsonlite::write_json(cfg, ufvs_engine_config_path(), auto_unbox = TRUE, pretty = TRUE)
  invisible(cfg)
}

#' Probe the configured engine and report what is actually usable.
engine_status <- function(cfg = load_engine_config()) {
  if (identical(cfg$mode, "bundled")) {
    d <- nz(cfg$path, ufvs_engine_dir())
    v <- engine_variants_in_dir(d)
    if (!length(v)) {
      return(list(ok = FALSE, level = "error", label = "No bundled build found",
                  detail = paste0("Nothing executable in ", d),
                  variants = character(0)))
    }
    return(list(ok = TRUE, level = "ready",
                label = paste0("Bundled (", paste(toupper(v), collapse = ", "), ")"),
                detail = d, variants = v))
  }
  if (identical(cfg$mode, "none") || is_blank(cfg$path)) {
    return(list(ok = FALSE, level = "none", label = "Not configured",
                detail = "Set an FVS executable or shared-library directory in Run Settings.",
                variants = character(0)))
  }
  if (identical(cfg$mode, "executable")) {
    if (!file.exists(cfg$path)) {
      return(list(ok = FALSE, level = "error", label = "Path not found",
                  detail = paste0("No file at ", cfg$path), variants = character(0)))
    }
    exec_ok <- engine_is_executable(cfg$path)
    return(list(ok = exec_ok, level = if (exec_ok) "ready" else "error",
                label = if (exec_ok) "Executable ready" else "Not executable",
                detail = cfg$path,
                variants = engine_variant_from_name(basename(cfg$path))))
  }
  if (identical(cfg$mode, "library")) {
    if (!dir.exists(cfg$path)) {
      return(list(ok = FALSE, level = "error", label = "Directory not found",
                  detail = paste0("No directory at ", cfg$path), variants = character(0)))
    }
    libs <- list.files(cfg$path,
                       pattern = paste0("^FVS[a-z]{2,3}\\", .Platform$dynlib.ext, "$"),
                       ignore.case = TRUE)
    if (!length(libs)) {
      return(list(ok = FALSE, level = "error", label = "No FVS libraries found",
                  detail = paste0("No FVS*", .Platform$dynlib.ext, " in ", cfg$path),
                  variants = character(0)))
    }
    return(list(ok = TRUE, level = "ready",
                label = paste0(length(libs), " variant librar", if (length(libs) == 1) "y" else "ies"),
                detail = cfg$path,
                variants = tolower(sub("\\..*$", "", sub("^FVS", "", libs,
                                                              ignore.case = TRUE),
                                       ignore.case = TRUE))))
  }
  list(ok = FALSE, level = "none", label = "Unknown mode", detail = "", variants = character(0))
}

engine_variant_from_name <- function(nm) {
  m <- regmatches(nm, regexpr("(?i)FVS([a-z]{2,3})", nm, perl = TRUE))
  if (!length(m)) return(character(0))
  tolower(sub("(?i)^FVS", "", m, perl = TRUE))
}
