# ------------------------------------------------------------------------------
# Stand visualization.
#
# These are FVS's own stand pictures, not a uFVS reconstruction. Adding the SVS
# keyword to a run makes FVS write Stand Visualization System files - one per
# cycle plus an index - containing, for every displayed tree:
#
#   species, tree class, crown class, DBH, height, crown radius and crown ratio
#   in four directions, lean and fall angles, and an (x, y) position on the
#   display plot.
#
# FVS assigns those positions itself (base/svstart.f, svgtpl.f). uFVS reads the
# files and draws them. The crown silhouette comes from the official SVS
# tree-form definitions shipped with fvsOL (config/treeforms.RData), which give
# the crown taper points and colors per species and tree class.
#
# What uFVS contributes is the drawing: a plan view and a profile view rendered
# with base graphics. fvsOL draws the same data in 3D through rgl; uFVS avoids
# that dependency, so these are 2D views of the same numbers.
# ------------------------------------------------------------------------------

#' Column layout of an SVS tree record.
#'
#' The records are whitespace separated and positional; fvsOL reads them the
#' same way (see its renderSVSImage, which picks fields 21, 22 and 7 for x, y
#' and height).
SVS_TREE_COLS <- c("sp", "tree", "trcl", "crcl", "stus", "dbh", "ht", "lang",
                   "fang", "edia", "crd1", "cr1", "crd2", "cr2", "crd3", "cr3",
                   "crd4", "cr4", "ex", "mk", "xloc", "yloc", "z")

svs_treeforms <- function() {
  cached("treeforms", function() {
    p <- file.path(ufvs_config_dir(), "treeforms.RData")
    if (!file.exists(p)) return(NULL)
    e <- new.env(parent = emptyenv())
    ok <- try(load(p, envir = e), silent = TRUE)
    if (inherits(ok, "try-error")) return(NULL)
    e$treeforms
  })
}

#' The SVS index FVS wrote for a run, if the SVS keyword was active.
#'
#' @return data.frame(label, file, year, stand, path) or an empty frame.
read_svs_index <- function(dir) {
  empty <- data.frame(label = character(0), file = character(0),
                      year = numeric(0), stand = character(0),
                      path = character(0), stringsAsFactors = FALSE)
  if (is.null(dir) || !dir.exists(dir)) return(empty)
  idx <- list.files(dir, pattern = "_index\\.svs$", full.names = TRUE)
  if (!length(idx)) return(empty)

  lines <- tryCatch(readLines(idx[1], warn = FALSE), error = function(e) character(0))
  lines <- lines[!grepl("^\\s*(#|;)", lines) & nzchar(trimws(lines))]
  if (!length(lines)) return(empty)

  # Each entry is: "Stand=69 Year=2024 Inventory conditions" "run_001.svs"
  parts <- regmatches(lines, gregexpr('"[^"]*"', lines))
  keep <- lengths(parts) >= 2
  parts <- parts[keep]
  if (!length(parts)) return(empty)

  label <- vapply(parts, function(p) gsub('"', "", p[1]), character(1))
  file <- vapply(parts, function(p) gsub('"', "", p[2]), character(1))
  num <- function(x, key) {
    m <- regmatches(x, regexpr(paste0(key, "=\\S+"), x))
    ifelse(length(m) == 0, NA_character_, sub(paste0(key, "="), "", m))
  }
  out <- data.frame(
    label = label,
    file = file,
    year = suppressWarnings(as.numeric(vapply(label, num, character(1), "Year"))),
    stand = vapply(label, num, character(1), "Stand"),
    path = file.path(dir, file),
    stringsAsFactors = FALSE)
  out <- out[file.exists(out$path), , drop = FALSE]
  rownames(out) <- NULL
  out
}

