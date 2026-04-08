# DWR Publication Inventory — Dashboard Specifications

## Overview

A Shiny app dashboard displaying DWR's peer-reviewed publication inventory.
It lives at `shiny/dashboard_app.R` and reads from `data/dwr_publications.parquet`.
All visible counts, charts, and table rows update reactively based on the
user's active filters and search.

---

## Data Source

**File:** `data/dwr_publications.parquet`

Loaded once at startup using `arrow::read_parquet()`. Key columns used:

| Column        | Dashboard use                                          |
|---------------|--------------------------------------------------------|
| `doi`         | Article link construction (`https://doi.org/<doi>`)    |
| `title`       | Article table, featured article                        |
| `year`        | Year filter, Publications by Year chart                |
| `authors`     | First author extraction (first list element)           |
| `affiliations`| Author Affiliation filter (all list elements, flattened) |
| `pc_category` | Science Category pie chart; populated by pipeline join |
| `pc_field`    | Science Field filter                                   |
| `is_funder`   | "Articles Funded" stat; contribution type chart        |
| `is_author`   | "Affiliated Org" stat; contribution type chart         |
| `is_lead_author` | "Lead Authored" stat; contribution type chart       |
| `is_sole_author` | Sole Author contribution type in chart              |
| `journal`     | (reserved; not displayed in initial version)           |

`pc_category` and `pc_field` are both present in the parquet file — no
in-app taxonomy join is needed. Category names are title-cased for display.

**Derived column — `contribution_type`:** Assign the *most specific* single
label per record for use in the stacked bar chart and the Contribution Type
filter. Hierarchy (most → least specific):

| Label         | Condition                                      |
|---------------|------------------------------------------------|
| `Sole Author` | `is_sole_author == TRUE`                       |
| `Lead Author` | `is_lead_author == TRUE & !is_sole_author`     |
| `Co-Author`   | `is_author == TRUE & !is_lead_author`          |
| `Funder`      | `is_funder == TRUE & !is_author`               |

> Note: a record with both `is_funder` and `is_author` is classified under the
> most specific authorship label. Pure funders (no authorship) get `"Funder"`.

**Co-authored stat:** count of records where `is_author == TRUE` but
`is_lead_author == FALSE`.

---

## Layout

```
┌─────────────────────────────────────────────────────────────────────────┐
│  HEADER (full width)                                                    │
├──────────────────────────────────────────────────────────────────────────┤
│  Keyword search bar (left)  │  [Sci. Category btn] [About btn] [Reset] │
├──────────────────────────────────────────────────────────────────────────┤
│  LEFT PANEL (≈40%)          │  RIGHT PANEL (≈60%)                       │
│  ─ Featured Article         │  ─ Filter dropdowns (row)                 │
│  ─ Science Category pie     │  ─ Summary stat boxes (row)               │
│  ─ Articles by Division bar │  ─ Publications by Year stacked bar chart │
│                             │  ─ Article table                          │
└──────────────────────────────────────────────────────────────────────────┘
│  FOOTER (full width)                                                    │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Header

- **Left:** DWR logo (if available) + "CALIFORNIA DEPARTMENT OF WATER RESOURCES"
- **Center:** "PEER-REVIEWED PUBLICATION INVENTORY" + subtitle showing the
  active year range, e.g. `2020–2026`
- **Right:** "CONTACT" label + instruction text +
  `dwrscience@water.ca.gov` as a `mailto:` link

Background: dark navy (`#1a2f4a` or close match). Text: white.

---

## Top Controls Bar

A row directly below the header containing:

### Keyword Search

- Text input (left-aligned, wide)
- Searches across `title`, `abstract`, and `authors` (case-insensitive)
- Filters the reactive dataset immediately on input (debounced ~300 ms)
- Placeholder text: `"Enter keyword search"`

### Action Buttons (right-aligned)

| Button                                   | Behavior                                     |
|------------------------------------------|----------------------------------------------|
| Science Category & Field Classification  | Opens **Classification Modal** (see below)   |
| About the Inventory                      | Opens **About Modal** (see below)            |
| Reset                                    | Clears all filters, search, resets year range to default |

---

## Filters Row (right panel, top)

Four `selectInput` dropdowns in a single row. Each defaults to `"All"`.
Selecting a value filters the reactive dataset.

| Filter             | Source                                                       | Notes                              |
|--------------------|--------------------------------------------------------------|------------------------------------|
| Division           | Placeholder — `"All"` only; disabled or grayed out          | Column not yet in data; see §Placeholder |
| Science Field      | Unique values of `pc_field`, sorted alphabetically          | Displays the field name            |
| Contribution Type  | Fixed: All / Funder / Co-Author / Lead Author / Sole Author | Derived `contribution_type` column |
| Author Affiliation | All unique canonical institution names from `affiliations`, split on `"; "`, `NA` excluded, alphabetically sorted | ~900 options; standard dropdown scroll |

