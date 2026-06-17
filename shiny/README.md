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

**When to use:** Any time, for exploration. Displays the final accepted publications with filters by year, division, science category, and contribution type. Includes an LLM chat assistant for natural-language queries over the inventory.

**Reads:** `data/generated/dwr_publications.parquet`
**Writes:** nothing

#### Filters

The left panel provides filter controls for year range, science category and field, DWR division, contribution type (Sole Author / Lead Author / Co-Author / Funder), and author affiliation. A keyword box searches across title, abstract, and author names. All filters update the publication table and charts in real time.

#### Chat assistant

The "Ask the data" button opens a chat sidebar powered by an LLM. The assistant operates on the current filtered view and can answer questions, run breakdowns, and control the dashboard filters — all through natural language.

The assistant uses the same LLM backend configured in `config/pipeline.yml` (`llm.base_url` and `llm.model`) and the same API key (`PUBCLASSIFY_LLM_KEY`). Each user session creates a fresh chat context; conversation history does not persist across page reloads.

The chat is built on the `ellmer` and `shinychat` packages. `ellmer` manages the LLM connection and tool call dispatch; `shinychat` provides the Shiny UI widget. Tool call/response cards are hidden from the chat pane — only the assistant's final text responses are shown.

The assistant has twelve tools. Some tools update the live dashboard (UI-driving tools); others query the current filtered view and return text answers (query tools).

**UI-driving tools** — these directly modify the Shiny filter controls:

| Tool | What it does |
|------|-------------|
| `set_filters` | Sets keyword, year range, science category/field, division, contribution type, or affiliation filters. Multiple parameters can be set in one call. |
| `reset_filters` | Clears all filters and returns the dashboard to its default state. |
| `filter_to_papers` | Pins the dashboard to a specific set of papers by record key — typically used after `find_papers` when the user wants to see those results in the table. |

**Query tools** — these read the current filtered view (or the full inventory) and return a text answer:

| Tool | What it does |
|------|-------------|
| `count_by` | Returns a ranked frequency table for a single dimension: year, science field/category, division, contribution type, journal, affiliation, or country. |
| `get_trend` | Returns year-by-year publication counts, optionally broken out by contribution type or division. |
| `compare_periods` | Splits the current view at a given year and compares counts and field distributions before and after. |
| `find_papers` | Full-text keyword search across title, abstract, and author fields across the entire inventory (not just the current filtered view). Returns a numbered list of matching papers. |
| `get_paper_detail` | Returns full metadata (title, authors, year, journal, abstract, science field, division, DOI) for a specific paper identified by title fragment or DOI. |
| `synthesize_selection` | Retrieves titles and abstracts for all currently visible papers so the LLM can summarize themes or answer questions about that set. Capped at 300 papers. |
| `get_author_stats` | Returns the most prolific DWR authors in the current view, with total and lead/sole-author counts. |
| `get_collaboration_stats` | Returns the external institutions most frequently appearing as co-author affiliations in the current view. |
| `cite_papers` | Formats citations for the current filtered selection, sorted by year or title. |

See [`docs/CHAT_TOOLS.md`](../docs/CHAT_TOOLS.md) for more detail on each tool's parameters and example prompts.

---

## Prerequisites

All review apps require the relevant pipeline targets to have been built first. If the expected queue or lookup file is missing, the app will stop with an informative error pointing to the `tar_make()` call that creates it.
