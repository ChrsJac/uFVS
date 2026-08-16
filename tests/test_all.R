#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# uFVS verification suite.
#
#   Rscript tests/test_all.R          from the repository root
#
# These are checks against things that can be verified independently: the
# semantics of FVS's own expansion routine, hand-computable statistics, and the
# behavior the runner promises when an engine fails.
# ------------------------------------------------------------------------------

options(ufvs.root = normalizePath(getwd()))
suppressPackageStartupMessages({
  library(jsonlite); library(DBI); library(RSQLite); library(readxl); library(callr); library(digest)
})
for (f in sort(list.files("R", pattern = "[.]R$", full.names = TRUE))) {
  if (grepl("/(20_ui|21_pages|22_info|30_server)[.]R$", f)) next   # need shiny
  source(f)
}

PASS <- 0; FAIL <- 0; MSGS <- character(0)

ok <- function(label, cond, detail = "") {
  if (isTRUE(cond)) {
    PASS <<- PASS + 1; cat(sprintf("  ok   %s\n", label))
  } else {
    FAIL <<- FAIL + 1
    MSGS <<- c(MSGS, label)
    cat(sprintf("  FAIL %s%s\n", label, if (nzchar(detail)) paste0(" — ", detail) else ""))
  }
}
near <- function(a, b, tol = 1e-6) !is.na(a) && !is.na(b) && abs(a - b) <= tol * max(1, abs(b))
section <- function(x) cat(sprintf("\n%s\n", x))

# ------------------------------------------------------------------------------
section("Expansion follows FVS base/notre.f")

# Variable-radius: one 10-inch tree on a BAF-10 point, single plot.
# notre.f: VP = BAF*183.3465/PI, TPA = P*VP/DBH^2. With PI = 1 point:
#   183.3465*10/100 = 18.33465 trees per acre.
des_vr <- list(baf = 10, fpa = 300, brk = 5, tfpa = 0, nplots = 1, grospc_mult = 1)
ok("variable-radius factor matches BAF*183.3465/DBH^2",
   near(tree_expansion_factor(10, des_vr), 10 * 183.3465 / 100))

# A tree below the break diameter uses the small-tree fixed plot instead.
ok("below break DBH uses the fixed small-tree plot",
   near(tree_expansion_factor(4, des_vr), 300))

# Negative BAF is the INVERSE OF A FIXED PLOT AREA, not a prism factor. This is
# the single most consequential convention in the whole file.
des_fx <- list(baf = -10, fpa = 300, brk = 5, tfpa = 0, nplots = 1, grospc_mult = 1)
ok("negative BAF means a 1/10 acre fixed plot, not BAF 10",
   near(tree_expansion_factor(10, des_fx), 10))
ok("negative BAF expansion does not vary with diameter",
   near(tree_expansion_factor(30, des_fx), tree_expansion_factor(10, des_fx)))

# TFPA overrides FPA for the small-tree plot (notre.f: IF(TFPA>0) FP=1/TFPA).
des_tf <- list(baf = 10, fpa = 300, brk = 5, tfpa = 0.01, nplots = 1, grospc_mult = 1)
ok("TFPA overrides INV_PLOT_SIZE below the break diameter",
   near(tree_expansion_factor(4, des_tf), 100))

# Dividing by the number of points.
des_n <- list(baf = -10, fpa = 300, brk = 5, tfpa = 0, nplots = 47, grospc_mult = 1)
ok("stand-level expansion divides by the point count",
   near(tree_expansion_factor(12, des_n) / 47, 10 / 47))

# ------------------------------------------------------------------------------
section("Per-variant DESIGN defaults transcribed from grinit.f")

d <- design_defaults_for("sn")
ok("SN defaults are BAF 40, FPA 300, BRK 5",
   d$baf == 40 && d$fpa == 300 && d$brk == 5,
   sprintf("got %s/%s/%s", d$baf, d$fpa, d$brk))
ok("AK carries its own BAF of 62.5", design_defaults_for("ak")$baf == 62.5)
ok("an unknown variant falls back rather than erroring",
   design_defaults_for("zz")$baf == 40)
ok("all 25 variants are present", length(known_variants()) >= 25)

# ------------------------------------------------------------------------------
section("Species tables")

sn <- species_for_variant("sn")
ok("SN has 90 species codes", nrow(sn) == 90, sprintf("got %d", nrow(sn)))
ok("loblolly pine is LP with FIA code 131",
   "LP" %in% sn$species_code && sn$fia_code[sn$species_code == "LP"] == "131")
ok("species codes are unique within a variant", !anyDuplicated(sn$species_code))

# ------------------------------------------------------------------------------
section("Sampling statistics")

