# Prompts

Three LLM tasks are used in the pipeline, each with a system prompt and a user template. All use an OpenAI-compatible chat API configured via `config/pipeline.yml`.

---

## Affiliation canonicalization

**Files:** `affiliation_system_prompt.txt`, `affiliation_user_template.txt`

**Used by:** `R/build_affiliation_lookup.R`

**What it does:** Groups raw affiliation strings by fuzzy similarity, then sends each cluster to the LLM and asks for the single canonical institution name that best represents the cluster. The result populates `data/lookups/affiliation_lookup.csv`.

**Template variable:** `{{cluster_blocks}}` — one numbered block per cluster, each listing the raw strings that belong to it.

**Output format:** JSON array, one object per cluster with `cluster_id` (int) and `canonical` (string or `"Unknown"`).

---

## Publication field classification

**Files:** `classify_system_prompt.txt`, `classify_user_instructions.txt`

**Used by:** `R/classify_publications.R`

**What it does:** Assigns each accepted publication to exactly one science field from the taxonomy in `taxonomy/`. The system prompt defines classification rules; the user instructions file provides tie-breaking priority rules that are appended to every request along with the actual publication batch.

**Output format:** JSON array, one object per publication. The pipeline parses the model response via `pubclassify`, which returns a data frame with `field` and `rationale` columns. The pipeline then assigns `field` to the `pc_field` column in the accepted publications table.

---

## Institution geolocation

**Files:** `geo_system_prompt.txt`, `geo_user_template.txt`

**Used by:** `R/build_institution_geo_lookup.R`

**What it does:** For each unique canonical institution name that has not yet been resolved, determines the country and (for US institutions) the US state. Results populate `data/lookups/institution_geo_lookup.csv`. The LLM is instructed to return `null` rather than guess when a location cannot be determined with confidence.

**Template variable:** `{{institution_list}}` — numbered list of institution names.

**Output format:** JSON array, one object per institution with `index`, `country`, and `state`.

---

## Dashboard chat assistant

**File:** `chat_system_prompt.txt`

**Used by:** `shiny/dashboard_app_internal.R` (loaded via `glue::glue()` at app startup)

**What it does:** Sets the system prompt for the per-session `ellmer` chat object that powers the "Ask the data" chat sidebar. Describes the available tools, when to use each one, tone rules, and how to handle out-of-scope requests.

**Template variables** (resolved from live data at app startup):

| Variable | Value |
|---|---|
| `{year_min}` / `{year_max}` | Full year range of the inventory |
| `{year_default_start}` / `{year_default_end}` | Default year range shown on load |
| `{categories_str}` | Semicolon-delimited science category list |
| `{fields_str}` | Semicolon-delimited science field list |
| `{divisions_str}` | Semicolon-delimited DWR division list |
| `{contrib_types_str}` | Comma-delimited contribution type list |
| `{n_affiliations}` | Total number of unique affiliations |
| `{affiliations_str}` | Semicolon-delimited sample of the top 60 affiliations |

Injecting live filter values at startup (rather than hardcoding them) keeps the prompt accurate as the inventory grows without manual edits.

---

## Modifying prompts

Rule changes in a system prompt affect all future LLM calls. They do not retroactively change already-resolved rows in the lookup files — those are protected by the `resolved = TRUE` flag (geo) or `reviewed_at` timestamp (affiliations). If you need to re-resolve existing rows after a rule change, clear the relevant flag/timestamp in the lookup CSV before re-running the pipeline target.