---

## Summary Stat Boxes

A row of five boxes (right panel, below filters). All counts reflect the
currently filtered dataset.

| Box Label         | Value                                                  |
|-------------------|--------------------------------------------------------|
| Total Articles    | `nrow(filtered_data)`                                  |
| Articles Funded   | `sum(is_funder)`                                       |
| Affiliated Org    | `sum(is_author)`                                       |
| Co-Authored       | `sum(is_author & !is_lead_author)`                     |
| Lead Authored     | `sum(is_lead_author)`                                  |

Each box shows a small icon, a large bold number, and a label beneath it.
Style: light card with subtle border; icon color matches the dashboard palette.

---

## Year Range Control

Default year range: **2020–2026**. The control lives **above or beside the
Publications by Year chart** (exact placement to be decided during build).

Implementation: `sliderInput` with `min = 1962`, `max = 2026` (dynamic from
data), `value = c(2020, 2026)`, `step = 1`, `sep = ""`. The subtitle in the
header updates to reflect the selected range.

---

## Charts

### Science Category Pie Chart (left panel)

- Plotly pie chart
- Groups the filtered data by `pc_category`
- Slices labeled with category name + percentage
- Color palette: muted earth tones / teal family consistent with DWR branding
- Title: "Science Category"
- Clicking a slice filters the Science Field dropdown to that category's fields

### Articles by Division Bar Chart (left panel)

- **Placeholder.** The `division` column does not yet exist in the data.
- Display a horizontal bar chart shell with a visible note:
  `"Division data coming soon"` or similar
- Chart title: "Articles by Division"
- When division data is added, bars should be horizontal, sorted descending by
  count, colored in the same palette as other charts

### Publications by Year and Contribution (right panel)

- Plotly stacked bar chart
- X axis: `year` (filtered by year slider)
- Y axis: count of publications
- Stack layers: `Sole Author`, `Lead Author`, `Co-Author`, `Funder`
  (color-coded; consistent legend)
- Total count label displayed above each bar
- Title: "Publications by Year and Contribution"
- Legend below chart, horizontal

---

## Article Table (right panel, bottom)

An interactive `DT::datatable` showing all filtered records.

| Column       | Source                                           | Notes                     |
|--------------|--------------------------------------------------|---------------------------|
| Article Title | `title`                                         | Left-aligned; truncate to ~80 chars with tooltip for full text |
| First Author  | `authors` element [1]                           |                           |
| Science Field | `pc_field`                                      |                           |
| Article Link  | `doi` → `https://doi.org/<doi>`                | Render as "Read >" hyperlink |

- Sorted by `title` ascending by default
- Pagination: 10 rows per page
- Column headers bold
- Search box hidden (global keyword search bar handles search)
- No row numbers displayed

---

## Featured Article (left panel, top)

- Randomly selected from the **unfiltered** full dataset on app load (not
  re-randomized on filter changes)
- Displays: bookmark icon, "FEATURED ARTICLE" label, article title,
  `(year) by [First Author]`, and a "Read Article →" link to
  `https://doi.org/<doi>`
- Card style: light background, subtle left border accent

---

## Modals

Both modals open centered over the dashboard with a semi-transparent overlay.
Closeable via an ✕ button or clicking outside.

### About the Inventory Modal

**Title:** About the Inventory

**Body (placeholder):**
> *[Placeholder] This inventory tracks peer-reviewed publications funded by
> or authored by staff of the California Department of Water Resources (DWR).
> Publications are identified through Scopus searches and classified into
> scientific fields using custom taxonomy and large language model. For
> questions, contact dwrscience@water.ca.gov.*

### Science Category & Field Classification Modal

**Title:** Science Category & Field Classification

**Body (placeholder):**
> *[Placeholder] Publications are classified into scientific fields using a
> custom DWR taxonomy developed in collaboration with subject-matter experts.
> Each field belongs to a broader science category. Classification is performed
> using a large language model guided by structured field definitions.
> See the full taxonomy for detailed field descriptions.*

---

## Footer

Full-width bar at the bottom. Dark background matching header.
Text: `"Dataset updated MM/DD/YYYY"` — hardcoded to the last known
update date for now; update manually when data is refreshed.

---

## Placeholder: Division Data

The Division filter and "Articles by Division" chart both depend on a `division`
column that is not yet present in `data/dwr_publications.csv`. Until it is added:

- The Division dropdown shows only `"All"` and is visually disabled (grayed)
  with a tooltip: `"Division data not yet available"`
