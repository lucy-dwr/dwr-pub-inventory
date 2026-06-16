# DWR Publication Inventory

This repository builds a searchable inventory of peer-reviewed publications
funded and/or authored by the California Department of Water Resources (DWR).
It uses a `targets` pipeline to retrieve records from Scopus, support manual
review of funder and author matches, classify publications into a custom
scientific taxonomy with the accompanying `pubclassify` R package, and write
publication datasets for downstream use.

## Applications

- `shiny/funder_review_app.R`: manual review of Scopus funder-search candidates.
- `shiny/author_review_app.R`: manual review of Scopus affiliation-search
  candidates and per-author DWR status.
- `shiny/author_division_resolution_app.R`: division assignment for confirmed
  DWR authors whose division could not be resolved automatically.
- `shiny/dashboard_app.R`: dashboard for browsing the final exported inventory.

## Refresh Workflow

The pipeline uses an append-oriented refresh model. Previously accepted records
are not overwritten in the default mode. Each refresh cycle is organized around
review queues, durable decision files, and a durable accepted-publications table.

### 1. Build Review Queues

```r
Sys.setenv(DWR_REFRESH_ID = "2026-06-08")  # optional; defaults to today's date
targets::tar_make(funder_review_queue_file, author_review_queue_file)
```

This harvests Scopus candidates, assigns stable `record_key` values, saves a
harvest snapshot under `data/harvests/`, and writes the current review queues:

- `data/funder_review_queue.parquet`
- `data/author_review_queue.parquet`

### 2. Review Candidates

Run the funder review app:

```r
shiny::runApp("shiny/funder_review_app.R")
```

Funder decisions are written to `data/funding_review_decisions.csv` with
`keep`, `drop`, or `unsure` decisions keyed by `record_key`.

Run the author review app:

```r
shiny::runApp("shiny/author_review_app.R")
```

Author review writes two files:

- `data/author_review_decisions.csv`: publication-level keep/drop/unsure
  decisions for affiliation-side candidates.
- `data/author_division_decisions.csv`: author-level DWR/not-DWR decisions and resolved
  division metadata where available.

Resolve any confirmed DWR authors that still need manual division assignment:

```r
shiny::runApp("shiny/author_division_resolution_app.R")
```

### 3. Publish The Updated Inventory

```r
targets::tar_make()
```

This applies review decisions, classifies records that are not already in the
accepted-publications table, canonicalizes affiliations, appends newly accepted
records to `data/accepted_publications.parquet`, updates the keep-only funding
division lookup, joins funding and author division fields, and writes dashboard
exports.

The full publish step expects `data/affiliation_lookup.csv` to exist because
`affiliation_lookup_csv` is a file target. Rebuild it with
`R/build_affiliation_lookup.R` when the lookup is missing or stale.

### Refresh Modes

Set `DWR_REFRESH_MODE` before running `targets::tar_make()`:

| Mode | Behavior |
|------|----------|
| `new_records_only` (default) | Classify only records not already accepted |
| `reclassify_all` | Reclassify every record in the current reviewed harvest |

## Project Structure

```text
_targets.R                              # Pipeline definition
config/
  pipeline.yml                          # Non-secret pipeline settings and paths
R/
  add_record_keys.R                     # Assign stable record_key values
  create_refresh_id.R                   # Refresh identity and refresh log management
  save_harvest_candidates.R             # Persist harvest snapshots per refresh
  build_funder_review_queue.R           # Build funder candidates needing review
  build_author_review_queue.R           # Build author/affiliation candidates needing review
  apply_review_decisions.R              # Apply keep/drop decisions from review files
  append_accepted_publications.R        # Append new records to accepted publications
  update_funding_division_lookup.R      # Maintain keep-only funder division lookup
  join_funding_division.R               # Join funding divisions into exports
  join_author_division.R                # Join resolved author divisions into exports
  author_name_utils.R                   # Author lookup/name matching utilities
  score_dwr_relevance.R                 # Funder-review suspicion scoring
  score_author_affiliation.R            # Author-review suspicion scoring
  apply_affiliation_lookup.R            # Canonicalize affiliation strings
  build_affiliation_lookup.R            # Build affiliation lookup table
  build_institution_reference.R         # Build institution reference list
taxonomy/
  dwr_disciplines_taxonomy.csv          # DWR field taxonomy
prompts/
  system_prompt.txt                     # LLM system prompt for classification
  classify_instructions.txt             # LLM classification instructions
data/
  accepted_publications.parquet         # Durable source of truth for accepted records
  refresh_log.csv                       # One row per refresh cycle with counts
  funding_review_decisions.csv           # Funder keep/drop/unsure decisions
  author_review_decisions.csv           # Author-publication keep/drop/unsure decisions
  author_division_decisions.csv                  # Per-author DWR status and division decisions
  funder_review_queue.parquet           # Current funder review queue
  author_review_queue.parquet           # Current author review queue
  funding_division_lookup.csv           # Kept funder records with division assignments
  author_division_lookup.csv            # Required local HR-derived name/year/division lookup
  dwr_org_lookup.csv                    # Raw org label to canonical division mapping
  harvests/                             # Per-refresh candidate snapshots
  affiliation_lookup.csv                # Canonical institution name lookup
  dwr_publications.csv                  # Dashboard export, list columns collapsed
  dwr_publications.parquet              # Dashboard export, native list columns
shiny/
  funder_review_app.R
  author_review_app.R
  author_division_resolution_app.R
  dashboard_app.R
```

`data/author_division_lookup.csv` is ignored by Git and must be available
locally for author scoring and division resolution.

## Setup

Restore R package dependencies with:

```r
renv::restore()
```

The pipeline expects these environment variables:

- `SCOPUS_API_KEY`
- `SCOPUS_INSTTOKEN`
- `PUBCLASSIFY_LLM_KEY`
- `PUBCLASSIFY_EMAIL` (optional)

Non-secret settings such as the LLM model name, endpoint, Scopus search terms,
refresh-mode default, and input/output paths live in `config/pipeline.yml`.
Secrets still come from environment variables.

## Outputs

- `data/accepted_publications.parquet`: durable source of truth; records are
  appended across refreshes in the default mode.
- `data/funding_division_lookup.csv`: manual lookup for funder-query records
  with explicit `keep` decisions in `data/funding_review_decisions.csv`.
- `data/dwr_publications.csv`: dashboard export with list columns collapsed to
  semicolon-delimited strings. Includes `funding_division` and
  `author_division` when available.
- `data/dwr_publications.parquet`: full-fidelity dashboard export used by
  `shiny/dashboard_app.R`. Includes native list columns plus joined division
  fields.
