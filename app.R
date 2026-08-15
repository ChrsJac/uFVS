# ------------------------------------------------------------------------------
# uFVS - an independent open-source interface for the USDA Forest Service
# Forest Vegetation Simulator.
#
# uFVS is not an official USDA Forest Service product and implements none of the
# FVS science. See the Information page in the running application, and
# NOTICE.md in this repository.
#
# Run with:   shiny::runApp()      from this directory
#         or: Rscript -e 'shiny::runApp(".", launch.browser=TRUE)'
# ------------------------------------------------------------------------------

# Set the root and bundled package library before loading any package. Release
# launchers set UFVS_RELEASE and provide a private library; a source checkout
# continues to use the normal R library paths.
options(ufvs.root = normalizePath(getwd(), mustWork = TRUE))
bundled_library <- file.path(getOption("ufvs.root"), "library")
if (dir.exists(bundled_library)) {
  .libPaths(unique(c(bundled_library, .libPaths())))
  Sys.setenv(R_LIBS_USER = bundled_library)
}

suppressPackageStartupMessages({
  library(shiny)
  library(ggplot2)
  library(jsonlite)
  library(DBI)
  library(RSQLite)
  library(readxl)
  library(callr)
  library(digest)     # SHA-256 provenance hashing
})

# 3D stand visualization is optional: rgl draws it, and uFVS falls back to its
# own 2D views when the package is absent. Loading it must never block startup.
if (requireNamespace("rgl", quietly = TRUE)) {
  options(rgl.useNULL = TRUE)   # never try to open a window from a server
  suppressPackageStartupMessages(library(rgl))
}

options(shiny.maxRequestSize = 200 * 1024^2)   # cruise workbooks get large

for (f in sort(list.files("R", pattern = "\\.R$", full.names = TRUE))) source(f)

shinyApp(ui = ufvs_ui(), server = ufvs_server)
