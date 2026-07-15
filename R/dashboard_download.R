#' Format publication records for dashboard CSV downloads
#'
#' @param pubs A dashboard publication data frame.
#' @param include_internal_fields Whether to include DWR division columns.
#' @return A data frame with viewer-friendly column names and flat values.
format_dashboard_download <- function(pubs, include_internal_fields = FALSE) {
  collapse_values <- function(x) {
    values <- trimws(as.character(unlist(x, use.names = FALSE)))
    values <- unique(values[!is.na(values) & nzchar(values)])
    if (length(values) == 0L) NA_character_ else paste(values, collapse = "; ")
  }

  text_value <- function(x) {
    x <- trimws(as.character(x))
    x[!nzchar(x)] <- NA_character_
    x
  }

  doi <- text_value(pubs$doi)
  download <- data.frame(
    "Title" = text_value(pubs$title),
    "Authors" = vapply(pubs$authors, collapse_values, character(1L)),
    "Publication Year" = pubs$year,
    "Publication Type" = text_value(pubs$doc_type),
    "Journal" = text_value(pubs$journal),
    "DOI" = doi,
    "DOI URL" = ifelse(is.na(doi), NA_character_, paste0("https://doi.org/", doi)),
    "Abstract" = text_value(pubs$abstract),
    "Science Category" = stringr::str_to_title(text_value(pubs$pc_category)),
    "Science Field" = text_value(pubs$pc_field),
    "DWR Contribution" = text_value(pubs$contribution_type),
    "Affiliated Organizations" = vapply(pubs$affiliations, collapse_values, character(1L)),
    "Affiliation Countries" = vapply(pubs$affiliation_countries, collapse_values, character(1L)),
    check.names = FALSE,
    stringsAsFactors = FALSE
  )

  if (isTRUE(include_internal_fields)) {
    download[["Author Division(s)"]] <- text_value(pubs$author_division)
    download[["Funding Division"]] <- text_value(pubs$funding_division)
  }

  download
}
