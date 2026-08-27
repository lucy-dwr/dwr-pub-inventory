#' Build a canonical institution lookup table from affiliation occurrences
#'
#' Builds one durable lookup row per publication/raw-affiliation occurrence,
#' while sending only unique raw strings to an OpenAI-compatible LLM.
#' The LLM canonicalization is applied back to each occurrence so ambiguous
#' generic strings can be resolved differently during manual review.
#'
#' @details
#' Output CSV columns:
#' \describe{
#'   \item{record_key}{Stable publication key}
#'   \item{doi}{Publication DOI}
#'   \item{doi_url}{DOI URL}
#'   \item{title}{Publication title}
#'   \item{year}{Publication year, when available}
#'   \item{raw}{Raw string exactly as it appears in `pubs$affiliations`}
#'   \item{canonical}{Canonical institution name, or `"Unknown"` if
#'     unresolvable}
#'   \item{new}{Logical flag marking unresolved rows that need human review}
#'   \item{reviewed_at}{Manual review timestamp, if reviewed}
#'   \item{review_notes}{Optional manual review notes}
#' }
#'
#' After reviewing (and manually correcting) the CSV, it is tracked by the
#' `affiliation_lookup_file` target and consumed by [apply_affiliation_lookup()].
#'
#' Typical usage:
#' ```r
#' source("R/build_affiliation_lookup.R")
#' pubs_to_publish <- targets::tar_read(pubs_to_publish)
#' build_affiliation_lookup(pubs_to_publish, model = "<model-name>")
#' ```
#'
#' @param pubs Tibble with an `affiliations` list column.
#' @param output_path Path to write the lookup CSV.
#' @param reference_path Path to the institution reference list produced by
#'   [build_institution_reference()]; one canonical name per line. If the file
#'   does not exist, the LLM receives no reference list and a warning is issued.
#' @param system_prompt_path Path to the affiliation canonicalization system
#'   prompt template. Must contain `{{reference_section}}`.
#' @param user_template_path Path to the affiliation canonicalization user
#'   prompt template. Must contain `{{cluster_blocks}}`.
#' @param batch_size Number of clusters to send per LLM API call.
#' @param threshold Optional Jaro-Winkler distance cut height for fuzzy
#'   clustering. Defaults to `NULL`, which sends each unique raw string as its
#'   own cluster to avoid grouping distinct institutions with similar names.
#' @param model LLM model name passed to the API. Defaults to `llm.model` in
#'   `config/pipeline.yml`.
#' @param api_key API key (reads `PUBCLASSIFY_LLM_KEY` by default).
#' @param base_url LLM base URL. Defaults to `llm.base_url` in
#'   `config/pipeline.yml`.
#' @param provider LLM API protocol. Defaults to `llm.provider` in
#'   `config/pipeline.yml`.
#'
#' @return Invisibly, the occurrence-level lookup data frame.

