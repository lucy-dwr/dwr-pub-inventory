library(shiny)
library(dplyr)
library(readr)
library(arrow)
library(yaml)

# ── Paths ─────────────────────────────────────────────────────────────────────
if (basename(getwd()) == "shiny") setwd("..")
.ROOT <- getwd()

source(file.path(.ROOT, "R", "author_name_utils.R"))

QUEUE_PATH            <- file.path(.ROOT, "data", "queues", "author_review_queue.parquet")
DECISIONS_PATH        <- file.path(.ROOT, "data", "decisions", "author_review_decisions.csv")
AUTHOR_DIVISION_DECISIONS_PATH <- file.path(.ROOT, "data", "decisions", "author_division_decisions.csv")
LOOKUP_PATH           <- file.path(.ROOT, "data", "lookups", "author_division_lookup.csv")
ORG_LOOKUP_PATH       <- file.path(.ROOT, "data", "lookups", "dwr_org_lookup.csv")
dir.create(dirname(DECISIONS_PATH), recursive = TRUE, showWarnings = FALSE)

# ── Data (loaded once at startup) ─────────────────────────────────────────────

if (!file.exists(QUEUE_PATH)) {
  stop(
    "Author review queue not found at ", QUEUE_PATH, ".\n",
    "Run targets::tar_make(author_review_queue_file) to build it before launching this app."
  )
}

pubs <- arrow::read_parquet(QUEUE_PATH) |>
  arrange(desc(caff_score), doi)

N <- nrow(pubs)

# HR lookup with org canonicalization applied up front
lookup <- NULL
if (file.exists(LOOKUP_PATH)) {
  lookup <- prepare_lookup(LOOKUP_PATH)
  if (file.exists(ORG_LOOKUP_PATH)) {
    org     <- read_csv(ORG_LOOKUP_PATH, show_col_types = FALSE,
                        col_types = cols(.default = col_character()))
    org_map <- setNames(org$division, toupper(trimws(org$original)))
    div_keys <- toupper(trimws(lookup$division))
    lookup$division <- ifelse(div_keys %in% names(org_map), org_map[div_keys], lookup$division)
  }
}

# ── Decision I/O ──────────────────────────────────────────────────────────────

load_decisions <- function() {
  if (file.exists(DECISIONS_PATH)) {
    read_csv(DECISIONS_PATH, show_col_types = FALSE,
             col_types = cols(.default = col_character()))
  } else {
    tibble(record_key=character(), doi=character(), decision=character(),
           reviewed_at=character(), review_refresh_id=character(), review_notes=character())
  }
}

save_decision <- function(record_key, doi, decision, refresh_id) {
  d <- load_decisions() |> filter(.data$record_key != .env$record_key)
  d <- bind_rows(d, tibble(
    record_key=record_key, doi=doi, decision=decision,
    reviewed_at=format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    review_refresh_id=refresh_id, review_notes=NA_character_
  ))
  write_csv(d, DECISIONS_PATH)
}

load_author_division_decisions <- function() {
  if (file.exists(AUTHOR_DIVISION_DECISIONS_PATH)) {
    d <- read_csv(AUTHOR_DIVISION_DECISIONS_PATH, show_col_types = FALSE,
                  col_types = cols(.default = col_character()))
    if (!"division"      %in% names(d)) d$division      <- NA_character_
    if (!"division_rule" %in% names(d)) d$division_rule <- NA_character_
    if (!"year"          %in% names(d)) d$year          <- NA_character_
    d
  } else {
    tibble(record_key=character(), doi=character(), author_name=character(),
           year=character(), decision=character(), division=character(),
           division_rule=character(), reviewed_at=character(), review_refresh_id=character())
  }
}

