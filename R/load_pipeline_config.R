#' Load targets pipeline configuration
#'
#' @param path Path to the YAML configuration file.
#' @return A nested list of pipeline settings.
load_pipeline_config <- function(path = "config/pipeline.yml") {
  cfg <- yaml::read_yaml(path)

  if (is.null(cfg$llm$model) || !nzchar(cfg$llm$model)) {
    stop("Pipeline config must define llm.model.", call. = FALSE)
  }

  if (is.null(cfg$refresh)) {
    cfg$refresh <- list()
  }
  if (is.null(cfg$refresh$id)) {
    cfg$refresh$id <- ""
  }
  if (is.null(cfg$refresh$default_mode) || !nzchar(cfg$refresh$default_mode)) {
    cfg$refresh$default_mode <- "new_records_only"
  }
  if (!cfg$refresh$default_mode %in% c("new_records_only", "reclassify_all")) {
    stop(
      "Pipeline config refresh.default_mode must be `new_records_only` or `reclassify_all`.",
      call. = FALSE
    )
  }

  if (is.null(cfg$scopus$allow_api_calls)) {
    cfg$scopus$allow_api_calls <- FALSE
  }

  defaults <- list(
    output_tokens_per_minute = 2000,
    safety_fraction = 0.8,
    state_path = "data/generated/llm_rate_limit.csv",
    classification_batch_size = 2L,
    classification_max_output_tokens = 600L,
    geo_batch_size = 20L,
    geo_max_output_tokens = 600L,
    affiliation_batch_size = 10L,
    affiliation_max_output_tokens = 600L,
    max_attempts = 3L,
    retry_wait_seconds = 65L
  )
  if (is.null(cfg$llm$rate_limit)) cfg$llm$rate_limit <- list()
  cfg$llm$rate_limit <- utils::modifyList(defaults, cfg$llm$rate_limit)

  cfg
}
