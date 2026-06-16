#' Append reviewed funder publications to the funding division lookup
#'
#' Reads the current lookup, accepted-publications table, and saved manual review
#' decisions. The lookup is restricted to funder records with an explicit
#' `"keep"` decision from the funding review step. Existing division assignments
#' are preserved for retained rows. Rows newly accepted in the current refresh
#' are prepended. The `new` flag is recalculated on every run and is `TRUE` only
#' for records newly accepted in the current refresh that still have a blank
#' division assignment.
#'
#' @param accepted_path  Path to `data/generated/accepted_publications.parquet`.
#' @param refresh_id     Character. Current refresh identifier.
#' @param decisions_path Path to `data/decisions/funding_review_decisions.csv`.
#' @param lookup_path    Path to `data/lookups/funding_division_lookup.csv`.
#'
#' @return The path to the updated lookup file (invisibly).

update_funding_division_lookup <- function(
    accepted_path,
    refresh_id,
    decisions_path = "data/decisions/funding_review_decisions.csv",
    lookup_path = "data/lookups/funding_division_lookup.csv"
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

  funder_pubs <- dplyr::mutate(funder_pubs, doi_key = tolower(trimws(.data$doi)))
  current_refresh_dois <- character()
  if ("accepted_refresh_id" %in% names(funder_pubs)) {
    current_refresh_dois <- funder_pubs |>
      dplyr::filter(.data$accepted_refresh_id == refresh_id) |>
      dplyr::pull("doi_key") |>
      unique()
    current_refresh_dois <- current_refresh_dois[
      !is.na(current_refresh_dois) & nzchar(current_refresh_dois)
    ]
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
  lookup <- lookup |>
    dplyr::mutate(doi_key = tolower(trimws(.data$doi))) |>
    dplyr::filter(.data$doi_key %in% keep_lookup_dois)

  funder_dois <- funder_pubs$doi_key[
    !is.na(funder_pubs$doi_key) & nzchar(funder_pubs$doi_key)
  ]
  new_dois <- setdiff(funder_dois, lookup$doi_key)

  if (length(new_dois) > 0L) {
    new_rows <- funder_pubs |>
      dplyr::filter(.data$doi_key %in% new_dois) |>
      dplyr::distinct(.data$doi, .keep_all = TRUE) |>
      dplyr::select(doi, year, title) |>
      dplyr::mutate(doi      = tolower(trimws(.data$doi)),
                    doi_url  = paste0("https://doi.org/", tolower(trimws(.data$doi))),
                    year     = as.character(.data$year),
                    division = NA_character_,
                    new      = "FALSE",
                    doi_key  = tolower(trimws(.data$doi))) |>
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

  lookup <- lookup |>
    dplyr::mutate(
      division_blank = is.na(.data$division) | !nzchar(trimws(.data$division)),
      new = dplyr::if_else(
        .data$doi_key %in% current_refresh_dois & .data$division_blank,
        "TRUE",
        "FALSE"
      )
    ) |>
    dplyr::select(-"doi_key", -"division_blank") |>
    dplyr::relocate(doi, doi_url, year, title, division, new)

  readr::write_csv(lookup, lookup_path, na = "")

  invisible(lookup_path)
}