build_affiliation_lookup <- function(
  pubs,
  output_path    = "data/lookups/affiliation_lookup.csv",
  reference_path = "data/lookups/institution_reference.txt",
  system_prompt_path = "prompts/affiliation_system_prompt.txt",
  user_template_path = "prompts/affiliation_user_template.txt",
  batch_size     = 50L,
  threshold      = NULL,
  model = NULL,
  api_key  = Sys.getenv("PUBCLASSIFY_LLM_KEY"),
  base_url = NULL,
  provider = NULL,
  max_output_tokens = 600L,
  rate_limit = NULL
) {
  llm_defaults <- .affiliation_llm_defaults()
  if (is.null(model) || !nzchar(as.character(model))) model <- llm_defaults$model
  if (is.null(base_url) || !nzchar(as.character(base_url))) base_url <- llm_defaults$base_url
  if (is.null(provider) || !nzchar(as.character(provider))) provider <- llm_defaults$provider

  existing_lookup <- .read_existing_lookup(output_path)
  reference <- .combined_reference(reference_path, existing_lookup)
  system_prompt_template <- .read_prompt_template(
    system_prompt_path,
    required_placeholder = "{{reference_section}}"
  )
  user_prompt_template <- .read_prompt_template(
    user_template_path,
    required_placeholder = "{{cluster_blocks}}"
  )
  
  # ---- Stage 1: Build occurrence inventory ----------------------------------

  occurrences <- .build_affiliation_occurrences(pubs)
  if (nrow(occurrences) == 0L) {
    readr::write_csv(existing_lookup, output_path)
    message(sprintf(
      "build_affiliation_lookup: no current affiliation occurrences; wrote %s unchanged (%d rows).",
      output_path,
      nrow(existing_lookup)
    ))
    return(invisible(existing_lookup))
  }

  occurrences <- .apply_existing_occurrence_reviews(occurrences, existing_lookup)
  occurrences <- .apply_trusted_raw_canonical(occurrences, existing_lookup)

  needs_label <- is.na(occurrences$canonical) |
    !nzchar(trimws(occurrences$canonical)) |
    (occurrences$new & occurrences$canonical == "Unknown")
  raw_affs <- unique(occurrences$raw[needs_label])
  raw_affs <- raw_affs[!is.na(raw_affs) & nzchar(trimws(raw_affs))]
  n_new <- length(raw_affs)

  message(sprintf(
    "build_affiliation_lookup: %d publication/raw-affiliation occurrence(s).",
    nrow(occurrences)
  ))
  message(sprintf(
    "build_affiliation_lookup: %d unique raw affiliation string(s) need LLM labels.",
    n_new
  ))

  if (n_new > 0L) {
    # ---- Stage 2: Create LLM labeling groups -------------------------------

    if (is.null(threshold)) {
      cluster_ids <- seq_along(raw_affs)
      message(sprintf(
        "Using one raw affiliation string per LLM cluster (%d cluster(s)).",
        n_new
      ))
    } else if (n_new == 1L) {
      cluster_ids <- 1L
    } else {
      message("Computing pairwise Jaro-Winkler distances for new strings (this may take a moment)...")
      dm <- stringdist::stringdistmatrix(raw_affs, raw_affs, method = "jw", p = 0.1)
      hc <- stats::hclust(stats::as.dist(dm), method = "average")
      cluster_ids <- stats::cutree(hc, h = threshold)
    }

    clusters_df <- data.frame(
      raw        = raw_affs,
      cluster_id = cluster_ids,
      stringsAsFactors = FALSE
    )

    n_clusters <- length(unique(cluster_ids))
    if (!is.null(threshold)) {
      message(sprintf(
        "Formed %d clusters from %d new strings at threshold %.2f.",
        n_clusters, n_new, threshold
      ))
    }

    # ---- Stage 3: LLM labels each cluster ----------------------------------

    cluster_list <- split(clusters_df$raw, clusters_df$cluster_id)
    cids         <- as.integer(names(cluster_list))
    n_batches    <- ceiling(n_clusters / batch_size)

    canonical_by_cid <- setNames(rep("Unknown", n_clusters), as.character(cids))

    for (b in seq_len(n_batches)) {
      idx_start <- (b - 1L) * batch_size + 1L
      idx_end   <- min(b * batch_size, n_clusters)
      batch_cids <- cids[idx_start:idx_end]
      batch      <- cluster_list[as.character(batch_cids)]

      message(sprintf(
        "LLM batch %d/%d (clusters %d-%d of %d)...",
        b, n_batches, idx_start, idx_end, n_clusters
      ))

      .llm_reserve_output_tokens(max_output_tokens, rate_limit)
      results <- .label_clusters_llm(
        batch,
        model,
        api_key,
        base_url,
        provider,
        reference,
        system_prompt_template,
        user_prompt_template,
        max_output_tokens
      )
      canonical_by_cid[as.character(batch_cids)] <- results
    }

    raw_to_canonical <- setNames(
      .normalize_unknown_canonical(canonical_by_cid[as.character(cluster_ids)]),
      raw_affs
    )
    idx <- which(needs_label & occurrences$raw %in% names(raw_to_canonical))
    occurrences$canonical[idx] <- unname(raw_to_canonical[occurrences$raw[idx]])
    occurrences$new[idx] <- occurrences$canonical[idx] == "Unknown"
  }

  occurrences$canonical <- .normalize_unknown_canonical(occurrences$canonical)
  occurrences$new <- .coerce_new_flag(occurrences$new)
  occurrences <- .append_existing_occurrences_not_current(occurrences, existing_lookup)
  occurrences <- .order_affiliation_lookup(occurrences)

  n_unresolved <- sum(occurrences$new & occurrences$canonical == "Unknown", na.rm = TRUE)
  if (n_unresolved > 0L) {
    message(sprintf(
      "%d occurrence(s) are unresolved and marked new/Unknown. ",
      n_unresolved
    ), appendLF = FALSE)
    message("Review them in shiny/affiliation_review_app.R before publishing.")
  }

  readr::write_csv(occurrences, output_path)
  message(sprintf("Lookup written to %s (%d occurrence rows).", output_path, nrow(occurrences)))
  invisible(occurrences)
}

