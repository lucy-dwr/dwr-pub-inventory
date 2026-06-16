#' Build the manual-review queue for a refresh cycle
#'
#' Returns the subset of funder candidates from `pubs_harvest` that require
#' manual review: newly harvested records not yet in the accepted-publications
#' table and not already reviewed in a prior cycle.
#'
#' Records previously marked `unsure` can be re-queued by setting
#' `include_unsure = TRUE`.
#'
#' @param pubs_harvest   Tibble of harvested candidates (all query sources) with
#'   a `record_key` column.
#' @param decisions_path Path to `data/funding_review_decisions.csv`.
#' @param accepted_path  Path to `data/accepted_publications.parquet`.
#' @param include_unsure Logical. If `TRUE`, records previously marked `unsure`
#'   are included in the queue for a second look.
#'
#' @return A tibble of funder candidates that need review, scored with
#'   `score_dwr_relevance()` and sorted by descending `cdwr_score`.

build_funder_review_queue <- function(
    pubs_harvest,
    decisions_path = "data/funding_review_decisions.csv",
    accepted_path  = "data/accepted_publications.parquet",
    include_unsure = FALSE
) {
  # Load existing review decisions
  if (file.exists(decisions_path)) {
    decisions <- readr::read_csv(decisions_path, show_col_types = FALSE,
                                 col_types = readr::cols(.default = readr::col_character()))
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

  # Load already-accepted record keys (side read — not a formal targets dependency)
  accepted_keys <- character()
  if (file.exists(accepted_path)) {
    accepted_keys <- arrow::read_parquet(accepted_path)$record_key
  }

  # Determine which record keys are already resolved
  if (include_unsure) {
    resolved_keys <- decisions$record_key[decisions$decision %in% c("keep", "drop")]
  } else {
    resolved_keys <- decisions$record_key
  }

  # Focus review on funder candidates only (matching current app behaviour)
  funder_pubs <- dplyr::filter(pubs_harvest,
                               grepl("funder", .data$query_source, fixed = TRUE))

  queue <- dplyr::filter(funder_pubs,
                         !.data$record_key %in% accepted_keys,
                         !.data$record_key %in% resolved_keys)

  # Re-queue `unsure` records when requested
  if (include_unsure) {
    unsure_keys <- decisions$record_key[decisions$decision == "unsure"]
    unsure_pubs <- dplyr::filter(funder_pubs, .data$record_key %in% unsure_keys)
    queue <- dplyr::bind_rows(queue, unsure_pubs) |>
      dplyr::distinct(.data$record_key, .keep_all = TRUE)
  }

  queue <- score_dwr_relevance(queue) |>
    dplyr::arrange(dplyr::desc(.data$cdwr_score), .data$doi)

  message(sprintf(
    paste0("build_funder_review_queue: %d record(s) need review ",
           "(%d funder candidates; %d already accepted; %d already reviewed)."),
    nrow(queue),
    nrow(funder_pubs),
    sum(funder_pubs$record_key %in% accepted_keys),
    sum(funder_pubs$record_key %in% resolved_keys)
  ))

  queue
}
