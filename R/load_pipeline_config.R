#' Load targets pipeline configuration
#'
#' @param path Path to the YAML configuration file.
#' @return A nested list of pipeline settings.
load_pipeline_config <- function(path = "config/pipeline.yml") {
  cfg <- yaml::read_yaml(path)

  if (is.null(cfg$llm$model) || !nzchar(cfg$llm$model)) {
    stop("Pipeline config must define llm.model.", call. = FALSE)
  }

  cfg
}
