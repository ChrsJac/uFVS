# ------------------------------------------------------------------------------
# Running FVS without risking the interface.
#
# FVS is a large Fortran program reached either as an executable or as a shared
# library loaded into the calling process. Loading it into the Shiny process
# would mean that any fault inside the engine takes the whole interface down and
# loses the user's unsaved project. So uFVS never runs FVS in-process: every run
# happens in a separate OS process created by callr, in its own directory, with
# its own inputs, outputs and logs.
#
# A failed run is a value, not an exception. The runner returns a structured
# result describing what failed and where the evidence is; the interface stays
# alive and editable.
# ------------------------------------------------------------------------------

#' Resolve which FVS executable will run a given variant, and say plainly when
#' none can.
#'
#' The invariant this protects: every stand runs under the executable for that
#' stand's own variant. Running an SO stand through FVSsn would produce numbers
#' that look plausible and are wrong, so a mismatch fails before launch rather
#' than being silently substituted.
#'
#' @return list(path, ok, reason, variant)
resolve_engine_exe <- function(engine, variant) {
  v <- tolower(nz(variant, ""))
  none <- function(reason) list(path = NA_character_, ok = FALSE, reason = reason, variant = v)

  if (!nzchar(v)) return(none("The stand does not name an FVS variant."))

  if (identical(engine$mode, "bundled")) {
    p <- if (identical(.Platform$OS.type, "windows")) {
      file.path(engine$path, paste0("FVS", v, ".exe"))
    } else file.path(engine$path, paste0("FVS", v))
    if (!engine_is_executable(p)) {
      avail <- engine_variants_in_dir(engine$path)
      return(none(sprintf(
        "No FVS executable for variant %s. Available here: %s.",
        toupper(v),
        if (length(avail)) paste(toupper(avail), collapse = ", ") else "none")))
    }
    return(list(path = p, ok = TRUE, reason = NA_character_, variant = v))
  }

  if (identical(engine$mode, "executable")) {
    if (!file.exists(nz(engine$path, ""))) {
      return(none(paste0("No FVS executable at ", nz(engine$path, "(unset)"), ".")))
    }
    # An executable names its variant (FVSsn, FVSso, ...). When it does and the
    # names disagree, that is a hard stop.
    ev <- engine_variant_from_name(basename(engine$path))
    if (length(ev) && !identical(ev[1], v)) {
      return(none(sprintf(
        "This stand requires FVS variant %s, but the configured executable is %s.",
        toupper(v), basename(engine$path))))
    }
    return(list(path = engine$path, ok = TRUE, reason = NA_character_, variant = v))
  }

  if (identical(engine$mode, "library")) {
    f <- file.path(engine$path, paste0("FVS", v, .Platform$dynlib.ext))
    if (!file.exists(f)) {
      return(none(sprintf("No FVS shared library for variant %s in %s.",
                          toupper(v), nz(engine$path, "(unset)"))))
    }
    return(list(path = f, ok = TRUE, reason = NA_character_, variant = v))
  }

  none("No FVS engine is configured.")
}

#' Group stands by their resolved FVS variant.
stands_by_variant <- function(data, stand_ids) {
  s <- data$stands[data$stands$STAND_ID %in% stand_ids, , drop = FALSE]
  v <- tolower(nz(s$VARIANT, ""))
  split(as.character(s$STAND_ID), ifelse(nzchar(v), v, "(none)"))
}

#' Check every stand can reach a usable executable before anything launches.
#'
#' @return data.frame(variant, stands, ok, reason); zero rows means nothing to run.
check_variant_dispatch <- function(data, stand_ids, engine = load_engine_config()) {
  groups <- stands_by_variant(data, stand_ids)
  if (!length(groups)) return(data.frame())
  do.call(rbind, lapply(names(groups), function(v) {
    r <- resolve_engine_exe(engine, if (identical(v, "(none)")) "" else v)
    data.frame(variant = v, stands = paste(groups[[v]], collapse = ", "),
               n = length(groups[[v]]), exe = nz(r$path, NA_character_),
               ok = r$ok, reason = nz(r$reason, NA_character_),
               stringsAsFactors = FALSE)
  }))
}

