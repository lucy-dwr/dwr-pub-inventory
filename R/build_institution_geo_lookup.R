#' Build or update an institution geolocation lookup table
#'
#' Reads the reviewed affiliation lookup, extracts unique canonical institution
#' names, and sends unresolved or failed-request rows to the configured LLM to
#' determine country and US state. Confirmed unknowns are never re-queried.
#'
#' @details
#' Output CSV columns:
#' \describe{
#'   \item{canonical}{Canonical institution name (primary key)}
#'   \item{country}{Full English country name, or `NA` when the country
#'     cannot be determined with confidence}
#'   \item{state}{Full US state name, or `NA` for non-US institutions or when
#'     the state is unclear. Only populated for United States institutions.}
#'   \item{status}{One of `"resolved"`, `"unknown"`, or `"request_failed"`.
#'     Only `"request_failed"` rows are retried automatically.}
#'   \item{error}{Request failure detail, when applicable.}
#'   \item{resolved}{Legacy compatibility flag; `TRUE` for terminal rows.}
#' }
#'
#' @param affiliation_lookup_path Path to `data/lookups/affiliation_lookup.csv`.
#' @param output_path Path to write the geo lookup CSV.
#' @param system_prompt_path Path to the geo system prompt.
#' @param user_template_path Path to the geo user prompt template. Must contain
#'   `{{institution_list}}`.
#' @param batch_size Number of institutions to send per LLM call.
#' @param model LLM model name. Defaults to `llm.model` in `config/pipeline.yml`.
#' @param api_key API key (reads `PUBCLASSIFY_LLM_KEY` by default).
#' @param base_url OpenAI-compatible base URL. Defaults to `llm.base_url` in
#'   `config/pipeline.yml`.
#' @param provider LLM API protocol: `"anthropic"` or `"openai-compatible"`.
#'
#' @return Invisibly, the updated geo lookup data frame.

build_institution_geo_lookup <- function(
  affiliation_lookup_path = "data/lookups/affiliation_lookup.csv",
  output_path             = "data/lookups/institution_geo_lookup.csv",
  system_prompt_path      = "prompts/geo_system_prompt.txt",
  user_template_path      = "prompts/geo_user_template.txt",
  batch_size              = 50L,
  model                   = NULL,
  api_key                 = Sys.getenv("PUBCLASSIFY_LLM_KEY"),
  base_url                = NULL,
  provider                = NULL,
  max_output_tokens       = 600L,
  rate_limit              = NULL,
  max_attempts            = 3L,
  retry_wait_seconds      = 65L
) {
  llm_defaults <- .geo_llm_defaults()
  if (is.null(model)    || !nzchar(as.character(model)))    model    <- llm_defaults$model
  if (is.null(base_url) || !nzchar(as.character(base_url))) base_url <- llm_defaults$base_url
  if (is.null(provider) || !nzchar(as.character(provider))) provider <- llm_defaults$provider

  system_prompt  <- .geo_read_prompt(system_prompt_path)
  user_template  <- .geo_read_prompt(user_template_path,
                                     required_placeholder = "{{institution_list}}")

  existing <- .read_existing_geo_lookup(output_path)

  # Unique reviewed canonicals from the affiliation lookup
  all_canonicals <- .geo_extract_canonicals(affiliation_lookup_path)

  terminal_names <- existing$canonical[existing$status %in% c("resolved", "unknown")]
  new_canonicals <- setdiff(all_canonicals, terminal_names)

  message(sprintf(
    "build_institution_geo_lookup: %d unique reviewed canonical(s); %d terminal; %d to geolocate.",
    length(all_canonicals), length(terminal_names), length(new_canonicals)
  ))

  if (length(new_canonicals) > 0L) {
    n_batches <- ceiling(length(new_canonicals) / batch_size)
    new_rows_list <- vector("list", n_batches)

    for (b in seq_len(n_batches)) {
      idx_start <- (b - 1L) * batch_size + 1L
      idx_end   <- min(b * batch_size, length(new_canonicals))
      batch     <- new_canonicals[idx_start:idx_end]

      message(sprintf(
        "LLM batch %d/%d (%d institution(s))...", b, n_batches, length(batch)
      ))

      results <- NULL
      for (attempt in seq_len(max_attempts)) {
        .llm_reserve_output_tokens(max_output_tokens, rate_limit)
        results <- .geo_label_batch(
          batch, model, api_key, base_url, provider, system_prompt,
          user_template, max_output_tokens
        )
        if (!all(results$status == "request_failed") || attempt == max_attempts) break
        message(sprintf(
          "Geo batch %d/%d failed; waiting %ds before retrying (%d/%d).",
          b, n_batches, retry_wait_seconds, attempt, max_attempts
        ))
        Sys.sleep(retry_wait_seconds)
      }
      new_rows_list[[b]] <- data.frame(
        canonical = batch,
        country   = .geo_normalize_na(results$country),
        state     = .geo_normalize_na(results$state),
        status    = results$status,
        error     = results$error,
        resolved  = results$status %in% c("resolved", "unknown"),
        stringsAsFactors = FALSE
      )
    }

    new_rows <- do.call(rbind, new_rows_list)
    existing <- .geo_merge(existing, new_rows)
  }

  existing <- existing[order(existing$canonical), , drop = FALSE]
  readr::write_csv(existing, output_path)
  message(sprintf(
    "build_institution_geo_lookup: wrote %s (%d row(s)).", output_path, nrow(existing)
  ))
  invisible(existing)
}