#' Read default LLM settings from pipeline config
#'
#' @return List with `model`, `base_url`, and `provider`.
#'
#' @noRd
.affiliation_llm_defaults <- function() {
  cfg <- yaml::read_yaml("config/pipeline.yml")
  model <- cfg$llm$model
  base_url <- cfg$llm$base_url
  if (is.null(model) || !nzchar(as.character(model))) {
    stop("config/pipeline.yml must define llm.model.", call. = FALSE)
  }
  if (is.null(base_url) || !nzchar(as.character(base_url))) {
    stop("config/pipeline.yml must define llm.base_url.", call. = FALSE)
  }
  provider <- cfg$llm$provider
  if (is.null(provider) || !nzchar(as.character(provider))) {
    provider <- "openai-compatible"
  }
  list(
    model = as.character(model),
    base_url = as.character(base_url),
    provider = as.character(provider)
  )
}

#' Read the existing affiliation lookup
#'
#' @param path Path to the lookup CSV.
#'
#' @return Data frame with occurrence-level lookup columns.
#'
#' @noRd
.read_existing_lookup <- function(path) {
  if (!file.exists(path)) {
    return(.empty_affiliation_lookup())
  }

  lookup <- readr::read_csv(path, show_col_types = FALSE)
  if (!all(c("raw", "canonical") %in% names(lookup))) {
    stop(sprintf(
      "build_affiliation_lookup: existing lookup %s must contain `raw` and `canonical` columns.",
      path
    ))
  }
  if (!"new" %in% names(lookup)) {
    lookup$new <- FALSE
  }

  required <- c(
    "record_key", "doi", "doi_url", "title", "year", "authors",
    "raw", "canonical", "new", "reviewed_at", "review_notes"
  )
  for (col in setdiff(required, names(lookup))) {
    lookup[[col]] <- if (col == "new") FALSE else NA_character_
  }

  lookup$record_key <- as.character(lookup$record_key)
  lookup$doi <- as.character(lookup$doi)
  lookup$doi_url <- as.character(lookup$doi_url)
  lookup$title <- as.character(lookup$title)
  lookup$year <- as.character(lookup$year)
  lookup$authors <- as.character(lookup$authors)
  lookup$raw <- as.character(lookup$raw)
  lookup$canonical <- .normalize_unknown_canonical(lookup$canonical)
  lookup$new <- .coerce_new_flag(lookup$new)
  lookup$reviewed_at <- as.character(lookup$reviewed_at)
  lookup$review_notes <- as.character(lookup$review_notes)

  lookup <- lookup[!is.na(lookup$raw) & nzchar(trimws(lookup$raw)), , drop = FALSE]
  lookup <- lookup[, c(required, setdiff(names(lookup), required)), drop = FALSE]

  occurrence_key <- .occurrence_key(lookup$record_key, lookup$raw)
  legacy <- is.na(lookup$record_key) | !nzchar(trimws(lookup$record_key))
  keep <- legacy | !duplicated(occurrence_key)
  lookup[keep, , drop = FALSE]
}