#' Create a fresh run directory and write everything the engine needs into it.
prepare_run <- function(data, scenario, stand_ids, engine = load_engine_config(),
                        title = "uFVS run", run_id = NULL, dataset_hash = NULL,
                        runs_dir = NULL) {
  stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
  rid <- nz(run_id, paste0(stamp, "_", substr(sha256_of(list(scenario, stand_ids)), 1, 6)))
  runs_dir <- nz(runs_dir, ufvs_runs_dir())
  dir.create(runs_dir, showWarnings = FALSE, recursive = TRUE)
  dir <- file.path(runs_dir, rid)
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)

  # Only the stands being run go into the engine's input database.
  sub <- data
  sub$stands <- data$stands[data$stands$STAND_ID %in% stand_ids, , drop = FALSE]
  sub$trees <- data$trees[data$trees$STAND_ID %in% stand_ids, , drop = FALSE]
  if (!is.null(data$plots) && nrow(data$plots))
    sub$plots <- data$plots[data$plots$STAND_ID %in% stand_ids, , drop = FALSE]

  input_db <- file.path(dir, "FVS_Data.db")
  write_fvs_input_db(sub, input_db)

  inv_years <- stats::setNames(as.list(sub$stands$INV_YEAR), sub$stands$STAND_ID)
  key <- build_keyword_file(stand_ids, scenario, input_db = "FVS_Data.db",
                            output_db = "FVSOut.db", title = title,
                            inv_years = inv_years)
  key_path <- file.path(dir, "run.key")
  writeLines(key, key_path)

  variants <- unique(tolower(nz(sub$stands$VARIANT, "")))
  variants <- variants[nzchar(variants)]
  # A job runs one executable, so it must carry exactly one variant. Callers
  # partition by variant before getting here; this is the backstop.
  if (length(variants) > 1) {
    stop("A single FVS job cannot mix variants (", paste(toupper(variants), collapse = ", "),
         "). Partition the stands by variant before preparing the run.", call. = FALSE)
  }
  variant <- if (length(variants)) variants[1] else NA_character_
  exe <- resolve_engine_exe(engine, variant)

  meta <- list(
    run_id = rid,
    ufvs_version = UFVS_VERSION,
    created = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    title = title,
    scenario = nz(scenario$name, "Base"),
    stand_ids = as.list(stand_ids),
    variants = as.list(variants),
    engine_mode = engine$mode,
    engine_path = engine$path,
    # The executable actually resolved for this job's variant, and its hash, so
    # a result can be tied to the binary that produced it.
    variant = nz(variant, NA_character_),
    engine_exe = nz(exe$path, NA_character_),
    engine_exe_hash = file_hash(exe$path),
    provenance_schema = UFVS_PROVENANCE_SCHEMA,
    r_version = paste(R.version$major, R.version$minor, sep = "."),
    platform = R.version$platform,
    input_hash = inventory_hash(sub),
    # Hash of the whole loaded inventory, not just the stands in this job, so
    # results can be matched back to the dataset that produced them.
    dataset_hash = nz(dataset_hash, inventory_hash(data)),
    dataset_name = nz(data$source$name, ""),
    keyword_hash = text_hash(key),
    config_hash = config_hash(),
    status = "prepared"
  )
  jsonlite::write_json(meta, file.path(dir, "run.json"), auto_unbox = TRUE, pretty = TRUE)

  list(run_id = rid, dir = dir, key = key_path, input_db = input_db,
       output_db = file.path(dir, "FVSOut.db"), meta = meta,
       variants = variants, variant = variant, exe = exe)
}

