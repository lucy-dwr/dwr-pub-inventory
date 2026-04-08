# DWR Publication Inventory — Analysis Plan

## Overview

This project produces a flat tabular inventory of peer-reviewed publications
funded and/or authored by the California Department of Water Resources (DWR),
with each publication classified into a user-defined scientific field taxonomy
using a large language model.

The pipeline is orchestrated with the
[`targets`](https://docs.ropensci.org/targets/) package. All bibliometric
retrieval and LLM classification is handled by the
[`pubclassify`](https://github.com/lucy-dwr/pubclassify) package.

---

## Repository Structure

```
_targets.R                  # Pipeline declaration (targets DAG only)
setup.R                     # One-time dev setup (load pubclassify from local path)
R/                          # Custom functions, sourced by tar_source("R/")
  score_dwr_relevance.R    # Heuristic scoring for funder review prioritisation
shiny/
  funder_review_app.R       # Shiny app for manual funder review
taxonomy/
  dwr_taxonomy.csv          # Field taxonomy (columns: field, definition)
data/
  review_decisions.csv      # Manual keep/drop/unsure decisions from review app
  dwr_publications.csv      # Flat output with list columns as semicolon strings
  dwr_publications.parquet  # Full-fidelity output with native list columns
```

---

## Configuration

Credentials are loaded from environment variables at pipeline runtime via
`pc_configure()`. The following environment variables must be set:

| Variable                  | Purpose                                      |
|---------------------------|----------------------------------------------|
| `SCOPUS_API_KEY`          | Elsevier Scopus API key                      |
| `SCOPUS_INSTTOKEN`        | Elsevier institutional token (COMPLETE view) |
| `PUBCLASSIFY_LLM_KEY`     | API key for the OpenAI-compatible LLM        |
| `PUBCLASSIFY_LLM_BASE_URL`| `https://customeruat.sda.state.ca.gov/api/v1`|
| `PUBCLASSIFY_EMAIL`       | Email for OpenAlex polite pool (optional)    |

`pc_configure()` is called once at the top of `_targets.R` (not as a target).

---

## Pipeline

### Target DAG

```mermaid
flowchart LR
    pubs_funding   --> pubs_funding_reviewed
    pubs_funding_reviewed --> pubs_combined
    pubs_affiliation --> pubs_combined
    pubs_combined    --> pubs_flagged
    pubs_flagged     --> pubs_classified
    taxonomy         --> pubs_classified
    pubs_classified  --> affiliation_lookup_csv
    affiliation_lookup_csv --> pubs_canonicalized
    pubs_classified  --> pubs_canonicalized
    pubs_canonicalized --> output_csv
    pubs_canonicalized --> output_parquet
```

---

### Target Descriptions

#### `taxonomy`

Load the custom field taxonomy from `taxonomy/dwr_taxonomy.csv` using
`pc_taxonomy()`. The CSV must have exactly two columns: `field` and
`definition`. This target will be invalidated automatically if the taxonomy
file changes, triggering reclassification.

```r
tar_target(
  taxonomy,
  pc_taxonomy("taxonomy/dwr_taxonomy.csv"),
  # Mark the CSV as a file dependency so edits invalidate this target
  # (wrap with tar_target format = "file" + read pattern, or use
  # a tarchetypes::tar_file_read() approach — to be decided at implementation)
)
```

---

#### `pubs_funding`

Search Scopus for publications acknowledging DWR as a funder the query string
"California Department of Water Resources".

```r
tar_target(
  pubs_funding,
  pc_search_scopus(
    query      = "California Department of Water Resources",
    field      = "funder",
    doc_type   = c("article", "review"),
    auto_fetch = FALSE
  )
)
```

---

#### Manual funder review (`shiny/funder_review_app.R`)

After `pubs_funding` is built, a Shiny app is available for manually
reviewing each publication to confirm it is genuinely a California DWR-funded
record. Launch it from the project root with:

```r
shiny::runApp("shiny/funder_review_app.R")
```

The app loads `pubs_funding` from the targets store, scores every record
with `score_dwr_relevance()` (see below), and presents them in descending
suspicion order so the most likely false positives are reviewed first. For each
publication the reviewer sees the title, suspicion score, DOI, year/journal,
author affiliations, funders, grant numbers, and an embedded view of the paper.

**Suspicion scoring (`R/score_dwr_relevance.R`)** adds points for signals that
suggest a record is *not* a genuine CA DWR publication:

| Signal | Points |
|--------|--------|
| No California geographic mention across all text fields | +4 |
| No water-related topic in title or abstract | +4 |
| Domain keywords indicate an unrelated field (medicine, physics, etc.) | +3 |
| No US institution detected in author affiliations | +2 |

Maximum score: 13. High suspicion ≥ 7, medium ≥ 4, low < 4.

The reviewer assigns one of three decisions to each record:

| Decision | Meaning |
|----------|---------|
| `keep`   | Confirmed as a CA DWR-funded publication |
| `drop`   | Not a CA DWR publication — exclude from pipeline |
| `unsure` | Ambiguous — flagged for further review |

Decisions are written to `data/review_decisions.csv` in real time. The app
resumes from the first unreviewed record on restart.

---

#### `review_decisions_file`

Tracks `data/review_decisions.csv` as a file dependency so that any edits
saved by the review app automatically invalidate `pubs_funding_reviewed`
and all downstream targets.

```r
tar_target(review_decisions_file, "data/review_decisions.csv", format = "file")
```

---

#### `pubs_funding_reviewed`

Applies the manual review decisions to `pubs_funding`, dropping records
marked `"drop"` and passing `"keep"` and `"unsure"` records through. This is
implemented by `apply_review_decisions()` in `R/`.

```r
tar_target(
  pubs_funding_reviewed,
  apply_review_decisions(pubs_funding, review_decisions_file)
)
```

---

#### `pubs_affiliation`

Search Scopus for publications where at least one author is affiliated with
DWR using the query string "California Department of Water Resources".

```r
tar_target(
  pubs_affiliation,
  pc_search_scopus(
    query      = "California Department of Water Resources",
    field      = "affiliation",
    doc_type   = c("article", "review"),
    auto_fetch = FALSE
  )
)
```

---

#### `pubs_combined`

Combine `pubs_funding_reviewed` and `pubs_affiliation` into a single deduplicated
tibble, tracking which search(es) each DOI came from before deduplication.
The source provenance columns (`from_funder`, `from_affiliation`) are used in
the next step to compute DWR contribution flags.

Deduplication is handled by `pc_deduplicate()`, which prefers the richest
record when a DOI appears in both result sets.

---

#### `pubs_flagged`

Add four boolean contribution columns to `pubs_combined`. These flags are not
mutually exclusive — a publication can both a funder flag and authorship flags.

| Column           | Definition                                |
|------------------|-------------------------------------------|
| `is_funder`      | DWR is acknowledged as a funder           |
| `is_author`      | At least one author is DWR-affiliated     |
| `is_lead_author` | The first-listed author is DWR-affiliated |
| `is_sole_author` | All authors are DWR-affiliated            |

The flags are nested: `is_sole_author → is_lead_author → is_author`. A record
can have `is_funder = TRUE` and more than one nested authorship flag set
simultaneously.

- `is_funder` is derived from `from_funder` provenance.
- `is_author` is derived from `from_affiliation` provenance.
- `is_lead_author` is computed by checking whether the first element of the
  `affiliations` list-column contains `"California Department of Water
  Resources"`.
- `is_sole_author` is computed by checking whether every element of the
  `affiliations` list-column contains `"California Department of Water
  Resources"`.

---

#### `pubs_classified`

Classify each publication into a scientific field from the taxonomy using the
OpenAI-compatible LLM endpoint hosted by the California Department of
Technology. Classification uses title and abstract as input text.

```r
tar_target(
  pubs_classified,
  pc_classify(
    pubs      = pubs_flagged,
    taxonomy  = taxonomy,
    provider  = "openai-compatible",
    model     = "<model name TBD>",
    api_key   = Sys.getenv("PUBCLASSIFY_LLM_KEY"),
    base_url  = Sys.getenv("PUBCLASSIFY_LLM_BASE_URL")
  )
)
```

The LLM model name is to be confirmed. Because the taxonomy has fewer than 40
fields, `use_embeddings = FALSE` (the default) is appropriate.

A custom `system_prompt` and `classify_instructions` should be developed and
passed to `pc_classify()` to guide the model. This will be drafted once the
taxonomy fields are finalized.

---

#### Institution canonicalization (`R/build_affiliation_lookup.R`)

After `pubs_classified` is built, a script is available to build a canonical
institution lookup table from the raw affiliation strings. Run it once from the
project root before building `pubs_canonicalized`:

```r
source("R/build_affiliation_lookup.R")
build_affiliation_lookup()
```

The script proceeds in three stages:

**Stage 1 — Extract unique raw strings.**  Flatten `pubs_classified$affiliations`
(a list column where each element is a character vector of per-author
affiliations) into a single character vector of unique raw strings. Each unique
string is the unit of work for the remainder of the process.

**Stage 2 — Cluster by string similarity.**  Compute pairwise string distances
(`stringdist` package, method `"jw"` or `"cosine"` on token sets) and apply
hierarchical clustering with a conservative threshold so that only near-certain
variants are grouped automatically. The output is a data frame with columns
`raw` and `cluster_id`. Cluster membership can be inspected and manually
corrected before proceeding.

**Stage 3 — LLM labels each cluster.**  For each cluster, send all member
strings together to the LLM with a structured prompt asking for a single
canonical institution name. The prompt includes:

- A **reference list** of expected institutions (all UC campuses, CSU campuses,
  major CA state agencies — DWR, DFW, SWRCB, etc. — and common federal agencies
  — USGS, BOR, EPA, NOAA) so the LLM matches against known names rather than
  generating freely.
- A **naming convention rule**: always use the full official name; for UC
  campuses use `"University of California, [City]"`.
- An instruction to return the sentinel `"UNKNOWN"` rather than guess when
  confidence is low. `UNKNOWN` entries are flagged for manual resolution.

The result is written to `data/affiliation_lookup.csv` with columns:

| Column      | Description                                      |
|-------------|--------------------------------------------------|
| `raw`       | Raw affiliation string as it appears in the data |
| `canonical` | Canonical institution name (or `"UNKNOWN"`)      |

The CSV should be reviewed before the pipeline proceeds. `UNKNOWN` entries and
any suspect canonicalizations can be corrected by editing the file directly.
Once approved, the file is tracked by the `affiliation_lookup_csv` target and
triggers `pubs_canonicalized` when changed.

---

#### `affiliation_lookup_csv`

Tracks `data/affiliation_lookup.csv` as a file dependency so that any manual
edits to the lookup table automatically invalidate `pubs_canonicalized` and all
downstream targets.

```r
tar_target(affiliation_lookup_csv, "data/affiliation_lookup.csv", format = "file")
```

---

#### `pubs_canonicalized`

Apply the approved affiliation lookup table to `pubs_classified`, replacing
every raw affiliation string in the `affiliations` list column with its
canonical institution name. Implemented by `apply_affiliation_lookup()` in `R/`.

```r
tar_target(
  pubs_canonicalized,
  apply_affiliation_lookup(pubs_classified, affiliation_lookup_csv)
)
```

After canonicalization, `pubs_canonicalized$affiliations` contains only
approved canonical institution names. The unique count of institutions across
the dataset is computable directly from this column.

---

#### `output_csv`

Write a flattened version of the classified tibble to
`data/dwr_publications.csv`. List columns (`authors`, `affiliations`,
`funders`, `grant_numbers`) are collapsed to semicolon-delimited strings so
the file is readable in Excel and other tabular tools without any special
handling.

```r
tar_target(
  output_csv,
  {
    collapse_list_col <- function(x) {
      vapply(x, function(v) paste(v, collapse = "; "), character(1L))
    }
    flat <- dplyr::mutate(
      pubs_canonicalized,
      dplyr::across(c(authors, affiliations, funders, grant_numbers),
                    collapse_list_col)
    )
    readr::write_csv(flat, "data/dwr_publications.csv")
    "data/dwr_publications.csv"
  },
  format = "file"
)
```

---

#### `output_parquet`

Write the classified tibble to `data/dwr_publications.parquet` using the `arrow`
package. List columns are preserved as Arrow list type, making this the
preferred format for downstream applications (e.g., Shiny, Streamlit,
TypeScript/React via DuckDB-WASM) that need the full structured data.

```r
tar_target(
  output_parquet,
  {
    arrow::write_parquet(pubs_canonicalized, "data/dwr_publications.parquet")
    "data/dwr_publications.parquet"
  },
  format = "file"
)
```

---

## Output Schema

The pipeline produces two output files from the same underlying data:

| File                          | List columns  | Best for                              |
|-------------------------------|---------------|---------------------------------------|
| `data/dwr_publications.csv`   | Semicolon-delimited strings | Excel, simple tabular tools |
| `data/dwr_publications.parquet` | Native list type | Shiny, Streamlit, React/DuckDB  |

Both files contain the standard `pubclassify` columns plus the columns
added by this pipeline:

| Column             | Description                                              |
|--------------------|----------------------------------------------------------|
| `doi`              | Digital Object Identifier                                |
| `title`            | Article title                                            |
| `abstract`         | Article abstract                                         |
| `year`             | Publication year                                         |
| `doc_type`         | Document type (article, review, etc.)                    |
| `authors`          | Author display names (list column)                       |
| `affiliations`     | Canonical institution names per author (list column) — raw Scopus strings replaced by `pubs_canonicalized` |
| `funders`          | Funder names (list column)                               |
| `grant_numbers`    | Grant/contract numbers (list column)                     |
| `journal`          | Journal name                                             |
| `source`           | API source (`"scopus"`)                                  |
| `is_funder`        | DWR is a funder (boolean)                                |
| `is_author`        | At least one DWR author (boolean)                        |
| `is_lead_author`   | First author is DWR-affiliated (boolean)                 |
| `is_sole_author`   | All authors are DWR-affiliated (boolean)                 |
| `pc_field`         | Assigned taxonomy field                                  |
| `pc_rationale`     | LLM rationale for field assignment                       |
| `pc_text_source`   | Text used for classification (`"title+abstract"`)        |
| `pc_classified_by` | Classification method (`"llm-full"`)                     |

---

## Open Questions / Deferred Decisions / Remaining Work

- **Acknowledgments text in funder review app** — the review app currently
  relies on Scopus-provided funder and grant number fields, which are
  inconsistently populated. Adding a free-text input to the app where the
  reviewer can paste the raw acknowledgments section from the paper would give
  a more reliable signal for confirming CA DWR funding. The pasted text could
  be saved alongside the keep/drop/unsure decision in `review_decisions.csv`
  and used to inform the `pubs_funding_reviewed` filter or a separate
  manual annotation column.

- **Remaining UNKNOWN affiliations** — some canonicalized affiliations in the
  file `affiliations_lookup.csv` are still "UNKNOWN" after a first pass because
  they require manual work to address.
