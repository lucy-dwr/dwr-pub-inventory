library(shiny)
library(dplyr)
library(readr)
library(arrow)
library(yaml)

# ── Paths ─────────────────────────────────────────────────────────────────────
if (basename(getwd()) == "shiny") setwd("..")
.ROOT <- getwd()

QUEUE_PATH     <- file.path(.ROOT, "data", "queues", "funder_review_queue.parquet")
DECISIONS_PATH <- file.path(.ROOT, "data", "decisions", "funding_review_decisions.csv")
dir.create(dirname(DECISIONS_PATH), recursive = TRUE, showWarnings = FALSE)

# ── Data (loaded once at startup) ─────────────────────────────────────────────

if (!file.exists(QUEUE_PATH)) {
  stop(
    "Review queue not found at ", QUEUE_PATH, ".\n",
    "Run targets::tar_make(funder_review_queue_file) to build it before launching this app."
  )
}

pubs <- arrow::read_parquet(QUEUE_PATH) |>
  arrange(desc(cdwr_score), doi)

N <- nrow(pubs)

# ── Decision I/O ──────────────────────────────────────────────────────────────

load_decisions <- function() {
  if (file.exists(DECISIONS_PATH)) {
    read_csv(DECISIONS_PATH, show_col_types = FALSE,
             col_types = cols(.default = col_character()))
  } else {
    tibble(
      record_key        = character(),
      doi               = character(),
      decision          = character(),
      reviewed_at       = character(),
      review_refresh_id = character(),
      review_notes      = character()
    )
  }
}

save_decision <- function(record_key, doi, decision, refresh_id) {
  d <- load_decisions() |>
    filter(.data$record_key != .env$record_key)
  d <- bind_rows(d, tibble(
    record_key        = record_key,
    doi               = doi,
    decision          = decision,
    reviewed_at       = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    review_refresh_id = refresh_id,
    review_notes      = NA_character_
  ))
  write_csv(d, DECISIONS_PATH)
}

# Determine current refresh_id from the queue data if available, else env var
current_refresh_id <- function() {
  if ("harvest_id" %in% names(pubs) && nrow(pubs) > 0L) pubs$harvest_id[[1L]]
  else {
    cfg <- yaml::read_yaml(file.path(.ROOT, "config", "pipeline.yml"))
    id <- cfg$refresh$id
    if (is.null(id) || length(id) == 0L || is.na(id)) id <- ""
    id <- trimws(as.character(id[[1L]]))
    if (nzchar(id)) id else format(Sys.Date(), "%Y-%m-%d")
  }
}

REFRESH_ID <- current_refresh_id()

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
    .queue-empty   { padding: 40px; text-align: center; color: #6c757d; }
  "))
  ),

  titlePanel(sprintf("DWR Publication Review — Refresh %s", REFRESH_ID)),

  if (N == 0L) {
    div(class = "queue-empty",
      tags$h3("Queue is empty"),
      tags$p("All funder candidates for this refresh have been reviewed or previously accepted."),
      tags$p("Run ", tags$code("targets::tar_make()"), " to publish the updated inventory.")
    )
  } else {
    tagList(
      fluidRow(column(12, uiOutput("progress_ui"))),
      tags$hr(style = "margin: 10px 0;"),
      fluidRow(
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
          ),
          div(style = "margin-top: 8px;",
            tags$label("Jump to DOI", `for` = "doi_jump_input",
              style = "font-size: 12px; font-weight: 700; color: #6c757d;
                       text-transform: uppercase; letter-spacing: .05em; display: block;"),
            div(style = "display: flex; gap: 4px;",
              textInput("doi_jump_input", label = NULL, placeholder = "10.xxxx/…",
                        width = "100%"),
              actionButton("btn_doi_jump", "Go", style = "white-space: nowrap;")
            )
          ),
          div(style = "margin-top: 8px;",
            checkboxInput("show_uncategorized_only", "Show only uncategorized", value = TRUE),
            checkboxInput("show_unsure_only", "Show only unsure", value = FALSE)
          )
        ),
        column(8,
          div(class = "open-link-bar", uiOutput("open_link_ui")),
          div(class = "iframe-wrap",
            tags$iframe(id = "paper_iframe", src = "", width = "100%", height = "800px")
          )
        )
      )
    )
  }
)

# ── Server ────────────────────────────────────────────────────────────────────