save_author_decision <- function(record_key, doi, author_name, year, decision,
                                  division = NA_character_, division_rule = NA_character_,
                                  refresh_id) {
  d <- load_author_division_decisions() |>
    filter(!(.data$record_key == .env$record_key & .data$author_name == .env$author_name))
  if (decision != "clear") {
    d <- bind_rows(d, tibble(
      record_key=record_key, doi=doi, author_name=author_name,
      year=as.character(year), decision=decision,
      division=division, division_rule=as.character(division_rule),
      reviewed_at=format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
      review_refresh_id=refresh_id
    ))
  }
  write_csv(d, AUTHOR_DIVISION_DECISIONS_PATH)
}

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
      function authorDecision(btn) {
        Shiny.setInputValue('author_action', {
          record_key:  btn.getAttribute('data-key'),
          author_name: btn.getAttribute('data-author'),
          decision:    btn.getAttribute('data-decision')
        }, {priority: 'event'});
      }
    ")),
    tags$style(HTML("
    body { font-size: 14px; }
    h2   { font-size: 20px; margin-bottom: 4px; }

    .paper-title  { font-size: 17px; font-weight: 600; line-height: 1.4; margin-bottom: 12px; }
    .meta-label   { font-size: 11px; font-weight: 700; color: #6c757d;
                    text-transform: uppercase; letter-spacing: .05em; margin-top: 10px; }
    .meta-value   { margin-top: 2px; }

    .score-badge { display: inline-block; padding: 3px 9px; border-radius: 4px;
                   font-weight: 700; font-size: 12px; }
    .score-high  { background: #f8d7da; color: #721c24; }
    .score-med   { background: #fff3cd; color: #856404; }
    .score-low   { background: #d4edda; color: #155724; }

    .dec-banner  { padding: 6px 10px; border-radius: 4px; margin-bottom: 10px;
                   font-size: 13px; background: #f8f9fa; }
    .dec-keep    { color: #155724; font-weight: 700; }
    .dec-drop    { color: #721c24; font-weight: 700; }
    .dec-unsure  { color: #856404; font-weight: 700; }

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

    /* ── Author entry states ── */
    .author-entry    { margin-bottom: 5px; padding: 3px 6px; border-radius: 3px;
                       border-left: 3px solid transparent;
                       display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
    .author-proposed { background: #fffbea; border-left-color: #ffc107; }
    .author-dwr      { background: #d4edda; border-left-color: #28a745; }

    /* ── Division / proposed badges ── */
    .badge-division          { font-size: 11px; font-weight: 700; color: #155724;
                               background: #c3e6cb; padding: 1px 6px; border-radius: 3px; }
    .badge-proposed          { font-size: 11px; color: #856404;
                               background: #fff3cd; padding: 1px 6px; border-radius: 3px; }
    .badge-needs-resolution  { font-size: 11px; color: #721c24;
                               background: #f8d7da; padding: 1px 6px; border-radius: 3px; }

    /* ── Per-author DWR toggle button ── */
    .btn-author     { font-size: 11px; padding: 1px 8px; border-radius: 3px;
                      cursor: pointer; line-height: 1.6; border: 1px solid; white-space: nowrap; }
    .btn-dwr        { background: #fff; color: #28a745; border-color: #28a745; }
    .btn-dwr:hover  { background: #d4edda; }
    .btn-dwr-active { background: #28a745; color: #fff; border-color: #28a745; }

    .abstract-box { font-size: 13px; color: #343a40; max-height: 130px;
                    overflow-y: auto; border-left: 3px solid #dee2e6;
                    padding-left: 8px; margin-top: 2px; }
    .query-source-tag { font-size: 11px; background: #e2e3e5; color: #383d41;
                        padding: 1px 6px; border-radius: 3px; }
  "))
  ),

  titlePanel(sprintf("DWR Author Affiliation Review — Refresh %s", REFRESH_ID)),

  if (N == 0L) {
    div(class = "queue-empty",
      tags$h3("Queue is empty"),
      tags$p("All affiliation candidates for this refresh have been reviewed or previously accepted."),
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
          div(class = "meta-label", "Year / Journal / Source"),
          div(class = "meta-value", uiOutput("journal_ui")),
          div(class = "meta-label", "Authors"),
          div(class = "meta-value", uiOutput("authors_ui")),
          div(class = "meta-label", "Abstract"),
          div(class = "abstract-box", uiOutput("abstract_ui")),
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
    idx             = 1L,
    decisions       = load_decisions(),
    author_division_decisions = load_author_division_decisions()
  )

  # ── Author action (per-author DWR/Not DWR buttons) ──────────────────────

  observeEvent(input$author_action, {
    a <- input$author_action
    existing <- rv$author_division_decisions$decision[
      rv$author_division_decisions$record_key == a$record_key &
      rv$author_division_decisions$author_name == a$author_name
    ]
    decision <- if (length(existing) > 0L && existing[1L] == a$decision) "clear" else a$decision

    division      <- NA_character_
    division_rule <- NA_character_

    pub_year <- pubs$year[pubs$record_key == a$record_key]
    pub_year <- if (length(pub_year) > 0L) pub_year[1L] else NA_character_

    if (decision == "dwr" && !is.null(lookup) && !is.na(pub_year)) {
      res <- resolve_author_division(a$author_name, pub_year, lookup)
      division_rule <- as.character(res$rule)
      if (res$rule %in% 1:3) division <- res$division
    }

    save_author_decision(a$record_key, current_doi(), a$author_name, pub_year,
                          decision, division, division_rule, REFRESH_ID)
    rv$author_division_decisions <- load_author_division_decisions()
  })

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

  visible_position <- reactive(match(rv$idx, visible_indices()))
  current_pub      <- reactive(pubs[rv$idx, ])
  current_key      <- reactive(current_pub()$record_key)
  current_doi      <- reactive(current_pub()$doi)

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
    if (isTRUE(input$show_uncategorized_only) && isTRUE(input$show_unsure_only))
      updateCheckboxInput(session, "show_unsure_only", value = FALSE)
  })

  observeEvent(input$show_unsure_only, {
    if (isTRUE(input$show_unsure_only) && isTRUE(input$show_uncategorized_only))
      updateCheckboxInput(session, "show_uncategorized_only", value = FALSE)
  })

  observe({
    visible <- visible_indices()
    if (length(visible) > 0L && !rv$idx %in% visible) rv$idx <- visible[1L]
  })

  advance <- function() {
    visible <- visible_indices()
    if (length(visible) == 0L) return()
    after <- visible[visible > rv$idx]
    rv$idx <- if (length(after) > 0L) after[1L] else visible[1L]
  }

  retreat <- function() {
    visible <- visible_indices()
    if (length(visible) == 0L) return()
    before <- visible[visible < rv$idx]
    rv$idx <- if (length(before) > 0L) before[length(before)] else visible[length(visible)]
  }

  record <- function(decision) {
    save_decision(current_key(), current_doi(), decision, REFRESH_ID)
    rv$decisions <- load_decisions()
    advance()
  }

  observeEvent(input$btn_keep,   record("keep"))
  observeEvent(input$btn_drop,   record("drop"))
  observeEvent(input$btn_unsure, record("unsure"))
  observeEvent(input$btn_back,   retreat())
  observeEvent(input$btn_skip,   advance())

  observeEvent(input$btn_doi_jump, {
    query <- trimws(input$doi_jump_input)
    if (!nzchar(query)) return()
    query <- sub("^https?://doi\\.org/", "", query, ignore.case = TRUE)
    hit <- which(tolower(pubs$doi) == tolower(query))
    if (length(hit) == 0L) {
      showNotification(paste0("No record found for DOI: ", query), type = "warning", duration = 4)
    } else {
      rv$idx <- hit[1L]
      updateTextInput(session, "doi_jump_input", value = "")
    }
  })

  # ── Outputs ──────────────────────────────────────────────────────────────

  output$progress_ui <- renderUI({
    c   <- counts()
    vis <- visible_indices()
    pos <- visible_position()
    if (length(vis) == 0L) {
      mode <- if (isTRUE(input$show_uncategorized_only)) "uncategorized"
              else if (isTRUE(input$show_unsure_only)) "unsure"
              else "visible"
      return(tagList(
        tags$small(sprintf(
          "No %s records  ·  Kept: %d  ·  Dropped: %d  ·  Unsure: %d",
          mode, c$kept, c$dropped, c$unsure
        )),
        div(class = "progress-bar-outer",
          div(class = "progress-bar-inner", style = "width: 100%"))
      ))
    }
    pos <- if (is.na(pos)) 1L else pos
    pct <- if (N > 0L) round(100 * c$reviewed / N) else 0L
    tagList(
      tags$small(sprintf(
        "%s %d of %d  ·  Overall record %d of %d  ·  Kept: %d  ·  Dropped: %d  ·  Unsure: %d  ·  Remaining: %d",
        if (isTRUE(input$show_uncategorized_only)) "Uncategorized"
        else if (isTRUE(input$show_unsure_only)) "Unsure"
        else "Visible record",
        pos, length(vis), rv$idx, N, c$kept, c$dropped, c$unsure, N - c$reviewed
      )),
      div(class = "progress-bar-outer",
        div(class = "progress-bar-inner", style = sprintf("width: %d%%", pct)))
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
      label, tags$small(style = "color:#6c757d; margin-left:8px;",
                        "(click a button to change)"))
  })

  output$title_ui <- renderUI(current_pub()$title)

  output$score_ui <- renderUI({
    s   <- current_pub()$caff_score
    cls <- if (s >= 7) "score-badge score-high" else if (s >= 4) "score-badge score-med" else "score-badge score-low"
    lbl <- if (s >= 7) "High suspicion" else if (s >= 4) "Medium suspicion" else "Low suspicion"
    span(class = cls, sprintf("%s  (%d / 12)", lbl, s))
  })

  output$doi_ui <- renderUI({
    doi <- current_doi()
    if (is.na(doi)) return(tags$em("no DOI"))
    tags$a(href = paste0("https://doi.org/", doi), target = "_blank", doi)
  })

  output$journal_ui <- renderUI({
    pub <- current_pub()
    qs  <- if ("query_source" %in% names(pub)) pub$query_source else NA
    tagList(
      sprintf("%s · %s", pub$year, pub$journal),
      if (!is.na(qs))
        tags$span(class = "query-source-tag", style = "margin-left:8px;", qs)
    )
  })

  output$authors_ui <- renderUI({
    pub  <- current_pub()
    key  <- pub$record_key
    year <- pub$year
    authors <- pub$authors[[1L]]
    ad  <- rv$author_division_decisions

    if (!length(authors)) return(tags$em("none"))

    items <- lapply(authors, function(auth) {

      # Current author decision for this record
      dec <- ad$decision[ad$record_key == key & ad$author_name == auth]
      dec <- if (length(dec) == 0L) NA_character_ else dec[1L]
      is_dwr <- !is.na(dec) && dec == "dwr"

      # HR lookup match
      hr_rows <- if (!is.null(lookup)) find_author_divisions(auth, year, lookup) else
                 data.frame(division = character(), stringsAsFactors = FALSE)
      is_hr <- nrow(hr_rows) > 0L
      divs  <- if (is_hr)
        paste(unique(hr_rows$division[!is.na(hr_rows$division)]), collapse = "; ")
      else ""

      # Entry styling
      entry_class <- if (is_dwr)  "author-entry author-dwr"
                     else if (is_hr) "author-entry author-proposed"
                     else             "author-entry"

      name_el   <- if (is_dwr || (!is_dwr && is_hr)) tags$strong(auth) else tags$span(auth)
      div_badge <- if (is_dwr) {
        saved_div  <- ad$division[ad$record_key == key & ad$author_name == auth]
        saved_rule <- ad$division_rule[ad$record_key == key & ad$author_name == auth]
        saved_div  <- if (length(saved_div)  > 0L) saved_div[1L]  else NA_character_
        saved_rule <- if (length(saved_rule) > 0L) saved_rule[1L] else NA_character_
        if (!is.na(saved_div))
          tags$span(class = "badge-division", saved_div)
        else if (!is.na(saved_rule) && saved_rule %in% c("4", "5"))
          tags$span(class = "badge-needs-resolution", "needs resolution")
        else NULL
      } else if (is_hr && nzchar(divs)) {
        tags$span(class = "badge-proposed", divs)
      } else NULL

      # Single toggle button: click to mark DWR, click again to clear
      btn_cls <- if (is_dwr) "btn-author btn-dwr-active" else "btn-author btn-dwr"
      btn_dec <- if (is_dwr) "clear" else "dwr"
      btn <- tags$button(
        class           = btn_cls,
        `data-key`      = key,
        `data-author`   = auth,
        `data-decision` = btn_dec,
        onclick         = "authorDecision(this)",
        "DWR"
      )

      div(class = entry_class, name_el, div_badge, btn)
    })

    tagList(items)
  })

  output$abstract_ui <- renderUI({
    pub <- current_pub()
    ab  <- if ("abstract" %in% names(pub)) pub$abstract else NA_character_
    if (is.na(ab) || !nzchar(trimws(ab))) return(tags$em("no abstract"))
    ab
  })

  output$open_link_ui <- renderUI({
    doi <- current_doi()
    if (is.na(doi)) return(NULL)
    url <- paste0("https://doi.org/", doi)
    tagList(
      tags$a(href = url, target = "_blank",
        class = "btn btn-sm btn-outline-secondary", "Open in browser ↗"),
      tags$span(style = "margin-left: 8px;",
        "Publisher sites often block embedding — use this if the frame is blank.")
    )
  })

  observeEvent(rv$idx, {
    doi <- current_doi()
    url <- if (!is.na(doi)) paste0("https://doi.org/", doi) else "about:blank"
    session$sendCustomMessage("updateIframe", url)
  }, ignoreInit = FALSE)

}

shinyApp(ui, server)
