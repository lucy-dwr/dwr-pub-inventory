library(shiny)
library(bslib)
library(plotly)
library(DT)
library(dplyr)
library(arrow)
library(stringr)

# ── Paths ──────────────────────────────────────────────────────────────────────
if (basename(getwd()) == "shiny") setwd("..")
.ROOT <- getwd()

# ── Load data ──────────────────────────────────────────────────────────────────
pubs_raw <- arrow::read_parquet(file.path(.ROOT, "data/dwr_publications.parquet"))

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
  "Funder"      = "#4a9cad",
  "Co-Author"   = "#1a3a5c",
  "Lead Author" = "#7ec8a0",
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
  .fa-badge {
    font-size: 0.68rem; font-weight: 700; text-transform: uppercase;
    letter-spacing: 0.08em; color: #4a6080; margin-bottom: 8px;
  }
  .fa-title {
    font-size: 0.92rem; font-weight: 500;
    color: #1a2f4a; line-height: 1.45;
  }
  .fa-meta { font-size: 0.77rem; color: #7a8a9a; margin-top: 5px; }
  a.fa-readlink {
    font-size: 0.82rem; color: #4a9cad;
    text-decoration: underline; display: inline-block; margin-top: 8px;
  }

  /* ── Division placeholder ── */
  .div-ph {
    display: flex; align-items: center; justify-content: center;
    min-height: 150px; color: #9aabb8; font-style: italic;
    font-size: 0.82rem; border: 1px dashed #c8d3da; border-radius: 4px;
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
  tags$head(tags$style(HTML(app_css))),

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
    actionButton("btn_reset", "Reset",                                   class = "btn-dwr")
  ),

  # ── Main content ─────────────────────────────────────────────────────────────
  div(class = "main-wrap",
    fluidRow(

      # ── Left panel (5 cols) ────────────────────────────────────────────────
      column(5,
        # Featured article
        div(class = "pcrd", uiOutput("featured_ui")),

        # Science Category pie chart
        div(class = "pcrd",
          div(class = "pcrd-title", "Science Category"),
          plotlyOutput("pie_category", height = "310px")
        ),

        # Articles by Division (placeholder)
        div(class = "pcrd",
          div(class = "pcrd-title", "Articles by Division"),
          div(class = "div-ph",
            "Division classifications are in progress \u2014 check back soon"
          )
        )
      ),

      # ── Right panel (7 cols) ───────────────────────────────────────────────
      column(7,
        # Filter dropdowns
        div(class = "pcrd filt-row",
          fluidRow(
            column(3,
              div(class = "filt-disabled",
                tags$span(title = "Division data not yet available",
                  selectInput("f_div", "Division", choices = "All", width = "100%")
                )
              )
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

  # ── Filtered dataset (core reactive) ──────────────────────────────────────
  filtered <- reactive({
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

  # ── Header year subtitle ───────────────────────────────────────────────────
  output$hdr_years <- renderText({
    yr <- input$year_range
    paste0(yr[1L], "\u2013", yr[2L])
  })

  # ── Featured article (static — does not react to filters) ─────────────────
  output$featured_ui <- renderUI({
    div(
      div(class = "fa-badge",
        icon("bookmark"), "\u00a0 FEATURED ARTICLE"
      ),
      div(class = "fa-title", featured$title),
      div(class = "fa-meta",
        paste0("(", featured$year, ") by ", featured$first_author)
      ),
      tags$a("Read Article \u2192",
        href   = paste0("https://doi.org/", featured$doi),
        target = "_blank",
        class  = "fa-readlink"
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
           lbl = "Affiliated Org"),
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
    df <- filtered()

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

  # Pie click → restrict Science Field dropdown to that category's fields
  observeEvent(event_data("plotly_click", source = "pie_chart"), {
    click <- event_data("plotly_click", source = "pie_chart")
    if (!is.null(click$label)) {
      fields <- pubs |>
        filter(str_to_title(pc_category) == click$label) |>
        pull(pc_field) |>
        na.omit() |>
        unique() |>
        sort()
      updateSelectInput(session, "f_field",
        choices  = c("All", fields),
        selected = "All"
      )
    }
  })

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
        showlegend    = FALSE,
        hoverinfo     = "none"
      ) |>
      layout(
        barmode       = "stack",
        xaxis         = list(title = "",              tickformat = "d", fixedrange = TRUE),
        yaxis         = list(title = "Publications",               fixedrange = TRUE),
        legend        = list(orientation = "h", y = -0.22, x = 0.5,
                             xanchor = "center", font = list(size = 11)),
        margin        = list(t = 16, b = 50, l = 50, r = 20),
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
    updateTextInput(  session, "keyword",    value    = "")
    updateSliderInput(session, "year_range", value    = YEAR_DEFAULT)
    updateSelectInput(session, "f_field",
      choices  = field_choices,
      selected = "All"
    )
    updateSelectInput(session, "f_contrib", selected = "All")
    updateSelectInput(session, "f_affil",   selected = "All")
  })
}

shinyApp(ui, server)
