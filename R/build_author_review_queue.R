#' Build the author affiliation review queue for a refresh cycle
#'
#' Returns affiliation-side candidates from `pubs_harvest` that require manual
#' review. "Affiliation-side" includes both `"affiliation"` records and
#' `"funder; affiliation"` overlap records, so authorship can be confirmed
#' independently of the funder review.
#'
#' @param pubs_harvest   Tibble of harvested candidates (all query sources).
#' @param decisions_path Path to `data/decisions/author_review_decisions.csv`.
#' @param accepted_path  Path to `data/generated/accepted_publications.parquet`.
#' @param lookup_path    Path to `data/lookups/author_division_lookup.csv`.
#' @param include_unsure If `TRUE`, records previously marked `unsure` are
#'   re-queued for a second look.
#'
#' @return Tibble of candidates needing author review, scored with
#'   `score_author_affiliation()` and sorted by descending `caff_score`.

build_author_review_queue <- function(
    pubs_harvest,
    decisions_path = "data/decisions/author_review_decisions.csv",
    accepted_path  = "data/generated/accepted_publications.parquet",
    lookup_path    = "data/lookups/author_division_lookup.csv",
    include_unsure = FALSE
) {
  if (file.exists(decisions_path)) {
    decisions <- readr::read_csv(
      decisions_path,
      show_col_types = FALSE,
      col_types = readr::cols(.default = readr::col_character())
    )
  } else {
    decisions <- tibble::tibble(
      record_key        = character(),
      doi               = character(),
      decision          = character(),
      reviewed_at       = character(),
      review_refresh_id = character(),
      review_notes      = character()
    )
  }

  accepted_keys <- character()
  if (file.exists(accepted_path)) {
    accepted_keys <- arrow::read_parquet(accepted_path)$record_key
  }

  resolved_keys <- if (include_unsure) {
    decisions$record_key[decisions$decision %in% c("keep", "drop")]
  } else {
    decisions$record_key
  }

  affil_pubs <- dplyr::filter(
    pubs_harvest,
    grepl("affiliation", .data$query_source, fixed = TRUE)
  )

  queue <- dplyr::filter(
    affil_pubs,
    !.data$record_key %in% accepted_keys,
    !.data$record_key %in% resolved_keys
  )

  if (include_unsure) {
    unsure_keys <- decisions$record_key[decisions$decision == "unsure"]
    unsure_pubs <- dplyr::filter(affil_pubs, .data$record_key %in% unsure_keys)
    queue <- dplyr::bind_rows(queue, unsure_pubs) |>
      dplyr::distinct(.data$record_key, .keep_all = TRUE)
  }

  queue <- score_author_affiliation(queue, lookup_path) |>
    dplyr::arrange(dplyr::desc(.data$caff_score), .data$doi)

  message(sprintf(
    paste0(
      "build_author_review_queue: %d record(s) need review ",
      "(%d affiliation-side candidates; %d already accepted; %d already reviewed)."
    ),
    nrow(queue),
    nrow(affil_pubs),
    sum(affil_pubs$record_key %in% accepted_keys),
    sum(affil_pubs$record_key %in% resolved_keys)
  ))

  queue
}
