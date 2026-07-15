# DWR Publication Inventory — Dashboard Reference

Design and behavior reference for the dashboard applications. Both
`shiny/dashboard_app_internal.R` and `shiny/dashboard_app_external.R` provide
the same four tabs (Dashboard, Institution Map, Publishing Network, Science
Fields) and shared publication-browsing behavior. This document details the
internal dashboard's division and chat features; those features are not present
in the public dashboard. For the pipeline architecture, see
[`docs/ARCHITECTURE.md`](ARCHITECTURE.md).

## Overview

Two Shiny apps display DWR's peer-reviewed publication inventory:

- `shiny/dashboard_app_internal.R` is for DWR staff. It includes DWR division
  information and the LLM chat assistant.
- `shiny/dashboard_app_external.R` is for public viewing. It has the same core
  browsing, chart, map, network, and science-fields functionality, but does not
  expose DWR division information or the LLM chat assistant.

Both read from `data/generated/dwr_publications.parquet` and
`data/lookups/institution_geo_lookup.csv`, loaded once at startup. All visible
counts, charts, and table rows update reactively based on the user's active
filters.

---

## Data Source

**File:** `data/generated/dwr_publications.parquet`

Loaded once at startup using `arrow::read_parquet()`. Key columns used:

| Column        | Dashboard use                                          |
|---------------|--------------------------------------------------------|
| `doi`         | Article link construction (`https://doi.org/<doi>`)    |
| `title`       | Article table, featured article                        |
| `year`        | Year filter, Publications by Year chart                |
| `authors`     | First author extraction (first list element)           |
| `affiliations`| Author Affiliation filter (all list elements, flattened) |
| `pc_category` | Science Category pie chart; populated by pipeline join |
| `pc_field`    | Science Field filter; article table display           |
| `is_funder`   | "Articles Funded" stat; contribution type chart        |
| `is_author`   | "Affiliated Org" stat; contribution type chart         |
| `is_lead_author` | "Lead Authored" stat; contribution type chart       |
| `is_sole_author` | Sole Author contribution type in chart              |
| `journal`     | (reserved; not displayed in initial version)           |
| `funding_division` | Internal dashboard: Division filter and Articles by Division chart |
| `author_division` | Internal dashboard: Division filter and Articles by Division chart |

`pc_category` and `pc_field` are both present in the parquet file — no
in-app taxonomy join is needed. Category names are title-cased for display.

The Science Fields tab separately reads `taxonomy/dwr_disciplines_taxonomy.csv`
at startup to display the current taxonomy definitions used by the classifier.

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
├─────────────────────────────────────────────────────────────────────────┤
│  Keyword search bar (left)  │  [Sci. Category btn] [About btn] [Reset]  │
├─────────────────────────────────────────────────────────────────────────┤
│  LEFT PANEL (≈40%)          │  RIGHT PANEL (≈60%)                       │
│  ─ Featured Article         │  ─ Filter dropdowns (row)                 │
│  ─ Science Category pie     │  ─ Summary stat boxes (row)               │
│  ─ Articles by Division     │  ─ Publications by Year stacked bar chart │
│                             │  ─ Article table                          │
└─────────────────────────────────────────────────────────────────────────┘
│  FOOTER (full width)                                                    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Header

- **Left:** DWR logo (if available) + "CALIFORNIA DEPARTMENT OF WATER RESOURCES"
- **Center:** "PEER-REVIEWED PUBLICATION INVENTORY" + subtitle showing the
  active year range, e.g. `2020-2026`
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

Four active `selectInput` dropdowns are displayed in a single row.

| Filter             | Source                                                       | Notes                              |
|--------------------|--------------------------------------------------------------|------------------------------------|
| Division           | Unique non-blank values from `author_division` and `funding_division`, excluding `Unknown` | Matches semicolon-delimited author divisions or the funding division |
| Science Field      | Unique values of `pc_field`, sorted alphabetically          | Displays the field name            |
| Contribution Type  | Fixed: All / Funder / Co-Author / Lead Author / Sole Author | Derived `contribution_type` column |
| Author Affiliation | All unique non-empty values from the `affiliations` list column | Standard dropdown scroll |

---

## Summary Stat Boxes

A row of five boxes (right panel, below filters). All counts reflect the
currently filtered dataset.

| Box Label         | Value                                                  |
|-------------------|--------------------------------------------------------|
| Total Articles    | `nrow(filtered_data)`                                  |
| Articles Funded   | `sum(is_funder)`                                       |
| Affiliated Orgs   | `sum(is_author)`                                       |
| Co-Authored       | `sum(is_author & !is_lead_author)`                     |
| Lead Authored     | `sum(is_lead_author)`                                  |

Each box shows a small icon, a large bold number, and a label beneath it.
Style: light card with subtle border; icon color matches the dashboard palette.

---

## Year Range Control

