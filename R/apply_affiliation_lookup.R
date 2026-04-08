#' Apply a canonical institution lookup table to the affiliations list column
#'
#' Reads the approved lookup CSV (columns: `raw`, `canonical`) produced by
#' [build_affiliation_lookup()] and replaces every raw affiliation string in
#' `pubs$affiliations` with its canonical name.
#'
#' Strings not found in the lookup are left unchanged and a warning is issued
#' listing the first few, so they can be added to `affiliation_lookup.csv` and
#' the target re-run.
#'
#' Used as a targets step: edits to `affiliation_lookup.csv` automatically
#' invalidate `pubs_canonicalized` and all downstream outputs.
#'
#' @param pubs A tibble with an `affiliations` list column.
#' @param lookup_path Path to the lookup CSV with columns `raw` and `canonical`.
#'
#' @return `pubs` with the `affiliations` list column flattened to one
#'   character vector per publication (across all authors) with each string
#'   replaced by its canonical name.

apply_affiliation_lookup <- function(pubs, lookup_path) {
  lookup <- readr::read_csv(lookup_path, col_types = readr::cols(
    raw       = readr::col_character(),
    canonical = readr::col_character()
  ))

  lut <- setNames(lookup$canonical, lookup$raw)

  all_raw <- unique(unlist(pubs$affiliations))
  missing <- all_raw[!is.na(all_raw) & !all_raw %in% names(lut)]
  if (length(missing) > 0L) {
    warning(sprintf(
      "apply_affiliation_lookup: %d affiliation string(s) not in lookup — left unchanged:\n  %s",
      length(missing),
      paste(head(missing, 5L), collapse = "\n  ")
    ))
  }

  pubs$affiliations <- lapply(pubs$affiliations, function(affs_per_pub) {
    all_affs <- unlist(affs_per_pub)
    if (length(all_affs) == 0L) return(character(0L))
    mapped <- lut[all_affs]
    unname(ifelse(is.na(mapped), all_affs, mapped))
  })

  n_unknown <- sum(vapply(
    pubs$affiliations,
    function(affs) any(affs == "UNKNOWN", na.rm = TRUE),
    logical(1L)
  ))
  if (n_unknown > 0L) {
    message(sprintf(
      "apply_affiliation_lookup: %d publication(s) retain at least one UNKNOWN affiliation.",
      n_unknown
    ))
  }

  message(sprintf(
    "apply_affiliation_lookup: canonicalized affiliations for %d publications.",
    nrow(pubs)
  ))
  pubs
}