#' Empty occurrence-level affiliation lookup
#'
#' @return Empty data frame with canonical lookup columns.
#'
#' @noRd
.empty_affiliation_lookup <- function() {
  data.frame(
    record_key = character(),
    doi = character(),
    doi_url = character(),
    title = character(),
    year = character(),
    authors = character(),
    raw = character(),
    canonical = character(),
    new = logical(),
    reviewed_at = character(),
    review_notes = character(),
    stringsAsFactors = FALSE
  )
}

#' Build one lookup row per publication/raw-affiliation occurrence
#'
#' @param pubs Publication data with `record_key` and `affiliations`.
#'
#' @return Occurrence-level lookup data frame.
#'
#' @noRd
.build_affiliation_occurrences <- function(pubs) {
  if (!"affiliations" %in% names(pubs) || nrow(pubs) == 0L) {
    return(.empty_affiliation_lookup())
  }

  get_col <- function(name) {
    if (name %in% names(pubs)) as.character(pubs[[name]]) else rep(NA_character_, nrow(pubs))
  }
  collapse_value <- function(x) {
    x <- unlist(x)
    x <- x[!is.na(x) & nzchar(trimws(x))]
    if (length(x) == 0L) NA_character_ else paste(unique(x), collapse = "; ")
  }

  record_key <- get_col("record_key")
  missing_key <- is.na(record_key) | !nzchar(trimws(record_key))
  record_key[missing_key] <- paste0("row_", which(missing_key))

  doi <- vapply(get_col("doi"), .normalize_doi, character(1L))
  doi_url <- ifelse(is.na(doi) | !nzchar(doi), NA_character_, paste0("https://doi.org/", doi))
  title <- get_col("title")
  year <- get_col("year")
  authors <- if ("authors" %in% names(pubs)) {
    vapply(pubs$authors, collapse_value, character(1L))
  } else {
    rep(NA_character_, nrow(pubs))
  }

  pieces <- lapply(seq_len(nrow(pubs)), function(i) {
    raw <- unique(unlist(pubs$affiliations[[i]]))
    raw <- raw[!is.na(raw) & nzchar(trimws(raw))]
    if (length(raw) == 0L) return(NULL)
    data.frame(
      record_key = record_key[[i]],
      doi = doi[[i]],
      doi_url = doi_url[[i]],
      title = title[[i]],
      year = year[[i]],
      authors = authors[[i]],
      raw = raw,
      canonical = NA_character_,
      new = TRUE,
      reviewed_at = NA_character_,
      review_notes = NA_character_,
      stringsAsFactors = FALSE
    )
  })

  occurrences <- do.call(rbind, pieces)
  if (is.null(occurrences) || nrow(occurrences) == 0L) {
    return(.empty_affiliation_lookup())
  }

  occurrences[!duplicated(.occurrence_key(occurrences$record_key, occurrences$raw)), , drop = FALSE]
}

#' Apply previously reviewed occurrence-level decisions to current rows
#'
#' @param occurrences Current occurrence inventory.
#' @param existing_lookup Existing lookup rows.
#'
#' @return Current rows with preserved canonical review fields where available.
#'
#' @noRd
.apply_existing_occurrence_reviews <- function(occurrences, existing_lookup) {
  if (nrow(occurrences) == 0L || nrow(existing_lookup) == 0L) {
    return(occurrences)
  }

  existing_occ <- existing_lookup[
    !is.na(existing_lookup$record_key) & nzchar(trimws(existing_lookup$record_key)),
    ,
    drop = FALSE
  ]
  if (nrow(existing_occ) == 0L) {
    return(occurrences)
  }

  existing_key <- .occurrence_key(existing_occ$record_key, existing_occ$raw)
  names(existing_key) <- seq_along(existing_key)
  current_key <- .occurrence_key(occurrences$record_key, occurrences$raw)
  match_idx <- match(current_key, existing_key)
  matched <- which(!is.na(match_idx))
  if (length(matched) == 0L) {
    return(occurrences)
  }

  old <- existing_occ[match_idx[matched], , drop = FALSE]
  preserve_cols <- c("canonical", "new", "reviewed_at", "review_notes")
  for (col in preserve_cols) {
    occurrences[matched, col] <- old[[col]]
  }
  occurrences
}

