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

  cfg
}
