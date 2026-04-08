#' Build a canonical institution lookup table from raw affiliation strings
#'
#' Extracts all unique raw affiliation strings from `pubs$affiliations`,
#' clusters near-identical variants by string distance, sends each cluster to
#' an OpenAI-compatible LLM to obtain a single canonical institution name, and
#' writes the result to a CSV for human review.
#'
#' @details
#' Output CSV columns:
#' \describe{
#'   \item{raw}{Raw string exactly as it appears in `pubs$affiliations`}
#'   \item{canonical}{Canonical institution name, or `"UNKNOWN"` if
#'     unresolvable}
#' }
#'
#' After reviewing (and manually correcting) the CSV, it is tracked by the
#' `affiliation_lookup_csv` target and consumed by [apply_affiliation_lookup()].
#'
#' Typical usage:
#' ```r
#' source("R/build_affiliation_lookup.R")
#' pubs_classified <- targets::tar_read(pubs_classified)
#' build_affiliation_lookup(pubs_classified, model = "<model-name>")
#' ```
#'
#' @param pubs Tibble with an `affiliations` list column.
#' @param output_path Path to write the lookup CSV.
#' @param reference_path Path to the institution reference list produced by
#'   [build_institution_reference()]; one canonical name per line. If the file
#'   does not exist, the LLM receives no reference list and a warning is issued.
#' @param batch_size Number of clusters to send per LLM API call.
#' @param threshold Jaro-Winkler distance cut height for clustering; lower is
#'   more conservative (only near-identical strings merge).
#' @param model LLM model name passed to the API.
#' @param api_key API key (reads `PUBCLASSIFY_LLM_KEY` by default).
#' @param base_url OpenAI-compatible base URL (reads `PUBCLASSIFY_LLM_BASE_URL`).
#'
#' @return Invisibly, the lookup data frame with columns `raw` and `canonical`.

build_affiliation_lookup <- function(
  pubs,
  output_path    = "data/affiliation_lookup.csv",
  reference_path = "data/institution_reference.txt",
  batch_size     = 50L,
  threshold      = 0.10,
  model,
  api_key  = Sys.getenv("PUBCLASSIFY_LLM_KEY"),
  base_url = Sys.getenv("PUBCLASSIFY_LLM_BASE_URL")
) {
  reference <- .load_reference(reference_path)
  
  # ---- Stage 1: Extract unique raw strings ----------------------------------

  raw_affs <- unique(unlist(pubs$affiliations))
  raw_affs <- raw_affs[!is.na(raw_affs) & nzchar(trimws(raw_affs))]
  n <- length(raw_affs)
  message(sprintf("build_affiliation_lookup: %d unique raw affiliation strings.", n))

  # ---- Stage 2: Cluster by Jaro-Winkler string distance --------------------

  message("Computing pairwise Jaro-Winkler distances (this may take a moment)...")
  dm <- stringdist::stringdistmatrix(raw_affs, raw_affs, method = "jw", p = 0.1)
  hc <- stats::hclust(stats::as.dist(dm), method = "average")
  cluster_ids <- stats::cutree(hc, h = threshold)

  clusters_df <- data.frame(
    raw        = raw_affs,
    cluster_id = cluster_ids,
    stringsAsFactors = FALSE
  )

  n_clusters <- length(unique(cluster_ids))
  message(sprintf(
    "Formed %d clusters from %d strings at threshold %.2f.",
    n_clusters, n, threshold
  ))

  # ---- Stage 3: LLM labels each cluster ------------------------------------

  cluster_list <- split(clusters_df$raw, clusters_df$cluster_id)
  cids         <- as.integer(names(cluster_list))
  n_batches    <- ceiling(n_clusters / batch_size)

  # Pre-fill with UNKNOWN; successful LLM responses overwrite entries
  canonical_by_cid <- setNames(rep("UNKNOWN", n_clusters), as.character(cids))

  for (b in seq_len(n_batches)) {
    idx_start <- (b - 1L) * batch_size + 1L
    idx_end   <- min(b * batch_size, n_clusters)
    batch_cids <- cids[idx_start:idx_end]
    batch      <- cluster_list[as.character(batch_cids)]

    message(sprintf(
      "LLM batch %d/%d (clusters %d-%d of %d)...",
      b, n_batches, idx_start, idx_end, n_clusters
    ))

    results <- .label_clusters_llm(batch, model, api_key, base_url, reference)
    canonical_by_cid[as.character(batch_cids)] <- results
  }

  # Join canonical names back to the per-string data frame
  clusters_df$canonical <- canonical_by_cid[as.character(clusters_df$cluster_id)]
  lookup <- clusters_df[, c("raw", "canonical")]

  n_unknown <- sum(lookup$canonical == "UNKNOWN", na.rm = TRUE)
  if (n_unknown > 0L) {
    message(sprintf(
      "%d string(s) could not be resolved and are marked UNKNOWN. ",
      n_unknown
    ), appendLF = FALSE)
    message(sprintf("Edit %s to resolve them before running tar_make().", output_path))
  }

  readr::write_csv(lookup, output_path)
  message(sprintf("Lookup written to %s (%d rows).", output_path, nrow(lookup)))
  invisible(lookup)
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

#' Send one batch of clusters to the LLM and return canonical names
#'
#' @param clusters Named list of character vectors (cluster ID → member strings).
#' @param model LLM model name.
#' @param api_key API key.
#' @param base_url OpenAI-compatible base URL.
#' @param reference Character vector of known canonical institution names.
#'
#' @return Character vector of canonical names in the same order as `clusters`.
#'
#' @noRd
.label_clusters_llm <- function(clusters, model, api_key, base_url, reference) {
  user_msg   <- .build_user_message(clusters)
  system_msg <- .affiliation_system_prompt(reference)

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
          list(role = "system", content = system_msg),
          list(role = "user",   content = user_msg)
        ),
        temperature = 0
      )) |>
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
    return(rep("UNKNOWN", length(clusters)))
  }

  body     <- httr2::resp_body_json(resp)
  raw_text <- body$choices[[1L]]$message$content

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
    return(rep("UNKNOWN", length(clusters)))
  }

  result_map <- setNames(as.character(parsed$canonical), as.character(parsed$cluster_id))

  vapply(names(clusters), function(cid) {
    val <- result_map[[cid]]
    if (is.null(val) || is.na(val) || !nzchar(val)) "UNKNOWN" else val
  }, character(1L))
}

