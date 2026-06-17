# DWR Publication Inventory - Implementation Notes

This document summarizes the current implementation and the remaining planned
work. For operator instructions, see `README.md`.

## Current Architecture

The project is organized around a `targets` pipeline in `_targets.R`.

The pipeline:

1. Loads non-secret settings from `config/pipeline.yml`.
2. Searches Scopus for DWR funder and affiliation candidates.
3. Assigns stable `record_key` values.
4. Saves a refresh-specific candidate snapshot under `data/harvests/`.
5. Builds separate funder and author review queues.
6. Applies review decisions from durable CSV files.
7. Flags DWR contribution types.
8. Maintains and applies the affiliation lookup through
   `data/lookups/affiliation_lookup.csv`.
9. Classifies new canonicalized records into the DWR taxonomy.
10. Appends accepted records to `data/generated/accepted_publications.parquet`.
11. Updates the keep-only funding division lookup.
12. Joins funding and author division fields into dashboard exports.

## Operator Workflow

```r
# In config/pipeline.yml, set scopus.allow_api_calls: true for an intentional harvest.
# Optionally set refresh.id; blank defaults to today's date.

# Build both review queues
targets::tar_make(funder_review_queue_file, author_review_queue_file)

# Review funder candidates
shiny::runApp("shiny/funder_review_app.R")

# Review author/affiliation candidates
shiny::runApp("shiny/author_review_app.R")

# Resolve any confirmed DWR authors with missing divisions
shiny::runApp("shiny/author_division_resolution_app.R")

# Build/refresh affiliation lookup; review unresolved rows before publishing
targets::tar_make(affiliation_lookup_file)
shiny::runApp("shiny/affiliation_review_app.R")

# Publish accepted records and dashboard exports
targets::tar_make()
```

## Key Source Files

| File | Purpose |
|------|---------|
| `_targets.R` | Pipeline definition |
| `config/pipeline.yml` | Non-secret paths, model, Scopus search settings |
| `R/add_record_keys.R` | Stable record key assignment |
| `R/create_refresh_id.R` | Refresh ID and refresh-log helpers |
| `R/save_harvest_candidates.R` | Per-refresh harvest snapshot writer |
| `R/build_funder_review_queue.R` | Funder review queue construction |
| `R/build_author_review_queue.R` | Author/affiliation review queue construction |
| `R/apply_review_decisions.R` | Shared keep/drop filtering |
| `R/append_accepted_publications.R` | Append new accepted records |
| `R/update_funding_division_lookup.R` | Keep-only funding division lookup update |
| `R/join_funding_division.R` | Export-time funding division join |
| `R/join_author_division.R` | Export-time author division join |
| `R/author_name_utils.R` | Author lookup and division matching utilities |
| `R/score_dwr_relevance.R` | Funder review suspicion scoring |
| `R/score_author_affiliation.R` | Author review suspicion scoring |
| `R/apply_affiliation_lookup.R` | Affiliation canonicalization |
| `R/build_affiliation_lookup.R` | Affiliation lookup generation |
| `R/build_institution_reference.R` | Institution reference list generation |
| `R/require_scopus_api_allowed.R` | Guard Scopus API calls behind config flag |
| `R/resolve_harvest_candidates_file.R` | Locate saved harvest candidates for a refresh |
| `shiny/funder_review_app.R` | Funder review app |
| `shiny/author_review_app.R` | Author review app |
| `shiny/author_division_resolution_app.R` | Missing author division resolution app |
| `shiny/affiliation_review_app.R` | Unresolved affiliation review app |
| `shiny/dashboard_app.R` | Dashboard app |

## Key Data Files

