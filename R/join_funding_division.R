join_funding_division <- function(pubs, lookup_path) {
  if (!file.exists(lookup_path)) {
    return(dplyr::mutate(pubs, funding_division = NA_character_))
  }

  lookup <- readr::read_csv(
    lookup_path,
    show_col_types = FALSE,
    col_types = readr::cols(.default = readr::col_character())
  ) |>
    dplyr::filter(!is.na(.data$division) & nzchar(.data$division)) |>
    dplyr::transmute(doi_key = tolower(trimws(.data$doi)), funding_division = .data$division) |>
    dplyr::distinct(.data$doi_key, .keep_all = TRUE)

  pubs |>
    dplyr::mutate(doi_key = tolower(trimws(.data$doi))) |>
    dplyr::left_join(lookup, by = "doi_key") |>
    dplyr::select(-"doi_key")
}