#' Apply a single unambiguous reviewed canonical value for repeated raw strings
#'
#' @param occurrences Current occurrence inventory.
#' @param existing_lookup Existing lookup rows.
#'
#' @return Current rows with obvious repeated raw strings filled.
#'
#' @noRd
.apply_trusted_raw_canonical <- function(occurrences, existing_lookup) {
  if (nrow(occurrences) == 0L || nrow(existing_lookup) == 0L) {
    return(occurrences)
  }

  reviewed <- existing_lookup[
    !existing_lookup$new &
      !is.na(existing_lookup$canonical) &
      nzchar(trimws(existing_lookup$canonical)) &
      existing_lookup$canonical != "Unknown",
    ,
    drop = FALSE
  ]
  if (nrow(reviewed) == 0L) {
    return(occurrences)
  }

  raw_values <- split(reviewed$canonical, reviewed$raw)
  trusted <- vapply(raw_values, function(x) {
    vals <- sort(unique(x[!is.na(x) & nzchar(trimws(x))]))
    if (length(vals) == 1L) vals[[1L]] else NA_character_
  }, character(1L))
  trusted <- trusted[!is.na(trusted)]
  if (length(trusted) == 0L) {
    return(occurrences)
  }

  needs_value <- is.na(occurrences$canonical) | !nzchar(trimws(occurrences$canonical))
  idx <- which(needs_value & occurrences$raw %in% names(trusted))
  if (length(idx) > 0L) {
    occurrences$canonical[idx] <- unname(trusted[occurrences$raw[idx]])
    occurrences$new[idx] <- FALSE
  }
  occurrences
}

#' Preserve existing occurrence rows outside the current publish set
#'
#' @param current Current occurrence rows.
#' @param existing_lookup Existing lookup rows.
#'
#' @return Combined lookup rows.
#'
#' @noRd
.append_existing_occurrences_not_current <- function(current, existing_lookup) {
  if (nrow(existing_lookup) == 0L) {
    return(current)
  }

  existing_occ <- existing_lookup[
    !is.na(existing_lookup$record_key) & nzchar(trimws(existing_lookup$record_key)),
    ,
    drop = FALSE
  ]
  if (nrow(existing_occ) == 0L) {
    return(current)
  }

  current_key <- .occurrence_key(current$record_key, current$raw)
  existing_key <- .occurrence_key(existing_occ$record_key, existing_occ$raw)
  old <- existing_occ[!existing_key %in% current_key, , drop = FALSE]
  .bind_lookup_rows(current, old)
}

#' Order lookup rows for efficient review
#'
#' @param lookup Occurrence-level lookup rows.
#'
#' @return Ordered lookup rows.
#'
#' @noRd
.order_affiliation_lookup <- function(lookup) {
  lookup[order(
    !lookup$new,
    lookup$canonical != "Unknown",
    lookup$raw,
    lookup$doi,
    na.last = TRUE
  ), , drop = FALSE]
}

#' Bind lookup rows while preserving columns
#'
#' @param x First data frame.
#' @param y Second data frame.
#'
#' @return Row-bound data frame.
#'
#' @noRd
.bind_lookup_rows <- function(x, y) {
  for (col in setdiff(names(y), names(x))) x[[col]] <- NA
  for (col in setdiff(names(x), names(y))) y[[col]] <- NA
  y <- y[, names(x), drop = FALSE]
  rbind(x, y)
}

#' Build an occurrence key
#'
#' @param record_key Publication record key.
#' @param raw Raw affiliation string.
#'
#' @return Character occurrence key.
#'
#' @noRd
.occurrence_key <- function(record_key, raw) {
  paste(as.character(record_key), as.character(raw), sep = "\r")
}

