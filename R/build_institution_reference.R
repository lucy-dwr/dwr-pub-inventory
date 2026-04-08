#' Build a reference list of canonical institution names
#'
#' Extracts the most frequent raw affiliation strings from `pubs$affiliations`
#' and, optionally, canonicalises them via an LLM, writing one institution name
#' per line to `output_path`.
#'
#' @details
#' Frequency is a reliable proxy for importance: strings that appear across many
#' author-publication pairs are almost certainly the major institutions in the
#' dataset. A quick LLM pass strips department prefixes and standardises
#' spelling/punctuation.
#'
#' The output file is read by [build_affiliation_lookup()] and included in the
#' system prompt as a reference list, anchoring the LLM to names actually
#' present in the dataset rather than guessing freely.
#'
#' Typical workflow:
#' \enumerate{
#'   \item `source("R/build_institution_reference.R")`
#'   \item `pubs_classified <- targets::tar_read(pubs_classified)`
#'   \item `build_institution_reference(pubs_classified, model = "<model-name>")`
#'   \item Review/edit `data/institution_reference.txt`.
#'   \item Run [build_affiliation_lookup()] — it reads the file automatically.
#' }
#'
#' @param pubs Tibble with an `affiliations` list column.
#' @param top_n Number of most-frequent raw strings to canonicalise.
#' @param output_path Path to write the reference list.
#' @param use_llm If `FALSE`, write the raw top-N strings without canonicalising;
#'   useful for a quick manual review pass before committing to an LLM call.
#' @param batch_size Number of strings per LLM API call (reduce if hitting
#'   timeouts).
#' @param model LLM model name (required when `use_llm = TRUE`).
#' @param api_key API key (reads `PUBCLASSIFY_LLM_KEY` by default).
#' @param base_url OpenAI-compatible base URL (reads `PUBCLASSIFY_LLM_BASE_URL`).
#'
#' @return Invisibly, a character vector of canonical institution names.

build_institution_reference <- function(
  pubs,
  top_n       = 100L,
  output_path = "data/institution_reference.txt",
  use_llm     = TRUE,
  batch_size  = 20L,
  model       = NULL,
  api_key     = Sys.getenv("PUBCLASSIFY_LLM_KEY"),
  base_url    = Sys.getenv("PUBCLASSIFY_LLM_BASE_URL")
) {
  # Frequency table across all author-publication pairs (not unique strings)
  all_affs <- unlist(pubs$affiliations)
  all_affs <- all_affs[!is.na(all_affs) & nzchar(trimws(all_affs))]
  freq     <- sort(table(all_affs), decreasing = TRUE)

  top_strings <- names(freq)[seq_len(min(top_n, length(freq)))]
  message(sprintf(
    "build_institution_reference: top %d strings selected (of %d unique).",
    length(top_strings), length(freq)
  ))

  if (!use_llm) {
    writeLines(top_strings, output_path)
    message(sprintf(
      "Raw top-%d strings written to %s — review and edit before running ",
      length(top_strings), output_path
    ), appendLF = FALSE)
    message("build_affiliation_lookup().")
    return(invisible(top_strings))
  }

  if (is.null(model) || !nzchar(model)) {
    stop("build_institution_reference: `model` is required when use_llm = TRUE.")
  }

  # LLM canonicalises the top strings in batches: strips department prefixes,
  # expands abbreviations, standardises punctuation. No reference list is needed
  # because these high-frequency strings are typically already well-formed and
  # the task is simpler (extract the institution, not identify it).
  n_strings  <- length(top_strings)
  n_batches  <- ceiling(n_strings / batch_size)
  canonical  <- character(n_strings)

  message(sprintf(
    "Sending %d strings to LLM in %d batch(es) of up to %d...",
    n_strings, n_batches, batch_size
  ))

  for (b in seq_len(n_batches)) {
    idx <- seq(
      from = (b - 1L) * batch_size + 1L,
      to   = min(b * batch_size, n_strings)
    )
    message(sprintf("  Batch %d/%d (strings %d–%d)...", b, n_batches, idx[1L], idx[length(idx)]))
    canonical[idx] <- .canonicalise_top_strings(top_strings[idx], idx[1L] - 1L, model, api_key, base_url)
  }

  # Deduplicate: multiple raw strings may resolve to the same institution
  institutions <- sort(unique(canonical[canonical != "UNKNOWN" & !is.na(canonical)]))

  n_unknown <- sum(canonical == "UNKNOWN" | is.na(canonical))
  if (n_unknown > 0L) {
    message(sprintf(
      "%d string(s) returned UNKNOWN — excluded from reference list. ",
      n_unknown
    ), appendLF = FALSE)
    message("Add them manually to ", output_path, " if needed.")
  }

  writeLines(institutions, output_path)
  message(sprintf(
    "Reference list written to %s (%d unique institutions).",
    output_path, length(institutions)
  ))
  invisible(institutions)
}

