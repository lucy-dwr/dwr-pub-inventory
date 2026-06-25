# Tests

Unit tests using **testthat v3**. No Scopus API key or LLM credential is required — all tests use in-memory fixtures or temporary files.

## Running tests

Run the full suite:

```r
testthat::test_dir("tests/testthat")
```

Run a single file:

```r
testthat::test_file("tests/testthat/test-add_record_keys.R")
```

## Layout

```
tests/
├── README.md                    # this file
├── TESTING.md                   # per-function test specs and fixture definitions
└── testthat/
    ├── helper-fixtures.R        # shared tibble factories and temp-file helpers
    ├── test-add_record_keys.R
    ├── test-append_accepted_publications.R
    ├── test-apply_affiliation_lookup.R
    ├── test-apply_review_decisions.R
    ├── test-author_name_utils.R
    ├── test-build_author_review_queue.R
    ├── test-build_funder_review_queue.R
    ├── test-classify_publications.R
    ├── test-create_refresh_id.R
    ├── test-flag_dwr_contributions.R
    ├── test-join_institution_countries.R
    ├── test-score_author_affiliation.R
    └── test-score_dwr_relevance.R
```

`helper-fixtures.R` is auto-sourced by testthat before any test file runs. It provides `make_pubs()` and `write_decisions_csv()` used across multiple test files.

## What is not tested

`classify_publications()` requires a live LLM and is not unit tested here. The `scripts/patch_classify_na.R` recovery script is an operational driver and is verified manually. See `TESTING.md` for details on both.
