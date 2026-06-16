source("R/load_pipeline_config.R")

cfg <- load_pipeline_config()

# Load credentials from environment variables
pubclassify::pc_configure(
  scopus_key       = Sys.getenv("SCOPUS_API_KEY"),
  scopus_insttoken = Sys.getenv("SCOPUS_INSTTOKEN"),
  email            = Sys.getenv("PUBCLASSIFY_EMAIL"),
  llm_key          = Sys.getenv("PUBCLASSIFY_LLM_KEY"),
  llm_base_url     = cfg$llm$base_url,
  llm_provider     = cfg$llm$provider
)

# Source custom functions from R/
targets::tar_source("R/")

# ── Operator workflow ──────────────────────────────────────────────────────────
#
# 1. Start a refresh:
#      Sys.setenv(DWR_REFRESH_ID = "2026-06-08")   # optional — defaults to today
#      targets::tar_make(funder_review_queue_file, author_review_queue_file)
#
# 2a. Review funder candidates (confirms DWR funding):
#      shiny::runApp("shiny/funder_review_app.R")
#
# 2b. Review author affiliation candidates (confirms DWR authorship):
#      shiny::runApp("shiny/author_review_app.R")
#
# 3. Publish updated inventory:
#      targets::tar_make()
#
# Refresh modes (set DWR_REFRESH_MODE):
#   new_records_only   — classify only newly harvested records (default)
#   reclassify_all     — reclassify every record in pubs_flagged