Default year range: **2020-2026**, clipped to the dataset's actual minimum and
maximum years. The control lives inside the **Publications by Year and
Contribution** card, directly above the chart.

Implementation: `sliderInput` with dynamic `min = year_min`,
`max = year_max`, `value = YEAR_DEFAULT`, `step = 1`, and `sep = ""`. The
subtitle in the header updates to reflect the selected range.

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

- Plotly horizontal stacked bar chart.
- Counts unique `(record_key, division)` pairs from both `author_division` and
  `funding_division`.
- Multi-valued `author_division` strings are split on `;`; `Unknown` and blank
  values are excluded.
- Bars are stacked by contribution type using the same colors as the year chart.
- Clicking a division bar toggles the Division dropdown to that division; clicking
  it again clears the filter.
- If the current selection has no division data, the chart displays
  `"No division data for selection"`.

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

- No default sort order (`ordering = FALSE`)
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
Closeable via an ✕ button or clicking outside. Modal body text is loaded from
Markdown files in `shiny/content/` — edit those files to update copy without
touching the app script.

### About the Inventory Modal

**Title:** About the Inventory

**Body:** Loaded from `shiny/content/about.md`. Describes the inventory's
purpose, Scopus coverage, classification approach, and refresh cadence.

### Science Category & Field Classification Modal

**Title:** Science Category & Field Classification

**Body:** Loaded from `shiny/content/classification.md`. Brief overview of the
taxonomy and LLM classification process, with a pointer to the Science Fields
tab for the full field definitions.

---

## Footer

Full-width bar at the bottom. Dark background matching header.
Text: `"Dataset updated MM/DD/YYYY"`. The date is read from the latest
non-empty `completed_at` value in `data/refresh_log.csv` at startup. If the
refresh log cannot be read, the app falls back to `12/10/2025`.

---

## Division Data (Internal Dashboard Only)

The pipeline can add `funding_division` and `author_division` to
`data/generated/dwr_publications.csv` and `data/generated/dwr_publications.parquet`.

`data/lookups/funding_division_lookup.csv` is a manual lookup for funder-query
records that explicitly passed funding review (`decision == "keep"`). Records
marked `drop` or `unsure` are excluded from the lookup. The lookup stores the
manual assignment in a `division` column; exports expose that value as
`funding_division`. Newly accepted current-refresh rows are prepended, and
`new == TRUE` means the row still needs a funding division assignment from the
current refresh.

`data/decisions/author_division_decisions.csv` stores confirmed DWR authors and
resolved division assignments. Exports expose those values as `author_division`.

Blank `funding_division` values mean the record passed funding review but still
needs a division assignment.

The internal dashboard uses both division columns for the Division filter and
the Articles by Division chart. Author divisions can be multi-valued; funding
division is a single value per record. The public dashboard does not display
these fields or division-derived controls and charts.

---

## R Packages Required

| Package       | Use                                          |
|---------------|----------------------------------------------|
| `shiny`       | App framework                                |
| `bslib`       | Bootstrap 5 theming                          |
| `plotly`      | Interactive pie and bar charts               |
| `DT`          | Interactive article table                    |
| `dplyr`       | Data manipulation                            |
| `arrow`       | Parquet loading                              |
| `stringr`     | String splitting, case conversion            |
| `shinychat`   | Chat UI                                      |
| `ellmer`      | LLM client and tool calling                  |
| `glue`        | Chat system prompt template interpolation    |
| `leaflet`     | Institution Map rendering                    |
| `rnaturalearth` | Country and US state polygon geometries    |
| `rnaturalearthdata` | Natural earth dataset for map polygons |
| `rnaturalearthhires` | High-res natural earth dataset        |
| `sf`          | Spatial data handling                        |
| `visNetwork`  | Publishing Network rendering                 |

---

## Chat Interface (Internal Dashboard Only)

### Purpose

An LLM-backed chat panel embedded in the dashboard with several capabilities:

1. **Filter-driving** — the user describes a slice of the data in natural language
   ("show me hydrology papers from 2018 to 2022 where DWR was lead author") and
   the LLM updates the existing Shiny filter controls to match.
2. **Inventory search and pinning** — the user searches the full inventory, then
   can pin the dashboard to specific matching papers.
3. **Breakdowns, trends, and comparisons** — the assistant can return frequency
   tables, year-by-year trends, and before/after comparisons for the current view.
4. **Paper detail, citations, authors, and collaborations** — the assistant can
   retrieve paper metadata, format citations, rank authors, and summarize common
   collaborating institutions.
5. **Literature synthesis** — the user asks for a summary or synthesis of the
   currently visible papers ("what are the main themes in these abstracts?") and
   the LLM reads the filtered abstracts and responds.

Both capabilities are served through a single `shinychat` panel; the user does
not need to switch tools or modes.

---

### LLM Backend

**Package stack:** `shinychat` (chat UI + streaming) + `ellmer` (LLM client).

