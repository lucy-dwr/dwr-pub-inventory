# Institution Geolocation — Spec

## Overview

Adds country and US state (where applicable) to every unique canonical institution in `affiliation_lookup.csv` using an LLM, in the same style as affiliation canonicalization. Countries flow into the final accepted inventory as `affiliation_countries` — a list column in the parquet and a semicolon-delimited string in the CSV. States are stored in the geo lookup for reference but are not promoted to the final inventory.

---

## Lookup table: `institution_geo_lookup.csv`

**Path:** `data/lookups/institution_geo_lookup.csv`

| Column | Type | Notes |
|---|---|---|
| `canonical` | character | Primary key. Exact canonical institution name from `affiliation_lookup.csv`. |
| `state` | character | Full US state name (e.g. `"California"`, `"New York"`). `NA` for non-US institutions or when state is unclear. US only — no Canadian provinces or other sub-national units. |
| `country` | character | Full English country name (e.g. `"United States"`, `"Germany"`, `"China"`). `NA` when country cannot be determined with confidence. No abbreviations or ISO codes. |
| `resolved` | logical | `TRUE` once the row has been through the LLM. Rows where `resolved = TRUE` are never re-queried, even if `country` is `NA`. |

**Key invariants:**
- One row per unique canonical institution name.
- The lookup is durable: existing resolved rows are never re-sent to the LLM.
- `"Unknown"` institution entries from `affiliation_lookup.csv` are excluded — they have no meaningful location.
- The LLM must not guess. If the country is ambiguous, both `state` and `country` are recorded as `NA` with `resolved = TRUE`.
- No human review step. Corrections can be made directly in the CSV by editing `country` / `state` values; the `resolved` flag can be left `TRUE`.

---

## LLM prompt design

### System prompt (`prompts/geo_system_prompt.txt`)

Rules for the model:
1. Return the full English country name. No abbreviations, ISO codes, or demonyms.
2. For US institutions only, return the full US state name. `null` for all others.
3. If country cannot be determined with confidence, return `null` for both. Do not guess.
4. Well-known institutions are resolved confidently; generic or ambiguous names return `null`.
5. US federal agencies and institutions with "United States" / "U.S." in their name resolve to country `"United States"`.
6. Respond with a JSON array only — no markdown fences or other text.

### User template (`prompts/geo_user_template.txt`)

Receives a numbered list of institution names via `{{institution_list}}`. Instructs the model to respond with a same-length JSON array, one element per institution: `{"index": <int>, "country": "..." | null, "state": "..." | null}`.

---

## R functions

### `R/build_institution_geo_lookup.R`

Builds and updates `institution_geo_lookup.csv`.

**Logic:**
1. Read `affiliation_lookup.csv`. Extract unique canonical values where `new == FALSE` and `canonical != "Unknown"`.
2. Read existing `institution_geo_lookup.csv` (if present). Skip any canonical where `resolved == TRUE`.
3. Send only unresolved canonicals to the LLM in batches of 50.
4. Parse JSON response. On failure, write `NA` for that batch and warn.
5. Merge new rows into existing lookup; write CSV sorted by `canonical`.

### `R/join_institution_countries.R`

Joins `affiliation_countries` onto a publication tibble.

**Logic:**
1. Read `institution_geo_lookup.csv`. Build `canonical → country` map (excluding NA-country rows).
2. For each publication, look up country of each affiliation; collect unique non-NA values as a character vector.
3. Add as `affiliation_countries` list column.

---

## Pipeline integration (`_targets.R`)

### New targets (after `affiliation_lookup_file`)

```r
tar_target(geo_system_prompt_file, pipeline_config$paths$geo_system_prompt, format = "file")
tar_target(geo_user_template_file, pipeline_config$paths$geo_user_template, format = "file")
tar_target(
  institution_geo_lookup_file,
  { build_institution_geo_lookup(...); pipeline_config$paths$institution_geo_lookup },
  format = "file"
)
```

### Updated `pubs_canonicalized`

```r
apply_affiliation_lookup(pubs_to_publish, affiliation_lookup_file) |>
  join_institution_countries(institution_geo_lookup_file)
```

### Dashboard CSV

`"affiliation_countries"` added to `list_cols` so it is collapsed with `"; "` alongside `authors` and `affiliations`.

---

## Final inventory outputs

| Output | Format | `affiliation_countries` |
|---|---|---|
| `data/generated/accepted_publications.parquet` | parquet | list column (character vector per row) |
| `data/generated/dwr_publications.parquet` | parquet | list column (pass-through) |
| `data/generated/dwr_publications.csv` | CSV | semicolon-delimited string |

---

## Config additions (`config/pipeline.yml`)

```yaml
paths:
  geo_system_prompt: prompts/geo_system_prompt.txt
  geo_user_template: prompts/geo_user_template.txt
  institution_geo_lookup: data/lookups/institution_geo_lookup.csv
```