# A vector whose statistics can be checked by hand.
x <- c(10, 20, 30, 40, 50)
s <- sampling_stats(x, 95)
ok("mean", near(s$mean, 30))
ok("variance", near(s$variance, 250))
ok("standard deviation", near(s$sd, sqrt(250)))
ok("standard error", near(s$se, sqrt(250) / sqrt(5)))
ok("degrees of freedom", s$df == 4)
ok("t critical value", near(s$t, qt(0.975, 4)))
ok("confidence limits", near(s$lcl, 30 - qt(0.975, 4) * sqrt(50)) &&
                        near(s$ucl, 30 + qt(0.975, 4) * sqrt(50)))
ok("coefficient of variation", near(s$cv, 100 * sqrt(250) / 30))
ok("relative standard error carries no t multiplier",
   near(s$rse, 100 * sqrt(50) / 30))
ok("sampling error percent does carry the t multiplier",
   near(s$se_pct, 100 * qt(0.975, 4) * sqrt(50) / 30))
ok("sampling error exceeds RSE at 95%", s$se_pct > s$rse)

# Confidence level is free, not a fixed list.
s90 <- sampling_stats(x, 90); s99 <- sampling_stats(x, 99); s87 <- sampling_stats(x, 87.5)
ok("a wider confidence level gives a wider interval",
   (s99$ucl - s99$lcl) > (s$ucl - s$lcl) && (s$ucl - s$lcl) > (s90$ucl - s90$lcl))
# 87.5% is a narrower level than 90%, so its t is smaller, not larger.
ok("a non-standard confidence level works",
   is.finite(s87$t) && near(s87$t, qt(1 - (1 - 0.875) / 2, 4)) && s87$t < s90$t)

# Finite population correction shrinks the standard error.
sf <- sampling_stats(x, 95, population_plots = 10)
ok("finite population correction reduces the standard error", sf$se < s$se)
ok("FPC matches sqrt(1 - n/N)", near(sf$se, s$se * sqrt(1 - 5 / 10)))

# Degenerate input must not throw.
ok("a single observation returns NA rather than failing",
   is.na(sampling_stats(c(5), 95)$sd))
ok("an empty vector returns NA rather than failing",
   is.na(sampling_stats(numeric(0), 95)$mean))

# Required plots.
rq <- required_plots(cv_pct = 50, target_error_pct = 10, conf_level = 95)
ok("required plots converges", isTRUE(rq$converged))
ok("required plots satisfies n = t^2 CV^2 / E^2",
   near(rq$n, ceiling(qt(0.975, rq$n - 1)^2 * 2500 / 100), tol = 0.02))
ok("a tighter target needs more plots",
   required_plots(50, 5, 95)$n > required_plots(50, 10, 95)$n)

# ------------------------------------------------------------------------------
section("A 47-point Southern cruise")

# uFVS ships no data, so the suite builds its own fixture and writes it through
# the real SQLite input path. Set UFVS_TEST_DATA to point at a genuine
# inventory file to run these checks against that instead.
make_fixture <- function() {
  path <- Sys.getenv("UFVS_TEST_DATA", "")
  if (nzchar(path) && file.exists(path)) return(path)

  set.seed(42)
  n_plots <- 47; n_trees <- 387
  stands <- data.frame(
    STAND_ID = "T1", VARIANT = "sn", INV_YEAR = 2024L, NUM_PLOTS = n_plots,
    BASAL_AREA_FACTOR = -10, INV_PLOT_SIZE = NA_real_, BRK_DBH = 2,
    NONSTK_PLOTS = NA_real_, SITE_SPECIES = "LP", SITE_INDEX = 85,
    stringsAsFactors = FALSE)
  # Every plot gets at least one tree so the fixture has no empty units, and
  # diameters stay above the break so a single expansion factor applies.
  plot_id <- c(seq_len(n_plots), sample(seq_len(n_plots), n_trees - n_plots, TRUE))
  trees <- data.frame(
    STAND_ID = "T1", PLOT_ID = as.character(sort(plot_id)),
    TREE_ID = seq_len(n_trees), TREE_COUNT = NA_real_, HISTORY = 1L,
    SPECIES = sample(c("LP", "SP", "SU", "RO", "PO", "HI", "AS"), n_trees, TRUE),
    DIAMETER = round(runif(n_trees, 5, 32), 1),
    HT = ifelse(runif(n_trees) < 0.6, round(runif(n_trees, 40, 130)), NA_real_),
    stringsAsFactors = FALSE)

  f <- file.path(tempdir(), "ufvs_fixture.db")
  unlink(f)
  write_fvs_input_db(list(stands = stands, trees = trees, plots = NULL), f)
  f
}

