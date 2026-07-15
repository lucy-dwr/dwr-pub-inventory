library(shiny)
library(bslib)
library(plotly)
library(DT)
library(dplyr)
library(arrow)
library(stringr)
library(leaflet)
library(rnaturalearth)
library(rnaturalearthdata)
library(rnaturalearthhires)
library(sf)
library(visNetwork)

# ── Paths ──────────────────────────────────────────────────────────────────────
if (basename(getwd()) == "shiny") setwd("..")
.ROOT <- getwd()


# ── Load data ──────────────────────────────────────────────────────────────────
pubs_raw  <- arrow::read_parquet(file.path(.ROOT, "data/generated/dwr_publications.parquet"))
taxonomy  <- read.csv(file.path(.ROOT, "taxonomy", "dwr_disciplines_taxonomy.csv"),
                      stringsAsFactors = FALSE)

refresh_log_path <- file.path(.ROOT, "data/refresh_log.csv")
.dataset_updated_label <- tryCatch({
  rl <- read.csv(refresh_log_path, stringsAsFactors = FALSE)
  completed <- as.POSIXct(rl$completed_at[nzchar(rl$completed_at) & !is.na(rl$completed_at)],
                          format = "%Y-%m-%d %H:%M:%S")
  dt <- as.Date(max(completed, na.rm = TRUE))
  format(dt, "%m/%d/%Y")
}, error = function(e) "12/10/2025")

# ── Geo lookup & map polygons (loaded once at startup) ─────────────────────────
geo_lookup_raw <- read.csv(
  file.path(.ROOT, "data/lookups/institution_geo_lookup.csv"),
  stringsAsFactors = FALSE
)
geo_lookup <- geo_lookup_raw[
  as.logical(geo_lookup_raw$resolved) & !is.na(geo_lookup_raw$country), , drop = FALSE
]
world_sf  <- rnaturalearth::ne_countries(scale = "medium", returnclass = "sf") |>
  dplyr::filter(iso_a3 != "USA")
states_sf <- rnaturalearth::ne_states(
  country = "United States of America", returnclass = "sf"
)

# Graceful fallback if pipeline hasn't been rebuilt yet
if (!"pc_category" %in% names(pubs_raw)) pubs_raw$pc_category <- NA_character_

# Pre-compute helper columns (done once at startup, not per-filter)
pubs <- pubs_raw |>
  mutate(
    first_author = vapply(authors, function(a) {
      v <- unlist(a)
      if (length(v) > 0L && !is.na(v[1L])) v[1L] else NA_character_
    }, character(1L)),
    authors_text = vapply(authors, function(a) {
      paste(unlist(a), collapse = " ")
    }, character(1L)),
    contribution_type = case_when(
      is_sole_author ~ "Sole Author",
      is_lead_author ~ "Lead Author",
      is_author      ~ "Co-Author",
      is_funder      ~ "Funder",
      TRUE           ~ NA_character_
    )
  )

# ── Country name harmonization: LLM names → Natural Earth admin names ──────────
.harmonize_country <- function(x) {
  mapping <- c(
    "United States" = "United States of America",
    "Tanzania"      = "United Republic of Tanzania",
    "Hong Kong"     = "Hong Kong S.A.R."
  )
  ifelse(!is.na(x) & x %in% names(mapping), mapping[x], x)
}

# ── Geo base tables (built once at startup from full pubs) ─────────────────────
# geo_country_base: one (record_key, country) row per unique country per paper,
# sourced from the pre-computed affiliation_countries list column.
geo_country_base <- {
  rows <- lapply(seq_len(nrow(pubs)), function(i) {
    ctrs <- unique(na.omit(unlist(pubs$affiliation_countries[[i]])))
    ctrs <- ctrs[nzchar(trimws(ctrs))]
    if (length(ctrs) == 0L) return(NULL)
    data.frame(record_key = pubs$record_key[i], country = ctrs,
               stringsAsFactors = FALSE)
  })
  do.call(rbind, Filter(Negate(is.null), rows))
}

