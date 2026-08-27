#' Reserve output-token capacity from a local rolling-window budget
#'
#' LLM targets run in separate R processes, so the reservation ledger is stored
#' on disk. This keeps sequential pipeline phases from independently assuming
#' that the full provider quota is available.
#'
#' @param tokens Maximum output tokens to reserve for the request.
#' @param config Named list with `output_tokens_per_minute`, `safety_fraction`,
#'   and `state_path`.
#' @return Invisibly `NULL` after capacity has been reserved.
#' @noRd
.llm_reserve_output_tokens <- function(tokens, config) {
  if (is.null(config)) return(invisible(NULL))

  limit <- as.numeric(config$output_tokens_per_minute)
  fraction <- as.numeric(config$safety_fraction)
  path <- as.character(config$state_path)
  budget <- floor(limit * fraction)
  tokens <- as.numeric(tokens)
  if (!is.finite(limit) || !is.finite(fraction) || !is.finite(tokens) ||
      limit <= 0 || fraction <= 0 || fraction > 1 || tokens <= 0 || tokens > budget) {
    stop("Invalid LLM rate-limit configuration or reservation.", call. = FALSE)
  }

  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  repeat {
    now <- as.numeric(Sys.time())
    ledger <- if (file.exists(path)) {
      readr::read_csv(path, show_col_types = FALSE,
                       col_types = readr::cols(timestamp = readr::col_double(),
                                               tokens = readr::col_double()))
    } else {
      data.frame(timestamp = numeric(), tokens = numeric())
    }
    ledger <- ledger[ledger$timestamp > now - 60, , drop = FALSE]

    if (sum(ledger$tokens) + tokens <= budget) {
      ledger <- rbind(ledger, data.frame(timestamp = now, tokens = tokens))
      readr::write_csv(ledger, path)
      return(invisible(NULL))
    }

    wait <- max(1, ceiling(min(ledger$timestamp) + 60 - now))
    message(sprintf(
      "LLM rate limit: reserving %d output tokens would exceed the %d/min budget; waiting %ds.",
      tokens, budget, wait
    ))
    Sys.sleep(wait)
  }
}
