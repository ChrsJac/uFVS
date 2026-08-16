#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# The single entry point both packaged launchers drive, and the one a developer
# can run by hand.
#
# The native launchers (uFVS.exe on Windows, uFVS.app/Contents/MacOS/uFVS on
# macOS) know the packaged directory shape and nothing else. They describe it
# through environment variables, start this script with the bundled Rscript, and
# then wait for the server to say it is ready. This script owns everything about
# starting Shiny; the launchers own the window, the browser, and the process
# tree.
#
# Contract with a launcher
#   in   UFVS_APP_DIR        application directory (app.R, R/, config/, www/)
#        UFVS_LIBRARY_DIR    private R package library
#        UFVS_RUNTIME_DIR    bundled R runtime
#        UFVS_FVS_DIR        bundled FVS binaries
#        UFVS_RESOURCES_DIR  BUILD_INFO.json, notices, docs
#        UFVS_PORT           requested port, or 0 to choose one
#        UFVS_SESSION_FILE   where to record the chosen port
#        UFVS_DESKTOP        1 to exit when the last browser window closes
#   out  the session file, written only once the port is bound
#
# A source checkout sets none of these. Running this file, or
# shiny::runApp("."), behaves exactly as it always has.
# ------------------------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)

env_dir <- function(name) Sys.getenv(name, unset = "")

# A launcher-supplied directory, or the source-checkout default.
env_dir_or <- function(value, default) if (nzchar(value)) value else default

# The application directory: named by a launcher, otherwise the parent of this
# script, which is where a source checkout keeps app.R.
app_dir <- env_dir("UFVS_APP_DIR")
if (!nzchar(app_dir)) {
  script_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", script_args, value = TRUE)
  script_path <- if (length(file_arg)) sub("^--file=", "", file_arg[1]) else "tools/launch.R"
  app_dir <- file.path(dirname(script_path), "..")
}
app_dir <- normalizePath(app_dir, mustWork = TRUE)
if (!file.exists(file.path(app_dir, "app.R"))) {
  stop("No app.R below ", app_dir, "; the uFVS application directory is missing.",
       call. = FALSE)
}

# Never depend on the caller's working directory: a double-clicked launcher can
# start anywhere at all.
setwd(app_dir)
options(ufvs.root = app_dir)

bundled_library <- env_dir("UFVS_LIBRARY_DIR")
if (!nzchar(bundled_library)) bundled_library <- file.path(app_dir, "library")

release <- tolower(Sys.getenv("UFVS_RELEASE", unset = "")) %in%
  c("1", "true", "yes", "y") ||
  (file.exists(file.path(env_dir_or(env_dir("UFVS_RESOURCES_DIR"), app_dir),
                         "BUILD_INFO.json")) &&
   dir.exists(env_dir_or(env_dir("UFVS_RUNTIME_DIR"), file.path(app_dir, "runtime"))))

if (dir.exists(bundled_library)) {
  bundled_library <- normalizePath(bundled_library, mustWork = FALSE)
  .libPaths(unique(c(bundled_library, .libPaths())))
  # callr workers inherit this, so an FVS worker resolves the same packages the
  # interface did rather than whatever a developer happens to have installed.
  if (release) Sys.setenv(R_LIBS_USER = bundled_library)
}

required <- c("shiny", "ggplot2", "jsonlite", "DBI", "RSQLite", "readxl", "callr", "digest")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]

if ("--check" %in% args) {
  if (length(missing)) cat(paste(missing, collapse = " "))
  quit(status = 0L)
}

if (length(missing)) {
  if (release) {
    stop(paste("This uFVS release is incomplete; its bundled package library is missing:",
               paste(missing, collapse = ", "), "."), call. = FALSE)
  }
  stop(paste("Missing R packages:", paste(missing, collapse = ", "),
             ". Install them with install.packages()."), call. = FALSE)
}

chosen_port <- suppressWarnings(as.integer(Sys.getenv("UFVS_PORT", unset = "0")))
if (length(chosen_port) != 1L || is.na(chosen_port) || chosen_port <= 0L) {
  chosen_port <- httpuv::randomPort(host = "127.0.0.1")
}
launch_browser <- tolower(Sys.getenv("UFVS_LAUNCH_BROWSER", unset = "true")) %in%
  c("1", "true", "yes", "y")

# Tell the launcher which port to poll. Written before runApp() blocks, and
# removed on the way out so a stale file cannot point at a dead process.
session_file <- Sys.getenv("UFVS_SESSION_FILE", unset = "")
if (nzchar(session_file)) {
  dir.create(dirname(session_file), showWarnings = FALSE, recursive = TRUE)
  writeLines(jsonlite::toJSON(list(
    port = chosen_port,
    pid = Sys.getpid(),
    url = sprintf("http://127.0.0.1:%d/", chosen_port),
    app = app_dir,
    started = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  ), auto_unbox = TRUE, pretty = TRUE), session_file)
  on.exit(unlink(session_file, force = TRUE), add = TRUE)
}

cat(sprintf("uFVS starting\n  R home:      %s\n  library:     %s\n  application: %s\n  address:     http://127.0.0.1:%d/\n",
            R.home(), bundled_library, app_dir, chosen_port))
utils::flush.console()

shiny::runApp(app_dir, port = chosen_port, launch.browser = launch_browser,
              host = "127.0.0.1")
