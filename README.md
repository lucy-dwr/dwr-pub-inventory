# DWR Publication Inventory

This repository builds a searchable inventory of peer-reviewed publications
funded and/or authored by the California Department of Water Resources (DWR). It
uses a `targets` pipeline to retrieve records from Scopus, apply manual review
where needed, classify publications into a custom scientific taxonomy with
`pubclassify`, and write publication datasets for downstream use.

The repo also includes two Shiny apps:

- `shiny/funder_review_app.R` for manual review of funder-search results
- `shiny/dashboard_app.R` for browsing the final inventory in a dashboard

## Workflow

1. Search Scopus for DWR-linked publications using both funder and affiliation
   queries.
2. Manually review funder matches and save decisions to
   `data/review_decisions.csv`.
3. Deduplicate records and flag DWR contribution types (`is_funder`,
   `is_author`, `is_lead_author`, `is_sole_author`).
4. Classify publications into fields from
   `taxonomy/dwr_disciplines_taxonomy.csv`.
5. Canonicalize affiliations and enrich records with top-level science
   categories.
6. Write outputs to `data/dwr_publications.csv` and
   `data/dwr_publications.parquet`.

## Project Structure

- `_targets.R`: pipeline definition
- `R/`: helper functions used by the pipeline
- `taxonomy/`: DWR field taxonomy
- `prompts/`: LLM system and classification prompts
- `data/`: review decisions, lookup tables, and publication outputs
- `shiny/`: review and dashboard apps

## Setup

Restore R package dependencies with `renv::restore()`.

The pipeline expects these environment variables, which can be securely created
with `pubclassify::pc_configure()`:

- `SCOPUS_API_KEY`
- `SCOPUS_INSTTOKEN`
- `PUBCLASSIFY_LLM_KEY`
- `PUBCLASSIFY_EMAIL` (optional)

`_targets.R` configures the OpenAI-compatible LLM endpoint internally.

## Running

Build the pipeline from the project root:

```r
targets::tar_make()
```

Launch the manual review app:

```r
shiny::runApp("shiny/funder_review_app.R")
```

Launch the dashboard:

```r
shiny::runApp("shiny/dashboard_app.R")
```

## Outputs

- `data/dwr_publications.csv`: flat export with list columns collapsed to
  semicolon-delimited strings
- `data/dwr_publications.parquet`: full-fidelity output used by the dashboard