samp <- make_fixture()
if (!file.exists(samp)) {
  cat("  skip (could not build a fixture)\n")
} else {
  data <- import_fvs_data(samp)
  sid <- data$stands$STAND_ID[1]
  ex <- expand_inventory(data)
  des <- ex$designs[[sid]]

  ok("design read as fixed 1/10 acre plots", des$baf == -10 && near(des$fpa, 300))
  ok("47 plots recognized", des$nplots == 47)
  ok("negative BAF gives one expansion factor for every diameter",
     near(tree_expansion_factor(8, des), tree_expansion_factor(28, des)))
  ok("break diameter came from the inventory, not the default",
     identical(des$source$brk, "inventory"))
  ok("plot size fell back to the variant default",
     identical(des$source$fpa, "variant default"))

  ss <- stand_summary(ex, data)
  # 387 trees, each 10 TPA on its own 1/10 acre plot, over 47 plots.
  ok("trees per acre equals trees x 10 / 47",
     near(ss$TPA, nrow(data$trees) * 10 / 47, tol = 1e-9))
  ok("basal area matches a direct computation",
     near(ss$BA, sum(0.005454154 * data$trees$DIAMETER^2) * 10 / 47, tol = 1e-9))
  ok("QMD inverts the basal area definition",
     near(ss$QMD, sqrt(ss$BA / ss$TPA / 0.005454154)))

  pt <- plot_table(ex, data)
  ok("every cruised plot is a sampling unit", nrow(pt) == 47)
  ok("the plot mean equals the stand estimate", near(mean(pt$BA), ss$BA, tol = 1e-9))
  ok("the plot mean of TPA equals the stand estimate", near(mean(pt$TPA), ss$TPA, tol = 1e-9))

  st <- sampling_stats(pt$BA, 95)
  ok("n is the plot count, not the tree count", st$n_plots == 47)
  ok("standard error is computed over plots",
     near(st$se, sd(pt$BA) / sqrt(47)))
  # The wrong way to do it, for contrast: per-tree records would give a much
  # smaller standard error. Guard against ever drifting back to it.
  tree_se <- sd(ex$trees$BA_PLOT) / sqrt(nrow(ex$trees))
  ok("plot-level SE is materially larger than a per-tree SE would be",
     st$se > 2 * tree_se)

  # Species subsets must include plots where the species is absent.
  tr <- ex$trees[ex$trees$IS_LIVE %in% TRUE, ]
  g <- plot_group_values(tr, pt, "BA_PLOT", "SPECIES")
  ok("each species vector has one entry per plot",
     all(vapply(g, length, numeric(1)) == 47))
  ok("species basal areas add back to the stand total",
     near(sum(vapply(g, mean, numeric(1))), ss$BA, tol = 1e-9))
  ok("absent species contribute zeros, not dropped plots",
     any(vapply(g, function(v) any(v == 0), logical(1))))

  # Product classes are a partition.
  ps <- product_summary_inventory(ex, default_products())
  ok("product classes reproduce the stand TPA",
     near(sum(ps$TPA), ss$TPA, tol = 1e-9))
  ok("product classes reproduce the stand basal area",
     near(sum(ps$BA), ss$BA, tol = 1e-9))

  # Half-open ranges: a tree exactly on a break belongs to exactly one class.
  edge <- data.frame(DBH = c(9, 12), SpeciesFVS = c("LP", "LP"), stringsAsFactors = FALSE)
  a <- assign_products(edge, default_products())
  ok("a tree on a class break lands in the upper class",
     a[1] == "Chip-n-saw" && a[2] == "Sawtimber", paste(a, collapse = "/"))
  species_rule <- list(
    list(name = "All sawtimber", species = "*", min_dbh = 12, max_dbh = 999),
    list(name = "LP sawtimber", species = "LP", min_dbh = 12, max_dbh = 18))
  sp_a <- assign_products(data.frame(DBH = c(14, 20), SpeciesFVS = c("LP", "LP")), species_rule)
  ok("species-specific product classes override all-species fallbacks",
     identical(sp_a, c("LP sawtimber", "All sawtimber")))

  iss <- validate_project(data, ex)
  ok("no validation errors on a clean cruise", sum(iss$severity == "error") == 0)
  ok("the negative BAF convention is explained to the user",
     any(grepl("fixed 1/10 acre", iss$message)))
  ok("the defaulted plot size is flagged",
     any(grepl("INV_PLOT_SIZE missing", iss$message)))
}

# ------------------------------------------------------------------------------
section("Validation catches what stops FVS")

bad <- list(
  stands = data.frame(STAND_ID = "1", VARIANT = "sn", INV_YEAR = 2024, NUM_PLOTS = 2,
                      BASAL_AREA_FACTOR = -10, stringsAsFactors = FALSE),
  trees = data.frame(STAND_ID = "1", PLOT_ID = as.character(1:5), TREE_ID = 1:5,
                     SPECIES = c("LP", "LP", "ZZ", "LP", "LP"),
                     DIAMETER = c(10, 12, 14, NA, 16), HT = 80, HISTORY = 1,
                     stringsAsFactors = FALSE),
  plots = NULL)
iss <- validate_project(bad)
ok("more tallied plots than NUM_PLOTS is an error",
   any(iss$severity == "error" & grepl("More plots tallied", iss$message)))
ok("a species not in the variant is an error",
   any(iss$severity == "error" & grepl("ZZ", iss$message)))
ok("a missing diameter is an error",
   any(iss$severity == "error" & grepl("DIAMETER", iss$message)))

