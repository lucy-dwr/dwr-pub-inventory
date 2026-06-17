#' Resolve the saved harvest candidates file for a refresh
#'
#' @param refresh_id Refresh identifier used in the harvest filename.
#' @param harvests_dir Directory containing harvest candidate snapshots.
#'
#' @return Path to the saved harvest candidates Parquet file.
resolve_harvest_candidates_file <- function(refresh_id, harvests_dir = "data/harvests") {
  path <- file.path(
    harvests_dir,
    sprintf("harvest_%s_candidates.parquet", refresh_id)
  )
  if (!file.exists(path)) {
    stop(
      paste(
        "Saved harvest candidates file not found:",
        path,
        "Run the intentional harvest step with scopus.allow_api_calls: true,",
        "then set it back to false before local review/publish steps."
      ),
      call. = FALSE
    )
  }
  path
}
