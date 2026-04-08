library(shiny)
library(targets)
library(dplyr)
library(readr)

# ── Paths ─────────────────────────────────────────────────────────────────────
# Shiny sets the working directory to the app file's location; step up to root.
if (basename(getwd()) == "shiny") setwd("..")

# Capture absolute root now — reactive contexts don't inherit setwd reliably.
.ROOT <- getwd()

source(file.path(.ROOT, "R/score_dwr_relevance.R"))

# Ensure data/ directory exists before any write attempt.
dir.create(file.path(.ROOT, "data"), showWarnings = FALSE)

DECISIONS_PATH <- file.path(.ROOT, "data", "review_decisions.csv")

# ── Data (loaded once at startup) ─────────────────────────────────────────────

pubs <- tar_read(pubs_funding) |>
  score_dwr_relevance() |>
  arrange(desc(cdwr_score), doi)

N <- nrow(pubs)

# ── Decision I/O ──────────────────────────────────────────────────────────────

load_decisions <- function() {
  if (file.exists(DECISIONS_PATH)) {
    read_csv(DECISIONS_PATH, col_types = cols(
      doi         = col_character(),
      decision    = col_character(),
      reviewed_at = col_character()
    ))
  } else {
    tibble(doi = character(), decision = character(), reviewed_at = character())
  }
}

save_decision <- function(doi, decision) {
  d <- load_decisions() |> filter(.data$doi != .env$doi)
  d <- bind_rows(d, tibble(
    doi         = doi,
    decision    = decision,
    reviewed_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  ))
  write_csv(d, DECISIONS_PATH)
}

# ── UI ────────────────────────────────────────────────────────────────────────