#' Format the user message for one batch of clusters
#'
#' @param clusters Named list of character vectors (cluster ID → member strings).
#'
#' @return A single character string containing the formatted prompt.
#'
#' @noRd
.build_user_message <- function(clusters) {
  cluster_blocks <- vapply(seq_along(clusters), function(i) {
    cid     <- names(clusters)[i]
    members <- clusters[[i]]
    lines   <- paste0("    - ", members, collapse = "\n")
    sprintf("Cluster %s:\n%s", cid, lines)
  }, character(1L))

  paste0(
    "Identify the canonical institution name for each cluster of affiliation ",
    "strings below. Each cluster groups strings that likely refer to the same ",
    "institution.\n\n",
    paste(cluster_blocks, collapse = "\n\n"),
    "\n\nRespond with a JSON array only — no other text, no markdown. ",
    "Each element must have exactly two fields:\n",
    "  \"cluster_id\": the cluster number (integer)\n",
    "  \"canonical\": the full official institution name, or \"UNKNOWN\"\n\n",
    "Example: [{\"cluster_id\": 1, \"canonical\": \"University of California, Davis\"}, ...]"
  )
}

#' Build the system prompt with naming rules and a data-derived reference list
#'
#' @param reference Character vector of canonical institution names produced by
#'   [build_institution_reference()]. If empty, the reference section is
#'   omitted from the prompt.
#'
#' @return A single character string containing the system prompt.
#'
#' @noRd
.affiliation_system_prompt <- function(reference) {
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

  paste0(
    "You are an expert in academic and government institution names, with deep ",
    "knowledge of California research institutions and water agencies. Your task ",
    "is to identify the single canonical (full, official) name for each cluster ",
    "of affiliation strings you are given.\n\n",

    "Rules:\n",
    "1. Always use the full official institution name — no abbreviations.\n",
    "2. University of California campuses: \"University of California, [City]\"\n",
    "   e.g., \"University of California, Davis\" (not \"UC Davis\" or \"UCD\").\n",
    "3. California State University campuses: use the official campus name,\n",
    "   e.g., \"California State University, Sacramento\" or \"San Jose State University\".\n",
    "4. Government agencies: spell out the full official name,\n",
    "   e.g., \"U.S. Geological Survey\", \"California Department of Water Resources\".\n",
    "5. If a cluster clearly contains strings from two genuinely different\n",
    "   institutions, return \"UNKNOWN\" — do not pick one arbitrarily.\n",
    "6. If you cannot confidently identify the institution, return \"UNKNOWN\".\n",
    "   It is better to return UNKNOWN than to guess incorrectly.\n\n",

    ref_section
  )
}
