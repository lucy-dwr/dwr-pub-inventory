# DWR Publication Inventory

This repository builds a searchable inventory of peer-reviewed publications
funded and/or authored by the California Department of Water Resources (DWR).
It uses a `targets` pipeline to retrieve records from Scopus, support efficient 
manual review of funder and author matches, classify publications into a custom
scientific taxonomy with the accompanying `pubclassify` R package, and write
publication datasets for downstream use.

## Applications

- `shiny/funder_review_app.R`: manual review of Scopus funder search candidates.
- `shiny/author_review_app.R`: manual review of Scopus affiliation search
  candidates and per-author DWR affiliation status.
- `shiny/author_division_resolution_app.R`: division assignment for confirmed
  DWR authors whose division could not be resolved automatically.
- `shiny/dashboard_app.R`: dashboard for browsing the final exported inventory.

## Refresh Workflow

The pipeline uses an append-oriented refresh model. Previously accepted records
are not overwritten in the default mode. Each refresh cycle is organized around
review queues, durable decision files, and a durable accepted publications table.

### 1. Build Review Queues

```r
Sys.setenv(DWR_REFRESH_ID = "2026-06-15")  # optional; defaults to today's date
targets::tar_make(funder_review_queue_file, author_review_queue_file)
```

This harvests Scopus candidates, assigns stable `record_key` values, saves a
harvest snapshot under `data/harvests/`, and writes the current review queues:

- `data/queues/funder_review_queue.parquet`
- `data/queues/author_review_queue.parquet`

### 2. Review Candidates

#### Funded

Run the funder review app:

```r
shiny::runApp("shiny/funder_review_app.R")
```

Funder decisions are written to `data/decisions/funding_review_decisions.csv` with
`keep`, `drop`, or `unsure` decisions keyed by `record_key`.

#### Authored

Run the author review app:

```r
shiny::runApp("shiny/author_review_app.R")
```

Author review writes two files:

- `data/decisions/author_review_decisions.csv`: publication-level keep/drop/unsure
  decisions for DWR affiliation candidates.
- `data/decisions/author_division_decisions.csv`: author-level DWR/not-DWR decisions and resolved division metadata where available.

Resolve any confirmed DWR authors that still need manual division assignment by
running:

```r
shiny::runApp("shiny/author_division_resolution_app.R")
```

### 3. Publish The Updated Inventory

```r
targets::tar_make()
```

This applies review decisions, classifies records that are not already in the
accepted publications table, canonicalizes affiliations, appends newly accepted
records to `data/generated/accepted_publications.parquet`, updates the keep-only
funding division lookup, joins funding and author division fields, and writes
dashboard exports.

The full publish step expects `data/lookups/affiliation_lookup.csv` to exist
because `affiliation_lookup_csv` is a file target. Rebuild it with
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
README.md                               # Project overview and operator quickstart
REFRESH_WORKFLOW.md                     # Detailed refresh workflow
PLAN.md                                 # Implementation notes and deferred work
SPEC.md                                 # Current dashboard specification
LICENSE

config/
  pipeline.yml                          # Non-secret pipeline settings and paths

R/
  load_pipeline_config.R                # Read config/pipeline.yml
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
  flag_dwr_contributions.R              # Add contribution-type boolean flags
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
  refresh_log.csv                       # One row per refresh cycle with counts
  decisions/
    funding_review_decisions.csv        # Funder keep/drop/unsure decisions
    author_review_decisions.csv         # Author-publication keep/drop/unsure decisions
    author_division_decisions.csv       # Per-author DWR status and division decisions
  lookups/
    funding_division_lookup.csv         # Kept funder records with division assignments
    dwr_org_lookup.csv                  # Raw org label to canonical division mapping
    institution_reference.txt           # Institution reference list for lookup generation
    affiliation_lookup.csv              # Canonical institution name lookup; may be absent until rebuilt
    author_division_lookup.csv          # Required local HR-derived lookup; ignored by Git
  generated/
    accepted_publications.parquet       # Durable source of truth; generated by pipeline
    dwr_publications.csv                # Dashboard export, list columns collapsed
    dwr_publications.parquet            # Dashboard export, native list columns
  queues/
    funder_review_queue.parquet         # Generated funder review queue; ignored by Git
    author_review_queue.parquet         # Generated author review queue; ignored by Git
  harvests/                             # Per-refresh candidate snapshots; ignored by Git

shiny/                                  # Review and visualization apps
  funder_review_app.R
  author_review_app.R
  author_division_resolution_app.R
  dashboard_app.R
  www/
    dwr-logo-new.png                    # Dashboard logo asset

renv/
  activate.R
  settings.json
renv.lock                               # R dependency lockfile
```

**`data/lookups/author_division_lookup.csv` is ignored by Git and must be available**
**locally for author scoring and division resolution.**

## Setup

Restore R package dependencies with:

```r
renv::restore()
```

The pipeline expects these environment variables:

- `SCOPUS_API_KEY`
- `SCOPUS_INSTTOKEN`
- `PUBCLASSIFY_LLM_KEY`
- `PUBCLASSIFY_EMAIL` (optional for API polite pools)

Non-secret settings such as the LLM model name, endpoint, Scopus search terms,
refresh-mode default, and input/output paths live in `config/pipeline.yml`.
Secrets still come from environment variables.

Note that you must manually add the file data/lookups/author_division_lookup.csv
to the repository; it is not published on GitHub for personnel privacy reasons.

**TODO: DISCUSS STRUCTURE OF AUTHOR DIVISION LOOKUP FILE**

## Outputs

- `data/generated/accepted_publications.parquet`: durable source of truth; records are
  appended across refreshes in the default mode.
- `data/lookups/funding_division_lookup.csv`: manual lookup for funder-query records
  with explicit `keep` decisions in `data/decisions/funding_review_decisions.csv`.
  Newly accepted current-refresh rows are prepended; `new == TRUE` means the
  row still needs a funding division assignment from the current refresh.
- `data/generated/dwr_publications.csv`: dashboard export with list columns collapsed to
  semicolon-delimited strings. Includes `funding_division` and
  `author_division` when available.
- `data/generated/dwr_publications.parquet`: full-fidelity dashboard export used by
  `shiny/dashboard_app.R`. Includes native list columns plus joined division
  fields.
