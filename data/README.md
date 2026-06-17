# Data Directory

Runtime data for the pipeline. Nothing here should be edited by hand except the files in `lookups/` (which have dedicated Shiny review apps) and `decisions/` (written by those apps).

See `docs/DATA_REFERENCE.md` for column-level schema documentation.

---

## Subdirectories

### `harvests/`

Raw Scopus harvest snapshots, one parquet file per refresh cycle.

```
harvest_<refresh_id>_candidates.parquet
```

These are write-once snapshots. The pipeline reads from them but never modifies them, so a refresh can be re-run from the harvest without hitting the Scopus API again.

---

### `queues/`

Review queues built from the harvest snapshot, filtered to records needing human review. Regenerated each refresh.

```
funder_review_queue.parquet     # input for shiny/funder_review_app.R
author_review_queue.parquet     # input for shiny/author_review_app.R
```

---

### `decisions/`

Manual review decisions recorded by the Shiny apps. These persist across refreshes — decisions from prior cycles are used to exclude already-reviewed records from future queues.

```
funding_review_decisions.csv        # keep / drop / unsure per funder candidate
author_review_decisions.csv         # keep / drop / unsure per affiliation candidate
author_division_decisions.csv       # division assignment per author/publication pair
```

---

### `lookups/`

Durable lookup tables. Most are built by pipeline targets and then reviewed via Shiny apps; some (`funding_division_lookup.csv`, `dwr_org_lookup.csv`) are partially hand-maintained.

```
affiliation_lookup.csv          # raw affiliation string → canonical institution name
author_division_lookup.csv      # DWR employee name × year → division (from HR data)
dwr_org_lookup.csv              # canonical division name aliases
funding_division_lookup.csv     # accepted funder publication → manually assigned DWR division
institution_geo_lookup.csv      # canonical institution name → country, US state
institution_reference.txt       # one canonical name per line; used as LLM context
```

After kept funder publications are published, the pipeline prepends any new rows
to `funding_division_lookup.csv`. Fill the `division` column manually for rows
where `new == TRUE`, then rerun the dashboard export targets so the final
inventory includes `funding_division`.

---

### `generated/`

Final pipeline outputs. These are the files consumed by the dashboard and any downstream exports.

```
accepted_publications.parquet   # durable source of truth; append-only
dwr_publications.parquet        # dashboard-ready view with division and country fields joined
dwr_publications.csv            # CSV export of the same
```

---

## `refresh_log.csv`

One row per completed refresh cycle, recording candidate counts, review counts, and timestamps. Written by `create_refresh_id.R` / `complete_refresh_log()`.
