# DWR Publication Inventory

This repository builds a searchable inventory of peer-reviewed publications
funded and/or authored by the California Department of Water Resources (DWR).
The inventory is intended to provide a maintained record of DWR-related
scientific publications for discovery, reporting, quality control, and dashboard
use. It combines Scopus publication metadata with project-specific review
decisions, DWR funding and authorship indicators, division assignments,
institutional affiliation cleanup, and scientific topic classifications.

This README is primarily for maintainers who need to refresh the inventory,
review candidate records, resolve author and affiliation metadata, and publish
updated data products.

The repository uses a [`targets`](https://books.ropensci.org/targets/) pipeline
to retrieve records from Scopus, support efficient manual review of funder and
author matches, classify publications into a custom scientific taxonomy with the accompanying [`pubclassify`](https://github.com/lucy-dwr/pubclassify) R package,
and write publication datasets for downstream use.

## TL;DR

To refresh the inventory:

```r
# One-time/local setup:
# - Restore dependencies with renv::restore()
# - Set required API credentials
# - Add data/lookups/author_division_lookup.csv if doing author review

# In config/pipeline.yml, set scopus.allow_api_calls: true for an intentional harvest.
# Optionally set refresh.id; blank defaults to today's date.

# Build both review queues.
targets::tar_make(names = c(funder_review_queue_file, author_review_queue_file))

# After the harvest, set scopus.allow_api_calls: false to avoid re-querying Scopus.

# Review funder candidates.
shiny::runApp("shiny/funder_review_app.R")

# Review author candidates and resolve unresolved author divisions.
shiny::runApp("shiny/author_review_app.R")
shiny::runApp("shiny/author_division_resolution_app.R")

# Build/refresh the affiliation lookup, then review unresolved rows.
targets::tar_make(affiliation_lookup_file)
shiny::runApp("shiny/affiliation_review_app.R")

# Publish accepted records and update the funding division lookup.
targets::tar_make(names = c(accepted_publications_updated, funding_division_lookup_updated))

# In data/lookups/funding_division_lookup.csv, fill division for rows where new == TRUE.

# Rebuild dashboard exports and complete the refresh log.
targets::tar_make(names = c(dashboard_csv, dashboard_parquet, refresh_log_completed))
```

## Setup

Open the project from the repository root so `.Rprofile` can activate `renv`.
Before running the pipeline or Shiny apps for the first time, restore the locked
R package environment:

```r
renv::restore()
```

The `pubclassify` package is not on CRAN; it is recorded in `renv.lock` as a
GitHub dependency, so `renv::restore()` should install it automatically. If you
need to install or update it manually, use `pak`:

```r
pak::pak("lucy-dwr/pubclassify")
```

The refresh workflow also requires API credentials in environment variables. Set
these before running the pipeline:

- `SCOPUS_API_KEY`
- `SCOPUS_INSTTOKEN`
- `PUBCLASSIFY_EMAIL`
- `PUBCLASSIFY_LLM_KEY`

These values are secrets or user-specific settings and should not be committed to
the repository. They can be set in a local `.Renviron` file, through the shell,
or in the active R session before running `targets::tar_make()`.

## Applications

There are four applications in this repo that can be run locally for quality 
control:

- `shiny/funder_review_app.R`: manual review of Scopus funder search candidates.
- `shiny/author_review_app.R`: manual review of Scopus affiliation search
  candidates and per-author DWR affiliation status.
- `shiny/author_division_resolution_app.R`: division assignment for confirmed
  DWR authors whose division could not be resolved automatically.
- `shiny/affiliation_review_app.R`: manual review of unresolved canonical
  institution assignments with DOI/title context and canonical-name browsing.

There is also an application for viewing the publication inventory in a dashboard:

- `shiny/dashboard_app.R`: three-tab dashboard for browsing the final exported
  inventory. The **Dashboard** tab provides filtered publication charts and a
  table, plus an LLM-powered chat assistant ("Ask the data") that accepts
  natural-language questions about the inventory. The **Institution Map** tab
  shows a choropleth world map of co-author affiliated institutions by geography
  with hover/click popups. The **Publishing Network** tab shows an interactive
  force-directed co-authorship network (institution or people mode) with
  click-through paper lists. See [`shiny/README.md`](shiny/README.md),
  [`docs/CHAT_TOOLS.md`](docs/CHAT_TOOLS.md), and
  [`docs/DASHBOARD.md`](docs/DASHBOARD.md) for details.

To run an application, use `shiny`:

```r
shiny::runApp(here::here("shiny", "<app-name>"))
```

The application will then run locally—Shiny will serve it as a local URL, such as
`http://127.0.0.1:xxxx/`, that can be opened in a browser.

## Refresh Workflow

Refresh behavior is controlled through `config/pipeline.yml`. Before starting a
refresh, review this file to confirm whether Scopus API calls are enabled, which
refresh ID will be used, which large language model API endpoint and model are
used, and whether the pipeline should process only new records or reclassify all
reviewed records.

The pipeline uses an append-oriented refresh model. Previously accepted records
are not overwritten in the default mode. Each refresh cycle is organized around
review queues, durable decision files, and a durable accepted publications table.

### 1. Build Review Queues

Scopus API calls are disabled by default. To intentionally refresh harvested
records, temporarily set this in `config/pipeline.yml`:

```yaml
scopus:
  allow_api_calls: true

refresh:
  id: 2026-06-15
  default_mode: new_records_only
```

Then run:

```r
targets::tar_make(names = c(funder_review_queue_file, author_review_queue_file))
```

This harvests Scopus candidates, assigns stable `record_key` values, saves a
harvest snapshot under `data/harvests/`, and writes the current review queues:

- `data/queues/funder_review_queue.parquet`
- `data/queues/author_review_queue.parquet`

**Set `scopus.allow_api_calls` back to `false` after the harvest step.** This
keeps local review, affiliation lookup, and publish work from accidentally hitting
Scopus when working with later steps in the pipeline. Leave `refresh.id` blank
to default to today's date.

### 2. Review Candidates

#### Funded

Run the funder review app to quality control articles that Scopus reports were
funded by DWR:

```r
shiny::runApp("shiny/funder_review_app.R")
```

Funder decisions are written to `data/decisions/funding_review_decisions.csv` with
`keep`, `drop`, or `unsure` decisions keyed by `record_key`.

Kept funder records also need a DWR funding division assignment. This is not done
in the Shiny app. During the publish step, the pipeline syncs kept funder records
into `data/lookups/funding_division_lookup.csv`. After that sync, manually fill
the `division` column for rows where `new == TRUE` by retrieving contract numbers
and associated divisions from SAP, then rerun the dashboard export targets so `funding_division` is populated in the final outputs.

#### Authored

Author division assignment uses a private HR-derived lookup file, followed by
manual review when the lookup cannot resolve a single division. The private file
is intentionally not included in this repository. Before running author review,
add it locally at:

```text
data/lookups/author_division_lookup.csv
```

The file must be a CSV with these columns:

| Column | Description |
|--------|-------------|
| `division` | DWR division or office name for the employee in that year |
| `year` | Calendar year for the employee/division assignment |
| `name` | Employee name in `FIRST MIDDLE LAST` format; case is normalized by the pipeline |

Example structure:

```csv
division,year,name
SWP - Engineering,2024,JANE Q SMITH
SWP - Engineering,2025,JANE Q SMITH
Flood Operations,2025,Alex R Johnson
```

During author review, confirmed DWR authors are matched against this lookup by
name and publication year. The app first tries to resolve the author's division
from the publication year, then the prior year, then the following year. If this
produces one division, the division is saved automatically. If the lookup finds
multiple possible divisions, or no match, the author is sent to the division
resolution app for manual review.

Division names from the HR lookup are normalized against
`data/lookups/dwr_org_lookup.csv`. This lookup maps historical names,
abbreviations, and renamed offices to the canonical division names used in the
inventory, so division assignments remain comparable even when DWR organization
names change over time.

Run the author review app to quality control articles that Scopus reports were
authored by DWR-affiliated authors:

```r
shiny::runApp("shiny/author_review_app.R")
```

Author review writes two files:

- `data/decisions/author_review_decisions.csv`: publication-level keep/drop/unsure
  decisions for DWR affiliation candidates.
- `data/decisions/author_division_decisions.csv`: author-level DWR/not-DWR decisions and resolved division metadata where available.

Resolve any confirmed DWR authors that still need manual division assignment by
running:

```r
shiny::runApp("shiny/author_division_resolution_app.R")
```

### 3. Refresh The Affiliation Lookup

Next, run the lookup-maintenance target:

```r
targets::tar_make(affiliation_lookup_file)
```

This harvests and prepends any previously unseen raw affiliation strings to
`data/lookups/affiliation_lookup.csv`. The durable lookup has one row per
publication/raw-affiliation occurrence, with DOI and title context.

This step also uses the configured LLM to propose canonical institution names.
The model and OpenAI-compatible API endpoint are set in `config/pipeline.yml`,
and the API key is read from `PUBCLASSIFY_LLM_KEY`. To keep the API call smaller,
the pipeline sends only raw affiliation strings that still need labels, reuses
trusted canonical values from the existing lookup when possible, and batches the
remaining strings for LLM canonicalization. The LLM is prompted with
`prompts/affiliation_system_prompt.txt`,
`prompts/affiliation_user_template.txt`, and the known institution reference list
in `data/lookups/institution_reference.txt`.

The LLM output is treated as a draft lookup value, not as final reviewed data.
Unresolved or uncertain results are retained as `canonical = "Unknown"` with
`new = TRUE`.

Review unresolved rows in the affiliation review app:

```r
shiny::runApp("shiny/affiliation_review_app.R")
```

The app defaults to `Unknown` and `new` rows, provides autocomplete from
established canonical institution names, and includes a searchable canonical
institution browser. Set each reviewed row's canonical value and save it; saved
rows are marked `new = FALSE`.

After the affiliation lookup is reviewed, the full publish step automatically
runs `institution_geo_lookup_file` to geolocate any newly seen canonical
institutions. This queries the LLM for country and US state using
`prompts/geo_system_prompt.txt` and `prompts/geo_user_template.txt` and writes
results to `data/lookups/institution_geo_lookup.csv`. Institutions where the
country cannot be determined confidently are recorded as `NA`; those rows are not
re-queried in future refreshes. No manual review step is needed for the geo
lookup.

### 4. Classify Publications

Disciplinary classification happens during the full publish step; there is no
separate command to run. The pipeline uses the custom taxonomy in
`taxonomy/dwr_disciplines_taxonomy.csv`, which defines DWR-relevant scientific
fields and their broader categories. Each taxonomy row contains a `field`, a
plain-language `definition`, and a top-level `category` used later in exports
and the dashboard.

The classifier sends publication metadata to the configured LLM through the
`pubclassify` package. The prompt combines:

- `prompts/classify_system_prompt.txt`: the classifier role and general rules.
- `prompts/classify_user_instructions.txt`: priority rules for hard boundary
  cases.
- The taxonomy field definitions from `taxonomy/dwr_disciplines_taxonomy.csv`.
- Each publication's title, abstract, and related metadata.

The LLM is asked to assign each publication to exactly one taxonomy field based
on the paper's central scientific objective, not only on method, data type, or
study system. Under the hood, `pubclassify` expects structured model output,
parses the JSON response returned by the model, and adds classification fields
such as `pc_field`. The pipeline then joins the corresponding top-level taxonomy
category as `pc_category`.

If the LLM returns a malformed response (e.g., a duplicate index or an
unrecognized category), the classifier logs a warning and leaves `pc_field` and
`pc_rationale` as `NA` for that batch. The retry logic in `pubclassify` retries
failed batches up to three times, but persistent failures can still leave a small
number of records unclassified. If `tar_meta(fields = warnings, complete_only = TRUE)`
shows classification warnings after a pipeline run, use the recovery script:

```r
Rscript scripts/patch_classify_na.R
```

This classifies any `accepted_publications.parquet` rows with `NA` `pc_field` and
patches the file in place. Afterwards, run
`targets::tar_make(names = c(dashboard_csv, dashboard_parquet))` to refresh the
dashboard exports.

### 5. Publish The Updated Inventory

```r
targets::tar_make(names = c(accepted_publications_updated, funding_division_lookup_updated))
```

This applies review decisions, canonicalizes affiliations, classifies records
that are not already in the accepted publications table, appends newly accepted
records to `data/generated/accepted_publications.parquet`, and updates the
keep-only funding division lookup.

Open `data/lookups/funding_division_lookup.csv` and fill the `division` column
for any current-refresh rows where `new == TRUE`. These rows are kept funder
records that need a manual DWR division assignment before the dashboard exports
are final. Leave `new` unchanged; the pipeline recalculates it on the next run.

Then rebuild the dashboard exports and complete the refresh log:

```r
targets::tar_make(names = c(dashboard_csv, dashboard_parquet, refresh_log_completed))
```

This joins funding and author division fields and writes dashboard exports.

The targeted publish step uses the saved harvest snapshot for the current
`refresh.id`, so it can run after `scopus.allow_api_calls` has been set back to
`false`. It updates `data/lookups/affiliation_lookup.csv` before canonicalization
and stops if any lookup rows are still marked `new = TRUE`.

### Refresh Modes

Set `refresh.default_mode` in `config/pipeline.yml` before running the publish
command:

| Mode | Behavior |
|------|----------|
| `new_records_only` (default) | Classify only records not already accepted |
| `reclassify_all` | Reclassify every record in the current reviewed harvest |

## Project Structure

```text
_targets.R                              # Pipeline definition
README.md                               # Project overview and operator quickstart
LICENSE

docs/
  ARCHITECTURE.md                       # Pipeline and dashboard architecture reference
  DASHBOARD.md                          # Dashboard design and behavior reference
  CHAT_TOOLS.md                         # Chat assistant tool reference
  DATA_REFERENCE.md                     # Data schemas and file formats
  LIMITATIONS.md                        # Known dataset and data-model limitations

config/
  pipeline.yml                          # Non-secret pipeline settings and paths

R/
  load_pipeline_config.R                # Read config/pipeline.yml
  add_record_keys.R                     # Assign stable record_key values
  create_refresh_id.R                   # Refresh identity and refresh log management
  save_harvest_candidates.R             # Persist harvest snapshots per refresh
  build_funder_review_queue.R           # Build funder candidates needing review
  build_author_review_queue.R           # Build author/affiliation candidates needing review
  apply_review_decisions.R              # Apply keep/drop decisions from review files
  append_accepted_publications.R        # Append new records to accepted publications
  update_funding_division_lookup.R      # Maintain keep-only funder division lookup
  join_funding_division.R               # Join funding divisions into exports
  join_author_division.R                # Join resolved author divisions into exports
  flag_dwr_contributions.R              # Add contribution-type boolean flags
  author_name_utils.R                   # Author lookup/name matching utilities
  score_dwr_relevance.R                 # Funder-review suspicion scoring
  score_author_affiliation.R            # Author-review suspicion scoring
  apply_affiliation_lookup.R            # Canonicalize affiliation strings
  build_affiliation_lookup.R            # Build affiliation lookup table
  build_institution_reference.R         # Build institution reference list
  build_institution_geo_lookup.R        # Geolocate canonical institutions (country, state)
  join_institution_countries.R          # Join institution countries onto publications
  require_scopus_api_allowed.R          # Guard Scopus API calls behind config flag
  resolve_harvest_candidates_file.R     # Locate saved harvest candidates for a refresh

scripts/
  patch_classify_na.R                   # Back-fill pc_field for publications left NA after LLM failures

taxonomy/
  dwr_disciplines_taxonomy.csv          # DWR field taxonomy

prompts/
  classify_system_prompt.txt            # LLM system prompt for disciplinary classification
  classify_user_instructions.txt        # LLM user instructions for disciplinary classification
  affiliation_system_prompt.txt         # LLM system prompt for affiliation canonicalization
  affiliation_user_template.txt         # LLM user template for affiliation canonicalization
  geo_system_prompt.txt                 # LLM system prompt for institution geolocation
  geo_user_template.txt                 # LLM user template for institution geolocation

data/
  refresh_log.csv                       # One row per refresh cycle with counts
  decisions/
    funding_review_decisions.csv        # Funder keep/drop/unsure decisions
    author_review_decisions.csv         # Author-publication keep/drop/unsure decisions
    author_division_decisions.csv       # Per-author DWR status and division decisions
  lookups/
    funding_division_lookup.csv         # Kept funder records with division assignments
    dwr_org_lookup.csv                  # Raw org label to canonical division mapping
    institution_reference.txt           # Institution reference list for lookup generation
    affiliation_lookup.csv              # Occurrence-level canonical institution review table
    institution_geo_lookup.csv          # Country and US state per canonical institution
    author_division_lookup.csv          # Required local HR-derived lookup; ignored by Git
  generated/
    accepted_publications.parquet       # Durable source of truth; generated by pipeline
    dwr_publications.csv                # dashboard_csv target; list columns collapsed
    dwr_publications.parquet            # dashboard_parquet target; native list columns
  queues/
    funder_review_queue.parquet         # Generated funder review queue; ignored by Git
    author_review_queue.parquet         # Generated author review queue; ignored by Git
  harvests/                             # Per-refresh candidate snapshots; ignored by Git

shiny/                                  # Review and visualization apps
  funder_review_app.R
  author_review_app.R
  author_division_resolution_app.R
  affiliation_review_app.R
  dashboard_app.R
  www/
    dwr-logo-new.png                    # Dashboard logo asset

renv/
  activate.R
  settings.json
renv.lock                               # R dependency lockfile
```

## Outputs

- `data/generated/accepted_publications.parquet`: durable source of truth; records are
  appended across refreshes in the default mode.
- `data/lookups/funding_division_lookup.csv`: manual lookup for funder-query records
  with explicit `keep` decisions in `data/decisions/funding_review_decisions.csv`.
  Newly accepted current-refresh rows are prepended; `new == TRUE` means the
  row still needs a manual funding division assignment from the current refresh.
- `data/generated/dwr_publications.csv`: dashboard export with list columns collapsed to
  semicolon-delimited strings. Includes `funding_division`, `author_division`,
  and `affiliation_countries` when available.
- `data/generated/dwr_publications.parquet`: full-fidelity dashboard export used by
  `shiny/dashboard_app.R`. Includes native list columns (including
  `affiliation_countries`) plus joined division fields.

## Data Reference

For stable record keys, refresh log fields, decision file schemas, and lookup
table schemas, see [`docs/DATA_REFERENCE.md`](docs/DATA_REFERENCE.md).
For interpretation caveats, see
[`docs/LIMITATIONS.md`](docs/LIMITATIONS.md).