#' The body of the worker process.
#'
#' Deliberately dependency-free and self-contained: callr copies it into a fresh
#' R session, so it cannot rely on anything uFVS has loaded.
fvs_worker_body <- function(dir, key_file, mode, engine_path, variant, exe_path = NULL) {
  # callr copies this function into a clean R session, so it cannot rely on any
  # uFVS helper being loaded. Anything it needs is defined here.
  nz <- function(x, y) {
    if (is.null(x) || length(x) == 0L) return(y)
    if (length(x) == 1L && is.na(x)) return(y)
    x
  }
  setwd(dir)
  started <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  result <- list(started = started, mode = mode, variant = variant)

  out_file <- file.path(dir, "fvs_stdout.log")
  err_file <- file.path(dir, "fvs_stderr.log")

  if (identical(mode, "bundled") || identical(mode, "executable")) {
    # The executable is resolved and variant-checked before launch; the worker
    # runs exactly what it was handed rather than choosing again.
    exe <- nz(exe_path, "")
    if (!nzchar(exe) || !file.exists(exe)) {
      return(c(result, list(ok = FALSE, stage = "engine",
                            message = paste0("FVS executable not found at ", exe,
                                             if (identical(mode, "bundled"))
                                               paste0(" for variant ", toupper(variant)) else ""),
                            exit_status = NA_integer_)))
    }
    status <- tryCatch(
      system2(exe, args = c(paste0("--keywordfile=", basename(key_file))),
              stdout = out_file, stderr = err_file, wait = TRUE),
      error = function(e) structure(-1L, msg = conditionMessage(e)))
    result$exit_status <- as.integer(status[1])
    result$ok <- identical(as.integer(status), 0L)
    result$stage <- if (result$ok) "complete" else "engine"
    if (!result$ok) result$message <- paste0("FVS exited with status ", status, ".")

  } else if (identical(mode, "library")) {
    lib <- file.path(engine_path,
                     paste0("FVS", toupper(substr(variant, 1, 1)), substr(variant, 2, 3)))
    # rFVS expects the bare program name; try both cases the builds use.
    cand <- c(paste0("FVS", variant), paste0("FVS", toupper(variant)))
    ok <- FALSE; msg <- ""
    for (pgm in cand) {
      f <- file.path(engine_path, paste0(pgm, .Platform$dynlib.ext))
      if (file.exists(f)) {
        r <- tryCatch({
          dyn.load(f, local = TRUE, now = TRUE)
          con <- file(out_file, open = "wt"); sink(con); sink(con, type = "message")
          on.exit({ sink(type = "message"); sink(); close(con) }, add = TRUE)
          .Fortran("CfvsSetCmdLine",
                   as.character(paste0("--keywordfile=", basename(key_file))),
                   as.integer(nchar(paste0("--keywordfile=", basename(key_file)))),
                   as.integer(0))
          rtn <- integer(1)
          .Fortran("fvs", rtn)
          rtn[1]
        }, error = function(e) structure(-1L, msg = conditionMessage(e)))
        ok <- identical(as.integer(r), 0L)
        msg <- nz(attr(r, "msg"), "")
        break
      }
    }
    result$ok <- ok
    result$exit_status <- if (ok) 0L else 1L
    result$stage <- if (ok) "complete" else "engine"
    if (!ok) result$message <- paste0(
      "The FVS shared library did not run successfully. ",
      if (nzchar(msg)) msg else paste0("Looked for ", paste(cand, collapse = " or "),
                                       .Platform$dynlib.ext, " in ", engine_path, "."))
  } else {
    return(c(result, list(ok = FALSE, stage = "engine", exit_status = NA_integer_,
                          message = "No FVS engine is configured.")))
  }

  # FVS's exit status reports the highest severity it met, so a non-zero status
  # covers everything from a benign "forest code defaulted" note to a genuine
  # abort. Judging a run by the status alone would fail perfectly good
  # projections. What actually matters is whether usable output came out, so
  # that is what decides, and FVS's own error table is surfaced either way.
  out_db <- file.path(dir, "FVSOut.db")
  result$output_db_exists <- file.exists(out_db)
  result$tables <- character(0)
  if (result$output_db_exists) {
    result$tables <- tryCatch({
      con <- DBI::dbConnect(RSQLite::SQLite(), out_db)
      on.exit(DBI::dbDisconnect(con), add = TRUE)
      DBI::dbListTables(con)
    }, error = function(e) character(0))
  }
  produced <- any(grepl("^FVS_Summary", result$tables))

  if (produced) {
    result$ok <- TRUE
    result$stage <- "complete"
    if (!identical(as.integer(nz(result$exit_status, 0L)), 0L)) {
      result$message <- paste0("FVS reported messages (exit status ",
                               result$exit_status, "). The projection completed.")
    }
  } else if (result$output_db_exists) {
    result$ok <- FALSE
    result$stage <- "output"
    result$message <- "FVS produced an output database with no stand summary in it."
  } else {
    result$ok <- FALSE
    result$stage <- if (identical(nz(result$stage, ""), "complete")) "output" else result$stage
    result$message <- nz(result$message, "FVS finished but produced no output database.")
  }
  result$finished <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  result
}

