#' Create or retrieve the current refresh identifier
#'
#' Returns a config-defined refresh identifier when present. Empty config values
#' default to today's date in `YYYY-MM-DD` format.
#'
#' @param pipeline_config Loaded pipeline configuration.
#'
#' @return Character refresh identifier.

create_refresh_id <- function(pipeline_config = NULL) {
  cfg_id <- NULL
  if (!is.null(pipeline_config)) {
    cfg_id <- pipeline_config$refresh$id
  }
  if (is.null(cfg_id) || length(cfg_id) == 0L || is.na(cfg_id)) {
    cfg_id <- ""
  }
  cfg_id <- trimws(as.character(cfg_id[[1L]]))
  if (nzchar(cfg_id)) {
    return(cfg_id)
  }

  format(Sys.Date(), "%Y-%m-%d")
}

#' Initialise a row in the refresh log for a new refresh cycle
#'
#' Creates `data/refresh_log.csv` if it does not exist. Appends a new row for
#' `refresh_id` with `started_at` set to the current time. If a row for
#' `refresh_id` already exists the function is a no-op.
#'
#' @param refresh_id Character. The refresh identifier.
#' @param log_path   Path to the refresh log CSV.

init_refresh_log <- function(refresh_id, log_path = "data/refresh_log.csv") {
  log_cols <- c(
    "refresh_id", "started_at", "completed_at", "scopus_query_date",
    "n_funder_candidates", "n_affiliation_candidates", "n_new_candidates",
    "n_reviewed", "n_kept", "n_dropped", "n_unsure", "n_accepted", "notes"
  )

  if (file.exists(log_path)) {
    log <- readr::read_csv(log_path, col_types = readr::cols(.default = readr::col_character()),
                           show_col_types = FALSE)
  } else {
    log <- do.call(tibble::tibble, setNames(rep(list(character()), length(log_cols)), log_cols))
    dir.create(dirname(log_path), recursive = TRUE, showWarnings = FALSE)
  }

  if (refresh_id %in% log$refresh_id) return(invisible(log))

  new_row <- tibble::tibble(
    refresh_id               = refresh_id,
    started_at               = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    completed_at             = NA_character_,
    scopus_query_date        = format(Sys.Date(), "%Y-%m-%d"),
    n_funder_candidates      = NA_character_,
    n_affiliation_candidates = NA_character_,
    n_new_candidates         = NA_character_,
    n_reviewed               = NA_character_,
    n_kept                   = NA_character_,
    n_dropped                = NA_character_,
    n_unsure                 = NA_character_,
    n_accepted               = NA_character_,
    notes                    = NA_character_
  )

  log <- dplyr::bind_rows(log, new_row)
  readr::write_csv(log, log_path)
  invisible(log)
}

#' Write completion statistics to the refresh log
#'
#' Updates the row for `refresh_id` with `completed_at` and any count fields
#' passed via `...`. Values supplied must match column names in the log.
#'
#' @param refresh_id Character. The refresh identifier.
#' @param log_path   Path to the refresh log CSV.
#' @param ...        Named integer or character values to write into log columns
#'   (e.g. `n_accepted = 42`).

complete_refresh_log <- function(refresh_id, log_path = "data/refresh_log.csv", ...) {
  if (!file.exists(log_path)) {
    warning("complete_refresh_log: no log found at ", log_path)
    return(invisible(NULL))
  }

  log <- readr::read_csv(log_path, col_types = readr::cols(.default = readr::col_character()),
                         show_col_types = FALSE)
  idx <- which(log$refresh_id == refresh_id)
  if (length(idx) == 0L) {
    warning("complete_refresh_log: refresh_id '", refresh_id, "' not found in log")
    return(invisible(log))
  }

  updates <- c(list(completed_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S")), list(...))
  for (nm in names(updates)) {
    if (nm %in% names(log)) log[[nm]][idx] <- as.character(updates[[nm]])
  }

  readr::write_csv(log, log_path)
  invisible(log)
}