#' Read one SVS file: plot geometry plus the tree records.
read_svs_file <- function(path) {
  if (!file.exists(path)) return(NULL)
  lines <- tryCatch(readLines(path, warn = FALSE), error = function(e) character(0))
  if (!length(lines)) return(NULL)

  header_val <- function(tag) {
    h <- grep(paste0("^#", tag), lines, value = TRUE)
    if (!length(h)) return(NULL)
    trimws(sub(paste0("^#", tag), "", h[1]))
  }

  size <- suppressWarnings(as.numeric(strsplit(nz(header_val("PLOTSIZE"), ""), "\\s+")[[1]]))
  size <- size[!is.na(size)]
  if (length(size) < 2) size <- c(208.71, 208.71)

  circle <- suppressWarnings(as.numeric(strsplit(nz(header_val("CIRCLE"), ""), "\\s+")[[1]]))
  circle <- circle[!is.na(circle)]

  tf_name <- nz(header_val("TREEFORM"), "")
  tf_name <- tolower(sub("\\..*$", "", tf_name))

  body <- lines[!grepl("^\\s*(#|;)", lines) & nzchar(trimws(lines))]
  if (!length(body)) {
    return(list(trees = data.frame(), plot_size = size, circle = circle,
                treeform = tf_name, title = nz(header_val("TITLE"), "")))
  }

  tr <- tryCatch(
    utils::read.table(text = body, header = FALSE, stringsAsFactors = FALSE,
                      fill = TRUE, comment.char = ""),
    error = function(e) NULL)
  if (is.null(tr) || !ncol(tr)) {
    return(list(trees = data.frame(), plot_size = size, circle = circle,
                treeform = tf_name, title = nz(header_val("TITLE"), "")))
  }

  n <- min(ncol(tr), length(SVS_TREE_COLS))
  tr <- tr[, seq_len(n), drop = FALSE]
  names(tr) <- SVS_TREE_COLS[seq_len(n)]
  for (cc in setdiff(names(tr), "sp")) tr[[cc]] <- safe_num(tr[[cc]])
  tr$sp <- as.character(tr$sp)
  tr <- tr[!is.na(tr$dbh) & !is.na(tr$ht) & tr$ht > 0, , drop = FALSE]

  list(trees = tr, plot_size = size, circle = circle, treeform = tf_name,
       title = nz(header_val("TITLE"), ""))
}

#' Tree-form parameters for one tree, from the official SVS definitions.
#'
#' Falls back through the tree's own class, the generic class 99, then the
#' "--" catch-all species, which is how the SVS forms are organized.
svs_form_for <- function(tf, species, trcl) {
  if (is.null(tf) || !nrow(tf)) return(NULL)
  ttcl <- if (is.na(trcl) || trcl == 0) 99 else trcl
  hit <- tf[tf$Sp == species & tf$TrCl == ttcl, , drop = FALSE]
  if (!nrow(hit)) hit <- tf[tf$Sp == species & tf$TrCl == 99, , drop = FALSE]
  if (!nrow(hit)) hit <- tf[tf$Sp == species, , drop = FALSE]
  if (!nrow(hit)) hit <- tf[tf$Sp == "--" & tf$TrCl == ttcl, , drop = FALSE]
  if (!nrow(hit)) hit <- tf[tf$Sp == "--", , drop = FALSE]
  if (!nrow(hit)) return(NULL)
  as.list(hit[1, ])
}

#' SVS color table, transcribed from fvsOL's svsTree.R.
SVS_COLORS <- c(
  grDevices::rgb(210,  66, 14, maxColorValue = 255),
  grDevices::rgb(163, 117,  0, maxColorValue = 255),
  grDevices::rgb(119,  42, 24, maxColorValue = 255),
  grDevices::rgb( 98,  98, 98, maxColorValue = 255),
  grDevices::rgb(112, 153,  0, maxColorValue = 255),
  grDevices::rgb(  0,  86, 26, maxColorValue = 255),
  grDevices::rgb( 20,  66, 42, maxColorValue = 255),
  grDevices::rgb(  0,  76,  0, maxColorValue = 255),
  grDevices::rgb( 62,  45, 45, maxColorValue = 255),
  grDevices::rgb( 98,  18,  0, maxColorValue = 255),
  grDevices::rgb( 88,  55, 57, maxColorValue = 255),
  grDevices::rgb( 52, 149, 64, maxColorValue = 255),
  grDevices::rgb(  0,  58, 44, maxColorValue = 255),
  grDevices::rgb( 90,  64, 38, maxColorValue = 255),
  grDevices::rgb(115,  82,  0, maxColorValue = 255),
  grDevices::rgb(137, 137,  0, maxColorValue = 255),
  grDevices::rgb( 69,  72, 72, maxColorValue = 255),
  grDevices::rgb( 86,  64, 16, maxColorValue = 255),
  grDevices::rgb(  0, 107,  0, maxColorValue = 255),
  grDevices::rgb( 76,  46,  0, maxColorValue = 255))

