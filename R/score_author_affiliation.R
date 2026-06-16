#' Score affiliation-query publications by likelihood of being a false positive
#'
#' Adds a `caff_score` integer column (0–12). Higher scores indicate records
#' that are more likely to require close inspection:
#'
#' | Signal | Points |
#' |---|---|
#' | No DWR author name + year found in `author_division_lookup.csv` | +5 |
#' | DWR affiliation string is a non-standard variant | +3 |
#' | Paper domain keywords suggest an unrelated field | +2 |
#' | No California geographic mention | +2 |
#'
#' Thresholds: high >= 7, medium >= 4, low < 4. Maximum: 12.
#'
#' @param pubs        Tibble with `affiliations` (list), `authors` (list),
#'   `year`, `title`, and `abstract` columns.
#' @param lookup_path Path to `data/lookups/author_division_lookup.csv`.
#'
#' @return `pubs` with `caff_score` column added.

score_author_affiliation <- function(pubs, lookup_path) {
  dwr_pattern <- "California Department of Water Resources"
  domain_pat  <- paste(
    "oncolog", "\\bcancer\\b", "cardiolog", "pharmaceut", "genomic",
    "quantum physic", "nuclear physic", "\\bfinancial market",
    "cryptocurrency", "dermatol", "\\bneurosurg",
    sep = "|"
  )
  ca_pat <- paste(
    "california", "\\bCA\\b", "sacramento", "san francisco", "los angeles",
    "san diego", "bay area", "bay delta", "\\bdelta\\b", "central valley",
    "sierra nevada", "\\bswp\\b", "\\bcvp\\b",
    sep = "|"
  )

  lookup <- if (file.exists(lookup_path)) prepare_lookup(lookup_path) else NULL

  scores <- vapply(seq_len(nrow(pubs)), function(i) {
    score        <- 0L
    affiliations <- pubs$affiliations[[i]]
    authors      <- pubs$authors[[i]]
    year         <- pubs$year[i]

    # Signal 1: no author on this paper found in HR staff lookup (+5)
    # Checks all authors — per-author affiliation position from Scopus is unreliable.
    if (!is.null(lookup) && length(authors) > 0L) {
      any_match <- any(vapply(
        authors,
        function(a) author_in_lookup(a, year, lookup),
        logical(1L)
      ))
      if (!any_match) score <- score + 5L
    }

    # Signal 2: non-standard DWR affiliation string variant (+3)
    all_affil_strings <- unlist(affiliations)
    dwr_strings <- all_affil_strings[grepl(dwr_pattern, all_affil_strings,
                                           ignore.case = TRUE, fixed = FALSE)]
    dwr_water <- dwr_strings[grepl(
      "water.{0,10}resource|dep.{0,15}water",
      dwr_strings, ignore.case = TRUE, perl = TRUE
    )]
    if (length(dwr_water) > 0L &&
        any(!grepl(dwr_pattern, dwr_water, fixed = TRUE))) {
      score <- score + 3L
    }

    all_text <- paste(
      if ("title"    %in% names(pubs)) pubs$title[i]    else "",
      if ("abstract" %in% names(pubs)) pubs$abstract[i] else "",
      paste(unlist(affiliations), collapse = " ")
    )

    # Signal 3: unrelated domain keywords (+2)
    if (grepl(domain_pat, all_text, ignore.case = TRUE, perl = TRUE)) {
      score <- score + 2L
    }

    # Signal 4: no California geographic mention (+2)
    if (!grepl(ca_pat, all_text, ignore.case = TRUE, perl = TRUE)) {
      score <- score + 2L
    }

    score
  }, integer(1L))

  dplyr::mutate(pubs, caff_score = scores)
}
