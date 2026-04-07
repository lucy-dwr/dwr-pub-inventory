library(targets)
library(pubclassify)

# Load credentials from environment variables
pubclassify::pc_configure(
  scopus_key       = Sys.getenv("SCOPUS_API_KEY"),
  scopus_insttoken = Sys.getenv("SCOPUS_INSTTOKEN"),
  email            = Sys.getenv("PUBCLASSIFY_EMAIL"),
  llm_key          = Sys.getenv("PUBCLASSIFY_LLM_KEY"),
  llm_base_url     = "https://customeruat.sda.state.ca.gov/api/v1",
  llm_provider     = "openai-compatible"
)

# Source custom functions from R/
tar_source("R/")

list(

  # ── Taxonomy ────────────────────────────────────────────────────────────────

  # Track the taxonomy CSV as a file dependency so edits trigger reclassification
  tar_target(taxonomy_file, "taxonomy/dwr_disciplines_taxonomy.csv", format = "file"),

  # Read with all three columns (category, field, definition); category is
  # preserved here so it can be joined back onto classified output later.
  tar_target(
    taxonomy_raw,
    readr::read_csv(taxonomy_file, show_col_types = FALSE)
  ),

  # pc_taxonomy() expects two columns (field, definition); drop category before
  # passing so the shape matches what the function requires.
  tar_target(taxonomy, pc_taxonomy(dplyr::select(taxonomy_raw, field, definition))),

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
    {
      funder_dois     <- unique(pubs_funding_reviewed$doi)
      affiliation_dois <- unique(pubs_affiliation$doi)
      deduped <- pc_deduplicate(dplyr::bind_rows(pubs_funding_reviewed, pubs_affiliation))
      dplyr::mutate(
        deduped,
        query_source = dplyr::case_when(
          doi %in% funder_dois & doi %in% affiliation_dois ~ "funder; affiliation",
          doi %in% funder_dois                             ~ "funder",
          doi %in% affiliation_dois                        ~ "affiliation",
          TRUE                                             ~ NA_character_
        )
      )
    }
  ),

  # Add boolean DWR contribution flags: is_funder, is_author, is_lead_author,
  # is_sole_author.
  tar_target(
    pubs_flagged,
    flag_dwr_contributions(pubs_combined)
  ),

  # ── Classification ──────────────────────────────────────────────────────────

  # Track prompt files as dependencies so edits trigger reclassification
  tar_target(system_prompt_file,  "prompts/system_prompt.txt",         format = "file"),
  tar_target(classify_instr_file, "prompts/classify_instructions.txt", format = "file"),

  tar_target(system_prompt,  readr::read_file(system_prompt_file)),
  tar_target(classify_instr, readr::read_file(classify_instr_file)),

  # Configuration was set at the top of this file (secret keys, LLM API endpoint, etc.)
  tar_target(
    pubs_classified,
    pc_classify(
      pubs                  = pubs_flagged,
      taxonomy              = taxonomy,
      model                 = "Anthropic Claude Sonnet 4.5",
      system_prompt         = system_prompt,
      classify_instructions = classify_instr
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