orphan <- bad; orphan$trees$STAND_ID <- "9"
ok("tree records with no stand record are an error",
   any(validate_project(orphan)$severity == "error"))

section("Schema and CSV import fail clearly")

malformed <- list(
  stands = data.frame(STAND_ID = "1", stringsAsFactors = FALSE),
  trees = data.frame(STAND_ID = "1", stringsAsFactors = FALSE), plots = NULL)
schema_issues <- validate_schema(malformed)
ok("schema validation runs before semantic validation",
   schema_blocks(schema_issues))
ok("a missing required tree column is named",
   any(grepl("DIAMETER", schema_issues$message)))
ok("malformed data does not throw a deep subscript error",
   !inherits(try(validate_project(malformed), silent = TRUE), "try-error"))

csv_root <- tempfile("ufvs-csv-set-"); dir.create(csv_root)
csv_stands <- data.frame(STAND_ID = "C1", VARIANT = "sn", INV_YEAR = 2024,
                         NUM_PLOTS = 1, stringsAsFactors = FALSE)
csv_trees <- data.frame(STAND_ID = "C1", PLOT_ID = "1", TREE_ID = 1,
                        SPECIES = "LP", DIAMETER = 10, stringsAsFactors = FALSE)
csv_stand_path <- file.path(csv_root, "FVS_StandInit.csv")
csv_tree_path <- file.path(csv_root, "FVS_TreeInit.csv")
utils::write.csv(csv_stands, csv_stand_path, row.names = FALSE)
utils::write.csv(csv_trees, csv_tree_path, row.names = FALSE)
csv_data <- import_fvs_data(c(csv_stand_path, csv_tree_path),
                            names = c("FVS_StandInit.csv", "FVS_TreeInit.csv"))
ok("paired CSV files import as one FVS inventory",
   nrow(csv_data$stands) == 1 && nrow(csv_data$trees) == 1)
ok("CSV source metadata keeps every selected file",
   length(csv_data$source$paths) == 2)
ok("a single CSV cannot masquerade as a complete inventory",
   inherits(try(import_fvs_data(csv_stand_path), silent = TRUE), "try-error"))

# ------------------------------------------------------------------------------
section("Keyword generation")

kw <- render_keyword("ThinBBA", list("1" = 2030, "2" = 70, "3" = 1, "4" = 5,
                                     "5" = 999, "6" = 0, "7" = 999))
ok("ThinBBA renders with its schedule and parameters",
   grepl("^ThinBBA", kw) && grepl("2030", kw) && grepl("70", kw))

# FVS slices fixed 10-column fields: KARD(I) = RECORD(J:J+9) in base/keyrdr.f.
# The Parms() form the fvsOL templates carry overruns the record for a six
# argument treatment, and FVS then rejects the whole keyword for a mismatched
# parenthesis while still reporting the run as successful. These checks pin the
# fixed-column layout that replaced it.
ok("the record has no Parms() expression", !grepl("Parms", kw, fixed = TRUE))
ok("the keyword sits in columns 1-10", identical(substr(kw, 1, 10), "ThinBBA   "))
ok("the schedule year sits in columns 11-20", identical(trimws(substr(kw, 11, 20)), "2030"))
ok("the first parameter sits in columns 21-30", identical(trimws(substr(kw, 21, 30)), "70"))
ok("the record fits what FVS will read", nchar(kw) <= 130)
ok("named field values land in the right positions",
   identical(trimws(substr(kw, 31, 40)), "1") &&
   identical(trimws(substr(kw, 41, 50)), "5") &&
   identical(trimws(substr(kw, 51, 60)), "999"))

# A named list must not fall through to positional lookup.
partial <- render_keyword("ThinDBH", list("1" = 2035, "2" = 5, "3" = 12, "6" = 100))
ok("unsupplied fields stay blank rather than borrowing a neighbor's value",
   grepl("Parms\\( +5, +12, +, +, +100, +\\)", gsub("\\s+", " ", partial)) ||
   !grepl("100.*100", partial), partial)

ok("the catalog covers the full thinning family",
   all(c("ThinABA", "ThinATA", "ThinBBA", "ThinBTA", "ThinCC", "ThinDBH", "ThinHt",
         "ThinMist", "ThinPRSC", "ThinPt", "ThinQFA", "ThinRDen", "ThinSDI") %in%
       keyword_defs()$keyword))
ok("the catalog spans multiple FVS extensions",
   length(unique(keyword_defs()$extension)) >= 10)
ok("an unknown keyword still renders rather than being unreachable",
   nzchar(render_keyword("ThinRDSL", list("1" = 2030))))

sc <- list(name = "Thin", cycles = 8, cycle_length = 5,
           events = list(list(keyword = "ThinBBA", year = 2030,
                              values = list("2" = 70))),
           raw_keywords = "SDIMAX                    350.")
kf <- build_keyword_file("69", sc, title = "T", inv_years = list("69" = 2024))
ok("keyword file opens each stand with StdIdent", grepl("StdIdent", kf))
ok("keyword file reads the stand from the input database",
   grepl("StandSQL", kf) && grepl("%StandID%", kf))