**Provider:** The same OpenAI-compatible endpoint used by the `pubclassify`
pipeline (California Department of Technology). The app uses
`ellmer::chat_openai_compatible()` with `base_url` read from
`pipeline_config$llm$base_url` (set in `config/pipeline.yml`) and
`api_key = Sys.getenv("PUBCLASSIFY_LLM_KEY")`.

If that endpoint is unavailable or a higher-capability model is needed,
`ellmer::chat_anthropic()` can be substituted — the tool-call and streaming
interfaces are identical across providers in `ellmer`.

The `synthesize_selection` tool stuffs titles and abstracts directly into the
prompt for filtered views ≤ 300 papers; it declines and asks the user to narrow
filters further for larger views. Typical filtered subsets (single field +
year band) are 30–200 papers and fit easily. The 300-paper cap can be tuned.

---

### Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  shinychat panel (collapsible sidebar)                       │
│                                                              │
│  User message ──► ellmer chat object ──► LLM                 │
│                             │                                │
│                    tool calls (R functions)                  │
│          filters/search/counts/trends/details/citations      │
│                             │                                │
│           Shiny inputs, filtered data, or formatted output   │
└──────────────────────────────────────────────────────────────┘
```

The `ellmer` chat object is created once per session with tool definitions
registered. `shinychat` handles streaming the response text into the chat panel.

---

### Tools

The assistant registers twelve tools:

- `set_filters`
- `reset_filters`
- `count_by`
- `get_trend`
- `compare_periods`
- `find_papers`
- `filter_to_papers`
- `get_paper_detail`
- `synthesize_selection`
- `get_author_stats`
- `get_collaboration_stats`
- `cite_papers`

#### `set_filters`

Updates the existing Shiny dashboard filter controls programmatically so the
main dashboard (charts, stat boxes, table) reacts as if the user had changed
the dropdowns manually.

**Parameters:**

| Parameter | Type | Description |
|---|---|---|
| `keyword` | string (optional) | Free-text search over title, abstract, and authors, or `"All"` to clear |
| `year_start` | integer (optional) | Start of year range |
| `year_end` | integer (optional) | End of year range |
| `science_category` | string (optional) | One of the title-cased science category values, or `"All"` |
| `science_field` | string (optional) | One of the `pc_field` values, or `"All"` |
| `division` | string (optional) | One of the dashboard division values, or `"All"` |
| `contribution_type` | string (optional) | One of `Funder`, `Co-Author`, `Lead Author`, `Sole Author`, or `"All"` |
| `affiliation` | string (optional) | One of the canonical institution names, or `"All"` |

All parameters are optional; only supplied ones are updated. Implemented via
`updateSliderInput()` / `updateSelectInput()` inside `session`.

The tool returns a plain-text confirmation of what was changed, e.g.:
*"Filters updated: Science Field → hydrology, Year → 2015-2022."*

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
It covers:

1. **Role:** The assistant helps users explore the DWR Peer-Reviewed
   Publication Inventory dashboard.
2. **Available filters:** List the current valid values for each filter
   (science categories, science fields, divisions, contribution types, year range,
   and top-N affiliations)
   so the LLM can map user language to valid filter values without guessing.
3. **Tool guidance:** Prefer `set_filters` for navigation requests and
   `synthesize_selection` for summarization requests. Clarify if the user's
   intent is ambiguous.
4. **Tone:** Professional, concise, suited to a government science context.

The system prompt template lives in `prompts/chat_system_prompt.txt` and is
loaded at app startup via `glue::glue()`. Valid filter values (year range,
categories, fields, divisions, affiliations) are interpolated from live data
at load time, so the prompt stays accurate as the inventory grows without
manual edits to the template.

---

### UI Layout

The chat panel is a **collapsible right sidebar** added alongside the existing
two-column layout. A toggle button in the controls bar opens and closes it.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  HEADER                                                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│  [Keyword search]  [Sci. Category] [About] [Reset]  [Ask the data ✦]        │
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

---

# Institution Map Page

## Overview

A second tab in the dashboard app showing a choropleth map of co-author
affiliated institutions by geography. The page has its own independent filter
controls and does not share reactive state with the Dashboard tab.

---

## Tab Structure

The app uses `tabsetPanel` inside `fluidPage`. The shared header and footer
are outer `div`s that span all tabs. Each tab has its own independent controls
and reactive state:

```
fluidPage(
  header div (shared)
  tabsetPanel(
    tabPanel("Dashboard",      controls bar + left/right/chat layout)
    tabPanel("Institution Map", map controls bar + leaflet map)
    tabPanel("Publishing Network", network controls bar + visNetwork)
    tabPanel("Science Fields", taxonomy table)
  )
  footer div (shared)
)
```

---

## Data Sources for the Map

Two geo lookups are loaded once at app startup alongside the publications
parquet.

### Country-level counts

The publications parquet contains `affiliation_countries`, a list column where
each element is a character vector of country names for all author affiliations
on that paper. This is unnested at render time to produce a count of distinct
papers per country.

**Count rule:** A paper with authors from France and Germany contributes 1 to
France and 1 to Germany — it is **not** double-counted within a single country
even if multiple authors share that country.

### US state-level counts

`data/lookups/institution_geo_lookup.csv` (columns: `canonical`, `country`,
`state`, `resolved`) is joined to the `affiliations` list column. The join key
is the canonical institution name.

For each paper, iterate over its affiliations. For each affiliation:

- If `country == "United States"` and `state` is not `NA`: contribute 1 to
  that state (deduplicated per paper per state).
- If `country == "United States"` and `state` is `NA`: contribute 1 to the
  **National / Unassigned** bucket (deduplicated per paper).

Affiliations not present in the geo lookup (or with `resolved == FALSE`) are
excluded from state-level counts. They still contribute to country-level counts
via `affiliation_countries`.

### Startup pre-computation

At app startup, compute two baseline data frames from the full unfiltered
`pubs`:

- `geo_country_base` — one row per `(record_key, country)` pair.
- `geo_inst_base` — one row per `(record_key, canonical, country, state)` pair.

`geo_inst_base` is used for US state counts, national-scope US counts, and
top-institution popup lists. These startup tables are filtered reactively by
year range and contribution type; no geo lookup re-join is needed on each
render.

---

## Map Controls (Independent of Dashboard Tab)

A compact controls bar above the map:

| Control | Type | Default | Notes |
|---|---|---|---|
| Year Range | `sliderInput` | 2020–2026 | Same `min`/`max` as main dashboard |
| Contribution Type | `selectInput` | All | All / Sole Author / Lead Author / Co-Author / Funder |
| Reset View | `actionButton` | — | Flies the map back to the initial world extent |

Changing these controls updates the map choropleth only. They have no effect on
the Dashboard tab.

---

## Map Rendering

**Library:** `leaflet` (R package). Leaflet is preferred over Plotly for this
page because it supports true pan/zoom, tile layer backgrounds, and per-feature
popups more naturally than Plotly choropleths.

**Base tiles:** Esri World Gray Canvas (`"Esri.WorldGrayCanvas"`) — clean, light
grey, English-only labels. CartoDB Positron was the original choice but renders
continent labels in regional languages; Esri World Gray Canvas is equivalent in
style and uses English throughout.

### Polygon Data

Loaded once at startup:

```r
world_sf  <- rnaturalearth::ne_countries(scale = "medium", returnclass = "sf")
states_sf <- rnaturalearth::ne_states(country = "United States of America",
                                       returnclass = "sf")
