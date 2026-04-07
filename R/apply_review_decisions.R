# Filter a publications tibble using saved manual review decisions.
#
# Reads `decisions_file` (a CSV with columns doi, decision, reviewed_at) and
# removes any record explicitly marked "drop".  Records marked "keep",
# "unsure", or not yet reviewed are retained.
#
# Used as a targets step so that running tar_make() after a review session
# automatically propagates decisions downstream.

apply_review_decisions <- function(pubs, decisions_file) {
  if (!file.exists(decisions_file)) {
    message("No review decisions file at: ", decisions_file, " — returning pubs unchanged.")
    return(pubs)
  }

  decisions <- readr::read_csv(decisions_file, col_types = readr::cols(
    doi         = readr::col_character(),
    decision    = readr::col_character(),
    reviewed_at = readr::col_character()
  ))

  drop_dois <- decisions$doi[decisions$decision == "drop"]
  n_dropped <- sum(pubs$doi %in% drop_dois)

  message(sprintf(
    "apply_review_decisions: dropping %d record(s) marked 'drop' (%d remaining).",
    n_dropped, nrow(pubs) - n_dropped
  ))

  dplyr::filter(pubs, !.data$doi %in% drop_dois)
}
