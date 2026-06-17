library(shiny)
library(dplyr)
library(readr)
library(DT)

if (basename(getwd()) == "shiny") setwd("..")
.ROOT <- getwd()

LOOKUP_PATH <- file.path(.ROOT, "data", "lookups", "affiliation_lookup.csv")
REFERENCE_PATH <- file.path(.ROOT, "data", "lookups", "institution_reference.txt")

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0L) y else x
}

if (!file.exists(LOOKUP_PATH)) {
  stop(
    "Affiliation lookup not found at ", LOOKUP_PATH, ".\n",
    "Run targets::tar_make(affiliation_lookup_file) before launching this app."
  )
}

read_lookup <- function(path = LOOKUP_PATH) {
  x <- read_csv(path, show_col_types = FALSE, col_types = cols(.default = col_character()))
  required <- c(
    "record_key", "doi", "doi_url", "title", "year", "authors",
    "raw", "canonical", "new", "reviewed_at", "review_notes",
    "manual_added"
  )
  for (col in setdiff(required, names(x))) {
    x[[col]] <- if (col == "manual_added") FALSE else NA_character_
  }
  x <- x[, c(required, setdiff(names(x), required)), drop = FALSE]
  x$new <- coerce_new_flag(x$new)
  x$manual_added <- coerce_new_flag(x$manual_added)
  x$canonical <- normalize_unknown(x$canonical)
  x$raw <- normalize_raw(x$raw)
  x
}

write_lookup <- function(x, path = LOOKUP_PATH) {
  write_csv(x, path)
}

coerce_new_flag <- function(x) {
  if (is.logical(x)) return(replace(x, is.na(x), FALSE))
  vals <- tolower(trimws(as.character(x)))
  vals[is.na(vals) | !nzchar(vals)] <- "false"
  vals %in% c("true", "t", "1", "yes", "y")
}

normalize_unknown <- function(x) {
  x <- trimws(as.character(x))
  x[is.na(x) | !nzchar(x)] <- "Unknown"
  x[tolower(x) == "unknown"] <- "Unknown"
  x
}

normalize_raw <- function(x) {
  x <- trimws(as.character(x))
  x[is.na(x) | !nzchar(x)] <- "[missing affiliation]"
  x
}

load_reference <- function(path = REFERENCE_PATH) {
  if (!file.exists(path)) return(character())
  vals <- trimws(readLines(path, warn = FALSE))
  vals[nzchar(vals)]
}

lookup <- read_lookup()

