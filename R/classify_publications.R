classify_publications <- function(pubs,
                                  taxonomy,
                                  provider,
                                  model,
                                  base_url = NULL,
                                  api_key = NULL,
                                  system_prompt = NULL,
                                  classify_instructions = NULL,
                                  batch_size = 2L,
                                  max_output_tokens = 600L,
                                  rate_limit = NULL,
                                  max_attempts = 3L,
                                  retry_wait_seconds = 65L,
                                  ...) {
  if (!inherits(taxonomy, "pc_taxonomy")) {
    stop("`taxonomy` must be a `pc_taxonomy` object. See pubclassify::pc_taxonomy().", call. = FALSE)
  }

  if (nrow(pubs) == 0L) {
    return(pubs)
  }

  if (nrow(taxonomy) >= 40L) {
    warning(
      sprintf(
        "Your taxonomy has %s fields. With use_embeddings = FALSE, the full taxonomy is included in every LLM call.",
        nrow(taxonomy)
      ),
      call. = FALSE
    )
  }

  package_env <- get(".pc_env", envir = asNamespace("pubclassify"))
  api_key <- api_key %||% package_env$llm_key %||% env_or_null("PUBCLASSIFY_LLM_KEY")
  base_url <- base_url %||% package_env$llm_base_url %||% env_or_null("PUBCLASSIFY_LLM_BASE_URL")
  provider <- provider %||% package_env$llm_provider %||% "anthropic"

  sys_msg <- system_prompt %||% paste(
    "You are a scientific literature classifier.",
    "You will be given a list of peer-reviewed publications (titles and/or abstracts) and a taxonomy of research categories.",
    "For each publication, assign exactly one category based on its central scientific objective - not the data type or methods used.",
    "Respond only with the structured output requested.",
    "Do not add commentary outside the JSON."
  )

  build_taxonomy_prompt <- getFromNamespace(".pc_build_taxonomy_prompt", "pubclassify")
  build_classify_text <- getFromNamespace(".pc_build_classify_text", "pubclassify")
  make_chat <- getFromNamespace(".pc_make_chat", "pubclassify")
  pc_classify_with_retry <- getFromNamespace(".pc_classify_with_retry", "pubclassify")

  full_taxonomy_prompt <- build_taxonomy_prompt(taxonomy)
  has_abstract <- !is.na(pubs$abstract) & nzchar(pubs$abstract)
  pubs$pc_text_source <- ifelse(has_abstract, "title+abstract", "title")
  pubs$pc_classified_by <- "llm-full"
  pubs$pc_field <- NA_character_
  pubs$pc_rationale <- NA_character_

  indices <- seq_len(nrow(pubs))
  batches <- split(indices, ceiling(indices / batch_size))
  cli::cli_progress_bar("Classifying publications", total = nrow(pubs))
  on.exit(cli::cli_progress_done(), add = TRUE)

  for (batch_idx in batches) {
    batch <- pubs[batch_idx, ]
    texts <- build_classify_text(batch$title, batch$abstract)
    chat_fn <- function() make_chat(
      provider, model, api_key, base_url, sys_msg,
      params = list(max_tokens = max_output_tokens), ...
    )
    classified <- NULL
    for (attempt in seq_len(max_attempts)) {
      .llm_reserve_output_tokens(max_output_tokens, rate_limit)
      classified <- pc_classify_with_retry(
        texts = texts,
        taxonomy_prompt = full_taxonomy_prompt,
        classify_instructions = classify_instructions,
        chat_fn = chat_fn,
        valid_fields = taxonomy$field,
        max_retries = 1L
      )
      incomplete <- is.na(classified$field) | !nzchar(trimws(classified$field)) |
        trimws(classified$field) == "NA"
      if (!any(incomplete)) break

      if (attempt < max_attempts) {
        message(sprintf(
          "Classification batch %d-%d incomplete after attempt %d/%d; waiting %ds before retrying.",
          batch_idx[[1L]], tail(batch_idx, 1L), attempt, max_attempts, retry_wait_seconds
        ))
        Sys.sleep(retry_wait_seconds)
      }
    }

    incomplete <- is.na(classified$field) | !nzchar(trimws(classified$field)) |
      trimws(classified$field) == "NA"
    if (any(incomplete)) {
      stop(sprintf(
        "Classification failed after %d delayed attempt(s) for publication row(s): %s. No records were appended.",
        max_attempts, paste(batch_idx[incomplete], collapse = ", ")
      ), call. = FALSE)
    }

    pubs$pc_field[batch_idx] <- classified$field
    pubs$pc_rationale[batch_idx] <- classified$rationale
    cli::cli_progress_update(inc = length(batch_idx))
  }

  pubs
}

env_or_null <- function(name) {
  value <- Sys.getenv(name, unset = NA_character_)
  if (is.na(value) || !nzchar(value)) {
    NULL
  } else {
    value
  }
}

`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}
