library(shiny)
library(dplyr)
library(readr)
library(arrow)

# ── Paths ─────────────────────────────────────────────────────────────────────
if (basename(getwd()) == "shiny") setwd("..")
.ROOT <- getwd()

source(file.path(.ROOT, "R", "author_name_utils.R"))

AUTHOR_DIVISION_DECISIONS_PATH <- file.path(.ROOT, "data", "decisions", "author_division_decisions.csv")
QUEUE_PATH            <- file.path(.ROOT, "data", "queues", "author_review_queue.parquet")
LOOKUP_PATH           <- file.path(.ROOT, "data", "lookups", "author_division_lookup.csv")
ORG_LOOKUP_PATH       <- file.path(.ROOT, "data", "lookups", "dwr_org_lookup.csv")
dir.create(dirname(AUTHOR_DIVISION_DECISIONS_PATH), recursive = TRUE, showWarnings = FALSE)

# ── Startup: load lookup with canonicalization ────────────────────────────────

lookup <- prepare_lookup(LOOKUP_PATH)
if (file.exists(ORG_LOOKUP_PATH)) {
  org     <- read_csv(ORG_LOOKUP_PATH, show_col_types = FALSE,
                      col_types = cols(.default = col_character()))
  org_map <- setNames(org$division, toupper(trimws(org$original)))
  div_keys <- toupper(trimws(lookup$division))
  lookup$division <- ifelse(div_keys %in% names(org_map), org_map[div_keys], lookup$division)
}

# Include canonical names from both the HR lookup and dwr_org_lookup.csv directly,
# so newly added canonical names appear in the dropdown even if no HR record uses them yet.
all_divisions <- sort(unique(c(
  lookup$division[!is.na(lookup$division) & nzchar(lookup$division)],
  if (file.exists(ORG_LOOKUP_PATH)) {
    org$division[!is.na(org$division) & nzchar(org$division)]
  } else character()
)))

# ── Decision I/O ──────────────────────────────────────────────────────────────

load_decisions <- function() {
  if (!file.exists(AUTHOR_DIVISION_DECISIONS_PATH)) {
    return(tibble(record_key=character(), doi=character(), author_name=character(),
                  year=character(), decision=character(), division=character(),
                  division_rule=character(), reviewed_at=character(),
                  review_refresh_id=character()))
  }
  d <- read_csv(AUTHOR_DIVISION_DECISIONS_PATH, show_col_types = FALSE,
                col_types = cols(.default = col_character()))
  if (!"year"          %in% names(d)) d$year          <- NA_character_
  if (!"division"      %in% names(d)) d$division      <- NA_character_
  if (!"division_rule" %in% names(d)) d$division_rule <- NA_character_
  d
}

save_division <- function(record_key, author_name, division, rule) {
  d <- load_decisions()
  idx <- which(d$record_key == record_key & d$author_name == author_name)
  if (length(idx) > 0L) {
    d$division[idx[1L]]      <- division
    d$division_rule[idx[1L]] <- as.character(rule)
  }
  write_csv(d, AUTHOR_DIVISION_DECISIONS_PATH)
}

# ── Startup: sync year/title from queue parquet via DOI ──────────────────────
# The queue parquet is the authoritative source for publication year. We join
# on DOI (stable across queue rebuilds) and always overwrite the stored year
# when the parquet has a value, repairing any previously corrupted rows. The
# stored year is kept only as a fallback for records absent from the parquet.

pub_meta <- (
  if (file.exists(QUEUE_PATH))
    arrow::read_parquet(QUEUE_PATH) |>
      select(doi, title, year) |>
      mutate(across(everything(), as.character))
  else tibble(doi=character(), title=character(), year=character())
) |>
  filter(!is.na(doi) & nzchar(doi)) |>
  mutate(doi_key = tolower(trimws(doi))) |>
  distinct(doi_key, .keep_all = TRUE)

