library(targets)
library(pubclassify)

# Load credentials from environment variables
pc_configure()

# Source custom functions from R/
tar_source("R/")

list(

  # ── Taxonomy ────────────────────────────────────────────────────────────────

  # Track the taxonomy CSV as a file dependency so edits trigger reclassification
  tar_target(taxonomy_file, "taxonomy/dwr_taxonomy.csv", format = "file"),
  tar_target(taxonomy, pc_taxonomy(taxonomy_file)),

  # ── Funder searches ─────────────────────────────────────────────────────────

  tar_target(
    pubs_funding,
    pc_search_scopus(
      query      = "California Department of Water Resources",
      field      = "funder",
      doc_type   = c("article", "review"),
      auto_fetch = TRUE,
      max_results = Inf
    )
  ),

  # Manual review: track the decisions CSV as a file dependency so that any
  # edits (via the Shiny app) trigger re-evaluation of downstream targets.
  # Launch the review app with: shiny::runApp("shiny/funder_review_app.R")
  tar_target(review_decisions_file, "data/review_decisions.csv", format = "file"),

  # Filter pubs_funding to remove records manually marked "drop".
  tar_target(
    pubs_funding_reviewed,
    apply_review_decisions(pubs_funding, review_decisions_file)
  ),

  # ── Affiliation search ──────────────────────────────────────────────────────

  tar_target(
    pubs_affiliation,
    pc_search_scopus(
      query      = "California Department of Water Resources",
      field      = "affiliation",
      doc_type   = c("article", "review"),
      auto_fetch = TRUE,
      max_results = Inf
    )
  ),

  # ── Combine and flag ────────────────────────────────────────────────────────

  # Merge funder and affiliation results, deduplicating by DOI and preserving
  # from_funder / from_affiliation provenance columns.
  tar_target(
    pubs_combined,
    pc_deduplicate(pubs_funding_reviewed, pubs_affiliation)
  ),

  # Add boolean DWR contribution flags: is_funder, is_author, is_lead_author,
  # is_sole_author.
  tar_target(
    pubs_flagged,
    flag_dwr_contributions(pubs_combined)
  ),

  # ── Classification ──────────────────────────────────────────────────────────

  tar_target(
    pubs_classified,
    pc_classify(
      pubs     = pubs_flagged,
      taxonomy = taxonomy,
      provider = "openai-compatible",
      model    = Sys.getenv("PUBCLASSIFY_LLM_MODEL"),
      api_key  = Sys.getenv("PUBCLASSIFY_LLM_KEY"),
      base_url = Sys.getenv("PUBCLASSIFY_LLM_BASE_URL")
    )
  ),

  # ── Outputs ─────────────────────────────────────────────────────────────────

  # Flat CSV with list columns collapsed to semicolon-delimited strings
  tar_target(
    output_csv,
    {
      collapse_list_col <- function(x) {
        vapply(x, function(v) paste(v, collapse = "; "), character(1L))
      }
      flat <- dplyr::mutate(
        pubs_classified,
        dplyr::across(c(authors, affiliations, funders, grant_numbers),
                      collapse_list_col)
      )
      readr::write_csv(flat, "data/dwr_publications.csv")
      "data/dwr_publications.csv"
    },
    format = "file"
  ),

  # Full-fidelity Parquet with native list columns
  tar_target(
    output_parquet,
    {
      arrow::write_parquet(pubs_classified, "data/dwr_publications.parquet")
      "data/dwr_publications.parquet"
    },
    format = "file"
  )

)