```

The US polygon in `world_sf` is excluded from the countries layer to prevent
overlap with the state polygons. Filter by `iso_a3 != "USA"` before rendering.

### Color Palette

Sequential green palette (`"#eef7eb"` pale mint at low end → `"#0b3f09"` deep
forest green at high end). Countries/states with zero publications are shown in
white (`"#ffffff"`) so they are visually distinct from the grey ocean/basemap.

**Scale:** `log1p`-transformed domain (`colorNumeric` applied to `log1p(count)`).
California will dominate the raw count, so a linear scale would leave most
countries and states compressed into near-identical pale shades. The log
transform compresses the high end and stretches the low end, making the
geographic spread of collaboration visible at a glance. Raw publication counts
(not log values) are always displayed in hover labels, popups, and the legend.

**Domain:** The palette domain runs from `log1p(1)` to `max(log1p(all counts))`,
so zero-publication polygons map to `NA` and receive the `na.color` (white) rather
than the lightest green. This creates three clearly distinct visual categories:
grey ocean, white countries/states with no publications, and green countries/states
with one or more publications.

**Shared domain across both layers:** The world layer and the US state layer
use the same `log1p` palette (same min/max drawn from all countries + all
states in the current filter). This keeps California and other countries
directly comparable — a viewer can see at a glance that California is darker
than, say, Australia — without maintaining two separate scales to explain.

**Legend labels:** Because the legend maps log-scale colors to actual counts,
label the legend at meaningful raw-count breakpoints (e.g., 1, 5, 10, 50, 100,
500) rather than evenly spaced log values. Use `addLegend()` with manual
`labels` and `colors` derived from the palette at those breakpoints. The first
swatch is white, labeled "0", to represent the zero-publication category.

### Layers

1. **World countries layer** — polygons from `world_sf` (US excluded), filled
   by publication count. Countries with no data in the current filter are white.
2. **US states layer** — polygons from `states_sf`, filled by publication count
   using the **same palette domain** as the world layer.

Both layers are rendered as `leaflet::addPolygons()`. The state layer is added
second so it renders on top of any world-layer tile at the US extent.

### Initial View

```r
leaflet() |> setView(lng = 10, lat = 20, zoom = 2)
```

---

## Hover and Click Behavior

### Hover tooltip

Every polygon (country and state) shows a brief `label` on hover:

- Country/state name
- Publication count, or "No publications" if zero

Example: `"France — 23 pubs"` / `"Wyoming — No publications"`

The label is a plain HTML string; no institution list. Tooltips use
`labelOptions(style = list("font-size" = "0.82rem"))` to match dashboard type scale.

### Click popup

Clicking any polygon opens a `popup` with the full detail:

- Country/state name (bold)
- Publication count under current filters
- Top 5 institutions in that country/state by count, each on its own line
  with its count (e.g., "UC Davis — 12")
- If no publications: "No publications in the current selection."

Popups are HTML-formatted strings built in the server (`sprintf`/`paste0`);
no external popup package required.

### Non-US country click

Popup scoped to the clicked country using `geo_inst_base` to retrieve
institution names for that country.

### US state click

Same popup format, scoped to the clicked state using `geo_inst_base`.

### Notes below the map

Two conditional text notes are displayed in a compact bar directly below the
map. Both use the `map-notes-bar` / `map-note-item` styles.

**National-scope US institutions** (shown when N > 0):

> N publication(s) involve US national-scope institutions (e.g., federal agencies
> without a single-state footprint) and are not attributed to any state on the
> map. Top: [up to 3 institution names].

**Publications without geo data** (shown when M > 0):

> M publication(s) have no affiliated institution geo data and are not shown on
> the map.

"No geo data" means the paper's `affiliation_countries` is empty/NA for all
affiliations. Affiliations absent from the geo lookup are excluded from
state-level counts and institution popup lists, but can still contribute to
country-level counts through `affiliation_countries`. Both notes are computed
from the reactive filtered data and update with filter changes. Hide each note
independently when its count is zero.

---

## Layout

```
┌────────────────────────────────────────────────────────────────────────┐
│  HEADER (shared, full-width)                                           │
├────────────────────────────────────────────────────────────────────────┤
│  [Dashboard]  [Institution Map]  [Publishing Network]  [Science Fields]│
├────────────────────────────────────────────────────────────────────────┤
│  [Year ────────────────○─○──]  [Contribution Type ▼]  [Reset View]     │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                  Leaflet choropleth map                         │   │
│  │  (world countries + US states; pan/zoom enabled)                │   │
│  │                                        [Legend: 0 ──── N pubs]  │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                        │
│  National-scope US institutions note (conditional)                     │
└────────────────────────────────────────────────────────────────────────┘
│  FOOTER (shared, full-width)                                           │
└────────────────────────────────────────────────────────────────────────┘
```

Map height: `calc(100vh - 300px)` so it fills the viewport. The controls bar
and note are compact (no scrolling needed).

---

## Legend

A Leaflet legend (`addLegend()`) anchored bottom-right. It shows a white swatch
for `0`, followed by green swatches at meaningful raw-count breakpoints
(`1`, `5`, `10`, `50`, `100`, `500`, capped at the current maximum). Labels are
actual publication counts, not log values. Title: "Publications".

---

## Design Decisions

1. **Tab styling** — The tab bar uses a white background with DWR dark-navy text
   and teal active/hover underlines. CSS targets `.nav-tabs .nav-link` and
   `.nav-tabs .nav-link.active`. The tab bar sits between the shared header and
   the tab content, flush with the header bottom border.

2. **Palette: green, log scale, shared domain** — Sequential green
   `log1p`-transformed `colorNumeric` palette, shared across world countries and
   US states. Zero-publication polygons map to white (`na.color = "#ffffff"`) so
   they are clearly distinct from the grey basemap ocean. The log compression
   ensures meaningful color variation across countries and states with smaller
   counts. Raw counts are always shown in labels, popups, and legend ticks.

3. **Missing geo data note** — A conditional note below the map reports M
   publications with no geographic data. These are excluded from the map silently
   without this note, which would be misleading. Definition of "no geo data":
   `affiliation_countries` is empty/NA for all affiliations, or all affiliations
   are absent from the geo lookup.

4. **Hover + click** — Brief `label` on hover (name + count only); full
   institution list in a `popup` on click. This avoids institution lists
   cluttering the hover experience when panning across many polygons.

---

## R Packages (Institution Map)

| Package | Use |
|---|---|
| `leaflet` | Interactive map rendering and polygon layers |
| `rnaturalearth` | Country and US state polygon geometries |
| `sf` | Spatial data frame join and handling |

---

---

# Publishing Network Tab

## Overview

A third tab in the dashboard showing an interactive co-authorship network. The
user can toggle between two network modes:

- **Institutions** — nodes are organizations; edges connect institutions that
  appear together on the same paper.
- **People** — nodes are individual authors; edges connect authors who
  co-authored a paper.

A year range, contribution type, and science field filter control which papers
feed the network. The tab is independent of the other tabs.

---

## Data Sources

### DWR canonical affiliation

The anchor institution node is `"California Department of Water Resources"` —
the single canonical string that appears in the `affiliations` list column for
DWR-authored records. It is stored as the constant `.DWR_NODE`. Other state
water agencies (Idaho, Arizona, etc.) are not merged into this node.

### DWR author set

`data/decisions/author_division_decisions.csv` contains confirmed DWR authors
with a `decision == "dwr"` column. At startup, build `dwr_author_names` as the
unique `author_name` values where `decision == "dwr"`. Used at render time to
color DWR staff nodes differently in People mode.

### Institution network base table

Computed once at startup from the full unfiltered `pubs`.

For each paper `i`:
1. Unnest `affiliations[[i]]`; deduplicate within the paper.
2. Generate all unique unordered pairs `(inst_a, inst_b)` with `inst_a < inst_b`
   (alphabetical tie-breaking to avoid duplicate reversed pairs).
3. Emit one row per pair: `(record_key, inst_a, inst_b, year,
   contribution_type)`.

Result: `network_inst_base`. No DWR injection for funder-only records — if
`"California Department of Water Resources"` does not appear naturally in
`affiliations[[i]]` (e.g., for funder papers where DWR was not an author), it
is not added. This means the DWR anchor node has no edges for pure-funder
papers, which is correct: DWR funded that research but did not co-author it.

### People network base table

For each paper `i`:
1. Unnest `authors[[i]]`; deduplicate within the paper.
2. Generate all unique unordered pairs `(author_a, author_b)` with `author_a <
   author_b`.
3. Emit one row per pair: `(record_key, author_a, author_b, year,
   contribution_type)`.

Result: `network_author_base`.

---

## Controls (Independent of Other Tabs)

A compact controls bar above the network:

| Control | Type | Default | Notes |
|---|---|---|---|
| Year Range | `sliderInput` | 2020–2026 | Same min/max as Dashboard and Map tabs |
| Contribution Type | `selectInput` | All | All / Sole Author / Lead Author / Co-Author / Funder |
| Science Field | `selectInput` | All | Same field list as Dashboard tab |
| Network Mode | `radioButtons` | Institutions | Institutions / People; switches node/edge source table |
| Top N Nodes | `sliderInput` | 25 | Range 5–100; step 5 |
| Reset View | `actionButton` | — | Resets all controls to defaults |

Changing any control triggers a full network recompute and re-render.

---

## Network Construction (Reactive)

On filter or mode change:

1. **Filter base table** — Filter `network_inst_base` (or `network_author_base`
   in People mode) by year range, contribution type, and science field.
2. **Aggregate edges** — Group by `(node_a, node_b)`; count distinct
   `record_key` values → `n_papers` (the number of papers on which the pair
   co-occurred). This is the edge weight.
3. **Build node list** — Collect all unique nodes from the edge list. Compute
   each node's degree (number of distinct neighbors in the current edge set).
4. **Apply Top N** — Rank nodes by degree descending; retain the top N. In
   Institutions mode, retain `.DWR_NODE` regardless of rank when it appears in
   the filtered degree table. Discard edges where either endpoint is not in the
   retained set.
5. **Render with `visNetwork`** — Build `nodes` and `edges` data frames and
   render the graph with `visNetwork::renderVisNetwork()`. When the user
   navigates to the Publishing Network tab, `visNetworkProxy()` calls `visFit()`
   to re-fit the graph in the visible viewport.

**Edge width:** `1 + log1p(n_papers) * 2` — thin for 1 shared paper, clearly
thicker at 10+.

**Node size:** `pmax(12, 8 + log1p(paper_count) * 4.5)` where `paper_count` is
the number of distinct papers in the current filtered view that involve that
node. Sized by papers (not degree) so visual prominence tracks publication
volume. The DWR anchor node uses a minimum size of `42` and a fixed position
at `x = 0, y = 0`.

---

## Node Styling

### Institutions mode

| Node type | Fill | Font color | Fixed? |
|---|---|---|---|
| DWR (`"California Department of Water Resources"`) | `#1a2f4a` | white | Yes — `x = 0, y = 0` |
| US institution | `#4da87a` (green) | `#1a2f4a` | No |
| International institution | `#4a9cad` (teal) | `#1a2f4a` | No |
| Unknown / unresolved | `#aaaaaa` | `#1a2f4a` | No |

