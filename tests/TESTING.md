# Testing Infrastructure Plan

## Framework

Use **testthat** (v3). It is the de-facto standard for R packages and plain R
projects alike, integrates well with RStudio, and does not require a package
structure. Tests live in `tests/testthat/` and are run with
`testthat::test_dir("tests/testthat")`.

No Scopus API key or LLM credential is needed to run any test below — all tests
use in-memory fixtures or temporary files.

---

## Directory layout

```
tests/
├── TESTING.md                  # this file
└── testthat/
    ├── helper-fixtures.R       # shared in-memory tibbles and temp-file helpers
    ├── test-add_record_keys.R
    ├── test-create_refresh_id.R
    ├── test-apply_review_decisions.R
    ├── test-flag_dwr_contributions.R
    ├── test-score_dwr_relevance.R
    ├── test-score_author_affiliation.R
    ├── test-author_name_utils.R
    ├── test-build_funder_review_queue.R
    ├── test-build_author_review_queue.R
    ├── test-append_accepted_publications.R
    ├── test-apply_affiliation_lookup.R
    ├── test-classify_publications.R
    └── test-join_institution_countries.R
```

---

## Shared fixtures (`helper-fixtures.R`)

A single sourced file so every test file can call these helpers without repeating
boilerplate. Testthat auto-sources files prefixed `helper-` before running tests.

```r
# Minimal publications tibble used by most tests
make_pubs <- function(n = 3) {
  tibble::tibble(
    eid       = c("2-s2.0-001", NA_character_, NA_character_),
    doi       = c("10.1000/abc", "10.1000/def", NA_character_),
    title     = c("Water resources in California", "Climate change study", "Hydrology review"),
    abstract  = c("Delta smelt population...", "Global warming impacts...", NA_character_),
    year      = c("2023", "2022", "2021"),
    authors   = list(c("Smith, John A."), c("Jones, Mary B.", "Chen, Wei"), c("Brown, K.")),
    affiliations = list(
      list(c("California Department of Water Resources, Sacramento")),
      list(c("University of London"), c("Peking University")),
      list(c("NOAA, Washington, DC"))
    ),
    funders       = list(list("California DWR"), list(), list()),
    grant_numbers = list(list("4600012345"), list(), list()),
    journal      = c("Water Resources Research", "Nature Climate Change", "Hydrology"),
    query_source = c("funder", "affiliation", "funder; affiliation")
  )
}

# Write a minimal decisions CSV to a temp file and return the path
write_decisions_csv <- function(decisions, dir = tempdir()) {
  path <- file.path(dir, paste0("decisions_", sample.int(1e6, 1), ".csv"))
  readr::write_csv(decisions, path)
  path
}
```

---

## Per-file test specs

### `test-add_record_keys.R` — `add_record_keys()`

| Test | What to assert |
|---|---|
| EID priority | Record with EID gets `record_key = "eid:2-s2.0-001"` |
| DOI fallback | Record with no EID but a DOI gets `"doi:10.1000/def"` (lowercased, trimmed) |
| Hash fallback | Record with neither EID nor DOI gets `"hash:<16-char hex>"` |
| DOI normalisation | DOI with leading/trailing whitespace is trimmed before keying |
| Nested list flattening | A list column containing nested lists is coerced to flat character vectors (Parquet safety) |
| Output column position | `record_key` is the first column of the returned tibble |
| No mutation of other cols | All non-key columns are unchanged |

### `test-create_refresh_id.R` — `create_refresh_id()`, `init_refresh_log()`, `complete_refresh_log()`

**`create_refresh_id()`**

| Test | What to assert |
|---|---|
| Config value used | Config with `refresh$id = "2026-06-01"` → returns `"2026-06-01"` |
| Empty config → today | Config with `refresh$id = ""` or `NULL` → returns today's date (`format(Sys.Date(), "%Y-%m-%d")`) |
| NULL config → today | `create_refresh_id(NULL)` → returns today's date |
| Whitespace-only → today | Config with `refresh$id = "  "` → returns today's date |

**`init_refresh_log()`**

| Test | What to assert |
|---|---|
| Creates new log | Temp dir with no CSV → creates file with correct columns and one data row |
| Appends to existing | Log with one row → adds a second row for new refresh_id |
| No-op if already present | Calling twice with same refresh_id → log still has one row for that id |
| `started_at` is populated | New row has non-NA `started_at` |

**`complete_refresh_log()`**

| Test | What to assert |
|---|---|
| Fills count fields | `n_accepted = 42` → log row has `"42"` in that column |
| Sets `completed_at` | `completed_at` is non-NA after call |
| Warns if id missing | refresh_id not in log → issues a warning |
| Warns if file missing | Non-existent path → issues a warning, returns `NULL` invisibly |

### `test-apply_review_decisions.R` — `apply_review_decisions()`

| Test | What to assert |
|---|---|
| Drops `"drop"` records by `record_key` | Record with `decision = "drop"` is absent from result |
| Keeps `"keep"` and `"unsure"` | Those records are present in result |
| Keeps unreviewed records | Records with no matching decision row are retained |
| DOI fallback | When `record_key` absent from both pubs and decisions, drops by DOI |
| Missing file → unchanged | Non-existent path → returns pubs unmodified, emits a message |
| NA decision rows ignored | Rows with NA decision do not trigger drops |

