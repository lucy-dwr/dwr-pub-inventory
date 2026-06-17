library(shiny)
library(bslib)
library(plotly)
library(DT)
library(dplyr)
library(arrow)
library(stringr)
library(shinychat)
library(ellmer)

# ── Paths ──────────────────────────────────────────────────────────────────────
if (basename(getwd()) == "shiny") setwd("..")
.ROOT <- getwd()

source(file.path(.ROOT, "R", "load_pipeline_config.R"))
pipeline_config <- load_pipeline_config(file.path(.ROOT, "config", "pipeline.yml"))

# ── Load data ──────────────────────────────────────────────────────────────────
pubs_raw <- arrow::read_parquet(file.path(.ROOT, "data/generated/dwr_publications.parquet"))

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

# ── Filter choices (built once) ────────────────────────────────────────────────
all_affiliations <- sort(unique(na.omit(unlist(pubs_raw$affiliations))))
all_affiliations <- all_affiliations[nchar(trimws(all_affiliations)) > 0L]
field_choices    <- c("All", sort(unique(na.omit(pubs$pc_field))))

author_divs_raw  <- unique(trimws(unlist(strsplit(na.omit(pubs_raw$author_division), ";"))))
funder_divs_raw  <- unique(trimws(na.omit(pubs_raw$funding_division)))
all_divisions    <- sort(setdiff(unique(c(author_divs_raw, funder_divs_raw)), c("Unknown", "")))
division_choices <- c("All", all_divisions)
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