Country classification uses `institution_geo_lookup.csv` (the same lookup
already loaded at startup for the map tab). Institutions absent from the lookup
default to "Unknown."

Label shown: institution name, truncated to ~30 characters.

### People mode

| Node type | Fill | Font color |
|---|---|---|
| DWR author (in `dwr_author_names`) | `#1a2f4a` | white |
| External author | `#4da87a` | `#1a2f4a` |

Label shown: author name as stored (`"Last F."` format).

---

## Edge Styling

```
color:        list(color = "#cccccc", highlight = "#4da87a", opacity = 0.85)
smooth:       FALSE   # improves performance for large graphs
```

Hover tooltip on an edge (`title`): `"N paper(s)"` where N = `n_papers`.

---

## visNetwork Configuration

```r
visNetwork(nodes, edges) |>
  visPhysics(
    solver = "forceAtlas2Based",
    forceAtlas2Based = list(
      gravitationalConstant = -120,
      centralGravity        = 0.005,
      springConstant        = 0.06,
      springLength          = 250,
      damping               = 0.4
    ),
    stabilization = list(enabled = TRUE, iterations = 300, fit = TRUE),
    timestep = 0.35
  ) |>
  visInteraction(
    dragNodes         = TRUE,
    zoomView          = TRUE,
    navigationButtons = TRUE,
    hover             = TRUE
  ) |>
  visOptions(
    highlightNearest = list(enabled = TRUE, degree = 1, hover = TRUE)
  ) |>
  visEvents(click = "function(params) {
    if (params.nodes.length > 0) {
      Shiny.setInputValue('net_node_click',
        {node: params.nodes[0], nonce: Math.random()}, {priority: 'event'});
    } else if (params.edges.length > 0) {
      Shiny.setInputValue('net_edge_click',
        {edge: params.edges[0], nonce: Math.random()}, {priority: 'event'});
    }
  }") |>
  visLegend(useGroups = FALSE, position = "right", width = 0.24, ncol = 1,
            addNodes = <mode-dependent legend nodes>)
```

