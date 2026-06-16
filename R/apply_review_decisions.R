#' Filter publications using saved manual review decisions
#'
#' Reads `decisions_file` and removes any record explicitly marked `"drop"`.
#' Records marked `"keep"`, `"unsure"`, or not yet reviewed are retained.
#'
#' Matching uses `record_key` when both the decisions table and `pubs` contain
#' that column; otherwise falls back to DOI for backwards compatibility.
#'
#' @param pubs           A tibble of publications.
#' @param decisions_file Path to a review decisions CSV.
#'
#' @return `pubs` with rows marked `"drop"` removed.

apply_review_decisions <- function(pubs, decisions_file) {
  if (!file.exists(decisions_file)) {
    message("apply_review_decisions: no file at ", decisions_file,
            " — returning pubs unchanged.")
    return(pubs)
  }

  decisions <- readr::read_csv(decisions_file, show_col_types = FALSE,
                               col_types = readr::cols(.default = readr::col_character()))

  use_record_key <- "record_key" %in% names(decisions) &&
                    "record_key" %in% names(pubs)

  if (use_record_key) {
    drop_keys <- decisions$record_key[decisions$decision == "drop"]
    drop_keys <- drop_keys[!is.na(drop_keys)]
    n_dropped <- sum(pubs$record_key %in% drop_keys)
    message(sprintf(
      "apply_review_decisions: dropping %d record(s) marked 'drop' (%d remaining).",
      n_dropped, nrow(pubs) - n_dropped
    ))
    dplyr::filter(pubs, !.data$record_key %in% drop_keys)
  } else {
    # Legacy DOI-based fallback
    drop_dois <- decisions$doi[decisions$decision == "drop"]
    drop_dois <- drop_dois[!is.na(drop_dois)]
    n_dropped <- sum(pubs$doi %in% drop_dois)
    message(sprintf(
      "apply_review_decisions: dropping %d record(s) marked 'drop' (%d remaining).",
      n_dropped, nrow(pubs) - n_dropped
    ))
    dplyr::filter(pubs, !.data$doi %in% drop_dois)
  }
}