### `test-flag_dwr_contributions.R` — `flag_dwr_contributions()`

| Test | What to assert |
|---|---|
| `is_funder` | query_source = "funder" → TRUE; "affiliation" → FALSE; "funder; affiliation" → TRUE |
| `is_author` from query_source | "affiliation" → TRUE |
| `is_author` from affiliation string | Even if query_source = "funder", a DWR affiliation string → TRUE |
| `is_lead_author` | First author's affiliation contains DWR → TRUE; all others → FALSE |
| `is_sole_author` | All authors have DWR affiliation → TRUE; mixed → FALSE |
| Empty affiliations | Empty list → `is_lead_author` and `is_sole_author` both FALSE |
| Case insensitivity | "california department of water resources" (lowercase) matches |

### `test-score_dwr_relevance.R` — `score_dwr_relevance()`

| Test | What to assert |
|---|---|
| Score 0 for clear DWR pub | Title with "water" + "California" + "NOAA" in affiliations → 0 |
| +4 for no CA mention | Abstract/title/funders with zero CA terms |
| +4 for no water topic | No water-related terms anywhere |
| +3 for non-water domain | "cancer treatment" in title → adds 3 |
| +2 for no US institution | All affiliations are non-US universities |
| Maximum score 13 | No CA, no water, non-water domain, no US institution → 13 |
| `cdwr_score` column added | Result has integer `cdwr_score` column |

### `test-score_author_affiliation.R` — `score_author_affiliation()`

| Test | What to assert |
|---|---|
| +5 when no author in lookup | Author not found in the HR CSV for the publication year |
| +0 when author is in lookup | Known author at correct year → no penalty |
| +3 for non-standard DWR string | "CA Dept of Water Resources" (variant) → adds 3 |
| +2 for unrelated domain | "cancer" in title → adds 2 |
| +2 for no CA geo mention | No California terms in any field |
| Max score 12 | All four signals fire simultaneously |
| Missing lookup file | No lookup CSV → scoring still runs (skips signal 1) |

### `test-author_name_utils.R` — `normalize_scopus_name()`, `author_in_lookup()`, `resolve_author_division()`

**`normalize_scopus_name()`**

| Test | What to assert |
|---|---|
| Comma format | "Smith, John A." → "JOHN A SMITH" |
| No-comma initials format | "Riordan D." → "D RIORDAN" |
| Multi-initial no-comma | "Biales A.D." → "A D BIALES" |
| Full given name no comma | "Smith John Allen" (no comma, long tokens) → cleaned uppercase |
| NA input → NA | Returns `NA_character_` |
| Empty/blank → NA | Empty or whitespace string → `NA_character_` |

**`author_in_lookup()`**

| Test | What to assert |
|---|---|
| Exact last + first initial match | Returns TRUE |
| Year-adjacent match | Author in year-1 or year+1 → TRUE |
| No match | Unknown author → FALSE |
| NA name → FALSE | `NA` returns FALSE without error |
| Empty lookup → FALSE | Zero-row data frame → FALSE |

**`resolve_author_division()`**

| Test | What to assert |
|---|---|
| Rule 1: unique match in pub year | Returns rule = 1, correct division |
| Rule 2: unique match in prior year | Returns rule = 2 |
| Rule 4: ambiguous | Two divisions → rule = 4, NA division, both in candidates |
| Rule 5: no match | Not found → rule = 5 |

### `test-build_funder_review_queue.R` — `build_funder_review_queue()`

| Test | What to assert |
|---|---|
| Excludes already-accepted records | Keys in accepted parquet are absent from queue |
| Excludes already-reviewed (all decisions) | Keys in decisions CSV with any decision are absent |
| `include_unsure = TRUE` re-queues unsure | "unsure" records appear in queue |
| Funder-only filter | Records with `query_source = "affiliation"` only are excluded |
| "funder; affiliation" included | Overlap records are included |
| Sorted by descending `cdwr_score` | First row has highest score |
| No decisions file → uses all funder candidates | Empty decisions → all unaccepted funder records appear |
| No accepted file → nothing excluded by accepted | All funder candidates queue when no accepted parquet exists |

### `test-build_author_review_queue.R` — `build_author_review_queue()`

| Test | What to assert |
|---|---|
| Affiliation candidates included | `query_source = "affiliation"` records appear |
| "funder; affiliation" overlap included | Both query sources yield review candidates |
| Funder-only excluded | Pure `query_source = "funder"` records absent |
| Excludes accepted records | Keys present in accepted parquet are excluded |
| Excludes already-reviewed | Reviewed keys absent |
| Sorted by descending `caff_score` | Highest-score record is first |

### `test-append_accepted_publications.R` — `append_accepted_publications()`

