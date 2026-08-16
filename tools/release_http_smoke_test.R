#!/usr/bin/env Rscript
# Drive the real packaged launcher the way a double-click does, then check the
# two things a user would notice: the application answers on localhost, and
# quitting it does not leave R or FVS processes running.
#
# This deliberately starts the native launcher rather than calling
# shiny::runApp() directly. The launcher is the part that resolves the bundled
# runtime, picks a port, waits for readiness and owns the process tree, so
# testing anything less would not test the thing users actually run.
#
#   release_http_smoke_test.R --launcher <path> [--library <dir>] [--timeout 120]

args <- commandArgs(trailingOnly = TRUE)
value_for <- function(flag, default = "") {
  i <- match(flag, args)
  if (!is.na(i) && i < length(args)) args[i + 1L] else default
}
env_or <- function(name, default) {
  v <- Sys.getenv(name, unset = "")
  if (nzchar(v)) v else default
}

launcher <- value_for("--launcher")
if (!nzchar(launcher) || !file.exists(launcher))
  stop("--launcher must name the packaged uFVS launcher.", call. = FALSE)
launcher <- normalizePath(launcher, mustWork = TRUE)

library_dir <- value_for("--library", env_or("UFVS_LIBRARY_DIR", ""))
if (nzchar(library_dir) && dir.exists(library_dir))
  .libPaths(unique(c(normalizePath(library_dir), .libPaths())))

timeout <- suppressWarnings(as.integer(value_for("--timeout", "120")))
if (is.na(timeout) || timeout < 10L) timeout <- 120L

suppressPackageStartupMessages(library(processx))

is_windows <- .Platform$OS.type == "windows"

process_is_alive <- function(pid) {
  if (is.na(pid) || pid <= 0) return(FALSE)
  if (is_windows) {
    out <- suppressWarnings(system2("tasklist", c("/FI", shQuote(paste0("PID eq ", pid)), "/NH"),
                                    stdout = TRUE, stderr = NULL))
    return(any(grepl(as.character(pid), out, fixed = TRUE)))
  }
  identical(suppressWarnings(system2("ps", c("-p", pid), stdout = FALSE, stderr = FALSE)), 0L)
}

# Isolate this run from any real uFVS state on the build machine.
state_home <- file.path(tempdir(), "ufvs-launcher-smoke")
unlink(state_home, recursive = TRUE, force = TRUE)
dir.create(state_home, showWarnings = FALSE, recursive = TRUE)

launch_env <- c("current",
                UFVS_NO_BROWSER = "1",
                UFVS_LAUNCH_BROWSER = "0",
                UFVS_START_TIMEOUT = as.character(timeout),
                HOME = state_home,
                LOCALAPPDATA = state_home)

stdout_file <- file.path(state_home, "launcher.stdout.log")
stderr_file <- file.path(state_home, "launcher.stderr.log")

app <- processx::process$new(launcher, character(0), env = launch_env,
                             stdout = stdout_file, stderr = stderr_file,
                             cleanup = TRUE)
on.exit({
  if (app$is_alive()) try(app$kill_tree(), silent = TRUE)
}, add = TRUE)

session_file <- file.path(state_home, "Library", "Application Support", "uFVS",
                          "runtime", "session.json")
if (is_windows) {
  session_file <- file.path(state_home, "uFVS", "runtime", "session.json")
}

read_session <- function() {
  if (!file.exists(session_file)) return(NULL)
  out <- tryCatch(jsonlite::fromJSON(session_file), error = function(e) NULL)
  if (!is.list(out) || is.null(out$url)) NULL else out
}

diagnostics <- function() {
  parts <- character(0)
  for (f in c(stdout_file, stderr_file,
              file.path(state_home, "Library", "Logs", "uFVS", "server.log"),
              file.path(state_home, "Library", "Logs", "uFVS", "launcher.log"),
              file.path(state_home, "uFVS", "logs", "server.log"),
              file.path(state_home, "uFVS", "logs", "launcher.log"))) {
    if (file.exists(f)) {
      lines <- tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
      if (length(lines)) parts <- c(parts, paste0("--- ", f, " ---"),
                                    utils::tail(lines, 30L))
    }
  }
  paste(parts, collapse = "\n")
}

session <- NULL
page <- NULL
for (i in seq_len(timeout)) {
  if (!app$is_alive()) {
    stop("The uFVS launcher exited before the application was ready.\n",
         diagnostics(), call. = FALSE)
  }
  if (is.null(session)) session <- read_session()
  if (!is.null(session)) {
    page <- tryCatch(readLines(session$url, warn = FALSE), error = function(e) NULL)
    if (length(page)) break
  }
  Sys.sleep(1)
}

if (!length(page)) {
  stop("The packaged application did not answer on localhost within ", timeout,
       " seconds.\n", diagnostics(), call. = FALSE)
}
if (!any(grepl("uFVS|shiny", page, ignore.case = TRUE)))
  stop("The local response did not look like the uFVS page.", call. = FALSE)

server_pid <- suppressWarnings(as.integer(session$pid))
if (is.na(server_pid) || !process_is_alive(server_pid))
  stop("The launcher did not report a live R process.", call. = FALSE)

# The application must be bound to loopback only. A packaged desktop app that
# listens on every interface would expose the user's inventory data to the
# local network.
if (!grepl("^http://127[.]0[.]0[.]1:", session$url))
  stop("The application is not served on 127.0.0.1: ", session$url, call. = FALSE)

cat("Packaged launcher smoke test\n")
cat("  launcher: ", launcher, "\n")
cat("  address:  ", session$url, "\n")
cat("  R process:", server_pid, "\n")

# --- quitting must not leave anything behind ---------------------------------
# Signal only the launcher, never the tree: the whole point is that the
# launcher itself is responsible for taking R and any FVS worker down with it.
if (is_windows) {
  invisible(app$kill())        # closes the job object, which kills everything in it
} else {
  invisible(app$signal(15L))   # SIGTERM, which the shell launcher traps
}
for (i in seq_len(30)) {
  if (!app$is_alive() && !process_is_alive(server_pid)) break
  Sys.sleep(1)
}

if (process_is_alive(server_pid)) {
  stop("Closing uFVS left the R process ", server_pid, " running.", call. = FALSE)
}
still_serving <- suppressWarnings(tryCatch(
  !is.null(readLines(session$url, warn = FALSE)), error = function(e) FALSE))
if (isTRUE(still_serving)) {
  stop("The application is still answering after uFVS was closed.", call. = FALSE)
}

cat("  shutdown: clean, no orphan R/FVS processes\n")
cat("Packaged launcher smoke test passed\n")
