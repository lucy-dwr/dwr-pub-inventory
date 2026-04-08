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
targets::tar_source("R/")

list(

  # ── Taxonomy ────────────────────────────────────────────────────────────────

  targets::tar_target(taxonomy_file, "taxonomy/dwr_disciplines_taxonomy.csv", format = "file"),

  targets::tar_target(
    taxonomy_raw,
    readr::read_csv(taxonomy_file, show_col_types = FALSE)
  ),

  targets::tar_target(
    taxonomy,
    pubclassify::pc_taxonomy(dplyr::select(taxonomy_raw, field, definition))
  ),

  # ── Funder searches ─────────────────────────────────────────────────────────

  targets::tar_target(
    pubs_funding,
    pubclassify::pc_search_scopus(
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
  targets::tar_target(review_decisions_file, "data/review_decisions.csv", format = "file"),

  targets::tar_target(
    pubs_funding_reviewed,
    apply_review_decisions(pubs_funding, review_decisions_file)
  ),

  # ── Affiliation search ──────────────────────────────────────────────────────

  targets::tar_target(
    pubs_affiliation,
    pubclassify::pc_search_scopus(
      query      = "California Department of Water Resources",
      field      = "affiliation",
      doc_type   = c("article", "review"),
      auto_fetch = TRUE,
      max_results = Inf
    )
  ),

  # ── Combine and flag ────────────────────────────────────────────────────────

  targets::tar_target(
    pubs_combined,
    {
      funder_dois     <- unique(pubs_funding_reviewed$doi)
      affiliation_dois <- unique(pubs_affiliation$doi)
      deduped <- pubclassify::pc_deduplicate(dplyr::bind_rows(pubs_funding_reviewed, pubs_affiliation))
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
  # is_sole_author
  targets::tar_target(
    pubs_flagged,
    flag_dwr_contributions(pubs_combined)
  ),

  # ── Classification ──────────────────────────────────────────────────────────

  # Track prompt files as dependencies so edits trigger reclassification
  targets::tar_target(system_prompt_file,  "prompts/system_prompt.txt",         format = "file"),
  targets::tar_target(classify_instr_file, "prompts/classify_instructions.txt", format = "file"),

  targets::tar_target(system_prompt,  readr::read_file(system_prompt_file)),
  targets::tar_target(classify_instr, readr::read_file(classify_instr_file)),

  # Configuration was set at the top of this file (secret keys, LLM API endpoint, etc.)
  targets::tar_target(
    pubs_classified,
    pubclassify::pc_classify(
      pubs                  = pubs_flagged,
      taxonomy              = taxonomy,
      model                 = "Anthropic Claude Sonnet 4.5",
      system_prompt         = system_prompt,
      classify_instructions = classify_instr
    )
  ),

  # ── Affiliation canonicalisation ────────────────────────────────────────────

  # Track the lookup CSV as a file dependency so that manual edits (or a re-run
  # of build_affiliation_lookup()) automatically invalidate pubs_canonicalized.
  # Build the lookup with:
  #   source("R/build_institution_reference.R")
  #   source("R/build_affiliation_lookup.R")
  #   pubs_classified <- tar_read(pubs_classified)
  #   build_institution_reference(pubs_classified, model = "<model-name>")
  #   build_affiliation_lookup(pubs_classified, model = "<model-name>")
  targets::tar_target(affiliation_lookup_csv, "data/affiliation_lookup.csv", format = "file"),

  targets::tar_target(
    pubs_canonicalized,
    apply_affiliation_lookup(pubs_classified, affiliation_lookup_csv)
  ),

  # ── Enrich with taxonomy top-level category ─────────────────────────────────

  targets::tar_target(
    pubs_enriched,
    {
      category_lookup <- dplyr::select(taxonomy_raw, pc_category = category, pc_field = field)
      dplyr::left_join(pubs_canonicalized, category_lookup, by = "pc_field") |>
        dplyr::relocate(pc_category, .before = pc_field)
    }
  ),

  # ── Outputs ─────────────────────────────────────────────────────────────────

  # Flat CSV with list columns collapsed to semicolon-delimited strings
  targets::tar_target(
    output_csv,
    {
      collapse_list_col <- function(x) {
        vapply(x, function(v) paste(v, collapse = "; "), character(1L))
      }
      flat <- dplyr::mutate(
        pubs_enriched,
        dplyr::across(c(authors, affiliations, funders, grant_numbers),
                      collapse_list_col)
      )
      readr::write_csv(flat, "data/dwr_publications.csv")
      "data/dwr_publications.csv"
    },
    format = "file"
  ),

  # Full-fidelity Parquet with native list columns
  targets::tar_target(
    output_parquet,
    {
      arrow::write_parquet(pubs_enriched, "data/dwr_publications.parquet")
      "data/dwr_publications.parquet"
    },
    format = "file"
  )

)
