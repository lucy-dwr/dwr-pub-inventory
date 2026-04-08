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
