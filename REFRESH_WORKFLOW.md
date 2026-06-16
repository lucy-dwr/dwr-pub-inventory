# Publication Inventory Refresh Workflow

## Purpose

This note describes the production refresh workflow for the DWR
publication inventory. The workflow supports periodic refreshes that add newly
harvested, reviewed, and validated publications without unintentionally
overwriting records that were previously accepted into the inventory.

Earlier versions of the pipeline behaved like a full rebuild:

```text
Scopus search
-> manual review decisions
-> combine, deduplicate, classify, canonicalize
-> overwrite final exports
```

For a production inventory that grows over time, the workflow should separate
three concepts:

1. Candidate records harvested from Scopus.
2. Manual review decisions for candidate records.
3. Accepted records that belong in the production inventory.

The final `data/dwr_publications.csv` and
`data/dwr_publications.parquet` files should be treated as exports, not as the
source of truth.

## Addressed Risks

The append-oriented workflow is designed to avoid these scheduled-refresh
risks:

- Previously accepted records can be overwritten by a later full rebuild.
- It is hard to tell when a publication was first harvested or accepted.
- It is hard to distinguish new candidates from previously reviewed records.
- Manual review decisions are keyed by DOI, but some records do not have a DOI.
- Existing records may be reclassified or recanonicalized unintentionally.
- There is no durable table of accepted production records separate from the
  latest Scopus search output.

## Model

The pipeline uses a pragmatic append-oriented workflow with durable refresh
metadata:

1. Add a refresh log.
2. Persist harvested candidates by refresh.
3. Assign stable record keys to harvested publications.
4. Review only new or unresolved candidates.
5. Append newly accepted records into a durable accepted-publications table.
6. Export the current full inventory from the accepted-publications table.

This keeps production history auditable while avoiding unnecessary complexity.

## Proposed Data Files

### `data/refresh_log.csv`

One row per refresh cycle.

Suggested columns:

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

The `refresh_id` can be a date-like value such as `2026-06-08`, or a timestamp
if multiple refreshes may occur on the same day.

### `data/harvests/`

Store raw or lightly normalized candidate records for each refresh.

Example:

```text
data/harvests/
  harvest_2026-06-08_candidates.parquet
  harvest_2026-09-15_candidates.parquet
```

Each harvested candidate should include:

```text
record_key
doi
scopus_id
title
abstract
year
authors
affiliations
funders
grant_numbers
journal
source
query_source
harvest_id
harvested_at
raw_metadata_hash
```

### `data/funder_review_decisions.csv`

Continue storing manual review decisions, but key decisions by `record_key`
rather than DOI alone.

Suggested columns:

```text
record_key
doi
decision
reviewed_at
review_refresh_id
review_notes
```

Valid decisions:

```text
keep
drop
unsure
```

For the broad accepted-publications flow, records marked `drop` are excluded
by `apply_review_decisions()`, while `keep` and `unsure` records are retained.
The funding-division lookup is stricter: `data/funding_division_lookup.csv`
contains only funder records with an explicit `keep` decision.

Manual corrections are made by editing the matching DOI or `record_key` row in
this file. Changing a decision away from `keep` removes that record from the
funding-division lookup the next time the lookup is updated.

### `data/funding_division_lookup.csv`

Manual DOI-to-division lookup for records found by the funder query that passed
the funding review stage.

Columns:

```text
doi
doi_url
year
title
division
new
```

Invariants:

- every row has `decision == "keep"` in `data/funder_review_decisions.csv`
- records marked `drop` or `unsure` are excluded
- `division` may be blank when a kept record still needs division assignment
- the dashboard exports receive this value as `funding_division`

### `data/accepted_publications.parquet`

This is the durable production source of truth.

Suggested columns:

```text
record_key
doi
scopus_id
title
abstract
year
authors
affiliations
funders
grant_numbers
journal
source
query_source
is_funder
is_author
is_lead_author
is_sole_author
pc_category
pc_field
pc_rationale
accepted_at
accepted_refresh_id
first_seen_at
last_seen_at
last_metadata_refresh_id
classification_version
affiliation_lookup_version
record_status
```

The final dashboard exports should be generated from this table:

```text
data/dwr_publications.csv
data/dwr_publications.parquet
```

## Stable Record Keys

DOI alone is not sufficient because some records do not have one. The workflow
needs a stable `record_key` that can identify previously seen records.

Recommended key priority:

```text
record_key =
  scopus_id, if available
  else normalized DOI, if available
  else hash(normalized title + year + first author + journal)
```

The fallback hash is not perfect, but it gives DOI-missing records a stable key
that is usually good enough for deduplication and review tracking.

## Proposed Refresh Flow

### 1. Start a Refresh

Create a new `refresh_id` and write a row to `data/refresh_log.csv` with
`started_at`.

### 2. Harvest Scopus Candidates

Run the funder and affiliation searches.

Save the harvested candidates with:

- `refresh_id`
- `harvested_at`
- `record_key`
- `query_source`
- `raw_metadata_hash`

### 3. Identify New or Unresolved Candidates

Compare harvested candidates against:

- previously accepted records
- previous review decisions
- previous harvests

The review queue should include records that are:

- newly harvested and not previously reviewed
- previously marked `unsure`, if the workflow wants a second review
- records whose metadata changed enough to require another look

### 4. Manual Review

Launch the review app on the refresh-specific review queue.

The app writes decisions to `data/funder_review_decisions.csv` using `record_key`, not
DOI alone.

### 5. Append Accepted Records

After review, append newly accepted records to
`data/accepted_publications.parquet`.

Previously accepted records should not be overwritten by default. If old
metadata should be refreshed, that should be a separate explicit mode.

Possible modes:

```text
new_records_only
update_existing_metadata
reclassify_all
```

The safest default is `new_records_only`.

### 6. Classify and Canonicalize

For normal scheduled refreshes, classify and canonicalize only newly accepted
records.

Reclassifying the entire inventory should be reserved for cases where the
taxonomy, prompts, model, or classification policy changes.

### 7. Export the Current Inventory

Generate the dashboard-ready exports from the accepted-publications table,
joining `funding_division` from `data/funding_division_lookup.csv`:

```text
data/dwr_publications.csv
data/dwr_publications.parquet
```

### 8. Finish the Refresh

Update `data/refresh_log.csv` with:

- `completed_at`
- candidate counts
- review counts
- accepted count
- any notes about unusual issues

## Review App Behavior

The review app reads the refresh review queue and writes decisions to
`data/funder_review_decisions.csv`.

It:

1. Reads a refresh-specific review queue.
2. Displays only records needing review.
3. Saves decisions keyed by `record_key`.
4. Preserves prior decisions unless the reviewer explicitly changes them.

## Implementation Components

The implemented workflow is made up of:

1. `refresh_log.csv`.
2. `record_key` creation.
3. Harvested candidate snapshots in `data/harvests/`.
4. Review decisions keyed by `record_key`.
5. A review app that reads `data/funder_review_queue.parquet`.
6. `accepted_publications.parquet`.
7. Exports derived from accepted publications plus the funding-division lookup.

The final exports are generated from accepted publications plus the
funding-division lookup.
