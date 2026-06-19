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

**When to use:** Any time, for exploration. Displays the final accepted publications with filters by year, division, science category, and contribution type. Includes an LLM chat assistant for natural-language queries over the inventory, an Institution Map tab showing where co-author affiliated institutions are located, a Publishing Network tab for co-authorship relationships, and a Science Fields tab listing the taxonomy definitions used for publication classification.

**Reads:** `data/generated/dwr_publications.parquet`, `data/lookups/institution_geo_lookup.csv`
**Writes:** nothing

The app has four tabs: **Dashboard** (default), **Institution Map**, **Publishing Network**, and **Science Fields**.

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

#### Institution Map tab

The Institution Map tab shows a choropleth world map of co-author affiliated
institutions by geography, with US state-level detail. It has its own
independent filter controls (year range and contribution type) that do not
affect the Dashboard tab.

**Map design:**

- **Base tiles:** Esri World Gray Canvas (English-only labels, grey ocean background)
- **Color scale:** Sequential green palette (`log1p`-transformed), palette min at
  1 publication. Countries/states with zero publications are white; the grey
  ocean makes these clearly distinct.
- **Layers:** World countries layer (excluding US) + US states layer, using the
  same shared `log1p` palette domain so counts are directly comparable.
- **Hover tooltip:** Country/state name and publication count.
- **Click popup:** Name, count, and top-5 institutions by count for that
  country or state.
- **Legend:** Anchored bottom-right. Shows a white "0" swatch followed by the
  green palette at breakpoints (1, 5, 10, 50, 100, 500).

**Notes below the map (conditional):**

- *National-scope US institutions:* US institutions without a single-state
  footprint (e.g., federal agencies) are not attributed to any state on the
  map; a note below reports how many publications are affected and names the
  top institutions.
- *No geo data:* Publications whose affiliations are entirely absent from the
  geo lookup are not shown on the map; a note reports the count. This note only
  appears when the count is greater than zero — with the current inventory, all
  publications have at least one resolvable institution, so this note does not
  appear in practice.

#### Publishing Network tab

The Publishing Network tab shows an interactive force-directed co-authorship
network built from the publication inventory. It has its own independent filter
controls and does not share state with the other tabs.

**Controls:**

| Control | Default | Notes |
|---------|---------|-------|
| Year Range | 2020–2026 | Same min/max as Dashboard |
| Contribution Type | All | All / Sole Author / Lead Author / Co-Author / Funder |
| Science Field | All | Same field list as Dashboard |
| Network Mode | Institutions | Institutions (org nodes) or People (author nodes) |
| Top N Nodes | 25 | Range 5–100; step 5 |
| Reset View | — | Resets all controls to defaults |

**Network modes:**

- *Institutions* — each node is a canonical organization name from the
  `affiliations` column. DWR (`"California Department of Water Resources"`) is
  pinned at the center and always included regardless of the Top N setting.
  Nodes are colored by geography: navy = DWR, green = US institution,
  teal = international, gray = unknown.
- *People* — each node is an author name as stored in Scopus (`"Last F."`
  format). DWR authors (from `author_division_decisions.csv`) are shown in navy;
  external authors in green. A disambiguation note warns that authors sharing
  the same name and initials may be merged into a single node.

**Node size** scales with the number of distinct papers in the current filtered
view that involve that node (log-scaled). Larger nodes = more publications.

**Edge width** scales with the number of shared papers between the two endpoint
nodes (`1 + log1p(n_papers) * 2`).

**Interactions:**
- Click a node → modal listing all papers for that node in the current view
  (title linked by DOI, year, contribution type, first author).
- Click an edge → modal listing all papers shared by both endpoint nodes.
- Pan and zoom are enabled; nodes can be dragged to reposition.

**Legend:** A color legend panel on the right side of the network identifies the
node color scheme for the active mode.

#### Science Fields tab

The Science Fields tab shows a searchable taxonomy table with each science
category, field, and definition used by the publication classifier. It reads the
same `taxonomy/dwr_disciplines_taxonomy.csv` file used by the pipeline, title-
cases category and field names for display, and bolds the leading definition
sentence to make scanning easier.

---

## Prerequisites

All review apps require the relevant pipeline targets to have been built first. If the expected queue or lookup file is missing, the app will stop with an informative error pointing to the `tar_make()` call that creates it.