#' Start a run in its own process. Returns immediately.
launch_run <- function(prep, engine = load_engine_config()) {
  variant <- nz(prep$variant, nz(prep$variants[1], ""))
  # Refuse to start rather than run a stand under the wrong variant's engine.
  if (!isTRUE(prep$exe$ok)) {
    update_run_meta(prep$dir, list(status = "failed", stage = "engine",
                                   message = nz(prep$exe$reason, "No usable FVS executable.")))
    return(list(handle = NULL, prep = prep,
                failed = list(state = "failed", stage = "engine", dir = prep$dir,
                              run_id = prep$run_id, exit_status = NA_integer_,
                              message = nz(prep$exe$reason, "No usable FVS executable."))))
  }
  handle <- callr::r_bg(
    func = fvs_worker_body,
    args = list(dir = prep$dir, key_file = prep$key, mode = engine$mode,
                engine_path = engine$path, variant = variant,
                exe_path = nz(prep$exe$path, NA_character_)),
    supervise = TRUE,
    stdout = file.path(prep$dir, "worker_stdout.log"),
    stderr = file.path(prep$dir, "worker_stderr.log"))
  update_run_meta(prep$dir, list(status = "running", pid = handle$get_pid()))
  list(handle = handle, prep = prep)
}

update_run_meta <- function(dir, changes) {
  p <- file.path(dir, "run.json")
  meta <- if (file.exists(p)) jsonlite::fromJSON(p, simplifyVector = TRUE) else list()
  meta <- utils::modifyList(meta, changes)
  jsonlite::write_json(meta, p, auto_unbox = TRUE, pretty = TRUE)
  meta
}

#' Poll a running job without ever letting a worker fault reach the interface.
run_status <- function(job) {
  if (is.null(job)) return(list(state = "idle"))
  # A job refused before launch carries its verdict instead of a process.
  if (!is.null(job$failed)) return(job$failed)
  h <- job$handle
  if (is.null(h)) return(list(state = "failed", stage = "engine",
                              dir = job$prep$dir, run_id = job$prep$run_id,
                              message = "The run was never started."))
  alive <- tryCatch(h$is_alive(), error = function(e) FALSE)
  if (alive) return(list(state = "running", run_id = job$prep$run_id, dir = job$prep$dir))

  res <- tryCatch(h$get_result(), error = function(e) {
    list(ok = FALSE, stage = "worker", exit_status = NA_integer_,
         message = paste0("The FVS worker process ended abnormally: ", conditionMessage(e)))
  })
  state <- if (isTRUE(res$ok)) "success" else "failed"
  update_run_meta(job$prep$dir, list(status = state,
                                     exit_status = nz(res$exit_status, NA),
                                     message = nz(res$message, "")))
  c(list(state = state, run_id = job$prep$run_id, dir = job$prep$dir), res)
}

#' Read whatever diagnostics exist for a run, for the Log page.
run_logs <- function(dir) {
  files <- c("fvs_stdout.log", "fvs_stderr.log", "worker_stdout.log",
             "worker_stderr.log", "run.key")
  out <- list()
  for (f in files) {
    p <- file.path(dir, f)
    if (file.exists(p)) {
      txt <- tryCatch(readLines(p, warn = FALSE), error = function(e) character(0))
      out[[f]] <- txt
    }
  }
  # FVS writes its own listing next to the keyword file.
  for (p in list.files(dir, pattern = "\\.(out|sum|trl)$", full.names = TRUE)) {
    out[[basename(p)]] <- tryCatch(readLines(p, warn = FALSE), error = function(e) character(0))
  }
  out
}

#' Try to point at the stand and keyword responsible for a failure.
#'
#' FVS reports problems in its listing file; this pulls the lines that name a
#' stand or an offending keyword so the interface can say more than "it failed".
diagnose_failure <- function(dir) {
  logs <- run_logs(dir)
  txt <- unlist(logs[intersect(names(logs), c("fvs_stdout.log", "fvs_stderr.log"))])
  if (!length(txt)) txt <- unlist(logs)
  if (!length(txt)) return(list(lines = character(0), stand = NA_character_, keyword = NA_character_))
  hits <- grep("ERROR|FATAL|ABORT|INVALID|NOT FOUND|CANNOT|FVS[0-9]+", txt,
               ignore.case = TRUE, value = TRUE)
  stand <- NA_character_; keyword <- NA_character_
  st <- grep("STAND", txt, ignore.case = TRUE, value = TRUE)
  if (length(st)) stand <- trimws(st[1])
  kw <- grep("KEYWORD", txt, ignore.case = TRUE, value = TRUE)
  if (length(kw)) keyword <- trimws(kw[1])
  list(lines = utils::head(hits, 40), stand = stand, keyword = keyword)
}

