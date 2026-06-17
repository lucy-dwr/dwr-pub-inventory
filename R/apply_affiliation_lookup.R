#' Apply a canonical institution lookup table to the affiliations list column
#'
#' Reads the approved occurrence-level lookup CSV produced by
#' [build_affiliation_lookup()] and replaces every raw affiliation string in
#' `pubs$affiliations` with its canonical name. Current lookup files are keyed
#' by `record_key` and `raw`; legacy raw-only lookup files are still supported.
#' Occurrence-level lookup rows marked `manual_added = TRUE` are appended to the
#' matching publication after canonicalization.
#'
#' Strings not found in the lookup are left unchanged and a warning is issued
#' listing the first few, so they can be added to `affiliation_lookup.csv` and
#' the target re-run.
#'
#' Used as a targets step: edits to `affiliation_lookup.csv` automatically
#' invalidate `pubs_canonicalized` and all downstream outputs.
#'
#' @param pubs A tibble with an `affiliations` list column.
#' @param lookup_path Path to the lookup CSV with columns `raw`, `canonical`,
#'   and preferably `record_key`.
#' @param require_reviewed If `TRUE`, stop when the lookup contains rows marked
#'   `new = TRUE`.
#'
#' @return `pubs` with the `affiliations` list column flattened to one
#'   character vector per publication (across all authors) with each string
#'   replaced by its canonical name.

apply_affiliation_lookup <- function(pubs, lookup_path, require_reviewed = TRUE) {
  lookup <- readr::read_csv(lookup_path, show_col_types = FALSE)
  if (!all(c("raw", "canonical") %in% names(lookup))) {
    stop(sprintf(
      "apply_affiliation_lookup: %s must contain `raw` and `canonical` columns.",
      lookup_path
    ))
  }
  if (!"new" %in% names(lookup)) {
    lookup$new <- FALSE
  }
  if (!"manual_added" %in% names(lookup)) {
    lookup$manual_added <- FALSE
  }
  lookup$canonical <- .normalize_unknown_canonical(lookup$canonical)
  lookup$new <- .coerce_new_flag(lookup$new)
  lookup$manual_added <- .coerce_new_flag(lookup$manual_added)

  use_occurrence_lookup <- "record_key" %in% names(lookup) &&
    "record_key" %in% names(pubs) &&
    any(!is.na(lookup$record_key) & nzchar(trimws(as.character(lookup$record_key))))

  current_lookup <- lookup
  if (use_occurrence_lookup) {
    current_keys <- unique(as.character(pubs$record_key))
    current_lookup <- lookup[
      as.character(lookup$record_key) %in% current_keys,
      ,
      drop = FALSE
    ]
  }

  if (require_reviewed && any(current_lookup$new, na.rm = TRUE)) {
    stop(sprintf(
      paste0(
        "apply_affiliation_lookup: %d affiliation lookup row(s) are marked new. ",
        "Review %s, correct canonical values as needed, and set new to FALSE before publishing."
      ),
      sum(current_lookup$new, na.rm = TRUE),
      lookup_path
    ))
  }

  if (use_occurrence_lookup) {
    lookup_key <- .affiliation_occurrence_key(lookup$record_key, lookup$raw)
    lut <- setNames(lookup$canonical, lookup_key)

    missing <- character()
    manual_lookup <- lookup[
      lookup$manual_added &
        !is.na(lookup$record_key) &
        nzchar(trimws(as.character(lookup$record_key))) &
        !is.na(lookup$canonical) &
        nzchar(trimws(as.character(lookup$canonical))),
      ,
      drop = FALSE
    ]
    manual_by_record <- split(manual_lookup$canonical, as.character(manual_lookup$record_key))

    pubs$affiliations <- Map(function(affs_per_pub, record_key) {
      all_affs <- unlist(affs_per_pub)
      if (length(all_affs) > 0L) {
        keys <- .affiliation_occurrence_key(record_key, all_affs)
        mapped <- lut[keys]
        missing <<- c(missing, all_affs[is.na(mapped)])
        out <- unname(ifelse(is.na(mapped), all_affs, mapped))
      } else {
        out <- character(0L)
      }
      manual <- manual_by_record[[as.character(record_key)]]
      manual <- manual[!is.na(manual) & nzchar(trimws(manual))]
      unique(c(out, manual))
    }, pubs$affiliations, as.character(pubs$record_key))
  } else {
    lut <- setNames(lookup$canonical, lookup$raw)

    missing <- character()
    pubs$affiliations <- lapply(pubs$affiliations, function(affs_per_pub) {
      all_affs <- unlist(affs_per_pub)
      if (length(all_affs) == 0L) return(character(0L))
      mapped <- lut[all_affs]
      missing <<- c(missing, all_affs[is.na(mapped)])
      unname(ifelse(is.na(mapped), all_affs, mapped))
    })
  }

  missing <- unique(missing[!is.na(missing) & nzchar(trimws(missing))])
  if (length(missing) > 0L) {
    warning(sprintf(
      "apply_affiliation_lookup: %d affiliation occurrence(s) not in lookup — left unchanged:\n  %s",
      length(missing),
      paste(head(missing, 5L), collapse = "\n  ")
    ))
  }

  n_unknown <- sum(vapply(
    pubs$affiliations,
    function(affs) any(.normalize_unknown_canonical(affs) == "Unknown", na.rm = TRUE),
    logical(1L)
  ))
  if (n_unknown > 0L) {
    message(sprintf(
      "apply_affiliation_lookup: %d publication(s) retain at least one Unknown affiliation.",
      n_unknown
    ))
  }

  message(sprintf(
    "apply_affiliation_lookup: canonicalized affiliations for %d publications.",
    nrow(pubs)
  ))
  pubs
}

#' Normalize unresolved canonical institution markers
#'
#' @param x Character vector of canonical institution names.
#'
#' @return `x`, with any case variant of `"unknown"` converted to `"Unknown"`.
#'
#' @noRd
.normalize_unknown_canonical <- function(x) {
  x <- as.character(x)
  x[!is.na(x) & tolower(trimws(x)) == "unknown"] <- "Unknown"
  x
}

#' Coerce lookup review flags to logical
#'
#' @param x Vector read from the lookup `new` column.
#'
#' @return Logical vector.
#'
#' @noRd
.coerce_new_flag <- function(x) {
  if (is.logical(x)) {
    return(replace(x, is.na(x), FALSE))
  }
  vals <- tolower(trimws(as.character(x)))
  vals[is.na(vals) | !nzchar(vals)] <- "false"
  vals %in% c("true", "t", "1", "yes", "y")
}

#' Build an occurrence key for affiliation lookup joins
#'
#' @param record_key Publication record key.
#' @param raw Raw affiliation string.
#'
#' @return Character occurrence key.
#'
#' @noRd
.affiliation_occurrence_key <- function(record_key, raw) {
  paste(as.character(record_key), as.character(raw), sep = "\r")
}