# ── Chat system prompt (built once at startup) ─────────────────────────────────
top_affiliations <- head(all_affiliations, 60L)
chat_system_prompt <- paste0(
  "You are a helpful assistant for the DWR Peer-Reviewed Publication Inventory ",
  "dashboard, used by the California Department of Water Resources (DWR). ",
  "You have access to the following tools — pick the right one for each request.\n\n",

  "TOOLS AND WHEN TO USE THEM\n",
  "set_filters       — User wants to filter/show/display a subset of data ",
  "(e.g. 'show sturgeon papers', 'hydrology papers from 2018', 'lead-authored only'). ",
  "Supports keyword (topic/species/place-name), year, science field/category, division, ",
  "contribution type, and affiliation. Use keyword='sturgeon' for topic-based filtering. ",
  "Prefer set_filters when the user says 'filter', 'show', or 'display'; ",
  "prefer find_papers when the user says 'find' or 'search' without wanting to change the view.\n",
  "reset_filters     — User says 'start over', 'clear', 'reset', or similar.\n",
  "count_by          — User asks for a breakdown or frequency table ",
  "(e.g. 'how many papers per division?', 'top journals').\n",
  "get_trend         — User asks about change over time ",
  "(e.g. 'is output growing?', 'when did ISE peak?').\n",
  "compare_periods   — User wants to compare two time periods ",
  "(e.g. 'before and after 2020').\n",
  "find_papers       — User wants to find papers on a topic without setting filters ",
  "(e.g. 'find papers about groundwater recharge'). Searches the full inventory.\n",
  "filter_to_papers  — After find_papers, user wants the dashboard to show ONLY those ",
  "specific results. Pass the record_keys from find_papers output. ",
  "Also use when user says 'filter to those', 'show just those papers', etc.\n",
  "get_paper_detail  — User asks for details on a specific paper by title or DOI.\n",
  "synthesize_selection — User asks for a summary or thematic analysis of the *currently ",
  "visible* papers. Retrieves titles + abstracts; you synthesize them.\n",
  "get_author_stats  — User asks who the most prolific authors are.\n",
  "get_collaboration_stats — User asks about external partners or collaborating institutions.\n",
  "cite_papers       — User wants formatted citations for the current selection.\n\n",

  "AVAILABLE FILTER VALUES\n",
  "Year range: ", year_min, "–", year_max,
  " (default view: ", YEAR_DEFAULT[1L], "–", YEAR_DEFAULT[2L], ")\n",
  "Science Categories: ", paste(all_categories, collapse = "; "), "\n",
  "Science Fields: ", paste(field_choices[-1L], collapse = "; "), "\n",
  "Divisions: ", paste(all_divisions, collapse = "; "), "\n",
  "Contribution Types: ", paste(CONTRIB_LEVELS, collapse = ", "), "\n",
  "Common Affiliations (sample of ", length(all_affiliations), " total): ",
  paste(top_affiliations, collapse = "; "), "\n\n",

  "GENERAL RULES\n",
  "- Prefer tools over prose wherever possible.\n",
  "- When intent is ambiguous between filtering and synthesis, ask for clarification.\n",
  "- set_filters and reset_filters update the UI; always confirm what changed.\n",
  "- synthesize_selection only covers the *current* filtered view; use find_papers ",
  "to search the whole inventory.\n",
  "- Be professional, direct, and suited to a government science context.\n\n",

  "STYLE — follow these rules precisely:\n",
  "- No emoji. Ever.\n",
  "- No obsequious openers. Never start with 'Great question!', 'Absolutely!', ",
  "'Of course!', 'Certainly!', 'Happy to help!', or any similar filler. ",
  "Get straight to the answer.\n",
  "- No markdown headings (##, ###). They render as oversized text. Use bold (**word**) ",
  "for emphasis if needed, or plain prose and simple bullet lists.\n",
  "- Do not adopt or refer to yourself by any name or persona.\n\n",

  "OUT-OF-SCOPE REQUESTS:\n",
  "If asked about something unrelated to the DWR publication inventory, note the scope ",
  "in one sentence and, if a relevant official California resource exists, point to it ",
  "(e.g. water.ca.gov for general DWR questions, ca.gov for other state agencies). ",
  "Do not apologize at length. Do not provide resources for topics unrelated to ",
  "California state government. Example for a DWR question: 'That is outside the scope ",
  "of this tool, which covers DWR peer-reviewed publications. For general information ",
  "about DWR programs, visit water.ca.gov.' Example for an unrelated topic: ",
  "'That is outside the scope of this tool. Is there something in the publication ",
  "inventory I can help with?'"
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
  .btn-chat-toggle { background: #2d7a5f !important; }
  .btn-chat-toggle:hover, .btn-chat-toggle:focus { background: #235f4a !important; }
  .btn-chat-toggle.is-open { background: #4a6080 !important; }
  .btn-chat-toggle.is-open:hover { background: #3a5070 !important; }

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
    transition: flex-basis 0.25s ease;
  }
  .panel-right {
    flex: 1;
    min-width: 0;
    overflow: hidden;
  }
  .chat-sidebar {
    flex: 0 0 0;
    overflow: hidden;
    min-width: 0;
    transition: flex-basis 0.25s ease;
  }
  .main-layout.chat-open .panel-left  { flex-basis: 33%; }
  .main-layout.chat-open .chat-sidebar {
    flex: 0 0 340px;
    overflow: visible;
  }
  .chat-sidebar-inner {
    width: 340px;
    background: white;
    border-radius: 4px;
    box-shadow: 0 1px 3px rgba(0,0,0,0.08);
    display: flex;
    flex-direction: column;
    height: calc(100vh - 180px);
    min-height: 500px;
    overflow: hidden;
  }
  .chat-sidebar-title {
    font-size: 0.87rem; font-weight: 600; color: white;
    background: #2d7a5f;
    padding: 10px 14px;
    border-radius: 4px 4px 0 0;
    flex-shrink: 0;
    display: flex; align-items: flex-start; justify-content: space-between;
  }
  .chat-sidebar-title small {
    display: block; font-weight: 400;
    font-size: 0.72rem; opacity: 0.85; margin-top: 2px;
  }
  .btn-chat-restart {
    background: none !important; border: 1px solid rgba(255,255,255,0.4) !important;
    color: rgba(255,255,255,0.85) !important; font-size: 0.66rem !important;
    padding: 2px 7px !important; border-radius: 3px !important;
    box-shadow: none !important;
    flex-shrink: 0; margin-top: 1px; white-space: nowrap;
  }
  .btn-chat-restart:hover, .btn-chat-restart:focus, .btn-chat-restart:active {
    background: rgba(255,255,255,0.15) !important;
    border-color: rgba(255,255,255,0.6) !important;
    color: white !important;
    box-shadow: none !important;
    outline: none !important;
  }

  /* Paper-selection filter banner */
  .papers-banner {
    background: #f0f5f0; border: 1px solid #b8d8b8;
    border-radius: 4px; padding: 6px 12px;
    font-size: 0.76rem; color: #2d7a5f;
    display: flex; align-items: center; justify-content: space-between;
    margin-bottom: 10px;
  }
  .papers-banner a { color: #7a8a9a; font-weight: 700; text-decoration: none; margin-left: 10px; }
  .papers-banner a:hover { color: #2d7a5f; }
  /* Hide tool call/result cards — show final responses only */
  .chat-sidebar-inner shiny-tool-request,
  .chat-sidebar-inner shiny-tool-result { display: none !important; }

  /* shinychat fills the remaining space */
  .chat-sidebar-inner .shiny-chat-container {
    flex: 1;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }
  /* Smaller text and flat headings in the chat pane */
  .chat-sidebar-inner p,
  .chat-sidebar-inner li,
  .chat-sidebar-inner td,
  .chat-sidebar-inner pre,
  .chat-sidebar-inner code {
    font-size: 0.78rem !important;
    line-height: 1.5;
  }
  .chat-sidebar-inner h1,
  .chat-sidebar-inner h2,
  .chat-sidebar-inner h3,
  .chat-sidebar-inner h4 {
    font-size: 0.82rem !important;
    font-weight: 600;
    margin: 5px 0 3px;
  }
  /* Match input textarea to chat body font size */
  .chat-sidebar-inner textarea {
    font-size: 0.78rem !important;
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

  /* ── Active-filter badge (pie / division) ── */
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

      // ── Chat sidebar toggle ──────────────────────────────────────────────────
      $(document).on('click', '#btn_chat_toggle', function() {
        var layout   = document.querySelector('.main-layout');
        var isOpen   = layout.classList.toggle('chat-open');
        var btn      = document.getElementById('btn_chat_toggle');
        btn.innerHTML = isOpen ? 'Close chat' : 'Ask the data &#10022;';
        btn.classList.toggle('is-open', isOpen);
        setTimeout(function() { window.dispatchEvent(new Event('resize')); }, 260);
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

  # ── Controls bar ────────────────────────────────────────────────────────────
  div(class = "ctrls-bar",
    div(class = "kw-wrap",
      textInput("keyword", label = NULL,
        placeholder = "\u25bc  Enter Keyword Search", width = "100%")
    ),
    div(class = "ctrls-spacer"),
    actionButton("btn_sci",   "Science Category & Field Classification", class = "btn-dwr"),
    actionButton("btn_about", "About the Inventory",                     class = "btn-dwr"),
    actionButton("btn_reset", "Reset",                                   class = "btn-dwr"),
    tags$button(
      id    = "btn_chat_toggle",
      class = "btn-dwr btn-chat-toggle",
      HTML("Ask the data &#10022;")
    )
  ),

  # ── Main content ─────────────────────────────────────────────────────────────
  div(class = "main-wrap",
    div(class = "main-layout",

      # ── Left panel ──────────────────────────────────────────────────────────
      div(class = "panel-left",
        # Featured article
        div(class = "pcrd", uiOutput("featured_ui")),

        # Science Category pie chart
        div(class = "pcrd",
          div(class = "pcrd-title", "Science Category"),
          uiOutput("cat_filter_badge"),
          plotlyOutput("pie_category", height = "310px")
        ),

        # Articles by Division
        div(class = "pcrd",
          div(class = "pcrd-title", "Articles by Division"),
          plotlyOutput("bar_division", height = "500px")
        )
      ),

      # ── Right panel ─────────────────────────────────────────────────────────
      div(class = "panel-right",
        # Filter dropdowns
        div(class = "pcrd filt-row",
          fluidRow(
            column(3,
              selectInput("f_div", "Division",
                choices = division_choices, width = "100%")
            ),
            column(3,
              selectInput("f_field", "Science Field",
                choices = field_choices, width = "100%")
            ),
            column(3,
              selectInput("f_contrib", "Contribution Type",
                choices = c("All", CONTRIB_LEVELS), width = "100%")
            ),
            column(3,
              selectInput("f_affil", "Author Affiliation",
                choices = c("All", all_affiliations), width = "100%")
            )
          )
        ),

        # Paper selection banner (shown when filter_to_papers is active)
        uiOutput("papers_filter_banner"),

        # Summary stat boxes
        uiOutput("stat_boxes"),

        # Publications by Year chart + year slider
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

        # Article table
        div(class = "pcrd",
          DT::dataTableOutput("article_table")
        )
      ),

      # ── Chat sidebar ─────────────────────────────────────────────────────────
      div(class = "chat-sidebar",
        div(class = "chat-sidebar-inner",
          div(class = "chat-sidebar-title",
            div(
              "\u2736 Ask the data",
              tags$small("Search, filter, summarize, and analyze DWR publications")
            ),
            actionButton(
              "btn_chat_restart", "\u21ba New chat",
              class = "btn-chat-restart",
              title = "Clear conversation and start over"
            )
          ),
          shinychat::chat_mod_ui(
            "chat",
            placeholder = "e.g. Show hydrology papers from 2015\u20132022\u2026"
          )
        )
      )

    )
  ),

  # ── Footer ──────────────────────────────────────────────────────────────────
  div(class = "dwr-footer", "Dataset updated 12/10/2025")
)

# ── Server ─────────────────────────────────────────────────────────────────────
server <- function(input, output, session) {

  # ── Debounced keyword ──────────────────────────────────────────────────────
  keyword_d <- debounce(reactive(input$keyword), 300)

  # Tracks which science category the user has clicked in the pie chart
  selected_category <- reactiveVal(NULL)
  # Holds a vector of record_keys when the chat pins specific papers
  selected_papers   <- reactiveVal(NULL)

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

    # Division (matches author_division or funding_division)
    if (!isTRUE(input$f_div == "All")) {
      tgt <- input$f_div
      keep_author <- vapply(df$author_division, function(d) {
        if (is.na(d)) return(FALSE)
        tgt %in% trimws(strsplit(d, ";")[[1L]])
      }, logical(1L))
      keep_funder <- !is.na(df$funding_division) &
        trimws(df$funding_division) == tgt
      df <- df[keep_author | keep_funder, ]
    }

    # Exact paper selection (set by filter_to_papers chat tool)
    sp <- selected_papers()
    if (!is.null(sp))
      df <- df[df$record_key %in% sp, ]

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

  # ── Articles by Division horizontal bar ───────────────────────────────────
  output$bar_division <- renderPlotly({
    df <- filtered()

    # Collect unique (record_key, div) pairs from author and funding columns
    auth_pairs <- do.call(rbind, lapply(
      which(!is.na(df$author_division)),
      function(i) {
        divs <- trimws(strsplit(df$author_division[i], ";")[[1L]])
        divs <- divs[divs != "Unknown" & nchar(divs) > 0L]
        if (length(divs) == 0L) return(NULL)
        data.frame(record_key = df$record_key[i], div = divs,
                   stringsAsFactors = FALSE)
      }
    ))
    fund_rows <- df[!is.na(df$funding_division), ]
    fund_pairs <- if (nrow(fund_rows) > 0L) {
      dv <- trimws(fund_rows$funding_division)
      ok <- dv != "Unknown" & nchar(dv) > 0L
      data.frame(record_key = fund_rows$record_key[ok], div = dv[ok],
                 stringsAsFactors = FALSE)
    } else NULL

    all_pairs <- unique(rbind(auth_pairs, fund_pairs))

    if (is.null(all_pairs) || nrow(all_pairs) == 0L) {
      return(plot_ly() |>
        layout(
          title         = list(text = "No division data for selection",
                               font = list(size = 12)),
          paper_bgcolor = "rgba(0,0,0,0)",
          plot_bgcolor  = "rgba(0,0,0,0)"
        ) |> config(displayModeBar = FALSE))
    }

    # Join contribution_type, then count by division × contribution type
    all_pairs <- left_join(
      all_pairs,
      select(df, record_key, contribution_type),
      by = "record_key"
    )

    # Division ordering: ascending total so largest ends at top
    div_order <- all_pairs |>
      count(div, name = "total") |>
      arrange(total) |>
      pull(div)

    div_counts <- all_pairs |>
      filter(!is.na(contribution_type)) |>
      count(div, contribution_type, name = "n") |>
      mutate(div = factor(div, levels = div_order))

    fig <- plot_ly(source = "div_chart")
    for (ct in CONTRIB_LEVELS) {
      d <- filter(div_counts, contribution_type == ct)
      if (nrow(d) == 0L) next
      fig <- add_trace(fig,
        data          = d,
        x             = ~n,
        y             = ~div,
        type          = "bar",
        orientation   = "h",
        name          = ct,
        marker        = list(color = CONTRIB_COLORS[[ct]]),
        hovertemplate = paste0(ct, ": %{x}<extra></extra>")
      )
    }

    fig |>
      layout(
        barmode       = "stack",
        xaxis         = list(title = "", fixedrange = TRUE,
                             automargin = TRUE, tickformat = "d",
                             dtick = 20, tick0 = 0,
                             gridcolor = "#ebebeb"),
        yaxis         = list(title = "", fixedrange = TRUE, automargin = TRUE,
                             tickfont = list(size = 9.5),
                             ticklen = 8, tickcolor = "rgba(0,0,0,0)",
                             dtick = 1),
        legend        = list(orientation = "h", y = -0.06, x = 0.5,
                             xanchor = "center", font = list(size = 10),
                             itemsizing = "constant"),
        margin        = list(t = 4, b = 40, l = 4, r = 4),
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

  output$papers_filter_banner <- renderUI({
    sp <- selected_papers()
    if (is.null(sp)) return(NULL)
    n <- length(sp)
    div(class = "papers-banner",
      tags$span(paste0(n, " specific paper", if (n == 1L) "" else "s",
                       " pinned by chat filter")),
      actionLink("clear_papers", "Clear ×")
    )
  })

  observeEvent(input$clear_papers, {
    selected_papers(NULL)
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

  # ── Division bar click → filter via the f_div dropdown ───────────────────
  observeEvent(
    event_data("plotly_click", source = "div_chart", priority = "event"),
    {
      click    <- event_data("plotly_click", source = "div_chart", priority = "event")
      div_name <- as.character(click$y)
      if (length(div_name) == 0L || is.na(div_name)) return()
      if (input$f_div == div_name) {
        updateSelectInput(session, "f_div", selected = "All")
      } else {
        updateSelectInput(session, "f_div", selected = div_name)
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
      p("[Placeholder] This inventory tracks peer-reviewed publications funded
        by or authored by staff of the California Department of Water Resources
        (DWR). Publications are identified through Scopus searches and classified
        into scientific fields using a custom taxonomy and large language model."),
      p("For question, contact ",
        tags$a("dwrscience@water.ca.gov",
               href = "mailto:dwrscience@water.ca.gov"), "."),
      easyClose = TRUE,
      footer    = modalButton("Close")
    ))
  })

  observeEvent(input$btn_sci, {
    showModal(modalDialog(
      title     = "Science Category & Field Classification",
      p("[Placeholder] Publications are classified into scientific fields using a
        custom DWR taxonomy developed in collaboration with subject-matter experts.
        Each field belongs to a broader science category. Classification is
        performed using a large language model guided by structured field
        definitions. See the full taxonomy for detailed field descriptions."),
      easyClose = TRUE,
      footer    = modalButton("Close")
    ))
  })

  # ── Reset ─────────────────────────────────────────────────────────────────
  observeEvent(input$btn_reset, {
    selected_category(NULL)
    selected_papers(NULL)
    updateTextInput(  session, "keyword",    value    = "")
    updateSliderInput(session, "year_range", value    = YEAR_DEFAULT)
    updateSelectInput(session, "f_div",      selected = "All")
    updateSelectInput(session, "f_field",
      choices  = field_choices,
      selected = "All"
    )
    updateSelectInput(session, "f_contrib", selected = "All")
    updateSelectInput(session, "f_affil",   selected = "All")
  })

  # ── Chat ──────────────────────────────────────────────────────────────────

  # Create one ellmer chat object per session with the system prompt.
  # Use chat_openai_compatible to match the pubclassify pipeline's provider.
  llm_key <- Sys.getenv("PUBCLASSIFY_LLM_KEY", unset = "")
  if (!nzchar(llm_key)) {
    stop("Dashboard chat requires PUBCLASSIFY_LLM_KEY in the environment.", call. = FALSE)
  }
  chat_obj <- ellmer::chat_openai_compatible(
    base_url      = pipeline_config$llm$base_url,
    system_prompt = chat_system_prompt,
    credentials   = NULL,
    api_headers   = c(Authorization = paste("Bearer", llm_key)),
    model         = pipeline_config$llm$model,
    echo          = "none"
  )

  # \u2500\u2500 Tool: set_filters \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  chat_obj$register_tool(ellmer::tool(
    function(
      keyword           = NULL,
      year_start        = NULL,
      year_end          = NULL,
      science_category  = NULL,
      science_field     = NULL,
      division          = NULL,
      contribution_type = NULL,
      affiliation       = NULL
    ) {
      changed <- character(0)

      if (!is.null(keyword)) {
        kw <- if (keyword == "All" || keyword == "") "" else trimws(keyword)
        updateTextInput(session, "keyword", value = kw)
        if (nchar(kw) > 0L)
          changed <- c(changed, paste0("Keyword → \"", kw, "\""))
        else
          changed <- c(changed, "Keyword cleared")
      }

      if (!is.null(year_start) || !is.null(year_end)) {
        current   <- isolate(input$year_range)
        new_start <- if (!is.null(year_start)) as.integer(year_start) else current[1L]
        new_end   <- if (!is.null(year_end))   as.integer(year_end)   else current[2L]
        updateSliderInput(session, "year_range", value = c(new_start, new_end))
        changed <- c(changed, paste0("Year \u2192 ", new_start, "\u2013", new_end))
      }

      if (!is.null(science_category)) {
        if (science_category == "All") {
          selected_category(NULL)
          updateSelectInput(session, "f_field", choices = field_choices, selected = "All")
        } else {
          selected_category(science_category)
          fields <- pubs |>
            filter(str_to_title(pc_category) == science_category) |>
            pull(pc_field) |> na.omit() |> unique() |> sort()
          updateSelectInput(session, "f_field",
            choices = c("All", fields), selected = "All")
        }
        changed <- c(changed, paste0("Science Category \u2192 ", science_category))
      }

      if (!is.null(science_field)) {
        updateSelectInput(session, "f_field", selected = science_field)
        changed <- c(changed, paste0("Science Field \u2192 ", science_field))
      }

      if (!is.null(division)) {
        updateSelectInput(session, "f_div", selected = division)
        changed <- c(changed, paste0("Division \u2192 ", division))
      }

      if (!is.null(contribution_type)) {
        updateSelectInput(session, "f_contrib", selected = contribution_type)
        changed <- c(changed, paste0("Contribution Type \u2192 ", contribution_type))
      }

      if (!is.null(affiliation)) {
        updateSelectInput(session, "f_affil", selected = affiliation)
        changed <- c(changed, paste0("Author Affiliation \u2192 ", affiliation))
      }

      if (length(changed) == 0L) return("No filters were changed.")
      paste0("Filters updated: ", paste(changed, collapse = "; "), ".")
    },
    "Update the live dashboard filter controls. Only supply parameters you want to
     change; omit the rest. Pass 'All' to any parameter to clear that filter.",
    arguments = list(
      keyword           = ellmer::type_string(
        "Free-text keyword to search title/abstract/authors, or 'All' to clear",
        required = FALSE),
      year_start        = ellmer::type_integer(
        "Start year (e.g. 2015)", required = FALSE),
      year_end          = ellmer::type_integer(
        "End year (e.g. 2022)", required = FALSE),
      science_category  = ellmer::type_string(
        "Science category title-cased exactly as listed, or 'All' to clear",
        required = FALSE),
      science_field     = ellmer::type_string(
        "Science field exactly as listed, or 'All' to clear", required = FALSE),
      division          = ellmer::type_string(
        "DWR division name exactly as listed, or 'All' to clear", required = FALSE),
      contribution_type = ellmer::type_string(
        "One of: Funder, Co-Author, Lead Author, Sole Author, or 'All' to clear",
        required = FALSE),
      affiliation       = ellmer::type_string(
        "Institution name exactly as listed, or 'All' to clear", required = FALSE)
    )
  ))

  # \u2500\u2500 Tool: reset_filters \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  chat_obj$register_tool(ellmer::tool(
    function() {
      selected_category(NULL)
      updateTextInput(  session, "keyword",    value    = "")
      updateSliderInput(session, "year_range", value    = YEAR_DEFAULT)
      updateSelectInput(session, "f_div",      selected = "All")
      updateSelectInput(session, "f_field",
        choices  = field_choices,
        selected = "All"
      )
      updateSelectInput(session, "f_contrib", selected = "All")
      updateSelectInput(session, "f_affil",   selected = "All")
      "All filters have been reset to defaults."
    },
    "Clear all dashboard filters and return to the default view."
  ))

  # \u2500\u2500 Tool: count_by \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  chat_obj$register_tool(ellmer::tool(
    function(dimension) {
      valid <- c("year", "science_field", "science_category", "division",
                 "contribution_type", "journal", "affiliation", "country")
      if (!dimension %in% valid)
        return(paste0("Unknown dimension '", dimension,
                      "'. Valid options: ", paste(valid, collapse = ", ")))

      df <- isolate(filtered())
      if (nrow(df) == 0L) return("No papers in current view.")

      counts <- if (dimension == "year") {
        tbl <- sort(table(df$year[!is.na(df$year)]), decreasing = TRUE)
        data.frame(value = names(tbl), n = as.integer(tbl), stringsAsFactors = FALSE)
      } else if (dimension == "science_field") {
        tbl <- sort(table(df$pc_field[!is.na(df$pc_field)]), decreasing = TRUE)
        data.frame(value = names(tbl), n = as.integer(tbl), stringsAsFactors = FALSE)
      } else if (dimension == "science_category") {
        cats <- str_to_title(df$pc_category[!is.na(df$pc_category)])
        tbl  <- sort(table(cats), decreasing = TRUE)
        data.frame(value = names(tbl), n = as.integer(tbl), stringsAsFactors = FALSE)
      } else if (dimension == "division") {
        auth_divs <- unlist(lapply(
          df$author_division[!is.na(df$author_division)],
          function(d) trimws(strsplit(d, ";")[[1L]])
        ))
        fund_divs <- trimws(df$funding_division[!is.na(df$funding_division)])
        all_divs  <- c(auth_divs, fund_divs)
        all_divs  <- all_divs[all_divs != "Unknown" & nchar(all_divs) > 0L]
        tbl <- sort(table(all_divs), decreasing = TRUE)
        data.frame(value = names(tbl), n = as.integer(tbl), stringsAsFactors = FALSE)
      } else if (dimension == "contribution_type") {
        tbl <- sort(table(df$contribution_type[!is.na(df$contribution_type)]),
                    decreasing = TRUE)
        data.frame(value = names(tbl), n = as.integer(tbl), stringsAsFactors = FALSE)
      } else if (dimension == "journal") {
        tbl <- sort(table(df$journal[!is.na(df$journal)]), decreasing = TRUE)
        data.frame(value = names(tbl), n = as.integer(tbl), stringsAsFactors = FALSE)
      } else if (dimension == "affiliation") {
        affs <- unlist(df$affiliations)
        affs <- affs[!is.na(affs) & trimws(affs) != "" & affs != "Unknown"]
        tbl  <- sort(table(affs), decreasing = TRUE)
        data.frame(value = names(tbl), n = as.integer(tbl), stringsAsFactors = FALSE)
      } else {
        ctrs <- unlist(df$affiliation_countries)
        ctrs <- ctrs[!is.na(ctrs) & trimws(ctrs) != ""]
        tbl  <- sort(table(ctrs), decreasing = TRUE)
        data.frame(value = names(tbl), n = as.integer(tbl), stringsAsFactors = FALSE)
      }

      top   <- head(counts, 25L)
      lines <- paste0(seq_len(nrow(top)), ". ", top$value, ": ", top$n)
      paste0("Breakdown by ", dimension, " (", nrow(df), " papers in view):\n",
             paste(lines, collapse = "\n"))
    },
    "Return a ranked frequency table for one dimension of the current filtered view.
     Use for questions like 'how many papers per division?' or 'top journals?'",
    arguments = list(
      dimension = ellmer::type_string(
        paste0("One of: year, science_field, science_category, division, ",
               "contribution_type, journal, affiliation, country"),
        required = TRUE)
    )
  ))

  # \u2500\u2500 Tool: get_trend \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  chat_obj$register_tool(ellmer::tool(
    function(breakdown = NULL) {
      df <- isolate(filtered())
      if (nrow(df) == 0L) return("No papers in current view.")

      if (is.null(breakdown)) {
        tbl   <- sort(table(df$year[!is.na(df$year)]))
        lines <- paste0(names(tbl), ": ", as.integer(tbl))
        return(paste0("Publications by year (", nrow(df), " total in view):\n",
                      paste(lines, collapse = "\n")))
      }

      if (breakdown == "contribution_type") {
        ct_year <- df |>
          filter(!is.na(year), !is.na(contribution_type)) |>
          count(year, contribution_type, name = "n") |>
          arrange(year)
        years <- sort(unique(ct_year$year))
        lines <- vapply(years, function(yr) {
          row   <- ct_year[ct_year$year == yr, ]
          parts <- paste0(row$contribution_type, ":", row$n)
          paste0(yr, ": total=", sum(row$n), " (", paste(parts, collapse = ", "), ")")
        }, character(1L))
        return(paste0("Publications by year and contribution type:\n",
                      paste(lines, collapse = "\n")))
      }

      if (breakdown == "division") {
        auth_pairs <- do.call(rbind, lapply(
          which(!is.na(df$author_division) & !is.na(df$year)),
          function(i) {
            divs <- trimws(strsplit(df$author_division[i], ";")[[1L]])
            divs <- divs[divs != "Unknown" & nchar(divs) > 0L]
            if (length(divs) == 0L) return(NULL)
            data.frame(year = df$year[i], div = divs, stringsAsFactors = FALSE)
          }
        ))
        if (is.null(auth_pairs)) return("No division data in current view.")
        div_year <- auth_pairs |> count(div, year, name = "n") |> arrange(div, year)
        lines <- vapply(unique(div_year$div), function(d) {
          rows <- div_year[div_year$div == d, ]
          paste0(d, ": ", paste0(rows$year, ":", rows$n, collapse = ", "),
                 " (total=", sum(rows$n), ")")
        }, character(1L))
        return(paste0("Publications by division over time:\n",
                      paste(sort(lines), collapse = "\n")))
      }

      paste0("Unknown breakdown '", breakdown,
             "'. Use: contribution_type, division, or omit for totals only.")
    },
    "Return year-by-year publication counts for the current view. Use for trend
     questions like 'is output growing?' or 'when did ISE peak?'",
    arguments = list(
      breakdown = ellmer::type_string(
        "Optional: 'contribution_type' or 'division' to break counts out further",
        required = FALSE)
    )
  ))

  # \u2500\u2500 Tool: compare_periods \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  chat_obj$register_tool(ellmer::tool(
    function(split_year) {
      df <- isolate(filtered())
      if (nrow(df) == 0L) return("No papers in current view.")

      split_year <- as.integer(split_year)
      before <- df[!is.na(df$year) & df$year <  split_year, ]
      after  <- df[!is.na(df$year) & df$year >= split_year, ]

      summarise_period <- function(d, label) {
        if (nrow(d) == 0L) return(paste0(label, ": No papers."))
        top_fields <- head(sort(table(d$pc_field[!is.na(d$pc_field)]),
                                decreasing = TRUE), 3L)
        ct_tbl <- sort(table(d$contribution_type[!is.na(d$contribution_type)]),
                       decreasing = TRUE)
        paste0(
          label, " (", min(d$year, na.rm = TRUE), "\u2013",
          max(d$year, na.rm = TRUE), "):\n",
          "  Total: ", nrow(d), " papers\n",
          "  Contribution types: ",
          paste(paste0(names(ct_tbl), " (", ct_tbl, ")"), collapse = ", "), "\n",
          "  Top fields: ",
          paste(paste0(names(top_fields), " (", top_fields, ")"), collapse = ", ")
        )
      }

      paste0(
        "Period comparison split at ", split_year,
        " (", nrow(df), " total papers in view):\n\n",
        summarise_period(before, paste0("Before ", split_year)), "\n\n",
        summarise_period(after,  paste0("From ", split_year, " onward"))
      )
    },
    "Split the current filtered view at a year and compare the two periods.
     Use for questions like 'compare before and after 2020'.",
    arguments = list(
      split_year = ellmer::type_integer(
        "The year to split on. Papers before this year form period 1; from this year onward form period 2.",
        required = TRUE)
    )
  ))

  # \u2500\u2500 Tool: find_papers \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  chat_obj$register_tool(ellmer::tool(
    function(query, max_results = 20L) {
      max_results <- as.integer(max_results)
      query_l     <- tolower(trimws(query))
      if (nchar(query_l) == 0L) return("Please provide a search query.")

      matches <- pubs |>
        filter(
          str_detect(tolower(coalesce(title,    "")), fixed(query_l)) |
          str_detect(tolower(coalesce(abstract, "")), fixed(query_l)) |
          str_detect(tolower(authors_text),           fixed(query_l))
        ) |>
        arrange(desc(year)) |>
        head(max_results)

      if (nrow(matches) == 0L)
        return(paste0("No papers found matching '", query, "'."))

      lines <- vapply(seq_len(nrow(matches)), function(i) {
        r   <- matches[i, ]
        doi <- if (!is.na(r$doi)) paste0(" \u2014 https://doi.org/", r$doi) else ""
        paste0(i, ". [key:", r$record_key, "] ",
               "(", coalesce(as.character(r$year), "?"), ") ",
               coalesce(r$title, "[No title]"),
               " / ", coalesce(r$first_author, "?"), doi)
      }, character(1L))

      paste0(
        "Found ", nrow(matches), " paper(s) matching '", query, "'",
        if (nrow(matches) == max_results)
          paste0(" (capped at ", max_results, "; there may be more)") else "",
        ":\n\n", paste(lines, collapse = "\n"),
        "\n\nTo filter the dashboard to these specific papers, ",
        "call filter_to_papers with the record_key values above."
      )
    },
    "Full-text search across the entire inventory (title, abstract, authors) \u2014
     independent of the current dashboard filters. Use when the user wants to
     find papers on a topic without changing the visible view.",
    arguments = list(
      query       = ellmer::type_string(
        "Keywords or phrase to search for", required = TRUE),
      max_results = ellmer::type_integer(
        "Maximum results to return (default 20)", required = FALSE)
    )
  ))

  # \u2500\u2500 Tool: filter_to_papers \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  chat_obj$register_tool(ellmer::tool(
    function(record_keys = NULL, dois = NULL, clear = FALSE) {
      if (isTRUE(clear)) {
        selected_papers(NULL)
        return("Paper selection cleared \u2014 dashboard now shows all papers matching other active filters.")
      }

      if (is.null(record_keys) && is.null(dois))
        return("Provide record_keys, dois, or clear = TRUE.")

      if (!is.null(record_keys)) {
        keys  <- as.character(record_keys)
        valid <- keys[keys %in% pubs$record_key]
        if (length(valid) == 0L)
          return("None of the provided record_keys matched any papers in the inventory.")
        selected_papers(valid)
        n <- length(valid)
        return(paste0("Dashboard filtered to ", n, " specific paper", if (n == 1L) "" else "s", "."))
      }

      doi_norm   <- tolower(trimws(as.character(dois)))
      found_keys <- pubs$record_key[!is.na(pubs$doi) & tolower(pubs$doi) %in% doi_norm]
      if (length(found_keys) == 0L)
        return("None of the provided DOIs matched any papers.")
      selected_papers(found_keys)
      n <- length(found_keys)
      paste0("Dashboard filtered to ", n, " specific paper", if (n == 1L) "" else "s", ".")
    },
    "Pin the dashboard to an exact set of papers by record_key or DOI.
     Use after find_papers when the user says 'filter to those', 'show just those papers',
     or similar. Pass clear = TRUE to remove the selection and return to normal filtering.",
    arguments = list(
      record_keys = ellmer::type_array(
        ellmer::type_string("A record_key value from find_papers output"),
        "Array of record_key strings to pin the dashboard to",
        required = FALSE),
      dois        = ellmer::type_array(
        ellmer::type_string("A DOI string"),
        "Array of DOI strings to pin the dashboard to",
        required = FALSE),
      clear       = ellmer::type_boolean(
        "Set TRUE to clear the selection and return to normal filtering",
        required = FALSE)
    )
  ))

  # \u2500\u2500 Tool: get_paper_detail \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  chat_obj$register_tool(ellmer::tool(
    function(title_fragment = NULL, doi = NULL) {
      if (is.null(title_fragment) && is.null(doi))
        return("Provide either a title_fragment or a doi.")

      if (!is.null(doi)) {
        doi_clean <- tolower(trimws(doi))
        match <- pubs[!is.na(pubs$doi) & tolower(pubs$doi) == doi_clean, ]
      } else {
        frag  <- tolower(trimws(title_fragment))
        match <- pubs[str_detect(tolower(coalesce(pubs$title, "")), fixed(frag)), ]
      }

      if (nrow(match) == 0L) return("No paper found matching those criteria.")
      if (nrow(match) > 3L)
        return(paste0(nrow(match), " papers matched \u2014 please be more specific. Titles:\n",
                      paste(head(match$title, 5L), collapse = "\n")))

      format_one <- function(r) {
        authors_str <- paste(unlist(r$authors), collapse = "; ")
        paste0(
          "Title:              ", coalesce(r$title,    "Unknown"), "\n",
          "Authors:            ", if (nchar(authors_str) > 0L) authors_str else "Unknown", "\n",
          "Year:               ", coalesce(as.character(r$year), "Unknown"), "\n",
          "Journal:            ", coalesce(r$journal,  "Unknown"), "\n",
          "DOI:                ",
          if (!is.na(r$doi)) paste0("https://doi.org/", r$doi) else "None", "\n",
          "Science Field:      ", coalesce(r$pc_field, "Unclassified"), "\n",
          "Science Category:   ", coalesce(str_to_title(r$pc_category), "Unclassified"), "\n",
          "Contribution Type:  ", coalesce(r$contribution_type, "Unknown"), "\n",
          "Division (Author):  ", coalesce(r$author_division,  "Unknown"), "\n",
          "Division (Funder):  ", coalesce(r$funding_division, "Unknown"), "\n",
          "Abstract:           ", coalesce(r$abstract, "No abstract available")
        )
      }

      paste(
        vapply(seq_len(nrow(match)), function(i) format_one(match[i, ]), character(1L)),
        collapse = "\n\n---\n\n"
      )
    },
    "Retrieve full metadata (title, authors, abstract, field, division, DOI, etc.)
     for a specific paper. Use when the user asks for details on a paper they've
     seen in the table or mentions a specific title or DOI.",
    arguments = list(
      title_fragment = ellmer::type_string(
        "A distinctive word or phrase from the paper title", required = FALSE),
      doi            = ellmer::type_string(
        "The paper's DOI (with or without the https://doi.org/ prefix)", required = FALSE)
    )
  ))

  # \u2500\u2500 Tool: synthesize_selection \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  chat_obj$register_tool(ellmer::tool(
    function() {
      df <- isolate(filtered())
      n  <- nrow(df)

      if (n == 0L)
        return("No papers are currently visible. Ask the user to adjust the filters.")

      if (n > 300L)
        return(paste0(
          "There are ", n, " papers in view \u2014 too many to synthesize at once. ",
          "Tell the user to narrow the selection first (field, contribution type, year range)."
        ))

      lines <- vapply(seq_len(n), function(i) {
        row <- df[i, ]
        paste0(i, ". (", coalesce(as.character(row$year), "?"), ") ",
               coalesce(row$title, "[No title]"),
               "\n   Abstract: ", coalesce(row$abstract, "[No abstract available]"))
      }, character(1L))

      paste0("The current filtered view contains ", n, " paper",
             if (n == 1L) "" else "s",
             ". Titles and abstracts:\n\n", paste(lines, collapse = "\n\n"))
    },
    "Retrieve titles and abstracts of the currently filtered papers so you can
     synthesize or analyze them. Use for summary or theme questions about the
     *visible* selection. For searching the whole inventory, use find_papers instead."
  ))

  # \u2500\u2500 Tool: get_author_stats \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  chat_obj$register_tool(ellmer::tool(
    function(top_n = 10L) {
      df    <- isolate(filtered())
      top_n <- as.integer(top_n)
      if (nrow(df) == 0L) return("No papers in current view.")

      author_totals <- df |>
        filter(!is.na(first_author)) |>
        count(first_author, name = "total") |>
        arrange(desc(total)) |>
        head(top_n)

      lead_counts <- df |>
        filter(!is.na(first_author), is_lead_author | is_sole_author) |>
        count(first_author, name = "lead")

      result <- author_totals |>
        left_join(lead_counts, by = "first_author") |>
        mutate(lead = coalesce(lead, 0L))

      lines <- paste0(
        seq_len(nrow(result)), ". ", result$first_author,
        " \u2014 total: ", result$total, ", lead/sole: ", result$lead
      )
      paste0("Top ", top_n, " DWR authors (", nrow(df), " papers in view):\n",
             paste(lines, collapse = "\n"))
    },
    "Return the most prolific DWR authors in the current filtered view, with
     total publication count and lead/sole-author count.",
    arguments = list(
      top_n = ellmer::type_integer(
        "Number of authors to return (default 10)", required = FALSE)
    )
  ))

  # \u2500\u2500 Tool: get_collaboration_stats \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  chat_obj$register_tool(ellmer::tool(
    function(top_n = 15L, exclude_dwr = TRUE) {
      df    <- isolate(filtered())
      top_n <- as.integer(top_n)
      if (nrow(df) == 0L) return("No papers in current view.")

      all_affs <- unlist(df$affiliations)
      all_affs <- all_affs[!is.na(all_affs) & trimws(all_affs) != "" &
                             all_affs != "Unknown"]

      if (isTRUE(exclude_dwr))
        all_affs <- all_affs[
          !grepl("Department of Water Resources|\\bDWR\\b", all_affs,
                 ignore.case = TRUE)]

      if (length(all_affs) == 0L)
        return("No external collaborator affiliations found in current view.")

      tbl  <- sort(table(all_affs), decreasing = TRUE)
      top  <- head(tbl, top_n)
      lines <- paste0(seq_along(top), ". ", names(top), " (", as.integer(top), " papers)")

      paste0(
        "Top ", top_n, " collaborating institutions",
        if (isTRUE(exclude_dwr)) " (DWR affiliations excluded)" else "",
        " (", nrow(df), " papers in view):\n",
        paste(lines, collapse = "\n")
      )
    },
    "Return the external institutions DWR most frequently collaborates with,
     based on co-author affiliations in the current filtered view.",
    arguments = list(
      top_n       = ellmer::type_integer(
        "Number of institutions to return (default 15)", required = FALSE),
      exclude_dwr = ellmer::type_boolean(
        "Exclude DWR-affiliated entries (default TRUE)", required = FALSE)
    )
  ))

  # \u2500\u2500 Tool: cite_papers \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  chat_obj$register_tool(ellmer::tool(
    function(max_papers = 10L, sort_by = "year_desc") {
      df         <- isolate(filtered())
      max_papers <- as.integer(max_papers)
      if (nrow(df) == 0L) return("No papers in current view.")

      if (!sort_by %in% c("year_desc", "year_asc", "title"))
        return("Invalid sort_by. Use: year_desc, year_asc, or title")

      df_sorted <- switch(sort_by,
        year_desc = arrange(df, desc(year), title),
        year_asc  = arrange(df, year, title),
        title     = arrange(df, title)
      )
      subset <- head(df_sorted, max_papers)

      lines <- vapply(seq_len(nrow(subset)), function(i) {
        r          <- subset[i, ]
        authors    <- paste(unlist(r$authors), collapse = ", ")
        if (nchar(authors) == 0L) authors <- "Unknown Authors"
        year_s     <- if (!is.na(r$year)) as.character(r$year) else "n.d."
        journal_s  <- coalesce(r$journal, "")
        doi_s      <- if (!is.na(r$doi)) paste0(" https://doi.org/", r$doi) else ""
        paste0(
          i, ". ", authors, " (", year_s, "). ",
          coalesce(r$title, "Untitled"), ".",
          if (nchar(journal_s) > 0L) paste0(" ", journal_s, ".") else "",
          doi_s
        )
      }, character(1L))

      paste0(
        "Citations for current selection (", sort_by, ", ",
        nrow(subset), " of ", nrow(df), " papers):\n\n",
        paste(lines, collapse = "\n\n")
      )
    },
    "Format papers from the current filtered view as plain-text citations.
     Useful when the user wants a reference list for a report or proposal.",
    arguments = list(
      max_papers = ellmer::type_integer(
        "Maximum number of citations to return (default 10)", required = FALSE),
      sort_by    = ellmer::type_string(
        "Sort order: 'year_desc' (default), 'year_asc', or 'title'", required = FALSE)
    )
  ))

  chat_welcome_msg <- paste0(
    "**DWR Publication Inventory Assistant**\n\n",
    "You can ask me to:\n\n",
    "- **Filter the dashboard** — describe the papers you want to see ",
    "(\"show lead-authored hydrology papers from 2018 to 2022\")\n",
    "- **Find and pin specific papers** — \"find papers about groundwater recharge\", ",
    "then \"filter the dashboard to those papers\"\n",
    "- **Break down the data** — \"how many papers per division?\" or ",
    "\"top journals in the current view\"\n",
    "- **Summarize** — \"summarize the themes in the current selection\"\n",
    "- **Compare periods** — \"compare output before and after 2020\"\n",
    "- **Get paper details or citations** — ask for a specific abstract, ",
    "or format the current selection as a reference list\n",
    "- **Track collaborations** — \"which institutions does DWR co-author with most?\"\n\n",
    "Type a question or description to get started."
  )

  # Hand off to shinychat, which handles streaming and the reactive input loop
  shinychat::chat_mod_server("chat", chat_obj)

  # Restart: clear chat UI + ellmer history, then re-inject welcome message
  observeEvent(input$btn_chat_restart, {
    shinychat::chat_clear("chat-chat", session = session)
    chat_obj$set_turns(list())
    shinychat::chat_append(
      id = "chat-chat", role = "assistant",
      response = chat_welcome_msg, session = session
    )
  })

  # Welcome message — injected once per session; not LLM-generated.
  shinychat::chat_append(
    id = "chat-chat", role = "assistant",
    response = chat_welcome_msg, session = session
  )
}

shinyApp(ui, server)