ok("keyword file requests the output tables uFVS reads",
   grepl("Summary", kf) && grepl("TreeLiDB", kf))
ok("keyword file ends with PROCESS then STOP",
   grepl("PROCESS", kf) && grepl("STOP", kf))
ok("raw user keywords are passed through verbatim", grepl("SDIMAX", kf))
# MgmtId is an A4 keyword whose value is read from the following record.
kf_mgmt_lines <- strsplit(build_keyword_file("69", sc, title = "T",
                                              inv_years = list("69" = 2024)), "\n")[[1]]
mgmt_at <- which(trimws(kf_mgmt_lines) == "MgmtId")[1]
ok("MgmtId places its four-character value on the next record",
   length(mgmt_at) == 1 && identical(trimws(kf_mgmt_lines[mgmt_at + 1]), "THIN"))
# FVS treats '*' and blank records as comments (base/keyrdr.f). Anything else at
# the start of a record is parsed as a keyword.
comment_lines <- grep("^[!#]", strsplit(kf, "\n")[[1]], value = TRUE)
ok("no comment marker FVS would misread as a keyword", length(comment_lines) == 0,
   paste(comment_lines, collapse = " | "))

# ------------------------------------------------------------------------------
section("Scenarios and treatments reach the engine")

# Regression: treatments were rendered with the Parms() form, which overran the
# record FVS reads. FVS reported a mismatched parenthesis, ignored the whole
# treatment, and still exited as a successful run, so a thinned scenario came
# back identical to the untouched one. These pin the record layout.
thin_sc <- list(name = "Thin", cycles = 10, cycle_length = 5, start_year = 2024,
                events = list(list(keyword = "ThinBBA", year = 2034,
                                   values = list("2" = 60, "3" = 1, "4" = 5,
                                                 "5" = 999, "6" = 0, "7" = 999))),
                raw_keywords = "")
kf_thin <- build_keyword_file("T1", thin_sc, title = "t", inv_years = list(T1 = 2024))
kf_lines <- strsplit(kf_thin, "\n")[[1]]
thin_line <- grep("^ThinBBA", kf_lines, value = TRUE)

ok("a scheduled treatment reaches the keyword file", length(thin_line) == 1)
ok("no keyword record exceeds what FVS reads",
   all(nchar(kf_lines) <= 130),
   paste("longest:", max(nchar(kf_lines))))
ok("no treatment carries an unbalanced Parms expression",
   !any(grepl("Parms\\([^)]*$", kf_lines)))
ok("the treatment year lands in the schedule field",
   identical(trimws(substr(thin_line[1], 11, 20)), "2034"))
ok("the residual basal area lands in the first parameter field",
   identical(trimws(substr(thin_line[1], 21, 30)), "60"))

# An empty scenario must not smuggle in a treatment.
base_sc <- list(name = "Base", cycles = 10, cycle_length = 5, start_year = 2024,
                events = list(), raw_keywords = "")
kf_base <- build_keyword_file("T1", base_sc, title = "t", inv_years = list(T1 = 2024))
ok("a scenario with no treatments emits none", !grepl("^Thin", kf_base))
ok("the two scenarios differ", !identical(kf_thin, kf_base))

# TimeInt field 1 is the cycle NUMBER; the length belongs in field 2. Putting
# the length in field 1 silently set one cycle's length and dropped a cycle out
# of the projection.
ti <- grep("^TimeInt", kf_lines, value = TRUE)
ok("TimeInt leaves the cycle-number field blank",
   length(ti) == 1 && !nzchar(trimws(substr(ti[1], 11, 20))), paste(ti, collapse = "|"))
ok("TimeInt puts the cycle length in field 2",
   length(ti) == 1 && identical(trimws(substr(ti[1], 21, 30)), "5"))

control_sc <- list(name = "Controls", cycles = 3, cycle_length = 5,
                   events = list(), raw_keywords = "",
                   volume = list(use_defaults = FALSE,
                                 keywords = list(list(keyword = "Volume",
                                                      values = keyword_defaults("Volume")))),
                   computes = list(list(name = "BA2", expr = "BA*2", when = "0")))
kf_controls <- build_keyword_file("T1", control_sc, title = "controls",
                                  inv_years = list(T1 = 2024))
ok("Volume settings reach the generated keyword file",
   any(grepl("^Volume", strsplit(kf_controls, "\n")[[1]])))
ok("Event Monitor Compute settings reach the generated keyword file",
   grepl("Compute", kf_controls, fixed = TRUE) && grepl("BA2 = BA*2", kf_controls, fixed = TRUE))

# ------------------------------------------------------------------------------
section("Stand visualization reads FVS's own SVS output")

# The SVS keyword must reach the run, or the Visualize page has nothing to show.
svs_sc <- list(name = "V", cycles = 4, cycle_length = 5, start_year = 2024,
               events = list(), raw_keywords = "", svs = TRUE)
