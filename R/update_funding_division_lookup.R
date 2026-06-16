#' Append reviewed funder publications to the funding division lookup
#'
#' Reads the current lookup, accepted-publications table, and saved manual review
#' decisions. The lookup is restricted to funder records with an explicit
#' `"keep"` decision from the funding review step. Existing division assignments
#' are preserved for retained rows.
#'
#' @param accepted_path  Path to `data/accepted_publications.parquet`.
#' @param decisions_path Path to `data/review_decisions.csv`.
#' @param lookup_path    Path to `data/funding_division_lookup.csv`.
#'
#' @return The path to the updated lookup file (invisibly).

update_funding_division_lookup <- function(
    accepted_path,
    decisions_path = "data/review_decisions.csv",
    lookup_path = "data/funding_division_lookup.csv"
) {
  accepted <- arrow::read_parquet(accepted_path)

  decisions <- readr::read_csv(decisions_path, show_col_types = FALSE,
                               col_types = readr::cols(.default = readr::col_character()))
  keep_decisions <- dplyr::filter(decisions, .data$decision == "keep")

  funder_pubs <- dplyr::filter(
    accepted,
    grepl("funder", .data$query_source, fixed = TRUE)
  )

  if ("record_key" %in% names(funder_pubs) && "record_key" %in% names(keep_decisions)) {
    funder_pubs <- dplyr::filter(funder_pubs, .data$record_key %in% keep_decisions$record_key)
  } else {
    keep_dois <- tolower(trimws(keep_decisions$doi))
    funder_pubs <- dplyr::filter(tolower(trimws(.data$doi)) %in% keep_dois)
  }

  if (file.exists(lookup_path)) {
    lookup <- readr::read_csv(lookup_path, show_col_types = FALSE,
                              col_types = readr::cols(.default = readr::col_character()))
  } else {
    lookup <- tibble::tibble(
      doi = character(),
      doi_url = character(),
      year = character(),
      title = character(),
      division = character(),
      new = character()
    )
  }
  if (!"new" %in% names(lookup)) {
    lookup <- dplyr::mutate(lookup, new = "FALSE")
  }

  keep_lookup_dois <- tolower(trimws(keep_decisions$doi))
  lookup <- dplyr::filter(lookup, tolower(trimws(.data$doi)) %in% keep_lookup_dois)

  new_dois <- setdiff(tolower(trimws(funder_pubs$doi)), tolower(trimws(lookup$doi)))

  if (length(new_dois) > 0L) {
    new_rows <- funder_pubs |>
      dplyr::filter(tolower(trimws(.data$doi)) %in% new_dois) |>
      dplyr::distinct(.data$doi, .keep_all = TRUE) |>
      dplyr::select(doi, year, title) |>
      dplyr::mutate(doi      = tolower(trimws(.data$doi)),
                    doi_url  = paste0("https://doi.org/", tolower(trimws(.data$doi))),
                    year     = as.character(.data$year),
                    division = NA_character_,
                    new      = "TRUE") |>
      dplyr::arrange(dplyr::desc(.data$year))

    lookup <- dplyr::bind_rows(new_rows, lookup) |>
      dplyr::relocate(doi, doi_url, year, title, division, new)

    message(sprintf(
      "update_funding_division_lookup: prepended %d new record(s) to %s",
      nrow(new_rows), lookup_path
    ))
  } else {
    message("update_funding_division_lookup: no new funder records to add")
  }

  readr::write_csv(lookup, lookup_path, na = "")

  invisible(lookup_path)
}
