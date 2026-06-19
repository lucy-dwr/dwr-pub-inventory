register_chat_tools <- function(
  chat_obj,
  session,
  input,
  filtered,
  pubs,
  selected_category,
  selected_papers,
  field_choices,
  YEAR_DEFAULT,
  all_categories
) {

  # ── set_filters ───────────────────────────────────────────────────────────────
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
        changed <- c(changed, paste0("Year → ", new_start, "–", new_end))
      }

      if (!is.null(science_category)) {
        if (science_category == "All") {
          selected_category(NULL)
          updateSelectInput(session, "f_field", choices = field_choices, selected = "All")
        } else {
          selected_category(science_category)
          fields <- pubs |>
            dplyr::filter(stringr::str_to_title(pc_category) == science_category) |>
            dplyr::pull(pc_field) |> stats::na.omit() |> unique() |> sort()
          updateSelectInput(session, "f_field",
            choices = c("All", fields), selected = "All")
        }
        changed <- c(changed, paste0("Science Category → ", science_category))
      }

      if (!is.null(science_field)) {
        updateSelectInput(session, "f_field", selected = science_field)
        changed <- c(changed, paste0("Science Field → ", science_field))
      }

      if (!is.null(division)) {
        updateSelectInput(session, "f_div", selected = division)
        changed <- c(changed, paste0("Division → ", division))
      }

      if (!is.null(contribution_type)) {
        updateSelectInput(session, "f_contrib", selected = contribution_type)
        changed <- c(changed, paste0("Contribution Type → ", contribution_type))
      }

      if (!is.null(affiliation)) {
        updateSelectInput(session, "f_affil", selected = affiliation)
        changed <- c(changed, paste0("Author Affiliation → ", affiliation))
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

  # ── reset_filters ─────────────────────────────────────────────────────────────
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

  # ── count_by ──────────────────────────────────────────────────────────────────
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
        cats <- stringr::str_to_title(df$pc_category[!is.na(df$pc_category)])
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

  # ── get_trend ─────────────────────────────────────────────────────────────────
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
          dplyr::filter(!is.na(year), !is.na(contribution_type)) |>
          dplyr::count(year, contribution_type, name = "n") |>
          dplyr::arrange(year)
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
        div_year <- auth_pairs |> dplyr::count(div, year, name = "n") |> dplyr::arrange(div, year)
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

  # ── compare_periods ───────────────────────────────────────────────────────────
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
          label, " (", min(d$year, na.rm = TRUE), "–",
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

  # ── find_papers ───────────────────────────────────────────────────────────────
  chat_obj$register_tool(ellmer::tool(
    function(query, max_results = 20L) {
      max_results <- as.integer(max_results)
      query_l     <- tolower(trimws(query))
      if (nchar(query_l) == 0L) return("Please provide a search query.")

      matches <- pubs |>
        dplyr::filter(
          stringr::str_detect(tolower(dplyr::coalesce(title,    "")), stringr::fixed(query_l)) |
          stringr::str_detect(tolower(dplyr::coalesce(abstract, "")), stringr::fixed(query_l)) |
          stringr::str_detect(tolower(authors_text),                  stringr::fixed(query_l))
        ) |>
        dplyr::arrange(dplyr::desc(year)) |>
        head(max_results)

      if (nrow(matches) == 0L)
        return(paste0("No papers found matching '", query, "'."))

      lines <- vapply(seq_len(nrow(matches)), function(i) {
        r   <- matches[i, ]
        doi <- if (!is.na(r$doi)) paste0(" — https://doi.org/", r$doi) else ""
        paste0(i, ". [key:", r$record_key, "] ",
               "(", dplyr::coalesce(as.character(r$year), "?"), ") ",
               dplyr::coalesce(r$title, "[No title]"),
               " / ", dplyr::coalesce(r$first_author, "?"), doi)
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
    "Full-text search across the entire inventory (title, abstract, authors) —
     independent of the current dashboard filters. Use when the user wants to
     find papers on a topic without changing the visible view.",
    arguments = list(
      query       = ellmer::type_string(
        "Keywords or phrase to search for", required = TRUE),
      max_results = ellmer::type_integer(
        "Maximum results to return (default 20)", required = FALSE)
    )
  ))

  # ── filter_to_papers ──────────────────────────────────────────────────────────
  chat_obj$register_tool(ellmer::tool(
    function(record_keys = NULL, dois = NULL, clear = FALSE) {
      if (isTRUE(clear)) {
        selected_papers(NULL)
        return("Paper selection cleared — dashboard now shows all papers matching other active filters.")
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

  # ── get_paper_detail ──────────────────────────────────────────────────────────
  chat_obj$register_tool(ellmer::tool(
    function(title_fragment = NULL, doi = NULL) {
      if (is.null(title_fragment) && is.null(doi))
        return("Provide either a title_fragment or a doi.")

      if (!is.null(doi)) {
        doi_clean <- tolower(trimws(doi))
        match <- pubs[!is.na(pubs$doi) & tolower(pubs$doi) == doi_clean, ]
      } else {
        frag  <- tolower(trimws(title_fragment))
        match <- pubs[stringr::str_detect(tolower(dplyr::coalesce(pubs$title, "")), stringr::fixed(frag)), ]
      }

      if (nrow(match) == 0L) return("No paper found matching those criteria.")
      if (nrow(match) > 3L)
        return(paste0(nrow(match), " papers matched — please be more specific. Titles:\n",
                      paste(head(match$title, 5L), collapse = "\n")))

      format_one <- function(r) {
        authors_str <- paste(unlist(r$authors), collapse = "; ")
        paste0(
          "Title:              ", dplyr::coalesce(r$title,    "Unknown"), "\n",
          "Authors:            ", if (nchar(authors_str) > 0L) authors_str else "Unknown", "\n",
          "Year:               ", dplyr::coalesce(as.character(r$year), "Unknown"), "\n",
          "Journal:            ", dplyr::coalesce(r$journal,  "Unknown"), "\n",
          "DOI:                ",
          if (!is.na(r$doi)) paste0("https://doi.org/", r$doi) else "None", "\n",
          "Science Field:      ", dplyr::coalesce(r$pc_field, "Unclassified"), "\n",
          "Science Category:   ", dplyr::coalesce(stringr::str_to_title(r$pc_category), "Unclassified"), "\n",
          "Contribution Type:  ", dplyr::coalesce(r$contribution_type, "Unknown"), "\n",
          "Division (Author):  ", dplyr::coalesce(r$author_division,  "Unknown"), "\n",
          "Division (Funder):  ", dplyr::coalesce(r$funding_division, "Unknown"), "\n",
          "Abstract:           ", dplyr::coalesce(r$abstract, "No abstract available")
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

  # ── synthesize_selection ──────────────────────────────────────────────────────
  chat_obj$register_tool(ellmer::tool(
    function() {
      df <- isolate(filtered())
      n  <- nrow(df)

      if (n == 0L)
        return("No papers are currently visible. Ask the user to adjust the filters.")

      if (n > 300L)
        return(paste0(
          "There are ", n, " papers in view — too many to synthesize at once. ",
          "Tell the user to narrow the selection first (field, contribution type, year range)."
        ))

      lines <- vapply(seq_len(n), function(i) {
        row <- df[i, ]
        paste0(i, ". (", dplyr::coalesce(as.character(row$year), "?"), ") ",
               dplyr::coalesce(row$title, "[No title]"),
               "\n   Abstract: ", dplyr::coalesce(row$abstract, "[No abstract available]"))
      }, character(1L))

      paste0("The current filtered view contains ", n, " paper",
             if (n == 1L) "" else "s",
             ". Titles and abstracts:\n\n", paste(lines, collapse = "\n\n"))
    },
    "Retrieve titles and abstracts of the currently filtered papers so you can
     synthesize or analyze them. Use for summary or theme questions about the
     *visible* selection. For searching the whole inventory, use find_papers instead."
  ))

  # ── get_author_stats ──────────────────────────────────────────────────────────
  chat_obj$register_tool(ellmer::tool(
    function(top_n = 10L) {
      df    <- isolate(filtered())
      top_n <- as.integer(top_n)
      if (nrow(df) == 0L) return("No papers in current view.")

      author_totals <- df |>
        dplyr::filter(!is.na(first_author)) |>
        dplyr::count(first_author, name = "total") |>
        dplyr::arrange(dplyr::desc(total)) |>
        head(top_n)

      lead_counts <- df |>
        dplyr::filter(!is.na(first_author), is_lead_author | is_sole_author) |>
        dplyr::count(first_author, name = "lead")

      result <- author_totals |>
        dplyr::left_join(lead_counts, by = "first_author") |>
        dplyr::mutate(lead = dplyr::coalesce(lead, 0L))

      lines <- paste0(
        seq_len(nrow(result)), ". ", result$first_author,
        " — total: ", result$total, ", lead/sole: ", result$lead
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

  # ── get_collaboration_stats ───────────────────────────────────────────────────
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

      tbl   <- sort(table(all_affs), decreasing = TRUE)
      top   <- head(tbl, top_n)
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

  # ── cite_papers ───────────────────────────────────────────────────────────────
  chat_obj$register_tool(ellmer::tool(
    function(max_papers = 10L, sort_by = "year_desc") {
      df         <- isolate(filtered())
      max_papers <- as.integer(max_papers)
      if (nrow(df) == 0L) return("No papers in current view.")

      if (!sort_by %in% c("year_desc", "year_asc", "title"))
        return("Invalid sort_by. Use: year_desc, year_asc, or title")

      df_sorted <- switch(sort_by,
        year_desc = dplyr::arrange(df, dplyr::desc(year), title),
        year_asc  = dplyr::arrange(df, year, title),
        title     = dplyr::arrange(df, title)
      )
      subset <- head(df_sorted, max_papers)

      lines <- vapply(seq_len(nrow(subset)), function(i) {
        r          <- subset[i, ]
        authors    <- paste(unlist(r$authors), collapse = ", ")
        if (nchar(authors) == 0L) authors <- "Unknown Authors"
        year_s     <- if (!is.na(r$year)) as.character(r$year) else "n.d."
        journal_s  <- dplyr::coalesce(r$journal, "")
        doi_s      <- if (!is.na(r$doi)) paste0(" https://doi.org/", r$doi) else ""
        paste0(
          i, ". ", authors, " (", year_s, "). ",
          dplyr::coalesce(r$title, "Untitled"), ".",
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
}