kf_svs <- build_keyword_file("T1", svs_sc, title = "v", inv_years = list(T1 = 2024))
ok("the SVS keyword is written when visualization is on",
   any(grepl("^SVS", strsplit(kf_svs, "\n")[[1]])))
svs_off <- build_keyword_file("T1", utils::modifyList(svs_sc, list(svs = FALSE)),
                              title = "v", inv_years = list(T1 = 2024))
ok("and omitted when it is off", !any(grepl("^SVS", strsplit(svs_off, "\n")[[1]])))

# Parse a small SVS file of the shape FVS writes.
svs_dir <- file.path(tempdir(), "ufvs_svs"); dir.create(svs_dir, showWarnings = FALSE)
writeLines(c(
  '#TREELISTINDEX',
  '"Stand=T1 Year=2024 Inventory conditions" "v_001.svs"',
  '"Stand=T1 Year=2029 Beginning of cycle" "v_002.svs"'),
  file.path(svs_dir, "v_index.svs"))
tree_rows <- c(
  "LP                 2  0 0 1  26.0  120. 0   0 0  19.4 0.43  19.4 0.43  19.4 0.43  19.4 0.43 1 0   26.36   33.18 0",
  "SU                 4  0 0 1  10.0   62. 0   0 0   8.1 0.32   8.1 0.32   8.1 0.32   8.1 0.32 1 0   19.80    5.67 0")
for (f in c("v_001.svs", "v_002.svs")) {
  writeLines(c("#TITLE Stand=T1 Year=2024 Inventory conditions", "#TREEFORM EAST.TRF",
               "#FORMAT 2", "#PLOTSIZE 208.71 208.71", "#UNITS ENGLISH",
               ";comment line", tree_rows), file.path(svs_dir, f))
}

idx <- read_svs_index(svs_dir)
ok("the SVS index is read", nrow(idx) == 2)
ok("years come off the index labels", identical(idx$year, c(2024, 2029)))
ok("an absent run directory yields no index", nrow(read_svs_index(tempfile())) == 0)

sv <- read_svs_file(file.path(svs_dir, "v_001.svs"))
ok("tree records parse", !is.null(sv) && nrow(sv$trees) == 2)
ok("the display plot size is read", near(sv$plot_size[1], 208.71))
ok("the tree form is read", identical(sv$treeform, "east"))
ok("comment lines are skipped", all(sv$trees$sp %in% c("LP", "SU")))
# Position and crown come from FVS; getting the column order wrong would put a
# tree in the wrong place with the wrong crown.
ok("position columns land correctly",
   near(sv$trees$xloc[1], 26.36) && near(sv$trees$yloc[1], 33.18))
ok("crown columns land correctly",
   near(sv$trees$crd1[1], 19.4) && near(sv$trees$cr1[1], 0.43))
ok("height and diameter land correctly",
   near(sv$trees$ht[1], 120) && near(sv$trees$dbh[1], 26))

tf <- svs_treeforms()
ok("the official tree forms load", !is.null(tf) && "east" %in% names(tf))
if (!is.null(tf)) {
  form <- svs_form_for(tf$east, "LP", 0)
  ok("a species finds its tree form", !is.null(form) && !is.null(form$LoX))
  ok("an unknown species falls back rather than failing",
     !is.null(svs_form_for(tf$east, "ZZZZ", 0)))
  o <- svs_crown_outline(120, 0.43, 19.4, form)
  ok("a crown outline is produced", !is.null(o) && length(o$x) == length(o$y))
  ok("the crown sits between the crown base and the tip",
     min(o$y) >= 120 * (1 - 0.43) - 1e-6 && max(o$y) <= 120 + 1e-6)
}
ok("a zero-length crown produces no outline",
   is.null(svs_crown_outline(120, 0, 19.4, list(LoX = .7, LoY = .05, HiX = 1, HiY = .55))))

lg <- svs_legend(sv)
ok("the legend lists the species present", nrow(lg) == 2 && all(c("LP", "SU") %in% lg$species))

# ------------------------------------------------------------------------------
section("Chart validation refuses impossible charts with a reason")

ss_tbl <- data.frame(StandID = "1", Year = c(2024, 2029), BA = c(100, 110),
                     Tpa = c(80, 75), SCENARIO = "Base", stringsAsFactors = FALSE)
tl_tbl <- data.frame(StandID = "1", Year = 2024, DBH = c(10, 12), Ht = c(70, 80),
                     TPA = c(1, 1), SpeciesFVS = c("LP", "SU"), PtIndex = c(1, 2),
                     SCENARIO = "Base", stringsAsFactors = FALSE)
tabs <- list(StandSummary = ss_tbl, TreeList = tl_tbl)

mk <- function(x, y, group = "None", fr = "None", fc = "None")
  list(type = "line", x = x, y = y, group = group, facet_row = fr, facet_col = fc,
       summary = "mean", scales = "fixed", points = TRUE, filters = list())