| Test | What to assert |
|---|---|
| First run creates parquet | Target file is created; has correct row count |
| Provenance columns added | `accepted_at`, `accepted_refresh_id`, `record_status` etc. are present |
| Re-run is idempotent | Second call with same records → row count unchanged |
| New keys appended | Second call with one new record → row count increases by 1 |
| Duplicate keys not re-appended | Existing record_keys in `pubs_new_enriched` are skipped |
| Column alignment | New records with extra columns → merged with NA fill for missing cols |
| Returns file path | Return value equals `accepted_path` |

### `test-apply_affiliation_lookup.R` — `apply_affiliation_lookup()`

**Core mapping**

| Test | What to assert |
|---|---|
| Raw → canonical replacement | Raw affil string is replaced by its canonical value |
| Occurrence-level lookup | When lookup has `record_key` column, matches are per-publication |
| Legacy raw-only lookup | When no `record_key` column in lookup, falls back to global raw→canonical |
| Unmatched affil → warning | Affiliation absent from lookup issues a warning and leaves value unchanged |
| `manual_added = TRUE` appended | Extra canonical institutions are appended to matching publication |

**Validation guards**

| Test | What to assert |
|---|---|
| `require_reviewed` stops on `new = TRUE` | Lookup with unreviewed rows → stops with informative error |
| `require_reviewed = FALSE` allows `new` rows | Same lookup passes when arg is FALSE |
| Missing `raw`/`canonical` cols → error | Lookup without required columns stops with error |

**Internal helpers**

| Test | What to assert |
|---|---|
| `.normalize_unknown_canonical()` | "UNKNOWN", "Unknown", "unknown" all → "Unknown" |
| `.coerce_new_flag()` logical input | `TRUE`/`FALSE` passes through as-is |
| `.coerce_new_flag()` character input | `"true"`, `"T"`, `"1"`, `"yes"` → TRUE; `"false"` → FALSE |
| `.affiliation_occurrence_key()` | Concatenates record_key and raw with `\r` separator |

### `test-classify_publications.R` — `classify_publications()` helpers

The main `classify_publications()` function requires a live LLM and is not unit
tested here. Retry-on-failure behavior is tested in the `pubclassify` package.
The two local helpers in `classify_publications.R` are testable without
credentials:

**`env_or_null()`**

| Test | What to assert |
|---|---|
| Set env var → returned | `withr::with_envvar(c(FOO = "bar"), env_or_null("FOO"))` returns `"bar"` |
| Unset env var → NULL | Unset variable returns `NULL` |
| Empty string → NULL | `withr::with_envvar(c(FOO = ""), env_or_null("FOO"))` returns `NULL` |

**`%||%`**

| Test | What to assert |
|---|---|
| NULL left → right | `NULL %||% "default"` returns `"default"` |
| Non-NULL left → left | `"value" %||% "default"` returns `"value"` |
| Both NULL → NULL | `NULL %||% NULL` returns `NULL` |

### `scripts/patch_classify_na.R` — recovery script

This is an operational driver script, not an exported function, so it does not
have a dedicated test file. Its behaviour depends on `classify_publications()`
(covered above) and `dplyr::rows_update()` (standard dplyr). Manual verification
after running the script: check that `accepted_publications.parquet` has no
remaining `NA` `pc_field` rows with `sum(is.na(arrow::read_parquet(...)[["pc_field"]]))`.

### `test-join_institution_countries.R` — `join_institution_countries()`

| Test | What to assert |
|---|---|
| Adds `affiliation_countries` list column | Column present with list type |
| Maps canonical → country | Known canonical name returns expected country |
| Unmatched affiliations → empty vector | Affiliation not in geo lookup → `character(0)` for that pub |
| Deduplicates countries | Two affiliations in same country → one entry in country vector |
| Missing required columns → error | Geo CSV without `canonical` or `country` → informative stop |
| NA country rows skipped | Rows with NA country in geo lookup do not produce NA entries |

---

## Implementation priorities

**Tier 1 — pure functions, no file I/O** (implement first; fastest feedback loop):
- `add_record_keys`
- `flag_dwr_contributions`
- `score_dwr_relevance`
- `normalize_scopus_name` and name-util helpers
- `.normalize_unknown_canonical`, `.coerce_new_flag`, `.affiliation_occurrence_key`

**Tier 2 — file I/O with temp files** (use `withr::local_tempdir()` for isolation):
- `create_refresh_id` / `init_refresh_log` / `complete_refresh_log`
- `apply_review_decisions`
- `append_accepted_publications`
- `join_institution_countries`

**Tier 3 — functions that depend on multiple files** (build on Tier 2 patterns):
- `apply_affiliation_lookup` (depends on lookup CSV + parquet pubs)
- `score_author_affiliation` (depends on author division lookup CSV)
- `author_in_lookup` / `resolve_author_division` (need prepared lookup)
- `build_funder_review_queue` / `build_author_review_queue` (need accepted parquet + decisions CSV)

---

## Packages needed

```r
install.packages(c("testthat", "withr"))
# Already used by the pipeline (should already be present):
# dplyr, tibble, readr, arrow, digest, stringdist
```

Run all tests:

```r
testthat::test_dir("tests/testthat")
```

Run a single file:

```r
testthat::test_file("tests/testthat/test-add_record_keys.R")
```
