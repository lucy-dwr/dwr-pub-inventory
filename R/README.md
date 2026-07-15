# R Functions

All pipeline logic lives here. Functions are sourced by `_targets.R` as needed—there is no package structure. Each file defines one primary function (named after the file) plus any private helpers.

---

## Pipeline entry points

These functions are called directly from `_targets.R` as pipeline targets.

| File | Function | What it does |
|---|---|---|
| `create_refresh_id.R` | `create_refresh_id()` | Returns the refresh identifier from config, defaulting to today's date |
| `require_scopus_api_allowed.R` | `require_scopus_api_allowed()` | Guards against accidental Scopus API calls outside intentional harvest steps |
| `save_harvest_candidates.R` | `save_harvest_candidates()` | Persists raw Scopus harvest results to `data/harvests/` |
| `resolve_harvest_candidates_file.R` | `resolve_harvest_candidates_file()` | Resolves the parquet path for a given refresh's harvest snapshot |
| `add_record_keys.R` | `add_record_keys()` | Assigns stable `record_key` identifiers (EID → DOI → hash) |
| `flag_dwr_contributions.R` | `flag_dwr_contributions()` | Adds `is_funder`, `is_author`, `is_lead_author`, `is_sole_author` boolean columns |
| `score_dwr_relevance.R` | `score_dwr_relevance()` | Adds `cdwr_score` — higher means less likely to be a true DWR-funded publication |
| `score_author_affiliation.R` | `score_author_affiliation()` | Adds `caff_score` — higher means the affiliation match needs closer inspection |
| `build_funder_review_queue.R` | `build_funder_review_queue()` | Returns the subset of funder candidates needing manual review this cycle |
| `build_author_review_queue.R` | `build_author_review_queue()` | Returns the subset of affiliation candidates needing manual review this cycle |
| `apply_review_decisions.R` | `apply_review_decisions()` | Drops records marked `"drop"` from a saved decisions CSV |
| `build_affiliation_lookup.R` | `build_affiliation_lookup()` | Sends novel raw affiliation strings to an LLM and builds the canonical lookup |
| `build_institution_reference.R` | `build_institution_reference()` | Builds `data/lookups/institution_reference.txt` from frequent affiliation strings |
| `apply_affiliation_lookup.R` | `apply_affiliation_lookup()` | Replaces raw affiliation strings with canonical names from the lookup |
| `build_institution_geo_lookup.R` | `build_institution_geo_lookup()` | LLM-resolves country/state for each unique canonical institution |
| `join_institution_countries.R` | `join_institution_countries()` | Adds `affiliation_countries` list column using the geo lookup |
| `classify_publications.R` | `classify_publications()` | LLM-classifies each publication into a science field from the taxonomy |
| `append_accepted_publications.R` | `append_accepted_publications()` | Appends newly accepted records to `data/generated/accepted_publications.parquet` |
| `join_author_division.R` | `join_author_division()` | Adds `author_division` using HR lookup and manual division decisions |
| `join_funding_division.R` | `join_funding_division()` | Adds `funding_division` from the funding division lookup |
| `dashboard_download.R` | `format_dashboard_download()` | Formats viewer-facing dashboard CSV downloads, with optional internal division fields |
| `update_funding_division_lookup.R` | `update_funding_division_lookup()` | Syncs accepted funder publications into `data/lookups/funding_division_lookup.csv` |
| `load_pipeline_config.R` | `load_pipeline_config()` | Reads `config/pipeline.yml` into a named list |

---

## Shared helpers

| File | What it exports |
|---|---|
| `author_name_utils.R` | `normalize_scopus_name()`, `author_in_lookup()`, `resolve_author_division()`, `prepare_lookup()` — shared by `score_author_affiliation.R`, `join_author_division.R`, and the Shiny review apps |

---

## Scoring functions

`score_dwr_relevance()` and `score_author_affiliation()` produce integer scores where **0 = most confident** and higher values = more likely to need review. They are used to sort review queues, not as hard filters — all candidates still go through manual review.

---

## LLM-dependent functions

`build_affiliation_lookup()`, `build_institution_geo_lookup()`, and `classify_publications()` require an API key and model configured in `config/pipeline.yml`. They are designed to be re-runnable: already-resolved rows are never re-sent to the LLM.