#' Combine file and lookup-derived canonical institution references
#'
#' @param reference_path Path to the institution reference text file.
#' @param existing_lookup Existing affiliation lookup data frame.
#'
#' @return Character vector of canonical institution names.
#'
#' @noRd
.combined_reference <- function(reference_path, existing_lookup) {
  reference <- .load_reference(reference_path)
  established <- character()
  if (nrow(existing_lookup) > 0L) {
    reviewed <- !existing_lookup$new
    established <- existing_lookup$canonical[
      reviewed &
        !is.na(existing_lookup$canonical) &
        nzchar(trimws(existing_lookup$canonical)) &
        existing_lookup$canonical != "Unknown"
    ]
  }
  sort(unique(c(reference, established)))
}

#' Read the institution reference list from a plain-text file
#'
#' @param path Path to a plain-text file with one institution name per line.
#'
#' @return Character vector of institution names. Returns `character(0)` and
#'   issues a warning if the file does not exist — [build_affiliation_lookup()]
#'   will still run, but reduced canonicalisation accuracy should be expected.
#'
#' @noRd
.load_reference <- function(path) {
  if (!file.exists(path)) {
    warning(sprintf(
      ".load_reference: %s not found — run build_institution_reference() first. ",
      path
    ), appendLF = FALSE)
    warning("Proceeding without a reference list.", call. = FALSE)
    return(character(0L))
  }
  lines <- readLines(path, warn = FALSE)
  lines <- trimws(lines)
  lines[nzchar(lines)]
}

#' Read a prompt template from disk and validate its dynamic placeholder
#'
#' @param path Path to prompt template.
#' @param required_placeholder Placeholder that must appear in the template.
#'
#' @return Prompt template text.
#'
#' @noRd
.read_prompt_template <- function(path, required_placeholder) {
  if (!file.exists(path)) {
    stop(sprintf("Prompt template not found: %s", path), call. = FALSE)
  }
  template <- readr::read_file(path)
  if (!grepl(required_placeholder, template, fixed = TRUE)) {
    stop(sprintf(
      "Prompt template %s must contain placeholder %s.",
      path,
      required_placeholder
    ), call. = FALSE)
  }
  template
}

#' Normalize a DOI value for trace output
#'
#' @param doi DOI value, possibly already expressed as a URL.
#'
#' @return Normalized DOI string or `NA_character_`.
#'
#' @noRd
.normalize_doi <- function(doi) {
  doi <- trimws(as.character(doi))
  if (length(doi) == 0L || is.na(doi) || !nzchar(doi)) {
    return(NA_character_)
  }
  doi <- sub("^https?://(dx\\.)?doi\\.org/", "", doi, ignore.case = TRUE)
  doi <- sub("^doi:\\s*", "", doi, ignore.case = TRUE)
  trimws(doi)
}

