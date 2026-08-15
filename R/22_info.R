# ------------------------------------------------------------------------------
# Basic project information.
# ------------------------------------------------------------------------------

page_info <- function() {
  tagList(
    page_head("About uFVS"),
    card(NULL,
      p(
        strong("uFVS"),
        " is an open-source interface for working with forest inventory data and the Forest Vegetation Simulator (FVS)."
      ),
      p("It helps users prepare inputs, build management scenarios, run FVS, and review results."),
      div(
        class = "disclaimer",
        strong("uFVS is independent. "),
        "It is not affiliated with, endorsed by, maintained by, or an official product of FVS or the U.S. Forest Service (USFS)."
      ),
      p(
        class = "muted small",
        "FVS remains responsible for the modeled simulation results. Upstream notices and project information are in NOTICE.md."
      ),
      uiOutput("info_versions")
    ),
    card("Contact",
      p("uFVS is developed and maintained by Chris Jacobson."),
      p("Questions, bug reports, and suggestions: ",
        tags$a(href = "mailto:johnchrisjacobson@gmail.com",
               "johnchrisjacobson@gmail.com")),
      p(class = "muted small",
        "This address is for uFVS itself. Questions about FVS, its models, or its ",
        "variants belong with the USDA Forest Service through their own channels."))
  )
}
