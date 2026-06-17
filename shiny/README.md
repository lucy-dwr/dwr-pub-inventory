# Shiny Apps

Five Shiny apps support the manual review and exploration steps of the pipeline. Each app reads from and writes to files in `data/` directly — they do not need a running API server.

Launch any app from the project root:

```r
shiny::runApp("shiny/<app_file>.R")
```

Or from inside the `shiny/` directory:

```r
shiny::runApp("<app_file>.R")
```

---

## Apps by workflow step

### 1. `funder_review_app.R` — Funder publication review

**When to use:** After `targets::tar_make(funder_review_queue_file)`. Review each candidate from the funder query one at a time and record a keep / drop / unsure decision.

**Reads:** `data/queues/funder_review_queue.parquet`
**Writes:** `data/decisions/funding_review_decisions.csv`

Records are sorted by `cdwr_score` descending — highest-priority review candidates first.

---

### 2. `author_review_app.R` — Author/affiliation publication review

**When to use:** After `targets::tar_make(author_review_queue_file)`. Review each candidate from the affiliation query and assign a keep / drop / unsure decision. Also surfaces author-to-division assignments for ambiguous authors.

**Reads:** `data/queues/author_review_queue.parquet`, `data/lookups/author_division_lookup.csv`, `data/lookups/dwr_org_lookup.csv`
**Writes:** `data/decisions/author_review_decisions.csv`, `data/decisions/author_division_decisions.csv`

Records are sorted by `caff_score` descending.

---

### 3. `affiliation_review_app.R` — Affiliation canonicalization review

**When to use:** After `build_affiliation_lookup()` produces new rows needing review. For each raw affiliation string, confirm or correct the LLM-suggested canonical institution name.

**Reads:** `data/lookups/affiliation_lookup.csv`, `data/lookups/institution_reference.txt`
**Writes:** `data/lookups/affiliation_lookup.csv` (in place)

Only rows where `reviewed_at` is NA are shown by default. Saving a row marks it reviewed.

---

### 4. `author_division_resolution_app.R` — Author division disambiguation

**When to use:** When the author review surfaces authors whose division could not be resolved automatically (rule 4 = ambiguous, rule 5 = not found). Assign a definitive division for each flagged author/publication pair.

**Reads:** `data/queues/author_review_queue.parquet`, `data/lookups/author_division_lookup.csv`, `data/lookups/dwr_org_lookup.csv`
**Writes:** `data/decisions/author_division_decisions.csv`

---

### 5. `dashboard_app.R` — Publication inventory dashboard

**When to use:** Any time, for exploration. Displays the final accepted publications with filters by year, division, science category, and contribution type. Includes an LLM chat interface for natural-language queries over the inventory.

**Reads:** `data/generated/dwr_publications.parquet`
**Writes:** nothing

Requires `ellmer` and `shinychat` packages for the chat feature. If those are not installed, remove the chat panel from the UI.

---

## Prerequisites

All review apps require the relevant pipeline targets to have been built first. If the expected queue or lookup file is missing, the app will stop with an informative error pointing to the `tar_make()` call that creates it.
