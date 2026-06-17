#' Build or update an institution geolocation lookup table
#'
#' Reads the reviewed affiliation lookup, extracts unique canonical institution
#' names, and sends any that have not yet been resolved to an OpenAI-compatible
#' LLM to determine country and US state. Existing resolved rows (including
#' intentional NAs) are never re-queried.
#'
#' @details
#' Output CSV columns:
#' \describe{
#'   \item{canonical}{Canonical institution name (primary key)}
#'   \item{country}{Full English country name, or `NA` when the country
#'     cannot be determined with confidence}
#'   \item{state}{Full US state name, or `NA` for non-US institutions or when
#'     the state is unclear. Only populated for United States institutions.}
#'   \item{resolved}{Logical flag. `TRUE` once the row has been through the
#'     LLM (even if `country` is `NA`). Prevents re-querying.}
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
  base_url                = NULL
) {
  llm_defaults <- .geo_llm_defaults()
  if (is.null(model)    || !nzchar(as.character(model)))    model    <- llm_defaults$model
  if (is.null(base_url) || !nzchar(as.character(base_url))) base_url <- llm_defaults$base_url

  system_prompt  <- .geo_read_prompt(system_prompt_path)
  user_template  <- .geo_read_prompt(user_template_path,
                                     required_placeholder = "{{institution_list}}")

  existing <- .read_existing_geo_lookup(output_path)

  # Unique reviewed canonicals from the affiliation lookup
  all_canonicals <- .geo_extract_canonicals(affiliation_lookup_path)

  # Only send canonicals not yet in the lookup with resolved == TRUE
  resolved_names <- existing$canonical[existing$resolved]
  new_canonicals <- setdiff(all_canonicals, resolved_names)

  message(sprintf(
    "build_institution_geo_lookup: %d unique reviewed canonical(s); %d already resolved; %d to geolocate.",
    length(all_canonicals), length(resolved_names), length(new_canonicals)
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

      results <- .geo_label_batch(batch, model, api_key, base_url,
                                  system_prompt, user_template)
      new_rows_list[[b]] <- data.frame(
        canonical = batch,
        country   = .geo_normalize_na(results$country),
        state     = .geo_normalize_na(results$state),
        resolved  = TRUE,
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
  if (is.null(model)    || !nzchar(as.character(model)))
    stop("config/pipeline.yml must define llm.model.", call. = FALSE)
  if (is.null(base_url) || !nzchar(as.character(base_url)))
    stop("config/pipeline.yml must define llm.base_url.", call. = FALSE)
  list(model = as.character(model), base_url = as.character(base_url))
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

  required <- c("canonical", "country", "state", "resolved")
  for (col in setdiff(required, names(lookup))) {
    lookup[[col]] <- if (col == "resolved") "FALSE" else NA_character_
  }

  lookup$canonical <- as.character(lookup$canonical)
  lookup$country   <- as.character(lookup$country)
  lookup$state     <- as.character(lookup$state)
  lookup$resolved  <- tolower(trimws(lookup$resolved)) %in% c("true", "t", "1", "yes")

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
#' @return Data frame with columns `country` and `state`, in the same order.
#' @noRd
.geo_label_batch <- function(institutions, model, api_key, base_url,
                              system_prompt, user_template) {
  n <- length(institutions)
  numbered <- paste(
    vapply(seq_along(institutions),
           function(i) sprintf("%d. %s", i, institutions[[i]]),
           character(1L)),
    collapse = "\n"
  )
  user_msg <- gsub("{{institution_list}}", numbered, user_template, fixed = TRUE)

  endpoint <- paste0(gsub("/$", "", base_url), "/chat/completions")

  resp <- tryCatch(
    httr2::request(endpoint) |>
      httr2::req_headers(
        Authorization = paste("Bearer", api_key),
        `Content-Type` = "application/json"
      ) |>
      httr2::req_body_json(list(
        model    = model,
        messages = list(
          list(role = "system", content = system_prompt),
          list(role = "user",   content = user_msg)
        ),
        temperature = 0
      )) |>
      httr2::req_error(is_error = \(r) FALSE) |>
      httr2::req_perform(),
    error = function(e) {
      warning(sprintf(".geo_label_batch: request failed: %s", e$message))
      NULL
    }
  )

  na_result <- data.frame(
    country = rep(NA_character_, n),
    state   = rep(NA_character_, n),
    stringsAsFactors = FALSE
  )

  if (is.null(resp) || httr2::resp_status(resp) != 200L) {
    if (!is.null(resp)) {
      warning(sprintf(".geo_label_batch: HTTP %d — %s",
                      httr2::resp_status(resp),
                      httr2::resp_body_string(resp)))
    }
    return(na_result)
  }

  raw_text <- httr2::resp_body_json(resp)$choices[[1L]]$message$content
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
    return(na_result)
  }

  parsed$index   <- as.integer(parsed$index)
  parsed$country <- as.character(parsed$country)
  parsed$state   <- as.character(parsed$state)

  if (!setequal(parsed$index, seq_len(n))) {
    warning(sprintf(
      ".geo_label_batch: expected indices 1-%d; got: %s. Returning NA for batch.",
      n, paste(sort(parsed$index), collapse = ", ")
    ))
    return(na_result)
  }

  parsed <- parsed[order(parsed$index), , drop = FALSE]
  data.frame(
    country = parsed$country,
    state   = parsed$state,
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

#' Merge new geo rows into the existing lookup, preserving existing rows
#' @noRd
.geo_merge <- function(existing, new_rows) {
  if (nrow(existing) == 0L) return(new_rows)
  # New rows for canonicals not yet in existing
  truly_new <- new_rows[!new_rows$canonical %in% existing$canonical, , drop = FALSE]
  if (nrow(truly_new) == 0L) return(existing)
  rbind(existing, truly_new)
}
