# DWR Publication Inventory — Architecture Reference

Technical reference for maintainers and contributors. Describes the pipeline
architecture, data flow, review semantics, and dashboard implementation.
For the operator quickstart, see `README.md`. For dashboard design and behavior,
see [`docs/DASHBOARD.md`](DASHBOARD.md).

## Architecture Overview

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
9. Maintains and applies the institution geo lookup through
   `data/lookups/institution_geo_lookup.csv`, then adds
   `affiliation_countries`.
10. Classifies new canonicalized records into the DWR taxonomy.
11. Appends accepted records to `data/generated/accepted_publications.parquet`.
12. Updates the keep-only funding division lookup.
13. Joins funding and author division fields into dashboard exports.
14. Completes the refresh log.

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

# Build/refresh the affiliation lookup; review unresolved rows before publishing
targets::tar_make(affiliation_lookup_file)
shiny::runApp("shiny/affiliation_review_app.R")

# Publish accepted records and update the funding division lookup
targets::tar_make(names = c(accepted_publications_updated, funding_division_lookup_updated))

# Fill division for rows where new == TRUE in data/lookups/funding_division_lookup.csv.

# Rebuild dashboard exports and complete the refresh log
targets::tar_make(names = c(dashboard_csv, dashboard_parquet, refresh_log_completed))
```

## Key Source Files

| File | Purpose |
|------|---------|
| `_targets.R` | Pipeline definition |
| `config/pipeline.yml` | Non-secret paths, model, Scopus search settings |
| `R/load_pipeline_config.R` | Pipeline configuration loader |
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
| `R/flag_dwr_contributions.R` | Contribution-type boolean flag assignment |
| `R/classify_publications.R` | LLM-backed taxonomy classification wrapper |
| `R/author_name_utils.R` | Author lookup and division matching utilities |
| `R/score_dwr_relevance.R` | Funder review suspicion scoring |
| `R/score_author_affiliation.R` | Author review suspicion scoring |
| `R/apply_affiliation_lookup.R` | Affiliation canonicalization |
| `R/build_affiliation_lookup.R` | Affiliation lookup generation |
| `R/build_institution_reference.R` | Institution reference list generation |
| `R/build_institution_geo_lookup.R` | Institution country/state lookup generation |
| `R/join_institution_countries.R` | Export-time country enrichment from institution geo lookup |
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
| `data/lookups/affiliation_lookup.csv` | Raw affiliation string to canonical institution lookup |
| `data/lookups/institution_geo_lookup.csv` | Canonical institution to country and US state lookup |
| `data/lookups/institution_reference.txt` | Reference list used as context for affiliation canonicalization |
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

## Institution Geo Enrichment

`build_institution_geo_lookup()` reads reviewed canonical institution names from
`data/lookups/affiliation_lookup.csv` and updates
`data/lookups/institution_geo_lookup.csv`.

The geo lookup has one row per canonical institution:

```text
canonical
country
state
resolved
```

Only reviewed affiliation lookup rows (`new != TRUE`) with non-`Unknown`
canonical names are sent for geolocation. Rows where `resolved == TRUE` are not
sent to the LLM again, even if `country` or `state` is blank. `state` is only
populated for United States institutions.

`join_institution_countries()` uses this lookup to add the
`affiliation_countries` list column to accepted records. The dashboard uses that
column for country-level Institution Map counts, and reads
`institution_geo_lookup.csv` directly for US state counts and institution popup
details.

## Dashboard State

`shiny/dashboard_app.R` reads `data/generated/dwr_publications.parquet` and
`data/lookups/institution_geo_lookup.csv`.

Implemented dashboard features:

- keyword search over title, abstract, and authors
- Division filter using `author_division` and `funding_division`
- Science Field filter
- Contribution Type filter
- Author Affiliation filter
- year range slider
- summary stat boxes
- Science Category pie chart
- Articles by Division stacked horizontal bar chart
- Publications by Year and Contribution stacked bar chart
- article table
- chat sidebar with filtering, search, breakdown, trend, paper-detail,
  synthesis, citation, author, and collaboration tools
- Institution Map tab (choropleth world map with US state detail)
- Publishing Network tab (interactive force-directed co-authorship network)
  - institution mode (org nodes, DWR pinned anchor, geo color coding)
  - people mode (author nodes, DWR authors highlighted)
  - node click → paper list modal
  - edge click → shared paper list modal
  - node size scaled to paper count
  - color legend

Not yet implemented in the dashboard:

- Author Division filter
- production copy for About and Classification modals

See [`docs/DASHBOARD.md`](DASHBOARD.md) for the dashboard design reference.

## Prerequisites and Known Gaps

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
