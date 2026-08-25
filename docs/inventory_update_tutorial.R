# DWR Publication Inventory: live demo / update tutorial
#
# Run this script from the repository root in an R session.
# The workflow pauses for the manual review steps; continue to the next section
# only after completing the corresponding review app.

# ---- 0. First-time setup ----------------------------------------------------

# Run once on a new machine or after renv.lock changes:
# renv::restore()

# Required before harvesting or classifying records. Store these securely (for
# example, in a local .Renviron file); do not add credential values to this script.
required_environment_variables <- c(
  "SCOPUS_API_KEY",
  "SCOPUS_INSTTOKEN",
  "PUBCLASSIFY_EMAIL",
  "PUBCLASSIFY_LLM_KEY"
)

missing_environment_variables <- required_environment_variables[
  !nzchar(Sys.getenv(required_environment_variables))
]

if (length(missing_environment_variables) > 0L) {
  stop(
    "Set these environment variables before continuing: ",
    paste(missing_environment_variables, collapse = ", "),
    call. = FALSE
  )
}

# ---- 1. Create review queues ------------------------------------------------

# In config/pipeline.yml, set:
#   scopus.allow_api_calls: true
# Optionally set refresh.id; leave it blank to use today's date.
targets::tar_make(names = c(
  funder_review_queue_file,
  author_review_queue_file
))

# IMPORTANT: Set scopus.allow_api_calls: false in config/pipeline.yml now,
# before proceeding with local review and publishing.

# ---- 2. Review funder and author candidates ---------------------------------

# Make decisions in each app, then close the app window before continuing.
shiny::runApp("shiny/funder_review_app.R")
shiny::runApp("shiny/author_review_app.R")
shiny::runApp("shiny/author_division_resolution_app.R")

# ---- 3. Review affiliation lookup -------------------------------------------

targets::tar_make(affiliation_lookup_file)
shiny::runApp("shiny/affiliation_review_app.R")

# ---- 4. Publish accepted records --------------------------------------------

targets::tar_make(names = c(
  accepted_publications_updated,
  funding_division_lookup_updated
))

# Manually open data/lookups/funding_division_lookup.csv and fill in `division`
# for every row where `new == TRUE`. Historically, Mikaela Mamola has done this
# work. Leave the `new` column unchanged.

# ---- 5. Rebuild the dashboard and close the refresh -------------------------

targets::tar_make(names = c(
  dashboard_csv,
  dashboard_parquet,
  refresh_log_completed
))
