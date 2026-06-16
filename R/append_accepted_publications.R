#' Append newly accepted records to the durable accepted-publications table
#'
#' Reads `accepted_path` if it exists, then appends only those records from
#' `pubs_new_enriched` whose `record_key` is not already present. Previously
#' accepted records are never overwritten in the default `new_records_only` mode.
#'
#' Accepted records receive provenance columns:
#'   - `accepted_at`              — datetime of acceptance
#'   - `accepted_refresh_id`      — refresh that produced this acceptance
#'   - `first_seen_at`            — copy of `accepted_at` on first write
#'   - `last_seen_at`             — datetime last confirmed in a harvest
#'   - `last_metadata_refresh_id` — refresh that last updated the record's metadata
#'   - `record_status`            — `"active"` by default
#'
#' @param pubs_new_enriched Tibble of newly classified and enriched publications
#'   eligible for acceptance: funder records not marked `drop`, plus
#'   affiliation-based candidates. Must contain a `record_key` column.
#' @param refresh_id        Character. The current refresh identifier.
#' @param accepted_path     Path to `data/generated/accepted_publications.parquet`.
#'
#' @return The path to the updated accepted-publications Parquet file.

append_accepted_publications <- function(
    pubs_new_enriched,
    refresh_id,
    accepted_path = "data/generated/accepted_publications.parquet"
) {
  now_str <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

  new_records <- dplyr::mutate(
    pubs_new_enriched,
    accepted_at                = now_str,
    accepted_refresh_id        = refresh_id,
    first_seen_at              = now_str,
    last_seen_at               = now_str,
    last_metadata_refresh_id   = refresh_id,
    record_status              = "active"
  )

  if (file.exists(accepted_path)) {
    existing  <- arrow::read_parquet(accepted_path)
    new_keys  <- setdiff(new_records$record_key, existing$record_key)
    to_append <- dplyr::filter(new_records, .data$record_key %in% new_keys)

    message(sprintf(
      "append_accepted_publications: appending %d new record(s); %d already accepted (skipped).",
      nrow(to_append), nrow(new_records) - nrow(to_append)
    ))

    if (nrow(to_append) > 0L) {
      # Align column sets before binding
      only_in_existing  <- setdiff(names(existing),   names(to_append))
      only_in_new       <- setdiff(names(to_append),  names(existing))
      existing          <- dplyr::mutate(existing,
                             dplyr::across(dplyr::all_of(only_in_new),      ~NA))
      to_append         <- dplyr::mutate(to_append,
                             dplyr::across(dplyr::all_of(only_in_existing), ~NA))
      combined <- dplyr::bind_rows(existing, to_append)
    } else {
      combined <- existing
    }
  } else {
    dir.create(dirname(accepted_path), recursive = TRUE, showWarnings = FALSE)
    message(sprintf(
      "append_accepted_publications: creating new accepted-publications table with %d record(s).",
      nrow(new_records)
    ))
    combined <- new_records
  }

  arrow::write_parquet(combined, accepted_path)
  accepted_path
}