svs_color <- function(idx, default = "#2e7d32") {
  if (is.null(idx) || is.na(idx)) return(default)
  i <- as.integer(idx) + 1L
  if (i < 1 || i > length(SVS_COLORS)) return(default)
  SVS_COLORS[i]
}

#' Crown outline for one tree in the profile view.
#'
#' Uses the SVS tree-form taper points: the crown widens from the base to
#' LoX/LoY, on to HiX/HiY, then closes at the tip. Those four numbers are what
#' give a fir a different silhouette from an oak.
svs_crown_outline <- function(ht, crown_ratio, crown_diam, form) {
  cl <- ht * crown_ratio
  hcb <- ht - cl
  r <- crown_diam / 2
  if (!is.finite(cl) || cl <= 0 || !is.finite(r) || r <= 0) return(NULL)

  lox <- nz(form$LoX, 0.7); loy <- nz(form$LoY, 0.05)
  hix <- nz(form$HiX, 1.0); hiy <- nz(form$HiY, 0.55)

  zs <- c(hcb, hcb + cl * loy, hcb + cl * hiy, ht)
  rs <- c(0,   r * lox,        r * hix,        0)
  # Interpolate between the four taper points, as svsTree does, so the
  # silhouette curves instead of showing four straight facets.
  ok <- !duplicated(zs)
  if (sum(ok) >= 2) {
    f <- stats::approxfun(zs[ok], rs[ok], rule = 2, ties = "ordered")
    zz <- seq(hcb, ht, length.out = 24)
    rr <- f(zz)
  } else {
    zz <- zs; rr <- rs
  }
  # Down one side and back up the other closes the silhouette.
  list(x = c(rr, rev(-rr)), y = c(zz, rev(zz)))
}

#' Profile (side) view of a stand.
#'
#' Trees are drawn back to front so nearer stems overlap farther ones, which is
#' what makes the picture read as a stand rather than a scatter of shapes.
plot_svs_profile <- function(svs, max_trees = 600, show_ground = TRUE) {
  tr <- svs$trees
  if (is.null(tr) || !nrow(tr)) {
    graphics::plot.new()
    graphics::text(0.5, 0.5, "No trees in this SVS file.", col = "#6e777d")
    return(invisible(NULL))
  }
  if (nrow(tr) > max_trees) tr <- tr[seq_len(max_trees), , drop = FALSE]

  tf <- svs_treeforms()[[nz(svs$treeform, "east")]]
  # Far trees first: larger y is farther back.
  tr <- tr[order(-tr$yloc), , drop = FALSE]
  depth <- range(c(tr$yloc, 0), na.rm = TRUE)
  span <- max(1e-6, diff(depth))

  xlim <- c(0, nz(svs$plot_size[1], 208.71))
  ylim <- c(0, max(tr$ht, na.rm = TRUE) * 1.08)

  op <- graphics::par(mar = c(3.2, 3.6, 1, 1), bg = "white")
  on.exit(graphics::par(op), add = TRUE)
  graphics::plot(NA, xlim = xlim, ylim = ylim, xaxs = "i", yaxs = "i",
                 xlab = "", ylab = "", axes = FALSE)
  if (show_ground) {
    graphics::rect(xlim[1], 0, xlim[2], ylim[2] * 0.012, col = "#d9d2c4", border = NA)
  }

  for (i in seq_len(nrow(tr))) {
    t <- tr[i, ]
    form <- svs_form_for(tf, t$sp, t$trcl)
    # Trees farther back are drawn slightly lighter, so depth reads.
    shade <- 0.55 + 0.45 * (1 - (t$yloc - depth[1]) / span)
    stem_col <- grDevices::adjustcolor(svs_color(nz(form$StemC, 13), "#6b4f2a"), alpha.f = shade)
    crown_col <- grDevices::adjustcolor(svs_color(nz(form$FlCol1, 5), "#2e7d32"), alpha.f = shade)

    cr <- nz(t$cr1, 0.4)
    cd <- nz(t$crd1, t$dbh / 4)
    dbh_ft <- nz(t$dbh, 1) / 12
    hcb <- t$ht * (1 - cr)

    graphics::rect(t$xloc - dbh_ft / 2, 0, t$xloc + dbh_ft / 2, max(hcb, t$ht * 0.02),
                   col = stem_col, border = NA)
    o <- svs_crown_outline(t$ht, cr, cd, form)
    if (!is.null(o)) {
      graphics::polygon(t$xloc + o$x, o$y, col = crown_col,
                        border = grDevices::adjustcolor("#1b3a1b", alpha.f = shade * 0.8))
    }
  }

  graphics::axis(1, col = "#171a1d", col.axis = "#4a5257", lwd = 1.2)
  graphics::axis(2, col = "#171a1d", col.axis = "#4a5257", lwd = 1.2, las = 1)
  graphics::mtext("Distance across plot (ft)", side = 1, line = 2.1,
                  col = "#171a1d", font = 2, cex = 0.9)
  graphics::mtext("Height (ft)", side = 2, line = 2.4,
                  col = "#171a1d", font = 2, cex = 0.9)
  invisible(nrow(tr))
}

