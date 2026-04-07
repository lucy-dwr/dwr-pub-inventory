# Add DWR contribution boolean flags to a deduplicated publications tibble.
#
# Expects `pubs` to have:
#   - `query_source`  character — "funder", "affiliation", or "funder; affiliation"
#   - `affiliations`  list<character> — per-author institutional affiliations
#
# Adds four non-exclusive boolean columns:
#   - `is_funder`      TRUE if the record came from a funder search
#   - `is_author`      TRUE if the record came from an affiliation search OR any
#                      author has a DWR affiliation in the metadata
#   - `is_lead_author` TRUE if the first-listed author is DWR-affiliated
#   - `is_sole_author` TRUE if every author is DWR-affiliated
#
# The nesting relationship is: is_sole_author => is_lead_author => is_author.
# is_funder is independent and can be TRUE alongside any authorship flag.

flag_dwr_contributions <- function(pubs) {
  dwr_pattern <- "California Department of Water Resources"

  # Does the first author's affiliation(s) contain the DWR string?
  is_lead <- function(affil_list) {
    vapply(
      affil_list,
      function(x) length(x) > 0L && any(grepl(dwr_pattern, x[[1L]], ignore.case = TRUE)),
      logical(1L)
    )
  }

  # Do ALL authors' affiliations contain the DWR string?
  is_sole <- function(affil_list) {
    vapply(
      affil_list,
      function(x) length(x) > 0L && all(vapply(x, function(a) any(grepl(dwr_pattern, a, ignore.case = TRUE)), logical(1L))),
      logical(1L)
    )
  }

  lead <- is_lead(pubs$affiliations)
  sole <- is_sole(pubs$affiliations)

  dplyr::mutate(
    pubs,
    is_funder      = grepl("funder",      query_source, fixed = TRUE),
    is_author      = grepl("affiliation", query_source, fixed = TRUE) | lead | sole,
    is_lead_author = lead,
    is_sole_author = sole
  )
}
