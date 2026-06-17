# scripts/patch_classify_na.R
#
# Back-fills pc_field / pc_category / pc_rationale for publications that got NA
# from the LLM classifier due to batch failures (duplicate index, unrecognized
# category, etc.).
#
# Run from the project root:
#   Rscript scripts/patch_classify_na.R
#
# After this script succeeds, run targets::tar_make() to refresh dashboard
# outputs. That re-run is fast — no Scopus calls, no affiliation LLM calls.
# append_accepted_publications() will see all record_keys already present and
# skip re-appending, so the patched classifications are preserved.

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
})

source("R/load_pipeline_config.R")
source("R/classify_publications.R")

cfg <- load_pipeline_config()

pubclassify::pc_configure(
  llm_key      = Sys.getenv("PUBCLASSIFY_LLM_KEY"),
  llm_base_url = cfg$llm$base_url,
  llm_provider = cfg$llm$provider
)

# ── Taxonomy ──────────────────────────────────────────────────────────────────

taxonomy_raw    <- readr::read_csv(cfg$paths$taxonomy, show_col_types = FALSE)
taxonomy        <- pubclassify::pc_taxonomy(dplyr::select(taxonomy_raw, field, definition))
category_lookup <- dplyr::select(taxonomy_raw, pc_category = category, pc_field = field)

# ── Find unclassified pubs ────────────────────────────────────────────────────

accepted <- arrow::read_parquet(cfg$paths$accepted_publications)
na_rows  <- dplyr::filter(accepted, is.na(.data$pc_field))

if (nrow(na_rows) == 0L) {
  message("No unclassified publications found. Nothing to do.")
  quit(save = "no")
}

message(sprintf("Found %d unclassified publication(s). Classifying...", nrow(na_rows)))

# ── Classify ──────────────────────────────────────────────────────────────────

system_prompt  <- readr::read_file(cfg$paths$classify_system_prompt)
classify_instr <- readr::read_file(cfg$paths$classify_user_instructions)

classified <- classify_publications(
  pubs                  = na_rows,
  taxonomy              = taxonomy,
  provider              = cfg$llm$provider,
  model                 = cfg$llm$model,
  base_url              = cfg$llm$base_url,
  system_prompt         = system_prompt,
  classify_instructions = classify_instr
)

classified <- classified |>
  dplyr::select(-dplyr::any_of("pc_category")) |>
  dplyr::left_join(category_lookup, by = "pc_field") |>
  dplyr::relocate(pc_category, .before = pc_field)

# ── Patch accepted_publications.parquet ───────────────────────────────────────

updates <- dplyr::select(
  classified,
  record_key, pc_text_source, pc_classified_by, pc_category, pc_field, pc_rationale
)

patched <- dplyr::rows_update(accepted, updates, by = "record_key", unmatched = "error")

arrow::write_parquet(patched, cfg$paths$accepted_publications)

still_na <- sum(is.na(patched$pc_field))
message(sprintf(
  "Done. Patched %d/%d record(s). %d still NA.",
  nrow(na_rows) - still_na, nrow(na_rows), still_na
))

if (still_na > 0L) {
  message("Some records are still NA — the LLM may have failed again. Re-run to retry.")
} else {
  message("\nNext: run targets::tar_make() to refresh dashboard outputs (~1-2 min).")
}