ui <- fluidPage(
  tags$head(
    tags$style(HTML("
      body { font-size: 14px; }
      h2 { font-size: 20px; margin-bottom: 4px; }
      .meta-label { font-size: 11px; font-weight: 700; color: #6c757d;
                    text-transform: uppercase; letter-spacing: .05em; margin-top: 10px; }
      .meta-value { margin-top: 2px; overflow-wrap: anywhere; }
      .status { display: inline-block; padding: 2px 7px; border-radius: 4px;
                font-size: 12px; font-weight: 700; }
      .status-new { color: #721c24; background: #f8d7da; }
      .status-reviewed { color: #155724; background: #d4edda; }
      .status-unknown { color: #856404; background: #fff3cd; }
      .browser-note { color: #6c757d; font-size: 13px; margin-bottom: 6px; }
      .button-row .btn { margin-right: 4px; margin-bottom: 6px; }
      .doi-link { overflow-wrap: anywhere; }
      .article-title { font-weight: 700; line-height: 1.3; margin-top: 2px; }
      .selected-raw { padding: 8px; border-left: 4px solid #0d6efd; background: #f8f9fa;
                      margin: 6px 0 10px 0; overflow-wrap: anywhere; }
      .table-note { color: #6c757d; font-size: 12px; margin-top: 4px; }
    "))
  ),

  titlePanel("Affiliation Canonicalization Review"),

  if (nrow(lookup) == 0L) {
    div(style = "padding: 40px; color: #6c757d;",
      tags$h3("No affiliation rows to review"),
      tags$p("Run ", tags$code("targets::tar_make(affiliation_lookup_file)"), " after building a publish set.")
    )
  } else {
    fluidRow(
      column(
        4,
        checkboxInput("unknown_only", "Articles with Unknown affiliations only", value = TRUE),
        checkboxInput("new_only", "Articles with new/unreviewed affiliations only", value = TRUE),
        textInput("article_search", "Search articles", placeholder = "title, DOI, author, raw, canonical"),
        uiOutput("progress_ui"),
        tags$hr(),
        uiOutput("article_status_ui"),
        div(class = "meta-label", "DOI"),
        div(class = "meta-value doi-link", uiOutput("doi_ui")),
        div(class = "meta-label", "Title"),
        div(class = "article-title", textOutput("title_text")),
        div(class = "meta-label", "Year"),
        div(class = "meta-value", textOutput("year_text")),
        div(class = "meta-label", "Authors"),
        div(class = "meta-value", textOutput("authors_text")),
        tags$hr(),
        div(class = "meta-label", "Selected Raw Affiliation"),
        div(class = "selected-raw", textOutput("selected_raw_text")),
        textInput(
          "selected_canonical",
          "Canonical institution for selected row",
          value = "",
          placeholder = "Type institution, or click one from Canonical Institutions"
        ),
        textAreaInput("selected_notes", "Review notes for selected row", height = "70px"),
        div(class = "button-row",
          actionButton("apply_selected", "Apply to selected row"),
          actionButton("mark_selected_unknown", "Mark selected Unknown")
        ),
        tags$hr(),
        div(class = "meta-label", "Add Missing Affiliation"),
        textInput("add_raw", NULL, placeholder = "Raw affiliation from article"),
        textInput("add_canonical", NULL, placeholder = "Canonical institution"),
        actionButton("add_affiliation", "Add affiliation"),
        tags$hr(),
        div(class = "button-row",
          actionButton("save_article_next", "Save Article + Next"),
          actionButton("save_article", "Save Article"),
          actionButton("back", "Back"),
          actionButton("skip", "Skip")
        )
      ),
      column(
        8,
        tabsetPanel(
          tabPanel(
            "Article Affiliations",
            div(class = "browser-note",
              "Review all affiliation strings for the current article together. Edit canonical values directly in the table, or select a row and use the field on the left."
            ),
            DTOutput("article_affiliations"),
            div(class = "table-note",
              "Saving the article marks all rows in this article reviewed. Blank canonical values are saved as Unknown."
            )
          ),
          tabPanel(
            "Canonical Institutions",
            div(class = "browser-note",
              "Search or scroll established canonical names. Click a row to copy it into the selected affiliation row."
            ),
            checkboxInput("include_reference", "Include reference-list names", value = TRUE),
            DTOutput("canonical_browser")
          ),
          tabPanel(
            "Article Queue",
            div(class = "browser-note",
              "Filtered articles. Click a row to jump to that article."
            ),
            DTOutput("article_queue_table")
          )
        )
      )
    )
  }
)

server <- function(input, output, session) {
  if (nrow(lookup) == 0L) return()

  rv <- reactiveValues(
    data = lookup,
    record_key = lookup$record_key[[1L]],
    draft = NULL,
    selected_draft_row = 1L
  )

  article_summary <- reactive({
    d <- rv$data
    d |>
      group_by(.data$record_key) |>
      summarise(
        doi = first(.data$doi),
        doi_url = first(.data$doi_url),
        title = first(.data$title),
        year = first(.data$year),
        authors = first(.data$authors),
        n_affiliations = n(),
        n_unknown = sum(.data$canonical == "Unknown", na.rm = TRUE),
        n_new = sum(.data$new, na.rm = TRUE),
        raw_text = paste(unique(.data$raw), collapse = " "),
        canonical_text = paste(unique(.data$canonical), collapse = " "),
        .groups = "drop"
      ) |>
      arrange(desc(.data$n_new > 0L), desc(.data$n_unknown > 0L), tolower(.data$title))
  })

  visible_articles <- reactive({
    d <- article_summary()
    keep <- rep(TRUE, nrow(d))
    if (isTRUE(input$unknown_only)) {
      keep <- keep & d$n_unknown > 0L
    }
    if (isTRUE(input$new_only)) {
      keep <- keep & d$n_new > 0L
    }
    q <- trimws(input$article_search %||% "")
    if (nzchar(q)) {
      hay <- paste(d$doi, d$title, d$authors, d$raw_text, d$canonical_text, sep = " ")
      keep <- keep & grepl(q, hay, ignore.case = TRUE, fixed = FALSE)
    }
    d$record_key[keep]
  })

  current_article <- reactive({
    article_summary() |>
      filter(.data$record_key == rv$record_key) |>
      slice_head(n = 1)
  })

  current_rows <- reactive({
    which(rv$data$record_key == rv$record_key)
  })

  reset_draft <- function() {
    rows <- current_rows()
    rv$draft <- rv$data[rows, , drop = FALSE]
    rv$selected_draft_row <- if (nrow(rv$draft) > 0L) 1L else NA_integer_
  }

  observe({
    keys <- visible_articles()
    if (length(keys) == 0L) return()
    if (!rv$record_key %in% keys) {
      rv$record_key <- keys[[1L]]
    }
  })

  observeEvent(rv$record_key, {
    reset_draft()
  }, ignoreInit = FALSE)

  observeEvent(rv$selected_draft_row, {
    if (is.null(rv$draft) || is.na(rv$selected_draft_row) || nrow(rv$draft) == 0L) {
      updateTextInput(session, "selected_canonical", value = "")
      updateTextAreaInput(session, "selected_notes", value = "")
      return()
    }
    row <- rv$draft[rv$selected_draft_row, , drop = FALSE]
    updateTextInput(session, "selected_canonical", value = row$canonical[[1L]])
    updateTextAreaInput(session, "selected_notes", value = row$review_notes[[1L]] %||% "")
  })

  output$progress_ui <- renderUI({
    keys <- visible_articles()
    pos <- match(rv$record_key, keys)
    if (length(keys) == 0L || is.na(pos)) {
      return(tags$p("No articles match the current filters.", style = "color:#6c757d;"))
    }
    tags$p(sprintf(
      "Showing article %d of %d. %d articles have unresolved new/Unknown affiliations.",
      pos,
      length(keys),
      sum(article_summary()$n_new > 0L & article_summary()$n_unknown > 0L, na.rm = TRUE)
    ))
  })

  output$article_status_ui <- renderUI({
    article <- current_article()
    tags$div(
      if (article$n_new[[1L]] > 0L) {
        tags$span(class = "status status-new", sprintf("%d New", article$n_new[[1L]]))
      } else {
        tags$span(class = "status status-reviewed", "Reviewed")
      },
      if (article$n_unknown[[1L]] > 0L) {
        tags$span(
          class = "status status-unknown",
          style = "margin-left:4px;",
          sprintf("%d Unknown", article$n_unknown[[1L]])
        )
      }
    )
  })

  output$title_text <- renderText(current_article()$title[[1L]] %||% "")
  output$year_text <- renderText(current_article()$year[[1L]] %||% "")
  output$authors_text <- renderText(current_article()$authors[[1L]] %||% "")
  output$doi_ui <- renderUI({
    article <- current_article()
    if (!is.na(article$doi_url[[1L]]) && nzchar(article$doi_url[[1L]])) {
      tags$a(article$doi[[1L]], href = article$doi_url[[1L]], target = "_blank")
    } else {
      article$doi[[1L]] %||% ""
    }
  })

  output$selected_raw_text <- renderText({
    if (is.null(rv$draft) || is.na(rv$selected_draft_row) || nrow(rv$draft) == 0L) {
      return("")
    }
    rv$draft$raw[[rv$selected_draft_row]]
  })

  article_affiliation_view <- reactive({
    req(rv$draft)
    out <- rv$draft[, c("raw", "canonical", "new", "manual_added", "review_notes"), drop = FALSE]
    out$new <- ifelse(out$new, "true", "false")
    out$manual_added <- ifelse(out$manual_added, "true", "false")
    out
  })

  output$article_affiliations <- renderDT({
    datatable(
      article_affiliation_view(),
      rownames = FALSE,
      selection = "single",
      editable = list(
        target = "cell",
        disable = list(columns = c(0, 2, 3))
      ),
      options = list(pageLength = 15, dom = "tip", scrollX = TRUE)
    )
  })

  observeEvent(input$article_affiliations_rows_selected, {
    idx <- input$article_affiliations_rows_selected
    if (length(idx) == 1L) {
      rv$selected_draft_row <- idx
    }
  })

  observeEvent(input$article_affiliations_cell_edit, {
    info <- input$article_affiliations_cell_edit
    i <- info$row
    j <- info$col + 1L
    cols <- c("raw", "canonical", "new", "manual_added", "review_notes")
    col <- cols[[j]]
    if (!col %in% c("canonical", "review_notes")) return()
    draft <- rv$draft
    draft[[col]][[i]] <- as.character(info$value)
    if (identical(col, "canonical")) {
      draft$canonical[[i]] <- normalize_unknown(draft$canonical[[i]])
    }
    rv$draft <- draft
    rv$selected_draft_row <- i
    row <- rv$draft[rv$selected_draft_row, , drop = FALSE]
    updateTextInput(session, "selected_canonical", value = row$canonical[[1L]])
    updateTextAreaInput(session, "selected_notes", value = row$review_notes[[1L]] %||% "")
  })

  apply_selected_value <- function(canonical, notes = input$selected_notes %||% NA_character_) {
    if (is.null(rv$draft) || is.na(rv$selected_draft_row) || nrow(rv$draft) == 0L) return()
    i <- rv$selected_draft_row
    draft <- rv$draft
    draft$canonical[[i]] <- normalize_unknown(canonical)[[1L]]
    draft$review_notes[[i]] <- notes
    rv$draft <- draft
  }

  observeEvent(input$add_affiliation, {
    raw <- trimws(input$add_raw %||% "")
    if (!nzchar(raw) || is.null(rv$draft) || nrow(rv$draft) == 0L) return()

    article <- current_article()
    canonical <- normalize_unknown(input$add_canonical %||% "")[[1L]]
    new_row <- rv$draft[1L, , drop = FALSE]
    new_row$record_key <- rv$record_key
    new_row$doi <- article$doi[[1L]]
    new_row$doi_url <- article$doi_url[[1L]]
    new_row$title <- article$title[[1L]]
    new_row$year <- article$year[[1L]]
    new_row$authors <- article$authors[[1L]]
    new_row$raw <- raw
    new_row$canonical <- canonical
    new_row$new <- FALSE
    new_row$reviewed_at <- NA_character_
    new_row$review_notes <- NA_character_
    new_row$manual_added <- TRUE

    draft <- rv$draft
    existing <- tolower(trimws(draft$raw)) == tolower(raw)
    if (any(existing, na.rm = TRUE)) {
      idx <- which(existing)[[1L]]
      draft$canonical[[idx]] <- canonical
      draft$manual_added[[idx]] <- TRUE
      rv$draft <- draft
      rv$selected_draft_row <- idx
    } else {
      rv$draft <- bind_rows(draft, new_row)
      rv$selected_draft_row <- nrow(rv$draft)
    }
    updateTextInput(session, "add_raw", value = "")
    updateTextInput(session, "add_canonical", value = "")
  })

  observeEvent(input$apply_selected, {
    apply_selected_value(input$selected_canonical)
  })

  observeEvent(input$mark_selected_unknown, {
    apply_selected_value("Unknown")
    updateTextInput(session, "selected_canonical", value = "Unknown")
  })

  save_article <- function() {
    if (is.null(rv$draft) || nrow(rv$draft) == 0L) return()
    rows <- current_rows()
    stamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
    draft <- rv$draft
    draft$canonical <- normalize_unknown(draft$canonical)
    draft$new <- FALSE
    draft$reviewed_at <- stamp
    rv$draft <- draft
    remaining <- rv$data[-rows, , drop = FALSE]
    rv$data <- bind_rows(remaining, draft)
    write_lookup(rv$data)
  }

  advance <- function() {
    keys <- visible_articles()
    if (length(keys) == 0L) return()
    pos <- match(rv$record_key, keys)
    if (is.na(pos)) {
      rv$record_key <- keys[[1L]]
    } else {
      rv$record_key <- keys[[if (pos < length(keys)) pos + 1L else 1L]]
    }
  }

  retreat <- function() {
    keys <- visible_articles()
    if (length(keys) == 0L) return()
    pos <- match(rv$record_key, keys)
    if (is.na(pos)) {
      rv$record_key <- keys[[1L]]
    } else {
      rv$record_key <- keys[[if (pos > 1L) pos - 1L else length(keys)]]
    }
  }

  observeEvent(input$save_article, {
    save_article()
    reset_draft()
  })

  observeEvent(input$save_article_next, {
    save_article()
    advance()
  })

  observeEvent(input$skip, advance())
  observeEvent(input$back, retreat())

  canonical_table <- reactive({
    vals <- rv$data$canonical[
      !is.na(rv$data$canonical) &
        nzchar(trimws(rv$data$canonical)) &
        rv$data$canonical != "Unknown"
    ]
    reviewed <- as.data.frame(sort(table(vals), decreasing = TRUE), stringsAsFactors = FALSE)
    names(reviewed) <- c("canonical", "n_occurrences")

    if (isTRUE(input$include_reference)) {
      ref <- setdiff(load_reference(), reviewed$canonical)
      if (length(ref) > 0L) {
        reviewed <- bind_rows(
          reviewed,
          data.frame(canonical = ref, n_occurrences = 0L, stringsAsFactors = FALSE)
        )
      }
    }
    reviewed[order(tolower(reviewed$canonical)), , drop = FALSE]
  })

  output$canonical_browser <- renderDT({
    datatable(
      canonical_table(),
      rownames = FALSE,
      selection = "single",
      options = list(pageLength = 15, dom = "ftip")
    )
  })

  observeEvent(input$canonical_browser_rows_selected, {
    idx <- input$canonical_browser_rows_selected
    if (length(idx) == 1L) {
      value <- canonical_table()$canonical[[idx]]
      updateTextInput(session, "selected_canonical", value = value)
      apply_selected_value(value)
    }
  })

  article_queue_data <- reactive({
    keys <- visible_articles()
    out <- article_summary() |>
      filter(.data$record_key %in% keys) |>
      select(
        doi, title, year, n_affiliations, n_unknown, n_new, authors, record_key
      )
    out$.record_key <- out$record_key
    out$record_key <- NULL
    out
  })

  output$article_queue_table <- renderDT({
    datatable(
      article_queue_data() |>
        select(doi, title, year, n_affiliations, n_unknown, n_new, authors),
      rownames = FALSE,
      selection = "single",
      options = list(pageLength = 10, dom = "ftip", scrollX = TRUE)
    )
  })

  observeEvent(input$article_queue_table_rows_selected, {
    idx <- input$article_queue_table_rows_selected
    if (length(idx) == 1L) {
      rv$record_key <- article_queue_data()$.record_key[[idx]]
    }
  })
}

shinyApp(ui, server)