{
  d <- load_decisions()
  d_synced <- d |>
    mutate(doi_key = tolower(trimws(doi))) |>
    left_join(pub_meta |> select(doi_key, year_meta = year), by = "doi_key") |>
    mutate(new_year = coalesce(year_meta, year))   # parquet year wins

  year_changed <- !is.na(d_synced$new_year) &
                  (is.na(d$year) | d_synced$new_year != d$year)

  # An auto-resolution (rule 1/2/3) made against a now-corrected year is invalid:
  # clear it so build_queue() re-resolves against the right year. Human picks
  # (rule 5 from the dropdown) are year-independent, so preserve them.
  auto_resolved <- d$division_rule %in% c("1", "2", "3")
  invalidate    <- year_changed & auto_resolved

  d_synced$year <- d_synced$new_year
  d_synced$division[invalidate]      <- NA_character_
  d_synced$division_rule[invalidate] <- NA_character_
  d_synced <- select(d_synced, -doi_key, -year_meta, -new_year)

  if (sum(year_changed) > 0L || sum(invalidate) > 0L) {
    write_csv(d_synced, AUTHOR_DIVISION_DECISIONS_PATH)
    message(sprintf(
      "Synced year for %d decision(s); cleared %d stale auto-resolution(s) for re-resolution.",
      sum(year_changed), sum(invalidate)
    ))
  }
}

# ── Build resolution queue ────────────────────────────────────────────────────
# Run at startup: auto-resolve rules 1-3, collect rules 4-5 for the app.

build_queue <- function() {
  d <- load_decisions()
  unresolved <- d[!is.na(d$decision) & d$decision == "dwr" & is.na(d$division), ]
  if (nrow(unresolved) == 0L) return(tibble())

  rows <- lapply(seq_len(nrow(unresolved)), function(i) {
    row  <- unresolved[i, ]
    doi_key <- tolower(trimws(row$doi))
    meta    <- pub_meta[pub_meta$doi_key == doi_key, ]
    year    <- if (!is.na(row$year) && nzchar(row$year)) row$year
               else if (nrow(meta) > 0L && !is.na(meta$year[1L])) meta$year[1L]
               else NA_character_
    title   <- if (nrow(meta) > 0L) meta$title[1L] else NA_character_

    if (is.na(year)) {
      return(tibble(
        record_key  = row$record_key,
        doi         = row$doi,
        author_name = row$author_name,
        title       = title,
        year        = NA_character_,
        rule        = 5L,
        candidates  = list(character())
      ))
    }

    res <- resolve_author_division(row$author_name, year, lookup)

    if (res$rule %in% 1:3) {
      # Auto-resolvable — save immediately and exclude from queue
      save_division(row$record_key, row$author_name, res$division, res$rule)
      return(NULL)
    }

    tibble(
      record_key  = row$record_key,
      doi         = row$doi,
      author_name = row$author_name,
      title       = title,
      year        = as.character(year),
      rule        = res$rule,
      candidates  = list(res$candidates)
    )
  })

  rows <- rows[!vapply(rows, is.null, logical(1L))]
  if (length(rows) == 0L) return(tibble())
  bind_rows(rows)
}

message("Resolving rules 1–3 automatically…")
queue <- build_queue()
N     <- nrow(queue)
message(sprintf("Done. %d author(s) need manual resolution.", N))

# ── UI ────────────────────────────────────────────────────────────────────────