# geo_inst_base: one (record_key, canonical, country, state) row per
# institution per paper, joined through the institution geo lookup.
# Used for US state counts and institution popup lists.
geo_inst_base <- {
  rows <- lapply(seq_len(nrow(pubs)), function(i) {
    affs <- unique(na.omit(unlist(pubs$affiliations[[i]])))
    affs <- affs[nzchar(trimws(affs))]
    if (length(affs) == 0L) return(NULL)
    matched <- geo_lookup[geo_lookup$canonical %in% affs, , drop = FALSE]
    if (nrow(matched) == 0L) return(NULL)
    data.frame(
      record_key = pubs$record_key[i],
      canonical  = matched$canonical,
      country    = matched$country,
      state      = matched$state,
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, Filter(Negate(is.null), rows))
}

# ── Publishing Network: constants, base tables, reverse lookups ────────────────
.DWR_NODE <- "California Department of Water Resources"

# Institution → country for node coloring (reuses geo_lookup already loaded)
inst_country_map <- setNames(geo_lookup$country, geo_lookup$canonical)

# Produce all ordered (smaller, larger) pairs from a vector; cap at 30 items
.make_node_pairs <- function(items, record_key, year, contribution_type, pc_field) {
  items <- unique(na.omit(items))
  items <- head(items[nzchar(trimws(items)) & items != "Unknown"], 30L)
  if (length(items) < 2L) return(NULL)
  idx <- combn(seq_along(items), 2L)
  a <- items[idx[1L, ]]
  b <- items[idx[2L, ]]
  swap <- a > b
  tmp <- a[swap]; a[swap] <- b[swap]; b[swap] <- tmp
  data.frame(
    node_a            = a,
    node_b            = b,
    record_key        = record_key,
    year              = year,
    contribution_type = contribution_type,
    pc_field          = pc_field,
    stringsAsFactors  = FALSE
  )
}

network_inst_base <- {
  rows <- lapply(seq_len(nrow(pubs)), function(i)
    .make_node_pairs(unlist(pubs$affiliations[[i]]),
                     pubs$record_key[i], pubs$year[i],
                     pubs$contribution_type[i], pubs$pc_field[i]))
  do.call(rbind, Filter(Negate(is.null), rows))
}

network_author_base <- {
  rows <- lapply(seq_len(nrow(pubs)), function(i)
    .make_node_pairs(unlist(pubs$authors[[i]]),
                     pubs$record_key[i], pubs$year[i],
                     pubs$contribution_type[i], pubs$pc_field[i]))
  do.call(rbind, Filter(Negate(is.null), rows))
}

# Fast reverse lookup: node label → vector of record_keys containing it
.build_node_lookup <- function(list_col, record_keys) {
  rows <- lapply(seq_along(list_col), function(i) {
    items <- unique(na.omit(unlist(list_col[[i]])))
    items <- items[nzchar(trimws(items))]
    if (length(items) == 0L) return(NULL)
    data.frame(node = items, record_key = record_keys[i], stringsAsFactors = FALSE)
  })
  df <- do.call(rbind, Filter(Negate(is.null), rows))
  if (is.null(df) || nrow(df) == 0L) return(list())
  split(df$record_key, df$node)
}

inst_to_records   <- .build_node_lookup(pubs$affiliations, pubs$record_key)
author_to_records <- .build_node_lookup(pubs$authors,      pubs$record_key)

# ── Filter choices (built once) ────────────────────────────────────────────────
all_affiliations <- sort(unique(na.omit(unlist(pubs_raw$affiliations))))
all_affiliations <- all_affiliations[nchar(trimws(all_affiliations)) > 0L]
field_choices    <- c("All", sort(unique(na.omit(pubs$pc_field))))

all_categories   <- sort(unique(str_to_title(na.omit(pubs$pc_category))))
year_min         <- min(pubs$year, na.rm = TRUE)
year_max         <- max(pubs$year, na.rm = TRUE)
YEAR_DEFAULT     <- c(max(year_min, 2020L), min(year_max, 2026L))

# ── Featured article: random, fixed at startup ─────────────────────────────────
set.seed(as.integer(Sys.time()) %% 100000L)
featured_pool <- filter(pubs, !is.na(doi), !is.na(title), !is.na(first_author))
featured      <- featured_pool[sample(nrow(featured_pool), 1L), ]

# ── Constants ──────────────────────────────────────────────────────────────────
CONTRIB_LEVELS <- c("Sole Author", "Lead Author", "Co-Author", "Funder")

CONTRIB_COLORS <- c(
  "Funder"      = "#1a3a5c",
  "Co-Author"   = "#a8d5b5",
  "Lead Author" = "#4da87a",
  "Sole Author" = "#2d7a5f"
)

CATEGORY_COLORS <- c(
  "#1a3a5c", "#2d6a7a", "#4a9cad", "#7dc3d0",
  "#2d7a5f", "#7ec8a0", "#c9a227", "#8a6aad"
)

# ── CSS ────────────────────────────────────────────────────────────────────────
app_css <- "
  body {
    margin: 0; padding: 0;
    background: #eef1f5;
    font-family: 'Helvetica Neue', Arial, sans-serif;
  }
  /* Remove Bootstrap container padding so header/footer go edge-to-edge */
  .container-fluid { padding: 0 !important; }

  /* ── Header ── */
  .dwr-header {
    background: #1a2f4a; color: white;
    padding: 14px 28px;
    display: flex; align-items: center; justify-content: space-between;
  }
  .hdr-brand {
    display: flex; align-items: center; gap: 12px;
  }
  .hdr-brand-text {
    font-size: 0.68rem; text-transform: uppercase;
    letter-spacing: 0.07em; line-height: 1.45;
  }
  .hdr-brand-text strong { font-size: 0.82rem; display: block; }
  .hdr-center { text-align: center; flex: 1; padding: 0 16px; }
  .hdr-center h1 {
    font-size: 1.2rem; font-weight: 700; margin: 0 0 3px;
    letter-spacing: 0.07em;
  }
  .hdr-center .yr-sub { font-size: 0.82rem; opacity: 0.8; }
  .hdr-contact {
    text-align: right; font-size: 0.68rem;
    line-height: 1.55; max-width: 240px;
  }
  .hdr-contact .ctlbl {
    font-weight: 700; color: #c9a227;
    text-transform: uppercase; letter-spacing: 0.06em;
    display: block; margin-bottom: 2px;
  }
  .hdr-contact a { color: #7dc3d0; }

  /* ── Controls bar ── */
  .ctrls-bar {
    background: white; padding: 10px 24px;
    display: flex; align-items: center; gap: 10px;
    border-bottom: 1px solid #dde3ea;
  }
  .ctrls-bar .kw-wrap { flex: 0 0 320px; }
  .ctrls-bar .kw-wrap .form-group,
  .ctrls-bar .kw-wrap .mb-3 { margin-bottom: 0 !important; }
  .ctrls-bar .kw-wrap input.form-control { font-size: 0.83rem; height: 34px; }
  .ctrls-spacer { flex: 1; }
  .btn-dwr {
    background: #1a2f4a !important; color: white !important;
    border: none !important; border-radius: 3px !important;
    font-size: 0.78rem !important; padding: 6px 13px !important;
    white-space: nowrap;
  }
  .btn-dwr:hover, .btn-dwr:focus { background: #2e4d72 !important; }
  /* ── Main wrapper ── */
  .main-wrap { padding: 16px 24px 4px; }

  /* ── Three-column flex layout ── */
  .main-layout {
    display: flex;
    gap: 14px;
    align-items: flex-start;
  }
  .panel-left {
    flex: 0 0 40%;
    min-width: 0;
    overflow: hidden;
  }
  .panel-right {
    flex: 1;
    min-width: 0;
    overflow: hidden;
  }
  /* ── Panel cards ── */
  .pcrd {
    background: white; border-radius: 4px;
    padding: 14px 16px; margin-bottom: 14px;
    box-shadow: 0 1px 3px rgba(0,0,0,0.08);
  }
  .pcrd-title {
    font-size: 0.87rem; font-weight: 600; color: #1a2f4a;
    text-align: center; margin-bottom: 8px;
  }

  /* ── Featured article ── */
  .feat-badge {
    font-size: 0.68rem; font-weight: 700; text-transform: uppercase;
    letter-spacing: 0.08em; color: #4a6080; margin-bottom: 8px;
  }
  .feat-title {
    font-size: 0.92rem; font-weight: 500;
    color: #1a2f4a; line-height: 1.45;
  }
  .feat-meta { font-size: 0.77rem; color: #7a8a9a; margin-top: 5px; }
  a.feat-readlink {
    font-size: 0.82rem; color: #4a9cad;
    text-decoration: underline; display: inline-block; margin-top: 8px;
  }

  /* ── Stat boxes ── */
  .stat-row { display: flex; gap: 10px; margin-bottom: 14px; }
  .sbox {
    flex: 1; background: white; border-radius: 4px;
    padding: 12px 8px; text-align: center;
    box-shadow: 0 1px 3px rgba(0,0,0,0.08);
    border-top: 3px solid #4a9cad;
  }
  .sbox-icon { color: #4a9cad; margin-bottom: 3px; font-size: 0.9rem; }
  .sbox-n   { font-size: 1.5rem; font-weight: 700; color: #1a2f4a; line-height: 1.1; }
  .sbox-lbl {
    font-size: 0.61rem; color: #7a8a9a;
    text-transform: uppercase; letter-spacing: 0.05em; margin-top: 3px;
  }

  /* ── Filters ── */
  .filt-row .form-group,
  .filt-row .mb-3 { margin-bottom: 0 !important; }
  .filt-row label { font-size: 0.76rem; font-weight: 600; color: #4a6080; margin-bottom: 2px; }
  .filt-row .form-control,
  .filt-row .selectize-input { font-size: 0.81rem; }
  .filt-disabled { opacity: 0.42; pointer-events: none; }

  /* ── Active-filter badge ── */
  .active-badge {
    text-align: center; margin-bottom: 7px;
  }
  .active-badge span {
    display: inline-flex; align-items: center; gap: 6px;
    background: #e8f1f7; color: #1a3a5c;
    font-size: 0.76rem; padding: 2px 10px;
    border-radius: 10px;
  }
  .active-badge a { color: #7a8a9a; font-weight: 700; text-decoration: none; }
  .active-badge a:hover { color: #1a3a5c; }

  /* ── Article table ── */
  table.dataTable thead th {
    font-weight: 700; background: #f5f7f9;
    color: #1a2f4a; font-size: 0.8rem;
    border-bottom: 2px solid #dde3ea !important;
  }
  table.dataTable tbody td { font-size: 0.8rem; vertical-align: middle; }
  table.dataTable tbody tr.odd  { background: #fafcfd; }
  table.dataTable tbody tr:hover { background: #edf4f8 !important; }
  .dataTables_wrapper .dataTables_paginate { font-size: 0.78rem; padding-top: 8px; }
  a.rd-link { color: #4a9cad; text-decoration: underline; }

  /* ── Footer ── */
  .dwr-footer {
    background: #1a2f4a; color: rgba(255,255,255,0.6);
    text-align: right; padding: 9px 28px;
    font-size: 0.71rem;
  }

  /* ── Tab navigation ── */
  .nav-tabs {
    background: white; padding: 0 24px;
    border-bottom: 2px solid #dde3ea;
    margin-bottom: 0;
  }
  .nav-tabs .nav-link {
    color: #4a6080; font-size: 0.80rem;
    font-weight: 600; text-transform: uppercase;
    letter-spacing: 0.06em; border: none !important;
    border-radius: 0 !important; padding: 10px 18px;
    border-bottom: 3px solid transparent !important;
  }
  .nav-tabs .nav-link:hover {
    color: #1a2f4a; background: none !important;
    border-bottom-color: #7dc3d0 !important;
  }
  .nav-tabs .nav-link.active {
    color: #1a2f4a !important; background: none !important;
    border-bottom: 3px solid #4a9cad !important;
  }
  .tab-content > .tab-pane { padding: 0; }
  .tab-content > .active  { display: block; }

  /* ── Map controls bar ── */
  .map-ctrls-bar {
    background: white; padding: 10px 24px;
    display: flex; align-items: stretch;
    border-bottom: 1px solid #dde3ea;
  }
  /* Left: label + slider, bottom-justified, takes remaining space */
  .map-yr-group {
    flex: 0 0 380px; display: flex; flex-direction: column;
    justify-content: flex-end; padding-right: 32px;
  }
  .map-yr-group .yr-label {
    font-size: 0.76rem; font-weight: 600; color: #4a6080; margin-bottom: 2px;
  }
  /* Right: dropdown + button, bottom-aligned, fixed to right edge */
  .map-right-group {
    flex-shrink: 0; display: flex; align-items: flex-end; gap: 16px;
  }
  .map-ctrls-bar .form-group,
  .map-ctrls-bar .mb-3 { margin-bottom: 0 !important; }
  .map-ctrls-bar label { font-size: 0.76rem; font-weight: 600; color: #4a6080; margin-bottom: 2px; }
  .map-ctrls-bar .ct-wrap { width: 200px; }
  .map-ctrls-bar .selectize-input,
  .map-ctrls-bar .form-control { font-size: 0.81rem; }
  /* match button height to selectize input */
  .map-ctrls-bar .btn-dwr {
    height: 38px; padding-top: 0; padding-bottom: 0;
    display: inline-flex; align-items: center;
  }
  /* hide grid ticks and endpoint labels; keep irs-from/to/single for moving handle labels */
  .map-ctrls-bar .irs--shiny .irs-grid-text,
  .map-ctrls-bar .irs--shiny .irs-grid-pol,
  .map-ctrls-bar .irs--shiny .irs-min,
  .map-ctrls-bar .irs--shiny .irs-max { display: none; }

  /* ── Map notes bar ── */
  .map-notes-bar {
    background: white; padding: 7px 24px;
    border-top: 1px solid #dde3ea;
    display: flex; gap: 24px; flex-wrap: wrap;
    font-size: 0.76rem; color: #4a6080;
  }
  .map-note-item { display: flex; align-items: flex-start; gap: 6px; }
  .map-note-lbl  { font-weight: 700; color: #1a2f4a; white-space: nowrap; }

  /* ── Network tab controls bar ── */
  .net-ctrls-bar {
    background: white; padding: 10px 24px;
    border-bottom: 1px solid #dde3ea;
  }
  .net-ctrls-row {
    display: flex; align-items: flex-end; gap: 36px; flex-wrap: wrap;
  }
  .net-yr-group   { flex: 0 0 300px; }
  .net-ct-group   { flex: 0 0 175px; }
  .net-fld-group  { flex: 0 0 200px; }
  .net-topn-group { flex: 0 0 190px; }
  .net-yr-group .yr-label {
    font-size: 0.76rem; font-weight: 600; color: #4a6080; margin-bottom: 2px;
  }
  .net-ctrls-bar .form-group,
  .net-ctrls-bar .mb-3 { margin-bottom: 0 !important; }
  .net-ctrls-bar label {
    font-size: 0.76rem; font-weight: 600; color: #4a6080; margin-bottom: 2px;
  }
  .net-ctrls-bar .selectize-input,
  .net-ctrls-bar .form-control { font-size: 0.81rem; }
  .net-ctrls-bar .btn-dwr {
    height: 38px; padding-top: 0; padding-bottom: 0;
    display: inline-flex; align-items: center;
  }
  .net-ctrls-bar .irs--shiny .irs-grid-text:not(.dwr-decade),
  .net-ctrls-bar .irs--shiny .irs-grid-pol:not(.dwr-decade-pol),
  .net-ctrls-bar .irs--shiny .irs-min,
  .net-ctrls-bar .irs--shiny .irs-max { display: none; }
  /* Network mode radio: inline, compact */
  .net-mode-group .shiny-input-container { margin-bottom: 0; }
  .net-mode-group .shiny-options-group   { display: flex; gap: 16px; margin-top: 2px; }
  .net-mode-group .radio                 { display: inline-flex; align-items: center; margin: 0; }
  .net-mode-group .radio label           { font-size: 0.81rem !important; font-weight: 400 !important; }
  .net-mode-group > .control-label {
    font-size: 0.76rem; font-weight: 600; color: #4a6080;
    display: block; margin-bottom: 2px;
  }

  /* ── Network stats / note bar ── */
  .net-stats-bar {
    background: white; padding: 6px 24px;
    border-top: 1px solid #dde3ea;
    font-size: 0.76rem; color: #4a6080;
  }

  /* ── Science Fields tab ── */
  .taxonomy-wrap {
    padding: 24px 40px;
  }
  #taxonomy_table td {
    white-space: normal !important;
    vertical-align: top;
    line-height: 1.5;
  }
  #taxonomy_table td:nth-child(1),
  #taxonomy_table td:nth-child(2) {
    white-space: nowrap !important;
    font-weight: 500;
  }
"

# ── UI ─────────────────────────────────────────────────────────────────────────
ui <- fluidPage(
  title = "DWR Peer-Reviewed Publication Inventory",
  theme = bslib::bs_theme(version = 5),
  tags$head(
    tags$style(HTML(app_css)),
    tags$script(HTML("
      // ── Decade tick marks on year slider ────────────────────────────────────
      $(document).on('shiny:connected', function() {
        var el = document.getElementById('year_range');
        if (!el) return;
        var container = el.closest('.shiny-input-container');

        function injectDecades() {
          var slider = $(el).data('ionRangeSlider');
          if (!slider) return false;
          var grid = container.querySelector('.irs-grid');
          if (!grid) return false;

          var min = slider.options.min, max = slider.options.max;

          // Hide all auto-generated labels and tick lines
          grid.querySelectorAll('.irs-grid-text:not(.dwr-decade), .irs-grid-pol:not(.dwr-decade-pol)').forEach(function(t) {
            t.style.display = 'none';
          });

          // Remove any stale custom elements before re-injecting
          grid.querySelectorAll('.dwr-decade, .dwr-decade-pol').forEach(function(t) { t.remove(); });

          // Inject a label and tick line for each decade within [min, max]
          for (var yr = Math.ceil(min / 10) * 10; yr <= max; yr += 10) {
            var pct = ((yr - min) / (max - min) * 100) + '%';

            var pol = document.createElement('span');
            pol.className = 'irs-grid-pol dwr-decade-pol';
            pol.style.left = pct;
            grid.appendChild(pol);

            var span = document.createElement('span');
            span.className = 'irs-grid-text dwr-decade';
            span.style.left = pct;
            span.style.transform = 'translateX(-50%)';
            span.textContent = yr;
            grid.appendChild(span);
          }
          return true;
        }

        // The grid is rendered once on init and is static -- disconnect after first success
        var obs = new MutationObserver(function() {
          if (injectDecades()) obs.disconnect();
        });
        obs.observe(container, { childList: true, subtree: true });
        setTimeout(injectDecades, 300);
      });

      // ── Map tab: trigger leaflet resize when tab becomes visible ─────────────
      $(document).on('shown.bs.tab', function() {
        setTimeout(function() { window.dispatchEvent(new Event('resize')); }, 100);
      });
    "))
  ),

  # ── Header ──────────────────────────────────────────────────────────────────
  div(class = "dwr-header",
    div(class = "hdr-brand",
      tags$img(src = "dwr-logo-new.png", height = "48px", alt = "DWR logo"),
      div(class = "hdr-brand-text",
        tags$small("California Department of"),
        tags$strong("WATER RESOURCES")
      )
    ),
    div(class = "hdr-center",
      tags$h1("PEER-REVIEWED PUBLICATION INVENTORY"),
      div(class = "yr-sub", textOutput("hdr_years", inline = TRUE))
    ),
    div(class = "hdr-contact",
      tags$span(class = "ctlbl", "Contact"),
      "For questions or feedback,", tags$br(),
      "please email ",
      tags$a("dwrscience@water.ca.gov", href = "mailto:dwrscience@water.ca.gov")
    )
  ),

  # ── Tabs ─────────────────────────────────────────────────────────────────────
  tabsetPanel(
    id = "main_tabs", type = "tabs",

    # ── Dashboard tab ──────────────────────────────────────────────────────────
    tabPanel("Dashboard",

      div(class = "ctrls-bar",
        div(class = "kw-wrap",
          textInput("keyword", label = NULL,
            placeholder = "▼  Enter Keyword Search", width = "100%")
        ),
        div(class = "ctrls-spacer"),
        actionButton("btn_sci",   "Science Category & Field Classification", class = "btn-dwr"),
        actionButton("btn_about", "About the Inventory",                     class = "btn-dwr"),
        actionButton("btn_reset", "Reset",                                   class = "btn-dwr")
      ),

      div(class = "main-wrap",
        div(class = "main-layout",

          div(class = "panel-left",
            div(class = "pcrd", uiOutput("featured_ui")),
            div(class = "pcrd",
              div(class = "pcrd-title", "Science Category"),
              uiOutput("cat_filter_badge"),
              plotlyOutput("pie_category", height = "310px")
            ),
          ),

          div(class = "panel-right",
            div(class = "pcrd filt-row",
              fluidRow(
                column(4,
                  selectInput("f_field", "Science Field",
                    choices = field_choices, width = "100%")
                ),
                column(4,
                  selectInput("f_contrib", "Contribution Type",
                    choices = c("All", CONTRIB_LEVELS), width = "100%")
                ),
                column(4,
                  selectInput("f_affil", "Author Affiliation",
                    choices = c("All", all_affiliations), width = "100%")
                )
              )
            ),
            uiOutput("papers_filter_banner"),
            uiOutput("stat_boxes"),
            div(class = "pcrd",
              div(class = "pcrd-title", "Publications by Year and Contribution"),
              sliderInput("year_range", NULL,
                min   = year_min,
                max   = year_max,
                value = YEAR_DEFAULT,
                step  = 1, sep = "", width = "100%"
              ),
              plotlyOutput("bar_year", height = "240px")
            ),
            div(class = "pcrd",
              DT::dataTableOutput("article_table")
            )
          )

        )
      )
    ),

    # ── Institution Map tab ────────────────────────────────────────────────────
    tabPanel("Institution Map",
      div(class = "map-ctrls-bar",
        div(class = "map-yr-group",
          tags$span(class = "yr-label", "Year Range"),
          div(class = "yr-wrap",
            sliderInput("map_year_range", label = NULL,
              min = year_min, max = year_max, value = YEAR_DEFAULT,
              step = 1, sep = "", width = "100%"
            )
          )
        ),
        div(class = "map-right-group",
          div(class = "ct-wrap",
            selectInput("map_contrib", "Contribution Type",
              choices = c("All", CONTRIB_LEVELS), width = "100%"
            )
          ),
          div(class = "reset-wrap",
            actionButton("map_reset_view", "Reset View", class = "btn-dwr")
          )
        )
      ),
      leafletOutput("institution_map", height = "calc(100vh - 300px)"),
      uiOutput("map_notes_ui")
    ),

    # ── Publishing Network tab ─────────────────────────────────────────────────
    tabPanel("Publishing Network",
      div(class = "net-ctrls-bar",
        div(class = "net-ctrls-row",
          div(class = "net-yr-group",
            tags$span(class = "yr-label", "Year Range"),
            sliderInput("net_year_range", label = NULL,
              min = year_min, max = year_max, value = YEAR_DEFAULT,
              step = 1, sep = "", width = "100%")
          ),
          div(class = "net-ct-group",
            selectInput("net_contrib", "Contribution Type",
              choices = c("All", CONTRIB_LEVELS), width = "100%")
          ),
          div(class = "net-fld-group",
            selectInput("net_field", "Science Field",
              choices = field_choices, width = "100%")
          ),
          div(class = "net-mode-group",
            radioButtons("net_mode", "Network Mode",
              choices  = c("Institutions", "People"),
              selected = "Institutions", inline = TRUE)
          ),
          div(class = "net-topn-group",
            sliderInput("net_top_n", "Top N Nodes",
              min = 5, max = 100, value = 25, step = 5, width = "100%")
          ),
          div(style = "flex-shrink: 0; display: flex; align-items: flex-end;",
            actionButton("net_reset", "Reset View", class = "btn-dwr")
          )
        )
      ),
      visNetwork::visNetworkOutput("network_graph", height = "calc(100vh - 280px)"),
      uiOutput("net_stats_bar"),
      uiOutput("net_disambig_note")
    ),

    # ── Science Fields tab ───────────────────────────────────────────────────
    tabPanel("Science Fields",
      div(class = "taxonomy-wrap",
        DT::dataTableOutput("taxonomy_table")
      )
    )

  ),

  # ── Footer ──────────────────────────────────────────────────────────────────────────
  div(class = "dwr-footer", paste0("Dataset updated ", .dataset_updated_label))
)

# ── Server ─────────────────────────────────────────────────────────────────────
server <- function(input, output, session) {

  # ── Debounced keyword ──────────────────────────────────────────────────────
  keyword_d <- debounce(reactive(input$keyword), 300)

  # Tracks which science category the user has clicked in the pie chart
  selected_category <- reactiveVal(NULL)

  # ── Filtered dataset (core reactive) ──────────────────────────────────────
  # filtered_base: all dropdown/slider filters; used by the pie chart itself
  # filtered:      base + science category selection from pie click
  filtered_base <- reactive({
    df <- pubs

    # Year range
    yr <- input$year_range
    df <- filter(df, !is.na(year), year >= yr[1L], year <= yr[2L])

    # Keyword: title, abstract, authors
    kw <- trimws(keyword_d())
    if (nchar(kw) > 0L) {
      kw_l <- tolower(kw)
      df <- filter(df,
        str_detect(tolower(coalesce(title,    "")), fixed(kw_l)) |
        str_detect(tolower(coalesce(abstract, "")), fixed(kw_l)) |
        str_detect(tolower(authors_text),           fixed(kw_l))
      )
    }

    # Science Field
    if (!isTRUE(input$f_field == "All"))
      df <- filter(df, pc_field == input$f_field)

    # Contribution Type
    if (!isTRUE(input$f_contrib == "All"))
      df <- filter(df, contribution_type == input$f_contrib)

    # Author Affiliation
    if (!isTRUE(input$f_affil == "All")) {
      tgt  <- input$f_affil
      keep <- vapply(df$affiliations,
        function(a) tgt %in% unlist(a), logical(1L))
      df <- df[keep, ]
    }

    df
  })

  filtered <- reactive({
    df  <- filtered_base()
    cat <- selected_category()
    if (!is.null(cat))
      df <- filter(df, str_to_title(pc_category) == cat)
    df
  })

  # ── Header year subtitle ───────────────────────────────────────────────────
  output$hdr_years <- renderText({
    yr <- input$year_range
    paste0(yr[1L], "\u2013", yr[2L])
  })

  # ── Featured article (static — does not react to filters) ─────────────────
  output$featured_ui <- renderUI({
    div(
      div(class = "feat-badge",
        "FEATURED ARTICLE"
      ),
      div(class = "feat-title", featured$title),
      div(class = "feat-meta", {
        n_authors <- length(unlist(featured$authors[[1]]))
        author_str <- if (n_authors > 1L) {
          paste0(featured$first_author, " et al.")
        } else {
          featured$first_author
        }
        paste0(author_str, ", ", featured$year)
      }),
      tags$a("Read Article \u2192",
        href   = paste0("https://doi.org/", featured$doi),
        target = "_blank",
        class  = "feat-readlink"
      )
    )
  })

  # ── Stat boxes ────────────────────────────────────────────────────────────
  output$stat_boxes <- renderUI({
    df    <- filtered()
    stats <- list(
      list(icon = "file-alt", n = nrow(df),
           lbl = "Total Articles"),
      list(icon = "coins",    n = sum(df$is_funder, na.rm = TRUE),
           lbl = "Articles Funded"),
      list(icon = "building", n = sum(df$is_author, na.rm = TRUE),
           lbl = "Affiliated Orgs"),
      list(icon = "users",    n = sum(df$is_author & !df$is_lead_author, na.rm = TRUE),
           lbl = "Co-Authored"),
      list(icon = "user",     n = sum(df$is_lead_author, na.rm = TRUE),
           lbl = "Lead Authored")
    )
    div(class = "stat-row",
      lapply(stats, function(s)
        div(class = "sbox",
          div(class = "sbox-icon", icon(s$icon)),
          div(class = "sbox-n",    format(s$n, big.mark = ",")),
          div(class = "sbox-lbl", s$lbl)
        )
      )
    )
  })

  # ── Science Category pie ───────────────────────────────────────────────────
  output$pie_category <- renderPlotly({
    df <- filtered_base()

    cat_df <- df |>
      filter(!is.na(pc_category)) |>
      mutate(cat = str_to_title(pc_category)) |>
      count(cat, name = "n") |>
      arrange(desc(n))

    if (nrow(cat_df) == 0L) {
      return(plot_ly() |>
        layout(
          title         = list(text = "No data", font = list(size = 12)),
          paper_bgcolor = "rgba(0,0,0,0)",
          plot_bgcolor  = "rgba(0,0,0,0)"
        ) |> config(displayModeBar = FALSE))
    }

    colors <- CATEGORY_COLORS[seq_len(min(nrow(cat_df), length(CATEGORY_COLORS)))]

    plot_ly(
      cat_df,
      labels        = ~cat,
      values        = ~n,
      type          = "pie",
      source        = "pie_chart",
      textinfo      = "percent",
      textposition  = "auto",
      hovertemplate = "%{label}<br>%{value} articles (%{percent})<extra></extra>",
      marker        = list(colors = colors,
                           line   = list(color = "white", width = 1.5)),
      showlegend    = TRUE
    ) |>
      layout(
        margin        = list(t = 4, b = 4, l = 4, r = 4),
        legend        = list(
          orientation = "v",
          x = 1.02, xanchor = "left",
          y = 0.5,  yanchor = "middle",
          font = list(size = 10),
          itemsizing = "constant"
        ),
        paper_bgcolor = "rgba(0,0,0,0)",
        plot_bgcolor  = "rgba(0,0,0,0)"
      ) |>
      config(displayModeBar = FALSE)
  })

  # ── Category badge (shows active pie selection; × clears it) ─────────────
  output$cat_filter_badge <- renderUI({
    cat <- selected_category()
    if (is.null(cat)) return(NULL)
    div(class = "active-badge",
      tags$span(cat, actionLink("clear_cat", "×"))
    )
  })

  observeEvent(input$clear_cat, {
    selected_category(NULL)
    updateSelectInput(session, "f_field", choices = field_choices, selected = "All")
  })

  # ── Pie click → filter by science category ────────────────────────────────
  observeEvent(
    event_data("plotly_click", source = "pie_chart", priority = "event"),
    {
      click <- event_data("plotly_click", source = "pie_chart", priority = "event")
      lbl   <- as.character(click$label)
      if (length(lbl) == 0L || is.na(lbl)) return()
      current <- selected_category()
      if (!is.null(current) && current == lbl) {
        # Same slice clicked again → deselect
        selected_category(NULL)
        updateSelectInput(session, "f_field", choices = field_choices, selected = "All")
      } else {
        selected_category(lbl)
        fields <- pubs |>
          filter(str_to_title(pc_category) == lbl) |>
          pull(pc_field) |> na.omit() |> unique() |> sort()
        updateSelectInput(session, "f_field",
          choices = c("All", fields), selected = "All")
      }
    }
  )

  # ── Publications by Year stacked bar ──────────────────────────────────────
  output$bar_year <- renderPlotly({
    df            <- filtered()
    years_present <- sort(unique(df$year[!is.na(df$year)]))

    if (length(years_present) == 0L) {
      return(plot_ly() |>
        layout(
          title         = list(text = "No data for selected filters", font = list(size = 12)),
          paper_bgcolor = "rgba(0,0,0,0)",
          plot_bgcolor  = "rgba(0,0,0,0)"
        ) |> config(displayModeBar = FALSE))
    }

    # Full year × contribution_type grid ensures no missing bars
    grid <- expand.grid(
      year              = years_present,
      contribution_type = CONTRIB_LEVELS,
      stringsAsFactors  = FALSE
    )
    counts <- df |>
      filter(!is.na(year), !is.na(contribution_type)) |>
      count(year, contribution_type) |>
      right_join(grid, by = c("year", "contribution_type")) |>
      mutate(n = coalesce(n, 0L))

    totals <- df |>
      filter(!is.na(year)) |>
      count(year, name = "total")

    fig <- plot_ly()
    for (ct in CONTRIB_LEVELS) {
      d <- filter(counts, contribution_type == ct)
      fig <- add_trace(fig,
        data          = d,
        x             = ~year,
        y             = ~n,
        type          = "bar",
        name          = ct,
        marker        = list(color = CONTRIB_COLORS[[ct]]),
        hovertemplate = paste0(ct, ": %{y}<extra></extra>")
      )
    }

    fig |>
      add_trace(
        data          = totals,
        x             = ~year,
        y             = ~total,
        type          = "scatter",
        mode          = "text",
        text          = ~total,
        textposition  = "top center",
        textfont      = list(size = 10, color = "#1a2f4a"),
        cliponaxis    = FALSE,
        showlegend    = FALSE,
        hoverinfo     = "none"
      ) |>
      layout(
        barmode       = "stack",
        xaxis         = list(title = "", tickformat = "d", fixedrange = TRUE,
                             automargin = TRUE),
        yaxis         = list(title = "Publications", fixedrange = TRUE,
                             range = list(0, max(totals$total, na.rm = TRUE) * 1.12)),
        legend        = list(orientation = "h", y = -0.22, x = 0.5,
                             xanchor = "center", font = list(size = 11)),
        margin        = list(t = 28, b = 50, l = 50, r = 20),
        paper_bgcolor = "rgba(0,0,0,0)",
        plot_bgcolor  = "rgba(0,0,0,0)"
      ) |>
      config(displayModeBar = FALSE)
  })

  # ── Article table ──────────────────────────────────────────────────────────
  output$article_table <- DT::renderDataTable({
    df <- filtered() |>
      mutate(
        title_html = ifelse(
          nchar(coalesce(title, "")) > 80L,
          paste0(
            '<span title="', htmltools::htmlEscape(coalesce(title, "")), '">',
            htmltools::htmlEscape(substr(coalesce(title, ""), 1L, 80L)),
            "&hellip;</span>"
          ),
          htmltools::htmlEscape(coalesce(title, ""))
        ),
        link_html = ifelse(
          !is.na(doi),
          paste0('<a href="https://doi.org/', doi,
                 '" target="_blank" class="rd-link">Read &gt;</a>'),
          ""
        )
      ) |>
      arrange(title) |>
      select(
        `Article Title` = title_html,
        `First Author`  = first_author,
        `Science Field` = pc_field,
        `Article Link`  = link_html
      )

    DT::datatable(
      df,
      escape   = FALSE,
      rownames = FALSE,
      options  = list(
        pageLength = 10,
        dom        = "tp",
        ordering   = FALSE,
        columnDefs = list(
          list(className = "dt-left", targets = "_all"),
          list(width = "48%", targets = 0L),
          list(width = "20%", targets = 1L),
          list(width = "20%", targets = 2L),
          list(width = "10%", targets = 3L)
        )
      ),
      class = "stripe hover"
    )
  }, server = TRUE)

  # ── Modals ────────────────────────────────────────────────────────────────
  observeEvent(input$btn_about, {
    showModal(modalDialog(
      title     = "About the Inventory",
      HTML(commonmark::markdown_html(
        paste(readLines(file.path(.ROOT, "shiny", "content", "about.md"),
                        warn = FALSE), collapse = "\n")
      )),
      easyClose = TRUE,
      footer    = modalButton("Close")
    ))
  })

  observeEvent(input$btn_sci, {
    showModal(modalDialog(
      title     = "Science Category & Field Classification",
      HTML(commonmark::markdown_html(
        paste(readLines(file.path(.ROOT, "shiny", "content", "classification.md"),
                        warn = FALSE), collapse = "\n")
      )),
      easyClose = TRUE,
      footer    = modalButton("Close")
    ))
  })

  # ── Science Fields tab ───────────────────────────────────────────────────
  output$taxonomy_table <- DT::renderDataTable({
    bold_first_sentence <- function(x) {
      # Bold up to and including the first sentence-ending period
      # (identified by a period followed by whitespace + capital letter)
      ifelse(
        grepl("\\. [A-Z]", x),
        sub("^(.*?\\.) (?=[A-Z])", "<strong>\\1</strong> ", x, perl = TRUE),
        paste0("<strong>", x, "</strong>")
      )
    }
    df <- data.frame(
      Category   = stringr::str_to_title(taxonomy$category),
      Field      = stringr::str_to_title(taxonomy$field),
      Definition = bold_first_sentence(taxonomy$definition),
      stringsAsFactors = FALSE
    )
    DT::datatable(
      df,
      rownames = FALSE,
      escape   = FALSE,
      width    = "100%",
      options  = list(
        pageLength = 50,
        dom        = "ft",
        order      = list(list(0L, "asc")),
        columnDefs = list(
          list(width = "18%",  targets = 0L),
          list(width = "16%",  targets = 1L),
          list(width = "66%",  targets = 2L)
        )
      ),
      class = "stripe hover"
    )
  }, server = FALSE)

  # ── Reset ─────────────────────────────────────────────────────────────────
  observeEvent(input$btn_reset, {
    selected_category(NULL)
    updateTextInput(  session, "keyword",    value    = "")
    updateSliderInput(session, "year_range", value    = YEAR_DEFAULT)
    updateSelectInput(session, "f_field",
      choices  = field_choices,
      selected = "All"
    )
    updateSelectInput(session, "f_contrib", selected = "All")
    updateSelectInput(session, "f_affil",   selected = "All")
  })

  # ── Institution Map ──────────────────────────────────────────────────────────

  map_filtered <- reactive({
    df <- pubs
    yr <- input$map_year_range
    df <- filter(df, !is.na(year), year >= yr[1L], year <= yr[2L])
    ct <- input$map_contrib
    if (!isTRUE(ct == "All"))
      df <- filter(df, contribution_type == ct)
    df
  })

  map_counts <- reactive({
    rk <- map_filtered()$record_key

    # Country counts: one (record_key, country) pair counts at most once
    country_n <- geo_country_base |>
      filter(record_key %in% rk) |>
      distinct(record_key, country) |>
      count(country, name = "n")

    # US state counts from geo_inst_base; deduplicate per (paper, state)
    state_n <- geo_inst_base |>
      filter(record_key %in% rk, country == "United States", !is.na(state)) |>
      distinct(record_key, state) |>
      count(state, name = "n")

    # National-scope US: US institutions with no state assigned
    nat_rk <- unique(geo_inst_base$record_key[
      geo_inst_base$record_key %in% rk &
      geo_inst_base$country == "United States" &
      is.na(geo_inst_base$state)
    ])
    national_n <- length(nat_rk)
    national_top <- if (national_n > 0L) {
      geo_inst_base |>
        filter(record_key %in% nat_rk,
               country == "United States", is.na(state)) |>
        distinct(record_key, canonical) |>
        count(canonical, name = "n") |>
        arrange(desc(n)) |>
        head(3L) |>
        pull(canonical)
    } else character(0L)

    # Publications with no geo data at all
    rk_with_geo <- unique(geo_country_base$record_key)
    no_geo_n <- sum(!rk %in% rk_with_geo)

    # Top-5 institutions per country (for popups)
    country_inst <- geo_inst_base |>
      filter(record_key %in% rk) |>
      distinct(record_key, country, canonical) |>
      count(country, canonical, name = "n") |>
      group_by(country) |>
      slice_max(n, n = 5L, with_ties = FALSE) |>
      ungroup()

    # Top-5 institutions per state (for popups)
    state_inst <- geo_inst_base |>
      filter(record_key %in% rk, !is.na(state)) |>
      distinct(record_key, state, canonical) |>
      count(state, canonical, name = "n") |>
      group_by(state) |>
      slice_max(n, n = 5L, with_ties = FALSE) |>
      ungroup()

    list(
      country_n    = country_n,
      state_n      = state_n,
      national_n   = national_n,
      national_top = national_top,
      no_geo_n     = no_geo_n,
      country_inst = country_inst,
      state_inst   = state_inst
    )
  })

  map_layer_data <- reactive({
    mc <- map_counts()
    cn <- mc$country_n
    sn <- mc$state_n
    ci <- mc$country_inst
    si <- mc$state_inst

    all_n    <- c(cn$n, sn$n)
    max_logn <- if (length(all_n) > 0L && max(all_n) > 1L) max(log1p(all_n)) else log1p(2L)

    pal <- colorNumeric(
      palette  = c("#eef7eb", "#bdddb9", "#79bb73", "#3e9438", "#1f6b1c", "#0b3f09"),
      domain   = c(log1p(1), max_logn),
      na.color = "#ffffff"
    )

    # Harmonize country names and aggregate (guards against multiple LLM names
    # mapping to the same Natural Earth admin polygon)
    cn_h <- cn |>
      mutate(admin = .harmonize_country(country)) |>
      group_by(admin) |>
      summarize(n = sum(n), .groups = "drop")

    world_data <- world_sf |>
      left_join(cn_h, by = "admin") |>
      mutate(n = coalesce(n, 0L), log_n = log1p(n))

    make_inst_lines <- function(inst_df) {
      if (nrow(inst_df) == 0L) return("")
      paste0(
        "<br><span style='font-size:0.78rem;color:#4a6080'>Top institutions:</span><br>",
        paste(
          paste0(htmltools::htmlEscape(inst_df$canonical), " — ", inst_df$n),
          collapse = "<br>"
        )
      )
    }

    world_labels <- sprintf(
      "<strong>%s</strong> — %s",
      world_data$admin,
      ifelse(world_data$n > 0L,
             paste0(world_data$n, " pub", ifelse(world_data$n == 1L, "", "s")),
             "No publications")
    )

    world_popups <- vapply(seq_len(nrow(world_data)), function(i) {
      nm   <- world_data$admin[i]
      n    <- world_data$n[i]
      orig <- cn$country[.harmonize_country(cn$country) == nm]
      inst_sub <- ci[ci$country %in% orig, ]
      if (n == 0L) return(paste0(
        "<strong>", htmltools::htmlEscape(nm),
        "</strong><br>No publications in the current selection."))
      paste0("<strong>", htmltools::htmlEscape(nm), "</strong><br>",
             n, " publication", if (n == 1L) "" else "s",
             make_inst_lines(inst_sub))
    }, character(1L))

    us_data <- states_sf |>
      left_join(sn, by = c("name" = "state")) |>
      mutate(n = coalesce(n, 0L), log_n = log1p(n))

    us_labels <- sprintf(
      "<strong>%s</strong> — %s",
      us_data$name,
      ifelse(us_data$n > 0L,
             paste0(us_data$n, " pub", ifelse(us_data$n == 1L, "", "s")),
             "No publications")
    )

    us_popups <- vapply(seq_len(nrow(us_data)), function(i) {
      nm <- us_data$name[i]
      n  <- us_data$n[i]
      inst_sub <- si[si$state == nm, ]
      if (n == 0L) return(paste0(
        "<strong>", htmltools::htmlEscape(nm),
        "</strong><br>No publications in the current selection."))
      paste0("<strong>", htmltools::htmlEscape(nm), "</strong><br>",
             n, " publication", if (n == 1L) "" else "s",
             make_inst_lines(inst_sub))
    }, character(1L))

    # Legend at meaningful raw-count breakpoints
    legend_breaks <- c(1L, 5L, 10L, 50L, 100L, 500L)
    if (length(all_n) > 0L && max(all_n) > 0L)
      legend_breaks <- legend_breaks[legend_breaks <= max(all_n)]
    if (length(legend_breaks) == 0L) legend_breaks <- 1L
    legend_colors <- c("#ffffff", pal(log1p(legend_breaks)))
    legend_labels <- c("0", as.character(legend_breaks))

    list(
      pal           = pal,
      world_data    = world_data,
      world_labels  = world_labels,
      world_popups  = world_popups,
      us_data       = us_data,
      us_labels     = us_labels,
      us_popups     = us_popups,
      legend_colors = legend_colors,
      legend_labels = legend_labels
    )
  })

  add_map_layers <- function(map, layer_data) {
    poly_style <- list(fillOpacity = 0.75, color = "white", weight = 0.6, opacity = 1)
    hl_opts <- highlightOptions(weight = 2, color = "#1a2f4a",
                                fillOpacity = 0.9, bringToFront = TRUE)
    lbl_opts <- labelOptions(style = list(
      "font-size"   = "0.82rem",
      "font-family" = "'Helvetica Neue', Arial, sans-serif",
      "padding"     = "4px 8px"
    ))

    map |>
      addPolygons(
        data             = layer_data$world_data,
        fillColor        = ~layer_data$pal(ifelse(n == 0L, NA_real_, log_n)),
        fillOpacity      = poly_style$fillOpacity,
        color            = poly_style$color,
        weight           = poly_style$weight,
        opacity          = poly_style$opacity,
        label            = lapply(layer_data$world_labels, htmltools::HTML),
        labelOptions     = lbl_opts,
        popup            = layer_data$world_popups,
        highlightOptions = hl_opts
      ) |>
      addPolygons(
        data             = layer_data$us_data,
        fillColor        = ~layer_data$pal(ifelse(n == 0L, NA_real_, log_n)),
        fillOpacity      = poly_style$fillOpacity,
        color            = poly_style$color,
        weight           = poly_style$weight,
        opacity          = poly_style$opacity,
        label            = lapply(layer_data$us_labels, htmltools::HTML),
        labelOptions     = lbl_opts,
        popup            = layer_data$us_popups,
        highlightOptions = hl_opts
      ) |>
      addLegend(
        position = "bottomright",
        colors   = layer_data$legend_colors,
        labels   = layer_data$legend_labels,
        title    = "Publications",
        opacity  = 0.85,
        layerId  = "dwr-map-legend"
      )
  }

  output$institution_map <- renderLeaflet({
    leaflet(options = leafletOptions(zoomControl = TRUE)) |>
      addProviderTiles("Esri.WorldGrayCanvas") |>
      setView(lng = 10, lat = 20, zoom = 2) |>
      add_map_layers(map_layer_data())
  })

  observe({
    input$main_tabs  # re-draw when user switches to the map tab
    layer_data <- map_layer_data()

    leafletProxy("institution_map") |>
      clearShapes() |>
      removeControl("dwr-map-legend") |>
      add_map_layers(layer_data)
  })

  observeEvent(input$map_reset_view, {
    leafletProxy("institution_map") |>
      setView(lng = 10, lat = 20, zoom = 2)
  })

  output$map_notes_ui <- renderUI({
    mc <- map_counts()
    notes <- list()

    if (mc$national_n > 0L) {
      top_str <- if (length(mc$national_top) > 0L)
        paste0(" Top: ", paste(mc$national_top, collapse = "; "), ".")
      else ""
      notes[[length(notes) + 1L]] <- div(class = "map-note-item",
        span(class = "map-note-lbl", "National-scope US institutions:"),
        span(paste0(
          mc$national_n, " publication",
          if (mc$national_n == 1L) "" else "s",
          " involve US institutions without a single-state footprint",
          " and are not attributed to any state on the map.", top_str
        ))
      )
    }

    if (mc$no_geo_n > 0L) {
      notes[[length(notes) + 1L]] <- div(class = "map-note-item",
        span(class = "map-note-lbl", "Publications without geo data:"),
        span(paste0(
          mc$no_geo_n, " publication",
          if (mc$no_geo_n == 1L) "" else "s",
          " have no affiliated institution geo data and are not shown on the map."
        ))
      )
    }

    if (length(notes) == 0L) return(NULL)
    div(class = "map-notes-bar", notes)
  })

  # ── Publishing Network ────────────────────────────────────────────────────────

  # Debounced slider inputs to avoid continuous re-render while dragging
  net_year_range_d <- debounce(reactive(input$net_year_range), 400)
  net_top_n_d      <- debounce(reactive(input$net_top_n),      400)

  # Filtered pair base table for the active network mode
  net_base <- reactive({
    mode <- input$net_mode
    base <- if (isTRUE(mode == "Institutions")) network_inst_base else network_author_base

    empty <- data.frame(
      node_a = character(0), node_b = character(0),
      record_key = character(0), year = integer(0),
      contribution_type = character(0), pc_field = character(0),
      stringsAsFactors = FALSE
    )
    if (is.null(base) || nrow(base) == 0L) return(empty)

    yr <- net_year_range_d()
    base <- base[!is.na(base$year) & base$year >= yr[1L] & base$year <= yr[2L], ]

    ct <- input$net_contrib
    if (!isTRUE(ct == "All"))
      base <- base[!is.na(base$contribution_type) & base$contribution_type == ct, ]

    fld <- input$net_field
    if (!isTRUE(fld == "All"))
      base <- base[!is.na(base$pc_field) & base$pc_field == fld, ]

    base
  })

  # Build visNetwork nodes/edges from the filtered base
  net_graph <- reactive({
    base  <- net_base()
    mode  <- input$net_mode
    n_top <- as.integer(net_top_n_d())

    empty_graph <- list(
      nodes      = data.frame(id = character(0), stringsAsFactors = FALSE),
      edges      = data.frame(id = integer(0), from = character(0),
                              to = character(0), stringsAsFactors = FALSE),
      edge_lookup = data.frame(id = integer(0), node_a = character(0),
                               node_b = character(0), stringsAsFactors = FALSE),
      n_papers   = 0L
    )

    if (nrow(base) == 0L) return(empty_graph)

    # Aggregate: count distinct papers per unique node pair
    edges_agg <- base |>
      group_by(node_a, node_b) |>
      summarize(n_papers = n_distinct(record_key), .groups = "drop") |>
      as.data.frame()

    # Node degree (number of distinct neighbors)
    deg_tbl    <- table(c(edges_agg$node_a, edges_agg$node_b))
    deg_sorted <- sort(deg_tbl, decreasing = TRUE)

    # Top-N nodes; always include .DWR_NODE in Institutions mode
    top_nodes <- names(head(deg_sorted, n_top))
    if (isTRUE(mode == "Institutions") &&
        .DWR_NODE %in% names(deg_tbl) &&
        !.DWR_NODE %in% top_nodes)
      top_nodes <- c(top_nodes, .DWR_NODE)

    # Restrict edges to top-N nodes
    edges_agg <- edges_agg[
      edges_agg$node_a %in% top_nodes & edges_agg$node_b %in% top_nodes, ,
      drop = FALSE
    ]

    # All nodes that appear in retained edges, plus DWR if it has edges
    all_nodes <- unique(c(edges_agg$node_a, edges_agg$node_b))
    if (isTRUE(mode == "Institutions") && .DWR_NODE %in% names(deg_tbl))
      all_nodes <- unique(c(all_nodes, .DWR_NODE))

    if (length(all_nodes) == 0L) return(empty_graph)

    degrees <- as.integer(deg_tbl[all_nodes])
    degrees[is.na(degrees)] <- 0L

    # Paper count per node: distinct papers in the current filter involving each node
    node_rk      <- unique(rbind(
      data.frame(node = base$node_a, record_key = base$record_key, stringsAsFactors = FALSE),
      data.frame(node = base$node_b, record_key = base$record_key, stringsAsFactors = FALSE)
    ))
    paper_ct     <- table(node_rk$node)
    paper_counts <- as.integer(paper_ct[all_nodes])
    paper_counts[is.na(paper_counts)] <- 0L

    # ── Node data frame ────────────────────────────────────────────────────────
    nodes_df <- data.frame(
      id    = all_nodes,
      label = substr(all_nodes, 1L, 28L),
      title = paste0("<b>", all_nodes, "</b><br>",
                     paper_counts, " paper", ifelse(paper_counts == 1L, "", "s")),
      size  = pmax(12, 8 + log1p(paper_counts) * 4.5),
      stringsAsFactors = FALSE
    )

    if (isTRUE(mode == "Institutions")) {
      is_dwr  <- nodes_df$id == .DWR_NODE
      ctrs    <- inst_country_map[nodes_df$id]
      is_us   <- !is.na(ctrs) & ctrs == "United States"
      is_intl <- !is.na(ctrs) & ctrs != "United States"

      nodes_df$color.background         <- ifelse(is_dwr, "#1a2f4a",
                                            ifelse(is_us, "#4da87a",
                                            ifelse(is_intl, "#4a9cad", "#aaaaaa")))
      nodes_df$color.border              <- ifelse(is_dwr, "#7dc3d0", "#d8e8d8")
      nodes_df$color.highlight.background <- ifelse(is_dwr, "#2e4d72",
                                              ifelse(is_us | is_intl, "#2d7a5f", "#888888"))
      nodes_df$font.color                <- ifelse(is_dwr, "white", "#1a2f4a")
      nodes_df$borderWidth               <- ifelse(is_dwr, 3L, 1L)
      nodes_df$size                      <- ifelse(is_dwr, pmax(nodes_df$size, 42), nodes_df$size)
      nodes_df$fixed.x                   <- is_dwr
      nodes_df$fixed.y                   <- is_dwr
      nodes_df$x                         <- ifelse(is_dwr, 0, NA_real_)
      nodes_df$y                         <- ifelse(is_dwr, 0, NA_real_)
    } else {
      nodes_df$color.background          <- "#4da87a"
      nodes_df$color.border              <- "#d8e8d8"
      nodes_df$color.highlight.background <- "#2d7a5f"
      nodes_df$font.color                <- "#1a2f4a"
      nodes_df$borderWidth               <- 1L
    }

    # ── Edge data frame ────────────────────────────────────────────────────────
    edge_n <- nrow(edges_agg)
    edges_df <- data.frame(
      id    = seq_len(edge_n),
      from  = edges_agg$node_a,
      to    = edges_agg$node_b,
      width = 1 + log1p(edges_agg$n_papers) * 2,
      title = paste0(edges_agg$n_papers, " paper",
                     ifelse(edges_agg$n_papers == 1L, "", "s")),
      stringsAsFactors = FALSE
    )

    # Edge lookup (id → node pair) used by the edge click handler
    edge_lookup <- data.frame(
      id     = seq_len(edge_n),
      node_a = edges_agg$node_a,
      node_b = edges_agg$node_b,
      stringsAsFactors = FALSE
    )

    list(
      nodes       = nodes_df,
      edges       = edges_df,
      edge_lookup = edge_lookup,
      n_papers    = n_distinct(base$record_key)
    )
  })

  # ── Render the network ────────────────────────────────────────────────────────
  output$network_graph <- visNetwork::renderVisNetwork({
    g <- net_graph()

    if (nrow(g$nodes) == 0L) {
      return(
        visNetwork::visNetwork(
          nodes = data.frame(
            id = 1L,
            label = "No connections found for current filters",
            color.background = "#eef1f5", color.border = "#dde3ea",
            font.color = "#7a8a9a", size = 20L,
            stringsAsFactors = FALSE
          ),
          edges = data.frame(from = integer(0), to = integer(0),
                             stringsAsFactors = FALSE)
        ) |>
          visNetwork::visOptions(physics = FALSE)
      )
    }

    visNetwork::visNetwork(g$nodes, g$edges) |>
      visNetwork::visPhysics(
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
      visNetwork::visInteraction(
        dragNodes         = TRUE,
        zoomView          = TRUE,
        navigationButtons = TRUE,
        hover             = TRUE
      ) |>
      visNetwork::visOptions(
        highlightNearest = list(enabled = TRUE, degree = 1, hover = TRUE)
      ) |>
      visNetwork::visEdges(
        color  = list(color = "#cccccc", highlight = "#4da87a", opacity = 0.85),
        smooth = FALSE
      ) |>
      visNetwork::visEvents(
        click = "function(params) {
          if (params.nodes.length > 0) {
            Shiny.setInputValue('net_node_click',
              {node: params.nodes[0], nonce: Math.random()},
              {priority: 'event'});
          } else if (params.edges.length > 0) {
            Shiny.setInputValue('net_edge_click',
              {edge: params.edges[0], nonce: Math.random()},
              {priority: 'event'});
          }
        }"
      ) |>
      visNetwork::visLegend(
        useGroups = FALSE,
        position  = "right",
        width     = 0.24,
        ncol      = 1,
        addNodes  = if (isTRUE(input$net_mode == "Institutions")) {
          data.frame(
            label            = c("DWR", "US Institution", "International", "Unknown geo"),
            shape            = "dot",
            color.background = c("#1a2f4a", "#4da87a", "#4a9cad", "#aaaaaa"),
            color.border     = c("#7dc3d0", "#d8e8d8", "#d8e8d8", "#d8e8d8"),
            size             = 12,
            stringsAsFactors = FALSE
          )
        } else {
          data.frame(
            label            = "Author",
            shape            = "dot",
            color.background = "#4da87a",
            color.border     = "#d8e8d8",
            size             = 12,
            stringsAsFactors = FALSE
          )
        }
      )
  })

  # Re-fit the network when the user navigates to the Publishing Network tab
  observeEvent(input$main_tabs, {
    if (isTRUE(input$main_tabs == "Publishing Network")) {
      visNetwork::visNetworkProxy("network_graph") |> visNetwork::visFit()
    }
  })

  # ── Modal content builder (inline — avoids uiOutput race condition) ───────────
  .net_paper_table <- function(papers) {
    if (nrow(papers) == 0L)
      return(p(style = "font-size:0.82rem; color:#4a6080; padding:8px 0",
               "No papers in the current view for this selection."))

    rows <- lapply(seq_len(min(nrow(papers), 50L)), function(i) {
      r   <- papers[i, ]
      ttl <- substr(coalesce(r$title, ""), 1L, 80L)
      if (nchar(coalesce(r$title, "")) > 80L) ttl <- paste0(ttl, "…")
      title_cell <- if (!is.na(r$doi))
        tags$a(ttl, href   = paste0("https://doi.org/", r$doi),
               target = "_blank",
               style  = "color:#4a9cad; text-decoration:underline")
      else
        tags$span(ttl)
      tags$tr(
        tags$td(title_cell,                         style = "width:54%; padding:5px 8px; vertical-align:top"),
        tags$td(coalesce(as.character(r$year), ""), style = "width:7%;  padding:5px 8px; vertical-align:top"),
        tags$td(coalesce(r$contribution_type, ""),  style = "width:17%; padding:5px 8px; vertical-align:top"),
        tags$td(coalesce(r$first_author, ""),       style = "width:22%; padding:5px 8px; vertical-align:top")
      )
    })

    tagList(
      if (nrow(papers) > 50L)
        p(style = "font-size:0.76rem; color:#7a8a9a; margin-bottom:6px",
          paste0("Showing first 50 of ", nrow(papers), " papers.")),
      tags$table(
        class = "table table-sm table-striped table-hover",
        style = "font-size:0.8rem; width:100%; margin-bottom:0",
        tags$thead(
          style = "background:#f5f7f9",
          tags$tr(
            tags$th("Title",        style = "font-weight:700; color:#1a2f4a; padding:6px 8px"),
            tags$th("Year",         style = "font-weight:700; color:#1a2f4a; padding:6px 8px"),
            tags$th("Contribution", style = "font-weight:700; color:#1a2f4a; padding:6px 8px"),
            tags$th("First Author", style = "font-weight:700; color:#1a2f4a; padding:6px 8px")
          )
        ),
        tags$tbody(rows)
      )
    )
  }

  # ── Node click → paper list modal ─────────────────────────────────────────────
  observeEvent(input$net_node_click, {
    req(input$net_node_click)
    node_id <- as.character(input$net_node_click$node)
    mode    <- isolate(input$net_mode)
    base    <- isolate(net_base())

    lookup  <- if (isTRUE(mode == "Institutions")) inst_to_records else author_to_records
    rk_node <- lookup[[node_id]]
    if (is.null(rk_node)) rk_node <- character(0L)

    rk_show <- intersect(rk_node, unique(base$record_key))
    papers  <- pubs[pubs$record_key %in% rk_show, ] |> arrange(desc(year))

    modal_title <- paste0(
      substr(node_id, 1L, 60L),
      if (nchar(node_id) > 60L) "…" else "",
      " — ", nrow(papers), " paper", if (nrow(papers) == 1L) "" else "s"
    )
    showModal(modalDialog(
      title     = modal_title,
      .net_paper_table(papers),
      easyClose = TRUE,
      footer    = modalButton("Close"),
      size      = "l"
    ))
  })

  # ── Edge click → shared-paper list modal ──────────────────────────────────────
  observeEvent(input$net_edge_click, {
    req(input$net_edge_click)
    edge_id <- as.integer(input$net_edge_click$edge)
    g       <- isolate(net_graph())
    base    <- isolate(net_base())
    mode    <- isolate(input$net_mode)

    erow <- g$edge_lookup[g$edge_lookup$id == edge_id, ]
    if (nrow(erow) == 0L) return()

    node_a <- erow$node_a[1L]
    node_b <- erow$node_b[1L]
    lookup <- if (isTRUE(mode == "Institutions")) inst_to_records else author_to_records
    rk_a   <- lookup[[node_a]]; if (is.null(rk_a)) rk_a <- character(0L)
    rk_b   <- lookup[[node_b]]; if (is.null(rk_b)) rk_b <- character(0L)

    rk_show <- intersect(intersect(rk_a, rk_b), unique(base$record_key))
    papers  <- pubs[pubs$record_key %in% rk_show, ] |> arrange(desc(year))

    short_a <- paste0(substr(node_a, 1L, 35L), if (nchar(node_a) > 35L) "…" else "")
    short_b <- paste0(substr(node_b, 1L, 35L), if (nchar(node_b) > 35L) "…" else "")
    modal_title <- paste0(
      short_a, " – ", short_b,
      " — ", nrow(papers), " shared paper", if (nrow(papers) == 1L) "" else "s"
    )
    showModal(modalDialog(
      title     = modal_title,
      .net_paper_table(papers),
      easyClose = TRUE,
      footer    = modalButton("Close"),
      size      = "l"
    ))
  })

  # ── Stats bar ─────────────────────────────────────────────────────────────────
  output$net_stats_bar <- renderUI({
    g    <- net_graph()
    mode <- input$net_mode
    node_word <- if (isTRUE(mode == "Institutions")) "institutions" else "authors"
    div(class = "net-stats-bar",
      HTML(paste0(
        "Showing <strong>", nrow(g$nodes), "</strong> ", node_word,
        " · <strong>", nrow(g$edges), "</strong> edges",
        " · <strong>", g$n_papers, "</strong> paper",
        if (g$n_papers == 1L) "" else "s", " in current filter"
      ))
    )
  })

  # ── Disambiguation note (People mode only) ────────────────────────────────────
  output$net_disambig_note <- renderUI({
    if (!isTRUE(input$net_mode == "People")) return(NULL)
    div(class = "net-stats-bar",
      style = "color:#7a8a9a; font-style:italic",
      "Author names appear as recorded in Scopus (“Last F.”). Different researchers
       sharing the same name and initials may appear as a single node."
    )
  })

  # ── Reset ─────────────────────────────────────────────────────────────────────
  observeEvent(input$net_reset, {
    updateSliderInput(session, "net_year_range", value    = YEAR_DEFAULT)
    updateSelectInput(session, "net_contrib",   selected = "All")
    updateSelectInput(session, "net_field",     selected = "All")
    updateRadioButtons(session, "net_mode",     selected = "Institutions")
    updateSliderInput(session, "net_top_n",     value    = 25L)
  })

}

shinyApp(ui, server)