#' Read default LLM settings from pipeline config
#' @noRd
.geo_llm_defaults <- function() {
  cfg <- yaml::read_yaml("config/pipeline.yml")
  model    <- cfg$llm$model
  base_url <- cfg$llm$base_url
  provider <- cfg$llm$provider
  if (is.null(model)    || !nzchar(as.character(model)))
    stop("config/pipeline.yml must define llm.model.", call. = FALSE)
  if (is.null(base_url) || !nzchar(as.character(base_url)))
    stop("config/pipeline.yml must define llm.base_url.", call. = FALSE)
  if (is.null(provider) || !nzchar(as.character(provider)))
    stop("config/pipeline.yml must define llm.provider.", call. = FALSE)
  list(
    model = as.character(model),
    base_url = as.character(base_url),
    provider = as.character(provider)
  )
}

#' Read and optionally validate a prompt file
#' @noRd
.geo_read_prompt <- function(path, required_placeholder = NULL) {
  if (!file.exists(path))
    stop(sprintf("Geo prompt file not found: %s", path), call. = FALSE)
  text <- readr::read_file(path)
  if (!is.null(required_placeholder) &&
      !grepl(required_placeholder, text, fixed = TRUE)) {
    stop(sprintf("Prompt %s must contain placeholder %s.", path, required_placeholder),
         call. = FALSE)
  }
  text
}

#' Read existing geo lookup or return empty frame
#' @noRd
.read_existing_geo_lookup <- function(path) {
  if (!file.exists(path)) return(.empty_geo_lookup())

  lookup <- readr::read_csv(path, show_col_types = FALSE,
                             col_types = readr::cols(.default = readr::col_character()))

  required <- c("canonical", "country", "state", "resolved", "status", "error")
  for (col in setdiff(required, names(lookup))) {
    lookup[[col]] <- if (col == "resolved") "FALSE" else NA_character_
  }

  lookup$canonical <- as.character(lookup$canonical)
  lookup$country   <- as.character(lookup$country)
  lookup$state     <- as.character(lookup$state)
  lookup$resolved  <- tolower(trimws(lookup$resolved)) %in% c("true", "t", "1", "yes")
  lookup$status    <- tolower(trimws(as.character(lookup$status)))
  lookup$error     <- as.character(lookup$error)

  # Legacy files had only `resolved`: preserve a completed row with no country
  # as a confirmed unknown rather than repeatedly sending it to the LLM.
  missing_status <- is.na(lookup$status) | !nzchar(lookup$status)
  has_country <- !is.na(lookup$country) & nzchar(trimws(lookup$country))
  lookup$status[missing_status & lookup$resolved & has_country] <- "resolved"
  lookup$status[missing_status & lookup$resolved & !has_country] <- "unknown"
  lookup$status[missing_status & !lookup$resolved] <- "request_failed"
  lookup$status[!lookup$status %in% c("resolved", "unknown", "request_failed")] <- "request_failed"
  lookup$resolved <- lookup$status %in% c("resolved", "unknown")

  # Drop rows with missing canonical
  lookup <- lookup[!is.na(lookup$canonical) & nzchar(trimws(lookup$canonical)), , drop = FALSE]
  lookup[!duplicated(lookup$canonical), , drop = FALSE]
}

#' Empty geo lookup data frame
#' @noRd
.empty_geo_lookup <- function() {
  data.frame(
    canonical = character(),
    country   = character(),
    state     = character(),
    status    = character(),
    error     = character(),
    resolved  = logical(),
    stringsAsFactors = FALSE
  )
}

#' Extract unique reviewed canonical names from the affiliation lookup
#' @noRd
.geo_extract_canonicals <- function(affiliation_lookup_path) {
  if (!file.exists(affiliation_lookup_path)) {
    warning(sprintf(
      "build_institution_geo_lookup: affiliation lookup not found at %s.",
      affiliation_lookup_path
    ), call. = FALSE)
    return(character(0L))
  }

  lookup <- readr::read_csv(affiliation_lookup_path, show_col_types = FALSE,
                             col_types = readr::cols(.default = readr::col_character()))

  if (!all(c("canonical", "new") %in% names(lookup))) {
    stop("Affiliation lookup must contain `canonical` and `new` columns.", call. = FALSE)
  }

  is_new <- tolower(trimws(lookup$new)) %in% c("true", "t", "1", "yes")
  canonical <- lookup$canonical[
    !is_new &
      !is.na(lookup$canonical) &
      nzchar(trimws(lookup$canonical)) &
      tolower(trimws(lookup$canonical)) != "unknown"
  ]

  sort(unique(as.character(canonical)))
}