server <- function(input, output, session) {

  if (N == 0L) return()

  rv <- reactiveValues(
    idx       = 1L,
    decisions = load_decisions()
  )

  # ── Derived reactives ────────────────────────────────────────────────────

  reviewed_keys <- reactive({
    rv$decisions$record_key[!is.na(rv$decisions$decision)]
  })

  unsure_keys <- reactive({
    rv$decisions$record_key[rv$decisions$decision == "unsure"]
  })

  visible_indices <- reactive({
    if (isTRUE(input$show_uncategorized_only)) {
      which(!pubs$record_key %in% reviewed_keys())
    } else if (isTRUE(input$show_unsure_only)) {
      which(pubs$record_key %in% unsure_keys())
    } else {
      seq_len(N)
    }
  })

  visible_position <- reactive({
    match(rv$idx, visible_indices())
  })

  current_pub <- reactive(pubs[rv$idx, ])
  current_key <- reactive(current_pub()$record_key)
  current_doi <- reactive(current_pub()$doi)

  current_decision <- reactive({
    m <- rv$decisions$decision[rv$decisions$record_key == current_key()]
    if (length(m) == 0L) NA_character_ else m
  })

  counts <- reactive({
    d <- rv$decisions
    list(
      kept     = sum(d$decision == "keep",   na.rm = TRUE),
      dropped  = sum(d$decision == "drop",   na.rm = TRUE),
      unsure   = sum(d$decision == "unsure", na.rm = TRUE),
      reviewed = sum(!is.na(d$decision))
    )
  })

  # ── Navigation ──────────────────────────────────────────────────────────

  observeEvent(input$show_uncategorized_only, {
    if (isTRUE(input$show_uncategorized_only) && isTRUE(input$show_unsure_only)) {
      updateCheckboxInput(session, "show_unsure_only", value = FALSE)
    }
  })

  observeEvent(input$show_unsure_only, {
    if (isTRUE(input$show_unsure_only) && isTRUE(input$show_uncategorized_only)) {
      updateCheckboxInput(session, "show_uncategorized_only", value = FALSE)
    }
  })

  observe({
    visible <- visible_indices()
    if (length(visible) == 0L) return()
    if (!rv$idx %in% visible) rv$idx <- visible[1L]
  })

  advance <- function() {
    visible <- visible_indices()
    if (length(visible) == 0L) return()
    after <- visible[visible > rv$idx]
    if (length(after) > 0L) {
      rv$idx <- after[1L]
    } else {
      rv$idx <- visible[1L]
    }
  }

  retreat <- function() {
    visible <- visible_indices()
    if (length(visible) == 0L) return()
    before <- visible[visible < rv$idx]
    if (length(before) > 0L) {
      rv$idx <- before[length(before)]
    } else {
      rv$idx <- visible[length(visible)]
    }
  }

  record <- function(decision) {
    save_decision(current_key(), current_doi(), decision, REFRESH_ID)
    rv$decisions <- load_decisions()
    advance()
  }

  observeEvent(input$btn_keep,   record("keep"))
  observeEvent(input$btn_drop,   record("drop"))
  observeEvent(input$btn_unsure, record("unsure"))

  observeEvent(input$btn_back, {
    retreat()
  })

  observeEvent(input$btn_skip, {
    advance()
  })

  observeEvent(input$btn_doi_jump, {
    query <- trimws(input$doi_jump_input)
    if (nchar(query) == 0L) return()
    # Strip a leading "https://doi.org/" prefix if pasted as a full URL
    query <- sub("^https?://doi\\.org/", "", query, ignore.case = TRUE)
    hit <- which(tolower(pubs$doi) == tolower(query))
    if (length(hit) == 0L) {
      showNotification(
        paste0("No record found for DOI: ", query),
        type = "warning", duration = 4
      )
    } else {
      rv$idx <- hit[1L]
      updateTextInput(session, "doi_jump_input", value = "")
    }
  })

  # ── Outputs ──────────────────────────────────────────────────────────────

  output$progress_ui <- renderUI({
    c <- counts()
    visible <- visible_indices()
    pos <- visible_position()
    if (length(visible) == 0L) {
      mode <- if (isTRUE(input$show_uncategorized_only)) {
        "uncategorized"
      } else if (isTRUE(input$show_unsure_only)) {
        "unsure"
      } else {
        "visible"
      }
      return(tagList(
        tags$small(sprintf(
          "No %s records  ·  Kept: %d  ·  Dropped: %d  ·  Unsure: %d",
          mode, c$kept, c$dropped, c$unsure
        )),
        div(class = "progress-bar-outer",
          div(class = "progress-bar-inner", style = "width: 100%")
        )
      ))
    }
    pos <- if (is.na(pos)) 1L else pos
    pct <- if (N > 0L) round(100 * c$reviewed / N) else 0L
    tagList(
      tags$small(sprintf(
        "%s %d of %d  ·  Overall record %d of %d  ·  Kept: %d  ·  Dropped: %d  ·  Unsure: %d  ·  Remaining: %d",
        if (isTRUE(input$show_uncategorized_only)) {
          "Uncategorized"
        } else if (isTRUE(input$show_unsure_only)) {
          "Unsure"
        } else {
          "Visible record"
        },
        pos, length(visible), rv$idx, N, c$kept, c$dropped, c$unsure, N - c$reviewed
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
      keep   = tags$span(class = "dec-keep",   "✓ Kept"),
      drop   = tags$span(class = "dec-drop",   "✗ Dropped"),
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
    if (is.na(doi)) return(tags$em("no DOI"))
    tags$a(href = paste0("https://doi.org/", doi), target = "_blank", doi)
  })

  output$journal_ui <- renderUI({
    pub <- current_pub()
    sprintf("%s · %s", pub$year, pub$journal)
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
    doi <- current_doi()
    if (is.na(doi)) return(NULL)
    url <- paste0("https://doi.org/", doi)
    tagList(
      tags$a(href = url, target = "_blank",
        class = "btn btn-sm btn-outline-secondary",
        "Open in browser ↗"
      ),
      tags$span(style = "margin-left: 8px;",
        "Publisher sites often block embedding — use this if the frame is blank."
      )
    )
  })

  observeEvent(rv$idx, {
    doi <- current_doi()
    url <- if (!is.na(doi)) paste0("https://doi.org/", doi) else "about:blank"
    session$sendCustomMessage("updateIframe", url)
  }, ignoreInit = FALSE)
}

shinyApp(ui, server)
