#' Require explicit config permission before calling Scopus
#'
#' Scopus calls are not secret, but they are external API calls that should only
#' happen during an intentional harvest step.
#'
#' @param pipeline_config Loaded pipeline configuration.
#'
#' @return Invisibly returns `TRUE` when Scopus calls are allowed.
require_scopus_api_allowed <- function(pipeline_config) {
  allowed <- isTRUE(pipeline_config$scopus$allow_api_calls)
  if (!allowed) {
    stop(
      paste(
        "Scopus API calls are disabled by config.",
        "To intentionally refresh harvested records, temporarily set",
        "`scopus.allow_api_calls: true` in config/pipeline.yml, run the harvest",
        "targets, then set it back to false before committing."
      ),
      call. = FALSE
    )
  }
  invisible(TRUE)
}