#' Call the LLM to geolocate a batch of institution names
#'
#' @param institutions Character vector of canonical institution names.
#' @return Data frame with `country`, `state`, `status`, and `error` columns.
#' @noRd
.geo_label_batch <- function(institutions, model, api_key, base_url, provider,
                              system_prompt, user_template, max_output_tokens = 600L) {
  n <- length(institutions)
  numbered <- paste(
    vapply(seq_along(institutions),
           function(i) sprintf("%d. %s", i, institutions[[i]]),
           character(1L)),
    collapse = "\n"
  )
  user_msg <- gsub("{{institution_list}}", numbered, user_template, fixed = TRUE)

  is_anthropic <- identical(provider, "anthropic")
  endpoint <- paste0(gsub("/$", "", base_url), if (is_anthropic) "/messages" else "/chat/completions")
  request <- httr2::request(endpoint) |>
    httr2::req_headers(`Content-Type` = "application/json")
  if (is_anthropic) {
    request <- request |>
      httr2::req_headers(`x-api-key` = api_key, `anthropic-version` = "2023-06-01") |>
      httr2::req_body_json(list(
        model = model,
        max_tokens = max_output_tokens,
        system = system_prompt,
        messages = list(list(role = "user", content = user_msg))
      ))
  } else if (identical(provider, "openai-compatible")) {
    request <- request |>
      httr2::req_headers(Authorization = paste("Bearer", api_key)) |>
      httr2::req_body_json(list(
        model = model,
        max_tokens = max_output_tokens,
        messages = list(
          list(role = "system", content = system_prompt),
          list(role = "user", content = user_msg)
        ),
        temperature = 0
      ))
  } else {
    stop(sprintf("Unsupported LLM provider: %s", provider), call. = FALSE)
  }

  resp <- tryCatch(
    request |>
      httr2::req_error(is_error = \(r) FALSE) |>
      httr2::req_perform(),
    error = function(e) {
      warning(sprintf(".geo_label_batch: request failed: %s", e$message))
      NULL
    }
  )

  failed_result <- function(error) data.frame(
    country = rep(NA_character_, n),
    state   = rep(NA_character_, n),
    status  = rep("request_failed", n),
    error   = rep(error, n),
    stringsAsFactors = FALSE
  )

  if (is.null(resp) || httr2::resp_status(resp) != 200L) {
    if (!is.null(resp)) {
      warning(sprintf(".geo_label_batch: HTTP %d — %s",
                      httr2::resp_status(resp),
                      httr2::resp_body_string(resp)))
    }
    error <- if (is.null(resp)) {
      "Request failed before receiving a response."
    } else {
      paste0("HTTP ", httr2::resp_status(resp), ": ", httr2::resp_body_string(resp))
    }
    return(failed_result(error))
  }

  body <- httr2::resp_body_json(resp)
  raw_text <- if (is_anthropic) {
    text_blocks <- Filter(function(block) identical(block$type, "text"), body$content)
    paste(vapply(text_blocks, function(block) block$text, character(1L)), collapse = "\n")
  } else {
    body$choices[[1L]]$message$content
  }
  raw_text <- gsub("^```(?:json)?\\s*|\\s*```$", "", trimws(raw_text), perl = TRUE)

  parsed <- tryCatch(
    jsonlite::fromJSON(raw_text, simplifyDataFrame = TRUE),
    error = function(e) {
      warning(sprintf(".geo_label_batch: JSON parse failed: %s\nRaw:\n%s",
                      e$message, raw_text))
      NULL
    }
  )

  if (is.null(parsed) || !all(c("index", "country", "state") %in% names(parsed))) {
    warning(".geo_label_batch: unexpected JSON structure; returning NA for batch.")
    return(failed_result("Response did not contain the expected JSON."))
  }

  parsed$index   <- as.integer(parsed$index)
  parsed$country <- .geo_normalize_na(parsed$country)
  parsed$state   <- .geo_normalize_na(parsed$state)

  if (!setequal(parsed$index, seq_len(n))) {
    warning(sprintf(
      ".geo_label_batch: expected indices 1-%d; got: %s. Returning NA for batch.",
      n, paste(sort(parsed$index), collapse = ", ")
    ))
    return(failed_result("Response did not contain every requested institution index."))
  }

  parsed <- parsed[order(parsed$index), , drop = FALSE]
  data.frame(
    country = parsed$country,
    state   = parsed$state,
    status  = ifelse(!is.na(parsed$country) & nzchar(trimws(parsed$country)), "resolved", "unknown"),
    error   = NA_character_,
    stringsAsFactors = FALSE
  )
}

#' Normalize character NA representations to true NA
#' @noRd
.geo_normalize_na <- function(x) {
  x <- as.character(x)
  x[is.na(x) | tolower(trimws(x)) %in% c("na", "null", "none", "")] <- NA_character_
  x
}

#' Merge new geo rows into the existing lookup, replacing retried rows
#' @noRd
.geo_merge <- function(existing, new_rows) {
  if (nrow(existing) == 0L) return(new_rows)
  existing <- existing[!existing$canonical %in% new_rows$canonical, , drop = FALSE]
  rbind(existing, new_rows)
}