ui <- fluidPage(

  tags$head(
    tags$script(HTML("
      Shiny.addCustomMessageHandler('updateIframe', function(url) {
        document.getElementById('paper_iframe').src = url;
      });
    ")),
    tags$style(HTML("
    body { font-size: 14px; }
    h2 { font-size: 20px; margin-bottom: 4px; }

    .paper-title  { font-size: 17px; font-weight: 600; line-height: 1.4; margin-bottom: 12px; }
    .meta-label   { font-size: 11px; font-weight: 700; color: #6c757d;
                    text-transform: uppercase; letter-spacing: .05em; margin-top: 10px; }
    .meta-value   { margin-top: 2px; }
    .meta-value ul { margin: 2px 0; padding-left: 16px; }

    .score-badge  { display: inline-block; padding: 3px 9px; border-radius: 4px;
                    font-weight: 700; font-size: 12px; }
    .score-high   { background: #f8d7da; color: #721c24; }
    .score-med    { background: #fff3cd; color: #856404; }
    .score-low    { background: #d4edda; color: #155724; }

    .dec-banner   { padding: 6px 10px; border-radius: 4px; margin-bottom: 10px;
                    font-size: 13px; background: #f8f9fa; }
    .dec-keep     { color: #155724; font-weight: 700; }
    .dec-drop     { color: #721c24; font-weight: 700; }
    .dec-unsure   { color: #856404; font-weight: 700; }

    #btn_keep   { background:#28a745; color:#fff; border:none; width:80px; margin-right:4px; }
    #btn_drop   { background:#dc3545; color:#fff; border:none; width:80px; margin-right:4px; }
    #btn_unsure { background:#ffc107; color:#212529; border:none; width:80px; margin-right:4px; }
    #btn_keep:hover   { background:#218838; }
    #btn_drop:hover   { background:#c82333; }
    #btn_unsure:hover { background:#e0a800; }
    #btn_back, #btn_skip { margin-right: 4px; }

    .progress-bar-outer { background:#e9ecef; border-radius:4px; height:6px; margin-top:5px; }
    .progress-bar-inner { background:#0d6efd; height:6px; border-radius:4px; }

    .open-link-bar { margin-bottom: 6px; font-size: 13px; color: #6c757d; }
    iframe         { border: none; display: block; }
    .iframe-wrap   { border: 1px solid #dee2e6; border-radius: 4px; overflow: hidden; }
  "))
),

  titlePanel("DWR Publication Review"),

  # ── Progress bar ────────────────────────────────────────────────────────────
  fluidRow(column(12, uiOutput("progress_ui"))),

  tags$hr(style = "margin: 10px 0;"),

  # ── Main layout ─────────────────────────────────────────────────────────────
  fluidRow(

    # Left: metadata + controls
    column(4,
      uiOutput("dec_banner_ui"),
      div(class = "paper-title", uiOutput("title_ui")),

      div(class = "meta-label", "Score"),
      div(class = "meta-value", uiOutput("score_ui")),

      div(class = "meta-label", "DOI"),
      div(class = "meta-value", uiOutput("doi_ui")),

      div(class = "meta-label", "Year / Journal"),
      div(class = "meta-value", uiOutput("journal_ui")),

      div(class = "meta-label", "Affiliations"),
      div(class = "meta-value", uiOutput("affiliations_ui")),

      div(class = "meta-label", "Funders"),
      div(class = "meta-value", uiOutput("funders_ui")),

      div(class = "meta-label", "Grant Numbers"),
      div(class = "meta-value", uiOutput("grants_ui")),

      tags$hr(),

      div(
        actionButton("btn_keep",   "Keep"),
        actionButton("btn_drop",   "Drop"),
        actionButton("btn_unsure", "Unsure")
      ),
      div(style = "margin-top: 8px;",
        actionButton("btn_back", "← Back"),
        actionButton("btn_skip", "Skip →")
      )
    ),

    # Right: embedded browser
    column(8,
      div(class = "open-link-bar", uiOutput("open_link_ui")),
      div(class = "iframe-wrap",
        tags$iframe(id = "paper_iframe", src = "", width = "100%", height = "800px")
      )
    )
  )
)

# ── Server ────────────────────────────────────────────────────────────────────

server <- function(input, output, session) {

  rv <- reactiveValues(
    idx       = 1L,
    decisions = load_decisions()
  )

  # Jump to the first unreviewed paper on startup
  observe({
    reviewed <- rv$decisions$doi
    unreviewed_idx <- which(!pubs$doi %in% reviewed)
    if (length(unreviewed_idx) > 0L) rv$idx <- unreviewed_idx[1L]
  }) |> bindEvent(TRUE)  # run once

  # ── Derived reactives ────────────────────────────────────────────────────

  current_pub <- reactive(pubs[rv$idx, ])
  current_doi <- reactive(current_pub()$doi)

  current_decision <- reactive({
    m <- rv$decisions$decision[rv$decisions$doi == current_doi()]
    if (length(m) == 0L) NA_character_ else m
  })

  counts <- reactive({
    d <- rv$decisions
    list(
      kept     = sum(d$decision == "keep"),
      dropped  = sum(d$decision == "drop"),
      unsure   = sum(d$decision == "unsure"),
      reviewed = nrow(d)
    )
  })

  # ── Navigation ──────────────────────────────────────────────────────────

  advance <- function() {
    reviewed <- rv$decisions$doi
    remaining <- which(!pubs$doi %in% reviewed)
    # Next unreviewed after current position
    after <- remaining[remaining > rv$idx]
    if (length(after) > 0L) {
      rv$idx <- after[1L]
    } else if (length(remaining) > 0L) {
      rv$idx <- remaining[1L]  # wrap to first unreviewed
    }
    # If everything is reviewed, stay put
  }

  record <- function(decision) {
    save_decision(current_doi(), decision)
    rv$decisions <- load_decisions()
    advance()
  }

  observeEvent(input$btn_keep,   record("keep"))
  observeEvent(input$btn_drop,   record("drop"))
  observeEvent(input$btn_unsure, record("unsure"))

  observeEvent(input$btn_back, {
    if (rv$idx > 1L) rv$idx <- rv$idx - 1L
  })

  observeEvent(input$btn_skip, {
    if (rv$idx < N) rv$idx <- rv$idx + 1L
  })

  # ── Outputs ──────────────────────────────────────────────────────────────

  output$progress_ui <- renderUI({
    c <- counts()
    pct <- if (N > 0L) round(100 * c$reviewed / N) else 0L
    tagList(
      tags$small(sprintf(
        "Record %d of %d  ·  Kept: %d  ·  Dropped: %d  ·  Unsure: %d  ·  Remaining: %d",
        rv$idx, N, c$kept, c$dropped, c$unsure, N - c$reviewed
      )),
      div(class = "progress-bar-outer",
        div(class = "progress-bar-inner", style = sprintf("width: %d%%", pct))
      )
    )
  })

  output$dec_banner_ui <- renderUI({
    dec <- current_decision()
    if (is.na(dec)) return(NULL)
    label <- switch(dec,
      keep   = tags$span(class = "dec-keep",   "\u2713 Kept"),
      drop   = tags$span(class = "dec-drop",   "\u2717 Dropped"),
      unsure = tags$span(class = "dec-unsure", "? Unsure")
    )
    div(class = "dec-banner",
      label,
      tags$small(style = "color:#6c757d; margin-left:8px;", "(click a button to change)")
    )
  })

  output$title_ui <- renderUI(current_pub()$title)

  output$score_ui <- renderUI({
    s   <- current_pub()$cdwr_score
    cls <- if (s >= 7) "score-badge score-high" else if (s >= 4) "score-badge score-med" else "score-badge score-low"
    lbl <- if (s >= 7) "High suspicion" else if (s >= 4) "Medium suspicion" else "Low suspicion"
    span(class = cls, sprintf("%s  (%d / 13)", lbl, s))
  })

  output$doi_ui <- renderUI({
    doi <- current_doi()
    tags$a(href = paste0("https://doi.org/", doi), target = "_blank", doi)
  })

  output$journal_ui <- renderUI({
    pub <- current_pub()
    sprintf("%s \u00b7 %s", pub$year, pub$journal)
  })

  output$affiliations_ui <- renderUI({
    vals <- unlist(current_pub()$affiliations[[1]])
    if (!length(vals)) return(tags$em("none"))
    tags$ul(lapply(vals, tags$li))
  })

  output$funders_ui <- renderUI({
    vals <- unlist(current_pub()$funders[[1]])
    if (!length(vals)) return(tags$em("none"))
    tags$ul(lapply(vals, tags$li))
  })

  output$grants_ui <- renderUI({
    vals <- unlist(current_pub()$grant_numbers[[1]])
    if (!length(vals)) return(tags$em("none"))
    tags$ul(lapply(vals, tags$li))
  })

  output$open_link_ui <- renderUI({
    url <- paste0("https://doi.org/", current_doi())
    tagList(
      tags$a(href = url, target = "_blank",
        class = "btn btn-sm btn-outline-secondary",
        "Open in browser \u2197"
      ),
      tags$span(style = "margin-left: 8px;",
        "Publisher sites often block embedding \u2014 use this if the frame is blank."
      )
    )
  })

  # Update the iframe src in-place via JS rather than re-rendering the element,
  # which avoids the grey flash caused by Shiny destroying and recreating it.
  observeEvent(rv$idx, {
    session$sendCustomMessage("updateIframe", paste0("https://doi.org/", current_doi()))
  }, ignoreInit = FALSE)
}

shinyApp(ui, server)