#' Every run uFVS has recorded, newest first.
list_runs <- function(runs_dir = NULL) {
  runs_dir <- nz(runs_dir, ufvs_runs_dir())
  if (!dir.exists(runs_dir)) {
    return(data.frame(run_id = character(0), created = character(0), scenario = character(0),
                      stands = integer(0), status = character(0),
                      dataset_hash = character(0), dataset_name = character(0),
                      dir = character(0), stringsAsFactors = FALSE))
  }
  dirs <- list.dirs(runs_dir, recursive = FALSE)
  metas <- lapply(dirs, function(d) {
    p <- file.path(d, "run.json")
    if (!file.exists(p)) return(NULL)
    m <- tryCatch(jsonlite::fromJSON(p, simplifyVector = TRUE), error = function(e) NULL)
    if (is.null(m)) return(NULL)
    data.frame(run_id = nz(m$run_id, basename(d)),
               created = nz(m$created, ""),
               scenario = nz(m$scenario, ""),
               stands = length(nz(m$stand_ids, list())),
               status = nz(m$status, "unknown"),
               dataset_hash = nz(m$dataset_hash, ""),
               dataset_name = nz(m$dataset_name, ""),
               dir = d, stringsAsFactors = FALSE)
  })
  metas <- metas[!vapply(metas, is.null, logical(1))]
  if (!length(metas)) {
    return(data.frame(run_id = character(0), created = character(0), scenario = character(0),
                      stands = integer(0), status = character(0),
                      dataset_hash = character(0), dataset_name = character(0),
                      dir = character(0), stringsAsFactors = FALSE))
  }
  out <- do.call(rbind, metas)
  out[order(out$created, decreasing = TRUE), , drop = FALSE]
}

#' Run several stands as independent jobs so one bad stand cannot stop the rest.
#'
#' Returns one job per stand; the caller polls them and reports per-stand
#' outcomes.
launch_batch <- function(data, scenario, stand_ids, engine = load_engine_config(),
                         title = "uFVS batch", dataset_hash = NULL, runs_dir = NULL) {
  # One job per stand keeps a bad stand from taking the others down, and it
  # guarantees each stand runs under its own variant's executable.
  lapply(stand_ids, function(sid) {
    prep <- prepare_run(data, scenario, sid, engine, title = paste(title, sid),
                        dataset_hash = dataset_hash, runs_dir = runs_dir)
    launch_run(prep, engine)
  })
}

#' Launch a scenario, partitioned so every stand meets its own variant's engine.
#'
#' A single FVS executable serves one variant. When an inventory spans several,
#' the run is split into one job per variant rather than pushing every stand
#' through whichever executable happened to be first.
launch_by_variant <- function(data, scenario, stand_ids, engine = load_engine_config(),
                              title = "uFVS run", dataset_hash = NULL, runs_dir = NULL) {
  groups <- stands_by_variant(data, stand_ids)
  out <- list()
  for (v in names(groups)) {
    ids <- groups[[v]]
    prep <- prepare_run(data, scenario, ids, engine,
                        title = if (length(groups) > 1) paste(title, toupper(v)) else title,
                        dataset_hash = dataset_hash, runs_dir = runs_dir)
    out[[length(out) + 1L]] <- launch_run(prep, engine)
  }
  out
}

#' FVS's own error/warning table from a completed run, if it wrote one.
#'
#' FVS records what it thought of the input here. Warnings are routine (a
#' defaulted forest code, say); errors mean a keyword was ignored or a value
#' rejected, which is worth showing even when the projection completed.
fvs_messages <- function(dir) {
  db <- file.path(dir, "FVSOut.db")
  if (!file.exists(db)) return(data.frame())
  out <- tryCatch({
    con <- DBI::dbConnect(RSQLite::SQLite(), db)
    on.exit(DBI::dbDisconnect(con), add = TRUE)
    if (!"FVS_Error" %in% DBI::dbListTables(con)) return(data.frame())
    DBI::dbReadTable(con, "FVS_Error")
  }, error = function(e) data.frame())
  if (!nrow(out)) return(out)
  msg <- trimws(nz(out$Message, ""))
  data.frame(
    stand = as.character(nz(out$StandID, "")),
    severity = ifelse(grepl("ERROR", msg), "error",
               ifelse(grepl("WARNING", msg), "warning", "note")),
    message = msg,
    stringsAsFactors = FALSE)
}