- The Articles by Division chart shows a styled placeholder panel with the
  message: `"Division classifications are in progress — check back soon"`

When division data becomes available, add a `division` column to the CSV and
remove the placeholder behavior from both components.

---

## R Packages Required

| Package       | Use                                          |
|---------------|----------------------------------------------|
| `shiny`       | App framework                                |
| `bslib`       | Bootstrap 5 theming                          |
| `plotly`      | Interactive pie and bar charts               |
| `DT`          | Interactive article table                    |
| `dplyr`       | Data manipulation                            |
| `stringr`     | String splitting, case conversion            |
| `readr`       | CSV loading                                  |

---

## Chat Interface (Phase 1)

### Purpose

An LLM-backed chat panel embedded in the dashboard with two capabilities:

1. **Filter-driving** — the user describes a slice of the data in natural language
   ("show me hydrology papers from 2018 to 2022 where DWR was lead author") and
   the LLM updates the existing Shiny filter controls to match.
2. **Literature synthesis** — the user asks for a summary or synthesis of the
   currently visible papers ("what are the main themes in these abstracts?") and
   the LLM reads the filtered abstracts and responds.

Both capabilities are served through a single `shinychat` panel; the user does
not need to switch tools or modes.

---

### LLM Backend

**Package stack:** `shinychat` (chat UI + streaming) + `ellmer` (LLM client).

**Provider:** The same OpenAI-compatible endpoint used by the `pubclassify`
pipeline (California Department of Technology, base URL
`PUBCLASSIFY_LLM_BASE_URL`). `ellmer::chat_openai()` with a custom `base_url`
and `api_key = Sys.getenv("PUBCLASSIFY_LLM_KEY")`.

If that endpoint is unavailable or a higher-capability model is needed,
`ellmer::chat_anthropic()` can be substituted — the tool-call and streaming
interfaces are identical across providers in `ellmer`.

---

### Do We Need RAG / Embeddings?

**Short answer: No, not for Phase 1.** Here is the analysis:

#### Full corpus token budget

| Scope | Papers | Approx. tokens |
|---|---|---|
| Entire dataset | 1,402 | ~569K |
| Default view (2020–2026) | ~708 | ~300K |
| Largest single field (fisheries biology) | 198 | ~85K |
| Typical filtered view (one field + year band) | 30–100 | ~12–40K |

Claude's usable context window is ~190K tokens after accounting for system
prompt and response space. This means:

- **Typical filtered subsets fit easily.** A single science field, a
  contribution type, a short year range — these produce 30–200 papers, well
  within context.
- **Large subsets do not fit.** The default 2020–2026 view (~300K tokens) and
  the full corpus (~569K tokens) exceed the window.

#### Strategy: stuffing with a synthesis gate

For the synthesis tool, check the token budget of the current filtered set
before calling the LLM:

- **≤ 300 papers** (roughly ≤ 120K tokens): stuff all titles and abstracts
  directly into the prompt. Single LLM call.
- **> 300 papers**: decline synthesis and prompt the user to apply additional
  filters first. Display a message such as: *"There are N papers in the current
  view — too many to synthesize at once. Try narrowing by Science Field,
  Contribution Type, or year range first."*

This gate keeps the implementation simple and avoids a more complex
map-reduce pipeline for Phase 1. The 300-paper threshold can be tuned.

#### Why not map-reduce?

Map-reduce (batch abstracts into groups of ~100, summarize each batch,
then meta-summarize) is more faithful than RAG for a "summarize everything
visible" task, but it multiplies LLM calls and latency. Given that filtered
views are typically small, the simpler gate is sufficient. Map-reduce is a
reasonable Phase 2 improvement if users frequently hit the limit.

#### Why not RAG / embeddings (ragnar)?

RAG with embeddings would enable a third use case not in Phase 1: **discovery
without pre-filtering** — e.g., "find papers related to SGMA and groundwater
banking" across the full corpus. For the two Phase 1 use cases (filter-driving
and filtered-set synthesis), embeddings add no value:

- Filter-driving needs no abstract content at all — just schema metadata and
  the available filter values.
- Synthesis is bounded by the user's existing Shiny filters, not by semantic
  retrieval.

The `ragnar` package (uses DuckDB for the vector store; produces embeddings
via a configurable provider) is the natural choice if a discovery use case
is added. Embeddings would be computed once at pipeline time and stored
alongside the parquet file. See **Phase 2** below.

---

### Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  shinychat panel (collapsible sidebar)                       │
│                                                              │
│  User message ──► ellmer chat object ──► LLM               │
│                           │                                  │
│                    tool calls (R functions)                  │
│                     ┌─────┴──────┐                           │
│              set_filters()   synthesize_selection()          │
│                     │              │                         │
│           updateSelectInput()  filtered() abstracts          │
│           updateSliderInput()  stuffed into next LLM call    │
│           (updates Shiny state)                              │
└──────────────────────────────────────────────────────────────┘
```

The `ellmer` chat object is created once per session with tool definitions
registered. `shinychat` handles streaming the response text into the chat panel.

---

### Tools

#### `set_filters`

Updates the existing Shiny dashboard filter controls programmatically so the
main dashboard (charts, stat boxes, table) reacts as if the user had changed
the dropdowns manually.

**Parameters:**

| Parameter | Type | Description |
|---|---|---|
| `year_start` | integer (optional) | Start of year range |
| `year_end` | integer (optional) | End of year range |
| `science_field` | string (optional) | One of the `pc_field` values, or `"All"` |
| `contribution_type` | string (optional) | One of `Funder`, `Co-Author`, `Lead Author`, `Sole Author`, or `"All"` |
| `affiliation` | string (optional) | One of the canonical institution names, or `"All"` |

All parameters are optional; only supplied ones are updated. Implemented via
`updateSliderInput()` / `updateSelectInput()` inside `session`.

The tool returns a plain-text confirmation of what was changed, e.g.:
*"Filters updated: Science Field → hydrology, Year → 2015–2022."*

#### `synthesize_selection`

Synthesizes the abstracts of the currently filtered publications into a
narrative summary.

**Parameters:** none — operates on the current `filtered()` reactive.

**Behavior:**
1. Check filtered row count. If > 300, return the synthesis gate message
   instead of calling the LLM again.
2. Build a prompt containing: the list of titles and abstracts, plus the user's
   request text.
3. Stream the response back through `shinychat`.

The tool does **not** make a separate LLM call — it assembles the abstract
content and returns it to the chat model as tool output, which the model then
synthesizes in its own response turn. This keeps the conversation coherent.

---

### System Prompt

The system prompt is set once when the `ellmer` chat object is initialised.
It should convey:

1. **Role:** The assistant helps users explore the DWR Peer-Reviewed
   Publication Inventory dashboard.
2. **Available filters:** List the current valid values for each filter
   (science fields, contribution types, year range, top-N affiliations)
   so the LLM can map user language to valid filter values without guessing.
3. **Tool guidance:** Prefer `set_filters` for navigation requests and
   `synthesize_selection` for summarization requests. Clarify if the user's
   intent is ambiguous.
4. **Tone:** Professional, concise, suited to a government science context.

Valid filter values are injected into the system prompt at app startup (not
hardcoded in the source file), so the prompt stays accurate if the data
is updated.

---

### UI Layout

The chat panel is a **collapsible right sidebar** added alongside the existing
two-column layout. A toggle button in the controls bar opens and closes it.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  HEADER                                                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│  [Keyword search]  [Sci. Category] [About] [Reset]  [Ask the data ✦]       │
├──────────────────────────────┬──────────────────────┬───────────────────────┤
│  LEFT (charts)               │  RIGHT (filters +    │  CHAT SIDEBAR         │
│                              │  table)              │  (collapsible)        │
│                              │                      │  ─ Chat history       │
│                              │                      │  ─ Text input         │
│                              │                      │  ─ Send button        │
└──────────────────────────────┴──────────────────────┴───────────────────────┘
```

When the sidebar is collapsed, the left/right panels expand to fill the full
width (restoring the current layout). The toggle button label is
**"Ask the data ✦"** when collapsed and **"Close chat"** when open.

The chat panel width is approximately 340px (fixed). Existing column widths
compress proportionally.

---

### Phase 2: Discovery with ragnar (deferred)

The `ragnar` package provides a straightforward path to adding a third chat
capability: **semantic discovery** — finding papers across the full corpus
without requiring the user to pre-filter.

**Architecture:**
- At pipeline time (`_targets.R`), build an embedding store for all abstracts
  using `ragnar::ragnar_store_create()`. Store the resulting DuckDB file at
  `data/pub_embeddings.duckdb`.
- At chat runtime, when the user's intent is discovery rather than synthesis
  of the current view, retrieve the top-K most relevant abstracts using
  `ragnar::ragnar_retrieve()` and pass them to the LLM.
- A third tool `retrieve_relevant_papers` would be registered alongside
  `set_filters` and `synthesize_selection`.

**When this becomes worthwhile:** if users regularly ask questions that span
the full corpus and cannot easily be reduced to the existing filter dimensions
(e.g., cross-field thematic questions, questions about specific geographic
areas or waterbodies not captured by existing filters).

---

## File Location

```
shiny/
  funder_review_app.R   # existing
  dashboard_app.R       # new — the inventory dashboard
```

Launch from the project root with:

```r
shiny::runApp("shiny/dashboard_app.R")
```