#' Send a batch of affiliation strings to the LLM for canonicalisation
#'
#' @param strings Character vector of raw affiliation strings.
#' @param index_offset Integer offset so that 1-based indices in the JSON
#'   response correspond to positions in the full `top_strings` vector.
#' @param model LLM model name.
#' @param api_key API key.
#' @param base_url OpenAI-compatible base URL.
#'
#' @return Character vector of canonical names the same length as `strings`.
#'   Failed or unresolvable entries are `"UNKNOWN"`.
#'
#' @noRd
.canonicalise_top_strings <- function(strings, index_offset = 0L, model, api_key, base_url) {
  indices  <- seq_along(strings) + index_offset
  numbered <- paste0(indices, ". ", strings, collapse = "\n")

  user_msg <- paste0(
    "For each affiliation string below, extract and return the canonical full ",
    "name of the institution only — not the department, lab, city, or country.\n\n",
    "Rules:\n",
    "- Use the full official institution name (no abbreviations).\n",
    "- University of California campuses: \"University of California, [City]\"\n",
    "- California State University campuses: use official campus name.\n",
    "- Government agencies: full official name, e.g. \"U.S. Geological Survey\".\n",
    "- If a string contains multiple distinct institutions, return \"UNKNOWN\".\n",
    "- If you cannot identify the institution with confidence, return \"UNKNOWN\".\n\n",
    "Strings:\n",
    numbered,
    "\n\nRespond with a JSON array only — no other text. Each element:\n",
    "  \"index\": the number from the list above (integer)\n",
    "  \"canonical\": the institution name or \"UNKNOWN\"\n\n",
    "Example: [{\"index\": 1, \"canonical\": \"University of California, Davis\"}, ...]"
  )

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
          list(role = "system", content = paste0(
            "You are an expert in academic and government institution names. ",
            "Extract the canonical institution name from each affiliation string. ",
            "Respond only with the JSON array requested."
          )),
          list(role = "user", content = user_msg)
        ),
        temperature = 0
      )) |>
      httr2::req_error(is_error = \(r) FALSE) |>
      httr2::req_perform(),
    error = function(e) {
      warning(sprintf(".canonicalise_top_strings: request failed: %s", e$message))
      NULL
    }
  )

  if (is.null(resp) || httr2::resp_status(resp) != 200L) {
    if (!is.null(resp)) {
      warning(sprintf(
        ".canonicalise_top_strings: HTTP %d",
        httr2::resp_status(resp)
      ))
    }
    return(rep("UNKNOWN", length(strings)))
  }

  raw_text <- resp |>
    httr2::resp_body_json() |>
    (\(b) b$choices[[1L]]$message$content)()

  raw_text <- gsub("^```(?:json)?\\s*|\\s*```$", "", trimws(raw_text), perl = TRUE)

  parsed <- tryCatch(
    jsonlite::fromJSON(raw_text, simplifyDataFrame = TRUE),
    error = function(e) {
      warning(sprintf(
        ".canonicalise_top_strings: JSON parse failed: %s\nRaw:\n%s",
        e$message, raw_text
      ))
      NULL
    }
  )

  if (is.null(parsed) || !all(c("index", "canonical") %in% names(parsed))) {
    return(rep("UNKNOWN", length(strings)))
  }

  result_map <- setNames(as.character(parsed$canonical), as.character(parsed$index))
  vapply(indices, function(i) {
    val <- result_map[[as.character(i)]]
    if (is.null(val) || is.na(val) || !nzchar(val)) "UNKNOWN" else val
  }, character(1L))
}