ok("a valid stand-level chart passes", validate_chart(mk("Year", "BA"), tabs)$ok)
ok("a valid tree-level chart passes", validate_chart(mk("DBH", "Ht"), tabs)$ok)
v <- validate_chart(mk("DBH", "BA"), tabs)
ok("mixing tree and stand levels is refused", !v$ok)
ok("the refusal names the levels involved", grepl("level of detail|levels of detail", v$message))
ok("the refusal suggests something usable", nzchar(v$suggestions[1]))
v <- validate_chart(mk("Year", "SpeciesFVS"), tabs)
ok("a categorical Y axis is refused", !v$ok && grepl("not a measurement", v$message))
v <- validate_chart(mk("Year", "Carbon"), tabs)
ok("an unknown variable is refused", !v$ok && grepl("does not know", v$message))
v <- validate_chart(mk("Year", "BA"), list(TreeList = tl_tbl))
ok("a variable whose table the run did not produce is refused", !v$ok)
ok("that refusal names the output keyword that would produce it",
   grepl("Summary|keyword", paste(v$message, v$suggestions)))

# ------------------------------------------------------------------------------
section("Runner isolates engine failure")

if (!file.exists(samp)) {
  cat("  skip (no fixture)\n")
} else {
  data <- import_fvs_data(samp)
  sid <- data$stands$STAND_ID[1]
  base_sc <- list(name = "Base", cycles = 4, cycle_length = 5, events = list())

  run_and_wait <- function(engine) {
    prep <- prepare_run(data, base_sc, sid, engine, title = "test",
                        runs_dir = file.path(tempdir(), "ufvs-run-tests"))
    job <- launch_run(prep, engine)
    # A job refused before launch has no process to wait on.
    if (is.null(job$handle)) return(run_status(job))
    for (i in 1:200) { if (!job$handle$is_alive()) break; Sys.sleep(0.1) }
    run_status(job)
  }

  st <- run_and_wait(list(mode = "none", path = ""))
  ok("no engine configured fails cleanly", identical(st$state, "failed"))
  ok("and says so in words", grepl("No FVS engine", nz(st$message, "")))

  st <- run_and_wait(list(mode = "executable", path = "/nonexistent/FVSsn"))
  ok("a missing executable fails cleanly", identical(st$state, "failed"))
  ok("and names the path it looked for", grepl("nonexistent", nz(st$message, "")))

  # An engine that dies on a signal is the case that would take down an
  # in-process design.
  fake <- file.path(tempdir(), "FVSsn")
  writeLines(c("#!/bin/sh", "echo running", "echo bad >&2", "kill -SEGV $$"), fake)
  Sys.chmod(fake, "0755")
  st <- run_and_wait(list(mode = "executable", path = fake))
  ok("an engine crash is reported, not propagated", identical(st$state, "failed"))
  ok("the exit status is captured", !is.na(nz(st$exit_status, NA)))
  ok("this R session survived the crash", TRUE)
  logs <- run_logs(st$dir)
  ok("engine stdout was captured", "fvs_stdout.log" %in% names(logs))
  ok("engine stderr was captured", "fvs_stderr.log" %in% names(logs))
  ok("the keyword file was preserved for inspection", "run.key" %in% names(logs))

  meta <- jsonlite::fromJSON(file.path(st$dir, "run.json"))
  ok("run metadata records the input hash", nzchar(nz(meta$input_hash, "")))
  ok("run metadata records the keyword hash", nzchar(nz(meta$keyword_hash, "")))
  ok("run metadata records the platform", nzchar(nz(meta$platform, "")))
  ok("input and keyword hashes differ", !identical(meta$input_hash, meta$keyword_hash))
}

# ------------------------------------------------------------------------------
section("Hashing")

ok("distinct inputs hash differently", short_hash("abc") != short_hash("abd"))
ok("hashing is stable", short_hash("abc") == short_hash("abc"))
ok("hashes are not degenerate", !grepl("^0+$", short_hash(list(1, 2))))
if (exists("data") && is.list(data)) {
  h0 <- inventory_hash(data)
  changed_tree <- data
  changed_tree$trees$DIAMETER[1] <- changed_tree$trees$DIAMETER[1] + 0.01
  ok("a change after the first tree is detectable", inventory_hash(changed_tree) != h0)

  changed_plot <- data
  changed_plot$plots <- data.frame(STAND_ID = data$stands$STAND_ID[1], PLOT_ID = "1",
                                   stringsAsFactors = FALSE)
  ok("the plot table contributes to the inventory hash", inventory_hash(changed_plot) != h0)
  ok("the reference configuration has a full SHA-256 hash",
     grepl("^[0-9a-f]{64}$", config_hash()))
}

