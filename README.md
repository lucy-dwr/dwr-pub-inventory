# DWR Publication Inventory

This repository builds a searchable inventory of peer-reviewed publications
funded and/or authored by the California Department of Water Resources (DWR). It
uses a `targets` pipeline to retrieve records from Scopus, apply manual review
where needed, classify publications into a custom scientific taxonomy with the
accompanying `pubclassify` R package, and write publication datasets for downstream
use.

The repo also includes two Shiny apps:

- `shiny/funder_review_app.R` for manual review of funder search results
- `shiny/dashboard_app.R` for browsing the final inventory in a dashboard

## Workflow

The pipeline uses an append-oriented refresh model. Previously accepted records
are never overwritten. Each refresh cycle runs in three steps:

**Step 1 — Build the review queue:**

```r
Sys.setenv(DWR_REFRESH_ID = "2026-06-08")  # optional; defaults to today's date
targets::tar_make(review_queue_file)
```

This harvests Scopus candidates, assigns stable record keys, and writes a
Parquet review queue of funder candidates that have not yet been reviewed or
accepted to `data/review_queue.parquet`.

**Step 2 — Review funder candidates:**

```r
shiny::runApp("shiny/funder_review_app.R")
```

Review each candidate and indicate whether DWR funded the article by marking it
`keep` (funding confirmed), `drop` (no evidence of funding), or `unsure` (funding
unsure, usually due to a paywall prohibiting article review). Decisions are
written to `data/review_decisions.csv` keyed by `record_key`.

**Step 3 — Publish the updated inventory:**

```r
targets::tar_make()
```

This applies decisions, classifies new accepted records, appends them to
`data/accepted_publications.parquet`, updates the funding-division lookup for
funder records that explicitly passed review, and regenerates the dashboard
exports.

### Refresh modes

Set `DWR_REFRESH_MODE` before running `tar_make()`:

| Mode | Behaviour |
|------|-----------|
| `new_records_only` (default) | Classify only records not already accepted |
| `reclassify_all` | Reclassify every record in the current harvest |

## Project Structure

```
_targets.R                              # Pipeline definition
config/
  pipeline.yml                          # Non-secret pipeline settings
R/
  add_record_keys.R                     # Assign stable record_key to each publication
  create_refresh_id.R                   # Refresh identity and refresh log management
  save_harvest_candidates.R             # Persist harvest snapshots per refresh
  build_review_queue.R                  # Filter candidates needing manual review
  apply_review_decisions.R              # Apply keep/drop decisions from review
  append_accepted_publications.R        # Safe append to the accepted-publications table
  update_funding_division_lookup.R      # Maintain keep-only funder DOI -> division lookup
  join_funding_division.R               # Join funding divisions into dashboard exports
  flag_dwr_contributions.R              # Add is_funder / is_author / … boolean flags
  score_dwr_relevance.R                 # Heuristic suspicion scoring for review prioritization
  apply_affiliation_lookup.R            # Canonicalize affiliation strings
  build_affiliation_lookup.R            # Build the affiliation lookup table (one-time)
  build_institution_reference.R         # Build the institution reference list (one-time)
taxonomy/
  dwr_disciplines_taxonomy.csv          # DWR field taxonomy
prompts/
  system_prompt.txt                     # LLM system prompt for classification
  classify_instructions.txt             # LLM classification instructions
data/
  accepted_publications.parquet         # Durable source of truth — all accepted records
  refresh_log.csv                       # One row per refresh cycle with counts
  review_decisions.csv                  # Manual keep/drop/unsure decisions (keyed by record_key)
  review_queue.parquet                  # Current review queue (built by pipeline; read by app)
  funding_division_lookup.csv           # Keep-only funder records with manual division assignments
  harvests/                             # Per-refresh candidate snapshots
  affiliation_lookup.csv                # Canonical institution name lookup
  dwr_publications.csv                  # Dashboard export (flat, list cols collapsed)
  dwr_publications.parquet              # Dashboard export (native list cols)
shiny/
  funder_review_app.R                   # Manual review app
  dashboard_app.R                       # Publication inventory dashboard
```

## Setup

Restore R package dependencies with `renv::restore()`.

The pipeline expects these environment variables, which can be securely created
with `pubclassify::pc_configure()`:

- `SCOPUS_API_KEY`
- `SCOPUS_INSTTOKEN`
- `PUBCLASSIFY_LLM_KEY`
- `PUBCLASSIFY_EMAIL` (optional; helpful for joining API polite pools)

Non-secret pipeline settings such as the LLM model name, endpoint, Scopus
search terms, refresh-mode default, and input/output paths live in
`config/pipeline.yml`. Secrets still come from environment variables.

## Outputs

- `data/accepted_publications.parquet`: durable source of truth; records are
  appended across refreshes and never overwritten by default
- `data/funding_division_lookup.csv`: manual lookup for funder-query records
  with explicit `keep` decisions in `data/review_decisions.csv`; columns are
  `doi`, `doi_url`, `year`, `title`, `division`, and `new`
- `data/dwr_publications.csv`: dashboard export with list columns collapsed to
  semicolon-delimited strings; derived from `accepted_publications.parquet`
  and includes `funding_division` joined from `funding_division_lookup.csv`
- `data/dwr_publications.parquet`: full-fidelity dashboard export used by
  `shiny/dashboard_app.R`; derived from `accepted_publications.parquet` and
  includes `funding_division` joined from `funding_division_lookup.csv`