A single `click` event (not `selectNode`/`selectEdge`) handles both nodes and
edges. `selectNode` only fires on state-change (unselected → selected), causing
missed events when re-clicking an already-selected node. The `click` event fires
on every click, with `params.nodes` / `params.edges` indicating what was hit. A
nonce is appended so Shiny always treats each click as a new event.

The graph uses force-directed physics with stabilization enabled. Users can
drag individual nodes to reposition them, and pan/zoom controls are enabled.

---

## Node Click: Paper List Modal

Clicking a node opens a modal showing the papers in the current filtered view
that involve that node. The modal title is `"<node name> — N paper(s)"`.

Modal content is built directly as a `tagList` (static HTML table) inside the
`observeEvent` body and passed to `showModal` inline — no `uiOutput`/`renderUI`
indirection. This avoids a race condition where the output update and the modal
HTML insertion arrive at the browser in the same Shiny flush but the output is
processed before the `uiOutput` placeholder exists in the DOM.

**Modal table columns:**

| Column | Source |
|---|---|
| Title | `title`, truncated to 80 chars; linked via `https://doi.org/<doi>` if DOI present |
| Year | `year` |
| Contribution | `contribution_type` |
| First Author | `first_author` |

Sorted by `year` descending. Capped at 50 rows; a note above the table reports
total count when more are available.