ui <- fluidPage(
  tags$head(tags$style(HTML("
    body { font-size: 14px; }
    .paper-title  { font-size: 16px; font-weight: 600; line-height: 1.4; margin-bottom: 8px; }
    .meta-label   { font-size: 11px; font-weight: 700; color: #6c757d;
                    text-transform: uppercase; letter-spacing: .05em; margin-top: 10px; }
    .meta-value   { margin-top: 2px; }
    .rule-badge   { display: inline-block; padding: 3px 9px; border-radius: 4px;
                    font-weight: 700; font-size: 12px; }
    .rule-4       { background: #fff3cd; color: #856404; }
    .rule-5       { background: #f8d7da; color: #721c24; }
    .progress-bar-outer { background:#e9ecef; border-radius:4px; height:6px; margin-top:5px; }
    .progress-bar-inner { background:#0d6efd; height:6px; border-radius:4px; }
    .queue-done   { padding: 40px; text-align: center; color: #155724; }
    .open-link-bar { margin-bottom: 6px; font-size: 13px; color: #6c757d; }
    iframe        { border: none; display: block; }
    .iframe-wrap  { border: 1px solid #dee2e6; border-radius: 4px; overflow: hidden; }
    #btn_save     { background:#0d6efd; color:#fff; border:none; margin-right:4px; }
    #btn_save:hover { background:#0b5ed7; }
    #btn_back     { margin-right: 4px; }
    #btn_skip     { margin-right: 4px; }
  "))),

  titlePanel("DWR Author Division Resolution"),

  if (N == 0L) {
    div(class = "queue-done",
      tags$h3("All divisions resolved"),
      tags$p("Every confirmed DWR author has been assigned a division."),
      tags$p("Run ", tags$code("targets::tar_make()"), " to publish the updated inventory.")
    )
  } else {
    tagList(
      fluidRow(column(12, uiOutput("progress_ui"))),
      tags$hr(style = "margin: 10px 0;"),
      fluidRow(
        column(4,
          div(class = "meta-label", "Rule"),
          div(class = "meta-value", uiOutput("rule_ui")),
          div(class = "paper-title", uiOutput("title_ui")),
          div(class = "meta-label", "Author / Year"),
          div(class = "meta-value", uiOutput("author_ui")),
          div(class = "meta-label", "DOI"),
          div(class = "meta-value", uiOutput("doi_ui")),
          tags$hr(),
          div(class = "meta-label", "Assign division"),
          div(class = "meta-value", uiOutput("division_input_ui")),
          tags$hr(),
          div(
            actionButton("btn_save", "Save & Next"),
            actionButton("btn_back", "← Back"),
            actionButton("btn_skip", "Skip →")
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

  rv <- reactiveValues(idx = 1L, resolved = 0L)

  current_row <- reactive(queue[rv$idx, ])

  # Update iframe on navigation
  observeEvent(rv$idx, {
    doi <- current_row()$doi
    url <- if (!is.na(doi)) paste0("https://doi.org/", doi) else "about:blank"
    session$sendCustomMessage(
      type    = "updateIframe",
      message = url
    )
  }, ignoreInit = FALSE)

  tags$head(tags$script(HTML("
    Shiny.addCustomMessageHandler('updateIframe', function(url) {
      document.getElementById('paper_iframe').src = url;
    });
  ")))

  advance <- function() {
    if (rv$idx < N) rv$idx <- rv$idx + 1L
  }

  retreat <- function() {
    if (rv$idx > 1L) rv$idx <- rv$idx - 1L
  }

  observeEvent(input$btn_skip, advance())
  observeEvent(input$btn_back, retreat())

  observeEvent(input$btn_save, {
    row <- current_row()
    sel <- if (row$rule == 4L) input$division_radio else input$division_select
    if (is.null(sel) || !nzchar(trimws(sel))) {
      showNotification("Please select a division before saving.", type = "warning")
      return()
    }
    save_division(row$record_key, row$author_name, trimws(sel), row$rule)
    rv$resolved <- rv$resolved + 1L
    advance()
  })

  # ── Outputs ──────────────────────────────────────────────────────────────

  output$progress_ui <- renderUI({
    tagList(
      tags$small(sprintf(
        "Author %d of %d  ·  Resolved this session: %d  ·  Remaining: %d",
        rv$idx, N, rv$resolved, N - rv$resolved
      )),
      div(class = "progress-bar-outer",
        div(class = "progress-bar-inner",
            style = sprintf("width: %d%%", round(100 * rv$resolved / N))))
    )
  })

  output$rule_ui <- renderUI({
    r <- current_row()$rule
    if (r == 4L) {
      span(class = "rule-badge rule-4",
           "Rule 4 — Multiple divisions found")
    } else {
      span(class = "rule-badge rule-5",
           "Rule 5 — No HR match found")
    }
  })

  output$title_ui <- renderUI(current_row()$title)

  output$author_ui <- renderUI({
    row <- current_row()
    tagList(
      tags$strong(row$author_name),
      if (!is.na(row$year))
        tags$span(style = "margin-left: 8px; color: #6c757d;", row$year)
    )
  })

  output$doi_ui <- renderUI({
    doi <- current_row()$doi
    if (!is.na(doi))
      tags$a(href = paste0("https://doi.org/", doi), target = "_blank", doi)
    else tags$em("no DOI")
  })

  output$division_input_ui <- renderUI({
    row <- current_row()
    if (row$rule == 4L) {
      radioButtons("division_radio", label = NULL,
                   choices  = row$candidates[[1L]],
                   selected = character(0))
    } else {
      selectInput("division_select", label = NULL,
                  choices  = c("— select —" = "", all_divisions),
                  selected = "")
    }
  })

  output$open_link_ui <- renderUI({
    doi <- current_row()$doi
    if (is.na(doi)) return(NULL)
    url <- paste0("https://doi.org/", doi)
    tagList(
      tags$a(href = url, target = "_blank",
             class = "btn btn-sm btn-outline-secondary", "Open in browser ↗"),
      tags$span(style = "margin-left: 8px;",
                "Publisher sites often block embedding — use this if the frame is blank.")
    )
  })
}

shinyApp(ui, server)
