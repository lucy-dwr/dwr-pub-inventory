#' Add stable record keys to a publications tibble
#'
#' Assigns a `record_key` using the first available identifier in priority order:
#' Scopus EID → normalised DOI → SHA-256 hash of (title + year + first author + journal).
#'
#' @param pubs A tibble of publications with at least `doi`, `title`, `year`,
#'   `authors` (list), and `journal` columns.
#'
#' @return `pubs` with a leading `record_key` character column.

add_record_keys <- function(pubs) {
  eid_col <- if ("eid" %in% names(pubs)) pubs$eid else rep(NA_character_, nrow(pubs))

  record_key <- vapply(seq_len(nrow(pubs)), function(i) {
    eid_val <- eid_col[[i]]
    doi_val <- pubs$doi[[i]]

    if (!is.na(eid_val) && nzchar(trimws(eid_val))) {
      return(paste0("eid:", trimws(eid_val)))
    }

    if (!is.na(doi_val) && nzchar(trimws(doi_val))) {
      return(paste0("doi:", tolower(trimws(doi_val))))
    }

    # Fallback: hash of normalised bibliographic fields
    title_norm   <- tolower(trimws(pubs$title[[i]]))
    year_val     <- as.character(pubs$year[[i]])
    authors_list <- pubs$authors[[i]]
    first_author <- if (length(authors_list) > 0L && !is.na(authors_list[[1L]]))
                      tolower(trimws(as.character(authors_list[[1L]])))
                    else ""
    journal_norm <- tolower(trimws(pubs$journal[[i]]))
    combined     <- paste(title_norm, year_val, first_author, journal_norm, sep = "|")
    paste0("hash:", substr(digest::digest(combined, algo = "sha256"), 1L, 16L))
  }, character(1L))

  pubs <- dplyr::mutate(pubs, record_key = record_key, .before = 1L)

  # Coerce any list-of-lists entries in list columns to flat character vectors.
  # Some Scopus records return nested lists (e.g. affiliations) that Arrow
  # cannot serialize to Parquet.
  for (nm in names(pubs)) {
    if (is.list(pubs[[nm]])) {
      pubs[[nm]] <- lapply(pubs[[nm]], function(x) {
        if (is.list(x)) unlist(x, use.names = FALSE) else x
      })
    }
  }

  pubs
}
