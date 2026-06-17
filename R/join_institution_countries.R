#' Join institution countries onto publications
#'
#' Reads `institution_geo_lookup.csv` and adds an `affiliation_countries`
#' list column to `pubs`. Each element is a character vector of unique
#' countries associated with that publication's canonical affiliations.
#' Publications whose affiliations have no resolved country get an empty
#' character vector.
#'
#' @param pubs Tibble with an `affiliations` list column of canonical
#'   institution names (as produced by [apply_affiliation_lookup()]).
#' @param geo_lookup_path Path to `data/lookups/institution_geo_lookup.csv`.
#'
#' @return `pubs` with an `affiliation_countries` list column added.

join_institution_countries <- function(pubs, geo_lookup_path) {
  geo <- readr::read_csv(geo_lookup_path, show_col_types = FALSE,
                          col_types = readr::cols(.default = readr::col_character()))

  if (!all(c("canonical", "country") %in% names(geo))) {
    stop(sprintf(
      "join_institution_countries: %s must contain `canonical` and `country` columns.",
      geo_lookup_path
    ), call. = FALSE)
  }

  geo$country <- as.character(geo$country)
  valid <- !is.na(geo$country) & nzchar(trimws(geo$country))
  country_map <- setNames(geo$country[valid], geo$canonical[valid])

  pubs$affiliation_countries <- lapply(pubs$affiliations, function(affs) {
    affs <- unique(unlist(affs))
    affs <- affs[!is.na(affs) & nzchar(trimws(affs))]
    if (length(affs) == 0L) return(character(0L))
    countries <- unname(country_map[affs])
    unique(countries[!is.na(countries) & nzchar(trimws(countries))])
  })

  message(sprintf(
    "join_institution_countries: added affiliation_countries for %d publication(s).",
    nrow(pubs)
  ))
  pubs
}