| File | Purpose |
|------|---------|
| `data/decisions/funding_review_decisions.csv` | Publication-level funder review decisions |
| `data/decisions/author_review_decisions.csv` | Publication-level author/affiliation review decisions |
| `data/decisions/author_division_decisions.csv` | Per-author DWR/not-DWR and division decisions |
| `data/lookups/funding_division_lookup.csv` | Kept funder records and manual funding division assignments; `new` flags current-refresh blanks |
| `data/lookups/author_division_lookup.csv` | Local HR-derived author/year/division lookup; ignored by Git |
| `data/lookups/dwr_org_lookup.csv` | Raw org label to canonical division lookup |
| `data/generated/accepted_publications.parquet` | Durable accepted-publications table |
| `data/generated/dwr_publications.csv` | Dashboard CSV export |
| `data/generated/dwr_publications.parquet` | Dashboard Parquet export |
| `data/refresh_log.csv` | Refresh log |
| `data/harvests/` | Refresh-specific candidate snapshots |

Generated queue files:

- `data/queues/funder_review_queue.parquet`
- `data/queues/author_review_queue.parquet`

## Review Semantics

### Funder Review

The funder queue contains candidates whose `query_source` includes
`"funder"`. Decisions are saved in `data/decisions/funding_review_decisions.csv`.

Decision handling:

- `keep`: retained and eligible for `data/lookups/funding_division_lookup.csv`.
- `drop`: funder side is removed.
- `unsure`: retained for now, but not eligible for the funding division lookup.

### Author Review

The author queue contains candidates whose `query_source` includes
`"affiliation"`, including overlap records with
`query_source == "funder; affiliation"`.

The app writes publication-level decisions to
`data/decisions/author_review_decisions.csv` and per-author decisions to
`data/decisions/author_division_decisions.csv`.

Confirmed DWR authors with unresolved divisions are handled in
`shiny/author_division_resolution_app.R`.

### Overlap Records

Records found by both searches are reviewed independently for funding and
authorship. In `_targets.R`, `pubs_reviewed` adjusts `query_source` for overlap
records when only one side is dropped, so contribution flags remain accurate.

## Author Division Assignment

`author_name_utils.R` prepares and matches the local
`data/lookups/author_division_lookup.csv` lookup. The review apps use these helpers to
resolve likely divisions automatically when possible.

`join_author_division()` does not re-run the HR lookup match during export.
Instead, it reads `data/decisions/author_division_decisions.csv` and joins divisions for rows with:

```text
decision == "dwr"
division is non-empty
```

The export column `author_division` is a semicolon-delimited set of unique
divisions for confirmed DWR authors on a publication.

## Dashboard State

`shiny/dashboard_app.R` reads `data/generated/dwr_publications.parquet`.

Implemented dashboard features:

- keyword search over title, abstract, and authors
- Science Field filter
- Contribution Type filter
- Author Affiliation filter
- year range slider
- summary stat boxes
- Science Category pie chart
- Publications by Year and Contribution stacked bar chart
- article table
- chat sidebar with filter-setting and filtered-set synthesis tools

Not yet implemented in the dashboard:

- active Division filter
- Articles by Division chart
- Author Division filter
- production copy for About and Classification modals

See `SPEC.md` for the current dashboard specification and planned dashboard
enhancements.

## Known Prerequisites And Gaps

- `data/lookups/affiliation_lookup.csv` is maintained by the
  `affiliation_lookup_file` target. The target prepends new raw affiliation
  strings with `new = TRUE`, sends only those new strings to the LLM, and keeps
  reviewed canonical names available as prompt context. Review the CSV, use
  `Unknown` for unresolved affiliations, and set `new = FALSE` before publishing.
- `data/lookups/author_division_lookup.csv` is required locally but ignored by Git.
- `refresh_log_completed` currently records funder-oriented review counts; it
  does not separately record author review counts.
- The funder review app does not capture acknowledgments text.
- The dashboard still has placeholder modal text.

## Deferred Work

- Add author-specific counts to `data/refresh_log.csv` and
  `refresh_log_completed`.
- Implement the dashboard Division filter and Articles by Division chart from
  `funding_division`.
- Decide whether dashboard division UX should expose `funding_division`,
  `author_division`, or a combined division filter.
- Add reviewer-entered acknowledgments text to the funder review workflow if
  needed for auditability.
- Replace dashboard placeholder modal copy with production text.