**Fast lookup:** A precomputed reverse map `inst_to_records` (or
`author_to_records` in People mode) maps each node name to its set of
`record_key` values using `split()` at startup. Node click intersects these
keys with the current filtered set — O(1) lookup, no per-click table scan.

---

## Edge Click: Shared Paper List Modal

Clicking an edge opens a modal showing papers shared by both endpoint nodes.
Title: `"<node_a> – <node_b> — N shared paper(s)"`.

The edge `id` (integer) is sent via `net_edge_click`. The server resolves it
using `g$edge_lookup` (a data frame of `id → node_a, node_b` stored in the
`net_graph()` return value), then intersects the record keys for both nodes and
the current filtered set to identify the shared papers.

Same inline `tagList` build as node clicks — no `uiOutput`/`renderUI`.

---

## Color Legend

A `visLegend` panel anchored on the right side of the network canvas
(`position = "right"`, `width = 0.24`). Content adapts to the active mode:

**Institutions mode:**

| Swatch | Label |
|---|---|
| `#1a2f4a` navy | DWR |
| `#4da87a` green | US Institution |
| `#4a9cad` teal | International |
| `#aaaaaa` gray | Unknown geo |

**People mode:**

| Swatch | Label |
|---|---|
| `#1a2f4a` navy | DWR Author |
| `#4da87a` green | External Author |

---

## Hover Tooltip

Each node's `title` field is rendered as an HTML tooltip on hover:

```
<b>Institution / Author Name</b>
N paper(s)
```

Edge `title`: `"N paper(s)"` (integer count of shared papers).

---

## Stats Bar

A single line of muted text below the network, updated reactively:

> Showing **N** nodes · **M** edges · **P** papers in current filter

---

## Disambiguation Note (People mode only)

A conditional note shown only when Network Mode = People, using the
`net-stats-bar` style:

> Author names appear as recorded in Scopus ("Last F."). Different researchers
> sharing the same name and initials may appear as a single node.

Hidden in Institutions mode.

---

## Layout

