# Data Reference

## Stable Record Keys

`record_key` is assigned by `R/add_record_keys.R` using this priority:

```text
Scopus EID
normalized DOI
hash(normalized title + year + first author + journal)
```

The key lets review decisions survive changes in file order and supports records
that have no DOI.

## `data/refresh_log.csv`

One row per refresh cycle. Columns:

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

`n_reviewed`, `n_kept`, `n_dropped`, and `n_unsure` are calculated from
`data/decisions/funding_review_decisions.csv` for the current refresh. Author
review decisions are stored separately, but the refresh log does not currently
include separate author-review count columns.

## `data/generated/accepted_publications.parquet`

This is the durable source of truth for accepted publications. It contains the
reviewed, canonicalized, classified publication records before dashboard-only
division fields are joined.

| Column | Description |
|--------|-------------|
| `record_key` | Stable publication identifier assigned from Scopus EID, DOI, or a title/year/author/journal hash. |
| `doi` | Digital Object Identifier, when available. |
| `title` | Publication title from Scopus. |
| `abstract` | Publication abstract from Scopus, when available. |
| `year` | Publication year. |
| `doc_type` | Scopus document type retained by the pipeline, such as `article` or `review`. |
| `authors` | List column of author names from Scopus. |
| `affiliations` | List column of canonicalized institution names associated with the publication. Raw affiliation strings are replaced through `data/lookups/affiliation_lookup.csv`. |
| `affiliation_countries` | List column of unique country names for the publication's canonical affiliations, derived from `data/lookups/institution_geo_lookup.csv`. Empty character vector when no country could be resolved. In the CSV export this is collapsed to a semicolon-delimited string. |
| `journal` | Journal or source title for the publication. |
| `source` | Bibliographic source label returned by Scopus. |
| `harvest_id` | Refresh identifier for the Scopus harvest that brought the record into the pipeline run. This comes from `refresh.id` in `config/pipeline.yml`, or defaults to the run date when the config value is blank. |
| `harvested_at` | Timestamp when the record was harvested from Scopus. |
| `query_source` | Scopus search route retained after review: `funder`, `affiliation`, or `funder; affiliation`. Records found by both searches start as `funder; affiliation`; if review drops one side of the match, the pipeline automatically updates `query_source` to keep only the remaining accepted route. |
| `is_funder` | `TRUE` when the accepted record is associated with DWR through a funder-search match. |
| `is_author` | `TRUE` when the accepted record is associated with DWR through an author-affiliation match or DWR affiliation metadata. |
| `is_lead_author` | `TRUE` when the first-listed author is DWR-affiliated according to the affiliation metadata. |
| `is_sole_author` | `TRUE` when all listed authors are DWR-affiliated according to the affiliation metadata. |
| `pc_text_source` | Text used for disciplinary classification. Current values are `title+abstract` when an abstract is available and `title` when classification uses title only. |
| `pc_classified_by` | Classification method label. Current pipeline value is `llm-full`. |
| `pc_category` | Top-level taxonomy category joined from `taxonomy/dwr_disciplines_taxonomy.csv` based on `pc_field`. |
| `pc_field` | Specific DWR taxonomy field assigned by the LLM classifier. |
| `pc_rationale` | Short model-generated rationale for the assigned taxonomy field. |
| `accepted_at` | Timestamp when the record was first appended to `accepted_publications.parquet`. |
| `accepted_refresh_id` | Refresh identifier for the refresh that first accepted the record into the authoritative inventory. |
| `first_seen_at` | Timestamp when the record first entered the accepted table; currently initialized from `accepted_at`. |
| `last_seen_at` | Timestamp when the record was last confirmed in a harvest; currently initialized when the record is accepted. |
| `last_metadata_refresh_id` | Refresh identifier for the most recent refresh that updated or confirmed the record's metadata; currently initialized from the accepting refresh. |
| `record_status` | Durable status flag for the accepted record. New records are written as `active`. |

Dashboard exports join two additional division columns, `funding_division` and
`author_division`, onto this accepted inventory.

## Review Decisions Schemas

`data/decisions/funding_review_decisions.csv` and
`data/decisions/author_review_decisions.csv` share the same schema:

```text
record_key
doi
decision
reviewed_at
review_refresh_id
review_notes
```

`data/decisions/author_division_decisions.csv` has additional author-level
fields:

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

Rows with `decision == "dwr"` and a non-empty `division` populate the
`author_division` export column.

## `data/lookups/institution_geo_lookup.csv`

One row per unique canonical institution name. Built and updated automatically
during the full publish step by `R/build_institution_geo_lookup.R`. Existing
resolved rows are never re-queried.

| Column | Description |
|--------|-------------|
| `canonical` | Canonical institution name (primary key). Matches values in `affiliation_lookup.csv`. |
| `country` | Full English country name (e.g. `"United States"`, `"Germany"`), or `NA` when the country cannot be determined with confidence. |
| `state` | Full US state name (e.g. `"California"`), or `NA` for non-US institutions or when the state is unclear. Only populated for United States institutions. |
| `resolved` | `TRUE` once the row has been through the LLM (even if `country` is `NA`). Rows where `resolved = TRUE` are not re-sent to the LLM in future refreshes. |

## `data/lookups/funding_division_lookup.csv`

Schema:

```text
doi
doi_url
year
title
division
new
```

Only funder records with an explicit `keep` decision are included. `new == TRUE`
flags current-refresh rows with a blank `division` still needing assignment.
Maintainers fill `division` manually in this CSV after
`funding_division_lookup_updated` runs, then rerun the dashboard export targets.
The pipeline preserves existing division assignments and recalculates `new` on
each run.
