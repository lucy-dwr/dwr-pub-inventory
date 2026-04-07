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
    pubs_funder_cdwr,
    pc_search_scopus(
      query      = "California Department of Water Resources",
      field      = "funder",
      doc_type   = c("article", "review"),
      auto_fetch = FALSE
    )
  ),

  tar_target(
    pubs_funder_dwr,
    pc_search_scopus(
      query      = "Department of Water Resources",
      field      = "funder",
      doc_type   = c("article", "review"),
      auto_fetch = FALSE
    )
  ),

  # Combine, deduplicate, and disambiguate funder results.
  # Retains records from pubs_funder_dwr only when they have a 4600-prefix
  # DWR contract number or a California-affiliated author; ambiguous records
  # are flagged for manual review.
  tar_target(
    pubs_funder,
    disambiguate_funder_pubs(pubs_funder_cdwr, pubs_funder_dwr)
  ),

  # ── Affiliation search ───────────────────────────────────────────────────────

  tar_target(
    pubs_affiliation,
    pc_search_scopus(
      query      = "California Department of Water Resources",
      field      = "affiliation",
      doc_type   = c("article", "review"),
      auto_fetch = FALSE
    )
  ),

  # ── Combine and flag ─────────────────────────────────────────────────────────

  # Merge funder and affiliation results, deduplicating by DOI and preserving
  # from_funder / from_affiliation provenance columns.
  tar_target(
    pubs_combined,
    pc_deduplicate(pubs_funder, pubs_affiliation)
  ),

  # Add boolean DWR contribution flags: is_funder, is_author,
  # is_lead_author, is_sole_author.
  tar_target(
    pubs_flagged,
    flag_dwr_contributions(pubs_combined)
  ),

  # ── Classification ───────────────────────────────────────────────────────────

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

  # ── Outputs ──────────────────────────────────────────────────────────────────

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