#' Plan view: crowns seen from above, on the display plot FVS laid out.
plot_svs_plan <- function(svs, max_trees = 1500) {
  tr <- svs$trees
  if (is.null(tr) || !nrow(tr)) {
    graphics::plot.new()
    graphics::text(0.5, 0.5, "No trees in this SVS file.", col = "#6e777d")
    return(invisible(NULL))
  }
  if (nrow(tr) > max_trees) tr <- tr[seq_len(max_trees), , drop = FALSE]
  tf <- svs_treeforms()[[nz(svs$treeform, "east")]]

  w <- nz(svs$plot_size[1], 208.71); h <- nz(svs$plot_size[2], w)
  op <- graphics::par(mar = c(3.2, 3.6, 1, 1), bg = "white")
  on.exit(graphics::par(op), add = TRUE)
  graphics::plot(NA, xlim = c(0, w), ylim = c(0, h), asp = 1,
                 xaxs = "i", yaxs = "i", xlab = "", ylab = "", axes = FALSE)

  if (length(svs$circle) >= 3) {
    th <- seq(0, 2 * pi, length.out = 180)
    graphics::polygon(svs$circle[1] + svs$circle[3] * cos(th),
                      svs$circle[2] + svs$circle[3] * sin(th),
                      col = "#f2f0ea", border = "#c8cdd1")
  } else {
    graphics::rect(0, 0, w, h, col = "#f2f0ea", border = "#c8cdd1")
  }

  # Tallest last so dominant crowns sit on top, as they do in the canopy.
  tr <- tr[order(tr$ht), , drop = FALSE]
  th <- seq(0, 2 * pi, length.out = 40)
  for (i in seq_len(nrow(tr))) {
    t <- tr[i, ]
    form <- svs_form_for(tf, t$sp, t$trcl)
    col <- grDevices::adjustcolor(svs_color(nz(form$FlCol1, 5), "#2e7d32"), alpha.f = 0.75)
    # The four crown radii FVS reports, one per quadrant.
    rq <- c(nz(t$crd1, 0), nz(t$crd2, nz(t$crd1, 0)),
            nz(t$crd3, nz(t$crd1, 0)), nz(t$crd4, nz(t$crd1, 0))) / 2
    if (all(rq <= 0)) next
    quad <- floor((th %% (2 * pi)) / (pi / 2)) + 1
    r <- rq[pmin(pmax(quad, 1), 4)]
    graphics::polygon(t$xloc + r * cos(th), t$yloc + r * sin(th),
                      col = col, border = grDevices::adjustcolor("#1b3a1b", 0.5))
  }

  graphics::axis(1, col = "#171a1d", col.axis = "#4a5257", lwd = 1.2)
  graphics::axis(2, col = "#171a1d", col.axis = "#4a5257", lwd = 1.2, las = 1)
  graphics::mtext("Feet", side = 1, line = 2.1, col = "#171a1d", font = 2, cex = 0.9)
  graphics::mtext("Feet", side = 2, line = 2.4, col = "#171a1d", font = 2, cex = 0.9)
  invisible(nrow(tr))
}

#' Species present in an SVS file, with the color used to draw them.
svs_legend <- function(svs) {
  tr <- svs$trees
  if (is.null(tr) || !nrow(tr)) return(data.frame())
  tf <- svs_treeforms()[[nz(svs$treeform, "east")]]
  sp <- sort(unique(tr$sp))
  data.frame(
    species = sp,
    trees = as.integer(vapply(sp, function(s) sum(tr$sp == s), numeric(1))),
    color = vapply(sp, function(s) {
      svs_color(nz(svs_form_for(tf, s, 0)$FlCol1, 5), "#2e7d32")
    }, character(1)),
    stringsAsFactors = FALSE)
}

