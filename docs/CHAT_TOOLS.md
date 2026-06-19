# Dashboard Chat — Tool Reference

The dashboard's "Ask the data" chat assistant is powered by the LLM configured in `config/pipeline.yml`. It exposes twelve tools that the model selects from automatically based on the user's question. Tools are hidden from the chat pane — only the assistant's final text responses are visible.

---

## UI-driving tools

These tools update the live Shiny filter controls. The assistant always confirms what changed after calling them.

### `set_filters`

Sets one or more dashboard filters in a single call. Any parameter left out is unchanged.

| Parameter | Type | Description |
|-----------|------|-------------|
| `keyword` | string | Free-text search across title, abstract, and author fields. Pass `"All"` or `""` to clear. |
| `year_start` | integer | Start of the year range slider. |
| `year_end` | integer | End of the year range slider. |
| `science_category` | string | Top-level science category (e.g. `"Hydrology"`). Pass `"All"` to clear. |
| `science_field` | string | Specific science field within a category. |
| `division` | string | DWR division or office. |
| `contribution_type` | string | One of: `Funder`, `Co-Author`, `Lead Author`, `Sole Author`. |
| `affiliation` | string | Exact canonical institution name, or `"All"` to clear. |

**Example prompts:** "Show hydrology papers from 2018," "Filter to lead-authored papers in the Delta division," "Search for sturgeon."

---

### `reset_filters`

Clears all filters and returns the dashboard to its default state (all contribution types, default year range, no keyword or division selection).

**Example prompts:** "Start over," "Clear all filters," "Reset."

---

### `filter_to_papers`

Pins the dashboard table to a specific list of papers identified by their `record_key` values. Typically used after `find_papers` when the user wants to see those exact results in the publication table.

| Parameter | Type | Description |
|-----------|------|-------------|
| `record_keys` | array of strings | Record keys from a prior `find_papers` result. |

**Example prompts:** "Filter the dashboard to those papers," "Show just those results."

---

## Query tools

These tools read the current filtered view (or the full inventory) and return a text answer without changing the UI.

### `count_by`

Returns a ranked frequency table for one dimension of the current filtered view. Returns up to 25 rows.

| Parameter | Type | Description |
|-----------|------|-------------|
| `dimension` | string | One of: `year`, `science_field`, `science_category`, `division`, `contribution_type`, `journal`, `affiliation`, `country`. |

**Example prompts:** "How many papers per division?", "What are the top journals in the current view?", "Break down by science category."

---

### `get_trend`

Returns year-by-year publication counts for the current filtered view as a text table, optionally broken out by contribution type or division.

| Parameter | Type | Description |
|-----------|------|-------------|
| `breakdown` | string | Optional. One of `contribution_type` or `division` for a cross-tabulated view. |

**Example prompts:** "Is DWR publishing more over time?", "Show the trend for lead-authored papers," "When did ISE output peak?"

---

### `compare_periods`

Splits the current filtered view at a given year and returns counts, contribution type breakdown, and top science fields for both periods.

| Parameter | Type | Description |
|-----------|------|-------------|
| `split_year` | integer | Papers before this year form period 1; from this year onward form period 2. |

**Example prompts:** "Compare before and after 2020," "How did output change after the reorganization in 2018?"

---

### `find_papers`

Full-text keyword search across title, abstract, and author fields across the **entire inventory**, regardless of current dashboard filters. Returns a numbered list of matching papers with record keys for use with `filter_to_papers`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `query` | string | Keywords or phrase to search for. |
| `max_results` | integer | Maximum results to return (default 20). |

**Example prompts:** "Find papers about groundwater recharge," "Are there any papers on the Sacramento-San Joaquin Delta?", "Search for Matern."

---

### `get_paper_detail`

Returns full metadata for a specific paper: title, authors, year, journal, abstract, science field, DWR division(s), and DOI link.

| Parameter | Type | Description |
|-----------|------|-------------|
| `title_fragment` | string | Partial title to search for (case-insensitive). At least one of `title_fragment` or `doi` is required. |
| `doi` | string | Exact DOI. |

**Example prompts:** "Tell me more about the 2021 flood forecasting paper," "What's the abstract for doi 10.1016/j.xxx?"

---

### `synthesize_selection`

Retrieves titles and abstracts for all currently visible papers and passes them to the LLM so it can summarize themes, identify gaps, or answer questions about that set. Capped at 300 papers; if the view is larger the assistant asks the user to narrow the selection first.

**Example prompts:** "Summarize the themes in the current view," "What are the common methods used in these papers?", "Is there any work on climate change in this set?"

---

### `get_author_stats`

Returns the most prolific DWR authors in the current filtered view, with total publication count and lead/sole-author count.

| Parameter | Type | Description |
|-----------|------|-------------|
| `top_n` | integer | Number of authors to return (default 10). |

**Example prompts:** "Who are the most prolific authors in this selection?", "Which authors have the most lead-authored papers?"

---

### `get_collaboration_stats`

Returns the external institutions most frequently appearing as co-author affiliations in the current filtered view.

| Parameter | Type | Description |
|-----------|------|-------------|
| `top_n` | integer | Number of institutions to return (default 15). |
| `exclude_dwr` | boolean | Exclude DWR-affiliated entries (default `TRUE`). |

**Example prompts:** "Who does DWR collaborate with most on hydrology papers?", "What universities appear most often as co-authors?"

---

### `cite_papers`

Formats citations for papers in the current filtered view, sorted by year or title.

| Parameter | Type | Description |
|-----------|------|-------------|
| `max_papers` | integer | Maximum number of citations to return (default 10). |
| `sort_by` | string | One of `year_desc` (default), `year_asc`, or `title`. |

**Example prompts:** "Give me citations for the top 5 most recent lead-authored papers," "Format the hydrology papers from 2022 as a reference list."

---

## Implementation notes

The chat object is created per session in `shiny/dashboard_app.R` using `ellmer::chat_openai_compatible()`. The LLM endpoint and model are read from `config/pipeline.yml`; the API key comes from the `PUBCLASSIFY_LLM_KEY` environment variable. The `shinychat` package renders the chat widget and routes tool calls back to the registered R functions.

Tool definitions live in `R/dashboard_chat_tools.R` as a single `register_chat_tools()` function called from the server. The system prompt is loaded from `prompts/chat_system_prompt.txt` at app startup using `glue::glue()` to interpolate live filter values (year range, science categories, fields, divisions, etc.).

Most query tools call `isolate(filtered())` to read the current reactive filtered dataset without creating a reactive dependency. `find_papers` is the exception — it always searches the full `pubs` dataset regardless of active filters. `set_filters` and `filter_to_papers` are the only tools that write back to the Shiny session (via `updateTextInput`, `updateSliderInput`, etc.).