#' Send one batch of clusters to the LLM and return canonical names
#'
#' @param clusters Named list of character vectors (cluster ID → member strings).
#' @param model LLM model name.
#' @param api_key API key.
#' @param base_url LLM base URL.
#' @param provider LLM API protocol.
#' @param reference Character vector of known canonical institution names.
#' @param system_prompt_template System prompt template text.
#' @param user_prompt_template User prompt template text.
#'
#' @return Character vector of canonical names in the same order as `clusters`.
#'
#' @noRd
.label_clusters_llm <- function(
  clusters,
  model,
  api_key,
  base_url,
  provider,
  reference,
  system_prompt_template,
  user_prompt_template,
  max_output_tokens = 600L
) {
  user_msg   <- .build_user_message(clusters, user_prompt_template)
  system_msg <- .affiliation_system_prompt(reference, system_prompt_template)

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
        system = system_msg,
        messages = list(list(role = "user", content = user_msg))
      ))
  } else if (identical(provider, "openai-compatible")) {
    request <- request |>
      httr2::req_headers(Authorization = paste("Bearer", api_key)) |>
      httr2::req_body_json(list(
        model = model,
        max_tokens = max_output_tokens,
        messages = list(
          list(role = "system", content = system_msg),
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
      warning(sprintf(".label_clusters_llm: request failed: %s", e$message))
      NULL
    }
  )

  if (is.null(resp) || httr2::resp_status(resp) != 200L) {
    if (!is.null(resp)) {
      warning(sprintf(
        ".label_clusters_llm: HTTP %d — %s",
        httr2::resp_status(resp),
        httr2::resp_body_string(resp)
      ))
    }
    return(rep("Unknown", length(clusters)))
  }

  body <- httr2::resp_body_json(resp)
  raw_text <- if (is_anthropic) {
    text_blocks <- Filter(function(block) identical(block$type, "text"), body$content)
    paste(vapply(text_blocks, function(block) block$text, character(1L)), collapse = "\n")
  } else {
    body$choices[[1L]]$message$content
  }

  # Strip markdown code fences the model may wrap around the JSON
  raw_text <- gsub("^```(?:json)?\\s*|\\s*```$", "", trimws(raw_text), perl = TRUE)

  parsed <- tryCatch(
    jsonlite::fromJSON(raw_text, simplifyDataFrame = TRUE),
    error = function(e) {
      warning(sprintf(
        ".label_clusters_llm: JSON parse failed: %s\nRaw response:\n%s",
        e$message, raw_text
      ))
      NULL
    }
  )

  if (is.null(parsed) || !all(c("cluster_id", "canonical") %in% names(parsed))) {
    return(rep("Unknown", length(clusters)))
  }

  result_map <- setNames(as.character(parsed$canonical), as.character(parsed$cluster_id))

  vapply(names(clusters), function(cid) {
    val <- result_map[[cid]]
    .normalize_unknown_canonical(if (is.null(val) || is.na(val) || !nzchar(val)) "Unknown" else val)
  }, character(1L))
}

#' Format the user message for one batch of clusters
#'
#' @param clusters Named list of character vectors (cluster ID → member strings).
#' @param user_prompt_template User prompt template text.
#'
#' @return A single character string containing the formatted prompt.
#'
#' @noRd
.build_user_message <- function(clusters, user_prompt_template) {
  cluster_blocks <- vapply(seq_along(clusters), function(i) {
    cid     <- names(clusters)[i]
    members <- clusters[[i]]
    lines   <- paste0("    - ", members, collapse = "\n")
    sprintf("Cluster %s:\n%s", cid, lines)
  }, character(1L))

  gsub(
    "{{cluster_blocks}}",
    paste(cluster_blocks, collapse = "\n\n"),
    user_prompt_template,
    fixed = TRUE
  )
}

#' Build the system prompt with naming rules and a data-derived reference list
#'
#' @param reference Character vector of canonical institution names produced by
#'   [build_institution_reference()]. If empty, the reference section is
#'   omitted from the prompt.
#' @param system_prompt_template System prompt template text.
#'
#' @return A single character string containing the system prompt.
#'
#' @noRd
.affiliation_system_prompt <- function(reference, system_prompt_template) {
  ref_section <- if (length(reference) > 0L) {
    paste0(
      "Known institutions in this dataset — if a cluster matches one of these, ",
      "use this exact spelling:\n",
      paste0("  ", reference, collapse = "\n"),
      "\n\n"
    )
  } else {
    ""
  }

  gsub(
    "{{reference_section}}",
    ref_section,
    system_prompt_template,
    fixed = TRUE
  )
}

#' Normalize unresolved canonical institution markers
#'
#' @param x Character vector of canonical institution names.
#'
#' @return `x`, with any case variant of `"unknown"` converted to `"Unknown"`.
#'
#' @noRd
.normalize_unknown_canonical <- function(x) {
  x <- as.character(x)
  x[!is.na(x) & tolower(trimws(x)) == "unknown"] <- "Unknown"
  x
}

#' Coerce lookup review flags to logical
#'
#' @param x Vector read from the lookup `new` column.
#'
#' @return Logical vector.
#'
#' @noRd
.coerce_new_flag <- function(x) {
  if (is.logical(x)) {
    return(replace(x, is.na(x), FALSE))
  }
  vals <- tolower(trimws(as.character(x)))
  vals[is.na(vals) | !nzchar(vals)] <- "false"
  vals %in% c("true", "t", "1", "yes", "y")
}