dispatch_dir <- tempfile("ufvs-engines-"); dir.create(dispatch_dir)
sn_exe <- file.path(dispatch_dir, "FVSsn"); so_exe <- file.path(dispatch_dir, "FVSso")
file.create(sn_exe); file.create(so_exe); Sys.chmod(c(sn_exe, so_exe), "0755")
mix <- list(
  stands = data.frame(STAND_ID = c("S1", "S2"), VARIANT = c("sn", "so"),
                      stringsAsFactors = FALSE),
  trees = data.frame(STAND_ID = c("S1", "S2"), DIAMETER = c(10, 10),
                     stringsAsFactors = FALSE))
disp <- check_variant_dispatch(mix, c("S1", "S2"),
                               list(mode = "bundled", path = dispatch_dir))
ok("mixed variants are dispatched to their matching executables",
   nrow(disp) == 2 && all(disp$ok))
ok("a mismatched configured executable is refused",
   !resolve_engine_exe(list(mode = "executable", path = sn_exe), "so")$ok)

# ------------------------------------------------------------------------------
section("Packaged layout resolution")

# A source checkout sets none of the layout variables and must keep using the
# directories beside app.R. Anything else would break development mode.
layout_vars <- c("UFVS_APP_DIR", "UFVS_RUNTIME_DIR", "UFVS_LIBRARY_DIR",
                 "UFVS_FVS_DIR", "UFVS_RESOURCES_DIR")
saved_layout <- Sys.getenv(layout_vars, unset = NA_character_)
for (v in layout_vars) Sys.unsetenv(v)

root <- ufvs_root()
ok("without launcher variables the engine directory sits beside the app",
   identical(ufvs_engine_dir(), file.path(root, "engine")))
ok("without launcher variables the library sits beside the app",
   identical(ufvs_bundled_library(), file.path(root, "library")))
ok("without launcher variables the runtime sits beside the app",
   identical(ufvs_runtime_dir(), file.path(root, "runtime")))
ok("without launcher variables resources are the app root",
   identical(ufvs_resources_dir(), root))

# A packaged launcher relocates all four, including onto paths with spaces.
layout_root <- file.path(tempdir(), "uFVS layout probe")
for (sub in c("app", "R", "R-library", "fvs", "res")) {
  dir.create(file.path(layout_root, sub), showWarnings = FALSE, recursive = TRUE)
}
Sys.setenv(UFVS_FVS_DIR = file.path(layout_root, "fvs"),
           UFVS_LIBRARY_DIR = file.path(layout_root, "R-library"),
           UFVS_RUNTIME_DIR = file.path(layout_root, "R"),
           UFVS_RESOURCES_DIR = file.path(layout_root, "res"))
ok("a launcher can relocate the FVS directory",
   identical(ufvs_engine_dir(), normalizePath(file.path(layout_root, "fvs"))))
ok("a launcher can relocate the package library",
   identical(ufvs_bundled_library(), normalizePath(file.path(layout_root, "R-library"))))
ok("a launcher can relocate the R runtime",
   identical(ufvs_runtime_dir(), normalizePath(file.path(layout_root, "R"))))
ok("BUILD_INFO.json is read from the resources directory",
   identical(ufvs_release_info_path(),
             file.path(normalizePath(file.path(layout_root, "res")), "BUILD_INFO.json")))

# A relocated bundle is only a release once its build metadata is really there.
ok("a relocated layout without BUILD_INFO.json is not a release",
   !ufvs_is_release())
writeLines("{}", file.path(layout_root, "res", "BUILD_INFO.json"))
ok("a relocated layout with BUILD_INFO.json and a runtime is a release",
   ufvs_is_release())

for (v in layout_vars) {
  if (is.na(saved_layout[[v]])) {
    Sys.unsetenv(v)
  } else {
    do.call(Sys.setenv, stats::setNames(list(saved_layout[[v]]), v))
  }
}
unlink(layout_root, recursive = TRUE, force = TRUE)

section("Desktop lifecycle")

# Closing a browser tab must never stop a developer's shiny::runApp() session.
Sys.unsetenv("UFVS_DESKTOP")
ok("development mode does not tie the process to the browser", !ufvs_desktop_mode())
Sys.setenv(UFVS_DESKTOP = "1")
ok("a launcher can ask for desktop lifecycle", ufvs_desktop_mode())
ok("the idle grace period defaults to something a reload survives",
   ufvs_idle_shutdown_seconds() >= 5)
Sys.setenv(UFVS_IDLE_SECONDS = "3")
ok("the idle grace period is configurable", ufvs_idle_shutdown_seconds() == 3)
Sys.setenv(UFVS_IDLE_SECONDS = "nonsense")
ok("a nonsense grace period falls back to the default",
   ufvs_idle_shutdown_seconds() >= 5)
Sys.unsetenv("UFVS_DESKTOP"); Sys.unsetenv("UFVS_IDLE_SECONDS")

# ------------------------------------------------------------------------------
cat(sprintf("\n%s\n%d passed, %d failed\n", strrep("-", 60), PASS, FAIL))
if (FAIL > 0) {
  cat("Failures:\n"); cat(paste0("  - ", MSGS, collapse = "\n"), "\n")
  quit(status = 1)
}