# ------------------------------------------------------------------------------
# 3D view
#
# FVS itself writes the SVS data; the 3D picture is drawn by a renderer. The
# standalone SVS program does it on Windows, and the official fvsOL interface
# does it in the browser with rgl. uFVS takes the fvsOL route, using the same
# vendored svsTree()/displayTrees() code (R/13_svsTree_upstream.R), so the trees
# look the way the official interface draws them.
# ------------------------------------------------------------------------------

svs_3d_available <- function() {
  isTRUE(requireNamespace("rgl", quietly = TRUE)) &&
    exists("svsTree", mode = "function")
}

#' Convert one parsed SVS row into the tree list svsTree() expects.
#'
#' fvsOL builds this from the raw record; uFVS has already parsed the columns,
#' so this just renames them to the field names the upstream renderer uses.
svs_tree_record <- function(row) {
  list(TrCl = nz(row$trcl, 0), CrCl = nz(row$crcl, 0), Stus = nz(row$stus, 1),
       DBH = nz(row$dbh, 0), Ht = nz(row$ht, 0), Lang = nz(row$lang, 0),
       Fang = nz(row$fang, 0), Crd1 = nz(row$crd1, 0), Cr1 = nz(row$cr1, 0),
       Xloc = nz(row$xloc, 0), Yloc = nz(row$yloc, 0), sp = as.character(row$sp))
}

#' Build the 3D scene for an SVS file and return an rgl widget.
#'
#' @param max_trees guard against very large stands; the plot is a display
#'   sample either way, and every tree drawn is a real FVS record.
svs_scene3d <- function(svs, max_trees = 400, down_trees = TRUE) {
  if (!svs_3d_available()) return(NULL)
  tr <- svs$trees
  if (is.null(tr) || !nrow(tr)) return(NULL)
  tf <- svs_treeforms()[[nz(svs$treeform, "east")]]
  if (is.null(tf)) return(NULL)
  if (!down_trees) tr <- tr[nz(tr$fang, 0) == 0, , drop = FALSE]
  if (!nrow(tr)) return(NULL)
  if (nrow(tr) > max_trees) tr <- tr[seq_len(max_trees), , drop = FALSE]

  # rgl must not try to open a real window inside a server process.
  old <- options(rgl.useNULL = TRUE)
  on.exit(options(old), add = TRUE)
  for (d in rgl::rgl.dev.list()) try(rgl::close3d(), silent = TRUE)
  rgl::open3d(useNULL = TRUE)

  # The display plot, so the trees stand on something.
  w <- nz(svs$plot_size[1], 208.71); h <- nz(svs$plot_size[2], w)
  if (length(svs$circle) >= 3) {
    th <- seq(0, 2 * pi, length.out = 90)
    ring <- cbind(svs$circle[1] + svs$circle[3] * cos(th),
                  svs$circle[2] + svs$circle[3] * sin(th), 0)
    try(rgl::polygon3d(ring, color = "#d9d2c4", alpha = 0.85), silent = TRUE)
  } else {
    try(rgl::quads3d(c(0, w, w, 0), c(0, 0, h, h), c(0, 0, 0, 0),
                     color = "#d9d2c4", alpha = 0.85), silent = TRUE)
  }

  drawn <- list()
  for (i in seq_len(nrow(tr))) {
    one <- tryCatch(svsTree(svs_tree_record(tr[i, ]), tf), error = function(e) NULL)
    if (!is.null(one)) drawn[[length(drawn) + 1L]] <- one
  }
  if (!length(drawn)) return(NULL)
  try(displayTrees(drawn), silent = TRUE)

  # A forester's eye height, looking slightly down at the stand.
  try(rgl::view3d(theta = 1, phi = -45, fov = 30, zoom = 0.85), silent = TRUE)
  rgl::rglwidget(rgl::scene3d())
}

#' Tree cap for the 3D scene. Each tree becomes hundreds of line segments, so
#' a dense stand can take a long time to build and to move in the browser.
SVS_MAX_3D_TREES <- 250L

#' How many stands can sit side by side before the panels become unreadable.
SVS_MAX_PANELS <- 3L
