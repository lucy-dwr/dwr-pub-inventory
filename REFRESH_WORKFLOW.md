# Publication Inventory Refresh Workflow

This document describes the implemented refresh workflow for the DWR
publication inventory.

The workflow separates four concepts:

1. Scopus candidate records harvested during a refresh.
2. Manual publication-level review decisions for funder and author candidates.
3. Manual author-level DWR/division decisions.
4. Accepted production records used to generate dashboard exports.

The dashboard files, `data/dwr_publications.csv` and
`data/dwr_publications.parquet`, are exports. The durable source of truth is
`data/accepted_publications.parquet`.

## Operator Workflow

### 1. Start A Refresh And Build Queues

```r
Sys.setenv(DWR_REFRESH_ID = "2026-06-08")  # optional; defaults to today's date
targets::tar_make(funder_review_queue_file, author_review_queue_file)
```

This step:

- runs the Scopus funder and affiliation searches configured in
  `config/pipeline.yml`
- assigns stable `record_key` values
- attaches `harvest_id` and `harvested_at`
- combines and deduplicates funder and affiliation candidates
- writes a harvest snapshot to `data/harvests/`
- writes review queues for the Shiny review apps

Queue files:

- `data/funder_review_queue.parquet`
- `data/author_review_queue.parquet`

### 2. Review Funder Candidates

```r
shiny::runApp("shiny/funder_review_app.R")
```

The funder review app reads `data/funder_review_queue.parquet` and writes
`data/funding_review_decisions.csv`.

Decision values:

| Decision | Meaning |
|----------|---------|
| `keep` | DWR funding is confirmed |
| `drop` | DWR funding is not supported; remove the funder side |
| `unsure` | Funding evidence is ambiguous; retain for now |

The funding division lookup is stricter than the accepted-publications flow:
only funder records with an explicit `keep` decision are eligible for
`data/funding_division_lookup.csv`.

### 3. Review Author/Affiliation Candidates

```r
shiny::runApp("shiny/author_review_app.R")
```

The author review app reads `data/author_review_queue.parquet` and writes:

- `data/author_review_decisions.csv`: publication-level keep/drop/unsure
  decisions for affiliation-side candidates.
- `data/author_division_decisions.csv`: per-author DWR/not-DWR decisions, plus division
  and division-rule fields when they can be resolved.

The author queue includes records whose `query_source` contains
`"affiliation"`, including overlap records with
`query_source == "funder; affiliation"`. Overlap records can therefore receive
independent funder and author decisions.

### 4. Resolve Missing Author Divisions

```r
shiny::runApp("shiny/author_division_resolution_app.R")
```

This app reads `data/author_division_decisions.csv` and focuses on rows where the author
was confirmed as DWR but no division has been assigned. It uses
`data/author_division_lookup.csv` and `data/dwr_org_lookup.csv` to suggest or
constrain division assignments, then writes updates back to
`data/author_division_decisions.csv`.

`data/author_division_lookup.csv` is a required local input and is ignored by
Git.

### 5. Publish The Updated Inventory

```r
targets::tar_make()
```

This step:

- applies funder and author publication-level review decisions
- corrects `query_source` for overlap records when only one side was dropped
- flags DWR contribution types (`is_funder`, `is_author`, `is_lead_author`,
  `is_sole_author`)
- classifies new records in the DWR taxonomy
- canonicalizes affiliations using `data/affiliation_lookup.csv`
- appends newly accepted records to `data/accepted_publications.parquet`
- updates `data/funding_division_lookup.csv`
- joins `funding_division` and `author_division`
- writes `data/dwr_publications.csv` and `data/dwr_publications.parquet`
- completes the refresh log

The publish step requires `data/affiliation_lookup.csv` to exist because it is
tracked as a file target. Rebuild it with `R/build_affiliation_lookup.R` if it
is missing or stale.

## Refresh Modes

Set `DWR_REFRESH_MODE` before `targets::tar_make()`:

| Mode | Behavior |
|------|----------|
| `new_records_only` | Default. Classifies only records not already accepted. |
| `reclassify_all` | Classifies every record in the current reviewed harvest. |

## Data Files

### `data/refresh_log.csv`

One row per refresh cycle. The implemented log columns are created by
`R/create_refresh_id.R`:

```text
refresh_id
started_at
completed_at
scopus_query_date
n_funder_candidates
n_affiliation_candidates
n_new_candidates
n_reviewed
n_kept
n_dropped
n_unsure
n_accepted
notes
```

At present, the completion counts are funder-oriented. Author-specific review
counts are not separately recorded.

### `data/harvests/`

Stores candidate snapshots for each refresh:

```text
data/harvests/harvest_<refresh_id>_candidates.parquet
```

Each row includes the assigned `record_key`, the `query_source`, and refresh
metadata.

### `data/funding_review_decisions.csv`

Publication-level decisions from `shiny/funder_review_app.R`.

Schema:

```text
record_key
doi
decision
reviewed_at
review_refresh_id
review_notes
```

### `data/author_review_decisions.csv`

Publication-level decisions from `shiny/author_review_app.R` for
affiliation-side candidates.

Schema:

```text
record_key
doi
decision
reviewed_at
review_refresh_id
review_notes
```

### `data/author_division_decisions.csv`

Author-level decisions from the author review and author division resolution
apps.

Schema:

```text
record_key
doi
author_name
decision
reviewed_at
review_refresh_id
division
division_rule
year
```

Rows with `decision == "dwr"` and a non-empty `division` are used by
`join_author_division()` to populate the `author_division` export column.

### `data/funding_division_lookup.csv`

Manual DOI-to-division lookup for funder-query records that passed funding
review.

Schema:

```text
doi
doi_url
year
title
division
new
```

Invariants:

- every retained row has `decision == "keep"` in
  `data/funding_review_decisions.csv`
- records marked `drop` or `unsure` are excluded
- `division` may be blank when a kept record still needs assignment
- exports expose this value as `funding_division`

### `data/accepted_publications.parquet`

Durable production source of truth. New records are appended by
`append_accepted_publications()` and receive provenance fields:

```text
accepted_at
accepted_refresh_id
first_seen_at
last_seen_at
last_metadata_refresh_id
record_status
```

### Dashboard Exports

Generated from `data/accepted_publications.parquet`:

```text
data/dwr_publications.csv
data/dwr_publications.parquet
```

Both exports include joined `funding_division` and `author_division` fields
when the relevant lookup/decision files contain assignments.

## Stable Record Keys

`record_key` is assigned by `R/add_record_keys.R` using this priority:

```text
Scopus EID
normalized DOI
hash(normalized title + year + first author + journal)
```

The key lets review decisions and accepted records survive changes in file
order and supports records that do not have a DOI.

## Implementation Components

- `_targets.R`: pipeline definition and operator comments.
- `config/pipeline.yml`: non-secret settings and file paths.
- `R/build_funder_review_queue.R`: funder queue construction.
- `R/build_author_review_queue.R`: author/affiliation queue construction.
- `R/apply_review_decisions.R`: shared keep/drop filtering.
- `R/append_accepted_publications.R`: append-oriented accepted table update.
- `R/update_funding_division_lookup.R`: keep-only funding division lookup.
- `R/join_funding_division.R`: export-time funding division join.
- `R/join_author_division.R`: export-time author division join from
  `data/author_division_decisions.csv`.
- `shiny/funder_review_app.R`: funder publication review.
- `shiny/author_review_app.R`: author publication and author-level review.
- `shiny/author_division_resolution_app.R`: unresolved division assignment.