list(

  targets::tar_target(
    pipeline_config_file,
    "config/pipeline.yml",
    format = "file"
  ),

  targets::tar_target(
    pipeline_config,
    load_pipeline_config(pipeline_config_file)
  ),

  # ── Taxonomy ──────────────────────────────────────────────────────────────

  targets::tar_target(
    taxonomy_file,
    pipeline_config$paths$taxonomy,
    format = "file"
  ),

  targets::tar_target(
    taxonomy_raw,
    readr::read_csv(taxonomy_file, show_col_types = FALSE)
  ),

  targets::tar_target(
    taxonomy,
    pubclassify::pc_taxonomy(dplyr::select(taxonomy_raw, field, definition))
  ),

  # ── Phase 2: Refresh identity ─────────────────────────────────────────────

  targets::tar_target(
    refresh_id,
    {
      id <- create_refresh_id()
      init_refresh_log(id, log_path = pipeline_config$paths$refresh_log)
      id
    }
  ),

  # ── Scopus searches ───────────────────────────────────────────────────────

  targets::tar_target(
    pubs_funding,
    pubclassify::pc_search_scopus(
      query       = pipeline_config$scopus$searches$funder$query,
      field       = pipeline_config$scopus$searches$funder$field,
      doc_type    = unlist(pipeline_config$scopus$doc_types),
      auto_fetch  = pipeline_config$scopus$auto_fetch,
      max_results = pipeline_config$scopus$max_results
    )
  ),

  targets::tar_target(
    pubs_affiliation,
    pubclassify::pc_search_scopus(
      query       = pipeline_config$scopus$searches$affiliation$query,
      field       = pipeline_config$scopus$searches$affiliation$field,
      doc_type    = unlist(pipeline_config$scopus$doc_types),
      auto_fetch  = pipeline_config$scopus$auto_fetch,
      max_results = pipeline_config$scopus$max_results
    )
  ),

  # ── Phase 1 & 2: Assign record keys and attach harvest metadata ───────────

  targets::tar_target(
    pubs_funding_keyed,
    dplyr::mutate(
      add_record_keys(pubs_funding),
      harvest_id   = refresh_id,
      harvested_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S")
    ) |>
      dplyr::filter(!is.na(.data$doi) & nzchar(trimws(.data$doi)))
  ),

  targets::tar_target(
    pubs_affiliation_keyed,
    dplyr::mutate(
      add_record_keys(pubs_affiliation),
      harvest_id   = refresh_id,
      harvested_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S")
    ) |>
      dplyr::filter(!is.na(.data$doi) & nzchar(trimws(.data$doi)))
  ),

  # ── Phase 3: Combine into harvest candidates with corrected query_source ──

  targets::tar_target(
    pubs_harvest_candidates,
    {
      funder_keys <- unique(pubs_funding_keyed$record_key)
      affil_keys  <- unique(pubs_affiliation_keyed$record_key)
      deduped     <- pubclassify::pc_deduplicate(
        dplyr::bind_rows(pubs_funding_keyed, pubs_affiliation_keyed)
      )
      dplyr::mutate(
        deduped,
        query_source = dplyr::case_when(
          record_key %in% funder_keys & record_key %in% affil_keys ~ "funder; affiliation",
          record_key %in% funder_keys                              ~ "funder",
          record_key %in% affil_keys                               ~ "affiliation",
          TRUE                                                     ~ NA_character_
        )
      )
    }
  ),

  # Persist the full candidate set for this refresh cycle
  targets::tar_target(
    harvest_candidates_file,
    save_harvest_candidates(
      pubs_harvest_candidates,
      refresh_id,
      harvests_dir = pipeline_config$paths$harvests_dir
    ),
    format = "file"
  ),

  # ── Phase 5: Build the manual-review queue ────────────────────────────────

  targets::tar_target(
    funder_review_queue,
    build_funder_review_queue(
      pubs_harvest_candidates,
      decisions_path = pipeline_config$paths$funder_review_decisions,
      accepted_path  = pipeline_config$paths$accepted_publications
    )
  ),

  # Write funder queue to file so the Shiny app can read it
  targets::tar_target(
    funder_review_queue_file,
    {
      arrow::write_parquet(funder_review_queue, pipeline_config$paths$funder_review_queue)
      pipeline_config$paths$funder_review_queue
    },
    format = "file"
  ),

  # ── Author affiliation review queue ───────────────────────────────────────

  targets::tar_target(
    author_review_queue,
    build_author_review_queue(
      pubs_harvest_candidates,
      decisions_path = pipeline_config$paths$author_review_decisions,
      accepted_path  = pipeline_config$paths$accepted_publications,
      lookup_path    = pipeline_config$paths$author_division_lookup
    )
  ),

  targets::tar_target(
    author_review_queue_file,
    {
      arrow::write_parquet(author_review_queue, pipeline_config$paths$author_review_queue)
      pipeline_config$paths$author_review_queue
    },
    format = "file"
  ),

  # ── Phase 4: Apply manual review decisions ────────────────────────────────

  # Track both decisions CSVs as file dependencies so that any edits (via the
  # Shiny apps) trigger re-evaluation of all downstream targets.
  targets::tar_target(
    funder_review_decisions_file,
    pipeline_config$paths$funder_review_decisions,
    format = "file"
  ),

  targets::tar_target(
    author_review_decisions_file,
    pipeline_config$paths$author_review_decisions,
    format = "file"
  ),

  targets::tar_target(
    author_decisions_file,
    pipeline_config$paths$author_decisions,
    format = "file"
  ),

  targets::tar_target(
    pubs_funding_reviewed,
    apply_review_decisions(
      dplyr::filter(pubs_harvest_candidates,
                    grepl("funder", .data$query_source, fixed = TRUE)),
      funder_review_decisions_file
    )
  ),

  targets::tar_target(
    pubs_affiliation_reviewed,
    apply_review_decisions(
      dplyr::filter(pubs_harvest_candidates,
                    grepl("affiliation", .data$query_source, fixed = TRUE)),
      author_review_decisions_file
    )
  ),

  # ── Combine reviewed funder and affiliation records ───────────────────────
  # For "funder; affiliation" overlap records, correct query_source based on
  # review outcomes so flag_dwr_contributions() sets is_funder / is_author
  # correctly. Both decisions files are already transitive dependencies via
  # the _reviewed targets above.

  targets::tar_target(
    pubs_combined,
    {
      combined <- dplyr::bind_rows(pubs_funding_reviewed, pubs_affiliation_reviewed) |>
        dplyr::distinct(.data$record_key, .keep_all = TRUE)

      read_drops <- function(path) {
        if (!file.exists(path)) return(character())
        d <- readr::read_csv(path, show_col_types = FALSE,
                             col_types = readr::cols(.default = readr::col_character()))
        d$record_key[!is.na(d$decision) & d$decision == "drop"]
      }
      funder_drops <- read_drops(pipeline_config$paths$funder_review_decisions)
      author_drops <- read_drops(pipeline_config$paths$author_review_decisions)

      dplyr::mutate(combined,
        query_source = dplyr::case_when(
          .data$record_key %in% funder_drops &
            .data$query_source == "funder; affiliation" ~ "affiliation",
          .data$record_key %in% author_drops &
            .data$query_source == "funder; affiliation" ~ "funder",
          TRUE ~ .data$query_source
        )
      )
    }
  ),

  targets::tar_target(
    pubs_flagged,
    flag_dwr_contributions(pubs_combined)
  ),

  # ── Phase 8: Filter to records not yet in the accepted-publications table ──

  # Side-reads data/accepted_publications.parquet without creating a formal
  # targets dependency (which would cause a cycle). The filter is only
  # bypassed when DWR_REFRESH_MODE=reclassify_all.
  targets::tar_target(
    pubs_to_classify,
    {
      refresh_mode <- Sys.getenv("DWR_REFRESH_MODE", unset = pipeline_config$refresh$default_mode)
      if (refresh_mode == "reclassify_all") {
        message("pubs_to_classify: reclassify_all mode — classifying all ", nrow(pubs_flagged), " records.")
        pubs_flagged
      } else {
        if (file.exists(pipeline_config$paths$accepted_publications)) {
          already_accepted <- arrow::read_parquet(pipeline_config$paths$accepted_publications)$record_key
          new_only <- dplyr::filter(pubs_flagged, !.data$record_key %in% already_accepted)
          message(sprintf(
            "pubs_to_classify: new_records_only mode — %d new record(s) to classify (%d already accepted).",
            nrow(new_only), length(already_accepted)
          ))
          new_only
        } else {
          pubs_flagged
        }
      }
    }
  ),

  # ── Classification ────────────────────────────────────────────────────────

  targets::tar_target(
    system_prompt_file,
    pipeline_config$paths$system_prompt,
    format = "file"
  ),
  targets::tar_target(
    classify_instr_file,
    pipeline_config$paths$classify_instructions,
    format = "file"
  ),

  targets::tar_target(system_prompt,  readr::read_file(system_prompt_file)),
  targets::tar_target(classify_instr, readr::read_file(classify_instr_file)),

  targets::tar_target(
    pubs_classified,
    if (nrow(pubs_to_classify) == 0L) {
      message("pubs_classified: no new records to classify.")
      pubs_to_classify
    } else {
      pubclassify::pc_classify(
        pubs                  = pubs_to_classify,
        taxonomy              = taxonomy,
        model                 = pipeline_config$llm$model,
        system_prompt         = system_prompt,
        classify_instructions = classify_instr
      )
    }
  ),

  # ── Affiliation canonicalization ──────────────────────────────────────────

  targets::tar_target(affiliation_lookup_csv, pipeline_config$paths$affiliation_lookup, format = "file"),

  targets::tar_target(
    pubs_canonicalized,
    if (nrow(pubs_classified) == 0L) {
      pubs_classified
    } else {
      apply_affiliation_lookup(pubs_classified, affiliation_lookup_csv)
    }
  ),

  # ── Enrich with taxonomy top-level category ───────────────────────────────

  targets::tar_target(
    pubs_enriched,
    {
      category_lookup <- dplyr::select(taxonomy_raw, pc_category = category, pc_field = field)
      if (nrow(pubs_canonicalized) == 0L || !"pc_field" %in% names(pubs_canonicalized)) {
        pubs_canonicalized
      } else {
        dplyr::left_join(pubs_canonicalized, category_lookup, by = "pc_field") |>
          dplyr::relocate(pc_category, .before = pc_field)
      }
    }
  ),

  # ── Phase 7: Append to durable accepted-publications table ───────────────

  targets::tar_target(
    accepted_publications_updated,
    append_accepted_publications(
      pubs_enriched,
      refresh_id,
      accepted_path = pipeline_config$paths$accepted_publications
    ),
    format = "file"
  ),

  # ── Phase 8: Update keep-only funding division lookup ────────────────────

  targets::tar_target(
    funding_division_lookup_updated,
    update_funding_division_lookup(
      accepted_path = accepted_publications_updated,
      decisions_path = pipeline_config$paths$funder_review_decisions,
      lookup_path   = pipeline_config$paths$funding_division_lookup
    ),
    format = "file"
  ),

  # ── Phase 9: Export dashboard dataset from accepted records ──────────────

  targets::tar_target(
    output_csv,
    {
      pubs <- arrow::read_parquet(accepted_publications_updated) |>
        join_funding_division(funding_division_lookup_updated) |>
        join_author_division(
          pipeline_config$paths$author_division_lookup,
          pipeline_config$paths$dwr_org_lookup,
          author_decisions_file
        )
      collapse_list_col <- function(x) {
        vapply(x, function(v) paste(unlist(v), collapse = "; "), character(1L))
      }
      list_cols <- intersect(c("authors", "affiliations", "funders", "grant_numbers"), names(pubs))
      flat <- dplyr::mutate(pubs, dplyr::across(dplyr::all_of(list_cols), collapse_list_col))
      readr::write_csv(flat, pipeline_config$paths$output_csv)
      pipeline_config$paths$output_csv
    },
    format = "file"
  ),

  targets::tar_target(
    output_parquet,
    {
      pubs <- arrow::read_parquet(accepted_publications_updated) |>
        join_funding_division(funding_division_lookup_updated) |>
        join_author_division(
          pipeline_config$paths$author_division_lookup,
          pipeline_config$paths$dwr_org_lookup,
          author_decisions_file
        )
      arrow::write_parquet(pubs, pipeline_config$paths$output_parquet)
      pipeline_config$paths$output_parquet
    },
    format = "file"
  ),

  # ── Phase 10: Complete the refresh log ───────────────────────────────────

  targets::tar_target(
    refresh_log_completed,
    {
      decisions <- readr::read_csv(funder_review_decisions_file, show_col_types = FALSE,
                                   col_types = readr::cols(.default = readr::col_character()))
      this_refresh <- dplyr::filter(decisions, .data$review_refresh_id == refresh_id)
      n_accepted <- nrow(arrow::read_parquet(accepted_publications_updated))
      complete_refresh_log(
        refresh_id               = refresh_id,
        log_path                 = pipeline_config$paths$refresh_log,
        n_funder_candidates      = nrow(pubs_funding),
        n_affiliation_candidates = nrow(pubs_affiliation),
        n_new_candidates         = nrow(funder_review_queue),
        n_reviewed               = nrow(this_refresh),
        n_kept                   = sum(this_refresh$decision == "keep",   na.rm = TRUE),
        n_dropped                = sum(this_refresh$decision == "drop",   na.rm = TRUE),
        n_unsure                 = sum(this_refresh$decision == "unsure", na.rm = TRUE),
        n_accepted               = n_accepted
      )
      pipeline_config$paths$refresh_log
    },
    format = "file"
  )

)