```
┌────────────────────────────────────────────────────────────────────────┐
│  HEADER (shared, full-width)                                           │
├────────────────────────────────────────────────────────────────────────┤
│  [Dashboard]  [Institution Map]  [Publishing Network]  [Science Fields]│
├────────────────────────────────────────────────────────────────────────┤
│  [Year ─────○─○──] [Contribution ▼] [Science Field ▼]                  │
│  [● Institutions  ○ People] [Top N ─────○──] [Reset View]              │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │           visNetwork interactive force-directed graph           │   │
│  │   (DWR pinned center; pan/zoom; node click → paper list)        │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                        │
│  Showing N nodes · M edges · P papers                                  │
│  [Disambiguation note — People mode only]                              │
└────────────────────────────────────────────────────────────────────────┘
│  FOOTER (shared, full-width)                                           │
└────────────────────────────────────────────────────────────────────────┘
```

Network height: `calc(100vh - 280px)`.

---

## Design Decisions

1. **DWR as fixed anchor (institution mode only)** — `"California Department of
   Water Resources"` is pinned to `x = 0, y = 0` when present in the current
   institution network. It is retained regardless of the Top N setting, as long
   as it has edges in the filtered base table. This makes DWR's collaboration
   network the explicit subject of the institution view. In People mode, DWR
   authors are highlighted but not pinned, since there are multiple DWR staff
   rather than a single anchor.

2. **Top-N default 25, pan/zoom for high N** — The default keeps the graph
   readable. Users who increase N to 50+ see a denser graph; force-directed
   layout + pan/zoom handle navigation. The network stabilizes with 300 physics
   iterations.

3. **No DWR injection for funder records** — Funder-only papers (where DWR was
   not an author) do not connect DWR to co-author institutions in the network.
   The institution relationships shown for funder papers are the institution-to-
   institution edges among the authors on those papers. This is semantically
   correct: the network shows co-authorship, not funding relationships.

4. **Institution color by geography** — US / international / unknown, using the
   same palette family as the map tab. Gives a geographic dimension to the
   network view without a separate map. A color legend (right side of canvas)
   makes the color scheme legible without requiring prior knowledge.

4a. **Node size by paper count, not degree** — Sizing by the number of papers
   a node appears in (rather than degree/connections) makes visual prominence
   proportional to publication volume. An institution with many papers but only
   a few partners would otherwise appear small and be easy to miss.

5. **Author disambiguation note** — Names in `"Last F."` format cannot be
   reliably disambiguated. The note is honest about this rather than silently
   misrepresenting nodes.

6. **Independent controls** — Consistent with the Institution Map tab. Cross-tab
   filter coupling complicates state management and surprises users who have
   filtered the Dashboard differently.

7. **Paper list modal on click** — Surfaces the papers underlying a node without
   navigating away from the network or unexpectedly modifying Dashboard filters.

---

## R Packages (Network Visualization)

| Package | Use |
|---|---|
| `visNetwork` | Interactive force-directed network rendering, node/edge styling, click events |

`igraph` is not required — degree computation and edge pair generation are
straightforward with `dplyr` over the base tables. Add `igraph` later if layout
algorithms or graph-theoretic metrics (clustering coefficient, centrality) are
needed.

---

# Science Fields Tab

## Overview

A fourth tab in the dashboard showing the science classification taxonomy used
by the pipeline and Dashboard filters. The tab is informational: it has no
filters and does not share reactive state with the other tabs.

---

## Data Source

**File:** `taxonomy/dwr_disciplines_taxonomy.csv`

Loaded once at startup. Required columns:

| Column | Display use |
|---|---|
| `category` | Science category column, title-cased |
| `field` | Science field column, title-cased |
| `definition` | Full field definition |

The table reflects the same taxonomy used by the LLM classifier to populate
`pc_category` and `pc_field` in the dashboard export.

---

## Table

The tab renders a single `DT::datatable` with three columns:

| Column | Notes |
|---|---|
| Category | Top-level science category |
| Field | Specific science field |
| Definition | Full field definition, with the first sentence bolded |

Table options:

- Search box enabled with `dom = "ft"`
- 50 rows per page
- Initial sort by Category ascending
- No row numbers
- HTML escaping disabled only so the bolded first sentence can render

---

## Layout

```
┌───────────────────────────────────────────────────────────────────────┐
│  HEADER (shared, full-width)                                          │
├───────────────────────────────────────────────────────────────────────┤
│  [Dashboard] [Institution Map] [Publishing Network] [Science Fields]  │
├───────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  Category | Field | Definition                                        │
│  searchable DT table of taxonomy rows                                 │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
│  FOOTER (shared, full-width)                                          │
└───────────────────────────────────────────────────────────────────────┘
```

---

## Open Questions / Deferred

- **Clustering at high N** — visNetwork's clustering API could group nodes by
  geography or science field when N > 50. Deferred.
- **DWR authors in funder-only records** — Authors on funder-only papers who
  happen to be DWR staff will not be in `dwr_author_names` (since that file
  covers author-role records only). Their names render as "external" in People
  mode. This is a known data-model limitation.
