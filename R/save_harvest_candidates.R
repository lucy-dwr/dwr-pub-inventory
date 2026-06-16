#' Persist harvested candidate records for a single refresh cycle
#'
#' Writes a Parquet file to `data/harvests/harvest_<refresh_id>_candidates.parquet`.
#' The directory is created automatically if it does not exist.
#'
#' @param pubs       A tibble of harvested candidate publications.
#' @param refresh_id Character. The refresh identifier (used in the filename).
#' @param harvests_dir Path to the directory where harvest files are stored.
#'
#' @return The path to the written file (invisibly), for use as a targets file target.

save_harvest_candidates <- function(pubs, refresh_id,
                                    harvests_dir = "data/harvests") {
  dir.create(harvests_dir, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(harvests_dir,
                    sprintf("harvest_%s_candidates.parquet", refresh_id))
  arrow::write_parquet(pubs, path)
  message(sprintf(
    "save_harvest_candidates: wrote %d records to %s", nrow(pubs), path
  ))
  path
}
